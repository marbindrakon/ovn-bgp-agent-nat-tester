#!/bin/bash
#
# OpenStack Test Infrastructure Cleanup Script
# Tears down resources created by setup-test-infra.sh
#
# Usage: ./cleanup-test-infra.sh [--with-auto-test-networks]
#

set -uo pipefail

# Configuration
EXTERNAL_NETWORK="evpn-external"
AVAILABILITY_ZONES=("az1" "az2" "az3")
AUTO_TEST_COUNT=150

# Address scope and subnet pool configuration
ADDRESS_SCOPE_NAME="evpn-100"
SUBNET_POOL_NAME="evpn-100"

# Parse command line arguments
CLEANUP_AUTO_TEST_NETWORKS=false
for arg in "$@"; do
    case $arg in
        --with-auto-test-networks)
            CLEANUP_AUTO_TEST_NETWORKS=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--with-auto-test-networks]"
            echo ""
            echo "Options:"
            echo "  --with-auto-test-networks  Also cleanup auto-test networks (1-${AUTO_TEST_COUNT})"
            echo "  --help, -h                 Show this help message"
            exit 0
            ;;
    esac
done

# Function to cleanup auto-test networks
cleanup_auto_test_networks() {
    echo ""
    echo "========================================"
    echo "Cleaning up Auto-Test Networks (1-${AUTO_TEST_COUNT})"
    echo "========================================"
    echo ""

    for i in $(seq 1 $AUTO_TEST_COUNT); do
        echo "----------------------------------------"
        echo "Cleaning up auto-test-$i"
        echo "----------------------------------------"

        # Remove private subnet from router
        echo "Removing subnet from router"
        openstack router remove subnet "auto-test-$i" "auto-test-$i-private-v4" 2>/dev/null || true

        # Remove external gateway from router
        echo "Removing external gateway from router"
        openstack router unset --external-gateway "auto-test-$i" 2>/dev/null || true

        # Delete router
        echo "Deleting router: auto-test-$i"
        openstack router delete "auto-test-$i" 2>/dev/null || true

        # Delete private subnet
        echo "Deleting private subnet: auto-test-$i-private-v4"
        openstack subnet delete "auto-test-$i-private-v4" 2>/dev/null || true

        # Delete private network
        echo "Deleting private network: auto-test-$i-private"
        openstack network delete "auto-test-$i-private" 2>/dev/null || true

        # Delete external subnet
        echo "Deleting external subnet: auto-test-$i-subnet"
        openstack subnet delete "auto-test-$i-subnet" 2>/dev/null || true

        # Delete external network
        echo "Deleting external network: auto-test-$i"
        openstack network delete "auto-test-$i" 2>/dev/null || true

        echo "Completed cleanup for auto-test-$i"
        echo ""
    done

    echo "========================================"
    echo "Auto-Test Networks Cleanup Complete"
    echo "========================================"
    echo ""
}

# Function to cleanup address scope and subnet pool
cleanup_address_scope_and_subnet_pool() {
    echo ""
    echo "========================================"
    echo "Cleaning up Address Scope and Subnet Pool"
    echo "========================================"
    echo ""

    # Delete subnet pool
    echo "Deleting subnet pool: $SUBNET_POOL_NAME"
    openstack subnet pool delete "$SUBNET_POOL_NAME" 2>/dev/null || true

    # Delete address scope
    echo "Deleting address scope: $ADDRESS_SCOPE_NAME"
    openstack address scope delete "$ADDRESS_SCOPE_NAME" 2>/dev/null || true

    echo ""
    echo "Address scope and subnet pool cleanup complete"
    echo ""
}

echo "=== OpenStack Test Infrastructure Cleanup ==="
if [[ "$CLEANUP_AUTO_TEST_NETWORKS" == "true" ]]; then
    echo "Auto-test network cleanup: ENABLED (1-${AUTO_TEST_COUNT})"
fi
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

# Cleanup auto-test networks if requested
if [[ "$CLEANUP_AUTO_TEST_NETWORKS" == "true" ]]; then
    cleanup_auto_test_networks
    cleanup_address_scope_and_subnet_pool
fi

echo "=== Infrastructure Cleanup Complete ==="
