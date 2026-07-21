#!/usr/bin/env bash
#
# test-lab-8.1-edit-vm-xml-network.sh - run and verify Lab 8.1 (Edit VM XML to
# Add a Network Interface) end-to-end against ol-lab-01.
#
# Backs up the VM XML, adds a second <interface> on the 'default' NAT network,
# validates the definition, restarts the domain so the new NIC appears, and
# confirms two interfaces exist host-side and inside the guest. Prints a
# PASS/WARN/FAIL line per lab "Expected result" and a FINDINGS block.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user.
#
# PREREQUISITES: ol-lab-01 exists; the 'default' network is active. (The lab also
# expects 'br0-network' active with the original interface on it; this script
# works regardless of which network the first interface is on.)
#
# NOTE: the lab edits the XML with the interactive 'virsh edit'. This script adds
# the interface non-interactively (virt-xml, or a dump/insert/define fallback) so
# it can run unattended, exercising the same edit-validate-apply cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="test-lab-8.1"
. "${SCRIPT_DIR}/../lib-lab.sh"

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
ADD_NETWORK="${ADD_NETWORK:-default}"
BEFORE_XML="${BEFORE_XML:-${HOME}/${VM_NAME}-before.xml}"
AFTER_XML="${AFTER_XML:-${HOME}/${VM_NAME}-after.xml}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    require_command virsh

    sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
        && pass "Preflight: $VM_NAME is defined" \
        || die "$VM_NAME not found. Run Lab 3.1/4.1 first."

    local netlist
    netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
    if printf '%s' "$netlist" | awk -v n="$ADD_NETWORK" '$1==n' | grep -q active; then
        pass "Preflight: network '$ADD_NETWORK' is active"
    else
        info "Network '$ADD_NETWORK' not active; attempting to start it"
        sudo virsh net-start "$ADD_NETWORK" >/dev/null 2>&1 || true
        sudo virsh net-list --all 2>/dev/null | awk -v n="$ADD_NETWORK" '$1==n' | grep -q active \
            && pass "Preflight: network '$ADD_NETWORK' started" \
            || die "network '$ADD_NETWORK' is not available"
    fi
}

# --------------------------------------------------------------------------
# Step 1: Dump the current XML definition
# --------------------------------------------------------------------------
IFACE_BEFORE=0
step1_dump_xml() {
    log "Step 1: Dump the current XML and back it up"

    local ifaces
    ifaces="$(sudo virsh dumpxml "$VM_NAME" 2>/dev/null | grep -A5 '<interface' || true)"
    info "Existing interface block(s):"; printf '%s\n' "$ifaces"

    sudo virsh dumpxml "$VM_NAME" > "$BEFORE_XML"
    [[ -s "$BEFORE_XML" ]] && pass "Step 1: full XML backed up to $BEFORE_XML" \
        || fail "Step 1: XML backup is empty"

    IFACE_BEFORE="$(grep -c '<interface' "$BEFORE_XML" 2>/dev/null || echo 0)"
    info "Interface count before: $IFACE_BEFORE"
}

# --------------------------------------------------------------------------
# Step 2: Add a second network interface
# --------------------------------------------------------------------------
step2_add_interface() {
    log "Step 2: Add a second <interface> on '$ADD_NETWORK'"

    # Skip if the VM already has 2+ interfaces including one on ADD_NETWORK.
    local domiflist
    domiflist="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null || true)"
    if (( IFACE_BEFORE >= 2 )) && printf '%s' "$domiflist" | grep -qw "$ADD_NETWORK"; then
        info "A second interface on '$ADD_NETWORK' already exists; skipping add"
        pass "Step 2: second interface already present"
        return
    fi

    if command -v virt-xml >/dev/null 2>&1; then
        info "Adding interface with virt-xml (--define, persistent)"
        sudo virt-xml "$VM_NAME" --add-device \
            --network "network=${ADD_NETWORK},model=virtio" --define \
            && pass "Step 2: interface added via virt-xml" \
            || fail "Step 2: virt-xml failed to add the interface"
    else
        info "virt-xml not present; falling back to dump/insert/define"
        finding "virt-xml (from virt-install) was not installed; used a dumpxml/insert/define fallback. Installing virt-install gives the cleaner non-interactive XML editor."
        local tmp=/tmp/${VM_NAME}-edit.xml
        sudo virsh dumpxml "$VM_NAME" > "$tmp"
        # Insert a new <interface> block just before </devices>.
        python3 - "$tmp" "$ADD_NETWORK" <<'PY'
import sys
path, net = sys.argv[1], sys.argv[2]
with open(path) as f:
    xml = f.read()
block = ("    <interface type='network'>\n"
         f"      <source network='{net}'/>\n"
         "      <model type='virtio'/>\n"
         "    </interface>\n")
xml = xml.replace("</devices>", block + "  </devices>", 1)
with open(path, "w") as f:
    f.write(xml)
PY
        sudo virsh define "$tmp" \
            && pass "Step 2: interface added via virsh define" \
            || fail "Step 2: virsh define failed"
    fi
}

# --------------------------------------------------------------------------
# Step 3: Validate the change
# --------------------------------------------------------------------------
step3_validate() {
    log "Step 3: Validate the new definition"

    sudo virsh dumpxml "$VM_NAME" > "$AFTER_XML"

    if command -v virt-xml-validate >/dev/null 2>&1; then
        if virt-xml-validate "$AFTER_XML" >/dev/null 2>&1; then
            pass "Step 3: $AFTER_XML validates cleanly against libvirt's schema"
        else
            fail "Step 3: virt-xml-validate reported errors"
        fi
    else
        warn "Step 3: virt-xml-validate not installed; skipping schema validation"
    fi

    local count
    count="$(grep -c '<interface' "$AFTER_XML" 2>/dev/null || echo 0)"
    info "Interface count after: $count"
    if (( count == 2 )); then
        pass "Step 3: exactly 2 <interface> blocks now defined"
    elif (( count > 2 )); then
        warn "Step 3: $count interfaces present (expected 2; extra interfaces from prior runs?)"
    else
        fail "Step 3: expected 2 interfaces, found $count"
    fi
}

# --------------------------------------------------------------------------
# Step 4: Restart and confirm the new interface
# --------------------------------------------------------------------------
step4_restart_confirm() {
    log "Step 4: Restart the domain and confirm both interfaces"

    finding "Lab 8.1 Step 10 uses 'virsh reboot' to apply the new NIC. A soft reboot does NOT reload the persistent domain XML, so the config-only interface will not appear. A full stop/start (virsh destroy/shutdown then start) is required - this script does that. (Alternatively, 'virsh attach-interface --live --config' applies it without a restart.)"

    info "Stopping the domain (so the new persistent device is instantiated on next start)"
    shutdown_vm "$VM_NAME" 24
    info "Starting the domain"
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    wait_for_state "$VM_NAME" running 12 || true

    local domiflist rows
    domiflist="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null || true)"
    info "virsh domiflist $VM_NAME:"; printf '%s\n' "$domiflist"
    assert_contains "$domiflist" "$ADD_NETWORK" "Step 4: an interface on '$ADD_NETWORK' is attached"
    rows="$(printf '%s\n' "$domiflist" | awk 'NF && $1!="Interface" && $1!~/^-+$/' | wc -l | tr -d ' ')"
    if (( rows >= 2 )); then
        pass "Step 4: host side shows $rows interfaces, each with its own MAC"
    else
        fail "Step 4: host side shows $rows interface(s), expected >= 2"
    fi

    # Guest-side confirmation (best-effort; needs reachability).
    local addr
    if ! addr="$(wait_for_vm_addr lease 24)"; then addr="$(vm_addr_any "$VM_NAME" || true)"; fi
    if [[ -n "$addr" ]] && vm_ssh_ok "$addr"; then
        local ipout nifs
        ipout="$(vm_ssh "$addr" 'ip -o addr show' || true)"
        info "guest ip addr:"; printf '%s\n' "$ipout"
        nifs="$(printf '%s\n' "$ipout" | awk '{print $2}' | grep -v '^lo$' | sort -u | wc -l | tr -d ' ')"
        if (( nifs >= 2 )); then
            pass "Step 4: guest shows $nifs non-loopback interfaces"
        else
            warn "Step 4: guest shows $nifs non-loopback interface(s); the new NIC may still be acquiring an address"
        fi
    else
        warn "Step 4: guest not reachable over SSH; skipped in-guest interface check"
    fi

    finding "Lab 8.1 Step 12 uses virt-viewer to check the guest; on a headless OCI host use 'virsh console' or SSH instead."
}

main() {
    preflight
    step1_dump_xml
    step2_add_interface
    step3_validate
    step4_restart_confirm
    summary
}

main "$@"
