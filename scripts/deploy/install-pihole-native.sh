#!/usr/bin/env bash
# Run inside the allocated dns01 Debian 13 LXC, never on a Proxmox host.
set +x
set -euo pipefail

CONFIG_DIR=/etc/pihole
LOG_ROOT=/var/log/homelab-pihole
FTL_BIN=/usr/bin/pihole-FTL
PIHOLE_BIN=/usr/local/bin/pihole
CORE_REPO=/etc/.pihole
WEB_REPO=/var/www/html/admin

fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
ipv4() {
    local value="$1" octet
    local -a octets
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 && "$octet" == "$((10#$octet))" ]] && ((10#$octet <= 255)) || return 1
    done
}
validate_settings() {
    PIHOLE_INTERFACE="${PIHOLE_INTERFACE:-eth0}"
    PIHOLE_LAN_CIDR="${PIHOLE_LAN_CIDR:-192.168.1.0/24}"
    PIHOLE_UPSTREAM1="${PIHOLE_UPSTREAM1:-1.1.1.1}"
    PIHOLE_UPSTREAM2="${PIHOLE_UPSTREAM2:-1.0.0.1}"
    PIHOLE_QUERY_LOGGING="${PIHOLE_QUERY_LOGGING:-true}"
    [[ "$PIHOLE_INTERFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || { fail 'Invalid interface'; return 1; }
    [[ "$PIHOLE_LAN_CIDR" == */* ]] && ipv4 "${PIHOLE_LAN_CIDR%/*}" || { fail 'Invalid LAN CIDR'; return 1; }
    local prefix="${PIHOLE_LAN_CIDR##*/}"
    [[ "$prefix" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || { fail 'Invalid LAN prefix'; return 1; }
    ipv4 "$PIHOLE_UPSTREAM1" && ipv4 "$PIHOLE_UPSTREAM2" || { fail 'Invalid upstream IPv4 address'; return 1; }
    [[ "$PIHOLE_UPSTREAM1" != "$PIHOLE_UPSTREAM2" ]] || { fail 'Upstreams must differ'; return 1; }
    [[ "$PIHOLE_QUERY_LOGGING" == true || "$PIHOLE_QUERY_LOGGING" == false ]] || { fail 'Query logging must be true or false'; return 1; }
}
render_config() {
    cat <<EOF
[dns]
upstreams = ["$PIHOLE_UPSTREAM1", "$PIHOLE_UPSTREAM2"]
interface = "$PIHOLE_INTERFACE"
listeningMode = "LOCAL"
queryLogging = $PIHOLE_QUERY_LOGGING

[dhcp]
active = false

[webserver]
port = ""
acl = "+127.0.0.1,+$PIHOLE_LAN_CIDR"

[ntp.ipv4]
active = false
[ntp.ipv6]
active = false
[ntp.sync]
active = false
EOF
}
require_guest() {
    [[ $EUID -eq 0 ]] || { fail 'Run as root inside dns01'; return 1; }
    [[ "$(systemd-detect-virt --container)" == lxc ]] || { fail 'Expected an LXC guest'; return 1; }
    [[ "$(hostname -s)" == dns01 ]] || { fail 'Expected hostname dns01'; return 1; }
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || { fail 'Expected Debian 13'; return 1; }
    [[ -n "$(ip -4 -o address show dev "$PIHOLE_INTERFACE" scope global)" ]] || { fail 'Guest needs an existing IPv4 address'; return 1; }
}
validate_versions() {
    [[ "${PIHOLE_EXPECTED_CORE:-}" =~ ^v6\.[0-9]+(\.[0-9]+)?$ &&
       "${PIHOLE_EXPECTED_WEB:-}" =~ ^v6\.[0-9]+(\.[0-9]+)?$ &&
       "${PIHOLE_EXPECTED_FTL:-}" =~ ^v6\.[0-9]+(\.[0-9]+)?$ ]] || { fail 'Explicit expected Core/Web/FTL v6 versions are required'; return 1; }
}
verify_versions() {
    [[ "$(git -C "$CORE_REPO" describe --tags --exact-match HEAD)" == "$PIHOLE_EXPECTED_CORE" ]] || { fail 'Core version differs from expected pin'; return 1; }
    [[ "$(git -C "$WEB_REPO" describe --tags --exact-match HEAD)" == "$PIHOLE_EXPECTED_WEB" ]] || { fail 'Web version differs from expected pin'; return 1; }
    [[ "$("$FTL_BIN" tag)" == "$PIHOLE_EXPECTED_FTL" ]] || { fail 'FTL version differs from expected pin'; return 1; }
}
has_password() {
    local hash
    hash="$("$FTL_BIN" --config webserver.api.pwhash)" || return 1
    [[ -n "$(tr -d '"[:space:]' <<< "$hash")" ]]
}
verify_web_readable() {
    runuser -u pihole -- test -r "$WEB_REPO" || { fail 'Web files are not readable by the service user'; return 1; }
}
verify_existing() {
    verify_versions || return 1
    verify_web_readable || return 1
    has_password || { fail 'Installed Pi-hole has no configured admin password'; return 1; }
    [[ "$("$FTL_BIN" --config dhcp.active)" == false ]] || { fail 'Pi-hole DHCP must remain disabled'; return 1; }
    [[ "$("$FTL_BIN" --config webserver.port)" == '80,443s' ]] || { fail 'Expected web listeners are not configured; inspect partial install'; return 1; }
    [[ "$("$FTL_BIN" --config dns.listeningMode)" == LOCAL ]] || { fail 'Expected local-origin DNS policy'; return 1; }
    [[ "$("$FTL_BIN" --config dns.interface)" == "$PIHOLE_INTERFACE" ]] || { fail 'DNS interface differs from expected'; return 1; }
    [[ "$("$FTL_BIN" --config webserver.acl)" == "+127.0.0.1,+$PIHOLE_LAN_CIDR" ]] || { fail 'Web LAN ACL differs from expected'; return 1; }
    systemctl is-active --quiet pihole-FTL || return 1
    printf 'Existing Pi-hole verified; configuration, password and databases preserved.\n'
}
main() {
    [[ $# -le 1 ]] || { fail 'Usage: install-pihole-native.sh [--render-config|--install|--verify]'; return 1; }
    local mode="${1:---install}"
    [[ "$mode" == --render-config || "$mode" == --install || "$mode" == --verify ]] || { fail 'Unknown mode'; return 1; }
    validate_settings || return 1
    if [[ "$mode" == --render-config ]]; then render_config; return 0; fi
    validate_versions || return 1
    require_guest || return 1

    if [[ -e "$CONFIG_DIR/pihole.toml" || -e "$CONFIG_DIR/setupVars.conf" ]]; then
        [[ -x "$PIHOLE_BIN" && -x "$FTL_BIN" && -f "$CONFIG_DIR/pihole.toml" ]] || { fail 'Existing/partial configuration requires inspection; nothing overwritten'; return 1; }
        verify_existing
        return $?
    fi
    [[ "$mode" == --install ]] || { fail 'No installed Pi-hole found'; return 1; }
    [[ ! -x "$PIHOLE_BIN" && ! -x "$FTL_BIN" ]] || { fail 'Partial installation requires inspection'; return 1; }
    [[ ! -d "$CONFIG_DIR" || -z "$(find "$CONFIG_DIR" -mindepth 1 -print -quit)" ]] || { fail 'Existing configuration directory is not empty'; return 1; }

    [[ "${PIHOLE_INSTALLER_COMMIT:-}" =~ ^[0-9a-f]{40}$ && "${PIHOLE_INSTALLER_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { fail 'Immutable installer commit and SHA256 are required'; return 1; }
    [[ -n "${PIHOLE_INSTALLER_FILE:-}" && -f "$PIHOLE_INSTALLER_FILE" ]] || { fail 'Downloaded/reviewed installer file is required'; return 1; }
    local actual_sha
    actual_sha="$(sha256sum -- "$PIHOLE_INSTALLER_FILE")"
    [[ "${actual_sha%% *}" == "$PIHOLE_INSTALLER_SHA256" ]] || { fail 'Installer SHA256 mismatch'; return 1; }
    bash -n "$PIHOLE_INSTALLER_FILE" || return 1

    local ADMIN_PASSWORD
    IFS= read -r ADMIN_PASSWORD || { fail 'Provide one admin-password line on stdin'; return 1; }
    [[ ${#ADMIN_PASSWORD} -ge 20 && ${#ADMIN_PASSWORD} -le 256 && "$ADMIN_PASSWORD" =~ ^[[:graph:]]+$ ]] || { unset ADMIN_PASSWORD; fail 'Password must be 20–256 printable non-space characters'; return 1; }
    trap 'unset ADMIN_PASSWORD' EXIT
    umask 077
    install -d -m 700 "$LOG_ROOT"
    local run_dir
    run_dir="$(mktemp -d "$LOG_ROOT/install.XXXXXX")"
    install -d -m 755 "$CONFIG_DIR"
    render_config > "$CONFIG_DIR/pihole.toml"
    chmod 600 "$CONFIG_DIR/pihole.toml"
    printf 'Installer commit: %s\nInstaller SHA256: %s\nExpected Core/Web/FTL: %s %s %s\n' \
        "$PIHOLE_INSTALLER_COMMIT" "$PIHOLE_INSTALLER_SHA256" "$PIHOLE_EXPECTED_CORE" "$PIHOLE_EXPECTED_WEB" "$PIHOLE_EXPECTED_FTL" > "$run_dir/provenance.txt"
    printf 'Installing from reviewed local file; private log directory: %s\n' "$run_dir"
    if ! (umask 022; DEBIAN_FRONTEND=noninteractive bash "$PIHOLE_INSTALLER_FILE" --unattended </dev/null) > "$run_dir/installer.log" 2>&1; then
        unset ADMIN_PASSWORD
        fail 'Installer failed; web remains disabled; inspect private logs and partial guest'
        return 1
    fi
    verify_versions || { unset ADMIN_PASSWORD; return 1; }
    verify_web_readable || { unset ADMIN_PASSWORD; return 1; }
    # No password argument in this wrapper's pihole invocation or command output.
    if ! printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | "$PIHOLE_BIN" setpassword > "$run_dir/password-status.log" 2>&1; then
        unset ADMIN_PASSWORD
        fail 'Password setup failed; web remains disabled'
        return 1
    fi
    unset ADMIN_PASSWORD
    has_password || { fail 'No admin password hash after setup; web remains disabled'; return 1; }
    "$FTL_BIN" --config webserver.port '80,443s' > "$run_dir/web-status.log" 2>&1
    systemctl restart pihole-FTL
    verify_existing || return 1
    printf 'Native Pi-hole install complete. Guest IP networking and home-router DNS were not changed.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
