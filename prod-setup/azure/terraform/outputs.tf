###############################################################################
# outputs.tf — Values printed after "terraform apply" completes.
#
# HOW TERRAFORM OUTPUTS WORK:
#   After Terraform finishes creating resources, it prints any "output"
#   blocks you define. You can also view them later with:
#     terraform output              # show all outputs
#     terraform output ssh_command  # show one specific output
#
# These outputs give you everything you need to connect to the cluster
# and set up the Kolla-Ansible inventory.
###############################################################################

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the resource group that holds all infrastructure."
  value       = azurerm_resource_group.prod.name
}

# ---------------------------------------------------------------------------
# Bastion
# ---------------------------------------------------------------------------

output "bastion_public_ip" {
  description = "The bastion's public IP — this is what you SSH to from your laptop."
  value       = azurerm_public_ip.bastion.ip_address
}

output "bastion_private_ip" {
  description = "The bastion's private IP inside the VNet."
  value       = var.bastion_ip
}

# ---------------------------------------------------------------------------
# Controller
# ---------------------------------------------------------------------------

output "controller_private_ip" {
  description = "Controller's management IP (eth0). Used in the Kolla inventory."
  value       = var.controller_ip
}

output "controller_neutron_ip" {
  description = "Controller's Neutron external IP (eth1)."
  value       = var.controller_neutron_ip
}

output "vip_ip" {
  description = "HAProxy VIP — all OpenStack API endpoints resolve to this."
  value       = var.vip_ip
}

# ---------------------------------------------------------------------------
# Compute nodes
# ---------------------------------------------------------------------------

output "compute_private_ips" {
  description = "Private IPs of all compute nodes."
  value       = [for i in range(var.compute_count) : var.compute_ips[i]]
}

# ---------------------------------------------------------------------------
# Handy SSH commands
# ---------------------------------------------------------------------------

output "ssh_to_bastion" {
  description = "SSH command to reach the bastion from your laptop."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.bastion.ip_address}"
}

output "ssh_to_controller" {
  description = "SSH command to reach the controller (run from bastion, or use ProxyJump)."
  value       = "ssh ${var.admin_username}@${var.controller_ip}"
}

output "ssh_to_compute" {
  description = "SSH commands to reach compute nodes (run from bastion)."
  value       = [for i in range(var.compute_count) : "ssh ${var.admin_username}@${var.compute_ips[i]}"]
}

output "horizon_tunnel" {
  description = "SSH tunnel command to access Horizon dashboard from your laptop browser. After running this, open http://localhost:8080 in your browser."
  value       = "ssh -L 8080:${var.vip_ip}:80 ${var.admin_username}@${azurerm_public_ip.bastion.ip_address}"
}

# ---------------------------------------------------------------------------
# SSH config snippet — paste this into ~/.ssh/config on your laptop
# ---------------------------------------------------------------------------

output "ssh_config" {
  description = "Paste this into ~/.ssh/config on your laptop for easy access. The BEGIN/END marker fence makes re-applying idempotent — see DEPLOY.md Step 1 for the awk snippet that replaces an existing block in place."
  value       = <<-EOT

    # === BEGIN openstack-prod (Azure) ===
    # Managed by Terraform — re-paste between the BEGIN/END markers to update.
    # ForwardAgent is intentionally NOT set: macOS's keychain auto-loads keys
    # into the agent, and a forwarded agent on the bastion makes plain `ssh`
    # offer 6+ keys, tripping MaxAuthTries=6 on the target nodes. DEPLOY.md
    # uses scp + IdentityFile + `unset SSH_AUTH_SOCK` instead — agent
    # forwarding is unnecessary and actively harmful here.
    Host bastion
      HostName ${azurerm_public_ip.bastion.ip_address}
      User ${var.admin_username}
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      ForwardAgent no

    Host controller
      HostName ${var.controller_ip}
      User ${var.admin_username}
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      ProxyJump bastion

    %{for i in range(var.compute_count)~}
    Host compute-${i + 1}
      HostName ${var.compute_ips[i]}
      User ${var.admin_username}
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      ProxyJump bastion

    %{endfor~}
    # === END openstack-prod (Azure) ===
  EOT
}

# ---------------------------------------------------------------------------
# Kolla-Ansible inventory — host-groups portion only.
#
# Cross-check this against kolla-config/multinode (the file actually consumed
# by kolla-ansible) whenever Terraform IPs change. The static file also
# contains the full [X:children] service map required by Kolla 2025.2.
#
# In 2025.2, [loadbalancer:children] is derived from [network] (HAProxy/
# keepalived run on whichever hosts are in the network group), so we don't
# emit a [loadbalancer] host group here.
# ---------------------------------------------------------------------------

output "kolla_inventory" {
  description = "Kolla-Ansible multinode inventory host-groups (reference only — full inventory lives in kolla-config/multinode)."
  value       = <<-EOT
    [control]
    controller ansible_host=${var.controller_ip}

    [network]
    controller ansible_host=${var.controller_ip}

    [compute]
    %{for i in range(var.compute_count)~}
    compute-${i + 1} ansible_host=${var.compute_ips[i]}
    %{endfor~}

    [monitoring]
    controller ansible_host=${var.controller_ip}

    [storage]
    %{for i in range(var.compute_count)~}
    compute-${i + 1} ansible_host=${var.compute_ips[i]}
    %{endfor~}

    [deployment]
    localhost ansible_connection=local

    [all:vars]
    ansible_user=${var.admin_username}
    ansible_become=true
    ansible_private_key_file=/home/${var.admin_username}/.ssh/id_rsa
  EOT
}
