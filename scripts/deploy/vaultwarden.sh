#!/usr/bin/env bash
# Run inside the permanent apps01 Docker VM; credentials remain outside Git.
set +x
set -euo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
main() {
    [[ $# -le 1 ]] || { fail 'Usage: vaultwarden.sh [compose-template]'; return 1; }
    [[ $EUID -eq 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing deployment on a Proxmox host'; return 1; }
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || { fail 'Expected Debian 13'; return 1; }
    local template="${1:-$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/vaultwarden/compose.json}"
    local runtime="$(dirname -- "${BASH_SOURCE[0]}")/vaultwarden-runtime.py"
    local stack=/opt/homelab/vaultwarden image resolved version cid existing
    [[ -f "$template" && -f "$runtime" ]] || { fail 'Repository compose/runtime payloads are required'; return 1; }
    command -v python3 >/dev/null
    command -v flock >/dev/null
    install -d -m 700 /var/lib/homelab
    exec 9>/var/lib/homelab/vaultwarden.lock
    flock -n 9 || { fail 'Another Vaultwarden deployment is active'; return 1; }
    docker info >/dev/null
    python3 - "$(docker compose version --short)" <<'PY'
import re,sys
match=re.match(r'v?(\d+)\.(\d+)\.(\d+)',sys.argv[1])
if not match or tuple(map(int,match.groups()))<(2,30,0):
    raise SystemExit('Compose >=2.30 is required for literal private env values')
PY
    [[ "$(docker network inspect homelab-proxy_default --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Expected the existing managed Caddy network'; return 1; }
    if [[ -e "$stack" ]]; then
        [[ -d "$stack" && ! -L "$stack" && "$(stat -c %u "$stack")" == 0 ]] || { fail 'Expected a root-owned stack directory'; return 1; }
        if [[ -e "$stack/managed-v1" ]]; then
            [[ -f "$stack/managed-v1" && ! -L "$stack/managed-v1" && "$(stat -c %u "$stack/managed-v1")" == 0 && "$(stat -c %a "$stack/managed-v1")" == 600 && "$(cat "$stack/managed-v1")" == homelab-vaultwarden-v1 ]] || { fail 'Unexpected stack ownership marker'; return 1; }
        else
            [[ -z "$(find "$stack" -mindepth 1 -print -quit)" ]] || { fail 'Unmanaged nonempty stack directory; preserved'; return 1; }
        fi
    fi
    if [[ -e "$stack/compose.json" ]]; then
        [[ -f "$stack/compose.json" && ! -L "$stack/compose.json" && "$(stat -c %u "$stack/compose.json")" == 0 && "$(stat -c %a "$stack/compose.json")" == 600 ]] && cmp -s "$template" "$stack/compose.json" || { fail 'Installed compose differs or has unsafe ownership; review before changing the stack'; return 1; }
    fi
    existing="$(docker ps -aq --filter label=com.docker.compose.project=homelab-vaultwarden)"
    if [[ -n "$existing" ]]; then
        while IFS= read -r cid; do
            [[ "$(docker inspect "$cid" --format '{{index .Config.Labels "io.homelab.managed"}}')" == vaultwarden-v1 ]] || { fail 'Unmanaged container uses the target project; preserved'; return 1; }
        done <<< "$existing"
    fi
    if docker volume inspect homelab-vaultwarden-data >/dev/null 2>&1; then
        [[ "$(docker volume inspect homelab-vaultwarden-data --format '{{index .Labels "io.homelab.managed"}}')" == vaultwarden-v1 ]] || { fail 'Unmanaged data volume exists; preserved'; return 1; }
    fi
    image=vaultwarden/server:1.37.4
    if [[ -f "$stack/.env" ]]; then
        [[ ! -L "$stack/.env" && "$(stat -c %u "$stack/.env")" == 0 && "$(stat -c %a "$stack/.env")" == 600 && "$(wc -l < "$stack/.env")" -eq 1 ]] || { fail 'Unexpected installed image-pin file'; return 1; }
        image="$(sed -n 's/^VAULTWARDEN_IMAGE=//p' "$stack/.env")"
        [[ "$image" =~ ^vaultwarden/server@sha256:[0-9a-f]{64}$ ]] || { fail 'Expected an existing official image digest'; return 1; }
    fi
    printf 'Pulling the reviewed release or existing immutable pin.\n'
    timeout --foreground 1200 docker pull "$image"
    resolved="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')"
    [[ "$resolved" =~ ^vaultwarden/server@sha256:[0-9a-f]{64}$ ]] || { fail 'Could not resolve the official image digest'; return 1; }
    if [[ "$image" == *@sha256:* ]]; then [[ "$resolved" == "$image" ]] || { fail 'Pulled digest differs from the existing pin'; return 1; }; fi
    version="$(timeout 60 docker run --rm --network none --read-only --cap-drop ALL "$resolved" /vaultwarden --version)"
    grep -Fxq 'Vaultwarden 1.37.4' <<< "$version" || { fail 'Pinned image version is not the reviewed release'; return 1; }
    install -d -m 700 "$stack"
    if [[ ! -e "$stack/managed-v1" ]]; then printf 'homelab-vaultwarden-v1\n' > "$stack/managed-v1"; fi
    printf 'Preparing protected admin/runtime configuration.\n'
    python3 "$runtime" prepare --image "$resolved"
    if ! docker volume inspect homelab-vaultwarden-data >/dev/null 2>&1; then
        docker volume create --label io.homelab.managed=vaultwarden-v1 homelab-vaultwarden-data >/dev/null
        docker run --rm --network none --read-only --cap-drop ALL --mount type=volume,src=homelab-vaultwarden-data,dst=/data "$resolved" sh -ec 'chmod 700 /data'
    fi
    docker run --rm --network none --read-only --cap-drop ALL --mount type=volume,src=homelab-vaultwarden-data,dst=/data,readonly "$resolved" sh -ec 'test ! -e /data/config.json' || { fail 'Admin config.json overrides require review; existing data preserved'; return 1; }
    export VAULTWARDEN_IMAGE="$resolved"
    docker compose --project-name homelab-vaultwarden -f "$template" config --quiet
    if [[ ! -e "$stack/compose.json" ]]; then install -m 600 "$template" "$stack/compose.json"; fi
    if [[ ! -e "$stack/.env" ]]; then printf 'VAULTWARDEN_IMAGE=%s\n' "$resolved" > "$stack/.env"; fi
    docker compose --project-name homelab-vaultwarden --env-file "$stack/.env" -f "$stack/compose.json" up -d --pull never --wait --wait-timeout 180
    cid="$(docker compose --project-name homelab-vaultwarden --env-file "$stack/.env" -f "$stack/compose.json" ps -q vaultwarden)"
    [[ -n "$cid" && "$cid" != *$'\n'* ]] || { fail 'Expected exactly one Vaultwarden container'; return 1; }
    python3 "$runtime" verify --container "$cid"
    python3 "$runtime" auth --container "$cid"
    printf 'Vaultwarden ready on internal Docker alias homelab-vaultwarden:80. Image: %s\n' "$resolved"
    printf 'Persistent data: homelab-vaultwarden-data. Private admin token: /etc/homelab/vaultwarden/admin-token\n'
    printf 'Caddy HTTPS routing, owner registration and backup/restore still require their separate checks.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
