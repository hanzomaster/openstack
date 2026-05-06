###############################################################################
# main.tf — Production-like OpenStack cluster on Azure.
#
# WHAT THIS FILE DOES:
#   Declares all the Azure infrastructure needed to run a multi-node OpenStack
#   cluster. Terraform reads this file and creates/updates/deletes Azure
#   resources to match what's declared here.
#
# WHAT IT CREATES (in order):
#   1. Resource Group (the container that holds everything)
#   2. Virtual Network + Subnets (the virtual network everything lives in)
#   3. NAT Gateway (so private instances can reach the internet outbound)
#   4. Network Security Groups (firewall rules — who can talk to whom)
#   5. Bastion VM (jump server — your entry point from the internet)
#   6. Controller VM (runs OpenStack control plane, dual-NIC)
#   7. Compute VMs x2 (run OpenStack VMs, Cinder LVM data disk attached)
#
# ARCHITECTURE DIAGRAM:
#
#   Internet
#     │
#     ▼
#   [Public IP on bastion NIC]
#     │
#     ├── Public Subnet 10.0.1.0/24
#     │     └── Bastion (10.0.1.10) ◄── you SSH here first
#     │
#     ▼
#   [NAT Gateway]  (lets private instances download packages)
#     │
#     └── Private Subnet 10.0.2.0/24
#           ├── Controller  (10.0.2.10) + VIP secondary (10.0.2.250) ◄── Keystone, Glance, Nova API, Horizon, etc.
#           ├── Controller Neutron NIC (10.0.2.11) ◄── second NIC (eth1) for Neutron external
#           ├── Compute-1   (10.0.2.21)  ◄── runs VMs
#           └── Compute-2   (10.0.2.22)  ◄── runs VMs
#
# HOW TO RUN:
#   az login
#   az account set --subscription "<your-subscription-id>"
#   cd prod-setup/azure/terraform
#   cp terraform.tfvars.example terraform.tfvars   # edit with your values
#   terraform init                                  # download Azure provider plugin
#   terraform plan -out=plan.out                    # preview what will be created
#   terraform apply plan.out                        # create everything
#
# HOW TO DESTROY:
#   terraform destroy                               # deletes ALL resources
###############################################################################


###############################################################################
# SECTION 1: Terraform configuration
###############################################################################
# This block tells Terraform:
#   - Which version of Terraform is required (>= 1.5)
#   - Which "providers" (cloud APIs) we use — azurerm + random
#   - Which version of the Azure provider plugin to download

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm" # Official Azure provider from HashiCorp
      version = "~> 4.0"            # Any 4.x version
    }

    # `local` provider — used by local_file to render kolla-config/multinode
    # from azure/terraform/multinode.tftpl so the Kolla inventory IPs are
    # always in lockstep with the Terraform variables (no manual sync).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    # `http` provider — used by data.http.my_ip to look up the laptop's
    # current public IP at apply time, so the bastion SSH allowlist tracks
    # whichever network you're on without manual tfvars edits.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# Configure the Azure provider.
# Terraform uses your Azure credentials from `az login` (Azure CLI) or
# environment variables: ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID,
# ARM_SUBSCRIPTION_ID.
provider "azurerm" {
  features {}

  # Optional: pin to a specific subscription. If null (the default), uses the
  # active subscription from `az account show`.
  subscription_id = var.subscription_id
}


###############################################################################
# SECTION 2: Resource Group
###############################################################################
# In Azure, every resource lives inside a Resource Group — a logical
# container that groups related resources. Deleting the RG deletes
# everything inside it (handy for full teardown).

resource "azurerm_resource_group" "prod" {
  name     = "${var.name_prefix}-rg"
  location = var.location

  tags = local.common_tags
}


###############################################################################
# SECTION 2.5: Common tags
###############################################################################
# Azure doesn't surface a "Name" tag specially (the resource's own `name`
# property is what shows up in the portal). We just attach a single Project
# tag so cost/billing reports group everything together.

locals {
  common_tags = {
    Project = var.name_prefix
  }
}


###############################################################################
# SECTION 2.6: Admin SSH allowlist (current laptop IP + static list)
###############################################################################
# The bastion NSG only opens port 22 to the IPs in `local.admin_cidrs`. That
# list is built from two sources:
#
#   1. data.http.my_ip — fetches the laptop's current public IP from
#      checkip.amazonaws.com at apply time. This means you don't have to
#      curl + edit tfvars every time you change networks.
#
#   2. var.allowed_admin_cidrs — optional static entries for networks you
#      want permanently allowed (home, office) so SSH still works from
#      there even if you last ran `terraform apply` from somewhere else.
#
# distinct() dedupes so an entry that's both static and current doesn't
# generate a duplicate rule. Stale IPs (old coffee shops, hotels) drop off
# automatically — only your current IP and the curated static list survive.

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  current_admin_cidr = "${chomp(data.http.my_ip.response_body)}/32"
  admin_cidrs        = distinct(concat(var.allowed_admin_cidrs, [local.current_admin_cidr]))
}


###############################################################################
# SECTION 3: Virtual Network (VNet) + Subnets
###############################################################################
# A VNet is your own isolated network inside Azure. Everything we create
# lives inside this VNet. Think of it as your own private data center.
#
# We create two subnets:
#
# PUBLIC SUBNET  (10.0.1.0/24) — bastion lives here with a public IP.
#   In Azure, a subnet is "public" simply because the NIC inside it has
#   a public IP attached. There is no Internet Gateway resource — outbound
#   internet works by default.
#
# PRIVATE SUBNET (10.0.2.0/24) — has NO public IPs on NICs.
#   Controller and compute nodes live here. We attach a NAT Gateway so
#   they can reach the internet outbound (apt-get, docker pull) but
#   nobody on the internet can reach them directly.

resource "azurerm_virtual_network" "prod" {
  name                = "${var.name_prefix}-vnet"
  address_space       = [var.vnet_cidr] # 10.0.0.0/16
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  tags = local.common_tags
}

resource "azurerm_subnet" "public" {
  name                 = "${var.name_prefix}-public"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.public_subnet_cidr] # 10.0.1.0/24
}

resource "azurerm_subnet" "private" {
  name                 = "${var.name_prefix}-private"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.private_subnet_cidr] # 10.0.2.0/24
}


###############################################################################
# SECTION 4: NAT Gateway
###############################################################################
# Lets private-subnet VMs make OUTBOUND connections (apt-get, docker pull)
# without being reachable FROM the internet. Attached to the private
# subnet via azurerm_subnet_nat_gateway_association.
#
# Cost: ~$0.045/hr + per-GB data processed (similar to AWS NAT GW).

resource "azurerm_public_ip" "nat" {
  name                = "${var.name_prefix}-nat-pip"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  allocation_method   = "Static"
  sku                 = "Standard"
  # No zones = regional (single-zone). For zone redundancy across an outage
  # of one AZ, set zones = ["1", "2", "3"] — costs the same on Standard SKU.
  # Omitting the attribute is the azurerm 4.x-correct way; an empty list is
  # deprecated.

  tags = local.common_tags
}

resource "azurerm_nat_gateway" "prod" {
  name                    = "${var.name_prefix}-nat"
  resource_group_name     = azurerm_resource_group.prod.name
  location                = azurerm_resource_group.prod.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "prod" {
  nat_gateway_id       = azurerm_nat_gateway.prod.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# Attach the NAT Gateway to the private subnet only.
# The public subnet uses the bastion's own public IP for egress; if we
# attached NAT to the public subnet, NAT would override the bastion's
# outbound path.
resource "azurerm_subnet_nat_gateway_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  nat_gateway_id = azurerm_nat_gateway.prod.id
}


###############################################################################
# SECTION 5: Network Security Groups (Firewall Rules)
###############################################################################
# NSGs are virtual firewalls. Each rule says:
#   "Allow/deny [direction] traffic from [source] on [port] using [protocol]"
#
# We create two NSGs:
#   1. bastion-nsg:  allows SSH from your IP only
#   2. internal-nsg: allows ALL traffic between OpenStack nodes (they need
#                    to talk freely for Kolla services, MariaDB replication,
#                    RabbitMQ, etc.) and SSH from the bastion subnet.
#
# Azure NSGs default-deny inbound from the internet, so we only need to
# express ALLOW rules. Outbound is allow-all by default — fine for us.

resource "azurerm_network_security_group" "bastion" {
  name                = "${var.name_prefix}-bastion-nsg"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  security_rule {
    name                       = "AllowSSHFromAdmin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = local.admin_cidrs
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

resource "azurerm_network_security_group" "internal" {
  name                = "${var.name_prefix}-internal-nsg"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  # Allow SSH from the public subnet (where the bastion lives).
  # Azure NSGs don't reference other NSGs as sources — we use the subnet CIDR.
  security_rule {
    name                       = "AllowSSHFromBastionSubnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.public_subnet_cidr
    destination_address_prefix = "*"
  }

  # Allow OpenStack API + Horizon + noVNC ports from the public subnet (bastion).
  # The bastion needs to reach the VIP (and direct controller IP) for:
  #   - Step 10  : `openstack` CLI verification (Keystone 5000, Glance 9292,
  #                Nova 8774, Neutron 9696, Cinder 8776, Heat 8000/8004,
  #                Placement 8778, Swift 8080, Designate 9001, Aodh 8042…)
  #   - Step 11  : `ssh -L 8080:VIP:80 bastion` Horizon tunnel (port 80)
  #                and the noVNC console (port 6080)
  # Without this rule the bastion → VIP traffic is dropped because the only
  # other public→private rule is SSH-only. Allow the full TCP range from the
  # bastion subnet — it's a lab egress path, not internet exposure (nothing
  # in the public subnet reaches here except the bastion itself).
  security_rule {
    name                       = "AllowOpenStackAPIsFromBastionSubnet"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.public_subnet_cidr
    destination_address_prefix = "*"
  }

  # Allow ICMP from the bastion subnet so `ping` works from the bastion to
  # the VIP / nodes. Used by Kolla prechecks on some clouds and by humans
  # during troubleshooting.
  security_rule {
    name                       = "AllowICMPFromBastionSubnet"
    priority                   = 106
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.public_subnet_cidr
    destination_address_prefix = "*"
  }

  # Allow ALL traffic between nodes inside the private subnet.
  # OpenStack services talk on many ports (MariaDB 3306, RabbitMQ 5672,
  # Keystone 5000, Glance 9292, Nova 8774, etc.). Rather than listing
  # every port, we allow everything within the subnet.
  security_rule {
    name                       = "AllowAllIntraPrivate"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.private_subnet_cidr
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

# Bind NSGs to subnets. Azure can attach NSGs at the subnet level, the NIC
# level, or both. We attach at subnet level so anything launched in the
# subnet inherits the rules.
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.internal.id
}


###############################################################################
# SECTION 6: Bastion Host (Jump Server)
###############################################################################
# The bastion is a small, cheap VM in the public subnet. It's the only
# machine with a public IP. You SSH to it first, then from there you can
# reach all the private OpenStack nodes.
#
# It also runs Kolla-Ansible (the tool that deploys OpenStack). We install
# Terraform and Ansible here via cloud-init (custom_data).

resource "azurerm_public_ip" "bastion" {
  name                = "${var.name_prefix}-bastion-pip"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

resource "azurerm_network_interface" "bastion" {
  name                = "${var.name_prefix}-bastion-nic"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.bastion_ip # 10.0.1.10
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }

  tags = local.common_tags
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "${var.name_prefix}-bastion"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  size                = var.bastion_vm_size # default: Standard_D2als_v7

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.bastion.id]

  os_disk {
    name                 = "${var.name_prefix}-bastion-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.bastion_root_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init script that runs on first boot (installs tools).
  # Azure expects custom_data to be base64-encoded.
  custom_data = base64encode(file("${path.module}/bastion-userdata.sh"))

  tags = local.common_tags

  lifecycle {
    # Don't replace the VM on:
    #   - source_image_reference  : "latest" Ubuntu image rolls forward
    #   - custom_data             : userdata only matters on first boot.
    #                                Comment/cosmetic edits would otherwise
    #                                trigger a destructive replace that loses
    #                                ~/.ssh/laptop_key, kolla venv, logs.
    #                                Use `terraform taint` if you genuinely
    #                                need to re-bootstrap from new userdata.
    ignore_changes = [source_image_reference, custom_data]
  }
}


###############################################################################
# SECTION 7: Controller Node
###############################################################################
# The controller runs all OpenStack control-plane services:
#   - MariaDB (database for all OpenStack services)
#   - RabbitMQ (message queue)
#   - Memcached (caching)
#   - HAProxy (load balancer, binds to the VIP)
#   - Keystone (identity/authentication)
#   - Glance (image storage)
#   - Nova API + Scheduler (compute orchestration)
#   - Neutron Server + L3/DHCP agents (networking)
#   - Cinder API + Scheduler (block storage orchestration)
#   - Horizon (web dashboard)
#
# It has TWO NICs:
#   - eth0 (primary): management network — all API and internal traffic.
#                     Carries TWO IPs: controller_ip + VIP (HAProxy).
#   - eth1 (secondary): Neutron external network — for provider/floating IPs.
#                       enable_ip_forwarding=true is the Azure equivalent of
#                       AWS's source_dest_check=false.

# Primary NIC: management + VIP secondary IP.
# Azure NICs support multiple IP configurations. The first one is the
# primary IP (used for hostname/cert SANs); the second is the VIP that
# HAProxy binds to. If you later add a second controller for HA, the VIP
# floats between them via keepalived.
resource "azurerm_network_interface" "controller_mgmt" {
  name                = "${var.name_prefix}-controller-mgmt-nic"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  ip_configuration {
    name                          = "mgmt"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.controller_ip # 10.0.2.10
    primary                       = true
  }

  ip_configuration {
    name                          = "vip"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.vip_ip # 10.0.2.250
  }

  tags = local.common_tags
}

# Secondary NIC: Neutron external network.
# enable_ip_forwarding must be true — Neutron routes packets with IPs that
# don't belong to this NIC (floating IPs, tenant traffic), and Azure would
# drop them otherwise.
resource "azurerm_network_interface" "controller_neutron" {
  name                  = "${var.name_prefix}-controller-neutron-nic"
  location              = azurerm_resource_group.prod.location
  resource_group_name   = azurerm_resource_group.prod.name
  ip_forwarding_enabled = true

  ip_configuration {
    name                          = "neutron"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.controller_neutron_ip # 10.0.2.11
  }

  tags = local.common_tags
}

resource "azurerm_linux_virtual_machine" "controller" {
  name                = "${var.name_prefix}-controller"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  size                = var.controller_vm_size # default: Standard_D2as_v7

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # Order matters: the first NIC becomes eth0, the second eth1.
  network_interface_ids = [
    azurerm_network_interface.controller_mgmt.id,
    azurerm_network_interface.controller_neutron.id,
  ]

  os_disk {
    name                 = "${var.name_prefix}-controller-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.root_size_gb # 80 GB
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/node-userdata.sh"))

  tags = local.common_tags

  lifecycle {
    # See bastion VM for rationale — userdata is one-shot, replacement loses
    # the running OpenStack control-plane containers.
    ignore_changes = [source_image_reference, custom_data]
  }
}


###############################################################################
# SECTION 8: Compute Nodes
###############################################################################
# Compute nodes run the actual virtual machines (via nova-compute) and
# handle tenant networking (via neutron-openvswitch-agent).
#
# Each compute node gets:
#   - One NIC on the private subnet (management network, eth0)
#   - An extra managed disk for Cinder LVM (block storage for OpenStack VMs)
#
# count = 2 means we get compute[0] and compute[1] (named compute-1 and
# compute-2 via tags). Reference them as azurerm_linux_virtual_machine.compute[0]
# and azurerm_linux_virtual_machine.compute[1].

resource "azurerm_network_interface" "compute" {
  count = var.compute_count # 2

  name                = "${var.name_prefix}-compute-${count.index + 1}-nic"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  ip_configuration {
    name                          = "mgmt"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.compute_ips[count.index] # 10.0.2.21, 10.0.2.22
  }

  tags = local.common_tags
}

resource "azurerm_linux_virtual_machine" "compute" {
  count = var.compute_count

  name                = "${var.name_prefix}-compute-${count.index + 1}"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  size                = var.compute_vm_size # default: Standard_D2as_v7

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.compute[count.index].id]

  os_disk {
    name                 = "${var.name_prefix}-compute-${count.index + 1}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.root_size_gb # 80 GB
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/node-userdata.sh"))

  tags = local.common_tags

  lifecycle {
    # See bastion VM for rationale — replacement loses the running OpenStack
    # tenant VMs and the LVM volume group on the data disk.
    ignore_changes = [source_image_reference, custom_data]
  }
}

# Extra managed disk for Cinder LVM on each compute node.
#
# Inside the VM the kernel name depends on the SKU's disk controller and
# whether it has a local resource disk:
#
#   * Dasv7 / Dalsv7 (NVMe, no resource disk): OS=/dev/nvme0n1, data=/dev/nvme0n2
#   * Dasv7 / Dalsv7 (SCSI, no resource disk): OS=/dev/sda,     data=/dev/sdb
#   * Older Dsv5 / Dasv5 with a resource disk: OS=/dev/sda, resource=/dev/sdb,
#                                              data (LUN 0)=/dev/sdc
#
# The default compute SKU (Standard_D2as_v7) has NO local resource disk, so
# LUN 0 lands on /dev/sdb (SCSI) or /dev/nvme0n2 (NVMe) — see DEPLOY.md
# Step 7 for the inspection flow.
#
# scripts/02-deploy-openstack.sh auto-detects across all of these layouts
# (and accepts CINDER_DISK= as an override). It then runs pvcreate +
# vgcreate on the chosen device to create the "cinder-volumes" LVM
# volume group.
resource "azurerm_managed_disk" "cinder" {
  count = var.compute_count

  name                 = "${var.name_prefix}-compute-${count.index + 1}-cinder"
  location             = azurerm_resource_group.prod.location
  resource_group_name  = azurerm_resource_group.prod.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.cinder_size_gb # 40 GB

  tags = local.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "cinder" {
  count = var.compute_count

  managed_disk_id    = azurerm_managed_disk.cinder[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.compute[count.index].id
  lun                = 0
  caching            = "None"
}


###############################################################################
# SECTION 9: Generated Kolla-Ansible inventory (single source of truth)
###############################################################################
# Renders kolla-config/multinode from azure/terraform/multinode.tftpl on every
# `terraform apply`, with IPs and admin_username pulled from Terraform
# variables. This guarantees that the Kolla inventory the bastion uses is
# always in lockstep with the actual Azure resources.
#
# IMPORTANT:
#   - Edit multinode.tftpl, NOT kolla-config/multinode (the rendered file).
#     Manual edits to the rendered file are blown away on the next apply.
#   - When you change controller_ip / compute_ips / admin_username, just
#     `terraform apply` — no manual sync of Kolla inventory required.
#   - The host-groups portion uses the variables; the lower service-group
#     mapping section is a verbatim copy of upstream stable/2025.2 and
#     rarely changes (only when you upgrade Kolla releases).

resource "local_file" "kolla_multinode" {
  filename        = "${path.module}/../../kolla-config/multinode"
  file_permission = "0644"
  content = templatefile("${path.module}/multinode.tftpl", {
    controller_ip  = var.controller_ip
    compute_ips    = slice(var.compute_ips, 0, var.compute_count)
    admin_username = var.admin_username
  })
}
