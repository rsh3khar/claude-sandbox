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

echo ""
echo -e "${C_ACCENT}${BOLD}◈ CLAUDE SANDBOX INSTALLER${NC}"
echo ""
echo -e "${C_DIM}Run Claude Code with --dangerously-skip-permissions${NC}"
echo -e "${C_DIM}safely in an isolated Docker container${NC}"
echo ""

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

# Check dependencies
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

# Install location
INSTALL_DIR="$HOME/.claude-sandbox"
BIN_DIR="$HOME/.local/bin"

echo -e "${C_TEXT}Installing to ${C_ACCENT}${INSTALL_DIR}${NC}..."
echo ""

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

# Get script directory (where install.sh lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy files
cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/claude-sandbox" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/entrypoint.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/auto-git.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/p10k.zsh" "$INSTALL_DIR/"

# Make executable
chmod +x "$INSTALL_DIR/claude-sandbox"
chmod +x "$INSTALL_DIR/entrypoint.sh"
chmod +x "$INSTALL_DIR/auto-git.sh"

echo -e "  ${C_SUCCESS}${CHECK}${NC} Copied files to ${INSTALL_DIR}"

# Create symlink
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

# Build Docker image
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

# Claude Code authentication
echo ""
echo -e "${C_TEXT}Claude Code authentication...${NC}"
echo ""

if [[ -f "$HOME/.claude-sandbox-token" ]]; then
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
            echo "$TOKEN" > "$HOME/.claude-sandbox-token"
            chmod 600 "$HOME/.claude-sandbox-token"
            echo ""
            echo -e "  ${C_SUCCESS}${CHECK}${NC} Token saved to ~/.claude-sandbox-token"
        fi
    fi
fi

# Done!
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${C_SUCCESS}${CHECK}${NC} ${C_TEXT}${BOLD}Installation complete!${NC}"
echo ""
echo -e "  ${C_DIM}Run ${C_ACCENT}claude-sandbox${C_DIM} or ${C_ACCENT}cs${C_DIM} to start${NC}"
echo ""
echo -e "  ${C_DIM}Tip: Add an alias to your shell config:${NC}"
echo -e "    ${C_TEXT}alias cs=\"claude-sandbox\"${NC}"
echo ""
echo -e "${C_SUCCESS}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
