# Pi-hole network setup — 1 November 2026

Pi-hole runs natively in pve01 CT100 dns01. Administration: http://192.168.1.210/admin/. DNS: 192.168.1.210, TCP/UDP53. Keep this permanent guest running.

## Router settings

Linksys Smart Wi-Fi router: 192.168.1.1. Connectivity > Local Network:

- DHCP remains enabled on the router, pool 192.168.1.10–192.168.1.254, lease 1440 minutes. Pi-hole DHCP remains disabled.
- Reservation: dns01, 192.168.1.210, MAC BC:24:11:42:2A:6F. It was saved, reopened and verified. The guest retained .210 with a fresh DHCP lease after reboot.
- Static DNS1: 192.168.1.210. Static DNS2 and DNS3 remain unset (0.0.0.0); no public alternate DNS was added.
- Clients may continue receiving 192.168.1.1 as DNS. This router forwards their queries to Pi-hole; this was verified with default desktop lookups and matching Pi-hole query logs from .1 after the guest reboot.
- Pi-hole upstreams remain 1.1.1.1 and 1.0.0.1. Do not point them back to the router: that would create a forwarding loop.

The Windows WiFi lease was renewed and its DNS cache cleared. Ordinary DNS lookups blocked doubleclick.net and googleadservices.com (A0.0.0.0, AAAA::), while debian.org resolved normally. Internet HTTPS returned 200. Other devices using router DNS are covered through the same forwarding path; devices with custom/encrypted DNS or VPN DNS can bypass it and were not individually audited.

No IPv6 DNS server or default IPv6 gateway was advertised to the tested desktop; dns01 had only link-local IPv6. No IPv6 feature was disabled. Recheck DHCPv6/RDNSS if the ISP/router later enables usable IPv6 connectivity.

## Blocking and maintenance

Enabled list: [StevenBlack hosts](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts). A successful gravity refresh loaded 76,737 unique blocked domains. The list is enabled for the default group. It blocks many advertising/tracking domains, not every advertisement; DNS cannot reliably distinguish ads and content sharing a domain.

FTL and cron are active/enabled. The installed weekly gravity job is Sunday04:26 in the guest's timezone; manual refresh passed, but a scheduled run has not yet been observed. CT onboot is enabled. Post-change reboot recovered DNS, web login, authentication and the reserved address. Authenticated API statistics passed; anonymous statistics requests were denied.

## Recovery and rollback

Access pve01 by its management IP, 192.168.1.2, if DNS is unavailable. Pi-hole is a single resolver and therefore a dependency for household DNS; router fallback behavior during a Pi-hole outage has not been established.

To undo the router DNS change, open 192.168.1.1 > Connectivity > Local Network and restore Static DNS1 to 0.0.0.0; DNS2/3 were already 0.0.0.0. Apply, then clear affected client DNS caches and renew leases if required. This restores the previous automatic router DNS configuration. Keep the reservation unless the guest is deliberately retired.

Before replacing or deleting dns01, migrate DNS to a functioning resolver first. Off-node backup and restore testing remain outstanding. The apps01 .58 lease still needs its own reservation.

Passwords and router credentials belong outside Git. Use the external credential store for Pi-hole; do not place secret values in this document or scripts. See [deployment](deployment.md) and [services](services.md).