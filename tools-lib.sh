#!/usr/bin/env bash
# tools-lib.sh — shared parser for tools.d/ descriptor files.
#
# A descriptor is KEY=value lines describing one external CLI the container
# integrates (dtctl, dtmgd, ...). Sourced by host scripts (via
# sandbox-common.sh) and by container scripts (install-tools.sh /
# install-agent-skills.sh, which source it from /etc/ai-containers/tools-lib.sh).
# Pure functions only — no side effects at source time.
#
# Fields: repo, binary, private, config_dir, allowlist_fragment, skills,
# skills_crossclient, install, repo_path, ref.
#
# config_dir accepts SEVERAL space-separated paths, for a tool that splits its
# state across more than one directory (e.g. config in one, credentials in
# another). Every listed path is group-scoped and mounted.
#
# install selects how install-tools.sh obtains the binary:
#   release    (default) a GitHub release asset, <binary>_<version>_<os>_<arch>.tar.gz
#   repo-file  a prebuilt binary COMMITTED IN the repo, at repo_path
# repo-file exists for tools whose build artifacts are vendored into a git repo
# instead of published as releases. repo_path is the path inside the repo and may
# contain ${ARCH} (expanded to amd64/arm64). ref pins a branch/tag/commit; the
# sandbox.conf value wins over it, so the key grammar for such a tool is
# ON | <git-ref> | OFF (there are no release versions to pin).

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
  TOOL_install="release" TOOL_repo_path="" TOOL_ref=""
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
      install)            TOOL_install="$val" ;;
      repo_path)          TOOL_repo_path="$val" ;;
      ref)                TOOL_ref="$val" ;;
    esac
  done < "$file"
  [[ -n "$TOOL_binary" ]] || TOOL_binary="$name"
  return 0
}
