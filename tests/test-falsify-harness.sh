#!/usr/bin/env bash
# tests/test-falsify-harness.sh — the harness self-test: it breaks
# tests/falsify/check-ledger.sh, one predicate at a time, and requires the old
# permissive behaviour to come back.
#
# WHY THIS EXISTS SEPARATELY FROM tests/test-falsify-ledger.sh. That test feeds
# the gate a fixture that should trip a given hard failure and asserts the
# failure fires. That is necessary and it is not sufficient: it proves the
# fixture and the gate agree TODAY, not that the predicate is what produced the
# agreement. Neuter a predicate in check-ledger.sh and the fixture stops
# tripping it — whereupon the assertion for it goes QUIET rather than failing,
# because "did not fire" is indistinguishable from "there was nothing to find".
# The ledger test's author did disable each predicate by hand while writing it,
# which is exactly the right thing to have done and exactly the kind of evidence
# that evaporates the moment the session ends. This file is that work, encoded
# so it re-runs on every PR.
#
# THE SHAPE OF A DEMONSTRATION, per predicate:
#
#   1  copy check-ledger.sh (plus the generate.sh it reads its operator
#      vocabulary from) into a scratch tree — the real one is never touched;
#   2  disable that ONE predicate with a sed, and ASSERT THE SED MATCHED, and
#      that it changed exactly one line. A break that did not apply proves
#      nothing while looking identical to one that did, and this repo has been
#      bitten by precisely that (tests/test-layer-containment.sh's comment
#      records the four occasions);
#   3  assert the broken copy still parses, so a syntax error cannot be what
#      the run below is actually measuring;
#   4  feed it the fixture that trips that predicate and require `0 problem(s)`
#      — the permissive behaviour returning;
#   5  feed it the OTHER FOUR fixtures and require each to still fail, so what
#      was disabled is one predicate and not the file.
#
# The five predicates, which are the four hard failures of the ledger gate plus
# the empty-reason rule that rides on the first of them:
#
#   missing   a SURVIVOR with no entry at all                             (B)
#   noclass   an entry with no GAP:/EQUIVALENT: classification            (A)
#   empty     an entry whose marker carries an EMPTY reason               (A)
#   stale     an entry whose identity matches no mutant this run made     (C)
#   obsolete  an entry whose mutants are now all KILLED                   (D)
#
# FAST BY CONSTRUCTION: the fixtures are a handful of lines of run.sh's
# documented STDOUT contract. The 249-mutant corpus is never invoked — it costs
# minutes and mutates a scratch checkout; this runs on every PR.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FALSIFY_DIR="$REPO_DIR/tests/falsify"
CHECK="$FALSIFY_DIR/check-ledger.sh"
# shellcheck source=./portability.sh
source "$REPO_DIR/tests/portability.sh"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2', got '$3')"; fi
}
assert_has() {  # $1=label $2=needle $3=haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"
  else fail "$1 — not in output: $3"; fi
}

[[ -f "$CHECK" ]] || { fail "tests/falsify/check-ledger.sh exists"; exit 1; }
CHECK_SHA_BEFORE="$(p_sha1 "$CHECK")"

# ── the run output every fixture is measured against ──────────────────────────
# One survivor, one killed mutant, one TARGET| line putting alpha.sh in scope.
# Written here rather than produced, for the reason in the header; the contract
# it encodes is pinned against the real runner by tests/test-falsify-run.sh.
S='1111111111111111111111111111111111111111'   # survived
K='2222222222222222222222222222222222222222'   # killed
X='3333333333333333333333333333333333333333'   # no mutant carries this
ID_S="alpha.sh:logic-flip:$S"
ID_K="alpha.sh:return-flip:$K"
ID_X="alpha.sh:cmp-flip:$X"

RUN="$TMP/run.txt"
cat > "$RUN" <<EOF
RUN|repo=/fix|conf=/fix/targets.conf|jobs=1|timeout=60|operators=<default>|targets=1|mutants=2
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|$ID_S|test-alpha.sh|1|10|none|12|  a && b
MUTANT|KILLED|$ID_K|test-alpha.sh|2|11|exit+failline|13|  return 1
TARGET|alpha.sh|test-alpha.sh|2|1|1|0|30
TOTAL|1|2|1|1|0|50|40
EOF

# ── one fixture ledger per predicate, each tripping THAT ONE and no other ─────
mk_ledger() { printf '%s\n' "$2" > "$TMP/led-$1.txt"; }
mk_ledger clean "$ID_S
  alpha.sh:10  a || b
  GAP: nothing in the suite asserts the || branch's effect."
mk_ledger missing "# a ledger that records nothing at all"
mk_ledger noclass "$ID_S
  alpha.sh:10  a || b"
mk_ledger empty "$ID_S
  alpha.sh:10  a || b
  GAP:"
mk_ledger stale "$ID_S
  GAP: nothing asserts the || branch.

$ID_X
  GAP: recorded when this line still generated a cmp-flip mutant."
mk_ledger obsolete "$ID_S
  GAP: nothing asserts the || branch.

$ID_K
  GAP: recorded when nothing killed this return-flip."

PREDICATES="missing noclass empty stale obsolete"

# The message each predicate prints, and the sed that disables it. Each sed
# addresses the cl_err CALL by a substring of the message it emits and comments
# it out behind a `:`, which is what "disable this predicate" means with the
# least collateral: the surrounding if/elif structure, the loop, and every other
# predicate are left exactly as they were. Substituting the CONDITION instead
# would not do — `if false; then` on check A's first branch hands the entry to
# the elif, and the empty-reason error fires in the missing-classification
# error's place, so the gate would still report a problem and the demonstration
# would be of nothing.
sed_for() {   # $1=predicate → the sed expression that disables it
  local blank=': # BROKEN-BY-TEST cl_err'
  case "$1" in
    missing)  printf '%s' '/^ *cl_err ".*but has no entry in /s/cl_err/'"$blank"'/' ;;
    noclass)  printf '%s' '/^ *cl_err ".*has no GAP:/s/cl_err/'"$blank"'/' ;;
    empty)    printf '%s' '/^ *cl_err ".*has an empty /s/cl_err/'"$blank"'/' ;;
    stale)    printf '%s' '/^ *cl_err ".*for a mutant that no longer exists/s/cl_err/'"$blank"'/' ;;
    obsolete) printf '%s' '/^ *cl_err ".*for a mutant that is now KILLED/s/cl_err/'"$blank"'/' ;;
  esac
}
signature_for() {   # $1=predicate → the exact text its ERROR: line carries
  case "$1" in
    missing)  printf '%s' 'but has no entry in' ;;
    noclass)  printf '%s' 'has no GAP:/EQUIVALENT:/ENV-DEPENDENT: classification' ;;
    empty)    printf '%s' 'an empty reason suppresses nothing' ;;
    stale)    printf '%s' 'for a mutant that no longer exists — stale, delete it' ;;
    obsolete) printf '%s' 'for a mutant that is now KILLED — obsolete amnesty, delete it' ;;
  esac
}

out=""; rc=0
run_gate() {   # $1=the check-ledger.sh to run $2=predicate whose ledger to feed
  # --strict: see the note on the same helper in tests/test-falsify-ledger.sh.
  # The obsolete-amnesty predicate is only fatal in the reference environment,
  # so a demonstration that it can fail has to ask for that environment.
  out="$(bash "$1" --ledger "$TMP/led-$2.txt" --run-output "$RUN" --strict 2>/dev/null)"; rc=$?
}

# ── CONTROLS ──────────────────────────────────────────────────────────────────
# Every demonstration below reads "this fixture stopped failing". That sentence
# is only evidence if the fixture failed to begin with, and for the reason
# claimed — so the pristine gate is put through all six first.
run_gate "$CHECK" clean
check "control: a ledger matching the run exits 0" "0" "$rc"
assert_has "control: and says so, counted not implied" 'OK: 0 problem(s)' "$out"

for p in $PREDICATES; do
  run_gate "$CHECK" "$p"
  check "control: the $p fixture fails the pristine gate" "1" "$rc"
  assert_has "control: the $p fixture produces exactly one finding" '1 problem(s)' "$out"
  assert_has "control: and it is the $p predicate that produced it" "$(signature_for "$p")" "$out"
done

# ── THE DEMONSTRATIONS ────────────────────────────────────────────────────────
# A scratch tree per break. check-ledger.sh sources its operator vocabulary from
# generate.sh beside it, which in turn sources ../portability.sh, so the copy
# mirrors that layout — the real vocabulary, not one restated here.
#
# BROKEN carries the copy's path rather than break_tree printing it: the
# function also emits PASS/FAIL lines, and a `$(break_tree …)` would capture
# those into the path.
BROKEN=""
break_tree() {   # $1=predicate → sets BROKEN; 0 when the break really applied
  local p="$1" dir="$TMP/break-$1" expr n
  BROKEN=""
  mkdir -p "$dir/falsify"
  cp "$REPO_DIR/tests/portability.sh" "$dir/portability.sh"
  cp "$FALSIFY_DIR/generate.sh" "$dir/falsify/generate.sh"
  expr="$(sed_for "$p")"
  sed "$expr" "$CHECK" > "$dir/falsify/check-ledger.sh"

  # The break must have APPLIED. A sed whose pattern has drifted matches
  # nothing, rewrites nothing, and leaves a demonstration that "breaking" the
  # gate changed no behaviour — passing while proving the opposite of what it
  # claims. Exactly one line, too: a pattern that grew loose enough to hit two
  # call sites would be disabling more than the one predicate under test.
  n="$(diff "$CHECK" "$dir/falsify/check-ledger.sh" | grep -c '^< ')"
  if [[ "$n" != "1" ]]; then
    fail "$p: the break applied to exactly one line (sed changed $n — the demonstration would prove nothing)"
    return 1
  fi
  if ! bash -n "$dir/falsify/check-ledger.sh" 2>/dev/null; then
    fail "$p: the break left a parseable script"
    return 1
  fi
  pass "$p: the break applied to ONE line of a COPY of check-ledger.sh, which still parses"
  BROKEN="$dir/falsify/check-ledger.sh"
  return 0
}

for p in $PREDICATES; do
  break_tree "$p" || continue
  broken="$BROKEN"

  # The permissive behaviour comes back: the fixture that tripped this predicate
  # a moment ago is now waved through, and the gate SAYS 0, not merely exits 0.
  run_gate "$broken" "$p"
  check "$p DISABLED: its own fixture now passes (rc)" "0" "$rc"
  assert_has "$p DISABLED: … reporting 0 problem(s) — the old permissive behaviour" \
    'OK: 0 problem(s)' "$out"

  # …and nothing else was disabled with it. Without this, commenting out the
  # whole of cl_main would satisfy every assertion above.
  for q in $PREDICATES; do
    [[ "$q" == "$p" ]] && continue
    run_gate "$broken" "$q"
    check "$p DISABLED: the $q predicate still fires (rc)" "1" "$rc"
    assert_has "$p DISABLED: … with the $q message, and one finding" \
      "$(signature_for "$q")" "$out"
    assert_has "$p DISABLED: … and $q is still exactly one finding" '1 problem(s)' "$out"
  done

  # The clean fixture is unaffected in both directions: a break that made the
  # gate fail a good ledger would be a different bug wearing this one's clothes.
  run_gate "$broken" clean
  check "$p DISABLED: a clean ledger still passes" "0" "$rc"
done

# ── the real gate is exactly as it was ────────────────────────────────────────
# Every break lives under mktemp -d and dies with the trap. Asserting it rather
# than trusting it, because a broken check-ledger.sh left in tests/falsify/
# would be a gate that passes everything, in the file whose entire job is to
# fail.
check "tests/falsify/check-ledger.sh is byte-identical after all five breaks" \
  "$CHECK_SHA_BEFORE" "$(p_sha1 "$CHECK")"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
