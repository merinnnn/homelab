# Local service names and reverse proxy

The node-local helpers preserve existing IPs while moving the three service guests from DHCP to static IPv4 configuration. Both Proxmox hosts already use static .2/.3 addresses. Reserve each guest IP/MAC on the router first so its DHCP pool cannot allocate the address to another device. This does not change the accepted AdGuard-first household DNS policy.

| Resource | Owning node / ID | Static address | MAC |
| --- | --- | --- | --- |
| dns01 | pve01 CT100 | 192.168.1.210/24 | BC:24:11:42:2A:6F |
| dns02 | pve02 CT101 | 192.168.1.150/24 | BC:24:11:6F:74:55 |
| apps01 | pve02 VM100 | 192.168.1.58/24 | BC:24:11:B4:7E:DA |

The topology-specific migration helper verifies owning host, ID, name, MAC, bridge, current address and gateway. It preserves other Proxmox NIC fields, records root-only backups and rollback scripts, updates VM cloud-init metadata and the reviewed Netplan file, and checks connectivity. It refuses unrelated layouts. Apply on one guest at a time from /root/homelab, then verify guest reboot persistence before continuing:

```bash
# pve01
bash scripts/deploy/proxmox-static-network.sh lxc 100 dns01 192.168.1.210/24 192.168.1.1
# pve02
bash scripts/deploy/proxmox-static-network.sh lxc 101 dns02 192.168.1.150/24 192.168.1.1
bash scripts/deploy/proxmox-static-network.sh vm 100 apps01 192.168.1.58/24 192.168.1.1
```

## Local DNS and client setup

configs/local-services.json defines the web names, all pointing to proxy/apps01 .58. Direct infrastructure names node01/node02 point to .2/.3, dns01/dns02 to .210/.150, apps01 to .58. Existing short OS hostnames and Proxmox node identities are unchanged. Use existing SSH aliases or direct infrastructure names for SSH; proxied web names point to apps01, not to the backend machine.

```bash
# pve01, then pve02 with 101 dns02:
bash scripts/deploy/proxmox-local-dns.sh 100 dns01
```

The helper merges local records into Pi-hole, preserving unrelated entries and refusing conflicting aliases. Both Pi-holes need the same records. It snapshots private configuration root-only, restarts FTL and validates the answers, rolling back its hosts setting on failure.

Public AdGuard cannot resolve private home.arpa names. Keep household router DNS unchanged. On a Windows client, run scripts/client/Set-HomelabDns.ps1 in elevated PowerShell to add only a .home.arpa NRPT rule using both Pi-holes. It preserves interface DNS and other policies, including Tailscale. -Remove removes only the validated owned rule. Verify with Resolve-DnsName without -Server or system/browser resolution: nslookup bypasses NRPT. Other devices need their own conditional local DNS configuration or equivalent hosts records; router DNS alone does not provide these private names. If both nodes are off, local service names are unavailable while normal internet DNS remains independent.

## HTTPS reverse proxy

| Friendly address | Backend |
| --- | --- |
| https://pve01.home.arpa/ | https://192.168.1.2:8006/ |
| https://pve02.home.arpa/ | https://192.168.1.3:8006/ |
| https://pihole01.home.arpa/ | http://192.168.1.210/admin/ |
| https://pihole02.home.arpa/ | http://192.168.1.150/admin/ |
| https://uptime.home.arpa/ | http://192.168.1.58:3001/ |
| https://proxy.home.arpa/ | Service links |
| https://home.home.arpa/ | http://homelab-homepage:3000/ on the private proxy network |
| https://vault.home.arpa/ | http://homelab-vaultwarden:80/ on the private proxy network |
| https://grafana.home.arpa/ | http://homelab-grafana:3000/ on the private proxy network |

Caddy runs in Docker in apps01, bound to its LAN address on ports80/443. HTTP redirects to HTTPS. The first installation pins the reviewed official release to its resolved digest; repeats retain it. Public Proxmox CA certificates verify each upstream's IP SAN; verification is never disabled. Prepare /etc/homelab/proxy-trust/{pve01,pve02}-ca.crt outside Git from each host's public /etc/pve/pve-root-ca.pem. Never copy TLS private keys.

```bash
# pve02
cd /root/homelab
bash scripts/deploy/proxmox-reverse-proxy.sh 100 home.arpa /etc/homelab/proxy-trust
```

Client HTTPS uses Caddy's internal CA. Its signing keys and certificate state stay in the private homelab-caddy-data/config Docker volumes. The helper exports ONLY the public /opt/homelab/reverse-proxy/root.crt. Install that public root certificate in the intended client's trusted-root store, checking its fingerprint against the guest's exported certificate. Other devices need separate trust setup. Never commit or export the private CA volume; preserve it across upgrades/reboots.

The helper refuses unknown stack directories, unrelated existing proxy project containers/volumes and configuration drift. It stages a release, validates Compose and Caddy before activation, reloads atomically, verifies all nine HTTPS pages using the public CA, and rolls back on failure. Old releases/backups are retained. The Compose .env.example contains public validation fixtures only; deployment writes a digest-pinned private runtime environment.

This is a single proxy in apps01: if apps01/pve02 is down, friendly web URLs are unavailable. Direct IP/port management remains available on surviving nodes. This proxy is independent of household internet DNS and does not change WAN forwarding. Existing service authentication remains required; no passwords are embedded in proxy configuration.

## Validation and current evidence

Run bash scripts/tests/reverse-proxy-offline.sh, node scripts/tests/static-network-offline.cjs, python3 scripts/tests/local-dns-offline.py, Bash syntax checks and the required identity-free audit. Offline checks are not live deployment evidence. Live acceptance includes actual client DNS, trusted HTTPS/redirects, authenticated Pi-hole APIs, Kuma WebSockets/monitor data, Proxmox APIs/consoles, repeat deployment, restart recovery and preserved household DNS. Current observations, failures and unrun cases belong in the external knowledge vault's latest report.

References: [Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy), [Caddy local HTTPS](https://caddyserver.com/docs/automatic-https), [Pi-hole local hosts configuration](https://docs.pi-hole.net/ftldns/configfile/), [Windows NRPT](https://learn.microsoft.com/en-us/powershell/module/dnsclient/add-dnsclientnrptrule), [home.arpa standard](https://www.rfc-editor.org/rfc/rfc8375).

Current extension: both Pi-holes serve 14 desired records. Homepage/Vaultwarden/Grafana use the existing CA and Windows suffix rule; all nine Windows HTTPS addresses passed normal trust after the final VM restart. Prometheus and Alertmanager stay internal; Grafana provides the authenticated dashboard.
