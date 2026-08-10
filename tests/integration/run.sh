#!/usr/bin/env bash
# run.sh — the runtime integration test runner.
#
# Cases never know whether they are on CI. They declare `tags:` and `requires:`
# in header comments; this script detects what the machine can actually do,
# SELECTS a subset by tag, executes each selected case as its own process under
# `timeout`, and reports selection and skips as SEPARATE counts.
#
# That separation is the point. --tags/--exclude decide what is selected — a
# deliberate, visible choice recorded in the workflow. A SKIP is a case that WAS
# selected and then could not run because a requirement was unmet. --require
# makes any skip inside the selected set fatal. Collapsing the two would let
# "we chose not to check this" read as "this passed".
#
# Written for bash 3.2 (stock macOS bash).
set -uo pipefail

INT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Layout-tolerant: upstream ai-containers keeps the engine beside tests/;
# mgd-ai-containers keeps it in base/ with tests/ one level up.
REPO_DIR="$(cd "$INT_DIR/../.." && pwd)"
[[ -f "$REPO_DIR/build.sh" ]] || REPO_DIR="$(cd "$INT_DIR/../../base" && pwd)"

CASES_DIR="${IT_CASES_DIR:-$INT_DIR/cases}"
IT_RUN_ID="${IT_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
IT_LABEL="ai-containers.it-run=$IT_RUN_ID"
# Under $HOME, never $TMPDIR: this becomes a bind-mount source, and macOS
# /var/folders is not shared with the Colima VM — the container would write into
# the VM and the host would read an empty directory.
IT_SCRATCH="${IT_SCRATCH:-$HOME/.cache/ai-containers-it/$IT_RUN_ID}"
IT_IMAGE="${IT_IMAGE:-ai-sandbox-it}"
IT_NET="${IT_NET:-ai-containers-it-$IT_RUN_ID}"
IT_DNS_IMAGE="${IT_DNS_IMAGE:-coredns/coredns:1.11.3}"
IT_CONNECT_TIMEOUT="${IT_CONNECT_TIMEOUT:-5}"
# No numeric default here on purpose: tests/integration/lib.sh (sourced by
# every case) owns this value — it applies a floor (currently 60, driven by a
# measured ~22s tshark-attach cost) and prints a stderr notice if it has to
# raise whatever arrives here. Bash's "${IT_SETTLE:-}" treats unset and empty
# alike, so leaving this blank still lets lib.sh's own default/floor apply
# unchanged. Do not reintroduce a number here — it would just be a second,
# driftable source of truth for the same setting.
IT_SETTLE="${IT_SETTLE:-}"
IT_GENERATED_ALLOWLIST_DIR="$IT_SCRATCH/generated-allowlists"
# Resolved once, here, while PATH is still clean: the mounts/groups/volumes
# cases put tests/integration/docker-shim.sh on PATH as `docker`, and the shim
# refuses to run without an explicit real binary rather than recurse into itself.
IT_REAL_DOCKER="${IT_REAL_DOCKER:-$(command -v docker 2>/dev/null)}"

want_tags=""; excl_tags=""; req_tags=""
do_list=0; do_list_caps=0; reuse_image=0; keep=0; verbose=0
timeout_secs=300
# Declared here, not just in the "Execution" section below, so it is defined
# under `set -u` for EVERY exit path — including one that exits before the
# execution loop ever runs (e.g. build_image failing) — because sweep()'s
# EXIT trap reads it to decide whether to keep $IT_SCRATCH.
n_fail=0

usage() {
  cat <<'EOF'
Usage: tests/integration/run.sh [options]

  --tags T[,T…]      run only cases carrying at least one of these tags
  --exclude T[,T…]   drop cases carrying any of these tags
  --require T[,T…]   fail the run if any SELECTED case with this tag SKIPPED
  --timeout N        per-case timeout in seconds (default 300)
  --image NAME       image tag to build/use (default ai-sandbox-it)
  --reuse-image      do not build; use the existing --image
  --keep             keep the image, network and scratch dir after the run
  --list             list cases with their tags/requires and exit
  --list-caps        print detected capabilities and exit
  -v, --verbose      stream each case's full output
  -h, --help         this text

Tags: network-mode mounts volumes groups packages | security | fast slow |
      needs-external needs-netadmin needs-dns | harness
Requires: docker netadmin sidecar dns external launcher
EOF
}

# IT_SOURCE_ONLY (see the early return before the sweep EXIT trap, below) means
# run.sh is being sourced by tests/test-integration-runner.sh's callfn.sh
# helper, which reuses "$@" as a FUNCTION NAME plus its arguments, not CLI
# flags — `source` shares positional parameters with its caller, so parsing
# them here would read e.g. "variant_overrides" as an unrecognised option and
# `exit 2`, which kills the whole sourcing process (not just this loop) before
# the requested function is ever called.
while [[ -z "${IT_SOURCE_ONLY:-}" && $# -gt 0 ]]; do
  # A value-taking option with no value must be a usage error, not a crash.
  # Without this guard `run.sh --tags` aborts with "line NN: 2: unbound variable"
  # under set -u — a message that names neither the option nor the problem, from a
  # script whose whole purpose is making failures legible.
  case "$1" in
    --tags|--exclude|--require|--timeout|--image)
      if [[ $# -lt 2 ]]; then
        printf 'run.sh: %s requires a value\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac

  case "$1" in
    --tags)     want_tags="${2//,/ }"; shift 2 ;;
    --exclude)  excl_tags="${2//,/ }"; shift 2 ;;
    --require)  req_tags="${2//,/ }";  shift 2 ;;
    --timeout)  timeout_secs="$2";     shift 2 ;;
    --image)    IT_IMAGE="$2";         shift 2 ;;
    --reuse-image) reuse_image=1; shift ;;
    --keep)     keep=1;    shift ;;
    --list)     do_list=1; shift ;;
    --list-caps) do_list_caps=1; shift ;;
    -v|--verbose) verbose=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'run.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done


# ── Portable timeout ────────────────────────────────────────────────────────────
# `timeout` is GNU coreutils. macOS ships NEITHER it nor a BSD equivalent, so on a
# Mac every `timeout ... bash "$case"` exited 127 ("command not found") and the
# runner reported all 14 selected cases as FAILED in 0s. The `timeout 120 docker
# pull` in detect_caps died the same way, which is why the dns capability was
# never detected there either — two symptoms, one cause, and the second looked
# convincingly like "Colima cannot do DNS".
#
# CI never saw this: ubuntu-latest has coreutils. It took the first real macOS run
# (host verification, 2026-08-08) to surface it, which is precisely the class of
# gap that run exists to catch — the plan's Global Constraints checked bash 3.2
# SYNTAX (no declare -A, no mapfile) but never GNU-only COMMANDS.
#
# Resolution order: GNU timeout, then Homebrew coreutils' gtimeout, then a pure
# bash fallback. The fallback runs the command in the background, polls for its
# exit, and kills it past the deadline — returning 124 like the real thing, so the
# caller's "timed out" branch is identical on every platform.
if command -v timeout >/dev/null 2>&1; then
  it_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  it_timeout() { gtimeout "$@"; }
else
  it_timeout() {  # $1=seconds, $2… = command
    local secs="$1"; shift
    "$@" &
    local cmd_pid=$!
    local waited=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
      if [[ "$waited" -ge "$secs" ]]; then
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 2
        kill -KILL "$cmd_pid" 2>/dev/null
        wait "$cmd_pid" 2>/dev/null
        return 124        # same code GNU timeout uses, so callers need no branch
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$cmd_pid"
  }
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── Case metadata ───────────────────────────────────────────────────────────────
case_meta() {  # $1=file $2=key → the header value, or empty
  sed -n "s/^#[[:space:]]*$2:[[:space:]]*//p" "$1" | head -1
}

# ── Image variants ──────────────────────────────────────────────────────────────
# The corpus ran on ONE image until the packages tier: the firewall does not know
# which fragment a domain came from, so proving admit/drop once proves it for
# every fragment, and N per-component images bought nothing. The packages tier is
# the exception — it asserts that components INSTALL, which is per-component by
# construction.
#
# Two variants, not three. The split is KEEP_BUILD_TOOLCHAIN, a distinction the
# Dockerfile itself makes: `agents` has it unset (the configuration most users
# ship), `native` has it set by ruby=/db-clients=. A single kitchen-sink image
# could only ever exercise the toolchain-kept path, so the agent-tier tools would
# never be tested in the configuration they actually ship in.
#
# Grouped with case_meta and placed after it, not up near IT_IMAGE: case_variant
# calls case_meta, and keeping producer and consumer together beats matching the
# top-of-file variable block this would otherwise sit in.
IT_RUBY_VERSIONS="${IT_RUBY_VERSIONS:-3.3.6,3.4.5}"

variant_overrides() {  # $1=variant → space-separated key=value; rc 1 if unknown
  case "$1" in
    default) printf '' ;;
    agents)  printf 'copilot=ON claude-code=ON codex=ON gemini=ON graphify=ON vale=ON node=22,20' ;;
    native)  printf 'db-clients=pg,mysql,mongo imagemagick=ON wkhtmltopdf=ON ruby=%s' "$IT_RUBY_VERSIONS" ;;
    *)       return 1 ;;
  esac
  return 0
}

variant_image() {  # $1=variant → the image tag to build/run
  case "$1" in
    default) printf '%s' "$IT_IMAGE" ;;
    *)       printf '%s-%s' "$IT_IMAGE" "$1" ;;
  esac
}

case_variant() {  # $1=case file → its variant, or `default`
  local v; v="$(case_meta "$1" image)"
  printf '%s' "${v:-default}"
}

list_intersects() {  # $1, $2 = space-separated lists → 0 if they share a member
  local a b
  for a in $1; do for b in $2; do [[ "$a" == "$b" ]] && return 0; done; done
  return 1
}

selected_variants() {  # $@=case files → distinct variants, first-seen order
  # bash 3.2: no associative arrays. Space-padded membership test, the same
  # shape have_cap() and list_intersects() already use.
  local f v seen=""
  for f in "$@"; do
    v="$(case_variant "$f")"
    case " $seen " in *" $v "*) ;; *) seen="${seen:+$seen }$v" ;; esac
  done
  printf '%s' "$seen"
}

all_cases() {
  local f
  for f in "$CASES_DIR"/*.sh; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
}

# ── Capability detection ────────────────────────────────────────────────────────
# Memoised, and lazy: --list must work on a machine with no daemon at all.
_caps=""; _caps_forced=0
detect_caps() {
  [[ -n "$_caps" ]] && return 0
  if [[ -n "${IT_FORCE_CAPS:-}" ]]; then
    _caps=" ${IT_FORCE_CAPS} "; _caps_forced=1; return 0
  fi
  local c=""
  if docker info >/dev/null 2>&1; then
    c="$c docker"
    if docker network create --label "$IT_LABEL" "${IT_NET}-probe" >/dev/null 2>&1; then
      c="$c sidecar"
      docker network rm "${IT_NET}-probe" >/dev/null 2>&1 || true
    fi
    if [[ "$reuse_image" -eq 1 ]] || docker image inspect "$IT_IMAGE" >/dev/null 2>&1; then
      probe_netadmin && c="$c netadmin"
      probe_launcher && c="$c launcher"
    fi
    # "Can this machine run a DNS-backed case?" — not "is the image already
    # cached". `docker image inspect` alone answers the second, and on a fresh CI
    # runner the answer is always no, so the needs-dns cases would SKIP forever
    # while looking like a deliberate capability gap. Try the cache first (fast,
    # offline-safe), then a bounded pull. A machine with no registry access still
    # correctly reports no dns capability rather than hanging.
    if docker image inspect "$IT_DNS_IMAGE" >/dev/null 2>&1 \
       || it_timeout 120 docker pull "$IT_DNS_IMAGE" >/dev/null 2>&1; then
      c="$c dns"
    fi
  fi
  curl -fsS --max-time 8 -o /dev/null https://example.com 2>/dev/null && c="$c external"
  _caps=" $c "
}

# Can a container here create an ipset and install match-set + NFLOG rules?
# This is the single question the whole security tier rests on (see Task 0).
probe_netadmin() {
  docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW --label "$IT_LABEL" \
    --entrypoint bash "$IT_IMAGE" -c '
      ipset create it_probe hash:net family inet   >/dev/null 2>&1 || exit 1
      iptables -A OUTPUT -m set --match-set it_probe dst -j ACCEPT >/dev/null 2>&1 || exit 1
      iptables -A OUTPUT -j NFLOG --nflog-group 100 >/dev/null 2>&1 || exit 1
    ' >/dev/null 2>&1
}

# Can this machine drive the REAL sandbox.sh through the docker shim?
#
# Without this probe, a daemon that rejected the rewritten invocation would make
# every mounts/groups/volumes case fail at its assertions, looking exactly like a
# mount bug — the harness sending a human to hunt in the wrong file. Detect it
# instead, so those cases SKIP naming `launcher`, and --require can make that
# fatal. A case that cannot run is not a pass.
#
# The probe issues the SAME SHAPE sandbox.sh:768 does — `docker run -it --rm`
# with no name and no label — so it exercises the actual `-it` → `-d -i` rewrite
# rather than a simplified stand-in that could pass while the real thing fails.
probe_launcher() {
  [[ -n "$IT_REAL_DOCKER" && -x "$IT_REAL_DOCKER" ]] || return 1
  [[ -x "$INT_DIR/docker-shim.sh" ]] || return 1
  local d="$IT_SCRATCH/launcher-probe" name="it-probe-launcher-$IT_RUN_ID" rc=1
  mkdir -p "$d" || return 1
  ln -sf "$INT_DIR/docker-shim.sh" "$d/docker" || return 1
  (
    export PATH="$d:$PATH" IT_REAL_DOCKER IT_LAUNCH_NAME="$name" IT_LABEL
    docker run -it --rm --entrypoint sleep --label "$IT_LABEL" "$IT_IMAGE" 120
  ) >/dev/null 2>&1
  if [[ "$($IT_REAL_DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    rc=0
  fi
  "$IT_REAL_DOCKER" rm -f "$name" >/dev/null 2>&1
  rm -rf "$d"
  return "$rc"
}

have_cap() { detect_caps; case "$_caps" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

unmet_requirement() {  # $1 = space-separated requires → prints the FIRST unmet one
  local r
  for r in $1; do have_cap "$r" || { printf '%s' "$r"; return 0; }; done
  return 1
}

# ── --list / --list-caps ────────────────────────────────────────────────────────
if [[ "$do_list" -eq 1 ]]; then
  for f in $(all_cases); do
    printf '%-46s  tags: %-34s  requires: %s\n' \
      "$(basename "$f" .sh)" "$(case_meta "$f" tags)" "$(case_meta "$f" requires)"
  done
  exit 0
fi
if [[ "$do_list_caps" -eq 1 ]]; then
  detect_caps
  printf 'capabilities:%s%s\n' "$_caps" \
    "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"
  exit 0
fi

# ── Image build + allowlist snapshot ────────────────────────────────────────────
# build.sh regenerates allowlist-*.txt IN THE REPO from sandbox.conf. Building
# from a minimal config would otherwise leave the developer's real allowlists
# replaced by a stripped-down set, silently, until their next ./build.sh.
#
# Both functions below are only ever CALLED when a build is about to happen
# (guarded by `[[ "$reuse_image" -eq 0 ]]` at each call site, not here — see
# those sites). This is not an optimisation to skip redundant I/O: with
# --reuse-image, build_image() never runs, so the real allowlist-*.txt files
# are never modified in the first place, and there is nothing to protect. Do
# NOT "simplify" the call sites back to unconditional — that would make every
# --reuse-image run (i.e. every hermetic unit-test invocation in
# tests/test-integration-runner.sh) read and then rewrite the real repo's
# allowlist-*.txt on every call, rewriting their mtimes even though content is
# byte-identical, and would race destructively against a concurrent, real
# (reuse_image=0) run that is mid-build_image(): that run's freshly generated
# allowlists would get clobbered by this run's stale snapshot on exit.
saved_allowlists="$IT_SCRATCH/saved-allowlists"
snapshot_real_allowlists() {
  mkdir -p "$saved_allowlists"
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    [[ -f "$REPO_DIR/$f" ]] && cp "$REPO_DIR/$f" "$saved_allowlists/$f"
  done
  return 0
}
restore_real_allowlists() {
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    [[ -f "$saved_allowlists/$f" ]] && cp "$saved_allowlists/$f" "$REPO_DIR/$f"
  done
  return 0
}

build_image() {  # $1=variant
  local variant="${1:-default}"
  local img; img="$(variant_image "$variant")"
  local overrides; overrides="$(variant_overrides "$variant")" || {
    warn "run.sh: unknown image variant '$variant'"
    return 1
  }
  local conf="$IT_SCRATCH/minimal-sandbox-$variant.conf"
  # Everything optional OFF, then the variant's overrides applied on top. The
  # rule lives in minimal-conf.sh because lib.sh's launcher_conf needs the SAME
  # one — a case drives the real sandbox.sh, which re-reads sandbox.conf at
  # launch time. Two copies of this derivation drifted apart once already; the
  # image then carried a component the launcher did not mount, and the case
  # failed on a missing directory that was correct behaviour.
  bash "$INT_DIR/minimal-conf.sh" "$REPO_DIR/sandbox.conf" $overrides > "$conf" || {
    warn "run.sh: could not derive a minimal sandbox.conf for variant '$variant'"
    return 1
  }
  say "── building $img (variant: $variant)…"
  ( cd "$REPO_DIR" && SANDBOX_CONF="$conf" IMAGE_NAME="$img" ./build.sh "$img" ) \
    > "$IT_SCRATCH/build-$variant.log" 2>&1 || {
      warn "run.sh: image build FAILED for variant '$variant' — last 40 lines of $IT_SCRATCH/build-$variant.log:"
      tail -40 "$IT_SCRATCH/build-$variant.log" >&2
      return 1
    }
  # Snapshot what build.sh generated, for the delivery case (300). Only the
  # default variant: 300 asserts the corpus image's allowlist, and a later
  # variant's build would overwrite the snapshot with a different one.
  if [[ "$variant" == "default" ]]; then
    mkdir -p "$IT_GENERATED_ALLOWLIST_DIR"
    local f
    for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
      cp "$REPO_DIR/$f" "$IT_GENERATED_ALLOWLIST_DIR/$f"
    done
  fi
  say "   build OK"
}

# ── Teardown ────────────────────────────────────────────────────────────────────
sweep() {
  # Gated on reuse_image: see the comment above snapshot_real_allowlists(). No
  # build ran, so nothing was snapshotted, and restoring here would still
  # touch the real repo for no reason (rewrite-with-identical-content).
  [[ "$reuse_image" -eq 0 ]] && restore_real_allowlists
  docker ps -aq --filter "label=$IT_LABEL" 2>/dev/null | while read -r c; do
    [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1
  done
  # Volumes, after the containers that hold them. The launcher creates some on
  # its own — a group's rvm volume, a :rwcopy working copy — and those are
  # multi-GB-capable debris if left behind.
  #
  # Label-scoped, and that is the whole safety argument: a volume only carries
  # this run's label if it was created THROUGH the shim, i.e. by a case. A real
  # `ai-containers-repo-<name>` or a developer's group volume was created by a
  # normal docker and cannot match, so this can never reach outside the run —
  # unlike a name-prefix filter, which is exactly how a sweep starts eating
  # production volumes.
  docker volume ls -q --filter "label=$IT_LABEL" 2>/dev/null | while read -r v; do
    [[ -n "$v" ]] && docker volume rm "$v" >/dev/null 2>&1
  done
  docker network ls -q --filter "label=$IT_LABEL" 2>/dev/null | while read -r n; do
    [[ -n "$n" ]] && docker network rm "$n" >/dev/null 2>&1
  done
  # Image cleanup is independent of failures; only --keep preserves it.
  if [[ "$keep" -eq 0 && "$reuse_image" -eq 0 ]]; then
    docker rmi "$IT_IMAGE" >/dev/null 2>&1
  fi
  # $IT_SCRATCH/logs is the ONLY record of why a case failed. CI's "Collect
  # diagnostics" step copies $IT_SCRATCH into an upload artifact, but that
  # step runs AFTER run.sh has already exited and this EXIT trap has already
  # fired — an unconditional `rm -rf` here deleted the logs before the copy
  # ever ran, which is how a red run shipped a 198-byte (empty) diagnostics
  # artifact: the exact "harness must never make a human ask for the next
  # round of output" failure this suite exists to prevent (see lib.sh's
  # it_diagnose). Keep scratch whenever this run had a failure, exactly as
  # --keep does, and say so on stderr so the path is discoverable without a
  # re-run.
  if [[ "$keep" -eq 1 ]]; then
    say "── kept: image $IT_IMAGE, scratch $IT_SCRATCH"
  elif [[ "$n_fail" -gt 0 ]]; then
    warn "── kept scratch ($n_fail failing case(s) — logs are the evidence): $IT_SCRATCH"
  else
    rm -rf "$IT_SCRATCH"
  fi
  return 0
}

# Sourced by tests/test-integration-runner.sh (via its callfn.sh helper) to
# unit-test the pure functions above without a Docker daemon. Cut here, not at
# the "── Selection ───" banner below: `trap 'sweep' EXIT` would otherwise fire
# sweep()'s real `docker` calls when callfn.sh's process exits, and the
# build_image()/mkdir/`docker network create` block right after it would try a
# real image build. Every line from here down performs real I/O — that is what
# a hermetic test must never reach, not just the selection/execution loop.
[[ -n "${IT_SOURCE_ONLY:-}" ]] && return 0 2>/dev/null

trap 'sweep' EXIT

mkdir -p "$IT_SCRATCH/logs"
# Gated on reuse_image: see the comment above snapshot_real_allowlists(). Only
# take (and later restore) a snapshot when build_image() is actually about to
# regenerate the real files — this is what keeps a --reuse-image run (every
# hermetic unit-test invocation) from touching the real repo at all.
if [[ "$reuse_image" -eq 0 ]]; then
  snapshot_real_allowlists
fi
docker network create --label "$IT_LABEL" "$IT_NET" >/dev/null 2>&1 || true

export IT_RUN_ID IT_LABEL IT_SCRATCH IT_IMAGE IT_NET IT_DNS_IMAGE \
       IT_CONNECT_TIMEOUT IT_SETTLE IT_GENERATED_ALLOWLIST_DIR IT_REAL_DOCKER

# ── Selection ───────────────────────────────────────────────────────────────────
total=0; selected=""
for f in $(all_cases); do
  total=$((total + 1))
  tags="$(case_meta "$f" tags)"
  [[ -n "$want_tags" ]] && { list_intersects "$tags" "$want_tags" || continue; }
  [[ -n "$excl_tags" ]] && { list_intersects "$tags" "$excl_tags" && continue; }
  selected="${selected:+$selected }$f"
done

detect_caps
printf 'capabilities:%s%s\n\n' "$_caps" \
  "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"

# ── Execution ───────────────────────────────────────────────────────────────────
n_pass=0; n_fail=0; n_skip=0; n_sel=0
failed_names=""; skipped_names=""; skipped_tags=""
# sweep() (the EXIT trap) reads the GLOBAL $IT_IMAGE — exported once, above,
# with the default/CLI value — to decide what to `docker rmi` / name in its
# "kept: image" message. An earlier version of this loop reassigned that same
# global per variant and restored it after the loop; that missed the loop's
# OTHER exit (the unknown-variant `exit 1` a few lines down), which left
# whatever the previous iteration had set behind for sweep() to misreport.
# Save/restore has as many failure points as the loop has exits, and a loop
# gains exits over time. Not mutating the global at all closes the whole
# class structurally: each case gets ITS variant's image via a per-invocation
# prefix assignment on the `it_timeout` call below (verified to reach the
# child through all three it_timeout implementations — GNU timeout, gtimeout,
# and the pure-bash background-job fallback — and through the --verbose
# pipeline, none of which is otherwise obvious from reading the call site).
# $IT_IMAGE itself never changes for the life of the script, so sweep() is
# correct no matter which of the loop's exits fires.
for v in $(selected_variants $selected); do
  IT_VARIANT_OVERRIDES="$(variant_overrides "$v")" || {
    printf 'ERROR: case declares unknown image variant: %s\n' "$v" >&2
    exit 1
  }
  export IT_VARIANT_OVERRIDES
  variant_img="$(variant_image "$v")"

  if [[ "$reuse_image" -eq 0 ]]; then
    build_image "$v" || {
      # A variant that will not build fails ITS cases by name rather than
      # aborting the run: the other variants' cases are unaffected and their
      # result is worth having. Reporting them as passed, or not reporting them
      # at all, is the failure this suite exists to prevent.
      for f in $selected; do
        [[ "$(case_variant "$f")" == "$v" ]] || continue
        printf '%-46s  FAIL  (image variant %s failed to build)\n' "$(basename "$f" .sh)" "$v"
        n_sel=$((n_sel + 1)); n_fail=$((n_fail + 1))
        failed_names="${failed_names:+$failed_names }$(basename "$f" .sh)"
      done
      continue
    }
  fi

  for f in $selected; do
  [[ "$(case_variant "$f")" == "$v" ]] || continue
  name="$(basename "$f" .sh)"
  n_sel=$((n_sel + 1))
  tags="$(case_meta "$f" tags)"
  reqs="$(case_meta "$f" requires)"
  log="$IT_SCRATCH/logs/$name.log"

  if missing="$(unmet_requirement "$reqs")"; then
    printf '%-46s  SKIP  (requires: %s)\n' "$name" "$missing"
    n_skip=$((n_skip + 1))
    skipped_names="${skipped_names:+$skipped_names }$name"
    skipped_tags="${skipped_tags}|${name}:${tags}"
    continue
  fi

  case_failed=0
  started=$SECONDS
  # IT_IMAGE="$variant_img" here is a per-command prefix assignment, not an
  # `export`: it reaches this case's own process (and lib.sh's `set -u`
  # IT_IMAGE check) through the environment bash builds for THIS command only,
  # then reverts — the parent shell's own $IT_IMAGE is never touched. See the
  # comment above the loop for why that matters.
  if [[ "$verbose" -eq 1 ]]; then
    IT_IMAGE="$variant_img" it_timeout "$timeout_secs" bash "$f" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  else
    IT_IMAGE="$variant_img" it_timeout "$timeout_secs" bash "$f" > "$log" 2>&1; rc=$?
  fi
  took=$((SECONDS - started))
  # grep -c prints "0" AND exits 1 on no match; under `set -o pipefail` (not in
  # play here, but the `|| echo 0` fallback some drafts use) that "0 || echo 0"
  # shape yields the two-line string "0\n0", not the integer 0. Force a single
  # scalar by pulling the last line, which is "0" whichever path produced it.
  # Deliberately narrower than tests/run-all.sh's '^(PASS|  ok)': that pattern
  # also accepts the '  ok' form some older hermetic tests emit, but no
  # integration case uses it — lib.sh's pass() prints exactly 'PASS: <msg>' and
  # is the only way a case can assert. Accepting a form nothing produces would
  # let a case that printed '  ok' by accident count as having asserted.
  n_ok="$(grep -c '^PASS:' "$log" 2>/dev/null | tail -1)"
  n_ok="${n_ok:-0}"

  if [[ "$rc" -eq 77 ]]; then
    printf '%-46s  SKIP  (%s)\n' "$name" \
      "$(grep -m1 '^SKIP:' "$log" | sed 's/^SKIP:[[:space:]]*//')"
    n_skip=$((n_skip + 1))
    skipped_names="${skipped_names:+$skipped_names }$name"
    skipped_tags="${skipped_tags}|${name}:${tags}"
  elif [[ "$rc" -eq 124 ]]; then
    printf '%-46s  FAIL  (timed out after %ss)\n' "$name" "$timeout_secs"
    case_failed=1
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$rc" -ne 0 ]]; then
    printf '%-46s  FAIL  (exit %s, %ss)\n' "$name" "$rc" "$took"
    case_failed=1
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$n_ok" -eq 0 ]]; then
    # Exiting 0 without asserting anything is not a pass: it is a case that
    # silently did nothing (bad guard, early return, renamed helper).
    printf '%-46s  FAIL  (exited 0 but asserted nothing)\n' "$name"
    case_failed=1
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  else
    printf '%-46s  PASS  (%s assertion(s), %ss)\n' "$name" "$n_ok" "$took"
    n_pass=$((n_pass + 1))
  fi

  # `rc -ne 0` is not the whole set of failures: a case that exits 0 having
  # printed no PASS: line is ALSO reported FAIL above ("asserted nothing"), and
  # it is the hardest failure to diagnose — nothing in the summary says why the
  # case did nothing (a bad guard, an early return, a renamed helper). Excluding
  # it from the dump left the least informative failure with the least
  # information. Gate on the FAIL having been counted, not on the exit code.
  if [[ "$case_failed" -eq 1 && "$verbose" -eq 0 ]]; then
    # A failing case's log holds its own PASS:/FAIL: assertion lines FIRST,
    # then lib.sh's EXIT trap appends it_diagnose's diagnostics (docker
    # logs, iptables -S, ipset counts, capture-dir listings) — which by
    # itself easily runs past 40 lines. A plain `tail -40` therefore showed
    # only the tail of the DIAGNOSTICS and silently discarded the assertion
    # that explains WHY the case failed, leaving a human with iptables rules
    # and no statement of the failure. Print the assertions unconditionally
    # and first — they must never be the thing that gets truncated — then a
    # bounded diagnostics tail for context.
    grep -E '^(PASS|FAIL|SKIP):' "$log" | sed 's/^/     /'
    printf '     ── diagnostics (last 40 lines of case output) ──\n'
    sed 's/^/     /' "$log" | tail -40
  fi
  done

  # Reclaim the disk before the next variant. Never the default variant: --keep
  # and the existing sweep() own that one — sweep() targets $IT_IMAGE, which
  # (per the comment above the loop) is always still the default here, so
  # this variant-scoped rmi and sweep()'s own never collide or double up.
  if [[ "$v" != "default" && "$reuse_image" -eq 0 && "$keep" -eq 0 ]]; then
    docker rmi "$variant_img" >/dev/null 2>&1 || true
  fi
done

# ── Report ──────────────────────────────────────────────────────────────────────
# A run that selected NOTHING is not a pass. Without this, an empty cases/ dir, a
# mistyped --tags, a bad IT_CASES_DIR, or a list_intersects regression all print
# "selected 0 of 0   passed 0  failed 0  skipped 0" and exit 0 — a green build
# that means "we did not look", which is the precise failure this whole suite
# exists to make impossible. It would be absurd for the runner to be the thing
# that reintroduces it one layer up.
#
# Deliberately fatal rather than a warning: asking for a tag that matches no case
# is a mistake worth stopping for, and "run nothing successfully" is not a useful
# outcome for any caller.
if [[ "$n_sel" -eq 0 ]]; then
  printf '\n%s\n' "────────────────────────────────────────────────────────────"
  printf 'selected 0 of %s   NOTHING RAN\n' "$total" >&2
  printf 'ERROR: no case was selected. A run that checked nothing is not a pass.\n' >&2
  if [[ -n "$want_tags$excl_tags" ]]; then
    printf '       selection was --tags "%s" --exclude "%s" — check for a typo\n' \
      "$want_tags" "$excl_tags" >&2
  fi
  if [[ "$total" -eq 0 ]]; then
    printf '       no case files found in %s\n' "$CASES_DIR" >&2
  fi
  exit 1
fi

printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf 'selected %s of %s   passed %s  failed %s  skipped %s\n' \
  "$n_sel" "$total" "$n_pass" "$n_fail" "$n_skip"
[[ -n "$failed_names"  ]] && printf 'failing: %s\n' "$failed_names"
[[ -n "$skipped_names" ]] && printf 'skipped: %s\n' "$skipped_names"

# ── --require: a skip inside the selected set is a failure ─────────────────────
req_violation=0
for t in $req_tags; do
  hit=""
  # skipped_tags entries look like |<name>:<tag> <tag>…
  #
  # `|| [[ -n "$entry" ]]` is LOAD-BEARING, not defensive noise. printf writes no
  # trailing newline, so the final entry reaches `read` unterminated: read returns
  # non-zero and a plain `while IFS= read -r entry` DISCARDS it. With two or more
  # skips that merely lost the last one; with exactly ONE skip — the common CI
  # case — it lost the only one, so --require saw nothing and the run exited 0
  # while a required case had silently not run. That is precisely the failure this
  # entire suite exists to prevent, inside the mechanism built to prevent it.
  # Found by making the runner's own --require test discriminating: the previous
  # version asserted rc != 0 on a corpus where other cases failed anyway, so it
  # passed against a --require that did nothing.
  printf '%s' "$skipped_tags" | tr '|' '\n' | while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    ename="${entry%%:*}"; etags="${entry#*:}"
    list_intersects "$etags" "$t" && printf '%s\n' "$ename"
  done > "$IT_SCRATCH/req-hits.$t"
  hit="$(tr '\n' ' ' < "$IT_SCRATCH/req-hits.$t")"
  if [[ -n "${hit// /}" ]]; then
    printf 'ERROR: required tag "%s" — these selected cases SKIPPED: %s\n' "$t" "$hit" >&2
    printf '       A case that cannot run is not a pass. Fix the environment or\n' >&2
    printf '       exclude the tag deliberately with --exclude.\n' >&2
    req_violation=1
  fi
done

[[ "$n_fail" -gt 0 || "$req_violation" -eq 1 ]] && exit 1
exit 0
