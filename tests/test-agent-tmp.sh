#!/usr/bin/env bash
# Tests for the scratch places an agent's work survives a container restart in.
#
# Containers run with --rm, so only a group directory outlives one. These cases
# cover ~/.cache and ~/.local/state, which are mounted WHOLE from the group
# whatever sandbox.conf says: a nested mount per tool (qmd, Playwright, Claude
# Code) left every other tool's cache and state to vanish with the container.
#
# A fake `docker` on PATH captures the `docker run` arguments, so nothing is
# launched. Its `ps` answers only the exact query the launch's pruning makes,
# and its `run` can age the launch's own /var/tmp folder, or kill the launcher,
# as a container would.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # <description> <command...>
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

REAL_HOME="$HOME"

setup() {  # $1 = sandbox.conf body
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  export HOME="$TMP/home"; mkdir -p "$HOME"
  # Physical HOME, so expectations built from it match the canonicalised -v
  # arguments sandbox.sh composes where the temp root is itself a link (macOS).
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP
  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 4\n%s\n' "${1:-qmd=OFF
playwright=OFF
claude-code=OFF}" > "$SANDBOX_CONF"

  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  # run: FAKE_AGE_SLOT=<host .var-tmp> puts a file in the launch's own folder and
  # gives both a 2020 mtime, as an archive unpacked onto $TMPDIR does;
  # FAKE_KILL_LAUNCHER=1 then sends the launcher a TERM, so it never returns
  # from docker run. ps: FAKE_RUNNING_SLOTS for the pruning's own query only,
  # nothing for any other, so a wrong filter or format is a folder not kept.
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
  if [[ -n "\${FAKE_AGE_SLOT:-}" ]]; then
    for a in "\$@"; do
      [[ "\$a" == AI_AGENT_TMPDIR=/var/tmp/* ]] || continue
      s="\$FAKE_AGE_SLOT/\${a#AI_AGENT_TMPDIR=/var/tmp/}"
      : > "\$s/f"; touch -t 202001010000 "\$s/f" "\$s"
    done
  fi
  [[ "\${FAKE_KILL_LAUNCHER:-}" == 1 ]] && kill -TERM "\$PPID"
  exit 0
fi
if [[ "\$1" == "ps" ]]; then
  printf '%s\n' "\$*" >> "$TMP/ps-calls.txt"
  [[ "\${FAKE_PS_FAIL:-}" == 1 ]] && exit 1
  if [[ \$# -eq 5 && "\$2" == --filter && "\$3" == label=ai-containers.tmpslot \\
        && "\$4" == --format && "\$5" == '{{.Label "ai-containers.tmpslot"}}' ]]; then
    [[ -n "\${FAKE_RUNNING_SLOTS:-}" ]] && printf '%s\n' "\$FAKE_RUNNING_SLOTS"
  fi
  exit 0
fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"

  GROUP_ROOT="$HOME/.ai-containers/default"
  mkdir -p "$TMP/app" "$TMP/launch"
}
teardown() {
  rm -rf "$TMP"
  unset SANDBOX_CONF AI_CONTAINER_GROUP AI_CONTAINER_GROUP_INIT SANDBOX_USER
  export HOME="$REAL_HOME"
}

# Launched from a temp dir: sandbox.sh writes its .agent-* output dirs into $PWD.
# The capture is emptied first, so a launch that stops before docker run leaves
# none from an earlier one. sandbox.sh is not the subshell's last command, so a
# launcher killed by a signal is reported in $ERR, not on the test's output.
run_sandbox() {
  ERR="$TMP/stderr.txt"; : > "$CAPTURE"
  ( cd "$TMP/launch" || exit; bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app"; exit $? ) \
    >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}
# launched: the last launch went through to docker run and exited 0.
launched() { [[ "$RC" -eq 0 && -s "$CAPTURE" ]]; }

# mounted <host-src> <container-dst> — is that exact rw bind flag in the captured args?
mounted() { grep -qx -- "$1:$2:rw" "$CAPTURE"; }

# ── ~/.cache and ~/.local/state, whole ──────────────────────────────────────────
setup
run_sandbox
check "sandbox.sh exits 0 (rc=$RC)" test "$RC" -eq 0
check "cache: ~/.cache mounted whole from the group, whatever sandbox.conf says" \
  mounted "$GROUP_ROOT/.cache" "/home/dev/.cache"
check "state: ~/.local/state mounted whole" \
  mounted "$GROUP_ROOT/.local/state" "/home/dev/.local/state"
check "both made in the group" \
  test -d "$GROUP_ROOT/.cache" -a -d "$GROUP_ROOT/.local/state"
teardown

# A nested mount under either would shadow part of the whole one.
setup 'qmd=ON
playwright=ON
claude-code=ON'
run_sandbox
check "no nested mount under ~/.cache or ~/.local/state" \
  bash -c '! grep -qE ":/home/dev/\.(cache|local/state)/" "$1"' _ "$CAPTURE"
check "whole ~/.cache and ~/.local/state still mounted" \
  bash -c 'grep -qxF -- "$2:/home/dev/.cache:rw" "$1" && grep -qxF -- "$3:/home/dev/.local/state:rw" "$1"' _ "$CAPTURE" "$GROUP_ROOT/.cache" "$GROUP_ROOT/.local/state"
check "claude-code still gets its own share dir" \
  mounted "$GROUP_ROOT/.local/share/claude" "/home/dev/.local/share/claude"
teardown

# ── group bootstrap: only the qmd index is carried, as before ───────────────────
setup
SRC="$HOME/.ai-containers/srcgrp"
mkdir -p "$SRC/.cache/qmd" "$SRC/.cache/pip" "$SRC/.local/state"
: > "$SRC/.cache/qmd/i"; : > "$SRC/.cache/pip/p"; : > "$SRC/.local/state/s"
NEW="$HOME/.ai-containers/newgrp"
AI_CONTAINER_GROUP=newgrp AI_CONTAINER_GROUP_INIT=from:srcgrp run_sandbox
check "slice: qmd still copied, other caches and state not" \
  bash -c '[[ -f "$1/.cache/qmd/i" && ! -e "$1/.cache/pip/p" && ! -e "$1/.local/state/s" ]]' _ "$NEW"
teardown

# ── /var/tmp: one folder per container ──────────────────────────────────────────
setup
run_sandbox
check "/var/tmp mounted from the group" mounted "$GROUP_ROOT/.var-tmp" "/var/tmp"
slot="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "AI_AGENT_TMPDIR names a per-container folder" \
  bash -c '[[ "$1" =~ ^[0-9]{6}-[0-9]{6}-[0-9]+$ ]]' _ "$slot"
check "TMPDIR stays within 30 bytes" test $(( ${#slot} + 9 )) -le 30
check "the container carries its folder as a label" grep -qxF "ai-containers.tmpslot=$slot" "$CAPTURE"
check "folder made on the host, 0700" \
  bash -c '[[ -d "$1" && "$2" == 700 ]]' _ "$GROUP_ROOT/.var-tmp/$slot" "$(p_stat_mode "$GROUP_ROOT/.var-tmp/$slot")"
check "TMPDIR itself is never passed to docker" bash -c '! grep -qE "^TMPDIR=" "$1"' _ "$CAPTURE"
run_sandbox
slot2="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "each launch gets its own folder" test -n "$slot2" -a "$slot2" != "$slot"
teardown

# container.env cannot choose the folder: the launch's own -e is refused from it.
setup
printf 'AI_AGENT_TMPDIR=/etc\n' > "$TMP/container.env"
SANDBOX_ENV_FILE="$TMP/container.env" run_sandbox
check "container.env AI_AGENT_TMPDIR refused with a WARNING naming it" \
  grep -q 'WARNING:.*AI_AGENT_TMPDIR' "$ERR"
check "captured AI_AGENT_TMPDIR is still the launch's folder" \
  grep -qE '^AI_AGENT_TMPDIR=/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$' "$CAPTURE"
check "no AI_AGENT_TMPDIR=/etc anywhere" bash -c '! grep -q "=/etc" "$1"' _ "$CAPTURE"
teardown

# ── pruning: folders of stopped containers untouched for 30 days ────────────────
# age_tree <dir>: set every mtime to 2020, deepest first so a parent is not
# bumped back by its children.
age_tree() { find "$1" -depth -exec touch -h -t 202001010000 {} +; }
# old_slot <name>: an aged per-container folder holding one file.
old_slot() {
  mkdir -p "$GROUP_ROOT/.var-tmp/$1"; : > "$GROUP_ROOT/.var-tmp/$1/f"
  age_tree "$GROUP_ROOT/.var-tmp/$1"
}
OLD=200101-000000-1
# touched <dir>: its own mtime is within 30 days, so the next launch does not
# list it.
touched() { local o; o="$(find -P "$1" -maxdepth 0 -mmin +43200)"; [[ -e "$1" && -z "$o" ]]; }
# sorted_find: a find on PATH that hands the launch's listing of .var-tmp back
# in name order, so which folders a capped listing, or the 50 a launch checks,
# reach does not depend on the filesystem's directory order. Every other find
# runs as it is.
sorted_find() {
  local real; real="$(type -P find)"
  cat > "$TMP/bin/find" <<FIND
#!/usr/bin/env bash
if [[ "\$*" == *"/.var-tmp -mindepth 1 -maxdepth 1 "* ]]; then
  "$real" "\$@" | LC_ALL=C sort -z
else
  exec "$real" "\$@"
fi
FIND
  chmod +x "$TMP/bin/find"
}

setup; old_slot "$OLD"; run_sandbox
check "an old folder of a stopped container is removed" test ! -e "$GROUP_ROOT/.var-tmp/$OLD"
check "the NOTE says 1 folder" grep -q 'NOTE: removed 1 temp folder(s) of stopped containers, untouched for 30 days, from .* freed)\.' "$ERR"
teardown

setup; old_slot "$OLD"; FAKE_RUNNING_SLOTS="$OLD" run_sandbox
check "a running container's folder is kept, however old" test -d "$GROUP_ROOT/.var-tmp/$OLD"
check "  and the launch went on (rc=$RC)" launched
teardown

# Append to an aged file in a subfolder, then age the folders back, so only a
# file deep inside is recent: a check of the folder's own mtime would miss it.
setup; old_slot "$OLD"; mkdir "$GROUP_ROOT/.var-tmp/$OLD/sub"; : > "$GROUP_ROOT/.var-tmp/$OLD/sub/h"
age_tree "$GROUP_ROOT/.var-tmp/$OLD"; printf x >> "$GROUP_ROOT/.var-tmp/$OLD/sub/h"
touch -h -t 202001010000 "$GROUP_ROOT/.var-tmp/$OLD/sub" "$GROUP_ROOT/.var-tmp/$OLD"
run_sandbox
check "a folder touched within 30 days is kept" test -d "$GROUP_ROOT/.var-tmp/$OLD"
check "  and the launch went on (rc=$RC)" launched
teardown

setup; mkdir -p "$GROUP_ROOT/.var-tmp/$(date +%y%m%d-%H%M%S)-2"; run_sandbox
check "a concurrent launch's new folder is kept" \
  bash -c 'l="$(ls "$1")"; grep -q -- "-2$" <<<"$l"' _ "$GROUP_ROOT/.var-tmp"
check "  and the launch went on (rc=$RC)" launched
teardown

setup; mkdir -p "$GROUP_ROOT/.var-tmp/keepme"; : > "$GROUP_ROOT/.var-tmp/x"
age_tree "$GROUP_ROOT/.var-tmp/keepme"; touch -h -t 202001010000 "$GROUP_ROOT/.var-tmp/x"
run_sandbox
check "only per-container folders are pruned" \
  test -d "$GROUP_ROOT/.var-tmp/keepme" -a -e "$GROUP_ROOT/.var-tmp/x"
check "  and the launch went on (rc=$RC)" launched
teardown

setup; old_slot "$OLD"; FAKE_PS_FAIL=1 run_sandbox
check "docker that cannot list containers removes nothing" \
  bash -c '[[ -d "$1" ]] && ! grep -q "removed" "$2"' _ "$GROUP_ROOT/.var-tmp/$OLD" "$ERR"
check "  and the launch went on (rc=$RC)" launched
teardown

setup; mkdir -p "$TMP/outside"; : > "$TMP/outside/f"
old_slot "$OLD"; ln -s "$TMP/outside/f" "$GROUP_ROOT/.var-tmp/$OLD/l"; age_tree "$GROUP_ROOT/.var-tmp/$OLD"
run_sandbox
check "a link in a pruned folder is not followed" \
  bash -c '[[ ! -e "$1" && -f "$2" ]]' _ "$GROUP_ROOT/.var-tmp/$OLD" "$TMP/outside/f"
check "  and the launch went on (rc=$RC)" launched
teardown

# As root (the suite's floor job) chmod 000 stops nothing, so this asserts only
# what holds either way: the launch goes on.
setup; old_slot "$OLD"; mkdir "$GROUP_ROOT/.var-tmp/$OLD/d"; : > "$GROUP_ROOT/.var-tmp/$OLD/d/g"
age_tree "$GROUP_ROOT/.var-tmp/$OLD"; chmod 000 "$GROUP_ROOT/.var-tmp/$OLD/d"
run_sandbox
check "an unreadable folder does not stop the launch (rc=$RC)" launched
if [[ "$(id -u)" -ne 0 ]]; then
  check "an unreadable folder is kept whole, with no removal NOTE" \
    bash -c '[[ -e "$1/f" ]] && ! grep -q "could not remove" "$2"' _ "$GROUP_ROOT/.var-tmp/$OLD" "$ERR"
  check "  and touched, so the next launches do not check it again" touched "$GROUP_ROOT/.var-tmp/$OLD"
fi
chmod 700 "$GROUP_ROOT/.var-tmp/$OLD/d" 2>/dev/null
teardown

# A du that fails (a sibling removed part of the folder meanwhile) must not end the launch.
setup; old_slot "$OLD"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/du"; chmod +x "$TMP/bin/du"
run_sandbox
check "a failing du does not stop the launch (rc=$RC)" test "$RC" -eq 0
check "the launch reached docker run" test -s "$CAPTURE"
teardown

# The cap: 50 per launch, the rest named and taken by the next launch.
setup; for i in $(seq 1 60); do old_slot "200101-000000-$i"; done
run_sandbox
check "60 old folders: one launch removes 50" \
  bash -c 'l="$(ls "$1")"; n="$(grep -c "^200101-" <<<"$l")"; [ "$n" = 10 ]' _ "$GROUP_ROOT/.var-tmp"
check "the cap NOTE says 10 more" grep -qxF "NOTE: 10 more old temp folder(s) in $GROUP_ROOT/.var-tmp are left for the next launch." "$ERR"
run_sandbox
check "the next launch removes the remaining 10" \
  bash -c 'l="$(ls "$1")"; ! grep -q "^200101-" <<<"$l"' _ "$GROUP_ROOT/.var-tmp"
check "no cap NOTE once nothing is left" bash -c '! grep -q "more old temp" "$1"' _ "$ERR"
teardown

# Only recent folders: docker is never asked.
setup; mkdir -p "$GROUP_ROOT/.var-tmp/$(date +%y%m%d-%H%M%S)-2"; run_sandbox
check "no old folder: docker ps is not called" test ! -s "$TMP/ps-calls.txt"
check "  and the launch went on (rc=$RC)" launched
teardown

# The listing is read to 500 folders at most, however many the agent makes old,
# and find is stopped there: 3000 of them, whose names are far more than a pipe
# holds, so a find that ran to its end was read to its end. The NOTE can then
# only say "at least".
setup; mkdir -p "$GROUP_ROOT/.var-tmp"
( cd "$GROUP_ROOT/.var-tmp" && mkdir 200101-000000-{1..3000} && touch -h -t 202001010000 200101-000000-{1..3000} )
real_find="$(type -P find)"
cat > "$TMP/bin/find" <<FIND
#!/usr/bin/env bash
if [[ "\$*" == *"/.var-tmp -mindepth 1 -maxdepth 1 "* ]]; then
  "$real_find" "\$@" && : > "$TMP/listing-read-whole"
else
  exec "$real_find" "\$@"
fi
FIND
chmod +x "$TMP/bin/find"
run_sandbox
check "3000 old folders: the launch went on (rc=$RC)" launched
check "  and removed 50" \
  bash -c 'l="$(ls "$1")"; n="$(grep -c "^200101-" <<<"$l")"; [ "$n" = 2950 ]' _ "$GROUP_ROOT/.var-tmp"
check "  the listing was not read to its end" test ! -e "$TMP/listing-read-whole"
check "  but cut at 500: the NOTE says at least 450 more" \
  grep -qxF "NOTE: at least 450 more old temp folder(s) in $GROUP_ROOT/.var-tmp are left for the next launch." "$ERR"
teardown

# Names that are not a per-container folder's are left out by find itself, so
# however many there are, old, they do not fill the 500 a launch reads. Both
# kinds sort before the real one: one that the first pattern refuses, and one
# that passes it with a character the regex refuses after the second dash.
setup; mkdir -p "$GROUP_ROOT/.var-tmp"
( cd "$GROUP_ROOT/.var-tmp" && mkdir 0-{1..510} 000000-000000-1x{1..510} \
  && touch -h -t 202001010000 0-{1..510} 000000-000000-1x{1..510} )
old_slot "$OLD"; sorted_find
run_sandbox
check "1020 old folders of other names, listed first: the per-container one is still removed" \
  test ! -e "$GROUP_ROOT/.var-tmp/$OLD"
check "  and the others are kept (rc=$RC)" \
  bash -c '[[ "$2" -eq 0 && -d "$1/0-510" && -d "$1/000000-000000-1x510" ]]' _ "$GROUP_ROOT/.var-tmp" "$RC"
teardown

# A folder kept for what it holds is touched, so it leaves the list for 30 days:
# 50 of them first in the listing used up the cap at every launch, and the old
# folder after them was never checked.
setup; mkdir -p "$GROUP_ROOT/.var-tmp"
( cd "$GROUP_ROOT/.var-tmp" && mkdir 200101-000000-{1..50} \
  && for k in 200101-000000-{1..50}; do : > "$k/new"; done \
  && touch -h -t 202001010000 200101-000000-{1..50} )
old_slot 200102-000000-1; sorted_find
run_sandbox
check "50 folders kept for a recent file: each is touched" \
  bash -c 'for k in "$1"/200101-000000-*; do o="$(find -P "$k" -maxdepth 0 -mmin +43200)"; [[ -z "$o" ]] || exit 1; done' _ "$GROUP_ROOT/.var-tmp"
run_sandbox
check "  so the next launch reaches the old folder after them and removes it" \
  test ! -e "$GROUP_ROOT/.var-tmp/200102-000000-1"
check "  and keeps the 50 (rc=$RC)" \
  bash -c 'l="$(ls "$1")"; n="$(grep -c "^200101-" <<<"$l")"; [[ "$n" = 50 && "$2" -eq 0 ]]' _ "$GROUP_ROOT/.var-tmp" "$RC"
check "  with no cap NOTE" bash -c '! grep -q "more old temp" "$1"' _ "$ERR"
teardown

# A folder that could not be removed is touched too. The fake rm refuses only
# what is in .var-tmp, and goes before teardown, which needs a real one.
setup; old_slot "$OLD"
cat > "$TMP/bin/rm" <<RM
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == */.var-tmp/* ]] && exit 1; done
exec "$(type -P rm)" "\$@"
RM
chmod +x "$TMP/bin/rm"
run_sandbox
command rm -f "$TMP/bin/rm"; hash -r
check "a folder rm cannot remove is named in a NOTE" grep -qF "NOTE: could not remove $GROUP_ROOT/.var-tmp/$OLD" "$ERR"
check "  and touched" touched "$GROUP_ROOT/.var-tmp/$OLD"
check "  and the launch went on (rc=$RC)" launched
teardown

# ── the launch's own folder: untouched counts from the container's exit ──────
# An archive unpacked onto $TMPDIR itself gives the folder and all it holds the
# archive's old dates; without a touch at exit the next launch removed it.
setup; FAKE_AGE_SLOT="$GROUP_ROOT/.var-tmp" run_sandbox
slot="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "a container that ages its own folder: the launch completes (rc=$RC)" launched
run_sandbox
check "  and the next launch keeps that folder" test -f "$GROUP_ROOT/.var-tmp/$slot/f"
teardown

# And at once when docker run returns, not only at exit: the check after the
# session (which runs find over the launch's writable mounts) can take 30 s, in
# which a concurrent launch would prune. This find notes, the first time it runs
# after docker run, whether the folder is old at that moment.
setup
real_find="$(type -P find)"
cat > "$TMP/bin/find" <<FIND
#!/usr/bin/env bash
if [[ -s "$CAPTURE" && ! -e "$TMP/probed" ]]; then
  s="\$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
  "$real_find" -P "$GROUP_ROOT/.var-tmp/\$s" -maxdepth 0 -mmin +43200 > "$TMP/probed" 2>&1
fi
exec "$real_find" "\$@"
FIND
chmod +x "$TMP/bin/find"
FAKE_AGE_SLOT="$GROUP_ROOT/.var-tmp" run_sandbox
check "the folder is touched as soon as docker run returns (rc=$RC)" \
  bash -c '[[ "$2" -eq 0 && -e "$1" && ! -s "$1" ]]' _ "$TMP/probed" "$RC"
teardown

# A launcher killed while the container runs touches it from its EXIT trap.
setup; FAKE_AGE_SLOT="$GROUP_ROOT/.var-tmp" FAKE_KILL_LAUNCHER=1 run_sandbox
slot="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "a launcher killed by TERM during docker run exits 143 (rc=$RC)" test "$RC" -eq 143
run_sandbox
check "  and the next launch keeps the folder its container aged" test -f "$GROUP_ROOT/.var-tmp/$slot/f"
teardown

if [[ $fails -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
