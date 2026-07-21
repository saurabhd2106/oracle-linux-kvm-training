#!/usr/bin/env bash
#
# test-lab-4.1-bridged-network.sh - run and verify Lab 4.1 (Configure a Bridged
# Network) end-to-end on the KVM host.
#
# Runs Steps 0-5 of the lab and asserts each "Expected result", printing a
# PASS/FAIL/WARN line per check and a summary at the end. Exits non-zero only if
# a real assertion FAILs; the OCI reachability limitation in Step 5 is reported
# as a WARN (see below), not a failure.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user (already in the
# libvirt group from install-kvm). It uses sudo for nmcli/virsh exactly as the
# lab does.
#
# WARNING: Step 2 moves the host's IP configuration onto the new br0 bridge and
# can briefly drop SSH. Run this from the OCI serial console (or a console that
# survives a NIC handover), not from the SSH session you are testing.
#
# LAB GAPS WORKED AROUND (see the plan for detail):
#   - genisoimage is removed on OL9; this script installs/uses xorriso instead.
#   - OCI only DHCPs the primary VNIC and drops unknown-MAC traffic, so a bridged
#     VM using its own MAC usually cannot get a host-subnet address. Step 5's
#     reachability checks are therefore treated as a KNOWN-LIMITATION WARN, not a
#     hard failure, so Steps 0-4 still validate.
#   - The lab's Step 0 uses "ssh root@"; the cloud-init key lands on the default
#     user, so this script uses cloud-user (falling back to root).

set -euo pipefail

# --------------------------------------------------------------------------
# Config (override via environment if needed)
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
MAC1="${MAC1:-52:54:00:ab:cd:01}"
MAC2="${MAC2:-52:54:00:ab:cd:02}"
BRIDGE="${BRIDGE:-br0}"
BRIDGE_PORT="${BRIDGE_PORT:-br0-port1}"
NET_NAME="${NET_NAME:-br0-network}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE="${BASE_IMAGE:-${IMAGE_DIR}/OL9-base.qcow2}"
VM_DISK="${VM_DISK:-${IMAGE_DIR}/${VM_NAME}.qcow2}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${VM_NAME}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${VM_NAME}-seed}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
OS_VARIANT="${OS_VARIANT:-ol9.0}"
NAT_SUBNET_PREFIX="${NAT_SUBNET_PREFIX:-192.168.122.}"

# Golden Oracle Linux 9 KVM cloud image, matching templates-kvm/bootstrap.sh.
OL9_IMAGE_URL="${OL9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u4/x86_64/OL9U4_x86_64-kvm-b234.qcow2}"

# SSH users to try, in order (cloud-init key lands on the default user).
SSH_USERS=(${SSH_USERS:-cloud-user root opc})

# --------------------------------------------------------------------------
# Logging / assertions
# --------------------------------------------------------------------------
NAME="test-lab-4.1"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log()  { printf '\n[%s] ==> %s\n' "$NAME" "$*"; }
info() { printf '[%s]     %s\n' "$NAME" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[%s] PASS: %s\n' "$NAME" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[%s] FAIL: %s\n' "$NAME" "$*" >&2; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[%s] WARN: %s\n' "$NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }

# assert_contains <haystack> <needle> <description>
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        pass "$3"
    else
        fail "$3 (expected to find: '$2')"
    fi
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        fail "$3 (did not expect: '$2')"
    else
        pass "$3"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Detect the host's physical uplink NIC from the default route rather than
# assuming a name like enp0s5 (the lab's single most common failure).
detect_phys_nic() {
    local nic
    nic="$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [[ -z "$nic" ]]; then
        # Fallback: first connected ethernet device that is not the bridge.
        nic="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
            | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')"
    fi
    printf '%s' "$nic"
}

# Build the NoCloud seed ISO from the files in SEED_DIR. Uses xorriso
# (genisoimage was removed on OL9). Tries xorrisofs, then "xorriso -as mkisofs".
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

# Return the CIDR (e.g. 10.0.0.15/24) currently on the bridge, if any.
bridge_cidr() {
    ip -4 -o addr show "$BRIDGE" 2>/dev/null | awk '{print $4; exit}'
}

# ssh into the VM at $1, running command $2. Tries each SSH user in turn.
# Prints the remote command's stdout; returns 0 on first success.
vm_ssh() {
    local addr="$1" cmd="$2" user out
    for user in "${SSH_USERS[@]}"; do
        if out="$(ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            "${user}@${addr}" "$cmd" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
    done
    return 1
}

# Like vm_ssh, but retries for a while so cloud-init has time to inject the key
# and bring sshd up before we judge the result.
# $1=addr  $2=cmd  $3=tries (default 24, i.e. up to ~2 min at 5s each)
vm_ssh_retry() {
    local addr="$1" cmd="$2" tries="${3:-24}" i out
    for ((i = 0; i < tries; i++)); do
        if out="$(vm_ssh "$addr" "$cmd")"; then
            printf '%s' "$out"
            return 0
        fi
        sleep 5
    done
    return 1
}

# Wait for the VM to acquire an address on the given libvirt lease source.
# $1 = source ("lease" or "arp"); prints the first IPv4 found, or nothing.
wait_for_vm_addr() {
    local source="$1" tries="${2:-30}" i out addr
    for ((i = 0; i < tries; i++)); do
        if [[ "$source" == "arp" ]]; then
            out="$(sudo virsh domifaddr "$VM_NAME" --source arp 2>/dev/null || true)"
        else
            out="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null || true)"
        fi
        addr="$(printf '%s' "$out" | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')"
        if [[ -n "$addr" ]]; then
            printf '%s' "$addr"
            return 0
        fi
        sleep 5
    done
    return 1
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command ip
    require_command nmcli
    require_command virsh
    require_command awk
    require_command grep

    PHYS_NIC="$(detect_phys_nic)"
    [[ -n "$PHYS_NIC" ]] || die "could not detect the host's physical NIC from the default route"
    info "Detected physical uplink NIC: $PHYS_NIC"

    cat <<EOF

[$NAME] ==========================================================================
[$NAME] WARNING: Step 2 moves the host IP onto '$BRIDGE' and can drop SSH.
[$NAME] Run this from the OCI serial console, not the SSH session under test.
[$NAME] Physical NIC that will become a bridge port: $PHYS_NIC
[$NAME] ==========================================================================
EOF
}

# --------------------------------------------------------------------------
# Step 0: Rebuild ol-lab-01 using the declared-configuration method
# --------------------------------------------------------------------------
step0_rebuild_vm() {
    log "Step 0: Rebuild $VM_NAME (declared-configuration method)"

    info "Removing any existing $VM_NAME (definition + storage)"
    sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || true
    sudo virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
    local all
    all="$(sudo virsh list --all 2>/dev/null || true)"
    assert_not_contains "$all" "$VM_NAME" "Step 0: $VM_NAME removed from 'virsh list --all'"

    info "Ensuring base image is present: $BASE_IMAGE"
    if ! sudo test -f "$BASE_IMAGE"; then
        info "Base image missing; downloading from $OL9_IMAGE_URL"
        require_command curl
        sudo curl -L -o "$BASE_IMAGE" "$OL9_IMAGE_URL"
    fi
    sudo test -f "$BASE_IMAGE" && pass "Step 0: base image present ($BASE_IMAGE)" \
        || { fail "Step 0: base image missing ($BASE_IMAGE)"; return; }

    info "Creating fresh VM disk: $VM_DISK"
    sudo cp -f "$BASE_IMAGE" "$VM_DISK"

    info "Ensuring SSH key pair exists: $SSH_KEY"
    if [[ ! -f "${SSH_KEY}.pub" ]]; then
        require_command ssh-keygen
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
    fi
    [[ -f "${SSH_KEY}.pub" ]] && pass "Step 0: SSH public key present (${SSH_KEY}.pub)" \
        || { fail "Step 0: SSH public key missing (${SSH_KEY}.pub)"; return; }

    info "Ensuring xorriso is installed (genisoimage is removed on OL9)"
    if ! command -v xorrisofs >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
        sudo dnf install -y xorriso
    fi
    ( command -v xorrisofs >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1 ) \
        && pass "Step 0: ISO build tool (xorriso) available" \
        || { fail "Step 0: xorriso not available after install"; return; }

    info "Writing seed files (instance-id v1, MAC $MAC1)"
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
      macaddress: "${MAC1}"
    set-name: eth0
    dhcp4: true
EOF

    info "Building seed ISO: $SEED_ISO"
    if build_seed_iso "$SEED_ISO"; then
        pass "Step 0: seed ISO built ($SEED_ISO)"
    else
        fail "Step 0: seed ISO build failed"
        return
    fi

    info "Rebuilding the VM with virt-install (network=default, mac=$MAC1)"
    require_command virt-install
    sudo virt-install \
        --name "$VM_NAME" \
        --memory 1024 \
        --vcpus 1 \
        --disk "path=${VM_DISK},format=qcow2" \
        --disk "path=${SEED_ISO},device=cdrom" \
        --import \
        --os-variant "$OS_VARIANT" \
        --network "network=default,mac=${MAC1}" \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole

    info "Waiting for the VM to boot and obtain a NAT lease"
    local addr
    if addr="$(wait_for_vm_addr lease 36)"; then
        info "VM address (NAT): $addr"
        info "Waiting for cloud-init to finish and inject the SSH key"
        local out
        if out="$(vm_ssh_retry "$addr" 'echo ok')" && [[ "$out" == "ok" ]]; then
            pass "Step 0: $VM_NAME reachable over SSH (echo ok)"
        else
            fail "Step 0: SSH to $VM_NAME did not return 'ok' (checked users: ${SSH_USERS[*]})"
        fi
    else
        fail "Step 0: VM did not obtain a NAT lease in time (cloud-init may still be running)"
    fi
}

# --------------------------------------------------------------------------
# Step 1: Review the current NAT network
# --------------------------------------------------------------------------
step1_review_nat() {
    log "Step 1: Review the current NAT network"

    local netlist dumpxml domiflist
    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    assert_contains "$netlist" "default" "Step 1: 'default' network listed"
    if printf '%s' "$netlist" | awk '/(^| )default( |$)/ {print}' | grep -q "active"; then
        pass "Step 1: 'default' network is active"
    else
        fail "Step 1: 'default' network is not active"
    fi

    dumpxml="$(sudo virsh net-dumpxml default 2>/dev/null || true)"
    assert_contains "$dumpxml" "<forward mode='nat'" "Step 1: default is a NAT network (forward mode='nat')"
    assert_contains "$dumpxml" "<bridge name='virbr0'" "Step 1: default uses virbr0 (not a physical bridge)"

    domiflist="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null || true)"
    assert_contains "$domiflist" "default" "Step 1: $VM_NAME interface source is 'default'"
    assert_contains "$domiflist" "$MAC1" "Step 1: $VM_NAME interface uses MAC $MAC1"
}

# --------------------------------------------------------------------------
# Step 2: Create a Linux bridge on the host
# --------------------------------------------------------------------------
bridge_is_healthy() {
    local addr link
    link="$(ip -o link show "$BRIDGE" 2>/dev/null || true)"
    addr="$(bridge_cidr)"
    # Healthy = has an IPv4 address and is not stuck with an all-zero MAC.
    [[ -n "$addr" ]] && printf '%s' "$link" | grep -qv "00:00:00:00:00:00"
}

step2_create_bridge() {
    log "Step 2: Create a Linux bridge ($BRIDGE) on $PHYS_NIC"

    info "nmcli device status:"
    sudo nmcli device status || true

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$BRIDGE"; then
        info "Bridge connection '$BRIDGE' already exists; reusing"
    else
        sudo nmcli connection add type bridge con-name "$BRIDGE" ifname "$BRIDGE"
    fi
    sudo nmcli connection modify "$BRIDGE" ipv4.method auto
    # Disable STP so the port starts forwarding immediately (avoids the ~30s
    # forwarding delay that can make later checks flaky).
    sudo nmcli connection modify "$BRIDGE" bridge.stp no

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$BRIDGE_PORT"; then
        info "Bridge port '$BRIDGE_PORT' already exists; reusing"
    else
        sudo nmcli connection add type ethernet port-type bridge \
            con-name "$BRIDGE_PORT" ifname "$PHYS_NIC" controller "$BRIDGE"
    fi

    info "Bringing up $BRIDGE then $BRIDGE_PORT"
    sudo nmcli connection up "$BRIDGE" || true
    sudo nmcli connection up "$BRIDGE_PORT" || true
    sleep 3

    # Handle the documented NO-CARRIER / 00:00:00:00:00:00 timing bug with one
    # clean down/up cycle of both connections.
    if ! bridge_is_healthy; then
        warn "Step 2: $BRIDGE not healthy yet (NO-CARRIER / zero MAC); retrying with a down/up cycle"
        sudo nmcli connection down "$BRIDGE_PORT" || true
        sudo nmcli connection down "$BRIDGE" || true
        sleep 2
        sudo nmcli connection up "$BRIDGE" || true
        sudo nmcli connection up "$BRIDGE_PORT" || true
        sleep 5
    fi

    info "ip addr show $BRIDGE:"
    ip addr show "$BRIDGE" || true

    local link addr
    link="$(ip -o link show "$BRIDGE" 2>/dev/null || true)"
    assert_contains "$link" "UP" "Step 2: $BRIDGE is UP"
    assert_contains "$link" "LOWER_UP" "Step 2: $BRIDGE has carrier (LOWER_UP)"
    addr="$(bridge_cidr)"
    if [[ -n "$addr" ]]; then
        pass "Step 2: $BRIDGE has an inet address ($addr)"
    else
        fail "Step 2: $BRIDGE has no inet address"
    fi

    local active
    active="$(nmcli connection show --active 2>/dev/null || true)"
    assert_contains "$active" "$BRIDGE" "Step 2: $BRIDGE connection is active"
    assert_contains "$active" "$BRIDGE_PORT" "Step 2: $BRIDGE_PORT connection is active"

    info "ip addr show $PHYS_NIC:"
    ip addr show "$PHYS_NIC" || true
    local phys
    phys="$(ip -4 -o addr show "$PHYS_NIC" 2>/dev/null || true)"
    if [[ -z "$phys" ]]; then
        pass "Step 2: $PHYS_NIC carries no IP of its own (pure bridge port)"
    else
        fail "Step 2: $PHYS_NIC still has an inet address (should be on $BRIDGE now)"
    fi
    local physlink
    physlink="$(ip -o link show "$PHYS_NIC" 2>/dev/null || true)"
    assert_contains "$physlink" "master $BRIDGE" "Step 2: $PHYS_NIC is enslaved to $BRIDGE"
}

# --------------------------------------------------------------------------
# Step 3: Define a libvirt network bound to the bridge
# --------------------------------------------------------------------------
step3_define_network() {
    log "Step 3: Define libvirt network '$NET_NAME' bound to $BRIDGE"

    local xml=/tmp/${NET_NAME}.xml
    cat > "$xml" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode="bridge"/>
  <bridge name="${BRIDGE}"/>
</network>
EOF

    if sudo virsh net-info "$NET_NAME" >/dev/null 2>&1; then
        info "Network '$NET_NAME' already defined; ensuring it is started/autostart"
    else
        sudo virsh net-define "$xml"
    fi
    sudo virsh net-start "$NET_NAME" >/dev/null 2>&1 || true
    sudo virsh net-autostart "$NET_NAME" >/dev/null 2>&1 || true

    local netlist
    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    info "virsh net-list --all:"
    printf '%s\n' "$netlist"

    for n in default "$NET_NAME"; do
        if printf '%s' "$netlist" | awk -v net="$n" '$1==net {print}' | grep -q "active"; then
            pass "Step 3: '$n' network is active"
        else
            fail "Step 3: '$n' network is not active"
        fi
        if printf '%s' "$netlist" | awk -v net="$n" '$1==net {print}' | grep -q "yes"; then
            pass "Step 3: '$n' network is autostart"
        else
            fail "Step 3: '$n' network is not autostart"
        fi
    done
}

# --------------------------------------------------------------------------
# Step 4: Regenerate the seed ISO for the new network + move the interface
# --------------------------------------------------------------------------
step4_move_interface() {
    log "Step 4: Move $VM_NAME to $NET_NAME and regenerate its seed (MAC $MAC2)"

    info "Shutting the VM down"
    sudo virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
    local i state
    for ((i = 0; i < 24; i++)); do
        state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
        [[ "$state" == "shut off" ]] && break
        sleep 5
    done
    if [[ "$state" != "shut off" ]]; then
        warn "Step 4: VM still '$state' after wait; forcing off with destroy"
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi
    state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || true)"
    [[ "$state" == "shut off" ]] && pass "Step 4: $VM_NAME is shut off" \
        || fail "Step 4: $VM_NAME is not shut off (state: $state)"

    info "Detaching the default-network interface ($MAC1)"
    sudo virsh detach-interface --domain "$VM_NAME" --type network \
        --mac "$MAC1" --config >/dev/null 2>&1 || true
    info "Attaching a new interface on $NET_NAME ($MAC2)"
    sudo virsh attach-interface --domain "$VM_NAME" --type network \
        --source "$NET_NAME" --model virtio --mac "$MAC2" --config

    local domiflist
    domiflist="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null || true)"
    info "virsh domiflist $VM_NAME:"
    printf '%s\n' "$domiflist"
    assert_contains "$domiflist" "$NET_NAME" "Step 4: interface source is now '$NET_NAME'"
    assert_contains "$domiflist" "$MAC2" "Step 4: interface uses new MAC $MAC2"
    assert_not_contains "$domiflist" "$MAC1" "Step 4: old MAC $MAC1 no longer present"

    info "Regenerating seed files (instance-id v2, MAC $MAC2)"
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}-v2
local-hostname: ${VM_NAME}
EOF
    cat > "$SEED_DIR/network-config" <<EOF
version: 2
ethernets:
  eth0:
    match:
      macaddress: "${MAC2}"
    set-name: eth0
    dhcp4: true
EOF

    info "Rebuilding the seed ISO at the same path: $SEED_ISO"
    if build_seed_iso "$SEED_ISO"; then
        pass "Step 4: seed ISO rebuilt ($SEED_ISO)"
    else
        fail "Step 4: seed ISO rebuild failed"
    fi

    info "Starting the VM"
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    info "Waiting for cloud-init to reconfigure the network"
    sleep 30
}

# --------------------------------------------------------------------------
# Step 5: Verify connectivity on the host's network segment
# --------------------------------------------------------------------------
step5_verify_connectivity() {
    log "Step 5: Verify $VM_NAME on the host's network segment"

    # The vnet port existing on the bridge is verifiable regardless of whether
    # OCI hands the VM an address, so assert it first.
    local brlink
    brlink="$(bridge link show 2>/dev/null || true)"
    info "bridge link show:"
    printf '%s\n' "$brlink"
    if printf '%s' "$brlink" | grep -q "master $BRIDGE" && printf '%s' "$brlink" | grep -q "vnet"; then
        pass "Step 5: a vnet interface is attached to $BRIDGE"
    else
        fail "Step 5: no vnet interface attached to $BRIDGE"
    fi

    # Prime the ARP cache across the bridge subnet, then look for the VM.
    local cidr host_ip
    cidr="$(bridge_cidr)"
    host_ip="${cidr%%/*}"
    if command -v nmap >/dev/null 2>&1 && [[ -n "$cidr" ]]; then
        info "Priming ARP with an nmap ping sweep of $cidr"
        sudo nmap -sn -n "$cidr" >/dev/null 2>&1 || true
    elif [[ -n "$host_ip" ]]; then
        info "Priming ARP with a small ping sweep around $host_ip"
        local base last
        base="${host_ip%.*}"
        for last in $(seq 1 254); do
            ping -c1 -W1 "${base}.${last}" >/dev/null 2>&1 &
        done
        wait 2>/dev/null || true
    fi

    local addr
    addr="$(wait_for_vm_addr arp 12 || true)"

    if [[ -n "$addr" && "$addr" != 169.254.* && "$addr" != "$NAT_SUBNET_PREFIX"* ]]; then
        info "VM address on bridge: $addr"
        assert_not_contains "$addr" "$NAT_SUBNET_PREFIX" "Step 5: VM address is NOT in the NAT range ($NAT_SUBNET_PREFIX0/24)"

        # Same subnet as the host's br0 address?
        local vm_net host_net
        vm_net="${addr%.*}"
        host_net="${host_ip%.*}"
        if [[ -n "$host_net" && "$vm_net" == "$host_net" ]]; then
            pass "Step 5: VM is in the same subnet as $BRIDGE ($host_net.0)"
        else
            warn "Step 5: VM subnet ($vm_net.0) differs from $BRIDGE subnet ($host_net.0)"
        fi

        local out
        if out="$(vm_ssh_retry "$addr" 'ip addr show' 12)" && [[ -n "$out" ]]; then
            pass "Step 5: SSH into VM on the bridged network succeeded"
        else
            warn "Step 5: could not SSH into VM at $addr (it may still be booting)"
        fi

        if ping -c2 -W2 "$addr" >/dev/null 2>&1; then
            pass "Step 5: VM is directly reachable via ping ($addr)"
        else
            warn "Step 5: VM did not answer ping at $addr"
        fi
    else
        # Expected on OCI: the substrate won't DHCP/route the VM's own MAC.
        warn "Step 5: KNOWN LIMITATION - VM has no host-subnet address (got: '${addr:-none}')."
        info  "        On OCI, only the primary VNIC gets DHCP and unknown-MAC traffic is"
        info  "        dropped, so a bridged VM using its own MAC ($MAC2) cannot obtain a"
        info  "        lease from the host's subnet. skip_source_dest_check on the VNIC is"
        info  "        necessary but not sufficient. Steps 0-4 above still validate the lab"
        info  "        mechanics; genuine reachability needs a secondary VNIC (oci-kvm) with"
        info  "        a static IP inside the guest. Reachability checks recorded as WARN."
    fi
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
summary() {
    log "Summary"
    printf '[%s] PASS: %d   WARN: %d   FAIL: %d\n' "$NAME" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    if (( WARN_COUNT > 0 )); then
        printf '[%s] Note: WARNs are expected on OCI (Step 5 bridging limitation).\n' "$NAME"
    fi
    if (( FAIL_COUNT > 0 )); then
        printf '[%s] RESULT: FAILED (%d assertion(s) failed)\n' "$NAME" "$FAIL_COUNT"
        exit 1
    fi
    printf '[%s] RESULT: PASSED\n' "$NAME"
}

main() {
    preflight
    step0_rebuild_vm
    step1_review_nat
    step2_create_bridge
    step3_define_network
    step4_move_interface
    step5_verify_connectivity
    summary
}

main "$@"
