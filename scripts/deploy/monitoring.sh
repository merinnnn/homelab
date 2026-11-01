#!/usr/bin/env bash
# Run inside apps01. Credentials and notification configuration stay outside Git.
set +x
set -euo pipefail
fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
compose() { docker compose --project-name homelab-metrics --env-file "$ROOT/current/.env" -f "$ROOT/current/compose.yml" "$@"; }
verify_release() {
    [[ -z "$(find "$1" -type l -print -quit)" ]] || return 1
    (cd "$1" && sha256sum --check --status MANIFEST &&
        diff -u <(find . -type f ! -path ./MANIFEST -printf '%P\n' | sort) <(sed -E 's/^[a-f0-9]{64} [ *]//' MANIFEST | sort))
}
resolve_image() {
    local key="$1" repository="$2" tag="$3" previous='' image
    [[ ! -e "$ROOT/current/.env" ]] || previous="$(sed -n "s/^$key=//p" "$ROOT/current/.env")"
    image="${!key:-${previous:-$repository:$tag}}"
    [[ "$image" == "$repository:$tag" || "$image" =~ ^$repository@sha256:[a-f0-9]{64}$ ]] || { fail 'Unreviewed image reference'; return 1; }
    timeout --foreground 1200 docker pull "$image" >&2
    image="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')"
    [[ "$image" =~ ^$repository@sha256:[a-f0-9]{64}$ ]] || { fail 'Official repository digest could not be resolved'; return 1; }
    [[ -z "$previous" || "$previous" == "$image" ]] || { fail 'Image upgrades require separate review'; return 1; }
    printf '%s\n' "$image"
}
prepare_private_files() {
    [[ ! -e "$PRIVATE" || -f "$PRIVATE/.homelab-monitoring-managed" ]] || { fail 'Unknown private runtime directory'; return 1; }
    install -d -o 0 -g 0 -m 0700 "$PRIVATE"
    touch "$PRIVATE/.homelab-monitoring-managed"
    if [[ ! -e "$PRIVATE/grafana-admin-password" ]]; then
        openssl rand -hex 32 > "$PRIVATE/grafana-admin-password"
        chmod 0600 "$PRIVATE/grafana-admin-password"
    fi
    [[ ! -L "$PRIVATE/grafana-admin-password" && "$(stat -c '%u:%a' "$PRIVATE/grafana-admin-password")" == 0:600 && "$(wc -c < "$PRIVATE/grafana-admin-password")" -ge 32 ]] || { fail 'Expected a root-owned private Grafana password file'; return 1; }
    # The canonical secret stays root-owned600 in a root700 directory. Only its
    # container-readable copy is owned by Grafana's standard UID472.
    install -o 472 -g 0 -m 0400 "$PRIVATE/grafana-admin-password" "$PRIVATE/grafana-admin-password.container"
    if [[ ! -e "$PRIVATE/alertmanager.yml" ]]; then
        install -m 0600 "$TEMPLATE/alertmanager.default.yml" "$PRIVATE/alertmanager.yml"
    fi
    [[ ! -L "$PRIVATE/alertmanager.yml" && "$(stat -c '%u:%a' "$PRIVATE/alertmanager.yml")" == 0:600 ]] || { fail 'Alertmanager configuration must be root-owned600 outside Git'; return 1; }
}
main() {
    [[ $# == 0 && "$(id -u)" == 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run monitoring.sh as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing application deployment on a Proxmox host'; return 1; }
    ROOT="${MONITORING_STACK_DIR:-/opt/homelab/monitoring}"
    PRIVATE="${MONITORING_PRIVATE_DIR:-/etc/homelab/monitoring}"
    TEMPLATE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/monitoring" && pwd)"
    [[ "$ROOT" =~ ^/[a-zA-Z0-9/_-]+$ && "$ROOT" != / && "$PRIVATE" =~ ^/[a-zA-Z0-9/_-]+$ && "$PRIVATE" != / && "$PRIVATE" != "$ROOT" && "$PRIVATE" != "$ROOT"/* && "$ROOT" != "$PRIVATE"/* ]] || { fail 'Invalid managed directories'; return 1; }
    [[ ! -e "$ROOT" || -f "$ROOT/.homelab-monitoring-managed" ]] || { fail 'Unknown existing stack; nothing overwritten'; return 1; }
    umask 077
    mkdir -p "$ROOT/releases"
    touch "$ROOT/.homelab-monitoring-managed"
    exec 9>"$ROOT/.lock"
    flock -n 9 || { fail 'Another monitoring deployment is running'; return 1; }
    [[ "$(docker network inspect homelab-proxy_default --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Expected the owned Caddy network'; return 1; }
    local previous='' existing volume
    if [[ -L "$ROOT/current" ]]; then
        previous="$(readlink "$ROOT/current")"
        [[ "$previous" =~ ^releases/release\.[a-zA-Z0-9]+$ ]] && verify_release "$ROOT/$previous" || { fail 'Existing configuration drift; nothing overwritten'; return 1; }
    else
        [[ ! -e "$ROOT/current" ]] || { fail 'Unknown current configuration'; return 1; }
        existing="$(docker ps -a --filter label=com.docker.compose.project=homelab-metrics --format '{{.ID}}')" || return 1
        [[ -z "$existing" ]] || { fail 'Existing monitoring containers require ownership inspection'; return 1; }
        for volume in homelab-prometheus-data homelab-grafana-data homelab-alertmanager-data; do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                [[ "$(docker volume inspect "$volume" --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-metrics ]] || { fail 'Unknown existing monitoring data volume'; return 1; }
            fi
        done
    fi
    local prometheus grafana alertmanager release pending status=0
    prometheus="$(resolve_image PROMETHEUS_IMAGE prom/prometheus v3.15.1)"
    grafana="$(resolve_image GRAFANA_IMAGE grafana/grafana 13.3.0)"
    alertmanager="$(resolve_image ALERTMANAGER_IMAGE prom/alertmanager v0.34.2)"
    prepare_private_files
    release="$(mktemp -d "$ROOT/releases/release.XXXXXX")"
    cp -a "$TEMPLATE/prometheus" "$TEMPLATE/grafana" "$release/"
    # Unprivileged official containers need readable public configuration, even
    # when the host caller correctly keeps release/backups private.
    find "$release/prometheus" "$release/grafana" -type d -exec chmod 0755 {} +
    find "$release/prometheus" "$release/grafana" -type f -exec chmod 0644 {} +
    install -m 0644 "$TEMPLATE/docker-compose.yml" "$release/compose.yml"
    printf 'PROMETHEUS_IMAGE=%s\nGRAFANA_IMAGE=%s\nALERTMANAGER_IMAGE=%s\nMONITORING_STACK_DIR=%s\nMONITORING_PRIVATE_DIR=%s\n' "$prometheus" "$grafana" "$alertmanager" "$ROOT" "$PRIVATE" > "$release/.env"
    docker run --rm --network none --entrypoint /bin/promtool -v "$release/prometheus:/etc/prometheus:ro" "$prometheus" check config /etc/prometheus/prometheus.yml
    docker run --rm --network none --entrypoint /bin/promtool -v "$release/prometheus:/work:ro" -w /work "$prometheus" test rules node-alerts.test.yml
    # Capture detailed receiver/config errors privately: URLs or tokens must not
    # be emitted by a failed config validator into shared deployment output.
    install -o 0 -g 0 -m 0600 /dev/null "$PRIVATE/alertmanager-validation.log"
    if ! docker run --rm --network none --user 0:0 --entrypoint /bin/amtool -v "$PRIVATE/alertmanager.yml:/config.yml:ro" "$alertmanager" check-config /config.yml > "$PRIVATE/alertmanager-validation.log" 2>&1; then
        fail 'Alertmanager configuration invalid; inspect its root-only validation log'; return 1
    fi
    (cd "$release" && find prometheus grafana -type f -print0 | sort -z | xargs -0 sha256sum > MANIFEST && sha256sum compose.yml .env >> MANIFEST)
    docker compose --project-name homelab-metrics --env-file "$release/.env" -f "$release/compose.yml" config --quiet
    # Runtime notification settings can contain secrets. Retain the previous
    # container-readable copy privately for rollback and never put it in a release.
    [[ ! -f "$PRIVATE/alertmanager.container.yml" ]] || cp -p "$PRIVATE/alertmanager.container.yml" "$PRIVATE/alertmanager.previous.yml"
    install -o 65534 -g 65534 -m 0400 "$PRIVATE/alertmanager.yml" "$PRIVATE/alertmanager.container.yml"
    pending="releases/${release##*/}"
    ln -s "$pending" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
    compose up -d --force-recreate --pull never --wait --wait-timeout 240 || status=$?
    if [[ "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            [[ ! -f "$PRIVATE/alertmanager.previous.yml" ]] || cp -p "$PRIVATE/alertmanager.previous.yml" "$PRIVATE/alertmanager.container.yml"
            ln -s "$previous" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
            compose up -d --force-recreate --pull never --wait --wait-timeout 240 || { fail 'Monitoring rollback failed; retained data/config require inspection'; return 1; }
        else compose down; rm "$ROOT/current"; fi
        fail 'Monitoring apply failed; prior configuration restored or new project stopped'; return 1
    fi
    printf 'Monitoring healthy; release %s; prior %s. Persistent data volumes retained.\n' "$pending" "${previous:-none}"
    printf 'Grafana admin password is in the root-only runtime store. External notifications require a configured channel and delivery test.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
