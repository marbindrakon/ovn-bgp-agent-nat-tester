# Troubleshooting Guide

Lessons learned from debugging OpenStack SNAT/FIP infrastructure issues.

## Environment Access

### SSH to Compute Nodes
- SSH key: `~/oso-ssh` (must be `chmod 600`)
- User: `cloud-admin`
- Example: `ssh -i ~/oso-ssh cloud-admin@<compute-ip>`

### OVN Northbound DB Commands
Run `ovn-nbctl` via the `ovn-northd-0` pod in OpenShift (not from compute nodes — they don't have the NB socket):

```bash
oc exec ovn-northd-0 -- ovn-nbctl \
    --db="ssl:ovsdbserver-nb-0.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-1.openstack.svc.cluster.local:6641,ssl:ovsdbserver-nb-2.openstack.svc.cluster.local:6641" \
    --certificate="/etc/pki/tls/certs/ovndb.crt" \
    --private-key="/etc/pki/tls/private/ovndb.key" \
    --ca-cert="/etc/pki/tls/certs/ovndbca.crt" \
    <command>
```

The helper function `ovn_nbctl` in `setup-test-infra.sh` wraps this.

### OVN BGP Agent Logs on Compute
```bash
sudo podman logs --tail 500 ovn_bgp_agent
```

### Chassis ID for a Compute Node
```bash
sudo ovs-vsctl get open_vswitch . external_ids:system-id
```

## Debugging a Missing FIP Route

When a floating IP is ACTIVE in OpenStack but unreachable externally, follow this sequence:

### 1. Confirm the data plane failure
```bash
# On the compute node hosting the VM
ip route show vrf vrf-100 | grep <fip-address>
```
If no output, the OVN BGP agent never programmed the route.

### 2. Check the OVN BGP agent logs for errors
```bash
sudo podman logs --tail 500 ovn_bgp_agent 2>&1 | grep -iE 'error|warn|<fip-address>'
```
If no errors and no mention of the FIP, the agent missed the binding event entirely (as opposed to failing to process it).

### 3. Verify OVN NB configuration is correct
Check that the logical switch has the correct EVPN external_ids:
```bash
ovn-nbctl get logical-switch neutron-<network-uuid> external_ids
# Should contain: "neutron_bgpvpn:type"=l3, "neutron_bgpvpn:vni"="100"
```

Check that the router has the NAT rule:
```bash
ovn-nbctl lr-nat-list neutron-<router-uuid>
# Should have a dnat_and_snat entry for the FIP
```

### 4. Compare with a working instance
Find another FIP instance that IS reporting and compare at each level:
- Network external_ids (should match)
- Router NAT rules (should have same structure)
- Subnet configuration (should be from same pool)
- Port binding status (both should be ACTIVE with OVS)

### 5. Fix: Re-bind the FIP
If configuration is correct but the route is missing, the agent likely missed the OVN event. Unbinding and re-binding the FIP forces a new event:
```bash
openstack floating ip unset --port <fip-id>
sleep 5
openstack floating ip set --port <port-id> <fip-id>
```
Wait ~10 seconds, then verify the route appeared:
```bash
ip route show vrf vrf-100 | grep <fip-address>
```

## VRF Naming

The VRF on compute nodes is named `vrf-100` (not `vni-100`). Check available VRFs with:
```bash
ip vrf show
```

## Key Identifiers to Collect

When investigating a failing instance, gather these upfront:
- Instance ID and name (`openstack server show`)
- Compute host (`OS-EXT-SRV-ATTR:host` field)
- Port ID (from the FIP association)
- FIP address and FIP UUID
- Floating network ID (which network the FIP was allocated from)
- Router ID (from `openstack floating ip show`)
- Network UUID of the auto-test network (for OVN logical switch lookup)

## Common Pitfalls

### FIP subnet confusion
All auto-test FIPs are allocated from `10.42.x.x/28` subnets (via the `evpn-100` subnet pool), NOT from `172.18.190.x`. The `172.18.190.x` FIPs are from `evpn-external` and are used by the permanent `test-*` instances. Both are valid and both should work — don't be misled by the different subnets.

### OpenStack CLI JSON parsing
`openstack ... -f json` piped to python can fail because the CLI sometimes writes warnings to stdout. Prefer capturing to a file first, or use `-f value` with specific columns.

### Race conditions under load
The OVN BGP agent can miss binding events when many FIPs are created simultaneously. This is the most common cause of "everything looks correct but the route is missing." The fix is always to re-bind the FIP.
