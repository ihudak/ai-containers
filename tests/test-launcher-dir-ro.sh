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
# names a writable mount inside a launcher (T40), and
# refuses a non-numeric identity (T30).
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
  pass "T24 (this filesystem refuses names that are not valid UTF-8; nothing to check)"
fi
# Valid UTF-8 must NOT be refused: a check that over-rejects leaves every
# non-ASCII project unprotected. Cyrillic, an emoji (4 bytes), U+10FFFF.
GOOD="$TMP/good"; gname=$'\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb5\xd0\xba\xd1\x82'; ename=$'e\xf0\x9f\x98\x80'; mname=$'m\xf4\x8f\xbf\xbf'
mk_launcher "$GOOD/$gname"; mk_launcher "$GOOD/$ename"; mk_launcher "$GOOD/$mname"
EXTRA_MOUNTS="$GOOD" launch "$LAUNCHER" "$TMP/app"
ok=1
for n in "$gname" "$ename" "$mname"; do
  grep -aqxF -- "-v $GOOD/$n/.ai-containers:/workspace/good/$n/.ai-containers:ro" <<<"$(raw_mounts)" || ok=0
done
[[ "$ok" -eq 1 ]] && ! grep -aq 'cannot protect' "$ERR" \
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
# launch. It is treated as one: overlaid read-only, its parents pinned, warned.
LOCK="$TMP/lockp"; mk_launcher "$LOCK/inner/proj2"; chmod 0311 "$LOCK/inner"
EXTRA_MOUNTS="$LOCK" launch "$LAUNCHER" "$TMP/app"
if [[ "$(id -u)" -eq 0 ]]; then
  # Root lists anything, so nothing is hidden: the launcher inside is found.
  grep -qxF -- "$LOCK/inner/proj2/.ai-containers:/workspace/lockp/inner/proj2/.ai-containers:ro" <<<"$(mounts_under /workspace/lockp/)" \
    && ! grep -q 'cannot be listed' "$ERR" \
    && pass "T25 (as root) a 0311 directory hides nothing: the launcher in it is found" \
    || fail "T25 as root (got: $(mounts_under /workspace/lockp/ | tr '\n' ' '))"
else
  [[ "$(mounts_under /workspace/lockp/)" == "$LOCK/inner:/workspace/lockp/inner:ro" ]] \
    && grep -qF "WARNING: $LOCK/inner cannot be listed by you" "$ERR" && grep -qF 'Restore: chmod u+rx' "$ERR" \
    && pass "T25 a directory of the agent's you cannot list is mounted read-only, with a warning" \
    || fail "T25 unlistable directory (got: $(mounts_under /workspace/lockp/ | tr '\n' ' '); stderr: $(grep -F "$LOCK" "$ERR" | tr '\n' ' '))"
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
  [[ "$(mounts_under /workspace/own/)" == "$OWN/srch:/workspace/own/srch:ro" ]] \
    && pass "T25b one the agent can search but you cannot list is mounted read-only; T25c one it cannot enter is left alone" \
    || fail "T25b/c agent-reach (got: $(mounts_under /workspace/own/ | tr '\n' ' '); stderr: $(grep -F "$OWN" "$ERR" | tr '\n' ' '))"
else
  pass "T25b/c (as root every directory can be listed; nothing to check)"
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
  [[ ! -s "$CAPTURE" ]] && grep -qF "ERROR: $ROOTL cannot be listed by you" "$ERR" \
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
  pass "T31 (needs root and setpriv to build another owner's directory; runs in the floor job)"
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
# of mount B is read-only through B and writable through A: still warned.
MA="$TMP/ma"; PD="$MA/a/b/c/d/e/f/g"; mk_launcher "$PD/peer"
ln -s "$PD/peer/.ai-containers/sandbox-common.sh" "$LAUNCHER/deep-peer.sh"
EXTRA_MOUNTS="$PD $MA" launch "$LAUNCHER" ..   # the protecting mount first
rm -f "$LAUNCHER/deep-peer.sh"
grep -qF "it can change $PD/peer/.ai-containers/sandbox-common.sh (at /workspace/ma/a/b/c/d/e/f/g/peer/.ai-containers/sandbox-common.sh)" \
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
  eval "$(awk "/^_link_walk\\(\\) \\{/,/^}\$/" "$1")"; eval "$(awk "/^_readlink_exact\\(\\) \\{/,/^}\$/" "$1")"
  _link_walk "$2"' _ "$ENGINE/sandbox.sh" "$NLT/d/l" | tr '\0\n' '|^')"
[[ "$got" == "$NLT/d/l|=$NLT/d/f^|" ]] \
  && pass "T37 a link target ending in a newline is followed exactly" \
  || fail "T37 trailing newline in a target (got: $got)"

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
  && grep -qF "NOTE: $MANY/p/.ai-containers holds more than 200 symlinks; only the first 200 were checked." "$ERR" \
  && pass "T38 at most 200 links per launcher are walked, and the cap is named" \
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
