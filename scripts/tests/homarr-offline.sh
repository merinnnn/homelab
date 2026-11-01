#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/deploy/homarr.sh"
COMPOSE="$REPO/configs/docker/homarr/docker-compose.yml"
WORK="$(mktemp -d /tmp/homelab-homarr-test-XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
checks=0; failures=0
assert() { local name="$1"; shift; checks=$((checks+1)); if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; failures=$((failures+1)); fi; }
assert 'guest helper parses' bash -n "$SCRIPT"
assert 'host helper parses' bash -n "$REPO/scripts/deploy/proxmox-homarr.sh"
assert 'test parses' bash -n "$0"
assert 'no published host ports' bash -c '! grep -q "^[[:space:]]*ports:" "$1"' _ "$COMPOSE"
assert 'no Docker socket' bash -c '! grep -q docker.sock "$1"' _ "$COMPOSE"
assert 'Docker control disabled' grep -Fq "ENABLE_DOCKER: 'false'" "$COMPOSE"
assert 'external requests disabled' grep -Fq "NO_EXTERNAL_CONNECTION: 'true'" "$COMPOSE"
assert 'secure canonical origin' grep -Fq 'BASE_URL: https://home.home.arpa' "$COMPOSE"
assert 'private file secret supported' grep -Fq 'SECRET_ENCRYPTION_KEY_FILE: /run/secrets/encryption-key' "$COMPOSE"
assert 'persistent named data' grep -Fq 'name: homelab-homarr-data' "$COMPOSE"
assert 'existing private proxy network' grep -Fq 'name: homelab-proxy_default' "$COMPOSE"
assert 'native liveness endpoint' grep -Fq 'http://127.0.0.1:7575/api/health/live' "$COMPOSE"
assert 'both local resolvers configured' grep -Fq 'dns: [192.168.1.210, 192.168.1.150]' "$COMPOSE"
assert 'public CA added to Node trust' grep -Fq 'NODE_EXTRA_CA_CERTS: /run/homelab-ca.crt' "$COMPOSE"
assert 'CA mount is read-only' grep -Fq '/run/homelab-ca.crt:ro' "$COMPOSE"
mkdir "$WORK/release"
printf 'original\n' > "$WORK/release/config.yaml"
(cd "$WORK/release" && sha256sum config.yaml > MANIFEST)
assert 'valid manifest verifies' bash -c 'source "$1"; verify_release "$2"' _ "$SCRIPT" "$WORK/release"
printf 'changed\n' > "$WORK/release/config.yaml"
assert 'changed bytes refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
printf 'original\n' > "$WORK/release/config.yaml"
printf 'unknown\n' > "$WORK/release/custom.yaml"
assert 'unknown files refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
rm "$WORK/release/custom.yaml"
ln -s config.yaml "$WORK/release/link"
assert 'unmanaged release link/path refused' bash -c 'source "$1"; ! verify_release "$2" >/dev/null 2>&1' _ "$SCRIPT" "$WORK/release"
mkdir "$WORK/key-fixture"
printf '%064d\n' 0 > "$WORK/key-fixture/encryption-key"
(cd "$WORK/key-fixture" && sha256sum encryption-key > managed-v1)
verify_key_fixture() {
    # Git Bash does not expose Linux root ownership/modes; model only stat.
    # All key bytes, checksums, directory membership and symlinks are real.
    bash -c 'source "$1"; SECRET="$2"; stat() { if [[ "$3" == "$SECRET" ]]; then echo 0:700; else echo "${FIXTURE_MODE:-0:600}"; fi; }; verify_secret' _ "$SCRIPT" "$WORK/key-fixture"
}
assert 'unchanged key/checksum verifies' verify_key_fixture
printf '{}\n' > "$WORK/key-fixture/admin.json"
printf '{}\n' > "$WORK/key-fixture/bootstrap.json"
assert 'explicit bootstrap files preserve key validation' verify_key_fixture
export FIXTURE_MODE=0:644
rejects_key_fixture() { ! verify_key_fixture >/dev/null 2>&1; }
assert 'world-readable private files refused' rejects_key_fixture
unset FIXTURE_MODE
printf 'changed\n' > "$WORK/key-fixture/encryption-key"
assert 'altered key refused' rejects_key_fixture
printf '%064d\n' 0 > "$WORK/key-fixture/encryption-key"
printf 'unknown\n' > "$WORK/key-fixture/other.json"
assert 'unknown private file refused' rejects_key_fixture
rm "$WORK/key-fixture/other.json" "$WORK/key-fixture/admin.json"
ln -s bootstrap.json "$WORK/key-fixture/admin.json"
if [[ -L "$WORK/key-fixture/admin.json" ]]; then
    assert 'private input symlink refused' rejects_key_fixture
else
    echo 'NOT RUN: private input symlink refusal (this shell copies links; rerun on native Linux)'
fi
rm -f "$WORK/key-fixture/admin.json"
mkdir "$WORK/key-fixture/admin.json"
assert 'private input directory refused' rejects_key_fixture
cat > "$WORK/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
id() { echo 0; }
hostname() { echo apps01; }
flock() { return 0; }
timeout() { shift 2; "$@"; }
openssl() { if [[ "$1" == x509 ]]; then [[ "${MOCK_MODE:-}" != bad_ca ]]; else command openssl "$@"; fi; }
docker() {
    printf '%s\n' "$*" >> "$CASE/log"
    case "$1" in
        network) echo homelab-proxy ;;
        ps) [[ "${MOCK_MODE:-}" != existing ]] || echo unknown-container ;;
        volume)
            if [[ "$2" == ls ]]; then [[ "${MOCK_MODE:-}" != existing_volume ]] || echo homelab-homarr-data; else return 42; fi ;;
        pull) return 27 ;;
        *) return 43 ;;
    esac
}
main "$@"
DRIVER
export SCRIPT
new_case() { export CASE="$WORK/$1"; mkdir "$CASE"; export HOMARR_STACK_DIR="$CASE/stack" HOMARR_SECRET_DIR="$CASE/private" HOMARR_CA_FILE="$CASE/public.crt"; printf 'mock certificate\n' > "$HOMARR_CA_FILE"; }
invoke_failure() { local status=0; bash "$WORK/driver" "$@" > "$CASE/output" 2>&1 || status=$?; [[ "$status" != 0 ]]; }
new_case invalid
assert 'invalid arguments refused' invoke_failure --reset
assert 'invalid arguments make no directories or Docker calls' bash -c '[[ ! -e "$1/stack" && ! -e "$1/log" ]]' _ "$CASE"
new_case unknown
mkdir "$CASE/stack"; echo preserved > "$CASE/stack/custom"
assert 'unknown stack refused' invoke_failure
assert 'unknown stack preserved before Docker work' bash -c '[[ -f "$1/stack/custom" && ! -e "$1/log" && ! -e "$1/stack/.homelab-homarr-managed" ]]' _ "$CASE"
new_case secret
mkdir "$CASE/private"; echo preserved > "$CASE/private/custom"
assert 'unknown private directory refused' invoke_failure
assert 'unknown private data preserved' bash -c '[[ -f "$1/private/custom" && ! -e "$1/log" && ! -e "$1/stack" ]]' _ "$CASE"
new_case existing
export MOCK_MODE=existing
assert 'unowned existing project refused' invoke_failure
assert 'unowned container untouched' bash -c '! grep -q "^pull\| up -d\| down" "$1/log"' _ "$CASE"
unset MOCK_MODE
new_case volume
export MOCK_MODE=existing_volume
assert 'unowned existing data volume refused' invoke_failure
assert 'unowned volume not replaced' bash -c '! grep -q "^pull\|^volume create\| up -d\| down" "$1/log"' _ "$CASE"
unset MOCK_MODE
new_case pull_failure
assert 'failed image pull stops deployment' invoke_failure
assert 'failed pull makes no secret, data volume or active release' bash -c '[[ ! -e "$1/private" && ! -e "$1/stack/current" ]] && ! grep -q "^volume create\| up -d\| down" "$1/log"' _ "$CASE"
new_case image
export HOMARR_IMAGE=untrusted/homarr:latest
assert 'unreviewed image refused' invoke_failure
assert 'unreviewed image never pulled' bash -c '! grep -q "^pull" "$1/log"' _ "$CASE"
unset HOMARR_IMAGE
new_case bad_ca
export MOCK_MODE=bad_ca
assert 'invalid public certificate refused' invoke_failure
assert 'invalid certificate makes no stack, secret or Docker changes' bash -c '[[ ! -e "$1/private" && ! -e "$1/stack" && ! -e "$1/log" ]]' _ "$CASE"
unset MOCK_MODE
printf 'Homarr offline checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
