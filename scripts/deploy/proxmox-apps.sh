#!/usr/bin/env bash
# Run from a checkout on the Proxmox host. Authentication uses normal SSH config.
set -euo pipefail
[[ $# -ge 2 ]] || { echo 'Usage: proxmox-apps.sh <install|init|publish> <vmid> [guest-ip] [private-account-json]' >&2; exit 1; }
ACTION="$1"; VMID="$2"
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo 'Invalid VMID' >&2; exit 1; }
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected apps01 guest' >&2; exit 1; }
STATE="/var/lib/homelab/apps01-$VMID"
install -d -m 0700 "$STATE"
guest_exec() {
    local output status=0
    output="$(mktemp)"
    qm guest exec "$VMID" --timeout 1800 -- bash -e -c "$1" > "$output" || status=$?
    if [[ "$status" -eq 0 ]]; then
        python3 - "$output" <<'PY' || status=$?
import json,sys
with open(sys.argv[1]) as f: r=json.load(f)
sys.stdout.write(r.get('out-data',''))
sys.stderr.write(r.get('err-data',''))
if not r.get('exited'): raise SystemExit('Guest command did not complete')
raise SystemExit(r.get('exitcode',1))
PY
        status=$?
    else cat "$output" >&2; fi
    rm -f "$output"
    return "$status"
}
case "$ACTION" in
    install)
        [[ $# -eq 2 ]] || { echo 'install takes only a VMID' >&2; exit 1; }
        archive="$(mktemp)"
        trap 'rm -f "$archive"' EXIT
        tar -C "$REPO" -czf "$archive" scripts/provision/install-docker-debian.sh scripts/deploy/uptime-kuma.sh scripts/deploy/setup-uptime-kuma.cjs configs/docker/uptime-kuma/docker-compose.yml
        payload="$(base64 -w0 "$archive")"
        guest_exec "install -d -m 0700 /opt/homelab/repo; printf '%s' '$payload' | base64 -d | tar -xzf - -C /opt/homelab/repo"
        guest_exec 'bash /opt/homelab/repo/scripts/provision/install-docker-debian.sh'
        guest_exec 'bash /opt/homelab/repo/scripts/deploy/uptime-kuma.sh /opt/homelab/repo/configs/docker/uptime-kuma/docker-compose.yml'
        ;;
    init)
        [[ $# -eq 4 ]] || { echo 'init requires VMID, guest IPv4 and private account JSON file' >&2; exit 1; }
        IP="$3"; ACCOUNT="$4"
        [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid guest IPv4' >&2; exit 1; }
        [[ -f "$ACCOUNT" && "$(stat -c %a "$ACCOUNT")" == 600 ]] || { echo 'Account JSON must be a private mode-600 file outside the checkout' >&2; exit 1; }
        case "$(readlink -f "$ACCOUNT")" in "$REPO"/*) echo 'Credentials must be outside the checkout' >&2; exit 1;; esac
        MAC="$(qm config "$VMID" | sed -n 's/^net0:.*virtio=\([^,]*\).*/\L\1/p')"
        ALIAS="homelab-vm-$VMID-${MAC//:/}"
        cat "$ACCOUNT" | ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$ALIAS" "${GUEST_USER:-homelab}@$IP" \
            'set -e; stack=/opt/homelab/uptime-kuma; cid=$(sudo docker compose --project-name homelab-monitoring --env-file "$stack/.env" -f "$stack/compose.yml" ps -q uptime-kuma); sudo docker cp /opt/homelab/repo/scripts/deploy/setup-uptime-kuma.cjs "$cid:/tmp/setup.cjs" >/dev/null; sudo docker exec -i "$cid" node /tmp/setup.cjs'
        touch "$STATE/account-initialized"
        ;;
    publish)
        [[ $# -eq 2 && -f "$STATE/account-initialized" ]] || { echo 'Initialize the account before LAN exposure' >&2; exit 1; }
        guest_exec 'KUMA_BIND_IP=0.0.0.0 bash /opt/homelab/repo/scripts/deploy/uptime-kuma.sh /opt/homelab/repo/configs/docker/uptime-kuma/docker-compose.yml'
        ;;
    *) echo 'Unknown action' >&2; exit 1;;
esac
