#!/bin/bash
set -e

GIT_URL="$1"
shift || true

if [[ -z "$GIT_URL" ]]; then
    echo "Usage: docker run ... <git-url>"
    exit 1
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

# Fix SSH socket permissions
if [[ -S "/run/host-services/ssh-auth.sock" ]]; then
    sudo chmod 666 /run/host-services/ssh-auth.sock 2>/dev/null || true
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

# Extract repo name from URL
REPO_NAME=$(basename "$GIT_URL" .git)

# Clone
echo -e "${C_DIM}Cloning ${REPO_NAME}...${NC}"
git clone --quiet "$GIT_URL" ~/workspace/"$REPO_NAME"
cd ~/workspace/"$REPO_NAME"

# Configure git identity
[[ -n "${GIT_USER_NAME:-}" ]] && git config user.name "$GIT_USER_NAME"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config user.email "$GIT_USER_EMAIL"

# Create sandbox context file (gitignored)
if ! grep -q "^\.claude-sandbox$" .gitignore 2>/dev/null; then
    echo ".claude-sandbox" >> .gitignore
fi

cat > .claude-sandbox << 'SANDBOXEOF'
# Claude Sandbox Context

You are running inside **Claude Sandbox** - an isolated Docker container.

## Key Facts
- You have `--dangerously-skip-permissions` enabled (no approval prompts)
- Changes auto-commit to GitHub every 60 seconds
- Container is destroyed on exit - your host machine is safe
- Network is shared with host (all ports work)

## What You Can Do
- Run any command without asking for permission
- Install packages, run builds, start servers
- Make breaking changes - the sandbox is disposable

## Paths
- Repo: ~/workspace/<repo-name>
- Shared config: ~/.claude (mounted from host)

## Screenshots / Images
Clipboard doesn't bridge host ↔ container. When user mentions a screenshot or image:
1. Check `/home/node/.claude/screenshots/` for the **most recently modified file**
2. Use `ls -t ~/.claude/screenshots/ | head -1` to find the latest
3. Read and analyze that image

User saves from host: `shot` (alias) or `pngpaste ~/.claude/screenshots/$(date +%s).png`

## Auto-Save
- Changes commit every 60s (when changes exist)
- On exit: final commit "wip: session end"
- Logs: `/tmp/auto-git.log`
SANDBOXEOF

# Function to show branch menu
show_branch_menu() {
    CURRENT=$(git branch --show-current)
    REMOTE_BRANCHES=$(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//' | sort -u)

    # Count sandbox branches
    SANDBOX_BRANCHES=$(echo "$REMOTE_BRANCHES" | grep -E "^sandbox-" || true)
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
    done <<< "$REMOTE_BRANCHES"

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
            echo -e "  ${C_ACCENT}${num})${NC} ${ICON} ${C_TEXT}$b${NC} ${C_DIM}(current)${NC}"
        else
            echo -e "  ${C_DIM}${num})${NC} ${ICON} ${C_DIM}$b${NC}"
        fi
    done

    echo ""
    echo -e "  ${C_ACCENT}n)${NC} ${C_TEXT}New branch${NC} ${C_DIM}(name it yourself)${NC}"
    echo -e "  ${C_ACCENT}q)${NC} ${C_TEXT}Quick branch${NC} ${C_DIM}(auto: sandbox-timestamp)${NC}"

    if [[ "$SANDBOX_COUNT" -gt 0 ]]; then
        echo -e "  ${C_DIM}d)${NC} ${C_DIM}Delete sandbox branches${NC} ${C_DIM}(${SANDBOX_COUNT} found)${NC}"
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
                echo "$SANDBOX_BRANCHES" | while read -r b; do
                    [[ -n "$b" ]] && git push origin --delete "$b" 2>/dev/null && echo -e "  ${C_SUCCESS}✓${NC} Deleted $b"
                done
            fi
        fi
        # Refresh and show menu again
        git fetch --prune --quiet 2>/dev/null || true
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
            git push -u origin "$BRANCH_NAME" --quiet 2>/dev/null || true
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

# Cleanup trap
cleanup() {
    echo ""
    echo -e "${C_DIM}Shutting down...${NC}"
    cd ~/workspace/"$REPO_NAME" 2>/dev/null || exit 0
    if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        echo -e "${C_DIM}Saving final changes...${NC}"
        git add -A
        git commit -m "wip: session end" --no-verify 2>/dev/null || true
        git push 2>/dev/null || true
    fi
    echo -e "${C_DIM}Goodbye!${NC}"
}
trap cleanup EXIT

# Start auto-git with repo path
auto-git 60 ~/workspace/"$REPO_NAME" > /tmp/auto-git.log 2>&1 &
disown $!

echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${C_TEXT}Repo:${NC}       ${C_ACCENT}${REPO_NAME}${NC}"
echo -e "  ${C_TEXT}Branch:${NC}     ${C_ACCENT}$(git branch --show-current)${NC}"
echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every 60s (when changes exist)${NC}"
echo ""
echo -e "  ${C_DIM}Type ${C_TEXT}claude${C_DIM} to start Claude Code${NC}"
echo ""
echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""

exec zsh
