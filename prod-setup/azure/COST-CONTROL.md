# Cost Control: Pause and Resume the Azure Lab

When you're not actively using the OpenStack cluster, you can pause it to
stop paying for compute without destroying any state. The
[`scripts/cost-control.sh`](scripts/cost-control.sh) helper wraps the two
common workflows — a **light pause** (deallocate VMs) and a **deep pause**
(also remove the NAT gateway).

## TL;DR

```bash
cd prod-setup/azure

# Pause for the night / weekend (fast, ~30 sec to resume)
./scripts/cost-control.sh pause

# Resume
./scripts/cost-control.sh resume

# Going away for a week+? Save another ~$36/mo
./scripts/cost-control.sh pause-deep
./scripts/cost-control.sh resume-deep
```

## Why deallocate, not stop

Azure has two "off" states and only one of them stops billing for compute:

| Action                            | Compute billed? | OS guest sees |
| --------------------------------- | --------------- | ------------- |
| `shutdown` from inside the OS     | **Yes**         | Powered off   |
| `az vm stop` (no `deallocate`)    | **Yes**         | Powered off   |
| `az vm deallocate`                | **No**          | Powered off   |

Deallocate releases the underlying compute host. Disks, NICs, public IPs,
NSGs, vnet, and Terraform state are all untouched, so resuming is just
`az vm start`.

## What still costs money while paused

At the default cluster size (1 bastion + 1 controller + 2 compute, southeastasia,
pay-as-you-go), here's roughly what survives each pause level:

```
Light pause (pause)
  4x OS disks (Premium SSD ~80 GB)     ~$48/mo
  2x Cinder data disks (~40 GB)        ~$10/mo
  2x Static Public IPs                 ~$7/mo
  NAT Gateway (idle hourly fee)        ~$32/mo
                                       --------
  Residual                             ~$97/mo

Deep pause (pause-deep)
  4x OS disks                          ~$48/mo
  2x Cinder data disks                 ~$10/mo
  1x Static Public IP (bastion only)   ~$4/mo
                                       --------
  Residual                             ~$62/mo
```

Numbers are rounded. `./scripts/cost-control.sh cost` prints the same table.
Check the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/)
for your exact region.

For comparison, the cluster running normally costs roughly **$365/mo**
(disks + IPs + NAT + 4 VMs). So:

- Light pause saves about **$269/mo** (74% off)
- Deep pause saves about **$303/mo** (83% off)

## Two pause levels — when to use which

### Light pause (`pause`)

What it does: `az vm deallocate` on every VM in the resource group.

Resume time: ~30 seconds.

Use it for:

- Overnight breaks
- Weekends
- Anywhere you'll be back within a few days

The NAT gateway stays up (~$1/day) so you can resume instantly.

### Deep pause (`pause-deep`)

What it does: light pause, then a targeted `terraform destroy` of the NAT
gateway and its public IP. The cluster's vnet, subnets, NSGs, VMs, and disks
are untouched.

Resume time: ~2 minutes (Terraform recreates the NAT gateway, then VMs start).

Use it for:

- Vacations, week-long breaks
- Any pause where the extra ~$36/mo matters more than 90-second resume

While the NAT gateway is gone, your compute and controller nodes have no
outbound internet — but that's fine because they're deallocated. **Do not
manually start the VMs while NAT is destroyed**; use `resume-deep` so
Terraform recreates NAT first.

### Full destroy (not in this script)

If you'll be away long enough that the residual ~$62/mo also stings:

```bash
cd prod-setup/azure/terraform
terraform destroy
```

This deletes everything including the disks. You lose all OpenStack state
(images, volumes, instances, Galera DB, Kolla configs on disk) and have to
re-bootstrap on the next `terraform apply`. Only do this when you don't need
the cluster's data anymore.

## Caveats and gotchas

1. **Static public IPs survive deallocation.** The bastion's public IP does
   not change across pause/resume cycles, so your SSH config and
   `allowed_admin_cidrs` keep working.

2. **OpenStack containers come back automatically.** Kolla containers run
   under Docker with `restart: unless-stopped`. After `resume`, give the
   controller ~60 seconds to settle before hitting the API; MariaDB and
   RabbitMQ need a moment.

3. **Don't run `terraform apply` on a paused cluster casually.** The azurerm
   provider doesn't normally treat power state as drift, but if you change
   things like VM size or image while paused, it may try to recreate the VM.
   Run `terraform plan` first and confirm the diff is what you expect.

4. **Single-controller Galera is fine.** Recovery on resume is automatic.
   This guidance does not extend to a future multi-controller HA setup —
   deallocating all controllers simultaneously can leave Galera needing a
   manual bootstrap.

5. **NAT processing fees.** Even idle, the NAT gateway charges per GB
   processed. Light pause keeps NAT up but with no traffic flowing the
   processing cost is effectively zero.

## Example workflows

**Daily / nightly pause** — quick to resume, slightly higher residual:

```bash
# end of day
./scripts/cost-control.sh pause

# next morning
./scripts/cost-control.sh resume
./scripts/cost-control.sh status      # confirm everything is "VM running"
```

**Weekly / vacation pause** — slower resume, lower residual:

```bash
# friday afternoon
./scripts/cost-control.sh pause-deep --yes

# monday morning
./scripts/cost-control.sh resume-deep --yes
```

**Check status any time** (read-only, no charges, safe to run):

```bash
./scripts/cost-control.sh status
```

## Manual equivalents (for reference)

If you ever need to do this without the script:

```bash
RG=$(terraform -chdir=prod-setup/azure/terraform output -raw resource_group_name)

# Pause
az vm deallocate --ids $(az vm list -g "$RG" --query "[].id" -o tsv)

# Resume
az vm start --ids $(az vm list -g "$RG" --query "[].id" -o tsv)

# Deep pause (after deallocate)
cd prod-setup/azure/terraform
terraform destroy \
  -target=azurerm_subnet_nat_gateway_association.private \
  -target=azurerm_nat_gateway_public_ip_association.prod \
  -target=azurerm_nat_gateway.prod \
  -target=azurerm_public_ip.nat

# Deep resume
terraform apply
az vm start --ids $(az vm list -g "$RG" --query "[].id" -o tsv)
```
