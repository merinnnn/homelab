#!/bin/bash
set -eo pipefail

# Remove enterprise and ceph repositories safely
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.list
rm -f /etc/apt/sources.list.d/ceph-*.list

# Safely comment out enterprise repo in main sources.list ONLY if it exists
if [ -f /etc/apt/sources.list ]; then
    sed -i 's/^deb https:\/\/enterprise/# deb https:\/\/enterprise/g' /etc/apt/sources.list
fi

# Add no-subscription repository for Proxmox 9 (Trixie)
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Force IPv4 to prevent "Network is unreachable" errors
APT_OPTS="-o Acquire::ForceIPv4=true"

# Update and upgrade system (noninteractive prevents hanging on config prompts)
apt update $APT_OPTS
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y $APT_OPTS

# Remove subscription nag screen
sed -i.bak "s/res\.data\.status\.toLowerCase() !== 'active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# Restart web interface to apply changes
systemctl restart pveproxy

echo "Post-install complete."