# Claude Sandbox Context

You are running inside **Claude Sandbox** - an isolated Docker container.

## Key Facts

- You have `--dangerously-skip-permissions` enabled (no approval prompts)
- Container is destroyed on exit - the host machine is safe
- Network is shared with host (all ports work)
- The "This session" section at the top states what is actually enabled.
  Never tell the user their work is being auto-committed without checking it.

## If This Repo Has Its Own CLAUDE.md / AGENTS.md

It does not get overwritten, and it still applies. This file sits one level up
at `~/workspace/`; the project's own file sits in the repo. Both are loaded,
and the project's is the more specific one — follow its conventions. This file
only describes the sandbox itself.

## What You Can Do

- Run any command without asking for permission
- Install packages, run builds, start servers
- Make breaking changes freely - the sandbox is disposable
- Access any file in the mounted folders

## Paths

| Location | Path |
|----------|------|
| Primary repo | `~/workspace/<repo-name>/` |
| Extra mounts | `~/workspace/<other-name>/` |
| Shared config | `~/.claude/` (mounted from host) |
| Screenshots | `~/.claude/screenshots/` |

## Mounted Folders

The session may mount several folders side by side under `~/workspace/`. The
startup banner lists each one with its branch and whether it has uncommitted
changes. Some may be:

- **read-only** - mounted with `:ro`; treat them as reference material
- **not git repositories** - notes, data, or assets; no branches there

Each git repo has its own branch and history. Committing in one does not
affect the others.

## Screenshots / Images

Clipboard doesn't bridge host ↔ container. When user mentions a screenshot or image:

1. Check `~/.claude/screenshots/` for the **most recently modified file**:
   ```bash
   ls -t ~/.claude/screenshots/ | head -1
   ```
2. Read and analyze that image

User takes screenshots with `Cmd+Shift+4` which saves directly to the shared folder.

## Auto-Save

Whether it is running **for this session** is stated at the top of this file —
trust that over anything here. When it is on:

- Commits every N seconds, only when there are actual changes
- Skipped during a merge, rebase, cherry-pick, or on a detached HEAD
- On exit: a final commit with message "wip: session end"
- Check whether it is running: `cat /tmp/auto-git.log`

Only the primary repo is watched. Changes in extra mounted folders are yours
to commit.

## Environment Notes

- **Python**: a virtualenv at `/opt/venv`, first on `PATH`. Do NOT use conda — it is not available in the container.
- **pip**: `pip install <package>` works directly (no flags, no `--break-system-packages`)
- **uv**: available and much faster — `uv pip install <package>` works in the same venv
- **Node**: v24 LTS, with `build-essential` present so native modules compile
- **Pre-installed**: boto3, requests, jq, ripgrep (`rg`), fd, tmux
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
