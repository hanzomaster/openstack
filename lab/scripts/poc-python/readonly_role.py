#!/usr/bin/env python3
"""PoC 3 — Create a read-only custom role with per-service policy overrides.

Two-phase workflow:
  Phase 1 (this script):
    - Creates the 'readonly-auditor' role in Keystone.
    - Assigns it to the 'auditor' user on 'demo-proj'.
    - Writes policy.yaml overrides for Nova, Neutron, Cinder, Glance, Keystone
      into /etc/kolla/config/<service>/policy.yaml.

  Phase 2 (manual):
    - Run:  kolla-ansible -i ~/kolla-inventory reconfigure
    - Then: python3 verify_readonly_role.py

Pre-Yoga approach: the 'reader' role is not enforced by services, so
we override each service's policy to recognize our custom role.
"""

import logging
from pathlib import Path

from common import banner, get_connection, setup_logging

log = logging.getLogger(__name__)

ROLE_NAME = "readonly-auditor"
AUDITOR_USER = "auditor"
DEMO_PROJECT = "demo-proj"
KOLLA_CONFIG = Path("/etc/kolla/config")
MARKER = "# --- readonly-auditor policy (managed by readonly_role.py) ---"

POLICIES: dict[str, str] = {
    "keystone": """\
"readonly_or_admin": "rule:admin_required or role:readonly-auditor"

"identity:list_projects": "rule:readonly_or_admin"
"identity:get_project": "rule:readonly_or_admin"
"identity:list_users": "rule:readonly_or_admin"
"identity:get_user": "rule:readonly_or_admin"
"identity:list_roles": "rule:readonly_or_admin"
"identity:get_role": "rule:readonly_or_admin"
"identity:list_role_assignments": "rule:readonly_or_admin"
"identity:list_endpoints": "rule:readonly_or_admin"
"identity:get_endpoint": "rule:readonly_or_admin"
"identity:list_services": "rule:readonly_or_admin"
"identity:get_service": "rule:readonly_or_admin"
"identity:list_domains": "rule:readonly_or_admin"
"identity:get_domain": "rule:readonly_or_admin"
""",
    "nova": """\
"is_readonly": "role:readonly-auditor"
"admin_or_owner_or_readonly": "rule:is_admin_or_owner or rule:is_readonly"
"admin_or_readonly": "rule:is_admin or rule:is_readonly"

"os_compute_api:servers:index": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:show": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:detail": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:index:get_all_tenants": "rule:admin_or_readonly"

"os_compute_api:os-flavor-extra-specs:index": "rule:admin_or_readonly"
"os_compute_api:os-flavor-extra-specs:show": "rule:admin_or_readonly"

"os_compute_api:os-hypervisors:list": "rule:admin_or_readonly"
"os_compute_api:os-hypervisors:list-detail": "rule:admin_or_readonly"
"os_compute_api:os-hypervisors:show": "rule:admin_or_readonly"

"os_compute_api:os-availability-zone:list": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-availability-zone:detail": "rule:admin_or_readonly"

"os_compute_api:os-quota-sets:show": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-quota-sets:defaults": "rule:admin_or_owner_or_readonly"

"os_compute_api:os-keypairs:index": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-keypairs:show": "rule:admin_or_owner_or_readonly"
""",
    "neutron": """\
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"
"readonly_or_admin": "rule:admin_only or role:readonly-auditor"

"get_network": "rule:readonly_or_owner_or_admin"
"get_network:provider:network_type": "rule:readonly_or_admin"
"get_network:provider:physical_network": "rule:readonly_or_admin"
"get_network:provider:segmentation_id": "rule:readonly_or_admin"

"get_subnet": "rule:readonly_or_owner_or_admin"
"get_subnet_pool": "rule:readonly_or_owner_or_admin"

"get_port": "rule:readonly_or_owner_or_admin"

"get_router": "rule:readonly_or_owner_or_admin"

"get_floatingip": "rule:readonly_or_owner_or_admin"

"get_security_group": "rule:readonly_or_owner_or_admin"
"get_security_group_rule": "rule:readonly_or_owner_or_admin"

"get_quota": "rule:readonly_or_admin"
""",
    "cinder": """\
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"
"readonly_or_admin": "rule:admin_api or role:readonly-auditor"

"volume:get_all": "rule:readonly_or_owner_or_admin"
"volume:get": "rule:readonly_or_owner_or_admin"

"volume:get_all_snapshots": "rule:readonly_or_owner_or_admin"
"volume:get_snapshot": "rule:readonly_or_owner_or_admin"

"volume_extension:volume_type_access": "rule:readonly_or_owner_or_admin"
"volume_extension:type_get": "rule:readonly_or_owner_or_admin"
"volume_extension:type_get_all": "rule:readonly_or_owner_or_admin"

"limits_extension:used_limits": "rule:readonly_or_owner_or_admin"
""",
    "glance": """\
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"

"get_image": "rule:readonly_or_owner_or_admin"
"get_images": "rule:readonly_or_owner_or_admin"
"get_image_location": "rule:readonly_or_owner_or_admin"
"get_members": "rule:readonly_or_owner_or_admin"
""",
}


def create_role(conn) -> None:
    log.info("[keystone] creating role: %s", ROLE_NAME)
    existing = conn.identity.find_role(ROLE_NAME)
    if existing:
        log.info("  role already exists (id=%s)", existing.id)
        return
    role = conn.identity.create_role(name=ROLE_NAME)
    log.info("  created (id=%s)", role.id)


def assign_role(conn) -> None:
    log.info("[keystone] assigning %s to '%s' on '%s'",
             ROLE_NAME, AUDITOR_USER, DEMO_PROJECT)

    user = conn.identity.find_user(AUDITOR_USER)
    project = conn.identity.find_project(DEMO_PROJECT)
    role = conn.identity.find_role(ROLE_NAME)

    if not user:
        log.error("  user '%s' not found — run 40-fixtures.sh first", AUDITOR_USER)
        return
    if not project:
        log.error("  project '%s' not found — run 40-fixtures.sh first", DEMO_PROJECT)
        return

    try:
        conn.identity.assign_project_role_to_user(project.id, user.id, role.id)
        log.info("  assigned")
    except Exception:
        log.info("  already assigned (or assignment succeeded)")


def write_policies() -> None:
    log.info("[policy] writing policy overrides to %s", KOLLA_CONFIG)

    for service, content in POLICIES.items():
        svc_dir = KOLLA_CONFIG / service
        svc_dir.mkdir(parents=True, exist_ok=True)
        policy_file = svc_dir / "policy.yaml"

        if policy_file.exists() and MARKER in policy_file.read_text():
            log.info("  [%s] policy.yaml already contains readonly-auditor rules, skipping",
                     service)
            continue

        new_content = f"\n{MARKER}\n{content}" if policy_file.exists() else f"{MARKER}\n{content}"

        if policy_file.exists():
            existing = policy_file.read_text()
            policy_file.write_text(existing + new_content)
        else:
            policy_file.write_text(new_content)

        log.info("  [%s] policy.yaml written (%d lines)", service,
                 len(policy_file.read_text().splitlines()))


def main() -> None:
    log_file = setup_logging("readonly-role")
    banner("readonly_role.py")

    conn = get_connection()
    create_role(conn)
    assign_role(conn)
    write_policies()

    log.info("")
    log.info("=== POLICY FILES ===")
    for service in POLICIES:
        f = KOLLA_CONFIG / service / "policy.yaml"
        if f.exists():
            log.info("  %s (%d lines)", f, len(f.read_text().splitlines()))

    log.info("")
    log.info("=== NEXT STEPS ===")
    log.info("  1. Apply:  kolla-ansible -i ~/kolla-inventory reconfigure")
    log.info("  2. Verify: python3 scripts/poc-python/verify_readonly_role.py")
    log.info("")
    log.info("Readonly role setup complete. Log at: %s", log_file)


if __name__ == "__main__":
    main()
