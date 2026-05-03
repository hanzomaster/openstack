#!/bin/bash
###############################################################################
# bastion-userdata.sh — cloud-init script for the bastion host on Azure.
#
# WHAT IS CLOUD-INIT?
#   When Azure launches a new VM, it can run a script automatically on first
#   boot via the "custom_data" property. This is called cloud-init. It runs
#   as root. You never need to run it manually — Azure does it for you.
#
# WHAT THIS SCRIPT INSTALLS:
#   - Basic build tools (gcc, python3-dev, etc.)
#   - Python 3 venv support (for Kolla-Ansible later)
#   - Ansible itself is NOT installed here — the setup script does that
#     because it needs an interactive shell for the venv
#
# AFTER THIS RUNS:
#   SSH to the bastion and run: scripts/01-setup-bastion.sh
###############################################################################

set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- System packages needed to build Python extensions (ansible, kolla) ---
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
  libdbus-1-dev \
  libglib2.0-dev \
  pkg-config \
  jq \
  tmux \
  htop

# --- Marker: lets the setup script verify cloud-init completed ---
mkdir -p /var/log/openstack-prod
echo "bastion cloud-init completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > /var/log/openstack-prod/00-bastion-userdata.log

# --- Cloud marker: lets 01-setup-bastion.sh branch on cloud provider ---
# Drives Azure-only behavior in the setup script: auto-patches globals.yml
# NIC names (eth0/eth1) and skips AWS-only Kolla precheck patches.
mkdir -p /etc/openstack-prod
echo "azure" > /etc/openstack-prod/cloud
