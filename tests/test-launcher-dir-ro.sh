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
# never scans blind past an unreadable directory (T24–T27).
#
# Hermetic: fake `docker` capturing the run args, no daemon. Integration cases
# 450-launcher-dir-read-only and 455-launcher-dir-nested-mount check that the
# container the agent gets actually enforces it.
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
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

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
  && pass "T22 a symlink on the launch path inside a writable mount is warned about" \
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
  out=(); unr=(); launcher_dirs_in out unr "$2" "$(id -u)"; printf "%s\0" "${out[@]}"' _ "$ENGINE/sandbox.sh" "$NL" | tr '\0\n' '|^')"
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
BAD="$TMP/bad"
if mk_launcher "$BAD/x"$'\xff' 2>/dev/null; then
  EXTRA_MOUNTS="$BAD" launch "$LAUNCHER" "$TMP/app"
  if ! grep -aqF -- "$BAD/x" <<<"$(raw_mounts)" && grep -aqF "WARNING: cannot protect $BAD/x" "$ERR" && [[ -s "$CAPTURE" ]]; then
    pass "T24 a name that is not valid UTF-8 is not mounted, is warned about, and the launch goes ahead"
  else
    fail "T24 invalid UTF-8 (mounts: $(raw_mounts | grep -aF "$BAD" | tr '\n' ' '); stderr: $(grep -aF "$BAD" "$ERR" | tr '\n' ' '))"
  fi
else
  pass "T24 (this filesystem refuses a name that is not valid UTF-8; nothing to check)"
fi

# ── T25: a directory the agent owns but has made unreadable cannot be looked
# inside, so a launcher in it would go unseen and stay writable at the next
# launch. It is treated as one: overlaid read-only, its parents pinned, warned.
LOCK="$TMP/lockp"; mk_launcher "$LOCK/inner/proj2"; chmod 0311 "$LOCK/inner"
EXTRA_MOUNTS="$LOCK" launch "$LAUNCHER" "$TMP/app"
chmod 0755 "$LOCK/inner"
[[ "$(mounts_under /workspace/lockp/)" == "$LOCK/inner:/workspace/lockp/inner:ro" ]] \
  && grep -qF "WARNING: $LOCK/inner is not readable" "$ERR" \
  && pass "T25 an unreadable directory of the agent's is mounted read-only, with a warning" \
  || fail "T25 unreadable directory (got: $(mounts_under /workspace/lockp/ | tr '\n' ' '); stderr: $(grep -F "$LOCK" "$ERR" | tr '\n' ' '))"

# ── T26: an unreadable writable mount ROOT cannot be overlaid (it is the mount)
# or looked inside, so the launch is refused, naming it — never started blind.
ROOTL="$TMP/rootl"; mk_launcher "$ROOTL/p"; chmod 0311 "$ROOTL"
EXTRA_MOUNTS="$ROOTL" launch "$LAUNCHER" "$TMP/app"
chmod 0755 "$ROOTL"
[[ ! -s "$CAPTURE" ]] && grep -qF "ERROR: $ROOTL is not readable" "$ERR" \
  && pass "T26 an unreadable writable mount root refuses the launch, naming it" \
  || fail "T26 unreadable mount root (docker run reached: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -E 'ERROR|WARNING' "$ERR" | tr '\n' ' '))"

# ── T27: the documented limits, so code and docs cannot drift: six levels
# down, and dependency/VCS trees are not searched.
LIM="$TMP/lim"; mk_launcher "$LIM/1/2/3/4/5"; mk_launcher "$LIM/a/b/c/d/e/f"; mk_launcher "$LIM/node_modules/p"
EXTRA_MOUNTS="$LIM" launch "$LAUNCHER" "$TMP/app"
[[ "$(mounts_under /workspace/lim/ | grep ':ro$')" == "$LIM/1/2/3/4/5/.ai-containers:/workspace/lim/1/2/3/4/5/.ai-containers:ro" ]] \
  && pass "T27 a launcher six levels down is found; seven levels, or under node_modules, is not" \
  || fail "T27 limits (got: $(mounts_under /workspace/lim/ | grep ':ro$' | tr '\n' ' '))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
