#!/usr/bin/env bash
# Every host entry point must reach the bash floor guard. The list is DERIVED
# from the repo, not hand-written: a hand-written list can only ever validate
# the files someone remembered to add to it, which is how the mgd port shipped
# with two files missing from its own byte-identity gate.
#
# Layout-tolerant: the engine directory (bash-floor.sh, sandbox-common.sh, and
# the entry-point scripts) is "the directory containing build.sh and
# sandbox.conf" — the repo root here, but base/ in the mgd-ai-containers port,
# where tests/ sits one level up beside it instead. Resolve it the same way
# verify-on-host.sh does, rather than assuming tests/.. is the engine dir.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
if [[ ! -f "$ENGINE_DIR/build.sh" || ! -f "$ENGINE_DIR/sandbox.conf" ]]; then
  ENGINE_DIR="$(cd "$TESTS_DIR/../base" && pwd)"
fi

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$ENGINE_DIR/build.sh" && -f "$ENGINE_DIR/sandbox.conf" ]] \
  && pass "engine directory resolved ($ENGINE_DIR)" \
  || fail "engine directory resolved — could not find build.sh + sandbox.conf under repo root or base/"

[[ -f "$ENGINE_DIR/bash-floor.sh" ]] \
  && pass "bash-floor.sh exists" || fail "bash-floor.sh exists"

# The floor is stated exactly once. A second literal somewhere else is how the
# 4.3-vs-4.4-vs-3.2 contradiction happened in the first place.
#
# TRACKED FILES ONLY, via git ls-files — the same idiom the entry-point list
# below already uses, and for a reason measured on 2026-08-21: this check used
# `grep -r` over the engine directory, which walks the filesystem and therefore
# counted `.ai-containers/bash-floor.sh`. That path is a git-IGNORED copy of the
# whole upstream repo, written into every project by sync-to-projects.sh —
# including into this checkout. Running the sync turned the suite red with "the
# floor is defined in 2 files", naming a second definition that is not a second
# definition at all but a copy of the first. A guard that fails on a file the
# project deliberately ignores does not protect the invariant; it just goes off.
#
# ONE derivation, guarded ONCE, because both checks in this file depend on it and
# it has been observed producing NOTHING. During a full parallel `run-all.sh` on
# 2026-08-21 this file failed with BOTH "the floor is defined in 0 files" and
# "checked 0 entry points" — `git ls-files` had returned empty, and the same
# command run a second later listed the file correctly. Zero tracked *.sh is
# impossible in a healthy checkout, so reporting it as a failed ASSERTION states
# something false about the code. It is a failed scaffold step, and
# SCAFFOLD-FAILED: is the channel for that (backlog F31/F32): run-all.sh reports
# it as "could not set itself up" and falsify scores such a mutant UNPROVEN
# rather than KILLED. The entry-point check below has depended on this same
# derivation since long before the floor count did.
tracked_sh="$(cd "$ENGINE_DIR" && git ls-files '*.sh' 2>/dev/null)" || tracked_sh=""
if [[ -z "$tracked_sh" ]]; then
  printf 'SCAFFOLD-FAILED: git ls-files listed no *.sh under %s — the derivation both checks here depend on produced nothing\n' "$ENGINE_DIR"
  exit 1
fi

floor_defs=0
while IFS= read -r _f; do
  [[ -n "$_f" ]] || continue
  case "$_f" in tests/*|*/tests/*) continue ;; esac
  grep -qE 'AI_CONTAINERS_BASH_FLOOR_(MAJOR|MINOR)=' "$ENGINE_DIR/$_f" 2>/dev/null \
    && floor_defs=$(( floor_defs + 1 ))
done <<< "$tracked_sh"
[[ "$floor_defs" == "1" ]] \
  && pass "the floor is defined in exactly one file" \
  || fail "the floor is defined in $floor_defs files — it must be exactly one"

# Derived entry-point list: executable *.sh at the engine directory's top level
# (not nested) that are RUN, not sourced. In-container scripts are excluded by
# name because they never execute on a host at all.
in_container="entrypoint.sh rvm-reconcile.sh agent-tools-reconcile.sh
  link-agent-tools.sh link-default-ruby.sh install-tools.sh
  refresh-ipset-allowlist.sh capture-blocked-traffic.sh
  install-agent-skills.sh capture-agent-destinations.sh bash-floor.sh
  sandbox-common.sh tools-lib.sh shared-files.sh"
# The multi-line string above embeds literal newlines; normalize them to spaces
# before substring-matching, otherwise an entry at the end of a physical line
# (immediately before its embedded \n, not a space) never matches " $base ".
in_container_flat=" ${in_container//$'\n'/ } "
n_checked=0
while IFS= read -r f; do
  base="$(basename "$f")"
  case "$in_container_flat" in *" $base "*) continue ;; esac
  n_checked=$((n_checked+1))
  if grep -qE '^(source|\.) .*(bash-floor|sandbox-common)\.sh' "$ENGINE_DIR/$base"; then
    pass "$base reaches the bash floor guard"
  else
    fail "$base reaches the bash floor guard — it can run under an unsupported bash"
  fi
done < <(printf '%s\n' "$tracked_sh" | grep -v '/')

# A derivation that found nothing must not report success.
[[ "$n_checked" -gt 0 ]] \
  && pass "checked $n_checked entry point(s)" \
  || fail "checked 0 entry points — the derivation matched nothing"

# ── The floor→image map ───────────────────────────────────────────────────────
# The image that TESTS the floor is part of declaring the floor. Kept as a map
# rather than a free variable so a floor bumped without a matching image yields
# empty (a hard failure downstream) instead of silently testing the wrong bash.
( source "$ENGINE_DIR/bash-floor.sh"
  [[ -n "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}" ]] ) \
  && pass "bash-floor.sh maps the declared floor to a container image" \
  || fail "bash-floor.sh maps no image to the declared floor — suite-floor cannot test the claim"

# Bumping the floor without extending the map must yield EMPTY, not a stale
# image. Tested against a COPY with rewritten floor numbers, NOT an env
# override: bash-floor.sh is the single declaration of the floor and six entry
# points source it as a guard, so making its assignments env-overridable to suit
# this test would let any stray AI_CONTAINERS_BASH_FLOOR_MAJOR silently lower
# that guard. Fix the test's assumption, never the product.
#
# 5.0 rather than a high number: sourcing the copy runs the version guard too,
# and a floor ABOVE the running bash would exit before reaching the map. 5.0 is
# below every bash this suite can run on (the real floor is 5.1) and is absent
# from the map, which is exactly the condition under test.
sed -e 's/^AI_CONTAINERS_BASH_FLOOR_MAJOR=.*/AI_CONTAINERS_BASH_FLOOR_MAJOR=5/' \
    -e 's/^AI_CONTAINERS_BASH_FLOOR_MINOR=.*/AI_CONTAINERS_BASH_FLOOR_MINOR=0/' \
    "$ENGINE_DIR/bash-floor.sh" > "$TMP/floor-unmapped.sh"
# A sed that matched nothing would leave the real floor in place and make the
# assertion below pass for the wrong reason.
grep -q '^AI_CONTAINERS_BASH_FLOOR_MINOR=0$' "$TMP/floor-unmapped.sh" \
  || fail "the unmapped-floor fixture was not rewritten — the assertion below would be vacuous"
out="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"' \
         _ "$TMP/floor-unmapped.sh")"
[[ -z "$out" ]] \
  && pass "an unmapped floor yields an empty image rather than a stale one" \
  || fail "an unmapped floor yielded '$out' — the map is not keyed on the declared floor"

# ── The comparison ITSELF refuses and accepts. ────────────────────────────────
# Everything above this point checks that the guard is WIRED IN — that it exists,
# that the floor is stated once, that every entry point sources it. None of it
# checks that the comparison WORKS, and the mutation tier proved the difference
# is not academic: flipping `BASH_VERSINFO[0] <` to `>` left the whole suite
# green while inverting the guard, so bash 3.2 would be ACCEPTED and bash 6
# REFUSED. That is the same failure this repo already records for the capture
# daemon — "the wiring was correct and the daemon died".
#
# BASH_VERSINFO is readonly, so the running bash cannot be faked. The floor is
# varied instead, against a COPY that differs from the shipped file in exactly
# the two constants: a floor above the running bash must REFUSE, one below must
# ACCEPT. Both directions are needed — the mutant inverts both, and either
# alone would still pass on one of them.
bf_with_floor() {   # $1=major $2=minor → rc of bash-floor.sh under that floor
  sed -E "s/^(AI_CONTAINERS_BASH_FLOOR_MAJOR)=.*/\1=$1/; \
          s/^(AI_CONTAINERS_BASH_FLOOR_MINOR)=.*/\1=$2/" \
      "$ENGINE_DIR/bash-floor.sh" > "$TMP/bf-probe.sh"
  # The substitution must have APPLIED, or both probes below run the shipped
  # floor and agree for the wrong reason.
  if ! grep -q "^AI_CONTAINERS_BASH_FLOOR_MAJOR=$1\$" "$TMP/bf-probe.sh"; then
    fail "bf_with_floor could not set the floor to $1.$2 — the probe is meaningless"
    return 2
  fi
  bash "$TMP/bf-probe.sh" >/dev/null 2>&1
}

bf_with_floor 99 0; rc=$?
[[ "$rc" -eq 1 ]] \
  && pass "a floor ABOVE the running bash is refused (rc=1)" \
  || fail "a floor above the running bash is refused — got rc=$rc, so the guard does not actually compare"

bf_with_floor 3 0; rc=$?
[[ "$rc" -eq 0 ]] \
  && pass "a floor BELOW the running bash is accepted (rc=0)" \
  || fail "a floor below the running bash is accepted — got rc=$rc"

# The MINOR half of the comparison, which the major-only probes above cannot
# reach: a floor with the same major and a higher minor must still refuse.
bf_with_floor "${BASH_VERSINFO[0]}" "$(( BASH_VERSINFO[1] + 1 ))"; rc=$?
[[ "$rc" -eq 1 ]] \
  && pass "same major, higher minor is refused (the minor comparison is live)" \
  || fail "same major, higher minor is refused — got rc=$rc"


# ── The re-entry guard, on the paths that sourcing alone never reaches ───────
# `return 0 2>/dev/null || exit 0` behaves differently depending on how the file
# is entered, and the ordinary path exercises only one of the two ways. SOURCED
# a second time, `return` succeeds and returns immediately, so the `|| exit 0`
# half is never evaluated at all. EXECUTED, `return` fails ("can only `return'
# from a function or sourced script", swallowed by the 2>/dev/null) and the
# `|| exit 0` is what ends the run.
#
# That asymmetry is a defect this project has already been bitten by once, in
# tests/lib-verify-repo.sh: three guards written to "fail loudly" had never
# failed, because the half that fails is the half nothing ran. Here it left
# mutants of this one line alive against the entire suite (falsify backlog
# F15). Measured, all three damages of the line:
#
#   line                        re-source rc   exec rc (sentinel)   ran on past guard
#   pristine  `... || exit 0`         0                0                    no
#   damage A  `... || exit 1`         0                1                    no
#   damage B  `... && exit 0`         0                0                   YES
#   damage C  `return 1 || exit 0`    1                0                    no
#
# Three different observations are needed because no one of them separates all
# three: C only moves the SOURCED status, A only moves the EXECUTED status, and
# B moves neither — it short-circuits, falls THROUGH the guard and re-runs the
# whole file, which on a bash at or above the floor still ends in status 0.
#
# "Ran on past the guard" is read from an xtrace of the run: the first statement
# after the guard is the sentinel assignment, so its trace line appears if and
# only if the guard failed to stop the file. The no-sentinel run below is the
# CONTROL for that detector — it must report YES. Without it a mistyped marker
# would make the fall-through assertion pass for the wrong reason, which is the
# same vacuity this whole entry is about.
#
# Every one of these runs its subject as the CONDITION of an `if` rather than as
# a bare statement. This file does not run under errexit today, but its sibling
# tests/test-shared-files-parity.sh does — it sources a product script that
# sets `-euo pipefail` — and the idiom must not depend on which. A bare
# non-zero command under errexit
# aborts the test where it stands — no FAIL line, no failure count, just exit 1
# — and the falsify tier scores that abort as KILLED, so the mutant would look
# caught while nothing had asserted anything.
GUARD_TARGET="$ENGINE_DIR/bash-floor.sh"
GUARD_SENTINEL="_AI_CONTAINERS_BASH_FLOOR_SOURCED"
guard_exec() {  # $1 = preset|plain ; sets guard_rc and guard_ran_on
  local trace
  if [[ "$1" == "preset" ]]; then
    if trace="$(env "$GUARD_SENTINEL=1" bash -x "$GUARD_TARGET" 2>&1 >/dev/null)"; then guard_rc=0; else guard_rc=$?; fi
  else
    if trace="$(bash -x "$GUARD_TARGET" 2>&1 >/dev/null)"; then guard_rc=0; else guard_rc=$?; fi
  fi
  if [[ "$trace" == *"$GUARD_SENTINEL=1"* ]]; then guard_ran_on=yes; else guard_ran_on=no; fi
}

# Sourced twice: the second source must report success. Callers source this file
# unconditionally and read the status; a re-entry that returns 1 makes a
# perfectly healthy second source look like a failed one.
if bash -c 'source "$1"; source "$1"' _ "$GUARD_TARGET" >/dev/null 2>&1; then guard_resource_rc=0; else guard_resource_rc=$?; fi
[[ "$guard_resource_rc" -eq 0 ]] \
  && pass "sourcing bash-floor.sh a second time returns 0" \
  || fail "sourcing bash-floor.sh a second time returns 0 — got $guard_resource_rc, so the re-entry guard reports a healthy re-source as a failure"

guard_exec plain
[[ "$guard_ran_on" == "yes" ]] \
  && pass "executing bash-floor.sh with no sentinel set runs the body (the fall-through detector is live)" \
  || fail "executing bash-floor.sh with no sentinel set runs the body — saw no '$GUARD_SENTINEL=1' in the xtrace, so the fall-through assertion below cannot fail and proves nothing"
[[ "$guard_rc" -eq 0 ]] \
  && pass "executing bash-floor.sh with no sentinel set exits 0" \
  || fail "executing bash-floor.sh with no sentinel set exits 0 — got $guard_rc"

guard_exec preset
[[ "$guard_rc" -eq 0 ]] \
  && pass "executing bash-floor.sh with the sentinel already set exits 0" \
  || fail "executing bash-floor.sh with the sentinel already set exits 0 — got $guard_rc; the re-entry guard's '|| exit' half reports the wrong status"
[[ "$guard_ran_on" == "no" ]] \
  && pass "executing bash-floor.sh with the sentinel already set stops AT the guard" \
  || fail "executing bash-floor.sh with the sentinel already set stops AT the guard — the xtrace shows '$GUARD_SENTINEL=1' running, so execution fell through and re-ran the whole file"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
