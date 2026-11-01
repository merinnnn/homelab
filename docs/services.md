# Running services — 1 November 2026

Deployments run from `/root/homelab` on each Proxmox host. Both checkouts contain the deployment scripts; guest payloads come from that checkout. Authentication uses normal host configuration. No personal identity material, identity filenames or desktop paths are embedded in scripts.

| Service | Resource | LAN endpoint | Storage |
| --- | --- | --- | --- |
| Uptime Kuma 2.5.8 | pve02 VM100, apps01 | http://192.168.1.58:3001 | Local named Docker volume homelab-uptime-kuma-data |
| Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8 | pve01 CT100, dns01 | http://192.168.1.210/admin/ ; DNS 192.168.1.210 TCP/UDP 53 | Native guest configuration/databases under /etc/pihole |
| Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8 | pve02 CT101, dns02 | http://192.168.1.150/admin/ ; DNS 192.168.1.150 TCP/UDP 53 | Native guest configuration/databases under /etc/pihole |

apps01 has 2 vCPU, 2 GiB RAM and a 32 GiB disk. dns01 and dns02 are each an unprivileged Debian 13 LXC with 1 vCPU, 512 MiB RAM and an 8 GiB disk. Debian systemd requires nesting enabled in this LXC. All three guests start automatically and are permanent resources, not old test guests.

## Addressing and access

All three guests use router DHCP on vmbr0. The router pool is .10-.254 with a 1440-minute lease. Both Pi-holes have verified .210/.150 reservations; apps01 still needs its lease reserved:

- apps01: BC:24:11:B4:7E:DA, observed 192.168.1.58.
- dns01: BC:24:11:42:2A:6F, reserved 192.168.1.210; retained after reboot.
- dns02: BC:24:11:6F:74:55, reserved 192.168.1.150; retained after controlled shutdown/start.

The proposed .53/.54 addresses were not assigned. Router DHCP remains enabled. DNS1 is AdGuard filtered public 94.140.14.14; DNS2/3 are Pi-hole .210/.150. Ten baseline and ten both-Pi-hole-container-outage checks passed through normal desktop/router DNS, including fresh ad blocking and HTTPS. AdGuard can answer even when nodes are healthy and uses its own list; this accepted compromise does not promise exclusive Pi-hole-first selection. See [DNS configuration, evidence and limits](pihole.md). Public port forwarding was not changed. Portainer is not deployed.

Account files are root-only and outside Git: `/etc/homelab/uptime-kuma.json` on pve02 and `/etc/homelab/pihole-password` on both nodes. Use the external credential store to retrieve passwords; never paste them into scripts, notes or Git. The Kuma username is merin.

## Verified behavior

- Docker 29.9.2 and Compose 5.6.1 run inside apps01, not on the Proxmox host.
- Kuma is pinned to `louislam/uptime-kuma@sha256:20abea8c48a163cf0a7a5d5936ab418e4b742d908704e1f58f6c06e56a9c6b67` with a persistent local volume and explicit SQLite database.
- Its account was initialized before LAN publication; repeat initialization verified the account and retained three monitors. Both Proxmox HTTPS monitors and the Pi-hole DNS monitor have fresh UP heartbeats after guest reboot.
- Pi-hole login and authenticated statistics API succeeded; anonymous statistics access was denied. TCP and UDP DNS queries succeeded from the desktop.
- A temporary exact example.com deny entry produced 0.0.0.0 over UDP and TCP; the entry was removed and positive resolution restored.
- The original two service login pages returned HTTP 200 after following redirects. An initial installer umask bug caused Pi-hole web-parent permissions to be too restrictive; it was repaired, version reporting restored, and a regression test now enforces service-readable web files.
- The original apps01 and dns01 guests were rebooted; services, account/configuration and monitoring data persisted. Repeat deployment verification preserved existing Pi-hole data and account settings.

Latest affected source checks passed: 43 general behavior cases, 95 native Pi-hole cases, 16 Bash syntax checks and the identity-free audit of 20 scripts. The preceding application suite passed 34 cases. Counts refer to separate offline suites. Mocks do not replace the live results above. See [deployment commands](deployment.md) and [apps01 details](apps01.md).

## Remaining work

Reserve the apps01 lease, configure off-node backups and test restore. Both Pi-holes have 76,737 gravity entries, working direct DNS/auth/web access and restart recovery. dns02 FTL/cron are active/enabled; both onboot flags are set. Both DNS services were absent during the successful client outage test; hosts/router were not powered off. Host/router cold boot, live IPv6 routing/isolation and automatic address-change handling were not tested. Kuma retains its existing three monitors; dns02 has no added monitor yet. The broad health scripts include a planned Portainer target, so use explicit target overrides. Legacy Docker Pi-hole examples are not the native deployment used here.
