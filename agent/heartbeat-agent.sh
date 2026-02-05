#!/bin/bash
#
# SNAT Test Heartbeat Agent
# This script is designed to be used as cloud-init userdata.
# It sends heartbeats to the dashboard every 60 seconds.
#

DASHBOARD_URL="https://snat-heartbeat.apps.lab-hub.lab.signal9.gg/heartbeat"
HEARTBEAT_INTERVAL=60

# Get instance metadata from OpenStack metadata service
get_metadata() {
    curl -s http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null
}

# Extract values from metadata
METADATA=$(get_metadata)
INSTANCE_ID=$(echo "$METADATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid','unknown'))" 2>/dev/null || echo "unknown")
HOSTNAME=$(echo "$METADATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','unknown'))" 2>/dev/null || hostname)
AZ=$(echo "$METADATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('availability_zone','unknown'))" 2>/dev/null || echo "unknown")

# Determine VM type from hostname
if [[ "$HOSTNAME" == *"-snat-"* ]]; then
    VM_TYPE="snat"
elif [[ "$HOSTNAME" == *"-fip-"* ]]; then
    VM_TYPE="fip"
else
    VM_TYPE="unknown"
fi

# Get primary IP address
IP_ADDRESS=$(hostname -I | awk '{print $1}')

echo "Starting heartbeat agent..."
echo "  Instance ID: $INSTANCE_ID"
echo "  Hostname: $HOSTNAME"
echo "  Availability Zone: $AZ"
echo "  VM Type: $VM_TYPE"
echo "  IP Address: $IP_ADDRESS"
echo "  Dashboard URL: $DASHBOARD_URL"

# Send heartbeats in a loop
while true; do
    PAYLOAD=$(cat <<EOF
{
    "instance_id": "$INSTANCE_ID",
    "hostname": "$HOSTNAME",
    "availability_zone": "$AZ",
    "vm_type": "$VM_TYPE",
    "ip_address": "$IP_ADDRESS"
}
EOF
)

    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --connect-timeout 10 \
        --max-time 30 \
        -k \
        "$DASHBOARD_URL" 2>&1)

    if [[ $? -eq 0 ]]; then
        echo "$(date -Iseconds) Heartbeat sent successfully: $RESPONSE"
    else
        echo "$(date -Iseconds) Heartbeat failed: $RESPONSE"
    fi

    sleep $HEARTBEAT_INTERVAL
done
