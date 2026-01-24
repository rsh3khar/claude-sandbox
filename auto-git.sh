#!/bin/bash
# Auto-git: Commits and pushes every N seconds ONLY if there are changes
# Usage: auto-git [interval_seconds] [repo_path]

INTERVAL=${1:-60}
REPO_PATH=${2:-~/workspace/repo}

cd "$REPO_PATH" || exit 1

echo "[auto-git] Watching for changes every ${INTERVAL}s"
echo "[auto-git] Branch: $(git branch --show-current)"
echo "[auto-git] Will only commit when there are actual changes"

COMMIT_COUNT=0

while true; do
    sleep "$INTERVAL"

    # Only commit if there are actual changes (excluding CLAUDE.md which has sandbox context)
    if [[ -n $(git status --porcelain -- ':!CLAUDE.md') ]]; then
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        COMMIT_COUNT=$((COMMIT_COUNT + 1))

        # Add everything except CLAUDE.md (it has sandbox-injected content)
        git add -A -- ':!CLAUDE.md'

        if git commit -m "auto-save #${COMMIT_COUNT}: ${TIMESTAMP}" --no-verify 2>/dev/null; then
            if git push 2>/dev/null; then
                echo "[auto-git] Committed and pushed (#${COMMIT_COUNT}) at ${TIMESTAMP}"
            else
                echo "[auto-git] Committed locally (#${COMMIT_COUNT}) - push failed, will retry"
            fi
        fi
    fi
done
