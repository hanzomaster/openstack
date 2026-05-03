#!/usr/bin/env bash
###############################################################################
# 02-deploy-openstack.sh — Deploy OpenStack using Kolla-Ansible.
#
# RUN THIS ON THE BASTION after 01-setup-bastion.sh completes.
#
# WHAT THIS DOES:
#   1. Prepares compute nodes (creates Cinder LVM volume groups)
#   2. Runs kolla-ansible bootstrap-servers (configures Docker, etc. on all nodes)
#   3. Runs kolla-ansible prechecks (validates everything is ready)
#   4. Runs kolla-ansible deploy (pulls images and starts all OpenStack containers)
#   5. Runs kolla-ansible post-deploy (generates admin credentials)
#   6. Verifies the deployment
#
# ESTIMATED TIME: ~45-60 minutes on m5.large instances
#
# HOW TO RUN:
#   bash scripts/02-deploy-openstack.sh
#
# IF IT FAILS:
#   - Kolla-Ansible is idempotent — you can re-run safely
#   - Check the log file printed at the end
#   - Common issues:
#     * SSH connectivity: re-run 01-setup-bastion.sh step 3
#     * Docker not ready: wait for cloud-init, check "docker info" on nodes
#     * Precheck failures: read the error, fix, re-run this script
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Inventory and venv paths can be overridden by the caller's environment;
# IPs are derived from the inventory file so we never drift from whatever
# Terraform/Kolla actually believe the cluster looks like.
INVENTORY="${INVENTORY:-$HOME/multinode}"
VENV="${VENV:-$HOME/kolla-venv}"
LOG_DIR="/var/log/openstack-prod"
LOG_FILE="$LOG_DIR/02-deploy.$(date -u +%Y%m%dT%H%M%SZ).log"

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: $INVENTORY not found. Run 01-setup-bastion.sh first." >&2
  exit 1
fi

# Pull "host ansible_host=ip" pairs out of the inventory's host-group lines.
# We look for the [control] / [compute] sections rather than scanning the
# whole file because the [<group>:children] sections later use the same host
# names as their literal key (which would re-match).
parse_inv_host() {
  local host=$1
  awk -v h="^${host}[[:space:]]" '
    /^\[/ { section=$0 }
    section ~ /^\[(control|network|compute|monitoring|storage)\]/ && $0 ~ h {
      for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {
        sub(/^ansible_host=/, "", $i); print $i; exit
      }
    }
  ' "$INVENTORY"
}

CONTROLLER_IP=$(parse_inv_host controller)
COMPUTE_IPS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && COMPUTE_IPS+=("$line")
done < <(
  awk '
    /^\[/ { section=$0 }
    section ~ /^\[compute\]/ && /^compute-[0-9]+[[:space:]]/ {
      for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {
        sub(/^ansible_host=/, "", $i); print $i
      }
    }
  ' "$INVENTORY"
)

if [[ -z "$CONTROLLER_IP" || ${#COMPUTE_IPS[@]} -eq 0 ]]; then
  echo "ERROR: failed to parse controller / compute IPs from $INVENTORY" >&2
  echo "       Inspect the file's [control] and [compute] sections." >&2
  exit 1
fi

# /etc/kolla must be owned by $USER (not root) so we can read passwords.yml
# and let kolla-ansible write its templated files. A partial earlier run as
# root can leave it tightly-permissioned; catch that here instead of failing
# silently inside read_pw later.
if [[ ! -r /etc/kolla/passwords.yml ]]; then
  echo "ERROR: /etc/kolla/passwords.yml is not readable as user '$USER'." >&2
  echo "       Likely a partial earlier run created /etc/kolla as root. Fix:" >&2
  echo "         sudo chown -R $USER:$USER /etc/kolla" >&2
  exit 1
fi

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 02-deploy-openstack.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " inventory:  $INVENTORY"
echo " controller: $CONTROLLER_IP"
echo " computes:   ${COMPUTE_IPS[*]}"
echo "=============================================="

# Activate the Python venv (where kolla-ansible is installed)
# shellcheck disable=SC1091
source "$VENV/bin/activate"

# ---------------------------------------------------------------------------
# Generic SSH retry helper.
#
# Wraps `ssh ubuntu@<ip> '<cmd>'` with N attempts and a backoff. Used for
# steps where transient network blips, brief sshd restarts during
# bootstrap-servers, or a node still finalising boot are common.
#
# Caller controls retry shape via env vars:
#   RETRY_ATTEMPTS=3        (total attempts, including the first)
#   RETRY_DELAY=10          (seconds between attempts)
# ---------------------------------------------------------------------------
retry_ssh() {
  local target=$1; shift
  local attempts=${RETRY_ATTEMPTS:-3}
  local delay=${RETRY_DELAY:-10}
  local i rc=0
  for ((i=1; i<=attempts; i++)); do
    if ssh -o ConnectTimeout=15 \
           -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
           -o StrictHostKeyChecking=accept-new \
           "$target" "$@"; then
      return 0
    fi
    rc=$?
    if [[ $i -lt $attempts ]]; then
      echo "  (SSH to $target failed rc=$rc; attempt $i/$attempts; sleeping ${delay}s)"
      sleep "$delay"
    fi
  done
  return $rc
}

# ---------------------------------------------------------------------------
# Reachability + cloud-init precheck across all nodes.
#
# DEPLOY.md Step 6 used to be a manual cloud-init wait. Doing it here means
# the script is safe to run the moment 01-setup-bastion.sh finishes; if a
# node is still finalising boot, we'll block until it's ready instead of
# failing 30 minutes deep.
# ---------------------------------------------------------------------------
echo ""
echo "--- Pre-flight: reachability + cloud-init on all nodes ---"
for ip in "$CONTROLLER_IP" "${COMPUTE_IPS[@]}"; do
  echo "  ${ip}: SSH reachability..."
  if ! retry_ssh "ubuntu@${ip}" "true"; then
    echo "ERROR: ${ip} is unreachable after ${RETRY_ATTEMPTS:-3} attempts." >&2
    echo "       Check the bastion's ~/.ssh/config and the node's NSG rules." >&2
    exit 1
  fi

  echo "  ${ip}: waiting for cloud-init..."
  if ! retry_ssh "ubuntu@${ip}" "sudo cloud-init status --wait"; then
    echo "ERROR: cloud-init on ${ip} failed or timed out." >&2
    echo "       Inspect /var/log/cloud-init-output.log on that node." >&2
    exit 1
  fi
done
echo "  All nodes reachable and cloud-init complete."

# ---------------------------------------------------------------------------
# Pre-flight (cont): strip the Terraform-pre-assigned VIP from controller eth0.
#
# WHY:
#   Both AWS (aws_network_interface.controller_mgmt) and Azure
#   (azurerm_network_interface.controller_mgmt's "vip" ip_configuration)
#   pre-assign the VIP (default 10.0.2.250) as a SECONDARY IP on the
#   controller's primary NIC, so the cloud platform routes VIP traffic to
#   the controller before keepalived has come up.
#
#   Side-effect: on the controller's kernel side, that pre-assigned VIP
#   often ends up reported as the *primary* address on eth0 (with the
#   real management IP demoted to "secondary metric 100"). Ansible's fact
#   gathering then picks up the VIP as eth0's address, and the
#   `kolla_address('api', controller)` filter (used by rabbitmq's
#   hostname-uniqueness precheck and others) returns the VIP instead of
#   the management IP. Result: rabbitmq precheck fails with
#   "Hostname has to resolve uniquely to the IP address of api_interface"
#   even though /etc/hosts is correct.
#
#   Setting `api_interface_address` in globals.yml only fixes services
#   that reference that variable directly — `kolla_address` reads
#   ansible_facts.eth0.ipv4.address with no override path for IPv4.
#
# WHAT:
#   Delete the /24 form of the VIP from controller eth0. Keepalived will
#   re-add it as a /32 during deploy (and the existing
#   loadbalancer-precheck patch tolerates that). Idempotent — only acts
#   when the /24 form is present.
# ---------------------------------------------------------------------------
echo ""
echo "--- Pre-flight: stripping pre-assigned VIP from controller eth0 (if present) ---"
PROD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIP=$(awk '/^kolla_internal_vip_address:/{print $2}' \
  "$PROD_DIR/kolla-config/globals.yml" 2>/dev/null | tr -d '"' || true)
VIP="${VIP:-10.0.2.250}"
ssh "ubuntu@${CONTROLLER_IP}" "
  if ip -4 addr show eth0 | grep -qE 'inet ${VIP}/24'; then
    echo '  found ${VIP}/24 on eth0 — removing so kolla_address picks the management IP'
    sudo ip addr del ${VIP}/24 dev eth0
  else
    echo '  ${VIP}/24 not present on eth0 — nothing to do (keepalived /32 form is fine)'
  fi
"

# ---------------------------------------------------------------------------
# Step 1: Prepare Cinder LVM on compute nodes
# ---------------------------------------------------------------------------
# Each compute node has an extra data volume that we turn into an LVM
# volume group named "cinder-volumes". The kernel name depends on the
# cloud and disk controller:
#   AWS Nitro EBS:    /dev/nvme1n1   (one disk per NVMe controller)
#   Azure v6/v7 NVMe: /dev/nvme0n2   (extra namespace on shared controller)
#   Older / SCSI:     /dev/sdb or /dev/xvdb
#
# LVM EXPLAINED:
#   PV (Physical Volume) = a raw disk or partition
#   VG (Volume Group)    = a pool of one or more PVs
#   LV (Logical Volume)  = a virtual partition carved from a VG
#
# Cinder creates LVs inside the "cinder-volumes" VG when users request
# block storage volumes in OpenStack.
#
# This block is hardened against:
#   - CINDER_DISK env var actually reaching the remote shell (prior
#     single-quoted heredoc swallowed it)
#   - the root device accidentally matching the auto-detect heuristic
#   - stale FS / partition / LVM signatures on a re-deployed disk
#     (DEPLOY.md "Edge cases" — wipefs first)
#   - SSH transients during the LVM step (retry_ssh-style retry loop)

echo ""
echo "=============================================="
echo " Step 1: Preparing Cinder LVM on compute nodes"
echo "=============================================="

# Capture CINDER_DISK from this script's env so we can pass it to the
# remote shell explicitly. (The heredoc below is single-quoted so the
# remote sees its body verbatim — we surface the override via SSH env.)
LOCAL_CINDER_DISK="${CINDER_DISK:-}"

for ip in "${COMPUTE_IPS[@]}"; do
  echo ""
  echo "--- Compute node ${ip} ---"

  # Wrap in a small retry loop: rare for LVM steps to hit transients,
  # but we'd rather wait 20s and retry than ask the user to start over.
  attempt=0
  max_attempts=2
  while :; do
    attempt=$((attempt+1))
    if ssh -o ConnectTimeout=15 \
           -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
           -o StrictHostKeyChecking=accept-new \
           "ubuntu@${ip}" \
           "CINDER_DISK_OVERRIDE='${LOCAL_CINDER_DISK}' bash -s" <<'REMOTE_SCRIPT'
      set -euo pipefail

      # ---- Identify the OS root device so we never touch it ---------------
      # findmnt prints e.g. "/dev/sda1" or "/dev/nvme0n1p1"; strip trailing
      # partition suffix to get the parent disk.
      ROOT_PART=$(findmnt -no SOURCE / 2>/dev/null || true)
      ROOT_DISK=$(lsblk -no PKNAME "${ROOT_PART}" 2>/dev/null | head -1)
      [[ -n "$ROOT_DISK" ]] && ROOT_DISK="/dev/${ROOT_DISK}"
      echo "  root device (OFF-LIMITS): ${ROOT_DISK:-unknown} (mounted as ${ROOT_PART:-?})"

      # Helper: is this disk currently used by any mount? (inc. swap, /boot)
      disk_in_use() {
        local d=$1
        [[ "$d" == "$ROOT_DISK" ]] && return 0
        # Any partition of this disk mounted somewhere?
        lsblk -no MOUNTPOINTS "$d" 2>/dev/null | grep -vE '^[[:space:]]*$' | grep -q .
      }

      # ---- Pick the data disk --------------------------------------------
      DISK=""
      if [[ -n "${CINDER_DISK_OVERRIDE:-}" ]]; then
        if [[ ! -b "${CINDER_DISK_OVERRIDE}" ]]; then
          echo "ERROR: CINDER_DISK=${CINDER_DISK_OVERRIDE} is not a block device on this node."
          lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
          exit 1
        fi
        if disk_in_use "${CINDER_DISK_OVERRIDE}"; then
          echo "ERROR: CINDER_DISK=${CINDER_DISK_OVERRIDE} is currently in use by the OS. Refusing."
          exit 1
        fi
        DISK="${CINDER_DISK_OVERRIDE}"
      else
        for cand in /dev/nvme1n1 /dev/nvme0n2 /dev/sdb /dev/xvdb; do
          if [[ -b "$cand" ]] && ! disk_in_use "$cand"; then
            DISK="$cand"
            break
          fi
        done
      fi

      if [[ -z "$DISK" ]]; then
        echo "ERROR: Cannot find a usable data disk."
        echo "Tried: /dev/nvme1n1, /dev/nvme0n2, /dev/sdb, /dev/xvdb"
        echo "Override on the bastion with:"
        echo "  CINDER_DISK=/dev/<your-device> bash scripts/02-deploy-openstack.sh"
        echo
        echo "Current block devices:"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
        exit 1
      fi

      echo "  selected data disk:  $DISK"

      # ---- VG already exists? Idempotent re-run path. ---------------------
      if sudo vgs cinder-volumes &>/dev/null; then
        echo "  VG cinder-volumes already exists — skipping pvcreate/vgcreate."
        sudo vgs cinder-volumes
        exit 0
      fi

      # ---- Wipe any stale signatures from a prior cluster ----------------
      # blkid / wipefs both report leftover FS / partition / LVM headers.
      # pvcreate would warn and prompt; we want non-interactive.
      if sudo blkid "$DISK" >/dev/null 2>&1 \
         || [[ -n "$(sudo wipefs -n "$DISK" 2>/dev/null)" ]]; then
        echo "  $DISK has stale signatures — wipefs -a to clear them..."
        sudo wipefs -a "$DISK"
      fi

      echo "  pvcreate $DISK..."
      sudo pvcreate -y "$DISK"

      echo "  vgcreate cinder-volumes $DISK..."
      sudo vgcreate cinder-volumes "$DISK"

      echo "  Done."
      sudo vgs cinder-volumes
REMOTE_SCRIPT
    then
      echo "Compute ${ip}: LVM ready."
      break
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: LVM setup on ${ip} failed after ${max_attempts} attempts." >&2
      exit 1
    fi
    echo "  LVM step on ${ip} failed; retrying in 20s..."
    sleep 20
  done
done

# ---------------------------------------------------------------------------
# Step 2: Kolla-Ansible bootstrap-servers
# ---------------------------------------------------------------------------
# This phase:
#   - Configures Docker daemon on all nodes (sets storage driver, etc.)
#   - Installs Python dependencies on all nodes
#   - Configures NTP synchronization
#   - Adjusts kernel parameters
#
# It connects via SSH to every node in the inventory and runs Ansible tasks.

echo ""
echo "=============================================="
echo " Step 2: kolla-ansible bootstrap-servers"
echo " (configures all nodes for OpenStack)"
echo "=============================================="
# Retry once on failure: bootstrap touches every node's apt/Docker repo,
# so a single transient 502 from download.docker.com or apt-cache lookup
# fail will kill the whole run. Idempotent — re-running is safe.
if ! kolla-ansible bootstrap-servers -i "$INVENTORY"; then
  echo ""
  echo "WARN: bootstrap-servers failed; sleeping 30s then retrying once..."
  sleep 30
  kolla-ansible bootstrap-servers -i "$INVENTORY"
fi

# ---------------------------------------------------------------------------
# Post-bootstrap-servers: rewrite controller's /etc/hosts self-mapping.
#
# Kolla 2025.2's bootstrap-servers writes "<vip> <controller-hostname>" into
# /etc/hosts on every node — meaning the controller resolves its OWN hostname
# to the VIP. RabbitMQ's epmd lookup, MariaDB's Galera node identity, and
# similar self-bound services can't bind/connect to the VIP and fail to
# start. Compute nodes are unaffected (they aren't in the loadbalancer group
# so kolla writes their real api_interface_address).
#
# We rewrite the controller's hostname → ${CONTROLLER_IP} (api_interface).
# Idempotent — only edits the line if it still points at the VIP.
# ---------------------------------------------------------------------------
echo ""
echo "--- Post-bootstrap: fixing /etc/hosts on controller ---"
VIP=$(awk '/^kolla_internal_vip_address:/{print $2}' \
  "$PROD_DIR/kolla-config/globals.yml" 2>/dev/null | tr -d '"' || true)
VIP="${VIP:-10.0.2.250}"
CTRL_HOSTNAME=$(ssh "ubuntu@${CONTROLLER_IP}" hostname)
ssh "ubuntu@${CONTROLLER_IP}" \
  "sudo sed -i 's|^${VIP} ${CTRL_HOSTNAME}\$|${CONTROLLER_IP} ${CTRL_HOSTNAME}|' /etc/hosts && \
   grep -E '${CTRL_HOSTNAME}\$' /etc/hosts"

# ---------------------------------------------------------------------------
# Step 3: Kolla-Ansible prechecks
# ---------------------------------------------------------------------------
# Validates that all nodes are correctly configured:
#   - Docker is running and accessible
#   - Required ports are not already in use
#   - Disk space is sufficient
#   - Network interfaces exist
#   - LVM volume group exists (on storage nodes)
#
# If prechecks fail, read the error carefully — it usually tells you
# exactly what's wrong and how to fix it.

echo ""
echo "=============================================="
echo " Step 3: kolla-ansible prechecks"
echo " (validates all nodes are ready)"
echo "=============================================="
# Same one-retry policy for prechecks — most checks are deterministic,
# but a few (disk space, port liveness) can flap during bootstrap settle.
if ! kolla-ansible prechecks -i "$INVENTORY"; then
  echo ""
  echo "WARN: prechecks failed; sleeping 20s then retrying once..."
  sleep 20
  kolla-ansible prechecks -i "$INVENTORY"
fi

# ---------------------------------------------------------------------------
# Step 4: Kolla-Ansible deploy
# ---------------------------------------------------------------------------
# THE MAIN EVENT. This phase:
#   - Pulls all Kolla Docker images (~2-3 GB total)
#   - Creates Docker containers for every OpenStack service
#   - Configures each service (generates config files inside containers)
#   - Starts all services in the correct order
#   - Sets up the database schema (MariaDB migrations)
#   - Creates Keystone endpoints
#
# This is the longest step — expect 30-40 minutes.

echo ""
echo "=============================================="
echo " Step 4: kolla-ansible deploy"
echo " (pulling images and starting all services)"
echo " This will take 30-40 minutes..."
echo "=============================================="

# ---------------------------------------------------------------------------
# Helper: read a single value from /etc/kolla/passwords.yml.
#
# Robust against:
#   - leading whitespace
#   - keys whose values contain colons or spaces (unlikely with kolla-genpwd
#     but cheap to handle)
#   - missing keys (returns empty string, never an error)
# ---------------------------------------------------------------------------
read_pw() {
  local key=$1
  awk -v k="^${key}:" '
    $0 ~ k {
      sub(/^[^:]+:[[:space:]]*/, "")  # drop "key:" + spaces
      sub(/[[:space:]]+$/, "")        # trim trailing whitespace
      print
      exit
    }
  ' /etc/kolla/passwords.yml 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: is a named container running on the controller?
# ---------------------------------------------------------------------------
ctrl_container_running() {
  local name=$1
  ssh -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@${CONTROLLER_IP}" \
       "sudo docker inspect -f '{{.State.Running}}' ${name} 2>/dev/null" \
     | grep -q '^true$'
}

# ---------------------------------------------------------------------------
# Helper: re-sync the `monitor` password on BOTH sides — MariaDB's user AND
# ProxySQL's stored mysql-monitor_password.
#
# WHY THIS EXISTS:
#   ProxySQL's monitor module connects to MariaDB as user 'monitor' to check
#   backend health. On a clean first deploy these passwords come from the
#   same passwords.yml and match. They DRIFT in two cases:
#
#   (a) "Timing race" — ProxySQL probes MariaDB before MariaDB has finished
#       first-boot init. ProxySQL marks the backend SHUNNED and never
#       re-probes on its own. Restart of proxysql alone fixes this.
#
#   (b) "Auth drift" — a partial earlier deploy, or a kolla password
#       regeneration, leaves MariaDB's monitor user and ProxySQL's stored
#       monitor password out of sync. Restart alone does NOT fix this:
#       the proxysql.db SQLite file is persistent, so ProxySQL keeps
#       offering the stale password and MariaDB keeps rejecting it.
#       Symptom: "Access denied for user 'monitor'@'<vip>'" repeating in
#       /var/log/kolla/proxysql/proxysql.log every 8 seconds.
#
#   This helper handles both: it runs ALTER USER on MariaDB (idempotent —
#   no-op when MariaDB already has the right hash) AND updates ProxySQL's
#   admin-tier `mysql-monitor_password` global variable, then LOAD/SAVE
#   so the new value survives a restart. Each side is skipped if its
#   container isn't running yet (so this is safe to call on a clean first
#   deploy where neither container exists).
#
# CLIENT-SIDE NOTE:
#   Both `mariadb` and `proxysql` containers run with network_mode: host in
#   Kolla 2025.2, so they share the host's network namespace. We exec the
#   `mariadb` client inside the mariadb container (proxysql ships no client)
#   and connect to BOTH services via $CONTROLLER_IP (the api_interface_address):
#
#     - MariaDB binds to ${CONTROLLER_IP}:3306 only — NOT 127.0.0.1
#     - ProxySQL admin binds to ${CONTROLLER_IP}:6032 AND VIP:6032 — also NOT 127.0.0.1
#
#   Using 127.0.0.1 looks reasonable but silently fails with errno 115
#   (connection refused) because nothing in this stack listens there.
# ---------------------------------------------------------------------------

sync_monitor_passwords() {
  local root_pw mon_pw psql_pw
  root_pw=$(read_pw database_password)
  mon_pw=$(read_pw mariadb_monitor_password)
  psql_pw=$(read_pw proxysql_admin_password)

  if [[ -z "$root_pw" || -z "$mon_pw" || -z "$psql_pw" ]]; then
    echo "  (passwords.yml not fully populated yet — skipping monitor sync)"
    echo "    database_password=$( [[ -n $root_pw ]] && echo set || echo MISSING)"
    echo "    mariadb_monitor_password=$( [[ -n $mon_pw  ]] && echo set || echo MISSING)"
    echo "    proxysql_admin_password=$( [[ -n $psql_pw ]] && echo set || echo MISSING)"
    return 0
  fi

  local err
  err=$(mktemp)

  # --- MariaDB side ----------------------------------------------------------
  if ctrl_container_running mariadb; then
    echo "  MariaDB side: ALTER USER 'monitor'@'%' to passwords.yml value..."
    # MariaDB does NOT accept MySQL 8's `IDENTIFIED WITH … BY …` syntax. We
    # use `IDENTIFIED VIA <plugin> USING PASSWORD(...)` (MariaDB 10.4+).
    #
    # Connect via TCP to ${CONTROLLER_IP}:3306 — that's where MariaDB binds
    # (api_interface_address). The mariadb container is host-networked so
    # this address is reachable from inside it.
    set +e
    ssh "ubuntu@${CONTROLLER_IP}" \
      "sudo docker exec -i mariadb mariadb -uroot -p'$root_pw' -h${CONTROLLER_IP} -P3306" \
      >/dev/null 2>"$err" <<SQL
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$mon_pw');
ALTER  USER             'monitor'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$mon_pw');
GRANT USAGE, REPLICATION CLIENT, PROCESS ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;
SQL
    local rc_m=$?
    set -e
    if [[ $rc_m -eq 0 ]]; then
      echo "    OK"
    else
      echo "    WARN: rc=$rc_m (mariadb may still be in mid-startup; continuing)"
      sed 's/^/      stderr: /' "$err"
    fi
  else
    echo "  MariaDB side: container not running — skipping (clean first deploy)."
  fi

  # --- ProxySQL side ---------------------------------------------------------
  if ctrl_container_running proxysql; then
    echo "  ProxySQL side: SET mysql-monitor_password and persist to disk..."
    # mariadb container is host-networked — exec the mariadb client there and
    # connect to ProxySQL admin at ${CONTROLLER_IP}:6032.
    set +e
    ssh "ubuntu@${CONTROLLER_IP}" \
      "sudo docker exec -i mariadb mariadb -ukolla-admin -p'$psql_pw' -h${CONTROLLER_IP} -P6032 --ssl-verify-server-cert=0" \
      >/dev/null 2>"$err" <<SQL
UPDATE global_variables SET variable_value='$mon_pw'
   WHERE variable_name='mysql-monitor_password';
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
SQL
    local rc_p=$?
    set -e
    if [[ $rc_p -eq 0 ]]; then
      echo "    OK"
    else
      echo "    WARN: rc=$rc_p (proxysql admin update failed; continuing)"
      sed 's/^/      stderr: /' "$err"
    fi
  else
    echo "  ProxySQL side: container not running — skipping (clean first deploy)."
  fi

  rm -f "$err"
  return 0
}

# ---------------------------------------------------------------------------
# Helper: rewrite ProxySQL's mysql_servers.hostname so it points at MariaDB's
# actual address ($CONTROLLER_IP / api_interface_address) instead of the VIP.
#
# WHY THIS EXISTS:
#   Kolla 2025.2's templated proxysql.yaml writes mysql_servers with
#   address=kolla_internal_vip_address (the VIP). But ProxySQL itself
#   listens on the VIP for clients, and MariaDB listens on api_interface
#   only. So ProxySQL's monitor module ends up connecting to its own
#   frontend instead of MariaDB → "Access denied for user 'monitor'@'<vip>'"
#   → backend SHUNNED → hostgroup 0 empty → Wait-for-VIP fails.
#
#   We patch this in proxysql.db at runtime; the change persists across
#   restarts because proxysql.yaml is only consulted on first init.
# ---------------------------------------------------------------------------
fix_proxysql_backend_address() {
  local psql_pw vip backend
  psql_pw=$(read_pw proxysql_admin_password)
  vip=$(awk '/^kolla_internal_vip_address:/{print $2}' \
    "$PROD_DIR/kolla-config/globals.yml" 2>/dev/null | tr -d '"' || true)
  vip="${vip:-10.0.2.250}"
  backend="${CONTROLLER_IP}"

  if ! ctrl_container_running proxysql || [[ -z "$psql_pw" ]]; then
    echo "  ProxySQL not running yet — skipping backend rewrite (first deploy)."
    return 0
  fi

  local need
  need=$(ssh "ubuntu@${CONTROLLER_IP}" \
    "sudo docker exec mariadb mariadb -ukolla-admin -p'$psql_pw' -h${CONTROLLER_IP} -P6032 --ssl-verify-server-cert=0 -ABNs \
       -e \"SELECT COUNT(*) FROM mysql_servers WHERE hostname='${vip}';\"" 2>/dev/null || echo 0)
  if [[ "${need:-0}" -eq 0 ]]; then
    echo "  ProxySQL backend already points to ${backend} (or no rows match) — no rewrite needed."
    return 0
  fi

  echo "  Rewriting ProxySQL mysql_servers.hostname: ${vip} -> ${backend}"
  ssh "ubuntu@${CONTROLLER_IP}" \
    "sudo docker exec -i mariadb mariadb -ukolla-admin -p'$psql_pw' -h${CONTROLLER_IP} -P6032 --ssl-verify-server-cert=0" <<SQL
UPDATE mysql_servers SET hostname='${backend}' WHERE hostname='${vip}';
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
SQL
}

# ---------------------------------------------------------------------------
# Helper: rewrite HAProxy backend `server` lines from the VIP to the
# api_interface_address.
#
# WHY THIS EXISTS:
#   Kolla 2025.2 templates haproxy.cfg with backend `server` lines using
#   kolla_internal_vip_address — the same address HAProxy itself listens
#   on for the frontend. So HAProxy forwards connections to itself, fails,
#   marks the backend DOWN, and returns 503 to clients (e.g.
#   `service-ks-register` failing with "Service Unavailable (HTTP 503)"
#   when it tries to register Keystone services through the VIP).
#
#   We rewrite ONLY backend `server <name> <vip>:<port>` lines (not the
#   frontend `bind <vip>:<port>` lines) and restart haproxy. Idempotent:
#   only rewrites when the VIP actually appears in a server line.
# ---------------------------------------------------------------------------
fix_haproxy_backend_addresses() {
  local vip backend changed
  vip=$(awk '/^kolla_internal_vip_address:/{print $2}' \
    "$PROD_DIR/kolla-config/globals.yml" 2>/dev/null | tr -d '"' || true)
  vip="${vip:-10.0.2.250}"
  backend="${CONTROLLER_IP}"

  if ! ctrl_container_running haproxy; then
    echo "  HAProxy not running yet — skipping backend rewrite (first deploy)."
    return 0
  fi

  changed=$(ssh "ubuntu@${CONTROLLER_IP}" \
    "sudo grep -lrE '^\s*server\s+\S+\s+${vip}:' /etc/kolla/haproxy/ 2>/dev/null | wc -l" 2>/dev/null || echo 0)
  if [[ "${changed:-0}" -eq 0 ]]; then
    echo "  HAProxy backends already point at ${backend} — no rewrite needed."
    return 0
  fi

  echo "  Rewriting HAProxy backend server lines: ${vip} -> ${backend} (${changed} files)"
  ssh "ubuntu@${CONTROLLER_IP}" \
    "sudo find /etc/kolla/haproxy -name '*.cfg' -print0 | sudo xargs -0 \
     sed -i -E 's|^(\s*server\s+\S+\s+)${vip}:|\1${backend}:|g' && \
     sudo docker restart haproxy"
  sleep 3
}

# ---------------------------------------------------------------------------
# Helper: HAProxy backend "watchdog" — runs on the controller during the
# deploy and continuously rewrites VIP-pointing backend `server` lines back
# to api_interface_address, restarting HAProxy whenever it does.
#
# WHY THIS EXISTS:
#   The pre-deploy fix_haproxy_backend_addresses helper is correct, but it
#   only wins on re-runs where HAProxy is already up AND no further deploy
#   step rewrites the configs. In Kolla 2025.2:
#
#     - The central haproxy role re-renders /etc/kolla/haproxy/haproxy.cfg
#       on every deploy.
#     - EACH service role (keystone, nova, glance, ...) re-renders its own
#       /etc/kolla/haproxy/services.d/<svc>.cfg AND restarts HAProxy via a
#       handler.
#
#   So a one-shot patch — pre-deploy or even mid-deploy — gets clobbered as
#   each service runs. The first re-render that lands before service-ks-register
#   reintroduces the broken VIP-pointing backends and we get HTTP 503 again.
#
#   The watchdog is the only intervention that survives this: it polls the
#   service.d directory every 2s, rewrites any VIP-pointing `server` line
#   back to ${CONTROLLER_IP}, and bounces HAProxy. It runs detached on the
#   controller, gets started right before deploy and stopped right after
#   post-deploy succeeds (also on EXIT trap, so a Ctrl-C cleans it up).
#
# WHY POLLING (not inotifywait):
#   - No new package install on the controller (inotify-tools isn't there).
#   - The kolla deploy runs for tens of minutes; a 2s poll is cheap.
#   - The body is a no-op when configs already point at the backend, so the
#     steady state cost is one grep every 2s.
# ---------------------------------------------------------------------------
start_haproxy_watchdog() {
  local vip backend tmpfile
  vip=$(awk '/^kolla_internal_vip_address:/{print $2}' \
    "$PROD_DIR/kolla-config/globals.yml" 2>/dev/null | tr -d '"' || true)
  vip="${vip:-10.0.2.250}"
  backend="${CONTROLLER_IP}"

  echo "  Starting HAProxy backend-watchdog on controller (${vip} -> ${backend})..."
  stop_haproxy_watchdog

  # Build the watchdog locally — avoids the local/remote double-escape
  # nightmare of nesting heredocs through ssh. ${vip}/${backend} are
  # interpolated NOW; \$VIP/\$BACKEND/etc become literal $VIP/$BACKEND in
  # the file so the remote bash interprets them.
  tmpfile=$(mktemp)
  cat > "$tmpfile" <<EOF
#!/usr/bin/env bash
# Auto-generated by 02-deploy-openstack.sh::start_haproxy_watchdog.
# Rewrites VIP-pointing HAProxy backend server lines back to api_interface
# every 2s and restarts haproxy. Safe no-op when configs already correct.
VIP="${vip}"
BACKEND="${backend}"
LOG=/var/log/haproxy-vip-watchdog.log
DIR=/etc/kolla/haproxy
mkdir -p "\$DIR/services.d" 2>/dev/null || true
echo "\$(date -u +%FT%TZ) watchdog start: VIP=\$VIP BACKEND=\$BACKEND" >> "\$LOG"
while true; do
  if grep -lrE "^[[:space:]]*server[[:space:]]+[^[:space:]]+[[:space:]]+\${VIP}:" \\
       "\$DIR" 2>/dev/null | head -1 >/dev/null; then
    find "\$DIR" -name '*.cfg' -print0 \\
      | xargs -0 sed -i -E "s|^([[:space:]]*server[[:space:]]+[^[:space:]]+[[:space:]]+)\${VIP}:|\\1\${BACKEND}:|g"
    docker restart haproxy >> "\$LOG" 2>&1 || true
    echo "\$(date -u +%FT%TZ) rewrote VIP backends and restarted haproxy" >> "\$LOG"
  fi
  sleep 2
done
EOF

  scp -q "$tmpfile" "ubuntu@${CONTROLLER_IP}:/tmp/haproxy-vip-watchdog.sh"
  rm -f "$tmpfile"
  ssh "ubuntu@${CONTROLLER_IP}" \
    "sudo install -m 0755 /tmp/haproxy-vip-watchdog.sh /usr/local/sbin/haproxy-vip-watchdog.sh && \
     rm -f /tmp/haproxy-vip-watchdog.sh && \
     sudo bash -c 'nohup /usr/local/sbin/haproxy-vip-watchdog.sh </dev/null >/dev/null 2>&1 & disown' && \
     sleep 1 && \
     pgrep -f haproxy-vip-watchdog.sh >/dev/null && echo '  watchdog PID(s):' \$(pgrep -f haproxy-vip-watchdog.sh)"
}

stop_haproxy_watchdog() {
  ssh -o ConnectTimeout=5 "ubuntu@${CONTROLLER_IP}" \
    "sudo pkill -f haproxy-vip-watchdog.sh 2>/dev/null || true" 2>/dev/null || true
}

# Always stop the watchdog on script exit (success, failure, or Ctrl-C) so it
# never lingers on the controller across runs.
trap 'stop_haproxy_watchdog' EXIT

# ---------------------------------------------------------------------------
# Pre-deploy: proactively re-sync monitor passwords on whichever side(s) are
# already up + correct ProxySQL backend address if it points at the VIP.
# Both are idempotent — no-op on truly fresh deploys; auto-fix on re-runs.
# ---------------------------------------------------------------------------
echo ""
echo "--- Pre-deploy: ensuring monitor passwords are in sync (MariaDB + ProxySQL) ---"
sync_monitor_passwords
echo "--- Pre-deploy: ensuring ProxySQL backend points at MariaDB (not the VIP) ---"
fix_proxysql_backend_address
echo "--- Pre-deploy: ensuring HAProxy backends point at api_interface (not the VIP) ---"
fix_haproxy_backend_addresses

# ---------------------------------------------------------------------------
# Auto-recovery wrapper for the ProxySQL SHUNNED race.
#
# Both cases described in sync_monitor_passwords (timing race + auth drift)
# manifest as the same Ansible failure:
#   `mariadb : Wait for MariaDB service to be ready through VIP`
#   "Max connect timeout reached while reaching hostgroup 0".
#
# On *that specific* failure we:
#   1. Run sync_monitor_passwords — fixes auth-drift on BOTH sides; no-op
#      when passwords already match (timing-only race).
#   2. Restart proxysql so it re-probes the backend (clears SHUNNED state).
#   3. Retry the deploy ONCE.
# Any other deploy failure is surfaced unchanged.
#
# Opt out: OPENSTACK_DISABLE_PROXYSQL_AUTORECOVERY=1 bash scripts/02-...
# ---------------------------------------------------------------------------
deploy_with_proxysql_recovery() {
  # Two error signatures both trace back to the same post-restart probe race:
  #   - "Max connect timeout reached while reaching hostgroup 0"  (ProxySQL classic)
  #   - "Can't connect to MySQL server on '<vip>' (timed out)"   (pymysql side)
  # Either signature on the Wait-for-VIP task triggers recovery.
  local err_pattern='Max connect timeout reached while reaching hostgroup 0|Can'\''t connect to MySQL server on'
  local err_task='Wait for MariaDB service to be ready through VIP'
  local capture
  capture=$(mktemp)
  # Up to TWO recovery attempts. The first is fired the instant we see the
  # SHUNNED-race signature; the second guards against a two-stage race
  # where the first sync ran while one of {mariadb, proxysql} was still
  # mid-boot and got skipped by ctrl_container_running.
  local recoveries=0
  local max_recoveries=2

  while true; do
    set +e
    kolla-ansible deploy -i "$INVENTORY" 2>&1 | tee -a "$capture"
    local rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -eq 0 ]]; then
      rm -f "$capture"
      return 0
    fi

    if [[ "${OPENSTACK_DISABLE_PROXYSQL_AUTORECOVERY:-0}" != "1" ]] \
       && [[ $recoveries -lt $max_recoveries ]] \
       && grep -qE "$err_pattern" "$capture" \
       && grep -qF "$err_task" "$capture"; then

      recoveries=$((recoveries+1))
      echo ""
      echo "=============================================="
      echo " Detected ProxySQL backend SHUNNED race."
      echo " Recovery attempt $recoveries / $max_recoveries."

      # Peek at the ProxySQL log purely for diagnostic output (the proxysql
      # image has no SQL client, but `tail` works fine).
      local proxylog
      proxylog=$(ssh "ubuntu@${CONTROLLER_IP}" \
        "sudo docker exec proxysql tail -10 /var/log/kolla/proxysql/proxysql.log 2>/dev/null || true")
      if echo "$proxylog" | grep -qF "Access denied for user 'monitor'"; then
        echo " ProxySQL log shows monitor-user auth denials → auth drift."
      else
        echo " ProxySQL log shows no auth denials → likely timing-only race."
      fi
      echo " Re-syncing monitor passwords on BOTH MariaDB and ProxySQL,"
      echo " then restarting proxysql and retrying deploy."
      echo " Opt out next time with:"
      echo "   OPENSTACK_DISABLE_PROXYSQL_AUTORECOVERY=1 bash scripts/02-...sh"
      echo "=============================================="

      sync_monitor_passwords
      fix_proxysql_backend_address
      ssh "ubuntu@${CONTROLLER_IP}" "sudo docker restart proxysql"

      # Poll runtime_mysql_servers until hostgroup 0 is ONLINE (or give up).
      # The retry only succeeds if the backend is actually serving — sleeping
      # a fixed time and hoping is what kept this loop spinning.
      local psql_pw
      psql_pw=$(read_pw proxysql_admin_password)
      local online=0
      if [[ -n "$psql_pw" ]]; then
        echo " Waiting up to 120s for ProxySQL hostgroup 0 to go ONLINE..."
        local i status
        for i in $(seq 1 24); do
          status=$(ssh "ubuntu@${CONTROLLER_IP}" \
            "sudo docker exec mariadb mariadb -ukolla-admin -p'$psql_pw' -h${CONTROLLER_IP} -P6032 --ssl-verify-server-cert=0 -ABNs \
               -e 'SELECT status FROM runtime_mysql_servers WHERE hostgroup_id=0 LIMIT 1;'" \
            2>/dev/null || echo "?")
          printf "   attempt %2d/24: status=%s\n" "$i" "$status"
          if [[ "$status" == "ONLINE" ]]; then online=1; break; fi
          sleep 5
        done
      fi

      if [[ $online -ne 1 ]]; then
        echo " Backend did NOT go ONLINE after sync + restart. Dumping diagnostics:"
        ssh "ubuntu@${CONTROLLER_IP}" \
          "sudo docker exec mariadb mariadb -ukolla-admin -p'$psql_pw' -h${CONTROLLER_IP} -P6032 --ssl-verify-server-cert=0 \
            -e 'SELECT hostgroup_id, hostname, port, status FROM runtime_mysql_servers;'" \
          2>&1 || true
        echo " Last 10 lines of proxysql.log:"
        ssh "ubuntu@${CONTROLLER_IP}" \
          "sudo docker exec proxysql tail -10 /var/log/kolla/proxysql/proxysql.log" \
          2>&1 || true
        echo " Aborting recovery — re-running deploy will only hit the same wall."
        rm -f "$capture"
        return $rc
      fi

      echo " Backend ONLINE — retrying deploy."
      : > "$capture"   # reset so the next failure is judged on its own
      continue
    fi

    rm -f "$capture"
    return $rc
  done
}

# Optional: start the HAProxy backend-watchdog BEFORE deploy. The watchdog
# polls /etc/kolla/haproxy/*.cfg every 2s, rewrites any VIP-pointing `server`
# line that any service role re-renders, then restarts haproxy. It was added
# to defend against keystone's `service-ks-register` hitting an HTTP 503 when
# a service role re-templated haproxy with VIP backends mid-deploy.
#
# DEFAULT: OFF. The 2s poll-and-restart turned out to be too aggressive on
# Azure: every haproxy restart trips keepalived's `check_alive` script,
# flapping the VRRP instance (FAULT → BACKUP → MASTER) and removing the
# VIP. The next `Wait for MariaDB through VIP` lands in the keepalived
# flap window and times out, even with extended retries.
#
# In practice the pre-deploy `fix_haproxy_backend_addresses` one-shot is
# enough — service-ks-register passes on a clean deploy without the
# watchdog needing to fight kolla mid-run. Re-enable explicitly with
# OPENSTACK_ENABLE_HAPROXY_WATCHDOG=1 if you ever see service-ks-register
# fail with HTTP 503 referencing a VIP backend.
if [[ "${OPENSTACK_ENABLE_HAPROXY_WATCHDOG:-0}" == "1" ]]; then
  echo ""
  echo "--- Pre-deploy: starting HAProxy backend-watchdog (opt-in via env var) ---"
  start_haproxy_watchdog
else
  echo ""
  echo "--- Pre-deploy: HAProxy backend-watchdog disabled (set OPENSTACK_ENABLE_HAPROXY_WATCHDOG=1 to enable) ---"
fi

deploy_with_proxysql_recovery

# ---------------------------------------------------------------------------
# Step 5: Kolla-Ansible post-deploy
# ---------------------------------------------------------------------------
# Generates:
#   - /etc/kolla/admin-openrc.sh — shell file you "source" to set env vars
#     for the OpenStack CLI (OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, etc.)
#   - /etc/kolla/clouds.yaml — same info in YAML format

echo ""
echo "=============================================="
echo " Step 5: kolla-ansible post-deploy"
echo " (generating admin credentials)"
echo "=============================================="
# Retry once: post-deploy hits Keystone via the VIP to write
# admin-openrc.sh / clouds.yaml, and a brief HAProxy backend flap right
# after Step 4 can fail the first attempt.
if ! kolla-ansible post-deploy -i "$INVENTORY"; then
  echo ""
  echo "WARN: post-deploy failed; sleeping 20s then retrying once..."
  sleep 20
  kolla-ansible post-deploy -i "$INVENTORY"
fi

# Deploy + post-deploy succeeded — Keystone is fully up and admin creds are
# written. Stop the watchdog explicitly (the EXIT trap also stops it; this
# just frees the controller earlier on the happy path).
echo ""
echo "--- Post-deploy: stopping HAProxy backend-watchdog ---"
stop_haproxy_watchdog

# ---------------------------------------------------------------------------
# Step 6: Verification
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " Step 6: Verification"
echo "=============================================="

if [[ -f /etc/kolla/admin-openrc.sh ]]; then
  # Source the admin credentials
  # shellcheck disable=SC1091
  source /etc/kolla/admin-openrc.sh

  echo ""
  echo "--- OpenStack Service List ---"
  openstack --insecure service list || true

  echo ""
  echo "--- OpenStack Endpoints (first 20) ---"
  openstack --insecure endpoint list | head -20 || true

  echo ""
  echo "--- Hypervisor List (should show 2 compute nodes) ---"
  openstack --insecure hypervisor list || true

  echo ""
  echo "--- Network Agent List ---"
  openstack --insecure network agent list || true
else
  echo "ERROR: /etc/kolla/admin-openrc.sh not found."
  echo "post-deploy may have failed. Check the log."
  exit 2
fi

echo ""
echo "=============================================="
echo " Deployment complete!"
echo " Log: $LOG_FILE"
echo ""
echo " ADMIN PASSWORD:"
echo "   grep keystone_admin_password /etc/kolla/passwords.yml"
echo ""
echo " HORIZON DASHBOARD (from your laptop):"
echo "   ssh -L 8080:10.0.2.250:80 ubuntu@<bastion-public-ip>"
echo "   Then open: http://localhost:8080"
echo "   Username: admin"
echo "   Password: (see above)"
echo ""
echo " OPENSTACK CLI (from bastion):"
echo "   source /etc/kolla/admin-openrc.sh"
echo "   openstack --insecure server list"
echo ""
echo " NEXT STEP (optional):"
echo "   bash scripts/03-verify.sh"
echo "=============================================="
