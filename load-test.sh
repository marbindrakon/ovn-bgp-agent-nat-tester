#!/bin/bash
#
# OpenStack Load Test Script
# Creates instances on random auto-test networks to induce load,
# validates test infrastructure, then cleans up and repeats.
#
# Two test modes:
#   workload - Churns VMs on existing auto-test-1..150 networks (default)
#   network  - Creates and tears down EVPN-wired networks each iteration
#
# Usage: ./load-test.sh [OPTIONS]
#   -m, --mode MODE          Test mode: 'workload' or 'network' (default: workload)
#   -n, --networks NUM       Networks per iteration (default: 10)
#   -i, --iterations NUM     Max iterations, 0=unlimited (default: 0)
#   -w, --wait SECONDS       Wait time before validation (default: 300)
#   -h, --help               Show this help message
#

set -uo pipefail

# Source local configuration (API keys, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-config.env
source "${SCRIPT_DIR}/local-config.env"

# Configuration
IMAGE="fedora-43"
FLAVOR="minimal"
KEYPAIR="aaustin-key"
DASHBOARD_URL="https://snat-heartbeat.apps.lab-hub.lab.signal9.gg"
DASHBOARD_API_URL="${DASHBOARD_URL}/api/instances"
DASHBOARD_STATUS_URL="${DASHBOARD_URL}/api/load-test/status"
DASHBOARD_API_KEY="${DASHBOARD_API_KEY:?DASHBOARD_API_KEY must be set}"
USERDATA_FILE="./agent/cloud-init-userdata.yaml"
DNS_NAMESERVER="172.18.42.10"
EPHEMERAL_STALE_THRESHOLD=180  # 3 minutes (for validation)

# Defaults (overridable by arguments)
TEST_MODE="workload"
NUM_NETWORKS=10
MAX_ITERATIONS=0  # 0 means unlimited
WAIT_TIME=300     # 5 minutes
ITERATION=0

# Network mode configuration (from setup-test-infra.sh)
AUTO_TEST_PROVIDER_NETWORK="bgp-physnet"
AUTO_TEST_SUBNET_POOL="evpn-100"
AUTO_TEST_PRIVATE_CIDR="10.100.0.0/24"
AUTO_TEST_MTU=1500
AUTO_TEST_VNI=100

# OVN configuration for EVPN
NBCTL_POD="ovn-northd-0"
OVN_DB_SERVERS="ssl:ovsdbserver-nb-0.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-1.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-2.openstack.svc.cluster.local:6641"
OVN_CERT="/etc/pki/tls/certs/ovndb.crt"
OVN_KEY="/etc/pki/tls/private/ovndb.key"
OVN_CA="/etc/pki/tls/certs/ovndbca.crt"

# --- Argument Parsing ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -m, --mode MODE          Test mode: 'workload' or 'network' (default: workload)
  -n, --networks NUM       Networks per iteration (default: 10)
  -i, --iterations NUM     Max iterations, 0=unlimited (default: 0)
  -w, --wait SECONDS       Wait time before validation (default: 300)
  -h, --help               Show this help message

Test Modes:
  workload   Picks random networks from the existing auto-test-1..150 pool,
             creates SNAT + FIP instances, validates heartbeats, cleans up.
  network    Creates fresh EVPN-wired networks each iteration, creates SNAT +
             FIP instances, validates heartbeats, tears down everything.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            TEST_MODE="$2"
            shift 2
            ;;
        -n|--networks)
            NUM_NETWORKS="$2"
            shift 2
            ;;
        -i|--iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_TIME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1
            ;;
    esac
done

# Validate test mode
if [[ "$TEST_MODE" != "workload" && "$TEST_MODE" != "network" ]]; then
    echo "ERROR: Invalid test mode '$TEST_MODE'. Must be 'workload' or 'network'."
    exit 1
fi

# Verify userdata file exists
if [[ ! -f "$USERDATA_FILE" ]]; then
    echo "ERROR: Userdata file not found: $USERDATA_FILE"
    exit 1
fi

# Template the API key into userdata for VM cloud-init
USERDATA_RENDERED=$(mktemp /tmp/cloud-init-userdata.XXXXXX.yaml)
trap 'rm -f "$USERDATA_RENDERED"' EXIT
sed "s|@@DASHBOARD_API_KEY@@|${DASHBOARD_API_KEY}|g" "$USERDATA_FILE" > "$USERDATA_RENDERED"
USERDATA_FILE="$USERDATA_RENDERED"

# In network mode, verify OVN NB pod is reachable
if [[ "$TEST_MODE" == "network" ]]; then
    echo "Verifying OVN NB pod ($NBCTL_POD) is reachable..."
    if ! oc exec "$NBCTL_POD" -- ovn-nbctl --db="$OVN_DB_SERVERS" \
        --certificate="$OVN_CERT" --private-key="$OVN_KEY" --ca-cert="$OVN_CA" \
        get-connection 2>/dev/null; then
        echo "ERROR: Cannot reach OVN NB pod '$NBCTL_POD'. Network mode requires OVN access."
        echo "Verify 'oc exec $NBCTL_POD' works and OVN DB is accessible."
        exit 1
    fi
    echo "OVN NB pod reachable"
    echo ""
fi

report_status() {
    local status="$1"
    local phase="${2:-}"
    local iteration="${3:-$ITERATION}"
    local max_iter="${4:-$MAX_ITERATIONS}"
    shift 4 2>/dev/null || true
    local failed_vms=("$@")

    local vms_json="[]"
    if [[ ${#failed_vms[@]} -gt 0 ]]; then
        vms_json=$(printf '%s\n' "${failed_vms[@]}" | jq -R . | jq -s .)
    fi

    local json
    json=$(jq -n \
        --arg status "$status" \
        --arg phase "$phase" \
        --arg test_mode "$TEST_MODE" \
        --argjson iteration "$iteration" \
        --argjson max_iterations "$max_iter" \
        --argjson failed_vms "$vms_json" \
        '{status: $status, phase: $phase, test_mode: $test_mode, iteration: $iteration, max_iterations: $max_iterations, failed_vms: $failed_vms}')

    curl -s -k -X POST -H 'Content-Type: application/json' \
        -H "X-API-Key: ${DASHBOARD_API_KEY}" \
        -d "$json" "$DASHBOARD_STATUS_URL" >/dev/null 2>&1 || true
}

# --- OVN Helper ---
ovn_nbctl() {
    oc exec "$NBCTL_POD" -- ovn-nbctl \
        --db="$OVN_DB_SERVERS" \
        --certificate="$OVN_CERT" \
        --private-key="$OVN_KEY" \
        --ca-cert="$OVN_CA" \
        "$@"
}

# --- Network Mode Functions ---

# Creates one EVPN-wired network set (external net, subnet, OVN EVPN config,
# router, private net, private subnet, router attachment).
# Args: $1 = name prefix (e.g. "load-net-iter1-3")
create_network_set() {
    local prefix="$1"

    echo "Creating network set: $prefix"

    # Create external network with VLAN provider
    echo "  Creating external network: $prefix"
    openstack network create \
        --external \
        --mtu "$AUTO_TEST_MTU" \
        --provider-physical-network "$AUTO_TEST_PROVIDER_NETWORK" \
        --provider-network-type vlan \
        "$prefix"

    # Create subnet from pool
    echo "  Creating subnet: ${prefix}-subnet"
    openstack subnet create \
        --network "$prefix" \
        --subnet-pool "$AUTO_TEST_SUBNET_POOL" \
        --dns-nameserver "$DNS_NAMESERVER" \
        "${prefix}-subnet"

    # Get network UUID for OVN configuration
    local net_uuid
    net_uuid=$(openstack network show -f value -c id "$prefix")

    # Configure EVPN on OVN logical switch
    echo "  Configuring EVPN on logical switch"
    ovn_nbctl set logical-switch "$net_uuid" 'external_ids:neutron_bgpvpn\:type=l3'
    ovn_nbctl set logical-switch "$net_uuid" "external_ids:neutron_bgpvpn\:vni=${AUTO_TEST_VNI}"

    # Create router with external gateway
    echo "  Creating router: ${prefix/load-net-/load-router-}"
    openstack router create \
        --external-gateway "$prefix" \
        "${prefix/load-net-/load-router-}"

    # Create private network
    echo "  Creating private network: ${prefix}-private"
    openstack network create "${prefix}-private"

    # Create private subnet
    echo "  Creating private subnet: ${prefix}-private-v4"
    openstack subnet create \
        --network "${prefix}-private" \
        --subnet-range "$AUTO_TEST_PRIVATE_CIDR" \
        --dns-nameserver "$DNS_NAMESERVER" \
        "${prefix}-private-v4"

    # Attach private subnet to router
    echo "  Attaching subnet to router"
    openstack router add subnet "${prefix/load-net-/load-router-}" "${prefix}-private-v4"

    echo "  Network set $prefix complete"
}

# Tears down one network set in reverse order.
# Args: $1 = name prefix (e.g. "load-net-iter1-3")
cleanup_network_set() {
    local prefix="$1"
    local router="${prefix/load-net-/load-router-}"

    echo "Cleaning up network set: $prefix"

    # Detach private subnet from router
    echo "  Detaching subnet from router"
    openstack router remove subnet "$router" "${prefix}-private-v4" 2>/dev/null || true

    # Delete router
    echo "  Deleting router: $router"
    openstack router delete "$router" 2>/dev/null || true

    # Delete private subnet
    echo "  Deleting private subnet: ${prefix}-private-v4"
    openstack subnet delete "${prefix}-private-v4" 2>/dev/null || true

    # Delete private network
    echo "  Deleting private network: ${prefix}-private"
    openstack network delete "${prefix}-private" 2>/dev/null || true

    # Delete external subnet
    echo "  Deleting external subnet: ${prefix}-subnet"
    openstack subnet delete "${prefix}-subnet" 2>/dev/null || true

    # Delete external network
    echo "  Deleting external network: $prefix"
    openstack network delete "$prefix" 2>/dev/null || true

    echo "  Network set $prefix cleanup complete"
}

# Track created networks for cleanup
declare -a CREATED_NETWORKS

# Creates NUM_NETWORKS network sets for the current iteration.
create_iteration_networks() {
    CREATED_NETWORKS=()

    echo ""
    echo "=== Creating $NUM_NETWORKS network sets for iteration $ITERATION ==="

    for idx in $(seq 1 "$NUM_NETWORKS"); do
        local prefix="load-net-iter${ITERATION}-${idx}"
        if ! create_network_set "$prefix"; then
            echo "ERROR: Failed to create network set $prefix"
            return 1
        fi
        CREATED_NETWORKS+=("$prefix")
        echo ""
    done

    echo "Created ${#CREATED_NETWORKS[@]} network sets"
}

# Cleans up all networks created for the current iteration.
cleanup_iteration_networks() {
    if [[ ${#CREATED_NETWORKS[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo "=== Cleaning up iteration network sets ==="

    for prefix in "${CREATED_NETWORKS[@]}"; do
        cleanup_network_set "$prefix"
    done

    CREATED_NETWORKS=()
    echo "Network cleanup complete"
}

# --- Stale Route Check (network mode only) ---
# One networker node per AZ to check for stale routes
NETWORKER_NODES=(
    "172.18.158.8"    # az1-networker-0
    "172.18.158.74"   # az2-networker-0
    "172.18.158.136"  # az3-networker-0
)
NETWORKER_NAMES=(
    "az1-networker-0"
    "az2-networker-0"
    "az3-networker-0"
)
SUBNET_POOL_PREFIX="10.42."
SSH_KEY="$HOME/oso-ssh"

check_stale_routes() {
    echo ""
    echo "=== Checking for stale routes (subnet pool prefix ${SUBNET_POOL_PREFIX}0.0/16) ==="

    local found_stale=false

    for i in "${!NETWORKER_NODES[@]}"; do
        local node_ip="${NETWORKER_NODES[$i]}"
        local node_name="${NETWORKER_NAMES[$i]}"

        echo "  Checking $node_name ($node_ip)..."
        local routes
        routes=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "cloud-admin@${node_ip}" \
            "sudo ip route show vrf vrf-100" 2>/dev/null | grep "$SUBNET_POOL_PREFIX" || true)

        if [[ -n "$routes" ]]; then
            echo "  STALE ROUTES FOUND on $node_name:"
            echo "$routes" | sed 's/^/    /'
            found_stale=true
        else
            echo "  $node_name: clean"
        fi
    done

    if [[ "$found_stale" == "true" ]]; then
        echo ""
        echo "ERROR: Stale routes detected using the evpn-100 subnet pool prefix (${SUBNET_POOL_PREFIX}0.0/16)."
        echo "Please ensure there are no manually-created subnets using the evpn-100 subnet pool,"
        echo "then clean up stale routes before running the network-mode load test."
        echo "See CLAUDE_TROUBLESHOOTING.md for stale route cleanup procedures."
        return 1
    fi

    echo "  No stale routes found"
    return 0
}

# Track created resources for cleanup
declare -a CREATED_SERVERS
declare -a CREATED_FIPS
declare -a CREATED_PORTS

clear_dashboard_instances() {
    local prefix="$1"
    echo "Clearing dashboard instances matching prefix: $prefix"
    local result
    result=$(curl -s -k -X DELETE -H "X-API-Key: ${DASHBOARD_API_KEY}" "${DASHBOARD_API_URL}?hostname_prefix=${prefix}" 2>/dev/null) || true
    local count
    count=$(echo "$result" | jq -r '.removed_count // 0' 2>/dev/null) || count=0
    echo "Removed $count instances from dashboard"
}

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

    # Clear ephemeral instances from dashboard after deleting VMs, so they don't look like false failures
    clear_dashboard_instances "load-"

    # Reset arrays
    CREATED_SERVERS=()
    CREATED_FIPS=()
    CREATED_PORTS=()

    echo "Cleanup complete"

    # In network mode, also tear down the networks
    if [[ "$TEST_MODE" == "network" ]]; then
        cleanup_iteration_networks
    fi
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
        if [[ "$TEST_MODE" == "network" && ${#CREATED_NETWORKS[@]} -gt 0 ]]; then
            echo "  Networks: ${CREATED_NETWORKS[*]}"
        fi
        echo ""
        echo "To manually cleanup, run:"
        echo "  ./cleanup-load-test-resources.sh"
    fi
}

# Cleanup on Ctrl+C (SIGINT) - always cleanup on interrupt
trap 'report_status "idle" ""; CLEANUP_ON_EXIT=true; cleanup_on_exit; exit 130' INT

# On normal exit, use the CLEANUP_ON_EXIT flag
trap cleanup_on_exit EXIT

validate_test_instances() {
    echo "Validating 6 test infrastructure instances..."

    RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -k "$DASHBOARD_API_URL")
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

validate_ephemeral_instances() {
    local expected_count=$1
    echo "Validating ephemeral load test instances via dashboard..."

    RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -k "$DASHBOARD_API_URL?type=ephemeral&hostname_prefix=load-")
    if [[ -z "$RESPONSE" ]]; then
        echo "ERROR: Failed to reach dashboard"
        return 1
    fi

    # Filter for instances from current iteration
    LOAD_INSTANCES=$(echo "$RESPONSE" | jq "[.instances[] | select(.hostname | contains(\"-iter${ITERATION}\"))]")
    LOAD_TOTAL=$(echo "$LOAD_INSTANCES" | jq 'length')
    LOAD_HEALTHY=$(echo "$LOAD_INSTANCES" | jq '[.[] | select(.is_stale == false)] | length')
    LOAD_STALE=$(echo "$LOAD_INSTANCES" | jq '[.[] | select(.is_stale == true)] | length')

    echo "Ephemeral instances (iter${ITERATION}): $LOAD_HEALTHY healthy, $LOAD_STALE stale, $LOAD_TOTAL total (expected: $expected_count)"

    # Check if all expected instances are present
    if [[ "$LOAD_TOTAL" -lt "$expected_count" ]]; then
        echo "ERROR: Expected $expected_count instances, found only $LOAD_TOTAL"
        echo "Missing instances may not have sent heartbeats yet"
        return 1
    fi

    # Check if all instances are healthy (not stale per 3-minute threshold)
    if [[ "$LOAD_HEALTHY" -lt "$expected_count" ]]; then
        echo "ERROR: Expected $expected_count healthy instances, found only $LOAD_HEALTHY"
        echo "Stale/unhealthy ephemeral instances:"
        echo "$LOAD_INSTANCES" | jq -r '.[] | select(.is_stale == true) | "  - \(.hostname) (last seen \(.seconds_ago)s ago)"'
        return 1
    fi

    echo "Ephemeral instance validation passed"
    return 0
}

# Create VMs on a list of network identifiers.
# In workload mode, identifiers are auto-test network IDs (numbers).
# In network mode, identifiers are network prefixes (load-net-iter1-3).
# Args: array of network identifiers via ITERATION_NETWORK_IDS
create_vms_on_networks() {
    for NET_ID in "${ITERATION_NETWORK_IDS[@]}"; do
        if [[ "$TEST_MODE" == "workload" ]]; then
            PRIVATE_NET="auto-test-${NET_ID}-private"
            EXTERNAL_NET="auto-test-${NET_ID}"
            SNAT_NAME="load-snat-${NET_ID}-iter${ITERATION}"
            FIP_NAME="load-fip-${NET_ID}-iter${ITERATION}"
            FIP_PORT="load-fip-port-${NET_ID}-iter${ITERATION}"
        else
            # network mode: NET_ID is a prefix like "load-net-iter1-3"
            PRIVATE_NET="${NET_ID}-private"
            EXTERNAL_NET="$NET_ID"
            # Extract the index portion for naming (e.g. "iter1-3")
            local suffix="${NET_ID#load-net-}"
            SNAT_NAME="load-snat-${suffix}"
            FIP_NAME="load-fip-${suffix}"
            FIP_PORT="load-fip-port-${suffix}"
        fi

        echo ""
        echo "--- Network: $NET_ID ---"

        # Create SNAT instance
        echo "Creating SNAT instance: $SNAT_NAME"
        if ! openstack server create \
            --image "$IMAGE" \
            --flavor "$FLAVOR" \
            --key-name "$KEYPAIR" \
            --network "$PRIVATE_NET" \
            --user-data "$USERDATA_FILE" \
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
            --user-data "$USERDATA_FILE" \
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
        echo "Assigned floating IP: $FIP_ADDR"

        # Create provider-network (external) instance
        if [[ "$TEST_MODE" == "workload" ]]; then
            EXT_NAME="load-ext-${NET_ID}-iter${ITERATION}"
            EXT_PORT="load-ext-port-${NET_ID}-iter${ITERATION}"
        else
            local ext_suffix="${NET_ID#load-net-}"
            EXT_NAME="load-ext-${ext_suffix}"
            EXT_PORT="load-ext-port-${ext_suffix}"
        fi

        echo "Creating port on external network: $EXT_PORT"
        if ! openstack port create \
            --network "$EXTERNAL_NET" \
            "$EXT_PORT" -f value -c id >/dev/null; then
            echo "ERROR: Failed to create port on $EXTERNAL_NET"
            return 1
        fi
        CREATED_PORTS+=("$EXT_PORT")

        echo "Creating provider-network instance: $EXT_NAME"
        if ! openstack server create \
            --image "$IMAGE" \
            --flavor "$FLAVOR" \
            --key-name "$KEYPAIR" \
            --port "$EXT_PORT" \
            --user-data "$USERDATA_FILE" \
            "$EXT_NAME" -f value -c id >/dev/null; then
            echo "ERROR: Failed to create provider-network instance on $EXTERNAL_NET"
            return 1
        fi
        CREATED_SERVERS+=("$EXT_NAME")
    done
}

collect_failed_vms() {
    local -n _failed_vms=$1
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -k "$DASHBOARD_API_URL?type=ephemeral&hostname_prefix=load-")
    if [[ -n "$RESPONSE" ]]; then
        # Stale instances
        while IFS= read -r vm; do
            [[ -n "$vm" ]] && _failed_vms+=("$vm")
        done < <(echo "$RESPONSE" | jq -r "[.instances[] | select(.hostname | contains(\"-iter${ITERATION}\")) | select(.is_stale == true)] | .[].hostname")
    fi
    # Also find expected instances that never reported at all
    for NET_ID in "${ITERATION_NETWORK_IDS[@]}"; do
        if [[ "$TEST_MODE" == "workload" ]]; then
            local snat_name="load-snat-${NET_ID}-iter${ITERATION}"
            local fip_name="load-fip-${NET_ID}-iter${ITERATION}"
            local ext_name="load-ext-${NET_ID}-iter${ITERATION}"
        else
            local suffix="${NET_ID#load-net-}"
            local snat_name="load-snat-${suffix}"
            local fip_name="load-fip-${suffix}"
            local ext_name="load-ext-${suffix}"
        fi
        for expected_name in "$snat_name" "$fip_name" "$ext_name"; do
            if [[ -n "$RESPONSE" ]] && ! echo "$RESPONSE" | jq -e ".instances[] | select(.hostname == \"$expected_name\")" >/dev/null 2>&1; then
                _failed_vms+=("$expected_name (no heartbeat)")
            fi
        done
    done
}

run_iteration() {
    ITERATION=$((ITERATION + 1))
    echo ""
    echo "========================================"
    echo "Starting iteration $ITERATION at $(date) [mode: $TEST_MODE]"
    echo "========================================"

    # Reset tracking arrays
    CREATED_SERVERS=()
    CREATED_FIPS=()
    CREATED_PORTS=()
    CREATED_NETWORKS=()

    # Build the list of networks to use this iteration
    declare -a ITERATION_NETWORK_IDS

    if [[ "$TEST_MODE" == "workload" ]]; then
        # Workload mode: pick random auto-test networks
        report_status "running" "selecting_networks" "$ITERATION" "$MAX_ITERATIONS"
        echo ""
        echo "=== Step 1: Selecting random networks ==="
        ITERATION_NETWORK_IDS=($(shuf -i 1-150 -n "$NUM_NETWORKS" | sort -n))
        echo "Selected networks: ${ITERATION_NETWORK_IDS[*]}"
    else
        # Network mode: check for stale routes before proceeding
        report_status "running" "stale_route_check" "$ITERATION" "$MAX_ITERATIONS"
        if ! check_stale_routes; then
            FAILED_VMS=("stale-routes-detected")
            report_status "failed" "stale_route_check" "$ITERATION" "$MAX_ITERATIONS" "${FAILED_VMS[@]}"
            return 1
        fi

        # Network mode: create fresh networks
        report_status "running" "creating_networks" "$ITERATION" "$MAX_ITERATIONS"
        if ! create_iteration_networks; then
            echo "ERROR: Failed to create iteration networks"
            return 1
        fi
        ITERATION_NETWORK_IDS=("${CREATED_NETWORKS[@]}")
    fi

    # Create instances on selected/created networks
    report_status "running" "creating_vms" "$ITERATION" "$MAX_ITERATIONS"
    echo ""
    echo "=== Creating instances ==="

    if ! create_vms_on_networks; then
        return 1
    fi

    echo ""
    echo "Created ${#CREATED_SERVERS[@]} servers, ${#CREATED_FIPS[@]} floating IPs"

    # Wait for instances to boot
    report_status "running" "booting" "$ITERATION" "$MAX_ITERATIONS"
    echo ""
    echo "=== Waiting for instances to boot (60s) ==="
    sleep 60

    # Wait then validate
    report_status "running" "waiting" "$ITERATION" "$MAX_ITERATIONS"
    echo ""
    echo "=== Waiting $WAIT_TIME seconds before validation ==="
    REMAINING=$WAIT_TIME
    while [[ $REMAINING -gt 0 ]]; do
        echo -ne "\r  Time remaining: ${REMAINING}s   "
        sleep 10
        REMAINING=$((REMAINING - 10))
    done
    echo ""

    report_status "running" "validating" "$ITERATION" "$MAX_ITERATIONS"
    echo ""
    echo "=== Validation ==="

    # Validate test infrastructure instances
    FAILED_VMS=()
    if ! validate_test_instances; then
        echo ""
        echo "!!! TEST FAILED: Test infrastructure validation failed !!!"
        # Collect stale test instance names
        RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -k "$DASHBOARD_API_URL")
        if [[ -n "$RESPONSE" ]]; then
            while IFS= read -r vm; do
                [[ -n "$vm" ]] && FAILED_VMS+=("$vm")
            done < <(echo "$RESPONSE" | jq -r '.instances[] | select(.hostname | startswith("test-")) | select(.is_stale == true) | .hostname')
        fi
        report_status "failed" "validating" "$ITERATION" "$MAX_ITERATIONS" "${FAILED_VMS[@]}"
        return 1
    fi

    # Validate ephemeral load test instances via dashboard
    EXPECTED_INSTANCES=$((NUM_NETWORKS * 3))
    if ! validate_ephemeral_instances "$EXPECTED_INSTANCES"; then
        echo ""
        echo "!!! TEST FAILED: Ephemeral instance validation failed !!!"
        collect_failed_vms FAILED_VMS
        report_status "failed" "validating" "$ITERATION" "$MAX_ITERATIONS" "${FAILED_VMS[@]}"
        return 1
    fi

    echo ""
    echo "=== Iteration $ITERATION PASSED ==="

    # Cleanup on success
    report_status "running" "cleanup" "$ITERATION" "$MAX_ITERATIONS"
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
echo "  Test mode: $TEST_MODE"
echo "  Networks per iteration: $NUM_NETWORKS"
echo "  Instances per iteration: $((NUM_NETWORKS * 3))"
echo "  Wait time: ${WAIT_TIME}s"
echo "  Ephemeral stale threshold: ${EPHEMERAL_STALE_THRESHOLD}s"
echo "  Dashboard API: $DASHBOARD_API_URL"
echo "  Dashboard status: $DASHBOARD_STATUS_URL"
echo "  Userdata file: $USERDATA_FILE"
if [[ $MAX_ITERATIONS -gt 0 ]]; then
    echo "  Max iterations: $MAX_ITERATIONS"
else
    echo "  Max iterations: unlimited"
fi
echo "  Cleanup on failure: NO (resources preserved for troubleshooting)"
if [[ "$TEST_MODE" == "network" ]]; then
    echo ""
    echo "Network mode settings:"
    echo "  Provider network: $AUTO_TEST_PROVIDER_NETWORK"
    echo "  Subnet pool: $AUTO_TEST_SUBNET_POOL"
    echo "  Private CIDR: $AUTO_TEST_PRIVATE_CIDR"
    echo "  MTU: $AUTO_TEST_MTU"
fi
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
        report_status "completed" "" "$ITERATION" "$MAX_ITERATIONS"
        CLEANUP_ON_EXIT=true
        exit 0
    fi

    echo ""
    echo "Sleeping 10 seconds before next iteration..."
    sleep 10
done
