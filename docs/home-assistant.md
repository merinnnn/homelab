# Home Assistant OS

The dedicated Home Assistant OS VM is allocated on pve01 as VM102, name ha01, MAC BC:24:11:32:8F:61,2CPU/4GiB/32GiB local-lvm. Never treat permanent VM102 as a disposable test guest. Keep apps01/Pi-holes and the accepted AdGuard-first household DNS unchanged.

The reviewed official KVM image is HAOS18.4:18.5 is a RaspberryPi-only release. Exact GitHub asset size/SHA256 are embedded in the installer and checked before Proxmox mutation. UEFI/q35/virtio SCSI, no enrolled secure-boot keys, guest agent and onboot are configured. Fresh creation is allowed ONLY on vmbr1 for private first boot and owner claim. The installer creates the VM stopped and never starts, resets or replaces existing disks on repeat. Unknown IDs, missing/partial ownership state and disk/configuration drift are refused; retain partial resources for explicit inspection.

Run from the actual pve01 checkout:

```bash
cd /root/homelab
python3 scripts/provision/home-assistant-vm.py install 102 BC:24:11:32:8F:61 --bridge vmbr1
qm start 102
```

Do not publish the VM or proxy before private owner initialization. Owner credentials and tokens belong in root-only /etc/homelab/home-assistant outside Git. Initial address is read from the owned guest agent, not guessed. Home Assistant2026.11.1 uses HTTP80 on HAOS; Container retains8123. Configuration API contracts require reviewing the observed Core version. HTTP reverse-proxy settings are now managed via UI/WebSocket with a timed confirmation, rather than deprecated YAML.

Before LAN promotion, reserve an unused static address on the router for this MAC, prepare guest static networking, and verify the root0600 successful bootstrap marker. Then:

```bash
python3 scripts/provision/home-assistant-vm.py promote-lan 102 BC:24:11:32:8F:61
# Later read-only installed ownership/configuration verification:
python3 scripts/provision/home-assistant-vm.py install 102 BC:24:11:32:8F:61 --bridge vmbr0
```

Planned friendly address https://ha.home.arpa/ through existing Caddy. Do not assume proposed192.168.1.211 is free/reserved until live router verification. Installation is not complete until owner auth, HTTPS/WebSocket, addressing, persistence and backups are verified. Dated live results and explicit NOT RUN limits belong in setup-status and the external Knowledge vault.
