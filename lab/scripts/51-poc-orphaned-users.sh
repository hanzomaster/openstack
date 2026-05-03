#!/usr/bin/env bash
# 51-poc-orphaned-users.sh — Find users with no project role assignments
# (orphaned/dangling users) and optionally post them to Mattermost.
#
# Uses openstack CLI to avoid extra Python dependencies.
# Strategy:
#   1. List all users (JSON).
#   2. List all role assignments (JSON).
#   3. Diff: users whose ID never appears in a project-scoped assignment.
#
# Mattermost integration:
#   Set MATTERMOST_WEBHOOK_URL env var to post results automatically.
#   If unset, the script prints results to stdout only.

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/51-poc-orphaned-users.$TS.log"

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 51-poc-orphaned-users.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "admin-openrc.sh not found — deploy first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh

os() { openstack --insecure "$@"; }

# Service accounts to exclude — these are created by kolla-ansible and
# will never have project-scoped roles in the normal sense.
SERVICE_USERS="nova neutron cinder glance heat placement keystone \
  barbican octavia designate manila aodh gnocchi ceilometer \
  swift magnum trove sahara ironic cloudkitty monasca panko \
  blazar freezer karbor mistral murano senlin tacker vitrage watcher zun"

# ------------------------------------------------------------------
# 1. Gather data
# ------------------------------------------------------------------
echo "[gather] listing users"
USERS_JSON="$(os user list --long -f json)"

echo "[gather] listing role assignments"
ASSIGNMENTS_JSON="$(os role assignment list -f json)"

# ------------------------------------------------------------------
# 2. Compute orphaned users
# ------------------------------------------------------------------
echo "[compute] finding orphaned users"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "$USERS_JSON" > "$TMP_DIR/users.json"
echo "$ASSIGNMENTS_JSON" > "$TMP_DIR/assignments.json"

RESULT="$(python3 <<PYEOF
import json, sys

service_user_names = set("""$SERVICE_USERS""".split())

with open("$TMP_DIR/users.json") as f:
    users = json.load(f)
with open("$TMP_DIR/assignments.json") as f:
    assignments = json.load(f)

users_with_projects = set()
for a in assignments:
    uid = a.get("User") or a.get("user") or ""
    project = a.get("Project") or a.get("project") or ""
    if project:
        users_with_projects.add(uid)

orphaned = []
for u in users:
    uid = u.get("ID") or u.get("id") or ""
    name = u.get("Name") or u.get("name") or ""
    if name.lower() in service_user_names:
        continue
    if name == "admin":
        continue
    if uid not in users_with_projects:
        orphaned.append({
            "id": uid,
            "name": name,
            "enabled": u.get("Enabled", u.get("enabled", "?"))
        })

print(json.dumps(orphaned, indent=2))
PYEOF
)"

ORPHAN_COUNT="$(echo "$RESULT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

echo
echo "=== ORPHANED USERS ($ORPHAN_COUNT) ==="
echo "$RESULT" | python3 -c '
import json, sys
users = json.load(sys.stdin)
if not users:
    print("  (none found)")
else:
    for u in users:
        status = "enabled" if u["enabled"] in (True, "True", "true") else "disabled"
        print(f"  - {u[\"name\"]}  (id={u[\"id\"]}, {status})")
'

# ------------------------------------------------------------------
# 3. Post to Mattermost (optional)
# ------------------------------------------------------------------
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"

if [[ -n "$MATTERMOST_WEBHOOK_URL" ]]; then
  echo
  echo "[mattermost] posting to webhook"

  echo "$RESULT" > "$TMP_DIR/orphaned.json"

  python3 - "$TMP_DIR/orphaned.json" "$TMP_DIR/payload.json" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    users = json.load(f)

if not users:
    text = "**Orphaned User Scan** — no orphaned users found."
else:
    lines = [f"**Orphaned User Scan** — found {len(users)} user(s) with no project role assignments:\n"]
    lines.append("| User | ID | Status |")
    lines.append("|------|----|----|")
    for u in users:
        status = "enabled" if u["enabled"] in (True, "True", "true") else "disabled"
        lines.append(f"| `{u['name']}` | `{u['id']}` | {status} |")
    text = "\n".join(lines)

with open(sys.argv[2], "w") as f:
    json.dump({"text": text}, f)
PYEOF

  HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d @"$TMP_DIR/payload.json" \
    "$MATTERMOST_WEBHOOK_URL")"

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  posted successfully (HTTP $HTTP_CODE)"
  else
    echo "  warning: Mattermost returned HTTP $HTTP_CODE" >&2
  fi
else
  echo
  echo "[mattermost] MATTERMOST_WEBHOOK_URL not set — skipping post"
  echo "  To enable: export MATTERMOST_WEBHOOK_URL=https://mm.example.com/hooks/xxx"
fi

echo
echo "Orphaned user scan complete. Log at: $LOG_FILE"
