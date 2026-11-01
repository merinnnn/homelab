# Node monitoring

Prometheus collects CPU, available memory, filesystem space and selected management-service states from both Proxmox hosts every30seconds. Grafana at https://grafana.home.arpa/ provides the provisioned Homelab nodes dashboard and firing-alert count. Its login is required; signup/anonymous access are disabled. Prometheus and Alertmanager remain internal Docker services without published ports or proxy routes. All three run on permanent apps01 alongside existing services, with bounded memory/log/metric retention and persistent named data volumes.

Deploy from the installed /root/homelab checkout on each owning node. First install the topology-gated Debian node exporter, then run on pve02:

```bash
bash scripts/deploy/proxmox-monitoring.sh 100
bash scripts/deploy/proxmox-homepage.sh 100
bash scripts/deploy/proxmox-reverse-proxy.sh 100 home.arpa /etc/homelab/proxy-trust
```

Apply configs/local-services.json to both Pi-holes. The existing suffix-scoped Windows DNS rule and public-root trust cover the added Grafana name; other clients still need their own local DNS/trust configuration. Household AdGuard-first DNS is unchanged.

Grafana admin username is admin. Its generated initial password stays in the VM's root-only /etc/homelab/monitoring/grafana-admin-password. The database retains account/password changes on repeats. Never print this file or put its value in Git/notes; retrieve via the private credential workflow. Canonical notification settings stay root-only at /etc/homelab/monitoring/alertmanager.yml. The checked-in default intentionally has a null receiver: external notifications are pending a selected channel, credentials and an observed delivery/resolution test. No delivery is claimed for this default. Re-run the helper after editing the private canonical file to validate and activate it without putting tokens/URLs into logs or release manifests.

Rules: exporter unreachable2minutes; CPU above90%10minutes; available RAM below10%10minutes; writable real filesystem available below15%10minutes (critical below5%); selected Proxmox management unit failed5minutes. Warning disk alerts are inhibited by critical ones for the same instance/mountpoint. Group wait30seconds, repeat4hours. Delays avoid momentary-spike notifications. Prometheus retains at most15days/3GB. These filesystem metrics do not establish LVM-thin pool, SMART or storage hardware health; guest disk usage and backups need separate monitoring.

Node exporters listen only on each host's LAN address port9100, with selected systemd collection enabled; the service exposes host metrics to the trusted LAN, without authentication. This setup does not change host firewalls. Existing management access/services remain. Unknown exporter installations or changed managed files require review and are preserved.

The monitoring stack depends on pve02/apps01 and household power/internet. It can observe pve01 failure while pve02 remains available; it cannot deliver its own outage when pve02, apps01 or both nodes are off. An independent outside watcher is required for that failure domain. No always-on extra device/router replacement is available, per the user. Existing Kuma uptime checks remain separate and share the same VM dependency.

Validation: scripts/tests/monitoring-offline.sh; native image promtool config/rule tests; amtool private config validation; actual scrape samples, Grafana authenticated dashboard/API and anonymous denial; bounded exporter outage firing/resolution; repeat and VM restart persistence. Native tests execute before activation; failed applies restore previous releases without deleting data. Detailed dated PASS/FAIL/NOT RUN evidence is kept in the project Obsidian vault. The owner chooses any external notification channel; no tokens belong in source or notes.

Exporter command on each owning node: bash scripts/provision/install-node-exporter.sh. Verify with --verify; repeats preserve the managed service and refuse unknown installations.

## Telegram

Prepare a root-owned mode600 JSON outside Git containing bot_token and optional positive private chat_id. If chat_id is absent, send /start privately to your bot; setup requires exactly one private chat. Run on pve02:

```bash
bash scripts/deploy/proxmox-telegram.sh 100 /etc/homelab/telegram.json
bash scripts/deploy/proxmox-monitoring.sh 100
```

The helper verifies Telegram bot/private chat, preserves unknown configurations, saves a private previous configuration and validates the candidate with the installed pinned amtool before activation. Credentials cross QGA stdin only and never enter archive payloads, command arguments or output. Canonical private Alertmanager settings contain the receiver token and selected chat ID; the desktop/node private input files hold the token. Repeated setup preserves the same receiver. Real firing/recovery delivery still requires an observed test; setup success alone is not delivery evidence. Grafana suggested plugin preinstallation/automatic updates are disabled; the provisioned node dashboard uses bundled features.
