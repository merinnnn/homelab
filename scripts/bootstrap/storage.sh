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

echo "--- FINAL STATE ---"

if grep -R 'thin_pool_autoextend_' \
    /etc/lvm/lvmlocal.conf \
    /etc/lvm/lvm.conf 2>/dev/null |
    grep -v '^[^:]*:[[:space:]]*#' |
    grep -q .; then
    echo "Active custom thin-pool autoextend configuration found"
    exit 1
fi
echo "Autoextend: none"

lvmconfig --validate

[ "$(lvs --noheadings -o seg_monitor "$POOL" | xargs)" = "monitored" ] || {
    echo "Thin pool is not monitored"
    exit 1
}
echo "Thin pool monitoring: active"

[ "$(systemctl is-enabled fstrim.timer)" = "enabled" ] || {
    echo "fstrim.timer is not enabled"
    exit 1
}

[ "$(systemctl is-active fstrim.timer)" = "active" ] || {
    echo "fstrim.timer is not active"
    exit 1
}
echo "TRIM: enabled and active"

if [ -n "$(systemctl --failed --no-legend --plain)" ]; then
    systemctl --failed --no-pager
    exit 1
fi
echo "Failed services: 0"

echo "Storage setup complete."