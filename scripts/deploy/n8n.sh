#!/usr/bin/env bash
# Run inside apps01. Owner bootstrap must complete before adding the proxy route.
set -euo pipefail
set +x
fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
compose() { docker compose --project-name homelab-n8n --env-file "$ROOT/current/.env" -f "$ROOT/current/compose.yml" "$@"; }
verify_release() {
    local release="$1"
    [[ -d "$release" && ! -L "$release" && -z "$(find "$release" -type l -print -quit)" ]] || return 1
    (cd "$release" && sha256sum --check --status MANIFEST &&
        diff -u <(find . -type f ! -path ./MANIFEST -printf '%P\n' | sort) <(sed -E 's/^[a-f0-9]{64} [ *]//' MANIFEST | sort))
}
verify_secret() {
    local entry name
    [[ -d "$SECRET" && ! -L "$SECRET" && "$(stat -c '%u:%a' "$SECRET")" == 0:700 ]] || return 1
    for name in encryption-key postgres-password runner-token n8n.env postgres.env runners.env managed-v1; do
        [[ -f "$SECRET/$name" && ! -L "$SECRET/$name" && "$(stat -c '%u:%a' "$SECRET/$name")" == 0:600 ]] || return 1
    done
    while IFS= read -r entry; do
        [[ -f "$entry" && ! -L "$entry" && "$(stat -c '%u:%a' "$entry")" == 0:600 ]] || return 1
        case "${entry##*/}" in
            encryption-key|postgres-password|runner-token|n8n.env|postgres.env|runners.env|managed-v1|owner.json|bootstrap.json) ;;
            *) return 1 ;;
        esac
    done < <(find "$SECRET" -mindepth 1 -maxdepth 1 -print)
    for name in encryption-key postgres-password runner-token; do
        [[ "$(wc -c < "$SECRET/$name")" == 65 ]] && grep -Eq '^[a-f0-9]{64}$' "$SECRET/$name" || return 1
    done
    [[ "$(wc -l < "$SECRET/managed-v1")" == 6 ]] || return 1
    diff -u <(sed -E 's/^[a-f0-9]{64} [ *]//' "$SECRET/managed-v1" | sort) <(printf '%s\n' encryption-key postgres-password runner-token n8n.env postgres.env runners.env | sort) >/dev/null || return 1
    (cd "$SECRET" && sha256sum --check --status managed-v1)
}
create_secret() {
    install -d -m 0700 "$SECRET"
    python3 - "$SECRET" <<'PY'
import hashlib, pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
values = {name: secrets.token_hex(32) for name in ('encryption-key', 'postgres-password', 'runner-token')}
files = {name: value + '\n' for name, value in values.items()}
files['postgres.env'] = 'POSTGRES_DB=n8n\nPOSTGRES_USER=n8n\nPOSTGRES_PASSWORD=' + values['postgres-password'] + '\n'
files['n8n.env'] = '\n'.join(('N8N_ENCRYPTION_KEY=' + values['encryption-key'], 'DB_POSTGRESDB_PASSWORD=' + values['postgres-password'], 'N8N_RUNNERS_AUTH_TOKEN=' + values['runner-token'], ''))
files['runners.env'] = 'N8N_RUNNERS_AUTH_TOKEN=' + values['runner-token'] + '\n'
for name, value in files.items():
    with (root / name).open('x', encoding='ascii') as stream:
        stream.write(value)
    (root / name).chmod(0o600)
with (root / 'managed-v1').open('x', encoding='ascii') as stream:
    for name in sorted(files):
        stream.write(hashlib.sha256((root / name).read_bytes()).hexdigest() + '  ' + name + '\n')
(root / 'managed-v1').chmod(0o600)
PY
}
main() {
    [[ $# == 0 ]] || { fail 'Usage: n8n.sh'; return 1; }
    [[ "$(id -u)" == 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing application installation on a Proxmox host'; return 1; }
    ROOT="${N8N_STACK_DIR:-/opt/homelab/n8n}"
    SECRET="${N8N_SECRET_DIR:-/etc/homelab/n8n}"
    CA_FILE="${N8N_CA_FILE:-/opt/homelab/reverse-proxy/root.crt}"
    local template="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/n8n" && pwd)"
    [[ "$ROOT" =~ ^/[a-zA-Z0-9/_-]+$ && "$ROOT" != / && "$ROOT" != */ && "$SECRET" =~ ^/[a-zA-Z0-9/_-]+$ && "$SECRET" != / && "$SECRET" != */ ]] || { fail 'Invalid private directory'; return 1; }
    [[ "$ROOT" != "$SECRET" && "$ROOT" != "$SECRET/"* && "$SECRET" != "$ROOT/"* ]] || { fail 'Private directories must be separate'; return 1; }
    [[ "$CA_FILE" =~ ^/[a-zA-Z0-9/_.-]+$ && -f "$CA_FILE" && ! -L "$CA_FILE" ]] || { fail 'Existing regular public Caddy root certificate required'; return 1; }
    openssl x509 -in "$CA_FILE" -noout -checkend 0 >/dev/null 2>&1 || { fail 'Public Caddy root certificate invalid or expired'; return 1; }
    [[ ! -L "$ROOT" && ( ! -e "$ROOT" || ( -f "$ROOT/.homelab-n8n-managed" && ! -L "$ROOT/.homelab-n8n-managed" ) ) ]] || { fail 'Unknown existing stack; nothing overwritten'; return 1; }
    [[ ! -L "$ROOT/releases" && ( ! -e "$ROOT/releases" || -d "$ROOT/releases" ) ]] || { fail 'Unknown releases directory'; return 1; }
    if [[ -e "$SECRET" || -L "$SECRET" ]]; then verify_secret || { fail 'Private configuration changed; nothing overwritten'; return 1; }; fi
    umask 077
    local lock="${N8N_LOCK_FILE:-/var/lib/homelab/n8n.lock}"
    [[ "$lock" =~ ^/[a-zA-Z0-9/_.-]+$ && ! -L "$lock" ]] || { fail 'Invalid lock file'; return 1; }
    install -d -m 0700 "$(dirname -- "$lock")"
    exec 9>"$lock"
    flock -n 9 || { fail 'Another n8n deployment or backup is running'; return 1; }
    [[ "$(docker network inspect homelab-proxy_default --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Expected existing owned Caddy network'; return 1; }
    local previous='' images='' containers volumes cid service expected volume
    if [[ -L "$ROOT/current" ]]; then
        previous="$(readlink "$ROOT/current")"
        [[ "$previous" =~ ^releases/release\.[a-zA-Z0-9]+$ ]] || { fail 'Unknown current release'; return 1; }
        verify_release "$ROOT/$previous" || { fail 'Existing configuration changed; nothing overwritten'; return 1; }
        verify_secret || { fail 'Existing secrets missing or changed'; return 1; }
    else
        [[ ! -e "$ROOT/current" ]] || { fail 'Unknown current configuration'; return 1; }
    fi
    containers="$(docker ps -a --filter label=com.docker.compose.project=homelab-n8n --format '{{.ID}}')"
    if [[ -n "$containers" ]]; then
        [[ -n "$previous" ]] || { fail 'Existing project containers require ownership inspection'; return 1; }
        while read -r cid; do
            [[ "$(docker inspect "$cid" --format '{{index .Config.Labels "io.homelab.managed"}}')" == n8n-v1 ]] || { fail 'Unknown project container'; return 1; }
            service="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}')"
            case "$service" in
                n8n) expected='volume:homelab-n8n-data'; volume='/home/node/.n8n' ;;
                postgres) expected='volume:homelab-n8n-postgres17-data'; volume='/var/lib/postgresql/data' ;;
                runners) expected=''; volume='not-a-volume' ;;
                *) fail 'Unknown project service'; return 1 ;;
            esac
            [[ "$(docker inspect "$cid" --format "{{range .Mounts}}{{if eq .Destination \"$volume\"}}{{.Type}}:{{.Name}}{{end}}{{end}}")" == "$expected" ]] || { fail 'Unexpected persistent data mount'; return 1; }
        done <<< "$containers"
    fi
    volumes="$(docker volume ls --format '{{.Name}}')"
    for volume in homelab-n8n-data homelab-n8n-postgres17-data; do
        if grep -Fxq "$volume" <<< "$volumes"; then
            [[ -n "$previous" && "$(docker volume inspect "$volume" --format '{{index .Labels "io.homelab.managed"}}')" == n8n-v1 ]] || { fail 'Existing volume requires ownership inspection'; return 1; }
        elif [[ -n "$previous" ]]; then fail 'Managed data volume missing; refusing empty replacement'; return 1
        fi
    done
    local image runner postgres key chosen resolved
    image=docker.n8n.io/n8nio/n8n:2.47.7
    runner=n8nio/runners:2.47.7
    postgres=postgres:17.12-alpine
    if [[ -n "$previous" ]]; then
        image="$(sed -n 's/^N8N_IMAGE=//p' "$ROOT/current/.env")"
        runner="$(sed -n 's/^N8N_RUNNERS_IMAGE=//p' "$ROOT/current/.env")"
        postgres="$(sed -n 's/^N8N_POSTGRES_IMAGE=//p' "$ROOT/current/.env")"
        [[ "$image" =~ ^docker.n8n.io/n8nio/n8n@sha256:[a-f0-9]{64}$ && "$runner" =~ ^n8nio/runners@sha256:[a-f0-9]{64}$ && "$postgres" =~ ^postgres@sha256:[a-f0-9]{64}$ ]] || { fail 'Invalid pinned images'; return 1; }
    fi
    for key in image runner postgres; do
        chosen="${!key}"
        timeout --foreground 1200 docker pull "$chosen"
        resolved="$(docker image inspect "$chosen" --format '{{index .RepoDigests 0}}')"
        case "$key" in
            image) [[ "$resolved" =~ ^docker.n8n.io/n8nio/n8n@sha256:[a-f0-9]{64}$ ]] ;;
            runner) [[ "$resolved" =~ ^n8nio/runners@sha256:[a-f0-9]{64}$ ]] ;;
            postgres) [[ "$resolved" =~ ^postgres@sha256:[a-f0-9]{64}$ ]] ;;
        esac || { fail 'Official image digest unresolved'; return 1; }
        [[ -z "$previous" || "$chosen" == "$resolved" ]] || { fail 'Pinned image changed; upgrades require backup and review'; return 1; }
        printf -v "$key" '%s' "$resolved"
    done
    if [[ ! -e "$SECRET" ]]; then create_secret; fi
    verify_secret || { fail 'Private configuration verification failed'; return 1; }
    install -d -m 0700 "$ROOT" "$ROOT/releases"
    touch "$ROOT/.homelab-n8n-managed"
    local release pending status=0
    release="$(mktemp -d "$ROOT/releases/release.XXXXXX")"
    install -m 0600 "$template/docker-compose.yml" "$release/compose.yml"
    printf 'N8N_IMAGE=%s\nN8N_RUNNERS_IMAGE=%s\nN8N_POSTGRES_IMAGE=%s\nN8N_SECRET_DIR=%s\nN8N_CA_FILE=%s\n' "$image" "$runner" "$postgres" "$SECRET" "$CA_FILE" > "$release/.env"
    (cd "$release" && sha256sum compose.yml .env > MANIFEST)
    verify_release "$release" || return 1
    docker compose --project-name homelab-n8n --env-file "$release/.env" -f "$release/compose.yml" config --quiet
    for volume in homelab-n8n-data homelab-n8n-postgres17-data; do
        if ! grep -Fxq "$volume" <<< "$volumes"; then docker volume create --label io.homelab.managed=n8n-v1 "$volume" >/dev/null; fi
    done
    pending="releases/${release##*/}"
    [[ ! -e "$ROOT/.current-next" && ! -L "$ROOT/.current-next" ]] || { fail 'Unexpected activation link'; return 1; }
    ln -s "$pending" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
    compose up -d --force-recreate --pull never --wait --wait-timeout 360 || status=$?
    if [[ "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            ln -s "$previous" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
            compose up -d --force-recreate --pull never --wait --wait-timeout 360 || { fail 'Rollback failed; inspect retained releases'; return 1; }
        else
            compose stop --timeout 60 || true
        fi
        fail 'n8n failed; previous release restored or new services stopped; data and private state retained'
        return 1
    fi
    printf 'n8n, PostgreSQL and external runners healthy; owner bootstrap required before proxy activation\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
