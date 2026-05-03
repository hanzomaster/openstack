# Reproduction Terraform

This stack spins up a **new** EC2 host that matches the layout of
`i-01cf67908af3f0e61` (our current hand-made lab). It does **not** manage
the existing instance.

## Why this exists

The existing lab was clicked together in the console — quick to start,
but not reproducible. When a teammate needs their own lab, or we want to
rebuild on a clean OS, this stack gives you a one-command path.

## What it creates

- Isolated VPC `10.0.0.0/16` (not the default VPC)
- Public subnet `10.0.1.0/24` in AZ-a
- IGW + route table
- Security group: SSH from `var.my_ip` only
- Primary ENI at `10.0.1.10` + VIP `10.0.1.250`
- Optional second ENI at `10.0.1.20` (`enable_neutron_eni = true`)
- m5.2xlarge Ubuntu 24.04 (Noble) with
  - 80 GB gp3 root
  - Optional 40 GB gp3 at `/dev/sdb` (`enable_cinder_ebs = true`)
- Elastic IP on the primary ENI
- cloud-init pre-installs Docker + build tools (see `user-data.sh`)

## Option A vs Option B

The variables `enable_neutron_eni` and `enable_cinder_ebs` let this stack
produce either layout:

| Layout    | `enable_neutron_eni` | `enable_cinder_ebs` | Host scripts still needed? |
| --------- | -------------------- | ------------------- | -------------------------- |
| Option B  | `false` (default)    | `false` (default)   | Yes — `10-prep-host.sh` creates veth + loopback-VG |
| Option A  | `true`               | `true`              | No — skip `10-prep-host.sh` |

For Option A you'll also need to:
1. Flip `neutron_external_interface` from `veth-ext` to `ens6` in
   `lab/kolla-config/globals.yml`
2. Adjust `cinder_volume_group` to point at the VG you create on
   `/dev/nvme1n1` (still `cinder-volumes` if you follow the name)

## Usage

```bash
cd lab/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars     # set key_name + my_ip

terraform init
terraform plan -out=plan.out
terraform apply plan.out

# Outputs tell you how to reach it
terraform output ssh_command
terraform output horizon_tunnel
```

Then SSH in and continue with `lab/scripts/10-prep-host.sh`
(skip for Option A), then `20-install-kolla.sh`, `30-deploy-kolla.sh`,
`40-fixtures.sh`.

## Updating `globals.yml` for a Terraform-created host

Default VPC IPs in `lab/kolla-config/globals.yml` are tuned for the
hand-made host (`172.31.38.*`). If you use this stack, update:

```yaml
kolla_internal_vip_address: "10.0.1.250"
network_interface: "ens5"
neutron_external_interface: "veth-ext"   # Option B; or "ens6" for Option A
```

## Teardown

```bash
terraform destroy
```

This is safe for a Terraform-created lab. **Never run this from the repo
that the hand-made instance lives alongside** — there's no linkage in
state, but confusing them is easy.

## Known gotchas

- `source_dest_check = false` on the Neutron ENI is required. Without it,
  AWS drops packets for IPs not matching the ENI's assigned addresses,
  and Neutron provider-network traffic goes nowhere.
- The VIP (`10.0.1.250`) must be added as a **secondary private IP** on
  the primary ENI, not as its own ENI. Kolla's haproxy binds to the VIP
  directly; AWS delivers it because it's on the same ENI.
- If you change `key_name` after first apply, Terraform will want to
  replace the instance. To rotate keys without a replace, use
  `ec2-instance-connect` or add an authorized key out-of-band.
- `lifecycle.ignore_changes = [ami]` prevents Terraform from replacing
  the instance when Canonical publishes a new daily AMI. To force an AMI
  refresh, `terraform taint aws_instance.openstack`.
