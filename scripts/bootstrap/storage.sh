#!/usr/bin/env bash
set -euo pipefail

THRESHOLD="${THRESHOLD:-80}"
EXTEND="${EXTEND:-20}"

command -v lvmconfig >/dev/null
command -v smartctl >/dev/null

VG="$(lvs --noheadings -o vg_name,segtype | awk '$2=="thin-pool"{print $1; exit}')"
DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
[ -n "$VG" ] && [ -n "$DISK" ]

cp -an /etc/lvm/lvmlocal.conf /etc/lvm/lvmlocal.conf.pre-homelab

if ! grep -q 'thin_pool_autoextend_threshold' /etc/lvm/lvmlocal.conf; then
cat >> /etc/lvm/lvmlocal.conf <<EOF

activation {
    thin_pool_autoextend_threshold = $THRESHOLD
    thin_pool_autoextend_percent = $EXTEND
}
EOF
fi

lvmconfig --type full activation/thin_pool_autoextend_threshold activation/thin_pool_autoextend_percent
lvs -o lv_name,lv_size,segtype,data_percent,metadata_percent,seg_monitor "$VG"
smartctl -H "$DISK"
systemctl enable --now fstrim.timer
