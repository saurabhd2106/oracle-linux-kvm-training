#!/usr/bin/env bash
#
# lib-vnic.sh - shared helper for discovering a secondary OCI VNIC from the
# instance metadata service (IMDS), used by the Lab 4.1 Option 1/2 scripts.
#
# Source this from a script: . "$(dirname "$0")/lib-vnic.sh"
#
# The secondary VNIC is provisioned by terraform-linux-day1 (set
# secondary_vnic_vms = ["vm1"] and apply). On the host it is exposed via IMDS at
# http://169.254.169.254/opc/v2/vnics/ - no OCI credentials are needed.

IMDS_VNICS_URL="${IMDS_VNICS_URL:-http://169.254.169.254/opc/v2/vnics/}"

# Fetch the raw IMDS VNICs JSON array. Returns non-zero if it cannot be reached.
imds_vnics_json() {
    curl -fsS -m 10 -H "Authorization: Bearer Oracle" "$IMDS_VNICS_URL" 2>/dev/null
}

# Print the secondary VNIC's fields as a single space-separated line:
#   <mac> <private_ip> <gateway> <prefix> <vnic_ocid>
#
# Selection: the entry at index SECONDARY_VNIC_INDEX (default 1, i.e. the first
# VNIC after the primary). Returns non-zero if IMDS is unreachable or there is no
# such VNIC (for example the secondary VNIC has not been attached yet).
#
# Requires python3 (present on Oracle Linux 9 by default) to parse JSON.
get_secondary_vnic() {
    local json
    json="$(imds_vnics_json)" || return 1
    [[ -n "$json" ]] || return 1

    # Pass the JSON via env (not stdin): stdin here is the heredoc program.
    IMDS_JSON="$json" IMDS_IDX="${SECONDARY_VNIC_INDEX:-1}" python3 <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["IMDS_JSON"])
except Exception:
    sys.exit(1)
idx = int(os.environ.get("IMDS_IDX", "1"))
if not isinstance(data, list) or len(data) <= idx:
    sys.exit(1)
v = data[idx]
mac  = v.get("macAddr", "")
ip   = v.get("privateIp", "")
gw   = v.get("virtualRouterIp", "")
cidr = v.get("subnetCidrBlock", "")
ocid = v.get("vnicId", "")
prefix = cidr.split("/")[1] if "/" in cidr else "24"
if not (mac and ip and gw and ocid):
    sys.exit(1)
print(f"{mac} {ip} {gw} {prefix} {ocid}")
PY
}
