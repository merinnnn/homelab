# Virtual Machine Creation and Configuration

This guide covers creating and configuring virtual machines in the Proxmox homelab environment.

## Overview

My homelab uses two primary VMs:
- **Pi-hole VM (ID: 110)** - DNS filtering and ad blocking
- **Docker Host VM (ID: 120)** - Container platform for services

## Prerequisites

- Proxmox VE configured and running
- Homelab network (vmbr1) configured
- Ubuntu Server 22.04 LTS ISO downloaded
- Basic understanding of virtualization concepts

## VM Planning and Resource Allocation

### Hardware Resource Overview

| Resource | Total Available | Pi-hole VM | Docker Host VM | Reserved for Host |
|----------|----------------|------------|----------------|-------------------|
| **CPU Cores** | 4 cores | 1 core | 2 cores | 1 core |
| **Memory** |8GB | 1GB | 3GB | 4GB available |
| **Storage** | 256GB SSD | 10GB | 20GB | 226GB available |

### VM Specifications

#### Pi-hole VM (110)
- **Purpose**: DNS filtering, ad blocking, DHCP (future)
- **CPU**: 1 core (sufficient for DNS workload)
- **Memory**: 1GB (Pi-hole is lightweight)
- **Storage**: 10GB (logs, blocklists, configuration)
- **Network**: vmbr1 (10.0.10.10/24)

#### Docker Host VM (120)  
- **Purpose**: Container platform for services
- **CPU**: 2 cores (handle multiple containers)
- **Memory**: 3GB (Docker overhead + containers)
- **Storage**: 20GB (images, volumes, logs)
- **Network**: vmbr1 (10.0.10.20/24)

## Ubuntu Server ISO Preparation

### Download Current Ubuntu Server ISO

```bash
# SSH into Proxmox host
ssh root@PROXMOX_IP

# Navigate to ISO storage
cd /var/lib/vz/template/iso/

# Download Ubuntu 22.04.5 LTS (current version)
wget https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso

# Verify download
ls -la ubuntu-22.04*
```

### Alternative: Web Interface Download

1. **Proxmox Web Interface**: `https://PROXMOX_IP:8006`
2. **Navigate**: Datacenter → Storage → local → ISO Images
3. **Click**: "Download from URL"
4. **URL**: `https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso`
5. **Wait** for download completion

## Creating the Pi-hole VM

### 1. Create VM via Web Interface

1. **Click**: "Create VM" button in Proxmox interface
2. **Configure General Tab**:
   - **VM ID**: `110`
   - **Name**: `pihole`
   - **Advanced**: ✓ Check "Start at boot"
   - **Description**: `Pi-hole DNS filtering and ad blocking service`

3. **Configure OS Tab**:
   - **Use CD/DVD disc image file (ISO)**: Selected
   - **Storage**: local
   - **ISO Image**: ubuntu-22.04.5-live-server-amd64.iso

4. **Configure System Tab**:
   - **Graphic card**: Default
   - **Machine**: Default (q35)
   - **SCSI Controller**: VirtIO SCSI
   - **BIOS**: OVMF (UEFI)
   - **EFI Storage**: local-lvm
   - **Pre-Enroll keys**: ✓ (for Secure Boot)

5. **Configure Disks Tab**:
   - **Bus/Device**: SCSI
   - **Storage**: local-lvm
   - **Disk size (GiB)**: `10`
   - **Format**: Raw
   - **Cache**: Write back (for better performance)
   - **Discard**: ✓ (for SSD TRIM support)

6. **Configure CPU Tab**:
   - **Sockets**: 1
   - **Cores**: 1
   - **Type**: Host (for best performance)
   - **Enable NUMA**: ✓

7. **Configure Memory Tab**:
   - **Memory (MiB)**: `1024` (1GB)
   - **Minimum memory (MiB)**: `512`
   - **Ballooning Device**: ✓

8. **Configure Network Tab**:
   - **Bridge**: vmbr1
   - **VLAN Tag**: (no VLAN)
   - **Firewall**: ✓
   - **Model**: VirtIO (paravirtualized)
   - **MAC address**: Auto-generated

9. **Confirm and Create**: Review settings and click "Finish"

### 2. Install Ubuntu on Pi-hole VM

1. **Start VM**: Select VM 110 and click "Start"
2. **Open Console**: Click "Console" to access VM

3. **Ubuntu Installation Process**:
   
   **Language Selection**: 
   - Select "English"

   **Keyboard Configuration**:
   - Select your keyboard layout

   **Network Configuration** (CRITICAL):
   - Select network interface (usually `ens18`)
   - Choose "Edit IPv4"
   - **Method**: Manual
   - **Subnet**: `10.0.10.0/24`
   - **Address**: `10.0.10.10`
   - **Gateway**: `10.0.10.1`
   - **Name servers**: `8.8.8.8,1.1.1.1`
   - **Search domains**: (leave empty)

   **Proxy Configuration**:
   - Leave empty

   **Ubuntu Archive Mirror**:
   - Use default or configure local mirror

   **Guided Storage Configuration**:
   - Use entire disk
   - Set up this disk as an LVM group: ✓
   - Encrypt the LVM group: (optional, for security)

   **Profile Setup**:
   - **Your name**: `Homelab Administrator`
   - **Your server's name**: `pihole`
   - **Pick a username**: `homelab`
   - **Choose a password**: (strong password)
   - **Confirm your password**: (repeat password)

   **SSH Setup**:
   - ✓ Install OpenSSH server
   - Import SSH identity: (optional)

   **Featured Server Snaps**:
   - Skip all (we'll install what we need manually)

4. **Installation Completion**:
   - Wait for installation to complete
   - **Reboot Now** when prompted
   - Remove installation media (done automatically)

## Creating the Docker Host VM

### 1. Create VM via Web Interface

Follow similar steps as Pi-hole VM with these differences:

- **VM ID**: `120`
- **Name**: `docker-host`
- **Description**: `Docker container platform for homelab services`
- **Disk size**: `20` GB
- **CPU cores**: `2`
- **Memory**: `3072` MB (3GB)
- **Network**: vmbr1 (same as Pi-hole)

### 2. Network Configuration for Docker Host

During Ubuntu installation:
- **Address**: `10.0.10.20`
- **Gateway**: `10.0.10.1`  
- **Name servers**: `8.8.8.8,1.1.1.1`
- **Server name**: `docker-host`

## Post-Installation VM Configuration

### 1. VM Settings Optimization

For both VMs, optimize settings in Proxmox:

```bash
# Access VM configuration via web interface:
# VM → Hardware → Options

# Recommended optimizations:
# - NUMA: Enabled
# - Hotplug: CPU, Memory, Network, Disk
# - Boot Order: Disk, Network
# - Start/Shutdown order: Start early, shutdown late
```

### 2. Install VM Guest Agent

On each VM after initial boot:

```bash
# SSH into each VM
ssh homelab@10.0.10.10  # Pi-hole
ssh homelab@10.0.10.20  # Docker host

# Install QEMU guest agent
sudo apt update
sudo apt install qemu-guest-agent -y

# Enable and start the service
sudo systemctl enable qemu-guest-agent
sudo systemctl start qemu-guest-agent

# Reboot to ensure guest agent is working
sudo reboot
```

### 3. Enable Guest Agent in Proxmox

For each VM in Proxmox web interface:
1. **VM → Options → QEMU Guest Agent**
2. **Edit** and check "Use QEMU Guest Agent"
3. **OK** to save

## Automated VM Post-Installation

Use the provided script to automate post-installation setup:

```bash
# On Pi-hole VM
wget https://raw.githubusercontent.com//merinnnn/homelab/main/scripts/vm-setup/ubuntu-post-install.sh
chmod +x ubuntu-post-install.sh
./ubuntu-post-install.sh --type pihole --ip 10.0.10.10

# On Docker Host VM  
wget https://raw.githubusercontent.com//merinnnn/homelab/main/scripts/vm-setup/ubuntu-post-install.sh
chmod +x ubuntu-post-install.sh
./ubuntu-post-install.sh --type docker --ip 10.0.10.20
```

## VM Management and Operations

### Starting and Stopping VMs

```bash
# Via Proxmox web interface:
# Select VM → Start/Stop/Reboot

# Via command line on Proxmox host:
qm start 110    # Start Pi-hole VM
qm start 120    # Start Docker host VM
qm stop 110     # Stop Pi-hole VM
qm shutdown 120 # Graceful shutdown Docker host VM
```

### VM Console Access

```bash
# Web console (preferred):
# VM → Console

# SSH access (after network configuration):
ssh homelab@10.0.10.10  # Pi-hole
ssh homelab@10.0.10.20  # Docker host

# Emergency console access via Proxmox host:
qm monitor 110
```

### VM Resource Monitoring

```bash
# Check VM status
qm list

# Monitor VM resources
qm monitor 110
info status
info cpus
info memory

# View VM configuration
qm config 110
```

## VM Backup Configuration

### Automated Backup Setup

1. **Proxmox Web Interface**: Datacenter → Backup
2. **Add Backup Job**:
   - **Node**: Select your Proxmox node
   - **Storage**: local (or external storage)
   - **Schedule**: Daily at 2:00 AM
   - **Selection Mode**: All
   - **Max Backups**: 7 (keep 7 days)
   - **Compression**: ZSTD (good compression)
   - **Mode**: Snapshot (faster, less downtime)
   - **Protected**: ✓ (prevent accidental deletion)
   - **Email**: Your notification email

### Manual Backup

```bash
# Create manual backup via command line
vzdump 110 --storage local --compress zstd --mode snapshot

# List available backups
ls -la /var/lib/vz/dump/

# Restore from backup (if needed)
qmrestore /var/lib/vz/dump/vzdump-qemu-110-*.vma.zst 110
```

## VM Cloning and Templates

### Creating VM Templates (Future Use)

```bash
# After configuring a VM perfectly, convert to template:
# 1. Shutdown VM
qm shutdown 110

# 2. Convert to template
qm template 110

# 3. Clone from template for new VMs
qm clone 110 130 --name new-vm --full
```

### VM Cloning for Testing

```bash
# Clone existing VM for testing
qm clone 110 111 --name pihole-test --full

# Start cloned VM with different network config
qm set 111 --net0 virtio,bridge=vmbr1
```

## VM Performance Tuning

### CPU Optimization

```bash
# Set CPU governor on VMs for better performance
ssh homelab@10.0.10.10
echo performance | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Make permanent by adding to /etc/rc.local:
echo 'echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor' | sudo tee -a /etc/rc.local
```

### Memory Optimization

```bash
# Configure swappiness for better memory management
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

# Configure memory ballooning (done via Proxmox)
# Allows dynamic memory allocation between VMs
```

### Storage Optimization

```bash
# Enable TRIM/discard for SSD performance
sudo systemctl enable fstrim.timer
sudo systemctl start fstrim.timer

# Configure I/O scheduler
echo mq-deadline | sudo tee /sys/block/sda/queue/scheduler
```

## VM Security Configuration

### SSH Hardening

```bash
# Disable root SSH login
sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Change SSH port (optional)
sudo sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config

# Restart SSH service
sudo systemctl restart ssh
```

### Firewall Configuration

```bash
# Enable UFW firewall
sudo ufw enable

# Allow SSH
sudo ufw allow ssh

# Allow specific services (adjust per VM)
# Pi-hole VM:
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 53/tcp   # DNS TCP
sudo ufw allow 53/udp   # DNS UDP

# Docker Host VM:
sudo ufw allow 9000/tcp  # Portainer
sudo ufw allow 3001/tcp  # Uptime Kuma
```

### Automatic Updates

```bash
# Configure unattended upgrades
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure unattended-upgrades

# Configure update settings
sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

## Troubleshooting VM Issues

### Common VM Problems

#### 1. VM Won't Start

```bash
# Check VM configuration
qm config 110

# Check Proxmox logs
tail -f /var/log/pve-firewall.log
tail -f /var/log/pvedaemon.log

# Check storage availability
pvesm status
```

#### 2. Network Issues in VM

```bash
# Check VM network configuration
ssh homelab@10.0.10.10 'ip addr show'

# Test connectivity from VM
ssh homelab@10.0.10.10 'ping 10.0.10.1'  # Gateway
ssh homelab@10.0.10.10 'ping 8.8.8.8'    # Internet

# Check Proxmox bridge status
brctl show vmbr1
```

#### 3. Performance Issues

```bash
# Check VM resource usage
qm monitor 110
info cpus
info memory

# Check host resource usage
htop
iostat 1

# Check VM disk I/O
ssh homelab@10.0.10.10 'iostat -x 1'
```

### VM Recovery Procedures

#### Boot Issues

```bash
# Boot from ISO for recovery
# 1. Attach Ubuntu ISO to VM
# 2. Change boot order in VM Options
# 3. Boot and use rescue mode

# Mount existing filesystem
sudo mkdir /mnt/recovery
sudo mount /dev/sda2 /mnt/recovery
sudo chroot /mnt/recovery
```

#### Network Recovery

```bash
# Reset network configuration
sudo netplan --debug generate
sudo netplan apply

# Or manually configure interface
sudo ip addr add 10.0.10.10/24 dev ens18
sudo ip route add default via 10.0.10.1
```

## VM Monitoring and Maintenance

### Regular Maintenance Tasks

```bash
# Weekly VM maintenance script
#!/bin/bash
# Update packages
sudo apt update && sudo apt upgrade -y

# Clean package cache
sudo apt autoremove -y
sudo apt autoclean

# Check disk usage
df -h

# Check service status
systemctl status qemu-guest-agent
```

### VM Health Monitoring

```bash
# Check VM uptime and load
uptime

# Monitor memory usage
free -h

# Check disk usage
df -h

# Monitor network connectivity
ping -c 4 10.0.10.1
```

## Next Steps

After VM creation and configuration:

1. **[Deploy Pi-hole Service](04-service-deployment.md#pihole-installation)**
2. **[Set up Docker Platform](04-service-deployment.md#docker-setup)**
3. **[Configure Service Monitoring](04-service-deployment.md#monitoring-setup)**
4. **[Test Network Connectivity](../troubleshooting/common-issues.md)**

## Related Documentation

- [Network Configuration](02-network-configuration.md)
- [Service Deployment](04-service-deployment.md)
- [Architecture Overview](../architecture/service-overview.md)
- [Troubleshooting Guide](../troubleshooting/common-issues.md)
