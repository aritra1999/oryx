# oryx

Home server running on a Dell Optiplex 7060 Micro.

**Docs**
- [`setup.sh`](setup.sh) — **run this on the server** · automated setup (phases 1–9)
- [`update.sh`](update.sh) — manually update all stacks or a specific one
- [`docs/setup-checklist.md`](docs/setup-checklist.md) — full checklist including hardware steps
- [`docs/setup.md`](docs/setup.md) — detailed guide with all commands
- [`docs/runbook.md`](docs/runbook.md) — troubleshooting and ops reference
- [`docs/superpowers/specs/2026-09-02-home-server-design.md`](docs/superpowers/specs/2026-09-02-home-server-design.md) — full design spec
- [`docs/superpowers/plans/2026-09-02-home-server.md`](docs/superpowers/plans/2026-09-02-home-server.md) — implementation plan

**Sub-projects**
- [`media-acquisition/`](media-acquisition/) — on-demand download stack (laptop)
- [`backup/`](backup/) — monthly backup scripts (check-mount, backup, restore)

---

## Storage Layout

```
256 GB NVMe  (M.2 · boot + services)
┌──────────────┬────────────────────────────────────────────────────┐
│  OS + swap   │  Services pool                                     │
│  ~35 GB      │  ~220 GB  (grows with containers)                  │
│  Ubuntu LTS  │  Docker · Pi-hole · Glance · Portainer             │
│              │  Grafana · Prometheus · Uptime Kuma · Tailscale    │
└──────────────┴────────────────────────────────────────────────────┘

1 TB SATA SSD  (2.5" internal bay · app data)
┌────────┬────────────────┬────────────────────────┬────────────────┐
│  AFFiNE│  Nextcloud     │  Immich                │  free          │
│  64 GB │  128 GB        │  400 GB                │  ~408 GB       │
│  blobs │  data+DB       │  originals · cache · DB│                │
└────────┴────────────────┴────────────────────────┴────────────────┘
```

---

## Resource Allocation

Hardware: i5-8500T · 6 cores · 16 GB RAM

> RAM is always-resident footprint. CPU is peak when active — most services sit near idle between requests.

### User-facing services

| Service | RAM | CPU (peak) | Storage |
|---|---|---|---|
| Immich (server + ML) | 5–6 GB | 2 cores | 400 GB (`/mnt/ssd/immich/`) |
| AFFiNE | 2 GB | 1 core | 64 GB (`/mnt/ssd/affine/`) |
| Nextcloud | 1 GB | 1 core | 128 GB (`/mnt/ssd/nextcloud/`) |
| Grafana | ~250 MB | 0.2 | ~2 GB (NVMe) |
| Uptime Kuma | ~150 MB | 0.1 | ~1 GB (NVMe) |

### Infrastructure (always-on)

| Service | RAM | CPU (peak) | Storage |
|---|---|---|---|
| PostgreSQL (shared) | ~500 MB | 0.3 | ~20 GB (NVMe) |
| Redis | ~256 MB | 0.1 | ~1 GB (NVMe) |
| Prometheus + exporters | ~350 MB | 0.2 | ~15 GB (NVMe) |
| Pi-hole | ~512 MB | 0.5 | ~1 GB (NVMe) |
| Portainer | ~150 MB | ~0 | ~1 GB (NVMe) |
| Glance | ~128 MB | ~0 | <1 GB (NVMe) |
| cloudflared | ~100 MB | ~0 | <1 GB (NVMe) |
| Tailscale | ~100 MB | ~0 | <1 GB (NVMe) |
| Watchtower | ~50 MB | ~0 | — |

### Totals

| | Used | Available | Headroom |
|---|---|---|---|
| RAM | ~11 GB | 16 GB | ~5 GB |
| CPU (peak) | ~4 cores | 6 cores | ~2 cores |
| NVMe | ~35 GB fixed + variable services | 256 GB | ~220 GB pool |
| SATA SSD | ~592 GB allocated | 1 TB | ~408 GB free |

### On-demand dev containers

| Container | RAM (when running) | Storage |
|---|---|---|
| PostgreSQL (dev) | ~256 MB | NVMe services pool |
| Elasticsearch | up to 2 GB | NVMe services pool |
| Supabase | ~500 MB | NVMe services pool |
| PocketBase | ~64 MB | NVMe services pool |

---

## Services

| Service | URL | Access |
|---|---|---|
| Glance | https://home.aritra.fyi | Cloudflare Access |
| AFFiNE | https://notes.aritra.fyi | Cloudflare Access |
| Nextcloud | https://drive.aritra.fyi | Cloudflare Access |
| Immich | https://photos.aritra.fyi | Cloudflare Access |
| Grafana | https://grafana.aritra.fyi | Cloudflare Access |
| Uptime Kuma | https://status.aritra.fyi | Cloudflare Access |
| Pi-hole admin | `server-ts-ip:8053` | Tailscale only |
| Portainer | `server-ts-ip:9000` | Tailscale only |
| SSH | `ssh aritra@server-ts-ip` | Tailscale only |

> Jellyfin deferred — adding later once a media drive is available.

---

## Stack layout

```
~/stacks/
  infra/          Pi-hole · cloudflared · Watchtower · Glance · Portainer
  media/          Immich
  productivity/   AFFiNE · Nextcloud
  monitoring/     Prometheus · Node Exporter · cAdvisor · Grafana · Uptime Kuma
  dev/            PostgreSQL · Elasticsearch  (on-demand)
```
