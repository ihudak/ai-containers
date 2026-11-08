#!/usr/bin/env bash
set -euo pipefail
# A relative `cd` would search the host shell's CDPATH first, which moved a
# relative core.worktree somewhere else (GIT-17; G73).
unset CDPATH
# A bounded read that was cut off signals this process from a subshell (_rd_fail),
# and says why on the stderr saved here: every caller sends its own to /dev/null.
exec {_rd_errfd}>&2
trap 'exit 1' USR1

# sandbox.sh — run the AI sandbox container.
#
# Build the image with ./build.sh and manage repo volumes with ./repo.sh.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/sandbox-common.sh
source "${_here}/sandbox-common.sh"
# shellcheck source=host-preflight.sh
source "${_here}/host-preflight.sh"
# shellcheck source=version.sh
# Sourced HERE and not from sandbox-common.sh: several test fixtures copy a
# hand-picked set of engine files into an isolated tree, and a new hard
# dependency in sandbox-common.sh breaks every one of them. Only the entry
# points that call version_report() need it — the same reason six entry points
# source bash-floor.sh directly.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version.sh"

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
# _repo_volume_foreign <repo> <volume>: refuse the launch (exit 1) when <volume>
# exists and its ai-containers.repo label names a repo other than <repo>; the
# message names the prefix the volume belongs to where its name shows it.
_repo_volume_foreign() {
  local owner; owner="$(docker_volume_label "$2" ai-containers.repo)"
  [[ -z "$owner" || "$owner" == "$1" ]] && return 0
  printf "ERROR: repo '%s': volume %s is labelled for repo '%s'; refusing to attach it.\n" "$1" "$2" "$owner" >&2
  local base="${2%--wc-*}"
  if [[ "$base" == *"-repo-$owner" ]]; then
    printf "       It is repo '%s' of REPO_VOLUME_PREFIX=%s, whose name collides with '%s' here.\n" "$owner" "${base%-repo-"$owner"}" "$1" >&2
  fi
  printf "       Attach '%s' under its own prefix; to use the name '%s' here, register it again under another name.\n" "$owner" "$1" >&2
  exit 1
}

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
  ./sandbox.sh restricted [primary]
  ./sandbox.sh discovery  [primary]
  ./sandbox.sh open       [primary]
  ./sandbox.sh --version

Commands:
  restricted  Run the container with the firewall enabled (agent runs as non-root, NET_ADMIN/NET_RAW dropped)
  discovery   Run the container with unrestricted egress and background capture (runs as sandbox user)
  open        Run with UNRESTRICTED egress and NO capture (no firewall, no logging)

Positional [primary] — selects the working directory inside the container:
  @<repo>     A REGISTERED repo (see ./repo.sh) becomes the working dir at
              /workspace/<repo>. It is attached writable automatically; if you
              also list it in REPOS it must be :rw or :rwcopy (not :ro).
  <host-path> A host directory, bind-mounted at /workspace/<basename> (rw) and
              used as the working dir.
  (omitted)   The working dir is the /workspace umbrella itself.

With no arguments, mode and working dir default to SANDBOX_MODE / SANDBOX_WORKDIR
(from sandbox.env / sandbox.local.env); a positional arg or inline env var wins.

Everything is mounted under the /workspace umbrella: REPOS at /workspace/<name>,
EXTRA_MOUNTS at /workspace/<basename>, the personal vault at /workspace/vault,
the specs repo at /workspace/specs, the docs repo at /workspace/docs (read-only by default).
Agent outputs (.agent-blocked/, .agent-discovery/) are written to the host
directory where sandbox.sh is launched (git- and docker-ignored).

Related scripts:
  ./build.sh  Build the image (reads sandbox.conf, regenerates allowlists)
  ./repo.sh   Manage shared repo volumes (add / sync / list / rm)

Environment variables:
  IMAGE_NAME          Image to run (default: ai-sandbox).
  AI_CONTAINER_GROUP  Group name selecting which dotfile tree to mount (default: default):
                      a lowercase name (a-z, 0-9, dashes; max 32 chars) selecting
                      ~/.ai-containers/<group>/. 'host' is refused.
  AI_CONTAINER_GROUP_INIT
                      Non-interactive override for first-time group bootstrap:
                        clean | from:host (a copy of your $HOME's) | from:<name>
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
                      and a :ro/:rw suffix (default :ro). If that same directory is ALREADY
                      mounted — as the working dir, or as a repo in REPOS — DOCS_PATH re-points
                      at that mount instead of mounting it again, and inherits its mode. So a
                      DOCS_PATH exported once on the host does not collide with the project that
                      happens to BE the docs repo. To edit docs otherwise, use :rw.
  ARCHITECTURE_REPO_PATH
                      Host architecture repo (standards, radar, ADRs) mounted READ-ONLY at
                      /workspace/architecture (also re-exported as
                      ARCHITECTURE_REPO_PATH=/workspace/architecture). Same grammar and
                      re-point rules as DOCS_PATH: @<name> (→ /workspace/<name>), a :ro/:rw
                      suffix (default :ro), and the existing mount when that directory is
                      already the working dir or a repo in REPOS.
  SANDBOX_ENV_FILE    Path to a KEY=VALUE env-file injected into the container
                      (default: <script_dir>/container.env if present). For
                      in-container app env (DB_HOST, REDIS_URL, ...). Not for secrets.
  SELF_HEALING_ENABLED  Set to 0 to disable self-healing allowlist (default: 1).
  GITHUB_PERSONAL_ACCESS_TOKEN
                        Forwarded into the container as-is for tools that expect this
                        exact variable name (github MCP servers, Claude Code github plugin).
  COPILOT_GITHUB_TOKEN  Forwarded for Copilot CLI auth. When unset, auto-extracted from
                        the group's gh hosts.yml so concurrent containers don't revoke
                        each other's Copilot sessions.
  SKILL_CHAR_BUDGET     Characters Copilot CLI may spend listing skills to the model;
                        a skill past the budget is listed by name only, without its
                        description (default: 25000; Copilot's own default is 15000).
  SLASH_COMMAND_TOOL_CHAR_BUDGET
                        Characters Claude Code may spend listing skills to the model;
                        over it, every skill's description is shortened (default:
                        40000; Claude Code's own is 8000 at a 200K context window).
                        Overrides skillListingBudgetFraction in your Claude Code
                        settings, so to change the budget in a container, set this.
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

# A group's own directories are meant to keep the agent away from your real
# config; one that is a link out of the group (left by an older copy, or made by
# hand) mounts what it points at instead. Named on every launch, not refused:
# a link made on purpose — a group sharing your real ~/.ssh — is yours to keep.
# run_container sets _group_guard_root.
_group_guard_root=""
_warn_group_link_out() {
  local original_src="$1" src="$2" groot
  [[ -n "$_group_guard_root" && "$original_src" == "$_group_guard_root"/* ]] || return 0
  groot="$(resolve_path "$_group_guard_root")"
  [[ "$src" == "$groot" || "$src" == "$groot"/* ]] && return 0
  printf 'WARNING: %s is a link out of the group, to %s;\n' "$original_src" "$src" >&2
  printf '         the container gets that directory, writable, not a copy of it. To keep a copy:\n' >&2
  printf '           rm %s && cp -a %s %s\n' "$(_q "$original_src")" "$(_q "$src/.")" "$(_q "$original_src/")" >&2
}

add_mount_if_exists() {
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  _warn_group_link_out "$original_src" "$src"
  if [[ -d "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  else
    printf 'WARNING: skipping mount — directory not found: %s\n' "$original_src" >&2
  fi
}

add_file_mount_if_exists() {
  # shellcheck disable=SC2178,SC2128  # nameref: shellcheck does not model `local -n`
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  [[ -f "$src" ]] && _warn_group_link_out "$original_src" "$src"
  if [[ -f "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  fi
}

# Launcher directories must not be writable from inside the container.
# A project's .ai-containers/ holds what the HOST runs or reads at the next
# launch — sandbox.sh, build.sh, the Dockerfile and entrypoint it builds,
# sandbox.env (SANDBOX_MODE, EXTRA_MOUNTS), sandbox.conf, container.env — and the
# documented launch mounts the whole project read-write (SANDBOX_WORKDIR=..).
# Left writable, the agent could rewrite any of them, and .ai-containers/ is
# gitignored, so `git status` would never show it. Docker mounts a nested bind
# on top of its parent (it orders mounts by destination depth), so each launcher
# is mounted again, read-only, inside every writable host bind that exposes it,
# and the rest of the mount stays writable.
#
# Which directories: this launcher's own, wherever it lives, and every other
# launcher a writable mount exposes (launcher_dirs_in) — a project attached as a
# :rw repo, a parent directory in EXTRA_MOUNTS, or an ai-containers checkout
# sitting in one. A launcher is matched by CONTENT (a directory holding both
# sandbox.sh and sandbox-common.sh), not by the name .ai-containers: the engine
# checkout itself is named ai-containers and is just as dangerous writable. A
# directory you cannot list, but the agent could still reach into (it owns it,
# so it can chmod it back; or its mode lets the agent search it), cannot be
# looked inside, so it is treated as if it held one; a writable mount ROOT you
# cannot list can be neither looked inside nor overlaid, so it refuses the
# launch.
#
# The directories BETWEEN the mount root and a launcher are pinned too, each
# bind-mounted onto itself read-write: an ordinary directory above a mount point
# can be renamed, and with it the read-only overlay moves out of the way of the
# path the host reads. A mount point cannot be renamed (EBUSY), and a self-bind
# changes nothing else about the directory. With the documented layout there is
# nothing between: the project is the mount root and .ai-containers its child.
# A SYMLINK on the path the host takes cannot be pinned that way, so one inside
# a writable mount is warned about instead. So is a symlink INSIDE a launcher
# (this one included, mounted or not) whose way out leads into a writable mount
# — to a file there, or through a link there the agent could repoint: the link
# is read-only with the launcher, but what the host reads is at the other end.
# A warning, not an overlay: turning link targets into mounts made mounts of
# the wrong paths, file binds that break `git checkout` in a checkout whose
# CLAUDE.md links to AGENTS.md, and scans with no bound. A link that stays
# inside its own launcher is not reported.
#
# launcher_ro_overlay <ro-flags-out> <verify-pairs-out> <this launcher's dir, as reached> <docker flag>...
# Reads the `-v <src>:<dst>[:<opts>]` pairs among the flags. Only a writable bind
# of a directory can expose a launcher: a named volume's source is a name and
# holds a copy, a file mount holds no directory, and a :ro bind is read-only
# already. Sources are canonicalised physically (`pwd -P`) and compared by path
# component, so /x/pro does not contain /x/proj. A mount that IS a launcher —
# one rooted at the engine itself (a checkout whose root holds the engine, as
# the working dir, or an engine directory nested in a checkout, such as
# mgd-ai-containers' base/, mounted on its own), or one rooted at a project's
# .ai-containers — cannot be made read-only without making that work impossible,
# so it is named with a NOTE instead. An engine reached INSIDE a larger writable
# mount is a launcher like any other and is overlaid. Launchers are handled
# shallowest-first: once a directory is overlaid read-only, everything inside
# it already is, so a launcher nested in another is skipped rather than pinned —
# a :rw pin there would punch a writable hole in the read-only parent.
#
# Robustness is part of the guarantee, because sandbox.sh runs under
# `set -euo pipefail` and an agent can name directories: everything here stays
# in arrays in this shell — no pipeline whose failure could end the loop early
# and leave later mounts unprotected, no newline- or tab-separated text a name
# could split — and every path is handed to docker in a form that carries it
# intact (_bind_mount_arg), or, where none can, not mounted, with a WARNING.
launcher_ro_overlay() {
  # shellcheck disable=SC2178  # nameref: shellcheck does not model `local -n`
  local -n _ro=$1 _vrfy=$2
  _rd_prep; _git_usable || true
  local reached="$3" self spec src rest dst opts l at pin path part r skip i k depth max=0 d p pp kind ok mf mv
  local x f e q w c inner how
  local uid="${SANDBOX_UID:-$(id -u)}" gid="${SANDBOX_GID:-$(id -g)}" you
  local -a found unreadable cand bsrc=() bdst=() cl=() cat=() csrc=() cdst=() cdep=() ckind=() ro_dsts=() psrc pdst
  local -a _xm_t=() _xm_by=() _xm_j=() ro_srcs=()
  local -A gpv=() gfprot=()
  local -a scan links walk gdirs gfiles glinks gunr gro ug usrc udst udep ukind
  local g base what gmax gn gitmax cfg cdir ocfg ocd k2 first ik ip ib rep al rk rh hk
  local -a inc pgd=() pga=() pgc=() pgo=() pgx=()
  local -A seen=() tried=() scanned=() pinned=()
  # Included git config files read: each once per protected config, keyed by
  # device:inode however it is spelled (review of b3d2362: `./config` and
  # `.//config` made the walk exponential) — per config, not per launch, so one
  # repository's walk never marks a file read for another's (security review of
  # c0d48d9). At most 20 per config and 1000 per launch; past either, that
  # config is named in a WARNING rather than skipped in silence.
  local nl no=0 lmax ireads=0 ients=0
  local -A hkdone=()
  local -a unchecked=()
  # The agent's identity decides what it can reach; find needs it numeric (and
  # within a 32-bit id — GNU find rejects 4294967295 and up), and a find that
  # errors out finds nothing — so refuse rather than search blind.
  if [[ ! "$uid" =~ ^[0-9]{1,10}$ || ! "$gid" =~ ^[0-9]{1,10}$ ]] \
     || (( 10#$uid > 4294967294 || 10#$gid > 4294967294 )); then
    printf 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric ids from 0 to 4294967294 (got %q / %q).\n' "$uid" "$gid" >&2
    exit 1
  fi
  # Not root, either: capsh switching 0 to 0 clears no capabilities, so the
  # agent would keep DAC_OVERRIDE and own the allowlist the root refresh loop
  # reloads (bugs review ENV-4). A root host user lands here by default.
  if (( 10#$uid == 0 || 10#$gid == 0 )); then
    printf 'ERROR: the agent must not run as root (SANDBOX_UID=%s, SANDBOX_GID=%s).\n' "$(_term "$uid")" "$(_term "$gid")" >&2
    printf '       Launching as root (sudo, a root WSL distro)? Set a non-root identity,\n' >&2
    printf '       e.g. SANDBOX_UID=1000 SANDBOX_GID=1000, for repo.sh as well.\n' >&2
    exit 1
  fi
  you="$(id -u)"
  shift 3
  _cd_phys self "$reached" || self="$reached"
  while (( $# )); do
    if [[ "$1" != -v || $# -lt 2 ]]; then shift; continue; fi
    spec="$2"; shift 2
    src="${spec%%:*}"; rest="${spec#*:}"
    dst="${rest%%:*}"; opts=""
    if [[ "$rest" == *:* ]]; then opts="${rest#*:}"; fi
    if [[ ",$opts," == *,ro,* ]]; then continue; fi
    if [[ "$src" != /* || ! -d "$src" ]]; then continue; fi
    # A mount root this launch cannot list cannot be searched for launchers,
    # and cannot be overlaid either (it IS the mount). -r/-x ask the kernel, so
    # ACLs and supplementary groups count.
    if [[ ! -r "$src" || ! -x "$src" ]]; then
      printf 'ERROR: %s cannot be listed by you, so the launcher cannot check it for\n' "$(_term "$src")" >&2
      printf '       launchers before mounting it writable at %s.\n' "$(_term "$dst")" >&2
      printf '       Make it listable (chmod u+rx, if it is yours), or mount it :ro.\n' >&2
      exit 1
    fi
    # Spelled as on disk, as every path compared with it is (GIT-38).
    _cd_phys src "$src" || continue
    bsrc+=("$src"); bdst+=("$dst")
  done

  # A symlink on the path this launcher was reached through, inside a writable
  # mount: the agent can replace it, and the host's next `cd` through it lands
  # wherever the replacement points.
  p=""; rest="${reached#/}"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    if [[ -z "$part" ]]; then continue; fi
    p="$p/$part"
    if [[ ! -L "$p" ]]; then continue; fi
    _cd_phys pp "${p%/*}/" || continue
    for i in ${bsrc[@]+"${!bsrc[@]}"}; do
      if [[ "$pp" == "${bsrc[i]}" || "$pp" == "${bsrc[i]}"/* ]]; then
        printf 'WARNING: %s is a symlink inside a writable mount (%s); the agent can\n' "$(_term "$p")" "$(_term "${bdst[i]}")" >&2
        printf '         replace it, and a later launch through it would run what replaced it.\n' >&2
        printf '         Launch through the real path instead: %s\n' "$(_term "$self")" >&2
        break
      fi
    done
  done

  # The agent's output directories, by source (LNCH-9).
  local -a outsrc=()
  local inout ox
  for i in ${bsrc[@]+"${!bsrc[@]}"}; do
    # By name too: run_container refuses an output directory that is a link, so
    # its source is the directory itself (automated security review of 8da6755).
    case "${bdst[i]}" in /workspace/.agent-blocked|/workspace/.agent-discovery)
      [[ "${bsrc[i]##*/}" == "${bdst[i]##*/}" ]] && outsrc+=("${bsrc[i]}") ;; esac
  done
  # Every launcher each mount exposes — and every directory there it cannot
  # see into — with where it lands in the container.
  for i in ${bsrc[@]+"${!bsrc[@]}"}; do
    src="${bsrc[i]}"; dst="${bdst[i]}"
    found=(); unreadable=()
    if [[ "$self" == "$src" || "$self" == "$src"/* ]]; then found+=("$self"); fi
    launcher_dirs_in found unreadable "$src" "$uid" "$gid" "$you"
    cand=(${found[@]+"${found[@]}"} ${unreadable[@]+"${unreadable[@]}"})
    for k in ${cand[@]+"${!cand[@]}"}; do
      l="${cand[k]}"
      kind=launcher
      if (( k >= ${#found[@]} )); then kind=unreadable; fi
      if [[ "$l" == "$src" ]]; then at="$dst"
      elif [[ "$l" == "$src"/* ]]; then at="$dst/${l#"$src"/}"
      else continue; fi
      d="${at//[!\/]/}"
      cl+=("$l"); cat+=("$at"); csrc+=("$src"); cdst+=("$dst"); cdep+=("${#d}"); ckind+=("$kind")
      if (( ${#d} > max )); then max=${#d}; fi
    done
  done

  # Two empty files make a launcher, and the agent can make unlistable
  # directories, so how many there are is the agent's to decide; each costs bind
  # mounts on every start and a pass of the loops below. Past
  # SANDBOX_LAUNCHER_MAX, refuse — as SANDBOX_GIT_MAX does — naming where, since
  # the agent could have planted them (tests/test-launcher-dir-ro.sh T46).
  lmax="${SANDBOX_LAUNCHER_MAX:-50}"
  if [[ ! "$lmax" =~ ^[1-9][0-9]{0,5}$ ]]; then
    printf 'ERROR: SANDBOX_LAUNCHER_MAX must be a whole number from 1 to 999999 (got %q).\n' "$lmax" >&2
    exit 1
  fi
  # Counted as overlays, not as finds: each distinct directory once, however many
  # mounts expose it, and none nested in another candidate that IS overlaid — its
  # overlay covers it (review of 643d9bd). A mount root that holds a launcher is
  # not overlaid (it stays writable, with a NOTE), so it covers nothing: the
  # agent can write those two files there (security review of c0d48d9).
  # Ancestors are walked per candidate, so this stays linear in the number found.
  # Keyed by where each lands in the container, so a directory two mounts expose
  # counts per mount, and an ancestor covers it only within the same mount.
  # Only an overlay that can be MADE covers what is nested in it, decided by the
  # test the overlay loop uses: discounting what an unmountable one held let 3,000
  # launchers under one pass a cap of 5 (review of the batch 1 hotfix, LNCH-4; a
  # pin on the way counts too, security review of 019392c). Asked only of a
  # candidate that is some other one's ancestor, once each, and the count stops
  # past the cap: asked of every candidate up front it made 2,000 planted
  # launchers take 52 s to refuse (review of batch 9, finding 1).
  local -A lcand=() lcounted=() lbuild=()
  local lc=0 la lj
  for i in ${cl[@]+"${!cl[@]}"}; do
    if [[ "${cl[i]}" != "${csrc[i]}" && -z "${lcand[${cat[i]}]:-}" ]]; then lcand[${cat[i]}]="$i"; fi
  done
  for l in ${cat[@]+"${cat[@]}"}; do
    [[ -z "${lcounted[$l]:-}" ]] || continue
    lcounted[$l]=1
    la="${l%/*}"
    while [[ -n "$la" ]]; do
      if [[ -n "${lcand[$la]:-}" ]]; then
        if [[ -z "${lbuild[$la]:-}" ]]; then
          lj="${lcand[$la]}"; lbuild[$la]=no
          if _overlay_buildable "${cl[lj]}" "${cat[lj]}" "${csrc[lj]}" "${cdst[lj]}"; then lbuild[$la]=yes; fi
        fi
        if [[ "${lbuild[$la]}" == yes ]]; then break; fi
      fi
      la="${la%/*}"
    done
    if [[ -z "$la" ]]; then
      lc=$((lc + 1))
      if (( lc > lmax )); then break; fi
    fi
  done
  if (( lc > lmax )); then
    printf 'ERROR: the writable mounts hold more than %d launchers and unlistable directories\n' "$lmax" >&2
    printf '       to protect, and each adds bind mounts to every container start. Among them:\n' >&2
    for (( k = ${#cl[@]} - 1, x = 0; k >= 0 && x < 5; k--, x++ )); do
      printf '         %s\n' "$(_q "${cl[k]}")" >&2
    done
    printf '       Remove the ones that are not yours, mount narrower directories or :ro,\n' >&2
    printf '       or raise SANDBOX_LAUNCHER_MAX if every one of them is yours.\n' >&2
    exit 1
  fi

  # Every launcher in play: this one, mounted or not, and every one found.
  scan=("$self"); scanned[$self]=1
  for i in ${cl[@]+"${!cl[@]}"}; do
    if [[ "${ckind[i]}" == launcher && -z "${scanned[${cl[i]}]:-}" ]]; then
      scanned[${cl[i]}]=1; scan+=("${cl[i]}")
    fi
  done

  # A writable bind of a directory INSIDE a launcher (its allowlist fragments,
  # say) keeps those files writable whatever overlay the launcher gets. Its own
  # output directories are meant to be written; anything else is named.
  for i in ${bsrc[@]+"${!bsrc[@]}"}; do
    for x in "${scan[@]}"; do
      if [[ "${bsrc[i]}" != "$x"/* ]]; then continue; fi
      case "${bsrc[i]#"$x"/}" in .agent-blocked|.agent-discovery) continue ;; esac
      printf 'NOTE: %s, part of launcher %s, is mounted writable at %s;\n' "$(_term "${bsrc[i]}")" "$(_term "$x")" "$(_term "${bdst[i]}")" >&2
      printf '      what changes there the host reads at the next launch.\n' >&2
      break
    done
  done

  # Shallowest first, so an outer read-only overlay is recorded before anything
  # nested in it is considered.
  for (( depth = 0; depth <= max; depth++ )); do
    for i in ${cat[@]+"${!cat[@]}"}; do
      if (( cdep[i] != depth )); then continue; fi
      at="${cat[i]}"; l="${cl[i]}"; src="${csrc[i]}"; dst="${cdst[i]}"; kind="${ckind[i]}"
      if [[ -n "${tried[$at]:-}" || -n "${seen[$at]:-}" ]]; then continue; fi
      tried[$at]=1
      skip=""
      for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$at" == "$r" || "$at" == "$r"/* ]]; then skip=1; break; fi
      done
      if [[ -n "$skip" ]]; then continue; fi
      if [[ "$l" == "$src" ]]; then
        seen[$at]=1
        printf 'NOTE: %s holds a launcher and stays writable at %s;\n' "$(_term "$l")" "$(_term "$dst")" >&2
        printf '      what changes there runs on the host at the next launch.\n' >&2
        continue
      fi
      # Searchable but not listable: what is inside can still be opened by name — a
      # FIFO sandbox.sh the host runs at the next launch, written through the
      # read-only overlay — and cannot be checked, so the launch is refused, as for
      # such a git directory (automated security review of c687370; T46). One the
      # launching user cannot search either hides nothing it can open by name.
      # Only one the agent could have written into (_agent_could_write). Another
      # user's it cannot write — an ordinary 0711 home directory, which this
      # refused (review of 7b41327; T25b) — keeps the overlay and the WARNING
      # (automated security review of cd83cb7; T25d).
      # Not in the agent's own output directories, whichever mount reaches them:
      # the host reads them only as data, and an unlistable one the agent left
      # there refused every later launch (LNCH-9; T55). It keeps the overlay and
      # the WARNING.
      inout=""
      for ox in ${outsrc[@]+"${outsrc[@]}"}; do
        if [[ "$l" == "$ox" || "$l" == "$ox"/* ]]; then inout=1; break; fi
      done
      if [[ "$kind" == unreadable && -x "$l" && -z "$inout" ]] && _agent_could_write "$l" "$uid" "$gid"; then
        printf 'ERROR: %s can be searched but not listed by you, so what is inside it cannot be\n' "$(_term "$l")" >&2
        printf '       checked for a FIFO the agent could write through a read-only overlay; refusing the launch.\n' >&2
        _unlistable_hint "$l" '       ' "$uid"
        exit 1
      fi
      # The pins this one needs, then whether docker can be handed all of them
      # and the overlay intact — all or nothing, never a partial set.
      psrc=(); pdst=()
      rest="${l#"$src"/}"; path="$src"; pin="$dst"
      while [[ "$rest" == */* ]]; do
        part="${rest%%/*}"; rest="${rest#*/}"
        path="$path/$part"; pin="$pin/$part"
        if [[ -z "${seen[$pin]:-}" ]]; then psrc+=("$path"); pdst+=("$pin"); fi
      done
      ok=1
      _overlay_buildable "$l" "$at" "$src" "$dst" || ok=""
      if [[ -z "$ok" ]]; then
        printf 'WARNING: cannot protect %s: docker cannot be handed that name intact,\n' "$(_term "$l")" >&2
        printf '         so it stays writable. Rename it on the host.\n' >&2
        continue
      fi
      for k in ${psrc[@]+"${!psrc[@]}"}; do
        seen[${pdst[k]}]=1; pinned[${pdst[k]}]=1
        _bind_mount_arg mf mv "${psrc[k]}" "${pdst[k]}" rw
        _ro+=("$mf" "$mv"); _vrfy+=("${psrc[k]}" "${pdst[k]}")
      done
      _bind_mount_arg mf mv "$l" "$at" ro
      _ro+=("$mf" "$mv"); _vrfy+=("$l" "$at")
      seen[$at]=1
      ro_dsts+=("$at")
      [[ "$kind" == unreadable ]] || ro_srcs+=("$l")
      if [[ "$kind" == unreadable ]]; then
        printf 'WARNING: %s cannot be listed by you, so it cannot be checked for\n' "$(_term "$l")" >&2
        printf '         launchers; it is mounted read-only at %s.\n' "$(_term "$at")" >&2
        _unlistable_hint "$l" '         ' "$uid"
      else
        printf 'READ-ONLY: %s  (launcher files; edit them on the host)\n' "$(_term "$at")" >&2
      fi
    done
  done

  # Git internals. What the HOST's git runs from a repository — its hooks, and
  # configuration whose keys run programs (core.hooksPath, core.fsmonitor,
  # core.sshCommand, filters, diff and merge drivers) — changed from inside the
  # container would run outside it at the next `git commit` or `git status`, and
  # nothing under .git/ shows in git status or git diff. So every git directory a
  # writable mount exposes (git_dirs_in) has its hooks/, config, config.worktree
  # and commondir mounted read-only, and every .git FILE (a linked worktree's or
  # a submodule's checkout, naming its git directory) likewise. Objects, refs and
  # the index stay writable: committing, branching, pushing and rebasing work;
  # what writes config (git config, git remote add, the upstream `push -u` would
  # record, `git submodule update --init`) does not.
  #
  # Two files git honours that a repository normally LACKS must exist to be
  # mounted, so they are made, as you, before mounting: commondir, which git
  # reads in any git directory and which would otherwise let the agent point git
  # at a config and hooks of its own — made holding `./`, this directory, which
  # git treats exactly as no commondir (measured over commit, merge, rebase,
  # stash, worktrees, gc, fsck and submodules; only `git rev-parse
  # --git-common-dir` prints the path absolute), as do libgit2 1.7 and 1.9,
  # dulwich and gitoxide; NOT `.`, which libgit2 refuses ("Repository not
  # found") — and config.worktree, made empty, where extensions.worktreeConfig
  # is on, and everywhere when git does not run (GIT-24). They stay: removing
  # one at exit would detach it in any other container still running on that
  # repository. A commondir that is not `./` in a repository's own git directory
  # refuses the launch: git never writes one there, and it sends the host's git
  # elsewhere for config and hooks.
  #
  # Directories from the mount root down to each, the git directory itself
  # included, are pinned, so .git cannot be renamed out from under the overlay.
  # A .git SYMLINK cannot be pinned (it would be replaced, not renamed) and is
  # warned about; a .git, or a directory inside one, that you cannot list is
  # mounted read-only whole. Handled shallowest first, so one under a read-only
  # overlay (a launcher, another repository's hooks/) needs nothing more. Every
  # one is protected: each costs four or five bind mounts, and a bind mount adds
  # ~50 ms to every container start on Docker Desktop, so past 30 a NOTE says so
  # — but a cap leaving the rest writable could be filled by the agent to push a
  # real repository past it, so past 200 the launch is refused instead. A named
  # group's own directories are not scanned: the host's git never runs there.
  # Every bare repository gets the placeholders, a tracked test fixture too: a
  # list that exempted fixtures could name one you push to (GIT-11, LNCH-16; G79).
  # Read before the scan, which stops following past it (GIT-9; G83).
  gitmax="${SANDBOX_GIT_MAX:-200}"
  if [[ ! "$gitmax" =~ ^[1-9][0-9]{0,5}$ ]]; then
    printf 'ERROR: SANDBOX_GIT_MAX must be a whole number from 1 to 999999 (got %q).\n' "$gitmax" >&2
    exit 1
  fi
  ug=(); usrc=(); udst=(); udep=(); ukind=(); gmax=0
  for i in ${bsrc[@]+"${!bsrc[@]}"}; do
    src="${bsrc[i]}"; dst="${bdst[i]}"
    # The group's own mounts only: a directory mounted into /workspace from inside
    # the group's directory is the agent's to write like any other (G92).
    if [[ -n "${_git_skip_root:-}" && ( "$src" == "$_git_skip_root" || "$src" == "$_git_skip_root"/* ) \
          && "$dst" != /workspace && "$dst" != /workspace/* ]]; then continue; fi
    if [[ "${src,,}" == */.git/* ]]; then
      printf 'NOTE: %s lies inside a git directory and is mounted writable at %s;\n' "$(_term "$src")" "$(_term "$dst")" >&2
      printf '      your host'\''s git may run what changes there.\n' >&2
    fi
    gdirs=(); gfiles=(); glinks=(); gunr=()
    git_dirs_in gdirs gfiles glinks gunr "$src"
    _git_scan_srcs+=("$src"); _git_bsrc=(${bsrc[@]+"${bsrc[@]}"})
    for f in ${gdirs[@]+"${gdirs[@]}"} ${gfiles[@]+"${gfiles[@]}"} ${glinks[@]+"${glinks[@]}"} ${gunr[@]+"${gunr[@]}"}; do
      _git_launch_seen[$f]="$(_git_ident "$f")"
    done
    for f in ${glinks[@]+"${glinks[@]}"}; do
      at="$dst${f#"$src"}"; skip=""
      for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$at" == "$r" || "$at" == "$r"/* ]]; then skip=1; break; fi
      done
      if [[ -n "$skip" ]]; then continue; fi
      printf 'WARNING: %s is a symlink inside a writable mount (%s); the agent can\n' "$(_term "$f")" "$(_term "$dst")" >&2
      printf '         replace it with a git directory of its own, and your host'\''s git would\n' >&2
      printf '         run that one'\''s hooks there. Replace the link with what it names.\n' >&2
    done
    for g in ${gdirs[@]+"${gdirs[@]}"}; do ug+=("$g"); ukind+=(dir); usrc+=("$src"); udst+=("$dst"); done
    for g in ${gfiles[@]+"${gfiles[@]}"}; do ug+=("$g"); ukind+=(file); usrc+=("$src"); udst+=("$dst"); done
    for g in ${gunr[@]+"${gunr[@]}"}; do ug+=("$g"); ukind+=(unr); usrc+=("$src"); udst+=("$dst"); done
  done
  # A git directory a .git file or commondir in one mount names inside ANOTHER
  # writable bind is protected in that bind's view, as if its scan had found it;
  # SANDBOX_GIT_MAX counts it like any other.
  # Keyed by where each lands in the container, so a directory two mounts expose
  # is protected in both views. Followed until nothing new turns up: a queued
  # target's own commondir names a git directory too, which was left writable
  # (review of 4a4e30c, HIGH). One inside the group's own directories, which are
  # not scanned because tools re-clone what they hold, is protected all the same
  # — left writable, the host's git would read it — and named.
  local -A uhave=()
  local j jj xq=0 xt xv2 cdt _gdi_warned=0
  for k in ${ug[@]+"${!ug[@]}"}; do uhave[${udst[k]}${ug[k]#"${usrc[k]}"}]=1; done
  while (( xq < ${#_xm_t[@]} )); do
    xt="${_xm_t[xq]}"; j="${_xm_j[xq]}"; xq=$((xq + 1))
    xv2="${bdst[j]}${xt#"${bsrc[j]}"}"
    [[ -z "${uhave[$xv2]:-}" ]] || continue
    uhave[$xv2]=1
    ug+=("$xt"); ukind+=(dir); usrc+=("${bsrc[j]}"); udst+=("${bdst[j]}")
    if [[ -f "$xt/commondir" ]]; then
      cdt=""; _git_ptr_read "$xt/commondir" cdt || true
      if [[ -n "$cdt" && "$cdt" != ./ && "$cdt" != . ]] && _gd_resolve "$xt" "$cdt" "$xt/commondir" cdt; then
        if _is_common_dir "$cdt"; then
          for jj in ${bsrc[@]+"${!bsrc[@]}"}; do
            if [[ "$cdt" == "${bsrc[jj]}" || "$cdt" == "${bsrc[jj]}"/* ]]; then
              _xm_t+=("$cdt"); _xm_by+=("$xt/commondir"); _xm_j+=("$jj")
            fi
          done
        elif _in_writable "$cdt" && (( ++_gdi_warned <= 5 )); then
          printf 'WARNING: %s names %s, which is not a git directory; nothing there is protected.\n' "$(_term "$xt/commondir")" "$(_term "$cdt")" >&2
        fi
      fi
    fi
  done
  for k in ${ug[@]+"${!ug[@]}"}; do
    at="${udst[k]}${ug[k]#"${usrc[k]}"}"; d="${at//[!\/]/}"
    udep+=("${#d}")
    if (( ${#d} > gmax )); then gmax=${#d}; fi
  done
  gn=0
  # A scan that stopped past SANDBOX_GIT_MAX (GIT-9) did not follow everything, so
  # the launch is refused here, whatever the protection loop below would count:
  # it does not count what is skipped there, and a launch with submodules left
  # unfollowed must not go ahead (automated security review of 630f5b0, HIGH; G83).
  if (( ${#_gdi_over[@]} )); then
    printf 'ERROR: the writable mounts hold more than %d git directories to protect, and\n' "$gitmax" >&2
    printf '       each adds bind mounts to every container start. Among those past the limit:\n' >&2
    for x in "${_gdi_over[@]:0:5}"; do printf '         %s\n' "$(_q "$x")" >&2; done
    printf '       Mount narrower directories, or mount them :ro, or raise SANDBOX_GIT_MAX\n' >&2
    printf '       if every one of them is yours.\n' >&2
    exit 1
  fi
  for (( depth = 0; depth <= gmax; depth++ )); do
    for k in ${ug[@]+"${!ug[@]}"}; do
      if (( udep[k] != depth )); then continue; fi
      g="${ug[k]}"; src="${usrc[k]}"; dst="${udst[k]}"; kind="${ukind[k]}"
      at="$dst${g#"$src"}"; skip=""
      for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$at" == "$r" || "$at" == "$r"/* ]]; then skip=1; break; fi
      done
      if [[ -n "$skip" ]]; then
        # Under a read-only overlay (inside a launcher, under another's hooks/): no
        # binds of its own, but what git reads there by name is held to what any
        # repository's is. Two empty files made a launcher whose repository had
        # none of it: a hard-linked config, or a commondir into its objects/
        # (reviews of the GIT-31 fix).
        if [[ "$kind" == file ]]; then _ro_links_check[$g]="file"; fi
        if [[ "$kind" == dir ]]; then
          if [[ -d "$g/objects" && -f "$g/commondir" ]]; then
            cdir=""; _git_ptr_read "$g/commondir" cdir || true
            if [[ "$cdir" != ./ ]]; then
              printf 'ERROR: %s sends git to %s for this repository'\''s\n' "$(_term "$g/commondir")" "$(_q "${cdir:0:200}")" >&2
              printf '       configuration and hooks, and git never writes one in a repository'\''s own git\n' >&2
              printf '       directory. If you did not make it, remove it on the host and launch again.\n' >&2
              exit 1
            fi
          fi
          # gitdir too, which names a linked worktree's checkout (final review of
          # the GIT-46 fix).
          for f in config config.worktree commondir gitdir; do
            if [[ -e "$g/$f" || -L "$g/$f" ]]; then _ro_links_check[$g/$f]="file"; fi
          done
          if [[ -d "$g/hooks" ]]; then _ro_links_check[$g/hooks]="hooks"; fi
          # Its includes, hooks path and links are judged after the pass, as a
          # protected repository's are, every one: one with no objects/ or no
          # config (a worktree's, whose config is its common directory's) was
          # not, and launched in silence (GIT-37; G116).
          # Whenever it has a commondir other than ./: git ignores a worktree's own
          # config, and a decoy there hid its config.worktree (review of the
          # GIT-36/37 fix).
          # One that cannot be resolved names a path that cannot exist, as the
          # protected path's does: the decoy beside it is not what git reads, and
          # what git would read once it exists cannot say the extension is off
          # (security review of a1b7ce7). An empty one is this directory, to git
          # and to _cd_phys alike.
          ocfg="$g/config"
          if [[ -f "$g/commondir" ]]; then
            cdir=""; _git_ptr_read "$g/commondir" cdir || true
            if [[ "$cdir" != ./ ]]; then
              if _cd_phys ocd "$g" "$cdir"; then ocfg="$ocd/config"
              else ocfg=/nonexistent/ai-launcher-unresolved-commondir/config; fi
            fi
          fi
          pgd+=("$g"); pga+=("$at"); pgc+=("$ocfg"); pgo[${#pgd[@]}-1]=1
        fi
        continue
      fi
      # Every one is protected — a cap that left some writable could be filled by
      # the agent (it can make repositories and unlistable directories) to push a
      # real one past it. Past SANDBOX_GIT_MAX (200), refuse instead: a bind mount
      # costs every start. The refusal names where the overflow is, since an agent
      # could have planted it, and a big tree (an AOSP-style checkout) can raise it.
      if (( gn >= gitmax )); then
        printf 'ERROR: the writable mounts hold more than %d git directories to protect, and\n' "$gitmax" >&2
        printf '       each adds bind mounts to every container start. Among those past the limit:\n' >&2
        x=0
        for (( d = depth; d <= gmax && x < 5; d++ )); do
          for k2 in "${!ug[@]}"; do
            if (( udep[k2] == d && x < 5 )) && { (( d > depth )) || (( k2 >= k )); }; then
              printf '         %s\n' "$(_q "${ug[k2]}")" >&2; x=$((x + 1))
            fi
          done
        done
        printf '       Mount narrower directories, or mount them :ro, or raise SANDBOX_GIT_MAX\n' >&2
        printf '       if every one of them is yours.\n' >&2
        exit 1
      fi
      gro=(); cfg=""
      if [[ "$kind" != dir ]]; then
        base="${g%/*}"; gro=("$g")      # a .git file, or read-only whole: pin what is above it
      else
        base="$g"
        # A config, config.worktree or commondir that is not a regular file (a FIFO)
        # is refused: a FIFO mounted read-only can still be written, so the agent
        # would feed the host's git whatever it reads there, fsmonitor and all —
        # reproduced (automated security review of 455fa85 and its review, HIGH;
        # G65). hooks/ must be a directory for the same reason.
        for f in HEAD config config.worktree commondir hooks; do
          [[ -e "$g/$f" && ! -L "$g/$f" ]] || continue
          if [[ "$f" == hooks && -d "$g/$f" ]] || [[ "$f" != hooks && -f "$g/$f" ]]; then continue; fi
          printf 'ERROR: %s is not a %s; refusing the launch.\n' "$(_term "$g/$f")" "$([[ "$f" == hooks ]] && printf directory || printf 'regular file')" >&2
          if [[ "$f" == HEAD ]]; then
            printf '       The agent could write into it, and your host'\''s git would read what it writes.\n' >&2
            printf '       Replace it on the host with a regular file, e.g. printf '\''ref: refs/heads/main\\n'\'' > %s\n' "$(_q "$g/$f")" >&2
          else
            printf '       Through a read-only bind the agent could still write into it, and your host'\''s git\n' >&2
            printf '       would read what it writes. Remove it on the host (rm %s).\n' "$(_q "$g/$f")" >&2
          fi
          exit 1
        done
        # The commondir read only when it is a regular file: a FIFO there blocked it
        # (review of 1a30bb4; G65). Read as git reads it (_git_ptr_read): $(...)
        # dropped a NUL, and `.\0/` passed for ./ (GIT-30).
        cdir=""
        if [[ -d "$g/objects" ]] && { [[ -f "$g/config" ]] || [[ ! -e "$g/commondir" && ! -L "$g/commondir" ]] \
             || { [[ -f "$g/commondir" ]] && _git_ptr_read "$g/commondir" cdir && [[ "$cdir" == ./ ]]; }; }; then
          cfg="$g/config"
          # A repository git reads with no config of its own gets an empty one, as
          # commondir gets ./ — or the agent could add one after the launch (G49).
          if [[ ! -e "$g/config" && ! -L "$g/config" ]]; then ( set -C; : > "$g/config" ) 2>/dev/null || true; fi
          # git makes hooks/ at init, but a repository can lack it — and then the
          # agent could make it.
          if [[ ! -e "$g/hooks" && ! -L "$g/hooks" ]]; then mkdir "$g/hooks" 2>/dev/null || true; fi
          first=""
          if [[ ! -e "$g/commondir" && ! -L "$g/commondir" ]]; then
            if ( set -C; printf './\n' > "$g/commondir" ) 2>/dev/null; then first=1; fi
          fi
          # Anything but our ./ sends the host's git elsewhere for this repository's
          # configuration and hooks, and git never writes one here: refuse, rather
          # than mount the redirect read-only and launch.
          if [[ -f "$g/commondir" && ! -L "$g/commondir" ]] && { _git_ptr_read "$g/commondir" cdir || true; [[ "$cdir" != "./" ]]; }; then
            printf 'ERROR: %s sends git to %s for this repository'\''s\n' "$(_term "$g/commondir")" "$(_q "${cdir:0:200}")" >&2
            printf '       configuration and hooks, and git never writes one in a repository'\''s own git\n' >&2
            printf '       directory. If you did not make it, remove it on the host and launch again.\n' >&2
            exit 1
          fi
          # Freezing the config read-only freezes whatever is in it. The launch
          # that first protects a repository — the one that just made its
          # placeholder — is the one moment that can only be what was set before
          # the protection existed, possibly from inside a container: name the
          # keys there that make the host's git run programs, once. Every value
          # stays unprinted; a credential helper's can hold a secret.
          # A repository whose placeholder was already there — made by an
          # earlier engine, or planted with one the agent made — never had this
          # moment: it is named once too, by the record of what was reported.
          # Where git does not run no key is read, so the record says only that
          # the hooks were named (`hooks:`): the next launch where git runs names
          # the keys, and the hooks NOTE is not repeated meanwhile (re-review of
          # the GIT-24 fix).
          rep=""; hk=""
          if [[ -n "$first" ]]; then rep="is protected for the first time"; al=" already"
          elif ! _git_reported "$g"; then
            if ! _git_reported "$g" hooks; then rep="was protected by an earlier launch that did not report it"; al=""
            elif _git_usable; then rep="was protected by an earlier launch where git did not run"; al=""; hk=1
            fi
          fi
          if [[ -n "$rep" ]]; then
            _git_runs "$g" rk rh
            if [[ -n "$hk" ]]; then rh=""; fi
            if [[ -n "$rk" ]]; then
              printf 'NOTE: %s %s, and its config%s sets\n' "$(_term "$at")" "$rep" "$al" >&2
              printf '      what makes your host'\''s git run programs: %s.\n' "$(_term "$rk")" >&2
              printf '      If you did not set them yourself, review them on the host:\n' >&2
              for f in "$g/config" "$g/config.worktree"; do
                if [[ -f "$f" ]]; then printf '        git config --file %s --list\n' "$(_q "$f")" >&2; fi
              done
            fi
            # The same moment freezes hooks/ as it is, and a repository the agent
            # made in a subdirectory arrives with whatever hooks it put there.
            if [[ -n "$rh" ]]; then
              printf 'NOTE: %s %s, and its hooks/%s\n' "$(_term "$at")" "$rep" "$al" >&2
              printf '      holds hooks your host'\''s git runs: %s.\n' "$(_term "$rh")" >&2
              printf '      If you did not put them there, review them on the host:\n' >&2
              printf '        ls -l %s\n' "$(_q "$g/hooks")" >&2
            fi
            # Not as reported where git does not run: no key was read, and the
            # launch with git that its WARNING asks for must still name them
            # (review of the GIT-24 fix, M1).
            if _git_usable; then _git_report_record "$g"; else _git_report_record "$g" hooks; fi
          fi
        elif [[ -f "$g/commondir" ]]; then
          # Physically, as git resolves it (strbuf_add_real_path), and without the
          # trailing CR git strips: `cd` reads `s/..` lexically, which named the
          # worktree's own directory, with no config, while git used A/.git
          # (review of batch 9, finding 3; G45).
          # Read as git reads it, or refused (_git_ptr_read; GIT-30). One that
          # cannot be resolved names a path that cannot exist, so both checks
          # below fail closed (security review of 99db199).
          cdir=""; _git_ptr_read "$g/commondir" cdir || true
          _cd_phys cfg "$g" "$cdir" || cfg=""
          # Not a path in the agent's tree, where it could plant one saying the
          # extension is off (security review of the commondir fix): a host path nothing makes.
          cfg="${cfg:-/nonexistent/ai-launcher-unresolved-commondir}/config"
        fi
        # A common config that cannot be read cannot say the extension is off, so
        # the placeholder is made, and config.worktree walked below, as if it were on.
        # Nor can one read where git does not run (GIT-24; G98).
        if [[ -n "$cfg" && ! -e "$g/config.worktree" && ! -L "$g/config.worktree" ]]; then
          if [[ ! -f "$cfg" ]] || ! _git_usable || _git_config_bool "$cfg" extensions.worktreeConfig; then
            ( set -C; : > "$g/config.worktree" ) 2>/dev/null || true
          fi
        fi
        # gitdir too, a linked worktree's: it names the checkout a relative
        # core.hooksPath is judged from, and written by the agent it chose that
        # (automated security review of c6316af; GIT-46).
        for f in config config.worktree commondir hooks gitdir; do
          if [[ -L "$g/$f" ]]; then
            printf 'WARNING: %s is a symlink, which cannot be mounted read-only in place;\n' "$(_term "$g/$f")" >&2
            printf '         what it leads to is what your host'\''s git reads. Replace the link with it.\n' >&2
          elif [[ -e "$g/$f" ]]; then
            gro+=("$g/$f")
          elif [[ "$f" == hooks || "$f" == commondir ]] && [[ -d "$g/objects" ]]; then
            printf 'WARNING: %s has no %s and one could not be made; the agent could make it.\n' "$(_term "$g")" "$(_term "$f")" >&2
          fi
        done
      fi
      if (( ${#gro[@]} == 0 )); then continue; fi
      psrc=(); pdst=()
      if [[ "$base" != "$src" ]]; then
        rest="${base#"$src"/}"; path="$src"; pin="$dst"
        while [[ -n "$rest" ]]; do
          part="${rest%%/*}"
          if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
          path="$path/$part"; pin="$pin/$part"
          if [[ -z "${seen[$pin]:-}" ]]; then psrc+=("$path"); pdst+=("$pin"); fi
        done
      fi
      ok=1
      for k2 in ${psrc[@]+"${!psrc[@]}"}; do
        if ! _mount_representable "${psrc[k2]}" "${pdst[k2]}"; then ok=""; fi
      done
      for f in "${gro[@]}"; do
        if ! _mount_representable "$f" "$dst${f#"$src"}"; then ok=""; fi
      done
      if [[ -z "$ok" ]]; then
        printf 'WARNING: cannot protect the git internals of %s: docker cannot be handed\n' "$(_term "$g")" >&2
        printf '         that name intact, so they stay writable. Rename it on the host.\n' >&2
        continue
      fi
      gn=$((gn + 1))
      for k2 in ${psrc[@]+"${!psrc[@]}"}; do
        seen[${pdst[k2]}]=1; pinned[${pdst[k2]}]=1
        _bind_mount_arg mf mv "${psrc[k2]}" "${pdst[k2]}" rw
        _ro+=("$mf" "$mv"); _vrfy+=("${psrc[k2]}" "${pdst[k2]}")
      done
      what=""
      for f in "${gro[@]}"; do
        x="$dst${f#"$src"}"
        _bind_mount_arg mf mv "$f" "$x" ro
        _ro+=("$mf" "$mv"); _vrfy+=("$f" "$x")
        seen[$x]=1; ro_dsts+=("$x"); ro_srcs+=("$f")
        if [[ "$kind" != unr ]]; then
          if [[ -d "$f" ]]; then _ro_links_check[$f]="hooks"; else _ro_links_check[$f]="file"; fi
        fi
        [[ -d "$f" ]] || launcher_ro_files+=("$f")
        if [[ "$f" != "$g" ]]; then what+="${what:+, }${f##*/}"; fi
      done
      if [[ "$kind" == unr && -x "$g" ]]; then
        # Searchable but not listable: git still opens what is inside by name, and
        # what is inside cannot be checked for a FIFO the agent writes through the
        # read-only bind (review of 56c91c4, HIGH; G66). Refused, whoever owns it:
        # binding another user's whole needed its config proved inert, and each
        # review found another way it was not — exec keys, sendemail recipients,
        # a remote URL naming a repository the agent makes (GIT-13; the user's
        # choice, reviews of the batch 10 branch).
        printf 'ERROR: %s can be searched but not listed by you, so what your host'\''s git reads in\n' "$(_term "$g")" >&2
        printf '       it cannot be checked; refusing the launch.\n' >&2
        _unlistable_hint "$g" '       ' "$uid"
        exit 1
      fi
      if [[ "$kind" == unr ]]; then
        printf 'WARNING: %s cannot be listed by you, so what it holds cannot be\n' "$(_term "$g")" >&2
        printf '         protected one by one; it is mounted read-only whole at %s.\n' "$(_term "$at")" >&2
        _unlistable_hint "$g" '         ' "$uid"
      elif [[ "$kind" == file ]]; then
        printf 'READ-ONLY: %s  (names the git directory your host'\''s git uses here)\n' "$(_term "$at")" >&2
        gfprot[$g]=1
      else
        printf 'READ-ONLY: %s: %s  (what your host'\''s git runs; change them on the host)\n' "$(_term "$at")" "$(_term "$what")" >&2
        pgd+=("$g"); pga+=("$at"); pgc+=("$cfg"); gpv[$at]=1
      fi
    done
  done
  # The git directories a .git file or commondir named in another writable mount:
  # named unless that mount's own view of them is read-only now.
  # Protected means ITS binds were issued (gpv), or it lies under a read-only
  # overlay — never merely that some read-only bind sits inside it, which a
  # repository the agent nests in it provides (review of 4e7da47, HIGH). Each
  # (target, mount) is judged; one is marked done only once named; twenty are
  # named, then a count.
  local -A xm_done=()
  local xv xr xs xn=0 xgw=0
  for k in ${_xm_t[@]+"${!_xm_t[@]}"}; do
    xv="${bdst[${_xm_j[k]}]}${_xm_t[k]#"${bsrc[${_xm_j[k]}]}"}"
    [[ -z "${xm_done[$xv]:-}" ]] || continue
    xs="${gpv[$xv]:-}"
    if [[ -n "$xs" && -n "${_git_skip_root:-}" && "${_xm_t[k]}" == "$_git_skip_root"/* ]]; then
      xm_done[$xv]=1
      if (( ++xgw <= 5 )); then
        printf 'NOTE: %s names %s, inside the container group'\''s own directories, which this launch\n' "$(_term "${_xm_by[k]}")" "$(_term "${_xm_t[k]}")" >&2
        printf '      protected there: a tool that deletes and re-clones it may fail with Resource busy.\n' >&2
        printf '      If that .git file is not yours, remove it on the host.\n' >&2
      fi
      continue
    fi
    if [[ -z "$xs" ]]; then
      for xr in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$xv" == "$xr" || "$xv" == "$xr"/* ]]; then xs=1; break; fi
      done
    fi
    [[ -z "$xs" ]] || continue
    xm_done[$xv]=1
    if (( ++xn <= 20 )); then
      printf 'WARNING: %s names %s, a git directory in another writable mount (%s),\n' "$(_term "${_xm_by[k]}")" "$(_term "${_xm_t[k]}")" "$(_term "${bdst[${_xm_j[k]}]}")" >&2
      printf '         which could not be protected there: your host'\''s git reads it. Check it on the host.\n' >&2
    fi
  done
  if (( xn > 20 )); then
    printf 'WARNING: … and %d more git directories in other writable mounts could not be protected.\n' "$((xn - 20))" >&2
  fi
  if (( xgw > 5 )); then
    printf 'NOTE: … and %d more in the container group'\''s own directories.\n' "$((xgw - 5))" >&2
  fi
  if (( _gdi_warned > 5 )); then
    printf 'WARNING: … and %d more commondirs of git directories in other mounts name what this launch cannot protect.\n' "$((_gdi_warned - 5))" >&2
  fi
  # Where git does not run nothing reads a config or an index (GIT-24): what that
  # leaves unchecked is said once, rather than passed over in silence. For a .git
  # file too: with git, the index of the git directory it names is read
  # (re-review of the GIT-24 fix).
  if (( gn > 0 )) && ! _git_usable; then
    printf 'WARNING: git is not installed on this host, is older than 2.18, or does not run, so\n' >&2
    printf '         no git config or index was read for the git directories and .git files\n' >&2
    printf '         protected here (%d): includes, keys that make git run a program, a\n' "$gn" >&2
    printf '         core.hooksPath that leads into a writable mount, and submodule checkouts\n' >&2
    printf '         outside the scan are not checked. Install git 2.18 or later on the host\n' >&2
    printf '         and launch again.\n' >&2
  fi
  if (( gn > 30 )); then
    printf 'NOTE: %d git directories were protected, each with its own bind mounts; that\n' "$gn" >&2
    printf '      adds seconds to every container start on Docker Desktop. Mount narrower\n' >&2
    printf '      directories, or mount the ones you will not change :ro.\n' >&2
  fi

  # A git directory that a .git file in a writable mount names outside every
  # writable mount — a linked worktree's, or a separate git directory, whose
  # checkout alone is mounted — is judged too, and so is its common directory,
  # with no binds of their own: the host's git reads their config, includes and
  # hooks for a command run in the checkout the agent can write. Only those the
  # launch protects, or found under a read-only overlay, were, and with husky's
  # layout under `git worktree` the agent wrote the hooks the host then ran
  # (GIT-44).
  # Git directories only, as git takes them: a planted .git file naming any
  # directory of the host had a file there read as its config. And at most
  # SANDBOX_GIT_MAX: .git files under a read-only overlay count toward nothing
  # else, and the agent can plant thousands (review of the GIT-44 fix).
  # The cap only for those named by .git files the launch did not protect —
  # under a read-only overlay, a planted launcher's — taken in the order found:
  # a protected .git file counts toward SANDBOX_GIT_MAX already, and the
  # repository a mount lies in is one per mount. Taken in hash order, a real
  # repository was cut while planted ones were judged (re-review of the GIT-44
  # fix).
  local -A pgk=()
  local t pass ncap=0
  local -a pgxo=()
  for k in ${pgd[@]+"${!pgd[@]}"}; do pgk[${pgd[k]}]=1; done
  for pass in 1 2; do
  for i in ${_gref_t[@]+"${!_gref_t[@]}"}; do
    t="${_gref_t[i]}"
    if [[ -n "${gfprot[${_gref_d[i]}/.git]:-}" ]] || ! _in_writable "${_gref_d[i]}"; then x=1; else x=2; fi
    [[ "$x" == "$pass" && -z "${pgk[$t]:-}" ]] || continue
    if _in_writable "$t" || ! _is_git_dir "$t"; then continue; fi
    pgk[$t]=1
    if (( pass == 2 )); then
      if (( ${#pgxo[@]} || ncap >= gitmax )); then pgxo+=("$t"); continue; fi
      ncap=$((ncap + 1))
    fi
    ocfg="$t/config"
    if [[ -f "$t/commondir" ]]; then
      cdir=""; _git_ptr_read "$t/commondir" cdir || true
      if [[ -n "$cdir" && "$cdir" != ./ ]]; then
        if _cd_phys ocd "$t" "$cdir"; then
          ocfg="$ocd/config"
          if [[ -z "${pgk[$ocd]:-}" ]] && ! _in_writable "$ocd" && _is_common_dir "$ocd"; then
            pgk[$ocd]=1; pgd+=("$ocd"); pga+=("$ocd"); pgc+=("$ocd/config"); pgx[${#pgd[@]}-1]=1
          fi
        else
          ocfg=/nonexistent/ai-launcher-unresolved-commondir/config
        fi
      fi
    fi
    pgd+=("$t"); pga+=("$t"); pgc+=("$ocfg"); pgx[${#pgd[@]}-1]=1
  done
  done
  if (( ${#pgxo[@]} )); then
    printf 'WARNING: .git files under read-only overlays here name more than %d git directories outside\n' "$gitmax" >&2
    printf '         every writable mount (SANDBOX_GIT_MAX); what these hold was not judged:\n' >&2
    for x in "${pgxo[@]:0:5}"; do printf '           %s\n' "$(_term "$x")" >&2; done
    if (( ${#pgxo[@]} > 5 )); then printf '         … and %d more.\n' "$(( ${#pgxo[@]} - 5 ))" >&2; fi
    printf '         Remove the .git files you did not make, or raise SANDBOX_GIT_MAX.\n' >&2
  fi

  # What a protected repository's git runs or reads from OUTSIDE its read-only
  # mounts — judged now that every overlay is decided, so a step into a
  # repository handled later counts as protected. A common directory's before
  # its linked worktrees', whose core.hooksPath its config sets (GIT-44).
  local -a kord=() _hpv_g=() _hpv_v=()
  for k in ${pgd[@]+"${!pgd[@]}"}; do [[ "${pgc[k]}" != "${pgd[k]}/config" ]] || kord+=("$k"); done
  for k in ${pgd[@]+"${!pgd[@]}"}; do [[ "${pgc[k]}" == "${pgd[k]}/config" ]] || kord+=("$k"); done
  for k in ${kord[@]+"${kord[@]}"}; do
    g="${pgd[k]}"; at="${pga[k]}"; cfg="${pgc[k]}"
    # One under a read-only overlay: a link among what git reads by name is read
    # through, and the overlay covers the link, not where it leads. Named whatever
    # it leads to, a link that leads nowhere yet included, as a protected one's
    # is (GIT-37).
    if [[ -n "${pgo[k]:-}" ]]; then
      for f in config config.worktree commondir hooks; do
        if [[ ! -L "$g/$f" ]]; then continue; fi
        printf 'WARNING: %s, under a read-only overlay, is a symlink: what it leads to is what your\n' "$(_term "$at/$f")" >&2
        printf '         host'\''s git reads, and the overlay covers the link, not that. Replace the link\n' >&2
        printf '         on the host with what it names.\n' >&2
      done
    fi
    # One outside every writable mount: a link among them is named where its way
    # out is the agent's to change (GIT-44).
    if [[ -n "${pgx[k]:-}" ]]; then
      for f in config config.worktree commondir hooks; do
        if [[ ! -L "$g/$f" ]]; then continue; fi
        walk=()
        mapfile -d '' -t walk < <(_link_walk "$g/$f")
        if ! _walk_exposed how q w "" ${walk[@]+"${walk[@]}"}; then continue; fi
        printf 'WARNING: %s, outside every writable mount, leads somewhere the agent can change:\n' "$(_term "$g/$f")" >&2
        case "$how" in
          change)  printf '         it can change %s (at %s), which your host'\''s git reads or runs through it.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          linked)  printf '         it can write %s through another name of that file, in %s\n' "$(_term "$q")" "$(_term "$w")" >&2
                   printf '         (on the host, find %s -xdev -samefile %s lists it).\n' "$(_q "$w")" "$(_q "$q")" >&2 ;;
          unsearched) printf '         %s has another name, and %s could not be searched for it in full.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          repoint) printf '         it can repoint %s (at %s), a link on its way.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          replace) printf '         it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          unchecked) printf '         its way out was not followed to the end (too many steps or links), so it is not known to be safe.\n' >&2 ;;
        esac
        printf '         Your host'\''s git reads it for the checkout mounted here. Replace the link on the host\n' >&2
        printf '         with what it names.\n' >&2
      done
    fi
    # A file the config includes is read as part of it, so it can set anything
    # the config can — core.fsmonitor, core.hooksPath — from wherever it lies.
    # git resolves a relative path from the including file's directory. An
    # included file the agent cannot reach can include one it can, so the chain
    # is followed from every file found safe, to git's own depth of 10; a file
    # the agent can reach is named, not read (tests/test-git-internals-ro-config.sh G29).
    # Bounded per LAUNCH as well as per config: two configs per git directory and
    # up to SANDBOX_GIT_MAX planted git directories made 150 repos take 81 s (review
    # of the batch 1 hotfix; GIT-2). config.worktree only where git reads it.
    local -A iseen=() hkp=() hkw=() hkr=() hkc=() icnd=()
    local -a hcf=() hcfw=()
    for f in "$g/config" "$g/config.worktree"; do
      # Through a link, for one outside every writable mount: its way out was
      # judged above, and what it leads to is what git reads (review of the
      # GIT-44 fix).
      if [[ ! -f "$f" ]] || { [[ -L "$f" ]] && [[ -z "${pgx[k]:-}" ]]; }; then continue; fi
      # From the config git reads extensions from: the common one, for a linked
      # worktree's git directory, which has none of its own (security review of
      # 1978dff). One that is not a readable file cannot say it is off: walked.
      if [[ "$f" == */config.worktree && -f "$cfg" ]] && ! _git_config_bool "$cfg" extensions.worktreeConfig; then continue; fi
      local -a ifile=("$f") idep=(0)
      local ii=0 icur itgt ikey inr=0 ient=0 icut="" icomp
      iseen=()
      ikey="$(_launcher_dev_ino "$f")" && iseen[$ikey]=1
      while (( ii < ${#ifile[@]} )); do
      icur="${ifile[ii]}"; ii=$((ii + 1))
      inc=()
      mapfile -d '' -t inc < <(_git_walk_keys "$icur")
      hkr[$icur]=1
      for e in ${inc[@]+"${inc[@]}"}; do
        # Entries, not only files: each costs a walk, and one config can hold
        # thousands (re-review of c0d48d9; G38). core.hooksPath and core.worktree
        # count too: thousands of them in a planted config cost a launch seconds
        # (re-review of the GIT-35 fix).
        # The launch's budget counts only what is walked: empty and oversized values
        # cost nothing, and planted repositories spent it on them, cutting the walk
        # of every later config (GIT-19; G72). They still count per config.
        # Cut, the file's core keys are read for the check below by git, not lost (hkc).
        if (( ++ient > 100 )); then icut=1; ii=${#ifile[@]}; hkc[$icur]=1; break; fi
        ik="${e%%$'\n'*}"; ip=""
        if [[ "$e" == *$'\n'* ]]; then ip="${e#*$'\n'}"; fi
        # The last of each in this file, for the core.hooksPath check below.
        case "$ik" in
          core.hookspath) hkp[$icur]="$ip"; continue ;;
          core.worktree) hkw[$icur]="$ip"; continue ;;
        esac
        if [[ -z "$ip" ]]; then continue; fi
        # A value git cannot open (longer than PATH_MAX) includes nothing. One with
        # hundreds of components is not walked step by step — _path_walk is
        # quadratic in them (100 such entries took 54 s) — and is left unchecked,
        # which the cut WARNING says.
        if (( ${#ip} > 4096 )); then continue; fi
        if (( ++ients > 1000 )); then icut=1; ii=${#ifile[@]}; hkc[$icur]=1; break; fi
        icomp="${ip//[!\/]/}"
        if (( ${#icomp} > 128 )); then icut=1; continue; fi
        # shellcheck disable=SC2088  # '~/'* matches a LITERAL leading ~/ in the config value, expanded by hand
        case "$ip" in '~/'*) ip="$HOME/${ip#\~/}" ;; esac
        walk=()
        _cd_phys ib "${icur%/*}" || ib=""
        mapfile -d '' -t walk < <(_path_walk "$ib" "$ip")
        if ! _walk_exposed how q w "" ${walk[@]+"${walk[@]}"}; then
          if [[ "$ip" == /* ]]; then itgt="$ip"; else itgt="${icur%/*}/$ip"; fi
          if [[ -f "$itgt" ]] && (( idep[ii - 1] < 10 )) && ikey="$(_launcher_dev_ino "$itgt")" \
             && [[ -z "${iseen[$ikey]:-}" ]]; then
            iseen[$ikey]=1
            if (( inr >= 20 || ireads >= 1000 )); then
              icut=1
            else
              inr=$((inr + 1)); ireads=$((ireads + 1))
              ifile+=("$itgt"); idep+=("$((idep[ii - 1] + 1))")
              # Read only when its condition holds, or reached through one that is.
              if [[ "${ik,,}" == includeif.* || -n "${icnd[$icur]:-}" ]]; then icnd[$itgt]=1; fi
            fi
          fi
          continue
        fi
        if [[ "$icur" == "$f" ]]; then
          printf 'WARNING: %s includes %s (%s), which the agent can redirect:\n' "$(_q "$at/${f##*/}")" "$(_q "$ip")" "$(_term "$ik")" >&2
        else
          printf 'WARNING: %s includes %s (%s in %s), which the agent can redirect:\n' "$(_q "$at/${f##*/}")" "$(_q "$ip")" "$(_term "$ik")" "$(_q "$icur")" >&2
        fi
        case "$how" in
          change)  printf '         it can write %s (at %s), which git reads as part of that config.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          linked)  printf '         it can write %s through another name of that file, in %s\n' "$(_term "$q")" "$(_term "$w")" >&2
                   printf '         (on the host, find %s -xdev -samefile %s lists it); git reads it as part of that config.\n' "$(_q "$w")" "$(_q "$q")" >&2 ;;
          unsearched) printf '         %s has another name, and %s could not be searched for it in full.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          repoint) printf '         it can repoint %s (at %s), a link on its way.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          replace) printf '         it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          unchecked) printf '         its way out was not followed to the end (too many steps or links), so it is not known to be safe.\n' >&2 ;;
        esac
        printf '         It can set what your host'\''s git runs. Move what it sets into %s on the host.\n' "${f##*/}" >&2
      done
      done
      # What git reads core.hooksPath from, below: this file and those it
      # includes that the agent cannot reach (one it can is named above).
      hcf+=("${ifile[@]}")
      if [[ "$f" == "$g/config.worktree" ]]; then hcfw+=("${ifile[@]}"); fi
      if [[ -n "$icut" ]]; then
        printf 'WARNING: not every include of %s was followed (100 entries and 20 files per config, 1000 of each per launch, 128 path components);\n' "$(_q "$at/${f##*/}")" >&2
        printf '         what the rest set was not checked. Review them: git config --file %s --list --show-origin --includes\n' "$(_q "$f")" >&2
      fi
    done

    # Hooks run from a directory core.hooksPath names are project files the
    # overlay leaves writable — and hook managers keep the scripts they run
    # gitignored (husky's .husky/_), so a change need not show in git status.
    # The key is read where git reads it: the config, the files it includes that
    # the agent cannot reach, and config.worktree where git reads that — the
    # files the include walk above read, which gave their keys too — the last
    # value of each, since git takes the last of them all. A relative one is
    # judged from each worktree git may run hooks in: where the .git lies, and
    # its core.worktree. The whole way is walked as an include's is — the way to
    # the core.worktree too: a link on it the agent can repoint, or a directory a
    # `..` steps out of that it can swap, sends git to hooks of its choosing;
    # resolved through them, a husky .husky/_ the agent had made a link to any
    # directory of the host was silent (GIT-35), and so was a submodule's
    # worktree made one (review of the fix). Every way is judged before any is
    # skipped as named.
    local b v y hd hwd hx hcond="" hopt="" hcut="" hkcut=""
    local -a hps=() hpx=() hwds=() hb=() hbd=() hbp=() wd=() wp=()
    local -A hseen=()
    local -a hfl=()
    if [[ "$cfg" == "$g/config" ]]; then
      hfl=("$cfg" ${hcf[@]+"${hcf[@]}"})
    else
      # A linked worktree's git directory: git takes core.hooksPath from the
      # common config, whose own judging collected what it and its includes
      # set (and judged it from the common config's core.worktree, and walked
      # the common hooks/ it runs), and from this one's config.worktree where
      # git reads that — never from a config of its own (GIT-44).
      hfl=(${hcfw[@]+"${hcfw[@]}"})
      for i in ${_hpv_g[@]+"${!_hpv_g[@]}"}; do
        [[ "${_hpv_g[i]}" == "${cfg%/config}" ]] || continue
        v="${_hpv_v[i]}"
        # Only one relative to a checkout: an absolute one, or one not judged, is
        # the same from every worktree, and was named once per worktree
        # (re-review of the GIT-44 fix).
        # (A :(optional) one stays: to a git older than 2.52 it is relative.)
        case "$v" in /*|'~'*|'%(prefix)/'*) continue ;; esac
        if [[ -z "${hseen[v:$v]:-}" ]]; then hseen[v:$v]=1; hps+=("$v"); fi
      done
    fi
    if (( ${#hfl[@]} )); then
      for f in "${hfl[@]}"; do
        [[ -z "${hseen[f:$f]:-}" ]] || continue
        hseen[f:$f]=1
        # core.worktree from the config and config.worktree alone: git never
        # takes it from a file they include (re-review of the GIT-35 fix).
        x=""
        if [[ -n "${hkr[$f]:-}" && -z "${hkc[$f]:-}" ]]; then
          v="${hkp[$f]:-}"
          if [[ "$f" == "$g/config" || "$f" == "$g/config.worktree" ]]; then x="${hkw[$f]:-}"; fi
        else
          # Not read by the walk: a config that is a link, or one past a cut.
          _git_config_get v "$f" core.hooksPath || v=""
          if [[ "$f" == "$g/config" || "$f" == "$g/config.worktree" ]]; then _git_config_get x "$f" core.worktree || x=""; fi
        fi
        if [[ -n "$v" ]]; then
          # From an includeIf, git may not use it, and run what hooks/ holds.
          if [[ -n "${icnd[$f]:-}" ]]; then hcond=1; fi
          if [[ -z "${hseen[v:$v]:-}" ]]; then hseen[v:$v]=1; hps+=("$v"); fi
        fi
        if [[ -n "$x" && -z "${hseen[w:$x]:-}" ]]; then hseen[w:$x]=1; hb+=("$x"); fi
      done
    fi
    # For its linked worktrees, which take them from this config.
    if [[ "$cfg" == "$g/config" ]]; then
      for v in ${hps[@]+"${hps[@]}"}; do _hpv_g+=("$g"); _hpv_v+=("$v"); done
    fi
    # Each base: a directory, and what goes before the value when walked from it.
    # Where the .git lies, each checkout whose .git file names this git
    # directory, a linked worktree's own (gitdir), and each core.worktree.
    if [[ "${g,,}" == */.git ]]; then hbd+=("${g%/*}"); hbp+=(""); hseen[r:${g%/*}]=1; fi
    for i in ${_gref_i[$g]:-}; do
      [[ -z "${hseen[r:${_gref_d[i]}]:-}" ]] || continue
      hseen[r:${_gref_d[i]}]=1; hbd+=("${_gref_d[i]}"); hbp+=("")
    done
    # Relative too, as git 2.48 and later can write it (worktree.useRelativePaths):
    # from this directory (review of the GIT-44 fix).
    if [[ "$cfg" != "$g/config" && -f "$g/gitdir" ]]; then
      x=""; _git_ptr_read "$g/gitdir" x gitdir || x=""
      if [[ "${x,,}" == */.git ]]; then x="${x%/*}"; fi
      # One that does not exist — deleted and never pruned, or made in a container
      # with /workspace paths — is judged from where it would be: in a writable
      # mount the agent can make it; elsewhere git runs nothing there. Not named
      # as unknown on every launch (final review of the GIT-46 fix).
      if [[ -n "$x" ]]; then
        y="$x"
        if ! _cd_phys x "$g" "$y"; then
          [[ "$y" == /* ]] || y="$g/$y"
          y="$(_lex_norm "$y")"; _canon_lex x "$y"
        fi
        if [[ -n "$x" && -z "${hseen[r:$x]:-}" ]]; then hseen[r:$x]=1; hbd+=("$x"); hbp+=(""); fi
      fi
    fi
    for x in ${hb[@]+"${hb[@]}"}; do hbd+=("$g"); hbp+=("$x/"); done
    # None: a bare repository, run in itself. Not a linked worktree's, whose
    # checkout is not known here: from its git directory the NOTE named a place
    # git never runs hooks in.
    if (( ! ${#hbd[@]} )) && [[ "$cfg" == "$g/config" ]]; then hbd=("$g"); hbp=(""); fi
    # :(optional) is taken off by git 2.52 and later, which run hooks/ where the
    # rest does not exist (review of the GIT-35 fix); an older git, Ubuntu
    # 24.04's 2.43 among them, reads it as part of a relative path, which the
    # agent can make (re-review). Both readings are judged, whatever the git:
    # a host can hold two (macOS's /usr/bin/git beside Homebrew's), and the one
    # the launcher asks need not be the one that runs the hooks (third review).
    for v in ${hps[@]+"${hps[@]}"}; do
      [[ "$v" == ':(optional)'* ]] || continue
      hopt=1
      x="${v#:(optional)}"
      if [[ -n "$x" && -z "${hseen[v:$x]:-}" ]]; then hseen[v:$x]=1; hpx+=("$x"); fi
    done
    hps+=(${hpx[@]+"${hpx[@]}"})
    for v in ${hps[@]+"${hps[@]}"}; do
      [[ -n "$v" ]] || continue
      # As for an include: one git cannot open runs nothing (longer than PATH_MAX).
      if (( ${#v} > 4096 )); then continue; fi
      wd=(); wp=()
      # shellcheck disable=SC2088  # '~/'* matches a LITERAL leading ~/ in the config value, expanded by hand
      case "$v" in
        /*) wd=(/); wp=("$v") ;;
        '~/'*) wd=(/); wp=("$HOME/${v#\~/}") ;;
        '~'*|'%(prefix)/'*)
          printf 'NOTE: %s takes its git hooks from %s (core.hooksPath), which the launcher does not expand\n' "$(_term "$at")" "$(_term "$v")" >&2
          printf '      (~user/, %%(prefix)/), so it is not judged. Check them before a git commit on the host.\n' >&2
          continue ;;
        *)
          # A linked worktree whose checkout this launch does not know: not judged,
          # and said so (automated security review of c6316af; GIT-46).
          if (( ! ${#hbd[@]} )); then
            printf 'NOTE: %s takes its git hooks from %s (core.hooksPath) relative to a checkout this launch\n' "$(_term "$at")" "$(_term "$v")" >&2
            printf '      does not know, so they are not judged. Check them before a git commit there.\n' >&2
            continue
          fi
          for i in "${!hbd[@]}"; do wd+=("${hbd[i]}"); wp+=("${hbp[i]}$v"); done ;;
      esac
      for i in "${!wd[@]}"; do
        # Each walk counts in the launch's budget, which the include walk spends
        # too: the values times the worktrees took a planted repository's launch
        # from 0.9 s to 64 s (re-review of the GIT-35 fix). One with hundreds of
        # components is not walked step by step, as for an include, and named once.
        if (( ++ients > 1000 )); then hcut=1; break 2; fi
        x="${wp[i]//[!\/]/}"
        if (( ${#x} > 128 )); then
          [[ -z "${hseen[u:$v]:-}" ]] || continue
          hseen[u:$v]=1
          printf 'NOTE: %s takes its git hooks from %s (core.hooksPath), whose way has too many\n' "$(_term "$at")" "$(_term "$v")" >&2
          printf '      components to follow, so it is not known to be safe. Check them before a git commit on the host.\n' >&2
          continue
        fi
        walk=()
        mapfile -d '' -t walk < <(_path_walk "${wd[i]}" "${wp[i]}")
        hd=""
        for x in ${walk[@]+"${walk[@]}"}; do [[ "$x" != =* ]] || hd="${x#=}"; done
        if ! _walk_exposed how q w "" ${walk[@]+"${walk[@]}"}; then
          if [[ -n "$hd" && -z "${hseen[h:$hd]:-}" ]]; then hseen[h:$hd]=1; hwds+=("$hd"); fi
          continue
        fi
        if [[ "$how" == change ]]; then
          [[ -z "${hseen[c:$w]:-}" ]] || continue
          hseen[c:$w]=1
          printf 'NOTE: %s runs its git hooks from %s (core.hooksPath), which the agent\n' "$(_term "$at")" "$(_term "$w")" >&2
          printf '      can change; hook managers keep those scripts gitignored (husky'\''s .husky/_),\n' >&2
          printf '      so a change need not show in git status. Check them before a git commit on the host.\n' >&2
          continue
        fi
        # Where they are, as the agent sees it where a mount holds it.
        x="${hd:-${wp[i]}}"
        for b in ${bsrc[@]+"${!bsrc[@]}"}; do
          if [[ -n "$hd" && ( "$hd" == "${bsrc[b]}" || "$hd" == "${bsrc[b]}"/* ) ]]; then x="${bdst[b]}${hd#"${bsrc[b]}"}"; break; fi
        done
        # Once per value where the way was not followed to the end, whatever the base.
        if [[ "$how" == unchecked ]]; then x="$v"; q=""; fi
        [[ -z "${hseen[o:$how:$q:$x]:-}" ]] || continue
        hseen[o:$how:$q:$x]=1
        printf 'NOTE: %s runs its git hooks from %s (core.hooksPath), and the agent can change the way there:\n' "$(_term "$at")" "$(_term "$x")" >&2
        case "$how" in
          repoint) printf '      it can repoint %s (at %s), a link on its way.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          replace) printf '      it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          unchecked) printf '      its way was not followed to the end (too many steps or links), so it is not known to be safe.\n' >&2 ;;
          *) printf '      it can change %s.\n' "$(_term "$q")" >&2 ;;
        esac
        printf '      Check them before a git commit on the host.\n' >&2
      done
    done
    if [[ -n "$hcut" ]]; then
      printf 'WARNING: not every core.hooksPath of %s was judged (1000 ways per launch, with its includes);\n' "$(_q "$at")" >&2
      printf '         check its hooks before a git commit on the host: git -C %s rev-parse --git-path hooks\n' "$(_q "$g")" >&2
    fi
    # hooks/ where git may run it: no core.hooksPath, one an includeIf may not
    # apply, or one git falls back from (:(optional)).
    if (( ! ${#hps[@]} )) || [[ -n "$hcond$hopt" ]]; then
      if [[ -d "$g/hooks" && -z "${hseen[h:$g/hooks]:-}" ]] && { [[ ! -L "$g/hooks" ]] || [[ -n "${pgx[k]:-}" ]]; }; then hwds+=("$g/hooks"); fi
    fi
    # A hook that is a link: hooks/ is read-only, but the link's way out need
    # not be. Pointing hooks at scripts the project tracks is a common setup,
    # hence a NOTE. Only the names git runs are looked at, so the count is
    # bounded whatever hooks/ was filled with before it was protected. In a
    # directory core.hooksPath names whose way the agent cannot change, a hook
    # file is walked too: one with another name in a writable mount can be
    # written through it (review of the GIT-39 fix). One in hooks/ with another
    # name refuses the launch (GIT-31).
    # A core.hooksPath directory is walked once a launch, however many
    # repositories name it, and each of its walks counts in the launch's budget:
    # every way judged safe adds one, and planted repositories naming hundreds,
    # each holding the 28 names as long link chains, took a launch from 1.7 s to
    # 161 s, in silence (third review of the GIT-35 fix). hooks/ is a
    # repository's own, bounded by SANDBOX_GIT_MAX, as before.
    for hwd in ${hwds[@]+"${hwds[@]}"}; do
      [[ -d "$hwd" ]] || continue
      # hooks/ of one outside every writable mount, bound by nothing, is walked as
      # a core.hooksPath directory is: files too, once, counted.
      hx=""; if [[ "$hwd" != "$g/hooks" || -n "${pgx[k]:-}" ]]; then hx=1; fi
      if [[ -n "$hx" ]]; then
        x="$(_launcher_dev_ino "$hwd")" || x="$hwd"
        [[ -z "${hkdone[$x]:-}" ]] || continue
        hkdone[$x]=1
      fi
      for e in "${git_hook_names[@]}"; do
        f="$hwd/$e"
        walk=()
        # Past the budget, only these are skipped: hooks/ is the repository's own,
        # and is walked still (automated security review of fe955c3).
        if [[ -n "$hx" && ( -L "$f" || -f "$f" ) ]] && (( ++ients > 1000 )); then hkcut=1; continue 2; fi
        if [[ -L "$f" ]]; then
          mapfile -d '' -t walk < <(_link_walk "$f")
        elif [[ -n "$hx" && -f "$f" ]]; then
          walk=("=$f")
        else
          continue
        fi
        if ! _walk_exposed how q w "" ${walk[@]+"${walk[@]}"}; then continue; fi
        if [[ "$hwd" == "$g/hooks" ]]; then
          printf 'NOTE: %s/hooks/%s, a hook your host'\''s git runs, is a link the agent can redirect:\n' "$(_term "$at")" "$(_term "$e")" >&2
        else
          printf 'NOTE: %s, a hook your host'\''s git runs for %s (core.hooksPath),\n' "$(_term "$f")" "$(_term "$at")" >&2
          printf '      leads somewhere the agent can change:\n' >&2
        fi
        case "$how" in
          change)  printf '      it can change %s (at %s), which the hook runs.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          linked)  printf '      it can write %s through another name of that file, in %s\n' "$(_term "$q")" "$(_term "$w")" >&2
                   printf '      (on the host, find %s -xdev -samefile %s lists it); the hook runs it.\n' "$(_q "$w")" "$(_q "$q")" >&2 ;;
          unsearched) printf '      %s has another name, and %s could not be searched for it in full.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          repoint) printf '      it can repoint %s (at %s), a link on its way.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          replace) printf '      it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
          unchecked) printf '      its way out was not followed to the end (too many steps or links), so it is not known to be safe.\n' >&2 ;;
        esac
        if [[ -L "$f" ]]; then
          printf '      Check it before a git commit on the host, or replace the link with what it names.\n' >&2
        else
          printf '      Check it before a git commit on the host, or remove its other name.\n' >&2
        fi
      done
    done
    if [[ -n "$hkcut" ]]; then
      printf 'WARNING: not every hook in the hook directories of %s was checked (1000 ways per\n' "$(_q "$at")" >&2
      printf '         launch, with its includes); check them before a git commit on the host.\n' >&2
    fi
  done

  # Symlinks in a launcher whose way out leads somewhere the agent can change.
  # Judged from the container side, now that the overlays are decided: every
  # writable bind that exposes a step on the way is checked, and the step is
  # safe only if each of them puts it under a read-only overlay — or, for a
  # directory a `..` steps out of, makes it a mount point (a mount root, a pin,
  # an overlay root), which cannot be swapped for a link. Scanned: every
  # launcher in play, except one that is itself a writable mount root — it is
  # writable by design, said so with a NOTE, and its links are the agent's to
  # make. Links that sit in a writable bind inside a launcher (an output
  # directory) are the agent's too, so they are not walked; links that point
  # INTO one are. At most 200 links of this launcher, and 200 of all the
  # others between them, so nothing the agent can write makes every later
  # launch slow — it decides how many other launchers there are (T38, T46).
  for x in "${scan[@]}"; do
    inner=""
    for i in ${bsrc[@]+"${!bsrc[@]}"}; do
      if [[ "${bsrc[i]}" == "$x" ]]; then inner=1; break; fi
    done
    if [[ -n "$inner" ]]; then continue; fi
    # Past the shared budget, the rest are only named: planted launchers can
    # use it up before a real one is reached, and that must show.
    if [[ "$x" != "$self" ]] && (( no > 200 )); then unchecked+=("$x"); continue; fi
    nl=0
    links=()
    mapfile -d '' -t links < <(find "$x" -maxdepth 6 \
        \( -type d \( -name node_modules -o -name .git -o -name vendor -o -name .venv -o -name target \) \) -prune \
        -o -type l -print0 2>/dev/null)
    for f in ${links[@]+"${links[@]}"}; do
      inner=""
      for i in ${bsrc[@]+"${!bsrc[@]}"}; do
        if [[ "${bsrc[i]}" == "$x"/* && "$f" == "${bsrc[i]}"/* ]]; then inner=1; break; fi
      done
      if [[ -n "$inner" ]]; then continue; fi
      if [[ "$x" == "$self" ]]; then
        if (( ++nl > 200 )); then
          printf 'NOTE: %s holds more than 200 symlinks; only the first 200 were checked.\n' "$(_term "$x")" >&2
          break
        fi
      elif (( ++no > 200 )); then
        unchecked+=("$x")
        break
      fi
      walk=()
      mapfile -d '' -t walk < <(_link_walk "$f")
      # A step inside this launcher and in no writable bind of its own (an output
      # directory, say) stays home — read-only with the launcher, or the working
      # dir someone is deliberately editing.
      if ! _walk_exposed how q w "$x" ${walk[@]+"${walk[@]}"}; then continue; fi
      printf 'WARNING: launcher link %s leads somewhere the agent can change:\n' "$(_term "$f")" >&2
      case "$how" in
        change)  printf '         it can change %s (at %s), which the host reads through it.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
        linked)  printf '         it can write %s through another name of that file, in %s\n' "$(_term "$q")" "$(_term "$w")" >&2
                 printf '         (on the host, find %s -xdev -samefile %s lists it); the host reads it through the link.\n' "$(_q "$w")" "$(_q "$q")" >&2 ;;
        unsearched) printf '         %s has another name, and %s could not be searched for it in full.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
        repoint) printf '         it can repoint %s (at %s), a link on its way.\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
        replace) printf '         it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$(_term "$q")" "$(_term "$w")" >&2 ;;
        unchecked) printf '         its way out was not followed to the end (too many steps or links), so it is not known to be safe.\n' >&2 ;;
      esac
      printf '         Replace the link with what it names, or mount that directory :ro.\n' >&2
    done
  done
  if (( ${#unchecked[@]} )); then
    printf 'NOTE: the other launchers the writable mounts expose hold more than 200 symlinks between them;\n' >&2
    printf '      not all the links of these were checked:\n' >&2
    for x in "${unchecked[@]}"; do printf '        %s\n' "$(_q "$x")" >&2; done
  fi
  # A read-only bind is a mount on one name. Where a directory ignores case but
  # the kernel does not (WSL's drvfs: _ci_alias_fs), another spelling of that
  # name, or of any directory on its way below the mount root, is a name of its
  # own that no mount covers, and writable: from a container, .git/CONFIG wrote
  # the host's .git/config, .AI-CONTAINERS/sandbox.sh the launcher, and a pinned
  # directory renamed away (measured on Docker Desktop, platform-issues PLAT-8).
  # Where Windows looks the names up (_win_fs), its 8.3 short names are names of
  # their own as well, in a case-sensitive directory too (AI-CON~1/sandbox.sh
  # wrote through a read-only .ai-containers; automated security review of
  # 1ed3de8), and nothing on Linux lists them, so any name there counts.
  # No bind can close that, so every overlay, pin and file bind is checked, and
  # one that can be reached so refuses the launch (bugs review GIT-41).
  local _gw_why _gw_flip
  for ((k = 0; k < ${#_vrfy[@]}; k += 2)); do
    f="${_vrfy[k]}"
    for i in ${bsrc[@]+"${!bsrc[@]}"}; do
      [[ "$f" == "${bsrc[i]}"/* ]] || continue
      p="${bsrc[i]}"; rest="${f#"${bsrc[i]}"/}"
      while [[ -n "$rest" ]]; do
        part="${rest%%/*}"
        if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        _gw_why=""
        if _win_fs "$p"; then _gw_why=win
        elif _ci_name "$p" "$part" && _ci_alias_fs "$p"; then _gw_why=case; fi
        if [[ "$_gw_why" == win ]]; then
          printf 'ERROR: %s is mounted read-only, but %s is on a filesystem where\n' "$(_term "${_vrfy[k+1]}")" "$(_term "$p")" >&2
          printf '       Windows looks names up (WSL'"'"'s drvfs under /mnt/<drive>, or SMB): it also reaches\n' >&2
          printf '       %s by its 8.3 short name, and by any other case where the directory ignores\n' "$(_q "$part")" >&2
          printf '       case, names no mount covers, so the agent could write it (bugs review GIT-41).\n' >&2
          printf '       A case-sensitive directory does not close it. Refusing the launch. Keep the project\n' >&2
          printf '       on a Linux filesystem (in WSL, the distro'"'"'s own, such as ~/dev), or mount it :ro.\n' >&2
          exit 1
        elif [[ "$_gw_why" == case ]]; then
          _case_flip _gw_flip "$part"
          printf 'ERROR: %s is mounted read-only, but %s ignores case\n' "$(_term "${_vrfy[k+1]}")" "$(_term "$p")" >&2
          printf '       and the kernel does not: in it, %s is %s by another name, which no\n' "$(_q "$_gw_flip")" "$(_q "$part")" >&2
          printf '       mount covers, so the agent could write it (bugs review GIT-41). Refusing the launch.\n' >&2
          printf '       Keep the project on a case-sensitive filesystem, or mount it :ro.\n' >&2
          exit 1
        fi
        p="$p/$part"
      done
    done
  done
  # A read-only bind does not make a FIFO read-only: the agent can still open one
  # for writing through it, and feed the host's git, or a launcher the host runs,
  # whatever it reads there — reproduced (reviews of 455fa85 and 56c91c4, HIGH;
  # G65-G67). Any FIFO or device in what is bound read-only refuses the launch,
  # as does a directory there that cannot be searched for one.
  # What stays writable inside an overlay — the agent's output directories — is
  # not searched: nothing on the host reads it, and a FIFO or a mode-000
  # directory the agent left there refused every later launch (review of
  # c687370; T50).
  # Handed back for the search again just before docker runs (LNCH-11).
  launcher_ro_dirs=(${ro_srcs[@]+"${ro_srcs[@]}"}); launcher_rw_srcs=(${bsrc[@]+"${bsrc[@]}"})
  _ro_fifo_search ro_srcs bsrc _ro_links_check
}

# _ro_fifo_search <read-only sources> <writable mount sources> [<link-checked>]:
# refuses the launch if any FIFO or device is in what is bound read-only, or a
# file with a second hard link in a source the third names (GIT-31) — see the end of
# launcher_ro_overlay. Run there, and again just before docker runs: a
# concurrent container with one of those directories writable could make a FIFO
# in between (LNCH-11; T57). Bounded at 30 s, past which the launch is refused
# naming the directory, since the agent decides how many files a planted
# launcher holds (LNCH-10; T56), and 90 s per launch over both runs (T59).
_ro_fifo_search() {
  local -n _fs_src=$1 _fs_rw=$2
  local x i e h fx ferr="" pat frc left fs_lc="" mnt
  local -a prune ft=() hn=() hits=()
  # The third, when given, names the sources also checked for a second hard link.
  if [[ -n "${3:-}" ]]; then local -n _fs_lc=$3; fs_lc=1; fi
  # One budget per launch, over both runs: 30 s a source let planted launchers,
  # each kept just under it, make a launch take hours (review of the batch 10
  # branch; T59). Each search gets what is left, at most 30 s.
  # Less what _fs_linked_in's listings took before it started.
  [[ -n "${_fs_deadline:-}" ]] || _fs_deadline=$((SECONDS + 90 - _fs_ml_spent))
  # Made only when there is something to search, and its error names TMPDIR: a
  # stale one in your shell stopped every launch, unnamed (LNCH-14; T53).
  if (( ${#_fs_src[@]} )); then
    ferr="$(mktemp "${TMPDIR:-/tmp}/ai-launcher-find.XXXXXX" 2>/dev/null)" || {
      printf 'ERROR: cannot make a temporary file in %s (TMPDIR); set TMPDIR to a writable directory.\n' "$(_q "${TMPDIR:-/tmp}")" >&2
      exit 1
    }
  fi
  for x in ${_fs_src[@]+"${_fs_src[@]}"}; do
    fx=""
    if [[ -p "$x" || -b "$x" || -c "$x" ]]; then fx="$x"
    elif [[ -d "$x" ]]; then
      # One you cannot search (chmod 000) hides nothing your host's git can read.
      [[ -x "$x" ]] || continue
      left=$((_fs_deadline - SECONDS))
      if (( left <= 0 )); then
        printf 'ERROR: the search for FIFOs in what this launch binds read-only ran past its 90 s budget,\n' >&2
        printf '       at %s; refusing the launch. Something there holds very many files:\n' "$(_term "$x")" >&2
        printf '       mount narrower directories, or mount them :ro.\n' >&2
        rm -f "$ferr"; exit 1
      fi
      (( left <= 30 )) || left=30
      read -r -a ft <<< "$(_timeout_prefix "$left") "
      prune=()
      for i in ${_fs_rw[@]+"${!_fs_rw[@]}"}; do
        [[ "${_fs_rw[i]}" == "$x"/* ]] || continue
        # find -path takes a pattern: its metacharacters are escaped.
        pat="${_fs_rw[i]//\\/\\\\}"; pat="${pat//\*/\\*}"; pat="${pat//\?/\\?}"; pat="${pat//\[/\\[}"
        prune+=(-path "$pat" -o)
      done
      # From /: find fails where the launch's working directory cannot be searched (T45).
      # Nothing of a git directory is skipped: git reads objects/info/alternates
      # and the packs (automated security review of f1817ce); the 30 s bound is
      # what keeps the search short.
      frc=0
      if (( ${#prune[@]} )); then
        unset 'prune[${#prune[@]}-1]'
        fx="$(cd / && "${ft[@]}" find "$x" \( "${prune[@]}" \) -prune -o \( -type p -o -type b -o -type c \) -print -quit 2>"$ferr")" || frc=$?
      else
        fx="$(cd / && "${ft[@]}" find "$x" \( -type p -o -type b -o -type c \) -print -quit 2>"$ferr")" || frc=$?
      fi
      if (( frc == 124 || frc == 137 )); then
        printf 'ERROR: %s, bound read-only, could not be searched for FIFOs within %s s; refusing the launch.\n' "$(_term "$x")" "$left" >&2
        printf '       Something there holds very many files: mount narrower directories, or mount it :ro.\n' >&2
        rm -f "$ferr"; exit 1
      fi
      (( frc == 0 )) || {
        printf 'ERROR: %s, bound read-only, cannot be searched for FIFOs; refusing the launch:\n' "$(_term "$x")" >&2
        printf '       %s\n' "$(_term "$(head -c 512 "$ferr" | head -n 1)")" >&2
        rm -f "$ferr"; exit 1
      }
    fi
    [[ -n "$fx" ]] || continue
    printf 'ERROR: %s is a FIFO or device inside what this launch binds read-only; refusing the launch.\n' "$(_term "$fx")" >&2
    printf '       The agent could still write into it, and what reads it on the host would get that.\n' >&2
    printf '       Remove it on the host (rm %s).\n' "$(_q "$fx")" >&2
    rm -f "$ferr"; exit 1
  done
  rm -f "$ferr"
  # A file git reads by name with a second name: a read-only bind protects a
  # path, not the file behind it, so a hard link made before the first
  # protection still writes it (GIT-31). link() into a read-only bind fails
  # (EXDEV), so the container cannot make one later. In hooks/, only the names
  # git runs: a deduplicating tool links .sample hooks across repositories, and
  # git never runs one. A link is followed, and counts only when it leads into a
  # writable mount: the Nix store links every file it holds (reviews of the
  # GIT-31 fix).
  [[ -n "$fs_lc" ]] || return 0
  # -iname: where case is ignored git runs hooks/PRE-COMMIT as pre-commit (third
  # review of the GIT-38 fix).
  for e in "${git_hook_names[@]}"; do hn+=(-o -iname "$e"); done
  hn=("${hn[@]:1}")
  local -a lf=() ld=()
  for x in ${_fs_lc[@]+"${!_fs_lc[@]}"}; do
    case "${_fs_lc[$x]}" in
      file) lf+=("$x") ;;
      hooks) if [[ -d "$x" ]]; then ld+=("$x"); fi ;;
    esac
  done
  # One find for the files, one for the hooks/ directories (a find each cost a
  # launch of 150 repositories most of a second, twice), within the search's
  # budget; one that runs out of time refuses, as the FIFO search does. Any other
  # failure is a link that leads nowhere, which the post-pass names.
  hits=()
  for e in file hooks; do
    if [[ "$e" == file ]]; then (( ${#lf[@]} )) || continue; else (( ${#ld[@]} )) || continue; fi
    left=$((_fs_deadline - SECONDS)); (( left > 0 )) || left=1; (( left <= 30 )) || left=30
    read -r -a ft <<< "$(_timeout_prefix "$left") "
    frc=0; x="$(mktemp "${TMPDIR:-/tmp}/ai-launcher-links.XXXXXX" 2>/dev/null)" || {
      printf 'ERROR: cannot make a temporary file in %s (TMPDIR); set TMPDIR to a writable directory.\n' "$(_q "${TMPDIR:-/tmp}")" >&2
      exit 1
    }
    if [[ "$e" == file ]]; then
      (cd / && "${ft[@]}" find -L "${lf[@]}" -prune -type f -links +1 -print0 > "$x" 2>/dev/null) || frc=$?
    else
      (cd / && "${ft[@]}" find -L "${ld[@]}" -mindepth 1 -maxdepth 1 \( "${hn[@]}" \) -type f -links +1 -print0 > "$x" 2>/dev/null) || frc=$?
    fi
    if (( frc == 124 || frc == 137 )); then
      rm -f "$x"
      printf 'ERROR: the files your host'\''s git reads by name could not be checked for hard links within\n' >&2
      printf '       %s s; refusing the launch. Something there holds very many files: mount narrower\n' "$left" >&2
      printf '       directories, or mount them :ro.\n' >&2
      exit 1
    fi
    mapfile -d '' -t -O "${#hits[@]}" hits < "$x"; rm -f "$x"
  done
  _fs_other_names hits
  for h in ${hits[@]+"${hits[@]}"}; do
    _fs_reachable "$h" || continue
    # Found, not copied over: a copy wrote through a link the agent could plant
    # beside it, into a file of yours. The other name is most likely in the
    # same mount, where the agent could make it; one made on the host need not be.
    mnt="${h%/*}"
    for i in ${_fs_rw[@]+"${!_fs_rw[@]}"}; do
      if [[ "$h" == "${_fs_rw[i]}"/* && ${#_fs_rw[i]} -lt ${#mnt} ]]; then mnt="${_fs_rw[i]}"; fi
    done
    printf 'ERROR: %s has more than one hard link, and your host'\''s git reads it; refusing the launch.\n' "$(_term "$h")" >&2
    printf '       A read-only bind protects a path, not the file: the agent can still write it through\n' >&2
    printf '       another name. On the host,\n' >&2
    printf '         find %s%s -xdev -samefile %s\n' "$([[ -L "$h" ]] && printf -- '-L ')" "$(_q "$mnt")" "$(_q "$h")" >&2
    printf '       lists its names. Copy apart one that is another repository'\''s own; remove one you did not make.\n' >&2
    exit 1
  done
}

# Files with a second name reached through a link out of every writable mount,
# by device:inode: 1 when another name of it lies in a writable mount, or could
# not be ruled out; 0 when none does. Kept over both runs of _ro_fifo_search.
declare -A _fs_reach_cache=()
# _fs_other_names <hits-var>: called from _ro_fifo_search, for the files git
# reads with a second hard link. Fills _fs_reach_cache for each one reached
# through a link that leads out of every writable mount (_fs_rw) — the Nix store
# links every file it holds — from _fs_linked_in's listing of each writable
# mount on its device. Where the target lay decided it before, and a name an
# earlier session made in a wider mount went unseen (automated security review
# of the GIT-31 fix); a search per hook let the agent make every launch take
# hours, and a search that failed on a directory it cannot read was taken for
# "no other name" (review, and automated security review, of the GIT-36/37
# fix). It fails closed.
_fs_other_names() {
  local -n _fo_hits=$1
  local h t di r rc
  for h in ${_fo_hits[@]+"${_fo_hits[@]}"}; do
    [[ -L "$h" ]] || continue
    t="$(_fs_target "$h")"
    [[ -n "$t" ]] || continue
    _fs_in_rw "$t" && continue
    di="$(_launcher_dev_ino "$t")" || continue
    [[ -z "${_fs_reach_cache[$di]:-}" ]] || continue
    rc=0; _fs_linked_in "$di" _fs_rw r || rc=$?
    if (( rc == 1 )); then _fs_reach_cache[$di]=0; else _fs_reach_cache[$di]=1; fi
  done
}
# For _fs_linked_in, kept for the launch: each writable mount's device; the file
# listing its files with a second hard link, one "<dev> <ino>" line each, and
# whether that listing was cut short; and the answer for each file asked about
# ("<rc> <mount>", by "<dev> <ino>"). The listings take at most 60 s before the
# FIFO search starts its 90 s clock, which then counts only the time they took
# (review of the GIT-39 fix: started at the first listing, the clock counted the
# walks between them, and refused launches that had passed). They hold at most
# 64 MiB in all, and at most 256 files are asked about.
declare -A _fs_ml_dev=() _fs_ml_file=() _fs_ml_cut=() _fs_ml_ans=()
_fs_ml_dir="" _fs_ml_spent=0 _fs_ml_bytes=67108864 _fs_ml_asked=0
# _fs_linked_in <dev ino> <mounts-var> <out-var>: for a file with a second hard
# link that lies in no writable mount — one git reads or runs, or a launcher
# link leads to. Returns 0 when another name of it lies in one of <mounts>,
# setting <out-var> to that mount; 2 when that cannot be ruled out (a listing
# failed, ran out of time or space, or too many files were asked about),
# setting <out-var> to a mount it may lie in; 1 when none holds one. A hard link
# never leaves its device, so only the mounts on its device are listed: each
# once per launch, whatever number of files is asked about (a search per file
# let planted configs make a launch take hours; review of the GIT-36/37 fix),
# and looked up with one grep, not loaded into the shell, whose memory and time
# the agent could fill with names. Shared by the hook, include and launcher link
# checks (_walk_exposed) and the hard-link refusal (_fs_other_names).
_fs_linked_in() {
  local -n _fl_m=$2 _fl_o=$3
  local _fl_di="$1" _fl_k _fl_x _fl_f _fl_left _fl_rc _fl_t0 _fl_sz _fl_hit="" _fl_bad=""
  local -a _fl_t=() _fl_s=() _fl_on=() _fl_fs=() _fl_p=()
  _fl_o=""
  _fl_x="${_fs_ml_ans[$_fl_di]:-}"
  if [[ -n "$_fl_x" ]]; then _fl_o="${_fl_x#* }"; return "${_fl_x%% *}"; fi
  for _fl_k in ${_fl_m[@]+"${_fl_m[@]}"}; do
    if [[ -z "${_fs_ml_dev[$_fl_k]+x}" ]]; then
      _fl_x="$(_launcher_dev_ino "$_fl_k")" || _fl_x=""
      _fs_ml_dev[$_fl_k]="${_fl_x%% *}"
    fi
    if [[ -n "${_fs_ml_dev[$_fl_k]}" && "${_fs_ml_dev[$_fl_k]}" == "${_fl_di%% *}" ]]; then _fl_on+=("$_fl_k"); fi
  done
  if (( ! ${#_fl_on[@]} )); then _fs_ml_ans[$_fl_di]="1 "; return 1; fi
  if (( ++_fs_ml_asked > 256 )); then
    _fl_o="${_fl_on[0]}"; _fs_ml_ans[$_fl_di]="2 $_fl_o"; return 2
  fi
  if (( _launcher_stat_gnu )); then _fl_s=(-c '%d %i'); else _fl_s=(-f '%d %i'); fi
  for _fl_k in "${_fl_on[@]}"; do
    if [[ -z "${_fs_ml_file[$_fl_k]:-}" ]]; then
      if [[ -z "$_fs_ml_dir" ]]; then
        _fs_ml_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-launcher-names.XXXXXX" 2>/dev/null)" || {
          _fs_ml_dir=""
          printf 'ERROR: cannot make a temporary directory in %s (TMPDIR); set TMPDIR to a writable directory.\n' "$(_q "${TMPDIR:-/tmp}")" >&2
          exit 1
        }
      fi
      _fl_f="$_fs_ml_dir/${#_fs_ml_file[@]}"
      # Once the FIFO search's clock runs, at least 1 s, as its own searches get.
      if [[ -n "${_fs_deadline:-}" ]]; then
        _fl_left=$((_fs_deadline - SECONDS)); (( _fl_left > 0 )) || _fl_left=1
      else
        _fl_left=$((60 - _fs_ml_spent))
      fi
      _fl_rc=0
      if (( _fl_left <= 0 )); then
        # The 60 s are spent: not listed, so nothing in it is ruled out.
        { : > "$_fl_f"; } 2>/dev/null || true
        _fl_rc=1
      else
        (( _fl_left <= 30 )) || _fl_left=30
        read -r -a _fl_t <<< "$(_timeout_prefix "$_fl_left") "
        _fl_t0=$SECONDS
        # Each side's status, whether or not pipefail is on: a find that failed
        # or ran out of time, or a head that ran out of space, cuts it short.
        (cd / || exit 1
         "${_fl_t[@]}" find "$_fl_k" -xdev -type f -links +1 -exec stat "${_fl_s[@]}" {} + 2>/dev/null | head -c "$_fs_ml_bytes" > "$_fl_f"
         _fl_p=("${PIPESTATUS[@]}"); (( _fl_p[0] == 0 && _fl_p[1] == 0 ))) || _fl_rc=$?
        [[ -n "${_fs_deadline:-}" ]] || _fs_ml_spent=$((_fs_ml_spent + SECONDS - _fl_t0))
      fi
      _fl_sz="$(wc -c < "$_fl_f" 2>/dev/null)" || _fl_sz=""
      [[ "$_fl_sz" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || { _fl_sz=0; _fl_rc=1; }
      _fs_ml_bytes=$((_fs_ml_bytes - _fl_sz))
      if (( _fs_ml_bytes <= 0 )); then _fs_ml_bytes=0; _fl_rc=1; fi
      # A last line cut short is no file's: it could match a shorter inode number.
      if (( _fl_rc != 0 )) && [[ -s "$_fl_f" && -n "$(tail -c 1 "$_fl_f" 2>/dev/null)" ]]; then
        { sed '$d' "$_fl_f" > "$_fl_f.t" && mv -f "$_fl_f.t" "$_fl_f"; } 2>/dev/null || { : > "$_fl_f"; } 2>/dev/null || true
      fi
      _fs_ml_file[$_fl_k]="$_fl_f"
      if (( _fl_rc != 0 )); then _fs_ml_cut[$_fl_k]=1; fi
    fi
    _fl_fs+=("${_fs_ml_file[$_fl_k]}")
    if [[ -n "${_fs_ml_cut[$_fl_k]:-}" && -z "$_fl_bad" ]]; then _fl_bad="$_fl_k"; fi
  done
  # One grep over every listing on the device; the first file it names is the mount.
  _fl_x="$(grep -l -x -F -- "$_fl_di" "${_fl_fs[@]}" 2>/dev/null | head -n 1)" || true
  if [[ -n "$_fl_x" ]]; then
    for _fl_k in "${_fl_on[@]}"; do
      if [[ "${_fs_ml_file[$_fl_k]}" == "$_fl_x" ]]; then _fl_hit="$_fl_k"; break; fi
    done
  fi
  if [[ -n "$_fl_hit" ]]; then _fl_o="$_fl_hit"; _fs_ml_ans[$_fl_di]="0 $_fl_o"; return 0; fi
  if [[ -n "$_fl_bad" ]]; then _fl_o="$_fl_bad"; _fs_ml_ans[$_fl_di]="2 $_fl_o"; return 2; fi
  _fs_ml_ans[$_fl_di]="1 "
  return 1
}
# _fs_ml_drop: the listings, done with once the FIFO search has run before
# docker, are not kept in TMPDIR (often memory) for the session: the agent can
# fill them with up to 64 MiB of names (re-review of the GIT-39 fix). A later
# question lists again, past the deadline, so it fails closed.
_fs_ml_drop() {
  if [[ -n "$_fs_ml_dir" ]]; then rm -rf "$_fs_ml_dir" 2>/dev/null || true; fi
  _fs_ml_dir=""; _fs_ml_file=(); _fs_ml_cut=()
}
# _fs_target <link>: where a link's way ends (_link_walk), or nothing.
_fs_target() {
  local -a w=()
  local i t=""
  mapfile -d '' -t w < <(_link_walk "$1")
  for i in ${w[@]+"${w[@]}"}; do [[ "$i" != =* ]] || t="${i#=}"; done
  printf '%s' "$t"
}
# _fs_in_rw <path>: inside one of _ro_fifo_search's writable mounts.
_fs_in_rw() {
  local i
  for i in ${_fs_rw[@]+"${_fs_rw[@]}"}; do
    if [[ "$1" == "$i" || "$1" == "$i"/* ]]; then return 0; fi
  done
  return 1
}
# _fs_reachable <path>: called from _ro_fifo_search, for a file git reads with a
# second hard link. Succeeds when the agent could reach a name of it: always,
# unless <path> is a link whose way ends outside every writable mount; then as
# _fs_other_names found, or could not rule out.
_fs_reachable() {
  local t di
  [[ -L "$1" ]] || return 0
  t="$(_fs_target "$1")"
  [[ -n "$t" ]] || return 0
  _fs_in_rw "$t" && return 0
  di="$(_launcher_dev_ino "$t")" || return 0
  [[ "${_fs_reach_cache[$di]:-1}" != 0 ]]
}

# _walk_exposed <how-var> <step-var> <at-var> <home> <step>...: called from
# launcher_ro_overlay, once its overlays are decided — it reads that function's
# bsrc, bdst, ro_dsts and pinned. Given a walk (_link_walk, _path_walk), succeeds
# at the first step the agent can change from inside the container, judged
# through every writable bind that exposes it: a step is safe only if each of
# them puts it under a read-only overlay or — for a directory a `..` steps out
# of — makes it a mount point (a mount root, a pin, an overlay root), which
# cannot be swapped for a link. Sets how (change, repoint or replace), the
# step's host path, and where the agent sees it; or, for a file in no writable
# mount with another name in one (linked) or one not ruled out (unsearched),
# the host path of that mount (_fs_linked_in). A step inside <home> and in no
# writable bind of <home>'s own is not judged. Its own names are prefixed, so
# none can shadow a variable the caller names.
_walk_exposed() {
  local -n _we_how=$1 _we_step=$2 _we_at=$3
  local _we_home="$4" _we_e _we_h _we_q _we_c _we_r _we_safe _we_in _we_j _we_d _we_rc
  shift 4
  for _we_e in "$@"; do
    case "$_we_e" in
      \?*) _we_how=unchecked; _we_step="${_we_e#\?}"; _we_at="$_we_step"; return 0 ;;
      # Spelled as on disk, here in the launcher's own shell, where each directory
      # is read once: a link's target written in another case leads to the same
      # place, and is judged against mounts by its prefix (GIT-38).
      =*) _we_h=change;  _we_q="${_we_e#=}"; _spell_rec _we_q
          # With a second name it can be changed through that one, under a
          # read-only overlay too — where the agent could make one: in a writable
          # mount (review of the GIT-31 fix).
          if [[ -f "$_we_q" && -n "$(cd / && find "$_we_q" -prune -type f -links +1 -print 2>/dev/null)" ]]; then
            for _we_j in ${bsrc[@]+"${!bsrc[@]}"}; do
              if [[ "$_we_q" == "${bsrc[_we_j]}" || "$_we_q" == "${bsrc[_we_j]}"/* ]]; then
                _we_how=change; _we_step="$_we_q"; _we_at="${bdst[_we_j]}${_we_q#"${bsrc[_we_j]}"}"; return 0
              fi
            done
            # In no writable mount, through a name that lies in one: made by an
            # earlier session with a wider mount, or by a tool that deduplicates
            # files. One not ruled out counts (bugs review GIT-39).
            # One whose device cannot be read is not ruled out either, as
            # _fs_reachable takes it (re-review of the GIT-39 fix).
            _we_rc=2; _we_j="its writable mounts"
            if _we_d="$(_launcher_dev_ino "$_we_q")"; then
              _we_rc=0; _fs_linked_in "$_we_d" bsrc _we_j || _we_rc=$?
            fi
            if (( _we_rc != 1 )); then
              if (( _we_rc == 0 )); then _we_how=linked; else _we_how=unsearched; fi
              _we_step="$_we_q"; _we_at="$_we_j"; return 0
            fi
          fi ;;
      ^*) _we_h=replace; _we_q="${_we_e#^}"; _spell_rec _we_q ;;
      *)  _we_h=repoint; _we_q="$_we_e"; _spell_rec _we_q ;;
    esac
    if [[ -n "$_we_home" && ( "$_we_q" == "$_we_home" || "$_we_q" == "$_we_home"/* ) ]]; then
      _we_in=""
      for _we_j in ${bsrc[@]+"${!bsrc[@]}"}; do
        if [[ "${bsrc[_we_j]}" == "$_we_home"/* && ( "$_we_q" == "${bsrc[_we_j]}" || "$_we_q" == "${bsrc[_we_j]}"/* ) ]]; then _we_in=1; break; fi
      done
      if [[ -z "$_we_in" ]]; then continue; fi
    fi
    for _we_j in ${bsrc[@]+"${!bsrc[@]}"}; do
      if [[ "$_we_q" != "${bsrc[_we_j]}" && "$_we_q" != "${bsrc[_we_j]}"/* ]]; then continue; fi
      _we_c="${bdst[_we_j]}${_we_q#"${bsrc[_we_j]}"}"
      _we_safe=""
      for _we_r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$_we_c" == "$_we_r" || "$_we_c" == "$_we_r"/* ]]; then _we_safe=1; break; fi
      done
      if [[ -z "$_we_safe" && "$_we_h" == replace ]]; then
        if [[ -n "${pinned[$_we_c]:-}" ]]; then _we_safe=1; fi
        for _we_r in "${bdst[@]}"; do
          if [[ "$_we_c" == "$_we_r" ]]; then _we_safe=1; break; fi
        done
      fi
      if [[ -z "$_we_safe" ]]; then
        _we_how="$_we_h"; _we_step="$_we_q"; _we_at="$_we_c"
        return 0
      fi
    done
  done
  return 1
}

# _bind_mount_arg <flag-var> <value-var> <source> <destination> <rw|ro>: how to
# hand docker one bind. `-v` carries any name docker accepts except one with a
# ':' (its separator) — trailing whitespace, tabs, newlines, commas and quotes
# included; a name with a ':' goes through `--mount` instead, whose value docker
# reads as a CSV record, so each field is quoted and any '"' doubled.
_bind_mount_arg() {
  local s="source=$3" d="destination=$4" o=""
  if [[ "$3$4" != *:* ]]; then
    printf -v "$1" '%s' -v
    printf -v "$2" '%s:%s:%s' "$3" "$4" "$5"
  else
    if [[ "$5" == ro ]]; then o=",readonly"; fi
    printf -v "$1" '%s' --mount
    printf -v "$2" 'type=bind,"%s","%s"%s' "${s//\"/\"\"}" "${d//\"/\"\"}" "$o"
  fi
}

# _mount_representable <source> <destination>: can _bind_mount_arg hand docker
# this pair so that it arrives byte for byte? Not when a name is not valid UTF-8
# (_utf8_valid): the CLI rewrites it to U+FFFD, the bind then names a path that
# does not exist, and Docker Desktop CREATES that path, root-owned, inside the
# host directory. And not, through `--mount`, a value ending in whitespace
# (docker refuses it — Go's unicode.IsSpace, so NBSP and U+3000 too) or holding
# a CR (its CSV reader folds CRLF to LF).
# _overlay_buildable <launcher> <its destination> <mount source> <mount destination>:
# can docker be handed the overlay and every pin between the mount root and it,
# intact? One test for the overlay loop and for SANDBOX_LAUNCHER_MAX's count, so
# the count cannot credit an overlay the loop will not make.
# _term <text>: text a scan found — a name the agent chose — made safe to print on
# the host's terminal: control characters become `?`, so an ESC ] 0 ; … BEL cannot
# retitle the window or cursor moves rewrite the warnings around it (bugs review
# LNCH-3). C0 and DEL, the C1 controls as UTF-8 encodes them (U+009B is a CSI to
# many terminals), and the bidi overrides and isolates that can make a warning
# read as something else (security review of 7b23d2e). Bytes, not a locale's
# classes, so it is the same everywhere; any other non-ASCII name stays readable,
# unlike %q — a raw 0x80-0x9F byte is also a UTF-8 continuation byte, so a lone
# one is left (a UTF-8 terminal does not take it for a control).
_term() {
  local LC_ALL=C s="$1"
  s="${s//[[:cntrl:]]/?}"
  s="${s//$'\xc2'[$'\x80'-$'\x9f']/?}"
  s="${s//$'\xe2\x80'[$'\xaa'-$'\xae']/?}"
  s="${s//$'\xe2\x81'[$'\xa6'-$'\xa9']/?}"
  printf '%s' "$s"
}

# _agent_could_write <dir> <agent uid> <agent gid>: whether the agent may have
# written into a directory the launcher can search but not list, so that what is
# inside (a FIFO, a repository) cannot be trusted unseen. Only the directory's own
# mode is judged; a writable directory inside another user's is not seen
# (LNCH-7). It could if the agent owns it, or its group (the agent's) or the
# other bits give write and search; if it is yours (LNCH-5: a file share that
# remaps ownership, as Docker Desktop and Colima do, shows what the agent made as
# yours, and you can always fix your own); or if it may carry an ACL, whose
# entries are not read: plain only when ls shows the bare mode, or GNU's
# SELinux-context '.' after it — a +, macOS's @ (it hides a +), anything else, or
# an ls that fails counts as one (automated security reviews of 63503a9, 64f8841).
_agent_could_write() {
  [[ -O "$1" ]] || _agent_bits_writable "$@"
}
# _agent_bits_writable <dir> <agent uid> <agent gid>: the mode and ACL half of it,
# apart from yours, so each can be tested on its own (T25g).
_agent_bits_writable() {
  local m a uu=0
  # An ACL entry can grant the agent write access whatever the mode says. getfacl,
  # where there is one, lists them: any beyond user::, group::, other:: and
  # mask:: counts, and a getfacl that fails counts too. Without it, only the +
  # that GNU's, BSD's and uutils' ls print is there to go by: busybox prints
  # none, so any other ls counts as one that saw an ACL (LNCH-6; T25g). uutils is
  # the default ls of recent Ubuntu releases (26.04: 0.10.0, measured with
  # setfacl: `d-wx-wx--x+`, plain `d-wx--x--x`); left out, every unlistable
  # directory there counted as agent-writable (LNCH-21; T25i). Its + marks any
  # extended attribute, an ACL included, so it can only over-report — but its
  # `.` for a security context takes the place of the +, where GNU's keeps the +,
  # so from uutils only the bare mode is plain.
  if command -v getfacl >/dev/null 2>&1; then
    a="$(cd / && getfacl -c -- "$1" 2>/dev/null)" || return 0
    while IFS= read -r m; do
      case "$m" in ''|user::*|group::*|other::*|mask::*) ;; *) return 0 ;; esac
    done <<< "$a"
  else
    case "$(uname -s 2>/dev/null)" in
      Darwin|*BSD|DragonFly) ;;
      *) case "$(cd / && ls --version 2>/dev/null)" in
           *"GNU coreutils"*) ;;
           # 0.1.0 or later: the release that first prints this name came after
           # ACL marking (0.0.24); a build naming itself so with an older number
           # is not taken at its word (automated security review of LNCH-21).
           *"(uutils coreutils) "[1-9]*|*"(uutils coreutils) 0."[1-9]*) uu=1 ;;
           *) return 0 ;;
         esac ;;
    esac
  fi
  m="$(cd / && LC_ALL=C ls -ld "$1" 2>/dev/null)" || m=""; m="${m%% *}"
  if (( uu )); then [[ "$m" =~ ^d[-rwxsStT]{9}$ ]] || return 0
  else [[ "$m" =~ ^d[-rwxsStT]{9}\.?$ ]] || return 0; fi
  [[ -n "$(cd / && find "$1" -maxdepth 0 \( -user "$2" -o \( -group "$3" -perm -0030 \) -o -perm -0003 \) -print 2>/dev/null)" ]]
}

# _unlistable_hint <dir> <indent> <agent uid>: how to make a directory listable —
# chmod it if it is yours, chown or sudo it back if the sandbox identity you chose
# owns it (LNCH-12), otherwise ask its owner (GIT-14).
_unlistable_hint() {
  if [[ -O "$1" ]]; then
    printf '%sRestore: chmod u+rx %s\n' "$2" "$(_q "$1")" >&2
  elif [[ -n "$(cd / && find "$1" -maxdepth 0 -user "$3" -print 2>/dev/null)" ]]; then
    printf '%sIt belongs to the sandbox identity (SANDBOX_UID=%s): sudo chmod u+rx %s, or chown it back.\n' "$2" "$3" "$(_q "$1")" >&2
  else
    printf '%sIt is not yours: ask its owner to make it listable, or leave it out of the writable mounts.\n' "$2" >&2
  fi
}

# _q <name>: a name quoted for the shell, as %q quotes it, safe to show and to
# paste. glibc counts the bidi overrides printable, and %q passed them to the
# terminal (LNCH-8; T52); replacing them with `?`, as _term does, made a pasted
# `rm` a glob (automated security review of f999f25). A name %q cannot render
# for the terminal is written as $'…' with every byte past the plainest ASCII
# as \xHH, which bash turns back into exactly that name.
_q() {
  local qs qi qc qo="" LC_ALL=C
  qs="$(printf '%q' "$1")"
  if [[ "$(_term "$qs")" == "$qs" ]]; then printf '%s' "$qs"; return 0; fi
  for (( qi = 0; qi < ${#1}; qi++ )); do
    qc="${1:qi:1}"
    case "$qc" in
      [A-Za-z0-9/._+,:@%=-]) qo+="$qc" ;;
      *) qo+="$(printf '\\x%02x' "'$qc")" ;;
    esac
  done
  printf "\$'%s'" "$qo"
}

_overlay_buildable() {
  local rest path pin
  _mount_representable "$1" "$2" || return 1
  rest="${1#"$3"/}"; path="$3"; pin="$4"
  while [[ "$rest" == */* ]]; do
    path="$path/${rest%%/*}"; pin="$pin/${rest%%/*}"; rest="${rest#*/}"
    _mount_representable "$path" "$pin" || return 1
  done
  return 0
}

_mount_representable() {
  local v w
  for v in "$1" "$2"; do
    if ! _utf8_valid "$v"; then return 1; fi
  done
  if [[ "$1$2" != *:* ]]; then return 0; fi
  for v in "$1" "$2"; do
    if [[ "$v" == *$'\r'* || "$v" == *[[:space:]] ]]; then return 1; fi
    for w in $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80' $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' \
             $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' \
             $'\xe2\x80\x89' $'\xe2\x80\x8a' $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' \
             $'\xe3\x80\x80'; do
      if [[ "$v" == *"$w" ]]; then return 1; fi
    done
  done
  return 0
}

# _link_walk <link>: resolves <link> the way the kernel does — one component at
# a time, from a physical directory, so `..` steps out of where a link really
# led rather than where its text pointed — and prints, NUL-separated, every
# symlink met (its physical path; <link> first), "^" and every directory a `..`
# steps out of (swap it for a link and the way changes), then "=" and the final
# path, which need not exist. Stops quietly after 40 links (a loop).
_link_walk() {
  local cur c t
  _cd_bash cur "${1%/*}/" || return 0
  c="${1##*/}"
  printf '%s\0' "$cur/$c"
  _readlink_exact t "$cur/$c" || return 0
  _path_walk "$cur" "$t" 1
}

# _path_walk <physical dir> <path> [<links met so far>]: the walk of <path> from
# <physical dir>, printed as _link_walk prints it — for a path that is not a
# link's target, such as a file a git config includes.
_path_walk() {
  local cur="$1" rest c t n="${3:-0}" steps=0
  if [[ "$2" == /* ]]; then cur=""; rest="${2#/}"; else rest="$2"; fi
  while [[ -n "$rest" ]]; do
    # One budget for every step, however it arrives: each link splices its target
    # in, so a short value through 40 links of `./././…` cost 14 s (review of batch
    # 9, finding 2). Cut short — here, or past 40 links — the walk ends `?<where>`,
    # which _walk_exposed takes for a step the agent can change: a way not
    # followed to the end is not known to be safe.
    if (( ++steps > 256 )); then printf '?%s\0' "${cur:-/}"; return 0; fi
    c="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "$c" in
      ''|.) continue ;;
      ..) if [[ -n "$cur" ]]; then printf '^%s\0' "$cur"; fi; cur="${cur%/*}"; continue ;;
    esac
    if [[ -L "$cur/$c" ]]; then
      if (( ++n > 40 )); then printf '?%s\0' "$cur/$c"; return 0; fi
      printf '%s\0' "$cur/$c"
      _readlink_exact t "$cur/$c" || return 0
      if [[ "$t" == /* ]]; then cur=""; rest="${t#/}${rest:+/$rest}"; else rest="$t${rest:+/$rest}"; fi
    else
      cur="$cur/$c"
    fi
  done
  printf '=%s\0' "${cur:-/}"
}

# _readlink_exact <var> <link>: a link's target, byte for byte — $(readlink)
# alone would drop any trailing newlines the target itself ends with. -n, not
# stripping one newline after the fact: macOS readlink adds its newline only
# when the target does not already end in one, so stripping ate the target's.
_readlink_exact() {
  local out
  out="$(readlink -n -- "$2" && printf x)" || return 1
  printf -v "$1" '%s' "${out%x}"
}

# _utf8_valid <string>: is it UTF-8 as RFC 3629 — and Go, whose JSON encoding of
# the request is what rewrites anything else — defines it? No overlongs, no
# surrogates, nothing above U+10FFFF. Not iconv: glibc's accepts both F4 90 80 80
# (above U+10FFFF) and five-byte forms, which Go rejects. Bytes are read as
# decimal numbers, so neither the locale nor the awk in use can change the answer.
_utf8_valid() {
  # ASCII is valid UTF-8, decided in bash: the pipeline below costs two processes,
  # and the launcher asks this of every launcher it counts (review of batch 9).
  local LC_ALL=C
  [[ "$1" != *[$'\x80'-$'\xff']* ]] && return 0
  printf '%s' "$1" | od -An -v -tu1 | awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
    END {
      i = 0
      while (i < n) {
        c = b[i]
        if (c < 128) { i++; continue }
        if (c >= 194 && c <= 223)                              { k = 1; lo = 128; hi = 191 }
        else if (c == 224)                                     { k = 2; lo = 160; hi = 191 }
        else if (c >= 225 && c <= 236 || c == 238 || c == 239) { k = 2; lo = 128; hi = 191 }
        else if (c == 237)                                     { k = 2; lo = 128; hi = 159 }
        else if (c == 240)                                     { k = 3; lo = 144; hi = 191 }
        else if (c >= 241 && c <= 243)                         { k = 3; lo = 128; hi = 191 }
        else if (c == 244)                                     { k = 3; lo = 128; hi = 143 }
        else exit 1
        if (i + k >= n) exit 1
        if (b[i + 1] < lo || b[i + 1] > hi) exit 1
        for (j = 2; j <= k; j++) if (b[i + j] < 128 || b[i + j] > 191) exit 1
        i += k + 1
      }
      exit 0
    }'
}

# container_env_filter <file> <lines-out> <keys-out> <docker run args>...: the lines of
# container.env that may go to the container, as env-file lines, and the names they set.
#
# container.env is the project's APPLICATION environment (DB_HOST, POSTGRES_*), and
# whoever can commit to the project writes it. `docker run --env-file` hands it to the
# ROOT entrypoint, where XTABLES_LIBDIR chooses the plugins iptables loads and
# ALLOWLIST_CIDRS_FILE the firewall's own allowlist — and every tool root runs reads
# keys of its own, so no deny-list closes that. The entrypoint therefore sets every key
# named in AI_CONTAINER_ENV_KEYS aside before it reads anything, and hands them back
# only to processes that run as the sandbox user (entrypoint.sh: stash_app_env()). What
# is left for this side, each refused with a WARNING naming the line (never the value)
# while the launch goes on:
#   - what acts before the entrypoint's first line can: the loader, env(1)'s PATH search
#     for the `#!/usr/bin/env bash` interpreter, bash's own start-up — env_key_denied;
#   - what the entrypoint could not set aside, or give back unchanged: a name that is not
#     a shell variable (bash passes `a.b=1` on and cannot unset it), bash's own variables,
#     HOME/USER/LOGNAME (the container sets them for the sandbox user), and a key this
#     launch passes with -e (setting it aside would unset the launcher's value) — read
#     from the docker run arguments themselves, so it cannot drift from them;
#   - knobs only root reads (SELF_HEALING_ENABLED, ALLOW_IPV6_BYPASS, the allowlist
#     and capture settings): from here they would silently do nothing, so the
#     warning says so, and where the two user-facing ones belong;
#   - the names stash_app_env uses itself (_aice_*), which it could not set aside.
#
# Parsed exactly as docker parses an env-file (measured against the docker CLI): a BOM
# is dropped from line 1, leading Unicode whitespace (Go's unicode.IsSpace) from every
# line, and one trailing CR; `#` starts a comment only as the first character left; a
# value is literal (quotes, `#`, trailing spaces kept); a bare NAME is passed bare, so
# docker still takes it from this shell's environment or drops it. A line docker would
# refuse — whitespace or nothing before `=` (`export NAME=` is the common one), invalid
# UTF-8, a NUL, more than 65535 bytes — would stop the whole launch; here only that line
# is refused. So is a value still ending in CR after the one docker drops: forwarded,
# docker would drop that one too.
container_env_filter() {
  local file="$1"
  local -n _cef_lines="$2" _cef_keys="$3"
  shift 3
  local -A launcher=() seen=() passthrough=()
  # A bare NAME takes the value docker finds in THIS shell, so it is the host's
  # secret, not the file's: only names this machine lists pass that way
  # (SANDBOX_ENV_PASSTHROUGH, machine-only; bugs review ENV-6).
  local _pt; local -a _pts=()
  read -ra _pts <<< "${SANDBOX_ENV_PASSTHROUGH:-}"
  for _pt in ${_pts[@]+"${_pts[@]}"}; do passthrough[$_pt]=1; done
  local prev="" a
  for a in "$@"; do
    [[ "$prev" == -e ]] && launcher["${a%%=*}"]=1
    prev="$a"
  done
  # keys_len: the length so far of "AI_CONTAINER_ENV_KEYS=<name> <name>…" — the
  # variable's own name, then a separator (= or space) and a name per key.
  local keys_var=AI_CONTAINER_ENV_KEYS
  local LC_ALL=C n=0 raw line name why ws keys_len=${#keys_var}
  local -a nul=() uws=(
    $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80'                                   # U+0085 U+00A0 U+1680
    $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84' # U+2000…
    $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89'
    $'\xe2\x80\x8a'                                                           # …U+200A
    $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80' # U+2028 U+2029 U+202F U+205F U+3000
  )
  # `read` drops NUL bytes without a word, so find them first: one entry per line,
  # N for each NUL in it.
  # LC_ALL=C on each tr: a `local LC_ALL` is not exported, and BSD tr in a UTF-8
  # locale stops at the first invalid byte, truncating the map.
  mapfile -t nul < <(LC_ALL=C tr -c '\000\n' '.' < "$file" | LC_ALL=C tr '\000' 'N')
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="${raw%$'\r'}"
    (( n == 1 )) && line="${line#$'\xef\xbb\xbf'}"
    while :; do
      case "$line" in [[:space:]]*) line="${line:1}"; continue ;; esac
      for ws in "${uws[@]}"; do
        if [[ "$line" == "$ws"* ]]; then line="${line:${#ws}}"; continue 2; fi
      done
      break
    done
    [[ -z "$line" || "$line" == '#'* ]] && continue
    name="${line%%=*}"; why=""
    if (( ${#raw} > 65535 )); then why="it is longer than docker reads (65535 bytes)"
    elif [[ "${nul[n - 1]:-}" == *N* ]]; then why="it holds a NUL byte"
    elif [[ "$line" == *[![:ascii:]]* ]] && ! _utf8_valid "$line"; then why="it is not valid UTF-8"
    elif [[ "$line" == *$'\r' ]]; then why="its value ends in a carriage return"
    elif [[ -z "$name" ]]; then why="it has no name before the ="
    elif [[ "$name" == export[[:blank:]]* ]]; then why="docker does not take 'export': write NAME=value"
    elif [[ "$name" == *[[:blank:]]* ]]; then why="its name holds whitespace"
    elif ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then why="its name is not a shell variable name"
    elif env_key_denied "$name"; then why="$name acts on the container's first process before it can be set aside"
    elif [[ -n "${launcher[$name]:-}" ]]; then why="the launcher sets $name itself"
    elif [[ "$line" != *=* && -z "${passthrough[$name]:-}" ]]; then
      why="$name takes its value from this machine's environment; list it in SANDBOX_ENV_PASSTHROUGH (sandbox.local.env) to pass it"
    else
      case "$name" in
        HOME|USER|LOGNAME) why="the container sets $name for the sandbox user" ;;
        # bash assigns these itself, or will not let them go, so the shell would
        # hold bash's value rather than the file's. Measured on bash 5.1 and 5.2;
        # tests/test-env-file.sh re-measures whichever bash runs it.
        BASH|BASHOPTS|BASHPID|BASH_*|COMP_*|COMPREPLY|COPROC*|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS)
          why="$name is bash's own variable" ;;
        EUID|FUNCNAME|GROUPS|HISTCMD|LINENO|MAPFILE|OLDPWD|OPTARG|OPTERR|OPTIND|PIPESTATUS|PPID)
          why="$name is bash's own variable" ;;
        PS1|PS2|PWD|RANDOM|READLINE_*|REPLY|SECONDS|SHLVL|SRANDOM|UID|_)
          why="$name is bash's own variable" ;;
        AI_CONTAINER_ENV_KEYS|_aice_*) why="$name is reserved for the launcher and the entrypoint" ;;
        # Knobs only the container's root setup reads (entrypoint.sh and the
        # daemons it starts as root); tests/test-env-file.sh fails if one is added
        # there without landing here or in the -e flags.
        SELF_HEALING_ENABLED|ALLOW_IPV6_BYPASS)
          why="only the container's root setup reads $name, and container.env does not reach it: set it in sandbox.env" ;;
        ALLOWLIST_DOMAINS_FILE|ALLOWLIST_CIDRS_FILE|ALLOWLIST_PROXY_DOMAINS_FILE|ALLOWLIST_IPV4_SET)
          why="only the container's root setup reads $name, and container.env does not reach it" ;;
        ALLOWLIST_IPV6_SET|BLOCKED_CAPTURE_ENABLED|BLOCKED_INTERNAL_DIR|NFLOG_GROUP)
          why="only the container's root setup reads $name, and container.env does not reach it" ;;
      esac
    fi
    if [[ -n "$why" ]]; then
      printf 'WARNING: %s line %d not passed to the container: %s.\n' "$file" "$n" "$why" >&2
      continue
    fi
    # Every name travels in one value, AI_CONTAINER_ENV_KEYS=…, and the kernel caps
    # one environment string at 128 KiB with its NUL (MAX_ARG_STRLEN): past that
    # the container could not start at all.
    if [[ -z "${seen[$name]:-}" ]] && (( keys_len + 1 + ${#name} > 131071 )); then
      printf 'WARNING: %s line %d not passed to the container: too many variables — their names no longer fit in one value.\n' "$file" "$n" >&2
      continue
    fi
    _cef_lines+=("$line")
    [[ -n "${seen[$name]:-}" ]] || { seen[$name]=1; _cef_keys+=("$name"); keys_len=$((keys_len + 1 + ${#name})); }
  done < "$file"
}

# launcher_dirs_in <launchers-out> <unreadable-out> <dir> <agent-uid> <agent-gid> <your-uid>: appends every
# launcher directory below <dir> — matched by CONTENT, a directory holding both
# sandbox.sh and sandbox-common.sh, which is what the host runs `./sandbox.sh`
# from (a project's .ai-containers/ copy, or an ai-containers checkout itself;
# sandbox.sh may be a symlink) — and every directory the search cannot see into
# although the agent (<uid>/<gid>) could reach inside it: one it owns, so can
# chmod back, or one whose mode lets it search. A directory nobody but its owner
# can enter (a database's data directory, say) hides nothing the agent can
# touch, so it is not reported. Mode bits decide the agent's side; the kernel
# (-r/-x) decides yours. To six levels down, pruning dependency and VCS trees:
# it runs on every launch over every writable mount, measured at a few
# hundredths of a second over a ~/dev full of repos (far slower on a WSL drvfs
# path under /mnt/<drive>). NUL-delimited, and always returns 0.
launcher_dirs_in() {
  # shellcheck disable=SC2178  # nameref: shellcheck does not model `local -n`
  local -n _ldi_out=$1 _ldi_unr=$2
  local f
  local -a hits=()
  mapfile -d '' -t hits < <(find "$3" -mindepth 1 -maxdepth 7 \
      \( -name node_modules -o -name .git -o -name vendor -o -name .venv -o -name target \) -prune \
      -o -name sandbox.sh \( -type f -o -type l \) -print0 2>/dev/null)
  for f in ${hits[@]+"${hits[@]}"}; do
    if [[ -f "$f" && -f "${f%/sandbox.sh}/sandbox-common.sh" ]]; then _ldi_out+=("${f%/sandbox.sh}"); fi
  done
  # Candidates: a directory of yours whose owner bits deny you (exact — the
  # owner class is all that applies to you), or any directory you do not own
  # (which class applies to you, given supplementary groups and ACLs, only the
  # kernel knows) — in either case only where the agent's own class, from mode
  # bits and its single group, lets it reach in. -r/-x then ask the kernel.
  hits=()
  mapfile -d '' -t hits < <(find "$3" -mindepth 1 -maxdepth 6 \
      \( -name node_modules -o -name .git -o -name vendor -o -name .venv -o -name target \) -prune \
      -o -type d \
         \( \( -user "$6" ! -perm -0500 \) -o ! -user "$6" \) \
         \( -user "$4" -o \( -group "$5" -perm -0010 \) -o \( ! -group "$5" -perm -0001 \) \) \
         -print0 2>/dev/null)
  for f in ${hits[@]+"${hits[@]}"}; do
    if [[ ! -r "$f" || ! -x "$f" ]]; then _ldi_unr+=("$f"); fi
  done
  return 0
}

# git_dirs_in <gitdirs-out> <gitfiles-out> <links-out> <unreadable-out> <dir>: appends every
# git directory below <dir>, matched by CONTENT — a directory holding HEAD and
# either config and objects/ (a repository's own, bare or not, or a submodule's
# under .git/modules) or commondir (a linked worktree's, under .git/worktrees) —
# every `.git` FILE (a linked worktree's or a submodule's checkout, naming its git
# directory), every `.git` symlink, and every directory you cannot list that is
# a .git or lies inside one (an agent that owns it could `chmod 000` it in one
# session to hide what is inside from the next scan). Where git runs, a
# submodule's checkout is also found through its git directory's core.worktree,
# wherever it lies — a vendor/ is pruned by name, and submodules commonly live
# in one. Git directories to seven levels down, so a checkout's own .git is
# found to six, as launchers are; dependency trees are pruned outside .git, and
# a .git's object store, refs and logs, which hold nothing that runs.
# NUL-delimited; always returns 0.
# _git_index_read <records-out> <gitdir> <worktree>: the index's records (`ls-files
# -s -z`), read by the host's git WITHOUT the repository: GIT_DIR is a throwaway
# empty repository of the launcher's own, and only GIT_INDEX_FILE is the real
# one. The agent can write a repository's config — an agent-made repository's
# whole — and git reads it, includes and all, before the index: a FIFO include
# hung the launch, /dev/stdin read what you typed, and in a partial clone the
# read fetched a missing tree and ran remote.<name>.uploadpack (GIT-1; review of
# b3d2362). No object store is given either (an alternates file can be a FIFO
# too), so a sparse index, which needs trees to expand, cannot be read: that
# fails, as does any `error:`/`fatal:` git prints while exiting 0 (git 2.34 does
# on a partial read). A missing index records nothing. Fails on any of those.
_git_index_read() {
  # shellcheck disable=SC2178  # nameref: shellcheck does not model `local -n`
  local -n _gir_out=$1
  local g="$2" top="$3" fmt
  _gir_out=()
  # Not where git does not run: a shim would be run for nothing, once per
  # index (re-review of the GIT-24 fix).
  _git_usable || return 1
  [[ -e "$g/index" ]] || return 0
  [[ -f "$g/index" ]] || return 1
  # A split index reads its shared part from beside it, a file the agent can
  # make a FIFO too (re-review of c0d48d9; G37).
  local si
  for si in "$g"/sharedindex.*; do
    if [[ ( -e "$si" || -L "$si" ) && ! -f "$si" ]]; then return 1; fi
  done
  # A sparse index cannot be read this way: even with --sparse, git checks the
  # objects of a sparse index as it loads it, and handing it the object store
  # would hand it files the agent can make FIFOs. It fails, and is named; the
  # cost is that a sparse-index repository's gitlinks are not followed.
  # From the common directory's config for a linked worktree's git directory,
  # which has none of its own: a sha256 repository was read as sha1 and failed
  # (review of 3c754aa).
  local fcfg="$g/config" fcd=""
  if [[ ! -f "$fcfg" && -f "$g/commondir" ]]; then
    _git_ptr_read "$g/commondir" fcd || true
    [[ "$fcd" == /* ]] || fcd="$g/$fcd"
    _cd_phys fcd "$fcd" && fcfg="$fcd/config"
  fi
  fmt="$(_git_file_config "$fcfg" extensions.objectformat 2>/dev/null)" || fmt=sha1
  [[ "$fmt" =~ ^[a-z0-9]{1,16}$ ]] || return 1
  if [[ -z "$_gir_tmp" ]]; then
    _gir_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-launcher-index.XXXXXX")" || {
      _gir_tmp=""
      if [[ -z "$_gir_tmp_warned" ]]; then
        _gir_tmp_warned=1
        printf 'WARNING: cannot make a temporary directory in %s (TMPDIR); git indexes are not read, so the submodules they record are not followed\n' "$(_q "${TMPDIR:-/tmp}")" >&2
      fi
      return 1
    }
  fi
  if [[ ! -d "$_gir_tmp/$fmt/.git" ]]; then
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git init -q --object-format="$fmt" "$_gir_tmp/$fmt" >/dev/null 2>&1 || return 1
  fi
  # LC_ALL=C keeps git's error:/fatal: prefixes untranslated (d39480b). The
  # marker starts with a NUL: a git that dies mid-record, printing nothing on
  # stderr, would otherwise glue it onto the cut-off record and pass (G39).
  # Bounded where timeout(1) exists: the FIFO checks above are check-then-use, and
  # a concurrent container could swap the index for a FIFO after them, which
  # blocked the launch for ever (review of the batch 1 hotfix; GIT-4, G44). A
  # timeout is a read that failed. macOS has no timeout(1): there it is bounded
  # only where Homebrew coreutils put gtimeout on PATH, and unbounded otherwise.
  # Read once per launch, into a file: ls-files lists the same whatever worktree
  # it is given, so a second mount reading one index reuses the first read, and
  # mapfile reads a file in blocks where it read a pipe a byte at a time — 100k
  # entries cost seconds a read (review of 4e91bf3). A git that exited non-zero,
  # a cut-off record included, is a failed read (G39).
  local _gir_t=() _gir_f _gir_rc
  read -r -a _gir_t <<< "$(_timeout_prefix)"
  _gir_f="${_gir_cache[$g]:-}"
  if [[ -z "$_gir_f" ]]; then
    _gir_f="$_gir_tmp/idx.${#_gir_cache[@]}"; _gir_cache[$g]="$_gir_f"
    _gir_rc=0
    LC_ALL=C GIT_DIR="$_gir_tmp/$fmt/.git" GIT_INDEX_FILE="$g/index" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none \
      ${_gir_t[@]+"${_gir_t[@]}"} git -C "$top" -c core.fsmonitor=false --work-tree="$top" ls-files -s -z \
      >"$_gir_f" 2>"$_gir_f.err" || _gir_rc=$?
    if (( _gir_rc == 0 )) && grep -qE '^(error|fatal):' "$_gir_f.err" 2>/dev/null; then _gir_rc=1; fi
    printf '%s' "$_gir_rc" > "$_gir_f.rc"
  fi
  if [[ "$(cat "$_gir_f.rc" 2>/dev/null)" != 0 ]]; then _gir_out=(); return 1; fi
  mapfile -d '' -t _gir_out < "$_gir_f"
  return 0
}

# _is_git_dir <dir>: what git takes for a git directory — HEAD, with objects/ and
# refs/ or a commondir. Not a config: git needs none, and one without was not taken
# for a git directory, so the agent could add a config the host's git then read
# (automated security review of 4a4e30c).
_is_git_dir() {
  # A regular commondir alone is enough, whatever HEAD, objects/ and refs/ hold:
  # git writes one in every linked worktree's directory, an earlier launch made
  # the ./ placeholder in every other it protected, and either is then bound
  # read-only, a mount point the agent cannot remove. HEAD, objects/ and refs/
  # are not, so moving one aside in one session hid the directory from the next
  # launch (GIT-7; G77, G78; automated security reviews of 855d205, 7429d87).
  # Taking a planted commondir too only protects more. A bare repository only the
  # scan finds gets no placeholder (GIT-11), so one whose HEAD is removed is not
  # found again — the trade-off GIT-11 accepted.
  if [[ -f "$1/commondir" && ! -L "$1/commondir" ]]; then return 0; fi
  # A HEAD that is a link counts too: git takes one (review of 56c91c4; G68).
  # A FIFO counts as well, so that it is refused rather than hidden (G70).
  # A link counts whatever it leads to, a directory too (G71).
  [[ -L "$1/HEAD" ]] || [[ -e "$1/HEAD" && ! -d "$1/HEAD" ]] || return 1
  { [[ -d "$1/objects" && -d "$1/refs" ]] || [[ -f "$1/commondir" ]]; }
}
# _is_common_dir <dir>: what git takes for the common directory a commondir names
# — objects/ and refs/; a HEAD is a worktree's, not needed here (automated
# security review of 236d347).
_is_common_dir() { [[ -d "$1/objects" && -d "$1/refs" ]]; }
# _in_writable <path>: inside one of launcher_ro_overlay's writable binds (bsrc).
_in_writable() {
  local _w
  for _w in ${bsrc[@]+"${bsrc[@]}"}; do [[ "$1" == "$_w" || "$1" == "$_w"/* ]] && return 0; done
  return 1
}
# _gd_resolve <dir> <path> <named by> <out-var>: resolve a gitdir:/commondir value
# as git does (physically, relative to <dir>), into <out-var>; a target the agent
# could still make, or reach through a link it can repoint, inside any writable
# bind, is named (capped by the caller's _gdi_warned). Fails if nothing resolves.
_gd_resolve() {
  local -n _gr_out=$4
  local _gr_t _gr_lex _gr_c _gr_ld="" _gr_raw
  _gr_out=""
  if [[ "$2" == /* ]]; then _gr_t="$2"; else _gr_t="$1/$2"; fi
  _gr_raw="$_gr_t"
  _gr_lex="$(_lex_norm "$_gr_t")"
  if ! _cd_phys _gr_t "$_gr_t"; then
    # Where it would be, spelled as on disk, as well as how it is written: in
    # another case it names the same place (GIT-38). Only here: a subshell more
    # for every target that exists cost every launch (third review).
    _canon_lex _gr_c "$_gr_lex"
    if { _in_writable "$_gr_lex" || _in_writable "$_gr_c"; } && (( ++_gdi_warned <= 5 )); then
      printf 'WARNING: %s names %s, which does not exist; if the agent makes it, your host'\''s git\n' "$(_term "$3")" "$(_term "$_gr_lex")" >&2
      printf '         reads it unprotected until the next launch.\n' >&2
    fi
    return 1
  fi
  # Through a link: not a case difference, which leads where it is written.
  if [[ "$_gr_lex" != "$_gr_t" ]] && _lex_link_dir _gr_ld "$_gr_raw" \
     && { _in_writable "$_gr_lex" || _in_writable "$_gr_ld"; } && (( ++_gdi_warned <= 5 )); then
    printf 'WARNING: %s reaches %s through a link inside the mount, which the agent can repoint\n' "$(_term "$3")" "$(_term "$_gr_t")" >&2
    printf '         to a git directory this launch did not protect. Name the real path in it instead.\n' >&2
  fi
  _gr_out="$_gr_t"
}

# _timeout_prefix [seconds]: the command that bounds a read (10 s by default), or
# nothing where there is none — Homebrew coreutils' `gtimeout`, else `timeout`
# (GIT-16; G44, G75).
_timeout_prefix() {
  # gtimeout first: Homebrew coreutils' name for the same GNU tool (G44, G75).
  if command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout -k 2 %s' "${1:-10}"
  elif command -v timeout >/dev/null 2>&1; then printf 'timeout -k 2 %s' "${1:-10}"
  fi
}

# Bounded reads (GIT-10, GIT-23). A small file the agent can write — a .git
# file, a commondir, a gitdir, a config — is checked as a regular file and then
# read, and a concurrent container can swap it for a FIFO in between, which
# blocked the launch for ever (GIT-10). So every read is bounded, and one cut off
# refuses the launch rather than reading as unset. The bound is a time, though,
# and a regular file only slow to read — a config of thousands of entries on a
# busy host — was refused too, blamed on a FIFO (bugs review GIT-23). So a read
# may take _rd_long_secs while the launch's slow reads (those past _rd_secs)
# have taken less than _rd_budget_secs in all, and _rd_secs once they have:
# planted slow files cost the launch that much, no more. What a read takes
# includes its reader's time, which the pipe holds the read to; buffering the
# output to retry a read cut off lost that, and a small config whose listing is
# large then held the launch for minutes (review of the GIT-23 fix). A refusal
# says whether the file was swapped or only slow.
_rd_secs=2 _rd_long_secs=10 _rd_budget_secs=30
_rd_init=""; _rd_dir=""; _rd_tp=(); _rd_lim=0
# _rd_prep: where the launch's subshells — most reads run in $(…) or <(…) —
# count the time slow reads took. run_container and launcher_ro_overlay call it
# first, in the launcher's own shell; the EXIT trap removes it. Without it, or once a count
# could not be written (`ok` gone), every read gets _rd_secs, as before GIT-23.
_rd_prep() {
  [[ -z "$_rd_init" ]] || return 0
  _rd_init=1
  # The timeout command without its duration, which each read sets.
  read -r -a _rd_tp <<< "$(_timeout_prefix 1) "
  if (( ${#_rd_tp[@]} )); then unset '_rd_tp[-1]'; fi
  # Only in the launcher's own shell: one made in a subshell would be lost to
  # the next read, and to the EXIT trap (re-review of the GIT-23 fix).
  if (( BASH_SUBSHELL > 0 )); then return 0; fi
  _rd_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-launcher-read.XXXXXX" 2>/dev/null)" || _rd_dir=""
  if [[ -n "$_rd_dir" ]] && ! { : > "$_rd_dir/ok"; } 2>/dev/null; then _rd_dir=""; fi
}
# _rd_left: sets _rd_lim to the milliseconds slow reads may still take, 0 when
# they cannot be counted. No subshell: it runs before every read.
_rd_left() {
  local n spent=0 c="$_rd_dir/spent"
  _rd_lim=0
  [[ -n "$_rd_dir" && -f "$_rd_dir/ok" ]] || return 0
  if [[ -e "$c" || -L "$c" ]]; then
    # A count that is not a regular file, or a line in it that is not one, ends
    # the longer bound for the launch: `ok` goes now, not only when a slow read
    # tries to add to it (whether a read cut off at the bound counts as slow is
    # a race; G99 failed on it at the floor).
    [[ -f "$c" && ! -L "$c" ]] || { rm -f "$_rd_dir/ok"; return 0; }
    while IFS= read -r n; do
      [[ "$n" =~ ^[0-9]{1,9}$ ]] || { rm -f "$_rd_dir/ok"; return 0; }
      spent=$(( spent + 10#$n ))
    done < "$c"
  fi
  _rd_lim=$(( _rd_budget_secs * 1000 > spent ? _rd_budget_secs * 1000 - spent : 0 ))
}
# _rd_run <file> <command>...: <command>, which reads <file>, under that bound.
_rd_run() {
  # Most callers read through `< <(…)`, which inherits errexit: a command that
  # fails here unhandled would end the read with nothing refused (re-review of
  # the GIT-23 fix, HIGH).
  local -; set +e
  local f="$1" rc=0 lim t0 ms c
  local -a t=()
  shift
  _rd_prep
  _rd_left; lim="$_rd_lim"
  (( lim < _rd_long_secs * 1000 )) || lim=$(( _rd_long_secs * 1000 ))
  (( lim > _rd_secs * 1000 )) || lim=$(( _rd_secs * 1000 ))
  # Whole seconds, which every timeout(1) takes.
  lim=$(( (lim + 999) / 1000 ))
  if (( ${#_rd_tp[@]} )); then t=("${_rd_tp[@]}" "$lim"); fi
  # Digits only: the decimal point is the locale's, and not always . or ,.
  t0="${EPOCHREALTIME//[!0-9]/}"
  "${t[@]}" "$@" || rc=$?
  ms=$(( (${EPOCHREALTIME//[!0-9]/} - t0) / 1000 ))
  if (( ms > _rd_secs * 1000 )) && [[ -n "$_rd_dir" ]]; then
    c="$_rd_dir/spent"
    if [[ ( -f "$c" && ! -L "$c" ) || ! ( -e "$c" || -L "$c" ) ]]; then
      { printf '%d\n' "$ms" >> "$c"; } 2>/dev/null || rm -f "$_rd_dir/ok"
    else
      rm -f "$_rd_dir/ok"
    fi
  fi
  if (( rc == 124 || rc == 137 )); then
    if [[ ! -f "$f" ]]; then _rd_fail "$f" fifo "$lim"
    elif (( lim > _rd_secs )); then _rd_fail "$f" slow "$lim"
    else _rd_fail "$f" spent "$lim"; fi
    return 1
  fi
  return "$rc"
}
# _rd <bytes> <file>: the first <bytes> of a small file the agent can write.
_rd() {
  _rd_run "$2" head -c "$1" -- "$2"
}
# _git_ptr_read <file> <out-var> [gitdir]: a file git takes a path from (a
# commondir, a gitdir, a .git file), as this launcher and git both read it. git
# reads it whole, cuts its trailing CRs and LFs, and stops at the first NUL; the
# launcher read up to the NUL and cut after it, so `./\n\0\n` was the ./
# placeholder here and, to git, a directory named by a newline that the agent
# can make in .git, whose config the host's git ran (bugs review GIT-30). With
# no NUL, and no more than the 4096 bytes read, the two read it alike, a CR or
# LF inside included (git writes one for a path that holds it); anything else
# is refused (_rd_fail), not parsed as git would parse it, as parsers standing
# in for git failed review after review. A worktree's gitdir git also cuts off
# trailing spaces and tabs, and never writes one there: with `gitdir`, one
# there is refused too (review of the GIT-30 fix).
_git_ptr_read() {
  local -n _gpr_out=$2
  local LC_ALL=C _gpr_v=""
  _gpr_out=""
  if IFS= read -r -d '' _gpr_v < <(_rd 4097 "$1" 2>/dev/null) || (( ${#_gpr_v} > 4096 )); then
    _rd_fail "$1" odd; return 1
  fi
  while [[ "$_gpr_v" == *[$'\r\n'] ]]; do _gpr_v="${_gpr_v%?}"; done
  if [[ "${3:-}" == gitdir && "$_gpr_v" == *[$' \t'] ]]; then _rd_fail "$1" odd; return 1; fi
  _gpr_out="$_gpr_v"
}
# _rd_fail <file> <fifo|slow|spent|odd> <seconds>: a bounded read that was cut off
# is not an absent key — read as one, it failed open (automated security review
# of 116129d). The reads run in $(…) and <(…), where exit ends only the subshell,
# so the launcher itself is signalled; its USR1 trap refuses the launch. Nothing
# here may stop it first: errexit is on in a <(…) (re-review of the GIT-23 fix).
_rd_fail() {
  local -; set +e
  local why
  case "${2:-}" in
    slow) why="could not be read within ${3:-?} s, though it is a regular file" ;;
    odd) why="holds what git reads otherwise than this launcher: a NUL, more than 4096 bytes, or a gitdir's space or tab at its end" ;;
    spent) why="could not be read within ${3:-?} s, though it is a regular file, and this launch has no more time for slow reads" ;;
    *) why="could not be read within ${3:-its bound} s, and is not a regular file now (swapped for a FIFO, or removed)" ;;
  esac
  # To the launcher's own stderr: every caller sends its stderr to /dev/null, and
  # the refusal was silent (review of the batch 10 branch; G86).
  printf 'ERROR: %s %s; refusing the launch.\n' "$(_term "$1")" "$why" >&"${_rd_errfd:-2}"
  if [[ "${2:-}" == slow || "${2:-}" == spent ]]; then
    printf '       The host may be busy: launch again.\n' >&"${_rd_errfd:-2}"
  elif [[ "${2:-}" == odd ]]; then
    printf '       git writes one path and a newline there. If you did not make it, remove it on the host.\n' >&"${_rd_errfd:-2}"
  fi
  kill -s USR1 "$$" 2>/dev/null || true
}

# _cd_phys <out-var> <dir> [<path>]: the physical path of <dir>, or of <path>
# taken from <dir>, exactly — into <out-var>, never through $(...), which drops
# the trailing newlines a directory's name can end with: a decoy without one was
# read instead (review of the GIT-31 fix). A relative <path> goes through ./, as
# git takes it: cd reads a bare `-` as its previous directory. Fails if either
# cannot be entered.
#   Spelled as on disk (_disk_spell): bash's $PWD keeps the spelling it was
# given, and on a filesystem that ignores case (macOS's APFS, a WSL drive) a
# gitdir: or core.worktree spelled in another case names the same directory,
# while every "inside this mount" test is a prefix match: the git directory it
# named was never protected (bugs review GIT-38).
_cd_phys() {
  _cd_bash "$@" || return 1
  _disk_spell "$1"
}

# _cd_bash: _cd_phys as bash spells it, for a walk that only follows links;
# _walk_exposed spells its records before it judges them.
_cd_bash() {
  local -n _cb_out=$1
  local _cb_p="${3:-.}"
  _cb_out=""
  [[ "$_cb_p" == /* ]] || _cb_p="./$_cb_p"
  IFS= read -r -d '' _cb_out < <(cd -P -- "$2" 2>/dev/null && cd -P -- "$_cb_p" 2>/dev/null && printf '%s\0' "$PWD") \
    || { _cb_out=""; return 1; }
  # bash keeps a leading //, which no mount's prefix matches: a gitdir: written
  # //<path> named a git directory never protected (second review of the GIT-38
  # fix). On Linux and macOS it is /.
  while [[ "$_cb_out" == //* ]]; do _cb_out="${_cb_out#/}"; done
}

# _ci_path <path>: whether a physical <path> crosses a directory that ignores
# case: some component, its case turned over, names the same file. Builtin
# tests only, so a case-sensitive filesystem costs no process (review of the
# GIT-38 fix: a process per step let an agent's tree stretch a launch tenfold).
# A link at the other spelling is not taken for one. Each prefix is checked
# once per shell (_ci_memo): walks and gitlinks ask about the same directories
# over and over, and a launch on a case-sensitive filesystem still took 2.5
# times as long (second review).
_ci_path() {
  [[ "$1" == /* ]] || return 1
  # Made once, by a flag: declare -p prints the whole table on every call.
  [[ -n "${_ci_memo_made:-}" ]] || { declare -gA _ci_memo=(); _ci_memo_made=1; }
  local _ci_p="${1%/}" _ci_s="" _ci_r _ci_c _ci_f
  while [[ -n "$_ci_p" && -z "${_ci_memo[$_ci_p]+x}" ]]; do
    _ci_s="/${_ci_p##*/}$_ci_s"; _ci_p="${_ci_p%/*}"
  done
  if [[ -n "$_ci_p" && "${_ci_memo[$_ci_p]}" == 1 ]]; then return 0; fi
  _ci_r="${_ci_s#/}"
  while [[ -n "$_ci_r" ]]; do
    _ci_c="${_ci_r%%/*}"
    if [[ "$_ci_r" == */* ]]; then _ci_r="${_ci_r#*/}"; else _ci_r=""; fi
    [[ -n "$_ci_c" ]] || continue
    _case_flip _ci_f "$_ci_c"
    if [[ "$_ci_f" != "$_ci_c" && ! -L "$_ci_p/$_ci_f" && "$_ci_p/$_ci_f" -ef "$_ci_p/$_ci_c" ]]; then
      _ci_memo[$_ci_p/$_ci_c]=1; return 0
    fi
    _ci_p="$_ci_p/$_ci_c"; _ci_memo[$_ci_p]=0
  done
  return 1
}

# _disk_spell <var>: the existing physical directory path in <var>, spelled as
# on disk where it crosses a directory that ignores case: from getcwd (an
# external pwd -P), one newline after it taken off exactly. Each directory is
# asked once per shell (_ds_cache); at most AI_CONTAINERS_SPELL_MAX (5000, a test
# knob) are asked per launch, then the launch is refused, named, as past
# SANDBOX_GIT_MAX: the agent can make directories (review of the GIT-38 fix).
# Unchanged where there is no pwd with an absolute path. Where readdir must
# spell it (_ds_readdir) and names nothing that is it, the launch is refused.
_disk_spell() {
  local -n _ds_v=$1
  local _ds_k="$_ds_v" _ds_r="" _ds_a _ds_rc=0
  [[ -n "$_ds_k" ]] || return 0
  _ci_path "$_ds_k" || _win_path "$_ds_k" || return 0
  [[ -n "${_ds_cache_made:-}" ]] || { declare -gA _ds_cache=(); _ds_cache_made=1; }
  if [[ -n "${_ds_cache[$_ds_k]+x}" ]]; then _ds_v="${_ds_cache[$_ds_k]}"; return 0; fi
  _ds_n=$(( ${_ds_n:-0} + 1 ))
  if (( _ds_n > ${AI_CONTAINERS_SPELL_MAX:-5000} )); then
    printf 'ERROR: more than %s directories on a filesystem that ignores case had to be read as\n' "${AI_CONTAINERS_SPELL_MAX:-5000}" >&2
    printf '       spelled on disk, the last %s; refusing the launch. Mount narrower directories, or :ro.\n' "$(_q "$_ds_k")" >&2
    kill -s USR1 "$$" 2>/dev/null || true
    exit 1
  fi
  if [[ -z "${_cd_phys_pwd:-}" ]]; then
    _cd_phys_pwd="$(type -P pwd 2>/dev/null)" || _cd_phys_pwd=""
    [[ "$_cd_phys_pwd" == /* ]] || _cd_phys_pwd=-
  fi
  # Where the kernel makes a dentry per spelling (WSL's drvfs), getcwd prints
  # the spelling a directory was reached by, so those directories are spelled
  # from readdir first (PLAT-8). getcwd is asked only if a directory that
  # ignores case on a filesystem whose kernel does too is left on the way.
  _ds_a="$_ds_k"
  _ds_readdir _ds_a || _ds_rc=$?
  if (( _ds_rc == 0 )); then _ds_cache[$_ds_k]="$_ds_a"; _ds_v="$_ds_a"; return 0; fi
  if (( _ds_rc == 2 )); then
    printf 'ERROR: nothing the listing of %s names is %s (it cannot be listed, it is\n' "$(_term "${_ds_a%/*}")" "$(_q "${_ds_a##*/}")" >&"${_rd_errfd:-2}"
    printf '       an 8.3 short name, or its case is not one this launcher folds), so %s cannot be spelled\n' "$(_q "$_ds_k")" >&"${_rd_errfd:-2}"
    printf '       as on disk to be compared with the mounts; refusing the launch. Write the path with\n' >&"${_rd_errfd:-2}"
    printf '       its long names, make the directory listable, mount narrower directories, or :ro.\n' >&"${_rd_errfd:-2}"
    kill -s USR1 "$$" 2>/dev/null || true
    exit 1
  fi
  _ds_v="$_ds_a"
  [[ "$_cd_phys_pwd" != - ]] || return 0
  IFS= read -r -d '' _ds_r < <(cd -- "$_ds_a" 2>/dev/null && "$_cd_phys_pwd" -P 2>/dev/null && printf '\0') || return 0
  _ds_r="${_ds_r%$'\n'}"
  [[ "$_ds_r" == /* ]] || return 0
  _ds_cache[$_ds_k]="$_ds_r"; _ds_v="$_ds_r"
}

# _ci_alias_fs <dir>: whether <dir>, a directory that ignores case, is on a
# filesystem whose kernel does not: one where each spelling of a name is a
# dentry of its own. WSL's drvfs (9p) is one, measured (platform-issues PLAT-8):
# a directory reached as PROJ is PROJ to getcwd, and a read-only bind, a mount
# on one dentry, does not cover the others (bugs review GIT-41). Where the
# kernel ignores case itself — ext4 and f2fs with casefold, a casefold tmpfs —
# a name has one dentry, and binds held for every spelling (the GIT-38 model).
# Linux only: the Mac half of PLAT-8 measures what Docker Desktop's file sharing
# does there. A filesystem whose type cannot be read counts as one. One stat
# per directory, cached; asked only of a directory that ignores case.
_ci_alias_fs() {
  [[ "$OSTYPE" == linux* ]] || return 1
  [[ -n "${_caf_made:-}" ]] || { declare -gA _caf=(); _caf_made=1; }
  if [[ -z "${_caf[$1]+x}" ]]; then
    case "$(stat -f -c %T -- "$1" 2>/dev/null)" in
      ext2/ext3|f2fs|tmpfs) _caf[$1]=0 ;;
      *) _caf[$1]=1 ;;
    esac
  fi
  [[ "${_caf[$1]}" == 1 ]]
}

# _ci_name <dir> <name>: <name>, its case turned over (_case_flip), names in
# <dir> the same file (a link at the other spelling is not taken for one):
# <dir> ignores case.
_ci_name() {
  local _cn_f
  _case_flip _cn_f "$2"
  [[ "$_cn_f" != "$2" && ! -L "$1/$_cn_f" && "$1/$_cn_f" -ef "$1/$2" ]]
}

# _u8_locale: a UTF-8 locale bash turns Cyrillic over in, into _u8_loc, or -
# where there is none; asked once, in a subshell, so the launcher's own locale
# is never changed.
_u8_locale() {
  [[ -z "${_u8_loc:-}" ]] || return 0
  _u8_loc="$(for _ul in C.UTF-8 C.utf8 en_US.UTF-8; do
    LC_ALL="$_ul"; _ut=$'\xd0\xb6'
    if [[ "${_ut~~}" == $'\xd0\x96' ]]; then printf '%s' "$_ul"; exit 0; fi
  done 2>/dev/null; printf -)"
}

# _case_flip <var> <name>: <name> with its case turned over, into <var>. bash
# turns over the letters of the current locale only, so under C a name with no
# ASCII letter (Док) came back as it was, and a directory by such a name was
# never seen to ignore case (automated security review of 1ed3de8). Such a name
# is turned over under a UTF-8 locale (_u8_locale), in a subshell, once per
# name; where there is none it stays as it was, and a WARNING says so, once.
_case_flip() {
  local -n _cf_v=$1
  _cf_v="${2~~}"
  [[ "$_cf_v" == "$2" && "$2" == *[![:ascii:]]* ]] || return 0
  [[ -n "${_cfl_made:-}" ]] || { declare -gA _cfl=(); _cfl_made=1; }
  if [[ -z "${_cfl[$2]+x}" ]]; then
    _u8_locale
    if [[ "$_u8_loc" != - ]]; then
      _cfl[$2]="$(LC_ALL="$_u8_loc"; printf '%s/' "${2~~}")"; _cfl[$2]="${_cfl[$2]%/}"
    else
      _cfl[$2]="$2"
      if [[ -z "${_cf_warned:-}" ]]; then
        _cf_warned=1
        printf 'WARNING: no UTF-8 locale here (C.UTF-8 or en_US.UTF-8), so a name with no ASCII letter,\n' >&"${_rd_errfd:-2}"
        printf '         such as %s, was not tried in another case: a directory by such a name that\n' "$(_q "$2")" >&"${_rd_errfd:-2}"
        printf '         ignores case is not seen. Install one, or keep such names out of the mounts.\n' >&"${_rd_errfd:-2}"
      fi
    fi
  fi
  _cf_v="${_cfl[$2]}"
}

# _win_fs <dir>: whether <dir> is on a filesystem where Windows looks names up,
# or that holds NTFS's names: WSL's drvfs (9p with aname=drvfs; virtiofs on a
# WSL kernel), SMB (cifs, and the FUSE clients smbnetfs and gvfs), and NTFS
# mounted from Linux (ntfs3, ntfs-3g as fuseblk). Windows also reaches a name by its 8.3
# short name, on a volume that makes them (C:, by default), in a case-sensitive
# directory too: from a container, a read-only bind on .ai-containers did not
# cover AI-CON~1 (measured on Docker Desktop; automated security review of
# 1ed3de8). Nothing on Linux lists short names, so every name there counts as
# having one. Only drvfs over 9p is measured; SMB counts by the protocol
# (Windows and Samba both answer to 8.3 names by default), NTFS because its
# directories index the short names, virtiofs because WSL can serve drvfs over
# it (automated security review of 0e0ea9a). Not every type unknown here: an
# NFS home would be refused. Decided by the mount <dir> lies on, from
# /proc/self/mountinfo read once (_win_mounts); where that cannot be read, by
# the filesystem's type, a 9p one counting as drvfs. Linux only; cached.
_win_fs() {
  [[ "$OSTYPE" == linux* ]] || return 1
  [[ -n "${_wf_made:-}" ]] || { declare -gA _wf=(); _wf_made=1; }
  if [[ -z "${_wf[$1]+x}" ]]; then
    _win_mounts
    local _wf_i _wf_n=-1 _wf_r=0
    if [[ "$_wm_ok" == 1 ]]; then
      # Under no Windows mount: the common case, and no further look.
      for _wf_i in ${_wm_win[@]+"${!_wm_win[@]}"}; do
        [[ "${_wm_win[_wf_i]}" == / || "$1" == "${_wm_win[_wf_i]}" || "$1" == "${_wm_win[_wf_i]}"/* ]] && _wf_r=1
      done
      if [[ "$_wf_r" == 1 ]]; then
        for _wf_i in "${!_wm_mp[@]}"; do
          [[ "${_wm_mp[_wf_i]}" == / || "$1" == "${_wm_mp[_wf_i]}" || "$1" == "${_wm_mp[_wf_i]}"/* ]] || continue
          (( ${#_wm_mp[_wf_i]} >= _wf_n )) || continue
          _wf_n="${#_wm_mp[_wf_i]}"; _wf_r="${_wm_is[_wf_i]}"
        done
      fi
    else
      case "$(stat -f -c %T -- "$1" 2>/dev/null)" in
        v9fs|cifs|smb|smb2|smb3|ntfs|fuseblk|fuse) _wf_r=1 ;;
        virtiofs) [[ "$_wm_wsl" == 0 ]] || _wf_r=1 ;;
      esac
    fi
    _wf[$1]="$_wf_r"
  fi
  [[ "${_wf[$1]}" == 1 ]]
}

# _win_path <path>: whether a physical <path> lies on, or crosses, such a
# filesystem (_win_fs): then each of its names there is spelled from readdir,
# which lists no short name (_ds_readdir).
_win_path() {
  local _wp_p="$1"
  [[ "$_wp_p" == /* ]] || return 1
  while :; do
    _win_fs "${_wp_p:-/}" && return 0
    [[ -n "$_wp_p" ]] || return 1
    _wp_p="${_wp_p%/*}"
  done
}

# _win_mounts: /proc/self/mountinfo, once: every mount point (_wm_mp), whether
# it is drvfs or SMB (_wm_is), and those that are (_wm_win); _wm_ok=1 if read.
# Mount points are unescaped as the kernel escapes them (\040, \011, \012, \134).
_win_mounts() {
  [[ -z "${_wm_ok:-}" ]] || return 0
  _wm_ok=0; _wm_mp=(); _wm_is=(); _wm_win=(); _wm_wsl=0
  case "$(cat /proc/sys/kernel/osrelease 2>/dev/null)" in *[Mm]icrosoft*|*WSL*) _wm_wsl=1 ;; esac
  [[ -r /proc/self/mountinfo ]] || return 0
  local _wm_l _wm_p _wm_t _wm_o _wm_j
  local -a _wm_f
  while IFS= read -r _wm_l; do
    IFS=' ' read -r -a _wm_f <<< "$_wm_l"
    _wm_p="${_wm_f[4]:-}"; _wm_p="${_wm_p//\\040/ }"; _wm_p="${_wm_p//\\011/$'\t'}"
    _wm_p="${_wm_p//\\012/$'\n'}"; _wm_p="${_wm_p//\\134/\\}"
    for ((_wm_j = 6; _wm_j < ${#_wm_f[@]}; _wm_j++)); do [[ "${_wm_f[_wm_j]}" != - ]] || break; done
    _wm_t="${_wm_f[_wm_j+1]:-}"; _wm_o=",${_wm_f[_wm_j+3]:-},"
    _wm_mp+=("$_wm_p")
    case "$_wm_t" in
      cifs|smb3|smb2|smbfs|drvfs|ntfs|ntfs3|fuseblk|fuse.smbnetfs|fuse.gvfsd-fuse) _wm_is+=(1) ;;
      virtiofs) _wm_is+=("$_wm_wsl") ;;
      9p) if [[ "$_wm_o" == *,aname=drvfs[,\;]* ]]; then _wm_is+=(1); else _wm_is+=(0); fi ;;
      *) _wm_is+=(0) ;;
    esac
    [[ "${_wm_is[-1]}" == 0 ]] || _wm_win+=("$_wm_p")
  done < /proc/self/mountinfo
  _wm_ok=1
}

# _ds_readdir <var>: the physical path in <var>, each name in a directory that
# ignores case on a filesystem whose kernel does not (_ci_alias_fs), and every
# name where Windows looks names up (_win_fs), spelled as readdir lists it:
# there an 8.3 short name (LONGNA~1) is the directory too, in a case-sensitive
# one as well, and readdir never lists it (automated security review of
# 0e0ea9a). Fails, with the rest respelled, if a directory that ignores
# case on another filesystem is on the way, for getcwd to spell. Each prefix
# once per shell (_dr_cache). The glob reads the directory once, in a subshell
# under a UTF-8 locale (_u8_locale), so a case bash folds only there is folded;
# the agent decides how many entries it holds, as for the scan. A directory
# whose listing names nothing that is the name — it cannot be read, folds a
# case bash does not, or the name is a short name — returns 2, with the path to it in <var>, and nothing is
# cached: getcwd would print the spelling given (automated security review of
# 1ed3de8).
_ds_readdir() {
  local -n _dr_v=$1
  local _dr_p="" _dr_r="${_dr_v#/}" _dr_c _dr_k _dr_m _dr_hit _dr_rc=0
  local -a _dr_g
  [[ -n "${_dr_cache_made:-}" ]] || { declare -gA _dr_cache=(); _dr_cache_made=1; }
  while [[ -n "$_dr_r" ]]; do
    _dr_c="${_dr_r%%/*}"
    if [[ "$_dr_r" == */* ]]; then _dr_r="${_dr_r#*/}"; else _dr_r=""; fi
    [[ -n "$_dr_c" ]] || continue
    _dr_k="$_dr_p/$_dr_c"
    if [[ -n "${_dr_cache[$_dr_k]+x}" ]]; then
      _dr_p="${_dr_cache[$_dr_k]% *}"; [[ "${_dr_cache[$_dr_k]##* }" == 0 ]] || _dr_rc=1; continue
    fi
    if _win_fs "${_dr_p:-/}" || { _ci_name "${_dr_p:-/}" "$_dr_c" && _ci_alias_fs "${_dr_p:-/}"; }; then
      _u8_locale
      _dr_g=()
      mapfile -d '' _dr_g < <(
        [[ "$_u8_loc" == - ]] || LC_ALL="$_u8_loc"
        shopt -s nocaseglob dotglob nullglob; shopt -u failglob
        _dr_l=("$_dr_p"/["${_dr_c:0:1}"]"${_dr_c:1}")
        (( ${#_dr_l[@]} == 0 )) || printf '%s\0' "${_dr_l[@]}")
      _dr_hit=""
      for _dr_m in ${_dr_g[@]+"${_dr_g[@]}"}; do
        if [[ ! -L "$_dr_m" && "$_dr_m" -ef "$_dr_p/$_dr_c" ]]; then _dr_hit="${_dr_m##*/}"; break; fi
      done
      if [[ -z "$_dr_hit" ]]; then _dr_v="$_dr_p/$_dr_c"; return 2; fi
      _dr_c="$_dr_hit"
    elif _ci_name "${_dr_p:-/}" "$_dr_c"; then
      _dr_rc=1
    fi
    _dr_p="$_dr_p/$_dr_c"
    _dr_cache[$_dr_k]="$_dr_p $_dr_rc"
  done
  _dr_v="${_dr_p:-/}"
  return "$_dr_rc"
}

# _spell_rec <var>: a path a walk reports spelled as on disk: a link by the
# directory it is in and its own name, anything else by its longest existing
# directory and the rest — a walk can end where nothing exists yet, which the
# agent can make (second review of the GIT-38 fix). A walk's records are
# physical already, so no cd: a subshell per record doubled a launch over an
# agent's links (second review).
_spell_rec() {
  local -n _sr_v=$1
  local _sr_d="$_sr_v" _sr_rest=""
  if [[ -L "$_sr_d" ]]; then _sr_rest="/${_sr_d##*/}"; _sr_d="${_sr_d%/*}"; fi
  while [[ "$_sr_d" == /?* && ! -d "$_sr_d" ]]; do
    _sr_rest="/${_sr_d##*/}$_sr_rest"; _sr_d="${_sr_d%/*}"
  done
  _disk_spell _sr_d
  _sr_v="${_sr_d%/}$_sr_rest"
  [[ -n "$_sr_v" ]] || _sr_v=/
}

# _canon_lex <out-var> <path>: an absolute, lexically normal <path> that need not
# exist, its longest existing directory taken by _cd_phys (spelled as on disk,
# links resolved) and the rest as written: where it would be, for a test of
# whether it lies in a mount (GIT-38).
_canon_lex() {
  local -n _cl_out=$1
  local _cl_d="$2" _cl_rest="" _cl_p
  while [[ "$_cl_d" == /?* && ! -d "$_cl_d" ]]; do
    _cl_rest="/${_cl_d##*/}$_cl_rest"; _cl_d="${_cl_d%/*}"
  done
  if _cd_phys _cl_p "${_cl_d:-/}"; then _cl_out="${_cl_p%/}$_cl_rest"; else _cl_out="$2"; fi
}

# _lex_link_dir <out-var> <path>: the directory, by _cd_phys, of the first
# symlink on the way of an absolute <path> as written; fails if there is none.
# Before it, a `..` steps where it is written to. A difference between how a
# path is written and where it is can be a link, or only its case or Unicode
# form (GIT-38). Not on the normalised path: `lnk/..` drops the link (review of
# the GIT-38 fix).
_lex_link_dir() {
  local -n _ll_out=$1
  local _ll_p="" _ll_rest="${2#/}" _ll_c
  while [[ -n "$_ll_rest" ]]; do
    _ll_c="${_ll_rest%%/*}"
    if [[ "$_ll_rest" == */* ]]; then _ll_rest="${_ll_rest#*/}"; else _ll_rest=""; fi
    case "$_ll_c" in
      ''|.) continue ;;
      ..) _ll_p="${_ll_p%/*}"; continue ;;
    esac
    if [[ -L "$_ll_p/$_ll_c" ]]; then _cd_phys _ll_out "${_ll_p:-/}"; return; fi
    _ll_p="$_ll_p/$_ll_c"
  done
  return 1
}

# _gdi_add_top <dir>: called from git_dirs_in; adds <dir> to its tops, once.
_gdi_add_top() {
  local _gat
  for _gat in ${tops[@]+"${tops[@]}"}; do [[ "$_gat" != "$1" ]] || return 0; done
  tops+=("$1")
}

# _lex_norm <absolute path>: the path with . and .. resolved by name alone, no link
# followed — what it says, to compare with where it physically leads.
_lex_norm() {
  local -a out=()
  local p rest="${1#/}"
  # Split by hand: `read` stopped at a newline inside a component (GIT-18; G74).
  while [[ -n "$rest" ]]; do
    p="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "$p" in
      ''|.) ;;
      ..) if (( ${#out[@]} )); then unset 'out[-1]'; fi ;;
      *) out+=("$p") ;;
    esac
  done
  local IFS=/
  printf '/%s' "${out[*]}"
}

# _gdi_follow <dir> <path> <mount root> <named by>: called from git_dirs_in, whose
# _gdi_dirs and had it extends. <path>, relative to <dir> unless absolute, is
# resolved physically, as git resolves a gitdir: or commondir; a git directory it
# leads to inside <mount root> joins the queue. One that is not a git directory
# there gets nothing made in it, and is named: git would refuse it, but an agent
# could make it one by the next launch.
_gdi_follow() {
  local t
  _gd_resolve "$1" "$2" "$4" t || return 0
  # Named by a .git file: its directory is that git directory's worktree, whose
  # index records its submodules (a linked worktree's or a separate git dir's
  # were never read; review of 236d347).
  # Every referrer is kept: one .git file must not choose the worktree a git
  # directory's index is read against (review of 3c754aa, HIGH).
  if [[ "${4,,}" == */.git && -z "${gref[$t|$1]:-}" ]]; then
    gref[$t|$1]=1; gtop_g+=("$t"); gtop_d+=("$1"); _gref_add "$t" "$1"
    # A referrer for one already read: read it again, with this worktree too — a
    # decoy found first was otherwise the only one (review of 4e91bf3).
    # Every git directory takes its worktrees from referrers too: git uses a .git
    # file's directory for a */.git it names as well (review of the GIT-36/37 fix).
    if [[ -n "${gread[$t]:-}" && -n "${greftop[$t]:-}" ]]; then unset 'gread[$t]'; _gdi_ionly+=("$t"); fi
  fi
  # A git directory outside this mount, reached from a .git file in it, that is
  # not a */.git or .git/modules one: its index is read here, against that .git
  # file's directory, which is this mount's — no other mount's scan sees the
  # referrer (a linked worktree in another mount than its main repository;
  # review of 8b3e0c5). It is protected by launcher_ro_overlay's queue.
  # A .git/modules/* one too: a submodule checkout mounted alone has its git
  # directory in the superproject, outside the mount (review of 3edee25).
  if [[ "${4,,}" == */.git && "$t" != "$3" && "$t" != "$3"/* \
        && -z "${ionly_had[$t]:-}" ]] && _is_git_dir "$t"; then
    ionly_had[$t]=1; _gdi_ionly+=("$t")
  fi
  local _ok=""
  if [[ "$4" == */commondir ]]; then _is_common_dir "$t" && _ok=1; else _is_git_dir "$t" && _ok=1; fi
  # Inside ANOTHER writable bind: recorded, and protected in that bind's view by
  # launcher_ro_overlay once every mount is scanned (reviews of dcf7dab, 4e7da47).
  local _j
  if [[ -n "$_ok" ]]; then
    for _j in ${bsrc[@]+"${!bsrc[@]}"}; do
      [[ "${bsrc[_j]}" != "$3" ]] || continue
      if [[ "$t" == "${bsrc[_j]}" || "$t" == "${bsrc[_j]}"/* ]]; then
        _xm_t+=("$t"); _xm_by+=("$4"); _xm_j+=("$_j")
      fi
    done
  fi
  [[ "$t" == "$3" || "$t" == "$3"/* ]] || return 0
  [[ -z "${had[$t]:-}" ]] || return 0
  had[$t]=1
  if [[ -n "$_ok" ]]; then
    _gdi_dirs+=("$t")
  elif (( ++_gdi_warned <= 5 )); then
    printf 'WARNING: %s names %s, which is not a git directory; nothing there is protected.\n' "$(_term "$4")" "$(_term "$t")" >&2
  fi
}

git_dirs_in() {
  # shellcheck disable=SC2178  # nameref: shellcheck does not model `local -n`
  local -n _gdi_dirs=$1 _gdi_files=$2 _gdi_links=$3 _gdi_unr=$4
  local f lf g wt wcf wtp co rel back nref
  local -a hits=()
  local -A had=()
  # git's own names however they are spelled: where case is ignored git opens
  # .GIT/head and .GIT/CONFIG as its own, and a repository the agent spelled so
  # was never found (second review of the GIT-38 fix). Elsewhere this finds a
  # few more names that the content checks below turn down.
  # The path patterns only for an entry whose name could match: seven -ipath
  # tests on every entry made every launch's scan half as slow again (third
  # review of the GIT-38 fix).
  mapfile -d '' -t hits < <(find "$5" -mindepth 1 -maxdepth 8 \
      \( \( \( -name node_modules -o -name vendor -o -name .venv -o -name target \) ! -ipath '*/.git/*' \) \
         -o \( \( -iname objects -o -iname refs -o -iname logs \) \
              \( -ipath '*/.git/objects' -o -ipath '*/.git/refs' -o -ipath '*/.git/logs' \
                 -o -ipath '*/.git/modules/*/objects' -o -ipath '*/.git/modules/*/refs' -o -ipath '*/.git/modules/*/logs' \) \) \) -prune \
      -o -iname HEAD ! -type d -print0 \
      -o -iname commondir -type f -print0 \
      -o -iname .git \( -type f -o -type l -o -type d \) -print0 \
      -o -type d -ipath '*/.git/*' -print0 2>/dev/null)
  for f in ${hits[@]+"${hits[@]}"}; do
    lf="${f,,}"
    # Matched only in another case: git's only where its directory ignores case.
    # On a case-sensitive filesystem a .Git is not git's, and was left alone
    # before (third review).
    case "$f" in
      */.git|*/HEAD|*/commondir|*/.git/*) ;;
      *) _ci_path "$f" || continue ;;
    esac
    if [[ "${lf##*/}" == .git ]]; then
      if [[ -L "$f" ]]; then _gdi_links+=("$f")
      elif [[ -f "$f" ]]; then _gdi_files+=("$f"); had[$f]=1
      elif [[ -d "$f" && ( ! -r "$f" || ! -x "$f" ) ]]; then _gdi_unr+=("$f")
      # A .git directory is protected whatever its HEAD holds: HEAD is not bound,
      # and `mv .git/HEAD .git/H` in one session hid the repository from the next
      # launch (GIT-7; G77). Queued once; its HEAD, if any, is skipped below.
      # Seven levels at most, as for one found by its HEAD (G12).
      elif [[ -d "$f" && -z "${had[$f]:-}" ]] && { rel="${f#"$5"/}"; rel="${rel//[!\/]/}"; (( ${#rel} < 7 )); }; then
        _gdi_dirs+=("$f"); had[$f]=1
      fi
      continue
    fi
    # A link is a HEAD whatever it leads to: git takes one whose text starts
    # refs/ without following it, and HEAD -> refs/heads was taken for a
    # directory (review of 7b41327, HIGH; G71). Taking every link over-accepts,
    # which only protects more.
    if [[ -d "$f" && ! -L "$f" ]]; then
      if [[ ! -r "$f" || ! -x "$f" ]]; then _gdi_unr+=("$f")
      # The git directories inside a .git count whatever their HEAD holds, as the
      # .git itself does: a linked worktree's (it has a commondir or a gitdir) and
      # a submodule's (objects/ and refs/). One whose HEAD the agent removed was
      # dropped (automated security review of 855d205, HIGH; G78).
      # A worktree's under any git directory (a bare repository's too) has a
      # commondir or a gitdir; a submodule's has any of what git keeps there.
      elif [[ -z "${had[$f]:-}" ]]; then
        if [[ "${lf%/*}" == */worktrees ]] && [[ -f "$f/commondir" || -f "$f/gitdir" ]]; then
          _gdi_dirs+=("$f"); had[$f]=1
        elif [[ "$lf" == */.git/modules/* ]] && [[ -d "$f/objects" || -d "$f/refs" || -f "$f/config" \
               || -d "$f/hooks" || -f "$f/index" || -f "$f/commondir" ]]; then
          _gdi_dirs+=("$f"); had[$f]=1
        fi
      fi
      continue
    fi
    g="${f%/*}"
    if [[ -z "${had[$g]:-}" ]] && _is_git_dir "$g"; then _gdi_dirs+=("$g"); had[$g]=1; fi
  done
  # Submodules the scan cannot see — a vendor/ is pruned by name, and submodules
  # commonly live in one: an absorbed one's checkout through its git directory's
  # core.worktree, and every submodule a repository's INDEX records (a gitlink),
  # whose .git may be a directory embedded in the checkout. Followed until
  # nothing new turns up, so a submodule's own submodules are found too. The
  # index is read with git, fsmonitor off, so a config tampered with before this
  # protection existed runs nothing here; without git, only what the scan sees.
  for g in ${_gdi_dirs[@]+"${_gdi_dirs[@]}"}; do had[$g]=1; done
  # _gdi_follow's WARNINGs: five named, then a count — every .git file is the
  # agent's to write (re-review of batch 9).
  local n=0 nf=0 top rec mode path tgt _gdi_warned=0
  local -a gtop_g=() gtop_d=() tops=() _gdi_ionly=()
  local _j
  local qq
  local -A ionly_had=() gpend=() gquiet=() gread=() gref=() greftop=() gwarned=()
  local gchanged up=""
  local ni=0
  # The repository a mount sits in, when the mount is a subdirectory of one: its
  # index, outside the mount and out of the agent's reach, records submodules
  # inside it that the scan prunes (review of 3edee25; G60). Index only.
  # Past every .git inside a writable bind, which the agent could have planted
  # between a nested mount and the real repository (review of 4e91bf3), to the
  # first one outside them all. An unreadable one out there is the user's own
  # (a sparse index), and is not named on every launch.
  up="${5%/*}"
  while [[ -n "$up" ]]; do
    # A directory or a regular file only: a FIFO planted as .git blocked the read
    # for ever (automated security review of 4a800a9; G64). Quiet only where the
    # .git itself is out of every writable bind.
    if [[ ( -d "$up/.git" || -f "$up/.git" ) && ! -L "$up/.git" ]]; then
      if [[ -d "$up/.git" ]]; then
        if _is_git_dir "$up/.git" && [[ -z "${ionly_had[$up/.git]:-}" ]]; then
          ionly_had[$up/.git]=1; _gdi_ionly+=("$up/.git")
          # Judged too, when out of every writable bind: husky's layout for a
          # project not at the git root has its hooks in the mounted directory
          # (review of the GIT-44 fix). In ANOTHER writable bind, past what its
          # scan reached, it is protected in that bind's view, as a .git file's
          # target is (re-review of the GIT-44 fix).
          if ! _in_writable "$up/.git"; then
            gquiet[$up/.git]=1; _gref_add "$up/.git" "$up"
          else
            for _j in ${bsrc[@]+"${!bsrc[@]}"}; do
              [[ "${bsrc[_j]}" != "$5" ]] || continue
              if [[ "$up/.git" == "${bsrc[_j]}"/* ]]; then _xm_t+=("$up/.git"); _xm_by+=("$5"); _xm_j+=("$_j"); fi
            done
          fi
        fi
      else
        tgt=""; _git_ptr_read "$up/.git" tgt || true
        if [[ "$tgt" == "gitdir: "* ]]; then
          _gdi_follow "$up" "${tgt#gitdir: }" "$5" "$up/.git"
          if ! _in_writable "$up/.git"; then
            tgt="${tgt#gitdir: }"; [[ "$tgt" == /* ]] || tgt="$up/$tgt"
            # The git directory it names too: one in the agent's reach is its to make
            # unreadable (automated security review of 1a30bb4).
            if _cd_phys tgt "$tgt" && ! _in_writable "$tgt"; then gquiet[$tgt]=1; fi
          fi
        fi
      fi
      _in_writable "$up" || break
    elif [[ -L "$up/.git" && -d "$up/.git" ]] && ! _in_writable "$up/.git"; then
      # A link out of every writable bind is the user's: git follows it, as
      # `repo` checkouts have it, and so does this; skipped, the next repository
      # up was judged instead (re-review of the GIT-44 fix).
      if _cd_phys tgt "$up/.git" && _is_git_dir "$tgt" && [[ -z "${ionly_had[$tgt]:-}" ]]; then
        ionly_had[$tgt]=1; _gdi_ionly+=("$tgt")
        # Its checkout is where the link lies: the worktree its index is read
        # against, as a .git file's directory is; and a target in ANOTHER
        # writable bind is protected there, as a .git directory is (final review
        # of the GIT-44 fix).
        if [[ -z "${gref[$tgt|$up]:-}" ]]; then gref[$tgt|$up]=1; gtop_g+=("$tgt"); gtop_d+=("$up"); fi
        # The checkout a relative core.hooksPath is judged from, wherever the
        # target lies (second final review of the GIT-44 fix; GIT-46).
        _gref_add "$tgt" "$up"
        if ! _in_writable "$tgt"; then
          gquiet[$tgt]=1
        elif [[ "$tgt" == "$5" || "$tgt" == "$5"/* ]]; then
          # In this mount, past what its scan reached: protected here, as a .git
          # file's target is (_gdi_follow; GIT-46).
          if [[ -z "${had[$tgt]:-}" ]]; then had[$tgt]=1; _gdi_dirs+=("$tgt"); fi
        else
          for _j in ${bsrc[@]+"${!bsrc[@]}"}; do
            [[ "${bsrc[_j]}" != "$5" ]] || continue
            if [[ "$tgt" == "${bsrc[_j]}"/* ]]; then _xm_t+=("$tgt"); _xm_by+=("$up/.git"); _xm_j+=("$_j"); fi
          done
        fi
      fi
      _in_writable "$up" || break
    fi
    up="${up%/*}"
  done
  local -A tseen=()
  local q
  local -a links=()
  local gover=""
  while :; do
  while (( n < ${#_gdi_dirs[@]} || nf < ${#_gdi_files[@]} || ni < ${#_gdi_ionly[@]} )); do
    # Past SANDBOX_GIT_MAX the launch is refused anyway: following on, and
    # reading an index per planted repository, cost minutes first (GIT-9; G83).
    if (( ${#_gdi_dirs[@]} > ${gitmax:-200} )); then gover=1; _gdi_over+=("${_gdi_dirs[@]:${gitmax:-200}:5}"); break 2; fi
    # A .git FILE names the git directory git uses there (`gitdir: <path>`), and a
    # linked worktree's commondir its common one; either can lie where the scan
    # does not go (node_modules, past depth 8), and was mounted read-only while
    # what it names stayed writable for the host's git to read (review of batch
    # 9, finding 4; G47). Each is followed into the queue.
    if (( nf < ${#_gdi_files[@]} )); then
      f="${_gdi_files[nf]}"; nf=$((nf + 1))
      # Only CR and LF stripped, as git does: `gitdir: g ` names `g ` (security
      # review of e2741b1).
      tgt=""; _git_ptr_read "$f" tgt || true
      [[ "$tgt" == "gitdir: "* ]] || continue
      _gdi_follow "${f%/*}" "${tgt#gitdir: }" "$5" "$f"
      continue
    fi
    if (( n >= ${#_gdi_dirs[@]} )); then
      # Index only: protected through the queue, its commondir followed there.
      g="${_gdi_ionly[ni]}"; ni=$((ni + 1))
    else
      g="${_gdi_dirs[n]}"; n=$((n + 1))
      # A commondir that is a link is read through, as git reads it; the protection
      # step names the link itself, which the agent can repoint (security review).
      if [[ -f "$g/commondir" ]]; then
        tgt=""; _git_ptr_read "$g/commondir" tgt || true
        if [[ -n "$tgt" && "$tgt" != ./ && "$tgt" != . ]]; then _gdi_follow "$g" "$tgt" "$5" "$g/commondir"; fi
      fi
    fi
    # The worktree its index is read against: where a .git directory lies, a
    # submodule's core.worktree, and only for a git directory that is neither (a
    # linked worktree's, a separate git dir) the directories of the .git files
    # naming it — each of them, once, so a decoy adds a worktree to check and
    # cannot replace one (review of 3c754aa, HIGH; G53).
    tops=(); top=""
    if [[ "${g,,}" == */.git ]]; then tops=("${g%/*}"); fi
    # Its core.worktree, from config and config.worktree, for every git directory,
    # resolved physically, as git takes it (chdir, then its real path): a `..`
    # after a link steps out of where the link leads, and a relative one goes
    # through ./, or cd takes `-` for its previous directory (GIT-32, GIT-33; G113).
    for wcf in "$g/config" "$g/config.worktree"; do
      _git_config_get wt "$wcf" core.worktree || continue
      if [[ -n "$wt" ]] && _cd_phys wtp "$g" "$wt"; then _gdi_add_top "$wtp"; fi
    done
    # A linked worktree, with extensions.worktreeConfig on, takes the common
    # config's core.worktree too, resolved from its own git directory (review of
    # the GIT-36/37 fix).
    if [[ -f "$g/commondir" ]]; then
      tgt=""; _git_ptr_read "$g/commondir" tgt || true
      if [[ -n "$tgt" && "$tgt" != ./ && "$tgt" != . ]] && _cd_phys wcf "$g" "$tgt" \
         && _git_config_get wt "$wcf/config" core.worktree && [[ -n "$wt" ]] && _cd_phys wtp "$g" "$wt"; then
        _gdi_add_top "$wtp"
      fi
    fi
    # Every git directory — a .git one too, a linked worktree's, a separate git
    # dir, a submodule's — also takes the directories of the .git files naming it
    # (review of 8b3e0c5; git uses that directory for any it names, review of the
    # GIT-36/37 fix), and a linked worktree's gitdir, each once and at most twenty:
    # a decoy adds one to check and cannot replace one (review of 3c754aa). A
    # submodule's core.worktree replaced them, and once the ./ placeholder exists
    # git ignores one in config and uses the .git file's directory (GIT-36; G115).
    tseen=(); nref=0
    for wcf in ${tops[@]+"${tops[@]}"}; do tseen[$wcf]=1; done
    # A linked worktree's git directory points back at its checkout's .git file
    # (gitdir): one more candidate, inside this mount — a decoy pointer adds a
    # checkout to check, no more.
    if [[ -f "$g/gitdir" ]]; then
      tgt=""; _git_ptr_read "$g/gitdir" tgt gitdir || true
      if [[ "${tgt,,}" == */.git ]]; then tgt="${tgt%/*}"; fi
      if [[ "$tgt" == /* && -d "$tgt" ]] && _cd_phys tgt "$tgt" \
         && [[ "$tgt" == "$5" || "$tgt" == "$5"/* ]] && [[ -z "${tseen[$tgt]:-}" ]]; then tseen[$tgt]=1; tops+=("$tgt"); fi
    fi
    for (( q = 0; q < ${#gtop_g[@]}; q++ )); do
      [[ "${gtop_g[q]}" == "$g" && -z "${tseen[${gtop_d[q]}]:-}" ]] || continue
      tseen[${gtop_d[q]}]=1
      # Refused past twenty, as SANDBOX_GIT_MAX refuses: skipping the rest let
      # decoys that sort first leave the real checkout unchecked (automated
      # security review of 3edee25). No real tree has that many.
      if (( ++nref > 20 )); then
        printf 'ERROR: more than 20 .git files in %s name %s; refusing the launch.\n' "$(_term "$5")" "$(_term "$g")" >&2
        printf '       Among them, in:\n' >&2
        for (( qq = 0; qq < 5 && qq < ${#tops[@]}; qq++ )); do printf '         %s\n' "$(_term "${tops[qq]}")" >&2; done
        printf '       Remove the .git files that are not yours.\n' >&2
        exit 1
      fi
      tops+=("${gtop_d[q]}")
    done
    greftop[$g]=1
    # None yet: the .git file naming it may turn up later (through an index read
    # later still), so it waits, and is retried until no waiting one gains one
    # (automated security review of 3edee25).
    if (( ${#tops[@]} == 0 )); then
      gpend[$g]=1
      continue
    fi
    unset 'gpend[$g]'
    for top in "${tops[@]}"; do
      if [[ "${g,,}" == */.git/modules/* && -f "$top/.git" && ! -L "$top/.git" && -z "${had[$top/.git]:-}" ]] \
         && [[ "$top" == "$5" || "$top" == "$5"/* ]]; then
        _gdi_files+=("$top/.git"); had[$top/.git]=1
      fi
    done
    _git_usable || continue
    # Read once: what ls-files lists does not depend on the worktree, and a read
    # per referrer let each planted .git file cost another (review of 8b3e0c5).
    links=()
    gread[$g]=1
    if ! _git_index_read links "$g" "${tops[0]}"; then
      [[ -z "${greftop[$g]:-}" || -z "${gwarned[$g]:-}" ]] || continue
      links=()
      if [[ -z "${gquiet[$g]:-}" ]]; then
        gwarned[$g]=1
        printf 'WARNING: cannot read the index of %s; submodules recorded in it are not followed,\n' "$(_q "$g")" >&2
        printf '         so a checkout of one that the scan does not reach is not protected.\n' >&2
      fi
    fi
    local gskip=0 gnl=0 r dsp
    local -a gco=() gphys=()
    local -A gres=()
    # Where each existing checkout physically is, resolved in ONE subshell per
    # index: a $(cd; pwd -P) per (gitlink, worktree top) pair, with 20 tops the
    # agent can plant, cost minutes for an index of its with thousands of
    # gitlinks; and an index with more than 1000 refuses the launch (GIT-8; G82).
    for rec in ${links[@]+"${links[@]}"}; do
      [[ "${rec%% *}" == 160000 ]] || continue
      # Past 1000 the launch is refused, as past SANDBOX_GIT_MAX: the agent writes
      # the index, and a cut that only warned left the gitlink it put last
      # unprotected (automated security review of the batch 10 branch; G82).
      if (( ++gnl > 1000 )); then
        printf 'ERROR: the index of %s records more than 1000 submodules; refusing the launch:\n' "$(_q "$g")" >&2
        printf '       a checkout of one past them would not be protected. Mount narrower directories, or :ro.\n' >&2
        exit 1
      fi
      path="${rec#*$'\t'}"
      for top in "${tops[@]}"; do
        co="$top/$path"
        if [[ "$co" == "$5"/* ]] && [[ -e "$co" || -L "$co" ]]; then gco+=("$co"); fi
      done
    done
    if (( ${#gco[@]} )); then
      mapfile -d '' -t gphys < <(cd / && for r in "${gco[@]}"; do
        if cd -P -- "$r" 2>/dev/null; then printf '%s\0' "$PWD"; else printf '\0'; fi; done)
      for (( r = 0; r < ${#gco[@]}; r++ )); do gres[${gco[r]}]="${gphys[r]:-}"; done
      # bash keeps the spelling it was given: one in another case, on a
      # filesystem that ignores case, is a case difference, and named below. Left
      # as written, it was a writable pin over a launcher's read-only overlay
      # (review of the GIT-38 fix).
      for (( r = 0; r < ${#gco[@]}; r++ )); do
        [[ "${gres[${gco[r]}]}" == "${gco[r]}" ]] || continue
        dsp="${gco[r]}"; _disk_spell dsp; gres[${gco[r]}]="$dsp"
      done
    fi
    gnl=0
    for rec in ${links[@]+"${links[@]}"}; do
      mode="${rec%% *}"; path="${rec#*$'\t'}"
      [[ "$mode" == 160000 && -n "$path" ]] || continue
      (( ++gnl <= 1000 )) || break
      # The index is the agent's to write, and git reads a hand-made entry such
      # as ../../victim as is: a path that steps out (.., ., an empty or
      # absolute component), or that a link on the way sends elsewhere, is not
      # followed (re-review of c0d48d9; tests/test-git-internals-ro-index.sh G36).
      # Named, not skipped in silence: a skipped gitlink is a checkout this launch
      # does not protect (review of the batch 1 hotfix; GIT-3).
      # Five named per index, then a count: the index is the agent's, and one with
      # 100,000 such entries printed 100,000 WARNINGs (review of batch 9, finding 5).
      case "/$path/" in */../*|*/./*|*//*)
        if (( ++gskip <= 5 )); then
          printf 'WARNING: the index of %s records a submodule at %s, which steps out of it; not followed.\n' "$(_q "$g")" "$(_q "$path")" >&2
        fi
        continue ;;
      esac
      for top in "${tops[@]}"; do
        co="$top/$path"; f="$co/.git"
        [[ "$co" == "$5"/* ]] || continue
        if [[ -e "$co" || -L "$co" ]]; then
          if [[ "${gres[$co]:-}" != "$co" ]]; then
            if (( ++gskip <= 5 )); then
              printf 'WARNING: submodule %s of %s is not where its index says (a link on the way, a case or\n' "$(_q "$co")" "$(_q "$g")" >&2
              printf '         Unicode difference, or a directory you cannot search); its checkout is not protected.\n' >&2
            fi
            continue
          fi
        fi
        if [[ -L "$f" ]]; then
          [[ -n "${had[$f]:-}" ]] || { _gdi_links+=("$f"); had[$f]=1; }
        elif [[ -f "$f" ]]; then
          [[ -n "${had[$f]:-}" ]] || { _gdi_files+=("$f"); had[$f]=1; }
        elif [[ -d "$f" && -z "${had[$f]:-}" ]] && _is_git_dir "$f"; then
          _gdi_dirs+=("$f"); had[$f]=1
        fi
      done
    done
    if (( gskip > 5 )); then
      printf 'WARNING: … and %d more submodules of %s were not followed, for the same reasons.\n' "$((gskip - 5))" "$(_q "$g")" >&2
    fi
  done
  # Every waiting git directory that has gained a worktree is read; repeated
  # until none does.
  gchanged=""
  for g in ${gpend[@]+"${!gpend[@]}"}; do
    for (( q = 0; q < ${#gtop_g[@]}; q++ )); do
      if [[ "${gtop_g[q]}" == "$g" ]]; then unset 'gpend[$g]'; _gdi_ionly+=("$g"); gchanged=1; break; fi
    done
  done
  [[ -n "$gchanged" ]] || break
  done
  if (( _gdi_warned > 5 )); then
    printf 'WARNING: … and %d more .git files or commondirs in %s name what this launch cannot protect.\n' "$((_gdi_warned - 5))" "$(_term "$5")" >&2
  fi
  # Named only if its index records a submodule: a removed or deinit'd submodule,
  # or a linked worktree checked out outside every mount, is ordinary (review of
  # 4e91bf3). ls-files lists the same whatever worktree, so $g serves as one.
  for g in ${gpend[@]+"${!gpend[@]}"}; do
    [[ -z "$gover" ]] || break
    [[ -f "$g/index" ]] || continue
    # A linked worktree checked out where the agent cannot write is not its to steer.
    if [[ -f "$g/gitdir" ]]; then
      tgt=""; _git_ptr_read "$g/gitdir" tgt gitdir || true
      # Only a real one: the agent can rewrite gitdir, and a path that leads
      # nowhere (GIT-6), or to any existing file (automated security review of
      # 3fd28c7), silenced the worktree's submodules. Quiet only for a regular
      # .git file outside every writable mount whose own gitdir: names this git
      # directory back (G80).
      # Physically where it says: a .. or a link on the way made a .git inside a
      # writable mount pass as outside them (automated security review of efbfcc3).
      # bash's spelling for "no link on the way", the one on disk for "outside
      # every mount": in another case on a filesystem that ignores case it is the
      # same .git file (third review of the GIT-38 fix).
      if [[ "$tgt" == /* && "${tgt,,}" == */.git && -f "$tgt" && ! -L "$tgt" ]] \
         && _cd_bash back "${tgt%/*}" && [[ "$back/${tgt##*/}" == "$tgt" ]] \
         && _canon_lex back "$tgt" && ! _in_writable "$back"; then
        back=""; _git_ptr_read "$tgt" back || true
        back="${back#gitdir: }"
        if [[ "$back" != /* ]]; then back="${tgt%/*}/$back"; fi
        if [[ "$(cd "$back" 2>/dev/null && pwd -P)" == "$g" ]]; then continue; fi
      fi
    fi
    links=()
    _git_index_read links "$g" "$g" || continue
    for rec in ${links[@]+"${links[@]}"}; do
      [[ "${rec%% *}" == 160000 ]] || continue
      printf 'WARNING: no worktree is known for %s, so the submodules its index records are not followed.\n' "$(_term "$g")" >&2
      break
    done
  done
  return 0
}

# _git_usable: succeeds when git runs on this host. `command -v` is not enough:
# macOS keeps /usr/bin/git on PATH whether or not the Command Line Tools are
# installed, and without them it only offers to install them and exits 1, so
# every key read through it came back unset (review of the GIT-24 fix, M2).
# Asked once, at the start of run_container (and of launcher_ro_overlay, for a
# caller that runs it alone) in the launcher's own shell, and kept, so a shim
# that opens an installer is not run once per read.
_git_usable() {
  local g p
  local -a t=()
  if [[ -z "$_git_ok" ]]; then
    _git_ok=0
    if ! g="$(command -v git 2>/dev/null)"; then
      :
    elif [[ "$g" -ef /usr/bin/git && "$(uname -s 2>/dev/null)" == Darwin ]] \
         && ! { p="$(xcode-select -p 2>/dev/null)" && [[ -n "$p" && -x "$p/usr/bin/git" ]]; }; then
      # Without a developer directory holding a git (the Command Line Tools,
      # or Xcode), running the shim opens the tools' installer. -p alone can
      # name one since removed (third review of the GIT-24 fix), and fails
      # outright on a Mac that never had them, where an empty answer made the
      # test the shim's own /usr/bin/git (review of the GIT-28 fix, L2). -ef,
      # not ==: through PATH it can be /usr//bin/git, or a link to it.
      :
    else
      # A known answer, not only an exit status: a git older than 2.18 has no
      # --type=bool, which every read here uses, and would read every key as
      # unset (re-review of the GIT-24 fix).
      read -r -a t <<< "$(_timeout_prefix 10) "
      if [[ "$(GIT_DIR=/dev/null "${t[@]}" git config --file /dev/null --type=bool --default true \
              --get ai-launcher.probe 2>/dev/null)" == true ]]; then
        _git_ok=1
      fi
    fi
  fi
  (( _git_ok ))
}

# _git_config_bool <config-file> <key>: succeeds when git reads the key as true
# (--type=bool). Where git does not run it fails: there is nothing to read a
# config with. An awk parser stood in for git once and misread its syntax both
# ways ("true" and 1k as off, \t0 as on), and no single guess is safe for every
# caller (bugs review GIT-24; G98). A caller for which "off" is not the cautious
# answer asks _git_usable itself; the include walk need not, since with no git
# there are no includes to walk.
_git_config_bool() {
  local v
  _git_usable || return 1
  v="$(_git_file_config "$1" --type=bool --get "$2" 2>/dev/null)" || return 1
  [[ "$v" == true ]]
}

# _git_config_get <out-var> <config-file> <key>: a key's value from one git
# config file, read by git, into <out-var> as git has it: up to the NUL git ends
# it with, a trailing newline included ($(...) dropped one, and a core.worktree
# naming `wt<newline>` was read as a decoy `wt`; review of the GIT-31 fix).
# Fails when it is unset, and always where git does not run: then core.hooksPath
# unset lists the hooks in hooks/, and a core.worktree is not followed, which the
# launch's WARNING names when it protects a git directory (GIT-24).
_git_config_get() {
  local -n _gcg_out=$1
  _gcg_out=""
  _git_usable || return 1
  IFS= read -r -d '' _gcg_out < <(_git_file_config "$2" --null --get "$3" 2>/dev/null) || { _gcg_out=""; return 1; }
}

# _git_exec_keys <config-file>...: the keys these git config files set that make
# git run a program, or read another file of keys (an include), NUL-separated,
# each once, values never printed. Read with git, which runs nothing from a
# file it only lists; with no git on this host, none. A boolean core.fsmonitor
# is git's own daemon, and an alias or a submodule's update runs a program only
# when it starts with '!'. A file that does not exist sets nothing.
_git_exec_keys() {
  local f rec k v
  local re='^(core\.(fsmonitor|hookspath|sshcommand|editor|pager|askpass|gitproxy|alternaterefscommand)|sequence\.editor|pager\..+|diff\.external|diff\..+\.(command|textconv)|merge\..+\.driver|filter\..+\.(clean|smudge|process)|credential\.(.+\.)?helper|gpg\.(.+\.)?program|remote\..+\.(uploadpack|receivepack)|(difftool|mergetool|man|browser)\..+\.(cmd|path)|web\.browser|include\.path|includeif\..+\.path|alias\..+|submodule\..+\.update|trailer\..+\.(command|cmd)|gpg\.ssh\.defaultkeycommand|sendemail\.(.+\.)?(tocmd|cccmd|headercmd|sendmailcmd|smtpserver)|protocol\.(ext\.)?allow|imap\.tunnel|instaweb\.httpd|guitool\..+\.cmd|interactive\.difffilter|tar\..+\.command|hook\..+\.command)$'
  local -A had=()
  _git_usable || return 0
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then continue; fi
    while IFS= read -r -d '' rec; do
      k="${rec%%$'\n'*}"; v=""
      if [[ "$rec" == *$'\n'* ]]; then v="${rec#*$'\n'}"; fi
      if [[ ! "$k" =~ $re || -n "${had[$k]:-}" ]]; then continue; fi
      case "$k" in
        core.fsmonitor) if [[ "${v,,}" =~ ^(true|false|yes|no|on|off|-?[0-9]+)?$ ]]; then continue; fi ;;
        alias.*|submodule.*.update) if [[ "$v" != '!'* ]]; then continue; fi ;;
        # A path runs a program; a host name does not (review of the batch 10 branch).
        sendemail.smtpserver|sendemail.*.smtpserver) if [[ "$v" != /* ]]; then continue; fi ;;
      esac
      had[$k]=1
      printf '%s\0' "$k"
    done < <(_git_file_config "$f" --null --list 2>/dev/null)
  done
}

# _git_runs <git dir> <keys-out> <hooks-out>: what in this git directory makes
# the host's git run a program, names only, comma-separated: the keys its config
# sets (_git_exec_keys; config.worktree too, as the first protection reads it),
# ten at most and then a count, and the hooks git would run — a name from
# githooks(5), executable, through a link too — unless core.hooksPath sends git
# elsewhere (a key named above). A commondir naming another directory sends git
# there for config and hooks; one this launch protected was frozen, and
# reported, then, so only config.worktree counts (a linked worktree's, from
# `git worktree add`), else that one's. A commondir or hooks/ that is a link, or
# a commondir that leads nowhere, cannot be checked here and is named as such.
_git_runs() {
  local -n _gr_k=$2 _gr_h=$3
  local g="$1" c="$1" cd="" e hp="" own=1 n=0
  local -a ek=() cf=()
  _gr_k=""; _gr_h=""
  # git reads a commondir through a link (automated security review of 7121741).
  if [[ -L "$g/commondir" ]] || [[ -e "$g/commondir" && ! -f "$g/commondir" ]]; then
    _gr_k="commondir, a link or not a file: what git reads through it is not checked"; return 0
  fi
  if [[ -f "$g/commondir" ]]; then
    _git_ptr_read "$g/commondir" cd || true
    if [[ -n "$cd" && "$cd" != ./ ]]; then
      _cd_phys c "$g" "$cd" || c=""
      if [[ -z "$c" ]]; then _gr_k="commondir, which leads nowhere it can be checked"; return 0; fi
      if [[ -n "${_git_launch_seen[$c]:-}" ]]; then own=""; fi
    fi
  fi
  if [[ -n "$own" ]]; then cf+=("$c/config"); fi
  cf+=("$g/config.worktree")
  mapfile -d '' -t ek < <(_git_exec_keys "${cf[@]}")
  for e in ${ek[@]+"${ek[@]:0:10}"}; do _gr_k+="${_gr_k:+, }$e"; done
  if (( ${#ek[@]} > 10 )); then _gr_k+=", and $(( ${#ek[@]} - 10 )) more"; fi
  [[ -n "$own" ]] || return 0
  # Where git does not run both reads fail, so hooks/ is listed whatever
  # core.hooksPath says. That may name a hook git would not run; the ones in a
  # core.hooksPath directory, which _git_exec_keys would name with git, go
  # unnamed (GIT-24; G98).
  _git_config_get hp "$c/config" core.hooksPath || hp=""
  if [[ -z "$hp" && -f "$g/config.worktree" ]] && _git_config_bool "$c/config" extensions.worktreeConfig; then
    _git_config_get hp "$g/config.worktree" core.hooksPath || hp=""
  fi
  [[ -z "$hp" ]] || return 0
  # git follows a hooks/ that is a link, and runs what it finds there.
  if [[ -L "$c/hooks" ]]; then _gr_h="hooks/, a link: what git runs through it is not checked"; return 0; fi
  if [[ -d "$c/hooks" ]]; then
    for e in "${git_hook_names[@]}"; do
      if [[ -f "$c/hooks/$e" && -x "$c/hooks/$e" ]]; then _gr_h+="${_gr_h:+, }$e"; (( ++n )); fi
    done
  fi
  return 0
}

# _git_ident <path>: what is at <path> — its device, inode and birth time (0
# where the filesystem keeps none), and a link's target text: a git directory
# made again at a path, even on a reused inode, or a .git link repointed, is
# another one (automated security review of 7121741; review of 7121741). The
# birth time is to the nanosecond: in whole seconds, overlayfs gave a directory
# removed and made again within the second its inode and its second back, and
# the re-made repository went unreported (G93 at the floor, on Colima).
_git_ident() {
  local i=""
  if (( _launcher_stat_gnu )); then i="$(stat -c '%d %i %.9W' -- "$1" 2>/dev/null)" || i=""
  else i="$(stat -f '%d %i %.9FB' -- "$1" 2>/dev/null)" || i=""; fi
  [[ -n "$i" ]] || i="?"
  if [[ -L "$1" ]]; then i+=" -> $(readlink -- "$1" 2>/dev/null)"; fi
  printf '%s' "$i"
}

# The repositories whose keys and hooks a launch has named, one `<identity>
# <path>` line each (_git_ident; a path with a newline is not recorded). The
# first protection — the launch that makes the commondir placeholder — names
# them. A repository whose placeholder was there already, made by an earlier
# engine or planted with one the agent made, never had that moment, and is
# named once too (feature-gaps review GAP-12). Recorded only after the NOTE is
# printed, so a launch refused on the way reports it again. Read once per
# launch. Machine-local, like image-projects.conf, and never mounted.
_git_reported_file="${ai_containers_root}/git-reported.conf"
declare -A _git_reported_set=()
# The files git reads by name in every git directory launcher_ro_overlay finds,
# protected or under a read-only overlay, that _ro_fifo_search checks for a
# second hard link (GIT-31): `file` (config, config.worktree, commondir, a .git
# file) or `hooks` (a hooks/ directory: the names git runs, a link followed).
declare -A _ro_links_check=()
_git_reported_loaded=""
_git_reported_load() {
  local line
  [[ -z "$_git_reported_loaded" ]] || return 0
  _git_reported_loaded=1
  [[ -f "$_git_reported_file" && ! -L "$_git_reported_file" && -r "$_git_reported_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] || _git_reported_set[$line]=1
  done < "$_git_reported_file" 2>/dev/null || true
}
# A second argument, `hooks`, is the record of a launch where git did not run,
# which named the hooks and read no key: `<identity> hooks:<path>`, a line no
# physical path can make, so an older engine matches it to nothing.
_git_reported() {    # <git dir, physical> [hooks]: rc 0 when it is in the record
  [[ "$1" != *$'\n'* ]] || return 1
  _git_reported_load
  [[ -n "${_git_reported_set["$(_git_ident "$1") ${2:+$2:}$1"]:-}" ]]
}
_git_report_record() {   # <git dir, physical> [hooks]: add it, once, on a line of its own; quiet
  local line last=""
  [[ "$1" != *$'\n'* ]] || return 0
  _git_reported_load
  line="$(_git_ident "$1") ${2:+$2:}$1"
  [[ -z "${_git_reported_set[$line]:-}" ]] || return 0
  _git_reported_set[$line]=1
  [[ ! -L "$_git_reported_file" && ( ! -e "$_git_reported_file" || ( -f "$_git_reported_file" \
     && -r "$_git_reported_file" && -w "$_git_reported_file" ) ) ]] || return 0
  mkdir -p "$ai_containers_root" 2>/dev/null || return 0
  if [[ -s "$_git_reported_file" ]]; then
    { last="$(tail -c 1 "$_git_reported_file")" || last=""; } 2>/dev/null
    if [[ -n "$last" ]]; then line=$'\n'"$line"; fi
  fi
  { printf '%s\n' "$line" >> "$_git_reported_file"; } 2>/dev/null || true
  return 0
}

# _ro_files_snapshot <file>...: what each file bound read-only on its own holds
# at launch, kept for _ro_files_restore (bugs review GIT-41). A container's
# kernel compares names case-sensitively, so .git/CONFIG is not the mount point
# of config's read-only bind; a host share that ignores case (virtiofs on macOS,
# measured on Colima) opens it as config, and the write lands. A directory has
# one dentry in the guest, so a directory bind holds under any spelling, and only
# these files need it. Only a file whose own name ignores case here is kept:
# elsewhere the container cannot reach it, and a change while the container ran
# was made on the host, which putting it back would undo. Read under the bound
# every read of a file the agent can write gets (_rd_run); one over 1 MiB is
# named and not kept.
_ro_files_snapshot() {
  local f n o m k
  (( $# )) || return 0
  for f; do
    n="${f##*/}"; o="${f%/*}/${n~~}"
    [[ "$o" != "$f" && ! -L "$o" && "$o" -ef "$f" ]] || continue
    if [[ -z "$_ro_snap_dir" ]]; then
      _ro_snap_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-containers-ro.XXXXXX" 2>/dev/null)" || {
        _ro_snap_dir=""
        printf 'WARNING: could not make a directory to keep the read-only git files in, so one the\n' >&2
        printf '         container writes under a name spelled in another case is not put back.\n' >&2
        return 0
      }
    fi
    k="$_ro_snap_dir/${#_ro_snap_src[@]}"
    if [[ -f "$f" && ! -L "$f" ]] && _rd_run "$f" head -c 1048577 -- "$f" > "$k" 2>/dev/null \
       && (( $(wc -c < "$k") <= 1048576 )); then
      if (( _launcher_stat_gnu )); then m="$(stat -c '%a' -- "$f" 2>/dev/null)"; else m="$(stat -f '%Lp' "$f" 2>/dev/null)"; fi
      [[ "$m" =~ ^[0-7]{3,4}$ ]] || m=644
      _ro_snap_src+=("$f"); _ro_snap_mode+=("$m")
    else
      rm -f "$k"
      printf 'WARNING: %s could not be kept as it is (over 1 MiB, or not a regular file), so if\n' "$(_term "$f")" >&2
      printf '         the container writes it under a name spelled in another case, it is not put back.\n' >&2
    fi
  done
}

# _ro_files_restore: when the container exits, each file _ro_files_snapshot kept
# that no longer holds what it did — changed, removed, or replaced by a link or a
# FIFO (not read: the type is checked first, and the compare is bounded) — is put
# back, and named in a WARNING. Its directory is still writable from a sibling
# container, so nothing there is opened or moved by a name another process could
# plant: the copy is made by an exclusive create under a random name, with its
# mode from the umask (no chmod, which follows a link), and renamed over the file
# without following a link at the destination. What stood there is never moved:
# a regular file's content, or a link's target, is copied into a directory of the
# launcher's own, ~/.ai-containers/restored/<time>-<pid>, which the WARNING names
# (the change may be the user's own, made on the host while the container ran:
# git push -u, git remote add). Not covered: the host's git reads the changed
# file until the container exits, and a launcher killed before then puts nothing
# back. Never a refusal, and the container's exit status stays the launcher's.
_ro_files_restore() {
  local i f k tmp m rd="" keep msg gone
  local -a t=()
  (( ${#_ro_snap_src[@]} )) || return 0
  read -r -a t <<< "$(_timeout_prefix 2) "
  for i in "${!_ro_snap_src[@]}"; do
    f="${_ro_snap_src[i]}"; k="$_ro_snap_dir/$i"
    if [[ -f "$f" && ! -L "$f" ]] && "${t[@]}" cmp -s "$k" "$f" 2>/dev/null; then continue; fi
    # What stood there, kept where only the launcher writes.
    keep=""; gone=""
    [[ -e "$f" || -L "$f" ]] || gone=1
    if [[ -z "$rd" ]]; then
      rd="$ai_containers_root/restored/$(date +%Y%m%d%H%M%S)-$$"
      if ! { mkdir -p "$ai_containers_root" && { mkdir -m 700 "$ai_containers_root/restored" \
                 || [[ -d "$ai_containers_root/restored" && ! -L "$ai_containers_root/restored" ]]; } \
             && mkdir -m 700 "$rd"; } 2>/dev/null || [[ -L "$rd" || ! -d "$rd" ]]; then rd=-; fi
    fi
    if [[ "$rd" != - ]]; then
      keep="$rd/$i-${f##*/}"
      if [[ -L "$f" ]]; then
        { printf 'a link to: %s\n' "$(readlink -- "$f")" > "$keep"; } 2>/dev/null || keep=""
      elif [[ -f "$f" ]]; then
        "${t[@]}" head -c 1048576 -- "$f" > "$keep" 2>/dev/null || keep=""
      elif [[ -e "$f" ]]; then
        { printf 'not a regular file (a FIFO, a device or a directory)\n' > "$keep"; } 2>/dev/null || keep=""
      else
        keep=""
      fi
    fi
    m="${_ro_snap_mode[i]}"; m="${m: -3}"
    tmp="${f%/*}/.${f##*/}.restore-$$-$RANDOM$RANDOM"
    if ( umask "$(printf '%03o' $(( 0777 & ~8#$m )))"; set -C; cat -- "$k" > "$tmp" ) 2>/dev/null \
       && [[ -f "$tmp" && ! -L "$tmp" ]] \
       && { mv -T -f -- "$tmp" "$f" 2>/dev/null || { [[ ! -d "$f" || -L "$f" ]] && mv -h -f -- "$tmp" "$f" 2>/dev/null; }; }; then
      msg="put back as it was at launch"
    else
      rm -f -- "$tmp" 2>/dev/null
      msg="could NOT be put back; check it before running git there"
    fi
    printf 'WARNING: %s changed while the container ran: on this host the container can write\n' "$(_term "$f")" >&2
    printf '         it under a name spelled in another case, past its read-only mount. It is %s.\n' "$msg" >&2
    if [[ -n "$keep" ]]; then
      printf '         What it held is kept in %s;\n' "$(_term "$keep")" >&2
      printf '         if you changed it on the host yourself meanwhile: diff %s %s\n' "$(_q "$f")" "$(_q "$keep")" >&2
    elif [[ -n "$gone" ]]; then
      printf '         (It had been removed.)\n' >&2
    else
      printf '         What it held could not be kept.\n' >&2
    fi
  done
}

# _git_after_session: the launch scan runs once, so a git directory the agent
# makes during the session is protected only by the next launch, and the host's
# git would run what it holds before then (GAP-12). When the container exits,
# the writable mounts the launch scanned are scanned again, and named in a
# WARNING: every new git directory that makes git run something (_git_runs) or
# cannot be listed, and every new .git file or link, which can send git to
# another directory. A plain `git init` or clone holds nothing git runs. "New"
# is by identity (_git_ident), so a .git link repointed is new.
#   Each mount is scanned in a subshell of its own, since git_dirs_in refuses by
# exiting; that, a scan stopped past SANDBOX_GIT_MAX, a bounded read cut off
# (which signals this process), or the deadline (AI_CONTAINERS_RESCAN_SECONDS,
# 30 s) is said to have cut the search short — never a refusal: the container
# has already run. Index reads start afresh: the index stays writable, and a
# gitlink added in the session leads where the launch never looked (review of
# 7121741). Only on a normal return from docker run.
_git_after_session() {
  (( ${#_git_scan_srcs[@]} )) || return 0
  local _gas_cut="" i rec
  local -a recs=() run=() away=()
  local -A named=()
  trap '_gas_cut=1' USR1
  mapfile -d '' -t recs < <(
    exec 2>/dev/null
    # What git_dirs_in reads of the launch's own state: the writable binds, and the bound.
    bsrc=(${_git_bsrc[@]+"${_git_bsrc[@]}"})
    gitmax="${SANDBOX_GIT_MAX:-200}"; _rd_errfd=""
    # A read cut off here only says the search was cut short, so it gets the
    # first bound: the longer one would lengthen a scan after the session.
    _rd_long_secs="$_rd_secs"
    lim="${AI_CONTAINERS_RESCAN_SECONDS:-30}"; [[ "$lim" =~ ^[0-9]{1,6}$ ]] || lim=30
    deadline=$(( SECONDS + 10#$lim ))
    for src in "${_git_scan_srcs[@]}"; do
      if (( SECONDS >= deadline )); then printf 'C\0\0\0'; break; fi
      [[ -d "$src" ]] || continue
      (
        _gir_cache=(); _gir_tmp=""; trap 'rm -rf "${_gir_tmp:-}"' EXIT
        gdirs=(); gfiles=(); glinks=(); gunr=(); _gdi_over=()
        git_dirs_in gdirs gfiles glinks gunr "$src" || true
        if (( ${#_gdi_over[@]} )); then printf 'C\0\0\0'; fi
        for f in ${gdirs[@]+"${gdirs[@]}"} ${gunr[@]+"${gunr[@]}"} ${gfiles[@]+"${gfiles[@]}"} ${glinks[@]+"${glinks[@]}"}; do
          if (( SECONDS >= deadline )); then printf 'C\0\0\0'; exit 0; fi
          [[ "${_git_launch_seen[$f]:-}" != "$(_git_ident "$f")" ]] || continue
          if [[ -L "$f" ]]; then printf 'A\0%s\0%s\0' "$f" "a link"
          elif [[ -f "$f" ]]; then printf 'A\0%s\0%s\0' "$f" "a .git file"
          elif [[ ! -r "$f" || ! -x "$f" ]]; then printf 'R\0%s\0%s\0' "$f" "cannot be listed, so it was not checked"
          else
            k=""; h=""; _git_runs "$f" k h || true
            # Where git does not run no key is read, so every new one is named
            # (re-review of the GIT-24 fix).
            if ! _git_usable; then k="${k:-not read, git does not run on this host}"; fi
            if [[ -n "$k$h" ]]; then printf 'R\0%s\0%s\0' "$f" "${k:+config: $k}${k:+${h:+; }}${h:+hooks: $h}"; fi
          fi
        done
        exit 0
      ) || printf 'C\0\0\0'
    done
  ) || true
  trap 'exit 1' USR1
  for (( i = 0; i + 2 < ${#recs[@]}; i += 3 )); do
    case "${recs[i]}" in
      C) _gas_cut=1 ;;
      R|A)
        [[ -z "${named[${recs[i+1]}]:-}" ]] || continue; named[${recs[i+1]}]=1
        rec="$(_term "${recs[i+1]}") ($(_term "${recs[i+2]}"))"
        if [[ "${recs[i]}" == R ]]; then run+=("$rec"); else away+=("$rec"); fi ;;
    esac
  done
  if (( ${#run[@]} )); then
    printf 'WARNING: the session made git repositories in a writable mount that this launch did\n' >&2
    printf '         not protect, and your host'\''s git could run what they hold:\n' >&2
    for rec in "${run[@]:0:20}"; do printf '           %s\n' "$rec" >&2; done
    if (( ${#run[@]} > 20 )); then printf '           … and %d more\n' "$(( ${#run[@]} - 20 ))" >&2; fi
    printf '         Review them on the host before you run git there; the next launch protects them.\n' >&2
  fi
  if (( ${#away[@]} )); then
    printf 'WARNING: the session made .git files or links in a writable mount; each can send your\n' >&2
    printf '         host'\''s git to another git directory, whose config and hooks it would run:\n' >&2
    for rec in "${away[@]:0:20}"; do printf '           %s\n' "$rec" >&2; done
    if (( ${#away[@]} > 20 )); then printf '           … and %d more\n' "$(( ${#away[@]} - 20 ))" >&2; fi
    printf '         Check where each leads before you run git there.\n' >&2
  fi
  if [[ -n "$_gas_cut" ]]; then
    printf 'WARNING: the writable mounts could not all be searched for git repositories the session\n' >&2
    printf '         made (past SANDBOX_GIT_MAX, a refusal, a read cut off, or the time limit). Launch\n' >&2
    printf '         again before you run git in them: the next launch protects, or refuses, what is there.\n' >&2
  fi
  return 0
}

# _git_file_config <config-file> <git-config-args>...: git config on one FILE,
# never on the repository the launcher happens to run from. A git started inside
# a repository reads its config first — includes and all — and the launcher runs
# from inside the project, whose config can include a file the agent writes: an
# include loop there made every such call die, silencing every check built on it
# (tests/test-git-internals-ro-config.sh G30). GIT_DIR=/dev/null stops the discovery.
_git_file_config() {
  local f="$1"; shift
  # A regular file only (-f follows a link to one): git config blocks on a FIFO,
  # and a directory the agent made a git directory of can hold one as its config
  # (review of 1a30bb4; G65).
  [[ -f "$f" ]] || return 1
  GIT_DIR=/dev/null _rd_run "$f" git config --file "$f" "$@"
}

# _git_walk_keys <config-file>: every include.path and includeIf.*.path the file
# sets — whatever the condition, since one that does not hold today may hold
# tomorrow — and its core.hooksPath and core.worktree, each as `<key>\n<value>`
# (the key as git prints it, in lower case), NUL-separated, in the file's order.
# One read gives the include walk and the core.hooksPath check what they need
# (a read each cost 150 repositories of six includes 27% more; review of the
# GIT-35 fix). With no git, none.
_git_walk_keys() {
  _git_usable || return 0
  _git_file_config "$1" --null --get-regexp '^(include(if\..*)?\.path|core\.(hookspath|worktree))$' 2>/dev/null || true
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
  docker run --rm --pull=never --entrypoint bash \
    -v "$base_vol":/src:ro \
    -v "$wc_vol":/dst \
    "$image_name" -c 'cp -a /src/. /dst/'
}

split_env_list() {  # $1=raw value (e.g. "$REPOS", "$EXTRA_MOUNTS", "$PREVIEW_PORTS")
  # Word-split a whitespace-separated env list WITHOUT pathname expansion.
  # Unquoted `for x in $VAR` splits on $IFS but also globs, so a value like
  # "*.txt" silently becomes whatever the launch directory happens to contain.
  # `set -f` blocks that; the prior state is captured and restored so this never
  # leaks noglob into the caller. Prints one entry per line; prints NOTHING for
  # an empty/unset value — callers rely on that (`while IFS= read -r … done < <(…)`
  # correctly iterates zero times, rather than once over an empty string).
  #
  # An intermediate fix used `IFS=' ' read -r -a … <<< "$raw"` instead: `read`
  # only splits WITHIN a single line and stops at the first newline regardless
  # of $IFS, so a value like $'x\ny' silently kept "x" and dropped "y" with no
  # warning. This word-splits on $IFS (space/tab/newline) the same way the old
  # unquoted `(${value})` did, matching what `set -f` alone is missing from that
  # original form.
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 0
  local -a entries=()
  local noglob=0
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206  # intentional unquoted word-split; set -f above blocks pathname expansion
  entries=($raw)
  (( noglob )) || set +f
  local e
  for e in "${entries[@]}"; do
    printf '%s\n' "$e"
  done
}

# Compare two git URLs for "same repository" without pretending to be a URL
# parser: drop the scheme, any user@, a trailing .git and a trailing slash, fold
# scp-form host:path to host/path, and lowercase. ssh://git@h/t/x.git,
# git@h:t/x and https://h/t/X all reduce to h/t/x.
normalise_git_url() {
  local u="$1"
  u="${u%.git}"; u="${u%/}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"; u="${u#git://}"
  u="${u#*@}"
  # scp form is host:path — a colon NOT followed by a port number
  case "$u" in
    *:[0-9]*) : ;;
    *:*)      u="${u%%:*}/${u#*:}" ;;
  esac
  printf '%s' "$u" | tr 'A-Z' 'a-z'
}

# _checkout_origin_url <dir>: the origin URL of the checkout <dir> is in, as
# `git remote get-url origin` printed it, but read from the checkout's config
# FILE (_git_file_config: bounded, no includes), never by running git there:
# get-url read the repository's config, includes and all, with no bound, so a
# FIFO an include named hung the launch, and it ran macOS's git shim without
# asking whether git runs (bugs review GIT-25). The checkout is found as git
# finds it, the nearest .git at or above <dir>; a .git file's gitdir: and a
# linked worktree's commondir are followed, read bounded. Of several URLs the
# first decides, an empty one emptying the list, as git reads them. A shorthand
# (url.<base>.insteadOf) is expanded as get-url expanded it, by
# `git ls-remote --get-url` outside any repository, which reads only your system
# and global config: the registry holds the URL repo.sh cloned, and its seed
# container has no ~/.gitconfig. Fails where git does not run (_git_usable), as
# git -C did where there was no git.
_checkout_origin_url() {
  local d="$1" gd t u=""
  local -a tp=()
  _git_usable || return 1
  while :; do
    if [[ -d "$d/.git" ]]; then gd="$d/.git"; break; fi
    if [[ -f "$d/.git" ]]; then
      # Only CR and LF stripped, as git does (security review of e2741b1).
      t=""; _git_ptr_read "$d/.git" t || true
      [[ "$t" == "gitdir: "* ]] || return 1
      t="${t#gitdir: }"; [[ "$t" == /* ]] || t="$d/$t"
      gd="$t"; break
    fi
    [[ -n "$d" ]] || return 1
    d="${d%/*}"
  done
  if [[ -f "$gd/commondir" ]]; then
    t=""; _git_ptr_read "$gd/commondir" t || true
    [[ -n "$t" ]] || return 1
    [[ "$t" == /* ]] || t="$gd/$t"
    gd="$t"
  fi
  while IFS= read -r -d '' t; do
    if [[ -z "$t" ]]; then u=""; elif [[ -z "$u" ]]; then u="$t"; fi
  done < <(_git_file_config "$gd/config" --null --get-all remote.origin.url 2>/dev/null)
  [[ -n "$u" ]] || return 1
  # `--`: the URL is the agent's to write, and is never read as an option.
  read -r -a tp <<< "$(_timeout_prefix 10) "
  if t="$(GIT_DIR=/dev/null "${tp[@]}" git ls-remote --get-url -- "$u" 2>/dev/null)" && [[ -n "$t" ]]; then
    u="$t"
  fi
  printf '%s' "$u"
}

# Is this host directory already mounted in this container under some name?
#
# A host pointer — VAULT_PATH, SPECS_PATH, DOCS_PATH, ARCHITECTURE_REPO_PATH —
# names a directory. That same directory may already be attached as the primary
# workspace, or as a repo volume listed in REPOS. When it is, mounting it a
# second time is at best a duplicate and at worst a refusal to start: the name
# each pointer wants (/workspace/docs) can already be taken by the repo of the
# same name.
#
# Reported 2026-08-21 by a user whose DOCS_PATH is exported once on the host for
# every project, and whose docs project is itself attached as repo `docs`:
#
#   REPO: /workspace/docs  (rw, shared base volume ai-containers-repo-docs)
#   ERROR: name 'docs' is used by REPOS, but DOCS_PATH also mounts at /workspace/docs.
#
# Nothing was wrong with that setup. The pointer and the repo were the same
# checkout, and the only remedies were to unset a global variable for one
# project or to rename the repo. Now the pointer re-points at the mount that is
# already there — the same accommodation the primary-path case has always had
# (see the DOCS_PATH block), extended to repo volumes.
#
# Identity is PROVEN, never guessed: only a path-sourced repo has a host
# directory to compare, and both sides are resolved with resolve_path first. A
# git-sourced repo records a URL, so a host path cannot be shown to be the same
# checkout and the caller keeps its collision error.
#
# $1 = resolved host directory. Echoes the repo name and returns 0 when found.
pointer_already_mounted_as() {
  local want="$1" name
  # 1. The same DIRECTORY, for a path-sourced repo. Exact identity.
  if (( ${#repo_source_real[@]} )); then
    for name in "${!repo_source_real[@]}"; do
      if [[ "${repo_source_real[$name]}" == "$want" ]]; then
        printf '%s' "$name"
        return 0
      fi
    done
  fi
  # 2. The same REPOSITORY, for a git-sourced repo. The registry holds the URL
  # it was cloned from and there is no host directory to compare, so ask the
  # pointer's own checkout what it came from. This is the case a user hits when
  # the project they work in was seeded with `repo.sh add <name> <git-url>` —
  # reported 2026-08-21, where DOCS_PATH and the repo were the same repository
  # and the launcher could not tell.
  #
  # "Same upstream" is a weaker claim than "same directory", and deliberately
  # enough: what the caller needs to decide is whether mounting again would be a
  # DUPLICATE, and two checkouts of one repository at /workspace/docs and
  # /workspace/docs is exactly that. A second checkout you genuinely want beside
  # the first belongs in REPOS or EXTRA_MOUNTS under its own name.
  # Read only with a git-sourced repo to compare it with: the agent can write
  # the checkout's config.
  local want_url=""
  if (( ${#repo_source_url[@]} )); then want_url="$(_checkout_origin_url "$want" || true)"; fi
  if [[ -n "$want_url" ]]; then
    want_url="$(normalise_git_url "$want_url")"
    for name in "${!repo_source_url[@]}"; do
      if [[ "${repo_source_url[$name]}" == "$want_url" ]]; then
        printf '%s' "$name"
        return 0
      fi
    done
  fi
  return 1
}

# REPOS_PATH as the container must see it. The same plugins run on the host, so
# a host profile exporting REPOS_PATH as a HOST directory is ordinary, and
# forwarding it verbatim handed the container a path that does not exist there
# (reported 2026-10-10). Everything the launcher mounts lands under /workspace,
# so a value there is an in-container path and is kept. Any other value names a
# host directory: it is mapped through the first host bind holding it (when
# binds nest, each gives a path to the same files), or becomes /workspace when
# none does, the usual case being a directory that HOLDS the mounted checkouts.
#
# $1 = configured value (may be empty), $2.. = docker mount flags. Echoes the
# in-container path.
repos_path_in_container() {
  local val="$1"; shift
  case "$val" in
    "") printf '/workspace'; return 0 ;;
    /workspace|/workspace/*) printf '%s' "$val"; return 0 ;;
  esac
  local host arg src dst
  host="$(resolve_path "${val/#\~/$HOME}")"
  for arg in "$@"; do
    # A host bind's value is `/src:/workspace/<name>[:mode]`; a volume's source
    # does not start with `/`, and holds no host directory to map.
    [[ "$arg" == /*:/workspace* ]] || continue
    src="${arg%%:/workspace*}"
    dst="${arg#"$src:"}"; dst="${dst%%:*}"
    if [[ "$host" == "$src" || "$host" == "$src"/* ]]; then
      printf '%s%s' "$dst" "${host#"$src"}"
      return 0
    fi
  done
  printf '/workspace'
}

# Device and inode of a path, "<dev> <ino>": GNU `stat -c` or BSD `stat -f`
# (macOS has only the latter). The platform is probed once, on `/` (always
# searchable — a probe of `.` fails in an unsearchable working directory and
# would mistake GNU for BSD), as tests/portability.sh does, rather than falling
# back on failure: GNU `stat -f` does not fail, it reports the FILESYSTEM
# instead. Anything that is not two numbers is discarded, so a misdetection
# degrades to the entrypoint's skip instead of handing it garbage. Prints
# nothing and returns non-zero when the path cannot be stat'ed.
if stat -c '%i' / >/dev/null 2>&1; then _launcher_stat_gnu=1; else _launcher_stat_gnu=0; fi
_launcher_dev_ino() {
  local out
  if (( _launcher_stat_gnu )); then out="$(stat -c '%d %i' "$1" 2>/dev/null)"; else out="$(stat -f '%d %i' "$1" 2>/dev/null)"; fi
  [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || return 1
  printf '%s\n' "$out"
}

# Colima's file sharing does not keep device:inode across a bind, so the host's
# stat is no use to the entrypoint's check there; Colima's VM's is. It reports
# the device:inode every container of that VM sees, a swap made by a concurrent
# container included, since that one is made in the VM (PLAT-3, GAP-11; measured
# on Colima 0.10.3 with virtiofs). A change made on the Mac shows in the VM about
# a second late, but the containers see it through the same cache, so the two
# never disagree. Nothing here decides that the check runs: the entrypoint still
# compares the verify directory's own device:inode first, and skips with its
# NOTE: unless the VM asked is the one the container runs in.
#
# _colima_profile: the Colima profile whose socket docker uses, or non-zero.
_colima_profile() {
  command -v colima >/dev/null 2>&1 || return 1
  local ep="${DOCKER_HOST:-}" base="${COLIMA_HOME:-$HOME/.colima}" p
  [[ -n "$ep" ]] || ep="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || return 1
  [[ "$ep" == "unix://$base/"*/docker.sock ]] || return 1
  p="${ep#"unix://$base/"}"; p="${p%/docker.sock}"
  [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s\n' "$p"
}
# _vm_dev_ino_load <map> <path>...: fills the associative array <map> with
# path → "dev ino" as Colima's VM sees each path, in one `colima ssh` (~0.3 s).
# The paths go to a fixed command on stdin, NUL-separated, never through the VM's
# shell: the agent names the directories. stat prints each name back, so a path
# the VM cannot stat is simply absent. Returns non-zero off Colima.
_vm_dev_ino_load() {
  # shellcheck disable=SC2178  # a nameref to the caller's associative array
  local -n _vl_map="$1"; shift
  local prof rec rest dev ino tp=()
  prof="$(_colima_profile)" || return 1
  read -r -a tp <<<"$(_timeout_prefix 20)"
  while IFS= read -r -d '' rec; do
    dev="${rec%%:*}"; rest="${rec#*:}"; ino="${rest%%:*}"
    [[ "$dev" =~ ^[0-9]+$ && "$ino" =~ ^[0-9]+$ ]] || continue
    _vl_map["${rest#*:}"]="$dev $ino"
  done < <(printf '%s\0' "$@" | ${tp[@]+"${tp[@]}"} colima ssh -p "$prof" -- xargs -0 stat '--printf=%d:%i:%n\0' -- 2>/dev/null)
  return 0
}

# Set by run_container when it creates a launcher-mount verify dir; removed by
# the EXIT trap below. A global, not a run_container local, so the trap can see
# it, and guarded with :- so `set -u` is satisfied when no dir was made.
_launcher_verify_dir=""
# Where _ro_files_snapshot keeps the read-only git files as they were at launch,
# and which it kept (GIT-41); the directory is removed by the EXIT trap below.
_ro_snap_dir=""
_ro_snap_src=() _ro_snap_mode=()
# The group's directory, physical: launcher_ro_overlay does not scan the group's
# own mounts (those outside /workspace) for git repositories, since the host's git
# never runs there; a directory mounted into /workspace from inside it is scanned
# like any other (G92). Set by run_container.
_git_skip_root=""
_gir_tmp="" _gir_tmp_warned=""
_git_ok=""                  # whether git runs here, asked once (_git_usable)
declare -A _gir_cache=()   # git directory → its read index, once per launch
_fs_deadline=""             # the FIFO search's deadline, once per launch (_ro_fifo_search)
# _ci_path's and _disk_spell's state, never from the environment: _cd_phys_pwd is
# the program run as pwd.
_ci_memo_made="" _ds_cache_made="" _ds_n=0 _cd_phys_pwd="" _caf_made="" _dr_cache_made=""
_u8_loc="" _cfl_made="" _cf_warned="" _wf_made="" _wm_ok=""
# The hooks git runs, by name (githooks(5)); anything else in hooks/ is inert.
git_hook_names=(applypatch-msg pre-applypatch post-applypatch pre-commit
  pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout
  post-merge pre-push pre-receive update proc-receive post-receive post-update
  reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate
  fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist
  p4-pre-submit post-index-change)
_gdi_over=()               # git directories past SANDBOX_GIT_MAX where a scan stopped (GIT-9)
# What the launch scan found (git_dirs_in), by path, and the writable sources it
# scanned: _git_after_session scans them again when the container exits.
declare -A _git_launch_seen=()
_git_scan_srcs=()
# Each .git a scan follows, a file or the directory a mount lies in: the git
# directory, and the checkout git runs hooks in for it (GIT-44), with the
# indices of each git directory's checkouts (a list searched per git directory
# made a launch with 2000 planted .git files quadratic; review of the GIT-44 fix).
_gref_t=() _gref_d=()
declare -A _gref_i=()
# _gref_add <git directory> <checkout>
_gref_add() { _gref_t+=("$1"); _gref_d+=("$2"); _gref_i[$1]+="$(( ${#_gref_t[@]} - 1 )) "; }
_git_bsrc=()               # every writable bind source of the launch (bsrc), for the rescan
trap 'rm -rf "${_launcher_verify_dir:-}" "${_gir_tmp:-}" "${_rd_dir:-}" "${_fs_ml_dir:-}" "${_ro_snap_dir:-}" 2>/dev/null' EXIT

# The agent's identity: numeric, within a 32-bit id, and never root — capsh
# switching 0 to 0 clears no capabilities (bugs review ENV-4). Checked first in
# run_container, before a group is made or a credential copied (review of
# batch 2, F8), and again where launcher_ro_overlay feeds the ids to find.
validate_sandbox_ids() {
  local uid="${SANDBOX_UID:-$(id -u)}" gid="${SANDBOX_GID:-$(id -g)}"
  if [[ ! "$uid" =~ ^[0-9]{1,10}$ || ! "$gid" =~ ^[0-9]{1,10}$ ]] \
     || (( 10#$uid > 4294967294 || 10#$gid > 4294967294 )); then
    printf 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric ids from 0 to 4294967294 (got %q / %q).\n' "$uid" "$gid" >&2
    exit 1
  fi
  if (( 10#$uid == 0 || 10#$gid == 0 )); then
    printf 'ERROR: the agent must not run as root (SANDBOX_UID=%s, SANDBOX_GID=%s).\n' "$uid" "$gid" >&2
    printf '       Launching as root (sudo, a root WSL distro)? Set a non-root identity,\n' >&2
    printf '       e.g. SANDBOX_UID=1000 SANDBOX_GID=1000, for repo.sh as well.\n' >&2
    exit 1
  fi
}

run_container() {
  check_config
  validate_sandbox_ids
  # In the launcher's own shell, before any read: the pointer checks below read
  # a checkout's config in $(…), where neither answer would be kept (GIT-25).
  _rd_prep; _git_usable || true
  # The group is checked before anything is made: a REPOS :rwcopy volume, the
  # output directories (review of batch 11). `host` is refused, and so is a group
  # directory that is a link: through one the container gets whatever it points
  # at, your real $HOME's dot-directories among them, as the removed host group
  # did — and the git scan, which skips the group's own directories, skipped what
  # lay under the link's target (G92).
  local group="${AI_CONTAINER_GROUP:-default}" _gsf
  if [[ "$group" == host ]]; then
    _gsf="$(host_group_source "$script_dir")"
    [[ -z "$_gsf" ]] || printf 'NOTE: AI_CONTAINER_GROUP=host is set in %s.\n' "$(_term "$_gsf")" >&2
  fi
  validate_group_name "$group"
  local _gr="$HOME/.ai-containers/$group" _glt _ghome _gpar _ghid
  _ghome="$(cd "$HOME" 2>/dev/null && pwd -P)" || _ghome=""
  # $HOME's device:inode: an alias of it by another path — a bind mount, a macOS
  # firmlink, another case on a case-insensitive filesystem — has the same pair
  # where its path differs (LNCH-19).
  _ghid="$(_launcher_dev_ino "$HOME/.")" || _ghid=""
  if [[ -L "$_gr" ]]; then
    _glt="$(cd "$_gr" 2>/dev/null && pwd -P)" || _glt=""
    _gpar="$(cd "$HOME/.ai-containers" 2>/dev/null && pwd -P)" || _gpar=""
    printf 'ERROR: the group directory %s is a link%s; a group must be a directory of its own:\n' \
      "$(_q "$_gr")" "${_glt:+ (to $(_q "$_glt"))}" >&2
    printf '       through a link the container gets whatever it points at, writable.\n' >&2
    # The way out depends on where it leads: `cp -a` of $HOME would copy the whole
    # home, every other group with it (review of 18011da; G92).
    if [[ ! -e "$_gr" ]]; then
      printf '       It leads nowhere: remove it (rm %s) and launch again.\n' "$(_q "$_gr")" >&2
    elif [[ -z "$_glt" ]]; then
      printf '       It leads to something that is not a directory you can enter: remove it (rm %s)\n' "$(_q "$_gr")" >&2
      printf '       and launch again.\n' >&2
    elif [[ "$_glt" == "$_ghome" ]] || { [[ -n "$_ghid" ]] && [[ "$(_launcher_dev_ino "$_gr/.")" == "$_ghid" ]]; }; then
      printf '       It leads to your home directory. Remove it (rm %s) and launch with\n' "$(_q "$_gr")" >&2
      printf '       AI_CONTAINER_GROUP_INIT=from:host, which makes the group as a copy of your credentials.\n' >&2
    elif [[ "${_glt%/*}" == "$_gpar" && "${_glt##*/}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "${_glt##*/}" != host ]]; then
      printf '       It leads to the group %s: use AI_CONTAINER_GROUP=%s, or remove the link (rm %s)\n' \
        "$(_q "${_glt##*/}")" "$(_q "${_glt##*/}")" "$(_q "$_gr")" >&2
      printf '       and launch with AI_CONTAINER_GROUP_INIT=from:%s for a copy of it.\n' "$(_q "${_glt##*/}")" >&2
    elif [[ -n "$_ghome" && "$_glt" == "$_ghome"/* ]]; then
      # Inside $HOME: a directory of yours, the group's own made beside it.
      printf '       Remove the link (rm %s) and launch again: the group is made as a directory of its own.\n' "$(_q "$_gr")" >&2
    else
      printf '       To keep groups on another disk, link ~/.ai-containers itself, not one group.\n' >&2
    fi
    exit 1
  fi
  # A group directory that IS your home by another route — ~/.ai-containers moved
  # to $HOME's parent and the group named after $HOME — mounts the real
  # dot-directories as surely as a link (review of 18011da; G92).
  if [[ -d "$_gr" ]] && { { [[ -n "$_ghome" ]] && [[ "$(cd "$_gr" 2>/dev/null && pwd -P)" == "$_ghome" ]]; } \
       || { [[ -n "$_ghid" ]] && [[ "$(_launcher_dev_ino "$_gr/.")" == "$_ghid" ]]; }; }; then
    printf 'ERROR: the group directory %s is your home directory; the container would get your\n' "$(_q "$_gr")" >&2
    printf '       real dot-directories, writable. Pick another group name, or move ~/.ai-containers.\n' >&2
    exit 1
  fi
  local mode="$1"
  local primary_arg="${2:-}"
  # Host directory where sandbox.sh was invoked. Agent outputs (.agent-blocked,
  # .agent-discovery) are written here so they persist host-visibly beside the
  # container files. These dirs are git- and docker-ignored.
  local launch_dir="$PWD"
  local capture_enabled="0"

  if [[ -n "${SSH_SCOPE_DIR:-}" ]]; then
    echo "Note: SSH_SCOPE_DIR is no longer used; .ssh is now part of the group at ~/.ai-containers/<group>/.ssh/. See CHANGELOG." >&2
  fi

  local capabilities=(--cap-add=NET_ADMIN --cap-add=NET_RAW)
  [[ "$mode" == "open" ]] && capabilities=()
  # Every launch bind-mounts host directories, and an SELinux daemon denies a
  # labelled container both those and the firewall's kernel modules
  # (sandbox-common.sh: selinux_security_opt()). Asked before anything is created,
  # so an unknown SELINUX_LABEL refuses the launch cleanly.
  local selinux_opt
  selinux_opt="$(selinux_security_opt)" || exit 1
  local sandbox_username="${SANDBOX_USER:-$(id -un)}"
  local dev_home="/home/$sandbox_username"

  # Agent outputs → host launch dir, surfaced under the /workspace umbrella.
  # Mounted writable, and docker follows a link there: one the agent left in the
  # launch dir in an earlier session (launched from the project root, the launch
  # dir is the agent's to write) mounted wherever it pointed — a launcher, ~/.ssh
  # — writable for the agent (automated security review of 8da6755; T60). A link,
  # or anything but a directory, refuses the launch.
  local output_mount_flags=() output_dirs=() _od
  for _od in .agent-discovery .agent-blocked; do
    [[ "$mode" == discovery && "$_od" == .agent-discovery ]] || [[ "$mode" == restricted && "$_od" == .agent-blocked ]] || continue
    if [[ -L "$launch_dir/$_od" ]] || { [[ -e "$launch_dir/$_od" ]] && [[ ! -d "$launch_dir/$_od" ]]; }; then
      printf 'ERROR: %s is not a directory (a link, or something else), and it would be mounted\n' "$(_term "$launch_dir/$_od")" >&2
      printf '       writable for the agent wherever it leads; refusing the launch. Remove it on the host.\n' >&2
      exit 1
    fi
    mkdir -p "$launch_dir/$_od"
    output_mount_flags+=(-v "$launch_dir/$_od:/workspace/$_od"); output_dirs+=("$_od")
  done
  [[ "$mode" != discovery ]] || capture_enabled="1"
  # open: no firewall capture, no output mounts.

  # Names already claimed under the /workspace umbrella (collision detection).
  local -A repos_used=()
  local -A repo_mode=()
  # Resolved host source of each mounted PATH-backed repo, keyed by repo name.
  # A host pointer (VAULT_PATH/SPECS_PATH/DOCS_PATH/ARCHITECTURE_REPO_PATH)
  # naming a directory that is ALREADY mounted under some repo name must
  # re-point at that mount rather than mount it twice or refuse to start — see
  # pointer_already_mounted_as below.
  local -A repo_source_real=()
  # Same, for GIT-sourced repos: the registry holds a URL, so identity is proven
  # by comparing the pointer directory's own `origin` against it.
  local -A repo_source_url=()

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
    while IFS= read -r entry; do
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
    done < <(split_env_list "$EXTRA_MOUNTS")
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
  # Effective list = REPOS, plus the @primary repo (as :rw) if not already
  # listed. split_env_list (defined above) does the actual splitting; see
  # its own header for why this is not `read -r -a … <<<` any more.
  local repos_list=() _repos_entry
  if [[ -n "${REPOS:-}" ]]; then
    while IFS= read -r _repos_entry; do
      repos_list+=("$_repos_entry")
    done < <(split_env_list "$REPOS")
  fi
  if [[ -n "$primary_repo" ]]; then
    local _found=0 _e
    for _e in ${repos_list[@]+"${repos_list[@]}"}; do
      [[ "${_e%%:*}" == "$primary_repo" ]] && _found=1
    done
    (( _found )) || repos_list+=("$primary_repo:rw")
  fi

  # ── Host-pointer @name desugar ───────────────────────────────────────────────
  # DOCS_PATH/SPECS_PATH/ARCHITECTURE_REPO_PATH may name a registered repo volume
  # (@name); treat it like a REPOS entry so the loop below mounts it at
  # /workspace/<name> (reusing an existing entry instead of double-mounting).
  # Host-path forms are handled after the loop.
  local docs_kind="" docs_src="" docs_mode=""
  local specs_kind="" specs_src="" specs_mode=""
  local arch_kind="" arch_src="" arch_mode=""
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
  if [[ -n "${ARCHITECTURE_REPO_PATH:-}" ]]; then
    parse_pointer_spec "$ARCHITECTURE_REPO_PATH" ro 1
    arch_kind="$PTR_KIND"; arch_src="$PTR_SRC"; arch_mode="$PTR_MODE"
    if [[ "$arch_kind" == "volume" ]]; then
      _entry="$(pointer_repo_entry "$arch_src" "$arch_mode" ${repos_list[@]+"${repos_list[@]}"})"
      [[ -n "$_entry" ]] && repos_list+=("$_entry")
    fi
  fi
  if [[ ${#repos_list[@]} -gt 0 ]]; then
    local ws_tag; ws_tag="$(sanitize_volume_token "$(basename "$launch_dir")")_$(printf '%s' "$launch_dir" | cksum | tr -cd '0-9' | cut -c1-8)"
    # Every entry's volumes are checked before ANY is seeded or mounted: a repo
    # volume is found by name, and under a nested REPO_VOLUME_PREFIX two repos'
    # names collide, a working copy's (`<base>--wc-<tag>`) as much as a base
    # volume's. Attaching would hand the agent ANOTHER repo's data, :rw included
    # (bugs review REPO-13; repo.sh refuses it the same way, REPO-11). An
    # unlabelled volume, made before labels, names no owner.
    local _pe _pn _pm _prec
    for _pe in "${repos_list[@]}"; do
      _pn="${_pe%%:*}"; _pm="${_pe##*:}"
      _prec="$(repo_registry_lookup "$_pn" 2>/dev/null)" || continue
      [[ "$(repo_record_backend "$_prec")" == "bind" ]] && continue
      _repo_volume_foreign "$_pn" "$(repo_volume_name "$_pn")"
      [[ "$_pm" == "rwcopy" ]] && _repo_volume_foreign "$_pn" "$(repo_workcopy_volume_name "$_pn" "$ws_tag")"
    done
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
      local rrecord rsource rbackend
      rrecord="$(repo_registry_lookup "$rname")"
      rsource="$(repo_record_field "$rrecord" 3)"
      rbackend="$(repo_record_backend "$rrecord")"
      # Only a path-sourced repo has a host directory to compare against; a
      # git-sourced one records a URL, and nothing here can prove that a host
      # path is the same checkout.
      if [[ "$(repo_record_field "$rrecord" 2)" == "path" ]]; then
        repo_source_real["$rname"]="$(resolve_path "${rsource/#\~/$HOME}")"
      else
        repo_source_url["$rname"]="$(normalise_git_url "$rsource")"
      fi

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
      local vault_at
      if vault_at="$(pointer_already_mounted_as "$vault_real")"; then
        vault_env_args+=(-e "VAULT_PATH=/workspace/$vault_at")
        qmd_corpora+=("VAULT_PATH")
      elif [[ -n "${repos_used[vault]:-}" ]]; then
        printf "ERROR: name 'vault' is used by %s, but VAULT_PATH also mounts at /workspace/vault.\n" "${repos_used[vault]}" >&2
        printf "       They are different directories; rename the repo or point VAULT_PATH elsewhere.\n" >&2
        exit 1
      else
        vault_mount_flags+=(-v "$vault_real:/workspace/vault:rw")
        vault_env_args+=(-e VAULT_PATH=/workspace/vault)
        qmd_corpora+=("VAULT_PATH")
      fi
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
        local specs_at
        if [[ -n "$primary_path" && "$specs_real" == "$primary_path" ]]; then
          specs_env_args+=(-e "SPECS_PATH=$workdir")
          qmd_corpora+=("SPECS_PATH")
        elif specs_at="$(pointer_already_mounted_as "$specs_real")"; then
          specs_env_args+=(-e "SPECS_PATH=/workspace/$specs_at")
          qmd_corpora+=("SPECS_PATH")
        elif [[ -n "${repos_used[specs]:-}" ]]; then
          printf "ERROR: name 'specs' is used by %s, but SPECS_PATH also mounts at /workspace/specs.\n" "${repos_used[specs]}" >&2
          printf "       They are different directories; rename the repo or point SPECS_PATH elsewhere.\n" >&2
          exit 1
        else
          specs_mount_flags+=(-v "$specs_real:/workspace/specs:rw")
          specs_env_args+=(-e SPECS_PATH=/workspace/specs)
          qmd_corpora+=("SPECS_PATH")
        fi
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
        local docs_at
        if docs_at="$(pointer_already_mounted_as "$docs_real")"; then
          # Same checkout, already attached as a repo. Re-point at that mount —
          # and note its mode wins: attached :rw, the docs are writable, which is
          # correct when that repo IS what you are working in. The :ro default
          # applies to a docs repo mounted BY this pointer, not to one you have
          # deliberately attached for editing.
          docs_env_args+=(-e "DOCS_PATH=/workspace/$docs_at")
          qmd_corpora+=("DOCS_PATH")
        elif [[ -n "${repos_used[docs]:-}" ]]; then
          printf "ERROR: name 'docs' is used by %s, but DOCS_PATH also mounts at /workspace/docs.\n" "${repos_used[docs]}" >&2
          printf "       They are different directories; rename the repo or point DOCS_PATH elsewhere.\n" >&2
          exit 1
        else
          docs_mount_flags+=(-v "$docs_real:/workspace/docs:$docs_mode")
          docs_env_args+=(-e DOCS_PATH=/workspace/docs)
          qmd_corpora+=("DOCS_PATH")
        fi
      else
        printf 'WARNING: DOCS_PATH is set but directory does not exist: %s\n' "$docs_src" >&2
      fi
    fi
  fi

  # ── Architecture repo → /workspace/architecture (grounding), /workspace/<name>
  #    (@name), or the working-dir mount when it IS the working dir ─────────────
  # Same grammar and re-point rules as DOCS_PATH, and read-only by default for
  # the same reason: workflows ground against it. The NAME comes from
  # product-architecture's own tooling (its MCP server and slash commands read
  # ARCHITECTURE_REPO_PATH as the repository root), so it is re-exported under
  # that name, at that root, for them to work in here unchanged.
  local arch_mount_flags=()
  local arch_env_args=()
  if [[ -n "${ARCHITECTURE_REPO_PATH:-}" ]]; then
    if [[ "$arch_kind" == "volume" ]]; then
      arch_env_args+=(-e "ARCHITECTURE_REPO_PATH=/workspace/$arch_src")
      qmd_corpora+=("ARCHITECTURE_REPO_PATH")
    else
      local arch_real
      arch_real="$(resolve_path "${arch_src/#\~/$HOME}")"
      if [[ -n "$primary_path" && "$arch_real" == "$primary_path" ]]; then
        # It IS the working dir: already mounted rw at $workdir, so the :ro
        # default and any suffix are moot — authoring an ADR there just works.
        arch_env_args+=(-e "ARCHITECTURE_REPO_PATH=$workdir")
        qmd_corpora+=("ARCHITECTURE_REPO_PATH")
      elif [[ -d "$arch_real" ]]; then
        local arch_at
        if arch_at="$(pointer_already_mounted_as "$arch_real")"; then
          arch_env_args+=(-e "ARCHITECTURE_REPO_PATH=/workspace/$arch_at")
          qmd_corpora+=("ARCHITECTURE_REPO_PATH")
        elif [[ -n "${repos_used[architecture]:-}" ]]; then
          printf "ERROR: name 'architecture' is used by %s, but ARCHITECTURE_REPO_PATH also mounts at /workspace/architecture.\n" "${repos_used[architecture]}" >&2
          printf "       They are different directories; rename the repo or point ARCHITECTURE_REPO_PATH elsewhere.\n" >&2
          exit 1
        else
          arch_mount_flags+=(-v "$arch_real:/workspace/architecture:$arch_mode")
          arch_env_args+=(-e ARCHITECTURE_REPO_PATH=/workspace/architecture)
          qmd_corpora+=("ARCHITECTURE_REPO_PATH")
        fi
      else
        printf 'WARNING: ARCHITECTURE_REPO_PATH is set but directory does not exist: %s\n' "$arch_src" >&2
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

  # ── Group resolution (the name was checked at the top) ─────────────────────
  local group_root
  mkdir -p "$HOME/.ai-containers"
  group_root="$HOME/.ai-containers/$group"
  _group_guard_root="$group_root"
  ensure_group_exists "$group" "$group_root"
  ensure_group_scaffold "$group_root"
  _cd_phys _git_skip_root "$group_root" || _git_skip_root=""

  # ── Credential mounts (enabled components only) ──────────────────────────────
  # Stage git config files into the group directory before mounting. Docker Desktop
  # on macOS (VirtioFS) bind-mounts a specific inode; if git/editors atomically
  # replace the file after the container starts the old inode gets link count 0 and
  # reads fail. Mounting from the group dir (which nothing replaces while running)
  # avoids this. The copy is refreshed on every container start.
  [[ -f "$HOME/.gitconfig"        ]] && cp "$HOME/.gitconfig"        "$group_root/.gitconfig"        2>/dev/null || true
  [[ -f "$HOME/.gitignore_global" ]] && cp "$HOME/.gitignore_global" "$group_root/.gitignore_global" 2>/dev/null || true
  local gitconfig_src="$group_root/.gitconfig"
  local gitignore_src="$group_root/.gitignore_global"
  local config_mount_flags=()
  add_mount_if_exists      config_mount_flags "$group_root/.ssh"         "$dev_home/.ssh"
  add_mount_if_exists      config_mount_flags "$group_root/.agents"      "$dev_home/.agents"
  add_file_mount_if_exists config_mount_flags "$gitconfig_src"           "$dev_home/.gitconfig" ro
  add_file_mount_if_exists config_mount_flags "$gitignore_src"           "$dev_home/.gitignore_global" ro

  if any_enabled github-cli copilot; then
    install -d "$group_root/.config/gh"
    add_mount_if_exists config_mount_flags "$group_root/.config/gh" "$dev_home/.config/gh"
  fi
  if is_enabled copilot; then
    install -d "$group_root/.copilot"
    add_mount_if_exists config_mount_flags "$group_root/.copilot" "$dev_home/.copilot"
  fi
  if is_enabled kiro; then
    install -d "$group_root/.kiro" "$group_root/.local/share/kiro-cli"
    add_mount_if_exists config_mount_flags "$group_root/.kiro"                  "$dev_home/.kiro"
    add_mount_if_exists config_mount_flags "$group_root/.local/share/kiro-cli"  "$dev_home/.local/share/kiro-cli"
  fi
  if is_enabled claude-code; then
    install -d "$group_root/.claude" \
               "$group_root/.local/share/claude" "$group_root/.local/state/claude"
    [[ -e "$group_root/.claude.json" ]] || printf '{}\n' > "$group_root/.claude.json"
    add_mount_if_exists      config_mount_flags "$group_root/.claude"      "$dev_home/.claude"
    add_file_mount_if_exists config_mount_flags "$group_root/.claude.json" "$dev_home/.claude.json"
    # Claude Code installs natively (agent-tools-reconcile.sh): ~/.local/share/claude holds
    # versions/<v>, ~/.local/state/claude the updater's bookkeeping. Group-scoped exactly
    # like ~/.local/share/kiro-cli above, and for the same reason — without these the
    # install is redone on every container start and every self-update dies with the
    # container, which is the whole capability this is meant to restore.
    add_mount_if_exists config_mount_flags "$group_root/.local/share/claude" "$dev_home/.local/share/claude"
    add_mount_if_exists config_mount_flags "$group_root/.local/state/claude" "$dev_home/.local/state/claude"
  fi
  if is_enabled codex; then
    install -d "$group_root/.codex"
    add_mount_if_exists config_mount_flags "$group_root/.codex" "$dev_home/.codex"
  fi
  if is_enabled gemini; then
    install -d "$group_root/.gemini"
    add_mount_if_exists config_mount_flags "$group_root/.gemini" "$dev_home/.gemini"
  fi
  if is_active ruby; then
    # A docker volume, never a bind mount — a bind mount cannot host an rvm
    # install on macOS at all. rvm_volume_ensure creates it on first use and
    # migrates a pre-volume ~/.rvm across if one is there.
    local rvm_vol
    if rvm_vol="$(rvm_volume_ensure "$group" "$group_root" "$image_name")"; then
      config_mount_flags+=(-v "$rvm_vol:$dev_home/.rvm")
    else
      printf 'WARNING: no rvm volume for group %s — Ruby will be unavailable.\n' "$group" >&2
    fi
  fi
  if [[ -n "$(runtime_tools_csv)" ]]; then
    install -d "$group_root/.ai-tools"
    add_mount_if_exists config_mount_flags "$group_root/.ai-tools" "$dev_home/.ai-tools"
  fi
  # .yarn/.aws/.azure/.kube are group-scoped like every dir above. They were
  # mounted straight from $HOME until now only because they predate the group
  # system and were never revisited — not because a cloud credential deserves a
  # weaker boundary than a Claude Code token. Two consequences worth naming: a
  # container can no longer write the developer's real AWS/Azure credentials,
  # and `kubectl config use-context` inside the sandbox stops flipping the
  # host's current context out from under whatever else is using it.
  #
  # What a group STARTS with is _copy_group_slice's decision, not this one: an
  # existing group gets an empty dir here, a group bootstrapped from:host or
  # from:<group> inherits the real files. .aws/.azure/.kube are in that slice;
  # .yarn is mounted but deliberately not copied, being a regenerable package
  # cache like .ai-tools and .cache/ms-playwright rather than a credential.
  if is_enabled yarn; then
    install -d "$group_root/.yarn"
    add_mount_if_exists config_mount_flags "$group_root/.yarn" "$dev_home/.yarn"
  fi
  if is_enabled aws-cli; then
    install -d "$group_root/.aws"
    add_mount_if_exists config_mount_flags "$group_root/.aws" "$dev_home/.aws"
  fi
  if is_enabled azure-cli; then
    install -d "$group_root/.azure"
    add_mount_if_exists config_mount_flags "$group_root/.azure" "$dev_home/.azure"
  fi
  if is_enabled kubectl; then
    install -d "$group_root/.kube"
    add_mount_if_exists config_mount_flags "$group_root/.kube" "$dev_home/.kube"
  fi
  # Tool config dirs (dtctl/dtmgd/...) are group-scoped like agent
  # credentials: created lazily in the group and seeded ONCE from the host home
  # if present, so a sandboxed agent never writes the developer's real host
  # config. The seed happens only when the group dir does not yet exist.
  #
  # A tool may split its state over more than one directory (e.g. config in one,
  # credentials in another), so config_dir is a space-separated LIST.
  local _tname _cdir; local -a _cdirs
  while IFS= read -r _tname; do
    is_active "$_tname" || continue
    tools_read_descriptor "$_tname" || continue
    [[ -n "$TOOL_config_dir" ]] || continue
    # config_dir may list several space-separated paths. Split with read -ra
    # rather than an unquoted expansion: bare word-splitting also GLOBS, so a
    # descriptor containing a metacharacter would expand against the launch dir.
    read -ra _cdirs <<< "$TOOL_config_dir"
    for _cdir in "${_cdirs[@]}"; do
      # A dangling link here is what the old `cp -a` of a relative link left:
      # the launcher's own artefact, so it is replaced, not tripped over.
      if [[ -L "$group_root/$_cdir" && ! -e "$group_root/$_cdir" ]]; then
        printf 'NOTE: replacing the dangling link %s in the group with a copy.\n' "$(_q "$group_root/$_cdir")" >&2
        rm -f "$group_root/$_cdir"
      fi
      if [[ ! -e "$group_root/$_cdir" && -e "$HOME/$_cdir" ]]; then
        install -d "$(dirname "$group_root/$_cdir")"
        _copy_dereferenced "$HOME/$_cdir" "$group_root/$_cdir"
      else
        install -d "$group_root/$_cdir"
      fi
      add_mount_if_exists config_mount_flags "$group_root/$_cdir" "$dev_home/$_cdir"
    done
  done < <(tools_list_names)
  if is_enabled qmd; then
    install -d "$group_root/.cache/qmd"
    add_mount_if_exists config_mount_flags "$group_root/.cache/qmd" "$dev_home/.cache/qmd"
  fi
  # Playwright's browser binaries (~500 MB) are NOT baked into the image — only
  # the OS libraries they link against are. They are downloaded at run time into
  # ~/.cache/ms-playwright, and containers run with --rm, so without this mount
  # every single container start re-downloads all of them. Group-scoped for the
  # same reason ~/.cache/qmd above is: the cost is paid once per group, not once
  # per project and not once per run.
  #
  # is_active, NOT is_enabled: the key is ON | x.y.z | OFF, and a pinned version
  # is just as on as ON.
  if is_active playwright; then
    install -d "$group_root/.cache/ms-playwright"
    add_mount_if_exists config_mount_flags "$group_root/.cache/ms-playwright" "$dev_home/.cache/ms-playwright"
  fi
  # Gradle's and Maven's user homes hold the wrapper distributions (~130 MB per
  # Gradle version) and every dependency a build downloads; with --rm, a start
  # without these mounts fetched all of it again. Gated on ANY JVM key, not on
  # gradle=/maven=: gradlew and mvnw need only a JDK. Mounted but not copied by
  # _copy_group_slice, being caches like .yarn — though gradle.properties and
  # settings.xml can hold repository credentials, which this keeps in the group.
  #
  # Concurrent builds in two containers of one group share the file locks, but
  # Gradle asks a lock's holder to release it over loopback, which does not cross
  # containers: the second build can wait out Gradle's 60 s lock timeout.
  if any_has_versions openjdk graalvm-ce graalvm-oracle kotlin scala maven gradle; then
    local _jvm_dir
    for _jvm_dir in .gradle .m2; do
      install -d "$group_root/$_jvm_dir"
      add_mount_if_exists config_mount_flags "$group_root/$_jvm_dir" "$dev_home/$_jvm_dir"
    done
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
    while IFS= read -r p; do
      port_flags+=(-p "$p")
    done < <(split_env_list "$PREVIEW_PORTS")
  fi

  # Optional project env-file → in-container app env (DB_HOST, REDIS_URL, ...).
  # Auto-detect container.env beside this script (i.e. <project>/.ai-containers/),
  # or honour an explicit SANDBOX_ENV_FILE override. Filtered just before docker run,
  # once every -e flag is known (container_env_filter).
  local _env_file="${SANDBOX_ENV_FILE:-${script_dir}/container.env}"
  if [[ -n "${SANDBOX_ENV_FILE:-}" && ! -f "$_env_file" ]]; then
    printf 'WARNING: SANDBOX_ENV_FILE=%s not found — skipping.\n' "$_env_file" >&2
    _env_file=""
  elif [[ -f "$_env_file" ]]; then
    printf 'Injecting project env-file: %s\n' "$_env_file" >&2
  else
    _env_file=""
  fi

  local mem_limit mem_reservation mem_swap
  validate_memory_limits

  if [[ -z "${CONTAINER_CPUS:-}" && -z "${CONTAINER_MEMORY:-}" ]]; then
    printf 'HINT: running at default limits (%s CPU / %s RAM) — the minimum for a single agent doing light work.\n' "${CONTAINER_CPUS:-1.0}" "$mem_limit" >&2
    printf '      For an agent plus a real build toolchain, CONTAINER_CPUS=4 CONTAINER_MEMORY=8g CONTAINER_MEMORY_SWAP=8g is more comfortable.\n' >&2
  fi

  # Does this image come from the files sitting next to it? Warned about here,
  # at the last moment before the container starts, because that is when the
  # answer is actionable and when somebody is watching the terminal.
  ai_containers_provenance_warn "$image_name" "$script_dir"

  # /dev/shm sizing. Docker's default is 64 MB, and headless Chromium dies on it
  # — the single most common Playwright-in-Docker failure, and one CONTAINER_MEMORY
  # cannot fix, because /dev/shm is a tmpfs sized independently of the memory
  # cgroup: a 16g container still crashes. Playwright's own docs reach for
  # `--ipc=host`, which fixes it by sharing the HOST's IPC namespace; this
  # project does not spend isolation to buy convenience, and --shm-size buys the
  # same result without it.
  #
  # Only passed when something actually needs it, so every container that does
  # not ask for Playwright composes exactly the `docker run` it composed before.
  # CONTAINER_SHM_SIZE overrides, and works on its own for anything else that
  # needs shared memory (it is not tied to this one component's key).
  local shm_flags=()
  if [[ -n "${CONTAINER_SHM_SIZE:-}" ]]; then
    shm_flags=(--shm-size="$CONTAINER_SHM_SIZE")
  elif is_active playwright; then
    shm_flags=(--shm-size=1g)
  fi

  # Container name. CONTAINER_NAME overrides; the default combines the
  # project's name with this process's PID, so several containers started
  # against the very same workspace (e.g. one editing, others
  # read-only-investigating) still get distinct names instead of colliding on
  # Docker's random adjective_surname default — which gives no clue which
  # running container is which task. The PID alone already guarantees
  # uniqueness; the project name is just there for legibility in `docker ps`.
  # launch_dir is "<project>/.ai-containers" (the documented invocation is
  # always `cd <project>/.ai-containers && ./sandbox.sh`), so its basename is
  # ".ai-containers" itself — useless, and Docker rejects a leading '.' in
  # --name outright. dirname(launch_dir) is the project folder.
  local container_name="${CONTAINER_NAME:-}"
  if [[ -z "$container_name" ]]; then
    local proj; proj="$(sanitize_volume_token "$(basename "$(dirname "$launch_dir")")")"
    # Docker requires --name to START with [a-zA-Z0-9]. sanitize_volume_token
    # only fixes disallowed characters, not a disallowed LEADING one — a
    # project folder named e.g. ".hidden" or "-scratch" would still crash the
    # same way ".ai-containers" did. Strip any such leading characters; if
    # nothing alphanumeric is left, fall back to a plain default.
    proj="$(printf '%s' "$proj" | sed -E 's/^[^a-zA-Z0-9]+//')"
    [[ -z "$proj" ]] && proj="workspace"
    container_name="${proj}-$$"
  fi
  printf 'Container name: %s\n' "$container_name" >&2

  # Last, once every bind mount is known: see launcher_ro_overlay.
  # shellcheck disable=SC2034  # launcher_ro_dirs/launcher_rw_srcs: set by launcher_ro_overlay, read through _ro_fifo_search's namerefs
  local launcher_ro_flags=() launcher_verify=() launcher_ro_files=() launcher_ro_dirs=() launcher_rw_srcs=()
  launcher_ro_overlay launcher_ro_flags launcher_verify "$script_dir" \
    ${output_mount_flags[@]+"${output_mount_flags[@]}"} \
    ${repo_mount_flags[@]+"${repo_mount_flags[@]}"} \
    ${extra_mount_flags[@]+"${extra_mount_flags[@]}"} \
    ${vault_mount_flags[@]+"${vault_mount_flags[@]}"} \
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
    ${docs_mount_flags[@]+"${docs_mount_flags[@]}"} \
    ${arch_mount_flags[@]+"${arch_mount_flags[@]}"} \
    ${config_mount_flags[@]+"${config_mount_flags[@]}"}

  # A concurrent container on an overlapping writable tree could swap one of the
  # launcher mounts' SOURCES for a symlink between the scan above and the moment
  # Docker resolves it, so the new container would mount an arbitrary host path.
  # Guard it: record each launcher mount's source identity (device:inode) now,
  # in a directory only this launch can reach — under $HOME/.ai-containers, where
  # the group mounts already come from, never inside /workspace — and hand it to
  # the root entrypoint, which re-checks every mount before the agent shell
  # exists and refuses to start on a mismatch (entrypoint.sh: verify_launcher_
  # mounts). The verify directory is itself mounted read-only and is the anchor:
  # if its own device:inode does not survive the mount, this filesystem does not
  # preserve them (some file-sharing layers), and the entrypoint says so and
  # skips rather than refusing every launch.
  local launcher_verify_flags=() launcher_anchor_env=()
  # Again, just before docker: a FIFO made since the overlay pass (LNCH-11).
  _ro_fifo_search launcher_ro_dirs launcher_rw_srcs _ro_links_check
  _fs_ml_drop
  # The output directories join the manifest: checked for a link above, they
  # could be swapped for one before docker resolves them, by a concurrent
  # container of the same project; the entrypoint refuses a swap as for any
  # overlay (review of the batch 10 branch, reproduced; T61).
  for _od in ${output_dirs[@]+"${output_dirs[@]}"}; do launcher_verify+=("$launch_dir/$_od" "/workspace/$_od"); done
  if (( ${#launcher_verify[@]} )); then
    _launcher_verify_dir="$HOME/.ai-containers/.verify-$$-$RANDOM"
    local _vdir="$_launcher_verify_dir"
    if mkdir -p "$_vdir" 2>/dev/null; then
      # Best-effort sweep of verify dirs a crashed launch left behind: older than
      # an hour AND whose launcher pid is gone. The age keeps it off a dir another
      # launch is still setting up (a pid can look dead from another pid
      # namespace, or another host sharing $HOME). Never fatal: a dir that will
      # not go must not cost this launch, under set -e, its start.
      local _old _opid
      while IFS= read -r -d '' _old; do
        _opid="${_old##*/.verify-}"; _opid="${_opid%%-*}"
        if [[ "$_opid" =~ ^[0-9]+$ ]] && ! kill -0 "$_opid" 2>/dev/null; then
          rm -rf "$_old" 2>/dev/null || true
        fi
      done < <(find "$HOME/.ai-containers" -mindepth 1 -maxdepth 1 -type d -name '.verify-*' -mmin +60 -print0 2>/dev/null)
      local _i _vsrc _vdst _vdev _vino
      # The read-only FILE binds the git-internals pass made, checked again where
      # their inodes are recorded: a concurrent container could swap one for a
      # FIFO after the pass (review of 455fa85). Tagged there, not guessed from
      # names, which also matched a worktree named config (review of 56c91c4).
      local -A _vrof=()
      for _vsrc in ${launcher_ro_files[@]+"${launcher_ro_files[@]}"}; do _vrof[$_vsrc]=1; done
      : > "$_vdir/manifest"
      # On Colima, every device:inode comes from its VM, the verify directory's
      # included, or none does: the entrypoint then checks there as on Linux. A
      # source the VM cannot stat is recorded as 0:0, which refuses the launch, as
      # a host stat that fails does (PLAT-3).
      local -A _vm_di=()
      local _vm_on=0 _vpaths=("$_vdir")
      for (( _i = 0; _i < ${#launcher_verify[@]}; _i += 2 )); do _vpaths+=("${launcher_verify[_i]}"); done
      if _vm_dev_ino_load _vm_di "${_vpaths[@]}" && [[ -n "${_vm_di[$_vdir]:-}" ]]; then _vm_on=1; fi
      for (( _i = 0; _i < ${#launcher_verify[@]}; _i += 2 )); do
        _vsrc="${launcher_verify[_i]}"; _vdst="${launcher_verify[_i+1]}"
        # Checked again where the inode is recorded: a concurrent container could
        # swap a protected config for a FIFO after the overlay pass, and the
        # entrypoint only compares inodes with these (review of 455fa85).
        if [[ -n "${_vrof[$_vsrc]:-}" ]] && [[ -p "$_vsrc" || -b "$_vsrc" || -c "$_vsrc" || -L "$_vsrc" || ! -e "$_vsrc" ]]; then
          printf 'ERROR: %s is no longer what was checked; refusing the launch.\n' "$(_term "$_vsrc")" >&2
          exit 1
        fi
        if (( _vm_on )); then
          if [[ -n "${_vm_di[$_vsrc]:-}" ]]; then read -r _vdev _vino <<<"${_vm_di[$_vsrc]}"; else _vdev=0; _vino=0; fi
        elif read -r _vdev _vino < <(_launcher_dev_ino "$_vsrc"); then :; else _vdev=0; _vino=0; fi
        printf '%s\0%s\0%s\0' "$_vdev" "$_vino" "$_vdst" >> "$_vdir/manifest"
      done
      launcher_verify_flags=(-v "$_vdir:/run/ai-launcher:ro")
      local _adev="" _aino=""
      if (( _vm_on )); then read -r _adev _aino <<<"${_vm_di[$_vdir]}"
      else read -r _adev _aino < <(_launcher_dev_ino "$_vdir") || true; fi
      launcher_anchor_env=(-e "AI_LAUNCHER_ANCHOR=${_adev}:${_aino}")
    else
      printf 'WARNING: could not create %s; launcher mounts will not be verified against\n' "$_vdir" >&2
      printf '         a concurrent-container swap this launch.\n' >&2
    fi
  fi

  # What each file bound read-only on its own holds now, put back if the container
  # writes it under another spelling (GIT-41).
  _ro_files_snapshot ${launcher_ro_files[@]+"${launcher_ro_files[@]}"}

  local repos_path_ctr
  repos_path_ctr="$(repos_path_in_container "${REPOS_PATH:-}" \
    ${extra_mount_flags[@]+"${extra_mount_flags[@]}"} \
    ${repo_mount_flags[@]+"${repo_mount_flags[@]}"} \
    ${vault_mount_flags[@]+"${vault_mount_flags[@]}"} \
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
    ${docs_mount_flags[@]+"${docs_mount_flags[@]}"} \
    ${arch_mount_flags[@]+"${arch_mount_flags[@]}"})"

  # Every -e this launch passes, in one array: container_env_filter reads the names
  # from it, so a key added here is refused from container.env with no second edit.
  local launcher_env=(
    -e DEV_CONTAINER_MODE="$mode"
    -e DISCOVERY_CAPTURE_ENABLED="$capture_enabled"
    -e DISCOVERY_CAPTURE_DIR="/workspace/.agent-discovery"
    -e BLOCKED_CAPTURE_DIR="/workspace/.agent-blocked"
    -e HOST_WORKSPACE_DIR="$launch_dir"
    -e IMAGE_NAME="$image_name"
    -e SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"
    -e SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"
    -e SANDBOX_USER="${SANDBOX_USER:-$(id -un)}"
    -e SANDBOX_GROUP="${SANDBOX_GROUP:-$(id -gn)}"
    -e AI_AGENTS_ENABLED="$(enabled_agents_csv)"
    -e AI_RUNTIME_TOOLS="$(runtime_tools_csv)"
    -e RUBY_VERSIONS="$(versions_to_space "$(version_list ruby)")"
    -e AI_SERVICES="$(services_csv)"
    -e REPOS_PATH="$repos_path_ctr"
    # Copilot CLI lists skills for the model within this many characters (its
    # own default is 15000) and lists a skill past it by name only, with no
    # description. A default, not a constant: a host value wins, as for REPOS_PATH.
    -e SKILL_CHAR_BUDGET="${SKILL_CHAR_BUDGET:-25000}"
    # Claude Code's skill listing gets this many characters when it is set;
    # otherwise context tokens x 4 x skillListingBudgetFraction (0.01: 8000 at a
    # 200K window), and over budget every description is shortened. It overrides
    # that settings fraction, so a host value wins here too.
    -e SLASH_COMMAND_TOOL_CHAR_BUDGET="${SLASH_COMMAND_TOOL_CHAR_BUDGET:-40000}"
    ${git_optional_locks_env[@]+"${git_optional_locks_env[@]}"}
    ${SELF_HEALING_ENABLED:+-e SELF_HEALING_ENABLED="$SELF_HEALING_ENABLED"}
    ${ALLOW_IPV6_BYPASS:+-e ALLOW_IPV6_BYPASS="$ALLOW_IPV6_BYPASS"}
    ${GITHUB_PERSONAL_ACCESS_TOKEN:+-e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"}
    ${copilot_token:+-e COPILOT_GITHUB_TOKEN="$copilot_token"}
    ${vault_env_args[@]+"${vault_env_args[@]}"}
    ${specs_env_args[@]+"${specs_env_args[@]}"}
    ${docs_env_args[@]+"${docs_env_args[@]}"}
    ${arch_env_args[@]+"${arch_env_args[@]}"}
    ${launcher_anchor_env[@]+"${launcher_anchor_env[@]}"}
  )

  # container.env, filtered (container_env_filter), and the names it sets, which the
  # entrypoint sets aside from root. Handed over on a descriptor held open for docker
  # run: a process substitution expanded into an array assignment is closed once the
  # assignment ends, and docker then finds nothing at /dev/fd/N.
  local app_env_flags=()
  if [[ -n "$_env_file" ]]; then
    local _app_lines=() _app_keys=() _app_fd
    container_env_filter "$_env_file" _app_lines _app_keys "${launcher_env[@]}"
    if (( ${#_app_lines[@]} )); then
      exec {_app_fd}< <(printf '%s\n' "${_app_lines[@]}")
      app_env_flags=(--env-file "/dev/fd/$_app_fd" -e "AI_CONTAINER_ENV_KEYS=${_app_keys[*]}")
    fi
  fi

  # --pull=never: IMAGE_NAME may come from a committed sandbox.env, and an image
  # this machine never built must not be fetched from a registry and run with
  # the group's credentials mounted. ./build.sh (or runme.sh) builds it first.
  # --security-opt=no-new-privileges: every process in the container, a
  # `docker exec` session included, starts unable to gain privileges through a
  # setuid-root or file-capability binary. The entrypoint gives the agent shell
  # the same flag itself (RT-10); an exec session is outside that tree (RT-11).
  local _run_rc=0
  docker run -it --rm --pull=never \
    --name "$container_name" \
    ${capabilities[@]+"${capabilities[@]}"} \
    --security-opt=no-new-privileges \
    ${selinux_opt:+"$selinux_opt"} \
    ${shm_flags[@]+"${shm_flags[@]}"} \
    --add-host=host.docker.internal:host-gateway \
    ${app_env_flags[@]+"${app_env_flags[@]}"} \
    ${port_flags[@]+"${port_flags[@]}"} \
    --cpus="${CONTAINER_CPUS:-1.0}" \
    --memory="$mem_limit" \
    --memory-reservation="$mem_reservation" \
    --memory-swap="$mem_swap" \
    --ulimit nofile="${CONTAINER_NOFILE:-1048576:1048576}" \
    "${launcher_env[@]}" \
    ${output_mount_flags[@]+"${output_mount_flags[@]}"} \
    ${repo_mount_flags[@]+"${repo_mount_flags[@]}"} \
    ${extra_mount_flags[@]+"${extra_mount_flags[@]}"} \
    ${vault_mount_flags[@]+"${vault_mount_flags[@]}"} \
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
    ${docs_mount_flags[@]+"${docs_mount_flags[@]}"} \
    ${arch_mount_flags[@]+"${arch_mount_flags[@]}"} \
    ${config_mount_flags[@]+"${config_mount_flags[@]}"} \
    ${launcher_ro_flags[@]+"${launcher_ro_flags[@]}"} \
    ${launcher_verify_flags[@]+"${launcher_verify_flags[@]}"} \
    -w "$workdir" \
    "$image_name" || _run_rc=$?
  _ro_files_restore
  _git_after_session
  return "$_run_rc"
}

# ── Entry point ──────────────────────────────────────────────────────────────────

# Mode + primary workdir fall back to SANDBOX_MODE / SANDBOX_WORKDIR (loaded from
# sandbox.env / sandbox.local.env by sandbox-common.sh) when the positional args are
# omitted — so a bare `./sandbox.sh` launches from config. A positional arg always wins;
# with no arg and no env value, mode → usage (help) and workdir → the /workspace umbrella.
command="${1:-${SANDBOX_MODE:-usage}}"

case "$command" in
  restricted|discovery|open)
    host_checkout_preflight "$_here" || exit 1
    run_container "$command" "${2:-${SANDBOX_WORKDIR:-}}"
    ;;
  build)
    printf 'ERROR: "sandbox.sh build" has been removed. Use ./build.sh instead.\n' >&2
    exit 1
    ;;
  -h|--help|help|usage)
    usage
    ;;
  -V|--version|version)
    # Pure output: no build, no container. The generated runme.sh short-circuits
    # to here BEFORE its own ./build.sh for the same reason.
    version_report "$script_dir"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
