#!/usr/bin/env bash
set -euo pipefail
unset CDPATH  # a relative cd follows it and prints the directory (bugs review GIT-17, GIT-20)

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
  ./repo.sh reset <name | --all> [--yes]         Clean slate: primary branch, remote tip, other branches dropped
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
# They come from the environment or a committed sandbox.env, and they reach the
# seed containers' root scripts, so they are checked here, before any docker
# command, by the rule sandbox.sh applies — and handed to those scripts as an
# argument, never as text (bugs review ENV-2; tests/test-repo-ids.sh).
if [[ ! "$host_uid" =~ ^[0-9]{1,10}$ || ! "$host_gid" =~ ^[0-9]{1,10}$ ]] \
   || (( 10#$host_uid > 4294967294 || 10#$host_gid > 4294967294 )); then
  printf 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric ids from 0 to 4294967294 (got %q / %q).\n' "$host_uid" "$host_gid" >&2
  exit 1
fi

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
#
# Also resolves seed_selinux_opt, which every seed container passes: each one
# bind-mounts a host path — the source tree, or ~/.ssh for a git repo — and an
# SELinux daemon denies that to a labelled container
# (sandbox-common.sh: selinux_security_opt()). Here because every path that runs
# one comes through here after its arguments are validated and before it creates
# or removes anything, so an unknown SELINUX_LABEL leaves no half-made volume.
seed_selinux_opt=""
ensure_seed_image() {
  seed_selinux_opt="$(selinux_security_opt)" || exit 1
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
  docker run --rm --entrypoint bash ${seed_selinux_opt:+"$seed_selinux_opt"} \
    -v "$real":/src:ro \
    -v "$vol":/dst \
    "$seed_image" -c 'cp -a /src/. /dst/ && chown -R "$1" /dst' _ "${host_uid}:${host_gid}"
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
  docker run --rm --entrypoint bash ${seed_selinux_opt:+"$seed_selinux_opt"} \
    -v "$real":/src:ro \
    -v "$vol":/dst \
    "$seed_image" -c '
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete /src/ /dst/
      else
        echo "NOTE: rsync not in image; using cp -a (updates/adds only, no deletions)." >&2
        cp -a /src/. /dst/
      fi
      chown -R "$1" /dst' _ "${host_uid}:${host_gid}"
}

# Clone a git URL into a fresh volume, authenticating with the host ~/.ssh.
seed_from_git() {
  local vol="$1" url="$2"
  printf 'Cloning %s into volume "%s" (auth via host ~/.ssh) ...\n' "$url" "$vol"
  docker run --rm --entrypoint bash ${seed_selinux_opt:+"$seed_selinux_opt"} \
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

# Pull latest into an existing git volume — through repo-git-reset.sh's pull,
# which, like reset, never runs git on the volume's own .git (a :rw volume's is
# the agent's to write, and this container holds your ~/.ssh keys): it clones
# afresh, fast-forwards the checkout from that clone, and refuses whatever it
# could lose.
sync_from_git() {
  local vol="$1" out
  printf 'Pulling latest into volume "%s" (auth via host ~/.ssh) ...\n' "$vol"
  out="$(git_helper_run "$vol" pull /dst "${host_uid}:${host_gid}")" || return 1
  # Every WARN record reaches the user: a ref sync could not keep is lost
  # (review of 82698a0, F2).
  local line
  while IFS= read -r line; do
    case "$line" in
      'WARN|chown failed') printf 'WARNING: could not chown the volume to %s\n' "${host_uid}:${host_gid}" >&2 ;;
      WARN\|*)            printf 'WARNING: %s\n' "${line#WARN|}" >&2 ;;
    esac
  done <<<"$out"
}

# The git half of `reset` lives in repo-git-reset.sh, mounted read-only into the
# seed container rather than embedded here as a string. It is a dozen git calls
# with branch detection, fallbacks and a destructive loop, and a string can only
# ever be ASSERTED, never RUN, by the hermetic suite — see that file's header and
# tests/test-repo-git-reset.sh, which drives it against real repositories.
# Mounting (rather than baking into Dockerfile.seed) keeps every existing seed
# image working with no rebuild.
git_helper_run() {   # $1 = volume  $2... = repo-git-reset.sh arguments
  local vol="$1" url; shift
  # The URL repo.sh recorded at `add` — a volume label, which nothing inside a
  # container can change — is the one remote the helper fetches from.
  url="$(docker_volume_label "$vol" 'ai-containers.source')"
  if [[ -z "$url" ]]; then
    printf "ERROR: volume %s carries no recorded source URL (no ai-containers.source label), so its\n" "$vol" >&2
    printf "       git is not run. Re-create it: ./repo.sh rm <name>, then ./repo.sh add <name> <url>.\n" >&2
    return 1
  fi
  # An agent with the volume mounted read-write could rewrite its .git between
  # the helper's check and git reading it, so not while one runs.
  if docker_volume_mounted_rw "$vol"; then
    printf "ERROR: volume %s is mounted read-write by a running container; stop it first.\n" "$vol" >&2
    return 1
  fi
  # Bounded, so nothing the agent left in the volume can make git exhaust the
  # host (review of fb1705e, Q3): memory, with swap capped to it (--memory alone
  # lets swap double it), and processes (bugs review REPO-7). REPO_HELPER_MEMORY
  # raises the memory for a huge repository; it reaches docker's argv, so it is
  # checked to be a size first.
  local mem="${REPO_HELPER_MEMORY:-4g}" rc=0
  if [[ ! "$mem" =~ ^[1-9][0-9]*[kKmMgG]?$ ]]; then
    printf "ERROR: REPO_HELPER_MEMORY=%q is not a size such as 4g or 8192m.\n" "$mem" >&2
    return 1
  fi
  docker run --rm --memory "$mem" --memory-swap "$mem" --pids-limit 512 --entrypoint bash ${seed_selinux_opt:+"$seed_selinux_opt"} \
    -e AI_REPO_URL="$url" \
    -v "$HOME/.ssh":/root/.ssh-host:ro \
    -v "${script_dir}/repo-git-reset.sh":/repo-git-reset.sh:ro \
    -v "$vol":/dst \
    "$seed_image" -c '
      mkdir -p /root/.ssh && cp -a /root/.ssh-host/. /root/.ssh/ 2>/dev/null || true
      chmod 700 /root/.ssh; chmod 600 /root/.ssh/* 2>/dev/null || true
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
      exec bash /repo-git-reset.sh "$@"' _ "$@" || rc=$?
  if (( rc == 137 )); then
    printf "ERROR: the git helper was killed (exit 137), most likely for exceeding its %s memory limit;\n" "$mem" >&2
    printf "       raise REPO_HELPER_MEMORY (e.g. REPO_HELPER_MEMORY=8g) for a very large repository.\n" >&2
  fi
  return "$rc"
}

# Read-only pass: the helper clones the recorded remote privately, then reports
# the remote's primary branch and every local branch with the number of its
# commits on no remote branch (`?` when it cannot tell). This is what the
# confirmation prompt is built from; the volume itself is not changed.
inspect_git() {   # $1 = volume  → the helper's records on stdout
  git_helper_run "$1" inspect /dst
}

# Destructive pass: the volume becomes a clean checkout of $2 at the remote's
# tip — its whole .git replaced by a fresh clone's, so local changes, untracked
# and ignored files, other branches, stashes, tags on no remote and per-repo
# config all go. It clones again, so it lands on the tip at reset time, which a
# force-push since the prompt could have moved. It is handed the branch NAME the
# prompt displayed, so what was approved is what happens.
reset_git() {   # $1 = volume  $2 = primary branch
  local vol="$1" primary="$2" out line kind rest on="" at=""
  printf 'Resetting volume "%s" to a clean checkout on "%s" ...\n' "$vol" "$primary"

  # The helper speaks records (DELETED|x, ON|y, AT|z, …) because a test needs to
  # read them. A person does not: unrendered they arrive as `DELETED|throwaway`,
  # `AT|3500160`, which reads like debug output leaking through. Captured and
  # translated here, so the protocol stays machine-readable and the terminal
  # stays prose. stderr is deliberately NOT captured — the helper's `die`
  # messages should reach the user unaltered and immediately.
  # Rendered whether or not it succeeds: a reset that fails after removing the
  # git repositories inside the checkout still says which (REPO-5).
  local rc=0
  out="$(git_helper_run "$vol" reset /dst "$primary" "${host_uid}:${host_gid}")" || rc=$?

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%%|*}"; rest="${line#*|}"
    case "$kind" in
      DELETED)       printf '  removed branch %s\n' "$rest" ;;
      REMOVED)       printf '  removed the git repository inside the checkout at %s\n' "$rest" ;;
      KEPT)          printf '  WARNING: kept branch %s — %s\n' "${rest%%|*}" "${rest#*|}" >&2 ;;
      WARN)          printf '  WARNING: %s\n' "$rest" >&2 ;;
      ON)            on="$rest" ;;
      AT)            at="$rest" ;;
      DELETED-COUNT) ;;   # each deletion is already named above
      # Anything this function does not recognise is printed VERBATIM rather
      # than dropped. A record type added to the helper later would otherwise
      # vanish here, and silence is the one thing a reset must never report.
      *)             printf '  %s\n' "$line" ;;
    esac
  done <<< "$out"

  if (( rc != 0 )); then
    printf '  ERROR: the git reset failed inside the seed container.\n' >&2
    return 1
  fi
  [[ -n "$on" ]] && printf '  now on %s%s\n' "$on" "${at:+ at $at}"
  return 0
}

cmd_add() {
  local name="$1" source="${2:-}"
  [[ -z "$name" || -z "$source" ]] && { printf 'ERROR: usage: ./repo.sh add <name> <host-path|git-url>\n' >&2; exit 1; }
  validate_repo_name "$name" || exit 1
  # A new name may not hold `--`: repo `app`'s working copy `ui` is the volume
  # ai-containers-repo-app--wc-ui, which is also repo `app--wc-ui`'s base volume
  # (bugs review PRJ-5). Only new names: an existing one is still synced and removed.
  [[ "$name" != *--* ]] || { printf "ERROR: repo name '%s' contains '--', which working-copy volume names use; choose another.\n" "$name" >&2; exit 1; }

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
    local owner; owner="$(foreign_base_owner "$name" "$vol")"
    if [[ -n "$owner" ]]; then
      # Not stray: another repo's, under a prefix whose names collide (REPO-11).
      printf "       It is labelled for repo '%s' — not yours to remove. Choose another name.\n" "$owner" >&2
    else
      printf "       Remove the stray volume first: docker volume rm %s\n" "$vol" >&2
    fi
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

  # Another repo's base volume is not this one's to rsync --delete or pull into
  # (REPO-11). A missing volume names no owner, so it is still re-seeded.
  local owner; owner="$(foreign_base_owner "$name" "$vol")"
  if [[ -n "$owner" ]]; then
    printf '  SKIP %s: volume %s is labelled for repo "%s"; left untouched.\n' "$name" "$vol" "$owner" >&2
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

# foreign_base_owner <name> <vol>: the repo another than <name> that <vol>'s
# ai-containers.repo label names, or nothing. A volume is found by name, and
# under a nested REPO_VOLUME_PREFIX two repos' names collide: `rm team-repo-x`
# deleted repo x's base volume of prefix <p>-repo-team, labelled x (bugs review
# REPO-11). An unlabelled volume — one made before labels — names no owner.
foreign_base_owner() {
  local owner
  owner="$(docker_volume_label "$2" ai-containers.repo)"
  [[ -n "$owner" && "$owner" != "$1" ]] && printf '%s' "$owner"
  return 0
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
  local workcopies; workcopies="$(repo_workcopy_volumes "$name")"
  local has_base=0 owner
  docker volume inspect "$vol" >/dev/null 2>&1 && has_base=1
  if (( has_base )); then
    owner="$(foreign_base_owner "$name" "$vol")"
    if [[ -n "$owner" ]]; then
      printf 'ERROR: volume %s is labelled for repo "%s", not "%s"; refusing to remove it.\n' "$vol" "$owner" "$name" >&2
      if [[ "$vol" == *"-repo-$owner" ]]; then
        printf '       It is repo "%s" of REPO_VOLUME_PREFIX=%s, whose name collides with this one;\n' "$owner" "${vol%-repo-"$owner"}" >&2
        printf '       "%s" has no base volume of its own under this prefix.\n' "$name" >&2
      fi
      if repo_is_registered "$name"; then
        printf '       To drop only the registry entry for "%s", delete its line from %s;\n' "$name" "$repo_registry_file" >&2
        printf '       its own working copies, if any: ./repo.sh gc --repo %s\n' "$name" >&2
      fi
      exit 1
    fi
  fi

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
  local name="$1" primary="${2:-}"
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

  # Before anything is removed: a base volume that belongs to another repo is not
  # this one's to reset (REPO-11).
  local owner; owner="$(foreign_base_owner "$name" "$vol")"
  if [[ -n "$owner" ]]; then
    printf '  SKIP %s: volume %s is labelled for repo "%s"; left untouched.\n' "$name" "$vol" "$owner" >&2
    return 0
  fi

  ensure_seed_image
  # Drop per-workspace writable working copies (that is where active edits live).
  local workcopies wc
  workcopies="$(repo_workcopy_volumes "$name")"
  for wc in $workcopies; do
    docker volume rm "$wc" >/dev/null 2>&1 && printf '  %s: removed working copy %s\n' "$name" "$wc" || true
  done

  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    printf '  %s: base volume missing — re-seeding clean from source.\n' "$name"
    repo_base_volume_create "$name" "$type" "$source"
    if [[ "$type" == "git" ]]; then seed_from_git "$vol" "$source"; else seed_from_path "$vol" "$source"; fi
  else
    if [[ "$type" != "git" ]]; then
      sync_from_path "$vol" "$source"
    elif [[ -n "$primary" ]]; then
      reset_git "$vol" "$primary"
    else
      # detect_primary falls back all the way to the checked-out branch, so an
      # empty answer means a detached HEAD with no usable remote. Guessing a
      # branch there would be inventing the target of a destructive operation.
      printf '  %s: no branch to reset onto (detached HEAD, no usable remote) — left untouched.\n' "$name"
      printf '         Inspect it directly, or re-add the repo to re-clone it.\n'
      return 0
    fi
  fi

  local now added; now="$(date +%s)"
  added="$(repo_record_field "$record" 4)"
  repo_registry_upsert "$name" "$type" "$source" "$added" "$now" "$backend"
  printf '  OK: %s reset to a clean state.\n' "$name"
}

# What `reset` is about to destroy, gathered BEFORE anything is destroyed.
#
# Filled by collect_inspections(), read by the prompt and then by reset_one, so
# the branch named in the summary is the branch reset is handed — not a second
# derivation that could disagree with what was approved.
declare -A RESET_PRIMARY=()
declare -A RESET_STALE=()
RESET_SUMMARY=()
RESET_AT_RISK=0

collect_inspections() {   # $@ = repo names
  local name record type vol backend line kind rest br unpushed flags
  for name in "$@"; do
    record="$(repo_registry_lookup "$name")" || continue
    type="$(repo_record_field "$record" 2)"
    backend="$(repo_record_backend "$record")"
    vol="$(repo_volume_name "$name")"

    # Bind-backed repos are the live host checkout and reset never writes to
    # them; path-sourced volumes are mirrored from the host, not branched.
    if [[ "$backend" == "bind" ]]; then
      RESET_SUMMARY+=("  - ${name}: bind-mount backend — host source untouched")
      continue
    fi
    # Before the type branches, so a path repo on another repo's volume is not
    # announced as re-mirrored (a missing volume names no owner).
    local owner; owner="$(foreign_base_owner "$name" "$vol")"
    if [[ -n "$owner" ]]; then
      RESET_SUMMARY+=("  - ${name}: ${vol} is labelled for repo '${owner}' — will be left untouched")
      continue
    fi
    if [[ "$type" != "git" ]]; then
      RESET_SUMMARY+=("  - ${name}: re-mirrored from its host source (no branches)")
      continue
    fi
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
      RESET_SUMMARY+=("  - ${name}: base volume missing — will be re-cloned clean")
      continue
    fi

    ensure_seed_image
    local branches=() tags=() nested=() primary="" stale="" stash_n="" nested_more=""
    while IFS= read -r line; do
      kind="${line%%|*}"; rest="${line#*|}"
      case "$kind" in
        PRIMARY) primary="$rest" ;;
        STALE)   stale="$rest" ;;
        BRANCH)
          br="${rest%%|*}"; rest="${rest#*|}"
          unpushed="${rest%%|*}"; flags="${rest#*|}"
          branches+=("${br}|${unpushed}|${flags}")
          ;;
        STASH) stash_n="$rest" ;;
        TAG)   tags+=("$rest") ;;
        NESTED) nested+=("$rest") ;;
        NESTED-MORE) nested_more="$rest" ;;
      esac
    done < <(inspect_git "$vol")

    [[ -n "$primary" ]] && RESET_PRIMARY["$name"]="$primary"
    [[ -n "$stale"   ]] && RESET_STALE["$name"]="$stale"

    if [[ -z "$primary" ]]; then
      # Its working copies are still removed, as reset_one does for every repo
      # it resets: only the base volume's checkout is skipped.
      RESET_SUMMARY+=("  - ${name}: no branch to reset onto (detached HEAD, no usable remote) — its base volume will be left untouched; its working copies are still removed")
      continue
    fi
    # Built as a plain variable, not inlined as $( … ): a command substitution
    # that exits non-zero sets the status of the assignment containing it, and
    # under `set -e` that ends the script — here, on the ordinary path where
    # the fetch SUCCEEDED and $stale is empty.
    local stale_note="" entry
    [[ -n "$stale" ]] && stale_note=" (STALE: fetch failed)"
    RESET_SUMMARY+=("  - ${name}: switches to '${primary}'${stale_note}")
    # The primary branch is moved to the remote's tip, so commits it has that no
    # remote has are lost exactly like a deleted branch's: they were skipped here
    # with no warning (review of REPO-8).
    for entry in "${branches[@]}"; do
      br="${entry%%|*}"; rest="${entry#*|}"; unpushed="${rest%%|*}"
      [[ "$br" == "$primary" ]] || continue
      if [[ ! "$unpushed" =~ ^[0-9]+$ ]]; then
        RESET_SUMMARY+=("      MOVE ${br} to the remote's tip — unpushed count unknown  <-- may hold unpushed work")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      elif [[ "$unpushed" -gt 0 ]]; then
        RESET_SUMMARY+=("      MOVE ${br} to the remote's tip — ${unpushed} commit(s) not on any remote  <-- unpushed work")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      fi
    done

    for entry in "${branches[@]}"; do
      br="${entry%%|*}"; rest="${entry#*|}"
      unpushed="${rest%%|*}"
      [[ "$br" == "$primary" ]] && continue
      # A count the helper could not make (`?`) is never read as 0 — that is the
      # branch a summary saying "pushed" would lose.
      if [[ ! "$unpushed" =~ ^[0-9]+$ ]]; then
        RESET_SUMMARY+=("      DELETE ${br} — unpushed count unknown  <-- may hold unpushed work")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      elif [[ "${unpushed:-0}" -gt 0 ]]; then
        RESET_SUMMARY+=("      DELETE ${br} — ${unpushed} commit(s) not on any remote  <-- unpushed work")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      else
        RESET_SUMMARY+=("      DELETE ${br} — pushed")
      fi
    done
    # A git repository inside the checkout (an initialised submodule, an editable
    # install's clone) is removed before reset runs git; its own history is not
    # on this repository's remote, so it is counted at risk (REPO-5).
    local np
    for np in ${nested[@]+"${nested[@]}"}; do
      RESET_SUMMARY+=("      REMOVE ${np} — a git repository inside the checkout  <-- its history is not on this repo's remote")
      RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
    done
    if [[ -n "$nested_more" ]]; then
      RESET_SUMMARY+=("      REMOVE ${nested_more} more git repositories inside the checkout  <-- not listed")
      [[ "$nested_more" =~ ^[0-9]+$ ]] && RESET_AT_RISK=$(( RESET_AT_RISK + nested_more )) || RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
    fi
    # Besides branches, replacing .git loses the stash and any tag the remote
    # does not have (bugs review REPO-8); a tag can hold the only reference to a
    # commit, and none of it can be undone.
    if [[ -n "$stash_n" ]]; then
      if [[ "$stash_n" =~ ^[0-9]+$ ]]; then
        RESET_SUMMARY+=("      DROP the stash (${stash_n} entr(y/ies))  <-- not kept by reset")
      else
        RESET_SUMMARY+=("      DROP the stash (entries unknown)  <-- not kept by reset")
      fi
      RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
    fi
    local tg tname tkept ton
    for tg in ${tags[@]+"${tags[@]}"}; do
      tname="${tg%%|*}"; tg="${tg#*|}"; tkept="${tg%%|*}"; ton="${tg#*|}"
      [[ "$tkept" == yes ]] && continue
      if [[ "$ton" == yes ]]; then
        RESET_SUMMARY+=("      DROP tag ${tname} — not on the remote (the commit it marks is on a remote branch)")
      elif [[ "$tkept" == '?' || "$ton" == '?' ]]; then
        RESET_SUMMARY+=("      DROP tag ${tname} — whether the remote has it, or its commit, is unknown  <-- may be lost")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      else
        RESET_SUMMARY+=("      DROP tag ${tname} — not on the remote, and the commit it marks is on no remote branch  <-- lost")
        RESET_AT_RISK=$(( RESET_AT_RISK + 1 ))
      fi
    done
  done
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

  # The inspection runs FIRST and unconditionally — before the prompt, and even
  # under --yes. It is also the fetch, so the "not on any remote" counts below
  # are measured against current remote refs rather than whatever this volume
  # last happened to see.
  collect_inspections "${targets[@]}"

  printf 'About to RESET the following repo(s) to a clean state:\n'
  local l; for l in "${RESET_SUMMARY[@]}"; do printf '%s\n' "$l"; done
  printf 'This DISCARDS uncommitted changes and untracked/ignored files (git: reset --hard\n'
  printf '+ clean -ffdx; path: rsync mirror), DELETES the local branches, the stash, the\n'
  printf 'tags and the nested repositories listed above, and removes any :rwcopy working\n'
  printf 'copies. Cannot be undone.\n'
  if (( RESET_AT_RISK > 0 )); then
    printf '\nWARNING: %s item(s) above (branches, a stash, tags, repositories) hold work that is on no remote.\n' "$RESET_AT_RISK"
    printf '         Resetting discards it. Push it first if you want it.\n\n'
  fi

  if (( ! assume_yes )); then
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
    if [[ -n "${RESET_STALE[$target]:-}" ]]; then
      printf 'WARNING: %s: fetch failed (%s).\n' "$target" "${RESET_STALE[$target]}" >&2
      printf '         Continuing with the LOCAL reset: the tree will be clean and on the\n' >&2
      printf '         primary branch, but at the remote tip as last fetched, not as of now.\n' >&2
    fi
    reset_one "$target" "${RESET_PRIMARY[$target]:-}"
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
