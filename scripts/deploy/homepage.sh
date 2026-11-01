#!/usr/bin/env bash
# Run inside apps01. This dashboard contains links only, no service API secrets.
set -euo pipefail
fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
compose() { docker compose --project-name homelab-homepage --env-file "$ROOT/current/.env" -f "$ROOT/current/compose.yml" "$@"; }
verify_release() {
    local release="$1"
    [[ -z "$(find "$release" -type l -print -quit)" ]] || return 1
    (cd "$release" && sha256sum --check --status MANIFEST &&
        diff -u <(find . -type f ! -path ./MANIFEST -printf '%P\n' | sort) <(sed -E 's/^[a-f0-9]{64} [ *]//' MANIFEST | sort))
}
main() {
    [[ $# == 0 ]] || { fail 'Usage: homepage.sh'; return 1; }
    [[ "$(id -u)" == 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing application installation on a Proxmox host'; return 1; }
    ROOT="${HOMEPAGE_STACK_DIR:-/opt/homelab/homepage}"
    local template="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/homepage" && pwd)"
    [[ "$ROOT" =~ ^/[a-zA-Z0-9/_-]+$ && "$ROOT" != / && "$ROOT" != */ ]] || { fail 'Invalid stack directory'; return 1; }
    [[ ! -e "$ROOT" || -f "$ROOT/.homelab-homepage-managed" ]] || { fail 'Unknown existing stack; nothing overwritten'; return 1; }
    umask 077
    mkdir -p "$ROOT/releases"
    touch "$ROOT/.homelab-homepage-managed"
    exec 9>"$ROOT/.lock"
    flock -n 9 || { fail 'Another Homepage deployment is running'; return 1; }
    [[ "$(docker network inspect homelab-proxy_default --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Expected the existing owned Caddy network'; return 1; }
    local previous='' image='' existing
    if [[ -L "$ROOT/current" ]]; then
        previous="$(readlink "$ROOT/current")"
        [[ "$previous" =~ ^releases/release\.[a-zA-Z0-9]+$ ]] || { fail 'Unknown current release'; return 1; }
        verify_release "$ROOT/$previous" || { fail 'Existing configuration changed or contains unknown files; nothing overwritten'; return 1; }
        image="$(sed -n 's/^HOMEPAGE_IMAGE=//p' "$ROOT/current/.env")"
    else
        [[ ! -e "$ROOT/current" ]] || { fail 'Unknown current configuration'; return 1; }
        existing="$(docker ps -a --filter label=com.docker.compose.project=homelab-homepage --format '{{.ID}}')" || return 1
        [[ -z "$existing" ]] || { fail 'Existing Homepage containers require ownership inspection'; return 1; }
    fi
    image="${HOMEPAGE_IMAGE:-${image:-ghcr.io/gethomepage/homepage:v2.7.0}}"
    [[ "$image" == ghcr.io/gethomepage/homepage:v2.7.0 || "$image" =~ ^ghcr.io/gethomepage/homepage@sha256:[a-f0-9]{64}$ ]] || { fail 'Use the reviewed official release or digest'; return 1; }
    timeout --foreground 1200 docker pull "$image"
    image="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')"
    [[ "$image" =~ ^ghcr.io/gethomepage/homepage@sha256:[a-f0-9]{64}$ ]] || { fail 'Official image digest could not be resolved'; return 1; }
    [[ -z "$previous" || "$image" == "$(sed -n 's/^HOMEPAGE_IMAGE=//p' "$ROOT/current/.env")" ]] || { fail 'Image upgrades require separate review'; return 1; }
    local release pending status=0
    release="$(mktemp -d "$ROOT/releases/release.XXXXXX")"
    mkdir "$release/config"
    # Seed every required skeleton from the exact image so read-only startup
    # never needs to create missing configuration files.
    docker run --rm --network none --entrypoint sh -v "$release/config:/target" "$image" -c 'cp -a /app/src/skeleton/. /target/'
    cp -a "$template/config/." "$release/config/"
    install -m 0644 "$template/docker-compose.yml" "$release/compose.yml"
    printf 'HOMEPAGE_IMAGE=%s\nHOMEPAGE_STACK_DIR=%s\n' "$image" "$ROOT" > "$release/.env"
    (cd "$release" && find config -type f -print0 | sort -z | xargs -0 sha256sum > MANIFEST && sha256sum compose.yml .env >> MANIFEST)
    verify_release "$release" || return 1
    docker compose --project-name homelab-homepage --env-file "$release/.env" -f "$release/compose.yml" config --quiet
    pending="releases/${release##*/}"
    ln -s "$pending" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
    compose up -d --force-recreate --pull never --wait --wait-timeout 180 || status=$?
    if [[ "$status" == 0 ]]; then
        compose exec -T homepage wget -q -O /dev/null --header='Host: home.home.arpa' http://127.0.0.1:3000/ || status=$?
    fi
    if [[ "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            ln -s "$previous" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
            compose up -d --force-recreate --pull never --wait --wait-timeout 180 || { fail 'Rollback failed; inspect retained releases'; return 1; }
        else compose down; rm "$ROOT/current"; fi
        fail 'Homepage failed; previous configuration restored or new container stopped'
        return 1
    fi
    printf 'Homepage healthy on the private proxy network; image %s; release %s; prior %s\n' "$image" "$pending" "${previous:-none}"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
