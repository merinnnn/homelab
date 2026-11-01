# Running services — 1 November 2026

Deployments run from `/root/homelab` on each Proxmox host. Both checkouts contain the deployment scripts; guest payloads come from that checkout. Authentication uses normal host configuration. No personal identity material, identity filenames or desktop paths are embedded in scripts.

| Service | Resource | LAN endpoint | Storage |
| --- | --- | --- | --- |
| Uptime Kuma 2.5.8 | pve02 VM100, apps01 | http://192.168.1.58:3001 | Local named Docker volume homelab-uptime-kuma-data |
| Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8 | pve01 CT100, dns01 | http://192.168.1.210/admin/ ; DNS 192.168.1.210 TCP/UDP 53 | Native guest configuration/databases under /etc/pihole |

apps01 has 2 vCPU, 2 GiB RAM and a 32 GiB disk. dns01 is an unprivileged Debian 13 LXC with 1 vCPU, 512 MiB RAM and an 8 GiB disk. Debian systemd requires nesting enabled in this LXC. Both guests start automatically and are permanent resources, not old test guests.

## Addressing and access

Both guests use router DHCP on vmbr0. The router pool is .10-.254 with a 1440-minute lease. Pi-hole has a verified .210 reservation; apps01 still needs its lease reserved:

- apps01: BC:24:11:B4:7E:DA, observed 192.168.1.58.
- dns01: BC:24:11:42:2A:6F, reserved 192.168.1.210; retained after reboot.

The old proposed addresses .53/.54 were not assigned. Router DHCP remains enabled. DNS1/2 are now 1.1.1.1/1.0.0.1, with Pi-hole .210 as DNS3. Default desktop browsing passed while Pi-hole CT100 was stopped; household ad filtering is best effort and is currently bypassed by public DNS. Public port forwarding was not changed. See [Pi-hole network setup and rollback](pihole.md). Portainer is not deployed.

Account files are root-only and outside Git: `/etc/homelab/uptime-kuma.json` on pve02 and `/etc/homelab/pihole-password` on pve01. Use the external credential store to retrieve passwords; never paste them into scripts, notes or Git. The Kuma username is merin.

## Verified behavior

- Docker 29.9.2 and Compose 5.6.1 run inside apps01, not on the Proxmox host.
- Kuma is pinned to `louislam/uptime-kuma@sha256:20abea8c48a163cf0a7a5d5936ab418e4b742d908704e1f58f6c06e56a9c6b67` with a persistent local volume and explicit SQLite database.
- Its account was initialized before LAN publication; repeat initialization verified the account and retained three monitors. Both Proxmox HTTPS monitors and the Pi-hole DNS monitor have fresh UP heartbeats after guest reboot.
- Pi-hole login and authenticated statistics API succeeded; anonymous statistics access was denied. TCP and UDP DNS queries succeeded from the desktop.
- A temporary exact example.com deny entry produced 0.0.0.0 over UDP and TCP; the entry was removed and positive resolution restored.
- Both actual login pages returned HTTP 200 after following redirects. An initial installer umask bug caused Pi-hole web-parent permissions to be too restrictive; it was repaired, version reporting restored, and a regression test now enforces service-readable web files.
- Both guests were rebooted; services, account/configuration and monitoring data persisted. Repeat deployment verification preserved existing Pi-hole data and account settings.

Source checks passed: 42 general behavior cases, 34 application cases, 47 native Pi-hole cases, Bash syntax and the identity-free script audit. Mocks do not replace the live results above. See [deployment commands](deployment.md) and [apps01 details](apps01.md).

## Remaining work

Reserve the apps01 lease, configure off-node backups and test restore. Pi-hole reservation, successful 76,737-domain gravity refresh and post-change reboot are verified. The later availability-first DNS change supersedes default-client blocking: six baseline and six container-outage DNS/HTTPS checks passed with public resolvers prioritized. Host reboot, live IPv6 routing/isolation and automatic address-change handling were not tested. The existing broad health scripts also include a planned Portainer target; use explicit target overrides and interpret undeployed-service checks accordingly. Legacy Docker Pi-hole/Portainer examples are not the native deployment used here.
