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
  # Phase 0 gates on this one, and only for the phases that need a daemon, so a
  # test that means to exercise that gate has to be able to fail it.
  info) exit "\${DOCKER_INFO_RC:-0}" ;;
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
# ── The registry's `-` rc_var sentinel ───────────────────────────────────────
# A check row whose stub takes no canned exit code writes `-` in the rc_var
# column. That string must never reach a parameter expansion: `${-}` is not an
# undefined variable, it is the SHELL'S OWN OPTION FLAGS, so `${-:-0}` expands
# to something like `huB` and `${!rc_var:-0}` does the same by indirection. The
# stub would then be asked to `exit huB` and die with "numeric argument
# required" (exit 2) — loud, but attributed to the stub rather than to the row.
# Unreachable at the time of writing (the only `-` row is `kind=probe`, which
# neither stub loop touches) and deliberately closed anyway: the registry exists
# so a new row can be added without reading this file, and `rc_var=-` on a
# repo-script or path-bin row is the natural thing to write.
#
# Two forms, because the two stub kinds resolve the value at different times.
# path-bin stubs are written at SOURCE time, before a test has set its canned
# code, so the stub must read the variable when it RUNS: rc_stub_expr emits the
# literal text `${NAME:-0}`. repo-script stubs are written inside mk_repo, by
# which point the caller's `SUITE_RC=1 mk_repo 0` prefix is already in effect,
# so rc_value_now resolves it immediately.
rc_stub_expr() {  # $1=rc_var → deferred expansion text for a generated stub
  if [[ "$1" == "-" ]]; then printf '0'; else printf '${%s:-0}' "$1"; fi
}
rc_value_now() {  # $1=rc_var → the canned exit code, resolved now
  if [[ "$1" == "-" ]]; then printf '0'; else printf '%s' "${!1:-0}"; fi
}

_n_pathbin=0
_n_reposcript=0
while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  [[ "$kind" != "repo-script" ]] || _n_reposcript=$((_n_reposcript+1))
  [[ "$kind" == "path-bin" ]] || continue
  # `-` is the registry's "no rc var" sentinel, and it must NOT reach an
  # expansion: `${-:-0}` indirects through `$-`, the shell's own option flags,
  # so the stub would be written as `exit "huB"` and die with "numeric argument
  # required" (exit 2) instead of the 0 the row asked for. See rc_stub_expr.
  cat > "$TMP/bin/$target" <<EOF
#!/usr/bin/env bash
printf 'STUB:%s\n' "$target" >> "$WITNESS_LOG"
exit "$(rc_stub_expr "$rc_var")"
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
             #    refs/remotes/origin/main ref at HEAD (default 1), on a repo
             #    given a SECOND commit first, so it models a normal checkout on
             #    main: origin/main == HEAD and HEAD^ resolves. Pass 0 for
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
        # rc_value_now, not a bare "${!rc_var:-0}", so the registry's `-`
        # sentinel cannot indirect through the shell's `$-` option flags.
        rc_val="$(rc_value_now "$rc_var")"
        # Two witness lines, not one. "STUB:<name>" proves the check RAN, which
        # is what the registry's own regex matches. "STUB-BASEREF:<name> <ref>"
        # records the BASE_REF it was handed, and exists because running is not
        # the same as checking: the schema gate hands its whole meaning to that
        # one variable, and a BASE_REF equal to HEAD makes it compare a commit to
        # itself and report OK (backlog F44). Only a test that can SEE the value
        # can tell those two apart. Emitted by every repo-script stub rather than
        # special-cased for one, and silent when BASE_REF is unset, so the other
        # stubs are unaffected.
        #
        # "STUB-TMPDIR:<name> <dir>" is the same idea for the same reason. Phase
        # 5 runs tests/run-all.sh TWICE — once ordinarily, once with TMPDIR
        # pointed at a symlink, which is the Linux stand-in for macOS, where /var
        # is a symlink and an unresolved-vs-resolved path comparison fails. Both
        # runs emit an identical "STUB:run-all.sh", so that line alone cannot
        # tell them apart, and a witness that cannot tell them apart would be
        # satisfied by the ordinary run while the symlinked one had been deleted.
        # Recording the TMPDIR is what makes the second run's witness
        # falsifiable. Silent when TMPDIR is unset, like BASE_REF above.
        {
          printf '#!/usr/bin/env bash\n'
          printf 'printf "STUB:%s\\n" >> "%s"\n' "$(basename "$target")" "$WITNESS_LOG"
          printf 'if [[ -n "${BASE_REF-}" ]]; then printf "STUB-BASEREF:%s %%s\\n" "$BASE_REF" >> "%s"; fi\n' \
            "$(basename "$target")" "$WITNESS_LOG"
          printf 'if [[ -n "${TMPDIR-}" ]]; then printf "STUB-TMPDIR:%s %%s\\n" "$TMPDIR" >> "%s"; fi\n' \
            "$(basename "$target")" "$WITNESS_LOG"
          printf 'exit %s\n' "$rc_val"
        } > "$r/$target"
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
  # add_origin=1 gets a SECOND commit before the ref is stamped, so the repo it
  # models is a normal checkout sitting on main: origin/main == HEAD, and HEAD^
  # resolves. That is the shape verify-on-host.sh's BASE_REF resolution has to
  # get right (backlog F44) — with only a root commit, "origin/main == HEAD" and
  # "no base at all" are indistinguishable, and a one-commit repo could not tell
  # a gate that falls back to HEAD^ from one that hands the gate HEAD itself.
  # add_origin=0 deliberately keeps its single commit: that IS the no-base case.
  ( cd "$r" && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
      && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m stub \
      && { [[ "$add_origin" != "1" ]] || {
             printf 'second\n' > .mk-repo-parent \
               && git add .mk-repo-parent \
               && git -c user.email=t@example -c user.name=t commit -q -m stub-2
           }; } \
      && { [[ "$add_origin" != "1" ]] || git update-ref refs/remotes/origin/main HEAD; } \
      && { [[ "${MK_REPO_UNTRACK_SH:-0}" != "1" ]] || {
             git rm -q --cached -- '*.sh' >/dev/null 2>&1
             git -c user.email=t@example -c user.name=t commit -q -m untrack-sh
           }; } \
  ) >/dev/null 2>&1
  printf '%s' "$r"
}

# Run a phase selection against a stub repo. Prints the exit code.
run_verify() {  # $1=repo  $2=phases  [$3…=VAR=VALUE for the script's environment]
                #   → exit code, log in $TMP/out.log
  local repo="$1" phases="$2"
  shift 2
  # THE OPERATOR'S SHELL IS NOT THE TEST'S ENVIRONMENT. verify-on-host.sh reads
  # FALSIFY_JOBS and FALSIFY_TIMEOUT (Phase 6's worker count and per-mutant
  # clock) and IT_EXTRA_ARGS (Phase 4's runner flags) straight out of the
  # environment, and its own header tells a developer to export exactly those
  # when a corpus run comes back with part of it unmeasured. A caller that
  # merely OMITS one is therefore asserting a property of whoever ran the suite
  # rather than of the script.
  #
  # Measured, 2026-08-20: tests/test-verify-exit-code.sh passed in CI and in the
  # dev container and FAILED on the host — inside the falsify tier's
  # pristine-oracle check, because the developer had followed this repo's own
  # instructions and exported FALSIFY_TIMEOUT=600. The tier then skipped that
  # oracle's whole target, so one environment-sensitive assertion cost all 55
  # mutants of THIS file and aborted the entire Phase 6 measurement (F49).
  #
  # So the environment is stated here and never inherited: the knobs are
  # removed, and a test that wants one passes it as a VAR=VALUE argument. `env`
  # applies its operands after its own -u options, so an argument still wins
  # over the removal — pinned by an assertion, not assumed.
  PATH="$TMP/bin:$PATH" REPO="$repo" PHASES="$phases" \
    env -u FALSIFY_JOBS -u FALSIFY_TIMEOUT -u IT_EXTRA_ARGS "$@" \
      bash "$repo/verify-on-host.sh" > "$TMP/out.log" 2>&1
  printf '%s' "$?"
}
