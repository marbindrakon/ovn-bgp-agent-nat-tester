#!/bin/bash
#
# Cleanup Load Test Resources Script
# Removes leftover load test VMs, floating IPs, and ports
# Does NOT touch permanent test infrastructure (test-* resources)
#

set -uo pipefail

echo "=== Load Test Resource Cleanup ==="
echo ""
echo "This script will remove all load-* resources:"
echo "  - Servers (VMs)"
echo "  - Floating IPs"
echo "  - Ports"
echo ""
echo "Permanent test infrastructure (test-*) will NOT be affected."
echo ""

# Function to cleanup load test servers
cleanup_servers() {
    echo "----------------------------------------"
    echo "Cleaning up load test servers"
    echo "----------------------------------------"

    SERVERS=$(openstack server list -f value -c Name 2>/dev/null | grep '^load-' || true)

    if [[ -z "$SERVERS" ]]; then
        echo "No load test servers found"
        return 0
    fi

    SERVER_COUNT=$(echo "$SERVERS" | wc -l)
    echo "Found $SERVER_COUNT load test servers"

    echo "$SERVERS" | while read -r server; do
        echo "  Deleting server: $server"
        openstack server delete "$server" 2>/dev/null || echo "    Failed to delete $server"
    done

    echo "Waiting for servers to be deleted..."
    sleep 5

    echo "Server cleanup complete"
    echo ""
}

# Function to cleanup load test floating IPs
# Floating IPs don't have names, so we find them by matching their port UUID
# against load-* port UUIDs.
cleanup_floating_ips() {
    echo "----------------------------------------"
    echo "Cleaning up load test floating IPs"
    echo "----------------------------------------"

    # Step 1: Get UUIDs of all load-* ports
    LOAD_PORT_IDS=$(openstack port list -f value -c ID -c Name 2>/dev/null | grep 'load-' | awk '{print $1}' || true)

    if [[ -z "$LOAD_PORT_IDS" ]]; then
        echo "No load test ports found, skipping FIP cleanup"
        return 0
    fi

    # Step 2: Get all floating IPs (ID, address, port UUID)
    ALL_FIPS=$(openstack floating ip list -f value -c ID -c 'Floating IP Address' -c Port 2>/dev/null || true)

    if [[ -z "$ALL_FIPS" ]]; then
        echo "No floating IPs found"
        return 0
    fi

    # Step 3: For each load-* port UUID, find and delete any attached FIP
    DELETED=0
    while read -r port_id; do
        [[ -z "$port_id" ]] && continue
        MATCHED=$(echo "$ALL_FIPS" | grep "$port_id" || true)
        if [[ -n "$MATCHED" ]]; then
            FIP_ID=$(echo "$MATCHED" | awk '{print $1}')
            FIP_ADDR=$(echo "$MATCHED" | awk '{print $2}')
            echo "  Deleting floating IP: $FIP_ADDR ($FIP_ID)"
            openstack floating ip delete "$FIP_ID" 2>/dev/null || echo "    Failed to delete $FIP_ID"
            DELETED=$((DELETED + 1))
        fi
    done <<< "$LOAD_PORT_IDS"

    if [[ $DELETED -eq 0 ]]; then
        echo "No floating IPs found on load test ports"
    else
        echo "Deleted $DELETED floating IPs"
    fi

    echo "Floating IP cleanup complete"
    echo ""
}

# Function to cleanup load test ports
cleanup_ports() {
    echo "----------------------------------------"
    echo "Cleaning up load test ports"
    echo "----------------------------------------"

    PORTS=$(openstack port list -f value -c Name 2>/dev/null | grep '^load-' || true)

    if [[ -z "$PORTS" ]]; then
        echo "No load test ports found"
        return 0
    fi

    PORT_COUNT=$(echo "$PORTS" | wc -l)
    echo "Found $PORT_COUNT load test ports"

    echo "$PORTS" | while read -r port; do
        echo "  Deleting port: $port"
        openstack port delete "$port" 2>/dev/null || echo "    Failed to delete $port"
    done

    echo "Port cleanup complete"
    echo ""
}

# Perform cleanup in correct dependency order
cleanup_floating_ips
cleanup_servers
cleanup_ports

echo "=== Load Test Resource Cleanup Complete ==="
echo ""

# Show remaining load test resources (if any)
REMAINING_SERVERS=$(openstack server list -f value -c Name 2>/dev/null | grep -c '^load-' || true)
REMAINING_PORTS=$(openstack port list -f value -c Name 2>/dev/null | grep -c '^load-' || true)

if [[ $REMAINING_SERVERS -gt 0 ]] || [[ $REMAINING_PORTS -gt 0 ]]; then
    echo "WARNING: Some resources could not be cleaned up:"
    [[ $REMAINING_SERVERS -gt 0 ]] && echo "  - Servers: $REMAINING_SERVERS"
    [[ $REMAINING_PORTS -gt 0 ]] && echo "  - Ports: $REMAINING_PORTS"
    echo ""
    echo "Run this script again or clean up manually."
    exit 1
else
    echo "All load test resources successfully cleaned up."
fi
