#!/usr/bin/env bash
# Run from the installed Proxmox checkout; no router/client DNS changes.
set -euo pipefail
[[ $# == 2 && "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^dns0[12]$ ]] || { echo 'Usage: proxmox-local-dns.sh <ctid> <dns01|dns02>' >&2; exit 1; }
ID="$1"; EXPECTED="$2"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $EUID == 0 ]] && command -v pct >/dev/null || { echo 'Run as root on the Proxmox host' >&2; exit 1; }
pct config "$ID" | grep -Fxq "hostname: $EXPECTED" || { echo 'Guest hostname differs' >&2; exit 1; }
[[ "$(pct status "$ID")" == 'status: running' ]] || { echo 'Guest must already be running' >&2; exit 1; }
WORK="$(pct exec "$ID" -- mktemp -d /root/homelab-local-dns.XXXXXXXX)"
trap 'pct exec "$ID" -- rm -f "$WORK/install.py" "$WORK/records.json"; pct exec "$ID" -- rmdir "$WORK"' EXIT
pct push "$ID" "$REPO/scripts/deploy/install-local-dns.py" "$WORK/install.py" --perms 600
pct push "$ID" "$REPO/configs/local-services.json" "$WORK/records.json" --perms 600
pct exec "$ID" -- python3 "$WORK/install.py" "$WORK/records.json"
