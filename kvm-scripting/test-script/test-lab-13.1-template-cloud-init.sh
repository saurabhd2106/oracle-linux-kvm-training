#!/usr/bin/env bash
#
# test-lab-13.1-template-cloud-init.sh - run and verify Lab 13.1 (Template &
# Deploy with cloud-init) end-to-end on the KVM host.
#
# Copies ol-lab-01's disk into a master template, generalises it with
# virt-sysprep, deploys a fresh app-vm-01 from the template with a NoCloud seed,
# and confirms hostname/SSH/sudo/machine-id all applied automatically. Prints a
# PASS/WARN/FAIL line per lab "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: ol-lab-01 exists; the 'default' NAT network is active.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-13.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
SRC_VM="${SRC_VM:-ol-lab-01}"
NEW_VM="${NEW_VM:-app-vm-01}"
NET_NAME="${NET_NAME:-default}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
MASTER_IMG="${MASTER_IMG:-${IMAGE_DIR}/${SRC_VM}-master.qcow2}"
NEW_DISK="${NEW_DISK:-${IMAGE_DIR}/${NEW_VM}.qcow2}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${NEW_VM}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${NEW_VM}-seed}"
OS_VARIANT="${OS_VARIANT:-ol9.0}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
SRC_DISK=""
preflight() {
    log "Preflight checks"
    require_command virsh
    require_command virt-install
    require_command qemu-img

    sudo virsh dominfo "$SRC_VM" >/dev/null 2>&1 \
        && pass "Preflight: source VM $SRC_VM is defined" \
        || die "$SRC_VM not found."

    SRC_DISK="$(sudo virsh domblklist "$SRC_VM" 2>/dev/null | awk '$1=="vda"{print $2; exit}')"
    [[ -z "$SRC_DISK" ]] && SRC_DISK="$(sudo virsh domblklist "$SRC_VM" 2>/dev/null | awk 'NR>2 && $2 ~ /\.qcow2$/ {print $2; exit}')"
    [[ -n "$SRC_DISK" ]] || die "could not determine $SRC_VM's disk path"
    info "Source disk: $SRC_DISK"

    if ! command -v virt-sysprep >/dev/null 2>&1; then
        info "Installing libguestfs-tools-c (provides virt-sysprep/virt-cat)"
        sudo dnf install -y libguestfs-tools-c >/dev/null 2>&1 || true
    fi
    command -v virt-sysprep >/dev/null 2>&1 || die "virt-sysprep not available"

    sudo virsh net-list --all 2>/dev/null | awk -v n="$NET_NAME" '$1==n' | grep -q active \
        && pass "Preflight: network '$NET_NAME' is active" \
        || { sudo virsh net-start "$NET_NAME" >/dev/null 2>&1 || true; }

    [[ -f "${SSH_KEY}.pub" ]] || { require_command ssh-keygen; ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""; }
    ensure_iso_tool || die "xorriso not available to build the seed ISO"
}

# --------------------------------------------------------------------------
# Step 1: Shut down a copy of ol-lab-01 to use as the master
# --------------------------------------------------------------------------
step1_copy_master() {
    log "Step 1: Copy $SRC_VM's disk into the master template"

    if sudo test -f "$MASTER_IMG"; then
        info "Master image already exists ($MASTER_IMG); reusing"
        pass "Step 1: master template present"
        return
    fi

    info "Shutting $SRC_VM down so its disk can be copied cleanly"
    shutdown_vm "$SRC_VM" 24
    sudo cp "$SRC_DISK" "$MASTER_IMG"
    sudo test -f "$MASTER_IMG" && pass "Step 1: master template created ($MASTER_IMG)" \
        || fail "Step 1: master template copy failed"

    info "Starting $SRC_VM back up (the copy is all the lab needs from here)"
    sudo virsh start "$SRC_VM" >/dev/null 2>&1 || true
    wait_for_state "$SRC_VM" running 12 || true
}

# --------------------------------------------------------------------------
# Step 2: Generalise the master with virt-sysprep
# --------------------------------------------------------------------------
step2_sysprep() {
    log "Step 2: Generalise the master with virt-sysprep"

    if sudo virt-sysprep -a "$MASTER_IMG" >/dev/null 2>&1; then
        pass "Step 2: virt-sysprep completed"
    else
        warn "Step 2: virt-sysprep failed; retrying with LIBGUESTFS_BACKEND=direct"
        finding "virt-sysprep failed with the default libvirt backend (common under nested virtualisation). LIBGUESTFS_BACKEND=direct is the documented workaround and was used here."
        if sudo LIBGUESTFS_BACKEND=direct virt-sysprep -a "$MASTER_IMG" >/dev/null 2>&1; then
            pass "Step 2: virt-sysprep completed with LIBGUESTFS_BACKEND=direct"
        else
            fail "Step 2: virt-sysprep failed even with LIBGUESTFS_BACKEND=direct"
            return
        fi
    fi

    local mid
    mid="$(sudo virt-cat -a "$MASTER_IMG" /etc/machine-id 2>/dev/null || true)"
    mid="$(printf '%s' "$mid" | tr -d '[:space:]')"
    if [[ -z "$mid" ]]; then
        pass "Step 2: template /etc/machine-id is empty/absent (each deployment gets a fresh one)"
    else
        warn "Step 2: template /etc/machine-id still populated ($mid)"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Launch a new VM from the template
# --------------------------------------------------------------------------
step3_deploy() {
    log "Step 3: Deploy $NEW_VM from the template"

    if sudo virsh dominfo "$NEW_VM" >/dev/null 2>&1; then
        info "$NEW_VM already exists; skipping deploy"
        pass "Step 3: $NEW_VM already deployed"
        return
    fi

    sudo cp "$MASTER_IMG" "$NEW_DISK"

    mkdir -p "$SEED_DIR"
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ${NEW_VM}-v1
local-hostname: ${NEW_VM}
EOF
    cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${SSH_KEY}.pub")
runcmd:
  - nmcli connection reload
  - nmcli connection up eth0
EOF
    rm -f "$SEED_DIR/network-config"
    finding "Lab 13.1's seed omits network-config on purpose so cloud-init falls back to DHCP on the default NAT network; this script does the same."

    build_seed_iso "$SEED_ISO" >/dev/null 2>&1 && pass "Step 3: seed ISO built ($SEED_ISO)" \
        || fail "Step 3: seed ISO build failed"

    finding "Lab 13.1 uses --graphics vnc,listen=0.0.0.0. Prefer listen=127.0.0.1 (used here) to avoid exposing VNC on all interfaces."
    sudo virt-install \
        --name "$NEW_VM" \
        --memory 1024 --vcpus 1 \
        --disk "path=${NEW_DISK},format=qcow2" \
        --disk "path=${SEED_ISO},device=cdrom" \
        --import \
        --os-variant "$OS_VARIANT" \
        --network "network=${NET_NAME}" \
        --graphics vnc,listen=127.0.0.1 \
        --noautoconsole

    wait_for_state "$NEW_VM" running 12 || true
    [[ "$(sudo virsh domstate "$NEW_VM" 2>/dev/null)" == "running" ]] \
        && pass "Step 3: $NEW_VM is running" \
        || fail "Step 3: $NEW_VM is not running"
}

# --------------------------------------------------------------------------
# Step 4: Confirm hostname, user, key, and a distinct machine-id
# --------------------------------------------------------------------------
step4_confirm() {
    log "Step 4: Confirm identity applied automatically (no manual login)"

    VM_NAME="$NEW_VM"
    local addr
    if ! addr="$(wait_for_vm_addr lease 30)"; then addr="$(vm_addr_any "$NEW_VM" || true)"; fi
    if [[ -z "$addr" ]]; then
        fail "Step 4: could not determine $NEW_VM's address"
        return
    fi
    info "$NEW_VM address: $addr"

    local ident
    ident="$(vm_ssh_retry "$addr" 'hostname; whoami; sudo whoami' 24 || true)"
    info "hostname/whoami/sudo whoami:"; printf '%s\n' "$ident"
    assert_contains "$ident" "$NEW_VM" "Step 4: hostname is $NEW_VM (from meta-data)"
    assert_contains "$ident" "root" "Step 4: default user has working sudo (sudo whoami = root)"

    local new_mid
    new_mid="$(vm_ssh "$addr" 'cat /etc/machine-id' || true)"
    new_mid="$(printf '%s' "$new_mid" | tr -d '[:space:]')"
    info "$NEW_VM machine-id: ${new_mid:-unknown}"
    [[ -n "$new_mid" ]] && pass "Step 4: $NEW_VM generated its own machine-id on first boot" \
        || warn "Step 4: could not read $NEW_VM machine-id"

    # Compare against the source VM if it is reachable.
    local src_addr src_mid
    src_addr="$(VM_NAME="$SRC_VM"; vm_addr_any "$SRC_VM" || true)"
    if [[ -n "$src_addr" ]] && src_mid="$(vm_ssh "$src_addr" 'cat /etc/machine-id' || true)" && [[ -n "$src_mid" ]]; then
        src_mid="$(printf '%s' "$src_mid" | tr -d '[:space:]')"
        info "$SRC_VM machine-id: $src_mid"
        if [[ -n "$new_mid" && "$new_mid" != "$src_mid" ]]; then
            pass "Step 4: $NEW_VM machine-id differs from $SRC_VM (genuinely distinct machine)"
        else
            fail "Step 4: $NEW_VM machine-id matches $SRC_VM (clone, not a fresh identity)"
        fi
    else
        warn "Step 4: $SRC_VM not reachable to compare machine-id (bridged guests may be unreachable on OCI); $NEW_VM still shows its own id"
    fi
}

main() {
    preflight
    step1_copy_master
    step2_sysprep
    step3_deploy
    step4_confirm
    summary
}

main "$@"
