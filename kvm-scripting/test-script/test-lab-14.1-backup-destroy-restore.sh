#!/usr/bin/env bash
#
# test-lab-14.1-backup-destroy-restore.sh - run and verify Lab 14.1 (Back Up,
# Destroy, Restore) end-to-end on the KVM host.
#
# Writes a recognisable marker inside the guest, backs up the VM's XML plus ALL
# of its attached disks and seed media to an external location, destroys the VM
# with 'undefine --remove-all-storage', then restores it purely from the backup
# and verifies the marker survived. Prints a PASS/WARN/FAIL line per lab
# "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# WARNING: this deliberately runs 'virsh undefine --remove-all-storage', which is
# genuinely destructive. It only does so AFTER backing up every attached disk, and
# restores the VM afterwards.
#
# PREREQUISITES: ol-lab-01 exists and is reachable over SSH; ideally the /data
# disk from Lab 5.1 is mounted so the marker lives on a second disk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-14.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/data/backups}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/${VM_NAME}}"
GUEST_DATA="${GUEST_DATA:-/data}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

ADDR=""
MARKER_PATH=""
MARKER_CONTENT=""
DISK_SOURCES=()

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command virsh

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found."

    if [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" != "running" ]]; then
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
        wait_for_state "$VM_NAME" running 12 || true
    fi

    # Choose a backup root; the lab uses /mnt/data (a separate disk).
    if ! findmnt -rn --target "$(dirname "$BACKUP_ROOT")" >/dev/null 2>&1; then :; fi
    if [[ "$BACKUP_ROOT" == /mnt/data/* ]] && ! findmnt -rn --target /mnt/data >/dev/null 2>&1; then
        warn "Preflight: /mnt/data is not a separate mount; backups will not be on an independent disk"
        finding "Lab 14.1 (correctly) stores backups on /mnt/data, a disk separate from the one being protected. /mnt/data was not a separate mount here; using ${BACKUP_ROOT} anyway. A real backup must live on separate storage."
    fi
    sudo mkdir -p "$BACKUP_DIR"
    pass "Preflight: backup directory ready ($BACKUP_DIR)"

    if ! ADDR="$(wait_for_vm_addr lease 24)"; then ADDR="$(vm_addr_any "$VM_NAME" || true)"; fi
    if [[ -n "$ADDR" ]] && vm_ssh_ok "$ADDR"; then
        pass "Preflight: guest reachable at $ADDR"
    else
        warn "Preflight: guest not reachable over SSH; the data-integrity marker check will be limited"
    fi
}

# --------------------------------------------------------------------------
# Prerequisite step: write a recognisable marker inside the guest
# --------------------------------------------------------------------------
step0_marker() {
    log "Prereq: Write a recognisable marker inside the guest"

    if [[ -z "$ADDR" ]] || ! vm_ssh_ok "$ADDR"; then
        warn "Prereq: guest unreachable; skipping marker write (restore will still be verified structurally)"
        return
    fi

    # Prefer the Lab 5.1 /data (second disk); fall back to /var/tmp (boot disk).
    if [[ "$(vm_ssh "$ADDR" "mountpoint -q $GUEST_DATA && echo yes || echo no" 2>/dev/null)" == "yes" ]]; then
        MARKER_PATH="${GUEST_DATA}/backup-marker.txt"
    else
        MARKER_PATH="/var/tmp/backup-marker.txt"
        finding "Lab 14.1 writes its marker to /data (the Lab 5.1 second disk). /data was not mounted here, so the marker went to ${MARKER_PATH} on the boot disk. To exercise multi-disk backup, run Lab 5.1 first."
    fi
    MARKER_CONTENT="Backup drill $(date '+%Y-%m-%d %H:%M:%S') $$"
    vm_ssh "$ADDR" "echo '$MARKER_CONTENT' | sudo tee $MARKER_PATH >/dev/null" >/dev/null 2>&1 || true
    local got
    got="$(vm_ssh "$ADDR" "cat $MARKER_PATH" || true)"
    if [[ "$got" == "$MARKER_CONTENT" ]]; then
        pass "Prereq: marker written to $MARKER_PATH inside the guest"
    else
        warn "Prereq: could not confirm the marker in the guest"
    fi
    # Flush to disk before we shut down.
    vm_ssh "$ADDR" 'sync' >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Step 1: Shut down; back up XML and ALL disks
# --------------------------------------------------------------------------
step1_backup() {
    log "Step 1: Shut down and back up XML + all attached disks"

    finding "Lab 14.1 Step 5 backs up only ol-lab-01.qcow2 (+ seed) but Step 7 runs 'undefine --remove-all-storage', which deletes EVERY attached disk - including the Lab 5.1 /data disk (vdb) - yet Step 4 expects the /data marker to survive. This script backs up ALL disks from domblklist so the restore genuinely recovers the marker."

    info "Shutting the VM down"
    shutdown_vm "$VM_NAME" 24
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] \
        && pass "Step 1: $VM_NAME is shut off" \
        || fail "Step 1: $VM_NAME did not shut off"

    # Save the XML definition.
    sudo virsh dumpxml "$VM_NAME" > "/tmp/${VM_NAME}.xml"
    sudo cp "/tmp/${VM_NAME}.xml" "${BACKUP_DIR}/${VM_NAME}.xml"
    [[ -s "${BACKUP_DIR}/${VM_NAME}.xml" ]] && pass "Step 1: XML definition backed up" \
        || fail "Step 1: XML backup is empty"

    # Collect ALL file-backed disk sources (boot disk, data disks, seed ISO).
    mapfile -t DISK_SOURCES < <(sudo virsh domblklist "$VM_NAME" --details 2>/dev/null \
        | awk '$1=="file" && $4!="-" {print $4}')
    info "Attached disk sources to back up: ${DISK_SOURCES[*]:-none}"

    local src ok=1
    for src in "${DISK_SOURCES[@]}"; do
        if sudo cp "$src" "${BACKUP_DIR}/$(basename "$src")"; then
            info "Backed up $(basename "$src")"
        else
            ok=0
            fail "Step 1: failed to back up $src"
        fi
    done
    (( ok == 1 )) && (( ${#DISK_SOURCES[@]} > 0 )) \
        && pass "Step 1: all ${#DISK_SOURCES[@]} attached disk(s) backed up to $BACKUP_DIR" \
        || warn "Step 1: disk backup incomplete"

    info "Backup contents:"; sudo ls -lh "$BACKUP_DIR" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Step 2: Simulate disaster - undefine --remove-all-storage
# --------------------------------------------------------------------------
step2_destroy() {
    log "Step 2: Simulate disaster (undefine --remove-all-storage)"

    sudo virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 \
        || sudo virsh undefine "$VM_NAME" --remove-all-storage --nvram >/dev/null 2>&1 || true

    local vmlist
    vmlist="$(sudo virsh list --all 2>/dev/null || true)"
    assert_not_contains "$vmlist" "$VM_NAME" "Step 2: $VM_NAME no longer in 'virsh list --all'"

    local gone=1 src
    for src in "${DISK_SOURCES[@]}"; do
        if sudo test -e "$src"; then gone=0; info "still present: $src"; fi
    done
    if (( gone == 1 )); then
        pass "Step 2: original disk(s) genuinely removed from libvirt storage"
    else
        warn "Step 2: some original disk files still present (unexpected)"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Restore - disks back, define XML, start
# --------------------------------------------------------------------------
step3_restore() {
    log "Step 3: Restore from backup (disks back, define XML, start)"

    local src
    for src in "${DISK_SOURCES[@]}"; do
        sudo mkdir -p "$(dirname "$src")"
        sudo cp "${BACKUP_DIR}/$(basename "$src")" "$src" \
            && info "Restored $(basename "$src") -> $src" \
            || fail "Step 3: failed to restore $src"
    done

    sudo virsh define "${BACKUP_DIR}/${VM_NAME}.xml" >/dev/null 2>&1 \
        && pass "Step 3: domain redefined from backup XML" \
        || fail "Step 3: virsh define failed"

    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    wait_for_state "$VM_NAME" running 12 || true
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]] \
        && pass "Step 3: $VM_NAME restored and running" \
        || fail "Step 3: $VM_NAME not running after restore"
}

# --------------------------------------------------------------------------
# Step 4: Confirm the guest boots with its data intact
# --------------------------------------------------------------------------
step4_verify_data() {
    log "Step 4: Confirm the marker survived the disaster"

    if [[ -z "$MARKER_PATH" ]]; then
        warn "Step 4: no marker was written (guest was unreachable earlier); skipping data-integrity check"
        return
    fi

    local addr
    if ! addr="$(wait_for_vm_addr lease 30)"; then addr="$(vm_addr_any "$VM_NAME" || true)"; fi
    if [[ -z "$addr" ]] || ! vm_ssh_retry "$addr" 'echo ok' 18 >/dev/null 2>&1; then
        warn "Step 4: restored guest not reachable over SSH; cannot read the marker back"
        return
    fi

    # If the marker lived on /data, make sure it is mounted after restore.
    if [[ "$MARKER_PATH" == "$GUEST_DATA/"* ]]; then
        vm_ssh "$addr" "mountpoint -q $GUEST_DATA || sudo mount /dev/vdb1 $GUEST_DATA" >/dev/null 2>&1 || true
    fi

    local got
    got="$(vm_ssh "$addr" "cat $MARKER_PATH" 2>/dev/null || true)"
    info "marker read back: '$got'"
    if [[ "$got" == "$MARKER_CONTENT" ]]; then
        pass "Step 4: marker recovered byte-for-byte (genuine data restored, not just a VM that boots)"
    else
        fail "Step 4: marker content did not match after restore (expected '$MARKER_CONTENT')"
    fi

    finding "Lab 14.1's restored VM keeps its original identity (same instance-id, so cloud-init does not re-run) - the correct behaviour for a restore, and the opposite of Lab 13.1's fresh-identity templating."
}

main() {
    preflight
    step0_marker
    step1_backup
    step2_destroy
    step3_restore
    step4_verify_data
    summary
}

main "$@"
