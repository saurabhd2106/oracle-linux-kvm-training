#!/usr/bin/env bash
#
# test-lab-4.1-option1-ocikvm.sh - Lab 4.1 Option 1: give a KVM guest a real,
# OCI-reachable IP using the Oracle-supported oci-kvm utility bound to a
# dedicated secondary VNIC.
#
# This is the closest-to-production variant: oci-kvm builds the libvirt bridge on
# a secondary VNIC and attaches the guest using that VNIC's Oracle-assigned MAC,
# so the OCI substrate recognizes the guest's traffic. Because OCI does not DHCP
# secondary VNICs, the guest is given a STATIC address (the VNIC's private IP)
# via a NoCloud seed ISO.
#
# PREREQUISITE: a secondary VNIC must be attached to this instance. Provision it
# with terraform-linux-day1 (set secondary_vnic_vms = ["vm1"] and apply).
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-vnic.sh lives at the kvm-scripting tree root, one level up from test-script/.
# shellcheck source=../lib-vnic.sh
. "${SCRIPT_DIR}/../lib-vnic.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01-opt1}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE="${BASE_IMAGE:-${IMAGE_DIR}/OL9-base.qcow2}"
VM_DISK="${VM_DISK:-${IMAGE_DIR}/${VM_NAME}.qcow2}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${VM_NAME}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${VM_NAME}-seed}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
OS_VARIANT="${OS_VARIANT:-ol9.0}"
OL9_IMAGE_URL="${OL9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u4/x86_64/OL9U4_x86_64-kvm-b234.qcow2}"
SSH_USERS=(${SSH_USERS:-opc cloud-user root})

# --------------------------------------------------------------------------
# Logging / assertions
# --------------------------------------------------------------------------
NAME="opt1-ocikvm"
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

# ssh into the VM, trying each user; retries so cloud-init can finish.
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
    require_command python3

    info "Discovering the secondary VNIC from instance metadata (IMDS)"
    local vnic
    if ! vnic="$(get_secondary_vnic)"; then
        die "no secondary VNIC found via IMDS. Provision it first:
       in terraform-linux-day1, set  secondary_vnic_vms = [\"<vm-key>\"]  and run 'terraform apply',
       then re-run this script on the KVM host."
    fi
    read -r VNIC_MAC VNIC_IP VNIC_GW VNIC_PREFIX VNIC_OCID <<<"$vnic"
    info "Secondary VNIC: mac=$VNIC_MAC ip=$VNIC_IP gw=$VNIC_GW prefix=/$VNIC_PREFIX"
    info "               ocid=$VNIC_OCID"
    pass "Preflight: secondary VNIC discovered"

    # oci-kvm lives in the separate oci-utils-kvm subpackage (oci-utils alone
    # excludes /usr/bin/oci-kvm). oci-utils-kvm Requires: oci-utils.
    info "Ensuring oci-utils-kvm (provides oci-kvm) is installed"
    if ! command -v oci-kvm >/dev/null 2>&1; then
        sudo dnf install -y oci-utils-kvm
    fi
    command -v oci-kvm >/dev/null 2>&1 && pass "Preflight: oci-kvm available" \
        || die "oci-kvm not available after installing oci-utils-kvm"

    info "Ensuring xorriso is installed (genisoimage is removed on OL9)"
    if ! command -v xorrisofs >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
        sudo dnf install -y xorriso
    fi

    info "Ensuring SSH key pair exists: $SSH_KEY"
    if [[ ! -f "${SSH_KEY}.pub" ]]; then
        require_command ssh-keygen
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
    fi

    info "Ensuring base image is present: $BASE_IMAGE"
    if ! sudo test -f "$BASE_IMAGE"; then
        info "Base image missing; downloading from $OL9_IMAGE_URL"
        sudo curl -L -o "$BASE_IMAGE" "$OL9_IMAGE_URL"
    fi
    sudo test -f "$BASE_IMAGE" && pass "Preflight: base image present" \
        || die "base image missing ($BASE_IMAGE)"
}

# --------------------------------------------------------------------------
# Build the static seed ISO (matches the VNIC's MAC + IP)
# --------------------------------------------------------------------------
build_seed() {
    log "Building static seed ISO for $VM_NAME (IP $VNIC_IP)"
    mkdir -p "$SEED_DIR"
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}-v1
local-hostname: ${VM_NAME}
EOF
    cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${SSH_KEY}.pub")
runcmd:
  - nmcli connection reload
  - nmcli connection up eth0
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
        pass "Seed ISO built ($SEED_ISO)"
    else
        die "seed ISO build failed"
    fi
}

# --------------------------------------------------------------------------
# Create the VM with oci-kvm, bound to the secondary VNIC
# --------------------------------------------------------------------------
create_vm() {
    log "Creating $VM_NAME with oci-kvm, bound to the secondary VNIC"

    info "Removing any existing $VM_NAME first"
    sudo oci-kvm destroy --domain "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || true

    info "Creating fresh VM disk: $VM_DISK"
    sudo cp -f "$BASE_IMAGE" "$VM_DISK"

    info "oci-kvm create --domain $VM_NAME --net $VNIC_OCID"
    if sudo oci-kvm create \
        --domain "$VM_NAME" \
        --disk "$VM_DISK" \
        --net "$VNIC_OCID" \
        --virt "--import --os-variant ${OS_VARIANT} --memory 1024 --vcpus 1 --disk path=${SEED_ISO},device=cdrom --noautoconsole"; then
        pass "oci-kvm create succeeded"
    else
        fail "oci-kvm create failed"
        return
    fi

    local i state
    for ((i = 0; i < 12; i++)); do
        state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
        [[ "$state" == "running" ]] && break
        sleep 5
    done
    [[ "$state" == "running" ]] && pass "$VM_NAME is running" \
        || fail "$VM_NAME is not running (state: ${state:-unknown})"
}

# --------------------------------------------------------------------------
# Verify reachability on the VNIC's OCI IP
# --------------------------------------------------------------------------
verify() {
    log "Verifying $VM_NAME is reachable on its OCI IP ($VNIC_IP)"
    info "Waiting for cloud-init to apply the static address and start sshd"

    if ping -c2 -W2 "$VNIC_IP" >/dev/null 2>&1; then
        pass "VM is reachable via ping ($VNIC_IP)"
    else
        # Not fatal immediately; the guest may still be booting.
        warn "VM did not answer ping yet at $VNIC_IP (will still try SSH)"
    fi

    local out
    if out="$(vm_ssh_retry "$VNIC_IP" 'ip -4 addr show eth0' 24)" && [[ -n "$out" ]]; then
        pass "SSH into VM on its OCI IP succeeded"
        if printf '%s' "$out" | grep -qF "$VNIC_IP"; then
            pass "Guest interface carries the OCI-assigned IP ($VNIC_IP)"
        else
            warn "Guest reachable but eth0 does not show $VNIC_IP (check cloud-init network-config)"
        fi
    else
        fail "Could not SSH into VM at $VNIC_IP (checked users: ${SSH_USERS[*]})"
    fi

    if ping -c2 -W2 "$VNIC_IP" >/dev/null 2>&1; then
        pass "VM answers ping on its OCI IP ($VNIC_IP)"
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
    build_seed
    create_vm
    verify
    summary
}

main "$@"
