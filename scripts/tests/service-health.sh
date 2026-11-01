#!/usr/bin/env bash
set -uo pipefail

# README defaults; override these for the observed production addresses.
PIHOLE_IP="${PIHOLE_IP:-192.168.1.53}"
DOCKER_IP="${DOCKER_IP:-192.168.1.54}"
DNS_NAME="${DNS_NAME:-example.com}"
failures=0

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '%s: OK\n' "$label"
    else
        printf '%s: FAIL\n' "$label"
        failures=$((failures + 1))
    fi
}

http_health() {
    local status
    status="$(curl --silent --connect-timeout 3 --max-time 8 --output /dev/null --write-out '%{http_code}' "$1")" || return 1
    [[ "$status" == 200 || "$status" == 302 ]]
}

dns_answer() {
    local answer
    answer="$(dig +time=2 +tries=1 @"$PIHOLE_IP" "$DNS_NAME" A +short)" || return 1
    [[ -n "${answer//[[:space:]]/}" ]]
}

printf 'Running service checks from %s...\n' "$(hostname)"
check "Pi-hole web ($PIHOLE_IP/admin)" http_health "http://$PIHOLE_IP/admin"
check "Pi-hole DNS answer ($PIHOLE_IP, $DNS_NAME)" dns_answer
check "Portainer web ($DOCKER_IP:9000)" http_health "http://$DOCKER_IP:9000"
check "Uptime Kuma web ($DOCKER_IP:3001)" http_health "http://$DOCKER_IP:3001"
printf 'Checks complete: %s failed.\n' "$failures"
[[ "$failures" -eq 0 ]]
