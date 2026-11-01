#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/deploy/homepage.sh"
COMPOSE="$REPO/configs/docker/homepage/docker-compose.yml"
WORK="$(mktemp -d /tmp/homelab-homepage-test-XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
checks=0; failures=0
assert() { local name="$1"; shift; checks=$((checks+1)); if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; failures=$((failures+1)); fi; }
assert 'guest helper parses' bash -n "$SCRIPT"
assert 'host helper parses' bash -n "$REPO/scripts/deploy/proxmox-homepage.sh"
assert 'test script parses' bash -n "$0"
assert 'dashboard has no published host ports' bash -c '! grep -q "^[[:space:]]*ports:" "$1"' _ "$COMPOSE"
assert 'dashboard has no Docker socket' bash -c '! grep -q docker.sock "$1"' _ "$COMPOSE"
assert 'allowed host is explicit' grep -Fq 'HOMEPAGE_ALLOWED_HOSTS: home.home.arpa' "$COMPOSE"
assert 'read-only configuration is mounted' grep -Fq '/current/config:/app/config:ro' "$COMPOSE"
assert 'logs use stdout for read-only startup' grep -Fq 'LOG_TARGETS: stdout' "$COMPOSE"
assert 'container uses the existing Caddy network' grep -Fq 'name: homelab-proxy_default' "$COMPOSE"
assert 'container has its own proxy alias' grep -Fq 'homelab-homepage' "$COMPOSE"
for host in pve01 pve02 pihole01 pihole02 uptime vault; do
    assert "$host service card exists" grep -Fq "https://$host.home.arpa/" "$REPO/configs/docker/homepage/config/services.yaml"
done
assert 'cards contain no credential/API integration widgets' bash -c '! grep -Eiq "^[[:space:]]*(widget|token|key|password|secret|provider|server):" "$1"' _ "$REPO/configs/docker/homepage/config/services.yaml"
for file in settings.yaml services.yaml bookmarks.yaml widgets.yaml docker.yaml kubernetes.yaml proxmox.yaml custom.css custom.js; do
    assert "managed $file exists" test -f "$REPO/configs/docker/homepage/config/$file"
done
mkdir "$WORK/release"
printf 'original\n' > "$WORK/release/config.yaml"
(cd "$WORK/release" && sha256sum config.yaml > MANIFEST)
export SCRIPT
assert 'valid manifest verifies' bash -c 'source "$1"; verify_release "$2"' _ "$SCRIPT" "$WORK/release"
printf 'changed\n' > "$WORK/release/config.yaml"
assert 'changed bytes are refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
printf 'original\n' > "$WORK/release/config.yaml"
printf 'unknown\n' > "$WORK/release/custom.yaml"
assert 'unknown files are refused before replacement' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
cat > "$WORK/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
id() { echo 0; }
hostname() { echo apps01; }
flock() { return 0; }
timeout() { shift 2; "$@"; }
docker() {
    printf '%s\n' "$*" >> "$CASE/log"
    case "$1" in
        network) echo homelab-proxy ;;
        ps) [[ "${MOCK_MODE:-}" != existing ]] || echo unknown-container ;;
        pull) return 0 ;;
        image) printf 'ghcr.io/gethomepage/homepage@sha256:%s\n' "$(printf 'a%.0s' {1..64})" ;;
        run) return 27 ;;
        *) return 1 ;;
    esac
}
main
DRIVER
new_case() { export CASE="$WORK/$1"; mkdir "$CASE"; export HOMEPAGE_STACK_DIR="$CASE/stack"; }
invoke_failure() { local status=0; bash "$WORK/driver" > "$CASE/output" 2>&1 || status=$?; [[ "$status" != 0 ]]; }
new_case unknown
mkdir "$CASE/stack"; echo preserved > "$CASE/stack/custom"
assert 'unknown stack is refused' invoke_failure
assert 'unknown stack is preserved before Docker work' bash -c '[[ -f "$1/stack/custom" && ! -e "$1/log" && ! -e "$1/stack/.homelab-homepage-managed" ]]' _ "$CASE"
new_case existing
export MOCK_MODE=existing
assert 'unowned existing project container is refused' invoke_failure
assert 'unowned container is not pulled/recreated/stopped' bash -c '! grep -q "^pull\| up -d\| down" "$1/log"' _ "$CASE"
unset MOCK_MODE
new_case seed_failure
assert 'failed image skeleton preparation stops apply' invoke_failure
assert 'skeleton seed uses the pinned image without network' grep -q '^run --rm --network none --entrypoint sh ' "$CASE/log"
assert 'failed preparation cannot start a container or activate configuration' bash -c '[[ ! -e "$1/stack/current" ]] && ! grep -q " up -d" "$1/log"' _ "$CASE"
printf 'Homepage offline checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
