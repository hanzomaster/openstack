# Option B: host prep with veth + loopback-VG

This document explains what `scripts/10-prep-host.sh` does, and why. Read
it before running the script — these actions are reversible but touch
systemd and LVM state.

## What we're standing up

| Resource                      | Real version (Option A)   | Option B stand-in            |
| ----------------------------- | ------------------------- | ---------------------------- |
| Neutron external interface    | second AWS ENI `ens6`     | `veth-ext` (veth pair)       |
| Cinder LVM volume group       | extra EBS `/dev/sdb` (40G)| loop device on `/var/lib/cinder-volumes.img` (40G sparse) |
| Log directory                 | —                         | `/var/log/openstack-lab/`    |

## Why veth for the external interface

Neutron wants an interface to plug the `br-ex` OVS bridge into. It doesn't
require that interface to actually carry traffic off-host — it just needs
something L2-shaped to bind to. A veth pair gives us two kernel-level
endpoints wired back-to-back; we set both `up`, hand `veth-ext` to
Neutron, and leave `veth-ext-peer` dangling.

Consequence: you cannot assign AWS-visible floating IPs. Tenant networks
still function internally, so instance-to-instance traffic and all Keystone
/ Horizon / API flows work fine. Access from your laptop is via SSH tunnel,
not a floating IP. This matches the original plan.

## Why a loopback file for Cinder

`pvcreate` / `vgcreate` / `lvcreate` operate on any block device. A
loopback device backed by a sparse file qualifies. Cinder's LVM driver
talks to the VG name, not to the physical disk — so as long as
`cinder-volumes` exists and has free extents, it's happy.

Consequence: throughput is limited by the root EBS (gp3, ~125 MB/s). Fine
for lab-scale create/attach/detach. The sparse file grows on first write
and never shrinks until you delete it.

## Persistence across reboots

A naive loop device disappears on reboot. Option B installs a systemd unit
`openstack-lab-loop.service` that:

1. Runs before `lvm2-activation.service` (type=oneshot, RemainAfterExit=yes)
2. Calls `losetup /dev/loop10 /var/lib/cinder-volumes.img`
3. Calls `vgchange -ay cinder-volumes`

The veth pair is recreated by the same unit — veth links also disappear on
reboot, and Neutron's containers expect to find `veth-ext` present at
agent startup.

## Reversing Option B (if you later move to Option A)

```bash
# Stop kolla first or at minimum cinder-volume + neutron-openvswitch-agent
sudo systemctl disable --now openstack-lab-loop.service
sudo rm /etc/systemd/system/openstack-lab-loop.service
sudo systemctl daemon-reload

# Tear down the LVM stack
sudo vgchange -an cinder-volumes
sudo vgremove -y cinder-volumes
sudo pvremove -y /dev/loop10
sudo losetup -d /dev/loop10
sudo rm /var/lib/cinder-volumes.img

# Remove the veth
sudo ip link del veth-ext
```

Then do Option A:

```bash
# From a box with awscli (your laptop)
aws ec2 create-network-interface \
  --subnet-id subnet-0b8d31e1e030ff8cb \
  --groups <sg-id> \
  --description "openstack-neutron" \
  --no-source-dest-check

aws ec2 attach-network-interface \
  --instance-id i-01cf67908af3f0e61 \
  --network-interface-id <new-eni-id> \
  --device-index 1

aws ec2 create-volume --size 40 --volume-type gp3 \
  --availability-zone ap-southeast-1b
aws ec2 attach-volume \
  --volume-id <vol-id> \
  --instance-id i-01cf67908af3f0e61 \
  --device /dev/sdb
```

Then on the host: `netplan` up `ens6`, `pvcreate /dev/nvme1n1`,
`vgcreate cinder-volumes /dev/nvme1n1`, edit `globals.yml` to set
`neutron_external_interface: "ens6"`, and redeploy.

## Verification after `10-prep-host.sh` runs

```bash
ip -br link | grep veth-ext              # veth-ext UP, veth-ext-peer UP
losetup -l | grep loop10                 # /dev/loop10 → /var/lib/cinder-volumes.img
sudo vgs cinder-volumes                  # VG present, ~40G free
systemctl is-enabled openstack-lab-loop  # enabled
```

All four should report success before moving on to `20-install-kolla.sh`.
