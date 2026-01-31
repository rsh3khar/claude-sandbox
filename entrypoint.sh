#!/bin/bash
set -e

# Check for local mode flag
LOCAL_MODE="${LOCAL_MODE:-}"
if [[ "$1" == "--local" ]]; then
    LOCAL_MODE=1
    shift
    REPO_NAME="$1"
    shift || true
else
    GIT_URL="$1"
    shift || true

    if [[ -z "$GIT_URL" ]]; then
        echo "Usage: docker run ... <git-url>"
        echo "       docker run ... --local <repo-name>"
        exit 1
    fi
fi

# Colors
C_DIM=$'\033[38;2;120;113;108m'
C_TEXT=$'\033[38;2;214;211;209m'
C_ACCENT=$'\033[38;2;217;119;6m'
C_SUCCESS=$'\033[38;2;34;197;94m'
NC=$'\033[0m'
BOLD=$'\033[1m'

echo ""
echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX${NC}"
echo ""

# Fix SSH socket permissions (Docker Desktop or OrbStack)
if [[ -S "/run/host-services/ssh-auth.sock" ]]; then
    sudo chmod 666 /run/host-services/ssh-auth.sock 2>/dev/null || true
fi
if [[ -S "/tmp/ssh-agent.sock" ]]; then
    sudo chmod 666 /tmp/ssh-agent.sock 2>/dev/null || true
fi

# SSH setup
mkdir -p ~/.ssh
cp ~/.ssh-host/known_hosts ~/.ssh/ 2>/dev/null || true
cat > ~/.ssh/config << 'SSHEOF'
Host *
    StrictHostKeyChecking accept-new
    AddKeysToAgent yes
SSHEOF
chmod 700 ~/.ssh
chmod 600 ~/.ssh/* 2>/dev/null || true

# Resolve broken skill symlinks (they point to ~/.agents which isn't mounted)
resolve_skill_symlinks() {
    local skills_dir="$HOME/.claude/skills"
    [[ ! -d "$skills_dir" ]] && return

    for link in "$skills_dir"/*; do
        [[ ! -L "$link" ]] && continue

        local name=$(basename "$link")

        # Check if symlink target exists
        if [[ ! -e "$link" ]]; then
            # Try plugins cache
            local plugin_path=$(find "$HOME/.claude/plugins" -type d -name "$name" -path "*/skills/*" 2>/dev/null | head -1)
            if [[ -n "$plugin_path" && -d "$plugin_path" ]]; then
                rm "$link"
                cp -r "$plugin_path" "$skills_dir/$name"
                echo -e "${C_DIM}Resolved skill: ${name}${NC}"
            fi
        fi
    done
}

resolve_skill_symlinks

if [[ -n "$LOCAL_MODE" ]]; then
    # Local mode: repo is already mounted
    echo -e "${C_DIM}Using local repo: ${REPO_NAME}${NC}"
    cd ~/workspace/"$REPO_NAME"
else
    # GitHub mode: clone
    REPO_NAME=$(basename "$GIT_URL" .git)
    echo -e "${C_DIM}Cloning ${REPO_NAME}...${NC}"
    git clone --quiet "$GIT_URL" ~/workspace/"$REPO_NAME"
    cd ~/workspace/"$REPO_NAME"
fi

# Configure git identity
[[ -n "${GIT_USER_NAME:-}" ]] && git config user.name "$GIT_USER_NAME"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config user.email "$GIT_USER_EMAIL"

# Function to show branch menu
show_branch_menu() {
    CURRENT=$(git branch --show-current)

    if [[ -n "$LOCAL_MODE" ]]; then
        # Local mode: use local branches
        ALL_BRANCHES=$(git branch --format='%(refname:short)' 2>/dev/null | sort -u)
        # If no branches (no commits yet), use current branch name
        if [[ -z "$ALL_BRANCHES" && -n "$CURRENT" ]]; then
            ALL_BRANCHES="$CURRENT"
        fi
    else
        # GitHub mode: use remote branches
        ALL_BRANCHES=$(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//' | sort -u)
    fi

    # Count sandbox branches
    SANDBOX_BRANCHES=$(echo "$ALL_BRANCHES" | grep -E "^sandbox-" || true)
    if [[ -n "$SANDBOX_BRANCHES" ]]; then
        SANDBOX_COUNT=$(echo "$SANDBOX_BRANCHES" | wc -l | tr -d ' ')
    else
        SANDBOX_COUNT=0
    fi

    echo ""
    echo -e "${C_TEXT}${BOLD}Select a branch${NC}"
    echo ""

    # Store branches in array for selection
    BRANCH_ARRAY=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && BRANCH_ARRAY+=("$b")
    done <<< "$ALL_BRANCHES"

    # Display numbered list
    for i in "${!BRANCH_ARRAY[@]}"; do
        b="${BRANCH_ARRAY[$i]}"
        num=$((i + 1))

        if [[ "$b" =~ ^sandbox- ]]; then
            ICON="${C_DIM}◇${NC}"
        else
            ICON="${C_SUCCESS}●${NC}"
        fi

        if [[ "$b" == "$CURRENT" ]]; then
            echo -e "  ${C_ACCENT}${num})${NC} ${ICON} ${C_TEXT}$b${NC} ${C_SUCCESS}(current)${NC}"
        else
            echo -e "  ${C_DIM}${num})${NC} ${ICON} ${C_DIM}$b${NC}"
        fi
    done

    echo ""
    echo -e "  ${C_ACCENT}n)${NC} ${C_TEXT}New branch${NC} ${C_DIM}(name it yourself)${NC}"
    echo -e "  ${C_ACCENT}q)${NC} ${C_TEXT}Quick branch${NC} ${C_DIM}(auto: sandbox-timestamp)${NC}"

    if [[ "$SANDBOX_COUNT" -gt 0 ]]; then
        if [[ -n "$LOCAL_MODE" ]]; then
            echo -e "  ${C_DIM}d)${NC} ${C_DIM}Delete sandbox branches${NC} ${C_DIM}(${SANDBOX_COUNT} local)${NC}"
        else
            echo -e "  ${C_DIM}d)${NC} ${C_DIM}Delete sandbox branches${NC} ${C_DIM}(${SANDBOX_COUNT} found)${NC}"
        fi
    fi

    echo ""
    read -p "▸ Choice [1]: " CHOICE
    CHOICE=${CHOICE:-1}

    # Handle delete
    if [[ "$CHOICE" == "d" || "$CHOICE" == "D" ]]; then
        if [[ "$SANDBOX_COUNT" -gt 0 ]]; then
            echo ""
            echo -e "${C_DIM}Sandbox branches to delete:${NC}"
            echo "$SANDBOX_BRANCHES" | while read -r b; do
                [[ -n "$b" ]] && echo -e "  ${C_DIM}• $b${NC}"
            done
            echo ""
            read -p "▸ Delete all? [y/N]: " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                echo ""
                if [[ -n "$LOCAL_MODE" ]]; then
                    # Delete local branches
                    echo "$SANDBOX_BRANCHES" | while read -r b; do
                        [[ -n "$b" ]] && git branch -D "$b" 2>/dev/null && echo -e "  ${C_SUCCESS}✓${NC} Deleted local $b"
                    done
                else
                    # Delete remote branches
                    echo "$SANDBOX_BRANCHES" | while read -r b; do
                        [[ -n "$b" ]] && git push origin --delete "$b" 2>/dev/null && echo -e "  ${C_SUCCESS}✓${NC} Deleted $b"
                    done
                fi
            fi
        fi
        # Refresh and show menu again
        if [[ -z "$LOCAL_MODE" ]]; then
            git fetch --prune --quiet 2>/dev/null || true
        fi
        show_branch_menu
        return
    fi

    # Handle new branch
    if [[ "$CHOICE" == "n" || "$CHOICE" == "N" || "$CHOICE" == "q" || "$CHOICE" == "Q" ]]; then
        echo ""
        echo -e "${C_DIM}Base off which branch?${NC}"

        for i in "${!BRANCH_ARRAY[@]}"; do
            b="${BRANCH_ARRAY[$i]}"
            num=$((i + 1))
            if [[ "$b" == "main" || "$b" == "master" ]]; then
                echo -e "  ${C_ACCENT}${num})${NC} ${C_TEXT}$b${NC} ${C_DIM}(default)${NC}"
            else
                echo -e "  ${C_DIM}${num})${NC} ${C_DIM}$b${NC}"
            fi
        done
        echo ""

        # Find default base
        DEFAULT_BASE=""
        for b in "${BRANCH_ARRAY[@]}"; do
            if [[ "$b" == "main" || "$b" == "master" ]]; then
                DEFAULT_BASE="$b"
                break
            fi
        done
        [[ -z "$DEFAULT_BASE" ]] && DEFAULT_BASE="${BRANCH_ARRAY[0]}"

        read -p "▸ Base [${DEFAULT_BASE}]: " BASE_CHOICE

        if [[ -z "$BASE_CHOICE" ]]; then
            BASE_BRANCH="$DEFAULT_BASE"
        elif [[ "$BASE_CHOICE" =~ ^[0-9]+$ ]]; then
            idx=$((BASE_CHOICE - 1))
            BASE_BRANCH="${BRANCH_ARRAY[$idx]:-$DEFAULT_BASE}"
        else
            BASE_BRANCH="$BASE_CHOICE"
        fi

        git checkout "$BASE_BRANCH" --quiet 2>/dev/null || true

        if [[ "$CHOICE" == "q" || "$CHOICE" == "Q" ]]; then
            TIMESTAMP=$(date +%Y%m%d-%H%M%S)
            BRANCH_NAME="sandbox-${TIMESTAMP}"
        else
            echo ""
            echo -e "${C_DIM}What are you working on?${NC}"
            read -p "▸ " FEATURE_DESC
            if [[ -n "$FEATURE_DESC" ]]; then
                BRANCH_NAME=$(echo "$FEATURE_DESC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
                [[ ! "$BRANCH_NAME" =~ ^(feature|fix|chore|docs)/ ]] && BRANCH_NAME="feature/${BRANCH_NAME}"
            fi
        fi

        if [[ -n "$BRANCH_NAME" ]]; then
            echo ""
            git checkout -b "$BRANCH_NAME" --quiet
            if [[ -z "$LOCAL_MODE" ]]; then
                git push -u origin "$BRANCH_NAME" --quiet 2>/dev/null || true
            fi
            echo -e "${C_SUCCESS}✓${NC} Created ${C_ACCENT}${BRANCH_NAME}${NC} ${C_DIM}from ${BASE_BRANCH}${NC}"
        fi
        return
    fi

    # Handle number selection
    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        idx=$((CHOICE - 1))
        SELECTED="${BRANCH_ARRAY[$idx]}"

        if [[ -n "$SELECTED" && "$SELECTED" != "$CURRENT" ]]; then
            git checkout "$SELECTED" --quiet
            echo ""
            echo -e "${C_SUCCESS}✓${NC} Switched to ${C_ACCENT}${SELECTED}${NC}"
        else
            echo ""
            echo -e "${C_SUCCESS}✓${NC} Staying on ${C_ACCENT}${CURRENT}${NC}"
        fi
    fi
}

# Run branch menu
show_branch_menu

echo ""

# Set up CLAUDE.md with sandbox context (AFTER branch selection to avoid checkout conflicts)
SANDBOX_TEMPLATE="/usr/local/share/sandbox-context.md"
SANDBOX_MARKER="<!-- END SANDBOX CONTEXT -->"

HAD_CLAUDE_MD=false
if [[ -f "CLAUDE.md" ]]; then
    HAD_CLAUDE_MD=true
    # Repo has existing CLAUDE.md - prepend sandbox context if not already there
    if ! grep -q "$SANDBOX_MARKER" CLAUDE.md 2>/dev/null; then
        cp CLAUDE.md CLAUDE.md.original
        cat "$SANDBOX_TEMPLATE" CLAUDE.md.original > CLAUDE.md
        echo -e "${C_DIM}Added sandbox context to CLAUDE.md${NC}"
    fi
else
    cp "$SANDBOX_TEMPLATE" CLAUDE.md
    echo -e "${C_DIM}Created CLAUDE.md with sandbox context${NC}"
fi
export HAD_CLAUDE_MD

# Cleanup trap
cleanup() {
    echo ""
    echo -e "${C_DIM}Shutting down...${NC}"
    cd ~/workspace/"$REPO_NAME" 2>/dev/null || exit 0

    # Check for changes (excluding sandbox files)
    if [[ -n $(git status --porcelain -- ':!CLAUDE.md' ':!CLAUDE.md.original' 2>/dev/null) ]]; then
        echo -e "${C_DIM}Saving final changes...${NC}"
        git add -A -- ':!CLAUDE.md' ':!CLAUDE.md.original'
        git commit -m "wip: session end" --no-verify 2>/dev/null || true
        if [[ -z "$LOCAL_MODE" ]]; then
            git push 2>/dev/null || true
        fi
    fi
    echo -e "${C_DIM}Goodbye!${NC}"
}
trap cleanup EXIT

# Start auto-git with repo path (pass LOCAL_MODE)
LOCAL_MODE="$LOCAL_MODE" auto-git 60 ~/workspace/"$REPO_NAME" > /tmp/auto-git.log 2>&1 &
disown $!

echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${C_TEXT}Repo:${NC}       ${C_ACCENT}${REPO_NAME}${NC}"
echo -e "  ${C_TEXT}Branch:${NC}     ${C_ACCENT}$(git branch --show-current)${NC}"
if [[ -n "$LOCAL_MODE" ]]; then
    echo -e "  ${C_TEXT}Mode:${NC}       ${C_WARN}Local${NC} ${C_DIM}(no push)${NC}"
    echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every 60s (local commits only)${NC}"
else
    echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every 60s (when changes exist)${NC}"
fi
echo ""
echo -e "  ${C_DIM}Type ${C_TEXT}c${C_DIM} or ${C_TEXT}claude${C_DIM} for Claude Code${NC}"
echo -e "  ${C_DIM}Type ${C_TEXT}x${C_DIM} or ${C_TEXT}codex${C_DIM} for OpenAI Codex${NC}"
echo -e "  ${C_DIM}Screenshots: save to ${C_TEXT}~/.claude/screenshots/${C_DIM} on host${NC}"
echo ""
echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""

exec zsh
