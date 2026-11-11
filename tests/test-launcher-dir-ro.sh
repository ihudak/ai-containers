#!/usr/bin/env bash
# The launcher's own directory is read-only inside the container.
#
# A project's .ai-containers/ holds what the HOST runs next time: sandbox.sh,
# build.sh, the Dockerfile and entrypoint it builds, sandbox.env (SANDBOX_MODE,
# EXTRA_MOUNTS), sandbox.conf and container.env. The default launch mounts the
# whole project read-write (SANDBOX_WORKDIR=..), so without an overlay the agent
# could rewrite any of them — and .ai-containers/ is gitignored, so `git status`
# would never show it. sandbox.sh therefore mounts its own directory again,
# :ro, inside every writable bind mount that contains it — and any other
# launcher such a mount exposes (matched by content: a dir with sandbox.sh and
# sandbox-common.sh, so an ai-containers checkout counts too) — pins every
# directory between a mount root and a launcher, and skips a launcher nested in
# another (T9–T19); robust to stray files and odd names, and warns about a
# symlink it cannot pin (T20–T23); never mounts a name docker would mangle, and
# never scans blind past a directory you cannot list (T24–T28, T31), warns
# about launcher links that lead somewhere the agent can change (T29, T32–T38),
# names a writable mount inside a launcher (T40), records every launcher
# mount for the entrypoint to re-verify against a concurrent-container swap (T41,
# T42), works with a BSD-only stat (T43) from any working directory (T45), sweeps
# only stale verify dirs and never fatally (T44), bounds what the agent can plant
# per launch (T46), and
# refuses a non-numeric identity (T30).
#
# Hermetic: fake `docker` capturing the run args, no daemon. Integration cases
# 450-launcher-dir-read-only and 455-launcher-dir-nested-mount check that the
# container the agent gets actually enforces it.
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
# Physical path: on macOS mktemp hands out /var/..., which is a symlink to
# /private/var/..., and sandbox.sh resolves every mount source.
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH \
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE SANDBOX_LAUNCHER_MAX DOCKER_HOST COLIMA_HOME
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
# The endpoint sandbox.sh asks for to tell Colima's socket (T66); none otherwise.
if [[ "\$1" == context ]]; then [[ -z "\${FAKE_DOCKER_ENDPOINT:-}" ]] || printf '%s\n' "\$FAKE_DOCKER_ENDPOINT"; exit 0; fi
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
  # Before sandbox.sh's EXIT trap removes it, copy out the verify dir's manifest
  # and its own device:inode, so the test can inspect them.
  prev=""
  for a in "\$@"; do
    if [[ "\$prev" == -v && "\$a" == *:/run/ai-launcher:ro ]]; then
      vsrc="\${a%:/run/ai-launcher:ro}"
      cp "\$vsrc/manifest" "$CAPTURE.manifest" 2>/dev/null
      printf '%s' "\$vsrc" > "$CAPTURE.vdir"
      if [[ "$_P_STAT_GNU" == 1 ]]; then stat -c '%d:%i' "\$vsrc"; else stat -f '%d:%i' "\$vsrc"; fi > "$CAPTURE.anchor" 2>/dev/null
    fi
    prev="\$a"
  done
  exit 0
fi
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
cp -R "$ENGINE/tools.d" "$LAUNCHER/"
# services.d only where the engine has one: mgd-ai-containers has no database servers.
[[ ! -d "$ENGINE/services.d" ]] || cp -R "$ENGINE/services.d" "$LAUNCHER/"
ln -s "$PROJ" "$TMP/link"

# $1 = directory to launch from (the engine copy), $2 = primary. Extra env via
# the caller's `VAR=x launch ...`. Leaves the run args in $CAPTURE, stderr in $ERR.
ERR="$TMP/err.txt"
launch() {
  : > "$CAPTURE"
  ( cd "$1" && bash ./sandbox.sh restricted "$2" ) >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?
}
# Whether an ERROR: line of the last launch names $1. Captured first: under
# pipefail `grep | grep -q` can report the opposite of what it saw.
err_names() { grep -aF "ERROR:" "$ERR" > "$TMP/err-lines.txt"; grep -aqF -- "$1" "$TMP/err-lines.txt"; }
# Every mount, rendered `src:dst[:opts]`, one per line — both the `-v` pairs the
# rest of sandbox.sh emits and the `--mount` values the launcher overlay emits.
# docker parses a --mount value as one CSV record, so this does too: quoted
# fields, `""` for a quote, commas inside quotes kept.
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
  ' "$CAPTURE"
}
# The overlay lines for THIS launcher ($LAUNCHER), read-only.
ro_overlays() { mounts | grep -F -- "$LAUNCHER:" | grep ':ro$'; }

# ── T1: the documented launch — project mounted rw, its .ai-containers ro on top
launch "$LAUNCHER" ..
if [[ -s "$CAPTURE" ]]; then pass "T1 sandbox.sh reached docker run"
else fail "T1 sandbox.sh reached docker run (no args captured)"; tail -5 "$ERR"; fi
# IMAGE_NAME can come from a committed sandbox.env: an image this machine never
# built must not be pulled from a registry and run with the group's credentials
# mounted (bugs review ENV-1, the security review of 5e338f8).
grep -qxF -- '--pull=never' "$CAPTURE" \
  && pass "T1 the launch never pulls an image (--pull=never)" \
  || fail "T1 docker run may pull the image (no --pull=never in the run args)"
[[ "${LAUNCH_RC:-1}" -eq 0 ]] && pass "T1 the launcher exits 0 (cleanup/trap included)"   || fail "T1 the launcher exits 0 — got $LAUNCH_RC ($(tail -1 "$ERR"))"
grep -qxF -- "$PROJ:/workspace/proj:rw" <<<"$(mounts)" \
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
grep -qF 'is a symlink inside a writable mount' "$ERR" \
  && fail "T7 ... and no symlink warning, since no mount contains $TMP/link (stderr: $(grep WARNING "$ERR" | tr '\n' ' '))" \
  || pass "T7 ... and no symlink warning, since no mount contains the symlink"

# ── T8: the launcher directory IS the mount (developing the engine itself) →
# it cannot be read-only without making the work impossible; say so instead.
launch "$LAUNCHER" .
grep -qxF -- "$LAUNCHER:/workspace/.ai-containers:rw" <<<"$(mounts)" \
  && [[ -z "$(ro_overlays)" ]] \
  && pass "T8 the launcher's own directory as the working dir stays writable" \
  || fail "T8 launcher dir as primary (mounts: $(mounts | tr '\n' ' '))"
grep -q 'NOTE:.*writable' "$ERR" \
  && pass "T8 ... and the launch says so" \
  || fail "T8 ... and the launch says so (stderr: $(tr '\n' ' ' <"$ERR"))"

# What lands under a destination prefix: one "<src>:<dst>:<opts>" per line.
mounts_under() { mounts | awk -F: -v p="$1" 'index($2, p) == 1'; }

# ── T9: the documented launch needs nothing between the mount root and the
# launcher — the project IS the mount root and .ai-containers its child.
launch "$LAUNCHER" ..
[[ "$(mounts_under /workspace/proj/)" == "$LAUNCHER:/workspace/proj/.ai-containers:ro" ]] \
  && pass "T9 the documented launch adds the overlay and nothing else under the project" \
  || fail "T9 only the overlay under /workspace/proj/ (got: $(mounts_under /workspace/proj/ | tr '\n' ' '))"

# ── T10: a mount rooted ABOVE the project pins every directory in between,
# each bound onto itself read-write: an ordinary directory above a mount point
# can be renamed, and the overlay would move with it.
EXTRA_MOUNTS="$TMP" launch "$LAUNCHER" "$TMP/app"
want="$(printf '%s\n' "$PROJ:/workspace/$tbase/proj:rw" \
                      "$LAUNCHER:/workspace/$tbase/proj/.ai-containers:ro")"
[[ "$(mounts_under "/workspace/$tbase/")" == "$want" ]] \
  && pass "T10 the directory between the mount root and the launcher is pinned, writable" \
  || fail "T10 pinned intermediate (got: $(mounts_under "/workspace/$tbase/" | tr '\n' ' '))"

# ── T11: deeper still — one pin per directory, in order, none twice.
DEEP="$TMP/deep"; mkdir -p "$DEEP/a/b"
cp -R "$LAUNCHER" "$DEEP/a/b/"
EXTRA_MOUNTS="$DEEP" launch "$LAUNCHER" "$TMP/app"
want="$(printf '%s\n' "$DEEP/a:/workspace/deep/a:rw" "$DEEP/a/b:/workspace/deep/a/b:rw" \
                      "$DEEP/a/b/.ai-containers:/workspace/deep/a/b/.ai-containers:ro")"
[[ "$(mounts_under /workspace/deep/)" == "$want" ]] \
  && pass "T11 every directory between is pinned exactly once" \
  || fail "T11 pins at depth 2 (got: $(mounts_under /workspace/deep/ | tr '\n' ' '))"

# ── T12: ANOTHER project's launcher inside a writable mount is protected too —
# e.g. this engine launching `./sandbox.sh restricted ~/other`. A directory
# that only holds a name (no sandbox.sh + sandbox-common.sh) is not a launcher.
OTHER="$TMP/other"; mkdir -p "$OTHER/.ai-containers" "$OTHER/sub/.ai-containers"
: > "$OTHER/.ai-containers/sandbox.sh"; : > "$OTHER/.ai-containers/sandbox-common.sh"
launch "$LAUNCHER" "$OTHER"
[[ "$(mounts_under /workspace/other/)" == "$OTHER/.ai-containers:/workspace/other/.ai-containers:ro" ]] \
  && pass "T12 another launcher (sandbox.sh + sandbox-common.sh) in the mount is read-only; a bare .ai-containers is not" \
  || fail "T12 other launcher (got: $(mounts_under /workspace/other/ | tr '\n' ' '))"

# ── T13–T15: the other writable mount sources reach the overlay too.
VAULT_PATH="$TMP" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$LAUNCHER:/workspace/vault/proj/.ai-containers:ro" <<<"$(mounts_under /workspace/vault/)" \
  && pass "T13 VAULT_PATH (writable) gets the overlay" \
  || fail "T13 VAULT_PATH (got: $(mounts_under /workspace/vault/ | tr '\n' ' '))"
SPECS_PATH="$TMP" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$LAUNCHER:/workspace/specs/proj/.ai-containers:ro" <<<"$(mounts_under /workspace/specs/)" \
  && pass "T14 SPECS_PATH (writable) gets the overlay" \
  || fail "T14 SPECS_PATH (got: $(mounts_under /workspace/specs/ | tr '\n' ' '))"
mkdir -p "$HOME/.ai-containers"
printf 'otherrepo|path|%s|0|0|bind\n' "$OTHER" >> "$HOME/.ai-containers/repos.conf"
REPOS="otherrepo:rw" launch "$LAUNCHER" "$TMP/app"
[[ "$(mounts_under /workspace/otherrepo/)" == "$OTHER/.ai-containers:/workspace/otherrepo/.ai-containers:ro" ]] \
  && pass "T15 a :rw bind repo gets the overlay" \
  || fail "T15 bind repo (got: $(mounts_under /workspace/otherrepo/ | tr '\n' ' '); stderr: $(tail -3 "$ERR" | tr '\n' ' '))"
DOCS_PATH="$TMP:rw" ARCHITECTURE_REPO_PATH="$TMP:rw" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$LAUNCHER:/workspace/docs/proj/.ai-containers:ro" <<<"$(mounts_under /workspace/docs/)" \
  && grep -qxF -- "$LAUNCHER:/workspace/architecture/proj/.ai-containers:ro" <<<"$(mounts_under /workspace/architecture/)" \
  && pass "T16 DOCS_PATH / ARCHITECTURE_REPO_PATH mounted :rw get the overlay" \
  || fail "T16 docs/architecture :rw (got: $(mounts_under /workspace/docs/ | tr '\n' ' ') | $(mounts_under /workspace/architecture/ | tr '\n' ' '))"

# ── T17: an engine checkout (named "ai-containers", NOT ".ai-containers")
# exposed by a writable mount is protected too — matched by content, not name.
ENG="$TMP/devroot/ai-tools/ai-containers"; mkdir -p "$ENG"
: > "$ENG/sandbox.sh"; : > "$ENG/sandbox-common.sh"
EXTRA_MOUNTS="$TMP/devroot" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$ENG:/workspace/devroot/ai-tools/ai-containers:ro" <<<"$(mounts)" \
  && pass "T17 an ai-containers checkout in a writable mount is read-only" \
  || fail "T17 engine checkout (got: $(mounts | grep -F devroot | tr '\n' ' '))"
# and the directories above it are pinned, writable, so it cannot be moved
grep -qxF -- "$TMP/devroot/ai-tools:/workspace/devroot/ai-tools:rw" <<<"$(mounts)" \
  && pass "T17 ... with its parent directories pinned writable" \
  || fail "T17 engine parents pinned (got: $(mounts | grep -F devroot | tr '\n' ' '))"

# ── T18: a launcher NESTED in another launcher gets no writable pin inside the
# outer read-only overlay — the whole nested path is already read-only.
NEST="$TMP/nest"; mkdir -p "$NEST/.ai-containers/sub/.ai-containers"
: > "$NEST/.ai-containers/sandbox.sh"; : > "$NEST/.ai-containers/sandbox-common.sh"
: > "$NEST/.ai-containers/sub/.ai-containers/sandbox.sh"; : > "$NEST/.ai-containers/sub/.ai-containers/sandbox-common.sh"
launch "$LAUNCHER" "$NEST"
[[ "$(mounts | grep -F "/workspace/nest/.ai-containers")" == "$NEST/.ai-containers:/workspace/nest/.ai-containers:ro" ]] \
  && pass "T18 a launcher nested in another is covered by the outer overlay, with no writable pin punched into it" \
  || fail "T18 nested launcher (got: $(mounts | grep -F /workspace/nest | tr '\n' ' '))"

# ── T19: a mount whose ROOT is a launcher cannot be made read-only (it is the
# mount); it stays writable and says so with a NOTE, rather than silently.
EXTRA_MOUNTS="$OTHER/.ai-containers" launch "$LAUNCHER" "$TMP/app"
obase="$(basename "$OTHER/.ai-containers")"   # ".ai-containers"
[[ -z "$(mounts | grep -F "/workspace/$obase:" | grep ':ro$')" ]] \
  && grep -q "NOTE:.*holds a launcher" "$ERR" \
  && pass "T19 a mount rooted at a launcher stays writable and prints a NOTE" \
  || fail "T19 launcher-as-mount NOTE (mounts: $(mounts | grep -F "/workspace/$obase" | tr '\n' ' '); stderr: $(grep NOTE "$ERR" | tr '\n' ' '))"

# ── T20: a file named sandbox.sh that is NOT a launcher (no sandbox-common.sh
# beside it — any repo may have a script by that name), in a mount scanned
# BEFORE the project, must not cost the project its overlay. sandbox.sh runs
# under `set -euo pipefail`, and a scan that returned non-zero once ended the
# whole candidate loop there — failing OPEN for every mount after it.
STRAY="$TMP/stray"; mkdir -p "$STRAY/tool"; : > "$STRAY/tool/sandbox.sh"
EXTRA_MOUNTS="$STRAY" launch "$LAUNCHER" ..
[[ "$(ro_overlays)" == "$LAUNCHER:/workspace/proj/.ai-containers:ro" ]] \
  && pass "T20 a stray sandbox.sh in an earlier mount does not drop the project's overlay" \
  || fail "T20 stray sandbox.sh in an earlier mount (got: $(ro_overlays | tr '\n' ' '))"

# ── T21: a launcher under a directory whose name holds a comma, a double quote
# and a tab — characters an agent can put in a name. docker reads --mount as
# CSV, so unquoted a ',' splits the field and the next launch fails; a tab
# once corrupted the scan's tab-separated records.
ODD="$TMP/odd"; oname='a,b"c'$'\t''d'; od="$ODD/$oname"
mkdir -p "$od/.ai-containers"; : > "$od/.ai-containers/sandbox.sh"; : > "$od/.ai-containers/sandbox-common.sh"
EXTRA_MOUNTS="$ODD" launch "$LAUNCHER" "$TMP/app"
want="$(printf '%s\n' "$od:/workspace/odd/$oname:rw" "$od/.ai-containers:/workspace/odd/$oname/.ai-containers:ro")"
[[ "$(mounts_under /workspace/odd/)" == "$want" ]] \
  && pass "T21 a launcher under a name with , \" and a tab is pinned and overlaid intact" \
  || fail "T21 odd name (got: $(mounts_under /workspace/odd/ | tr '\n\t' '|^'))"

# ── T22: a symlink on the path this launcher was reached through, sitting in
# a writable mount, cannot be pinned — the agent could replace it, and the next
# `cd <that path>` on the host would land in the replacement. Say so.
LINKS="$TMP/links"; mkdir -p "$LINKS"; ln -s "$PROJ" "$LINKS/proj"
EXTRA_MOUNTS="$LINKS" launch "$LINKS/proj/.ai-containers" ..
grep -qF "WARNING: $LINKS/proj is a symlink inside a writable mount" "$ERR" \
  && grep -qxF "         Launch through the real path instead: $LAUNCHER" "$ERR" \
  && pass "T22 a symlink on the launch path inside a writable mount is warned about, naming the real path" \
  || fail "T22 symlink warning (stderr: $(tr '\n' ' ' <"$ERR"))"
[[ "$(ro_overlays)" == "$LAUNCHER:/workspace/proj/.ai-containers:ro" ]] \
  && pass "T22 ... and the real launcher is still overlaid" \
  || fail "T22 real launcher overlay (got: $(ro_overlays | tr '\n' ' '))"

# ── T23: launcher_dirs_in itself, on a launcher under a name holding a newline.
# The fake docker above records one argument per line, so it cannot carry one;
# the scan is checked directly instead. Read NUL-delimited, the name arrives
# whole; read line by line, it would arrive as two halves, neither a launcher.
NL="$TMP/nl"; nlname='x'$'\n''y'; mkdir -p "$NL/$nlname/.ai-containers"
: > "$NL/$nlname/.ai-containers/sandbox.sh"; : > "$NL/$nlname/.ai-containers/sandbox-common.sh"
got="$(bash -c '
  set -euo pipefail
  eval "$(awk "/^launcher_dirs_in\\(\\) \\{/,/^}\$/" "$1")"
  out=(); unr=(); launcher_dirs_in out unr "$2" "$(id -u)" "$(id -g)" "$(id -u)"; printf "%s\0" "${out[@]}"' _ "$ENGINE/sandbox.sh" "$NL" | tr '\0\n' '|^')"
[[ "$got" == "$NL/x^y/.ai-containers|" ]] \
  && pass "T23 launcher_dirs_in finds a launcher under a name with a newline, whole" \
  || fail "T23 newline in a name (got: $got)"

# A launcher at <base>/<name>/.ai-containers, a real one (both files).
mk_launcher() { mkdir -p "$1/.ai-containers" && : > "$1/.ai-containers/sandbox.sh" && : > "$1/.ai-containers/sandbox-common.sh"; }
# The argument after each `-v` / `--mount`, raw, one per line, prefixed by the flag.
raw_mounts() { awk 'prev=="-v"||prev=="--mount"{print prev " " $0} {prev=$0}' "$CAPTURE"; }

# ── T24: how each launcher is handed to docker. `-v` carries every name docker
# accepts except one holding ':' (its separator); `--mount` carries the ':' but
# refuses a value ending in whitespace. What neither can carry faithfully — a
# ':' plus a trailing space, or a name that is not valid UTF-8, which docker
# rewrites (and Docker Desktop then CREATES, root-owned, inside the project) —
# is not mounted at all, with a WARNING, rather than wedging the launch.
REP="$TMP/rep"
mk_launcher "$REP/c:o,n"; mk_launcher "$REP/tr "; mk_launcher "$REP/c:o "; mk_launcher "$REP/p:q/in"
# A launcher whose OWN directory has the unrepresentable name — nothing above it
# to pin, so only the check on the launcher itself can catch it.
mkdir -p "$REP/l:x "; : > "$REP/l:x /sandbox.sh"; : > "$REP/l:x /sandbox-common.sh"
EXTRA_MOUNTS="$REP" launch "$LAUNCHER" "$TMP/app"
grep -aqxF -- "--mount type=bind,\"source=$REP/c:o,n/.ai-containers\",\"destination=/workspace/rep/c:o,n/.ai-containers\",readonly" <<<"$(raw_mounts)" \
  && pass "T24 a name with ':' goes through --mount, CSV-quoted" \
  || fail "T24 ':' via --mount (got: $(raw_mounts | grep -aF 'c:o,n' | tr '\n' ' '))"
grep -aqxF -- "-v $REP/tr /.ai-containers:/workspace/rep/tr /.ai-containers:ro" <<<"$(raw_mounts)" \
  && grep -aqxF -- "-v $REP/tr :/workspace/rep/tr :rw" <<<"$(raw_mounts)" \
  && pass "T24 a name ending in a space goes through -v, which keeps it" \
  || fail "T24 trailing space via -v (got: $(raw_mounts | grep -aF '/tr ' | tr '\n' ' '))"
if ! grep -aqF -- "c:o /" <<<"$(raw_mounts)" && grep -aqF "WARNING: cannot protect $REP/c:o /.ai-containers" "$ERR"; then
  pass "T24 ':' plus a trailing space is not mounted, and is warned about"
else
  fail "T24 unrepresentable ':'+space (mounts: $(raw_mounts | grep -aF 'c:o ' | tr '\n' ' '); stderr: $(grep -aF 'c:o ' "$ERR" | tr '\n' ' '))"
fi
grep -aqxF -- "--mount type=bind,\"source=$REP/p:q\",\"destination=/workspace/rep/p:q\"" <<<"$(raw_mounts)" \
  && grep -aqxF -- "--mount type=bind,\"source=$REP/p:q/in\",\"destination=/workspace/rep/p:q/in\"" <<<"$(raw_mounts)" \
  && grep -aqxF -- "--mount type=bind,\"source=$REP/p:q/in/.ai-containers\",\"destination=/workspace/rep/p:q/in/.ai-containers\",readonly" <<<"$(raw_mounts)" \
  && pass "T24 pins under a ':' go through --mount, writable; the launcher read-only" \
  || fail "T24 ':' in a pinned directory (got: $(raw_mounts | grep -aF 'p:q' | tr '\n' ' '))"
if ! grep -aqF -- "l:x " <<<"$(raw_mounts)" && grep -aqF "WARNING: cannot protect $REP/l:x " "$ERR"; then
  pass "T24 a launcher whose own name is unrepresentable is not mounted, and is warned about"
else
  fail "T24 launcher's own name (mounts: $(raw_mounts | grep -aF 'l:x' | tr '\n' ' '); stderr: $(grep -aF 'l:x' "$ERR" | tr '\n' ' '))"
fi
[[ -s "$CAPTURE" ]] && pass "T24 ... and the launch still goes ahead" || fail "T24 the launch still goes ahead"
# Not valid UTF-8 as Go (hence docker) reads it: a stray byte, an overlong, a
# surrogate, a code point above U+10FFFF, a five-byte form. glibc's iconv
# accepts the last two, which is why the check is not iconv.
BAD="$TMP/bad"; made=0
for b in $'\xff' $'\xc0\xaf' $'\xed\xa0\x80' $'\xf4\x90\x80\x80' $'\xf8\x88\x80\x80\x80'; do
  mk_launcher "$BAD/x$b" 2>/dev/null && made=$((made + 1))
done
if (( made > 0 )); then
  EXTRA_MOUNTS="$BAD" launch "$LAUNCHER" "$TMP/app"
  nwarn="$(grep -ac "WARNING: cannot protect $BAD/x" "$ERR")"
  if ! grep -aqF -- "$BAD/x" <<<"$(raw_mounts)" && [[ "$nwarn" -eq "$made" ]] && [[ -s "$CAPTURE" ]]; then
    pass "T24 names that are not valid UTF-8 ($made kinds) are not mounted, each is warned about, and the launch goes ahead"
  else
    fail "T24 invalid UTF-8 ($made made, $nwarn warned; mounts: $(raw_mounts | grep -aF "$BAD/x" | od -An -c | tr -s ' \n' ' '))"
  fi
else
  printf 'SKIP: T24 invalid-UTF-8 names — this filesystem refuses them\n'
fi
# Valid UTF-8 must NOT be refused: a check that over-rejects leaves every
# non-ASCII project unprotected. Cyrillic, an emoji (4 bytes), U+10FFFF.
GOOD="$TMP/good"; gname=$'\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb5\xd0\xba\xd1\x82'; ename=$'e\xf0\x9f\x98\x80'; mname=$'m\xf4\x8f\xbf\xbf'
# APFS refuses U+10FFFF, a noncharacter ("Illegal byte sequence"), so a name
# the filesystem will not make is skipped, as the invalid-UTF-8 names above are.
gmade=()
for n in "$gname" "$ename" "$mname"; do
  if mk_launcher "$GOOD/$n" 2>/dev/null; then gmade+=("$n")
  else printf 'SKIP: T24 valid UTF-8 %q — this filesystem refuses it\n' "$n"; fi
done
EXTRA_MOUNTS="$GOOD" launch "$LAUNCHER" "$TMP/app"
ok=1
for n in "${gmade[@]}"; do
  grep -aqxF -- "-v $GOOD/$n/.ai-containers:/workspace/good/$n/.ai-containers:ro" <<<"$(raw_mounts)" || ok=0
done
[[ "$ok" -eq 1 && ${#gmade[@]} -gt 0 ]] && ! grep -aq 'cannot protect' "$ERR" \
  && pass "T24 valid non-ASCII names (Cyrillic, an emoji, U+10FFFF) are protected through -v" \
  || fail "T24 valid UTF-8 (mounts: $(raw_mounts | grep -aF "$GOOD" | tr '\n' ' '); stderr: $(grep -a WARNING "$ERR" | tr '\n' ' '))"
# With a ':' (so --mount): Unicode whitespace at the end and a CR anywhere are
# refused by docker, so not mounted; a '"' is fine, doubled inside its quotes.
COL="$TMP/col"
mk_launcher "$COL/n:b"$'\xc2\xa0'; mk_launcher "$COL/i:d"$'\xe3\x80\x80'; mk_launcher "$COL/c:r"$'\r'"x"; mk_launcher "$COL/q:\"x"
EXTRA_MOUNTS="$COL" launch "$LAUNCHER" "$TMP/app"
[[ "$(grep -ac "WARNING: cannot protect $COL/" "$ERR")" -eq 3 ]] \
  && grep -aqxF -- "--mount type=bind,\"source=$COL/q:\"\"x/.ai-containers\",\"destination=/workspace/col/q:\"\"x/.ai-containers\",readonly" <<<"$(raw_mounts)" \
  && grep -aqxF -- "--mount type=bind,\"source=$COL/q:\"\"x\",\"destination=/workspace/col/q:\"\"x\"" <<<"$(raw_mounts)" \
  && [[ "$(raw_mounts | grep -ac -- "$COL/")" -eq 2 ]] \
  && pass "T24 with a ':', NBSP/U+3000 at the end or a CR are not mounted; a '\"' is, doubled" \
  || fail "T24 ':' plus whitespace/CR/quote (mounts: $(raw_mounts | grep -aF "$COL/" | tr '\n\r' ' ^'); warned: $(grep -ac "cannot protect $COL/" "$ERR"))"

# ── T25: a directory the agent owns but has made unreadable cannot be looked
# inside, so a launcher in it would go unseen and stay writable at the next
# launch. One you can still search (0311) is refused: a FIFO inside it can be
# opened by name and written through a read-only overlay (automated security
# review of c687370). One you cannot search either (0200) is treated as a
# launcher: overlaid read-only, its parents pinned, warned.
LOCK="$TMP/lockp"; mk_launcher "$LOCK/inner/proj2"; chmod 0311 "$LOCK/inner"
EXTRA_MOUNTS="$LOCK" launch "$LAUNCHER" "$TMP/app"
if [[ "$(id -u)" -eq 0 ]]; then
  # Root lists anything, so nothing is hidden: the launcher inside is found.
  grep -qxF -- "$LOCK/inner/proj2/.ai-containers:/workspace/lockp/inner/proj2/.ai-containers:ro" <<<"$(mounts_under /workspace/lockp/)" \
    && ! grep -q 'cannot be listed' "$ERR" \
    && pass "T25 (as root) a 0311 directory hides nothing: the launcher in it is found" \
    || fail "T25 as root (got: $(mounts_under /workspace/lockp/ | tr '\n' ' '))"
else
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $LOCK/inner can be searched but not listed by you" "$ERR" \
    && grep -qF 'Restore: chmod u+rx' "$ERR" \
    && pass "T25 a directory of the agent's you can search but not list refuses the launch" \
    || fail "T25 searchable unlistable directory (rc=$LAUNCH_RC; stderr: $(grep -F "$LOCK" "$ERR" | tr '\n' ' '))"
  chmod 0200 "$LOCK/inner"
  EXTRA_MOUNTS="$LOCK" launch "$LAUNCHER" "$TMP/app"
  [[ "$LAUNCH_RC" == 0 && "$(mounts_under /workspace/lockp/)" == "$LOCK/inner:/workspace/lockp/inner:ro" ]] \
    && grep -qF "WARNING: $LOCK/inner cannot be listed by you" "$ERR" && grep -qF 'Restore: chmod u+rx' "$ERR" \
    && pass "T25 one you cannot search either is mounted read-only, with a warning" \
    || fail "T25 unsearchable directory (rc=$LAUNCH_RC; got: $(mounts_under /workspace/lockp/ | tr '\n' ' '); stderr: $(grep -F "$LOCK" "$ERR" | tr '\n' ' '))"
fi
chmod 0755 "$LOCK/inner"

# ── T25b/c: a directory the agent does NOT own (agent identity overridden). It
# hides a launcher only if the agent can still search it (T25b, o+x); one the
# agent cannot enter at all — a database's data directory, say — hides nothing
# it could touch, so it is not reported (T25c). Root lists everything: n/a.
if [[ "$(id -u)" -ne 0 ]]; then
  OWN="$TMP/own"; mk_launcher "$OWN/srch/p"; mk_launcher "$OWN/shut/p"; chmod 0311 "$OWN/srch"; chmod 0310 "$OWN/shut"
  SANDBOX_UID=4242 SANDBOX_GID=4343 EXTRA_MOUNTS="$OWN" launch "$LAUNCHER" "$TMP/app"
  chmod 0755 "$OWN/srch" "$OWN/shut"
  # Yours, though the agent's identity is another: on a file share that remaps
  # ownership (Docker Desktop, Colima) what the agent makes shows up as yours, so
  # it is refused, and you can always fix your own (LNCH-5). Another user's the
  # agent cannot write keeps the overlay and the WARNING (review of 7b41327).
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $OWN/srch can be searched but not listed" "$ERR" && ! grep -qF "$OWN/shut" "$ERR" \
    && pass "T25b one you own that the agent can search refuses the launch; T25c one it cannot enter is left alone" \
    || fail "T25b/c agent-reach (got: $(mounts_under /workspace/own/ | tr '\n' ' '); stderr: $(grep -F "$OWN" "$ERR" | tr '\n' ' '))"
  # Not the agent's, but writable and searchable by it through its group or the
  # other bits: it could have planted a FIFO there, so refused (automated
  # security review of cd83cb7).
  OWN2="$TMP/own2g"; OWN3="$TMP/own2o"; mk_launcher "$OWN2/grp/p"; mk_launcher "$OWN3/oth/p"
  chmod 0331 "$OWN2/grp"; chmod 0303 "$OWN3/oth"
  SANDBOX_UID=4242 SANDBOX_GID="$(id -g)" EXTRA_MOUNTS="$OWN2" launch "$LAUNCHER" "$TMP/app"
  rc_g=$LAUNCH_RC; err_g="$(grep -F ERROR "$ERR" | head -1)"
  SANDBOX_UID=4242 SANDBOX_GID=4343 EXTRA_MOUNTS="$OWN3" launch "$LAUNCHER" "$TMP/app"
  rc_o=$LAUNCH_RC; err_o="$(grep -F ERROR "$ERR" | head -1)"
  chmod 0755 "$OWN2/grp" "$OWN3/oth"
  [[ "$rc_g" != 0 && "$err_g" == *"can be searched but not listed"* && "$rc_o" != 0 && "$err_o" == *"can be searched but not listed"* ]] \
    && pass "T25d one the agent can write through its group or the other bits refuses the launch" \
    || fail "T25d agent-writable, not the agent's (group rc=$rc_g: $err_g; other rc=$rc_o: $err_o)"
  # One with an ACL: an entry can let the agent write whatever the mode bits say,
  # and those entries are not read here, so it is refused (automated security
  # review of 63503a9).
  if command -v setfacl >/dev/null 2>&1; then
    OWN4="$TMP/own2a"; mk_launcher "$OWN4/acl/p"; chmod 0311 "$OWN4/acl"
    if setfacl -m u:4242:wx "$OWN4/acl" 2>/dev/null; then
      SANDBOX_UID=4242 SANDBOX_GID=4343 EXTRA_MOUNTS="$OWN4" launch "$LAUNCHER" "$TMP/app"
      [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $OWN4/acl can be searched but not listed" "$ERR" \
        && pass "T25e one with an ACL refuses the launch" \
        || fail "T25e ACL directory (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
    else
      printf 'SKIP: T25e — this filesystem takes no ACL\n'
    fi
    chmod 0755 "$OWN4/acl"
  else
    printf 'SKIP: T25e — no setfacl\n'
  fi
  # T25f: fails closed where ls cannot say there is no ACL — macOS prints @ in
  # place of a + when there are extended attributes too, and an ls that fails
  # says nothing (automated security review of 64f8841). A shim ls answers for
  # this one directory and passes everything else through.
  OWN5="$TMP/own2f"; mk_launcher "$OWN5/srch/p"; chmod 0311 "$OWN5/srch"
  SHIM="$TMP/lsshim"; mkdir -p "$SHIM"
  printf '#!/bin/bash\nfor a; do last="$a"; done\nif [[ "$last" == %q ]]; then\n  [[ "$LS_SHIM" == fail ]] && exit 1\n  printf "drwx--x--x@ 2 u g 64 Jan 1 00:00 %%s\\n" "$last"; exit 0\nfi\nexec %q "$@"\n' \
    "$OWN5/srch" "$(command -v ls)" > "$SHIM/ls"; chmod +x "$SHIM/ls"
  for v in at fail; do
    LS_SHIM=$v PATH="$SHIM:$PATH" SANDBOX_UID=4242 SANDBOX_GID=4343 EXTRA_MOUNTS="$OWN5" launch "$LAUNCHER" "$TMP/app"
    [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $OWN5/srch can be searched but not listed" "$ERR" \
      && pass "T25f an ls that shows $v refuses the launch" \
      || fail "T25f ls $v (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  done
  chmod 0755 "$OWN5/srch"
  # T25g: the mode and ACL half on its own. T25d-f now refuse also because the
  # directory is yours (LNCH-5), so each rule of _agent_bits_writable is checked
  # directly, against an agent that is not you.
  eval "$(awk 'index($0, "_agent_bits_writable() {") == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh")"
  B25="$TMP/bits25"; mkdir -p "$B25/plain" "$B25/grp" "$B25/oth" "$B25/acl"
  chmod 0311 "$B25/plain"; chmod 0331 "$B25/grp"; chmod 0303 "$B25/oth"; chmod 0311 "$B25/acl"
  g25="$(id -g)"; r25=""
  _agent_bits_writable "$B25/plain" 4242 4343 && r25+=" plain"
  _agent_bits_writable "$B25/grp" 4242 4343 && r25+=" grp-other-gid"
  _agent_bits_writable "$B25/grp" 4242 "$g25" || r25+=" grp-missed"
  _agent_bits_writable "$B25/oth" 4242 4343 || r25+=" oth-missed"
  _agent_bits_writable "$B25/plain" "$(id -u)" 4343 || r25+=" own-uid-missed"
  if command -v setfacl >/dev/null 2>&1 && setfacl -m u:4242:wx "$B25/acl" 2>/dev/null; then
    _agent_bits_writable "$B25/acl" 4242 4343 || r25+=" acl-missed"
  fi
  LS_SHIM=at PATH="$SHIM:$PATH" _agent_bits_writable "$OWN5/srch" 4242 4343 || r25+=" at-missed"
  LS_SHIM=fail PATH="$SHIM:$PATH" _agent_bits_writable "$OWN5/srch" 4242 4343 || r25+=" fail-missed"
  # T25i: uutils' ls marks an ACL with +, so with no getfacl it is trusted too
  # (LNCH-21) — but not its `.`, which takes the place of a + where a security
  # context is set. Run where neither the host's ls, its getfacl nor its kernel
  # can decide: a PATH of find, a uname that says Linux (on a Mac the version
  # check is skipped), and a shim ls that says it is uutils.
  UU="$TMP/uu25"; mkdir -p "$UU"
  ln -sf "$(command -v find)" "$UU/find"
  printf '#!/bin/sh\necho Linux\n' > "$UU/uname"; chmod +x "$UU/uname"
  printf '#!/bin/sh\ncase "$1" in --version) echo "ls (uutils coreutils) 0.10.0"; exit 0;; esac\nprintf "%%s 2 u g 64 Jan 1 00:00 %%s\\n" "$UU_MODE" "$2"\n' > "$UU/ls"; chmod +x "$UU/ls"
  UU_MODE="d-wx--x--x" PATH="$UU" _agent_bits_writable "$B25/plain" 4242 4343 && r25+=" uutils-plain-counted"
  UU_MODE="d-wx--x--x+" PATH="$UU" _agent_bits_writable "$B25/plain" 4242 4343 || r25+=" uutils-acl-missed"
  UU_MODE="d-wx--x--x." PATH="$UU" _agent_bits_writable "$B25/plain" 4242 4343 || r25+=" uutils-dot-trusted"
  # A uutils that reports a version before 0.1.0 is not trusted (fails closed).
  sed 's/0\.10\.0/0.0.23/' "$UU/ls" > "$UU/ls.old" && mv "$UU/ls.old" "$UU/ls" && chmod +x "$UU/ls"
  UU_MODE="d-wx--x--x" PATH="$UU" _agent_bits_writable "$B25/plain" 4242 4343 || r25+=" uutils-old-trusted"
  # T25h: an ls that does not mark ACLs (busybox; GNU's on CIFS) is not taken at
  # its word (LNCH-6). getfacl decides where there is one, and one that fails
  # counts as an ACL; with no getfacl, only GNU's or a BSD ls is trusted.
  BB="$TMP/bb25"; mkdir -p "$BB"
  printf '#!/bin/sh\ncase "$1" in --version) echo "BusyBox v1.36"; exit 1;; esac\nprintf "d-wx--x--x 2 u g 64 Jan 1 00:00 %%s\\n" "$2"\n' > "$BB/ls"
  printf '#!/bin/sh\nexit 1\n' > "$BB/getfacl"; chmod +x "$BB/ls" "$BB/getfacl"
  PATH="$BB:$PATH" _agent_bits_writable "$B25/plain" 4242 4343 || r25+=" busybox-ls-failing-getfacl-trusted"
  # …and with no getfacl at all, an ls that is not GNU's, BSD's or uutils' is not
  # trusted either (LNCH-18): the same PATH of find and a Linux uname as T25i, with
  # the busybox ls — so neither the host's getfacl nor its ls decides.
  NB="$TMP/nb25"; mkdir -p "$NB"
  ln -sf "$(command -v find)" "$NB/find"; cp "$UU/uname" "$BB/ls" "$NB/"
  PATH="$NB" _agent_bits_writable "$B25/plain" 4242 4343 || r25+=" unknown-ls-without-getfacl-trusted"
  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && setfacl -m u:4242:wx "$B25/acl" 2>/dev/null; then
    mkdir -p "$BB/l"; cp "$BB/ls" "$BB/l/ls"
    PATH="$BB/l:$PATH" _agent_bits_writable "$B25/acl" 4242 4343 || r25+=" acl-unmarked-by-ls-missed"
    _agent_bits_writable "$B25/plain" 4242 4343 && r25+=" plain-with-getfacl"
  fi
  chmod -R u+rwx "$B25"
  [[ -z "$r25" ]] && pass "T25g the mode, group, other, ACL and ls rules each decide on their own" \
    || fail "T25g _agent_bits_writable:$r25"
else
  printf 'SKIP: T25b/c — as root every directory can be listed\n'
fi

# ── T26: an unreadable writable mount ROOT cannot be overlaid (it is the mount)
# or looked inside, so the launch is refused, naming it — never started blind.
ROOTL="$TMP/rootl"; mk_launcher "$ROOTL/p"; chmod 0311 "$ROOTL"
EXTRA_MOUNTS="$ROOTL" launch "$LAUNCHER" "$TMP/app"
chmod 0755 "$ROOTL"
if [[ "$(id -u)" -eq 0 ]]; then
  grep -qxF -- "$ROOTL/p/.ai-containers:/workspace/rootl/p/.ai-containers:ro" <<<"$(mounts)" \
    && pass "T26 (as root) a 0311 mount root can be listed, so the launch goes ahead, protected" \
    || fail "T26 as root (got: $(mounts | grep -F rootl | tr '\n' ' '))"
else
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $ROOTL cannot be listed by you" "$ERR" \
    && pass "T26 a writable mount root you cannot list refuses the launch, naming it" \
    || fail "T26 unlistable mount root (docker run reached: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -E 'ERROR|WARNING' "$ERR" | tr '\n' ' '))"
fi

# ── T27: the documented limits, so code and docs cannot drift: six levels
# down, and dependency/VCS trees are not searched.
LIM="$TMP/lim"; mk_launcher "$LIM/1/2/3/4/5"; mk_launcher "$LIM/a/b/c/d/e/f"; mk_launcher "$LIM/node_modules/p"
EXTRA_MOUNTS="$LIM" launch "$LAUNCHER" "$TMP/app"
[[ "$(mounts_under /workspace/lim/ | grep ':ro$')" == "$LIM/1/2/3/4/5/.ai-containers:/workspace/lim/1/2/3/4/5/.ai-containers:ro" ]] \
  && pass "T27 a launcher six levels down is found; seven levels, or under node_modules, is not" \
  || fail "T27 limits (got: $(mounts_under /workspace/lim/ | grep ':ro$' | tr '\n' ' '))"

# ── T28: a launcher whose sandbox.sh is a symlink is still a launcher.
SL="$TMP/sl"; mkdir -p "$SL/p/.ai-containers"; : > "$SL/p/.ai-containers/sandbox-common.sh"
ln -s "$ENGINE/sandbox.sh" "$SL/p/.ai-containers/sandbox.sh"
EXTRA_MOUNTS="$SL" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$SL/p/.ai-containers:/workspace/sl/p/.ai-containers:ro" <<<"$(mounts)" \
  && pass "T28 a launcher whose sandbox.sh is a symlink is found and protected" \
  || fail "T28 symlinked sandbox.sh (got: $(mounts | grep -F /workspace/sl | tr '\n' ' '))"

# ── T29: symlinks INSIDE a launcher. The link is read-only with the launcher,
# but what the host reads is at its other end. When the way there leads into a
# writable mount — to a file there, or through a link there the agent could
# repoint — the launch warns, once per link, naming the first such place. It
# does not overlay targets (that made wrong mounts and broke git checkouts).
# Resolution is the kernel's, component by component: `sub/../x` steps out of
# where `sub` really leads. A link staying inside its launcher, or ending
# outside every mount, is not reported.
LK="$TMP/lk"; mk_launcher "$LK/p"; A="$LK/p/.ai-containers"
mkdir -p "$LK/shared/tools.d" "$LK/shared/subdir" "$LK/shared/config"
echo c > "$LK/shared/sandbox.conf"; echo r > "$LK/shared/real.conf"; echo e > "$LK/shared/cfg.env"; echo k > "$LK/shared/config/sandbox.conf"
ln -s ../../shared/sandbox.conf "$A/sandbox.conf"            # file in a writable mount
ln -s "$LK/shared/tools.d" "$A/tools.d"                      # directory there, absolute link
ln -s real.conf "$LK/shared/hop"; ln -s ../../shared/hop "$A/hop.conf"   # through a link there
ln -s ../../shared/subdir "$A/sub"; ln -s sub/../cfg.env "$A/wrong.conf"  # `..` after a symlinked dir
ln -s shared/config "$LK/config"; ln -s ../../config/sandbox.conf "$A/via.conf"  # symlinked component
ln -s sandbox.sh "$A/alias.sh"                               # stays inside: silent
ln -s "$ENGINE/AGENTS.md" "$A/outside.md"                    # outside every mount: silent
mk_launcher "$LK/q"; ln -s ../../q/.ai-containers/sandbox-common.sh "$A/peer.sh"  # into another launcher, read-only already: silent
mkdir -p "$LK/p/real"; ln -s ../real/../../q/.ai-containers/sandbox-common.sh "$A/step.conf"  # steps out of an ordinary dir
ln -s ../../shared/real.conf "$A/target"                     # named like a pruned directory: still checked
ln -s ../../../lk/shared/real.conf "$A/up3.conf"             # steps out of the mount root itself: that is safe
ln -s loop2 "$LK/shared/loop1"; ln -s loop1 "$LK/shared/loop2"; ln -s ../../shared/loop1 "$A/loop.conf"
EXTRA_MOUNTS="$LK" launch "$LAUNCHER" "$TMP/app"
[[ "$(mounts_under /workspace/lk/ | sort)" == "$(printf '%s\n' "$A:/workspace/lk/p/.ai-containers:ro" "$LK/p:/workspace/lk/p:rw" \
                                                  "$LK/q/.ai-containers:/workspace/lk/q/.ai-containers:ro" "$LK/q:/workspace/lk/q:rw" | sort)" ]] \
  && pass "T29 a launcher's links add no mounts (the two launchers are overlaid, nothing else)" \
  || fail "T29 no mounts for link targets (got: $(mounts_under /workspace/lk/ | tr '\n' ' '))"
t29() {  # $1 link name, $2 change|repoint, $3 the place named
  grep -qF "WARNING: launcher link $A/$1 leads somewhere the agent can change" "$ERR" \
    && grep -qF "it can $2 $3 (at " <<<"$(grep -A1 -F "launcher link $A/$1 leads" "$ERR")"
}
ok=1
t29 sandbox.conf change  "$LK/shared/sandbox.conf" || { ok=0; fail "T29 file target"; }
t29 tools.d      change  "$LK/shared/tools.d"      || { ok=0; fail "T29 directory target"; }
t29 hop.conf     repoint "$LK/shared/hop"          || { ok=0; fail "T29 a link on the way"; }
t29 sub          change  "$LK/shared/subdir"       || { ok=0; fail "T29 symlinked dir member"; }
t29 wrong.conf   replace "$LK/shared/subdir"       || { ok=0; fail "T29 sub/../x resolved as the kernel does (steps out of where sub leads)"; }
t29 step.conf    replace "$LK/p/real"              || { ok=0; fail "T29 a .. out of an ordinary directory"; }
t29 target       change  "$LK/shared/real.conf"    || { ok=0; fail "T29 a link named like a pruned directory"; }
t29 up3.conf     change  "$LK/shared/real.conf"    || { ok=0; fail "T29 stepping out of a mount root is not reported"; }
t29 via.conf     repoint "$LK/config"              || { ok=0; fail "T29 a symlinked component in a writable mount"; }
t29 loop.conf    repoint "$LK/shared/loop1"        || { ok=0; fail "T29 a loop"; }
[[ "$ok" -eq 1 ]] && pass "T29 each link leading into a writable mount is warned about, naming what the agent could change or repoint"
[[ "$(grep -c 'leads somewhere the agent can change' "$ERR")" -eq 10 ]] \
  && ! grep -qF "$A/alias.sh" "$ERR" && ! grep -qF "$A/outside.md" "$ERR" && ! grep -qF "$A/peer.sh" "$ERR" \
  && pass "T29 exactly once per link; one staying inside its launcher, into another (read-only) launcher, or out of every mount is silent" \
  || fail "T29 warning count/silence (got $(grep -c 'leads somewhere the agent can change' "$ERR"): $(grep -F 'leads into' "$ERR" | tr '\n' ' '))"
# A launcher under a path with a space: its own link is not mistaken for a
# repointable link on the way (membership must not split the path).
SPL="$TMP/spl"; mk_launcher "$SPL/sp ace"; echo s > "$SPL/shared.conf"
ln -s ../../shared.conf "$SPL/sp ace/.ai-containers/shared.conf"
EXTRA_MOUNTS="$SPL" launch "$LAUNCHER" "$TMP/app"
[[ "$(grep -c 'leads somewhere the agent can change' "$ERR")" -eq 1 ]] \
  && grep -qF "change $SPL/shared.conf (at " <<<"$(grep -A1 -F "launcher link $SPL/sp ace/.ai-containers/shared.conf leads" "$ERR")" \
  && pass "T29 a launcher under a path with a space: its link is followed out, and named once" \
  || fail "T29 space in a launcher path (stderr: $(grep -A1 -F 'leads into' "$ERR" | tr '\n' ' '))"

# ── T30: the agent's identity must be numeric; find would error on anything
# else and the search would quietly find nothing. Refuse instead.
SANDBOX_UID=abc launch "$LAUNCHER" ..
[[ ! -s "$CAPTURE" ]] && grep -qF 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric' "$ERR" \
  && pass "T30 a non-numeric SANDBOX_UID refuses the launch" \
  || fail "T30 non-numeric SANDBOX_UID (docker run reached: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep ERROR "$ERR" | tr '\n' ' '))"
# Nor root: capsh switching 0 to 0 clears no capabilities, so the agent keeps
# DAC_OVERRIDE and owns the allowlist the root refresh loop reloads every 60 s
# (bugs review ENV-4). A root host user — sudo, a root WSL distro — included.
for id47 in UID GID; do
  if [[ "$id47" == UID ]]; then SANDBOX_UID=0 launch "$LAUNCHER" ..; else SANDBOX_GID=0 launch "$LAUNCHER" ..; fi
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF 'ERROR: the agent must not run as root' "$ERR" \
    && pass "T30 SANDBOX_$id47=0 refuses the launch" \
    || fail "T30 SANDBOX_$id47=0 (rc=$LAUNCH_RC; docker run reached: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep ERROR "$ERR" | tr '\n' ' '))"
done

SANDBOX_UID=4294967296 launch "$LAUNCHER" ..
[[ ! -s "$CAPTURE" ]] && grep -qF 'ERROR: SANDBOX_UID/SANDBOX_GID must be numeric' "$ERR" \
  && pass "T30 ... and so does one beyond a 32-bit id, which find would reject" \
  || fail "T30 SANDBOX_UID=4294967296 (docker run reached: $([[ -s "$CAPTURE" ]] && echo yes || echo no))"

# ── T31: a directory you do not own, which you cannot list only because of a
# SUPPLEMENTARY group the agent does not have (root:<group> 0705: your class is
# that group, with nothing; the agent's is "other", with r-x). Mode bits alone
# guess your class wrong; only the kernel knows. Needs root to build another
# owner's directory and to run the search as an ordinary user.
if [[ "$(id -u)" -eq 0 ]] && command -v setpriv >/dev/null 2>&1; then
  SG="$TMP/sg"; mk_launcher "$SG/locked/p"; chown -R 1500:1500 "$SG/locked/p"
  chown 0:2600 "$SG/locked"; chmod 0705 "$SG/locked"; chmod 0755 "$TMP" "$SG"
  # tests/run-all.sh gives each test a 0700 TMPDIR: let the ordinary user
  # traverse (o+x only, no listing) every directory above the tree we own.
  d="$TMP"; while d="${d%/*}"; [[ -n "$d" ]]; do if [[ -O "$d" ]]; then chmod o+x "$d"; fi; done
  got="$(setpriv --reuid=1500 --regid=1500 --groups=2600 bash -c '
    set -euo pipefail
    eval "$(awk "/^launcher_dirs_in\\(\\) \\{/,/^}\$/" "$1")"
    out=(); unr=(); launcher_dirs_in out unr "$2" 1500 1500 1500; printf "%s|" ${unr[@]+"${unr[@]}"}' _ "$ENGINE/sandbox.sh" "$SG")"
  [[ "$got" == "$SG/locked|" ]] \
    && pass "T31 a directory hidden from you only by a supplementary group is reported" \
    || fail "T31 supplementary-group blind spot (got: ${got:-nothing})"
else
  printf 'SKIP: T31 — needs root and setpriv to build another owner'"'"'s directory (runs in the floor job)\n'
fi

# ── T32: the launcher you launch from is searched even when no mount holds it
# (an @repo primary, or launching another project from the engine checkout): a
# sandbox.env linked into a writable vault is what the host reads next time.
SOLO="$TMP/solo/.ai-containers"; mkdir -p "$TMP/solo" "$TMP/vault32"; cp -R "$LAUNCHER" "$SOLO"
rm -f "$SOLO/sandbox.env"; : > "$TMP/vault32/sandbox.env"; ln -s "$TMP/vault32/sandbox.env" "$SOLO/sandbox.env"
VAULT_PATH="$TMP/vault32" launch "$SOLO" "$TMP/app"
grep -qF "change $TMP/vault32/sandbox.env (at /workspace/vault/sandbox.env)" <<<"$(grep -A1 -F "launcher link $SOLO/sandbox.env leads somewhere the agent can change" "$ERR")" \
  && pass "T32 this launcher's own links are checked even when no mount holds it" \
  || fail "T32 unmounted launcher's link (stderr: $(grep -A1 -F 'leads into' "$ERR" | tr '\n' ' '))"

# ── T33: an engine checkout as the working dir is a writable mount root (NOTE)
# whose CLAUDE.md-style links point inside it: no warning, and no file bind
# that would make `git checkout` of the target fail with EBUSY.
ln -s sandbox.sh "$LAUNCHER/CLAUDE-like.md"
launch "$LAUNCHER" .
rm -f "$LAUNCHER/CLAUDE-like.md"
! grep -q 'leads somewhere the agent can change' "$ERR" && [[ -z "$(ro_overlays)" ]] \
  && ! grep -qF -- "$LAUNCHER/sandbox.sh:" <<<"$(mounts)" \
  && pass "T33 links inside a checkout used as the working dir: no warning, no file bind" \
  || fail "T33 engine-as-workdir links (stderr: $(grep -F 'leads into' "$ERR" | tr '\n' ' '); overlays: $(ro_overlays | tr '\n' ' '))"

# ── T34: a link is judged by EVERY writable mount that exposes its target. A
# peer launcher too deep for mount A's search (seven levels) but near the root
# of mount B is read-only through both: what B's scan finds is carried into A's
# view (GIT-51), so the link into it is not warned about. Through a mount rooted
# at the peer launcher itself, which cannot be overlaid, it stays writable:
# warned, naming that view.
MA="$TMP/ma"; PD="$MA/a/b/c/d/e/f/g"; mk_launcher "$PD/peer"
ln -s "$PD/peer/.ai-containers/sandbox-common.sh" "$LAUNCHER/deep-peer.sh"
EXTRA_MOUNTS="$PD $MA" launch "$LAUNCHER" ..   # the protecting mount first
m34="$(mounts)"
grep -qxF -- "$PD/peer/.ai-containers:/workspace/ma/a/b/c/d/e/f/g/peer/.ai-containers:ro" <<<"$m34" \
  && grep -qxF -- "$PD/peer/.ai-containers:/workspace/g/peer/.ai-containers:ro" <<<"$m34" \
  && ! grep -qF "launcher link $LAUNCHER/deep-peer.sh leads" "$ERR" \
  && pass "T34 a peer read-only through every mount that exposes it: the link into it is not warned about" \
  || fail "T34 deep peer (got: $(grep -F 'peer/.ai-containers' <<<"$m34" | tr '\n' ' '); stderr: $(grep -A1 -F 'deep-peer' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$PD $PD/peer/.ai-containers" launch "$LAUNCHER" ..
rm -f "$LAUNCHER/deep-peer.sh"
grep -qF "it can change $PD/peer/.ai-containers/sandbox-common.sh (at /workspace/.ai-containers/sandbox-common.sh)" \
     <<<"$(grep -A1 -F "launcher link $LAUNCHER/deep-peer.sh leads" "$ERR")" \
  && pass "T34 a target read-only through one mount but writable through another is warned about" \
  || fail "T34 two mounts, one unprotected (stderr: $(grep -A1 -F 'deep-peer' "$ERR" | tr '\n' ' '))"

# ── T35: a link into a writable directory INSIDE the launcher (its blocked-
# traffic output, mounted read-write on its own) is not "staying home".
ln -s .agent-blocked/x.conf "$LAUNCHER/blk.conf"
launch "$LAUNCHER" ..
rm -f "$LAUNCHER/blk.conf"
grep -qF "it can change $LAUNCHER/.agent-blocked/x.conf (at /workspace/.agent-blocked/x.conf)" \
     <<<"$(grep -A1 -F "launcher link $LAUNCHER/blk.conf leads" "$ERR")" \
  && pass "T35 a link into a writable bind inside the launcher is warned about" \
  || fail "T35 link into .agent-blocked (stderr: $(grep -A1 -F 'blk.conf' "$ERR" | tr '\n' ' '))"

# ── T36: a link into a launcher that could not be overlaid (a name docker
# cannot carry) is not protected by that launcher: warned.
UR="$TMP/ur"; mk_launcher "$UR/c:o "
ln -s "$UR/c:o /.ai-containers/sandbox.sh" "$LAUNCHER/unrep.sh"
EXTRA_MOUNTS="$UR" launch "$LAUNCHER" "$TMP/app"
rm -f "$LAUNCHER/unrep.sh"
grep -qF "launcher link $LAUNCHER/unrep.sh leads somewhere the agent can change" "$ERR" \
  && pass "T36 a link into a launcher that could not be overlaid is warned about" \
  || fail "T36 link into an unrepresentable launcher (stderr: $(grep -F 'unrep' "$ERR" | tr '\n' ' '))"

# ── T37: _link_walk reads a link's target byte for byte — a target ending in a
# newline names a different file than the same text without it.
NLT="$TMP/nlt"; mkdir -p "$NLT/d"; : > "$NLT/d/f"$'\n'; ln -s "f"$'\n' "$NLT/d/l"
got="$(bash -c '
  set -euo pipefail
  for fn in _cd_phys _cd_bash _ci_path _case_flip _u8_locale _win_path _win_fs _win_mounts _disk_spell _link_walk _path_walk _readlink_exact; do eval "$(awk "/^$fn\\(\\) \\{/,/^}\$/" "$1")"; done
  _link_walk "$2"' _ "$ENGINE/sandbox.sh" "$NLT/d/l" | tr '\0\n' '|^')"
[[ "$got" == "$NLT/d/l|=$NLT/d/f^|" ]] \
  && pass "T37 a link target ending in a newline is followed exactly" \
  || fail "T37 trailing newline in a target (got: $got)"
# A link whose target cannot be read (removed between the scan and the read; a
# readlink that fails stands in) ends the walk at the link: nothing is taken for
# its target, and the read says it failed (GAP-2 slice 3).
mkdir -p "$TMP/rlfail"; printf '#!/bin/sh\nexit 1\n' > "$TMP/rlfail/readlink"; chmod +x "$TMP/rlfail/readlink"
got="$(PATH="$TMP/rlfail:$PATH" bash -c '
  set -uo pipefail
  for fn in _cd_phys _cd_bash _ci_path _disk_spell _link_walk _path_walk _readlink_exact; do eval "$(awk "/^$fn\\(\\) \\{/,/^}\$/" "$1")"; done
  v=kept; rc=0; _readlink_exact v "$2" || rc=$?; printf "rc=%s v=%s|" "$rc" "$v"
  _link_walk "$2"' _ "$ENGINE/sandbox.sh" "$NLT/d/l" | tr '\0\n' '|^')"
[[ "$got" == "rc=1 v=kept|$NLT/d/l|" ]] \
  && pass "T37 a link whose target cannot be read ends the walk there" \
  || fail "T37 an unreadable link target (got: $got)"

# ── T62: where readdir must spell a directory (one that ignores case on a
# filesystem whose kernel does not: WSL's drvfs) and its listing names nothing
# that is it, the launch is refused; the path as given was kept (automated
# security review of 1ed3de8). Here a directory that cannot be listed, the
# filesystem's case taken as drvfs's.
UNL="$TMP/unl"; mkdir -p "$UNL/d/sub" && UNLP="$(cd "$UNL/d/sub" && pwd -P)" && chmod 311 "$UNL/d"
if ls "$UNL/d" >/dev/null 2>&1; then
  printf 'NOTE: T62, T63 not run: a mode-311 directory can be listed here (root)\n'
else
  out="$(bash -c '
    set -euo pipefail
    for fn in _ci_path _case_flip _u8_locale _win_path _win_fs _win_mounts _disk_spell _ds_readdir _ci_name _q _term; do eval "$(awk "/^$fn\\(\\) \\{/,/^}\$/" "$1")"; done
    _ci_path() { return 0; }; _ci_name() { return 0; }; _ci_alias_fs() { return 0; }
    v="$2"; _disk_spell v; printf "SPELLED:%s\n" "$v"' _ "$ENGINE/sandbox.sh" "$UNLP" 2>&1)"; rc=$?
  [[ "$rc" != 0 && "$out" == *"names is sub"*"refusing the launch"* && "$out" != *SPELLED:* ]] \
    && pass "T62 a directory readdir must spell and cannot is refused" \
    || fail "T62 unlistable directory on a case-aliasing filesystem (rc=$rc; out: $out)"
  # ── T63: where Windows looks names up (_win_fs), every name is spelled from
  # readdir even where no directory on the way ignores case (ntfs3 is
  # case-sensitive): an 8.3 short name is never listed (automated security
  # review of 0e0ea9a). Here the same unlistable directory, the filesystem's
  # kind taken as Windows's and nothing else overridden.
  out="$(bash -c '
    set -euo pipefail
    for fn in _ci_path _case_flip _u8_locale _win_path _win_fs _win_mounts _disk_spell _ds_readdir _ci_name _ci_alias_fs _q _term; do eval "$(awk "/^$fn\\(\\) \\{/,/^}\$/" "$1")"; done
    _win_fs() { return 0; }
    v="$2"; _disk_spell v; printf "SPELLED:%s\n" "$v"' _ "$ENGINE/sandbox.sh" "$UNLP" 2>&1)"; rc=$?
  [[ "$rc" != 0 && "$out" == *"names is sub"*"refusing the launch"* && "$out" != *SPELLED:* ]] \
    && pass "T63 where Windows looks names up, a name readdir cannot list is refused, case-sensitive too" \
    || fail "T63 Windows filesystem, no directory ignoring case (rc=$rc; out: $out)"
fi
chmod 755 "$UNL/d"; rm -rf "$UNL"

# ── T71: where /proc/self/mountinfo cannot be read, _win_fs decides by statfs's
# type, and statfs names every FUSE filesystem fuse (virtiofs, smbnetfs,
# ntfs-3g and sshfs alike), so each counts as Windows on any kernel: the
# launch fails closed (bugs review GIT-47). 9p counts as drvfs, SMB and NTFS as
# themselves; ext4 and tmpfs do not.
out="$(bash -c '
  for fn in _win_fs; do eval "$(awk "/^$fn\\(\\) \\{/,/^}\$/" "$1")"; done
  OSTYPE=linux-gnu
  for c in fuse:0 fuse:1 fuseblk:0 v9fs:0 smb2:0 cifs:0 ntfs:0 ext2/ext3:1 tmpfs:1; do
    unset _wf_made; T="${c%:*}"
    _win_mounts() { _wm_ok=0; _wm_wsl="${c#*:}"; }
    stat() { printf "%s\n" "$T"; }
    if _win_fs /d; then r=1; else r=0; fi
    printf "%s=%s " "$c" "$r"
  done' _ "$ENGINE/sandbox.sh" 2>&1)"
[[ "$out" == "fuse:0=1 fuse:1=1 fuseblk:0=1 v9fs:0=1 smb2:0=1 cifs:0=1 ntfs:0=1 ext2/ext3:1=0 tmpfs:1=0 " ]] \
  && pass "T71 without mountinfo, every FUSE filesystem counts as Windows on any kernel, 9p, SMB and NTFS too, ext4 not" \
  || fail "T71 stat fallback (got '$out')"

# ── T38: what the agent can write cannot make the link check noisy or slow.
# Links planted in the launcher's own output directory are not walked; a
# launcher that is itself the working dir (writable by design, with a NOTE) is
# not walked; and at most 200 links per launcher are, with a NOTE beyond that.
OUT38="$TMP/out38"; mkdir -p "$OUT38" "$LAUNCHER/.agent-blocked"
ln -s "$OUT38/x" "$LAUNCHER/.agent-blocked/planted"
EXTRA_MOUNTS="$OUT38" launch "$LAUNCHER" ..
rm -f "$LAUNCHER/.agent-blocked/planted"
! grep -q 'leads somewhere the agent can change' "$ERR" \
  && pass "T38 a link planted in the launcher's output directory is not walked" \
  || fail "T38 planted output-dir link (stderr: $(grep -F 'leads somewhere' "$ERR" | tr '\n' ' '))"
ln -s "$OUT38/x" "$LAUNCHER/outward.conf"
EXTRA_MOUNTS="$OUT38" launch "$LAUNCHER" .
rm -f "$LAUNCHER/outward.conf"
! grep -q 'leads somewhere the agent can change' "$ERR" && grep -q 'NOTE:.*holds a launcher' "$ERR" \
  && pass "T38 a launcher that is the working dir is not walked (its NOTE says it is writable)" \
  || fail "T38 launcher-as-mount-root walked (stderr: $(grep -E 'NOTE|leads somewhere' "$ERR" | tr '\n' ' '))"
MANY="$TMP/many"; mk_launcher "$MANY/p"; mkdir -p "$MANY/w"
for n in $(seq 1 205); do ln -s "../../w/f$n" "$MANY/p/.ai-containers/l$n"; done
EXTRA_MOUNTS="$MANY" launch "$LAUNCHER" "$TMP/app"
[[ "$(grep -c 'leads somewhere the agent can change' "$ERR")" -eq 200 ]] \
  && grep -qF "NOTE: the other launchers the writable mounts expose hold more than 200 symlinks between them;" "$ERR" \
  && pass "T38 at most 200 links of the other launchers are walked, and the cap is named" \
  || fail "T38 cap (warnings: $(grep -c 'leads somewhere' "$ERR"); stderr: $(grep -F 'more than 200' "$ERR"))"

# ── T39: a launcher nested in one that cannot be overlaid needs that outer
# directory pinned, and it cannot be (same name): so it is not protected
# either, and must not be reported READ-ONLY.
NEST39="$TMP/n39"; mkdir -p "$NEST39/a: "; : > "$NEST39/a: /sandbox.sh"; : > "$NEST39/a: /sandbox-common.sh"
mk_launcher "$NEST39/a: /in"
EXTRA_MOUNTS="$NEST39" launch "$LAUNCHER" "$TMP/app"
[[ "$(grep -c "WARNING: cannot protect $NEST39/a: " "$ERR")" -eq 2 ]] && ! grep -qF "READ-ONLY: /workspace/n39/" "$ERR" \
  && pass "T39 a launcher nested in an unprotectable one is not reported READ-ONLY" \
  || fail "T39 nested in unprotectable (stderr: $(grep -E 'cannot protect|READ-ONLY: /workspace/n39' "$ERR" | tr '\n' ' '))"

# ── T40: a writable mount of a directory INSIDE a launcher (its tools.d, say)
# keeps those files writable whatever overlay the launcher gets: named. The
# launcher's own output directory, meant to be written, is not.
EXTRA_MOUNTS="$LAUNCHER/tools.d" launch "$LAUNCHER" ..
grep -qF "NOTE: $LAUNCHER/tools.d, part of launcher $LAUNCHER, is mounted writable at /workspace/tools.d;" "$ERR" \
  && ! grep -qF "NOTE: $LAUNCHER/.agent-blocked, part of launcher" "$ERR" \
  && pass "T40 a writable mount inside a launcher is named; its output directory is not" \
  || fail "T40 inner writable mount (stderr: $(grep -F 'part of launcher' "$ERR" | tr '\n' ' '))"

# ── T41: every launcher mount is recorded for the entrypoint to re-verify, so
# a concurrent container cannot swap a mount's source between the scan and the
# mount. For each overlay (:ro) and pin (:rw) the manifest carries the source's
# device:inode and the container-side destination; the anchor env carries the
# verify dir's own device:inode, and the verify dir is mounted :ro from under
# $HOME/.ai-containers, never from /workspace.
EXTRA_MOUNTS="$TMP" launch "$LAUNCHER" ..
# the verify mount exists, sourced from the group tree, read-only
vline="$(mounts | grep ':/run/ai-launcher:ro$' || true)"
[[ -n "$vline" && "${vline%%:*}" == "$HOME/.ai-containers/.verify-"* ]] \
  && pass "T41 the verify dir is mounted read-only at /run/ai-launcher, from under \$HOME/.ai-containers" \
  || fail "T41 verify mount (got: $vline)"
# the anchor env equals the verify dir's own device:inode
aenv="$(awk 'prev=="-e"{print} {prev=$0}' "$CAPTURE" | sed -n 's/^AI_LAUNCHER_ANCHOR=//p')"
[[ -n "$aenv" && "$aenv" == "$(cat "$CAPTURE.anchor" 2>/dev/null)" ]] \
  && pass "T41 AI_LAUNCHER_ANCHOR is the verify dir's own device:inode" \
  || fail "T41 anchor env (got: '$aenv', dir: '$(cat "$CAPTURE.anchor" 2>/dev/null)')"
# the manifest lists each overlay and pin, with its SOURCE's device:inode and dest
declare -A man=()
while IFS= read -r -d '' dev && IFS= read -r -d '' ino && IFS= read -r -d '' dst; do
  man["$dst"]="$dev:$ino"
done < "$CAPTURE.manifest"
ok=1
# the project overlay (an overlay source) and the pin above it (a pin source)
for pair in "$LAUNCHER=/workspace/$tbase/proj/.ai-containers" "$PROJ=/workspace/$tbase/proj"; do
  src="${pair%%=*}"; dst="${pair#*=}"
  want="$(p_dev_ino "$src" | tr ' ' ':')"
  [[ "${man[$dst]:-}" == "$want" ]] || { ok=0; fail "T41 manifest $dst -> ${man[$dst]:-MISSING} (want $want for $src)"; }
done
[[ "$ok" -eq 1 ]] && pass "T41 the manifest records each overlay and pin by its source's device:inode and its destination"
# nothing under /workspace is a verify source
[[ "${vline%%:*}" != /workspace/* ]] && pass "T41 the verify source is never under /workspace" || fail "T41 verify source is under /workspace: $vline"

# ── T42: nothing to guard → no verify mount and no anchor at all. An open-mode
# launch has no output directories, and here no writable mount holds a
# launcher. (A restricted launch always guards its .agent-blocked: T61.)
: > "$CAPTURE"; ( cd "$LAUNCHER" && bash ./sandbox.sh open "$TMP/app" ) >/dev/null 2>"$ERR" </dev/null
[[ -z "$(mounts | grep ':/run/ai-launcher:ro$' || true)" ]] \
  && [[ -z "$(awk 'prev=="-e"{print} {prev=$0}' "$CAPTURE" | grep '^AI_LAUNCHER_ANCHOR=' || true)" ]] \
  && pass "T42 a launch with nothing to guard adds no verify mount or anchor" \
  || fail "T42 spurious verify machinery (mounts: $(mounts | grep -F /run/ai-launcher | tr '\n' ' '))"
# …and a restricted one guards only its output directory.
launch "$LAUNCHER" "$TMP/app"
[[ "$(tr '\0' '\n' < "$CAPTURE.manifest" 2>/dev/null | grep -c '^/workspace/')" == 1 ]] \
  && grep -qxF /workspace/.agent-blocked <<<"$(tr '\0' '\n' < "$CAPTURE.manifest" 2>/dev/null)" \
  && pass "T42 a restricted launch with no launcher mounts guards only its .agent-blocked" \
  || fail "T42 restricted manifest ($(tr '\0' '\n' < "$CAPTURE.manifest" 2>/dev/null | grep '^/workspace/' | tr '\n' ' '))"

# ── T43: the host launcher must not use GNU-only `stat -c` (macOS has only BSD
# `stat -f`). A shim that rejects -c and serves -f stands in for a BSD host:
# the launch must still reach docker run, with a well-formed anchor, not abort
# under set -euo pipefail. (The manifest's dev:ino need not match anything here;
# on a real macOS host the entrypoint's anchor check then degrades to a skip.)
BSD="$TMP/bsdbin"; mkdir -p "$BSD"
REAL_STAT="$(command -v stat)"
if [[ "$_P_STAT_GNU" == 1 ]]; then f_via="-c"; else f_via="-f"; fi
cat > "$BSD/stat" <<SH
#!/usr/bin/env bash
# BSD-only: no -c. -f FMT is served by the real stat — natively on a BSD host,
# through GNU's -c (same %d/%i letters) on a GNU one.
if [[ "\$1" == -c ]]; then echo "stat: illegal option -- c" >&2; exit 1; fi
if [[ "\$1" == -f ]]; then fmt="\$2"; shift 2; exec "$REAL_STAT" $f_via "\$fmt" "\$@"; fi
exec "$REAL_STAT" "\$@"
SH
chmod +x "$BSD/stat"
: > "$CAPTURE"
( cd "$LAUNCHER" && PATH="$BSD:$PATH" bash ./sandbox.sh restricted .. ) >/dev/null 2>"$ERR"; bsd_rc=$?
[[ "$bsd_rc" -eq 0 && -s "$CAPTURE" ]] \
  && pass "T43 a BSD-only stat host still reaches docker run (no GNU stat -c in the launcher)" \
  || fail "T43 BSD stat launch (rc=$bsd_rc, reached docker=$([[ -s "$CAPTURE" ]] && echo yes || echo no); $(tail -1 "$ERR"))"
aenv="$(awk 'prev=="-e"{print} {prev=$0}' "$CAPTURE" | sed -n 's/^AI_LAUNCHER_ANCHOR=//p')"
[[ "$aenv" =~ ^[0-9]+:[0-9]+$ ]] \
  && pass "T43 the anchor is still a well-formed device:inode via stat -f" \
  || fail "T43 anchor via BSD stat (got: '$aenv')"

# ── T44: the sweep of verify dirs a crashed launch left behind. Swept only when
# BOTH older than an hour and its launcher pid is gone; a fresh one is kept even
# with a dead pid (it may belong to a launch still setting up — a pid can look
# dead from another namespace or host); and a dir that will not go must not
# abort this launch under set -e.
VBASE="$HOME/.ai-containers"; mkdir -p "$VBASE"
sleep 0 & deadpid=$!; wait "$deadpid" 2>/dev/null || true
mkdir -p "$VBASE/.verify-$deadpid-1" "$VBASE/.verify-$deadpid-2" "$VBASE/.verify-$$-3"
touch -t 202001010000 "$VBASE/.verify-$deadpid-1"            # stale: old + dead pid
touch -t 202001010000 "$VBASE/.verify-$$-3"                  # old, but its pid ($$, this test) is alive
launch "$LAUNCHER" ..
[[ ! -e "$VBASE/.verify-$deadpid-1" && -d "$VBASE/.verify-$deadpid-2" && -d "$VBASE/.verify-$$-3" ]] \
  && pass "T44 an old verify dir of a dead launch is swept; a fresh one, or an old one whose pid lives, is kept" \
  || fail "T44 sweep (old+dead: $([[ -e "$VBASE/.verify-$deadpid-1" ]] && echo kept || echo gone), fresh: $([[ -d "$VBASE/.verify-$deadpid-2" ]] && echo kept || echo gone), old+live: $([[ -d "$VBASE/.verify-$$-3" ]] && echo kept || echo gone))"
rm -rf "$VBASE/.verify-$deadpid-2" "$VBASE/.verify-$$-3"
if [[ "$(id -u)" -ne 0 ]]; then
  stuck="$VBASE/.verify-$deadpid-3"; mkdir -p "$stuck/ro"; : > "$stuck/ro/f"; chmod 0500 "$stuck/ro"
  touch -t 202001010000 "$stuck"
  launch "$LAUNCHER" ..
  chmod 0700 "$stuck/ro"; rm -rf "$stuck"
  [[ "${LAUNCH_RC:-1}" -eq 0 && -s "$CAPTURE" ]] \
    && pass "T44 a stale dir that cannot be removed does not abort the launch" \
    || fail "T44 unremovable stale dir aborted the launch (rc=${LAUNCH_RC:-?}; $(tail -1 "$ERR"))"
else
  printf 'SKIP: T44 unremovable stale dir — chmod does not constrain root\n'
fi

# ── T45: the GNU/BSD stat probe must not depend on the working directory. Run
# from one that cannot be searched, a probe of `.` fails, a GNU host is taken
# for BSD, and `stat -f` (GNU: filesystem status) hands the entrypoint garbage
# for an anchor. The anchor must still be two numbers.
if [[ "$(id -u)" -ne 0 ]]; then
  UNS="$TMP/unsearchable"; mkdir -p "$UNS"; : > "$CAPTURE"
  ( cd "$UNS" && chmod 000 "$UNS" && bash "$LAUNCHER/sandbox.sh" open "$PROJ" ) >/dev/null 2>"$ERR" </dev/null
  chmod 0755 "$UNS"
  aenv="$(awk 'prev=="-e"{print} {prev=$0}' "$CAPTURE" | sed -n 's/^AI_LAUNCHER_ANCHOR=//p')"
  [[ "$aenv" =~ ^[0-9]+:[0-9]+$ ]] \
    && pass "T45 launched from an unsearchable directory, the anchor is still device:inode" \
    || fail "T45 unsearchable cwd (anchor: '$aenv'; $(tail -1 "$ERR"))"
else
  printf 'SKIP: T45 — chmod does not constrain root\n'
fi

# ── T46: the agent decides how many launchers there are — two empty files make
# one — so what it plants is bounded per LAUNCH, not per launcher. Past
# SANDBOX_LAUNCHER_MAX (50) launchers and unlistable directories to overlay, the
# launch is refused, naming where; the links of every launcher but this one
# share one budget of 200, and this launcher keeps its own.
FAKE="$TMP/fake46"; mkdir -p "$FAKE/w"
for n in $(seq 1 51); do mk_launcher "$FAKE/p$n"; done
EXTRA_MOUNTS="$FAKE" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF 'ERROR: the writable mounts hold more than 50 launchers and unlistable directories' "$ERR" \
  && grep -qE "^         $FAKE/p[0-9]+/\.ai-containers\$" "$ERR" && grep -qF 'raise SANDBOX_LAUNCHER_MAX' "$ERR" \
  && pass "T46 past SANDBOX_LAUNCHER_MAX the launch is refused, naming where" \
  || fail "T46 cap not enforced (rc=$LAUNCH_RC; stderr: $(grep -A3 ERROR "$ERR" | tr '\n' ' '))"
[[ "$(grep -cE "^         $FAKE/" "$ERR")" -le 5 ]] \
  && pass "T46 the refusal names at most five of them" \
  || fail "T46 refusal floods (named: $(grep -cE "^         $FAKE/" "$ERR"))"
# A name the agent chose reaches your terminal: quoted, never raw escapes.
ESC46="$TMP/esc46"; mk_launcher "$ESC46/a"; mk_launcher "$ESC46/z"$'\e]0;pwned\a'
SANDBOX_LAUNCHER_MAX=1 EXTRA_MOUNTS="$ESC46" launch "$LAUNCHER" "$TMP/app"
! grep -q $'\e' "$ERR" && grep -q 'pwned' "$ERR" && grep -qF 'ERROR: the writable mounts hold more than 1' "$ERR" \
  && pass "T46 a planted name in the refusal is quoted, not printed raw" \
  || fail "T46 raw escape in the refusal (stderr: $(grep -A7 ERROR "$ERR" | cat -v | tr '\n' ' '))"
rm -rf "$ESC46"
SANDBOX_LAUNCHER_MAX=60 EXTRA_MOUNTS="$FAKE" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -s "$CAPTURE" ]] \
  && pass "T46 raising SANDBOX_LAUNCHER_MAX lets the launch through" \
  || fail "T46 raised cap still refused (rc=$LAUNCH_RC; stderr: $(grep -A2 ERROR "$ERR" | tr '\n' ' '))"
SANDBOX_LAUNCHER_MAX=abc EXTRA_MOUNTS="$FAKE" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: SANDBOX_LAUNCHER_MAX must be a whole number from 1 to 999999' "$ERR" \
  && pass "T46 a SANDBOX_LAUNCHER_MAX that is not a number refuses the launch" \
  || fail "T46 bad SANDBOX_LAUNCHER_MAX (rc=$LAUNCH_RC; stderr: $(tr '\n' ' ' < "$ERR"))"
rm -rf "$FAKE"
# A candidate that cannot be mounted (a name that is not UTF-8) gets no overlay,
# so it covers nothing: what is nested in it counts toward the cap. It was
# discounted, and 3,000 launchers under one passed SANDBOX_LAUNCHER_MAX=5 with a
# WARNING each (review of the batch 1 hotfix; LNCH-4).
# APFS refuses a name that is not UTF-8 ("Illegal byte sequence"); there the
# candidate is one with a ':' and a CR, which no form of the bind carries either.
BAD47="$TMP/bad47"; b47="bad"$'\xff'
mk_launcher "$BAD47/$b47" 2>/dev/null || { b47="bad:"$'\r'"x"; mk_launcher "$BAD47/$b47"; }
for n in $(seq 1 8); do mk_launcher "$BAD47/$b47/.ai-containers/n$n"; done
SANDBOX_LAUNCHER_MAX=5 EXTRA_MOUNTS="$BAD47" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: the writable mounts hold more than 5 launchers' "$ERR" \
  && pass "T46 launchers nested in one that cannot be overlaid count toward the cap" \
  || fail "T46 an unrepresentable launcher still discounts what it holds (rc=$LAUNCH_RC)"
rm -rf "$BAD47"
# A launcher candidate you can search but not list can hide a FIFO by name — a
# sandbox.sh the host runs at the next launch, written through the read-only
# overlay — so it refuses, as such a git directory does (automated security
# review of c687370). One nobody can search (chmod 000) keeps the WARNING.
if [[ "$(id -u)" != 0 ]]; then
  SRCH47="$TMP/srch47"; mkdir -p "$SRCH47/d"; chmod 0300 "$SRCH47/d"
  EXTRA_MOUNTS="$SRCH47" launch "$LAUNCHER" "$TMP/app"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "can be searched but not listed" "$ERR" \
    && pass "T46 a launcher candidate searchable but not listable refuses the launch" \
    || fail "T46 searchable unlistable directory not refused (rc=$LAUNCH_RC)"
  chmod 0755 "$SRCH47/d"; rm -rf "$SRCH47"
fi
# The same when only a PIN on the way cannot be handed to docker (a parent named
# `x: `): the overlay loop refuses the whole candidate, so counting must too
# (security review of 019392c).
PIN47="$TMP/pin47"; mkdir -p "$PIN47/x: "; mk_launcher "$PIN47/x: /p"
for n in $(seq 1 8); do mk_launcher "$PIN47/x: /p/.ai-containers/n$n"; done
SANDBOX_LAUNCHER_MAX=5 EXTRA_MOUNTS="$PIN47" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: the writable mounts hold more than 5 launchers' "$ERR" \
  && pass "T46 … and nested in one whose pins cannot be made" \
  || fail "T46 an unmountable pin still discounts what the launcher holds (rc=$LAUNCH_RC)"
rm -rf "$PIN47"
# …and counting them stays cheap: the test above, run per candidate before the
# refusal, cost two od|awk pipelines a launcher — 2,000 planted ones took 52 s
# to be refused, 1 s before it (review of batch 9, finding 1).
MANY47="$TMP/many47"; for n in $(seq 1 2000); do mk_launcher "$MANY47/a/b/n$n"; done
t47=$SECONDS
SANDBOX_LAUNCHER_MAX=5 EXTRA_MOUNTS="$MANY47" launch "$LAUNCHER" "$TMP/app"
t47=$((SECONDS - t47))
[[ "$LAUNCH_RC" != 0 && "$t47" -lt 20 ]] && grep -qF 'ERROR: the writable mounts hold more than 5 launchers' "$ERR" \
  && pass "T46 2,000 planted launchers are refused in seconds (${t47}s)" \
  || fail "T46 counting 2,000 launchers took ${t47}s (rc=$LAUNCH_RC)"
rm -rf "$MANY47"
if [[ "$(id -u)" != 0 ]]; then
  UNR="$TMP/unr46"
  for n in $(seq 1 51); do mkdir -p "$UNR/d$n"; chmod 000 "$UNR/d$n"; done
  EXTRA_MOUNTS="$UNR" launch "$LAUNCHER" "$TMP/app"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: the writable mounts hold more than 50 launchers and unlistable directories' "$ERR" \
    && pass "T46 unlistable directories count toward the same limit" \
    || fail "T46 unlistable dirs not capped (rc=$LAUNCH_RC; stderr: $(grep -A2 ERROR "$ERR" | tr '\n' ' '))"
  chmod -R u+rwx "$UNR"; rm -rf "$UNR"
else
  printf 'SKIP: T46 unlistable directories — chmod does not constrain root\n'
fi
FAKE="$TMP/fake46l"; mkdir -p "$FAKE/w"
for n in 1 2 3; do
  mk_launcher "$FAKE/p$n"
  for m in $(seq 1 150); do ln -s "../../w/f$m" "$FAKE/p$n/.ai-containers/l$m"; done
done
ln -s "$FAKE/w/own" "$LAUNCHER/own46.conf"
# And one with no links, in a mount scanned after: past the budget it is named
# without being searched, so the budget bounds what the search costs too.
FAKE2="$TMP/fake46e"; mk_launcher "$FAKE2/e"
EXTRA_MOUNTS="$FAKE $FAKE2" launch "$LAUNCHER" "$TMP/app"
rm -f "$LAUNCHER/own46.conf"
w46="$(grep -c 'leads somewhere the agent can change' "$ERR")"
[[ "$w46" -eq 201 ]] && grep -qF "WARNING: launcher link $LAUNCHER/own46.conf leads somewhere" "$ERR" \
  && [[ "$(grep -c 'hold more than 200 symlinks between them' "$ERR")" -eq 1 ]] \
  && pass "T46 the other launchers share one 200-link budget; this launcher's own links are still checked" \
  || fail "T46 link budget (warnings: $w46; stderr: $(grep -E 'more than 200|own46' "$ERR" | tr '\n' ' '))"
# Planted launchers can use the budget up before a real one is reached, so
# every launcher whose links went unchecked is named — never a silent stop.
unc46="$(sed -n '/hold more than 200 symlinks between them/,/^[^ ]/p' "$ERR")"
# 150 links each against a 200 budget: the first one walked is checked whole,
# the other two are not — whichever order find hands them over in.
[[ "$(grep -cE "^ +$FAKE/p[123]/\.ai-containers\$" <<<"$unc46")" -eq 2 ]] \
  && pass "T46 the launchers whose links were not all checked are named" \
  || fail "T46 unchecked launchers not named (stderr: $(tr '\n' ' ' <<<"$unc46"))"
grep -qE "^ +$FAKE2/e/\.ai-containers\$" <<<"$unc46" \
  && pass "T46 a launcher reached past the budget is named without being searched" \
  || fail "T46 launcher past the budget searched (stderr: $(tr '\n' ' ' <<<"$unc46"))"
rm -rf "$FAKE" "$FAKE2"

# ── T47: the limit counts what is overlaid, not every launcher found. One
# read-only overlay covers whatever is nested inside it, so launchers there
# cost nothing (review of 643d9bd).
NEST47="$TMP/nest47"; mk_launcher "$NEST47/outer"
for n in 1 2 3; do mk_launcher "$NEST47/outer/.ai-containers/in$n"; done
SANDBOX_LAUNCHER_MAX=1 EXTRA_MOUNTS="$NEST47" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -s "$CAPTURE" ]] && ! grep -q 'ERROR: the writable mounts hold more than' "$ERR" \
  && pass "T47 launchers nested in one overlay count as that one overlay" \
  || fail "T47 nested launchers counted (rc=$LAUNCH_RC; stderr: $(grep -A3 ERROR "$ERR" | tr '\n' ' '))"
rm -rf "$NEST47"

# ── T48: … but only an overlay that is MADE covers what is nested in it. A
# writable mount whose root holds a launcher stays writable (with a NOTE), so
# every launcher nested in it gets an overlay of its own and counts — the agent
# can write those two files at the root (security review of c0d48d9).
ROOT48="$TMP/root48"; mkdir -p "$ROOT48"; : > "$ROOT48/sandbox.sh"; : > "$ROOT48/sandbox-common.sh"
for n in 1 2 3; do mk_launcher "$ROOT48/p$n"; done
SANDBOX_LAUNCHER_MAX=2 EXTRA_MOUNTS="$ROOT48" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: the writable mounts hold more than 2 launchers' "$ERR" \
  && pass "T48 launchers under a mount-root launcher, which is not overlaid, each count" \
  || fail "T48 mount-root launcher hid its nested ones from the limit (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|NOTE' "$ERR" | tr '\n' ' '))"
rm -rf "$ROOT48"

# ── T49: names the agent chose reach your terminal without their escapes ──────
# The refusal listings used %q (T46); every other launcher message printed a
# scanned path raw, so a name with ESC ] 0 ; … BEL retitled the terminal, and
# cursor movement could rewrite the warnings around it (LNCH-3).
ESC48="$TMP/esc48"; mk_launcher "$ESC48/p"; mkdir -p "$ESC48/shared"; : > "$ESC48/shared/real.conf"
ln -s ../../shared/real.conf "$ESC48/p/.ai-containers/x"$'\e]0;pwned48\a'".conf"
# …and the C1 CSI (U+009B) and a right-to-left override (U+202E), as UTF-8 writes them.
ln -s ../../shared/real.conf "$ESC48/p/.ai-containers/c1"$'\xc2\x9b'"pwned48c1.conf"
ln -s ../../shared/real.conf "$ESC48/p/.ai-containers/bidi"$'\xe2\x80\xae'"pwned48bd.conf"
EXTRA_MOUNTS="$ESC48" launch "$LAUNCHER" "$TMP/app"
grep -q 'pwned48c1' "$ERR" && grep -q 'pwned48bd' "$ERR" \
  && ! grep -q $'\xc2\x9b' "$ERR" && ! grep -q $'\xe2\x80\xae' "$ERR" \
  && pass "T49 … nor a C1 control or a bidi override" \
  || fail "T49 a C1 control or bidi override reached the terminal: $(grep -a pwned48 "$ERR" | od -c | head -3 | tr '\n' ' ')"
grep -q 'pwned48' "$ERR" && ! grep -q $'\e' "$ERR" && ! grep -q $'\a' "$ERR" \
  && pass "T49 a planted link name in a launcher WARNING carries no raw control characters" \
  || fail "T49 raw control characters reached the terminal: $(grep -a pwned48 "$ERR" | cat -v | head -2 | tr '\n' ' ')"
rm -rf "$ESC48"

# ── T50: the FIFO check does not search what stays writable inside an overlay:
# nothing on the host reads the agent's output directories, and a FIFO or a
# mode-000 directory there refused every later launch (review of c687370). One
# elsewhere in the overlay is still refused, naming the directory it could not
# search.
mkdir -p "$LAUNCHER/.agent-blocked"; mkfifo "$LAUNCHER/.agent-blocked/f50"; mkdir -p "$LAUNCHER/.agent-blocked/d50"; chmod 000 "$LAUNCHER/.agent-blocked/d50"
launch "$LAUNCHER" "$PROJ"
[[ "$LAUNCH_RC" == 0 ]] && pass "T50 a FIFO or a 000 directory in .agent-blocked does not refuse the launch" \
  || fail "T50 .agent-blocked contents refused the launch (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
chmod 755 "$LAUNCHER/.agent-blocked/d50"; rm -rf "$LAUNCHER/.agent-blocked/f50" "$LAUNCHER/.agent-blocked/d50"
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$LAUNCHER/tools.d/d50"; chmod 000 "$LAUNCHER/tools.d/d50"
  launch "$LAUNCHER" "$PROJ"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "$LAUNCHER/tools.d/d50" "$ERR" \
    && pass "T50 a directory the FIFO check cannot search is named in the refusal" \
    || fail "T50 unsearchable directory in an overlay (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$LAUNCHER/tools.d/d50"; rm -rf "$LAUNCHER/tools.d/d50"
fi

# ── T51: a stale TMPDIR (LNCH-14). The FIFO search needs a temporary file only
# when something is bound read-only; a launch that binds nothing read-only must
# not be stopped by it, and one that does is refused naming the TMPDIR.
TMPDIR="$TMP/no-such-tmp51" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && pass "T51 a stale TMPDIR does not refuse a launch that binds nothing read-only" \
  || fail "T51 a stale TMPDIR refused a launch with nothing to search (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
TMPDIR="$TMP/no-such-tmp51" launch "$LAUNCHER" "$PROJ"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "in $TMP/no-such-tmp51 (TMPDIR)" "$ERR" \
  && pass "T51 a stale TMPDIR refuses a launch with read-only binds, naming the TMPDIR" \
  || fail "T51 the refusal does not name the TMPDIR (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
# The index read needs a temporary directory too: it says so once per launch,
# naming the TMPDIR, rather than once per index (LNCH-15). Two repositories
# with an index each, so "once" is tested.
for r in r51a r51b; do
  mkdir -p "$TMP/g51/$r" && git -C "$TMP/g51/$r" init -q && : > "$TMP/g51/$r/f" && git -C "$TMP/g51/$r" add f
done
TMPDIR="$TMP/no-such-tmp51" EXTRA_MOUNTS="$TMP/g51" launch "$LAUNCHER" "$TMP/app"
[[ "$(grep -cF "cannot make a temporary directory in $TMP/no-such-tmp51 (TMPDIR)" "$ERR")" == 1 ]] \
  && pass "T51 the index read names the TMPDIR it could not use, once" \
  || fail "T51 the index read's TMPDIR warning (count: $(grep -cF 'cannot make a temporary directory' "$ERR"))"
rm -rf "$TMP/g51"

# ── T52: %q prints a bidi override raw, so every scanned name goes through _q ─
# glibc counts U+202A-U+202E and U+2066-U+2069 printable, and %q passed them to
# the terminal, reordering the name a refusal or a hint points at (LNCH-8).
B52="$TMP/bidi52"; for n in 1 2 3; do mk_launcher "$B52/p$n"$'\xe2\x80\xae'"x"; done
SANDBOX_LAUNCHER_MAX=1 EXTRA_MOUNTS="$B52" launch "$LAUNCHER" "$TMP/app"
rc52=$LAUNCH_RC; raw52=0; grep -q $'\xe2\x80\xae' "$ERR" && raw52=1
rm -rf "$B52"; mk_launcher "$B52/q"; mkdir -p "$B52/q/.ai-containers/d"$'\xe2\x81\xa6'"z"; mkfifo "$B52/q/.ai-containers/d"$'\xe2\x81\xa6'"z/f"
EXTRA_MOUNTS="$B52" launch "$LAUNCHER" "$TMP/app"
grep -q $'\xe2\x81\xa6' "$ERR" && raw52=$((raw52 + 2))
# …and the rm hint stays exact when pasted: `$'…'` with the bytes escaped, never
# a `?` in their place, which an unquoted paste reads as a glob (automated
# security review of f999f25).
[[ "$rc52" != 0 && "$LAUNCH_RC" != 0 && "$raw52" == 0 ]] && grep -qF 'Remove it on the host (rm ' "$ERR" \
  && { grep -qF '\342\201\246' "$ERR" || grep -qF '\xe2\x81\xa6' "$ERR"; } \
  && ! grep -qF 'd?z' <<<"$(grep -F 'Remove it on the host (rm ' "$ERR")" \
  && pass "T52 a bidi override in a refusal listing or an rm hint does not reach the terminal" \
  || fail "T52 bidi reached the terminal (listing rc=$rc52, rm rc=$LAUNCH_RC, raw=$raw52; $(grep -aF 'rm ' "$ERR" | head -1))"
rm -rf "$B52"

# ── T53: a stale TMPDIR stops only a launch that needs a temporary file ──────
# The FIFO search's file was made on every launch, and the error did not say
# which directory it could not write (LNCH-14).
TMPDIR=/nonexistent53 launch "$LAUNCHER" "$TMP/app"; rc53a=$LAUNCH_RC
TMPDIR=/nonexistent53 launch "$LAUNCHER" "$PROJ"
[[ "$rc53a" == 0 && "$LAUNCH_RC" != 0 ]] && grep -qF '/nonexistent53' "$ERR" && grep -qF 'TMPDIR' "$ERR" \
  && pass "T53 a bad TMPDIR stops only a launch with something to search, and is named" \
  || fail "T53 bad TMPDIR (nothing to search rc=$rc53a; to search rc=$LAUNCH_RC: $(grep -F ERROR "$ERR" | head -1))"

# ── T55: what the agent leaves in its output directories cannot block a launch
# .agent-blocked is a writable mount root of its own, so a 0100 or 0311
# directory the agent made there was refused as an unlistable candidate on
# every later launch; the host reads that directory only as data (LNCH-9).
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$LAUNCHER/.agent-blocked/d55" "$LAUNCHER/.agent-blocked/e55"; chmod 0100 "$LAUNCHER/.agent-blocked/d55"; chmod 0311 "$LAUNCHER/.agent-blocked/e55"
  launch "$LAUNCHER" "$TMP/app"; rc55a=$LAUNCH_RC
  chmod 0755 "$LAUNCHER/.agent-blocked/d55" "$LAUNCHER/.agent-blocked/e55"; rm -rf "$LAUNCHER/.agent-blocked/d55" "$LAUNCHER/.agent-blocked/e55"
  # …and launched from the project root, where the output directories are the
  # project's own and the project mount reaches them too (review of the batch 10
  # branch).
  mkdir -p "$PROJ/.agent-blocked/e55"; chmod 0311 "$PROJ/.agent-blocked/e55"; : > "$CAPTURE"
  ( cd "$PROJ" && bash ./.ai-containers/sandbox.sh restricted "$PROJ" ) >/dev/null 2>"$ERR" </dev/null; LAUNCH_RC=$?
  chmod 0755 "$PROJ/.agent-blocked/e55"; rm -rf "$PROJ/.agent-blocked" "$PROJ/.agent-discovery"
  [[ "$rc55a" == 0 && "$LAUNCH_RC" == 0 ]] && pass "T55 an unlistable directory the agent left in .agent-blocked does not refuse the launch, whichever mount reaches it" \
    || fail "T55 .agent-blocked blocked the launch (own mount rc=$rc55a; project root rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
fi

# ── T56, T57: the FIFO search is bounded, and runs again just before docker ──
# It walked every file of every read-only source with no bound, the agent
# deciding how many (LNCH-10); and a FIFO a concurrent container made after it,
# before docker ran, went unseen (LNCH-11). A stand-in find answers for the FIFO
# search only (the one with -quit) and passes everything else through.
FS="$TMP/fshim"; mkdir -p "$FS"; REALFIND="$(command -v find)"
printf '#!/bin/bash\ncase " $* " in *" -quit "*) printf "%%s\\n" "$*" >> %q; [[ "${FIND_SHIM:-}" == slow ]] && exit 124;; esac\nexec %q "$@"\n' \
  "$TMP/fshim.log" "$REALFIND" > "$FS/find"; chmod +x "$FS/find"
: > "$TMP/fshim.log"; FIND_SHIM=slow PATH="$FS:$PATH" launch "$LAUNCHER" "$PROJ"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "could not be searched for FIFOs within" "$ERR" && grep -qF "$LAUNCHER" "$ERR" \
  && pass "T56 a FIFO search that runs out of time refuses the launch, naming the directory" \
  || fail "T56 unbounded FIFO search (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
: > "$TMP/fshim.log"; PATH="$FS:$PATH" launch "$LAUNCHER" "$PROJ"
n57="$(grep -cF -- "$LAUNCHER " "$TMP/fshim.log")"
[[ "$LAUNCH_RC" == 0 && "$n57" -ge 2 ]] \
  && pass "T57 the FIFO search runs again just before docker ($n57 searches of the launcher)" \
  || fail "T57 FIFO re-search (rc=$LAUNCH_RC; $n57 searches of the launcher)"
rm -rf "$FS" "$TMP/fshim.log"

# ── T58: a FIFO inside .git/objects is searched for too ──────────────────────
# git reads objects/info/alternates, and the packs, so skipping .git/objects let
# the agent feed the host's git which object stores it uses (automated security
# review of f1817ce).
mk_launcher "$TMP/obj58/p"; git init -q "$TMP/obj58/p/.ai-containers" 2>/dev/null \
  && mkfifo "$TMP/obj58/p/.ai-containers/.git/objects/info/alternates"
EXTRA_MOUNTS="$TMP/obj58" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'objects/info/alternates is a FIFO' "$ERR" \
  && pass "T58 a FIFO at .git/objects/info/alternates refuses the launch" \
  || fail "T58 FIFO in .git/objects (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
( exec 3<>"$TMP/obj58/p/.ai-containers/.git/objects/info/alternates" ) 2>/dev/null; rm -rf "$TMP/obj58"

# ── T59: the FIFO search has one budget per launch ──────────────────────────
# 30 s per source, with the agent deciding how many sources there are, and a
# second run before docker, let planted launchers each kept just under 30 s make
# a launch take hours (review of the batch 10 branch). One budget covers both
# runs; spent, the launch is refused. Started here with it already spent.
fns59="$TMP/fns59.sh"
for f59 in _term _q _timeout_prefix _ro_fifo_search; do
  awk -v f="$f59() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns59"
mkdir -p "$TMP/src59"
bash -c 'source "$1"; srcs=("$2"); rw=(); _fs_deadline=$((SECONDS - 1)); _ro_fifo_search srcs rw; echo continued' _ "$fns59" "$TMP/src59" >"$TMP/o59" 2>"$TMP/e59"; rc59=$?
[[ "$rc59" != 0 && ! -s "$TMP/o59" ]] && grep -qF 'budget' "$TMP/e59" \
  && pass "T59 a FIFO search past the launch's budget refuses the launch" \
  || fail "T59 FIFO search budget (rc=$rc59; $(cat "$TMP/o59" "$TMP/e59" | tr '\n' ' '))"
rm -rf "$fns59" "$TMP/src59" "$TMP/o59" "$TMP/e59"

# ── T60: an output directory that is a link refuses the launch ──────────────
# The launch dir's .agent-blocked is mounted writable at /workspace/.agent-
# blocked, and docker follows a link there: launched from the project root, a
# link the agent left in an earlier session mounted wherever it pointed — a
# launcher, ~/.ssh — writable for the agent (automated security review of
# 8da6755). A link, or anything but a directory, is refused, before docker.
mkdir -p "$TMP/target60"; rm -rf "$PROJ/.agent-blocked"; ln -s "$TMP/target60" "$PROJ/.agent-blocked"; : > "$CAPTURE"
( cd "$PROJ" && bash ./.ai-containers/sandbox.sh restricted "$PROJ" ) >/dev/null 2>"$ERR" </dev/null; LAUNCH_RC=$?
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF '.agent-blocked' "$ERR" && ! grep -qF "$TMP/target60" "$CAPTURE" \
  && pass "T60 an output directory that is a link refuses the launch, before docker" \
  || fail "T60 a linked output directory (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); mounted: $(grep -c target60 "$CAPTURE"))"
rm -f "$PROJ/.agent-blocked"; rm -rf "$TMP/target60"

# ── T61: the output directories join the verify manifest ────────────────────
# T60 checks them before docker, but a concurrent container of the same project
# could swap .agent-blocked for a link in between; recorded by device:inode, a
# swap is refused by the entrypoint like any overlay's (automated security
# review of 1665dce; review of the batch 10 branch, reproduced). Restricted
# mode's .agent-blocked and discovery mode's .agent-discovery alike.
ok61=""
for m61 in restricted discovery; do
  : > "$CAPTURE"; rm -f "$CAPTURE.manifest"
  ( cd "$PROJ" && bash ./.ai-containers/sandbox.sh "$m61" "$PROJ" ) >/dev/null 2>"$ERR" </dev/null
  d61=/workspace/.agent-blocked; [[ "$m61" == discovery ]] && d61=/workspace/.agent-discovery
  # …with the directory's own device:inode, which is what the entrypoint compares
  # (a 0 0 passed the name-only check; review of the batch 10 branch).
  want61="$(p_dev_ino "$PROJ/${d61#/workspace/}")"; got61=""
  mapfile -d '' -t man61 < "$CAPTURE.manifest" 2>/dev/null || man61=()
  for (( i61 = 0; i61 + 2 < ${#man61[@]}; i61 += 3 )); do
    [[ "${man61[i61+2]}" == "$d61" ]] && got61="${man61[i61]} ${man61[i61+1]}"
  done
  [[ -n "$got61" && "$got61" == "$want61" ]] && ok61+=" $m61"
done
rm -rf "$PROJ/.agent-blocked" "$PROJ/.agent-discovery"
[[ "$ok61" == " restricted discovery" ]] && pass "T61 each output directory is recorded in the verify manifest, in both modes" \
  || fail "T61 output directories in the manifest (recorded for:$ok61)"

# ── T64: a launcher left writable stays home ────────────────────────────────
# A launcher whose name docker cannot carry gets no overlay (T24), so the agent
# can change all of it and was told so once, by name. A link inside it that
# stays inside it is not warned about again, once per link: the step is in no
# writable bind of the launcher's own (sandbox.sh: `_walk_exposed()`, its
# <home>). One that leads out of it into a writable mount still is, which shows
# its links were walked at all (GAP-2 slice 3: every damage to the <home> test
# survived, because a launcher with an overlay is read-only either way).
UR64="$TMP/ur64"; mk_launcher "$UR64/c:o "; L64="$UR64/c:o /.ai-containers"
: > "$TMP/app/x64"
ln -s sandbox.sh "$L64/home64.sh"; ln -s "$TMP/app/x64" "$L64/out64.sh"
EXTRA_MOUNTS="$UR64" launch "$LAUNCHER" "$TMP/app"
rm -f "$TMP/app/x64"; rm -rf "$UR64"
if grep -aqF "WARNING: cannot protect $L64" "$ERR" \
   && grep -aqF "launcher link $L64/out64.sh leads somewhere the agent can change" "$ERR" \
   && ! grep -aqF "launcher link $L64/home64.sh" "$ERR"; then
  pass "T64 in a launcher that could not be overlaid, a link that stays inside it is not warned about again"
else
  fail "T64 a writable launcher's own links (rc=$LAUNCH_RC; stderr: $(grep -aF 'ur64' "$ERR" | tr '\n' ' '))"
fi
# One with a writable bind of its own inside it (here the primary, a directory
# there, which gets a NOTE): a step inside the launcher is judged only where it
# lies in that bind. The launcher's name, a ':' and a trailing space, is one
# docker cannot carry; the bind's, which holds the ':' but does not end in the
# space, goes through --mount (LNCH-22). Skipped where the filesystem refuses
# the name, as T24's are.
B64="$TMP/b64"; L64b="$B64/c:o /.ai-containers"
if mk_launcher "$B64/c:o " 2>/dev/null; then
  mkdir -p "$L64b/inner64"; : > "$L64b/inner64/x64"
  ln -s sandbox.sh "$L64b/home64.sh"; ln -s inner64/x64 "$L64b/in64.sh"
  EXTRA_MOUNTS="$B64" launch "$LAUNCHER" "$L64b/inner64"
  if [[ "$LAUNCH_RC" == 0 ]] && grep -aqF "WARNING: cannot protect $B64/c:o " "$ERR" \
     && grep -aqF "/in64.sh leads somewhere the agent can change" "$ERR" \
     && ! grep -aqF "home64.sh" "$ERR"; then
    pass "T64 in a launcher that could not be overlaid, with a writable bind inside it, a link that stays out of that bind is not warned about"
  else
    fail "T64 a writable launcher with a bind inside it (rc=$LAUNCH_RC; stderr: $(grep -aF 'b64' "$ERR" | tr '\n' ' '))"
  fi
else
  printf 'SKIP: T64 a launcher whose name holds a colon — this filesystem refuses it\n'
fi
rm -rf "$B64"

# ── T65: a link to a writable mount's root ──────────────────────────────────
# A mount point cannot be swapped for a link, so a way that steps OUT of one
# (`..`) is safe there; what lies in it can still be changed. A launcher link to
# the root of the working dir is warned about (GAP-2 slice 3: taking every step
# at a mount root as safe survived).
ln -s "$TMP/app" "$LAUNCHER/approot65"
launch "$LAUNCHER" "$TMP/app"
rm -f "$LAUNCHER/approot65"
grep -qF "it can change $TMP/app (at /workspace/app)" \
     <<<"$(grep -A1 -F "launcher link $LAUNCHER/approot65 leads" "$ERR")" \
  && pass "T65 a launcher link to a writable mount's root is warned about" \
  || fail "T65 link to a mount root (rc=$LAUNCH_RC; stderr: $(grep -A1 -F 'approot65' "$ERR" | tr '\n' ' '))"

# ── T66: on Colima the manifest holds the VM's device:inode ──────────────────
# Colima's file sharing does not keep device:inode across a bind, so the host's
# stat let the entrypoint skip the check on every launch (PLAT-3, GAP-11). Its VM
# reports what the containers see; every recorded source and the anchor come from
# there, through one `colima ssh` whose argv holds no path (the agent names the
# directories). A fake `colima` stands in for the VM: device 77, the inode a
# checksum of the path, so a record mapped to the wrong path shows.
T66="$TMP/t66"; odd66=$'a:b\nc'
mkdir -p "$T66/$odd66" && cp -R "$LAUNCHER" "$T66/$odd66/"
cat > "$TMP/bin/colima" <<COLIMA
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CAPTURE.colima"
[[ -z "\${FAKE_COLIMA_FAIL:-}" ]] || exit 1
while IFS= read -r -d '' p; do
  [[ -n "\${FAKE_COLIMA_MISS:-}" && "\$p" == "\$FAKE_COLIMA_MISS" ]] && continue
  printf '77:%s:%s\0' "\$(printf '%s' "\$p" | cksum | cut -d' ' -f1)" "\$p"
done
COLIMA
chmod +x "$TMP/bin/colima"
vm66() { printf '77 %s' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
# man66 <dst>: what the manifest records for that destination.
man66() {
  local -a m; local i
  mapfile -d '' -t m < "$CAPTURE.manifest" 2>/dev/null || m=()
  for (( i = 0; i + 2 < ${#m[@]}; i += 3 )); do [[ "${m[i+2]}" == "$1" ]] && printf '%s %s' "${m[i]}" "${m[i+1]}"; done
}
src66="$T66/$odd66/.ai-containers"; dst66="/workspace/t66/$odd66/.ai-containers"
colima66="unix://$HOME/.colima/default/docker.sock"
rm -f "$CAPTURE.colima" "$CAPTURE.manifest"
FAKE_DOCKER_ENDPOINT="$colima66" EXTRA_MOUNTS="$T66" launch "$LAUNCHER" "$TMP/app"
aenv66="$(awk 'prev=="-e"{print} {prev=$0}' "$CAPTURE" | sed -n 's/^AI_LAUNCHER_ANCHOR=//p')"
vdir66="$(cat "$CAPTURE.vdir" 2>/dev/null)"
if [[ "$(man66 "$dst66")" == "$(vm66 "$src66")" && "$(man66 "/workspace/t66/$odd66")" == "$(vm66 "$T66/$odd66")" \
      && "$(man66 /workspace/.agent-blocked)" == "$(vm66 "$LAUNCHER/.agent-blocked")" \
      && -n "$vdir66" && "$aenv66" == "$(vm66 "$vdir66" | tr ' ' ':')" ]]; then
  pass "T66 on Colima the manifest and the anchor hold the VM's device:inode, each for its own path"
else
  fail "T66 VM ids (rc=$LAUNCH_RC; $dst66 -> '$(man66 "$dst66")' want '$(vm66 "$src66")'; anchor '$aenv66'; stderr: $(tail -3 "$ERR" | tr '\n' ' '))"
fi
# Only fixed arguments reach the VM: the paths go on stdin.
[[ "$(cat "$CAPTURE.colima" 2>/dev/null)" == "$(printf '%s\n' ssh -p default -- xargs -0 stat '--printf=%d:%i:%n\0' --)" ]] \
  && pass "T66 colima ssh gets the profile and a fixed command, no path" \
  || fail "T66 colima argv: $(tr '\n' ' ' < "$CAPTURE.colima" 2>/dev/null)"
# A source the VM cannot stat is recorded 0:0, which the entrypoint refuses, not
# the host's device:inode, which would pass for nothing there.
FAKE_COLIMA_MISS="$src66" FAKE_DOCKER_ENDPOINT="$colima66" EXTRA_MOUNTS="$T66" launch "$LAUNCHER" "$TMP/app"
[[ "$(man66 "$dst66")" == "0 0" && "$(man66 /workspace/.agent-blocked)" == "$(vm66 "$LAUNCHER/.agent-blocked")" ]] \
  && pass "T66 a source the VM cannot stat is recorded as 0:0" \
  || fail "T66 VM miss: $dst66 -> '$(man66 "$dst66")'"
# No answer from the VM, or a socket that is not Colima's: the host's, as before
# (the entrypoint then skips with its NOTE: where they do not survive the bind).
FAKE_COLIMA_FAIL=1 FAKE_DOCKER_ENDPOINT="$colima66" EXTRA_MOUNTS="$T66" launch "$LAUNCHER" "$TMP/app"
[[ "$(man66 "$dst66")" == "$(p_dev_ino "$src66")" ]] \
  && pass "T66 when the VM does not answer, the host's device:inode is recorded" \
  || fail "T66 VM failure: $dst66 -> '$(man66 "$dst66")' want '$(p_dev_ino "$src66")'"
for ep66 in unix:///var/run/docker.sock "unix://$HOME/.colima/../x/docker.sock"; do
  rm -f "$CAPTURE.colima"
  FAKE_DOCKER_ENDPOINT="$ep66" EXTRA_MOUNTS="$T66" launch "$LAUNCHER" "$TMP/app"
  [[ ! -e "$CAPTURE.colima" && "$(man66 "$dst66")" == "$(p_dev_ino "$src66")" ]] \
    && pass "T66 docker at $ep66 is not Colima's: colima is not asked" \
    || fail "T66 $ep66: colima asked ($(tr '\n' ' ' < "$CAPTURE.colima" 2>/dev/null)), $dst66 -> '$(man66 "$dst66")'"
done
rm -f "$TMP/bin/colima"; rm -rf "$T66"

# ── T67: a host path holding ':', or bytes that are not UTF-8 ──────────────
# docker splits a `-v` value at every ':', and refused the whole launch over a
# primary, an EXTRA_MOUNTS entry, a pointer or a launch directory named with
# one; the overlay scan, splitting the same way, searched a directory of
# another name in its place. Every bind now goes through _bind_mount_arg, which
# hands such a name to --mount, and the scan reads that form too (bugs review
# LNCH-22).
P67="$TMP/p:67"; mk_launcher "$P67"; mk_launcher "$TMP/f:67"; mkdir -p "$TMP/e:67" "$TMP/v:67"
EXTRA_MOUNTS="$TMP/e:67 $TMP/f:67:ro" VAULT_PATH="$TMP/v:67" launch "$LAUNCHER" "$P67"
m67="$(mounts)"
if [[ "$LAUNCH_RC" == 0 ]] \
   && grep -qxF -- "type=bind,\"source=$P67\",\"destination=/workspace/p:67\"" "$CAPTURE"; then
  pass "T67 a primary whose name holds ':' reaches docker through --mount"
else
  fail "T67 primary with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F 'p:67' "$CAPTURE" | tr '\n' ' '))"
fi
grep -qxF -- "$P67/.ai-containers:/workspace/p:67/.ai-containers:ro" <<<"$m67" \
  && pass "T67 a launcher inside a mount whose name holds ':' is overlaid read-only (the scan read the --mount form)" \
  || fail "T67 launcher inside a ':' mount not overlaid (mounts: $(grep -F 'p:67' <<<"$m67" | tr '\n' ' '))"
grep -qxF -- "type=bind,\"source=$TMP/e:67\",\"destination=/workspace/e:67\"" "$CAPTURE" \
  && grep -qxF -- "type=bind,\"source=$TMP/f:67\",\"destination=/workspace/f:67\",readonly" "$CAPTURE" \
  && pass "T67 an EXTRA_MOUNTS entry holding ':' is mounted, a trailing :ro read as its mode" \
  || fail "T67 EXTRA_MOUNTS with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F ':67' "$CAPTURE" | tr '\n' ' '))"
grep -qxF -- "type=bind,\"source=$TMP/v:67\",\"destination=/workspace/vault\"" "$CAPTURE" \
  && pass "T67 a VAULT_PATH holding ':' is mounted through --mount" \
  || fail "T67 VAULT_PATH with ':' (args: $(grep -F 'v:67' "$CAPTURE" | tr '\n' ' '))"
# Read-only (--mount's `readonly`) is read back as such: nothing in it is
# overlaid, as nothing in a `-v …:ro` is.
! grep -qF -- "$TMP/f:67/.ai-containers:" <<<"$m67" && grep -qxF -- "$TMP/f:67:/workspace/f:67:ro" <<<"$m67" \
  && pass "T67 a launcher inside a read-only mount whose name holds ':' gets no overlay" \
  || fail "T67 read-only ':' mount scanned as writable (mounts: $(grep -F 'f:67' <<<"$m67" | tr '\n' ' '))"
rm -rf "$P67" "$TMP/e:67" "$TMP/f:67" "$TMP/v:67"
# The --mount record is CSV: a name holding ',' and '"' (doubled) is read back
# whole, so a launcher in it is overlaid (review of the LNCH-22 fix: splitting at
# a quoted comma, or not taking "" for one quote, switched the overlay off).
Q67="$TMP/q:r,\"s67"; mk_launcher "$Q67"
launch "$LAUNCHER" "$Q67"
grep -qxF -- "$Q67/.ai-containers:/workspace/q:r,\"s67/.ai-containers:ro" <<<"$(mounts)" \
  && pass "T67 a launcher inside a mount named with ':', ',' and '\"' is overlaid read-only" \
  || fail "T67 CSV-quoted mount name (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); mounts: $(mounts | grep -F 's67' | tr '\n' ' '))"
rm -rf "$Q67"
# A suffix of options `-v` takes is still the mode, passed through as before;
# a path holding ':' whose mode is more than ro or rw, which --mount as written
# cannot carry, refuses the launch rather than lose the option.
mkdir -p "$TMP/c67" "$TMP/d:67"
EXTRA_MOUNTS="$TMP/c67:ro,z" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "$TMP/c67:/workspace/c67:ro,z" "$CAPTURE" \
  && pass "T67 an EXTRA_MOUNTS entry's option list (:ro,z) still reaches -v as its mode" \
  || fail "T67 EXTRA_MOUNTS :ro,z (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F 'c67' "$CAPTURE" | tr '\n' ' '))"
EXTRA_MOUNTS="$TMP/d:67:ro,z" launch "$LAUNCHER" "$TMP/app"
if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "$TMP/d:67"; then
  pass "T67 a path holding ':' with an option --mount is not given refuses the launch, naming it"
else
  fail "T67 ':' with ro,z (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
fi
# A trailing comma is no option list: the entry is read as a path, which does
# not exist.
EXTRA_MOUNTS="$TMP/c67:ro," launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -aqF "EXTRA_MOUNTS path does not exist: $TMP/c67:ro," "$ERR" \
  && pass "T67 an EXTRA_MOUNTS suffix ending in a comma is not read as a mode" \
  || fail "T67 EXTRA_MOUNTS :ro, (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# The mode refusal names the name holding the ':': here the destination, a
# link's own name, not the directory it leads to.
ln -s "$TMP/c67" "$TMP/a:b67"
EXTRA_MOUNTS="$TMP/a:b67:ro,z" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -aqF "/workspace/a:b67 holds a \":\"" "$ERR" \
  && pass "T67 the mode refusal names the destination when the ':' is there" \
  || fail "T67 mode refusal at the destination (rc=$LAUNCH_RC; stderr: $(grep -a -A1 'ERROR' "$ERR" | head -3 | tr '\n' ' '))"
rm -f "$TMP/a:b67"
rm -rf "$TMP/c67" "$TMP/d:67"
# SPECS_PATH, and DOCS_PATH and ARCHITECTURE_REPO_PATH asked for :rw: each
# reaches docker through --mount (review of the LNCH-22 fix: these call sites,
# reverted to a raw -v, survived).
mkdir -p "$TMP/s:67" "$TMP/d:67" "$TMP/a:67"
SPECS_PATH="$TMP/s:67" DOCS_PATH="$TMP/d:67:rw" ARCHITECTURE_REPO_PATH="$TMP/a:67:rw" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "type=bind,\"source=$TMP/s:67\",\"destination=/workspace/specs\"" "$CAPTURE" \
  && grep -qxF -- "type=bind,\"source=$TMP/d:67\",\"destination=/workspace/docs\"" "$CAPTURE" \
  && grep -qxF -- "type=bind,\"source=$TMP/a:67\",\"destination=/workspace/architecture\"" "$CAPTURE" \
  && pass "T67 SPECS_PATH, DOCS_PATH and ARCHITECTURE_REPO_PATH holding ':' reach docker through --mount" \
  || fail "T67 pointers with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F ':67' "$CAPTURE" | tr '\n' ' '))"
rm -rf "$TMP/s:67" "$TMP/d:67" "$TMP/a:67"
# A REPOS entry this host bind-mounts (the Linux bind backend).
mkdir -p "$TMP/r:67src" "$HOME/.ai-containers"; cp -p "$HOME/.ai-containers/repos.conf" "$TMP/repos67.bak" 2>/dev/null
printf 'r67|path|%s|2026-11-08|2026-11-08|bind\n' "$TMP/r:67src" >> "$HOME/.ai-containers/repos.conf"
REPOS="r67:rw" launch "$LAUNCHER" "$TMP/app"
grep -qxF -- "type=bind,\"source=$TMP/r:67src\",\"destination=/workspace/r67\"" "$CAPTURE" \
  && pass "T67 a REPOS bind whose source holds ':' reaches docker through --mount" \
  || fail "T67 REPOS bind with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F 'r67' "$CAPTURE" | tr '\n' ' '))"
if [[ -f "$TMP/repos67.bak" ]]; then mv "$TMP/repos67.bak" "$HOME/.ai-containers/repos.conf"; else rm -f "$HOME/.ai-containers/repos.conf"; fi
rm -rf "$TMP/r:67src"
# A HOME holding ':': the group's directories, its files (.gitconfig, read-only)
# and the verify directory.
H67="$TMP/h:67"; mkdir -p "$H67"; printf '[user]\n' > "$H67/.gitconfig"
HOME="$H67" launch "$LAUNCHER" "$TMP/app"
if [[ "$LAUNCH_RC" == 0 ]] \
   && grep -qxF -- "type=bind,\"source=$H67/.ai-containers/default/.ssh\",\"destination=/home/tester/.ssh\"" "$CAPTURE" \
   && grep -qxF -- "type=bind,\"source=$H67/.ai-containers/default/.gitconfig\",\"destination=/home/tester/.gitconfig\",readonly" "$CAPTURE" \
   && grep -qF -- '"destination=/run/ai-launcher",readonly' "$CAPTURE"; then
  pass "T67 under a HOME holding ':', the group's directories and files and the verify directory reach docker through --mount"
else
  fail "T67 HOME with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F 'h:67' "$CAPTURE" | head -3 | tr '\n' ' '))"
fi
rm -rf "$H67"
# A HOME that is not UTF-8 whose ~/.ai-containers links to a directory that is:
# the verify directory lies under the link's target, as the group's mounts do,
# and the launch goes on (final review of the LNCH-22 fix: it was refused).
H67u="$TMP/hu67"$'\xff'; G67u="$TMP/g67u"
if mkdir "$H67u" 2>/dev/null; then
  mkdir -p "$G67u" && ln -s "$G67u" "$H67u/.ai-containers"
  HOME="$H67u" launch "$LAUNCHER" "$TMP/app"
  if [[ "$LAUNCH_RC" == 0 ]] && grep -qaF -- "$G67u/.verify-" "$CAPTURE"; then
    pass "T67 a HOME that is not UTF-8, with ~/.ai-containers linked to one that is, launches, its verify directory under the link's target"
  else
    fail "T67 non-UTF-8 HOME, linked group root (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  rm -rf "$H67u" "$G67u"
else
  printf 'SKIP: T67 a HOME that is not UTF-8 \xe2\x80\x94 this filesystem refuses the name\n'
fi

# Launched from a directory holding ':': the output directory and this
# launcher's own overlay.
L67="$TMP/l:67/.ai-containers"; mkdir -p "$TMP/l:67"; cp -R "$LAUNCHER" "$L67"; rm -rf "$L67/.agent-blocked"
launch "$L67" ..
if [[ "$LAUNCH_RC" == 0 ]] \
   && grep -qxF -- "type=bind,\"source=$L67/.agent-blocked\",\"destination=/workspace/.agent-blocked\"" "$CAPTURE" \
   && grep -qxF -- "$L67:/workspace/l:67/.ai-containers:ro" <<<"$(mounts)"; then
  pass "T67 launched from a directory holding ':', its output directory is mounted and the launcher overlaid"
else
  fail "T67 launch dir with ':' (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '); args: $(grep -F 'l:67' "$CAPTURE" | tr '\n' ' '))"
fi
rm -rf "$TMP/l:67"

# What no form carries is refused before docker runs, naming it: a name that is
# not UTF-8 (the CLI rewrites it to U+FFFD, and docker mounts, or makes, the
# directory of that name instead: unscanned), and one holding ':' that ends in
# whitespace (--mount refuses it). Skipped where the filesystem refuses a name.
U67="$TMP/u67"$'\xff'; W67="$TMP/w:67 "
if mkdir "$U67" 2>/dev/null; then
  launch "$LAUNCHER" "$U67"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "$U67"; then
    pass "T67 a primary whose name is not UTF-8 refuses the launch, naming it, before docker runs"
  else
    fail "T67 non-UTF-8 primary (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  mkdir -p "$U67/inner"
  EXTRA_MOUNTS="$U67/inner" launch "$LAUNCHER" "$TMP/app"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "$U67/inner"; then
    pass "T67 an EXTRA_MOUNTS entry that is not UTF-8 refuses the launch, naming it, before docker runs"
  else
    fail "T67 non-UTF-8 EXTRA_MOUNTS (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  rm -rf "$U67"
  # A link whose own name is not UTF-8: the source it leads to is fine, the
  # destination named after the link is not, and the refusal names that.
  ln -s "$TMP/app" "$TMP/ln67"$'\xff'
  EXTRA_MOUNTS="$TMP/ln67"$'\xff' launch "$LAUNCHER" "$TMP/app"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "at /workspace/ln67"$'\xff'; then
    pass "T67 an EXTRA_MOUNTS link whose name is not UTF-8 refuses the launch, naming the destination at fault"
  else
    fail "T67 non-UTF-8 destination (rc=$LAUNCH_RC; stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  rm -f "$TMP/ln67"$'\xff'
  # Not UTF-8 in the destination, with a source that ends in a space: the
  # destination is named, as the name at fault.
  mkdir -p "$TMP/tgt67 "; ln -s "$TMP/tgt67 " "$TMP/lm67"$'\xff'
  EXTRA_MOUNTS="$TMP/lm67"$'\xff' launch "$LAUNCHER" "$TMP/app"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -aqF "/workspace/lm67"$'\xff'" is not valid UTF-8" "$ERR"; then
    pass "T67 a destination that is not UTF-8 is named even when the source ends in a space"
  else
    fail "T67 non-UTF-8 destination, spaced source (rc=$LAUNCH_RC; stderr: $(grep -a -A1 'ERROR' "$ERR" | head -3 | tr '\n' ' '))"
  fi
  rm -f "$TMP/lm67"$'\xff'; rm -rf "$TMP/tgt67 "
  # SPECS_PATH not UTF-8: refused, as the primary is.
  mkdir "$U67"; SPECS_PATH="$U67" launch "$LAUNCHER" "$TMP/app"; rmdir "$U67"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "SPECS_PATH $U67"; then
    pass "T67 a SPECS_PATH that is not UTF-8 refuses the launch, naming it, before docker runs"
  else
    fail "T67 non-UTF-8 SPECS_PATH (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
else
  printf 'SKIP: T67 a name that is not UTF-8 — this filesystem refuses it\n'
fi
if mkdir "$W67" 2>/dev/null; then
  launch "$LAUNCHER" "$W67"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && err_names "$W67"; then
    pass "T67 a primary holding ':' and ending in a space refuses the launch, naming it, before docker runs"
  else
    fail "T67 ':' and trailing space (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -a 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  rm -rf "$W67"
else
  printf 'SKIP: T67 a name holding a colon — this filesystem refuses it\n'
fi

# ── T68: a read-only source that is itself a FIFO or a device ───────────────
# A file the launch binds read-only (a git config, a .git file) that a
# concurrent container swaps for a FIFO between the scan and the search before
# docker (LNCH-11) is refused by name, as one inside a bound directory is; so is
# a device. Driven directly, as T59 is (GAP-2 slice 4: dropping either test
# survived).
fns68="$TMP/fns68.sh"
for f68 in _term _q _timeout_prefix _ro_fifo_search; do
  awk -v f="$f68() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns68"
mkfifo "$TMP/fifo68"
for src68 in "$TMP/fifo68" /dev/null; do
  bash -c 'source "$1"; srcs=("$2"); rw=(); _ro_fifo_search srcs rw; echo continued' _ "$fns68" "$src68" >"$TMP/o68" 2>"$TMP/e68"; rc68=$?
  [[ "$rc68" != 0 && ! -s "$TMP/o68" ]] && grep -qF "$src68 is a FIFO or device inside what this launch binds read-only" "$TMP/e68" \
    && pass "T68 a read-only source that is itself a FIFO or device ($src68) refuses the launch" \
    || fail "T68 FIFO or device source $src68 (rc=$rc68; $(cat "$TMP/o68" "$TMP/e68" | tr '\n' ' '))"
done
rm -f "$fns68" "$TMP/fifo68" "$TMP/o68" "$TMP/e68"

# ── T69: each FIFO search gets at most 30 s, and a failed one refuses ───────
# One search may take what is left of the launch's 90 s, but never more than
# 30 s, so a planted launcher cannot hold one search for the whole budget; and a
# find that fails or runs out of time where no writable mount lies inside the
# source refuses the launch, as it does where one does (T56). Driven directly,
# as T59 is, with stand-ins for timeout and find (GAP-2 slice 4: the cap and
# the failure check, damaged, survived).
fns69="$TMP/fns69.sh"
for f69 in _term _q _timeout_prefix _ro_fifo_search; do
  awk -v f="$f69() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns69"
sh69="$TMP/sh69"; mkdir -p "$sh69" "$TMP/src69"
# timeout -k 2 <seconds> <command…>: records the seconds, runs the command.
printf '#!/bin/bash\nprintf "%%s\\n" "$3" >> %q\nshift 3\nexec "$@"\n' "$TMP/to69.log" > "$sh69/timeout"
cp "$sh69/timeout" "$sh69/gtimeout"; chmod +x "$sh69/timeout" "$sh69/gtimeout"
for case69 in fresh:30 spent:10; do
  : > "$TMP/to69.log"
  PATH="$sh69:$PATH" bash -c 'source "$1"; srcs=("$2"); rw=()
    [[ "$3" == spent ]] && _fs_deadline=$((SECONDS + 10))
    _ro_fifo_search srcs rw' _ "$fns69" "$TMP/src69" "${case69%%:*}" >/dev/null 2>&1
  got69="$(head -1 "$TMP/to69.log")"
  [[ -n "$got69" ]] && (( got69 <= ${case69#*:} && got69 >= ${case69#*:} - 2 )) \
    && pass "T69 a FIFO search with the budget ${case69%%:*} gets ${got69} s (at most 30, at most what is left)" \
    || fail "T69 FIFO search bound, budget ${case69%%:*} (want ${case69#*:} s, got '${got69}')"
done
# find fails (exit 124: out of time) where nothing inside the source is a
# writable mount to prune.
printf '#!/bin/bash\ncase " $* " in *" -quit "*) exit 124;; esac\nexec %q "$@"\n' "$(command -v find)" > "$sh69/find"; chmod +x "$sh69/find"
PATH="$sh69:$PATH" bash -c 'source "$1"; srcs=("$2"); rw=(); _ro_fifo_search srcs rw; echo continued' _ "$fns69" "$TMP/src69" >"$TMP/o69" 2>"$TMP/e69"; rc69=$?
[[ "$rc69" != 0 && ! -s "$TMP/o69" ]] && grep -qF "could not be searched for FIFOs within" "$TMP/e69" \
  && pass "T69 a FIFO search that runs out of time, with nothing to prune, refuses the launch" \
  || fail "T69 failed search with nothing to prune (rc=$rc69; $(cat "$TMP/o69" "$TMP/e69" | tr '\n' ' '))"
rm -rf "$fns69" "$sh69" "$TMP/src69" "$TMP/to69.log" "$TMP/o69" "$TMP/e69"

# ── T70: the hard-link check of what git reads by name, driven directly ─────
# Its file list alone (no hooks/ directory to search) still refuses a config
# with a second name, and the `find` it gives searches the widest writable mount
# that holds the file (not another, shorter one beside it). Its search gets at
# most 30 s, and at least 1 once the launch's budget is spent; one that runs
# out of time, or a temporary file that cannot be made, refuses the launch
# (GAP-2 slice 4: with both lists always given, swapping them survived, and so
# did each of the others).
fns70="$TMP/fns70.sh"
for f70 in _term _q _timeout_prefix _ro_fifo_search _fs_other_names _fs_reachable; do
  awk -v f="$f70() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns70"
M70="$TMP/m70"; mkdir -p "$M70/g" && : > "$M70/g/config" && ln "$M70/g/config" "$M70/x70"
sh70="$TMP/sh70"; mkdir -p "$sh70"
printf '#!/bin/bash\nprintf "%%s\\n" "$3" >> %q\nshift 3\nexec "$@"\n' "$TMP/to70.log" > "$sh70/timeout"
cp "$sh70/timeout" "$sh70/gtimeout"; chmod +x "$sh70/timeout" "$sh70/gtimeout"
# run70 <spent|fresh>: the check over $M70/g/config alone, $M70 writable and,
# beside it, $TMP/o6, whose name is shorter.
run70() {
  bash -c 'source "$1"; declare -A _fs_reach_cache=(); git_hook_names=(pre-commit)
    srcs=(); rw=("$2" "${2%/*}/o6"); declare -A lc=(["$3"]=file)
    [[ "$4" == spent ]] && _fs_deadline=$((SECONDS - 5))
    _ro_fifo_search srcs rw lc; echo continued' _ "$fns70" "$M70" "$M70/g/config" "$1" >"$TMP/o70" 2>"$TMP/e70"
}
for case70 in fresh:30 spent:1; do
  : > "$TMP/to70.log"; PATH="$sh70:$PATH" run70 "${case70%%:*}"; rc70=$?
  got70="$(head -1 "$TMP/to70.log")"
  if [[ "$rc70" != 0 && ! -s "$TMP/o70" ]] && grep -qF "$M70/g/config has more than one hard link" "$TMP/e70" \
     && grep -qF "find $M70 -xdev -samefile $M70/g/config" "$TMP/e70" && [[ "$got70" == "${case70#*:}" ]]; then
    pass "T70 the file list alone refuses a config with a second name; its search, budget ${case70%%:*}, gets ${got70} s"
  else
    fail "T70 hard-link check, budget ${case70%%:*} (rc=$rc70; bound '${got70}', want ${case70#*:}; $(cat "$TMP/o70" "$TMP/e70" | tr '\n' ' '))"
  fi
done
# Out of time: refused.
printf '#!/bin/bash\ncase " $* " in *" -links "*) exit 124;; esac\nexec %q "$@"\n' "$(command -v find)" > "$sh70/find"; chmod +x "$sh70/find"
PATH="$sh70:$PATH" run70 fresh; rc70=$?
[[ "$rc70" != 0 && ! -s "$TMP/o70" ]] && grep -qF "could not be checked for hard links within" "$TMP/e70" \
  && pass "T70 a hard-link search that runs out of time refuses the launch" \
  || fail "T70 hard-link search out of time (rc=$rc70; $(cat "$TMP/o70" "$TMP/e70" | tr '\n' ' '))"
rm -f "$sh70/find"
# No temporary file: refused.
TMPDIR="$TMP/none70" run70 fresh; rc70=$?
[[ "$rc70" != 0 && ! -s "$TMP/o70" ]] && grep -qF "cannot make a temporary file in" "$TMP/e70" \
  && pass "T70 a hard-link search with no temporary file refuses the launch" \
  || fail "T70 hard-link search, no temporary file (rc=$rc70; $(cat "$TMP/o70" "$TMP/e70" | tr '\n' ' '))"
rm -rf "$fns70" "$M70" "$sh70" "$TMP/to70.log" "$TMP/o70" "$TMP/e70"

# ── T72: small launcher helpers, on their own, under the launcher's options ──
# GAP-2 slice 5: a condition or a return of each, turned, survived every test.
fns72="$TMP/fns72.sh"
{ awk -v f="resolve_path() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox-common.sh"
  for f72 in _term _q _repo_volume_foreign _warn_group_link_out add_file_mount_if_exists validate_sandbox_ids split_env_list \
             _fs_ml_devof _bind_opts_ok _bind_read _ci_alias_fs; do
    awk -v f="$f72() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
  done; } > "$fns72"
t72() { bash -c 'set -euo pipefail; source "$1"; shift; eval "$1"' _ "$fns72" "$1" 2>&1; }
# A volume labelled for another repo: the line naming the prefix it collides
# under appears only where the names do collide.
o72="$(t72 'docker_volume_label() { printf app; }; ( _repo_volume_foreign ui ai-containers-repo-app ) || true; echo ==; ( _repo_volume_foreign ui somevol ) || true')"
[[ "${o72%%==*}" == *"REPO_VOLUME_PREFIX=ai-containers"* && "${o72#*==}" != *REPO_VOLUME_PREFIX* ]] \
  && pass "T72 a foreign repo volume names the prefix it collides under only when it does" \
  || fail "T72 _repo_volume_foreign (got: $o72)"
# The group's files: one that is a link out of the group warns; one inside does
# not; one outside the guard is not judged; none ends the launch under set -e.
mkdir -p "$TMP/g72/grp" "$TMP/g72/out" && printf x > "$TMP/g72/out/f" && printf x > "$TMP/g72/grp/in" \
  && ln -s ../out/f "$TMP/g72/grp/link" || { printf 'SCAFFOLD-FAILED: T72 group\n'; exit 1; }
o72="$(t72 "_group_guard_root='$TMP/g72/grp'; _bind_add() { :; }; a=()
  add_file_mount_if_exists a '$TMP/g72/grp/link' /d; echo L; add_file_mount_if_exists a '$TMP/g72/grp/in' /d; echo I
  add_file_mount_if_exists a '$TMP/g72/out/f' /d; echo O; _group_guard_root=''; add_file_mount_if_exists a '$TMP/g72/grp/link' /d; echo E")"
[[ "$o72" == *"WARNING: $TMP/g72/grp/link is a link out of the group"*$'\nL\nI\nO\nE' && "$(grep -c WARNING <<< "$o72")" == 1 ]] \
  && pass "T72 a group file that links out of the group warns, one inside or unguarded does not, and none ends the launch" \
  || fail "T72 group files (got: $o72)"
rm -rf "$TMP/g72"
# Ids: either one not a number, either one too large, and the refusal's status.
bad72=""
for c72 in "abc 1000" "1000 abc" "4294967295 1000" "1000 4294967295"; do
  o72="$(t72 "SANDBOX_UID=${c72% *} SANDBOX_GID=${c72#* }; ( validate_sandbox_ids ) || echo rc=\$?")" || true
  [[ "$o72" == *"must be numeric ids"*"rc=1" ]] || bad72+="[$c72: $o72] "
done
for c72 in "0 1000" "1000 0"; do
  o72="$(t72 "SANDBOX_UID=${c72% *} SANDBOX_GID=${c72#* }; ( validate_sandbox_ids ) || echo rc=\$?")" || true
  [[ "$o72" == *"must not run as root"*"rc=1" ]] || bad72+="[$c72: $o72] "
done
o72="$(t72 'SANDBOX_UID=1000 SANDBOX_GID=1000; validate_sandbox_ids; echo ok')"
[[ -z "$bad72" && "$o72" == ok ]] && pass "T72 an id not numeric, too large or root, either one, is refused with status 1; a good one passes" \
  || fail "T72 validate_sandbox_ids (${bad72}good: $o72)"
# split_env_list leaves the caller's globbing as it was.
o72="$(t72 'set +f; split_env_list "a b" >/dev/null; echo "[$-]"')"
[[ "$o72" != *f* ]] && pass "T72 split_env_list leaves globbing on where it was on" || fail "T72 split_env_list (got: $o72)"
# Cached, asked twice; an empty option list; a flag that is no bind.
o72="$(C72="$TMP/c72" t72 'declare -A _fs_ml_dev=(); : > "$C72"; _launcher_dev_ino() { printf x >> "$C72"; printf "5 6"; }; _fs_ml_devof /x; _fs_ml_devof /x; printf "%s:%s|" "${_fs_ml_dev[/x]}" "$(wc -c < "$C72" | tr -d " ")"
  _bind_opts_ok "" && printf "empty-ok|" || printf "empty-no|"; _bind_read -x foo && printf "x-ok" || printf "x-no"')"
[[ "$o72" == "5:1|empty-no|x-no" ]] \
  && pass "T72 a device asked twice is stat'ed once, an empty option list is no bind's, nor is another flag" \
  || fail "T72 small helpers (got: $o72)"
# Where a directory ignores case, whether the filesystem aliases names: Linux
# only; ext4, f2fs and tmpfs do not.
o72="$(t72 'stat() { printf "%s\n" "${*: -1}"; }; for t in ext2/ext3 tmpfs cifs; do OSTYPE=linux-gnu; _caf_made=""; _ci_alias_fs "$t" && printf "%s=1 " "$t" || printf "%s=0 " "$t"; done
  OSTYPE=darwin21; _ci_alias_fs cifs && printf "mac=1" || printf "mac=0"')"
[[ "$o72" == "ext2/ext3=0 tmpfs=0 cifs=1 mac=0" ]] \
  && pass "T72 a filesystem aliases names unless its kernel ignores case, on Linux only" \
  || fail "T72 _ci_alias_fs (got: $o72)"
rm -f "$fns72"

# ── T73: working copies, Colima, a pointer's path, a name quoted, launchers ──
# GAP-2 slice 5: a condition or a return of each, turned, survived every test.
fns73="$TMP/fns73.sh"
{ awk -v f="resolve_path() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox-common.sh"
  for f73 in _term _q _timeout_prefix seed_workcopy_volume _colima_profile _vm_dev_ino_load _bind_read repos_path_in_container launcher_dirs_in; do
    awk -v f="$f73() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
  done; } > "$fns73"
t73() { bash -c 'set -euo pipefail; source "$1"; shift; eval "$1"' _ "$fns73" "$1" 2>&1; }
# A working copy: made once, with the labels it has a value for, and copied;
# an existing one is left alone.
o73="$(T73L="$TMP/t73.log" t73 'image_name=img; L="$T73L"; : > "$L"; docker() { printf "%s\n" "$*" >> "$L"; case "$1 $2" in "volume inspect") return "${INSPECT:-1}" ;; esac; }
  seed_workcopy_volume base wc app /launch 2>/dev/null; echo == >> "$L"; seed_workcopy_volume base wc2 "" "" 2>/dev/null; echo == >> "$L"
  INSPECT=0 seed_workcopy_volume base wc3 app /l; echo done >> "$L"; cat "$L"')"
w1="${o73%%==*}"; r73="${o73#*==}"; w2="${r73%%==*}"; w3="${r73#*==}"
if [[ "$w1" == *"volume create --label ai-containers.workcopy=1 --label ai-containers.repo=app --label ai-containers.launch-dir=/launch wc"* \
      && "$w1" == *"run --rm --pull=never"*"base:/src:ro"*"wc:/dst"* \
      && "$w2" == *"volume create --label ai-containers.workcopy=1 wc2"* && "$w2" != *"ai-containers.repo="* \
      && "$w3" == *"volume inspect wc3"* && "$w3" != *"volume create"* && "$w3" == *done ]]; then
  pass "T73 a working copy is made once, labelled for what it has, and copied; an existing one is left alone"
else
  fail "T73 seed_workcopy_volume (got: $(tr '\n' ' ' <<< "$o73"))"
fi
# Colima: no colima, or no docker endpoint, is no profile, and nothing is
# loaded (a load with no profile recorded every source 0:0, refusing every
# launch); a record without numeric ids is dropped.
o73="$(t73 '( PATH=/nonexistent73; _colima_profile ) && printf "p0|" || printf "n0|"; declare -A m=(); ( PATH=/nonexistent73; _vm_dev_ino_load m /a ) && printf "l0|" || printf "nl0|"
  _timeout_prefix() { :; }; colima() { if [[ "$1" == ssh ]]; then cat >/dev/null; printf "12:34:/a\0x:5:/b\0007:y:/c\0"; fi; }
  docker() { return 1; }; DOCKER_HOST=""; _colima_profile && printf "p1|" || printf "n1|"
  DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"; COLIMA_HOME="$HOME/.colima"; printf "%s|" "$(_colima_profile)"
  declare -A m=(); _vm_dev_ino_load m /a /b /c; printf "%s=%s " "${!m[@]}" "${m[@]}"')"
[[ "$o73" == "n0|nl0|n1|default|/a=12 34 " ]] \
  && pass "T73 with no colima or no endpoint there is no profile and nothing loaded; records without numeric ids are dropped" \
  || fail "T73 Colima (got: $o73)"
# A pointer's host path, translated only through a host bind into /workspace.
o73="$(t73 'repos_path_in_container /h/sub -v /h:/elsewhere; printf "|"; repos_path_in_container /h/sub -v /h:/workspace/h')"
[[ "$o73" == "/workspace|/workspace/h/sub" ]] \
  && pass "T73 a host path is translated only through a bind into /workspace" || fail "T73 repos_path_in_container (got: $o73)"
# A launcher is a directory holding both files: a sandbox.sh alone, or a link
# to nothing beside sandbox-common.sh, is not one.
mkdir -p "$TMP/t73/a" "$TMP/t73/b" "$TMP/t73/c" && : > "$TMP/t73/a/sandbox.sh" && : > "$TMP/t73/a/sandbox-common.sh" \
  && : > "$TMP/t73/b/sandbox.sh" && ln -s nowhere "$TMP/t73/c/sandbox.sh" && : > "$TMP/t73/c/sandbox-common.sh" \
  || { printf 'SCAFFOLD-FAILED: T73 launchers\n'; exit 1; }
o73="$(t73 "o=(); u=(); launcher_dirs_in o u '$TMP/t73' \$(id -u) \$(id -g) \$(id -u); printf '%s ' \"\${o[@]#$TMP/t73/}\"")"
[[ "$o73" == "a " ]] && pass "T73 a launcher holds both its files; a sandbox.sh alone, or one that leads nowhere, is none" \
  || fail "T73 launcher_dirs_in (got: $o73)"
rm -rf "$TMP/t73" "$TMP/t73.log" "$fns73"

# ── T74: what one mount's scan finds is protected in every writable mount that
# exposes it (GIT-51). An outer EXTRA_MOUNTS directory whose scan does not reach
# the inner primary (node_modules is pruned) left another project's launcher
# there writable in the outer mount's view.
O74="$TMP/o74"; mk_launcher "$O74/node_modules/x"
EXTRA_MOUNTS="$O74" launch "$LAUNCHER" "$O74/node_modules/x"
m74="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$O74/node_modules/x/.ai-containers:/workspace/x/.ai-containers:ro" <<<"$m74" \
  && grep -qxF -- "$O74/node_modules/x/.ai-containers:/workspace/o74/node_modules/x/.ai-containers:ro" <<<"$m74" \
  && grep -qxF -- "$O74/node_modules/x:/workspace/o74/node_modules/x:rw" <<<"$m74" \
  && pass "T74 a launcher only the inner mount's scan finds is read-only, its parents pinned, in the outer mount's view too" \
  || fail "T74 nested mounts (rc=$LAUNCH_RC; got: $(grep -F /o74/ <<<"$m74" | tr '\n' ' '))"
# A directory there you cannot list, which could hide one, likewise.
mkdir -p "$O74/node_modules/x/hid" && chmod 0200 "$O74/node_modules/x/hid"
if [[ -r "$O74/node_modules/x/hid" ]]; then
  printf 'SKIP: T74 unlistable — chmod does not constrain root\n'
else
  EXTRA_MOUNTS="$O74" launch "$LAUNCHER" "$O74/node_modules/x"
  m74="$(mounts)"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$O74/node_modules/x/hid:/workspace/x/hid:ro" <<<"$m74" \
    && grep -qxF -- "$O74/node_modules/x/hid:/workspace/o74/node_modules/x/hid:ro" <<<"$m74" \
    && pass "T74 a directory you cannot list, only the inner mount's scan finds, is read-only in the outer mount's view too" \
    || fail "T74 unlistable (rc=$LAUNCH_RC; got: $(grep -F hid <<<"$m74" | tr '\n' ' '); stderr: $(grep -F hid "$ERR" | head -2 | tr '\n' ' '))"
fi
chmod 0755 "$O74/node_modules/x/hid"; rm -rf "$O74"
# A launcher the agent planted as the root of its own output directory gets no
# NOTE there: the host reads what is there as data and never launches from it,
# so "runs on the host at the next launch" was false, and the agent's to print
# (review of the GIT-51 fix).
mkdir -p "$LAUNCHER/.agent-blocked" && : > "$LAUNCHER/.agent-blocked/sandbox.sh" && : > "$LAUNCHER/.agent-blocked/sandbox-common.sh"
launch "$LAUNCHER" ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "holds a launcher and stays writable at /workspace/.agent-blocked" "$ERR" \
  && pass "T74 a launcher planted as the root of an output directory gets no NOTE there" \
  || fail "T74 output root (rc=$LAUNCH_RC; $(grep -F '.agent-blocked' "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$LAUNCHER/.agent-blocked/sandbox.sh" "$LAUNCHER/.agent-blocked/sandbox-common.sh"

# ── T75: a launcher in a read-only mount inside a writable mount (LNCH-24) ────
# A read-only mount was not scanned for launchers, since nothing can be written
# through it. But one inside a writable mount whose scan does not reach it (an
# EXTRA_MOUNTS directory, its node_modules pruned) is writable through that
# mount, and a launcher there stayed so. It is now overlaid in that mount's view
# only: the read-only mount's own view gets nothing, a :rw pin least of all.
O75="$TMP/o75"; mk_launcher "$O75/node_modules/x"
EXTRA_MOUNTS="$O75" DOCS_PATH="$O75/node_modules/x" launch "$LAUNCHER" ..
m75="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$O75/node_modules/x/.ai-containers:/workspace/o75/node_modules/x/.ai-containers:ro" <<<"$m75" \
  && grep -qxF -- "$O75/node_modules/x:/workspace/o75/node_modules/x:rw" <<<"$m75" \
  && pass "T75 a launcher in a read-only mount inside a writable one is read-only, its parents pinned, in the writable mount's view" \
  || fail "T75 read-only inside writable (rc=$LAUNCH_RC; got: $(grep -F /o75/ <<<"$m75" | tr '\n' ' '))"
! grep -qF ":/workspace/docs/" <<<"$m75" \
  && pass "T75 nothing is bound in the read-only mount's own view" \
  || fail "T75 binds in the read-only view ($(grep -F ':/workspace/docs/' <<<"$m75" | tr '\n' ' '))"
rm -rf "$O75"

# ── T76: this launcher itself, where a mount's scan cannot reach it ──────────
# The scan finds a launcher to six levels and not under a pruned name; this
# launcher is added by where it was reached from, so one deeper than that is
# overlaid all the same. And it is one launcher, found once however many routes
# find it: one walk of its links, one warning that it cannot be protected.
mk_engine() {
  mkdir -p "$1" || return 1
  for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$1/$f" || return 1; done
  cp -R "$ENGINE/tools.d" "$1/" || return 1
  [[ ! -d "$ENGINE/services.d" ]] || cp -R "$ENGINE/services.d" "$1/"
}
D76="$TMP/d76"; L76="$D76/a/b/c/d/e/f/.ai-containers"
mk_engine "$L76" && mkdir -p "$D76/w76" && : > "$D76/w76/t" && ln -s "$D76/w76/t" "$L76/lnk76" \
  || { printf 'SCAFFOLD-FAILED: T76 deep\n'; exit 1; }
launch "$L76" "$D76"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$L76:/workspace/d76/a/b/c/d/e/f/.ai-containers:ro" <<<"$(mounts)" \
  && pass "T76 this launcher, seven levels below a writable mount root, is read-only there" \
  || fail "T76 deep own launcher (rc=$LAUNCH_RC; got: $(mounts | grep -F /d76/ | tr '\n' ' '))"
[[ "$(grep -cF "WARNING: launcher link $L76/lnk76 leads somewhere the agent can change" "$ERR")" == 1 ]] \
  && pass "T76 a link in this launcher is warned about once" \
  || fail "T76 own link warned $(grep -cF "launcher link $L76/lnk76" "$ERR") times"
rm -rf "$D76"
# Launched from a launcher nested in another: the outer one is read-only, and
# nothing in it is pinned writable.
N76="$TMP/n76"; mk_launcher "$N76" && mk_engine "$N76/.ai-containers/sub/.ai-containers" \
  || { printf 'SCAFFOLD-FAILED: T76 nested\n'; exit 1; }
launch "$N76/.ai-containers/sub/.ai-containers" "$N76"
m76="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$N76/.ai-containers:/workspace/n76/.ai-containers:ro" <<<"$m76" \
  && [[ -z "$(grep -F ':/workspace/n76/.ai-containers' <<<"$m76" | grep -v ':ro$')" ]] \
  && pass "T76 launched from a launcher nested in another, the outer one is read-only, with no writable pin in it" \
  || fail "T76 nested own launcher (rc=$LAUNCH_RC; got: $(grep -F /n76/ <<<"$m76" | tr '\n' ' '))"
rm -rf "$N76"
# One docker cannot be handed: named once. Launched from a directory of its
# own, so the output directories, which sit in the launch directory, can be
# handed over, and nothing is left where later tests launch.
U76="$TMP/u76"; u76="x"$'\xff'
mk_engine "$U76/$u76/.ai-containers" 2>/dev/null || { rm -rf "$U76"; u76="x:"$'\r'"y"; mk_engine "$U76/$u76/.ai-containers"; } \
  || { printf 'SCAFFOLD-FAILED: T76 unrepresentable\n'; exit 1; }
: > "$CAPTURE"
mkdir -p "$TMP/run76" && ( cd "$TMP/run76" && bash "$U76/$u76/.ai-containers/sandbox.sh" restricted "$U76" ) >/dev/null 2>"$ERR" </dev/null; LAUNCH_RC=$?
[[ "$LAUNCH_RC" == 0 && "$(grep -c 'WARNING: cannot protect' "$ERR")" == 1 ]] \
  && pass "T76 this launcher under a name docker cannot be handed is warned about once" \
  || fail "T76 unrepresentable own launcher (rc=$LAUNCH_RC; warned $(grep -c 'WARNING: cannot protect' "$ERR") times)"
rm -rf "$U76" "$TMP/run76"
# One whose script is not named sandbox.sh (a renamed copy) is no launcher to
# the scan, which matches by name; as a mount root it is this launcher still.
R76="$TMP/r76/.ai-containers"; mk_engine "$R76" && mv "$R76/sandbox.sh" "$R76/launch76.sh" \
  || { printf 'SCAFFOLD-FAILED: T76 renamed\n'; exit 1; }
: > "$CAPTURE"
( cd "$R76" && bash ./launch76.sh restricted . ) >/dev/null 2>"$ERR" </dev/null; LAUNCH_RC=$?
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "NOTE: $R76 holds a launcher and stays writable at /workspace/.ai-containers;" "$ERR" \
  && pass "T76 this launcher as a mount root stays writable and says so, its script renamed too" \
  || fail "T76 renamed own launcher as mount root (rc=$LAUNCH_RC; $(grep -E 'NOTE|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/r76"
# A .git link inside a launcher another mount exposes lies under that
# launcher's read-only overlay: the agent cannot repoint it, so it is not named.
G76="$TMP/g76"; mk_launcher "$G76/p" && mkdir -p "$G76/p/.ai-containers/sub" "$G76/r" \
  && ln -s "$G76/r" "$G76/p/.ai-containers/sub/.git" || { printf 'SCAFFOLD-FAILED: T76 .git link\n'; exit 1; }
EXTRA_MOUNTS="$G76" launch "$LAUNCHER" "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$G76/p/.ai-containers:/workspace/g76/p/.ai-containers:ro" <<<"$(mounts)" \
  && ! grep -qF "$G76/p/.ai-containers/sub/.git is a symlink" "$ERR" \
  && pass "T76 a .git link under a launcher's read-only overlay is not named" \
  || fail "T76 .git link under an overlay (rc=$LAUNCH_RC; $(grep -F 'sub/.git' "$ERR" | head -1))"
rm -rf "$G76"

# ── T77: what the SANDBOX_LAUNCHER_MAX refusal names ────────────────────────
# A launcher two mounts expose is named once per place, not once per scan that
# found it: the outer mount's scan and the inner one's both find y/p.
X77="$TMP/x77"; mk_launcher "$X77/a" && mk_launcher "$X77/y/p" || { printf 'SCAFFOLD-FAILED: T77\n'; exit 1; }
SANDBOX_LAUNCHER_MAX=1 EXTRA_MOUNTS="$X77 $X77/y" launch "$LAUNCHER" "$TMP/app"
l77="$(awk '/Among them:/ {p = 1; next} p && /^         / {print} p && !/^         / {p = 0}' "$ERR" | sort)"
w77="$(printf '         %s\n' "$X77/a/.ai-containers" "$X77/y/p/.ai-containers" "$X77/y/p/.ai-containers" | sort)"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" && "$l77" == "$w77" ]] \
  && pass "T77 past SANDBOX_LAUNCHER_MAX the refusal names each place a launcher is exposed once" \
  || fail "T77 launcher cap listing (rc=$LAUNCH_RC; named: $(tr '\n' '|' <<<"$l77"))"
rm -rf "$X77"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
