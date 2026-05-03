#!/usr/bin/env bash
# 10-prep-host.sh — Option B host prep for the OpenStack lab.
# Creates the veth pair that stands in for ens6, and the loopback-file
# volume group that stands in for an extra EBS volume. Installs a systemd
# unit so both survive reboots. Safe to re-run.
#
# See docs/02-option-b-setup.md for rationale and teardown.

set -euo pipefail

LOG_DIR=/var/log/openstack-lab
LOG_FILE="$LOG_DIR/10-prep-host.$(date -u +%Y%m%dT%H%M%SZ).log"
LOOP_DEV=/dev/loop10
CINDER_IMG=/var/lib/cinder-volumes.img
CINDER_IMG_SIZE=40G
VG_NAME=cinder-volumes
VETH_NAME=veth-ext
VETH_PEER=veth-ext-peer
SYSTEMD_UNIT=/etc/systemd/system/openstack-lab-loop.service

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root (use sudo)." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
chmod 0755 "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " 10-prep-host.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " host: $(hostname)"
echo "=============================================="

# ------------------------------------------------------------------
# 1. veth pair for the Neutron external interface
# ------------------------------------------------------------------
if ip link show "$VETH_NAME" >/dev/null 2>&1; then
  echo "[veth] $VETH_NAME already exists, skipping creation"
else
  echo "[veth] creating $VETH_NAME <-> $VETH_PEER"
  ip link add "$VETH_NAME" type veth peer name "$VETH_PEER"
fi
ip link set "$VETH_NAME" up
ip link set "$VETH_PEER" up

# ------------------------------------------------------------------
# 2. sparse file + loop device + VG for Cinder LVM
# ------------------------------------------------------------------
if [[ ! -f "$CINDER_IMG" ]]; then
  echo "[cinder] creating $CINDER_IMG_SIZE sparse file at $CINDER_IMG"
  truncate -s "$CINDER_IMG_SIZE" "$CINDER_IMG"
else
  echo "[cinder] $CINDER_IMG already exists, skipping truncate"
fi

if losetup -j "$CINDER_IMG" | grep -q "$LOOP_DEV"; then
  echo "[cinder] $LOOP_DEV already points at $CINDER_IMG"
else
  # Detach any stale loop for this file, then attach at the fixed number
  losetup -j "$CINDER_IMG" | awk -F: '{print $1}' | xargs -r -n1 losetup -d
  [[ -b "$LOOP_DEV" ]] || mknod "$LOOP_DEV" b 7 10 2>/dev/null || true
  losetup "$LOOP_DEV" "$CINDER_IMG"
  echo "[cinder] attached $CINDER_IMG -> $LOOP_DEV"
fi

if ! pvs "$LOOP_DEV" >/dev/null 2>&1; then
  pvcreate -y "$LOOP_DEV"
fi
if ! vgs "$VG_NAME" >/dev/null 2>&1; then
  vgcreate "$VG_NAME" "$LOOP_DEV"
else
  echo "[cinder] VG $VG_NAME already exists"
fi
vgs "$VG_NAME"

# ------------------------------------------------------------------
# 3. systemd unit for reboot persistence
# ------------------------------------------------------------------
cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=OpenStack lab Option-B persistence (veth-ext + loopback VG)
After=local-fs.target
Before=lvm2-activation.service docker.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/sbin/ip link show $VETH_NAME >/dev/null 2>&1 || /sbin/ip link add $VETH_NAME type veth peer name $VETH_PEER'
ExecStart=/sbin/ip link set $VETH_NAME up
ExecStart=/sbin/ip link set $VETH_PEER up
ExecStart=/bin/sh -c '/sbin/losetup -j $CINDER_IMG | grep -q $LOOP_DEV || /sbin/losetup $LOOP_DEV $CINDER_IMG'
ExecStart=/sbin/vgchange -ay $VG_NAME
ExecStop=/sbin/vgchange -an $VG_NAME
ExecStop=/sbin/losetup -d $LOOP_DEV

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openstack-lab-loop.service
echo "[systemd] unit installed and enabled: $SYSTEMD_UNIT"

# ------------------------------------------------------------------
# 4. Verification
# ------------------------------------------------------------------
echo
echo "=== VERIFICATION ==="
ip -br link | grep -E "^(veth-ext|veth-ext-peer)" || { echo "veth missing!" >&2; exit 2; }
losetup -l | grep "$LOOP_DEV" || { echo "loop missing!" >&2; exit 2; }
vgs "$VG_NAME" || { echo "VG missing!" >&2; exit 2; }
systemctl is-enabled openstack-lab-loop.service

echo
echo "Host prep complete. Log at: $LOG_FILE"
echo "Next step: bash scripts/20-install-kolla.sh"
