# Homelab Infrastructure

Proxmox automation for two standalone mini PCs, with Debian VM/LXC creation and an isolated test network.

## Current setup

| Node | Management address | Lab bridge |
| --- | --- | --- |
| pve01 | 192.168.1.2 | vmbr1, 10.0.10.1/24 |
| pve02 | 192.168.1.3 | vmbr1, 10.0.10.1/24 |

Both nodes run Proxmox VE 9.2.20 as observed on 1 November 2026. `vmbr0` connects to the home LAN through the RE220/switch. Each node's `vmbr1` is a separate internal bridge with dnsmasq DHCP/DNS and host NAT; matching bridge names/subnets do not connect guests across nodes. Nodes are managed independently.

Pi-hole runs in dns01 on pve01 at static 192.168.1.210 and dns02 on pve02 at static 192.168.1.150. Docker/Uptime Kuma and the Caddy reverse proxy run in apps01 on pve02 at static 192.168.1.58. All guests have matching router reservations and onboot enabled. Both Pi-holes and apps01 passed guest reboot/static-network recovery checks.

Friendly HTTPS addresses: [pve01](https://pve01.home.arpa/), [pve02](https://pve02.home.arpa/), [Pi-hole 1](https://pihole01.home.arpa/), [Pi-hole 2](https://pihole02.home.arpa/), [Uptime Kuma](https://uptime.home.arpa/), [service links](https://proxy.home.arpa/). These require local DNS and trust in the public Caddy root certificate; see [local service access](docs/local-access.md) for client setup and current verification limits. The Windows home.arpa DNS rule is installed; certificate trust may require a Windows Security Warning confirmation. Other devices are not automatically configured.

Router DNS remains AdGuard filtered public first, then both Pi-holes. This preserves household internet DNS independently of the nodes; AdGuard may answer while Pi-holes are healthy. See [DNS resilience](docs/pihole.md), [running services](docs/services.md) and [node-local deployment](docs/deployment.md). The proxy is a single apps01 service; direct IP/port management remains available if it is down. Portainer remains planned.

## Scripts

- `scripts/bootstrap/post-install.sh`: node package/repository configuration.
- `scripts/bootstrap/storage.sh`: storage setup/checks.
- `scripts/bootstrap/network.sh`: lab bridge, routing, DHCP/DNS and firewall setup.
- `scripts/provision/prepare-images.sh`: prepare Debian LXC/cloud images.
- `scripts/provision/create-vm.sh`: create a stopped cloud-init VM.
- `scripts/provision/create-lxc.sh`: create a stopped unprivileged LXC.
- `scripts/provision/provision-debian-vm.sh`: install/start/check the QEMU guest agent over SSH.
- `scripts/tests/network-connectivity.sh` and `service-health.sh`: bounded checks that exit nonzero on failures.

Review bootstrap scripts against the current node before running them. They modify host configuration and are not general-purpose health checks. Do not rerun storage/bootstrap steps to validate an already prepared node.

## Create and provision a Debian VM

Run on the intended Proxmox node after confirming storage, images, bridges and free resources. Guest IDs are allocated dynamically; use the ID printed by creation.

```bash
bash scripts/provision/prepare-images.sh
bash scripts/provision/create-vm.sh example-debian vmbr1 /etc/homelab/guest-public-keys.pub
qm start <printed-vmid>
# Wait for DHCP and cloud-init/SSH readiness, then:
bash scripts/provision/provision-debian-vm.sh <printed-vmid> homelab
qm agent <printed-vmid> ping
```

The provisioning script accepts new SSH host keys under a VMID/MAC alias and continues to reject changed keys for that identity. DHCP address reuse does not require deleting unrelated known-host entries. Debian's QEMU agent unit is device-activated; provisioning starts it and checks that it is active.

Creation/provisioning is not a transaction: if import or a later step fails, inspect the allocated guest and volumes before retrying or cleaning up. Never assume historical IDs are free.

## Health checks

Run these from a network vantage that is intended to reach the targets. Dependencies: Bash, `ping`, `dig`, `nc`, `curl`.

```bash
bash scripts/tests/network-connectivity.sh
bash scripts/tests/service-health.sh
GATEWAY=10.0.10.1 PIHOLE_IP=<actual-dns-ip> DOCKER_IP=<actual-docker-ip> \
  bash scripts/tests/network-connectivity.sh
```

Default Pi-hole/Docker addresses are the planned LAN addresses `192.168.1.53`/`.54`; override them for actual deployments. Missing services or dependencies are failures, not successful validation. ICMP/HTTP/DNS probes have bounded waits. These checks do not establish firewall isolation; test permitted and denied traffic independently.

CI parses shell scripts and validates Docker Compose configuration. It does not execute privileged bootstrap scripts or validate live hosts.

## Project records

Read [AGENTS.md](AGENTS.md) before continuing. Architecture notes are in [docs/networking.md](docs/networking.md). On the project owner's Windows machine, the Obsidian vault is `C:\Users\merin\Documents\ChatGPT\Homelab\Knowledge`; start with `00 Start Here.md`. Keep dated test evidence and handoffs there. Credentials and private keys belong outside documentation and Git.

## Deploy on the Proxmox nodes

Use the installed /root/homelab checkout on each node. See [node-local deployment](docs/deployment.md) for apps01, dns01 and dns02 commands, external runtime configuration, and checkout update rules. Repository scripts must not embed personal identities or assume identity filenames.
