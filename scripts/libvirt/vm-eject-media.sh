#!/usr/bin/env bash
#
# Eject CDROM media from a libvirt VM and optionally enable autostart.
#
# Standalone, hypervisor-side replacement for the "Eject virtual-media" and
# "Set VM to auto-start" tasks of playbooks/infra/deploy-vm-bastion-libvirt.yml
# (the vendored community.libvirt collection does not implement
# 'action: eject-media' / 'state: stopped').
#
# Equivalent of the playbook tasks:
#   - Eject virtual-media:  stop the VM, then eject the media from its CDROMs
#   - Set VM to auto-start: 'virsh autostart' + make sure the VM is running
#
# Requirements: virsh (libvirt-client) and permission to manage the VM
# (run as root, or as a user with access to qemu:///system).

set -euo pipefail

readonly PROGNAME="${0##*/}"

VM_NAME=""
AUTOSTART=false
STOP_VM=true
SHUTDOWN_TIMEOUT=120
LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

usage() {
    cat <<EOF
Usage: ${PROGNAME} <vm_name> [options]

Stop a libvirt VM, eject the media from its CDROM devices and optionally
enable autostart (mirrors the 'Eject virtual-media' / 'Set VM to auto-start'
tasks of playbooks/infra/deploy-vm-bastion-libvirt.yml).

Options:
  --autostart       Enable autostart and start the VM
                    (equivalent of bastion.autostart: true)
  --timeout <secs>  Seconds to wait for a graceful shutdown before forcing
                    power-off (default: 120; 0 = force stop immediately)
  --no-stop         Do not stop the VM, eject the media live instead
  --uri <URI>       libvirt URI to connect to (default: ${LIBVIRT_URI})
  -h, --help        Show this help

Examples:
  ${PROGNAME} bastion-vm
  ${PROGNAME} bastion-vm --autostart
  ${PROGNAME} bastion-vm --no-stop --autostart
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ----------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
    case "$1" in
        --autostart) AUTOSTART=true ;;
        --no-stop)   STOP_VM=false ;;
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout requires a value"
            SHUTDOWN_TIMEOUT="$2"
            shift
            ;;
        --uri)
            [[ $# -ge 2 ]] || die "--uri requires a value"
            LIBVIRT_URI="$2"
            shift
            ;;
        -h|--help)   usage; exit 0 ;;
        --*)         die "Unknown option: $1 (see --help)" ;;
        *)
            [[ -z "$VM_NAME" ]] || die "VM name already set to '${VM_NAME}'"
            VM_NAME="$1"
            ;;
    esac
    shift
done

[[ -n "$VM_NAME" ]] || { usage >&2; exit 1; }
[[ "$SHUTDOWN_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer"
command -v virsh >/dev/null 2>&1 || die "virsh not found, install libvirt-client"

# All virsh calls below go through this wrapper to honor --uri.
virsh() { command virsh --connect "$LIBVIRT_URI" "$@"; }

vm_state() { virsh domstate "$VM_NAME"; }

# --------------------------------------------------------------- stop the VM --
stop_vm() {
    local state elapsed

    state="$(vm_state)"
    info "VM '${VM_NAME}' is currently: ${state}"

    case "$state" in
        "shut off" | crashed)
            info "VM is already ${state}, nothing to stop"
            return 0
            ;;
        paused | pmsuspended)
            # A paused/suspended guest cannot process an ACPI shutdown request.
            info "VM is ${state}, forcing power-off"
            virsh destroy "$VM_NAME"
            return 0
            ;;
    esac

    if (( SHUTDOWN_TIMEOUT == 0 )); then
        info "Forcing power-off (virsh destroy)"
        virsh destroy "$VM_NAME"
        return 0
    fi

    if [[ "$state" == "in shutdown" ]]; then
        info "VM is already shutting down"
    else
        info "Requesting graceful shutdown (waiting up to ${SHUTDOWN_TIMEOUT}s)"
        virsh shutdown "$VM_NAME"
    fi

    elapsed=0
    while true; do
        state="$(vm_state)"
        if [[ "$state" == "shut off" ]]; then
            info "VM is now shut off"
            return 0
        fi
        if (( elapsed >= SHUTDOWN_TIMEOUT )); then
            info "Graceful shutdown timed out, forcing power-off"
            virsh destroy "$VM_NAME"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# ------------------------------------------------------------ eject the media --
# Iterates over every CDROM device that has media inserted and ejects it.
# '--config' persists the change across reboots; '--live' is added when the
# VM is running so the media is also ejected from the active domain.
eject_media() {
    local target source flags found=0

    if [[ "$(vm_state)" == "running" ]]; then
        flags=(--live --config)
    else
        flags=(--config)
    fi

    # 'virsh domblklist --details' columns: Type, Device, Target, Source.
    while IFS=$'\t' read -r target source; do
        found=1
        if [[ -z "$source" || "$source" == "-" ]]; then
            info "CDROM ${target}: no media inserted, skipping"
            continue
        fi
        info "Ejecting '${source}' from CDROM ${target}"
        if ! virsh change-media "$VM_NAME" "$target" --eject "${flags[@]}"; then
            info "change-media failed on ${target} (media may be in use in the guest)"
            info "falling back to detaching the device"
            virsh detach-disk "$VM_NAME" "$target" "${flags[@]}"
        fi
    done < <(virsh domblklist "$VM_NAME" --details \
             | awk '$2 == "cdrom" {print $3 "\t" $4}')

    if (( found == 0 )); then
        info "No CDROM devices attached to '${VM_NAME}'"
    fi
}

# ---------------------------------------------------------------------- main --
info "Connecting to ${LIBVIRT_URI}"
virsh dominfo "$VM_NAME" >/dev/null || die "VM '${VM_NAME}' not found on ${LIBVIRT_URI}"

if [[ "$STOP_VM" == true ]]; then
    stop_vm
fi

eject_media

if [[ "$AUTOSTART" == true ]]; then
    info "Enabling autostart for '${VM_NAME}'"
    virsh autostart "$VM_NAME"
    if [[ "$(vm_state)" != "running" ]]; then
        info "Starting '${VM_NAME}'"
        virsh start "$VM_NAME"
    fi
elif [[ "$(vm_state)" != "running" ]]; then
    info "VM left $(vm_state) (pass --autostart to enable autostart and start it)"
fi

info "Done. VM '${VM_NAME}' is: $(vm_state)"
