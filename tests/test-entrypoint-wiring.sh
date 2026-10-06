#!/usr/bin/env bash
# Asserts the runtime agent-tool hooks are defined and wired into entrypoint.sh in all
# three modes. (grep '<name>$' matches only the call-sites; the '<name>() {' def line
# ends in '{', not the name, so it is not counted.)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
# Added for the useradd-wrapper section at the end, which extracts a function
# out of entrypoint.sh and runs it; everything above this is pure grep.
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
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

# ── in-container database servers ──────────────────────────────────────────────
# Grep-level, like the rest of this file: entrypoint.sh runs as root and is
# GREPPED-ONLY in the falsify tier. That a real server starts is integration case
# 780-postgres-server-runs. run_services deliberately takes NO env override for
# the runner's path — an override would let a project's data file choose what
# root executes. start gets container.env back (stash_app_env), minus the
# runner's test-only path knobs.
grep -q '^run_services() {' "$REPO_DIR/entrypoint.sh" && pass "defines run_services" || fail "defines run_services"
ns="$(grep -c '^[[:space:]]*run_services$' "$REPO_DIR/entrypoint.sh")"
[[ "$ns" -ge 3 ]] && pass "run_services wired in 3 modes ($ns)" || fail "run_services wired in 3 modes ($ns)"
grep -q 'runuser -u "$sandbox_user" -- env -u AI_SERVICES_DIR -u AI_SERVICES_STATE_ROOT -u AI_SERVICES_LOG_ROOT \\$' "$REPO_DIR/entrypoint.sh" \
  && grep -qF '    ${start_env[@]+"${start_env[@]}"} /usr/local/bin/start-services.sh start || true' "$REPO_DIR/entrypoint.sh" \
  && pass "the start phase runs as the sandbox user" \
  || fail "the start phase runs as the sandbox user"
# The sandbox-user start strips the test-only path overrides; root's prepare
# goes further (env -i, below), so exactly one invocation uses the strip list.
nstrip="$(grep -c 'env -u AI_SERVICES_DIR -u AI_SERVICES_STATE_ROOT -u AI_SERVICES_LOG_ROOT' "$REPO_DIR/entrypoint.sh")"
[[ "$nstrip" -eq 1 ]] && pass "the start invocation strips the path overrides ($nstrip)" || fail "the start invocation strips the path overrides ($nstrip)"
grep -q '^  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\$' "$REPO_DIR/entrypoint.sh" \
  && pass "the prepare invocation starts from an empty environment (env -i, fixed PATH)" \
  || fail "the prepare invocation starts from an empty environment (env -i, fixed PATH)"
grep -q 'AI_SERVICES_RUNNER' "$REPO_DIR/entrypoint.sh" \
  && fail "run_services takes no env override for the runner path" \
  || pass "run_services takes no env override for the runner path"

# ── what reaches each phase, by EXECUTION ─────────────────────────────────────
# container.env (project-writable, and writable from inside the container)
# reaches this ROOT process. In `prepare` the postgres adapter EXECUTES
# "<lib root>/<major>/bin/postgres --version" and mkdirs+chowns its socket dir,
# so any variable that reaches root's prepare can choose a binary root runs or a
# path root chowns. The claim is therefore about what does NOT arrive.
#
# run_services is extracted by name and run with its fixed runner path pointed
# at a fake that records the environment it was given. runuser is a stub that
# checks its `-u <user> --` shape and runs the rest; everything else is real.
rs_fn="$TMP/run-services.sh"; rs_fake="$TMP/fake-start-services.sh"
cat > "$rs_fake" <<FAKE
#!/bin/sh
env > "$TMP/env.\$1"
FAKE
chmod +x "$rs_fake"
awk '/^run_services\(\) \{/,/^\}/' "$REPO_DIR/entrypoint.sh" \
  | sed "s#/usr/local/bin/start-services.sh#$rs_fake#g" > "$rs_fn"
n_fake="$(grep -c "$rs_fake" "$rs_fn")"
if [[ "$n_fake" -lt 3 ]]; then
  fail "run_services could be extracted with its runner path replaced in all 3 places (got $n_fake)"
else
  pass "run_services could be extracted with its runner path replaced in all 3 places"
  rm -f "$TMP"/env.*
  ( # shellcheck source=/dev/null
    source "$rs_fn"
    runuser() { [[ "${1:-}" == -u && "${2:-}" == alice && "${3:-}" == -- ]] || return 97; shift 3; "$@"; }
    # shellcheck disable=SC2034  # read by the extracted run_services, which shellcheck cannot see
    sandbox_user=alice
    export AI_SERVICES=postgres=ON SANDBOX_UID=4242 SANDBOX_GID=4343 \
           AI_SERVICES_DIR=/evil AI_SERVICES_STATE_ROOT=/evil AI_SERVICES_LOG_ROOT=/evil \
           AI_SERVICES_PG_LIB_ROOT=/evil AI_SERVICES_PG_MAJOR_FILE=/evil AI_SERVICES_PG_SOCKET_DIR=/etc \
           PG_LIB_ROOT=/evil POSTGRES_ROLES=app_user DATABASE_URL=postgres://app_user@localhost/myapp_test
    run_services ) >/dev/null 2>&1
  # A shell adds its own PWD/SHLVL/_ to whatever it was handed; those are the
  # fake's, not the caller's.
  prep_names="$(sed -n 's/=.*//p' "$TMP/env.prepare" 2>/dev/null | grep -vxE 'PWD|OLDPWD|SHLVL|_' | sort | tr '\n' ' ')"
  [[ "$prep_names" == "AI_SERVICES PATH SANDBOX_GID SANDBOX_UID " ]] \
    && pass "root's prepare receives exactly AI_SERVICES, PATH, SANDBOX_UID, SANDBOX_GID" \
    || fail "root's prepare receives exactly AI_SERVICES, PATH, SANDBOX_UID, SANDBOX_GID (got: ${prep_names:-no prepare run at all})"
  prep_vals="$(grep -E '^(AI_SERVICES|PATH|SANDBOX_UID|SANDBOX_GID)=' "$TMP/env.prepare" 2>/dev/null | sort | tr '\n' ' ')"
  [[ "$prep_vals" == "AI_SERVICES=postgres=ON PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin SANDBOX_GID=4343 SANDBOX_UID=4242 " ]] \
    && pass "those four carry the caller's AI_SERVICES/SANDBOX_UID/SANDBOX_GID and a fixed PATH" \
    || fail "prepare's four values (got: $prep_vals)"
  start_env="$(cat "$TMP/env.start" 2>/dev/null)"
  if [[ -z "$start_env" ]]; then
    fail "the start phase ran (via runuser -u <sandbox user> --) — nothing was recorded"
  else
    pass "the start phase ran (via runuser -u <sandbox user> --)"
    grep -qE '^AI_SERVICES_(DIR|STATE_ROOT|LOG_ROOT)=' <<<"$start_env" \
      && fail "start receives no AI_SERVICES_DIR/_STATE_ROOT/_LOG_ROOT" \
      || pass "start receives no AI_SERVICES_DIR/_STATE_ROOT/_LOG_ROOT"
    grep -qx 'POSTGRES_ROLES=app_user' <<<"$start_env" \
      && pass "start still receives container.env (POSTGRES_ROLES), which it needs" \
      || fail "start still receives container.env (POSTGRES_ROLES)"
  fi
fi
# LAST before the exec in each mode, so the ready line is the last thing printed
# before the prompt.
for m in restricted discovery open; do
  block="$(awk -v m="$m" '
    $0 ~ "^[[:space:]]*"m"\\)" {grab=1; next}
    grab && /;;/ {grab=0}
    grab {print}
  ' "$REPO_DIR/entrypoint.sh")"
  order="$(grep -E '^[[:space:]]*(run_agent_skill_install|run_services|exec capsh)' <<<"$block" \
           | awk '{print $1}' | tr '\n' ' ')"
  [[ "$order" == "run_agent_skill_install run_services exec " ]] \
    && pass "$m: run_services runs after the skill install and immediately before exec capsh" \
    || fail "$m: run_services order (got: $order)"
done

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
