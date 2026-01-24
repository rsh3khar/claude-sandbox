# Claude Sandbox

Run [Claude Code](https://claude.ai/code) with `--dangerously-skip-permissions` safely in an isolated Docker container.

![Claude Sandbox](screenshot.png)

## Why?

Claude Code's `--dangerously-skip-permissions` flag lets Claude execute commands without asking for approval - great for productivity, but risky on your main machine. Claude Sandbox gives you the best of both worlds:

- **Full autonomy** - Claude can run any command without interruption
- **Complete isolation** - Container is destroyed after each session
- **Auto-save to GitHub** - Changes are committed every 60s, never lose work
- **SSH forwarding** - Your GitHub credentials work without copying keys

## Features

- Interactive branch selection and creation
- Auto-commit changes to GitHub every 60s
- Beautiful terminal UI with Powerlevel10k
- Python + Node.js support out of the box
- Host network mode - any port just works

## Requirements

- **Docker** - [OrbStack](https://orbstack.dev/) (recommended) or [Docker Desktop](https://docker.com/products/docker-desktop)
- **macOS** or **Linux**
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [Claude Code](https://claude.ai/code) with active subscription

## Installation

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/rsh3khar/claude-sandbox/main/install.sh | bash
```

### Manual

```bash
# Clone the repo
git clone https://github.com/rsh3khar/claude-sandbox.git
cd claude-sandbox

# Run installer
./install.sh
```

The installer will:
1. Check and install dependencies (`gh`, `gum`, `jq`)
2. Build the Docker image
3. Set up Claude Code authentication

### Developer Mode

For contributors who want changes to take effect immediately:

```bash
./install.sh --link    # Symlinks ~/.claude-sandbox to repo
./install.sh --update  # Rebuild Docker image after changes
```

### Other Commands

```bash
./install.sh --help       # Show all options
./install.sh --uninstall  # Remove claude-sandbox completely
./install.sh --skip-deps  # Skip dependency checks
./install.sh --skip-build # Skip Docker image build
```

## Usage

### Interactive Mode

```bash
claude-sandbox
# or
cs  # if you set up the alias
```

This opens an interactive menu to:
- Select a repository from your GitHub account
- Choose or create a branch
- Launch the sandbox

### Direct Mode

```bash
claude-sandbox owner/repo
claude-sandbox git@github.com:owner/repo.git
```

### Inside the Sandbox

```bash
# Start Claude Code (auto-skips permissions)
claude
# or
c

# Your changes auto-commit every 60s
# Just work and let the sandbox handle git
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  Host (macOS/Linux)                                             │
│                                                                 │
│  ┌─────────────────────┐  ┌─────────────────┐  ┌────────────┐  │
│  │ ~/.claude/          │  │ ~/.ssh/         │  │ SSH Agent  │  │
│  │ ├── settings        │  │ (read-only)     │  │ Socket     │  │
│  │ └── screenshots/ ◄──┼──┼─ Cmd+Shift+4    │  │            │  │
│  └──────────┬──────────┘  └────────┬────────┘  └─────┬──────┘  │
│             │                      │                  │         │
└─────────────┼──────────────────────┼──────────────────┼─────────┘
              │ mount                │ mount            │ forward
              ▼                      ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  Container (isolated)                                           │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ ~/workspace/<repo>/     Fresh git clone                   │  │
│  │ ~/.claude/screenshots/  Claude reads screenshots here     │  │
│  │                                                           │  │
│  │ Claude Code (--dangerously-skip-permissions)              │  │
│  │ Auto-git daemon (commits every 60s)                       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Container destroyed on exit - host untouched                   │
└─────────────────────────────────────────────────────────────────┘
```

## Branch Management

When you launch the sandbox, you'll see an interactive branch menu:

```
Select a branch

  1) ● main (current)
  2) ● dev
  3) ◇ sandbox-20260124-155720

  n) New branch (name it yourself)
  q) Quick branch (auto: sandbox-timestamp)
  d) Delete sandbox branches (1 found)

▸ Choice [1]:
```

- **●** = synced with origin
- **◇** = sandbox branch (auto-generated)
- **n)** = create named branch (e.g., "add dark mode" → `feature/add-dark-mode`)
- **q)** = quick sandbox branch with timestamp
- **d)** = bulk delete sandbox branches

## Authentication

Claude Sandbox uses OAuth tokens for Claude Code authentication:

```bash
# Generate a token (valid for 1 year)
claude setup-token

# Save it securely
echo 'YOUR_TOKEN' > ~/.claude-sandbox-token
chmod 600 ~/.claude-sandbox-token
```

The installer will guide you through this.

## Configuration

Files are installed to `~/.claude-sandbox/`:

```
~/.claude-sandbox/
├── Dockerfile       # Container definition
├── claude-sandbox   # Main CLI
├── entrypoint.sh    # Container startup
├── auto-git.sh      # Auto-commit daemon
└── p10k.zsh         # Terminal theme config
```

Token stored at `~/.claude-sandbox-token` (chmod 600).

**Terminal theme:** The container uses a [Powerlevel10k](https://github.com/romkatv/powerlevel10k) config included in `p10k.zsh`. Customize it to change the terminal appearance.

## Running Dev Servers

The container uses `--network host`, so any port works automatically:

```bash
# Frontend (Vite)
cd frontend && npm run dev
# → http://localhost:5173

# Backend (Python)
cd backend && pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
# → http://localhost:8000
```

## Screenshot Sharing

Claude inside the container can't access your clipboard. To share screenshots:

**Option 1: Let installer configure it**

The installer will ask to change your macOS screenshot save location to `~/.claude/screenshots/`. Then:
1. Take screenshot (Cmd+Shift+4)
2. Tell Claude "check the screenshot"

**Option 2: Manual setup**

```bash
mkdir -p ~/.claude/screenshots
defaults write com.apple.screencapture location ~/.claude/screenshots
killall SystemUIServer
```

**Option 3: One-off sharing**

```bash
# Install pngpaste
brew install pngpaste

# Copy clipboard to shared folder
pngpaste ~/.claude/screenshots/shot.png
```

**To restore default screenshot location:**
```bash
defaults write com.apple.screencapture location ~/Desktop
killall SystemUIServer
```

## Troubleshooting

### SSH not working

Make sure your SSH agent is running:
```bash
ssh-add -l  # Should list your keys
```

### Claude asks for login

Your OAuth token might be missing or expired:
```bash
claude setup-token
echo 'NEW_TOKEN' > ~/.claude-sandbox-token
```

### Port not accessible

Make sure you bind to `0.0.0.0`, not `127.0.0.1`:
```bash
# Wrong
npm run dev  # binds to 127.0.0.1

# Right
npm run dev -- --host  # binds to 0.0.0.0
```

## License

MIT - do whatever you want with it.

## Credits

Built with Claude Code, for Claude Code users.
