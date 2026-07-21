#!/usr/bin/env bash
#
# test-lab-12.1-observe-under-load.sh - run and verify Lab 12.1 (Observe
# ol-lab-01 Under Load) end-to-end on the KVM host.
#
# Captures a quiet domstats baseline, generates real CPU and disk load inside the
# guest, confirms the host-side cpu.time climbs, and confirms libvirt lifecycle
# events fire on shutdown/start. Prints a PASS/WARN/FAIL line per lab "Expected
# result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: ol-lab-01 exists, is running, and is reachable over SSH; ideally
# the /data disk from Lab 5.1 is available in the guest for the disk-load step.
#
# NOTE: the lab uses three interactive terminals (virt-top, 'virsh event --loop'
# needing Ctrl-C). This script instead samples domstats twice and collects events
# with a bounded 'virsh event --timeout', so it runs unattended.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-12.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
GUEST_DATA="${GUEST_DATA:-/data}"
LOAD_SECS="${LOAD_SECS:-30}"
EVENT_LOG="${EVENT_LOG:-/tmp/${VM_NAME}-lab12-events.log}"
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
        || die "$VM_NAME not found."

    if [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" != "running" ]]; then
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
        wait_for_state "$VM_NAME" running 12 || true
    fi
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]] \
        && pass "Preflight: $VM_NAME is running" \
        || die "$VM_NAME is not running"

    if ! ADDR="$(wait_for_vm_addr lease 24)"; then ADDR="$(vm_addr_any "$VM_NAME" || true)"; fi
    if [[ -n "$ADDR" ]] && vm_ssh_ok "$ADDR"; then
        pass "Preflight: guest reachable at $ADDR"
        vm_ssh "$ADDR" 'command -v stress-ng >/dev/null 2>&1 || sudo dnf install -y stress-ng' >/dev/null 2>&1 || true
    else
        warn "Preflight: guest not reachable over SSH; CPU/disk load will be skipped (event checks still run)"
    fi

    if ! command -v virt-top >/dev/null 2>&1; then
        sudo dnf install -y virt-top >/dev/null 2>&1 || true
    fi
    finding "Lab 12.1 uses three interactive terminals (virt-top and 'virsh event --loop', both needing Ctrl-C). For automation/monitoring, sample 'virsh domstats' twice and use 'virsh event --timeout N' - which is what this script does."
}

# domstats_cputime - print the VM's cpu.time counter (nanoseconds).
domstats_cputime() {
    sudo virsh domstats "$VM_NAME" 2>/dev/null | awk -F= '/cpu\.time=/ {print $2; exit}'
}

# --------------------------------------------------------------------------
# Step 1: Baseline with domstats
# --------------------------------------------------------------------------
BASE_CPU=""
step1_baseline() {
    log "Step 1: Baseline with virsh domstats"
    info "virsh domstats $VM_NAME (excerpt):"
    sudo virsh domstats "$VM_NAME" 2>/dev/null | grep -E 'cpu\.time|balloon\.current|block\.' | head -n 8 || true
    BASE_CPU="$(domstats_cputime)"
    info "Baseline cpu.time: ${BASE_CPU:-unknown} ns"
    [[ -n "$BASE_CPU" ]] && pass "Step 1: captured baseline cpu.time" \
        || fail "Step 1: could not read cpu.time from domstats"
}

# --------------------------------------------------------------------------
# Step 2: Generate load and watch the numbers move
# --------------------------------------------------------------------------
step2_load() {
    log "Step 2: Generate CPU + disk load and confirm cpu.time climbs"

    if [[ -z "$ADDR" ]] || ! vm_ssh_ok "$ADDR"; then
        warn "Step 2: guest not reachable; skipping load generation and the cpu.time delta check"
        return
    fi

    local vcpus
    vcpus="$(sudo virsh vcpucount "$VM_NAME" --live 2>/dev/null | awk '/current/&&/live/{print $3; exit}')"
    [[ -n "$vcpus" ]] || vcpus=2
    info "Starting stress-ng --cpu $vcpus for ${LOAD_SECS}s and a dd disk load"
    vm_ssh "$ADDR" "nohup stress-ng --cpu $vcpus --timeout ${LOAD_SECS}s >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    # Disk load only if the Lab 5.1 /data disk is mounted.
    if [[ "$(vm_ssh "$ADDR" "mountpoint -q $GUEST_DATA && echo yes || echo no" 2>/dev/null)" == "yes" ]]; then
        vm_ssh "$ADDR" "sudo dd if=/dev/zero of=$GUEST_DATA/loadtest.img bs=1M count=1000 oflag=direct >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    else
        info "Step 2: $GUEST_DATA not mounted; running CPU load only (Lab 5.1 provides /data)"
    fi

    info "Letting the load run..."
    sleep "$((LOAD_SECS / 2 + 5))"

    local after
    after="$(domstats_cputime)"
    info "cpu.time after load: ${after:-unknown} ns (baseline ${BASE_CPU:-unknown})"
    if [[ -n "$BASE_CPU" && -n "$after" ]] && awk -v a="$after" -v b="$BASE_CPU" 'BEGIN{exit !(a>b)}'; then
        pass "Step 2: cpu.time climbed under load (host view reflects guest activity)"
    else
        fail "Step 2: cpu.time did not climb as expected"
    fi

    # Clean up the disk load file, once dd has finished.
    sleep "$((LOAD_SECS / 2 + 5))"
    vm_ssh "$ADDR" "sudo rm -f $GUEST_DATA/loadtest.img" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Step 3/4: Stream lifecycle events and confirm stop/start fire
# --------------------------------------------------------------------------
step3_events() {
    log "Step 3/4: Confirm lifecycle events fire on shutdown/start"

    : > "$EVENT_LOG"
    info "Collecting events with a bounded 'virsh event --timeout' (no Ctrl-C needed)"
    sudo timeout 90 virsh event --loop --all >"$EVENT_LOG" 2>&1 &
    local evjob=$!
    sleep 2

    info "Shutting the VM down (expect a 'Stopped' lifecycle event)"
    shutdown_vm "$VM_NAME" 18
    sleep 3
    info "Starting the VM (expect a 'Started'/'Booted' lifecycle event)"
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    wait_for_state "$VM_NAME" running 12 || true
    sleep 3

    # Stop the collector.
    sudo kill "$evjob" >/dev/null 2>&1 || true
    wait "$evjob" 2>/dev/null || true

    info "Collected events:"; cat "$EVENT_LOG" 2>/dev/null || true
    local events
    events="$(cat "$EVENT_LOG" 2>/dev/null || true)"
    if printf '%s' "$events" | grep -qiE 'Stopped|Shutdown'; then
        pass "Step 4: a Stopped/Shutdown lifecycle event fired"
    else
        fail "Step 4: no Stopped lifecycle event captured"
    fi
    if printf '%s' "$events" | grep -qiE 'Started|Booted|Resumed'; then
        pass "Step 4: a Started/Booted lifecycle event fired"
    else
        fail "Step 4: no Started lifecycle event captured"
    fi
    finding "Lab 12.1 uses 'ssh cloud-user@<addr>' - correct for the cloud image. The event stream ('virsh event --all') is the same feed a monitoring/alerting system would parse in production."
}

main() {
    preflight
    step1_baseline
    step2_load
    step3_events
    summary
}

main "$@"
