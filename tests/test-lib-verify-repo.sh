#!/usr/bin/env bash
# tests/test-lib-verify-repo.sh — the first test of tests/lib-verify-repo.sh
# itself.
#
# That library has five unrecoverable conditions, and until this file none of
# them had ever been seen failing — five unfalsified guards inside the one file
# whose entire subject is guards that cannot fail.
#
# Every case here asserts by EFFECT: it writes a small harness script, runs it,
# and reads the harness's exit code and stdout. Each NEGATIVE case asserts that
# the harness exited non-zero with that guard's own message AND that a sentinel
# line placed AFTER the `source` never printed; the two positive controls assert
# the exact opposite — rc=0 and the post-`source` sentinels all present.
# Inspecting the library's source text would prove only that an `exit` is
# written somewhere in it, not that execution actually stopped — and "the string
# is present" is the exact false negative this repo's suite exists to close.
#
# The two positive controls are load-bearing, not padding: without them a
# library hard-wired to exit 1 unconditionally would satisfy every negative
# case in this file. The first proves a GOOD registry sources cleanly and
# continues; the second proves the bare, UNGUARDED `r="$(mk_repo 0)"` form —
# the way all 13 real call sites now read, with no `[[ -n "$r" ]] ||` guard
# after it — yields a usable repo and continues too. (The two `fixture: …`
# assertions further down are neither: they check this file's own doctored
# `.conf` inputs, not the library under test.)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like the rest of the suite: upstream keeps the engine beside
# tests/, mgd-ai-containers keeps it in base/. One copy of this file serves both.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
REAL_CONF="$REPO_DIR/tests/layer-checks.conf"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

for f in "$VERIFY" "$REAL_CONF" "$REPO_DIR/tests/lib-verify-repo.sh" \
         "$REPO_DIR/tests/lib-layer-checks.sh"; do
  [[ -f "$f" ]] || { fail "missing prerequisite: $f"; exit 1; }
done

hn=0
# Write a harness that sources the two libraries and then prints sentinels.
# $1 = LAYER_CHECKS_CONF to use
# $2 = "skip-lc" to deliberately NOT source lib-layer-checks.sh
# $3 = "no-tmp"  to deliberately leave TMP unset
# $4 = extra body appended after the source (may be empty)
# $5 = VERIFY override — a path used in place of the real $VERIFY; empty/absent
#      uses the real one. Exists to exercise the source-time -f "$VERIFY"
#      check with a path that does not exist (task-1-review.md finding 2).
# $6 = ENGINE_DIR override — same idea for the third clause of that same
#      contract check, -f "$ENGINE_DIR/bash-floor.sh" (final-review.md
#      finding 1).
mk_harness() {
  hn=$((hn + 1))
  local h="$TMP/harness-$hn.sh"
  local verify_val="${5:-$VERIFY}"
  local engine_val="${6:-$ENGINE_DIR}"
  cat > "$h" <<EOF
#!/usr/bin/env bash
set -uo pipefail
VERIFY=$(printf '%q' "$verify_val")
ENGINE_DIR=$(printf '%q' "$engine_val")
LAYER_CHECKS_CONF=$(printf '%q' "$1")
EOF
  # The library's contract check reads TMP; the "no-tmp" mode leaves it unset.
  # Quoted heredoc: $TMP here belongs to the harness at run time, not to us.
  [[ "$3" == "no-tmp" ]] || cat >> "$h" <<'EOF'
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
EOF
  [[ "$2" == "skip-lc" ]] || printf 'source %q\n' "$REPO_DIR/tests/lib-layer-checks.sh" >> "$h"
  printf 'source %q\n' "$REPO_DIR/tests/lib-verify-repo.sh" >> "$h"
  printf 'echo SENTINEL-SOURCED\n' >> "$h"
  printf '%s\n' "$4" >> "$h"
  chmod +x "$h"
  printf '%s' "$h"
}

# Run a harness. Prints its exit code; output lands in $TMP/harness.out.
# $2, when non-empty, is prepended to PATH (used to plant a broken `git`).
run_harness() {
  local extra_path="${2:-}"
  PATH="${extra_path:+$extra_path:}$PATH" bash "$1" > "$TMP/harness.out" 2>&1
  printf '%s' "$?"
}

# $1=label $2=harness rc $3=ERE that must match a line in $TMP/harness.out —
# the SPECIFIC guard's own stderr message (read from tests/lib-verify-repo.sh
# itself, never retyped from memory). Without this third check, any guard
# firing for ANY reason would satisfy a case named for a DIFFERENT guard — a
# future sixth source-time check added to the library would let an existing
# case here keep passing after the guard it actually names was deleted.
#
# Asserts the harness stopped at the source line, for the reason this case
# claims: rc non-zero WITH the named guard's message present is one condition
# (a match failure here means either the guard never fired, or a DIFFERENT
# guard fired instead); no SENTINEL-SOURCED is the second, independent
# condition — a library that returned instead of exiting would let the
# sourcing script run on and print it while some later, unrelated step still
# made the harness exit non-zero.
expect_aborted() {
  local ok=1
  if [[ "$2" == "0" ]] || ! grep -Eq "$3" "$TMP/harness.out"; then
    ok=0
    fail "$1 — did not abort with its own guard message (rc=$2, expected a line matching: $3)"
  fi
  if grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
    ok=0
    fail "$1 — execution continued past the source (SENTINEL-SOURCED printed)"
  fi
  (( ok )) && pass "$1"
  (( ok )) || sed 's/^/       /' "$TMP/harness.out" | tail -8
}

# ── Positive control: a good registry sources cleanly ─────────────────────────
# Without this, every negative case below would also pass against a library
# that aborted unconditionally.
h="$(mk_harness "$REAL_CONF" "" "" "")"
rc="$(run_harness "$h")"
if [[ "$rc" == "0" ]] && grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
  pass "control: the real registry sources cleanly and continues"
else
  fail "control: the real registry sources cleanly and continues — rc=$rc"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi

# ── TMP/VERIFY/ENGINE_DIR unset ───────────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "" "no-tmp" "")"
expect_aborted "contract violation (TMP unset) aborts the sourcing script" "$(run_harness "$h")" \
  "VERIFY must be an existing file, and ENGINE_DIR/bash-floor.sh must be an existing file"

# ── VERIFY points at a nonexistent path ───────────────────────────────────────
# task-1-review.md finding 2: the source-time contract used to test only
# `-n "${VERIFY:-}"`. A VERIFY set to a path that does not exist sourced
# cleanly under that check — mk_repo's later `cp "$VERIFY" …` would then fail
# silently (no `set -e` anywhere in this suite), yielding a valid-looking stub
# repo path and a misleading rc-127 failure downstream. Same shape the git
# probe above exists to close.
h="$(mk_harness "$REAL_CONF" "" "" "" "$TMP/no-such-verify-on-host.sh")"
expect_aborted "a nonexistent VERIFY path aborts the sourcing script" "$(run_harness "$h")" \
  "VERIFY must be an existing file, and ENGINE_DIR/bash-floor.sh must be an existing file"

# ── ENGINE_DIR has verify-on-host.sh but no bash-floor.sh ─────────────────────
# final-review.md finding 1: the third clause of that same contract check,
# -f "$ENGINE_DIR/bash-floor.sh", had no case — deleting it left this file,
# test-verify-exit-code.sh and test-layer-containment.sh all at 0 failure(s).
# The scenario is real, not hypothetical: a partially-synced project copy
# (AGENTS.md calls bash-floor.sh "a hard, load-bearing member" of
# shared-files.sh), and the mgd port, which picks ENGINE_DIR by probing for
# verify-on-host.sh and never for bash-floor.sh. Without the clause the source
# succeeds, mk_repo's second `cp` fails silently (no `set -e`), and every
# captured log carries "bash-floor.sh: No such file or directory" WITHOUT
# changing the exit code these tests assert on.
#
# The fixture assertion below is load-bearing, not decoration: all three clauses
# of that compound emit ONE message, so the ERE cannot tell which clause fired.
# Asserting the directory really does hold verify-on-host.sh (so the -f VERIFY
# clause is satisfied) and really does lack bash-floor.sh is what pins the abort
# to the clause this case names. VERIFY is pointed INTO that directory too,
# which is how the mgd port would reach this state.
engine_nofloor="$TMP/engine-nofloor"
mkdir -p "$engine_nofloor"
cp "$VERIFY" "$engine_nofloor/verify-on-host.sh"
if [[ -f "$engine_nofloor/verify-on-host.sh" && ! -e "$engine_nofloor/bash-floor.sh" ]]; then
  pass "fixture: engine-nofloor holds verify-on-host.sh and no bash-floor.sh"
else
  fail "fixture is wrong: engine-nofloor must hold verify-on-host.sh and no bash-floor.sh"
fi
h="$(mk_harness "$REAL_CONF" "" "" "" "$engine_nofloor/verify-on-host.sh" "$engine_nofloor")"
expect_aborted "an ENGINE_DIR with no bash-floor.sh aborts the sourcing script" "$(run_harness "$h")" \
  "VERIFY must be an existing file, and ENGINE_DIR/bash-floor.sh must be an existing file"

# ── lib-layer-checks.sh not sourced ───────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "skip-lc" "" "")"
expect_aborted "lc_rows undefined aborts the sourcing script" "$(run_harness "$h")" \
  "source tests/lib-layer-checks.sh"

# ── A registry with no path-bin rows ──────────────────────────────────────────
# Rewrites every check row's stub_kind to repo-script, so the registry is
# well-formed and non-empty but yields zero PATH stubs — the real shape of this
# failure, not a corrupt file.
conf_no_pathbin="$TMP/no-pathbin.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "path-bin") $5 = "repo-script" } { print }' \
  "$REAL_CONF" > "$conf_no_pathbin"
if grep -q '^check|.*|path-bin|' "$conf_no_pathbin"; then
  fail "fixture is wrong: no-pathbin.conf still holds a path-bin row"
else
  pass "fixture: no-pathbin.conf holds no path-bin row"
fi
h="$(mk_harness "$conf_no_pathbin" "" "" "")"
expect_aborted "a registry yielding no path-bin stubs aborts the sourcing script" "$(run_harness "$h")" \
  "no path-bin stubs built from"

# ── A registry with no repo-script rows ───────────────────────────────────────
# The condition mk_repo used to `return 1` for from inside a command
# substitution, where the status was swallowed and 13 hand-written caller
# guards had to re-detect it.
conf_no_reposcript="$TMP/no-reposcript.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "repo-script") $5 = "none" } { print }' \
  "$REAL_CONF" > "$conf_no_reposcript"
if grep -q '^check|.*|repo-script|' "$conf_no_reposcript"; then
  fail "fixture is wrong: no-reposcript.conf still holds a repo-script row"
else
  pass "fixture: no-reposcript.conf holds no repo-script row"
fi
h="$(mk_harness "$conf_no_reposcript" "" "" "")"
expect_aborted "a registry yielding no repo-script stubs aborts the sourcing script" "$(run_harness "$h")" \
  "no repo-script stubs declared in"

# ── git unusable ──────────────────────────────────────────────────────────────
# mk_repo's stub repo must be a real git repo with tracked files. When git
# cannot deliver that, Phase 7 fails with "bash -n parsed no files" — a
# DIFFERENT failure that silently satisfies any assertion merely expecting the
# phase under test to fail. Probing at source time turns that into a loud stop.
mkdir -p "$TMP/badgit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/badgit/git"
chmod +x "$TMP/badgit/git"
h="$(mk_harness "$REAL_CONF" "" "" "")"
expect_aborted "an unusable git aborts the sourcing script" "$(run_harness "$h" "$TMP/badgit")" \
  "git cannot create a repo and commit under"

# ── git WITHOUT `init -b`, and git that cannot commit ─────────────────────────
# The `git init -b main . || git init .` fallback and the probe's `add &&
# commit` are unfalsifiable against a healthy modern git: the second `init` is
# an idempotent re-init, so flipping `||` to `&&` changes nothing, and flipping
# `add && commit` to `add || commit` merely skips a commit whose success nobody
# was checking. All three flips survived the entire suite (backlog F17), and
# the third is the worse kind: `git add f || git commit` stops proving git can
# commit while still reporting success — a guard that cannot fail, which is the
# defect class this library was rewritten to remove.
#
# So the fallback is exercised where it is REACHABLE: against a git that
# rejects `init -b`, exactly as git < 2.28 does. Both fakes delegate to the
# real git for everything else, because a fake that answers everything itself
# would be testing the fake.
REAL_GIT="$(command -v git)"
[[ -x "$REAL_GIT" ]] \
  || { printf 'SCAFFOLD-FAILED: no git on PATH to delegate to\n'; exit 1; }

mkdir -p "$TMP/nobgit"
{ printf '#!/usr/bin/env bash\n'
  printf 'if [[ "${1:-}" == "init" ]]; then\n'
  printf '  for a in "$@"; do [[ "$a" == "-b" ]] && { printf "error: unknown switch \\`b'"'"'\\n" >&2; exit 129; }; done\n'
  printf 'fi\n'
  printf 'exec %q "$@"\n' "$REAL_GIT"
} > "$TMP/nobgit/git"
chmod +x "$TMP/nobgit/git"
# The fake must actually reject what it claims to, and still work otherwise —
# a fake that silently delegated everything would make both cases below pass
# for no reason at all.
( cd "$TMP" && rm -rf .fakeprobe && mkdir .fakeprobe && cd .fakeprobe \
    && PATH="$TMP/nobgit:$PATH" git init -q -b main . ) >/dev/null 2>&1 \
  && fail "fixture: the -b-rejecting git accepted \`init -b\` — both cases below would prove nothing" \
  || pass "fixture: the -b-rejecting git refuses \`init -b\`"
( cd "$TMP/.fakeprobe" && PATH="$TMP/nobgit:$PATH" git init -q . ) >/dev/null 2>&1 \
  && pass "fixture: … and still delegates a plain \`git init\` to the real git" \
  || fail "fixture: the -b-rejecting git broke plain \`git init\` too — the cases below would fail for the wrong reason"
rm -rf "$TMP/.fakeprobe"

mkdir -p "$TMP/nocommitgit"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [[ "$a" == "commit" ]] && exit 1; done\n'
  printf 'exec %q "$@"\n' "$REAL_GIT"
} > "$TMP/nocommitgit/git"
chmod +x "$TMP/nocommitgit/git"
( cd "$TMP" && rm -rf .fakeprobe2 && mkdir .fakeprobe2 && cd .fakeprobe2 \
    && PATH="$TMP/nocommitgit:$PATH" git init -q . && : > f \
    && PATH="$TMP/nocommitgit:$PATH" git add f ) >/dev/null 2>&1 \
  && pass "fixture: the commit-refusing git still inits and adds" \
  || fail "fixture: the commit-refusing git broke init/add — the case below would abort for the wrong reason"
( cd "$TMP/.fakeprobe2" \
    && PATH="$TMP/nocommitgit:$PATH" git -c user.email=t@example -c user.name=t commit -q -m x ) >/dev/null 2>&1 \
  && fail "fixture: the commit-refusing git accepted a commit — the case below would prove nothing" \
  || pass "fixture: … and refuses \`commit\` even behind -c options"
rm -rf "$TMP/.fakeprobe2"

# 1. The probe's fallback (line ~181). Sourcing must SUCCEED: `git init -b`
#    fails, `git init` succeeds, the probe commits. Under the `&&` mutant the
#    first failure ends the chain and the source aborts with its own message —
#    which the assertion below reads as a failure, by rc AND by sentinel.
h="$(mk_harness "$REAL_CONF" "" "" 'echo SENTINEL-PROBE-SURVIVED-NOB')"
rc="$(run_harness "$h" "$TMP/nobgit")"
if [[ "$rc" == "0" ]] && grep -q '^SENTINEL-PROBE-SURVIVED-NOB$' "$TMP/harness.out"; then
  pass "a git without \`init -b\` still passes the source-time probe (the || fallback is reached)"
else
  fail "a git without \`init -b\` still passes the source-time probe (rc=$rc)"
  sed 's/^/       /' "$TMP/harness.out" | tail -4
fi

# 2. mk_repo's own fallback (line ~322). mk_repo swallows its subshell's status
#    by design, so "it worked" cannot be read from an exit code — it is read
#    from the three things the real call sites consume, the same trio the
#    control case below pins.
h="$(mk_harness "$REAL_CONF" "" "" '
r="$(mk_repo 0)"
[[ -n "$r" ]] && git -C "$r" rev-parse HEAD >/dev/null 2>&1 && echo "SENTINEL-NOB-COMMIT-OK"
[[ -n "$r" ]] && [[ -n "$(git -C "$r" ls-files "*.sh")" ]] && echo "SENTINEL-NOB-TRACKED-OK"')"
rc="$(run_harness "$h" "$TMP/nobgit")"
missing=""
[[ "$rc" == "0" ]] || missing="${missing}rc=$rc "
grep -q '^SENTINEL-NOB-COMMIT-OK$' "$TMP/harness.out" || missing="${missing}no-commit "
grep -q '^SENTINEL-NOB-TRACKED-OK$' "$TMP/harness.out" || missing="${missing}no-tracked-sh-files "
if [[ -z "$missing" ]]; then
  pass "mk_repo still yields a committed repo with tracked *.sh under a git without \`init -b\`"
else
  fail "mk_repo still yields a committed repo with tracked *.sh under a git without \`init -b\` — missing: ${missing% }"
  sed 's/^/       /' "$TMP/harness.out" | tail -6
fi

# 3. The probe's commit step (line ~183). `add && commit` flipped to `add ||
#    commit` skips the commit whenever `add` succeeds — so the probe stops
#    proving git can commit and reports success anyway. The only way to see
#    that is a git that adds fine and refuses to commit: pristine ABORTS,
#    mutant carries on.
h="$(mk_harness "$REAL_CONF" "" "" 'echo SENTINEL-SHOULD-NOT-REACH')"
out_rc="$(run_harness "$h" "$TMP/nocommitgit")"
expect_aborted "a git that cannot COMMIT aborts the sourcing script" "$out_rc" \
  "git cannot create a repo and commit under"
grep -q '^SENTINEL-SHOULD-NOT-REACH$' "$TMP/harness.out" \
  && fail "  … and execution stopped there (the harness body ran anyway)" \
  || pass "  … and execution stopped there"

# ── An unguarded call site is safe ────────────────────────────────────────────
# The point of Task 1, stated as a test. Against a GOOD registry, the bare
# `r="$(mk_repo 0)"` form — no `[[ -n "$r" ]] ||` guard after it, which is how
# all 13 call sites now read — produces a USABLE repo and execution continues.
# Its other half is the no-repo-script case above: with a bad registry, control
# never reaches this line at all, because the source aborted.
#
# task-2-review.md finding (Important): `-d "$r/.git"` alone is satisfied
# immediately after `git init`, before any `add`/`commit` — it does not prove
# the "usable repo" the label claims. "Usable" is pinned to the three things
# the real call sites' downstream phases actually consume: a real commit
# (`git rev-parse HEAD`, not `git log`, whose output would then need parsing),
# the files mk_repo copies in actually present, and at least one tracked
# `*.sh` file — the exact input Phase 7's `git ls-files '*.sh'` reads.
#
# final-review.md finding 6: `$r` non-emptiness is its own sub-condition, and
# both git probes are gated on it. `git -C ""` has been a NO-OP since Git 2.9,
# so an empty `$r` would let the AMBIENT repository — the developer's real
# checkout, when the suite runs from the repo root — answer two of the three
# conditions. That is the same shape as `cd ""` succeeding and staying put,
# which in this repo once committed the whole real working tree under a fake
# identity (see tests/test-layer-containment.sh's mk_repo call site).
h="$(mk_harness "$REAL_CONF" "" "" '
r="$(mk_repo 0)"
[[ -n "$r" ]] && echo "SENTINEL-PATH-OK"
[[ -n "$r" ]] && git -C "$r" rev-parse HEAD >/dev/null 2>&1 && echo "SENTINEL-COMMIT-OK"
[[ -f "$r/verify-on-host.sh" ]] && echo "SENTINEL-FILE-OK"
[[ -n "$r" ]] && [[ -n "$(git -C "$r" ls-files "*.sh")" ]] && echo "SENTINEL-TRACKED-OK"
echo "SENTINEL-AFTER-MKREPO"')"
rc="$(run_harness "$h")"
missing=""
[[ "$rc" == "0" ]] || missing="${missing}rc=$rc "
grep -q '^SENTINEL-PATH-OK$' "$TMP/harness.out" || missing="${missing}empty-repo-path "
grep -q '^SENTINEL-COMMIT-OK$' "$TMP/harness.out" || missing="${missing}no-commit "
grep -q '^SENTINEL-FILE-OK$' "$TMP/harness.out" || missing="${missing}verify-on-host.sh-not-copied "
grep -q '^SENTINEL-TRACKED-OK$' "$TMP/harness.out" || missing="${missing}no-tracked-sh-files "
grep -q '^SENTINEL-AFTER-MKREPO$' "$TMP/harness.out" || missing="${missing}did-not-continue "
if [[ -z "$missing" ]]; then
  pass "control: an unguarded mk_repo call site yields a usable repo and continues"
else
  fail "control: an unguarded mk_repo call site yields a usable repo and continues — missing: ${missing% }"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi

# ── The registry's `-` rc_var sentinel never reaches an expansion ─────────────
# `${-}` is not an undefined variable — it is the shell's own option flags — so
# a naive `${rc_var:-0}` / `${!rc_var:-0}` turns a row that asked for "no canned
# exit code" into `exit huB`, which dies with "numeric argument required" and
# reports 2. The registry exists so a new row can be added without reading
# lib-verify-repo.sh, and `rc_var=-` on a repo-script or path-bin row is the
# natural thing to write, so this is closed by construction rather than left to
# the fact that no such row exists today.
#
# Asserted by EFFECT, on both stub kinds, because they resolve the value at
# different times: the path-bin stub is written at source time and reads the
# variable when it runs; the repo-script stub is written inside mk_repo with the
# value already resolved. A fix to one form would not fix the other.
conf_dash_rc="$TMP/dash-rc.conf"
awk -F'|' -v OFS='|' \
  '/^check\|/ { if ($5 == "repo-script" || $5 == "path-bin") $7 = "-" } { print }' \
  "$REAL_CONF" > "$conf_dash_rc"
if grep -qE '^check\|[^|]*\|[^|]*\|[^|]*\|(repo-script|path-bin)\|[^|]*\|-\|' "$conf_dash_rc"; then
  pass "fixture: dash-rc.conf gives a repo-script/path-bin row rc_var=-"
else
  fail "fixture: dash-rc.conf gives a repo-script/path-bin row rc_var=-"
fi
h="$(mk_harness "$conf_dash_rc" "" "" '
r="$(mk_repo 0)"
bash "$r/tests/run-all.sh" >/dev/null 2>&1; echo "REPO-SCRIPT-RC=$?"
bash "$TMP/bin/shellcheck" >/dev/null 2>&1; echo "PATH-BIN-RC=$?"')"
rc="$(run_harness "$h")"
missing=""
[[ "$rc" == "0" ]] || missing="${missing}harness-rc=$rc "
grep -q '^REPO-SCRIPT-RC=0$' "$TMP/harness.out" || missing="${missing}repo-script-stub "
grep -q '^PATH-BIN-RC=0$' "$TMP/harness.out" || missing="${missing}path-bin-stub "
if [[ -z "$missing" ]]; then
  pass "an rc_var of '-' yields a stub that exits 0, not the shell's option flags"
else
  fail "an rc_var of '-' yields a stub that exits 0, not the shell's option flags — bad: ${missing% }"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
