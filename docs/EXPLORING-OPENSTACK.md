# Exploring OpenStack: Hands-on Architecture Walkthrough

> Once your cluster is deployed (`prod-setup/scripts/01-03` complete and
> `03-verify.sh` clean), this doc walks you through actually *seeing* what
> OpenStack does when you boot a VM. Two parallel paths — pick whichever fits
> your style:
>
> - **CLI walkthrough** — terminal-driven, see the API requests directly.
> - **Horizon walkthrough** — point-and-click in the web dashboard.
>
> Both produce the same VM via the same APIs. The CLI version is the more
> instructive of the two; Horizon is faster once you understand what's
> happening underneath.

---

## 1. The mental model

When you tell OpenStack "boot a VM", this chain runs:

```
You ──► Keystone ──► Nova API ──► Placement ──► RabbitMQ ──► Nova Compute
                       │              │                         │
                       └──────────────┴── policy ◄─── Glance ───┴──► Neutron ──► QEMU
```

Three things to keep in mind throughout:

1. **Keystone is touched by every other service** to validate your token. Every
   API call you make includes a token; the receiving service phones Keystone
   (or its memcached cache) to confirm the token is alive and asks "what role
   does this user have on this project?".
2. **RabbitMQ is the bridge between API and Compute.** Nova API doesn't SSH or
   RPC into compute hosts directly — it queues a "build this VM" message;
   `nova_compute` on the chosen host picks the message off the queue and does
   the actual work. This is why `server create` returns in ~1 second even
   though the VM takes 20+ seconds to boot.
3. **Placement answers exactly one question**: "which compute hosts have at
   least *N* vCPUs, *M* MB RAM, and *D* GB disk free?" Nova Scheduler asks it
   before sending the build message. Without Placement, scheduling would
   require broadcast queries to every compute and would race under
   concurrency.

---

## 2. CLI walkthrough — boot a VM and trace the call chain

All commands run **from the bastion**, with the kolla venv activated and
`admin-openrc.sh` sourced:

```bash
ssh bastion
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
```

### 2a. Look at the service topology

```bash
# Where each service lives — note the VIP (10.0.2.250) is HAProxy's address;
# all internal/public endpoints point there.
openstack --insecure endpoint list -f value \
  --column 'Service Name' --column Interface --column URL | sort | column -t

# Compute hosts (hypervisors) — should show 2 nodes "up"
openstack --insecure compute service list --service nova-compute

# Where Neutron has presence — note that DHCP/L3/Metadata only run on the
# controller (centralised L3), but OVS runs on every host (data plane).
openstack --insecure network agent list -f value \
  -c Host -c 'Agent Type' -c Alive -c State | sort | column -t
```

### 2b. Stage a tenant network as alice in demo-proj

We use `alice` (a `member` of `demo-proj`) instead of `admin` because the
project-scoped admin token gets refused by some of Ticket 3's read policies.
See [Appendix B: Policy caveats from Ticket 3](#appendix-b-policy-caveats-from-ticket-3).

```bash
# Switch identity to alice (preserves OS_AUTH_URL from admin-openrc.sh)
export OS_USERNAME=alice
export OS_PASSWORD='Pass123!'      # set by lab/scripts/40-fixtures.sh
export OS_PROJECT_NAME=demo-proj
unset OS_SYSTEM_SCOPE

# Token sanity check — should print a project_id and an expiry
openstack --insecure token issue -f value -c project_id -c expires

# Tenant network + subnet (Neutron only — no compute involved yet)
openstack --insecure network create arch-demo-net
openstack --insecure subnet  create arch-demo-subnet \
  --network arch-demo-net --subnet-range 192.168.99.0/24
```

### 2c. Boot a VM with timed state transitions

This is the centrepiece. The shell loop polls Nova every 2 seconds and prints
each time the state changes:

```bash
T0=$(date +%s); ts() { printf '[T+%2ds] ' $(($(date +%s) - T0)); }

ts; echo "=== [Nova API] server create — async, returns in ~1s ==="
VM_ID=$(openstack --insecure server create arch-demo-vm \
  --flavor m1.tiny --image cirros --network arch-demo-net \
  -f value -c id 2>&1 | grep -E '^[0-9a-f-]{36}$' | head -1)
ts; echo "Nova returned id: $VM_ID"

PREV=""
for i in $(seq 1 60); do
  CURR=$(openstack --insecure server show "$VM_ID" \
    -f value -c status -c OS-EXT-STS:task_state -c OS-EXT-STS:vm_state \
    -c OS-EXT-SRV-ATTR:host 2>/dev/null | tr '\n' '|')
  if [[ -n "$CURR" && "$CURR" != "$PREV" ]]; then
    ts; echo "  status|task|vm|host = $CURR"
    PREV="$CURR"
  fi
  STATUS=$(echo "$CURR" | cut -d'|' -f1)
  [[ "$STATUS" == "ACTIVE" || "$STATUS" == "ERROR" ]] && break
  sleep 2
done
```

A typical run looks like:

```
[T+ 1s] Nova returned id: e2e9012b-d935-4ef1-b7ff-0ff0b5079175
[T+ 3s]   BUILD|scheduling|building|None        ← Nova Scheduler ↔ Placement
[T+ 6s]   BUILD|None|building|None              ← Build msg in RabbitMQ; gap
                                                  before nova-compute consumes
[T+ 9s]   BUILD|spawning|building|None          ← Compute host: pull image,
                                                  plug Neutron port, start QEMU
[T+22s]   ACTIVE|None|active|None               ← VM running
```

22 seconds total because Kolla deploys with `nova_compute_virt_type: "qemu"`
(software emulation — see `docs/LEARNING.md` §16). On bare-metal KVM the
same boot is 5–10 seconds.

### 2d. Inspect what got plumbed

```bash
# Server final state — note alice can't see OS-EXT-SRV-ATTR:host (admin-only)
openstack --insecure server show "$VM_ID" -f shell \
  -c status -c addresses -c image -c flavor

# The Neutron port Nova lazily created during spawning
openstack --insecure port list --server "$VM_ID" -f value \
  -c ID -c 'MAC Address' -c 'Fixed IP Addresses' -c Status

# Audit log of API-driven actions on this VM (create, reboot, resize, …)
openstack --insecure server event list "$VM_ID"
```

### 2e. Cleanup

```bash
openstack --insecure server  delete arch-demo-vm --wait
openstack --insecure subnet  delete arch-demo-subnet
openstack --insecure network delete arch-demo-net
```

### What each transition means

| Stage                              | Service flow                                                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------------- |
| `task_state=scheduling`            | Nova Scheduler asks Placement for hosts with enough free `VCPU/MEMORY_MB/DISK_GB`           |
| `task_state=None` between phases   | Build message in RabbitMQ; brief gap before `nova_compute` on the chosen host consumes it    |
| `task_state=spawning`              | `nova_compute`: fetch image from Glance → ask Neutron for a port → `libvirt domain start`   |
| `status=ACTIVE / vm_state=active`  | QEMU process running, OVS port plugged, DHCP-assigned IP visible to the guest               |

---

## 3. Horizon walkthrough — same flow, clicked

Horizon is OpenStack's web dashboard. The Kolla deploy already runs it on the
controller; you reach it by SSH-tunnelling through the bastion.

### 3a. Open the tunnel and log in

```bash
# === LAPTOP ===  (NOT the bastion — leave this terminal open)
ssh -L 8080:10.0.2.250:80 bastion
```

Then in your browser:

- **URL**: <http://localhost:8080>
- **Domain**: `Default`
- **User**: `admin`
- **Password**:
  ```bash
  # === BASTION ===
  sudo grep '^keystone_admin_password:' /etc/kolla/passwords.yml | awk '{print $2}'
  ```

### 3b. Page-to-API map

Each Horizon page is a thin GUI in front of the same APIs you used in §2. Open
browser devtools → Network tab — every click triggers one or more
`GET /v2.1/...` or `POST /v2.0/...` calls.

| Horizon page                                  | Equivalent CLI                                  |
| --------------------------------------------- | ----------------------------------------------- |
| Project → Compute → Overview                  | `openstack quota show`                          |
| Project → Compute → Instances                 | `openstack server list`                         |
| Project → Compute → Images                    | `openstack image list`                          |
| Project → Compute → Key Pairs                 | `openstack keypair list`                        |
| **Project → Network → Network Topology**      | (no direct CLI — visual graph of all networks)  |
| Project → Network → Networks                  | `openstack network/subnet/port list`            |
| Project → Network → Security Groups           | `openstack security group rule list`            |
| Project → Volumes → Volumes                   | `openstack volume list`                         |
| Admin → Compute → Hypervisors                 | `openstack hypervisor list`                     |
| Admin → System → System Information           | `openstack service list` + `endpoint list`      |
| Identity → Projects / Users / Roles           | `openstack project/user/role list`              |

### 3c. Recommended click-through (mirrors §2)

1. **Identity → Users** — find `alice`, `bob`, `auditor`, `orphan-charlie`.
   Click `auditor`; you'll see the `readonly-auditor` role assigned on
   `demo-proj` (set up by `lab/scripts/52-poc-readonly-role.sh`).
2. **Top-left project switcher → switch to `demo-proj`**.
3. **Project → Compute → Instances → Launch Instance**. Walk the wizard:
   *Details*: name `arch-demo-vm` · *Source*: `cirros` · *Flavor*: `m1.tiny` ·
   *Networks*: pick or create one · **Launch**. Watch the spinner — Horizon is
   polling `task_state` exactly like our shell loop did.
4. **Project → Network → Network Topology** — see the VM rendered on its
   network. Drag, hover, click. This is the most visually informative page in
   OpenStack.
5. Switch back to the `admin` project and open **Admin → Compute → Hypervisors**
   — see compute-1 and compute-2's resource usage tick up while the VM runs.
6. Delete the VM from **Project → Compute → Instances** when done.

---

## 4. Going deeper

Three exercises beyond what §2 and §3 cover, in increasing depth.

### 4a. Live log trace during a boot

The CLI walkthrough shows you the *outside* of each transition. To watch the
actual service-to-service calls, tail the Docker logs on the controller and a
compute host while you boot:

```bash
# === BASTION ===  (3 separate terminals/tmux panes)
ssh controller 'docker logs -f nova_api'
ssh controller 'docker logs -f nova_scheduler'
ssh compute-1  'docker logs -f nova_compute'
```

Then in a fourth terminal, boot a VM (§2c). You'll see:

- `nova_api`: the incoming `POST /servers` request, token validation, the
  build instance creation
- `nova_scheduler`: the Placement query and the chosen host
- `nova_compute`: the image download, the Neutron port creation, the libvirt
  domain start

### 4b. Break a service on purpose

OpenStack failures are often *partial* — APIs respond but VMs don't appear.
Practising recovery:

```bash
# === BASTION ===
ssh controller 'docker stop neutron_server'
# Try to boot a VM (§2c). It will hang in BUILD/spawning forever because
# nova_compute can't ask Neutron for a port.
ssh controller 'docker logs --tail=20 nova_compute'   # see the timeouts

# Recover
ssh controller 'docker start neutron_server'
# nova_compute will retry; the stuck VM may eventually reach ACTIVE, or
# you may need to delete and re-boot.
```

Try the same with `rabbitmq` (Nova API queues messages but compute never
picks them up) or `mariadb` (services start failing 500s as their state
becomes unreachable).

### 4c. Inspect a service container

```bash
# === BASTION ===
ssh controller 'docker exec -it keystone bash'
# Inside the container:
cat /etc/keystone/keystone.conf
ls /etc/keystone/
keystone-manage --help
```

Repeat for `nova_api`, `neutron_server`, `cinder_api`, `glance_api`. The file
layouts are very similar — once you've seen one, you can navigate any of them.
Config files are mounted into the container from `/etc/kolla/<service>/` on
the host, so changes you make to the host file get picked up after a
`kolla-ansible reconfigure -t <service>`.

---

## Appendix A: Helpful one-liners

```bash
# What's running where (which compute is hosting each VM)
openstack --insecure server list --all-projects -f value -c Name -c Host

# Floating IP usage (when applicable)
openstack --insecure floating ip list -f value -c 'Floating IP Address' -c Port

# Health: are all containers on a host running?
ssh controller 'docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -v "Up "'
ssh compute-1  'docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -v "Up "'

# Quota for current project
openstack --insecure quota show

# A single VM's full config
openstack --insecure server show <id>
```

---

## Appendix B: Policy caveats from Ticket 3

`lab/scripts/52-poc-readonly-role.sh` writes per-service `policy.yaml`
overrides to grant `readonly-auditor` read access. Running it on a Kolla
2025.1 cluster reveals one important wrinkle:

The lab's nova policy uses Nova's built-in `rule:is_admin_or_owner`. Under
secure-RBAC defaults that rule resolves to **system-scoped admin only** — so
a project-scoped admin token (what `admin-openrc.sh` issues) and even a
regular project member fail to satisfy it. The result: after running ticket
3, neither `admin@admin` nor `alice@demo-proj` can `openstack server show`.

**Current workaround in this cluster**: `/etc/kolla/config/nova/policy.yaml`
has been moved aside (`.disabled`) and Nova reconfigured to defaults, so
`admin` and `member` users work normally. The other four services'
overrides (Keystone, Neutron, Cinder, Glance) remain active.

**The proper fix** (still TODO) is to rewrite `52-poc-readonly-role.sh` to
use explicit `project_id:%(project_id)s` checks instead of relying on
`rule:is_admin_or_owner`, so the rules grant the intended union of
`{admin, project-member, readonly-auditor}` rather than only
system-scoped admin. The same fix needs porting across all five services
because Keystone/Neutron/Cinder/Glance overrides may exhibit similar
behaviour on pages Horizon hits as `admin`.

If a Horizon page returns 403 for `admin`, this is the cause — not Horizon
being broken.

---

## Appendix C: Creating your first instance with a volume

Goal: launch a VM with a separate persistent Cinder volume attached, both
from the CLI and from Horizon. Treat this as a takeaway reference once the
walkthrough in §2/§3 makes sense.

### Picking an image

| Image                    | Size    | Boot time   | Notes                                                      |
| ------------------------ | ------- | ----------- | ---------------------------------------------------------- |
| **CirrOS 0.6.2**         | ~21 MB  | seconds     | already in your Glance — best for learning                 |
| Alpine cloud             | ~50 MB  | seconds     | minimal real Linux with `apk` for package management       |
| Ubuntu cloud minimal     | ~280 MB | 30–60 s     | real distro; only worth uploading if you need apt          |

Stick with **CirrOS** unless you need otherwise. Console login: user
`cirros`, password `gocubsgo`.

### Pre-flight checklist

| Need                              | How to verify                                                     |
| --------------------------------- | ----------------------------------------------------------------- |
| Image in Glance                   | `openstack --insecure image list \| grep cirros`                  |
| Flavor                            | `openstack --insecure flavor list \| grep m1.tiny`                |
| Project + member user             | `openstack --insecure user show alice` (set up by 40-fixtures)    |
| Compute capacity                  | `openstack --insecure compute service list --service nova-compute` |
| Cinder volume capacity            | `openstack --insecure volume service list`                        |
| (optional) SSH keypair            | created in step 2 of the CLI flow below                           |
| (optional) Security group rules   | created in step 2 of the CLI flow below                           |

### CLI flow

```bash
ssh bastion
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
export OS_USERNAME=alice OS_PASSWORD='Pass123!' OS_PROJECT_NAME=demo-proj
unset OS_SYSTEM_SCOPE

# 1. Network + subnet (Neutron)
openstack --insecure network create my-net
openstack --insecure subnet  create my-subnet --network my-net --subnet-range 10.99.0.0/24

# 2. (optional) Keypair + security-group rules so you can ping/SSH the VM
openstack --insecure keypair create my-key > ~/my-key.pem && chmod 400 ~/my-key.pem
openstack --insecure security group rule create --proto icmp default
openstack --insecure security group rule create --proto tcp --dst-port 22 default

# 3. Boot the instance from cirros (ephemeral root disk per flavor)
openstack --insecure server create my-vm \
  --flavor m1.tiny --image cirros --network my-net --key-name my-key --wait

# 4. Create a 2 GB Cinder volume (separate from VM's ephemeral disk)
openstack --insecure volume create my-vol --size 2

# 5. Attach the volume — appears as /dev/vdb inside the VM
openstack --insecure server add volume my-vm my-vol

# 6. Verify
openstack --insecure server show my-vm -f shell -c status -c addresses -c volumes_attached
openstack --insecure volume list
```

To open a graphical console session in CirrOS:

```bash
openstack --insecure console url show my-vm
# Open the URL in your browser via SSH tunnel:  ssh -L 6080:10.0.2.250:6080 bastion
# Visit the URL but replace 10.0.2.250 with localhost:6080
# Login:  cirros / gocubsgo
# Inside CirrOS:  sudo fdisk -l   shows /dev/vdb (the attached volume, unformatted)
```

Cleanup when done:

```bash
openstack --insecure server   remove volume my-vm my-vol
openstack --insecure volume   delete my-vol
openstack --insecure server   delete my-vm --wait
openstack --insecure subnet   delete my-subnet
openstack --insecure network  delete my-net
openstack --insecure keypair  delete my-key
```

### Horizon flow

Open the SSH tunnel + login per §3a, then switch to project `demo-proj` in
the top-left.

1. **Project → Network → Networks → Create Network**
   - Tab *Network*: name `my-net`
   - Tab *Subnet*: name `my-subnet`, CIDR `10.99.0.0/24`
   - Tab *Subnet Detail*: defaults are fine → **Create**

2. **Project → Compute → Key Pairs → Create Key Pair** (optional)
   - Type `SSH Key`, name `my-key` → download the `.pem`

3. **Project → Network → Security Groups → default → Manage Rules → Add Rule** (optional)
   - Add an `All ICMP` ingress rule and an `SSH (22)` ingress rule

4. **Project → Compute → Instances → Launch Instance**
   - *Details*: name `my-vm`
   - *Source*: select `cirros`. Toggle **Create New Volume: No** for now (we
     attach a separate one in step 5)
   - *Flavor*: `m1.tiny`
   - *Networks*: pick `my-net`
   - *Security Groups*: `default`
   - *Key Pair*: `my-key` (if created)
   - **Launch Instance** — watch the progress bar; Horizon is polling
     `task_state` exactly the way our shell loop did in §2c.

5. **Project → Volumes → Volumes → Create Volume**
   - Name `my-vol`, size `2 GiB` → **Create**
   - Then on the volume's row: **Manage Attachments → Attach to Instance: my-vm**

6. **Console** — Project → Compute → Instances → `my-vm` → **Console** tab.
   CirrOS login appears in the browser.

### Two boot patterns

What §C above does is **boot from image + attach a separate volume** — the
VM's root disk is ephemeral (lives in the flavor's `disk` size on the compute
host); the separate Cinder volume gives you a persistent secondary disk.

The other common pattern is **boot from volume**: Nova creates a Cinder
volume from the image at launch time and uses that as the root disk. The
VM's OS then lives on a persistent Cinder volume that survives instance
deletion and can be snapshotted.

```bash
# Boot-from-volume — root disk is a 5 GB Cinder volume created from cirros
openstack --insecure server create my-vm \
  --flavor m1.tiny --network my-net --boot-from-volume 5 --image cirros --wait
```

In Horizon's Launch Instance wizard: *Source* → **Create New Volume: Yes**,
**Volume Size: 5**.

Worth trying both at least once — boot-from-volume is what production VMs
typically use because it makes the VM independently persistable and
snapshotable.

---

## Where to go from here

- `docs/LEARNING.md` — comprehensive reference (1200+ lines covering
  Terraform/Kolla/services/ops/troubleshooting). Read §10 (services) and
  §16 (gotchas) if you haven't.
- `prod-setup/azure/DEPLOY.md` — deployment runbook (you've already
  followed this).
- `lab/scripts/` — the three PoC ticket scripts. Re-running them is
  idempotent; modifying them is the cleanest way to extend the demo
  fixtures (e.g., add more users, more projects, more roles).
