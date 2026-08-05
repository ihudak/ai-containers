#!/usr/bin/env bash
# Tests the sandbox.env/sandbox.local.env loader (load_env_defaults, precedence
# inline > local > portable) and sandbox.sh's SANDBOX_MODE/SANDBOX_WORKDIR defaulting.
# NOTE: tests/test-env-file.sh covers a DIFFERENT layer (in-container container.env).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass() { printf 'PASS: %s\n' "$1"; }; fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/sandbox-common.sh" && pass "sandbox-common.sh bash -n" || fail "sandbox-common.sh bash -n"
bash -n "$REPO_DIR/sandbox.sh"        && pass "sandbox.sh bash -n"        || fail "sandbox.sh bash -n"

# Load the REAL load_env_defaults + its env_key_denied helper (extract just the
# functions so the file's heavy top-level code does not run).
eval "$(sed -n '/^env_key_denied()/,/^}/p;/^load_env_defaults()/,/^}/p' "$REPO_DIR/sandbox-common.sh")"
type load_env_defaults >/dev/null 2>&1 && pass "load_env_defaults defined" || { fail "load_env_defaults defined"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
type env_key_denied >/dev/null 2>&1 && pass "env_key_denied defined" || { fail "env_key_denied defined"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# Apply exactly as sandbox-common.sh does: local first, then portable.
apply() { load_env_defaults "$LOCAL"; load_env_defaults "$PORTABLE"; }
mk() { LOCAL="$(mktemp)"; PORTABLE="$(mktemp)"; }
rmk() { rm -f "$LOCAL" "$PORTABLE"; }

# precedence: inline > local > portable
mk; printf 'CONTAINER_MEMORY=2g\n' > "$PORTABLE"; printf 'CONTAINER_MEMORY=4g\n' > "$LOCAL"
( unset CONTAINER_MEMORY; export CONTAINER_MEMORY=8g; apply; [[ "$CONTAINER_MEMORY" == 8g ]] ) \
  && pass "inline wins over local + portable" || fail "inline wins over local + portable"
( unset CONTAINER_MEMORY; apply; [[ "$CONTAINER_MEMORY" == 4g ]] ) \
  && pass "local wins over portable" || fail "local wins over portable"
rmk

# an explicitly-empty inline value is respected (set-if-SET, not set-if-nonempty)
mk; printf 'CONTAINER_MEMORY=2g\n' > "$PORTABLE"
( export CONTAINER_MEMORY=; apply; [[ -z "$CONTAINER_MEMORY" ]] ) \
  && pass "explicit empty inline value is not clobbered" || fail "explicit empty inline value is not clobbered"
rmk

# portable-only key applied
mk; printf 'IMAGE_NAME=proj-img\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == proj-img ]] ) \
  && pass "portable-only key applied" || fail "portable-only key applied"
rmk

# missing local file is a no-op
mk; rm -f "$LOCAL"; printf 'IMAGE_NAME=x\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == x ]] ) \
  && pass "missing sandbox.local.env is a clean no-op" || fail "missing sandbox.local.env is a clean no-op"
rm -f "$PORTABLE"

# comments / blank / export prefix / surrounding quotes / non-assignment ignored
mk
{ printf '# comment\n'; printf '\n'; printf 'export EXTRA_MOUNTS="/a /b"\n'; printf 'not an assignment\n'; } > "$PORTABLE"
( unset EXTRA_MOUNTS; apply; [[ "$EXTRA_MOUNTS" == "/a /b" ]] ) \
  && pass "export prefix + surrounding quotes handled" || fail "export prefix + surrounding quotes handled"
# a stray command line must NOT execute
marker="$(mktemp -u)"; printf 'touch %s\n' "$marker" >> "$PORTABLE"
( apply ) >/dev/null 2>&1
[[ ! -e "$marker" ]] && pass "non-assignment lines do not execute" || { fail "non-assignment lines do not execute"; rm -f "$marker"; }
rmk

# tolerant `export` prefix (tab or multiple spaces, not just a single space)
mk; printf 'export\tCONTAINER_CPUS=3\n' > "$PORTABLE"
( unset CONTAINER_CPUS; apply; [[ "$CONTAINER_CPUS" == 3 ]] ) \
  && pass "tolerates 'export<TAB>KEY=val'" || fail "tolerates 'export<TAB>KEY=val'"
rmk

# Keys that hand control of the SHELL to the file are refused. `sandbox.env` is a TRACKED,
# team-shared file, so a well-formed `BASH_ENV=…` line would otherwise be exported by the
# loader and then executed by the very next child bash that build.sh/sandbox.sh spawn —
# arbitrary code out of a file the design promises is inert data.
mk; evil="$(mktemp)"; marker2="$(mktemp -u)"
printf 'touch %s\n' "$marker2" > "$evil"
printf 'BASH_ENV=%s\nIMAGE_NAME=still-parsed\n' "$evil" > "$PORTABLE"
out_deny="$( ( unset BASH_ENV IMAGE_NAME; apply; printf 'BASH_ENV=[%s] IMAGE_NAME=[%s]\n' "${BASH_ENV:-}" "${IMAGE_NAME:-}"; bash -c 'true' ) 2>&1 )"
grep -q 'BASH_ENV=\[\]' <<<"$out_deny" \
  && pass "BASH_ENV in an env file is refused (not exported)" || fail "BASH_ENV in an env file is refused (got: $out_deny)"
[[ ! -e "$marker2" ]] \
  && pass "a refused BASH_ENV cannot execute code in a child bash" || { fail "a refused BASH_ENV cannot execute code in a child bash"; rm -f "$marker2"; }
grep -q 'IMAGE_NAME=\[still-parsed\]' <<<"$out_deny" \
  && pass "a refused key does not abort parsing of later keys" || fail "a refused key does not abort parsing of later keys"
grep -qi 'WARNING' <<<"$out_deny" \
  && pass "a refused key warns on stderr" || fail "a refused key warns on stderr"
rm -f "$evil"; rmk

# ENV / SHELLOPTS / BASH_FUNC_* are refused for the same reason.
mk; printf 'ENV=/tmp/x.sh\n' > "$PORTABLE"
( unset ENV; apply; [[ -z "${ENV:-}" ]] ) 2>/dev/null \
  && pass "ENV is refused" || fail "ENV is refused"
printf 'BASH_FUNC_foo%%%%=() { echo hi; }\n' > "$PORTABLE"
( unset 'BASH_FUNC_foo%%'; apply ) >/dev/null 2>&1
pass "BASH_FUNC_* line does not crash the loader"
rmk

# Surrounding double quotes are stripped only as a MATCHED pair, so a value that
# legitimately contains a single quote character is not silently mangled.
mk; printf 'EXTRA_MOUNTS=/a"b\n' > "$PORTABLE"
( unset EXTRA_MOUNTS; apply; [[ "$EXTRA_MOUNTS" == '/a"b' ]] ) \
  && pass "an unmatched quote inside a value is preserved" || fail "an unmatched quote inside a value is preserved"
rmk

# load ORDER in sandbox-common.sh: local before portable
loc_ln=$(grep -n 'load_env_defaults .*sandbox\.local\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
por_ln=$(grep -n 'load_env_defaults .*/sandbox\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
[[ -n "$loc_ln" && -n "$por_ln" && "$loc_ln" -lt "$por_ln" ]] \
  && pass "sandbox-common.sh loads local before portable ($loc_ln<$por_ln)" \
  || fail "sandbox-common.sh loads local before portable (local=$loc_ln portable=$por_ln)"

# sandbox.sh mode/workdir defaulting (structural — matches test-env-file.sh's grep style)
grep -qF 'command="${1:-${SANDBOX_MODE:-usage}}"' "$REPO_DIR/sandbox.sh" \
  && pass "mode falls back to SANDBOX_MODE (else usage)" || fail "mode falls back to SANDBOX_MODE"
grep -qF '${2:-${SANDBOX_WORKDIR:-}}' "$REPO_DIR/sandbox.sh" \
  && pass "workdir falls back to SANDBOX_WORKDIR" || fail "workdir falls back to SANDBOX_WORKDIR"

# behavioral: a bare ./sandbox.sh with no SANDBOX_MODE resolves mode → usage (docker-free
# path — usage() just prints and exits; no run_container/docker is reached). Hermetic only
# when the repo root has no sandbox.env/sandbox.local.env (the loader would read them and
# could set SANDBOX_MODE, defeating the probe); the committed repo has neither.
if [[ ! -f "$REPO_DIR/sandbox.env" && ! -f "$REPO_DIR/sandbox.local.env" ]]; then
  sbout="$(mktemp)"
  ( unset SANDBOX_MODE SANDBOX_WORKDIR; bash "$REPO_DIR/sandbox.sh" >"$sbout" 2>&1 || true )
  grep -q '^Usage:' "$sbout" && pass "bare ./sandbox.sh (no SANDBOX_MODE) shows usage" || fail "bare ./sandbox.sh (no SANDBOX_MODE) shows usage"
  rm -f "$sbout"
else
  printf 'NOTE: skipping bare-sandbox.sh usage probe (repo-root sandbox.env/local present)\n'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
