#!/usr/bin/env bash
# Run from the pve02 checkout. Transfer public trust certificates only.
set -euo pipefail
[[ $# == 3 && "$1" =~ ^[0-9]+$ ]] || { echo 'Usage: proxmox-reverse-proxy.sh <vmid> <domain> <public-ca-directory>' >&2; exit 1; }
VMID="$1"; DOMAIN="$2"; TRUST="$3"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# Reuse input validation; sourcing this file performs no deployment.
source "$REPO/scripts/deploy/reverse-proxy.sh"
validate_domain "$DOMAIN" || { echo 'Invalid local domain' >&2; exit 1; }
command -v qm >/dev/null || { echo 'Run on the Proxmox host' >&2; exit 1; }
qm config "$VMID" | grep -Fxq 'name: apps01' || { echo 'Expected apps01 guest' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/trust"
for node in pve01 pve02; do
    [[ -f "$TRUST/$node-ca.crt" ]] && ! grep -q 'PRIVATE KEY' "$TRUST/$node-ca.crt" || { echo 'Public CA certificates are required; private keys refused' >&2; exit 1; }
    openssl x509 -in "$TRUST/$node-ca.crt" -noout >/dev/null
    install -m 0644 "$TRUST/$node-ca.crt" "$WORK/trust/$node-ca.crt"
done
tar -czf "$WORK/payload.tgz" -C "$REPO" scripts/deploy/reverse-proxy.sh configs/docker/reverse-proxy -C "$WORK" trust
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
guest_exec "umask 022; install -d -m 0755 /opt/homelab/proxy-payload; printf '%s' '$PAYLOAD' | base64 -d | tar -xzf - -C /opt/homelab/proxy-payload"
guest_exec "bash /opt/homelab/proxy-payload/scripts/deploy/reverse-proxy.sh apply '$DOMAIN' /opt/homelab/proxy-payload/trust"
