#!/bin/bash
###############################################################################
# node-userdata.sh — cloud-init script for controller and compute nodes on Azure.
#
# This runs automatically on first boot (as root) for every OpenStack node.
#
# WHAT THIS SCRIPT INSTALLS:
#   - Docker CE (required by Kolla-Ansible — all OpenStack services run
#     as Docker containers)
#   - Python 3 + build tools
#   - LVM2 (needed for Cinder block storage on compute nodes)
#
# AZURE-SPECIFIC NOTES:
#   - On Azure VMs, NICs come up as eth0, eth1, ... (not ens5/ens6 like AWS).
#     This script writes a /etc/openstack-prod/cloud marker so the bastion
#     setup script auto-applies the eth0/eth1 patch to globals.yml without
#     manual intervention.
#   - Disk naming depends on the SKU's controller:
#       v6 / v7 NVMe (e.g. D2as_v7, D2als_v7): OS=/dev/nvme0n1, data=/dev/nvme0n2
#       Older SCSI/virtio (e.g. Dsv5, Dasv5): OS=/dev/sda,    data=/dev/sdb
#     The deploy script (scripts/02-deploy-openstack.sh) auto-detects across
#     these layouts; no manual disk-path edit needed for the supported SKUs.
#
# WHY DOCKER?
#   Kolla-Ansible deploys OpenStack by pulling pre-built Docker images
#   (e.g., kolla/keystone, kolla/nova-compute) and running them as
#   containers. Docker must be installed on every node BEFORE Kolla runs.
###############################################################################

set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- Base packages ---
apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  python3-dev \
  python3-venv \
  python3-pip \
  git \
  libffi-dev \
  gcc \
  libssl-dev \
  lvm2

# --- Docker CE from Docker's official APT repository ---
# We add Docker's GPG key and repo, then install Docker.
# Kolla-Ansible requires Docker CE (Community Edition), not docker.io from Ubuntu.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# shellcheck disable=SC1091
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Allow the admin user (default: ubuntu) to run docker commands without sudo.
# We pull the username from cloud-init metadata if present, else default.
ADMIN_USER="${ADMIN_USER:-ubuntu}"
if id "$ADMIN_USER" &>/dev/null; then
  usermod -aG docker "$ADMIN_USER"
fi

# Enable and start Docker
systemctl enable --now docker

# --- Marker: lets scripts verify cloud-init completed ---
mkdir -p /var/log/openstack-prod
echo "node cloud-init completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > /var/log/openstack-prod/00-node-userdata.log

# --- Cloud marker: lets the bastion setup script branch on cloud provider ---
# Read by scripts/01-setup-bastion.sh when it scp's this file from the
# controller, so it can auto-apply Azure-only patches to globals.yml.
mkdir -p /etc/openstack-prod
echo "azure" > /etc/openstack-prod/cloud
