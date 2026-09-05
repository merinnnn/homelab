#!/bin/bash
set -eo pipefail

# Remove enterprise and ceph repositories
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.list
rm -f /etc/apt/sources.list.d/ceph-*.list
sed -i 's/^deb https:\/\/enterprise/# deb https:\/\/enterprise/g' /etc/apt/sources.list

# Add no-subscription repository for Proxmox 9 (Trixie)
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update and upgrade system (noninteractive prevents hanging on config prompts)
apt update
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y

# Remove subscription nag screen
sed -i.bak "s/data.status !== 'Active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# Restart web interface to apply changes
systemctl restart pveproxy