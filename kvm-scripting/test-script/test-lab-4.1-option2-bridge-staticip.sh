#!/usr/bin/env bash
#
# test-lab-4.1-option2-bridge-staticip.sh - Lab 4.1 Option 2: make the lab's own
# manual br0 bridge actually work on OCI by giving the guest the secondary VNIC's
# Oracle-assigned MAC and a STATIC IP.
#
# This keeps the exact bridge you built in Lab 4.1 (br0 + br0-network) - the
# closest-to-on-prem variant - but swaps the guest's made-up MAC for the OCI
# VNIC's MAC and assigns the VNIC's private IP statically (OCI does not DHCP
# secondary VNICs). The result is a bridged guest reachable on the host's subnet.
#
# PREREQUISITES:
#   - Lab 4.1 has been run so br0 + br0-network exist (see
#     test-lab-4.1-bridged-network.sh), and ol-lab-01 exists.
#   - A secondary VNIC is attached to this instance (terraform-linux-day1:
#     secondary_vnic_vms = ["<vm-key>"] then 'terraform apply').
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# WARNING: this reconfigures networking; run from the OCI serial console.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-vnic.sh lives at the kvm-scripting tree root, one level up from test-script/.
# shellcheck source=../lib-vnic.sh
. "${SCRIPT_DIR}/../lib-vnic.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
BRIDGE="${BRIDGE:-br0}"
NET_NAME="${NET_NAME:-br0-network}"
OLD_MAC="${OLD_MAC:-52:54:00:ab:cd:02}"   # the lab's Step 4 bridged MAC
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${VM_NAME}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${VM_NAME}-seed}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_USERS=(${SSH_USERS:-opc cloud-user root})

# --------------------------------------------------------------------------
# Logging / assertions
# --------------------------------------------------------------------------
NAME="opt2-bridge-static"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log()  { printf '\n[%s] ==> %s\n' "$NAME" "$*"; }
info() { printf '[%s]     %s\n' "$NAME" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[%s] PASS: %s\n' "$NAME" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[%s] FAIL: %s\n' "$NAME" "$*" >&2; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[%s] WARN: %s\n' "$NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

vm_ssh() {
    local addr="$1" cmd="$2" user out
    for user in "${SSH_USERS[@]}"; do
        if out="$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
            "${user}@${addr}" "$cmd" 2>/dev/null)"; then
            printf '%s' "$out"; return 0
        fi
    done
    return 1
}
vm_ssh_retry() {
    local addr="$1" cmd="$2" tries="${3:-24}" i out
    for ((i = 0; i < tries; i++)); do
        if out="$(vm_ssh "$addr" "$cmd")"; then printf '%s' "$out"; return 0; fi
        sleep 5
    done
    return 1
}

build_seed_iso() {
    local out="$1"
    ( cd "$SEED_DIR" && \
      if command -v xorrisofs >/dev/null 2>&1; then
          sudo xorrisofs -output "$out" -volid cidata -joliet -rock \
              user-data meta-data network-config
      else
          sudo xorriso -as mkisofs -output "$out" -volid cidata -joliet -rock \
              user-data meta-data network-config
      fi )
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command curl
    require_command virsh
    require_command nmcli
    require_command python3
    require_command ip

    ip link show "$BRIDGE" >/dev/null 2>&1 \
        && pass "Preflight: bridge $BRIDGE exists" \
        || die "bridge $BRIDGE not found. Run the Lab 4.1 test (test-lab-4.1-bridged-network.sh) first."
    sudo virsh net-info "$NET_NAME" >/dev/null 2>&1 \
        && pass "Preflight: libvirt network $NET_NAME exists" \
        || die "libvirt network $NET_NAME not found. Run the Lab 4.1 test first."
    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: VM $VM_NAME exists" \
        || die "VM $VM_NAME not found. Run the Lab 4.1 test first."
    [[ -f "${SSH_KEY}.pub" ]] || die "SSH key ${SSH_KEY}.pub not found (expected from Lab 3.1/4.1)."
    [[ -d "$SEED_DIR" ]] || die "seed dir $SEED_DIR not found (expected from Lab 4.1)."

    info "Discovering the secondary VNIC from IMDS"
    local vnic
    if ! vnic="$(get_secondary_vnic)"; then
        die "no secondary VNIC found via IMDS. Provision it first:
       in terraform-linux-day1, set  secondary_vnic_vms = [\"<vm-key>\"]  and run 'terraform apply'."
    fi
    read -r VNIC_MAC VNIC_IP VNIC_GW VNIC_PREFIX VNIC_OCID <<<"$vnic"
    info "Secondary VNIC: mac=$VNIC_MAC ip=$VNIC_IP gw=$VNIC_GW prefix=/$VNIC_PREFIX"
    pass "Preflight: secondary VNIC discovered"
}

# --------------------------------------------------------------------------
# Make sure the host does not claim the secondary NIC (the guest owns its MAC)
# --------------------------------------------------------------------------
release_host_nic() {
    log "Ensuring the host leaves the secondary NIC unconfigured"

    # Find the host device whose permanent/current MAC matches the VNIC's MAC.
    local dev
    dev="$(ip -o link show 2>/dev/null | awk -v mac="$VNIC_MAC" 'tolower($0) ~ tolower(mac) {sub(/:$/,"",$2); sub(/@.*/,"",$2); print $2; exit}')"

    if [[ -n "$dev" ]]; then
        info "Secondary NIC on host is device '$dev'; removing any NM profile so the guest can own its MAC"
        local con
        con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$dev" '$2==d {print $1}')"
        if [[ -n "$con" ]]; then
            while IFS= read -r c; do
                [[ -n "$c" ]] || continue
                sudo nmcli connection down "$c" >/dev/null 2>&1 || true
                sudo nmcli connection delete "$c" >/dev/null 2>&1 || true
            done <<<"$con"
        fi
        # Also make sure it is not attached to the bridge as a port.
        sudo ip link set "$dev" nomaster >/dev/null 2>&1 || true
        pass "Host NIC '$dev' released (guest will use MAC $VNIC_MAC over $BRIDGE)"
    else
        info "No host device currently claims MAC $VNIC_MAC; nothing to release"
        pass "Host is not claiming the secondary VNIC MAC"
    fi
}

# --------------------------------------------------------------------------
# Move ol-lab-01's interface to the OCI MAC and give it a static seed
# --------------------------------------------------------------------------
apply_change() {
    log "Repointing $VM_NAME onto $NET_NAME using the OCI MAC $VNIC_MAC"

    info "Shutting the VM down"
    sudo virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
    local i state
    for ((i = 0; i < 24; i++)); do
        state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
        [[ "$state" == "shut off" ]] && break
        sleep 5
    done
    if [[ "$state" != "shut off" ]]; then
        warn "VM still '$state'; forcing off"
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi

    info "Detaching current interface(s) and attaching one on $NET_NAME with MAC $VNIC_MAC"
    sudo virsh detach-interface --domain "$VM_NAME" --type network \
        --mac "$OLD_MAC" --config >/dev/null 2>&1 || true
    # Also detach any lingering interface on this network with a different MAC.
    sudo virsh detach-interface --domain "$VM_NAME" --type bridge --config >/dev/null 2>&1 || true
    sudo virsh attach-interface --domain "$VM_NAME" --type network \
        --source "$NET_NAME" --model virtio --mac "$VNIC_MAC" --config

    local domiflist
    domiflist="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null || true)"
    info "virsh domiflist $VM_NAME:"
    printf '%s\n' "$domiflist"
    printf '%s' "$domiflist" | grep -qF "$NET_NAME" \
        && pass "Interface source is $NET_NAME" || fail "Interface not on $NET_NAME"
    printf '%s' "$domiflist" | grep -qiF "$VNIC_MAC" \
        && pass "Interface uses the OCI VNIC MAC ($VNIC_MAC)" || fail "Interface not using $VNIC_MAC"

    info "Regenerating the seed with a static address ($VNIC_IP/$VNIC_PREFIX)"
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}-v3
local-hostname: ${VM_NAME}
EOF
    cat > "$SEED_DIR/network-config" <<EOF
version: 2
ethernets:
  eth0:
    match:
      macaddress: "${VNIC_MAC}"
    set-name: eth0
    dhcp4: false
    addresses:
      - ${VNIC_IP}/${VNIC_PREFIX}
    gateway4: ${VNIC_GW}
    nameservers:
      addresses: [169.254.169.254]
EOF
    if build_seed_iso "$SEED_ISO"; then
        pass "Seed ISO rebuilt with static config ($SEED_ISO)"
    else
        fail "seed ISO rebuild failed"
    fi

    info "Starting the VM"
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    info "Waiting for cloud-init to apply the static address"
    sleep 30
}

# --------------------------------------------------------------------------
# Verify reachability on the OCI IP
# --------------------------------------------------------------------------
verify() {
    log "Verifying $VM_NAME is reachable on its OCI IP ($VNIC_IP)"

    local brlink
    brlink="$(bridge link show 2>/dev/null || true)"
    if printf '%s' "$brlink" | grep -q "master $BRIDGE" && printf '%s' "$brlink" | grep -q "vnet"; then
        pass "A vnet interface is attached to $BRIDGE"
    else
        fail "No vnet interface attached to $BRIDGE"
    fi

    local out
    if out="$(vm_ssh_retry "$VNIC_IP" 'ip -4 addr show eth0' 24)" && [[ -n "$out" ]]; then
        pass "SSH into the bridged VM on its OCI IP succeeded"
        if printf '%s' "$out" | grep -qF "$VNIC_IP"; then
            pass "Guest interface carries the OCI-assigned IP ($VNIC_IP)"
        else
            warn "Guest reachable but eth0 does not show $VNIC_IP"
        fi
    else
        fail "Could not SSH into the bridged VM at $VNIC_IP (checked users: ${SSH_USERS[*]})"
    fi

    if ping -c2 -W2 "$VNIC_IP" >/dev/null 2>&1; then
        pass "Bridged VM is directly reachable via ping ($VNIC_IP)"
    else
        warn "Bridged VM did not answer ping at $VNIC_IP (check the VCN security list allows ICMP)"
    fi
}

summary() {
    log "Summary"
    printf '[%s] PASS: %d   WARN: %d   FAIL: %d\n' "$NAME" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    if (( FAIL_COUNT > 0 )); then
        printf '[%s] RESULT: FAILED (%d assertion(s) failed)\n' "$NAME" "$FAIL_COUNT"
        exit 1
    fi
    printf '[%s] RESULT: PASSED\n' "$NAME"
}

main() {
    preflight
    release_host_nic
    apply_change
    verify
    summary
}

main "$@"
