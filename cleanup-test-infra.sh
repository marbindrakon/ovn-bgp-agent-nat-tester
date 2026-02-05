#!/bin/bash
#
# OpenStack Test Infrastructure Cleanup Script
# Tears down resources created by setup-test-infra.sh
#

set -uo pipefail

# Configuration
EXTERNAL_NETWORK="evpn-external"
AVAILABILITY_ZONES=("az1" "az2" "az3")

echo "=== OpenStack Test Infrastructure Cleanup ==="
echo ""

for AZ in "${AVAILABILITY_ZONES[@]}"; do
    echo "----------------------------------------"
    echo "Cleaning up infrastructure for $AZ"
    echo "----------------------------------------"

    NETWORK_NAME="test-net-${AZ}"
    SUBNET_NAME="test-subnet-${AZ}"
    ROUTER_NAME="test-router-${AZ}"
    SNAT_VM_NAME="test-snat-${AZ}"
    FIP_VM_NAME="test-fip-${AZ}"
    FIP_PORT_NAME="test-fip-port-${AZ}"

    # Delete floating IPs associated with the FIP port
    echo "Deleting floating IPs for $FIP_PORT_NAME"
    FIP_PORT_ID=$(openstack port show "$FIP_PORT_NAME" -f value -c id 2>/dev/null || true)
    if [[ -n "$FIP_PORT_ID" ]]; then
        FLOATING_IPS=$(openstack floating ip list --port "$FIP_PORT_ID" -f value -c ID 2>/dev/null || true)
        for FIP_ID in $FLOATING_IPS; do
            echo "  Deleting floating IP: $FIP_ID"
            openstack floating ip delete "$FIP_ID" || true
        done
    fi

    # Delete servers
    echo "Deleting server: $SNAT_VM_NAME"
    openstack server delete --wait "$SNAT_VM_NAME" 2>/dev/null || true

    echo "Deleting server: $FIP_VM_NAME"
    openstack server delete --wait "$FIP_VM_NAME" 2>/dev/null || true

    # Delete the FIP port
    echo "Deleting port: $FIP_PORT_NAME"
    openstack port delete "$FIP_PORT_NAME" 2>/dev/null || true

    # Remove subnet from router
    echo "Removing subnet from router: $ROUTER_NAME"
    openstack router remove subnet "$ROUTER_NAME" "$SUBNET_NAME" 2>/dev/null || true

    # Remove external gateway from router
    echo "Removing external gateway from router: $ROUTER_NAME"
    openstack router unset --external-gateway "$ROUTER_NAME" 2>/dev/null || true

    # Delete router
    echo "Deleting router: $ROUTER_NAME"
    openstack router delete "$ROUTER_NAME" 2>/dev/null || true

    # Delete subnet
    echo "Deleting subnet: $SUBNET_NAME"
    openstack subnet delete "$SUBNET_NAME" 2>/dev/null || true

    # Delete network
    echo "Deleting network: $NETWORK_NAME"
    openstack network delete "$NETWORK_NAME" 2>/dev/null || true

    echo ""
    echo "Completed cleanup for $AZ"
    echo ""
done

echo "=== Infrastructure Cleanup Complete ==="
