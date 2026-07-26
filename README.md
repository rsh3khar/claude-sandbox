# Claude Sandbox

Run [Claude Code](https://claude.ai/code) and [Codex](https://developers.openai.com/codex/cli) with approvals disabled, in a container you can throw away.

![Claude Sandbox](screenshot.png)

## Why

`--dangerously-skip-permissions` is worth having and worth fencing off. This is the fence.

- No approval prompts
- Container destroyed on exit
- SSH agent, `gh` token and `~/.aws` forwarded, not copied
- Any local folder, or a GitHub clone
- `--worktree` keeps your checkout out of it

## Scope

Covers accidents: a wrong `rm -rf`, a migration against the wrong database, a dependency that rewrites your dotfiles.

Does not contain a hostile agent, because it forwards what one would want:

| Forwarded | Reach |
|---|---|
| SSH agent socket | any repo your key can push to |
| `GH_TOKEN` from `gh` | GitHub, at your token's scope |
| `~/.aws` | any profile with a live session |
| `~/.claude` | read-write, including hooks that later run on the host |
| `--network host` | anything your machine can reach, localhost included |

For untrusted code or untrusted input, use a VM or Claude Code's [native sandboxing](https://code.claude.com/docs/en/sandboxing) with a network allowlist.

`~/.claude` is mounted whole and read-write deliberately: skills, plugins, session history and `--resume` need the real thing.

Host file permissions are never modified. `-m path:ro` mounts read-only. `--worktree` doesn't mount your working tree at all.

### Linux: uid 1000 only

The container runs as uid 1000, so bind mounts owned by another uid aren't writable. macOS maps ownership and is unaffected. Open an issue if you need uid remapping.

## Requirements

Docker ([OrbStack](https://orbstack.dev/) or Docker Desktop), macOS or Linux, and a Claude Code subscription or API key. The installer offers to install `gh`, `gum` and `jq`. `fzf` is optional; it makes the folder picker filterable with a preview pane.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rsh3khar/claude-sandbox/main/install.sh | bash
```

Installs a pinned release verified against its published `SHA256SUMS`, then pulls the multi-arch image from GHCR, falling back to a local build if the registry is unreachable.

```bash
./install.sh --version v0.3.0   # pin a release
./install.sh --no-pull          # always build locally
./install.sh --link             # dev mode: symlink to a clone
./install.sh --uninstall
```

## Usage

### Local folders

```bash
cs .                      # the current repo, from any subdirectory
cs . ~/work/api ~/notes   # with extra folders
cs ~/projects/my-app      # any folder, git or not
cs . -w                   # worktree mode
cs . -m ~/work/api -m ~/notes:ro
```

Interactively, `cs` lists every git repo near the one you picked — siblings and cousins both, so `~/work/api`, `~/work/team-b/web` and `~/side/notes` land in one list. Type to filter, `tab` or `space` to mark several, enter to take them.

The menu loops until you pick `Done`, so a session can mix marked repos, browsed folders and typed paths. `Browse folders` is one flat filterable list from `~` down, repos marked `[repo]`, with a preview of the highlighted folder; the read-only variant mounts that batch `:ro`. `Remove a mount` drops one after the fact.

Recent workspaces are remembered with their mounts.

If your repos live elsewhere or nest deeply:

```ini
REPO_ROOTS=~/knowledge,~/clients   # extra trees to search
REPO_DEPTH=5                       # default 5; ~/work/<group>/<area>/<repo> needs 4+
```

A repo that always needs the same companions can commit a `.claude-sandbox`:

```ini
MOUNTS=../api,../web,~/design-docs:ro
WORKTREE=true
BROWSER=true
```

Config files are parsed, not sourced.

### GitHub repos

```bash
cs owner/repo
cs owner/repo -b feature/login
cs git@github.com:owner/repo.git
```

### Headless

```bash
cs exec "run the test suite and summarize failures"
cs exec "review the diff on this branch" ~/work/api --agent codex
```

Only the agent's output reaches stdout.

### Managing sandboxes

```bash
cs ps          # running sandboxes and their mounts
cs attach      # open a second shell in one
cs orphans     # sandboxes whose terminal is gone
cs kill --all
cs doctor      # check your setup
```

### Inside the sandbox

```bash
c    # claude, permissions off
x    # codex, permissions off
```

## Worktree mode

```bash
cs . --worktree
```

The agent gets a worktree on a scratch branch; your working tree is never mounted, but commits land in your object store:

```bash
git log sandbox/20260726-143022
git merge sandbox/20260726-143022
```

On exit an untouched worktree is removed, one with work in it is kept, and the review/merge/discard commands are printed.

## Auto-save

Off by default — a commit a minute buries real history under `auto-save #N`.

```bash
cs . --auto-git --interval 120
```

It skips no-op commits, and won't commit mid-merge, mid-rebase, mid-cherry-pick or on a detached HEAD.

## Local folders are bind-mounted

Edits and deletes hit your disk as they happen, so killing the sandbox loses nothing and untracked files it removes are gone.

`--snapshot` records the working tree — untracked included, gitignored excluded — to `refs/claude-sandbox/pre-session/<ts>` beforehand, touching neither HEAD, index, working tree nor stash:

```bash
cs . --snapshot
# later
git diff --stat <ref>
git checkout <ref> -- path/to/file
```

## Options

| Flag | Effect |
|---|---|
| `-y, --yes` | No prompts, use defaults |
| `-w, --worktree` | Isolate work in a git worktree |
| `-b, --branch <name>` | Check out or create a branch |
| `-m, --mount <path[:ro]>` | Mount another folder |
| `-n, --name <name>` | Container name |
| `--agent claude\|codex` | Agent for `exec` |
| `--auto-git` / `--interval <s>` | Periodic commits |
| `--browser` | Headless Chromium + Playwright MCP |
| `--update-tools` | Update agent CLIs at startup |
| `--snapshot` | Record the working tree first |
| `REPO_ROOTS=` (config) | Extra trees to search when picking mounts |
| `--network <mode>` / `-p a:b` | Networking |
| `--image <ref>` / `--pull` / `--no-pull` | Image selection |
| `--dry-run` | Print the docker command and exit |

Global defaults live in `~/.config/claude-sandbox/config`, using the same keys.

## How it works

```
┌──────────────────────────────────────────────────────────────────┐
│  Host                                                            │
│  ~/.claude   ~/.ssh   ~/.aws   ~/.config/gh   SSH agent          │
│      │                                              │            │
└──────┼──────────────────────────────────────────────┼────────────┘
       │ mount                                       │ forward
       ▼                                             ▼
┌──────────────────────────────────────────────────────────────────┐
│  Container (destroyed on exit)                                   │
│                                                                  │
│  ~/workspace/<repo>/      your folder, or a git worktree of it   │
│  ~/workspace/<other>/     extra mounts, rw or ro                 │
│  claude / codex           permissions disabled                   │
└──────────────────────────────────────────────────────────────────┘
```

Containers are labelled `com.claude-sandbox.managed=true`, which is how `ps`, `attach` and `kill` find them regardless of image tag.

## Development

```bash
make check        # lint + unit tests + portability (run before pushing)
make test         # bats unit tests, no Docker daemon needed
make build        # build the image
make test-image   # build, then smoke-test the image
make dry-run      # print the docker command for this repo
make dev          # symlink ~/.claude-sandbox to this clone, then build
```

Every tool runs from a pinned container when it isn't installed locally, so Docker is the only requirement. `claude-sandbox` is safe to `source` — `main` runs only when the file is executed — which is how the unit tests reach its internals.

## Releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org/). `make release VERSION=x.y.z` bumps the version, regenerates `CHANGELOG.md` and tags, publishing nothing. Pushing the tag publishes a verified tarball, a GitHub release, and a multi-arch image to `ghcr.io/rsh3khar/claude-sandbox` with build provenance.

## Troubleshooting

**AWS credentials expired** — `aws sso login` on the host; `~/.aws` is bind-mounted.

**Claude asks for login** — `claude setup-token`, then `echo 'TOKEN' > ~/.claude-sandbox-token && chmod 600 ~/.claude-sandbox-token`.

**Port not reachable** — bind to `0.0.0.0`, not `127.0.0.1`. Docker Desktop needs host networking enabled in settings; otherwise `--network bridge -p 3000:3000`. `cs doctor` reports which runtime you're on.

**A sandbox outlived its terminal** — `cs orphans`, then `cs kill <name>`.

## Screenshots

The clipboard doesn't cross the container boundary. Point macOS screenshots at a shared folder — the installer offers this:

```bash
mkdir -p ~/.claude/screenshots
defaults write com.apple.screencapture location ~/.claude/screenshots
killall SystemUIServer
```

Then take a screenshot and say "check the screenshot".

## License

MIT.
