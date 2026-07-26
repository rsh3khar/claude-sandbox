#!/usr/bin/env bats
#
# Every reachable branch of the interactive flow, exercised with stubbed
# pickers. The point is coverage of the *transitions*: each menu entry must be
# handled, and no entry — including cancellation — may abort the CLI.
#
# The map these cover:
#
#   main
#    ├─ screen_welcome ......... (no GitHub? warn and continue, never exit)
#    ├─ detect_current_repo .... yes -> local mode + mounts | no -> source select
#    ├─ screen_source_select
#    │    ├─ Recent workspace -> screen_recent_workspaces -> pick | ← Back
#    │    ├─ Local directory  -> screen_local_path -> prompt_extra_mounts
#    │    ├─ GitHub repository -> github mode
#    │    └─ ← Back / cancel  -> main menu
#    ├─ prompt_extra_mounts (loop)
#    │    ├─ Pick from my repos -> offer_repo_mounts
#    │    ├─ Browse any folder  -> browse_directories
#    │    ├─ Type a path        -> ask_text
#    │    └─ Done / cancel      -> exit loop
#    └─ screen_main_menu (loop)
#         Launch | Select Repo/Dir | Switch mode | Switch Account
#         | Running Sandboxes | Rebuild Image | Exit | cancel -> loop

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    source "$REPO_ROOT/claude-sandbox"

    # Neutralise everything that would touch the terminal, docker or network.
    WORKDIR="$(mktemp -d)"
    LOCAL_PATH="$WORKDIR"
    SELECTED_REPO="work"
    LOCAL_MODE=true
    EXTRA_PATHS=()
    REPO_ROOTS=""
    SNAPSHOT=false

    clear() { :; }
    sleep() { :; }
    gum() { return 0; }                 # gum confirm -> yes
    docker() { return 0; }
    gh() { return 1; }
    refresh_gh_user() { GH_USER=""; GH_USER_DATA=""; }
    animate_spinner() { :; }
    launch_sandbox() { LAUNCHED=1; }
    offer_repo_mounts() { VISITED_REPO_MOUNTS=1; }
    browse_directories() { printf ''; }
}

teardown() {
    rm -rf "$WORKDIR"
}

# Feed a sequence of answers to pick_one, one per call.
#
# The queue lives in a file rather than a variable: callers use
# `choice=$(pick_one ...)`, which runs the stub in a subshell, so an in-memory
# counter would never advance and the stub would answer the same thing forever —
# turning any menu loop into an infinite one.
stub_choices() {
    STUB_FILE="$WORKDIR/choices"
    printf '%s\n' "$@" > "$STUB_FILE"

    pick_one() {
        local v=""
        if [[ -s "$STUB_FILE" ]]; then
            v=$(head -n 1 "$STUB_FILE")
            tail -n +2 "$STUB_FILE" > "${STUB_FILE}.rest" && mv "${STUB_FILE}.rest" "$STUB_FILE"
        fi
        printf '%s' "$v"
    }
}

# ── screen_source_select: every entry plus cancellation ──────────────────────

@test "source select: Local directory routes to the local path screen" {
    screen_local_path() { VISITED_LOCAL_PATH=1; }
    stub_choices "Local directory"
    VISITED_LOCAL_PATH=0
    screen_source_select
    [ "$LOCAL_MODE" = true ]
    [ "$VISITED_LOCAL_PATH" = 1 ]
}

@test "source select: GitHub repository switches out of local mode" {
    screen_repo_select() { VISITED_REPO_SELECT=1; }
    stub_choices "GitHub repository"
    screen_source_select
    [ "$LOCAL_MODE" = false ]
}

@test "source select: Recent workspace is reachable" {
    RECENT_FILE="$WORKDIR/recent"
    printf '%s\t\n' "$WORKDIR" > "$RECENT_FILE"
    screen_recent_workspaces() { VISITED_RECENT=1; }
    stub_choices "Recent workspace"
    VISITED_RECENT=0
    screen_source_select
    [ "$VISITED_RECENT" = 1 ]
}

@test "source select: Back returns without choosing anything" {
    stub_choices "← Back"
    run screen_source_select
    [ "$status" -eq 0 ]
}

@test "source select: cancellation returns without choosing anything" {
    stub_choices ""
    run screen_source_select
    [ "$status" -eq 0 ]
}

# ── prompt_extra_mounts: every entry plus cancellation ───────────────────────

@test "extra mounts: Done exits the loop" {
    stub_choices "Done"
    run prompt_extra_mounts
    [ "$status" -eq 0 ]
}

@test "extra mounts: cancellation exits the loop" {
    stub_choices ""
    run prompt_extra_mounts
    [ "$status" -eq 0 ]
}

@test "extra mounts: Pick from my repos then Done" {
    stub_choices "Pick from my repos" "Done"
    VISITED_REPO_MOUNTS=0
    prompt_extra_mounts
    [ "$VISITED_REPO_MOUNTS" = 1 ]
}

@test "extra mounts: Browse folders then Done" {
    stub_choices "Browse folders" "Done"
    run prompt_extra_mounts
    [ "$status" -eq 0 ]
}

@test "extra mounts: Type a path then Done" {
    stub_choices "Type a path" "Done"
    ask_text() { printf ''; }
    run prompt_extra_mounts
    [ "$status" -eq 0 ]
}

@test "extra mounts: an unrecognised answer exits rather than looping forever" {
    stub_choices "something unexpected"
    run timeout 10 bash -c "
        source '$REPO_ROOT/claude-sandbox'
        pick_one() { printf 'something unexpected'; }
        gum() { return 0; }
        LOCAL_PATH=/tmp; EXTRA_PATHS=()
        prompt_extra_mounts
    "
    [ "$status" -eq 0 ]
}

# ── screen_recent_workspaces ─────────────────────────────────────────────────

@test "recent workspaces: Back leaves state untouched" {
    RECENT_FILE="$WORKDIR/recent"
    mkdir -p "$WORKDIR/proj"
    printf '%s\t\n' "$WORKDIR/proj" > "$RECENT_FILE"
    stub_choices "← Back"

    LOCAL_PATH="untouched"
    screen_recent_workspaces
    [ "$LOCAL_PATH" = "untouched" ]
}

@test "recent workspaces: selecting one restores it" {
    RECENT_FILE="$WORKDIR/recent"
    mkdir -p "$WORKDIR/proj"
    printf '%s\t\n' "$WORKDIR/proj" > "$RECENT_FILE"
    stub_choices "proj"

    screen_recent_workspaces
    [ "$LOCAL_PATH" = "$WORKDIR/proj" ]
    [ "$SELECTED_REPO" = "proj" ]
}

@test "recent workspaces: an empty list falls back to the local path screen" {
    screen_local_path() { VISITED_LOCAL_PATH=1; }
    RECENT_FILE="$WORKDIR/none"
    VISITED_LOCAL_PATH=0
    stub_choices ""
    screen_recent_workspaces
    [ "$VISITED_LOCAL_PATH" = 1 ]
}

# ── screen_switch_account ────────────────────────────────────────────────────

@test "switch account: Back returns cleanly" {
    get_all_accounts() { printf 'alice\nbob\n'; }
    stub_choices "← Back"
    run screen_switch_account
    [ "$status" -eq 0 ]
}

@test "switch account: no accounts is handled" {
    get_all_accounts() { printf ''; }
    read() { :; }
    run screen_switch_account
    [ "$status" -eq 0 ]
}

# ── screen_welcome: GitHub is optional ───────────────────────────────────────

@test "not being signed in is reported where GitHub is actually needed" {
    # The welcome screen no longer checks GitHub; repo selection does, which is
    # the first point where it matters.
    refresh_gh_user() { GH_USER=""; }
    GH_USER=""; GH_LOOKUP_DONE=""
    read() { :; }

    run screen_repo_select
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not signed in to GitHub"* ]]
    [[ "$output" == *"local folder"* ]]
}

# ── The whole set of documented menu entries is handled ──────────────────────

@test "every main menu entry is dispatched" {
    # Each label must appear in the case statement that follows the menu, or
    # picking it would silently do nothing.
    local body
    body=$(declare -f screen_main_menu)

    for entry in "Launch Sandbox" "Select Repository" "Select Directory" \
                 "Switch to GitHub" "Switch to Local" "Switch Account" \
                 "Running Sandboxes" "Rebuild Image" "Exit"; do
        [[ "$body" == *"$entry"* ]] || {
            echo "main menu offers '$entry' but does not handle it"
            false
        }
    done
}

# ── The declined-current-folder flow ─────────────────────────────────────────
# Saying "no" to "Use this repository?" used to land on a prompt pre-filled
# with "." — the folder just declined — which Enter then accepted.

@test "local path: nothing is chosen implicitly, Back leaves local mode" {
    stub_choices "← Back"
    LOCAL_PATH=""
    LOCAL_MODE=true

    screen_local_path
    [ "$LOCAL_MODE" = false ]
    [ -z "$LOCAL_PATH" ]
}

@test "local path: repo list is offered and selecting one sets the workspace" {
    prompt_extra_mounts() { :; }

    local base="$WORKDIR/tree"
    mkdir -p "$base/group/chosen/.git" "$base/group/other/.git"
    cd "$base/group/other"

    # first answer picks the "Pick from my repos" entry, second picks the repo
    stub_choices "Pick from my repos (2)" "$(cd "$base/group/chosen" && pwd)"
    LOCAL_PATH=""
    REPO_ROOTS=""

    screen_local_path
    [[ "$LOCAL_PATH" == *"/chosen" ]]
    [ "$SELECTED_REPO" = "chosen" ]
}

@test "local path: typing a bad path re-prompts instead of accepting the cwd" {
    prompt_extra_mounts() { :; }
    ask_text() { printf '/definitely/not/here'; }

    # Type a path (fails) -> Back. The cwd must never be silently selected.
    stub_choices "Type a path" "← Back"
    LOCAL_PATH=""

    screen_local_path
    [ -z "$LOCAL_PATH" ]
    [ "$LOCAL_MODE" = false ]
}

@test "local path: the current folder is an explicit choice, not a default" {
    prompt_extra_mounts() { :; }

    local base="$WORKDIR/cur"
    mkdir -p "$base/.git"
    cd "$base"

    stub_choices "Use current folder ($(basename "$base"))"
    LOCAL_PATH=""

    screen_local_path
    [ "$LOCAL_PATH" = "$(cd "$base" && pwd)" ]
}

# ── Startup does no work it doesn't need ─────────────────────────────────────

@test "welcome draws the logo without touching the network or waiting" {
    local called="$WORKDIR/gh-called"
    : > "$called"
    gh() { echo x >> "$called"; return 1; }

    # A timeout is the assertion that it does not block: the old version waited
    # on Enter here.
    run timeout 5 bash -c "
        source '$REPO_ROOT/claude-sandbox'
        gh() { echo x >> '$called'; return 1; }
        clear() { :; }
        screen_welcome
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"dangerously-skip-permissions"* ]]
    [ ! -s "$called" ]
}

@test "the GitHub identity is fetched once, and only when asked for" {
    local calls="$WORKDIR/gh-calls"
    : > "$calls"
    refresh_gh_user() { echo x >> "$calls"; GH_USER="someone"; }

    GH_USER=""
    GH_LOOKUP_DONE=""
    ensure_gh_user
    ensure_gh_user
    ensure_gh_user
    [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ]
}

@test "a local session never looks up the GitHub identity" {
    local calls="$WORKDIR/gh-calls"
    : > "$calls"
    refresh_gh_user() { echo x >> "$calls"; }
    screen_local_path() { :; }

    stub_choices "Local directory"
    screen_source_select

    [ ! -s "$calls" ]
}

@test "the first screen keeps the startup logo, later screens clear" {
    # screen_welcome draws the full logo; if the next screen cleared, it would
    # flash and vanish. Also guards against screen_header recursing into
    # itself, which an over-eager refactor once did.
    local log="$WORKDIR/clears"
    : > "$log"
    clear() { echo cleared >> "$log"; }

    FIRST_SCREEN=true
    screen_header >/dev/null
    [ ! -s "$log" ]                       # first screen: no clear

    screen_header >/dev/null
    [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ]

    screen_header >/dev/null
    [ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ]
}

@test "screen_header terminates" {
    FIRST_SCREEN=false
    clear() { :; }
    run timeout 5 bash -c "
        source '$REPO_ROOT/claude-sandbox'
        clear() { :; }
        FIRST_SCREEN=false
        screen_header
    "
    [ "$status" -eq 0 ]
}
