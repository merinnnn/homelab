# Homelab Infrastructure

A Proxmox-based virtual environment for self-hosted services and infrastructure automation.

## Hardware

| Component | Specification |
|---|---|
| **Host** | HP EliteDesk Mini G2 |
| **CPU** | Intel Core i7-8700 (6 cores) |
| **RAM** | 8 GB DDR4 |
| **Storage** | 256 GB SSD |
| **Network** | Bridged via Wi-Fi extender |
| **Hypervisor** | Proxmox VE |

## Network Architecture

```text
                         [ Internet ]
                              |
                       [ Wi-Fi Extender ]
                              |
                    [ Proxmox Host / vmbr0 ]
                              |
                         ┌────┴────┐
                         │  vmbr1  │
                         │ Internal│
                         │ Network │
                         └────┬────┘
                              |
                    10.0.10.0/24
                         /         \
                        /           \
                 [ Pi-hole ]   [ Docker Host ]
                  10.0.10.10     10.0.10.20
                                     |
                              ┌──────┴──────┐
                              |             |
                         [Portainer]   [Uptime Kuma]
                          :9000            :3001
```

### Network Interfaces

- **`vmbr0`** — External bridge connected to the physical LAN through the Wi-Fi extender.
- **`vmbr1`** — Internal, isolated homelab network using `10.0.10.0/24`.
- **Gateway** — `10.0.10.1` (Proxmox host).

## Deployed Services

| Service | Host | Port | Purpose |
|---|---|---:|---|
| **Pi-hole** | `10.0.10.10` | — | DNS filtering and ad blocking |
| **Portainer** | `10.0.10.20` | `9000` | Docker container management |
| **Uptime Kuma** | `10.0.10.20` | `3001` | Service monitoring and alerts |

### Service URLs

```text
Portainer:   http://10.0.10.20:9000
Uptime Kuma: http://10.0.10.20:3001
Pi-hole:     http://10.0.10.10
```

## Repository Structure

```text
.
├── configs/
│   ├── proxmox/
│   ├── docker/
│   └── services/
├── docs/
│   ├── setup/
│   └── architecture/
├── scripts/
│   └── *.sh
├── tests/
│   ├── network-connectivity.sh
│   └── service-health.sh
└── .github/
    └── workflows/
        └── *.yml
```

### Directory Overview

- **`configs/`** — Proxmox, Docker, and service configuration files.
- **`docs/`** — Setup guides and architecture documentation.
- **`scripts/`** — Bash automation for setup and maintenance.
- **`tests/`** — Network connectivity and service health-check scripts.
- **`.github/workflows/`** — CI/CD validation pipelines.

## Testing

Run the network and service health checks from the repository root:

```bash
bash tests/network-connectivity.sh
bash tests/service-health.sh
```

These scripts verify:

- Network connectivity between infrastructure components.
- Availability of deployed services.
- Basic health of the homelab network.

## Security

The current security model includes:

- Internal services isolated from direct external internet access.
- `iptables` NAT and port-forwarding rules used to expose only required services.
- SSH hardened with root login disabled.
- Internal services hosted on the isolated `vmbr1` network.

> **Note:** Port-forwarding and firewall rules should be reviewed whenever a new externally accessible service is deployed.

## Future Plans

### Remote Access

- [ ] Deploy **WireGuard VPN** for secure remote access.
- [ ] Avoid exposing management interfaces directly to the public internet.

### Infrastructure Automation

- [ ] Introduce **Ansible** for automated VM provisioning and configuration.
- [ ] Automate repeatable host and service setup.

### Monitoring

- [ ] Deploy **Prometheus** for metrics collection.
- [ ] Deploy **Grafana** for dashboards and visualization.
- [ ] Integrate monitoring with Uptime Kuma where appropriate.

### Reverse Proxy

- [ ] Deploy **HAProxy** as a reverse proxy.
- [ ] Configure SSL/TLS termination.
- [ ] Centralize access to self-hosted web services.

## Architecture Goals

The homelab is designed around the following principles:

1. **Isolation** — Keep infrastructure and self-hosted services on an internal network.
2. **Security** — Minimize externally exposed services and harden administrative access.
3. **Automation** — Reduce manual configuration through scripts and Ansible.
4. **Observability** — Monitor service availability and system health.
5. **Scalability** — Keep the architecture flexible enough to add additional VMs, containers, and services.
