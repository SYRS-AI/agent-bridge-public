#!/usr/bin/env python3
"""bridge-runtime-inventory.py — inventory legacy runtime dependencies."""

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


def load_jobs(path: Path) -> list[dict]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        jobs = raw.get("jobs", [])
    else:
        jobs = raw
    if not isinstance(jobs, list):
        raise ValueError(f"invalid jobs payload: {path}")
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
    parser = argparse.ArgumentParser(description="Inventory bridge runtime dependencies still tied to a legacy source tree.")
    parser.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(HOME / ".agent-bridge")))
    parser.add_argument("--legacy-home", default=os.environ.get("BRIDGE_LEGACY_HOME", str(HOME / ".openclaw")))
    parser.add_argument("--jobs-file", default=None)
    parser.add_argument("--native-jobs-file", default=None)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--report", default=None)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    bridge_home = Path(args.bridge_home).expanduser()
    legacy_home = Path(args.legacy_home).expanduser()
    jobs_file = Path(args.jobs_file).expanduser() if args.jobs_file else legacy_home / "cron" / "jobs.json"
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


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
