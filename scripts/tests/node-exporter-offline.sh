#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/provision/install-node-exporter.sh"
WORK="$(mktemp -d /tmp/homelab-exporter-test-XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
checks=0; failures=0
assert() { local name="$1"; shift; checks=$((checks+1)); if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; failures=$((failures+1)); fi; }
assert 'installer parses' bash -n "$SCRIPT"
assert 'regression parses' bash -n "$0"
bash "$SCRIPT" --render pve01 > "$WORK/pve01.conf"
bash "$SCRIPT" --render pve02 > "$WORK/pve02.conf"
assert 'pve01 binds only its LAN IP' grep -Fq -- '--web.listen-address=192.168.1.2:9100' "$WORK/pve01.conf"
assert 'pve02 binds only its LAN IP' grep -Fq -- '--web.listen-address=192.168.1.3:9100' "$WORK/pve02.conf"
assert 'systemd collector explicitly enabled' grep -Fq -- '--collector.systemd ' "$WORK/pve01.conf"
assert 'unit include is limited to known PVE/exporter services' grep -Fq -- '--collector.systemd.unit-include=(pveproxy|pvedaemon|pvestatd|pvescheduler|prometheus-node-exporter)[.]service' "$WORK/pve01.conf"
assert 'vendor ExecStart is explicitly cleared' grep -qx 'ExecStart=' "$WORK/pve01.conf"
for invalid in '' apps01 dns01 pve03 'pve01;true' '--help'; do
    assert "unknown node [$invalid] refused" bash -c '! bash "$1" --render "$2" >/dev/null 2>&1' _ "$SCRIPT" "$invalid"
done
assert 'non-root host is refused' bash -c 'source "$1"; id() { echo 1000; }; ! require_host >/dev/null 2>&1' _ "$SCRIPT"
assert 'container is refused even with Proxmox command' bash -c 'source "$1"; id() { echo 0; }; pveversion() { return 0; }; systemd-detect-virt() { return 0; }; ! require_host >/dev/null 2>&1' _ "$SCRIPT"
cat > "$WORK/metrics.good" <<'METRICS'
node_cpu_seconds_total{cpu="0",mode="idle"} 10
node_memory_MemAvailable_bytes 40
node_memory_MemTotal_bytes 100
node_filesystem_avail_bytes{mountpoint="/"} 20
node_systemd_unit_state{name="pveproxy.service",state="active",type="simple"} 1
node_scrape_collector_success{collector="systemd"} 1
METRICS
cat > "$WORK/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
set_paths() { STATE="$CASE/state"; DROP_DIR="$CASE/dropins"; DROP_IN="$DROP_DIR/50-homelab.conf"; DEFAULTS="$CASE/defaults"; LOCK="$CASE/lock"; }
require_host() { select_node pve01; }
flock() { return 0; }
installed() { [[ "$SCENARIO" == package || "$SCENARIO" == repeat ]]; }
systemctl() {
    printf '%s\n' "$*" >> "$CASE/operations"
    [[ "$SCENARIO" != service_down ]] || return 1
    if [[ "$*" == *DropInPaths* ]]; then printf '%s\n' "$DROP_IN"; fi
}
apt-get() { echo unexpected-apt >> "$CASE/operations"; return 99; }
curl() { [[ "$SCENARIO" != curl_failure ]] || return 7; cat "$CASE/metrics"; }
if [[ "$ACTION" == metrics ]]; then
    set_paths; select_node pve01; mkdir -p "$STATE"; verify_metrics
else main; fi
DRIVER
export SCRIPT
new_case() { export CASE="$WORK/$1"; mkdir "$CASE"; cp "$WORK/metrics.good" "$CASE/metrics"; export ACTION=metrics SCENARIO=healthy; }
invoke() { bash "$WORK/driver" > "$CASE/output" 2>&1; }
fails() { local status=0; invoke || status=$?; [[ "$status" != 0 ]]; }
new_case good
assert 'CPU/memory/filesystem/management metrics verify' invoke
assert 'metrics samples are removed after successful verification' bash -c '[[ -z "$(find "$1/state" -name "metrics.*" -print -quit)" ]]' _ "$CASE"
new_case missing_metric
sed -i '/node_memory_MemAvailable_bytes/d' "$CASE/metrics"
assert 'missing memory metric fails verification' fails
new_case collector_failure
sed -i 's/collector="systemd"} 1/collector="systemd"} 0/' "$CASE/metrics"
assert 'failed systemd collector is refused despite other metrics' fails
new_case service_down
export SCENARIO=service_down
assert 'inactive service fails verification' fails
new_case curl_failure
export SCENARIO=curl_failure
assert 'failed HTTP probe fails verification' fails
assert 'failed HTTP sample is cleaned up' bash -c '[[ -z "$(find "$1/state" -name "metrics.*" -print -quit)" ]]' _ "$CASE"
new_case package
export ACTION=install SCENARIO=package
assert 'unowned installed package is refused' fails
assert 'refused package runs no apt or service mutation' bash -c '[[ ! -e "$1/operations" && ! -e "$1/state" ]]' _ "$CASE"
new_case defaults
export ACTION=install
echo preserve > "$CASE/defaults"
assert 'unowned defaults are refused' fails
assert 'unowned defaults remain unchanged' test "$(cat "$CASE/defaults")" = preserve
new_case partial
export ACTION=install
mkdir "$CASE/state"; echo preserve > "$CASE/state/partial"
assert 'partial state is refused before rerunning installation' fails
assert 'partial state remains unchanged' test "$(cat "$CASE/state/partial")" = preserve
new_case repeat
export ACTION=install SCENARIO=repeat
mkdir "$CASE/state" "$CASE/dropins"
echo pve01 > "$CASE/state/node"; touch "$CASE/state/complete"
bash "$SCRIPT" --render pve01 > "$CASE/dropins/50-homelab.conf"
echo default > "$CASE/defaults"
sha256sum "$CASE/defaults" "$CASE/dropins/50-homelab.conf" > "$CASE/state/package-files.sha256"
before="$(sha256sum "$CASE/dropins/50-homelab.conf")"
assert 'completed repeat verifies healthy existing service' invoke
assert 'completed repeat preserves override bytes' test "$(sha256sum "$CASE/dropins/50-homelab.conf")" = "$before"
assert 'completed repeat does not apt/restart/enable service' bash -c '! grep -Eq "unexpected-apt|^restart |^enable |^daemon-reload" "$1/operations"' _ "$CASE"
echo changed >> "$CASE/defaults"
assert 'completed repeat refuses configuration drift' fails
printf 'Node exporter offline checks: %s; failures: %s\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
