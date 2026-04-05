#!/usr/bin/env python3
"""bridge-runtime-inventory.py — inventory and rewrite legacy runtime dependencies."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path


HOME = Path.home()
TEXT_EXTENSIONS = {
    ".md",
    ".txt",
    ".json",
    ".jsonl",
    ".yaml",
    ".yml",
    ".sh",
    ".bash",
    ".zsh",
    ".py",
    ".sql",
}
MAX_TEXT_BYTES = 512 * 1024
SKIP_DIRS = {
    ".git",
    ".cache",
    ".discord",
    ".playwright-mcp",
    "__pycache__",
    "logs",
    "memory",
    "state",
    "tmp",
    "output",
    "outputs",
    "previews",
    "preview",
}
AGENT_RUNTIME_FILES = {
    ".mcp.json",
    "CLAUDE.md",
    "HEARTBEAT.md",
    "MEMORY.md",
    "ROSTER.md",
    "SOUL.md",
    "SKILLS.md",
    "SYRS-CONTEXT.md",
    "SYRS-RULES.md",
    "SYRS-USER.md",
    "TOOLS.md",
}
AGENT_RUNTIME_DIRS = {"references", "skills"}
SHARED_RUNTIME_DIRS = {"references", "tools"}


def pretty_path(path: Path) -> str:
    return str(path).replace(str(HOME), "~")


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def legacy_aliases(legacy_home: Path) -> list[str]:
    aliases = [str(legacy_home)]
    try:
        relative = legacy_home.relative_to(HOME)
    except ValueError:
        relative = None
    if relative is not None:
        aliases.append(f"~/{relative}")
    if legacy_home.name == ".openclaw":
        aliases.append("~/.openclaw")
    return list(dict.fromkeys(aliases))


def category_patterns(legacy_home: Path) -> dict[str, list[re.Pattern[str]]]:
    aliases = [re.escape(alias.rstrip("/")) for alias in legacy_aliases(legacy_home)]
    legacy_root = "|".join(aliases)
    return {
        "scripts": [re.compile(rf"(?:{legacy_root})/scripts/")],
        "skills": [re.compile(rf"(?:{legacy_root})/skills/")],
        "tools": [
            re.compile(rf"(?:{legacy_root})/shared/tools/"),
            re.compile(rf"(?:{legacy_root})/shared/TOOLS(?:-REGISTRY)?\.md"),
        ],
        "shared": [
            re.compile(rf"(?:{legacy_root})/shared/"),
            re.compile(r"\ba2a-files\b"),
        ],
        "secrets": [
            re.compile(rf"(?:{legacy_root})/(?:credentials|secrets)/"),
            re.compile(rf"(?:{legacy_root})/openclaw\.json"),
            re.compile(r"\bop://"),
            re.compile(r"\b1password\b", re.IGNORECASE),
            re.compile(r"\bop (?:read|run|inject)\b"),
        ],
        "db": [
            re.compile(r"\bagent-db\b"),
            re.compile(r"\b(?:postgres|psql|supabase)\b", re.IGNORECASE),
            re.compile(r"\b(?:pinchtab|railway-db|vendor-db|production-db|cost-db|syrs-commerce-db)\b"),
            re.compile(r"\.sqlite\b"),
        ],
        "notify": [
            re.compile(r"\bopenclaw message send\b"),
            re.compile(r"\bsessions_send\b"),
            re.compile(r"\bsessions_spawn\b"),
            re.compile(r"\bsessions_history\b"),
            re.compile(r"\bpatch-a2a-bridge\.sh\b"),
            re.compile(r"\bshopify-a2a-bridge\.sh\b"),
        ],
        "mcp": [
            re.compile(r"\.mcp\.json\b"),
            re.compile(r"\bmcpServers\b"),
            re.compile(r"\bplaywright-mcp\b"),
        ],
        "memory": [re.compile(rf"(?:{legacy_root})/memory/")],
    }


def source_inventory(legacy_home: Path) -> dict[str, dict[str, object]]:
    def count_files(path: Path, pattern: str | None = None) -> int:
        if not path.exists():
            return 0
        if pattern is None:
            return sum(1 for item in path.rglob("*") if item.is_file())
        return sum(1 for item in path.rglob(pattern) if item.is_file())

    def count_dirs(path: Path) -> int:
        if not path.exists():
            return 0
        return sum(1 for item in path.iterdir() if item.is_dir() and not item.name.startswith("."))

    items = {
        "scripts": {"path": legacy_home / "scripts", "count": count_files(legacy_home / "scripts")},
        "skills": {"path": legacy_home / "skills", "count": count_dirs(legacy_home / "skills")},
        "shared_tools": {"path": legacy_home / "shared" / "tools", "count": count_files(legacy_home / "shared" / "tools")},
        "patches": {"path": legacy_home / "patches", "count": count_files(legacy_home / "patches")},
        "media": {"path": legacy_home / "media", "count": count_files(legacy_home / "media")},
        "vault": {"path": legacy_home / "vault", "count": count_files(legacy_home / "vault")},
        "credentials": {"path": legacy_home / "credentials", "count": count_files(legacy_home / "credentials")},
        "secrets": {"path": legacy_home / "secrets", "count": count_files(legacy_home / "secrets")},
        "memory_sqlite": {"path": legacy_home / "memory", "count": count_files(legacy_home / "memory", "*.sqlite")},
        "cron_runs": {"path": legacy_home / "cron" / "runs", "count": count_files(legacy_home / "cron" / "runs")},
        "mcp_files": {
            "path": legacy_home,
            "count": count_files(legacy_home, ".mcp.json"),
        },
    }
    return {
        key: {
            "path": pretty_path(value["path"]),
            "count": value["count"],
        }
        for key, value in items.items()
    }


def load_jobs_payload(path: Path):
    raw = json.loads(path.expanduser().read_text(encoding="utf-8"))
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must contain a top-level list or {jobs:[...]}")
    return raw, jobs


def load_jobs(path: Path) -> list[dict]:
    if not path.exists():
        return []
    _, jobs = load_jobs_payload(path)
    return [job for job in jobs if isinstance(job, dict)]


def iter_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for nested in value.values():
            yield from iter_strings(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from iter_strings(nested)


def kind_for_job(job: dict) -> str:
    schedule = job.get("schedule") or {}
    if schedule.get("kind") == "at" or job.get("deleteAfterRun") is True:
        return "one-shot"
    return "recurring"


def first_line(text: str, limit: int = 140) -> str:
    flattened = " ".join(text.split())
    if len(flattened) <= limit:
        return flattened
    return flattened[: limit - 3].rstrip() + "..."


def match_categories(texts: list[str], patterns: dict[str, list[re.Pattern[str]]]) -> dict[str, str]:
    joined = "\n".join(texts)
    matches: dict[str, str] = {}
    for category, regexes in patterns.items():
        for regex in regexes:
            match = regex.search(joined)
            if match:
                line = next((first_line(text) for text in texts if regex.search(text)), first_line(joined))
                matches[category] = line
                break
    return matches


def scan_cron_jobs(jobs: list[dict], patterns: dict[str, list[re.Pattern[str]]]) -> dict[str, object]:
    category_counts = Counter()
    examples: defaultdict[str, list[dict[str, str]]] = defaultdict(list)
    jobs_with_refs = 0
    recurring_jobs = 0
    one_shot_jobs = 0
    enabled_jobs = 0

    for job in jobs:
        texts = list(iter_strings(job))
        name = str(job.get("name") or job.get("id") or "<unnamed>")
        if job.get("enabled", False):
            enabled_jobs += 1
        kind = kind_for_job(job)
        if kind == "recurring":
            recurring_jobs += 1
        else:
            one_shot_jobs += 1
        matches = match_categories(texts, patterns)
        if not matches:
            continue
        jobs_with_refs += 1
        for category, preview in matches.items():
            category_counts[category] += 1
            if len(examples[category]) < 5:
                examples[category].append(
                    {
                        "job": name,
                        "kind": kind,
                        "preview": preview,
                    }
                )

    return {
        "total_jobs": len(jobs),
        "enabled_jobs": enabled_jobs,
        "recurring_jobs": recurring_jobs,
        "one_shot_jobs": one_shot_jobs,
        "jobs_with_legacy_refs": jobs_with_refs,
        "categories": {
            category: {
                "count": category_counts.get(category, 0),
                "examples": examples.get(category, []),
            }
            for category in patterns
        },
    }


def is_probably_text(path: Path) -> bool:
    if path.suffix.lower() in TEXT_EXTENSIONS:
        return True
    try:
        sample = path.read_bytes()[:2048]
    except OSError:
        return False
    return b"\0" not in sample


def iter_text_files(root: Path):
    if not root.exists():
        return
    for current_root, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        current_path = Path(current_root)
        for name in sorted(filenames):
            path = current_path / name
            if path.name.startswith(".") and path.name not in {".mcp.json"}:
                continue
            try:
                if path.stat().st_size > MAX_TEXT_BYTES:
                    continue
            except OSError:
                continue
            if not is_probably_text(path):
                continue
            yield path


def iter_curated_runtime_files(bridge_home: Path):
    agents_root = bridge_home / "agents"
    if agents_root.exists():
        for agent_dir in sorted(agents_root.iterdir()):
            if not agent_dir.is_dir() or agent_dir.name.startswith(".") or agent_dir.name in {"_template", "shared"}:
                continue
            for child in sorted(agent_dir.iterdir()):
                if child.name in SKIP_DIRS:
                    continue
                if child.is_file() and child.name in AGENT_RUNTIME_FILES and is_probably_text(child):
                    yield child
                elif child.is_dir() and child.name in AGENT_RUNTIME_DIRS:
                    for item in child.rglob("*"):
                        if item.is_file() and is_probably_text(item):
                            yield item

    shared_root = bridge_home / "shared"
    if shared_root.exists():
        for child in sorted(shared_root.iterdir()):
            if child.name in SKIP_DIRS:
                continue
            if child.is_file() and is_probably_text(child):
                yield child
            elif child.is_dir() and child.name in SHARED_RUNTIME_DIRS:
                for item in child.rglob("*"):
                    if item.is_file() and is_probably_text(item):
                        yield item


def scan_runtime_surface(bridge_home: Path, patterns: dict[str, list[re.Pattern[str]]]) -> dict[str, object]:
    category_counts = Counter()
    examples: defaultdict[str, list[dict[str, str]]] = defaultdict(list)
    files_scanned = 0
    files_with_refs = 0

    for path in iter_curated_runtime_files(bridge_home):
        files_scanned += 1
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        texts = content.splitlines() or [content]
        matches = match_categories(texts, patterns)
        if not matches:
            continue
        files_with_refs += 1
        for category, preview in matches.items():
            category_counts[category] += 1
            if len(examples[category]) < 8:
                examples[category].append(
                    {
                        "path": pretty_path(path),
                        "preview": preview,
                    }
                )

    return {
        "files_scanned": files_scanned,
        "files_with_legacy_refs": files_with_refs,
        "categories": {
            category: {
                "count": category_counts.get(category, 0),
                "examples": examples.get(category, []),
            }
            for category in patterns
        },
    }


def load_bridge_native_jobs(path: Path) -> dict[str, int]:
    jobs = load_jobs(path)
    enabled = sum(1 for job in jobs if job.get("enabled", False))
    recurring = sum(1 for job in jobs if kind_for_job(job) == "recurring")
    return {
        "total_jobs": len(jobs),
        "enabled_jobs": enabled,
        "recurring_jobs": recurring,
    }


def render_report(data: dict[str, object]) -> str:
    cron = data["cron"]
    docs = data["live_runtime"]
    source = data["legacy_source"]
    lines = [
        "# Runtime Inventory",
        "",
        f"- generated_at: {data['generated_at']}",
        f"- bridge_home: {data['bridge_home']}",
        f"- legacy_source: {data['legacy_home']}",
        f"- legacy_jobs_file: {data['jobs_file']}",
        f"- native_jobs_file: {data['native_jobs_file']}",
        "",
        "## Summary",
        "",
        f"- legacy cron jobs: {cron['total_jobs']} total / {cron['enabled_jobs']} enabled / {cron['recurring_jobs']} recurring / {cron['jobs_with_legacy_refs']} with legacy refs",
        f"- bridge-native cron jobs: {data['native_cron']['total_jobs']} total / {data['native_cron']['enabled_jobs']} enabled / {data['native_cron']['recurring_jobs']} recurring",
        f"- live files scanned: {docs['files_scanned']} / {docs['files_with_legacy_refs']} with legacy refs",
        "",
        "## Legacy Source Inventory",
        "",
    ]
    for key, item in source.items():
        lines.append(f"- {key}: {item['count']} ({item['path']})")

    lines.extend(["", "## Cron Categories", ""])
    for category, payload in cron["categories"].items():
        lines.append(f"- {category}: {payload['count']}")
        for example in payload["examples"][:3]:
            lines.append(f"  - {example['job']} [{example['kind']}] :: {example['preview']}")

    lines.extend(["", "## Live Runtime Categories", ""])
    for category, payload in docs["categories"].items():
        lines.append(f"- {category}: {payload['count']}")
        for example in payload["examples"][:3]:
            lines.append(f"  - {example['path']} :: {example['preview']}")

    return "\n".join(lines) + "\n"


def build_inventory(bridge_home: Path, legacy_home: Path, jobs_file: Path, native_jobs_file: Path) -> dict[str, object]:
    patterns = category_patterns(legacy_home)
    cron_jobs = load_jobs(jobs_file)
    return {
        "generated_at": iso_now(),
        "bridge_home": pretty_path(bridge_home),
        "legacy_home": pretty_path(legacy_home),
        "jobs_file": pretty_path(jobs_file),
        "native_jobs_file": pretty_path(native_jobs_file),
        "legacy_source": source_inventory(legacy_home),
        "native_cron": load_bridge_native_jobs(native_jobs_file),
        "cron": scan_cron_jobs(cron_jobs, patterns),
        "live_runtime": scan_runtime_surface(bridge_home, patterns),
    }


def runtime_prefixes(bridge_home: Path) -> dict[str, str]:
    runtime_root = bridge_home / "runtime"
    return {
        "scripts": pretty_path(runtime_root / "scripts"),
        "skills": pretty_path(runtime_root / "skills"),
        "patches": pretty_path(runtime_root / "patches"),
        "media": pretty_path(runtime_root / "media"),
        "vault": pretty_path(runtime_root / "vault"),
        "logs": pretty_path(bridge_home / "logs"),
        "shared_tools": pretty_path(runtime_root / "shared" / "tools"),
        "shared_references": pretty_path(runtime_root / "shared" / "references"),
        "memory": pretty_path(runtime_root / "memory"),
        "credentials": pretty_path(runtime_root / "credentials"),
        "secrets": pretty_path(runtime_root / "secrets"),
        "config": pretty_path(runtime_root / "openclaw.json"),
        "shared": pretty_path(bridge_home / "shared"),
    }


def legacy_rewrite_rules(bridge_home: Path, legacy_home: Path) -> list[tuple[str, str, str]]:
    runtime = runtime_prefixes(bridge_home)
    abs_legacy = str(legacy_home)
    return [
        ("scripts", f"{abs_legacy}/scripts/", f"{runtime['scripts']}/"),
        ("scripts", "~/.openclaw/scripts/", f"{runtime['scripts']}/"),
        ("scripts", "$HOME/.openclaw/scripts/", f"{runtime['scripts']}/"),
        ("skills", f"{abs_legacy}/skills/", f"{runtime['skills']}/"),
        ("skills", "~/.openclaw/skills/", f"{runtime['skills']}/"),
        ("skills", "$HOME/.openclaw/skills/", f"{runtime['skills']}/"),
        ("patches", f"{abs_legacy}/patches/", f"{runtime['patches']}/"),
        ("patches", "~/.openclaw/patches/", f"{runtime['patches']}/"),
        ("patches", "$HOME/.openclaw/patches/", f"{runtime['patches']}/"),
        ("media", f"{abs_legacy}/media/", f"{runtime['media']}/"),
        ("media", "~/.openclaw/media/", f"{runtime['media']}/"),
        ("media", "$HOME/.openclaw/media/", f"{runtime['media']}/"),
        ("vault", f"{abs_legacy}/vault/", f"{runtime['vault']}/"),
        ("vault", "~/.openclaw/vault/", f"{runtime['vault']}/"),
        ("vault", "$HOME/.openclaw/vault/", f"{runtime['vault']}/"),
        ("logs", f"{abs_legacy}/logs/", f"{runtime['logs']}/"),
        ("logs", "~/.openclaw/logs/", f"{runtime['logs']}/"),
        ("logs", "$HOME/.openclaw/logs/", f"{runtime['logs']}/"),
        ("shared_tools", f"{abs_legacy}/shared/tools/", f"{runtime['shared_tools']}/"),
        ("shared_tools", "~/.openclaw/shared/tools/", f"{runtime['shared_tools']}/"),
        ("shared_tools", "$HOME/.openclaw/shared/tools/", f"{runtime['shared_tools']}/"),
        ("shared_references", f"{abs_legacy}/shared/references/", f"{runtime['shared_references']}/"),
        ("shared_references", "~/.openclaw/shared/references/", f"{runtime['shared_references']}/"),
        ("shared_references", "$HOME/.openclaw/shared/references/", f"{runtime['shared_references']}/"),
        ("shared", f"{abs_legacy}/shared/a2a-files/", f"{runtime['shared']}/a2a-files/"),
        ("shared", "~/.openclaw/shared/a2a-files/", f"{runtime['shared']}/a2a-files/"),
        ("shared", "$HOME/.openclaw/shared/a2a-files/", f"{runtime['shared']}/a2a-files/"),
        ("shared", f"{abs_legacy}/shared/ROSTER.md", f"{runtime['shared']}/ROSTER.md"),
        ("shared", "~/.openclaw/shared/ROSTER.md", f"{runtime['shared']}/ROSTER.md"),
        ("shared", "$HOME/.openclaw/shared/ROSTER.md", f"{runtime['shared']}/ROSTER.md"),
        ("shared", f"{abs_legacy}/shared/SYRS-CONTEXT.md", f"{runtime['shared']}/SYRS-CONTEXT.md"),
        ("shared", "~/.openclaw/shared/SYRS-CONTEXT.md", f"{runtime['shared']}/SYRS-CONTEXT.md"),
        ("shared", "$HOME/.openclaw/shared/SYRS-CONTEXT.md", f"{runtime['shared']}/SYRS-CONTEXT.md"),
        ("shared", f"{abs_legacy}/shared/SYRS-RULES.md", f"{runtime['shared']}/SYRS-RULES.md"),
        ("shared", "~/.openclaw/shared/SYRS-RULES.md", f"{runtime['shared']}/SYRS-RULES.md"),
        ("shared", "$HOME/.openclaw/shared/SYRS-RULES.md", f"{runtime['shared']}/SYRS-RULES.md"),
        ("shared", f"{abs_legacy}/shared/SYRS-USER.md", f"{runtime['shared']}/SYRS-USER.md"),
        ("shared", "~/.openclaw/shared/SYRS-USER.md", f"{runtime['shared']}/SYRS-USER.md"),
        ("shared", "$HOME/.openclaw/shared/SYRS-USER.md", f"{runtime['shared']}/SYRS-USER.md"),
        ("shared", f"{abs_legacy}/shared/TOOLS.md", f"{runtime['shared']}/TOOLS.md"),
        ("shared", "~/.openclaw/shared/TOOLS.md", f"{runtime['shared']}/TOOLS.md"),
        ("shared", "$HOME/.openclaw/shared/TOOLS.md", f"{runtime['shared']}/TOOLS.md"),
        ("shared", f"{abs_legacy}/shared/TOOLS-REGISTRY.md", f"{runtime['shared']}/TOOLS-REGISTRY.md"),
        ("shared", "~/.openclaw/shared/TOOLS-REGISTRY.md", f"{runtime['shared']}/TOOLS-REGISTRY.md"),
        ("shared", "$HOME/.openclaw/shared/TOOLS-REGISTRY.md", f"{runtime['shared']}/TOOLS-REGISTRY.md"),
        ("memory", f"{abs_legacy}/memory/", f"{runtime['memory']}/"),
        ("memory", "~/.openclaw/memory/", f"{runtime['memory']}/"),
        ("memory", "$HOME/.openclaw/memory/", f"{runtime['memory']}/"),
        ("credentials", f"{abs_legacy}/credentials/", f"{runtime['credentials']}/"),
        ("credentials", "~/.openclaw/credentials/", f"{runtime['credentials']}/"),
        ("credentials", "$HOME/.openclaw/credentials/", f"{runtime['credentials']}/"),
        ("secrets", f"{abs_legacy}/secrets/", f"{runtime['secrets']}/"),
        ("secrets", "~/.openclaw/secrets/", f"{runtime['secrets']}/"),
        ("secrets", "$HOME/.openclaw/secrets/", f"{runtime['secrets']}/"),
        ("config", f"{abs_legacy}/openclaw.json", runtime["config"]),
        ("config", "~/.openclaw/openclaw.json", runtime["config"]),
        ("config", "$HOME/.openclaw/openclaw.json", runtime["config"]),
    ]


def rewrite_string(value: str, rules: list[tuple[str, str, str]]) -> tuple[str, Counter]:
    result = value
    counts: Counter = Counter()
    for category, old, new in rules:
        if old not in result:
            continue
        occurrences = result.count(old)
        result = result.replace(old, new)
        counts[category] += occurrences
    return result, counts


def extract_session_target_agent(text: str) -> str | None:
    patterns = (
        r'sessionKey="agent:([^:"]+):',
        r"sessionKey='agent:([^:']+):",
        r'agent:([^:"]+):discord:',
        r"agent:([^:']+):discord:",
    )
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1)
    return None


def replace_with_indent(line: str, replacement: str) -> str:
    prefix = re.match(r"\s*", line).group(0)
    return f"{prefix}{replacement}"


def rewrite_cron_delivery_text(text: str, agent_id: str) -> tuple[str, Counter]:
    if (
        "sessions_send" not in text
        and "openclaw message send" not in text
        and "sessions_history" not in text
    ):
        return text, Counter()

    counts: Counter = Counter()
    lines = text.splitlines()
    output: list[str] = []
    banner_added = False

    def add_banner() -> None:
        nonlocal banner_added
        if banner_added:
            return
        output.extend(
            [
                "Bridge cron delivery rules:",
                "- direct-send legacy primitive는 실행하지 않는다.",
                "- 다른 에이전트 도움이 필요하면 결과에 durable handoff 필요 여부를 적고 `agent-bridge task create --to <agent>` 기준으로 넘긴다.",
                "- 사람-facing 알림이 필요하면 `needs_human_followup=true`와 함께 채널/DM용 메시지 초안을 결과에 남긴다.",
                "",
            ]
        )
        banner_added = True

    for line in lines:
        if "sessions_send" in line:
            add_banner()
            target_agent = extract_session_target_agent(line)
            if target_agent and target_agent != agent_id:
                output.append(
                    replace_with_indent(
                        line,
                        f"- cross-agent 전달이 필요하면 `agent-bridge task create --to {target_agent}` handoff가 필요하다고 결과에 적고, 전달할 메시지 초안을 함께 남긴다.",
                    )
                )
                counts["notify_handoff"] += 1
            else:
                output.append(
                    replace_with_indent(
                        line,
                        "- direct-send 대신 `needs_human_followup=true`로 표시하고, 부모 세션이 채널에서 보낼 메시지 초안을 결과에 남긴다.",
                    )
                )
                counts["notify_followup"] += 1
            continue
        if "openclaw message send" in line:
            add_banner()
            output.append(
                replace_with_indent(
                    line,
                    "- direct send CLI는 사용하지 않는다. 채널/DM 보고가 필요하면 `needs_human_followup=true`로 표시하고, 대상과 메시지 초안을 결과에 남긴다.",
                )
            )
            counts["notify_followup"] += 1
            continue
        if "sessions_history" in line:
            add_banner()
            output.append(
                replace_with_indent(
                    line,
                    "- legacy session history 직접 조회 대신 `MEMORY.md`, 현재 bridge queue/task 상태, 관련 파일/DB 결과로 최근 맥락을 판단한다.",
                )
            )
            counts["notify_context"] += 1
            continue
        output.append(line)

    return "\n".join(output), counts


def rewrite_value(value, rules: list[tuple[str, str, str]]):
    counts: Counter = Counter()
    changed = False
    if isinstance(value, str):
        rewritten, local_counts = rewrite_string(value, rules)
        return rewritten, rewritten != value, local_counts
    if isinstance(value, list):
        items = []
        for item in value:
            rewritten, item_changed, item_counts = rewrite_value(item, rules)
            items.append(rewritten)
            changed = changed or item_changed
            counts.update(item_counts)
        return items, changed, counts
    if isinstance(value, dict):
        output = {}
        for key, item in value.items():
            rewritten, item_changed, item_counts = rewrite_value(item, rules)
            output[key] = rewritten
            changed = changed or item_changed
            counts.update(item_counts)
        return output, changed, counts
    return value, False, counts


def backup_path_for(path: Path) -> Path:
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    return path.with_name(f"{path.name}.bak-{stamp}")


def atomic_write_json(path: Path, payload) -> None:
    temp_path = path.with_name(f".{path.name}.tmp")
    temp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp_path, path)


def rewrite_cron_jobs(bridge_home: Path, legacy_home: Path, jobs_file: Path, dry_run: bool) -> dict[str, object]:
    raw, jobs = load_jobs_payload(jobs_file)
    rules = legacy_rewrite_rules(bridge_home, legacy_home)
    changed_jobs = 0
    replacement_counts: Counter = Counter()
    examples: list[dict[str, object]] = []
    rewritten_jobs = []

    for job in jobs:
        rewritten, changed, counts = rewrite_value(job, rules)
        agent_id = str(rewritten.get("agentId") or job.get("agentId") or "")
        payload = rewritten.get("payload")
        if isinstance(payload, dict):
            for field in ("message", "text"):
                raw = payload.get(field)
                if not isinstance(raw, str):
                    continue
                delivery_rewritten, delivery_counts = rewrite_cron_delivery_text(raw, agent_id)
                if delivery_rewritten != raw:
                    payload[field] = delivery_rewritten
                    changed = True
                    counts.update(delivery_counts)
        rewritten_jobs.append(rewritten)
        if not changed:
            continue
        changed_jobs += 1
        replacement_counts.update(counts)
        if len(examples) < 8:
            texts = list(iter_strings(rewritten))
            preview = next(
                (
                    first_line(text)
                    for text in texts
                    if "~/.agent-bridge/runtime/" in text
                    or "~/.agent-bridge/shared/" in text
                    or "needs_human_followup=true" in text
                    or "agent-bridge task create --to" in text
                ),
                "",
            )
            examples.append(
                {
                    "job": str(job.get("name") or job.get("id") or "<unnamed>"),
                    "preview": preview,
                }
            )

    payload = raw if isinstance(raw, dict) else {"jobs": rewritten_jobs}
    payload["jobs"] = rewritten_jobs
    result = {
        "generated_at": iso_now(),
        "jobs_file": pretty_path(jobs_file),
        "bridge_home": pretty_path(bridge_home),
        "legacy_home": pretty_path(legacy_home),
        "total_jobs": len(jobs),
        "changed_jobs": changed_jobs,
        "replacement_counts": dict(replacement_counts),
        "examples": examples,
    }
    if dry_run or changed_jobs == 0:
        result["status"] = "dry_run" if dry_run else "no_changes"
        return result

    backup_path = backup_path_for(jobs_file)
    backup_path.write_text(jobs_file.read_text(encoding="utf-8"), encoding="utf-8")
    atomic_write_json(jobs_file, payload)
    result["status"] = "rewritten"
    result["backup_file"] = pretty_path(backup_path)
    return result


def rewrite_runtime_files(bridge_home: Path, legacy_home: Path, runtime_root: Path, dry_run: bool) -> dict[str, object]:
    rules = legacy_rewrite_rules(bridge_home, legacy_home)
    changed_files = 0
    replacement_counts: Counter = Counter()
    examples: list[dict[str, object]] = []
    backup_root = runtime_root.parent / "state-unused"
    if bridge_home.name == ".agent-bridge":
        backup_root = bridge_home / "state" / "runtime-rewrite" / datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")

    for path in iter_text_files(runtime_root):
        try:
            original = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        rewritten, changed, counts = rewrite_value(original, rules)
        if not changed:
            continue
        changed_files += 1
        replacement_counts.update(counts)
        if len(examples) < 8:
            preview = next((line for line in rewritten.splitlines() if "~/.agent-bridge/runtime/" in line or "~/.agent-bridge/shared/" in line), first_line(rewritten))
            examples.append({"path": pretty_path(path), "preview": first_line(preview)})
        if dry_run:
            continue
        relative = path.relative_to(runtime_root)
        backup_path = backup_root / relative
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_path.write_text(original, encoding="utf-8")
        path.write_text(rewritten, encoding="utf-8")

    result = {
        "generated_at": iso_now(),
        "runtime_root": pretty_path(runtime_root),
        "bridge_home": pretty_path(bridge_home),
        "legacy_home": pretty_path(legacy_home),
        "changed_files": changed_files,
        "replacement_counts": dict(replacement_counts),
        "examples": examples,
    }
    if dry_run or changed_files == 0:
        result["status"] = "dry_run" if dry_run else "no_changes"
    else:
        result["status"] = "rewritten"
        result["backup_root"] = pretty_path(backup_root)
    return result


def print_human(data: dict[str, object]) -> None:
    cron = data["cron"]
    docs = data["live_runtime"]
    print(f"bridge_home: {data['bridge_home']}")
    print(f"legacy_source: {data['legacy_home']}")
    print(f"legacy_jobs_file: {data['jobs_file']}")
    print(f"native_jobs_file: {data['native_jobs_file']}")
    print()
    print("summary:")
    print(f"  cron_total: {cron['total_jobs']}")
    print(f"  cron_enabled: {cron['enabled_jobs']}")
    print(f"  cron_recurring: {cron['recurring_jobs']}")
    print(f"  cron_with_legacy_refs: {cron['jobs_with_legacy_refs']}")
    print(f"  native_jobs: {data['native_cron']['total_jobs']}")
    print(f"  files_scanned: {docs['files_scanned']}")
    print(f"  files_with_legacy_refs: {docs['files_with_legacy_refs']}")
    print()
    print("legacy_source:")
    for key, item in data["legacy_source"].items():
        print(f"  {key}: {item['count']} ({item['path']})")
    print()
    print("cron_categories:")
    for category, payload in cron["categories"].items():
        print(f"  {category}: {payload['count']}")
    print()
    print("live_runtime_categories:")
    for category, payload in docs["categories"].items():
        print(f"  {category}: {payload['count']}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inventory and rewrite legacy runtime dependencies for Agent Bridge.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory", help="Inventory legacy runtime dependencies.")
    inventory.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(HOME / ".agent-bridge")))
    inventory.add_argument("--legacy-home", default=os.environ.get("BRIDGE_LEGACY_HOME", str(HOME / ".openclaw")))
    inventory.add_argument("--jobs-file", default=None)
    inventory.add_argument("--native-jobs-file", default=None)
    inventory.add_argument("--json", action="store_true")
    inventory.add_argument("--report", default=None)

    rewrite = subparsers.add_parser("rewrite-cron", help="Rewrite cron payload legacy paths to bridge-local runtime roots.")
    rewrite.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(HOME / ".agent-bridge")))
    rewrite.add_argument("--legacy-home", default=os.environ.get("BRIDGE_LEGACY_HOME", str(HOME / ".openclaw")))
    rewrite.add_argument("--jobs-file", default=None)
    rewrite.add_argument("--dry-run", action="store_true")
    rewrite.add_argument("--json", action="store_true")

    rewrite_files = subparsers.add_parser("rewrite-files", help="Rewrite copied runtime files to bridge-local paths.")
    rewrite_files.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(HOME / ".agent-bridge")))
    rewrite_files.add_argument("--legacy-home", default=os.environ.get("BRIDGE_LEGACY_HOME", str(HOME / ".openclaw")))
    rewrite_files.add_argument("--runtime-root", default=None)
    rewrite_files.add_argument("--dry-run", action="store_true")
    rewrite_files.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def print_rewrite_result(result: dict[str, object]) -> None:
    print(f"status: {result['status']}")
    if "jobs_file" in result:
        print(f"jobs_file: {result['jobs_file']}")
        print(f"total_jobs: {result['total_jobs']}")
        print(f"changed_jobs: {result['changed_jobs']}")
    else:
        print(f"runtime_root: {result['runtime_root']}")
        print(f"changed_files: {result['changed_files']}")
    print("replacement_counts:")
    counts = result.get("replacement_counts", {})
    if not counts:
        print("  - none")
    else:
        for category, count in sorted(counts.items()):
            print(f"  - {category}: {count}")
    if result.get("backup_file"):
        print(f"backup_file: {result['backup_file']}")
    if result.get("backup_root"):
        print(f"backup_root: {result['backup_root']}")
    print("examples:")
    examples = result.get("examples", [])
    if not examples:
        print("  - none")
    else:
        for example in examples[:5]:
            label = example.get("job") or example.get("path") or "<unknown>"
            print(f"  - {label} :: {example['preview']}")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    bridge_home = Path(args.bridge_home).expanduser()
    legacy_home = Path(args.legacy_home).expanduser()
    jobs_file = Path(args.jobs_file).expanduser() if getattr(args, "jobs_file", None) else legacy_home / "cron" / "jobs.json"

    if args.command == "inventory":
        native_jobs_file = Path(args.native_jobs_file).expanduser() if args.native_jobs_file else bridge_home / "cron" / "jobs.json"
        data = build_inventory(bridge_home, legacy_home, jobs_file, native_jobs_file)

        if args.report:
            report_path = Path(args.report).expanduser()
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(render_report(data), encoding="utf-8")

        if args.json:
            json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write("\n")
        else:
            print_human(data)
        return 0

    if args.command == "rewrite-cron":
        result = rewrite_cron_jobs(bridge_home, legacy_home, jobs_file, args.dry_run)
        if args.json:
            json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write("\n")
        else:
            print_rewrite_result(result)
        return 0

    if args.command == "rewrite-files":
        runtime_root = Path(args.runtime_root).expanduser() if args.runtime_root else bridge_home / "runtime"
        result = rewrite_runtime_files(bridge_home, legacy_home, runtime_root, args.dry_run)
        if args.json:
            json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write("\n")
        else:
            print_rewrite_result(result)
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
