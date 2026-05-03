# OpenStack Production-Like Cluster

Multi-node OpenStack deployment using Kolla-Ansible, with a bastion
(jump server) for secure access to private nodes. The IaC layer is
provided for two clouds — pick one:

- **AWS** (EC2, VPC, NAT Gateway): see [aws/](aws/) — this README walks
  through the AWS path end-to-end.
- **Azure** (VMs, VNet, NAT Gateway): see [azure/README.md](azure/README.md)
  for the Azure-specific instructions.

Everything *after* infrastructure provisioning — Kolla configuration in
[kolla-config/](kolla-config/) and deploy scripts in [scripts/](scripts/) —
is shared between both clouds.

The rest of this README documents the AWS deployment.

## Architecture

```
YOUR LAPTOP
    │
    │  SSH (port 22)
    ▼
┌────────────────────────────────────────────────────────────────────┐
│  AWS VPC  10.0.0.0/16                                              │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Public Subnet 10.0.1.0/24                                   │  │
│  │                                                              │  │
│  │  Bastion (t3.small)                                          │  │
│  │  10.0.1.10 + Elastic IP (public)                             │  │
│  │  Runs: Kolla-Ansible, Ansible                                │  │
│  │                                                              │  │
│  └─────────────────────────────┬────────────────────────────────┘  │
│                                │ SSH                               │
│  ┌─────────────────────────────▼────────────────────────────────┐  │
│  │  Private Subnet 10.0.2.0/24 (NAT Gateway for outbound)       │  │
│  │                                                              │  │
│  │  Controller (m5.large)       10.0.2.10                       │  │
│  │  ├── ens5: management        10.0.2.10                       │  │
│  │  ├── ens5: VIP (HAProxy)     10.0.2.250  (secondary IP)      │  │
│  │  └── ens6: neutron external  10.0.2.11   (second ENI)        │  │
│  │  Runs: Keystone, Glance, Nova API, Neutron Server,           │  │
│  │        Horizon, Cinder API, MariaDB, RabbitMQ,               │  │
│  │        Memcached, HAProxy                                    │  │
│  │                                                              │  │
│  │  Compute-1 (m5.large)       10.0.2.21                        │  │
│  │  ├── ens5: management        10.0.2.21                       │  │
│  │  └── /dev/nvme1n1: 40GB      Cinder LVM (cinder-volumes)     │  │
│  │  Runs: Nova Compute, Neutron OVS Agent, Cinder Volume        │  │
│  │                                                              │  │
│  │  Compute-2 (m5.large)       10.0.2.22                        │  │
│  │  ├── ens5: management        10.0.2.22                       │  │
│  │  └── /dev/nvme1n1: 40GB      Cinder LVM (cinder-volumes)     │  │
│  │  Runs: Nova Compute, Neutron OVS Agent, Cinder Volume        │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

## Cost Estimate

| Resource        | Type     | Approx $/hr             | Purpose                     |
| --------------- | -------- | ----------------------- | --------------------------- |
| Bastion         | t3.small | $0.023                  | Jump server + runs Ansible  |
| Controller      | m5.large | $0.096                  | OpenStack control plane     |
| Compute-1       | m5.large | $0.096                  | Runs VMs                    |
| Compute-2       | m5.large | $0.096                  | Runs VMs                    |
| NAT Gateway     | managed  | $0.045                  | Outbound internet for nodes |
| EBS (root x4)   | gp3      | ~$0.02                  | OS disks                    |
| EBS (cinder x2) | gp3      | ~$0.005                 | Block storage for OpenStack |
| Elastic IPs x2  | —        | free (in use)           | Bastion + NAT               |
| **Total**       |          | **~$0.38/hr (~$9/day)** |                             |

Stop instances when not in use to save money (see Teardown section).

## Prerequisites

Before you start, you need:

1. **AWS Account** with permissions to create VPCs, EC2 instances, NAT Gateways
2. **AWS CLI configured** on your laptop:

   ```bash
   # Install AWS CLI (macOS)
   brew install awscli

   # Configure with your access key
   aws configure
   # Enter: Access Key ID, Secret Access Key, Region (ap-southeast-1), Output (json)
   ```

3. **Terraform installed** on your laptop:

   ```bash
   # macOS
   brew install terraform

   # Verify
   terraform --version    # should be >= 1.5
   ```

4. **An EC2 Key Pair** created in the AWS Console:
   - Go to: AWS Console -> EC2 -> Key Pairs -> Create Key Pair
   - Name it something memorable (e.g., "openstack-prod")
   - Download the .pem file
   - Move it: `mv ~/Downloads/openstack-prod.pem ~/.ssh/`
   - Set permissions: `chmod 400 ~/.ssh/openstack-prod.pem`
5. **Your public IP** (for SSH access):

   ```bash
   curl -s https://checkip.amazonaws.com
   # Note this down — you'll need it as "YOUR_IP/32"
   ```

## File Structure

```
prod-setup/
├── README.md                   <- you are here (AWS guide)
├── .gitignore                  <- keeps secrets out of git
├── aws/
│   └── terraform/
│       ├── main.tf             <- all AWS infrastructure (VPC, instances, etc.)
│       ├── variables.tf        <- input variables with defaults
│       ├── outputs.tf          <- values printed after apply (IPs, SSH commands)
│       ├── terraform.tfvars.example <- copy to terraform.tfvars and fill in
│       ├── bastion-userdata.sh <- cloud-init script for bastion (runs on first boot)
│       └── node-userdata.sh    <- cloud-init script for OpenStack nodes
├── azure/
│   ├── README.md               <- Azure-specific deployment guide
│   ├── .gitignore
│   └── terraform/              <- mirror of aws/terraform/, but for Azure
├── kolla-config/
│   ├── globals.yml             <- Kolla-Ansible overrides (services, networking)
│   └── multinode               <- Ansible inventory (which node plays which role)
└── scripts/
    ├── 01-setup-bastion.sh     <- install tools + configure bastion
    ├── 02-deploy-openstack.sh  <- run Kolla-Ansible to deploy OpenStack
    └── 03-verify.sh            <- test the deployment (boot a VM)
```

## Step-by-Step Deployment Guide

### Phase 1: Create Infrastructure (from your laptop)

This phase runs Terraform on your laptop to create all the AWS resources.

```bash
# 1. Navigate to the terraform directory
cd prod-setup/aws/terraform

# 2. Create your config file from the example
cp terraform.tfvars.example terraform.tfvars

# 3. Edit terraform.tfvars — fill in your key pair name and IP
#    Example content:
#      key_name = "openstack-prod"
#      my_ip    = "203.0.113.42/32"
nano terraform.tfvars    # or: vim, code, etc.

# 4. Initialize Terraform (downloads the AWS provider plugin)
#    This creates a .terraform/ directory — run once per project.
terraform init

# 5. Preview what Terraform will create (dry run — changes nothing)
#    This shows you a plan: what will be created, modified, or destroyed.
#    Read through it to make sure it looks right.
terraform plan -out=plan.out

# 6. Apply the plan (actually create the resources in AWS)
#    Type "yes" when prompted (or use the saved plan to skip the prompt).
#    This takes 3-5 minutes.
terraform apply plan.out

# 7. Note the outputs — you'll need them for the next steps
#    Terraform prints: bastion IP, SSH commands, inventory, etc.
terraform output
```

**What just happened?**

Terraform created all of this in AWS:

- A new VPC with public and private subnets
- Internet Gateway + NAT Gateway
- Security groups (firewall rules)
- 4 EC2 instances (bastion + controller + 2 computes)
- Elastic IPs for the bastion and NAT
- Extra EBS volumes on compute nodes for Cinder

### Phase 2: Configure SSH Access (from your laptop)

Now set up SSH so you can easily reach all nodes.

```bash
# 1. Get the SSH config snippet from Terraform
terraform output ssh_config

# 2. Paste the output into your SSH config file
#    (on your laptop, NOT the bastion)
nano ~/.ssh/config    # paste the output at the bottom

# 3. Test: SSH to the bastion
ssh bastion

# If this works, you should see an Ubuntu prompt.
# Type "exit" to go back to your laptop.

# 4. Test: SSH through the bastion to the controller
#    ProxyJump in the SSH config makes this transparent.
ssh controller

# 5. Test: SSH through the bastion to compute nodes
ssh compute-1
ssh compute-2
```

**Troubleshooting SSH:**

- "Connection refused": Wait 2-3 minutes for the instance to finish booting
- "Permission denied": Check that your .pem file has `chmod 400` permissions
- "Host key verification failed": Run `ssh-keygen -R <ip>` to clear old keys

### Phase 3: Set Up the Bastion (on the bastion)

SSH to the bastion and run the setup script. This installs Kolla-Ansible
and prepares everything for the OpenStack deployment.

```bash
# 1. SSH to the bastion
ssh bastion

# 2. Wait for cloud-init to finish (check the log exists)
#    Cloud-init is the script that runs on first boot to install packages.
#    It usually takes 1-2 minutes after the instance launches.
cat /var/log/openstack-prod/00-bastion-userdata.log
# Should show: "bastion cloud-init completed at ..."
# If the file doesn't exist yet, wait and try again.

# 3. Clone this repo onto the bastion
git clone <your-repo-url>
cd openstack/prod-setup

# 4. Run the setup script
bash scripts/01-setup-bastion.sh
```

**What this script does:**

1. Generates an SSH key pair on the bastion
2. Asks you to copy the public key to all nodes (see below)
3. Tests SSH connectivity to all nodes
4. Installs Kolla-Ansible in a Python venv
5. Copies configs to /etc/kolla/
6. Generates random passwords for all OpenStack services

**Copying the bastion's SSH key to nodes:**

The script will print the public key and instructions. The easiest way
is to use `ssh-copy-id` from the bastion. But since the bastion's key
isn't on the nodes yet, you need to use SSH agent forwarding:

```bash
# On your LAPTOP (not the bastion), start SSH agent and add your key:
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/openstack-prod.pem

# SSH to the bastion WITH agent forwarding (-A flag):
ssh -A bastion

# Now from the bastion, copy its key to each node:
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.10    # controller
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.21    # compute-1
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@10.0.2.22    # compute-2

# Verify each one works:
ssh ubuntu@10.0.2.10 hostname    # should print the controller's hostname
ssh ubuntu@10.0.2.21 hostname    # should print compute-1's hostname
ssh ubuntu@10.0.2.22 hostname    # should print compute-2's hostname
```

### Phase 4: Deploy OpenStack (on the bastion)

This is the main event. Kolla-Ansible will deploy all OpenStack services
as Docker containers across all nodes.

```bash
# On the bastion:
cd openstack/prod-setup
bash scripts/02-deploy-openstack.sh
```

**This takes 45-60 minutes.** Use `tmux` to avoid losing progress if
your SSH connection drops:

```bash
# Start a tmux session (persists even if SSH disconnects)
tmux new -s deploy

# Run the deploy inside tmux
bash scripts/02-deploy-openstack.sh

# If your SSH drops, reconnect and reattach:
ssh bastion
tmux attach -t deploy
```

**What happens during deployment:**

| Phase             | Duration | What it does                                         |
| ----------------- | -------- | ---------------------------------------------------- |
| bootstrap-servers | ~5 min   | Configures Docker, kernel params, NTP on all nodes   |
| prechecks         | ~3 min   | Validates everything is ready (ports, disks, Docker) |
| deploy            | ~35 min  | Pulls Docker images, starts all OpenStack containers |
| post-deploy       | ~2 min   | Generates admin credentials (admin-openrc.sh)        |

### Phase 5: Verify (on the bastion)

```bash
# Run the verification script (creates a test VM and cleans up)
bash scripts/03-verify.sh
```

Or verify manually:

```bash
# Load admin credentials
source /etc/kolla/admin-openrc.sh

# List OpenStack services
openstack --insecure service list

# List compute hypervisors (should show 2)
openstack --insecure hypervisor list

# List network agents
openstack --insecure network agent list
```

### Phase 6: Access Horizon Dashboard (from your laptop)

Horizon is the OpenStack web UI. Since it's on a private network, you
access it via an SSH tunnel.

```bash
# On your laptop:
ssh -L 8080:10.0.2.250:80 bastion

# Now open in your browser:
#   http://localhost:8080
#
# Login:
#   Username: admin
#   Password: (get it from the bastion)

# To get the admin password, on the bastion:
grep keystone_admin_password /etc/kolla/passwords.yml
```

## Teardown / Cost Control

### Stop instances (keep data, stop paying for compute)

```bash
# From your laptop (with AWS CLI):
# Get instance IDs from Terraform
cd prod-setup/aws/terraform
terraform output

# Stop all instances
aws ec2 stop-instances --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>
```

Note: The NAT Gateway continues to cost ~$0.045/hr even when instances
are stopped. To fully stop costs, destroy everything.

### Start instances back up

```bash
aws ec2 start-instances --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>

# Wait a few minutes for boot, then SSH in.
# OpenStack containers auto-restart with Docker.
```

### Destroy everything (delete all AWS resources)

```bash
cd prod-setup/aws/terraform
terraform destroy
# Type "yes" to confirm. This deletes EVERYTHING — VPC, instances, disks, all data.
```

## Troubleshooting

### "Connection timed out" when SSHing to bastion

- Check that `my_ip` in terraform.tfvars matches your current public IP
  (it changes if you switch networks/VPNs)
- Run `curl -s https://checkip.amazonaws.com` to check
- Update terraform.tfvars and run `terraform apply` to update the security group

### Cloud-init hasn't finished

```bash
# Check cloud-init status on any instance
sudo cloud-init status
# "status: running" = still going
# "status: done"    = finished
# "status: error"   = something failed

# View cloud-init logs
sudo cat /var/log/cloud-init-output.log
```

### Kolla precheck fails

Read the error message — it's usually specific. Common issues:

- **"Docker is not running"**: Wait for cloud-init to finish on that node
- **"Port XXXX is already in use"**: Another service is using the port. Check with `ss -tlnp`
- **"Network interface not found"**: The expected interface (ens5/ens6) doesn't exist. Run `ip -br link` on the node
- **"VG cinder-volumes not found"**: LVM wasn't set up. The deploy script does this automatically, but you can do it manually on the compute node

### A service container is unhealthy

```bash
# SSH to the affected node (from bastion)
ssh ubuntu@10.0.2.10   # or .21, .22

# List all Kolla containers
docker ps -a --format "table {{.Names}}\t{{.Status}}"

# View logs for a specific container
docker logs nova_compute
docker logs neutron_openvswitch_agent

# Restart a specific container
docker restart keystone
```

### Redeploy after fixing an issue

Kolla-Ansible is idempotent — re-running is safe:

```bash
source ~/kolla-venv/bin/activate
kolla-ansible deploy -i ~/multinode
```

## Key Concepts Glossary

| Term               | What it is                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------- |
| **Terraform**      | Infrastructure-as-code tool. You describe what you want (VPC, instances), it creates them in AWS. |
| **Ansible**        | Configuration management tool. Connects to servers via SSH and runs tasks (install, configure).   |
| **Kolla-Ansible**  | An Ansible project that deploys OpenStack as Docker containers.                                   |
| **Bastion/Jump**   | A small server that's your gateway into the private network. Only it has a public IP.             |
| **VPC**            | Virtual Private Cloud — your own isolated network in AWS.                                         |
| **Subnet**         | A subdivision of a VPC. Public subnets have internet access; private ones don't.                  |
| **NAT Gateway**    | Lets private instances make outbound connections (apt-get, docker pull) without being exposed.    |
| **Security Group** | A virtual firewall. Rules say who can connect on which ports.                                     |
| **ENI**            | Elastic Network Interface — a virtual network card attached to an instance.                       |
| **EBS**            | Elastic Block Store — a virtual disk attached to an instance.                                     |
| **VIP**            | Virtual IP — a floating IP that HAProxy binds to. All OpenStack APIs are served here.             |
| **HAProxy**        | Load balancer. Sits on the VIP and forwards API requests to the right service.                    |
| **Keystone**       | OpenStack identity service (authentication + authorization).                                      |
| **Glance**         | OpenStack image service (stores VM images like Ubuntu, CirrOS).                                   |
| **Nova**           | OpenStack compute service (manages VMs).                                                          |
| **Neutron**        | OpenStack networking service (virtual networks, routers, floating IPs).                           |
| **Cinder**         | OpenStack block storage (virtual disks that attach to VMs).                                       |
| **Horizon**        | OpenStack web dashboard.                                                                          |
| **LVM**            | Linux Logical Volume Manager. Cinder uses it to carve virtual disks from a physical disk.         |
| **cloud-init**     | A tool that runs scripts on first boot of a cloud instance (user-data).                           |
