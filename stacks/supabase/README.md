# Supabase Stack

Self-hosted Supabase on oryx.

## First-time setup

```bash
bash ~/stacks/supabase/init.sh
```

This clones the official Supabase docker files, generates all secrets, and creates `.env`.

## Start

```bash
cd ~/stacks/supabase
docker compose -f docker-compose.supabase.yml up -d
```

## Access

- **Studio (admin):** `http://192.168.2.100:8000` or `https://supabase.aritra.fyi`
- **API:** `https://supabase.aritra.fyi`
- Login with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`

## Ports

| Service | Port |
|---|---|
| API Gateway (Kong/Envoy) | 8000 |
| Postgres (direct) | 5432 |
| Pooler (transaction) | 6543 |

## Update

```bash
cd ~/stacks/supabase
docker compose -f docker-compose.supabase.yml pull
docker compose -f docker-compose.supabase.yml up -d
```
