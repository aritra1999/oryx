"""
Shared Budibase API client used by all scheduler scripts.
"""

import os
import requests

BASE_URL = os.environ["BB_BASE_URL"].rstrip("/")
API_KEY  = os.environ["BB_API_KEY"]
APP_ID   = os.environ["BB_APP_ID"]
PUBLIC   = f"{BASE_URL}/api/public/v1"

HEADERS = {
    "x-budibase-api-key": API_KEY,
    "x-budibase-app-id":  APP_ID,
    "Content-Type":       "application/json",
}


def get_table_id(name: str) -> str:
    resp = requests.get(f"{PUBLIC}/tables", headers=HEADERS)
    resp.raise_for_status()
    for t in resp.json().get("data", []):
        if t["name"] == name:
            return t["_id"]
    raise RuntimeError(f"Table '{name}' not found — run seed/setup.py first")


def search_rows(table_id: str, limit: int = 200) -> list[dict]:
    resp = requests.post(
        f"{PUBLIC}/tables/{table_id}/rows/search",
        headers=HEADERS,
        json={"limit": limit},
    )
    resp.raise_for_status()
    return resp.json().get("data", [])


def update_row(table_id: str, row_id: str, patch: dict) -> None:
    resp = requests.patch(
        f"{PUBLIC}/tables/{table_id}/rows/{row_id}",
        headers=HEADERS,
        json=patch,
    )
    resp.raise_for_status()


def create_row(table_id: str, row: dict) -> dict:
    resp = requests.post(
        f"{PUBLIC}/tables/{table_id}/rows",
        headers=HEADERS,
        json=row,
    )
    resp.raise_for_status()
    return resp.json().get("data", {})


def get_latest_exchange_rate(pair: str = "EUR/INR") -> float:
    table_id = get_table_id("ExchangeRates")
    rows = search_rows(table_id)
    for r in rows:
        if r.get("currency_pair") == pair:
            return float(r.get("rate", 0))
    return 0.0
