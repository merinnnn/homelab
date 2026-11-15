#!/usr/bin/env bash
# Run from the installed pve02 checkout. Transfer public source only.
set -euo pipefail
set +x
[[ $# == 1 && "$1" == 100 ]] || { echo 'Usage: proxmox-n8n.sh 100' >&2; exit 1; }
[[ "$(id -u)" == 0 && "$(hostname -s)" == pve02 ]] || { echo 'Run as root on pve02' >&2; exit 1; }
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
VMID="$1"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected permanent apps01 guest' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
tar -czf "$WORK/payload.tgz" -C "$REPO" scripts/deploy/n8n.sh scripts/deploy/n8n-bootstrap.py scripts/deploy/backup-n8n.py configs/docker/n8n configs/systemd/homelab-n8n-backup.service configs/systemd/homelab-n8n-backup.timer
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
    else status=$?; echo 'Guest-agent transport failed; inspect privately on node' >&2; fi
    return "$status"
}
guest_exec "umask 022; install -d -m 0755 /opt/homelab/n8n-payload; printf '%s' '$PAYLOAD' | base64 -d | tar -xzf - -C /opt/homelab/n8n-payload"
guest_exec 'bash /opt/homelab/n8n-payload/scripts/deploy/n8n.sh'

guest_exec 'install -m 0644 /opt/homelab/n8n-payload/configs/systemd/homelab-n8n-backup.service /etc/systemd/system/homelab-n8n-backup.service; install -m 0644 /opt/homelab/n8n-payload/configs/systemd/homelab-n8n-backup.timer /etc/systemd/system/homelab-n8n-backup.timer; systemctl daemon-reload'
printf 'Owner bootstrap must complete before enabling the backup timer and proxy route.\n'
