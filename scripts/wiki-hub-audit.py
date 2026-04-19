#!/usr/bin/env python3
"""wiki-hub-audit.py — Phase 2 candidacy emitter (L2).

Reads ``shared/wiki/_index/mentions.db`` and identifies entities that
meet the cross-agent reach threshold but do NOT yet have a shared
canonical hub under ``shared/wiki/entities/`` or ``shared/wiki/people/``.
Writes a markdown report listing every candidate with the data the
admin agent needs to decide whether to author a hub.

Usage:
  wiki-hub-audit.py                                       # print to stdout
  wiki-hub-audit.py --out <path>                          # write to file
  wiki-hub-audit.py --json                                # machine-readable
  wiki-hub-audit.py --min-agents 2 --min-mentions 5       # override thresholds

Default thresholds: min-agents=2, min-mentions=5. Conservative on
purpose — the admin reviews, not the script. False positives (suggest
a hub for something that should stay agent-scoped) are cheap; false
negatives starve the graph.

L2 = candidacy layer in the wiki-graph automation pipeline. Pairs with
L1 (wiki-mention-scan.py) as the observation layer.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MIN_AGENTS = 2
DEFAULT_MIN_MENTIONS = 5
DEFAULT_REPORT_LIMIT = 60


def wiki_root_for(args: argparse.Namespace) -> Path:
    if args.wiki_root:
        return Path(args.wiki_root).expanduser().resolve()
    env = os.environ.get("AGENT_BRIDGE_WIKI")
    if env:
        return Path(env).expanduser().resolve()
    script = Path(__file__).resolve().parent
    return (script.parent / "shared" / "wiki").resolve()


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_candidates(
    conn: sqlite3.Connection,
    min_agents: int,
    min_mentions: int,
    limit: int,
) -> list[dict]:
    rows = conn.execute(
        """
        SELECT e.slug AS slug,
               e.title AS title,
               e.type AS type,
               e.hub_scope AS hub_scope,
               COUNT(DISTINCT m.source_agent) AS agents,
               COALESCE(SUM(m.mention_count), 0) AS mentions,
               COUNT(DISTINCT m.source_path) AS sources
        FROM entities e
        JOIN mentions m ON m.entity_slug = e.slug
        WHERE (e.hub_scope IS NULL OR e.hub_scope != 'shared')
          AND (e.type IS NULL OR e.type != 'redirect')
        GROUP BY e.slug
        HAVING agents >= ? AND mentions >= ?
        ORDER BY agents DESC, mentions DESC, e.slug
        LIMIT ?
        """,
        (min_agents, min_mentions, limit),
    ).fetchall()
    return [dict(zip([c[0] for c in conn.execute("SELECT 1").description or []], row)) if False else {
        "slug": row[0],
        "title": row[1] or "",
        "type": row[2] or "",
        "hub_scope": row[3] or "",
        "agents": row[4],
        "mentions": row[5],
        "sources": row[6],
    } for row in rows]


def load_sample_sources(
    conn: sqlite3.Connection, slug: str, limit: int = 6
) -> list[str]:
    """Return up to `limit` distinct source_paths referencing `slug`.

    Used in the human-readable report so the admin can click through to
    actual mention sites rather than guessing the context.
    """
    rows = conn.execute(
        """
        SELECT DISTINCT source_path
        FROM mentions
        WHERE entity_slug = ?
        ORDER BY source_path
        LIMIT ?
        """,
        (slug, limit),
    ).fetchall()
    return [row[0] for row in rows]


def render_report(
    wiki: Path,
    candidates: list[dict],
    min_agents: int,
    min_mentions: int,
    conn: sqlite3.Connection,
) -> str:
    lines: list[str] = []
    append = lines.append

    append("# Wiki Canonical Hub Candidates")
    append("")
    append(f"- generated: {now_iso()}")
    append(f"- wiki_root: `{wiki}`")
    append(f"- threshold: min_agents={min_agents}, min_mentions={min_mentions}")
    append(f"- candidate_count: {len(candidates)}")
    append("")
    append(
        "These entities are mentioned across multiple agents but do not yet "
        "have a team-canonical hub at `shared/wiki/entities/<slug>.md` "
        "(or `shared/wiki/people/<slug>.md` for a person). Admin judgement "
        "required before creation — see `admin-protocol.md`."
    )
    append("")

    if not candidates:
        append(
            "_No candidates above threshold._ Either the wiki is already "
            "well-hubbed, the mentions index is empty, or the threshold is "
            "set too high."
        )
        return "\n".join(lines)

    append("## Candidates (top 40)")
    append("")
    append("| # | Slug | Agents | Mentions | Sources | Current scope | Type |")
    append("|---|---|---|---|---|---|---|")
    for idx, cand in enumerate(candidates[:40], 1):
        append(
            f"| {idx} | `{cand['slug']}` | {cand['agents']} | {cand['mentions']} | "
            f"{cand['sources']} | {cand['hub_scope'] or '—'} | {cand['type'] or '—'} |"
        )
    append("")

    append("## Sample source files (for context)")
    append("")
    for cand in candidates[:20]:
        sources = load_sample_sources(conn, cand["slug"], limit=5)
        if not sources:
            continue
        append(f"### `{cand['slug']}` ({cand['agents']} agents / {cand['mentions']} mentions)")
        for src in sources:
            append(f"- `{src}`")
        append("")

    append("## Hub authoring checklist")
    append("")
    append(
        "For each candidate you decide to promote, create "
        "`shared/wiki/entities/<slug>.md` (or `shared/wiki/people/<slug>.md` "
        "for a person) with at minimum:"
    )
    append("")
    append("```yaml")
    append("---")
    append("type: entity       # or person / concept / system / vendor")
    append("slug: <kebab-case>")
    append("title: \"<Display name>\"")
    append("aliases: [..., every surface form across scripts + legacy slugs]")
    append("canonical_from: [..., the agent-scoped pages this hub consolidates]")
    append("date_captured: YYYY-MM-DD")
    append("date_updated: YYYY-MM-DD")
    append("agent: shared")
    append("tags: [team-canonical, ...]")
    append("---")
    append("```")
    append("")
    append(
        "Then: write a 2-3 sentence role/definition, a short facts list, and "
        "a `## Related` section with fanout `[[wikilinks]]` to the "
        "agent-scoped pages that hold the detail. If the existing "
        "agent-scoped entity file has no unique content worth preserving, "
        "convert it to a redirect (`type: redirect`, `redirect_to: entities/<slug>`) "
        "per `wiki-entity-lifecycle.md` §3.5."
    )
    append("")
    append(
        "If a candidate is agent-specific and should NOT become a team hub "
        "(e.g. `memory-daily-cron` is infrastructure, not a team concept), "
        "mark it as skipped in your done-note. Do not invent hubs."
    )
    append("")
    return "\n".join(lines)


def emit_task(
    bridge_bin: Path, admin_agent: str, report_path: Path, candidate_count: int
) -> bool:
    """Create a ``[wiki-hub-candidates]`` task for the admin agent."""
    if not bridge_bin.exists():
        return False
    import subprocess
    try:
        subprocess.run(
            [
                str(bridge_bin),
                "task",
                "create",
                "--to",
                admin_agent,
                "--priority",
                "normal",
                "--from",
                admin_agent,
                "--title",
                f"[wiki-hub-candidates] {candidate_count} 엔티티 허브 리뷰 필요 — {datetime.now().strftime('%Y-%m-%d')}",
                "--body-file",
                str(report_path),
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"[warn] task emit failed: {exc}", file=sys.stderr)
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wiki-hub-audit",
        description=(
            "Scan shared/wiki/_index/mentions.db for hub candidates. "
            "Writes a markdown report and optionally emits a task to the "
            "admin agent for review."
        ),
    )
    parser.add_argument("--wiki-root", help="Override wiki root.")
    parser.add_argument(
        "--min-agents",
        type=int,
        default=DEFAULT_MIN_AGENTS,
        help=f"Minimum distinct agents mentioning the entity (default {DEFAULT_MIN_AGENTS}).",
    )
    parser.add_argument(
        "--min-mentions",
        type=int,
        default=DEFAULT_MIN_MENTIONS,
        help=f"Minimum total mention count (default {DEFAULT_MIN_MENTIONS}).",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_REPORT_LIMIT,
        help=f"Maximum candidate rows in the report (default {DEFAULT_REPORT_LIMIT}).",
    )
    parser.add_argument("--out", help="Write the markdown report to this path.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a machine-readable summary instead of markdown.",
    )
    parser.add_argument(
        "--emit-task",
        action="store_true",
        help=(
            "After writing the report, create a [wiki-hub-candidates] task "
            "for --admin-agent via `agent-bridge task create`."
        ),
    )
    parser.add_argument(
        "--admin-agent",
        default=os.environ.get("BRIDGE_ADMIN_AGENT", "patch"),
        help="Admin agent to notify (default: patch).",
    )
    parser.add_argument(
        "--bridge-bin",
        default=os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", ""),
        help="Path to agent-bridge CLI. Defaults to <bridge-home>/agent-bridge.",
    )
    args = parser.parse_args(argv)

    wiki = wiki_root_for(args)
    db_path = wiki / "_index" / "mentions.db"
    if not db_path.exists():
        print(
            f"[error] mentions.db not found; run wiki-mention-scan first: {db_path}",
            file=sys.stderr,
        )
        return 1
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    candidates = load_candidates(
        conn, args.min_agents, args.min_mentions, args.limit
    )

    if args.json:
        summary = {
            "generated_at": now_iso(),
            "wiki_root": str(wiki),
            "thresholds": {
                "min_agents": args.min_agents,
                "min_mentions": args.min_mentions,
            },
            "candidate_count": len(candidates),
            "candidates": candidates,
        }
        json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    report = render_report(wiki, candidates, args.min_agents, args.min_mentions, conn)

    if args.out:
        out_path = Path(args.out).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(report, encoding="utf-8")
        print(f"wiki-hub-audit: candidates={len(candidates)} report={out_path}")
    else:
        sys.stdout.write(report)
        out_path = None

    if args.emit_task and out_path and candidates:
        if args.bridge_bin:
            bridge_bin = Path(args.bridge_bin).expanduser()
        else:
            # Default: <script_dir>/../agent-bridge
            bridge_bin = Path(__file__).resolve().parent.parent / "agent-bridge"
        ok = emit_task(bridge_bin, args.admin_agent, out_path, len(candidates))
        if ok:
            print(f"wiki-hub-audit: task emitted to {args.admin_agent}")
        else:
            print(f"wiki-hub-audit: task emit skipped (see warnings above)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
