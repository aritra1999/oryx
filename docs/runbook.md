# oryx — Operations Runbook

Quick reference for everything that can go wrong and how to fix it.
Assumes the server is running and you have SSH access (via Tailscale or LAN).

**Server LAN IP:** `192.168.1.100`  
**Server Tailscale IP:** run `tailscale ip -4` once and note it here: `_______`  
**SSH:** `ssh aritra@<tailscale-ip>`  
**Portainer:** `http://<tailscale-ip>:9000` — web UI for all containers

---

## 0. Daily commands you'll actually use

```bash
# See all running containers and their status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Check disk usage
df -h /  /mnt/ssd  /mnt/hdd

# Tail logs for a specific container
docker logs -f jellyfin
docker logs -f --tail 100 immich-server

# Restart a single service
docker restart <container-name>

# Restart a whole stack
cd ~/stacks/media && docker compose restart

# Pull latest images and recreate containers
cd ~/stacks/media && docker compose pull && docker compose up -d
```

---

## 1. A service is down or not responding

**Symptom:** A subdomain returns an error, or Uptime Kuma fires a Discord alert.

```bash
# 1. Which container is the problem?
docker ps -a --format "table {{.Names}}\t{{.Status}}"
# look for anything showing "Exited" or "Restarting"

# 2. Read its logs
docker logs --tail 50 <container-name>

# 3. Restart it
docker restart <container-name>

# 4. If restart doesn't help — recreate it
cd ~/stacks/<stack-name>
docker compose up -d --force-recreate <service-name>

# 5. If the whole stack is broken
cd ~/stacks/<stack-name>
docker compose down && docker compose up -d
```

**Common causes:**
- Out of memory → check `docker stats` or Grafana RAM panel
- Crashed on startup → check logs for error, may need config fix
- Dependency not ready yet → `depends_on` doesn't guarantee readiness, just start order

---

## 2. Entire server is unreachable

**Symptom:** Can't SSH in, all public subdomains down, Discord fires everything.

### Check if it's a power issue (you're at home)
Look at the machine — is it on? The Optiplex has a power LED.
- **Off:** press power button. If it doesn't come back, check the power cable and the wall socket.
- **On but unresponsive:** hold power button 5 seconds to force off, then press again.

### Check if it's a network issue (you're remote)
```bash
# Can Tailscale see the server?
tailscale ping <tailscale-ip>

# If no response, the server is off or Tailscale has dropped.
# Tailscale auto-reconnects on boot — it may just need a minute after a power cycle.
```

### After the server comes back up
All containers have `restart: unless-stopped` so they start automatically. Wait 2-3 minutes after boot, then verify:
```bash
ssh aritra@<tailscale-ip>
docker ps | grep -c "Up"   # should match expected number of containers
```

If containers didn't come back:
```bash
# Start all stacks manually
for stack in infra media productivity monitoring; do
  cd ~/stacks/$stack && docker compose up -d
done
```

### If you're remote and the server is physically off (power cut, etc.)
You can't restart it remotely unless you set up Wake-on-LAN or have someone nearby.
- Ask someone at home to press the power button
- The server will auto-restart all services on boot

---

## 3. Can't SSH in remotely (Tailscale not working)

**Symptom:** `ssh aritra@tailscale-ip` times out, Tailscale shows server as offline.

### From your device
```bash
tailscale status                  # is the server listed?
tailscale ping <tailscale-ip>     # does it respond?
```

### Fix 1 — Tailscale daemon crashed on the server (you have other access)
```bash
# If you can reach the server on LAN:
ssh aritra@192.168.1.100
sudo systemctl restart tailscaled
sudo tailscale up --ssh
```

### Fix 2 — Tailscale auth expired
Tailscale keys expire after 90 days by default (you can set them to not expire in the admin console).
```bash
# On the server (via LAN access):
sudo tailscale up   # re-authenticate via the URL it prints
```

### Fix 3 — You're locked out completely (no LAN access, no Tailscale)
The Cloudflare Tunnel is still running as long as the server is on. You can SSH through it:
```bash
# On your laptop, create an SSH-over-Cloudflare Tunnel:
cloudflared access ssh --hostname ssh.aritra.bio
```
This requires adding an SSH application in Cloudflare Access first. Set it up proactively:
- Cloudflare Zero Trust → Access → Applications → Add → Self-hosted
- Type: SSH, hostname: `ssh.aritra.bio`
- Then add a DNS route: `cloudflared tunnel route dns oryx ssh.aritra.bio`

### Prevention
In Tailscale admin console (https://login.tailscale.com/admin):
- Set key expiry to **Never expire** for the server node
- Enable Tailscale SSH so it's always available even if the daemon needs reauthentication

---

## 4. Cloudflare Tunnel down (public subdomains unreachable)

**Symptom:** All `*.aritra.bio` return errors but Tailscale/LAN works fine.

```bash
# Check cloudflared container
docker logs cloudflared --tail 30

# Restart it
docker restart cloudflared

# Verify it reconnects (should show "Connection registered")
docker logs -f cloudflared
```

### If the token has expired
```bash
# On your laptop:
cloudflared tunnel token oryx   # generate a new token

# On the server:
# Edit ~/stacks/infra/.env, replace CLOUDFLARE_TUNNEL_TOKEN value
# Then:
cd ~/stacks/infra
docker compose up -d --force-recreate cloudflared
```

### If Cloudflare's edge is having issues
Check https://www.cloudflarestatus.com — if it's a Cloudflare outage, nothing to do but wait.

---

## 5. Pi-hole broke my home internet (DNS broken)

**Symptom:** Devices on the home network can't resolve any domains, internet is down for everyone.

### Immediate fix — bypass Pi-hole on the affected device
On the device that's broken, manually set DNS to `1.1.1.1` in network settings.

### Fix Pi-hole on the server
```bash
# Check if Pi-hole is running
docker ps | grep pihole

# If it's down, restart it
docker restart pihole

# If it's up but blocking too aggressively (false positives):
# Go to http://<tailscale-ip>:8053/admin → Whitelist the domain
```

### Emergency — disable Pi-hole as router DNS
Log into your router admin UI → DHCP settings → change primary DNS back to `1.1.1.1`.
Now all devices bypass Pi-hole until you fix the issue and re-enable it.

### Pi-hole container won't start
```bash
cd ~/stacks/infra
docker compose logs pihole
# Common fix: port 53 is in use by systemd-resolved
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
docker compose up -d pihole
```

---

## 6. Disk full

### Check which disk is full
```bash
df -h
# look for any filesystem at 90%+

# Find what's using space on NVMe (/)
du -sh /mnt/nvme/* | sort -hr | head -20

# Find what's using space on SATA SSD
du -sh /mnt/ssd/* | sort -hr | head -20
```

### NVMe full — most likely culprits

**Docker images (even though they're on SATA SSD, some cache stays on NVMe):**
```bash
docker system df             # see how much Docker is using
docker image prune -a        # remove all unused images
docker system prune --volumes  # nuclear option — removes stopped containers, unused networks, volumes
```

**Borg backup exceeded 64 GB:**
```bash
borg info /mnt/nvme/backup/borg
# If too large, manually prune more aggressively:
borg prune --keep-daily=3 --keep-weekly=2 --keep-monthly=1 /mnt/nvme/backup/borg
borg compact /mnt/nvme/backup/borg
```

**Prometheus TSDB (set to 14 GB retention):**
```bash
# If it somehow grew beyond 15 GB:
docker exec prometheus promtool tsdb analyze /prometheus
# Reduce retention in docker-compose.yml:
# --storage.tsdb.retention.size=10GB
```

**Container logs (capped at 10 MB × 3 = 30 MB per container — shouldn't be a problem):**
```bash
# Check log sizes
du -sh /mnt/ssd/docker/containers/*/
```

### SATA SSD full

**Docker images (`/mnt/ssd/docker`):**
```bash
docker image prune -a    # removes images not used by any container
docker system df -v      # detailed view
```

**AFFiNE data grew large:**
```bash
du -sh /mnt/ssd/affine/data/
# Nothing to prune automatically — you'd need to delete old blobs in AFFiNE's UI
```

**Nextcloud data full (128 GB cap):**
```bash
du -sh /mnt/ssd/nextcloud/data/
# Delete files from within the Nextcloud web UI
# Or run: docker exec nextcloud php occ files:cleanup
```

### HDD full

```bash
du -sh /mnt/hdd/jellyfin/movies/* | sort -hr | head -20
# Delete files you don't need via the Jellyfin UI or directly from /mnt/hdd/
```

---

## 7. Container broken after an update

**Symptom:** Watchtower updated a container overnight and now it doesn't work.

```bash
# Find which image was recently updated
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

# Read the container's logs for errors
docker logs --tail 50 <container-name>
```

### Roll back to previous image version
```bash
# Find the previous image tag on Docker Hub (e.g., jellyfin/jellyfin:10.9.x)
# Edit the image tag in ~/stacks/<stack>/docker-compose.yml from "latest" to the specific version

# Then recreate the container with the old image
cd ~/stacks/<stack>
docker compose up -d --force-recreate <service-name>
```

### Prevent Watchtower from updating a specific container
Add this label to the container in docker-compose.yml:
```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=false"
```

---

## 8. Can't log into Cloudflare Access (locked out)

**Symptom:** You can't authenticate to any public subdomain — the Cloudflare Access page never lets you through.

1. Check you're using the correct email (the one you added to the Access policy)
2. Check the Google/GitHub account is accessible
3. **Bypass via Tailscale:** all services are still accessible on their host ports via Tailscale:
   - AFFiNE: `http://<tailscale-ip>:3000`
   - Nextcloud: `http://<tailscale-ip>:8081`
   - Jellyfin: `http://<tailscale-ip>:8096`
   - etc.
4. Fix the policy in Cloudflare Zero Trust dashboard from a browser: https://one.dash.cloudflare.com

---

## 9. Restore from Borg backup

```bash
# List available archives
borg list /mnt/nvme/backup/borg

# Restore a specific archive to a temp location
mkdir -p /tmp/restore
borg extract /mnt/nvme/backup/borg::<archive-name> --target /tmp/restore

# Example: restore just the AFFiNE data
borg extract /mnt/nvme/backup/borg::<archive-name> mnt/ssd/affine --target /tmp/restore

# Stop the affected service, swap in the restored data, restart
cd ~/stacks/productivity && docker compose stop affine
cp -r /tmp/restore/mnt/ssd/affine/data /mnt/ssd/affine/data-backup   # keep old copy
rsync -av /tmp/restore/mnt/ssd/affine/data/ /mnt/ssd/affine/data/
docker compose up -d affine
```

### Restore Nextcloud from Borg
```bash
# 1. Enable maintenance mode (prevents DB writes during restore)
docker exec nextcloud php occ maintenance:mode --on

# 2. Restore files
borg extract /mnt/nvme/backup/borg::<archive-name> mnt/ssd/nextcloud

# 3. Restore database
docker exec -i prod-postgres psql -U appuser nextcloud < nextcloud-dump.sql

# 4. Disable maintenance mode
docker exec nextcloud php occ maintenance:mode --off
docker exec nextcloud php occ files:scan --all
```

---

## 10. Database issues

### Postgres won't start
```bash
docker logs prod-postgres --tail 50
# Common issue: data directory corruption
# If data is corrupt, you'll need to restore from Borg backup (see section 9)
```

### Immich database issues
```bash
docker logs immich-postgres --tail 50

# Run Immich's built-in DB check
docker exec immich-server node /usr/src/app/dist/main database --check
```

### Manually connect to a database (via Tailscale from your laptop)
```bash
# Start the dev Postgres stack if you need a psql client:
cd ~/stacks/dev && docker compose up -d postgres-dev

# Connect to the productivity Postgres
docker exec -it prod-postgres psql -U appuser -d affine
docker exec -it prod-postgres psql -U appuser -d nextcloud
```

---

## 11. Updating services manually (without Watchtower)

When you want to update a specific service on your own schedule:

```bash
cd ~/stacks/<stack>

# Pull latest images
docker compose pull

# Recreate only updated containers (leaves others running)
docker compose up -d

# Verify the updated container is healthy
docker ps | grep <container-name>
docker logs --tail 20 <container-name>
```

### Update all stacks at once
```bash
for stack in infra media productivity monitoring; do
  echo "=== Updating $stack ==="
  cd ~/stacks/$stack
  docker compose pull
  docker compose up -d
done
```

### Update Ubuntu packages
```bash
sudo apt update && sudo apt upgrade -y
sudo reboot   # only if there's a kernel update (check: ls /var/run/reboot-required)
```

---

## 12. Drive failure

### SATA SSD (internal bay) fails

All Docker containers will be broken (their data-root and most app data is here).

```bash
# Check if it's still mounted
df -h | grep ssd
lsblk

# Plug it back in and remount
sudo mount -a
docker restart $(docker ps -q)   # restart all containers
```

If the drive is dead:
- AFFiNE and Nextcloud data is in Borg backup (restore: see section 9)
- Docker images can be re-pulled (`docker compose up -d` in each stack)
- Replace the drive, reformat, remount at `/mnt/ssd`, restore from Borg

### HDD (USB-C enclosure) fails or is disconnected

Jellyfin and Immich originals are on this drive. No automated backup for media.

```bash
df -h | grep hdd
lsblk
# plug back in if accidentally disconnected
sudo mount -a
```

If the drive dies:
- Jellyfin library is re-downloadable (use the media-acquisition stack)
- Immich originals: only recoverable if you have a separate copy elsewhere
- Replace the drive, reformat, remount at `/mnt/hdd`, rebuild libraries

### SMART monitoring (proactive health check)

Run periodically to catch drive failures early:
```bash
sudo apt install -y smartmontools
sudo smartctl -H /dev/sda    # HDD
sudo smartctl -H /dev/nvme0  # NVMe
# "PASSED" = healthy, any other result = investigate
```

---

## 13. Jellyfin-specific issues

### Media not showing up
```bash
# Trigger a library scan
curl -X POST http://localhost:8096/Library/Refresh \
  -H "X-Emby-Authorization: MediaBrowser Token=<your-api-key>"

# Or from the Jellyfin UI: Dashboard → Libraries → Scan All Libraries
```

### Hardware transcoding not working (QSV)
```bash
# Verify the iGPU is accessible from the container
docker exec jellyfin ls /dev/dri/
# Should show: card0  renderD128

# Check Jellyfin transcode logs
docker logs jellyfin 2>&1 | grep -i "qsv\|vaapi\|error"
```

### Jellyfin using too much CPU (software transcoding instead of QSV)
In Jellyfin UI → Dashboard → Playback → Transcoding:
- Enable: Allow Intel QuickSync H264 encoding
- Enable: Allow Intel QuickSync HEVC encoding
- VAAPI device: `/dev/dri/renderD128`

---

## 14. Immich-specific issues

### ML/face recognition not working
```bash
docker logs immich-ml --tail 30
docker restart immich-ml
```

### Photos not uploading / stuck
```bash
docker logs immich-server --tail 50

# Check Redis (message queue)
docker exec immich-redis redis-cli ping   # should return PONG

# Check Postgres
docker exec immich-postgres pg_isready    # should return "accepting connections"
```

### Re-run ML jobs on existing photos
Immich UI → Administration → Jobs → All Jobs → Run

---

## 15. Nextcloud-specific issues

### Nextcloud in maintenance mode (can't log in)
```bash
docker exec nextcloud php occ maintenance:mode --off
```

### Nextcloud is slow
```bash
# Clear cache
docker exec nextcloud php occ cache:flush

# Run background jobs manually
docker exec nextcloud php occ background:cron
```

### Files out of sync (client shows wrong state)
```bash
docker exec nextcloud php occ files:scan --all
```

---

## 16. Backup issues

### Borg backup failed
```bash
# Check last backup status
sudo journalctl -u borg-backup.service --since yesterday

# Test backup manually
~/backup/borg-backup.sh

# If Borg says "repository already locked" (crashed mid-backup):
borg break-lock /mnt/nvme/backup/borg
```

### rclone backup failed
```bash
sudo journalctl -u rclone-backup.service --since "7 days ago"

# Test manually
~/backup/rclone-backup.sh

# If Google OAuth token expired, re-authenticate:
rclone config reconnect gdrive:
```

---

## 17. Remote maintenance checklist (when you're not home)

When something goes wrong and you're in India / another country:

1. **Can you reach the server?**
   - Try Tailscale first: `tailscale ping <server-ip>`
   - If Tailscale fails, try SSH over Cloudflare Tunnel: `cloudflared access ssh --hostname ssh.aritra.bio`
   - If both fail: server is likely off or internet at home is down — ask someone to check physically

2. **Is it one service or everything?**
   - Check Uptime Kuma status page: https://status.aritra.bio
   - One service down → likely a container crash (section 1)
   - Everything down → power or network issue (section 2)

3. **Before doing anything destructive:** take a Borg backup snapshot
   ```bash
   ~/backup/borg-backup.sh
   ```

4. **Quick triage commands:**
   ```bash
   # System health
   uptime && free -h && df -h

   # Container status
   docker ps -a --format "table {{.Names}}\t{{.Status}}"

   # Recent errors across all containers
   docker ps -q | xargs -I{} docker logs --tail 20 {} 2>&1 | grep -i "error\|fatal\|panic"
   ```

5. **If you need to reboot:**
   ```bash
   # Make sure Tailscale and Docker are set to start on boot (they should be)
   sudo systemctl is-enabled tailscaled docker   # both should show "enabled"
   sudo reboot
   # Wait 3-4 minutes then reconnect
   ```

---

## Useful one-liners

```bash
# RAM usage by container (top 5)
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -hr | head -5

# Disk usage summary
df -h / /mnt/ssd /mnt/hdd

# Check when each container last restarted
docker inspect --format='{{.Name}} started: {{.State.StartedAt}}' $(docker ps -q)

# Prune unused Docker resources (safe — doesn't touch running containers)
docker system prune -f

# Show all failed systemd units
systemctl --failed

# Check Tailscale connection health
tailscale status && tailscale netcheck

# Force Borg backup right now
sudo systemctl start borg-backup.service

# Watch real-time container logs across all stacks
docker ps --format "{{.Names}}" | xargs -P4 -I{} docker logs -f --tail 0 {} 2>&1 | grep -v "^$"
```
