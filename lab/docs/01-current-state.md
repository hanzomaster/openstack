# Current state of the EC2 host

Snapshot taken **2026-04-19** via EC2 instance metadata service + on-host commands.

If any of the values below have drifted when you read this, stop and update
this file first. The scripts in `scripts/` assume this baseline.

## AWS identity

| Key                | Value                     |
| ------------------ | ------------------------- |
| Instance ID        | `i-01cf67908af3f0e61`     |
| Instance type      | `m5.2xlarge`              |
| Region / AZ        | `ap-southeast-1` / `1b`   |
| AMI                | `ami-0e7ff22101b84bcff`   |
| VPC                | `vpc-0f688543451bd207a` (default VPC, `172.31.0.0/16`) |
| Subnet             | `subnet-0b8d31e1e030ff8cb` (`172.31.32.0/20`) |
| Security group     | `launch-wizard-1`         |
| Public IPv4        | `54.255.198.174`          |
| Primary private IP | `172.31.38.210`           |
| MAC (primary ENI)  | `06:20:28:bd:48:75`       |

## OS & hardware

```
Ubuntu 24.04.4 LTS (Noble Numbat)
Kernel: 6.17.0-1010-aws  (x86_64)
CPU:    8 vCPU — Intel Xeon Platinum 8259CL @ 2.50 GHz
RAM:    30 GiB
Swap:   none
```

## Disks (`lsblk`)

```
nvme0n1      60G  root
├─nvme0n1p1  59G  /
├─nvme0n1p14 4M
├─nvme0n1p15 106M /boot/efi
└─nvme0n1p16 913M /boot
```

**Missing compared to the original plan:** no second EBS volume for Cinder
LVM. Option B (see `02-option-b-setup.md`) creates a loopback file to stand
in for it.

## Network interfaces (`ip -br link`)

```
lo        UNKNOWN   <LOOPBACK,UP,LOWER_UP>
ens5      UP        06:20:28:bd:48:75   <BROADCAST,MULTICAST,UP,LOWER_UP>
docker0   DOWN      86:0f:43:8f:ec:32   <NO-CARRIER,BROADCAST,MULTICAST,UP>
```

**Missing compared to the original plan:** no `ens6` second ENI for the
Neutron external interface. Option B creates a veth pair named `veth-ext`
to stand in for it.

## Kolla-relevant software versions

| Tool          | Version         | Note                                 |
| ------------- | --------------- | ------------------------------------ |
| Docker        | `29.4.0`        | already installed by hand            |
| Python        | `3.12.3`        | system default on Noble              |
| ansible-core  | *not installed* | we install inside a venv             |
| kolla-ansible | *not installed* | we install `stable/2025.1` in venv   |
| Terraform     | *not installed* | not needed on this host              |
| AWS CLI       | *not installed* | not needed on this host              |

## Filesystem paths

- `/etc/kolla/` — does not exist yet, created in `scripts/30-deploy-kolla.sh`
- `/var/log/openstack-lab/` — does not exist yet, created in `10-prep-host.sh`
- `/var/lib/cinder-volumes.img` — does not exist yet, created in `10-prep-host.sh`

## What was done by hand (before this repo existed)

Based on inspection; not a guaranteed-complete list:

1. EC2 instance launched from the AWS console with an Ubuntu 24.04 AMI
2. SSH key pair configured so `ubuntu@...` works
3. `docker.io` (or docker-ce) package installed — `docker --version` works
4. No OpenStack-specific configuration yet

Everything beyond this point is scripted in `scripts/`.
