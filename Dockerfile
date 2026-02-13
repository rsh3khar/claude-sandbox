# Claude Code Sandbox Environment
# Isolated container for running Claude Code with --dangerously-skip-permissions

FROM node:20-bookworm

# Install essential tools + zsh + python + gh
RUN apt-get update && apt-get install -y \
    git \
    curl \
    vim \
    htop \
    ripgrep \
    jq \
    openssh-client \
    tmux \
    zsh \
    locales \
    sudo \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && ln -s /usr/bin/python3 /usr/bin/python

# Pre-install common Python packages and remove pip restriction
RUN pip3 install --break-system-packages boto3 requests \
    && rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Set locale
ENV LANG=en_US.UTF-8
ENV LC_CTYPE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Use existing node user (uid 1000), give sudo access
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && chsh -s /bin/zsh node

# Switch to node user for remaining setup
USER node
WORKDIR /home/node

# Install Oh-My-Zsh + Powerlevel10k + plugins
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k \
    && git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

# Copy Powerlevel10k config (customize p10k.zsh to change terminal theme)
COPY --chown=node:node p10k.zsh /home/node/.p10k.zsh

# Configure zshrc
RUN sed -i 's|^ZSH_THEME=".*"|ZSH_THEME="powerlevel10k/powerlevel10k"|' ~/.zshrc \
    && sed -i 's/plugins=(.*)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc \
    && echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> ~/.zshrc \
    && echo '' >> ~/.zshrc \
    && echo '# Claude sandbox aliases' >> ~/.zshrc \
    && echo 'alias claude="claude --dangerously-skip-permissions"' >> ~/.zshrc \
    && echo 'alias c="claude --dangerously-skip-permissions"' >> ~/.zshrc \
    && echo '' >> ~/.zshrc \
    && echo '# Codex sandbox aliases' >> ~/.zshrc \
    && echo 'alias codex="command codex -a never -s danger-full-access"' >> ~/.zshrc \
    && echo 'alias x="command codex -a never -s danger-full-access"' >> ~/.zshrc \
    && echo '' >> ~/.zshrc \
    && echo '# Python helpers' >> ~/.zshrc \
    && echo 'alias pip="pip3 --break-system-packages"' >> ~/.zshrc

# Pre-configure Claude Code (skip onboarding prompts)
RUN mkdir -p /home/node/.claude \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark"}' > /home/node/.claude.json

# Set zsh as default shell
ENV SHELL=/bin/zsh

# Install Claude Code CLI (native method)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Install OpenAI Codex CLI (needs root for global install)
# Use @latest to ensure newest version on each build
USER root
RUN npm install -g @openai/codex@latest

# Playwright env vars (browser installed on-demand via entrypoint when ENABLE_BROWSER is set)
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright
ENV PLAYWRIGHT_CHROMIUM_SANDBOX=0

USER node

# Add claude to PATH
ENV PATH="/home/node/.local/bin:$PATH"

# Create workspace directory
RUN mkdir -p /home/node/workspace
WORKDIR /home/node/workspace

# Copy scripts and templates (need root for this)
USER root
COPY auto-git.sh /usr/local/bin/auto-git
COPY entrypoint.sh /entrypoint.sh
COPY sandbox-context.md /usr/local/share/sandbox-context.md
RUN chmod +x /usr/local/bin/auto-git /entrypoint.sh

# Switch back to node user
USER node

ENTRYPOINT ["/entrypoint.sh"]
