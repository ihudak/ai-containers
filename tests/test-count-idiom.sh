#!/usr/bin/env bash
# tests/test-count-idiom.sh — `grep -c … || <fallback>` is always wrong.
#
# THE DEFECT, IN ONE LINE. `grep -c` and `grep -vc` ALWAYS print a count, and
# they exit 1 when that count is ZERO. So `n="$(grep -c … || printf 0)"` appends
# a SECOND zero on the one path the fallback was written for, and `n` becomes
# the two-line string "0\n0".
#
# WHAT THAT COSTS, all three observed in this repo rather than imagined:
#   * in arithmetic — `(( n > 0 ))` dies with
#     `((: 0\n0: syntax error in expression`, so the code does not merely
#     mis-count, it aborts;
#   * in a RECORD — `printf 'SKIPPED|%s|%s|%s|…' … "$n"` emits a line break
#     inside the record, and the harvester reads two malformed ones. Silent
#     corruption of the tier's own output, not a loud error;
#   * in a DIAGNOSTIC — a one-line SCAFFOLD-FAILED message splits in two,
#     precisely in the failure case it exists to report.
#
# AND IT HIDES, WHICH IS WHY THIS FILE EXISTS. The idiom is harmless while the
# count happens to be non-zero, so it passes review, passes CI, and waits. It
# was fixed at four sites, then a fifth was found, then three more. Three
# separate passes over the same defect, each believed complete. A mechanical
# sweep is the only thing that can make "complete" a checkable claim.
#
# THE RULE IS DELIBERATELY NARROW: only a `grep` whose flags contain `c`, and
# only when the `||` binds to IT. A match-printing `grep … || echo '<absent>'`
# is CORRECT — that grep prints nothing when it does not match — so the check
# looks at the LAST grep before each `||`, not at any grep on the line. Getting
# that wrong would flag correct code and the rule would be turned off.
#
# The fix is always the same shape:
#     n="$(grep -c . "$f" 2>/dev/null)"; n="${n:-0}"
# which still defaults when the file is MISSING (grep prints nothing, exit 2).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Returns 0 when the line carries the defect. Exposed as a function so the
# self-test below runs the REAL rule over known-bad and known-good vectors
# rather than a paraphrase of it.
count_idiom_violation() {   # <line>
  local line="$1" before after last_grep fallback
  case "$line" in
    *'||'*) ;;
    *) return 1 ;;
  esac
  # A per-line opt-out, in this repo's `# shellcheck disable=…` / `# dialect-lint:
  # allow …` idiom. The reason is REQUIRED and checked for: a marker with nothing
  # after it suppresses nothing. Its only legitimate use is a line that IS the bad
  # code, i.e. this file's own vectors.
  [[ "$line" =~ \#[[:space:]]*count-idiom:[[:space:]]*allow[[:space:]]+[^[:space:]] ]] && return 1
  local rest="$line"
  while [[ "$rest" == *'||'* ]]; do
    before="${rest%%||*}"
    after="${rest#*||}"
    rest="$after"
    [[ "$before" == *grep* ]] || continue
    last_grep="grep${before##*grep}"
    # THE `||` MUST BIND TO THE GREP. Anything that ends a command between the
    # two means it does not — `[[ … ]] && printf 1 || printf 0` is a TERNARY
    # whose `||` guards the printf, and `n=$(grep -c …); [[ … ]] && x || y` is
    # two statements. Flagging either would put this rule on correct code, and a
    # rule that does that gets switched off.
    case "$last_grep" in
      *'&&'*|*';'*|*']]'*) continue ;;
    esac
    # …and the grep must be a COUNTING one. Flags may cluster: -c, -vc, -rc.
    [[ "$last_grep" =~ ^grep[[:space:]]+(-[a-zA-Z]*c[a-zA-Z]*)([[:space:]]|$) ]] || continue
    # …and the fallback must PRODUCE OUTPUT. This is the whole distinction, and
    # missing it is what made the first version of this rule flag 18 correct
    # lines: `|| true` and `|| :` print NOTHING, so they only discard grep's
    # exit status — which is exactly right under `set -e`, and is the dominant
    # idiom in this repo. Only a fallback that PRINTS appends a second value.
    fallback="${after%%[;)]*}"
    fallback="${fallback##*( )}"
    case "$fallback" in
      *printf*|*echo*) return 0 ;;
    esac
  done
  return 1
}

# ── the rule, tested on vectors before it is trusted on the tree ─────────────
# A scanner nobody has seen reject anything is a scanner that reports a clean
# tree because its regex never matches.
declare -a bad=(
  'n="$(grep -c . "$f" 2>/dev/null || printf 0)"'   # count-idiom: allow — this line IS a vector for the rule
  '_n="$(grep -vc Authorization: "$LOG" 2>/dev/null || printf 0)"'   # count-idiom: allow — this line IS a vector for the rule
  '"$(ps -o pid= -u "$(id -u)" 2>/dev/null | grep -c . || printf %s ?)"'   # count-idiom: allow — this line IS a vector for the rule
  'n="$(grep -c . "$f" || echo 0)"'   # count-idiom: allow — this line IS a vector for the rule
)
declare -a good=(
  # the fix
  'n="$(grep -c . "$f" 2>/dev/null)"; n="${n:-0}"'
  # a fallback that PRINTS NOTHING only discards the status — correct, and the
  # dominant idiom in this repo (18 lines of it when this rule was written)
  'entries="$(printf "%s" "$u" | grep -c "^### " || true)"'   # count-idiom: allow — this line IS a vector for the rule
  'count="$(builds | grep -c . || :)"'   # count-idiom: allow — this line IS a vector for the rule
  # the || belongs to a match-printing grep, which prints nothing when it misses
  'REPOS_PATH=$(grep "^REPOS_PATH=" "$CAPTURE" || echo "<absent>")'
  # …and to a ternary, not to the grep
  '"$( [[ "$(grep -c "^M" <<< "$O")" -gt 0 ]] && printf 1 || printf 0 )"'
  'nr="$(grep -c x "$f")"; [[ "$nr" -ge 3 ]] && pass "y" || fail "z"'
  # not a grep at all
  'v="$(ulimit -u 2>/dev/null || printf ?)"'
)
v_bad=0 v_good=0
for l in "${bad[@]}"; do count_idiom_violation "$l" && v_bad=$((v_bad + 1)); done
for l in "${good[@]}"; do count_idiom_violation "$l" || v_good=$((v_good + 1)); done
if (( v_bad == ${#bad[@]} )); then
  pass "the rule flags all ${#bad[@]} known-bad vector(s)"
else
  fail "the rule flags all ${#bad[@]} known-bad vector(s) — caught only $v_bad, so the sweep below cannot be trusted"
fi
if (( v_good == ${#good[@]} )); then
  pass "  … and none of the ${#good[@]} known-good ones, including a match-printing grep with a legitimate ||"
else
  fail "  … and none of the ${#good[@]} known-good ones — $((${#good[@]} - v_good)) false positive(s); a rule that flags correct code gets switched off"
fi

# ── the sweep ────────────────────────────────────────────────────────────────
# Tracked plus untracked-and-not-ignored, the same list the lint gate uses: a
# file written but not yet `git add`ed is exactly the one about to be committed.
mapfile -t files < <(
  { ( cd "$REPO_DIR" && git ls-files '*.sh' 2>/dev/null )
    ( cd "$REPO_DIR" && git ls-files --others --exclude-standard '*.sh' 2>/dev/null ); } | sort -u
)
hits=0 scanned=0
for f in "${files[@]}"; do
  [[ -f "$REPO_DIR/$f" ]] || continue
  scanned=$((scanned + 1))
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if count_idiom_violation "$line"; then
      printf 'FAIL: %s:%s carries `grep -c … || fallback` — grep -c prints a count AND exits 1 when it is zero, so the fallback appends a second value and the result is the two-line string "0\\n0"\n' "$f" "$n"
      hits=$((hits + 1)); fails=$((fails + 1))
    fi
  done < "$REPO_DIR/$f"
done

if (( scanned == 0 )); then
  fail "the sweep read no files — the pathspec matched nothing, so a clean result means nothing"
elif (( hits == 0 )); then
  pass "no count-grep is guarded by || across $scanned script(s)"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
