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
# Match a markdown codespan (one or more backticks, content, matching backtick run).
# We skip wikilinks whose match.start() falls inside any codespan range.
# Intentionally NOT multiline: markdown codespans don't span paragraphs, and
# using re.S would consume text across unrelated paragraphs when a stray
# backtick appears (which would accidentally mask real broken wikilinks).
_CODESPAN_RE = re.compile(r"(`+)(?!`)(.+?)\1(?!`)")
_ENTITY_DIRS = ("entities", "concepts", "decisions", "systems")


def _codespan_ranges(text: str) -> list[tuple[int, int]]:
    """Return list of (start, end) character ranges that fall inside a
    markdown codespan (i.e. between matching backtick runs).

    A wikilink match at position `p` should be skipped when any range
    (s, e) in the returned list satisfies `s <= p < e` — i.e. the
    `[[…]]` is inside `` `…` ``.
    """
    return [(m.start(), m.end()) for m in _CODESPAN_RE.finditer(text)]


def _inside_codespan(pos: int, ranges: list[tuple[int, int]]) -> bool:
    for start, end in ranges:
        if start <= pos < end:
            return True
        if start > pos:
            break
    return False


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
        cs_ranges = _codespan_ranges(text)
        for match in _WIKILINK_RE.finditer(text):
            # Skip `[[…]]` that lives inside a `` `…` `` codespan — those
            # are prose illustrations of the wikilink syntax, not live links.
            if _inside_codespan(match.start(), cs_ranges):
                continue
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
        cs_ranges = _codespan_ranges(text)
        # Tree-edge heuristic: file linking to its own direct parent dir
        # (e.g. `daily-2026-04-19.md` → `[[daily]]`).
        for match in _WIKILINK_RE.finditer(text):
            if _inside_codespan(match.start(), cs_ranges):
                continue
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

_SAFE_AUTO_BASENAME_DENY = {"index.md", "readme.md"}


def _plan_is_dedup_scan_output(plan: dict) -> bool:
    """A raw dedup-scan JSON has `candidates: [{stem, paths}]`.
    A hand-authored plan has `merges: [{canonical, aliases}]`."""
    return "candidates" in plan and "merges" not in plan


def _auto_safe_merges(plan: dict) -> list[dict]:
    """Derive auto-safe merges from a dedup-scan `candidates` list.

    A cluster is auto-safe only when ALL of:
      - exactly 2 paths share the stem
      - identical basename (same filename, different directories)
      - neither basename is in the deny list (index.md, readme.md)
    The shallower path becomes canonical; the deeper becomes the alias.
    """
    safe: list[dict] = []
    for cluster in plan.get("candidates", []):
        paths = cluster.get("paths") or []
        if len(paths) != 2:
            continue
        basenames = {p.rsplit("/", 1)[-1].lower() for p in paths}
        if len(basenames) != 1:
            continue
        if basenames & _SAFE_AUTO_BASENAME_DENY:
            continue
        paths_sorted = sorted(paths, key=lambda p: (p.count("/"), p))
        canonical, alias = paths_sorted[0], paths_sorted[1]
        safe.append({"canonical": canonical, "aliases": [alias]})
    return safe


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
    if getattr(args, "auto_safe", False) and _plan_is_dedup_scan_output(plan):
        plan = {"merges": _auto_safe_merges(plan)}
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

# Cap on how many new [wiki-orphan] tasks a single `--create-tasks` run may
# enqueue. Protects against runaway enqueue if the wiki devolves into
# hundreds of new orphan clusters overnight. Tunable via
# `--orphan-max-tasks-per-run`.
_ORPHAN_MAX_TASKS_PER_RUN_DEFAULT = 20
_ORPHAN_CLUSTER_THRESHOLD_DEFAULT = 3


def _bridge_queue_script() -> Path:
    return _install_root() / "bridge-queue.py"


def _orphan_open_task_stems(owner: str) -> set[str]:
    """Return the set of orphan-stems that already have an open
    `[wiki-orphan]` task for `owner`. Uses
    `bridge-queue.py find-open --title-prefix` for dedup. Falls back to
    empty set on any failure — the rate limit still caps runaway enqueue.
    """
    script = _bridge_queue_script()
    if not script.exists():
        return set()
    cmd = [
        sys.executable or "python3", str(script),
        "find-open",
        "--agent", owner,
        "--title-prefix", "[wiki-orphan] cluster ",
        "--all",
    ]
    try:
        completed = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if completed.returncode != 0:
        return set()
    try:
        payload = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError:
        return set()
    stems: set[str] = set()
    if isinstance(payload, list):
        for item in payload:
            title = (item or {}).get("title", "")
            # title shape: "[wiki-orphan] cluster <stem> (N files)"
            prefix = "[wiki-orphan] cluster "
            if not title.startswith(prefix):
                continue
            rest = title[len(prefix):]
            stem = rest.rsplit(" (", 1)[0].strip()
            if stem:
                stems.add(stem)
    return stems


def _enqueue_orphan_task(owner: str, stem: str, sources: list[str]) -> tuple[bool, str]:
    """Create one `[wiki-orphan] cluster <stem> (N files)` task for `owner`.

    Returns (ok, detail). `detail` is the task id on success or an error
    snippet otherwise. Body lists source files that reference the stem
    plus quick-fix suggestions (rename, stub, delete).
    """
    script = _bridge_queue_script()
    if not script.exists():
        return False, f"bridge-queue.py missing: {script}"
    n = len(sources)
    title = f"[wiki-orphan] cluster {stem} ({n} files)"
    body_lines = [
        f"Orphan wikilink stem: [[{stem}]]",
        f"Appears in {n} file(s) under shared/wiki/ but no page resolves the stem.",
        "",
        "Source files referencing this stem:",
    ]
    for src in sources[:50]:
        body_lines.append(f"- {src}")
    if n > 50:
        body_lines.append(f"... and {n - 50} more")
    body_lines.extend([
        "",
        "Quick-fix options:",
        f"1. Rename an existing page so its stem becomes `{stem}`",
        f"2. Create a stub at `shared/wiki/{stem}.md` with frontmatter",
        f"3. Delete the `[[{stem}]]` link(s) if the reference is obsolete",
        "",
        "Generated by `bridge-wiki.py repair-links --create-tasks`.",
    ])
    body = "\n".join(body_lines)
    cmd = [
        sys.executable or "python3", str(script),
        "create",
        "--to", owner,
        "--from", "bridge-wiki",
        "--title", title,
        "--body", body,
        "--priority", "low",
    ]
    try:
        completed = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"enqueue-error: {exc}"
    if completed.returncode != 0:
        return False, (completed.stderr or completed.stdout or "").strip()[:200]
    return True, (completed.stdout or "").strip()


def cmd_repair_links(args: argparse.Namespace) -> int:
    wiki = _wiki_root(_shared_root(args))
    if not wiki.exists():
        print(f"wiki root not found: {wiki}", file=sys.stderr)
        return 1
    # Guard: `--create-tasks` and `--apply` are mutually exclusive by
    # default — mixing link rewrites with task enqueue is usually a
    # mistake. `--apply-and-create-tasks` opts into doing both in the
    # same run.
    create_tasks = getattr(args, "create_tasks", False)
    do_apply = bool(args.apply)
    if create_tasks and do_apply and not getattr(args, "apply_and_create_tasks", False):
        print(
            "error: --create-tasks and --apply together require "
            "--apply-and-create-tasks (mutual-exclusion guard).",
            file=sys.stderr,
        )
        return 2
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
    # orphan_clusters: stem → ordered list of distinct source files where
    # the stem appears broken. Populated only when is_broken AND no
    # single-candidate suggestion exists (i.e. the zero-candidate case
    # that `--apply` alone cannot fix).
    orphan_clusters: dict[str, list[str]] = {}
    orphan_order: list[str] = []  # preserves first-seen stem order
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
        cs_ranges = _codespan_ranges(text)

        def _rewrite(match: re.Match) -> str:
            """Span-scoped rewrite: only touch the matched `[[…]]` wikilink.

            Uses the raw (un-stripped) target span for offset arithmetic
            so inputs with incidental whitespace (`[[ Foo|bar]]`) don't
            produce a misaligned replacement. The normalized `target`
            drives the broken-ness and suggestion lookup only.
            """
            nonlocal file_changed
            full = match.group(0)
            # Skip codespan-embedded wikilinks (prose illustrations of
            # `[[…]]` syntax inside backticks) so we neither flag them as
            # broken nor rewrite them.
            if _inside_codespan(match.start(), cs_ranges):
                return full
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
                # Zero-candidate orphan — track it for --create-tasks.
                src_file = str(rel)
                bucket = orphan_clusters.setdefault(stem, [])
                if stem not in orphan_order:
                    orphan_order.append(stem)
                if src_file not in bucket:
                    bucket.append(src_file)
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

    # Orphan-task policy: cluster zero-candidate orphans by stem and
    # create a review task to `--task-owner` for each cluster whose file
    # count ≥ `--orphan-cluster-threshold`. Rate-limited by
    # `--orphan-max-tasks-per-run`. Already-open clusters are skipped.
    cluster_threshold = max(1, int(getattr(args, "orphan_cluster_threshold", _ORPHAN_CLUSTER_THRESHOLD_DEFAULT)))
    cluster_max_tasks = max(1, int(getattr(args, "orphan_max_tasks_per_run", _ORPHAN_MAX_TASKS_PER_RUN_DEFAULT)))
    task_owner = getattr(args, "task_owner", "") or "patch"

    eligible_clusters = [
        (stem, orphan_clusters[stem])
        for stem in orphan_order
        if len(orphan_clusters[stem]) >= cluster_threshold
    ]
    below_threshold = sum(
        1 for stem in orphan_order if len(orphan_clusters[stem]) < cluster_threshold
    )

    tasks_created = 0
    tasks_skipped_open = 0
    tasks_skipped_rate = 0
    tasks_failed = 0
    task_actions: list[dict] = []
    if create_tasks and eligible_clusters:
        open_stems = _orphan_open_task_stems(task_owner)
        for stem, sources in eligible_clusters:
            if stem in open_stems:
                tasks_skipped_open += 1
                task_actions.append({
                    "stem": stem, "status": "skipped-open",
                    "file_count": len(sources),
                })
                continue
            if tasks_created >= cluster_max_tasks:
                tasks_skipped_rate += 1
                task_actions.append({
                    "stem": stem, "status": "skipped-rate-limit",
                    "file_count": len(sources),
                })
                continue
            ok, detail = _enqueue_orphan_task(task_owner, stem, sources)
            if ok:
                tasks_created += 1
                task_actions.append({
                    "stem": stem, "status": "created",
                    "file_count": len(sources), "task": detail,
                })
            else:
                tasks_failed += 1
                task_actions.append({
                    "stem": stem, "status": "failed",
                    "file_count": len(sources), "error": detail,
                })

    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "wiki_root": str(wiki),
        "suggestion_count": len(suggestions),
        "files_rewritten": rewritten,
        "applied": bool(args.apply),
        "suggestions": suggestions[: args.limit or 100],
        "orphan_clusters_total": len(orphan_clusters),
        "orphan_clusters_eligible": len(eligible_clusters),
        "orphan_clusters_below_threshold": below_threshold,
        "orphan_cluster_threshold": cluster_threshold,
        "orphan_max_tasks_per_run": cluster_max_tasks,
        "create_tasks": bool(create_tasks),
        "task_owner": task_owner,
        "tasks_created": tasks_created,
        "tasks_skipped_open": tasks_skipped_open,
        "tasks_skipped_rate": tasks_skipped_rate,
        "tasks_failed": tasks_failed,
        "task_actions": task_actions,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"suggestions: {len(suggestions)}")
        if args.apply:
            print(f"rewrote: {rewritten} files")
        if create_tasks:
            print(
                f"tasks_created={tasks_created} "
                f"clusters={len(eligible_clusters)} "
                f"orphans_skipped_below_threshold={below_threshold}"
            )
            if tasks_skipped_open:
                print(f"  skipped (already open): {tasks_skipped_open}")
            if tasks_skipped_rate:
                print(f"  skipped (rate limit): {tasks_skipped_rate}")
            if tasks_failed:
                print(f"  failed: {tasks_failed}")
    return 0 if tasks_failed == 0 else 1


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
    da.add_argument("--auto-safe", action="store_true",
                    help="restrict merges to exact same-basename stem "
                         "collisions (2 paths, identical basename, not "
                         "index/readme) derived from a raw dedup-scan output")
    da.add_argument("--dry-run", action="store_true")
    da.add_argument("--json", action="store_true")
    da.set_defaults(func=cmd_dedup_apply)

    rl = sub.add_parser("repair-links")
    rl.add_argument("--shared-root", default="")
    rl.add_argument("--apply", action="store_true",
                    help="rewrite suggested fixes in place (unambiguous single-candidate only)")
    rl.add_argument("--create-tasks", action="store_true",
                    help="create [wiki-orphan] review tasks for zero-candidate orphan clusters. "
                         "By default mutually exclusive with --apply; combine via --apply-and-create-tasks.")
    rl.add_argument("--apply-and-create-tasks", action="store_true",
                    help="allow --apply and --create-tasks together in the same run")
    rl.add_argument("--orphan-cluster-threshold", type=int,
                    default=_ORPHAN_CLUSTER_THRESHOLD_DEFAULT,
                    help=f"min file count per stem cluster to warrant a task "
                         f"(default {_ORPHAN_CLUSTER_THRESHOLD_DEFAULT})")
    rl.add_argument("--orphan-max-tasks-per-run", type=int,
                    default=_ORPHAN_MAX_TASKS_PER_RUN_DEFAULT,
                    help=f"cap on new [wiki-orphan] tasks created in a single run "
                         f"(default {_ORPHAN_MAX_TASKS_PER_RUN_DEFAULT})")
    rl.add_argument("--task-owner", default="patch",
                    help="agent that receives [wiki-orphan] tasks (default: patch)")
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
