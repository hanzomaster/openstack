#!/usr/bin/env bash
# 53-verify-readonly-role.sh — Verify the readonly-auditor role works:
# read operations succeed, write operations are denied (HTTP 403).
#
# Run AFTER:
#   1. bash scripts/52-poc-readonly-role.sh
#   2. kolla-ansible -i ~/kolla-inventory reconfigure

set -uo pipefail

LOG_DIR=/var/log/openstack-lab
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/53-verify-readonly-role.$TS.log"
DEMO_PASSWORD='Pass123!'

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 53-verify-readonly-role.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

# ------------------------------------------------------------------
# Source admin creds to read AUTH_URL, then switch to auditor
# ------------------------------------------------------------------
if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "admin-openrc.sh not found — deploy first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh
AUTH_URL="$OS_AUTH_URL"

# Override identity to auditor / demo-proj
export OS_USERNAME=auditor
export OS_PASSWORD="$DEMO_PASSWORD"
export OS_PROJECT_NAME=demo-proj
export OS_AUTH_URL="$AUTH_URL"
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
unset OS_CLOUD

os() { openstack --insecure "$@"; }

PASS=0
FAIL=0

expect_success() {
  local label="$1"; shift
  echo -n "  [READ]  $label ... "
  if output=$("$@" 2>&1); then
    echo "OK"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    echo "    $output" | head -3
    FAIL=$((FAIL + 1))
  fi
}

expect_denied() {
  local label="$1"; shift
  echo -n "  [WRITE] $label ... "
  if output=$("$@" 2>&1); then
    echo "FAIL (should have been denied)"
    echo "    $output" | head -3
    FAIL=$((FAIL + 1))
  else
    if echo "$output" | grep -qi "403\|forbidden\|not authorized\|policy"; then
      echo "DENIED (expected)"
      PASS=$((PASS + 1))
    else
      echo "FAIL (error but not 403)"
      echo "    $output" | head -3
      FAIL=$((FAIL + 1))
    fi
  fi
}

# ------------------------------------------------------------------
# Test suite
# ------------------------------------------------------------------
echo
echo "=== Testing as auditor (readonly-auditor role on demo-proj) ==="

echo
echo "--- Keystone ---"
expect_success "project list"          os project list
expect_success "user list"             os user list
expect_success "role list"             os role list
expect_success "endpoint list"         os endpoint list
expect_denied  "project create"        os project create test-deny-project

echo
echo "--- Nova ---"
expect_success "server list"           os server list
expect_success "flavor list"           os flavor list
expect_success "hypervisor list"       os hypervisor list
expect_success "availability zone list" os availability zone list
expect_denied  "server create"         os server create --flavor m1.tiny --image cirros test-deny-vm

echo
echo "--- Neutron ---"
expect_success "network list"          os network list
expect_success "subnet list"           os subnet list
expect_success "router list"           os router list
expect_success "security group list"   os security group list
expect_denied  "network create"        os network create test-deny-net

echo
echo "--- Cinder ---"
expect_success "volume list"           os volume list
expect_success "volume type list"      os volume type list
expect_denied  "volume create"         os volume create --size 1 test-deny-vol

echo
echo "--- Glance ---"
expect_success "image list"            os image list
expect_denied  "image create"          os image create --disk-format qcow2 --container-format bare --file /dev/null test-deny-img

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo
echo "=============================================="
echo " RESULTS: $PASS/$TOTAL passed, $FAIL/$TOTAL failed"
echo "=============================================="

if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Some tests failed. Check that you ran 'kolla-ansible reconfigure'"
  echo "after 52-poc-readonly-role.sh and that services restarted cleanly."
  exit 1
fi

echo
echo "All tests passed. The readonly-auditor role is working correctly."
echo "Log at: $LOG_FILE"
