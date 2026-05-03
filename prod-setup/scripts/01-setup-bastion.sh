#!/usr/bin/env bash
###############################################################################
# 01-setup-bastion.sh — First script to run ON THE BASTION after SSH-ing in.
#
# WHAT THIS DOES:
#   1. Verifies cloud-init finished (the bastion-userdata.sh ran on boot)
#   2. Sets up SSH keys so the bastion can reach controller + compute nodes
#   3. Creates a Python virtual environment (venv)
#   4. Installs Kolla-Ansible + Ansible inside the venv
#   5. Copies Kolla config files (globals.yml, inventory) into place
#   6. Tests SSH connectivity to all nodes
#
# PREREQUISITES:
#   - You've already run "terraform apply" from your laptop
#   - You've cloned this repo onto the bastion (or copied it via scp)
#   - You're SSH'd into the bastion as the "ubuntu" user
#
# HOW TO RUN:
#   bash scripts/01-setup-bastion.sh
#
# WHAT HAPPENS NEXT:
#   After this script completes, run: bash scripts/02-deploy-openstack.sh
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these if you changed Terraform variables
# ---------------------------------------------------------------------------
CONTROLLER_IP="10.0.2.10"
COMPUTE_IPS=("10.0.2.21" "10.0.2.22")
ALL_NODE_IPS=("$CONTROLLER_IP" "${COMPUTE_IPS[@]}")

VENV="$HOME/kolla-venv"
KOLLA_BRANCH="stable/2025.2"   # OpenStack Flamingo
LOG_DIR="/var/log/openstack-prod"
LOG_FILE="$LOG_DIR/01-setup-bastion.$(date -u +%Y%m%dT%H%M%SZ).log"

# The directory where this script lives (prod-setup/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The prod-setup/ root directory (one level up from scripts/)
PROD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 01-setup-bastion.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " user: $USER"
echo " prod-dir: $PROD_DIR"
echo "=============================================="

# ---------------------------------------------------------------------------
# Detect cloud provider so we can apply cloud-specific patches automatically.
# bastion-userdata.sh writes /etc/openstack-prod/cloud on first boot.
# ---------------------------------------------------------------------------
CLOUD="unknown"
if [[ -f /etc/openstack-prod/cloud ]]; then
  CLOUD=$(tr -d '[:space:]' < /etc/openstack-prod/cloud)
fi
echo " cloud: $CLOUD"
echo "=============================================="

# ---------------------------------------------------------------------------
# Step 1: Verify cloud-init completed
# ---------------------------------------------------------------------------
# This script depends on packages that bastion-userdata.sh installs (python3-venv,
# git, gcc, …). If we ran before cloud-init finished, the venv build later in
# this script would race against `apt-get install` and fail.
#
# `cloud-init status --wait` blocks until first-boot user-data is done. Exit
# codes: 0 = clean success, 2 = "degraded" (finished with recoverable warnings),
# anything else = real failure. Azure routinely flags the boot as degraded
# because the IMDS reprovisiondata endpoint returns 404 on a non-reprovisioning
# VM — that's not a fault. The marker file written at the end of
# bastion-userdata.sh is the authoritative signal that user-data succeeded.
echo ""
echo "--- Step 1: Waiting for cloud-init to finish ---"
set +e
sudo cloud-init status --wait
ci_rc=$?
set -e
if [[ $ci_rc -ne 0 && $ci_rc -ne 2 ]]; then
  echo "ERROR: cloud-init reported a failure (exit=$ci_rc). Check 'sudo cloud-init status --long'"
  echo "       and /var/log/cloud-init-output.log before re-running."
  exit 1
fi
if [[ $ci_rc -eq 2 ]]; then
  echo "NOTE: cloud-init finished in 'degraded' state (recoverable warnings only — typical on Azure)."
fi

if [[ -f /var/log/openstack-prod/00-bastion-userdata.log ]]; then
  echo "OK: bastion user-data completed."
  cat /var/log/openstack-prod/00-bastion-userdata.log
else
  echo "ERROR: cloud-init says done but /var/log/openstack-prod/00-bastion-userdata.log"
  echo "       is missing. bastion-userdata.sh likely errored mid-run."
  echo "       Inspect /var/log/cloud-init-output.log on this VM."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Set up SSH keys
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Setting up SSH keys ---"
echo ""
echo "Kolla-Ansible uses SSH to connect from this bastion to the controller"
echo "and compute nodes. We need a key pair on the bastion."
echo ""

if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
  echo "Generating SSH key pair (no passphrase)..."
  ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N "" -q
  echo "Key generated: $HOME/.ssh/id_rsa"
else
  echo "SSH key already exists at $HOME/.ssh/id_rsa — skipping generation."
fi

# Probe whether the bastion's id_rsa already gets us into every node.
# DEPLOY.md Step 5 installs this key on all nodes, so on the happy path
# this probe succeeds and we skip the interactive prompt entirely.
echo "Probing whether SSH already works to all nodes..."
ALL_OK=1
for ip in "${ALL_NODE_IPS[@]}"; do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=5 "ubuntu@${ip}" "true" 2>/dev/null; then
    echo "  ${ip}: OK"
  else
    echo "  ${ip}: not reachable yet"
    ALL_OK=0
  fi
done

if [[ $ALL_OK -eq 1 ]]; then
  echo "SSH to all nodes already works — skipping key-copy prompt."
else
  echo ""
  echo "======================================================================="
  echo " IMPORTANT: You must copy the bastion's public key to each node."
  echo ""
  echo " The public key is:"
  echo ""
  cat "$HOME/.ssh/id_rsa.pub"
  echo ""
  echo " Copy it to each node by running these commands FROM YOUR LAPTOP"
  echo " (not from the bastion), or use SSH agent forwarding."
  echo ""
  echo " Option A — From your laptop (one command per node):"
  echo ""
  BASTION_PUB_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
  for ip in "${ALL_NODE_IPS[@]}"; do
    echo "   ssh -J ubuntu@\$(terraform -chdir=<path-to-terraform> output -raw bastion_public_ip) ubuntu@${ip} 'echo \"${BASTION_PUB_KEY}\" >> ~/.ssh/authorized_keys'"
  done
  echo ""
  echo " Option B — If you have SSH agent forwarding set up:"
  echo "   (from bastion, for each node IP)"
  for ip in "${ALL_NODE_IPS[@]}"; do
    echo "   ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@${ip}"
  done
  echo ""
  echo "======================================================================="
  echo ""
  read -rp "Have you copied the SSH key to all nodes? (y/N): " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo ""
    echo "Please copy the key to all nodes before continuing."
    echo "Then re-run this script."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Test SSH connectivity to all nodes
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Testing SSH connectivity ---"

FAILED=0
for ip in "${ALL_NODE_IPS[@]}"; do
  echo -n "  Testing SSH to ${ip}... "
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@${ip}" "hostname" 2>/dev/null; then
    echo "OK"
  else
    echo "FAILED"
    FAILED=1
  fi
done

if [[ $FAILED -eq 1 ]]; then
  echo ""
  echo "ERROR: Some nodes are not reachable. Fix SSH access and re-run."
  exit 1
fi
echo "All nodes reachable."

# ---------------------------------------------------------------------------
# Step 4: Create Python venv and install Kolla-Ansible
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Installing Kolla-Ansible ---"

if [[ ! -d "$VENV" ]]; then
  echo "Creating Python virtual environment at $VENV..."
  python3 -m venv "$VENV"
fi

# Activate the venv. From now on, "pip" and "python" refer to the venv's copies.
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing ansible-core..."
pip install 'ansible-core>=2.16,<2.18'

echo "Installing kolla-ansible from branch $KOLLA_BRANCH..."
pip install "git+https://opendev.org/openstack/kolla-ansible@${KOLLA_BRANCH}"

echo "Installing Kolla-Ansible's required Ansible collections..."
kolla-ansible install-deps

echo "Installing Docker SDK for Python (needed by Kolla's prechecks)..."
pip install 'docker>=7.1.0' dbus-python

# python-openstackclient ships separately from kolla-ansible. The bastion
# needs it to verify the deploy (02 step 6) and to drive the cluster after
# (03-verify.sh boots a test VM). Without this line, every `openstack ...`
# call fails with "command not found".
echo "Installing python-openstackclient..."
pip install 'python-openstackclient'

# ---------------------------------------------------------------------------
# VIP-pingability precheck patch (BOTH AWS and Azure)
#
# WHY:
#   Kolla assumes keepalived will claim the VIP via gratuitous ARP at deploy
#   time, so the VIP must be UNREACHABLE before the deploy starts. The
#   precheck pings the VIP from every node and fails when ping succeeds.
#
#   On AWS we assigned the VIP (10.0.2.250) as a secondary IP on the
#   controller's ENI (Terraform: aws_network_interface.controller_mgmt),
#   because AWS won't route packets to an IP unless an ENI claims it.
#
#   On Azure we did the same thing (Terraform:
#   azurerm_network_interface.controller_mgmt's second `ip_configuration`
#   "vip"). Azure binds the secondary IP to the host stack via DHCP, so the
#   controller answers pings on .250 just like on AWS.
#
#   Net result: on BOTH clouds the precheck fails on a clean deploy unless
#   we patch it. (DEPLOY.md previously claimed Azure didn't pre-route the
#   VIP — that was wrong; the precheck does fire.)
#
# WHAT:
#   The precheck pings the VIP from every node and fails if rc != 1
#   (i.e. fails when the IP IS reachable). We flip "failed_when" to false
#   so the task always succeeds. HAProxy + keepalived still run normally.
#
# CAVEAT:
#   Lives in the venv. If you rebuild the venv, this patch must reapply —
#   which is why it's part of this script. Idempotent: re-running is safe
#   because we check for our marker comment.
PRECHECK="$VENV/share/kolla-ansible/ansible/roles/loadbalancer/tasks/precheck.yml"
PRECHECK_MARKER='VIP pre-assigned by Terraform'
if [[ -f "$PRECHECK" ]] && ! grep -q "$PRECHECK_MARKER" "$PRECHECK"; then
  # Match BOTH the old AWS-only marker (if a previous run installed it) and
  # the unpatched line, so a re-run from any prior state lands on the new
  # cloud-agnostic marker.
  sed -i \
    -e "s|failed_when: false  # AWS: VIP pre-assigned on ENI|failed_when: false  # ${PRECHECK_MARKER}|" \
    -e "s|failed_when: ping_output.rc != 1|failed_when: false  # ${PRECHECK_MARKER}|" \
    "$PRECHECK"
  echo "Patched VIP-pingability precheck (cloud=$CLOUD) in $PRECHECK"
else
  echo "VIP precheck already patched (or file not found) — skipping."
fi

# ---------------------------------------------------------------------------
# MariaDB wait-for-VIP retry bump (BOTH AWS and Azure, defensive)
#
# WHY:
#   The post-deploy task `mariadb : Wait for MariaDB service to be ready
#   through VIP` retries 6× with 10s delay = 60s total. That's tight when
#   ProxySQL has just restarted (Kolla's loadbalancer role triggers a
#   restart) and is still re-probing its backend, or when keepalived
#   briefly flapped. On Azure with the (now-disabled) HAProxy watchdog
#   active, 60s wasn't enough; with the watchdog disabled this is rare
#   but non-zero — bumping to 30 retries (5 min total) gives ProxySQL's
#   own monitor cadence ample time to re-mark the backend ONLINE.
#
# WHAT:
#   Bump retries from 6 to 30 in roles/mariadb/tasks/check.yml.
#   Idempotent — only fires when the file still has retries=6.
#   Lives in the venv. If you rebuild the venv (re-run this script),
#   the patch reapplies automatically, which is exactly what we want.
MARIADB_CHECK="$VENV/share/kolla-ansible/ansible/roles/mariadb/tasks/check.yml"
if [[ -f "$MARIADB_CHECK" ]] && grep -qE '^[[:space:]]+retries:[[:space:]]+6$' "$MARIADB_CHECK"; then
  sed -i 's|^\([[:space:]]\+retries:[[:space:]]\+\)6$|\130|' "$MARIADB_CHECK"
  echo "Patched mariadb wait-for-VIP retries 6 -> 30 in $MARIADB_CHECK"
else
  echo "MariaDB wait-for-VIP retries already patched (or file not found) — skipping."
fi

# ---------------------------------------------------------------------------
# Step 5: Configure /etc/kolla
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 5: Configuring /etc/kolla ---"

# Create the /etc/kolla directory and seed it with Kolla's default configs
if [[ ! -d /etc/kolla ]]; then
  sudo mkdir -p /etc/kolla
  sudo chown "$USER":"$USER" /etc/kolla
  cp -r "$VENV/share/kolla-ansible/etc_examples/kolla/"* /etc/kolla/
  echo "Seeded /etc/kolla from Kolla defaults."
else
  echo "/etc/kolla already exists — leaving it in place."
fi

# Append our custom overrides to globals.yml
GLOBALS_OVERRIDE="$PROD_DIR/kolla-config/globals.yml"
MARKER="# --- openstack-prod overrides ---"

# Azure-specific patch: rewrite NIC names from AWS defaults (ens5/ens6) to
# Azure defaults (eth0/eth1). Idempotent — only fires when AWS values are
# still present, so re-runs and AWS deploys are no-ops. This eliminates the
# manual Step 2 sed in DEPLOY.md.
if [[ "$CLOUD" == "azure" ]]; then
  if grep -q '^network_interface: "ens5"' "$GLOBALS_OVERRIDE"; then
    sed -i 's|^network_interface: "ens5"|network_interface: "eth0"|' "$GLOBALS_OVERRIDE"
    echo "Azure: rewrote network_interface ens5 -> eth0 in $GLOBALS_OVERRIDE"
  fi
  if grep -q '^neutron_external_interface: "ens6"' "$GLOBALS_OVERRIDE"; then
    sed -i 's|^neutron_external_interface: "ens6"|neutron_external_interface: "eth1"|' "$GLOBALS_OVERRIDE"
    echo "Azure: rewrote neutron_external_interface ens6 -> eth1 in $GLOBALS_OVERRIDE"
  fi
fi

if ! grep -qF "$MARKER" /etc/kolla/globals.yml; then
  {
    echo ""
    echo "$MARKER"
    # Strip the YAML document separator (---) from our override file
    grep -v '^---[[:space:]]*$' "$GLOBALS_OVERRIDE"
  } >> /etc/kolla/globals.yml
  echo "Appended prod overrides to /etc/kolla/globals.yml"
else
  echo "Prod overrides already present in globals.yml — skipping."
fi

# Generate random passwords for all OpenStack services
if [[ ! -s /etc/kolla/passwords.yml ]] || \
   ! grep -q "keystone_admin_password:" /etc/kolla/passwords.yml || \
   grep -q "^keystone_admin_password: *$" /etc/kolla/passwords.yml; then
  kolla-genpwd
  echo "Generated passwords in /etc/kolla/passwords.yml"
else
  echo "Passwords already populated — skipping generation."
fi

# Copy our multinode inventory to the home directory
cp "$PROD_DIR/kolla-config/multinode" "$HOME/multinode"
echo "Copied inventory to $HOME/multinode"

# ---------------------------------------------------------------------------
# Step 6: Verification
# ---------------------------------------------------------------------------
echo ""
echo "=== VERIFICATION ==="
echo ""
which kolla-ansible
kolla-ansible --version || true
ansible --version | head -2
echo ""
echo "Inventory location: $HOME/multinode"
echo "Kolla config:       /etc/kolla/globals.yml"
echo "Passwords:          /etc/kolla/passwords.yml"
echo ""
echo "=============================================="
echo " Setup complete!"
echo " Log: $LOG_FILE"
echo ""
echo " NEXT STEP:"
echo "   bash scripts/02-deploy-openstack.sh"
echo "=============================================="
