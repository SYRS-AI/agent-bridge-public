# Agent Bridge

Agent Bridge coordinates Claude Code and Codex agent sessions through `tmux`.

## macOS Setup

1. Install prerequisites:

```bash
brew install bash tmux python
```

2. Make sure Homebrew Bash is first in `PATH`:

```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
exec zsh
bash --version
```

You need Bash 4+ because the bridge uses associative arrays. `bash --version` should not show the macOS system `3.2`.

3. Clone the repo:

```bash
git clone https://github.com/SYRS-AI/agent-bridge.git ~/agent-bridge
cd ~/agent-bridge
```

4. Install and log in to the CLIs you plan to use:
- `claude`
- `codex`

5. Start the bridge daemon once:

```bash
bash bridge-daemon.sh ensure
```

## First Run

From the project you want the agent to work on:

```bash
cd ~/agent-bridge
./ab --codex --name dev
```

Or for Claude:

```bash
./ab --claude --name tester
```

If you want the agent to work on another repo, `cd` into that repo first and run `~/agent-bridge/ab --codex --name dev`.

Useful commands:

```bash
./ab status
./ab list
./ab task create --to tester --title "check this" --body-file ~/agent-bridge/shared/note.md
./ab urgent tester "Check your inbox."
```

On the first Claude run in a new folder, Claude Code may show a trust prompt. Confirm it once, then the bridge can resume that session normally.
