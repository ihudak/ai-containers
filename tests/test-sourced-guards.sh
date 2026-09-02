#!/usr/bin/env bash
# tests/test-sourced-guards.sh — a sourced-or-executed guard must ask the SHELL,
# never compare argv strings.
#
# THE CLASS. Nine scripts in this tree decide whether they were sourced or
# executed. The decision comes in two polarities, and each has a form that
# compares argv strings and a form that asks the shell:
#
#   [[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0
#      →  (return 0 2>/dev/null) && return 0
#   if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main; fi
#      →  if ! (return 0 2>/dev/null); then main; fi
#
# The string form is correct only by accident of how the caller happened to type
# the path. `$0` is what the process was INVOKED as; `BASH_SOURCE[0]` is the
# file currently being read. Source a file by the same absolute path the process
# was invoked as and the two are byte-identical, the guard concludes "not
# sourced", and the body runs inside the caller.
#
# WHY THIS FILE EXISTS RATHER THAN A NOTE. build.sh had that guard, and
# ai_containers_config_digest (sandbox-common.sh) sources build.sh by an
# absolute path. Executing build.sh by that same path closed the loop: the build
# body ran inside the digest subshell, which computed the digest, which sourced
# build.sh again. Measured 2026-09-01: 1077 processes over two hours, never
# reaching `docker build`. It was fixed in #218 and is asserted by
# tests/test-provenance.sh.
#
# A CLASS SWEEP FOUND EIGHT MORE, WHERE A HAND REVIEW HAD FOUND TWO. The review
# after #218 named project-init.sh and sync-to-projects.sh, both written in the
# `!=` polarity. The scan at the bottom of this file matches BOTH polarities and
# found six further instances in the `==` form, whose failure is the mirror
# image: sourced by the invoking path, the comparison is true and `main` RUNS
# during the source.
#
#   != polarity   project-init.sh, sync-to-projects.sh
#   == polarity   install-tools.sh, install-agent-skills.sh,
#                 tests/falsify/{run,generate,check-ledger,derive-targets}.sh
#
# All eight were LATENT, not live: no caller sources any of them by a path equal
# to its own $0 today. That is precisely what build.sh was on the day before
# ai_containers_config_digest arrived — and "no such caller today" is a fact
# about callers, not about these files, which is why the sweep is the part of
# this test that keeps the count from growing back.
#
# ── WHAT IS ASSERTED, AND WHY IT IS SAFE ─────────────────────────────────────
#
# BY EFFECT: each subject is sourced by its own absolute path and must return
# having run NOTHING of its body — proven by the absence of a string only its
# body can print, not by reading the guard's source text. The negative case is
# asserted too: an EXECUTED script must still run, because a guard that returns
# early unconditionally would satisfy the first assertion and break every
# invocation.
#
# AGAINST A SCRATCH COPY, WHICH IS A SAFETY REQUIREMENT AND NOT A CONVENIENCE.
# With the guard broken, sourcing sync-to-projects.sh runs its MAIN BODY, and
# its no-argument branch syncs every project in projects.conf. Pointed at the
# real repo that is a write to every registered project on the machine. The
# scratch has no projects.conf, so the same code path stops at a diagnostic.
# project-init.sh is bounded the same way: its wizard never gets past the first
# prompt, so it never writes anything.
#
# The scratch holds COPIES OF THE WORKING TREE, not `git archive HEAD`: this
# file has to fail before the fix is committed and pass after, so it must
# exercise the files as they are on disk.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# THE ENGINE IS NOT ALWAYS THE REPO ROOT. The mgd port keeps the engine under
# `base/` with tests at the root, which is why every other test in this tree
# resolves it this way rather than assuming a flat checkout. Without it the
# scratch below is built from the wrong directory and this file SCAFFOLD-FAILs
# on that layout — loud, but it means the class ratchet never runs there.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox-common.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
# shellcheck source=./portability.sh
source "$REPO_DIR/tests/portability.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# GUARDED, because this file FORKS: p_timeout backgrounds both the command it
# bounds and a watchdog beside it, and a forked child inherits this trap and can
# run it — deleting the fixture the parent is still using. $BASHPID is the pid of
# the process actually executing; $$ is unchanged in a subshell and would guard
# nothing. See tests/test-exit-trap-ownership.sh, which fails without this.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# ── the scratch engine ────────────────────────────────────────────────────────
# Both subjects resolve their siblings from `dirname "${BASH_SOURCE[0]}"` and
# source bash-floor.sh, shared-files.sh and version.sh before reaching their
# guard, so the copy needs the engine's top-level scripts beside them. No
# `git ls-files`: this file also runs inside the bash-floor container and inside
# a falsify-seeded tree, neither of which is guaranteed to be a git checkout.
ENGINE="$TMP/engine"
mkdir -p "$ENGINE" || { printf 'SCAFFOLD-FAILED: mkdir engine\n'; exit 1; }
cp "$ENGINE_DIR"/*.sh "$ENGINE/" 2>/dev/null || true
# migrations/ is shared at the REPO root in the mgd layout and sits beside the
# engine in a flat checkout, so both are tried and whichever exists wins.
for d in migrations tools.d; do
  for src in "$ENGINE_DIR/$d" "$REPO_DIR/$d"; do
    [[ -d "$src" ]] || continue
    mkdir -p "$ENGINE/$d" && cp -R "$src/." "$ENGINE/$d/" 2>/dev/null || true
    break
  done
done
chmod +x "$ENGINE"/*.sh 2>/dev/null || true

# The scaffold must assert ITSELF. An engine missing a subject would make every
# assertion below vacuous in the direction that reports success.
scaffold_ok=1
for f in project-init.sh sync-to-projects.sh bash-floor.sh shared-files.sh version.sh; do
  [[ -f "$ENGINE/$f" ]] || { printf 'SCAFFOLD-FAILED: engine has no %s\n' "$f"; scaffold_ok=0; }
done
[[ -e "$ENGINE/projects.conf" ]] \
  && { printf 'SCAFFOLD-FAILED: scratch has a projects.conf — a broken guard would SYNC through it\n'; scaffold_ok=0; }
(( scaffold_ok == 1 )) || exit 1

# ── the two shapes, run under a portable bound ────────────────────────────────
# `p_timeout`, never `timeout`, and no `setsid`: neither exists on a stock macOS,
# each returns 127 there, and 127 is not the value these checks look for — so the
# first version of the build.sh guard test PASSED on macOS against the very
# defect it was written for (fixed in 02112f3). A bound that is absent on the
# platform running it is not a bound.
RC=0
run_sourced() {   # <script> [stdin-text] → its output on stdout, status in $RC
  local script="$1" stdin_text="${2-}" out
  out="$(printf '%s' "$stdin_text" \
    | p_timeout 30 bash -c 'source "$0"' "$script" 2>&1)"
  RC=$?
  printf '%s' "$out"
# `bash <file>`, not `./<file>`: most scripts in this tree are committed
# non-executable (generate.sh among them), and mode is not what is under test —
# `bash <file>` is an execution, and sets $0 to the file, which is.
}
run_executed() {  # <script> [stdin-text] → its output on stdout, status in $RC
  local script="$1" stdin_text="${2-}" out
  out="$(printf '%s' "$stdin_text" | p_timeout 30 bash "$script" 2>&1)"
  RC=$?
  printf '%s' "$out"
}

# ── 1. project-init.sh ────────────────────────────────────────────────────────
# Its body opens with a `while true` wizard whose first prompt rejects an empty
# answer with "Path is required." — a string that exists nowhere else in the
# file and cannot be printed without the body having run. Two blank lines on
# stdin make it say so twice and then stop at EOF, so the broken case terminates
# on its own rather than relying on the bound. `read -p` writes its prompt only
# to a terminal, which is why the WIZARD'S OWN diagnostic is the witness and not
# the prompt text.
PI_WITNESS='Path is required.'

out="$(run_sourced "$ENGINE/project-init.sh" $'\n\n')"; rc=$RC
if [[ "$rc" -eq 0 && "$out" != *"$PI_WITNESS"* ]]; then
  pass "sourcing project-init.sh by absolute path returns without entering the wizard"
else
  fail "sourcing project-init.sh by absolute path ran its body (rc=$rc) — the guard compares \$0 to BASH_SOURCE[0] as strings, so an absolute-path invocation makes them equal and the wizard runs inside the caller"
fi

# NOT VACUOUS: the guard must still let an EXECUTED project-init.sh run. Without
# this, replacing the guard with a bare `return 0` would satisfy the assertion
# above while breaking every real invocation.
out="$(run_executed "$ENGINE/project-init.sh" $'\n\n')"; rc=$RC
if [[ "$out" == *"$PI_WITNESS"* ]]; then
  pass "  … while an EXECUTED project-init.sh still runs its wizard"
else
  fail "  … while an EXECUTED project-init.sh still runs its wizard — it returned silently (rc=$rc), so the guard fires for execution too"
fi

# ── 2. sync-to-projects.sh ────────────────────────────────────────────────────
# Its no-argument branch reads projects.conf, which the scratch does not have, so
# the body announces itself and stops before touching anything. That diagnostic
# is the witness: reaching it means the guard let the main body run.
SP_WITNESS='projects.conf not found'

out="$(run_sourced "$ENGINE/sync-to-projects.sh")"; rc=$RC
if [[ "$rc" -eq 0 && "$out" != *"$SP_WITNESS"* ]]; then
  pass "sourcing sync-to-projects.sh by absolute path returns without running the sync"
else
  fail "sourcing sync-to-projects.sh by absolute path ran its main body (rc=$rc) — with a real projects.conf beside it that body syncs EVERY registered project"
fi

out="$(run_executed "$ENGINE/sync-to-projects.sh")"; rc=$RC
if [[ "$out" == *"$SP_WITNESS"* ]]; then
  pass "  … while an EXECUTED sync-to-projects.sh still runs its main body"
else
  fail "  … while an EXECUTED sync-to-projects.sh still runs its main body — it returned silently (rc=$rc), so the guard fires for execution too"
fi

# ── 3. the OTHER polarity ─────────────────────────────────────────────────────
# Both subjects above are written `!=` … `return 0`, where the failure is that
# the body is SKIPPED for an executed script. The remaining six use the mirror
# form, `==` … `then main`, where the failure is the opposite: sourced by the
# invoking path the comparison is true and MAIN RUNS during the source. Those
# are different effects, so asserting one polarity does not assert the other,
# and a scan of source text asserts neither.
#
# tests/falsify/generate.sh is the subject because it is the cheapest of the six
# that is SAFE to let run: with no arguments its main prints a usage line and
# exits 2, having written nothing and taken no measurable time. The others are
# not — install-agent-skills.sh's main writes under $HOME, and
# tests/falsify/run.sh's main would start the whole mutation tier. It is used
# here IN PLACE, not copied, because running it costs nothing and a copy would
# assert the copy.
GEN="$REPO_DIR/tests/falsify/generate.sh"
GEN_WITNESS='usage: generate.sh'

if [[ -f "$GEN" ]]; then
  out="$(run_sourced "$GEN")"; rc=$RC
  if [[ "$rc" -eq 0 && "$out" != *"$GEN_WITNESS"* ]]; then
    pass "sourcing generate.sh by absolute path does not run its main"
  else
    fail "sourcing generate.sh by absolute path RAN its main (rc=$rc) — the equality polarity of the same defect: the two spellings coincide, so the file mistakes a source for an execution"
  fi

  out="$(run_executed "$GEN")"; rc=$RC
  if [[ "$out" == *"$GEN_WITNESS"* ]]; then
    pass "  … while an EXECUTED generate.sh still runs its main"
  else
    fail "  … while an EXECUTED generate.sh still runs its main — it produced no usage line (rc=$rc), so the guard now suppresses execution too"
  fi
else
  fail "sourcing generate.sh by absolute path does not run its main — no such file, so the == polarity is unasserted"
  fail "  … while an EXECUTED generate.sh still runs its main — no such file"
fi

# ── 4. the class ratchet ──────────────────────────────────────────────────────
# The two assertions above pin the two files that have the idiom TODAY. This
# scan is what stops a fourth file from acquiring it, and it is the only part of
# this test that reads source text rather than observing behaviour — a lint, in
# the same spirit as tests/bash-dialect-lint.sh, and stated as such rather than
# smuggled in as an effect assertion.
#
# WHOLE-LINE COMMENT CLASSIFICATION, NOT COMMENT STRIPPING. Three of the five
# matches in this tree are prose ABOUT the idiom (build.sh's own explanation,
# and two test headers), so the scan must skip comments — but stripping from the
# first `#` in a line is unsound, because a `#` inside a quoted string or a
# parameter expansion is indistinguishable from one opening a comment by regex
# alone (the reasoning tests/bash-dialect-lint.sh records). A line whose first
# non-blank character is `#` is unambiguously a comment; that is the only
# classification made here.
scan_string_guards() {   # <file>… → "<file>:<lineno>" per offending line
  local f line trimmed norm lineno
  for f in "$@"; do
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$(( lineno + 1 ))
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [[ "$trimmed" == '#'* ]] && continue
      # Quotes and braces removed so `"${0}"`, `"$0"` and `$0` read alike, and
      # so the test catches the comparison written in either order.
      norm="${line//[\"\{\}]/}"
      [[ "$norm" == *'BASH_SOURCE[0]'* ]] || continue
      [[ "$norm" == *'$0'* ]] || continue
      [[ "$norm" == *'!='* || "$norm" == *'=='* ]] || continue
      printf '%s:%s\n' "$f" "$lineno"
    done < "$f"
  done
}

# The scanner is demonstrated in BOTH directions before it judges the tree: one
# planted file it must flag, two it must not. A scanner that reported nothing
# would otherwise "pass" the sweep below having looked at nothing.
# THE VECTORS ARE ASSEMBLED, NOT WRITTEN LITERALLY, so this file does not trip
# the scan it defines. The scan requires all three tokens on ONE line; keeping
# the source token in a variable and the operator in the format string means no
# line here carries the whole idiom. That is cheaper and more honest than an
# opt-out marker mechanism nothing else in the tree would use — and unlike a
# blanket exemption for this path, it leaves the file genuinely subject to its
# own rule.
bs='BASH_SOURCE[0]'
{ printf '#!/usr/bin/env bash\n'
  printf '[[ "${%s}" != "${0}" ]] && return 0\n' "$bs"; } > "$TMP/plant-bad.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'if [[ "${0}" == "${%s}" ]]; then :; fi\n' "$bs"; } > "$TMP/plant-reversed.sh"
{ printf '#!/usr/bin/env bash\n'
  printf '# prose naming ${%s} and ${0} together, which is not code\n' "$bs"
  printf '(return 0 2>/dev/null) && return 0\n'; } > "$TMP/plant-comment.sh"

hits="$(scan_string_guards "$TMP/plant-bad.sh")"
[[ "$hits" == *"plant-bad.sh:2"* ]] \
  && pass "the scan flags the string-compare idiom on a code line" \
  || fail "the scan flags the string-compare idiom on a code line — it reported '$hits', so the sweep below is looking at nothing"

hits="$(scan_string_guards "$TMP/plant-reversed.sh")"
[[ -n "$hits" ]] \
  && pass "  … in either order (\$0 compared to BASH_SOURCE[0])" \
  || fail "  … in either order (\$0 compared to BASH_SOURCE[0]) — reversing the operands evades the scan"

hits="$(scan_string_guards "$TMP/plant-comment.sh")"
[[ -z "$hits" ]] \
  && pass "  … and does not flag prose describing it, nor the shell-asking form" \
  || fail "  … and does not flag prose describing it, nor the shell-asking form — reported '$hits', so every file explaining the defect becomes a violation"

# THE SWEEP. `find`, not `git ls-files`: an untracked script in the tree is still
# a script someone can run, and this file must also work in the bash-floor
# container and in a falsify-seeded tree, neither guaranteed to be a checkout.
#
# EXCEPT A SYNCED PROJECT WORKING COPY, which is not source and cannot be fixed
# by editing anything. `project-init.sh` puts a `.ai-containers/` beside a
# project — including beside THIS repo, when it is registered against itself —
# holding copies of AI_CONTAINERS_SHARED_FILES as of the release it last synced.
# A copy that predates #218 therefore still carries the string compare, and it
# reappears every time an older engine is synced, so a hit there is a report
# about the copy's AGE, not about a fourth file acquiring the idiom. The remedy
# is `./sync-to-projects.sh <project>`, never a source edit; the drift itself is
# what `ai-containers-report.sh`'s per-project VERSION/SCHEMA columns exist to
# show. Sweeping it makes this assertion fail on every machine that actually
# runs containers from this checkout and pass in CI, which has no working copy —
# green where it is cheap to be green, red where the developer is. Measured
# 2026-09-02 on macOS: three hits, all in a v0.9.9 copy, none in the tree.
tree_scripts() {   # <root> → every *.sh under it that this ratchet governs
  find "$1" -name '*.sh' -type f \
    -not -path '*/.git/*' \
    -not -path '*/.ai-containers/*' 2>/dev/null | sort
}

# THE EXCLUSION IS DEMONSTRATED IN BOTH DIRECTIONS, because a path filter that
# quietly matched too much would empty the sweep and report success.
mkdir -p "$TMP/sweeproot/sub" "$TMP/sweeproot/.ai-containers"
: > "$TMP/sweeproot/sub/real.sh"
: > "$TMP/sweeproot/.ai-containers/synced-copy.sh"
listed="$(tree_scripts "$TMP/sweeproot")"
[[ "$listed" == *"sub/real.sh"* ]] \
  && pass "the sweep still reaches an ordinary script anywhere under the tree" \
  || fail "the sweep still reaches an ordinary script anywhere under the tree — it listed '$listed', so the exclusion below matches too much and the ratchet is empty"
[[ "$listed" != *".ai-containers/synced-copy.sh"* ]] \
  && pass "  … and skips a synced project working copy, whose age is not this file's subject" \
  || fail "  … and skips a synced project working copy, whose age is not this file's subject — it listed '$listed'"

mapfile -t all_sh < <(tree_scripts "$REPO_DIR")
if (( ${#all_sh[@]} == 0 )); then
  printf 'SCAFFOLD-FAILED: found no *.sh under %s\n' "$REPO_DIR"
  exit 1
fi
hits="$(scan_string_guards "${all_sh[@]}")"
if [[ -z "$hits" ]]; then
  pass "no script in the tree compares \$0 to BASH_SOURCE[0] (${#all_sh[@]} scanned)"
else
  fail "a script compares \$0 to BASH_SOURCE[0] — correct only until someone invokes it by the path it sources itself as:"
  printf '%s\n' "$hits" | sed "s|^$REPO_DIR/|         |"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
