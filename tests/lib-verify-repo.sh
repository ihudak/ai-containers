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
# sourcing this file. Provides: mk_repo(), run_verify(), stub binaries at
# $TMP/bin/{docker,shellcheck}, and $WITNESS_LOG.
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

[[ -n "${TMP:-}" && -n "${VERIFY:-}" && -n "${ENGINE_DIR:-}" ]] || {
  echo "lib-verify-repo.sh: TMP, VERIFY and ENGINE_DIR must be set before sourcing" >&2
  return 1 2>/dev/null || exit 1
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
# on whatever machine runs this suite, and this repo currently carries a real
# pre-existing shellcheck backlog (Task 9 of this increment clears it) —
# neither fact may leak into a hermetic test's result, so the stub always
# wins over PATH.
cat > "$TMP/bin/shellcheck" <<EOF
#!/usr/bin/env bash
printf 'STUB:shellcheck\n' >> "$WITNESS_LOG"
exit "\${SHELLCHECK_RC:-0}"
EOF
chmod +x "$TMP/bin/shellcheck"

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
mk_repo() {  # $1=build.sh exit code
  local r="$TMP/repo"
  rm -rf "$r"; mkdir -p "$r/tests/integration"
  cp "$VERIFY" "$r/verify-on-host.sh"
  # verify-on-host.sh sources bash-floor.sh once $REPO is confirmed to be the
  # engine dir. Without this copy the source silently fails (set -uo pipefail
  # has no -e), printing "bash-floor.sh: No such file or directory" into every
  # captured log without affecting the exit code this file asserts on.
  cp "$ENGINE_DIR/bash-floor.sh" "$r/bash-floor.sh"
  printf '#!/usr/bin/env bash\necho "stub build (rc=%s)" >&2\nexit %s\n' "$1" "$1" > "$r/build.sh"
  chmod +x "$r/build.sh"
  printf 'db-clients=\nimagemagick=OFF\nwkhtmltopdf=OFF\nruby=\ncopilot=OFF\n' > "$r/sandbox.conf"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --list-caps) exit 0 ;; esac\nexit %s\n' \
    "${CORPUS_RC:-0}" > "$r/tests/integration/run.sh"
  chmod +x "$r/tests/integration/run.sh"
  printf '#!/usr/bin/env bash\nprintf "STUB:run-all.sh\\n" >> "%s"\nexit %s\n' \
    "$WITNESS_LOG" "${SUITE_RC:-0}" > "$r/tests/run-all.sh"
  chmod +x "$r/tests/run-all.sh"
  printf '#!/usr/bin/env bash\nprintf "STUB:check-sandbox-version.sh\\n" >> "%s"\nexit %s\n' \
    "$WITNESS_LOG" "${SCHEMA_RC:-0}" > "$r/check-sandbox-version.sh"
  chmod +x "$r/check-sandbox-version.sh"
  printf '#!/usr/bin/env bash\nprintf "STUB:bash-dialect-lint.sh\\n" >> "%s"\nexit %s\n' \
    "$WITNESS_LOG" "${DIALECT_RC:-0}" > "$r/tests/bash-dialect-lint.sh"
  chmod +x "$r/tests/bash-dialect-lint.sh"
  ( cd "$r" && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
      && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m stub ) >/dev/null 2>&1
  printf '%s' "$r"
}

# Run a phase selection against a stub repo. Prints the exit code.
run_verify() {  # $1=repo $2=phases  → exit code, log in $TMP/out.log
  PATH="$TMP/bin:$PATH" REPO="$1" PHASES="$2" \
    bash "$1/verify-on-host.sh" > "$TMP/out.log" 2>&1
  printf '%s' "$?"
}
