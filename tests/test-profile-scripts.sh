#!/usr/bin/env bash
# tests/test-profile-scripts.sh — the files the Dockerfile writes into
# /etc/profile.d are read by every POSIX shell, not only bash.
#
# /etc/profile sources /etc/profile.d/*.sh in whatever shell reads it: `sh -l`
# is dash in the image. ai-tools.sh defined a function named npm-agent-tools,
# which dash refuses to parse, so `sh -l` stopped there with "Bad function
# name"; rvm.sh called `source`, which dash does not have, and its trailing
# `[ -s … ] && source …` made sourcing it return 1 for a user without ~/.rvm
# (bugs review RT-12 and its review).
#
# The files are generated here by the Dockerfile's own printf lines, run under
# the Dockerfile's SHELL, so this test reads what the image gets: a change to
# those lines is a change to this test's input, never a copy that drifts. Each
# is then sourced under dash (skipped where there is none, as on macOS), bash,
# and bash in posix mode, which refuses the function's name too. Case 310 runs
# ai-tools.sh in the real image.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DF="$REPO_DIR/Dockerfile"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"; trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# gen <first-line-pattern> <redirect-pattern> <out>: the Dockerfile lines from
# the printf that starts at <first-line-pattern> to the line holding
# <redirect-pattern>, with that redirect pointed at <out>, run as the RUN would.
gen() {
  local start="$1" redir="$2" out="$3" snippet
  # Through ENVIRON, not -v: awk processes escapes in a -v value, and the
  # patterns hold a literal backslash-n.
  snippet="$(GEN_S="$start" GEN_R="$redir" awk '
    index($0, ENVIRON["GEN_S"]) { p = 1 }
    p { print }
    p && index($0, ENVIRON["GEN_R"]) { exit }' "$DF")"
  [[ -n "$snippet" && "$snippet" == *"$redir"* ]] || return 1
  snippet="${snippet/"$redir"/"> $out"}"
  snippet="${snippet%%&& \\}"; snippet="${snippet%\\}"
  bash -euo pipefail -c "$snippet"
}

AI="$TMP/ai-tools.sh"; RVM="$TMP/rvm.sh"
gen "printf '%s\\n' \\" "| tee /etc/profile.d/ai-tools.sh >> /etc/bash.bashrc" "$AI" && [[ -s "$AI" ]] \
  || { printf 'SCAFFOLD-FAILED: could not generate ai-tools.sh from the Dockerfile\n'; exit 1; }
gen "printf '%s\\n%s\\n' \\" "> /etc/profile.d/rvm.sh" "$RVM" && [[ -s "$RVM" ]] \
  || { printf 'SCAFFOLD-FAILED: could not generate rvm.sh from the Dockerfile\n'; exit 1; }

# ── under dash ──
if command -v dash >/dev/null 2>&1; then
  H="$TMP/home-dash"; mkdir -p "$H"
  for f in "$AI" "$RVM"; do
    out="$(HOME="$H" dash -c ". '$f'; echo \"rc=\$?\"" 2>&1)"
    [[ "$out" == "rc=0" ]] && pass "dash sources $(basename "$f") cleanly, status 0" \
      || fail "dash and $(basename "$f"): $out"
    # With set -e, as a strict profile might be: the file must not end the shell.
    out="$(HOME="$H" dash -c "set -e; . '$f'; echo after" 2>&1)"
    [[ "$out" == after ]] && pass "  … and under set -e" || fail "dash, set -e and $(basename "$f"): $out"
  done
  # A user who has ~/.rvm: dash must not try to source it.
  mkdir -p "$H/.rvm/scripts"; printf 'echo SOURCED\n' > "$H/.rvm/scripts/rvm"
  out="$(HOME="$H" dash -c ". '$RVM'; echo rc=\$?" 2>&1)"
  [[ "$out" == "rc=0" ]] && pass "dash does not try to source ~/.rvm/scripts/rvm" \
    || fail "dash and a user's ~/.rvm: $out"
else
  printf 'SKIP: no dash here; the dash checks run on Linux\n'
fi

# ── under bash ──
H="$TMP/home-bash"; mkdir -p "$H/.rvm/scripts"; printf 'RVM_LOADED=1\n' > "$H/.rvm/scripts/rvm"
out="$(HOME="$H" bash -c ". '$AI'; type -t npm-agent-tools" 2>&1)"
[[ "$out" == function ]] && pass "bash defines npm-agent-tools" || fail "bash and npm-agent-tools: $out"
# It forwards its arguments intact, with --prefix first, expanding HOME at call time.
out="$(HOME="$H" bash -c ". '$AI'; npm() { printf '[%s]' \"\$@\"; }; npm-agent-tools 'a b' '' 'c*d'" 2>&1)"
[[ "$out" == "[--prefix][$H/.ai-tools/npm][a b][][c*d]" ]] && pass "npm-agent-tools forwards its arguments intact" \
  || fail "npm-agent-tools arguments: $out"
out="$(HOME="$H" bash -c ". '$RVM'; echo \"\${RVM_LOADED:-no}\"" 2>&1)"
[[ "$out" == 1 ]] && pass "bash sources ~/.rvm/scripts/rvm when it is there" || fail "bash and rvm.sh: $out"
H2="$TMP/home-norvm"; mkdir -p "$H2"
out="$(HOME="$H2" bash -c "set -e; . '$RVM'; echo after" 2>&1)"
[[ "$out" == after ]] && pass "  … and returns 0 for a user without one, under set -e" || fail "bash, set -e and rvm.sh: $out"

# ── bash in posix mode: the image's bash 5.2 refuses the function's name there,
# fatally (`not a valid identifier`); 5.3 accepts it. The guard skips it in
# posix mode on every version, which is what is asserted: sourced cleanly, and
# no function.
out="$(HOME="$H" bash -c "set -o posix; . '$AI'; echo \"rc=\$? fn=\$(type -t npm-agent-tools)\"" 2>&1)"
[[ "$out" == "rc=0 fn=" ]] && pass "posix-mode bash sources ai-tools.sh cleanly, without the function" \
  || fail "posix-mode bash and ai-tools.sh: $out"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
