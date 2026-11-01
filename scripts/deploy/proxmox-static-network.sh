#!/usr/bin/env bash
# Run on the owning Proxmox host. Existing addresses and MACs are preserved.
set -Eeuo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
ipv4() {
    local octet value="$1"; local -a parts
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$value"
    for octet in "${parts[@]}"; do
        [[ ${#octet} -le 3 && "$octet" == "$((10#$octet))" ]] && ((10#$octet <= 255)) || return 1
    done
}
validate_arguments() {
    [[ $# -eq 5 ]] || { fail 'Usage: proxmox-static-network.sh <lxc|vm> <id> <expected-name> <IPv4/24> <gateway>'; return 1; }
    KIND="$1"; VMID="$2"; EXPECTED_NAME="$3"; CIDR="$4"; GATEWAY="$5"; ADDRESS="${4%/*}"
    [[ "$KIND" == lxc || "$KIND" == vm ]] || { fail 'Expected lxc or vm'; return 1; }
    [[ "$VMID" =~ ^[1-9][0-9]{2,8}$ ]] || { fail 'Invalid guest ID'; return 1; }
    [[ "$EXPECTED_NAME" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || { fail 'Invalid expected guest name'; return 1; }
    ipv4 "$ADDRESS" && [[ "$CIDR" == "$ADDRESS/24" && "$GATEWAY" == 192.168.1.1 ]] || { fail 'Expected existing home-LAN /24 and gateway'; return 1; }
    # Deliberately scoped to the three authorized permanent resources.
    case "$KIND:$VMID:$EXPECTED_NAME:$ADDRESS" in
        lxc:100:dns01:192.168.1.210) EXPECTED_NODE=pve01;;
        lxc:101:dns02:192.168.1.150) EXPECTED_NODE=pve02;;
        vm:100:apps01:192.168.1.58) EXPECTED_NODE=pve02;;
        *) fail 'Resource/address is outside the approved static migration'; return 1;;
    esac
}
guest_exec() {
    if [[ "$KIND" == lxc ]]; then pct exec "$VMID" -- bash -e -c "$1"; return; fi
    local output status=0
    output="$(mktemp)"
    qm guest exec "$VMID" --timeout 300 -- bash -e -c "$1" > "$output" || status=$?
    if [[ "$status" -eq 0 ]]; then
        python3 - "$output" <<'PY' || status=$?
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
sys.stdout.write(result.get('out-data',''))
sys.stderr.write(result.get('err-data',''))
if not result.get('exited'): raise SystemExit('Guest command did not complete')
raise SystemExit(result.get('exitcode',1))
PY
    else cat "$output" >&2; fi
    rm -f "$output"
    return "$status"
}
config_value() { sed -n "s/^$1: //p" "$STATE/original.conf"; }
validate_vm_ipconfig() {
    # Proxmox may canonicalize property order when storing ipconfig0.
    python3 - "$1" "$2" "$3" <<'PY'
import sys
value,address,gateway=sys.argv[1:]
parts={}
for item in value.split(','):
    if '=' not in item: raise SystemExit('Malformed cloud-init IPv4 metadata')
    key,setting=item.split('=',1)
    if key in parts: raise SystemExit('Duplicate cloud-init IPv4 property')
    parts[key]=setting
if parts not in ({'ip':'dhcp'},{'ip':address,'gw':gateway}):
    raise SystemExit('Unexpected existing cloud-init IPv4 metadata')
PY
}
vm_guest_apply() {
    set -Eeuo pipefail
    umask 077
    local address="$1" gateway="$2" mac="$3" state="$4"
    [[ ! -e "$state" ]] || { echo 'Guest backup path already exists' >&2; return 1; }
    install -d -m 700 "$state"
    # Refuse a different renderer/interface or an unreviewed multi-file layout.
    python3 - "$address" "$gateway" "$mac" "$state" <<'PY'
import glob,os,shutil,sys,yaml
address,gateway,mac,state=sys.argv[1:]
path='/etc/netplan/50-cloud-init.yaml'
if not os.path.isfile(path) or os.path.islink(path):
    raise SystemExit('Expected a regular reviewed netplan file')
other_files=glob.glob('/etc/netplan/*.yml')
for directory in ('/lib/netplan','/run/netplan'):
    other_files+=glob.glob(directory+'/*.yaml')+glob.glob(directory+'/*.yml')
if glob.glob('/etc/netplan/*.yaml') != [path] or other_files:
    raise SystemExit('Expected only the reviewed 50-cloud-init.yaml netplan file')
with open(path) as f: data=yaml.safe_load(f)
network=data.get('network',{})
if network.get('version')!=2 or network.get('renderer','networkd')!='networkd':
    raise SystemExit('Expected networkd netplan version 2')
if set(network)-{'version','renderer','ethernets'} or set(network.get('ethernets',{}))!={'eth0'}:
    raise SystemExit('Unexpected netplan topology; nothing overwritten')
eth=network['ethernets']['eth0']
allowed={'match','set-name','dhcp4','dhcp6','addresses','gateway4','nameservers','routes'}
if set(eth)-allowed or eth.get('set-name','eth0')!='eth0' or eth.get('match',{}).get('macaddress','').lower()!=mac.lower():
    raise SystemExit('Expected eth0 with matching MAC and reviewed keys')
if set(eth.get('match',{}))!={'macaddress'} or eth.get('dhcp6',False):
    raise SystemExit('Unexpected interface match or DHCPv6 policy')
old_addresses=eth.get('addresses',[])
if old_addresses and old_addresses != [address+'/24']:
    raise SystemExit('Unexpected existing static addresses')
routes=eth.get('routes',[])
if any(route.get('to') not in ('default','0.0.0.0/0') or route.get('via')!=gateway or set(route)-{'to','via'} for route in routes):
    raise SystemExit('Unexpected existing static routes')
if eth.get('gateway4',gateway)!=gateway:
    raise SystemExit('Unexpected legacy gateway')
if set(eth.get('nameservers',{}))-{'addresses','search'}:
    raise SystemExit('Unexpected nameserver options')
shutil.copy2(path,state+'/50-cloud-init.yaml')
eth['dhcp4']=False
eth['addresses']=[address+'/24']
eth.pop('gateway4',None)
eth['routes']=[{'to':'default','via':gateway}]
eth.setdefault('nameservers',{})['addresses']=[gateway]
candidate=state+'/candidate.yaml'
with open(candidate,'w') as f: yaml.safe_dump(data,f,sort_keys=False)
os.chmod(candidate,0o600)
PY
    cat > "$state/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
state="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cp --preserve=mode,timestamps "$state/50-cloud-init.yaml" /etc/netplan/50-cloud-init.yaml
timeout 45 netplan generate
timeout 45 netplan apply
echo 'Original guest netplan restored.'
ROLLBACK
    chmod 700 "$state/rollback.sh"
    if cmp -s "$state/candidate.yaml" /etc/netplan/50-cloud-init.yaml; then
        printf 'Guest static netplan already matches; no network reconfiguration. Backup: %s\n' "$state"
        return 0
    fi
    trap 'status=$?; trap - ERR; bash "$state/rollback.sh" >&2 || true; exit "$status"' ERR
    install -m 600 "$state/candidate.yaml" /etc/netplan/50-cloud-init.yaml
    timeout 45 netplan generate
    timeout 45 netplan apply
    ip -4 -o address show dev eth0 | awk '{print $4}' | grep -Fxq "$address/24"
    ip -4 route show default dev eth0 | grep -Eq "^default via $gateway( |$)"
    timeout 12 getent ahostsv4 debian.org >/dev/null
    trap - ERR
    printf 'Guest static netplan applied; rollback: %s/rollback.sh\n' "$state"
}
main() {
    validate_arguments "$@"
    [[ $EUID -eq 0 && "$(hostname -s)" == "$EXPECTED_NODE" ]] || { fail 'Run as root on the owning Proxmox node'; return 1; }
    command -v python3 >/dev/null
    command -v flock >/dev/null
    install -d -m 700 /var/lib/homelab/network
    exec 9>"/var/lib/homelab/network/$KIND-$VMID.lock"
    flock -n 9 || { fail 'Another migration owns this guest'; return 1; }
    STATE="$(mktemp -d "/var/lib/homelab/network/$KIND-$VMID.XXXXXX")"
    if [[ "$KIND" == lxc ]]; then
        pct status "$VMID" | grep -Fxq 'status: running'
        pct config "$VMID" > "$STATE/original.conf"
        [[ "$(config_value hostname)" == "$EXPECTED_NAME" ]]
    else
        qm status "$VMID" | grep -Fxq 'status: running'
        qm config "$VMID" > "$STATE/original.conf"
        [[ "$(config_value name)" == "$EXPECTED_NAME" ]]
    fi
    OLD_NET0="$(config_value net0)"; OLD_NAMESERVER="$(config_value nameserver)"; OLD_IPCONFIG0="$(config_value ipconfig0)"
    MAC="$(python3 - "$KIND" "$OLD_NET0" <<'PY'
import re,sys
kind,value=sys.argv[1:]
parts=dict(item.split('=',1) for item in value.split(','))
if parts.get('bridge')!='vmbr0': raise SystemExit('Expected vmbr0')
if kind=='lxc':
    if parts.get('name')!='eth0' or parts.get('ip') not in ('dhcp','192.168.1.210/24','192.168.1.150/24'):
        raise SystemExit('Unexpected LXC eth0 address policy')
    mac=parts.get('hwaddr','')
else: mac=parts.get('virtio','')
if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}',mac): raise SystemExit('Expected existing MAC')
print(mac.lower())
PY
)"
    guest_exec "[[ \$(hostname -s) == '$EXPECTED_NAME' && \$(cat /sys/class/net/eth0/address) == '$MAC' ]]; ip -4 -o address show dev eth0 | awk '{print \$4}' | grep -Fxq '$CIDR'; ip -4 route show default dev eth0 | grep -Eq '^default via $GATEWAY( |\$)'"
    GUEST_STATE="/var/lib/homelab/network/$(basename "$STATE")"
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'KIND=%q\nVMID=%q\nOLD_NET0=%q\nOLD_NAMESERVER=%q\nOLD_IPCONFIG0=%q\nGUEST_STATE=%q\n' "$KIND" "$VMID" "$OLD_NET0" "$OLD_NAMESERVER" "$OLD_IPCONFIG0" "$GUEST_STATE"
        cat <<'ROLLBACK'
if [[ "$KIND" == lxc ]]; then
    pct set "$VMID" --net0 "$OLD_NET0"
    if [[ -n "$OLD_NAMESERVER" ]]; then pct set "$VMID" --nameserver "$OLD_NAMESERVER"; else pct set "$VMID" --delete nameserver; fi
else
    if [[ -n "$OLD_IPCONFIG0" ]]; then qm set "$VMID" --ipconfig0 "$OLD_IPCONFIG0"; else qm set "$VMID" --delete ipconfig0; fi
    if [[ -n "$OLD_NAMESERVER" ]]; then qm set "$VMID" --nameserver "$OLD_NAMESERVER"; else qm set "$VMID" --delete nameserver; fi
    result="$(mktemp)"
    qm guest exec "$VMID" --timeout 120 -- bash -e -c "if [[ -f '$GUEST_STATE/rollback.sh' ]]; then bash '$GUEST_STATE/rollback.sh'; fi" > "$result"
    python3 - "$result" <<'PY'
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
sys.stdout.write(result.get('out-data',''));sys.stderr.write(result.get('err-data',''))
if not result.get('exited'): raise SystemExit('Guest rollback did not complete')
raise SystemExit(result.get('exitcode',1))
PY
    rm -f "$result"
fi
echo 'Original Proxmox network metadata restored; verify guest connectivity.'
ROLLBACK
    } > "$STATE/rollback.sh"
    chmod 700 "$STATE/rollback.sh"
    trap 'status=$?; trap - ERR; echo "Migration failed; attempting rollback: $STATE/rollback.sh" >&2; bash "$STATE/rollback.sh" >&2 || true; exit "$status"' ERR
    if [[ "$KIND" == lxc ]]; then
        NEW_NET0="$(python3 - "$OLD_NET0" "$CIDR" "$GATEWAY" <<'PY'
import sys
old,address,gateway=sys.argv[1:]
parts=dict(item.split('=',1) for item in old.split(','))
parts['ip']=address;parts['gw']=gateway
print(','.join(key+'='+value for key,value in parts.items()))
PY
)"
        guest_exec "umask 077; install -d -m 700 '$GUEST_STATE'; cp -a /etc/network/interfaces '$GUEST_STATE/interfaces'; cp -L --preserve=mode,timestamps /etc/resolv.conf '$GUEST_STATE/resolv.conf'"
        if [[ "$OLD_NET0" == "$NEW_NET0" && "$OLD_NAMESERVER" == "$GATEWAY" ]] && guest_exec "grep -Eq '^iface eth0 inet static$' /etc/network/interfaces"; then
            echo 'Existing LXC static metadata and guest interface match; no network reconfiguration.'
        else
            pct set "$VMID" --net0 "$NEW_NET0" --nameserver "$GATEWAY"
        fi
    else
        validate_vm_ipconfig "$OLD_IPCONFIG0" "$CIDR" "$GATEWAY"
        qm set "$VMID" --ipconfig0 "ip=$CIDR,gw=$GATEWAY" --nameserver "$GATEWAY"
        payload="$(declare -f vm_guest_apply); vm_guest_apply '$ADDRESS' '$GATEWAY' '$MAC' '$GUEST_STATE'"
        guest_exec "$payload"
    fi
    guest_exec "ip -4 -o address show dev eth0 | awk '{print \$4}' | grep -Fxq '$CIDR'; ip -4 route show default dev eth0 | grep -Eq '^default via $GATEWAY( |\$)'; timeout 12 getent ahostsv4 debian.org >/dev/null"
    trap - ERR
    printf 'Static migration verified: %s %s %s, gateway/DNS %s. Backup and manual rollback: %s/rollback.sh\n' "$KIND" "$VMID" "$CIDR" "$GATEWAY" "$STATE"
    echo 'Guest reboot persistence must be tested separately. Router DNS and Pi-hole upstream settings were not changed.'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
