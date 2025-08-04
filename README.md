
# 🧪 Homelab Infrastructure — Self-Hosted Automation Lab

Welcome to my homelab! This project is a reproducible infrastructure-as-code setup designed for learning, experimentation, and hosting essential services on a single-node **Proxmox-based virtual environment**.

---

## 🖥️ Hardware

| Component        | Spec                         |
|------------------|------------------------------|
| **Host Device**   | HP EliteDesk Mini G2         |
| **CPU**           | Intel i7-8700 (6 cores)     |
| **RAM**           | 8GB DDR4                    |
| **Disk**          | 256GB SSD                    |
| **Network**       | WiFi extender (bridged)      |
| **Virtualization**| Proxmox VE                   |

---

## 🌐 Network Architecture

```txt
        [Internet]
            |
     [WiFi Extender]
            |
     [Proxmox Host (vmbr0)]
            |
        ┌───vmbr1───┐
        │           │
    [Pi-hole]   [Docker Host]
   10.0.10.10    10.0.10.20
```

- **vmbr0**: External bridge (connected to LAN via WiFi extender)
- **vmbr1**: Internal isolated homelab network (10.0.10.0/24)
- **Gateway**: 10.0.10.1 (Proxmox host)

---

## 📦 Services Deployed

| Service       | Purpose                      | URL                                |
|---------------|------------------------------|-------------------------------------|
| **Pi-hole**   | DNS filtering & Ad blocking  | `http://<HOST>:8080/admin`         |
| **Portainer** | Docker management UI         | `http://<HOST>:9000`               |
| **Uptime Kuma** | Monitoring & alerts         | `http://<HOST>:3001`               |

Each is isolated inside its own VM or containerized environment.

---

## 📁 Repository Structure

```
homelab/
├── docs/                 # Step-by-step setup guides
├── scripts/              # Automations for setup & testing
├── configs/              # Proxmox, Docker, and service config files
├── tests/                # Connectivity & service health checks
├── infrastructure/       # Future Terraform/Ansible expansions
└── .github/              # CI/CD and issue templates
```

---

## 📚 Documentation

| Guide                  | Purpose                                        |
|------------------------|------------------------------------------------|
| **01-proxmox-setup**   | Install and configure Proxmox VE               |
| **02-network-configuration** | Create vmbr1 bridge, NAT, DHCP, firewall  |
| **03-vm-creation**     | Deploy Pi-hole and Docker Host VMs            |
| **04-service-deployment** | Setup Pi-hole, Portainer, and Uptime Kuma   |

All setup steps are **scriptable** and **documented** in [`docs/setup`](./docs/setup).

---

## 🧪 Testing & Validation

Automated tests ensure full end-to-end homelab health:

- ✅ VM connectivity (gateway, DNS, internet)
- ✅ DNS resolution + blocking (via Pi-hole)
- ✅ Port health checks (HTTP, DNS, etc.)
- ✅ HTTP interface responses (curl)
- ✅ External access (via NAT rules)

> Run:
```bash
bash tests/network-connectivity.sh
bash tests/service-health.sh
```

---

## 🛡️ Security & Isolation

- Internal services are **fully air-gapped** from the internet
- **Port forwarding rules** (iptables) expose only necessary ports externally
- SSH hardened, root login disabled, UFW and firewall rules configured
- DNS logs and metrics captured via Pi-hole and future Prometheus setup

---

## 📈 Monitoring (WIP)

Planned:

- Prometheus metrics via exporters
- Grafana dashboards for system + service health
- Alertmanager for failure notification

---

## 🔄 Backup & Recovery

- Daily VM snapshot backups using `vzdump`S

---

## 🧰 Tooling

- **Virtualization**: Proxmox VE (KVM-based)
- **Containerization**: Docker, Docker Compose
- **Monitoring**: Uptime Kuma (now), Prometheus/Grafana (soon)
- **Scripting**: Bash automation for setup/testing
- **Networking**: iptables, NAT, port forwarding
- **CI/CD**: GitHub Actions for doc + config linting

---

## 🛣️ Future Roadmap

- 🔒 WireGuard VPN for secure remote access
- 🐧 Ansible-based VM provisioning
- 🌍 Terraform for infrastructure templating
- 📊 Full Prometheus + Grafana monitoring stack
- 🌐 HAProxy reverse proxy for SSL + load balancing

---

