#!/usr/bin/env bash
# Run as root inside apps01; passwords and TLS private keys never enter Git.
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
validate_domain() {
    local label
    [[ ${#1} -le 240 && "$1" == *.* && "$1" != .* && "$1" != *. && "$1" != *..* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
render_config() {
    validate_domain "$1" || { fail 'Invalid local domain'; return 1; }
    sed "s/@DOMAIN@/$1/g" "$TEMPLATE_DIR/Caddyfile.template"
}
compose() { docker compose --project-name homelab-proxy --env-file "$ROOT/current/.env" -f "$ROOT/current/compose.yml" "$@"; }
verify_manifest() { (cd "$1" && sha256sum --check --status MANIFEST); }
verify_endpoints() {
    local domain="$1" bind="$2" name uri
    # Only the public CA certificate leaves Caddy's private data volume.
    compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > "$ROOT/.root.crt.next" || return 1
    openssl x509 -in "$ROOT/.root.crt.next" -noout >/dev/null || return 1
    install -m 0644 "$ROOT/.root.crt.next" "$ROOT/root.crt" || return 1
    rm "$ROOT/.root.crt.next"
    for name in pve01 pve02 pihole01 pihole02 uptime proxy; do
        uri=/; [[ "$name" != pihole* ]] || uri=/admin/
        curl --noproxy '*' --fail --silent --show-error --location --connect-timeout 5 --max-time 30 \
            --resolve "$name.$domain:443:$bind" --cacert "$ROOT/root.crt" "https://$name.$domain$uri" >/dev/null || return 1
    done
}
main() {
    local action="${1-}" domain="${2-home.arpa}" trust="${3-}"
    TEMPLATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../configs/docker/reverse-proxy" && pwd)"
    if [[ "$action" == render ]]; then [[ $# -le 2 ]] || return 1; render_config "$domain"; return; fi
    [[ "$action" == apply && $# -ge 3 && $# -le 4 ]] || { fail 'Usage: reverse-proxy.sh render [domain] | apply <domain> <public-ca-directory> [bind-ip]'; return 1; }
    validate_domain "$domain" || { fail 'Invalid local domain'; return 1; }
    [[ "$(id -u)" == 0 && "$(hostname -s)" == apps01 ]] || { fail 'Run as root inside apps01'; return 1; }
    ! command -v pveversion >/dev/null || { fail 'Refusing Docker deployment on a Proxmox host'; return 1; }
    ROOT="${PROXY_STACK_DIR:-/opt/homelab/reverse-proxy}"
    local bind="${4-192.168.1.58}"
    [[ "$ROOT" =~ ^/[a-zA-Z0-9/_-]+$ && "$ROOT" != / && "$ROOT" != */ ]] || { fail 'Invalid absolute stack directory'; return 1; }
    [[ "$bind" == 192.168.1.58 ]] || { fail 'This topology requires the verified apps01 address 192.168.1.58'; return 1; }
    [[ ! -e "$ROOT" || -f "$ROOT/.homelab-proxy-managed" ]] || { fail 'Unknown existing stack directory; nothing overwritten'; return 1; }
    umask 077
    mkdir -p "$ROOT/releases"
    touch "$ROOT/.homelab-proxy-managed"
    exec 9>"$ROOT/.lock"
    flock -n 9 || { fail 'Another proxy deployment is running'; return 1; }
    local previous='' image=''
    if [[ -L "$ROOT/current" ]]; then
        previous="$(readlink "$ROOT/current")"
        [[ "$previous" =~ ^releases/release\.[a-zA-Z0-9]+$ ]] || { fail 'Unknown current release'; return 1; }
        verify_manifest "$ROOT/$previous" || { fail 'Installed configuration drift; nothing overwritten'; return 1; }
        image="$(sed -n 's/^CADDY_IMAGE=//p' "$ROOT/current/.env")"
    else
        [[ ! -e "$ROOT/current" ]] || { fail 'Unknown current configuration'; return 1; }
        local existing_containers
        existing_containers="$(docker ps -a --filter label=com.docker.compose.project=homelab-proxy --format '{{.ID}}')" || return 1
        [[ -z "$existing_containers" ]] || { fail 'Existing proxy project containers require ownership inspection'; return 1; }
        local volume
        for volume in homelab-caddy-data homelab-caddy-config; do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                [[ "$(docker volume inspect "$volume" --format '{{index .Labels "com.docker.compose.project"}}')" == homelab-proxy ]] || { fail 'Existing unowned proxy volume requires inspection'; return 1; }
            fi
        done
    fi
    image="${CADDY_IMAGE:-${image:-caddy:2.11.7-alpine}}"
    [[ "$image" == caddy:2.11.7-alpine || "$image" =~ ^caddy@sha256:[a-f0-9]{64}$ ]] || { fail 'Use the reviewed Caddy release or official-repository digest'; return 1; }
    timeout --foreground 1200 docker pull "$image"
    image="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')"
    [[ "$image" =~ ^caddy@sha256:[a-f0-9]{64}$ ]] || { fail 'Could not resolve official Caddy digest'; return 1; }
    if [[ -n "$previous" ]]; then
        [[ "$image" == "$(sed -n 's/^CADDY_IMAGE=//p' "$ROOT/current/.env")" ]] || { fail 'Image changes require a separate reviewed upgrade'; return 1; }
    fi
    local release path node ip
    release="$(mktemp -d "$ROOT/releases/release.XXXXXX")"
    mkdir "$release/trust"
    for node in pve01 pve02; do
        path="$trust/$node-ca.crt"
        [[ -f "$path" ]] && ! grep -q 'PRIVATE KEY' "$path" || { fail 'Public Proxmox CA files are required; no keys'; return 1; }
        openssl x509 -in "$path" -noout -checkend 86400 >/dev/null || return 1
        install -m 0644 "$path" "$release/trust/$node-ca.crt"
        ip=192.168.1.2; [[ "$node" != pve02 ]] || ip=192.168.1.3
        curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 --cacert "$path" "https://$ip:8006/" >/dev/null
    done
    render_config "$domain" > "$release/Caddyfile"
    mkdir "$release/site"
    sed "s/@DOMAIN@/$domain/g" "$TEMPLATE_DIR/index.html.template" > "$release/site/index.html"
    install -m 0644 "$TEMPLATE_DIR/docker-compose.yml" "$release/compose.yml"
    printf 'CADDY_IMAGE=%s\nPROXY_BIND_IP=%s\nPROXY_STACK_DIR=%s\n' "$image" "$bind" "$ROOT" > "$release/.env"
    (cd "$release" && sha256sum Caddyfile compose.yml .env trust/*.crt site/index.html > MANIFEST)
    docker compose --project-name homelab-proxy --env-file "$release/.env" -f "$release/compose.yml" config --quiet
    # Provisioning validation runs without published ports and before switching current.
    docker run --rm --network none -v "$release:/etc/caddy/current:ro" --tmpfs /data --tmpfs /config \
        "$image" caddy validate --config /etc/caddy/current/Caddyfile --adapter caddyfile
    local pending="releases/${release##*/}"
    ln -s "$pending" "$ROOT/.current-next"
    mv -Tf "$ROOT/.current-next" "$ROOT/current"
    local status=0
    if [[ -n "$previous" ]]; then
        compose exec -T caddy caddy reload --config /etc/caddy/current/Caddyfile --adapter caddyfile || status=$?
    else
        compose up -d --pull never --wait --wait-timeout 120 || status=$?
    fi
    if [[ "$status" == 0 ]]; then
        compose exec -T caddy wget -q -O /dev/null http://127.0.0.1:8080/healthz || status=$?
    fi
    if [[ "$status" == 0 ]]; then verify_endpoints "$domain" "$bind" || status=$?; fi
    if [[ "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            ln -s "$previous" "$ROOT/.current-next"; mv -Tf "$ROOT/.current-next" "$ROOT/current"
            compose exec -T caddy caddy reload --config /etc/caddy/current/Caddyfile --adapter caddyfile || { fail 'Rollback reload failed; retained releases require inspection'; return 1; }
        else compose down; rm "$ROOT/current"; fi
        fail 'Proxy apply failed; previous service configuration restored or new container stopped'
        return 1
    fi
    printf 'Proxy healthy; image %s; current %s; prior %s\n' "$image" "$pending" "${previous:-none}"
    printf 'Retain the private homelab-caddy-data volume. Export only its public root.crt for client trust.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
