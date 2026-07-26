#!/usr/bin/env bash
set -euo pipefail

# Smoke tests for the built sandbox image.
#
# These assert the properties that have actually broken before, so they are
# worth the seconds they cost:
#   - the agent CLIs exist and run
#   - codex does NOT resolve into ~/.codex (that path is a host bind mount)
#   - the entrypoint never changes permissions on bind-mounted host files
#
# Usage: IMAGE=claude-sandbox ./tests/image-smoke.sh

IMAGE="${IMAGE:-claude-sandbox}"

PASS=0
FAIL=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        ok "$name"
    else
        bad "$name — expected '$expected', got '$actual'"
    fi
}

in_image() {
    docker run --rm --entrypoint bash "$IMAGE" -c "$1" 2>&1
}

echo ""
echo "  Image smoke tests: $IMAGE"
echo ""

if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "  Image '$IMAGE' not found. Run: make build" >&2
    exit 1
fi

# ── Toolchain ────────────────────────────────────────────────────────────────
check "node is v24 (v20 is EOL)"   "v24"          "$(in_image 'node --version')"
check "claude code installed"      "Claude Code"  "$(in_image 'claude --version')"
check "codex installed"            "codex"        "$(in_image 'codex --version')"
check "gh installed"               "gh version"   "$(in_image 'gh --version | head -1')"
check "aws cli installed"          "aws-cli/2"    "$(in_image 'aws --version')"
check "uv installed"               "uv "          "$(in_image 'uv --version')"
check "ripgrep installed"          "ripgrep"      "$(in_image 'rg --version | head -1')"
check "tmux installed"             "tmux"         "$(in_image 'tmux -V')"

# ── Python: a real venv, not a patched system interpreter ────────────────────
check "python resolves to the venv" "/opt/venv/bin/python" "$(in_image 'which python')"
check "pip resolves to the venv"    "/opt/venv/bin/pip"    "$(in_image 'which pip')"
check "pip install needs no flags"  "OK"                   "$(in_image 'pip install --quiet six >/dev/null 2>&1 && echo OK')"
check "boto3 preinstalled"          "OK"                   "$(in_image 'python -c "import boto3, requests" && echo OK')"
check "EXTERNALLY-MANAGED intact"   "OK"                   "$(in_image 'ls /usr/lib/python3.*/EXTERNALLY-MANAGED >/dev/null 2>&1 && echo OK || echo MISSING')"

# ── Codex must not live under ~/.codex (that gets bind-mounted from the host) ─
codex_target="$(in_image 'readlink -f "$(which codex)"')"
if [[ "$codex_target" == *"/home/node/.codex/"* ]]; then
    bad "codex binary is outside ~/.codex — resolves to $codex_target (host mount would shadow it)"
else
    ok "codex binary is outside ~/.codex ($codex_target)"
fi

# The real test: mount something over ~/.codex like a launch does, and see if
# codex still runs.
fake_codex="$(mktemp -d)"
mkdir -p "$fake_codex/packages/standalone"
echo "not-a-linux-binary" > "$fake_codex/packages/standalone/current"
if docker run --rm -v "$fake_codex:/home/node/.codex" --entrypoint bash "$IMAGE" \
    -c 'codex --version' >/dev/null 2>&1; then
    ok "codex survives a host ~/.codex bind mount"
else
    bad "codex breaks when the host ~/.codex is mounted"
fi
rm -rf "$fake_codex"

# ── Host files must never be chmod'd by the container ────────────────────────
workdir="$(mktemp -d)"
mkdir -p "$workdir/repo/.git"
echo "secret" > "$workdir/repo/.env"
chmod 600 "$workdir/repo/.env"

before="$(stat -f '%Lp' "$workdir/repo/.env" 2>/dev/null || stat -c '%a' "$workdir/repo/.env")"
docker run --rm -v "$workdir/repo:/home/node/workspace/repo" --entrypoint bash "$IMAGE" -c '
    sudo chmod 777 /home/node/workspace 2>/dev/null || true
    sudo chmod 1777 /tmp 2>/dev/null || true
    touch /home/node/workspace/CLAUDE.md
    touch /home/node/workspace/repo/.probe && rm /home/node/workspace/repo/.probe
' >/dev/null 2>&1
after="$(stat -f '%Lp' "$workdir/repo/.env" 2>/dev/null || stat -c '%a' "$workdir/repo/.env")"

if [[ "$before" == "$after" ]]; then
    ok "host file permissions preserved (.env stayed $after)"
else
    bad "host file permissions changed: $before -> $after"
fi
rm -rf "$workdir"

# ── Headless exec: stdout must carry agent output and nothing else ───────────
execdir="$(mktemp -d)"
mkdir -p "$execdir/repo" "$execdir/fake"
cat > "$execdir/fake/claude" <<'FAKE'
#!/bin/bash
echo "AGENT_OUTPUT_MARKER"
FAKE
chmod +x "$execdir/fake/claude"
(
    cd "$execdir/repo"
    git init -q
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
) >/dev/null 2>&1

exec_out=$(docker run --rm -i \
    -e "SANDBOX_EXEC=test prompt" -e "SANDBOX_AGENT=claude" -e "LOCAL_MODE=1" \
    -v "$execdir/repo:/home/node/workspace/repo" \
    -v "$execdir/fake/claude:/opt/venv/bin/claude:ro" \
    "$IMAGE" --local repo 2>/dev/null)

if [[ "$exec_out" == "AGENT_OUTPUT_MARKER" ]]; then
    ok "headless exec puts only agent output on stdout"
else
    bad "headless exec stdout polluted: $(echo "$exec_out" | head -3 | tr '\n' '|')"
fi
rm -rf "$execdir"

# ── Worktree mode: git must be fully functional inside the container ─────────
wtdir="$(cd "$(mktemp -d)" && pwd -P)"   # resolve symlinked /var on macOS
(
    cd "$wtdir"
    mkdir main
    cd main
    git init -q
    echo hi > a.txt
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm init
    git worktree add -q "$wtdir/tree" -b agent-work
) >/dev/null 2>&1

wt_out=$(docker run --rm \
    -v "$wtdir/tree:/home/node/workspace/proj" \
    -v "$wtdir/main/.git:$wtdir/main/.git" \
    --entrypoint bash "$IMAGE" -c '
        cd /home/node/workspace/proj
        echo new > b.txt
        git add -A
        git -c user.email=t@t -c user.name=t commit -qm "from sandbox" >/dev/null
        git branch --show-current
    ' 2>&1)

if [[ "$wt_out" == "agent-work" ]]; then
    # The commit must be visible from the main repo, and main must stay clean
    host_log=$(git -C "$wtdir/main" log --oneline agent-work 2>/dev/null | head -1)
    host_dirty=$(git -C "$wtdir/main" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$host_log" == *"from sandbox"* && "$host_dirty" == "0" ]]; then
        ok "worktree mode: commits reach the host repo, checkout stays clean"
    else
        bad "worktree mode: host repo did not receive the commit (log='$host_log', dirty=$host_dirty)"
    fi
else
    bad "worktree mode: git broken inside container ($wt_out)"
fi
git -C "$wtdir/main" worktree remove --force "$wtdir/tree" >/dev/null 2>&1 || true
rm -rf "$wtdir"

# ── Entrypoint sanity ────────────────────────────────────────────────────────
check "entrypoint is executable"  "OK" "$(in_image 'test -x /entrypoint.sh && echo OK')"
check "entrypoint parses"         "OK" "$(in_image 'bash -n /entrypoint.sh && echo OK')"
check "auto-git installed"        "OK" "$(in_image 'test -x /usr/local/bin/auto-git && echo OK')"
check "auto-git parses"           "OK" "$(in_image 'bash -n /usr/local/bin/auto-git && echo OK')"
check "sandbox context present"   "OK" "$(in_image 'test -f /usr/local/share/sandbox-context.md && echo OK')"
check "zsh is the shell"          "/bin/zsh" "$(in_image 'echo $SHELL')"
check "sandbox aliases loaded"    "dangerously" "$(in_image 'grep -h dangerously ~/.zshrc.sandbox | head -1')"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
echo ""
[[ "$FAIL" -eq 0 ]]
