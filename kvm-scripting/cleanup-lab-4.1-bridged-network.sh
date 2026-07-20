#!/usr/bin/env bash
#
# cleanup-lab-4.1-bridged-network.sh - tear down everything Lab 4.1 created and
# return the KVM host to a clean slate.
#
# Removes ol-lab-01 (definition + storage) and its seed artifacts, removes the
# br0-network libvirt network, deletes the br0 bridge and its port, and restores
# the physical NIC to plain DHCP. Every step is best-effort so the script is safe
# to re-run (a partially cleaned host still ends clean).
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user. Uses sudo for
# nmcli/virsh exactly as the lab does.
#
# WARNING: deleting the bridge and restoring the physical NIC re-homes the host's
# IP and can briefly drop SSH. Run this from the OCI serial console, not from the
# SSH session that rides over the NIC being restored.

set -euo pipefail

# --------------------------------------------------------------------------
# Config (override via environment if needed; keep in sync with the test script)
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
BRIDGE="${BRIDGE:-br0}"
BRIDGE_PORT="${BRIDGE_PORT:-br0-port1}"
NET_NAME="${NET_NAME:-br0-network}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${VM_NAME}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${VM_NAME}-seed}"

# --------------------------------------------------------------------------
# Logging / checks
# --------------------------------------------------------------------------
NAME="cleanup-lab-4.1"
PASS_COUNT=0
FAIL_COUNT=0

log()  { printf '\n[%s] ==> %s\n' "$NAME" "$*"; }
info() { printf '[%s]     %s\n' "$NAME" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[%s] OK:   %s\n' "$NAME" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[%s] LEFT: %s\n' "$NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Detect the physical uplink NIC. After the bridge exists, the default route is
# via br0, so also look for the device enslaved to the bridge.
detect_phys_nic() {
    local nic
    nic="$(ip -o link show 2>/dev/null | awk -v br="$BRIDGE" '$0 ~ ("master " br) {sub(/@.*/, "", $2); gsub(/:/, "", $2); print $2; exit}')"
    if [[ -z "$nic" ]]; then
        nic="$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi
    # Never return the bridge itself.
    [[ "$nic" == "$BRIDGE" ]] && nic=""
    printf '%s' "$nic"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    require_command ip
    require_command nmcli
    require_command virsh

    PHYS_NIC="$(detect_phys_nic)"
    cat <<EOF

[$NAME] ==========================================================================
[$NAME] WARNING: removing '$BRIDGE' re-homes the host IP and can drop SSH.
[$NAME] Run this from the OCI serial console, not the SSH session under test.
[$NAME] Physical NIC to restore: ${PHYS_NIC:-<none detected>}
[$NAME] ==========================================================================
EOF
}

# --------------------------------------------------------------------------
# 1. Remove the VM (definition + storage) and seed artifacts
# --------------------------------------------------------------------------
remove_vm() {
    log "Removing VM $VM_NAME and its storage"
    sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 \
        || sudo virsh undefine "$VM_NAME" >/dev/null 2>&1 || true

    info "Removing seed ISO and seed directory"
    sudo rm -f "$SEED_ISO" || true
    rm -rf "$SEED_DIR" || true
    # The VM disk is normally removed by --remove-all-storage; clean up just in case.
    sudo rm -f "${IMAGE_DIR}/${VM_NAME}.qcow2" || true
}

# --------------------------------------------------------------------------
# 2. Remove the libvirt network
# --------------------------------------------------------------------------
remove_network() {
    log "Removing libvirt network $NET_NAME"
    sudo virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
    sudo virsh net-undefine "$NET_NAME" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# 3. Delete the bridge + port and restore the physical NIC to DHCP
# --------------------------------------------------------------------------
remove_bridge() {
    log "Deleting bridge connections and restoring $PHYS_NIC to DHCP"

    sudo nmcli connection down "$BRIDGE_PORT" >/dev/null 2>&1 || true
    sudo nmcli connection down "$BRIDGE" >/dev/null 2>&1 || true
    sudo nmcli connection delete "$BRIDGE_PORT" >/dev/null 2>&1 || true
    sudo nmcli connection delete "$BRIDGE" >/dev/null 2>&1 || true

    if [[ -z "$PHYS_NIC" ]]; then
        info "No physical NIC detected to restore; skipping NIC re-home"
        return
    fi

    # Prefer reactivating an existing profile bound to the NIC; otherwise create
    # a fresh DHCP ethernet profile. This is the step that can briefly drop SSH.
    local existing
    existing="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
        | awk -F: -v dev="$PHYS_NIC" -v port="$BRIDGE_PORT" '$2==dev && $1!=port {print $1; exit}')"
    if [[ -z "$existing" ]]; then
        existing="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
            | awk -F: -v port="$BRIDGE_PORT" '$2=="802-3-ethernet" && $1!=port {print $1; exit}')"
    fi

    if [[ -n "$existing" ]]; then
        info "Reactivating existing profile '$existing' on $PHYS_NIC"
        sudo nmcli connection up "$existing" >/dev/null 2>&1 || true
    else
        info "Creating a fresh DHCP profile on $PHYS_NIC"
        sudo nmcli connection add type ethernet con-name "$PHYS_NIC" \
            ifname "$PHYS_NIC" ipv4.method auto >/dev/null 2>&1 || true
        sudo nmcli connection up "$PHYS_NIC" >/dev/null 2>&1 || true
    fi
    sleep 3
}

# --------------------------------------------------------------------------
# 4. Verify the clean slate
# --------------------------------------------------------------------------
verify() {
    log "Verifying clean slate"

    local vmlist netlist
    vmlist="$(sudo virsh list --all 2>/dev/null || true)"
    if printf '%s' "$vmlist" | grep -qw "$VM_NAME"; then
        fail "$VM_NAME still present in 'virsh list --all'"
    else
        pass "$VM_NAME is gone"
    fi

    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    if printf '%s' "$netlist" | grep -qw "$NET_NAME"; then
        fail "$NET_NAME still present in 'virsh net-list --all'"
    else
        pass "$NET_NAME is gone"
    fi

    if ip link show "$BRIDGE" >/dev/null 2>&1; then
        fail "bridge $BRIDGE still exists"
    else
        pass "bridge $BRIDGE is gone"
    fi

    if [[ -n "$PHYS_NIC" ]]; then
        local phys
        phys="$(ip -4 -o addr show "$PHYS_NIC" 2>/dev/null || true)"
        if [[ -n "$phys" ]]; then
            pass "$PHYS_NIC carries an IP again ($(printf '%s' "$phys" | awk '{print $4}'))"
        else
            fail "$PHYS_NIC has no IP; check console connectivity"
        fi
    fi
}

summary() {
    log "Summary"
    printf '[%s] OK: %d   LEFT: %d\n' "$NAME" "$PASS_COUNT" "$FAIL_COUNT"
    if (( FAIL_COUNT > 0 )); then
        printf '[%s] RESULT: INCOMPLETE (%d item(s) still present) - re-run or inspect manually\n' "$NAME" "$FAIL_COUNT"
        exit 1
    fi
    printf '[%s] RESULT: CLEAN\n' "$NAME"
}

main() {
    preflight
    remove_vm
    remove_network
    remove_bridge
    verify
    summary
}

main "$@"
