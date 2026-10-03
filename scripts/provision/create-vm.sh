#!/usr/bin/env bash
set -euo pipefail

[ $# -ge 1 ] || {
    echo "Usage: $0 <name> [bridge] [ssh-public-key]"
    exit 1
}

NAME="$1"
BRIDGE="${2:-vmbr1}"
SSH_KEY="${3:-/root/.ssh/id_rsa.pub}"

DEBIAN_RELEASE="13"
ARCH="$(dpkg --print-architecture)"

CORES=2
MEMORY=2048
DISK=8
CIUSER="homelab"

VMID="$(pvesh get /cluster/nextid)"

IMPORTS="$(
    for storage in $(pvesm status -content import |
        awk 'NR > 1 && $3 == "active" {print $1}'); do
        pvesm list "$storage" --content import
    done |
    awk -v release="$DEBIAN_RELEASE" -v arch="$ARCH" \
        '$1 ~ "/debian-" release "-genericcloud-" arch "\\.qcow2$" {print $1}'
)"

IMPORT_COUNT="$(printf '%s\n' "$IMPORTS" | awk 'NF' | wc -l)"

[ "$IMPORT_COUNT" -eq 1 ] || {
    echo "Expected exactly one Debian $DEBIAN_RELEASE $ARCH genericcloud image; found $IMPORT_COUNT"
    printf '%s\n' "$IMPORTS"
    exit 1
}

IMAGE="$IMPORTS"

IMAGE_STORAGES="$(
    pvesm status -content images |
    awk 'NR > 1 && $3 == "active" {print $1}'
)"

STORAGE_COUNT="$(printf '%s\n' "$IMAGE_STORAGES" | awk 'NF' | wc -l)"

[ "$STORAGE_COUNT" -eq 1 ] || {
    echo "Expected exactly one active images storage; found $STORAGE_COUNT"
    printf '%s\n' "$IMAGE_STORAGES"
    exit 1
}

STORAGE="$IMAGE_STORAGES"

ip link show "$BRIDGE" >/dev/null 2>&1 || {
    echo "Bridge $BRIDGE not found"
    exit 1
}

[ -f "$SSH_KEY" ] || {
    echo "SSH public key not found: $SSH_KEY"
    exit 1
}

qm create "$VMID" \
    --name "$NAME" \
    --ostype l26 \
    --cpu host \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=$BRIDGE" \
    --agent enabled=1 \
    --onboot 0

qm set "$VMID" \
    --scsi0 "$STORAGE:0,import-from=$IMAGE"

qm resize "$VMID" scsi0 "${DISK}G"

qm set "$VMID" \
    --ide2 "$STORAGE:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --ciuser "$CIUSER" \
    --sshkeys "$SSH_KEY" \
    --ipconfig0 ip=dhcp \
    --ciupgrade 1

echo "Created VM $VMID"