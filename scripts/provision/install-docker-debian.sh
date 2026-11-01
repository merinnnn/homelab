#!/usr/bin/env bash
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run inside the Debian guest as root" >&2; exit 1; }
if command -v pveversion >/dev/null 2>&1; then echo "Refusing Docker installation on a Proxmox host" >&2; exit 1; fi
[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 1; }
. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 && "$VERSION_CODENAME" == trixie ]] || {
    echo "This installer requires Debian 13 (trixie)" >&2; exit 1;
}
[[ "${CLOUD_INIT_TIMEOUT:-600}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid CLOUD_INIT_TIMEOUT" >&2; exit 1; }

# A bounded wait avoids racing the guest's first-boot apt/cloud-init jobs.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
if command -v cloud-init >/dev/null 2>&1; then
    status=0
    timeout --foreground "${CLOUD_INIT_TIMEOUT:-600}" cloud-init status --wait --format json >"$state" || status=$?
    if [[ "$status" -eq 2 ]]; then
        # Debian's current cloud image reports a nonfatal scalar-user deprecation.
        # Accept completed/degraded state only when cloud-init has no fatal errors.
        python3 - "$state" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "done" or result.get("errors"):
    raise SystemExit("cloud-init did not finish without fatal errors")
print("cloud-init completed with nonfatal warnings", file=sys.stderr)
PY
    elif [[ "$status" -ne 0 ]]; then
        echo "cloud-init readiness failed (exit $status)" >&2; exit "$status"
    fi
fi

# Do not remove a preexisting alternative runtime or its data automatically.
for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
        echo "Conflicting package installed: $package; review before proceeding" >&2; exit 1
    fi
done

export DEBIAN_FRONTEND=noninteractive
apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl --connect-timeout 15 --max-time 120 --retry 3 -fsSL https://download.docker.com/linux/debian/gpg -o "$state"
install -m 0644 "$state" /etc/apt/keyrings/docker.asc
printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/debian' \
    'Suites: trixie' \
    'Components: stable' \
    "Architectures: $(dpkg --print-architecture)" \
    'Signed-By: /etc/apt/keyrings/docker.asc' |
    tee /etc/apt/sources.list.d/docker.sources >/dev/null
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
systemctl is-active --quiet docker
docker info >/dev/null
docker version --format '{{.Server.Version}}'
docker compose version
