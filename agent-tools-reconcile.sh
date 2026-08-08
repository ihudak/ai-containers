#!/usr/bin/env bash
# agent-tools-reconcile.sh — runs as the sandbox USER at container start. Installs the
# enabled agent-tier tools (Claude Code, Codex, Gemini, Copilot, graphify, Vale) into
# the group-mounted ~/.ai-tools home on first use — INSTALL-IF-MISSING only; keeping
# them current is each tool's own job (/update, npm update -g, uv tool upgrade).
# Concurrency-safe via flock on the shared mount. Offline-tolerant and non-fatal: a tool
# that fails to install logs FAILED and is skipped, never blocking container start.
# No `set -u` (parity with rvm-reconcile.sh; tolerate unset envs via ${VAR:-}).
set -o pipefail

tools="${AI_RUNTIME_TOOLS:-}"
[[ -z "${tools//,/}" ]] && exit 0        # nothing enabled → nothing to do

home_root="$HOME/.ai-tools"
mkdir -p "$home_root/npm" "$home_root/uv/bin" "$home_root/bin"

# Serialize concurrent same-group container starts (they share the mounted ~/.ai-tools).
# Runs before the interactive shell, so report a wait instead of appearing hung.
exec 9>"$home_root/.reconcile.lock"
if ! flock -n 9; then
  printf '[agent-tools-reconcile] another container in this group is installing tools — waiting…\n'
  flock 9
fi

log(){ printf '[agent-tools-reconcile] %s\n' "$*"; }

# uv is pointed at the group-mounted tool dir. npm gets NO env-var/.npmrc prefix here
# (see Dockerfile) — install_npm passes --prefix per invocation instead, which nvm's
# nvm_die_on_prefix does not object to (it only inspects .npmrc/$PREFIX/
# $NPM_CONFIG_PREFIX, never a command's own flags).
export UV_TOOL_DIR="$home_root/uv"
export UV_TOOL_BIN_DIR="$home_root/uv/bin"
npm_prefix="$home_root/npm"
npm_bin="$npm_prefix/bin"

install_npm() {   # $1=binary  $2=package
  local bin="$1" pkg="$2"
  if [[ -x "$npm_bin/$bin" ]]; then log "$bin already present"; return 0; fi
  log "installing $pkg…"
  npm install -g --prefix "$npm_prefix" "$pkg" || log "FAILED: npm install -g --prefix $npm_prefix $pkg (skipped)"
}

install_uv() {    # $1=binary  $2=package
  local bin="$1" pkg="$2"
  if [[ -x "$UV_TOOL_BIN_DIR/$bin" ]]; then log "$bin already present"; return 0; fi
  log "installing $pkg (uv)…"
  uv tool install "$pkg" || log "FAILED: uv tool install $pkg (skipped)"
}

install_vale() {
  if [[ -x "$home_root/bin/vale" ]]; then log "vale already present"; return 0; fi
  log "installing vale…"
  local arch ver
  arch="$(uname -m | sed 's/x86_64/64-bit/; s/aarch64/arm64/')"
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/vale-cli/vale/releases/latest 2>/dev/null | sed 's#.*/tag/v##')"
  # The sed only strips a `v`-prefixed tag. If upstream ever publishes an unprefixed tag
  # (or the redirect is intercepted) $ver would be a whole URL — non-empty, so an
  # emptiness check alone would let it through into the download URL. Require a version.
  if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    log "FAILED: could not resolve latest Vale version (got '${ver:-<empty>}') (skipped)"; return 0
  fi
  if curl -fsSL -o /tmp/vale.tar.gz \
       "https://github.com/vale-cli/vale/releases/download/v${ver}/vale_${ver}_Linux_${arch}.tar.gz" 2>/dev/null; then
    tar -xzf /tmp/vale.tar.gz -C "$home_root/bin" vale 2>/dev/null || log "FAILED: extract Vale (skipped)"
    rm -f /tmp/vale.tar.gz
  else
    log "FAILED: download Vale (skipped)"
  fi
}

IFS=, read -ra want <<<"$tools"
for t in "${want[@]}"; do
  case "$t" in
    claude-code) install_npm claude "@anthropic-ai/claude-code" ;;
    copilot)     install_npm copilot "@github/copilot" ;;
    codex)       install_npm codex "@openai/codex" ;;
    gemini)      install_npm gemini "@google/gemini-cli" ;;
    graphify)    install_uv graphify "graphifyy" ;;
    vale)        install_vale ;;
    *)           log "unknown tool '$t' (skipped)" ;;
  esac
done

# Claude Code plugins expect the native path ~/.local/bin/claude; point it at the
# group-mounted npm install when present.
if [[ -x "$npm_bin/claude" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$npm_bin/claude" "$HOME/.local/bin/claude"
fi

log "done."
