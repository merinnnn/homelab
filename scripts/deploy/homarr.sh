#!/usr/bin/env bash
# Run inside apps01. Administrator bootstrap is a separate private operation.
set -euo pipefail
set +x
fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
compose() { docker compose --project-name homelab-homarr --env-file "$ROOT/current/.env" -f "$ROOT/current/compose.yml" "$@"; }
verify_release() {
    local release="$1"
    [[ -d "$release" && ! -L "$release" && -z "$(find "$release" -type l -print -quit)" ]] || return 1
    (cd "$release" && sha256sum --check --status MANIFEST &&
        diff -u <(find . -type f ! -path ./MANIFEST -printf '%P\n' | sort) <(sed -E 's/^[a-f0-9]{64} [ *]//' MANIFEST | sort))
}
verify_secret() {
    local private_file name
    [[ -d "$SECRET" && ! -L "$SECRET" && "$(stat -c '%u:%a' "$SECRET")" == 0:700 ]] || return 1
    [[ -f "$SECRET/encryption-key" && ! -L "$SECRET/encryption-key" && "$(stat -c '%u:%a' "$SECRET/encryption-key")" == 0:600 ]] || return 1
    [[ -f "$SECRET/managed-v1" && ! -L "$SECRET/managed-v1" && "$(stat -c '%u:%a' "$SECRET/managed-v1")" == 0:600 ]] || return 1
    while IFS= read -r private_file; do
        name="${private_file##*/}"
        case "$name" in
            encryption-key|managed-v1) ;;
            admin.json|bootstrap.json)
                [[ -f "$private_file" && ! -L "$private_file" && "$(stat -c '%u:%a' "$private_file")" == 0:600 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$SECRET" -mindepth 1 -maxdepth 1 -print)
    [[ "$(wc -c < "$SECRET/encryption-key")" == 65 ]] || return 1
    grep -Eq '^[a-f0-9]{64}$' "$SECRET/encryption-key" || return 1
    [[ "$(wc -l < "$SECRET/managed-v1")" == 1 ]] || return 1
    grep -Eq '^[a-f0-9]{64} [ *]encryption-key$' "$SECRET/managed-v1" || return 1
    (cd "$SECRET" && sha256sum --check --status managed-v1)
}
main() {
    [[ $# == 0 ]] || { fail 'Usage: homarr.sh'; return 1; }
    [[ "$(id -u)" == 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing application installation on a Proxmox host'; return 1; }
    ROOT="${HOMARR_STACK_DIR:-/opt/homelab/homarr}"
    SECRET="${HOMARR_SECRET_DIR:-/etc/homelab/homarr}"
    CA_FILE="${HOMARR_CA_FILE:-/opt/homelab/reverse-proxy/root.crt}"
    local template="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/homarr" && pwd)"
    [[ "$ROOT" =~ ^/[a-zA-Z0-9/_-]+$ && "$ROOT" != / && "$ROOT" != */ && "$SECRET" =~ ^/[a-zA-Z0-9/_-]+$ && "$SECRET" != / && "$SECRET" != */ ]] || { fail 'Invalid private directory'; return 1; }
    [[ "$ROOT" != "$SECRET" && "$ROOT" != "$SECRET/"* && "$SECRET" != "$ROOT/"* ]] || { fail 'Private directories must be separate'; return 1; }
    [[ "$CA_FILE" =~ ^/[a-zA-Z0-9/_.-]+$ && -f "$CA_FILE" && ! -L "$CA_FILE" ]] || { fail 'Existing regular public Caddy root certificate required'; return 1; }
    openssl x509 -in "$CA_FILE" -noout -checkend 0 >/dev/null 2>&1 || { fail 'Public Caddy root certificate is invalid or expired'; return 1; }
    [[ ! -L "$ROOT" && ( ! -e "$ROOT" || ( -f "$ROOT/.homelab-homarr-managed" && ! -L "$ROOT/.homelab-homarr-managed" ) ) ]] || { fail 'Unknown existing stack; nothing overwritten'; return 1; }
    [[ ! -L "$ROOT/releases" && ( ! -e "$ROOT/releases" || -d "$ROOT/releases" ) ]] || { fail 'Unknown releases directory'; return 1; }
    if [[ -e "$SECRET" || -L "$SECRET" ]]; then verify_secret || { fail 'Private key ownership or bytes changed; nothing overwritten'; return 1; }; fi
    umask 077
    mkdir -p "$ROOT/releases"
    touch "$ROOT/.homelab-homarr-managed"
    exec 9>"$ROOT/.lock"
    flock -n 9 || { fail 'Another Homarr deployment is running'; return 1; }
    [[ "$(docker network inspect homelab-proxy_default --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Expected the existing owned Caddy network'; return 1; }
    local previous='' image='' containers volumes
    if [[ -L "$ROOT/current" ]]; then
        previous="$(readlink "$ROOT/current")"
        [[ "$previous" =~ ^releases/release\.[a-zA-Z0-9]+$ ]] || { fail 'Unknown current release'; return 1; }
        verify_release "$ROOT/$previous" || { fail 'Existing configuration changed; nothing overwritten'; return 1; }
        verify_secret || { fail 'Existing private key missing or changed'; return 1; }
        image="$(sed -n 's/^HOMARR_IMAGE=//p' "$ROOT/current/.env")"
    else
        [[ ! -e "$ROOT/current" ]] || { fail 'Unknown current configuration'; return 1; }
    fi
    containers="$(docker ps -a --filter label=com.docker.compose.project=homelab-homarr --format '{{.ID}}')"
    if [[ -n "$containers" ]]; then
        [[ -n "$previous" ]] || { fail 'Existing project containers require ownership inspection'; return 1; }
        while read -r cid; do
            [[ "$(docker inspect "$cid" --format '{{index .Config.Labels "io.homelab.managed"}}:{{index .Config.Labels "com.docker.compose.service"}}')" == homarr-v1:homarr ]] || { fail 'Unknown project container'; return 1; }
            [[ "$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/appdata"}}{{.Type}}:{{.Name}}{{end}}{{end}}')" == volume:homelab-homarr-data ]] || { fail 'Unexpected persistent data mount'; return 1; }
        done <<< "$containers"
    fi
    volumes="$(docker volume ls --format '{{.Name}}')"
    if grep -Fxq homelab-homarr-data <<< "$volumes"; then
        [[ -n "$previous" && "$(docker volume inspect homelab-homarr-data --format '{{index .Labels "io.homelab.managed"}}')" == homarr-v1 ]] || { fail 'Existing volume requires ownership inspection'; return 1; }
    elif [[ -n "$previous" ]]; then fail 'Managed data volume missing; refusing to create an empty replacement'; return 1
    fi
    image="${HOMARR_IMAGE:-${image:-ghcr.io/homarr-labs/homarr:v2.10.1}}"
    [[ "$image" == ghcr.io/homarr-labs/homarr:v2.10.1 || "$image" =~ ^ghcr.io/homarr-labs/homarr@sha256:[a-f0-9]{64}$ ]] || { fail 'Use the reviewed official release or digest'; return 1; }
    timeout --foreground 1200 docker pull "$image"
    image="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')"
    [[ "$image" =~ ^ghcr.io/homarr-labs/homarr@sha256:[a-f0-9]{64}$ ]] || { fail 'Official image digest could not be resolved'; return 1; }
    [[ -z "$previous" || "$image" == "$(sed -n 's/^HOMARR_IMAGE=//p' "$ROOT/current/.env")" ]] || { fail 'Image upgrades require backup and separate review'; return 1; }
    if [[ ! -e "$SECRET" ]]; then
        install -d -m 0700 "$SECRET"
        openssl rand -hex 32 > "$SECRET/encryption-key"
        chmod 0600 "$SECRET/encryption-key"
        (cd "$SECRET" && sha256sum encryption-key > managed-v1)
        chmod 0600 "$SECRET/managed-v1"
    fi
    verify_secret || { fail 'Private key verification failed'; return 1; }
    local release pending status=0
    release="$(mktemp -d "$ROOT/releases/release.XXXXXX")"
    install -m 0600 "$template/docker-compose.yml" "$release/compose.yml"
    printf 'HOMARR_IMAGE=%s\nHOMARR_SECRET_DIR=%s\nHOMARR_CA_FILE=%s\n' "$image" "$SECRET" "$CA_FILE" > "$release/.env"
    (cd "$release" && sha256sum compose.yml .env > MANIFEST)
    verify_release "$release" || return 1
    docker compose --project-name homelab-homarr --env-file "$release/.env" -f "$release/compose.yml" config --quiet
    if ! grep -Fxq homelab-homarr-data <<< "$volumes"; then
        docker volume create --label io.homelab.managed=homarr-v1 homelab-homarr-data >/dev/null
    fi
    pending="releases/${release##*/}"
    ln -s "$pending" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
    compose up -d --force-recreate --pull never --wait --wait-timeout 300 || status=$?
    if [[ "$status" == 0 ]]; then
        compose exec -T homarr wget -q --spider http://127.0.0.1:7575/api/health/live || status=$?
    fi
    if [[ "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            ln -s "$previous" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
            compose up -d --force-recreate --pull never --wait --wait-timeout 300 || { fail 'Rollback failed; inspect retained releases'; return 1; }
        else
            compose down || true
            rm "$ROOT/current"
        fi
        fail 'Homarr failed; prior configuration restored or new container stopped; private data retained'
        return 1
    fi
    printf 'Homarr healthy on the private proxy network; administrator bootstrap remains separate; image %s\n' "$image"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
