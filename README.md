# Homelab Infrastructure

A Proxmox-based virtual environment for self-hosted services and infrastructure automation.

---

## Hardware

| Component | Specification |
| :--- | :--- |
| **Nodes** | 2× Mini PCs |
| **Hypervisor** | Proxmox VE 9.x |
| **Network** | TP-Link RE220 Wi-Fi Extender → Ethernet Switch |

---

## Network Architecture

```text
               [ Main Router ]
                      |
            [ TP-Link RE220 Extender ]
                      |
                [ Ethernet Switch ]
                 /             \
        [ Node 1 ]         [ Node 2 ]
         /      \            /      \
     vmbr0    vmbr1      vmbr0    vmbr1
   (Main)   (Test)     (Main)   (Test)
      |        |          |        |
  [Pi-hole] [Test VMs] [Docker]  [Test VMs]
```

### Network Bridges

| Bridge | Purpose | Subnet | Internet Access |
| :--- | :--- | :--- | :--- |
| `vmbr0` | Production services | `192.168.1.0/24` | Direct (via main router) |
| `vmbr1` | Isolated test network | `10.0.10.0/24` | NAT via `vmbr0` |

- **`vmbr0`** is bridged to the physical Ethernet interface. MAC passthrough is confirmed working via the TP-Link RE220, allowing VMs and containers to receive native IPs from the main router.
- **`vmbr1`** is an internal-only bridge. Outbound internet access is provided via `nftables` masquerade on the Proxmox host. Inbound connections originating from the main LAN are dropped.

---

## Deployed Services

| Service | Host | IP | Port | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Pi-hole** | Node 1 LXC | `192.168.1.53` | `80` | DNS filtering & ad blocking |
| **Docker Host** | Node 1 LXC | `192.168.1.54` | — | Container runtime |
| **Portainer** | Docker Host | `192.168.1.54` | `9000` | Docker management UI |
| **Uptime Kuma** | Docker Host | `192.168.1.54` | `3001` | Service monitoring |

---

## Repository Structure

```text
.
├── scripts/
│   ├── bootstrap/               # Node initialization (run once per node)
│   │   ├── post-install.sh
│   │   ├── network.sh
│   │   └── nat.sh
│   ├── deploy/                  # Service deployment
│   │   ├── pihole.sh
│   │   └── docker-host.sh
│   └── tests/                   # Health checks
│       ├── network-connectivity.sh
│       └── service-health.sh
├── configs/
│   ├── docker/                  # Docker Compose stacks
│   │   ├── pihole/
│   │   ├── portainer/
│   │   └── uptime-kuma/
│   └── proxmox/                 # Proxmox config templates
├── docs/                        # Architecture notes
└── .github/
    └── workflows/               # CI/CD pipelines
```

---

## Quick Start

### 1. Bootstrap a New Node

```bash
# Configure enterprise/no-subscription repos, remove subscription nag
sudo bash scripts/bootstrap/post-install.sh

# Set up vmbr0 (main) and vmbr1 (test) bridges
sudo PROXMOX_IP=192.168.1.50 bash scripts/bootstrap/network.sh
sudo reboot

# Enable internet masquerade for the isolated test network
sudo bash scripts/bootstrap/nat.sh
```

### 2. Deploy Services

```bash
# Pi-hole (DNS sinkhole for the primary network)
sudo bash scripts/deploy/pihole.sh

# Docker host (for Portainer, Uptime Kuma, etc.)
sudo bash scripts/deploy/docker-host.sh
```

### 3. Run Verification Tests

```bash
bash scripts/tests/network-connectivity.sh
bash scripts/tests/service-health.sh
```

---

## Configuration

All deployment scripts support customization through environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PROXMOX_IP` | `192.168.1.50` | Static IP for the Proxmox host |
| `GATEWAY` | `192.168.1.1` | Main upstream router IP |
| `CT_ID` | `100` / `101` | Proxmox Container ID |
| `CT_IP` | `192.168.1.53` / `.54` | Container static IPv4 address |
| `CT_PASS` | `ChangeMe123!` | Initial container root password |

**Example:**

```bash
sudo CT_ID=200 CT_IP=192.168.1.60 bash scripts/deploy/pihole.sh
```

---

## Architecture Decisions

- **No Proxmox Cluster:** The Wi-Fi extender backhaul introduces latency spikes and jitter that risk split-brain conditions in a 2-node Corosync cluster. Nodes operate independently and are orchestrated via these scripts.
- **LXC over VMs:** System containers provide near-bare-metal performance with minimal RAM and CPU overhead on compact Mini PC nodes.
- **nftables over iptables:** Native to Proxmox VE 9.x. All NAT, port forwarding, and isolation rules utilize modern `nftables` syntax.
- **Split Network Design:** Production workloads attach to `vmbr0` for flat LAN visibility, while untrusted or experimental workloads run isolated on `vmbr1` behind NAT.

---

## Future Plans

- [ ] WireGuard VPN for secure external access
- [ ] Ansible playbooks for multi-node orchestration
- [ ] Prometheus + Grafana metrics collection stack
- [ ] HAProxy reverse proxy with automated Let's Encrypt SSL termination
- [ ] Proxmox Backup Server (PBS) integration for scheduled off-node backups
