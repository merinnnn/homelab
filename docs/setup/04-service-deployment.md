# Service Deployment and Configuration

This guide covers deploying and configuring all homelab services including Pi-hole, Portainer, and Uptime Kuma.

## Service Overview

| Service | VM | Internal URL | External URL | Purpose |
|---------|----|--------------|--------------|---------| 
| **Pi-hole** | 110 | http://10.0.10.10/admin | http://HOST_IP:8080/admin | DNS filtering, ad blocking |
| **Portainer** | 120 | http://10.0.10.20:9000 | http://HOST_IP:9000 | Docker management |
| **Uptime Kuma** | 120 | http://10.0.10.20:3001 | http://HOST_IP:3001 | Service monitoring |

## Prerequisites

- VMs created and configured ([VM Creation Guide](03-vm-creation.md))
- Network properly configured ([Network Guide](02-network-configuration.md))
- SSH access to both VMs
- Internet connectivity verified on all VMs

## Pi-hole Installation and Configuration

### 1. Connect to Pi-hole VM

```bash
# SSH into Pi-hole VM
ssh homelab@10.0.10.10
```

### 2. System Preparation

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required dependencies
sudo apt install -y curl wget git
```

### 3. Install Pi-hole

```bash
# Download and run Pi-hole installer
curl -sSL https://install.pi-hole.net | bash
```

### 4. Pi-hole Installation Configuration

During installation, configure:

**Interface Selection**:
- Select `ens18` (or your VM's network interface)

**Upstream DNS Provider**:
- Choose "Google" (8.8.8.8, 8.8.4.4)
- Or "Cloudflare" (1.1.1.1, 1.0.0.1)

**Block Lists**:
- ✓ Enable default block lists
- ✓ Enable additional malware protection

**Admin Web Interface**:
- ✓ Install web admin interface
- ✓ Install web server (lighttpd)

**Query Logging**:
- ✓ Enable query logging
- **Privacy Mode**: "0 - Show everything"

**Important**: Note the admin password displayed at the end of installation!

### 5. Pi-hole Post-Installation

```bash
# Set a custom admin password
pihole -a -p

# Update block lists
pihole -g

# Check Pi-hole status
pihole status

# Test DNS filtering
dig @localhost doubleclick.net
# Should return 0.0.0.0 if blocked
```

### 6. Pi-hole Web Interface Configuration

1. **Access**: http://10.0.10.10/admin
2. **Login**: Use the admin password
3. **Configure Settings**:
   - **DNS**: Add upstream DNS servers
   - **DHCP**: Disable (using router DHCP)
   - **Privacy**: Adjust as needed
   - **Block Lists**: Add custom lists if desired

### 7. Additional Block Lists (Optional)

```bash
# Add popular block lists via web interface:
# Settings → Block Lists → Add

# Example additional block lists:
# - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
# - https://someonewhocares.org/hosts/zero/hosts
# - https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/MobileFilter/sections/adservers.txt
```

## Docker Platform Setup

### 1. Connect to Docker Host VM

```bash
# SSH into Docker host VM
ssh homelab@10.0.10.20
```

### 2. Install Docker

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker using official script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add user to docker group
sudo usermod -aG docker homelab

# Install Docker Compose
sudo apt install docker-compose -y

# Enable Docker service
sudo systemctl enable docker
sudo systemctl start docker
```

### 3. Verify Docker Installation

```bash
# Reboot to apply group membership
sudo reboot

# After reboot, test Docker
ssh homelab@10.0.10.20
docker --version
docker-compose --version
docker run hello-world
```

### 4. Create Directory Structure

```bash
# Create homelab directory structure
mkdir -p ~/homelab/{portainer,uptime-kuma,configs,logs}
cd ~/homelab
```

## Portainer Deployment

### 1. Create Portainer Configuration

```bash
# Create Portainer directory
cd ~/homelab/portainer

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data
    environment:
      - TZ=Europe/London
    labels:
      - "homelab.service=portainer"
      - "homelab.description=Docker container management"
      - "homelab.url=http://10.0.10.20:9000"

volumes:
  portainer_data:
    driver: local
EOF
```

### 2. Deploy Portainer

```bash
# Start Portainer
docker-compose up -d

# Verify deployment
docker-compose ps
docker logs portainer
```

### 3. Configure Portainer

1. **Access**: http://10.0.10.20:9000
2. **Initial Setup**:
   - **Admin Username**: admin
   - **Admin Password**: (choose strong password)
   - **Confirm Password**: (repeat password)
3. **Environment Setup**:
   - Select "Docker" (local environment)
   - **Environment name**: "Docker Host"
   - Click "Connect"

### 4. Portainer Configuration

After login:
1. **Environment → local → Settings**:
   - **Public IP**: 10.0.10.20
   - **Enable Host Management**: ✓
2. **Users → Create User** (optional):
   - Create additional users if needed

## Uptime Kuma Deployment

### 1. Create Uptime Kuma Configuration

```bash
# Create Uptime Kuma directory
cd ~/homelab/uptime-kuma

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "3001:3001"
    volumes:
      - uptime-kuma-data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TZ=Europe/London
      - UPTIME_KUMA_PORT=3001
    labels:
      - "homelab.service=uptime-kuma"
      - "homelab.description=Service monitoring and alerting"
      - "homelab.url=http://10.0.10.20:3001"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:3001 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  uptime-kuma-data:
    driver: local
EOF
```

### 2. Deploy Uptime Kuma

```bash
# Start Uptime Kuma
docker-compose up -d

# Verify deployment
docker-compose ps
docker logs uptime-kuma
```

### 3. Configure Uptime Kuma

1. **Access**: http://10.0.10.20:3001
2. **Initial Setup**:
   - **Admin Username**: admin
   - **Admin Password**: (choose strong password)
   - **Repeat Password**: (confirm password)

### 4. Add Service Monitors

After initial setup, add monitors for:

#### Pi-hole Monitor
- **Monitor Type**: HTTP(s)
- **Friendly Name**: Pi-hole
- **URL**: http://10.0.10.10/admin
- **Heartbeat Interval**: 60 seconds
- **Max Retries**: 3
- **Accepted Status Codes**: 200-299

#### Portainer Monitor
- **Monitor Type**: HTTP(s)
- **Friendly Name**: Portainer
- **URL**: http://10.0.10.20:9000
- **Heartbeat Interval**: 60 seconds

#### Internet Connectivity Monitor
- **Monitor Type**: Ping
- **Friendly Name**: Internet Gateway
- **Hostname**: 8.8.8.8
- **Heartbeat Interval**: 60 seconds

#### Internal Network Monitor
- **Monitor Type**: Ping
- **Friendly Name**: Homelab Gateway
- **Hostname**: 10.0.10.1
- **Heartbeat Interval**: 60 seconds

### 5. Configure Notifications (Optional)

Set up notifications for service alerts:

**Email Notifications**:
1. **Settings → Notifications → Add New**
2. **Type**: Email (SMTP)
3. **Configuration**:
   - **SMTP Server**: your-smtp-server.com
   - **Port**: 587 (or 465 for SSL)
   - **Username**: your-email@domain.com
   - **Password**: your-app-password
   - **From Email**: your-email@domain.com
   - **To Email**: your-notification-email@domain.com

**Discord Notifications** (if preferred):
1. **Create Discord Webhook** in your server
2. **Settings → Notifications → Add New**
3. **Type**: Discord
4. **Discord Webhook URL**: (paste webhook URL)

## External Access Configuration

### 1. Set Up Port Forwarding

```bash
# SSH into Proxmox host
ssh root@PROXMOX_IP

# Run port forwarding script
./scripts/proxmox/setup-port-forwarding.sh

# Or configure manually:
# Pi-hole (port 8080 → 10.0.10.10:80)
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 8080 -j DNAT --to 10.0.10.10:80

# Portainer (port 9000 → 10.0.10.20:9000) 
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 9000 -j DNAT --to 10.0.10.20:9000

# Uptime Kuma (port 3001 → 10.0.10.20:3001)
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 3001 -j DNAT --to 10.0.10.20:3001

# Allow forwarded traffic
iptables -A FORWARD -d 10.0.10.0/24 -j ACCEPT

# Save rules permanently
iptables-save > /etc/iptables/rules.v4
```

### 2. Test External Access

```bash
# Find your Proxmox host external IP
EXTERNAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)
echo "External IP: $EXTERNAL_IP"

# Test services from another device:
# - Pi-hole: http://EXTERNAL_IP:8080/admin
# - Portainer: http://EXTERNAL_IP:9000
# - Uptime Kuma: http://EXTERNAL_IP:3001
```

## Service Management

### Starting and Stopping Services

```bash
# On Docker Host VM (10.0.10.20):

# Stop all services
cd ~/homelab/portainer && docker-compose down
cd ~/homelab/uptime-kuma && docker-compose down

# Start all services
cd ~/homelab/portainer && docker-compose up -d
cd ~/homelab/uptime-kuma && docker-compose up -d

# Restart services
cd ~/homelab/portainer && docker-compose restart
cd ~/homelab/uptime-kuma && docker-compose restart
```

### Service Logs

```bash
# View service logs
docker logs portainer -f
docker logs uptime-kuma -f

# View compose logs
cd ~/homelab/portainer && docker-compose logs -f
cd ~/homelab/uptime-kuma && docker-compose logs -f
```

### Service Updates

```bash
# Update service images
cd ~/homelab/portainer
docker-compose pull
docker-compose up -d

cd ~/homelab/uptime-kuma
docker-compose pull
docker-compose up -d

# Clean up old images
docker image prune -f
```

## Backup Procedures

### Pi-hole Backup

```bash
# SSH into Pi-hole VM
ssh homelab@10.0.10.10

# Create backup directory
mkdir -p ~/backups/pihole

# Backup Pi-hole configuration
sudo tar -czf ~/backups/pihole/pihole-config-$(date +%Y%m%d).tar.gz \
  /etc/pihole/ \
  /etc/dnsmasq.d/ \
  /var/log/pihole.log

# Export Pi-hole settings via web interface:
# Settings → Teleporter → Export
```

### Docker Services Backup

```bash
# SSH into Docker Host VM
ssh homelab@10.0.10.20

# Create backup directory
mkdir -p ~/backups/{portainer,uptime-kuma}

# Backup Docker volumes
docker run --rm -v portainer_portainer_data:/data -v ~/backups/portainer:/backup busybox tar czf /backup/portainer-data-$(date +%Y%m%d).tar.gz -C /data .

docker run --rm -v uptime-kuma_uptime-kuma-data:/data -v ~/backups/uptime-kuma:/backup busybox tar czf /backup/uptime-kuma-data-$(date +%Y%m%d).tar.gz -C /data .

# Backup configuration files
cp -r ~/homelab ~/backups/docker-configs-$(date +%Y%m%d)
```

## Security Considerations

### Service Security

```bash
# Update services regularly
# Use strong passwords for all admin interfaces
# Enable HTTPS where possible (future enhancement)
# Regular security audits

# Check for service vulnerabilities
docker scan portainer/portainer-ce:latest
docker scan louislam/uptime-kuma:1
```

### Network Security

- Services isolated on internal network (10.0.10.0/24)
- External access only through controlled port forwarding
- No direct internet exposure of internal services
- Regular firewall rule reviews

## Performance Monitoring

### Resource Usage Monitoring

```bash
# Monitor Docker resource usage
docker stats

# Monitor system resources
htop
iostat -x 1
free -h

# Check service health
curl -f http://10.0.10.20:9000 || echo "Portainer unhealthy"
curl -f http://10.0.10.20:3001 || echo "Uptime Kuma unhealthy"
curl -f http://10.0.10.10/admin || echo "Pi-hole unhealthy"
```

### Performance Optimization

```bash
# Optimize Docker daemon
sudo nano /etc/docker/daemon.json
```

Add optimization settings:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
```

```bash
# Restart Docker
sudo systemctl restart docker
```

## Troubleshooting Common Issues

### Service Won't Start

```bash
# Check Docker daemon
sudo systemctl status docker

# Check service logs
docker logs portainer
docker logs uptime-kuma

# Check port conflicts
netstat -tlnp | grep -E ':9000|:3001'

# Recreate service
cd ~/homelab/portainer
docker-compose down
docker-compose up -d
```

### External Access Issues

```bash
# Check port forwarding rules
iptables -t nat -L PREROUTING -n -v

# Test internal connectivity first
curl http://10.0.10.20:9000

# Check if external port is open
nmap -p 9000 EXTERNAL_IP
```

### Pi-hole Issues

```bash
# Check Pi-hole status
pihole status

# Restart Pi-hole
pihole restartdns

# Check DNS resolution
dig @10.0.10.10 google.com

# Update block lists
pihole -g
```

## Next Steps

After service deployment:

1. **[Configure Monitoring](../runbooks/monitoring.md)**
2. **[Set Up Backup Automation](../runbooks/backup-procedures.md)**
3. **[Test All Services](../../tests/service-health.sh)**
4. **[Plan Future Expansions](../architecture/service-overview.md#future-services)**

## Related Documentation

- [Network Configuration](02-network-configuration.md)
- [VM Management](03-vm-creation.md)
- [Service Architecture](../architecture/service-overview.md)
- [Troubleshooting Guide](../troubleshooting/common-issues.md)
