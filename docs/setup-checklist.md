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
- [x] Open Disk Management → format the 1 TB HDD as NTFS (D: drive)  ← do this now

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

- [ ] SSH in from laptop, copy SSH public key
- [ ] Disable password auth in SSH config
- [ ] Verify key-only login works before proceeding
- [ ] Enable UFW — allow SSH, deny everything else
- [ ] Enable automatic security updates
- [ ] Set static LAN IP (`192.168.1.100`) via Netplan
- [ ] Reserve IP in router DHCP settings

---

## Optiplex — Storage

- [ ] Identify SATA SSD device name (`lsblk`)
- [ ] Format 1 TB SATA SSD as ext4, mount at `/mnt/ssd`, add to `/etc/fstab` with `nofail`
- [ ] Create all `/opt/` and `/mnt/ssd/` service directories

---

## Docker

- [ ] Install Docker
- [ ] Add `aritra` to docker group, log out and back in
- [ ] Configure Docker data-root → NVMe (`/opt/docker`)
- [ ] Create shared Docker network (`server-net`)
- [ ] Clone oryx repo to `~/oryx`
- [ ] Create `~/stacks/{infra,media,productivity,monitoring,dev}`

---

## Tailscale

- [ ] Install Tailscale
- [ ] `tailscale up --ssh`, authorize via URL
- [ ] Note Tailscale IP, test SSH from laptop over Tailscale
- [ ] Set node key to never expire in Tailscale admin console

---

## Infrastructure stack

- [ ] Fill in `~/stacks/infra/.env` (Pi-hole password, timezone)
- [ ] Create `docker-compose.yml` for infra stack
- [ ] Create `/opt/glance/glance.yml`
- [ ] Start Pi-hole, Glance, Watchtower, Portainer
- [ ] Set router primary DNS to `192.168.1.100`
- [ ] Verify Pi-hole admin loads (`server-ts-ip:8053`)
- [ ] Verify Glance loads (`server-ts-ip:8080`)
- [ ] Verify Portainer loads (`server-ts-ip:9000`), create admin account
- [ ] Confirm ad-blocking works from a home device

---

## Cloudflare Tunnel

**On laptop:**
- [ ] Install cloudflared
- [ ] `cloudflared tunnel login`
- [ ] `cloudflared tunnel create oryx`
- [ ] Create DNS routes for all 6 subdomains (`home`, `affine`, `drive`, `photos`, `grafana`, `status`)
- [ ] Copy tunnel token

**On server:**
- [ ] Paste tunnel token into `infra/.env`
- [ ] Start cloudflared, verify 4 connections registered in logs

**Cloudflare Access (one.dash.cloudflare.com):**
- [ ] Add self-hosted application for each subdomain (6 total)
- [ ] Set policy: allow your email via Google/GitHub OAuth
- [ ] Test from mobile data — all subdomains should hit the CF Access login

---

## Media stack (Immich only)

- [ ] Fill in `~/stacks/media/.env`
- [ ] Start media stack
- [ ] Verify Immich is running (`server-ts-ip:2283`)

---

## Productivity stack

- [ ] Fill in `~/stacks/productivity/.env`
- [ ] Create `init-db.sh`
- [ ] Start productivity stack
- [ ] Verify AFFiNE loads (`server-ts-ip:3000`)
- [ ] Verify Nextcloud loads (`server-ts-ip:8081`)

---

## Monitoring stack

- [ ] Create `prometheus.yml`
- [ ] Fill in `~/stacks/monitoring/.env`
- [ ] Start monitoring stack

**Grafana (`server-ts-ip:3001`):**
- [ ] Add Prometheus data source
- [ ] Import Node Exporter dashboard (ID: 1860)
- [ ] Import cAdvisor dashboard (ID: 14282)
- [ ] Add Discord webhook contact point, send test
- [ ] Create CPU alert (> 85% for 5 min)
- [ ] Create RAM alert (> 88% for 5 min)
- [ ] Create disk full alert (> 82%)
- [ ] Create container down alert

**Uptime Kuma (`server-ts-ip:3002`):**
- [ ] Create admin account
- [ ] Add HTTP monitors for all 6 public subdomains (interval: 60s)
- [ ] Add Discord notification, assign to all monitors
- [ ] Create public status page (`status.aritra.bio`)

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
- [ ] All 6 public subdomains load behind CF Access (test on mobile data)
- [ ] SSH via Tailscale works from outside home network
- [ ] Pi-hole blocking ads on home network
- [ ] Grafana shows live CPU/RAM/disk metrics
- [ ] Discord test alert fires and is received
- [ ] Uptime Kuma shows all monitors green
- [ ] Plug in external drive, run `check-mount.sh`, confirm backup scripts work

---

## Secrets — store in Bitwarden before starting

- [ ] Pi-hole web password
- [ ] Cloudflare Tunnel token
- [ ] Immich DB password
- [ ] Nextcloud admin password
- [ ] AFFiNE admin password
- [ ] Shared PostgreSQL password
- [ ] Grafana admin password
- [ ] Discord webhook URL
