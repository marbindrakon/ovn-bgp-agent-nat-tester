#!/bin/bash
#
# OpenStack Test Infrastructure Setup Script
# Creates networks, routers, and instances across three availability zones
#
# Usage: ./setup-test-infra.sh [--with-auto-test-networks]
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

# Auto-test network configuration
AUTO_TEST_COUNT=150
AUTO_TEST_PROVIDER_NETWORK="bgp-physnet"
AUTO_TEST_SUBNET_POOL="evpn-100"
AUTO_TEST_PRIVATE_CIDR="10.100.0.0/24"
AUTO_TEST_MTU=1500

# Address scope and subnet pool configuration
ADDRESS_SCOPE_NAME="evpn-100"
SUBNET_POOL_NAME="evpn-100"
SUBNET_POOL_PREFIXES="10.42.0.0/16"
SUBNET_POOL_DEFAULT_PREFIX_LEN=28
SUBNET_POOL_MIN_PREFIX_LEN=8
SUBNET_POOL_MAX_PREFIX_LEN=32

# OVN configuration for EVPN
NBCTL_POD="ovn-northd-0"
OVN_DB_SERVERS="ssl:ovsdbserver-nb-0.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-1.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-2.openstack.svc.cluster.local:6641"
OVN_CERT="/etc/pki/tls/certs/ovndb.crt"
OVN_KEY="/etc/pki/tls/private/ovndb.key"
OVN_CA="/etc/pki/tls/certs/ovndbca.crt"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_FILE="${SCRIPT_DIR}/agent/cloud-init-userdata.yaml"

# Parse command line arguments
CREATE_AUTO_TEST_NETWORKS=false
for arg in "$@"; do
    case $arg in
        --with-auto-test-networks)
            CREATE_AUTO_TEST_NETWORKS=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--with-auto-test-networks]"
            echo ""
            echo "Options:"
            echo "  --with-auto-test-networks  Create auto-test networks (1-${AUTO_TEST_COUNT})"
            echo "                             with EVPN configuration"
            echo "  --help, -h                 Show this help message"
            exit 0
            ;;
    esac
done

# Function to run OVN nbctl commands
ovn_nbctl() {
    oc exec "$NBCTL_POD" -- ovn-nbctl \
        --db="$OVN_DB_SERVERS" \
        --certificate="$OVN_CERT" \
        --private-key="$OVN_KEY" \
        --ca-cert="$OVN_CA" \
        "$@"
}

# Function to create address scope and subnet pool
create_address_scope_and_subnet_pool() {
    echo ""
    echo "========================================"
    echo "Creating Address Scope and Subnet Pool"
    echo "========================================"
    echo ""

    # Check if address scope already exists
    if openstack address scope show "$ADDRESS_SCOPE_NAME" &>/dev/null; then
        echo "Address scope '$ADDRESS_SCOPE_NAME' already exists, skipping creation"
    else
        echo "Creating address scope: $ADDRESS_SCOPE_NAME"
        openstack address scope create \
            --ip-version 4 \
            "$ADDRESS_SCOPE_NAME"
    fi

    # Check if subnet pool already exists
    if openstack subnet pool show "$SUBNET_POOL_NAME" &>/dev/null; then
        echo "Subnet pool '$SUBNET_POOL_NAME' already exists, skipping creation"
    else
        echo "Creating subnet pool: $SUBNET_POOL_NAME"
        openstack subnet pool create \
            --address-scope "$ADDRESS_SCOPE_NAME" \
            --pool-prefix "$SUBNET_POOL_PREFIXES" \
            --default-prefix-length "$SUBNET_POOL_DEFAULT_PREFIX_LEN" \
            --min-prefix-length "$SUBNET_POOL_MIN_PREFIX_LEN" \
            --max-prefix-length "$SUBNET_POOL_MAX_PREFIX_LEN" \
            "$SUBNET_POOL_NAME"
    fi

    echo ""
    echo "Address scope and subnet pool ready"
    echo ""
}

# Function to create auto-test networks with EVPN
create_auto_test_networks() {
    echo ""
    echo "========================================"
    echo "Creating Auto-Test Networks (1-${AUTO_TEST_COUNT})"
    echo "========================================"
    echo ""

    for i in $(seq 1 $AUTO_TEST_COUNT); do
        echo "----------------------------------------"
        echo "Creating auto-test-$i"
        echo "----------------------------------------"

        # Create external network with VLAN provider
        echo "Creating external network: auto-test-$i"
        openstack network create \
            --external \
            --mtu "$AUTO_TEST_MTU" \
            --provider-physical-network "$AUTO_TEST_PROVIDER_NETWORK" \
            --provider-network-type vlan \
            "auto-test-$i"

        # Create subnet from pool
        echo "Creating subnet: auto-test-$i-subnet"
        openstack subnet create \
            --network "auto-test-$i" \
            --subnet-pool "$AUTO_TEST_SUBNET_POOL" \
            "auto-test-$i-subnet"

        # Get network UUID for OVN configuration
        NET_UUID=$(openstack network show -f value -c id "auto-test-$i")

        # Configure EVPN on OVN logical switch
        echo "Configuring EVPN on logical switch"
        ovn_nbctl set logical-switch "$NET_UUID" 'external_ids:"neutron_bgpvpn\:type"="l3"'
        ovn_nbctl set logical-switch "$NET_UUID" 'external_ids:"neutron_bgpvpn\:vni"="100"'

        # Create router with external gateway
        echo "Creating router: auto-test-$i"
        openstack router create \
            --external-gateway "auto-test-$i" \
            "auto-test-$i"

        # Create private network
        echo "Creating private network: auto-test-$i-private"
        openstack network create "auto-test-$i-private"

        # Create private subnet
        echo "Creating private subnet: auto-test-$i-private-v4"
        openstack subnet create \
            --network "auto-test-$i-private" \
            --subnet-range "$AUTO_TEST_PRIVATE_CIDR" \
            "auto-test-$i-private-v4"

        # Attach private subnet to router
        echo "Attaching subnet to router"
        openstack router add subnet "auto-test-$i" "auto-test-$i-private-v4"

        echo "Completed auto-test-$i"
        echo ""
    done

    echo "========================================"
    echo "Auto-Test Networks Complete"
    echo "========================================"
    echo "Created $AUTO_TEST_COUNT network sets"
    echo ""
}

# Verify userdata file exists
if [[ ! -f "$USERDATA_FILE" ]]; then
    echo "ERROR: Cloud-init userdata file not found: $USERDATA_FILE"
    exit 1
fi

echo "=== OpenStack Test Infrastructure Setup ==="
echo "Using cloud-init userdata: $USERDATA_FILE"
if [[ "$CREATE_AUTO_TEST_NETWORKS" == "true" ]]; then
    echo "Auto-test network creation: ENABLED (1-${AUTO_TEST_COUNT})"
fi
echo ""

# Create auto-test networks if requested
if [[ "$CREATE_AUTO_TEST_NETWORKS" == "true" ]]; then
    create_address_scope_and_subnet_pool
    create_auto_test_networks
fi

# Create test infrastructure for each availability zone
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

if [[ "$CREATE_AUTO_TEST_NETWORKS" == "true" ]]; then
    echo "Address Scope and Subnet Pool:"
    echo "  Address scope: ${ADDRESS_SCOPE_NAME}"
    echo "  Subnet pool: ${SUBNET_POOL_NAME} (${SUBNET_POOL_PREFIXES})"
    echo ""
    echo "Auto-Test Networks:"
    echo "  External networks: auto-test-1 through auto-test-${AUTO_TEST_COUNT}"
    echo "  Private networks: auto-test-1-private through auto-test-${AUTO_TEST_COUNT}-private"
    echo "  Routers: auto-test-1 through auto-test-${AUTO_TEST_COUNT}"
    echo ""
fi

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
