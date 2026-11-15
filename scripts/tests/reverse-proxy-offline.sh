#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT_REPO="$(cd -- "$DIR/../.." && pwd)"
SCRIPT="$ROOT_REPO/scripts/deploy/reverse-proxy.sh"
WORK="$(mktemp -d /tmp/homelab-proxy-test-XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
checks=0; failures=0
assert() { local name="$1"; shift; checks=$((checks+1)); if "$@"; then printf 'PASS: %s\n' "$name"; else printf 'FAIL: %s\n' "$name"; failures=$((failures+1)); fi; }
assert 'guest helper parses' bash -n "$SCRIPT"
assert 'host helper parses' bash -n "$ROOT_REPO/scripts/deploy/proxmox-reverse-proxy.sh"
assert 'test suite parses' bash -n "$0"
bash "$SCRIPT" render home.arpa > "$WORK/Caddyfile"
for host in pve01 pve02 pihole01 pihole02 uptime proxy home vault grafana n8n; do
    assert "$host canonical local name rendered" grep -Fq "$host.home.arpa {" "$WORK/Caddyfile"
done
assert 'template tokens all replaced' bash -c '! grep -q @DOMAIN@ "$1"' _ "$WORK/Caddyfile"
assert 'all ten sites use the internal issuer' test "$(grep -c '^    tls internal$' "$WORK/Caddyfile")" = 10
assert 'upstream trust is scoped to both public PVE CA files' test "$(grep -c 'tls_trust_pool file /etc/caddy/current/trust/pve0[12]-ca.crt' "$WORK/Caddyfile")" = 2
assert 'upstream TLS verification remains enabled' bash -c '! grep -q tls_insecure_skip_verify "$1"' _ "$WORK/Caddyfile"
for domain in '' '.home.arpa' 'home.arpa.' 'home..arpa' '-home.arpa' 'home.arpa;true' 'home/../../etc' 'HOME.arpa'; do
    assert "reject unsafe domain [$domain]" bash -c '! bash "$1" render "$2" >/dev/null 2>&1' _ "$SCRIPT" "$domain"
done
cat > "$WORK/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
id() { echo 0; }
hostname() { echo apps01; }
command() {
    [[ "$*" != '-v pveversion' ]] || return 1
    builtin command "$@"
}
flock() { return 0; }
openssl() { return 0; }
curl() { printf 'upstream-check\n' >> "$CASE/log"; return 0; }
timeout() { shift 2; "$@"; }
docker() {
    printf '%s\n' "$*" >> "$CASE/log"
    case "$1" in
        ps) [[ "${MOCK_MODE:-}" != existing_project ]] || echo fixture-existing-container; return 0 ;;
        volume) return 1 ;;
        pull) return 0 ;;
        image) printf 'caddy@sha256:%s\n' "$(printf 'a%.0s' {1..64})" ;;
        compose) return 0 ;;
        run) return 27 ;;
        *) return 1 ;;
    esac
}
main apply home.arpa "$CASE/trust"
DRIVER
export SCRIPT
new_case() { export CASE="$WORK/$1"; mkdir -p "$CASE/trust"; printf 'public cert fixture\n' > "$CASE/trust/pve01-ca.crt"; cp "$CASE/trust/pve01-ca.crt" "$CASE/trust/pve02-ca.crt"; export PROXY_STACK_DIR="$CASE/stack"; }
invoke_failure() { local status=0; bash "$WORK/driver" > "$CASE/output" 2>&1 || status=$?; [[ "$status" != 0 ]]; }
new_case unknown
mkdir "$CASE/stack"; printf 'owned by someone else\n' > "$CASE/stack/preserve"
assert 'unknown existing stack refused' invoke_failure
assert 'unknown stack preserved without Docker operations' bash -c '[[ -f "$1/stack/preserve" && ! -e "$1/log" && ! -e "$1/stack/.homelab-proxy-managed" ]]' _ "$CASE"
new_case private_key
printf '%s%s%s\n' '-----BEGIN ' 'PRIVATE KEY' '-----' > "$CASE/trust/pve01-ca.crt"
assert 'private material rejected as CA input' invoke_failure
assert 'private material never copied into a release' bash -c '[[ -d "$1/stack/releases" ]] && ! grep -R -q "PRIVATE KEY" "$1/stack/releases"' _ "$CASE"
new_case existing_project
export MOCK_MODE=existing_project
assert 'unowned Compose project containers refused' invoke_failure
assert 'unowned project is not pulled, recreated or stopped' bash -c '[[ -f "$1/log" ]] && ! grep -q "^pull\| up -d\| down" "$1/log" && [[ ! -e "$1/stack/current" ]]' _ "$CASE"
unset MOCK_MODE
new_case validation
assert 'invalid Caddy config stops deployment' invoke_failure
assert 'actual Caddy provisioning validation was requested without public ports' grep -q '^run --rm --network none .*caddy validate --config /etc/caddy/current/Caddyfile' "$CASE/log"
assert 'failed validation cannot activate configuration or start a container' bash -c '[[ ! -e "$1/stack/current" ]] && ! grep -q " up -d\|caddy reload" "$1/log"' _ "$CASE"
assert 'both real TLS upstream checks occur before validation' test "$(grep -c '^upstream-check$' "$CASE/log")" = 2
printf 'Reverse proxy offline checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
