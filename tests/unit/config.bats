#!/usr/bin/env bats
#
# Config files are parsed, never sourced. `cs .` inside a repo you just cloned
# must not be able to run code on your machine, so these tests pin that down.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$REPO_ROOT/claude-sandbox"
    CONFIG_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$CONFIG_TMP"
}

@test "load_config_file reads allowlisted keys" {
    cat > "$CONFIG_TMP/cfg" <<'EOF'
AUTO_GIT=false
AUTO_GIT_INTERVAL=120
BROWSER=true
NETWORK=bridge
EOF
    load_config_file "$CONFIG_TMP/cfg"

    [ "$AUTO_GIT" = "false" ]
    [ "$AUTO_GIT_INTERVAL" = "120" ]
    [ "$BROWSER" = "true" ]
    [ "$NETWORK" = "bridge" ]
}

@test "load_config_file ignores comments, blank lines and whitespace" {
    cat > "$CONFIG_TMP/cfg" <<'EOF'

# a comment
   BROWSER = true

EOF
    load_config_file "$CONFIG_TMP/cfg"
    [ "$BROWSER" = "true" ]
}

@test "load_config_file strips surrounding quotes" {
    printf 'NETWORK="bridge"\n' > "$CONFIG_TMP/cfg"
    load_config_file "$CONFIG_TMP/cfg"
    [ "$NETWORK" = "bridge" ]
}

@test "load_config_file ignores keys that are not allowlisted" {
    cat > "$CONFIG_TMP/cfg" <<'EOF'
PATH=/evil/bin
HOME=/evil
SELECTED_REPO=hijacked
LABEL_NS=nope
EOF
    load_config_file "$CONFIG_TMP/cfg"

    [[ "$PATH" != "/evil/bin" ]]
    [[ "$HOME" != "/evil" ]]
    [[ "${SELECTED_REPO:-}" != "hijacked" ]]
}

@test "load_config_file does not execute command substitution" {
    marker="$CONFIG_TMP/pwned"
    cat > "$CONFIG_TMP/cfg" <<EOF
NETWORK=\$(touch $marker)
BROWSER=\`touch $marker\`
EOF
    load_config_file "$CONFIG_TMP/cfg"

    [ ! -f "$marker" ]
    [[ "$NETWORK" != *"pwned"* ]]
}

@test "load_config_file rejects values with shell metacharacters" {
    printf 'NETWORK=bridge; rm -rf /\n' > "$CONFIG_TMP/cfg"
    NETWORK="host"
    load_config_file "$CONFIG_TMP/cfg"
    [ "$NETWORK" = "host" ]
}

@test "load_config_file on a missing file is a no-op" {
    NETWORK="host"
    run load_config_file "$CONFIG_TMP/does-not-exist"
    [ "$status" -eq 0 ]
    [ "$NETWORK" = "host" ]
}
