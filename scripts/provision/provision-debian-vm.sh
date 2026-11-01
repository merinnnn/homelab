#!/usr/bin/env bash
set -euo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || {
    echo "Usage: $0 <vmid> [user]"
    exit 1
}

VMID="$1"
USER="${2:-homelab}"

[[ "$VMID" =~ ^[0-9]+$ ]] || {
    echo "Invalid VMID: expected decimal digits" >&2
    exit 1
}

[[ "$USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] || {
    echo "Invalid SSH user" >&2
    exit 1
}

qm config "$VMID" >/dev/null

MAC="$(
    qm config "$VMID" |
    sed -n 's/^net0:.*virtio=\([^,]*\).*/\L\1/p'
)"

[ -n "$MAC" ] || {
    echo "Could not determine MAC for VM $VMID"
    exit 1
}

IP="$(
    awk -v mac="$MAC" -v now="$(date +%s)" '
        $1 ~ /^[0-9]+$/ && ($1 == 0 || $1 > now) && tolower($2) == mac { print $3 }
    ' /var/lib/misc/dnsmasq.leases
)"

IP_COUNT="$(printf '%s\n' "$IP" | awk 'NF' | wc -l)"

[ "$IP_COUNT" -eq 1 ] || {
    echo "Expected exactly one DHCP lease for $MAC; found $IP_COUNT"
    printf '%s\n' "$IP"
    exit 1
}

ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o "HostKeyAlias=homelab-vm-${VMID}-${MAC//:/}" \
    "$USER@$IP" '
set -e
sudo apt-get update
sudo apt-get install -y qemu-guest-agent
# Debian uses device activation for this static unit at boot.
sudo systemctl start qemu-guest-agent
sudo systemctl is-active --quiet qemu-guest-agent
'

echo "Provisioned VM $VMID at $IP"