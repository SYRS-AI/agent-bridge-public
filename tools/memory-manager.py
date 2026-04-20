#!/usr/bin/env python3
"""Read-only memory search for Agent Bridge derived indexes and legacy stores."""

import argparse
import datetime as dt
import heapq
import json
import math
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_MAX_RESULTS = 6
DEFAULT_MIN_SCORE = 0.35
DEFAULT_HYBRID_VECTOR_WEIGHT = 0.7
DEFAULT_HYBRID_TEXT_WEIGHT = 0.3
DEFAULT_HYBRID_CANDIDATE_MULTIPLIER = 4
DEFAULT_MMR_LAMBDA = 0.7
DEFAULT_HALF_LIFE_DAYS = 30
DATE_PATH_RE = re.compile(r"(?:^|/)memory/(\d{4})-(\d{2})-(\d{2})\.md$")


def deep_merge(base, override):
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_agent_home_root(bridge_home, agent_home_root):
    if agent_home_root:
        return Path(agent_home_root)
    return Path(bridge_home) / "agents"


def runtime_memory_dir(bridge_home):
    return Path(bridge_home) / "runtime" / "memory"


def default_config_path(bridge_home, openclaw_root):
    runtime_candidate = Path(bridge_home) / "runtime" / "bridge-config.json"
    if runtime_candidate.exists():
        return str(runtime_candidate)
    legacy_runtime_candidate = Path(bridge_home) / "runtime" / "openclaw.json"
    if legacy_runtime_candidate.exists():
        return str(legacy_runtime_candidate)
    return str(Path(openclaw_root) / "openclaw.json")


def looks_like_workspace(path):
    candidate = Path(path)
    if not candidate.is_dir():
        return False
    markers = (
        candidate / "MEMORY.md",
        candidate / "memory",
        candidate / ".openclaw" / "workspace-state.json",
    )
    return any(marker.exists() for marker in markers)


def legacy_workspace_dir(agent_id, openclaw_root):
    root = Path(openclaw_root)
    if agent_id == "main":
        return root / "workspace"
    if agent_id == "patch":
        return root / "patch"
    return root / f"workspace-{agent_id}"


def resolve_workspace_dir(agent_entry, resolved_agent, openclaw_root, bridge_home, agent_home_root):
    workspace_dir = agent_entry.get("workspace") if agent_entry else None
    if workspace_dir:
        return str(Path(workspace_dir).expanduser())

    bridge_candidate = resolve_agent_home_root(bridge_home, agent_home_root) / resolved_agent
    if looks_like_workspace(bridge_candidate):
        return str(bridge_candidate)

    legacy_candidate = legacy_workspace_dir(resolved_agent, openclaw_root)
    if legacy_candidate.exists():
        return str(legacy_candidate)

    return str(bridge_candidate)


def parse_args():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    search = subparsers.add_parser("search")
    search.add_argument("--agent", required=True, help="Bridge agent id or a compatibility alias")
    search.add_argument("query", help="Search query")
    search.add_argument("--config")
    search.add_argument("--openclaw-root", default=str(Path.home() / ".openclaw"))
    search.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    search.add_argument("--agent-home-root", default=os.environ.get("BRIDGE_AGENT_HOME_ROOT"))
    search.add_argument("--db-path")
    search.add_argument("--workspace-dir")
    search.add_argument("--model")
    search.add_argument("--api-key")
    search.add_argument("--source", action="append", dest="sources")
    search.add_argument("--max-results", type=int)
    search.add_argument("--min-score", type=float)
    search.add_argument("--json", action="store_true")
    search.set_defaults(func=cmd_search)

    return parser.parse_args()


def resolve_agent_id(agent_id, openclaw_root, bridge_home, config):
    listed = {item.get("id") for item in config.get("agents", {}).get("list", [])}
    memory_roots = [runtime_memory_dir(bridge_home), Path(openclaw_root) / "memory"]
    direct_db = None
    for memory_root in memory_roots:
        candidate = memory_root / f"{agent_id}.sqlite"
        if candidate.exists():
            direct_db = candidate
            break

    if agent_id in listed or (direct_db is not None and direct_db.exists()):
        return agent_id
    suffix_matches = {
        item
        for item in listed
        if item.endswith(f"-{agent_id}")
    }
    for memory_root in memory_roots:
        suffix_matches.update(
            path.stem
            for path in memory_root.glob(f"*-{agent_id}.sqlite")
        )
    if len(suffix_matches) == 1:
        return next(iter(suffix_matches))
    return agent_id


def default_memory_db_path(resolved_agent, openclaw_root, bridge_home):
    runtime_candidate = runtime_memory_dir(bridge_home) / f"{resolved_agent}.sqlite"
    if runtime_candidate.exists():
        return str(runtime_candidate)
    return str(Path(openclaw_root) / "memory" / f"{resolved_agent}.sqlite")


def load_agent_settings(agent_id, config_path, openclaw_root, bridge_home, agent_home_root):
    config = load_json(config_path)
    resolved_agent = resolve_agent_id(agent_id, openclaw_root, bridge_home, config)
    defaults = config.get("agents", {}).get("defaults", {}).get("memorySearch", {})
    agent_entry = None
    for item in config.get("agents", {}).get("list", []):
        if item.get("id") == resolved_agent:
            agent_entry = item
            break
    agent_memory = agent_entry.get("memorySearch", {}) if agent_entry else {}
    memory_settings = deep_merge(defaults, agent_memory)

    db_path = (
        memory_settings.get("store", {}).get("path")
        or default_memory_db_path(resolved_agent, openclaw_root, bridge_home)
    )
    workspace_dir = resolve_workspace_dir(agent_entry, resolved_agent, openclaw_root, bridge_home, agent_home_root)

    remote = memory_settings.get("remote", {})
    query = memory_settings.get("query", {})
    hybrid = query.get("hybrid", {})
    temporal = hybrid.get("temporalDecay", {})
    mmr = hybrid.get("mmr", {})

    return {
        "requested_agent": agent_id,
        "agent": resolved_agent,
        "db_path": db_path,
        "workspace_dir": workspace_dir,
        "api_key": remote.get("apiKey") or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"),
        "model": memory_settings.get("model", "gemini-embedding-2-preview"),
        "output_dimensionality": memory_settings.get("outputDimensionality", 3072),
        "sources": memory_settings.get("sources", ["memory", "sessions"]),
        "max_results": query.get("maxResults", DEFAULT_MAX_RESULTS),
        "min_score": query.get("minScore", DEFAULT_MIN_SCORE),
        "vector_weight": hybrid.get("vectorWeight", DEFAULT_HYBRID_VECTOR_WEIGHT),
        "text_weight": hybrid.get("textWeight", DEFAULT_HYBRID_TEXT_WEIGHT),
        "candidate_multiplier": hybrid.get("candidateMultiplier", DEFAULT_HYBRID_CANDIDATE_MULTIPLIER),
        "mmr_enabled": mmr.get("enabled", True),
        "mmr_lambda": mmr.get("lambda", DEFAULT_MMR_LAMBDA),
        "temporal_decay_enabled": temporal.get("enabled", True),
        "half_life_days": temporal.get("halfLifeDays", DEFAULT_HALF_LIFE_DAYS),
    }


def normalize_vector(values):
    norm = math.sqrt(sum(value * value for value in values))
    if not math.isfinite(norm) or norm <= 0:
        return values
    return [value / norm for value in values]


def embed_query(text, api_key, model, output_dimensionality):
    if not api_key:
        raise RuntimeError("Gemini API key is missing. Set it in openclaw.json or pass --api-key.")

    model_path = urllib.parse.quote(model, safe="")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model_path}:embedContent"
    payload = {
        "model": f"models/{model}",
        "content": {"parts": [{"text": text}]},
        "taskType": "RETRIEVAL_QUERY",
        "outputDimensionality": int(output_dimensionality),
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Gemini embedding request failed: HTTP {exc.code}: {details}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Gemini embedding request failed: {exc}") from exc

    values = body.get("embedding", {}).get("values")
    if not isinstance(values, list) or not values:
        raise RuntimeError(f"Unexpected embedding response: {body}")
    return normalize_vector([float(value) for value in values])


def open_db(path):
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    return connection


# Known index kinds. `bridge-wiki-fts-v1` and the implicit `legacy-hybrid`
# were the original two shapes; `bridge-wiki-hybrid-v2` is additive and
# introduced by the Track 3 cascading summarizer so that weekly/monthly
# summaries and ingested captures are all searchable through the same
# hybrid engine.
#
# IMPORTANT: do NOT alter behavior for the existing kinds. Detection is
# additive and fall-through; any kind other than the v2 marker still hits
# the legacy code paths unchanged.
INDEX_KIND_WIKI_FTS = "bridge-wiki-fts-v1"
INDEX_KIND_WIKI_HYBRID_V2 = "bridge-wiki-hybrid-v2"


def sources_for_index_kind(kind, default_sources):
    """Return the effective `sources` filter for an index kind.

    The v2 hybrid index is populated from:
      - shared/wiki/**/*.md   (source="wiki")
      - memory/weekly/*.md    (source="memory-weekly")
      - memory/monthly/*.md   (source="memory-monthly")
      - raw/captures/ingested/**/*.json   (source="capture-ingested")

    Contract:
    - If the caller passes a non-empty `default_sources` list, it is
      authoritative and returned verbatim — callers that explicitly scope
      the search are trusted to mean what they asked for.
    - If the caller passes an empty/None list, the v2 defaults (all four
      source families above) are substituted, so ad-hoc callers get a
      useful result. Non-v2 kinds see no expansion.
    """
    if default_sources:
        # Caller-provided filter is authoritative — never broaden it.
        return list(default_sources)
    if kind == INDEX_KIND_WIKI_HYBRID_V2:
        return ["wiki", "memory-weekly", "memory-monthly", "capture-ingested"]
    return default_sources


def _index_has_embeddings(connection) -> bool:
    """Return True if at least one chunk row has a non-empty embedding vector.

    An embedding that is literally `[]` (JSON empty array) counts as absent;
    this is how the FTS-only build marks un-embedded chunks. Embedding
    presence is the only reliable signal here. `chunks.model` is a
    provenance tag (set by the index builder to the index_kind, e.g.
    `bridge-wiki-hybrid-v2`) and must not be conflated with the embedding
    model name — hence no model argument.
    """
    try:
        row = connection.execute(
            "SELECT 1 FROM chunks WHERE embedding IS NOT NULL AND embedding != '[]' LIMIT 1"
        ).fetchone()
    except sqlite3.DatabaseError:
        return False
    return row is not None


def detect_index_kind(connection):
    tables = {
        row["name"]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    if "meta" in tables:
        row = connection.execute("SELECT value FROM meta WHERE key = 'index_kind'").fetchone()
        if row and row["value"]:
            return row["value"]
    return "legacy-hybrid"


def sql_in_clause(values):
    return ",".join("?" for _ in values)


def build_fts_query(raw):
    tokens = re.findall(r"\w+", raw, flags=re.UNICODE)
    tokens = [token.strip() for token in tokens if token.strip()]
    if not tokens:
        return None
    return " AND ".join(f'"{token.replace(chr(34), "")}"' for token in tokens)


def trim_snippet(text, width=220):
    compact = " ".join((text or "").split())
    if len(compact) <= width:
        return compact
    return compact[: width - 3] + "..."


def search_keyword(connection, query, limit, sources, model):
    fts_query = build_fts_query(query)
    if not fts_query:
        return []

    clauses = ["chunks_fts MATCH ?"]
    params = [fts_query]
    if model:
        clauses.append("chunks.model = ?")
        params.append(model)
    if sources:
        clauses.append(f"chunks.source IN ({sql_in_clause(sources)})")
        params.extend(sources)
    params.append(limit)

    sql = f"""
        SELECT chunks.id, chunks.path, chunks.source, chunks.start_line, chunks.end_line, chunks.text, bm25(chunks_fts) AS rank
        FROM chunks_fts
        JOIN chunks ON chunks.id = chunks_fts.rowid
        WHERE {' AND '.join(clauses)}
        ORDER BY rank ASC
        LIMIT ?
    """
    results = []
    for row in connection.execute(sql, params):
        rank = row["rank"]
        if not math.isfinite(rank):
            text_score = 1 / 1000
        elif rank < 0:
            relevance = -rank
            text_score = relevance / (1 + relevance)
        else:
            text_score = 1 / (1 + rank)
        results.append(
            {
                "id": row["id"],
                "path": row["path"],
                "source": row["source"],
                "startLine": row["start_line"],
                "endLine": row["end_line"],
                "snippet": trim_snippet(row["text"]),
                "textScore": text_score,
            }
        )
    return results


def dot_product(left, right):
    return sum(a * b for a, b in zip(left, right))


def search_vector(connection, query_vec, limit, sources, model):
    clauses = []
    params = []
    if model:
        clauses.append("model = ?")
        params.append(model)
    if sources:
        clauses.append(f"source IN ({sql_in_clause(sources)})")
        params.extend(sources)

    sql = """
        SELECT id, path, source, start_line, end_line, text, embedding
        FROM chunks
    """
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)

    heap = []
    sequence = 0
    for row in connection.execute(sql, params):
        embedding = json.loads(row["embedding"])
        score = dot_product(query_vec, normalize_vector([float(value) for value in embedding]))
        entry = (
            score,
            sequence,
            {
                "id": row["id"],
                "path": row["path"],
                "source": row["source"],
                "startLine": row["start_line"],
                "endLine": row["end_line"],
                "snippet": trim_snippet(row["text"]),
                "score": score,
            },
        )
        sequence += 1
        if len(heap) < limit:
            heapq.heappush(heap, entry)
        else:
            heapq.heappushpop(heap, entry)

    return [item[2] for item in sorted(heap, key=lambda pair: (pair[0], pair[1]), reverse=True)]


def tokenize_for_mmr(text):
    tokens = []
    buffer = []
    for char in (text or "").lower():
        if unicodedata.category(char)[0] in {"L", "N"} or char == "_":
            buffer.append(char)
            continue
        if buffer:
            tokens.append("".join(buffer))
            buffer = []
    if buffer:
        tokens.append("".join(buffer))
    return set(tokens)


def jaccard_similarity(set_a, set_b):
    if not set_a and not set_b:
        return 1.0
    if not set_a or not set_b:
        return 0.0
    intersection = len(set_a & set_b)
    union = len(set_a) + len(set_b) - intersection
    return 0.0 if union == 0 else intersection / union


def apply_mmr(results, enabled, lambd):
    if not enabled or len(results) <= 1:
        return list(results)
    clamped_lambda = max(0.0, min(1.0, float(lambd)))
    if clamped_lambda == 1.0:
        return sorted(results, key=lambda item: item["score"], reverse=True)

    token_cache = {}
    for index, item in enumerate(results):
        token_cache[index] = tokenize_for_mmr(item["snippet"])
    max_score = max(item["score"] for item in results)
    min_score = min(item["score"] for item in results)
    score_range = max_score - min_score

    def normalize(score):
        if score_range == 0:
            return 1.0
        return (score - min_score) / score_range

    selected = []
    remaining = set(range(len(results)))
    while remaining:
        best_index = None
        best_score = -math.inf
        for index in list(remaining):
            max_similarity = 0.0
            for chosen in selected:
                similarity = jaccard_similarity(token_cache[index], token_cache[chosen])
                if similarity > max_similarity:
                    max_similarity = similarity
            mmr_score = clamped_lambda * normalize(results[index]["score"]) - (1 - clamped_lambda) * max_similarity
            if mmr_score > best_score or (
                mmr_score == best_score and (best_index is None or results[index]["score"] > results[best_index]["score"])
            ):
                best_score = mmr_score
                best_index = index
        selected.append(best_index)
        remaining.remove(best_index)
    return [results[index] for index in selected]


def parse_memory_date(path_text):
    normalized = path_text.replace("\\", "/").lstrip("./")
    match = DATE_PATH_RE.search(normalized)
    if not match:
        return None
    year, month, day = map(int, match.groups())
    try:
        return dt.datetime(year, month, day, tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def is_evergreen_memory_path(path_text):
    normalized = path_text.replace("\\", "/").lstrip("./")
    if normalized in {"MEMORY.md", "memory.md"}:
        return True
    if not normalized.startswith("memory/"):
        return False
    return DATE_PATH_RE.search(normalized) is None


def extract_timestamp(entry, workspace_dir):
    from_path = parse_memory_date(entry["path"])
    if from_path:
        return from_path
    if entry["source"] == "memory" and is_evergreen_memory_path(entry["path"]):
        return None
    if not workspace_dir:
        return None

    file_path = Path(entry["path"])
    absolute = file_path if file_path.is_absolute() else Path(workspace_dir) / file_path
    try:
        stat = absolute.stat()
    except OSError:
        return None
    return dt.datetime.fromtimestamp(stat.st_mtime, tz=dt.timezone.utc)


def apply_temporal_decay(results, enabled, half_life_days, workspace_dir):
    if not enabled:
        return list(results)
    now = dt.datetime.now(dt.timezone.utc)
    decay_lambda = 0.0
    if half_life_days and half_life_days > 0:
        decay_lambda = math.log(2) / float(half_life_days)

    decayed = []
    for entry in results:
        timestamp = extract_timestamp(entry, workspace_dir)
        if not timestamp or decay_lambda <= 0:
            decayed.append(entry)
            continue
        age_days = max(0.0, (now - timestamp).total_seconds() / 86400.0)
        multiplier = math.exp(-decay_lambda * age_days)
        updated = dict(entry)
        updated["score"] = updated["score"] * multiplier
        decayed.append(updated)
    return decayed


def merge_hybrid_results(vector_results, keyword_results, vector_weight, text_weight, workspace_dir, temporal_decay_enabled, half_life_days, mmr_enabled, mmr_lambda):
    by_id = {}
    for item in vector_results:
        by_id[item["id"]] = {
            "id": item["id"],
            "path": item["path"],
            "startLine": item["startLine"],
            "endLine": item["endLine"],
            "source": item["source"],
            "snippet": item["snippet"],
            "vectorScore": item["score"],
            "textScore": 0.0,
        }

    for item in keyword_results:
        existing = by_id.get(item["id"])
        if existing:
            existing["textScore"] = item["textScore"]
            if item["snippet"]:
                existing["snippet"] = item["snippet"]
        else:
            by_id[item["id"]] = {
                "id": item["id"],
                "path": item["path"],
                "startLine": item["startLine"],
                "endLine": item["endLine"],
                "source": item["source"],
                "snippet": item["snippet"],
                "vectorScore": 0.0,
                "textScore": item["textScore"],
            }

    combined = []
    for entry in by_id.values():
        score = vector_weight * entry["vectorScore"] + text_weight * entry["textScore"]
        combined.append(
            {
                "id": entry["id"],
                "path": entry["path"],
                "startLine": entry["startLine"],
                "endLine": entry["endLine"],
                "source": entry["source"],
                "snippet": entry["snippet"],
                "vectorScore": entry["vectorScore"],
                "textScore": entry["textScore"],
                "score": score,
            }
        )

    decayed = apply_temporal_decay(combined, temporal_decay_enabled, half_life_days, workspace_dir)
    sorted_results = sorted(decayed, key=lambda item: item["score"], reverse=True)
    return apply_mmr(sorted_results, mmr_enabled, mmr_lambda)


def search_memory(settings, query, sources_override=None, max_results=None, min_score=None):
    sources = sources_override or settings["sources"]
    connection = open_db(settings["db_path"])
    try:
        index_kind = detect_index_kind(connection)
        max_results = max_results or settings["max_results"]
        min_score = settings["min_score"] if min_score is None else min_score
        candidate_limit = min(200, max(1, int(math.floor(max_results * settings["candidate_multiplier"]))))

        if index_kind == INDEX_KIND_WIKI_FTS:
            keyword_results = search_keyword(connection, query, candidate_limit, sources=None, model=None)
            seen = {}
            for item in keyword_results:
                key = item["id"]
                if key not in seen or item["textScore"] > seen[key]["score"]:
                    seen[key] = {
                        "id": item["id"],
                        "path": item["path"],
                        "startLine": item["startLine"],
                        "endLine": item["endLine"],
                        "source": item["source"],
                        "snippet": item["snippet"],
                        "vectorScore": 0.0,
                        "textScore": item["textScore"],
                        "score": item["textScore"],
                    }
            base = sorted(seen.values(), key=lambda item: item["score"], reverse=True)
            strict = [item for item in base if item["score"] >= min_score]
            return strict[:max_results]

        if index_kind == INDEX_KIND_WIKI_HYBRID_V2:
            # Same hybrid pipeline as legacy-hybrid (vector 0.7 / BM25 0.3,
            # MMR dedup, 30-day half-life decay); the ONLY difference is the
            # expanded `sources` filter so cascading summaries and ingested
            # captures are visible alongside wiki pages.
            #
            # Degradation path: if the index has no embeddings (built without
            # a Gemini key) or the query-time embed call fails, fall through
            # to the keyword-only branch below rather than 500'ing the search.
            expanded_sources = sources_for_index_kind(index_kind, sources)
            has_embeddings = _index_has_embeddings(connection)
            # v2 tags `chunks.model` with the index_kind string (e.g.
            # `bridge-wiki-hybrid-v2`), not the embedding model name. The
            # keyword/vector search paths therefore skip the model filter
            # here so results are not accidentally narrowed to zero when
            # settings["model"] (the Gemini embed model) does not match
            # what the writer actually stored. Embedding presence is the
            # correct gating signal for the vector branch.
            query_vec = None
            if has_embeddings:
                try:
                    query_vec = embed_query(
                        query,
                        settings["api_key"],
                        settings["model"],
                        settings["output_dimensionality"],
                    )
                except RuntimeError:
                    query_vec = None
            vector_results = (
                search_vector(
                    connection, query_vec, candidate_limit, expanded_sources, None
                )
                if query_vec is not None else []
            )
            keyword_results = search_keyword(
                connection, query, candidate_limit, expanded_sources, None
            )
            if not vector_results:
                seen = {}
                for item in keyword_results:
                    key = item["id"]
                    if key not in seen or item["textScore"] > seen[key]["score"]:
                        seen[key] = {
                            "id": item["id"],
                            "path": item["path"],
                            "startLine": item["startLine"],
                            "endLine": item["endLine"],
                            "source": item["source"],
                            "snippet": item["snippet"],
                            "vectorScore": 0.0,
                            "textScore": item["textScore"],
                            "score": item["textScore"],
                        }
                base = sorted(seen.values(), key=lambda item: item["score"], reverse=True)
                return [item for item in base if item["score"] >= min_score][:max_results]
            merged = merge_hybrid_results(
                vector_results,
                keyword_results,
                settings["vector_weight"],
                settings["text_weight"],
                settings["workspace_dir"],
                settings["temporal_decay_enabled"],
                settings["half_life_days"],
                settings["mmr_enabled"],
                settings["mmr_lambda"],
            )
            return [item for item in merged if item["score"] >= min_score][:max_results]

        query_vec = embed_query(query, settings["api_key"], settings["model"], settings["output_dimensionality"])

        vector_results = search_vector(connection, query_vec, candidate_limit, sources, settings["model"])
        keyword_results = search_keyword(connection, query, candidate_limit, sources, settings["model"])

        if not vector_results:
            seen = {}
            for item in keyword_results:
                key = item["id"]
                if key not in seen or item["textScore"] > seen[key]["score"]:
                    seen[key] = {
                        "id": item["id"],
                        "path": item["path"],
                        "startLine": item["startLine"],
                        "endLine": item["endLine"],
                        "source": item["source"],
                        "snippet": item["snippet"],
                        "vectorScore": 0.0,
                        "textScore": item["textScore"],
                        "score": item["textScore"],
                    }
            base = sorted(seen.values(), key=lambda item: item["score"], reverse=True)
            strict = [item for item in base if item["score"] >= min_score]
            return strict[:max_results]

        merged = merge_hybrid_results(
            vector_results,
            keyword_results,
            settings["vector_weight"],
            settings["text_weight"],
            settings["workspace_dir"],
            settings["temporal_decay_enabled"],
            settings["half_life_days"],
            settings["mmr_enabled"],
            settings["mmr_lambda"],
        )
        strict = [item for item in merged if item["score"] >= min_score]
        if strict or not keyword_results:
            return strict[:max_results]

        relaxed_min_score = min(min_score, settings["text_weight"])
        keyword_keys = {
            f"{item['source']}:{item['path']}:{item['startLine']}:{item['endLine']}" for item in keyword_results
        }
        relaxed = [
            item
            for item in merged
            if f"{item['source']}:{item['path']}:{item['startLine']}:{item['endLine']}" in keyword_keys
            and item["score"] >= relaxed_min_score
        ]
        return relaxed[:max_results]
    finally:
        connection.close()


def render_text(payload):
    print(f"agent: {payload['agent']}")
    if payload["requested_agent"] != payload["agent"]:
        print(f"resolved_agent: {payload['requested_agent']} -> {payload['agent']}")
    print(f"db_path: {payload['db_path']}")
    print(f"workspace_dir: {payload['workspace_dir']}")
    print(f"model: {payload['model']}")
    print(f"results: {len(payload['results'])}")
    if not payload["results"]:
        print("(no results)")
        return
    for index, item in enumerate(payload["results"], start=1):
        print()
        print(f"{index}. score={item['score']:.4f} vector={item['vectorScore']:.4f} text={item['textScore']:.4f}")
        print(f"   {item['source']} {item['path']}:{item['startLine']}-{item['endLine']}")
        print(f"   {item['snippet']}")


def cmd_search(args):
    config_path = args.config or default_config_path(args.bridge_home, args.openclaw_root)
    settings = load_agent_settings(
        args.agent,
        config_path,
        args.openclaw_root,
        args.bridge_home,
        args.agent_home_root,
    )
    if args.db_path:
        settings["db_path"] = args.db_path
    if args.workspace_dir:
        settings["workspace_dir"] = args.workspace_dir
    if args.model:
        settings["model"] = args.model
    if args.api_key:
        settings["api_key"] = args.api_key
    if args.max_results:
        settings["max_results"] = args.max_results
    if args.min_score is not None:
        settings["min_score"] = args.min_score

    payload = {
        "requested_agent": settings["requested_agent"],
        "agent": settings["agent"],
        "db_path": settings["db_path"],
        "workspace_dir": settings["workspace_dir"],
        "model": settings["model"],
        "results": search_memory(
            settings,
            args.query,
            sources_override=args.sources,
            max_results=args.max_results,
            min_score=args.min_score,
        ),
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        render_text(payload)
    return 0


def main():
    args = parse_args()
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
