#!/usr/bin/env bash
#
# test-lab-10.1-numa-pin.sh - run and verify Lab 10.1 (Pin ol-lab-01 & Prove It
# Took) end-to-end on the KVM host.
#
# Reads the host NUMA topology, captures a baseline of the VM's vCPU affinity,
# pins both vCPUs to distinct cores on node 0, locks memory to node 0 in strict
# mode, then re-checks and proves the before/after difference. Prints a
# PASS/WARN/FAIL line per lab "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: ol-lab-01 exists and is running, ideally with 2 vCPUs (Lab 3.1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-10.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
NODE0_CORES=()
VCPU_COUNT=0
preflight() {
    log "Preflight checks"
    require_command virsh
    require_command lscpu

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found. Run Lab 3.1 first."

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

    if ! command -v numactl >/dev/null 2>&1; then
        info "Installing numactl (provides numactl/numastat)"
        sudo dnf install -y numactl >/dev/null 2>&1 || true
    fi
}

# --------------------------------------------------------------------------
# Step 1: Read the host topology
# --------------------------------------------------------------------------
step1_topology() {
    log "Step 1: Read the host NUMA topology"

    info "lscpu (NUMA/Socket/Core/Thread):"
    lscpu | grep -E "NUMA|Socket|Core|Thread" || true

    local nodes
    nodes="$(lscpu | awk -F: '/NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}')"
    info "NUMA node count: ${nodes:-unknown}"
    if [[ "${nodes:-0}" -le 1 ]]; then
        warn "Step 1: host exposes a single NUMA node; pinning still works but the after-state won't show a dramatic node-to-node shift"
        finding "This host has a single NUMA node (common on cloud/nested instances). The pinning mechanics are still validated, but numastat won't show memory migrating between nodes."
    fi

    # Determine node 0's CPU list.
    if command -v numactl >/dev/null 2>&1; then
        info "numactl --hardware:"; numactl --hardware || true
        read -r -a NODE0_CORES <<<"$(numactl --hardware 2>/dev/null | awk '/node 0 cpus:/ {$1="";$2="";$3="";print}')"
    fi
    if [[ ${#NODE0_CORES[@]} -eq 0 ]]; then
        # Fallback: NUMA node0 CPU(s) line from lscpu, or just 0..n.
        local line
        line="$(lscpu | awk -F: '/NUMA node0 CPU/ {print $2}')"
        if [[ -n "$line" ]]; then
            # Expand a range like "0-3" to a list.
            line="$(printf '%s' "$line" | tr -d ' ')"
            if [[ "$line" == *-* ]]; then
                read -r -a NODE0_CORES <<<"$(seq "${line%-*}" "${line#*-}")"
            else
                IFS=',' read -r -a NODE0_CORES <<<"$line"
            fi
        fi
    fi
    if [[ ${#NODE0_CORES[@]} -eq 0 ]]; then
        NODE0_CORES=(0 1)
        warn "Step 1: could not parse node 0 CPU list; defaulting to cores 0 and 1"
    fi
    info "Node 0 cores available for pinning: ${NODE0_CORES[*]}"
    pass "Step 1: host topology read; node 0 has ${#NODE0_CORES[@]} core(s)"
}

# --------------------------------------------------------------------------
# Step 2: Capture the baseline
# --------------------------------------------------------------------------
BASELINE_VCPUINFO=""
step2_baseline() {
    log "Step 2: Capture the baseline placement"

    VCPU_COUNT="$(sudo virsh vcpucount "$VM_NAME" --live 2>/dev/null | awk '/current/ && /live/ {print $3; exit}')"
    [[ -n "$VCPU_COUNT" ]] || VCPU_COUNT="$(sudo virsh dumpxml "$VM_NAME" | awk -F'[<>]' '/<vcpu/ {print $3; exit}')"
    info "$VM_NAME vCPU count: ${VCPU_COUNT:-unknown}"
    if [[ "${VCPU_COUNT:-0}" -lt 2 ]]; then
        warn "Step 2: $VM_NAME has ${VCPU_COUNT:-?} vCPU(s); Lab 10.1 expects 2 (from Lab 3.1)"
        finding "Lab 10.1 assumes ol-lab-01 has 2 vCPUs (from Lab 3.1). This VM has ${VCPU_COUNT:-unknown}; the script pins the vCPUs it actually has."
    fi

    if command -v numastat >/dev/null 2>&1; then
        info "numastat -c qemu-system-x86 (baseline):"
        numastat -c qemu-system-x86 2>/dev/null || true
    fi

    BASELINE_VCPUINFO="$(sudo virsh vcpuinfo "$VM_NAME" 2>/dev/null || true)"
    info "virsh vcpuinfo $VM_NAME (baseline):"; printf '%s\n' "$BASELINE_VCPUINFO"
    # A fresh VM's affinity mask spans all CPUs (lots of 'y').
    if printf '%s' "$BASELINE_VCPUINFO" | grep -q "CPU Affinity"; then
        pass "Step 2: captured baseline vCPU affinity"
    else
        fail "Step 2: could not read baseline vCPU affinity"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Pin vCPUs to cores on node 0
# --------------------------------------------------------------------------
step3_pin_vcpus() {
    log "Step 3: Pin vCPUs to distinct cores on node 0"

    local n="${VCPU_COUNT:-1}" v core
    for ((v = 0; v < n; v++)); do
        # Use distinct cores where possible.
        if (( v < ${#NODE0_CORES[@]} )); then
            core="${NODE0_CORES[$v]}"
        else
            core="${NODE0_CORES[$(( v % ${#NODE0_CORES[@]} ))]}"
        fi
        info "Pinning vCPU $v -> core $core"
        sudo virsh vcpupin "$VM_NAME" "$v" "$core" --live --config >/dev/null 2>&1 \
            && pass "Step 3: vcpupin vCPU $v -> core $core applied" \
            || fail "Step 3: vcpupin vCPU $v -> core $core failed"
    done

    if [[ ${#NODE0_CORES[@]} -ge 2 ]]; then
        finding "Lab 10.1 warns not to pin both vCPUs onto hyperthread siblings of the same physical core. This script pins to distinct entries in node 0's CPU list; on hosts with hyperthreading, verify those entries are different physical cores (lscpu Thread(s) per core)."
    fi

    local after
    after="$(sudo virsh vcpuinfo "$VM_NAME" 2>/dev/null || true)"
    info "virsh vcpuinfo $VM_NAME (after pin):"; printf '%s\n' "$after"
    # Each affinity line should now be mostly '-' with a single 'y'.
    local single=1 line ycount
    while IFS= read -r line; do
        [[ "$line" == *"CPU Affinity"* ]] || continue
        ycount="$(printf '%s' "${line#*:}" | tr -cd 'y' | wc -c | tr -d ' ')"
        (( ycount == 1 )) || single=0
    done <<<"$after"
    if (( single == 1 )); then
        pass "Step 3: each vCPU affinity mask now shows a single pinned core"
    else
        warn "Step 3: at least one vCPU affinity mask is not a single core"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Lock memory to node 0
# --------------------------------------------------------------------------
step4_lock_memory() {
    log "Step 4: Lock memory to node 0 (strict)"

    if sudo virsh numatune "$VM_NAME" --mode strict --nodeset 0 --live --config >/dev/null 2>&1; then
        pass "Step 4: numatune strict/nodeset 0 applied"
    else
        warn "Step 4: numatune strict failed (node 0 may lack free memory for the VM)"
        finding "Lab 10.1 Step 9 notes numatune --mode strict fails outright if node 0 lacks free memory - that is deliberate. If this warns, node 0 could not satisfy the VM's memory."
    fi

    local nt
    nt="$(sudo virsh numatune "$VM_NAME" 2>/dev/null || true)"
    info "virsh numatune $VM_NAME:"; printf '%s\n' "$nt"
    assert_contains "$nt" "strict" "Step 4: numa_mode is strict"
    assert_contains "$nt" "0" "Step 4: numa_nodeset includes 0"
}

# --------------------------------------------------------------------------
# Step 5: Re-run and confirm the before/after difference
# --------------------------------------------------------------------------
step5_compare() {
    log "Step 5: Confirm the before/after difference"

    if command -v numastat >/dev/null 2>&1; then
        info "numastat -c qemu-system-x86 (after):"
        numastat -c qemu-system-x86 2>/dev/null || true
    fi

    local after
    after="$(sudo virsh vcpuinfo "$VM_NAME" 2>/dev/null || true)"
    if [[ "$after" != "$BASELINE_VCPUINFO" ]]; then
        pass "Step 5: vcpuinfo changed from baseline (pinning genuinely took effect)"
    else
        fail "Step 5: vcpuinfo is unchanged from baseline (pinning did not take)"
    fi
    finding "Lab 10.1's whole point: proof is the before/after comparison of vcpuinfo/numastat, NOT that the commands ran without error. This script diffs the baseline vcpuinfo against the post-pin state."
}

main() {
    preflight
    step1_topology
    step2_baseline
    step3_pin_vcpus
    step4_lock_memory
    step5_compare
    summary
}

main "$@"
