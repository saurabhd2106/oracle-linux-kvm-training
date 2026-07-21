#!/usr/bin/env bash
#
# test-lab-10.2-cpu-cap.sh - run and verify Lab 10.2 (Cap ol-lab-01 & Watch It
# Bite) end-to-end on the KVM host.
#
# Baselines the VM uncapped, applies a 20%-of-one-core CPU quota via schedinfo,
# re-runs the same stress workload and confirms the throughput drops, then reads
# the kernel's cgroup cpu.max file to prove libvirt and the kernel agree.
# Optionally applies a disk I/O cap. Prints a PASS/WARN/FAIL line per lab
# "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user. It SSHes into
# the guest to generate load (the lab's "Terminal 1"); host-side checks are the
# lab's "Terminal 2".
#
# PREREQUISITES: ol-lab-01 exists and is running, reachable over SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-10.2"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
QUOTA="${QUOTA:-20000}"          # 20% of one core at the default 100000 period
IO_CAP_BYTES="${IO_CAP_BYTES:-10485760}"  # 10 MB/s
GUEST_DATA="${GUEST_DATA:-/data}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
STRESS_ARGS="${STRESS_ARGS:---cpu 1 --cpu-method matrixprod --timeout 20s --metrics-brief}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
ADDR=""
preflight() {
    log "Preflight checks"
    require_command virsh

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found. Run Lab 3.1 first."

    local state
    state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
    if [[ "$state" != "running" ]]; then
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
        wait_for_state "$VM_NAME" running 12 || true
    fi
    [[ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]] \
        && pass "Preflight: $VM_NAME is running" \
        || die "$VM_NAME is not running"

    if ! ADDR="$(wait_for_vm_addr lease 24)"; then ADDR="$(vm_addr_any "$VM_NAME" || true)"; fi
    if [[ -n "$ADDR" ]] && vm_ssh_ok "$ADDR"; then
        pass "Preflight: guest reachable over SSH at $ADDR"
        info "Ensuring stress-ng is installed in the guest"
        vm_ssh "$ADDR" 'command -v stress-ng >/dev/null 2>&1 || sudo dnf install -y stress-ng' >/dev/null 2>&1 || true
    else
        warn "Preflight: guest not reachable over SSH; workload throughput checks will be skipped (host-side cap checks still run)"
    fi
}

# stress_ops <addr> - run the stress workload, print total bogo-ops (integer).
stress_ops() {
    local addr="$1" out
    out="$(vm_ssh "$addr" "stress-ng ${STRESS_ARGS} 2>&1" || true)"
    printf '%s\n' "$out" >&2
    printf '%s' "$out" | awk '/ cpu / {for (i=1;i<=NF;i++) if ($i=="cpu") {print $(i+1); exit}}'
}

# --------------------------------------------------------------------------
# Step 1: Baseline - uncapped
# --------------------------------------------------------------------------
BASELINE_OPS=""
step1_baseline() {
    log "Step 1: Baseline the VM uncapped"

    # Ensure a clean uncapped baseline even if a prior run left a cap.
    sudo virsh schedinfo "$VM_NAME" --set vcpu_quota=-1 --live --config >/dev/null 2>&1 || true
    local sched
    sched="$(sudo virsh schedinfo "$VM_NAME" 2>/dev/null || true)"
    info "virsh schedinfo $VM_NAME:"; printf '%s\n' "$sched"
    if printf '%s' "$sched" | grep -q 'vcpu_quota *: *-1'; then
        pass "Step 1: vcpu_quota is -1 (unlimited)"
    else
        warn "Step 1: vcpu_quota is not -1 at baseline"
    fi

    if [[ -n "$ADDR" ]] && vm_ssh_ok "$ADDR"; then
        info "Running uncapped stress workload..."
        BASELINE_OPS="$(stress_ops "$ADDR")"
        info "Baseline bogo-ops: ${BASELINE_OPS:-unknown}"
        [[ -n "$BASELINE_OPS" ]] && pass "Step 1: captured uncapped baseline throughput" \
            || warn "Step 1: could not parse baseline throughput from stress-ng"
    fi
}

# --------------------------------------------------------------------------
# Step 2: Apply a cap with schedinfo vcpu_quota
# --------------------------------------------------------------------------
step2_apply_cap() {
    log "Step 2: Apply a CPU quota of $QUOTA"

    local period
    period="$(sudo virsh schedinfo "$VM_NAME" 2>/dev/null | awk -F: '/vcpu_period/ {gsub(/ /,"",$2); print $2}')"
    info "Current vcpu_period: ${period:-unknown} (default 100000 = 100ms)"

    sudo virsh schedinfo "$VM_NAME" --set "vcpu_quota=${QUOTA}" --live --config >/dev/null 2>&1 \
        && pass "Step 2: vcpu_quota set to $QUOTA (live+config)" \
        || fail "Step 2: failed to set vcpu_quota"

    local sched
    sched="$(sudo virsh schedinfo "$VM_NAME" 2>/dev/null || true)"
    if printf '%s' "$sched" | grep -q "vcpu_quota *: *${QUOTA}"; then
        pass "Step 2: schedinfo confirms vcpu_quota=$QUOTA"
    else
        fail "Step 2: schedinfo does not show vcpu_quota=$QUOTA"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Re-run the stress and watch it throttle
# --------------------------------------------------------------------------
step3_rerun_stress() {
    log "Step 3: Re-run the same stress and confirm throttling"

    if [[ -z "$ADDR" ]] || ! vm_ssh_ok "$ADDR"; then
        warn "Step 3: guest not reachable; skipping throughput comparison"
        return
    fi
    info "Running capped stress workload..."
    local capped_ops
    capped_ops="$(stress_ops "$ADDR")"
    info "Capped bogo-ops: ${capped_ops:-unknown} (baseline was ${BASELINE_OPS:-unknown})"

    if [[ -n "$BASELINE_OPS" && -n "$capped_ops" ]]; then
        # Expect roughly a fifth; assert it dropped to under half the baseline.
        if awk -v b="$BASELINE_OPS" -v c="$capped_ops" 'BEGIN{exit !(c < b*0.5)}'; then
            pass "Step 3: capped throughput ($capped_ops) is well below baseline ($BASELINE_OPS)"
        else
            fail "Step 3: capped throughput ($capped_ops) did not drop below half of baseline ($BASELINE_OPS)"
        fi
    else
        warn "Step 3: missing throughput numbers; cannot compare"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Confirm the kernel cgroup cpu.max agrees
# --------------------------------------------------------------------------
step4_cgroup() {
    log "Step 4: Read the cgroup cpu.max and confirm it matches"

    local cgpath
    cgpath="$(sudo find /sys/fs/cgroup/machine.slice -maxdepth 1 -iname "*$(printf '%s' "$VM_NAME" | tr '.-' '**')*" 2>/dev/null | head -n1)"
    if [[ -z "$cgpath" ]]; then
        cgpath="$(sudo find /sys/fs/cgroup/machine.slice -maxdepth 1 -iname "*ol*lab*" 2>/dev/null | head -n1)"
    fi
    if [[ -z "$cgpath" ]]; then
        warn "Step 4: could not locate the VM's cgroup scope under machine.slice (cgroup v1 host?)"
        finding "Step 4 assumes cgroup v2 (cpu.max under machine.slice). On a cgroup v1 host the path/format differs (cpu.cfs_quota_us / cpu.cfs_period_us)."
        return
    fi
    info "cgroup scope: $cgpath"
    local cpumax
    cpumax="$(sudo cat "$cgpath/cpu.max" 2>/dev/null || true)"
    info "cpu.max: $cpumax"
    if [[ "${cpumax%% *}" == "$QUOTA" ]]; then
        pass "Step 4: kernel cpu.max quota ($cpumax) matches vcpu_quota=$QUOTA"
    else
        fail "Step 4: cpu.max ($cpumax) does not start with the quota $QUOTA"
    fi
}

# --------------------------------------------------------------------------
# Optional: Disk I/O cap
# --------------------------------------------------------------------------
step5_io_cap() {
    log "Optional: Disk I/O throughput cap"

    finding "Lab 10.2 Step 15 caps 'vda' with blkdeviotune but the dd workload writes to /data, which is the SECOND disk (vdb from Lab 5.1). The cap should target the disk being tested. This script caps the disk that actually backs /data."

    if [[ -z "$ADDR" ]] || ! vm_ssh_ok "$ADDR"; then
        warn "Optional: guest not reachable; skipping disk I/O cap"
        return
    fi
    local mounted
    mounted="$(vm_ssh "$ADDR" "mountpoint -q $GUEST_DATA && echo yes || echo no" 2>/dev/null || echo no)"
    if [[ "$mounted" != "yes" ]]; then
        info "Optional: $GUEST_DATA not mounted in guest; skipping I/O cap (run Lab 5.1 first)"
        return
    fi

    # Determine which host-side target backs /data (default vdb).
    local target="vdb"
    if ! sudo virsh domblklist "$VM_NAME" 2>/dev/null | awk '{print $1}' | grep -qx vdb; then
        target="vda"
    fi
    info "Baseline dd on $GUEST_DATA (uncapped):"
    vm_ssh "$ADDR" "sudo dd if=/dev/zero of=$GUEST_DATA/iotest.img bs=1M count=500 oflag=direct 2>&1" | tail -n1 || true

    sudo virsh blkdeviotune "$VM_NAME" "$target" --total-bytes-sec "$IO_CAP_BYTES" --live --config >/dev/null 2>&1 \
        && pass "Optional: blkdeviotune applied to $target ($IO_CAP_BYTES B/s)" \
        || warn "Optional: blkdeviotune failed on $target"

    info "Re-running dd on $GUEST_DATA (capped):"
    vm_ssh "$ADDR" "sudo rm -f $GUEST_DATA/iotest.img; sudo dd if=/dev/zero of=$GUEST_DATA/iotest.img bs=1M count=500 oflag=direct 2>&1" | tail -n1 || true
    vm_ssh "$ADDR" "sudo rm -f $GUEST_DATA/iotest.img" >/dev/null 2>&1 || true
    info "Compare the two dd transfer rates above; the capped run should be near $((IO_CAP_BYTES / 1048576)) MB/s."
}

main() {
    preflight
    step1_baseline
    step2_apply_cap
    step3_rerun_stress
    step4_cgroup
    step5_io_cap
    summary
}

main "$@"
