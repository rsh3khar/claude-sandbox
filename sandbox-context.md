# Claude Sandbox Context

You are running inside **Claude Sandbox** - an isolated Docker container.

## Key Facts

- You have `--dangerously-skip-permissions` enabled (no approval prompts)
- Changes auto-commit to GitHub every 60 seconds
- Container is destroyed on exit - the host machine is safe
- Network is shared with host (all ports work)

## What You Can Do

- Run any command without asking for permission
- Install packages, run builds, start servers
- Make breaking changes freely - the sandbox is disposable
- Access any file in the cloned repo

## Paths

| Location | Path |
|----------|------|
| Repo | `~/workspace/<repo-name>/` |
| Shared config | `~/.claude/` (mounted from host) |
| Screenshots | `~/.claude/screenshots/` |

## Screenshots / Images

Clipboard doesn't bridge host ↔ container. When user mentions a screenshot or image:

1. Check `~/.claude/screenshots/` for the **most recently modified file**:
   ```bash
   ls -t ~/.claude/screenshots/ | head -1
   ```
2. Read and analyze that image

User takes screenshots with `Cmd+Shift+4` which saves directly to the shared folder.

## Browser / UI Testing

Browser is **opt-in** — enable it from the launch menu. When enabled, this sandbox includes a **headless Chromium browser** via Playwright. The Chromium binary is cached in a Docker volume, so only the first launch downloads it.

If you need the browser but it wasn't enabled at launch, **exit and restart the sandbox** with the browser option — volumes can't be mounted to a running container.

### MCP Browser Tools (Claude Code)

Playwright MCP is auto-configured when browser is enabled. Available tools:
- `browser_navigate` — Go to a URL (e.g. `http://localhost:3000`)
- `browser_screenshot` — Capture what's on screen
- `browser_click` — Click an element by selector
- `browser_type` — Type text into inputs
- `browser_hover`, `browser_select_option` — Other interactions
- `browser_console_messages` — View console output

Just ask to navigate or screenshot a page — the tools are available automatically.

### Python Playwright (Claude Code + Codex)

The `playwright` Python package is pre-installed:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
    )
    page = browser.new_page()
    page.goto('http://localhost:3000')
    page.wait_for_load_state('networkidle')
    page.screenshot(path='screenshot.png')
    browser.close()
```

**Container args required**: Always include `args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu']`.

The `webapp-testing` skill has helper scripts for managing server lifecycle — use it for complex scenarios.

## Auto-Save

- Changes commit every 60 seconds (only when changes exist)
- On exit: final commit with message "wip: session end"
- Check logs: `cat /tmp/auto-git.log`

## Skills

Skills are reusable capabilities that extend what you can do. Browse and discover skills at [skills.sh](https://skills.sh).

### Claude Code Skills

- **Location**: `~/.claude/skills/` (mounted from host)
- **Install**: `npx skills add <owner/repo>`
- Skills are auto-discovered — just invoke with `/skill-name`

### Codex Skills

- **Location**: `~/.agents/skills/` (mounted from host)
- **Install**: `skill-installer install <name> from <source>`
- Skills activate via `/skills` or `$skill-name`, or implicitly when your task matches a skill's description

## Parallel Agents with tmux

`tmux` is installed in the container. Use it to run multiple Claude Code or Codex sessions in parallel.

**Important**: Both Claude Code and Codex need **double Enter** to submit a message.

### Quick start

```bash
# Start a detached agent session
tmux new-session -d -s agent1
tmux send-keys -t agent1 'claude --dangerously-skip-permissions' Enter
sleep 3
tmux send-keys -t agent1 'Build the REST API with Express + TypeScript' Enter Enter

# Start another agent in parallel
tmux new-session -d -s agent2
tmux send-keys -t agent2 'claude --dangerously-skip-permissions' Enter
sleep 3
tmux send-keys -t agent2 'Write tests for the auth module' Enter Enter
```

### Managing sessions

```bash
tmux list-sessions              # List all sessions
tmux capture-pane -t agent1 -p -S -100  # Read last 100 lines of output
tmux attach -t agent1           # Watch live (detach: Ctrl+B then D)
tmux send-keys -t agent1 Escape # Interrupt an agent
tmux kill-session -t agent1     # Kill a session
```

### Long prompts (avoid special character issues)

```bash
cat > /tmp/task.txt << 'EOF'
Your detailed instructions here...
EOF
tmux load-buffer /tmp/task.txt
tmux paste-buffer -t agent1
tmux send-keys -t agent1 Enter Enter
```

### Observing agent activity

Claude Code writes session logs to `~/.claude/projects/`. Read the JSONL files directly for ground-truth status instead of asking agents to self-report:

```bash
# Find the latest session log
ls -t ~/.claude/projects/*//*.jsonl | head -1
```

### Git worktrees (parallel work on same repo)

When multiple agents touch the same codebase, use worktrees to avoid conflicts:

```bash
git worktree add ~/workspace/feat-auth -b feat/auth
git worktree add ~/workspace/feat-payments -b feat/payments
```

Each agent works on its own branch in its own directory. Merge when done.

## Environment Notes

- **Python**: System Python 3 with pip. Do NOT use conda — it is not available in the container.
- **pip**: `pip install <package>` works directly (no flags needed)
- **Pre-installed**: boto3, requests, jq
- **AWS**: If credentials fail, tell the user to run `aws sso login` on the HOST machine, then retry inside the container
- The global `~/.claude/CLAUDE.md` may reference conda environments — ignore those instructions inside the sandbox

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CLAUDE_SANDBOX=1` | Indicates sandbox environment |
| `CLAUDE_CODE_OAUTH_TOKEN` | Auth token |
| `GIT_USER_NAME` | Git commit author |
| `GIT_USER_EMAIL` | Git commit email |

---
<!-- END SANDBOX CONTEXT -->
