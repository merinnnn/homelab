#!/bin/bash
set -euo pipefail

HOSTNAME="lxc-test2"
BRIDGE="vmbr1"
CORES=1
MEMORY=512
SWAP=256
DISK=4

VMID=$(pvesh get /cluster/nextid)

DEBIAN_TEMPLATES=$(pveam list local | awk '/debian-13-standard/ {print $1}')
TEMPLATE_COUNT=$(printf '%s\n' "$DEBIAN_TEMPLATES" | awk 'NF' | wc -l)

[ "$TEMPLATE_COUNT" -eq 1 ] || {
    echo "Expected exactly one Debian 13 template; found $TEMPLATE_COUNT"
    printf '%s\n' "$DEBIAN_TEMPLATES"
    exit 1
}

TEMPLATE="$DEBIAN_TEMPLATES"

ROOT_STORAGES=$(pvesm status --content rootdir | awk 'NR>1 && $3=="active" {print $1}')
STORAGE_COUNT=$(printf '%s\n' "$ROOT_STORAGES" | awk 'NF' | wc -l)

[ "$STORAGE_COUNT" -eq 1 ] || {
    echo "Expected exactly one active rootdir storage; found $STORAGE_COUNT"
    printf '%s\n' "$ROOT_STORAGES"
    exit 1
}

STORAGE="$ROOT_STORAGES"

ip link show "$BRIDGE" >/dev/null 2>&1 || {
    echo "Bridge $BRIDGE not found"
    exit 1
}

pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --unprivileged 1 \
    --features nesting=1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" \
    --ostype debian \
    --timezone host \
    --onboot 0 \
    --start 0

echo "Created CT $VMID"