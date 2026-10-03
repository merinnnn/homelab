#!/usr/bin/env bash
set -euo pipefail

POOL="$(lvs --noheadings -o vg_name,lv_name,segtype |
    awk '$3=="thin-pool" {print $1"/"$2; exit}')"

[ -n "$POOL" ] || { echo "No thin pool found"; exit 1; }

VG="${POOL%%/*}"

PV="$(pvs --noheadings -o pv_name,vg_name |
    awk -v vg="$VG" '$2==vg {print $1; exit}')"

[ -n "$PV" ] || { echo "No physical volume found for VG $VG"; exit 1; }

DEVICE="$PV"

while [ "$(lsblk -ndo TYPE "$DEVICE")" != "disk" ]; do
    PARENT="$(lsblk -ndo PKNAME "$DEVICE")"
    [ -n "$PARENT" ] || {
        echo "Cannot determine physical disk for $PV"
        exit 1
    }
    DEVICE="/dev/$PARENT"
done

DISK="$DEVICE"

# Remove obsolete homelab auto-extension policy
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

echo "--- DISK HEALTH ($DISK) ---"
smartctl -H "$DISK"

echo "--- TRIM ---"
systemctl is-enabled fstrim.timer
systemctl is-active fstrim.timer