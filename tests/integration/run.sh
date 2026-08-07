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
Requires: docker netadmin sidecar dns external
EOF
}

while [[ $# -gt 0 ]]; do
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

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── Case metadata ───────────────────────────────────────────────────────────────
case_meta() {  # $1=file $2=key → the header value, or empty
  sed -n "s/^#[[:space:]]*$2:[[:space:]]*//p" "$1" | head -1
}

list_intersects() {  # $1, $2 = space-separated lists → 0 if they share a member
  local a b
  for a in $1; do for b in $2; do [[ "$a" == "$b" ]] && return 0; done; done
  return 1
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
    fi
    # "Can this machine run a DNS-backed case?" — not "is the image already
    # cached". `docker image inspect` alone answers the second, and on a fresh CI
    # runner the answer is always no, so the needs-dns cases would SKIP forever
    # while looking like a deliberate capability gap. Try the cache first (fast,
    # offline-safe), then a bounded pull. A machine with no registry access still
    # correctly reports no dns capability rather than hanging.
    if docker image inspect "$IT_DNS_IMAGE" >/dev/null 2>&1 \
       || timeout 120 docker pull "$IT_DNS_IMAGE" >/dev/null 2>&1; then
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

build_image() {
  local conf="$IT_SCRATCH/minimal-sandbox.conf"
  # Everything optional OFF: the firewall does not know which fragment a domain
  # came from, so proving admit/drop once proves it for every fragment. Version
  # lists are emptied; boolean keys are turned OFF.
  sed -E 's/^([a-z0-9-]+)=ON$/\1=OFF/; s/^(node|python|ruby|rust|go|openjdk|graalvm-ce|graalvm-oracle|kotlin|scala|maven|gradle|db-clients|angular-cli)=.*/\1=/' \
    "$REPO_DIR/sandbox.conf" > "$conf"
  say "── building $IT_IMAGE from a minimal sandbox.conf…"
  ( cd "$REPO_DIR" && SANDBOX_CONF="$conf" IMAGE_NAME="$IT_IMAGE" ./build.sh "$IT_IMAGE" ) \
    > "$IT_SCRATCH/build.log" 2>&1 || {
      warn "run.sh: image build FAILED — last 40 lines of $IT_SCRATCH/build.log:"
      tail -40 "$IT_SCRATCH/build.log" >&2
      return 1
    }
  # Snapshot what build.sh generated, for the delivery case (300).
  mkdir -p "$IT_GENERATED_ALLOWLIST_DIR"
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    cp "$REPO_DIR/$f" "$IT_GENERATED_ALLOWLIST_DIR/$f"
  done
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
trap 'sweep' EXIT

mkdir -p "$IT_SCRATCH/logs"
# Gated on reuse_image: see the comment above snapshot_real_allowlists(). Only
# take (and later restore) a snapshot when build_image() is actually about to
# regenerate the real files — this is what keeps a --reuse-image run (every
# hermetic unit-test invocation) from touching the real repo at all.
if [[ "$reuse_image" -eq 0 ]]; then
  snapshot_real_allowlists
  build_image || exit 1
fi
docker network create --label "$IT_LABEL" "$IT_NET" >/dev/null 2>&1 || true

export IT_RUN_ID IT_LABEL IT_SCRATCH IT_IMAGE IT_NET IT_DNS_IMAGE \
       IT_CONNECT_TIMEOUT IT_SETTLE IT_GENERATED_ALLOWLIST_DIR

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
for f in $selected; do
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

  started=$SECONDS
  if [[ "$verbose" -eq 1 ]]; then
    timeout "$timeout_secs" bash "$f" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  else
    timeout "$timeout_secs" bash "$f" > "$log" 2>&1; rc=$?
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
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$rc" -ne 0 ]]; then
    printf '%-46s  FAIL  (exit %s, %ss)\n' "$name" "$rc" "$took"
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$n_ok" -eq 0 ]]; then
    # Exiting 0 without asserting anything is not a pass: it is a case that
    # silently did nothing (bad guard, early return, renamed helper).
    printf '%-46s  FAIL  (exited 0 but asserted nothing)\n' "$name"
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  else
    printf '%-46s  PASS  (%s assertion(s), %ss)\n' "$name" "$n_ok" "$took"
    n_pass=$((n_pass + 1))
  fi

  if [[ "$rc" -ne 0 && "$verbose" -eq 0 ]]; then
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
  printf '%s' "$skipped_tags" | tr '|' '\n' | while IFS= read -r entry; do
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
