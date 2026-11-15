# Latest setup — 15 November 2026

n8n2.47.7 is installed at https://n8n.home.arpa/ on apps01 with PostgreSQL17.12 and matching external runners. Protected owner setup, actual JavaScript42 workflow, container recreation persistence, daily backup/recovery, initial private off-node copy, isolated synthetic encrypted restore and43 independent live checks passed. All10 friendly HTTPS pages and15 Pi-hole records passed. Homarr now has8 cards. apps01 was raised to4GiB with a guarded graceful guest restart; no physical node/router reboot or household DNS-policy change occurred.10 healthy containers,10 active volumes plus1 retained PostgreSQL16 volume; original CA/accounts/data retained. See [n8n](n8n.md), [services](services.md) and the external Knowledge15November report for source hashes, retained failures and scope.

No SMTP recovery, WAN webhook ingress, n8n HA, recurring off-node transfer or backup retention was configured. Production-backup restore, real external integrations/credentials, arbitrary workload capacity, visual browser rendering and physical power recovery remain NOT RUN. Synthetic restore used no production data and all exact-owned disposable resources were cleaned. Prior Telegram delivery and node-exporter behavior were not retested for this n8n extension. Credentials remain private outside Git/vault.

---

# Historical setup status — 1 November 2026


Current extension: Vaultwarden, Homarr and node usage monitoring are installed. Telegram firing/recovery notifications, real two-node metrics, private authentication, isolated encrypted-vault restore, daily backup, initial off-node backup copy and 3 GiB apps01 VM restart persistence passed. See services.md, monitoring.md and vault-and-homepage.md. Owner master-password registration remains a private user step; recurring off-node backup transfer and monitoring its own pve02 failure need separate work.

This records the earlier prepared-node validation. Pi-hole and Docker/Uptime Kuma have since been deployed and verified; see [running services](services.md) for current resources, endpoints and deployment checks. Earlier empty inventories refer to the pre-deployment baseline.

## Observed nodes and source

- pve01: `192.168.1.2`; pve02: `192.168.1.3`.
- Both: Proxmox VE 9.2.20, kernel 7.0.14-19-pve; active `local` and `local-lvm`; dnsmasq/nftables active; IPv4 forwarding enabled, IPv6 forwarding disabled.
- Management uses `vmbr0`, `192.168.1.0/24`. Each host separately provides `vmbr1`, `10.0.10.1/24`, with DHCP/DNS/NAT. These are separate host-local networks.
- The initial inventory on both nodes had no VMs/containers. Existing remote `/root/homelab` working trees differ and were preserved. The Windows repository began at `6acd23c` with an uncommitted provisioning change; the corrections build on that change.

## Completed validation

- Fresh Debian VM creation and boot on both nodes: dynamically allocated VM 100, 2 GiB RAM, 8 GiB disk, expected cloud-init user and isolated bridge.
- Fresh unprivileged Debian LXC creation and boot on both nodes: CT 101, 512 MiB RAM, 4 GiB root disk.
- Guest DHCP, default route, gateway/internet ICMP and DNS passed on both nodes. VM root filesystems grew to approximately 7.7 GiB.
- Initial noninteractive VM provisioning failed on unknown SSH host keys. The correction uses first-contact `accept-new` with a stable VMID/MAC host alias, keeps host verification, and avoids deleting unrelated known-host entries.
- Corrected provisioning and repeat provisioning succeeded on both VMs. QEMU guest-agent host pings succeeded, including after guest reboot. Debian's static agent unit is started and checked rather than incorrectly treated as enableable.
- Packet capture proved the old forward policy delivered home-LAN packets to a lab guest despite sender ping timeouts. Corrected scoped project rules were applied on both nodes; post-change captures on both lab bridges received zero probe packets.
- After the firewall correction and persistent reload, both VMs retained gateway/DNS/internet connectivity and HTTPS to `deb.debian.org` returned 200. TCP attempts to gateway SSH, pve01 web management and pve02 SSH timed out as intended.
- Scoped rule application preserved an unrelated sentinel nftables table. Persistent configurations passed the live nft parser and loaded successfully. The legacy top-level file was replaced only after an exact comparison to the original project-generated configuration; backups were retained.
- Offline candidates pass 42 behavior scenarios. Additional focused health/bootstrap and firewall harnesses passed 24 and 26 checks respectively. Tests include real invalid-shell fixtures to verify CI failure propagation. These counts describe separate suites, not a count of unique live tests.

## Corrected source behavior

- Reject invalid provisioning arguments and expired DHCP leases.
- Support noninteractive SSH first contact with guest-specific host identity; verify agent service activity.
- Aggregate failed health probes into a nonzero exit, require a nonempty DNS answer, bound network waits, and support actual target overrides.
- Propagate validation/input errors in CI using explicit Bash/pipefail and run the offline regression harness.
- Correct two bootstrap status/reporting bugs without executing those mutating bootstrap scripts on the live nodes.
- Replace only project-owned nftables tables; deny new routed traffic into the lab and protect the configured home prefix from lab traffic. Full network bootstrap still requires reviewed boot integration; see [firewall notes](firewall.md).

## Limits and next setup work

- Cloud-init completed with no fatal errors but returned status 2 for an upstream generated scalar `user` deprecation warning (removal scheduled for cloud-init 27.2). This warning is recorded, not suppressed or represented as a clean status 0.
- Host reboot, IPv6 routing/isolation, backup restore, storage failure, throughput and hardware stress were not tested. Guest reboot is separate from host reboot. Persistent rules were syntax-checked and loaded, not verified through host restart.
- Only the configured home prefix is protected against lab egress; additional VPN/private networks require an explicit policy. Same-bridge guest traffic and host-originated traffic are outside this routed isolation boundary.
- Pi-hole, Docker and Uptime Kuma are deployed and verified as described in [running services](services.md). Pi-hole router reservation and household DNS forwarding are completed; see [Pi-hole network setup](pihole.md). Portainer remains undeployed.
- Full post-install, storage and network bootstrap were reviewed/mocked rather than rerun on prepared nodes. Image preparation's current three-column catalogue path was mocked; existing prepared images were used for live creation.
- Guest creation can leave a partial resource if a later import/configuration step fails. Inspect ownership and volumes before retrying or removing it.

The local Obsidian vault contains dated command evidence, resource cleanup/final inventory, and the next handoff: `C:\Users\merin\Documents\ChatGPT\Homelab\Knowledge`, starting at `00 Start Here.md`. The portable offline suite runs with `node scripts/tests/offline-behavior.cjs` (Bash required; `BASH` can override its path).
