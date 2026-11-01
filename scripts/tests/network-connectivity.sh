#!/usr/bin/env bash
set -uo pipefail

# README defaults; override these for the observed network and test vantage.
GATEWAY="${GATEWAY:-192.168.1.1}"
INTERNET_IP="${INTERNET_IP:-1.1.1.1}"
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

dns_answer() {
    local answer
    answer="$(dig +time=2 +tries=1 @"$PIHOLE_IP" "$DNS_NAME" A +short)" || return 1
    [[ -n "${answer//[[:space:]]/}" ]]
}

printf 'Running connectivity checks from %s...\n' "$(hostname)"
check "Gateway ($GATEWAY)" ping -n -c 1 -W 2 -w 3 "$GATEWAY"
check "Internet ICMP ($INTERNET_IP)" ping -n -c 1 -W 2 -w 3 "$INTERNET_IP"
check "Pi-hole host ($PIHOLE_IP)" ping -n -c 1 -W 2 -w 3 "$PIHOLE_IP"
check "Docker host ($DOCKER_IP)" ping -n -c 1 -W 2 -w 3 "$DOCKER_IP"
check "Pi-hole DNS answer ($PIHOLE_IP, $DNS_NAME)" dns_answer
check "Pi-hole TCP DNS ($PIHOLE_IP:53)" nc -z -w 2 "$PIHOLE_IP" 53
check "Portainer TCP ($DOCKER_IP:9000)" nc -z -w 2 "$DOCKER_IP" 9000
check "Uptime Kuma TCP ($DOCKER_IP:3001)" nc -z -w 2 "$DOCKER_IP" 3001
printf 'Checks complete: %s failed.\n' "$failures"
[[ "$failures" -eq 0 ]]
