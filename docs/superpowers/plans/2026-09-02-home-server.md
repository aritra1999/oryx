# Home Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up a self-hosted home server on the Dell Optiplex 7060 Micro running Jellyfin, Immich, AFFiNE, Nextcloud, Glance, Pi-hole, and a Prometheus/Grafana monitoring stack — accessible globally via Cloudflare Tunnel + Access and privately via Tailscale.

**Architecture:** Docker Compose stacks grouped by function (`infra/`, `media/`, `productivity/`, `monitoring/`, `dev/`), all sharing a single Docker bridge network (`server-net`). Three storage tiers: NVMe for OS/cache/monitoring, SATA SSD (USB-C) for Docker root and app data, HDD for media originals.

**Tech Stack:** Ubuntu 26.04 LTS · Docker Compose · Cloudflare Tunnel · Tailscale · Jellyfin · Immich · AFFiNE · Nextcloud · Glance · Prometheus · Grafana · Uptime Kuma · Pi-hole · Borg · rclone

**Spec:** `docs/superpowers/specs/2026-09-02-home-server-design.md`

---

## Directory layout (end state)

```
~/stacks/
  infra/
    docker-compose.yml
    .env
  media/
    docker-compose.yml
    .env
  productivity/
    docker-compose.yml
    .env
  monitoring/
    docker-compose.yml
    .env
    prometheus/
      prometheus.yml
  dev/
    docker-compose.yml     ← on-demand only, not started by default
    .env

/mnt/nvme/                 ← NVMe SSD (boot drive, already mounted as /)
  pihole/
  cloudflared/
  glance/
  jellyfin/cache/
  immich/cache/
  immich/model-cache/
  monitoring/
    prometheus/
    grafana/
    uptime-kuma/
  backup/                  ← Borg repo (64 GB cap)

/mnt/ssd/                  ← SATA SSD (USB-C enclosure)
  docker/                  ← Docker data-root
  affine/
  nextcloud/

/mnt/hdd/                  ← SATA HDD (internal bay)
  jellyfin/
    movies/
    shows/
  immich/
```

---

## Phase 1 — OS Installation & Base System

### Task 1: Install Ubuntu 26.04 LTS

**Files:**
- None (live USB install)

- [ ] Download Ubuntu 26.04 LTS Server ISO from https://ubuntu.com/download/server
- [ ] Flash to USB with:
  ```bash
  # on your Mac
  sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/diskN bs=1m status=progress
  ```
- [ ] Boot the Optiplex from USB (F12 at POST for boot menu)
- [ ] Follow installer — select "Ubuntu Server (minimized)", wipe disk, install on NVMe
- [ ] During install: create user `aritra`, enable OpenSSH server
- [ ] After reboot, verify:
  ```bash
  uname -a        # should show 6.x kernel
  lsb_release -a  # should show Ubuntu 26.04
  ```

---

### Task 2: Base system hardening & static IP

**Files:**
- Modify: `/etc/ssh/sshd_config`
- Create: `/etc/ufw/` rules
- Modify: `/etc/netplan/00-installer-config.yaml`

- [ ] SSH key setup — on your **laptop** generate a key if you don't have one:
  ```bash
  ssh-keygen -t ed25519 -C "aritra-homeserver"
  ssh-copy-id aritra@<server-ip>
  ```
- [ ] Disable SSH password auth:
  ```bash
  sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  sudo systemctl restart ssh
  ```
- [ ] Verify key-only login works from a new terminal before proceeding
- [ ] Enable UFW:
  ```bash
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh
  sudo ufw enable
  # verify
  sudo ufw status verbose
  ```
- [ ] Enable automatic security updates:
  ```bash
  sudo apt install -y unattended-upgrades
  sudo dpkg-reconfigure --priority=low unattended-upgrades
  # choose "Yes"
  ```
- [ ] Set static LAN IP via netplan (replace `enp3s0` with your interface from `ip link`):
  ```bash
  sudo tee /etc/netplan/00-installer-config.yaml << 'EOF'
  network:
    version: 2
    ethernets:
      enp3s0:
        dhcp4: no
        addresses:
          - 192.168.1.100/24
        routes:
          - to: default
            via: 192.168.1.1
        nameservers:
          addresses: [1.1.1.1, 8.8.8.8]
  EOF
  sudo netplan apply
  ```
  > Replace `192.168.1.100` and gateway `192.168.1.1` with your router's subnet values. Reserve this IP in your router's DHCP settings too.
- [ ] Verify connectivity:
  ```bash
  ip addr show enp3s0
  ping -c 3 1.1.1.1
  ```
- [ ] Commit system state (note the static IP and SSH key fingerprint somewhere safe)

---

## Phase 2 — Storage Setup

### Task 3: Mount SATA SSD (USB-C) and HDD

- [ ] Physically install: **SATA SSD in the internal 2.5" bay**, HDD in USB-C 3.1 Gen 2 enclosure plugged into the rear USB-C port
- [ ] Identify devices:
  ```bash
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
  ```
  Expected: NVMe as `nvme0n1` (already mounted as `/`), SATA SSD as `sda` (internal), HDD as `sdb` (USB-C)
- [ ] Format both drives (adjust device names to match your system):
  ```bash
  # SATA SSD (internal bay — Docker + app data)
  sudo parted /dev/sda mklabel gpt
  sudo parted /dev/sda mkpart primary ext4 0% 100%
  sudo mkfs.ext4 -L ssd /dev/sda1

  # HDD (USB-C enclosure — media)
  sudo parted /dev/sdb mklabel gpt
  sudo parted /dev/sdb mkpart primary ext4 0% 100%
  sudo mkfs.ext4 -L hdd /dev/sdb1
  ```
- [ ] Create mount points:
  ```bash
  sudo mkdir -p /mnt/hdd /mnt/ssd
  ```
- [ ] Get UUIDs and add to fstab:
  ```bash
  sudo blkid /dev/sda1 /dev/sdb1
  # copy the UUIDs, then:
  sudo tee -a /etc/fstab << 'EOF'
  UUID=<hdd-uuid>  /mnt/hdd  ext4  defaults,nofail  0  2
  UUID=<ssd-uuid>  /mnt/ssd  ext4  defaults,nofail  0  2
  EOF
  sudo mount -a
  ```
  > `nofail` ensures the system still boots if the USB SSD is unplugged
- [ ] Verify both are mounted:
  ```bash
  df -h | grep mnt
  ```
  Expected: `/mnt/hdd` and `/mnt/ssd` each showing their full capacity

---

### Task 4: Create directory structure

- [ ] Create all app data directories:
  ```bash
  # NVMe directories (under /)
    sudo mkdir -p \
      /mnt/nvme/pihole/etc \
      /mnt/nvme/pihole/dnsmasq \
      /mnt/nvme/cloudflared \
      /mnt/nvme/glance \
      /mnt/nvme/portainer \
    /mnt/nvme/jellyfin/cache \
    /mnt/nvme/immich/cache \
    /mnt/nvme/immich/model-cache \
    /mnt/nvme/monitoring/prometheus \
    /mnt/nvme/monitoring/grafana \
    /mnt/nvme/monitoring/uptime-kuma \
    /mnt/nvme/backup

  # SATA SSD directories
  sudo mkdir -p \
    /mnt/ssd/docker \
    /mnt/ssd/affine \
    /mnt/ssd/nextcloud

  # HDD directories
  sudo mkdir -p \
    /mnt/hdd/jellyfin/movies \
    /mnt/hdd/jellyfin/shows \
    /mnt/hdd/immich
  ```
  > Note: `/mnt/nvme` is just a logical label for paths on the root filesystem (`/`). The NVMe IS the root disk — no separate mount needed.
- [ ] Set ownership (replace `1000:1000` if your UID/GID differs — check with `id`):
  ```bash
  sudo chown -R 1000:1000 /mnt/ssd /mnt/hdd
  sudo chown -R 1000:1000 /mnt/nvme
  ```
- [ ] Verify:
  ```bash
  ls /mnt/hdd/jellyfin/
  # Expected: movies  shows
  ```

---

## Phase 3 — Docker & Shared Network

### Task 5: Install Docker, configure data-root on SATA SSD

**Files:**
- Create: `/etc/docker/daemon.json`

- [ ] Install Docker:
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker aritra
  # log out and back in for group to take effect
  ```
- [ ] Configure Docker data-root to use SATA SSD:
  ```bash
  sudo tee /etc/docker/daemon.json << 'EOF'
  {
    "data-root": "/mnt/ssd/docker",
    "log-driver": "json-file",
    "log-opts": {
      "max-size": "10m",
      "max-file": "3"
    }
  }
  EOF
  sudo systemctl restart docker
  ```
- [ ] Verify Docker is using the correct data-root:
  ```bash
  docker info | grep "Docker Root Dir"
  # Expected: Docker Root Dir: /mnt/ssd/docker
  ```
- [ ] Create shared Docker network:
  ```bash
  docker network create server-net
  docker network ls | grep server-net
  ```
- [ ] Create stacks directory:
  ```bash
  mkdir -p ~/stacks/{infra,media,productivity,monitoring,dev}
  ```
- [ ] Commit:
  ```bash
  cd ~/stacks && git init && git add . && git commit -m "chore: initial stacks directory"
  ```

---

## Phase 4 — Infrastructure Stack

### Task 6: Tailscale

- [ ] Install Tailscale:
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  ```
- [ ] Authenticate (opens a URL — open it on your phone/laptop):
  ```bash
  sudo tailscale up
  ```
- [ ] Enable SSH via Tailscale and note the Tailscale IP:
  ```bash
  sudo tailscale up --ssh
  tailscale ip -4
  # note this IP — it's your "server-ts-ip" for all admin access
  ```
- [ ] Verify from your **laptop** (must have Tailscale installed):
  ```bash
  ssh aritra@<tailscale-ip>
  # should connect without password
  ```
- [ ] Enable Tailscale to start on boot:
  ```bash
  sudo systemctl enable --now tailscaled
  ```

---

### Task 7: Infrastructure stack (Pi-hole, cloudflared, Watchtower, Glance)

**Files:**
- Create: `~/stacks/infra/docker-compose.yml`
- Create: `~/stacks/infra/.env`

- [ ] Create `.env`:
  ```bash
  tee ~/stacks/infra/.env << 'EOF'
  TZ=Europe/Berlin
  PIHOLE_PASSWORD=changeme_strong_password
  CLOUDFLARE_TUNNEL_TOKEN=           # fill in after Task 8
  EOF
  ```
- [ ] Create `docker-compose.yml`:
  ```bash
  tee ~/stacks/infra/docker-compose.yml << 'EOF'
  networks:
    server-net:
      external: true

  services:

    pihole:
      image: pihole/pihole:latest
      container_name: pihole
      ports:
        - "53:53/tcp"
        - "53:53/udp"
        - "8053:80/tcp"       # admin UI on :8053 (80 reserved for other services)
      environment:
        TZ: ${TZ}
        WEBPASSWORD: ${PIHOLE_PASSWORD}
      volumes:
        - /mnt/nvme/pihole/etc:/etc/pihole
        - /mnt/nvme/pihole/dnsmasq:/etc/dnsmasq.d
      cap_add:
        - NET_ADMIN
      restart: unless-stopped
      networks:
        - server-net

    cloudflared:
      image: cloudflare/cloudflared:latest
      container_name: cloudflared
      restart: unless-stopped
      command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
      networks:
        - server-net

    watchtower:
      image: containrrr/watchtower:latest
      container_name: watchtower
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
      environment:
        WATCHTOWER_SCHEDULE: "0 0 3 * * *"    # 3am nightly
        WATCHTOWER_CLEANUP: "true"
        TZ: ${TZ}
      restart: unless-stopped

  glance:
    image: glanceapp/glance:latest
    container_name: glance
    ports:
      - "8080:8080"
    volumes:
      - /mnt/nvme/glance:/app/assets
      - /mnt/nvme/glance/glance.yml:/app/glance.yml:ro
    restart: unless-stopped
    networks:
      - server-net

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/nvme/portainer:/data
    restart: unless-stopped
  EOF
  ```
- [ ] Create a minimal Glance config:
  ```bash
  tee /mnt/nvme/glance/glance.yml << 'EOF'
  pages:
    - name: Home
      columns:
        - size: full
          widgets:
            - type: bookmarks
              title: Services
              groups:
                - title: Media
                  links:
                    - title: Jellyfin
                      url: https://media.aritra.fyi
                    - title: Immich
                      url: https://photos.aritra.fyi
                - title: Productivity
                  links:
                    - title: AFFiNE
                      url: https://notes.aritra.fyi
                    - title: Nextcloud
                      url: https://drive.aritra.fyi
                - title: Monitoring
                  links:
                    - title: Grafana
                      url: https://grafana.aritra.fyi
                    - title: Status
                      url: https://status.aritra.fyi
  EOF
  ```
- [ ] Start Pi-hole and Glance only (cloudflared needs the token from Task 8):
  ```bash
  cd ~/stacks/infra
  docker compose up -d pihole glance watchtower
  ```
- [ ] Verify Pi-hole admin is reachable:
  ```bash
  curl -I http://localhost:8053/admin/
  # Expected: HTTP/1.1 301 or 200
  ```
- [ ] Verify Glance dashboard:
  ```bash
  curl -I http://localhost:8080
  # Expected: HTTP/1.1 200 OK
  ```
- [ ] Point router DNS to server: log into your router admin UI and set primary DNS to `192.168.1.100` (the server's static LAN IP)
- [ ] Verify ad-blocking works from any home device:
  ```bash
  nslookup doubleclick.net 192.168.1.100
  # Expected: returns 0.0.0.0 (blocked)
  ```
- [ ] Commit:
  ```bash
  cd ~/stacks && git add infra/ && git commit -m "feat: infra stack — pihole, glance, watchtower"
  ```

---

## Phase 5 — Cloudflare Tunnel & Access

### Task 8: Create Cloudflare Tunnel and configure subdomains

- [ ] Install cloudflared locally on your laptop (for setup only):
  ```bash
  # macOS
  brew install cloudflare/cloudflare/cloudflared
  ```
- [ ] Authenticate with Cloudflare (opens browser):
  ```bash
  cloudflared tunnel login
  ```
- [ ] Create the tunnel:
  ```bash
  cloudflared tunnel create oryx
  # note the tunnel ID from the output
  ```
- [ ] Create tunnel config pointing each subdomain to a server port:
  ```bash
  tee ~/.cloudflared/config.yml << 'EOF'
  tunnel: <your-tunnel-id>
  credentials-file: /root/.cloudflared/<tunnel-id>.json

  ingress:
    - hostname: home.aritra.fyi
      service: http://localhost:8080
    - hostname: notes.aritra.fyi
      service: http://localhost:3000
    - hostname: drive.aritra.fyi
      service: http://localhost:8081
    - hostname: photos.aritra.fyi
      service: http://localhost:2283
    - hostname: media.aritra.fyi
      service: http://localhost:8096
    - hostname: grafana.aritra.fyi
      service: http://localhost:3001
    - hostname: status.aritra.fyi
      service: http://localhost:3002
    - service: http_status:404
  EOF
  ```
- [ ] Create DNS records for all subdomains:
  ```bash
  for sub in home affine drive photos media grafana status; do
    cloudflared tunnel route dns oryx ${sub}.aritra.fyi
  done
  ```
- [ ] Generate a tunnel token for the server:
  ```bash
  cloudflared tunnel token oryx
  # copy the token
  ```
- [ ] Paste the token into `~/stacks/infra/.env` on the server:
  ```
  CLOUDFLARE_TUNNEL_TOKEN=<paste token here>
  ```
- [ ] Start cloudflared:
  ```bash
  cd ~/stacks/infra
  docker compose up -d cloudflared
  docker logs cloudflared
  # Expected: "Connection ... registered" (4 connections)
  ```
- [ ] Verify tunnel is active:
  ```bash
  cloudflared tunnel info oryx
  # Expected: shows active connections
  ```

---

### Task 9: Cloudflare Access (zero-trust auth)

- [ ] Go to https://one.dash.cloudflare.com → Access → Applications
- [ ] Add a self-hosted application for each subdomain (repeat for all 7):
  - Application name: e.g. `Jellyfin`
  - Application domain: `media.aritra.fyi`
  - Session duration: `24 hours`
  - Policy: Allow → Emails → add your email address
  - Identity providers: Google (or GitHub)
- [ ] Verify access from outside your home network (use mobile data):
  ```bash
  curl -I https://home.aritra.fyi
  # Expected: HTTP 302 redirect to Cloudflare Access login
  ```
- [ ] Complete the OAuth login flow in browser — verify it reaches the Glance dashboard

---

## Phase 6 — Media Stack

### Task 10: Jellyfin

**Files:**
- Create: `~/stacks/media/docker-compose.yml`
- Create: `~/stacks/media/.env`

- [ ] Create `.env`:
  ```bash
  tee ~/stacks/media/.env << 'EOF'
  TZ=Europe/Berlin
  EOF
  ```
- [ ] Enable Intel QSV hardware transcoding:
  ```bash
  sudo apt install -y intel-media-va-driver-non-free vainfo
  vainfo
  # Expected: lists VAEntrypointVLD and VAEntrypointEncSlice for H.264/H.265
  ls /dev/dri/
  # Expected: card0  renderD128
  ```
- [ ] Get the `render` group ID (needed for QSV access):
  ```bash
  getent group render | cut -d: -f3
  # note the number (commonly 110 or 44)
  ```
- [ ] Create `docker-compose.yml`:
  ```bash
  tee ~/stacks/media/docker-compose.yml << 'EOF'
  networks:
    server-net:
      external: true

  services:

    jellyfin:
      image: jellyfin/jellyfin:latest
      container_name: jellyfin
      ports:
        - "8096:8096"
      volumes:
        - /mnt/nvme/jellyfin/cache:/cache
        - /mnt/nvme/jellyfin/config:/config
        - /mnt/hdd/jellyfin/movies:/media/movies:ro
        - /mnt/hdd/jellyfin/shows:/media/shows:ro
      devices:
        - /dev/dri:/dev/dri
      group_add:
        - "110"                 # render group — replace with value from above
      environment:
        TZ: ${TZ}
        JELLYFIN_PublishedServerUrl: https://media.aritra.fyi
      restart: unless-stopped
      networks:
        - server-net

    # Immich gets its own Postgres (requires pgvecto-rs extension)
    immich-server:
      image: ghcr.io/immich-app/immich-server:release
      container_name: immich-server
      ports:
        - "2283:2283"
      volumes:
        - /mnt/hdd/immich:/usr/src/app/upload
        - /mnt/nvme/immich/cache:/mnt/cache
      environment:
        TZ: ${TZ}
        DB_HOSTNAME: immich-postgres
        DB_USERNAME: ${IMMICH_DB_USER}
        DB_PASSWORD: ${IMMICH_DB_PASSWORD}
        DB_DATABASE_NAME: immich
        REDIS_HOSTNAME: immich-redis
      depends_on:
        - immich-postgres
        - immich-redis
      restart: unless-stopped
      networks:
        - server-net

    immich-machine-learning:
      image: ghcr.io/immich-app/immich-machine-learning:release
      container_name: immich-ml
      volumes:
        - /mnt/nvme/immich/model-cache:/cache
      restart: unless-stopped
      networks:
        - server-net

    immich-redis:
      image: redis:7-alpine
      container_name: immich-redis
      restart: unless-stopped
      networks:
        - server-net

    immich-postgres:
      image: tensorchord/pgvecto-rs:pg16-v0.2.0
      container_name: immich-postgres
      environment:
        POSTGRES_USER: ${IMMICH_DB_USER}
        POSTGRES_PASSWORD: ${IMMICH_DB_PASSWORD}
        POSTGRES_DB: immich
        POSTGRES_INITDB_ARGS: '--data-checksums'
      volumes:
        - /mnt/nvme/immich/postgres:/var/lib/postgresql/data
      restart: unless-stopped
      networks:
        - server-net
  EOF
  ```
- [ ] Add Immich DB credentials to `.env`:
  ```bash
  tee -a ~/stacks/media/.env << 'EOF'
  IMMICH_DB_USER=immich
  IMMICH_DB_PASSWORD=changeme_strong_password
  EOF
  ```
- [ ] Start media stack:
  ```bash
  cd ~/stacks/media
  docker compose up -d
  docker compose ps
  # Expected: all containers show "running"
  ```
- [ ] Verify Jellyfin:
  ```bash
  curl -I http://localhost:8096
  # Expected: HTTP/1.1 302 (redirects to setup wizard)
  ```
- [ ] Complete Jellyfin setup wizard in browser at `http://localhost:8096`:
  - Create admin account
  - Add media library: Movies → `/media/movies`
  - Add media library: TV Shows → `/media/shows`
  - Enable Hardware Acceleration: Playback → Transcoding → Intel QuickSync
- [ ] Verify Immich:
  ```bash
  curl -I http://localhost:2283
  # Expected: HTTP/1.1 200 OK
  ```
- [ ] Commit:
  ```bash
  cd ~/stacks && git add media/ && git commit -m "feat: media stack — jellyfin, immich"
  ```

---

## Phase 7 — Productivity Stack

### Task 11: AFFiNE + Nextcloud + shared infrastructure

**Files:**
- Create: `~/stacks/productivity/docker-compose.yml`
- Create: `~/stacks/productivity/.env`

- [ ] Create `.env`:
  ```bash
  tee ~/stacks/productivity/.env << 'EOF'
  TZ=Europe/Berlin
  POSTGRES_USER=appuser
  POSTGRES_PASSWORD=changeme_strong_password
  AFFINE_ADMIN_EMAIL=aritra@example.com
  AFFINE_ADMIN_PASSWORD=changeme_strong_password
  NEXTCLOUD_ADMIN_USER=aritra
  NEXTCLOUD_ADMIN_PASSWORD=changeme_strong_password
  EOF
  ```
- [ ] Create `docker-compose.yml`:
  ```bash
  tee ~/stacks/productivity/docker-compose.yml << 'EOF'
  networks:
    server-net:
      external: true

  services:

    # ── Shared infrastructure ─────────────────────────────────────────────────
    postgres:
      image: postgres:16-alpine
      container_name: prod-postgres
      environment:
        POSTGRES_USER: ${POSTGRES_USER}
        POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
        POSTGRES_MULTIPLE_DATABASES: affine,nextcloud
      volumes:
        - /mnt/ssd/affine/postgres:/var/lib/postgresql/data
        - ./init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
      restart: unless-stopped
      networks:
        - server-net

    redis:
      image: redis:7-alpine
      container_name: prod-redis
      restart: unless-stopped
      networks:
        - server-net

    # ── AFFiNE ────────────────────────────────────────────────────────────────
    affine:
      image: ghcr.io/toeverything/affine-graphql:stable
      container_name: affine
      ports:
        - "3000:3010"
      volumes:
        - /mnt/ssd/affine/data:/root/.affine/storage
        - /mnt/ssd/affine/config:/root/.affine/config
      environment:
        NODE_OPTIONS: "--import=./scripts/register.js"
        AFFINE_CONFIG_PATH: /root/.affine/config
        REDIS_SERVER_HOST: redis
        DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/affine
        AFFINE_ADMIN_EMAIL: ${AFFINE_ADMIN_EMAIL}
        AFFINE_ADMIN_PASSWORD: ${AFFINE_ADMIN_PASSWORD}
      depends_on:
        - postgres
        - redis
      restart: unless-stopped
      networks:
        - server-net

    # ── Nextcloud ─────────────────────────────────────────────────────────────
    nextcloud:
      image: nextcloud:29-apache
      container_name: nextcloud
      ports:
        - "8081:80"
      volumes:
        - /mnt/ssd/nextcloud/data:/var/www/html/data
        - /mnt/ssd/nextcloud/config:/var/www/html/config
        - /mnt/ssd/nextcloud/apps:/var/www/html/custom_apps
      environment:
        POSTGRES_HOST: postgres
        POSTGRES_DB: nextcloud
        POSTGRES_USER: ${POSTGRES_USER}
        POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
        REDIS_HOST: redis
        NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
        NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
        NEXTCLOUD_TRUSTED_DOMAINS: drive.aritra.fyi localhost
        OVERWRITEPROTOCOL: https
        OVERWRITECLIURL: https://drive.aritra.fyi
      depends_on:
        - postgres
        - redis
      restart: unless-stopped
      networks:
        - server-net
  EOF
  ```
- [ ] Create the multi-database init script (so one Postgres serves both apps):
  ```bash
  tee ~/stacks/productivity/init-db.sh << 'EOF'
  #!/bin/bash
  set -e
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
      CREATE DATABASE affine;
      CREATE DATABASE nextcloud;
      GRANT ALL PRIVILEGES ON DATABASE affine TO $POSTGRES_USER;
      GRANT ALL PRIVILEGES ON DATABASE nextcloud TO $POSTGRES_USER;
  EOSQL
  EOF
  chmod +x ~/stacks/productivity/init-db.sh
  ```
- [ ] Start the productivity stack:
  ```bash
  cd ~/stacks/productivity
  docker compose up -d
  docker compose ps
  # Expected: all 4 containers running
  ```
- [ ] Verify AFFiNE:
  ```bash
  curl -I http://localhost:3000
  # Expected: HTTP/1.1 200 OK
  ```
- [ ] Verify Nextcloud:
  ```bash
  curl -I http://localhost:8081
  # Expected: HTTP/1.1 302 (redirects to setup or login)
  ```
- [ ] Commit:
  ```bash
  cd ~/stacks && git add productivity/ && git commit -m "feat: productivity stack — affine, nextcloud"
  ```

---

## Phase 8 — Monitoring Stack

### Task 12: Prometheus + Node Exporter + cAdvisor + Grafana + Uptime Kuma

**Files:**
- Create: `~/stacks/monitoring/docker-compose.yml`
- Create: `~/stacks/monitoring/.env`
- Create: `~/stacks/monitoring/prometheus/prometheus.yml`

- [ ] Create `.env`:
  ```bash
  tee ~/stacks/monitoring/.env << 'EOF'
  TZ=Europe/Berlin
  GRAFANA_ADMIN_PASSWORD=changeme_strong_password
  EOF
  ```
- [ ] Create Prometheus config:
  ```bash
  mkdir -p ~/stacks/monitoring/prometheus
  tee ~/stacks/monitoring/prometheus/prometheus.yml << 'EOF'
  global:
    scrape_interval: 15s
    evaluation_interval: 15s

  scrape_configs:
    - job_name: node
      static_configs:
        - targets: ['node-exporter:9100']

    - job_name: cadvisor
      static_configs:
        - targets: ['cadvisor:8080']

    - job_name: prometheus
      static_configs:
        - targets: ['localhost:9090']
  EOF
  ```
- [ ] Create `docker-compose.yml`:
  ```bash
  tee ~/stacks/monitoring/docker-compose.yml << 'EOF'
  networks:
    server-net:
      external: true

  services:

    prometheus:
      image: prom/prometheus:latest
      container_name: prometheus
      ports:
        - "9090:9090"
      volumes:
        - /mnt/nvme/monitoring/prometheus:/prometheus
        - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      command:
        - '--config.file=/etc/prometheus/prometheus.yml'
        - '--storage.tsdb.path=/prometheus'
        - '--storage.tsdb.retention.time=30d'
        - '--storage.tsdb.retention.size=14GB'
      restart: unless-stopped
      networks:
        - server-net

    node-exporter:
      image: prom/node-exporter:latest
      container_name: node-exporter
      pid: host
      volumes:
        - /proc:/host/proc:ro
        - /sys:/host/sys:ro
        - /:/rootfs:ro
      command:
        - '--path.procfs=/host/proc'
        - '--path.rootfs=/rootfs'
        - '--path.sysfs=/host/sys'
        - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
      restart: unless-stopped
      network_mode: host

    cadvisor:
      image: gcr.io/cadvisor/cadvisor:latest
      container_name: cadvisor
      ports:
        - "8082:8080"
      volumes:
        - /:/rootfs:ro
        - /var/run:/var/run:rw
        - /sys:/sys:ro
        - /mnt/ssd/docker:/var/lib/docker:ro
        - /dev/disk/:/dev/disk:ro
      privileged: true
      restart: unless-stopped
      networks:
        - server-net

    grafana:
      image: grafana/grafana:latest
      container_name: grafana
      ports:
        - "3001:3000"
      volumes:
        - /mnt/nvme/monitoring/grafana:/var/lib/grafana
      environment:
        GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
        GF_USERS_ALLOW_SIGN_UP: "false"
        GF_SERVER_ROOT_URL: https://grafana.aritra.fyi
        GF_SERVER_DOMAIN: grafana.aritra.fyi
      restart: unless-stopped
      networks:
        - server-net

    uptime-kuma:
      image: louislam/uptime-kuma:1
      container_name: uptime-kuma
      ports:
        - "3002:3001"
      volumes:
        - /mnt/nvme/monitoring/uptime-kuma:/app/data
      restart: unless-stopped
      networks:
        - server-net
  EOF
  ```
- [ ] Start monitoring stack:
  ```bash
  cd ~/stacks/monitoring
  docker compose up -d
  docker compose ps
  # Expected: all 5 containers running
  ```
- [ ] Verify Prometheus is scraping:
  ```bash
  curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep '"health"'
  # Expected: "health": "up" for each target
  ```
- [ ] Verify Grafana:
  ```bash
  curl -I http://localhost:3001
  # Expected: HTTP/1.1 302 redirect to login
  ```
- [ ] Set up Grafana Prometheus datasource:
  - Open http://localhost:3001, login with admin + your password
  - Connections → Data Sources → Add → Prometheus
  - URL: `http://prometheus:9090`
  - Save & Test → "Data source is working"
- [ ] Import Node Exporter dashboard:
  - Dashboards → Import → ID: `1860` (Node Exporter Full)
  - Select Prometheus datasource → Import
- [ ] Import cAdvisor dashboard:
  - Dashboards → Import → ID: `14282`
  - Select Prometheus datasource → Import
- [ ] Add Discord alert contact point:
  - Alerting → Contact Points → Add contact point
  - Type: Discord, paste your Discord webhook URL
  - Name: `discord`
  - Test → verify you receive a test message in Discord
- [ ] Create alert rules:
  - Alerting → Alert Rules → New rule for each:

  **CPU Alert:**
  ```
  Name: High CPU
  Query A: 100 - (avg by(instance)(irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
  Condition: IS ABOVE 85
  For: 5m
  Contact point: discord
  ```

  **RAM Alert:**
  ```
  Name: High RAM
  Query A: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
  Condition: IS ABOVE 88
  For: 5m
  Contact point: discord
  ```

  **Disk Alert (NVMe):**
  ```
  Name: NVMe disk full
  Query A: (1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100
  Condition: IS ABOVE 82
  Contact point: discord
  ```

  **Disk Alert (HDD):**
  ```
  Name: HDD disk full
  Query A: (1 - (node_filesystem_avail_bytes{mountpoint="/mnt/hdd"} / node_filesystem_size_bytes{mountpoint="/mnt/hdd"})) * 100
  Condition: IS ABOVE 82
  Contact point: discord
  ```

- [ ] Configure Uptime Kuma:
  - Open http://localhost:3002, create admin account
  - Add monitor for each public subdomain:
    - Type: HTTP(s), URL: `https://home.aritra.fyi`, interval: 60s
    - Repeat for: `affine.`, `drive.`, `photos.`, `media.`, `grafana.`, `status.`
  - Settings → Notifications → Add Discord webhook
  - Assign webhook to all monitors
  - Status Page → New status page `aritra.fyi Services` → public URL: `status.aritra.fyi`
  **Container Down Alert:**
  ```
  Name: Container down
  Query A: absent(container_last_seen{name=~"jellyfin|immich-server|affine|nextcloud|pihole|grafana|uptime-kuma|cloudflared"})
  Condition: IS ABOVE 0
  For: 2m
  Contact point: discord
  ```

- [ ] Commit:
  ```bash
  cd ~/stacks && git add monitoring/ && git commit -m "feat: monitoring stack — prometheus, grafana, uptime-kuma"
  ```

---

## Phase 9 — Backup

### Task 13: Borg local backup

**Files:**
- Create: `~/backup/borg-backup.sh`
- Create: `/etc/systemd/system/borg-backup.service`
- Create: `/etc/systemd/system/borg-backup.timer`

- [ ] Install Borg:
  ```bash
  sudo apt install -y borgbackup
  ```
- [ ] Initialise Borg repository on NVMe (with encryption):
  ```bash
  borg init --encryption=repokey /mnt/nvme/backup/borg
  # you'll be prompted for a passphrase — store it safely
  ```
- [ ] Create the backup script:
  ```bash
  mkdir -p ~/backup
  tee ~/backup/borg-backup.sh << 'EOF'
  #!/usr/bin/env bash
  set -euo pipefail

  export BORG_REPO=/mnt/nvme/backup/borg
  export BORG_PASSPHRASE='your_borg_passphrase_here'   # replace with real passphrase

  ARCHIVE="${BORG_REPO}::$(date +%Y-%m-%d_%H-%M-%S)"

  # Backup: stacks configs + AFFiNE data + Nextcloud data
  borg create \
    --verbose \
    --filter AME \
    --stats \
    --show-rc \
    --compression lz4 \
    "${ARCHIVE}" \
    ~/stacks \
    /mnt/ssd/affine \
    /mnt/ssd/nextcloud

  # Prune: keep 7 daily, 4 weekly, 3 monthly
  borg prune \
    --verbose \
    --list \
    --stats \
    --show-rc \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=3 \
    "${BORG_REPO}"

  # Cap repo at 64 GB (Borg doesn't hard-cap; this is a manual check)
  USAGE=$(borg info "${BORG_REPO}" --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['repository']['stats']['total_size'])")
  if [ "$USAGE" -gt 68719476736 ]; then   # 64 GB in bytes
    echo "WARNING: Borg repo exceeds 64 GB — prune manually or increase cap"
  fi
  EOF
  chmod +x ~/backup/borg-backup.sh
  ```
- [ ] Test backup runs without error:
  ```bash
  ~/backup/borg-backup.sh
  borg list /mnt/nvme/backup/borg
  # Expected: shows one archive with today's date
  ```
- [ ] Create systemd service + timer for nightly 2am backup:
  ```bash
  sudo tee /etc/systemd/system/borg-backup.service << 'EOF'
  [Unit]
  Description=Borg Backup

  [Service]
  Type=oneshot
  User=aritra
  ExecStart=/home/aritra/backup/borg-backup.sh
  StandardOutput=journal
  StandardError=journal
  EOF

  sudo tee /etc/systemd/system/borg-backup.timer << 'EOF'
  [Unit]
  Description=Nightly Borg Backup

  [Timer]
  OnCalendar=*-*-* 02:00:00
  Persistent=true

  [Install]
  WantedBy=timers.target
  EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now borg-backup.timer
  sudo systemctl list-timers borg-backup.timer
  # Expected: shows next trigger time around 02:00
  ```

---

### Task 14: rclone Google Drive offsite backup

- [ ] Install rclone:
  ```bash
  curl https://rclone.org/install.sh | sudo bash
  ```
- [ ] Configure Google Drive remote:
  ```bash
  rclone config
  # Follow prompts:
  # n (new remote) → name: gdrive → type: drive
  # client_id and client_secret: leave blank (use rclone defaults)
  # scope: 1 (full access)
  # Follow OAuth flow in browser
  # team_drive: leave blank
  ```
- [ ] Test access:
  ```bash
  rclone lsd gdrive:
  # Expected: lists your Google Drive root folders
  ```
- [ ] Create the offsite backup script:
  ```bash
  tee ~/backup/rclone-backup.sh << 'EOF'
  #!/usr/bin/env bash
  set -euo pipefail

  # Dump Postgres databases
  TIMESTAMP=$(date +%Y-%m-%d)
  DUMP_DIR="/tmp/db-dumps-${TIMESTAMP}"
  mkdir -p "${DUMP_DIR}"

  docker exec prod-postgres pg_dump -U appuser affine    > "${DUMP_DIR}/affine.sql"
  docker exec prod-postgres pg_dump -U appuser nextcloud > "${DUMP_DIR}/nextcloud.sql"

  # Sync to Google Drive (encrypted with rclone crypt — see note below)
  rclone sync "${DUMP_DIR}" gdrive:homeserver-backup/db-dumps \
    --log-level INFO

  rclone sync ~/stacks gdrive:homeserver-backup/stacks \
    --log-level INFO \
    --exclude ".env"     # never sync .env files with credentials

  # Cleanup
  rm -rf "${DUMP_DIR}"

  echo "rclone backup complete: $(date)"
  EOF
  chmod +x ~/backup/rclone-backup.sh
  ```
  > **Note:** For encrypted backups add an rclone crypt remote on top of gdrive. Run `rclone config` again, choose `crypt`, wrap the `gdrive:homeserver-backup` path, and use the crypt remote name in the script instead.
- [ ] Test run:
  ```bash
  ~/backup/rclone-backup.sh
  rclone ls gdrive:homeserver-backup/
  # Expected: db-dumps/ and stacks/ directories
  ```
- [ ] Create weekly systemd timer (Sunday 3am):
  ```bash
  sudo tee /etc/systemd/system/rclone-backup.service << 'EOF'
  [Unit]
  Description=rclone Google Drive Backup

  [Service]
  Type=oneshot
  User=aritra
  ExecStart=/home/aritra/backup/rclone-backup.sh
  StandardOutput=journal
  EOF

  sudo tee /etc/systemd/system/rclone-backup.timer << 'EOF'
  [Unit]
  Description=Weekly rclone Backup

  [Timer]
  OnCalendar=Sun *-*-* 03:00:00
  Persistent=true

  [Install]
  WantedBy=timers.target
  EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now rclone-backup.timer
  ```
- [ ] Commit everything:
  ```bash
  cd ~/stacks && git add . && git commit -m "feat: backup — borg local + rclone gdrive"
  cd ~/backup && git init && git add borg-backup.sh rclone-backup.sh && git commit -m "feat: backup scripts"
  ```

---

## Phase 10 — Dev stack (on-demand)

### Task 15: Dev containers (PostgreSQL, Elasticsearch)

**Files:**
- Create: `~/stacks/dev/docker-compose.yml`
- Create: `~/stacks/dev/.env`

- [ ] Create `.env`:
  ```bash
  tee ~/stacks/dev/.env << 'EOF'
  POSTGRES_USER=dev
  POSTGRES_PASSWORD=devpassword
  ELASTIC_PASSWORD=devpassword
  EOF
  ```
- [ ] Create `docker-compose.yml`:
  ```bash
  tee ~/stacks/dev/docker-compose.yml << 'EOF'
  # Start on demand: docker compose up -d
  # Stop when done:  docker compose down
  # Data persists in /mnt/nvme/dev/ between sessions

  networks:
    server-net:
      external: true

  services:

    postgres-dev:
      image: postgres:16-alpine
      container_name: dev-postgres
      ports:
        - "5432:5432"
      environment:
        POSTGRES_USER: ${POSTGRES_USER}
        POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      volumes:
        - /mnt/nvme/dev/postgres:/var/lib/postgresql/data
      restart: "no"
      networks:
        - server-net

    elasticsearch:
      image: docker.elastic.co/elasticsearch/elasticsearch:8.13.0
      container_name: dev-elasticsearch
      ports:
        - "9200:9200"
      environment:
        discovery.type: single-node
        ELASTIC_PASSWORD: ${ELASTIC_PASSWORD}
        xpack.security.enabled: "true"
      volumes:
        - /mnt/nvme/dev/elasticsearch:/usr/share/elasticsearch/data
      mem_limit: 2g
      restart: "no"
      networks:
        - server-net
  EOF
  ```
- [ ] Access from laptop via Tailscale:
  ```bash
  # PostgreSQL
  psql -h <server-ts-ip> -U dev -p 5432

  # Elasticsearch
  curl -u elastic:devpassword https://<server-ts-ip>:9200
  ```
- [ ] Commit:
  ```bash
  cd ~/stacks && git add dev/ && git commit -m "feat: dev stack — postgres, elasticsearch (on-demand)"
  ```

---

## Final verification checklist

Run after all phases are complete:

- [ ] All containers running: `docker ps --format "table {{.Names}}\t{{.Status}}"` — no `Exited` status
- [ ] DNS blocking works: `nslookup ads.google.com 192.168.1.100` → returns `0.0.0.0`
- [ ] Tailscale connected: `tailscale status` → shows server as connected
- [ ] All public subdomains reachable (on mobile data, not home WiFi):
  ```bash
  for sub in home affine drive photos media grafana status; do
    echo -n "${sub}.aritra.fyi: "
    curl -sI https://${sub}.aritra.fyi | head -1
  done
  ```
- [ ] Cloudflare Access blocks unauthenticated access: visit any subdomain in incognito → should see CF login
- [ ] Grafana dashboards show data for CPU, RAM, disk
- [ ] Discord alert fires: temporarily set CPU alert threshold to 1% to trigger test, reset after
- [ ] Uptime Kuma shows all services green at `https://status.aritra.fyi`
- [ ] Borg backup: `borg list /mnt/nvme/backup/borg` → shows at least one archive
- [ ] rclone backup: `rclone ls gdrive:homeserver-backup/` → shows directories

---

## Secrets checklist — store all of these safely (Bitwarden / 1Password)

| Secret | Where used |
|---|---|
| Borg passphrase | `~/backup/borg-backup.sh` |
| Cloudflare Tunnel token | `~/stacks/infra/.env` |
| Pi-hole web password | `~/stacks/infra/.env` |
| Immich DB password | `~/stacks/media/.env` |
| Nextcloud / AFFiNE DB password | `~/stacks/productivity/.env` |
| Grafana admin password | `~/stacks/monitoring/.env` |
| SSH private key | `~/.ssh/` on your laptop |
| rclone Google OAuth token | `~/.config/rclone/rclone.conf` |
