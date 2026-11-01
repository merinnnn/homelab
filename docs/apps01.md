# Docker and Uptime Kuma on apps01

Run these payloads as root **inside the Debian 13 guest**, after reviewing the allocated guest identity. They install Docker from its signed official Debian repository. They are not Proxmox host bootstrap scripts. Permanent apps01 is VM100 on pve02 with2 CPU cores,3 GiB RAM and32 GiB disk. It uses static/reserved 192.168.1.58/24 on vmbr0, gateway 192.168.1.1. Vaultwarden, Homarr and node monitoring now share this VM; see services.md and monitoring.md. The former DHCP/static-address planning statements are historical.

## Install and start privately

Copy both shell payloads and the Compose template into the guest, then run:

```bash
bash install-docker-debian.sh
bash uptime-kuma.sh /tmp/docker-compose.yml
```

The installer waits at most 600 seconds for cloud-init; set `CLOUD_INIT_TIMEOUT` to another positive number if needed. Fatal cloud-init errors and readiness timeouts stop installation. A completed run with only the known nonfatal upstream warning is reported separately. Existing conflicting Docker/container runtimes are not uninstalled automatically.

The Compose stack starts bound to `127.0.0.1:3001`. It pulls the exact official release `2.5.8`, records its resolved digest in `/opt/homelab/uptime-kuma/.env`, and retains that digest on repeat runs. Explicit `KUMA_IMAGE` can select a reviewed exact stable v2 release or official-repository digest. Local named volume `homelab-uptime-kuma-data` holds the database; do not remove it when recreating containers. Database type is explicitly SQLite so a new deployment reaches account setup without a separate database-setup wizard. The built-in image healthcheck is `/app/extra/healthcheck`.

The pull has a 1200-second bound (`IMAGE_PULL_TIMEOUT` override). Compose waits up to 300 seconds for healthy state. Failure does not delete the persistent volume. No Docker socket is mounted and Portainer is not deployed.

## Initialize the account and monitors

The helper uses the inspected **2.5.8** Socket.IO contract, not a stable public provisioning API. Revalidate it before upgrading the application. Run it in the pinned container so its installed client dependency is available:

```bash
stack=/opt/homelab/uptime-kuma
cid="$(docker compose --project-name homelab-monitoring --env-file "$stack/.env" -f "$stack/compose.yml" ps -q uptime-kuma)"
docker cp setup-uptime-kuma.cjs "$cid:/tmp/setup.cjs"
# Feed a private JSON file with top-level username, password, optional dnsHost.
# Keep that file and all credential values outside this repository and notes.
docker exec -i "$cid" node /tmp/setup.cjs < /root/.config/homelab/kuma-input.json
```

The coordinator generates/stores credentials separately and transforms them into the helper's stdin schema without printing them. Do not place passwords on command lines or put real credential examples in documentation. On an empty instance the helper creates the account, then logs in; on repeats it verifies the existing credentials. It reports only account action and monitor counts. It never outputs the authentication token or monitor configuration.

It creates HTTP availability monitors for `https://192.168.1.2:8006/` and `https://192.168.1.3:8006/`, accepting 2xx status. TLS verification is disabled **only in those two monitor definitions** because the local PVE servers use self-signed certificates. These checks establish web availability, not authenticated API correctness. Optional `dnsHost` creates a Pi-hole `example.com` A-record monitor using the observed DNS guest address and port 53. Existing same-name/same-target monitors are retained; a conflicting target requires review rather than silent replacement.

After account initialization, publish on the recorded guest LAN address:

```bash
KUMA_BIND_IP=<observed-apps01-IPv4> bash uptime-kuma.sh /tmp/docker-compose.yml
```

The saved image digest, volume and bind address are retained by later runs. `KUMA_PORT` defaults to 3001. Account setup must precede LAN exposure. No router DNS changes or internet port forwarding are part of this deployment.

## Verification

Run `node scripts/tests/apps-deployment.cjs` for mock failure-path and Socket.IO-contract checks. The existing `offline-behavior.cjs` remains a separate regression suite. CI runs both.

Live acceptance must separately record image version/digest, Docker service state, container health, account login, expected monitor heartbeat results, data persistence through container recreation and guest reboot, and the actual LAN endpoint. Preserve failures and untested behavior in the project vault.

Official sources checked on 1 November 2026:

- [Docker Engine for Debian](https://docs.docker.com/engine/install/debian/)
- [Uptime Kuma 2.5.8 release](https://github.com/louislam/uptime-kuma/releases/tag/2.5.8)
- [Pinned image Dockerfile](https://github.com/louislam/uptime-kuma/blob/2.5.8/docker/dockerfile)
- [Pinned Socket.IO handlers](https://github.com/louislam/uptime-kuma/blob/2.5.8/server/server.js)
- [Pinned database setup](https://github.com/louislam/uptime-kuma/blob/2.5.8/server/setup-database.js)
