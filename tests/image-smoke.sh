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

# GNU stat needs -c, BSD stat needs -f — and GNU's -f prints filesystem info to
# STDOUT while exiting 1, so a `-f || -c` fallback silently returns that noise
# with the real answer appended. Try the GNU form first: it fails cleanly on BSD.
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
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

before="$(file_mode "$workdir/repo/.env")"
docker run --rm -v "$workdir/repo:/home/node/workspace/repo" --entrypoint bash "$IMAGE" -c '
    sudo chmod 777 /home/node/workspace 2>/dev/null || true
    sudo chmod 1777 /tmp 2>/dev/null || true
    touch /home/node/workspace/CLAUDE.md 2>/dev/null || true
    touch /home/node/workspace/repo/.probe 2>/dev/null && rm /home/node/workspace/repo/.probe || true
' >/dev/null 2>&1 || true
after="$(file_mode "$workdir/repo/.env")"

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
wtdir="$(cd "$(mktemp -d)" && pwd -P)"

# Setup failures used to be swallowed by `>/dev/null 2>&1`, so a git error on a
# CI runner surfaced only as "exit code 128" with no clue which command. Capture
# the status explicitly rather than relying on `if !`, and print a marker so the
# log shows how far we got even if the shell dies anyway.
printf "  … worktree setup\n"
wt_rc=0
wt_setup=$( {
    cd "$wtdir" &&
    mkdir main &&
    cd main &&
    git init -q &&
    echo hi > a.txt &&
    git add -A &&
    git -c user.email=t@t -c user.name=t commit -qm init &&
    git worktree add -q "$wtdir/tree" -b agent-work
} 2>&1 ) || wt_rc=$?
printf "  … worktree setup rc=%s\n" "$wt_rc"

if [[ "$wt_rc" -ne 0 ]]; then
    bad "worktree setup failed (rc=$wt_rc): $(printf '%s' "$wt_setup" | tr '\n' ' ' | head -c 200)"
    rm -rf "$wtdir"
    wtdir=""
fi

if [[ -n "$wtdir" ]]; then
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
fi

# ── Injected context must describe THIS session, not features in general ────
ctxdir="$(mktemp -d)"; mkdir -p "$ctxdir/repo"
facts() {
    docker run --rm -e "LOCAL_MODE=1" "$@" -v "$ctxdir/repo:/home/node/workspace/repo" \
        --entrypoint bash "$IMAGE" -c '
            REPO_NAME=repo
            source <(sed -n "/^write_session_facts()/,/^}/p" /entrypoint.sh)
            write_session_facts /tmp/f && cat /tmp/f' 2>/dev/null
}
check "session facts: auto-save off is stated"  "Auto-save is OFF" "$(facts -e DISABLE_AUTO_GIT=1)"
check "session facts: auto-save on states interval" "every 120s"    "$(facts -e AUTO_GIT_INTERVAL=120)"
check "session facts: browser absence is stated" "No browser"       "$(facts -e DISABLE_AUTO_GIT=1)"
check "session facts: worktree mode is stated"  "Worktree mode"     "$(facts -e SANDBOX_WORKTREE=1)"
rm -rf "$ctxdir"

# ── Injected context includes only the sections that apply ──────────────────
ctx2="$(mktemp -d)"; mkdir -p "$ctx2/repo" "$ctx2/api"
injected() {
    docker run --rm -e LOCAL_MODE=1 -e DISABLE_AUTO_GIT=1 "$@" \
        -v "$ctx2/repo:/home/node/workspace/repo" \
        --entrypoint bash "$IMAGE" -c '
            REPO_NAME=repo LOCAL_MODE=1 DISABLE_AUTO_GIT=1
            eval "$(sed -n "/^write_session_facts()/,/^}/p" /entrypoint.sh)"
            eval "$(sed -n "/^CTX_DIR=/,/^fi$/p" /entrypoint.sh)"
            cat ~/workspace/CLAUDE.md' 2>/dev/null
}

plain=$(injected)
withbrowser=$(injected -e ENABLE_BROWSER=1)
withworktree=$(injected -e SANDBOX_WORKTREE=1)

case "$plain" in
    *"## Browser / UI Testing"*) bad "browser docs injected with no browser" ;;
    *)                           ok "browser docs omitted when there is no browser" ;;
esac
case "$withbrowser" in
    *"## Browser / UI Testing"*) ok "browser docs included when the browser is on" ;;
    *)                           bad "browser docs missing when the browser is on" ;;
esac
case "$withworktree" in
    *"Worktree Mode"*) ok "worktree docs included in worktree mode" ;;
    *)                 bad "worktree docs missing in worktree mode" ;;
esac
case "$plain" in
    *"Worktree Mode"*) bad "worktree docs injected outside worktree mode" ;;
    *)                 ok "worktree docs omitted outside worktree mode" ;;
esac
case "$plain" in
    *"## Parallel Agents with tmux"*) bad "tmux orchestration injected for a single-repo session" ;;
    *)                               ok "tmux docs omitted for a single-repo session" ;;
esac
rm -rf "$ctx2"

# ── A repo's own CLAUDE.md must survive untouched ───────────────────────────
# An early version wrote into the repo and polluted user projects.
ownmd="$(mktemp -d)"; mkdir -p "$ownmd/repo"
printf '# project rules\n' > "$ownmd/repo/CLAUDE.md"
before_md5=$(md5sum "$ownmd/repo/CLAUDE.md" 2>/dev/null | cut -d" " -f1 || md5 -q "$ownmd/repo/CLAUDE.md")

docker run --rm -e "LOCAL_MODE=1" -e "DISABLE_AUTO_GIT=1" \
    -v "$ownmd/repo:/home/node/workspace/repo" --entrypoint bash "$IMAGE" -c '
        REPO_NAME=repo LOCAL_MODE=1 DISABLE_AUTO_GIT=1
        source <(sed -n "/^write_session_facts()/,/^}/p" /entrypoint.sh)
        write_session_facts ~/workspace/CLAUDE.md
        cat /usr/local/share/sandbox-context.md >> ~/workspace/CLAUDE.md
        test -f ~/workspace/repo/CLAUDE.md' >/dev/null 2>&1

after_md5=$(md5sum "$ownmd/repo/CLAUDE.md" 2>/dev/null | cut -d" " -f1 || md5 -q "$ownmd/repo/CLAUDE.md")
if [[ "$before_md5" == "$after_md5" ]]; then
    ok "a repo's own CLAUDE.md is left byte-identical"
else
    bad "a repo's own CLAUDE.md was modified"
fi
rm -rf "$ownmd"

check "sandbox context explains project-level files" "does not get overwritten" \
    "$(in_image 'cat /usr/local/share/sandbox-context/core.md')"

# ── Exiting must not silently kill shells attached from other terminals ─────
check "entrypoint does not exec away its cleanup" "0" \
    "$(in_image 'grep -c "^exec zsh" /entrypoint.sh || echo 0')"
check "attached shells are counted before exit" "OK" \
    "$(in_image 'grep -q "count_attached_shells" /entrypoint.sh && echo OK')"

acid=$(docker run -d --entrypoint bash "$IMAGE" -c 'sleep 60')
docker exec -d "$acid" zsh -c 'while :; do sleep 1; done'
sleep 1
attached=$(docker exec "$acid" bash -c 'pgrep -x zsh 2>/dev/null | grep -c . || echo 0')
if [[ "$attached" -ge 1 ]]; then
    ok "a shell attached from another terminal is detectable"
else
    bad "attached shells are invisible, so exit would destroy them silently"
fi
docker rm -f "$acid" >/dev/null 2>&1

# ── Entrypoint sanity ────────────────────────────────────────────────────────
check "entrypoint is executable"  "OK" "$(in_image 'test -x /entrypoint.sh && echo OK')"
check "entrypoint parses"         "OK" "$(in_image 'bash -n /entrypoint.sh && echo OK')"
check "auto-git installed"        "OK" "$(in_image 'test -x /usr/local/bin/auto-git && echo OK')"
check "auto-git parses"           "OK" "$(in_image 'bash -n /usr/local/bin/auto-git && echo OK')"
check "sandbox context present"   "OK" "$(in_image 'test -d /usr/local/share/sandbox-context && test -f /usr/local/share/sandbox-context/core.md && echo OK')"
check "zsh is the shell"          "/bin/zsh" "$(in_image 'echo $SHELL')"
check "sandbox aliases loaded"    "dangerously" "$(in_image 'grep -h dangerously ~/.zshrc.sandbox | head -1')"

# ── Nothing may block on a hidden prompt ─────────────────────────────────────
# `npx` asks "Ok to proceed?" when a package is missing and stdin is a TTY.
# Inside a command substitution that prompt is invisible and the session just
# appears frozen — which is exactly what happened during a tool update.
check "npx is non-interactive" "true"   "$(in_image 'grep -m1 -o "NPM_CONFIG_YES=true" /entrypoint.sh | cut -d= -f2')"
check "no bare npx is executed" "0" \
    "$(in_image 'grep -vE "^\s*#|echo" /entrypoint.sh | grep -cE "(^|[^-])npx [^-]" || echo 0')"

# Every network call that could stall is bounded, so a hang ends in an error
# rather than an unexplained freeze.
# CI=1 also silences npx, but it is the standard "no colour, non-interactive"
# signal — setting it stripped every colour out of the agent TUI.
check "entrypoint does not set CI" "0" \
    "$(in_image 'grep -c "^export CI=" /entrypoint.sh || echo 0')"
check "no colour-suppressing vars set" "OK" \
    "$(in_image 'grep -qE "^export (NO_COLOR|TERM=dumb|CLICOLOR=0)" /entrypoint.sh && echo BAD || echo OK')"

check "network calls are bounded" "OK" \
    "$(in_image 'grep -q "timeout 300 bash -c" /entrypoint.sh && grep -q "timeout 60 git push" /entrypoint.sh && echo OK')"

# A failing step must print why, not just a warning symbol.
check "failed steps print their output" "OK" \
    "$(in_image 'grep -q "sed .s/\^/      /. \"\$LAST_STEP_LOG\"" /entrypoint.sh && echo OK')"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
echo ""
[[ "$FAIL" -eq 0 ]]

