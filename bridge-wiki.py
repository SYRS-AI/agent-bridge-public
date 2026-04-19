#!/usr/bin/env python3
"""bridge-wiki.py — wiki lifecycle orchestrator for Track 3 wiring.

Subcommands:

  bootstrap  — Build or refresh the hybrid-v2 search index for one or all
               agents. Delegates to `bridge-memory.py rebuild-index --index-kind
               bridge-wiki-hybrid-v2 --shared-root <shared>` per agent.

  validate   — Run hygiene checks on `shared/wiki/`:
                 * frontmatter coverage on entity-like files
                 * broken `[[wikilink]]` count (stem- OR path-resolves)
                 * tree-edge + per-agent-index antipatterns
               Exit code 0 = pass, 1 = fail. Read-only; use
               `repair-links --apply` for link fixes and
               `dedup-apply --plan` for alias merges.

  dedup-scan — Walk `shared/wiki/**/*.md` and group stems to surface
               canonical-merge candidates. Writes a plan file that
               `dedup-apply` can consume.

  dedup-apply — Read a dedup plan file and merge duplicate entities by
                rewriting aliases / adding redirect stubs. `--dry-run`
                prints actions without touching files.

  repair-links — Scan `shared/wiki/**/*.md` for `[[wikilinks]]` that do
                 not resolve and emit a JSON report with suggested fixes
                 (best-effort stem-alias lookup). `--apply` rewrites links
                 where the suggestion is unambiguous.

The CLI is intentionally thin — heavy lifting lives in other bridge
modules so each concern has a single implementation.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


# ---------------------------------------------------------------------------
# Install-root helpers
# ---------------------------------------------------------------------------

def _install_root() -> Path:
    env = os.environ.get("BRIDGE_HOME")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent


def _agents_root() -> Path:
    return _install_root() / "agents"


def _shared_root(args: argparse.Namespace) -> Path:
    if getattr(args, "shared_root", ""):
        return Path(args.shared_root)
    return _install_root() / "shared"


def _wiki_root(shared_root: Path) -> Path:
    return shared_root / "wiki"


def _list_agents(include_template: bool = False) -> list[str]:
    root = _agents_root()
    if not root.exists():
        return []
    out: list[str] = []
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        if name.startswith(".") or (name.startswith("_") and not include_template):
            continue
        if not (entry / "CLAUDE.md").exists():
            continue
        out.append(name)
    return out


# ---------------------------------------------------------------------------
# bootstrap
# ---------------------------------------------------------------------------

def cmd_bootstrap(args: argparse.Namespace) -> int:
    install = _install_root()
    shared = _shared_root(args)
    bridge_memory = install / "bridge-memory.py"
    if not bridge_memory.exists():
        print(f"bridge-memory.py not found: {bridge_memory}", file=sys.stderr)
        return 1

    agents = [args.agent] if args.agent else _list_agents()
    ok = 0
    failed = 0
    rows: list[dict] = []
    for name in agents:
        home = _agents_root() / name
        if not home.exists():
            rows.append({"agent": name, "status": "no-home"})
            failed += 1
            continue
        cmd = [
            sys.executable or "python3", str(bridge_memory), "rebuild-index",
            "--agent", name,
            "--home", str(home),
            "--bridge-home", str(install),
            "--index-kind", "bridge-wiki-hybrid-v2",
            "--shared-root", str(shared),
            "--json",
        ]
        if args.dry_run:
            cmd.append("--dry-run")
        try:
            completed = subprocess.run(cmd, capture_output=True, text=True, timeout=600, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            rows.append({"agent": name, "status": "error", "error": str(exc)})
            failed += 1
            continue
        if completed.returncode != 0:
            rows.append({
                "agent": name, "status": "failed",
                "rc": completed.returncode,
                "stderr": (completed.stderr or "").strip()[:500],
            })
            failed += 1
            continue
        try:
            payload = json.loads(completed.stdout or "{}")
        except json.JSONDecodeError:
            payload = {}
        rows.append({
            "agent": name,
            "status": "ok",
            "db_path": payload.get("db_path", ""),
            "chunks": payload.get("chunk_count", 0),
            "documents": payload.get("document_count", 0),
        })
        ok += 1

    result = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "shared_root": str(shared),
        "ok": ok,
        "failed": failed,
        "agents": rows,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for r in rows:
            if r["status"] == "ok":
                print(f"- {r['agent']}: ok ({r['chunks']} chunks)")
            else:
                print(f"- {r['agent']}: {r['status']}")
        print(f"\nbootstrap: {ok} ok, {failed} failed")
    return 0 if failed == 0 else 1


# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
_WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")
_ENTITY_DIRS = ("entities", "concepts", "decisions", "systems")


def _is_entity_like(rel_parts: tuple) -> bool:
    return any(d in rel_parts for d in _ENTITY_DIRS)


def _validate_frontmatter(wiki: Path) -> tuple[int, int]:
    """Return (total_entity_files, missing_frontmatter_count)."""
    total = missing = 0
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        if not _is_entity_like(rel.parts):
            continue
        total += 1
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            missing += 1
            continue
        if not _FRONTMATTER_RE.match(text):
            missing += 1
    return total, missing


def _validate_broken_links(wiki: Path) -> tuple[int, dict]:
    """Return (broken_link_count, top_offenders).

    A link is broken iff:
    - Path-qualified (contains "/"): the resolved `<wiki>/<target>.md`
      does NOT exist.
    - Stem-only (no "/"): no `.md` file anywhere in wiki has that stem.

    This matches the scoped PR body target (<20 broken links), using the
    same "stem OR path resolves" contract as `wiki-daily-hygiene.sh`.
    """
    known_stems: set[str] = set()
    known_rel_paths: set[str] = set()
    for p in wiki.rglob("*.md"):
        rel = p.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        known_stems.add(p.stem)
        # Store both with and without .md suffix for flexible lookup.
        rel_str = str(rel).removesuffix(".md")
        known_rel_paths.add(rel_str)
    broken = 0
    offenders: dict = {}
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for match in _WIKILINK_RE.finditer(text):
            target = match.group(1).strip()
            if not target:
                continue
            # Path-qualified link: must resolve to a real file.
            if "/" in target:
                bare = target.removesuffix(".md")
                if bare not in known_rel_paths:
                    broken += 1
                    offenders[target] = offenders.get(target, 0) + 1
                continue
            # Stem-only link: any file with that stem satisfies the link.
            if target not in known_stems:
                broken += 1
                offenders[target] = offenders.get(target, 0) + 1
    top = dict(sorted(offenders.items(), key=lambda kv: kv[1], reverse=True)[:20])
    return broken, top


def _validate_tree_edges(wiki: Path) -> list[str]:
    """Return paths with tree-edge antipatterns."""
    hits: list[str] = []
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        # Tree-edge heuristic: file linking to its own direct parent dir
        # (e.g. `daily-2026-04-19.md` → `[[daily]]`).
        for match in _WIKILINK_RE.finditer(text):
            target = match.group(1).strip()
            if target in rel.parts[:-1]:
                hits.append(str(rel))
                break
    return hits


def cmd_validate(args: argparse.Namespace) -> int:
    wiki = _wiki_root(_shared_root(args))
    if not wiki.exists():
        print(f"wiki root not found: {wiki}", file=sys.stderr)
        return 1

    checks = []
    if args.frontmatter or args.full:
        total, missing = _validate_frontmatter(wiki)
        checks.append({
            "check": "frontmatter",
            "ok": missing == 0,
            "total": total,
            "missing": missing,
        })
    if args.broken_link or args.full:
        broken, offenders = _validate_broken_links(wiki)
        checks.append({
            "check": "broken_links",
            "ok": broken < (args.broken_link_threshold or 20),
            "count": broken,
            "top_offenders": offenders,
        })
    if args.tree_edge or args.full:
        tree_hits = _validate_tree_edges(wiki)
        checks.append({
            "check": "tree_edges",
            "ok": len(tree_hits) == 0,
            "count": len(tree_hits),
            "hits": tree_hits[:20],
        })

    if not checks:
        print("no checks requested; pass --full or one of --frontmatter/--broken-link/--tree-edge", file=sys.stderr)
        return 2

    all_ok = all(c["ok"] for c in checks)
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "wiki_root": str(wiki),
        "ok": all_ok,
        "checks": checks,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for c in checks:
            mark = "✓" if c["ok"] else "✗"
            if c["check"] == "frontmatter":
                print(f"{mark} frontmatter: {c['total']-c['missing']}/{c['total']} covered ({c['missing']} missing)")
            elif c["check"] == "broken_links":
                print(f"{mark} broken_links: {c['count']}")
            elif c["check"] == "tree_edges":
                print(f"{mark} tree_edges: {c['count']}")
        print("overall:", "ok" if all_ok else "fail")
    return 0 if all_ok else 1


# ---------------------------------------------------------------------------
# dedup-scan
# ---------------------------------------------------------------------------

def cmd_dedup_scan(args: argparse.Namespace) -> int:
    wiki = _wiki_root(_shared_root(args))
    if not wiki.exists():
        print(f"wiki root not found: {wiki}", file=sys.stderr)
        return 1
    groups: dict[str, list[str]] = {}
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        groups.setdefault(path.stem, []).append(str(rel))
    candidates = [
        {"stem": stem, "paths": sorted(paths)}
        for stem, paths in sorted(groups.items())
        if len(paths) > 1
    ]
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "wiki_root": str(wiki),
        "candidate_count": len(candidates),
        "candidates": candidates,
    }
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    if args.json or not args.output:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"candidates: {len(candidates)} (written to {args.output})")
    return 0


# ---------------------------------------------------------------------------
# dedup-apply
# ---------------------------------------------------------------------------

def cmd_dedup_apply(args: argparse.Namespace) -> int:
    if not args.plan:
        print("--plan <file> is required", file=sys.stderr)
        return 2
    plan_path = Path(args.plan)
    if not plan_path.exists():
        print(f"plan not found: {plan_path}", file=sys.stderr)
        return 1
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot parse plan: {exc}", file=sys.stderr)
        return 1
    applied = 0
    skipped = 0
    actions: list[dict] = []
    for entry in plan.get("merges", []):
        canonical = entry.get("canonical")
        aliases = entry.get("aliases", [])
        if not canonical or not isinstance(aliases, list):
            skipped += 1
            continue
        actions.append({"canonical": canonical, "aliases": list(aliases), "applied": False})
        if args.dry_run:
            continue
        wiki = _wiki_root(_shared_root(args))
        canonical_path = wiki / canonical
        if not canonical_path.exists():
            skipped += 1
            continue
        try:
            text = canonical_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            skipped += 1
            continue
        match = _FRONTMATTER_RE.match(text)
        if match:
            # Extend existing frontmatter's `aliases:` list.
            head = match.group(1)
            rest = text[match.end():]
            lines = head.splitlines()
            new_lines: list[str] = []
            saw_aliases = False
            existing_aliases: list[str] = []
            for line in lines:
                if line.strip().startswith("aliases:"):
                    saw_aliases = True
                    existing_aliases = []
                    continue
                if saw_aliases and line.strip().startswith("-"):
                    existing_aliases.append(line.strip()[1:].strip())
                    continue
                saw_aliases = False
                new_lines.append(line)
            merged_aliases = existing_aliases + [a for a in aliases if a not in existing_aliases]
            alias_block = "aliases:\n" + "\n".join(f"  - {a}" for a in merged_aliases)
            new_head = "\n".join(new_lines) + "\n" + alias_block
            new_text = f"---\n{new_head}\n---\n{rest}"
        else:
            alias_block = "aliases:\n" + "\n".join(f"  - {a}" for a in aliases)
            new_text = f"---\n{alias_block}\n---\n{text}"
        canonical_path.write_text(new_text, encoding="utf-8")
        actions[-1]["applied"] = True
        applied += 1
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "plan": str(plan_path),
        "applied": applied,
        "skipped": skipped,
        "actions": actions,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for a in actions:
            mark = "ok" if a["applied"] else "skip"
            print(f"- {mark}: {a['canonical']} ← {', '.join(a['aliases'])}")
    return 0 if skipped == 0 else 1


# ---------------------------------------------------------------------------
# repair-links
# ---------------------------------------------------------------------------

def cmd_repair_links(args: argparse.Namespace) -> int:
    wiki = _wiki_root(_shared_root(args))
    if not wiki.exists():
        print(f"wiki root not found: {wiki}", file=sys.stderr)
        return 1
    # Build stem → list-of-paths so `--apply` can tell apart unambiguous
    # (stem appears exactly once) and ambiguous (multiple files share the
    # stem) targets. Only unambiguous suggestions are auto-applied.
    stem_candidates: dict[str, list[str]] = {}
    known_rel_paths: set[str] = set()
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        bare = str(rel).removesuffix(".md")
        stem_candidates.setdefault(path.stem, []).append(bare)
        known_rel_paths.add(bare)
    known_stems = set(stem_candidates.keys())

    def _suggest(stem: str) -> tuple[str | None, bool]:
        """Return (suggested_path_or_None, is_ambiguous)."""
        paths = stem_candidates.get(stem) or []
        if len(paths) == 1:
            return paths[0], False
        if len(paths) > 1:
            return paths[0], True  # still surface first match as a hint
        return None, False

    suggestions: list[dict] = []
    rewritten = 0
    for path in wiki.rglob("*.md"):
        rel = path.relative_to(wiki)
        if rel.parts and rel.parts[0] in ("_workspace", "_audit"):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        file_changed = False

        def _rewrite(match: re.Match) -> str:
            """Span-scoped rewrite: only touch the matched `[[…]]` wikilink.

            Uses the raw (un-stripped) target span for offset arithmetic
            so inputs with incidental whitespace (`[[ Foo|bar]]`) don't
            produce a misaligned replacement. The normalized `target`
            drives the broken-ness and suggestion lookup only.
            """
            nonlocal file_changed
            full = match.group(0)
            raw_target = match.group(1)
            target = raw_target.strip()
            if not target:
                return full
            # Broken-ness check (same rule as validate).
            if "/" in target:
                bare = target.removesuffix(".md")
                is_broken = bare not in known_rel_paths
            else:
                is_broken = target not in known_stems
            if not is_broken:
                return full
            stem = target.rsplit("/", 1)[-1]
            suggested, ambiguous = _suggest(stem)
            suggestions.append({
                "file": str(rel),
                "broken_target": target,
                "suggested": suggested,
                "ambiguous": ambiguous,
                "candidates": stem_candidates.get(stem, []),
            })
            if not suggested:
                return full
            # Only auto-apply when we have exactly one candidate AND the
            # caller passed --apply. Ambiguous suggestions are reported but
            # never rewritten automatically.
            if not args.apply or ambiguous:
                return full
            file_changed = True
            # Preserve the original trailer after the raw (un-stripped)
            # target span — this keeps alias/anchor text and incidental
            # whitespace intact.
            trailer = full[len("[[") + len(raw_target):]
            return f"[[{suggested}{trailer}"

        new_text = _WIKILINK_RE.sub(_rewrite, text)
        if args.apply and file_changed:
            path.write_text(new_text, encoding="utf-8")
            rewritten += 1
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "wiki_root": str(wiki),
        "suggestion_count": len(suggestions),
        "files_rewritten": rewritten,
        "applied": bool(args.apply),
        "suggestions": suggestions[: args.limit or 100],
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"suggestions: {len(suggestions)}")
        if args.apply:
            print(f"rewrote: {rewritten} files")
    return 0


# ---------------------------------------------------------------------------
# parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    boot = sub.add_parser("bootstrap")
    boot.add_argument("--agent", default="")
    boot.add_argument("--shared-root", default="")
    boot.add_argument("--dry-run", action="store_true")
    boot.add_argument("--json", action="store_true")
    boot.set_defaults(func=cmd_bootstrap)

    val = sub.add_parser("validate")
    val.add_argument("--shared-root", default="")
    val.add_argument("--full", action="store_true",
                     help="run all checks (frontmatter + broken-link + tree-edge)")
    val.add_argument("--frontmatter", action="store_true")
    val.add_argument("--broken-link", action="store_true")
    val.add_argument("--broken-link-threshold", type=int, default=20)
    val.add_argument("--tree-edge", action="store_true")
    val.add_argument("--json", action="store_true")
    val.set_defaults(func=cmd_validate)

    ds = sub.add_parser("dedup-scan")
    ds.add_argument("--shared-root", default="")
    ds.add_argument("--output", default="")
    ds.add_argument("--json", action="store_true")
    ds.set_defaults(func=cmd_dedup_scan)

    da = sub.add_parser("dedup-apply")
    da.add_argument("--shared-root", default="")
    da.add_argument("--plan", required=True,
                    help="JSON plan file produced by dedup-scan (hand-edited or LLM-reviewed)")
    da.add_argument("--dry-run", action="store_true")
    da.add_argument("--json", action="store_true")
    da.set_defaults(func=cmd_dedup_apply)

    rl = sub.add_parser("repair-links")
    rl.add_argument("--shared-root", default="")
    rl.add_argument("--apply", action="store_true",
                    help="rewrite suggested fixes in place")
    rl.add_argument("--limit", type=int, default=200)
    rl.add_argument("--json", action="store_true")
    rl.set_defaults(func=cmd_repair_links)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
