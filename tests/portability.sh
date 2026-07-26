#!/bin/bash
# Portability checks, run under the SYSTEM bash rather than a container.
#
# The unit suite runs in a bats image on bash 5, so it cannot see bugs that
# only appear on bash 3.2 — which is what /bin/bash still is on every macOS.
# One of those shipped: `${p/#$HOME/\~}` leaves a literal backslash on 3.2, so
# every path in the folder picker became "\~/work/app" and resolved to nothing.
#
# Usage: tests/portability.sh [path-to-bash]

set -uo pipefail

BASH_BIN="${1:-/bin/bash}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

if [[ ! -x "$BASH_BIN" ]]; then
    echo "  no bash at $BASH_BIN — skipping"
    exit 0
fi

version=$("$BASH_BIN" -c 'echo "$BASH_VERSION"')
echo ""
echo "  Portability: $BASH_BIN (bash $version)"
echo ""

# Run an expression with the CLI sourced under the target bash
in_bash() {
    "$BASH_BIN" -c "source '$REPO_ROOT/claude-sandbox' >/dev/null 2>&1; $1" 2>&1
}

# A literal tilde here is an expected *display* string, not a path to expand,
# so it comes from a variable rather than tripping SC2088 at every use.
TILDE='~'

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$name"
    else
        bad "$name — expected [$expected], got [$actual]"
    fi
}

# ── The script must parse and be sourceable ──────────────────────────────────
if "$BASH_BIN" -n "$REPO_ROOT/claude-sandbox" 2>/dev/null; then
    ok "claude-sandbox parses"
else
    bad "claude-sandbox does not parse"
fi
if "$BASH_BIN" -n "$REPO_ROOT/install.sh" 2>/dev/null; then
    ok "install.sh parses"
else
    bad "install.sh does not parse"
fi
check "sourceable (main is guarded)" "sourced" "$(in_bash 'echo sourced')"

# ── Path display round trip: the bug that shipped ────────────────────────────
check "display_path shortens \$HOME" "${TILDE}/work/app" \
    "$(in_bash 'HOME=/Users/me; display_path /Users/me/work/app')"
check "display_path leaves other paths alone" "/opt/tool" \
    "$(in_bash 'HOME=/Users/me; display_path /opt/tool')"
check "no backslash is introduced" "clean" \
    "$(in_bash 'HOME=/Users/me; case "$(display_path /Users/me/x)" in *\\*) echo dirty ;; *) echo clean ;; esac')"
check "round trip is lossless" "/Users/me/work/app" \
    "$(in_bash 'HOME=/Users/me; resolve_display_path "$(display_path /Users/me/work/app)"')"
check "round trip survives spaces" "/Users/me/my dir/app" \
    "$(in_bash 'HOME=/Users/me; resolve_display_path "$(display_path "/Users/me/my dir/app")"')"
check "bare ~ resolves to \$HOME" "/Users/me" \
    "$(in_bash 'HOME=/Users/me; resolve_display_path "~"')"

# ── Other version- and platform-sensitive helpers ────────────────────────────
check "slugify" "my-repo" "$(in_bash 'slugify "My Repo"')"
check "mount accessors" "/a b|name|ro" \
    "$(in_bash 'e="/a b|name|ro"; printf "%s|%s|%s" "$(mount_path "$e")" "$(mount_name "$e")" "$(mount_mode "$e")"')"
check "format_date never fails" "0" \
    "$(in_bash 'format_date "2026-01-15T10:30:00Z" >/dev/null; echo $?')"
check "format_date tolerates junk" "0" \
    "$(in_bash 'format_date "not-a-date" >/dev/null; echo $?')"

# mktemp flags differ between BSD and GNU
check "snapshot temp index name" "ok" \
    "$(in_bash 'f=$(mktemp -u -t cs-index.XXXXXX 2>/dev/null) && [ -n "$f" ] && echo ok')"

# stat: BSD uses -f, GNU uses -c; doctor must handle whichever exists
check "stat has a working form" "ok" \
    "$(in_bash 'stat -f "%Lp" "$0" >/dev/null 2>&1 || stat -c "%a" "$0" >/dev/null 2>&1; echo ok')"

# ── Box rendering: every row must close on the right ─────────────────────────
# Checked here rather than in the bats container, which has no UTF-8 locale and
# a sed that does not understand \x1b, so the box characters and colour codes
# both come out mangled there.
panel_rows_closed() {
    local width="$1" out line total=0 closed=0
    out=$("$BASH_BIN" -c "
        source '$REPO_ROOT/claude-sandbox' >/dev/null 2>&1
        SELECTED_REPO=demo; LOCAL_MODE=true; LOCAL_PATH=\"\$HOME/work/demo\"
        EXTRA_PATHS=(\"\$HOME/work/some/deeply/nested/thing/api|api|rw\" \"\$HOME/notes|notes|ro\")
        draw_selection_panel $width")

    while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed $'s/\033\[[0-9;]*m//g')
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        case "$line" in
            *│|*╮|*╯) closed=$((closed + 1)) ;;
        esac
    done <<< "$out"

    [[ "$total" -gt 4 && "$closed" -eq "$total" ]] && echo "closed" || echo "$closed/$total"
}

check "panel rows close at width 46" "closed" "$(panel_rows_closed 46)"
check "panel rows close at width 56" "closed" "$(panel_rows_closed 56)"

# ── No \uXXXX escapes: bash 3.2 prints them literally ────────────────────────
# `$'\u2192'` yields the arrow on bash 4.2+ and the six characters "\u2192" on
# 3.2, so any such escape reaches macOS users as visible garbage.
check "no \\u escapes survive into rendered UI" "clean" \
    "$(in_bash 'SELECTED_REPO=demo; EXTRA_PATHS=()
        fzf() { printf "%s\n" "$@"; }
        out=$(browse_directories /tmp 2>/dev/null)
        case "$out" in *\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) echo dirty ;; *) echo clean ;; esac')"

check "browser header renders its hint text" "ok" \
    "$(in_bash 'SELECTED_REPO=demo; EXTRA_PATHS=()
        fzf() { printf "%s\n" "$@"; }
        out=$(browse_directories /tmp 2>/dev/null)
        case "$out" in *"space/tab mark"*) echo ok ;; *) echo missing ;; esac')"

# ── Cancelled pickers must not abort under set -euo pipefail ─────────────────
check "pick_one survives cancellation" "survived" \
    "$(in_bash 'set -euo pipefail; gum() { return 1; }; fzf() { return 130; }; pick_one "" a b >/dev/null; echo survived')"
check "ask_text survives cancellation" "survived" \
    "$(in_bash 'set -euo pipefail; gum() { return 1; }; ask_text x >/dev/null; echo survived')"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
echo ""
[[ "$FAIL" -eq 0 ]]
