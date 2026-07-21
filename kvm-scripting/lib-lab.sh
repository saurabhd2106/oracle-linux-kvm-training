#!/usr/bin/env bash
#
# lib-lab.sh - shared helpers for the KVM lab test scripts (Labs 5.1-14.1) and
# the unified cleanup. Source this from a script AFTER setting NAME, e.g.:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   NAME="test-lab-5.1"
#   . "${SCRIPT_DIR}/../lib-lab.sh"
#
# It provides the PASS/WARN/FAIL logging harness used by test-lab-4.1-*.sh,
# assertion helpers, guest-SSH helpers, NoCloud seed-ISO building, and a FINDINGS
# facility so each lab can report incorrect lab steps or better alternates at the
# end of its run (even when the RESULT is PASSED).
#
# All helpers read their configuration (NAME, SSH_KEY, SSH_USERS, SEED_DIR,
# VM_NAME) from the caller's environment at call time, so a script may set or
# override any of them before or after sourcing this file.

# --------------------------------------------------------------------------
# Defaults (override in the caller before use if needed)
# --------------------------------------------------------------------------
NAME="${NAME:-lab}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
# SSH users to try, in order (cloud-init lands the key on the default user).
if [[ -z "${SSH_USERS+x}" ]]; then
    SSH_USERS=(cloud-user opc root)
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FINDINGS=()

# --------------------------------------------------------------------------
# Logging / assertions
# --------------------------------------------------------------------------
log()  { printf '\n[%s] ==> %s\n' "$NAME" "$*"; }
info() { printf '[%s]     %s\n' "$NAME" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[%s] PASS: %s\n' "$NAME" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[%s] FAIL: %s\n' "$NAME" "$*" >&2; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[%s] WARN: %s\n' "$NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }

# finding <text> - record a lab-quality observation for the FINDINGS block.
finding() { FINDINGS+=("$*"); }

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
# Guest SSH helpers
# --------------------------------------------------------------------------

# vm_ssh <addr> <cmd> - run <cmd> on the guest, trying each SSH user in order.
# Prints the remote stdout; returns 0 on first success.
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

# vm_ssh_retry <addr> <cmd> [tries] - retry vm_ssh so cloud-init/sshd can settle.
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

# vm_ssh_ok <addr> - true if the guest answers SSH at all.
vm_ssh_ok() {
    local addr="$1" out
    out="$(vm_ssh "$addr" 'echo ok' 2>/dev/null || true)"
    [[ "$out" == "ok" ]]
}

# --------------------------------------------------------------------------
# libvirt guest-address discovery
# --------------------------------------------------------------------------

# wait_for_vm_addr [source] [tries] - wait for VM_NAME to acquire an IPv4.
# source: "lease" (default) or "arp". Prints the first IPv4 found, or nothing.
wait_for_vm_addr() {
    local source="${1:-lease}" tries="${2:-30}" i out addr
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

# vm_addr_any [name] - best-effort single IPv4 for a domain from lease then arp.
vm_addr_any() {
    local dom="${1:-$VM_NAME}" out addr
    for src in "" "--source arp"; do
        out="$(sudo virsh domifaddr "$dom" $src 2>/dev/null || true)"
        addr="$(printf '%s' "$out" | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')"
        [[ -n "$addr" ]] && { printf '%s' "$addr"; return 0; }
    done
    return 1
}

# wait_for_state <name> <state> [tries] - poll domstate until it matches.
wait_for_state() {
    local dom="$1" want="$2" tries="${3:-24}" i state
    for ((i = 0; i < tries; i++)); do
        state="$(sudo virsh domstate "$dom" 2>/dev/null || true)"
        [[ "$state" == "$want" ]] && return 0
        sleep 5
    done
    return 1
}

# shutdown_vm <name> [tries] - graceful shutdown, force-destroy if it hangs.
shutdown_vm() {
    local dom="$1" tries="${2:-24}"
    sudo virsh shutdown "$dom" >/dev/null 2>&1 || true
    if ! wait_for_state "$dom" "shut off" "$tries"; then
        sudo virsh destroy "$dom" >/dev/null 2>&1 || true
        sleep 2
    fi
}

# --------------------------------------------------------------------------
# NoCloud seed ISO
# --------------------------------------------------------------------------

# build_seed_iso <out> - build a NoCloud seed from SEED_DIR, including only the
# files that exist among user-data, meta-data, network-config. Uses xorriso
# (genisoimage was removed on OL9): prefers xorrisofs, falls back to xorriso.
build_seed_iso() {
    local out="$1" files=()
    local f
    for f in user-data meta-data network-config; do
        [[ -f "$SEED_DIR/$f" ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 1
    ( cd "$SEED_DIR" && \
      if command -v xorrisofs >/dev/null 2>&1; then
          sudo xorrisofs -output "$out" -volid cidata -joliet -rock "${files[@]}"
      else
          sudo xorriso -as mkisofs -output "$out" -volid cidata -joliet -rock "${files[@]}"
      fi )
}

# ensure_iso_tool - make sure xorriso/xorrisofs is present.
ensure_iso_tool() {
    if ! command -v xorrisofs >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
        sudo dnf install -y xorriso
    fi
    command -v xorrisofs >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Summary + findings
# --------------------------------------------------------------------------

# print_findings - print the recorded FINDINGS block, if any.
print_findings() {
    (( ${#FINDINGS[@]} > 0 )) || return 0
    printf '\n[%s] ==> FINDINGS (lab-quality notes and better alternates)\n' "$NAME"
    local i
    for ((i = 0; i < ${#FINDINGS[@]}; i++)); do
        printf '[%s] FINDING %d: %s\n' "$NAME" "$((i + 1))" "${FINDINGS[$i]}"
    done
}

# summary - print PASS/WARN/FAIL counts, the findings, and RESULT. Exits 1 on
# any FAIL.
summary() {
    log "Summary"
    printf '[%s] PASS: %d   WARN: %d   FAIL: %d\n' "$NAME" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    print_findings
    if (( FAIL_COUNT > 0 )); then
        printf '\n[%s] RESULT: FAILED (%d assertion(s) failed)\n' "$NAME" "$FAIL_COUNT"
        exit 1
    fi
    printf '\n[%s] RESULT: PASSED\n' "$NAME"
}
