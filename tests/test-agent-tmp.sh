#!/usr/bin/env bash
# Tests for the scratch places an agent's work survives a container restart in.
#
# Containers run with --rm, so only a group directory or a group's Docker
# volume outlives one. ~/.cache and ~/.local/state are mounted WHOLE from the
# group whatever sandbox.conf says: a nested mount per tool (qmd, Playwright,
# Claude Code) left every other tool's cache and state to vanish with the
# container. /var/tmp is the group's Docker volume, never a host folder (GNU
# tar's `..` placeholder fails on a macOS virtiofs bind), and each launch names
# its own folder in it, which the container's start-up makes after pruning old
# ones: agent-tmp.sh, run directly in the last section.
#
# A fake `docker` on PATH captures the `docker run` arguments, so nothing is
# launched. It hands `volume` calls to tests/lib-fake-docker-volume.sh, and its
# `ps` answers only the exact query the launch makes for the folders of the
# running containers, nothing for any other, so a wrong filter or format is a
# folder left out of the list.
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
  # ps: FAKE_RUNNING_SLOTS, one label value per line, for the launch's own
  # query only; FAKE_PS_FAIL=1 fails every ps.
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
[[ "\$1" == volume ]] && exec bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$TMP/volumes" "\$@"
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
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
# none from an earlier one.
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
# arg_after <flag> <value>: the captured docker run passes <flag>, then <value>.
arg_after() { awk -v f="$1" -v v="$2" 'p == f && $0 == v { ok = 1 } { p = $0 } END { exit !ok }' "$CAPTURE"; }

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

# ── /var/tmp: the group's Docker volume, one folder per container ───────────────
VOL=ai-containers-vartmp-default
PSQ='ps --filter label=ai-containers.tmpslot --format {{.Label "ai-containers.tmpslot"}}'
# ps_asked: how many times the launches of this setup made the launch's query.
ps_asked() { grep -cxF -- "$PSQ" "$TMP/ps-calls.txt" 2>/dev/null; }

setup
run_sandbox
check "a launch goes through (rc=$RC)" launched
check "/var/tmp is mounted from the group's volume" arg_after -v "$VOL:/var/tmp"
check "the volume was created with the group's label" \
  grep -qxF ai-containers.vartmp-group=default "$TMP/volumes/$VOL/labels"
check "no .var-tmp is made in the group" bash -c '[[ ! -e "$1" && ! -L "$1" ]]' _ "$GROUP_ROOT/.var-tmp"
check "no host folder is bound at /var/tmp" bash -c '! grep -q ":/var/tmp:rw$" "$1"' _ "$CAPTURE"
check "AI_AGENT_TMP_RUNNING is passed, empty, with no container running" arg_after -e "AI_AGENT_TMP_RUNNING="
check "no NOTE about an old .var-tmp when there is none" bash -c '! grep -q "is no longer mounted" "$1"' _ "$ERR"
slot="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "AI_AGENT_TMPDIR names a per-container folder" \
  bash -c '[[ "$1" =~ ^[0-9]{6}-[0-9]{6}-[0-9]+$ ]]' _ "$slot"
check "TMPDIR stays within 30 bytes" test $(( ${#slot} + 9 )) -le 30
check "the container carries its folder as a label" grep -qxF "ai-containers.tmpslot=$slot" "$CAPTURE"
check "TMPDIR itself is never passed to docker" bash -c '! grep -qE "^TMPDIR=" "$1"' _ "$CAPTURE"
check "docker ps is asked for the running containers' folders" test "$(ps_asked)" = 1
run_sandbox
slot2="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
check "each launch gets its own folder" test -n "$slot2" -a "$slot2" != "$slot"
check "docker ps is asked again on the next launch, with no old folder anywhere" test "$(ps_asked)" = 2
check "the next launch uses the same volume, and makes no other (rc=$RC)" \
  bash -c '[[ "$2" -eq 0 && "$(ls "$1")" == "$3" ]]' _ "$TMP/volumes" "$RC" "$VOL"
teardown

# Only label values of the folder-name form are passed: another tool's label, a
# path, a value with a space never reach the start-up.
setup
FAKE_RUNNING_SLOTS=$'200101-000000-1\n../x\nx y\n200101-000000-2' run_sandbox
check "the running containers' folder names are passed, and nothing else" \
  arg_after -e "AI_AGENT_TMP_RUNNING=200101-000000-1 200101-000000-2"
teardown

setup
FAKE_PS_FAIL=1 run_sandbox
check "a docker ps that fails passes ?, and the launch goes on (rc=$RC)" \
  bash -c '[[ "$1" -eq 0 ]] && grep -qxF "AI_AGENT_TMP_RUNNING=?" "$2"' _ "$RC" "$CAPTURE"
teardown

# container.env cannot choose the folder, nor which folders are in use: the
# launch's own -e is refused from it.
setup
printf 'AI_AGENT_TMPDIR=/etc\nAI_AGENT_TMP_RUNNING=x\n' > "$TMP/container.env"
SANDBOX_ENV_FILE="$TMP/container.env" run_sandbox
check "container.env AI_AGENT_TMPDIR refused with a WARNING naming it" \
  grep -q 'WARNING:.*AI_AGENT_TMPDIR' "$ERR"
check "container.env AI_AGENT_TMP_RUNNING refused with a WARNING naming it" \
  grep -q 'WARNING:.*AI_AGENT_TMP_RUNNING' "$ERR"
check "captured AI_AGENT_TMPDIR is still the launch's folder" \
  grep -qE '^AI_AGENT_TMPDIR=/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$' "$CAPTURE"
check "captured AI_AGENT_TMP_RUNNING is still the launch's" arg_after -e "AI_AGENT_TMP_RUNNING="
check "no AI_AGENT_TMPDIR=/etc anywhere" bash -c '! grep -q "=/etc" "$1"' _ "$CAPTURE"
teardown

# A volume of the name that is not this group's (made by a `docker run -v`
# before the group's first launch) refuses the launch: mounted, it would serve as
# the group's /var/tmp while group.sh never takes it for the group's.
setup
bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$TMP/volumes" volume create "$VOL" >/dev/null
run_sandbox
check "an unlabelled volume of the name refuses the launch (rc=$RC)" test "$RC" -ne 0
check "  before docker run" test ! -s "$CAPTURE"
check "  with its ERROR on stderr" \
  grep -qF "ERROR: the volume $VOL exists but is not a temp volume of group \"default\"" "$ERR"
teardown

# An old .var-tmp from the bind version is named at every launch, with how to
# copy it into the volume and how to remove it, and is never touched.
setup
mkdir -p "$GROUP_ROOT/.var-tmp/200101-000000-1"; : > "$GROUP_ROOT/.var-tmp/200101-000000-1/f"
run_sandbox
check "an old .var-tmp does not stop the launch (rc=$RC)" launched
check "  a NOTE names it" grep -qF "NOTE: $GROUP_ROOT/.var-tmp is no longer mounted: /var/tmp is now the Docker volume $VOL." "$ERR"
# Each step to a file, not a pipe: under pipefail `grep | grep -q` can report the
# opposite of what it saw.
sed 's/^ *//' "$ERR" > "$TMP/err-trimmed.txt"
grep -F 'docker run ' "$ERR" > "$TMP/err-run.txt"
grep -F -- "-v $GROUP_ROOT/.var-tmp:/src:ro" "$TMP/err-run.txt" > "$TMP/err-run-src.txt"
check "  and gives the line that removes it" grep -qxF -- "rm -rf $GROUP_ROOT/.var-tmp" "$TMP/err-trimmed.txt"
check "  and the docker run that copies it into the volume" grep -qF -- "-v $VOL:/dst" "$TMP/err-run-src.txt"
check "  the folder and its file are still there" test -f "$GROUP_ROOT/.var-tmp/200101-000000-1/f"
check "  and nothing of it is mounted" bash -c '! grep -qF -- "$2" "$1"' _ "$CAPTURE" "$GROUP_ROOT/.var-tmp"
run_sandbox
check "  the NOTE comes again at the next launch" grep -qF "NOTE: $GROUP_ROOT/.var-tmp is no longer mounted" "$ERR"
teardown

# One that is a link, leading nowhere, is named too.
setup
mkdir -p "$GROUP_ROOT"; ln -s "$TMP/nowhere" "$GROUP_ROOT/.var-tmp"
run_sandbox
check "an old .var-tmp that is a dangling link is named (rc=$RC)" \
  bash -c '[[ "$1" -eq 0 ]] && grep -qF "NOTE: $3/.var-tmp is no longer mounted" "$2"' _ "$RC" "$ERR" "$GROUP_ROOT"
check "  and left as it is" test -L "$GROUP_ROOT/.var-tmp"
teardown

# In a home whose path holds a ':', the copy command still binds the old folder
# at /src: `-v` splits at every ':', so it goes through --mount, as every bind
# of a launch holding one does (sandbox-common.sh: `_bind_mount_arg()`). The
# printed line, read as a shell reads it, is the argv docker would get.
setup
export HOME="$TMP/ho:me"; mkdir -p "$HOME"; HOME="$(p_realdir "$HOME")"; export HOME
GROUP_ROOT="$HOME/.ai-containers/default"
mkdir -p "$GROUP_ROOT/.var-tmp"
run_sandbox
grep -F 'docker run ' "$ERR" > "$TMP/err-run.txt"
check "a home holding ':' launches and names its old .var-tmp with a copy command (rc=$RC)" \
  bash -c '[[ "$1" -eq 0 && "$(grep -c . "$2")" == 1 ]]' _ "$RC" "$TMP/err-run.txt"
line="$(sed 's/^ *//' "$TMP/err-run.txt")"
( eval "set -- $line"; printf '%s\n' "$@" ) > "$TMP/copy-argv.txt"
pair_in() { awk -v f="$1" -v v="$2" 'p == f && $0 == v { ok = 1 } { p = $0 } END { exit !ok }' "$3"; }
check "  which binds the old folder read-only at /src through --mount" \
  pair_in --mount "type=bind,\"source=$GROUP_ROOT/.var-tmp\",\"destination=/src\",readonly" "$TMP/copy-argv.txt"
check "  and the group's volume at /dst" pair_in -v "$VOL:/dst" "$TMP/copy-argv.txt"
check "  and copies with cp -a /src/. /dst/" bash -c '[[ "$(tail -n 3 "$1" | tr "\n" " ")" == "-a /src/. /dst/ " ]]' _ "$TMP/copy-argv.txt"
teardown

# ── agent-tmp.sh, run directly ──
# Change time cannot be set back, so "old" items are made first, T is recorded,
# and after a sleep the "recent" ones; --now T+1+30 days then makes everything
# made before T+1 over 30 days old and everything after recent.
AT="$REPO_DIR/agent-tmp.sh"
at_setup() { D="$(mktemp -d)"; ERR="$D.err"; SLOT=260101-120000-99; }
at_run() {  # <running> [--now N]  -> RC, stderr in $ERR
  local run="$1"; shift
  bash "$AT" "$D" "$SLOT" "$run" "$@" 2> "$ERR"; RC=$?
}
at_old() { mkdir -p "$D/$1"; : > "$D/$1/f"; }
at_far() { printf '%s' "$(( $(date +%s) + 2592000 + 60 ))"; }
at_clean() { rm -rf "$D" "$ERR"; }
at_fakebin() {  # fake tool on PATH: <name> <body>
  mkdir -p "$D.bin"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$D.bin/$1"; chmod +x "$D.bin/$1"
}

at_setup
at_old 200101-000000-1; at_old 200101-000000-2
at_run "200101-000000-2" --now "$(at_far)"
check "an old folder is removed (rc=$RC)" test ! -e "$D/200101-000000-1"
check "  with its NOTE" grep -qF "NOTE: removed 1 temp folder(s) of stopped containers, untouched for 30 days, from $D (" "$ERR"
check "  and freed size, in K for a folder under 1M (0 for one du counts as none)" grep -qE '\(([0-9][0-9.]*K|0) freed\)\.$' "$ERR"
check "a folder named in <running> is kept, however old" test -d "$D/200101-000000-2"
check "the launch's folder is made, exit 0" test "$RC" -eq 0 -a -d "$D/$SLOT"
check "  mode 700" test "$(p_stat_mode "$D/$SLOT")" = 700
at_clean

at_setup; at_old 200101-000000-1
at_run "?" --now "$(at_far)"
check "<running> = ? removes nothing" test -d "$D/200101-000000-1"
check "  and still makes the folder (rc=$RC)" test "$RC" -eq 0 -a -d "$D/$SLOT"
at_clean

at_setup; at_old 200101-000000-1
at_run "../200101-000000-1 x y" --now "$(at_far)"
check "non-names in <running> are ignored: the old folder is removed" test ! -e "$D/200101-000000-1"
at_clean

at_setup; mkdir -p "$D/200101-000000-4/sub"; : > "$D/200101-000000-4/sub/f"
T=$(date +%s); sleep 2
printf x >> "$D/200101-000000-4/sub/f"
at_run "" --now $((T + 1 + 2592000))
check "a folder holding a recently changed file is kept" test -d "$D/200101-000000-4"
check "  and touched (ctime after T+1)" bash -c '[[ "$(find -P "$1" -maxdepth 0 -cnewer "$2")" ]]' _ "$D/200101-000000-4" "$D/200101-000000-4/sub/f"
at_clean

at_setup; at_old 200101-000000-1
T=$(date +%s); sleep 2
for i in $(seq 1 60); do mkdir "$D/200101-000000-9$i"; done
at_run "" --now $((T + 1 + 2592000))
check "recent folders are not listed as candidates: no cap note" bash -c '! grep -q "more old temp" "$1"' _ "$ERR"
check "  the old one is still removed" test ! -e "$D/200101-000000-1"
at_clean

at_setup
mkdir -p "$D/elsewhere"; : > "$D/elsewhere/keep"
mkdir -p "$D/200101-000000-1x" "$D/notes"; : > "$D/200101-000000-2"
ln -s elsewhere "$D/200101-000000-3"
at_run "" --now "$(at_far)"
check "names of another form, a file and a link are kept" bash -c \
  '[[ -d "$1/200101-000000-1x" && -d "$1/notes" && -f "$1/200101-000000-2" && -L "$1/200101-000000-3" ]]' _ "$D"
check "  the link's target is untouched" test -f "$D/elsewhere/keep"
at_clean

at_setup; at_old 200101-000000-1
at_fakebin id 'if [[ "$1" == -u ]]; then echo 4242; else exec /usr/bin/id "$@"; fi'
PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
check "only folders of the script's own uid are candidates" test -d "$D/200101-000000-1"
check "  nothing is said of the other uid's folder" test ! -s "$ERR"
rm -rf "$D.bin"; at_clean

at_setup
for i in $(seq 1 60); do mkdir "$D/200101-000000-$i"; done
at_run "" --now "$(at_far)"
check "60 old folders: one run removes 50" test "$(find "$D" -mindepth 1 -maxdepth 1 -name '2001*' | wc -l)" -eq 10
check "  and says 10 are left" grep -qF "NOTE: 10 more old temp folder(s) in $D are left for the next launch." "$ERR"
rm -rf "${D:?}/$SLOT"; SLOT=260101-120000-98
at_run "" --now "$(at_far)"
check "  a second run removes the other 10" test "$(find "$D" -mindepth 1 -maxdepth 1 -name '2001*' | wc -l)" -eq 0
check "  and prints no more-old line" bash -c '! grep -q "more old temp" "$1"' _ "$ERR"
at_clean

at_setup
for i in $(seq 1 600); do mkdir "$D/200101-000000-$i"; done
at_run "" --now "$(at_far)"
check "600 old folders: 50 removed" test "$(find "$D" -mindepth 1 -maxdepth 1 -name '2001*' | wc -l)" -eq 550
check "  the note says at least 450 more" grep -qF "NOTE: at least 450 more old temp folder(s) in $D are left" "$ERR"
at_clean

at_setup; at_old 200101-000000-1
at_fakebin rm 'for a in "$@"; do [[ "$a" == "'"$D"'/"* ]] && exit 1; done; exec /bin/rm "$@"'
PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
check "a folder rm cannot remove is named" grep -qF "NOTE: could not remove all of $D/200101-000000-1; what is left of it is kept, and checked again in 30 days." "$ERR"
check "  and kept" test -d "$D/200101-000000-1"
check "  and touched (ctime after the clock's cut-off)" bash -c '[[ "$(find -P "$1" -maxdepth 0 -cnewer "$2")" ]]' _ "$D/200101-000000-1" "$D/200101-000000-1/f"
rm -rf "$D.bin"; at_clean

# The freed size is du's, summed over what was removed, rounded up as du -h
# rounds. A folder holding 2000 KiB of random data (which no filesystem
# compresses) is 2.0M on ext4, which charges the folder a 4 KiB block (2004),
# and on tmpfs and btrfs, which charge it none (2000): du -h says 2.0M from
# 1946 to 2048 KiB, so up to 48 KiB charged beyond the data. 2048 KiB of data
# was 2052 on ext4, 2.1M.
at_setup; at_old 200101-000000-1
dd if=/dev/urandom of="$D/200101-000000-1/big" bs=1024 count=2000 2>/dev/null
at_run "" --now "$(at_far)"
check "a removed folder holding 2000 KiB: the NOTE says 2.0M freed" \
  grep -qxF "NOTE: removed 1 temp folder(s) of stopped containers, untouched for 30 days, from $D (2.0M freed)." "$ERR"
at_clean

# An rm -rf that fails part way has removed part of the folder: what is left is
# kept, and the NOTE says so rather than that the folder is kept as it was. The
# fake rm removes the file inside, then fails as on a file it cannot unlink.
at_setup; at_old 200101-000000-1; : > "$D/200101-000000-1/g"
at_fakebin rm 'for a in "$@"; do [[ "$a" == "'"$D"'/"* ]] && { /bin/rm -f -- "$a/f"; exit 1; }; done; exec /bin/rm "$@"'
PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
check "rm that removed part of a folder: what is left is named as kept" \
  grep -qxF "NOTE: could not remove all of $D/200101-000000-1; what is left of it is kept, and checked again in 30 days." "$ERR"
check "  the part rm removed is gone and the rest is kept" test ! -e "$D/200101-000000-1/f" -a -e "$D/200101-000000-1/g"
check "  and it is not counted as removed" bash -c '! grep -q "NOTE: removed" "$1"' _ "$ERR"
rm -rf "$D.bin"; at_clean

# The freed size reads as GNU du -h reads (what du -sh in the container says):
# rounded up, one decimal below 10, a whole number from 10, carried to the next
# unit at 1024, through T. Measured with du (GNU coreutils) 9.12 --apparent-size
# on files of each size. The fake du gives each removed folder the size.
for pair in 0:0 1:1.0K 4:4.0K 10:10K 1023:1023K 1024:1.0M 1025:1.1M 1537:1.6M 10239:10M 10241:11M \
            1047552:1023M 1048064:1.0G 1048577:1.1G 1073741824:1.0T 1073741825:1.1T; do
  at_setup; at_old 200101-000000-1
  at_fakebin du 'printf "%s\t%s\n" '"${pair%%:*}"' "${@: -1}"'
  PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
  check "a removed folder of ${pair%%:*} KiB: the NOTE says ${pair#*:} freed, as du -h does" \
    grep -qxF "NOTE: removed 1 temp folder(s) of stopped containers, untouched for 30 days, from $D (${pair#*:} freed)." "$ERR"
  rm -rf "$D.bin"; at_clean
done

# A link of the folder form that the listing names, as if a folder had been
# swapped for one after find read the directory, is never removed: only a
# directory that is no link is a candidate. The fake find adds it to the one
# call that lists the directory (the one with -mindepth); the clock puts the
# link's own change time past 30 days.
at_setup; mkdir -p "$D/elsewhere"; : > "$D/elsewhere/keep"; ln -s elsewhere "$D/200101-000000-7"
mkdir -p "$D.bin"
cat > "$D.bin/find" <<FAKEFIND
#!/usr/bin/env bash
"$(command -v find)" "\$@"; rc=\$?
for a in "\$@"; do [[ "\$a" == -mindepth ]] && printf '%s\0' "$D/200101-000000-7"; done
exit \$rc
FAKEFIND
chmod +x "$D.bin/find"
PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
check "a link the listing names is kept (rc=$RC)" test -L "$D/200101-000000-7"
check "  its target and what it holds are untouched" test -f "$D/elsewhere/keep"
check "  and nothing is said of it" bash -c '! grep -qE "NOTE: removed|could not remove" "$1"' _ "$ERR"
rm -rf "$D.bin"; at_clean

# A folder counts as removed only once it is gone: an rm that says it removed
# the folder while the folder is still there keeps it, named.
at_setup; at_old 200101-000000-1
at_fakebin rm 'for a in "$@"; do [[ "$a" == "'"$D"'/"* ]] && exit 0; done; exec /bin/rm "$@"'
PATH="$D.bin:$PATH" at_run "" --now "$(at_far)"
check "rm says done but the folder is there: named as not removed" \
  grep -qF "NOTE: could not remove all of $D/200101-000000-1; what is left of it is kept, and checked again in 30 days." "$ERR"
check "  and not counted as removed" bash -c '! grep -q "NOTE: removed" "$1"' _ "$ERR"
rm -rf "$D.bin"; at_clean

at_setup; at_old "$SLOT"
at_run "" --now "$(at_far)"
check "an existing slot: exit 1" test "$RC" -eq 1
check "  with a WARNING naming it" grep -qF "WARNING: cannot create $D/$SLOT" "$ERR"
check "  its content is untouched, and it is not pruned" test -f "$D/$SLOT/f"
at_clean

for bad in '../x' 'a b' ''; do
  at_setup; at_old 200101-000000-1; SLOT="$bad"
  at_run "" --now "$(at_far)"
  check "slot '$bad': exit 1 with a WARNING, nothing made" bash -c \
    '[[ "$1" -eq 1 ]] && grep -q "^WARNING:" "$2" && [[ "$(ls -A "$3")" == 200101-000000-1 && ! -e "$3/../x" ]]' _ "$RC" "$ERR" "$D"
  check "  and an old folder survives the refused call" test -d "$D/200101-000000-1"
  at_clean
done

at_setup
bash "$AT" "$D" "$SLOT" 2>/dev/null; rc=$?
check "fewer than 3 arguments: exit 2" test "$rc" -eq 2
at_clean

# --now is a decimal count of seconds, a leading zero included. Read as bash
# reads a number, 0123 was octal and 089 an error, and junk, an empty value or
# one past bash's arithmetic went on in silence, on the real clock or a wrapped
# one. Each, and anything else after the three arguments, is a usage error.
at_setup; at_old 200101-000000-1
at_run "" --now "0$(at_far)"
check "--now with a leading zero is read as decimal: the old folder is removed (rc=$RC)" \
  bash -c '[[ "$1" -eq 0 && ! -e "$2" ]]' _ "$RC" "$D/200101-000000-1"
at_clean
for bad in abc '' -5 1e9 99999999999999999999; do
  at_setup; at_old 200101-000000-1
  at_run "" --now "$bad"
  check "--now '$bad': exit 2, nothing pruned or made (rc=$RC)" bash -c \
    '[[ "$1" -eq 2 && -d "$2/200101-000000-1" && ! -e "$2/$3" ]]' _ "$RC" "$D" "$SLOT"
  at_clean
done
at_setup
at_run "" --now
check "--now with no value: exit 2 (rc=$RC)" test "$RC" -eq 2
at_run "" --later 5
check "an unknown option: exit 2 (rc=$RC)" test "$RC" -eq 2
check "  and no folder is made" test ! -e "$D/$SLOT"
at_clean

# The cut-off, 30 days before now, is handed to touch -t in UTC, and touch reads
# it in UTC. Written in local time, the hour a clock goes back names two times,
# and touch took either, moving the cut-off by an hour. Containers run in UTC;
# the host a test runs on need not.
at_setup
N="$(at_far)"
want="$(date -u -d "@$((N - 2592000))" +%Y%m%d%H%M.%S 2>/dev/null || date -u -r "$((N - 2592000))" +%Y%m%d%H%M.%S)"
at_fakebin touch 'printf "%s|%s\n" "${TZ-unset}" "$*" >> "'"$D"'.touch"; exec '"$(command -v touch)"' "$@"'
PATH="$D.bin:$PATH" TZ=XST5XDT,M3.2.0,M11.1.0 at_run "" --now "$N"
check "the cut-off goes to touch -t as UTC, touch reading it in UTC, under any caller's TZ" \
  grep -qE "^UTC0\|-t ${want//./\\.} " "$D.touch"
check "  and the folder is made (rc=$RC)" test "$RC" -eq 0 -a -d "$D/$SLOT"
rm -rf "$D.bin" "$D.touch"; at_clean

if [[ $fails -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
