#!/bin/bash
set -euo pipefail

NAME="vm-test2"
BRIDGE="vmbr1"
CORES=2
MEMORY=2048
DISK=8
CIUSER="homelab"
SSH_KEY="/root/.ssh/id_rsa.pub"

VMID=$(pvesh get /cluster/nextid)

IMAGES=$(pvesm status --content images | awk 'NR>1 && $3=="active" {print $1}')
IMAGE_COUNT=$(printf '%s\n' "$IMAGES" | awk 'NF' | wc -l)

[ "$IMAGE_COUNT" -eq 1 ] || {
    echo "Expected exactly one active images storage; found $IMAGE_COUNT"
    printf '%s\n' "$IMAGES"
    exit 1
}

STORAGE="$IMAGES"

IMPORTS=$(pvesm list local --content import |
    awk '$1 ~ /debian-13-genericcloud-amd64\.qcow2$/ {print $1}')
IMPORT_COUNT=$(printf '%s\n' "$IMPORTS" | awk 'NF' | wc -l)

[ "$IMPORT_COUNT" -eq 1 ] || {
    echo "Expected exactly one Debian 13 genericcloud image; found $IMPORT_COUNT"
    printf '%s\n' "$IMPORTS"
    exit 1
}

IMAGE="$IMPORTS"

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