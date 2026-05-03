###############################################################################
# variables.tf — Input variables for the prod-like OpenStack cluster on Azure.
#
# HOW TERRAFORM VARIABLES WORK:
#   - Each "variable" block declares a name, a type, and optionally a default.
#   - If there's no default, you MUST provide a value (in terraform.tfvars).
#   - If there IS a default, you can override it or leave it as-is.
#   - You set values in a file called "terraform.tfvars" (see the .example).
#
# HOW TO USE:
#   1. Copy terraform.tfvars.example -> terraform.tfvars
#   2. Fill in the required values (ssh_public_key, my_ip)
#   3. Optionally tweak defaults (location, VM sizes, IPs, etc.)
###############################################################################

# ---------------------------------------------------------------------------
# Azure basics
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Leave null (the default) to use the active subscription from `az account show`."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region where all resources will be created. southeastasia is Singapore."
  type        = string
  default     = "southeastasia"
}

variable "name_prefix" {
  description = "Prefix added to every Azure resource name/tag, so you can tell them apart in the portal."
  type        = string
  default     = "openstack-prod"
}

variable "admin_username" {
  description = "Linux admin username on every VM. Maps to the Ubuntu account that you SSH into."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  # NO DEFAULT — you must provide this.
  # The OpenSSH public key that will be installed on every VM.
  # On macOS/Linux, generate one with:
  #   ssh-keygen -t ed25519 -f ~/.ssh/openstack-prod
  # Then paste the contents of ~/.ssh/openstack-prod.pub here.
  description = "OpenSSH public key (the contents of ~/.ssh/<key>.pub) installed on every VM for SSH access."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key on your laptop. Used only to render the ssh_config output snippet — Terraform never reads this file."
  type        = string
  default     = "~/.ssh/openstack-prod"
}

variable "allowed_admin_cidrs" {
  # NO DEFAULT — you must provide at least one entry.
  # Public IPs (in CIDR form) allowed to SSH the bastion. Add one entry per
  # network you work from (home, office, etc.) so you don't have to replace
  # the value every time you change networks — just append.
  # Find your current IP with:  curl -s https://checkip.amazonaws.com
  # Then add /32, e.g. "203.0.113.42/32"
  description = "List of public IPs in CIDR notation allowed to SSH the bastion (e.g. [\"203.0.113.42/32\", \"198.51.100.5/32\"])."
  type        = list(string)

  validation {
    condition     = length(var.allowed_admin_cidrs) > 0
    error_message = "allowed_admin_cidrs must contain at least one CIDR — otherwise nothing can SSH to the bastion."
  }
}

# ---------------------------------------------------------------------------
# VM sizes
# ---------------------------------------------------------------------------
# Azure VM size cheat sheet (Singapore / southeastasia, on-demand, approximate):
#   Standard_D2als_v7  2 vCPU /  4 GB AMD  ~$0.069/hr   low-mem, used for bastion
#   Standard_D2as_v7   2 vCPU /  8 GB AMD  ~$0.100/hr   close to AWS m5.large
#   Standard_D4as_v7   4 vCPU / 16 GB AMD  ~$0.200/hr   if you need more headroom
#
# B-family burstable SKUs (Standard_B2s / B2s_v2 / B2as_v2 etc.) are cheaper
# but widely capacity-restricted in southeastasia. We default to AMD v7 SKUs
# that are actually allocatable. If your region has burstable stock, override
# bastion_vm_size to "Standard_B2s_v2" (~$0.042/hr) in terraform.tfvars.

variable "bastion_vm_size" {
  description = "Azure VM size for the bastion/jump server. Defaults to AMD Standard_D2als_v7 because B-family burstable SKUs are widely capacity-restricted in southeastasia. Override in terraform.tfvars if your region/subscription has B2s_v2 available."
  type        = string
  default     = "Standard_D2als_v7"
}

variable "controller_vm_size" {
  description = "Azure VM size for the OpenStack controller. Runs all control-plane services (database, message queue, APIs). AMD v7 generation."
  type        = string
  default     = "Standard_D2as_v7"
}

variable "compute_vm_size" {
  description = "Azure VM size for OpenStack compute nodes. Runs virtual machines (nova-compute). Must support nested virtualization for KVM — the AMD Dasv7 family does."
  type        = string
  default     = "Standard_D2as_v7"
}

variable "compute_count" {
  description = "Number of compute nodes to create. Set to 2 for a realistic multi-node cluster."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Networking — VNet and subnet CIDRs
# ---------------------------------------------------------------------------
# We create a brand-new VNet (not a default one — Azure has no default VNet
# concept anyway). Network layout:
#
#   VNet             10.0.0.0/16     (65,536 IPs — the big container)
#   ├── Public       10.0.1.0/24     (256 IPs — bastion lives here, has public IP)
#   └── Private      10.0.2.0/24     (256 IPs — controller + computes, NAT for outbound)
#
# In Azure, "public" vs "private" is determined by whether NICs in the
# subnet have public IPs attached and whether a NAT Gateway is associated.

variable "vnet_cidr" {
  description = "CIDR block for the entire VNet. /16 gives 65k IPs — way more than we need, but standard."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (bastion). /24 = 256 IPs."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (controller + computes). /24 = 256 IPs."
  type        = string
  default     = "10.0.2.0/24"
}

# ---------------------------------------------------------------------------
# Static private IPs
# ---------------------------------------------------------------------------
# We assign fixed IPs so that:
#   - Kolla-Ansible inventory always points to the same addresses
#   - The VIP (Virtual IP) for HAProxy is predictable
#   - You can write SSH configs once and never change them
#
# Note: Azure reserves the first 4 IPs in every subnet (.0, .1, .2, .3) and
# the broadcast address. Our chosen IPs (.10, .11, .21, .22, .250) are
# all safely outside the reserved range.

variable "bastion_ip" {
  description = "Private IP for the bastion in the public subnet."
  type        = string
  default     = "10.0.1.10"
}

variable "controller_ip" {
  description = "Private IP for the controller's management interface (eth0)."
  type        = string
  default     = "10.0.2.10"
}

variable "controller_neutron_ip" {
  description = "Private IP for the controller's Neutron external interface (eth1, second NIC)."
  type        = string
  default     = "10.0.2.11"
}

variable "vip_ip" {
  description = "Kolla HAProxy Virtual IP. Must be unused and in the same subnet as the controller. HAProxy binds to this IP and load-balances API requests. On Azure this is a secondary IP config on the controller's primary NIC."
  type        = string
  default     = "10.0.2.250"
}

variable "compute_ips" {
  description = "Private IPs for compute nodes. Must have at least var.compute_count entries."
  type        = list(string)
  default     = ["10.0.2.21", "10.0.2.22"]
}

# ---------------------------------------------------------------------------
# Disk sizes
# ---------------------------------------------------------------------------

variable "root_size_gb" {
  description = "OS disk size (GB) for controller and compute nodes. Holds the OS + Docker images for OpenStack containers."
  type        = number
  default     = 80
}

variable "bastion_root_size_gb" {
  description = "OS disk size (GB) for the bastion host. Holds tools, Kolla venv, and the dated logs each setup run writes under /var/log/openstack-prod/. 64 GB leaves headroom for log accumulation."
  type        = number
  default     = 64
}

variable "cinder_size_gb" {
  description = "Extra managed disk size (GB) attached to each compute node for Cinder LVM (OpenStack block storage). Cinder creates virtual disks inside this volume."
  type        = number
  default     = 40
}
