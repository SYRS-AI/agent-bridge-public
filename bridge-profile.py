#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_managed_files(root):
    files = {}
    if root is None or not root.exists():
        return files

    claude = root / "CLAUDE.md"
    if claude.is_file():
        files["CLAUDE.md"] = sha256_file(claude)

    skills_root = root / "skills"
    if skills_root.exists():
        for path in sorted(skills_root.rglob("*")):
            if not path.is_file():
                continue
            if path.name == ".gitkeep":
                continue
            rel = path.relative_to(root).as_posix()
            files[rel] = sha256_file(path)

    return files


def hash_selected(paths, file_map):
    digest = hashlib.sha256()
    for rel in sorted(paths):
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_map.get(rel, "<missing>").encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def build_summary(source_files, target_files):
    source_paths = sorted(source_files)
    target_paths = sorted(target_files)
    changed = [rel for rel in source_paths if rel in target_files and source_files[rel] != target_files[rel]]
    missing_in_target = [rel for rel in source_paths if rel not in target_files]
    target_only = [rel for rel in target_paths if rel not in source_files]
    in_sync = not changed and not missing_in_target

    return {
        "source_paths": source_paths,
        "target_paths": target_paths,
        "changed": changed,
        "missing_in_target": missing_in_target,
        "target_only": target_only,
        "in_sync": in_sync,
        "source_hash": hash_selected(source_paths, source_files),
        "target_hash_for_source": hash_selected(source_paths, target_files),
    }


def load_manifest(state_file):
    if not state_file.is_file():
        return None
    try:
        return json.loads(state_file.read_text(encoding="utf-8"))
    except Exception:
        return None


def render_list(title, items):
    if not items:
        return
    print(f"{title}:")
    for item in items:
        print(f"- {item}")


def cmd_status(args):
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser() if args.target_root else None
    state_file = Path(args.state_file).expanduser()
    source_exists = source_root.is_dir()
    target_exists = target_root.is_dir() if target_root else False
    source_files = scan_managed_files(source_root if source_exists else None)
    target_files = scan_managed_files(target_root if target_exists else None)
    summary = build_summary(source_files, target_files)
    manifest = load_manifest(state_file)

    target_drift = "unknown"
    if manifest:
        manifest_paths = manifest.get("managed_paths", [])
        manifest_target_hash = manifest.get("target_hash", "")
        current_hash = hash_selected(manifest_paths, target_files)
        target_drift = "yes" if current_hash != manifest_target_hash else "no"

    if not source_exists:
        sync = "missing_source"
    elif not args.target_root:
        sync = "unconfigured"
    elif summary["in_sync"]:
        sync = "in_sync"
    else:
        sync = "drift"

    print(f"agent: {args.agent}")
    print(f"source_root: {source_root}")
    print(f"target_root: {target_root if target_root else '-'}")
    print(f"active: {args.active}")
    print(f"source_exists: {'yes' if source_exists else 'no'}")
    print(f"target_exists: {'yes' if target_exists else 'no'}")
    print(f"sync: {sync}")
    print(f"manifest: {'present' if manifest else 'absent'}")
    print(f"target_drift: {target_drift}")
    print(f"managed_source_files: {len(summary['source_paths'])}")
    print(f"changed_files: {len(summary['changed'])}")
    print(f"missing_in_target: {len(summary['missing_in_target'])}")
    print(f"target_only_files: {len(summary['target_only'])}")
    if manifest:
        print(f"last_deployed_at: {manifest.get('deployed_at', '-')}")
        print(f"last_deployed_by: {manifest.get('deployed_by', '-')}")

    return 0


def cmd_diff(args):
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    if not source_root.is_dir():
        print(f"error: tracked profile source is missing: {source_root}", file=sys.stderr)
        return 2
    source_files = scan_managed_files(source_root)
    target_files = scan_managed_files(target_root if target_root.is_dir() else None)
    summary = build_summary(source_files, target_files)

    print(f"agent: {args.agent}")
    print(f"source_root: {source_root}")
    print(f"target_root: {target_root}")
    print(
        "summary: "
        f"changed={len(summary['changed'])} "
        f"missing_in_target={len(summary['missing_in_target'])} "
        f"target_only={len(summary['target_only'])} "
        f"in_sync={'yes' if summary['in_sync'] else 'no'}"
    )
    render_list("changed", summary["changed"])
    render_list("missing_in_target", summary["missing_in_target"])
    render_list("target_only", summary["target_only"])
    return 0 if summary["in_sync"] and not summary["target_only"] else 1


def deploy_requires_force(summary, target_files, manifest):
    if manifest:
        manifest_paths = manifest.get("managed_paths", [])
        manifest_target_hash = manifest.get("target_hash", "")
        current_hash = hash_selected(manifest_paths, target_files)
        if current_hash != manifest_target_hash:
            return True, "target managed files changed since the last deploy"
        return False, ""

    overlapping_changes = [rel for rel in summary["changed"] if rel in target_files]
    if overlapping_changes:
        return True, "target already has differing managed files and no prior deploy manifest exists"

    return False, ""


def copy_file(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def write_manifest(state_file, args, managed_paths, source_hash, target_hash):
    state_file.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "agent": args.agent,
        "source_root": str(Path(args.source_root).expanduser()),
        "target_root": str(Path(args.target_root).expanduser()),
        "managed_paths": managed_paths,
        "source_hash": source_hash,
        "target_hash": target_hash,
        "deployed_at": args.deployed_at,
        "deployed_by": args.deployed_by,
    }
    state_file.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def cmd_deploy(args):
    source_root = Path(args.source_root).expanduser()
    target_root = Path(args.target_root).expanduser()
    state_file = Path(args.state_file).expanduser()
    if not source_root.is_dir():
        print(f"error: tracked profile source is missing: {source_root}", file=sys.stderr)
        return 2

    source_files = scan_managed_files(source_root)
    target_files = scan_managed_files(target_root if target_root.is_dir() else None)
    summary = build_summary(source_files, target_files)
    manifest = load_manifest(state_file)
    must_force, reason = deploy_requires_force(summary, target_files, manifest)
    if must_force and not args.force:
        print(f"error: {reason}; rerun with --force", file=sys.stderr)
        return 2

    target_root.mkdir(parents=True, exist_ok=True)

    to_copy = [rel for rel in summary["source_paths"] if rel in summary["missing_in_target"] or rel in summary["changed"]]
    backup_path = target_root / ".CLAUDE.md.bak"
    target_claude = target_root / "CLAUDE.md"
    source_claude = source_root / "CLAUDE.md"
    needs_backup = (
        source_claude.is_file()
        and target_claude.is_file()
        and target_files.get("CLAUDE.md") != source_files.get("CLAUDE.md")
    )

    print(f"agent: {args.agent}")
    print(f"mode: {'dry-run' if args.dry_run else 'deploy'}")
    print(f"source_root: {source_root}")
    print(f"target_root: {target_root}")
    if args.active == "yes":
        print("warning: active session detected; restart may be needed for profile changes to take effect")
    if needs_backup:
        print(f"claude_backup: {backup_path}")
    render_list("copy", to_copy)
    render_list("preserve_target_only", summary["target_only"])

    if args.dry_run:
        print("result: dry-run only; no files changed")
        return 0

    if needs_backup:
        shutil.copy2(target_claude, backup_path)

    for rel in to_copy:
        copy_file(source_root / rel, target_root / rel)

    deployed_target_files = scan_managed_files(target_root)
    target_hash = hash_selected(summary["source_paths"], deployed_target_files)
    write_manifest(state_file, args, summary["source_paths"], summary["source_hash"], target_hash)
    print("result: deploy complete")
    return 0


def build_parser():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser, require_target):
        subparser.add_argument("--agent", required=True)
        subparser.add_argument("--source-root", required=True)
        subparser.add_argument("--target-root", required=require_target)
        subparser.add_argument("--state-file", required=True)
        subparser.add_argument("--active", choices=("yes", "no"), required=True)

    status = subparsers.add_parser("status")
    add_common(status, require_target=False)
    status.set_defaults(func=cmd_status)

    diff = subparsers.add_parser("diff")
    add_common(diff, require_target=True)
    diff.set_defaults(func=cmd_diff)

    deploy = subparsers.add_parser("deploy")
    add_common(deploy, require_target=True)
    deploy.add_argument("--dry-run", action="store_true")
    deploy.add_argument("--force", action="store_true")
    deploy.add_argument("--deployed-at", required=True)
    deploy.add_argument("--deployed-by", required=True)
    deploy.set_defaults(func=cmd_deploy)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
