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
  # A count that becomes a link while the read runs, with the longer bound.
  slow2plant) printf 'a.b=1\n'; ln -s "$FG99_PLANT" "$FG99_SPENT"; sleep 2; printf 'a.c=2\n' ;;
  fifo) rm -f "$3"; mkfifo "$3"; sleep 8 ;;
esac
FAKEGIT
chmod +x "$TMP/fg99/git"
run99() {  # <mode> <spent before (printf format), or empty> [nodir|spentdir|nook|spentlink|spentdangling|plantlink|plantdangling] -> rc99, out99, err99, calls99, rdd99
  rm -rf "$TMP/rdt99" "$TMP/st99"; mkdir -p "$TMP/rdt99"
  FG99_MODE="$1" FG99_STATE="$TMP/st99" PATH="$TMP/fg99:$PATH" TMPDIR="$TMP/rdt99" "$BASH" -c '
    source "$1"; _rd_prep
    case "$4" in
      nodir) rm -rf "$_rd_dir"; _rd_dir="" ;;
      spentdir) mkdir "$_rd_dir/spent" ;;
      nook) rm -f "$_rd_dir/ok" ;;
      spentlink) : > "$TMPDIR/other"; ln -s "$TMPDIR/other" "$_rd_dir/spent" ;;
      spentdangling) ln -s "$TMPDIR/other" "$_rd_dir/spent" ;;
      plantlink) : > "$TMPDIR/other"; export FG99_SPENT="$_rd_dir/spent" FG99_PLANT="$TMPDIR/other" ;;
      plantdangling) export FG99_SPENT="$_rd_dir/spent" FG99_PLANT="$TMPDIR/other" ;;
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
[[ "$rc99" == 0 && "$out99" == $'a.b=1\na.c=2' && -z "$err99" && "$calls99" == 1 && -f "$rdd99/ok" ]] \
  && grep -qE '^[0-9]{4,}$' "$rdd99/spent" \
  && pass "G99 a read that takes 2 s, past the first bound, is read whole, once, and charged to the launch, which keeps the longer bound" \
  || fail "G99 slow read (rc=$rc99; calls=$calls99; out=$(tr '\n' '|' <<<"$out99"); err=$err99; spent=$(cat "$rdd99/spent" 2>/dev/null); ok: $(ls "$rdd99/ok" 2>&1))"
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
run99 slow2 "" nook
[[ "$rc99" == 3 ]] && grep -qF 'could not be read within 1 s' <<<"$err99" \
  && pass "G99 once the count may not be kept (ok gone), every read gets the first bound" \
  || fail "G99 ok gone (rc=$rc99; err=$err99)"
# A count that is a link, to a file or to nothing, is never written through:
# the longer bound ends, and the file it names stays as it was, or unmade.
for m99 in spentlink spentdangling; do
  run99 slow2 "" "$m99"
  if [[ "$m99" == spentlink ]]; then o99="$([[ -f "$TMP/rdt99/other" && ! -s "$TMP/rdt99/other" ]] && echo kept)"
  else o99="$([[ ! -e "$TMP/rdt99/other" ]] && echo kept)"; fi
  [[ "$rc99" == 3 && "$o99" == kept && ! -e "$rdd99/ok" ]] \
    && pass "G99 a count that is a link ($m99) is not written through, and the longer bound ends" \
    || fail "G99 count a link, $m99 (rc=$rc99; other: $(ls -l "$TMP/rdt99/other" 2>&1); ok: $(ls "$rdd99/ok" 2>&1))"
done
# The same where it becomes a link during a read that takes 2 s under the longer
# bound: the write of the count is then reached, seconds past the first bound,
# and refused (a read cut off at the first bound reaches it by a millisecond).
for m99 in plantlink plantdangling; do
  run99 slow2plant "" "$m99"
  if [[ "$m99" == plantlink ]]; then o99="$([[ -f "$TMP/rdt99/other" && ! -s "$TMP/rdt99/other" ]] && echo kept)"
  else o99="$([[ ! -e "$TMP/rdt99/other" ]] && echo kept)"; fi
  [[ "$rc99" == 0 && "$out99" == $'a.b=1\na.c=2' && "$o99" == kept && ! -e "$rdd99/ok" ]] \
    && pass "G99 a count made a link during a slow read ($m99) is not written through, and the longer bound ends" \
    || fail "G99 count made a link, $m99 (rc=$rc99; out=$(tr '\n' '|' <<<"$out99"); other: $(ls -l "$TMP/rdt99/other" 2>&1); ok: $(ls "$rdd99/ok" 2>&1))"
done
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
grep -qF "it can write $TMP/other112/hook through another name of that file, in $TMP/h112" <<<"$(grep -A1 -F 'NOTE: /workspace/h112/r/.git/hooks/pre-commit, a hook your host' "$ERR")" \
  && pass "G112 such a hook is also named as a link the agent can redirect, with where the other name lies" \
  || fail "G112 hook NOTE (stderr: $(grep -A1 -F 'hooks/pre-commit, a hook' "$ERR" | head -2 | tr '\n' ' '))"
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
# made a search each, twice per launch (review of the GIT-36/37 fix). Each
# search lists a mount's files with a second name (GIT-39). A stand-in find
# counts them, for one hook and for four.
mkdir -p "$TMP/fs112"
printf '#!/bin/bash\ncase " $* " in *" -links "*" -exec "*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/fs112/log" "$(command -v find)" > "$TMP/fs112/find"
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

# ── G118: what GIT-38's fix costs and keeps on a case-sensitive filesystem ──
# No process per path: a case-sensitive filesystem needs no getcwd, and one per
# walk step let an agent's tree stretch a launch tenfold (review of the GIT-38
# fix). A pwd on PATH that logs each run is the witness.
mkdir -p "$TMP/pwd118" "$PROJ/w118" && printf '#!/bin/sh\nprintf x >> %q\nexec %q "$@"\n' "$TMP/pwd118.calls" "$(type -P pwd)" > "$TMP/pwd118/pwd" \
  && chmod +x "$TMP/pwd118/pwd" && ln -s ../w118/../w118/../README "$PROJ/.git/hooks/pre-push" \
  && "${G[@]}" -C "$PROJ" config include.path ../w118/../w118/inc.cfg || { printf 'SCAFFOLD-FAILED: G118 pwd\n'; exit 1; }
# Only where TMPDIR is case-sensitive: macOS's is not (third review).
if mkdir "$TMP/Probe118" && [[ -d "$TMP/PROBE118" ]]; then
  printf 'NOTE: TMPDIR ignores case here; G118'\''s pwd count does not apply\n'
else
  PATH="$TMP/pwd118:$PATH" launch ..
  [[ "$LAUNCH_RC" == 0 && ! -s "$TMP/pwd118.calls" ]] \
    && pass "G118 a launch on a case-sensitive filesystem runs no pwd process" \
    || fail "G118 pwd ran $(wc -c < "$TMP/pwd118.calls" 2>/dev/null || echo 0) times (rc=$LAUNCH_RC)"
fi
rmdir "$TMP/Probe118" 2>/dev/null
"${G[@]}" -C "$PROJ" config --unset include.path; rm -rf "$TMP/pwd118" "$TMP/pwd118.calls" "$PROJ/w118" "$PROJ/.git/hooks/pre-push"
# A gitdir: through a link and then .. out of where it leads: still named as a
# link the agent can repoint; the path as written, not normalised, is searched
# for one (review of the GIT-38 fix).
mkdir -p "$PROJ/src118" "$PROJ/node_modules/a118/b" && "${G[@]}" init -q --bare "$PROJ/node_modules/a118/real" \
  && "${G[@]}" config --file "$PROJ/node_modules/a118/real/config" core.bare false \
  && ln -s node_modules/a118/b "$PROJ/lnk118" && printf 'gitdir: ../lnk118/../real\n' > "$PROJ/src118/.git" \
  || { printf 'SCAFFOLD-FAILED: G118 link\n'; exit 1; }
launch ..
grep -qF 'a118/real through a link inside the mount' "$ERR" \
  && pass "G118 a gitdir: through a link and .. is named as a link the agent can repoint" \
  || fail "G118 link then .. (stderr: $(grep -F a118 "$ERR" | head -1))"
rm -rf "$PROJ/src118" "$PROJ/node_modules/a118" "$PROJ/lnk118"
# A gitdir: written with a leading //: bash's cd -P keeps it, and no mount's
# prefix matched, so its git directory went unprotected (second review of the
# GIT-38 fix).
mkdir -p "$PROJ/src118b" "$PROJ/node_modules/x118b" && "${G[@]}" init -q --bare "$PROJ/node_modules/x118b/g" \
  && "${G[@]}" config --file "$PROJ/node_modules/x118b/g/config" core.bare false \
  && printf 'gitdir: /%s\n' "$PROJ/node_modules/x118b/g" > "$PROJ/src118b/.git" || { printf 'SCAFFOLD-FAILED: G118 //\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/x118b/g/config:/workspace/proj/node_modules/x118b/g/config:ro" \
  && pass "G118 a gitdir: written with a leading // is protected" \
  || fail "G118 // gitdir (mounts: $(grep -c x118b <<<"$(mounts)"); stderr: $(grep -F x118b "$ERR" | head -1))"
rm -rf "$PROJ/src118b" "$PROJ/node_modules/x118b"
# A core.hooksPath into the writable project that does not exist yet: the agent
# can make it, and it is named, as one that exists is (second review of the
# GIT-38 fix).
"${G[@]}" -C "$PROJ" config core.hooksPath .later118/hooks || { printf 'SCAFFOLD-FAILED: G118 hooksPath\n'; exit 1; }
launch ..
grep -qF "runs its git hooks from /workspace/proj/.later118/hooks (core.hooksPath)" "$ERR" \
  && pass "G118 a core.hooksPath into the project that does not exist yet is named" \
  || fail "G118 missing hooksPath (stderr: $(grep -F hooksPath "$ERR" | head -1))"
"${G[@]}" -C "$PROJ" config --unset core.hooksPath
# A .Git directory on a case-sensitive filesystem is not git's: left alone, as
# before the scan matched git's names in any case (third review of the GIT-38
# fix). Where TMPDIR ignores case it is git's, and the casefold test has it.
if ! { mkdir "$TMP/Probe118b" && [[ -d "$TMP/PROBE118B" ]]; }; then
  mkdir -p "$PROJ/c118/.Git/objects" "$PROJ/c118/.Git/refs" || { printf 'SCAFFOLD-FAILED: G118 .Git\n'; exit 1; }
  launch ..
  [[ ! -e "$PROJ/c118/.Git/commondir" ]] && ! grep -qF 'c118' "$ERR" && ! grep -qF 'c118' <<<"$(mounts)" \
    && pass "G118 a .Git directory on a case-sensitive filesystem is left alone" \
    || fail "G118 .Git touched ($(ls -A "$PROJ/c118/.Git" | tr '\n' ' '); stderr: $(grep -F c118 "$ERR" | head -1))"
  rm -rf "$PROJ/c118"
fi
rmdir "$TMP/Probe118b" 2>/dev/null

# ── G119: an include whose file has another name in a writable mount ───────
# A read-only bind protects a path; an include names a file. One outside every
# mount was out of the agent's reach, but a second name of it in a writable
# mount — made by an earlier session with a wider mount, or by a tool that
# deduplicates files — writes the same file. With include.path=<outside>/inc.cfg
# and `ln <outside>/inc.cfg <mount>/side.cfg` the launch was silent, and a
# core.fsmonitor appended through side.cfg ran on the host (bugs review GIT-39).
# The same holds for a launcher link. A hook's is refused (G112).
mk119() {
  rm -rf "$TMP/h119" "$TMP/o119"; mkdir -p "$TMP/h119" "$TMP/o119" && "${G[@]}" init -q "$TMP/h119/r" \
    && printf '[user]\n\tname = x\n' > "$TMP/o119/inc.cfg" || { printf 'SCAFFOLD-FAILED: G119\n'; exit 1; }
}
mk119; ln "$TMP/o119/inc.cfg" "$TMP/o119/.dedup" && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/inc.cfg" \
  || { printf 'SCAFFOLD-FAILED: G119 outside\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'o119' "$ERR" \
  && pass "G119 an include of a file whose other name lies outside every mount is not named" \
  || fail "G119 both names outside (rc=$LAUNCH_RC; stderr: $(grep -F o119 "$ERR" | head -2 | tr '\n' ' '))"
ln "$TMP/o119/inc.cfg" "$TMP/h119/side.cfg" || { printf 'SCAFFOLD-FAILED: G119 side\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
w119="$(grep -A2 -F "WARNING: /workspace/h119/r/.git/config includes $TMP/o119/inc.cfg (include.path), which the agent can redirect" "$ERR")"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "it can write $TMP/o119/inc.cfg through another name of that file, in $TMP/h119" <<<"$w119" \
  && grep -qF "find $TMP/h119 -xdev -samefile $TMP/o119/inc.cfg" <<<"$w119" \
  && pass "G119 an include of a file outside every mount, with a name inside one, is named with the find that lists it" \
  || fail "G119 include with a second name in a mount (rc=$LAUNCH_RC; stderr: $(grep -A2 -F o119 "$ERR" | head -3 | tr '\n' ' '))"
# Through a file it includes that the agent cannot reach: the chain is followed.
"${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/a.cfg" && printf '[include]\n\tpath = inc.cfg\n' > "$TMP/o119/a.cfg" \
  || { printf 'SCAFFOLD-FAILED: G119 chain\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "it can write $TMP/o119/inc.cfg through another name of that file" <<<"$(grep -A1 -F "includes inc.cfg (include.path in $TMP/o119/a.cfg)" "$ERR")" \
  && pass "G119 such a file included by an included file is named" \
  || fail "G119 second-level include (rc=$LAUNCH_RC; stderr: $(grep -A1 -F o119 "$ERR" | head -2 | tr '\n' ' '))"
# Hidden in a directory the search cannot read: not ruled out, so named. Not as
# root, which can read any directory.
if [[ "$(id -u)" != 0 ]]; then
  mk119; mkdir -p "$TMP/h119/node_modules/x" && ln "$TMP/o119/inc.cfg" "$TMP/h119/node_modules/x/side" \
    && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/inc.cfg" && chmod 000 "$TMP/h119/node_modules/x" \
    || { printf 'SCAFFOLD-FAILED: G119 unreadable\n'; exit 1; }
  EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
  chmod 755 "$TMP/h119/node_modules/x"
  grep -qF "$TMP/o119/inc.cfg has another name, and $TMP/h119 could not be searched for it in full" "$ERR" \
    && pass "G119 such an include whose other name may lie in a directory that cannot be read is named" \
    || fail "G119 unreadable directory (rc=$LAUNCH_RC; stderr: $(grep -A1 -F o119 "$ERR" | head -2 | tr '\n' ' '))"
else
  printf 'SKIP: G119 an unreadable directory: root can read any directory\n'
fi
# A launcher link to such a file: the host reads it through the link.
mk119; mkdir -p "$TMP/h119/L" && : > "$TMP/h119/L/sandbox.sh" && : > "$TMP/h119/L/sandbox-common.sh" \
  && ln -s "$TMP/o119/inc.cfg" "$TMP/h119/L/x.cfg" && ln "$TMP/o119/inc.cfg" "$TMP/h119/side.cfg" \
  || { printf 'SCAFFOLD-FAILED: G119 launcher link\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "it can write $TMP/o119/inc.cfg through another name of that file, in $TMP/h119" <<<"$(grep -A1 -F "WARNING: launcher link $TMP/h119/L/x.cfg leads somewhere the agent can change" "$ERR")" \
  && pass "G119 a launcher link to a file outside every mount, with a name inside one, is named" \
  || fail "G119 launcher link (rc=$LAUNCH_RC; stderr: $(grep -A1 -F h119/L "$ERR" | head -2 | tr '\n' ' '))"
# A listing is bounded in time, and one cut off cannot rule a name out. A
# stand-in find answers for the listing as one that ran out of time, saying what
# started it.
mk119; mkdir -p "$TMP/fs119" && ln "$TMP/o119/inc.cfg" "$TMP/o119/.dedup" \
  && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/inc.cfg" \
  && printf '#!/bin/bash\ncase " $* " in *" -links "*" -exec "*) ps -o comm= -p "$PPID" >> %q; exit 124;; esac\nexec %q "$@"\n' "$TMP/fs119/by" "$(command -v find)" > "$TMP/fs119/find" \
  && chmod +x "$TMP/fs119/find" || { printf 'SCAFFOLD-FAILED: G119 bound\n'; exit 1; }
PATH="$TMP/fs119:$PATH" EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "$TMP/o119/inc.cfg has another name, and " "$ERR" && grep -qF "could not be searched for it in full" "$ERR" \
  && pass "G119 a listing cut off by its time bound does not rule the other name out" \
  || fail "G119 listing cut off (rc=$LAUNCH_RC; stderr: $(grep -A1 -F o119 "$ERR" | head -2 | tr '\n' ' '))"
# ps on macOS prints the program's path, and gtimeout is taken before timeout.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  [[ -s "$TMP/fs119/by" ]] && ! grep -qvE 'timeout$' "$TMP/fs119/by" \
    && pass "G119 each listing runs under timeout" \
    || fail "G119 a listing not under timeout (started by: $(sort -u "$TMP/fs119/by" 2>/dev/null | tr '\n' ' '))"
fi
rm -rf "$TMP/fs119"
# A file whose device cannot be read is not ruled out, as the hard-link refusal
# takes one (re-review of the GIT-39 fix). A stand-in stat fails for it alone.
mk119; mkdir -p "$TMP/fs119" && ln "$TMP/o119/inc.cfg" "$TMP/o119/.dedup" \
  && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/inc.cfg" \
  && printf '#!/bin/bash\n[[ "${!#}" == %q ]] && exit 1\nexec %q "$@"\n' "$TMP/o119/inc.cfg" "$(command -v stat)" > "$TMP/fs119/stat" \
  && chmod +x "$TMP/fs119/stat" || { printf 'SCAFFOLD-FAILED: G119 stat\n'; exit 1; }
PATH="$TMP/fs119:$PATH" EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "$TMP/o119/inc.cfg has another name, and its writable mounts could not be searched for it in full" "$ERR" \
  && pass "G119 an include of such a file whose device cannot be read is named" \
  || fail "G119 device not read (rc=$LAUNCH_RC; stderr: $(grep -A1 -F o119 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/fs119"
# The listings are removed before docker runs: the agent can fill them with names,
# in a TMPDIR that is often memory (re-review of the GIT-39 fix). Nothing of the
# launcher's is left in TMPDIR once it exits.
mk119; mkdir -p "$TMP/td119" && ln "$TMP/o119/inc.cfg" "$TMP/h119/side.cfg" \
  && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/inc.cfg" || { printf 'SCAFFOLD-FAILED: G119 TMPDIR\n'; exit 1; }
TMPDIR="$TMP/td119" FAKE_SESSION="ls -A '$TMP/td119' > '$TMP/td119.during'" EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "it can write $TMP/o119/inc.cfg through another name" "$ERR" && [[ -f "$TMP/td119.during" ]] && ! grep -q 'ai-launcher-names' "$TMP/td119.during" \
  && pass "G119 the listings are removed before docker runs" \
  || fail "G119 listings kept for the session (during it: $(tr '\n' ' ' < "$TMP/td119.during" 2>/dev/null))"
[[ -z "$(ls -A "$TMP/td119")" ]] \
  && pass "G119 nothing of the launcher's is left in TMPDIR after it exits" \
  || fail "G119 left in TMPDIR: $(ls -A "$TMP/td119" | tr '\n' ' ')"
rm -rf "$TMP/td119" "$TMP/td119.during"
# GIT-35's first case: a core.hooksPath into a read-only overlay (a planted
# launcher's node_modules, which the launcher link walk prunes), whose hook links
# to a writable script, was silent after the first launch. Its hooks are walked.
mk119; mkdir -p "$TMP/h119/L/node_modules/h" && : > "$TMP/h119/L/sandbox.sh" && : > "$TMP/h119/L/sandbox-common.sh" \
  && printf '#!/bin/sh\n' > "$TMP/h119/w.sh" && ln -s ../../../w.sh "$TMP/h119/L/node_modules/h/post-checkout" \
  && "${G[@]}" -C "$TMP/h119/r" config core.hooksPath ../L/node_modules/h || { printf 'SCAFFOLD-FAILED: G119 overlay hooksPath\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"; EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "it can change $TMP/h119/w.sh" <<<"$(grep -A2 -F "NOTE: $TMP/h119/L/node_modules/h/post-checkout, a hook your host's git runs" "$ERR")" \
  && pass "G119 a hook link in a core.hooksPath under a read-only overlay, into a writable script, is named on every launch" \
  || fail "G119 overlay hooksPath (rc=$LAUNCH_RC; stderr: $(grep -A2 -F node_modules/h "$ERR" | head -3 | tr '\n' ' '))"
# A core.hooksPath outside every mount: its hooks are walked, as hooks/'s are.
# A hook file there with another name in a writable mount, and a hook link there
# leading into one, were silent (review of the GIT-39 fix).
mk119; mkdir -p "$TMP/o119/hooks" && printf '#!/bin/sh\n' > "$TMP/o119/hooks/pre-commit" && chmod 755 "$TMP/o119/hooks/pre-commit" \
  && printf '#!/bin/sh\n' > "$TMP/o119/hooks/pre-push" && chmod 755 "$TMP/o119/hooks/pre-push" \
  && "${G[@]}" -C "$TMP/h119/r" config core.hooksPath "$TMP/o119/hooks" || { printf 'SCAFFOLD-FAILED: G119 hooksPath\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/o119/hooks" "$ERR" \
  && pass "G119 hooks in a core.hooksPath outside every mount, with no other name, are not named" \
  || fail "G119 plain hooksPath named (rc=$LAUNCH_RC; stderr: $(grep -F o119 "$ERR" | head -2 | tr '\n' ' '))"
ln "$TMP/o119/hooks/pre-commit" "$TMP/h119/side" && printf '#!/bin/sh\n' > "$TMP/h119/script" && rm -f "$TMP/o119/hooks/pre-push" \
  && ln -s "$TMP/h119/script" "$TMP/o119/hooks/pre-push" || { printf 'SCAFFOLD-FAILED: G119 hooksPath 2\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF "it can write $TMP/o119/hooks/pre-commit through another name of that file, in $TMP/h119" <<<"$(grep -A2 -F "NOTE: $TMP/o119/hooks/pre-commit, a hook your host's git runs for /workspace/h119/r/.git (core.hooksPath)" "$ERR")" \
  && pass "G119 a hook file in a core.hooksPath outside every mount, with a name inside one, is named" \
  || fail "G119 hooksPath hook with a second name (rc=$LAUNCH_RC; stderr: $(grep -A2 -F o119/hooks "$ERR" | head -3 | tr '\n' ' '))"
grep -qF "it can change $TMP/h119/script" <<<"$(grep -A2 -F "NOTE: $TMP/o119/hooks/pre-push, a hook your host's git runs" "$ERR")" \
  && pass "G119 a hook link in a core.hooksPath outside every mount, into a writable one, is named" \
  || fail "G119 hooksPath hook link (rc=$LAUNCH_RC; stderr: $(grep -A2 -F o119/hooks/pre-push "$ERR" | head -3 | tr '\n' ' '))"
# A core.hooksPath the agent can change is named once, as a whole: its hooks are
# not walked one by one as well.
mk119; mkdir -p "$TMP/h119/hk" && ln -s ../script "$TMP/h119/hk/pre-push" && printf '#!/bin/sh\n' > "$TMP/h119/script" \
  && "${G[@]}" -C "$TMP/h119/r" config core.hooksPath "$TMP/h119/hk" || { printf 'SCAFFOLD-FAILED: G119 writable hooksPath\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
grep -qF 'runs its git hooks from /workspace/h119/hk (core.hooksPath)' "$ERR" && ! grep -qF "NOTE: $TMP/h119/hk/pre-push" "$ERR" \
  && pass "G119 a core.hooksPath the agent can change is named once, its hooks not walked as well" \
  || fail "G119 writable hooksPath (rc=$LAUNCH_RC; stderr: $(grep -F h119/hk "$ERR" | head -2 | tr '\n' ' '))"
# What the checks cost, counted by stand-ins: one listing per writable mount on
# the file's device, whatever the number of includes and hooks leading to such
# files, shared by the include check and the hook check (a search per file let
# planted configs make a launch take hours); each mount's device read once (read
# per call, 20 repositories of 28 such hooks took 54 s where they took 22;
# review of the GIT-39 fix); and one lookup per file, however often it is asked.
mk119; mkdir -p "$TMP/fs119" && for e in 1 2 3; do printf '[user]\n' > "$TMP/o119/i$e.cfg" && ln "$TMP/o119/i$e.cfg" "$TMP/o119/.i$e"; done \
  && "${G[@]}" -C "$TMP/h119/r" config include.path "$TMP/o119/i1.cfg" \
  && printf '#!/bin/bash\ncase " $* " in *" -links "*" -exec "*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/fs119/log" "$(command -v find)" > "$TMP/fs119/find" \
  && printf '#!/bin/bash\ncase " $* " in *" "%q" "*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/h119" "$TMP/fs119/stat.log" "$(command -v stat)" > "$TMP/fs119/stat" \
  && printf '#!/bin/bash\ncase " $* " in *" -l -x -F "*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/fs119/grep.log" "$(command -v grep)" > "$TMP/fs119/grep" \
  && chmod +x "$TMP/fs119/find" "$TMP/fs119/stat" "$TMP/fs119/grep" || { printf 'SCAFFOLD-FAILED: G119 cost\n'; exit 1; }
: > "$TMP/fs119/log"; : > "$TMP/fs119/stat.log"; : > "$TMP/fs119/grep.log"
PATH="$TMP/fs119:$PATH" EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
n1_119="$(wc -l < "$TMP/fs119/log")"; s1_119="$(wc -l < "$TMP/fs119/stat.log")"; g1_119="$(wc -l < "$TMP/fs119/grep.log")"
"${G[@]}" -C "$TMP/h119/r" config --add include.path "$TMP/o119/i2.cfg" && "${G[@]}" -C "$TMP/h119/r" config --add include.path "$TMP/o119/i3.cfg" \
  && for e in pre-push post-merge post-checkout; do ln -s "$TMP/o119/i1.cfg" "$TMP/h119/r/.git/hooks/$e"; done || { printf 'SCAFFOLD-FAILED: G119 cost 2\n'; exit 1; }
: > "$TMP/fs119/log"; : > "$TMP/fs119/stat.log"; : > "$TMP/fs119/grep.log"
PATH="$TMP/fs119:$PATH" EXTRA_MOUNTS="$TMP/h119" launch "$TMP/app"
n4_119="$(wc -l < "$TMP/fs119/log")"; s4_119="$(wc -l < "$TMP/fs119/stat.log")"; g4_119="$(wc -l < "$TMP/fs119/grep.log")"
[[ "$LAUNCH_RC" == 0 && "$n1_119" -ge 1 && "$n4_119" == "$n1_119" ]] \
  && pass "G119 three includes and three hooks leading to such files cost the listings one include does ($n1_119)" \
  || fail "G119 listings per file (rc=$LAUNCH_RC; $n1_119 for one include, $n4_119 for three and three hooks)"
[[ "$s4_119" == "$s1_119" ]] \
  && pass "G119 a mount's device is read once a launch, however many files are asked about ($s1_119 reads)" \
  || fail "G119 a mount's device read per file ($s1_119 for one include, $s4_119 for three and three hooks)"
# Numbers, not strings: BSD wc pads its count with spaces.
(( g1_119 == 1 && g4_119 == 3 )) \
  && pass "G119 one lookup per file asked about, however often it is asked" \
  || fail "G119 lookups ($g1_119 for one include; $g4_119 for three files asked about seven times)"
rm -rf "$TMP/fs119"
# Bounded, in the launcher's own shell (the functions alone): the listings'
# time before the FIFO search starts is all the search's clock counts — a walk
# between them does not; past 64 MiB of listing, and past 256 files asked about,
# nothing is ruled out. A stand-in find takes 2 s per listing. The files asked
# about are made-up inodes on the mount's device.
fns119="$TMP/fns119.sh"
for f119 in _term _q _timeout_prefix _launcher_dev_ino _win_mounts _fs_mounts_in _fs_ml_devof _fs_linked_in _ro_fifo_search; do
  awk -v f="$f119() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns119"
grep -E '^(declare -A _fs_ml_|_fs_ml_dir=|_fs_mp=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns119"
mkdir -p "$TMP/u119/m" "$TMP/fs119" && printf 'x\n' > "$TMP/u119/m/a" && ln "$TMP/u119/m/a" "$TMP/u119/m/b" \
  && printf 'x\n' > "$TMP/u119/m/c" && ln "$TMP/u119/m/c" "$TMP/u119/m/d" \
  && printf '#!/bin/bash\ncase " $* " in *" -links "*" -exec "*) sleep 2;; esac\nexec %q "$@"\n' "$(command -v find)" > "$TMP/fs119/find" \
  && chmod +x "$TMP/fs119/find" || { printf 'SCAFFOLD-FAILED: G119 bounds\n'; exit 1; }
u119() {  # $1 = script run with the functions, the mount as m, its device as $dev
  ( cd "$TMP/u119" && TMPDIR="$TMP/u119" bash -c 'set -euo pipefail; source "$1"; _fs_deadline=""; m=("$2"); dev="$(_launcher_dev_ino "$2")"; dev="${dev%% *}"; eval "$3"; rm -rf "$_fs_ml_dir"' _ "$fns119" "$TMP/u119/m" "$1" ) 2>/dev/null
}
b119="$(PATH="$TMP/fs119:$PATH" u119 '_fs_linked_in "$dev 9999999999901" m r || true; sleep 3; s=(); _ro_fifo_search s m; echo "$((_fs_deadline - SECONDS))"')"
[[ "$b119" =~ ^[0-9]+$ ]] && (( b119 >= 86 && b119 <= 89 )) \
  && pass "G119 the FIFO search's clock counts the listings' time, not the walk after them ($b119 s left of 90)" \
  || fail "G119 FIFO clock after a listing (${b119:-nothing} s left of 90; 88 expected)"
c119="$(u119 'r1=0; _fs_linked_in "$dev 9999999999901" m r || r1=$?; _fs_ml_ans=(); _fs_ml_file=(); _fs_ml_cut=(); _fs_ml_bytes=8; r2=0; _fs_linked_in "$dev 9999999999902" m r || r2=$?; echo "$r1 $r2"')"
[[ "$c119" == "1 2" ]] \
  && pass "G119 a listing past its space cannot rule a name out" \
  || fail "G119 listing space (${c119:-nothing}; 1 2 expected)"
t119="$(u119 '_fs_ml_spent=60; r1=0; _fs_linked_in "$dev 9999999999901" m r || r1=$?; echo "$r1 ${#_fs_ml_file[@]}"')"
[[ "$t119" == "2 1" ]] \
  && pass "G119 with the listings' 60 s spent before the FIFO search, a listing is not run and rules nothing out" \
  || fail "G119 listings past their 60 s (${t119:-nothing}; 2 1 expected)"
d119="$(u119 '_fs_deadline=$((SECONDS - 1)); r1=0; _fs_linked_in "$dev 9999999999901" m r || r1=$?; echo "$r1"')"
[[ "$d119" == 1 ]] \
  && pass "G119 past the FIFO search's deadline, a listing still gets its second, as the search's own do" \
  || fail "G119 listing past the deadline (${d119:-nothing}; 1 expected)"
mkdir -p "$TMP/u119/m2" && printf 'x\n' > "$TMP/u119/m2/a" && ln "$TMP/u119/m2/a" "$TMP/u119/m2/b" || { printf 'SCAFFOLD-FAILED: G119 m2\n'; exit 1; }
p119="$( cd "$TMP/u119" && TMPDIR="$TMP/u119" bash -c 'set -euo pipefail; source "$1"; _fs_deadline=""; m=("$2"); l="$(_launcher_dev_ino "$2/a")"; _fs_ml_bytes=$(( ${#l} - 1 )); r=0; _fs_linked_in "${l%?}" m o || r=$?; echo "$r"; rm -rf "$_fs_ml_dir"' _ "$fns119" "$TMP/u119/m2" 2>/dev/null)"
[[ "$p119" == 2 ]] \
  && pass "G119 a line a listing cut short does not match a shorter inode number" \
  || fail "G119 partial line (${p119:-nothing}; 2 expected)"
q119="$(u119 'for i in $(seq 1 257); do r=0; _fs_linked_in "$dev 99999999999$((i + 1000))" m o || r=$?; printf "%s" "$r"; done')"
[[ "${q119:0:256}" == "$(printf '1%.0s' $(seq 1 256))" && "${q119:256}" == 2 ]] \
  && pass "G119 past 256 files asked about, nothing is ruled out" \
  || fail "G119 files asked about (${q119:250} at the end of ${#q119})"
rm -rf "$fns119" "$TMP/u119"
rm -rf "$TMP/fs119" "$TMP/h119" "$TMP/o119"

# ── G128: the listing of a writable mount's linked files, driven directly ────
# _fs_linked_in lists only the writable mounts on the file's own device (a hard
# link never leaves it), each search at most 30 s and at most what the FIFO
# search's budget has left; a listing cut short keeps every whole line it got
# and drops only a line cut in two, so a file it did list is still found there;
# and a temporary directory that cannot be made refuses the launch (GAP-2 slice
# 4: each of those, damaged, survived).
fns128="$TMP/fns128.sh"
for f128 in _term _q _timeout_prefix _launcher_dev_ino _win_mounts _fs_mounts_in _fs_ml_devof _fs_linked_in; do
  awk -v f="$f128() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns128"
# What it keeps for the launch, as sandbox.sh declares it.
grep -E '^(declare -A _fs_ml_|_fs_ml_dir=|_fs_mp=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns128"
M128="$TMP/m128"; mkdir -p "$M128/a" "$M128/b" && : > "$M128/a/f" && ln "$M128/a/f" "$M128/x128"
sh128="$TMP/sh128"; mkdir -p "$sh128"
# timeout -k 2 <seconds> find <mount> …: records the seconds and the mount.
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$3" "$5" >> %q\nshift 3\nexec "$@"\n' "$TMP/to128.log" > "$sh128/timeout"
cp "$sh128/timeout" "$sh128/gtimeout"; chmod +x "$sh128/timeout" "$sh128/gtimeout"
# run128 <fresh|short>: asks about $M128/a/f, with $M128/a and $M128/b writable and
# $M128/b on another device. Prints "<status> <mount>".
run128() {
  bash -c 'source "$1"; A="$2" B="$3" f="$4"
    eval "$(declare -f _launcher_dev_ino | sed "1s/^_launcher_dev_ino/_ldi128/")"
    _launcher_dev_ino() { if [[ "$1" == "$B" ]]; then echo "999999 1"; else _ldi128 "$1"; fi; }
    [[ "$5" == short ]] && _fs_deadline=$((SECONDS + 5))
    m=("$A" "$B"); di="$(_launcher_dev_ino "$f")"; rc=0; _fs_linked_in "$di" m o || rc=$?
    printf "%s %s\n" "$rc" "$o"; rm -rf "$_fs_ml_dir"' _ "$fns128" "$M128/a" "$M128/b" "$M128/a/f" "$1" >"$TMP/o128" 2>"$TMP/e128"
}
for case128 in fresh:30 short:5; do
  : > "$TMP/to128.log"; PATH="$sh128:$PATH" run128 "${case128%%:*}"
  got128="$(cut -d' ' -f1 "$TMP/to128.log" | tr '\n' ' ')"
  if [[ "$(cat "$TMP/o128")" == "0 $M128/a" ]] && ! grep -qF " $M128/b" "$TMP/to128.log" \
     && [[ "$got128" == "${case128#*:} " || "$got128" == "$(( ${case128#*:} - 1 )) " ]]; then
    pass "G128 a file's second name is found by listing only the mount on its device, the listing given ${got128% } s (budget ${case128%%:*})"
  else
    fail "G128 listing, budget ${case128%%:*} (want '0 $M128/a', ${case128#*:} s, $M128/b not listed; got '$(cat "$TMP/o128")', listed: $(tr '\n' ' ' < "$TMP/to128.log"); $(tr '\n' ' ' < "$TMP/e128"))"
  fi
done
# Cut short (out of time) after its last whole line, or in the middle of a
# line: the file named on a whole line is found either way.
for cut128 in "whole::" "mid-line:printf 9"; do
  printf '#!/bin/bash\n%q "$@"; %s; exit 124\n' "$(command -v find)" "${cut128#*:}" > "$sh128/find"; chmod +x "$sh128/find"
  PATH="$sh128:$PATH" run128 fresh
  [[ "$(cat "$TMP/o128")" == "0 $M128/a" ]] \
    && pass "G128 a listing cut short (${cut128%%:*}) keeps every whole line, and the file one names is found" \
    || fail "G128 listing cut short, ${cut128%%:*} (want '0 $M128/a', got '$(cat "$TMP/o128")'; $(tr '\n' ' ' < "$TMP/e128"))"
done
rm -f "$sh128/find"
# No temporary directory: refused.
TMPDIR="$TMP/none128" run128 fresh; rc128=$?
[[ "$rc128" != 0 && ! -s "$TMP/o128" ]] && grep -qF "cannot make a temporary directory in" "$TMP/e128" \
  && pass "G128 a listing with no temporary directory refuses the launch" \
  || fail "G128 listing, no temporary directory (rc=$rc128; $(cat "$TMP/o128" "$TMP/e128" | tr '\n' ' '))"
rm -rf "$fns128" "$M128" "$sh128" "$TMP/to128.log" "$TMP/o128" "$TMP/e128"

# ── G129: a hard-linked file reached through a link, driven directly ─────────
# _fs_reachable fails closed: the file counts as one the agent can reach when
# the link leads into a writable mount, whatever device the file is on there (a
# filesystem mounted inside the mount), when the link's way cannot be followed
# to its end, and when the file cannot be stat'ed (GAP-2 slice 4: each, damaged,
# survived).
fns129="$TMP/fns129.sh"
for f129 in _term _q _timeout_prefix _launcher_dev_ino _win_mounts _fs_mounts_in _fs_ml_devof _fs_linked_in _fs_other_names _fs_in_rw _fs_reachable; do
  awk -v f="$f129() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns129"
grep -E '^(declare -A _fs_reach_cache=|declare -A _fs_ml_|_fs_ml_dir=|_fs_mp=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns129"
M129="$TMP/m129"; mkdir -p "$M129/m" "$M129/w" && : > "$M129/m/t" && ln "$M129/m/t" "$M129/m/t2" && ln -s "$M129/m/t" "$M129/h"
# run129 <nested|nowalk|nostat>: is $M129/h, a link to $M129/m/t, reachable? For
# nested, $M129/m is the writable mount; for the others, $M129/w beside it is,
# so the way out of every writable mount has to be judged.
run129() {
  bash -c 'source "$1"; M="$2"; tgt129="$M/m/t"; how="$3"
    eval "$(declare -f _launcher_dev_ino | sed "1s/^_launcher_dev_ino/_ldi129/")"
    _launcher_dev_ino() {
      if [[ "$1" == "$tgt129" && "$how" == nested ]]; then echo "999999 7"
      elif [[ "$1" == "$tgt129" && "$how" == nostat ]]; then return 1
      else _ldi129 "$1"; fi
    }
    _fs_target() { [[ "$how" == nowalk ]] || printf "%s" "$tgt129"; }
    if [[ "$how" == nested ]]; then _fs_rw=("$M/m"); else _fs_rw=("$M/w"); fi
    hits=("$M/h"); _fs_other_names hits
    if _fs_reachable "$M/h"; then echo reachable; else echo unreachable; fi
    rm -rf "$_fs_ml_dir"' _ "$fns129" "$M129" "$1" >"$TMP/o129" 2>"$TMP/e129"
}
for case129 in "nested:on another device inside the writable mount" "nowalk:whose way cannot be followed to its end" "nostat:that cannot be stat'ed"; do
  run129 "${case129%%:*}"
  [[ "$(cat "$TMP/o129")" == reachable ]] \
    && pass "G129 a hard-linked file reached through a link, ${case129#*:}, counts as reachable" \
    || fail "G129 ${case129%%:*} (want reachable, got '$(cat "$TMP/o129")'; $(tr '\n' ' ' < "$TMP/e129"))"
done
rm -rf "$fns129" "$M129" "$TMP/o129" "$TMP/e129"

# ── G130: the count of slow reads is made only in the launcher's own shell ──
# _rd_prep, first called in a subshell (a read reached before run_container's
# own call, as a function driven on its own is), makes no directory, which would
# be lost to the next read and to the EXIT trap, and still succeeds under
# errexit; in the shell itself it makes one (GAP-2 slice 4: the guard, damaged
# either way, survived).
fns130="$TMP/fns130.sh"
for f130 in _timeout_prefix _rd_prep; do
  awk -v f="$f130() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns130"
printf '_rd_init="" _rd_dir="" _rd_tp=() _rd_lim=0\n' >> "$fns130"
rm -rf "$TMP/rdt130"; mkdir -p "$TMP/rdt130"
TMPDIR="$TMP/rdt130" bash -c 'set -euo pipefail; source "$1"
  ( _rd_prep; printf "subshell:%s\n" "${_rd_dir:-none}" )
  ls -A "$TMPDIR"; _rd_prep; printf "shell:%s\n" "${_rd_dir:+made}"; rm -rf "$_rd_dir"' _ "$fns130" >"$TMP/o130" 2>&1; rc130=$?
[[ "$rc130" == 0 && "$(cat "$TMP/o130")" == $'subshell:none\nshell:made' ]] \
  && pass "G130 the count of slow reads is made in the launcher's own shell, never in a subshell" \
  || fail "G130 _rd_prep in a subshell (rc=$rc130; $(tr '\n' '|' < "$TMP/o130"))"
rm -rf "$fns130" "$TMP/rdt130" "$TMP/o130"

# ── G131: a second name on a filesystem mounted inside a writable mount ─────
# docker's binds are recursive, so a filesystem mounted inside a writable mount
# is the agent's to write too. A file outside every mount whose second name lies
# on such a filesystem — its device the file's, the writable mount's root on
# another — went unseen: only the mounts whose root is on the file's device were
# listed (bugs review GIT-43). Here the writable mount is a tmpfs and a directory
# of TMPDIR's filesystem is bound inside it, in a user namespace.
if command -v unshare >/dev/null 2>&1 && unshare --user --map-current-user --mount --keep-caps true 2>/dev/null; then
  fns131="$TMP/fns131.sh"
  for f131 in _term _q _timeout_prefix _launcher_dev_ino _win_mounts _fs_mounts_in _fs_ml_devof _fs_linked_in; do
    awk -v f="$f131() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
  done > "$fns131"
  grep -E '^(declare -A _fs_ml_|_fs_ml_dir=|_fs_mp=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns131"
  M131="$TMP/m131"; mkdir -p "$M131/w" "$M131/w2" "$M131/real" "$M131/out" && : > "$M131/out/f" && ln "$M131/out/f" "$M131/real/x" \
    || { printf 'SCAFFOLD-FAILED: G131\n'; exit 1; }
  # A second writable mount, w2, holds the same bind under a directory the
  # agent made unsearchable: its device cannot be read, so nothing is ruled
  # out. Run without the namespace's capabilities, which would search it anyway.
  unshare --user --map-current-user --mount --keep-caps bash -c '
    M="$2"; mount -t tmpfs tmpfs "$M/w" && mkdir "$M/w/sub" && mount --bind "$M/real" "$M/w/sub" || exit 77
    mount -t tmpfs tmpfs "$M/w2" && mkdir -p "$M/w2/a/sub" && mount --bind "$M/real" "$M/w2/a/sub" && chmod 000 "$M/w2/a" || exit 77
    command -v setpriv >/dev/null 2>&1 || exit 77
    exec setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- bash -c '\''
      M="$2"; source "$1"; di="$(_launcher_dev_ino "$M/out/f")"
      m=("$M/w"); rc=0; TMPDIR="$M" _fs_linked_in "$di" m o || rc=$?
      printf "%s %s\n" "$rc" "$o"; rm -rf "$_fs_ml_dir"
      _fs_ml_ans=(); _fs_ml_file=(); _fs_ml_dir=""
      m=("$M/w2"); rc=0; TMPDIR="$M" _fs_linked_in "$di" m o 2>/dev/null || rc=$?
      printf "%s\n" "$rc"; rm -rf "$_fs_ml_dir"'\'' _ "$1" "$M"' _ "$fns131" "$M131" >"$TMP/o131" 2>"$TMP/e131"; rc131=$?
  if (( rc131 == 77 )); then
    printf 'SKIP: G131 a filesystem mounted inside a writable mount — no tmpfs, bind mount or setpriv in a user namespace here\n'
  else
    [[ "$(head -n 1 "$TMP/o131")" == "0 $M131/w/sub" ]] \
      && pass "G131 a second name on a filesystem mounted inside a writable mount is found there" \
      || fail "G131 nested mount on the file's device (want '0 $M131/w/sub', got '$(head -n 1 "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
    [[ "$(sed -n 2p "$TMP/o131")" == 2 ]] \
      && pass "G131 a mount point inside a writable mount that cannot be stat'ed rules nothing out" \
      || fail "G131 unsearchable nested mount (want 2, got '$(sed -n 2p "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
  fi
  chmod 700 "$M131/w2/a" 2>/dev/null
  rm -rf "$fns131" "$M131" "$TMP/o131" "$TMP/e131"
elif [[ "$(uname -s)" == Darwin ]] && command -v hdiutil >/dev/null 2>&1; then
  # macOS has no bind mount: a disk image attached inside the writable mount,
  # its mount points read from mount(8). That names them by the physical path,
  # as pwd -P does (/private/var/…, not /var/…), so a TMPDIR reached through a
  # link is matched too (platform-issues, the Mac agent's half of GIT-43).
  fns131="$TMP/fns131.sh"
  for f131 in _term _q _timeout_prefix _launcher_dev_ino _win_mounts _fs_mounts_in _fs_ml_devof _fs_linked_in; do
    awk -v f="$f131() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
  done > "$fns131"
  grep -E '^(declare -A _fs_ml_|_fs_ml_dir=|_fs_mp=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns131"
  M131="$TMP/m131"; mkdir -p "$M131/w/a/mnt" "$M131/t" \
    && hdiutil create -quiet -size 8m -fs APFS -volname g131 -o "$M131/img.dmg" >/dev/null 2>&1 \
    && hdiutil attach -quiet -nobrowse -mountpoint "$M131/w/a/mnt" "$M131/img.dmg" >/dev/null 2>&1; rc131=$?
  if (( rc131 != 0 )); then
    printf 'SKIP: G131 a filesystem mounted inside a writable mount — hdiutil could not make or attach an image here\n'
  else
    : > "$M131/w/a/mnt/f" && ln "$M131/w/a/mnt/f" "$M131/w/a/mnt/g" || { hdiutil detach -quiet -force "$M131/w/a/mnt"; printf 'SCAFFOLD-FAILED: G131\n'; exit 1; }
    di131="$(stat -f '%d %i' "$M131/w/a/mnt/f")"
    q131='source "$1"; m=("$2"); rc=0; TMPDIR="$3" _fs_linked_in "$4" m o 2>/dev/null || rc=$?; printf "%s %s\n" "$rc" "$o"'
    bash -c "$q131" _ "$fns131" "$M131/w" "$M131/t" "$di131" >"$TMP/o131" 2>"$TMP/e131"
    chmod 000 "$M131/w/a"
    bash -c "$q131" _ "$fns131" "$M131/w" "$M131/t" "$di131" >>"$TMP/o131" 2>>"$TMP/e131"
    chmod 700 "$M131/w/a"
    hdiutil detach -quiet -force "$M131/w/a/mnt" >/dev/null 2>&1
    [[ "$(head -n 1 "$TMP/o131")" == "0 $M131/w/a/mnt" ]] \
      && pass "G131 a second name on a disk image attached inside a writable mount is found there" \
      || fail "G131 attached image (want '0 $M131/w/a/mnt', got '$(head -n 1 "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
    [[ "$(sed -n 2p "$TMP/o131")" == "2 $M131/w/a/mnt" ]] \
      && pass "G131 an attached image under a directory that cannot be searched rules nothing out" \
      || fail "G131 attached image, unsearchable (want '2 $M131/w/a/mnt', got '$(sed -n 2p "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
  fi
  rm -rf "$fns131" "$M131" "$TMP/o131" "$TMP/e131"
else
  printf 'SKIP: G131 a filesystem mounted inside a writable mount — no unprivileged user namespace here\n'
fi
# Where there is no /proc/self/mountinfo (macOS), mount(8)'s table: a mount
# point may hold " on " and " (", which the parse keeps.
fns131="$TMP/fns131.sh"
for f131 in _win_mounts _fs_mounts_in; do
  awk -v f="$f131() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns131"
grep -E '^_fs_mp=' "$ENGINE/sandbox.sh" >> "$fns131"
bash -c 'source "$1"; _wm_ok=0
  mount() { printf "%s\n" "/dev/disk3s1 on / (apfs, local, journaled)" \
    "/dev/disk4s1 on /p/w/a on b (x (apfs, local, nodev)" "map auto_home on /p/w (autofs, automounted)" \
    "/dev/disk5 on /p/wx (hfs, local)" "//u@srv/s on /p/w/c (smbfs, nodev, nosuid)"; }
  _fs_mounts_in /p/w o; for i in "${o[@]}"; do printf "%s|" "${_fs_mp[i]}"; done' _ "$fns131" >"$TMP/o131" 2>"$TMP/e131"
[[ "$(cat "$TMP/o131")" == "/p/w/a on b (x|/p/w/c|" ]] \
  && pass "G131 without /proc/self/mountinfo, mount(8)'s table names the mount points below a writable mount" \
  || fail "G131 mount(8) parse (got '$(cat "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
# The mount points below each writable mount are found once a launch, however
# many files are asked about: matched again for each, a launch of planted links
# to thousands of linked files took minutes (review of the GIT-43 fix).
for f131 in _term _q _timeout_prefix _launcher_dev_ino _fs_ml_devof _fs_linked_in; do
  awk -v f="$f131() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done >> "$fns131"
grep -E '^(declare -A _fs_ml_|_fs_ml_dir=|if stat -c )' "$ENGINE/sandbox.sh" >> "$fns131"
mkdir -p "$TMP/m131/a" "$TMP/m131/b" || { printf 'SCAFFOLD-FAILED: G131 cache\n'; exit 1; }
TMPDIR="$TMP/m131" bash -c 'source "$1"; n=0
  eval "$(declare -f _fs_mounts_in | sed "1s/^_fs_mounts_in/_fmi131/")"
  _fs_mounts_in() { n=$((n + 1)); _fmi131 "$@"; }
  m=("$2/a" "$2/b"); d="$(_launcher_dev_ino "$2/a")"; d="${d%% *}"
  for i in $(seq 1 40); do _fs_linked_in "$d 9999999$i" m o || true; done
  echo "$n"; rm -rf "$_fs_ml_dir"' _ "$fns131" "$TMP/m131" >"$TMP/o131" 2>"$TMP/e131"
[[ "$(cat "$TMP/o131")" == 2 ]] \
  && pass "G131 the mount points below each writable mount are found once, for 40 files asked about" \
  || fail "G131 found per file (want 2 searches, got '$(cat "$TMP/o131")'; $(tr '\n' ' ' < "$TMP/e131"))"
rm -rf "$fns131" "$TMP/m131" "$TMP/o131" "$TMP/e131"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
