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
