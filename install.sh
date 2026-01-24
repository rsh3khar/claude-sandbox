#!/bin/bash
set -euo pipefail

# Colors
C_DIM=$'\033[38;2;120;113;108m'
C_TEXT=$'\033[38;2;214;211;209m'
C_ACCENT=$'\033[38;2;217;119;6m'
C_SUCCESS=$'\033[38;2;34;197;94m'
C_ERROR=$'\033[38;2;239;68;68m'
C_WARN=$'\033[38;2;234;179;8m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# Symbols
CHECK="✓"
CROSS="✗"
ARROW="→"

# Install locations
INSTALL_DIR="$HOME/.claude-sandbox"
BIN_DIR="$HOME/.local/bin"
TOKEN_FILE="$HOME/.claude-sandbox-token"

# GitHub raw URL for downloading files
GITHUB_RAW="https://raw.githubusercontent.com/rsh3khar/claude-sandbox/main"

# Detect if running from pipe (curl | bash) or from local file
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FROM_PIPE=false
else
    SCRIPT_DIR=""
    FROM_PIPE=true
fi

# Parse arguments
MODE="install"
SKIP_DEPS=false
SKIP_BUILD=false

show_help() {
    echo ""
    echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX INSTALLER${NC}"
    echo ""
    echo -e "${C_TEXT}Usage:${NC}"
    echo -e "  ./install.sh              ${C_DIM}# Normal install (copies files)${NC}"
    echo -e "  ./install.sh --link       ${C_DIM}# Dev mode (symlinks to repo)${NC}"
    echo -e "  ./install.sh --uninstall  ${C_DIM}# Remove claude-sandbox${NC}"
    echo -e "  ./install.sh --update     ${C_DIM}# Rebuild Docker image only${NC}"
    echo ""
    echo -e "${C_TEXT}Options:${NC}"
    echo -e "  --link        ${C_DIM}Symlink ~/.claude-sandbox to this repo (for development)${NC}"
    echo -e "  --uninstall   ${C_DIM}Remove installed files and Docker image${NC}"
    echo -e "  --update      ${C_DIM}Rebuild Docker image without reinstalling${NC}"
    echo -e "  --skip-deps   ${C_DIM}Skip dependency checks${NC}"
    echo -e "  --skip-build  ${C_DIM}Skip Docker image build${NC}"
    echo -e "  --help        ${C_DIM}Show this help message${NC}"
    echo ""
}

for arg in "$@"; do
    case $arg in
        --link)
            MODE="link"
            ;;
        --uninstall)
            MODE="uninstall"
            ;;
        --update)
            MODE="update"
            ;;
        --skip-deps)
            SKIP_DEPS=true
            ;;
        --skip-build)
            SKIP_BUILD=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo -e "${C_ERROR}Unknown option: $arg${NC}"
            show_help
            exit 1
            ;;
    esac
done

# ============================================================================
# UNINSTALL
# ============================================================================

if [[ "$MODE" == "uninstall" ]]; then
    echo ""
    echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX UNINSTALLER${NC}"
    echo ""

    # Remove install directory
    if [[ -e "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Removed ${INSTALL_DIR}"
    else
        echo -e "  ${C_DIM}-${NC} ${INSTALL_DIR} not found"
    fi

    # Remove symlink
    if [[ -L "$BIN_DIR/claude-sandbox" ]]; then
        rm "$BIN_DIR/claude-sandbox"
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Removed symlink from ${BIN_DIR}"
    else
        echo -e "  ${C_DIM}-${NC} Symlink not found"
    fi

    # Remove Docker image
    if docker image inspect claude-sandbox &>/dev/null; then
        docker rmi claude-sandbox --force &>/dev/null
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Removed Docker image"
    else
        echo -e "  ${C_DIM}-${NC} Docker image not found"
    fi

    # Ask about token file
    if [[ -f "$TOKEN_FILE" ]]; then
        echo ""
        read -p "Remove OAuth token file (~/.claude-sandbox-token)? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$TOKEN_FILE"
            echo -e "  ${C_SUCCESS}${CHECK}${NC} Removed token file"
        else
            echo -e "  ${C_DIM}-${NC} Kept token file"
        fi
    fi

    echo ""
    echo -e "${C_SUCCESS}${CHECK}${NC} ${C_TEXT}Uninstall complete${NC}"
    echo ""
    exit 0
fi

# ============================================================================
# UPDATE (rebuild Docker image only)
# ============================================================================

if [[ "$MODE" == "update" ]]; then
    echo ""
    echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX UPDATER${NC}"
    echo ""

    # Check if installed
    if [[ ! -e "$INSTALL_DIR" ]]; then
        echo -e "${C_ERROR}${CROSS}${NC} Claude Sandbox not installed. Run ./install.sh first."
        exit 1
    fi

    echo -e "${C_TEXT}Rebuilding Docker image...${NC}"
    echo ""

    if docker build -t claude-sandbox "$INSTALL_DIR" 2>&1 | while read -r line; do
        echo -e "  ${C_DIM}${line}${NC}"
    done; then
        echo ""
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Docker image rebuilt"
    else
        echo ""
        echo -e "  ${C_ERROR}${CROSS}${NC} Docker build failed"
        exit 1
    fi

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
    echo -e "${C_WARN}${BOLD}Developer mode:${NC} ${C_DIM}Will symlink to this repo${NC}"
    echo ""
fi

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
fi

# Check for Homebrew on macOS
HAS_BREW=false
if command -v brew &>/dev/null; then
    HAS_BREW=true
fi

# Function to check if a command exists
check_cmd() {
    command -v "$1" &>/dev/null
}

# Function to install a dependency
install_dep() {
    local dep="$1"
    local brew_pkg="${2:-$1}"
    local apt_pkg="${3:-$1}"

    if [[ "$OS" == "macos" && "$HAS_BREW" == "true" ]]; then
        echo -e "  ${C_ACCENT}${ARROW}${NC} Installing ${dep} via Homebrew..."
        brew install "$brew_pkg"
    elif [[ "$OS" == "linux" ]]; then
        echo -e "  ${C_ACCENT}${ARROW}${NC} Installing ${dep} via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y "$apt_pkg"
    else
        echo -e "  ${C_ERROR}${CROSS}${NC} Cannot auto-install ${dep}. Please install manually."
        return 1
    fi
}

# Check dependencies (unless skipped)
if [[ "$SKIP_DEPS" == "false" ]]; then
    echo -e "${C_TEXT}Checking dependencies...${NC}"
    echo ""

    MISSING=()

    # Docker
    if check_cmd docker; then
        echo -e "  ${C_SUCCESS}${CHECK}${NC} docker"
    else
        echo -e "  ${C_ERROR}${CROSS}${NC} docker ${C_DIM}(required)${NC}"
        MISSING+=("docker")
    fi

    # GitHub CLI
    if check_cmd gh; then
        echo -e "  ${C_SUCCESS}${CHECK}${NC} gh"
    else
        echo -e "  ${C_ERROR}${CROSS}${NC} gh ${C_DIM}(GitHub CLI)${NC}"
        MISSING+=("gh")
    fi

    # gum (for interactive prompts)
    if check_cmd gum; then
        echo -e "  ${C_SUCCESS}${CHECK}${NC} gum"
    else
        echo -e "  ${C_ERROR}${CROSS}${NC} gum ${C_DIM}(interactive prompts)${NC}"
        MISSING+=("gum")
    fi

    # jq (for JSON parsing)
    if check_cmd jq; then
        echo -e "  ${C_SUCCESS}${CHECK}${NC} jq"
    else
        echo -e "  ${C_ERROR}${CROSS}${NC} jq ${C_DIM}(JSON parsing)${NC}"
        MISSING+=("jq")
    fi

    echo ""

    # Handle missing dependencies
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo -e "${C_WARN}Missing dependencies: ${MISSING[*]}${NC}"
        echo ""

        # Special handling for Docker
        if [[ " ${MISSING[*]} " =~ " docker " ]]; then
            echo -e "${C_TEXT}Docker is required. Install one of:${NC}"
            echo -e "  ${C_DIM}•${NC} OrbStack (recommended): ${C_TEXT}brew install orbstack${NC}"
            echo -e "  ${C_DIM}•${NC} Docker Desktop: ${C_TEXT}brew install --cask docker${NC}"
            echo ""
            echo -e "${C_DIM}After installing Docker, run this installer again.${NC}"
            exit 1
        fi

        # Offer to install other missing deps
        if [[ "$HAS_BREW" == "true" || "$OS" == "linux" ]]; then
            read -p "Install missing dependencies? [Y/n] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                for dep in "${MISSING[@]}"; do
                    if [[ "$dep" != "docker" ]]; then
                        install_dep "$dep"
                    fi
                done
                echo ""
            else
                echo -e "${C_DIM}Please install missing dependencies and run again.${NC}"
                exit 1
            fi
        else
            echo -e "${C_ERROR}Cannot auto-install dependencies.${NC}"
            echo -e "${C_DIM}Please install: ${MISSING[*]}${NC}"
            exit 1
        fi
    fi

    # Check GitHub auth
    echo -e "${C_TEXT}Checking GitHub authentication...${NC}"
    if gh auth status &>/dev/null; then
        GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Logged in as ${C_ACCENT}@${GH_USER}${NC}"
    else
        echo -e "  ${C_WARN}!${NC} Not logged in to GitHub"
        echo ""
        read -p "Login to GitHub now? [Y/n] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            gh auth login
        fi
    fi
    echo ""
fi

# Create bin directory
mkdir -p "$BIN_DIR"

# Install based on mode
if [[ "$MODE" == "link" ]]; then
    # Developer mode: symlink to repo
    if [[ "$FROM_PIPE" == true ]]; then
        echo -e "${C_ERROR}${CROSS} --link requires running from cloned repo, not curl | bash${NC}"
        echo -e "${C_DIM}  Clone the repo first: git clone https://github.com/rsh3khar/claude-sandbox${NC}"
        exit 1
    fi
    echo -e "${C_TEXT}Linking to ${C_ACCENT}${SCRIPT_DIR}${NC}..."
    echo ""

    # Remove existing install dir if it's not already a symlink to this repo
    if [[ -e "$INSTALL_DIR" ]]; then
        if [[ -L "$INSTALL_DIR" ]]; then
            CURRENT_TARGET=$(readlink "$INSTALL_DIR")
            if [[ "$CURRENT_TARGET" == "$SCRIPT_DIR" ]]; then
                echo -e "  ${C_DIM}-${NC} Already linked to this repo"
            else
                rm "$INSTALL_DIR"
                ln -s "$SCRIPT_DIR" "$INSTALL_DIR"
                echo -e "  ${C_SUCCESS}${CHECK}${NC} Updated symlink to this repo"
            fi
        else
            rm -rf "$INSTALL_DIR"
            ln -s "$SCRIPT_DIR" "$INSTALL_DIR"
            echo -e "  ${C_SUCCESS}${CHECK}${NC} Replaced install with symlink to repo"
        fi
    else
        ln -s "$SCRIPT_DIR" "$INSTALL_DIR"
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Created symlink: ${INSTALL_DIR} → ${SCRIPT_DIR}"
    fi
else
    # Normal mode: copy or download files
    echo -e "${C_TEXT}Installing to ${C_ACCENT}${INSTALL_DIR}${NC}..."
    echo ""

    # Remove if symlink (switching from dev mode)
    if [[ -L "$INSTALL_DIR" ]]; then
        rm "$INSTALL_DIR"
        echo -e "  ${C_DIM}-${NC} Removed dev symlink"
    fi

    # Create directory
    mkdir -p "$INSTALL_DIR"

    if [[ "$FROM_PIPE" == true ]]; then
        # Download files from GitHub
        echo -e "  ${C_DIM}Downloading from GitHub...${NC}"
        curl -fsSL "$GITHUB_RAW/Dockerfile" -o "$INSTALL_DIR/Dockerfile"
        curl -fsSL "$GITHUB_RAW/claude-sandbox" -o "$INSTALL_DIR/claude-sandbox"
        curl -fsSL "$GITHUB_RAW/entrypoint.sh" -o "$INSTALL_DIR/entrypoint.sh"
        curl -fsSL "$GITHUB_RAW/auto-git.sh" -o "$INSTALL_DIR/auto-git.sh"
        curl -fsSL "$GITHUB_RAW/p10k.zsh" -o "$INSTALL_DIR/p10k.zsh"
        curl -fsSL "$GITHUB_RAW/sandbox-context.md" -o "$INSTALL_DIR/sandbox-context.md"
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Downloaded files from GitHub"
    else
        # Copy files from local directory
        cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/claude-sandbox" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/entrypoint.sh" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/auto-git.sh" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/p10k.zsh" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/sandbox-context.md" "$INSTALL_DIR/"
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Copied files to ${INSTALL_DIR}"
    fi

    # Make executable
    chmod +x "$INSTALL_DIR/claude-sandbox"
    chmod +x "$INSTALL_DIR/entrypoint.sh"
    chmod +x "$INSTALL_DIR/auto-git.sh"
fi

# Create symlink to binary
ln -sf "$INSTALL_DIR/claude-sandbox" "$BIN_DIR/claude-sandbox"
echo -e "  ${C_SUCCESS}${CHECK}${NC} Created symlink in ${BIN_DIR}"

# Check if BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo -e "  ${C_WARN}!${NC} ${BIN_DIR} is not in your PATH"
    echo -e "  ${C_DIM}Add this to your ~/.zshrc or ~/.bashrc:${NC}"
    echo ""
    echo -e "    ${C_TEXT}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
fi

# Build Docker image (unless skipped)
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo ""
    echo -e "${C_TEXT}Building Docker image...${NC}"
    echo -e "${C_DIM}(this may take a few minutes on first run)${NC}"
    echo ""

    if docker build -t claude-sandbox "$INSTALL_DIR" 2>&1 | while read -r line; do
        echo -e "  ${C_DIM}${line}${NC}"
    done; then
        echo ""
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Docker image built"
    else
        echo ""
        echo -e "  ${C_ERROR}${CROSS}${NC} Docker build failed"
        exit 1
    fi
fi

# Claude Code authentication
echo ""
echo -e "${C_TEXT}Claude Code authentication...${NC}"
echo ""

if [[ -f "$TOKEN_FILE" ]]; then
    echo -e "  ${C_SUCCESS}${CHECK}${NC} Token file exists at ~/.claude-sandbox-token"
else
    echo -e "  ${C_DIM}Claude Code needs an OAuth token to work in the container.${NC}"
    echo ""
    echo -e "  ${C_TEXT}1.${NC} Run: ${C_ACCENT}claude setup-token${NC}"
    echo -e "  ${C_TEXT}2.${NC} Copy the token"
    echo -e "  ${C_TEXT}3.${NC} Save it: ${C_ACCENT}echo 'YOUR_TOKEN' > ~/.claude-sandbox-token${NC}"
    echo -e "  ${C_TEXT}4.${NC} Secure it: ${C_ACCENT}chmod 600 ~/.claude-sandbox-token${NC}"
    echo ""
    read -p "Set up token now? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "${C_DIM}Running 'claude setup-token'...${NC}"
        echo -e "${C_DIM}Copy the token when it appears, then paste it below.${NC}"
        echo ""

        # Run claude setup-token
        claude setup-token || true

        echo ""
        echo -e "${C_TEXT}Paste your OAuth token:${NC}"
        read -r TOKEN

        if [[ -n "$TOKEN" ]]; then
            echo "$TOKEN" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo ""
            echo -e "  ${C_SUCCESS}${CHECK}${NC} Token saved to ~/.claude-sandbox-token"
        fi
    fi
fi

# Screenshot sharing setup (macOS only)
if [[ "$OS" == "macos" ]]; then
    echo ""
    echo -e "${C_TEXT}Screenshot sharing...${NC}"
    echo ""
    echo -e "  ${C_DIM}Claude inside the sandbox can't access your clipboard.${NC}"
    echo -e "  ${C_DIM}To share screenshots, we can change where macOS saves them.${NC}"
    echo ""
    echo -e "  ${C_DIM}Current location:${NC} $(defaults read com.apple.screencapture location 2>/dev/null || echo "~/Desktop")"
    echo -e "  ${C_DIM}New location:${NC}     ${C_ACCENT}~/.claude/screenshots/${NC}"
    echo ""
    read -p "Change screenshot save location? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$HOME/.claude/screenshots"
        defaults write com.apple.screencapture location "$HOME/.claude/screenshots"
        killall SystemUIServer 2>/dev/null || true
        echo -e "  ${C_SUCCESS}${CHECK}${NC} Screenshots now save to ~/.claude/screenshots/"
        echo -e "  ${C_DIM}  Take screenshot (Cmd+Shift+4) → Claude can see it${NC}"
    else
        echo -e "  ${C_DIM}-${NC} Skipped (you can set this up later)"
    fi
fi

# Done!
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${C_SUCCESS}${CHECK}${NC} ${C_TEXT}${BOLD}Installation complete!${NC}"
echo ""

if [[ "$MODE" == "link" ]]; then
    echo -e "  ${C_WARN}${BOLD}Dev mode:${NC} ${C_DIM}Changes in repo take effect immediately${NC}"
    echo -e "  ${C_DIM}Run ${C_ACCENT}./install.sh --update${C_DIM} to rebuild Docker image${NC}"
    echo ""
fi

echo -e "  ${C_DIM}Run ${C_ACCENT}claude-sandbox${C_DIM} or ${C_ACCENT}cs${C_DIM} to start${NC}"
echo ""
echo -e "  ${C_DIM}Tip: Add an alias to your shell config:${NC}"
echo -e "    ${C_TEXT}alias cs=\"claude-sandbox\"${NC}"
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
