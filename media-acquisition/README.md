# media-acquisition

On-demand media download stack for the aritra.bio home server.
Runs on your **laptop** — not on the home server itself.

Stack: **Prowlarr** (indexers) · **Radarr** (movies) · **Sonarr** (TV) · **qBittorrent** (downloads)

---

## How it works

```
YOUR LAPTOP                           HOME SERVER (Germany)
──────────────────────────────        ──────────────────────────
Prowlarr + Radarr + Sonarr            Jellyfin
      ↓ queue downloads
  qBittorrent
      ↓ saves to ~/media/
      ↓
  rsync over Tailscale VPN ─────────→ /mnt/hdd/jellyfin/
```

rsync uses SSH as its transport — `user@server-ts-ip` is just an SSH
address over Tailscale's WireGuard VPN. It only transfers files that
don't already exist on the server, so interrupted transfers are safe
to resume by running the same command again.

---

## First-time setup

### 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

### 2. Create the folder structure

```bash
mkdir -p ~/media/{downloads/{incomplete,complete},movies,shows,config/{qbittorrent,radarr,sonarr,prowlarr}}
```

### 3. Configure the environment

```bash
cp .env.example .env
```

Edit `.env`:

```bash
MEDIA_ROOT=~/media   # folder created above
PUID=1000            # run `id` to confirm your values
PGID=1000
TZ=Europe/Berlin     # your timezone
```

### 4. Start the stack

```bash
docker compose up -d
```

---

## One-time app configuration

Do this once — settings persist in `~/media/config/` between sessions.

### Step 1 — qBittorrent

Open **http://localhost:8080**

- Default credentials: `admin` / `adminadmin` — change immediately
  (Tools → Options → Web UI → change password)
- Set download paths:
  - Default save path: `/data/downloads/complete`
  - Keep incomplete torrents in: `/data/downloads/incomplete`

### Step 2 — Prowlarr

Open **http://localhost:9696**

- Add your indexers: Indexers → Add Indexer
- Connect to Radarr and Sonarr: Settings → Apps → Add Application
  - Use `http://radarr:7878` and `http://sonarr:8989` as URLs
    (container names, not `localhost`)

### Step 3 — Radarr (movies)

Open **http://localhost:7878**

- Add download client: Settings → Download Clients → +
  - Type: qBittorrent · Host: `qbittorrent` · Port: `8080` · Category: `radarr`
- Add root folder: Settings → Media Management → Root Folders → `/data/movies`

### Step 4 — Sonarr (TV shows)

Open **http://localhost:8989**

- Add download client: Settings → Download Clients → +
  - Type: qBittorrent · Host: `qbittorrent` · Port: `8080` · Category: `sonarr`
- Add root folder: Settings → Media Management → Root Folders → `/data/shows`

---

## Every session

```bash
# Start
docker compose up -d

# Use the web UIs:
#   Prowlarr    http://localhost:9696
#   Radarr      http://localhost:7878
#   Sonarr      http://localhost:8989
#   qBittorrent http://localhost:8080

# Stop when done downloading
docker compose down
```

---

## Upload to the home server

Make sure Tailscale is running on both your laptop and the server, then:

```bash
# Movies
rsync -avh --progress ~/media/movies/ user@server-ts-ip:/mnt/hdd/jellyfin/movies/

# TV shows
rsync -avh --progress ~/media/shows/ user@server-ts-ip:/mnt/hdd/jellyfin/shows/
```

Then trigger a library scan in Jellyfin: Dashboard → Libraries → Scan All.

---

## Naming conventions

Jellyfin needs files named correctly to match metadata. Radarr and Sonarr
handle this automatically — configure the format in Settings → Media Management.

**Movies:**
```
movies/
  Inception (2010)/
    Inception (2010).mkv
```

**TV Shows:**
```
shows/
  Breaking Bad/
    Season 01/
      Breaking Bad S01E01.mkv
```

---

## Ports

| Service     | URL                        |
|-------------|----------------------------|
| qBittorrent | http://localhost:8080      |
| Prowlarr    | http://localhost:9696      |
| Radarr      | http://localhost:7878      |
| Sonarr      | http://localhost:8989      |
