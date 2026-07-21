#!/usr/bin/env bash
#
# test-lab-9.1-consolidation.sh - run and verify Lab 9.1 (Consolidation Lab:
# build a 2-VM environment from scratch) end-to-end on the KVM host.
#
# Builds app-vm and db-vm on a dedicated pool and the bridged network, snapshots
# both, attaches a second data disk to db-vm, then runs the fault-and-restore
# cycle and documents the final state. Prints a PASS/WARN/FAIL line per lab
# "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# DIFFERENCES FROM THE LAB (see FINDINGS at the end for detail):
#   - The lab installs each VM interactively from a DVD ISO via virt-viewer. That
#     is slow and needs a GUI console; this script deploys from the OL9 cloud
#     image + a NoCloud seed ISO (the same method Labs 3.1/4.1 use), so it runs
#     unattended.
#   - The lab points consolidation-pool at /var/lib/libvirt/images (the boot
#     volume), which contradicts Lab 5.1's warning about limited boot-volume
#     space; this script defaults the pool to the dedicated data disk.
#   - The core lesson (a snapshot does not protect a disk attached AFTER it was
#     taken) is verified host-side with domblklist, so it holds even when the
#     bridged guests are not reachable on OCI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-9.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
APP_VM="${APP_VM:-app-vm}"
DB_VM="${DB_VM:-db-vm}"
POOL_NAME="${POOL_NAME:-consolidation-pool}"
POOL_TARGET="${POOL_TARGET:-/mnt/data/consolidation-pool}"
NET_NAME="${NET_NAME:-br0-network}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE="${BASE_IMAGE:-${IMAGE_DIR}/OL9-base.qcow2}"
OL9_IMAGE_URL="${OL9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u4/x86_64/OL9U4_x86_64-kvm-b234.qcow2}"
OS_VARIANT="${OS_VARIANT:-ol9.0}"
DB_DATA_VOL="${DB_DATA_VOL:-db-vm-data.qcow2}"
DB_DATA_SIZE="${DB_DATA_SIZE:-5G}"
DISK_SIZE="${DISK_SIZE:-15G}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command virsh
    require_command virt-install
    require_command qemu-img

    systemctl is-active libvirtd >/dev/null 2>&1 \
        && pass "Preflight: libvirtd is active" \
        || warn "Preflight: libvirtd not reported active (continuing; virsh may use a different unit)"

    local netlist
    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    if printf '%s' "$netlist" | awk -v n="$NET_NAME" '$1==n' | grep -q active; then
        pass "Preflight: bridged network '$NET_NAME' is active"
    else
        warn "Preflight: '$NET_NAME' not active; falling back to 'default' NAT for the build"
        finding "Lab 9.1 requires the bridged network '$NET_NAME' from Lab 4.1 to be active. It was not; the VMs were placed on 'default' NAT instead. Run Lab 4.1 first for the intended bridged topology."
        NET_NAME="default"
    fi

    ensure_iso_tool || die "xorriso not available to build seed ISOs"

    if [[ ! -f "${SSH_KEY}.pub" ]]; then
        require_command ssh-keygen
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
    fi

    if ! sudo test -f "$BASE_IMAGE"; then
        info "Base cloud image missing; downloading from $OL9_IMAGE_URL"
        require_command curl
        sudo curl -L -o "$BASE_IMAGE" "$OL9_IMAGE_URL"
    fi
    sudo test -f "$BASE_IMAGE" && pass "Preflight: base cloud image present ($BASE_IMAGE)" \
        || die "base image missing ($BASE_IMAGE)"

    finding "Lab 9.1 Steps 5-7 install each VM from a DVD ISO via virt-viewer (interactive, GUI, slow). This script deploys from the OL9 cloud image + NoCloud seed - unattended and consistent with Labs 3.1/4.1."
    finding "Lab 9.1 sets --graphics vnc,listen=0.0.0.0, exposing VNC on all interfaces. Prefer listen=127.0.0.1 (this script uses that) and tunnel if remote console access is needed."
}

# --------------------------------------------------------------------------
# Step 1: Create the dedicated storage pool
# --------------------------------------------------------------------------
step1_create_pool() {
    log "Step 1: Create the '$POOL_NAME' pool at $POOL_TARGET"

    if [[ "$POOL_TARGET" == /var/lib/libvirt/images/* ]]; then
        finding "Lab 9.1 points consolidation-pool at /var/lib/libvirt/images (the boot volume), contradicting Lab 5.1's boot-volume space warning. Prefer a target on the dedicated data disk (default here: /mnt/data/consolidation-pool)."
    fi

    sudo mkdir -p "$POOL_TARGET"
    if sudo virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
        info "Pool '$POOL_NAME' already exists; ensuring started/autostart"
    else
        sudo virsh pool-define-as "$POOL_NAME" dir --target "$POOL_TARGET" >/dev/null
        sudo virsh pool-build "$POOL_NAME" >/dev/null 2>&1 || true
    fi
    sudo virsh pool-start "$POOL_NAME" >/dev/null 2>&1 || true
    sudo virsh pool-autostart "$POOL_NAME" >/dev/null 2>&1 || true

    local pools
    pools="$(sudo virsh pool-list --all 2>/dev/null || true)"
    info "virsh pool-list --all:"; printf '%s\n' "$pools"
    if printf '%s' "$pools" | awk -v p="$POOL_NAME" '$1==p' | grep -q active; then
        pass "Step 1: pool '$POOL_NAME' is active"
    else
        fail "Step 1: pool '$POOL_NAME' is not active"
    fi
}

# --------------------------------------------------------------------------
# Helper: build one cloud-image VM with a DHCP seed
# --------------------------------------------------------------------------
build_vm() {
    local vm="$1" disk="${POOL_TARGET}/${vm}.qcow2" seed_dir="${HOME}/${vm}-seed"
    local seed_iso="${POOL_TARGET}/${vm}-seed.iso"

    if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
        info "$vm already defined; skipping build"
        return 0
    fi

    info "Creating disk for $vm from the cloud image"
    sudo cp -f "$BASE_IMAGE" "$disk"
    sudo qemu-img resize "$disk" "$DISK_SIZE" >/dev/null 2>&1 || true

    mkdir -p "$seed_dir"
    cat > "$seed_dir/meta-data" <<EOF
instance-id: ${vm}-v1
local-hostname: ${vm}
EOF
    cat > "$seed_dir/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${SSH_KEY}.pub")
EOF
    rm -f "$seed_dir/network-config"  # no network-config: cloud-init uses DHCP
    SEED_DIR="$seed_dir" build_seed_iso "$seed_iso" >/dev/null 2>&1 || true

    info "virt-install $vm on network=$NET_NAME"
    sudo virt-install \
        --name "$vm" \
        --memory 1024 --vcpus 1 \
        --disk "path=${disk},format=qcow2" \
        --disk "path=${seed_iso},device=cdrom" \
        --import \
        --os-variant "$OS_VARIANT" \
        --network "network=${NET_NAME}" \
        --graphics vnc,listen=127.0.0.1 \
        --noautoconsole
}

# --------------------------------------------------------------------------
# Step 2/3: Create both VMs and confirm they are up
# --------------------------------------------------------------------------
step2_create_vms() {
    log "Step 2/3: Create $APP_VM and $DB_VM and confirm they are running"

    build_vm "$APP_VM"
    build_vm "$DB_VM"

    local vm
    for vm in "$APP_VM" "$DB_VM"; do
        wait_for_state "$vm" running 12 || true
        [[ "$(sudo virsh domstate "$vm" 2>/dev/null)" == "running" ]] \
            && pass "Step 3: $vm is running" \
            || fail "Step 3: $vm is not running"
    done
}

# --------------------------------------------------------------------------
# Step 4: Take baseline snapshots of both VMs (BEFORE the data disk)
# --------------------------------------------------------------------------
step4_baseline_snapshots() {
    log "Step 4: Take baseline snapshots of both VMs"

    local vm
    for vm in "$APP_VM" "$DB_VM"; do
        sudo virsh snapshot-delete "$vm" baseline >/dev/null 2>&1 || true
        if sudo virsh snapshot-create-as "$vm" baseline "Base OS install confirmed" >/dev/null 2>&1; then
            pass "Step 4: baseline snapshot created for $vm"
        else
            fail "Step 4: baseline snapshot failed for $vm"
        fi
        local snaps
        snaps="$(sudo virsh snapshot-list "$vm" 2>/dev/null || true)"
        assert_contains "$snaps" "baseline" "Step 4: $vm shows a 'baseline' snapshot"
    done
}

# --------------------------------------------------------------------------
# Step 5: Attach a second data disk to db-vm (AFTER the baseline snapshot)
# --------------------------------------------------------------------------
step5_attach_data_disk() {
    log "Step 5: Attach a $DB_DATA_SIZE data disk to $DB_VM"

    if ! sudo virsh vol-info --pool "$POOL_NAME" "$DB_DATA_VOL" >/dev/null 2>&1; then
        sudo virsh vol-create-as "$POOL_NAME" "$DB_DATA_VOL" "$DB_DATA_SIZE" --format qcow2 >/dev/null
    fi
    local volpath
    volpath="$(sudo virsh vol-path --pool "$POOL_NAME" "$DB_DATA_VOL" 2>/dev/null || echo "${POOL_TARGET}/${DB_DATA_VOL}")"

    if sudo virsh domblklist "$DB_VM" 2>/dev/null | awk '{print $1}' | grep -qx vdb; then
        info "vdb already attached to $DB_VM"
    else
        sudo virsh attach-disk "$DB_VM" "$volpath" vdb \
            --subdriver qcow2 --targetbus virtio --live --config
    fi

    local domblk
    domblk="$(sudo virsh domblklist "$DB_VM" 2>/dev/null || true)"
    info "virsh domblklist $DB_VM:"; printf '%s\n' "$domblk"
    assert_contains "$domblk" "$DB_DATA_VOL" "Step 5: $DB_VM has the data disk ($DB_DATA_VOL) attached"

    # Best-effort in-guest format + marker (needs reachability).
    local addr
    if ! addr="$(wait_for_vm_addr lease 12)"; then addr="$(vm_addr_any "$DB_VM" || true)"; fi
    if [[ -n "$addr" ]] && vm_ssh_ok "$addr"; then
        vm_ssh "$addr" 'sudo parted /dev/vdb --script mklabel gpt mkpart data ext4 0% 100%' >/dev/null 2>&1 || true
        sleep 2
        vm_ssh "$addr" 'sudo mkfs.ext4 -F /dev/vdb1' >/dev/null 2>&1 || true
        vm_ssh "$addr" 'sudo mkdir -p /data && sudo mount /dev/vdb1 /data && sudo touch /data/consolidation-lab-marker' >/dev/null 2>&1 || true
        local mk
        mk="$(vm_ssh "$addr" 'ls -l /data/consolidation-lab-marker' || true)"
        assert_contains "$mk" "consolidation-lab-marker" "Step 5: data marker created inside $DB_VM"
    else
        warn "Step 5: $DB_VM not reachable over SSH; skipped in-guest format/marker (bridged guests may be unreachable on OCI)"
    fi
}

# --------------------------------------------------------------------------
# Step 6: Fault on db-vm, then restore - and observe disk protection limits
# --------------------------------------------------------------------------
step6_fault_restore() {
    log "Step 6: Fault $DB_VM, revert to baseline, and check disk protection"

    local addr
    if ! addr="$(wait_for_vm_addr lease 12)"; then addr="$(vm_addr_any "$DB_VM" || true)"; fi
    if [[ -n "$addr" ]] && vm_ssh_ok "$addr"; then
        vm_ssh "$addr" 'sudo nohup sh -c "systemctl disable sshd; systemctl stop sshd" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
        sleep 15
        vm_ssh_ok "$addr" && warn "Step 6: sshd still up after disable attempt" \
            || pass "Step 6: fault confirmed ($DB_VM SSH refused)"
    else
        warn "Step 6: $DB_VM not reachable; demonstrating the snapshot/disk lesson host-side only"
    fi

    info "Reverting $DB_VM to its baseline snapshot (taken before the data disk)"
    sudo virsh snapshot-revert "$DB_VM" baseline >/dev/null 2>&1 \
        && pass "Step 6: reverted $DB_VM to baseline" \
        || fail "Step 6: revert failed"

    # The core lesson: baseline predates the data disk, so the revert rolls back
    # the device config too - vdb should be gone.
    local domblk
    domblk="$(sudo virsh domblklist "$DB_VM" 2>/dev/null || true)"
    info "virsh domblklist $DB_VM (after revert):"; printf '%s\n' "$domblk"
    if printf '%s' "$domblk" | grep -qF "$DB_DATA_VOL"; then
        warn "Step 6: data disk still present after revert (snapshot metadata may have retained it)"
    else
        pass "Step 6: data disk is GONE after revert - snapshots only protect what existed when taken"
        finding "Lab 9.1's key lesson confirmed: reverting to a snapshot taken before a disk was attached removes that disk from the VM. Snapshots protect only the state captured at snapshot time; later-added disks need their own snapshot/backup."
    fi

    # Step 15: reattach the data disk (the volume still exists in the pool).
    local volpath
    volpath="$(sudo virsh vol-path --pool "$POOL_NAME" "$DB_DATA_VOL" 2>/dev/null || echo "${POOL_TARGET}/${DB_DATA_VOL}")"
    if ! printf '%s' "$domblk" | grep -qF "$DB_DATA_VOL"; then
        sudo virsh attach-disk "$DB_VM" "$volpath" vdb \
            --subdriver qcow2 --targetbus virtio --live --config >/dev/null 2>&1 || true
        domblk="$(sudo virsh domblklist "$DB_VM" 2>/dev/null || true)"
        assert_contains "$domblk" "$DB_DATA_VOL" "Step 6: data disk reattached to $DB_VM"
    fi
}

# --------------------------------------------------------------------------
# Step 7: Document the final state
# --------------------------------------------------------------------------
step7_document() {
    log "Step 7: Document the final state"

    local vmlist netlist pools
    vmlist="$(sudo virsh list --all 2>/dev/null || true)"
    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    pools="$(sudo virsh pool-list --all 2>/dev/null || true)"
    info "virsh list --all:"; printf '%s\n' "$vmlist"
    info "virsh net-list --all:"; printf '%s\n' "$netlist"
    info "virsh pool-list --all:"; printf '%s\n' "$pools"
    info "$APP_VM snapshots:"; sudo virsh snapshot-list "$APP_VM" --tree 2>/dev/null || true
    info "$DB_VM snapshots:"; sudo virsh snapshot-list "$DB_VM" --tree 2>/dev/null || true

    assert_contains "$vmlist" "$APP_VM" "Step 7: $APP_VM present in final state"
    assert_contains "$vmlist" "$DB_VM" "Step 7: $DB_VM present in final state"
    assert_contains "$pools" "$POOL_NAME" "Step 7: $POOL_NAME present in final state"
}

main() {
    preflight
    step1_create_pool
    step2_create_vms
    step4_baseline_snapshots
    step5_attach_data_disk
    step6_fault_restore
    step7_document
    summary
}

main "$@"
