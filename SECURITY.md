# Security Model

Claude Sandbox runs coding agents with all approval prompts disabled. That is the point, and it means the security model deserves a precise description rather than a reassuring one.

## Threat model

**In scope: accidents.** An agent that deletes the wrong directory, runs a destructive migration, installs a malicious package, fills the disk, or corrupts a build. The container is disposable, host files outside the mounted folders are unreachable, and host file permissions are never modified.

**Out of scope: a hostile or prompt-injected agent.** The sandbox forwards live credentials in order to be useful. An agent that has been manipulated — by a poisoned dependency, a malicious README, untrusted issue text, a compromised MCP server — can use every one of them.

If you need containment against a hostile agent, this is the wrong tool. Use a disposable VM, or Claude Code's [native sandboxing](https://code.claude.com/docs/en/sandboxing), which enforces filesystem and network policy at the OS level with a network allowlist.

## What is exposed

| Surface | Access | Notes |
|---|---|---|
| SSH agent socket | signing | Keys are never copied; the agent can still sign as you |
| `GH_TOKEN` | read/write | Whatever scope your `gh` login has, across all your repos |
| `~/.aws` | read/write | Any profile with an active SSO session |
| `~/.claude` | read/write | Settings, skills, plugins — including hooks that run on the **host** |
| `~/.codex`, `~/.agents` | read/write | Agent configuration |
| Mounted folders | read/write unless `:ro` | Only what you mount |
| Network | `--network host` by default | Reaches localhost services and your LAN |

## What is deliberately not exposed

- **Your working tree, under `--worktree`.** The agent gets a git worktree on a scratch branch; your checkout is never mounted.
- **Host file permissions.** Earlier versions ran `chmod -R 777` across the workspace, which in local mode propagated to the real repository on the host. That is fixed; only container-local paths are touched.
- **Code execution from config files.** `.claude-sandbox` files are parsed with a key allowlist and a value pattern, never sourced, so opening an untrusted repo with `cs .` cannot run code on your host.

## Reducing exposure

```bash
cs . --worktree                 # your checkout is not mounted
cs . -m ~/reference:ro          # read-only mounts
cs . --network bridge -p 3000:3000   # no host networking
```

Run `gh auth login` with a scoped token, or `unset GH_TOKEN` before launching, if you do not need GitHub write access in a session.

## Reporting a vulnerability

Open a GitHub issue for anything non-sensitive. For something that should not be public, use GitHub's private vulnerability reporting on this repository.
