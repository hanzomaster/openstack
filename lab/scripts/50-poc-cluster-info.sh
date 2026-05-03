#!/usr/bin/env bash
# 50-poc-cluster-info.sh — Collect cluster-wide information and produce
# a JSON + Markdown snapshot suitable for onboarding new team members.
#
# Uses the openstack CLI (python-openstackclient) already installed in
# the kolla venv. CLI chosen over raw SDK because:
#   1. Zero extra dependencies — ships with every kolla-ansible deploy.
#   2. JSON output (-f json) is machine-parseable.
#   3. Easy to extend — add another `collect` call for any new service.
#
# Output:
#   /var/log/openstack-lab/cluster-snapshot-<ts>.json   (raw data)
#   /var/log/openstack-lab/cluster-snapshot-<ts>.md     (human summary)

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/50-poc-cluster-info.$TS.log"
JSON_OUT="$LOG_DIR/cluster-snapshot-$TS.json"
MD_OUT="$LOG_DIR/cluster-snapshot-$TS.md"

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 50-poc-cluster-info.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "admin-openrc.sh not found — deploy first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh

os() { openstack --insecure "$@"; }

# ------------------------------------------------------------------
# Collect each resource into a top-level JSON key
# ------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

collect() {
  local key="$1"; shift
  local outfile="$TMP_DIR/${key}.json"
  echo "[collect] $key"
  if ! os "$@" -f json > "$outfile" 2>/dev/null; then
    echo "[]" > "$outfile"
    echo "  warning: $key query failed, stored empty array"
  fi
}

# Identity
collect services            service list
collect endpoints           endpoint list
collect domains             domain list
collect projects            project list --long
collect users               user list --long
collect roles               role list
collect role_assignments    role assignment list --names

# Compute
collect hypervisors         hypervisor list
collect flavors             flavor list --long
collect availability_zones  availability zone list --compute
collect servers             server list --all-projects --long

# Network
collect networks            network list --long
collect subnets             subnet list --long
collect routers             router list --long
collect floating_ips        floating ip list --long
collect security_groups     security group list --all-projects

# Block Storage
collect volumes             volume list --all-projects --long
collect volume_types        volume type list --long

# Images
collect images              image list --long

# ------------------------------------------------------------------
# Merge into single JSON document
# ------------------------------------------------------------------
echo "[merge] building $JSON_OUT"
{
  echo "{"
  echo "  \"snapshot_ts\": \"$TS\","
  echo "  \"hostname\": \"$(hostname)\","
  first=true
  for f in "$TMP_DIR"/*.json; do
    key="$(basename "$f" .json)"
    if $first; then first=false; else echo ","; fi
    printf '  "%s": %s' "$key" "$(cat "$f")"
  done
  echo
  echo "}"
} > "$JSON_OUT"

# ------------------------------------------------------------------
# Generate Markdown summary
# ------------------------------------------------------------------
echo "[summary] building $MD_OUT"

count_json_array() {
  local f="$TMP_DIR/${1}.json"
  python3 -c "import json,sys; d=json.load(open('$f')); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "?"
}

cat > "$MD_OUT" <<EOF
# OpenStack Cluster Snapshot

**Generated**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Host**: $(hostname)

## Why we collect each resource

This section explains what each piece of cluster information tells a new
team member. The goal is that anyone reading this report can build a
complete mental model of the infrastructure without asking existing members.

| Resource | What it reveals about the cluster |
|----------|----------------------------------|
| **services** | Which OpenStack services are registered (Nova, Neutron, Cinder, etc.). Shows exactly which capabilities this cluster has — e.g. whether Octavia (LBaaS), Designate (DNS), or Manila (shared FS) are deployed. A missing service means it's not available. |
| **endpoints** | Maps each service to its API URLs (public, internal, admin). Needed to configure CLI clients, SDKs, or Terraform providers. Also reveals network topology — whether internal endpoints use a private subnet vs. the same public IP. |
| **domains** | Identity domains in use. Most single-org deployments only have 'Default', but multi-tenant or federated setups have more. Shows whether you need to specify a domain when authenticating. |
| **projects** | All tenants/projects and their enabled state. This is the primary resource isolation boundary — every VM, network, and volume belongs to a project. Shows which projects exist, which are active, and where workloads should go. |
| **users** | All human and service accounts. Shows who has access, which are service accounts (nova, neutron, etc.), and whether there are stale/disabled accounts needing cleanup. |
| **roles** | RBAC roles defined in the cluster (admin, member, reader, custom). Shows the permission model — what each role can do and which roles are available for assignment. |
| **role_assignments** | Maps users to roles on specific projects — the authorization matrix. Critical to understand access control: who are admins, who is scoped to specific projects, whether any user has excessive privileges. |
| **hypervisors** | Physical/virtual compute hosts and their resource capacity (vCPUs, RAM, local disk). Shows total compute power, how many nodes are up, and whether the cluster is nearing capacity. Essential for capacity planning. |
| **flavors** | The VM size menu (vCPU, RAM, disk combinations). Shows what sizes are available. Custom flavors reveal organizational conventions — GPU flavors, high-memory flavors, cost-tier naming. |
| **availability_zones** | Failure domain boundaries. VMs in different AZs typically run on different physical racks. Needed to design HA deployments by spreading replicas. Reveals single-AZ vs. multi-AZ topology. |
| **servers** | All VMs across all projects with status, flavor, host, and network attachments. Shows what's actually running — workload density, which projects are active, whether VMs are healthy (ACTIVE) or stuck (ERROR/SHUTOFF). |
| **networks** | L2 network topology — provider networks (external/physical), tenant networks (private), shared networks. Shows how traffic flows: which network is the external gateway, which are internal, what segmentation (VLAN/VXLAN) is used. |
| **subnets** | IP address ranges (CIDR), DHCP settings, DNS servers, gateway IPs for each network. Needed to assign IPs correctly, avoid conflicts, and understand addressing — which subnets are externally routable vs. RFC1918 internal. |
| **routers** | L3 routing between networks and external gateways. Shows how private tenant networks reach the internet. Missing or misconfigured routers are a common cause of connectivity issues. |
| **floating_ips** | Public IPs allocated from the external pool and their VM associations. Shows how many public IPs are in use vs. available (often scarce). Also shows which VMs are publicly reachable. |
| **security_groups** | Firewall rules applied to VM ports. Shows the default security posture — what traffic is allowed by default, whether there are shared groups, whether the 'default' group is locked down or permissive. |
| **volumes** | Persistent block devices (virtual disks) with size, status, and VM attachment. Shows block storage consumption, orphaned volumes (available but unused), and which backend is in use. |
| **volume_types** | Storage tiers/backends (e.g. SSD vs HDD, replicated vs non-replicated). Needed to pick the right type for performance/durability. Reveals which Cinder backends are configured (LVM, Ceph, NFS). |
| **images** | OS images and snapshots for booting VMs. Shows which base images are available (Ubuntu, CentOS, etc.), their versions, and whether there are custom/golden images. Old/oversized images may indicate cleanup needs. |

## Resource counts

| Category | Resource | Count |
|----------|----------|-------|
| Identity | Services | $(count_json_array services) |
| Identity | Endpoints | $(count_json_array endpoints) |
| Identity | Projects | $(count_json_array projects) |
| Identity | Users | $(count_json_array users) |
| Identity | Roles | $(count_json_array roles) |
| Compute | Hypervisors | $(count_json_array hypervisors) |
| Compute | Flavors | $(count_json_array flavors) |
| Compute | Servers | $(count_json_array servers) |
| Network | Networks | $(count_json_array networks) |
| Network | Subnets | $(count_json_array subnets) |
| Network | Routers | $(count_json_array routers) |
| Network | Floating IPs | $(count_json_array floating_ips) |
| Network | Security Groups | $(count_json_array security_groups) |
| Storage | Volumes | $(count_json_array volumes) |
| Storage | Volume Types | $(count_json_array volume_types) |
| Image | Images | $(count_json_array images) |

## Endpoints

\`\`\`
$(os endpoint list -f table 2>/dev/null || echo "failed to list endpoints")
\`\`\`

## Hypervisors

\`\`\`
$(os hypervisor list -f table 2>/dev/null || echo "no hypervisors")
\`\`\`

## Projects & Users

\`\`\`
$(os project list -f table 2>/dev/null || echo "failed")
\`\`\`

\`\`\`
$(os user list -f table 2>/dev/null || echo "failed")
\`\`\`

## Role Assignments

\`\`\`
$(os role assignment list --names -f table 2>/dev/null || echo "failed")
\`\`\`

---
*Full machine-readable data: $JSON_OUT*
EOF

# ------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------
echo
echo "=== VERIFICATION ==="
echo "JSON snapshot : $JSON_OUT ($(wc -c < "$JSON_OUT") bytes)"
echo "Markdown report: $MD_OUT"
echo
head -30 "$MD_OUT"

echo
echo "Cluster info collection complete. Log at: $LOG_FILE"
