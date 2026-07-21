#!/usr/bin/env bash
#
# test-lab-6.1-snapshot-fault-restore.sh - run and verify Lab 6.1 (Snapshot,
# Fault, Restore) end-to-end against a running ol-lab-01.
#
# Takes a live internal (disk+memory) snapshot, deliberately breaks remote SSH
# on the guest, confirms the fault from the host, reverts to the snapshot, and
# confirms SSH is restored - then inspects the snapshot tree/info. Prints a
# PASS/WARN/FAIL line per lab "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: ol-lab-01 exists, is running, and is reachable over SSH on its
# network address (Lab 3.1/4.1, plus Option 1/2 if bridged on OCI).
#
# NOTE: unlike the lab, this script does NOT use virt-viewer. It disables sshd
# over the existing SSH session (backgrounded so the command survives the drop),
# which is how you would automate this on a headless OCI host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-6.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
SNAP_NAME="${SNAP_NAME:-pre-fault-snapshot}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
ADDR=""
preflight() {
    log "Preflight checks"
    require_command virsh

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found. Run Lab 3.1/4.1 first."

    local state
    state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
    if [[ "$state" != "running" ]]; then
        info "$VM_NAME is '$state'; starting it"
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
        wait_for_state "$VM_NAME" running 12 || true
    fi
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]] \
        && pass "Preflight: $VM_NAME is running" \
        || die "$VM_NAME is not running"

    if ! ADDR="$(wait_for_vm_addr lease 24)"; then
        ADDR="$(vm_addr_any "$VM_NAME" || true)"
    fi
    [[ -n "$ADDR" ]] || die "could not determine $VM_NAME's address (needed to prove the fault over SSH)"
    info "Guest address: $ADDR"

    finding "Lab 6.1 uses 'ssh oracle@<addr>'; the cloud image delivers the SSH key to cloud-user/opc, not an 'oracle' user. This script tries cloud-user/opc/root."
    finding "Lab 6.1 Step 5 breaks sshd from a virt-viewer GUI console. On a headless OCI host that is impractical; this script disables sshd over SSH (backgrounded) or via 'virsh console', which is the automatable equivalent."
}

# --------------------------------------------------------------------------
# Step 1: Take a snapshot in a known-good state
# --------------------------------------------------------------------------
step1_snapshot() {
    log "Step 1: Confirm SSH works, then snapshot in a known-good state"

    if vm_ssh_ok "$ADDR"; then
        pass "Step 1: SSH into $VM_NAME works (known-good state confirmed)"
    else
        warn "Step 1: SSH not reachable at start; attempting to recover via any existing '$SNAP_NAME'"
        sudo virsh snapshot-revert "$VM_NAME" "$SNAP_NAME" >/dev/null 2>&1 || true
        sleep 10
        vm_ssh_ok "$ADDR" \
            && pass "Step 1: SSH recovered after revert" \
            || die "Step 1: SSH to $VM_NAME not working and could not be recovered; fix reachability first"
    fi

    # Idempotent: recreate the known-good snapshot from the current working state.
    sudo virsh snapshot-delete "$VM_NAME" "$SNAP_NAME" >/dev/null 2>&1 || true
    if sudo virsh snapshot-create-as "$VM_NAME" "$SNAP_NAME" \
        "Known-good state, SSH working" >/dev/null 2>&1; then
        pass "Step 1: snapshot '$SNAP_NAME' created"
    else
        fail "Step 1: snapshot-create-as failed (internal disk+memory snapshots need all disks to be qcow2)"
        finding "Internal snapshots require every attached disk to support them (qcow2). If Lab 5.1 attached a raw volume, 'snapshot-create-as' fails; use qcow2 volumes or --disk-only/external snapshots."
        return
    fi

    local snaplist
    snaplist="$(sudo virsh snapshot-list "$VM_NAME" 2>/dev/null || true)"
    info "virsh snapshot-list $VM_NAME:"; printf '%s\n' "$snaplist"
    assert_contains "$snaplist" "$SNAP_NAME" "Step 1: '$SNAP_NAME' listed"
    if printf '%s' "$snaplist" | awk -v s="$SNAP_NAME" '$1==s' | grep -q "running"; then
        pass "Step 1: snapshot state is 'running' (includes memory, not --disk-only)"
    else
        warn "Step 1: snapshot state not shown as 'running'"
    fi
}

# --------------------------------------------------------------------------
# Step 2 + 3: Break sshd on the guest, then confirm the fault from the host
# --------------------------------------------------------------------------
step2_break_and_confirm() {
    log "Step 2/3: Disable sshd on the guest and confirm the fault"

    # Backgrounded via nohup so the command survives sshd dropping our session.
    vm_ssh "$ADDR" 'sudo nohup sh -c "systemctl disable sshd; systemctl stop sshd" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
    info "Waiting for sshd to go down..."
    local i broken=1
    for ((i = 0; i < 12; i++)); do
        sleep 5
        if ! vm_ssh_ok "$ADDR"; then broken=0; break; fi
    done
    if (( broken == 0 )); then
        pass "Step 3: SSH to $VM_NAME now refused/timed out (fault confirmed)"
    else
        fail "Step 3: SSH still reachable; sshd was not disabled as expected"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Revert to the pre-fault snapshot
# --------------------------------------------------------------------------
step4_revert() {
    log "Step 4: Revert $VM_NAME to '$SNAP_NAME'"

    if sudo virsh snapshot-revert "$VM_NAME" "$SNAP_NAME" >/dev/null 2>&1; then
        pass "Step 4: snapshot-revert completed"
    else
        fail "Step 4: snapshot-revert failed"
        return
    fi

    info "Waiting for the VM to settle and sshd to come back"
    if vm_ssh_retry "$ADDR" 'echo ok' 12 >/dev/null 2>&1; then
        pass "Step 4: SSH access restored after revert (fault gone)"
    else
        fail "Step 4: SSH not restored after revert"
    fi
}

# --------------------------------------------------------------------------
# Step 5: Review the snapshot
# --------------------------------------------------------------------------
step5_review() {
    log "Step 5: Review the snapshot"

    local tree info_out
    tree="$(sudo virsh snapshot-list "$VM_NAME" --tree 2>/dev/null || true)"
    info "virsh snapshot-list $VM_NAME --tree:"; printf '%s\n' "$tree"
    assert_contains "$tree" "$SNAP_NAME" "Step 5: '$SNAP_NAME' present in the snapshot tree"

    info_out="$(sudo virsh snapshot-info "$VM_NAME" "$SNAP_NAME" 2>/dev/null || true)"
    info "virsh snapshot-info:"; printf '%s\n' "$info_out"
    assert_contains "$info_out" "running" "Step 5: snapshot State is running"
    assert_contains "$info_out" "internal" "Step 5: snapshot Location is internal (disk+memory)"

    finding "Lab 6.1 leaves '$SNAP_NAME' in place. A snapshot lives inside the same qcow2 as the VM and is NOT a backup (see Lab 14.1). In production, delete rollback snapshots you no longer need with 'virsh snapshot-delete'."
}

main() {
    preflight
    step1_snapshot
    step2_break_and_confirm
    step4_revert
    step5_review
    summary
}

main "$@"
