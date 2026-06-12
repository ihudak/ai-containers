#!/usr/bin/env bash
set -euo pipefail

# repo.sh — manage shared, native-speed repo volumes for the AI sandbox.
#
# Repo volumes are Docker named volumes living inside the Colima/Docker VM, so
# containers read them at native speed instead of paying the virtiofs penalty of
# host bind mounts. They are GLOBAL (shared across all container groups) and
# tracked in a registry at ~/.ai-containers/repos.conf.
#
# Seed a repo ONCE, then attach it to any number of containers via the runme.sh
# REPOS variable:  REPOS="cluster:ro lib:ro app:rw" ./runme.sh restricted /ws

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./repo.sh add  <name> <host-path | git-url>   Seed a repo volume and register it
  ./repo.sh sync <name | --all>                  Refresh a repo volume from its source
  ./repo.sh reset <name | --all> [--yes]         Discard local changes (clean slate; keeps the repo)
  ./repo.sh list [--sizes]                       List registered repos (and on-disk sizes)
  ./repo.sh rm   <name> [--yes]                  Remove a repo volume + its working copies

Notes:
  - Repo volumes are GLOBAL — shared by containers in any AI_CONTAINER_GROUP.
  - Authentication for git-url sources uses your HOST ~/.ssh (mounted read-only).
  - Volume contents are chowned to SANDBOX_UID/SANDBOX_GID (default id -u/id -g),
    the SAME identity runme.sh runs the container as. If you override these, set
    the SAME values for both repo.sh and runme.sh or mounted repos get the wrong
    owner and the in-container agent hits permission errors.
  - 'add' refuses to overwrite an existing repo; use 'sync' to refresh or 'rm' first.
  - Attach repos at run time with runme.sh's REPOS variable (default :ro, shared).
  - Seeding does NOT require the sandbox image. A small, shared helper image
    ("ai-containers-seed", built on demand from Dockerfile.seed) does the copy /
    clone / rsync for every project. Override with REPO_SEED_IMAGE.
  - Backend (auto by default): on macOS, 'path' and 'git' repos use Docker named
    volumes (native VM speed). On Linux, 'path' repos are registered as named
    bind-mount aliases — 'add' only updates the registry (no volume, no copy), and
    runme.sh bind-mounts the host path directly. Override with REPO_BACKEND.

Registry: ~/.ai-containers/repos.conf
EOF
}

# Numeric owner applied to seeded/synced volume contents. MUST match the identity
# the main container runs as, since Linux permissions are by UID/GID. runme.sh
# creates the sandbox user with SANDBOX_UID/SANDBOX_GID (defaulting to id -u/id -g),
# so this resolves them the SAME way — overriding one without the other (or seeding
# and running as different users) causes ownership mismatches in mounted repos.
host_uid="${SANDBOX_UID:-$(id -u)}"
host_gid="${SANDBOX_GID:-$(id -g)}"

# Format a unix epoch as a human date, portable across BSD (macOS) and GNU date.
fmt_epoch() {
  local e="$1"
  [[ "$e" =~ ^[0-9]+$ ]] || { printf '%s' "$e"; return; }
  date -r "$e" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || printf '%s' "$e"
}

# The repo-volume seeding helper image (`seed_image`) is defined in
# sandbox-common.sh as a fixed, project-independent name (default
# "ai-containers-seed", override with REPO_SEED_IMAGE). It is built on demand
# from Dockerfile.seed below — independent of the (large, slow) sandbox image,
# which typically does not exist yet when repos are first seeded.
seed_dockerfile="${_here}/Dockerfile.seed"

# Ensure the seed helper image exists, building it on demand from Dockerfile.seed.
# If REPO_SEED_IMAGE points at an image that is already present we use it as-is
# (and never try to build it).
ensure_seed_image() {
  if docker image inspect "$seed_image" >/dev/null 2>&1; then
    return
  fi
  if [[ -n "${REPO_SEED_IMAGE:-}" ]]; then
    printf 'ERROR: REPO_SEED_IMAGE="%s" not found. Pull or build it first.\n' "$seed_image" >&2
    exit 1
  fi
  if [[ ! -f "$seed_dockerfile" ]]; then
    printf 'ERROR: seed helper Dockerfile not found at %s\n' "$seed_dockerfile" >&2
    exit 1
  fi
  printf 'Seed helper image "%s" not found — building it (one-time, ~40MB) ...\n' "$seed_image" >&2
  if ! docker build -t "$seed_image" -f "$seed_dockerfile" "$_here" >&2; then
    printf 'ERROR: failed to build seed helper image "%s".\n' "$seed_image" >&2
    exit 1
  fi
}

is_git_url() {
  case "$1" in
    *://*|*@*:*) return 0 ;;
    *)          return 1 ;;
  esac
}

# Seed a fresh volume from a local host path (one-time copy through virtiofs).
seed_from_path() {
  local vol="$1" src="$2"
  local real; real="$(resolve_path "$src")"
  if [[ ! -d "$real" ]]; then
    printf 'ERROR: source path does not exist or is not a directory: %s\n' "$src" >&2
    exit 1
  fi
  printf 'Seeding volume "%s" from host path %s ...\n' "$vol" "$real"
  docker run --rm --entrypoint bash \
    -v "$real":/src:ro \
    -v "$vol":/dst \
    "$seed_image" -c "cp -a /src/. /dst/ && chown -R ${host_uid}:${host_gid} /dst"
}

# Refresh a volume from its local host path source.
sync_from_path() {
  local vol="$1" src="$2"
  local real; real="$(resolve_path "$src")"
  if [[ ! -d "$real" ]]; then
    printf 'ERROR: source path no longer exists: %s\n' "$src" >&2
    exit 1
  fi
  printf 'Syncing volume "%s" from host path %s ...\n' "$vol" "$real"
  # Prefer rsync (mirror with deletes) if available in the image; fall back to cp.
  docker run --rm --entrypoint bash \
    -v "$real":/src:ro \
    -v "$vol":/dst \
    "$seed_image" -c '
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete /src/ /dst/
      else
        echo "NOTE: rsync not in image; using cp -a (updates/adds only, no deletions)." >&2
        cp -a /src/. /dst/
      fi
      chown -R '"${host_uid}:${host_gid}"' /dst'
}

# Clone a git URL into a fresh volume, authenticating with the host ~/.ssh.
seed_from_git() {
  local vol="$1" url="$2"
  printf 'Cloning %s into volume "%s" (auth via host ~/.ssh) ...\n' "$url" "$vol"
  docker run --rm --entrypoint bash \
    -v "$HOME/.ssh":/root/.ssh-host:ro \
    -v "$vol":/dst \
    "$seed_image" -c '
      set -e
      # Copy host known_hosts/keys to a writable location so accept-new can record.
      mkdir -p /root/.ssh && cp -a /root/.ssh-host/. /root/.ssh/ 2>/dev/null || true
      chmod 700 /root/.ssh; chmod 600 /root/.ssh/* 2>/dev/null || true
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
      git clone "$1" /dst
      chown -R "$2" /dst' _ "$url" "${host_uid}:${host_gid}"
}

# Pull latest into an existing git volume.
sync_from_git() {
  local vol="$1"
  printf 'Pulling latest into volume "%s" (auth via host ~/.ssh) ...\n' "$vol"
  docker run --rm --entrypoint bash \
    -v "$HOME/.ssh":/root/.ssh-host:ro \
    -v "$vol":/dst \
    "$seed_image" -c '
      set -e
      mkdir -p /root/.ssh && cp -a /root/.ssh-host/. /root/.ssh/ 2>/dev/null || true
      chmod 700 /root/.ssh; chmod 600 /root/.ssh/* 2>/dev/null || true
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
      # The volume was chowned to the host UID after the initial clone, but this
      # helper runs as root — mark it safe so git does not refuse with
      # "detected dubious ownership".
      git config --global --add safe.directory /dst
      git -C /dst pull --ff-only
      chown -R '"${host_uid}:${host_gid}"' /dst'
}

# Reset a git volume to a clean checkout: discard uncommitted changes, drop
# untracked/ignored files, and reset the current branch to its upstream (or
# HEAD if there is none). Fully local — no fetch, no re-clone.
reset_git() {
  local vol="$1"
  printf 'Resetting volume "%s" to a clean checkout ...\n' "$vol"
  docker run --rm --entrypoint bash \
    -v "$vol":/dst \
    "$seed_image" -c '
      set -e
      # Helper runs as root while /dst is owned by the host UID.
      git config --global --add safe.directory /dst
      target=HEAD
      if git -C /dst rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        target="@{u}"
      fi
      git -C /dst reset --hard "$target"
      git -C /dst clean -ffdx
      chown -R '"${host_uid}:${host_gid}"' /dst'
}

cmd_add() {
  local name="$1" source="${2:-}"
  [[ -z "$name" || -z "$source" ]] && { printf 'ERROR: usage: ./repo.sh add <name> <host-path|git-url>\n' >&2; exit 1; }
  validate_repo_name "$name" || exit 1

  if repo_is_registered "$name"; then
    printf "ERROR: repo '%s' is already registered.\n" "$name" >&2
    printf "       Refresh it:  ./repo.sh sync %s\n" "$name" >&2
    printf "       Recreate it: ./repo.sh rm %s && ./repo.sh add %s <source>\n" "$name" "$name" >&2
    exit 1
  fi

  local type
  if is_git_url "$source"; then type="git"; else type="path"; fi

  if [[ "$type" == "path" ]]; then
    source="$(resolve_path "$source")"
    if [[ ! -d "$source" ]]; then
      printf 'ERROR: source path does not exist or is not a directory: %s\n' "$source" >&2
      exit 1
    fi
  fi

  local backend; backend="$(repo_effective_backend "$type")"
  local now; now="$(date +%s)"

  if [[ "$backend" == "bind" ]]; then
    # Linux + path source: no volume, no copy. The registry entry is a named
    # alias; runme.sh bind-mounts the source path directly (native speed here).
    repo_registry_upsert "$name" "$type" "$source" "$now" "$now" "$backend"
    printf 'OK: repo "%s" registered (bind-mount backend — no volume seeded on this host).\n' "$name"
    printf '    /workspace/%s will bind-mount %s at run time.\n' "$name" "$source"
    printf '    Attach it:  REPOS="%s:ro" ./runme.sh restricted /path/to/workspace\n' "$name"
    return
  fi

  local vol; vol="$(repo_volume_name "$name")"
  ensure_seed_image
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    printf "ERROR: docker volume '%s' already exists but '%s' is not registered.\n" "$vol" "$name" >&2
    printf "       Remove the stray volume first: docker volume rm %s\n" "$vol" >&2
    exit 1
  fi

  docker volume create "$vol" >/dev/null
  if [[ "$type" == "git" ]]; then
    seed_from_git "$vol" "$source"
  else
    seed_from_path "$vol" "$source"
  fi

  repo_registry_upsert "$name" "$type" "$source" "$now" "$now" "$backend"
  printf 'OK: repo "%s" (%s) seeded into volume "%s" and registered.\n' "$name" "$type" "$vol"
  printf '    Attach it:  REPOS="%s:ro" ./runme.sh restricted /path/to/workspace\n' "$name"
}

# Sync a single registered repo from its source (used by cmd_sync).
sync_one() {
  local name="$1"
  local record; record="$(repo_registry_lookup "$name")" || {
    printf "  SKIP %s: not registered.\n" "$name" >&2
    return 0
  }
  local type source vol backend
  type="$(repo_record_field "$record" 2)"
  source="$(repo_record_field "$record" 3)"
  vol="$(repo_volume_name "$name")"
  backend="$(repo_record_backend "$record")"

  if [[ "$backend" == "bind" ]]; then
    [[ -d "$source" ]] || printf "  WARNING: %s: bind-mount source no longer exists: %s\n" "$name" "$source" >&2
    printf '  %s: bind-mount backend — source %s is live; nothing to sync.\n' "$name" "$source"
    return 0
  fi

  ensure_seed_image
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    printf "  %s: base volume missing — re-seeding from source.\n" "$name" >&2
    docker volume create "$vol" >/dev/null
    if [[ "$type" == "git" ]]; then seed_from_git "$vol" "$source"; else seed_from_path "$vol" "$source"; fi
  else
    if [[ "$type" == "git" ]]; then sync_from_git "$vol"; else sync_from_path "$vol" "$source"; fi
  fi

  local now added; now="$(date +%s)"
  added="$(repo_record_field "$record" 4)"
  repo_registry_upsert "$name" "$type" "$source" "$added" "$now" "$backend"
  printf '  OK: %s synced.\n' "$name"
}

cmd_sync() {
  local do_all=0 name=""
  while (( $# )); do
    case "$1" in
      --all) do_all=1 ;;
      -*)    printf 'ERROR: unknown flag %s\n' "$1" >&2; exit 1 ;;
      *)     [[ -n "$name" ]] && { printf 'ERROR: sync takes a single <name> (or --all).\n' >&2; exit 1; }; name="$1" ;;
    esac
    shift
  done

  if (( do_all )) && [[ -n "$name" ]]; then
    printf 'ERROR: pass either <name> or --all, not both.\n' >&2; exit 1
  fi
  if (( ! do_all )) && [[ -z "$name" ]]; then
    printf 'ERROR: usage: ./repo.sh sync <name|--all>\n' >&2; exit 1
  fi

  local targets=()
  if (( do_all )); then
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && targets+=("$n"); done < <(repo_registry_names)
    if (( ${#targets[@]} == 0 )); then
      printf 'No repos registered. Nothing to sync.\n'
      return 0
    fi
  else
    validate_repo_name "$name" || exit 1
    repo_is_registered "$name" || {
      printf "ERROR: repo '%s' is not registered. See: ./repo.sh list\n" "$name" >&2
      exit 1
    }
    targets+=("$name")
  fi

  local target
  for target in "${targets[@]}"; do
    sync_one "$target"
  done
  printf 'NOTE: :rw / :rwcopy working copies are NOT updated by sync — use ./repo.sh reset <name>, or remove the working-copy volumes to re-seed.\n'
}

cmd_list() {
  local show_sizes=0
  [[ "${1:-}" == "--sizes" ]] && show_sizes=1
  repo_registry_ensure
  # The size probe runs `du` inside the seed helper image; build it on demand.
  (( show_sizes )) && ensure_seed_image

  local names; names="$(repo_registry_names)"
  if [[ -z "$names" ]]; then
    printf 'No repos registered. Add one with: ./repo.sh add <name> <host-path|git-url>\n'
    return 0
  fi

  printf '%-16s %-5s %-8s %-19s %s\n' "NAME" "TYPE" "BACKEND" "LAST SYNCED" "SOURCE"
  local name record type source synced vol backend present size
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    record="$(repo_registry_lookup "$name")"
    type="$(repo_record_field "$record" 2)"
    source="$(repo_record_field "$record" 3)"
    synced="$(repo_record_field "$record" 5)"
    vol="$(repo_volume_name "$name")"
    backend="$(repo_record_backend "$record")"
    if [[ "$backend" == "bind" ]]; then
      if [[ -d "$source" ]]; then present="bind"; else present="bind!"; fi
    elif docker volume inspect "$vol" >/dev/null 2>&1; then
      present="present"
    else
      present="MISSING"
    fi
    local synced_h="-"
    [[ "$synced" =~ ^[0-9]+$ ]] && synced_h="$(fmt_epoch "$synced")"
    if (( show_sizes )) && [[ "$present" == "present" ]]; then
      size="$(docker run --rm --entrypoint sh -v "$vol":/v "$seed_image" -c 'du -sh /v 2>/dev/null | cut -f1' 2>/dev/null || echo '?')"
      printf '%-16s %-5s %-8s %-19s %s  (%s)\n' "$name" "$type" "$present" "$synced_h" "$source" "$size"
    else
      printf '%-16s %-5s %-8s %-19s %s\n' "$name" "$type" "$present" "$synced_h" "$source"
    fi
  done <<< "$names"
}

cmd_rm() {
  local name="$1" assume_yes=0
  [[ "${2:-}" == "--yes" ]] && assume_yes=1
  [[ -z "$name" ]] && { printf 'ERROR: usage: ./repo.sh rm <name> [--yes]\n' >&2; exit 1; }
  validate_repo_name "$name" || exit 1

  if ! repo_is_registered "$name" && ! docker volume inspect "$(repo_volume_name "$name")" >/dev/null 2>&1; then
    printf "Nothing to remove: '%s' is neither registered nor has a volume.\n" "$name"
    return 0
  fi

  local vol; vol="$(repo_volume_name "$name")"
  # Find any per-workspace writable working copies.
  local workcopies; workcopies="$(docker volume ls --quiet --filter "name=${vol}--wc-" 2>/dev/null || true)"
  local has_base=0
  docker volume inspect "$vol" >/dev/null 2>&1 && has_base=1

  printf 'About to remove repo "%s":\n' "$name"
  if (( has_base )); then
    printf '  - base volume:    %s\n' "$vol"
  else
    printf '  - (no volume — bind-mount backend; host source is left untouched)\n'
  fi
  if [[ -n "$workcopies" ]]; then
    printf '  - working copies (may contain UNCOMMITTED changes):\n'
    printf '      %s\n' $workcopies
  fi
  printf '  - registry entry in %s\n' "$repo_registry_file"

  if (( ! assume_yes )); then
    if [[ -t 0 ]]; then
      read -r -p "Proceed? Type 'yes' to confirm: " reply
      [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
    else
      printf 'ERROR: refusing to remove non-interactively without --yes.\n' >&2
      exit 1
    fi
  fi

  docker volume rm "$vol" >/dev/null 2>&1 || true
  local wc
  for wc in $workcopies; do
    docker volume rm "$wc" >/dev/null 2>&1 || true
  done
  repo_registry_remove "$name"
  printf 'OK: removed repo "%s".\n' "$name"
}

# Reset a single registered repo to a clean state (used by cmd_reset).
reset_one() {
  local name="$1"
  local record; record="$(repo_registry_lookup "$name")" || {
    printf "  SKIP %s: not registered.\n" "$name" >&2
    return 0
  }
  local type source vol backend
  type="$(repo_record_field "$record" 2)"
  source="$(repo_record_field "$record" 3)"
  vol="$(repo_volume_name "$name")"
  backend="$(repo_record_backend "$record")"

  if [[ "$backend" == "bind" ]]; then
    printf '  %s: bind-mount backend — host source %s is live; not touching host files.\n' "$name" "$source"
    printf '         Clean it directly, e.g.: git -C %s reset --hard && git -C %s clean -ffdx\n' "$source" "$source"
    return 0
  fi

  ensure_seed_image
  # Drop per-workspace writable working copies (that is where active edits live).
  local workcopies wc
  workcopies="$(docker volume ls --quiet --filter "name=${vol}--wc-" 2>/dev/null || true)"
  for wc in $workcopies; do
    docker volume rm "$wc" >/dev/null 2>&1 && printf '  %s: removed working copy %s\n' "$name" "$wc" || true
  done

  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    printf '  %s: base volume missing — re-seeding clean from source.\n' "$name"
    docker volume create "$vol" >/dev/null
    if [[ "$type" == "git" ]]; then seed_from_git "$vol" "$source"; else seed_from_path "$vol" "$source"; fi
  else
    if [[ "$type" == "git" ]]; then reset_git "$vol"; else sync_from_path "$vol" "$source"; fi
  fi

  local now added; now="$(date +%s)"
  added="$(repo_record_field "$record" 4)"
  repo_registry_upsert "$name" "$type" "$source" "$added" "$now" "$backend"
  printf '  OK: %s reset to a clean state.\n' "$name"
}

cmd_reset() {
  local assume_yes=0 do_all=0 name=""
  while (( $# )); do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      --all)    do_all=1 ;;
      -*)       printf 'ERROR: unknown flag %s\n' "$1" >&2; exit 1 ;;
      *)        [[ -n "$name" ]] && { printf 'ERROR: reset takes a single <name> (or --all).\n' >&2; exit 1; }; name="$1" ;;
    esac
    shift
  done

  if (( do_all )) && [[ -n "$name" ]]; then
    printf 'ERROR: pass either <name> or --all, not both.\n' >&2; exit 1
  fi
  if (( ! do_all )) && [[ -z "$name" ]]; then
    printf 'ERROR: usage: ./repo.sh reset <name|--all> [--yes]\n' >&2; exit 1
  fi

  local targets=()
  if (( do_all )); then
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && targets+=("$n"); done < <(repo_registry_names)
    if (( ${#targets[@]} == 0 )); then
      printf 'No repos registered. Nothing to reset.\n'
      return 0
    fi
  else
    validate_repo_name "$name" || exit 1
    repo_is_registered "$name" || {
      printf "ERROR: repo '%s' is not registered. See: ./repo.sh list\n" "$name" >&2
      exit 1
    }
    targets+=("$name")
  fi

  if (( ! assume_yes )); then
    printf 'About to RESET the following repo(s) to a clean state:\n'
    local t; for t in "${targets[@]}"; do printf '  - %s\n' "$t"; done
    printf 'This DISCARDS uncommitted changes and untracked/ignored files (git: reset --hard\n'
    printf '+ clean -ffdx; path: rsync mirror) and removes any :rwcopy working copies. Cannot be undone.\n'
    if [[ -t 0 ]]; then
      read -r -p "Type 'yes' to confirm: " reply
      [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
    else
      printf 'ERROR: refusing to reset non-interactively without --yes.\n' >&2
      exit 1
    fi
  fi

  # ensure_seed_image runs lazily inside reset_one (only for non-bind repos).
  local target
  for target in "${targets[@]}"; do
    reset_one "$target"
  done
  printf 'OK: reset complete.\n'
}

# ── Entry point ──────────────────────────────────────────────────────────────────

command="${1:-usage}"
shift || true

case "$command" in
  add)              cmd_add  "${1:-}" "${2:-}" ;;
  sync)             cmd_sync "$@" ;;
  reset)            cmd_reset "$@" ;;
  list)             cmd_list "${1:-}" ;;
  rm|remove)        cmd_rm   "${1:-}" "${2:-}" ;;
  -h|--help|help|usage) usage ;;
  *)                usage >&2; exit 1 ;;
esac
