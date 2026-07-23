#!/usr/bin/env bash
# tools-lib.sh — shared parser for tools.d/ descriptor files.
#
# A descriptor is KEY=value lines describing one external CLI the container
# integrates (dtctl, dtmgd, ...). Sourced by host scripts (via
# sandbox-common.sh) and by container scripts (install-tools.sh /
# install-agent-skills.sh, which source it from /etc/ai-containers/tools-lib.sh).
# Pure functions only — no side effects at source time.

# Descriptor directory. Host scripts point this at the repo tree; container
# scripts inherit the default.
: "${TOOLS_D_DIR:=/etc/ai-containers/tools.d}"

# tools_list_names — echo one descriptor name (basename without .conf) per line.
tools_list_names() {
  local f b
  [[ -d "$TOOLS_D_DIR" ]] || return 0
  for f in "$TOOLS_D_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    b="${f##*/}"                 # strip dir (no basename subshell)
    printf '%s\n' "${b%.conf}"   # strip .conf suffix
  done
}

# tools_read_descriptor <name> — populate TOOL_* globals from <name>.conf.
# Resets every field first so stale values never leak. Returns 1 if absent.
# TOOL_* are consumed by the scripts that source this library (install-tools.sh,
# install-agent-skills.sh, build.sh), not within this file:
# shellcheck disable=SC2034
tools_read_descriptor() {
  local name="$1" file="$TOOLS_D_DIR/$1.conf" line key val
  TOOL_name="$name"
  TOOL_repo="" TOOL_binary="" TOOL_private="no" TOOL_config_dir=""
  TOOL_allowlist_fragment="" TOOL_skills="no" TOOL_skills_crossclient=""
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                    # strip comments
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"            # trim key
    val="${val#"${val%%[![:space:]]*}"}"  # ltrim val
    val="${val%"${val##*[![:space:]]}"}"  # rtrim val
    case "$key" in
      repo)               TOOL_repo="$val" ;;
      binary)             TOOL_binary="$val" ;;
      private)            TOOL_private="$val" ;;
      config_dir)         TOOL_config_dir="$val" ;;
      allowlist_fragment) TOOL_allowlist_fragment="$val" ;;
      skills)             TOOL_skills="$val" ;;
      skills_crossclient) TOOL_skills_crossclient="$val" ;;
    esac
  done < "$file"
  [[ -n "$TOOL_binary" ]] || TOOL_binary="$name"
  return 0
}
