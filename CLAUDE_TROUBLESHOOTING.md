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

## FIP Failure Mode Classification

There are three known failure modes for FIP connectivity. All present the same symptom (VM is ACTIVE, FIP is ACTIVE in API, but FIP is unreachable). They require different investigation and remediation.

### Failure Mode 1: Agent missed the binding event (original race condition)

**Identifying signs:**
- No log entries at all for the FIP address in `ovn_bgp_agent` logs
- No route in kernel table 100 for the FIP
- OVN NB config (logical switch, NAT rules) is correct

**Root cause:** Under load, the OVN BGP agent misses the `LogicalSwitchPortFIPCreateEvent`. The event fires but is not matched/processed. No errors in logs — it silently skips the FIP.

**Fix:** Re-bind the FIP to force a new event:
```bash
openstack floating ip unset --port <fip-id>
sleep 5
openstack floating ip set --port <port-id> <fip-id>
```

### Failure Mode 2: FRR crash loop (bgpd down)

**Identifying signs:**
- OVN BGP agent logs show the FIP was **successfully** processed: "Adding BGP route for FIP", "Route created at table 100", "Added BGP route for FIP"
- The reconciliation loop repeatedly reports "Route already existing" (route is in kernel)
- `sudo podman exec frr vtysh -c 'show bgp summary'` returns: **`bgpd is not running`**
- FRR container logs (`sudo podman logs frr`) show repeated restart attempts failing with:
  ```
  Can't bind zserv socket on (null): Address already in use
  Cannot bind path /var/run/frr/bgpd.vty: Address already in use
  rm: cannot remove '/var/run/frr/bgpd.pid': Permission denied
  ```
- Restarts happen every ~10 minutes, all fail with the same errors

**Root cause:** FRR daemons (zebra, bgpd, staticd, bfdd) crashed or were killed without clean shutdown. Stale Unix domain sockets (`.vty` files) and PID files are left in `/var/run/frr/`. The systemd restart policy tries to bring FRR back, but the new processes can't bind to the stale sockets and immediately exit. The OVN BGP agent continues programming routes into the kernel routing table successfully, but with bgpd down, no routes are advertised via BGP to upstream routers.

**Why some FIPs on the same node still work:** Routes advertised before the crash may still be held by upstream routers from the previous BGP session (graceful restart / stale route timers).

**Fix:** A full `stop` + `start` cycle (not `restart`) clears the stale container state:
```bash
sudo systemctl stop edpm_frr
sleep 3
sudo systemctl start edpm_frr
```
Then restart the OVN BGP agent to trigger a full reconciliation against the fresh FRR instance:
```bash
sudo systemctl restart edpm_ovn_bgp_agent
```
Wait 30-60 seconds for routes to be re-advertised and heartbeat agents to report in.

**Verification:**
```bash
sudo podman exec frr vtysh -c 'show bgp summary'
# Should show peers with Up/Down time and prefix counts
```

### Failure Mode 3: Reconciliation deletes a valid route ("excessive route")

**Identifying signs:**
- OVN BGP agent logs show the FIP was **successfully** processed initially: "Route created at table 100"
- Shortly after (within ~2 minutes), the reconciliation loop **deletes** the route:
  ```
  INFO: Remove excessive route <fip-address>
  DEBUG: Route deleted at table 100
  ```
- No further log entries for the FIP after deletion — it is never re-added
- FRR is healthy (`bgpd` is running, peers are established)

**Root cause:** The agent's reconciliation loop compares kernel routes against its internal snapshot of OVN NB state. If the reconciliation pass runs before the agent's cached view fully reflects the new FIP binding, the route appears "excessive" (exists in kernel but not in the agent's view of what should exist). The agent deletes the route it just correctly programmed moments earlier. Once deleted, the FIP is never re-exposed because no new OVN event fires.

**Fix:** Re-bind the FIP (same as Failure Mode 1):
```bash
openstack floating ip unset --port <fip-id>
sleep 5
openstack floating ip set --port <port-id> <fip-id>
```
Alternatively, restarting the OVN BGP agent triggers a full reconciliation with a fresh OVN NB snapshot, which should correctly re-expose the FIP.

### Failure Mode 4: Stale route from deleted FIP (asymmetric event handling)

**Identifying signs:**
- OVN BGP agent logs on the **correct** compute node show "Route already existing" every 2 minutes — everything looks healthy
- FRR is running and advertising the route on both nodes
- The FIP is unreachable externally, but **pings from the correct compute node via the VRF work**: `sudo ip vrf exec vrf-100 ping <fip-address>`
- On the **gateway router**, the FIP has **two ECMP next-hops** from two different compute nodes:
  ```bash
  sudo vtysh -c 'show ip route vrf vrf-100 <fip-address>'
  # Shows two * entries with different next-hops and equal weight
  ```
- On the **stale** compute node, the OVN BGP agent logs show the FIP was exposed via `NATMACAddedEvent` (not `LogicalSwitchPortFIPCreateEvent`) and there are **no subsequent log entries** for the FIP — no withdrawal, no reconciliation "Route already existing"
- The FIP ID and port ID from the stale node's `NATMACAddedEvent` log entry **no longer exist** in OpenStack:
  ```bash
  openstack floating ip show <fip-id>   # "No FloatingIP found"
  openstack port show <port-id>         # "No Port found"
  ```
- Reconciliation on the stale node reports "No excessive routes to remove" — it does not detect the orphaned route

**Root cause:** Two bugs compound to create an unrecoverable stale route:

**Bug 1 — Asymmetric event handling (no delete counterpart for NATMACAddedEvent):** When a FIP is created, two independent event paths can expose the route:
1. `LogicalSwitchPortFIPCreateEvent` — watches the `Logical_Switch_Port` table for `neutron:port_fip` in external_ids
2. `NATMACAddedEvent` — watches the `NAT` table for `external_mac` being populated

When the FIP is later deleted, only `LogicalSwitchPortFIPDeleteEvent` (on the LSP table) fires to withdraw routes. There is **no corresponding `NATMACDeletedEvent`** — zero NAT delete events appear in logs across the entire agent lifetime. Routes exposed via the NAT event path are invisible to the LSP delete handler, so no withdrawal occurs.

**Bug 2 — Reconciliation doesn't verify chassis binding:** The reconciliation loop checks whether a NAT entry exists in OVN NB for each kernel route, but does **not** verify that the NAT entry's `logical_port` is bound to the local chassis. When a FIP IP is recycled to a new VM on a different compute node, the OVN NB NAT entry still exists (for the new VM), so the stale compute node's reconciliation sees it and concludes the route is valid. This means **agent restarts do not fix this failure mode** — the route is re-validated on every reconciliation pass.

This typically occurs under load when FIP IPs are recycled across iterations: a previous-iteration FIP is deleted, its IP is reallocated to a new VM on a different compute node, and the old compute node continues advertising the stale route. The gateway router receives EVPN type-5 advertisements from both nodes and ECMP load-balances traffic, with roughly half being blackholed at the stale node.

**How to identify the stale compute node:**
```bash
# On the gateway router (172.18.158.123, user: almalinux)
sudo vtysh -c 'show bgp l2vpn evpn route type prefix' | grep -A 5 '<fip-address>'
# Look for two entries with different next-hops — the one that doesn't match
# the correct compute node's BGP router-id is the stale source

# Compute node BGP router-ids can be found with:
sudo podman exec frr vtysh -c 'show bgp summary'  # "BGP router identifier" line
```

**Fix:** Manually delete the stale kernel route and neighbor entry on the stale compute node. Agent restarts alone will NOT fix this because the reconciliation re-validates the route against the (still-existing) NAT entry without checking chassis binding.
```bash
# On the stale compute node — find the VRF interface from the route
sudo ip route show vrf vrf-100 | grep '<fip-address>'
# Output: <fip-address> dev <vrf-interface> scope link

# Delete the stale route and neighbor
sudo ip route del <fip-address>/32 dev <vrf-interface> table 100
sudo ip neigh del <fip-address> dev <vrf-interface>
```
FRR will automatically withdraw the BGP advertisement once the kernel route is removed. Wait 30-60 seconds for the gateway to converge on the single correct path.

**Important:** After manually deleting the route, restart the OVN BGP agent to prevent the reconciliation from re-adding it:
```bash
sudo systemctl stop edpm_ovn_bgp_agent
sudo ip route del <fip-address>/32 dev <vrf-interface> table 100
sudo ip neigh del <fip-address> dev <vrf-interface>
sudo systemctl start edpm_ovn_bgp_agent
```
Note: Due to Bug 2, the agent may re-add the route on the next reconciliation pass. If that happens, the only reliable fix is to also clean up the VRF interface and OVS port associated with the stale route, so the agent has no interface to program the route on.

**Verification:**
```bash
# On the gateway router — should now show only ONE next-hop
sudo vtysh -c 'show ip route vrf vrf-100 <fip-address>'

# From your workstation — FIP should now be reachable
ping <fip-address>
```

## Diagnosing Which Failure Mode

Quick triage for a non-reporting FIP instance:

1. **Get the compute node:** `openstack server show <instance> -f value -c OS-EXT-SRV-ATTR:host`
2. **SSH to the compute node** and check FRR first:
   ```bash
   sudo podman exec frr vtysh -c 'show bgp summary'
   ```
   - If `bgpd is not running` → **Failure Mode 2**
3. **Search the OVN BGP agent logs:**
   ```bash
   sudo podman logs ovn_bgp_agent 2>&1 | grep '<fip-address>'
   ```
   - No output at all → **Failure Mode 1** (missed event)
   - Shows "Route created" followed by "Remove excessive route" → **Failure Mode 3** (reconciliation bug)
   - Shows "Route created" and repeated "Route already existing" but no deletion → **Failure Mode 2** (route exists but not advertised because FRR is down)
4. **If everything looks correct on the hosting compute node** (route exists, FRR healthy, advertised to peer, local VRF ping works, but external ping fails):
   ```bash
   # Check the gateway router for duplicate routes
   ssh -i ~/oso-ssh almalinux@172.18.158.123 \
     "sudo vtysh -c 'show ip route vrf vrf-100 <fip-address>'"
   ```
   - Two ECMP next-hops → **Failure Mode 4** (stale route on another compute node)

## Bulk Recovery

To restart FRR and the OVN BGP agent across all compute nodes:
```bash
ansible -i ansible-inventory -u cloud-admin --key-file ~/oso-ssh -b -m shell \
  -a "systemctl stop edpm_frr && sleep 3 && systemctl start edpm_frr && systemctl restart edpm_ovn_bgp_agent" all
```
Note: use `stop` + `start` (not `restart`) for FRR to ensure stale sockets are cleaned up.
