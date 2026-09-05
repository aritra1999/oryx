# oryx — Home Server Setup Guide

**Hardware:** Dell Optiplex 7060 Micro · i5-8500T · 16 GB RAM  
**Drives:** 256 GB NVMe (boot + services) · 1 TB SATA SSD (internal 2.5" bay, app data)  
**Domain:** aritra.fyi (Cloudflare)

For the full implementation plan with checkboxes see:
`docs/superpowers/plans/2026-09-02-home-server.md`

---

## Before you start — what you need

- [ ] The Optiplex 7060 Micro
- [ ] 1 TB SATA SSD installed in the internal 2.5" bay
  (the NVMe is already installed — this is the data drive)
- [ ] Ubuntu 26.04 LTS Server ISO flashed to USB
- [ ] A Cloudflare account with `aritra.fyi` already managed there
- [ ] A Discord server with a webhook URL for alerts
- [ ] Your SSH public key ready (`~/.ssh/id_ed25519.pub` on your laptop)
- [ ] All passwords/secrets stored in a password manager **before** you start

---

## Phase 1 — Install Ubuntu

Boot from USB (F12 at POST), choose **Ubuntu Server (minimized)**:
- Install on the NVMe (the 256 GB M.2 drive)
- Username: `aritra`
- Enable OpenSSH server during install

First boot:
```bash
# Copy your SSH key to the server
ssh-copy-id aritra@<server-local-ip>

# Disable password login
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Firewall
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow ssh && sudo ufw enable

# Auto security updates
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades   # choose Yes
```

Set a static LAN IP (edit interface name from `ip link`):
```bash
sudo tee /etc/netplan/00-installer-config.yaml << 'EOF'
network:
  version: 2
  ethernets:
    enp3s0:
      dhcp4: no
      addresses: [192.168.1.100/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
EOF
sudo netplan apply
```
> Also reserve `192.168.1.100` in your router's DHCP settings.

---

## Phase 2 — Mount SATA SSD and create directories

```bash
# Find device names
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
# NVMe = nvme0n1 (already mounted as / — boot drive)
# SSD  = sda     (1 TB SATA SSD — app data drive)

# Format SATA SSD
sudo parted /dev/sda mklabel gpt
sudo parted /dev/sda mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L ssd /dev/sda1

# Mount point
sudo mkdir -p /mnt/ssd

# Get UUID and add to fstab
sudo blkid /dev/sda1
echo "UUID=<ssd-uuid>  /mnt/ssd  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
sudo mount -a

# Verify
df -h | grep ssd   # should show /mnt/ssd with ~1 TB
```

Create all service data directories:
```bash
# NVMe (services under /opt/)
sudo mkdir -p \
  /opt/pihole/etc /opt/pihole/dnsmasq \
  /opt/cloudflared \
  /opt/glance \
  /opt/portainer \
  /opt/monitoring/prometheus /opt/monitoring/grafana \
  /opt/docker

# SATA SSD (app data under /mnt/ssd/)
sudo mkdir -p \
  /mnt/ssd/affine/data /mnt/ssd/affine/postgres \
  /mnt/ssd/nextcloud/data /mnt/ssd/nextcloud/config /mnt/ssd/nextcloud/apps \
  /mnt/ssd/immich/upload /mnt/ssd/immich/postgres /mnt/ssd/immich/cache /mnt/ssd/immich/model-cache

sudo chown -R 1000:1000 /opt /mnt/ssd
```

---

## Phase 3 — Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker aritra
# log out and back in

# Point Docker data-root at /opt/docker (on the SSD)
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/opt/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker

# Verify
docker info | grep "Docker Root Dir"   # should show /opt/docker

# Shared network all stacks use
docker network create server-net

# Stacks directory
mkdir -p ~/stacks/{infra,media,productivity,monitoring,dev}
cd ~/stacks && git init && git commit --allow-empty -m "chore: init"
```

---

## Phase 4 — Tailscale (install first — you'll need remote access)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
# open the URL it prints, authorize on your phone/laptop
tailscale ip -4   # note this — it's your permanent remote address
sudo systemctl enable --now tailscaled
```

Test from your laptop:
```bash
ssh aritra@<tailscale-ip>   # should connect without password
```

---

## Phase 5 — Infrastructure stack

`~/stacks/infra/.env`:
```bash
TZ=Europe/Berlin
PIHOLE_PASSWORD=<strong_password>
CLOUDFLARE_TUNNEL_TOKEN=              # fill in after Phase 7
```

`~/stacks/infra/docker-compose.yml`:
```yaml
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
      - "8053:80/tcp"
    environment:
      TZ: ${TZ}
      WEBPASSWORD: ${PIHOLE_PASSWORD}
    volumes:
      - /opt/pihole/etc:/etc/pihole
      - /opt/pihole/dnsmasq:/etc/dnsmasq.d
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
      WATCHTOWER_SCHEDULE: "0 0 3 * * *"
      WATCHTOWER_CLEANUP: "true"
      TZ: ${TZ}
    restart: unless-stopped

  glance:
    image: glanceapp/glance:latest
    container_name: glance
    ports:
      - "8080:8080"
    volumes:
      - /opt/glance:/app/assets
      - /opt/glance/glance.yml:/app/glance.yml:ro
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
      - /opt/portainer:/data
    restart: unless-stopped
```

Create a basic Glance config at `/opt/glance/glance.yml` (edit URLs once set up):
```yaml
pages:
  - name: Home
    columns:
      - size: full
        widgets:
          - type: bookmarks
            groups:
              - title: Media
                links:
                  - { title: Immich, url: "https://photos.aritra.fyi" }
              - title: Productivity
                links:
                  - { title: AFFiNE, url: "https://notes.aritra.fyi" }
                  - { title: Nextcloud, url: "https://drive.aritra.fyi" }
              - title: Monitoring
                links:
                  - { title: Grafana, url: "https://grafana.aritra.fyi" }
```

```bash
cd ~/stacks/infra
docker compose up -d pihole glance watchtower   # cloudflared starts after Phase 7
```

**Set router primary DNS to `192.168.1.100`** (your server's LAN IP). Pi-hole is now the DNS resolver for your entire home network.

---

## Phase 6 — Media stack (Immich only)

`~/stacks/media/.env`:
```bash
TZ=Europe/Berlin
IMMICH_DB_USER=immich
IMMICH_DB_PASSWORD=<strong_password>
```

`~/stacks/media/docker-compose.yml`:
```yaml
networks:
  server-net:
    external: true

services:

  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich-server
    ports:
      - "2283:2283"
    volumes:
      - /mnt/ssd/immich/upload:/usr/src/app/upload
      - /mnt/ssd/immich/cache:/mnt/cache
    environment:
      TZ: ${TZ}
      DB_HOSTNAME: immich-postgres
      DB_USERNAME: ${IMMICH_DB_USER}
      DB_PASSWORD: ${IMMICH_DB_PASSWORD}
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: immich-redis
    depends_on: [immich-postgres, immich-redis]
    restart: unless-stopped
    networks:
      - server-net

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    container_name: immich-ml
    volumes:
      - /mnt/ssd/immich/model-cache:/cache
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
    volumes:
      - /mnt/ssd/immich/postgres:/var/lib/postgresql/data
    restart: unless-stopped
    networks:
      - server-net
```

```bash
# Verify Intel QSV is available first
sudo apt install -y intel-media-va-driver-non-free vainfo
vainfo   # should list H.264/H.265 encode/decode entries

cd ~/stacks/media
docker compose up -d

# Add libraries: Movies → /media/movies, TV Shows → /media/shows
# Enable Hardware Acceleration: Playback → Transcoding → Intel QuickSync
```

---

## Phase 7 — Cloudflare Tunnel + Access

**On your laptop** (one-time setup):
```bash
brew install cloudflare/cloudflare/cloudflared
cloudflared tunnel login          # opens browser, authorize
cloudflared tunnel create oryx   # note the tunnel ID

# Create DNS records for all subdomains
for sub in home affine drive photos media grafana status; do
  cloudflared tunnel route dns oryx ${sub}.aritra.fyi
done

# Get the token to paste into the server
cloudflared tunnel token oryx
```

**On the server**, paste the token into `~/stacks/infra/.env`:
```bash
CLOUDFLARE_TUNNEL_TOKEN=<paste token here>
```

Create the tunnel config on the server:
```bash
sudo mkdir -p /opt/cloudflared
sudo tee /opt/cloudflared/config.yml << 'EOF'
tunnel: <your-tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json

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
  - service: http_status:404
EOF

cd ~/stacks/infra
docker compose up -d cloudflared
docker logs cloudflared   # should show 4 connections registered
```

**Cloudflare Access** — in https://one.dash.cloudflare.com:
1. Access → Applications → Add → Self-hosted
2. Repeat for each subdomain: name it, set the domain, create a policy allowing your email via Google/GitHub OAuth
3. Session duration: 24 hours

---

## Phase 8 — Productivity stack

`~/stacks/productivity/init-db.sh`:
```bash
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE affine;
    CREATE DATABASE nextcloud;
    GRANT ALL PRIVILEGES ON DATABASE affine TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE nextcloud TO $POSTGRES_USER;
EOSQL
```

`~/stacks/productivity/.env`:
```bash
TZ=Europe/Berlin
POSTGRES_USER=appuser
POSTGRES_PASSWORD=<strong_password>
AFFINE_ADMIN_EMAIL=you@example.com
AFFINE_ADMIN_PASSWORD=<strong_password>
NEXTCLOUD_ADMIN_USER=aritra
NEXTCLOUD_ADMIN_PASSWORD=<strong_password>
```

`~/stacks/productivity/docker-compose.yml`:
```yaml
networks:
  server-net:
    external: true

services:

  postgres:
    image: postgres:16-alpine
    container_name: prod-postgres
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /opt/affine/postgres:/var/lib/postgresql/data
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

  affine:
    image: ghcr.io/toeverything/affine-graphql:stable
    container_name: affine
    ports:
      - "3000:3010"
    volumes:
      - /opt/affine/data:/root/.affine/storage
    environment:
      REDIS_SERVER_HOST: redis
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/affine
      AFFINE_ADMIN_EMAIL: ${AFFINE_ADMIN_EMAIL}
      AFFINE_ADMIN_PASSWORD: ${AFFINE_ADMIN_PASSWORD}
    depends_on: [postgres, redis]
    restart: unless-stopped
    networks:
      - server-net

  nextcloud:
    image: nextcloud:29-apache
    container_name: nextcloud
    ports:
      - "8081:80"
    volumes:
      - /opt/nextcloud/data:/var/www/html/data
      - /opt/nextcloud/config:/var/www/html/config
      - /opt/nextcloud/apps:/var/www/html/custom_apps
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: nextcloud
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: "drive.aritra.fyi localhost"
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: https://drive.aritra.fyi
    depends_on: [postgres, redis]
    restart: unless-stopped
    networks:
      - server-net
```

```bash
chmod +x ~/stacks/productivity/init-db.sh
cd ~/stacks/productivity
docker compose up -d
```

---

## Phase 9 — Monitoring stack

`~/stacks/monitoring/prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s

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
```

`~/stacks/monitoring/.env`:
```bash
TZ=Europe/Berlin
GRAFANA_ADMIN_PASSWORD=<strong_password>
```

`~/stacks/monitoring/docker-compose.yml`:
```yaml
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
      - /opt/monitoring/prometheus:/prometheus
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
      - /opt/docker:/var/lib/docker:ro
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
      - /opt/monitoring/grafana:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SERVER_ROOT_URL: https://grafana.aritra.fyi
    restart: unless-stopped
    networks:
      - server-net
```

```bash
cd ~/stacks/monitoring
docker compose up -d
```

**Grafana setup** (http://localhost:3001):
1. Connections → Data Sources → Prometheus → URL: `http://prometheus:9090` → Save & Test
2. Dashboards → Import → `1860` (Node Exporter Full)
3. Dashboards → Import → `14282` (cAdvisor)
4. Alerting → Contact Points → Add Discord webhook → test it
5. Create alert rules for CPU > 85%, RAM > 88%, disk > 82%, container down

1. Add HTTP monitors for all 7 public subdomains, interval 60s
2. Add Discord notification to all monitors
3. Create public status page

---

## Phase 10 — Backup

Backup is manual — use the scripts in `backup/` when you plug in an external drive.

```bash
# Make scripts executable (once)
chmod +x ~/oryx/backup/*.sh

# Create the mount point
sudo mkdir -p /mnt/backup

# Each time you want to back up:
sudo mount /dev/sdX /mnt/backup   # replace sdX with your backup drive
~/oryx/backup/check-mount.sh
~/oryx/backup/backup.sh --skip-media   # fast: AFFiNE + Nextcloud + Immich + configs
# or: ~/oryx/backup/backup.sh          # full: includes Immich originals
sudo umount /mnt/backup
```

rclone Google Drive (weekly offsite):
```bash
curl https://rclone.org/install.sh | sudo bash
rclone config   # follow prompts, add Google Drive remote named "gdrive"
```

`~/backup/rclone-backup.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DUMP=/tmp/db-dumps-$(date +%Y-%m-%d)
mkdir -p "$DUMP"
docker exec prod-postgres pg_dump -U appuser affine    > "$DUMP/affine.sql"
docker exec prod-postgres pg_dump -U appuser nextcloud > "$DUMP/nextcloud.sql"
docker exec immich-postgres pg_dump -U immich immich   > "$DUMP/immich.sql"
rclone sync "$DUMP" gdrive:homeserver-backup/db-dumps
rclone sync ~/stacks gdrive:homeserver-backup/stacks --exclude ".env"
rm -rf "$DUMP"
```

```bash
chmod +x ~/backup/rclone-backup.sh

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

---

## Verify everything works

```bash
# All containers running
docker ps --format "table {{.Names}}\t{{.Status}}"

# DNS blocking
nslookup doubleclick.net 192.168.1.100   # should return 0.0.0.0

# All public subdomains (run from mobile data / different network)
for sub in home affine drive photos media grafana status; do
  echo -n "${sub}.aritra.fyi: "
  curl -sI https://${sub}.aritra.fyi | head -1
done
```

---

## Quick reference — all ports

| Service | URL / access | Port |
|---|---|---|
| Glance | https://home.aritra.fyi | 8080 |
| AFFiNE | https://notes.aritra.fyi | 3000 |
| Nextcloud | https://drive.aritra.fyi | 8081 |
| Immich | https://photos.aritra.fyi | 2283 |
| Grafana | https://grafana.aritra.fyi | 3001 |
| Pi-hole admin | http://server-ts-ip:8053/admin | 8053 |
| SSH | ssh aritra@server-ts-ip | 22 |
| PostgreSQL (dev) | server-ts-ip | 5432 |
