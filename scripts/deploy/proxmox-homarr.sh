#!/usr/bin/env bash
# Run from the installed pve02 checkout; payload contains public source only.
set -euo pipefail
set +x
[[ $# == 1 && "$1" == 100 ]] || { echo 'Usage: proxmox-homarr.sh 100' >&2; exit 1; }
[[ "$(id -u)" == 0 && "$(hostname -s)" == pve02 ]] || { echo 'Run as root on pve02' >&2; exit 1; }
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
VMID="$1"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected permanent apps01 guest' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
tar -czf "$WORK/payload.tgz" -C "$REPO" scripts/deploy/homarr.sh scripts/deploy/bootstrap-homarr.py configs/docker/homarr
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
    else status=$?; echo 'Guest-agent transport failed; inspect privately on the node' >&2; fi
    return "$status"
}
guest_exec "umask 022; install -d -m 0755 /opt/homelab/homarr-payload; printf '%s' '$PAYLOAD' | base64 -d | tar -xzf - -C /opt/homelab/homarr-payload"
guest_exec 'bash /opt/homelab/homarr-payload/scripts/deploy/homarr.sh'

guest_exec 'cid=$(docker compose --project-name homelab-homarr --env-file /opt/homelab/homarr/current/.env -f /opt/homelab/homarr/current/compose.yml ps -q homarr); python3 /opt/homelab/homarr-payload/scripts/deploy/bootstrap-homarr.py --container "$cid" --services /opt/homelab/homarr-payload/configs/docker/homarr/services.json'
