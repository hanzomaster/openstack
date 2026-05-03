#!/usr/bin/env bash
# 40-fixtures.sh — seed demo project/users for the three tickets.
#
# Ticket fixtures:
#   demo-proj           project used by most demos
#   alice, bob          users with `member` role in demo-proj
#   orphan-charlie      user with NO role assignments — for orphan detection
#   auditor             user intended to hold a read-only role once defined
#
# Every command is tolerant of "already exists". Re-run as many times as
# you want.

set -uo pipefail   # intentionally no -e: create commands may fail benign-ly

LOG_DIR=/var/log/openstack-lab
LOG_FILE="$LOG_DIR/40-fixtures.$(date -u +%Y%m%dT%H%M%SZ).log"
DEMO_PASSWORD='Pass123!'   # lab-only throwaway

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 40-fixtures.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "admin-openrc.sh not found — deploy first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh

os() { openstack --insecure "$@"; }

tolerate_exists() {
  # runs its args; swallows non-zero if stderr mentions "already exists"
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -ne 0 ]] && ! grep -qi "already exists\|conflict\|HTTP 409" <<<"$out"; then
    echo "$out" >&2
    return $rc
  fi
  echo "$out"
  return 0
}

echo "[project] demo-proj"
tolerate_exists os project create --description "Demo project for tickets" demo-proj

for user in alice bob orphan-charlie auditor; do
  echo "[user] $user"
  tolerate_exists os user create --password "$DEMO_PASSWORD" "$user"
done

echo "[role] attaching member for alice, bob"
for user in alice bob; do
  tolerate_exists os role add --user "$user" --project demo-proj member
done

echo "[role] orphan-charlie: deliberately no role assignments"
echo "[role] auditor: deliberately no role assignments (ticket 3 will add readonly-auditor later)"

# ----------------------------------------------------------------------
# Compute/image fixtures — needed by 53-verify-readonly-role.sh which
# does `os server create --flavor m1.tiny --image cirros` to confirm
# Nova denies non-readers. Without these the verifier fails before the
# policy check fires (HTTP 400/404 on missing image/flavor instead of 403).
# ----------------------------------------------------------------------
echo "[flavor] m1.tiny"
if ! os flavor show m1.tiny >/dev/null 2>&1; then
  tolerate_exists os flavor create m1.tiny --vcpus 1 --ram 512 --disk 1 --public
fi

echo "[image] cirros"
if ! os image show cirros >/dev/null 2>&1; then
  CIRROS_URL="https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img"
  CIRROS_FILE="/tmp/cirros.img"
  [[ -f "$CIRROS_FILE" ]] || curl -sL -o "$CIRROS_FILE" "$CIRROS_URL"
  tolerate_exists os image create cirros \
    --file "$CIRROS_FILE" --disk-format qcow2 --container-format bare --public
fi

echo
echo "=== RESULT ==="
os user list
echo
os role assignment list --names

echo
echo "Fixtures complete. Log at: $LOG_FILE"
