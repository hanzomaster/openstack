#!/usr/bin/env python3
"""PoC 1 — Collect cluster-wide information for onboarding.

Queries every core OpenStack service via openstacksdk and produces:
  - cluster-snapshot-<ts>.json  (machine-readable)
  - cluster-snapshot-<ts>.md    (human-readable summary with justifications)

Why openstacksdk over CLI:
  1. Structured data without shelling out or parsing tables.
  2. Single authenticated connection reused across all queries.
  3. Easy to extend with new resources — just add a collector.

Each collected resource includes a "why" — what it tells a new team
member about the cluster. This satisfies the ticket requirement:
"Lên danh sách các thông tin cần thu thập, các thông tin này phản ánh
được gì về thông tin cluster."
"""

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from socket import gethostname

from common import LOG_DIR, banner, get_connection, setup_logging, write_json

log = logging.getLogger(__name__)


@dataclass
class ResourceCollector:
    name: str
    category: str
    reason: str
    fn: callable


COLLECTORS: list[ResourceCollector] = []


def collector(name: str, category: str, reason: str):
    def decorator(fn):
        COLLECTORS.append(ResourceCollector(name=name, category=category, reason=reason, fn=fn))
        return fn
    return decorator


# =====================================================================
# Identity (Keystone)
# =====================================================================

@collector(
    "services", "Identity",
    "Shows which OpenStack services are registered (Nova, Neutron, Cinder, "
    "etc.). Tells a new member exactly which capabilities this cluster has — "
    "e.g. whether Octavia (LBaaS), Designate (DNS), or Manila (shared FS) "
    "are deployed. A missing service here means it's not available.",
)
def _(conn):
    return [s.to_dict() for s in conn.identity.services()]


@collector(
    "endpoints", "Identity",
    "Maps each service to its API URLs (public, internal, admin). A new "
    "member needs these to configure CLI clients, SDKs, or Terraform "
    "providers. Also reveals the network topology — e.g. whether internal "
    "endpoints use a private subnet vs. the same public IP.",
)
def _(conn):
    return [e.to_dict() for e in conn.identity.endpoints()]


@collector(
    "domains", "Identity",
    "Shows the identity domains in use. Most single-org deployments only "
    "have 'Default', but multi-tenant or federated setups will have more. "
    "Tells a new member whether they need to specify a domain when "
    "authenticating and how tenancy is structured.",
)
def _(conn):
    return [d.to_dict() for d in conn.identity.domains()]


@collector(
    "projects", "Identity",
    "Lists all tenants/projects and their enabled state. This is the "
    "primary resource isolation boundary in OpenStack — every VM, network, "
    "and volume belongs to a project. A new member needs to know which "
    "projects exist, which are active, and where their workloads should go.",
)
def _(conn):
    return [p.to_dict() for p in conn.identity.projects()]


@collector(
    "users", "Identity",
    "Lists all human and service accounts. Helps a new member understand "
    "who has access, which accounts are service accounts (nova, neutron, "
    "etc.), and whether there are stale/disabled accounts that need cleanup.",
)
def _(conn):
    return [u.to_dict() for u in conn.identity.users()]


@collector(
    "roles", "Identity",
    "Shows the RBAC roles defined in the cluster (admin, member, reader, "
    "custom roles). A new member needs to understand the permission model — "
    "what each role can do and which roles are available for assignment.",
)
def _(conn):
    return [r.to_dict() for r in conn.identity.roles()]


@collector(
    "role_assignments", "Identity",
    "Maps users to roles on specific projects. This is the authorization "
    "matrix — who can do what, where. Critical for a new member to "
    "understand access control: which users are admins, which are scoped "
    "to specific projects, and whether any user has excessive privileges.",
)
def _(conn):
    return [a.to_dict() for a in conn.identity.role_assignments()]


# =====================================================================
# Compute (Nova)
# =====================================================================

@collector(
    "hypervisors", "Compute",
    "Lists physical/virtual compute hosts and their resource capacity "
    "(vCPUs, RAM, local disk). Tells a new member how much compute power "
    "the cluster has, how many nodes are up, and whether the cluster is "
    "nearing capacity. Essential for capacity planning.",
)
def _(conn):
    return [h.to_dict() for h in conn.compute.hypervisors()]


@collector(
    "flavors", "Compute",
    "Defines the VM size menu (vCPUs, RAM, disk combinations). A new "
    "member launching VMs needs to know what sizes are available. Custom "
    "flavors also reveal organizational conventions — e.g. GPU flavors, "
    "high-memory flavors, or cost-tier naming schemes.",
)
def _(conn):
    return [f.to_dict() for f in conn.compute.flavors()]


@collector(
    "availability_zones", "Compute",
    "Shows failure domain boundaries. VMs in different AZs typically run "
    "on different physical racks or hosts. A new member needs this to "
    "design HA deployments — e.g. spreading replicas across AZs. Also "
    "reveals whether the cluster has a single-AZ or multi-AZ topology.",
)
def _(conn):
    return [az.to_dict() for az in conn.compute.availability_zones()]


@collector(
    "servers", "Compute",
    "Lists all VMs across all projects with their status, flavor, host, "
    "and network attachments. Gives a new member a picture of what's "
    "actually running — workload density, which projects are active, "
    "whether VMs are healthy (ACTIVE) or stuck (ERROR/SHUTOFF).",
)
def _(conn):
    return [s.to_dict() for s in conn.compute.servers(all_projects=True)]


# =====================================================================
# Network (Neutron)
# =====================================================================

@collector(
    "networks", "Network",
    "Shows the L2 network topology — provider networks (external/physical), "
    "tenant networks (private), and shared networks. A new member needs "
    "this to understand how traffic flows: which network is the external "
    "gateway, which are internal, and what segmentation (VLAN/VXLAN) is used.",
)
def _(conn):
    return [n.to_dict() for n in conn.network.networks()]


@collector(
    "subnets", "Network",
    "Lists IP address ranges (CIDR), DHCP settings, DNS servers, and "
    "gateway IPs for each network. A new member needs this to assign IPs "
    "correctly, avoid conflicts, and understand the addressing scheme — "
    "e.g. which subnets are routable externally vs. RFC1918 internal only.",
)
def _(conn):
    return [s.to_dict() for s in conn.network.subnets()]


@collector(
    "routers", "Network",
    "Shows L3 routing between networks and external gateways. Tells a new "
    "member how private tenant networks reach the internet or other "
    "networks. Missing or misconfigured routers are a common cause of "
    "connectivity issues.",
)
def _(conn):
    return [r.to_dict() for r in conn.network.routers()]


@collector(
    "floating_ips", "Network",
    "Lists public IPs allocated from the external pool and their "
    "associations to VMs/ports. A new member needs to know how many "
    "public IPs are in use vs. available — this is often a scarce resource. "
    "Also shows which VMs are publicly reachable.",
)
def _(conn):
    return [f.to_dict() for f in conn.network.ips()]


@collector(
    "security_groups", "Network",
    "Shows firewall rules applied to VM ports. A new member needs to "
    "understand the default security posture — what traffic is allowed "
    "by default, whether there are shared security groups, and whether "
    "the 'default' group is locked down or permissive.",
)
def _(conn):
    return [sg.to_dict() for sg in conn.network.security_groups()]


# =====================================================================
# Block Storage (Cinder)
# =====================================================================

@collector(
    "volumes", "Storage",
    "Lists persistent block devices (virtual disks) with their size, "
    "status, and attachment to VMs. Tells a new member how much block "
    "storage is consumed, whether volumes are attached or orphaned "
    "(available but unused), and which backend is in use.",
)
def _(conn):
    return [v.to_dict() for v in conn.block_storage.volumes(all_projects=True)]


@collector(
    "volume_types", "Storage",
    "Defines storage tiers/backends (e.g. SSD vs. HDD, replicated vs. "
    "non-replicated). A new member creating volumes needs to pick the "
    "right type for their performance/durability needs. Also reveals "
    "which Cinder backends are configured (LVM, Ceph, NFS, etc.).",
)
def _(conn):
    return [vt.to_dict() for vt in conn.block_storage.types()]


# =====================================================================
# Image (Glance)
# =====================================================================

@collector(
    "images", "Image",
    "Lists OS images and snapshots available for booting VMs. A new "
    "member needs to know which base images are available (Ubuntu, "
    "CentOS, etc.), their versions, and whether there are custom/golden "
    "images maintained by the team. Old or oversized images may indicate "
    "cleanup opportunities.",
)
def _(conn):
    return [i.to_dict() for i in conn.image.images()]


# =====================================================================
# Report generation
# =====================================================================

def generate_markdown(snapshot: dict, collectors: list[ResourceCollector],
                      md_path: Path) -> None:
    ts = snapshot["snapshot_ts"]
    host = snapshot["hostname"]

    summary_rows = []
    detail_sections = []

    for c in collectors:
        items = snapshot.get(c.name, [])
        count = len(items)
        summary_rows.append(f"| {c.category} | {c.name} | {count} |")

    reason_rows = []
    for c in collectors:
        reason_rows.append(f"| **{c.name}** | {c.reason} |")

    reasons_table = "\n".join(reason_rows)
    summary_table = "\n".join(summary_rows)

    projects_list = "\n".join(
        f"- **{p.get('name', '')}** (id={p.get('id', '')}, "
        f"enabled={p.get('is_enabled', '')})"
        for p in snapshot.get("projects", [])
    ) or "(none)"

    users_list = "\n".join(
        f"- **{u.get('name', '')}** (id={u.get('id', '')}, "
        f"enabled={u.get('is_enabled', '')})"
        for u in snapshot.get("users", [])
    ) or "(none)"

    endpoints_table = "\n".join(
        f"| {e.get('service_id', '')} | {e.get('interface', '')} | "
        f"{e.get('url', '')} |"
        for e in snapshot.get("endpoints", [])
    ) or "| (none) | | |"

    hypervisors_list = "\n".join(
        f"- **{h.get('name', '')}** — "
        f"vCPUs: {h.get('vcpus', '?')}, "
        f"RAM: {h.get('memory_size', h.get('memory_mb', '?'))} MB, "
        f"status: {h.get('status', '?')}"
        for h in snapshot.get("hypervisors", [])
    ) or "(none)"

    md_path.write_text(f"""\
# OpenStack Cluster Snapshot

**Generated**: {ts}
**Host**: {host}

## Why we collect each resource

This section explains what each piece of cluster information tells a new
team member. The goal is that anyone reading this report can build a
complete mental model of the infrastructure without needing to ask
existing team members.

| Resource | What it reveals about the cluster |
|----------|----------------------------------|
{reasons_table}

## Resource counts

| Category | Resource | Count |
|----------|----------|-------|
{summary_table}

## Endpoints

| Service ID | Interface | URL |
|------------|-----------|-----|
{endpoints_table}

## Hypervisors

{hypervisors_list}

## Projects

{projects_list}

## Users

{users_list}

---
*Full machine-readable data: see corresponding .json file*
""")
    log.info("wrote %s", md_path)


# =====================================================================
# Main
# =====================================================================

def main() -> None:
    log_file = setup_logging("cluster-info")
    banner("cluster_info.py")

    conn = get_connection()

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    snapshot = {
        "snapshot_ts": ts,
        "hostname": gethostname(),
    }

    for c in COLLECTORS:
        log.info("[collect] %-20s — %s", c.name, c.reason[:60] + "...")
        try:
            snapshot[c.name] = c.fn(conn)
        except Exception:
            log.exception("  failed to collect %s", c.name)
            snapshot[c.name] = []

    json_path = LOG_DIR / f"cluster-snapshot-{ts}.json"
    md_path = LOG_DIR / f"cluster-snapshot-{ts}.md"

    write_json(json_path, snapshot)
    generate_markdown(snapshot, COLLECTORS, md_path)

    log.info("")
    log.info("=== SUMMARY ===")
    for c in COLLECTORS:
        items = snapshot.get(c.name, [])
        log.info("  %-25s %3d items", c.name, len(items))
    log.info("")
    log.info("JSON  : %s", json_path)
    log.info("Report: %s", md_path)
    log.info("Log   : %s", log_file)


if __name__ == "__main__":
    main()
