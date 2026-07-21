#!/usr/bin/env bash
#
# cleanup-all-labs.sh - single, unified teardown for the KVM Day-2 labs (4.1
# through 14.1, including the Lab 4.1 options). Replaces the three per-lab Lab 4.1
# cleanup scripts.
#
# Every step is best-effort so the script is safe to re-run: a partially cleaned
# host still ends clean. Prints an OK/LEFT line per item and a RESULT of
# CLEAN or INCOMPLETE.
#
# WHERE TO RUN: on the Oracle Linux 9 KVM host, as the "opc" user. Uses sudo for
# nmcli/virsh exactly as the labs do.
#
# SCOPE / SAFETY:
#   By default this removes everything the labs *added on top of* ol-lab-01
#   (pools, extra disks, snapshots, extra VMs, template, backups, sVirt test dir,
#   CPU/NUMA tuning) but LEAVES ol-lab-01, the br0 bridge, and br0-network in
#   place. Pass --bridge (or CLEAN_BRIDGE=1) to ALSO remove ol-lab-01, the
#   br0-network libvirt network, the br0 bridge, and restore the physical NIC to
#   DHCP - the old cleanup-lab-4.1-bridged-network.sh behaviour.
#
#   WARNING: --bridge re-homes the host IP and can briefly drop SSH. Run it from
#   the OCI serial console, not from the SSH session that rides over the NIC.
#
# FLAGS / ENV:
#   --bridge         | CLEAN_BRIDGE=1   also tear down ol-lab-01 + bridge (destructive)
#   --keep-backups   | KEEP_BACKUPS=1   keep Lab 14.1 backups under /mnt/data/backups
#   -h | --help                          show usage

set -euo pipefail

# --------------------------------------------------------------------------
# Config (override via environment if needed; keep in sync with the tests)
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ol-lab-01}"
BRIDGE="${BRIDGE:-br0}"
BRIDGE_PORT="${BRIDGE_PORT:-br0-port1}"
NET_NAME="${NET_NAME:-br0-network}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
SEED_ISO="${SEED_ISO:-${IMAGE_DIR}/${VM_NAME}-seed.iso}"
SEED_DIR="${SEED_DIR:-${HOME}/${VM_NAME}-seed}"

# Lab 5.1
LABPOOL="${LABPOOL:-labpool}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"
DATA_VOL="${DATA_VOL:-data-disk.qcow2}"
# Lab 9.1
APP_VM="${APP_VM:-app-vm}"
DB_VM="${DB_VM:-db-vm}"
CONS_POOL="${CONS_POOL:-consolidation-pool}"
CONS_TARGET="${CONS_TARGET:-/mnt/data/consolidation-pool}"
# Lab 6.1
SNAP_NAME="${SNAP_NAME:-pre-fault-snapshot}"
# Lab 11.1
SVIRT_DIR="${SVIRT_DIR:-/home/opc/svirt-test}"
# Lab 13.1
MASTER_IMG="${MASTER_IMG:-${IMAGE_DIR}/${VM_NAME}-master.qcow2}"
TEMPLATE_VM="${TEMPLATE_VM:-app-vm-01}"
# Lab 14.1
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/data/backups}"
# Lab 4.1 options
OPT1_VM="${OPT1_VM:-ol-lab-01-opt1}"

CLEAN_BRIDGE="${CLEAN_BRIDGE:-0}"
KEEP_BACKUPS="${KEEP_BACKUPS:-0}"

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}
for arg in "$@"; do
    case "$arg" in
        --bridge)       CLEAN_BRIDGE=1 ;;
        --keep-backups) KEEP_BACKUPS=1 ;;
        -h|--help)      usage ;;
        *) printf 'Unknown option: %s (use --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Logging / checks
# --------------------------------------------------------------------------
NAME="cleanup-all"
PASS_COUNT=0
FAIL_COUNT=0

log()  { printf '\n[%s] ==> %s\n' "$NAME" "$*"; }
info() { printf '[%s]     %s\n' "$NAME" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[%s] OK:   %s\n' "$NAME" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[%s] LEFT: %s\n' "$NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Remove a domain completely (definition + storage), best-effort.
nuke_domain() {
    local dom="$1"
    sudo virsh destroy "$dom" >/dev/null 2>&1 || true
    sudo virsh undefine "$dom" --remove-all-storage --snapshots-metadata >/dev/null 2>&1 \
        || sudo virsh undefine "$dom" --remove-all-storage >/dev/null 2>&1 \
        || sudo virsh undefine "$dom" >/dev/null 2>&1 || true
}

# Destroy + undefine a storage pool, best-effort.
nuke_pool() {
    local pool="$1"
    sudo virsh pool-destroy "$pool" >/dev/null 2>&1 || true
    sudo virsh pool-undefine "$pool" >/dev/null 2>&1 || true
}

domain_exists() { sudo virsh dominfo "$1" >/dev/null 2>&1; }
pool_exists()   { sudo virsh pool-info "$1" >/dev/null 2>&1; }

detect_phys_nic() {
    local nic
    nic="$(ip -o link show 2>/dev/null | awk -v br="$BRIDGE" '$0 ~ ("master " br) {sub(/@.*/, "", $2); gsub(/:/, "", $2); print $2; exit}')"
    if [[ -z "$nic" ]]; then
        nic="$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi
    [[ "$nic" == "$BRIDGE" ]] && nic=""
    printf '%s' "$nic"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
    require_command virsh
    require_command ip
    PHYS_NIC="$(detect_phys_nic)"
    cat <<EOF

[$NAME] ==========================================================================
[$NAME] Unified KVM lab cleanup.
[$NAME]   CLEAN_BRIDGE=$CLEAN_BRIDGE (remove $VM_NAME + $BRIDGE + $NET_NAME)
[$NAME]   KEEP_BACKUPS=$KEEP_BACKUPS
EOF
    if [[ "$CLEAN_BRIDGE" == "1" ]]; then
        cat <<EOF
[$NAME] WARNING: --bridge removes '$BRIDGE' and re-homes the host IP; run from the
[$NAME]          OCI serial console. Physical NIC to restore: ${PHYS_NIC:-<none>}
EOF
    fi
    printf '[%s] ==========================================================================\n' "$NAME"
}

# --------------------------------------------------------------------------
# 14.1 - remove external backups
# --------------------------------------------------------------------------
clean_lab14() {
    log "Lab 14.1: external backups"
    if [[ "$KEEP_BACKUPS" == "1" ]]; then
        info "KEEP_BACKUPS=1; leaving $BACKUP_ROOT in place"
        return
    fi
    sudo rm -rf "${BACKUP_ROOT:?}/${VM_NAME}" >/dev/null 2>&1 || true
    sudo rmdir "$BACKUP_ROOT" >/dev/null 2>&1 || true
    info "Removed backups under ${BACKUP_ROOT}/${VM_NAME}"
}

# --------------------------------------------------------------------------
# 13.1 - template VM + master image
# --------------------------------------------------------------------------
clean_lab13() {
    log "Lab 13.1: template deployment ($TEMPLATE_VM) and master image"
    nuke_domain "$TEMPLATE_VM"
    sudo rm -f "${IMAGE_DIR}/${TEMPLATE_VM}.qcow2" "${IMAGE_DIR}/${TEMPLATE_VM}-seed.iso" "$MASTER_IMG" >/dev/null 2>&1 || true
    rm -rf "${HOME}/${TEMPLATE_VM}-seed" >/dev/null 2>&1 || true
    info "Removed $TEMPLATE_VM, its disk/seed, and $MASTER_IMG"
}

# --------------------------------------------------------------------------
# 11.1 - sVirt test dir + fcontext rule; ensure disk back in the default path
# --------------------------------------------------------------------------
clean_lab11() {
    log "Lab 11.1: sVirt test directory and fcontext rule"
    # If the disk was left under the test dir, move it back and repoint the VM.
    local stray="${SVIRT_DIR}/${VM_NAME}.qcow2" orig="${IMAGE_DIR}/${VM_NAME}.qcow2"
    if sudo test -f "$stray"; then
        info "Found stray disk at $stray; moving it back to $orig"
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        sudo mv "$stray" "$orig" >/dev/null 2>&1 || true
        if domain_exists "$VM_NAME"; then
            local tmp=/tmp/${VM_NAME}-cleanup.xml
            sudo virsh dumpxml "$VM_NAME" 2>/dev/null | sed "s#$stray#$orig#g" > "$tmp" 2>/dev/null || true
            sudo virsh define "$tmp" >/dev/null 2>&1 || true
        fi
    fi
    if command -v semanage >/dev/null 2>&1; then
        sudo semanage fcontext -d "${SVIRT_DIR}(/.*)?" >/dev/null 2>&1 || true
    fi
    sudo rm -rf "$SVIRT_DIR" >/dev/null 2>&1 || true
    info "Removed $SVIRT_DIR and its fcontext rule"
}

# --------------------------------------------------------------------------
# 10.x - reset CPU quota, disk I/O cap, and CPU/NUMA pinning on ol-lab-01
# --------------------------------------------------------------------------
clean_lab10() {
    log "Lab 10.x: reset CPU quota / IO cap / pinning on $VM_NAME"
    if ! domain_exists "$VM_NAME"; then
        info "$VM_NAME not present; nothing to reset"
        return
    fi
    sudo virsh schedinfo "$VM_NAME" --set vcpu_quota=-1 --live --config >/dev/null 2>&1 || true
    local tgt
    for tgt in vda vdb; do
        sudo virsh blkdeviotune "$VM_NAME" "$tgt" --total-bytes-sec 0 --live --config >/dev/null 2>&1 || true
    done
    # Broaden vCPU affinity back to all host CPUs.
    local ncpu vcpus v
    ncpu="$(nproc 2>/dev/null || echo 1)"
    vcpus="$(sudo virsh vcpucount "$VM_NAME" --live 2>/dev/null | awk '/current/&&/live/{print $3; exit}')"
    [[ -n "$vcpus" ]] || vcpus=1
    for ((v = 0; v < vcpus; v++)); do
        sudo virsh vcpupin "$VM_NAME" "$v" "0-$((ncpu - 1))" --live --config >/dev/null 2>&1 || true
    done
    sudo virsh numatune "$VM_NAME" --mode preferred --nodeset 0 --config >/dev/null 2>&1 || true
    info "Reset vcpu_quota=-1, IO caps=0, and broadened vCPU affinity"
}

# --------------------------------------------------------------------------
# 9.1 - consolidation VMs + pool
# --------------------------------------------------------------------------
clean_lab9() {
    log "Lab 9.1: $APP_VM / $DB_VM and $CONS_POOL"
    nuke_domain "$APP_VM"
    nuke_domain "$DB_VM"
    if pool_exists "$CONS_POOL"; then
        sudo virsh vol-delete "${DB_VM}-data.qcow2" --pool "$CONS_POOL" >/dev/null 2>&1 || true
        nuke_pool "$CONS_POOL"
    fi
    sudo rm -f "${CONS_TARGET}/${APP_VM}.qcow2" "${CONS_TARGET}/${DB_VM}.qcow2" \
        "${CONS_TARGET}/${APP_VM}-seed.iso" "${CONS_TARGET}/${DB_VM}-seed.iso" \
        "${CONS_TARGET}/${DB_VM}-data.qcow2" >/dev/null 2>&1 || true
    rm -rf "${HOME}/${APP_VM}-seed" "${HOME}/${DB_VM}-seed" >/dev/null 2>&1 || true
    info "Removed $APP_VM, $DB_VM, and $CONS_POOL"
}

# --------------------------------------------------------------------------
# 8.1 - remove the extra 'default' NIC added to ol-lab-01 + saved XML dumps
# --------------------------------------------------------------------------
clean_lab8() {
    log "Lab 8.1: extra NIC on $VM_NAME"
    if domain_exists "$VM_NAME"; then
        # If two interfaces exist and one is on 'default', drop the default one.
        local n_default
        n_default="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | awk '$3=="default"{c++} END{print c+0}')"
        local total
        total="$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | awk 'NF && $1!="Interface" && $1!~/^-+$/{c++} END{print c+0}')"
        if (( total > 1 && n_default > 0 )); then
            sudo virsh detach-interface --domain "$VM_NAME" --type network --config >/dev/null 2>&1 || true
            info "Detached one 'default' network interface (best-effort)"
        else
            info "No extra 'default' interface to remove"
        fi
    fi
    rm -f "${HOME}/${VM_NAME}-before.xml" "${HOME}/${VM_NAME}-after.xml" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# 6.1 - delete lab snapshots
# --------------------------------------------------------------------------
clean_lab6() {
    log "Lab 6.1: snapshots on $VM_NAME"
    if domain_exists "$VM_NAME"; then
        sudo virsh snapshot-delete "$VM_NAME" "$SNAP_NAME" >/dev/null 2>&1 || true
        info "Deleted '$SNAP_NAME' if present"
    fi
}

# --------------------------------------------------------------------------
# 5.1 - detach the data disk, delete volumes, destroy labpool
# --------------------------------------------------------------------------
clean_lab5() {
    log "Lab 5.1: data disk, volumes, and $LABPOOL"
    if domain_exists "$VM_NAME"; then
        sudo virsh detach-disk "$VM_NAME" vdb --live --config >/dev/null 2>&1 || true
        sudo virsh detach-disk "$VM_NAME" vdb --config >/dev/null 2>&1 || true
    fi
    if pool_exists "$LABPOOL"; then
        local v
        for v in "$DATA_VOL" compare-test.qcow2 compare-test.raw; do
            sudo virsh vol-delete "$v" --pool "$LABPOOL" >/dev/null 2>&1 || true
        done
        nuke_pool "$LABPOOL"
    fi
    # Leave the /mnt/data filesystem itself intact (Day-1 provisioned).
    info "Detached vdb, removed lab volumes, and destroyed $LABPOOL (left $DATA_MOUNT filesystem intact)"
}

# --------------------------------------------------------------------------
# 4.1 options - remove option VMs (leave the secondary VNIC, Terraform-managed)
# --------------------------------------------------------------------------
clean_lab4_options() {
    log "Lab 4.1 options: $OPT1_VM (oci-kvm) and option artifacts"
    if command -v oci-kvm >/dev/null 2>&1; then
        sudo oci-kvm destroy --domain "$OPT1_VM" >/dev/null 2>&1 || true
    fi
    nuke_domain "$OPT1_VM"
    sudo rm -f "${IMAGE_DIR}/${OPT1_VM}.qcow2" "${IMAGE_DIR}/${OPT1_VM}-seed.iso" >/dev/null 2>&1 || true
    rm -rf "${HOME}/${OPT1_VM}-seed" >/dev/null 2>&1 || true
    info "Removed $OPT1_VM (secondary VNIC left attached; it is Terraform-managed)"
}

# --------------------------------------------------------------------------
# 4.1 bridge - remove ol-lab-01, br0-network, the bridge; restore the phys NIC
# (only when --bridge / CLEAN_BRIDGE=1)
# --------------------------------------------------------------------------
clean_lab4_bridge() {
    log "Lab 4.1: $VM_NAME, $NET_NAME, and the $BRIDGE bridge"

    info "Removing VM $VM_NAME and its storage"
    nuke_domain "$VM_NAME"
    sudo rm -f "$SEED_ISO" "${IMAGE_DIR}/${VM_NAME}.qcow2" >/dev/null 2>&1 || true
    rm -rf "$SEED_DIR" >/dev/null 2>&1 || true

    info "Removing libvirt network $NET_NAME"
    sudo virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
    sudo virsh net-undefine "$NET_NAME" >/dev/null 2>&1 || true

    info "Deleting bridge connections and restoring $PHYS_NIC to DHCP"
    require_command nmcli
    sudo nmcli connection down "$BRIDGE_PORT" >/dev/null 2>&1 || true
    sudo nmcli connection down "$BRIDGE" >/dev/null 2>&1 || true
    sudo nmcli connection delete "$BRIDGE_PORT" >/dev/null 2>&1 || true
    sudo nmcli connection delete "$BRIDGE" >/dev/null 2>&1 || true

    if [[ -z "$PHYS_NIC" ]]; then
        info "No physical NIC detected to restore; skipping NIC re-home"
        return
    fi
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
# Verify the clean slate
# --------------------------------------------------------------------------
verify() {
    log "Verifying clean slate"

    local vmlist netlist poollist
    vmlist="$(sudo virsh list --all 2>/dev/null || true)"
    poollist="$(sudo virsh pool-list --all 2>/dev/null || true)"

    local d
    for d in "$TEMPLATE_VM" "$APP_VM" "$DB_VM" "$OPT1_VM"; do
        if printf '%s' "$vmlist" | grep -qw "$d"; then fail "$d still present"; else pass "$d is gone"; fi
    done

    local p
    for p in "$LABPOOL" "$CONS_POOL"; do
        if printf '%s' "$poollist" | grep -qw "$p"; then fail "pool $p still present"; else pass "pool $p is gone"; fi
    done

    if sudo test -f "$MASTER_IMG"; then fail "master image still present ($MASTER_IMG)"; else pass "master image gone"; fi
    if [[ -d "$SVIRT_DIR" ]]; then fail "sVirt test dir still present ($SVIRT_DIR)"; else pass "sVirt test dir gone"; fi
    if [[ "$KEEP_BACKUPS" != "1" ]]; then
        if sudo test -d "${BACKUP_ROOT}/${VM_NAME}"; then fail "backups still present"; else pass "backups gone"; fi
    fi

    if [[ "$CLEAN_BRIDGE" == "1" ]]; then
        netlist="$(sudo virsh net-list --all 2>/dev/null || true)"
        if printf '%s' "$vmlist" | grep -qw "$VM_NAME"; then fail "$VM_NAME still present"; else pass "$VM_NAME is gone"; fi
        if printf '%s' "$netlist" | grep -qw "$NET_NAME"; then fail "$NET_NAME still present"; else pass "$NET_NAME is gone"; fi
        if ip link show "$BRIDGE" >/dev/null 2>&1; then fail "bridge $BRIDGE still exists"; else pass "bridge $BRIDGE is gone"; fi
        if [[ -n "$PHYS_NIC" ]]; then
            local phys
            phys="$(ip -4 -o addr show "$PHYS_NIC" 2>/dev/null || true)"
            [[ -n "$phys" ]] && pass "$PHYS_NIC carries an IP again" || fail "$PHYS_NIC has no IP; check console connectivity"
        fi
    else
        info "Left $VM_NAME, $BRIDGE, and $NET_NAME intact (pass --bridge to remove them)"
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
    clean_lab14
    clean_lab13
    clean_lab11
    clean_lab10
    clean_lab9
    clean_lab8
    clean_lab6
    clean_lab5
    clean_lab4_options
    if [[ "$CLEAN_BRIDGE" == "1" ]]; then
        clean_lab4_bridge
    fi
    verify
    summary
}

main "$@"
