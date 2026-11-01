#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/deploy/monitoring.sh"
COMPOSE="$REPO/configs/docker/monitoring/docker-compose.yml"
WORK="$(mktemp -d /tmp/homelab-metrics-test-XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
checks=0; failures=0
assert() { local name="$1"; shift; checks=$((checks+1)); if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; failures=$((failures+1)); fi; }
assert 'guest helper parses' bash -n "$SCRIPT"
assert 'host helper parses' bash -n "$REPO/scripts/deploy/proxmox-monitoring.sh"
assert 'regression suite parses' bash -n "$0"
assert 'no service publishes a host port' bash -c '! grep -q "^[[:space:]]*ports:" "$1"' _ "$COMPOSE"
assert 'no Docker socket is mounted' bash -c '! grep -q docker.sock "$1"' _ "$COMPOSE"
assert 'anonymous Grafana access is disabled' grep -Fq 'GF_AUTH_ANONYMOUS_ENABLED: "false"' "$COMPOSE"
assert 'Grafana public signup is disabled' grep -Fq 'GF_USERS_ALLOW_SIGN_UP: "false"' "$COMPOSE"
assert 'Grafana reads its initial password from a file' grep -Fq 'GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana-admin-password' "$COMPOSE"
assert 'notification receiver has no external delivery configured' bash -c '! grep -Eiq "(_configs:|webhook|smtp|token|api_key|password)" "$1"' _ "$REPO/configs/docker/monitoring/alertmanager.default.yml"
for alias in homelab-prometheus homelab-grafana homelab-alertmanager; do
    assert "$alias is on the private proxy network" grep -Fq "$alias" "$COMPOSE"
done
for node in pve01 pve02; do
    assert "$node has a static exporter scrape target" grep -Fq "node: $node" "$REPO/configs/docker/monitoring/prometheus/prometheus.yml"
done
mkdir "$WORK/release"
printf 'keep\n' > "$WORK/release/data.yml"
(cd "$WORK/release" && sha256sum data.yml > MANIFEST)
assert 'valid installed configuration verifies' bash -c 'source "$1"; verify_release "$2"' _ "$SCRIPT" "$WORK/release"
printf 'changed\n' > "$WORK/release/data.yml"
assert 'installed byte changes are refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
printf 'keep\n' > "$WORK/release/data.yml"
printf 'unknown\n' > "$WORK/release/custom.yml"
assert 'unknown installed files are refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
assert 'unreviewed image tag is refused before Docker pull' bash -c 'source "$1"; ROOT="$2"; PROMETHEUS_IMAGE=prom/prometheus:latest; docker() { echo unexpected >&2; return 99; }; ! resolve_image PROMETHEUS_IMAGE prom/prometheus v3.15.1 > "$2/result" 2>&1; ! grep -q unexpected "$2/result"' _ "$SCRIPT" "$WORK"
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
        volume) return 1 ;;
        pull) return 27 ;;
        *) return 1 ;;
    esac
}
main
DRIVER
export SCRIPT
new_case() { export CASE="$WORK/$1"; mkdir "$CASE"; export MONITORING_STACK_DIR="$CASE/stack" MONITORING_PRIVATE_DIR="$CASE/private"; }
invoke_failure() { local status=0; bash "$WORK/driver" > "$CASE/output" 2>&1 || status=$?; [[ "$status" != 0 ]]; }
new_case unknown
mkdir "$CASE/stack"; echo preserved > "$CASE/stack/custom"
assert 'unknown stack is refused' invoke_failure
assert 'unknown data is preserved before Docker operations' bash -c '[[ -f "$1/stack/custom" && ! -e "$1/log" && ! -e "$1/stack/.homelab-monitoring-managed" ]]' _ "$CASE"
new_case existing
export MOCK_MODE=existing
assert 'unowned project containers are refused' invoke_failure
assert 'unowned project is not pulled/recreated/stopped' bash -c '! grep -q "^pull\| up -d\| down" "$1/log"' _ "$CASE"
unset MOCK_MODE
new_case pull_failure
assert 'failed image pull propagates failure' invoke_failure
assert 'failed pull never generates secrets, starts services or activates config' bash -c '[[ ! -e "$1/private" && ! -e "$1/stack/current" ]] && ! grep -q " up -d" "$1/log"' _ "$CASE"
printf 'Monitoring offline checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
