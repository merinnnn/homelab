#!/usr/bin/env bash
# Run from the owning Proxmox host checkout. No firewall or management changes.
set -euo pipefail
UNIT=prometheus-node-exporter.service
fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
select_node() {
    NODE="$1"
    case "$NODE" in
        pve01) ADDRESS=192.168.1.2 ;;
        pve02) ADDRESS=192.168.1.3 ;;
        *) fail 'Expected pve01 or pve02'; return 1 ;;
    esac
}
set_paths() {
    STATE=/var/lib/homelab/node-exporter
    DROP_DIR=/etc/systemd/system/prometheus-node-exporter.service.d
    DROP_IN="$DROP_DIR/50-homelab.conf"
    DEFAULTS=/etc/default/prometheus-node-exporter
    LOCK=/run/lock/homelab-node-exporter.lock
}
render_override() {
    cat <<EOF
# Managed by homelab install-node-exporter.sh
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=$ADDRESS:9100 --collector.systemd "--collector.systemd.unit-include=(pveproxy|pvedaemon|pvestatd|pvescheduler|prometheus-node-exporter)[.]service"
EOF
}
require_host() {
    [[ "$(id -u)" == 0 ]] || { fail 'Run as root on the owning Proxmox host'; return 1; }
    command -v pveversion >/dev/null || { fail 'Expected a Proxmox host'; return 1; }
    if systemd-detect-virt --container --quiet; then fail 'Refusing an LXC/container'; return 1; fi
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || { fail 'Expected Debian 13'; return 1; }
    select_node "$(hostname -s)" || return 1
    ip -4 -o address show dev vmbr0 | awk -v expected="$ADDRESS/24" '$4 == expected {found=1} END {exit !found}' || { fail 'Node identity/address mismatch'; return 1; }
    [[ -S /run/dbus/system_bus_socket ]] || { fail 'A working system D-Bus socket is required for unit metrics'; return 1; }
}
installed() { dpkg-query -W -f='${Status}' prometheus-node-exporter 2>/dev/null | grep -qx 'install ok installed'; }
verify_layout() {
    [[ ! -e /etc/systemd/system/prometheus-node-exporter.service && ! -e /run/systemd/system/prometheus-node-exporter.service ]] || { fail 'An unknown full service override exists'; return 1; }
    [[ "$(systemctl show "$UNIT" -p DropInPaths --value)" == "$DROP_IN" ]] || { fail 'Unexpected service drop-ins; nothing overwritten'; return 1; }
}
verify_metrics() {
    systemctl is-enabled --quiet "$UNIT" && systemctl is-active --quiet "$UNIT" || { fail 'Exporter must be enabled and active'; return 1; }
    local sample result=0 metric
    sample="$(mktemp "$STATE/metrics.XXXXXX")"
    curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 10 --retry 3 --retry-connrefused --retry-delay 1 --retry-max-time 20 "http://$ADDRESS:9100/metrics" > "$sample" || result=$?
    if [[ "$result" == 0 ]]; then
        for metric in node_cpu_seconds_total node_memory_MemAvailable_bytes node_memory_MemTotal_bytes node_filesystem_avail_bytes; do
            grep -Eq "^$metric([ {])" "$sample" || result=1
        done
        grep -Eq '^node_systemd_unit_state\{[^}]*name="pveproxy[.]service"' "$sample" || result=1
        # Collector failures must not be represented as a complete metrics pass.
        ! grep -Eq '^node_scrape_collector_success\{collector="(cpu|meminfo|filesystem|systemd)"\} 0([.]0+)?$' "$sample" || result=1
    fi
    rm -f "$sample"
    [[ "$result" == 0 ]] || { fail 'Exporter metrics/collector verification failed'; return 1; }
}
main() {
    if [[ "${1-}" == --render ]]; then [[ $# == 2 ]] || return 1; select_node "$2" || return 1; render_override; return; fi
    [[ $# -le 1 && ( "${1:---install}" == --install || "${1-}" == --verify ) ]] || { fail 'Usage: install-node-exporter.sh [--install|--verify] | --render <pve01|pve02>'; return 1; }
    local mode="${1:---install}"
    set_paths
    require_host || return 1
    exec 9>"$LOCK"
    flock -n 9 || { fail 'Another exporter installation/check is running'; return 1; }
    umask 022
    if [[ -f "$STATE/complete" ]]; then
        installed || { fail 'Managed package is missing'; return 1; }
        [[ "$(cat "$STATE/node")" == "$NODE" ]] || { fail 'Saved node identity differs'; return 1; }
        sha256sum --check --status "$STATE/package-files.sha256" || { fail 'Package/default/override configuration drift; inspect before retry'; return 1; }
        cmp -s "$DROP_IN" <(render_override) || { fail 'Desired override differs; explicit migration review required'; return 1; }
        verify_layout && verify_metrics || return 1
        printf 'Existing exporter verified at %s:9100; configuration/service preserved.\n' "$ADDRESS"
        return 0
    fi
    [[ "$mode" == --install ]] || { fail 'No completed managed installation found'; return 1; }
    [[ ! -e "$STATE" ]] || { fail 'Existing/partial state requires inspection; nothing overwritten'; return 1; }
    ! installed || { fail 'An unowned exporter package is already installed'; return 1; }
    [[ ! -e "$DEFAULTS" && ! -e "$DROP_DIR" && ! -e /etc/systemd/system/prometheus-node-exporter.service && ! -e /run/systemd/system/prometheus-node-exporter.service ]] || { fail 'Existing exporter configuration is not owned; nothing overwritten'; return 1; }
    [[ -z "$(systemctl show "$UNIT" -p FragmentPath --value)" && -z "$(systemctl show "$UNIT" -p DropInPaths --value)" ]] || { fail 'An unowned exporter service exists'; return 1; }
    local listeners
    listeners="$(ss -H -lnt 'sport = :9100')" || return 1
    [[ -z "$listeners" ]] || { fail 'TCP port 9100 is already occupied'; return 1; }
    install -d -m 0700 "$STATE"
    printf '%s\n' "$NODE" > "$STATE/node"
    chmod 0600 "$STATE/node"
    # Package postinst may start the service. Install the explicit bind first.
    install -d -m 0755 "$DROP_DIR"
    render_override > "$DROP_IN"
    chmod 0644 "$DROP_IN"
    systemctl daemon-reload
    export DEBIAN_FRONTEND=noninteractive
    local -a apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
    apt-get "${apt_options[@]}" update
    apt-get "${apt_options[@]}" install --no-install-recommends -y prometheus-node-exporter
    installed || { fail 'APT did not install the exporter'; return 1; }
    local fragment
    fragment="$(systemctl show "$UNIT" -p FragmentPath --value)"
    [[ "$fragment" == /usr/lib/systemd/system/prometheus-node-exporter.service || "$fragment" == /lib/systemd/system/prometheus-node-exporter.service ]] || { fail 'Expected a packaged vendor service'; return 1; }
    verify_layout || return 1
    systemctl enable "$UNIT"
    systemctl restart "$UNIT"
    verify_metrics || { systemctl disable --now "$UNIT"; fail 'Fresh exporter failed validation and was disabled; inspect retained partial state'; return 1; }
    sha256sum "$fragment" "$DEFAULTS" "$DROP_IN" > "$STATE/package-files.sha256"
    chmod 0600 "$STATE/package-files.sha256"
    touch "$STATE/complete"
    chmod 0600 "$STATE/complete"
    printf 'Exporter installed and verified at %s:9100. Package: ' "$ADDRESS"
    dpkg-query -W -f='${Version}\n' prometheus-node-exporter
    printf 'No firewall rules, management services, bridges or router settings were changed. Verify the scrape from apps01 separately.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
