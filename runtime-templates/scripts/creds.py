"""Agent Bridge runtime credential loader.

Use this helper from runtime scripts that need local credentials:

    from creds import load_creds
    config = load_creds("service-account.json")
    token = load_creds("api-token.txt")

Credentials are read from the bridge runtime only:

- ``$BRIDGE_RUNTIME_CREDENTIALS_DIR`` or ``~/.agent-bridge/runtime/credentials``
- ``$BRIDGE_RUNTIME_SECRETS_DIR`` or ``~/.agent-bridge/runtime/secrets``

JSON files return parsed JSON. Other files return stripped text.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


BRIDGE_HOME = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))).expanduser()
RUNTIME_ROOT = Path(os.environ.get("BRIDGE_RUNTIME_ROOT", str(BRIDGE_HOME / "runtime"))).expanduser()
CREDENTIALS_DIR = Path(
    os.environ.get("BRIDGE_RUNTIME_CREDENTIALS_DIR", str(RUNTIME_ROOT / "credentials"))
).expanduser()
SECRETS_DIR = Path(os.environ.get("BRIDGE_RUNTIME_SECRETS_DIR", str(RUNTIME_ROOT / "secrets"))).expanduser()

_CACHE: dict[str, Any] = {}


class CredentialNotFoundError(FileNotFoundError):
    """Raised when a runtime credential is absent without exposing secrets."""


def _candidate_paths(filename: str) -> list[Path]:
    return [CREDENTIALS_DIR / filename, SECRETS_DIR / filename]


def _redact_path(path: Path) -> str:
    try:
        home = Path.home().expanduser().resolve()
        resolved = path.expanduser().resolve()
        if resolved == home:
            return "~"
        return "~/" + str(resolved.relative_to(home)) if resolved.is_relative_to(home) else str(resolved)
    except Exception:
        text = str(path.expanduser())
        home_text = str(Path.home().expanduser())
        if text == home_text:
            return "~"
        if text.startswith(home_text + os.sep):
            return "~/" + text[len(home_text + os.sep):]
        return text


def credential_diagnostic(filename: str) -> dict[str, Any]:
    """Return redacted lookup diagnostics without reading credential values."""
    return {
        "credential": filename,
        "found": any(path.exists() for path in _candidate_paths(filename)),
        "search_roots": [_redact_path(CREDENTIALS_DIR), _redact_path(SECRETS_DIR)],
        "policy": "Store secret values only in runtime credentials/secrets files; never paste them into logs, tasks, issues, or source.",
    }


def _read_file(filename: str) -> str:
    for path in _candidate_paths(filename):
        if path.exists():
            return path.read_text(encoding="utf-8")
    diagnostic = credential_diagnostic(filename)
    checked = ", ".join(diagnostic["search_roots"])
    raise CredentialNotFoundError(f"Credential not found: {filename}; checked redacted roots: {checked}")


def load_creds(filename: str) -> Any:
    """Load a credential by filename from the bridge runtime.

    The filename must be relative to the runtime credentials or secrets
    directory. Path traversal is rejected so scripts cannot accidentally read
    outside the credential roots.
    """
    if filename in _CACHE:
        return _CACHE[filename]

    path = Path(filename)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Credential filename must be relative: {filename}")

    raw = _read_file(filename)
    if filename.endswith(".json"):
        result = json.loads(raw)
    else:
        result = raw.strip()

    _CACHE[filename] = result
    return result
