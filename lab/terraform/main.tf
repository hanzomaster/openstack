###############################################################################
# OpenStack lab on EC2 — reproduction Terraform.
#
# IMPORTANT: This stack does NOT manage the currently running instance
# `i-01cf67908af3f0e61`. That instance was created by hand in the console
# before this repo existed. Use this stack to create a FRESH, similar lab
# host (same instance type, same AMI family, same region) — for a teammate,
# a rebuild, or a clean-room demo.
#
# What it creates:
#   - VPC 10.0.0.0/16 (separate from the default VPC where the hand-made
#     instance lives, so nothing collides)
#   - Public subnet 10.0.1.0/24 in the first AZ of var.region
#   - IGW + route table
#   - Security group: SSH from var.my_ip only
#   - Primary ENI with a VIP secondary IP (for Kolla's haproxy)
#   - OPTIONAL second ENI for Neutron (`var.enable_neutron_eni = true`)
#   - m5.2xlarge Ubuntu 24.04 instance with:
#       * 60 GB root gp3
#       * OPTIONAL 40 GB gp3 at /dev/sdb (`var.enable_cinder_ebs = true`)
#   - Elastic IP on the primary ENI
#   - cloud-init user-data that pre-installs Docker + deps so you can go
#     straight to `scripts/10-prep-host.sh`.
#
# See terraform/README.md for how to run it.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

###############################################################################
# Data sources
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

###############################################################################
# Networking
###############################################################################

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-subnet" }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${var.name_prefix}-rt" }
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "lab" {
  name        = "${var.name_prefix}-sg"
  description = "OpenStack lab: SSH from admin only; Horizon reached via SSH tunnel."
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

###############################################################################
# ENIs
###############################################################################

# Primary: management + Kolla VIP
resource "aws_network_interface" "mgmt" {
  subnet_id         = aws_subnet.lab.id
  private_ips       = [var.primary_ip, var.vip_ip]
  security_groups   = [aws_security_group.lab.id]
  source_dest_check = true
  tags              = { Name = "${var.name_prefix}-mgmt" }
}

# Secondary: Neutron external — optional (enable for Option A layouts)
resource "aws_network_interface" "neutron" {
  count             = var.enable_neutron_eni ? 1 : 0
  subnet_id         = aws_subnet.lab.id
  private_ips       = [var.neutron_ip]
  security_groups   = [aws_security_group.lab.id]
  source_dest_check = false # required for provider-network traffic
  tags              = { Name = "${var.name_prefix}-neutron" }
}

resource "aws_eip" "mgmt" {
  domain            = "vpc"
  network_interface = aws_network_interface.mgmt.id
  tags              = { Name = "${var.name_prefix}-eip" }
  depends_on        = [aws_internet_gateway.lab]
}

###############################################################################
# Instance
###############################################################################

resource "aws_instance" "openstack" {
  ami           = data.aws_ami.ubuntu_2404.id
  instance_type = var.instance_type
  key_name      = var.key_name

  # Primary ENI (mgmt)
  network_interface {
    network_interface_id = aws_network_interface.mgmt.id
    device_index         = 0
  }

  # Optional secondary ENI (Neutron external)
  dynamic "network_interface" {
    for_each = var.enable_neutron_eni ? [1] : []
    content {
      network_interface_id = aws_network_interface.neutron[0].id
      device_index         = 1
    }
  }

  root_block_device {
    volume_size = var.root_size_gb
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${var.name_prefix}-root" }
  }

  # Optional extra disk for Cinder LVM (Option A layouts)
  dynamic "ebs_block_device" {
    for_each = var.enable_cinder_ebs ? [1] : []
    content {
      device_name = "/dev/sdb"
      volume_size = var.cinder_size_gb
      volume_type = "gp3"
      encrypted   = true
      tags        = { Name = "${var.name_prefix}-cinder" }
    }
  }

  user_data = file("${path.module}/user-data.sh")

  tags = { Name = "${var.name_prefix}-aio" }

  lifecycle {
    ignore_changes = [ami] # don't replace just because Canonical published a new image
  }
}

###############################################################################
# Outputs
###############################################################################

output "instance_id"   { value = aws_instance.openstack.id }
output "public_ip"     { value = aws_eip.mgmt.public_ip }
output "primary_ip"    { value = var.primary_ip }
output "vip_ip"        { value = var.vip_ip }
output "neutron_ip"    { value = var.enable_neutron_eni ? var.neutron_ip : null }
output "ssh_command"   { value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.mgmt.public_ip}" }
output "horizon_tunnel" {
  value = "ssh -L 8080:${var.vip_ip}:80 -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.mgmt.public_ip}"
}
