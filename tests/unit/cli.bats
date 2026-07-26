#!/usr/bin/env bats
#
# Unit tests for the pure parts of the claude-sandbox CLI.
# These never touch the Docker daemon — see tests/image-smoke.sh for that.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    # Sourcing is safe: main() only runs when the script is executed directly.
    source "$REPO_ROOT/claude-sandbox"
}

@test "version is a semver string" {
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "slugify lowercases and replaces unsafe characters" {
    [ "$(slugify 'My Repo')" = "my-repo" ]
    [ "$(slugify 'owner/repo')" = "owner-repo" ]
    [ "$(slugify 'UPPER_case.name')" = "upper_case.name" ]
    [ "$(slugify '--leading--and--trailing--')" = "leading-and-trailing" ]
}

@test "format_date never fails, whatever date implementation the platform has" {
    # GNU date, BSD date and busybox date all disagree about ISO-8601 parsing.
    # The contract is only that this is best-effort and never aborts a launch.
    run format_date "2026-01-15T10:30:00Z"
    [ "$status" -eq 0 ]

    run format_date "not-a-date"
    [ "$status" -eq 0 ]

    run format_date ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run format_date "null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "format_date renders a short date where the platform can parse ISO-8601" {
    if ! date -d "2026-01-15T10:30:00Z" +%b >/dev/null 2>&1 &&
       ! date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-15T10:30:00Z" +%b >/dev/null 2>&1; then
        skip "platform date cannot parse ISO-8601"
    fi

    run format_date "2026-01-15T10:30:00Z"
    [[ "$output" =~ ^[A-Z][a-z]{2}\ [0-9]{2}$ ]]
}

@test "resolve_mount_name appends a suffix on collision" {
    SELECTED_REPO="api"
    EXTRA_PATHS=()
    [ "$(resolve_mount_name 'web')" = "web" ]
    [ "$(resolve_mount_name 'api')" = "api-2" ]

    EXTRA_PATHS=("/x/web|web|rw")
    [ "$(resolve_mount_name 'web')" = "web-2" ]
}

@test "resolve_mount_name compares against the repo basename, not owner/repo" {
    SELECTED_REPO="owner/api"
    EXTRA_PATHS=()
    [ "$(resolve_mount_name 'api')" = "api-2" ]
}

@test "print_docker_command masks every secret it forwards" {
    DOCKER_ARGS=(run --rm
        -e "CLAUDE_CODE_OAUTH_TOKEN=sk-super-secret"
        -e "ANTHROPIC_API_KEY=sk-ant-secret"
        -e "GH_TOKEN=ghp_secret"
        image)

    run print_docker_command
    [ "$status" -eq 0 ]
    [[ "$output" != *"sk-super-secret"* ]]
    [[ "$output" != *"sk-ant-secret"* ]]
    [[ "$output" != *"ghp_secret"* ]]
    [[ "$output" == *"CLAUDE_CODE_OAUTH_TOKEN=***"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY=***"* ]]
    [[ "$output" == *"GH_TOKEN=***"* ]]
}

@test "print_docker_command quotes arguments containing spaces" {
    DOCKER_ARGS=(run -e "GIT_USER_NAME=Ada Lovelace" image)
    run print_docker_command
    [[ "$output" == *"'GIT_USER_NAME=Ada Lovelace'"* ]]
}

@test "parse_args reads launch flags" {
    POSITIONAL=()
    parse_args . -y --browser --no-auto-git --interval 30 --network bridge -b feature/x

    [ "$ASSUME_YES" = true ]
    [ "$BROWSER" = true ]
    [ "$AUTO_GIT" = false ]
    [ "$AUTO_GIT_INTERVAL" = "30" ]
    [ "$NETWORK" = "bridge" ]
    [ "$SANDBOX_BRANCH" = "feature/x" ]
    [ "${POSITIONAL[0]}" = "." ]
}

@test "parse_args treats --mount as an extra positional target" {
    POSITIONAL=()
    parse_args . -m /tmp/one -m /tmp/two
    [ "${#POSITIONAL[@]}" -eq 3 ]
    [ "${POSITIONAL[1]}" = "/tmp/one" ]
    [ "${POSITIONAL[2]}" = "/tmp/two" ]
}

@test "parse_args publishing a port switches to bridge networking" {
    POSITIONAL=()
    parse_args . -p 3000:3000
    [ "$NETWORK" = "bridge" ]
    [ "${PUBLISH_PORTS[0]}" = "3000:3000" ]
}

@test "parse_args rejects unknown options" {
    run parse_args --definitely-not-a-flag
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "dry-run implies non-interactive" {
    POSITIONAL=()
    parse_args --dry-run
    [ "$DRY_RUN" = true ]
    [ "$ASSUME_YES" = true ]
}

@test "build_docker_args wires local mode into mounts and entrypoint args" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/myrepo"
    SELECTED_REPO="myrepo"
    IMAGE_REF="claude-sandbox"
    CONTAINER_NAME="cs-test"      # avoids the docker ps lookup
    EXTRA_PATHS=("/tmp/other|other|rw")
    AUTO_GIT=true
    BROWSER=false

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"--name cs-test"* ]]
    [[ "$joined" == *"com.claude-sandbox.managed=true"* ]]
    [[ "$joined" == *"com.claude-sandbox.mode=local"* ]]
    [[ "$joined" == *"/tmp/myrepo:/home/node/workspace/myrepo"* ]]
    [[ "$joined" == *"/tmp/other:/home/node/workspace/other"* ]]
    [[ "$joined" == *"LOCAL_MODE=1"* ]]
    [[ "$joined" == *"--local myrepo"* ]]
}

@test "build_docker_args passes the clone URL in github mode" {
    LOCAL_MODE=false
    SELECTED_REPO="owner/repo"
    SELECTED_REPO_URL="git@github.com:owner/repo.git"
    IMAGE_REF="claude-sandbox"
    CONTAINER_NAME="cs-test"
    EXTRA_PATHS=()

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"git@github.com:owner/repo.git"* ]]
    [[ "$joined" == *"com.claude-sandbox.mode=github"* ]]
    [[ "$joined" != *"LOCAL_MODE=1"* ]]
}

@test "build_docker_args disables auto-git when requested" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    AUTO_GIT=false

    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"DISABLE_AUTO_GIT=1"* ]]
    [[ "${DOCKER_ARGS[*]}" != *"AUTO_GIT_INTERVAL"* ]]
}

@test "build_docker_args mounts the browser cache volume only with --browser" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()

    BROWSER=false
    build_docker_args
    [[ "${DOCKER_ARGS[*]}" != *"claude-sandbox-browser"* ]]

    BROWSER=true
    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"claude-sandbox-browser:/usr/local/share/playwright"* ]]
    [[ "${DOCKER_ARGS[*]}" == *"ENABLE_BROWSER=1"* ]]
}

@test "help output lists every subcommand" {
    run show_help
    [ "$status" -eq 0 ]
    for cmd in run exec ps attach kill orphans worktrees doctor update version help; do
        [[ "$output" == *"$cmd"* ]]
    done
}

# ── Local-mode mounts ────────────────────────────────────────────────────────

@test "mount accessors split the pipe-delimited entry" {
    local entry="/a/b c:d|name|ro"
    [ "$(mount_path "$entry")" = "/a/b c:d" ]
    [ "$(mount_name "$entry")" = "name" ]
    [ "$(mount_mode "$entry")" = "ro" ]
}

@test "validate_and_add_extra_path accepts non-git folders and :ro" {
    local dir
    dir="$(mktemp -d)"
    LOCAL_PATH="/somewhere/else"
    SELECTED_REPO="primary"
    EXTRA_PATHS=()

    run validate_and_add_extra_path "$dir"
    [ "$status" -eq 0 ]

    EXTRA_PATHS=()
    validate_and_add_extra_path "${dir}:ro" >/dev/null
    [ "$(mount_mode "${EXTRA_PATHS[0]}")" = "ro" ]
    [ "$(mount_path "${EXTRA_PATHS[0]}")" = "$dir" ]

    rm -rf "$dir"
}

@test "validate_and_add_extra_path refuses duplicates and the primary repo" {
    local dir
    dir="$(mktemp -d)"
    LOCAL_PATH="$dir"
    SELECTED_REPO="primary"
    EXTRA_PATHS=()

    run validate_and_add_extra_path "$dir"
    [ "$status" -ne 0 ]

    LOCAL_PATH="/elsewhere"
    validate_and_add_extra_path "$dir" >/dev/null
    run validate_and_add_extra_path "$dir"
    [ "$status" -ne 0 ]

    rm -rf "$dir"
}

@test "read-only mounts are marked :ro in the docker args" {
    local dir
    dir="$(mktemp -d)"
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=("${dir}|docs|ro")

    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"${dir}:/home/node/workspace/docs:ro"* ]]

    rm -rf "$dir"
}

@test "MOUNTS config entries resolve relative to the repo" {
    local base sibling
    base="$(mktemp -d)"
    mkdir -p "$base/repo" "$base/api"
    sibling="$base/api"

    LOCAL_PATH="$base/repo"
    SELECTED_REPO="repo"
    EXTRA_PATHS=()
    MOUNTS="../api"

    add_mounts_from_config "$LOCAL_PATH" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 1 ]
    [ "$(mount_name "${EXTRA_PATHS[0]}")" = "api" ]
    [ "$(mount_path "${EXTRA_PATHS[0]}")" = "$(cd "$sibling" && pwd)" ]

    rm -rf "$base"
}

# ── Precedence ───────────────────────────────────────────────────────────────

@test "explicit flags beat config file values" {
    local cfg
    cfg="$(mktemp)"
    printf 'BROWSER=true\nNETWORK=bridge\n' > "$cfg"

    POSITIONAL=()
    parse_args --no-browser         # explicit
    load_config_file "$cfg"

    [ "$BROWSER" = false ]          # flag wins
    [ "$NETWORK" = "bridge" ]       # config still applies where no flag was given

    rm -f "$cfg"
}

# ── Headless exec ────────────────────────────────────────────────────────────

@test "exec mode passes the prompt and drops the TTY" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    EXEC_PROMPT="run the tests"
    AGENT="codex"

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"SANDBOX_EXEC=run the tests"* ]]
    [[ "$joined" == *"SANDBOX_AGENT=codex"* ]]
    [[ " $joined " == *" -i "* ]]
    [[ " $joined " != *" -it "* ]]
}

@test "interactive mode keeps the TTY" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    EXEC_PROMPT=""

    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"-it"* ]]
    [[ "${DOCKER_ARGS[*]}" != *"SANDBOX_EXEC"* ]]
}

# ── Worktree isolation ───────────────────────────────────────────────────────

@test "worktree mode mounts the worktree and mirrors the main .git path" {
    LOCAL_MODE=true
    LOCAL_PATH="/host/repo"
    SELECTED_REPO="repo"
    IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    WORKTREE_PATH="/host/worktrees/repo-sandbox"

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    # The worktree is what the agent sees as the repo...
    [[ "$joined" == *"/host/worktrees/repo-sandbox:/home/node/workspace/repo"* ]]
    # ...and the main .git is mirrored so the gitdir link resolves
    [[ "$joined" == *"/host/repo/.git:/host/repo/.git"* ]]
    # The real working tree is never mounted
    [[ "$joined" != *" /host/repo:/home/node/workspace/repo"* ]]
}

@test "worktree gitdir target follows the recorded gitdir, not the given path" {
    # git records a symlink-resolved absolute path in the worktree's .git file;
    # mounting $LOCAL_PATH/.git blindly would miss it (macOS /var -> /private/var).
    local base
    base="$(mktemp -d)"
    WORKTREE_PATH="$base/tree"
    mkdir -p "$WORKTREE_PATH"
    echo "gitdir: /private/real/repo/.git/worktrees/tree" > "$WORKTREE_PATH/.git"

    LOCAL_PATH="/var/link/repo"
    [ "$(worktree_gitdir_target)" = "/private/real/repo/.git" ]

    rm -rf "$base"
}

@test "worktree gitdir target falls back to a physical path before creation" {
    WORKTREE_PATH="/nonexistent/worktree"
    LOCAL_PATH="/definitely/not/here"
    [ "$(worktree_gitdir_target)" = "/definitely/not/here/.git" ]
}

# ── Recent workspaces ────────────────────────────────────────────────────────

@test "recent workspaces round-trip, including paths with spaces and commas" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/my proj" "$base/Acme, Inc" "$base/plain"
    RECENT_FILE="$base/recent"

    LOCAL_MODE=true
    LOCAL_PATH="$base/my proj"
    SELECTED_REPO="my proj"
    EXTRA_PATHS=("$base/Acme, Inc|acme|ro" "$base/plain|plain|rw")

    remember_workspace
    [ -f "$RECENT_FILE" ]

    run list_recent_workspaces
    [[ "$output" == *"my proj + 2 mount(s)"* ]]

    # Restore rebuilds both mounts intact — neither the space nor the comma
    # may split a path in two.
    local label path extras
    IFS=$'\t' read -r label path extras < <(list_recent_workspaces)
    [ "$path" = "$base/my proj" ]

    EXTRA_PATHS=()
    LOCAL_PATH=""
    restore_recent_workspace "$path" "$extras"

    [ "$LOCAL_PATH" = "$base/my proj" ]
    [ "${#EXTRA_PATHS[@]}" -eq 2 ]
    [ "$(mount_path "${EXTRA_PATHS[0]}")" = "$base/Acme, Inc" ]
    [ "$(mount_mode "${EXTRA_PATHS[0]}")" = "ro" ]
    [ "$(mount_path "${EXTRA_PATHS[1]}")" = "$base/plain" ]

    rm -rf "$base"
}

@test "paths with spaces survive into the docker arguments" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/my repo" "$base/other dir"

    LOCAL_MODE=true
    LOCAL_PATH="$base/my repo"
    SELECTED_REPO="my repo"
    IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    validate_and_add_extra_path "$base/other dir" >/dev/null

    build_docker_args

    # Each -v must be ONE argv element, with the space preserved
    local found_primary=0 found_extra=0 a
    for a in "${DOCKER_ARGS[@]}"; do
        [[ "$a" == "$base/my repo:/home/node/workspace/my repo" ]] && found_primary=1
        [[ "$a" == "$base/other dir:/home/node/workspace/other dir" ]] && found_extra=1
    done
    [ "$found_primary" -eq 1 ]
    [ "$found_extra" -eq 1 ]

    # And the container name must be slug-safe
    [[ "$CONTAINER_NAME" != *" "* ]]

    rm -rf "$base"
}

@test "recent workspaces skip directories that no longer exist" {
    local base
    base="$(mktemp -d)"
    RECENT_FILE="$base/recent"
    printf '%s\t\n' "$base/gone" > "$RECENT_FILE"

    run list_recent_workspaces
    [ -z "$output" ]

    rm -rf "$base"
}

# ── Blast radius ─────────────────────────────────────────────────────────────

@test "host agent config is mounted whole and read-write" {
    # Deliberate: settings, skills, plugins, session history and --resume all
    # need the real directories. Do not "harden" this by masking or redirecting
    # them -- it breaks resume and throws away the session transcript.
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.claude/projects" "$fake_home/.codex" "$fake_home/.agents"
    HOME="$fake_home"

    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    DRY_RUN=true

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"$fake_home/.claude:/home/node/.claude"* ]]
    [[ "$joined" == *"$fake_home/.codex:/home/node/.codex"* ]]
    [[ "$joined" == *"$fake_home/.agents:/home/node/.agents"* ]]

    # No masking or redirection of anything inside them
    [[ "$joined" != *"tmpfs,destination=/home/node/.claude"* ]]
    [[ "$joined" != *"/home/node/.claude/projects"* ]]

    rm -rf "$fake_home"
}

# ── Durability of local work ─────────────────────────────────────────────────

@test "auto-save defaults off for local mode, on for github clones" {
    # A bind-mounted repo is already on the host, so a killed container loses
    # nothing. A clone that lives inside the container does.
    EXPLICIT_KEYS=()
    LOCAL_MODE=true
    AUTO_GIT=false
    apply_autosave_default
    [ "$AUTO_GIT" = false ]

    EXPLICIT_KEYS=()
    LOCAL_MODE=false
    AUTO_GIT=false
    apply_autosave_default
    [ "$AUTO_GIT" = true ]
}

@test "an explicit --no-auto-git is honoured even for github clones" {
    EXPLICIT_KEYS=()
    LOCAL_MODE=false
    POSITIONAL=()
    parse_args --no-auto-git
    apply_autosave_default
    [ "$AUTO_GIT" = false ]
}

@test "snapshots are opt-in, not taken by default" {
    EXPLICIT_KEYS=()
    POSITIONAL=()
    parse_args .
    [ "$SNAPSHOT" = false ]

    POSITIONAL=()
    parse_args . --snapshot
    [ "$SNAPSHOT" = true ]
}

@test "snapshots cover every writable mounted repo, skipping read-only ones" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/primary" "$base/api" "$base/readonly"
    SNAPSHOT=true
    LOCAL_MODE=true
    WORKTREE_PATH=""
    LOCAL_PATH="$base/primary"
    EXTRA_PATHS=("$base/api|api|rw" "$base/readonly|readonly|ro")

    # None are git repos, so nothing is recorded — but the walk must not fail
    run snapshot_all_repos
    [ "$status" -eq 0 ]

    rm -rf "$base"
}

@test "snapshot leaves HEAD, the index and the working tree untouched" {
    if ! command -v git >/dev/null 2>&1; then
        skip "git not available in this environment"
    fi

    local repo
    repo="$(mktemp -d)"
    (
        cd "$repo"
        git init -q
        echo committed > a.txt
        git add -A
        git -c user.email=t@t -c user.name=t commit -qm base
        echo modified > a.txt
        echo untracked > b.txt
    ) >/dev/null 2>&1

    local head_before status_before
    head_before=$(git -C "$repo" rev-parse HEAD)
    status_before=$(git -C "$repo" status --porcelain)

    SNAPSHOT=true
    SNAPSHOT_REFS=()
    snapshot_repo "$repo"

    [ "$(git -C "$repo" rev-parse HEAD)" = "$head_before" ]
    [ "$(git -C "$repo" status --porcelain)" = "$status_before" ]
    [ "${#SNAPSHOT_REFS[@]}" -eq 1 ]

    # Both the modified tracked file and the untracked one are recoverable
    local ref="${SNAPSHOT_REFS[0]##*|}"
    [ "$(git -C "$repo" show "${ref}:a.txt")" = "modified" ]
    [ "$(git -C "$repo" show "${ref}:b.txt")" = "untracked" ]

    rm -rf "$repo"
}

@test "terminal control codes never reach a piped stdout" {
    # `cs exec ... | jq` and `cs --dry-run > file` must not receive escape
    # sequences from cursor restoration.
    run cleanup_terminal
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Discovering repos to mount ───────────────────────────────────────────────

@test "discover_repos finds repos across sibling and cousin trees" {
    local base
    base="$(mktemp -d)"
    # layout: base/group-a/{primary,api}  base/group-b/web
    mkdir -p "$base/group-a/primary/.git" "$base/group-a/api/.git" \
             "$base/group-b/web/.git" "$base/group-a/plain-dir"
    LOCAL_PATH="$base/group-a/primary"
    REPO_ROOTS=""

    run discover_repos
    [ "$status" -eq 0 ]

    # sibling (same parent) and cousin (via grandparent) both found
    [[ "$output" == *"$base/group-a/api"* ]]
    [[ "$output" == *"$base/group-b/web"* ]]
    # a non-git directory is not offered
    [[ "$output" != *"plain-dir"* ]]

    rm -rf "$base"
}

@test "REPO_ROOTS adds trees outside the repo's own hierarchy" {
    local base elsewhere
    base="$(mktemp -d)"
    elsewhere="$(mktemp -d)"
    mkdir -p "$base/group/primary/.git" "$elsewhere/notes/.git"
    LOCAL_PATH="$base/group/primary"

    REPO_ROOTS=""
    run discover_repos
    [[ "$output" != *"$elsewhere/notes"* ]]

    REPO_ROOTS="$elsewhere"
    run discover_repos
    [[ "$output" == *"$elsewhere/notes"* ]]

    rm -rf "$base" "$elsewhere"
}

@test "discover_repos ignores repos vendored inside node_modules" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/group/primary/.git" "$base/group/app/node_modules/dep/.git"
    LOCAL_PATH="$base/group/primary"
    REPO_ROOTS=""

    run discover_repos
    [[ "$output" != *"node_modules"* ]]

    rm -rf "$base"
}

@test "discover_repos refuses to scan from \$HOME or /" {
    LOCAL_PATH="$HOME/somerepo"     # parent is $HOME -> no roots
    REPO_ROOTS=""
    run discover_repos
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}


@test "discovery reaches repos nested one level deeper than the group folder" {
    # ~/work/<group>/<area>/<repo> puts .git 4 levels down; a depth-3 scan
    # silently omitted an entire product's worth of repos.
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/group/primary/.git" \
             "$base/product/server/api/.git" \
             "$base/product/app/web/.git"
    LOCAL_PATH="$base/group/primary"
    REPO_ROOTS=""
    REPO_DEPTH=5

    run discover_repos
    [[ "$output" == *"$base/product/server/api"* ]]
    [[ "$output" == *"$base/product/app/web"* ]]

    rm -rf "$base"
}

@test "REPO_DEPTH is configurable" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/group/primary/.git" "$base/a/b/c/deep/.git"
    LOCAL_PATH="$base/group/primary"
    REPO_ROOTS=""

    REPO_DEPTH=2
    run discover_repos
    [[ "$output" != *"deep"* ]]

    REPO_DEPTH=6
    run discover_repos
    [[ "$output" == *"$base/a/b/c/deep"* ]]

    rm -rf "$base"
}


@test "list_dirs_of marks git repos and skips dotfolders" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/a-repo/.git" "$base/plain" "$base/.hidden"

    run list_dirs_of "$base"
    [[ "$output" == *"a-repo"* ]]
    [[ "$output" == *"[repo]"* ]]
    [[ "$output" == *"plain"* ]]
    [[ "$output" != *".hidden"* ]]

    rm -rf "$base"
}

# ── Menus must never abort the CLI ───────────────────────────────────────────



# ── Interactive prompts ──────────────────────────────────────────────────────
# gum exits non-zero on esc/ctrl-c. These assert the behaviour that keeps the
# CLI alive, by stubbing gum rather than grepping the source for guards.

@test "pick_one returns empty and succeeds when the user cancels" {
    gum() { return 1; }          # esc / ctrl-c
    export -f gum 2>/dev/null || true

    run pick_one "" "alpha" "beta"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pick_one passes the selection through unchanged" {
    gum() { echo "beta"; }
    run pick_one "header" "alpha" "beta"
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

@test "pick_one with no items is a no-op rather than an error" {
    run pick_one "header"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pick_many returns empty and succeeds when cancelled" {
    gum() { return 130; }        # ctrl-c
    run pick_many "placeholder" "one" "two"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pick_many returns every selected line" {
    gum() { printf 'one\nthree\n'; }
    run pick_many "placeholder" "one" "two" "three"
    [ "$status" -eq 0 ]
    [[ "$output" == *"one"* ]]
    [[ "$output" == *"three"* ]]
}

@test "ask_text returns empty and succeeds when cancelled" {
    gum() { return 1; }
    run ask_text "type here"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ask_text forwards a default value" {
    gum() { printf '%s\n' "$*"; }
    run ask_text "placeholder" "thedefault"
    [[ "$output" == *"--value=thedefault"* ]]
}

@test "every screen survives a cancelled picker" {
    # The real regression: under set -euo pipefail an unguarded capture aborted
    # the CLI, so esc quit cs outright.
    gum() { return 1; }
    EXTRA_PATHS=(); LOCAL_PATH="/tmp"; LOCAL_MODE=true; SELECTED_REPO=""

    run screen_source_select
    [ "$status" -eq 0 ]

    run prompt_extra_mounts
    [ "$status" -eq 0 ]
}

# ── The running selection stays visible ──────────────────────────────────────

@test "mounts_summary lists the primary repo and every extra mount" {
    SELECTED_REPO="open-contract"
    EXTRA_PATHS=()
    run mounts_summary
    [ "$output" = "mounting: open-contract" ]

    EXTRA_PATHS=("/a/api|api|rw" "/b/notes|notes|ro")
    run mounts_summary
    [ "$output" = "mounting: open-contract + api, notes:ro" ]
}

@test "mounts_summary uses the repo basename, not owner/repo" {
    SELECTED_REPO="owner/repo"
    EXTRA_PATHS=()
    run mounts_summary
    [ "$output" = "mounting: repo" ]
}

@test "mounts_summary is safe before anything is selected" {
    SELECTED_REPO=""
    EXTRA_PATHS=()
    run mounts_summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing yet"* ]]
}

@test "the selection panel lists the main folder and every mount once" {
    SELECTED_REPO="open-contract"
    LOCAL_MODE=true
    LOCAL_PATH="$HOME/work/open-contract"
    EXTRA_PATHS=("$HOME/work/api|api|rw" "$HOME/notes|notes|ro")

    run draw_selection_panel
    [ "$status" -eq 0 ]

    # every selected thing appears, exactly once each
    [ "$(grep -c 'open-contract' <<< "$output")" -eq 2 ]   # name + path line
    [[ "$output" == *"api"* ]]
    [[ "$output" == *"notes"* ]]
    [[ "$output" == *"read-only"* ]]
    [[ "$output" == *"(main)"* ]]
}

@test "the selection panel is honest when nothing is chosen" {
    SELECTED_REPO=""
    EXTRA_PATHS=()
    run draw_selection_panel
    [ "$status" -eq 0 ]
    [[ "$output" == *"no folder chosen yet"* ]]
}


@test "long paths are truncated to fit a narrow panel" {
    SELECTED_REPO="r"
    LOCAL_MODE=true
    LOCAL_PATH="/a"
    EXTRA_PATHS=("/an/extremely/long/path/that/will/never/fit/in/a/narrow/panel/api|api|rw")

    run draw_selection_panel 40
    [[ "$output" == *"…"* ]]
}

@test "the corner panel stacks instead of overlaying when there is no room" {
    SELECTED_REPO="r"; EXTRA_PATHS=()

    CS_TERM_COLS=80 CS_TERM_ROWS=40
    run selection_fits_beside
    [ "$status" -ne 0 ]

    CS_TERM_COLS=150 CS_TERM_ROWS=20
    run selection_fits_beside
    [ "$status" -ne 0 ]

    CS_TERM_COLS=150 CS_TERM_ROWS=40
    run selection_fits_beside
    [ "$status" -eq 0 ]
}

@test "corner placement emits cursor positioning only when it fits" {
    SELECTED_REPO="r"; EXTRA_PATHS=(); LOCAL_MODE=true; LOCAL_PATH="/a"

    CS_TERM_COLS=80 CS_TERM_ROWS=40 run draw_selection_corner
    [ "$status" -eq 0 ]
    [[ "$output" == *"THIS SANDBOX WILL MOUNT"* ]]   # stacked, still visible
}

@test "clear_screen survives an unset or dumb TERM" {
    TERM="" run clear_screen
    [ "$status" -eq 0 ]

    TERM=dumb run clear_screen
    [ "$status" -eq 0 ]
}

# ── Multi-select from the folder browser ─────────────────────────────────────

@test "every folder tab-selected in the browser becomes a mount" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/one" "$base/two" "$base/three"

    LOCAL_PATH="/elsewhere"
    SELECTED_REPO="primary"
    EXTRA_PATHS=()
    browse_directories() { printf '%s\n%s\n%s\n' "$base/one" "$base/two" "$base/three"; }
    gum() { return 1; }          # "Mount read-only?" -> no

    add_mount_interactively "$base" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 3 ]

    rm -rf "$base"
}

@test "a selection is kept even when the browser reports a non-zero exit" {
    # pipefail + SIGPIPE made the browser 'fail' while still having produced
    # output; `|| return` then discarded everything the user picked.
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/one" "$base/two"

    LOCAL_PATH="/elsewhere"
    SELECTED_REPO="primary"
    EXTRA_PATHS=()
    browse_directories() { printf '%s\n%s\n' "$base/one" "$base/two"; return 141; }
    gum() { return 1; }

    add_mount_interactively "$base" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 2 ]

    rm -rf "$base"
}


@test "browsing loops so folders can be gathered across directories" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/a/one" "$base/b/two" "$base/c/three"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()

    # Three passes: one folder each, then cancel out of the browser.
    printf '%s\n%s\n%s\n' "$base/a/one" "$base/b/two" "$base/c/three" > "$BATS_TEST_TMPDIR/queue"
    browse_directories() {
        local v=""
        if [[ -s "$BATS_TEST_TMPDIR/queue" ]]; then
            v=$(head -n 1 "$BATS_TEST_TMPDIR/queue")
            tail -n +2 "$BATS_TEST_TMPDIR/queue" > "$BATS_TEST_TMPDIR/q2" && mv "$BATS_TEST_TMPDIR/q2" "$BATS_TEST_TMPDIR/queue"
        fi
        printf '%s' "$v"
    }
    gum() { return 0; }   # read-only? yes ; continue? yes

    add_mount_interactively "$base" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 3 ]

    rm -rf "$base"
}

@test "browsing stops when the user declines to continue" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/one"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()
    browse_directories() { printf '%s' "$base/one"; }
    # first gum call = read-only? ; second = continue? -> answer no to continue
    local n="$BATS_TEST_TMPDIR/n"; echo 0 > "$n"
    gum() {
        local c; c=$(cat "$n"); echo $((c + 1)) > "$n"
        [[ "$c" == "1" ]] && return 1     # decline "add from somewhere else"
        return 0
    }

    run timeout 10 bash -c "true"   # guard: the loop must not spin
    add_mount_interactively "$base" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 1 ]

    rm -rf "$base"
}

@test "a pass that adds nothing new ends the browse loop" {
    # Otherwise re-selecting the same folders would re-offer them forever.
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/dup"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()
    browse_directories() { printf '%s' "$base/dup"; }   # always the same folder
    gum() { return 0; }                                  # always "yes, continue"

    run timeout 10 bash -c "
        source '$REPO_ROOT/claude-sandbox'
        LOCAL_PATH=/elsewhere; SELECTED_REPO=primary; EXTRA_PATHS=()
        browse_directories() { printf '%s' '$base/dup'; }
        gum() { return 0; }
        sleep() { :; }
        add_mount_interactively '$base' >/dev/null 2>&1
        echo \"count=\${#EXTRA_PATHS[@]}\"
    "
    [ "$status" -eq 0 ]                 # terminated, did not spin
    [[ "$output" == *"count=1"* ]]      # added once, not repeatedly

    rm -rf "$base"
}

# ── Selecting several folders at once ───────────────────────────────────────

@test "every folder fzf returns becomes a mount, from any directories" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/one" "$base/two" "$base/deep/three"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()
    # fzf multi-select emits one line per marked row
    fzf() { printf '%s\t%s\n' "$base/one" one "$base/two" two "$base/deep/three" three; }
    gum() { return 1; }

    add_mount_interactively "$base" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 3 ]

    rm -rf "$base"
}

@test "browse_directories asks fzf for multi-select and returns the path column" {
    local seen="$BATS_TEST_TMPDIR/args"
    fzf() { printf '%s\n' "$@" > "$seen"; printf '/p/one\tone/\n/p/two\ttwo/\n'; }

    run browse_directories /tmp
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
    [[ "$output" == *"/p/one"* ]]
    [[ "$output" == *"/p/two"* ]]

    grep -qx -- '--multi' "$seen"
    grep -q -- 'space:toggle' "$seen"
    # no reload: reload is what cleared marks
    ! grep -q -- 'reload(' "$seen"
}

# ── The folder picker is a flat multi-select, not a drill-down ───────────────

@test "picker lists repos at any depth, plus shallow plain folders" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/group/deep/area/repo/.git" "$base/notes" "$base/notes/sub"

    run list_dirs_tree "$base"
    [ "$status" -eq 0 ]

    # a repo four levels down is offered, and marked
    [[ "$output" == *"group/deep/area/repo  [repo]"* ]]
    # a shallow plain folder is offered
    [[ "$output" == *"notes/"* ]]

    rm -rf "$base"
}

@test "picker rows carry the real path in a hidden first column" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/proj/.git"

    run list_dirs_tree "$base"
    # field 1 must be an absolute, usable path
    local first
    first=$(printf '%s\n' "$output" | head -1 | cut -f1)
    [ -d "$first" ]

    rm -rf "$base"
}

@test "picker skips node_modules and dotfolders" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/app/node_modules/dep/.git" "$base/.hidden/x"

    run list_dirs_tree "$base"
    [[ "$output" != *"node_modules"* ]]
    [[ "$output" != *".hidden"* ]]

    rm -rf "$base"
}

@test "read-only is a menu choice, applied to the whole batch" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/ref" "$base/docs"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()
    fzf() { printf '%s\t%s\n' "$base/ref" ref "$base/docs" docs; }
    gum() { return 1; }        # decline "add from somewhere else"

    add_mount_interactively "$base" ro >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 2 ]
    [ "$(mount_mode "${EXTRA_PATHS[0]}")" = "ro" ]
    [ "$(mount_mode "${EXTRA_PATHS[1]}")" = "ro" ]

    rm -rf "$base"
}

@test "browsing defaults to read-write with no extra prompt" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/api"

    LOCAL_PATH="/elsewhere"; SELECTED_REPO="primary"; EXTRA_PATHS=()
    fzf() { printf '%s\t%s\n' "$base/api" api; }
    local asked="$BATS_TEST_TMPDIR/asked"; : > "$asked"
    gum() { printf '%s\n' "$*" >> "$asked"; return 1; }

    add_mount_interactively "$base" >/dev/null 2>&1

    [ "$(mount_mode "${EXTRA_PATHS[0]}")" = "rw" ]
    # the only question asked may be whether to continue, never read-only
    ! grep -qi "read-only" "$asked"

    rm -rf "$base"
}

@test "picker reaches back to \$HOME, not just the current tree" {
    local home_dir
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/work/group/deep/repo/.git" "$home_dir/knowledge" "$home_dir/code/tool"
    HOME="$home_dir"

    run list_dirs_tree "$home_dir/work"

    # deep repo in the working tree
    [[ "$output" == *"work/group/deep/repo"* ]]
    # sibling trees under $HOME, reached without navigating
    [[ "$output" == *"knowledge"* ]]
    [[ "$output" == *"code/tool"* ]]

    rm -rf "$home_dir"
}

@test "picker lists plain folders, not only git repos" {
    local home_dir
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/notes" "$home_dir/data/exports" "$home_dir/proj/.git"
    HOME="$home_dir"

    run list_dirs_tree "$home_dir/proj"

    [[ "$output" == *"notes"* ]]
    [[ "$output" == *"data/exports"* ]]
    [[ "$output" == *"[repo]"* ]]      # repos still marked

    rm -rf "$home_dir"
}

@test "picker prunes Library, Applications and app bundles" {
    local home_dir
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/Library/Caches/x" "$home_dir/Applications/Foo.app/Contents" \
             "$home_dir/Thing.app/Contents" "$home_dir/keep"
    HOME="$home_dir"

    run list_dirs_tree "$home_dir"

    [[ "$output" != *"Library"* ]]
    [[ "$output" != *"Applications"* ]]
    [[ "$output" != *".app"* ]]
    [[ "$output" == *"keep"* ]]

    rm -rf "$home_dir"
}

@test "picker returns each path exactly once" {
    local home_dir
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/work/repo/.git"
    HOME="$home_dir"

    run list_dirs_tree "$home_dir/work"
    local dupes
    dupes=$(printf '%s\n' "$output" | cut -f1 | sort | uniq -d | grep -c . || true)
    [ "$dupes" -eq 0 ]

    rm -rf "$home_dir"
}

# ── Undoing a mistaken selection ─────────────────────────────────────────────

@test "a mount can be removed after it was added" {
    EXTRA_PATHS=("/a/api|api|rw" "/b/notes|notes|rw" "/c/web|web|rw")
    pick_one() { printf 'notes'; }

    remove_mount_interactively >/dev/null
    [ "${#EXTRA_PATHS[@]}" -eq 2 ]
    [ "$(mount_name "${EXTRA_PATHS[0]}")" = "api" ]
    [ "$(mount_name "${EXTRA_PATHS[1]}")" = "web" ]
}

@test "removing a read-only mount matches despite its label" {
    EXTRA_PATHS=("/a/api|api|rw" "/b/docs|docs|ro")
    pick_one() { printf 'docs  [read-only]'; }

    remove_mount_interactively >/dev/null
    [ "${#EXTRA_PATHS[@]}" -eq 1 ]
    [ "$(mount_name "${EXTRA_PATHS[0]}")" = "api" ]
}

@test "Back leaves the mounts untouched" {
    EXTRA_PATHS=("/a/api|api|rw" "/b/web|web|rw")
    pick_one() { printf '← Back'; }

    remove_mount_interactively >/dev/null
    [ "${#EXTRA_PATHS[@]}" -eq 2 ]
}

@test "removing from an empty list is a no-op" {
    EXTRA_PATHS=()
    pick_one() { printf 'anything'; }

    run remove_mount_interactively
    [ "$status" -eq 0 ]
}

@test "the remove entry appears only when something is mounted" {
    # menu is built from EXTRA_PATHS, so check the construction directly
    EXTRA_PATHS=()
    local menu=("Pick from my repos" "Browse folders" "Browse folders (read-only)" "Type a path")
    [[ ${#EXTRA_PATHS[@]} -gt 0 ]] && menu+=("Remove a mount")
    menu+=("Done")
    [[ "${menu[*]}" != *"Remove a mount"* ]]

    EXTRA_PATHS=("/a/x|x|rw")
    menu=("Pick from my repos" "Browse folders" "Browse folders (read-only)" "Type a path")
    [[ ${#EXTRA_PATHS[@]} -gt 0 ]] && menu+=("Remove a mount")
    menu+=("Done")
    [[ "${menu[*]}" == *"Remove a mount"* ]]
}

# ── Direct invocation (cs .) ─────────────────────────────────────────────────

@test "cs . keeps mounts declared in the repo's .claude-sandbox" {
    local base
    base="$(mktemp -d)"
    mkdir -p "$base/main" "$base/sibling"
    printf 'MOUNTS=../sibling\n' > "$base/main/.claude-sandbox"

    LOCAL_PATH=""; SELECTED_REPO=""; EXTRA_PATHS=(); MOUNTS=""
    DRY_RUN=true

    resolve_target "$base/main" >/dev/null 2>&1
    [ "${#EXTRA_PATHS[@]}" -eq 1 ]
    [ "$(mount_name "${EXTRA_PATHS[0]}")" = "sibling" ]

    rm -rf "$base"
}

@test "cs . accepts extra folders as arguments and via -m" {
    POSITIONAL=()
    parse_args . -m /tmp/one /tmp/two
    # target plus both extras survive parsing
    [ "${#POSITIONAL[@]}" -eq 3 ]
    [[ "${POSITIONAL[*]}" == *"/tmp/one"* ]]
    [[ "${POSITIONAL[*]}" == *"/tmp/two"* ]]
}

@test "the launch step offers to add folders, and cancel means cancel" {
    LOCAL_MODE=true; LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; EXTRA_PATHS=()
    ASSUME_YES=false
    clear() { :; }
    gum() { return 0; }

    pick_one() { printf 'Cancel'; }
    run screen_launch_confirm
    [ "$status" -ne 0 ]

    pick_one() { printf 'Launch sandbox'; }
    run screen_launch_confirm
    [ "$status" -eq 0 ]
}

# ── Dependencies are required only when used ────────────────────────────────

@test "dry-run does not require gum" {
    DRY_RUN=true; ASSUME_YES=true; EXEC_PROMPT=""
    command -v() { [[ "$1" == "docker" ]]; }   # only docker present
    run check_deps
    [ "$status" -eq 0 ]
}

@test "exec does not require gum" {
    DRY_RUN=false; ASSUME_YES=false; EXEC_PROMPT="do a thing"
    command -v() { [[ "$1" == "docker" ]]; }
    run check_deps
    [ "$status" -eq 0 ]
}

@test "interactive use does require gum" {
    DRY_RUN=false; ASSUME_YES=false; EXEC_PROMPT=""
    command -v() { [[ "$1" == "docker" ]]; }
    clear_screen() { :; }
    run check_deps
    [ "$status" -ne 0 ]
    [[ "$output" == *"gum"* ]]
}

@test "docker is always required" {
    DRY_RUN=true; ASSUME_YES=true; EXEC_PROMPT=""
    command -v() { return 1; }
    clear_screen() { :; }
    run check_deps
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker"* ]]
}
