#!/bin/bash
# cloud-init user-data for a fresh OpenStack lab host.
#
# Mirrors the "initial setup done by hand" that happened on
# i-01cf67908af3f0e61. Running this on a fresh instance brings it to the
# same starting state that `lab/scripts/10-prep-host.sh` expects.

set -euxo pipefail

# ---- Base packages ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg \
  python3-dev python3-venv python3-pip \
  git libffi-dev gcc libssl-dev \
  lvm2

# ---- Docker (official CE repo; same approach as the hand-made host) ----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu
systemctl enable --now docker

# ---- Sanity marker: lets scripts/10-prep-host.sh verify we got here ----
mkdir -p /var/log/openstack-lab
echo "user-data completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > /var/log/openstack-lab/00-user-data.log
