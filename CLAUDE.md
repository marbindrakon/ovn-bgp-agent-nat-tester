# CLAUDE.md

## Project Overview

OpenStack SNAT/FIP test harness that validates networking connectivity across availability zones. Creates test infrastructure (networks, routers, VMs), runs load tests, and monitors instance health via a heartbeat dashboard deployed on OpenShift.

## Repository Layout

- `setup-test-infra.sh` / `cleanup-test-infra.sh` - Permanent test infrastructure
- `load-test.sh` - Continuous load testing with ephemeral VMs
- `cleanup-load-test-resources.sh` - Cleanup leftover load-* resources
- `web-service/` - Flask heartbeat dashboard (deployed as container on OpenShift)
- `k8s/` - OpenShift/Kubernetes manifests
- `agent/` - Heartbeat agent (cloud-init userdata)
- `deploy-dashboard.sh` - Build, push, and deploy the dashboard

## Important Conventions

### Instance Naming

Hostname prefixes determine behavior throughout the system:
- `test-*` = permanent instances (5-min stale threshold, never cleaned up from dashboard)
- `load-*` = ephemeral instances (3-min stale threshold, auto-removed after 10 min)

This convention is used in the dashboard (`app.py`), cleanup scripts, and load test validation. Do not change these prefixes without updating all consumers.

### Resource Naming in Load Tests

- Servers: `load-snat-{net_id}-iter{iteration}`, `load-fip-{net_id}-iter{iteration}`
- Ports: `load-fip-port-{net_id}-iter{iteration}`
- Floating IPs: no name (matched by port UUID association)

## Gotchas and Unintuitive Behaviors

### OpenStack CLI `--name` flag

The `--name` flag on `openstack server list`, `openstack port list`, etc. does **not** reliably do substring matching. In some OpenStack client versions it requires an exact match or uses server-side regex that behaves inconsistently. Always prefer listing all resources and piping through `grep` instead:

```bash
# BAD - unreliable
openstack port list --name 'load-' -f value -c Name

# GOOD - reliable
openstack port list -f value -c Name | grep '^load-'
```

### Floating IPs Have No Name Field

Floating IPs in OpenStack don't carry the name of the server or port they're attached to. The `Port` column in `openstack floating ip list` contains a **UUID**, not a port name. To find FIPs belonging to load-* resources, you must:
1. Get load-* port UUIDs from `openstack port list`
2. Match those UUIDs against the Port column in `openstack floating ip list`

### Container Image SHA Digests

**Never use `podman inspect` to get the SHA digest for Kubernetes deployments.** The local image digest differs from the registry digest. Always use:

```bash
skopeo inspect docker://quay.signal9.gg/aaustin/snat-test-dashboard:latest | jq -r '.Digest'
```

The deployment manifest (`k8s/deployment.yaml`) pins the image by SHA digest, not tag. This must be updated on every deploy.

### Registry Authentication

Registry auth to `quay.signal9.gg` expires. If `podman push` fails with "unauthorized", the user needs to run `podman login quay.signal9.gg` manually. Do not attempt to run this programmatically - it requires interactive credentials.

### Working Directory

The deploy script `cd`s into `web-service/`. After running it or building the container, git commands may fail if run from `web-service/` instead of the repo root. Use absolute paths or `git -C /home/aaustin/cc-workspaces/oso-test-script` to avoid this.

## Deploy Workflow

1. Build: `podman build -t quay.signal9.gg/aaustin/snat-test-dashboard:latest .` (from `web-service/`)
2. Push: `podman push quay.signal9.gg/aaustin/snat-test-dashboard:latest`
3. Get digest: `skopeo inspect docker://quay.signal9.gg/aaustin/snat-test-dashboard:latest | jq -r '.Digest'`
4. Update `k8s/deployment.yaml` with new digest
5. Apply: `oc apply -f k8s/deployment.yaml`
6. Verify: `oc rollout status deployment/snat-heartbeat-dashboard -n snat-test`

## Load Test Expected Behavior

The load test is designed to **trigger infrastructure failures**. These are not bugs:
- VMs show ACTIVE but floating IPs are unreachable (data plane failure)
- 70-85% heartbeat success rate is normal under load
- Missing heartbeats from some ephemeral instances is expected
- Resources are preserved on failure for troubleshooting (use `cleanup-load-test-resources.sh` after)

## Key Infrastructure Details

- External network: `evpn-external`
- Auto-test networks: `auto-test-1` through `auto-test-150` (VLAN provider, EVPN)
- DNS nameserver: `172.18.42.10` (required for heartbeat agent to resolve dashboard hostname)
- Dashboard URL: `https://snat-heartbeat.apps.lab-hub.lab.signal9.gg`
- Container registry: `quay.signal9.gg/aaustin/snat-test-dashboard`
- OpenShift namespace: `snat-test`
- Image: `fedora-43`, Flavor: `minimal`, Keypair: `aaustin-key`
