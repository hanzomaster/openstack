# AWS Cost Reference — OpenStack Cluster

> Region: **ap-southeast-1 (Singapore)**  
> Last updated: 2026-04-26

---

## Hourly Costs (instances running)

| Resource | Type | $/hr |
|---|---|---|
| Bastion | t3.small | $0.026 |
| Controller | m5.large | $0.120 |
| Compute-1 | m5.large | $0.120 |
| Compute-2 | m5.large | $0.120 |
| NAT Gateway | managed | $0.059 |
| NAT data processing | per GB | $0.059/GB |
| Elastic IPs (bastion + NAT) | in use | free |
| **Total (all running)** | | **~$0.445/hr** |

---

## Storage Costs (charged 24/7 even when stopped)

| Disk | Node | Size | $/month |
|---|---|---|---|
| Root | Bastion | 20 GB gp3 | $1.84 |
| Root | Controller | 40 GB gp3 | $3.68 |
| Root | Compute-1 | 40 GB gp3 | $3.68 |
| Root | Compute-2 | 40 GB gp3 | $3.68 |
| Cinder data | Compute-1 | 20 GB gp3 | $1.84 |
| Cinder data | Compute-2 | 20 GB gp3 | $1.84 |
| **Total EBS** | | **180 GB** | **$16.56/mo** |

---

## Scenario Totals

| Scenario | $/hr | $/day | $/month |
|---|---|---|---|
| **Everything running** | ~$0.47 | ~$11.30 | ~$338 |
| **Instances stopped** (EBS + NAT still running) | ~$0.08 | ~$1.90 | ~$58 |
| **Instances stopped + NAT deleted** | ~$0.02 | ~$0.46 | ~$17 |
| **`terraform destroy`** | $0 | $0 | $0 |

---

## How to Stop / Start

### Stop instances (keep data, saves ~80%)

```bash
# Get instance IDs
cd prod-setup/terraform && terraform output

# Stop all
aws ec2 stop-instances \
  --region ap-southeast-1 \
  --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>
```

NAT Gateway continues at ~$0.059/hr = ~$43/month while stopped.

### Start instances back up

```bash
aws ec2 start-instances \
  --region ap-southeast-1 \
  --instance-ids <bastion-id> <controller-id> <compute1-id> <compute2-id>

# Wait ~3 min, then verify:
ssh bastion 'source ~/kolla-venv/bin/activate && source /etc/kolla/admin-openrc.sh && openstack --insecure service list'
```

### Delete NAT Gateway (for idle days, saves extra ~$43/month)

```bash
aws ec2 delete-nat-gateway \
  --region ap-southeast-1 \
  --nat-gateway-id nat-<id>

# After ~2 min, release the NAT's Elastic IP to avoid EIP idle charges:
aws ec2 describe-addresses --region ap-southeast-1  # find NAT EIP
aws ec2 release-address --region ap-southeast-1 --allocation-id eipalloc-<id>
```

To recreate: `terraform apply` will recreate it automatically.  
**Warning:** While NAT is gone, private nodes (controller, computes) cannot reach the internet. Docker pulls and apt-get will fail.

### Destroy everything

```bash
cd prod-setup/terraform
terraform destroy    # type "yes" — deletes ALL resources, all data
```

---

## Notes

- **gp3 EBS** = $0.08/GB/month in ap-southeast-1
- **NAT Gateway** = $0.059/hr + $0.059/GB processed (data cost is usually small for a lab)
- **Elastic IPs** = free while attached to a running instance; $0.005/hr if unattached (idle)
- All prices exclude data transfer costs (usually negligible for lab use)
