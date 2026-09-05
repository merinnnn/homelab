# Destroy all VMs and Containers
qm list | awk 'NR>1 {print $1}' | xargs -I {} qm destroy {}
pct list | awk 'NR>1 {print $1}' | xargs -I {} pct destroy {}

# Wipe and recreate the LVM thin pool for a completely fresh storage layout
lvremove -f pve/data
lvcreate -l 100%FREE -T pve/data

# Reset Proxmox WebUI configuration
# systemctl restart pveproxy pvedaemon pvestatd