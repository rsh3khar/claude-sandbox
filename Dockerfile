# syntax=docker/dockerfile:1.9
#
# Claude Sandbox — isolated container for running coding agents with all
# approval prompts disabled. The container is the security boundary.
#
# Build:  docker buildx build -t claude-sandbox .
# Args:   NODE_VERSION, DEBIAN_SUITE, CLAUDE_CODE_VERSION, CODEX_VERSION

# bookworm-slim, not bookworm: the full node image bundles buildpack-deps
# (subversion, mercurial, every -dev header) for ~880MB that agents never use.
# build-essential is installed explicitly below, so native npm modules still
# compile. Measured: 2.24GB -> 1.71GB.
ARG NODE_VERSION=24
ARG DEBIAN_SUITE=bookworm-slim

FROM node:${NODE_VERSION}-${DEBIAN_SUITE}

ARG TARGETARCH
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG VERSION=dev
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="Claude Sandbox" \
      org.opencontainers.image.description="Isolated container for Claude Code and Codex with permissions disabled" \
      org.opencontainers.image.source="https://github.com/rsh3khar/claude-sandbox" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

# ── System packages ──────────────────────────────────────────────────────────
# apt caches live in BuildKit cache mounts (scoped per-arch so multi-platform
# builds don't race), so we deliberately do NOT rm the lists afterwards.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    fd-find \
    git \
    gnupg \
    htop \
    jq \
    less \
    locales \
    openssh-client \
    procps \
    python3 \
    python3-venv \
    ripgrep \
    sudo \
    tmux \
    unzip \
    vim \
    zsh \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# ── GitHub CLI ───────────────────────────────────────────────────────────────
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh

# ── AWS CLI v2 ───────────────────────────────────────────────────────────────
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# ── Python toolchain ─────────────────────────────────────────────────────────
# A real virtualenv on PATH instead of --break-system-packages / deleting
# EXTERNALLY-MANAGED. `pip install x` just works and the system python is safe.
# uv is included because agents reach for it and it is dramatically faster.
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:/home/node/.local/bin:$PATH"

RUN python3 -m venv "$VIRTUAL_ENV" \
    && "$VIRTUAL_ENV/bin/pip" install --no-cache-dir --upgrade pip boto3 requests \
    && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && chown -R node:node "$VIRTUAL_ENV"

# ── Locale ───────────────────────────────────────────────────────────────────
ENV LANG=en_US.UTF-8 \
    LC_CTYPE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    SHELL=/bin/zsh

# ── Codex CLI ────────────────────────────────────────────────────────────────
# Official native installer (the npm package is no longer the documented path).
# CODEX_HOME is pinned to /opt/codex for the *install* only: the installer
# symlinks the binary into $CODEX_HOME/packages/standalone/current, and at
# runtime we bind-mount the host's ~/.codex over the default location — which
# would replace the Linux binary with the host's macOS one. Runtime CODEX_HOME
# stays unset so config and auth still come from the mounted ~/.codex.
RUN CODEX_HOME=/opt/codex \
    CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_NON_INTERACTIVE=true \
    CODEX_RELEASE="${CODEX_VERSION}" \
    sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && chmod -R a+rX /opt/codex \
    && codex --version

# node user (uid 1000) gets passwordless sudo — it is a disposable sandbox
RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node \
    && chsh -s /bin/zsh node

USER node
WORKDIR /home/node

RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}"

# ── Shell ────────────────────────────────────────────────────────────────────
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

COPY --chown=node:node runtime/p10k.zsh /home/node/.p10k.zsh
COPY --chown=node:node runtime/zshrc /home/node/.zshrc.sandbox

RUN sed -i 's|^ZSH_THEME=".*"|ZSH_THEME="powerlevel10k/powerlevel10k"|' ~/.zshrc \
    && sed -i 's/^plugins=(.*)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc \
    && printf '\n# --- Claude Sandbox ---\nsource ~/.zshrc.sandbox\n' >> ~/.zshrc \
    && mkdir -p /home/node/.claude /home/node/workspace \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark"}' > /home/node/.claude.json

# ── Playwright (browser installed on demand by the entrypoint) ───────────────
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright \
    PLAYWRIGHT_CHROMIUM_SANDBOX=0

USER root
RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" && chown node:node "$PLAYWRIGHT_BROWSERS_PATH"

COPY runtime/auto-git.sh /usr/local/bin/auto-git
COPY runtime/entrypoint.sh /entrypoint.sh
COPY runtime/context/ /usr/local/share/sandbox-context/
RUN chmod +x /usr/local/bin/auto-git /entrypoint.sh

ENV CLAUDE_SANDBOX_IMAGE_VERSION="${VERSION}"

USER node
WORKDIR /home/node/workspace

ENTRYPOINT ["/entrypoint.sh"]
