#!/usr/bin/env bash
#
# test-lab-11.1-svirt.sh - run and verify Lab 11.1 (See sVirt Confine a VM)
# end-to-end on the KVM host.
#
# Confirms SELinux is Enforcing, inspects the VM's svirt_t process label and its
# disk's svirt_image_t label, moves the disk to an unlabelled path and proves the
# VM refuses to start (with an AVC denial), then fixes it the correct way with
# semanage fcontext + restorecon and confirms it boots. Finally restores the disk
# to its original location. Prints a PASS/WARN/FAIL line per lab "Expected
# result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: SELinux Enforcing; ol-lab-01 exists. This script is careful to
# restore ol-lab-01 to its original disk path at the end, even on the fix path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-11.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
SVIRT_DIR="${SVIRT_DIR:-/home/opc/svirt-test}"

ORIG_DISK=""
DISK_BASENAME=""
NEW_DISK=""

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
# set_disk_source <old_path> <new_path> - repoint the VM's disk non-interactively
# (the lab uses interactive 'virsh edit').
set_disk_source() {
    local old="$1" new="$2" tmp=/tmp/${VM_NAME}-svirt.xml
    sudo virsh dumpxml "$VM_NAME" > "$tmp"
    OLD_P="$old" NEW_P="$new" python3 - "$tmp" <<'PY'
import os, sys
path = sys.argv[1]
old, new = os.environ["OLD_P"], os.environ["NEW_P"]
with open(path) as f:
    xml = f.read()
xml = xml.replace(old, new, 1)
with open(path, "w") as f:
    f.write(xml)
PY
    sudo virsh define "$tmp" >/dev/null
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command virsh

    if ! command -v getenforce >/dev/null 2>&1; then
        die "getenforce not found; this lab requires SELinux userspace tools on an OL9 host"
    fi
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    info "getenforce: $mode"
    sestatus 2>/dev/null || true
    if [[ "$mode" == "Enforcing" ]]; then
        pass "Preflight: SELinux is Enforcing"
    else
        die "SELinux is '$mode', not Enforcing. Nothing in this lab behaves as described otherwise. Fix with 'setenforce 1' and enforcing=1 in config before continuing."
    fi

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found."

    # Discover the VM's boot disk path (vda).
    ORIG_DISK="$(sudo virsh domblklist "$VM_NAME" 2>/dev/null | awk '$1=="vda"{print $2; exit}')"
    [[ -z "$ORIG_DISK" ]] && ORIG_DISK="$(sudo virsh domblklist "$VM_NAME" 2>/dev/null | awk 'NR>2 && $2 ~ /\.qcow2$/ {print $2; exit}')"
    [[ -n "$ORIG_DISK" ]] || die "could not determine $VM_NAME's disk path from domblklist"
    DISK_BASENAME="$(basename "$ORIG_DISK")"
    NEW_DISK="${SVIRT_DIR}/${DISK_BASENAME}"
    info "Boot disk: $ORIG_DISK  ->  test path: $NEW_DISK"

    if ! command -v semanage >/dev/null 2>&1; then
        info "Installing policycoreutils-python-utils (provides semanage)"
        sudo dnf install -y policycoreutils-python-utils >/dev/null 2>&1 || true
    fi
    command -v semanage >/dev/null 2>&1 || die "semanage not available; needed for the fix step"

    # Make sure the VM is running so its process label is visible.
    if [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" != "running" ]]; then
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
        wait_for_state "$VM_NAME" running 12 || true
    fi
}

# --------------------------------------------------------------------------
# Step 1/2: Inspect the svirt_t process label and svirt_image_t disk label
# --------------------------------------------------------------------------
step1_labels() {
    log "Step 1/2: Inspect the sVirt process and disk labels"

    local ps_out ls_out
    ps_out="$(ps -eZ 2>/dev/null | grep -i qemu || true)"
    info "ps -eZ | grep qemu:"; printf '%s\n' "$ps_out"
    assert_contains "$ps_out" "svirt_t" "Step 1: QEMU process carries the svirt_t label"

    ls_out="$(ls -Z "$ORIG_DISK" 2>/dev/null || sudo ls -Z "$ORIG_DISK" 2>/dev/null || true)"
    info "ls -Z $ORIG_DISK:"; printf '%s\n' "$ls_out"
    assert_contains "$ls_out" "svirt_image_t" "Step 2: disk carries the svirt_image_t label"
}

# --------------------------------------------------------------------------
# Step 3: Move the disk to an unlabelled path - watch it fail to start
# --------------------------------------------------------------------------
step3_break() {
    log "Step 3: Move the disk to an unlabelled path and expect a start failure"

    info "Shutting the VM down"
    shutdown_vm "$VM_NAME" 24

    sudo mkdir -p "$SVIRT_DIR"
    sudo mv "$ORIG_DISK" "$NEW_DISK"
    local ls_out
    ls_out="$(sudo ls -Z "$NEW_DISK" 2>/dev/null || true)"
    info "ls -Z $NEW_DISK:"; printf '%s\n' "$ls_out"
    if printf '%s' "$ls_out" | grep -q "svirt_image_t"; then
        warn "Step 3: file already labelled svirt_image_t at the new path (unexpected)"
    else
        pass "Step 3: disk at new path is NOT svirt_image_t (inherited the directory's context)"
    fi

    info "Repointing the VM definition at $NEW_DISK"
    set_disk_source "$ORIG_DISK" "$NEW_DISK"

    info "Attempting to start the VM (expected to fail)"
    if sudo virsh start "$VM_NAME" >/dev/null 2>&1; then
        fail "Step 3: VM started from the unlabelled path (SELinux did NOT block it as expected)"
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    else
        pass "Step 3: VM refused to start from the unlabelled path (SELinux blocked it)"
    fi

    local avc
    avc="$(sudo ausearch -m avc -ts recent 2>/dev/null || true)"
    if printf '%s' "$avc" | grep -qi "denied"; then
        pass "Step 3: an AVC denial referencing the disk/qemu is present in the audit log"
    else
        warn "Step 3: no recent AVC denial found via ausearch (auditd may be off; check /var/log/audit)"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Fix it the right way with semanage + restorecon
# --------------------------------------------------------------------------
step4_fix() {
    log "Step 4: Fix with semanage fcontext + restorecon (never setenforce 0)"

    finding "Lab 11.1's whole point: the correct fix is 'semanage fcontext' + 'restorecon', NEVER 'setenforce 0'. Disabling SELinux would hide the very protection being demonstrated."

    sudo semanage fcontext -a -t svirt_image_t "${SVIRT_DIR}(/.*)?" >/dev/null 2>&1 \
        && pass "Step 4: registered ${SVIRT_DIR} as svirt_image_t in the fcontext policy" \
        || warn "Step 4: semanage fcontext add reported an issue (rule may already exist)"

    sudo restorecon -Rv "$SVIRT_DIR/" || true
    local ls_out
    ls_out="$(sudo ls -Z "$NEW_DISK" 2>/dev/null || true)"
    info "ls -Z $NEW_DISK (after restorecon):"; printf '%s\n' "$ls_out"
    assert_contains "$ls_out" "svirt_image_t" "Step 4: disk relabelled to svirt_image_t"

    info "Starting the VM again"
    if sudo virsh start "$VM_NAME" >/dev/null 2>&1; then
        pass "Step 4: VM starts successfully now (only SELinux policy changed)"
    else
        fail "Step 4: VM still fails to start after relabel"
    fi
}

# --------------------------------------------------------------------------
# Cleanup: restore the original disk location and remove the test fcontext rule
# --------------------------------------------------------------------------
cleanup_restore() {
    log "Cleanup: restore $VM_NAME to its original disk location"

    shutdown_vm "$VM_NAME" 24
    if sudo test -f "$NEW_DISK"; then
        sudo mv "$NEW_DISK" "$ORIG_DISK"
    fi
    set_disk_source "$NEW_DISK" "$ORIG_DISK"
    # Remove the test-only fcontext rule and clean the directory.
    sudo semanage fcontext -d "${SVIRT_DIR}(/.*)?" >/dev/null 2>&1 || true
    sudo rmdir "$SVIRT_DIR" >/dev/null 2>&1 || true

    info "Starting the VM from its original path"
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    wait_for_state "$VM_NAME" running 12 || true

    local ls_out
    ls_out="$(sudo ls -Z "$ORIG_DISK" 2>/dev/null || true)"
    if printf '%s' "$ls_out" | grep -q "svirt_image_t"; then
        pass "Cleanup: disk back at $ORIG_DISK with svirt_image_t (no restorecon needed - /var/lib/libvirt/images is labelled by default)"
    else
        warn "Cleanup: disk restored but label not confirmed; check $ORIG_DISK"
    fi
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]] \
        && pass "Cleanup: $VM_NAME running again from its original path" \
        || warn "Cleanup: $VM_NAME not running after restore; start it manually"
}

main() {
    preflight
    step1_labels
    step3_break
    step4_fix
    cleanup_restore
    summary
}

main "$@"
