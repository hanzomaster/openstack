#!/usr/bin/env bash
# 20-install-kolla.sh — install Kolla-Ansible + ansible-core into a venv.
# Idempotent: safe to re-run; pip will re-resolve without reinstalling
# unchanged packages.
#
# See docs/03-kolla-deploy.md.

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
LOG_FILE="$LOG_DIR/20-install-kolla.$(date -u +%Y%m%dT%H%M%SZ).log"
VENV="$HOME/kolla-venv"
KOLLA_BRANCH="stable/2025.1"   # OpenStack Epoxy

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 20-install-kolla.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " user: $USER  venv: $VENV  branch: $KOLLA_BRANCH"
echo "=============================================="

# ------------------------------------------------------------------
# 1. OS build deps
# ------------------------------------------------------------------
echo "[apt] installing build dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3-dev python3-venv git libffi-dev gcc libssl-dev \
  libdbus-1-dev libglib2.0-dev pkg-config

# ------------------------------------------------------------------
# 2. venv
# ------------------------------------------------------------------
if [[ ! -d "$VENV" ]]; then
  echo "[venv] creating $VENV"
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --upgrade pip

# ------------------------------------------------------------------
# 3. ansible-core (pinned compatible range for kolla-ansible 2025.1)
# ------------------------------------------------------------------
pip install 'ansible-core>=2.16,<2.18'

# ------------------------------------------------------------------
# 4. kolla-ansible
# ------------------------------------------------------------------
pip install "git+https://opendev.org/openstack/kolla-ansible@${KOLLA_BRANCH}"

# ------------------------------------------------------------------
# 5. required Ansible collections
# ------------------------------------------------------------------
kolla-ansible install-deps

# ------------------------------------------------------------------
# 6. Python deps the prechecks import against the venv interpreter
# (docker SDK, dbus-python). dbus-python builds a C extension and
# needs libdbus-1-dev + libglib2.0-dev from the apt step above.
# ------------------------------------------------------------------
pip install 'docker>=7.1.0' dbus-python

echo
echo "=== VERIFICATION ==="
which kolla-ansible
kolla-ansible --version || true
ansible --version | head -2

echo
echo "Install complete. Log at: $LOG_FILE"
echo "Next step: bash scripts/30-deploy-kolla.sh"
