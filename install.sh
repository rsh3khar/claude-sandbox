#!/usr/bin/env bash
set -euo pipefail

# Claude Sandbox installer.
#
#   curl -fsSL https://raw.githubusercontent.com/rsh3khar/claude-sandbox/main/install.sh | bash
#
# Installs a pinned release (verified against its published SHA256SUMS) into
# ~/.claude-sandbox, then pulls the prebuilt image from GHCR — falling back to
# a local build if the registry is unreachable.

# Colors
C_DIM=$'\033[38;2;120;113;108m'
C_TEXT=$'\033[38;2;214;211;209m'
C_ACCENT=$'\033[38;2;217;119;6m'
C_SUCCESS=$'\033[38;2;34;197;94m'
C_ERROR=$'\033[38;2;239;68;68m'
C_WARN=$'\033[38;2;234;179;8m'
NC=$'\033[0m'
BOLD=$'\033[1m'

CHECK="✓"
CROSS="✗"
ARROW="→"

# Install locations
INSTALL_DIR="$HOME/.claude-sandbox"
BIN_DIR="$HOME/.local/bin"
TOKEN_FILE="$HOME/.claude-sandbox-token"

GITHUB_REPO="rsh3khar/claude-sandbox"
IMAGE_NAME="claude-sandbox"
IMAGE_REGISTRY="ghcr.io/${GITHUB_REPO}"

# Detect if running from a pipe (curl | bash) or from a cloned repo
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FROM_PIPE=false
else
    SCRIPT_DIR=""
    FROM_PIPE=true
fi

MODE="install"
SKIP_DEPS=false
SKIP_BUILD=false
PULL_IMAGE=true
REQUESTED_VERSION="${CLAUDE_SANDBOX_VERSION:-latest}"

say_ok()   { echo -e "  ${C_SUCCESS}${CHECK}${NC} $*"; }
say_warn() { echo -e "  ${C_WARN}!${NC} $*"; }
say_err()  { echo -e "  ${C_ERROR}${CROSS}${NC} $*" >&2; }
say_step() { echo -e "  ${C_ACCENT}${ARROW}${NC} $*"; }
die()      { say_err "$*"; exit 1; }

show_help() {
    cat <<EOF

${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX INSTALLER${NC}

${C_TEXT}Usage:${NC}
  ./install.sh                ${C_DIM}# Install the latest release${NC}
  ./install.sh --link         ${C_DIM}# Dev mode (symlink this repo)${NC}
  ./install.sh --update       ${C_DIM}# Update the image only${NC}
  ./install.sh --uninstall    ${C_DIM}# Remove claude-sandbox${NC}

${C_TEXT}Options:${NC}
  --link              ${C_DIM}Symlink ~/.claude-sandbox to this repo (development)${NC}
  --uninstall         ${C_DIM}Remove installed files and the Docker image${NC}
  --update            ${C_DIM}Pull/rebuild the image without reinstalling files${NC}
  --version <tag>     ${C_DIM}Install a specific release (e.g. v0.3.0, or 'main')${NC}
  --no-pull           ${C_DIM}Always build the image locally instead of pulling${NC}
  --skip-deps         ${C_DIM}Skip dependency checks${NC}
  --skip-build        ${C_DIM}Skip the image step entirely${NC}
  --help              ${C_DIM}Show this help${NC}

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --link)       MODE="link"; shift ;;
        --uninstall)  MODE="uninstall"; shift ;;
        --update)     MODE="update"; shift ;;
        --version)    REQUESTED_VERSION="${2:?--version needs a tag}"; shift 2 ;;
        --no-pull)    PULL_IMAGE=false; shift ;;
        --skip-deps)  SKIP_DEPS=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --help|-h)    show_help; exit 0 ;;
        *)            say_err "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ============================================================================
# Image helpers
# ============================================================================

pull_or_build_image() {
    local version_tag="$1"
    local ref="${IMAGE_REGISTRY}:${version_tag}"

    if [[ "$PULL_IMAGE" == true ]]; then
        echo -e "  ${C_DIM}Pulling ${ref}...${NC}"
        if docker pull --quiet "$ref" >/dev/null 2>&1; then
            docker tag "$ref" "$IMAGE_NAME"
            say_ok "Image pulled ${C_DIM}(${ref})${NC}"
            return 0
        fi
        say_warn "Registry unavailable — building locally instead"
    fi

    [[ -f "$INSTALL_DIR/Dockerfile" ]] || die "No Dockerfile at ${INSTALL_DIR}"

    echo -e "  ${C_DIM}Building image (a few minutes on first run)...${NC}"
    if DOCKER_BUILDKIT=1 docker build -t "$IMAGE_NAME" "$INSTALL_DIR" 2>&1 | while read -r line; do
        echo -e "    ${C_DIM}${line}${NC}"
    done; then
        say_ok "Image built"
    else
        die "Docker build failed"
    fi
}

# ============================================================================
# UNINSTALL
# ============================================================================

if [[ "$MODE" == "uninstall" ]]; then
    echo ""
    echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX UNINSTALLER${NC}"
    echo ""

    if [[ -e "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        say_ok "Removed ${INSTALL_DIR}"
    else
        echo -e "  ${C_DIM}-${NC} ${INSTALL_DIR} not found"
    fi

    if [[ -L "$BIN_DIR/claude-sandbox" ]]; then
        rm "$BIN_DIR/claude-sandbox"
        say_ok "Removed symlink from ${BIN_DIR}"
    fi

    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        docker rmi "$IMAGE_NAME" --force &>/dev/null || true
        say_ok "Removed Docker image"
    fi

    if docker volume inspect claude-sandbox-browser &>/dev/null; then
        docker volume rm claude-sandbox-browser &>/dev/null || true
        say_ok "Removed browser cache volume"
    fi

    if [[ -f "$TOKEN_FILE" ]]; then
        echo ""
        read -r -p "Remove OAuth token file (~/.claude-sandbox-token)? [y/N] " -n 1 REPLY
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$TOKEN_FILE"
            say_ok "Removed token file"
        fi
    fi

    echo ""
    say_ok "${C_TEXT}Uninstall complete${NC}"
    echo ""
    exit 0
fi

# ============================================================================
# UPDATE (image only)
# ============================================================================

if [[ "$MODE" == "update" ]]; then
    echo ""
    echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX UPDATER${NC}"
    echo ""

    [[ -e "$INSTALL_DIR" ]] || die "Claude Sandbox not installed. Run ./install.sh first."

    installed_version=$(sed -n 's/^VERSION="\(.*\)".*/\1/p' "$INSTALL_DIR/claude-sandbox" 2>/dev/null | head -1)
    pull_or_build_image "v${installed_version:-latest}"

    echo ""
    exit 0
fi

# ============================================================================
# INSTALL / LINK
# ============================================================================

echo ""
echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX INSTALLER${NC}"
echo ""
echo -e "${C_DIM}Run Claude Code with --dangerously-skip-permissions${NC}"
echo -e "${C_DIM}safely in an isolated Docker container${NC}"
echo ""

if [[ "$MODE" == "link" ]]; then
    echo -e "${C_WARN}${BOLD}Developer mode:${NC} ${C_DIM}will symlink to this repo${NC}"
    echo ""
fi

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
fi

HAS_BREW=false
command -v brew &>/dev/null && HAS_BREW=true

check_cmd() { command -v "$1" &>/dev/null; }

install_dep() {
    local dep="$1"
    if [[ "$OS" == "macos" && "$HAS_BREW" == "true" ]]; then
        say_step "Installing ${dep} via Homebrew..."
        brew install "$dep"
    elif [[ "$OS" == "linux" ]]; then
        say_step "Installing ${dep} via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y "$dep"
    else
        say_err "Cannot auto-install ${dep}. Please install manually."
        return 1
    fi
}

# ── Dependencies ─────────────────────────────────────────────────────────────
if [[ "$SKIP_DEPS" == "false" ]]; then
    echo -e "${C_TEXT}Checking dependencies...${NC}"
    echo ""

    MISSING=()
    for dep in docker gh gum jq; do
        if check_cmd "$dep"; then
            say_ok "$dep"
        else
            say_err "$dep"
            MISSING+=("$dep")
        fi
    done
    echo ""

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo -e "${C_WARN}Missing dependencies: ${MISSING[*]}${NC}"
        echo ""

        if [[ " ${MISSING[*]} " == *" docker "* ]]; then
            echo -e "${C_TEXT}Docker is required. Install one of:${NC}"
            echo -e "  ${C_DIM}•${NC} OrbStack (recommended): ${C_TEXT}brew install orbstack${NC}"
            echo -e "  ${C_DIM}•${NC} Docker Desktop: ${C_TEXT}brew install --cask docker${NC}"
            echo ""
            die "Install Docker, then run this installer again."
        fi

        if [[ "$HAS_BREW" == "true" || "$OS" == "linux" ]]; then
            read -r -p "Install missing dependencies? [Y/n] " -n 1 REPLY
            echo ""
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                for dep in "${MISSING[@]}"; do
                    install_dep "$dep"
                done
                echo ""
            else
                die "Please install missing dependencies and run again."
            fi
        else
            die "Cannot auto-install. Please install: ${MISSING[*]}"
        fi
    fi

    # Recommended, not required: makes the folder picker a filterable
    # multi-select list with a preview pane instead of a plain single column.
    if check_cmd fzf; then
        say_ok "fzf ${C_DIM}(folder browser)${NC}"
    else
        say_warn "fzf not found ${C_DIM}— optional, enables the folder browser with previews${NC}"
        if [[ "$HAS_BREW" == "true" || "$OS" == "linux" ]]; then
            read -r -p "  Install fzf? [y/N] " -n 1 REPLY
            echo ""
            [[ $REPLY =~ ^[Yy]$ ]] && install_dep fzf
        fi
    fi
    echo ""

    echo -e "${C_TEXT}Checking GitHub authentication...${NC}"
    if gh auth status &>/dev/null; then
        GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
        say_ok "Logged in as ${C_ACCENT}@${GH_USER}${NC}"
    else
        say_warn "Not logged in to GitHub"
        echo ""
        read -r -p "Login to GitHub now? [Y/n] " -n 1 REPLY
        echo ""
        [[ ! $REPLY =~ ^[Nn]$ ]] && gh auth login
    fi
    echo ""
fi

mkdir -p "$BIN_DIR"

# ── Resolve the version to install ───────────────────────────────────────────
resolve_version() {
    if [[ "$REQUESTED_VERSION" != "latest" ]]; then
        echo "$REQUESTED_VERSION"
        return
    fi
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || echo "")
    echo "${tag:-main}"
}

# ── Download a pinned release and verify it ──────────────────────────────────
download_release() {
    local version="$1" dest="$2"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if [[ "$version" == "main" ]]; then
        say_warn "Installing from ${C_TEXT}main${NC} ${C_DIM}(unreleased, no checksum verification)${NC}"
        curl -fsSL "https://github.com/${GITHUB_REPO}/archive/refs/heads/main.tar.gz" -o "$tmp/src.tar.gz" \
            || die "Download failed"
    else
        local base="https://github.com/${GITHUB_REPO}/releases/download/${version}"
        curl -fsSL "${base}/claude-sandbox-${version}.tar.gz" -o "$tmp/src.tar.gz" \
            || die "Could not download release ${version}"

        if curl -fsSL "${base}/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
            local expected actual
            expected=$(grep "claude-sandbox-${version}.tar.gz" "$tmp/SHA256SUMS" | awk '{print $1}')
            if command -v sha256sum &>/dev/null; then
                actual=$(sha256sum "$tmp/src.tar.gz" | awk '{print $1}')
            else
                actual=$(shasum -a 256 "$tmp/src.tar.gz" | awk '{print $1}')
            fi
            if [[ -n "$expected" && "$expected" != "$actual" ]]; then
                die "Checksum mismatch for ${version} — refusing to install"
            fi
            say_ok "Checksum verified ${C_DIM}(sha256)${NC}"
        else
            say_warn "No SHA256SUMS published for ${version} — skipping verification"
        fi
    fi

    mkdir -p "$dest"
    tar -xzf "$tmp/src.tar.gz" -C "$tmp"
    local extracted
    extracted=$(find "$tmp" -maxdepth 1 -type d -name 'claude-sandbox-*' | head -1)
    [[ -n "$extracted" ]] || die "Unexpected archive layout"

    # Replace contents without nuking the directory itself (it may be in PATH)
    rm -rf "${dest:?}"/*
    cp -R "$extracted"/. "$dest"/
}

INSTALLED_VERSION=""

if [[ "$MODE" == "link" ]]; then
    [[ "$FROM_PIPE" == false ]] || die "--link requires a cloned repo, not curl | bash"

    echo -e "${C_TEXT}Linking to ${C_ACCENT}${SCRIPT_DIR}${NC}..."
    echo ""

    if [[ -L "$INSTALL_DIR" ]]; then
        [[ "$(readlink "$INSTALL_DIR")" == "$SCRIPT_DIR" ]] || { rm "$INSTALL_DIR"; ln -s "$SCRIPT_DIR" "$INSTALL_DIR"; }
        say_ok "Linked ${INSTALL_DIR} ${ARROW} ${SCRIPT_DIR}"
    else
        [[ -e "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
        ln -s "$SCRIPT_DIR" "$INSTALL_DIR"
        say_ok "Created symlink: ${INSTALL_DIR} ${ARROW} ${SCRIPT_DIR}"
    fi
else
    VERSION_TAG=$(resolve_version)
    echo -e "${C_TEXT}Installing ${C_ACCENT}${VERSION_TAG}${C_TEXT} to ${C_ACCENT}${INSTALL_DIR}${NC}..."
    echo ""

    [[ -L "$INSTALL_DIR" ]] && { rm "$INSTALL_DIR"; echo -e "  ${C_DIM}-${NC} Removed dev symlink"; }
    mkdir -p "$INSTALL_DIR"

    if [[ "$FROM_PIPE" == false && "$REQUESTED_VERSION" == "latest" && -f "$SCRIPT_DIR/claude-sandbox" ]]; then
        # Running from a clone: install exactly what is checked out
        rm -rf "${INSTALL_DIR:?}"/*
        cp -R "$SCRIPT_DIR"/. "$INSTALL_DIR"/
        rm -rf "$INSTALL_DIR/.git"
        say_ok "Copied working tree to ${INSTALL_DIR}"
    else
        download_release "$VERSION_TAG" "$INSTALL_DIR"
        say_ok "Installed ${VERSION_TAG}"
    fi

    chmod +x "$INSTALL_DIR/claude-sandbox" "$INSTALL_DIR/runtime/entrypoint.sh" "$INSTALL_DIR/runtime/auto-git.sh" 2>/dev/null || true
fi

INSTALLED_VERSION=$(sed -n 's/^VERSION="\(.*\)".*/\1/p' "$INSTALL_DIR/claude-sandbox" 2>/dev/null | head -1)

ln -sf "$INSTALL_DIR/claude-sandbox" "$BIN_DIR/claude-sandbox"
say_ok "Linked ${BIN_DIR}/claude-sandbox"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    say_warn "${BIN_DIR} is not in your PATH"
    echo -e "  ${C_DIM}Add to your shell rc:${NC} ${C_TEXT}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
fi

# ── zsh completion ───────────────────────────────────────────────────────────
if [[ -f "$INSTALL_DIR/completions/_claude-sandbox" ]]; then
    COMPLETION_DIR=""
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        COMPLETION_DIR="$HOME/.oh-my-zsh/completions"
    elif [[ -n "${ZDOTDIR:-}" || -f "$HOME/.zshrc" ]]; then
        COMPLETION_DIR="$HOME/.zsh/completions"
    fi
    if [[ -n "$COMPLETION_DIR" ]]; then
        mkdir -p "$COMPLETION_DIR"
        cp "$INSTALL_DIR/completions/_claude-sandbox" "$COMPLETION_DIR/"
        say_ok "Installed zsh completion ${C_DIM}(${COMPLETION_DIR})${NC}"
    fi
fi

# ── Image ────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo ""
    echo -e "${C_TEXT}Sandbox image...${NC}"
    echo ""
    pull_or_build_image "v${INSTALLED_VERSION:-latest}"
fi

# ── Claude Code authentication ───────────────────────────────────────────────
echo ""
echo -e "${C_TEXT}Claude Code authentication...${NC}"
echo ""

if [[ -f "$TOKEN_FILE" ]]; then
    say_ok "Token file exists at ~/.claude-sandbox-token"
else
    echo -e "  ${C_DIM}Claude Code needs an OAuth token to work in the container.${NC}"
    echo ""
    echo -e "  ${C_TEXT}1.${NC} Run: ${C_ACCENT}claude setup-token${NC}"
    echo -e "  ${C_TEXT}2.${NC} Copy the token"
    echo -e "  ${C_TEXT}3.${NC} Save it: ${C_ACCENT}echo 'YOUR_TOKEN' > ~/.claude-sandbox-token${NC}"
    echo -e "  ${C_TEXT}4.${NC} Secure it: ${C_ACCENT}chmod 600 ~/.claude-sandbox-token${NC}"
    echo ""
    read -r -p "Set up token now? [Y/n] " -n 1 REPLY
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "${C_DIM}Running 'claude setup-token'...${NC}"
        echo ""
        claude setup-token || true

        echo ""
        echo -e "${C_TEXT}Paste your OAuth token:${NC}"
        read -r TOKEN

        if [[ -n "$TOKEN" ]]; then
            (umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE")
            echo ""
            say_ok "Token saved to ~/.claude-sandbox-token ${C_DIM}(chmod 600)${NC}"
        fi
    fi
fi

# ── Screenshot sharing (macOS) ───────────────────────────────────────────────
if [[ "$OS" == "macos" ]]; then
    echo ""
    echo -e "${C_TEXT}Screenshot sharing...${NC}"
    echo ""
    echo -e "  ${C_DIM}Claude inside the sandbox can't reach your clipboard.${NC}"
    echo -e "  ${C_DIM}We can point macOS screenshots at a shared folder instead.${NC}"
    echo ""
    echo -e "  ${C_DIM}Current location:${NC} $(defaults read com.apple.screencapture location 2>/dev/null || echo "$HOME/Desktop")"
    echo -e "  ${C_DIM}New location:${NC}     ${C_ACCENT}${HOME}/.claude/screenshots/${NC}"
    echo ""
    read -r -p "Change screenshot save location? [y/N] " -n 1 REPLY
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$HOME/.claude/screenshots"
        defaults write com.apple.screencapture location "$HOME/.claude/screenshots"
        killall SystemUIServer 2>/dev/null || true
        say_ok "Screenshots now save to ~/.claude/screenshots/"
    else
        echo -e "  ${C_DIM}-${NC} Skipped"
    fi
fi

# ── Shell alias ──────────────────────────────────────────────────────────────
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
say_ok "${C_TEXT}${BOLD}Installed claude-sandbox ${INSTALLED_VERSION}${NC}"
echo ""

if [[ "$MODE" == "link" ]]; then
    echo -e "  ${C_WARN}${BOLD}Dev mode:${NC} ${C_DIM}script changes apply immediately${NC}"
    echo -e "  ${C_DIM}Rebuild the image with ${C_ACCENT}make build${NC}"
    echo ""
fi

SHELL_RC=""
if [[ -f "$HOME/.zshrc" ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [[ -n "$SHELL_RC" ]]; then
    if grep -q 'alias cs=' "$SHELL_RC" 2>/dev/null; then
        say_ok "${C_DIM}Alias ${C_ACCENT}cs${C_DIM} already in $(basename "$SHELL_RC")${NC}"
    else
        read -r -p "  Add the ${C_ACCENT}cs${NC} alias to $(basename "$SHELL_RC")? [Y/n] " -n 1 REPLY
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            printf '\n# Claude Sandbox\nalias cs="claude-sandbox"\n' >> "$SHELL_RC"
            say_ok "Added ${C_ACCENT}cs${NC} alias"
        fi
    fi

    # Container management now lives in the CLI itself
    if grep -qE '^(cs-list|cs-attach|cs-orphans)\(\)' "$SHELL_RC" 2>/dev/null; then
        echo ""
        say_warn "Found ${C_TEXT}cs-list/cs-attach/cs-orphans${NC} in $(basename "$SHELL_RC")"
        echo -e "     ${C_DIM}These are now built in and label-aware:${NC}"
        echo -e "     ${C_DIM}  cs-list    ${ARROW} ${C_TEXT}cs ps${NC}"
        echo -e "     ${C_DIM}  cs-attach  ${ARROW} ${C_TEXT}cs attach${NC}"
        echo -e "     ${C_DIM}  cs-orphans ${ARROW} ${C_TEXT}cs orphans${NC}"
        echo -e "     ${C_DIM}Safe to delete the old functions.${NC}"
    fi
fi

echo ""
echo -e "  ${C_DIM}Get started:${NC}"
echo -e "    ${C_TEXT}cs .${NC}          ${C_DIM}sandbox the current repo${NC}"
echo -e "    ${C_TEXT}cs doctor${NC}     ${C_DIM}check your setup${NC}"
echo -e "    ${C_TEXT}cs --help${NC}     ${C_DIM}all commands${NC}"
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
