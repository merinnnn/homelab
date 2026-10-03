#!/bin/bash
set -euo pipefail

VMID="$1"

MAC=$(qm config "$VMID" |
    sed -n 's/^net0:.*virtio=\([^,]*\).*/\L\1/p')

[ -n "$MAC" ] || {
    echo "Could not determine MAC for VM $VMID"
    exit 1
}

IP=$(awk -v mac="$MAC" '
    tolower($2) == mac { print $3 }
' /var/lib/misc/dnsmasq.leases)

IP_COUNT=$(printf '%s\n' "$IP" | awk 'NF' | wc -l)

[ "$IP_COUNT" -eq 1 ] || {
    echo "Expected exactly one DHCP lease for $MAC; found $IP_COUNT"
    printf '%s\n' "$IP"
    exit 1
}

ssh "homelab@$IP" '
set -e
sudo apt-get update
sudo apt-get install -y qemu-guest-agent
'

echo "Provisioned VM $VMID at $IP"