#!/usr/bin/env bash
# tests/lib-verify-repo.sh — shared stub-repo machinery for exercising
# verify-on-host.sh hermetically. SOURCED, never executed directly — it is
# deliberately NOT named test-*.sh so tests/run-all.sh's glob skips it.
#
# Used by tests/test-verify-exit-code.sh and tests/test-layer-containment.sh
# so the two do not maintain independent copies of the same stub repo and
# stub tools. A second, drifted copy of this machinery is exactly the kind of
# duplication this project's own doctrine warns about (AGENTS.md: "a
# hand-written list validates only what someone remembered").
#
# CONTRACT: the sourcing file must set TMP (a scratch dir it owns and tears
# down via its own EXIT trap), VERIFY (path to the real verify-on-host.sh
# under test) and ENGINE_DIR (dir containing the real bash-floor.sh) BEFORE
# sourcing this file, and must have already set LAYER_CHECKS_CONF and sourced
# tests/lib-layer-checks.sh (this file calls lc_rows). Provides: mk_repo(),
# run_verify(), stub binaries at $TMP/bin/{docker,shellcheck}, and $WITNESS_LOG.
#
# Two opt-in modes, both default OFF because test-verify-exit-code.sh shares
# mk_repo() and asserts canned exit codes:
#   MK_REPO_PROBE=1       plant each `probe` row's target holding a REAL syntax
#                         error, tracked, so Phase 7's bash -n emits a
#                         "PARSE ERROR: <path>" line. Always-on would make that
#                         file's Phase 7 fail independently of the RC under test.
#   MK_REPO_UNTRACK_SH=1  after the commit, drop every *.sh from the index so
#                         `git ls-files '*.sh'` is empty while the files remain
#                         on disk. Exercises the "parsed no files" branch.
#
# WITNESS_LOG ($TMP/witness.log): every stub this file creates — docker (its
# `run` subcommand only), shellcheck, tests/run-all.sh,
# check-sandbox-version.sh, tests/bash-dialect-lint.sh — appends one line
# recording that it was ACTUALLY INVOKED (not merely named in a comment) to
# this file, each with a distinct "STUB:<name>" prefix so one stub's witness
# line can never be mistaken for another's — this matters concretely for
# tests/run-all.sh: the floor-suite docker invocation ALSO embeds the string
# "run-all.sh" in its own argv (it runs the suite again, inside a container),
# so a witness scheme that just grepped for "run-all.sh" anywhere in the log
# would report a PASS from the floor invocation alone even if the PRIMARY,
# non-containerized invocation had been deleted — the exact false-negative
# this file exists to close. docker's witness line uses the DIFFERENT prefix
# "STUB:docker-run", so it never collides with tests/run-all.sh's own
# "STUB:run-all.sh" line.
#
# A test that wants to prove a check GENUINELY RAN, not merely that its name
# appears somewhere in verify-on-host.sh's source text, truncates
# $WITNESS_LOG (or relies on the fresh one this file creates at source time)
# before calling run_verify() and then greps it afterward. Callers that only
# care about exit codes (the *_RC canned-exit-code tests in
# test-verify-exit-code.sh) can ignore it entirely.

# Every failure below is UNRECOVERABLE and identical for every caller, and this
# file is sourced, never executed (see the header). `exit` from a sourced file
# terminates the sourcing script and cannot be discarded; the usual
# `return 1 2>/dev/null || exit 1` idiom exists to support both invocation
# modes, and returning here would hand the caller a status nothing reads —
# which is precisely what made 13 hand-written caller guards necessary.
# TMP is asserted -n only (not -d): it is a directory the CALLER owns and
# creates via its own `mktemp -d`/EXIT trap, so by the time this file is
# sourced it necessarily already exists — asserting -n here is asserting the
# contract was followed, not probing the filesystem. VERIFY and
# ENGINE_DIR/bash-floor.sh are different: they name paths this file itself
# reads from later (mk_repo's two `cp` calls), so a merely non-empty path that
# does not exist would source cleanly and fail much later, at a `cp`, with no
# `set -e` to stop it and a misleading cause downstream — the same shape the
# git probe below exists to close. Hence -f, not -n, for those two.
[[ -n "${TMP:-}" && -f "${VERIFY:-}" && -f "${ENGINE_DIR:-}/bash-floor.sh" ]] || {
  echo "lib-verify-repo.sh: TMP must be set, VERIFY must be an existing file, and ENGINE_DIR/bash-floor.sh must be an existing file, before sourcing" >&2
  exit 1
}

declare -F lc_rows >/dev/null 2>&1 || {
  echo "lib-verify-repo.sh: source tests/lib-layer-checks.sh (with LAYER_CHECKS_CONF set) first" >&2
  exit 1
}

WITNESS_LOG="$TMP/witness.log"
: > "$WITNESS_LOG"

# ── Stub docker ──────────────────────────────────────────────────────────────
# Phase 0's environment banner calls docker directly (--version, buildx
# version, info, system df) and must always see success, or every test here
# would die at Phase 0 regardless of which phase it means to exercise. Phase
# 5's declared-floor step is the one real `docker run` in the surviving
# script; this stub does not execute its payload (that would mean apt-get and
# a real image pull inside a "hermetic" test) — it records the full `docker
# run` argv to WITNESS_LOG (so a test can assert WHICH image was actually
# passed) and then exits $DOCKER_RUN_RC, same idiom as CORPUS_RC below for
# tests/integration/run.sh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "run" ]]; then
  printf 'STUB:docker-run %s\n' "\$*" >> "$WITNESS_LOG"
fi
case "\${1:-}" in
  run) exit "\${DOCKER_RUN_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# ── Stub shellcheck ──────────────────────────────────────────────────────────
# Phase 7 gates on shellcheck's exit code. A real shellcheck is not guaranteed
# on whatever machine runs this suite, and this repo's own findings backlog
# (cleared by Task 9 of this increment) is a fact about the repo's current
# tree, not about the phase-selection logic under test here — neither fact
# may leak into a hermetic test's result, so the stub always wins over PATH.
_n_pathbin=0
_n_reposcript=0
while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  [[ "$kind" != "repo-script" ]] || _n_reposcript=$((_n_reposcript+1))
  [[ "$kind" == "path-bin" ]] || continue
  cat > "$TMP/bin/$target" <<EOF
#!/usr/bin/env bash
printf 'STUB:%s\n' "$target" >> "$WITNESS_LOG"
exit "\${${rc_var}:-0}"
EOF
  chmod +x "$TMP/bin/$target"
  _n_pathbin=$((_n_pathbin+1))
done < <(lc_rows check)
# A registry read that produced no path-bin stub means the registry is empty,
# malformed, or lc_rows failed — all of which would otherwise leave the real
# on-PATH shellcheck binary in play, letting this "hermetic" library depend on
# the host. (Line deliberately does not start with "# shellcheck" — that
# prefix is parsed as a shellcheck directive, not a comment, and breaks SC1072/
# SC1073.)
(( _n_pathbin > 0 )) || {
  echo "lib-verify-repo.sh: no path-bin stubs built from $LAYER_CHECKS_CONF" >&2
  exit 1
}
# Counted HERE rather than inside mk_repo, which is invoked as
# `r="$(mk_repo 0)"` — a command-substitution subshell, where neither `return`
# nor `exit` can reach the caller. Both read the same lc_rows output, fixed at
# source time, so nothing is lost by checking it once, early, where a failure
# can actually stop the run.
(( _n_reposcript > 0 )) || {
  echo "lib-verify-repo.sh: no repo-script stubs declared in $LAYER_CHECKS_CONF" >&2
  exit 1
}

# ── git probe ────────────────────────────────────────────────────────────────
# mk_repo's stub repo must be a real git repository with at least one tracked
# file: Phase 7 runs `git ls-files '*.sh'` against it. If git cannot deliver
# that, Phase 7 fails with "bash -n parsed no files" — a DIFFERENT failure that
# still satisfies every assertion merely expecting the phase under test to
# fail, turning a real test into a vacuous one. Probe once, here, where a
# failure can stop the run; mk_repo itself cannot signal one.
_gitprobe="$TMP/.gitprobe"
rm -rf "$_gitprobe"; mkdir -p "$_gitprobe"
(
  cd "$_gitprobe" \
    && { git init -q -b main . || git init -q .; } \
    && : > f && git add f \
    && git -c user.email=t@example -c user.name=t commit -q -m probe
) >/dev/null 2>&1 || {
  echo "lib-verify-repo.sh: git cannot create a repo and commit under $TMP — mk_repo's stub repo would have no tracked files, and Phase 7 would fail with 'parsed no files' instead of the condition under test" >&2
  exit 1
}
rm -rf "$_gitprobe"

# ── Stub repo ────────────────────────────────────────────────────────────────
# $1=build.sh exit code. Nothing in the surviving script (Phase 0, Phase 4)
# actually executes build.sh any more — only the preflight `[[ -f
# "$REPO/build.sh" ]]` existence check does — but that check still requires
# the file to exist, so mk_repo keeps writing it.
#
# Phases 5 and 7 need their own stub targets (tests/run-all.sh,
# check-sandbox-version.sh, tests/bash-dialect-lint.sh) and, for Phase 7's
# `git ls-files`, a real git repository with at least one tracked file — an
# empty/non-git stub dir would make Phase 7 fail with "parsed no files"
# regardless of what a given test is trying to isolate, which is a different
# assertion. Each stub's exit code is independently configurable (SUITE_RC /
# SCHEMA_RC / DIALECT_RC, alongside the existing CORPUS_RC and
# DOCKER_RUN_RC), so a test can make exactly one phase — or two at once — fail
# without touching the others. Each of these three also appends its own
# "STUB:<name>" line to WITNESS_LOG before exiting — see the header comment
# above for why that is a distinct mechanism from the RC-based tests.
#
# mk_repo cannot return a non-zero status, and cannot print an empty path. Its
# output is always `$TMP/repo`, `$TMP` is checked non-empty at source time
# above, and its final command is the unconditional `printf '%s' "$r"`. What
# makes the second half hold is that nothing it expands can kill the
# `r="$(mk_repo 0)"` command-substitution subshell before that printf: `$1` and
# `$2` carry defaults (see mk_repo's own header), every environment variable it
# reads is `${…:-default}`-guarded, and the rest are either locals it assigns
# itself or the TMP/VERIFY/ENGINE_DIR/WITNESS_LOG the source-time checks above
# have already proven set. The other source-time checks (the registry's
# path-bin and repo-script counts, git's ability to init/add/commit) close the
# routes to a *useless* repo, for the same reason: a `return`/`exit` from
# inside that command substitution cannot reach the caller, so this file
# front-loads every check that could.
#
# Two caveats a future caller can reintroduce, neither true of the two callers
# today: unsetting TMP after sourcing (the check above runs once, at source
# time), and `set -e` COMBINED WITH `shopt -s inherit_errexit` — errexit alone
# does not reach inside a command substitution, so a failing `cp`/`mkdir` there
# still falls through to the printf. Both callers run `set -uo pipefail` and
# neither sets that shopt.
#
# That guarantee is what the 13 `[[ -n "$r" ]]` guards that used to follow
# `mk_repo`'s 13 call sites — 12 in tests/test-verify-exit-code.sh, 1 in
# tests/test-layer-containment.sh, all now deleted — were re-detecting one
# level down, and it is what lets a call site carry no guard at all. The 14th
# call site (the floor-suite block at the end of tests/test-verify-exit-code.sh)
# was added with no guard and needs none: that is the property, demonstrated by
# tests/test-lib-verify-repo.sh's unguarded-call-site control.
#
# It is NOT a guarantee that everything mk_repo does succeeds. NOTHING inside
# mk_repo has its status checked: the whole `( cd "$r" && git init … && git
# add -A && git commit … && git update-ref … && … )` subshell's status is
# discarded by its own `>/dev/null 2>&1` (below), and so are both `cp`s, every
# `printf >` redirection, every `mkdir -p` and every `chmod`. What the
# source-time checks buy is not that those operations succeed but that their
# PRECONDITIONS hold — TMP set, both `cp` sources existing, this git able to
# init/add/commit under $TMP — leaving a residual of write failures under a
# $TMP the caller created and owns, on the SAME git binary the probe just
# validated. That is narrow, and it is not the "different failure" class the
# probe exists to close. If any of it did fail, `$r` would still be non-empty
# and mk_repo would still return 0; only the *contents* of the stub repo would
# be wrong — e.g. origin/main silently absent — which is a downstream
# test-correctness concern for whichever assertion depends on it, not a
# failure mk_repo itself could signal or that a caller guard on `$r` would
# ever have caught.
mk_repo() {  # $1=build.sh exit code (default 0)  $2=1 to stamp a
             #    refs/remotes/origin/main ref at HEAD (default 1). Pass 0 for
             #    a repo with NO usable schema-gate base at all — no
             #    origin/main ref, and the single "stub" commit below is also
             #    HEAD's only commit, so HEAD^ does not resolve either. That
             #    combination is what verify-on-host.sh's BASE_REF fallback
             #    (merge-base against origin/main, else HEAD^) is meant to fail
             #    loudly against — see tests/test-verify-exit-code.sh's "no
             #    usable base" cases.
             #
             # $1 CARRIES A DEFAULT rather than being required. Both callers
             # run `set -u`, under which a bare `$1` in an arg-less
             # `r="$(mk_repo)"` kills the command-substitution subshell and
             # hands the caller an EMPTY `$r` — the one route to an empty path
             # that no source-time check above can close, and (with the caller
             # guards gone) one nothing downstream would catch. `${1:?…}` would
             # not help: it fires inside that same subshell, so `$r` still
             # comes back empty; it improves attribution, not signalling. A
             # default removes the failure instead of policing it. 0 is the
             # right value — it means "build.sh succeeds", which is what all
             # 14 current call sites pass, and nothing in the surviving
             # verify-on-host.sh executes build.sh at all: only the preflight
             # `[[ -f "$REPO/build.sh" ]]` existence check reads it.
  local r="$TMP/repo"
  local build_rc="${1:-0}"
  local add_origin="${2:-1}"
  rm -rf "$r"; mkdir -p "$r/tests/integration"
  cp "$VERIFY" "$r/verify-on-host.sh"
  # verify-on-host.sh sources bash-floor.sh once $REPO is confirmed to be the
  # engine dir. Without this copy the source silently fails (set -uo pipefail
  # has no -e), printing "bash-floor.sh: No such file or directory" into every
  # captured log without affecting the exit code this file asserts on.
  cp "$ENGINE_DIR/bash-floor.sh" "$r/bash-floor.sh"
  printf '#!/usr/bin/env bash\necho "stub build (rc=%s)" >&2\nexit %s\n' \
    "$build_rc" "$build_rc" > "$r/build.sh"
  chmod +x "$r/build.sh"
  printf 'db-clients=\nimagemagick=OFF\nwkhtmltopdf=OFF\nruby=\ncopilot=OFF\n' > "$r/sandbox.conf"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --list-caps) exit 0 ;; esac\nexit %s\n' \
    "${CORPUS_RC:-0}" > "$r/tests/integration/run.sh"
  chmod +x "$r/tests/integration/run.sh"
  # Stubs from the registry (tests/layer-checks.conf) rather than one hardcoded
  # printf per check. The two lists used to be maintained separately and nothing
  # made them agree.
  local id job step kind target rc_var wtgt wre rc_val
  # shellcheck disable=SC2034  # id/job/step/wtgt/wre are positional registry columns (tests/lib-layer-checks.sh); only kind/target/rc_var drive this loop, but `read` needs every field named to consume the row
  while IFS='|' read -r id job step kind target rc_var wtgt wre; do
    case "$kind" in
      repo-script)
        mkdir -p "$r/$(dirname "$target")"
        # Indirect expansion, not eval: the registry supplies the VARIABLE NAME
        # (SUITE_RC, SCHEMA_RC, …) and the caller may have set it to a canned
        # exit code. eval here would execute registry content as shell.
        rc_val="${!rc_var:-0}"
        printf '#!/usr/bin/env bash\nprintf "STUB:%s\\n" >> "%s"\nexit %s\n' \
          "$(basename "$target")" "$WITNESS_LOG" "$rc_val" > "$r/$target"
        chmod +x "$r/$target"
        ;;
      probe)
        [[ "${MK_REPO_PROBE:-0}" == "1" ]] || continue
        mkdir -p "$r/$(dirname "$target")"
        # A REAL syntax error: Phase 7 can only print "PARSE ERROR: <path>" for
        # this if bash -n genuinely ran against its content. A comment merely
        # naming "bash -n" could never produce that line.
        printf '#!/usr/bin/env bash\nif [ 1 -eq\n' > "$r/$target"
        ;;
    esac
  done < <(lc_rows check)
  ( cd "$r" && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
      && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m stub \
      && { [[ "$add_origin" != "1" ]] || git update-ref refs/remotes/origin/main HEAD; } \
      && { [[ "${MK_REPO_UNTRACK_SH:-0}" != "1" ]] || {
             git rm -q --cached -- '*.sh' >/dev/null 2>&1
             git -c user.email=t@example -c user.name=t commit -q -m untrack-sh
           }; } \
  ) >/dev/null 2>&1
  printf '%s' "$r"
}

# Run a phase selection against a stub repo. Prints the exit code.
run_verify() {  # $1=repo $2=phases  → exit code, log in $TMP/out.log
  PATH="$TMP/bin:$PATH" REPO="$1" PHASES="$2" \
    bash "$1/verify-on-host.sh" > "$TMP/out.log" 2>&1
  printf '%s' "$?"
}
