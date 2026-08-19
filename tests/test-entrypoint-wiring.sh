#!/usr/bin/env bash
# Asserts the runtime agent-tool hooks are defined and wired into entrypoint.sh in all
# three modes. (grep '<name>$' matches only the call-sites; the '<name>() {' def line
# ends in '{', not the name, so it is not counted.)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
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

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
