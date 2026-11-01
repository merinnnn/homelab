# Pi-hole and household DNS availability — 1 November 2026

Household browsing takes priority over ad blocking. DNS must remain usable when Pi-hole or either Proxmox node is unavailable. The router has independent public resolvers; the homelab is not a required DNS dependency.

Pi-hole remains installed in pve01 CT100 dns01: http://192.168.1.210/admin/, TCP/UDP53. It is a permanent guest, reserved at .210 for MAC BC:24:11:42:2A:6F. It retains its own upstreams 1.1.1.1/1.0.0.1; never point them back to the router.

## Current router configuration

Linksys Smart Wi-Fi, 192.168.1.1 > Connectivity > Local Network:

| Field | Address |
| --- | --- |
| Static DNS1 | 1.1.1.1 |
| Static DNS2 | 1.0.0.1 |
| Static DNS3 | 192.168.1.210 |

DHCP stays enabled on the router, pool .10-.254, lease 1440 minutes; Pi-hole DHCP stays disabled. The tested desktop continues using router .1 as its DNS server. Public resolvers are independent of both Proxmox nodes. Router/client resolver ordering is not a strict primary/backup contract: public alternatives can be used while Pi-hole is healthy. Default desktop queries for doubleclick.net currently return public addresses, so household-wide ad blocking is **not guaranteed**. Direct queries to .210 remain filtered.

This availability-first policy supersedes the earlier Pi-hole-only router setup. A configuration with Pi-hole first and public alternatives second/third produced several 4-second DNS timeouts and slow browsing during baseline testing. It was not accepted. Public resolvers first passed the tests below. Devices deliberately configured to use only .210 would still lose DNS if it fails; provide those devices independent alternatives or leave them on automatic router DNS.

No usable IPv6 DNS/default route was advertised to the tested desktop; dns01 only has link-local IPv6. No IPv6 feature was disabled. Recheck DHCPv6/RDNSS if this changes. Custom VPN/encrypted/application DNS was not audited device by device.

## Actual outage verification

The coordinator armed a 120-second recovery timer on pve01 before cleanly shutting down only CT100. It was confirmed stopped both before and after the client probes. Using the desktop's configured router DNS, with no public-server override:

- A unique uncached name under example.com returned a valid negative DNS response in 11 ms (NOERROR/NODATA, zero answers, one authority record).
- Positive DNS lookups for www.freebsd.org, www.python.org and www.mozilla.org succeeded in 45, 8 and 12 ms; these differed from baseline probe domains.
- Fresh curl processes without proxies returned HTTPS200 for Debian in 288 ms and IANA in 101 ms.
- Six baseline checks and six outage checks passed. The container was restored, its FTL service became active, and the recovery timer was canceled. An independent agent verified the result files, running guest/service and absence of leftover timers/units.
- After restoration, direct Pi-hole lookups blocked doubleclick.net and resolved debian.org. Login HTTP200, authenticated API access and anonymous statistics denial passed.

The outage test removed the only homelab DNS service entirely. Neither physical host was powered off. pve02 hosts no required household DNS component; its Docker applications/monitoring are separate from router internet access. This does not protect against router, ISP, power or public-resolver failure. It establishes continued DNS/browsing during the tested Pi-hole outage, not a universal uptime guarantee.

## Filtering, maintenance and recovery

The [StevenBlack list](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts) has 76,737 loaded domains. Pi-hole blocks direct test queries and has FTL/cron enabled; weekly gravity is scheduled Sunday 04:26 guest-local time. First scheduled execution has not yet been observed. The guest starts automatically. DNS filtering cannot block every advertisement.

For an entirely homelab-independent router configuration, set DNS3 to 0.0.0.0 while retaining DNS1/2 as the public resolvers. To restore the router's original automatic ISP configuration, set all three DNS fields to 0.0.0.0 and Apply. Keep the address reservation. Do not revert to Pi-hole-only household DNS: that violates the user's availability requirement.

If DNS is unavailable, access Proxmox by IP 192.168.1.2 and the router by IP 192.168.1.1. Off-node backup/restore testing and the apps01 .58 reservation remain separate work. Passwords/keys belong outside Git. See [deployment](deployment.md) and [services](services.md).