#!/usr/bin/env bash
# Run from the installed pve02 checkout; this payload contains no secrets.
set -euo pipefail
[[ $# == 1 && "$1" =~ ^[0-9]+$ ]] || { echo 'Usage: proxmox-monitoring.sh <vmid>' >&2; exit 1; }
VMID="$1"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected apps01 guest' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
tar -czf "$WORK/payload.tgz" -C "$REPO" scripts/deploy/monitoring.sh configs/docker/monitoring
PAYLOAD="$(base64 -w0 "$WORK/payload.tgz")"
guest_exec() {
    local status=0
    if qm guest exec "$VMID" --timeout 1800 -- bash -e -c "$1" > "$WORK/result.json"; then
        python3 - "$WORK/result.json" <<'PY' || status=$?
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
sys.stdout.write(result.get('out-data', ''))
sys.stderr.write(result.get('err-data', ''))
if not result.get('exited'):
    raise SystemExit('Guest command did not complete')
raise SystemExit(result.get('exitcode', 1))
PY
    else status=$?; cat "$WORK/result.json" >&2; fi
    return "$status"
}
guest_exec "umask 022; install -d -m 0755 /opt/homelab/monitoring-payload; printf '%s' '$PAYLOAD' | base64 -d | tar -xzf - -C /opt/homelab/monitoring-payload"
guest_exec 'bash /opt/homelab/monitoring-payload/scripts/deploy/monitoring.sh'
