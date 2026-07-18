#!/usr/bin/env bash
#
# bootstrap.sh - one-time setup for the templates-kvm kcli deployment.
#
# Installs kcli on the Oracle Linux 9 KVM host and downloads the golden
# Oracle Linux 9 cloud image as the kcli image named "ol9". Safe to re-run:
# kcli is skipped if already installed and the image is skipped if present.
#
# Run this on the KVM host (as the "opc" user, which is already in the
# libvirt group from install-kvm). It uses sudo for the package steps.

set -euo pipefail

# Golden Oracle Linux 9 KVM cloud image (x86_64, matches the lab's
# VM.Standard.E5.Flex shape and the OL 9.8 host). Update to the current OL9
# build from https://yum.oracle.com/oracle-linux-templates.html as needed.
OL9_IMAGE_URL="${OL9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u8/x86_64/OL9U8_x86_64-kvm-b293.qcow2}"

# Expected SHA256 of the image above (from the Oracle templates page). Leave
# empty to skip verification; set to "" via env to bypass for a custom URL.
OL9_IMAGE_SHA256="${OL9_IMAGE_SHA256:-b12103391327abee8090686759c0d62dac9a7af2bf0f45fdf6b0d085a0fbb52b}"

# kcli name and storage pool for the downloaded image.
IMAGE_NAME="${IMAGE_NAME:-ol9}"
POOL="${POOL:-default}"

log() { printf '\n==> %s\n' "$*"; }

install_kcli() {
    if command -v kcli >/dev/null 2>&1; then
        log "kcli already installed: $(kcli version 2>/dev/null | head -n1)"
        return
    fi

    log "Installing kcli from the karmab COPR repository"
    sudo dnf -y install dnf-plugins-core
    sudo dnf -y copr enable karmab/kcli
    sudo dnf -y install kcli
    log "kcli installed: $(kcli version 2>/dev/null | head -n1)"
}

download_image() {
    if kcli list image 2>/dev/null | grep -qw "${IMAGE_NAME}"; then
        log "Golden image '${IMAGE_NAME}' already present; skipping download"
        return
    fi

    log "Downloading golden Oracle Linux 9 image as '${IMAGE_NAME}'"
    log "Source: ${OL9_IMAGE_URL}"
    kcli download image -P url="${OL9_IMAGE_URL}" -P pool="${POOL}" "${IMAGE_NAME}"
    log "Golden image '${IMAGE_NAME}' is ready in pool '${POOL}'"
}

# Best-effort SHA256 check of the downloaded volume. kcli stores it as
# <pool path>/<IMAGE_NAME>; the file is owned by libvirt, so read it via sudo.
verify_checksum() {
    if [ -z "${OL9_IMAGE_SHA256}" ]; then
        log "OL9_IMAGE_SHA256 is empty; skipping checksum verification"
        return
    fi

    local pooldir imgpath actual
    pooldir=$(sudo virsh pool-dumpxml "${POOL}" 2>/dev/null \
        | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -n1)
    pooldir="${pooldir:-/var/lib/libvirt/images}"
    imgpath="${pooldir}/${IMAGE_NAME}"

    if [ ! -f "${imgpath}" ] && ! sudo test -f "${imgpath}"; then
        log "Could not locate ${imgpath}; skipping checksum verification"
        return
    fi

    log "Verifying SHA256 of ${imgpath}"
    actual=$(sudo sha256sum "${imgpath}" | awk '{print $1}')
    if [ "${actual}" != "${OL9_IMAGE_SHA256}" ]; then
        echo "ERROR: checksum mismatch for ${imgpath}" >&2
        echo "  expected: ${OL9_IMAGE_SHA256}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
    log "Checksum OK"
}

install_kcli
download_image
verify_checksum

log "Bootstrap complete. Next: kcli create plan -f kcli_plan.yml templatevms"
