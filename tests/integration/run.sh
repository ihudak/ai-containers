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
# IT_DOCKER_HOST (the docker ENDPOINT) is NOT resolved here despite the
# parallel to IT_REAL_DOCKER just above — deliberately. `command -v docker`
# never executes the docker binary, so IT_REAL_DOCKER is invisible to anything
# watching docker's own invocations; `docker context inspect` genuinely runs
# it. --list/--list-caps both exit long before the execution loop that
# actually needs IT_DOCKER_HOST, and detect_caps's own hermetic tests
# (tests/test-integration-runner.sh) run this script for real against a
# call-counting stub docker and assert on the EXACT sequence of calls it
# makes — an unconditional resolution up here would show up in that log
# before detect_caps's own first call and break an assertion that has nothing
# to do with this fix. It is resolved instead right before the export list
# further down, which every real (non---list/-caps) run reaches exactly once,
# after every early-exit path has already returned. See that site for the
# full DOCKER_HOST-vs-DOCKER_CONFIG / resolution-failure reasoning.

want_tags=""; excl_tags=""; req_tags=""; want_variant=""; want_cases=""
do_list=0; do_dry_run=0; do_list_caps=0; reuse_image=0; keep=0; verbose=0
timeout_secs=300
# Declared here, not just in the "Execution" section below, so it is defined
# under `set -u` for EVERY exit path — including one that exits before the
# execution loop ever runs (e.g. build_image failing) — because sweep()'s
# EXIT trap reads it to decide whether to keep $IT_SCRATCH.
n_fail=0

# Single source of truth for valid --variant NAMES, consumed by usage() below
# and by the unknown-variant error message further down — so those two
# user-facing strings can never drift apart from each other. Assigned here,
# ahead of the option-parsing loop, because usage() can be invoked as early as
# a bare `-h`/`--help`, before variant_overrides() (which is the actual
# authority on what a valid variant IS, not just its name) has even been
# defined as a function yet. variant_overrides()'s own case arms, near its
# definition below, carry a comment pointing back here: its per-variant
# override bodies can't be derived from a flat name list without contorting
# that function, so the two are kept in sync by hand plus that pointer.
KNOWN_VARIANTS="default agents native"
# The DISPLAY form of the same list, derived rather than duplicated. The
# variable itself stays space-separated because that is its machine form — a
# `for v in $KNOWN_VARIANTS` word-split, and the `case " $KNOWN_VARIANTS " in
# *" $v "*)` membership idiom this file uses elsewhere — while every other
# user-facing list in this file (--tags, --exclude, --cases, --require) is
# comma-formatted, so a bare "(default agents native)" reads as three separate
# things rather than one list of three. Derived, so adding a variant cannot
# update one and miss the other.
KNOWN_VARIANTS_DISPLAY="${KNOWN_VARIANTS// /, }"

usage() {
  cat <<EOF
Usage: tests/integration/run.sh [options]

  --tags T[,T…]      run only cases carrying at least one of these tags
  --exclude T[,T…]   drop cases carrying any of these tags
  --variant NAME     run only cases whose image variant is NAME ($KNOWN_VARIANTS_DISPLAY)
                      — composes with --tags/--exclude, it narrows rather than
                      replaces that selection. Like --tags/--exclude, it has
                      no effect on --list, which always catalogues the whole
                      corpus regardless of any selection flag.
  --cases C[,C…]     run only these case basenames (e.g.
                      760-ruby-persists-no-recompile) — composes with
                      --tags/--exclude/--variant, narrowing further just like
                      --variant does. An unrecognised name fails loudly rather
                      than silently selecting zero cases.
  --require T[,T…]   fail the run if any SELECTED case with this tag SKIPPED
  --timeout N        per-case timeout in seconds (default 300)
  --image NAME       image tag to build/use (default ai-sandbox-it)
  --reuse-image      do not build; use the existing --image
  --keep             keep the image, network and scratch dir after the run
  --list             list cases with their tags/requires and exit
  --dry-run          print the cases the current selection WOULD run, one per
                      line, and exit — no image build, no container. Unlike
                      --list, it honours --tags/--exclude/--cases/--variant.
  --list-caps        print detected capabilities and exit
  -v, --verbose      stream each case's full output
  -h, --help         this text

Tags: network-mode mounts volumes groups packages | security | fast slow |
      needs-external needs-netadmin needs-dns needs-multiruby | harness
Requires: docker netadmin sidecar dns external launcher multiruby
EOF
}

# IT_SOURCE_ONLY (see the early return before the sweep EXIT trap, below) means
# run.sh is being sourced by tests/test-integration-runner.sh's callfn.sh
# helper, which reuses "$@" as a FUNCTION NAME plus its arguments, not CLI
# flags — `source` shares positional parameters with its caller, so parsing
# them here would read e.g. "variant_overrides" as an unrecognised option and
# `exit 2`, which kills the whole sourcing process (not just this loop) before
# the requested function is ever called.
# Same IT_SOURCE_ONLY cut is explained from the other two sides at
# tests/integration/run.sh:785 and tests/test-integration-runner.sh:35 — an edit
# to any of the three should check the other two have not drifted.
while [[ -z "${IT_SOURCE_ONLY:-}" && $# -gt 0 ]]; do
  # A value-taking option with no value must be a usage error, not a crash.
  # Without this guard `run.sh --tags` aborts with "line NN: 2: unbound variable"
  # under set -u — a message that names neither the option nor the problem, from a
  # script whose whole purpose is making failures legible.
  case "$1" in
    --tags|--exclude|--variant|--cases|--require|--timeout|--image)
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
    --variant)  want_variant="$2";     shift 2 ;;
    --cases)    want_cases="${2//,/ }"; shift 2 ;;
    --require)  req_tags="${2//,/ }";  shift 2 ;;
    --timeout)  timeout_secs="$2";     shift 2 ;;
    --image)    IT_IMAGE="$2";         shift 2 ;;
    --reuse-image) reuse_image=1; shift ;;
    --keep)     keep=1;    shift ;;
    --list)     do_list=1; shift ;;
    --dry-run)  do_dry_run=1; shift ;;
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

# This function is the actual authority on which variant names are valid —
# KNOWN_VARIANTS (top of file) is a flat name list for two user-facing
# strings (usage(), the unknown-variant error) that run before this function
# even exists yet; it can't be derived FROM this function's case arms without
# contorting them, since each arm carries a different override body, not just
# a name. If a variant is ever added/removed here, update KNOWN_VARIANTS too.
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

# Per-case override for the corpus-wide --timeout/300s default. Added for the
# packages tier: 700/710/720 budget an agent-tier install (four npm global
# installs, a uv tool install, a vale download) at up to 30 minutes, which
# the 300s default was never sized for — and nightly.yml runs with no
# --timeout flag at all, the only CI path those cases take. Raising the
# global default would weaken every fast case's protection against a hang;
# a per-case number is the only one that can be right, since a 10-second
# network case and a slow install do not share a sensible ceiling.
#
# Empty header → the run's own $timeout_secs (--timeout, or its 300s
# literal default) — NOT a second hardcoded 300 here, which would silently
# drift from the CLI flag the moment someone changed one but not the other.
# A non-numeric header returns 1 rather than falling back: a case author's
# typo must fail the run loudly, not silently revert to the exact 300s
# ceiling this key exists to let a case opt out of.
case_timeout() {  # $1=case file → seconds; rc 1 if the header exists but is not a positive integer
  local t; t="$(case_meta "$1" timeout)"
  if [[ -z "$t" ]]; then
    printf '%s' "$timeout_secs"
    return 0
  fi
  if [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -gt 0 ]]; then
    printf '%s' "$t"
    return 0
  fi
  return 1
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
_caps=""; _caps_forced=0; _caps_unknown=""
# Which image tag detect_caps's netadmin/launcher probes start a container
# FROM. Defaults to $IT_IMAGE (the default variant's tag) — the ONLY thing
# this ever pointed at before --variant existed, so --list-caps and
# --reuse-image (neither of which builds anything here) keep exactly their
# old behaviour. A real (non-reuse) run overwrites this via ensure_caps_image
# (defined below build_image), once a variant's image has actually been
# built — see that function's comment for why $IT_IMAGE alone stopped being a
# safe assumption the day a per-variant CI job stopped building it at all.
IT_CAPS_IMAGE="$IT_IMAGE"
detect_caps() {
  [[ -n "$_caps" ]] && return 0
  if [[ -n "${IT_FORCE_CAPS:-}" ]]; then
    _caps=" ${IT_FORCE_CAPS} "; _caps_forced=1; return 0
  fi
  local c="" u=""
  if docker info >/dev/null 2>&1; then
    c="$c docker"
    if docker network create --label "$IT_LABEL" "${IT_NET}-probe" >/dev/null 2>&1; then
      c="$c sidecar"
      docker network rm "${IT_NET}-probe" >/dev/null 2>&1 || true
    fi
    # Pre-existing, not a regression: this gate is keyed to whatever
    # IT_CAPS_IMAGE currently holds, which defaults to $IT_IMAGE. If every
    # selected variant fails to build (ensure_caps_image leaves IT_CAPS_IMAGE
    # at that default) AND a stale image happens to already exist under the
    # default tag from an unrelated earlier build, the probes below run
    # against an image that has nothing to do with this run.
    if [[ "$reuse_image" -eq 1 ]] || docker image inspect "$IT_CAPS_IMAGE" >/dev/null 2>&1; then
      probe_netadmin && c="$c netadmin"
      probe_launcher && c="$c launcher"
    else
      # No image exists yet to start a container FROM — e.g. --list-caps
      # before any build, or every selected variant failed to build (see
      # ensure_caps_image). netadmin/launcher are HOST properties (kernel
      # modules, the docker-shim); the image is only the vehicle the probe
      # needs to start a container with. "No vehicle available" is not the
      # same fact as "probed it and the host genuinely can't do this" —
      # collapsing the two is the exact defect class this fix exists to
      # eliminate, so record it in a visibly separate list rather than just
      # leaving both capabilities out of $c indistinguishably from absent.
      u="$u netadmin launcher"
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
  # A REAL outbound HTTPS request, deliberately — reviewed and kept as-is.
  # `external` means "this host can reach the public internet", and the six
  # packages-tier cases that require it spend up to 35 minutes each installing
  # from npm/rvm/apt through the restricted firewall. Any probe that cannot
  # fail would report the capability present on an air-gapped runner and turn
  # those into 35-minute timeouts with a misleading cause, which is strictly
  # worse than one handshake. So the cheaper options were all rejected:
  #
  #   - a shorter --max-time: 8s is a FLOOR, not fat to trim. A high-latency
  #     or captive-portal-throttled link that needs 6s would start reporting
  #     no external, and nightly's `--require packages` turns that skip into a
  #     red run blaming the wrong thing.
  #   - probing a host the suite actually depends on (registry.npmjs.org,
  #     get.rvm.io, deb.debian.org): each case needs a DIFFERENT one, so any
  #     single pick answers a narrower question than the capability claims,
  #     and when that one host is down the case fails either way — skip or
  #     fail, both red, no information gained for the extra coupling.
  #   - dropping the probe and inferring reachability from the docker pull
  #     above: that answers "can this host reach the registry", which is a
  #     different question and already has its own capability (`dns`).
  #
  # Cost is bounded and paid at most once per run: detect_caps memoises into
  # $_caps, and IT_FORCE_CAPS bypasses the whole function for a host that
  # knows its own answer (an air-gapped or proxied runner).
  #
  # Known, accepted imprecision: a host with no `curl` at all reports no
  # external (rc 127) even with a working network. It fails SAFE — a skip,
  # never a false "available" — and --require makes it loud rather than
  # silent.
  # `external` is deliberately NOT probed here — see probe_external() below.
  # Deliberately OUTSIDE the `docker info` block above, not just outside the
  # `docker image inspect` gate that wraps netadmin/launcher: this probe reads a
  # resolved variable, not a live daemon or a built image, so it must still be
  # reported on a machine with no Docker at all — the exact shape this test
  # suite runs on. Nesting it inside either gate would make `multiruby` vanish
  # wherever `docker`/`sidecar` do, and 750 would then SKIP for a reason that
  # has nothing to do with Ruby.
  probe_multiruby && c="$c multiruby"
  _caps=" $c "
  _caps_unknown=" $u "
}

# Can a container here create an ipset and install match-set + NFLOG rules?
# This is the single question the whole security tier rests on (see Task 0).
probe_netadmin() {
  docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW --label "$IT_LABEL" \
    --entrypoint bash "$IT_CAPS_IMAGE" -c '
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
# The probe issues the SAME SHAPE sandbox.sh:805 does — `docker run -it --rm`
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
    docker run -it --rm --entrypoint sleep --label "$IT_LABEL" "$IT_CAPS_IMAGE" 120
  ) >/dev/null 2>&1
  if [[ "$($IT_REAL_DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    rc=0
  fi
  "$IT_REAL_DOCKER" rm -f "$name" >/dev/null 2>&1
  rm -rf "$d"
  return "$rc"
}

# Can 750-ruby-multiversion-selection select between two Rubies? With only one
# version configured there is nothing to select — the case would either have to
# skip for an unrelated reason or "pass" against a single-element list, which
# tests nothing. Read from the resolved IT_RUBY_VERSIONS, never assumed: a probe
# that always returned 0 would be exactly the decorative check this suite exists
# to eliminate.
probe_multiruby() {
  case "$IT_RUBY_VERSIONS" in *,*) return 0 ;; *) return 1 ;; esac
}

# `external` is the one capability probed LAZILY — only when something actually
# asks for it — rather than in detect_caps' up-front batch. Every other probe
# reads local state (a resolved variable, `docker info`, a container this run
# was going to start anyway); this one makes a real outbound HTTPS request to a
# third party. Running it unconditionally meant the PR gate paid it on every
# push while explicitly selecting `--tags fast --exclude needs-external`, and no
# `fast` case requires it — a network call in a run that had already declared it
# does not need the network. A hermetic run should make no outbound request at
# all, and now does not.
#
# The probe ITSELF is unchanged and stays unchanged on purpose: `external` means
# "this host can reach the public internet", and a cheaper probe either answers
# a narrower question or risks a false negative that `--require packages` turns
# into a red nightly blaming the wrong thing. The fix is WHEN it runs, not what
# it does. IT_FORCE_CAPS still bypasses it entirely.
_ext_probed=0; _ext_rc=1
probe_external() {
  # Memoised, so a corpus of 34 cases each declaring `external` still pays for
  # exactly one request — the same at-most-once contract detect_caps gives the
  # rest, just deferred to first use instead of paid up front.
  if [[ "$_ext_probed" -eq 0 ]]; then
    _ext_probed=1
    # Known, accepted imprecision, unchanged: a host with no `curl` at all
    # reports no external (rc 127) even with a working network. It fails SAFE —
    # a skip, never a false "available" — and --require makes it loud.
    curl -fsS --max-time 8 -o /dev/null https://example.com 2>/dev/null
    _ext_rc=$?
  fi
  return "$_ext_rc"
}

have_cap() {
  detect_caps
  # IT_FORCE_CAPS is an explicit answer from a host that knows its own
  # situation (air-gapped, proxied); honour it for `external` too rather than
  # reaching for the network behind the operator's back.
  if [[ "$1" == "external" && "$_caps_forced" -eq 0 ]]; then
    probe_external && return 0 || return 1
  fi
  case "$_caps" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

unmet_requirement() {  # $1 = space-separated requires → prints the FIRST unmet one
  local r
  for r in $1; do have_cap "$r" || { printf '%s' "$r"; return 0; }; done
  return 1
}

# A run that selected NOTHING is not a pass. Without this, an empty cases/ dir, a
# mistyped --tags, a bad IT_CASES_DIR, or a list_intersects regression all print
# "selected 0 of 0   passed 0  failed 0  skipped 0" and exit 0 — a green build
# that means "we did not look", which is the precise failure this whole suite
# exists to make impossible.
#
# One function, two call sites: the real end-of-run report (whose $n_sel is,
# by construction of the execution loop below, always exactly the count of
# $selected — every case in $selected increments it exactly once, whether it
# runs, skips, or fails because its variant's image would not build) and
# --dry-run's own early exit, which checks $selected directly because it never
# reaches the execution loop that would otherwise populate $n_sel. A second,
# hand-copied version of this message at the early call site is exactly the
# kind of drift this function exists to prevent.
fatal_no_selection() {
  printf '\n%s\n' "────────────────────────────────────────────────────────────"
  printf 'selected 0 of %s   NOTHING RAN\n' "$total" >&2
  printf 'ERROR: no case was selected. A run that checked nothing is not a pass.\n' >&2
  if [[ -n "$want_tags$excl_tags" ]]; then
    printf '       selection was --tags "%s" --exclude "%s" — check for a typo\n' \
      "$want_tags" "$excl_tags" >&2
  fi
  # An unknown --variant name never reaches here — it is validated (and exits)
  # before selection runs, above. This is the LEGITIMATE empty intersection: a
  # recognised variant that just has no case matching --tags/--exclude.
  if [[ -n "$want_variant" ]]; then
    printf '       --variant "%s" narrowed it further — check the variant matches a selected case\n' \
      "$want_variant" >&2
  fi
  if [[ "$total" -eq 0 ]]; then
    printf '       no case files found in %s\n' "$CASES_DIR" >&2
  fi
  exit 1
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
  # Deliberately does NOT build anything (see ensure_caps_image's comment for
  # why probing accurately can require a build): IT_CAPS_IMAGE is still just
  # its $IT_IMAGE default here, so this reports exactly what --reuse-image
  # would find (an image built by an earlier, separate run/build) and
  # nothing more.
  detect_caps
  # --list-caps exists to answer "what can this machine do", so it asks for
  # `external` explicitly — the one question a lazy probe would otherwise leave
  # unanswered here. Reporting a capability as absent because nothing happened
  # to ask is the same collapse the "undetermined" block below exists to stop.
  have_cap external && _caps="${_caps}external "
  printf 'capabilities:%s%s\n' "$_caps" \
    "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"
  # A capability detect_caps could not PROBE (no image to start a container
  # from) is reported here, distinctly from the list above — never silently
  # folded into "absent". That collapse is the exact defect class task 13b
  # exists to eliminate: it is what made a genuinely present capability read
  # as a missing one, and made the failure confusing instead of obvious.
  if [[ -n "${_caps_unknown// /}" ]]; then
    printf 'undetermined (no image built successfully to probe with — build one first, or pass --reuse-image against an existing tag):%s\n' \
      "$_caps_unknown"
  fi
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

# ── Capability-probe image selection ────────────────────────────────────────────
# Per-variant build cache: a variant is built AT MOST ONCE per run. Without
# this, ensure_caps_image (below) building the first selected variant just to
# have something for detect_caps to probe would pay for that variant's build
# TWICE — once here, once again when the execution loop reaches it — on every
# real (non ---reuse-image) run.
built_ok_variants=""; built_failed_variants=""

ensure_variant_built() {  # $1=variant → 0 once its image exists, 1 if the build failed
  local v="$1"
  [[ "$reuse_image" -eq 1 ]] && return 0
  case " $built_ok_variants " in *" $v "*) return 0 ;; esac
  case " $built_failed_variants " in *" $v "*) return 1 ;; esac
  if build_image "$v"; then
    built_ok_variants="${built_ok_variants:+$built_ok_variants }$v"
    return 0
  fi
  built_failed_variants="${built_failed_variants:+$built_failed_variants }$v"
  return 1
}

# detect_caps's netadmin/launcher probes need a real image to start a
# container FROM. Before --variant existed that was always $IT_IMAGE, the
# default variant's tag — but a per-variant CI job (this fix's actual
# trigger: the packages tier's `agents`/`native` jobs) never builds the
# default tag at all, so the old hardcoded assumption left detect_caps with
# nothing to probe and both capabilities silently read as absent.
#
# netadmin/launcher are HOST properties (kernel modules, the docker-shim, the
# daemon itself), not properties of any one image — the image is only the
# vehicle a probe needs to start a container with. So any ONE successfully
# built selected variant is exactly as good as another for this purpose;
# there is no reason it has to be the default. Walk selected_variants in its
# first-seen order and point IT_CAPS_IMAGE at the first one that builds. A
# variant whose build genuinely fails is not retried here — it is recorded
# (ensure_variant_built's own cache) so the execution loop below reports that
# failure by name exactly once, and this function simply moves on to try the
# next selected variant instead of giving up on capability detection
# entirely because of one unrelated variant's build problem.
#
# If EVERY selected variant fails to build, IT_CAPS_IMAGE is left at its
# $IT_IMAGE default (nothing exists to probe), detect_caps's gate correctly
# reports netadmin/launcher UNDETERMINED rather than absent, and it does not
# matter operationally: every one of those variants' cases already failed at
# the build step above, so none of them ever reaches a requirement check
# that would consult netadmin/launcher's value at all.
#
# A no-op under --reuse-image, by design (a hard constraint on this fix:
# that flag's short circuit must keep working unchanged) — IT_CAPS_IMAGE
# stays at its $IT_IMAGE default, exactly what detect_caps always probed for
# a --reuse-image run before this function existed.
ensure_caps_image() {  # $@=selected case files
  [[ "$reuse_image" -eq 1 ]] && return 0
  local v
  for v in $(selected_variants "$@"); do
    if ensure_variant_built "$v"; then
      IT_CAPS_IMAGE="$(variant_image "$v")"
      return 0
    fi
  done
  return 1
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
#
# `return` halts a SOURCED script only. Executed, it fails ("can only `return'
# from a function or sourced script", rc 1) and the old one-line form
# `[[ -n … ]] && return 0 2>/dev/null` then FELL THROUGH into exactly the I/O
# it names — the sweep EXIT trap, the allowlist snapshot, a real image build —
# with no option parsing having run either, so the run would also silently
# ignore every flag it was given. Nothing executes run.sh with this variable
# set today; that is a convention, and a convention is not a guard. So: return
# for the sourcing path, and a hard, LOUD exit for the executed one.
#
# Exit 2 (a usage error), never 0: an executed run.sh that runs no case is not
# a green run — the same rule the "selected 0 … NOTHING RAN" check at the
# bottom of this file enforces, applied to the one path that could reach the
# bottom having done nothing at all.
# Same IT_SOURCE_ONLY cut is explained from the other two sides at
# tests/integration/run.sh:128 and tests/test-integration-runner.sh:35 — an edit
# to any of the three should check the other two have not drifted.
if [[ -n "${IT_SOURCE_ONLY:-}" ]]; then
  return 0 2>/dev/null
  printf 'run.sh: IT_SOURCE_ONLY is set but run.sh was EXECUTED, not sourced.\n' >&2
  printf '        That variable exists for `source run.sh` (hermetic function tests);\n' >&2
  printf '        executing with it set would run NOTHING and report success.\n' >&2
  exit 2
fi

# Everything from here through the IT_RUBY_VERSIONS export just below is real
# I/O — the sweep EXIT trap's own `docker` cleanup calls, the allowlist
# snapshot, `docker network create`, and (further down) a `docker context
# inspect` to resolve IT_DOCKER_HOST. --dry-run's whole contract is "no image
# build, no container, no docker call at all", and that includes cleanup calls
# a trap would fire on this script's own exit — so this entire block is
# skipped outright for --dry-run, which reaches its own print-and-exit inside
# the Selection section below without ever setting the trap that would
# otherwise touch docker on the way out. See the comment on the IT_SOURCE_ONLY
# guard just above, which cuts at this exact same line for the same reason.
if [[ "$do_dry_run" -eq 0 ]]; then
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

  # The docker ENDPOINT, resolved once here — the reasoning for WHY (not just
  # where) lives beside IT_REAL_DOCKER near the top of this file, which explains
  # the placement; this is the substance.
  #
  # launcher_run and launcher_script (tests/integration/lib.sh) redirect HOME to
  # a per-case scratch directory to isolate group state, but the docker CLI
  # resolves which daemon to talk to from $HOME/.docker/config.json's
  # currentContext (and $HOME/.docker/contexts/) — redirecting HOME throws that
  # away. On a host where the daemon sits at the CLI's built-in default
  # (unix:///var/run/docker.sock) this is invisible; on macOS + Colima, which
  # supplies its endpoint ONLY through the active context, every docker call
  # made from inside a HOME-redirected subshell — sandbox.sh's/group.sh's/
  # repo.sh's own, and the shim's `exec $IT_REAL_DOCKER` — fails to connect.
  # Linux CI never sees this because /var/run/docker.sock genuinely exists
  # there.
  #
  # DOCKER_HOST, not DOCKER_CONFIG. Pointing DOCKER_CONFIG at the developer's
  # real ~/.docker instead would also fix this, and would additionally carry
  # TLS material and credential-helper config for an endpoint that needs them —
  # but it reintroduces the developer's real state into a harness whose whole
  # point is per-case HOME isolation. Colima's endpoint is a plain unix socket:
  # no TLS, no stored credentials. DOCKER_HOST — one string, carrying nothing
  # sensitive — covers that, and is the narrowest fix that does. A future
  # endpoint that genuinely needs client certs or a credential helper would
  # need DOCKER_CONFIG (or an explicit cert/key triplet); nothing this suite
  # targets today does.
  #
  # An already-exported DOCKER_HOST wins outright: a caller who set it on
  # purpose (e.g. pointing at a remote daemon) knows better than a context
  # lookup — checked first, so a genuine override skips the subprocess too.
  # Resolution failure — no `docker context` subcommand, docker missing
  # entirely, or a template result of "<no value>" (Go's own empty-field
  # marker) — leaves IT_DOCKER_HOST EMPTY, never a fabricated string: the
  # export sites in lib.sh only ever set DOCKER_HOST when this is non-empty, so
  # empty means "do not touch DOCKER_HOST at all" — the honest fallback.
  # Exporting an empty DOCKER_HOST would be worse than exporting nothing at all
  # — it overrides the CLI's own built-in default just as effectively as a
  # wrong one.
  #
  # The `[[ -z "${IT_DOCKER_HOST+x}" ]]` guard (IS-SET, not IS-NON-EMPTY — the
  # same "set-but-empty still counts as set" convention sandbox-common.sh's
  # load_env_defaults uses) exists for a caller that pre-exports IT_DOCKER_HOST
  # itself (e.g. a nested/manual invocation), so this block is idempotent
  # rather than blindly re-shelling-out. In the ordinary case it is always
  # unset on entry here, since nothing sets it earlier in this file.
  if [[ -z "${IT_DOCKER_HOST+x}" ]]; then
    if [[ -n "${DOCKER_HOST:-}" ]]; then
      IT_DOCKER_HOST="$DOCKER_HOST"
    else
      IT_DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
      case "$IT_DOCKER_HOST" in *'<no value>'*) IT_DOCKER_HOST="" ;; esac
    fi
  fi

  # IT_RUBY_VERSIONS: resolved above (with everything else in this block) purely
  # for run.sh's OWN use — variant_overrides()/probe_multiruby() read it while
  # still inside this process. Without exporting it here too, it never reaches a
  # case's process at all: `bash "$f"` (the execution loop, below) starts a CHILD
  # bash, which inherits only the environment, not this script's plain variable
  # assignments. The packages-tier Ruby cases (740/750) read $IT_RUBY_VERSIONS
  # directly under `set -u`, so a case that lost this value would not silently
  # assert nothing against an empty list — it would abort immediately with bash's
  # own "unbound variable" error, reported by run.sh as a bare nonzero exit with
  # no case-specific diagnosis. Found and fixed while writing those cases
  # (task 9), never exercised until then because no earlier case read the var.
  export IT_RUN_ID IT_LABEL IT_SCRATCH IT_IMAGE IT_NET IT_DNS_IMAGE \
         IT_CONNECT_TIMEOUT IT_SETTLE IT_GENERATED_ALLOWLIST_DIR IT_REAL_DOCKER \
         IT_DOCKER_HOST IT_RUBY_VERSIONS
fi  # do_dry_run -eq 0

# --variant is validated HERE, once, rather than left to fall through to the
# "selected 0" fatal check below: a bad name would otherwise just match zero
# cases in the loop right below and get the SAME message a mistyped --tags
# gets ("no case was selected... check for a typo"), which is true but not
# specific — it never says the NAME itself is unrecognised. variant_overrides()
# is the single source of truth for valid names (build_image() trusts the
# exact same call), so this can never drift from what the execution loop
# itself would accept.
if [[ -n "$want_variant" ]]; then
  variant_overrides "$want_variant" >/dev/null || {
    printf 'run.sh: unknown variant: %s (known: %s)\n' "$want_variant" "$KNOWN_VARIANTS_DISPLAY" >&2
    exit 2
  }
fi

# --cases is validated HERE, the same way --variant is just above: a mistyped
# name would otherwise just intersect to zero cases in the loop below and hit
# the generic "no case was selected" message further down, which is true but
# does not say WHICH name was the problem — same reasoning as --variant's
# dedicated check, applied per-name since --cases can name several at once.
if [[ -n "$want_cases" ]]; then
  known_case_names=""
  for f in $(all_cases); do
    known_case_names="${known_case_names:+$known_case_names }$(basename "$f" .sh)"
  done
  unknown_cases=""
  for c in $want_cases; do
    case " $known_case_names " in
      *" $c "*) ;;
      *) unknown_cases="${unknown_cases:+$unknown_cases }$c" ;;
    esac
  done
  if [[ -n "$unknown_cases" ]]; then
    printf 'run.sh: unknown case name(s): %s\n' "$unknown_cases" >&2
    exit 2
  fi
fi

# ── Selection ───────────────────────────────────────────────────────────────────
# --cases is applied BEFORE --variant here (the reverse of the two flags'
# narrative order in the comments below), so $selected_pre_variant can capture
# "everything --tags/--exclude/--cases agreed on" at the exact point before the
# variant cut is made. That set is what the task-11c diagnostic immediately
# below this loop (well before the fatal zero-selection guard near the bottom
# of the file) uses to tell "you named real cases, but they all belong to a
# different --variant" (a deliberate no-op — a sibling job covers them) apart
# from an actual typo or a --tags/--exclude mismatch (still fatal).
# The final $selected membership is identical either way; only the bookkeeping
# moved.
total=0; selected=""; selected_pre_variant=""
for f in $(all_cases); do
  total=$((total + 1))
  tags="$(case_meta "$f" tags)"
  [[ -n "$want_tags" ]] && { list_intersects "$tags" "$want_tags" || continue; }
  [[ -n "$excl_tags" ]] && { list_intersects "$tags" "$excl_tags" && continue; }
  # Narrows to an explicit set of case basenames, exactly the "run just this
  # one mutated case plus its controls" shape a mutation demonstration needs.
  [[ -n "$want_cases" ]] && { list_intersects "$(basename "$f" .sh)" "$want_cases" || continue; }
  selected_pre_variant="${selected_pre_variant:+$selected_pre_variant }$f"
  # Composes with --tags/--exclude/--cases above rather than replacing them:
  # narrows whatever they already selected down to one image variant.
  [[ -n "$want_variant" ]] && { [[ "$(case_variant "$f")" == "$want_variant" ]] || continue; }
  selected="${selected:+$selected }$f"
done

# ── Legitimate empty selection: known --cases naming a sibling job's variant ───
# Task 11c: nightly.yml's packages-agents/packages-native jobs both thread the
# SAME workflow_dispatch `cases` input into `--tags packages --variant <name>
# ${cases:+--cases <cases>}`. A dispatch plan built around one variant's case
# names (e.g. `--cases 700-agent-tools-install-restricted`, an agents-tier
# case) therefore also reaches the OTHER job as
# `--variant native --cases 700-agent-tools-install-restricted`. That name is
# real — it already survived the unknown-name check earlier in this file — it
# simply belongs to the sibling job's variant, not this one's. Treating that
# the same as a typo (falling through to the FATAL guard near the bottom of
# this file)
# would fail a job for doing exactly what it was asked: nothing, because its
# sibling covers these cases.
#
# $selected_pre_variant is the selection loop just above with every filter but
# --variant already applied. If it is non-empty while $selected (--variant
# applied) is empty, --tags/--exclude/--cases were all satisfied and the ONLY
# remaining cause is the variant cut itself — provable from data already
# computed here, not inferred from the flags. Exit 0 (not the FATAL 1 below)
# with a message naming the variant(s) the requested cases actually belong to,
# so a reader of a green log can tell "this job deliberately did nothing"
# apart from "this job silently checked nothing" — the exact ambiguity the
# FATAL guard exists to prevent for every OTHER cause of an empty selection.
# A --cases name that fails --tags/--exclude for a reason OTHER than variant
# leaves $selected_pre_variant empty too, so it still falls through to FATAL,
# unchanged.
#
# -n "$want_cases" is NOT redundant with -n "$selected_pre_variant": without
# --cases, $selected_pre_variant is just "every case that passed
# --tags/--exclude" (the ordinary --variant-only selection pool), which is
# routinely non-empty even when THIS variant's cut of it is empty — e.g.
# `--tags fast --variant native` when no fast-tagged case is native. That is
# the plain "this variant has none of the tag-selected cases" outcome the
# FATAL guard has always correctly caught; it has nothing to do with --cases
# naming a real case in a sibling variant, and must keep failing exactly as
# before.
if [[ -z "$selected" && -n "$want_cases" && -n "$want_variant" && -n "$selected_pre_variant" ]]; then
  owning_variants=""
  for f in $selected_pre_variant; do
    v="$(case_variant "$f")"
    case " $owning_variants " in
      *" $v "*) ;;
      *) owning_variants="${owning_variants:+$owning_variants }$v" ;;
    esac
  done
  printf 'run.sh: --cases "%s" named known case(s) belonging to variant "%s" -- not this job'"'"'s --variant "%s".\n' \
    "$want_cases" "$owning_variants" "$want_variant" >&2
  printf '        Nothing to run here; a sibling job with --variant "%s" covers them. Exiting 0 (deliberate no-op, not an error).\n' \
    "$owning_variants" >&2
  exit 0
fi

# Validated for the WHOLE selected set up front, before any image build or
# capability probe: a malformed `timeout:` header is an authoring bug, and
# letting it surface only once that case's own it_timeout call is reached
# would mean discovering it after paying for a multi-GB build — the same
# fail-fast reasoning variant_overrides applies to an unrecognised `image:`
# header just below. Loud and fatal, not a silent revert to 300s.
for f in $selected; do
  case_timeout "$f" >/dev/null || {
    printf 'ERROR: %s declares a non-numeric timeout: header value "%s"\n' \
      "$(basename "$f" .sh)" "$(case_meta "$f" timeout)" >&2
    exit 2
  }
done

# ── --dry-run ────────────────────────────────────────────────────────────────────
# $selected is final here: every filter above (--tags/--exclude/--cases,
# --variant, the sibling-job legitimate-no-op exit, the per-case timeout-header
# validation) has already run. Nothing below this point is selection — it is
# the first byte of real execution (image build, capability probe, containers)
# — so this is the last point at which printing the selection and exiting is
# still honest, and the earliest point at which $selected can be trusted.
#
# Placed here, not merely "after `--list`" as a first instinct might suggest:
# `--list` (above) exits long before the docker/trap setup this file performs
# unconditionally on the way to Selection (see the `do_dry_run -eq 0` guard
# around that setup, above) — a print-and-exit dropped in after that setup
# would still have fired `trap 'sweep' EXIT`, `docker network create`, and a
# `docker context inspect`, i.e. it would already have touched docker before
# ever reaching here. That guard is what makes the "no docker call at all"
# claim below true, not this exit by itself.
if [[ "$do_dry_run" -eq 1 ]]; then
  [[ -z "$selected" ]] && fatal_no_selection
  # basename … .sh, matching --list and --cases: every other place in this
  # file names a case without its extension, and Task 6's containment check
  # compares --dry-run's output across layers as a set of names — a stray
  # ".sh" here would silently make every one of those comparisons a mismatch.
  for f in $selected; do basename "$f" .sh; done
  exit 0
fi

# Build at least one usable image BEFORE detecting capabilities: netadmin and
# launcher both need to start a real container to probe the host, and a run
# that only ever builds a --variant image (every packages-tier CI job) left
# nothing for detect_caps to probe if it still hardcoded $IT_IMAGE, the
# DEFAULT variant's tag (see ensure_caps_image's own comment for the full
# story). Capabilities are a HOST property, so detecting ONCE — against
# whichever selected variant's image builds first — is correct for every
# variant's cases in the loop below, not just that first one's.
ensure_caps_image $selected
detect_caps
printf 'capabilities:%s%s\n' "$_caps" \
  "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"
if [[ -n "${_caps_unknown// /}" ]]; then
  printf 'undetermined (no image built successfully to probe with — build one first, or pass --reuse-image against an existing tag):%s\n' "$_caps_unknown"
fi
printf '\n'

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

  # ensure_variant_built, not a bare build_image call: ensure_caps_image
  # (above the capabilities banner) may already have built THIS variant — the
  # first selected one — purely to have something for detect_caps to probe
  # with. The shared cache makes that case a no-op here rather than a second,
  # redundant build; every other variant still gets its normal first (and
  # only) build right here, and --reuse-image still skips building entirely.
  ensure_variant_built "$v" || {
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

  for f in $selected; do
    [[ "$(case_variant "$f")" == "$v" ]] || continue
    name="$(basename "$f" .sh)"
    n_sel=$((n_sel + 1))
    tags="$(case_meta "$f" tags)"
    reqs="$(case_meta "$f" requires)"
    log="$IT_SCRATCH/logs/$name.log"
    # Already validated in the Selection section above (every selected case's
    # header was checked before the first image build), so this cannot fail
    # here — just resolves the same value again for THIS case's own it_timeout
    # call and its "timed out after Ns" report below.
    case_to="$(case_timeout "$f")"

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
      IT_IMAGE="$variant_img" it_timeout "$case_to" bash "$f" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    else
      IT_IMAGE="$variant_img" it_timeout "$case_to" bash "$f" > "$log" 2>&1; rc=$?
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
    # Same narrowness reasoning as n_ok above: lib.sh's fail() prints exactly
    # 'FAIL: <msg>', so this is the one form a case can genuinely fail through.
    n_fail_lines="$(grep -c '^FAIL:' "$log" 2>/dev/null | tail -1)"
    n_fail_lines="${n_fail_lines:-0}"

    if [[ "$rc" -eq 77 ]]; then
      printf '%-46s  SKIP  (%s)\n' "$name" \
        "$(grep -m1 '^SKIP:' "$log" | sed 's/^SKIP:[[:space:]]*//')"
      n_skip=$((n_skip + 1))
      skipped_names="${skipped_names:+$skipped_names }$name"
      skipped_tags="${skipped_tags}|${name}:${tags}"
    elif [[ "$rc" -eq 124 ]]; then
      printf '%-46s  FAIL  (timed out after %ss)\n' "$name" "$case_to"
      case_failed=1
      n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
    elif [[ "$rc" -ne 0 ]]; then
      printf '%-46s  FAIL  (exit %s, %ss)\n' "$name" "$rc" "$took"
      case_failed=1
      n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
    elif [[ "$n_fail_lines" -gt 0 ]]; then
      # rc==0 here (the branches above already claimed every nonzero exit), yet
      # the log holds real FAIL: lines. The normal exit path is lib.sh's
      # it_finish, which `exit`s "$it_fails" — so rc==0 with a FAIL: present
      # means the case never reached it_finish (an early return, a forgotten
      # call at the end of a hand-rolled case) and whatever ran last happened to
      # exit 0, silently swallowing the failure. Gate on the printed evidence,
      # not the exit code the case forgot to set.
      printf '%-46s  FAIL  (exited 0 but printed %s FAIL: line(s) — case never reached it_finish)\n' \
        "$name" "$n_fail_lines"
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
      # The SAME truncation defect applies one layer down, to it_diagnose's own
      # dump: it prints "── docker logs (last 60) ──" FIRST, then iptables -S,
      # ipset counts and capture-dir listings AFTER it (lib.sh's it_diagnose,
      # unchanged here — reordering it would ripple to every other caller that
      # reads its output directly, e.g. a case's own `it_diagnose "$IT_CID"`
      # mid-script). Those later sections routinely push the combined log past
      # 40 lines on their own, so the plain `tail -40` below reliably showed
      # ONLY iptables/ipset/`ls` output and discarded the container logs
      # entirely — the actual record of what the entrypoint/reconcile/agent did,
      # and the single most useful thing here (task-14a: a real failure's
      # diagnostics were 100% iptables/ipset/capture-dir noise, zero lines of
      # what the container had actually printed). Extract and print that section
      # unconditionally and first, the same way the assertions above already
      # are, rather than hoping a fixed-size tail happens to land on it.
      #
      # Bounded by construction, not just by luck: it_diagnose itself caps this
      # section at 60 lines (`docker logs | tail -60`), so pulling it out whole
      # cannot turn into the unbounded dump the plain tail below is deliberately
      # sized against. Captured to a variable rather than piped straight to
      # sed/printf so an empty result (no it_diagnose ran — e.g. a case failed
      # before IT_CID was ever set) prints nothing at all instead of a
      # container-logs header over an empty section.
      container_logs="$(awk '
        /── docker logs \(last 60\) ──/ { f=1; next }
        /── iptables -S OUTPUT ──/      { f=0 }
        f
      ' "$log")"
      if [[ -n "$container_logs" ]]; then
        printf '     ── container logs (from it_diagnose, unbounded by the tail below) ──\n'
        printf '%s\n' "$container_logs" | sed 's/^/     /'
      fi
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
# A run that selected NOTHING is not a pass — see fatal_no_selection (defined
# above, beside unmet_requirement) for why, and for the --dry-run call site
# that shares this exact check rather than a second copy of it. $n_sel is, by
# construction of the execution loop above, always exactly the count of
# $selected (every case in it increments n_sel once, whether it ran, skipped,
# or failed because its variant's image would not build), so this is the same
# condition --dry-run checks directly on $selected, just observed the other
# way — through what actually got attempted instead of the pre-execution list.
[[ "$n_sel" -eq 0 ]] && fatal_no_selection

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
