# backup scripts

Three scripts for manually backing up the oryx home server to an external HDD.

Run these on the **server** with an external backup drive plugged in.

---

## Scripts

| Script | Purpose |
|---|---|
| `check-mount.sh` | Verify backup drive is mounted, writable, and has enough space |
| `backup.sh` | Back up all server data to the external drive |
| `restore.sh` | Restore data from a previous backup |

---

## Setup

```bash
# On the server, after cloning this repo:
chmod +x ~/oryx/backup/*.sh

# Create the backup mount point
sudo mkdir -p /mnt/backup

# Plug in your external HDD, find it, mount it
lsblk -o NAME,SIZE,LABEL,FSTYPE,MOUNTPOINT
sudo mount /dev/sdX /mnt/backup   # replace sdX with your drive
```

---

## 1. Check mount

Always run this first to confirm the drive is ready.

```bash
./check-mount.sh
```

Output:
```
Checking backup drive at /mnt/backup
──────────────────────────────────────
  ✓  Drive mounted at /mnt/backup
  ✓  Filesystem: ext4
  ✓  Drive is writable
  ✓  312 GB free of 931 GB (66% used)
  ✓  3 existing backup(s) — latest: 2026-10-15_091234
──────────────────────────────────────
  Backup drive is ready.
```

Override defaults:
```bash
BACKUP_MOUNT=/mnt/external ./check-mount.sh   # different mount point
MIN_FREE_GB=100 ./check-mount.sh              # require 100 GB free
```

---

## 2. Backup

```bash
# Full backup (AFFiNE + Nextcloud + Immich originals + configs + DB dumps)
./backup.sh

# Database dumps only (very fast, ~seconds)
./backup.sh --only-db

# Dry run — see what would be backed up without writing anything
./backup.sh --dry-run
```

### What gets backed up

| Component | Source | Notes |
|---|---|---|
| AFFiNE | `/opt/affine/` | files + DB dump |
| Nextcloud | `/opt/nextcloud/` | files + DB dump |
| Immich | `/opt/immich/upload/` | originals + DB dump |
| Stack configs | `~/stacks/` | docker-compose files (`.env` excluded) |
| DB dumps | PostgreSQL | AFFiNE + Nextcloud + Immich |

> Jellyfin is not set up yet. When added later, its library will not be backed up (re-downloadable).

### Backup layout on external drive

```
/mnt/backup/
  backups/
    2026-09-15_143022/
      db-dumps/
        affine_2026-09-15_143022.sql
        nextcloud_2026-09-15_143022.sql
        immich_2026-09-15_143022.sql
      affine/
      nextcloud/
      immich/
      stacks/
      manifest.txt
  latest              ← symlink to most recent backup
  backup.log          ← running log of all backup runs
```

---

## 3. Restore

```bash
# List available backups
./restore.sh --list

# Restore everything from the latest backup
./restore.sh --backup latest

# Restore everything from a specific backup
./restore.sh --backup 2026-09-15_143022

# Restore only AFFiNE (files + database)
./restore.sh --backup latest --component affine

# Restore only Nextcloud
./restore.sh --backup latest --component nextcloud

# Restore only Immich originals
./restore.sh --backup latest --component immich

# Restore only database dumps (all DBs)
./restore.sh --backup latest --component db

# Restore only stack configs
./restore.sh --backup latest --component stacks
```

### Safety behaviour

- Asks for `YES` confirmation before overwriting anything
- Stops affected Docker services before restoring
- **Moves current data** to `*.pre-restore-TIMESTAMP` before overwriting — nothing is deleted
- Restarts services after restore
- Nextcloud automatically exits maintenance mode and rescans files

### After a restore

```bash
# Check services came back up
docker ps --format "table {{.Names}}\t{{.Status}}"

# Remove pre-restore snapshots when you're satisfied everything works
rm -rf /mnt/ssd/affine.pre-restore-*
rm -rf /mnt/ssd/nextcloud.pre-restore-*
```

---

## Recommended monthly routine

```bash
# 1. Plug in external backup HDD
# 2. Mount it
sudo mount /dev/sdX /mnt/backup

# 3. Check it's ready
./check-mount.sh

# 4. Run full backup
./backup.sh

# 5. Unmount when done
sudo umount /mnt/backup
# 6. Unplug drive
```
