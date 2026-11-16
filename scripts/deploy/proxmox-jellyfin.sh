#!/usr/bin/env bash
# Node-local Jellyfin deployment. No writes to the SSD except explicitly creating
# the requested Jellyfin directory tree. Never formats, resets or deletes media.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
[[ $EUID == 0 && $(hostname -s) == pve01 && $PWD == /root/homelab ]]
id=103
uuid=2627-3DAE
dev=/dev/disk/by-uuid/$uuid
base=/mnt/homelab-jellyfin
mac=BC:24:11:18:F4:09
mount_unit=$(systemd-escape --path --suffix=mount "$base")
device_unit=$(systemd-escape --path --suffix=device "$dev")
timer_dir=/etc/systemd/system/pve-container@$id.service.d
state=/var/lib/homelab/jellyfin
action=${1:-}
exec 9>/run/homelab-jellyfin.lock
flock -n 9
umask 022

need_ssd() {
    [[ -b $dev && $(blkid -s TYPE -o value "$dev") == exfat ]]
    [[ $(lsblk -dn -o TRAN "/dev/$(lsblk -dn -o PKNAME "$dev")") == usb ]]
}
owned() {
    [[ -f $state/owner && ! -L $state/owner && $(cat "$state/owner") == 'pve01:103:homelab-jellyfin' ]]
    local cfg
    cfg=$(pct config "$id")
    grep -Fxq 'hostname: jellyfin01' <<< "$cfg"
    grep -Fxq 'tags: homelab-jellyfin' <<< "$cfg"
    grep -Fxq 'unprivileged: 1' <<< "$cfg"
    grep -Eq "^net0: .*hwaddr=$mac(,|$)" <<< "$cfg"
    grep -Eq '^rootfs: local-lvm:vm-103-disk-[0-9]+(,|$)' <<< "$cfg"
}
guest_helper() {
    pct exec "$id" -- install -d -m 0700 /root/homelab-jellyfin
    pct push "$id" scripts/deploy/jellyfin-bootstrap.py /root/homelab-jellyfin/bootstrap.py --perms 600
    pct exec "$id" -- python3 /root/homelab-jellyfin/bootstrap.py "$1"
}
mounted() {
    need_ssd
    findmnt -rn -M "$base" -S "UUID=$uuid" -t exfat -O ro >/dev/null
    [[ -d $base/Jellyfin && ! -L $base/Jellyfin ]]
}

case "$action" in
install)
    [[ ! -e $state && ! -L $state && ! -e /etc/pve/lxc/$id.conf && ! -e /etc/pve/qemu-server/$id.conf ]]
    [[ -c /dev/dri/renderD128 ]]
    pvesh get /cluster/resources --type vm --output-format json |
        python3 -c 'import sys,json; assert all(vm["vmid"] != 103 for vm in json.load(sys.stdin))'
    mapfile -t templates < <(pveam list local | awk '$1 ~ /^local:vztmpl\/debian-13-standard_.*_amd64\.tar\.zst$/ {print $1}')
    [[ ${#templates[@]} == 1 ]]
    install -d -m 0700 "$state"
    (umask 077; printf '%s\n' pve01:103:homelab-jellyfin > "$state/owner")
    pct create "$id" "${templates[0]}" --hostname jellyfin01 --ostype debian --unprivileged 1 \
        --rootfs local-lvm:24 --cores 2 --memory 1536 --swap 256 --onboot 0 --timezone host \
        --net0 "name=eth0,bridge=vmbr1,hwaddr=$mac,ip=dhcp,type=veth" --tags homelab-jellyfin \
        --dev0 path=/dev/dri/renderD128,gid=3001,mode=0660
    owned
    pct start "$id"
    ;;&
install|install-guest)
    owned
    [[ $(pct status "$id") == 'status: running' ]]
    grep -q '^net0: .*bridge=vmbr1,' < <(pct config "$id")
    pct exec "$id" -- test ! -e /etc/homelab/jellyfin/owner.json
    pct push "$id" scripts/deploy/jellyfin-guest.sh /root/homelab-install-jellyfin.sh --perms 600
    pct exec "$id" -- bash /root/homelab-install-jellyfin.sh
    guest_helper bootstrap
    ;;
attach)
    owned
    [[ $(pct status "$id") == 'status: running' ]]
    pct config "$id" | grep -q '^net0: .*bridge=vmbr1,'
    ! pct config "$id" | grep -q '^mp0:'
    need_ssd
    [[ ! -e $base && ! -L $base && ! -e /etc/systemd/system/$mount_unit && ! -e $timer_dir/50-homelab-media.conf ]]
    [[ -z $(findmnt -rn -S "$dev") ]]
    pid=$(lxc-info -n "$id" -pH)
    mapped=$(awk '$1<=3000 && 3000<$1+$3 {print $2+3000-$1}' "/proc/$pid/gid_map")
    [[ $mapped =~ ^[1-9][0-9]{4,}$ ]]
    pct exec "$id" -- getent group jellyfin-media | grep -Fxq 'jellyfin-media:x:3000:jellyfin'
    work=$(mktemp -d /run/homelab-jellyfin.XXXXXXXX)
    trap 'if mountpoint -q "$work"; then umount "$work"; fi; rmdir "$work"' EXIT
    mount -t exfat -o rw,nosuid,nodev,noexec "$dev" "$work"
    # A pre-existing folder is preserved; this action is only for the authorized fresh tree.
    [[ ! -e $work/Jellyfin && ! -L $work/Jellyfin ]]
    mkdir -- "$work/Jellyfin"
    mkdir -- "$work/Jellyfin/Movies" "$work/Jellyfin/TV Shows" "$work/Jellyfin/Music"
    sync -f "$work"
    umount "$work"
    rmdir "$work"
    trap - EXIT
    pct shutdown "$id" --timeout 45
    install -d -m 0755 "$base" "$timer_dir"
    cat > "/etc/systemd/system/$mount_unit" <<EOF
[Unit]
Description=Jellyfin T7 media mount
BindsTo=$device_unit
After=$device_unit
JobTimeoutSec=20s

[Mount]
What=$dev
Where=$base
Type=exfat
Options=ro,nosuid,nodev,noexec,uid=0,gid=$mapped,dmask=0027,fmask=0137
TimeoutSec=10s
EOF
    cat > "$timer_dir/50-homelab-media.conf" <<EOF
[Unit]
BindsTo=$mount_unit
After=$mount_unit

[Service]
ExecStartPre=/usr/bin/findmnt -rn -M $base -S UUID=$uuid -t exfat -O ro
ExecStartPre=/usr/bin/test -d $base/Jellyfin
EOF
    chmod 0644 "/etc/systemd/system/$mount_unit" "$timer_dir/50-homelab-media.conf"
    systemctl daemon-reload
    systemctl start "$mount_unit"
    mounted
    pct set "$id" --mp0 "$base/Jellyfin,mp=/srv/media,ro=1,backup=0,replicate=0"
    pct start "$id"
    ;;&
attach|libraries)
    owned
    mounted
    pct exec "$id" -- runuser -u jellyfin -- test -r '/srv/media/TV Shows'
    guest_helper libraries
    ;;
publish)
    owned
    mounted
    pct config "$id" | grep -q '^net0: .*bridge=vmbr1,'
    pct config "$id" | grep -Fxq "mp0: $base/Jellyfin,mp=/srv/media,backup=0,replicate=0,ro=1"
    guest_helper verify
    # .9 is outside the verified router-managed .10-.254 DHCP pool.
    if ping -c1 -W2 192.168.1.9 >/dev/null 2>&1; then
        echo 'Jellyfin address already answered' >&2; exit 1
    fi
    if ip neigh show 192.168.1.9 dev vmbr0 | grep -q lladdr; then
        echo 'A LAN neighbor already uses the Jellyfin address' >&2; exit 1
    fi
    pct shutdown "$id" --timeout 45
    pct set "$id" --net0 "name=eth0,bridge=vmbr0,hwaddr=$mac,ip=192.168.1.9/24,gw=192.168.1.1,type=veth" \
        --nameserver '192.168.1.210 192.168.1.150 94.140.14.14' --onboot 1 --startup order=30,up=10,down=60
    pct start "$id"
    guest_helper verify
    ;;
verify)
    owned
    mounted
    pct exec "$id" -- findmnt -rn -M /srv/media -t exfat -O ro
    pct exec "$id" -- runuser -u jellyfin -- test -r '/srv/media/TV Shows'
    guest_helper verify
    ;;
*) echo 'Usage: proxmox-jellyfin.sh install|install-guest|attach|libraries|publish|verify' >&2; exit 2 ;;
esac