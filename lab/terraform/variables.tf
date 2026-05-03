variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix for resource names/tags"
  type        = string
  default     = "openstack-lab"
}

variable "instance_type" {
  description = "EC2 instance type. m5.2xlarge is the minimum we've tested with qemu virt."
  type        = string
  default     = "m5.2xlarge"
}

variable "key_name" {
  description = "Existing EC2 key pair name (created out-of-band)"
  type        = string
}

variable "my_ip" {
  description = "Your admin IP in CIDR notation, e.g. 1.2.3.4/32. SSH is restricted to this."
  type        = string
}

# ---- Networking ----

variable "vpc_cidr" {
  description = "VPC CIDR — kept separate from the default VPC to avoid collisions"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "primary_ip" {
  description = "Primary private IP assigned to the mgmt ENI"
  type        = string
  default     = "10.0.1.10"
}

variable "vip_ip" {
  description = "Kolla internal VIP (secondary IP on mgmt ENI)"
  type        = string
  default     = "10.0.1.250"
}

variable "neutron_ip" {
  description = "Private IP assigned to the Neutron ENI (only used if enable_neutron_eni)"
  type        = string
  default     = "10.0.1.20"
}

# ---- Toggles: Option A vs Option B ----

variable "enable_neutron_eni" {
  description = "If true, attach a second ENI as the Neutron external interface (Option A). If false, use Option B's veth workaround on the host."
  type        = bool
  default     = false
}

variable "enable_cinder_ebs" {
  description = "If true, attach a second EBS volume at /dev/sdb for Cinder LVM (Option A). If false, use Option B's loopback-file workaround."
  type        = bool
  default     = false
}

# ---- Disk sizes ----

variable "root_size_gb" {
  description = "Root volume size in GB"
  type        = number
  default     = 80
}

variable "cinder_size_gb" {
  description = "Cinder LVM EBS size in GB (only used if enable_cinder_ebs)"
  type        = number
  default     = 40
}
