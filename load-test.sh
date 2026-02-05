#!/bin/bash
#
# OpenStack Load Test Script
# Creates instances on random auto-test networks to induce load,
# validates test infrastructure, then cleans up and repeats.
#
# Usage: ./load-test.sh [max_iterations]
#   max_iterations: Optional. Stop after N iterations (default: unlimited)
#

set -uo pipefail

# Configuration
IMAGE="fedora-43"
FLAVOR="minimal"
KEYPAIR="aaustin-key"
DASHBOARD_URL="https://snat-heartbeat.apps.lab-hub.lab.signal9.gg/api/instances"
NUM_NETWORKS=10
WAIT_TIME=300  # 5 minutes
PING_RETRIES=5
PING_RETRY_DELAY=10
ITERATION=0
MAX_ITERATIONS=${1:-0}  # 0 means unlimited

# Track created resources for cleanup
declare -a CREATED_SERVERS
declare -a CREATED_FIPS
declare -a CREATED_PORTS

cleanup_iteration() {
    echo ""
    echo "=== Cleaning up iteration resources ==="

    # Delete floating IPs
    for fip_id in "${CREATED_FIPS[@]}"; do
        echo "Deleting floating IP: $fip_id"
        openstack floating ip delete "$fip_id" 2>/dev/null || true
    done

    # Delete servers
    for server in "${CREATED_SERVERS[@]}"; do
        echo "Deleting server: $server"
        openstack server delete "$server" 2>/dev/null || true
    done

    # Wait for servers to be deleted
    echo "Waiting for servers to be deleted..."
    for server in "${CREATED_SERVERS[@]}"; do
        while openstack server show "$server" &>/dev/null; do
            sleep 2
        done
    done

    # Delete ports
    for port in "${CREATED_PORTS[@]}"; do
        echo "Deleting port: $port"
        openstack port delete "$port" 2>/dev/null || true
    done

    # Reset arrays
    CREATED_SERVERS=()
    CREATED_FIPS=()
    CREATED_PORTS=()

    echo "Cleanup complete"
}

# Track if cleanup should run on exit (only on success or Ctrl+C, not on failure)
CLEANUP_ON_EXIT=false

cleanup_on_exit() {
    if [[ "$CLEANUP_ON_EXIT" == "true" ]]; then
        cleanup_iteration
    else
        echo ""
        echo "=== Skipping cleanup to allow troubleshooting ==="
        echo "Resources left for debugging:"
        echo "  Servers: ${CREATED_SERVERS[*]:-none}"
        echo "  Floating IPs: ${CREATED_FIPS[*]:-none}"
        echo "  Ports: ${CREATED_PORTS[*]:-none}"
        echo ""
        echo "To manually cleanup, run:"
        echo "  openstack server list --name 'load-*-iter${ITERATION}'"
        echo "  openstack floating ip list | grep 'load-'"
    fi
}

# Cleanup on Ctrl+C (SIGINT) - always cleanup on interrupt
trap 'CLEANUP_ON_EXIT=true; cleanup_on_exit; exit 130' INT

# On normal exit, use the CLEANUP_ON_EXIT flag
trap cleanup_on_exit EXIT

validate_test_instances() {
    echo "Validating 6 test infrastructure instances..."

    RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -k "$DASHBOARD_URL")
    if [[ -z "$RESPONSE" ]]; then
        echo "ERROR: Failed to reach dashboard"
        return 1
    fi

    HEALTHY_COUNT=$(echo "$RESPONSE" | jq -r '.healthy_count')
    STALE_COUNT=$(echo "$RESPONSE" | jq -r '.stale_count')

    # Check that we have at least 6 healthy test instances
    # Filter for test-snat-* and test-fip-* hostnames
    TEST_INSTANCES=$(echo "$RESPONSE" | jq '[.instances[] | select(.hostname | startswith("test-"))]')
    TEST_HEALTHY=$(echo "$TEST_INSTANCES" | jq '[.[] | select(.is_stale == false)] | length')
    TEST_TOTAL=$(echo "$TEST_INSTANCES" | jq 'length')

    echo "Test instances: $TEST_HEALTHY healthy out of $TEST_TOTAL total"

    if [[ "$TEST_HEALTHY" -lt 6 ]]; then
        echo "ERROR: Expected at least 6 healthy test instances, found $TEST_HEALTHY"
        echo "Stale/unhealthy test instances:"
        echo "$TEST_INSTANCES" | jq -r '.[] | select(.is_stale == true) | "  - \(.hostname) (last seen \(.seconds_ago)s ago)"'
        return 1
    fi

    echo "Test infrastructure validation passed"
    return 0
}

validate_fip_connectivity() {
    local fip_addresses=("$@")
    local max_retries=$PING_RETRIES
    local retry_delay=$PING_RETRY_DELAY

    echo "Validating FIP connectivity..."

    for fip in "${fip_addresses[@]}"; do
        echo -n "  Pinging $fip... "
        local attempt=1
        local success=false

        while [[ $attempt -le $max_retries ]]; do
            if ping -c 3 -W 5 "$fip" &>/dev/null; then
                echo "OK"
                success=true
                break
            else
                if [[ $attempt -lt $max_retries ]]; then
                    echo -n "retry $attempt/$max_retries... "
                    sleep $retry_delay
                fi
                attempt=$((attempt + 1))
            fi
        done

        if [[ "$success" != "true" ]]; then
            echo "FAILED after $max_retries attempts"
            echo "ERROR: Cannot ping floating IP $fip"
            return 1
        fi
    done

    echo "FIP connectivity validation passed"
    return 0
}

run_iteration() {
    ITERATION=$((ITERATION + 1))
    echo ""
    echo "========================================"
    echo "Starting iteration $ITERATION at $(date)"
    echo "========================================"

    # Reset tracking arrays
    CREATED_SERVERS=()
    CREATED_FIPS=()
    CREATED_PORTS=()

    # Step 1: Choose 10 random auto-test networks
    echo ""
    echo "=== Step 1: Selecting random networks ==="
    NETWORK_IDS=($(shuf -i 1-150 -n $NUM_NETWORKS | sort -n))
    echo "Selected networks: ${NETWORK_IDS[*]}"

    # Track FIP addresses for ping validation
    declare -a FIP_ADDRESSES

    # Step 2 & 3: Create instances and assign FIPs
    echo ""
    echo "=== Step 2 & 3: Creating instances ==="

    for NET_ID in "${NETWORK_IDS[@]}"; do
        PRIVATE_NET="auto-test-${NET_ID}-private"
        EXTERNAL_NET="auto-test-${NET_ID}"
        SNAT_NAME="load-snat-${NET_ID}-iter${ITERATION}"
        FIP_NAME="load-fip-${NET_ID}-iter${ITERATION}"
        FIP_PORT="load-fip-port-${NET_ID}-iter${ITERATION}"

        echo ""
        echo "--- Network $NET_ID ---"

        # Create SNAT instance
        echo "Creating SNAT instance: $SNAT_NAME"
        if ! openstack server create \
            --image "$IMAGE" \
            --flavor "$FLAVOR" \
            --key-name "$KEYPAIR" \
            --network "$PRIVATE_NET" \
            "$SNAT_NAME" -f value -c id >/dev/null; then
            echo "ERROR: Failed to create SNAT instance on $PRIVATE_NET"
            return 1
        fi
        CREATED_SERVERS+=("$SNAT_NAME")

        # Create port for FIP instance
        echo "Creating port: $FIP_PORT"
        if ! openstack port create \
            --network "$PRIVATE_NET" \
            "$FIP_PORT" -f value -c id >/dev/null; then
            echo "ERROR: Failed to create port on $PRIVATE_NET"
            return 1
        fi
        CREATED_PORTS+=("$FIP_PORT")

        # Create FIP instance
        echo "Creating FIP instance: $FIP_NAME"
        if ! openstack server create \
            --image "$IMAGE" \
            --flavor "$FLAVOR" \
            --key-name "$KEYPAIR" \
            --port "$FIP_PORT" \
            "$FIP_NAME" -f value -c id >/dev/null; then
            echo "ERROR: Failed to create FIP instance on $PRIVATE_NET"
            return 1
        fi
        CREATED_SERVERS+=("$FIP_NAME")

        # Create and assign floating IP
        echo "Creating floating IP from $EXTERNAL_NET"
        FIP_RESULT=$(openstack floating ip create \
            --port "$FIP_PORT" \
            "$EXTERNAL_NET" \
            -f json 2>&1)

        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to create floating IP from $EXTERNAL_NET"
            echo "$FIP_RESULT"
            return 1
        fi

        FIP_ID=$(echo "$FIP_RESULT" | jq -r '.id')
        FIP_ADDR=$(echo "$FIP_RESULT" | jq -r '.floating_ip_address')
        CREATED_FIPS+=("$FIP_ID")
        FIP_ADDRESSES+=("$FIP_ADDR")
        echo "Assigned floating IP: $FIP_ADDR"
    done

    echo ""
    echo "Created ${#CREATED_SERVERS[@]} servers, ${#CREATED_FIPS[@]} floating IPs"

    # Wait for instances to boot
    echo ""
    echo "=== Waiting for instances to boot (60s) ==="
    sleep 60

    # Step 4: Wait 5 minutes then validate
    echo ""
    echo "=== Step 4: Waiting $WAIT_TIME seconds before validation ==="
    REMAINING=$WAIT_TIME
    while [[ $REMAINING -gt 0 ]]; do
        echo -ne "\r  Time remaining: ${REMAINING}s   "
        sleep 10
        REMAINING=$((REMAINING - 10))
    done
    echo ""

    echo ""
    echo "=== Validation ==="

    # Validate test infrastructure instances
    if ! validate_test_instances; then
        echo ""
        echo "!!! TEST FAILED: Test infrastructure validation failed !!!"
        return 1
    fi

    # Validate FIP connectivity
    if ! validate_fip_connectivity "${FIP_ADDRESSES[@]}"; then
        echo ""
        echo "!!! TEST FAILED: FIP connectivity validation failed !!!"
        return 1
    fi

    echo ""
    echo "=== Iteration $ITERATION PASSED ==="

    # Step 6: Cleanup on success
    CLEANUP_ON_EXIT=true
    cleanup_iteration
    CLEANUP_ON_EXIT=false

    return 0
}

# Main loop
echo "========================================"
echo "OpenStack Load Test Script"
echo "========================================"
echo ""
echo "Configuration:"
echo "  Networks per iteration: $NUM_NETWORKS"
echo "  Instances per iteration: $((NUM_NETWORKS * 2))"
echo "  Wait time: ${WAIT_TIME}s"
echo "  Ping retries: $PING_RETRIES (with ${PING_RETRY_DELAY}s delay)"
echo "  Dashboard: $DASHBOARD_URL"
if [[ $MAX_ITERATIONS -gt 0 ]]; then
    echo "  Max iterations: $MAX_ITERATIONS"
else
    echo "  Max iterations: unlimited"
fi
echo "  Cleanup on failure: NO (resources preserved for troubleshooting)"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Initial validation
echo "=== Initial validation ==="
if ! validate_test_instances; then
    echo "ERROR: Initial validation failed. Ensure test infrastructure is healthy."
    exit 1
fi
echo ""

while true; do
    if ! run_iteration; then
        echo ""
        echo "========================================"
        echo "LOAD TEST FAILED at iteration $ITERATION"
        echo "Time: $(date)"
        echo "========================================"
        CLEANUP_ON_EXIT=false
        exit 1
    fi

    # Check if we've reached max iterations
    if [[ $MAX_ITERATIONS -gt 0 && $ITERATION -ge $MAX_ITERATIONS ]]; then
        echo ""
        echo "========================================"
        echo "LOAD TEST COMPLETED: $ITERATION iterations successful"
        echo "Time: $(date)"
        echo "========================================"
        CLEANUP_ON_EXIT=true
        exit 0
    fi

    echo ""
    echo "Sleeping 10 seconds before next iteration..."
    sleep 10
done
