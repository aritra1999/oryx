"""
net_worth.py — Daily net worth snapshot.

Sums:
  - Accounts.current_balance (manually maintained)
  - FixedDeposits.maturity_value
  - Holdings: quantity × current_price

Converts INR → EUR via latest ExchangeRates row.
Writes one row to NetWorthSnapshots.

Runs at 18:00 UTC (after price_refresh at 17:00 and fx_rates at 08:00).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import bb_client as bb


def main() -> None:
    now = datetime.now(timezone.utc).isoformat()
    print(f"[net_worth] {now}")

    eur_inr = bb.get_latest_exchange_rate("EUR/INR")
    if eur_inr == 0:
        print("  WARN: EUR/INR rate is 0 — fx_rates.py may not have run yet")
        eur_inr = 1  # avoid division by zero; snapshot will be inaccurate

    def to_eur(amount: float, currency: str) -> float:
        if currency == "EUR":
            return amount
        if currency == "INR":
            return amount / eur_inr
        return amount  # unknown currency: pass through

    de_eur = in_eur = 0.0

    # ── Accounts ──────────────────────────────────────────────────────────────
    for row in bb.search_rows(bb.get_table_id("Accounts")):
        balance  = float(row.get("current_balance", 0))
        currency = row.get("currency", "EUR")
        country  = row.get("country", "DE")
        val_eur  = to_eur(balance, currency)
        if country == "DE":
            de_eur += val_eur
        else:
            in_eur += val_eur

    # ── Fixed Deposits ────────────────────────────────────────────────────────
    for row in bb.search_rows(bb.get_table_id("FixedDeposits")):
        maturity = float(row.get("maturity_value", 0))
        currency = row.get("currency", "INR")
        in_eur  += to_eur(maturity, currency)

    # ── Holdings ──────────────────────────────────────────────────────────────
    for row in bb.search_rows(bb.get_table_id("Holdings")):
        qty      = float(row.get("quantity", 0))
        price    = float(row.get("current_price", 0))
        currency = row.get("currency", "EUR")
        country  = row.get("country", "DE")
        val_eur  = to_eur(qty * price, currency)
        if country == "DE":
            de_eur += val_eur
        else:
            in_eur += val_eur

    total_eur = de_eur + in_eur
    total_inr = total_eur * eur_inr

    breakdown = {"DE": round(de_eur, 2), "IN": round(in_eur, 2)}

    snap_table = bb.get_table_id("NetWorthSnapshots")
    bb.create_row(snap_table, {
        "date":                 now,
        "total_value_eur":      round(total_eur, 2),
        "total_value_inr":      round(total_inr, 2),
        "breakdown_by_country": json.dumps(breakdown),
    })

    print(f"  Total: €{total_eur:,.2f} / ₹{total_inr:,.2f}")
    print(f"  DE: €{de_eur:,.2f}  IN: €{in_eur:,.2f}")
    print("[net_worth] done")


if __name__ == "__main__":
    main()
