#!/usr/bin/env bash
# 52-poc-readonly-role.sh — Create a read-only custom role and configure
# per-service policies so holders can list/show resources but cannot
# create, update, or delete.
#
# Pre-Yoga approach: the `reader` role is not enforced by default, so we
# must override each service's policy.yaml. Kolla-ansible picks up
# custom policies from /etc/kolla/config/<service>/policy.yaml and
# mounts them into the containers on reconfigure.
#
# Services covered: Keystone, Nova, Neutron, Cinder, Glance.
#
# After running this script, execute:
#   kolla-ansible -i ~/kolla-inventory reconfigure
# to apply the policies. Then run:
#   bash scripts/53-verify-readonly-role.sh
# to validate.

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/52-poc-readonly-role.$TS.log"
KOLLA_CONFIG=/etc/kolla/config

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 52-poc-readonly-role.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "admin-openrc.sh not found — deploy first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh

os() { openstack --insecure "$@"; }

ROLE_NAME="readonly-auditor"

# ------------------------------------------------------------------
# 1. Create custom role in Keystone
# ------------------------------------------------------------------
echo "[keystone] creating role: $ROLE_NAME"
if os role show "$ROLE_NAME" >/dev/null 2>&1; then
  echo "  role already exists"
else
  os role create "$ROLE_NAME"
  echo "  created"
fi

# ------------------------------------------------------------------
# 2. Assign role to the auditor user on demo-proj
# ------------------------------------------------------------------
echo "[keystone] assigning $ROLE_NAME to 'auditor' on 'demo-proj'"
os role add --user auditor --project demo-proj "$ROLE_NAME" 2>/dev/null || true
echo "  assigned"

# ------------------------------------------------------------------
# 3. Write per-service policy overrides
# ------------------------------------------------------------------
echo "[policy] writing policy overrides to $KOLLA_CONFIG"

# Helper: create dir and write policy file (preserves existing files by
# appending a guard comment so re-runs are safe).
write_policy() {
  local service="$1"
  local content="$2"
  local dir="$KOLLA_CONFIG/$service"
  local file="$dir/policy.yaml"
  local marker="# --- readonly-auditor policy (managed by 52-poc-readonly-role.sh) ---"

  sudo mkdir -p "$dir"
  sudo chown "$USER":"$USER" "$dir"

  if [[ -f "$file" ]] && grep -qF "$marker" "$file"; then
    echo "  [$service] policy.yaml already contains readonly-auditor rules, skipping"
    return
  fi

  if [[ -f "$file" ]]; then
    {
      echo ""
      echo "$marker"
      echo "$content"
    } >> "$file"
  else
    {
      echo "$marker"
      echo "$content"
    } > "$file"
  fi
  echo "  [$service] policy.yaml written"
}

# -- Keystone ----------------------------------------------------------
write_policy keystone '
# Allow readonly-auditor to list identity resources (project-scoped)
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
"identity:get_domain": "rule:readonly_or_admin"'

# -- Nova --------------------------------------------------------------
write_policy nova '
# Composite rules
"is_readonly": "role:readonly-auditor"
"admin_or_owner_or_readonly": "rule:is_admin_or_owner or rule:is_readonly"
"admin_or_readonly": "rule:is_admin or rule:is_readonly"

# Servers
"os_compute_api:servers:index": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:show": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:detail": "rule:admin_or_owner_or_readonly"
"os_compute_api:servers:index:get_all_tenants": "rule:admin_or_readonly"

# Flavors
"os_compute_api:os-flavor-extra-specs:index": "rule:admin_or_readonly"
"os_compute_api:os-flavor-extra-specs:show": "rule:admin_or_readonly"

# Hypervisors
"os_compute_api:os-hypervisors:list": "rule:admin_or_readonly"
"os_compute_api:os-hypervisors:list-detail": "rule:admin_or_readonly"
"os_compute_api:os-hypervisors:show": "rule:admin_or_readonly"

# Availability zones
"os_compute_api:os-availability-zone:list": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-availability-zone:detail": "rule:admin_or_readonly"

# Quotas (read)
"os_compute_api:os-quota-sets:show": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-quota-sets:defaults": "rule:admin_or_owner_or_readonly"

# Keypairs (own)
"os_compute_api:os-keypairs:index": "rule:admin_or_owner_or_readonly"
"os_compute_api:os-keypairs:show": "rule:admin_or_owner_or_readonly"'

# -- Neutron -----------------------------------------------------------
write_policy neutron '
# Composite rules
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"
"readonly_or_admin": "rule:admin_only or role:readonly-auditor"

# Networks
"get_network": "rule:readonly_or_owner_or_admin"
"get_network:provider:network_type": "rule:readonly_or_admin"
"get_network:provider:physical_network": "rule:readonly_or_admin"
"get_network:provider:segmentation_id": "rule:readonly_or_admin"

# Subnets
"get_subnet": "rule:readonly_or_owner_or_admin"
"get_subnet_pool": "rule:readonly_or_owner_or_admin"

# Ports
"get_port": "rule:readonly_or_owner_or_admin"

# Routers
"get_router": "rule:readonly_or_owner_or_admin"

# Floating IPs
"get_floatingip": "rule:readonly_or_owner_or_admin"

# Security groups
"get_security_group": "rule:readonly_or_owner_or_admin"
"get_security_group_rule": "rule:readonly_or_owner_or_admin"

# Quotas
"get_quota": "rule:readonly_or_admin"'

# -- Cinder ------------------------------------------------------------
write_policy cinder '
# Composite rules
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"
"readonly_or_admin": "rule:admin_api or role:readonly-auditor"

# Volumes
"volume:get_all": "rule:readonly_or_owner_or_admin"
"volume:get": "rule:readonly_or_owner_or_admin"

# Snapshots
"volume:get_all_snapshots": "rule:readonly_or_owner_or_admin"
"volume:get_snapshot": "rule:readonly_or_owner_or_admin"

# Volume types
"volume_extension:volume_type_access": "rule:readonly_or_owner_or_admin"
"volume_extension:type_get": "rule:readonly_or_owner_or_admin"
"volume_extension:type_get_all": "rule:readonly_or_owner_or_admin"

# Quotas
"limits_extension:used_limits": "rule:readonly_or_owner_or_admin"'

# -- Glance ------------------------------------------------------------
write_policy glance '
# Composite rules
"readonly_or_owner_or_admin": "rule:admin_or_owner or role:readonly-auditor"

# Images
"get_image": "rule:readonly_or_owner_or_admin"
"get_images": "rule:readonly_or_owner_or_admin"
"get_image_location": "rule:readonly_or_owner_or_admin"
"get_members": "rule:readonly_or_owner_or_admin"'

# ------------------------------------------------------------------
# 4. Summary
# ------------------------------------------------------------------
echo
echo "=== POLICY FILES CREATED ==="
for svc in keystone nova neutron cinder glance; do
  f="$KOLLA_CONFIG/$svc/policy.yaml"
  if [[ -f "$f" ]]; then
    echo "  $f ($(wc -l < "$f") lines)"
  fi
done

echo
echo "=== ROLE ASSIGNMENTS ==="
os role assignment list --names --user auditor -f table

echo
echo "=== NEXT STEPS ==="
echo "  1. Apply policies:  kolla-ansible -i ~/kolla-inventory reconfigure"
echo "  2. Verify:          bash scripts/53-verify-readonly-role.sh"
echo
echo "Readonly role setup complete. Log at: $LOG_FILE"
