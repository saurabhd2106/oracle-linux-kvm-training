#!/usr/bin/env bash
#
# test-lab-5.1-storage-pools.sh - run and verify Lab 5.1 (Storage Pools &
# Additional Disks) end-to-end against a running ol-lab-01.
#
# Confirms the pre-provisioned data volume, builds the 'labpool' directory pool
# on it, creates a 10G qcow2 volume, attaches it live as vdb, partitions/formats/
# mounts it inside the guest at /data, then compares qcow2 vs raw creation and
# cleans up the comparison volumes. Prints a PASS/WARN/FAIL line per lab
# "Expected result" and a FINDINGS block at the end.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user. Uses sudo for
# virsh exactly as the lab does, and SSHes into the guest for the in-guest steps.
#
# PREREQUISITES: ol-lab-01 exists and is running (Lab 3.1/4.1), reachable over
# SSH, and the Day-1 secondary data disk is mounted (default /mnt/data).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-5.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config (override via environment if needed)
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
POOL_NAME="${POOL_NAME:-labpool}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"
VOL_NAME="${VOL_NAME:-data-disk.qcow2}"
VOL_SIZE="${VOL_SIZE:-10G}"
TARGET_DEV="${TARGET_DEV:-vdb}"
GUEST_MOUNT="${GUEST_MOUNT:-/data}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command virsh
    require_command qemu-img
    require_command awk

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
    state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
    [[ "$state" == "running" ]] && pass "Preflight: $VM_NAME is running" \
        || die "$VM_NAME is not running (state: $state)"

    # The lab uses 'ssh root@'; the cloud-init key lands on cloud-user/opc.
    finding "Lab 5.1 Step 12 uses 'ssh root@<addr>', but the cloud image delivers the SSH key to the default user (cloud-user/opc), not root. This script tries cloud-user/opc/root in order."
}

# --------------------------------------------------------------------------
# Step 1: Confirm the pre-provisioned data volume
# --------------------------------------------------------------------------
step1_confirm_data_volume() {
    log "Step 1: Confirm the pre-provisioned data volume at $DATA_MOUNT"

    local src fstype size
    if src="$(findmnt -rn -o SOURCE --target "$DATA_MOUNT" 2>/dev/null)" \
        && [[ "$(findmnt -rn -o TARGET --target "$DATA_MOUNT" 2>/dev/null)" == "$DATA_MOUNT" ]]; then
        fstype="$(findmnt -rn -o FSTYPE --target "$DATA_MOUNT" 2>/dev/null || true)"
        size="$(findmnt -rn -o SIZE --target "$DATA_MOUNT" 2>/dev/null || true)"
        pass "Step 1: $DATA_MOUNT is a mount point (source=$src fstype=$fstype size=$size)"
        info "This is the dedicated secondary disk prepared during the Day-1 Linux lab."
        finding "Lab 5.1 hardcodes /dev/sdb in Step 3 ('sudo lsblk /dev/sdb'); the actual device varies. This script detects the mount source ($src) via findmnt instead of assuming a device name."
    else
        warn "Step 1: $DATA_MOUNT is not a separate mount point; the Day-1 secondary disk may not be attached/mounted"
        finding "Lab 5.1 assumes /mnt/data is a mounted ~50G secondary disk from the Day-1 lab. It was not mounted here, so the pool would land on the boot volume - the exact situation the lab warns against. Provision/mount the secondary disk before this lab."
        info "Creating $DATA_MOUNT as a plain directory so the rest of the lab can still be exercised (degraded)."
        sudo mkdir -p "$DATA_MOUNT"
    fi
}

# --------------------------------------------------------------------------
# Step 2: Create the storage pool on the dedicated disk
# --------------------------------------------------------------------------
step2_create_pool() {
    log "Step 2: Create the '$POOL_NAME' directory pool on $DATA_MOUNT"

    if sudo virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
        info "Pool '$POOL_NAME' already exists; ensuring it is started/autostart"
    else
        sudo virsh pool-define-as "$POOL_NAME" dir --target "$DATA_MOUNT" >/dev/null
        sudo virsh pool-build "$POOL_NAME" >/dev/null 2>&1 || true
    fi
    sudo virsh pool-start "$POOL_NAME" >/dev/null 2>&1 || true
    sudo virsh pool-autostart "$POOL_NAME" >/dev/null 2>&1 || true

    local details
    details="$(sudo virsh pool-list --all --details 2>/dev/null || true)"
    info "virsh pool-list --all --details:"
    printf '%s\n' "$details"

    if printf '%s' "$details" | awk -v p="$POOL_NAME" '$1==p' | grep -q "running"; then
        pass "Step 2: pool '$POOL_NAME' is active (running)"
    else
        fail "Step 2: pool '$POOL_NAME' is not active"
    fi
    if printf '%s' "$details" | awk -v p="$POOL_NAME" '$1==p' | grep -qi "yes"; then
        pass "Step 2: pool '$POOL_NAME' is autostart"
    else
        fail "Step 2: pool '$POOL_NAME' is not autostart"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Create a 10 GB qcow2 volume
# --------------------------------------------------------------------------
step3_create_volume() {
    log "Step 3: Create a $VOL_SIZE qcow2 volume '$VOL_NAME' in '$POOL_NAME'"

    if sudo virsh vol-info --pool "$POOL_NAME" "$VOL_NAME" >/dev/null 2>&1; then
        info "Volume '$VOL_NAME' already exists; reusing"
    else
        sudo virsh vol-create-as "$POOL_NAME" "$VOL_NAME" "$VOL_SIZE" --format qcow2 >/dev/null
    fi

    local vollist volpath imginfo
    vollist="$(sudo virsh vol-list "$POOL_NAME" 2>/dev/null || true)"
    assert_contains "$vollist" "$VOL_NAME" "Step 3: '$VOL_NAME' listed in pool '$POOL_NAME'"

    volpath="$(sudo virsh vol-path --pool "$POOL_NAME" "$VOL_NAME" 2>/dev/null || echo "${DATA_MOUNT}/${VOL_NAME}")"
    imginfo="$(sudo qemu-img info "$volpath" 2>/dev/null || true)"
    info "qemu-img info $volpath:"
    printf '%s\n' "$imginfo"
    assert_contains "$imginfo" "10 GiB" "Step 3: virtual size is 10 GiB"
    # qcow2 does not pre-allocate: disk size should be far under the virtual size.
    if printf '%s' "$imginfo" | grep -q "format: qcow2"; then
        pass "Step 3: volume format is qcow2 (thin-provisioned)"
    else
        fail "Step 3: volume format is not qcow2"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Attach the volume to the running VM
# --------------------------------------------------------------------------
step4_attach_disk() {
    log "Step 4: Attach '$VOL_NAME' to $VM_NAME as $TARGET_DEV (live + config)"

    local volpath domblk
    volpath="$(sudo virsh vol-path --pool "$POOL_NAME" "$VOL_NAME" 2>/dev/null || echo "${DATA_MOUNT}/${VOL_NAME}")"

    domblk="$(sudo virsh domblklist "$VM_NAME" 2>/dev/null || true)"
    if printf '%s' "$domblk" | awk '{print $1}' | grep -qx "$TARGET_DEV"; then
        info "$TARGET_DEV already attached; skipping attach-disk"
    else
        sudo virsh attach-disk "$VM_NAME" "$volpath" "$TARGET_DEV" \
            --subdriver qcow2 --targetbus virtio --live --config
    fi

    domblk="$(sudo virsh domblklist "$VM_NAME" 2>/dev/null || true)"
    info "virsh domblklist $VM_NAME:"
    printf '%s\n' "$domblk"
    assert_contains "$domblk" "vda" "Step 4: original disk (vda) still listed"
    assert_contains "$domblk" "$TARGET_DEV" "Step 4: new disk ($TARGET_DEV) listed"
    assert_contains "$domblk" "$VOL_NAME" "Step 4: $TARGET_DEV points at $VOL_NAME"
}

# --------------------------------------------------------------------------
# Step 5: Partition, format, and mount the new disk inside the guest
# --------------------------------------------------------------------------
step5_guest_filesystem() {
    log "Step 5: Partition/format/mount $TARGET_DEV inside the guest at $GUEST_MOUNT"

    local addr
    if ! addr="$(wait_for_vm_addr lease 24)"; then
        addr="$(vm_addr_any "$VM_NAME" || true)"
    fi
    if [[ -z "$addr" ]]; then
        warn "Step 5: could not determine $VM_NAME's address; skipping in-guest steps"
        finding "Lab 5.1 Steps 12-17 (in-guest partition/format/mount) require guest network reachability; on OCI the bridged guest may need the Lab 4.1 Option 1/2 setup to be reachable from the host."
        return
    fi
    info "Guest address: $addr"

    if ! vm_ssh_ok "$addr"; then
        warn "Step 5: guest at $addr is not answering SSH; skipping in-guest steps"
        return
    fi

    local lsblk_out
    lsblk_out="$(vm_ssh "$addr" 'lsblk' || true)"
    info "guest lsblk:"
    printf '%s\n' "$lsblk_out"
    assert_contains "$lsblk_out" "$TARGET_DEV" "Step 5: new disk ($TARGET_DEV) visible inside the guest"

    # Idempotent: only partition/format if the partition is absent.
    if printf '%s' "$lsblk_out" | grep -q "${TARGET_DEV}1"; then
        info "${TARGET_DEV}1 already exists inside the guest; skipping parted/mkfs"
    else
        info "Creating GPT partition + ext4 filesystem on /dev/$TARGET_DEV"
        vm_ssh "$addr" "sudo parted /dev/$TARGET_DEV --script mklabel gpt mkpart data ext4 0% 100%" >/dev/null 2>&1 || true
        sleep 2
        vm_ssh "$addr" "sudo mkfs.ext4 -F /dev/${TARGET_DEV}1" >/dev/null 2>&1 || true
    fi

    finding "Lab 5.1 Step 14 uses 'mkpart primary ext4' - 'primary' is MBR terminology and is ignored on a GPT label; a partition name like 'mkpart data ext4 0% 100%' is clearer on GPT. This script uses a GPT partition name."

    vm_ssh "$addr" "sudo mkdir -p $GUEST_MOUNT && (mountpoint -q $GUEST_MOUNT || sudo mount /dev/${TARGET_DEV}1 $GUEST_MOUNT)" >/dev/null 2>&1 || true
    vm_ssh "$addr" "sudo touch $GUEST_MOUNT/test-file" >/dev/null 2>&1 || true

    local df_out ls_out
    df_out="$(vm_ssh "$addr" "df -h $GUEST_MOUNT" || true)"
    ls_out="$(vm_ssh "$addr" "ls -l $GUEST_MOUNT/test-file" || true)"
    info "guest df -h $GUEST_MOUNT:"; printf '%s\n' "$df_out"
    if printf '%s' "$df_out" | grep -q "$GUEST_MOUNT"; then
        pass "Step 5: $GUEST_MOUNT is mounted inside the guest"
    else
        fail "Step 5: $GUEST_MOUNT is not mounted inside the guest"
    fi
    assert_contains "$ls_out" "test-file" "Step 5: test-file created on $GUEST_MOUNT (disk is usable)"

    finding "Lab 5.1 Step 17 mount is deliberately not persistent (no /etc/fstab entry); it will not survive a guest reboot. The lab notes this on purpose."
}

# --------------------------------------------------------------------------
# Step 6: Compare qcow2 and raw volume creation
# --------------------------------------------------------------------------
step6_compare_formats() {
    log "Step 6: Compare qcow2 vs raw volume creation in '$POOL_NAME'"

    sudo virsh vol-delete compare-test.qcow2 --pool "$POOL_NAME" >/dev/null 2>&1 || true
    sudo virsh vol-delete compare-test.raw --pool "$POOL_NAME" >/dev/null 2>&1 || true

    info "Timing qcow2 creation:"
    time sudo virsh vol-create-as "$POOL_NAME" compare-test.qcow2 "$VOL_SIZE" --format qcow2 >/dev/null || true
    info "Timing raw creation:"
    time sudo virsh vol-create-as "$POOL_NAME" compare-test.raw "$VOL_SIZE" --format raw >/dev/null || true

    local qpath rpath qinfo rinfo
    qpath="$(sudo virsh vol-path --pool "$POOL_NAME" compare-test.qcow2 2>/dev/null || echo "${DATA_MOUNT}/compare-test.qcow2")"
    rpath="$(sudo virsh vol-path --pool "$POOL_NAME" compare-test.raw 2>/dev/null || echo "${DATA_MOUNT}/compare-test.raw")"
    qinfo="$(sudo qemu-img info "$qpath" 2>/dev/null || true)"
    rinfo="$(sudo qemu-img info "$rpath" 2>/dev/null || true)"
    info "qcow2 info:"; printf '%s\n' "$qinfo"
    info "raw info:";   printf '%s\n' "$rinfo"
    assert_contains "$qinfo" "10 GiB" "Step 6: qcow2 compare volume virtual size is 10 GiB"
    assert_contains "$rinfo" "10 GiB" "Step 6: raw compare volume virtual size is 10 GiB"

    info "Cleaning up the comparison volumes"
    sudo virsh vol-delete compare-test.qcow2 --pool "$POOL_NAME" >/dev/null 2>&1 || true
    sudo virsh vol-delete compare-test.raw --pool "$POOL_NAME" >/dev/null 2>&1 || true
    local vollist
    vollist="$(sudo virsh vol-list "$POOL_NAME" 2>/dev/null || true)"
    assert_not_contains "$vollist" "compare-test.qcow2" "Step 6: qcow2 compare volume deleted"
    assert_not_contains "$vollist" "compare-test.raw" "Step 6: raw compare volume deleted"
}

main() {
    preflight
    step1_confirm_data_volume
    step2_create_pool
    step3_create_volume
    step4_attach_disk
    step5_guest_filesystem
    step6_compare_formats
    summary
}

main "$@"
