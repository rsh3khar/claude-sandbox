# Claude Code Sandbox Environment
# Isolated container for running Claude Code with --dangerously-skip-permissions

FROM node:20-bookworm

# Install essential tools + zsh + python
RUN apt-get update && apt-get install -y \
    git \
    curl \
    vim \
    htop \
    ripgrep \
    openssh-client \
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
    && echo '# Python helpers' >> ~/.zshrc \
    && echo 'alias pip="pip3 --break-system-packages"' >> ~/.zshrc

# Pre-configure Claude Code (skip onboarding prompts)
RUN mkdir -p /home/node/.claude \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark"}' > /home/node/.claude.json

# Set zsh as default shell
ENV SHELL=/bin/zsh

# Install Claude Code CLI (native method)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Add claude to PATH
ENV PATH="/home/node/.local/bin:$PATH"

# Create workspace directory
RUN mkdir -p /home/node/workspace
WORKDIR /home/node/workspace

# Copy scripts (need root for this)
USER root
COPY auto-git.sh /usr/local/bin/auto-git
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/auto-git /entrypoint.sh

# Switch back to node user
USER node

ENTRYPOINT ["/entrypoint.sh"]
