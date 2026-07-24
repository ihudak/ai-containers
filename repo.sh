#!/usr/bin/env bash
set -euo pipefail

# repo.sh — manage shared, native-speed repo volumes for the AI sandbox.
#
# Repo volumes are Docker named volumes living inside the Colima/Docker VM, so
# containers read them at native speed instead of paying the virtiofs penalty of
# host bind mounts. They are GLOBAL (shared across all container groups) and
# tracked in a registry at ~/.ai-containers/repos.conf.
#
# Seed a repo ONCE, then attach it to any number of containers via the sandbox.sh
# REPOS variable:  REPOS="cluster:ro lib:ro app:rw" ./sandbox.sh restricted /ws

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./repo.sh add  <name> <host-path | git-url>   Seed a repo volume and register it
  ./repo.sh sync <name | --all>                  Refresh a repo volume from its source
  ./repo.sh reset <name | --all> [--yes]         Discard local changes (clean slate; keeps the repo)
  ./repo.sh list [--sizes] [--copies]            List repos (--copies lists :rwcopy working copies)
  ./repo.sh rm   <name> [--yes]                  Remove a repo volume + its working copies
  ./repo.sh gc   [--repo <name>] [--unused] [--yes]
                                                 Prune :rwcopy working-copy volumes
  ./repo.sh reindex                              Rebuild the registry from volume labels

Notes:
  - Repo volumes are GLOBAL — one volume per repo name, shared by containers in
    ANY project/image and ANY AI_CONTAINER_GROUP. No IMAGE_NAME juggling: register
    once with 'add', then attach the same volume to as many containers as you like.
  - Docker volumes are the source of truth. Base volumes are labeled with their
    repo name/type/source and working copies with their repo + launch dir, so
    'list'/'gc' read them directly. The registry (repos.conf) is a cache: it is
    authoritative only for Linux bind-backend repos (no volume) and the mutable
    last-synced time, and is rebuildable from labels with 'reindex'.
  - Authentication for git-url sources uses your HOST ~/.ssh (mounted read-only).
  - Volume contents are chowned to SANDBOX_UID/SANDBOX_GID (default id -u/id -g),
    the SAME identity sandbox.sh runs the container as. If you override these, set
    the SAME values for both repo.sh and sandbox.sh or mounted repos get the wrong
    owner and the in-container agent hits permission errors.
  - 'add' refuses to overwrite an existing repo; use 'sync' to refresh or 'rm' first.
  - Attach repos at run time with sandbox.sh's REPOS variable (default :ro, shared).
  - Seeding does NOT require the sandbox image. A small, shared helper image
    ("ai-containers-seed", built on demand from Dockerfile.seed) does the copy /
    clone / rsync for every project. Override with REPO_SEED_IMAGE.
  - Backend (auto by default): on macOS, 'path' and 'git' repos use Docker named
    volumes (native VM speed). On Linux, 'path' repos are registered as named
    bind-mount aliases — 'add' only updates the registry (no volume, no copy), and
    sandbox.sh bind-mounts the host path directly. Override with REPO_BACKEND.

Registry: ~/.ai-containers/repos.conf
EOF
}

# Numeric owner applied to seeded/synced volume contents. MUST match the identity
# the main container runs as, since Linux permissions are by UID/GID. sandbox.sh
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
    # alias; sandbox.sh bind-mounts the source path directly (native speed here).
    repo_registry_upsert "$name" "$type" "$source" "$now" "$now" "$backend"
    printf 'OK: repo "%s" registered (bind-mount backend — no volume seeded on this host).\n' "$name"
    printf '    /workspace/%s will bind-mount %s at run time.\n' "$name" "$source"
    printf '    Attach it:  REPOS="%s:ro" ./sandbox.sh restricted /path/to/workspace\n' "$name"
    return
  fi

  local vol; vol="$(repo_volume_name "$name")"
  ensure_seed_image
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    printf "ERROR: docker volume '%s' already exists but '%s' is not registered.\n" "$vol" "$name" >&2
    printf "       Remove the stray volume first: docker volume rm %s\n" "$vol" >&2
    exit 1
  fi

  repo_base_volume_create "$name" "$type" "$source"
  if [[ "$type" == "git" ]]; then
    seed_from_git "$vol" "$source"
  else
    seed_from_path "$vol" "$source"
  fi

  repo_registry_upsert "$name" "$type" "$source" "$now" "$now" "$backend"
  printf 'OK: repo "%s" (%s) seeded into volume "%s" and registered.\n' "$name" "$type" "$vol"
  printf '    Attach it:  REPOS="%s:ro" ./sandbox.sh restricted /path/to/workspace\n' "$name"
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
    repo_base_volume_create "$name" "$type" "$source"
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

# List working-copy (:rwcopy) volumes with their parent repo, originating launch
# directory (from labels), in-use state, and optionally size.
list_copies() {
  local show_sizes="$1"
  local copies; copies="$(repo_workcopy_volumes)"
  if [[ -z "$copies" ]]; then
    printf 'No :rwcopy working copies exist.\n'
    return 0
  fi
  printf '%-4s %-44s %-14s %-7s %s\n' "USE" "WORKING COPY VOLUME" "REPO" "SIZE" "LAUNCH DIR"
  local wc repo ldir inuse size
  while IFS= read -r wc; do
    [[ -z "$wc" ]] && continue
    if docker_volume_in_use "$wc"; then inuse="yes"; else inuse="no"; fi
    repo="$(docker_volume_label "$wc" 'ai-containers.repo')"; [[ -z "$repo" ]] && repo="?"
    ldir="$(docker_volume_label "$wc" 'ai-containers.launch-dir')"; [[ -z "$ldir" ]] && ldir="(unlabeled)"
    size="-"
    (( show_sizes )) && size="$(docker run --rm --entrypoint sh -v "$wc":/v "$seed_image" -c 'du -sh /v 2>/dev/null | cut -f1' 2>/dev/null || echo '?')"
    printf '%-4s %-44s %-14s %-7s %s\n' "$inuse" "$wc" "$repo" "$size" "$ldir"
  done <<< "$copies"
}

cmd_list() {
  local show_sizes=0 show_copies=0
  while (( $# )); do
    case "$1" in
      --sizes)  show_sizes=1 ;;
      --copies) show_copies=1 ;;
      -*)       printf 'ERROR: unknown flag %s\n' "$1" >&2; exit 1 ;;
      *)        printf 'ERROR: unexpected argument %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done
  repo_registry_ensure
  # The size probe runs `du` inside the seed helper image; build it on demand.
  (( show_sizes )) && ensure_seed_image

  if (( show_copies )); then
    list_copies "$show_sizes"
    return 0
  fi

  # Names = union of base volumes (source of truth for existence, via labels) and
  # registry entries (covers Linux bind repos, which have no volume, and surfaces
  # registry/volume drift as MISSING). Volume labels win for type/source.
  local names; names="$(
    { repo_registry_names
      local v
      while IFS= read -r v; do [[ -n "$v" ]] && repo_name_from_volume "$v"; done < <(repo_base_volumes)
    } | sort -u
  )"
  if [[ -z "$names" ]]; then
    printf 'No repos found. Add one with: ./repo.sh add <name> <host-path|git-url>\n'
    return 0
  fi

  printf '%-16s %-5s %-8s %-19s %-3s %s\n' "NAME" "TYPE" "STATE" "LAST SYNCED" "WC" "SOURCE"
  local name record type source synced vol backend state size wc_count synced_h size_str
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    vol="$(repo_volume_name "$name")"
    record="$(repo_registry_lookup "$name" || true)"
    # Prefer self-describing volume labels; fall back to the registry record.
    type="$(docker_volume_label "$vol" 'ai-containers.type')"
    source="$(docker_volume_label "$vol" 'ai-containers.source')"
    if [[ -n "$record" ]]; then
      [[ -z "$type" ]]   && type="$(repo_record_field "$record" 2)"
      [[ -z "$source" ]] && source="$(repo_record_field "$record" 3)"
      synced="$(repo_record_field "$record" 5)"
      backend="$(repo_record_backend "$record")"
    else
      synced=""
      backend="volume"
    fi
    if [[ "$backend" == "bind" ]]; then
      if [[ -d "$source" ]]; then state="bind"; else state="bind!"; fi
    elif docker volume inspect "$vol" >/dev/null 2>&1; then
      state="present"
    else
      state="MISSING"
    fi
    synced_h="-"
    [[ "$synced" =~ ^[0-9]+$ ]] && synced_h="$(fmt_epoch "$synced")"
    wc_count="$(repo_workcopy_volumes "$name" | grep -c . || true)"
    size_str=""
    if (( show_sizes )) && [[ "$state" == "present" ]]; then
      size="$(docker run --rm --entrypoint sh -v "$vol":/v "$seed_image" -c 'du -sh /v 2>/dev/null | cut -f1' 2>/dev/null || echo '?')"
      size_str="  (${size})"
    fi
    printf '%-16s %-5s %-8s %-19s %-3s %s%s\n' "$name" "${type:-?}" "$state" "$synced_h" "$wc_count" "$source" "$size_str"
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
    repo_base_volume_create "$name" "$type" "$source"
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

# Prune :rwcopy working-copy volumes. By default removes ALL working copies (of
# all repos); narrow with --repo <name>, and/or restrict to copies not currently
# mounted by a running container with --unused. Working copies may hold
# UNCOMMITTED work, so it confirms unless --yes.
cmd_gc() {
  local target_repo="" only_unused=0 assume_yes=0
  while (( $# )); do
    case "$1" in
      --repo)   shift; target_repo="${1:-}"; [[ -z "$target_repo" ]] && { printf 'ERROR: --repo needs a name\n' >&2; exit 1; } ;;
      --unused) only_unused=1 ;;
      --yes|-y) assume_yes=1 ;;
      -*)       printf 'ERROR: unknown flag %s\n' "$1" >&2; exit 1 ;;
      *)        printf 'ERROR: unexpected argument %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done
  [[ -n "$target_repo" ]] && { validate_repo_name "$target_repo" || exit 1; }

  local all; all="$(repo_workcopy_volumes "$target_repo")"
  if [[ -z "$all" ]]; then
    printf 'No working copies%s found.\n' "${target_repo:+ for repo \"$target_repo\"}"
    return 0
  fi

  local victims=() wc repo ldir inuse
  printf 'Working copies%s:\n' "${target_repo:+ for \"$target_repo\"}"
  printf '  %-4s %-44s %-14s %s\n' "USE" "VOLUME" "REPO" "LAUNCH DIR"
  while IFS= read -r wc; do
    [[ -z "$wc" ]] && continue
    if docker_volume_in_use "$wc"; then inuse="yes"; else inuse="no"; fi
    repo="$(docker_volume_label "$wc" 'ai-containers.repo')"; [[ -z "$repo" ]] && repo="?"
    ldir="$(docker_volume_label "$wc" 'ai-containers.launch-dir')"; [[ -z "$ldir" ]] && ldir="(unlabeled)"
    if (( only_unused )) && [[ "$inuse" == "yes" ]]; then
      printf '  %-4s %-44s %-14s %s  [in use — kept]\n' "$inuse" "$wc" "$repo" "$ldir"
      continue
    fi
    printf '  %-4s %-44s %-14s %s\n' "$inuse" "$wc" "$repo" "$ldir"
    victims+=("$wc")
  done <<< "$all"

  if (( ${#victims[@]} == 0 )); then
    printf 'Nothing to remove.\n'
    return 0
  fi

  printf '\nAbout to remove %d working-copy volume(s). These may hold UNCOMMITTED work.\n' "${#victims[@]}"
  if (( ! assume_yes )); then
    if [[ -t 0 ]]; then
      read -r -p "Type 'yes' to confirm: " reply
      [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
    else
      printf 'ERROR: refusing to remove non-interactively without --yes.\n' >&2
      exit 1
    fi
  fi

  local v removed=0
  for v in "${victims[@]}"; do
    if docker volume rm "$v" >/dev/null 2>&1; then
      printf '  removed %s\n' "$v"; removed=$((removed + 1))
    else
      printf '  WARN: could not remove %s (in use?)\n' "$v" >&2
    fi
  done
  printf 'OK: removed %d working-copy volume(s).\n' "$removed"
}

# Rebuild the registry (repos.conf) from the self-describing base-volume labels.
# Use this to recover a lost/stale registry, or to adopt repos seeded elsewhere.
# Additive and healing: it inserts/updates the volume-backed repos found on this
# machine and preserves their existing added/synced timestamps when known. It does
# NOT touch Linux bind-backend entries (they have no volume) and does NOT delete
# anything.
cmd_reindex() {
  repo_registry_ensure
  local now; now="$(date +%s)"
  local count=0 vol name type source record added synced
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    name="$(repo_name_from_volume "$vol")"
    type="$(docker_volume_label "$vol" 'ai-containers.type')"
    source="$(docker_volume_label "$vol" 'ai-containers.source')"
    if [[ -z "$type" || -z "$source" ]]; then
      printf 'skip %s: volume "%s" has no ai-containers labels (seeded by an older version?). Re-seed with: ./repo.sh sync %s\n' "$name" "$vol" "$name" >&2
      continue
    fi
    record="$(repo_registry_lookup "$name" || true)"
    added="$now"; synced="$now"
    if [[ -n "$record" ]]; then
      added="$(repo_record_field "$record" 4)"
      synced="$(repo_record_field "$record" 5)"
    fi
    repo_registry_upsert "$name" "$type" "$source" "$added" "$synced" "volume"
    printf 'indexed %s (%s) -> %s\n' "$name" "$type" "$source"
    count=$((count + 1))
  done < <(repo_base_volumes)
  printf 'OK: reindex complete (%d volume-backed repo(s)). Bind-backend entries left as-is.\n' "$count"
}

# ── Entry point ──────────────────────────────────────────────────────────────────

command="${1:-usage}"
shift || true

case "$command" in
  add)              cmd_add  "${1:-}" "${2:-}" ;;
  sync)             cmd_sync "$@" ;;
  reset)            cmd_reset "$@" ;;
  list)             cmd_list "$@" ;;
  rm|remove)        cmd_rm   "${1:-}" "${2:-}" ;;
  gc)               cmd_gc "$@" ;;
  reindex)          cmd_reindex ;;
  -h|--help|help|usage) usage ;;
  *)                usage >&2; exit 1 ;;
esac
