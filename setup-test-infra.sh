#!/bin/bash
#
# OpenStack Test Infrastructure Setup Script
# Creates networks, routers, and instances across three availability zones
#

set -euo pipefail

# Configuration
EXTERNAL_NETWORK="evpn-external"
IMAGE="fedora-43"
FLAVOR="minimal"
KEYPAIR="aaustin-key"
SUBNET_CIDR="10.0.0.0/24"
DNS_NAMESERVER="172.18.42.10"
AVAILABILITY_ZONES=("az1" "az2" "az3")

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_FILE="${SCRIPT_DIR}/agent/cloud-init-userdata.yaml"

# Verify userdata file exists
if [[ ! -f "$USERDATA_FILE" ]]; then
    echo "ERROR: Cloud-init userdata file not found: $USERDATA_FILE"
    exit 1
fi

echo "=== OpenStack Test Infrastructure Setup ==="
echo "Using cloud-init userdata: $USERDATA_FILE"
echo ""

for AZ in "${AVAILABILITY_ZONES[@]}"; do
    echo "----------------------------------------"
    echo "Setting up infrastructure for $AZ"
    echo "----------------------------------------"

    NETWORK_NAME="test-net-${AZ}"
    SUBNET_NAME="test-subnet-${AZ}"
    ROUTER_NAME="test-router-${AZ}"
    SNAT_VM_NAME="test-snat-${AZ}"
    FIP_VM_NAME="test-fip-${AZ}"
    FIP_PORT_NAME="test-fip-port-${AZ}"

    # Create private network
    echo "Creating network: $NETWORK_NAME"
    openstack network create \
        --availability-zone-hint "$AZ" \
        "$NETWORK_NAME"

    # Create subnet
    echo "Creating subnet: $SUBNET_NAME"
    openstack subnet create \
        --network "$NETWORK_NAME" \
        --subnet-range "$SUBNET_CIDR" \
        --dns-nameserver "$DNS_NAMESERVER" \
        "$SUBNET_NAME"

    # Create router
    echo "Creating router: $ROUTER_NAME"
    openstack router create \
        --availability-zone-hint "$AZ" \
        "$ROUTER_NAME"

    # Set external gateway on router
    echo "Setting external gateway on router"
    openstack router set \
        --external-gateway "$EXTERNAL_NETWORK" \
        "$ROUTER_NAME"

    # Add subnet to router
    echo "Adding subnet to router"
    openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME"

    # Create SNAT test instance with heartbeat agent
    echo "Creating SNAT test instance: $SNAT_VM_NAME"
    openstack server create \
        --image "$IMAGE" \
        --flavor "$FLAVOR" \
        --key-name "$KEYPAIR" \
        --network "$NETWORK_NAME" \
        --availability-zone "$AZ" \
        --user-data "$USERDATA_FILE" \
        "$SNAT_VM_NAME"

    # Create port for FIP test instance (needed to assign floating IP)
    echo "Creating port for FIP test instance: $FIP_PORT_NAME"
    openstack port create \
        --network "$NETWORK_NAME" \
        "$FIP_PORT_NAME"

    # Create FIP test instance using the port with heartbeat agent
    echo "Creating FIP test instance: $FIP_VM_NAME"
    openstack server create \
        --image "$IMAGE" \
        --flavor "$FLAVOR" \
        --key-name "$KEYPAIR" \
        --port "$FIP_PORT_NAME" \
        --availability-zone "$AZ" \
        --user-data "$USERDATA_FILE" \
        "$FIP_VM_NAME"

    # Create and assign floating IP to FIP test instance
    echo "Creating and assigning floating IP to $FIP_VM_NAME"
    FLOATING_IP=$(openstack floating ip create \
        --port "$FIP_PORT_NAME" \
        "$EXTERNAL_NETWORK" \
        -f value -c floating_ip_address)
    echo "Assigned floating IP: $FLOATING_IP to $FIP_VM_NAME"

    echo ""
    echo "Completed setup for $AZ"
    echo ""
done

echo "=== Infrastructure Setup Complete ==="
echo ""
echo "Summary of created resources:"
echo ""

for AZ in "${AVAILABILITY_ZONES[@]}"; do
    echo "$AZ:"
    echo "  Network: test-net-${AZ}"
    echo "  Subnet: test-subnet-${AZ} (${SUBNET_CIDR})"
    echo "  Router: test-router-${AZ} -> ${EXTERNAL_NETWORK}"
    echo "  SNAT VM: test-snat-${AZ} (with heartbeat agent)"
    echo "  FIP VM: test-fip-${AZ} (with heartbeat agent)"
    echo ""
done

echo "All VMs are configured with the heartbeat agent."
echo "Monitor instances at: https://snat-heartbeat.apps.lab-hub.lab.signal9.gg"
