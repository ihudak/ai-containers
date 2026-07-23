#!/usr/bin/env bash
set -euo pipefail

# runme.sh — run the AI sandbox container.
#
# Build the image with ./build.sh and manage repo volumes with ./repo.sh.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"

# Parse a host-pointer value "[@]<source>[:ro|:rw]" into three globals the caller
# reads immediately: PTR_KIND (volume|path), PTR_SRC (repo name or host path),
# PTR_MODE (ro|rw — the trailing suffix when $3 is 1, else the $2 default).
parse_pointer_spec() {  # $1=raw value  $2=default mode  $3=allow_suffix(1|0)
  local val="$1" default_mode="$2" allow_suffix="$3"
  PTR_MODE="$default_mode"
  if [[ "$allow_suffix" == "1" ]]; then
    case "$val" in
      *:ro) PTR_MODE="ro"; val="${val%:ro}" ;;
      *:rw) PTR_MODE="rw"; val="${val%:rw}" ;;
    esac
  fi
  if [[ "${val:0:1}" == "@" ]]; then
    PTR_KIND="volume"; PTR_SRC="${val#@}"
  else
    PTR_KIND="path"; PTR_SRC="$val"
  fi
}

# For a @name pointer, echo "name:mode" to append to the repo list — UNLESS 'name'
# is already listed, in which case echo nothing (the existing REPOS/@primary entry
# wins) and note a mode divergence on stderr. Pass the current repo list as $3...
pointer_repo_entry() {  # $1=name  $2=mode  $3..=current repos_list entries
  local name="$1" mode="$2"; shift 2
  local e existing_mode
  for e in "$@"; do
    if [[ "${e%%:*}" == "$name" ]]; then
      existing_mode="${e##*:}"; [[ "$existing_mode" == "$name" ]] && existing_mode="ro"
      if [[ "$existing_mode" != "$mode" ]]; then
        printf "NOTE: repo '%s' is already mounted (%s); the pointer's :%s is ignored.\n" \
          "$name" "$existing_mode" "$mode" >&2
      fi
      return 0
    fi
  done
  printf '%s:%s' "$name" "$mode"
}

usage() {
  cat <<'EOF'
Usage:
  ./runme.sh restricted [primary]
  ./runme.sh discovery  [primary]

Commands:
  restricted  Run the container with the firewall enabled (agent runs as non-root, NET_ADMIN/NET_RAW dropped)
  discovery   Run the container with unrestricted egress and background capture (runs as sandbox user)

Positional [primary] — selects the working directory inside the container:
  @<repo>     A REGISTERED repo (see ./repo.sh) becomes the working dir at
              /workspace/<repo>. It is attached writable automatically; if you
              also list it in REPOS it must be :rw or :rwcopy (not :ro).
  <host-path> A host directory, bind-mounted at /workspace/<basename> (rw) and
              used as the working dir.
  (omitted)   The working dir is the /workspace umbrella itself.

Everything is mounted under the /workspace umbrella: REPOS at /workspace/<name>,
EXTRA_MOUNTS at /workspace/<basename>, the personal vault at /workspace/vault,
the specs repo at /workspace/specs, the docs repo at /workspace/docs (read-only by default).
Agent outputs (.agent-blocked/, .agent-discovery/) are written to the host
directory where runme.sh is launched (git- and docker-ignored).

Related scripts:
  ./build.sh  Build the image (reads sandbox.conf, regenerates allowlists)
  ./repo.sh   Manage shared repo volumes (add / sync / list / rm)

Environment variables:
  IMAGE_NAME          Image to run (default: ai-sandbox).
  AGENT_REBUILD_MAX_AGE_HOURS
                      If the image is at least this many hours old, runme.sh offers
                      to rebuild it so the bundled AI agents (Copilot/Claude/Codex/
                      Gemini/Kiro) are refreshed — they are installed unpinned at
                      build time and otherwise never update. Default 72 (3 days).
                      Set to 0 (or off/never) to disable the check. The rebuild is a
                      fast, targeted agent-layer refresh (heavy toolchains are reused).
  AGENT_REBUILD_ACK   On a non-TTY run, set to 1 to perform the stale-image rebuild
                      without prompting; otherwise a non-TTY run with a stale image
                      just warns and continues.
  AI_CONTAINER_GROUP  Group name selecting which dotfile tree to mount (default: default).
                      Use 'host' to mount directly from $HOME. Use any lowercase name
                      (a-z, 0-9, dashes; max 32 chars) to select ~/.ai-containers/<group>/.
  AI_CONTAINER_GROUP_INIT
                      Non-interactive override for first-time group bootstrap:
                        clean | from:host | from:<name>
  AI_CONTAINER_HOST_ACK
                      Set to 1 to skip the macOS host-group interactive acknowledgement.
  SANDBOX_UID / SANDBOX_GID / SANDBOX_USER / SANDBOX_GROUP
                      Override the container user identity (default: detected from host).
  REPOS               Space-separated list of REGISTERED repo volumes to attach under
                      /workspace/<name>, each at native in-VM speed. Append :ro (default),
                      :rw, or :rwcopy. Register repos first with ./repo.sh add.
                        :ro      Shared, read-only. Many containers mount the same single
                                 copy. GIT_OPTIONAL_LOCKS=0 is set so read-only git ops
                                 (log/blame/status) don't try to write to .git.
                        :rw      Shared base volume, mounted writable directly (no copy).
                                 Intended for a SINGLE writer at a time; two containers
                                 writing one repo concurrently can wedge git state.
                        :rwcopy  Isolated per-workspace writable working copy, seeded once
                                 by a fast local copy from the shared base (no re-clone),
                                 keyed by the launch directory. Use for concurrent writers
                                 to the same repo. Volume backend only.
                      Examples:
                        REPOS="cluster"                       # cluster, read-only
                        REPOS="cluster:ro lib-a:ro app:rw"    # read 2, write 1 (shared base)
  REPO_BACKEND        How a repo is backed; chosen when you run ./repo.sh add and
                      stored in the registry (changing it later has no effect on
                      already-added repos — re-add to change). auto (default) | volume | bind.
                        auto   — volume on macOS; on Linux, a direct host bind mount
                                 for 'path' repos (already native-speed there), volume
                                 for 'git' repos. One REPOS line works on both platforms.
                        volume — always a Docker named volume (identical behaviour
                                 everywhere; macOS-style :rwcopy isolated working copies).
                        bind   — bind-mount the host path for 'path' repos (falls back
                                 to volume for 'git' repos, which have no local path).
                      Note: with auto/bind, :rw on a bind-mounted repo writes LIVE to
                      the host source; with volume it writes to the shared in-VM base.
  EXTRA_MOUNTS        Space-separated list of extra HOST directories to bind-mount under
                      /workspace/<basename> (virtiofs; slower, but live-visible on the host
                      and needs no registration). Append :ro or :rw (default: rw).
                      A name appearing in both EXTRA_MOUNTS and REPOS is an error.
  VAULT_PATH          Host personal knowledge base (Obsidian vault or any markdown KB) mounted
                      at /workspace/vault (also re-exported as VAULT_PATH=/workspace/vault).
                      qmd=ON in sandbox.conf enables in-container search of mounted markdown corpora;
                      its index cache (~/.cache/qmd) is group-scoped, persisting across restarts.
  SPECS_PATH          Host specs/design/plans repo mounted at /workspace/specs (also re-exported
                      as SPECS_PATH=/workspace/specs). Accepts @<name> for a registered repo
                      volume (mounted at /workspace/<name> instead).
  DOCS_PATH           Host product-documentation repo mounted READ-ONLY at /workspace/docs (also
                      re-exported as DOCS_PATH=/workspace/docs). Accepts @<name> (→ /workspace/<name>)
                      and a :ro/:rw suffix (default :ro). When the docs repo is the working dir,
                      DOCS_PATH re-points to that writable mount. To edit docs, use :rw or mount
                      the repo as the working dir.
  SELF_HEALING_ENABLED  Set to 0 to disable self-healing allowlist (default: 1).
  GITHUB_PERSONAL_ACCESS_TOKEN
                        Forwarded into the container as-is for tools that expect this
                        exact variable name (github MCP servers, Claude Code github plugin).
  COPILOT_GITHUB_TOKEN  Forwarded for Copilot CLI auth. When unset, auto-extracted from
                        the group's gh hosts.yml so concurrent containers don't revoke
                        each other's Copilot sessions.
  PREVIEW_PORTS       Space-separated list of ports (or host:container pairs) to publish.
  CONTAINER_CPUS      CPU limit (default: 1.0).
  CONTAINER_MEMORY    Hard memory limit (default: 4g).
  CONTAINER_MEMORY_RESERVATION
                      Soft memory limit (default: 2g). Must be <= CONTAINER_MEMORY.
  CONTAINER_MEMORY_SWAP
                      Total memory + swap (default: 4g). Set equal to CONTAINER_MEMORY to
                      disable swap, or -1 for unlimited. Must be >= CONTAINER_MEMORY.
  CONTAINER_NOFILE    Open-file-descriptor limit, soft[:hard] (default: 1048576:1048576).
EOF
}

# ── Memory reconciliation ────────────────────────────────────────────────────────

# Parse a docker-style memory string (e.g. 512m, 2g, 1073741824, or -1) into bytes.
mem_to_bytes() {
  local v="${1,,}"
  if [[ "$v" == "-1" ]]; then printf '%s' "-1"; return 0; fi
  if [[ "$v" =~ ^([0-9]+)([bkmg]?)$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
      b|"") printf '%s' "$num" ;;
      k)    printf '%s' "$(( num * 1024 ))" ;;
      m)    printf '%s' "$(( num * 1024 * 1024 ))" ;;
      g)    printf '%s' "$(( num * 1024 * 1024 * 1024 ))" ;;
    esac
    return 0
  fi
  return 1
}

# Validate and reconcile CONTAINER_MEMORY / _RESERVATION / _SWAP before docker run.
validate_memory_limits() {
  mem_limit="${CONTAINER_MEMORY:-4g}"
  mem_reservation="${CONTAINER_MEMORY_RESERVATION:-2g}"
  mem_swap="${CONTAINER_MEMORY_SWAP:-4g}"

  local lim_b res_b swap_b
  if ! lim_b="$(mem_to_bytes "$mem_limit")"; then
    printf 'WARNING: CONTAINER_MEMORY="%s" is not a recognised memory value; skipping memory validation.\n' "$mem_limit" >&2
    return
  fi
  if ! res_b="$(mem_to_bytes "$mem_reservation")"; then
    printf 'WARNING: CONTAINER_MEMORY_RESERVATION="%s" is not a recognised memory value; skipping memory validation.\n' "$mem_reservation" >&2
    return
  fi
  if ! swap_b="$(mem_to_bytes "$mem_swap")"; then
    printf 'WARNING: CONTAINER_MEMORY_SWAP="%s" is not a recognised memory value; skipping memory validation.\n' "$mem_swap" >&2
    return
  fi

  if (( res_b > lim_b )); then
    printf 'WARNING: CONTAINER_MEMORY_RESERVATION (%s) exceeds CONTAINER_MEMORY (%s).\n' "$mem_reservation" "$mem_limit" >&2
    printf '         Lowering memory reservation to %s (the hard limit).\n' "$mem_limit" >&2
    mem_reservation="$mem_limit"
  fi

  if [[ "$swap_b" != "-1" ]] && (( swap_b < lim_b )); then
    printf 'WARNING: CONTAINER_MEMORY_SWAP (%s) is less than CONTAINER_MEMORY (%s); docker would reject this.\n' "$mem_swap" "$mem_limit" >&2
    printf '         Raising memory-swap to %s (disables swap; container is hard-capped at the memory limit).\n' "$mem_limit" >&2
    mem_swap="$mem_limit"
  fi
}

# ── Mount helpers ────────────────────────────────────────────────────────────────

add_mount_if_exists() {
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  if [[ -d "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  else
    printf 'WARNING: skipping mount — directory not found: %s\n' "$original_src" >&2
  fi
}

add_file_mount_if_exists() {
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  if [[ -f "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  fi
}

# Seed a per-workspace writable working-copy volume from a repo's shared base
# volume using a fast local copy inside the VM (no network, no re-clone). The
# working copy is labeled with its parent repo and originating launch dir so
# `repo.sh list --copies` / `repo.sh gc` can identify and prune it later.
seed_workcopy_volume() {
  local base_vol="$1" wc_vol="$2" repo_name="${3:-}" launch="${4:-}"
  if docker volume inspect "$wc_vol" >/dev/null 2>&1; then
    return 0
  fi
  printf 'Seeding writable working copy "%s" from "%s" (one-time local copy)...\n' "$wc_vol" "$base_vol" >&2
  local labels=(--label "ai-containers.workcopy=1")
  [[ -n "$repo_name" ]] && labels+=(--label "ai-containers.repo=${repo_name}")
  [[ -n "$launch" ]] && labels+=(--label "ai-containers.launch-dir=${launch}")
  docker volume create "${labels[@]}" "$wc_vol" >/dev/null
  # --entrypoint bash bypasses entrypoint.sh (which ignores args and would run the
  # firewall/restricted flow). cp -a preserves the ownership set on the base volume.
  docker run --rm --entrypoint bash \
    -v "$base_vol":/src:ro \
    -v "$wc_vol":/dst \
    "$image_name" -c 'cp -a /src/. /dst/'
}

# ── Image staleness / agent auto-refresh ─────────────────────────────────────────

# Echo the age of a docker image in whole hours, or return 1 if it can't be
# determined. Parses docker's RFC3339 .Created timestamp portably across GNU
# date (Linux) and BSD date (macOS).
image_age_hours() {
  local img="$1" created created_epoch now_epoch trunc
  created="$(docker image inspect --format '{{.Created}}' "$img" 2>/dev/null)" || return 1
  [[ -n "$created" ]] || return 1
  # Normalise nanoseconds + 'Z' (2026-06-12T08:30:00.123Z) → seconds + 'Z'
  # (2026-06-12T08:30:00Z), which BSD date can parse with an explicit format.
  trunc="${created%.*}"
  trunc="${trunc%Z}Z"
  if created_epoch="$(date -u -d "$created" +%s 2>/dev/null)"; then
    :   # GNU date understands the full RFC3339Nano string directly.
  elif created_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$trunc" +%s 2>/dev/null)"; then
    :   # BSD date (macOS) needs the truncated seconds form + explicit format.
  else
    return 1
  fi
  now_epoch="$(date -u +%s)"
  printf '%s' "$(( (now_epoch - created_epoch) / 3600 ))"
}

# If the image is older than AGENT_REBUILD_MAX_AGE_HOURS (default 72 = 3 days),
# offer to rebuild it so the bundled AI agents (which are installed unpinned at
# build time and otherwise never update) are refreshed. The rebuild is a
# TARGETED agent-layer refresh via AGENTS_CACHE_BUST — heavy toolchain layers
# are reused.
#
#   AGENT_REBUILD_MAX_AGE_HOURS threshold in hours (default 72; 0/off/never/no
#                               disables the check entirely)
#   AGENT_REBUILD_ACK=1         on a non-TTY (scripted/CI) run, proceed with the
#                               rebuild without prompting; otherwise a non-TTY
#                               run with a stale image just warns and continues.
maybe_rebuild_stale_image() {
  local max_age="${AGENT_REBUILD_MAX_AGE_HOURS:-72}"
  case "${max_age,,}" in
    0|off|never|no|false|disabled) return 0 ;;
  esac
  if ! [[ "$max_age" =~ ^[0-9]+$ ]]; then
    printf 'WARNING: AGENT_REBUILD_MAX_AGE_HOURS="%s" is not a non-negative integer; skipping staleness check.\n' "$max_age" >&2
    return 0
  fi

  if ! docker image inspect "$image_name" >/dev/null 2>&1; then
    # No image yet — nothing to refresh. The normal flow will surface the build
    # hint when `docker run` fails.
    printf 'NOTE: image "%s" not found — build it first with ./build.sh\n' "$image_name" >&2
    return 0
  fi

  local age
  if ! age="$(image_age_hours "$image_name")"; then
    printf 'WARNING: could not determine age of image "%s"; skipping staleness check.\n' "$image_name" >&2
    return 0
  fi
  (( age < max_age )) && return 0

  printf 'Image "%s" is %d hour(s) old (>= AGENT_REBUILD_MAX_AGE_HOURS=%d). Its bundled AI agents may be outdated.\n' \
    "$image_name" "$age" "$max_age" >&2

  local do_rebuild=0
  if [[ -t 0 ]]; then
    local reply
    read -r -p "Refresh the agents now (targeted rebuild, heavy layers reused)? [Y/n]: " reply </dev/tty
    case "${reply:-y}" in
      y|Y|yes|YES) do_rebuild=1 ;;
    esac
  elif [[ "${AGENT_REBUILD_ACK:-0}" == "1" ]]; then
    do_rebuild=1
  else
    printf 'Skipping rebuild (no TTY and AGENT_REBUILD_ACK != 1). Run ./build.sh to refresh, or set AGENT_REBUILD_MAX_AGE_HOURS=0 to silence.\n' >&2
    return 0
  fi

  if (( do_rebuild )); then
    printf 'Refreshing AI agents via targeted rebuild...\n' >&2
    AGENTS_CACHE_BUST="$(date -u +%s)" "${script_dir}/build.sh" "$image_name"
  else
    printf 'Continuing with the existing image. Run ./build.sh (or AGENTS_CACHE_BUST=$(date +%%s) ./build.sh) to refresh later.\n' >&2
  fi
}

run_container() {
  check_config
  maybe_rebuild_stale_image
  local mode="$1"
  local primary_arg="${2:-}"
  # Host directory where runme.sh was invoked. Agent outputs (.agent-blocked,
  # .agent-discovery) are written here so they persist host-visibly beside the
  # container files. These dirs are git- and docker-ignored.
  local launch_dir="$PWD"
  local capture_enabled="0"

  if [[ -n "${SSH_SCOPE_DIR:-}" ]]; then
    echo "Note: SSH_SCOPE_DIR is no longer used; .ssh is now part of the group at ~/.ai-containers/<group>/.ssh/. See CHANGELOG." >&2
  fi

  local capabilities=(--cap-add=NET_ADMIN --cap-add=NET_RAW)
  local sandbox_username="${SANDBOX_USER:-$(id -un)}"
  local dev_home="/home/$sandbox_username"

  # Agent outputs → host launch dir, surfaced under the /workspace umbrella.
  local output_mount_flags=()
  if [[ "$mode" == "discovery" ]]; then
    capture_enabled="1"
    mkdir -p "$launch_dir/.agent-discovery"
    output_mount_flags+=(-v "$launch_dir/.agent-discovery:/workspace/.agent-discovery")
  else
    mkdir -p "$launch_dir/.agent-blocked"
    output_mount_flags+=(-v "$launch_dir/.agent-blocked:/workspace/.agent-blocked")
  fi

  # Names already claimed under the /workspace umbrella (collision detection).
  local -A repos_used=()
  local -A repo_mode=()

  # ── Primary working directory (positional arg) ──────────────────────────────
  #   @name     → registered repo <name> becomes the working dir (must be writable)
  #   host path → mounted at /workspace/<basename> (rw) and used as the working dir
  #   (omitted) → the /workspace umbrella itself
  local workdir="/workspace"
  local primary_repo="" primary_path=""
  if [[ -n "$primary_arg" ]]; then
    if [[ "${primary_arg:0:1}" == "@" ]]; then
      primary_repo="${primary_arg#@}"
      validate_repo_name "$primary_repo" || exit 1
      if ! repo_is_registered "$primary_repo"; then
        printf "ERROR: primary repo '%s' (selected with @) is not registered.\n" "$primary_repo" >&2
        printf "       Add it first:   ./repo.sh add %s <host-path-or-git-url>\n" "$primary_repo" >&2
        printf "       See registered: ./repo.sh list\n" >&2
        exit 1
      fi
      workdir="/workspace/$primary_repo"
    else
      primary_path="$(resolve_path "${primary_arg/#\~/$HOME}")"
      if [[ ! -d "$primary_path" ]]; then
        printf 'ERROR: primary workspace directory does not exist: %s\n' "$primary_arg" >&2
        exit 1
      fi
      workdir="/workspace/$(basename "$primary_path")"
    fi
  fi

  # ── EXTRA_MOUNTS: ad-hoc host bind mounts at /workspace/<basename> ───────────
  local extra_mount_flags=()
  if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
    for entry in $EXTRA_MOUNTS; do
      local dir opt real_dir base
      dir="${entry%%:*}"
      opt="${entry##*:}"
      [[ "$opt" == "$dir" ]] && opt="rw"
      real_dir="$(resolve_path "${dir/#\~/$HOME}")"
      if [[ ! -d "$real_dir" ]]; then
        printf 'ERROR: EXTRA_MOUNTS path does not exist: %s\n' "$dir" >&2
        exit 1
      fi
      base="$(basename "$dir")"
      if [[ -n "${repos_used[$base]:-}" ]]; then
        printf "ERROR: name '%s' (EXTRA_MOUNTS) collides with %s at /workspace/%s.\n" "$base" "${repos_used[$base]}" "$base" >&2
        exit 1
      fi
      repos_used["$base"]="EXTRA_MOUNTS"
      extra_mount_flags+=(-v "$real_dir:/workspace/$base:$opt")
    done
  fi

  # Primary given as a host path → bind-mount it (rw) as a /workspace sibling.
  if [[ -n "$primary_path" ]]; then
    local pbase; pbase="$(basename "$primary_path")"
    if [[ -n "${repos_used[$pbase]:-}" ]]; then
      printf "ERROR: primary path basename '%s' collides with %s at /workspace/%s.\n" "$pbase" "${repos_used[$pbase]}" "$pbase" >&2
      exit 1
    fi
    repos_used["$pbase"]="primary"
    extra_mount_flags+=(-v "$primary_path:/workspace/$pbase:rw")
  fi

  # ── REPOS: attach registered repo volumes at /workspace/<name> ───────────────
  local repo_mount_flags=()
  local git_optional_locks_env=()
  # Effective list = REPOS, plus the @primary repo (as :rw) if not already listed.
  local repos_list=(${REPOS:-})
  if [[ -n "$primary_repo" ]]; then
    local _found=0 _e
    for _e in ${repos_list[@]+"${repos_list[@]}"}; do
      [[ "${_e%%:*}" == "$primary_repo" ]] && _found=1
    done
    (( _found )) || repos_list+=("$primary_repo:rw")
  fi

  # ── Host-pointer @name desugar ───────────────────────────────────────────────
  # DOCS_PATH/SPECS_PATH may name a registered repo volume (@name); treat it like a
  # REPOS entry so the loop below mounts it at /workspace/<name> (reusing an existing
  # entry instead of double-mounting). Host-path forms are handled after the loop.
  local docs_kind="" docs_src="" docs_mode=""
  local specs_kind="" specs_src="" specs_mode=""
  local PTR_KIND PTR_SRC PTR_MODE _entry
  if [[ -n "${DOCS_PATH:-}" ]]; then
    parse_pointer_spec "$DOCS_PATH" ro 1
    docs_kind="$PTR_KIND"; docs_src="$PTR_SRC"; docs_mode="$PTR_MODE"
    if [[ "$docs_kind" == "volume" ]]; then
      _entry="$(pointer_repo_entry "$docs_src" "$docs_mode" ${repos_list[@]+"${repos_list[@]}"})"
      [[ -n "$_entry" ]] && repos_list+=("$_entry")
    fi
  fi
  if [[ -n "${SPECS_PATH:-}" ]]; then
    parse_pointer_spec "$SPECS_PATH" rw 0
    specs_kind="$PTR_KIND"; specs_src="$PTR_SRC"; specs_mode="$PTR_MODE"
    if [[ "$specs_kind" == "volume" ]]; then
      _entry="$(pointer_repo_entry "$specs_src" "$specs_mode" ${repos_list[@]+"${repos_list[@]}"})"
      [[ -n "$_entry" ]] && repos_list+=("$_entry")
    fi
  fi
  if [[ ${#repos_list[@]} -gt 0 ]]; then
    local ws_tag; ws_tag="$(sanitize_volume_token "$(basename "$launch_dir")")_$(printf '%s' "$launch_dir" | cksum | tr -cd '0-9' | cut -c1-8)"
    for entry in "${repos_list[@]}"; do
      local rname rmode
      rname="${entry%%:*}"
      rmode="${entry##*:}"
      [[ "$rmode" == "$rname" ]] && rmode="ro"

      if ! validate_repo_name "$rname"; then
        exit 1
      fi
      if [[ "$rmode" != "ro" && "$rmode" != "rw" && "$rmode" != "rwcopy" ]]; then
        printf "ERROR: REPOS entry '%s' has invalid mode '%s' (expected :ro, :rw, or :rwcopy).\n" "$entry" "$rmode" >&2
        exit 1
      fi
      if [[ -n "${repos_used[$rname]:-}" ]]; then
        printf "ERROR: name '%s' is used by both %s and REPOS — they both mount at /workspace/%s.\n" \
          "$rname" "${repos_used[$rname]}" "$rname" >&2
        exit 1
      fi
      if ! repo_is_registered "$rname"; then
        printf "ERROR: REPOS entry '%s' is not a registered repo.\n" "$rname" >&2
        printf "       Add it first:   ./repo.sh add %s <host-path-or-git-url>\n" "$rname" >&2
        printf "       See registered: ./repo.sh list\n" >&2
        exit 1
      fi

      repos_used["$rname"]="REPOS"
      repo_mode["$rname"]="$rmode"
      local rrecord rtype rsource rbackend
      rrecord="$(repo_registry_lookup "$rname")"
      rtype="$(repo_record_field "$rrecord" 2)"
      rsource="$(repo_record_field "$rrecord" 3)"
      rbackend="$(repo_record_backend "$rrecord")"

      if [[ "$rbackend" == "bind" ]]; then
        # Linux + path source: bind-mount the registered host path directly
        # (native speed here, no volume). :rw is a live host dir.
        if [[ "$rmode" == "rwcopy" ]]; then
          printf "ERROR: repo '%s': :rwcopy needs a volume backend, but this host bind-mounts it.\n" "$rname" >&2
          printf "       Use :rw for a live bind mount, or set REPO_BACKEND=volume for an isolated copy.\n" >&2
          exit 1
        fi
        local rreal; rreal="$(resolve_path "$rsource")"
        if [[ ! -d "$rreal" ]]; then
          printf "ERROR: repo '%s' bind source does not exist on this host: %s\n" "$rname" "$rsource" >&2
          printf "       Re-point it: ./repo.sh rm %s && ./repo.sh add %s <host-path>\n" "$rname" "$rname" >&2
          exit 1
        fi
        repo_mount_flags+=(-v "$rreal:/workspace/$rname:$rmode")
        printf 'REPO: /workspace/%s  (%s, bind %s)\n' "$rname" "$rmode" "$rreal" >&2
      else
        if ! repo_volume_exists "$rname"; then
          printf "ERROR: repo '%s' is registered but its docker volume (%s) is missing.\n" \
            "$rname" "$(repo_volume_name "$rname")" >&2
          printf "       Re-seed it: ./repo.sh sync %s   (or ./repo.sh rm %s && ./repo.sh add ...)\n" "$rname" "$rname" >&2
          exit 1
        fi
        local base_vol; base_vol="$(repo_volume_name "$rname")"
        case "$rmode" in
          ro)
            # Shared, read-only: many containers mount the same single copy.
            repo_mount_flags+=(-v "$base_vol:/workspace/$rname:ro")
            printf 'REPO: /workspace/%s  (ro, shared volume %s)\n' "$rname" "$base_vol" >&2
            ;;
          rw)
            # Shared base, writable directly — no copy. Intended for a single
            # writer; concurrent :rw writers to one repo can wedge git state
            # (use :rwcopy for isolated concurrent writers).
            repo_mount_flags+=(-v "$base_vol:/workspace/$rname")
            printf 'REPO: /workspace/%s  (rw, shared base volume %s)\n' "$rname" "$base_vol" >&2
            ;;
          rwcopy)
            # Isolated, per-workspace writable working copy seeded from the base.
            local wc_vol; wc_vol="$(repo_workcopy_volume_name "$rname" "$ws_tag")"
            seed_workcopy_volume "$base_vol" "$wc_vol" "$rname" "$launch_dir"
            repo_mount_flags+=(-v "$wc_vol:/workspace/$rname")
            printf 'REPO: /workspace/%s  (rwcopy, working copy %s)\n' "$rname" "$wc_vol" >&2
            ;;
        esac
      fi
    done
    # Read-only repo mounts can break git operations that want to write .git;
    # disabling optional locks keeps log/blame/status working read-only.
    git_optional_locks_env=(-e GIT_OPTIONAL_LOCKS=0)
  fi

  # The working directory must be writable when a primary repo is selected.
  if [[ -n "$primary_repo" ]]; then
    case "${repo_mode[$primary_repo]:-}" in
      rw|rwcopy) : ;;
      ro)
        printf "ERROR: primary repo '%s' is attached :ro, but the working directory must be writable.\n" "$primary_repo" >&2
        printf "       Use REPOS=\"%s:rw\" (or :rwcopy), or drop it from REPOS to attach it writable automatically.\n" "$primary_repo" >&2
        exit 1
        ;;
    esac
  fi

  # Corpus names collected for one consolidated qmd nudge (see below).
  local qmd_corpora=()

  # ── Personal vault → /workspace/vault ────────────────────────────────────────
  local vault_mount_flags=()
  local vault_env_args=()
  if [[ -n "${VAULT_PATH:-}" ]]; then
    local vault_real
    vault_real="$(resolve_path "${VAULT_PATH/#\~/$HOME}")"
    if [[ -d "$vault_real" ]]; then
      if [[ -n "${repos_used[vault]:-}" ]]; then
        printf "ERROR: name 'vault' is used by %s, but VAULT_PATH also mounts at /workspace/vault.\n" "${repos_used[vault]}" >&2
        exit 1
      fi
      vault_mount_flags+=(-v "$vault_real:/workspace/vault:rw")
      vault_env_args+=(-e VAULT_PATH=/workspace/vault)
      qmd_corpora+=("VAULT_PATH")
    else
      printf 'WARNING: VAULT_PATH is set but directory does not exist: %s\n' "$VAULT_PATH" >&2
    fi
  fi

  # ── Specs repo → /workspace/specs (host path) or /workspace/<name> (@name) ────
  local specs_mount_flags=()
  local specs_env_args=()
  if [[ -n "${SPECS_PATH:-}" ]]; then
    if [[ "$specs_kind" == "volume" ]]; then
      # Mounted by the repo loop at /workspace/<name>; just re-export the pointer.
      specs_env_args+=(-e "SPECS_PATH=/workspace/$specs_src")
      qmd_corpora+=("SPECS_PATH")
    else
      local specs_real
      specs_real="$(resolve_path "${specs_src/#\~/$HOME}")"
      if [[ -d "$specs_real" ]]; then
        if [[ -n "${repos_used[specs]:-}" ]]; then
          printf "ERROR: name 'specs' is used by %s, but SPECS_PATH also mounts at /workspace/specs.\n" "${repos_used[specs]}" >&2
          exit 1
        fi
        specs_mount_flags+=(-v "$specs_real:/workspace/specs:rw")
        specs_env_args+=(-e SPECS_PATH=/workspace/specs)
        qmd_corpora+=("SPECS_PATH")
      else
        printf 'WARNING: SPECS_PATH is set but directory does not exist: %s\n' "$specs_src" >&2
      fi
    fi
  fi

  # ── Docs repo → /workspace/docs (grounding), /workspace/<name> (@name), or the
  #    working-dir mount when the docs repo IS the working dir ───────────────────
  local docs_mount_flags=()
  local docs_env_args=()
  if [[ -n "${DOCS_PATH:-}" ]]; then
    if [[ "$docs_kind" == "volume" ]]; then
      docs_env_args+=(-e "DOCS_PATH=/workspace/$docs_src")
      qmd_corpora+=("DOCS_PATH")
    else
      local docs_real
      docs_real="$(resolve_path "${docs_src/#\~/$HOME}")"
      if [[ -n "$primary_path" && "$docs_real" == "$primary_path" ]]; then
        # Docs repo IS the working dir: already mounted rw by the primary at
        # $workdir. Re-point DOCS_PATH there; any :ro/:rw suffix is moot.
        docs_env_args+=(-e "DOCS_PATH=$workdir")
        qmd_corpora+=("DOCS_PATH")
      elif [[ -d "$docs_real" ]]; then
        if [[ -n "${repos_used[docs]:-}" ]]; then
          printf "ERROR: name 'docs' is used by %s, but DOCS_PATH also mounts at /workspace/docs.\n" "${repos_used[docs]}" >&2
          exit 1
        fi
        docs_mount_flags+=(-v "$docs_real:/workspace/docs:$docs_mode")
        docs_env_args+=(-e DOCS_PATH=/workspace/docs)
        qmd_corpora+=("DOCS_PATH")
      else
        printf 'WARNING: DOCS_PATH is set but directory does not exist: %s\n' "$docs_src" >&2
      fi
    fi
  fi

  # ── Consolidated qmd search nudge ────────────────────────────────────────────
  # qmd is a single global sandbox.conf toggle, not a per-mount capability, so
  # warn once if any markdown corpus is mounted but in-container search was not
  # baked into the image.
  if [[ ${#qmd_corpora[@]} -gt 0 ]] && ! is_enabled qmd; then
    local qmd_joined
    printf -v qmd_joined '%s, ' "${qmd_corpora[@]}"
    qmd_joined="${qmd_joined%, }"
    printf 'WARNING: qmd=OFF in sandbox.conf, but markdown corpora are mounted (%s). Set qmd=ON and rebuild for in-container search.\n' \
      "$qmd_joined" >&2
  fi

  # ── Group resolution ─────────────────────────────────────────────────────────
  local group="${AI_CONTAINER_GROUP:-default}"
  validate_group_name "$group"

  local group_root
  if [[ "$group" == "host" ]]; then
    [[ "$(uname -s)" == "Darwin" ]] && require_host_ack
    group_root="$HOME"
  else
    mkdir -p "$HOME/.ai-containers"
    group_root="$HOME/.ai-containers/$group"
    ensure_group_exists "$group" "$group_root"
    ensure_group_scaffold "$group_root"
  fi

  # ── Credential mounts (enabled components only) ──────────────────────────────
  # Stage git config files into the group directory before mounting. Docker Desktop
  # on macOS (VirtioFS) bind-mounts a specific inode; if git/editors atomically
  # replace the file after the container starts the old inode gets link count 0 and
  # reads fail. Mounting from the group dir (which nothing replaces while running)
  # avoids this. The copy is refreshed on every container start.
  local gitconfig_src="$HOME/.gitconfig"
  local gitignore_src="$HOME/.gitignore_global"
  if [[ "$group" != "host" ]]; then
    [[ -f "$HOME/.gitconfig"        ]] && cp "$HOME/.gitconfig"        "$group_root/.gitconfig"        2>/dev/null || true
    [[ -f "$HOME/.gitignore_global" ]] && cp "$HOME/.gitignore_global" "$group_root/.gitignore_global" 2>/dev/null || true
    gitconfig_src="$group_root/.gitconfig"
    gitignore_src="$group_root/.gitignore_global"
  fi
  local config_mount_flags=()
  add_mount_if_exists      config_mount_flags "$group_root/.ssh"         "$dev_home/.ssh"
  add_mount_if_exists      config_mount_flags "$group_root/.agents"      "$dev_home/.agents"
  add_file_mount_if_exists config_mount_flags "$gitconfig_src"           "$dev_home/.gitconfig" ro
  add_file_mount_if_exists config_mount_flags "$gitignore_src"           "$dev_home/.gitignore_global" ro

  if any_enabled github-cli copilot; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.config/gh"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.config/gh" "$dev_home/.config/gh"
  fi
  if is_enabled copilot; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.copilot"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.copilot" "$dev_home/.copilot"
  fi
  if is_enabled kiro; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.kiro" "$group_root/.local/share/kiro-cli"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.kiro"                  "$dev_home/.kiro"
    add_mount_if_exists config_mount_flags "$group_root/.local/share/kiro-cli"  "$dev_home/.local/share/kiro-cli"
  fi
  if is_enabled claude-code; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.claude"
      [[ -e "$group_root/.claude.json" ]] || printf '{}\n' > "$group_root/.claude.json"
    fi
    add_mount_if_exists      config_mount_flags "$group_root/.claude"      "$dev_home/.claude"
    add_file_mount_if_exists config_mount_flags "$group_root/.claude.json" "$dev_home/.claude.json"
  fi
  if is_enabled codex; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.codex"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.codex" "$dev_home/.codex"
  fi
  if is_enabled gemini; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.gemini"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.gemini" "$dev_home/.gemini"
  fi
  if is_enabled yarn; then
    add_mount_if_exists config_mount_flags "$HOME/.yarn" "$dev_home/.yarn"
  fi
  if is_enabled aws-cli; then
    add_mount_if_exists config_mount_flags "$HOME/.aws" "$dev_home/.aws"
  fi
  if is_enabled azure-cli; then
    add_mount_if_exists config_mount_flags "$HOME/.azure" "$dev_home/.azure"
  fi
  if is_enabled kubectl; then
    add_mount_if_exists config_mount_flags "$HOME/.kube" "$dev_home/.kube"
  fi
  # Tool config dirs (dtctl/dtmgd/junoctl/...) are group-scoped like agent
  # credentials: created lazily in the group and seeded ONCE from the host home
  # if present, so a sandboxed agent never writes the developer's real host
  # config. The seed happens only when the group dir does not yet exist.
  local _tname
  while IFS= read -r _tname; do
    is_active "$_tname" || continue
    tools_read_descriptor "$_tname" || continue
    [[ -n "$TOOL_config_dir" ]] || continue
    if [[ "$group" != "host" ]]; then
      if [[ ! -e "$group_root/$TOOL_config_dir" && -e "$HOME/$TOOL_config_dir" ]]; then
        install -d "$(dirname "$group_root/$TOOL_config_dir")"
        cp -a "$HOME/$TOOL_config_dir" "$group_root/$TOOL_config_dir"
      else
        install -d "$group_root/$TOOL_config_dir"
      fi
      add_mount_if_exists config_mount_flags "$group_root/$TOOL_config_dir" "$dev_home/$TOOL_config_dir"
    else
      add_mount_if_exists config_mount_flags "$HOME/$TOOL_config_dir" "$dev_home/$TOOL_config_dir"
    fi
  done < <(tools_list_names)
  if is_enabled qmd; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.cache/qmd"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.cache/qmd" "$dev_home/.cache/qmd"
  fi

  # Resolve COPILOT_GITHUB_TOKEN from the group's gh hosts.yml if not set.
  local copilot_token="${COPILOT_GITHUB_TOKEN:-}"
  if is_enabled copilot && [[ -z "$copilot_token" ]]; then
    local gh_hosts="$group_root/.config/gh/hosts.yml"
    if [[ -f "$gh_hosts" ]]; then
      copilot_token="$(awk '/oauth_token:/{print $2; exit}' "$gh_hosts")"
    fi
    if [[ -z "$copilot_token" ]]; then
      printf 'HINT: No gh auth token found for group "%s".\n' "$group" >&2
      printf '      Run "gh auth login" inside the container to authenticate Copilot CLI.\n' >&2
    fi
  fi

  # Build -p flags from PREVIEW_PORTS.
  local port_flags=()
  if [[ -n "${PREVIEW_PORTS:-}" ]]; then
    for p in $PREVIEW_PORTS; do
      port_flags+=(-p "$p")
    done
  fi

  local mem_limit mem_reservation mem_swap
  validate_memory_limits

  if [[ -z "${CONTAINER_CPUS:-}" && -z "${CONTAINER_MEMORY:-}" ]]; then
    printf 'HINT: running at default limits (%s CPU / %s RAM) — the minimum for a single agent doing light work.\n' "${CONTAINER_CPUS:-1.0}" "$mem_limit" >&2
    printf '      For an agent plus a real build toolchain, CONTAINER_CPUS=4 CONTAINER_MEMORY=8g CONTAINER_MEMORY_SWAP=8g is more comfortable.\n' >&2
  fi

  docker run -it --rm \
    "${capabilities[@]}" \
    --add-host=host.docker.internal:host-gateway \
    ${port_flags[@]+"${port_flags[@]}"} \
    --cpus="${CONTAINER_CPUS:-1.0}" \
    --memory="$mem_limit" \
    --memory-reservation="$mem_reservation" \
    --memory-swap="$mem_swap" \
    --ulimit nofile="${CONTAINER_NOFILE:-1048576:1048576}" \
    -e DEV_CONTAINER_MODE="$mode" \
    -e DISCOVERY_CAPTURE_ENABLED="$capture_enabled" \
    -e DISCOVERY_CAPTURE_DIR="/workspace/.agent-discovery" \
    -e BLOCKED_CAPTURE_DIR="/workspace/.agent-blocked" \
    -e HOST_WORKSPACE_DIR="$launch_dir" \
    -e IMAGE_NAME="$image_name" \
    -e SANDBOX_UID="${SANDBOX_UID:-$(id -u)}" \
    -e SANDBOX_GID="${SANDBOX_GID:-$(id -g)}" \
    -e SANDBOX_USER="${SANDBOX_USER:-$(id -un)}" \
    -e SANDBOX_GROUP="${SANDBOX_GROUP:-$(id -gn)}" \
    -e AI_AGENTS_ENABLED="$(enabled_agents_csv)" \
    ${git_optional_locks_env[@]+"${git_optional_locks_env[@]}"} \
    ${SELF_HEALING_ENABLED:+-e SELF_HEALING_ENABLED="$SELF_HEALING_ENABLED"} \
    ${ALLOW_IPV6_BYPASS:+-e ALLOW_IPV6_BYPASS="$ALLOW_IPV6_BYPASS"} \
    ${GITHUB_PERSONAL_ACCESS_TOKEN:+-e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"} \
    ${copilot_token:+-e COPILOT_GITHUB_TOKEN="$copilot_token"} \
    ${vault_env_args[@]+"${vault_env_args[@]}"} \
    ${specs_env_args[@]+"${specs_env_args[@]}"} \
    ${docs_env_args[@]+"${docs_env_args[@]}"} \
    ${output_mount_flags[@]+"${output_mount_flags[@]}"} \
    ${repo_mount_flags[@]+"${repo_mount_flags[@]}"} \
    ${extra_mount_flags[@]+"${extra_mount_flags[@]}"} \
    ${vault_mount_flags[@]+"${vault_mount_flags[@]}"} \
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
    ${docs_mount_flags[@]+"${docs_mount_flags[@]}"} \
    ${config_mount_flags[@]+"${config_mount_flags[@]}"} \
    -w "$workdir" \
    "$image_name"
}

# ── Entry point ──────────────────────────────────────────────────────────────────

command="${1:-usage}"

case "$command" in
  restricted|discovery)
    run_container "$command" "${2:-}"
    ;;
  build)
    printf 'ERROR: "runme.sh build" has been removed. Use ./build.sh instead.\n' >&2
    exit 1
    ;;
  -h|--help|help|usage)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
