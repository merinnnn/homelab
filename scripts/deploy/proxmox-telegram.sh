#!/usr/bin/env bash
# Run from pve02's checkout. The private credential file never enters a payload.
set +x
set -euo pipefail
[[ $# == 2 && "$1" =~ ^[0-9]+$ ]] || { echo 'Usage: proxmox-telegram.sh <vmid> <private-credential-json>' >&2; exit 1; }
VMID="$1"; CREDENTIALS="$2"
[[ "$(id -u)" == 0 && "$(hostname -s)" == pve02 && "$VMID" == 100 ]] || { echo 'Expected root on pve02 and permanent apps01 VM100' >&2; exit 1; }
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected apps01 guest' >&2; exit 1; }
[[ -f "$CREDENTIALS" && ! -L "$CREDENTIALS" && "$(stat -c '%u:%a' "$CREDENTIALS")" == 0:600 ]] || { echo 'Credentials require a root-owned mode600 file outside Git' >&2; exit 1; }
case "$(readlink -f "$CREDENTIALS")" in "$REPO"/*) echo 'Credentials must stay outside the checkout' >&2; exit 1;; esac
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
tar -czf "$WORK/payload.tgz" -C "$REPO" scripts/deploy/setup-telegram.py configs/docker/monitoring/alertmanager.default.yml
PAYLOAD="$(base64 -w0 "$WORK/payload.tgz")"
qm guest exec "$VMID" --timeout 120 -- bash -e -c "umask 022; install -d -m 0755 /opt/homelab/telegram-payload; printf '%s' '$PAYLOAD' | base64 -d | tar -xzf - -C /opt/homelab/telegram-payload" > "$WORK/result.json"
python3 - "$WORK/result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if not result.get('exited') or result.get('exitcode', 1):
    raise SystemExit('Telegram source transfer failed')
print('Telegram source transfer verified')
PY
qm guest exec "$VMID" --timeout 120 --pass-stdin -- python3 /opt/homelab/telegram-payload/scripts/deploy/setup-telegram.py --input-stdin < "$CREDENTIALS" > "$WORK/setup-result.json"
python3 - "$WORK/setup-result.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as stream:
        result = json.load(stream)
    if not result.get('exited') or result.get('exitcode', 1):
        raise ValueError('guest preparation failed')
except Exception:
    raise SystemExit('Telegram receiver preparation failed; verify private bot access, a unique private /start or explicit chat ID, and guest validation state') from None
# Never dump arbitrary guest stdout/stderr or the result JSON, even on failure.
print('Private Telegram receiver preparation verified. Reapply monitoring and test delivery.')
PY
