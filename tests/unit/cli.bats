#!/usr/bin/env bats
#
# Unit tests for the pure parts of the claude-sandbox CLI.
# These never touch the Docker daemon — see tests/image-smoke.sh for that.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    # Sourcing is safe: main() only runs when the script is executed directly.
    source "$REPO_ROOT/claude-sandbox"
}

@test "version is a semver string" {
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "slugify lowercases and replaces unsafe characters" {
    [ "$(slugify 'My Repo')" = "my-repo" ]
    [ "$(slugify 'owner/repo')" = "owner-repo" ]
    [ "$(slugify 'UPPER_case.name')" = "upper_case.name" ]
    [ "$(slugify '--leading--and--trailing--')" = "leading-and-trailing" ]
}

@test "format_date never fails, whatever date implementation the platform has" {
    # GNU date, BSD date and busybox date all disagree about ISO-8601 parsing.
    # The contract is only that this is best-effort and never aborts a launch.
    run format_date "2026-01-15T10:30:00Z"
    [ "$status" -eq 0 ]

    run format_date "not-a-date"
    [ "$status" -eq 0 ]

    run format_date ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run format_date "null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "format_date renders a short date where the platform can parse ISO-8601" {
    if ! date -d "2026-01-15T10:30:00Z" +%b >/dev/null 2>&1 &&
       ! date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-15T10:30:00Z" +%b >/dev/null 2>&1; then
        skip "platform date cannot parse ISO-8601"
    fi

    run format_date "2026-01-15T10:30:00Z"
    [[ "$output" =~ ^[A-Z][a-z]{2}\ [0-9]{2}$ ]]
}

@test "resolve_mount_name appends a suffix on collision" {
    SELECTED_REPO="api"
    EXTRA_PATHS=()
    [ "$(resolve_mount_name 'web')" = "web" ]
    [ "$(resolve_mount_name 'api')" = "api-2" ]

    EXTRA_PATHS=("/x/web:web")
    [ "$(resolve_mount_name 'web')" = "web-2" ]
}

@test "resolve_mount_name compares against the repo basename, not owner/repo" {
    SELECTED_REPO="owner/api"
    EXTRA_PATHS=()
    [ "$(resolve_mount_name 'api')" = "api-2" ]
}

@test "print_docker_command masks every secret it forwards" {
    DOCKER_ARGS=(run --rm
        -e "CLAUDE_CODE_OAUTH_TOKEN=sk-super-secret"
        -e "ANTHROPIC_API_KEY=sk-ant-secret"
        -e "GH_TOKEN=ghp_secret"
        image)

    run print_docker_command
    [ "$status" -eq 0 ]
    [[ "$output" != *"sk-super-secret"* ]]
    [[ "$output" != *"sk-ant-secret"* ]]
    [[ "$output" != *"ghp_secret"* ]]
    [[ "$output" == *"CLAUDE_CODE_OAUTH_TOKEN=***"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY=***"* ]]
    [[ "$output" == *"GH_TOKEN=***"* ]]
}

@test "print_docker_command quotes arguments containing spaces" {
    DOCKER_ARGS=(run -e "GIT_USER_NAME=Ada Lovelace" image)
    run print_docker_command
    [[ "$output" == *"'GIT_USER_NAME=Ada Lovelace'"* ]]
}

@test "parse_args reads launch flags" {
    POSITIONAL=()
    parse_args . -y --browser --no-auto-git --interval 30 --network bridge -b feature/x

    [ "$ASSUME_YES" = true ]
    [ "$BROWSER" = true ]
    [ "$AUTO_GIT" = false ]
    [ "$AUTO_GIT_INTERVAL" = "30" ]
    [ "$NETWORK" = "bridge" ]
    [ "$SANDBOX_BRANCH" = "feature/x" ]
    [ "${POSITIONAL[0]}" = "." ]
}

@test "parse_args treats --mount as an extra positional target" {
    POSITIONAL=()
    parse_args . -m /tmp/one -m /tmp/two
    [ "${#POSITIONAL[@]}" -eq 3 ]
    [ "${POSITIONAL[1]}" = "/tmp/one" ]
    [ "${POSITIONAL[2]}" = "/tmp/two" ]
}

@test "parse_args publishing a port switches to bridge networking" {
    POSITIONAL=()
    parse_args . -p 3000:3000
    [ "$NETWORK" = "bridge" ]
    [ "${PUBLISH_PORTS[0]}" = "3000:3000" ]
}

@test "parse_args rejects unknown options" {
    run parse_args --definitely-not-a-flag
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "dry-run implies non-interactive" {
    POSITIONAL=()
    parse_args --dry-run
    [ "$DRY_RUN" = true ]
    [ "$ASSUME_YES" = true ]
}

@test "build_docker_args wires local mode into mounts and entrypoint args" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/myrepo"
    SELECTED_REPO="myrepo"
    IMAGE_REF="claude-sandbox"
    CONTAINER_NAME="cs-test"      # avoids the docker ps lookup
    EXTRA_PATHS=("/tmp/other:other")
    AUTO_GIT=true
    BROWSER=false

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"--name cs-test"* ]]
    [[ "$joined" == *"com.claude-sandbox.managed=true"* ]]
    [[ "$joined" == *"com.claude-sandbox.mode=local"* ]]
    [[ "$joined" == *"/tmp/myrepo:/home/node/workspace/myrepo"* ]]
    [[ "$joined" == *"/tmp/other:/home/node/workspace/other"* ]]
    [[ "$joined" == *"LOCAL_MODE=1"* ]]
    [[ "$joined" == *"--local myrepo"* ]]
}

@test "build_docker_args passes the clone URL in github mode" {
    LOCAL_MODE=false
    SELECTED_REPO="owner/repo"
    SELECTED_REPO_URL="git@github.com:owner/repo.git"
    IMAGE_REF="claude-sandbox"
    CONTAINER_NAME="cs-test"
    EXTRA_PATHS=()

    build_docker_args
    local joined="${DOCKER_ARGS[*]}"

    [[ "$joined" == *"git@github.com:owner/repo.git"* ]]
    [[ "$joined" == *"com.claude-sandbox.mode=github"* ]]
    [[ "$joined" != *"LOCAL_MODE=1"* ]]
}

@test "build_docker_args disables auto-git when requested" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()
    AUTO_GIT=false

    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"DISABLE_AUTO_GIT=1"* ]]
    [[ "${DOCKER_ARGS[*]}" != *"AUTO_GIT_INTERVAL"* ]]
}

@test "build_docker_args mounts the browser cache volume only with --browser" {
    LOCAL_MODE=true
    LOCAL_PATH="/tmp/r"; SELECTED_REPO="r"; IMAGE_REF="img"; CONTAINER_NAME="cs-t"
    EXTRA_PATHS=()

    BROWSER=false
    build_docker_args
    [[ "${DOCKER_ARGS[*]}" != *"claude-sandbox-browser"* ]]

    BROWSER=true
    build_docker_args
    [[ "${DOCKER_ARGS[*]}" == *"claude-sandbox-browser:/usr/local/share/playwright"* ]]
    [[ "${DOCKER_ARGS[*]}" == *"ENABLE_BROWSER=1"* ]]
}

@test "help output lists every subcommand" {
    run show_help
    [ "$status" -eq 0 ]
    for cmd in run ps attach kill orphans doctor update version help; do
        [[ "$output" == *"$cmd"* ]]
    done
}
