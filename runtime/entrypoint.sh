#!/bin/bash
set -euo pipefail

# Claude Sandbox container entrypoint.
#
# Usage: entrypoint.sh <git-url>
#        entrypoint.sh --local <repo-name>
#
# Environment:
#   LOCAL_MODE            non-empty -> repo is bind-mounted, never pushed
#   DISABLE_AUTO_GIT      non-empty -> no auto-commit daemon
#   AUTO_GIT_INTERVAL     seconds between auto-commits (default 60)
#   ENABLE_BROWSER        non-empty -> install Playwright + Chromium
#   UPDATE_TOOLS          non-empty -> update agent CLIs on start
#   SANDBOX_BRANCH        branch to check out (skips the interactive menu)
#   SKIP_BRANCH_MENU      non-empty -> stay on the current branch
#   GIT_USER_NAME/EMAIL   commit identity forwarded from the host

# npx asks "Ok to proceed?" when a package is missing AND stdin is a terminal.
# Inside a command substitution that prompt is invisible, so the session simply
# appears frozen. NPM_CONFIG_YES answers it, everywhere.
#
# Deliberately NOT CI=1. That also stops npx prompting, but CI is the standard
# signal for "no colour, non-interactive", and Claude Code and Codex both
# honour it — setting it stripped the colour out of the agent TUI.
export NPM_CONFIG_YES=true

LOCAL_MODE="${LOCAL_MODE:-}"
if [[ "${1:-}" == "--local" ]]; then
    LOCAL_MODE=1
    shift
    REPO_NAME="${1:-}"
    shift || true
    if [[ -z "$REPO_NAME" ]]; then
        echo "Usage: entrypoint.sh --local <repo-name>" >&2
        exit 1
    fi
else
    GIT_URL="${1:-}"
    shift || true

    if [[ -z "$GIT_URL" ]]; then
        echo "Usage: entrypoint.sh <git-url>" >&2
        echo "       entrypoint.sh --local <repo-name>" >&2
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
# Run a step with a spinner. Output is captured rather than discarded: a step
# that fails prints its last lines instead of a bare warning, and the elapsed
# time is shown so a slow step is visibly making progress rather than hung.
LAST_STEP_LOG=""
run_with_spinner() {
    local msg="$1"
    shift
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0 elapsed=0

    LAST_STEP_LOG=$(mktemp)
    "$@" > "$LAST_STEP_LOG" 2>&1 &
    local pid=$!
    local start=$SECONDS

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( SECONDS - start ))
        if [[ "$elapsed" -ge 5 ]]; then
            printf "\r  %s%s%s %s%s (%ss)%s  " "$C_ACCENT" "${frames[$i]}" "$NC" "$C_DIM" "$msg" "$elapsed" "$NC"
        else
            printf "\r  %s%s%s %s%s%s  " "$C_ACCENT" "${frames[$i]}" "$NC" "$C_DIM" "$msg" "$NC"
        fi
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done
    tput cnorm 2>/dev/null || true

    local exit_code=0
    wait "$pid" || exit_code=$?
    printf "\r%70s\r" ""

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "  ${C_WARN}⚠${NC} ${msg} failed ${C_DIM}(exit ${exit_code})${NC}"
        sed 's/^/      /' "$LAST_STEP_LOG" | tail -6
    fi
    return $exit_code
}

# In headless mode, keep fd 3 as the real stdout and send all setup chatter to
# stderr, so `cs exec` output is exactly the agent's answer and nothing else.
if [[ -n "${SANDBOX_EXEC:-}" ]]; then
    exec 3>&1 1>&2
fi

echo ""
echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX${NC}"
echo ""

# Container-local paths only. NEVER chmod -R anything under ~/workspace: in
# local mode those are bind mounts, and permission changes propagate straight
# back to the user's real files on the host.
sudo chmod 777 /home/node/workspace 2>/dev/null || true
sudo chmod 1777 /tmp 2>/dev/null || true
if [[ -d /usr/local/share/playwright ]]; then
    sudo chown -R node:node /usr/local/share/playwright 2>/dev/null || true
fi

# Fix SSH socket permissions (Docker Desktop or OrbStack)
if [[ -S "/run/host-services/ssh-auth.sock" ]]; then
    sudo chmod 666 /run/host-services/ssh-auth.sock 2>/dev/null || true
fi
if [[ -S "/tmp/ssh-agent.sock" ]]; then
    sudo chmod 666 /tmp/ssh-agent.sock 2>/dev/null || true
fi

# SSH setup — host keys are never copied in; the forwarded agent does the signing.
mkdir -p ~/.ssh
cp ~/.ssh-host/known_hosts ~/.ssh/ 2>/dev/null || true
cat > ~/.ssh/config << 'SSHEOF'
Host *
    StrictHostKeyChecking accept-new
    AddKeysToAgent yes
SSHEOF
chmod 700 ~/.ssh
chmod 600 ~/.ssh/* 2>/dev/null || true

# Resolve broken skill symlinks (they point to host paths that aren't mounted)
resolve_skill_symlinks() {
    local skills_dir="$HOME/.claude/skills"
    [[ ! -d "$skills_dir" ]] && return 0

    local link name plugin_path
    for link in "$skills_dir"/*; do
        [[ ! -L "$link" ]] && continue
        [[ -e "$link" ]] && continue

        name=$(basename "$link")
        plugin_path=$(find "$HOME/.claude/plugins" -type d -name "$name" -path "*/skills/*" 2>/dev/null | head -1)
        if [[ -n "$plugin_path" && -d "$plugin_path" ]]; then
            rm "$link"
            cp -r "$plugin_path" "$skills_dir/$name"
            echo -e "${C_DIM}Resolved skill: ${name}${NC}"
        fi
    done
}

resolve_skill_symlinks

if [[ -n "$LOCAL_MODE" ]]; then
    echo -e "${C_DIM}Using local repo: ${REPO_NAME}${NC}"
    cd ~/workspace/"$REPO_NAME"
else
    REPO_NAME=$(basename "$GIT_URL" .git)
    run_with_spinner "Cloning ${REPO_NAME}" git clone "$GIT_URL" "$HOME/workspace/$REPO_NAME" \
        || { echo -e "  ${C_WARN}⚠${NC} clone failed"; exit 1; }
    cd ~/workspace/"$REPO_NAME"
fi

# Git identity from host
[[ -n "${GIT_USER_NAME:-}" ]] && git config user.name "$GIT_USER_NAME"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config user.email "$GIT_USER_EMAIL"

# Sandbox context for the agents. Written to the workspace root (the parent of
# the repo) so no repo file is ever touched — Claude Code and Codex both walk
# parent directories looking for CLAUDE.md / AGENTS.md.
# The static file can only describe features conditionally ("when auto-save is
# enabled..."), which leaves the agent guessing which branch applies — and it
# guessed wrong, telling users their work was being auto-committed when it was
# not. So the real state of THIS session is generated and put first.
write_session_facts() {
    local out="$1"

    {
        echo "# This session"
        echo ""
        echo "These are the actual settings in force right now. Where this"
        echo "disagrees with anything below, this section is correct."
        echo ""

        if [[ -n "${SANDBOX_WORKTREE:-}" ]]; then
            echo "- **Worktree mode.** \`${REPO_NAME}\` is a git worktree on a scratch"
            echo "  branch, not the user's working tree. Their checkout is untouched;"
            echo "  commit normally and they merge the branch afterwards."
        elif [[ -n "$LOCAL_MODE" ]]; then
            echo "- **Local mode.** \`${REPO_NAME}\` is bind-mounted from the user's"
            echo "  machine: edits and deletions are immediate and real. Nothing is"
            echo "  pushed anywhere."
        else
            echo "- **Cloned repo.** \`${REPO_NAME}\` lives inside this container. If the"
            echo "  container is destroyed, anything unpushed is gone."
        fi

        if [[ -n "${DISABLE_AUTO_GIT:-}" ]]; then
            echo "- **Auto-save is OFF.** Nothing commits your work for you. Commit"
            echo "  deliberately, and never tell the user their work is being saved"
            echo "  automatically."
        else
            echo "- **Auto-save is ON**, every ${AUTO_GIT_INTERVAL:-60}s, and only when"
            echo "  there are changes. It watches \`${REPO_NAME}\` only — changes in"
            echo "  other mounted folders are yours to commit."
        fi

        if [[ -n "${ENABLE_BROWSER:-}" ]]; then
            echo "- **Headless Chromium is available** via Playwright and the"
            echo "  playwright MCP server."
        else
            echo "- **No browser.** Playwright is not installed; the user must"
            echo "  relaunch with --browser to get one."
        fi

        local extras=()
        local d name
        while IFS= read -r d; do
            [[ -n "$d" && "$d" != "$HOME/workspace/$REPO_NAME" ]] || continue
            name=$(basename "$d")
            if [[ -w "$d" ]]; then extras+=("$name"); else extras+=("$name (read-only)"); fi
        done < <(find "$HOME/workspace" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        if [[ ${#extras[@]} -gt 0 ]]; then
            echo "- **Also mounted:** $(printf '%s, ' "${extras[@]}" | sed 's/, $//')."
            echo "  Read-only ones cannot be modified — do not try."
        fi

        echo ""
        echo "---"
        echo ""
    } > "$out"
}

# Only the sections that apply. The full document is ~220 lines and most of it
# is conditional — Playwright docs with no browser, tmux orchestration nobody
# asked for — and it is read on every single launch.
CTX_DIR="/usr/local/share/sandbox-context"
if [[ -d "$CTX_DIR" ]]; then
    write_session_facts ~/workspace/CLAUDE.md
    cat "$CTX_DIR/core.md" >> ~/workspace/CLAUDE.md

    [[ -n "${SANDBOX_WORKTREE:-}" ]] && cat "$CTX_DIR/worktree.md" >> ~/workspace/CLAUDE.md
    [[ -n "${ENABLE_BROWSER:-}" ]] && cat "$CTX_DIR/browser.md" >> ~/workspace/CLAUDE.md

    # tmux orchestration only matters once there is more than one repo to split
    # work across, or the user asked for a browser-driven workflow.
    if [[ $(find "$HOME/workspace" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
        cat "$CTX_DIR/tmux.md" >> ~/workspace/CLAUDE.md
    fi

    if [[ -d "$HOME/.claude/skills" ]] || [[ -d "$HOME/.agents/skills" ]]; then
        cat "$CTX_DIR/skills.md" >> ~/workspace/CLAUDE.md
    fi

    cp ~/workspace/CLAUDE.md ~/workspace/AGENTS.md
fi

# ── Browser (opt-in) ─────────────────────────────────────────────────────────
if [[ -n "${ENABLE_BROWSER:-}" ]]; then
    echo -e "${C_DIM}Setting up browser...${NC}"

    if run_with_spinner "Installing system dependencies" sudo npx -y playwright install-deps chromium; then
        echo -e "  ${C_SUCCESS}✓${NC} System dependencies"
    else
        echo -e "  ${C_WARN}⚠${NC} System dependencies failed"
    fi

    browser_path="${PLAYWRIGHT_BROWSERS_PATH:-/usr/local/share/playwright}"
    if compgen -G "$browser_path/chromium-*/chrome-linux/chrome" >/dev/null 2>&1; then
        echo -e "  ${C_SUCCESS}✓${NC} Chromium ${C_DIM}(cached)${NC}"
    else
        if run_with_spinner "Downloading Chromium (first time only)" npx -y playwright install chromium; then
            echo -e "  ${C_SUCCESS}✓${NC} Chromium installed"
        else
            echo -e "  ${C_WARN}⚠${NC} Chromium install failed"
        fi
    fi

    if run_with_spinner "Setting up Python Playwright" pip install playwright; then
        echo -e "  ${C_SUCCESS}✓${NC} Python Playwright"
    else
        echo -e "  ${C_WARN}⚠${NC} Python Playwright failed"
    fi

    if run_with_spinner "Setting up Playwright MCP" sudo npm install -g @playwright/mcp@latest; then
        echo -e "  ${C_SUCCESS}✓${NC} Playwright MCP"
    else
        echo -e "  ${C_WARN}⚠${NC} Playwright MCP failed"
    fi

    echo ""

    # Project-level .mcp.json so Claude Code auto-discovers the browser.
    # Kept out of git so auto-save never commits it.
    grep -qxF '.mcp.json' .git/info/exclude 2>/dev/null || echo '.mcp.json' >> .git/info/exclude 2>/dev/null || true

    if [ -f .mcp.json ]; then
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

# ── Tool updates (opt-in) ────────────────────────────────────────────────────
if [[ -n "${UPDATE_TOOLS:-}" ]]; then
    echo -e "${C_DIM}Checking for updates...${NC}"

    CLAUDE_CURRENT=$(claude --version 2>/dev/null || echo "")
    if run_with_spinner "Updating Claude Code" timeout 300 bash -c "curl -fsSL https://claude.ai/install.sh | bash -s latest"; then
        CLAUDE_NEW=$(claude --version 2>/dev/null || echo "")
        if [[ -n "$CLAUDE_CURRENT" && "$CLAUDE_CURRENT" == "$CLAUDE_NEW" ]]; then
            echo -e "  ${C_SUCCESS}✓${NC} Claude Code ${C_DIM}(${CLAUDE_NEW:-unknown}, latest)${NC}"
        else
            echo -e "  ${C_SUCCESS}✓${NC} Claude Code updated ${C_DIM}(${CLAUDE_NEW:-unknown})${NC}"
        fi
    else
        echo -e "  ${C_WARN}⚠${NC} Claude Code update failed"
    fi

    # Same CODEX_HOME pinning as the image build — see Dockerfile.
    CODEX_CURRENT=$(codex --version 2>/dev/null || echo "")
    if run_with_spinner "Updating Codex" timeout 300 sudo env \
        CODEX_HOME=/opt/codex \
        CODEX_INSTALL_DIR=/usr/local/bin \
        CODEX_NON_INTERACTIVE=true \
        sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'; then
        sudo chmod -R a+rX /opt/codex 2>/dev/null || true
        CODEX_NEW=$(codex --version 2>/dev/null || echo "")
        if [[ -n "$CODEX_CURRENT" && "$CODEX_CURRENT" == "$CODEX_NEW" ]]; then
            echo -e "  ${C_SUCCESS}✓${NC} Codex ${C_DIM}(${CODEX_NEW:-unknown}, latest)${NC}"
        else
            echo -e "  ${C_SUCCESS}✓${NC} Codex updated ${C_DIM}(${CODEX_NEW:-unknown})${NC}"
        fi
    else
        echo -e "  ${C_WARN}⚠${NC} Codex update failed"
    fi

    if [[ -n "${ENABLE_BROWSER:-}" ]]; then
        echo -e "  ${C_DIM}checking Playwright version...${NC}"
        PW_CURRENT=$(timeout 60 npx -y playwright --version 2>/dev/null || echo "")
        PW_LATEST=$(timeout 30 npm view playwright@latest version 2>/dev/null || echo "")
        if [[ -n "$PW_CURRENT" && -n "$PW_LATEST" && "$PW_CURRENT" == *"$PW_LATEST"* ]]; then
            echo -e "  ${C_SUCCESS}✓${NC} Playwright ${C_DIM}(${PW_CURRENT}, latest)${NC}"
        else
            if run_with_spinner "Updating Playwright" npx -y playwright install chromium; then
                echo -e "  ${C_SUCCESS}✓${NC} Playwright updated"
            else
                echo -e "  ${C_WARN}⚠${NC} Playwright update failed"
            fi
        fi
    fi

    echo ""
fi

# ── Headless one-shot run ────────────────────────────────────────────────────
# No branch menu, no auto-save daemon, no shell: run the agent and exit with
# its status. Agent output goes to the real stdout via fd 3.
if [[ -n "${SANDBOX_EXEC:-}" ]]; then
    echo -e "${C_DIM}Running ${SANDBOX_AGENT:-claude} headlessly in ${REPO_NAME}...${NC}"
    case "${SANDBOX_AGENT:-claude}" in
        codex)
            exec codex exec --dangerously-bypass-approvals-and-sandbox "$SANDBOX_EXEC" >&3
            ;;
        *)
            exec claude --dangerously-skip-permissions -p "$SANDBOX_EXEC" >&3
            ;;
    esac
fi

# ── Branch selection ─────────────────────────────────────────────────────────
checkout_or_create() {
    local branch="$1"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch" --quiet
        echo -e "${C_SUCCESS}✓${NC} Switched to ${C_ACCENT}${branch}${NC}"
    elif [[ -z "$LOCAL_MODE" ]] && timeout 30 git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        git checkout -b "$branch" --track "origin/$branch" --quiet
        echo -e "${C_SUCCESS}✓${NC} Tracking ${C_ACCENT}${branch}${NC}"
    else
        git checkout -b "$branch" --quiet
        if [[ -z "$LOCAL_MODE" ]]; then
            run_with_spinner "Pushing ${branch}" timeout 60 git push -u origin "$branch" \
                || echo -e "  ${C_DIM}(not pushed — you can push later)${NC}"
        fi
        echo -e "${C_SUCCESS}✓${NC} Created ${C_ACCENT}${branch}${NC}"
    fi
}

show_branch_menu() {
    CURRENT=$(git branch --show-current)

    if [[ -n "$LOCAL_MODE" ]]; then
        ALL_BRANCHES=$(git branch --format='%(refname:short)' 2>/dev/null | sort -u)
        if [[ -z "$ALL_BRANCHES" && -n "$CURRENT" ]]; then
            ALL_BRANCHES="$CURRENT"
        fi
    else
        ALL_BRANCHES=$(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//' | sort -u)
    fi

    SANDBOX_BRANCHES=$(echo "$ALL_BRANCHES" | grep -E "^sandbox-" || true)
    if [[ -n "$SANDBOX_BRANCHES" ]]; then
        SANDBOX_COUNT=$(echo "$SANDBOX_BRANCHES" | wc -l | tr -d ' ')
    else
        SANDBOX_COUNT=0
    fi

    echo ""
    echo -e "${C_TEXT}${BOLD}Select a branch${NC}"
    echo ""

    BRANCH_ARRAY=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && BRANCH_ARRAY+=("$b")
    done <<< "$ALL_BRANCHES"

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
    read -r -p "▸ Choice [1]: " CHOICE
    CHOICE=${CHOICE:-1}

    if [[ "$CHOICE" == "d" || "$CHOICE" == "D" ]]; then
        if [[ "$SANDBOX_COUNT" -gt 0 ]]; then
            echo ""
            echo -e "${C_DIM}Sandbox branches to delete:${NC}"
            echo "$SANDBOX_BRANCHES" | while read -r b; do
                [[ -n "$b" ]] && echo -e "  ${C_DIM}• $b${NC}"
            done
            echo ""
            read -r -p "▸ Delete all? [y/N]: " CONFIRM
            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                echo ""
                if [[ -n "$LOCAL_MODE" ]]; then
                    echo "$SANDBOX_BRANCHES" | while read -r b; do
                        [[ -n "$b" && "$b" != "$CURRENT" ]] && git branch -D "$b" 2>/dev/null && echo -e "  ${C_SUCCESS}✓${NC} Deleted local $b"
                    done
                else
                    echo "$SANDBOX_BRANCHES" | while read -r b; do
                        [[ -n "$b" ]] || continue
                        if timeout 60 git push origin --delete "$b" >/dev/null 2>&1; then
                            echo -e "  ${C_SUCCESS}✓${NC} Deleted $b"
                        else
                            echo -e "  ${C_WARN}⚠${NC} Could not delete $b"
                        fi
                    done
                fi
            fi
        fi
        if [[ -z "$LOCAL_MODE" ]]; then
            run_with_spinner "Refreshing branches" timeout 60 git fetch --prune || true
        fi
        show_branch_menu
        return
    fi

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

        DEFAULT_BASE=""
        for b in "${BRANCH_ARRAY[@]}"; do
            if [[ "$b" == "main" || "$b" == "master" ]]; then
                DEFAULT_BASE="$b"
                break
            fi
        done
        [[ -z "$DEFAULT_BASE" ]] && DEFAULT_BASE="${BRANCH_ARRAY[0]}"

        read -r -p "▸ Base [${DEFAULT_BASE}]: " BASE_CHOICE

        if [[ -z "$BASE_CHOICE" ]]; then
            BASE_BRANCH="$DEFAULT_BASE"
        elif [[ "$BASE_CHOICE" =~ ^[0-9]+$ ]]; then
            idx=$((BASE_CHOICE - 1))
            BASE_BRANCH="${BRANCH_ARRAY[$idx]:-$DEFAULT_BASE}"
        else
            BASE_BRANCH="$BASE_CHOICE"
        fi

        git checkout "$BASE_BRANCH" --quiet 2>/dev/null || true

        BRANCH_NAME=""
        if [[ "$CHOICE" == "q" || "$CHOICE" == "Q" ]]; then
            BRANCH_NAME="sandbox-$(date +%Y%m%d-%H%M%S)"
        else
            echo ""
            echo -e "${C_DIM}What are you working on?${NC}"
            read -r -p "▸ " FEATURE_DESC
            if [[ -n "$FEATURE_DESC" ]]; then
                BRANCH_NAME=$(echo "$FEATURE_DESC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
                [[ ! "$BRANCH_NAME" =~ ^(feature|fix|chore|docs)/ ]] && BRANCH_NAME="feature/${BRANCH_NAME}"
            fi
        fi

        if [[ -n "$BRANCH_NAME" ]]; then
            echo ""
            git checkout -b "$BRANCH_NAME" --quiet
            if [[ -z "$LOCAL_MODE" ]]; then
                run_with_spinner "Pushing ${BRANCH_NAME}" timeout 60 git push -u origin "$BRANCH_NAME" \
                    || echo -e "  ${C_DIM}(not pushed — you can push later)${NC}"
            fi
            echo -e "${C_SUCCESS}✓${NC} Created ${C_ACCENT}${BRANCH_NAME}${NC} ${C_DIM}from ${BASE_BRANCH}${NC}"
        fi
        return
    fi

    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        idx=$((CHOICE - 1))
        SELECTED="${BRANCH_ARRAY[$idx]:-}"

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

if [[ -n "${SANDBOX_BRANCH:-}" ]]; then
    echo ""
    checkout_or_create "$SANDBOX_BRANCH"
elif [[ -n "${SKIP_BRANCH_MENU:-}" ]]; then
    echo ""
    echo -e "${C_DIM}Staying on branch ${C_ACCENT}$(git branch --show-current)${NC}"
else
    show_branch_menu
fi

echo ""

cleanup() {
    echo ""
    echo -e "${C_DIM}Shutting down...${NC}"
    cd ~/workspace/"$REPO_NAME" 2>/dev/null || exit 0

    if [[ -z "${DISABLE_AUTO_GIT:-}" ]] && [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        echo -e "${C_DIM}Saving final changes...${NC}"
        git add -A
        git commit -m "wip: session end" --no-verify 2>/dev/null || true
        if [[ -z "$LOCAL_MODE" ]]; then
            echo -e "${C_DIM}Pushing...${NC}"
            timeout 60 git push >/dev/null 2>&1 \
                && echo -e "${C_DIM}Pushed.${NC}" \
                || echo -e "${C_WARN}⚠${NC} Push failed — your commits are still local"
        fi
    fi
    echo -e "${C_DIM}Goodbye!${NC}"
}
trap cleanup EXIT

AUTO_GIT_INTERVAL="${AUTO_GIT_INTERVAL:-60}"
if [[ -n "${DISABLE_AUTO_GIT:-}" ]]; then
    echo -e "${C_DIM}Auto-save: disabled${NC}"
else
    LOCAL_MODE="$LOCAL_MODE" auto-git "$AUTO_GIT_INTERVAL" ~/workspace/"$REPO_NAME" > /tmp/auto-git.log 2>&1 &
    disown $!
fi

echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${C_TEXT}Repo:${NC}       ${C_ACCENT}${REPO_NAME}${NC}"
echo -e "  ${C_TEXT}Branch:${NC}     ${C_ACCENT}$(git branch --show-current)${NC}"

# Additional mounted folders: show each one's branch and dirty state, so the
# state of a multi-repo session is obvious at a glance.
EXTRA_DIRS=()
while IFS= read -r d; do
    [[ -n "$d" ]] && EXTRA_DIRS+=("$d")
done < <(find ~/workspace -mindepth 1 -maxdepth 1 -type d ! -name "$REPO_NAME" 2>/dev/null | sort)

if [[ ${#EXTRA_DIRS[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${C_TEXT}Also mounted:${NC}"
    for d in "${EXTRA_DIRS[@]}"; do
        name=$(basename "$d")
        if [[ -e "$d/.git" ]]; then
            br=$(git -C "$d" branch --show-current 2>/dev/null || echo "?")
            dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$dirty" != "0" ]]; then
                echo -e "    ${C_ACCENT}${name}${NC} ${C_DIM}(${br}, ${dirty} uncommitted)${NC}"
            else
                echo -e "    ${C_ACCENT}${name}${NC} ${C_DIM}(${br})${NC}"
            fi
        else
            writable="read-only"
            [[ -w "$d" ]] && writable="writable"
            echo -e "    ${C_ACCENT}${name}${NC} ${C_DIM}(no git, ${writable})${NC}"
        fi
    done
fi
if [[ -n "$LOCAL_MODE" ]]; then
    echo -e "  ${C_TEXT}Mode:${NC}       ${C_WARN}Local${NC} ${C_DIM}(no push)${NC}"
fi
if [[ -n "${DISABLE_AUTO_GIT:-}" ]]; then
    echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_WARN}disabled${NC}"
else
    if [[ -n "$LOCAL_MODE" ]]; then
        echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every ${AUTO_GIT_INTERVAL}s (local commits only)${NC}"
    else
        echo -e "  ${C_TEXT}Auto-save:${NC}  ${C_DIM}every ${AUTO_GIT_INTERVAL}s (when changes exist)${NC}"
    fi
fi
echo ""
echo -e "  ${C_DIM}Type ${C_TEXT}c${C_DIM} or ${C_TEXT}claude${C_DIM} for Claude Code${NC}"
echo -e "  ${C_DIM}Type ${C_TEXT}x${C_DIM} or ${C_TEXT}codex${C_DIM} for OpenAI Codex${NC}"
if [[ -n "${ENABLE_BROWSER:-}" ]]; then
    echo -e "  ${C_DIM}Browser: ${C_TEXT}Chromium (headless)${C_DIM} via Playwright${NC}"
else
    echo -e "  ${C_DIM}Browser: ${C_TEXT}disabled${C_DIM} (relaunch with --browser to enable)${NC}"
fi
echo -e "  ${C_DIM}Screenshots: save to ${C_TEXT}~/.claude/screenshots/${C_DIM} on host${NC}"

# ── Skills summary ───────────────────────────────────────────────────────────
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CODEX_SKILLS_DIR="$HOME/.agents/skills"

count_skills() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo 0; return; }
    find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}
skill_names() {
    local dir="$1"
    find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | head -4 | paste -sd ", " -
}

CLAUDE_SKILL_COUNT=$(count_skills "$CLAUDE_SKILLS_DIR")
CODEX_SKILL_COUNT=$(count_skills "$CODEX_SKILLS_DIR")
TOTAL_SKILLS=$((CLAUDE_SKILL_COUNT + CODEX_SKILL_COUNT))

if [[ "$TOTAL_SKILLS" -gt 0 ]]; then
    SKILL_PARTS=""
    if [[ "$CLAUDE_SKILL_COUNT" -gt 0 ]]; then
        SKILL_PARTS="Claude: ${CLAUDE_SKILL_COUNT} ($(skill_names "$CLAUDE_SKILLS_DIR"))"
    fi
    if [[ "$CODEX_SKILL_COUNT" -gt 0 ]]; then
        if [[ -n "$SKILL_PARTS" ]]; then
            SKILL_PARTS="${SKILL_PARTS} | Codex: ${CODEX_SKILL_COUNT} ($(skill_names "$CODEX_SKILLS_DIR"))"
        else
            SKILL_PARTS="Codex: ${CODEX_SKILL_COUNT} ($(skill_names "$CODEX_SKILLS_DIR"))"
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
    if [[ -t 0 ]]; then
        echo ""
        read -r -p "  Install popular skills now? [y/N]: " INSTALL_SKILLS
        if [[ "$INSTALL_SKILLS" == "y" || "$INSTALL_SKILLS" == "Y" ]]; then
            echo ""
            if run_with_spinner "Installing skills" npx -y skills add anthropics/claude-code-skills; then
                echo -e "  ${C_SUCCESS}✓${NC} Claude skills installed"
            fi
        fi
    fi
fi

echo ""
echo -e "${C_DIM}─────────────────────────────────────────${NC}"
echo ""

# Deliberately NOT `exec zsh`.
#
# exec replaces this process, which silently discarded the EXIT trap below —
# so the session-end commit never actually ran. Keeping bash as PID 1 means
# cleanup happens, and it gives us somewhere to notice that other shells are
# still attached before the container (and their work) disappears.
count_attached_shells() {
    # Shells from `cs attach` are separate zsh processes in this container.
    pgrep -x zsh 2>/dev/null | grep -c . || echo 0
}

while true; do
    zsh || true

    attached=$(count_attached_shells)
    [[ "$attached" -gt 0 ]] || break

    echo ""
    echo -e "  ${C_WARN}⚠${NC}  ${attached} other shell(s) still attached to this sandbox."
    echo -e "     ${C_DIM}Leaving destroys the container and kills them.${NC}"
    echo ""
    read -r -p "  Exit anyway? [y/N] " leave_anyway
    case "$leave_anyway" in
        [Yy]*) break ;;
        *) echo -e "  ${C_DIM}Staying. Type exit again when you are done.${NC}" ;;
    esac
done

cleanup
