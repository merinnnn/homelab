#!/usr/bin/env bash
set -euo pipefail

THRESHOLD="${THRESHOLD:-80}"
EXTEND="${EXTEND:-10}"

POOL="$(lvs --noheadings -o vg_name,lv_name,segtype |
    awk '$3=="thin-pool" {print $1"/"$2; exit}')"

DISK="$(lsblk -ndo NAME,TYPE |
    awk '$2=="disk" {print "/dev/"$1; exit}')"

[ -n "$POOL" ] || { echo "No thin pool found"; exit 1; }
[ -n "$DISK" ] || { echo "No disk found"; exit 1; }

VG="${POOL%%/*}"

POOL_BYTES="$(lvs --noheadings --units b --nosuffix -o lv_size "$POOL" | awk '{printf "%.0f",$1}')"
FREE_BYTES="$(vgs --noheadings --units b --nosuffix -o vg_free "$VG" | awk '{printf "%.0f",$1}')"
EXTEND_BYTES=$((POOL_BYTES * EXTEND / 100))

[ "$FREE_BYTES" -ge "$EXTEND_BYTES" ] || {
    echo "Insufficient VG free space for ${EXTEND}% thin-pool extension"
    exit 1
}

cp -an /etc/lvm/lvmlocal.conf /etc/lvm/lvmlocal.conf.pre-homelab

cat > /etc/lvm/lvmlocal.conf <<EOF
activation {
    thin_pool_autoextend_threshold = $THRESHOLD
    thin_pool_autoextend_percent = $EXTEND
}
EOF

lvchange --monitor y "$POOL"
systemctl enable --now lvm2-monitor
systemctl enable --now fstrim.timer

lvmconfig --type full \
    activation/thin_pool_autoextend_threshold \
    activation/thin_pool_autoextend_percent

lvs -o lv_name,lv_size,segtype,data_percent,metadata_percent,seg_monitor "$VG"
vgs -o vg_name,vg_size,vg_free "$VG"
smartctl -H "$DISK"