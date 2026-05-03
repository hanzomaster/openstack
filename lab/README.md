# OpenStack lab on EC2

Kolla-Ansible all-in-one deployment for exercising three internal tickets
(Keystone governance / access-review work — orphan detection, read-only auditors, etc.).

Target release: **Kolla-Ansible `stable/2025.1` (OpenStack Epoxy)**.

## Where things live

```
lab/
├── README.md                   ← start here
├── docs/
│   ├── 01-current-state.md     snapshot of the EC2 host as found (2026-04-19)
│   ├── 02-option-b-setup.md    runbook: veth + loopback-VG workarounds
│   └── 03-kolla-deploy.md      runbook: install + deploy Kolla-Ansible
├── scripts/                    runnable equivalents of the docs
│   ├── 10-prep-host.sh
│   ├── 20-install-kolla.sh
│   ├── 30-deploy-kolla.sh
│   └── 40-fixtures.sh          demo users/projects for the three tickets
├── kolla-config/
│   └── globals.yml             overrides copied on top of /etc/kolla/globals.yml
└── terraform/                  reproduce a similar host from scratch (future use)
    ├── main.tf
    ├── variables.tf
    ├── user-data.sh
    ├── terraform.tfvars.example
    └── README.md
```

## Status of this particular EC2 host (i-01cf67908af3f0e61)

- Created by hand in the AWS console on 2026-04-19
- Some setup already done by hand (Docker installed, SSH access working)
- No Terraform state exists for this host — it was **not** created by the
  `terraform/` in this repo
- The `terraform/` directory is for **future similar setups**, not for
  managing this existing instance

See `docs/01-current-state.md` for the exact snapshot: interfaces, disks,
software versions, what is missing vs. the original plan.

## Why Option B (veth + loopback-VG)

Two pieces of the original plan were not created by hand:

1. A second ENI for Neutron's external network (ens6)
2. A second EBS volume for the Cinder LVM volume group

Rather than fix this in AWS now, Option B fakes both on-host so the lab can
come up today:

- `veth-ext` — a veth pair stands in for `ens6`. Nothing will actually leave
  the host over it, but Neutron will happily bind provider networks to it
  and tenant networks will work through the `br-ex` OVS bridge on the
  internal VIP.
- `/var/lib/cinder-volumes.img` — a 40 GB sparse file loop-mounted as
  `/dev/loop10` and made into VG `cinder-volumes`. Cinder doesn't know or
  care that it's a file.

Trade-off: no off-host floating IPs (you reach Horizon by SSH tunnel only,
which the plan already assumed). Loopback-backed Cinder is slower than real
EBS but adequate for lab volume create/attach/detach flows.

If you later want real networking + storage:

- Option A in `docs/02-option-b-setup.md` shows the AWS CLI commands to
  attach a second ENI and EBS, then flip `globals.yml` and redeploy.

## Traceability

Every script prints a banner with its name and the date, and writes a log
under `/var/log/openstack-lab/` (created with the right perms in
`10-prep-host.sh`). Docs reference the exact script and line where each
step runs, so the state of the host can be walked back to the commands
that produced it.

## Runbook (abbreviated)

1. Read `docs/01-current-state.md` — confirm it still matches `ip -br link`,
   `lsblk`, `docker --version`. If any of those drifted, stop and update
   the doc before running scripts.
2. `sudo bash scripts/10-prep-host.sh` (creates veth, VG, systemd unit)
3. `bash scripts/20-install-kolla.sh` (venv, ansible, kolla-ansible)
4. `bash scripts/30-deploy-kolla.sh` (bootstrap → prechecks → deploy →
   post-deploy, ~40 min)
5. `bash scripts/40-fixtures.sh` (users/projects for the tickets)
6. SSH-tunnel Horizon: `ssh -L 8080:172.31.38.250:80 ubuntu@54.255.198.174`

## Teardown / cost control

The instance costs ~$0.38/hr on-demand. When not actively working:

```bash
# From anywhere with AWS credentials
aws ec2 stop-instances --instance-ids i-01cf67908af3f0e61
```

Stopping preserves the 60 GB root (Kolla deployment stays intact). Starting
again restarts containers — the loopback VG is re-attached by the systemd
unit installed in `10-prep-host.sh`.

**Do not `terraform destroy`** from `terraform/` — that stack does not know
about this instance.

## Referenced external context

- Kolla-Ansible docs: https://docs.openstack.org/kolla-ansible/2025.1/
- AWS instance metadata snapshot: `docs/01-current-state.md`
