#!/usr/bin/env bash
set -euo pipefail

POOL="$(lvs --noheadings -o vg_name,lv_name,segtype |
    awk '$3=="thin-pool" {print $1"/"$2; exit}')"

DISK="$(lsblk -ndo NAME,TYPE |
    awk '$2=="disk" {print "/dev/"$1; exit}')"

[ -n "$POOL" ] || { echo "No thin pool found"; exit 1; }
[ -n "$DISK" ] || { echo "No disk found"; exit 1; }

VG="${POOL%%/*}"

# Remove our old auto-extension policy if present
if grep -q 'thin_pool_autoextend_' /etc/lvm/lvmlocal.conf; then
    cp -an /etc/lvm/lvmlocal.conf /etc/lvm/lvmlocal.conf.pre-homelab

    sed -i '/^[[:space:]]*activation[[:space:]]*{/,/^[[:space:]]*}/{
        /thin_pool_autoextend_threshold/d
        /thin_pool_autoextend_percent/d
        /^[[:space:]]*activation[[:space:]]*{$d
        /^[[:space:]]*}$/d
    }' /etc/lvm/lvmlocal.conf
fi

lvchange --monitor y "$POOL"
systemctl enable --now lvm2-monitor
systemctl enable --now fstrim.timer

echo "--- THIN POOL ---"
lvs -o vg_name,lv_name,lv_size,segtype,data_percent,metadata_percent,seg_monitor "$VG"

echo "--- VG CAPACITY ---"
vgs -o vg_name,vg_size,vg_free "$VG"

echo "--- PROXMOX STORAGE ---"
pvesm status

echo "--- DISK HEALTH ---"
smartctl -H "$DISK"

echo "--- TRIM ---"
systemctl is-enabled fstrim.timer
systemctl is-active fstrim.timer