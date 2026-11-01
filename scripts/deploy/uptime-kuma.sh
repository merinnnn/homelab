#!/usr/bin/env bash
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run inside the Docker guest as root" >&2; exit 1; }
if command -v pveversion >/dev/null 2>&1; then echo "Refusing application deployment on a Proxmox host" >&2; exit 1; fi
[[ $# -le 1 ]] || { echo "Usage: $0 [compose-template]" >&2; exit 1; }
TEMPLATE="${1:-$(dirname "$0")/../../configs/docker/uptime-kuma/docker-compose.yml}"
STACK_DIR="${STACK_DIR:-/opt/homelab/uptime-kuma}"
[[ "$STACK_DIR" == /* && "$STACK_DIR" != / ]] || { echo "STACK_DIR must be an absolute directory" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "Compose template not found: $TEMPLATE" >&2; exit 1; }

# Read only individual values; never execute an installed environment file.
previous() { if [[ -f "$STACK_DIR/.env" ]]; then sed -n "s/^$1=//p" "$STACK_DIR/.env" | head -n 1; fi; }
KUMA_IMAGE="${KUMA_IMAGE:-$(previous KUMA_IMAGE)}"
KUMA_IMAGE="${KUMA_IMAGE:-louislam/uptime-kuma:2.5.8}"
KUMA_BIND_IP="${KUMA_BIND_IP:-$(previous KUMA_BIND_IP)}"
KUMA_BIND_IP="${KUMA_BIND_IP:-127.0.0.1}"
KUMA_PORT="${KUMA_PORT:-$(previous KUMA_PORT)}"
KUMA_PORT="${KUMA_PORT:-3001}"
TZ="${TZ:-Europe/London}"

[[ "$KUMA_IMAGE" =~ ^louislam/uptime-kuma:(2\.[0-9]+\.[0-9]+)$ || "$KUMA_IMAGE" =~ ^louislam/uptime-kuma@sha256:[0-9a-f]{64}$ ]] || {
    echo "KUMA_IMAGE must be an exact stable v2 release or official-repository digest" >&2; exit 1;
}
[[ "$KUMA_BIND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "KUMA_BIND_IP must be IPv4" >&2; exit 1; }
IFS=. read -r -a octets <<<"$KUMA_BIND_IP"
for octet in "${octets[@]}"; do [[ "$((10#$octet))" -le 255 ]] || { echo "Invalid bind address" >&2; exit 1; }; done
[[ "$KUMA_PORT" =~ ^[1-9][0-9]{0,4}$ && "$KUMA_PORT" -le 65535 ]] || { echo "Invalid KUMA_PORT" >&2; exit 1; }
[[ "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo "Invalid TZ" >&2; exit 1; }
[[ "${IMAGE_PULL_TIMEOUT:-1200}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid IMAGE_PULL_TIMEOUT" >&2; exit 1; }

docker info >/dev/null
docker compose version >/dev/null
timeout --foreground "${IMAGE_PULL_TIMEOUT:-1200}" docker pull "$KUMA_IMAGE"
resolved="$(docker image inspect "$KUMA_IMAGE" --format '{{index .RepoDigests 0}}')"
[[ "$resolved" =~ ^louislam/uptime-kuma@sha256:[0-9a-f]{64}$ ]] || { echo "Could not resolve official image digest" >&2; exit 1; }

# Pin the actual pulled image; subsequent runs retain that digest unless overridden.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
printf 'KUMA_IMAGE=%s\nKUMA_BIND_IP=%s\nKUMA_PORT=%s\nTZ=%s\n' "$resolved" "$KUMA_BIND_IP" "$KUMA_PORT" "$TZ" >"$state"
docker compose --project-name homelab-monitoring --env-file "$state" -f "$TEMPLATE" config --quiet
install -d -m 0755 "$STACK_DIR"
install -m 0640 "$state" "$STACK_DIR/.env"
install -m 0644 "$TEMPLATE" "$STACK_DIR/compose.yml"
docker compose --project-name homelab-monitoring --env-file "$STACK_DIR/.env" -f "$STACK_DIR/compose.yml" up -d --pull never --wait --wait-timeout 300
echo "Uptime Kuma healthy at $KUMA_BIND_IP:$KUMA_PORT"
echo "Image: $resolved"
echo "Persistent volume: homelab-uptime-kuma-data"
