#!/bin/bash
# Auto-git: commits (and pushes) every N seconds, but only when there is
# something to save and the repo is in a state where committing is safe.
#
# Usage: auto-git [interval_seconds] [repo_path]
# Env:   LOCAL_MODE=1  commit locally, never push

INTERVAL=${1:-60}
REPO_PATH=${2:-$HOME/workspace/repo}

cd "$REPO_PATH" || exit 1

log() { echo "[auto-git] $*"; }

log "Watching for changes every ${INTERVAL}s"
log "Branch: $(git branch --show-current)"
if [[ -n "$LOCAL_MODE" ]]; then
    log "Mode: LOCAL (no push)"
else
    log "Mode: REMOTE (push enabled)"
fi

# Committing mid-merge or mid-rebase resolves it with whatever the working
# tree happens to contain, which is a great way to silently destroy a
# conflict resolution the agent is halfway through.
operation_in_progress() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    [[ -e "$git_dir/MERGE_HEAD" ]] && { echo "merge"; return 0; }
    [[ -e "$git_dir/CHERRY_PICK_HEAD" ]] && { echo "cherry-pick"; return 0; }
    [[ -e "$git_dir/REVERT_HEAD" ]] && { echo "revert"; return 0; }
    [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] && { echo "rebase"; return 0; }
    [[ -e "$git_dir/BISECT_LOG" ]] && { echo "bisect"; return 0; }
    return 1
}

COMMIT_COUNT=0
SKIP_LOGGED=""

while true; do
    sleep "$INTERVAL"

    # Nothing to do
    [[ -z $(git status --porcelain 2>/dev/null) ]] && continue

    # Detached HEAD: a commit here is unreachable once the branch moves on
    if ! git symbolic-ref --quiet HEAD >/dev/null 2>&1; then
        [[ "$SKIP_LOGGED" == "detached" ]] || log "Skipping: detached HEAD (checkout a branch to resume auto-save)"
        SKIP_LOGGED="detached"
        continue
    fi

    if op=$(operation_in_progress); then
        [[ "$SKIP_LOGGED" == "$op" ]] || log "Skipping: ${op} in progress"
        SKIP_LOGGED="$op"
        continue
    fi

    SKIP_LOGGED=""
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    COMMIT_COUNT=$((COMMIT_COUNT + 1))

    git add -A

    if git commit -m "auto-save #${COMMIT_COUNT}: ${TIMESTAMP}" --no-verify >/dev/null 2>&1; then
        if [[ -n "$LOCAL_MODE" ]]; then
            log "Committed locally (#${COMMIT_COUNT}) at ${TIMESTAMP}"
        elif git push >/dev/null 2>&1; then
            log "Committed and pushed (#${COMMIT_COUNT}) at ${TIMESTAMP}"
        else
            log "Committed locally (#${COMMIT_COUNT}) — push failed, will retry"
        fi
    else
        COMMIT_COUNT=$((COMMIT_COUNT - 1))
    fi
done
