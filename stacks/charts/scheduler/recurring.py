"""
recurring.py — Log SIPs and employer stock vests on their scheduled day.

For SIP:  creates a Transaction row, then updates the linked Holding's
          quantity and avg_buy_price using the current NAV.

For vest: fetches current stock price, calculates shares = EUR_amount / price,
          creates a Transaction row, updates the Holding.

Runs at 06:00 UTC daily.
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

import requests

import bb_client as bb


YAHOO_URL = "https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?interval=1d&range=1d"
MFAPI_URL = "https://api.mfapi.in/mf/{code}/latest"
YAHOO_HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}


def fetch_yahoo_price(ticker: str) -> float | None:
    try:
        resp = requests.get(YAHOO_URL.format(ticker=ticker), headers=YAHOO_HEADERS, timeout=15)
        resp.raise_for_status()
        return float(resp.json()["chart"]["result"][0]["meta"]["regularMarketPrice"])
    except Exception as exc:
        print(f"  WARN: Yahoo {ticker}: {exc}", file=sys.stderr)
        return None


def fetch_mf_nav(code: str) -> float | None:
    try:
        resp = requests.get(MFAPI_URL.format(code=code), timeout=15)
        resp.raise_for_status()
        return float(resp.json()["data"][0]["nav"])
    except Exception as exc:
        print(f"  WARN: mfapi {code}: {exc}", file=sys.stderr)
        return None


def recalculate_avg(old_qty: float, old_avg: float, new_qty: float, new_price: float) -> float:
    total_qty = old_qty + new_qty
    if total_qty == 0:
        return new_price
    return (old_qty * old_avg + new_qty * new_price) / total_qty


def main() -> None:
    now = datetime.now(timezone.utc)
    today_day = now.day
    now_iso   = now.isoformat()
    print(f"[recurring] {now_iso} — day {today_day}")

    ri_table_id  = bb.get_table_id("RecurringInvestments")
    h_table_id   = bb.get_table_id("Holdings")
    tx_table_id  = bb.get_table_id("Transactions")

    ri_rows  = bb.search_rows(ri_table_id)
    holdings = {r["name"]: r for r in bb.search_rows(h_table_id)}

    scheduled = [r for r in ri_rows if r.get("day_of_month") == today_day]
    if not scheduled:
        print(f"[recurring] nothing scheduled for day {today_day}")
        return

    for ri in scheduled:
        name           = ri.get("name", "?")
        linked_holding = ri.get("linked_holding", "")
        ri_type        = ri.get("type", "")
        amount         = float(ri.get("shares_or_amount", 0))
        currency       = ri.get("currency", "INR")

        holding = holdings.get(linked_holding)
        if not holding:
            print(f"  SKIP {name}: holding '{linked_holding}' not found", file=sys.stderr)
            continue

        identifier = holding.get("identifier", "")
        old_qty    = float(holding.get("quantity", 0))
        old_avg    = float(holding.get("avg_buy_price", 0))

        # ── SIP ────────────────────────────────────────────────────────────────
        if ri_type == "SIP":
            nav = fetch_mf_nav(identifier)
            if nav is None:
                print(f"  FAIL {name}: could not fetch NAV", file=sys.stderr)
                continue
            new_units = amount / nav
            new_avg   = recalculate_avg(old_qty, old_avg, new_units, nav)

            bb.create_row(tx_table_id, {
                "date":           now_iso,
                "linked_holding": linked_holding,
                "type":           "SIP",
                "quantity":       new_units,
                "price":          nav,
                "currency":       currency,
                "is_recurring":   True,
            })
            bb.update_row(h_table_id, holding["_id"], {
                "quantity":      old_qty + new_units,
                "avg_buy_price": new_avg,
            })
            print(f"  SIP  {name}: {new_units:.4f} units @ NAV {nav} (total {old_qty + new_units:.4f})")

        # ── Vest ───────────────────────────────────────────────────────────────
        elif ri_type == "vest":
            price = fetch_yahoo_price(identifier)
            if price is None:
                print(f"  FAIL {name}: could not fetch price", file=sys.stderr)
                continue
            new_shares = amount / price
            new_avg    = recalculate_avg(old_qty, old_avg, new_shares, price)

            bb.create_row(tx_table_id, {
                "date":           now_iso,
                "linked_holding": linked_holding,
                "type":           "vest",
                "quantity":       new_shares,
                "price":          price,
                "currency":       currency,
                "is_recurring":   True,
            })
            bb.update_row(h_table_id, holding["_id"], {
                "quantity":      old_qty + new_shares,
                "avg_buy_price": new_avg,
            })
            print(f"  VEST {name}: {new_shares:.4f} shares @ {price} (€{amount} / {price})")

        else:
            print(f"  SKIP {name}: unknown type '{ri_type}'")

    print("[recurring] done")


if __name__ == "__main__":
    main()
