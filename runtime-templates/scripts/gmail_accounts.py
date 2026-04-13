"""Shared Gmail accounts config loader.

Used by both email-webhook-handler.py and adjacent Gmail jobs so the
config loading logic stays in a single importable module.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

RUNTIME_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GMAIL_ACCOUNTS_FILE = RUNTIME_ROOT / "credentials" / "gmail-accounts.json"


def load_gmail_accounts() -> dict[str, str]:
    """Load Gmail account config from env or file."""
    raw_json = os.environ.get("BRIDGE_GMAIL_ACCOUNTS_JSON", "").strip()
    if raw_json:
        try:
            payload = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise RuntimeError("BRIDGE_GMAIL_ACCOUNTS_JSON must be valid JSON") from exc
    else:
        config_path = Path(
            os.environ.get("BRIDGE_GMAIL_ACCOUNTS_FILE", str(DEFAULT_GMAIL_ACCOUNTS_FILE))
        ).expanduser()
        if not config_path.exists():
            return {}
        payload = json.loads(config_path.read_text(encoding="utf-8"))

    if isinstance(payload, dict) and isinstance(payload.get("accounts"), dict):
        payload = payload["accounts"]
    if not isinstance(payload, dict):
        raise RuntimeError("gmail account config must be a JSON object")

    return {
        str(name): str(address).strip()
        for name, address in payload.items()
        if str(name).strip() and str(address).strip()
    }


def gmail_accounts_config_source() -> str:
    """Return the resolved config source for diagnostics."""
    raw_json = os.environ.get("BRIDGE_GMAIL_ACCOUNTS_JSON", "").strip()
    if raw_json:
        return "env:BRIDGE_GMAIL_ACCOUNTS_JSON"
    return os.environ.get("BRIDGE_GMAIL_ACCOUNTS_FILE", str(DEFAULT_GMAIL_ACCOUNTS_FILE))
