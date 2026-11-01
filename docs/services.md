# Running services â€” 1 November 2026

Deployments run from `/root/homelab` on each Proxmox host. Both checkouts contain the deployment scripts; guest payloads come from that checkout. Authentication uses normal host configuration. No personal identity material, identity filenames or desktop paths are embedded in scripts.

| Service | Resource | LAN endpoint | Storage |
| --- | --- | --- | --- |
| Uptime Kuma 2.5.8 | pve02 VM100, apps01 | http://192.168.1.58:3001 | Local named Docker volume homelab-uptime-kuma-data |
| Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8 | pve01 CT100, dns01 | http://192.168.1.210/admin/ ; DNS 192.168.1.210 TCP/UDP 53 | Native guest configuration/databases under /etc/pihole |
| Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8 | pve02 CT101, dns02 | http://192.168.1.150/admin/ ; DNS 192.168.1.150 TCP/UDP 53 | Native guest configuration/databases under /etc/pihole |
| Caddy 2.11.7 reverse proxy | pve02 VM100, apps01 | https://proxy.home.arpa/ and the eight service names below, LAN ports80/443 | Persistent homelab-caddy-data/config named volumes |

apps01 has 2 vCPU, 3 GiB RAM and a 32 GiB disk. dns01 and dns02 are each an unprivileged Debian 13 LXC with 1 vCPU, 512 MiB RAM and an 8 GiB disk. Debian systemd requires nesting enabled in this LXC. All three guests start automatically and are permanent resources, not old test guests.

## Addressing and access

All three guests use static IPv4 configuration on vmbr0, gateway/OS DNS192.168.1.1. Matching DHCP reservations prevent the router pool from assigning their addresses elsewhere. The router pool remains .10-.254, 1440-minute leases:

- apps01: BC:24:11:B4:7E:DA, static/reserved 192.168.1.58.
- dns01: BC:24:11:42:2A:6F, static/reserved 192.168.1.210.
- dns02: BC:24:11:6F:74:55, static/reserved 192.168.1.150.

All three retained static networking after guest reboot; repeat migration checks passed. Proxmox .2/.3 were already static. No OS/Proxmox node identity was renamed.

| Service | Static backend IP | Friendly address |
| --- | --- | --- |
| Proxmox pve01 | 192.168.1.2 | https://pve01.home.arpa/ |
| Proxmox pve02 | 192.168.1.3 | https://pve02.home.arpa/ |
| Pi-hole dns01 | 192.168.1.210 | https://pihole01.home.arpa/ |
| Pi-hole dns02 | 192.168.1.150 | https://pihole02.home.arpa/ |
| Uptime Kuma apps01 | 192.168.1.58 | https://uptime.home.arpa/ |
| Service links / Caddy | 192.168.1.58 | https://proxy.home.arpa/ |
| Homepage 2.7.0 | 192.168.1.58, private Docker backend | https://home.home.arpa/ |
| Vaultwarden 1.37.4 | 192.168.1.58, private Docker backend | https://vault.home.arpa/ |
| Grafana 13.3.0 | 192.168.1.58, private Docker backend | https://grafana.home.arpa/ |

Web names point to proxy .58. Direct node01/node02.home.arpa names point to .2/.3, dns01/dns02.home.arpa to .210/.150, apps01.home.arpa to .58. Existing SSH aliases remain unchanged. Both Pi-holes have the records; Windows resolves home.arpa through a scoped NRPT rule while internet DNS continues through router .1. Other devices need local DNS and public Caddy root trust. The public root import completed for this Windows user; all nine pages pass normal Windows HTTPS/default trust. Automated visual browser verification was not established. See [local access deployment and limits](local-access.md).

The proposed .53/.54 addresses were not assigned. Router DHCP remains enabled. DNS1 is AdGuard filtered public 94.140.14.14; DNS2/3 are Pi-hole .210/.150. Ten baseline and ten both-Pi-hole-container-outage checks passed through normal desktop/router DNS, including fresh ad blocking and HTTPS. AdGuard can answer even when nodes are healthy and uses its own list; this accepted compromise does not promise exclusive Pi-hole-first selection. See [DNS configuration, evidence and limits](pihole.md). Public port forwarding was not changed. Portainer is not deployed.

Account files are root-only and outside Git: `/etc/homelab/uptime-kuma.json` on pve02 and `/etc/homelab/pihole-password` on both nodes. Use the external credential store to retrieve passwords; never paste them into scripts, notes or Git. The Kuma username is merin.

## Vault, dashboard and node monitoring

Vaultwarden, Homepage and Prometheus 3.15.1/Grafana 13.3.0/Alertmanager 0.34.2 run as private Docker backends with pinned official image digests. Prometheus/Alertmanager have no public proxy routes or host ports. Debian node exporters 1.9.0-1+b4 run on each Proxmox LAN IP:9100. Grafana login is required; its dashboard shows both hosts' CPU, available RAM, filesystem space, exporter status and firing alerts. Six rules cover outage, sustained pressure and failed management services. Telegram firing and recovery notifications were accepted by the API with zero integration failures. See [monitoring](monitoring.md).

Vaultwarden has one privately invited owner pending registration; public signup is denied. Choose the master password directly in the web vault. Isolated real API/encryption/cold-backup/restore acceptance passed and disposable resources were cleaned. The daily backup timer, initial private off-node copy and limitations are described in [vault and Homepage](vault-and-homepage.md). No real owner master password or real vault item was created by an agent.

All seven containers/seven persistent volumes, static network, unchanged public CA, private login, pre-restart metric history and backup timer passed a graceful apps01 VM restart after increasing its RAM to3 GiB. Host reboots were not performed. Windows normal HTTPS9/9 and router DNS/filtering/internet10/10 passed. Private Grafana/Telegram runtime data remain outside Git.

## Earlier verified behavior

- Docker 29.9.2 and Compose 5.6.1 run inside apps01, not on the Proxmox host.
- Kuma is pinned to `louislam/uptime-kuma@sha256:20abea8c48a163cf0a7a5d5936ab418e4b742d908704e1f58f6c06e56a9c6b67` with a persistent local volume and explicit SQLite database.
- Its account was initialized before LAN publication; repeat initialization verified the account and retained three monitors. Both Proxmox HTTPS monitors and the Pi-hole DNS monitor have fresh UP heartbeats after guest reboot.
- Pi-hole login and authenticated statistics API succeeded; anonymous statistics access was denied. TCP and UDP DNS queries succeeded from the desktop.
- A temporary exact example.com deny entry produced 0.0.0.0 over UDP and TCP; the entry was removed and positive resolution restored.
- The original two service login pages returned HTTP 200 after following redirects. An initial installer umask bug caused Pi-hole web-parent permissions to be too restrictive; it was repaired, version reporting restored, and a regression test now enforces service-readable web files.
- The original apps01 and dns01 guests were rebooted; services, account/configuration and monitoring data persisted. Repeat deployment verification preserved existing Pi-hole data and account settings.

Latest affected source checks passed: 43 general behavior cases, 95 native Pi-hole cases, 16 Bash syntax checks and the identity-free audit of 20 scripts. The preceding application suite passed 34 cases. Counts refer to separate offline suites. Mocks do not replace the live results above. See [deployment commands](deployment.md) and [apps01 details](apps01.md).

## Remaining work

Configure off-node backups and test restore. Complete local DNS/public-root trust on any additional client devices. Both Pi-holes have 76,737 gravity entries, working direct DNS/auth/web access and restart recovery. dns02 FTL/cron are active/enabled; both onboot flags are set. Both DNS services were absent during the successful client outage test; hosts/router were not powered off. Host/router cold boot, live IPv6 routing/isolation and automatic address-change handling were not tested; these services now use static addresses. Kuma retains its existing three monitors; dns02 has no added monitor yet. The broad health scripts include a planned Portainer target, so use explicit target overrides. Legacy Docker Pi-hole examples are not the native deployment used here.

## Reverse proxy verification

Caddy is pinned to caddy@sha256:e70b164da81ef698b3ad19af799ea6086ce6d9e48ed4079eb9fe26f6fbf14ee5. Actual Linux Caddy/Compose validation passed. All six HTTPS pages and HTTP308 redirects passed through actual Windows DNS with explicit public-CA verification; Schannel required best-effort handling for the private CA's missing CRL. Proxy-side CA/hostname validation of both Proxmox upstreams remains enabled.

Independent functional checks passed both proxied Pi-hole logins/statistics/anonymous denial/session cleanup and Kuma authenticated WebSocket-only access to its existing three monitors, with fresh UP heartbeats. Source checks passed31 reverse-proxy,27 static-input/parser and6 local-DNS cases,21 shell syntax checks and29-file identity audit. Repeated proxy application retained its image/CA/data; a deliberately invalid isolated candidate was rejected before activation while the current proxy remained healthy. apps01 reboot recovered static networking, Caddy/Kuma and the unchanged CA. Both Proxmox nodes passed authenticated API access and actual console WebSocket authentication/display checks; no shell input was entered. Final client trust status is recorded in the latest vault report.
