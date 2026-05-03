#!/usr/bin/env bash
# 30-deploy-kolla.sh — generate /etc/kolla config, then run the four
# Kolla phases: bootstrap-servers, prechecks, deploy, post-deploy.
#
# Total runtime ~40 min on m5.2xlarge. Safe to re-run after fixing
# precheck failures — Kolla is idempotent by design.
#
# See docs/03-kolla-deploy.md.

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
LOG_FILE="$LOG_DIR/30-deploy-kolla.$(date -u +%Y%m%dT%H%M%SZ).log"
VENV="$HOME/kolla-venv"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBALS_OVERRIDE="$LAB_DIR/kolla-config/globals.yml"
INVENTORY="$HOME/kolla-inventory"

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 30-deploy-kolla.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

# shellcheck disable=SC1091
source "$VENV/bin/activate"

# ------------------------------------------------------------------
# 1. Scaffolding at /etc/kolla
# ------------------------------------------------------------------
if [[ ! -d /etc/kolla ]]; then
  sudo mkdir -p /etc/kolla
  sudo chown "$USER":"$USER" /etc/kolla
  cp -r "$VENV/share/kolla-ansible/etc_examples/kolla/"* /etc/kolla/
  echo "[config] seeded /etc/kolla from etc_examples"
else
  echo "[config] /etc/kolla already present, leaving it in place"
fi

# Append our overrides (idempotent: uses a marker)
MARKER="# --- openstack-lab overrides (lab/kolla-config/globals.yml) ---"
if ! grep -qF "$MARKER" /etc/kolla/globals.yml; then
  {
    echo ""
    echo "$MARKER"
    # Strip any YAML document separator (---) so we don't start a new
    # document inside the already-open globals.yml.
    grep -v '^---[[:space:]]*$' "$GLOBALS_OVERRIDE"
  } >> /etc/kolla/globals.yml
  echo "[config] appended lab overrides to /etc/kolla/globals.yml"
else
  echo "[config] lab overrides already present in globals.yml"
fi

# Generate passwords if not already generated
if [[ ! -s /etc/kolla/passwords.yml ]] || ! grep -q "keystone_admin_password:" /etc/kolla/passwords.yml || \
   grep -q "^keystone_admin_password: *$" /etc/kolla/passwords.yml; then
  kolla-genpwd
  echo "[config] passwords generated in /etc/kolla/passwords.yml"
else
  echo "[config] /etc/kolla/passwords.yml already populated"
fi

# Inventory: copy the all-in-one example so we can edit/annotate without
# touching the venv files
if [[ ! -f "$INVENTORY" ]]; then
  cp "$VENV/share/kolla-ansible/ansible/inventory/all-in-one" "$INVENTORY"
  echo "[config] inventory copied to $INVENTORY"
fi

# ------------------------------------------------------------------
# 2. Four Kolla phases
# ------------------------------------------------------------------
echo
echo "=== bootstrap-servers ==="
kolla-ansible bootstrap-servers -i "$INVENTORY"

echo
echo "=== prechecks ==="
kolla-ansible prechecks -i "$INVENTORY"

echo
echo "=== deploy ==="
kolla-ansible deploy -i "$INVENTORY"

echo
echo "=== post-deploy ==="
kolla-ansible post-deploy -i "$INVENTORY"

# ------------------------------------------------------------------
# 3. Verification
# ------------------------------------------------------------------
echo
echo "=== VERIFICATION ==="
if [[ -f /etc/kolla/admin-openrc.sh ]]; then
  # shellcheck disable=SC1091
  source /etc/kolla/admin-openrc.sh
  openstack --insecure service list || true
  openstack --insecure endpoint list | head -20 || true
  openstack --insecure hypervisor list || true
else
  echo "admin-openrc.sh not found — post-deploy may have failed" >&2
  exit 2
fi

echo
echo "Deploy complete. Log at: $LOG_FILE"
echo "Horizon: ssh -L 8080:172.31.38.250:80 ubuntu@54.255.198.174 -> http://localhost:8080"
echo "Admin password: grep keystone_admin_password /etc/kolla/passwords.yml"
echo "Next step: bash scripts/40-fixtures.sh"
