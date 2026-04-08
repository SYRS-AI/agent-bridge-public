#!/usr/bin/env python3
"""Helpers for smart Agent Bridge upgrade flows."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path


def render_template(text: str, agent_id: str, display_name: str, role_text: str, engine: str, session_type: str) -> str:
    runtime = "Claude Code CLI" if engine == "claude" else "Codex CLI"
    replacements = {
        "<Agent Name>": display_name,
        "<agent-id>": agent_id,
        "<Role>": role_text,
        "<Role Summary>": role_text,
        "<Runtime>": runtime,
        "<Boss>": "관리자 에이전트",
        "<한 줄 역할 설명>": role_text,
        "<표시 이름>": display_name,
        "<Session Type>": session_type,
        "<핵심 책임>": role_text,
        "<주 요청자>": "관리자 에이전트",
        "<Claude Code CLI | Codex CLI>": runtime,
        "<반드시 지킬 운영 규칙>": "큐를 source of truth로 삼고, claim/done note를 생략하지 않는다.",
        "<위험 작업 제한>": "크리티컬 변경 전에는 dry-run 또는 관련 상태 확인을 먼저 수행한다.",
        "<보고 방식>": "결과는 요청자 채널 또는 task queue로 반드시 남긴다.",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def discover_agent_dirs(agent_root: Path) -> list[Path]:
    if not agent_root.exists():
        return []
    results: list[Path] = []
    for path in sorted(agent_root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        results.append(path)
    return results


def detect_display_name(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        match = re.search(r"^#\s+(.+?)\s+—\s+.+$", claude_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    soul_path = agent_dir / "SOUL.md"
    if soul_path.exists():
        match = re.search(r"^#\s+(.+?)\s+Soul$", soul_path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            return match.group(1).strip()
    return agent_dir.name


def detect_role_text(agent_dir: Path) -> str:
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists():
        text = claude_path.read_text(encoding="utf-8", errors="ignore")
        match = re.search(r"^#\s+.+?\s+—\s+(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
        match = re.search(r"- \*\*역할\*\*:\s*(.+)$", text, re.M)
        if match:
            return match.group(1).strip()
    return "Bridge-managed agent"


def detect_session_type(agent_dir: Path, admin_agent: str) -> str:
    session_path = agent_dir / "SESSION-TYPE.md"
    if session_path.exists():
        match = re.search(r"Session Type:\s*([A-Za-z0-9._-]+)", session_path.read_text(encoding="utf-8", errors="ignore"))
        if match:
            return match.group(1).strip()
    if agent_dir.name == admin_agent:
        return "admin"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and "Codex CLI" in claude_path.read_text(encoding="utf-8", errors="ignore"):
        return "static-codex"
    return "static-claude"


def detect_engine(agent_dir: Path, session_type: str) -> str:
    if session_type == "static-codex":
        return "codex"
    claude_path = agent_dir / "CLAUDE.md"
    if claude_path.exists() and "Codex CLI" in claude_path.read_text(encoding="utf-8", errors="ignore"):
        return "codex"
    return "claude"


@dataclass
class AgentMigrationResult:
    agent: str
    added_files: list[str]
    created_dirs: list[str]
    session_type: str
    engine: str


def migrate_agent_home(agent_dir: Path, template_root: Path, admin_agent: str, dry_run: bool) -> AgentMigrationResult:
    agent = agent_dir.name
    session_type = detect_session_type(agent_dir, admin_agent)
    engine = detect_engine(agent_dir, session_type)
    display_name = detect_display_name(agent_dir)
    role_text = detect_role_text(agent_dir)
    added_files: list[str] = []
    created_dirs: list[str] = []

    for path in sorted(template_root.rglob("*")):
        rel = path.relative_to(template_root)
        if rel.parts and rel.parts[0] == "session-types":
            continue
        target = agent_dir / rel
        if path.is_dir():
            if not target.exists():
                created_dirs.append(rel.as_posix())
                if not dry_run:
                    target.mkdir(parents=True, exist_ok=True)
            continue
        if target.exists():
            continue
        added_files.append(rel.as_posix())
        if dry_run:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        rendered = render_template(path.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type)
        target.write_text(rendered, encoding="utf-8")

    session_template = template_root / "session-types" / f"{session_type}.md"
    session_target = agent_dir / "SESSION-TYPE.md"
    if not session_target.exists() and session_template.exists():
        added_files.append("SESSION-TYPE.md")
        if not dry_run:
            session_target.parent.mkdir(parents=True, exist_ok=True)
            session_target.write_text(
                render_template(session_template.read_text(encoding="utf-8"), agent, display_name, role_text, engine, session_type),
                encoding="utf-8",
            )

    return AgentMigrationResult(
        agent=agent,
        added_files=added_files,
        created_dirs=created_dirs,
        session_type=session_type,
        engine=engine,
    )


def cmd_migrate_agents(args: argparse.Namespace) -> int:
    template_root = Path(args.source_root).expanduser() / "agents" / "_template"
    agent_root = Path(args.target_root).expanduser() / "agents"
    admin_agent = (args.admin_agent or "").strip()
    results = [migrate_agent_home(path, template_root, admin_agent, args.dry_run) for path in discover_agent_dirs(agent_root)]
    payload = {
        "agent_count": len(results),
        "agents_with_additions": sum(1 for item in results if item.added_files or item.created_dirs),
        "added_files": sum(len(item.added_files) for item in results),
        "created_dirs": sum(len(item.created_dirs) for item in results),
        "agents": [asdict(item) for item in results],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def copy_live_backup(target_root: Path, backup_root: Path) -> None:
    backup_live = backup_root / "live"
    backup_live.mkdir(parents=True, exist_ok=True)
    for child in sorted(target_root.iterdir()):
        if child.name == "backups":
            continue
        dst = backup_live / child.name
        if child.is_dir():
            shutil.copytree(child, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(child, dst, follow_symlinks=False)


def cmd_backup_live(args: argparse.Namespace) -> int:
    target_root = Path(args.target_root).expanduser()
    backup_root = Path(args.backup_root).expanduser()
    payload = {
        "target_root": str(target_root),
        "backup_root": str(backup_root),
        "exists": target_root.exists(),
        "created": False,
    }
    if target_root.exists() and not args.dry_run:
        copy_live_backup(target_root, backup_root)
        payload["created"] = True
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-upgrade.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate = subparsers.add_parser("migrate-agents")
    migrate.add_argument("--source-root", required=True)
    migrate.add_argument("--target-root", required=True)
    migrate.add_argument("--admin-agent", default="")
    migrate.add_argument("--dry-run", action="store_true")
    migrate.set_defaults(handler=cmd_migrate_agents)

    backup = subparsers.add_parser("backup-live")
    backup.add_argument("--target-root", required=True)
    backup.add_argument("--backup-root", required=True)
    backup.add_argument("--dry-run", action="store_true")
    backup.set_defaults(handler=cmd_backup_live)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
