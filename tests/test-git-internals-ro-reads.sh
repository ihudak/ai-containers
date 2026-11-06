#!/usr/bin/env bash
# tests/test-git-internals-ro-reads.sh — that a read-only bind does not make a
# FIFO read-only, that a file the agent can swap for a FIFO cannot hang a launch
# or read as unset, and how long a read may take (GIT-10, GIT-23).
#
# One of the tests/test-git-internals-ro-*.sh files, which share
# tests/lib-git-internals-ro.sh; the checks keep the G numbers sandbox.sh and
# the reviews cite. Hermetic: a fake docker capturing the run arguments, real
# git repositories. Integration case 465-git-internals-read-only checks that
# the container the agent gets actually refuses the writes, and still commits.
# shellcheck source=tests/lib-git-internals-ro.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-git-internals-ro.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-git-internals-ro.sh\n'; exit 1; }

gi_warm_up

# ── G65: a git directory's config or commondir as a FIFO cannot hang a launch ─
# Since a config is no longer required to take a directory for a git directory,
# one the agent made with a FIFO config, or commondir, hung every read of it:
# hooksPath, objectformat, core.worktree, the own-repository test (review of
# 1a30bb4, MEDIUM; a regression from 236d347).
for v in config commondir; do
  mkdir -p "$PROJ/ff65/.git/objects" "$PROJ/ff65/.git/refs"; printf 'ref: refs/heads/main\n' > "$PROJ/ff65/.git/HEAD"
  mkfifo "$PROJ/ff65/.git/$v"
  launch_timed 60
  # Refused, not just skipped: a FIFO mounted read-only can still be written, so
  # the agent would feed the host's git whatever config it reads there
  # (automated security review of 455fa85).
  [[ "$LAUNCH_RC" != 124 && "$LAUNCH_RC" != 0 ]] && grep -qF "ff65/.git/$v is not a regular file" "$ERR" \
    && pass "G65 a FIFO $v in a git directory refuses the launch, without hanging (${LAUNCH_S}s)" \
    || fail "G65 a FIFO $v (rc=$LAUNCH_RC; $(grep -F ff65 "$ERR" | head -1))"
  ( exec 3<>"$PROJ/ff65/.git/$v" ) 2>/dev/null; rm -rf "$PROJ/ff65"
done

# ── G66-G69: a read-only bind does not make a FIFO read-only ────────────────
# On Linux a FIFO under a read-only bind can still be opened for writing, so the
# agent could feed the host's git a config through any FIFO in what the launcher
# binds read-only: reproduced through an unlistable .git, a .git inside a planted
# launcher (review of 56c91c4, HIGH). Any FIFO or device in a read-only bind
# source refuses the launch, as does a git directory searchable but not listable.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$PROJ/u66" && "${G[@]}" -C "$PROJ/u66" init -q && rm -f "$PROJ/u66/.git/config" \
    && mkfifo "$PROJ/u66/.git/config" && chmod 0300 "$PROJ/u66/.git"
  launch_timed 60
  [[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "u66/.git" "$ERR" \
    && pass "G66 a searchable but unlistable .git refuses the launch" \
    || fail "G66 unlistable .git with a FIFO config (rc=$LAUNCH_RC; $(grep -F u66 "$ERR" | head -1))"
  chmod 0755 "$PROJ/u66/.git"; ( exec 3<>"$PROJ/u66/.git/config" ) 2>/dev/null; rm -rf "$PROJ/u66"
fi
# …and so is ANOTHER user's (GIT-22): binding one whole was tried and dropped,
# and a check that put ownership back into the condition passed G66, whose .git
# is the launching user's. Only root can make another user's directory, so this
# runs where the suite runs as root (the floor container): the tree is handed to
# one uid, the .git to another, and the launch runs as the first.
if [[ "$(id -u)" == 0 ]] && ! command -v setpriv >/dev/null 2>&1; then
  printf 'SKIP: G66b — needs setpriv to launch as another user\n'
elif [[ "$(id -u)" == 0 ]]; then
  o22="$(id -u):$(id -g)"
  mkdir -p "$PROJ/u22" && "${G[@]}" -C "$PROJ/u22" init -q || { printf 'SCAFFOLD-FAILED: G66b\n'; exit 1; }
  chown -R 4100:4100 "$TMP" && chown -R 4200:4200 "$PROJ/u22/.git" && chmod 0711 "$PROJ/u22/.git" \
    || { printf 'SCAFFOLD-FAILED: G66b chown\n'; exit 1; }
  # The directories above $TMP (run-all.sh's scratch root) are root's 0700: let the
  # launching uid through them for this launch, and put each back after.
  a22=(); d22="$(dirname "$TMP")"
  while [[ "$d22" != / ]]; do
    if [[ -n "$(find "$d22" -maxdepth 0 ! -perm -o+x 2>/dev/null)" ]]; then chmod o+x "$d22" && a22+=("$d22"); fi
    d22="$(dirname "$d22")"
  done
  rm -f "$CAPTURE" "$CAPTURE.manifest" "$CAPTURE.calls"
  p_timeout 60 setpriv --reuid=4100 --regid=4100 --clear-groups bash -c 'cd "$1" && exec bash ./sandbox.sh restricted ..' _ "$LAUNCHER" >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?
  for d22 in "${a22[@]}"; do chmod o-x "$d22"; done
  chown -R "$o22" "$TMP"; rm -rf "$PROJ/u22"
  # The git refusal's own line, not the launcher scan's, which shares its opening.
  [[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 && ! -e "$CAPTURE" ]] \
    && grep -qF "u22/.git can be searched but not listed by you, so what your host" "$ERR" \
    && pass "G66b another user's searchable but unlistable .git refuses the launch" \
    || fail "G66b another user's unlistable .git (rc=$LAUNCH_RC; $(head -3 "$ERR" | tr '\n' ' '))"
fi
mkdir -p "$PROJ/tools67/x"; : > "$PROJ/tools67/x/sandbox.sh"; : > "$PROJ/tools67/x/sandbox-common.sh"
"${G[@]}" init -q "$PROJ/tools67/x" && rm -f "$PROJ/tools67/x/.git/config" && mkfifo "$PROJ/tools67/x/.git/config"
launch_timed 60
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "tools67/x/.git/config" "$ERR" \
  && pass "G67 a FIFO inside a planted launcher's read-only overlay refuses the launch" \
  || fail "G67 FIFO under a launcher overlay (rc=$LAUNCH_RC; $(grep -F tools67 "$ERR" | head -1))"
( exec 3<>"$PROJ/tools67/x/.git/config" ) 2>/dev/null; rm -rf "$PROJ/tools67"
# G68: git takes a symlinked HEAD; one the agent made was never taken for a git
# directory, so its config stayed writable, silently (review of 56c91c4, HIGH).
mkdir -p "$PROJ/h68" && "${G[@]}" -C "$PROJ/h68" init -q && rm -f "$PROJ/h68/.git/HEAD" && ln -s refs/heads/main "$PROJ/h68/.git/HEAD"
launch ..
has_mount "$PROJ/h68/.git/config:/workspace/proj/h68/.git/config:ro" \
  && pass "G68 a git directory whose HEAD is a symlink is protected" \
  || fail "G68 symlinked-HEAD repository left writable"
rm -rf "$PROJ/h68"
# G69: a worktree or submodule named config is not taken for a FIFO config (the
# recheck matched names; review of 56c91c4).
M69="$PROJ/main69"; "${G[@]}" init -q "$M69" && "${G[@]}" -C "$M69" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M69" worktree add -q "$PROJ/config" || { printf 'SCAFFOLD-FAILED: G69\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && pass "G69 a worktree named config launches" \
  || fail "G69 a worktree named config refused (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$M69" "$PROJ/config"

# ── G84: a small git file swapped for a FIFO cannot hang the read ───────────
# .git files, commondir, gitdir and config are checked as regular files, then
# read; a concurrent container can swap one for a FIFO in between, which blocked
# the launch for ever. Each read is bounded (_rd, and _git_file_config) (GIT-10).
for f84 in _timeout_prefix _rd_prep _rd_left _rd_run _rd; do load_fn "$f84"; done
# The longer bound (G99) at 2 s too, to keep this quick: what is asserted is that
# the read is cut off at all.
_rd_secs=2 _rd_long_secs=2 _rd_budget_secs=30 _rd_init="" _rd_dir="" _rd_tp=() _rd_lim=0
TMPDIR="$TMP" _rd_prep
# The bound alone, here in the test's own shell: _rd_fail would signal it (G86).
_rd_fail() { :; }
if [[ -n "$(_timeout_prefix)" ]]; then
  mkfifo "$TMP/f84"; t84=$SECONDS
  _rd 4096 "$TMP/f84" >/dev/null 2>&1; d84=$((SECONDS - t84))
  ( exec 3<>"$TMP/f84" ) 2>/dev/null; rm -f "$TMP/f84"; rm -rf "$_rd_dir"
  (( d84 <= 6 )) && pass "G84 a read of a FIFO swapped in for a small git file is cut off (${d84}s)" \
    || fail "G84 a FIFO read took ${d84}s"
else
  printf 'SKIP: G84 — no timeout or gtimeout here\n'
fi

# ── G86: a read cut off by its bound refuses the launch, it is not "unset" ──
# G84's bound turned a hang into a key read as absent, which fails open for the
# checks that read a config (automated security review of 116129d, HIGH). It now
# signals the launcher (USR1), which refuses. The case runs as its own process,
# as the launcher does: the signal goes to $$.
fns86="$TMP/fns86.sh"
for f86 in _term _timeout_prefix _rd_prep _rd_left _rd_run _rd _rd_fail; do
  awk -v f="$f86() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns86"; mkdir -p "$TMP/rd86"
printf '_rd_secs=2 _rd_long_secs=2 _rd_budget_secs=30 _rd_init="" _rd_dir="" _rd_tp=() _rd_lim=0\nexec {_rd_errfd}>&2\ntrap "exit 3" USR1\n' >> "$fns86"
if [[ -n "$(_timeout_prefix)" ]]; then
  mkfifo "$TMP/f86"
  # 2>/dev/null, as every real caller has: the ERROR still reaches the launcher's
  # stderr (review of the batch 10 branch: it was silent).
  # As the launcher reads: errexit on, through a process substitution, which
  # inherits it — a refusal that failed there read as unset (re-review of the
  # GIT-23 fix, HIGH).
  TMPDIR="$TMP/rd86" bash -c 'set -euo pipefail; source "$1"; x=""; IFS= read -r -d "" x < <(_rd 4096 "$2" 2>/dev/null) || true; echo continued' \
    _ "$fns86" "$TMP/f86" >"$TMP/o86" 2>"$TMP/e86"; rc86=$?
  ( exec 3<>"$TMP/f86" ) 2>/dev/null; rm -f "$TMP/f86"
  [[ "$rc86" == 3 && ! -s "$TMP/o86" ]] && grep -qF 'could not be read' "$TMP/e86" \
    && pass "G86 a small git file whose read is cut off stops the launch" \
    || fail "G86 cut-off read (rc=$rc86; $(cat "$TMP/o86" "$TMP/e86" | tr '\n' ' '))"
fi
rm -rf "$fns86" "$TMP/o86" "$TMP/e86" "$TMP/rd86"

# ── G99: a file only slow to read gets longer, within a budget per launch ────
# Every read of a small file the agent can write is bounded (G84), and one cut
# off refused the launch, blamed on a FIFO. The bound is a time, so under load a
# regular config was cut off too: G38's 5,000 entries, during a falsify run with
# ten workers (GIT-23). A read now gets 10 s while the launch's slow reads (past
# 2 s) have taken less than 30 s in all, and 2 s once they have; the time
# includes its reader's, which the pipe holds it to; and the refusal says whether
# the file was swapped or only slow. First through a launch, with a git that is
# slow once for one config.
REAL_GIT99="$(command -v git)"
mkdir -p "$TMP/slowgit99"
cat > "$TMP/slowgit99/git" <<'SLOWGIT'
#!/usr/bin/env bash
if [[ "${1:-}" == config && "${2:-}" == --file && "${3:-}" == "$SLOW99_CFG" && ! -e "$SLOW99_MARK" ]]; then
  : > "$SLOW99_MARK"; sleep 3
fi
exec "$SLOW99_GIT" "$@"
SLOWGIT
chmod +x "$TMP/slowgit99/git"
"${G[@]}" init -q "$PROJ/slow99" && "${G[@]}" -C "$PROJ/slow99" config core.fsmonitor 'run-me-99'
SLOW99_CFG="$PROJ/slow99/.git/config" SLOW99_MARK="$TMP/slow99.mark" SLOW99_GIT="$REAL_GIT99" \
  PATH="$TMP/slowgit99:$PATH" launch ..
[[ -e "$TMP/slow99.mark" ]] || fail "G99 SCAFFOLD: the slow git was never asked for $PROJ/slow99/.git/config"
# Read whole, not cut off and taken for empty: the first protection names its key.
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'could not be read' "$ERR" \
  && grep -qF 'core.fsmonitor' <<<"$(grep -A1 -F 'NOTE: /workspace/proj/slow99/.git is protected for the first time, and its config already sets' "$ERR")" \
  && pass "G99 a config that took 3 s to read is read whole, and the launch goes ahead" \
  || fail "G99 slow config (rc=$LAUNCH_RC; stderr: $(grep -A1 -F 'could not be read' "$ERR" | tr '\n' ' '))"
rm -rf "$PROJ/slow99" "$TMP/slow99.mark" "$TMP/slowgit99"

# Then each outcome on its own, with bounds of 1 s and 6 s and a budget of 10 s,
# the functions run as the launcher runs them: errexit on, read through a
# process substitution. A refusal is the USR1 trap's exit 3.
fns99="$TMP/fns99.sh"
for f99 in _term _timeout_prefix _rd_prep _rd_left _rd_run _rd _rd_fail _git_file_config; do
  awk -v f="$f99() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns99"
printf '_rd_secs=1 _rd_long_secs=6 _rd_budget_secs=10 _rd_init="" _rd_dir="" _rd_tp=() _rd_lim=0\nexec {_rd_errfd}>&2\ntrap "exit 3" USR1\n' >> "$fns99"
# A git that counts its calls in $FG99_STATE and, by $FG99_MODE: prints a line,
# takes 2 s, prints another; takes 8 s; or swaps the file it was asked to read
# for a FIFO and hangs.
mkdir -p "$TMP/fg99"
cat > "$TMP/fg99/git" <<'FAKEGIT'
#!/usr/bin/env bash
n="$(cat "$FG99_STATE" 2>/dev/null)"; n="${n:-0}"; printf '%d\n' "$((n + 1))" > "$FG99_STATE"
case "$FG99_MODE" in
  slow2) printf 'a.b=1\n'; sleep 2; printf 'a.c=2\n' ;;
  slow8) sleep 8 ;;
  fifo) rm -f "$3"; mkfifo "$3"; sleep 8 ;;
esac
FAKEGIT
chmod +x "$TMP/fg99/git"
run99() {  # <mode> <spent before (printf format), or empty> [nodir|spentdir] -> rc99, out99, err99, calls99, rdd99
  rm -rf "$TMP/rdt99" "$TMP/st99"; mkdir -p "$TMP/rdt99"
  FG99_MODE="$1" FG99_STATE="$TMP/st99" PATH="$TMP/fg99:$PATH" TMPDIR="$TMP/rdt99" "$BASH" -c '
    source "$1"; _rd_prep
    case "$4" in
      nodir) rm -rf "$_rd_dir"; _rd_dir="" ;;
      spentdir) mkdir "$_rd_dir/spent" ;;
    esac
    [[ -z "$3" ]] || printf "$3" > "$_rd_dir/spent"
    set -euo pipefail; out=""
    IFS= read -r -d "" out < <(_git_file_config "$2" --list) || true
    printf "%s" "$out"' _ "$fns99" "$TMP/c99" "$2" "${3:-}" >"$TMP/o99" 2>"$TMP/e99"
  rc99=$?; out99="$(cat "$TMP/o99")"; err99="$(cat "$TMP/e99")"; calls99="$(cat "$TMP/st99" 2>/dev/null)"
  rdd99="$(ls -d "$TMP"/rdt99/ai-launcher-read.* 2>/dev/null | head -1)"
}
printf '[a]\n\tb = 1\n' > "$TMP/c99"
run99 slow2 ""
[[ "$rc99" == 0 && "$out99" == $'a.b=1\na.c=2' && -z "$err99" && "$calls99" == 1 ]] \
  && grep -qE '^[0-9]{4,}$' "$rdd99/spent" \
  && pass "G99 a read that takes 2 s, past the first bound, is read whole, once, and charged to the launch" \
  || fail "G99 slow read (rc=$rc99; calls=$calls99; out=$(tr '\n' '|' <<<"$out99"); err=$err99; spent=$(cat "$rdd99/spent" 2>/dev/null))"
run99 fifo ""; rm -f "$TMP/c99"; printf '[a]\n\tb = 1\n' > "$TMP/c99"
[[ "$rc99" == 3 && "$calls99" == 1 && -z "$out99" ]] \
  && grep -qF 'could not be read within 6 s, and is not a regular file now (swapped for a FIFO, or removed)' <<<"$err99" \
  && pass "G99 a file swapped for a FIFO while it was read is refused, and says so" \
  || fail "G99 FIFO swapped in (rc=$rc99; calls=$calls99; err=$err99)"
run99 slow8 ""
[[ "$rc99" == 3 && "$calls99" == 1 ]] && grep -qF 'could not be read within 6 s, though it is a regular file;' <<<"$err99" \
  && grep -qF 'The host may be busy: launch again.' <<<"$err99" \
  && pass "G99 a regular file past the longer bound is refused, and the refusal says the host may be busy" \
  || fail "G99 slow past the longer bound (rc=$rc99; calls=$calls99; err=$err99)"
run99 slow8 '7000\n'
grep -qF 'could not be read within 3 s, though it is a regular file;' <<<"$err99" \
  && pass "G99 the longer bound is what is left of the budget, when that is less" \
  || fail "G99 the bound from what is left (rc=$rc99; err=$err99)"
run99 slow2 '5000\n5000\n'
[[ "$rc99" == 3 ]] && grep -qF 'could not be read within 1 s, though it is a regular file, and this launch has no more time for slow reads' <<<"$err99" \
  && pass "G99 once the launch's slow reads have taken the budget, every line counted, a read gets the first bound" \
  || fail "G99 budget spent (rc=$rc99; calls=$calls99; err=$err99)"
run99 slow2 "" nodir
[[ "$rc99" == 3 ]] && grep -qF 'could not be read within 1 s' <<<"$err99" \
  && pass "G99 with nowhere to count slow reads, every read gets the first bound, as before" \
  || fail "G99 no count (rc=$rc99; err=$err99)"
run99 slow2 "" spentdir
[[ "$rc99" == 3 && ! -e "$rdd99/ok" ]] && grep -qF 'could not be read within 1 s' <<<"$err99" \
  && pass "G99 a count that is not a regular file gives the first bound, and stops the longer one for the launch" \
  || fail "G99 count not a file (rc=$rc99; ok: $(ls "$rdd99/ok" 2>&1); err=$err99)"
# _rd, which reads .git files, commondir and gitdir, gets the longer bound too.
mkdir -p "$TMP/fh99"; REAL_HEAD99="$(command -v head)"
printf '#!/usr/bin/env bash\nsleep 2\nexec %q "$@"\n' "$REAL_HEAD99" > "$TMP/fh99/head"
chmod +x "$TMP/fh99/head"; rm -rf "$TMP/rdt99"; mkdir -p "$TMP/rdt99"; printf 'gitdir: ../x\n' > "$TMP/f99"
PATH="$TMP/fh99:$PATH" TMPDIR="$TMP/rdt99" "$BASH" -c 'source "$1"; _rd_prep; set -euo pipefail; x=""
    IFS= read -r -d "" x < <(_rd 4096 "$2") || true; printf "%s" "$x"' \
  _ "$fns99" "$TMP/f99" >"$TMP/o99" 2>"$TMP/e99"; rc99=$?
[[ "$rc99" == 0 && "$(cat "$TMP/o99")" == 'gitdir: ../x' ]] \
  && pass "G99 a small git file that takes 2 s to read is read whole" \
  || fail "G99 _rd past the first bound (rc=$rc99; out=$(cat "$TMP/o99"); err=$(cat "$TMP/e99"))"
rm -rf "$fns99" "$TMP/fg99" "$TMP/fh99" "$TMP/rdt99" "$TMP/st99" "$TMP/c99" "$TMP/f99" "$TMP/o99" "$TMP/e99"

# ── G111: a file git takes a path from is read as git reads it, or refused ───
# git reads a commondir, a gitdir or a .git file whole, cuts its trailing CRs
# and LFs, and stops at the first NUL. The launcher read up to the NUL and cut
# after it (and `$(…)` dropped NULs), so `./\n\0\n` was its ./ placeholder,
# while git used .git/<LF>/, a directory the agent can make: its config ran on
# the host, and no launch and no rescan named it (bugs review GIT-30). A NUL, or
# more than the 4096 bytes read, refuses the launch, naming the file; so does a
# worktree's gitdir ending in a space or a tab, which git cuts and never writes.
mk111() {  # $1 = repository, $2 = commondir bytes (printf format): a hidden common dir beside
  "${G[@]}" init -q "$1" && printf "$2" > "$1/.git/commondir" && mkdir -p "$1/.git/"$'\n' \
    && "${G[@]}" init -q --bare "$TMP/t111" && cp -R "$TMP/t111/objects" "$TMP/t111/refs" "$TMP/t111/config" "$1/.git/"$'\n'/ \
    && printf '[core]\n\tfsmonitor = run-me-111\n' >> "$1/.git/"$'\n'/config && rm -rf "$TMP/t111"
}
odd111() {  # $1 = label, $2 = the file the refusal names
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $2 holds what git reads otherwise than this launcher" "$ERR" \
    && grep -qF 'git writes one path and a newline there. If you did not make it, remove it on the host.' "$ERR" \
    && pass "G111 $1 refuses the launch, naming it" \
    || fail "G111 $1 (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|111' "$ERR" | head -2 | tr '\n' ' '))"
}
mkdir -p "$TMP/n111" && mk111 "$TMP/n111/r" './\n\0\n' || { printf 'SCAFFOLD-FAILED: G111\n'; exit 1; }
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
odd111 "a commondir with a newline before a NUL" "$TMP/n111/r/.git/commondir"
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111" && mk111 "$TMP/n111/r" '.\0/' || { printf 'SCAFFOLD-FAILED: G111\n'; exit 1; }
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
odd111 "a commondir that is ./ only with its NUL dropped" "$TMP/n111/r/.git/commondir"
# A linked worktree's commondir longer than the 4096 bytes read: cut there, its
# x/../ steps led back to the worktree's own directory, while git follows them
# to the end.
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111" && "${G[@]}" init -q "$TMP/n111/m" && "${G[@]}" -C "$TMP/n111/m" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$TMP/n111/m" worktree add -q "$TMP/n111/w" && wt111="$(ls -d "$TMP/n111/m/.git/worktrees"/* | head -1)" \
  && mkdir -p "$wt111/x" && { printf 'x/../%.0s' $(seq 1 900); printf '../..\n'; } > "$wt111/commondir" \
  || { printf 'SCAFFOLD-FAILED: G111\n'; exit 1; }
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
odd111 "a linked worktree's commondir longer than 4096 bytes" "$wt111/commondir"
# Counted in bytes whatever the locale: 2049 two-byte characters are 4098 bytes.
loc111="$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -1)"
if [[ -n "$loc111" ]]; then
  { printf '\303\251%.0s' $(seq 1 2049); printf '\n'; } > "$wt111/commondir"
  LC_ALL="$loc111" EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
  odd111 "a commondir of 4098 bytes in 2049 characters, under $loc111" "$wt111/commondir"
else
  printf 'SKIP: G111 multibyte commondir: no UTF-8 locale here\n'
fi
# A .git file, and a linked worktree's commondir, the same.
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111/s" && "${G[@]}" init -q --bare "$TMP/n111/g" \
  && printf 'gitdir: ../g\n\0\n' > "$TMP/n111/s/.git" || { printf 'SCAFFOLD-FAILED: G111\n'; exit 1; }
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
odd111 "a .git file with a newline before a NUL" "$TMP/n111/s/.git"
# With no NUL, git and the launcher read a CR or LF inside alike, and git
# writes one for a path that holds it: read, not refused.
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111" && "${G[@]}" init -q "$TMP/n111/m" && "${G[@]}" -C "$TMP/n111/m" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$TMP/n111/m" worktree add -q "$TMP/n111/w" && wt111="$(ls -d "$TMP/n111/m/.git/worktrees"/* | head -1)" \
  && printf '../..\r..\n' > "$wt111/commondir" || { printf 'SCAFFOLD-FAILED: G111\n'; exit 1; }
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "$wt111/commondir names" "$ERR" && ! grep -qF 'holds what git reads otherwise' "$ERR" \
  && pass "G111 a commondir with a CR inside it is read as git reads it, and what it names is named" \
  || fail "G111 inner CR (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|commondir' "$ERR" | head -2 | tr '\n' ' '))"
# A worktree's gitdir git cuts of every trailing white space, not only CR and
# LF (review of the GIT-30 fix): a space or tab at its end is refused too.
printf '../..\n' > "$wt111/commondir"; printf '%s/.git \t\n' "$TMP/n111/w" > "$wt111/gitdir"
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
odd111 "a linked worktree's gitdir ending in a space and a tab" "$wt111/gitdir"
printf '%s/.git\n' "$TMP/n111/w" > "$wt111/gitdir"
# A trailing CR LF is cut, as git cuts it: not refused.
printf '../..\r\n' > "$wt111/commondir"
EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'holds what git reads otherwise' "$ERR" \
  && pass "G111 a commondir ending in CR LF is read as git reads it" \
  || fail "G111 trailing CR LF refused (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
# A .git file above a mount, which the walk up from it reads.
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111/sub" && printf 'gitdir: ../g\n\0\n' > "$TMP/n111/.git"
EXTRA_MOUNTS="$TMP/n111/sub" launch "$TMP/app"
odd111 "a .git file above a mount, with a newline before a NUL" "$TMP/n111/.git"
# The session that makes one: the rescan, quiet about what it reads, says the
# search was cut short, which asks for the launch that names the file; the
# exit status is the container's.
rm -rf "$TMP/n111"; mkdir -p "$TMP/n111"
FAKE_SESSION="cd '$TMP/n111' && git init -q r && printf './\n\0\n' > r/.git/commondir" FAKE_DOCKER_RC=4 \
  EXTRA_MOUNTS="$TMP/n111" launch "$TMP/app"
[[ "$LAUNCH_RC" == 4 ]] && grep -qF 'could not all be searched for git repositories the session' "$ERR" \
  && pass "G111 a session that makes one is told the search was cut short" \
  || fail "G111 rescan (rc=$LAUNCH_RC; stderr: $(tail -4 "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/n111"

# ── G112: a read-only bind does not make a hard-linked file read-only ───────
# A bind protects a path, not the file behind it: a hard link made before the
# repository's first protection writes the same file through another name, and
# link() into a read-only bind fails (EXDEV), so only one made before matters.
# The agent made one in a session (`ln .git/config notes.txt`); the next launch
# bound .git/config and named nothing, a later session added a core.fsmonitor
# through notes.txt, and the host's git ran it (bugs review GIT-31). A file the
# launch binds read-only in a git directory, or under its hooks/, with more
# than one link refuses the launch, naming it; so does one in a repository
# under a read-only overlay, which gets no binds of its own.
hl112() {  # $1 = label, $2 = the file the refusal names
  # The advice finds the other name; copying over it wrote through a link the
  # agent planted at <file>.new, into a file of yours (review of the GIT-31 fix).
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $2 has more than one hard link, and your host's git reads it" "$ERR" \
    && grep -qF -- "-xdev -samefile $2" "$ERR" && ! grep -qF 'cp -p' "$ERR" \
    && pass "G112 $1 refuses the launch, naming it" \
    || fail "G112 $1 (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
}
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && ln "$TMP/h112/r/.git/config" "$TMP/h112/r/notes.txt" \
  || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a config with a second name" "$TMP/h112/r/.git/config"
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && printf './\n' > "$TMP/h112/r/.git/commondir" \
  && ln "$TMP/h112/r/.git/commondir" "$TMP/h112/r/cd.txt" || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a commondir with a second name" "$TMP/h112/r/.git/commondir"
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && "${G[@]}" -C "$TMP/h112/r" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$TMP/h112/r" config --worktree user.name w112 && ln "$TMP/h112/r/.git/config.worktree" "$TMP/h112/r/cw.txt" \
  || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a config.worktree with a second name" "$TMP/h112/r/.git/config.worktree"
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && printf '#!/bin/sh\n' > "$TMP/h112/r/.git/hooks/post-checkout" \
  && chmod 755 "$TMP/h112/r/.git/hooks/post-checkout" && ln "$TMP/h112/r/.git/hooks/post-checkout" "$TMP/h112/r/h.txt" \
  || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a hook with a second name" "$TMP/h112/r/.git/hooks/post-checkout"
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/m" && "${G[@]}" -C "$TMP/h112/m" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$TMP/h112/m" worktree add -q "$TMP/h112/w" && ln "$TMP/h112/w/.git" "$TMP/h112/w/g.txt" \
  || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a linked worktree's .git file with a second name" "$TMP/h112/w/.git"
# A FIFO in hooks/ is still named as one, not as a file with a second name.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && mkfifo "$TMP/h112/r/.git/hooks/post-merge" \
  || { printf 'SCAFFOLD-FAILED: G112 FIFO\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch_timed 60 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $TMP/h112/r/.git/hooks/post-merge is a FIFO or device" "$ERR" \
  && pass "G112 a FIFO in hooks/ is still refused as a FIFO" \
  || fail "G112 FIFO in hooks/ (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
( exec 3<>"$TMP/h112/r/.git/hooks/post-merge" ) 2>/dev/null
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/m" && "${G[@]}" -C "$TMP/h112/m" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$TMP/h112/m" worktree add -q "$TMP/h112/w" && ln "$TMP/h112/w/.git" "$TMP/h112/w/g.txt" \
  || { printf 'SCAFFOLD-FAILED: G112\n'; exit 1; }
# Nor anything else in a launcher overlay: an engine checkout cloned from a
# local path shares its objects with the original by hard link.
mkdir -p "$TMP/h112/eng" && : > "$TMP/h112/eng/sandbox.sh" && : > "$TMP/h112/eng/sandbox-common.sh" \
  && "${G[@]}" init -q "$TMP/h112/eng" && : > "$TMP/h112/eng/.git/objects/pack/p" \
  && ln "$TMP/h112/eng/.git/objects/pack/p" "$TMP/h112/eng/.git/objects/pack/p2" \
  || { printf 'SCAFFOLD-FAILED: G112 launcher\n'; exit 1; }
rm -f "$TMP/h112/w/g.txt"
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'more than one hard link' "$ERR" && grep -qF 'READ-ONLY: /workspace/h112/eng' "$ERR" \
  && pass "G112 a launcher overlay whose git objects have two names launches" \
  || fail "G112 a hard link in a launcher overlay (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|h112/eng' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/h112/eng"
# Its other name removed, as the refusal says, it has one name again.
rm -f "$TMP/h112/w/g.txt"
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'more than one hard link' "$ERR" \
  && pass "G112 the same file, its other name removed, launches" \
  || fail "G112 after the copy (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
# A repository inside a planted launcher is overlaid read-only whole, and got no
# check of its own: two empty files hid its hard-linked config (review of the
# GIT-31 fix). What git reads there by name is checked as any repository's is.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112/r" && : > "$TMP/h112/r/sandbox.sh" && : > "$TMP/h112/r/sandbox-common.sh" \
  && "${G[@]}" init -q "$TMP/h112/r" && ln "$TMP/h112/r/.git/config" "$TMP/h112/notes.txt" \
  || { printf 'SCAFFOLD-FAILED: G112 launcher repository\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a repository's config with a second name, inside a planted launcher" "$TMP/h112/r/.git/config"
# Not by a pattern the agent can meet: a config under its objects/, reached
# through a link or a commondir, which no exemption may cover (re-review).
rm -f "$TMP/h112/notes.txt"; rm -f "$TMP/h112/r/.git/config"; : > "$TMP/h112/r/.git/objects/c"
ln -s objects/c "$TMP/h112/r/.git/config" && ln "$TMP/h112/r/.git/objects/c" "$TMP/h112/notes.txt" \
  || { printf 'SCAFFOLD-FAILED: G112 objects link\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a planted launcher's config linking into objects/, with a second name" "$TMP/h112/r/.git/config"
rm -f "$TMP/h112/r/.git/config" "$TMP/h112/notes.txt"; : > "$TMP/h112/r/.git/config"
mkdir -p "$TMP/h112/r/.git/objects/gd/objects" "$TMP/h112/r/.git/objects/gd/refs" && printf 'objects/gd\n' > "$TMP/h112/r/.git/commondir"
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $TMP/h112/r/.git/commondir sends git to objects/gd" "$ERR" \
  && pass "G112 a planted launcher's repository with a commondir other than ./ refuses the launch" \
  || fail "G112 commondir in a planted launcher (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
# Its links are judged as a protected repository's are: a config leading out of
# the overlay into the writable tree is named.
rm -f "$TMP/h112/r/.git/commondir" "$TMP/h112/r/.git/config"; : > "$TMP/h112/cfg.txt"; ln -s ../../cfg.txt "$TMP/h112/r/.git/config"
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
grep -qF 'WARNING: /workspace/h112/r/.git/config, under a read-only overlay, is a symlink' "$ERR" \
  && pass "G112 a planted launcher's config linking into the writable tree is named" \
  || fail "G112 overlay link (rc=$LAUNCH_RC; stderr: $(grep -A1 'under a read-only overlay' "$ERR" | head -2 | tr '\n' ' '))"
# A launcher file deduplicated with another project's copy launches: git does
# not read it.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" "$TMP/other112" && ln "$LAUNCHER/Dockerfile" "$TMP/other112/Dockerfile" \
  || { printf 'SCAFFOLD-FAILED: G112 launcher dedup\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'more than one hard link' "$ERR" \
  && pass "G112 a launcher file with a second name outside every mount launches" \
  || fail "G112 a deduplicated launcher file (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
rm -f "$TMP/other112/Dockerfile"
# A hook linking to a file whose two names both lie outside every mount (the
# Nix store links every file it holds) launches: the agent can reach neither.
"${G[@]}" init -q "$TMP/h112/r" && printf '#!/bin/sh\n' > "$TMP/other112/hook" && chmod 755 "$TMP/other112/hook" \
  && ln "$TMP/other112/hook" "$TMP/other112/.links-hook" && ln -s "$TMP/other112/hook" "$TMP/h112/r/.git/hooks/pre-commit" \
  && "${G[@]}" -C "$TMP/h112/r" config include.path "$TMP/other112/hook" \
  || { printf 'SCAFFOLD-FAILED: G112 outside links\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'more than one hard link' "$ERR" && ! grep -qF "it can write $TMP/other112" "$ERR" \
  && pass "G112 a hook and an include leading to a file with both names outside every mount launch, unnamed" \
  || fail "G112 outside links (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|other112' "$ERR" | head -2 | tr '\n' ' '))"
# But where its other name lies inside one — an earlier session with a wider
# mount made it — the agent can write it, wherever the link leads (automated
# security review of the GIT-31 fix).
ln "$TMP/other112/hook" "$TMP/h112/side.txt" || { printf 'SCAFFOLD-FAILED: G112 side name\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a hook linking outside every mount, to a file with a name inside one" "$TMP/h112/r/.git/hooks/pre-commit"
# Hidden in a directory the search cannot read (the agent owns it, and can
# chmod it back): a search that fails is not "no other name" (automated security
# review of the GIT-36/37 fix). Not as root, which can read any directory.
rm -f "$TMP/h112/side.txt"
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$TMP/h112/node_modules/x"; ln "$TMP/other112/hook" "$TMP/h112/node_modules/x/side"
  chmod 000 "$TMP/h112/node_modules/x"
  EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
  chmod 755 "$TMP/h112/node_modules/x"
  hl112 "a hook linking outside every mount, its other name in a directory that cannot be read" "$TMP/h112/r/.git/hooks/pre-commit"
  rm -rf "$TMP/h112/node_modules"
else
  printf 'SKIP: G112 an unreadable directory: root can read any directory\n'
fi
# A search per writable mount, whatever the number of hooks linking to such
# files, and once per launch: an agent's 28 hooks in each of 200 repositories
# made a search each, twice per launch (review of the GIT-36/37 fix). A
# stand-in find counts them, for one hook and for four.
mkdir -p "$TMP/fs112"
printf '#!/bin/bash\ncase " $* " in *" -samefile "*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/fs112/log" "$(command -v find)" > "$TMP/fs112/find"
chmod +x "$TMP/fs112/find"
: > "$TMP/fs112/log"; PATH="$TMP/fs112:$PATH" EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"; n1_112="$(wc -l < "$TMP/fs112/log")"
for e in pre-push post-merge post-checkout; do ln -s "$TMP/other112/hook" "$TMP/h112/r/.git/hooks/$e"; done
: > "$TMP/fs112/log"; PATH="$TMP/fs112:$PATH" EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"; n4_112="$(wc -l < "$TMP/fs112/log")"
[[ "$LAUNCH_RC" == 0 && "$n1_112" -ge 1 && "$n4_112" == "$n1_112" ]] \
  && pass "G112 four hooks linking to one outside file cost the searches one does ($n1_112, one per mount on its device)" \
  || fail "G112 searches per hook (rc=$LAUNCH_RC; $n1_112 for one hook, $n4_112 for four)"
rm -rf "$TMP/fs112" "$TMP/other112"
# hooks/: the names git runs, through a link too; not a .sample a deduplicating
# tool linked to another repository's.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" && "${G[@]}" init -q "$TMP/h112/r" && "${G[@]}" init -q "$TMP/h112/r2" \
  && rm -f "$TMP/h112/r2/.git/hooks/pre-commit.sample" && ln "$TMP/h112/r/.git/hooks/pre-commit.sample" "$TMP/h112/r2/.git/hooks/pre-commit.sample" \
  || { printf 'SCAFFOLD-FAILED: G112 samples\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'more than one hard link' "$ERR" \
  && pass "G112 a .sample hook with a second name launches: git never runs it" \
  || fail "G112 a linked .sample refused (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
ln -s pre-commit.sample "$TMP/h112/r/.git/hooks/pre-commit"
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a hook that links to a .sample with a second name" "$TMP/h112/r/.git/hooks/pre-commit"
# A link whose target has a second name leads somewhere the agent can change,
# even inside a read-only overlay: a hook into a planted launcher's objects/.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112/L" && : > "$TMP/h112/L/sandbox.sh" && : > "$TMP/h112/L/sandbox-common.sh" \
  && "${G[@]}" init -q "$TMP/h112/L" && printf '#!/bin/sh\n' > "$TMP/h112/L/.git/objects/run" && chmod 755 "$TMP/h112/L/.git/objects/run" \
  && ln "$TMP/h112/L/.git/objects/run" "$TMP/h112/run.txt" && "${G[@]}" init -q "$TMP/h112/p" \
  && ln -s ../../../L/.git/objects/run "$TMP/h112/p/.git/hooks/post-checkout" \
  || { printf 'SCAFFOLD-FAILED: G112 hook into a launcher\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
grep -qF "it can change $TMP/h112/L/.git/objects/run" <<<"$(grep -A1 -F 'NOTE: /workspace/h112/p/.git/hooks/post-checkout, a hook your host' "$ERR")" \
  && pass "G112 a hook leading to a file with a second name is named as one the agent can change" \
  || fail "G112 hook to a hard-linked file (rc=$LAUNCH_RC; stderr: $(grep -A1 'h112/p' "$ERR" | head -2 | tr '\n' ' '))"
# Linked between the overlay pass and docker, by a concurrent container: the
# search just before docker finds it. A stand-in find makes the link once the
# first check of the config has run.
rm -rf "$TMP/h112"; mkdir -p "$TMP/h112" "$TMP/fs112" && "${G[@]}" init -q "$TMP/h112/r" \
  || { printf 'SCAFFOLD-FAILED: G112 second search\n'; exit 1; }
cfg112="$TMP/h112/r/.git/config"
printf '#!/bin/bash\nif [[ " $* " == *" -links "* && " $* " == *" %s "* && ! -e %q ]]; then\n  : > %q; %q "$@"; rc=$?; ln %q %q; exit $rc\nfi\nexec %q "$@"\n' \
  "$cfg112" "$TMP/fs112/done" "$TMP/fs112/done" "$(command -v find)" "$cfg112" "$TMP/h112/side.txt" "$(command -v find)" > "$TMP/fs112/find"
chmod +x "$TMP/fs112/find"
PATH="$TMP/fs112:$PATH" EXTRA_MOUNTS="$TMP/h112" launch "$TMP/app"
hl112 "a config linked after the overlay pass, before docker" "$cfg112"
rm -rf "$TMP/fs112"
rm -rf "$TMP/h112"

# ── G116: every repository under a read-only overlay is judged ─────────────
# Only one with objects/ and a regular config was: a config that is a dangling
# link (filled in by a later session), a repository with no config (its hook
# links went unwalked), and a worktree-shaped one (a config.worktree including a
# writable file, a commondir that is a link) launched in silence, and the host's
# git ran what they led to (review of the GIT-31 fix; bugs review GIT-37). A link
# at a name git reads is named whatever it leads to, as a protected one's is.
mk116() {  # a planted launcher holding a repository
  rm -rf "$TMP/o116"; mkdir -p "$TMP/o116/L" "$TMP/o116/w" && : > "$TMP/o116/L/sandbox.sh" && : > "$TMP/o116/L/sandbox-common.sh" \
    && "${G[@]}" init -q "$TMP/o116/L" || { printf 'SCAFFOLD-FAILED: G116\n'; exit 1; }
}
mk116; rm -f "$TMP/o116/L/.git/config"; ln -s ../../w/c.cfg "$TMP/o116/L/.git/config"
EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
grep -qF "WARNING: /workspace/o116/L/.git/config, under a read-only overlay, is a symlink" "$ERR" \
  && pass "G116 a dangling config link under an overlay is named" \
  || fail "G116 dangling config link (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
mk116; rm -f "$TMP/o116/L/.git/config"; printf '#!/bin/sh\n' > "$TMP/o116/w/run.sh"; chmod 755 "$TMP/o116/w/run.sh"
ln -s ../../../w/run.sh "$TMP/o116/L/.git/hooks/post-commit"
EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
grep -qF 'NOTE: /workspace/o116/L/.git/hooks/post-commit, a hook your host' "$ERR" \
  && pass "G116 a hook link of a repository with no config, under an overlay, is named" \
  || fail "G116 no-config hook link (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
for decoy116 in "" decoy; do
mk116; "${G[@]}" -C "$TMP/o116/L" config extensions.worktreeConfig true && mkdir -p "$TMP/o116/L/.git/worktrees/x" \
  && printf 'ref: refs/heads/main\n' > "$TMP/o116/L/.git/worktrees/x/HEAD" && printf '../..\n' > "$TMP/o116/L/.git/worktrees/x/commondir" \
  && printf '[include]\n\tpath = ../../../../w/inc.cfg\n' > "$TMP/o116/L/.git/worktrees/x/config.worktree" \
  || { printf 'SCAFFOLD-FAILED: G116 worktree\n'; exit 1; }
# git ignores a worktree's own config: a decoy one there, saying the extension
# is off, does not stop its config.worktree being judged (review of the
# GIT-36/37 fix).
if [[ -n "$decoy116" ]]; then printf '[core]\n\trepositoryformatversion = 0\n' > "$TMP/o116/L/.git/worktrees/x/config"; fi
EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
grep -qF "/o116/L/.git/worktrees/x/config.worktree includes" "$ERR" \
  && pass "G116 a worktree-shaped git directory's config.worktree under an overlay has its includes judged${decoy116:+, a decoy config beside it}" \
  || fail "G116 worktree config.worktree include${decoy116:+ with a decoy config} (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
done
# A commondir that leads nowhere — beside the repository, or outside every
# mount, where nothing else warns: git's common config cannot be read, so it
# cannot say the extension is off. Neither does the decoy beside it, nor the
# usual common directory's config, which the agent can set to false too
# (security review of a1b7ce7; review of the GIT-40 fix).
"${G[@]}" -C "$TMP/o116/L" config extensions.worktreeConfig false
printf '[extensions]\n\tworktreeConfig = false\n' > "$TMP/o116/L/.git/worktrees/x/config"
for cd116 in ../../nowhere /nonexistent-git40/x; do
  printf '%s\n' "$cd116" > "$TMP/o116/L/.git/worktrees/x/commondir"
  EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
  grep -qF "/o116/L/.git/worktrees/x/config.worktree includes" "$ERR" \
    && pass "G116 a commondir that leads nowhere ($cd116), under an overlay, has its config.worktree judged" \
    || fail "G116 unresolved commondir $cd116 (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
done
rm -f "$TMP/o116/L/.git/worktrees/x/commondir"; ln -s ../../../../w/cd "$TMP/o116/L/.git/worktrees/x/commondir"; printf '../..\n' > "$TMP/o116/w/cd"
EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
grep -qF "WARNING: /workspace/o116/L/.git/worktrees/x/commondir, under a read-only overlay, is a symlink" "$ERR" \
  && pass "G116 a commondir link under an overlay is named" \
  || fail "G116 commondir link (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
# An empty commondir is no commondir to git, which reads the git directory's own
# config, as the protected path does: its core.hooksPath is judged (review of
# the GIT-40 fix).
mk116; mkdir -p "$TMP/o116/L/.git/worktrees/y" "$TMP/o116/w/hk" && printf 'ref: refs/heads/main\n' > "$TMP/o116/L/.git/worktrees/y/HEAD" \
  && : > "$TMP/o116/L/.git/worktrees/y/commondir" && printf '[core]\n\thooksPath = %s\n' "$TMP/o116/w/hk" > "$TMP/o116/L/.git/worktrees/y/config" \
  || { printf 'SCAFFOLD-FAILED: G116 empty commondir\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/o116/w/hk (core.hooksPath)" "$ERR" \
  && pass "G116 an empty commondir under an overlay is no commondir: its own config's core.hooksPath is judged" \
  || fail "G116 empty commondir (rc=$LAUNCH_RC; stderr: $(grep -F o116 "$ERR" | head -2 | tr '\n' ' '))"
# The hooks' link check that runs out of time refuses, as the FIFO search does.
mk116; "${G[@]}" init -q "$TMP/o116/r" || { printf 'SCAFFOLD-FAILED: G116 timeout\n'; exit 1; }
mkdir -p "$TMP/fs116"; printf '#!/bin/bash\ncase " $* " in *" -maxdepth 1 "*" -links "*) exit 124;; esac\nexec %q "$@"\n' "$(command -v find)" > "$TMP/fs116/find"
chmod +x "$TMP/fs116/find"
PATH="$TMP/fs116:$PATH" EXTRA_MOUNTS="$TMP/o116" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'could not be checked for hard links within' "$ERR" \
  && pass "G116 a hooks link check that runs out of time refuses the launch" \
  || fail "G116 hooks check timeout (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
rm -rf "$TMP/fs116" "$TMP/o116"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
