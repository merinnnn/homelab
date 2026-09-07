#!/bin/bash
# Proxmox 9 Post-Installation: Repos & Updates
set -eo pipefail

echo "Proxmox 9 Post-Install Setup"

# Remove enterprise and ceph repositories
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.list

# Add no-subscription repository (Trixie/Proxmox 9)
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list

# Update system
apt update
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y

# Remove subscription nag screen
sed -i.bak "s/res\.data\.status\.toLowerCase() !== 'active'/false/g" \
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

systemctl restart pveproxy
echo "Post-install complete. Ready for network setup."