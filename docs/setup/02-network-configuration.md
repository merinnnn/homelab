# Network Configuration and Setup

This document covers the detailed network configuration for the homelab environment, including the isolated internal network and external access setup.

## Network Architecture Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                           Physical Network                         │
│                           (WiFi Extender)                          │
│                            192.168.1.0/24                          │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │
┌──────────────────────────────────┴─────────────────────────────────┐
│                        Proxmox Host (vmbr0)                        │
│                         DHCP: 192.168.1.x                          │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────────┤
│  │                    Homelab Network (vmbr1)                      │
│  │                         10.0.10.0/24                            │
│  │                                                                 │
│  │      ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐      │
│  │      │   Pi-hole   │  │Docker Host  │  │  Future VMs     │      │
│  │      │ 10.0.10.10  │  │ 10.0.10.20  │  │ 10.0.10.30+     │      │
│  │      └─────────────┘  └─────────────┘  └─────────────────┘      │
│  └─────────────────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────────────────┘
```

## Network Interfaces

### vmbr0 (External Bridge)
- **Purpose**: Connection to physical network (WiFi extender)
- **Configuration**: DHCP from WiFi extender
- **Used for**: Internet access, external connectivity

### vmbr1 (Internal Homelab Bridge)
- **Purpose**: Isolated internal network for homelab services
- **Network**: 10.0.10.0/24
- **Gateway**: 10.0.10.1 (Proxmox host)
- **Used for**: Internal VM communication, service isolation

## Automated Network Setup

### Using the Setup Script

```bash
# Download and run the network setup script
wget https://raw.githubusercontent.com/YOUR_USERNAME/homelab-infrastructure/main/scripts/proxmox/setup-homelab-network.sh
chmod +x setup-homelab-network.sh
./setup-homelab-network.sh
```

### Manual Configuration Steps

If you prefer manual setup or need to troubleshoot:

#### 1. Edit Network Interfaces
```bash
# Backup current configuration
cp /etc/network/interfaces /etc/network/interfaces.backup

# Edit network configuration
nano /etc/network/interfaces
```

Add the homelab bridge configuration:
```bash
# Homelab internal network
auto vmbr1
iface vmbr1 inet static
        address 10.0.10.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up iptables -t nat -A POSTROUTING -s '10.0.10.0/24' -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '10.0.10.0/24' -o vmbr0 -j MASQUERADE
```

#### 2. Enable IP Forwarding
```bash
# Enable immediately
echo 1 > /proc/sys/net/ipv4/ip_forward

# Make permanent
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
```

#### 3. Configure NAT and Firewall Rules
```bash
# Add NAT rule for internet access
iptables -t nat -A POSTROUTING -s '10.0.10.0/24' -o vmbr0 -j MASQUERADE

# Allow forwarding
iptables -A FORWARD -s 10.0.10.0/24 -j ACCEPT
iptables -A FORWARD -d 10.0.10.0/24 -j ACCEPT

# Save rules permanently
apt install iptables-persistent -y
iptables-save > /etc/iptables/rules.v4
```

#### 4. Apply Network Configuration
```bash
# Restart networking
systemctl restart networking

# Bring up the bridge
ifup vmbr1

# Restart Proxmox services
systemctl restart pveproxy
systemctl restart pvedaemon
```

## Port Forwarding Configuration

### External Service Access

To access internal services from outside the homelab network:

```bash
# Run the port forwarding setup script
./scripts/proxmox/setup-port-forwarding.sh
```

### Manual Port Forwarding Rules

```bash
# Pi-hole (port 8080 → 10.0.10.10:80)
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 8080 -j DNAT --to 10.0.10.10:80

# Portainer (port 9000 → 10.0.10.20:9000)
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 9000 -j DNAT --to 10.0.10.20:9000

# Uptime Kuma (port 3001 → 10.0.10.20:3001)  
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 3001 -j DNAT --to 10.0.10.20:3001

# Allow forwarded traffic
iptables -A FORWARD -d 10.0.10.0/24 -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4
```

## IP Address Allocation

### Reserved Address Ranges

| Range | Purpose | Notes |
|-------|---------|-------|
| 10.0.10.1 | Gateway (Proxmox host) | Fixed |
| 10.0.10.10-19 | Infrastructure services | Pi-hole, DNS, etc. |
| 10.0.10.20-29 | Application services | Docker hosts, web services |
| 10.0.10.30-49 | Development services | Test environments |
| 10.0.10.50-99 | User services | Personal applications |
| 10.0.10.100-199 | DHCP range (future) | Dynamic allocation |
| 10.0.10.200-254 | Temporary/testing | Short-term assignments |

### Current Assignments

| IP Address | Service | VM ID | Purpose |
|------------|---------|-------|---------|
| 10.0.10.1 | Gateway | N/A | Proxmox host bridge |
| 10.0.10.10 | Pi-hole | 110 | DNS filtering, ad blocking |
| 10.0.10.20 | Docker Host | 120 | Container platform |

## VM Network Configuration

### Ubuntu VM Network Setup

During Ubuntu installation, configure networking as follows:

```yaml
Network Configuration:
  Interface: ens18 (or similar)
  Method: Manual
  Subnet: 10.0.10.0/24
  Address: 10.0.10.XX  # See IP allocation table
  Gateway: 10.0.10.1
  Name servers: 8.8.8.8,1.1.1.1
  Search domains: (leave empty)
```

### Post-Installation Network Verification

```bash
# Check IP configuration
ip addr show

# Test gateway connectivity
ping 10.0.10.1

# Test internet connectivity
ping 8.8.8.8

# Test DNS resolution
nslookup google.com
```

## Network Security

### Firewall Rules

```bash
# Allow SSH from homelab network
iptables -A INPUT -s 10.0.10.0/24 -p tcp --dport 22 -j ACCEPT

# Allow web interface access
iptables -A INPUT -s 10.0.10.0/24 -p tcp --dport 8006 -j ACCEPT

# Allow specific service ports
iptables -A INPUT -s 10.0.10.0/24 -p tcp --dport 9000 -j ACCEPT  # Portainer
iptables -A INPUT -s 10.0.10.0/24 -p tcp --dport 3001 -j ACCEPT  # Uptime Kuma
```

### Network Isolation

- Internal services are isolated on 10.0.10.0/24 network
- No direct internet exposure of internal services
- All external access goes through controlled port forwarding
- Inter-VM communication is allowed within homelab network

## DNS Configuration

### DNS Hierarchy

1. **Pi-hole** (10.0.10.10) - Primary DNS for ad blocking
2. **Upstream DNS** - 8.8.8.8, 1.1.1.1 (Google, Cloudflare)
3. **Local DNS records** - Custom internal domain resolution

### Local DNS Records (Future)

```bash
# Example local DNS entries in Pi-hole
10.0.10.10  pihole.homelab.local
10.0.10.20  docker.homelab.local
10.0.10.1   proxmox.homelab.local
```

## Performance Optimization

### Network Tuning

```bash
# Optimize network performance
echo 'net.core.rmem_default = 262144' >> /etc/sysctl.conf
echo 'net.core.rmem_max = 16777216' >> /etc/sysctl.conf
echo 'net.core.wmem_default = 262144' >> /etc/sysctl.conf
echo 'net.core.wmem_max = 16777216' >> /etc/sysctl.conf

# Apply settings
sysctl -p
```

### VM Network Performance

- Use VirtIO network drivers for VMs
- Enable multiqueue for high-throughput applications
- Consider SR-IOV for demanding applications (hardware dependent)

## Monitoring and Troubleshooting

### Network Monitoring Commands

```bash
# Check bridge status
brctl show

# Monitor network traffic
iftop -i vmbr1

# Check routing table
ip route show

# Monitor NAT connections
cat /proc/net/nf_conntrack

# Check firewall rules
iptables -L -n -v
iptables -t nat -L -n -v
```

### Common Network Issues

#### 1. VMs Can't Access Internet

```bash
# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check NAT rules
iptables -t nat -L POSTROUTING -n -v

# Verify gateway connectivity from VM
ping 10.0.10.1
```

#### 2. External Access Not Working

```bash
# Check port forwarding rules
iptables -t nat -L PREROUTING -n -v

# Verify service is running on internal IP
curl http://10.0.10.20:9000

# Check if external port is open
netstat -tlnp | grep :9000
```

#### 3. DNS Resolution Issues

```bash
# Test DNS from VM
nslookup google.com 8.8.8.8

# Check if Pi-hole is responding
dig @10.0.10.10 google.com

# Verify DNS configuration
cat /etc/resolv.conf
```

## Network Testing

### Automated Testing

Use the provided network connectivity test:

```bash
./tests/network-connectivity.sh
```

### Manual Testing Checklist

- [ ] Proxmox host can access internet
- [ ] vmbr1 bridge is up with correct IP
- [ ] IP forwarding is enabled
- [ ] NAT rules are configured
- [ ] VMs can reach gateway (10.0.10.1)
- [ ] VMs can access internet (ping 8.8.8.8)
- [ ] DNS resolution works from VMs
- [ ] Port forwarding works for services
- [ ] External access works from other devices

## Future Network Enhancements

### Planned Improvements

1. **VLAN Segmentation**
   - Separate VLANs for different service types
   - DMZ for publicly accessible services

2. **VPN Access**
   - WireGuard VPN for secure remote access
   - Split tunneling configuration

3. **Load Balancing**
   - HAProxy for service load balancing
   - SSL termination

4. **Network Monitoring**
   - Prometheus network metrics
   - Grafana network dashboards
   - AlertManager for network issues

## Related Documentation

- [VM Creation Guide](03-vm-creation.md)
- [Service Deployment](04-service-deployment.md)
- [Troubleshooting Guide](../troubleshooting/common-issues.md)
- [Network Architecture](../architecture/network-diagram.md)
