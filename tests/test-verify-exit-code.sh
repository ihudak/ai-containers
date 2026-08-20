#!/usr/bin/env bash
# Hermetic tests for verify-on-host.sh's EXIT STATUS.
#
# Why this file exists, precisely: verify-on-host.sh was written as a
# human-read diagnostic and later wired into nightly CI as a gate
# (`PHASES="1 2 3" bash ./verify-on-host.sh`). It recorded failures by printing
# "BUILD FAILED" and then exited 0 — from its first day in CI, in both repos, the
# packages job passed unconditionally and could not have done otherwise. Nobody
# knew whether those phases were green, because the job was structurally
# incapable of saying they were not.
#
# That history is why the failure ledger (phase_fail/FAILED_PHASES/RESULT:/exit 1)
# exists and why this file exists to hold the line on it. The phases that history
# refers to (1, 2, 3) are gone for good — Increment 3 moved what they checked
# into the packages tier of the runtime integration corpus, and those numbers
# must never be reused (see verify-on-host.sh's own header). Increment 4 added
# phases 5 (the hermetic suite + schema gate) and 7 (lint, shellcheck gating), so
# this file now tests Phase 4, Phase 5, Phase 7 and the verdict mechanism itself
# — including, again, whether one failing phase can hide another, which phases 5
# and 7 make possible to demonstrate again (see the dedicated block below).
#
# Everything here is fake: a stub repo, a stub `docker`, a stub `shellcheck`, and
# stubs for tests/integration/run.sh, tests/run-all.sh, check-sandbox-version.sh
# and tests/bash-dialect-lint.sh. No daemon, no image, no network — none of the
# stubs literally executes the command it stands in for; each is a canned exit
# code so the pass/fail PATH through verify-on-host.sh is what gets exercised,
# not a real build or a real container.
#
# The last test is the load-bearing one. It strips the verdict block back out and
# requires the SAME failing scenario to exit 0, which is the only way to know the
# tests above are discriminating rather than agreeing with a script that cannot
# fail. Without it this file would have passed against the broken original.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like run.sh, lib.sh and the script under test: upstream keeps
# the engine beside tests/, mgd-ai-containers keeps it in base/. One copy of this
# file serves both, which is the property that lets the two stay byte-identical.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

[[ -f "$VERIFY" ]] || { fail "verify-on-host.sh not found at $VERIFY"; exit 1; }
bash -n "$VERIFY" && pass "verify-on-host.sh bash -n" || fail "verify-on-host.sh bash -n"

# ── Static checks: the phase selection wiring ───────────────────────────────────
# The default selection must name every phase this script has. A local layer
# nobody selects is not a local layer — which is why Phase 6 joined the default
# the moment it existed rather than being opt-in.
#
# Both literals are pinned, and that is the point: 6 was RESERVED and kept out
# of VALID_PHASES so that naming it early failed loudly. Adding the phase had to
# fail here first, and it did — these two assertions are the ones that caught it.
grep -qE 'PHASES="\$\{PHASES:-4 5 6 7\}"' "$VERIFY" \
  && pass "PHASES defaults to every phase (4 5 6 7)" \
  || fail "PHASES defaults to every phase (4 5 6 7)"
grep -qE '^VALID_PHASES="0 4 5 6 7"' "$VERIFY" \
  && pass "VALID_PHASES names 0 4 5 6 7" || fail "VALID_PHASES names 0 4 5 6 7"

# Every phase must record through phase_fail — the founding defect was a phase
# that failed while the script exited 0.
for p in 5 7; do
  if awk -v p="$p" '$0 ~ "PHASE "p" —" {g=1} g && /phase_fail '"$p"'/ {found=1} END{exit !found}' "$VERIFY"; then
    pass "phase $p records through phase_fail"
  else
    fail "phase $p records through phase_fail — a failure there would exit 0"
  fi
done

# ── Shared stub-repo machinery ───────────────────────────────────────────────
# tests/lib-verify-repo.sh builds the stub docker/shellcheck binaries and the
# mk_repo()/run_verify() functions used by every test below. It is also used
# by tests/test-layer-containment.sh's effect-based local-layer containment
# check (Task 6 fix round 1) — one shared copy of the stub repo, not two
# independently-maintained ones. That file's header documents the WITNESS_LOG
# contract added for that use; nothing below in THIS file reads WITNESS_LOG,
# but every stub still writes to it as a side effect.
# shellcheck disable=SC2034  # consumed by lib-layer-checks.sh, which reads it after this file sources it
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"
# shellcheck source=lib-verify-repo.sh
source "$REPO_DIR/tests/lib-verify-repo.sh"

expect_rc() {  # $1=label $2=expected $3=actual
  if [[ "$3" == "$2" ]]; then
    pass "$1"
  else
    fail "$1 — expected exit $2, got $3"
    tail -12 "$TMP/out.log" | sed 's/^/       /'
  fi
}

# ── A phase that fails must make the script fail ───────────────────────────────
r="$(CORPUS_RC=1 mk_repo 0)"
expect_rc "phase 4: a failing corpus exits non-zero" 1 "$(run_verify "$r" 4)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "phase 4: verdict line says FAILED" \
  || fail "phase 4: verdict line says FAILED"
grep -q 'PHASE 4 FAILED' "$TMP/out.log" \
  && pass "phase 4: names the phase that failed" \
  || fail "phase 4: names the phase that failed"

# ── A phase that passes must NOT make it fail ──────────────────────────────────
# The other half of the property. A script hard-wired to exit 1 would satisfy
# every assertion above and be just as useless.
r="$(mk_repo 0)"
expect_rc "phase 4: a passing corpus exits 0" 0 "$(run_verify "$r" 4)"
grep -q 'RESULT: PASSED' "$TMP/out.log" \
  && pass "phase 4: verdict line says PASSED" \
  || fail "phase 4: verdict line says PASSED"

# ── A failure is recorded and reported by the verdict, not just by exiting ─────
# The ledger existed to report every failure instead of stopping at the first.
# HISTORICAL NOTE, corrected: this comment used to say Phase 4 was "the only
# selectable, ledger-tracked phase left in the script", so the cross-phase "one
# broken phase never hides another" property — the ledger's FOUNDING purpose —
# had no second phase left to demonstrate it against, and this block could only
# re-check the single-phase mechanism (a recorded failure reaches the summary
# with its phase number). That was true only because Increment 3 had removed
# phases 1-3 and left just one. Increment 4 added phases 5 and 7, so the
# cross-phase demonstration is possible again — restored in the dedicated block
# immediately below, not folded in here, so each keeps testing one thing.
r="$(CORPUS_RC=1 mk_repo 0)"
rc="$(run_verify "$r" 4)"
expect_rc "phase 4 fails: still exits 1" 1 "$rc"
n="$(grep -c '^\[host-verify\]   phase 4:' "$TMP/out.log")"
if [[ "$n" -eq 1 ]]; then
  pass "the failure reaches the summary with its phase number"
else
  fail "the failure reaches the summary with its phase number — got $n"
  sed -n '/RESULT:/,$p' "$TMP/out.log" | sed 's/^/       /'
fi

# ── RESTORED: two phases failing in the same run must BOTH be named ────────────
# This is the demonstration the comment above used to say was lost. Phase 5
# (via SUITE_RC) and Phase 7 (via DIALECT_RC) are made to fail independently,
# together, so the founding property — one broken phase does not hide another —
# has a real cross-phase case again, not just the single-phase mechanism check
# above. PHASES="5 7" deliberately excludes Phase 4, so CORPUS_RC is irrelevant
# here and only these two are in play.
r="$(SUITE_RC=1 DIALECT_RC=1 mk_repo 0)"
rc="$(run_verify "$r" "5 7")"
expect_rc "phase 5 and phase 7 can fail in the same run" 1 "$rc"
grep -q 'PHASE 5 FAILED' "$TMP/out.log" \
  && pass "both-failing run: names phase 5" \
  || fail "both-failing run: names phase 5"
grep -q 'PHASE 7 FAILED' "$TMP/out.log" \
  && pass "both-failing run: names phase 7" \
  || fail "both-failing run: names phase 7"
n5="$(grep -c '^\[host-verify\]   phase 5:' "$TMP/out.log")"
n7="$(grep -c '^\[host-verify\]   phase 7:' "$TMP/out.log")"
if [[ "$n5" -eq 1 && "$n7" -eq 1 ]]; then
  pass "RESULT: FAILED summary names BOTH phase 5 and phase 7, not just the first"
else
  fail "RESULT: FAILED summary names BOTH phase 5 and phase 7 — got phase5=$n5 phase7=$n7"
  sed -n '/RESULT:/,$p' "$TMP/out.log" | sed 's/^/       /'
fi
grep -q 'RESULT: FAILED — 2 phase(s)' "$TMP/out.log" \
  && pass "verdict counts exactly 2 failed phases, not 1" \
  || fail "verdict counts exactly 2 failed phases, not 1"

# ── shellcheck missing from PATH must fail the phase, not silently skip it ─────
# Phase 7's shellcheck sub-check is gated on `command -v shellcheck`. Bypasses
# run_verify()'s PATH (which always prepends the stub shellcheck) with a
# PATH built from scratch, so this exercises the ELSE branch none of the
# tests above ever reach.
#
# CAUGHT BUG, second version: an earlier version of this block prepended a
# no-shellcheck dir but left the rest of the inherited $PATH attached, so a
# real shellcheck later in $PATH was still reachable — passed the exit-code
# assertion but failed the message assertion. The FIX for that (filtering out
# every PATH component that resolves a real shellcheck) was itself wrong in a
# way only CI exposed: GitHub Actions' ubuntu-latest runner ships shellcheck
# pre-installed in /usr/bin, the SAME directory as bash/git/coreutils, so
# filtering out "any dir containing shellcheck" also filtered out bash, git,
# sed and everything else those directories provide. With PATH left holding
# only the docker stub's directory, `docker`'s own `#!/usr/bin/env bash`
# shebang could not resolve "bash" via env's PATH lookup, and the whole run
# died with exit 127 ("bash: command not found") — a PATH self-inflicted
# wound, not a signal about shellcheck, and it never reproduced on a host
# (this repo's dev machines, macOS) where shellcheck lives in its own
# directory (e.g. Homebrew's, or a lone ~/.local/bin) separate from
# coreutils. Reproduced locally by copying git/bash/sed/shellcheck into one
# shared directory and confirming the same exit 127.
#
# The fix: stop filtering the INHERITED PATH by directory at all — build a
# hermetic PATH from scratch, symlinking in exactly the external tools
# verify-on-host.sh's phases 0 and 7 need (resolved via `command -v` against
# whatever PATH this test itself is running under), and never linking the
# checker binary in. This is correct regardless of whether the host has a
# real shellcheck, and regardless of which directory it lives in: shellcheck
# is excluded by simply never being one of the tools copied in, not by
# guessing at and excising directories.
mkdir -p "$TMP/bin-no-shellcheck" "$TMP/hermetic-tools"
cp "$TMP/bin/docker" "$TMP/bin-no-shellcheck/docker"
for _tool in bash git sed grep awk cut tr head wc uname xargs printf cat mkdir rm chmod mktemp; do
  _real_tool_path="$(command -v "$_tool" 2>/dev/null)" || continue
  ln -sf "$_real_tool_path" "$TMP/hermetic-tools/$_tool"
done
no_sc_path="$TMP/bin-no-shellcheck:$TMP/hermetic-tools"
r="$(mk_repo 0)"
PATH="$no_sc_path" REPO="$r" PHASES=7 bash "$r/verify-on-host.sh" \
  > "$TMP/out.log" 2>&1
expect_rc "shellcheck missing from PATH fails phase 7, not a silent skip" 1 "$?"
grep -q 'shellcheck not installed' "$TMP/out.log" \
  && pass "names the reason: shellcheck not installed" \
  || fail "names the reason: shellcheck not installed"

# ── Phase 5's schema gate must fail loudly with no usable BASE_REF ─────────────
# The gate's own default (BASE_REF=HEAD) is a silent no-op once a change is
# committed: the working tree and HEAD are then identical, so nothing looks
# removed. verify-on-host.sh must resolve a REAL base (merge-base against
# origin/main, else HEAD^) before invoking the gate, and phase_fail loudly if
# NEITHER resolves — handing the gate an unusable ref instead would not fail
# either: check-sandbox-version.sh itself treats an unresolvable ref as "no
# sandbox.conf at that ref, nothing to compare" and exits 0, which is the
# exact silent pass this relocates the risk of, one level down.
#
# mk_repo's second argument (0) skips stamping refs/remotes/origin/main, and
# the stub repo's single "stub" commit has no parent, so HEAD^ does not
# resolve either — the "no usable base at all" case.
r="$(mk_repo 0 0)"
: > "$WITNESS_LOG"
rc="$(run_verify "$r" 5)"
expect_rc "phase 5 fails when the schema gate has no usable BASE_REF" 1 "$rc"
grep -q 'no usable BASE_REF' "$TMP/out.log" \
  && pass "names the reason: no usable BASE_REF" \
  || fail "names the reason: no usable BASE_REF"
grep -q 'STUB:check-sandbox-version\.sh' "$WITNESS_LOG" \
  && fail "check-sandbox-version.sh ran despite no usable BASE_REF — should have been skipped, not handed an unusable ref" \
  || pass "check-sandbox-version.sh is never invoked without a usable BASE_REF"

# The other half: mk_repo's DEFAULT repo models a normal checkout sitting on
# main — origin/main stamped at HEAD, and a parent commit behind it. The gate
# still genuinely runs and phase 5 still passes; this file must not have become
# impossible to pass.
#
# AND IT MUST NOT RUN WITH BASE_REF=HEAD, which is the assertion this block was
# missing and the reason the defect survived. Until 2026-08-19 this said "the
# origin/main ref stamped at HEAD DOES have a usable base" — it does not. On
# main, merge-base(HEAD, origin/main) IS HEAD, so the gate was handed HEAD,
# compared a commit against an identical working tree, found nothing removed and
# printed OK. Running and checking are different things, and only "STUB:…" was
# ever asserted, so the test agreed the whole time. Observed live on a host run
# before it was fixed: `schema gate diffing sandbox.conf against aeb1421…` with
# aeb1421 == HEAD. Backlog F44.
r="$(mk_repo 0)"
: > "$WITNESS_LOG"
rc="$(run_verify "$r" 5)"
expect_rc "phase 5 passes when a usable BASE_REF exists (origin/main)" 0 "$rc"
grep -q 'STUB:check-sandbox-version\.sh' "$WITNESS_LOG" \
  && pass "schema gate genuinely ran with a usable BASE_REF" \
  || fail "schema gate genuinely ran with a usable BASE_REF"

gate_head="$(git -C "$r" rev-parse HEAD 2>/dev/null || true)"
gate_parent="$(git -C "$r" rev-parse HEAD^ 2>/dev/null || true)"
gate_ref="$(sed -n 's/^STUB-BASEREF:check-sandbox-version\.sh //p' "$WITNESS_LOG" | tail -1)"
# The fixture's own premise first, so the two assertions below cannot pass by
# both values being empty.
if [[ -n "$gate_head" && -n "$gate_parent" && "$gate_head" != "$gate_parent" ]]; then
  pass "the stub repo has a parent commit distinct from HEAD (the fixture can tell the two apart)"
else
  fail "the stub repo has a parent commit distinct from HEAD — head='$gate_head' parent='$gate_parent'; the BASE_REF assertions below would prove nothing"
fi
if [[ -n "$gate_ref" ]]; then
  pass "the schema gate recorded the BASE_REF it was handed ($gate_ref)"
else
  fail "the schema gate recorded the BASE_REF it was handed — no STUB-BASEREF line, so the assertion below cannot fail"
fi
if [[ "$gate_ref" != "$gate_head" ]]; then
  pass "the schema gate is never handed BASE_REF=HEAD (it would compare a commit to itself)"
else
  fail "the schema gate was handed BASE_REF=HEAD ($gate_ref) — it compared HEAD's sandbox.conf against an identical working tree and reported OK, verifying nothing"
fi
if [[ "$gate_ref" == "$gate_parent" ]]; then
  pass "the schema gate fell back to HEAD^ when origin/main is HEAD"
else
  fail "the schema gate fell back to HEAD^ when origin/main is HEAD — want '$gate_parent', got '$gate_ref'"
fi

# ── mk_repo's origin/main stamp and parent commit, asserted directly ─────────
# add_origin=1 must stamp refs/remotes/origin/main AT HEAD and leave a parent
# commit; add_origin=0 must do neither. Both halves of both, because each guard
# is a single condition and one half alone leaves its inversion unobserved.
#
# This exists because of a regression the fixture itself caused. mk_repo's
# add_origin=1 repo gained a SECOND commit (backlog F44, so the fixture can tell
# `origin/main == HEAD` apart from `no base at all`), and that quietly removed
# the only thing that had been killing the update-ref line's mutants. Before,
# inverting that line left the stub with neither origin/main nor a resolvable
# HEAD^, so Phase 5 failed loudly and the block above saw it. After, HEAD^
# resolves, the schema gate falls back to it and passes, and all three mutants
# of that line SURVIVED — measured: tests/lib-verify-repo.sh went from 49/49 to
# 55 mutants with 3 survivors, and the ledger ratchet failed on them.
#
# The general lesson, which is why this is a comment and not just four lines: a
# fixture made richer to support a NEW assertion can take away what an OLD
# assertion was resting on, and nothing about that change looks like a coverage
# change. The tier is what noticed. So the contract is asserted here directly,
# not left to depend on which fallback some consumer happens to reach for.
r="$(mk_repo 0)"
# The premise, first and strictly. An empty $r makes every `git -C "$r"` below
# operate on the CURRENT directory — the real repository — which has an
# origin/main at HEAD and a parent commit, so all four assertions would pass
# while measuring nothing. That is not hypothetical: it is what this block did
# on its first draft, in a file where mk_repo was not in scope.
if [[ -n "$r" && "$r" == "$TMP"/* && -d "$r/.git" ]]; then
  pass "the stub repo is a real git repo under \$TMP (not the working repository)"
else
  fail "the stub repo is a real git repo under \$TMP — got '$r'; every assertion below would read the REAL repository and pass vacuously"
fi
origin_sha="$(git -C "$r" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)"
head_sha="$(git -C "$r" rev-parse --verify -q HEAD 2>/dev/null || true)"
parent_sha="$(git -C "$r" rev-parse --verify -q HEAD^ 2>/dev/null || true)"
if [[ -n "$origin_sha" && "$origin_sha" == "$head_sha" ]]; then
  pass "mk_repo add_origin=1 stamps refs/remotes/origin/main at HEAD"
else
  fail "mk_repo add_origin=1 stamps refs/remotes/origin/main at HEAD — origin='$origin_sha' head='$head_sha'"
fi
if [[ -n "$parent_sha" && "$parent_sha" != "$head_sha" ]]; then
  pass "mk_repo add_origin=1 leaves a parent commit, so HEAD^ resolves"
else
  fail "mk_repo add_origin=1 leaves a parent commit, so HEAD^ resolves — parent='$parent_sha' head='$head_sha'"
fi

r="$(mk_repo 0 0)"
if [[ -n "$r" && "$r" == "$TMP"/* && -d "$r/.git" ]]; then
  pass "the no-base stub repo is a real git repo under \$TMP"
else
  fail "the no-base stub repo is a real git repo under \$TMP — got '$r'"
fi
origin_sha="$(git -C "$r" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)"
parent_sha="$(git -C "$r" rev-parse --verify -q HEAD^ 2>/dev/null || true)"
if [[ -z "$origin_sha" ]]; then
  pass "mk_repo add_origin=0 stamps no origin/main"
else
  fail "mk_repo add_origin=0 stamps no origin/main — got '$origin_sha', so the no-base case is not what it claims to be"
fi
if [[ -z "$parent_sha" ]]; then
  pass "mk_repo add_origin=0 leaves a root commit, so HEAD^ does not resolve"
else
  fail "mk_repo add_origin=0 leaves a root commit, so HEAD^ does not resolve — got '$parent_sha'; the 'no usable BASE_REF' case would silently acquire one"
fi

# ── A stale PHASES selection must fail loudly, not verify nothing and exit 0 ───
# The founding defect of this whole file, reachable now through phase SELECTION
# instead of phase REPORTING: PHASES="1 2 3" names only phases this script no
# longer has (they moved into the packages tier in Increment 3). want_phase()
# is a bare substring match with no validation, so nothing matched, nothing
# called phase_fail, and the script declared success having run zero checks —
# exactly what the failure ledger above exists to prevent. The string is not
# hypothetical: `PHASES="1 2 3" bash ./verify-on-host.sh` was the literal
# command in nightly.yml's packages job, in AGENTS.md, and in every note anyone
# wrote about this script for two increments. It survives in muscle memory and
# in the sibling repo's checkouts long after the phases themselves are gone,
# which is why the selection must reject it rather than quietly match nothing.
# This guard must SURVIVE the addition of phases 5 and 7 — VALID_PHASES grew to
# "0 4 5 7", and 1/2/3 must still be rejected, not accidentally re-admitted.
r="$(mk_repo 0)"
expect_rc "a stale PHASES=1 selection fails loudly, not exits 0" 1 "$(run_verify "$r" 1)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=1: verdict line says FAILED" \
  || fail "PHASES=1: verdict line says FAILED"

r="$(mk_repo 0)"
expect_rc "a stale PHASES=\"1 2 3\" selection still fails after 5 and 7 exist" 1 \
  "$(run_verify "$r" "1 2 3")"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=\"1 2 3\": verdict line says FAILED" \
  || fail "PHASES=\"1 2 3\": verdict line says FAILED"

# The empty case is NOT affected — ${PHASES:-4 5 7} must still default cleanly
# to every real phase this script has, with no phase_fail firing for a
# selection nobody made. This is also the one test that exercises ALL of
# phases 4, 5 and 7 (and every one of their sub-checks) passing together in a
# single hermetic run, since mk_repo's stubs all default their *_RC to 0.
r="$(mk_repo 0)"
expect_rc "an empty/unset PHASES still defaults to 4 5 7 and passes" 0 "$(run_verify "$r" "")"
grep -q 'RESULT: PASSED' "$TMP/out.log" \
  && pass "PHASES=\"\": verdict line says PASSED (default still works)" \
  || fail "PHASES=\"\": verdict line says PASSED (default still works)"

# ── THE DEMONSTRATION ──────────────────────────────────────────────────────────
# Strip the verdict block and require the failing scenario to exit 0 again. That
# reproduces the exact defect this file was written for, and proves the
# assertions above discriminate. Truncation at a marker, not a sed substitution:
# a marker that has moved is a loud failure here, whereas a sed that matches
# nothing would leave the script intact and report a clean pass — the decorative
# check this project keeps finding.
r="$(CORPUS_RC=1 mk_repo 0)"
marker='# ── Verdict ─'
if ! grep -qF "$marker" "$r/verify-on-host.sh"; then
  fail "the verdict marker moved — this demonstration verified NOTHING; update it"
else
  before="$(wc -l < "$r/verify-on-host.sh")"
  awk -v m="$marker" 'index($0, m) { exit } { print }' \
    "$r/verify-on-host.sh" > "$r/neutered.sh"
  after="$(wc -l < "$r/neutered.sh")"
  if [[ "$after" -ge "$before" ]]; then
    fail "truncation removed nothing ($before → $after lines) — nothing was demonstrated"
  else
    pass "verdict block located and stripped ($before → $after lines)"
    PATH="$TMP/bin:$PATH" REPO="$r" PHASES=4 bash "$r/neutered.sh" >/dev/null 2>&1
    if [[ "$?" -eq 0 ]]; then
      pass "without the verdict block the same failing run exits 0 (the original bug)"
    else
      fail "without the verdict block the run still fails — something ELSE is setting"
      printf '       the exit code, so the tests above are not measuring the verdict.\n'
    fi
  fi
fi

# ── Phase 7's "parsed no files" branch, exercised ─────────────────────────────
# This branch existed unexercised: no fixture ever produced an empty
# `git ls-files '*.sh'`, so replacing its phase_fail with a no-op changed
# nothing. MK_REPO_UNTRACK_SH drops *.sh from the index while leaving the files
# on disk, so every existence check still passes and this is the ONLY thing that
# fails — which is what makes both assertions below meaningful.
r="$(MK_REPO_UNTRACK_SH=1 mk_repo 0)"
rc="$(run_verify "$r" "7")"
[[ "$rc" != "0" ]] \
  && pass "a run whose bash -n matched no files exits non-zero" \
  || fail "a run whose bash -n matched no files exited 0 — it verified nothing and said so with a zero"
grep -q "bash -n parsed no files" "$TMP/out.log" \
  && pass "the empty-pathspec run names 'bash -n parsed no files'" \
  || fail "the empty-pathspec run did not report 'bash -n parsed no files' (got: $(tail -3 "$TMP/out.log" | tr '\n' ' '))"

# ── The floor-suite container's exit code must reach the verdict ──────────────
# The registry's floor-suite row declares WHICH env var carries that exit code;
# read it from there rather than hardcoding the name, so a rename in
# lib-verify-repo.sh's docker stub makes this assertion red at its cause
# instead of leaving an inert column nobody reads. That row's stub_kind is
# `none` — the docker stub is Phase-0 infrastructure the library writes by hand
# rather than something the registry loop builds — so this is the only thing
# that ties the two together.
floor_rc_var="$(lc_rows check | awk -F'|' '$1 == "floor-suite" { print $6 }')"
if [[ -z "$floor_rc_var" || "$floor_rc_var" == "-" ]]; then
  fail "the registry's floor-suite row names an rc_var"
else
  pass "the registry's floor-suite row names an rc_var ($floor_rc_var)"
  r="$(mk_repo 0)"
  rc="$( export "${floor_rc_var}=1"; run_verify "$r" 5 )"
  expect_rc "phase 5: a failing floor-suite container exits non-zero" 1 "$rc"
  grep -q 'hermetic suite at the declared floor exited 1' "$TMP/out.log" \
    && pass "phase 5: the verdict names the floor suite as what failed" \
    || fail "phase 5: the verdict names the floor suite as what failed"
fi

# ── A FAILED CORPUS MUST SAY WHY, NOT SHOW THE LAST TEN PROGRESS NOTES ────────
# run.sh has two stderr channels and they are not equal: `falsify:` is routine
# progress (one note per timed-out mutant — a loaded machine emits dozens) and
# `ERROR:` is the reason it gave up. Phase 6 used to match both in one grep and
# `tail -10` the result, so on any run with ten or more timeouts the cause was
# pushed off the end and the operator was told only "the corpus did not
# complete". Measured on macOS, 2026-08-17, which is why this assertion exists.
#
# Demonstrated failing by restoring that form:
#   grep -E '^(ERROR|falsify):' "$fl_run" | sed 's/^/  /' | tail -10
# with which the ERROR line below is absent from the output and this fails.
r="$(mk_repo 0)"
cat > "$r/tests/falsify/run.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ERROR: the pristine oracle is not green — refusing to measure\n'
i=0; while [[ "$i" -lt 20 ]]; do printf 'falsify: TIMEOUT after 120s: mutant-%s\n' "$i"; i=$((i+1)); done
exit 1
STUB
rc="$(run_verify "$r" 6)"
expect_rc "phase 6: a corpus that does not complete exits non-zero" 1 "$rc"
grep -q 'refusing to measure' "$TMP/out.log" \
  && pass "phase 6: a failed corpus surfaces run.sh's ERROR line, not just its notes" \
  || fail "phase 6: a failed corpus surfaces run.sh's ERROR line, not just its notes (got: $(grep -c '^.*falsify: TIMEOUT' "$TMP/out.log") note line(s), no ERROR)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
