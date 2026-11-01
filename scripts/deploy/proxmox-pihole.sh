#!/usr/bin/env bash
# Run from a checkout on the Proxmox host; the password stays outside Git.
set -euo pipefail
[[ $# -eq 2 && "$1" =~ ^[0-9]+$ ]] || { echo 'Usage: proxmox-pihole.sh <ctid> <private-password-file>' >&2; exit 1; }
VMID="$1"; PASSWORD_FILE="$2"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$PASSWORD_FILE" && "$(stat -c %a "$PASSWORD_FILE")" == 600 ]] || { echo 'Password must be in a mode-600 file outside the checkout' >&2; exit 1; }
case "$(readlink -f "$PASSWORD_FILE")" in "$REPO"/*) echo 'Password must be outside the checkout' >&2; exit 1;; esac
pct config "$VMID" | grep -Fxq 'hostname: dns01' || { echo 'Expected dns01 guest' >&2; exit 1; }
COMMIT=f503a65d3a07cb71fd931389f1d3babf718249aa
SHA=0c67c8f8358fede4b4dd8d51b429114461c9bb90ad56ff00ef05637f664bf3ac
CACHE=/var/cache/homelab/pihole
install -d -m 0700 "$CACHE"
INSTALLER="$CACHE/basic-install-$COMMIT.sh"
if [[ ! -f "$INSTALLER" ]]; then
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 --retry 3 \
        "https://raw.githubusercontent.com/pi-hole/pi-hole/$COMMIT/automated%20install/basic-install.sh" -o "$INSTALLER.download"
    printf '%s  %s\n' "$SHA" "$INSTALLER.download" | sha256sum --check --status
    mv "$INSTALLER.download" "$INSTALLER"
fi
printf '%s  %s\n' "$SHA" "$INSTALLER" | sha256sum --check --status
pct exec "$VMID" -- install -d -m 0700 /root/homelab-bootstrap
pct push "$VMID" "$INSTALLER" /root/homelab-bootstrap/basic-install.sh --perms 0600
pct push "$VMID" "$REPO/scripts/deploy/install-pihole-native.sh" /root/homelab-bootstrap/install-pihole-native.sh --perms 0600
pct exec "$VMID" -- env \
    PIHOLE_INSTALLER_FILE=/root/homelab-bootstrap/basic-install.sh \
    PIHOLE_INSTALLER_COMMIT="$COMMIT" PIHOLE_INSTALLER_SHA256="$SHA" \
    PIHOLE_EXPECTED_CORE=v6.5 PIHOLE_EXPECTED_WEB=v6.6.1 PIHOLE_EXPECTED_FTL=v6.8 \
    bash /root/homelab-bootstrap/install-pihole-native.sh --install < "$PASSWORD_FILE"
