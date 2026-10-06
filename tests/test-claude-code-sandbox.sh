#!/usr/bin/env bash
# Unit tests for the `claude-code-sandbox` sandbox.conf key.
#
# The key buys three things: the bubblewrap + socat packages and the managed
# settings file at build time (one build arg), and the two --security-opt flags
# bubblewrap needs at run time, one of which names the seccomp profile this repo
# ships (Part D holds that file to what it promises). These are wiring
# assertions. That bubblewrap then starts inside a container run with those flags
# is a claim no hermetic test can make; it needs a Docker host.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
trap 'rm -rf "${TMP:-}" "${F1:-}"' EXIT

# ── Part A: build.sh — the build arg ───────────────────────────────────────────
for state in ON OFF; do
  F1="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  printf '# schema-version: 4\nclaude-code-sandbox=%s\n' "$state" > "$F1/sandbox.conf"
  want=0; [[ "$state" == ON ]] && want=1
  out="$(
    export SANDBOX_CONF="$F1/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    printf '%s\n' "${args[@]}"
  )"
  if grep -qx "INSTALL_CLAUDE_CODE_SANDBOX=$want" <<<"$out"; then
    pass "claude-code-sandbox=$state: INSTALL_CLAUDE_CODE_SANDBOX=$want"
  else
    fail "claude-code-sandbox=$state: INSTALL_CLAUDE_CODE_SANDBOX=$want"
  fi
  rm -rf "$F1"
done

# ── Part B: sandbox.sh — the run flags ─────────────────────────────────────────
# A fake `docker` on PATH captures the assembled `docker run` argv, the harness
# test-tool-config-mounts.sh established. No daemon involved.
REAL_HOME="$HOME"
cs_setup() {  # $1 = sandbox.conf body
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  export HOME="$TMP/home"; mkdir -p "$HOME"
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP CONTAINER_SHM_SIZE
  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 4\n%s\n' "$1" > "$SANDBOX_CONF"
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin" "$TMP/app" "$TMP/launch"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
cs_teardown() {
  rm -rf "$TMP"
  unset SANDBOX_CONF AI_CONTAINER_GROUP_INIT SANDBOX_USER
  export HOME="$REAL_HOME"
}
cs_run() { ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) >/dev/null 2>&1 </dev/null; }

cs_setup 'claude-code-sandbox=ON'
cs_run
security_opts="$(grep -A1 -x -- '--security-opt' "$CAPTURE")"
if grep -qx -- 'apparmor=ai-containers-sandbox' <<<"$security_opts"; then
  pass "claude-code-sandbox=ON: --security-opt apparmor=ai-containers-sandbox"
else
  fail "claude-code-sandbox=ON: --security-opt apparmor=ai-containers-sandbox"
fi
# The seccomp profile goes by path: the Docker client reads the file and sends it
# with the container. It is the one shipped beside sandbox.sh — never `unconfined`.
seccomp_opt="$(grep -x -- 'seccomp=.*' <<<"$security_opts")"
if [[ "$seccomp_opt" == seccomp=*/ai-containers-sandbox.seccomp.json && -f "${seccomp_opt#seccomp=}" ]]; then
  pass "claude-code-sandbox=ON: --security-opt seccomp=<the shipped profile>"
else
  fail "claude-code-sandbox=ON: --security-opt seccomp=<the shipped profile> — got: ${seccomp_opt:-none}"
fi
cs_teardown

# OFF: every container that does not ask for the inner sandbox keeps Docker's
# default profiles — the flags must not leak into it.
cs_setup 'claude-code-sandbox=OFF'
cs_run
if [[ -s "$CAPTURE" ]] && ! grep -q -- '--security-opt' "$CAPTURE"; then
  pass "claude-code-sandbox=OFF: no --security-opt flag"
else
  fail "claude-code-sandbox=OFF: no --security-opt flag"
fi
cs_teardown

# The profile not loaded where Docker's kernel runs: a container started without
# it would stop every Claude Code session (failIfUnavailable), so sandbox.sh probes
# with a throwaway container first and stops, saying how to load it. The fake
# docker fails that probe — `--entrypoint true` — the way the daemon does.
probe_refuses() {  # $1 = the error Docker prints for the probe container
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then
  shift
  prev=""
  for a in "\$@"; do
    if [[ "\$prev" == "--entrypoint" && "\$a" == "true" ]]; then
      echo "$1" >&2
      exit 125
    fi
    prev="\$a"
  done
  printf '%s\n' "\$@" > "$CAPTURE"; exit 0
fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
}
cs_setup 'claude-code-sandbox=ON'
probe_refuses "docker: Error response from daemon: AppArmor enabled on system but the ai-containers-sandbox profile could not be loaded"
err="$( ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) 2>&1 >/dev/null </dev/null )"; rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "claude-code-sandbox=ON, profile not loaded: sandbox.sh stops"
else
  fail "claude-code-sandbox=ON, profile not loaded: sandbox.sh stops"
fi
if [[ ! -s "$CAPTURE" ]]; then
  pass "claude-code-sandbox=ON, profile not loaded: no container is started"
else
  fail "claude-code-sandbox=ON, profile not loaded: no container is started"
fi
if grep -qF 'apparmor_parser -r' <<<"$err" && grep -qF 'ai-containers-sandbox.apparmor' <<<"$err"; then
  pass "claude-code-sandbox=ON, profile not loaded: the message says how to load it"
else
  fail "claude-code-sandbox=ON, profile not loaded: the message says how to load it"
fi
cs_teardown

# A refusal that is not AppArmor's — the seccomp profile unreadable or rejected,
# say — is shown as Docker gave it, never as the load commands for a profile that
# may well be loaded.
cs_setup 'claude-code-sandbox=ON'
probe_refuses "docker: Error response from daemon: Decoding seccomp profile failed: invalid character"
err="$( ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) 2>&1 >/dev/null </dev/null )"; rc=$?
if [[ "$rc" -ne 0 && ! -s "$CAPTURE" ]]; then
  pass "claude-code-sandbox=ON, another refusal: sandbox.sh stops and starts no container"
else
  fail "claude-code-sandbox=ON, another refusal: sandbox.sh stops and starts no container"
fi
if grep -qF 'Decoding seccomp profile failed' <<<"$err" && ! grep -qF 'apparmor_parser' <<<"$err"; then
  pass "claude-code-sandbox=ON, another refusal: Docker's error is shown, not the AppArmor load commands"
else
  fail "claude-code-sandbox=ON, another refusal: Docker's error is shown, not the AppArmor load commands"
fi
cs_teardown

# ── Part C: the managed settings file holds the boundary ───────────────────────
# Each line below is a property the docs page promises; a settings edit that
# drops one turns the sandbox back into a prompt-saver Claude can step out of.
S="$REPO_DIR/claude-managed-settings.json"
for want in '"enabled": true' '"failIfUnavailable": true' '"allowUnsandboxedCommands": false' \
            '"strictAllowlist": true' '"name": "GITHUB_PERSONAL_ACCESS_TOKEN", "mode": "deny"' \
            '"name": "COPILOT_GITHUB_TOKEN", "mode": "deny"'; do
  if grep -qF -- "$want" "$S"; then pass "managed settings: $want"; else fail "managed settings: $want"; fi
done
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$S" 2>/dev/null; then
    pass "managed settings: valid JSON"
  else
    fail "managed settings: valid JSON"
  fi
fi

# ── Part D: the seccomp profile frees what bubblewrap needs, and nothing else ──
# Docker's default profile with clone (namespace flags included), unshare, mount,
# umount2 and pivot_root allowed to a container without CAP_SYS_ADMIN. Everything
# else Docker reserves for CAP_SYS_ADMIN — setns, bpf, sethostname and the rest —
# must stay reserved: a widened rule would hand every agent in the container more
# than bubblewrap asks for.
P="$REPO_DIR/ai-containers-sandbox.seccomp.json"
if command -v python3 >/dev/null 2>&1; then
  out="$(python3 - "$P" 2>&1 <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
rules = p["syscalls"]
def plain(r):
    return r["action"] == "SCMP_ACT_ALLOW" and not r.get("args") and not r.get("includes") and not r.get("excludes")
free = {n for r in rules if plain(r) for n in r["names"]}
admin = {n for r in rules if (r.get("includes") or {}).get("caps") == ["CAP_SYS_ADMIN"] for n in r["names"]}
five = {"clone", "unshare", "mount", "umount2", "pivot_root"}
print("refuses-by-default" if p["defaultAction"] == "SCMP_ACT_ERRNO" else "default: " + p["defaultAction"])
print("frees-the-five" if five <= free else "not freed: %s" % sorted(five - free))
print("rest-stays-reserved" if not (admin - five) & free else "freed beyond the five: %s" % sorted((admin - five) & free))
print("admin-rule-intact" if {"setns", "unshare", "bpf", "sethostname"} <= admin else "CAP_SYS_ADMIN rule changed")
print("clone3-enosys" if any(r["names"] == ["clone3"] and r["action"] == "SCMP_ACT_ERRNO" and r.get("errnoRet") == 38 for r in rules) else "clone3 rule changed")
print("no-filtered-clone" if not any("clone" in r["names"] and r.get("args") for r in rules) else "an argument-filtered clone rule is left")
PY
)"
  for want in "refuses-by-default:refuses any syscall it does not list (SCMP_ACT_ERRNO)" \
              "frees-the-five:allows clone, unshare, mount, umount2 and pivot_root to a container without CAP_SYS_ADMIN" \
              "rest-stays-reserved:keeps the rest of what Docker reserves for CAP_SYS_ADMIN reserved" \
              "admin-rule-intact:keeps Docker's CAP_SYS_ADMIN rule (setns, unshare, bpf, sethostname)" \
              "clone3-enosys:still answers clone3 with ENOSYS, so glibc falls back to clone" \
              "no-filtered-clone:leaves no argument-filtered clone rule beside the unconditional one"; do
    if grep -qx -- "${want%%:*}" <<<"$out"; then
      pass "seccomp profile: ${want#*:}"
    else
      fail "seccomp profile: ${want#*:} — got: $(tr '\n' ' ' <<<"$out")"
    fi
  done
fi

[[ $fails -eq 0 ]] && exit 0 || exit 1
