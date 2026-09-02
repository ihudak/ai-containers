FROM ubuntu:24.04
LABEL org.opencontainers.image.title="AI Sandbox Container" \
      org.opencontainers.image.description="Isolated Docker workspace for AI coding agents with deny-by-default firewall" \
      org.opencontainers.image.source="https://github.com/ihudak/ai-containers" \
      org.opencontainers.image.licenses="MIT"
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Sandbox user: created at container startup by the entrypoint using
# the SANDBOX_UID/SANDBOX_GID env vars that sandbox.sh passes automatically
# (defaults to the host user's id -u / id -g).
# No user is baked into the image so that the same image works for every
# team member without rebuilding.

# ── Essential packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  git vim grep mc jq \
  wget iputils-ping \
  rsync \
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
ARG NVM_VERSION=v0.40.7
# RETRIED, AND FETCHED BEFORE IT IS RUN. raw.githubusercontent.com fails
# intermittently: measured 2026-08-31, several builds in one morning could not
# fetch v0.40.6 while v0.40.7 succeeded, and v0.40.6 worked again later. Nothing
# about the tag had changed. `--retry-all-errors` because the failures are not
# only the transient classes curl retries by default; a genuinely missing tag
# still fails, five attempts later and no less clearly.
#
# `-f` IS A PRECONDITION OF ALL OF THAT, not a tidiness flag. Without it curl
# treats an HTTP error as a successful transfer of an error page: it exits 0,
# writes the body to the output file, and `--retry-all-errors` has nothing to
# retry because nothing failed. Three fetches here shipped in exactly that
# state — kubectl, aws-cli and azure-cli — so the retry they were given was
# inert, and `curl -LO` on a 404 left a 260-byte XML error document that
# `install kubectl /usr/local/bin/kubectl` then installed as the binary.
# Measured, not reasoned: without `-f`, rc=0 and the file is the error page;
# with it, rc=22 and the transfer is retried.
#
# `-o` then `bash FILE`, not `curl | bash`: a pipe hands bash whatever arrived,
# so a TRUNCATED download executes its prefix and reports success. With a file,
# a short read is curl's failure and the build stops there.
# RETRY THE INSTALLER, NOT ONLY ITS DOWNLOAD. The curl below is retried; what it
# downloads is not. nvm's install.sh defaults to install_nvm_from_git, which runs
# a bare `git clone --depth=1` against github.com with no retry of its own.
#
# Measured 2026-09-02, not reasoned: `fatal: could not read Username for
# 'https://github.com'` — GitHub answering an unauthenticated clone of a PUBLIC
# repo with 401, which is what it does when rate-limiting an IP — failed all
# three image variants and therefore all 36 integration cases, and the identical
# build succeeded on the next attempt with nothing changed. The v0.40.6 incident
# was the same class reached from the other side.
#
# v0.9.9 decided a build-time fetch must survive a transient failure;
# tests/test-build-fetch-retry.sh enforces that for every `curl` and CANNOT see a
# fetch a vendor's own installer makes. This loop is where that gap is closed for
# the one installer with recorded failures.
#
# A CLEAN SLATE PER ATTEMPT is load-bearing: a half-finished clone leaves
# $NVM_DIR/.git behind, and install.sh then takes its "already installed" branch
# and fetches into a repository that may be broken — so a retry over the debris
# of the previous attempt is not a retry. `nvm install --lts` sits inside the
# loop for the same reason the clone does (it downloads from nodejs.org) and is
# idempotent given that reset.
RUN --mount=type=secret,id=github_token \
    if [ -s /run/secrets/github_token ]; then \
      GH_TOKEN="$(cat /run/secrets/github_token)"; export GH_TOKEN; \
      export GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="credential.https://github.com.helper" \
        GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'; \
    fi; \
    mkdir -p "$NVM_DIR" && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      -o /tmp/nvm-install.sh \
      "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" && \
    for attempt in 1 2 3 4 5; do \
      rm -rf "$NVM_DIR"; mkdir -p "$NVM_DIR"; \
      if PROFILE=/dev/null bash /tmp/nvm-install.sh && \
         bash -c "source $NVM_DIR/nvm.sh && nvm install --lts && nvm alias default 'lts/*'"; then \
        break; \
      fi; \
      if [ "$attempt" = 5 ]; then \
        echo "nvm bootstrap failed after 5 attempts" >&2; exit 1; \
      fi; \
      sleep $((attempt * 15)); \
    done && \
    rm -f /tmp/nvm-install.sh && \
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
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/sdkman.sh "https://get.sdkman.io" && \
      SDKMAN_DIR="$SDKMAN_DIR" bash /tmp/sdkman.sh && rm -f /tmp/sdkman.sh && \
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
      # Symlink native-image from the actual GraalVM installation directory,
      # not java/current (which may point to a non-GraalVM JDK like Temurin).
      if [ -n "$GRAALVM_VERSIONS" ]; then \
        graal_id="$(echo $GRAALVM_VERSIONS | awk '{print $1}')-graalce"; \
        ln -sf "$SDKMAN_DIR/candidates/java/$graal_id/bin/native-image" /usr/local/bin/native-image 2>/dev/null || true; \
      elif [ -n "$GRAALVM_ORACLE_VERSIONS" ]; then \
        graal_id="$(echo $GRAALVM_ORACLE_VERSIONS | awk '{print $1}')-graal"; \
        ln -sf "$SDKMAN_DIR/candidates/java/$graal_id/bin/native-image" /usr/local/bin/native-image 2>/dev/null || true; \
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
# RETRY THE INSTALLER, NOT ONLY ITS DOWNLOAD — the second installer to need it.
# The curl below is retried; what it downloads is not. `https://pyenv.run` is a
# 270-byte SHIM whose entire body is `curl -s -S -L .../pyenv-installer | bash`,
# and that real installer runs FOUR bare `git clone`s — pyenv, pyenv-doctor,
# pyenv-update, pyenv-virtualenv — none of them retried.
#
# Measured 2026-09-02, not reasoned: the first of those four answered `fatal:
# could not read Username for 'https://github.com'` — GitHub answering an
# unauthenticated clone of a PUBLIC repo with 401, which is what it does when
# rate-limiting an IP — and failed the build here. That is the same window and
# the same shape that took the nvm layer above; see its block for why the rule
# in tests/test-build-fetch-retry.sh cannot see a fetch a vendor installer makes.
#
# A CLEAN SLATE PER ATTEMPT IS LOAD-BEARING, for a STRONGER reason than nvm's.
# pyenv-installer refuses to run at all when $PYENV_ROOT exists — "Can not
# proceed with installation. Kindly remove the '...' directory first.", exit 1,
# before it touches the network. With four clones, a partially populated
# $PYENV_ROOT is the LIKELY shape of a rate-limited failure rather than an edge
# case: clone 1 succeeds, clone 3 takes the 401, the directory is left behind.
# Without the reset, attempts 2 and 3 would then fail deterministically — a loop
# that converts one transient 401 into three.
#
# THE TOKEN IS THE HEADROOM; THE LOOP ONLY BUYS TIME. Both clone layers mount the
# same `github_token` BuildKit secret install-tools.sh already uses, and configure
# git to present it when it is there. It stays OPTIONAL — with no secret the
# clones are anonymous exactly as before, so this repo's "GITHUB_TOKEN is a
# rate-limit convenience, never a requirement" position is unchanged.
#
# IT IS A CREDENTIAL HELPER, NOT A URL REWRITE, on purpose: an
# `url.https://x-access-token:$TOK@github.com/.insteadOf` rewrite puts the token
# INSIDE the remote URL, and git prints that URL in some failure messages — which
# would publish the token into the build log, the one place a BuildKit secret is
# meant never to reach. The helper keeps it in env only. Env set inside a RUN
# does not persist into the image, and a secret mount is not a layer.
#
# THE BUDGET IS 5 ATTEMPTS OVER ~150s OF BACKOFF, AND THAT NUMBER IS MEASURED.
# The first version of this loop was 3 attempts over 30s, copied from nvm's. It
# ran against the real window on 2026-09-02 and FAILED ALL THREE: 401 at t=35s,
# t=45s and t=65s of the build, ~31s apart end to end. The identical clone
# succeeded 119s later, from the same host and the same daemon, inside a
# `docker build` — so the window outlasted a 30s budget and had cleared within
# the following two minutes. A retry budget shorter than the transient it exists
# to survive is a loop that only makes the failure take longer to arrive, which
# is what 3x10s was. nvm's loop carries the same budget for the same reason and
# was widened with this one; its numbers had never met a real window.
#
# NOTE THE ASYMMETRY WITH NVM: that loop resets with `rm -rf` THEN `mkdir -p`,
# because install.sh needs $NVM_DIR to exist. Here the mkdir would trip the very
# refusal above, so there must not be one. The guard asserts both directions.
RUN --mount=type=secret,id=github_token \
    if [ -s /run/secrets/github_token ]; then \
      GH_TOKEN="$(cat /run/secrets/github_token)"; export GH_TOKEN; \
      export GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="credential.https://github.com.helper" \
        GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
      libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev \
      libxmlsec1-dev libffi-dev liblzma-dev && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/pyenv.sh https://pyenv.run && \
    for attempt in 1 2 3 4 5; do \
      rm -rf "$PYENV_ROOT"; \
      if PYENV_ROOT="$PYENV_ROOT" bash /tmp/pyenv.sh; then \
        break; \
      fi; \
      if [ "$attempt" = 5 ]; then \
        echo "pyenv bootstrap failed after 5 attempts" >&2; exit 1; \
      fi; \
      sleep $((attempt * 15)); \
    done && \
    rm -f /tmp/pyenv.sh && \
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
    # Symlink python3/pip3/uvx into PATH
    ln -sf "$PYENV_ROOT/shims/python3" /usr/local/bin/python3 && \
    ln -sf "$PYENV_ROOT/shims/pip3"    /usr/local/bin/pip3 && \
    pip3 install uv && \
    ln -sf "$PYENV_ROOT/shims/uvx" /usr/local/bin/uvx
RUN printf '\nexport PYENV_ROOT=%s\nexport PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"\n' \
      "$PYENV_ROOT" >> /etc/bash.bashrc

# ── rustup + Rust ───────────────────────────────────────────────────────────────
# RUST_TOOLCHAIN: stable | beta | nightly | specific version, or empty to skip.
ARG RUST_TOOLCHAIN=""
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH="$CARGO_HOME/bin:$PATH"
RUN if [ -n "$RUST_TOOLCHAIN" ]; then \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/rustup.sh https://sh.rustup.rs && \
        RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
        sh /tmp/rustup.sh -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN" && \
      rm -f /tmp/rustup.sh && \
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
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
        | tar xz -C /usr/local && \
      ln -sf /usr/local/go/bin/go   /usr/local/bin/go && \
      ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    fi
# Add ~/go/bin to PATH for all users so `go install` tools are immediately usable.
RUN if [ -n "$GO_VERSION" ]; then \
      printf '\n# Go: add go install tools to PATH\nexport PATH="$HOME/go/bin:$PATH"\n' \
        >> /etc/bash.bashrc; \
    fi

# ── GoReleaser ──────────────────────────────────────────────────────────────────
ARG INSTALL_GORELEASER=0
RUN if [ "$INSTALL_GORELEASER" = "1" ]; then \
      echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' \
        > /etc/apt/sources.list.d/goreleaser.list && \
      apt-get update && apt-get install -y --no-install-recommends goreleaser && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Cleanup: remove compile-time -dev packages ─────────────────────────────────
# Deferred from the pyenv layer so that rvm/Ruby and Rust (which need gcc/make)
# can build successfully. Keep runtime libs (libssl3, zlib1g, etc.).
RUN apt-get purge -y --auto-remove \
      build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
      libsqlite3-dev libncursesw5-dev tk-dev libxml2-dev \
      libxmlsec1-dev libffi-dev liblzma-dev 2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/*

# ── Optional: kubectl ───────────────────────────────────────────────────────────
ARG INSTALL_KUBECTL=0
RUN if [ "$INSTALL_KUBECTL" = "1" ]; then \
      ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') && \
      KUBE_VERSION=$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://dl.k8s.io/release/stable.txt) && \
      curl -fLO --retry 5 --retry-delay 2 --retry-all-errors "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl" && \
      install kubectl /usr/local/bin/kubectl && rm kubectl; \
    fi

# ── Optional: AWS CLI v2 ────────────────────────────────────────────────────────
ARG INSTALL_AWS_CLI=0
RUN if [ "$INSTALL_AWS_CLI" = "1" ]; then \
      ARCH=$(uname -m) && \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip && \
      unzip awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip; \
    fi

# ── Optional: Azure CLI ─────────────────────────────────────────────────────────
ARG INSTALL_AZURE_CLI=0
RUN if [ "$INSTALL_AZURE_CLI" = "1" ]; then \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/azcli.sh https://aka.ms/InstallAzureCLIDeb && \
      bash /tmp/azcli.sh && rm -f /tmp/azcli.sh; \
    fi

# ── Optional: GitHub CLI ────────────────────────────────────────────────────────
ARG INSTALL_GITHUB_CLI=0
RUN if [ "$INSTALL_GITHUB_CLI" = "1" ]; then \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
      apt-get update && apt-get install -y --no-install-recommends gh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── DB client libraries + CLIs (general, reusable) ──────────────────────────────
# DB_CLIENTS: space-separated subset of {pg mysql mongo}. Installs CLIENT/dev
# libs and shells ONLY — never database servers. libpq/mysql are Ubuntu-main;
# mongosh comes from MongoDB's official apt repo.
ARG DB_CLIENTS=""
RUN if [ -n "$DB_CLIENTS" ]; then \
      apt-get update; \
      for c in $DB_CLIENTS; do \
        case "$c" in \
          pg) \
            apt-get install -y --no-install-recommends libpq-dev postgresql-client ;; \
          mysql) \
            apt-get install -y --no-install-recommends default-libmysqlclient-dev default-mysql-client ;; \
          mongo) \
            curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://pgp.mongodb.com/server-8.0.asc \
              | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg && \
            echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
              > /etc/apt/sources.list.d/mongodb-org-8.0.list && \
            apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh ;; \
          *) echo "WARNING: unknown db-client '$c' — skipping" >&2 ;; \
        esac; \
      done; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Retain a runtime build toolchain (native extensions build at runtime) ───────
# The cleanup layer above purged build-essential. Ruby gems (pg, bcrypt, ...),
# DB driver gems, and Python source wheels compile at runtime, so put a minimal
# toolchain back when KEEP_BUILD_TOOLCHAIN=1 — set by build.sh for ruby, db-clients OR
# c-toolchain. This layer deliberately does not know WHICH: the arg is the whole
# interface, which is what lets `c-toolchain=ON` alone be sound without an image
# variant built to prove it (backlog F60).
ARG KEEP_BUILD_TOOLCHAIN=0
RUN if [ "$KEEP_BUILD_TOOLCHAIN" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        build-essential libyaml-dev zlib1g-dev libssl-dev && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: ImageMagick ───────────────────────────────────────────────────────
ARG INSTALL_IMAGEMAGICK=0
RUN if [ "$INSTALL_IMAGEMAGICK" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends imagemagick && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: wkhtmltopdf runtime libs + standalone binary ───────────────────────
# Installs the Qt/X11/font libraries the wkhtmltopdf binary links against (so a
# gem-vendored binary can run) AND the official standalone binary (so non-Ruby
# projects get a working wkhtmltopdf). No conflict: wicked_pdf points at its own
# gem binary; a system binary on PATH does not override it.
ARG INSTALL_WKHTMLTOPDF=0
RUN if [ "$INSTALL_WKHTMLTOPDF" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        libxrender1 libxext6 libx11-6 libfontconfig1 libjpeg-turbo8 \
        fontconfig xfonts-base xfonts-75dpi && \
      ARCH="$(dpkg --print-architecture)" && \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/wkhtmltox.deb \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${ARCH}.deb" && \
      apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb && \
      rm -f /tmp/wkhtmltox.deb && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: Playwright browser OS dependencies ────────────────────────────────
# Installs the shared libraries and fonts Playwright's browsers link against —
# NOT the browsers themselves, which are ~500 MB fetched at container run time
# into the group-mounted ~/.cache/ms-playwright.
#
# THIS LAYER IS THE ONLY PLACE THIS CAN HAPPEN. entrypoint.sh permanently drops
# root via `capsh --user=` before the agent shell exists, so no runtime reconcile
# — the pattern the agent-tier tools and rvm use — can apt-get anything.
#
# The package list is Playwright's, not ours: `install-deps` reads the version's
# own dependency table for the detected distro. Hardcoding it here would rot
# silently against both new Playwright releases and Ubuntu's package renames
# (the t64 transition moved most of this set).
#
# The arg is the WHOLE interface: this layer reads no other build arg, which is
# what lets integration case 770 prove `PLAYWRIGHT_VERSION=<v> -> working deps`
# once and have it hold for every value the key can take (the same composition
# argument test-db-clients.sh makes for KEEP_BUILD_TOOLCHAIN, backlog F60).
# EMPTY is the skip — build.sh normalises both OFF and an unset key to it.
#
# Placed after the cleanup purge above, alongside imagemagick/wkhtmltopdf. One
# purge runs LATER than this layer: the qmd layer's, gated on INSTALL_QMD=1 AND
# KEEP_BUILD_TOOLCHAIN!=1. `install-deps` installs these packages explicitly, so
# apt marks them manual and `--auto-remove` does not reclaim them.
#
# THAT ARGUMENT IS REASONED, NOT OBSERVED, and this comment previously claimed
# integration case 730 observed it. It does not: no image any case builds
# reaches that purge at all — `native` sets KEEP_BUILD_TOOLCHAIN=1 (via ruby and
# db-clients) and leaves qmd=OFF, so its condition is false there, and the same
# was true of the wkhtmltopdf precedent cited as evidence. The one configuration
# that exercises it is `playwright=ON qmd=ON` with no ruby/db-clients/c-toolchain,
# which nothing in the corpus builds.
#
# The RESOLVED version is recorded at /etc/ai-containers-playwright-version. `ON`
# means "latest at build time", so the image cannot otherwise say which
# dependency list it was built against — and integration case 770 needs exactly
# that: it asks Playwright which packages this version wants and checks the image
# has them. Asking `playwright@latest` at case-run time instead would compare the
# image against a list published after it was built, and fail for drift rather
# than for a defect. `awk 'NR==1{print $NF}'` rather than stripping a literal
# "Version " prefix, so a change to that prefix does not silently empty the file
# — and NR==1 because a bare `{print $NF}` prints the last field of EVERY line,
# so one stray npm notice on stdout would write a multi-line marker that `test
# -s` still accepts;
# the `test -s` then fails the BUILD if it somehow did, rather than shipping an
# image whose only evidence of this layer is an empty file.
ARG PLAYWRIGHT_VERSION=
RUN if [ -n "$PLAYWRIGHT_VERSION" ]; then \
      apt-get update && \
      npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps && \
      npx --yes "playwright@${PLAYWRIGHT_VERSION}" --version \
        | awk 'NR==1{print $NF}' > /etc/ai-containers-playwright-version && \
      test -s /etc/ai-containers-playwright-version && \
      rm -rf /var/lib/apt/lists/* /root/.npm; \
    fi

# ── shellcheck ─────────────────────────────────────────────────────────────────
# From Ubuntu's own archive, deliberately, not a pinned upstream release: this
# base is ubuntu:24.04 and CI pins `runs-on: ubuntu-24.04`, so apt hands back the
# SAME shellcheck the lint gate runs. Matching the gate is worth more here than
# being current — a newer binary reports findings the gate does not, and time
# spent on those is time spent on a lint nobody is blocked by.
#
# After the cleanup purge above, alongside imagemagick/wkhtmltopdf/playwright.
# `apt-get install` marks it manual, so the later qmd-layer purge's --auto-remove
# does not reclaim it.
ARG INSTALL_SHELLCHECK=0
RUN if [ "$INSTALL_SHELLCHECK" = "1" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends shellcheck && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Ruby runtime prerequisites (rvm is a per-user install at ~/.rvm, done at
# container start; nothing Ruby is baked). Retain the FULL ruby-build dependency
# set so `rvm install` compiles Ruby at runtime, pre-seed rvm's GPG keys so the
# runtime installer needs no keyserver, and bake a $HOME-relative conditional
# rc-source line (no runtime /etc write needed).
ARG RUBY_RUNTIME=0
# build.sh always co-sets KEEP_BUILD_TOOLCHAIN=1 when RUBY_RUNTIME=1 (ruby implies both,
# build.sh:231/239), and that earlier layer already installs build-essential / libssl-dev /
# libyaml-dev / zlib1g-dev — so this layer installs only the ruby-build-specific extras.
RUN if [ "$RUBY_RUNTIME" = "1" ]; then \
      if [ "$KEEP_BUILD_TOOLCHAIN" != "1" ]; then echo "ERROR: RUBY_RUNTIME=1 requires KEEP_BUILD_TOOLCHAIN=1 (build.sh co-sets them; this layer relies on that layer's build-essential/libssl-dev/libyaml-dev/zlib1g-dev)" >&2; exit 1; fi; \
      apt-get update && apt-get install -y --no-install-recommends \
        gnupg2 ca-certificates procps \
        autoconf bison patch \
        libreadline-dev libncurses-dev libffi-dev libgdbm-dev \
        libsqlite3-dev sqlite3 libgmp-dev libtool && \
      rm -rf /var/lib/apt/lists/* && \
      # Pre-seed rvm signing keys into /etc/skel so every sandbox user inherits
      # them and the runtime `rvm` installer skips the keyserver fetch.
      install -d -m 700 /etc/skel/.gnupg && \
      GNUPGHOME=/etc/skel/.gnupg gpg2 --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
                    7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
      chmod -R go-rwx /etc/skel/.gnupg && \
      # Source a per-user rvm when present (login + interactive shells).
      # The rvm_stored_umask line is what rvm's own modern loader sets, and rvm
      # checks for it BY NAME: without it, every bootstrap prints "your RVM loading
      # script /etc/profile.d/rvm.sh is deprecated and causes you to have umask g+w
      # set in your shell". That warning is a false positive here — it is a pure
      # heuristic (grep for this variable) and never measures a umask. The `umask
      # g+w` it describes came from the old SYSTEM-WIDE multi-user rvm loader, which
      # made a shared /usr/local/rvm group-writable; this is a per-user install and
      # the line below sets no umask. Capturing the umask before sourcing is also
      # what rvm expects a loader to do (__rvm_call_with_restored_umask restores it),
      # so this is the correct loader, not just a way to silence the check.
      printf '%s\n%s\n' \
        '[ -n "${rvm_stored_umask:-}" ] || export rvm_stored_umask=$(umask)' \
        '[ -s "$HOME/.rvm/scripts/rvm" ] && source "$HOME/.rvm/scripts/rvm"' \
        > /etc/profile.d/rvm.sh && \
      printf '\n%s\n' '[ -s "$HOME/.rvm/scripts/rvm" ] && source "$HOME/.rvm/scripts/rvm"' \
        >> /etc/bash.bashrc; \
    fi

# Ship the runtime rvm reconcile script (invoked by entrypoint as the sandbox user).
COPY rvm-reconcile.sh /usr/local/bin/rvm-reconcile.sh
RUN chmod +x /usr/local/bin/rvm-reconcile.sh

# Ship the default-Ruby linker (invoked by entrypoint as root, after the reconcile,
# to expose ruby/gem/bundle on /usr/local/bin for non-interactive shells).
COPY link-default-ruby.sh /usr/local/bin/link-default-ruby.sh
RUN chmod +x /usr/local/bin/link-default-ruby.sh

# ── Agent-tier tool home (runtime-installed into the group-mounted ~/.ai-tools) ──
# Bake only scaffolding: PATH + uv env for login/interactive shells, the ~/.local/bin
# dir Claude Code's native path uses, and a tiny `npm-agent-tools` wrapper function
# (below). No baked npm prefix/globalconfig here on purpose: a $HOME/.npmrc `prefix=`
# line makes nvm's `nvm_die_on_prefix` check fail `nvm use <version>` outright (not
# just print a warning), breaking the node= multi-version workflow sandbox.conf
# advertises. agent-tools-reconcile.sh instead passes `--prefix` per npm invocation,
# which nvm does not object to — it inspects .npmrc/$PREFIX/$NPM_CONFIG_PREFIX, never
# a command's own flags. `npm-agent-tools` is a shell function, not an exported env
# var, so it preserves the `npm update -g` self-update workflow (see AGENTS.md)
# without exporting NPM_CONFIG_PREFIX globally, which would trip that same nvm check.
# The six tools (Claude Code, Codex, Gemini, Copilot, graphify, Vale) install at
# container start via agent-tools-reconcile.sh; nothing agent-tier is baked.
RUN install -d /etc/skel/.local/bin && \
    printf '%s\n' \
      'export UV_TOOL_DIR="$HOME/.ai-tools/uv"' \
      'export UV_TOOL_BIN_DIR="$HOME/.ai-tools/uv/bin"' \
      'export PATH="$HOME/.ai-tools/npm/bin:$HOME/.ai-tools/uv/bin:$HOME/.ai-tools/bin:$HOME/.local/bin:$PATH"' \
      'npm-agent-tools() { npm --prefix "$HOME/.ai-tools/npm" "$@"; }' \
      | tee /etc/profile.d/ai-tools.sh >> /etc/bash.bashrc

# Ship the runtime agent-tool scripts (invoked by entrypoint: reconcile as the sandbox
# user, linker as root).
COPY agent-tools-reconcile.sh /usr/local/bin/agent-tools-reconcile.sh
COPY link-agent-tools.sh /usr/local/bin/link-agent-tools.sh
RUN chmod +x /usr/local/bin/agent-tools-reconcile.sh /usr/local/bin/link-agent-tools.sh

# ── Agent CLIs are NOT baked — they install at container start into ~/.ai-tools ──

ARG ANGULAR_CLI_VERSION=""
RUN if [ -n "$ANGULAR_CLI_VERSION" ] && [ "$ANGULAR_CLI_VERSION" != "OFF" ]; then \
      if [ "$ANGULAR_CLI_VERSION" = "latest" ]; then \
        npm install -g @angular/cli; \
      else \
        npm install -g "@angular/cli@${ANGULAR_CLI_VERSION}"; \
      fi; \
    fi

ARG INSTALL_YARN=0
RUN if [ "$INSTALL_YARN" = "1" ]; then npm install -g yarn; fi

# pnpm — installed globally as root at build time (mirrors yarn). corepack ships
# with Node, but a non-root sandbox user can't `corepack enable` / `npm i -g` at
# runtime because the nvm Node dir is root-owned, so pnpm is baked in instead.
ARG INSTALL_PNPM=0
RUN if [ "$INSTALL_PNPM" = "1" ]; then npm install -g pnpm; fi

ARG INSTALL_QMD=0
# @tobilu/qmd pulls in tree-sitter, which compiles native addons via node-gyp.
# build-essential was purged in the cleanup layer above, so reinstall the toolchain
# just for this layer. Purge it again to keep the image lean — but ONLY when the
# runtime toolchain isn't needed: ruby, db-clients or c-toolchain set KEEP_BUILD_TOOLCHAIN=1 and rely
# on build-essential surviving for runtime native compilation, so keep it then.
RUN if [ "$INSTALL_QMD" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends build-essential && \
      npm install -g @tobilu/qmd && \
      if [ "$KEEP_BUILD_TOOLCHAIN" != "1" ]; then apt-get purge -y --auto-remove build-essential; fi && \
      rm -rf /var/lib/apt/lists/*; \
    fi

ARG INSTALL_BUN=0
RUN if [ "$INSTALL_BUN" = "1" ]; then \
      npm install -g bun && \
      BUN_NATIVE=$(find "$(npm root -g)/bun" -name "bun" -executable -type f 2>/dev/null | grep -v musl | head -1) && \
      [ -n "$BUN_NATIVE" ] && ln -sf "$BUN_NATIVE" /usr/local/bin/bun || true; \
    fi

# ── Optional: Kiro CLI ──────────────────────────────────────────────────────────
ARG INSTALL_KIRO=0
RUN if [ "$INSTALL_KIRO" = "1" ]; then \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/kiro.sh https://cli.kiro.dev/install && \
      bash /tmp/kiro.sh && rm -f /tmp/kiro.sh && \
      # Copy installed binaries to PATH; find them dynamically in case the
      # installer changes its default location.
      install_dir=$(dirname "$(command -v kiro-cli 2>/dev/null || find /root -name kiro-cli -type f 2>/dev/null | head -1)") && \
      if [ -z "$install_dir" ] || [ "$install_dir" = "." ]; then \
        echo "ERROR: kiro-cli install location not found"; exit 1; \
      fi && \
      for bin in kiro-cli kiro-cli-chat kiro-cli-term; do \
        [ -f "$install_dir/$bin" ] && cp "$install_dir/$bin" /usr/local/bin/; \
      done && \
      # Verify the install succeeded
      command -v kiro-cli >/dev/null || { echo "ERROR: kiro-cli not found after install"; exit 1; }; \
    fi

# ── Optional external tools (dtctl / dtmgd / …) ─────────────────────────────────
# Driven by TOOL_VERSIONS ("name=version;…"), generated by build.sh from
# sandbox.conf + tools.d/. Public tools install unauthenticated; private tools
# (private=yes) require the github_token BuildKit secret. See tools.d/*.conf.
ARG TOOL_VERSIONS=""
COPY tools.d /etc/ai-containers/tools.d
COPY tools-lib.sh /etc/ai-containers/tools-lib.sh
COPY install-tools.sh /tmp/install-tools.sh
RUN --mount=type=secret,id=github_token \
    TOOL_VERSIONS="$TOOL_VERSIONS" \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    bash /tmp/install-tools.sh
COPY install-agent-skills.sh /usr/local/bin/install-agent-skills.sh
RUN chmod +x /usr/local/bin/install-agent-skills.sh

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

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
