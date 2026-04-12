# Release Policy

Agent Bridge uses semantic versioning for public releases.

## Version Channels

- `stable`: the default user channel. It installs or upgrades to the latest `vX.Y.Z` Git tag.
- `dev`: tracks `main`. Use this only for development or explicit testing.
- `current`: deploys the current local checkout. This is mainly for maintainers and CI-style smoke checks.
- `ref`: deploys an explicit Git ref, such as a branch, tag, or commit SHA.

## First Stable Release

The first public onboarding-ready release is `v0.1.0`.

This release line means:

- Claude Code can install Agent Bridge from the public README without guessing repository internals.
- The live install path remains `~/.agent-bridge`.
- The source checkout is kept separately at `~/.agent-bridge-source`.
- User-owned runtime files are preserved during upgrade.
- `agb admin` starts the default admin agent and continues onboarding.

## Current Stable Release

The current stable release is `v0.2.0`.

This release line adds:

- shared team knowledge and operator profiles
- queue-backed handoff bundles, intake triage, and review gates
- Teams and Microsoft 365 channel/plugin support
- safer restart continuity, plugin cache sync, and crash-loop recovery
- MCP orphan cleanup and stronger smoke coverage for restart/cleanup regressions

## Patch Releases

After `v0.1.0`, publish user-facing fixes as patch releases such as `v0.1.1`.
Do not force-move existing public tags. Normal users should receive only tagged
stable releases unless they explicitly opt into `--channel dev`.

## Maintainer Release Checklist

1. Confirm `VERSION` contains the intended release version without the `v` prefix.
2. Run syntax and smoke tests:

   ```bash
   bash -n agent-bridge agb bridge-*.sh scripts/*.sh
   python3 -m py_compile bridge-*.py scripts/*.py
   ./scripts/smoke-test.sh
   ```

3. Commit and push private `main`.
4. Mirror the public-safe commit to `SYRS-AI/agent-bridge-public`.
5. Tag the public release:

   ```bash
   version="$(tr -d '[:space:]' < VERSION)"
   git tag -a "v${version}" -m "Agent Bridge v${version}"
   git push origin "v${version}"
   ```

6. Create a GitHub Release from the tag.
7. Verify a clean install from the public README.

## Upgrade Commands

```bash
agb version
agb upgrade --check
agb upgrade
agb upgrade --channel dev
agb upgrade --version 0.2.0
```

Default `agb upgrade` should use `stable`, not `main`, so normal users only receive tagged releases.
