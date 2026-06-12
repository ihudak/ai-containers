#!/usr/bin/env bash
# sandbox-common.sh — shared library for build.sh, runme.sh, and repo.sh.
#
# This file is meant to be SOURCED, not executed. It provides:
#   - configuration parsing for sandbox.conf (get_versions / is_enabled / ...)
#   - container-group helpers (validate/bootstrap ~/.ai-containers/<group>/)
#   - path + docker-volume name helpers
#   - the global repo-volume registry (~/.ai-containers/repos.conf)
#
# All three entry-point scripts live in the same directory as this file.

# Guard against double-sourcing.
if [[ -n "${_SANDBOX_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_SANDBOX_COMMON_SOURCED=1

# Require bash >= 4.3 (associative arrays + namerefs are used throughout).
# macOS ships bash 3.2 — `brew install bash` provides a newer one.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "ERROR: bash >= 4.3 is required (running ${BASH_VERSION:-unknown})." >&2
  echo "       On macOS: brew install bash, then run the scripts with the newer bash." >&2
  exit 1
fi

# ── Shared constants ────────────────────────────────────────────────────────────

# Directory containing this library (and the entry-point scripts beside it).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${script_dir}/sandbox.conf"

# Persisted per-project environment (written by project-init.sh; one KEY=value
# per line). It is sourced ONLY to supply IMAGE_NAME when the env var is not
# already set, so build.sh / runme.sh / repo.sh all resolve the SAME image name
# — and therefore the same repo-volume names (<image>-repo-<repo>) — even when a
# script is run directly instead of through the generated launcher. An exported
# IMAGE_NAME (e.g. from the launcher) always takes precedence.
sandbox_env_file="${script_dir}/sandbox.env"
if [[ -z "${IMAGE_NAME:-}" && -f "$sandbox_env_file" ]]; then
  # shellcheck disable=SC1090
  source "$sandbox_env_file"
fi
image_name="${IMAGE_NAME:-ai-sandbox}"

# Fixed, project-independent name for the small repo.sh seeding helper image
# (Alpine + git/openssh-client/rsync/bash). It is deliberately NOT derived from
# IMAGE_NAME: the helper is generic, so one shared image is built once and reused
# by every project instead of one near-identical copy per project image.
# Override with REPO_SEED_IMAGE to reuse an existing image.
seed_image="${REPO_SEED_IMAGE:-ai-containers-seed}"

# Global (group-independent) repo registry. Repo volumes are code, not
# credentials, so they live OUTSIDE the per-group dotfile trees and are shared
# by containers in any group.
ai_containers_root="${HOME}/.ai-containers"
repo_registry_file="${ai_containers_root}/repos.conf"

# ── Config helpers ──────────────────────────────────────────────────────────────

check_config() {
  if [[ ! -f "$config_file" ]]; then
    printf 'ERROR: sandbox.conf not found in %s\n' "$script_dir" >&2
    exit 1
  fi
}

# Returns empty string if the key is absent or has no value.
get_versions() {
  local key="$1"
  local raw
  raw=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2-)
  # Strip inline comments (e.g. "21 # LTS version" → "21")
  raw="${raw%%#*}"
  # Trim whitespace
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

# Returns 0 if the component is set to ON in sandbox.conf, 1 otherwise.
is_enabled() {
  [[ "$(get_versions "$1")" == "ON" ]]
}

# Returns 0 if at least one of the given components is ON.
any_enabled() {
  local c
  for c in "$@"; do
    if is_enabled "$c"; then return 0; fi
  done
  return 1
}

# Returns 0 if a key is ON or has a non-empty version value (i.e. the component is active).
is_active() {
  local val; val=$(get_versions "$1")
  [[ -n "$val" && "$val" != "OFF" ]]
}

# Returns 0 if at least one of the given keys is active.
any_active() {
  local k
  for k in "$@"; do
    if is_active "$k"; then return 0; fi
  done
  return 1
}

# Returns 0 if the version-list key has at least one version set.
has_versions() {
  local val
  val="$(get_versions "$1")"
  [[ -n "$val" ]]
}

# Returns 0 if any of the given version-list keys have at least one version set.
any_has_versions() {
  local k
  for k in "$@"; do
    if has_versions "$k"; then return 0; fi
  done
  return 1
}

# Convert a comma-separated version list to a space-separated list for build args.
versions_to_space() {
  printf '%s' "$1" | tr ',' ' '
}

# ── Path + volume-name helpers ──────────────────────────────────────────────────

# Resolve a path to an ABSOLUTE path, following symlinks where possible.
# Portable across GNU and BSD/macOS. Critical for `docker run -v`: a RELATIVE
# source is treated by Docker as a named-volume reference.
resolve_path() {
  local p="$1"
  if command -v greadlink >/dev/null 2>&1; then
    greadlink -f -- "$p" 2>/dev/null && return 0
  elif readlink -f -- "$p" >/dev/null 2>&1; then
    readlink -f -- "$p"
    return 0
  fi
  if [[ -d "$p" ]]; then
    (cd "$p" 2>/dev/null && pwd) && return 0
  fi
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$PWD" "${p#./}" ;;
  esac
}

# Sanitize an arbitrary string into a token safe for a Docker volume name
# (Docker allows [a-zA-Z0-9][a-zA-Z0-9_.-]*). Non-conforming chars collapse to
# underscores; leading separators are stripped.
sanitize_volume_token() {
  local s="$1"
  s="$(printf '%s' "$s" | tr -c 'a-zA-Z0-9_.-' '_')"
  s="${s#_}"
  printf '%s' "$s"
}

# Validate a user-supplied repo name (used as part of a volume name and as the
# registry key). Same character class as group names for consistency.
validate_repo_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || {
    printf "Invalid repo name '%s'. Allowed: lowercase letters, digits, dashes; 1-64 chars; must start with alphanum.\n" "$name" >&2
    return 1
  }
}

# Docker volume name backing a registered repo (the shared, read base copy).
repo_volume_name() {
  printf '%s-repo-%s' "$image_name" "$(sanitize_volume_token "$1")"
}

# Docker volume name for a per-workspace writable working copy of a repo.
#   $1 = repo name, $2 = working-copy tag (e.g. primary workspace basename)
repo_workcopy_volume_name() {
  printf '%s-repo-%s--wc-%s' "$image_name" "$(sanitize_volume_token "$1")" "$(sanitize_volume_token "$2")"
}

# ── Repo registry helpers ───────────────────────────────────────────────────────
#
# Registry format: one record per line, pipe-delimited, in repos.conf:
#   name|type|source|added_epoch|synced_epoch|backend
#     type    = path | git
#     source  = absolute host path (type=path) or git URL (type=git)
#     backend = volume | bind   (decided at add time on THIS machine; the
#               registry is machine-local and never synced across hosts)
# Blank lines and lines starting with '#' are ignored.

repo_registry_ensure() {
  mkdir -p "$ai_containers_root"
  [[ -f "$repo_registry_file" ]] || {
    printf '# ai-containers repo registry — managed by repo.sh\n' > "$repo_registry_file"
    printf '# format: name|type|source|added_epoch|synced_epoch|backend\n' >> "$repo_registry_file"
  }
}

# Echo the full registry record line for a repo, or return 1 if not present.
repo_registry_lookup() {
  local name="$1"
  [[ -f "$repo_registry_file" ]] || return 1
  grep -E "^${name}\|" "$repo_registry_file" 2>/dev/null | head -1
}

repo_is_registered() {
  repo_registry_lookup "$1" >/dev/null 2>&1
}

# Extract a field (1=name 2=type 3=source 4=added 5=synced 6=backend) from a record.
repo_record_field() {
  local record="$1" field="$2"
  printf '%s' "$record" | cut -d'|' -f"$field"
}

# Backend stored in a record (field 6); fall back to computing it from the type
# for older records that predate the field.
repo_record_backend() {
  local record="$1"
  local b; b="$(repo_record_field "$record" 6)"
  if [[ "$b" == "volume" || "$b" == "bind" ]]; then
    printf '%s' "$b"
  else
    repo_effective_backend "$(repo_record_field "$record" 2)"
  fi
}

# Insert or replace a registry record.
repo_registry_upsert() {
  local name="$1" type="$2" source="$3" added="$4" synced="$5" backend="${6:-}"
  repo_registry_ensure
  local tmp; tmp="$(mktemp)"
  grep -vE "^${name}\|" "$repo_registry_file" > "$tmp" 2>/dev/null || true
  printf '%s|%s|%s|%s|%s|%s\n' "$name" "$type" "$source" "$added" "$synced" "$backend" >> "$tmp"
  mv "$tmp" "$repo_registry_file"
}

repo_registry_remove() {
  local name="$1"
  [[ -f "$repo_registry_file" ]] || return 0
  local tmp; tmp="$(mktemp)"
  grep -vE "^${name}\|" "$repo_registry_file" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$repo_registry_file"
}

# Echo each registered repo name (one per line).
repo_registry_names() {
  [[ -f "$repo_registry_file" ]] || return 0
  # '|| true' so a no-match grep (empty registry) doesn't trip set -e/pipefail.
  grep -vE '^[[:space:]]*(#|$)' "$repo_registry_file" 2>/dev/null | cut -d'|' -f1 || true
}

# Returns 0 if the docker volume backing repo $1 exists.
repo_volume_exists() {
  local vol; vol="$(repo_volume_name "$1")"
  docker volume inspect "$vol" >/dev/null 2>&1
}

# Decide whether a repo should be backed by a Docker named volume or a direct
# host bind mount, given its source type and the REPO_BACKEND override.
#   REPO_BACKEND=volume → always a volume.
#   REPO_BACKEND=bind   → bind when a host path is available, else volume.
#   REPO_BACKEND=auto (default) → bind on Linux for 'path' sources (host bind
#     mounts are already native-speed there), volume otherwise (notably macOS,
#     where bind mounts pay the virtiofs penalty, and for 'git' sources which
#     have no local path to bind).
# Echoes "bind" or "volume".
repo_effective_backend() {
  local type="$1"
  case "${REPO_BACKEND:-auto}" in
    volume) printf 'volume' ;;
    bind)   if [[ "$type" == "path" ]]; then printf 'bind'; else printf 'volume'; fi ;;
    *)      # auto
            if [[ "$(uname -s)" == "Linux" && "$type" == "path" ]]; then
              printf 'bind'
            else
              printf 'volume'
            fi ;;
  esac
}

# ── Group helpers ────────────────────────────────────────────────────────────────

validate_group_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
    echo "Invalid AI_CONTAINER_GROUP='$name'. Allowed: lowercase letters, digits, dashes; 1-32 chars; must start with alphanum." >&2
    exit 1
  }
}

print_macos_host_warning() {
  cat >&2 <<'EOF'
WARNING: AI_CONTAINER_GROUP=host on macOS

The following tools store OAuth in the macOS Keychain and
will NOT have working credentials in the container:
  - Claude Code        (~/.claude)
  - GitHub Copilot CLI (~/.copilot)
  - Kiro CLI           (~/.kiro)  [also: per-arch bun binary conflict]
  - GitHub CLI         (~/.config/gh)

Codex, Gemini, and other dirs are unaffected.
EOF
}

require_host_ack() {
  if [[ "${AI_CONTAINER_HOST_ACK:-0}" == "1" ]]; then
    return
  elif [[ -t 0 ]]; then
    print_macos_host_warning
    read -r -p "Type 'yes' to continue, anything else to abort: " reply
    [[ "$reply" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
  else
    print_macos_host_warning
    echo "Aborting: stdin is not a TTY and AI_CONTAINER_HOST_ACK=1 is not set." >&2
    exit 1
  fi
}

ensure_group_scaffold() {
  local root="$1"
  install -d -m 700 "$root/.ssh"
  install -d        "$root/.agents"
}

# Copy the group-scoped slice of dotfiles from $src into $dst.
_copy_group_slice() {
  local src="$1" dst="$2"
  local paths=(.claude .claude.json .copilot .config/gh .kiro ".local/share/kiro-cli" .codex .gemini .agents .ssh)
  for p in "${paths[@]}"; do
    local from="$src/$p"
    if [[ -e "$from" ]]; then
      mkdir -p "$(dirname "$dst/$p")"
      cp -a "$from" "$dst/$p"
    fi
  done
}

ensure_group_exists() {
  local group="$1" root="$2"
  if [[ -d "$root" ]]; then
    return
  fi

  if [[ -n "${AI_CONTAINER_GROUP_INIT:-}" ]]; then
    case "$AI_CONTAINER_GROUP_INIT" in
      clean)
        mkdir -p "$root"
        ;;
      from:host)
        mkdir -p "$root"
        _copy_group_slice "$HOME" "$root"
        ;;
      from:*)
        local src_name="${AI_CONTAINER_GROUP_INIT#from:}"
        local src_root="$HOME/.ai-containers/$src_name"
        if [[ ! -d "$src_root" ]]; then
          echo "ERROR: AI_CONTAINER_GROUP_INIT=from:$src_name — source group '$src_name' not found at $src_root" >&2
          exit 1
        fi
        mkdir -p "$root"
        _copy_group_slice "$src_root" "$root"
        ;;
      *)
        echo "ERROR: unknown AI_CONTAINER_GROUP_INIT value '${AI_CONTAINER_GROUP_INIT}'. Expected: clean, from:host, or from:<group>." >&2
        exit 1
        ;;
    esac
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "ERROR: group '$group' not found at $root and stdin is not a TTY." >&2
    echo "       Set AI_CONTAINER_GROUP_INIT=clean (empty), AI_CONTAINER_GROUP_INIT=from:host, or AI_CONTAINER_GROUP_INIT=from:<existing-group> to bootstrap non-interactively." >&2
    exit 1
  fi

  # Interactive prompt: numbered options + 'q' as a non-numeric escape.
  local options=() option_labels=()
  local default_exists=0
  if [[ -d "$HOME/.ai-containers/default" ]]; then
    options+=("default")
    option_labels+=("default (recommended)")
    default_exists=1
  fi
  options+=("host")
  if (( default_exists == 0 )); then
    option_labels+=("host (recommended)")
  else
    option_labels+=("host")
  fi
  while IFS= read -r -d '' dir; do
    local name; name="$(basename "$dir")"
    [[ "$name" == "default" || "$name" == "$group" ]] && continue
    options+=("$name")
    option_labels+=("$name")
  done < <(find "$HOME/.ai-containers" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
           | xargs -0 ls -dt 2>/dev/null \
           | while IFS= read -r d; do printf '%s\0' "$d"; done)
  options+=("<empty>")
  option_labels+=("<empty>")

  echo "Group '$group' not found. Initialize from:" >&2
  local i
  for i in "${!option_labels[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${option_labels[$i]}" >&2
  done
  echo "  q) cancel" >&2

  local default_idx=1
  local reply
  read -r -p "[${default_idx}]: " reply </dev/tty
  [[ -z "$reply" ]] && reply="$default_idx"

  if [[ "$reply" == "q" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
  if [[ ! "$reply" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection '$reply'." >&2
    exit 1
  fi

  local choice_idx=$(( reply - 1 ))
  if (( choice_idx < 0 || choice_idx >= ${#options[@]} )); then
    echo "Invalid selection '$reply'." >&2
    exit 1
  fi

  local chosen="${options[$choice_idx]}"

  case "$chosen" in
    "<empty>")
      mkdir -p "$root"
      ;;
    host)
      mkdir -p "$root"
      _copy_group_slice "$HOME" "$root"
      ;;
    *)
      local src_root="$HOME/.ai-containers/$chosen"
      if [[ ! -d "$src_root" ]]; then
        echo "ERROR: source group '$chosen' not found at $src_root" >&2
        exit 1
      fi
      mkdir -p "$root"
      _copy_group_slice "$src_root" "$root"
      ;;
  esac
}
