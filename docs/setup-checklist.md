# oryx — Master Setup Checklist

Everything in order, start to finish.
Detailed commands for every step are in [`docs/setup.md`](setup.md).

---

## External HDD prep

- [x] Clean up the Seagate drive
- [x] Back up any content from it to the external Seagate
- [x] Format 1 TB HDD — done via Windows Disk Management (exFAT) · will reformat as ext4 during server setup

---

## G7 — Prep

- [x] Back up important data from the 1 TB SATA SSD (it's moving to the Optiplex)
- [x] Download Windows ISO
- [x] Create bootable Windows USB (Rufus or Media Creation Tool)

---

## G7 — Swap drives

- [x] Power down the Dell G7
- [x] Open laptop, remove the 1 TB SATA SSD → set aside for Optiplex
- [x] Install the 1 TB SATA HDD in the G7's SATA slot
- [x] Close laptop

---

## G7 — Install Windows on NVMe

- [x] Boot G7 from Windows USB
- [x] At drive selection, delete all existing partitions on the 256 GB NVMe (Fedora)
- [x] Install Windows to the unallocated space
- [x] Verify Windows boots cleanly from NVMe
- [x] Open Disk Management → format the 1 TB HDD as NTFS (D: drive)

---

## Optiplex — Hardware prep

- [x] Install the 1 TB SATA SSD into the Optiplex internal 2.5" bay
- [x] Connect ethernet cable to router
- [x] Flash Ubuntu 26.04 LTS Server ISO to a USB drive
- [x] Verified both drives show in BIOS (SATA-0: 1 TB, SATA-4: 256 GB M.2 SATA)

---

## Optiplex — OS install

- [x] Boot from USB (F12 at POST for boot menu)
- [x] Select Ubuntu Server (minimised)
- [x] Install target: 256 GB M.2 SATA (SATA-4) — do NOT select the 1 TB
- [x] Username: `aritra`, enable OpenSSH during install
- [x] Complete install, reboot, remove USB

---

## Optiplex — Initial system setup

- [x] SSH in from laptop, copy SSH public key
- [x] Disable password auth in SSH config
- [x] Verify key-only login works before proceeding
- [x] Enable UFW — allow SSH, deny everything else
- [x] Enable automatic security updates
- [x] Set static LAN IP (`192.168.2.100`) via Netplan
- [x] Reserve IP — static IP set via Netplan + Speedport DHCP reservation

---

## Optiplex — Storage

- [x] Identify SATA SSD device name (`lsblk`)
- [x] Format 1 TB SATA SSD as ext4, mount at `/mnt/ssd`, add to `/etc/fstab` with `nofail`
- [x] Create all `/opt/` and `/mnt/ssd/` service directories

---

## Docker

- [x] Install Docker
- [x] Add `aritra` to docker group, log out and back in
- [x] Configure Docker data-root → NVMe (`/opt/docker`)
- [x] Create shared Docker network (`server-net`)
- [x] Clone oryx repo to `~/oryx`
- [x] Create `~/stacks/{infra,media,productivity,monitoring,dev}`

---

## Tailscale

- [x] Install Tailscale
- [x] `tailscale up --ssh`, authorize via URL
- [x] Note Tailscale IP (`100.106.157.117`), SSH works over Tailscale
- [ ] Set node key to never expire in Tailscale admin console

---

## Infrastructure stack

- [x] Fill in `~/stacks/infra/.env`
- [x] Create `docker-compose.yml` for infra stack
- [x] Create `config/glance.yml`
- [x] Start Pi-hole, Glance, Watchtower, Portainer, cloudflared
- [x] Pi-hole DHCP enabled (Speedport workaround for DNS)
- [x] Verify Pi-hole admin loads (`100.106.157.117:8053`)
- [x] Verify Glance loads (`https://home.aritra.fyi`)
- [x] Verify Portainer loads (`100.106.157.117:9000`), create admin account
- [ ] Confirm ad-blocking works from a home device

---

## Cloudflare Tunnel

- [x] Install cloudflared, login, create `oryx` tunnel
- [x] Create DNS routes for all subdomains (`home`, `notes`, `drive`, `photos`, `grafana`)
- [x] Configure ingress rules via Cloudflare dashboard
- [x] Start cloudflared, connections verified

**Cloudflare Access:**
- [x] `home`, `grafana` — protected by CF Access (email OTP)
- [x] `notes`, `drive`, `photos` — own auth, CF Access removed
- [x] Verified CF Access login works from mobile data

---

## Media stack (Immich)

- [x] Fill in `~/stacks/media/.env`
- [x] Start media stack
- [x] Verify Immich loads (`https://photos.aritra.fyi`)
- [x] Android app connected

---

## Productivity stack

- [x] Fill in `~/stacks/productivity/.env`
- [x] Start productivity stack
- [x] Verify AFFiNE loads (`https://notes.aritra.fyi`)
- [x] Verify Nextcloud loads (`https://drive.aritra.fyi`)
- [x] Android apps connected

---

## Monitoring stack

- [x] `prometheus.yml` + `blackbox.yml` configured
- [x] Fill in `~/stacks/monitoring/.env`
- [x] Start monitoring stack (Prometheus, Node Exporter, cAdvisor, Blackbox, Grafana)
- [x] Add Prometheus data source in Grafana
- [x] Import Node Exporter dashboard (ID: 1860)
- [x] Import cAdvisor dashboard (ID: 14282)
- [x] Import Blackbox Exporter dashboard (ID: 7587)
- [ ] Set node key to never expire in Tailscale admin console
- [ ] Add Discord webhook contact point, send test
- [ ] Create CPU alert (> 85% for 5 min)
- [ ] Create RAM alert (> 88% for 5 min)
- [ ] Create disk full alert (> 82%)
- [ ] Create container down alert

---

## Backup

- [ ] Install rclone, configure Google Drive remote
- [ ] Test rclone sync, verify files appear in Drive
- [ ] Make backup scripts executable (`~/oryx/backup/*.sh`)
- [ ] Create backup mount point (`/mnt/backup`)
- [ ] Set up weekly rclone systemd timer

---

## Final checks

- [ ] All containers running, none in `Exited` state
- [ ] All public subdomains load correctly
- [ ] SSH via Tailscale works from outside home network
- [ ] Pi-hole blocking ads on home network
- [ ] Grafana shows live CPU/RAM/disk metrics
- [ ] Discord test alert fires and is received
- [ ] Grafana Blackbox dashboard shows all services green
- [ ] Plug in external drive, run `check-mount.sh`, confirm backup scripts work

---

## Secrets — store in Bitwarden

- [ ] Pi-hole web password
- [ ] Cloudflare Tunnel token
- [ ] Immich DB password
- [ ] Nextcloud admin password
- [ ] AFFiNE admin password
- [ ] Shared PostgreSQL password
- [ ] Grafana admin password
- [ ] Discord webhook URL
