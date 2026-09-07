# Portainer via Cloudflare Access

**Date:** 2026-09-07  
**Status:** Approved

## Goal

Expose Portainer at `portainer.aritra.fyi` behind Cloudflare Access (email OTP), so it is reachable remotely without requiring Tailscale. Update Glance to reflect the new public URL.

## Scope

Three files change plus two manual steps in the Cloudflare dashboard.

## Changes

### 1. `stacks/infra/cloudflared/config.yml`

Add one ingress rule before the catch-all:

```yaml
- hostname: portainer.aritra.fyi
  service: http://portainer:9000
```

Portainer is already on `server-net`; cloudflared reaches it by container name, consistent with all other services.

### 2. DNS record (one-time command on server)

```bash
cloudflared tunnel route dns oryx portainer.aritra.fyi
```

Creates a CNAME in Cloudflare DNS pointing to the tunnel.

### 3. Restart cloudflared

```bash
docker compose -f ~/stacks/infra/docker-compose.yml restart cloudflared
```

### 4. CF Access application (manual — Cloudflare Zero Trust dashboard)

- Access → Applications → Add → Self-hosted
- Application name: `Portainer`
- Domain: `portainer.aritra.fyi`
- Policy: allow `your-email` via email OTP
- Session duration: 24 hours

Same configuration as the existing `home` and `grafana` applications.

### 5. `stacks/infra/config/glance.yml`

Two edits:

**Monitor widget** — add Portainer alongside the existing services:
```yaml
- title: Portainer
  url: https://portainer.aritra.fyi
  icon: si:portainer
```

**Admin bookmarks** — update URL from Tailscale to public, rename the group:
- URL: `http://100.106.157.117:9000` → `https://portainer.aritra.fyi`
- Group title: `Internal (Tailscale)` → `Admin`

## What does not change

- Portainer's `9000:9000` port binding stays, so it remains accessible on Tailscale at `100.106.157.117:9000` as a fallback.
- No other services are affected.
- Portainer's own username/password login is the second auth layer after CF Access.

## Verification

After applying:
1. `docker logs cloudflared` — should show 4 connections, no errors
2. Open `https://portainer.aritra.fyi` from mobile data — CF Access email OTP prompt appears
3. After OTP, Portainer login screen loads
4. Glance monitor widget shows Portainer green
5. Glance Admin bookmark navigates to `https://portainer.aritra.fyi`
