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
C_WARN=$'\033[38;2;234;179;8m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# Spinner for long-running tasks
# Usage: run_with_spinner "message" command arg1 arg2 ...
run_with_spinner() {
    local msg="$1"
    shift
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0

    "$@" >/dev/null 2>&1 &
    local pid=$!

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_ACCENT}${frames[$i]}${NC} ${C_DIM}${msg}${NC}  "
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done
    tput cnorm 2>/dev/null || true

    wait "$pid"
    local exit_code=$?
    printf "\r%60s\r" ""
    return $exit_code
}

echo ""
echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX${NC}"
echo ""

# Open up container-local permissions — it's a sandbox, no friction.
# SKIP host mounts: ~/.claude, ~/.aws, ~/.config/gh, ~/.codex, ~/.agents, ~/.ssh-host
sudo chmod -R 777 /home/node/workspace 2>/dev/null || true
sudo chmod -R 777 /usr/local/share/playwright 2>/dev/null || true
sudo chmod -R 777 /tmp 2>/dev/null || true

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

# Inject sandbox context for Claude Code and Codex
# Place it in the workspace root (parent of repo) so it's picked up
# without touching any repo files. Claude Code walks parent dirs for CLAUDE.md.
SANDBOX_CTX="/usr/local/share/sandbox-context.md"
if [[ -f "$SANDBOX_CTX" ]]; then
    cp "$SANDBOX_CTX" ~/workspace/CLAUDE.md
    cp "$SANDBOX_CTX" ~/workspace/AGENTS.md
fi

# Install & configure Playwright + Chromium (only when browser is enabled)
if [[ -n "${ENABLE_BROWSER:-}" ]]; then
    echo -e "${C_DIM}Setting up browser...${NC}"

    # System dependencies (always needed — container is fresh each time, but fast)
    if run_with_spinner "Installing system dependencies" sudo npx -y playwright install-deps chromium; then
        echo -e "  ${C_SUCCESS}✓${NC} System dependencies"
    else
        echo -e "  ${C_WARN}⚠${NC} System dependencies failed"
    fi

    # Chromium binary (cached in Docker volume — skips download if already present)
    browser_path="${PLAYWRIGHT_BROWSERS_PATH:-/usr/local/share/playwright}"
    if ls "$browser_path"/chromium-*/chrome-linux/chrome >/dev/null 2>&1; then
        echo -e "  ${C_SUCCESS}✓${NC} Chromium ${C_DIM}(cached)${NC}"
    else
        if run_with_spinner "Downloading Chromium (first time only)" bash -c "sudo npx -y playwright install chromium"; then
            echo -e "  ${C_SUCCESS}✓${NC} Chromium installed"
        else
            echo -e "  ${C_WARN}⚠${NC} Chromium install failed"
        fi
    fi

    # Python Playwright client (small, always needed since container is fresh)
    if run_with_spinner "Setting up Python Playwright" pip3 install --break-system-packages playwright; then
        echo -e "  ${C_SUCCESS}✓${NC} Python Playwright"
    else
        echo -e "  ${C_WARN}⚠${NC} Python Playwright failed"
    fi

    # Install MCP server globally so it shares the same browser
    if run_with_spinner "Setting up Playwright MCP" sudo npm install -g @playwright/mcp@latest; then
        echo -e "  ${C_SUCCESS}✓${NC} Playwright MCP"
    else
        echo -e "  ${C_WARN}⚠${NC} Playwright MCP failed"
    fi

    echo ""

    # Write project-level .mcp.json so Claude Code auto-discovers it
    # Exclude from git so auto-git doesn't commit it
    echo '.mcp.json' >> .git/info/exclude 2>/dev/null || true

    if [ -f .mcp.json ]; then
        # Repo already has .mcp.json — merge playwright into it
        python3 -c "
import json
with open('.mcp.json') as f: cfg = json.load(f)
cfg.setdefault('mcpServers', {})
cfg['mcpServers']['playwright'] = {'command':'playwright-mcp','args':['--headless','--browser','chromium']}
with open('.mcp.json','w') as f: json.dump(cfg, f, indent=2)
" 2>/dev/null || true
    else
        cat > .mcp.json << 'MCPEOF'
{
  "mcpServers": {
    "playwright": {
      "command": "playwright-mcp",
      "args": ["--headless", "--browser", "chromium"]
    }
  }
}
MCPEOF
    fi
fi

# Update CLI tools if requested
if [[ -n "${UPDATE_TOOLS:-}" ]]; then
    echo -e "${C_DIM}Checking for updates...${NC}"

    # Claude Code
    CLAUDE_CURRENT=$(claude --version 2>/dev/null || echo "")
    CLAUDE_LATEST=$(curl -fsSL https://claude.ai/install.sh 2>/dev/null | grep -o 'VERSION="[^"]*"' | head -1 | cut -d'"' -f2 || echo "")
    if [[ -n "$CLAUDE_CURRENT" && "$CLAUDE_CURRENT" == *"$CLAUDE_LATEST"* && -n "$CLAUDE_LATEST" ]]; then
        echo -e "  ${C_SUCCESS}✓${NC} Claude Code ${C_DIM}(${CLAUDE_CURRENT}, latest)${NC}"
    else
        if run_with_spinner "Updating Claude Code" bash -c "curl -fsSL https://claude.ai/install.sh | bash"; then
            echo -e "  ${C_SUCCESS}✓${NC} Claude Code updated"
        else
            echo -e "  ${C_WARN}⚠${NC} Claude Code update failed"
        fi
    fi

    # Codex
    CODEX_CURRENT=$(npm list -g @openai/codex --json 2>/dev/null | jq -r '.dependencies["@openai/codex"].version // empty' 2>/dev/null)
    CODEX_LATEST=$(npm view @openai/codex@latest version 2>/dev/null || echo "")
    if [[ -n "$CODEX_CURRENT" && "$CODEX_CURRENT" == "$CODEX_LATEST" ]]; then
        echo -e "  ${C_SUCCESS}✓${NC} Codex ${C_DIM}(${CODEX_CURRENT}, latest)${NC}"
    else
        if run_with_spinner "Updating Codex" sudo npm install -g @openai/codex@latest; then
            echo -e "  ${C_SUCCESS}✓${NC} Codex updated"
        else
            echo -e "  ${C_WARN}⚠${NC} Codex update failed"
        fi
    fi

    # Playwright (only if browser enabled)
    if [[ -n "${ENABLE_BROWSER:-}" ]]; then
        PW_CURRENT=$(npx playwright --version 2>/dev/null || echo "")
        PW_LATEST=$(npm view playwright@latest version 2>/dev/null || echo "")
        if [[ -n "$PW_CURRENT" && "$PW_CURRENT" == *"$PW_LATEST"* && -n "$PW_LATEST" ]]; then
            echo -e "  ${C_SUCCESS}✓${NC} Playwright ${C_DIM}(${PW_CURRENT}, latest)${NC}"
        else
            if run_with_spinner "Updating Playwright" sudo npx -y playwright install chromium; then
                echo -e "  ${C_SUCCESS}✓${NC} Playwright updated"
            else
                echo -e "  ${C_WARN}⚠${NC} Playwright update failed"
            fi
        fi
    fi

    echo ""
fi

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

# Cleanup trap
cleanup() {
    echo ""
    echo -e "${C_DIM}Shutting down...${NC}"
    cd ~/workspace/"$REPO_NAME" 2>/dev/null || exit 0

    # Check for changes — skip if auto-git disabled
    if [[ -z "${DISABLE_AUTO_GIT:-}" ]] && [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        echo -e "${C_DIM}Saving final changes...${NC}"
        git add -A
        git commit -m "wip: session end" --no-verify 2>/dev/null || true
        if [[ -z "$LOCAL_MODE" ]]; then
            git push 2>/dev/null || true
        fi
    fi
    echo -e "${C_DIM}Goodbye!${NC}"
}
trap cleanup EXIT

# Start auto-git with repo path (pass LOCAL_MODE) unless disabled
if [[ -n "${DISABLE_AUTO_GIT:-}" ]]; then
    echo -e "${C_DIM}Auto-save: disabled${NC}"
else
    LOCAL_MODE="$LOCAL_MODE" auto-git 60 ~/workspace/"$REPO_NAME" > /tmp/auto-git.log 2>&1 &
    disown $!
fi

echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${C_TEXT}Repo:${NC}       ${C_ACCENT}${REPO_NAME}${NC}"
echo -e "  ${C_TEXT}Branch:${NC}     ${C_ACCENT}$(git branch --show-current)${NC}"
if [[ -n "$LOCAL_MODE" ]]; then
    echo -e "  ${C_TEXT}Mode:${NC}       ${C_WARN}Local${NC} ${C_DIM}(no push)${NC}"
fi
if [[ -n "${DISABLE_AUTO_GIT:-}" ]]; then
    echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_WARN}disabled${NC}"
else
    if [[ -n "$LOCAL_MODE" ]]; then
        echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every 60s (local commits only)${NC}"
    else
        echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every 60s (when changes exist)${NC}"
    fi
fi
echo ""
echo -e "  ${C_DIM}Type ${C_TEXT}c${C_DIM} or ${C_TEXT}claude${C_DIM} for Claude Code${NC}"
echo -e "  ${C_DIM}Type ${C_TEXT}x${C_DIM} or ${C_TEXT}codex${C_DIM} for OpenAI Codex${NC}"
if [[ -n "${ENABLE_BROWSER:-}" ]]; then
    echo -e "  ${C_DIM}Browser: ${C_TEXT}Chromium (headless)${C_DIM} via Playwright${NC}"
else
    echo -e "  ${C_DIM}Browser: ${C_TEXT}disabled${C_DIM} (restart with browser option to enable)${NC}"
fi
echo -e "  ${C_DIM}Screenshots: save to ${C_TEXT}~/.claude/screenshots/${C_DIM} on host${NC}"

# Skills summary
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CODEX_SKILLS_DIR="$HOME/.agents/skills"
CLAUDE_SKILL_COUNT=0
CODEX_SKILL_COUNT=0

if [[ -d "$CLAUDE_SKILLS_DIR" ]]; then
    CLAUDE_SKILL_COUNT=$(ls -1d "$CLAUDE_SKILLS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
fi
if [[ -d "$CODEX_SKILLS_DIR" ]]; then
    CODEX_SKILL_COUNT=$(ls -1d "$CODEX_SKILLS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
fi

TOTAL_SKILLS=$((CLAUDE_SKILL_COUNT + CODEX_SKILL_COUNT))

if [[ "$TOTAL_SKILLS" -gt 0 ]]; then
    SKILL_PARTS=""
    if [[ "$CLAUDE_SKILL_COUNT" -gt 0 ]]; then
        CLAUDE_NAMES=$(ls -1d "$CLAUDE_SKILLS_DIR"/*/ 2>/dev/null | xargs -I{} basename {} | head -4 | paste -sd ", " -)
        SKILL_PARTS="Claude: ${CLAUDE_SKILL_COUNT} (${CLAUDE_NAMES})"
    fi
    if [[ "$CODEX_SKILL_COUNT" -gt 0 ]]; then
        CODEX_NAMES=$(ls -1d "$CODEX_SKILLS_DIR"/*/ 2>/dev/null | xargs -I{} basename {} | head -4 | paste -sd ", " -)
        if [[ -n "$SKILL_PARTS" ]]; then
            SKILL_PARTS="${SKILL_PARTS} | Codex: ${CODEX_SKILL_COUNT} (${CODEX_NAMES})"
        else
            SKILL_PARTS="Codex: ${CODEX_SKILL_COUNT} (${CODEX_NAMES})"
        fi
    fi
    echo -e "  ${C_DIM}Skills: ${C_TEXT}${SKILL_PARTS}${NC}"
else
    echo ""
    echo -e "  ${C_ACCENT}No skills installed.${NC}"
    echo -e "  ${C_DIM}Skills add capabilities like web testing, code review, deployment, etc.${NC}"
    echo -e "  ${C_DIM}Browse: ${C_TEXT}https://skills.sh${NC}"
    echo -e "  ${C_DIM}Claude:  ${C_TEXT}npx skills add <owner/repo>${NC}"
    echo -e "  ${C_DIM}Codex:   ${C_TEXT}skill-installer install <name> from <source>${NC}"
    echo ""
    read -p "  Install popular skills now? [y/N]: " INSTALL_SKILLS
    if [[ "$INSTALL_SKILLS" == "y" || "$INSTALL_SKILLS" == "Y" ]]; then
        echo ""
        npx -y skills add anthropics/claude-code-skills 2>/dev/null \
            && echo -e "  ${C_SUCCESS}✓${NC} Claude skills installed" \
            || echo -e "  ${C_ACCENT}⚠${NC} Claude skills install failed"
    fi
fi

echo ""
echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""

exec zsh
