#!/usr/bin/env bash
# Asserts the runtime agent-tool hooks are defined and wired into entrypoint.sh in all
# three modes. (grep '<name>$' matches only the call-sites; the '<name>() {' def line
# ends in '{', not the name, so it is not counted.)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
# Added for the useradd-wrapper section at the end, which extracts a function
# out of entrypoint.sh and runs it; everything above this is pure grep.
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
bash -n "$REPO_DIR/entrypoint.sh" && pass "entrypoint.sh bash -n" || fail "entrypoint.sh bash -n"
grep -q 'run_agent_tools_reconcile()' "$REPO_DIR/entrypoint.sh" && pass "defines run_agent_tools_reconcile" || fail "defines run_agent_tools_reconcile"
grep -q 'link_agent_tools()' "$REPO_DIR/entrypoint.sh" && pass "defines link_agent_tools" || fail "defines link_agent_tools"
nr="$(grep -c 'run_agent_tools_reconcile$' "$REPO_DIR/entrypoint.sh")"; [[ "$nr" -ge 3 ]] && pass "reconcile wired in 3 modes ($nr)" || fail "reconcile wired in 3 modes ($nr)"
nl="$(grep -c 'link_agent_tools$' "$REPO_DIR/entrypoint.sh")"; [[ "$nl" -ge 3 ]] && pass "linker wired in 3 modes ($nl)" || fail "linker wired in 3 modes ($nl)"

# Regression guard: every mode must print its own network-posture banner. discovery
# previously printed none — the only mode combining unrestricted egress with a pcap
# that persists on the host, and the user could not tell which mode they were in.
# Extract each case-branch body (from "<mode>)" to its ";;") and require a boxed
# banner (╔...╗) inside it, so a future edit that drops one back out fails loudly.
for m in restricted discovery open; do
  block="$(awk -v m="$m" '
    $0 ~ "^[[:space:]]*"m"\\)" {grab=1; next}
    grab && /;;/ {grab=0}
    grab {print}
  ' "$REPO_DIR/entrypoint.sh")"
  if grep -q '╔' <<<"$block"; then
    pass "$m mode prints a network-posture banner"
  else
    fail "$m mode prints a network-posture banner"
  fi
done

# ── the benign useradd warning is dropped, and nothing else is ───────────────
# `useradd warning: …'s uid 502 outside of the UID_MIN 1000 and UID_MAX 60000
# range.` fires for every macOS host user, because macOS starts human UIDs at
# 501 and shadow-utils expects 1000+. Matching the host UID is the entire point
# of this design, so that line describes the feature working — and it is one of
# the first things a new user sees on every start.
#
# Tested by EXECUTION, not by grepping for the pattern: entrypoint.sh has no
# source guard, so the function is extracted by name and run against a stubbed
# `useradd`. What matters is not that the benign line goes but that NOTHING ELSE
# does — a wrapper that swallowed a real failure would be far worse than the
# cosmetic wart it replaces.
ew_fn="$TMP/useradd-wrapper.sh"
awk '/^useradd_matching_host_uid\(\) \{/,/^\}/' "$REPO_DIR/entrypoint.sh" > "$ew_fn"
if [[ ! -s "$ew_fn" ]]; then
  fail "the useradd wrapper could be extracted from entrypoint.sh"
else
  pass "the useradd wrapper could be extracted from entrypoint.sh"
  ew_run() {   # <stderr the fake useradd emits> <its exit status> → "rc|stderr"
    ( # shellcheck source=/dev/null
      source "$ew_fn"
      useradd() { printf '%s\n' "$1" >&2; return "$2"; }
      err="$( { useradd_matching_host_uid "$1" "$2"; printf 'RC=%s' "$?" >&3; } 2>&1 3>&1 )"
      printf '%s' "$err" | tr '\n' ' ' )
  }
  out="$(ew_run "useradd warning: bob's uid 502 outside of the UID_MIN 1000 and UID_MAX 60000 range." 0)"
  case "$out" in
    *"outside of the UID_MIN"*) fail "the benign UID_MIN warning is dropped (got: $out)" ;;
    *RC=0*)                     pass "the benign UID_MIN warning is dropped, and the status is still 0" ;;
    *)                          fail "the benign UID_MIN warning is dropped (unexpected: $out)" ;;
  esac
  # THE HALF THAT MATTERS. A real failure must survive the filter, message and
  # status both, or this wrapper has turned a cosmetic problem into a silent one.
  out="$(ew_run "useradd: UID 502 is not unique" 4)"
  case "$out" in
    *"is not unique"*RC=4*) pass "a real useradd failure keeps both its message and its exit status" ;;
    *)                      fail "a real useradd failure keeps both its message and its exit status (got: $out)" ;;
  esac
fi

# And the call site actually uses it — the wrapper can be perfect and unreached.
grep -q 'useradd_matching_host_uid -M -s /bin/bash' "$REPO_DIR/entrypoint.sh" \
  && pass "setup_sandbox_user calls the wrapper, not useradd directly" \
  || fail "setup_sandbox_user calls the wrapper, not useradd directly"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
