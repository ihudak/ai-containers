#!/usr/bin/env bash
# The launcher's own directory is read-only inside the container.
#
# A project's .ai-containers/ holds what the HOST runs next time: sandbox.sh,
# build.sh, the Dockerfile and entrypoint it builds, sandbox.env (SANDBOX_MODE,
# EXTRA_MOUNTS), sandbox.conf and container.env. The default launch mounts the
# whole project read-write (SANDBOX_WORKDIR=..), so without an overlay the agent
# could rewrite any of them — and .ai-containers/ is gitignored, so `git status`
# would never show it. sandbox.sh therefore mounts its own directory again,
# :ro, on top of every writable bind mount that contains it.
#
# Hermetic: fake `docker` capturing the run args, no daemon. Integration case
# 450-launcher-dir-read-only checks that the overlay is actually read-only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/sandbox.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
# Physical path: on macOS mktemp hands out /var/..., which is a symlink to
# /private/var/..., and sandbox.sh resolves every mount source.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH \
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF; : > "$SANDBOX_CONF"

# A project's working copy, as project-init.sh / sync-to-projects.sh lay it out.
# shellcheck source=shared-files.sh
source "$ENGINE/shared-files.sh"
PROJ="$TMP/proj"; LAUNCHER="$PROJ/.ai-containers"
mkdir -p "$LAUNCHER" "$TMP/app" "$TMP/pro"
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$LAUNCHER/$f"; done
cp -R "$ENGINE/tools.d" "$ENGINE/services.d" "$LAUNCHER/"
ln -s "$PROJ" "$TMP/link"

# $1 = directory to launch from (the engine copy), $2 = primary. Extra env via
# the caller's `VAR=x launch ...`. Leaves the run args in $CAPTURE, stderr in $ERR.
ERR="$TMP/err.txt"
launch() {
  : > "$CAPTURE"
  ( cd "$1" && bash ./sandbox.sh restricted "$2" ) >/dev/null 2>"$ERR" </dev/null
}
# Every `-v` value, one per line.
mounts() { awk 'prev=="-v"{print} {prev=$0}' "$CAPTURE"; }
ro_overlays() { mounts | grep -F -- "$LAUNCHER:" | grep ':ro$'; }

# ── T1: the documented launch — project mounted rw, its .ai-containers ro on top
launch "$LAUNCHER" ..
if [[ -s "$CAPTURE" ]]; then pass "T1 sandbox.sh reached docker run"
else fail "T1 sandbox.sh reached docker run (no args captured)"; tail -5 "$ERR"; fi
mounts | grep -qx -- "$PROJ:/workspace/proj:rw" \
  && pass "T1 the project itself is still mounted read-write" \
  || fail "T1 the project itself is still mounted read-write (mounts: $(mounts | tr '\n' ' '))"
[[ "$(ro_overlays)" == "$LAUNCHER:/workspace/proj/.ai-containers:ro" ]] \
  && pass "T1 .ai-containers is mounted again, read-only, at its place inside the project" \
  || fail "T1 read-only overlay (got: $(ro_overlays | tr '\n' ' '))"
grep -qF '/workspace/proj/.ai-containers' "$ERR" && grep -qi 'read-only' "$ERR" \
  && pass "T1 the launch says which path is read-only" \
  || fail "T1 the launch says which path is read-only (stderr: $(tr '\n' ' ' <"$ERR"))"

# ── T2: a primary that does not contain the launcher → no overlay
launch "$LAUNCHER" "$TMP/app"
[[ -s "$CAPTURE" && -z "$(ro_overlays)" ]] \
  && pass "T2 no overlay when no mount contains the launcher" \
  || fail "T2 no overlay when no mount contains the launcher (got: $(ro_overlays | tr '\n' ' '))"

# ── T3: a writable EXTRA_MOUNTS parent contains it → overlay at that mount's path
EXTRA_MOUNTS="$TMP" launch "$LAUNCHER" "$TMP/app"
tbase="$(basename "$TMP")"
[[ "$(ro_overlays)" == "$LAUNCHER:/workspace/$tbase/proj/.ai-containers:ro" ]] \
  && pass "T3 a writable EXTRA_MOUNTS parent gets the overlay at its own path" \
  || fail "T3 EXTRA_MOUNTS parent (got: $(ro_overlays | tr '\n' ' '))"

# ── T4: the same parent mounted :ro is already read-only → nothing added
EXTRA_MOUNTS="$TMP:ro" launch "$LAUNCHER" "$TMP/app"
[[ -s "$CAPTURE" && -z "$(ro_overlays)" ]] \
  && pass "T4 a :ro parent needs no overlay" \
  || fail "T4 a :ro parent needs no overlay (got: $(ro_overlays | tr '\n' ' '))"

# ── T5: two writable mounts contain it → one overlay under each
EXTRA_MOUNTS="$TMP" launch "$LAUNCHER" ..
want="$(printf '%s\n' "$LAUNCHER:/workspace/$tbase/proj/.ai-containers:ro" \
                      "$LAUNCHER:/workspace/proj/.ai-containers:ro" | sort)"
[[ "$(ro_overlays | sort)" == "$want" ]] \
  && pass "T5 every writable mount that contains it gets its own overlay" \
  || fail "T5 two containing mounts (got: $(ro_overlays | tr '\n' ' '))"

# ── T6: a sibling whose NAME is a prefix of the project's does not contain it
EXTRA_MOUNTS="$TMP/pro" launch "$LAUNCHER" "$TMP/app"
[[ -s "$CAPTURE" && -z "$(ro_overlays)" ]] \
  && pass "T6 $TMP/pro does not contain $TMP/proj/.ai-containers" \
  || fail "T6 prefix is not containment (got: $(ro_overlays | tr '\n' ' '))"

# ── T7: launched through a symlinked path → still found, resolved
launch "$TMP/link/.ai-containers" ..
[[ "$(ro_overlays)" == "$LAUNCHER:/workspace/proj/.ai-containers:ro" ]] \
  && pass "T7 a launch through a symlinked path still gets the overlay" \
  || fail "T7 symlinked launch path (got: $(ro_overlays | tr '\n' ' '))"

# ── T8: the launcher directory IS the mount (developing the engine itself) →
# it cannot be read-only without making the work impossible; say so instead.
launch "$LAUNCHER" .
mounts | grep -qx -- "$LAUNCHER:/workspace/.ai-containers:rw" \
  && [[ -z "$(ro_overlays)" ]] \
  && pass "T8 the launcher's own directory as the working dir stays writable" \
  || fail "T8 launcher dir as primary (mounts: $(mounts | tr '\n' ' '))"
grep -q 'NOTE:.*writable' "$ERR" \
  && pass "T8 ... and the launch says so" \
  || fail "T8 ... and the launch says so (stderr: $(tr '\n' ' ' <"$ERR"))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
