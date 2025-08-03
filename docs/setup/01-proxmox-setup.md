# Proxmox VE Setup and Configuration

This guide covers the initial setup and configuration of Proxmox VE on the HP EliteDesk Mini G2 for homelab use.

## Hardware Specifications

### HP EliteDesk Mini G2 Configuration
- **CPU**: Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz, 6 cores
- **RAM**: 8GB DDR4 (expandable)
- **Storage**: 256GB SSD
- **Network**: Gigabit Ethernet
- **Form Factor**: Ultra-small desktop (175mm x 175mm x 34mm)

## Initial Proxmox Installation

### 1. Download Proxmox VE ISO
```bash
wget https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso
```

### 2. Create Installation Media
- Use tools like Rufus (Windows) or `dd` (Linux) to create bootable USB
- Boot from USB and follow installation wizard

### 3. Installation Configuration
During installation, configure:
- **Hostname**: `proxmox-homelab.local`
- **Network**: Configure for your WiFi extender network
- **Root Password**: Use a strong password
- **Email**: Your email for notifications

## Post-Installation Configuration

### 1. Access Web Interface
```bash
# Find Proxmox IP address
ip addr show

# Access web interface at: https://PROXMOX_IP:8006
```

### 2. Configure Package Repositories
```bash
# SSH into Proxmox host
ssh root@PROXMOX_IP

# Disable enterprise repositories (require paid license)
mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.disabled
mv /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.disabled

# Add community repository (free)
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update package lists
apt update && apt upgrade -y
```

### 3. Configure Permanent DNS
```bash
# Install resolvconf for permanent DNS
apt install resolvconf -y

# Configure DNS servers
nano /etc/resolvconf/resolv.conf.d/head
```

Add:
```
nameserver 8.8.8.8
nameserver 1.1.1.1
```

Apply configuration:
```bash
resolvconf -u
```

## Storage Configuration

### 1. Review Storage Setup
```bash
# Check available storage
pvesm status

# Typical setup includes:
# - local: Proxmox system files and ISOs
# - local-lvm: VM disk images
```

### 2. Optimize Storage for Small System
```bash
# For systems with limited storage, consider:
# - Thin provisioning for VM disks
# - Regular cleanup of old backups
# - Compression for backup storage
```

## Network Interface Configuration

### 1. Default Bridge (vmbr0)
- Connected to physical network interface
- Provides internet access to VMs
- In my case, configured with DHCP from WiFi extender

### 2. Management Network Access
```bash
# Ensure SSH access is enabled
systemctl enable ssh
systemctl start ssh

# Configure firewall if needed
ufw allow ssh
ufw allow 8006/tcp  # Proxmox web interface
```

## Security Hardening

### 1. SSH Configuration
```bash
# Edit SSH configuration
nano /etc/ssh/sshd_config

# Recommended changes:
# PermitRootLogin yes (for initial setup, can disable later)
# PasswordAuthentication yes
# PubkeyAuthentication yes

# Restart SSH
systemctl restart ssh
```

### 2. Firewall Configuration
```bash
# Install and configure UFW
apt install ufw -y

# Allow essential services
ufw allow ssh
ufw allow 8006/tcp  # Proxmox web interface
ufw allow from 10.0.10.0/24  # Allow homelab network

# Enable firewall
ufw enable
```

### 3. Automatic Updates
```bash
# Configure automatic security updates
apt install unattended-upgrades -y
dpkg-reconfigure unattended-upgrades

# Configure update settings
nano /etc/apt/apt.conf.d/50unattended-upgrades
```

## Performance Optimization

### 1. CPU Configuration
- Enable CPU scaling governor for power efficiency
- Configure CPU limits for VMs based on actual needs

### 2. Memory Management
```bash
# Check memory usage
free -h

# Configure swap if needed (for systems with limited RAM)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 3. Disk I/O Optimization
- Use VirtIO SCSI for VM disks
- Enable discard/TRIM for SSDs
- Consider cache settings for different workloads

## Backup Configuration

### 1. Local Backup Setup
```bash
# Create backup schedule in Proxmox web interface:
# Datacenter → Backup → Add
# - Storage: local
# - Schedule: Daily at 2:00 AM
# - Mode: Snapshot (for faster backups)
# - Compression: ZSTD (good compression ratio)
```

### 2. Backup Retention Policy
- Keep daily backups for 7 days
- Keep weekly backups for 4 weeks
- Keep monthly backups for 3 months

## Monitoring Setup

### 1. Enable Prometheus Metrics
```bash
# Configure Proxmox to export metrics
# Web interface: Datacenter → Metric Server → Add
# Type: InfluxDB or Prometheus
```

### 2. Log Management
```bash
# Configure log rotation
nano /etc/logrotate.d/proxmox

# Monitor important logs
tail -f /var/log/pve-firewall.log
tail -f /var/log/pvedaemon.log
```

## Troubleshooting Common Issues

### 1. Web Interface Access Issues
```bash
# Restart Proxmox web services
systemctl restart pveproxy
systemctl restart pvedaemon

# Check service status
systemctl status pveproxy
systemctl status pvedaemon
```

### 2. Network Connectivity Issues
```bash
# Check network configuration
ip addr show
ip route show

# Test internet connectivity
ping -c 4 8.8.8.8

# Check DNS resolution
nslookup google.com
```

### 3. Storage Issues
```bash
# Check storage usage
df -h
pvesm status

# Clean up old backups
find /var/lib/vz/dump -name "*.vma*" -mtime +7 -delete
```

## Next Steps

After completing Proxmox setup:
1. [Configure homelab network](02-network-configuration.md)
2. [Create virtual machines](03-vm-creation.md)
3. [Deploy services](04-service-deployment.md)

## Additional Resources

- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [Proxmox VE Community Forum](https://forum.proxmox.com/)
- [Proxmox VE Wiki](https://pve.proxmox.com/wiki/Main_Page)
