#!/usr/bin/env bash
# cost-control.sh -- pause/resume the Azure OpenStack lab to save money.
# Full guide: prod-setup/azure/COST-CONTROL.md
#
# Subcommands:
#   status        Show power state of every VM in the resource group.
#   pause         Deallocate all VMs (stops compute billing). Keeps disks/IPs/NAT.
#   resume        Start all VMs back up.
#   pause-deep    pause + terraform-destroy the NAT gateway (saves another ~$36/mo).
#   resume-deep   terraform-apply to recreate NAT, then start all VMs.
#   cost          Print what costs persist while paused (informational).
#   help          This message.
#
# Flags:
#   -y, --yes     Skip confirmation prompts (for non-interactive use).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

# Resources targeted by pause-deep / resume-deep.
NAT_TARGETS=(
  azurerm_subnet_nat_gateway_association.private
  azurerm_nat_gateway_public_ip_association.prod
  azurerm_nat_gateway.prod
  azurerm_public_ip.nat
)

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf '!   %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

resource_group() {
  terraform -chdir="$TF_DIR" output -raw resource_group_name 2>/dev/null \
    || die "could not read resource_group_name from terraform state in $TF_DIR"
}

vm_ids() {
  local rg="$1"
  az vm list -g "$rg" --query "[].id" -o tsv
}

cmd_status() {
  local rg ids
  rg="$(resource_group)"
  log "Resource group: $rg"
  ids="$(vm_ids "$rg")"
  if [[ -z "$ids" ]]; then
    warn "No VMs found in $rg (already destroyed?)"
    return 0
  fi
  az vm list -g "$rg" -d \
    --query "[].{name:name, size:hardwareProfile.vmSize, power:powerState, publicIp:publicIps, privateIp:privateIps}" \
    -o table
}

cmd_pause() {
  local rg ids
  rg="$(resource_group)"
  ids="$(vm_ids "$rg")"
  if [[ -z "$ids" ]]; then
    warn "No VMs to deallocate in $rg"
    return 0
  fi
  log "Will deallocate every VM in: $rg"
  echo "$ids" | sed 's|.*/||;s/^/    - /'
  confirm "Proceed?" || { warn "aborted"; return 1; }
  az vm deallocate --ids $ids
  log "Done. Run '$0 status' to verify."
}

cmd_resume() {
  local rg ids
  rg="$(resource_group)"
  ids="$(vm_ids "$rg")"
  if [[ -z "$ids" ]]; then
    die "No VMs found in $rg. If you ran pause-deep, use 'resume-deep' instead."
  fi
  log "Starting every VM in: $rg"
  az vm start --ids $ids
  log "Done. SSH back in via the bastion (public IP is unchanged)."
}

cmd_pause_deep() {
  cmd_pause
  log "Targeted terraform destroy of NAT gateway resources in $TF_DIR"
  for t in "${NAT_TARGETS[@]}"; do printf '    - %s\n' "$t"; done
  warn "While NAT is gone, private nodes have no outbound internet."
  warn "That is fine because they are deallocated. Do NOT bring VMs back without resume-deep."
  confirm "Proceed with terraform destroy?" || { warn "aborted (VMs are deallocated; NAT still up)"; return 1; }
  local args=()
  for t in "${NAT_TARGETS[@]}"; do args+=( -target="$t" ); done
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    args+=( -auto-approve )
  fi
  terraform -chdir="$TF_DIR" destroy "${args[@]}"
  log "Deep pause complete."
}

cmd_resume_deep() {
  log "Recreating NAT gateway via terraform apply in $TF_DIR"
  local args=()
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    args+=( -auto-approve )
  fi
  terraform -chdir="$TF_DIR" apply "${args[@]}"
  cmd_resume
}

cmd_cost() {
  cat <<'EOF'
While paused, you stop paying for VM compute (~$269/mo at default sizes in
southeastasia). What is still billed:

  Light pause (`pause`):
    - 4x OS disks (Premium SSD ~80 GB)        ~$48 / month
    - 2x Cinder data disks (~40 GB)           ~$10 / month
    - 2x Static Public IPs (bastion + NAT)    ~$7  / month
    - NAT Gateway (idle hourly fee)           ~$32 / month
    ----------------------------------------------------
    Approx. residual:                         ~$97 / month

  Deep pause (`pause-deep`, NAT destroyed):
    - 4x OS disks                             ~$48 / month
    - 2x Cinder data disks                    ~$10 / month
    - 1x Static Public IP (bastion only)      ~$4  / month
    ----------------------------------------------------
    Approx. residual:                         ~$62 / month

Numbers are pay-as-you-go for southeastasia and rounded. Check the Azure
pricing calculator for your exact region and any reservations.
EOF
}

cmd_help() {
  cat <<'HELP'
cost-control.sh -- pause/resume the Azure OpenStack lab to save money.
Full guide: prod-setup/azure/COST-CONTROL.md

Subcommands:
  status        Show power state of every VM in the resource group.
  pause         Deallocate all VMs (stops compute billing). Keeps disks/IPs/NAT.
  resume        Start all VMs back up.
  pause-deep    pause + terraform-destroy the NAT gateway (saves another ~$36/mo).
  resume-deep   terraform-apply to recreate NAT, then start all VMs.
  cost          Print what costs persist while paused (informational).
  help          This message.

Flags:
  -y, --yes     Skip confirmation prompts (for non-interactive use).
HELP
}

main() {
  require az
  require terraform

  ASSUME_YES=0
  local args=()
  for a in "$@"; do
    case "$a" in
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) args+=( help ) ;;
      *) args+=( "$a" ) ;;
    esac
  done
  set -- "${args[@]}"

  local sub="${1:-help}"
  shift || true
  case "$sub" in
    status)        cmd_status "$@" ;;
    pause)         cmd_pause "$@" ;;
    resume)        cmd_resume "$@" ;;
    pause-deep)    cmd_pause_deep "$@" ;;
    resume-deep)   cmd_resume_deep "$@" ;;
    cost)          cmd_cost "$@" ;;
    help|"")       cmd_help ;;
    *)             die "unknown subcommand: $sub (try '$0 help')" ;;
  esac
}

main "$@"
