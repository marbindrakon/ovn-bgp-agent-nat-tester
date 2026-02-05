#!/bin/bash
#
# Update Auto-Test Private Subnets DNS Configuration
# Adds DNS nameserver to existing auto-test private subnets
#
# Usage: ./update-auto-test-dns.sh
#

set -uo pipefail

# Configuration
DNS_NAMESERVER="172.18.42.10"
AUTO_TEST_COUNT=150

echo "========================================"
echo "Updating Auto-Test Private Subnet DNS"
echo "========================================"
echo ""
echo "DNS Nameserver: $DNS_NAMESERVER"
echo "Subnets to update: auto-test-1-private-v4 through auto-test-${AUTO_TEST_COUNT}-private-v4"
echo ""

UPDATED=0
SKIPPED=0
FAILED=0

for i in $(seq 1 $AUTO_TEST_COUNT); do
    SUBNET_NAME="auto-test-$i-private-v4"

    # Check if subnet exists
    if ! openstack subnet show "$SUBNET_NAME" &>/dev/null; then
        echo "[$i/$AUTO_TEST_COUNT] SKIP: $SUBNET_NAME does not exist"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Update subnet with DNS nameserver
    echo -n "[$i/$AUTO_TEST_COUNT] Updating $SUBNET_NAME... "
    if openstack subnet set --dns-nameserver "$DNS_NAMESERVER" "$SUBNET_NAME" 2>/dev/null; then
        echo "OK"
        UPDATED=$((UPDATED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================"
echo "Update Complete"
echo "========================================"
echo "Updated: $UPDATED"
echo "Skipped: $SKIPPED (subnet doesn't exist)"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "WARNING: Some subnets failed to update. Check OpenStack permissions."
    exit 1
fi

exit 0
