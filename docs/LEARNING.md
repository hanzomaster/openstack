# OpenStack on AWS — Complete Learning Reference

> Written: 2026-04-26  
> Purpose: Everything built in this project, explained from first principles.  
> Audience: Future-you (and anyone who inherits this).

---

## Table of Contents

1. [What We Built and Why](#1-what-we-built-and-why)
2. [Repository Layout](#2-repository-layout)
3. [Technology Stack Explained](#3-technology-stack-explained)
4. [Architecture: Lab (Single-Node)](#4-architecture-lab-single-node)
5. [Architecture: Prod-Like (Multi-Node)](#5-architecture-prod-like-multi-node)
6. [AWS Infrastructure Deep Dive](#6-aws-infrastructure-deep-dive)
7. [Networking Explained](#7-networking-explained)
8. [Kolla-Ansible Configuration](#8-kolla-ansible-configuration)
9. [Deployment Workflow: Step by Step](#9-deployment-workflow-step-by-step)
10. [OpenStack Services — What Each One Does](#10-openstack-services--what-each-one-does)
11. [PoC Scripts](#11-poc-scripts)
12. [Cost Analysis](#12-cost-analysis)
13. [Operations Runbook](#13-operations-runbook)
14. [Troubleshooting Guide](#14-troubleshooting-guide)
15. [Key Concepts Glossary](#15-key-concepts-glossary)
16. [Lessons Learned and Gotchas](#16-lessons-learned-and-gotchas)

---

## 1. What We Built and Why

### The Goal

Run a realistic, multi-node **OpenStack** cluster on **AWS EC2** — good enough to:
- Learn OpenStack architecture hands-on
- Develop and test automation scripts against real OpenStack APIs
- Prototype PoC tooling (cluster inventory, orphan detection, RBAC custom roles)

### Two Environments

| Environment | Location | Purpose |
|---|---|---|
| **Lab** (`lab/`) | Single m5.2xlarge EC2, pre-existing | Quick iteration, single-node all-in-one |
| **Prod-like** (`prod-setup/`) | 4 EC2 instances provisioned by Terraform | Realistic multi-node, proper separation |

### What "OpenStack" Means Here

OpenStack is a collection of interoperating services that together behave like a private cloud — you get compute (VMs), networking (virtual L2/L3), block storage (virtual disks), image storage, and a web dashboard. We deployed **OpenStack 2025.1 "Epoxy"** using **Kolla-Ansible**, which packages every service as a Docker container.

---

## 2. Repository Layout

```
openstack/
├── docs/
│   └── LEARNING.md          ← this file
│
├── lab/                     ← single-node lab on a pre-existing EC2
│   ├── docs/
│   │   ├── 01-current-state.md     ← snapshot of the EC2 host before anything was done
│   │   ├── 02-option-b-setup.md    ← how we faked a second NIC + extra disk
│   │   └── 03-kolla-deploy.md      ← Kolla install + deploy steps for single-node
│   ├── kolla-config/
│   │   └── globals.yml             ← single-node Kolla overrides
│   └── scripts/
│       ├── 10-prep-host.sh         ← create veth + loopback LVM (Option B)
│       ├── 20-install-kolla.sh     ← install kolla-ansible in a venv
│       ├── 30-deploy-kolla.sh      ← kolla bootstrap + prechecks + deploy + post-deploy
│       ├── 40-fixtures.sh          ← create demo project/users for PoC tickets
│       ├── 50-poc-cluster-info.sh  ← Ticket 1: cluster snapshot (JSON + Markdown)
│       ├── 51-poc-orphaned-users.sh ← Ticket 2: find users with no role assignments
│       ├── 52-poc-readonly-role.sh  ← Ticket 3: create readonly-auditor RBAC role
│       └── 53-verify-readonly-role.sh ← verify the readonly role works
│
└── prod-setup/              ← proper multi-node cluster via Terraform
    ├── README.md            ← step-by-step deployment guide
    ├── terraform/
    │   ├── main.tf          ← all AWS resources declared here
    │   ├── variables.tf     ← input variables with defaults + comments
    │   ├── outputs.tf       ← SSH commands, inventory, IPs printed after apply
    │   ├── terraform.tfvars.example  ← copy → terraform.tfvars, fill in key+IP
    │   ├── bastion-userdata.sh  ← cloud-init for bastion (python tools)
    │   └── node-userdata.sh    ← cloud-init for nodes (Docker CE + LVM)
    ├── kolla-config/
    │   ├── globals.yml      ← Kolla overrides for the multi-node cluster
    │   └── multinode        ← Ansible inventory: maps nodes to OpenStack roles
    └── scripts/
        ├── 01-setup-bastion.sh    ← on bastion: install kolla, config /etc/kolla
        ├── 02-deploy-openstack.sh ← on bastion: kolla deploy
        └── 03-verify.sh           ← boot a CirrOS test VM and clean up
```

---

## 3. Technology Stack Explained

### Terraform

**What it is:** Infrastructure-as-code tool. You describe AWS resources in `.tf` files (declarative HCL language). Terraform figures out what to create/modify/delete to reach your desired state.

**Key commands:**
```bash
terraform init      # Download provider plugins (once per project)
terraform plan      # Dry run — shows what WOULD change, nothing is touched
terraform apply     # Create/update resources to match the .tf files
terraform destroy   # Delete EVERYTHING declared in the .tf files
terraform output    # Print output values (IPs, SSH commands)
```

**How it works internally:**
1. Reads `.tf` files to build a dependency graph
2. Calls AWS APIs in the right order (can't create a subnet before the VPC)
3. Stores state in `terraform.tfstate` — never delete this or Terraform loses track of what it created
4. On next `apply`, compares desired state (`.tf`) vs actual state (`tfstate`) vs real AWS

**Key concepts in our code:**
- `resource "aws_xxx" "name"` — declares something to create
- `data "aws_xxx" "name"` — reads something already in AWS (e.g. latest Ubuntu AMI)
- `var.xxx` — references a variable from `variables.tf` / `terraform.tfvars`
- `aws_xxx.name.id` — references an attribute of another resource (dependency)
- `count = 2` — creates 2 identical resources; reference via `[0]`, `[1]`

---

### Ansible

**What it is:** Agentless configuration management. Connects to servers over SSH, runs tasks (install packages, write files, restart services). No agent needed on target machines.

**How Kolla uses it:** Kolla-Ansible is a big collection of Ansible playbooks that knows how to deploy OpenStack. When you run `kolla-ansible deploy`, it:
1. Reads the inventory file (`multinode`) to know which nodes exist
2. SSHs into each node
3. Runs tasks: pulls Docker images, generates config files, starts containers

---

### Kolla-Ansible

**What it is:** An official OpenStack project that deploys OpenStack as Docker containers. Each service (Keystone, Nova, Neutron, etc.) runs in its own container. This is much easier than manually installing and configuring each service.

**Key commands:**
```bash
kolla-ansible bootstrap-servers -i ~/multinode   # Prepare nodes (Docker config, packages)
kolla-ansible prechecks -i ~/multinode           # Validate everything is ready
kolla-ansible deploy -i ~/multinode              # Deploy all containers
kolla-ansible post-deploy -i ~/multinode         # Generate admin credentials
kolla-ansible reconfigure -i ~/multinode         # Apply config changes without full redeploy
```

**Key files:**
- `/etc/kolla/globals.yml` — master config (which services, which IPs, which interfaces)
- `/etc/kolla/passwords.yml` — auto-generated random passwords for every service
- `/etc/kolla/admin-openrc.sh` — shell credentials file (source this to use OpenStack CLI)
- `~/multinode` — Ansible inventory mapping nodes to roles

---

### OpenStack CLI (`openstack`)

After deployment, you interact with the cluster via the `openstack` CLI:
```bash
source /etc/kolla/admin-openrc.sh   # Load credentials into environment
openstack --insecure service list   # --insecure = skip TLS cert validation (Kolla uses self-signed certs)
openstack server create ...
openstack network create ...
```

The `--insecure` flag is needed because Kolla deploys with self-signed TLS certificates by default.

---

## 4. Architecture: Lab (Single-Node)

The lab ran on a **single pre-existing EC2 instance** (m5.2xlarge, 8 vCPU, 30 GiB RAM) in `ap-southeast-1`.

### The problem: missing hardware

A proper OpenStack node needs:
1. **Two network interfaces** — one for management traffic, one for Neutron's external network
2. **An extra disk** — for Cinder LVM block storage

The lab EC2 had neither. We used **Option B** workarounds:

| What Kolla expects | What we gave it |
|---|---|
| Second ENI `ens6` for Neutron | `veth-ext` — a virtual ethernet pair (kernel veth) |
| Extra EBS disk `/dev/sdb` | `/dev/loop10` — a loopback device backed by a 40GB sparse file |

### veth pair explained

A **veth pair** is two virtual NICs wired back-to-back inside the kernel. What goes into one end comes out the other. We create `veth-ext` and `veth-ext-peer`:
- Neutron gets `veth-ext` as its external interface
- `veth-ext-peer` dangles, unconnected

Neutron's OVS bridge (`br-ex`) attaches to `veth-ext`. It can't reach the real internet through this, but **all internal API and tenant networking works fine**. You access Horizon via SSH tunnel, not floating IPs.

### Loopback device explained

A **loop device** makes a regular file look like a block device. Steps:
```bash
dd if=/dev/zero of=/var/lib/cinder-volumes.img bs=1M seek=40960 count=0  # 40GB sparse file
losetup /dev/loop10 /var/lib/cinder-volumes.img   # attach as block device
pvcreate /dev/loop10                               # LVM physical volume
vgcreate cinder-volumes /dev/loop10               # LVM volume group
```
Cinder's LVM driver sees `cinder-volumes` VG and uses it normally.

### Persistence

Both the loop device and veth pair disappear on reboot. We installed a **systemd unit** (`openstack-lab-loop.service`) that recreates them at boot:
```
Type=oneshot, RemainAfterExit=yes
ExecStart: losetup + vgchange + ip link add veth-ext
```

---

## 5. Architecture: Prod-Like (Multi-Node)

```
YOUR LAPTOP
    │  SSH (port 22, your IP only)
    ▼
┌──────────────────────────────────────────────────────────┐
│  AWS VPC  10.0.0.0/16  (ap-southeast-1)                  │
│                                                          │
│  Public Subnet 10.0.1.0/24  ──► Internet Gateway        │
│  ┌────────────────────────┐                              │
│  │  BASTION  10.0.1.10    │ ← Elastic IP (public)        │
│  │  t3.small              │   Jump server                │
│  │  Kolla-Ansible here    │                              │
│  └────────────┬───────────┘                              │
│               │ SSH (private network only)               │
│  Private Subnet 10.0.2.0/24  ──► NAT Gateway            │
│  ┌────────────▼───────────────────────────────────────┐  │
│  │ CONTROLLER  10.0.2.10  (m5.large, 2vCPU, 8GB RAM)  │  │
│  │   ens5:  10.0.2.10      (management)               │  │
│  │   ens5:  10.0.2.250     (HAProxy VIP, secondary IP) │  │
│  │   ens6:  10.0.2.11      (Neutron external, 2nd ENI) │  │
│  │   root:  40 GB gp3                                  │  │
│  │ Services: Keystone, Glance, Nova API, Neutron,      │  │
│  │           Cinder API, Horizon, MariaDB, RabbitMQ,   │  │
│  │           Memcached, HAProxy, Placement             │  │
│  │                                                     │  │
│  │ COMPUTE-1  10.0.2.21  (m5.large)                    │  │
│  │   ens5:  10.0.2.21      (management)               │  │
│  │   root:  40 GB gp3                                  │  │
│  │   data:  20 GB gp3      (Cinder LVM: cinder-volumes)│  │
│  │ Services: Nova Compute, Neutron OVS, Cinder Volume  │  │
│  │                                                     │  │
│  │ COMPUTE-2  10.0.2.22  (m5.large)                    │  │
│  │   (same as Compute-1)                               │  │
│  └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### IP Address Map

| Host | Role | Private IP | Notes |
|---|---|---|---|
| Bastion | Jump server | 10.0.1.10 | + Elastic IP (public) |
| Controller | Control plane | 10.0.2.10 | |
| Controller | HAProxy VIP | 10.0.2.250 | Secondary IP on same ENI |
| Controller | Neutron external | 10.0.2.11 | Second ENI (ens6) |
| Compute-1 | Compute node | 10.0.2.21 | |
| Compute-2 | Compute node | 10.0.2.22 | |
| NAT Gateway | Outbound internet | Dynamic | Lives in public subnet |

---

## 6. AWS Infrastructure Deep Dive

### VPC (Virtual Private Cloud)

A VPC is your private network inside AWS. Everything we create lives inside it.

```hcl
resource "aws_vpc" "prod" {
  cidr_block           = "10.0.0.0/16"   # 65,536 IPs
  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

`/16` means 16 bits are the "network" portion, 16 bits are "host" — giving 2^16 = 65,536 possible IPs. Way more than we need, but `/16` is the standard VPC size.

### Subnets

Subnets partition the VPC. We have two:

**Public subnet (10.0.1.0/24):**
- Has a route to the Internet Gateway
- Instances CAN get public IPs
- The bastion lives here

**Private subnet (10.0.2.0/24):**
- NO direct internet access from outside
- Routes outbound traffic through NAT Gateway
- Controller and computes live here — unreachable from the internet

### Internet Gateway vs NAT Gateway

| | Internet Gateway | NAT Gateway |
|---|---|---|
| **Purpose** | Bidirectional internet access | Outbound-only internet access |
| **Who uses it** | Public subnet | Private subnet |
| **Cost** | Free | ~$0.059/hr + $0.059/GB |
| **Directionality** | Both ways | Outbound only |

The **Internet Gateway** lets the bastion be reached from the internet (you SSH to it).  
The **NAT Gateway** lets private nodes download packages (apt-get, docker pull) without being reachable from the internet.

### Route Tables

Route tables are like routing rules: "for destination X, send traffic to Y."

**Public route table:**
```
Destination     Target
10.0.0.0/16     local            (VPC-internal traffic)
0.0.0.0/0       igw-xxxxx        (everything else → Internet Gateway)
```

**Private route table:**
```
Destination     Target
10.0.0.0/16     local            (VPC-internal traffic)
0.0.0.0/0       nat-xxxxx        (everything else → NAT Gateway)
```

### Security Groups (Firewalls)

Security groups are stateful — if you allow outbound traffic on a port, the response automatically gets in.

**Bastion security group:**
```
Inbound:  port 22 (SSH) from YOUR_IP/32 only
Outbound: all traffic allowed
```

**Internal security group (applied to controller + computes):**
```
Inbound:  port 22 (SSH) from bastion-sg
Inbound:  ALL ports from instances in THIS same security group (self-referencing)
Outbound: all traffic allowed
```

The `self = true` rule is important: OpenStack services communicate on many ports (MariaDB:3306, RabbitMQ:5672, Keystone:5000, Nova:8774, Neutron:9696, Glance:9292, Cinder:8776, Horizon:80, VNC:6080...). Rather than enumerate them all, we allow all traffic between nodes that share the same security group.

### EC2 Instance Details

**Bastion (t3.small):**
- Small and cheap — only runs Ansible
- In the PUBLIC subnet with an Elastic IP
- Has cloud-init that installs Python tools

**Controller (m5.large):**
- `m5` = memory-optimized, `large` = 2 vCPU / 8 GB RAM
- **Two ENIs:** primary (management + VIP secondary IP) + secondary (Neutron external)
- 40 GB root disk

**Compute nodes x2 (m5.large each):**
- Same instance type as controller
- **Two EBS volumes:** root (40 GB) + Cinder (20 GB)
- `source_dest_check = false` not needed on compute nodes (only needed on the Neutron ENI)

### ENI (Elastic Network Interface)

An ENI is a virtual NIC. Normally an instance has one (eth0/ens5). The controller has two:

**Why two NICs?**
- `ens5` (primary): All OpenStack API traffic, management, MariaDB, RabbitMQ, etc.
- `ens6` (secondary): Neutron attaches this to the OVS bridge (`br-ex`) for external network traffic. It must NOT have `source_dest_check` — Neutron routes packets whose destination IP isn't this ENI's IP (floating IPs, tenant IPs), and AWS would drop them.

**The VIP (10.0.2.250):**
A secondary private IP assigned to `ens5`. HAProxy binds to this IP. ALL OpenStack API endpoints point here. This design means: if you later add a second controller, you can use keepalived to float the VIP between them — zero-downtime failover.

### EBS Volumes (Elastic Block Store)

EBS is AWS's network-attached storage (virtual disks). Key properties:
- **Persist independently** of the instance — you can detach, reattach, snapshot
- **gp3** = general-purpose SSD, 3000 IOPS baseline, 125 MB/s
- **Cost** = $0.08/GB/month regardless of whether the instance is running
- `encrypted = true` — AES-256 encryption at rest (good practice)

The extra EBS volume on compute nodes becomes the **Cinder LVM backend**:
```
/dev/nvme1n1 (EBS volume)
  └── PV (LVM physical volume)
       └── VG: cinder-volumes
            └── LVs created dynamically when users request block storage
```

### cloud-init (User Data)

When AWS launches a new instance, it can run a script on first boot. This is `user_data` in Terraform:

**Bastion (`bastion-userdata.sh`):** Installs Python build tools, venv, jq, tmux, htop. The bastion needs these to install Kolla-Ansible.

**Nodes (`node-userdata.sh`):** Installs Docker CE (not `docker.io` from Ubuntu — Kolla requires Docker CE from Docker's official repo), LVM2, Python tools. Every OpenStack node must have Docker before Kolla can deploy.

**How to verify it ran:**
```bash
cat /var/log/openstack-prod/00-bastion-userdata.log  # bastion
cat /var/log/openstack-prod/00-node-userdata.log     # nodes
sudo cloud-init status                               # check status
```

---

## 7. Networking Explained

### The Big Picture

```
Internet
   │
   ▼
[Internet Gateway]
   │
   ├──── Public Subnet 10.0.1.0/24
   │     └── Bastion 10.0.1.10 (+ Elastic IP)
   │
   └──── [NAT Gateway]
              │
              └──── Private Subnet 10.0.2.0/24
                    ├── Controller 10.0.2.10
                    │     └── VIP: 10.0.2.250 (secondary IP)
                    │     └── Neutron ext: 10.0.2.11 (2nd ENI)
                    ├── Compute-1: 10.0.2.21
                    └── Compute-2: 10.0.2.22
```

### How SSH Access Works

**From laptop → Bastion:**
```bash
ssh -i ~/.ssh/openstack-prod.pem ubuntu@<bastion-elastic-ip>
```

**From laptop → Controller (via bastion jump):**
```bash
ssh -J ubuntu@<bastion-ip> ubuntu@10.0.2.10
# Or with ~/.ssh/config ProxyJump entry: ssh controller
```

**ProxyJump** makes this transparent — your SSH client connects to the bastion, then tunnels through it to the private node. The private node never needs a public IP.

### How OpenStack Networking Works (Neutron)

Neutron creates virtual networks on top of the physical network:

```
VM in OpenStack
  │
  └── Neutron port (tap device)
       └── OVS bridge (br-int)
            └── VXLAN tunnel (tenant traffic)
                 └── OVS bridge (br-ex)
                      └── ens6 (physical external interface)
                           └── AWS VPC
```

- **Provider network**: Maps to real physical network (our AWS VPC subnet)
- **Tenant network**: Private network inside OpenStack, uses VXLAN tunneling
- **Floating IP**: Public IP attached to a VM so it's reachable from outside its tenant network
- **Router**: L3 device that connects tenant networks to each other or to external

### Why `source_dest_check = false` on the Neutron ENI

AWS checks: "Is the packet source or destination IP one that belongs to this ENI?" If not, it drops the packet. This is normally a security feature (prevents IP spoofing).

But Neutron routes packets for **floating IPs** and **tenant network IPs** — neither of which belongs to the ENI's assigned IPs. We must disable this check on `ens6` so AWS passes these packets through to Neutron.

---

## 8. Kolla-Ansible Configuration

### globals.yml — Key Settings

```yaml
# OpenStack version
kolla_base_distro: "ubuntu"
openstack_release: "2025.1"

# Networking
kolla_internal_vip_address: "10.0.2.250"    # HAProxy VIP — all APIs here
network_interface: "ens5"                    # Management/API traffic
neutron_external_interface: "ens6"           # Neutron external (provider networks)

# Virtualization
nova_compute_virt_type: "qemu"    # EC2 non-metal can't do KVM; QEMU = software emulation

# Services
enable_horizon: "yes"
enable_neutron_provider_networks: "yes"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-volumes"

# Disabled (keep footprint small)
enable_ceph: "no"
enable_swift: "no"
enable_heat: "no"
```

**Why `nova_compute_virt_type: "qemu"`?**  
KVM (hardware virtualization) requires the CPU to expose VMX/SVM instructions directly to the VM. EC2 non-metal instances are themselves VMs, so nested virtualization isn't available by default. QEMU can emulate a full CPU in software — slower (VM boot takes minutes instead of seconds) but functionally identical for lab use.

### Multinode Inventory

Maps each host to its Kolla role(s):

```ini
[control]        ← Runs: APIs, DB, message queue, scheduler
controller ansible_host=10.0.2.10

[network]        ← Runs: Neutron L3/DHCP/metadata agents
controller ansible_host=10.0.2.10

[compute]        ← Runs: nova-compute, neutron-openvswitch-agent
compute-1 ansible_host=10.0.2.21
compute-2 ansible_host=10.0.2.22

[storage]        ← Runs: cinder-volume (LVM backend)
compute-1 ansible_host=10.0.2.21
compute-2 ansible_host=10.0.2.22

[monitoring]
controller ansible_host=10.0.2.10

[deployment]
localhost ansible_connection=local    ← The bastion (where you run kolla-ansible)
```

Notice: `controller` appears in both `[control]` and `[network]`. That's intentional — the controller runs both the API services AND the network agents. In a larger cluster you might split these.

### passwords.yml

Kolla generates random passwords for every service-to-service communication:
```bash
kolla-genpwd    # generates /etc/kolla/passwords.yml
```

Contains entries like:
```yaml
keystone_admin_password: <random>
database_password: <random>
rabbitmq_password: <random>
cinder_keystone_password: <random>
# ... 60+ more
```

**Never commit passwords.yml to git.** The `.gitignore` excludes it.

### admin-openrc.sh

Generated by `post-deploy`. Sets environment variables:
```bash
export OS_AUTH_URL=http://10.0.2.250:5000/v3
export OS_USERNAME=admin
export OS_PASSWORD=<keystone_admin_password>
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
```
`source /etc/kolla/admin-openrc.sh` loads these so `openstack` CLI authenticates.

---

## 9. Deployment Workflow: Step by Step

### Phase 1: Infrastructure (from laptop)

```bash
cd prod-setup/terraform

# 1. Configure
cp terraform.tfvars.example terraform.tfvars
# Edit: key_name = "your-ec2-keypair-name"
#        my_ip = "$(curl -s checkip.amazonaws.com)/32"

# 2. Initialize
terraform init       # Downloads AWS provider plugin → .terraform/

# 3. Plan (dry run)
terraform plan -out=plan.out    # Shows: 23 resources to create

# 4. Apply (creates everything, ~3-5 min)
terraform apply plan.out

# 5. Note outputs
terraform output     # Shows IPs, SSH commands, inventory snippet
```

**What Terraform creates (23 resources in order):**
1. VPC
2. Public + private subnets
3. Internet Gateway
4. Elastic IP for NAT
5. NAT Gateway
6. Public + private route tables
7. Route table associations (×2)
8. Security groups: bastion + internal
9. ENIs: controller-mgmt + controller-neutron
10. EC2 instances: bastion, controller, compute-1, compute-2
11. Elastic IPs: bastion + NAT
12. EBS volumes: embedded in instance definitions

### Phase 2: SSH Config (from laptop)

```bash
# Paste into ~/.ssh/config:
Host bastion
  HostName <bastion-elastic-ip>
  User ubuntu
  IdentityFile ~/.ssh/openstack-prod.pem

Host controller
  HostName 10.0.2.10
  User ubuntu
  IdentityFile ~/.ssh/openstack-prod.pem
  ProxyJump bastion

Host compute-1
  HostName 10.0.2.21
  User ubuntu
  IdentityFile ~/.ssh/openstack-prod.pem
  ProxyJump bastion

Host compute-2
  HostName 10.0.2.22
  User ubuntu
  IdentityFile ~/.ssh/openstack-prod.pem
  ProxyJump bastion
```

### Phase 3: Bastion Setup (on bastion)

```bash
ssh bastion

# Wait for cloud-init
cat /var/log/openstack-prod/00-bastion-userdata.log

# Clone repo
git clone <repo-url>
cd openstack/prod-setup

# Run setup (installs kolla-ansible, configures /etc/kolla)
bash scripts/01-setup-bastion.sh
```

**What the script does:**
1. Generates SSH key on bastion (`~/.ssh/id_rsa`)
2. Prompts you to copy that key to all nodes (needed for Kolla to SSH)
3. Creates Python venv at `~/kolla-venv`
4. Installs: `ansible-core>=2.16`, `kolla-ansible` (from OpenDev git), `docker` SDK
5. Seeds `/etc/kolla/` from Kolla's default config
6. Appends our `globals.yml` overrides to `/etc/kolla/globals.yml`
7. Generates passwords with `kolla-genpwd`
8. Copies `multinode` inventory to `~/multinode`

**Copying SSH key to nodes:**
```bash
# From laptop with SSH agent forwarding:
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/openstack-prod.pem
ssh -A bastion                              # -A = forward agent

# From bastion (agent forwarded, can auth to nodes):
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.10
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.21
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.22
```

### Phase 4: Deploy OpenStack (on bastion)

```bash
# Use tmux — the deploy takes 45-60 min
tmux new -s deploy
bash scripts/02-deploy-openstack.sh
# tmux attach -t deploy  (reconnect if SSH drops)
```

**Four Kolla phases:**

| Phase | Time | What happens |
|---|---|---|
| `bootstrap-servers` | ~5 min | Configures Docker daemon on all nodes, installs pip packages, sets kernel params, NTP |
| `prechecks` | ~3 min | Validates: Docker running, ports free, disk space, interfaces exist, VG exists |
| `deploy` | ~35 min | Pulls Docker images (~2-3 GB), starts 30+ containers in dependency order |
| `post-deploy` | ~2 min | Writes `/etc/kolla/admin-openrc.sh` and `clouds.yaml` |

**Before deploy: Cinder LVM setup**

The script also SSHs to each compute node and creates the LVM VG:
```bash
pvcreate /dev/nvme1n1        # Mark the extra EBS as LVM physical volume
vgcreate cinder-volumes /dev/nvme1n1   # Create volume group named "cinder-volumes"
```
This runs BEFORE `bootstrap-servers` because `prechecks` validates the VG exists.

### Phase 5: Verify

```bash
bash scripts/03-verify.sh
```

The script:
1. Lists services and endpoints
2. Checks 2 hypervisors are online
3. Creates a test network + subnet
4. Downloads CirrOS (~15 MB tiny Linux image)
5. Uploads to Glance
6. Boots a test VM
7. Verifies VM reaches `ACTIVE` state
8. Cleans everything up

### Phase 6: Access Horizon

```bash
# From laptop:
ssh -L 8080:10.0.2.250:80 bastion

# Browser: http://localhost:8080
# User: admin
# Password:
grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}'
```

---

## 10. OpenStack Services — What Each One Does

All of these run as Docker containers on the controller (and some on computes):

| Service | Port | Role |
|---|---|---|
| **Keystone** | 5000 | Identity: authentication (who are you?) and authorization (what can you do?). Every other service validates tokens through Keystone. |
| **Glance** | 9292 | Image service: stores OS images (Ubuntu, CentOS, CirrOS). Nova asks Glance for the image when booting a VM. |
| **Nova** | 8774 | Compute: schedules VMs (Nova Scheduler), manages them (Nova API), and actually runs them (Nova Compute on compute nodes). |
| **Neutron** | 9696 | Networking: virtual L2 networks, L3 routing, DHCP, security groups, floating IPs. Runs OVS (Open vSwitch) on all nodes. |
| **Cinder** | 8776 | Block storage: virtual disks (volumes) that attach to VMs. Like AWS EBS, but OpenStack-managed. Uses LVM on our compute nodes. |
| **Placement** | 8780 | Resource tracking: tracks CPU/RAM/disk available on each compute node. Nova Scheduler queries it to decide where to place VMs. |
| **Horizon** | 80 | Web dashboard: GUI for managing the cluster (create VMs, networks, volumes, etc.). |
| **HAProxy** | — | Load balancer: binds to the VIP (10.0.2.250) and forwards requests to the appropriate service. |
| **MariaDB** | 3306 | Database: all services store their state here (VM records, network configs, user data, image metadata, etc.). |
| **RabbitMQ** | 5672 | Message queue: services communicate asynchronously through it. Example: Nova API sends a "create VM" message → RabbitMQ → Nova Compute picks it up. |
| **Memcached** | 11211 | Cache: speeds up Keystone token validation by caching tokens. |

### Service Communication Flow (Creating a VM)

```
User → openstack server create
  │
  ▼
Keystone (authenticate, return token)
  │
  ▼
Nova API (receive request, validate token with Keystone)
  │
  ▼
Nova Scheduler → Placement (find compute node with enough resources)
  │
  ▼
RabbitMQ (queue "create VM" message for compute node)
  │
  ▼
Nova Compute (on compute-1 or compute-2)
  ├── Glance (download image)
  ├── Neutron (create port, configure networking on this node)
  └── QEMU (actually boot the VM)
```

---

## 11. PoC Scripts

These are proof-of-concept scripts demonstrating common OpenStack admin tasks.

### 40-fixtures.sh — Demo Data

Creates users and projects for testing:

```
demo-proj           ← project (tenant) for most tests
alice, bob          ← members of demo-proj (have "member" role)
orphan-charlie      ← user with NO role assignments (to test orphan detection)
auditor             ← user to receive the readonly-auditor role
```

All OpenStack resources (VMs, networks, volumes) belong to a **project**. The `member` role allows creating/managing resources within a project. The `admin` role allows cluster-wide admin.

### 50-poc-cluster-info.sh — Cluster Snapshot

Collects ALL cluster state into a JSON + Markdown report. Covers:
- Identity: services, endpoints, domains, projects, users, roles, role assignments
- Compute: hypervisors, flavors, availability zones, VMs
- Network: networks, subnets, routers, floating IPs, security groups
- Storage: volumes, volume types
- Images

Output: `/var/log/openstack-lab/cluster-snapshot-<ts>.json` and `.md`

**Why this is useful:**
- Onboarding: new team members can read the Markdown and understand the cluster
- Auditing: see who has access to what
- Capacity planning: see resource counts and hypervisor capacity

### 51-poc-orphaned-users.sh — Orphan Detection

Finds users with **no role assignments** — accounts that exist but can't do anything useful. These are security liabilities (dormant accounts that could be re-activated) and clutter (bloat the user list).

Logic: `openstack user list` → for each user, `openstack role assignment list --user <id>` → if empty, it's orphaned.

### 52-poc-readonly-role.sh — Custom RBAC Role

Creates a `readonly-auditor` role that can **read** everything but **cannot create, modify, or delete**.

**How OpenStack RBAC works:**
- Each API action has a policy rule (e.g. `"os_compute_api:servers:index": "rule:admin_or_owner"`)
- Policy rules live in `/etc/kolla/<service>/policy.yaml`
- Rules can reference role names: `"role:my-role"`

**What the script does:**
1. Creates `readonly-auditor` role in Keystone
2. Assigns it to `auditor` user on `demo-proj`
3. Writes policy overrides for Keystone, Nova, Neutron, Cinder, Glance
4. Allows `readonly-auditor` to call list/show/get actions
5. Policy takes effect after `kolla-ansible reconfigure`

**Example policy rule:**
```yaml
# In /etc/kolla/config/nova/policy.yaml
"is_readonly": "role:readonly-auditor"
"os_compute_api:servers:index": "rule:admin_or_owner or rule:is_readonly"
"os_compute_api:servers:create": "rule:admin_or_owner"    # NOT readonly
```

**To apply:** `kolla-ansible -i ~/multinode reconfigure`  
**To verify:** `bash scripts/53-verify-readonly-role.sh`

---

## 12. Cost Analysis

Pricing in **ap-southeast-1 (Singapore)**. Last verified: April 2026.

### Hourly costs (instances running)

| Resource | Type | $/hr |
|---|---|---|
| Bastion | t3.small | $0.026 |
| Controller | m5.large | $0.120 |
| Compute-1 | m5.large | $0.120 |
| Compute-2 | m5.large | $0.120 |
| NAT Gateway | managed | $0.059 |
| **Compute subtotal** | | **$0.386/hr** |
| **With NAT** | | **$0.445/hr** |

### Storage costs (continuous, even when stopped)

| Disk | Size | $/month |
|---|---|---|
| Bastion root | 20 GB gp3 | $1.84 |
| Controller root | 40 GB gp3 | $3.68 |
| Compute-1 root | 40 GB gp3 | $3.68 |
| Compute-2 root | 40 GB gp3 | $3.68 |
| Compute-1 Cinder | 20 GB gp3 | $1.84 |
| Compute-2 Cinder | 20 GB gp3 | $1.84 |
| **Total EBS** | **180 GB** | **$16.56/mo** |

### Total cost by scenario

| Scenario | $/hr | $/day | $/month |
|---|---|---|---|
| **Everything running** | ~$0.47 | ~$11.30 | ~$338 |
| **Instances stopped** (NAT + EBS still running) | ~$0.08 | ~$1.90 | ~$58 |
| **Instances stopped + NAT deleted** | ~$0.02 | ~$0.46 | ~$17 |
| **`terraform destroy`** | $0 | $0 | $0 |

### Cost-saving decisions

1. **Stop instances when not working:**
   ```bash
   aws ec2 stop-instances --instance-ids i-xxx i-yyy i-zzz i-www
   ```
   Saves ~$0.39/hr. EBS and NAT still cost ~$0.08/hr.

2. **Delete NAT Gateway when idle for days:**
   ```bash
   aws ec2 delete-nat-gateway --nat-gateway-id nat-xxx
   # Wait a few minutes, then release the Elastic IP too
   aws ec2 release-address --allocation-id eipalloc-xxx
   ```
   Saves another ~$0.059/hr = ~$43/month. But private nodes lose internet. Recreate via Terraform when needed.

3. **Destroy everything:**
   ```bash
   terraform destroy
   ```
   Eliminates all costs. Terraform can recreate the cluster in ~5 minutes from scratch.

---

## 13. Operations Runbook

### Start the cluster

```bash
# Start instances (from laptop with AWS CLI)
aws ec2 start-instances \
  --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>

# Wait ~3 min for boot
# Verify Docker containers are running on controller:
ssh controller 'docker ps --format "table {{.Names}}\t{{.Status}}" | head -30'

# Load credentials and test
ssh bastion
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
openstack --insecure service list
```

Note: Docker is configured to `restart: unless-stopped` on all containers, so OpenStack services restart automatically when the instance boots.

### Stop the cluster

```bash
aws ec2 stop-instances \
  --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>
```

EBS volumes and Elastic IPs are preserved. The cluster can be restarted anytime.

### Destroy everything

```bash
cd prod-setup/terraform
terraform destroy
# Type: yes
```

This deletes: VPC, subnets, IGW, NAT, EIPs, security groups, instances, all EBS volumes, ENIs. All data is GONE.

### Redeploy from scratch

```bash
cd prod-setup/terraform
terraform apply plan.out       # ~5 min: infrastructure

ssh bastion
bash scripts/01-setup-bastion.sh    # ~10 min: kolla install
bash scripts/02-deploy-openstack.sh  # ~60 min: OpenStack deploy
bash scripts/03-verify.sh            # ~5 min: verify
```

### Access Horizon dashboard

```bash
# Port-forward from laptop:
ssh -L 8080:10.0.2.250:80 bastion

# Browser: http://localhost:8080
# User: admin
# Password:
ssh bastion 'grep keystone_admin_password /etc/kolla/passwords.yml | awk "{print \$2}"'
```

### Run OpenStack CLI commands

```bash
ssh bastion
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

# Examples:
openstack --insecure service list
openstack --insecure server list --all-projects
openstack --insecure hypervisor list
openstack --insecure network list
openstack --insecure volume list --all-projects
```

### Check container health

```bash
# On controller:
ssh controller 'docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -v "Up "'
# Shows any containers NOT running

# View logs for a specific service:
ssh controller 'docker logs --tail=50 keystone'
ssh controller 'docker logs --tail=50 nova_api'
ssh controller 'docker logs --tail=50 neutron_server'
ssh compute-1  'docker logs --tail=50 nova_compute'
```

### Reconfigure after changing globals.yml

```bash
# After editing /etc/kolla/globals.yml or any policy file:
source ~/kolla-venv/bin/activate
kolla-ansible reconfigure -i ~/multinode

# Or just reconfigure one service:
kolla-ansible reconfigure -i ~/multinode --tags nova
```

### Rotate admin password

```bash
# Edit /etc/kolla/passwords.yml — change keystone_admin_password
# Then:
kolla-ansible reconfigure -i ~/multinode --tags keystone
# Update admin-openrc.sh:
kolla-ansible post-deploy -i ~/multinode
```

---

## 14. Troubleshooting Guide

### SSH: "Connection timed out" to bastion

Your IP changed (switched networks/VPN).
```bash
curl -s checkip.amazonaws.com    # Your current IP
# Update terraform.tfvars: my_ip = "NEW_IP/32"
cd prod-setup/terraform
terraform apply    # Updates the security group
```

### SSH: "Permission denied (publickey)"

```bash
chmod 400 ~/.ssh/openstack-prod.pem   # Key must be 400
ssh -i ~/.ssh/openstack-prod.pem ubuntu@<bastion-ip>  # Test explicitly
```

### cloud-init still running

```bash
sudo cloud-init status    # "running" = still going, "done" = finished
sudo tail -f /var/log/cloud-init-output.log   # Watch it
```

### kolla precheck fails: "Docker is not running"

cloud-init hasn't finished on that node yet.
```bash
ssh ubuntu@10.0.2.21 'sudo cloud-init status'
ssh ubuntu@10.0.2.21 'systemctl is-active docker'
```

### kolla precheck fails: "Network interface not found"

```bash
ssh ubuntu@10.0.2.10 'ip -br link'    # Check ens5, ens6 exist
```
If `ens6` is missing, the second ENI wasn't attached or the node hasn't been rebooted since attachment.

### kolla precheck fails: "VG cinder-volumes not found"

```bash
ssh ubuntu@10.0.2.21 'sudo vgs'       # Should show cinder-volumes
# If missing, run manually:
ssh ubuntu@10.0.2.21 'sudo pvcreate /dev/nvme1n1 && sudo vgcreate cinder-volumes /dev/nvme1n1'
```

### kolla deploy fails partway through

Kolla-Ansible is **idempotent** — just re-run:
```bash
source ~/kolla-venv/bin/activate
kolla-ansible deploy -i ~/multinode
```
It skips already-done steps and retries failed ones.

### A container keeps restarting

```bash
ssh controller 'docker logs nova_api 2>&1 | tail -50'
# Look for the error, fix the config, then:
kolla-ansible reconfigure -i ~/multinode --tags nova
```

### VM stuck in BUILD state

```bash
# Check nova-compute log on the compute node:
ssh compute-1 'docker logs nova_compute 2>&1 | tail -50'

# Check nova scheduler:
ssh controller 'docker logs nova_scheduler 2>&1 | tail -20'

# Check neutron:
ssh compute-1 'docker logs neutron_openvswitch_agent 2>&1 | tail -20'
```

### Can't access Horizon

```bash
# Check haproxy on controller:
ssh controller 'docker logs haproxy 2>&1 | tail -20'

# Check the VIP is assigned on the controller:
ssh ubuntu@10.0.2.10 'ip addr show ens5 | grep 10.0.2.250'

# The tunnel:
ssh -L 8080:10.0.2.250:80 bastion   # Make sure you specify the VIP, not controller's IP
```

---

## 15. Key Concepts Glossary

| Term | Definition |
|---|---|
| **Terraform** | Infrastructure-as-code tool. Declare AWS resources in `.tf` files; Terraform creates/updates/deletes them. |
| **Ansible** | Agentless config management. SSHs into servers and runs tasks. |
| **Kolla-Ansible** | OpenStack project that deploys OpenStack as Docker containers using Ansible. |
| **VPC** | Virtual Private Cloud — your isolated network inside AWS. |
| **Subnet** | Subdivision of a VPC. Public = has IGW route. Private = uses NAT. |
| **Internet Gateway (IGW)** | Connects VPC to the public internet. Bidirectional. |
| **NAT Gateway** | Lets private instances reach the internet (outbound only). ~$0.059/hr. |
| **Route Table** | Traffic routing rules: "destination X → send to Y." |
| **Security Group** | Stateful virtual firewall. Rules = who can connect on which port. |
| **ENI** | Elastic Network Interface — virtual NIC. Instances can have multiple. |
| **EBS** | Elastic Block Store — virtual disk. Persists independently of instance. |
| **Elastic IP** | Static public IP address in AWS. Free when attached to a running instance. |
| **cloud-init** | Script that runs on first boot of an EC2 instance (user-data). |
| **Bastion/Jump server** | Small server in public subnet. Gateway into the private network. |
| **VIP** | Virtual IP — floating IP that HAProxy binds to. All APIs are at this address. |
| **HAProxy** | Load balancer. Forwards requests from VIP to the correct service port. |
| **Keystone** | OpenStack identity: authentication + authorization. Token-based. |
| **Glance** | OpenStack image store. Holds VM OS images. |
| **Nova** | OpenStack compute. Schedules, provisions, and manages VMs. |
| **Neutron** | OpenStack networking. Virtual L2/L3, DHCP, routing, floating IPs. |
| **Cinder** | OpenStack block storage. Virtual disks that attach to VMs. |
| **Placement** | Tracks available resources per compute node. Nova Scheduler uses it. |
| **Horizon** | OpenStack web dashboard (GUI). |
| **MariaDB** | Database used by all OpenStack services for persistent state. |
| **RabbitMQ** | Message queue. Services communicate asynchronously through it. |
| **LVM** | Linux Logical Volume Manager. Cinder uses it to carve virtual disks. |
| **QEMU** | Software CPU emulator. Used instead of KVM on EC2 non-metal instances. |
| **KVM** | Hardware virtualization. Faster than QEMU but requires bare-metal or nested virt. |
| **OVS** | Open vSwitch. Software switch used by Neutron for L2 forwarding. |
| **VXLAN** | Overlay network protocol. Neutron uses it to tunnel tenant L2 traffic over L3. |
| **veth** | Virtual ethernet pair. Two virtual NICs wired back-to-back in the kernel. |
| **ProxyJump** | SSH feature: tunnel through a jump host transparently. |
| **CirrOS** | Tiny (~15 MB) Linux cloud image used for OpenStack testing. |
| **admin-openrc.sh** | Shell file that sets `OS_*` environment variables for OpenStack CLI auth. |
| **idempotent** | Running the same operation multiple times gives the same result. Both Terraform and Kolla-Ansible are idempotent — re-running is safe. |
| **cloud image** | A pre-built VM disk image designed for cloud deployment (has cloud-init, no root password, etc.). |

---

## 16. Lessons Learned and Gotchas

### Infrastructure

1. **`source_dest_check = false` is mandatory on the Neutron ENI.**  
   Without it, AWS silently drops all Neutron-routed traffic. Hard to debug because everything else looks healthy.

2. **The VIP must be in the same subnet as the management interface.**  
   Kolla assigns it as a secondary IP on `ens5`. If you put it in a different subnet, HAProxy binds to it but traffic can't be routed to it.

3. **EBS volumes persist even when you `stop-instances`.**  
   NAT Gateway also keeps charging. The only way to truly stop all costs is `terraform destroy`.

4. **cloud-init takes 1-3 minutes after first boot.**  
   Don't run setup scripts until it finishes. Check: `cat /var/log/openstack-prod/00-*-userdata.log`.

5. **The Elastic IP for the bastion changes only if you release it.**  
   Stopping and starting the instance does NOT change the EIP — it stays attached.

### Kolla-Ansible

6. **Kolla requires Docker CE, not `docker.io` from Ubuntu apt.**  
   The Ubuntu package (`docker.io`) is older and has different paths/behavior that breaks Kolla's prechecks.

7. **`kolla-genpwd` OVERWRITES passwords if you re-run it.**  
   Only run it once. If you re-run after deploy, the new passwords won't match what's in the database — everything breaks. The deploy script checks before running it.

8. **Kolla is idempotent — re-running `deploy` is safe.**  
   Containers that are already running correctly won't be touched. Failed ones will be retried.

9. **`globals.yml` is YAML — a missing space after `:` breaks everything.**  
   `key:value` is wrong. `key: value` is correct. The prechecks will usually catch this.

10. **`kolla-ansible reconfigure` applies config changes without a full redeploy.**  
    Use this after editing `globals.yml` or policy files. Much faster than full deploy.

### OpenStack

11. **`openstack --insecure` is required because Kolla uses self-signed TLS.**  
    The certificate is self-signed to `10.0.2.250` (the VIP). Adding `--insecure` skips the CA check. For production, replace with a proper cert.

12. **QEMU is much slower than KVM.**  
    VMs take 3-5 minutes to boot instead of 30 seconds. The cluster is fully functional but not performance-representative. For performance testing, use bare-metal instances.

13. **The `reader` role in OpenStack isn't enforced by default (pre-Yoga services).**  
    Despite existing, `reader` grants no extra access until you write policy rules for each service. That's why `52-poc-readonly-role.sh` writes `policy.yaml` overrides for every service individually.

14. **Policy files live in `/etc/kolla/config/<service>/policy.yaml` on the bastion.**  
    Kolla mounts these into the containers. After editing, run `kolla-ansible reconfigure --tags <service>`.

15. **RabbitMQ handles all async communication between services.**  
    If RabbitMQ is unhealthy, VMs won't launch (Nova API queues the request but Nova Compute never picks it up). Always check RabbitMQ first when API calls hang.

16. **MariaDB holds all state.**  
    If MariaDB crashes or runs out of disk, the entire cluster becomes read-only (APIs return 500). Monitor disk usage on the controller.

### Lab vs. Prod-like differences

| | Lab (single-node) | Prod-like (multi-node) |
|---|---|---|
| Cinder storage | Loopback file (`/dev/loop10`) | Real EBS volume (`/dev/nvme1n1`) |
| Neutron external | veth pair (`veth-ext`) | Second ENI (`ens6`) |
| Compute separation | All-in-one | Separate compute nodes |
| SSH access | Direct public IP | Bastion jump server |
| Infrastructure | Manual / pre-existing | Terraform-managed |
| Floating IPs | Don't work (veth) | Don't work (no real external routing from AWS) |
| Cost | Single instance | 4 instances + NAT |

---

*End of learning document. Questions? Check the scripts — every line is commented.*
