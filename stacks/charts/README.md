# charts stack — Budibase + scheduler

General-purpose Budibase instance at `charts.aritra.fyi`.
The finance tracker is the first app; create more apps in the same instance at will.

## Directory layout

```
stacks/charts/
  docker-compose.yml      — Budibase + scheduler containers
  .env.example            — copy to .env and fill in
  seed/
    setup.py              — creates all tables and inserts data (idempotent)
    data.json             — YOUR holdings/accounts — fill this in
    requirements.txt
  scheduler/
    Dockerfile
    crontab               — 4 jobs at fixed UTC times
    bb_client.py          — shared Budibase API helpers
    price_refresh.py      — 17:00 UTC: update current_price on all Holdings
    recurring.py          — 06:00 UTC: log SIPs and employer vests
    fx_rates.py           — 08:00 UTC: update EUR/INR from Yahoo Finance
    net_worth.py          — 18:00 UTC: write a NetWorthSnapshots row
```

## Bootstrap sequence

### 1. Generate secrets and configure `.env`

```bash
cd stacks/charts
cp .env.example .env

# Fill in the admin credentials, then generate random secrets:
for var in BB_JWT_SECRET BB_MINIO_ACCESS_KEY BB_MINIO_SECRET_KEY \
           BB_REDIS_PASSWORD BB_COUCHDB_PASSWORD; do
  echo "$var=$(openssl rand -hex 32)"
done >> .env
# Then open .env and set BB_COUCHDB_USER=budibase
```

### 2. Start Budibase

```bash
docker compose up -d budibase
```

Wait ~30 seconds for Budibase to initialise, then open `https://charts.aritra.fyi`
(or `http://oryx-tailscale-ip:10000` before Cloudflare DNS propagates).

### 3. Create your first app and get credentials

1. Log in with the admin email/password from `.env`
2. Click **Create new app** → name it `Finance` (or anything)
3. Note the **App ID** from the browser URL:
   `https://charts.aritra.fyi/builder/app/app_dev_XXXX` → copy `app_dev_XXXX`
4. Click your avatar (top right) → **View API key** → generate and copy the key
5. Add both to `.env`:

```ini
BB_API_KEY=your_api_key
BB_APP_ID=app_dev_XXXX      # use app_XXXX (without _dev_) for the published app
```

### 4. Fill in your data

```bash
cp seed/data.json.example seed/data.json   # gitignored — safe to put real values here
```

Edit `seed/data.json` with your real accounts, holdings, and recurring investments.
Replace the example rows; the AMFI scheme codes for your MFs and Yahoo Finance
tickers for your stocks are the key fields to get right.

**Finding AMFI scheme codes**: https://www.amfiindia.com/nav-history-download
**Finding Yahoo Finance tickers**: search your stock on finance.yahoo.com and copy
the ticker from the URL (e.g. `RELIANCE.NS`, `EXW1.DE`).

### 5. Run the seed script

```bash
cd seed
pip install -r requirements.txt
export $(grep -v '^#' ../.env | xargs)
python setup.py
```

The script prints each table ID — save them for reference if needed.
It is **idempotent**: re-running it skips tables and rows that already exist.

### 6. Start the scheduler

```bash
cd ..
docker compose up -d scheduler
```

Check logs:
```bash
docker logs -f budibase-scheduler
```

You can also run any job manually to verify it works:
```bash
docker exec budibase-scheduler python /app/price_refresh.py
docker exec budibase-scheduler python /app/fx_rates.py
docker exec budibase-scheduler python /app/net_worth.py
docker exec budibase-scheduler python /app/recurring.py
```

## Scheduler job times (UTC)

| Job              | UTC   | IST   | CEST  |
|------------------|-------|-------|-------|
| fx_rates         | 08:00 | 13:30 | 10:00 |
| recurring        | 06:00 | 11:30 | 08:00 |
| price_refresh    | 17:00 | 22:30 | 19:00 |
| net_worth        | 18:00 | 23:30 | 20:00 |

## Building the dashboard in Budibase

After seeding, set up the Finance app screen:

1. In the app builder, create a new **Screen**
2. Add a **Cards** or **Stat** component bound to `NetWorthSnapshots` (latest row)
   for the total EUR and INR summary
3. Add a **Table** component bound to `Holdings`; add a computed column:
   `{{ quantity * current_price }}`
4. Add a **Chart** component:
   - Pie: bind to a query that aggregates Holdings value by country
   - Line: bind to `NetWorthSnapshots`, x = `date`, y = `total_value_eur`
5. Add a second **Table** bound to `FixedDeposits`, sorted by `maturity_date` ascending

## Re-seeding safely

The seed script is idempotent. To add a new holding after initial setup:

1. Add the row to `seed/data.json`
2. Re-run `python setup.py` — only the new row will be inserted

To update a value (e.g. avg_buy_price after a top-up), update it directly in the
Budibase data editor — do not change it in data.json and re-run (the script skips
existing rows by name).

## Cloudflare tunnel

The `charts.aritra.fyi` entry has been added to
`stacks/infra/cloudflared/config.yml`. After pushing to the server, reload the
infra stack:

```bash
cd stacks/infra
docker compose up -d --force-recreate cloudflared
```
