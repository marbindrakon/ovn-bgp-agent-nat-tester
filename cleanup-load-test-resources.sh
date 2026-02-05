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

    SERVERS=$(openstack server list --name 'load-' -f value -c Name 2>/dev/null)

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
cleanup_floating_ips() {
    echo "----------------------------------------"
    echo "Cleaning up load test floating IPs"
    echo "----------------------------------------"

    # Get all floating IPs and filter for those associated with load-* ports
    FIPS=$(openstack floating ip list -f json 2>/dev/null | \
           jq -r '.[] | select(.Port != null) | select(.Port | contains("load-")) | .ID' 2>/dev/null)

    if [[ -z "$FIPS" ]]; then
        echo "No load test floating IPs found"
        return 0
    fi

    FIP_COUNT=$(echo "$FIPS" | wc -l)
    echo "Found $FIP_COUNT load test floating IPs"

    echo "$FIPS" | while read -r fip_id; do
        FIP_ADDR=$(openstack floating ip show "$fip_id" -f value -c floating_ip_address 2>/dev/null)
        echo "  Deleting floating IP: $FIP_ADDR ($fip_id)"
        openstack floating ip delete "$fip_id" 2>/dev/null || echo "    Failed to delete $fip_id"
    done

    echo "Floating IP cleanup complete"
    echo ""
}

# Function to cleanup load test ports
cleanup_ports() {
    echo "----------------------------------------"
    echo "Cleaning up load test ports"
    echo "----------------------------------------"

    PORTS=$(openstack port list --name 'load-' -f value -c Name 2>/dev/null)

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
REMAINING_SERVERS=$(openstack server list --name 'load-' -f value -c Name 2>/dev/null | wc -l)
REMAINING_PORTS=$(openstack port list --name 'load-' -f value -c Name 2>/dev/null | wc -l)
REMAINING_FIPS=$(openstack floating ip list -f json 2>/dev/null | \
                 jq -r '.[] | select(.Port != null) | select(.Port | contains("load-")) | .ID' 2>/dev/null | wc -l)

if [[ $REMAINING_SERVERS -gt 0 ]] || [[ $REMAINING_PORTS -gt 0 ]] || [[ $REMAINING_FIPS -gt 0 ]]; then
    echo "WARNING: Some resources could not be cleaned up:"
    [[ $REMAINING_SERVERS -gt 0 ]] && echo "  - Servers: $REMAINING_SERVERS"
    [[ $REMAINING_FIPS -gt 0 ]] && echo "  - Floating IPs: $REMAINING_FIPS"
    [[ $REMAINING_PORTS -gt 0 ]] && echo "  - Ports: $REMAINING_PORTS"
    echo ""
    echo "Run this script again or clean up manually."
    exit 1
else
    echo "All load test resources successfully cleaned up."
fi
