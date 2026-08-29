#!/usr/bin/env bash
# tests/test-falsify-generate.sh — the oracle for tests/falsify/generate.sh.
#
# generate.sh enumerates mutants; this file is what stops it from enumerating the
# WRONG ones. The failure mode that matters is not a crash — it is an operator
# that quietly stops matching, because then every mutant is killed, the mutation
# score reads 100 %, and the tier reports that the hermetic suite is perfect. So
# the counts are pinned, per-operator coverage is asserted, and the bash -n gate
# is demonstrated as a no-op and shown to fail.
#
# Hermetic: no docker, no network. Every fixture is written into its own $TMP.
# The generator is never allowed to touch the repo — asserted, not assumed.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
if [[ ! -f "$ENGINE_DIR/build.sh" || ! -f "$ENGINE_DIR/sandbox.conf" ]]; then
  ENGINE_DIR="$(cd "$TESTS_DIR/../base" && pwd)"
fi
GEN="$TESTS_DIR/falsify/generate.sh"
ALL_OPS='cond-negate,logic-flip,return-flip,cmp-flip,stream-flip'
# The field separator, spelled out. A literal tab in a grep pattern in this file
# is one editor setting away from becoming spaces and matching nothing.
TAB=$'\t'

# shellcheck source=portability.sh
source "$TESTS_DIR/portability.sh"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

sha_of_string() {   # $1 = text → sha1 of exactly that text, no trailing newline
  printf '%s' "$1" > "$TMP/.sha-in"
  p_sha1 "$TMP/.sha-in"
}

# Mutants only (stdout); diagnostics are dropped. Every assertion below reads
# this, never the generator's source text.
gen() { bash "$GEN" "$@" 2>/dev/null; }

if [[ ! -f "$GEN" ]]; then
  fail "tests/falsify/generate.sh exists"
  printf '\n%d failure(s)\n' "$fails"; exit "$fails"
fi
pass "tests/falsify/generate.sh exists"

# ── 1. the contract: four tab-separated fields, nothing else on stdout ─────────
cat > "$TMP/t.sh" <<'EOF'
#!/usr/bin/env bash
f() { [[ -n "$1" ]] && return 0 || return 1; }
warn() { printf 'nope\n' >&2; }
EOF

out="$(gen "$TMP/t.sh")"
grep -q '^cond-negate' <<<"$out" && pass "cond-negate emitted" || fail "cond-negate emitted"
grep -q '^logic-flip'  <<<"$out" && pass "logic-flip emitted"  || fail "logic-flip emitted"
grep -q '^return-flip' <<<"$out" && pass "return-flip emitted" || fail "return-flip emitted"

# Non-vacuous both ways: this fixture DOES contain a `>&2`, so "no stream-flip"
# is a real observation about the gate and not about the fixture. The paired
# assertion below proves the operator can fire on this very file.
if grep -q '^stream-flip' <<<"$out"; then
  fail "stream-flip is off by default"
else
  pass "stream-flip is off by default"
fi
if grep -q '^stream-flip' < <(FALSIFY_OPERATORS="$ALL_OPS" gen "$TMP/t.sh"); then
  pass "stream-flip fires on the same fixture when FALSIFY_OPERATORS names it"
else
  fail "stream-flip fires on the same fixture when FALSIFY_OPERATORS names it — the assertion above was vacuous"
fi

bad="$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { n++ } END { print n+0 }')"
[[ "$bad" == "0" ]] \
  && pass "every stdout line carries exactly 4 tab-separated fields" \
  || fail "every stdout line carries exactly 4 tab-separated fields — $bad line(s) did not"

shape_bad="$(printf '%s\n' "$out" | awk -F'\t' '
  $1 !~ /^(cond-negate|logic-flip|return-flip|cmp-flip|stream-flip)$/ { n++; next }
  $2 !~ /^[0-9]+$/ { n++; next }
  # length()+[0-9a-f]+ rather than {40}: mawk 1.3.4-20200120, which ubuntu:22.04
  # ships and the bash-floor container therefore runs, has interval quantifiers
  # DISABLED by default, so /^[0-9a-f]{40}$/ matches no sha1 at all there and
  # every well-formed line counts as malformed. Found by the local layer floor
  # run: green on the 24.04 mawk here and on macOS, red at the floor.
  (length($3) != 40 || $3 !~ /^[0-9a-f]+$/) { n++ }
  END { print n+0 }')"
[[ "$shape_bad" == "0" ]] \
  && pass "field 1 is a known operator, field 2 a line number, field 3 a sha1" \
  || fail "field 1 is a known operator, field 2 a line number, field 3 a sha1 — $shape_bad bad line(s)"

# The tally is a diagnostic and must not pollute the machine-readable stream.
err="$(bash "$GEN" "$TMP/t.sh" 2>&1 >/dev/null)"
grep -q 'mutant(s)' <<<"$err" \
  && pass "the mutant/discard tally goes to stderr" \
  || fail "the mutant/discard tally goes to stderr"
if grep -qvE "^[a-z-]+${TAB}[0-9]+${TAB}[0-9a-f]{40}${TAB}" <<<"$out"; then
  fail "stdout carries mutants and nothing else"
else
  pass "stdout carries mutants and nothing else"
fi

# ── 2. field 3 is the sha1 of the TRIMMED original line ───────────────────────
sha_bad=0
sha_checked=0
while IFS=$'\t' read -r _op lineno sha _text; do
  [[ -n "${lineno:-}" ]] || continue
  orig="$(sed -n "${lineno}p" "$TMP/t.sh")"
  trimmed="${orig#"${orig%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  want="$(sha_of_string "$trimmed")"
  sha_checked=$((sha_checked + 1))
  [[ "$sha" == "$want" ]] || sha_bad=$((sha_bad + 1))
done <<<"$out"
(( sha_checked > 0 )) \
  && pass "checked $sha_checked mutant identity hash(es)" \
  || fail "checked 0 identity hashes — the loop matched nothing"
[[ "$sha_bad" == "0" ]] \
  && pass "field 3 is the sha1 of the trimmed original line" \
  || fail "field 3 is the sha1 of the trimmed original line — $sha_bad mismatch(es)"

# ── 3. one mutant per token OCCURRENCE, not per line ──────────────────────────
cat > "$TMP/two.sh" <<'EOF'
#!/usr/bin/env bash
a() { true && true && true; }
EOF
n_lf="$(gen "$TMP/two.sh" | grep -c '^logic-flip' || true)"
[[ "$n_lf" == "2" ]] \
  && pass "two && on one line yield two logic-flip mutants (per occurrence, not per line)" \
  || fail "two && on one line yield two logic-flip mutants — got $n_lf"
n_distinct="$(gen "$TMP/two.sh" | grep '^logic-flip' | cut -f4 | sort -u | wc -l | tr -d ' ')"
[[ "$n_distinct" == "2" ]] \
  && pass "the two logic-flip mutants differ (a different occurrence was flipped)" \
  || fail "the two logic-flip mutants differ — got $n_distinct distinct text(s)"

# ── 4. < and > flip only inside [[ ]] / (( )) spans ───────────────────────────
cat > "$TMP/cmp.sh" <<'EOF'
#!/usr/bin/env bash
t1() { [[ "$1" < "$2" ]]; }
t2() { (( $1 > $2 )); }
t3() { cat /etc/hosts > /dev/null; }
t4() { read -r l < /etc/hosts; }
t5() { printf '%s' "$(( 1 << 3 ))"; }
EOF
cmp_lines="$(FALSIFY_OPERATORS="$ALL_OPS" gen "$TMP/cmp.sh" | grep '^cmp-flip' | cut -f2 | sort -u | tr '\n' ' ')"
[[ "$cmp_lines" == "2 3 " ]] \
  && pass "< and > flip inside [[ ]] and (( )) only (lines: $cmp_lines)" \
  || fail "< and > flip inside [[ ]] and (( )) only — cmp-flip landed on lines: ${cmp_lines:-none}"

# ── 5. skips: shebang, full-line comment, trailing comment, heredoc body ──────
# Every skipped construct here contains a token the generator WOULD otherwise
# mutate, and the file ends with a sentinel line that must still be mutated —
# without it, "no mutants in the heredoc" would pass by emitting nothing at all.
cat > "$TMP/skip.sh" <<'SKIPEOF'
#!/usr/bin/env bash && return 0
# a full-line comment with && and return 0 and [[ -n x ]] in it
code() { true && true; }   # trailing && comment with return 0
cat > /dev/null <<'INNER'
body && line with return 0
[[ -n "$x" ]] || exit 1
INNER
grep -q x <<<"a && b" || true
sentinel() { true && true; }
SKIPEOF

skip_out="$(gen "$TMP/skip.sh")"
skip_lines="$(cut -f2 <<<"$skip_out" | sort -un | tr '\n' ' ')"
for forbidden in 1 2 5 6 7; do
  if grep -qE "^[a-z-]+${TAB}$forbidden${TAB}" <<<"$skip_out"; then
    fail "line $forbidden is skipped (shebang/comment/heredoc body/terminator) — a mutant was emitted there"
  else
    pass "line $forbidden is skipped (shebang/comment/heredoc body/terminator)"
  fi
done
n3="$(grep -cE "^logic-flip${TAB}3${TAB}" <<<"$skip_out" || true)"
[[ "$n3" == "1" ]] \
  && pass "a trailing comment's && is skipped while the code's && is mutated (line 3: 1 mutant)" \
  || fail "a trailing comment's && is skipped while the code's && is mutated — line 3 yielded $n3"
grep -qE "^logic-flip${TAB}3${TAB}.*# trailing && comment" <<<"$skip_out" \
  && pass "the trailing comment survives into the mutated line unchanged" \
  || fail "the trailing comment survives into the mutated line unchanged"
grep -qE "^logic-flip${TAB}9${TAB}" <<<"$skip_out" \
  && pass "the sentinel line after the heredoc terminator IS mutated (skips above are not vacuous)" \
  || fail "the sentinel line after the heredoc terminator IS mutated — the heredoc swallowed the rest of the file (skip lines: ${skip_lines:-none})"
grep -qE "^logic-flip${TAB}8${TAB}" <<<"$skip_out" \
  && pass "a <<< herestring is not read as a heredoc opener" \
  || fail "a <<< herestring is not read as a heredoc opener — line 8 yielded nothing"

# ── 6. the bash -n gate, DEMONSTRATED ────────────────────────────────────────
# Driven through falsify_check_syntax — the same function falsify_generate's loop
# calls — by sourcing the generator rather than re-implementing the check.
cat > "$TMP/gate.sh" <<'EOF'
#!/usr/bin/env bash
f() {
  if [[ -n "$1" ]]; then
    printf 'x\n'
  fi
}
f "$@"
EOF

malformed=(
  '  if [[ -n "$1" ]]; then )'
  '  fi'
  '  x=$( '
)
wellformed=(
  '  if [[ ! -n "$1" ]]; then'
  '  if ! [[ -n "$1" ]]; then'
  '  if [[ -z "$1" ]]; then'
  '  if true; then'
  '  if [[ -n "$1" ]] && [[ -n "$2" ]]; then'
)

# Ground truth, established independently of the generator: each malformed
# candidate really does break the file, each well-formed one really does not.
gt_bad=0
for cand in "${malformed[@]}"; do
  { head -n 2 "$TMP/gate.sh"; printf '%s\n' "$cand"; tail -n +4 "$TMP/gate.sh"; } > "$TMP/gt.sh"
  bash -n "$TMP/gt.sh" 2>/dev/null && gt_bad=$((gt_bad + 1))
done
[[ "$gt_bad" == "0" ]] \
  && pass "all 3 malformed candidates are genuinely unparseable (ground truth)" \
  || fail "all 3 malformed candidates are genuinely unparseable — $gt_bad of them parse, so the gate demo below proves nothing"

FALSIFY_TMPDIR="$TMP/scratch"
export FALSIFY_TMPDIR
# shellcheck source=falsify/generate.sh
source "$GEN"

discarded=0
for cand in "${malformed[@]}"; do
  falsify_check_syntax "$TMP/gate.sh" 3 "$cand" || discarded=$((discarded + 1))
done
[[ "$discarded" == "3" ]] \
  && pass "the bash -n gate discards 3/3 malformed candidates" \
  || fail "the bash -n gate discards 3/3 malformed candidates — discarded $discarded"

accepted=0
for cand in "${wellformed[@]}"; do
  falsify_check_syntax "$TMP/gate.sh" 3 "$cand" && accepted=$((accepted + 1))
done
[[ "$accepted" == "5" ]] \
  && pass "the bash -n gate accepts 5/5 well-formed candidates" \
  || fail "the bash -n gate accepts 5/5 well-formed candidates — accepted $accepted"

# THE DEMONSTRATION. A gate that discarded nothing would still let the 5/5
# assertion pass, so the 3/3 assertion is the one that has to be shown to break.
# Mirror the real layout (falsify/generate.sh beside ../portability.sh) so the
# copy resolves its own source line, then turn the `bash -n` call into `true`.
mkdir -p "$TMP/mirror/falsify"
cp "$TESTS_DIR/portability.sh" "$TMP/mirror/portability.sh"
sed 's|bash -n "\$_FALSIFY_SYNTAX_TMP" 2>/dev/null|true|' "$GEN" \
  > "$TMP/mirror/falsify/generate.sh"
if grep -q 'bash -n "\$_FALSIFY_SYNTAX_TMP"' "$TMP/mirror/falsify/generate.sh"; then
  fail "the no-op-gate fixture was rewritten — the demonstration below is vacuous"
else
  pass "the no-op-gate fixture was rewritten (bash -n replaced by true)"
fi
nooped="$(
  FALSIFY_TMPDIR="$TMP/scratch2"
  # shellcheck source=/dev/null
  source "$TMP/mirror/falsify/generate.sh"
  n=0
  for cand in '  if [[ -n "$1" ]]; then )' '  fi' '  x=$( '; do
    falsify_check_syntax "$TMP/gate.sh" 3 "$cand" && n=$((n + 1))
  done
  printf '%s' "$n"
)"
[[ "$nooped" == "3" ]] \
  && pass "with the gate stubbed out, all 3 malformed candidates are accepted — the 3/3 assertion reads the gate's real verdict" \
  || fail "with the gate stubbed out, only $nooped/3 malformed candidates were accepted — the 3/3 assertion is not reading the gate"

# ── 7. the DISCARD path is reachable end to end ──────────────────────────────
# The gate above is a function; this proves falsify_generate's loop actually
# routes a rejected candidate to the tally instead of printing it. Break one
# operator's replacement text so it cannot parse, then watch the whole pipeline.
sed "s|_falsify_tok cond-negate \"\$i\" 2 '\[\[ !'|_falsify_tok cond-negate \"\$i\" 2 '[[ !)'|" \
  "$GEN" > "$TMP/mirror/falsify/broken.sh"
if grep -qF "'[[ !)'" "$TMP/mirror/falsify/broken.sh"; then
  pass "the broken-operator fixture was rewritten"
else
  fail "the broken-operator fixture was rewritten — the assertions below are vacuous"
fi
broken_err="$(bash "$TMP/mirror/falsify/broken.sh" "$TMP/t.sh" 2>&1 >"$TMP/broken.out")"
grep -q 'DISCARD' <<<"$broken_err" \
  && pass "a malformed candidate is reported as DISCARD on stderr" \
  || fail "a malformed candidate is reported as DISCARD on stderr"
grep -qE 'mutant\(s\), [1-9][0-9]* discarded' <<<"$broken_err" \
  && pass "the discard tally is non-zero when a candidate does not parse" \
  || fail "the discard tally is non-zero when a candidate does not parse — got: $broken_err"
if grep -q '^cond-negate' "$TMP/broken.out"; then
  fail "a discarded candidate never reaches stdout"
else
  pass "a discarded candidate never reaches stdout"
fi

# ── 7b. a gate that CANNOT RUN is not a discard ──────────────────────────────
# `bash -n` answers three different ways and the generator must not flatten them:
# rc 0 parses, rc 2 is a real syntax error, and anything else means bash never
# judged the candidate at all — an unreadable scratch file, or the shape a failed
# fork takes under memory/process pressure. Treating the third as a discard turns
# load into a QUIETLY SMALLER corpus reported with a successful exit code, which
# is the one failure a mutation tier must never have.
#
# Demonstrated by making the gate un-runnable (rc 127) rather than argued: the
# generator must exit non-zero and name the cause, and must NOT report a tally.
# IN $TMP, NOT IN THE REPO. The rewritten copy used to be dropped beside the
# original as tests/falsify/tmp-cantrun-$$.sh, because generate.sh sources
# `../portability.sh` relative to its own directory and a copy anywhere else
# could not find it. That put the ONLY write this suite makes outside mktemp
# into the developer's working tree -- and verify-on-host.sh's Phase 5 mounts
# that tree :ro into the bash-floor container, where the redirect simply fails
# and every assertion below it reports on a file that was never written
# ("No such file or directory", measured 2026-08-28). The layout is reproduced
# instead: a falsify/ directory with portability.sh as its sibling, which is all
# the copy needs to resolve its source line.
cantrun_root="$TMP/cantrun"
mkdir -p "$cantrun_root/falsify"
# $TESTS_DIR, not $ENGINE_DIR/tests: tests/ sits beside the engine in one repo
# and inside it in the other, and the mirror fixture 70 lines above already
# resolves this file the layout-independent way.
cp "$TESTS_DIR/portability.sh" "$cantrun_root/portability.sh"
cantrun="$cantrun_root/falsify/generate.sh"
sed 's|bash -n "\$_FALSIFY_SYNTAX_TMP" 2>/dev/null|bash -n /nonexistent/nope.sh 2>/dev/null|' \
  "$GEN" > "$cantrun"
if grep -q 'nonexistent/nope.sh' "$cantrun"; then
  pass "the un-runnable-gate fixture was rewritten"
else
  fail "the un-runnable-gate fixture was rewritten — the demonstration below is vacuous"
fi
cr_out="$(bash "$cantrun" "$ENGINE_DIR/tools-lib.sh" 2>"$TMP/cantrun.err")"; cr_rc=$?
rm -rf "$cantrun_root"
(( cr_rc != 0 )) \
  && pass "a gate that cannot run FAILS the generation (rc=$cr_rc)" \
  || fail "a gate that cannot run FAILS the generation — got rc=0, so a short corpus would be reported as a complete one"
[[ -z "$cr_out" ]] \
  && pass "…and emits no mutants to stdout" \
  || fail "…and emits no mutants to stdout (got $(grep -c . <<<"$cr_out"))"
grep -q 'could not run' "$TMP/cantrun.err" \
  && pass "…and says the gate could not run, rather than blaming the candidate" \
  || fail "…and says the gate could not run — stderr: $(head -2 "$TMP/cantrun.err" | tr '\n' '|')"
! grep -q 'discarded' "$TMP/cantrun.err" \
  && pass "…and reports no discard tally, which would read as a completed run" \
  || fail "…and reports no discard tally — got: $(grep -o '[0-9]* mutant(s), [0-9]* discarded' "$TMP/cantrun.err")"

# ── 8. the pinned counts, all five operators ─────────────────────────────────
# A regression fence, not a fact about these files. If a target's real content
# changes, the number moves legitimately and is updated here. What must NOT
# happen quietly is an operator that stops matching: that shows up as a smaller
# count here instead of as "the suite kills everything".
#
# tools-lib.sh moved 17 -> 18 when `stream-flip` gained its reverse direction
# (stdout -> `>&2`), which the tier needed to reach historical hole #6. The
# default four-operator corpus is unchanged at 249 — stream-flip is opt-in.
#
# bash-floor.sh moved 12 -> 13 when the span scanner learned to carry `[[`/`((`
# depth across a backslash continuation (backlog F9). Before that, the `<` on
# bash-floor.sh:42 — inside the multi-line arithmetic condition that IS this
# repo's bash floor check — was unreachable by any mutant. The fix is strictly
# additive: measured before/after, exactly one mutant gained, none lost.
declare -A PINNED=(
  ["$ENGINE_DIR/tools-lib.sh"]=18
  ["$ENGINE_DIR/bash-floor.sh"]=13
  ["$ENGINE_DIR/shared-files.sh"]=5
)
for target in "$ENGINE_DIR/tools-lib.sh" "$ENGINE_DIR/bash-floor.sh" "$ENGINE_DIR/shared-files.sh"; do
  want="${PINNED[$target]}"
  got="$(FALSIFY_OPERATORS="$ALL_OPS" gen "$target" | grep -c . || true)"
  [[ "$got" == "$want" ]] \
    && pass "$(basename "$target"): $want mutant(s) under all five operators" \
    || fail "$(basename "$target"): expected $want mutant(s) under all five operators, got $got"
  d="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$target" 2>&1 >/dev/null \
        | sed -n 's/.*mutant(s), \([0-9]*\) discarded.*/\1/p')"
  [[ "$d" == "0" ]] \
    && pass "$(basename "$target"): 0 candidates discarded by bash -n" \
    || fail "$(basename "$target"): expected 0 discards, got ${d:-unknown} — the generator emits malformed output"
done

# The pin has to be sensitive to an operator going missing, or it fences
# nothing. Drop one operator and the number must move.
reduced="$(FALSIFY_OPERATORS='logic-flip,return-flip,cmp-flip,stream-flip' \
             gen "$ENGINE_DIR/tools-lib.sh" | grep -c . || true)"
[[ "$reduced" != "17" ]] \
  && pass "dropping one operator changes tools-lib.sh's count ($reduced != 17) — the pin is sensitive" \
  || fail "dropping cond-negate left tools-lib.sh at 17 — the pinned count cannot detect a dead operator"

# ── 9. every operator is alive somewhere in the staged targets ────────────────
allout="$(for target in "$ENGINE_DIR/tools-lib.sh" "$ENGINE_DIR/bash-floor.sh" \
                        "$ENGINE_DIR/shared-files.sh"; do
            FALSIFY_OPERATORS="$ALL_OPS" gen "$target"
          done)"
for op in cond-negate logic-flip return-flip cmp-flip stream-flip; do
  grep -q "^$op${TAB}" <<<"$allout" \
    && pass "$op produced at least one mutant across the three pinned targets" \
    || fail "$op produced no mutant across the three pinned targets — the operator is dead"
done

# ── 10. every emitted mutant parses, verified INDEPENDENTLY ──────────────────
# Not via falsify_check_syntax: asserting a generator's output with the
# generator's own checker is assert f(x) == f(x). This rebuilds the file with
# head/tail and parses it.
mut_checked=0; mut_bad=0; changed_bad=0; mut_emitted=0
for src in "$ENGINE_DIR/tools-lib.sh" "$ENGINE_DIR/bash-floor.sh" "$ENGINE_DIR/shared-files.sh"; do
  while IFS=$'\t' read -r _op lineno _sha text; do
    mut_emitted=$((mut_emitted + 1))
    [[ -n "${lineno:-}" ]] || continue
    { head -n $((lineno - 1)) "$src"; printf '%s\n' "$text"; tail -n +$((lineno + 1)) "$src"; } \
      > "$TMP/applied.sh"
    bash -n "$TMP/applied.sh" 2>/dev/null || mut_bad=$((mut_bad + 1))
    [[ "$text" == "$(sed -n "${lineno}p" "$src")" ]] && changed_bad=$((changed_bad + 1))
    mut_checked=$((mut_checked + 1))
  done < <(FALSIFY_OPERATORS="$ALL_OPS" gen "$src")
done
# Derived from PINNED, not a second hardcoded total: 34 and 12 were two
# statements of the same fact, and raising the pinned count left this one
# stale — the exact drift this repo removes wherever it finds it.
mut_expected=0
for _t in "${!PINNED[@]}"; do mut_expected=$(( mut_expected + PINNED[$_t] )); done
# TWO facts, told apart, because one number cannot say which went wrong. A
# generator that emitted fewer rows and a walk that could not read the rows it
# was given are different defects with different owners, and the single
# walked-vs-pinned comparison this replaced reported both as the same sentence —
# which cost an hour on a macOS host where the emitted count was the one that
# moved.
[[ "$mut_emitted" == "$mut_expected" ]] \
  && pass "the generator emitted all $mut_expected mutants of the three pinned targets" \
  || fail "the generator emitted $mut_emitted of $mut_expected mutants across the three pinned targets — the GENERATOR came up short, not the walk"
[[ "$mut_checked" == "$mut_emitted" ]] \
  && pass "independently re-applied every one of the $mut_emitted rows emitted" \
  || fail "independently re-applied $mut_checked of the $mut_emitted rows emitted — $((mut_emitted - mut_checked)) row(s) carried no line number, so the generator's output is malformed"
[[ "$mut_bad" == "0" ]] \
  && pass "every emitted mutant parses when applied to the real file" \
  || fail "every emitted mutant parses when applied to the real file — $mut_bad did not"
[[ "$changed_bad" == "0" ]] \
  && pass "every emitted mutant actually changes its line" \
  || fail "every emitted mutant actually changes its line — $changed_bad were identical to the original"

# ── 11. the generator never writes to its target ─────────────────────────────
before="$(for f in "$ENGINE_DIR/tools-lib.sh" "$ENGINE_DIR/bash-floor.sh" \
                   "$ENGINE_DIR/shared-files.sh"; do p_sha1 "$f"; p_stat_meta "$f"; done)"
FALSIFY_OPERATORS="$ALL_OPS" gen "$ENGINE_DIR/tools-lib.sh" >/dev/null
FALSIFY_OPERATORS="$ALL_OPS" gen "$ENGINE_DIR/bash-floor.sh" >/dev/null
FALSIFY_OPERATORS="$ALL_OPS" gen "$ENGINE_DIR/shared-files.sh" >/dev/null
after="$(for f in "$ENGINE_DIR/tools-lib.sh" "$ENGINE_DIR/bash-floor.sh" \
                  "$ENGINE_DIR/shared-files.sh"; do p_sha1 "$f"; p_stat_meta "$f"; done)"
[[ -n "$before" && "$before" == "$after" ]] \
  && pass "generating mutants leaves the target files byte-identical" \
  || fail "generating mutants leaves the target files byte-identical — content or metadata changed"

# ── 12. failure modes are loud ───────────────────────────────────────────────
bash "$GEN" >"$TMP/o" 2>"$TMP/e"; rc=$?
[[ "$rc" != "0" ]] && pass "no argument exits non-zero (got $rc)" || fail "no argument exits non-zero"
[[ ! -s "$TMP/o" ]] && pass "no argument prints nothing to stdout" || fail "no argument prints nothing to stdout"
grep -qi usage "$TMP/e" && pass "no argument prints a usage line to stderr" || fail "no argument prints a usage line to stderr"

bash "$GEN" "$TMP/definitely-absent.sh" >"$TMP/o" 2>"$TMP/e"; rc=$?
[[ "$rc" != "0" ]] && pass "a missing file exits non-zero (got $rc)" || fail "a missing file exits non-zero"
[[ ! -s "$TMP/o" ]] && pass "a missing file prints nothing to stdout" || fail "a missing file prints nothing to stdout"

FALSIFY_OPERATORS='cond-negate,nope-flip' bash "$GEN" "$TMP/t.sh" >"$TMP/o" 2>"$TMP/e"; rc=$?
[[ "$rc" != "0" ]] && pass "an unknown operator name exits non-zero (got $rc)" || fail "an unknown operator name exits non-zero"
[[ ! -s "$TMP/o" ]] \
  && pass "an unknown operator name generates nothing rather than a silent subset" \
  || fail "an unknown operator name generates nothing rather than a silent subset"
grep -q 'nope-flip' "$TMP/e" \
  && pass "the error names the unknown operator" || fail "the error names the unknown operator"

FALSIFY_OPERATORS='' bash "$GEN" "$TMP/t.sh" >"$TMP/o" 2>"$TMP/e"; rc=$?
# An empty value means the caller asked for an empty set, which can only ever
# produce an empty corpus. Same rule the integration runner applies to a
# selection that matches no case: refuse, do not report success having done
# nothing. (Unset, by contrast, means "use the defaults" — asserted in §1.)
[[ "$rc" != "0" ]] \
  && pass "an empty FALSIFY_OPERATORS is refused rather than silently generating nothing (got $rc)" \
  || fail "an empty FALSIFY_OPERATORS is refused rather than silently generating nothing"

# ── 13. an explicit operator subset emits only that operator ─────────────────
sub="$(FALSIFY_OPERATORS='logic-flip' gen "$ENGINE_DIR/tools-lib.sh")"
sub_ops="$(cut -f1 <<<"$sub" | sort -u | tr '\n' ' ')"
[[ "$sub_ops" == "logic-flip " ]] \
  && pass "FALSIFY_OPERATORS=logic-flip emits logic-flip only" \
  || fail "FALSIFY_OPERATORS=logic-flip emits logic-flip only — got: ${sub_ops:-none}"
full_lf="$(FALSIFY_OPERATORS="$ALL_OPS" gen "$ENGINE_DIR/tools-lib.sh" | grep -c '^logic-flip' || true)"
sub_lf="$(grep -c '^logic-flip' <<<"$sub" || true)"
[[ "$sub_lf" == "$full_lf" && "$sub_lf" != "0" ]] \
  && pass "the subset run yields the same $sub_lf logic-flip mutant(s) as the full run" \
  || fail "the subset run yields the same logic-flip mutants as the full run — $sub_lf vs $full_lf"

# stream-flip must remain reachable per target, which is the whole reason it is
# gated rather than deleted.
sf="$(FALSIFY_OPERATORS='stream-flip' gen "$ENGINE_DIR/bash-floor.sh" | grep -c '^stream-flip' || true)"
[[ "$sf" == "2" ]] \
  && pass "stream-flip alone yields bash-floor.sh's 2 stderr redirections" \
  || fail "stream-flip alone yields bash-floor.sh's 2 stderr redirections — got $sf"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
