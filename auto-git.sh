#!/bin/bash
# Auto-git: Commits and pushes every N seconds ONLY if there are changes
# Usage: auto-git [interval_seconds] [repo_path]
# Set LOCAL_MODE=1 env var to skip push

INTERVAL=${1:-60}
REPO_PATH=${2:-~/workspace/repo}

cd "$REPO_PATH" || exit 1

echo "[auto-git] Watching for changes every ${INTERVAL}s"
echo "[auto-git] Branch: $(git branch --show-current)"
if [[ -n "$LOCAL_MODE" ]]; then
    echo "[auto-git] Mode: LOCAL (no push)"
else
    echo "[auto-git] Mode: REMOTE (push enabled)"
fi
echo "[auto-git] Will only commit when there are actual changes"

COMMIT_COUNT=0

while true; do
    sleep "$INTERVAL"

    # Only commit if there are actual changes (excluding sandbox files)
    if [[ -n $(git status --porcelain -- ':!CLAUDE.md' ':!CLAUDE.md.original') ]]; then
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        COMMIT_COUNT=$((COMMIT_COUNT + 1))

        # Add everything except sandbox files
        git add -A -- ':!CLAUDE.md' ':!CLAUDE.md.original'

        if git commit -m "auto-save #${COMMIT_COUNT}: ${TIMESTAMP}" --no-verify 2>/dev/null; then
            if [[ -n "$LOCAL_MODE" ]]; then
                echo "[auto-git] Committed locally (#${COMMIT_COUNT}) at ${TIMESTAMP}"
            else
                if git push 2>/dev/null; then
                    echo "[auto-git] Committed and pushed (#${COMMIT_COUNT}) at ${TIMESTAMP}"
                else
                    echo "[auto-git] Committed locally (#${COMMIT_COUNT}) - push failed, will retry"
                fi
            fi
        fi
    fi
done
