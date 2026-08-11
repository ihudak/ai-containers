#!/usr/bin/env bash
# Keeps the known-bad demonstrations honest.
#
# The suite's authoring rule says a case is not accepted until it has been seen
# FAILING against the configuration it exists to catch. That rule was prose. It
# held for increment 1 because the demonstrations happened by hand during the
# session, and it would have decayed the moment someone added a case in a hurry
# — nothing anywhere could tell the difference between a case proven
# discriminating and a case nobody ever broke on purpose.
#
# This file makes the rule mechanical, in both directions:
#
#   every mutation still applies    → a refactor that moves the code being
#                                     broken reports itself, instead of leaving
#                                     a mutation that mutates nothing
#   every case has a mutation       → a new launcher-tier case without a
#                                     known-bad patch fails HERE, at review
#                                     time, not silently forever
#
# Scope is the launcher tier (mounts/groups/volumes). Increment 1's network
# cases predate this mechanism and keep their fixture-based demonstrations under
# tests/integration/fixtures/ — two known-bad daemons, each preserving a
# different real bug. Those are deliberately not converted: they are copies of
# code that no longer exists, so there is nothing for a patch to apply to.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUT_DIR="$REPO_DIR/tests/integration/mutations"
CASES_DIR="$REPO_DIR/tests/integration/cases"
MUTATE="$REPO_DIR/tests/integration/mutate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

bash -n "$MUTATE" && pass "mutate.sh bash -n" || fail "mutate.sh bash -n"

# A run inside a git worktree is required for `git apply --check`; say so rather
# than reporting a clean pass on a machine that checked nothing.
if ! ( cd "$REPO_DIR" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  fail "these checks need a git working tree (git apply --check) — nothing was verified"
  printf '\n%d failure(s)\n' "$fails"
  exit "$fails"
fi

# ── There is a mutation set at all ─────────────────────────────────────────────
n_patch=0
for p in "$MUT_DIR"/*.patch; do [[ -f "$p" ]] && n_patch=$((n_patch + 1)); done
if [[ "$n_patch" -gt 0 ]]; then
  pass "found $n_patch mutation patch(es)"
else
  fail "found mutation patches — none in $MUT_DIR, so nothing below checks anything"
  printf '\n%d failure(s)\n' "$fails"
  exit "$fails"
fi

# ── Every patch still applies, and names a real case ───────────────────────────
for p in "$MUT_DIR"/*.patch; do
  [[ -f "$p" ]] || continue
  id="$(basename "$p" .patch)"

  # Through mutate.sh, not a local `git apply`: the base/-layout resolution lives
  # there, and a second copy here would be right in this repo and quietly wrong
  # in the fork — reporting every patch stale, or worse, every patch fine.
  if bash "$MUTATE" check "$id" >/dev/null 2>&1; then
    pass "$id still applies"
  else
    fail "$id still applies — the code it breaks has changed; regenerate the patch"
  fi

  case_name="$(sed -n 's/^# case:[[:space:]]*//p' "$p" | head -1)"
  if [[ -n "$case_name" ]]; then
    pass "$id names the case it breaks"
  else
    fail "$id names the case it breaks — no '# case:' header"
  fi
  if [[ -n "$case_name" && -f "$CASES_DIR/$case_name.sh" ]]; then
    pass "$id → $case_name exists"
  else
    fail "$id → case '$case_name' does not exist in cases/"
  fi
  if sed -n 's/^# what:[[:space:]]*//p' "$p" | head -1 | grep -q .; then
    pass "$id says what it changes"
  else
    fail "$id says what it changes — no '# what:' header"
  fi
done

# ── Every launcher-tier case has a mutation. THE coverage assertion. ───────────
# Without this the file only audits the mutations that happen to exist, and a
# case added with none would be invisible to it.
for c in "$CASES_DIR"/*.sh; do
  [[ -f "$c" ]] || continue
  tags="$(sed -n 's/^#[[:space:]]*tags:[[:space:]]*//p' "$c" | head -1)"
  case " $tags " in
    *" mounts "*|*" groups "*|*" volumes "*|*" packages "*) : ;;
    *) continue ;;
  esac
  name="$(basename "$c" .sh)"
  if grep -lqs "^# case:[[:space:]]*$name\$" "$MUT_DIR"/*.patch 2>/dev/null; then
    pass "$name has a known-bad mutation"
  else
    fail "$name has a known-bad mutation — add one under tests/integration/mutations/"
    printf '       A case never observed failing is not a regression test.\n'
  fi
done

# ── mutate.sh's own guard rails ────────────────────────────────────────────────
out="$(bash "$MUTATE" list 2>&1)"
if grep -q 'BREAKS CASE' <<< "$out" && [[ "$(grep -c . <<< "$out")" -gt "$n_patch" ]]; then
  pass "mutate.sh list reports every mutation"
else
  fail "mutate.sh list reports every mutation"
fi

out="$(bash "$MUTATE" apply no-such-mutation 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'no such mutation' <<< "$out"; then
  pass "mutate.sh refuses an unknown mutation id"
else
  fail "mutate.sh refuses an unknown mutation id (rc=$rc)"
fi

out="$(bash "$MUTATE" apply 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "mutate.sh refuses apply with no id"
else
  fail "mutate.sh refuses apply with no id"
fi

# `verify` must be able to FAIL. Point it at a mutations dir holding a patch
# that cannot apply, and require a non-zero exit — otherwise "all patches apply"
# above is being reported by a command incapable of saying otherwise.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tests/integration/mutations"
cp "$MUTATE" "$tmp/tests/integration/mutate.sh"
cat > "$tmp/tests/integration/mutations/bogus.patch" <<'EOF'
# case: 400-ro-repo-not-writable
# what: a patch against a line that does not exist
diff --git a/sandbox.sh b/sandbox.sh
--- a/sandbox.sh
+++ b/sandbox.sh
@@ -1,3 +1,3 @@
 #!/usr/bin/env bash
-this line is not in sandbox.sh
+neither is this one
 set -euo pipefail
EOF
# Run it against the REAL repo so `git apply --check` has a tree to check
# against, but with the bogus patch dir.
out="$( cd "$REPO_DIR" && bash "$tmp/tests/integration/mutate.sh" verify 2>&1 )"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'STALE' <<< "$out"; then
  pass "mutate.sh verify FAILS on a stale patch (the check can fail)"
else
  fail "mutate.sh verify FAILS on a stale patch (rc=$rc) — it cannot detect staleness"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# ── Multi-apply ────────────────────────────────────────────────────────────────
# Batched demonstrations need several known-bad patches applied at once. The
# state file becomes a LIST, and revert must reverse in the opposite order —
# two patches touching the same file apply cleanly forwards and conflict
# backwards if reversed in the order they were applied.
out="$(bash "$MUTATE" apply 400-ro-suffix-dropped no-such-mutation 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'no such mutation' <<< "$out"; then
  pass "multi-apply rejects the whole batch when any id is unknown"
else
  fail "multi-apply rejects the whole batch when any id is unknown (rc=$rc)"
fi
if [[ ! -f "$MUT_DIR/.applied" ]]; then
  pass "a rejected batch applies nothing (no state file left behind)"
else
  fail "a rejected batch applies nothing — .applied exists after a refused batch"
  bash "$MUTATE" revert >/dev/null 2>&1
fi

grep -q 'apply <id>\.\.\.' "$MUTATE" || grep -q 'apply.*\[<id>' "$MUTATE" \
  && pass "usage documents multi-apply" \
  || fail "usage documents multi-apply"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
