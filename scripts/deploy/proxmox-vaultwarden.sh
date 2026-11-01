#!/usr/bin/env bash
# Run from the owning Proxmox node's actual repository checkout.
set +x
set -euo pipefail
umask 077
[[ $# -ge 2 && "$2" == 100 && ( "$1" == install || "$1" == invite ) ]] || { echo 'Usage: proxmox-vaultwarden.sh <install|invite> 100 [private-owner-json-file]' >&2; exit 1; }
ACTION="$1"; VMID="$2"
[[ $EUID -eq 0 && "$(hostname -s)" == pve02 ]] || { echo 'Run as root on pve02' >&2; exit 1; }
qm status "$VMID" | grep -Fxq 'status: running'
qm config "$VMID" | grep -Fxq 'name: apps01'
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
guest_exec() {
    local output status=0
    output="$(mktemp)"
    qm guest exec "$VMID" --timeout 1800 --pass-stdin -- bash -e -c "$1" > "$output" || status=$?
    if [[ "$status" -eq 0 ]]; then
        python3 - "$output" <<'PY' || status=$?
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
sys.stdout.write(result.get('out-data',''));sys.stderr.write(result.get('err-data',''))
if not result.get('exited'): raise SystemExit('Guest command did not complete')
raise SystemExit(result.get('exitcode',1))
PY
    fi
    # Do not dump arbitrary QGA response bodies on a failed secret-input action.
    rm -f "$output"
    return "$status"
}
case "$ACTION" in
    install)
        [[ $# -eq 2 ]] || { echo 'Install takes only the allocated VMID' >&2; exit 1; }
        archive="$(mktemp)"
        trap 'rm -f "$archive"' EXIT
        tar -C "$REPO" -czf "$archive" scripts/deploy/vaultwarden.sh scripts/deploy/vaultwarden-runtime.py configs/docker/vaultwarden/compose.json scripts/deploy/backup-vaultwarden.py configs/systemd/homelab-vaultwarden-backup.service configs/systemd/homelab-vaultwarden-backup.timer
        guest_exec 'umask 077; if [[ ! -d /opt/homelab/repo ]]; then install -d -m 700 /opt/homelab/repo; fi; tar -xzf - -C /opt/homelab/repo' < "$archive"
        guest_exec 'bash /opt/homelab/repo/scripts/deploy/vaultwarden.sh /opt/homelab/repo/configs/docker/vaultwarden/compose.json' </dev/null
        guest_exec 'set -e; for unit in homelab-vaultwarden-backup.service homelab-vaultwarden-backup.timer; do source=/opt/homelab/repo/configs/systemd/$unit; target=/etc/systemd/system/$unit; if [[ -e "$target" ]]; then cmp -s "$source" "$target" || { echo "Unknown existing backup unit; preserved" >&2; exit 1; }; fi; install -m 644 "$source" "$target"; done; systemctl daemon-reload; systemctl enable --now homelab-vaultwarden-backup.timer' </dev/null
        ;;
    invite)
        [[ $# -eq 3 && -f "$3" && ! -L "$3" && "$(stat -c %a "$3")" == 600 && "$(stat -c %u "$3")" == 0 ]] || { echo 'Provide a root-owned mode-600 owner JSON file outside Git' >&2; exit 1; }
        case "$(readlink -f "$3")" in "$REPO"/*) echo 'Owner input must remain outside the checkout' >&2; exit 1;; esac
        guest_exec 'stack=/opt/homelab/vaultwarden; cid=$(docker compose --project-name homelab-vaultwarden --env-file "$stack/.env" -f "$stack/compose.json" ps -q vaultwarden); python3 /opt/homelab/repo/scripts/deploy/vaultwarden-runtime.py invite --container "$cid" --owner-stdin' < "$3"
        ;;
esac
