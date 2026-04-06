#!/usr/bin/env python3
"""bridge-docs.py — audit and normalize bridge-owned agent home docs."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"
TODAY = datetime.now().strftime("%Y-%m-%d")

REMOVABLE_DOCS = ("AGENTS.md", "IDENTITY.md", "BOOTSTRAP.md")
SHARED_SOURCE_FILES = ("ROSTER.md", "SYRS-CONTEXT.md", "SYRS-RULES.md", "SYRS-USER.md")
AGENT_SHARED_LINKS = ("TOOLS.md", "ROSTER.md", "SYRS-CONTEXT.md", "SYRS-RULES.md", "SYRS-USER.md")
AGENT_RUNTIME_REWRITE_FILES = ("SOUL.md", "HEARTBEAT.md", "CHECKLIST.md", "MEMORY.md")
LEGACY_PATTERNS = (
    "openclaw message send",
    "sessions_send",
    "sessions_spawn",
    "sessions_history",
    "openclaw cron add",
    "~/agent-bridge/state/tasks.db",
    "/Users/soonseokoh/agent-bridge/state/tasks.db",
    "~/.openclaw/",
    "/Users/soonseokoh/.openclaw/",
)


@dataclass
class AgentAudit:
    agent: str
    removable_docs: list[str]
    broken_links: list[str]
    local_skills: list[str]
    reference_files: list[str]
    claude_legacy_hits: list[str]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def pretty_path(path: Path) -> str:
    return str(path).replace(str(Path.home()), "~")


def write_text(path: Path, content: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def copy_path(src: Path, dst: Path, dry_run: bool) -> None:
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        if dst.exists() and not dst.is_dir():
            if dst.is_symlink() or dst.is_file():
                dst.unlink()
            else:
                shutil.rmtree(dst)
        shutil.copytree(src, dst, dirs_exist_ok=True)
        return
    shutil.copy2(src, dst)


def ensure_symlink(link_path: Path, target: str, dry_run: bool) -> None:
    current = link_path.is_symlink() and os.readlink(link_path) == target
    if current:
        return
    if dry_run:
        return
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.exists() or link_path.is_symlink():
        if link_path.is_dir() and not link_path.is_symlink():
            shutil.rmtree(link_path)
        else:
            link_path.unlink()
    link_path.symlink_to(target)


def backup_file(src: Path, backup_root: Path, dry_run: bool) -> None:
    if not src.exists() and not src.is_symlink():
        return
    if dry_run:
        return
    backup_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, backup_root / src.name)


def list_agent_dirs(target_root: Path, selected: list[str], all_agents: bool) -> list[Path]:
    candidates = []
    for path in sorted(target_root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in {"_template", "shared"}:
            continue
        candidates.append(path)
    if all_agents or not selected:
        return candidates
    selected_set = set(selected)
    return [path for path in candidates if path.name in selected_set]


def collect_relative_files(base: Path, child: str) -> list[str]:
    path = base / child
    if not path.exists():
        return []
    if path.is_file():
        return [child]
    results = []
    for item in sorted(path.rglob("*")):
        if item.is_file():
            results.append(str(item.relative_to(base)))
    return results


def collect_broken_links(agent_dir: Path) -> list[str]:
    broken = []
    for path in agent_dir.rglob("*"):
        if path.is_symlink() and not path.exists():
            broken.append(f"{path.relative_to(agent_dir)} -> {os.readlink(path)}")
    return broken


def audit_agent(agent_dir: Path) -> AgentAudit:
    removable_docs = [name for name in REMOVABLE_DOCS if (agent_dir / name).exists()]
    local_skills = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    claude_path = agent_dir / "CLAUDE.md"
    claude_hits: list[str] = []
    if claude_path.exists():
        claude_text = re.sub(
            rf"{re.escape(MANAGED_START)}.*?{re.escape(MANAGED_END)}\n*",
            "",
            read_text(claude_path),
            flags=re.S,
        )
        for pattern in LEGACY_PATTERNS:
            if pattern in claude_text:
                claude_hits.append(pattern)
    return AgentAudit(
        agent=agent_dir.name,
        removable_docs=removable_docs,
        broken_links=collect_broken_links(agent_dir),
        local_skills=local_skills,
        reference_files=reference_files,
        claude_legacy_hits=claude_hits,
    )


def render_shared_override(name: str) -> str:
    bullets_by_file = {
        "ROSTER.md": [
            "이 파일은 현재 `~/.agent-bridge/shared/ROSTER.md`에서 관리된다.",
            "에이전트 간 durable 통신의 기본값은 `~/.agent-bridge/agent-bridge task create|urgent|handoff`다.",
            "본문에 남아 있는 옛 queue/send/gateway 설명은 역사적 참고 정보다.",
            "현재 live roster/queue 상태는 `~/.agent-bridge/agent-bridge status`와 `~/.agent-bridge/state/active-roster.md`가 기준이다.",
        ],
        "SYRS-RULES.md": [
            "이 파일은 현재 Agent Bridge 런타임 기준으로 읽는다.",
            "본문에 남아 있는 옛 message/cron 예시는 역사적 참고 정보다.",
            "사람에게 보이는 Discord/Telegram 출력은 연결된 Claude 세션 또는 bridge notify path를 사용한다.",
            "시스템 전역 변경 승인 규칙은 Agent Bridge, 남은 OpenClaw compatibility layer, Claude/Codex runtime 전부에 적용된다.",
        ],
        "SYRS-CONTEXT.md": [
            "이 파일의 비즈니스 팩트는 그대로 SSOT다.",
            "문서 위치만 `~/.agent-bridge/shared/SYRS-CONTEXT.md`로 옮겼다.",
            "툴/전송 메커니즘은 `TOOLS.md`와 각 에이전트 `CLAUDE.md`의 Agent Bridge block을 따른다.",
        ],
    }
    bullets = bullets_by_file.get(name)
    if not bullets:
        return ""
    lines = [
        f"## Agent Bridge Migration Override ({TODAY})",
        *(f"- {bullet}" for bullet in bullets),
        "- 아래 본문과 충돌하면 이 override가 우선이다.",
    ]
    return "\n".join(lines) + "\n"


def inject_after_heading(text: str, block: str) -> str:
    if not block:
        return text
    if text.startswith("# "):
        first, rest = text.split("\n", 1) if "\n" in text else (text, "")
        return f"{first}\n\n{block}\n{rest.lstrip()}"
    return f"{block}\n{text}"


def render_shared_tools_md(bridge_home: Path) -> str:
    home = pretty_path(bridge_home)
    return f"""# TOOLS.md — Agent Bridge Shared Runtime

<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->

## Canonical Queue Commands
- Dashboard: `{home}/agent-bridge status`
- Inbox 확인: `{home}/agb inbox <agent>`
- 태스크 상세: `{home}/agb show <task-id>`
- claim / done: `{home}/agb claim <task-id> --agent <agent>` / `{home}/agb done <task-id> --agent <agent>`
- durable A2A: `{home}/agent-bridge task create --to <agent> --title "..." --body-file {home}/shared/report.md`
- urgent interrupt: `{home}/agent-bridge urgent <agent> "..."`
- handoff: `{home}/agent-bridge handoff <task-id> --to <agent> --note "..."`

## Human-Facing Output
- Discord/Telegram 보고는 연결된 Claude 세션 안에서 자연스럽게 응답한다.
- 레거시 direct-send CLI를 직접 호출하지 않는다.
- 브리지 알림이 필요하면 queue 또는 bridge notify path를 사용한다.

## Cron
- inventory/list/create/update/delete: `{home}/agent-bridge cron ...`
- 옛 cron helper 예시는 더 이상 기준이 아니다.

## Queue State
- live queue는 `{home}/state/tasks.db`에 있다.
- 하지만 직접 sqlite를 두드리는 대신 `agb inbox/show/claim/done/summary`를 사용한다.
- repo checkout의 `~/agent-bridge/state/tasks.db`는 live state의 기준이 아니다.

## Subagents
- bridge-managed disposable child가 필요하면 현재 engine의 disposable runner를 사용한다.
- 옛 child-session 예시는 더 이상 기준이 아니다.

## Shared References
- 비즈니스 SSOT: `{home}/shared/SYRS-CONTEXT.md`
- 팀 규칙: `{home}/shared/SYRS-RULES.md`
- 사용자 정보: `{home}/shared/SYRS-USER.md`
- roster: `{home}/shared/ROSTER.md`
- 스킬 가이드: `{home}/shared/SKILLS.md`
"""


def render_shared_skills_md(bridge_home: Path) -> str:
    home = pretty_path(bridge_home)
    return f"""# SKILLS.md — Agent Bridge Shared Skill Guide

<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->

## Bridge-Native Skills
- bridge coordination skill: `<agent>/.claude/skills/agent-bridge-project/`
- agent-local skills: `<agent>/skills/`
- shared references: `{home}/shared/references/`

## Usage Rules
- 먼저 각 에이전트의 `CLAUDE.md`와 `SOUL.md`를 읽고, 필요한 경우 이 파일과 local `skills/`를 확인한다.
- `skills/`에 있는 문서형 스킬은 해당 파일을 먼저 읽고 절차를 따른다.
- `references/`는 supporting material이지 실행 명령 목록이 아니다.

## Migration Compatibility
- 예전 메모나 참고 문서에 외부 skill 경로가 남아 있더라도 canonical runtime은 bridge-local skill registry다.
- bridge-local 대체가 있으면 그쪽을 우선한다.
- 아직 외부 위치에 남은 스킬은 실행 전 현재 동작 여부를 검증하고 migration debt로 기록한다.
"""


def rewrite_shared_legacy_text(name: str, bridge_home: Path, text: str) -> str:
    runtime_root = pretty_path(bridge_home / "runtime")
    replacements = {
        "~/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "$HOME/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "/Users/soonseokoh/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "~/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "$HOME/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "/Users/soonseokoh/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "~/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "$HOME/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "/Users/soonseokoh/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "~/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "$HOME/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "/Users/soonseokoh/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "~/.openclaw/skills/": f"{runtime_root}/skills/",
        "$HOME/.openclaw/skills/": f"{runtime_root}/skills/",
        "/Users/soonseokoh/.openclaw/skills/": f"{runtime_root}/skills/",
        "~/.openclaw/data/": f"{runtime_root}/data/",
        "$HOME/.openclaw/data/": f"{runtime_root}/data/",
        "/Users/soonseokoh/.openclaw/data/": f"{runtime_root}/data/",
        "~/.openclaw/assets/": f"{runtime_root}/assets/",
        "$HOME/.openclaw/assets/": f"{runtime_root}/assets/",
        "/Users/soonseokoh/.openclaw/assets/": f"{runtime_root}/assets/",
        "~/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "$HOME/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "/Users/soonseokoh/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "~/.openclaw/shared/a2a-files/": "~/.agent-bridge/shared/a2a-files/",
        "$HOME/.openclaw/shared/a2a-files/": "~/.agent-bridge/shared/a2a-files/",
        "/Users/soonseokoh/.openclaw/shared/a2a-files/": "~/.agent-bridge/shared/a2a-files/",
        "bash ~/.openclaw/scripts/codex-review.sh review main": "agent-bridge task create --to patch --title \"[REVIEW] 변경 검토\" --body \"변경 내용과 검토 포인트를 함께 전달\"",
        "bash ~/.openclaw/scripts/codex-review.sh plan /path/to/plan.md": "agent-bridge task create --to patch --title \"[PLAN-REVIEW] 계획 검토\" --body-file /path/to/plan.md",
        "bash ~/.openclaw/scripts/codex-review.sh review [base] [instructions]": "agent-bridge task create --to patch --title \"[REVIEW] 변경 검토\" --body \"base와 검토 포인트를 함께 전달\"",
        "bash ~/.openclaw/scripts/codex-review.sh plan <file>": "agent-bridge task create --to patch --title \"[PLAN-REVIEW] 계획 검토\" --body-file <file>",
        "bash ~/.openclaw/scripts/codex-review.sh challenge [focus]": "agent-bridge task create --to patch --title \"[CHALLENGE] 적대적 분석\" --body \"focus를 함께 전달\"",
        "bash ~/.openclaw/scripts/codex-review.sh consult \"<prompt>\"": "agent-bridge task create --to patch --title \"[CONSULT]\" --body \"<prompt>\"",
        "python3 ~/.openclaw/skills/task-log/scripts/task-log.py": f"python3 {runtime_root}/skills/task-log/scripts/task-log.py",
        "Discord #patch 채널 웹훅": "`agent-bridge task create --to patch` 또는 `agent-bridge urgent patch`",
        "localhost:8787/hooks/patch-trigger": "`agent-bridge urgent patch`",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)

    if name in {"SYRS-RULES.md", "ROSTER.md", "SYRS-CONTEXT.md"}:
        text = text.replace("A2A(sessions_send)", "A2A(agent-bridge task create)")
        text = text.replace("sessions_send/sessions_spawn", "agent-bridge task create/urgent")
        text = text.replace("sessions_spawn", "bridge disposable child")
        text = text.replace("sessions_history", "bridge task/MEMORY context")
        text = text.replace("sessions_send", "agent-bridge task create")
        text = text.replace("openclaw message send", "연결된 Claude 세션 응답")
        text = text.replace("패치는 OpenClaw 에이전트가 아님", "패치는 Agent Bridge 관리자 역할")

    return text


def rewrite_agent_runtime_text(agent_dir: Path, text: str) -> str:
    text = normalize_legacy_paths(text)
    runtime_root = "~/.agent-bridge/runtime"
    replacements = {
        "~/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "$HOME/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "/Users/soonseokoh/.openclaw/credentials/": f"{runtime_root}/credentials/",
        "~/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "$HOME/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "/Users/soonseokoh/.openclaw/secrets/": f"{runtime_root}/secrets/",
        "~/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "$HOME/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "/Users/soonseokoh/.openclaw/openclaw.json": f"{runtime_root}/openclaw.json",
        "~/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "$HOME/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "/Users/soonseokoh/.openclaw/scripts/": f"{runtime_root}/scripts/",
        "~/.openclaw/skills/": f"{runtime_root}/skills/",
        "$HOME/.openclaw/skills/": f"{runtime_root}/skills/",
        "/Users/soonseokoh/.openclaw/skills/": f"{runtime_root}/skills/",
        "~/.openclaw/data/": f"{runtime_root}/data/",
        "$HOME/.openclaw/data/": f"{runtime_root}/data/",
        "/Users/soonseokoh/.openclaw/data/": f"{runtime_root}/data/",
        "~/.openclaw/assets/": f"{runtime_root}/assets/",
        "$HOME/.openclaw/assets/": f"{runtime_root}/assets/",
        "/Users/soonseokoh/.openclaw/assets/": f"{runtime_root}/assets/",
        "~/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "$HOME/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "/Users/soonseokoh/.openclaw/extensions/": f"{runtime_root}/extensions/",
        "~/.openclaw/memory/": f"{runtime_root}/memory/",
        "$HOME/.openclaw/memory/": f"{runtime_root}/memory/",
        "/Users/soonseokoh/.openclaw/memory/": f"{runtime_root}/memory/",
        "sessions_send": "agent-bridge task create",
        "sessions_spawn": "bridge disposable child",
        "sessions_history": "bridge task/MEMORY context",
        "openclaw message send": "연결된 Claude 세션 응답",
        "localhost:8787/hooks/patch-trigger": "`agent-bridge urgent patch`",
        "Discord #patch 채널 웹훅": "`agent-bridge task create --to patch` 또는 `agent-bridge urgent patch`",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)

    if agent_dir.name == "patch":
        text = text.replace("~/.openclaw/patch/", "~/.agent-bridge/agents/patch/")
        text = text.replace("/Users/soonseokoh/.openclaw/patch/", "~/.agent-bridge/agents/patch/")
        text = text.replace("~/.agent-bridge/agents/patches/", "~/.agent-bridge/runtime/patches/")
        text = text.replace(
            "- **⚠️ `agent-bridge task create`로 patch 호출 불가** — allow 리스트에서 제거됨, 에러 발생함",
            "- patch 호출은 `agent-bridge task create --to patch` 또는 `agent-bridge urgent patch \"...\"`를 사용한다.",
        )
        text = text.replace(
            "- **⚠️ 기존 `curl `agent-bridge urgent patch``는 사용 금지** — 코드는 남아있지만(롤백용) 에이전트는 Discord webhook만 사용",
            "- **⚠️ 기존 localhost patch trigger는 사용 금지** — 지금은 `agent-bridge task create --to patch` 또는 `agent-bridge urgent patch \"...\"`만 사용한다.",
        )
        text = text.replace(
            "- LaunchAgent logs: `~/.openclaw/logs/gateway.log`, `gateway.err.log`",
            "- Bridge logs: `~/.agent-bridge/logs/`",
        )

    return text


def normalize_agent_runtime_file(path: Path, agent_dir: Path, dry_run: bool, backup_root: Path) -> bool:
    if not path.exists() or not path.is_file():
        return False
    original = read_text(path)
    rewritten = rewrite_agent_runtime_text(agent_dir, original)
    if rewritten == original:
        return False
    backup_file(path, backup_root, dry_run)
    write_text(path, rewritten, dry_run)
    return True


def sync_shared_docs(bridge_home: Path, source_shared: Path, dry_run: bool) -> list[str]:
    changed: list[str] = []
    target_shared = bridge_home / "shared"
    target_refs = target_shared / "references"
    if not dry_run:
        target_shared.mkdir(parents=True, exist_ok=True)
    ensure_symlink(bridge_home / "agents" / "shared", "../shared", dry_run)

    for name in SHARED_SOURCE_FILES:
        src = source_shared / name
        if not src.exists():
            continue
        text = inject_after_heading(read_text(src), render_shared_override(name))
        text = normalize_legacy_paths(text)
        text = rewrite_shared_legacy_text(name, bridge_home, text)
        dst = target_shared / name
        old = read_text(dst) if dst.exists() else None
        if old != text:
            write_text(dst, text, dry_run)
            changed.append(str(dst))

    source_refs = source_shared / "references"
    if source_refs.exists():
        for ref in sorted(source_refs.rglob("*")):
            if not ref.is_file():
                continue
            dst = target_refs / ref.relative_to(source_refs)
            if not dst.exists() or read_text(dst) != read_text(ref):
                copy_path(ref, dst, dry_run)
                changed.append(str(dst))

    for name, renderer in (("TOOLS.md", render_shared_tools_md), ("SKILLS.md", render_shared_skills_md)):
        dst = target_shared / name
        text = renderer(bridge_home)
        old = read_text(dst) if dst.exists() else None
        if old != text:
            write_text(dst, text, dry_run)
            changed.append(str(dst))

    return changed


def normalize_legacy_paths(text: str) -> str:
    replacements = {
        "/Users/soonseokoh/agent-bridge/state/tasks.db": "~/.agent-bridge/state/tasks.db",
        "~/agent-bridge/state/tasks.db": "~/.agent-bridge/state/tasks.db",
        "/Users/soonseokoh/agent-bridge/shared/": "~/.agent-bridge/shared/",
        "~/agent-bridge/shared/": "~/.agent-bridge/shared/",
        "/Users/soonseokoh/.openclaw/shared/": "~/.agent-bridge/shared/",
        "~/.openclaw/shared/": "~/.agent-bridge/shared/",
        "$HOME/.openclaw/shared/": "~/.agent-bridge/shared/",
        "/Users/soonseokoh/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        "~/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        "$HOME/.openclaw/assets/": "~/.agent-bridge/runtime/assets/",
        "/Users/soonseokoh/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        "~/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        "$HOME/.openclaw/extensions/": "~/.agent-bridge/runtime/extensions/",
        "/Users/soonseokoh/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        "~/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        "$HOME/.openclaw/vault/": "~/.agent-bridge/runtime/vault/",
        "/Users/soonseokoh/.openclaw/agents/": "~/.agent-bridge/agents/",
        "~/.openclaw/agents/": "~/.agent-bridge/agents/",
        "$HOME/.openclaw/agents/": "~/.agent-bridge/agents/",
        "/Users/soonseokoh/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        "/Users/soonseokoh/.openclaw/patch": "~/.agent-bridge/agents/patch",
        "~/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        "~/.openclaw/patch": "~/.agent-bridge/agents/patch",
        "$HOME/.openclaw/patch/": "~/.agent-bridge/agents/patch/",
        "$HOME/.openclaw/patch": "~/.agent-bridge/agents/patch",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    text = re.sub(
        r"(?:~|/Users/soonseokoh)/\.openclaw/workspace-([A-Za-z0-9._-]+)",
        r"~/.agent-bridge/agents/\1",
        text,
    )
    text = re.sub(
        r"(?:~|/Users/soonseokoh)/\.openclaw/workspace\b",
        "~/.agent-bridge/agents/main",
        text,
    )
    return normalize_openclaw_home_variants(text)


def normalize_openclaw_home_variants(text: str) -> str:
    text = re.sub(
        r"\$HOME/\.openclaw/workspace-([A-Za-z0-9._-]+)",
        r"~/.agent-bridge/agents/\1",
        text,
    )
    return re.sub(
        r"\$HOME/\.openclaw/workspace\b",
        "~/.agent-bridge/agents/main",
        text,
    )


def extract_identity_snapshot(identity_path: Path) -> list[str]:
    if not identity_path.exists():
        return []
    lines = []
    for raw in read_text(identity_path).splitlines():
        line = raw.strip()
        if line.startswith("- **"):
            lines.append(line)
    return lines[:5]


def render_agent_bridge_block(agent_dir: Path) -> str:
    identity_lines = extract_identity_snapshot(agent_dir / "IDENTITY.md")
    local_skill_files = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    lines = [
        MANAGED_START,
        "## Agent Bridge Runtime Canon",
        "- `SOUL.md`가 성격과 말투의 기준이다. 매 세션 시작 시 가장 먼저 읽는다.",
        "- `CLAUDE.md`는 운영 계약서다. 레거시 문서나 오래된 메모와 충돌하면 이 파일이 우선한다.",
        "- `MEMORY.md`와 `memory/`는 작업 메모리다. `HEARTBEAT.md`는 필요할 때만 읽는 운영 참고 문서다.",
        "- `TOOLS.md`와 `SKILLS.md`는 현재 bridge-native runtime reference다.",
        "",
        "## Queue & Delivery",
        "- inbox / task 상태 확인은 `~/.agent-bridge/agb inbox|show|claim|done`를 사용한다.",
        "- durable A2A는 `~/.agent-bridge/agent-bridge task create|urgent|handoff`를 사용한다.",
        "- 사람에게 보이는 Discord/Telegram 응답은 연결된 Claude 세션 안에서 처리한다. direct-send CLI는 기본 경로가 아니다.",
        "- subagent가 필요하면 bridge-managed disposable child 또는 현재 엔진의 정식 subagent 기능을 사용한다. 옛 child-session 헬퍼는 기준이 아니다.",
        "",
        "## Task Processing Protocol",
        "task를 수신하면 아래 순서를 반드시 따른다:",
        "1. **claim**: `agb claim <task_id>` — 다른 에이전트의 중복 작업 방지",
        "2. **처리**: task body를 읽고 요청된 작업 수행",
        "3. **결과 전달**: 처리 결과를 요청자가 볼 수 있는 surface에 반드시 전달",
        "   - 사람이 최종 수신자 → 연결된 채널 세션(Discord/Telegram)에 메시지",
        "   - 다른 에이전트가 요청자 → `agent-bridge task create --to <요청자>`로 결과 전달",
        "4. **done**: `agb done <task_id> --note \"요약\"` — 반드시 note에 무엇을 했는지 기록",
        "- **조용한 done 금지**: 결과를 아무에게도 전달하지 않은 채 done만 치는 것은 금지",
        "- **빈 note done 금지**: --note 없이 done 금지",
        "- `[cron-followup]`에 `needs_human_followup=true` → 반드시 사용자 채널로 전달 후 done",
        "- 인프라 장애 → `agent-bridge urgent patch \"...\"`, 비즈니스 판단 필요 → 사람 채널로 에스컬레이션",
        "- 15분 이상 blocked → `agb update <task_id> --status blocked --note \"사유\"`",
        "",
        "## Legacy Guardrails",
        "- repo checkout의 `~/agent-bridge/state/tasks.db`를 보지 않는다. live queue는 `~/.agent-bridge/state/tasks.db`이며, 직접 sqlite 대신 bridge CLI를 우선한다.",
        "- 공용 운영 문서는 `~/.agent-bridge/shared/*`를 기준으로 읽는다.",
        "- cron 생성/수정은 `~/.agent-bridge/agent-bridge cron ...`를 사용한다.",
        "- 예전 `AGENTS.md`, `IDENTITY.md`, `BOOTSTRAP.md`의 규칙은 여기로 흡수되었다. 삭제된 파일을 기준으로 삼지 않는다.",
    ]
    if identity_lines:
        lines.extend(["", "## Identity Snapshot", *identity_lines])
    if local_skill_files or reference_files:
        lines.extend(["", "## Local Assets"])
        if local_skill_files:
            lines.append("- local skills:")
            lines.extend([f"  - `{entry}`" for entry in local_skill_files])
        if reference_files:
            lines.append("- local references:")
            lines.extend([f"  - `{entry}`" for entry in reference_files])
    lines.append(MANAGED_END)
    return "\n".join(lines)


COMMON_CLAUDE_REPLACEMENTS = {
    '5. Run the DB preflight steps described in `AGENTS.md` before sending anything; if compaction recovery is pending, wait for verification rather than guessing.': '5. Run the DB preflight steps described in `TOOLS.md` before sending anything; if compaction recovery is pending, wait for verification rather than guessing.',
    '6. Confirm that the workspace files you need (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `ROSTER.md`, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.': '6. Confirm that the workspace files you need (`SOUL.md`, `TOOLS.md`, `ROSTER.md`, the user files, and the memory tree) are accessible. If something is missing, document it in your notes before you proceed.',
    '- Replace `sessions_send(sessionKey="agent:<id>:main", …)` calls with `agent-bridge task create --to <agent>` for the intended recipient, and `agent-bridge urgent` for interrupts. Add context so the receiving agent knows why the request exists.': '- Durable delegation uses `agent-bridge task create --to <agent>`. True interrupts use `agent-bridge urgent <agent> "..."`. Always include enough context for the receiver to work from the queue alone.',
    '- **Telegram** – respond through Claude Code `--channels plugin:telegram`. The plugin mimics the old `openclaw message send` behavior; you do not run that CLI anymore. If a job needs a Telegram nudge, craft the message inside Claude Code and let the plugin deliver it.': '- **Telegram** – respond through Claude Code `--channels plugin:telegram`. If a job needs a Telegram nudge, craft it in the live session and let the plugin deliver it.',
    '- **Bridge queue** – when another agent asks you to do something, create a durable task rather than replying via `sessions_send`. Always include the full context so the queue consumer does not have to open the old gateway stacks.': '- **Bridge queue** – when another agent asks you to do something, create a durable task with enough context for the receiver to work from the queue alone.',
    '- 기존 `sessions_send` 기반 위임은 `agent-bridge task create --to <agent>`로 번역한다. durable delegation은 Bridge queue가 기본이다.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다. 긴급 인터럽트만 `agent-bridge urgent <agent> "..."`를 쓴다.',
    '- `openclaw message send`는 Claude Code CLI에서 직접 쓰지 않는다. Discord-connected `huchu` 세션이 채널과 DM의 전달 경로다.': '- Discord 보고와 DM escalation은 연결된 `huchu` 세션 안에서 직접 처리한다.',
    '- 예전 `sessions_send(timeoutSeconds=0)`의 의미는 "즉시 fan-out 후 나중에 수집"이었다. Bridge에서도 같은 프로젝트의 child task는 가능하면 한 burst로 만든다.': '- fan-out semantics는 유지한다: 같은 프로젝트의 child task는 가능하면 한 burst로 만들고, 결과는 수집 후 한 번만 보고한다.',
    '- Old `sessions_send` mail routing becomes `agent-bridge task create --to <agent>` with a full `[MAIL]`, `[SEND-MAIL]`, or `[REPLY-MAIL]` style payload.': '- 메일 라우팅과 회신 handoff는 `agent-bridge task create --to <agent>`로 보낸다. payload에는 `[MAIL]`, `[SEND-MAIL]`, `[REPLY-MAIL]` 맥락을 그대로 담는다.',
    '- Do not use `openclaw message send` directly. In Claude Code, a Discord-connected `mailbot` session is the channel surface.': '- 사람에게 보이는 Discord 상태 공유는 연결된 `mailbot` 세션 안에서 직접 처리한다.',
    '- Old `sessions_send` reporting becomes `agent-bridge task create --to huchu`.': '- 정기 보고와 handoff는 `agent-bridge task create --to huchu`를 사용한다.',
    '- Old `sessions_send` reports become `agent-bridge task create --to huchu`.': '- 정기 보고와 handoff는 `agent-bridge task create --to huchu`를 사용한다.',
    '- Old `sessions_send` reporting becomes `agent-bridge task create --to <agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` reports become `agent-bridge task create --to <agent>`.': '- 정기 보고와 handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` becomes `agent-bridge task create --to <agent>`.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` delegation becomes `agent-bridge task create --to <agent>`.': '- durable delegation은 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` handoffs become `agent-bridge task create --to <agent>`.': '- handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send` consults become `agent-bridge task create --to <agent>`.': '- consult handoff는 `agent-bridge task create --to <agent>`를 사용한다.',
    '- Old `sessions_send`/`sessions_spawn` style QA orchestration becomes bridge tasks plus Claude subagent features only when explicitly needed inside Claude Code.': '- QA handoff는 bridge task를 기본으로 하고, 정말 필요할 때만 Claude-native subagent를 사용한다.',
    '- Keep executing scripted workloads (e.g., `morning-briefing.py`, `evening-digest.py`, `memory-daily-*`, `event-reminder-*`, `iran-crisis-monitor`) from `~/.openclaw/scripts/`. Keep track of their logs to track regressions.': '- recurring workflow는 bridge-managed cron family와 disposable-child run을 기준으로 본다. legacy helper가 아직 필요하면 실제 존재 여부를 확인한 뒤 compatibility 경로로만 다룬다.',
    '- Mention the regime of skills you still rely on: `agent-db`, `pinchtab`, `naver-maps`, `naver-search`, `openclaw-config`, `patch`, `agent-factory`. Flag `agent-factory` as gateway infrastructure to revisit later if / when it gets rebuilt.': '- Mention the bridge-local integrations you still rely on. If a dependency still lives outside `~/.agent-bridge/runtime`, call it out explicitly as migration debt instead of presenting it as a default tool.',
}


def replace_section(text: str, heading: str, replacement: str) -> str:
    pattern = rf"{re.escape(heading)}\n.*?(?=\n## |\Z)"
    return re.sub(pattern, replacement.strip() + "\n\n", text, flags=re.S)


def replace_section_range(text: str, start_heading: str, end_heading: str, replacement: str) -> str:
    pattern = rf"{re.escape(start_heading)}\n.*?(?=\n{re.escape(end_heading)}\n)"
    return re.sub(pattern, replacement.strip() + "\n\n", text, flags=re.S)


def rewrite_claude_legacy_text(agent_dir: Path, text: str) -> str:
    for old, new in COMMON_CLAUDE_REPLACEMENTS.items():
        text = text.replace(old, new)

    if agent_dir.name == "patch":
        text = replace_section_range(
            text,
            "## 환경 (맥미니 이전 완료 2026-02-18)",
            "## 메모리 관리",
            """## 환경
- **호스트**: Mac mini (macOS, ARM64, 8GB RAM)
- **홈**: `~/.agent-bridge/agents/patch/`
- **Bridge Home**: `~/.agent-bridge/`
- **관리자 실행**: `agb admin`
- 시스템 변경과 배포는 Agent Bridge 기준으로 수행한다. 남아 있는 OpenClaw 자산은 compatibility 대상으로만 본다.

## 호출 방식
- **션 직접**: `agb admin` 또는 patch 홈에서 Claude 실행
- **다른 에이전트**: `agent-bridge task create --to patch` 또는 `agent-bridge urgent patch "..."`로 요청
- **사람-facing surface**: 연결된 `patch` 세션과 #patch 채널
- 세션은 유지형이다. 점검/수리 요청은 bridge queue 기준으로 pull한다.

## 리포트 / A2A 전송 방법
- 다른 에이전트에게는 `agent-bridge task create --to <agent>`로 전달한다.
- 진짜 인터럽트만 `agent-bridge urgent <agent> "..."`를 사용한다.
- 장문 결과는 `~/.agent-bridge/shared/`에 저장하고 경로만 전달한다.
- 직접 gateway webhook, `a2a-send.sh`, legacy send CLI를 호출하지 않는다.""",
        )
        text = replace_section(
            text,
            "## OpenClaw 스킬 (Claude Code에서도 사용 가능)",
            """## Skills & Integrations
- patch 전용 local skill은 `skills/`에 있다. 현재 포함된 문서형 스킬은 `skills/new-agent-checklist.md`, `skills/personal-agent-checklist.md`다.
- 공용 bridge skill/참조는 `~/.agent-bridge/shared/SKILLS.md`, `~/.agent-bridge/shared/TOOLS.md`를 본다.
- 예전 외부 skill 경로는 compatibility inventory로만 취급한다. 실제 실행 전 존재 여부와 현재 유효성을 검증하고, 장기적으로는 bridge-local replacement로 옮긴다.
- 외부 credential/script 경로를 다시 쓰게 되면 그 사실을 리포트에 명시해서 migration debt로 남긴다.""",
        )
        text = text.replace("- **경로**: `/Users/soonseokoh/.openclaw/`", "- **경로**: `~/.agent-bridge/`")
        text = text.replace("- ⚠️ 에이전트가 패치를 호출할 때: Discord webhook만 사용. `sessions_send(patch)` 불가 (allow에서 제거됨)", "- 에이전트가 패치를 호출할 때는 `agent-bridge task create --to patch` 또는 `agent-bridge urgent patch \"...\"`를 사용한다.")
        text = text.replace("- 직접 gateway webhook, `a2a-send.sh`, `openclaw message send`를 호출하지 않는다.", "- 직접 gateway webhook, `a2a-send.sh`, legacy send CLI를 호출하지 않는다.")
        text = text.replace("- 예전 `~/.openclaw/skills/...` 경로는 compatibility inventory로만 취급한다. 실제 실행 전 존재 여부와 현재 유효성을 검증하고, 장기적으로는 bridge-local replacement로 옮긴다.", "- 예전 외부 skill 경로는 compatibility inventory로만 취급한다. 실제 실행 전 존재 여부와 현재 유효성을 검증하고, 장기적으로는 bridge-local replacement로 옮긴다.")
        text = text.replace("- `~/.openclaw/credentials`, `~/.openclaw/scripts` 같은 경로를 다시 쓰게 되면 그 사실을 리포트에 명시해서 migration debt로 남긴다.", "- 외부 credential/script 경로를 다시 쓰게 되면 그 사실을 리포트에 명시해서 migration debt로 남긴다.")

    if agent_dir.name == "shopify":
        text = replace_section_range(
            text,
            "## 환경",
            "## 메모리 관리",
            """## 환경
- **호스트**: Mac mini (macOS, ARM64, 8GB RAM)
- **홈**: `~/.agent-bridge/agents/shopify/`
- **공유 역할**: `shopify`, `shopify-codex`, `syrs-shopify`가 이 홈을 공유한다.
- 현재 canonical runtime은 Agent Bridge다. 예전 wrapper, session poller, LaunchAgent bridge 설명은 레거시 참고 정보다.

## 호출 방식
- 사람/다른 에이전트의 durable 요청은 `agent-bridge task create --to shopify` 또는 `--to syrs-shopify`로 받는다.
- 진짜 인터럽트만 `agent-bridge urgent ...`를 사용한다.
- 사람에게 보이는 Discord 업데이트는 연결된 `shopify` 또는 `syrs-shopify` 세션 안에서 직접 처리한다.
- `call-shopify.sh`, old A2A bridge poller, gateway wrapper를 기본 경로로 보지 않는다.

## Bridge Roles
- `shopify` = Claude 역할
- `shopify-codex` = Codex 보조 역할
- `syrs-shopify` = Discord-connected Claude 역할
- 세 역할은 같은 memory/home을 공유하지만, durable handoff는 모두 bridge queue를 기준으로 한다.""",
        )
        text = replace_section_range(
            text,
            "## 도구",
            "## Rules",
            """## Tools & Integrations
- Shopify theme/code work는 이 홈과 연결된 저장소에서 직접 수행한다. legacy wrapper 스크립트를 기본 경로로 보지 않는다.
- 패치에게 요청할 때는 `agent-bridge task create --to patch` 또는 `agent-bridge urgent patch "..."`를 사용한다.
- Shopify API / theme CLI / credential helper가 아직 bridge 밖 레거시 위치에 남아 있을 수 있다. 그 경우 실행 전 실제 경로를 검증하고, dependency를 리포트에 남긴다.
- `skills/`와 `~/.agent-bridge/shared/SKILLS.md`를 현재 skill registry로 사용한다.

## Credentials
- 비밀 파일은 tracked repo 밖에서 관리한다.
- 아직 특정 credential이 bridge 밖 레거시 위치에만 남아 있다면 migration debt로 보고하고, 장기적으로 bridge 기준 secret mount로 옮긴다.

## Reporting
- 사람에게 보이는 Discord 보고는 연결된 `shopify` 또는 `syrs-shopify` 세션 안에서 직접 처리한다.
- queue/A2A 호출 결과는 bridge task와 live session 상태로 이어진다. 별도 gateway send CLI를 호출하지 않는다.""",
        )
        text = text.replace(
            "- **소속**: OpenClaw 에이전트 시스템 (에이전트 ID: `syrs-shopify`)",
            "- **소속**: Agent Bridge 런타임 (에이전트 ID: `syrs-shopify`)",
        )
        text = text.replace(
            "## Reporting\n작업 완료 후 Discord #shopify 채널에 보고:\n```bash\nopenclaw message send --channel discord --account shopify \\\n  --target 1476851892876345374 --message \"🛒 작업 완료: ...\"\n```\n> **참고:** A2A/크론으로 호출된 경우 래퍼 스크립트가 자동 전달하므로 직접 보고 불필요.\n> 션 직접 대화 시에만 위 명령어로 Discord에 수동 보고.\n",
            "## Reporting\n- 작업 완료 후 사람-facing 보고는 연결된 `shopify` 또는 `syrs-shopify` 세션 안에서 직접 처리한다.\n- bridge queue가 태스크 상태를 보존하므로 별도 send CLI를 호출하지 않는다.\n- 결과, 영향, 다음 액션을 한 메시지로 정리해서 남긴다.\n",
        )
        text = text.replace(
            "- **쇼피 (syrs-shopify):** 이 프로젝트의 OpenClaw 에이전트",
            "- **쇼피 (syrs-shopify):** 이 프로젝트의 Agent Bridge 역할",
        )
        text = text.replace(
            "- Shopify API / theme CLI / credential helper가 아직 legacy path에 남아 있을 수 있다. 그 경우 실행 전 실제 경로를 검증하고, dependency를 리포트에 남긴다.",
            "- Shopify API / theme CLI / credential helper가 아직 bridge 밖 레거시 위치에 남아 있을 수 있다. 그 경우 실행 전 실제 경로를 검증하고, dependency를 리포트에 남긴다.",
        )
        text = text.replace(
            "- 아직 특정 credential이 `~/.openclaw/credentials/`에만 남아 있다면 migration debt로 보고하고, 장기적으로 bridge 기준 secret mount로 옮긴다.",
            "- 아직 특정 credential이 bridge 밖 레거시 위치에만 남아 있다면 migration debt로 보고하고, 장기적으로 bridge 기준 secret mount로 옮긴다.",
        )

    return text


def normalize_claude(agent_dir: Path, dry_run: bool, backup_root: Path) -> bool:
    claude_path = agent_dir / "CLAUDE.md"
    if not claude_path.exists():
        return False
    original = read_text(claude_path)
    backup_file(claude_path, backup_root, dry_run)
    normalized = re.sub(
        rf"{re.escape(MANAGED_START)}.*?{re.escape(MANAGED_END)}\n*",
        "",
        original,
        flags=re.S,
    )
    normalized = normalize_legacy_paths(normalized)
    normalized = rewrite_claude_legacy_text(agent_dir, normalized)
    block = render_agent_bridge_block(agent_dir)
    if normalized.startswith("# "):
        first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
        normalized = f"{first}\n\n{block}\n\n{rest.lstrip()}"
    else:
        normalized = f"{block}\n\n{normalized}"
    if normalized != original:
        write_text(claude_path, normalized, dry_run)
        return True
    return False


def render_agent_skills_md(agent_dir: Path) -> str:
    skill_files = collect_relative_files(agent_dir, "skills")
    reference_files = collect_relative_files(agent_dir, "references")
    lines = [
        f"# SKILLS.md — {agent_dir.name}",
        "",
        "<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->",
        "",
        "## Runtime Skill Rules",
        "- 공용 bridge 명령은 `TOOLS.md`와 `~/.agent-bridge/shared/SKILLS.md`를 먼저 본다.",
        "- local `skills/`가 있으면 해당 파일을 먼저 읽고 절차를 따른다.",
        "- 예전 외부 skill 경로는 compatibility note로만 본다. bridge-local 대체가 있으면 그쪽이 우선이다.",
        "",
        "## Local Inventory",
    ]
    if skill_files:
        lines.extend([f"- `{entry}`" for entry in skill_files])
    else:
        lines.append("- local `skills/` 없음")
    if reference_files:
        lines.extend(["", "## References", *[f"- `{entry}`" for entry in reference_files]])
    return "\n".join(lines) + "\n"


def ensure_agent_shared_links(agent_dir: Path, dry_run: bool, backup_root: Path) -> list[str]:
    changed: list[str] = []
    for name in AGENT_SHARED_LINKS:
        path = agent_dir / name
        target = f"../shared/{name}"
        current_ok = path.is_symlink() and os.readlink(path) == target
        if current_ok:
            continue
        if path.exists() or path.is_symlink():
            backup_file(path, backup_root, dry_run)
        ensure_symlink(path, target, dry_run)
        changed.append(str(path))
    return changed


def sync_agent_docs(agent_dir: Path, bridge_home: Path, dry_run: bool, stamp: str) -> list[str]:
    changed: list[str] = []
    backup_root = bridge_home / "state" / "doc-migration" / "backups" / stamp / agent_dir.name

    changed.extend(ensure_agent_shared_links(agent_dir, dry_run, backup_root))

    if normalize_claude(agent_dir, dry_run, backup_root):
        changed.append(str(agent_dir / "CLAUDE.md"))

    skills_path = agent_dir / "SKILLS.md"
    skills_text = render_agent_skills_md(agent_dir)
    old_skills = read_text(skills_path) if skills_path.exists() else None
    if old_skills != skills_text:
        if skills_path.exists():
            backup_file(skills_path, backup_root, dry_run)
        write_text(skills_path, skills_text, dry_run)
        changed.append(str(skills_path))

    for name in AGENT_RUNTIME_REWRITE_FILES:
        path = agent_dir / name
        if normalize_agent_runtime_file(path, agent_dir, dry_run, backup_root):
            changed.append(str(path))

    skills_root = agent_dir / "skills"
    if skills_root.exists():
        for path in sorted(skills_root.rglob("*.md")):
            if normalize_agent_runtime_file(path, agent_dir, dry_run, backup_root):
                changed.append(str(path))

    for name in REMOVABLE_DOCS:
        path = agent_dir / name
        if path.exists():
            backup_file(path, backup_root, dry_run)
            if not dry_run:
                path.unlink()
            changed.append(f"removed:{path}")

    return changed


def render_audit(audits: list[AgentAudit], bridge_home: Path, source_shared: Path) -> str:
    lines = [
        "# Agent Doc Audit",
        "",
        f"- bridge_home: `{pretty_path(bridge_home)}`",
        f"- source_shared: `{pretty_path(source_shared)}`",
        "",
        "## Summary",
        f"- agents: {len(audits)}",
        f"- removable legacy docs: {sum(len(audit.removable_docs) for audit in audits)}",
        f"- broken links: {sum(len(audit.broken_links) for audit in audits)}",
        f"- CLAUDE legacy hits: {sum(len(audit.claude_legacy_hits) for audit in audits)}",
        "",
    ]
    for audit in audits:
        lines.append(f"## {audit.agent}")
        if audit.removable_docs:
            lines.append(f"- removable: {', '.join(audit.removable_docs)}")
        if audit.broken_links:
            lines.append("- broken links:")
            lines.extend([f"  - {item}" for item in audit.broken_links])
        if audit.claude_legacy_hits:
            lines.append(f"- CLAUDE legacy hits: {', '.join(audit.claude_legacy_hits)}")
        if audit.local_skills:
            lines.append(f"- local skills: {', '.join(audit.local_skills)}")
        if audit.reference_files:
            lines.append(f"- references: {', '.join(audit.reference_files)}")
        if not any((audit.removable_docs, audit.broken_links, audit.claude_legacy_hits, audit.local_skills, audit.reference_files)):
            lines.append("- clean")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def parse_args() -> argparse.Namespace:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("audit", "apply"))
    parser.add_argument("agents", nargs="*")
    parser.add_argument("--all", action="store_true", dest="all_agents")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--bridge-home", type=Path, default=bridge_home)
    parser.add_argument(
        "--target-root",
        type=Path,
        default=Path(os.environ.get("BRIDGE_AGENT_HOME_ROOT", str(bridge_home / "agents"))),
    )
    parser.add_argument(
        "--source-shared",
        type=Path,
        default=Path(os.environ.get("BRIDGE_OPENCLAW_HOME", str(Path.home() / ".openclaw"))) / "shared",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    bridge_home = args.bridge_home.expanduser().resolve()
    target_root = args.target_root.expanduser().resolve()
    source_shared = args.source_shared.expanduser().resolve()
    agent_dirs = list_agent_dirs(target_root, args.agents, args.all_agents)

    if args.command == "audit":
        audits = [audit_agent(agent_dir) for agent_dir in agent_dirs]
        report = render_audit(audits, bridge_home, source_shared)
        sys.stdout.write(report)
        if args.report:
            write_text(args.report, report, False)
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    changed = sync_shared_docs(bridge_home, source_shared, args.dry_run)
    for agent_dir in agent_dirs:
        changed.extend(sync_agent_docs(agent_dir, bridge_home, args.dry_run, stamp))

    audits = [audit_agent(agent_dir) for agent_dir in agent_dirs]
    report_lines = [
        "# Agent Doc Migration",
        "",
        f"- mode: {'dry-run' if args.dry_run else 'apply'}",
        f"- agents: {len(agent_dirs)}",
        f"- changed_paths: {len(changed)}",
        "",
        "## Changed",
    ]
    if changed:
        report_lines.extend([f"- `{item}`" for item in changed])
    else:
        report_lines.append("- no changes")
    report_lines.extend(["", render_audit(audits, bridge_home, source_shared).rstrip(), ""])
    report = "\n".join(report_lines)
    sys.stdout.write(report)
    if args.report:
        write_text(args.report, report, False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
