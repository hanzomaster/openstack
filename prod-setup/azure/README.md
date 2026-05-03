# OpenStack Production-Like Cluster on Azure

Multi-node OpenStack deployment using Kolla-Ansible on Azure VMs, with a
bastion (jump server) for secure access to private nodes.

This is the Azure mirror of the AWS deployment in [../aws/](../aws/). The
architecture, Kolla configuration, and deploy scripts are identical — only
the IaC layer changes.

> **For the post-`terraform apply` walk-through (SSH bootstrap, Kolla
> deploy, Horizon access), see [DEPLOY.md](DEPLOY.md).**

## Architecture

```
YOUR LAPTOP
    │
    │  SSH (port 22)
    ▼
┌────────────────────────────────────────────────────────────────────┐
│  Azure VNet  10.0.0.0/16  (resource group: openstack-prod-rg)      │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Public Subnet 10.0.1.0/24  (NSG: bastion-nsg)               │  │
│  │                                                              │  │
│  │  Bastion (Standard_D2als_v7)                                 │  │
│  │  10.0.1.10 + Static Public IP                                │  │
│  │  Runs: Kolla-Ansible, Ansible                                │  │
│  │                                                              │  │
│  └─────────────────────────────┬────────────────────────────────┘  │
│                                │ SSH                               │
│  ┌─────────────────────────────▼────────────────────────────────┐  │
│  │  Private Subnet 10.0.2.0/24 (NAT Gateway, NSG: internal-nsg) │  │
│  │                                                              │  │
│  │  Controller (Standard_D2as_v7)                               │  │
│  │  ├── eth0: management        10.0.2.10                       │  │
│  │  ├── eth0: VIP (HAProxy)     10.0.2.250  (secondary IP)      │  │
│  │  └── eth1: neutron external  10.0.2.11   (second NIC)        │  │
│  │  Runs: Keystone, Glance, Nova API, Neutron Server,           │  │
│  │        Horizon, Cinder API, MariaDB, RabbitMQ,               │  │
│  │        Memcached, HAProxy                                    │  │
│  │                                                              │  │
│  │  Compute-1 (Standard_D2as_v7)  10.0.2.21                     │  │
│  │  ├── eth0: management         10.0.2.21                      │  │
│  │  └── /dev/sdc: 40GB           Cinder LVM (cinder-volumes)    │  │
│  │  Runs: Nova Compute, Neutron OVS Agent, Cinder Volume        │  │
│  │                                                              │  │
│  │  Compute-2 (Standard_D2as_v7)  10.0.2.22                     │  │
│  │  ├── eth0: management         10.0.2.22                      │  │
│  │  └── /dev/sdc: 40GB           Cinder LVM (cinder-volumes)    │  │
│  │  Runs: Nova Compute, Neutron OVS Agent, Cinder Volume        │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

## Cost Estimate (southeastasia, on-demand, Linux pay-as-you-go)

| Resource          | Type              | Approx $/hr              | Purpose                     |
| ----------------- | ----------------- | ------------------------ | --------------------------- |
| Bastion           | Standard_D2als_v7 | $0.069                   | Jump server + runs Ansible  |
| Controller        | Standard_D2as_v7  | $0.100                   | OpenStack control plane     |
| Compute-1         | Standard_D2as_v7  | $0.100                   | Runs VMs                    |
| Compute-2         | Standard_D2as_v7  | $0.100                   | Runs VMs                    |
| NAT Gateway       | Standard          | $0.045                   | Outbound internet for nodes |
| OS disks (4x)     | StandardSSD_LRS   | ~$0.043                  | 30+80+80+80 GB              |
| Cinder disks (2x) | StandardSSD_LRS   | ~$0.013                  | 2x 40 GB block storage      |
| Public IP (2x)    | Standard          | ~$0.010                  | Bastion + NAT               |
| **Total**         |                   | **~$0.48/hr (~$11.50/day)** |                          |

> The defaults landed on AMD v7 SKUs because B-family burstable VMs (e.g.
> `Standard_B2s` ~$0.042/hr) are capacity-restricted in `southeastasia`.
> If your subscription has burstable stock, override `bastion_vm_size` to
> `Standard_B2s_v2` in `terraform.tfvars` to drop ~$0.027/hr off the bill.
> Run `az vm list-skus -l southeastasia --resource-type virtualMachines -o table`
> to see what's available to you.

Stop VMs when not in use to save money (see Teardown section).

## Prerequisites

Before you start, you need:

1. **Azure subscription** with permissions to create resource groups, VNets,
   VMs, NAT Gateways, and Public IPs (Contributor on the subscription is
   enough).
2. **Azure CLI configured** on your laptop:

   ```bash
   # macOS
   brew install azure-cli

   # Sign in (opens browser)
   az login

   # Pick the subscription you want to use
   az account list -o table
   az account set --subscription "<subscription-id-or-name>"
   ```

3. **Terraform installed** on your laptop:

   ```bash
   brew install terraform
   terraform --version    # should be >= 1.5
   ```

4. **An SSH key pair** on your laptop (no Azure-side key resource needed):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/openstack-prod
   chmod 400 ~/.ssh/openstack-prod
   cat ~/.ssh/openstack-prod.pub        # copy this into terraform.tfvars
   ```

5. **Your public IP** (for SSH access):

   ```bash
   curl -s https://checkip.amazonaws.com
   # Note this down — you'll need it as "YOUR_IP/32"
   ```

## File Structure

```
prod-setup/azure/
├── README.md                   <- you are here
└── terraform/
    ├── main.tf                 <- all Azure infrastructure (VNet, VMs, etc.)
    ├── variables.tf            <- input variables with defaults
    ├── outputs.tf              <- values printed after apply (IPs, SSH commands)
    ├── terraform.tfvars.example <- copy to terraform.tfvars and fill in
    ├── bastion-userdata.sh     <- cloud-init script for bastion (runs on first boot)
    └── node-userdata.sh        <- cloud-init script for OpenStack nodes
```

The Kolla configuration ([kolla-config/](../kolla-config/)) and deploy
scripts ([scripts/](../scripts/)) are shared with the AWS setup at the
top level of `prod-setup/`.

## Step-by-Step Deployment Guide

### Phase 1: Create Infrastructure (from your laptop)

```bash
# 1. Sign in to Azure
az login
az account set --subscription "<subscription-id>"

# 2. Navigate to the terraform directory
cd prod-setup/azure/terraform

# 3. Create your config file from the example
cp terraform.tfvars.example terraform.tfvars

# 4. Edit terraform.tfvars — paste your SSH public key and IP
nano terraform.tfvars

# 5. Initialize Terraform (downloads the azurerm provider plugin)
terraform init

# 6. Preview what Terraform will create
terraform plan -out=plan.out

# 7. Apply the plan (3-5 minutes)
terraform apply plan.out

# 8. Note the outputs — you'll need them for the next steps
terraform output
```

### Phase 2: Configure SSH Access

```bash
# Get the SSH config snippet from Terraform
terraform output ssh_config

# Paste it into ~/.ssh/config on your laptop (NOT the bastion).
# Then test:
ssh bastion
ssh controller
ssh compute-1
ssh compute-2
```

The `ssh_config` output assumes your private key is the system default
(`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`). If you used a custom name like
`~/.ssh/openstack-prod`, add `IdentityFile ~/.ssh/openstack-prod` to each
host entry, or load it once with `ssh-add ~/.ssh/openstack-prod`.

### Phase 3-6

Phases 3–6 (bastion setup, OpenStack deploy, verification, Horizon access)
are identical to the AWS guide. Follow [../README.md](../README.md) from
"Phase 3: Set Up the Bastion" onwards.

> **Note on interface names:** the Kolla `globals.yml` and inventory at
> [../kolla-config/](../kolla-config/) reference `eth0`/`eth1`. AWS uses
> `ens5`/`ens6`. If you run both AWS and Azure deployments in parallel,
> keep them in separate branches or override
> `network_interface` / `neutron_external_interface` per-host in the
> inventory. On Azure VMs the names are `eth0`/`eth1` out of the box.

## Teardown / Cost Control

### Stop VMs (keep data, stop paying for compute)

```bash
RG=$(terraform -chdir=prod-setup/azure/terraform output -raw resource_group_name)
az vm deallocate --ids $(az vm list -g "$RG" --query "[].id" -o tsv)
```

`deallocate` (not `stop`) is the one that stops billing for compute on
Azure. Plain `stop` keeps the compute reservation.

The NAT Gateway and Public IPs continue to cost a few cents per hour
even when VMs are deallocated. To fully stop costs, destroy everything.

### Start VMs back up

```bash
RG=$(terraform -chdir=prod-setup/azure/terraform output -raw resource_group_name)
az vm start --ids $(az vm list -g "$RG" --query "[].id" -o tsv)
# OpenStack containers auto-restart with Docker.
```

### Destroy everything

```bash
cd prod-setup/azure/terraform
terraform destroy
# Type "yes" to confirm. Deletes the entire resource group and everything in it.
```

## Azure ↔ AWS Quick Reference

| AWS                              | Azure                                              |
| -------------------------------- | -------------------------------------------------- |
| VPC                              | Virtual Network (VNet)                             |
| Subnet                           | Subnet (inside VNet)                               |
| Internet Gateway                 | implicit (any NIC with a public IP)                |
| NAT Gateway                      | NAT Gateway (similar)                              |
| Security Group                   | Network Security Group (NSG)                       |
| Elastic IP                       | Public IP (Static SKU)                             |
| EC2 Instance                     | Linux Virtual Machine                              |
| AMI                              | source_image_reference (Marketplace publisher/offer) |
| Key Pair (.pem)                  | admin_ssh_key (paste public key contents)          |
| EBS volume                       | Managed Disk                                       |
| ENI                              | Network Interface (azurerm_network_interface)      |
| Multiple secondary IPs on an ENI | Multiple `ip_configuration` blocks on a NIC        |
| `source_dest_check = false`      | `ip_forwarding_enabled = true`                     |
| ens5, ens6                       | eth0, eth1                                         |
| `aws configure`                  | `az login`                                         |
