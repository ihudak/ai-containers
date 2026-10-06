#!/usr/bin/env bash
set -euo pipefail

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
# claude-code-sandbox=ON and Docker cannot start a container under the
# ai-containers-sandbox AppArmor profile: say where and how to load it, once, as
# root, where Docker's kernel runs. The copy under /etc/apparmor.d is loaded again
# on every boot of that kernel.
claude_sandbox_profile_missing() {  # $1=absolute path of ai-containers-sandbox.apparmor
  local profile="$1"
  local load="cp '$profile' /etc/apparmor.d/ai-containers-sandbox && apparmor_parser -r /etc/apparmor.d/ai-containers-sandbox"
  {
    printf 'claude-code-sandbox=ON, but Docker cannot start a container under the\n'
    printf 'ai-containers-sandbox AppArmor profile: it is not loaded where Docker'"'"'s kernel runs.\n'
    printf 'Load it once, as root, there (the profile path must be visible inside the VM;\n'
    printf 'Colima and Lima share your home directory by default):\n\n'
    printf '  Mac, Colima:  colima ssh -- sudo sh -c "%s"\n' "$load"
    printf '  Mac, Lima:    limactl shell <instance> -- sudo sh -c "%s"\n' "$load"
    printf '  Linux:        sudo sh -c "%s"\n\n' "$load"
    printf 'See docs/components/claude-code-sandbox.md. Or set claude-code-sandbox=OFF.\n'
  } >&2
}

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
  # shellcheck disable=SC2178,SC2128  # nameref: shellcheck does not model `local -n`
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
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
# an engine checkout as the working dir, or a mount rooted at a project's
# .ai-containers — cannot be made read-only without making that work impossible,
# so it is named with a NOTE instead. Launchers are handled shallowest-first:
# once a directory is overlaid read-only, everything inside it already is, so a
# launcher nested in another is skipped rather than pinned — a :rw pin there
# would punch a writable hole in the read-only parent.
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
  local reached="$3" self spec src rest dst opts l at pin path part r skip i k depth max=0 d p pp kind ok mf mv
  local x f e q w c safe inner how
  local uid="${SANDBOX_UID:-$(id -u)}" gid="${SANDBOX_GID:-$(id -g)}" you
  local -a found unreadable cand bsrc=() bdst=() cl=() cat=() csrc=() cdst=() cdep=() ckind=() ro_dsts=() psrc pdst
  local -a scan links walk gdirs gfiles glinks gunr gro ug usrc udst udep ukind
  local g base what gmax gn gitmax cfg hp hpd k2
  local -A seen=() tried=() scanned=() pinned=()
  local nl
  # The agent's identity decides what it can reach; find needs it numeric (and
  # within a 32-bit id — GNU find rejects 4294967295 and up), and a find that
  # errors out finds nothing — so refuse rather than search blind.
  if [[ ! "$uid" =~ ^[0-9]{1,10}$ || ! "$gid" =~ ^[0-9]{1,10}$ ]] \
     || (( 10#$uid > 4294967294 || 10#$gid > 4294967294 )); then
    printf 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric ids from 0 to 4294967294 (got %q / %q).\n' "$uid" "$gid" >&2
    exit 1
  fi
  you="$(id -u)"
  shift 3
  self="$(cd "$reached" 2>/dev/null && pwd -P)" || self="$reached"
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
      printf 'ERROR: %s cannot be listed by you, so the launcher cannot check it for\n' "$src" >&2
      printf '       launchers before mounting it writable at %s.\n' "$dst" >&2
      printf '       Make it listable (chmod u+rx, if it is yours), or mount it :ro.\n' >&2
      exit 1
    fi
    src="$(cd "$src" 2>/dev/null && pwd -P)" || continue
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
    pp="$(cd "${p%/*}/" 2>/dev/null && pwd -P)" || continue
    for i in ${bsrc[@]+"${!bsrc[@]}"}; do
      if [[ "$pp" == "${bsrc[i]}" || "$pp" == "${bsrc[i]}"/* ]]; then
        printf 'WARNING: %s is a symlink inside a writable mount (%s); the agent can\n' "$p" "${bdst[i]}" >&2
        printf '         replace it, and a later launch through it would run what replaced it.\n' >&2
        printf '         Launch through the real path instead: %s\n' "$self" >&2
        break
      fi
    done
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
      printf 'NOTE: %s, part of launcher %s, is mounted writable at %s;\n' "${bsrc[i]}" "$x" "${bdst[i]}" >&2
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
        printf 'NOTE: %s holds a launcher and stays writable at %s;\n' "$l" "$dst" >&2
        printf '      what changes there runs on the host at the next launch.\n' >&2
        continue
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
      if ! _mount_representable "$l" "$at"; then ok=""; fi
      for k in ${psrc[@]+"${!psrc[@]}"}; do
        if [[ -n "$ok" ]] && ! _mount_representable "${psrc[k]}" "${pdst[k]}"; then ok=""; fi
      done
      if [[ -z "$ok" ]]; then
        printf 'WARNING: cannot protect %s: docker cannot be handed that name intact,\n' "$l" >&2
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
      if [[ "$kind" == unreadable ]]; then
        printf 'WARNING: %s cannot be listed by you, so it cannot be checked for\n' "$l" >&2
        printf '         launchers; it is mounted read-only at %s.\n' "$at" >&2
        if [[ -O "$l" ]]; then
          printf '         Restore: chmod u+rx %q\n' "$l" >&2
        else
          printf '         It is not yours: ask its owner, or mount it :ro yourself.\n' >&2
        fi
      else
        printf 'READ-ONLY: %s  (launcher files; edit them on the host)\n' "$at" >&2
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
  # is on. They stay: removing one at exit would detach it in any other
  # container still running on that repository. A commondir that is not `./`
  # in a repository's own git directory refuses the launch: git never writes one
  # there, and it sends the host's git elsewhere for config and hooks.
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
  ug=(); usrc=(); udst=(); udep=(); ukind=(); gmax=0
  for i in ${bsrc[@]+"${!bsrc[@]}"}; do
    src="${bsrc[i]}"; dst="${bdst[i]}"
    if [[ -n "${_git_skip_root:-}" && ( "$src" == "$_git_skip_root" || "$src" == "$_git_skip_root"/* ) ]]; then continue; fi
    if [[ "$src" == */.git/* ]]; then
      printf 'NOTE: %s lies inside a git directory and is mounted writable at %s;\n' "$src" "$dst" >&2
      printf '      your host'\''s git may run what changes there.\n' >&2
    fi
    gdirs=(); gfiles=(); glinks=(); gunr=()
    git_dirs_in gdirs gfiles glinks gunr "$src"
    for f in ${glinks[@]+"${glinks[@]}"}; do
      at="$dst${f#"$src"}"; skip=""
      for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
        if [[ "$at" == "$r" || "$at" == "$r"/* ]]; then skip=1; break; fi
      done
      if [[ -n "$skip" ]]; then continue; fi
      printf 'WARNING: %s is a symlink inside a writable mount (%s); the agent can\n' "$f" "$dst" >&2
      printf '         replace it with a git directory of its own, and your host'\''s git would\n' >&2
      printf '         run that one'\''s hooks there. Replace the link with what it names.\n' >&2
    done
    for g in ${gdirs[@]+"${gdirs[@]}"}; do ug+=("$g"); ukind+=(dir); usrc+=("$src"); udst+=("$dst"); done
    for g in ${gfiles[@]+"${gfiles[@]}"}; do ug+=("$g"); ukind+=(file); usrc+=("$src"); udst+=("$dst"); done
    for g in ${gunr[@]+"${gunr[@]}"}; do ug+=("$g"); ukind+=(unr); usrc+=("$src"); udst+=("$dst"); done
  done
  for k in ${ug[@]+"${!ug[@]}"}; do
    at="${udst[k]}${ug[k]#"${usrc[k]}"}"; d="${at//[!\/]/}"
    udep+=("${#d}")
    if (( ${#d} > gmax )); then gmax=${#d}; fi
  done
  gn=0
  gitmax="${SANDBOX_GIT_MAX:-200}"
  if [[ ! "$gitmax" =~ ^[1-9][0-9]{0,5}$ ]]; then
    printf 'ERROR: SANDBOX_GIT_MAX must be a whole number from 1 to 999999 (got %q).\n' "$gitmax" >&2
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
      if [[ -n "$skip" ]]; then continue; fi
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
              printf '         %s\n' "${ug[k2]}" >&2; x=$((x + 1))
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
        if [[ -d "$g/objects" && -f "$g/config" ]]; then
          cfg="$g/config"
          # git makes hooks/ at init, but a repository can lack it — and then the
          # agent could make it.
          if [[ ! -e "$g/hooks" && ! -L "$g/hooks" ]]; then mkdir "$g/hooks" 2>/dev/null || true; fi
          if [[ ! -e "$g/commondir" && ! -L "$g/commondir" ]]; then
            ( set -C; printf './\n' > "$g/commondir" ) 2>/dev/null || true
          fi
          # Anything but our ./ sends the host's git elsewhere for this repository's
          # configuration and hooks, and git never writes one here: refuse, rather
          # than mount the redirect read-only and launch.
          if [[ -f "$g/commondir" && ! -L "$g/commondir" && "$(cat "$g/commondir" 2>/dev/null)" != "./" ]]; then
            printf 'ERROR: %s sends git to %q for this repository'\''s\n' "$g/commondir" "$(head -c 200 "$g/commondir" 2>/dev/null)" >&2
            printf '       configuration and hooks, and git never writes one in a repository'\''s own git\n' >&2
            printf '       directory. If you did not make it, remove it on the host and launch again.\n' >&2
            exit 1
          fi
        elif [[ -f "$g/commondir" ]]; then
          cfg="$(cd "$g" 2>/dev/null && cd "$(cat commondir 2>/dev/null)" 2>/dev/null && pwd -P)/config" || cfg=""
        fi
        if [[ -n "$cfg" && ! -e "$g/config.worktree" && ! -L "$g/config.worktree" ]]; then
          if _git_config_bool "$cfg" extensions.worktreeConfig; then
            ( set -C; : > "$g/config.worktree" ) 2>/dev/null || true
          fi
        fi
        for f in config config.worktree commondir hooks; do
          if [[ -L "$g/$f" ]]; then
            printf 'WARNING: %s is a symlink, which cannot be mounted read-only in place;\n' "$g/$f" >&2
            printf '         what it leads to is what your host'\''s git reads. Replace the link with it.\n' >&2
          elif [[ -e "$g/$f" ]]; then
            gro+=("$g/$f")
          elif [[ "$f" == hooks || "$f" == commondir ]] && [[ -d "$g/objects" ]]; then
            printf 'WARNING: %s has no %s and one could not be made; the agent could make it.\n' "$g" "$f" >&2
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
        printf 'WARNING: cannot protect the git internals of %s: docker cannot be handed\n' "$g" >&2
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
        seen[$x]=1; ro_dsts+=("$x")
        if [[ "$f" != "$g" ]]; then what+="${what:+, }${f##*/}"; fi
      done
      if [[ "$kind" == unr ]]; then
        printf 'WARNING: %s cannot be listed by you, so what it holds cannot be\n' "$g" >&2
        printf '         protected one by one; it is mounted read-only whole at %s.\n' "$at" >&2
        printf '         Restore: chmod u+rx %q\n' "$g" >&2
      elif [[ "$kind" == file ]]; then
        printf 'READ-ONLY: %s  (names the git directory your host'\''s git uses here)\n' "$at" >&2
      else
        printf 'READ-ONLY: %s: %s  (what your host'\''s git runs; change them on the host)\n' "$at" "$what" >&2
      fi
      # Hooks run from a directory core.hooksPath names are project files the
      # overlay leaves writable — and hook managers keep the scripts they run
      # gitignored (husky's .husky/_), so a change need not show in git status.
      if [[ "$kind" == dir && "$cfg" == "$g/config" ]]; then
        hp="$(_git_config_get "$cfg" core.hooksPath)" || hp=""
        if [[ -n "$hp" ]]; then
          # shellcheck disable=SC2088  # '~/'* matches a LITERAL leading ~/ in the config value, expanded by hand
          case "$hp" in
            /*) hpd="$hp" ;;
            '~/'*) hpd="$HOME/${hp#\~/}" ;;
            *) if [[ "$g" == */.git ]]; then hpd="${g%/.git}/$hp"; else hpd="$g/$hp"; fi ;;
          esac
          hpd="$(cd "$hpd" 2>/dev/null && pwd -P)" || hpd=""
          for i in ${bsrc[@]+"${!bsrc[@]}"}; do
            if [[ -z "$hpd" || ( "$hpd" != "${bsrc[i]}" && "$hpd" != "${bsrc[i]}"/* ) ]]; then continue; fi
            x="${bdst[i]}${hpd#"${bsrc[i]}"}"; safe=""
            for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
              if [[ "$x" == "$r" || "$x" == "$r"/* ]]; then safe=1; break; fi
            done
            if [[ -n "$safe" ]]; then continue; fi
            printf 'NOTE: %s runs its git hooks from %s (core.hooksPath), which the agent\n' "$at" "$x" >&2
            printf '      can change; hook managers keep those scripts gitignored (husky'\''s .husky/_),\n' >&2
            printf '      so a change need not show in git status. Check them before a git commit on the host.\n' >&2
            break
          done
        fi
      fi
    done
  done
  if (( gn > 30 )); then
    printf 'NOTE: %d git directories were protected, each with its own bind mounts; that\n' "$gn" >&2
    printf '      adds seconds to every container start on Docker Desktop. Mount narrower\n' >&2
    printf '      directories, or mount the ones you will not change :ro.\n' >&2
  fi

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
  # INTO one are. At most 200 links per launcher, so nothing the agent can
  # write makes every later launch slow.
  for x in "${scan[@]}"; do
    inner=""
    for i in ${bsrc[@]+"${!bsrc[@]}"}; do
      if [[ "${bsrc[i]}" == "$x" ]]; then inner=1; break; fi
    done
    if [[ -n "$inner" ]]; then continue; fi
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
      if (( ++nl > 200 )); then
        printf 'NOTE: %s holds more than 200 symlinks; only the first 200 were checked.\n' "$x" >&2
        break
      fi
      walk=()
      mapfile -d '' -t walk < <(_link_walk "$f")
      for e in ${walk[@]+"${walk[@]}"}; do
        case "$e" in
          =*) how=change;  q="${e#=}" ;;
          ^*) how=replace; q="${e#^}" ;;
          *)  how=repoint; q="$e" ;;
        esac
        # Inside this launcher and in no writable bind of its own (an output
        # directory, say): the way stays home — read-only with the launcher,
        # or the working dir someone is deliberately editing.
        if [[ "$q" == "$x" || "$q" == "$x"/* ]]; then
          inner=""
          for i in ${bsrc[@]+"${!bsrc[@]}"}; do
            if [[ "${bsrc[i]}" == "$x"/* && ( "$q" == "${bsrc[i]}" || "$q" == "${bsrc[i]}"/* ) ]]; then inner=1; break; fi
          done
          if [[ -z "$inner" ]]; then continue; fi
        fi
        w=""
        for i in ${bsrc[@]+"${!bsrc[@]}"}; do
          if [[ "$q" != "${bsrc[i]}" && "$q" != "${bsrc[i]}"/* ]]; then continue; fi
          c="${bdst[i]}${q#"${bsrc[i]}"}"
          safe=""
          for r in ${ro_dsts[@]+"${ro_dsts[@]}"}; do
            if [[ "$c" == "$r" || "$c" == "$r"/* ]]; then safe=1; break; fi
          done
          if [[ -z "$safe" && "$how" == replace ]]; then
            if [[ -n "${pinned[$c]:-}" ]]; then safe=1; fi
            for r in "${bdst[@]}"; do
              if [[ "$c" == "$r" ]]; then safe=1; break; fi
            done
          fi
          if [[ -z "$safe" ]]; then w="$c"; break; fi
        done
        if [[ -z "$w" ]]; then continue; fi
        printf 'WARNING: launcher link %s leads somewhere the agent can change:\n' "$f" >&2
        case "$how" in
          change)  printf '         it can change %s (at %s), which the host reads through it.\n' "$q" "$w" >&2 ;;
          repoint) printf '         it can repoint %s (at %s), a link on its way.\n' "$q" "$w" >&2 ;;
          replace) printf '         it can replace %s (at %s) with a link; the way steps out of it (..).\n' "$q" "$w" >&2 ;;
        esac
        printf '         Replace the link with what it names, or mount that directory :ro.\n' >&2
        break
      done
    done
  done
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
  local cur rest c t n=1
  cur="$(cd "${1%/*}/" 2>/dev/null && pwd -P)" || return 0
  c="${1##*/}"
  printf '%s\0' "$cur/$c"
  _readlink_exact t "$cur/$c" || return 0
  if [[ "$t" == /* ]]; then cur=""; rest="${t#/}"; else rest="$t"; fi
  while [[ -n "$rest" ]]; do
    c="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "$c" in
      ''|.) continue ;;
      ..) if [[ -n "$cur" ]]; then printf '^%s\0' "$cur"; fi; cur="${cur%/*}"; continue ;;
    esac
    if [[ -L "$cur/$c" ]]; then
      if (( ++n > 40 )); then return 0; fi
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
# alone would drop any trailing newlines the target itself ends with.
_readlink_exact() {
  local out
  out="$(readlink -- "$2" && printf x)" || return 1
  out="${out%x}"
  printf -v "$1" '%s' "${out%$'\n'}"
}

# _utf8_valid <string>: is it UTF-8 as RFC 3629 — and Go, whose JSON encoding of
# the request is what rewrites anything else — defines it? No overlongs, no
# surrogates, nothing above U+10FFFF. Not iconv: glibc's accepts both F4 90 80 80
# (above U+10FFFF) and five-byte forms, which Go rejects. Bytes are read as
# decimal numbers, so neither the locale nor the awk in use can change the answer.
_utf8_valid() {
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
  local -A launcher=() seen=()
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
# session to hide what is inside from the next scan). A submodule's checkout is
# also found through its git directory's core.worktree, wherever it lies — a
# vendor/ is pruned by name, and submodules commonly live in one. Git directories
# to seven levels down, so a checkout's own .git is found to six, as launchers
# are; dependency trees are pruned outside .git, and a .git's object store, refs
# and logs, which hold nothing that runs. NUL-delimited; always returns 0.
git_dirs_in() {
  # shellcheck disable=SC2178  # nameref: shellcheck does not model `local -n`
  local -n _gdi_dirs=$1 _gdi_files=$2 _gdi_links=$3 _gdi_unr=$4
  local f g wt co
  local -a hits=()
  local -A had=()
  mapfile -d '' -t hits < <(find "$5" -mindepth 1 -maxdepth 8 \
      \( \( \( -name node_modules -o -name vendor -o -name .venv -o -name target \) ! -path '*/.git/*' \) \
         -o -path '*/.git/objects' -o -path '*/.git/refs' -o -path '*/.git/logs' \
         -o -path '*/.git/modules/*/objects' -o -path '*/.git/modules/*/refs' -o -path '*/.git/modules/*/logs' \) -prune \
      -o -type f -name HEAD -print0 \
      -o -name .git \( -type f -o -type l -o -type d \) -print0 \
      -o -type d -path '*/.git/*' -print0 2>/dev/null)
  for f in ${hits[@]+"${hits[@]}"}; do
    if [[ "${f##*/}" == .git ]]; then
      if [[ -L "$f" ]]; then _gdi_links+=("$f")
      elif [[ -f "$f" ]]; then _gdi_files+=("$f"); had[$f]=1
      elif [[ -d "$f" && ( ! -r "$f" || ! -x "$f" ) ]]; then _gdi_unr+=("$f")
      fi
      continue
    fi
    if [[ -d "$f" ]]; then
      if [[ ! -r "$f" || ! -x "$f" ]]; then _gdi_unr+=("$f"); fi
      continue
    fi
    g="${f%/HEAD}"
    if [[ ( -f "$g/config" && -d "$g/objects" ) || -f "$g/commondir" ]]; then _gdi_dirs+=("$g"); fi
  done
  # Submodules the scan cannot see — a vendor/ is pruned by name, and submodules
  # commonly live in one: an absorbed one's checkout through its git directory's
  # core.worktree, and every submodule a repository's INDEX records (a gitlink),
  # whose .git may be a directory embedded in the checkout. Followed until
  # nothing new turns up, so a submodule's own submodules are found too. The
  # index is read with git, fsmonitor off, so a config tampered with before this
  # protection existed runs nothing here; without git, only what the scan sees.
  for g in ${_gdi_dirs[@]+"${_gdi_dirs[@]}"}; do had[$g]=1; done
  local n=0 top rec mode path
  local -a links=()
  while (( n < ${#_gdi_dirs[@]} )); do
    g="${_gdi_dirs[n]}"; n=$((n + 1))
    [[ -f "$g/config" && -d "$g/objects" ]] || continue
    top=""
    if [[ "$g" == */.git/modules/* ]]; then
      wt="$(_git_config_get "$g/config" core.worktree)" || wt=""
      if [[ -n "$wt" ]]; then top="$(cd "$g" 2>/dev/null && cd "$wt" 2>/dev/null && pwd -P)" || top=""; fi
    elif [[ "$g" == */.git ]]; then
      top="${g%/.git}"
    fi
    [[ -n "$top" ]] || continue
    if [[ "$g" == */.git/modules/* && -f "$top/.git" && ! -L "$top/.git" && -z "${had[$top/.git]:-}" ]] \
       && [[ "$top" == "$5" || "$top" == "$5"/* ]]; then
      _gdi_files+=("$top/.git"); had[$top/.git]=1
    fi
    command -v git >/dev/null 2>&1 || continue
    links=()
    # From the work tree's root: run from a subdirectory (sandbox.sh runs from
    # .ai-containers), ls-files lists only what lies under it.
    # safe.directory='*': a repository another user owns would otherwise refuse
    # to be read, and its submodules go unprotected; ls-files runs nothing from a
    # repository's config once fsmonitor is off.
    mapfile -d '' -t links < <(git -C "$top" -c core.fsmonitor=false -c safe.directory='*' \
        --git-dir="$g" --work-tree="$top" ls-files -s -z 2>/dev/null)
    for rec in ${links[@]+"${links[@]}"}; do
      mode="${rec%% *}"; path="${rec#*$'\t'}"
      [[ "$mode" == 160000 && -n "$path" ]] || continue
      co="$top/$path"; f="$co/.git"
      [[ "$co" == "$5"/* ]] || continue
      if [[ -L "$f" ]]; then
        [[ -n "${had[$f]:-}" ]] || { _gdi_links+=("$f"); had[$f]=1; }
      elif [[ -f "$f" ]]; then
        [[ -n "${had[$f]:-}" ]] || { _gdi_files+=("$f"); had[$f]=1; }
      elif [[ -d "$f" && -f "$f/HEAD" && -f "$f/config" && -d "$f/objects" && -z "${had[$f]:-}" ]]; then
        _gdi_dirs+=("$f"); had[$f]=1
      fi
    done
  done
  return 0
}

# _git_config_bool <config-file> <key>: succeeds when git would read the key as
# true — with git's own --type=bool, or else as git spells true: a bare key, or
# true/yes/on, or a non-zero integer.
_git_config_bool() {
  local v
  if command -v git >/dev/null 2>&1; then
    v="$(git config --file "$1" --type=bool --get "$2" 2>/dev/null)" || return 1
    [[ "$v" == true ]]; return
  fi
  awk -v sec="${2%.*}" -v key="${2##*.}" '
    /^[[:space:]]*\[/ { s = tolower($0); gsub(/[][[:space:]]/, "", s); insec = (s == tolower(sec)); next }
    insec {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]*([#;].*)?$/, "", line)
      n = index(line, "="); k = n ? substr(line, 1, n - 1) : line; sub(/[[:space:]]+$/, "", k)
      if (tolower(k) != tolower(key)) next
      if (!n) { r = 1; next }
      v = tolower(substr(line, n + 1)); gsub(/[[:space:]]/, "", v)
      r = (v == "true" || v == "yes" || v == "on" || (v ~ /^-?[0-9]+$/ && v + 0 != 0))
    }
    END { exit !r }' "$1" 2>/dev/null
}

# _git_config_get <config-file> <key>: a key's value from one git config file —
# with git, which reads it exactly, or else the first `<name> = value` line of
# the key's section, which covers what git itself writes. Fails when unset.
_git_config_get() {
  local v
  if command -v git >/dev/null 2>&1; then
    v="$(git config --file "$1" --get "$2" 2>/dev/null)" || return 1
    printf '%s' "$v"; return 0
  fi
  awk -v sec="${2%.*}" -v key="${2##*.}" '
    /^[[:space:]]*\[/ { s = tolower($0); gsub(/[][[:space:]]/, "", s); insec = (s == tolower(sec)); next }
    insec {
      line = $0; sub(/^[[:space:]]+/, "", line)
      n = index(line, "="); if (!n) next
      k = substr(line, 1, n - 1); sub(/[[:space:]]+$/, "", k)
      if (tolower(k) != tolower(key)) next
      v = substr(line, n + 1); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; found = 1; exit
    }
    END { exit !found }' "$1" 2>/dev/null
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
  local want_url
  want_url="$(git -C "$want" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$want_url" ]] && (( ${#repo_source_url[@]} )); then
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

# Set by run_container when it creates a launcher-mount verify dir; removed by
# the EXIT trap below. A global, not a run_container local, so the trap can see
# it, and guarded with :- so `set -u` is satisfied when no dir was made.
_launcher_verify_dir=""
# A named group's directory, which launcher_ro_overlay does not scan for git
# repositories (the host's git never runs there). Set by run_container.
_git_skip_root=""
trap 'rm -rf "${_launcher_verify_dir:-}" 2>/dev/null' EXIT

run_container() {
  check_config
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
  local sandbox_username="${SANDBOX_USER:-$(id -un)}"
  local dev_home="/home/$sandbox_username"

  # Agent outputs → host launch dir, surfaced under the /workspace umbrella.
  local output_mount_flags=()
  if [[ "$mode" == "discovery" ]]; then
    capture_enabled="1"
    mkdir -p "$launch_dir/.agent-discovery"
    output_mount_flags+=(-v "$launch_dir/.agent-discovery:/workspace/.agent-discovery")
  elif [[ "$mode" == "restricted" ]]; then
    mkdir -p "$launch_dir/.agent-blocked"
    output_mount_flags+=(-v "$launch_dir/.agent-blocked:/workspace/.agent-blocked")
  fi
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
    _git_skip_root="$(cd "$group_root" 2>/dev/null && pwd -P)" || _git_skip_root=""
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
      install -d "$group_root/.claude" \
                 "$group_root/.local/share/claude" "$group_root/.local/state/claude"
      [[ -e "$group_root/.claude.json" ]] || printf '{}\n' > "$group_root/.claude.json"
    fi
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
  if is_active ruby; then
    if [[ "$group" == "host" ]]; then
      # The host group's contract is "mount my real $HOME dirs" — honour it rather
      # than silently substituting a volume for one of them. Consequence on macOS:
      # rvm cannot bootstrap in the host group (see the tar/virtiofs note on
      # rvm_volume_name in sandbox-common.sh); use a named group for Ruby work.
      add_mount_if_exists config_mount_flags "$group_root/.rvm" "$dev_home/.rvm"
    else
      # Named groups get a docker volume, never a bind mount — a bind mount cannot
      # host an rvm install on macOS at all. rvm_volume_ensure creates it on first
      # use and migrates a pre-volume ~/.rvm across if one is there.
      local rvm_vol
      if rvm_vol="$(rvm_volume_ensure "$group" "$group_root" "$image_name")"; then
        config_mount_flags+=(-v "$rvm_vol:$dev_home/.rvm")
      else
        printf 'WARNING: no rvm volume for group %s — Ruby will be unavailable.\n' "$group" >&2
      fi
    fi
  fi
  if [[ -n "$(runtime_tools_csv)" ]]; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.ai-tools"
    fi
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
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.yarn"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.yarn" "$dev_home/.yarn"
  fi
  if is_enabled aws-cli; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.aws"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.aws" "$dev_home/.aws"
  fi
  if is_enabled azure-cli; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.azure"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.azure" "$dev_home/.azure"
  fi
  if is_enabled kubectl; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.kube"
    fi
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
      if [[ "$group" != "host" ]]; then
        if [[ ! -e "$group_root/$_cdir" && -e "$HOME/$_cdir" ]]; then
          install -d "$(dirname "$group_root/$_cdir")"
          cp -a "$HOME/$_cdir" "$group_root/$_cdir"
        else
          install -d "$group_root/$_cdir"
        fi
        add_mount_if_exists config_mount_flags "$group_root/$_cdir" "$dev_home/$_cdir"
      else
        add_mount_if_exists config_mount_flags "$HOME/$_cdir" "$dev_home/$_cdir"
      fi
    done
  done < <(tools_list_names)
  if is_enabled qmd; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.cache/qmd"
    fi
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
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.cache/ms-playwright"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.cache/ms-playwright" "$dev_home/.cache/ms-playwright"
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
  local launcher_ro_flags=() launcher_verify=()
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
      : > "$_vdir/manifest"
      for (( _i = 0; _i < ${#launcher_verify[@]}; _i += 2 )); do
        _vsrc="${launcher_verify[_i]}"; _vdst="${launcher_verify[_i+1]}"
        if read -r _vdev _vino < <(_launcher_dev_ino "$_vsrc"); then :; else _vdev=0; _vino=0; fi
        printf '%s\0%s\0%s\0' "$_vdev" "$_vino" "$_vdst" >> "$_vdir/manifest"
      done
      launcher_verify_flags=(-v "$_vdir:/run/ai-launcher:ro")
      local _adev="" _aino=""
      read -r _adev _aino < <(_launcher_dev_ino "$_vdir") || true
      launcher_anchor_env=(-e "AI_LAUNCHER_ANCHOR=${_adev}:${_aino}")
    else
      printf 'WARNING: could not create %s; launcher mounts will not be verified against\n' "$_vdir" >&2
      printf '         a concurrent-container swap this launch.\n' >&2
    fi
  fi

  # Claude Code's own sandbox (claude-code-sandbox=ON) runs each shell command
  # Claude starts inside bubblewrap, which must create its namespaces and then
  # mount and pivot_root inside them. Docker's default profiles refuse both halves:
  # - the namespace: AppArmor. Where Docker's kernel is Ubuntu 24.04's — on a Mac,
  #   the Linux VM Docker runs in (measured in a Lima VM) —
  #   kernel.apparmor_restrict_unprivileged_userns=1 refuses it under
  #   docker-default, and still strips it of its capabilities under
  #   apparmor=unconfined. A profile that grants `userns` is exempt:
  #   ai-containers-sandbox.apparmor is docker-default plus userns, mount and
  #   pivot_root, and integration case 790 passes under it on such a kernel.
  # - the namespaces and the mounts: seccomp. Docker's profile refuses clone with
  #   a namespace flag, unshare, mount and umount2 to a container without
  #   CAP_SYS_ADMIN, which this one never holds, and pivot_root to every
  #   container. ai-containers-sandbox.seccomp.json is Docker's profile with those
  #   five allowed (unshare: bubblewrap's second user namespace, which it creates
  #   whenever it mounts /dev). The Docker client reads the file and sends it with
  #   the container, so, unlike the AppArmor profile, it is never loaded anywhere.
  # The AppArmor profile must be loaded where Docker's kernel runs, and a container
  # started without it would stop every Claude Code session at startup
  # (failIfUnavailable), so a throwaway container under both profiles proves they
  # apply before the real one starts. A refusal that does not name AppArmor is
  # Docker's own (an unreadable seccomp profile, say) and is shown as Docker gave
  # it. Both options apply only when the key asks for the inner sandbox: every
  # other container composes exactly the `docker run` it did before.
  local inner_sandbox_flags=() probe_err
  if is_enabled claude-code-sandbox; then
    inner_sandbox_flags=(--security-opt "seccomp=$script_dir/ai-containers-sandbox.seccomp.json"
                         --security-opt apparmor=ai-containers-sandbox)
    if ! probe_err="$(docker run --rm --entrypoint true "${inner_sandbox_flags[@]}" "$image_name" 2>&1 >/dev/null)"; then
      if grep -qi 'apparmor' <<<"$probe_err"; then
        claude_sandbox_profile_missing "$script_dir/ai-containers-sandbox.apparmor"
      else
        printf 'claude-code-sandbox=ON, but Docker cannot start a container with its security options:\n%s\n' "$probe_err" >&2
        printf 'See docs/components/claude-code-sandbox.md. Or set claude-code-sandbox=OFF.\n' >&2
      fi
      exit 1
    fi
  fi

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
    -e REPOS_PATH="${REPOS_PATH:-/workspace}"
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

  docker run -it --rm \
    --name "$container_name" \
    ${capabilities[@]+"${capabilities[@]}"} \
    ${inner_sandbox_flags[@]+"${inner_sandbox_flags[@]}"} \
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
    "$image_name"
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
