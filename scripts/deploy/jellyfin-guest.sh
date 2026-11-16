#!/usr/bin/env bash
# Installs/configures only the fresh, isolated Jellyfin container.
set -euo pipefail
umask 077
[[ $EUID == 0 && "$(hostname -s)" == jellyfin01 ]]
. /etc/os-release
[[ $ID == debian && $VERSION_CODENAME == trixie && $(dpkg --print-architecture) == amd64 ]]
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
apt-get -qq update
apt-get -y --no-install-recommends install ca-certificates curl gpg python3
work=$(mktemp -d)
trap 'rm -f "$work/key.asc" "$work/key.gpg"; rmdir "$work"' EXIT
curl --fail --silent --show-error --location --max-time 45 https://repo.jellyfin.org/jellyfin_team.gpg.key -o "$work/key.asc"
install -d -m 0700 /root/.gnupg
fpr=$(gpg --batch --no-options --show-keys --with-colons "$work/key.asc" | awk -F: '$1=="pub"{pub=1;next} $1=="fpr" && pub{print $10;pub=0}')
[[ $fpr == 4918AABC486CA052358D778D49023CD01DE21A7B ]]
gpg --batch --dearmor --output "$work/key.gpg" "$work/key.asc"
install -d -m 0755 /etc/apt/keyrings
source_file=/etc/apt/sources.list.d/homelab-jellyfin.sources
key_file=/etc/apt/keyrings/homelab-jellyfin.gpg
[[ ! -e $source_file && ! -e $key_file ]] || { echo 'Existing Jellyfin repository files; inspect owned state before repeating install' >&2; exit 1; }
install -m 0644 "$work/key.gpg" "$key_file"
cat > "$source_file" <<'EOF'
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: trixie
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/homelab-jellyfin.gpg
EOF
chmod 644 "$source_file"
apt-get -qq update
apt-get -y --no-install-recommends install jellyfin-server=12.4+deb13 jellyfin-web=12.4+deb13 jellyfin-ffmpeg8=8.1.3-2-trixie
getent group 3000 >/dev/null && { echo 'Media group ID already in use' >&2; exit 1; }
groupadd -g 3000 jellyfin-media
usermod -aG jellyfin-media jellyfin
groupadd -g 3001 jellyfin-render
usermod -aG jellyfin-render jellyfin
systemctl restart jellyfin
runuser -u jellyfin -- test -r /dev/dri/renderD128
dpkg-query -W jellyfin-server jellyfin-web jellyfin-ffmpeg8