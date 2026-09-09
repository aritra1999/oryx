"""
price_refresh.py — Daily price update for all Holdings rows.

- mutual_fund  → mfapi.in (AMFI scheme code)
- stock / ETF  → Yahoo Finance (ticker)

Runs at 17:00 UTC (≈ 21:00 IST / 18:00 CEST).
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

import requests

import bb_client as bb


YAHOO_URL = "https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?interval=1d&range=1d"
MFAPI_URL = "https://api.mfapi.in/mf/{code}/latest"

YAHOO_HEADERS = {
    "User-Agent": "Mozilla/5.0",
    "Accept": "application/json",
}


def fetch_yahoo_price(ticker: str) -> float | None:
    try:
        resp = requests.get(
            YAHOO_URL.format(ticker=ticker),
            headers=YAHOO_HEADERS,
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        return float(data["chart"]["result"][0]["meta"]["regularMarketPrice"])
    except Exception as exc:
        print(f"  WARN: Yahoo fetch failed for {ticker}: {exc}", file=sys.stderr)
        return None


def fetch_mf_nav(scheme_code: str) -> float | None:
    try:
        resp = requests.get(MFAPI_URL.format(code=scheme_code), timeout=15)
        resp.raise_for_status()
        data = resp.json()
        return float(data["data"][0]["nav"])
    except Exception as exc:
        print(f"  WARN: mfapi fetch failed for {scheme_code}: {exc}", file=sys.stderr)
        return None


def main() -> None:
    now = datetime.now(timezone.utc).isoformat()
    print(f"[price_refresh] {now}")

    table_id = bb.get_table_id("Holdings")
    rows     = bb.search_rows(table_id)
    ok = err = 0

    for row in rows:
        name       = row.get("name", "?")
        identifier = row.get("identifier", "")
        asset_type = row.get("asset_type", "")

        if not identifier:
            print(f"  SKIP {name}: no identifier")
            continue

        if asset_type == "mutual_fund":
            price = fetch_mf_nav(identifier)
        else:
            price = fetch_yahoo_price(identifier)

        if price is None:
            err += 1
            continue

        bb.update_row(table_id, row["_id"], {
            "current_price":     price,
            "last_price_update": now,
        })
        print(f"  OK   {name} ({identifier}): {price}")
        ok += 1

    print(f"[price_refresh] done — {ok} updated, {err} failed")


if __name__ == "__main__":
    main()
