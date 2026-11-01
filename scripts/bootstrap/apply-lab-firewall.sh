#!/usr/bin/env bash
# Apply only project-owned nftables tables. Does not configure bridges, services,
# forwarding sysctls, packages or boot persistence. --render is read-only.
set -euo pipefail
LAB_BRIDGE="${LAB_BRIDGE:-vmbr1}"
LAB_IP="${LAB_IP:-10.0.10.1}"
LAB_NET="${LAB_NET:-10.0.10.0/24}"
UPLINK="${UPLINK:-vmbr0}"
MAIN_NET="${MAIN_NET:-192.168.1.0/24}"

[[ "$LAB_BRIDGE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$UPLINK" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || { echo 'Invalid interface name' >&2; exit 1; }
[[ "$LAB_BRIDGE" != "$UPLINK" ]] || { echo 'Lab and uplink must differ' >&2; exit 1; }
[[ "$LAB_IP" =~ ^[0-9.]+$ && "$LAB_NET" =~ ^[0-9.]+/[0-9]+$ && "$MAIN_NET" =~ ^[0-9.]+/[0-9]+$ ]] || { echo 'Invalid IPv4 value' >&2; exit 1; }

render() {
    cat <<EOF
table inet homelab {
    chain input {
        type filter hook input priority 0; policy accept;
        ct state established,related accept
        iifname "$LAB_BRIDGE" udp dport 67 accept
        iifname "$LAB_BRIDGE" ip daddr $LAB_IP udp dport 53 accept
        iifname "$LAB_BRIDGE" ip daddr $LAB_IP tcp dport 53 accept
        iifname "$LAB_BRIDGE" ip daddr $LAB_IP ip protocol icmp accept
        iifname "$LAB_BRIDGE" drop
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "$LAB_BRIDGE" oifname "$UPLINK" ip daddr $MAIN_NET drop
        iifname "$LAB_BRIDGE" oifname "$UPLINK" ip saddr $LAB_NET ct state new,established,related accept
        iifname "$UPLINK" oifname "$LAB_BRIDGE" ip daddr $LAB_NET ct state established,related accept
        iifname "$LAB_BRIDGE" drop
        oifname "$LAB_BRIDGE" drop
    }
}
table ip homelab_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname "$LAB_BRIDGE" oifname "$UPLINK" ip saddr $LAB_NET masquerade
    }
}
EOF
}

case "${1:---render}" in
    --render) render; exit 0 ;;
    --render-persistent)
        printf 'destroy table inet homelab\ndestroy table ip homelab_nat\n'
        render
        exit 0 ;;
    --apply) ;;
    *) echo 'Usage: apply-lab-firewall.sh [--render|--render-persistent|--apply]' >&2; exit 1 ;;
esac

umask 077
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/homelab-firewall}"
mkdir -p -- "$BACKUP_ROOT"
BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
printf 'Firewall backup directory: %s\n' "$BACKUP_DIR"

# Inventory must succeed; permission or nft errors must not be mistaken for absent tables.
nft list tables > "$BACKUP_DIR/tables.before"
: > "$BACKUP_DIR/apply.nft"
printf 'delete table inet homelab\ndelete table ip homelab_nat\n' > "$BACKUP_DIR/rollback.nft"
for table_spec in 'inet homelab' 'ip homelab_nat'; do
    read -r family table_name <<< "$table_spec"
    if grep -Fxq "table $family $table_name" "$BACKUP_DIR/tables.before"; then
        nft list table "$family" "$table_name" > "$BACKUP_DIR/$family-$table_name.before.nft"
        printf 'delete table %s %s\n' "$family" "$table_name" >> "$BACKUP_DIR/apply.nft"
        cat "$BACKUP_DIR/$family-$table_name.before.nft" >> "$BACKUP_DIR/rollback.nft"
    fi
done
render > "$BACKUP_DIR/homelab.nft"
cat "$BACKUP_DIR/homelab.nft" >> "$BACKUP_DIR/apply.nft"

# nft -f commits the scoped delete/recreate batch as one transaction.
nft -c -f "$BACKUP_DIR/apply.nft"
nft -f "$BACKUP_DIR/apply.nft"
printf 'Runtime project rules applied. Boot configuration was not changed.\n'
printf 'Rollback after this successful apply: nft -c -f %q && nft -f %q\n' "$BACKUP_DIR/rollback.nft" "$BACKUP_DIR/rollback.nft"
