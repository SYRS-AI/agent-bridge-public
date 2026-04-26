#!/usr/bin/env python3
"""bridge-config.py — operator-gated wrapper for system-config mutations.

Issue #341 makes this the only normal mutation path for the protected
file list (see `lib/system_config_paths.py`). Direct Edit/Write tool
calls against those paths are denied by `hooks/tool-policy.py`; the
wrapper layers the caller-agent + caller-source check that the hook
deliberately does not enforce.

CLI shape mirrors the brief:

    bridge-config.py set  --path <p> --change <expr> [--from <agent>]
    bridge-config.py get  --path <p>
    bridge-config.py list-protected [--json]

`set` accepts:

    key=value                     # top-level scalar set
    a.b.c=value                   # nested scalar set (creates intermediate dicts)
    a.b.append=value              # append to a list at a.b
    a.b.remove=value              # remove first occurrence from a.b list

Both before-sha256 and after-sha256 are recorded in the audit row so the
operator can compare a wrapper-apply event against the file's at-rest
hash on disk.

Trust model recap (from the issue's "신뢰 경계 정의" table):

    operator-tui          interactive shell (stdin+stdout are TTYs)
    operator-trusted-id   set explicitly by a verified channel handler
                          via BRIDGE_CALLER_SOURCE env
    agent-direct          everything else — denied

This file is invoked through `bridge-config.sh`, which is in turn dispatched
by the `agent-bridge config …` subcommand.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
LIB_DIR = ROOT / "lib"
if LIB_DIR.is_dir() and str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from system_config_paths import (  # noqa: E402
    PROTECTED_GLOBS,
    bridge_home_dir,
    is_protected_path,
    matched_pattern,
)


CALLER_SOURCE_OPERATOR_TUI = "operator-tui"
CALLER_SOURCE_OPERATOR_TRUSTED_ID = "operator-trusted-id"
CALLER_SOURCE_AGENT_DIRECT = "agent-direct"

# Caller sources allowed to mutate. The operator can extend this set via
# the env var below at deploy time, but the default set is deliberately
# narrow — issue #341 §"권한 모델이 코드에 없고 가이드 텍스트에만 있음" is
# the failure mode we are correcting.
ALLOWED_CALLER_SOURCES = frozenset(
    {CALLER_SOURCE_OPERATOR_TUI, CALLER_SOURCE_OPERATOR_TRUSTED_ID}
)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def detect_caller_source() -> str:
    """Resolve which trust bucket the current process belongs to.

    `BRIDGE_CALLER_SOURCE` is the explicit override a verified channel
    handler uses to declare it has already validated the operator's
    user_id against the canonical roster (issue #341 §B). When unset,
    we fall back to TTY detection: an interactive shell invoking
    `agent-bridge config set` is treated as operator-tui. Any
    non-interactive non-overridden caller is `agent-direct` and the
    wrapper denies the mutation.
    """
    explicit = os.environ.get("BRIDGE_CALLER_SOURCE", "").strip().lower()
    if explicit in {CALLER_SOURCE_OPERATOR_TUI, CALLER_SOURCE_OPERATOR_TRUSTED_ID}:
        return explicit
    if explicit:
        return CALLER_SOURCE_AGENT_DIRECT
    try:
        if sys.stdin.isatty() and sys.stdout.isatty():
            return CALLER_SOURCE_OPERATOR_TUI
    except (OSError, ValueError):
        pass
    return CALLER_SOURCE_AGENT_DIRECT


def admin_agent_id() -> str:
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


def caller_agent_id(args: argparse.Namespace) -> str:
    explicit = getattr(args, "from_agent", None)
    if explicit:
        return str(explicit).strip()
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


def caller_is_admin(agent: str) -> bool:
    """The wrapper requires the caller to either be the explicit admin
    agent or to invoke from operator-TUI without claiming an agent
    identity at all (the human operator typing the command).

    The check is intentionally stricter than the hook's `is_admin_agent`
    — the hook gates by session-type files that an agent could in theory
    plant; the wrapper requires either an env-declared admin id or a
    TTY-resolved operator identity.
    """
    admin = admin_agent_id()
    if admin and agent == admin:
        return True
    # Operator typing at a TTY without setting BRIDGE_AGENT_ID is the
    # canonical "operator personally invoking" surface — accept it as
    # admin-equivalent only when the caller-source is operator-tui.
    if not agent and detect_caller_source() == CALLER_SOURCE_OPERATOR_TUI:
        return True
    return False


def write_audit(detail: dict[str, Any]) -> Path:
    """Write a `system_config_mutation` row to the bridge audit log.

    Uses bridge-audit.py write to keep the hash chain intact — the
    wrapper's rows hash-link with hook rows so an operator can verify
    the audit log end-to-end.
    """
    log_path = audit_log_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    detail_json = json.dumps(detail, ensure_ascii=True, sort_keys=True)
    cmd = [
        sys.executable,
        str(ROOT / "bridge-audit.py"),
        "write",
        "--file",
        str(log_path),
        "--actor",
        "wrapper",
        "--action",
        "system_config_mutation",
        "--target",
        detail.get("path", "") or "",
        "--detail-json",
        detail_json,
    ]
    try:
        subprocess.run(cmd, check=False, capture_output=True)
    except OSError:
        # Fallback: append the raw record directly so a missing python
        # interpreter does not silently swallow the audit row. Best-effort.
        record = {
            "ts": now_iso(),
            "actor": "wrapper",
            "action": "system_config_mutation",
            "target": detail.get("path", ""),
            "detail": detail,
            "pid": os.getpid(),
            "host": socket.gethostname(),
        }
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=True) + "\n")
    return log_path


def audit_log_path() -> Path:
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_home_dir() / "logs" / "audit.jsonl"


def file_sha256(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        with path.open("rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return ""


def parse_change_expr(expr: str) -> tuple[list[str], str, str]:
    """Split a change expression into (key path, operator, value).

    The operator is one of `set` / `append` / `remove`. The brief lists
    `<key=val|json-patch>` as syntax — we deliberately implement only the
    bounded set that's enough for the four test scenarios. JSON patch is
    out of scope for the v1 wrapper; an operator who needs full patch
    semantics can run multiple set calls or extend this parser later.
    """
    if "=" not in expr:
        raise SystemExit(f"--change must be 'key=value': {expr}")
    raw_key, value = expr.split("=", 1)
    raw_key = raw_key.strip()
    if not raw_key:
        raise SystemExit(f"--change key is empty: {expr}")
    parts = raw_key.split(".")
    if parts[-1] in {"append", "remove"}:
        op = parts[-1]
        keys = parts[:-1]
    else:
        op = "set"
        keys = parts
    if not keys:
        raise SystemExit(f"--change key path is empty: {expr}")
    return keys, op, value


def apply_change_to_json(payload: Any, keys: list[str], op: str, value: str) -> Any:
    if not isinstance(payload, dict):
        raise SystemExit("config root must be a JSON object")
    cursor: dict[str, Any] = payload
    for key in keys[:-1]:
        next_value = cursor.get(key)
        if not isinstance(next_value, dict):
            next_value = {}
            cursor[key] = next_value
        cursor = next_value
    last_key = keys[-1]
    if op == "set":
        cursor[last_key] = _coerce_value(value)
    elif op == "append":
        existing = cursor.get(last_key)
        if existing is None:
            existing = []
        if not isinstance(existing, list):
            raise SystemExit(f"cannot append: {'.'.join(keys)} is not a list")
        existing.append(_coerce_value(value))
        cursor[last_key] = existing
    elif op == "remove":
        existing = cursor.get(last_key)
        if not isinstance(existing, list):
            raise SystemExit(f"cannot remove: {'.'.join(keys)} is not a list")
        coerced = _coerce_value(value)
        # Match either the coerced form or the literal string so the
        # operator does not have to know whether the list stores ints
        # or strings.
        for candidate in (coerced, value):
            if candidate in existing:
                existing.remove(candidate)
                break
        cursor[last_key] = existing
    else:
        raise SystemExit(f"unsupported change op: {op}")
    return payload


def _coerce_value(value: str) -> Any:
    """Best-effort scalar coercion: try JSON literal first, fall back to str.

    `groups.append=1476851882533191681` is the obvious case — we want
    the int form to land in JSON, not the quoted string.
    """
    stripped = value.strip()
    if not stripped:
        return value
    try:
        return json.loads(stripped)
    except (ValueError, TypeError):
        return value


def atomic_write(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        # Preserve mode if the original existed; default to 0600 otherwise
        # so secrets-bearing config files (access.json) do not loosen.
        if path.exists():
            shutil.copymode(path, tmp_name)
        else:
            os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def cmd_list_protected(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps(list(PROTECTED_GLOBS), ensure_ascii=True, indent=2))
        return 0
    print(f"BRIDGE_HOME: {bridge_home_dir()}")
    print("protected globs (relative to BRIDGE_HOME):")
    for pattern in PROTECTED_GLOBS:
        print(f"  {pattern}")
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser()
    if not is_protected_path(path):
        print(
            f"refusing: {path} is not in the system-config protected list",
            file=sys.stderr,
        )
        return 2
    if not path.exists():
        print(f"missing: {path}", file=sys.stderr)
        return 1
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"read failed: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser()
    caller_agent = caller_agent_id(args)
    caller_source = detect_caller_source()

    deny_reason: str | None = None
    if not is_protected_path(path):
        deny_reason = "path not in system-config protected list"
    elif not caller_is_admin(caller_agent):
        deny_reason = (
            f"caller agent {caller_agent or '(none)'} is not the admin "
            "agent — refusing system-config mutation"
        )
    elif caller_source not in ALLOWED_CALLER_SOURCES:
        deny_reason = (
            f"caller source {caller_source} is not allowed to mutate "
            "system config (need operator-tui or operator-trusted-id)"
        )

    actor_label = caller_agent or (
        "operator" if caller_source == CALLER_SOURCE_OPERATOR_TUI else "unknown"
    )
    if deny_reason is not None:
        write_audit(
            {
                "kind": "system_config_mutation",
                "actor": actor_label,
                "actor_source": caller_source,
                "trigger": "wrapper-deny",
                "path": str(path),
                "before_sha256": file_sha256(path),
                "after_sha256": file_sha256(path),
                "operation": args.change,
                "matched_pattern": matched_pattern(path) or "",
                "reason": deny_reason,
            }
        )
        print(f"deny: {deny_reason}", file=sys.stderr)
        return 3

    # Limit to JSON files. Roster (`agent-roster.local.sh`) is a shell
    # file; mutating it through this wrapper would require shell-aware
    # editing that is well out of scope for v1. We still record a
    # `wrapper-deny` row so the operator sees the attempt.
    if path.suffix != ".json":
        write_audit(
            {
                "kind": "system_config_mutation",
                "actor": actor_label,
                "actor_source": caller_source,
                "trigger": "wrapper-deny",
                "path": str(path),
                "before_sha256": file_sha256(path),
                "after_sha256": file_sha256(path),
                "operation": args.change,
                "matched_pattern": matched_pattern(path) or "",
                "reason": "non-JSON system config files are not yet wrapper-mutable",
            }
        )
        print(
            f"deny: {path.suffix} files are not yet wrapper-mutable — "
            "edit at the operator-TUI manually and re-run `agent-bridge config get` to verify",
            file=sys.stderr,
        )
        return 4

    keys, op, value = parse_change_expr(args.change)

    before_sha = file_sha256(path)
    payload: Any
    if path.exists():
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"read failed: {exc}", file=sys.stderr)
            return 1
    else:
        payload = {}

    payload = apply_change_to_json(payload, keys, op, value)
    atomic_write(path, payload)
    after_sha = file_sha256(path)

    write_audit(
        {
            "kind": "system_config_mutation",
            "actor": actor_label,
            "actor_source": caller_source,
            "trigger": "wrapper-apply",
            "path": str(path),
            "before_sha256": before_sha,
            "after_sha256": after_sha,
            "operation": args.change,
            "matched_pattern": matched_pattern(path) or "",
        }
    )
    print(f"applied: {path} ({op} {'.'.join(keys)})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="agent-bridge config — gated system-config mutations (issue #341)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    set_parser = sub.add_parser("set", help="apply a change to a protected path")
    set_parser.add_argument("--path", required=True)
    set_parser.add_argument(
        "--change",
        required=True,
        help="change expression: key=value | a.b=value | a.b.append=value | a.b.remove=value",
    )
    set_parser.add_argument("--from", dest="from_agent", help="caller agent id (defaults to $BRIDGE_AGENT_ID)")
    set_parser.set_defaults(handler=cmd_set)

    get_parser = sub.add_parser("get", help="read a protected path")
    get_parser.add_argument("--path", required=True)
    get_parser.set_defaults(handler=cmd_get)

    list_parser = sub.add_parser("list-protected", help="print the protected glob list")
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(handler=cmd_list_protected)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
