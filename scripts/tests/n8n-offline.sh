#!/usr/bin/env bash
# Behavioral deployment checks with isolated fake Docker; no live resources used.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d /tmp/n8n-offline-XXXXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
export REPO
cat > "$WORK/run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO/scripts/deploy/n8n.sh"
id() { printf '0\n'; }
hostname() { printf 'apps01\n'; }
command() {
    if [[ "$*" == '-v pveversion' ]]; then [[ "${CASE:-}" == host ]]; return; fi
    builtin command "$@"
}
openssl() { return 0; }
install() {
    if [[ "$1" == -d ]]; then shift 3; mkdir -p "$@"; else shift 2; cp "$@"; fi
}
flock() { return 0; }
timeout() { shift 2; "$@"; }
stat() {
    local path="${*: -1}"
    if [[ -d "$path" ]]; then printf '0:700\n'; else printf '0:600\n'; fi
}
create_secret() {
    install -d -m 0700 "$SECRET"
    local name
    for name in encryption-key postgres-password runner-token; do printf '%064d\n' 1 > "$SECRET/$name"; done
    for name in n8n.env postgres.env runners.env; do printf 'MOCK_PUBLIC_FIXTURE=1\n' > "$SECRET/$name"; done
    (cd "$SECRET" && sha256sum encryption-key postgres-password runner-token n8n.env postgres.env runners.env > managed-v1)
    chmod 0600 "$SECRET/"*
}
docker() {
    printf '%s\n' "$*" >> "$TEST_LOG"
    case "$1 $2" in
        'network inspect') printf 'homelab-proxy\n' ;;
        'ps -a') [[ "${CASE:-}" != foreign-container ]] || printf 'foreign\n' ;;
        'inspect foreign') printf 'unknown\n' ;;
        'volume ls') cat "$TEST_STATE" ;;
        'volume inspect') printf '%s\n' "${VOLUME_LABEL:-n8n-v1}" ;;
        'volume create') printf '%s\n' "${*: -1}" >> "$TEST_STATE" ;;
        'pull '*) return 0 ;;
        'image inspect')
            case "$3" in
                docker.n8n.io/n8nio/n8n:*) printf 'docker.n8n.io/n8nio/n8n@sha256:%064d\n' 1 ;;
                n8nio/runners:*) printf 'n8nio/runners@sha256:%064d\n' 2 ;;
                postgres:*) printf 'postgres@sha256:%064d\n' 3 ;;
                *) printf '%s\n' "$3" ;;
            esac ;;
        'compose '*)
            case " $* " in
                *' config '*) printf 'CONFIG\n' >> "$TEST_PHASE"; [[ "${CASE:-}" != invalid-config ]] ;;
                *' up '*)
                    printf 'UP\n' >> "$TEST_PHASE"
                    if [[ "${CASE:-}" == unhealthy && ! -e "$TEST_PHASE.failed" ]]; then touch "$TEST_PHASE.failed"; return 1; fi ;;
                *' stop '*) printf 'STOP\n' >> "$TEST_PHASE" ;;
            esac ;;
        *) return 8 ;;
    esac
}
main
SH
run() { bash "$WORK/run" > "$WORK/output" 2>&1; }
new_case() {
    export N8N_STACK_DIR="$WORK/$1-stack" N8N_SECRET_DIR="$WORK/$1-private" N8N_CA_FILE="$WORK/root.crt" N8N_LOCK_FILE="$WORK/$1.lock"
    export TEST_LOG="$WORK/$1.log" TEST_STATE="$WORK/$1.volumes" TEST_PHASE="$WORK/$1.phases" CASE=''
    : > "$TEST_STATE"; : > "$TEST_LOG"; : > "$TEST_PHASE"; : > "$N8N_CA_FILE"
}
passed=0
check() { "$@" || { cat "$WORK/output" >&2; echo "FAIL: $*" >&2; exit 1; }; passed=$((passed+1)); }
refused() { if run; then echo 'Expected refusal' >&2; return 1; fi; }
new_case baseline
check run
check test -L "$N8N_STACK_DIR/current"
check grep -Fxq UP "$TEST_PHASE"
check test "$(wc -l < "$TEST_STATE")" == 2
key_hash="$(sha256sum "$N8N_SECRET_DIR/encryption-key")"
check run
check test "$(sha256sum "$N8N_SECRET_DIR/encryption-key")" == "$key_hash"
check test "$(wc -l < "$TEST_STATE")" == 2
printf 'changed\n' >> "$N8N_SECRET_DIR/encryption-key"
: > "$TEST_LOG"
check refused
check test ! -s "$TEST_LOG"
new_case missing-volume
check run
sed -i '/homelab-n8n-data$/d' "$TEST_STATE"
: > "$TEST_PHASE"
check refused
check test ! -s "$TEST_PHASE"
new_case changed-release
check run
printf '# drift\n' >> "$N8N_STACK_DIR/current/compose.yml"
: > "$TEST_PHASE"
check refused
check test ! -s "$TEST_PHASE"
new_case foreign-volume
printf 'homelab-n8n-data\n' > "$TEST_STATE"
check refused
check test ! -s "$TEST_PHASE"
new_case foreign-container
export CASE=foreign-container
check refused
check test ! -s "$TEST_PHASE"
new_case invalid
export CASE=invalid-config
check refused
check grep -Fxq CONFIG "$TEST_PHASE"
check test ! -s "$TEST_STATE"
check test ! -L "$N8N_STACK_DIR/current"
new_case failed-first
export CASE=unhealthy
check refused
check grep -Fxq UP "$TEST_PHASE"
check grep -Fxq STOP "$TEST_PHASE"
check test -L "$N8N_STACK_DIR/current"
check test "$(wc -l < "$TEST_STATE")" == 2
new_case rollback
check run
old="$(readlink "$N8N_STACK_DIR/current")"
export CASE=unhealthy
: > "$TEST_PHASE"
check refused
check test "$(readlink "$N8N_STACK_DIR/current")" == "$old"
check test "$(grep -Fxc UP "$TEST_PHASE")" == 2
new_case proxmox-host
export CASE=host
check refused
check test ! -s "$TEST_LOG"
printf 'PASS: %s isolated n8n deployment assertions (Docker is mocked)\n' "$passed"
