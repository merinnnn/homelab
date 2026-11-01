#!/usr/bin/env bash
# Native install behavior under isolated mocks. No downloads, root, LXC or live DNS.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
DEPLOY_SCRIPT="$(cd -- "$SCRIPT_DIR/../deploy" && pwd)/install-pihole-native.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pihole-native-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
checks=0; failures=0
assert() {
    local label="$1"; shift
    checks=$((checks+1))
    if "$@"; then printf 'PASS: %s\n' "$label"; else printf 'FAIL: %s\n' "$label"; failures=$((failures+1)); fi
}
cat > "$WORK/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *core*) [[ "$MOCK_MODE" != core_drift ]] && echo v6.5 || echo v6.999 ;;
    *web*) echo v6.6.1 ;;
    *) exit 1 ;;
esac
MOCK
cat > "$WORK/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/systemctl.calls"
[[ "$MOCK_MODE" != service_fail ]]
MOCK
chmod +x "$WORK/bin/git" "$WORK/bin/systemctl"
cat > "$WORK/bin/install" <<'MOCK'
#!/usr/bin/env bash
# Windows Git Bash cannot enforce Unix directory ownership/mode; record intent.
printf '%s\n' "$*" >> "$FIXTURE/install.calls"
[[ "$1" == -d && "$2" == -m ]] || exit 1
mkdir -p -- "$4"
MOCK
chmod +x "$WORK/bin/install"
cat > "$WORK/installer" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == --unattended ]]
[[ "$DEBIAN_FRONTEND" == noninteractive ]]
grep -q '^port = ""$' "$FIXTURE/config/pihole.toml"
grep -A1 '^\[dhcp\]' "$FIXTURE/config/pihole.toml" | grep -q 'active = false'
printf 'called\n' >> "$FIXTURE/installer.calls"
[[ "$MOCK_MODE" != installer_fail ]] || exit 7
cat > "$FIXTURE/ftl" <<'FTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/ftl.calls"
case "$*" in
    tag) [[ "$MOCK_MODE" != ftl_drift ]] && echo v6.8 || echo v6.999 ;;
    '--config webserver.api.pwhash') [[ ! -f "$FIXTURE/password-set" ]] || echo test-hash ;;
    '--config dhcp.active') echo false ;;
    '--config webserver.port') [[ ! -f "$FIXTURE/web-enabled" ]] || echo '80,443s' ;;
    '--config dns.listeningMode') [[ "$MOCK_MODE" != policy_drift ]] && echo LOCAL || echo ALL ;;
    '--config dns.interface') echo eth0 ;;
    '--config webserver.acl') echo '+127.0.0.1,+192.168.1.0/24' ;;
    '--config webserver.port 80,443s') touch "$FIXTURE/web-enabled" ;;
    *) exit 1 ;;
esac
FTL
cat > "$FIXTURE/pihole" <<'PIHOLE'
#!/usr/bin/env bash
[[ "$*" == setpassword ]] || exit 8
IFS= read -r first
IFS= read -r second
[[ "$first" == "$second" && ${#first} -ge 20 ]] || exit 9
printf '%s' "$first" | sha256sum > "$FIXTURE/password.digest"
[[ "$MOCK_MODE" != password_fail ]] || exit 10
[[ "$MOCK_MODE" == hash_missing ]] || touch "$FIXTURE/password-set"
printf 'Password updated\n'
PIHOLE
chmod +x "$FIXTURE/ftl" "$FIXTURE/pihole"
MOCK
cat > "$WORK/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$DEPLOY_SCRIPT"
CONFIG_DIR="$FIXTURE/config"
LOG_ROOT="$FIXTURE/logs"
FTL_BIN="$FIXTURE/ftl"
PIHOLE_BIN="$FIXTURE/pihole"
CORE_REPO="$FIXTURE/core"
WEB_REPO="$FIXTURE/web"
# Only the guest/root gate is replaced; no production test-bypass flag exists.
require_guest() { return 0; }
main "${MODE:---install}"
DRIVER
export DEPLOY_SCRIPT
export PIHOLE_EXPECTED_CORE=v6.5 PIHOLE_EXPECTED_WEB=v6.6.1 PIHOLE_EXPECTED_FTL=v6.8
export PIHOLE_INSTALLER_COMMIT=f503a65d3a07cb71fd931389f1d3babf718249aa
export PIHOLE_INSTALLER_FILE="$WORK/installer"
export PIHOLE_INSTALLER_SHA256="$(sha256sum "$WORK/installer" | cut -d' ' -f1)"
export PATH="$WORK/bin:$PATH"
export MOCK_MODE=healthy
new_fixture() { export FIXTURE="$WORK/$1"; mkdir "$FIXTURE"; }
invoke() {
    local password="${1-FixturePassword_OnlyForTests42}" status=0
    printf '%s\n' "$password" | bash "$WORK/driver" > "$FIXTURE/output" 2>&1 || status=$?
    return "$status"
}
expect_fail() { local status=0; invoke "${1-FixturePassword_OnlyForTests42}" || status=$?; [[ "$status" -ne 0 ]]; }
no_secret_output() { ! grep -R -F 'FixturePassword_OnlyForTests42' "$FIXTURE"; }
assert 'deploy script parses' bash -n "$DEPLOY_SCRIPT"
assert 'regression script parses' bash -n "${BASH_SOURCE[0]}"
bash "$DEPLOY_SCRIPT" --render-config > "$WORK/config.toml"
assert 'v6 preseed disables Pi-hole DHCP' bash -c 'grep -A1 "^\[dhcp\]" "$1" | grep -q "active = false"' _ "$WORK/config.toml"
assert 'web is disabled before password setup' grep -q '^port = ""$' "$WORK/config.toml"
assert 'DNS uses local-origin mode' grep -q '^listeningMode = "LOCAL"$' "$WORK/config.toml"
assert 'upstreams use the requested pair' grep -Fq '["1.1.1.1", "1.0.0.1"]' "$WORK/config.toml"
assert 'render supports query logging override' bash -c 'PIHOLE_QUERY_LOGGING=false bash "$1" --render-config | grep -q "queryLogging = false"' _ "$DEPLOY_SCRIPT"
assert 'rejects out-of-range upstream' bash -c '! PIHOLE_UPSTREAM1=999.1.1.1 bash "$1" --render-config >/dev/null 2>&1' _ "$DEPLOY_SCRIPT"
assert 'rejects TOML injection in interface' bash -c '! PIHOLE_INTERFACE="eth0\"bad" bash "$1" --render-config >/dev/null 2>&1' _ "$DEPLOY_SCRIPT"
assert 'rejects unbounded LAN prefix' bash -c '! PIHOLE_LAN_CIDR=192.168.1.0/0 bash "$1" --render-config >/dev/null 2>&1' _ "$DEPLOY_SCRIPT"
new_fixture healthy
assert 'fresh install succeeds using preseed and --unattended' invoke
if [[ ! -e "$FIXTURE/installer.calls" ]]; then cat "$FIXTURE/output"; exit 1; fi
assert 'web enables only after password set' test -f "$FIXTURE/web-enabled"
expected_digest="$(printf '%s' FixturePassword_OnlyForTests42 | sha256sum)"
assert 'native CLI receives the exact supplied secret twice through stdin' test "$(cat "$FIXTURE/password.digest")" = "$expected_digest"
assert 'password is absent from console and all fixture log files' no_secret_output
assert 'installer ran exactly once' bash -c '[[ $(wc -l < "$1/installer.calls") -eq 1 ]]' _ "$FIXTURE"
printf '\n# keep custom config on rerun\n' >> "$FIXTURE/config/pihole.toml"
before="$(sha256sum "$FIXTURE/config/pihole.toml")"
assert 'repeat install verifies instead of reinstalling' invoke
after="$(sha256sum "$FIXTURE/config/pihole.toml")"
assert 'repeat leaves existing configuration bytes unchanged' test "$before" = "$after"
assert 'repeat does not invoke installer again' bash -c '[[ $(wc -l < "$1/installer.calls") -eq 1 ]]' _ "$FIXTURE"
export MODE=--verify
assert 'verify-only requires no password input' invoke ''
unset MODE
rm "$FIXTURE/web-enabled"
assert 'repeat detects prior partial install with disabled web' expect_fail
assert 'partial web rerun does not reinstall' bash -c '[[ $(wc -l < "$1/installer.calls") -eq 1 ]]' _ "$FIXTURE"
touch "$FIXTURE/web-enabled"
export MOCK_MODE=policy_drift
assert 'repeat refuses unsafe DNS policy drift without overwriting it' expect_fail
export MOCK_MODE=healthy

for scenario in installer_fail core_drift ftl_drift password_fail hash_missing; do
    new_fixture "$scenario"; export MOCK_MODE="$scenario"
    assert "$scenario returns nonzero" expect_fail
    assert "$scenario never enables web" bash -c '[[ ! -e "$1/web-enabled" ]]' _ "$FIXTURE"
    assert "$scenario keeps password out of files/output" no_secret_output
done
export MOCK_MODE=healthy
new_fixture checksum_mismatch
saved_sha="$PIHOLE_INSTALLER_SHA256"; export PIHOLE_INSTALLER_SHA256="$(printf '0%.0s' {1..64})"
assert 'checksum mismatch returns nonzero' expect_fail
assert 'checksum mismatch does not seed config or execute installer' bash -c '[[ ! -e "$1/config/pihole.toml" && ! -e "$1/installer.calls" ]]' _ "$FIXTURE"
export PIHOLE_INSTALLER_SHA256="$saved_sha"
new_fixture partial
mkdir "$FIXTURE/config"; printf '# existing partial config\n' > "$FIXTURE/config/pihole.toml"
before="$(sha256sum "$FIXTURE/config/pihole.toml")"
assert 'partial installation refuses overwrite' expect_fail
after="$(sha256sum "$FIXTURE/config/pihole.toml")"
assert 'partial configuration preserved byte-for-byte' test "$before" = "$after"
new_fixture weak_password
assert 'weak password rejected before seeding/install' expect_fail short
assert 'weak password leaves no config/install action' bash -c '[[ ! -e "$1/config/pihole.toml" && ! -e "$1/installer.calls" ]]' _ "$FIXTURE"
printf 'Pi-hole native checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
