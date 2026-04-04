# Contributing

Thanks for contributing to Agent Bridge.

## Development Environment

Required tools:

- Bash 4+
- `tmux`
- `python3`
- `git`

Recommended:

- `shellcheck`

Install and verify the local toolchain before changing code.

## First Steps

1. Read [`README.md`](./README.md)
2. Read [`ARCHITECTURE.md`](./ARCHITECTURE.md)
3. Read [`OPERATIONS.md`](./OPERATIONS.md)
4. Read [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md)

## Local Workflow

Make small, reviewable changes. Favor queue-first and daemon-safe changes over broad rewrites.

If you need local static roles, create `agent-roster.local.sh` from the example file. Do not commit machine-specific roster overrides.

## Validation

Run these before opening a pull request:

```bash
bash -n *.sh agent-bridge agb lib/*.sh scripts/*.sh
shellcheck *.sh agent-bridge agb lib/*.sh scripts/*.sh agent-roster.local.example.sh
./scripts/smoke-test.sh
```

If your change affects live coordination behavior, include one manual verification note that explains what you tested beyond the isolated smoke test.

## Style

- Use `#!/usr/bin/env bash`
- Prefer small `bridge_` helper functions
- Keep runtime artifacts out of git
- Preserve queue-first behavior unless you are intentionally changing orchestration semantics

## Pull Requests

Keep pull requests focused. Include:

- a short problem statement
- the approach you chose
- exact validation commands
- any operational or migration impact

If a change affects queue semantics, roster loading, session resume, or worktree handling, call that out explicitly.
