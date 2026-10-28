#!/usr/bin/env bash
# agent-tools-reconcile.sh — runs as the sandbox USER at container start. Installs the
# enabled agent-tier tools (Claude Code, Codex, Gemini, Copilot, graphify, Vale, MkDocs) into
# the group-mounted ~/.ai-tools home on first use. Mostly INSTALL-IF-MISSING, because
# keeping current is normally the tool's own job — but that only holds for tools that
# CAN update themselves here, which was established by testing each one rather than
# assumed:
#   claude-code  native install (~/.local/share/claude), self-updates    → if-missing
#   copilot      downloads its own GitHub release, self-updates in place → if-missing
#   codex        its `update` runs bare `npm install -g` → EACCES 243    → UPDATE if newer
#   gemini       has no update mechanism at all                          → UPDATE if newer
#   graphify     uv tool upgrade                                         → if-missing (*)
#   vale         latest at first install, never refreshed                → if-missing
#   mkdocs       uv tool upgrade                                         → if-missing (*)
#   (*) retried once on the previous Python minor when the image's fails — install_uv
# Concurrency-safe via flock on the shared mount. Offline-tolerant and non-fatal: a tool
# that fails to install logs FAILED and is skipped, never blocking container start.
# No `set -u` (parity with rvm-reconcile.sh; tolerate unset envs via ${VAR:-}).
set -o pipefail

tools="${AI_RUNTIME_TOOLS:-}"
[[ -z "${tools//,/}" ]] && exit 0        # nothing enabled → nothing to do

# From /, not the entrypoint's working directory: that is the project, and uv reads
# a .python-version, a .venv and a uv.toml there — the fallback's `uv python find`
# took the project's Python for the image's, and failed outright on one the image
# lacks (bugs review RT-4). Not $HOME either: a group's home may hold a pin.
cd / || exit 0

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
# A uv-managed Python (install_uv's fallback) lives in the tool home too: a tool's
# environment links to its interpreter, so one kept in the container layer would
# vanish on restart and take the tool with it.
export UV_PYTHON_INSTALL_DIR="$home_root/uv/python"
npm_prefix="$home_root/npm"
npm_bin="$npm_prefix/bin"

install_npm() {   # $1=binary  $2=package
  local bin="$1" pkg="$2"
  if [[ -x "$npm_bin/$bin" ]]; then log "$bin already present"; return 0; fi
  log "installing $pkg…"
  npm install -g --prefix "$npm_prefix" "$pkg" || log "FAILED: npm install -g --prefix $npm_prefix $pkg (skipped)"
}

# Keep a package at the LATEST published version rather than merely present. Used only
# for the tools that cannot keep themselves current, and the distinction is measured:
#   * codex's own `update` shells out to a bare `npm install -g @openai/codex`, which
#     resolves to nvm's root-owned prefix and dies EACCES (`exit status: 243`).
#   * gemini ships no update mechanism at all — nothing matching update/upgrade in its
#     --help.
# Copilot is deliberately NOT in this set: it downloads its own release from GitHub and
# self-updates in place, verified working behind the restricted firewall.
# Cost measured in-container: ~7s for four packages with a warm cache, ~24s cold.
#
# Only when the registry's version differs from the one installed: a reinstall
# re-extracts the package in place, under any sibling container of the group that
# is running it right now (bugs review RT-7), and that cost ~7s a start for
# nothing. An unreachable registry keeps what is installed.
update_npm() {    # $1=binary  $2=package
  local bin="$1" pkg="$2" cur="" latest=""
  if [[ -x "$npm_bin/$bin" ]]; then
    cur="$(npm ls -g --prefix "$npm_prefix" --depth=0 "$pkg" 2>/dev/null | sed -n "s|.*$pkg@\([^ ]*\).*|\1|p" | head -n 1)"
    if ! latest="$(npm view "$pkg" version 2>/dev/null | tail -n 1)" || [[ -z "$latest" ]]; then
      log "$bin: the registry cannot be reached; keeping ${cur:-the installed version}"; return 0
    fi
    if [[ -n "$cur" && "$cur" == "$latest" ]]; then log "$bin is current ($cur)"; return 0; fi
  fi
  log "updating $pkg…"
  npm install -g --prefix "$npm_prefix" "$pkg" \
    || log "FAILED: npm install -g --prefix $npm_prefix $pkg (skipped)"
}

# Claude Code installs NATIVELY rather than through npm, and the reason is a measurement
# rather than a preference. Its npm-installed self-updater runs a bare `npm install -g`,
# which resolves to nvm's root-owned prefix and fails with "no write permission to npm
# prefix" — the capability lost when bc2e551 removed the baked /etc/skel/.npmrc. That
# removal was correct (the baked prefix made `nvm use <version>` FAIL, not warn, breaking
# the node= multi-version workflow), so the fix cannot be to put it back: restoring it
# re-breaks nvm, and nvm's own suggested escape hatch, `nvm use --delete-prefix`, silently
# deletes the prefix again at runtime.
#
# The native installer sidesteps the whole conflict by not involving npm at any point:
# versions land in ~/.local/share/claude/versions/<v>, the launcher in ~/.local/bin/claude,
# and `claude update` replaces them in place. Verified end-to-end in a restricted-mode
# container — install and self-update both succeed behind the firewall (claude.ai,
# downloads.claude.ai and storage.googleapis.com are already allowlisted, and nothing was
# recorded in blocked-domains.txt), and `nvm use` still passes afterwards.
#
# Install-if-missing, keyed on the native install dir: keeping it current is `claude
# update`'s job, which — unlike codex and gemini — actually works.
install_claude_native() {
  # THE PRESENCE CHECK MUST KEY ON WHAT PERSISTS. ~/.local/share/claude is
  # group-mounted and survives the container; ~/.local/bin is NOT — it lives in
  # the writable layer and is gone on every restart. Keying on the launcher made
  # the conjunction false on every fresh start, so the reconcile re-ran
  # `curl https://claude.ai/install.sh | bash` EVERY TIME: a network dependency
  # at container start even in restricted mode, and a silent move of the whole
  # group to a new "stable" whenever upstream publishes one. Observed on a real
  # start, 2026-08-23: "installing Claude Code (native installer)…" with the
  # version already sitting in the mounted versions dir.
  #
  # The versions directory decides, and the ephemeral launcher is re-created
  # HERE rather than by re-running the installer. There is no other pointer to
  # rebuild it from — ~/.local/state/claude holds only per-run locks — so the
  # highest version present is the active one, which is what `claude update`
  # converges to anyway.
  local versions="$HOME/.local/share/claude/versions" latest="" _v
  if [[ -d "$versions" ]]; then
    # Glob + sort -V rather than parsing `ls`: 2.1.99 must not outrank 2.1.241.
    # Assigned INSIDE the body: the read that hits EOF returns non-zero and
    # clears its own variable, so a bare `while read latest; do :; done` leaves
    # it empty — which sent this straight back to the reinstall branch.
    while IFS= read -r _v; do latest="$_v"; done < <(cd "$versions" && printf '%s\n' * | sort -V)
  fi
  if [[ -n "$latest" && -x "$versions/$latest" ]]; then
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$versions/$latest" "$HOME/.local/bin/claude"
    log "claude already present (native, $latest)"
    return 0
  fi
  log "installing Claude Code (native installer)…"
  # ~/.local/bin ON PATH FOR THE INSTALLER, which otherwise ends a clean install
  # with a warning that is FALSE by the time anybody reads it:
  #
  #   ● Native installation exists but ~/.local/bin is not in your PATH.
  #
  # It is not on PATH *here* — this script runs from the entrypoint via runuser,
  # a non-interactive non-login shell, so /etc/profile.d/ai-tools.sh has not been
  # sourced. It IS on PATH in every shell the user ever gets. The installer is
  # telling the truth about the wrong shell, and the first thing a new user sees
  # is their tooling apparently misconfigured. Telling it the truth about the
  # shell that matters costs one export.
  export PATH="$HOME/.local/bin:$PATH"
  curl -fsSL https://claude.ai/install.sh | bash \
    || log "FAILED: native Claude Code install (skipped)"
}

# The image takes pyenv's NEWEST CPython, which runs weeks ahead of the compiled wheels
# some packages publish, and it has no C compiler unless c-toolchain=ON — so a tool
# with a dependency that has no wheel for that Python yet fails to build. Measured
# 2026-10-10: Python 3.15.0 became pyenv's latest, graphify pins tree-sitter<0.26,
# tree-sitter shipped wheels up to 3.14 only, and the install died with "Failed to
# build tree-sitter==0.25.2 ... No such file or directory: 'gcc'".
#
# So a failed install is retried ONCE on the previous minor, which uv uses from the
# image if it is there and otherwise downloads as a managed Python. The version is
# computed from the image's own, so it needs no bump when the next CPython lands.
#
# The first attempt and the version probe say --no-managed-python: uv PREFERS managed
# Pythons, and UV_PYTHON_INSTALL_DIR is shared by the group, so after one fallback
# every later install would quietly move to the older interpreter.
install_uv() {    # $1=binary  $2=package  $3..=extra `uv tool install` args
  local bin="$1" pkg="$2"; shift 2
  # Present means it can run: a tool's environment links to the interpreter it was
  # installed with, which a rebuild onto a newer patch release removes from the
  # image while the entry point stays executable (bugs review RT-3). uv links the
  # entry point from the tool's own bin/, where `python` is that interpreter.
  local reinstall=() entry envpy
  if [[ -x "$UV_TOOL_BIN_DIR/$bin" ]]; then
    entry="$(readlink -f "$UV_TOOL_BIN_DIR/$bin" 2>/dev/null)"
    envpy="${entry%/*}/python"
    if [[ -n "$entry" && -L "$envpy" && ! -x "$envpy" ]]; then
      log "$bin is installed against a Python this image no longer has; reinstalling…"
      reinstall=(--reinstall)
    else
      log "$bin already present"; return 0
    fi
  else
    log "installing $pkg (uv)…"
  fi
  uv tool install "$pkg" "$@" --no-managed-python "${reinstall[@]}" && return 0
  local py major="" minor=""
  py="$(uv python find --no-managed-python 2>/dev/null)"
  [[ -n "$py" ]] && read -r major minor < <("$py" -c 'import sys; print(*sys.version_info[:2])' 2>/dev/null)
  if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && (( minor > 0 )); then
    log "retrying $pkg on Python $major.$((minor - 1)): a dependency may have no wheel for $major.$minor yet…"
    uv tool install "$pkg" "$@" --python "$major.$((minor - 1))" "${reinstall[@]}" && return 0
  fi
  log "FAILED: uv tool install $pkg $* (skipped)"
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
    claude-code) install_claude_native ;;
    copilot)     install_npm copilot "@github/copilot" ;;
    codex)       update_npm  codex "@openai/codex" ;;
    gemini)      update_npm  gemini "@google/gemini-cli" ;;
    graphify)    install_uv graphify "graphifyy" ;;
    vale)        install_vale ;;
    # A uv tool's environment holds only what it was installed with, and a docs
    # scaffold's one requirement is the Material theme.
    mkdocs)      install_uv mkdocs mkdocs --with mkdocs-material ;;
    *)           log "unknown tool '$t' (skipped)" ;;
  esac
done

# Claude Code plugins expect ~/.local/bin/claude. The native installer creates and OWNS
# that path, so only point it at a leftover npm copy when no native install exists —
# a group provisioned before this change still carries ~300 MB of npm Claude under
# ~/.ai-tools/npm, and it must keep working until someone clears it, without shadowing
# the native install once that appears. Deliberately not deleted here: other containers
# in the same group may be running against it right now. Gated on claude-code being ON
# here: the npm copy is in the group's shared tool home, so its mere presence says only
# that SOME project in the group enabled it.
# "No native install" is no executable version, as install_claude_native decides it —
# never a missing directory: sandbox.sh makes and mounts ~/.local/share/claude for
# every named group with claude-code on, so that test never fired (bugs review RT-5).
native_claude_present() {   # the highest version is executable, as install_claude_native asks
  local versions="$HOME/.local/share/claude/versions" latest="" _v
  [[ -d "$versions" ]] || return 1
  while IFS= read -r _v; do latest="$_v"; done < <(cd "$versions" && printf '%s\n' * | sort -V)
  [[ -n "$latest" && -x "$versions/$latest" ]]
}
if [[ ",$tools," == *",claude-code,"* ]] && ! native_claude_present && [[ -x "$npm_bin/claude" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$npm_bin/claude" "$HOME/.local/bin/claude"
  log "using leftover npm Claude ($npm_bin/claude) — no native install present"
fi

log "done."
