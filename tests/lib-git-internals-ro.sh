#!/usr/bin/env bash
# tests/lib-git-internals-ro.sh — what the tests/test-git-internals-ro-*.sh files
# share: a project and its working copy in a git repository, a fake docker that
# records the launch, and the helpers that launch it and read what it mounted.
# Sourced, never run.
#
# What the HOST's git runs from a repository must not be writable from inside
# the container: its hooks/, and config, whose keys run programs (core.hooksPath,
# core.fsmonitor, core.sshCommand, filters). sandbox.sh mounts them read-only
# inside every writable mount that exposes a git directory, pins the directories
# above them so .git cannot be renamed away, and leaves objects, refs and the
# index writable (launcher_ro_overlay, git_dirs_in). What it cannot freeze is
# named: a hook that links out, an include of a file the agent can write, and —
# once, at the first protection — the keys a config already sets that run programs.
#
# The five files were one, tests/test-git-internals-ro.sh (checks G1 to G99, 204
# check lines), until 2026-11-04: split by area so the mutation tier's oracle
# selection can run only the files a mutated line reaches (feature-gaps review
# GAP-2). Each keeps its checks' G numbers.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/sandbox.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
# shellcheck source=tests/portability.sh
source "$ROOT/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
# Physical path: on macOS mktemp hands out /var/..., a symlink to /private/var/...,
# and sandbox.sh resolves every mount source.
TMP="$(cd "$TMP" && pwd -P)"
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; export HOME="$REAL_HOME"; }' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH \
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE SANDBOX_GIT_MAX SANDBOX_LAUNCHER_MAX
# The repositories below are made with the test's own identity, never the host's.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main)
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE.calls"
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
  prev=""
  for a in "\$@"; do
    if [[ "\$prev" == -v && "\$a" == *:/run/ai-launcher:ro ]]; then
      cp "\${a%:/run/ai-launcher:ro}/manifest" "$CAPTURE.manifest" 2>/dev/null
    fi
    prev="\$a"
  done
  # What the agent does during the session (G94), and how the container exits.
  if [[ -n "\${FAKE_SESSION:-}" ]]; then bash -c "\$FAKE_SESSION"; fi
  exit "\${FAKE_DOCKER_RC:-0}"
fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF; : > "$SANDBOX_CONF"

# A project's working copy, as project-init.sh lays it out, in a git repository.
# shellcheck source=shared-files.sh
source "$ENGINE/shared-files.sh"
PROJ="$TMP/proj"; LAUNCHER="$PROJ/.ai-containers"
mkdir -p "$LAUNCHER" "$TMP/app"
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$LAUNCHER/$f"; done
cp -R "$ENGINE/tools.d" "$LAUNCHER/"
# services.d only where the engine has one: mgd-ai-containers has no database servers.
[[ ! -d "$ENGINE/services.d" ]] || cp -R "$ENGINE/services.d" "$LAUNCHER/"
"${G[@]}" -C "$PROJ" init -q && printf 'x\n' > "$PROJ/README" && "${G[@]}" -C "$PROJ" add README \
  && "${G[@]}" -C "$PROJ" commit -qm init \
  || { printf 'SCAFFOLD-FAILED: cannot create the project repository\n'; exit 1; }

ERR="$TMP/err.txt"
launch() {  # $1 = primary; extra env via the caller's `VAR=x launch …`
  rm -f "$CAPTURE" "$CAPTURE.manifest" "$CAPTURE.calls"
  ( cd "$LAUNCHER" && bash ./sandbox.sh restricted "$1" ) >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?
}
# Every mount, rendered `src:dst:opts`, whether docker got it as -v or --mount.
mounts() {
  awk '
    function csv(s, f,   n, i, c, q, cur) {
      n = 0; cur = ""; q = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q) {
          if (c == "\"") { if (substr(s, i + 1, 1) == "\"") { cur = cur "\""; i++ } else q = 0 }
          else cur = cur c
        } else if (c == "\"") q = 1
        else if (c == ",") { f[++n] = cur; cur = "" }
        else cur = cur c
      }
      f[++n] = cur
      return n
    }
    prev == "-v" { print }
    prev == "--mount" {
      n = csv($0, f); src = dst = ""; ro = 0
      for (k = 1; k <= n; k++) {
        if (f[k] ~ /^source=/)           src = substr(f[k], 8)
        else if (f[k] ~ /^destination=/) dst = substr(f[k], 13)
        else if (f[k] == "readonly" || f[k] == "ro") ro = 1
      }
      printf "%s:%s:%s\n", src, dst, (ro ? "ro" : "rw")
    }
    { prev = $0 }
  ' "$CAPTURE" 2>/dev/null
}
has_mount() { grep -qxF -- "$1" <<<"$(mounts)"; }
# The git-related mounts: anything whose source is or lies under a .git, plus
# pins (src == dst's host path) of the directories above one.
git_mounts() { mounts | grep -E '/\.git(:|/)' || true; }


# shellcheck disable=SC2034  # LAUNCH_S is read by the test files that source this
launch_timed() {  # $1 = seconds; leaves LAUNCH_RC (124 on timeout) and LAUNCH_S
  local t0=$SECONDS
  rm -f "$CAPTURE" "$CAPTURE.manifest"
  p_timeout "$1" bash -c 'cd "$1" && exec bash ./sandbox.sh restricted ..' _ "$LAUNCHER" >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?; LAUNCH_S=$((SECONDS - t0))
}

# Loads one function from the launcher, which cannot be sourced whole (it runs).
load_fn() { eval "$(awk -v f="$1() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh")"; }

# gi_warm_up: the launch G1 makes, for a file without G1: every check after it
# was written against a project already protected once. One that fails is a
# FAIL:, as G1 reports it — the code's, never SCAFFOLD-FAILED, which the mutation
# tier reads as the environment's and would score a killing mutant UNPROVEN
# (review of the split) — and the checks after it run, as they did after G1.
gi_warm_up() {
  launch ..
  [[ "$LAUNCH_RC" == 0 ]] || fail "the first launch of the project failed (rc=$LAUNCH_RC: $(tail -2 "$ERR" | tr '\n' ' '))"
}
