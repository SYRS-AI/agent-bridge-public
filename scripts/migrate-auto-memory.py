#!/usr/bin/env python3
"""Migrate shared Claude auto-memory into per-agent directories.

Agent Bridge places every agent home under a single git repo, so Claude
Code's auto-memory — scoped per repo — ends up shared across agents. PR
1A (see bridge-agent.sh:bridge_ensure_auto_memory_isolation) seeds new
agents with a per-agent `autoMemoryDirectory`. PR 1B (this script)
handles the existing corpus: it splits the shared dir into per-agent
folders, seeds `settings.local.json` for agents that still share
auto-memory, and records a manifest so the move can be reversed.

Modes:
  dry-run   Plan the migration and print the routing report. Safe to
            re-run; writes nothing.
  migrate   Execute the migration. Requires --yes and, by default,
            refuses to run while Claude processes are active. Creates a
            tar.gz backup and a JSON manifest under the backup dir.
  restore   Reverse a migration using the manifest. Moves files back,
            strips the seeded autoMemoryDirectory from each agent's
            settings.local.json, and records a restore marker.

Routing policy (mirrors the PR 1 plan, section 15):
  - Files with `originSessionId` in frontmatter route to the agent whose
    Claude project directory contains the matching session JSONL. 53/74
    files on the reference install resolved uniquely this way.
  - Everything else (MEMORY.md, shared user profiles, notes without a
    session stamp) is moved to `<backup-dir>/needs-review/` and left for
    operator triage. Heuristics are never used to force a routing.

The script only touches Anthropic-managed files under ~/.claude and
bridge-owned files under ~/.agent-bridge. It never rewrites repo
sources.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
ORIGIN_KEY_RE = re.compile(r"^originSessionId:\s*(\S+)\s*$", re.MULTILINE)

DEFAULT_BRIDGE_HOME = Path.home() / ".agent-bridge"
DEFAULT_CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
DEFAULT_AUTO_MEMORY_ROOT = Path.home() / ".claude" / "auto-memory"
DEFAULT_BACKUP_ROOT = DEFAULT_BRIDGE_HOME / "backups"


@dataclass
class FileDecision:
    """Routing decision for one source file."""

    source: Path
    agent: str | None
    reason: str
    origin_session_id: str | None = None
    destination: Path | None = None


@dataclass
class Manifest:
    """Everything needed to reverse a migration."""

    created_at: str
    bridge_home: str
    source_dir: str
    backup_dir: str
    slug: str
    auto_memory_root: str
    agents_dir: str = ""
    moves: list[dict] = field(default_factory=list)
    seeded_agents: list[str] = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(self.__dict__, indent=2, ensure_ascii=False) + "\n"


def bridge_home_slug(bridge_home: Path) -> str:
    """Match Anthropic's ~/.claude/projects/ slug convention."""
    resolved = os.path.realpath(str(bridge_home))
    return resolved.replace(os.sep, "-").replace(".", "-")


def shared_memory_dir(bridge_home: Path, claude_projects: Path) -> Path:
    """Where Claude stores shared auto-memory for the bridge repo."""
    slug = bridge_home_slug(bridge_home)
    return claude_projects / slug / "memory"


def iter_markdown(source_dir: Path) -> Iterable[Path]:
    for entry in sorted(source_dir.iterdir()):
        if entry.is_file() and entry.suffix == ".md":
            yield entry


def read_origin_session_id(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = FRONTMATTER_RE.match(text)
    if not match:
        return None
    key_match = ORIGIN_KEY_RE.search(match.group(1))
    if not key_match:
        return None
    return key_match.group(1).strip().strip("'\"")


def discover_agents(agents_dir: Path) -> dict[str, Path]:
    """Return {agent_id: agent_home_path} for every claude-capable agent."""
    agents: dict[str, Path] = {}
    if not agents_dir.is_dir():
        return agents
    for child in sorted(agents_dir.iterdir()):
        if child.is_dir() and (child / ".claude").is_dir():
            agents[child.name] = child
    return agents


def agent_project_slug_for_home(agent_home: Path) -> str:
    """Compute the Anthropic project-dir slug for a discovered agent home.

    Derived from the *actual* agent home path (not a value recomputed
    from bridge_home), so explicit `--agents-dir` overrides flow through
    to session routing without contradicting the settings-write path.
    """
    resolved = agent_home.resolve()
    return str(resolved).replace(os.sep, "-").replace(".", "-")


def build_session_to_agent(
    claude_projects: Path, agents: dict[str, Path]
) -> dict[str, str]:
    """Map session_id → agent by scanning each discovered home's project dir.

    Anthropic derives the project dir from the session cwd. We start
    from the homes `discover_agents()` actually found under the
    operator's `--agents-dir`, so an explicit override changes both
    settings writes and session-id routing consistently.
    """
    mapping: dict[str, str] = {}
    for agent, agent_home in agents.items():
        project_dir = claude_projects / agent_project_slug_for_home(agent_home)
        if not project_dir.is_dir():
            continue
        for jsonl in project_dir.glob("*.jsonl"):
            session_id = jsonl.stem
            mapping.setdefault(session_id, agent)
    return mapping


def plan_migration(
    source_dir: Path,
    session_to_agent: dict[str, str],
) -> list[FileDecision]:
    """Decide where every file in source_dir should go (no writes)."""
    decisions: list[FileDecision] = []
    for path in iter_markdown(source_dir):
        session_id = read_origin_session_id(path)
        if session_id is None:
            decisions.append(
                FileDecision(
                    source=path,
                    agent=None,
                    reason="no originSessionId",
                    origin_session_id=None,
                )
            )
            continue
        agent = session_to_agent.get(session_id)
        if agent is None:
            decisions.append(
                FileDecision(
                    source=path,
                    agent=None,
                    reason=f"originSessionId {session_id} not resolved to any agent dir",
                    origin_session_id=session_id,
                )
            )
            continue
        decisions.append(
            FileDecision(
                source=path,
                agent=agent,
                reason="routed by originSessionId",
                origin_session_id=session_id,
            )
        )
    return decisions


def render_report(
    decisions: list[FileDecision],
    source_dir: Path,
    target_root: Path,
) -> str:
    total = len(decisions)
    routed = [d for d in decisions if d.agent]
    unrouted = [d for d in decisions if not d.agent]
    by_agent: dict[str, list[FileDecision]] = {}
    for dec in routed:
        by_agent.setdefault(dec.agent or "", []).append(dec)

    lines: list[str] = []
    lines.append(f"# Auto-memory migration plan ({datetime.now(timezone.utc).isoformat()})")
    lines.append("")
    lines.append(f"source: {source_dir}")
    lines.append(f"target root: {target_root}")
    lines.append(f"total files: {total}")
    lines.append(f"routed by originSessionId: {len(routed)}")
    lines.append(f"needs-review (no route): {len(unrouted)}")
    lines.append("")
    lines.append("## Routed")
    for agent in sorted(by_agent):
        group = by_agent[agent]
        lines.append(f"### {agent} ({len(group)})")
        for dec in sorted(group, key=lambda d: d.source.name):
            lines.append(f"  - {dec.source.name}  ({dec.origin_session_id})")
        lines.append("")
    lines.append("## Needs review (no automatic route)")
    for dec in sorted(unrouted, key=lambda d: d.source.name):
        lines.append(f"  - {dec.source.name}  — {dec.reason}")
    lines.append("")
    return "\n".join(lines)


def active_claude_processes() -> list[str]:
    """Return a list of Claude Code process descriptions, if any."""
    try:
        out = subprocess.run(
            ["pgrep", "-fl", r"claude( |$)"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    procs: list[str] = []
    for line in (out.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        # filter ourselves and obvious non-agent helpers
        if "migrate-auto-memory" in line:
            continue
        if "claude-hud" in line or "claudeCode" in line:
            continue
        procs.append(line)
    return procs


def make_backup(source_dir: Path, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    archive = backup_dir / "source.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(source_dir, arcname=source_dir.name)
    return archive


def hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def seed_settings_local(
    settings_path: Path,
    target_path: str,
) -> str:
    """Apply the PR 1A merge policy to an existing agent's settings."""
    if not settings_path.parent.exists():
        settings_path.parent.mkdir(parents=True, exist_ok=True)

    if not settings_path.exists():
        settings_path.write_text(
            json.dumps({"autoMemoryDirectory": target_path}, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return "created"

    raw = settings_path.read_text(encoding="utf-8")
    if not raw.strip():
        raise RuntimeError(
            f"{settings_path} is empty; inspect or remove before migrating."
        )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"{settings_path} is not valid JSON ({exc}); fix it before migrating."
        ) from exc
    if not isinstance(data, dict):
        raise RuntimeError(
            f"{settings_path} is not a JSON object; fix it before migrating."
        )

    current = data.get("autoMemoryDirectory")
    if current == target_path:
        return "no-op"
    if current not in (None, ""):
        raise RuntimeError(
            f"{settings_path} already sets autoMemoryDirectory to {current!r}; "
            f"expected {target_path!r}. Resolve manually."
        )
    data["autoMemoryDirectory"] = target_path
    tmp = settings_path.with_suffix(settings_path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, settings_path)
    return "upserted"


def strip_auto_memory_directory(settings_path: Path) -> str:
    if not settings_path.exists():
        return "missing"
    raw = settings_path.read_text(encoding="utf-8")
    if not raw.strip():
        return "empty"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return "parse-error"
    if not isinstance(data, dict):
        return "not-object"
    if "autoMemoryDirectory" not in data:
        return "no-key"
    del data["autoMemoryDirectory"]
    if data:
        tmp = settings_path.with_suffix(settings_path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, settings_path)
        return "stripped"
    settings_path.unlink()
    return "removed"


def _write_manifest(manifest_path: Path, manifest: Manifest) -> None:
    """Atomically persist the manifest so restore always sees committed state."""
    tmp = manifest_path.with_suffix(manifest_path.suffix + ".tmp")
    tmp.write_text(manifest.to_json(), encoding="utf-8")
    os.replace(tmp, manifest_path)


def execute_migration(
    decisions: list[FileDecision],
    source_dir: Path,
    target_root: Path,
    backup_dir: Path,
    needs_review_dir: Path,
    agents: dict[str, Path],
    bridge_home: Path,
) -> Manifest:
    """Move files + seed settings, persisting the manifest after every step.

    Rollback contract: at any point during this function, ``manifest.json``
    on disk reflects exactly the moves and seeds that have already
    completed. A partial run (e.g. a mid-seed conflict) therefore leaves
    a consumable manifest that ``restore`` can replay without losing
    track of already-moved files.
    """
    slug = bridge_home_slug(bridge_home)
    # Record the actual agents dir we operated on so restore can target
    # the same homes even when CLI defaults change between runs.
    agents_dir_value = ""
    if agents:
        first_home = next(iter(agents.values()))
        agents_dir_value = str(first_home.parent)
    manifest = Manifest(
        created_at=datetime.now(timezone.utc).isoformat(),
        bridge_home=str(bridge_home),
        source_dir=str(source_dir),
        backup_dir=str(backup_dir),
        slug=slug,
        auto_memory_root=str(target_root),
        agents_dir=agents_dir_value,
    )
    manifest_path = backup_dir / "manifest.json"

    needs_review_dir.mkdir(parents=True, exist_ok=True)
    # Persist an empty manifest before any mutation so a crash before
    # the first move still leaves the restore tool something to read.
    _write_manifest(manifest_path, manifest)

    routed_agents: set[str] = set()
    for dec in decisions:
        src = dec.source
        checksum = hash_file(src)
        if dec.agent:
            agent_dir = target_root / slug / dec.agent
            agent_dir.mkdir(parents=True, exist_ok=True)
            dst = agent_dir / src.name
            routed_agents.add(dec.agent)
        else:
            dst = needs_review_dir / src.name
        if dst.exists():
            raise RuntimeError(
                f"refusing to overwrite existing destination: {dst}"
            )
        shutil.move(str(src), str(dst))
        manifest.moves.append(
            {
                "source": str(src),
                "destination": str(dst),
                "agent": dec.agent,
                "origin_session_id": dec.origin_session_id,
                "reason": dec.reason,
                "sha256": checksum,
            }
        )
        _write_manifest(manifest_path, manifest)
        dec.destination = dst

    # Derive the seeded settings path from the same target_root we moved
    # files into — hardcoding `~/.claude/auto-memory/...` left seeded
    # settings pointing at the default root even when `--target-root`
    # sent the files elsewhere (PR 1B reviewer catch). Keep the `~/`
    # form when the target is under HOME so the seeded settings stay
    # portable; otherwise emit the absolute path.
    home_str = str(Path.home())
    for agent in sorted(routed_agents):
        agent_home = agents.get(agent)
        if agent_home is None:
            continue
        settings_path = agent_home / ".claude" / "settings.local.json"
        agent_target_dir = (target_root / slug / agent).resolve()
        agent_target_str = str(agent_target_dir)
        if agent_target_str == home_str or agent_target_str.startswith(home_str + os.sep):
            target_path = "~" + agent_target_str[len(home_str):]
        else:
            target_path = agent_target_str
        outcome = seed_settings_local(settings_path, target_path)
        if outcome in ("created", "upserted"):
            manifest.seeded_agents.append(agent)
            _write_manifest(manifest_path, manifest)

    return manifest


def cmd_dry_run(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    claude_projects = Path(args.claude_projects).expanduser()
    source_dir = (
        Path(args.source_dir).expanduser()
        if args.source_dir
        else shared_memory_dir(bridge_home, claude_projects)
    )
    target_root = Path(args.target_root).expanduser()
    agents_dir = Path(args.agents_dir).expanduser() if args.agents_dir else (bridge_home / "agents")

    if not source_dir.is_dir():
        sys.stderr.write(f"source dir does not exist: {source_dir}\n")
        return 1

    agents = discover_agents(agents_dir)
    session_to_agent = build_session_to_agent(claude_projects, agents)
    decisions = plan_migration(source_dir, session_to_agent)
    report = render_report(decisions, source_dir, target_root)
    if args.report:
        Path(args.report).expanduser().write_text(report, encoding="utf-8")
    sys.stdout.write(report)
    return 0


def cmd_migrate(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    claude_projects = Path(args.claude_projects).expanduser()
    source_dir = (
        Path(args.source_dir).expanduser()
        if args.source_dir
        else shared_memory_dir(bridge_home, claude_projects)
    )
    target_root = Path(args.target_root).expanduser()
    agents_dir = Path(args.agents_dir).expanduser() if args.agents_dir else (bridge_home / "agents")

    if not source_dir.is_dir():
        sys.stderr.write(f"source dir does not exist: {source_dir}\n")
        return 1

    if not args.yes:
        sys.stderr.write("migrate requires --yes. Run dry-run first.\n")
        return 2

    if not args.force_live:
        procs = active_claude_processes()
        if procs:
            sys.stderr.write(
                "Active Claude processes detected; refusing to migrate. "
                "Stop them or pass --force-live (operator escape hatch).\n"
            )
            for line in procs:
                sys.stderr.write(f"  {line}\n")
            return 3

    ts = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    backup_dir = Path(args.backup_dir).expanduser() / f"auto-memory-migration-{ts}"
    needs_review_dir = backup_dir / "needs-review"

    agents = discover_agents(agents_dir)
    session_to_agent = build_session_to_agent(claude_projects, agents)
    decisions = plan_migration(source_dir, session_to_agent)

    backup_dir.mkdir(parents=True, exist_ok=True)
    make_backup(source_dir, backup_dir)
    report = render_report(decisions, source_dir, target_root)
    (backup_dir / "report.md").write_text(report, encoding="utf-8")

    # execute_migration writes manifest.json incrementally.
    manifest = execute_migration(
        decisions=decisions,
        source_dir=source_dir,
        target_root=target_root,
        backup_dir=backup_dir,
        needs_review_dir=needs_review_dir,
        agents=agents,
        bridge_home=bridge_home,
    )

    sys.stdout.write(f"migration complete. backup+manifest: {backup_dir}\n")
    sys.stdout.write(
        f"files routed: {sum(1 for m in manifest.moves if m['agent'])}, "
        f"needs-review: {sum(1 for m in manifest.moves if not m['agent'])}, "
        f"agents seeded: {len(manifest.seeded_agents)}\n"
    )
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    backup_dir = Path(args.backup_dir).expanduser()
    manifest_path = backup_dir / "manifest.json"
    if not manifest_path.exists():
        sys.stderr.write(f"no manifest found at {manifest_path}\n")
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    if not args.force_live:
        procs = active_claude_processes()
        if procs:
            sys.stderr.write(
                "Active Claude processes detected; refusing to restore. "
                "Stop them or pass --force-live (operator escape hatch).\n"
            )
            for line in procs:
                sys.stderr.write(f"  {line}\n")
            return 3

    restored_count = 0
    for move in manifest.get("moves", []):
        dst = Path(move["destination"])
        src = Path(move["source"])
        if not dst.exists():
            sys.stderr.write(f"skipping missing destination: {dst}\n")
            continue
        src.parent.mkdir(parents=True, exist_ok=True)
        if src.exists():
            sys.stderr.write(f"source path occupied; refusing to overwrite: {src}\n")
            return 2
        shutil.move(str(dst), str(src))
        restored_count += 1

    # Prefer the CLI override, then the manifest-recorded path, then
    # derive from the manifest's bridge_home. This ensures restore hits
    # the same homes migrate touched, even on non-default installs.
    if args.agents_dir:
        agents_dir = Path(args.agents_dir).expanduser()
    elif manifest.get("agents_dir"):
        agents_dir = Path(manifest["agents_dir"]).expanduser()
    elif manifest.get("bridge_home"):
        agents_dir = Path(manifest["bridge_home"]).expanduser() / "agents"
    else:
        sys.stderr.write(
            "manifest has no agents_dir or bridge_home; pass --agents-dir explicitly.\n"
        )
        return 4

    stripped: list[str] = []
    for agent in manifest.get("seeded_agents", []):
        settings_path = agents_dir / agent / ".claude" / "settings.local.json"
        outcome = strip_auto_memory_directory(settings_path)
        if outcome in ("stripped", "removed"):
            stripped.append(agent)

    marker = backup_dir / f"restored-at-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}.txt"
    marker.write_text(
        f"restored {restored_count} files\n"
        f"stripped autoMemoryDirectory from: {', '.join(stripped)}\n",
        encoding="utf-8",
    )
    sys.stdout.write(f"restored {restored_count} files; stripped {len(stripped)} settings.\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--bridge-home", default=str(DEFAULT_BRIDGE_HOME))
    common.add_argument("--claude-projects", default=str(DEFAULT_CLAUDE_PROJECTS))
    common.add_argument("--source-dir", default=None, help="override auto-detected shared memory dir")
    common.add_argument("--target-root", default=str(DEFAULT_AUTO_MEMORY_ROOT))
    common.add_argument(
        "--agents-dir",
        default=None,
        help="override agents dir (default: <bridge-home>/agents)",
    )

    p_dry = sub.add_parser("dry-run", parents=[common], help="plan migration without writing")
    p_dry.add_argument("--report", default=None, help="write plan to this path in addition to stdout")
    p_dry.set_defaults(func=cmd_dry_run)

    p_mig = sub.add_parser("migrate", parents=[common], help="execute migration")
    p_mig.add_argument("--yes", action="store_true", help="confirm destructive action")
    p_mig.add_argument("--force-live", action="store_true", help="migrate even while Claude processes are running")
    p_mig.add_argument("--backup-dir", default=str(DEFAULT_BACKUP_ROOT))
    p_mig.set_defaults(func=cmd_migrate)

    p_res = sub.add_parser("restore", help="reverse a migration using its manifest")
    p_res.add_argument("--backup-dir", required=True, help="backup directory containing manifest.json")
    p_res.add_argument(
        "--agents-dir",
        default=None,
        help="override agents dir (default: manifest.agents_dir, then manifest.bridge_home/agents)",
    )
    p_res.add_argument("--force-live", action="store_true", help="restore even while Claude processes are running")
    p_res.set_defaults(func=cmd_restore)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
