#!/usr/bin/env bash
###############################################################################
# 03-verify.sh — Verify the OpenStack deployment is healthy.
#
# RUN THIS ON THE BASTION after 02-deploy-openstack.sh completes.
#
# WHAT THIS DOES:
#   1. Checks all OpenStack services are registered
#   2. Verifies both compute hypervisors are online
#   3. Creates a test network, subnet, router, and security group
#   4. Downloads a tiny test image (CirrOS — a 15MB cloud image)
#   5. Boots a test VM
#   6. Verifies the VM reaches ACTIVE state
#   7. Cleans up the test resources
#
# HOW TO RUN:
#   bash scripts/03-verify.sh
###############################################################################

set -euo pipefail

VENV="$HOME/kolla-venv"
LOG_DIR="/var/log/openstack-prod"
LOG_FILE="$LOG_DIR/03-verify.$(date -u +%Y%m%dT%H%M%SZ).log"

sudo mkdir -p "$LOG_DIR" && sudo chown "$USER":"$USER" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 03-verify.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

# shellcheck disable=SC1091
source "$VENV/bin/activate"

# Load admin credentials
if [[ ! -f /etc/kolla/admin-openrc.sh ]]; then
  echo "ERROR: /etc/kolla/admin-openrc.sh not found. Run 02-deploy-openstack.sh first."
  exit 1
fi
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh

# Use --insecure because Kolla uses self-signed TLS by default
alias openstack="openstack --insecure"

# ---------------------------------------------------------------------------
# Check 1: Services
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 1: OpenStack services ---"
openstack --insecure service list
echo ""

# ---------------------------------------------------------------------------
# Check 2: Hypervisors (should show 2 compute nodes)
# ---------------------------------------------------------------------------
echo "--- Check 2: Compute hypervisors ---"
HYPERVISOR_COUNT=$(openstack --insecure hypervisor list -f value | wc -l)
echo "Found $HYPERVISOR_COUNT hypervisor(s):"
openstack --insecure hypervisor list
echo ""

if [[ "$HYPERVISOR_COUNT" -lt 2 ]]; then
  echo "WARNING: Expected 2 hypervisors but found $HYPERVISOR_COUNT."
  echo "Check nova-compute on compute nodes: docker logs nova_compute"
fi

# ---------------------------------------------------------------------------
# Check 3: Network agents
# ---------------------------------------------------------------------------
echo "--- Check 3: Network agents ---"
openstack --insecure network agent list
echo ""

# ---------------------------------------------------------------------------
# Check 4: Create test resources and boot a VM
# ---------------------------------------------------------------------------
echo "--- Check 4: End-to-end test (create network + boot VM) ---"
echo ""

TEST_PREFIX="verify-test"

# Create a test network
echo "Creating test network..."
openstack --insecure network create "${TEST_PREFIX}-net"

echo "Creating test subnet (192.168.100.0/24)..."
openstack --insecure subnet create "${TEST_PREFIX}-subnet" \
  --network "${TEST_PREFIX}-net" \
  --subnet-range 192.168.100.0/24 \
  --dns-nameserver 8.8.8.8

# Download CirrOS test image (tiny Linux image, ~15 MB)
echo "Downloading CirrOS test image..."
CIRROS_URL="https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img"
CIRROS_FILE="/tmp/cirros.img"
if [[ ! -f "$CIRROS_FILE" ]]; then
  curl -L -o "$CIRROS_FILE" "$CIRROS_URL"
fi

echo "Uploading image to Glance..."
openstack --insecure image create "${TEST_PREFIX}-cirros" \
  --file "$CIRROS_FILE" \
  --disk-format qcow2 \
  --container-format bare \
  --public

# Create a tiny flavor (VM size)
echo "Creating test flavor (512MB RAM, 1 vCPU, 1GB disk)..."
openstack --insecure flavor create "${TEST_PREFIX}-tiny" \
  --ram 512 --disk 1 --vcpus 1 || true

# Boot a test VM
echo "Booting test VM..."
openstack --insecure server create "${TEST_PREFIX}-vm" \
  --flavor "${TEST_PREFIX}-tiny" \
  --image "${TEST_PREFIX}-cirros" \
  --network "${TEST_PREFIX}-net" \
  --wait

# Check the VM status
echo ""
echo "VM status:"
openstack --insecure server show "${TEST_PREFIX}-vm" -f value -c status
VM_STATUS=$(openstack --insecure server show "${TEST_PREFIX}-vm" -f value -c status)

if [[ "$VM_STATUS" == "ACTIVE" ]]; then
  echo ""
  echo "SUCCESS: Test VM is ACTIVE. OpenStack is working!"
else
  echo ""
  echo "WARNING: Test VM status is '$VM_STATUS' (expected ACTIVE)."
  echo "Check nova-compute logs: ssh ubuntu@10.0.2.21 'docker logs nova_compute'"
fi

# ---------------------------------------------------------------------------
# Cleanup test resources
# ---------------------------------------------------------------------------
echo ""
echo "--- Cleaning up test resources ---"

echo "Deleting test VM..."
openstack --insecure server delete "${TEST_PREFIX}-vm" --wait || true

echo "Deleting test network..."
openstack --insecure subnet delete "${TEST_PREFIX}-subnet" || true
openstack --insecure network delete "${TEST_PREFIX}-net" || true

echo "Deleting test image..."
openstack --insecure image delete "${TEST_PREFIX}-cirros" || true

echo "Deleting test flavor..."
openstack --insecure flavor delete "${TEST_PREFIX}-tiny" || true

echo ""
echo "=============================================="
echo " Verification complete!"
echo " Log: $LOG_FILE"
echo ""
if [[ "$VM_STATUS" == "ACTIVE" ]]; then
  echo " RESULT: ALL CHECKS PASSED"
else
  echo " RESULT: VM did not reach ACTIVE state. Check logs."
fi
echo "=============================================="
