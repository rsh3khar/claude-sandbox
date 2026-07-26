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
make check        # lint + format check + unit tests — run before pushing
make test         # bats unit tests only (fast, no Docker daemon needed)
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

- `bash` with `set -euo pipefail`, 4-space indent, `shfmt -i 4 -ci`
- shellcheck clean at `--severity=warning`; use a targeted `# shellcheck disable=` with a reason when you must
- comments explain *why*, particularly where behaviour looks odd — most of the odd-looking code here is working around a real platform difference

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), because release automation reads them:

```
feat: add worktree isolation
fix: stop chmod from propagating to host files
perf: render the contribution graph in one jq pass
docs: describe the threat model honestly
```

`feat` bumps the minor version, `fix` the patch. `!` or a `BREAKING CHANGE:` footer bumps major.

Do not edit `CHANGELOG.md` or the `VERSION` line in `claude-sandbox` by hand — release-please owns both.

## Releasing

Merging to `main` updates a release PR. Merging *that* tags the release, publishes a tarball with `SHA256SUMS`, and pushes a multi-arch image to GHCR with build provenance. No manual tagging.
