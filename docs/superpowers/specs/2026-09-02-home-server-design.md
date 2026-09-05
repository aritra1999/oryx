# Home Server Design — aritra.fyi

**Date:** 2026-09-02  
**Hardware:** Dell Optiplex 7060 Micro · i5-8500T · 16 GB DDR4 · 2 drives

---

## 1. Hardware

| Component | Spec |
|---|---|
| CPU | Intel Core i5-8500T · 6 cores · 2.1 GHz (iGPU: UHD 630, QSV hardware transcode) |
| RAM | 16 GB DDR4 |
| Boot + services drive | 256 GB NVMe SSD (M.2 slot, shipped with unit) |
| App data drive | 1 TB 2.5" SATA SSD (internal 2.5" bay, from Dell G7) |
| Network | Intel I219-LM Gigabit Ethernet (wired to router) |

> The Optiplex shipped with a 256 GB NVMe in the M.2 slot. The 1 TB SATA SSD moves from the Dell G7 into the Optiplex's empty 2.5" bay. Jellyfin is deferred until a media drive is available.

---

## 2. Operating System

- **Ubuntu 26.04 LTS** (fresh install, wipe Windows 11 MAR on NVMe)
- Static LAN IP assigned via router DHCP reservation
- SSH enabled on first boot; Tailscale installed immediately after

---

## 3. Storage Layout

### 3.1 NVMe SSD — 256 GB (M.2 · boot + services)

| Volume | Size | Purpose |
|---|---|---|
| Ubuntu OS + swap | ~35 GB | System |
| Services pool | ~220 GB | Docker · Pi-hole · Glance · cloudflared · Tailscale · Portainer · Grafana · Prometheus · Uptime Kuma · on-demand containers |

> One filesystem. Services pool is all space not used by the OS (~220 GB), shared by all containers.

### 3.2 SATA SSD — 1 TB (2.5" internal bay · app data)

| Volume | Size | Purpose |
|---|---|---|
| AFFiNE | **64 GB** | Blobs + PostgreSQL + Redis |
| Nextcloud | **128 GB** | Data directory + config + PostgreSQL |
| Immich | **400 GB** | Originals + thumbnails + ML cache + PostgreSQL |
| Free / growth | ~408 GB | Unallocated |

> Jellyfin deferred — will add a media drive and set up Jellyfin at that point.

---

## 4. Resource Allocation

| Service | RAM | CPU | Storage drive |
|---|---|---|---|
| Ubuntu OS + kernel | ~1 GB | — | NVMe |
| Immich | 5–6 GB | 2 cores | SATA SSD (originals + cache + DB) |
| AFFiNE | 2 GB | 1 core | SATA SSD (blobs + DB) |
| Nextcloud | 1 GB | 1 core | SATA SSD (data dir) |
| Grafana | ~250 MB | 0.3 | NVMe |
| Prometheus + exporters | ~350 MB | 0.3 | NVMe |
| Uptime Kuma | ~150 MB | 0.1 | NVMe |
| Pi-hole | 512 MB | 0.5 | NVMe |
| Glance | 128 MB | ~0 | NVMe |
| cloudflared + Tailscale | ~200 MB | ~0 | NVMe |
| **Total** | **~11 GB** | **~4 cores** | — |
| **Free headroom** | **~5 GB** | **~2 cores** | — |

---

## 5. Services

### 5.1 User-facing services

| Service | Subdomain | Port | Drive | Purpose |
|---|---|---|---|---|
| Glance | `home.aritra.fyi` | 8080 | NVMe | Home dashboard (RSS, weather, GitHub, etc.) |
| AFFiNE | `notes.aritra.fyi` | 3000 | SATA SSD | Self-hosted notes and whiteboards |
| Nextcloud | `drive.aritra.fyi` | 80 | SATA SSD | Google Drive replacement |
| Immich | `photos.aritra.fyi` | 2283 | HDD + NVMe cache | Google Photos replacement |
| Jellyfin | `media.aritra.fyi` | 8096 | HDD + NVMe cache | Media server (movies, TV) with QSV transcode |
| Grafana | `grafana.aritra.fyi` | 3001 | NVMe | Monitoring dashboards |
| Uptime Kuma | `status.aritra.fyi` | 3002 | NVMe | Public status page + uptime monitoring |

### 5.2 Internal / admin services

| Service | Access | Port | Purpose |
|---|---|---|---|
| SSH | Tailscale only | 22 | Server shell |
| Pi-hole admin | Tailscale only | 8053 | DNS ad-blocking admin UI |
| Pi-hole DNS | LAN (router config) | 53 | Home network DNS resolver |
| Portainer | Tailscale only | 9000 | Docker web UI — manage containers, stacks, logs |
| PostgreSQL | Tailscale only | 5432 | Dev databases (on-demand) |
| Prometheus | Internal only | 9090 | Metrics scrape target |
| Node Exporter | Internal only | 9100 | System metrics |
| cAdvisor | Internal only | 8081 | Container metrics |

### 5.3 Infrastructure / background

| Service | Purpose |
|---|---|
| cloudflared | Outbound Cloudflare Tunnel daemon (no open router ports needed) |
| Tailscale | WireGuard VPN daemon for private SSH + admin access |
| Portainer CE | Web UI for managing Docker containers, stacks, logs, volumes |
| Watchtower | Nightly container image update checks |
| Borg | Scheduled local backup to NVMe (capped 64 GB) |
| rclone | Weekly encrypted sync of configs + DB dumps to Google Drive (15 GB free tier) |

---

## 6. Network & Access

### 6.1 Cloudflare Tunnel (public, authenticated)

All public services are behind **Cloudflare Access** (Google / GitHub OAuth or email OTP) before traffic reaches the server. No router port-forwarding required — `cloudflared` makes outbound connections only.

```
Browser → Cloudflare Access (OAuth) → Cloudflare Tunnel → cloudflared daemon → service:port
```

### 6.2 Tailscale VPN (private)

SSH and admin UIs are accessible only from enrolled devices. Pi-hole, PostgreSQL, and other internal services are never exposed to the public internet.

```
Enrolled device (Tailscale) → WireGuard mesh → Tailscale daemon → service:port
```

### 6.3 Pi-hole DNS

The server's LAN IP is set as the primary DNS server in the home router. All home network DNS queries go through Pi-hole for ad-blocking and local name resolution.

---

## 7. Monitoring & Alerting

### 7.1 Metrics stack

```
Node Exporter  ─┐
cAdvisor        ├─► Prometheus (scrape every 15s) ─► Grafana (dashboards + alert rules)
```

Uptime Kuma handles HTTP endpoint probing (see 7.3) — Blackbox Exporter is not needed.

### 7.2 Alert rules (Grafana → Discord webhook)

| Alert | Threshold |
|---|---|
| CPU sustained high | > 85% for 5 min |
| RAM pressure | > 88% for 5 min |
| Any disk full | > 82% used |
| Container down | Any compose service exits unexpectedly |

### 7.3 Uptime Kuma → Discord webhook

- Checks each public subdomain every 60 s from inside the server
- Fires Discord notification on down/recovery
- Hosts public status page at `status.aritra.fyi`

---

## 8. Backup Strategy

### 8.1 Manual (external HDD → monthly)

Plug in an external backup HDD and run the backup scripts in `backup/`:
- **Scope:** AFFiNE · Nextcloud · Immich originals · stack configs · DB dumps
- **Excluded:** Jellyfin library (re-downloadable) · Jellyfin cache (regeneratable)
- **Scripts:** `backup/check-mount.sh` · `backup/backup.sh` · `backup/restore.sh`

### 8.2 Offsite (rclone → Google Drive)

- **Scope:** Configs, Docker Compose files, PostgreSQL dumps, AFFiNE DB dump only (not blobs — too large for 15 GB free tier)
- **Schedule:** Weekly at 03:00 Sunday
- **Encryption:** rclone crypt before upload
- **Size estimate:** ~3–5 GB

### 8.3 Jellyfin (manual)

- Manual rsync to external HDD once a month
- No automated backup — library is re-downloadable

---

## 9. Docker Compose Organisation

All services are managed with Docker Compose, grouped into stacks by function:

```
~/stacks/
  media/          docker-compose.yml   # Jellyfin, Immich
  productivity/   docker-compose.yml   # AFFiNE, Nextcloud
  infra/          docker-compose.yml   # Pi-hole, cloudflared, Tailscale, Glance
  monitoring/     docker-compose.yml   # Prometheus, Node Exporter, cAdvisor, Grafana, Uptime Kuma
  dev/            docker-compose.yml   # PostgreSQL, Elasticsearch, etc. (on-demand)
```

Each stack uses a shared Docker network (`server-net`) so services can reach each other by container name.

Mount paths follow a consistent pattern:
- `/mnt/nvme/...` — NVMe volumes (cache, monitoring data, backup)
- `/mnt/ssd/...` — SATA SSD volumes (Docker root, AFFiNE, Nextcloud)
- `/mnt/hdd/...` — SATA HDD volumes (Immich originals, Jellyfin library)

---

## 10. Open Decisions

- **Remote backup scope for Immich:** Currently excluded from Google Drive backup due to 15 GB free tier limit. Revisit if upgrading to Google One.
- **Elasticsearch:** Omitted from always-on services; spin up as a dev container on demand.
- **SSL for internal services:** Cloudflare handles TLS termination for all public subdomains. Internal Tailscale traffic is encrypted by WireGuard; no additional TLS needed.
- **UPS:** No UPS planned. Server may restart after power cut; all services use Docker restart policies (`unless-stopped`).
