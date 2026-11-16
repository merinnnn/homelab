# Jellyfin on pve01

Jellyfin 12.4 runs in unprivileged Debian 13 CT103, jellyfin01, on pve01. Open https://jellyfin.home.arpa/ or use its Homarr card. The direct LAN fallback is http://192.168.1.9:8096/ (unencrypted). The static address is outside the router DHCP pool (.10 through .254); no router setting or accepted household DNS policy changed. The Caddy route retains the existing private CA and depends on apps01 on pve02. Both Pi-holes carry the friendly and direct infrastructure names. Other clients need local DNS and trust for the existing public CA when using HTTPS.

The owner is admin. The login is in the existing private desktop service store under jellyfin and inside the CT at /etc/homelab/jellyfin/owner.json (root only). Keep credentials and raw authenticated output out of the repository and knowledge vault. The setup wizard was closed before LAN exposure. Remote access is disabled; Jellyfin trusts forwarded IPs only from Caddy at 192.168.1.58. No WAN forwarding was added.

## Media and permissions

The Samsung T7 (1 TB, exFAT, UUID 2627-3DAE) is connected directly to pve01 at USB 5 Gbps. The only new paths on the SSD are Jellyfin/Movies, Jellyfin/TV Shows and Jellyfin/Music. Preexisting directories were not migrated or exposed. Copy media into those new folders. Jellyfin has read-only access to only the Jellyfin subtree, mounted as /srv/media in the CT. The database, metadata and transcode cache live on the internal CT disk (24 GiB at creation), not on the USB drive. No drive formatting occurred.

The UUID mount uses a synthetic exFAT GID matching the container's media group, plus ro/nosuid/nodev/noexec. An instance drop-in binds only CT103 to that mount. It refuses to start without the correct read-only mount or the intended source folder. There is no independent replica of the SSD; host or container backups do not include its read-only bind mount contents.

For the simplest media import, coordinate a safe disconnect: shut down only CT103 with pct shutdown 103 on pve01 and stop the precise mount unit (shown below). Once findmnt confirms it is no longer mounted, move the SSD to a computer to copy files into the chosen folders and safely eject it there. Reconnect the drive to pve01 and run pct start 103; the mount is a startup dependency. Use Jellyfin Dashboard > Scan All Libraries after adding files. The media library does not currently expose a writable network share.

~~~sh
pct shutdown 103 --timeout 45
systemctl stop "$(systemd-escape --path --suffix=mount /mnt/homelab-jellyfin)"
findmnt --mountpoint /mnt/homelab-jellyfin
# Only unplug if findmnt reports no such mount.
# After reconnecting to pve01:
pct start 103
cd /root/homelab
bash scripts/deploy/proxmox-jellyfin.sh verify
~~~

## Deployment and recovery

CT103 uses 2 vCPUs, 1536 MiB RAM and 24 GiB internal storage, onboot order 30. The setup helper runs only from /root/homelab on pve01. The first install creates a stopped/then private-bridge guest, verifies the official Jellyfin signing key, installs pinned Debian 13 packages and claims a random administrator credential before LAN promotion. The attach action creates only the approved directory tree; it refuses to overwrite a preexisting Jellyfin folder. The root-owned deployment marker and CT hostname, MAC, storage and tag guard against acting on another CT. Never rerun install or attach against existing resources as a diagnostic. Verify or recover the owned resource instead; preserve partial state if a step fails.

Only Intel HD 530 render device /dev/dri/renderD128 is passed to the CT. H.264 8-bit VA-API was enabled after verifying decode/encode availability as the Jellyfin user and an actual 640x360 to 320x180 playback transcode with h264_vaapi. Do not assume 4K HEVC 10-bit/HDR or AV1 hardware transcoding on this node. Direct play may still work for supported client codecs. Server restart and missing-mount recovery are recorded in the dated Obsidian report. Actual television/mobile playback, USB removal during playback, and physical blackout recovery were not tested. No automated Jellyfin config backup or off-node media backup was added.
