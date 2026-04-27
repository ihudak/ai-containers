FROM ubuntu:24.04
LABEL org.opencontainers.image.title="AI Sandbox Container" \
      org.opencontainers.image.description="Isolated Docker workspace for AI coding agents with deny-by-default firewall" \
      org.opencontainers.image.source="https://github.com/ihudak/ai-containers" \
      org.opencontainers.image.licenses="MIT"
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Sandbox user: created at container startup by the entrypoint using
# the SANDBOX_UID/SANDBOX_GID env vars that runme.sh passes automatically
# (defaults to the host user's id -u / id -g).
# No user is baked into the image so that the same image works for every
# team member without rebuilding.

# ── Essential packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  git vim grep mc \
  wget iputils-ping \
  iptables ipset dnsutils \
  openssh-client \
  libcap2-bin \
  unzip zip \
  tcpdump \
  tshark && \
  rm -rf /var/lib/apt/lists/*

# ── nvm + Node.js ───────────────────────────────────────────────────────────────
# nvm is always installed; the latest LTS is always present (required by AI agents).
# NODE_EXTRA_VERSIONS: space-separated list of additional versions to install.
ARG NODE_EXTRA_VERSIONS=""
ENV NVM_DIR=/opt/nvm
# Pin nvm to a release tag for reproducibility and supply-chain safety.
# Configured via nvm-version in sandbox.conf; this default is the fallback.
# Check https://github.com/nvm-sh/nvm/releases for newer versions.
ARG NVM_VERSION=v0.40.4
RUN mkdir -p "$NVM_DIR" && \
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | \
      PROFILE=/dev/null bash && \
    # Always install latest LTS
    bash -c "source $NVM_DIR/nvm.sh && nvm install --lts && nvm alias default 'lts/*'" && \
    # Install any extra versions requested
    if [ -n "$NODE_EXTRA_VERSIONS" ]; then \
      for ver in $NODE_EXTRA_VERSIONS; do \
        bash -c "source $NVM_DIR/nvm.sh && nvm install $ver"; \
      done; \
    fi && \
    # Symlink the default (latest LTS) node/npm/npx into PATH for non-nvm shells
    bash -c "source $NVM_DIR/nvm.sh && \
      ln -sf \$(nvm which default) /usr/local/bin/node && \
      ln -sf \$(dirname \$(nvm which default))/npm /usr/local/bin/npm && \
      ln -sf \$(dirname \$(nvm which default))/npx /usr/local/bin/npx"
# Make nvm available in all bash shells
RUN printf '\nexport NVM_DIR=%s\n[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"\n' "$NVM_DIR" \
      >> /etc/bash.bashrc

# ── SDKMAN + JVM toolchains ─────────────────────────────────────────────────────
# SDKMAN is installed system-wide under /opt/sdkman so it works for any user.
# OPENJDK_VERSIONS / GRAALVM_VERSIONS / KOTLIN_VERSIONS / SCALA_VERSIONS /
# MAVEN_VERSIONS / GRADLE_VERSIONS: space-separated version lists.
ARG INSTALL_SDKMAN=0
ARG OPENJDK_VERSIONS=""
ARG GRAALVM_VERSIONS=""
ARG GRAALVM_ORACLE_VERSIONS=""
ARG KOTLIN_VERSIONS=""
ARG SCALA_VERSIONS=""
ARG MAVEN_VERSIONS=""
ARG GRADLE_VERSIONS=""
ENV SDKMAN_DIR=/opt/sdkman
RUN if [ "$INSTALL_SDKMAN" = "1" ]; then \
      curl -fsSL "https://get.sdkman.io" | SDKMAN_DIR="$SDKMAN_DIR" bash && \
      chmod -R a+rX "$SDKMAN_DIR"; \
    fi
# Install each requested JVM candidate in a separate RUN so layer caching is useful.
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$OPENJDK_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $OPENJDK_VERSIONS; do sdk install java \${ver}-tem; done"; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$GRAALVM_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $GRAALVM_VERSIONS; do sdk install java \${ver}-graalce; done"; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$GRAALVM_ORACLE_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $GRAALVM_ORACLE_VERSIONS; do sdk install java \${ver}-graal; done"; \
    fi
# Set the default JDK once after all JVM installs to avoid race conditions.
# Priority: first OpenJDK version > first GraalVM CE > first GraalVM Oracle.
RUN if [ "$INSTALL_SDKMAN" = "1" ]; then \
      default_id="" && \
      if [ -n "$OPENJDK_VERSIONS" ]; then \
        default_id="$(echo $OPENJDK_VERSIONS | awk '{print $1}')-tem"; \
      elif [ -n "$GRAALVM_VERSIONS" ]; then \
        default_id="$(echo $GRAALVM_VERSIONS | awk '{print $1}')-graalce"; \
      elif [ -n "$GRAALVM_ORACLE_VERSIONS" ]; then \
        default_id="$(echo $GRAALVM_ORACLE_VERSIONS | awk '{print $1}')-graal"; \
      fi && \
      if [ -n "$default_id" ]; then \
        bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && sdk default java $default_id" && \
        ln -sf "$SDKMAN_DIR/candidates/java/current/bin/java"  /usr/local/bin/java && \
        ln -sf "$SDKMAN_DIR/candidates/java/current/bin/javac" /usr/local/bin/javac; \
      fi && \
      # Symlink native-image if any GraalVM variant is installed
      if [ -n "$GRAALVM_VERSIONS" ] || [ -n "$GRAALVM_ORACLE_VERSIONS" ]; then \
        ln -sf "$SDKMAN_DIR/candidates/java/current/bin/native-image" /usr/local/bin/native-image 2>/dev/null || true; \
      fi; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$KOTLIN_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $KOTLIN_VERSIONS; do sdk install kotlin \$ver; done" && \
      ln -sf "$SDKMAN_DIR/candidates/kotlin/current/bin/kotlin"  /usr/local/bin/kotlin && \
      ln -sf "$SDKMAN_DIR/candidates/kotlin/current/bin/kotlinc" /usr/local/bin/kotlinc; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$SCALA_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $SCALA_VERSIONS; do sdk install scala \$ver; done" && \
      ln -sf "$SDKMAN_DIR/candidates/scala/current/bin/scala"  /usr/local/bin/scala && \
      ln -sf "$SDKMAN_DIR/candidates/scala/current/bin/scalac" /usr/local/bin/scalac; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$MAVEN_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $MAVEN_VERSIONS; do sdk install maven \$ver; done" && \
      ln -sf "$SDKMAN_DIR/candidates/maven/current/bin/mvn" /usr/local/bin/mvn; \
    fi
RUN if [ "$INSTALL_SDKMAN" = "1" ] && [ -n "$GRADLE_VERSIONS" ]; then \
      bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
        for ver in $GRADLE_VERSIONS; do sdk install gradle \$ver; done" && \
      ln -sf "$SDKMAN_DIR/candidates/gradle/current/bin/gradle" /usr/local/bin/gradle; \
    fi
# Make SDKMAN available in all bash shells
RUN if [ "$INSTALL_SDKMAN" = "1" ]; then \
      printf '\nexport SDKMAN_DIR=%s\n[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"\n' \
        "$SDKMAN_DIR" >> /etc/bash.bashrc; \
    fi

# ── pyenv + Python ──────────────────────────────────────────────────────────────
# Python is always installed (latest stable). PYTHON_EXTRA_VERSIONS adds more.
ARG PYTHON_EXTRA_VERSIONS=""
ENV PYENV_ROOT=/opt/pyenv
ENV PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
RUN apt-get update && apt-get install -y \
      build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
      libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev \
      libxmlsec1-dev libffi-dev liblzma-dev && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://pyenv.run | PYENV_ROOT="$PYENV_ROOT" bash && \
    chmod -R a+rX "$PYENV_ROOT" && \
    # Always install latest stable Python (sort -V for correct ordering with 3.20+)
    latest=$("$PYENV_ROOT/bin/pyenv" install --list | grep -E '^\s+3\.[0-9]+\.[0-9]+$' | tr -d ' ' | sort -V | tail -1) && \
    "$PYENV_ROOT/bin/pyenv" install "$latest" && \
    "$PYENV_ROOT/bin/pyenv" global "$latest" && \
    # Install extra versions
    if [ -n "$PYTHON_EXTRA_VERSIONS" ]; then \
      for ver in $PYTHON_EXTRA_VERSIONS; do \
        "$PYENV_ROOT/bin/pyenv" install "$ver"; \
      done; \
    fi && \
    # Symlink python3/pip3 into PATH
    ln -sf "$PYENV_ROOT/shims/python3" /usr/local/bin/python3 && \
    ln -sf "$PYENV_ROOT/shims/pip3"    /usr/local/bin/pip3 && \
    # Remove compile-time -dev packages no longer needed after Python is built.
    # Keep runtime libs (libssl3, zlib1g, etc.) that Python links against.
    apt-get purge -y --auto-remove \
      build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
      libsqlite3-dev libncursesw5-dev tk-dev libxml2-dev \
      libxmlsec1-dev libffi-dev liblzma-dev && \
    rm -rf /var/lib/apt/lists/*
RUN printf '\nexport PYENV_ROOT=%s\nexport PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"\n' \
      "$PYENV_ROOT" >> /etc/bash.bashrc

# ── rvm + Ruby (+ Rails) ────────────────────────────────────────────────────────
# rvm is only installed when RUBY_VERSION is set.
ARG RUBY_VERSION=""
ARG RAILS_VERSION=""
RUN if [ -n "$RUBY_VERSION" ]; then \
      apt-get update && apt-get install -y gnupg2 && \
      rm -rf /var/lib/apt/lists/* && \
      # Import RVM GPG keys
      gpg2 --keyserver keyserver.ubuntu.com \
            --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
                        7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
      curl -fsSL https://get.rvm.io | bash -s stable && \
      # Install Ruby
      bash -lc "rvm install $RUBY_VERSION && rvm use $RUBY_VERSION --default" && \
      # Install Rails if requested
      if [ -n "$RAILS_VERSION" ]; then \
        bash -lc "gem install rails -v $RAILS_VERSION --no-document"; \
      fi && \
      # Symlink ruby/gem/bundle into PATH
      ln -sf /usr/local/rvm/rubies/default/bin/ruby /usr/local/bin/ruby && \
      ln -sf /usr/local/rvm/rubies/default/bin/gem  /usr/local/bin/gem; \
    fi
RUN if [ -n "$RUBY_VERSION" ]; then \
      printf '\n[ -s "/usr/local/rvm/scripts/rvm" ] && source "/usr/local/rvm/scripts/rvm"\n' \
        >> /etc/bash.bashrc; \
    fi

# ── rustup + Rust ───────────────────────────────────────────────────────────────
# RUST_TOOLCHAIN: stable | beta | nightly | specific version, or empty to skip.
ARG RUST_TOOLCHAIN=""
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH="$CARGO_HOME/bin:$PATH"
RUN if [ -n "$RUST_TOOLCHAIN" ]; then \
      curl -fsSL https://sh.rustup.rs | \
        RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
        sh -s -- -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN" && \
      chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"; \
    fi
RUN if [ -n "$RUST_TOOLCHAIN" ]; then \
      printf '\nexport RUSTUP_HOME=%s\nexport CARGO_HOME=%s\nexport PATH="$CARGO_HOME/bin:$PATH"\n' \
        "$RUSTUP_HOME" "$CARGO_HOME" >> /etc/bash.bashrc; \
    fi

# ── Go ──────────────────────────────────────────────────────────────────────────
# GO_VERSION: e.g. "1.24.2", or empty to skip.
ARG GO_VERSION=""
ENV GOROOT=/usr/local/go
ENV PATH="$GOROOT/bin:$PATH"
RUN if [ -n "$GO_VERSION" ]; then \
      ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') && \
      curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
        | tar xz -C /usr/local && \
      ln -sf /usr/local/go/bin/go   /usr/local/bin/go && \
      ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    fi

# ── Optional: kubectl ───────────────────────────────────────────────────────────
ARG INSTALL_KUBECTL=1
RUN if [ "$INSTALL_KUBECTL" = "1" ]; then \
      ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') && \
      KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
      curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl" && \
      install kubectl /usr/local/bin/kubectl && rm kubectl; \
    fi

# ── Optional: AWS CLI v2 ────────────────────────────────────────────────────────
ARG INSTALL_AWS_CLI=1
RUN if [ "$INSTALL_AWS_CLI" = "1" ]; then \
      ARCH=$(uname -m) && \
      curl "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip && \
      unzip awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip; \
    fi

# ── Optional: Azure CLI ─────────────────────────────────────────────────────────
ARG INSTALL_AZURE_CLI=0
RUN if [ "$INSTALL_AZURE_CLI" = "1" ]; then \
      curl -sL https://aka.ms/InstallAzureCLIDeb | bash; \
    fi

# ── Optional: GitHub CLI ────────────────────────────────────────────────────────
ARG INSTALL_GITHUB_CLI=1
RUN if [ "$INSTALL_GITHUB_CLI" = "1" ]; then \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
      apt-get update && apt-get install -y gh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: npm-based agent tools ────────────────────────────────────────────
# Each agent gets its own layer so toggling one doesn't invalidate the others.
ARG INSTALL_COPILOT=1
RUN if [ "$INSTALL_COPILOT" = "1" ]; then npm install -g @github/copilot; fi

ARG ANGULAR_CLI_VERSION="latest"
RUN if [ -n "$ANGULAR_CLI_VERSION" ] && [ "$ANGULAR_CLI_VERSION" != "OFF" ]; then \
      if [ "$ANGULAR_CLI_VERSION" = "latest" ]; then \
        npm install -g @angular/cli; \
      else \
        npm install -g "@angular/cli@${ANGULAR_CLI_VERSION}"; \
      fi; \
    fi

ARG INSTALL_CLAUDE_CODE=1
RUN if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then npm install -g @anthropic-ai/claude-code; fi

ARG INSTALL_CODEX=0
RUN if [ "$INSTALL_CODEX" = "1" ]; then npm install -g @openai/codex; fi

ARG INSTALL_GEMINI=0
RUN if [ "$INSTALL_GEMINI" = "1" ]; then npm install -g @google/gemini-cli; fi

ARG INSTALL_YARN=0
RUN if [ "$INSTALL_YARN" = "1" ]; then npm install -g yarn; fi

# ── Optional: Kiro CLI ──────────────────────────────────────────────────────────
ARG INSTALL_KIRO=0
RUN if [ "$INSTALL_KIRO" = "1" ]; then \
      curl -fsSL https://cli.kiro.dev/install | bash && \
      # Copy installed binaries to PATH; find them dynamically in case the
      # installer changes its default location.
      install_dir=$(dirname "$(command -v kiro-cli 2>/dev/null || find /root -name kiro-cli -type f 2>/dev/null | head -1)") && \
      for bin in kiro-cli kiro-cli-chat kiro-cli-term; do \
        [ -f "$install_dir/$bin" ] && cp "$install_dir/$bin" /usr/local/bin/; \
      done && \
      # Verify the install succeeded
      command -v kiro-cli >/dev/null || { echo "ERROR: kiro-cli not found after install"; exit 1; }; \
    fi

# ── Optional: dtctl and dtmgd ───────────────────────────────────────────────────
# DTCTL_VERSION / DTMGD_VERSION:
#   "latest"  = auto-detect latest release from GitHub API
#   "x.y.z"   = install that exact version (no API call, fully reproducible)
#   ""        = skip
# GITHUB_TOKEN is passed as a BuildKit secret (never stored in image layers).
# Set it on the host to avoid GitHub API rate limits when using "latest".
ARG DTCTL_VERSION="latest"
ARG DTMGD_VERSION="latest"
COPY install-dt-tools.sh /tmp/install-dt-tools.sh
RUN --mount=type=secret,id=github_token \
    DTCTL_VERSION="$DTCTL_VERSION" DTMGD_VERSION="$DTMGD_VERSION" \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    bash /tmp/install-dt-tools.sh

COPY refresh-ipset-allowlist.sh /usr/local/bin/
COPY capture-agent-destinations.sh /usr/local/bin/
COPY capture-blocked-traffic.sh /usr/local/bin/
COPY allowlist-domains.txt /tmp/
COPY allowlist-cidrs.txt /tmp/
COPY allowlist-proxy-domains.txt /tmp/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/refresh-ipset-allowlist.sh \
  /usr/local/bin/capture-agent-destinations.sh \
  /usr/local/bin/capture-blocked-traffic.sh \
  /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
WORKDIR /workspace
