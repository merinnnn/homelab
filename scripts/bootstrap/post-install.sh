#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

# Disable subscription-only repositories
for f in /etc/apt/sources.list.d/pve-enterprise.sources \
         /etc/apt/sources.list.d/ceph.sources; do
    [[ -f "$f" ]] && mv "$f" "$f.disabled"
done

# Enable PVE no-subscription repository
cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update
apt full-upgrade -y

# Remove subscription popup
FILE=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = """                    ) {
                        Ext.Msg.show({
                            title: gettext('No valid subscription'),"""

new = """                    ) {
                        orig_cmd();
                        return;
                        Ext.Msg.show({
                            title: gettext('No valid subscription'),"""

if new in s:
    raise SystemExit(0)

if s.count(old) != 1:
    raise SystemExit("Subscription popup structure not recognized")

backup = p.with_suffix(p.suffix + ".bak")
if not backup.exists():
    backup.write_bytes(p.read_bytes())

p.write_text(s.replace(old, new))
PY

systemctl restart pveproxy

# Reboot only if a newer installed kernel is not currently running
latest="$(
    dpkg-query -W -f='${Package}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null |
    sed -n 's/^proxmox-kernel-\(.*\)-pve-signed$/\1-pve/p' |
    sort -V |
    tail -1
)"

[[ -n "$latest" && "$(uname -r)" != "$latest" ]] && reboot