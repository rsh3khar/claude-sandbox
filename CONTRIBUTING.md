# Contributing

## Setup

```bash
git clone https://github.com/rsh3khar/claude-sandbox
cd claude-sandbox
make dev      # symlinks ~/.claude-sandbox to this clone, then builds the image
```

In dev mode, edits to `claude-sandbox` take effect immediately. Changes under `runtime/` or to the `Dockerfile` need `make build`.

## The loop

```bash
make check        # lint + unit tests + portability — run before pushing
make test         # bats unit tests only (fast, no Docker daemon needed)
make portability  # pure functions under the system bash (3.2 on macOS)
make test-image   # build the image and smoke-test it
make dry-run      # see the exact docker command this repo would launch with
```

Every tool runs from a pinned container image when it isn't on your PATH, so the only requirement is Docker.

## Testing

**Unit tests** (`tests/unit/*.bats`) source `claude-sandbox` and test its functions directly — the script only calls `main` when executed, never when sourced. Keep these free of Docker and network calls.

**Image smoke tests** (`tests/image-smoke.sh`) assert properties of the built image. They exist because each one has broken before:

- `codex` must not resolve inside `~/.codex` — that path is a host bind mount, and the host's copy is a macOS binary
- the entrypoint must never change permissions on bind-mounted host files
- worktree mode must leave the host checkout clean while commits reach the host repo
- `cs exec` must put only agent output on stdout

When you fix a bug, add the test that would have caught it.

## Style

- `bash` with `set -euo pipefail`, 4-space indent
- shellcheck clean at `--severity=warning`; use a targeted `# shellcheck disable=` with a reason when you must
- `make fmt` runs `shfmt -i 4 -ci` if you want it, but formatting is not gated: this codebase aligns case arms and box-drawing calls into columns deliberately, and shfmt collapses that
- comments explain *why*, particularly where behaviour looks odd — most of the odd-looking code here is working around a real platform difference

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), because release automation reads them:

```
feat: add worktree isolation
fix: stop chmod from propagating to host files
perf: render the contribution graph in one jq pass
docs: describe the threat model honestly
```

`feat`, `fix`, `perf`, `refactor` and `docs` become changelog sections. Other types (`test`, `build`, `chore`) stay out of it.

## Releasing

```bash
make release VERSION=0.4.0        # runs check, bumps VERSION, regenerates CHANGELOG.md, tags
git push origin main --follow-tags
```

`make release` publishes nothing; the tag does. Pushing it builds a tarball with `SHA256SUMS`, creates the GitHub release, and pushes a multi-arch image to GHCR with build provenance. The version is chosen by hand — nothing infers it from commit types.

`CHANGELOG.md` and the `VERSION` line in `claude-sandbox` are both rewritten by `make release`, so edits to them by hand will be overwritten.
