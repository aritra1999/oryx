#!/usr/bin/env python3
"""
Budibase seed script — creates all tables and inserts data from data.json.
Idempotent: skips tables that already exist, skips rows whose 'name' already exists.

Usage:
    pip install -r requirements.txt
    BB_API_KEY=... BB_APP_ID=... BB_BASE_URL=http://localhost:10000 python setup.py

Or copy .env.example to .env, fill it in, then:
    export $(cat ../.env | grep -v '^#' | xargs) && python setup.py
"""

import json
import os
import sys
from pathlib import Path

import requests

# ── Config ────────────────────────────────────────────────────────────────────

BASE_URL = os.environ["BB_BASE_URL"].rstrip("/")
API_KEY  = os.environ["BB_API_KEY"]
APP_ID   = os.environ["BB_APP_ID"]

HEADERS = {
    "x-budibase-api-key": API_KEY,
    "x-budibase-app-id":  APP_ID,
    "Content-Type":       "application/json",
}

PUBLIC = f"{BASE_URL}/api/public/v1"

# ── Table definitions ─────────────────────────────────────────────────────────

TABLES = [
    {
        "name": "Accounts",
        "primaryDisplay": "name",
        "schema": {
            "name":            {"type": "string",  "name": "name"},
            "country":         {"type": "options", "name": "country",
                                "constraints": {"inclusion": ["DE", "IN"]}},
            "currency":        {"type": "options", "name": "currency",
                                "constraints": {"inclusion": ["EUR", "INR"]}},
            "type":            {"type": "options", "name": "type",
                                "constraints": {"inclusion": ["bank", "broker", "FD"]}},
            "current_balance": {"type": "number",   "name": "current_balance"},
            "last_updated":    {"type": "datetime", "name": "last_updated"},
        },
    },
    {
        "name": "FixedDeposits",
        "primaryDisplay": "name",
        "schema": {
            "name":           {"type": "string",   "name": "name"},
            "linked_account": {"type": "string",   "name": "linked_account"},
            "principal":      {"type": "number",   "name": "principal"},
            "interest_rate":  {"type": "number",   "name": "interest_rate"},
            "currency":       {"type": "options",  "name": "currency",
                               "constraints": {"inclusion": ["EUR", "INR"]}},
            "start_date":     {"type": "datetime", "name": "start_date"},
            "maturity_date":  {"type": "datetime", "name": "maturity_date"},
            "maturity_value": {"type": "number",   "name": "maturity_value"},
        },
    },
    {
        "name": "Holdings",
        "primaryDisplay": "name",
        "schema": {
            "name":              {"type": "string",   "name": "name"},
            "asset_type":        {"type": "options",  "name": "asset_type",
                                  "constraints": {"inclusion": ["stock", "ETF", "mutual_fund"]}},
            "country":           {"type": "options",  "name": "country",
                                  "constraints": {"inclusion": ["DE", "IN"]}},
            "currency":          {"type": "options",  "name": "currency",
                                  "constraints": {"inclusion": ["EUR", "INR"]}},
            "identifier":        {"type": "string",   "name": "identifier"},
            "quantity":          {"type": "number",   "name": "quantity"},
            "avg_buy_price":     {"type": "number",   "name": "avg_buy_price"},
            "current_price":     {"type": "number",   "name": "current_price"},
            "last_price_update": {"type": "datetime", "name": "last_price_update"},
        },
    },
    {
        "name": "Transactions",
        "primaryDisplay": "date",
        "schema": {
            "date":           {"type": "datetime", "name": "date"},
            "linked_holding": {"type": "string",   "name": "linked_holding"},
            "type":           {"type": "options",  "name": "type",
                               "constraints": {"inclusion": ["buy", "sell", "SIP", "vest", "dividend"]}},
            "quantity":       {"type": "number",   "name": "quantity"},
            "price":          {"type": "number",   "name": "price"},
            "currency":       {"type": "options",  "name": "currency",
                               "constraints": {"inclusion": ["EUR", "INR"]}},
            "is_recurring":   {"type": "boolean",  "name": "is_recurring"},
        },
    },
    {
        "name": "RecurringInvestments",
        "primaryDisplay": "name",
        "schema": {
            "name":             {"type": "string",  "name": "name"},
            "linked_holding":   {"type": "string",  "name": "linked_holding"},
            "type":             {"type": "options", "name": "type",
                                 "constraints": {"inclusion": ["SIP", "vest"]}},
            "shares_or_amount": {"type": "number",  "name": "shares_or_amount"},
            "day_of_month":     {"type": "number",  "name": "day_of_month"},
            "currency":         {"type": "options", "name": "currency",
                                 "constraints": {"inclusion": ["EUR", "INR"]}},
        },
    },
    {
        "name": "ExchangeRates",
        "primaryDisplay": "currency_pair",
        "schema": {
            "currency_pair": {"type": "string",   "name": "currency_pair"},
            "rate":          {"type": "number",   "name": "rate"},
            "date":          {"type": "datetime", "name": "date"},
        },
    },
    {
        "name": "NetWorthSnapshots",
        "primaryDisplay": "date",
        "schema": {
            "date":                   {"type": "datetime", "name": "date"},
            "total_value_eur":        {"type": "number",   "name": "total_value_eur"},
            "total_value_inr":        {"type": "number",   "name": "total_value_inr"},
            "breakdown_by_country":   {"type": "json",     "name": "breakdown_by_country"},
        },
    },
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def get_existing_tables() -> dict[str, str]:
    """Return {table_name: table_id} for all existing tables in the app."""
    resp = requests.get(f"{PUBLIC}/tables", headers=HEADERS)
    resp.raise_for_status()
    return {t["name"]: t["_id"] for t in resp.json().get("data", [])}


def create_table(defn: dict) -> str:
    resp = requests.post(f"{PUBLIC}/tables", headers=HEADERS, json=defn)
    resp.raise_for_status()
    table_id = resp.json()["data"]["_id"]
    print(f"  Created table '{defn['name']}' → {table_id}")
    return table_id


def get_existing_row_names(table_id: str) -> set[str]:
    """Return set of 'name' values already in the table (for idempotency)."""
    resp = requests.post(
        f"{PUBLIC}/tables/{table_id}/rows/search",
        headers=HEADERS,
        json={"limit": 1000},
    )
    resp.raise_for_status()
    rows = resp.json().get("data", [])
    return {r.get("name", r.get("currency_pair", r.get("date", ""))) for r in rows}


def insert_row(table_id: str, row: dict) -> None:
    resp = requests.post(
        f"{PUBLIC}/tables/{table_id}/rows",
        headers=HEADERS,
        json=row,
    )
    resp.raise_for_status()


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    data_path = Path(__file__).parent / "data.json"
    if not data_path.exists():
        print("ERROR: seed/data.json not found.")
        print("  cp seed/data.json.example seed/data.json  # then fill it in")
        sys.exit(1)

    with open(data_path) as f:
        data = json.load(f)

    # ── Step 1: ensure all tables exist ───────────────────────────────────────
    print("\n── Tables ──────────────────────────────────────────────────────────")
    existing = get_existing_tables()
    table_ids: dict[str, str] = {}

    for defn in TABLES:
        name = defn["name"]
        if name in existing:
            table_ids[name] = existing[name]
            print(f"  Skipped '{name}' (already exists) → {existing[name]}")
        else:
            table_ids[name] = create_table(defn)

    # ── Step 2: insert rows ────────────────────────────────────────────────────
    sections = [
        ("Accounts",             "accounts"),
        ("FixedDeposits",        "fixed_deposits"),
        ("Holdings",             "holdings"),
        ("RecurringInvestments", "recurring_investments"),
    ]

    for table_name, data_key in sections:
        rows = data.get(data_key, [])
        if not rows:
            print(f"\n── {table_name}: no rows in data.json, skipping")
            continue

        print(f"\n── {table_name} ({len(rows)} rows) ──────────────────────────────────")
        table_id     = table_ids[table_name]
        existing_ids = get_existing_row_names(table_id)

        for row in rows:
            key = row.get("name", row.get("currency_pair", ""))
            if key in existing_ids:
                print(f"  Skipped '{key}' (already exists)")
            else:
                insert_row(table_id, row)
                print(f"  Inserted '{key}'")

    # ── Step 3: seed ExchangeRates with a placeholder ─────────────────────────
    er_id       = table_ids["ExchangeRates"]
    er_existing = get_existing_row_names(er_id)
    if "EUR/INR" not in er_existing:
        insert_row(er_id, {"currency_pair": "EUR/INR", "rate": 0, "date": "2000-01-01T00:00:00.000Z"})
        print("\n── ExchangeRates: seeded EUR/INR placeholder (scheduler will update)")

    print("\n✓ Seed complete.")
    print("\nTable IDs (paste into scheduler .env if needed):")
    for name, tid in table_ids.items():
        print(f"  {name}: {tid}")


if __name__ == "__main__":
    main()
