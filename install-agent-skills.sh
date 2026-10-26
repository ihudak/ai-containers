#!/usr/bin/env bash
# install-agent-skills.sh — install each installed tool's Agent Skill for every
# enabled AI agent, refreshing when the tool's version changes.
#
# Runs at container start as the sandbox user (see entrypoint.sh). Offline:
# skills are embedded in each tool binary. Never fails container start.
#
# Env:
#   AI_AGENTS_ENABLED  comma-separated sandbox.conf agent keys ("claude-code,copilot")
set -uo pipefail

TOOLS_D_DIR="${TOOLS_D_DIR:-/etc/ai-containers/tools.d}"
_tools_lib="${TOOLS_LIB:-/etc/ai-containers/tools-lib.sh}"
if [ ! -r "$_tools_lib" ]; then
  echo "install-agent-skills: descriptor library not found ($_tools_lib); skipping." >&2
  exit 0
fi
# shellcheck source=/dev/null
source "$_tools_lib"

export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
STAMP="$HOME/.agents/.ai-containers-skills-stamp"
mkdir -p "$HOME/.agents" 2>/dev/null || true

# Map a sandbox.conf agent key to the tool's --for agent name.
map_agent() { case "$1" in claude-code) echo claude ;; *) echo "$1" ;; esac; }

# current_stamp — "name=version" per installed skills tool, sorted (change key).
# TOOL_* are set by tools_read_descriptor in the sourced tools-lib.sh.
# shellcheck disable=SC2154
current_stamp() {
  local name
  while IFS= read -r name; do
    tools_read_descriptor "$name" || continue
    [ "$TOOL_skills" = "yes" ] || continue
    command -v "$TOOL_binary" >/dev/null 2>&1 || continue
    # dtctl/dtmgd/junoctl (cobra CLIs) expose a `version` subcommand, not a
    # --version flag; fall back to the flag for tools that use that form.
    local ver
    ver="$("$TOOL_binary" version 2>/dev/null | head -1)"
    [ -n "$ver" ] || ver="$("$TOOL_binary" --version 2>/dev/null | head -1)"
    printf '%s=%s\n' "$name" "$ver"
  done < <(tools_list_names) | sort
}

# install_for_tool <name> <agents csv> <cross: 1|0> — for the --for agent names
# given (already mapped), and the cross-client skill when <cross> is 1.
install_for_tool() {
  local name="$1" agents_csv="$2" cross="$3"
  tools_read_descriptor "$name" || return 0
  [ "$TOOL_skills" = "yes" ] || return 0
  command -v "$TOOL_binary" >/dev/null 2>&1 || return 0
  local bin="$TOOL_binary" installed=() key agent

  if [ "$cross" = 1 ] && [ -n "$TOOL_skills_crossclient" ]; then
    # shellcheck disable=SC2086
    if "$bin" skills install $TOOL_skills_crossclient --global --force >/dev/null 2>&1; then
      installed+=("cross-client")
    fi
  fi

  local IFS=','; read -ra _agents <<< "$agents_csv"
  for key in "${_agents[@]}"; do
    [ -n "$key" ] || continue
    agent="$key"
    if "$bin" skills install --for "$agent" --global --force >/dev/null 2>&1; then
      installed+=("$agent")
    fi
  done

  if [ "${#installed[@]}" -gt 0 ]; then
    printf '  %s → %s\n' "$name" "$(IFS=,; echo "${installed[*]}")"
  else
    printf '  %s → (no supported agents)\n' "$name"
  fi
}

# The stamp holds one "<target><TAB>name=version" line per target and tool, a
# target being the cross-client skill or one agent. ~/.agents is group-mounted,
# so projects with different agents share it: a target is installed when its own
# lines differ from what is installed now, and an agent enabled later gets the
# skills although no tool version changed (bugs review RT-2). A stamp from
# before targets (no TAB) matches no target, so everything installs once.
target_stamp() {  # <target> — that target's lines, without the prefix
  [ -f "$STAMP" ] || return 0
  local t line; t="$1"
  while IFS= read -r line; do
    case "$line" in "$t"$'\t'*) printf '%s\n' "${line#*$'\t'}" ;; esac
  done < "$STAMP"
}

main() {
  local want; want="$(current_stamp)"
  local targets=(cross-client) key t todo=() agents="" cross=0
  local IFS=','; read -ra _keys <<< "${AI_AGENTS_ENABLED:-}"; unset IFS
  for key in "${_keys[@]}"; do [ -n "$key" ] && targets+=("$(map_agent "$key")"); done
  for t in "${targets[@]}"; do
    [ -f "$STAMP" ] && [ "$(target_stamp "$t")" = "$want" ] && continue
    todo+=("$t")
    if [ "$t" = cross-client ]; then cross=1; else agents="${agents:+$agents,}$t"; fi
  done
  [ "${#todo[@]}" -gt 0 ] || exit 0
  echo "Installing agent skills..."
  local name
  while IFS= read -r name; do
    install_for_tool "$name" "$agents" "$cross"
  done < <(tools_list_names)
  # Keep every other target's lines (another project's agents), replace these.
  local new="" line keep
  if [ -f "$STAMP" ]; then
    while IFS= read -r line; do
      case "$line" in *$'\t'*) ;; *) continue ;; esac
      keep=1
      for t in "${todo[@]}"; do case "$line" in "$t"$'\t'*) keep=0 ;; esac; done
      [ "$keep" = 1 ] && new="$new$line"$'\n'
    done < "$STAMP"
  fi
  for t in "${todo[@]}"; do
    while IFS= read -r line; do [ -n "$line" ] && new="$new$t"$'\t'"$line"$'\n'; done <<< "$want"
  done
  printf '%s' "$new" > "$STAMP" 2>/dev/null || true
}

# BY BEHAVIOUR, NOT BY STRING (#218): `return` succeeds outside a function only
# in a sourced file, so this cannot be fooled by an absolute-path invocation.
if ! (return 0 2>/dev/null); then main; fi
