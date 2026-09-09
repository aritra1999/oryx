"""
fx_rates.py — Fetch EUR/INR (and EUR/EUR identity) from Yahoo Finance.

Runs at 08:00 UTC daily.
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

import requests

import bb_client as bb


YAHOO_URL = "https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?interval=1d&range=1d"
YAHOO_HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}

PAIRS = [
    ("EUR/INR", "EURINR=X"),
]


def fetch_rate(ticker: str) -> float | None:
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
        print(f"  WARN: fetch failed for {ticker}: {exc}", file=sys.stderr)
        return None


def main() -> None:
    now = datetime.now(timezone.utc).isoformat()
    today = now[:10]
    print(f"[fx_rates] {now}")

    table_id = bb.get_table_id("ExchangeRates")
    existing = {r["currency_pair"]: r for r in bb.search_rows(table_id)}

    for pair, ticker in PAIRS:
        rate = fetch_rate(ticker)
        if rate is None:
            print(f"  FAIL {pair}", file=sys.stderr)
            continue

        if pair in existing:
            bb.update_row(table_id, existing[pair]["_id"], {"rate": rate, "date": now})
        else:
            bb.create_row(table_id, {"currency_pair": pair, "rate": rate, "date": now})

        print(f"  OK   {pair} = {rate:.4f}")

    print("[fx_rates] done")


if __name__ == "__main__":
    main()
