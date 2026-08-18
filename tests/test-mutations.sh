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

  # A patch may declare MORE THAN ONE case, and 070-230-pid1-caps-fresh-exec
  # does: its damage is a single edit to tests/integration/lib.sh, which both
  # cases consume. Splitting that into two patches duplicated the diff body
  # verbatim, and two copies of one body drift.
  #
  # Every declared name is validated, not just the first. Reading `head -1`
  # here while the coverage assertion below greps for ANY matching `# case:`
  # line would let a second, misspelled name satisfy coverage without ever
  # being checked for existence — a patch could claim a case that does not
  # exist and report itself green.
  mapfile -t case_names < <(sed -n 's/^# case:[[:space:]]*//p' "$p")
  if [[ ${#case_names[@]} -gt 0 ]]; then
    pass "$id names the case it breaks"
  else
    fail "$id names the case it breaks — no '# case:' header"
  fi
  for cn in "${case_names[@]}"; do
    if [[ -f "$CASES_DIR/$cn.sh" ]]; then
      pass "$id → $cn exists"
    else
      fail "$id → $cn does not exist in cases/"
    fi
  done
  # Captured rather than `sed … | head -1 | grep -q .`: head exits after one
  # line, sed keeps reading into a closed pipe, and pipefail promotes sed's 141
  # over grep's success — failing this assertion for a patch that does say what
  # it changes. Same hazard as wf_has_step in tests/lib-layer-checks.sh.
  _what="$(sed -n 's/^# what:[[:space:]]*//p' "$p")"
  if [[ -n "${_what%%$'\n'*}" ]]; then
    pass "$id says what it changes"
  else
    fail "$id says what it changes — no '# what:' header"
  fi
done

# ── Every launcher- AND network-tier case has a mutation. THE coverage assertion.
# Without this the file only audits the mutations that happen to exist, and a
# case added with none would be invisible to it.
#
# `network-mode` was added late, in increment 5, and the reason is worth keeping:
# the network/security cases were believed covered because AGENTS.md said they
# "keep their fixture-based demonstrations under tests/integration/fixtures/".
# They did not. Only two cases (040, 060) have a fixture at all, NO case mounted
# either one — every reference to them in cases/ was a comment — and the actual
# demonstrations lived as prose in the increment-1 plan, ending with
# `git checkout -- tests/integration/cases/`. So the tier with every
# restricted-mode assertion in it (010 blocks-unlisted, 070 drops-capabilities,
# the self-heal pair) had no enforced demonstration of any kind, and a new case
# could ship with none while nothing reported it.
#
# Do not narrow this filter back to the launcher tags. The two fixtures remain
# under fixtures/ and are still not patches — they preserve code that no longer
# exists, so nothing could apply to them — but every network case now carries a
# patch like the launcher tier.
#
# EVERY case is classified — tier-covered, or explicitly exempt with a reason.
# The tag filter alone cannot protect itself: narrowing it back to the launcher
# tags makes 15 coverage assertions VANISH rather than fail, which is silent
# success, the shape this suite refuses everywhere. Requiring every case to land
# in one bucket or the other turns that narrowing into a failure, because the
# cases it stops checking then match no bucket at all.
#
# Same idiom as tests/layer-checks.conf's `setup` rows and falsify's
# `EXCLUDED:` — an exemption is allowed, an unexplained omission is not.
case_exempt() {  # $1=case basename → prints the reason, or nothing
  case "$1" in
    000-harness-selftest)
      printf 'the harness own smoke test: if it breaks, every other case is uninterpretable, so it has no meaningful known-bad configuration of its own' ;;
    300-allowlist-delivered)
      printf 'TRACKED GAP, not a clean exemption — see docs/superpowers/specs/2026-08-14-falsify-backlog.md F5. Its honest mutation breaks Dockerfile delivery, which needs an image REBUILD, so it cannot ride the --reuse-image path the other demonstrations use' ;;
  esac
}

for c in "$CASES_DIR"/*.sh; do
  [[ -f "$c" ]] || continue
  name="$(basename "$c" .sh)"
  tags="$(sed -n 's/^#[[:space:]]*tags:[[:space:]]*//p' "$c" | head -1)"
  case " $tags " in
    *" mounts "*|*" groups "*|*" volumes "*|*" packages "*|*" network-mode "*) : ;;
    *)
      reason="$(case_exempt "$name")"
      if [[ -n "$reason" ]]; then
        pass "$name is exempt from the mutation rule ($reason)"
      else
        fail "$name is neither tier-covered nor exempt — add a mutation, or an exemption with a reason in case_exempt()"
        printf '       A case in no bucket is a case nobody decided about.\n'
      fi
      continue ;;
  esac
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
tmp="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$tmp"' EXIT
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

# ── apply/revert state handling, driven in a THROWAWAY git repo ────────────────
# Everything below mutates a tree and inspects what is left behind, so it runs
# against a disposable repo with disposable patches — never this one. mutate.sh
# resolves its repo from its own location (the directory holding build.sh), so a
# copy of the script plus an empty build.sh is a complete, self-contained
# instance of it.
#
# The state file is the subject. A mutation is a deliberately WRONG production
# file; if .applied and the tree ever disagree, the next demonstration runs
# against a tree nobody described — which is how a "known-bad" demonstration
# silently becomes a demonstration of something else.
MT_REPO="$tmp/mutrepo"
MT_MUT="$MT_REPO/tests/integration/mutations"
MT_STATE="$MT_MUT/.applied"
mkdir -p "$MT_MUT"
cp "$MUTATE" "$MT_REPO/tests/integration/mutate.sh"
: > "$MT_REPO/build.sh"          # marks this as the engine dir, like the real repo
printf 'alpha\nbeta\ngamma\n' > "$MT_REPO/target.txt"
( cd "$MT_REPO" && git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1
  git add -A && git -c user.email=t@example -c user.name=t commit -qm init ) >/dev/null 2>&1

cat > "$MT_MUT/p-good.patch" <<'EOF'
# case: 400-ro-suffix-dropped
# what: flips beta to BETA
diff --git a/target.txt b/target.txt
--- a/target.txt
+++ b/target.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
EOF
# Deliberately unappliable: stands in for the real "the code it breaks has
# changed" case, which is the only thing that triggers a mid-batch rollback.
cat > "$MT_MUT/p-stale.patch" <<'EOF'
# case: 400-ro-suffix-dropped
# what: patches a line that does not exist
diff --git a/target.txt b/target.txt
--- a/target.txt
+++ b/target.txt
@@ -1,3 +1,3 @@
 alpha
-this line is not in target.txt
+neither is this one
 gamma
EOF

mt() {  # run the throwaway instance; $@ = mutate.sh args
  ( cd "$MT_REPO" && bash "$MT_REPO/tests/integration/mutate.sh" "$@" 2>&1 )
}
mt_clean() {  # tree back to committed state, no state file
  ( cd "$MT_REPO" && git checkout -- . >/dev/null 2>&1 ); rm -f "$MT_STATE"
}
mt_dirty() { ! ( cd "$MT_REPO" && git diff --quiet ); }

# Sanity: the fixture itself works, or every assertion below is vacuous.
out="$(mt apply p-good)"; rc=$?
if [[ "$rc" -eq 0 ]] && mt_dirty && [[ -f "$MT_STATE" ]]; then
  pass "fixture: applying a good patch mutates the tree and records it"
else
  fail "fixture: applying a good patch mutates the tree and records it (rc=$rc, out=$out)"
fi
out="$(mt revert)"; rc=$?
if [[ "$rc" -eq 0 ]] && ! mt_dirty && [[ ! -f "$MT_STATE" ]] && grep -q 'Reverted p-good' <<< "$out"; then
  pass "fixture: revert undoes it, says so, and clears the state file"
else
  fail "fixture: revert undoes it, says so, and clears the state file (rc=$rc, out=$out)"
fi
mt_clean

# ── A mid-batch rollback ACCOUNTS for what it undid ────────────────────────────
# The batch applies p-good, then p-stale fails and the rollback runs. It printed
# nothing at all, so a batch that half-applied and then unwound left no record
# of what had been touched — the reader could not tell an unwound tree from an
# untouched one without running git diff themselves.
out="$(mt apply p-good p-stale)"; rc=$?
[[ "$rc" -ne 0 ]] \
  && pass "a batch containing a stale patch fails" \
  || fail "a batch containing a stale patch fails (rc=$rc)"
grep -q 'Reverted p-good' <<< "$out" \
  && pass "the mid-batch rollback names what it undid" \
  || fail "the mid-batch rollback names what it undid (out: $out)"
# ...on STDOUT, the same stream cmd_revert uses for the identical line. This
# assertion captures stdout ALONE — the one above merges both streams and so
# cannot tell the two apart, which is how the rollback's copy sat on stderr
# while cmd_revert's sat on stdout. `mutate.sh apply a b c > log` then recorded
# a partial rollback in two places a reader has to reassemble. The ROLLBACK
# FAILED line is deliberately NOT included here: that one is an error and
# belongs on stderr.
# NOT through mt(): that helper folds stderr into stdout INSIDE its own
# subshell (`... 2>&1` at :228), so an outer 2>/dev/null suppresses nothing and
# this assertion could not fail — verified by putting the line back on stderr
# and watching it still pass. Call mutate.sh directly, capturing stdout alone.
out_stdout="$( ( cd "$MT_REPO" && bash "$MT_REPO/tests/integration/mutate.sh" apply p-good p-stale 2>/dev/null ) )"
grep -q 'Reverted p-good' <<< "$out_stdout" \
  && pass "the mid-batch rollback reports on stdout, like cmd_revert's identical line" \
  || fail "the mid-batch rollback reports on stdout (stdout alone was: $out_stdout)"
mt_clean
out="$(mt apply p-good p-stale)"; rc=$?
mt_dirty \
  && fail "a rolled-back batch leaves the tree mutated (out: $out)" \
  || pass "a successful rollback leaves the tree exactly as found"
[[ ! -f "$MT_STATE" ]] \
  && pass "a successful rollback removes the state file" \
  || fail "a successful rollback removes the state file"
mt_clean

# ── apply REFUSES a dirty tree ─────────────────────────────────────────────────
# mutate.sh's clean-tree gate is the guarantee that a mutation is the only
# difference in the tree, which is what makes `revert` a reversal rather than a
# guess. Nothing asserted it, and the consequence was measured, not supposed:
# mutating that line from
#     if ! ( cd "$GIT_ROOT" && git diff --quiet ); then
# to `||` disables the gate COMPLETELY — `cd` succeeds, `||` short-circuits, the
# negation is false, so a dirty tree sails straight through — and the whole
# hermetic suite stayed green. It was the first survivor the falsify pilot found,
# in the best-covered file in the corpus (123 assertions over 256 lines).
#
# Asserted through the throwaway instance, never the real repo: this test must be
# able to run while the developer's own tree is dirty.
printf 'delta\n' >> "$MT_REPO/target.txt"          # dirty, but NOT via a mutation
out="$(mt apply p-good)"; rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "apply refuses a dirty tree"
else
  fail "apply refuses a dirty tree (rc=$rc) — a mutation is no longer the only difference"
fi
if grep -q 'unstaged changes' <<< "$out"; then
  pass "apply says WHY it refused a dirty tree"
else
  fail "apply says WHY it refused a dirty tree (out: $out)"
fi
# And it must not have half-applied: refusing then mutating anyway would be worse
# than not refusing, because $STATE would not record it.
if [[ ! -f "$MT_STATE" ]]; then
  pass "a refused apply records no state"
else
  fail "a refused apply records no state (state: $(cat "$MT_STATE" 2>/dev/null))"
fi
( cd "$MT_REPO" && git checkout -- . >/dev/null 2>&1 )
mt_clean

# ── A rollback that FAILS is loud, and the state file keeps tracking ───────────
# The reversal used to run as `git_apply -R … 2>/dev/null` with its status
# discarded and $STATE deleted regardless, so a failed rollback was
# indistinguishable from a successful one: a mutated production file left in the
# tree, no message, and nothing recording that it was still applied. The next
# apply then started from a tree it believed was clean.
#
# A fake `git` that refuses REVERSE applies (and passes everything else through
# to the real one) is the only deterministic way in: git apply is atomic, so a
# patch that applied forward a moment ago always reverses cleanly.
MT_BIN="$tmp/mut-bin"; mkdir -p "$MT_BIN"
REAL_GIT="$(command -v git)"
cat > "$MT_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == "-R" ]] && { printf 'fake git: refusing to reverse (test fixture)\n' >&2; exit 1; }
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$MT_BIN/git"

out="$( cd "$MT_REPO" && PATH="$MT_BIN:$PATH" bash "$MT_REPO/tests/integration/mutate.sh" apply p-good p-stale 2>&1 )"; rc=$?
[[ "$rc" -ne 0 ]] \
  && pass "a batch whose rollback fails still exits non-zero" \
  || fail "a batch whose rollback fails still exits non-zero (rc=$rc)"
grep -q 'ROLLBACK FAILED for p-good' <<< "$out" \
  && pass "a failed rollback says so, naming the mutation still applied" \
  || fail "a failed rollback says so, naming the mutation still applied (out: $out)"
if [[ -f "$MT_STATE" ]] && grep -qx 'p-good' "$MT_STATE"; then
  pass "a failed rollback keeps the state file, still recording the applied mutation"
else
  fail "a failed rollback keeps the state file recording p-good (state: $(cat "$MT_STATE" 2>/dev/null || printf '<absent>'))"
fi
mt_dirty \
  && pass "the tree really is still mutated (so the state file above is the truth, not a guess)" \
  || fail "the tree really is still mutated — the fixture did not reproduce a failed rollback"
mt_clean

# ── revert distinguishes "undid it" from "it was already absent" ───────────────
# .applied is gitignored, so it survives a branch switch or a `git checkout --`
# — ordinary things to do between demonstrations. The recorded patch is then no
# longer in the tree, `git apply -R` fails, and revert used to exit 1 leaving
# .applied behind, which made the NEXT apply refuse ("still applied") against a
# pristine tree. That cost a wasted CI dispatch during increment 3.
out="$(mt apply p-good)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "fixture: could not apply p-good for the already-absent case (out: $out)"
( cd "$MT_REPO" && git checkout -- target.txt )    # stands in for the branch switch
out="$(mt revert)"; rc=$?
[[ "$rc" -eq 0 ]] \
  && pass "revert succeeds when the recorded patch is not in the tree" \
  || fail "revert succeeds when the recorded patch is not in the tree (rc=$rc, out: $out)"
grep -q 'Already absent: p-good' <<< "$out" \
  && pass "revert states 'already absent' rather than claiming it reverted something" \
  || fail "revert states 'already absent' rather than claiming it reverted something (out: $out)"
grep -q 'Reverted p-good' <<< "$out" \
  && fail "revert must not report 'Reverted' for a patch it did not undo (out: $out)" \
  || pass "revert does not report 'Reverted' for a patch it did not undo"
[[ ! -f "$MT_STATE" ]] \
  && pass "an already-absent revert clears the state file" \
  || fail "an already-absent revert clears the state file"
# The consequence that actually cost the dispatch: the next demonstration runs.
out="$(mt apply p-good)"; rc=$?
[[ "$rc" -eq 0 ]] \
  && pass "the next apply is not blocked by the cleared state" \
  || fail "the next apply is not blocked by the cleared state (rc=$rc, out: $out)"
mt_clean

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
