# Filtered household DNS resilience — 1 November 2026

The user approved an ad-blocking public DNS alternative so browsing and DNS ad blocking can continue even when both Proxmox nodes remain off after household power is restored. No additional device, router replacement or firmware change was used.

## Current router configuration

Linksys MX5700 Series, firmware 1.0.2.216808, 192.168.1.1 > Connectivity > Local Network:

| Field | Address | Role |
| --- | --- | --- |
| Static DNS1 | 94.140.14.14 | AdGuard public DNS, default ads/trackers filtering |
| Static DNS2 | 192.168.1.210 | pve01 CT100 dns01, Pi-hole |
| Static DNS3 | 192.168.1.150 | pve02 CT101 dns02, Pi-hole |

AdGuard is the public filtered primary in this ordering. It may answer while both Pi-holes are healthy and uses its own blocklist; local custom Pi-hole rules do not automatically apply there. Router DNS slots do not establish strict health-based primary/backup selection. The user accepted this compromise after Pi-hole-only and local-first tests timed out. Do not describe this as exclusive Pi-hole-first filtering with conditional public fallback.

All three configured DNS choices filter ads. The [AdGuard default public service](https://adguard-dns.io/en/public-dns.html) blocks ads and trackers. DNS filtering cannot remove every ad, including ads sharing domains with desired content. Applications using their own VPN/encrypted DNS can bypass router DNS; household devices were not audited individually.

Router DHCP remains enabled, pool 192.168.1.10–192.168.1.254, lease 1440 minutes. Saved reservations are dns01 .210 / BC:24:11:42:2A:6F and dns02 .150 / BC:24:11:6F:74:55. The desktop uses router .1 for DNS. No usable IPv6 DNS/default route was advertised to that desktop; IPv6 was not disabled. Recheck DHCPv6/RDNSS if IPv6 connectivity changes.

## Pi-hole instances

| Instance | Guest | Admin page | DNS |
| --- | --- | --- | --- |
| dns01 | pve01 CT100 | http://192.168.1.210/admin/ | .210 TCP/UDP53 |
| dns02 | pve02 CT101 | http://192.168.1.150/admin/ | .150 TCP/UDP53 |

Both are permanent unprivileged Debian 13 LXCs with nesting enabled, 1 vCPU, 512 MiB RAM and 8 GiB disks. Both have onboot enabled, startup order10/up20/down30. Both run Core v6.5, Web v6.6.1 and FTL v6.8 with 76,737 loaded gravity domains from the [StevenBlack hosts list](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts). FTL and cron are enabled; Pi-hole DHCP/NTP are disabled. Weekly gravity is scheduled; its first scheduled execution has not been observed. Lists are not automatically synchronized between instances.

Pi-hole upstreams remain independent 1.1.1.1/1.0.0.1. Never point them back to router .1, which would create a loop. Root-only account files live outside Git at /etc/homelab/pihole-password on each node. The second installation reuses the existing private account credential. Login, authenticated statistics and anonymous statistics denial were checked; secrets were not copied into source or reports.

## Actual outage verification

Using the desktop's configured router DNS with no resolver override, ten baseline checks and ten checks with BOTH CT100 on pve01 and CT101 on pve02 stopped passed:

- A unique uncached name returned a valid negative response in 12 ms during the outage.
- Three fresh positive domain lookups succeeded in 6–147 ms.
- A fresh doubleclick.net subdomain returned blocked A/AAAA answers 0.0.0.0/::, including TCP DNS. Normal TCP DNS also succeeded.
- Normal TLS requests returned IANA robots.txt HTTP200 in 118 ms and Google generate_204 HTTP204 in 50 ms; curl exited0 with complete transfers.
- Both guests were confirmed stopped before AND after the probes. Independent 240-second recovery timers were armed on both hosts before shutdown. Both guests were then restored with direct blocking verified, and both recovery guards were cleared. The harness exited0.

Evidence is saved in the external project workspace under deployment/pihole/dns-filtered-both-baseline.json and dns-filtered-both-unavailable.json, with Test-FilteredDnsAvailability.ps1. These live results are separate from source mocks. The test removed both local DNS services while the router continued filtering through AdGuard. It did not power off either host or cold-boot the router; physical power restoration and ISP/router/public-resolver failures were NOT RUN. Saved router configuration makes DNS independent of node startup, but cold-boot behavior has not been verified.

Retained failures explain the chosen setup: Pi-hole-only and local-first ordering each timed out on the first uncached outage query (~4 seconds). An earlier AdGuard-first test passed eight DNS checks, then a full Debian homepage transfer timed out at 12 seconds despite HTTP200; that full-page suite remains FAIL. A Debian HEAD request also timed out after both Pi-holes were restored, but the cause was not proven. The final smaller HTTPS probes establish DNS/HTTPS availability for the tested endpoints, not that every website transfer succeeds.

## Maintenance and recovery

Deploy from /root/homelab on the appropriate node; see [deployment commands](deployment.md). An inherited restrictive umask created dns02 /etc as mode0700, preventing the installer’s _apt user from reading DNS configuration. Repairing that guest directory to0755 allowed installation; the creation helper now explicitly uses umask022, with a regression case. Private runtime files remain mode600.

If DNS fails, reach the router by IP192.168.1.1 or Proxmox by IP192.168.1.2/.3. To temporarily remove local resolvers while preserving public filtering, replace DNS2 with AdGuard’s other default address94.140.15.15 and DNS3 with0.0.0.0, retaining DNS1. To restore original ISP automatic DNS, set all fields to0.0.0.0 and Apply; this relinquishes the configured filtering policy. Keep reservations. Do not restore Pi-hole-only household DNS without a design that survives both nodes being off.

Off-node backups, restore testing and the apps01 .58 reservation remain separate work. See [running services](services.md). No host reboot, router replacement or firmware flashing was performed.
