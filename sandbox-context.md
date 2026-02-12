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

## Auto-Save

- Changes commit every 60 seconds (only when changes exist)
- On exit: final commit with message "wip: session end"
- Check logs: `cat /tmp/auto-git.log`

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
