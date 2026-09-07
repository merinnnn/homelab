# Networking Notes

## Physical Topology
[Main Router] --WiFi--> [TP-Link RE220] --Ethernet--> [Switch] --Ethernet--> [Proxmox Nodes]

## TP-Link RE220 Behavior

The RE220 operates in **Range Extender** mode (confirmed by the `_EXT` SSID suffix).

### MAC Passthrough

The RE220 passes MAC addresses transparently through its Ethernet port. This was verified by comparing the ARP table on the Proxmox host (`ip neigh`) against the real MAC addresses of devices on the main LAN. They match.

This means:
- Proxmox `vmbr0` can bridge directly to the physical interface
- VMs and containers receive real DHCP leases from the main router
- No host-level NAT or port forwarding is needed for `vmbr0` services

### Limitations

- **100 Mbps Ethernet port**: The RE220 has a Fast Ethernet (10/100) port, not Gigabit. This is fine for DNS, web UIs, and SSH, but not suitable for heavy media streaming or large file transfers.
- **Wi-Fi backhaul latency**: Occasional micro-drops make Proxmox clustering unreliable. Nodes are managed as standalone hosts.
- **Single point of failure**: If the RE220 loses its Wi-Fi uplink, all nodes lose connectivity.

## Bridge Configuration

### vmbr0 (Production)
- Bridged to the physical Ethernet interface
- Gets IPs from the main router's DHCP range (static assignments)
- Services here are directly accessible from the main LAN

### vmbr1 (Test)
- Internal-only bridge (no physical port)
- Subnet: 10.0.10.0/24
- Gateway: 10.0.10.1 (Proxmox host)
- Internet access via nftables masquerade through vmbr0
- Main LAN devices cannot initiate connections to vmbr1 hosts

## DNS Flow

```text
[Client: Phone/Laptop]
        │
        ▼ (DHCP assigns DNS: 192.168.1.53)
[Pi-hole LXC on vmbr0]
        │
        ▼ (Upstream queries)
[Upstream Resolvers: 1.1.1.1 / 8.8.8.8]
```
