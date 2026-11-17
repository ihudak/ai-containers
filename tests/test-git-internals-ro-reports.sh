#!/usr/bin/env bash
# tests/test-git-internals-ro-reports.sh — what the launch says about what a
# repository already holds when it first protects it, and about the repositories
# a session made, when it ends.
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

# ── G26: the launch that first protects a repository names what its config ────
# already runs — the one moment that can only be what was set before the
# protection existed. Once: a later launch says nothing. Names, never values.
mkdir -p "$TMP/fp/r" "$TMP/fp/clean"
"${G[@]}" -C "$TMP/fp/r" init -q && "${G[@]}" -C "$TMP/fp/clean" init -q
"${G[@]}" -C "$TMP/fp/r" config core.sshCommand 'ssh -i sekrit-key'
"${G[@]}" -C "$TMP/fp/r" config core.fsmonitor .git/hooks/fsmonitor-watchman
"${G[@]}" -C "$TMP/fp/r" config filter.lfs.clean 'git-lfs clean -- %f'
"${G[@]}" -C "$TMP/fp/r" config alias.sh '!echo hi'
"${G[@]}" -C "$TMP/fp/r" config alias.st status
"${G[@]}" -C "$TMP/fp/clean" config core.fsmonitor true
"${G[@]}" -C "$TMP/fp/r" config sendemail.smtpserver /usr/bin/msmtp
"${G[@]}" -C "$TMP/fp/r" config hook.lint.command 'run-lint' && "${G[@]}" -C "$TMP/fp/r" config hook.lint.event pre-commit
"${G[@]}" -C "$TMP/fp/clean" config sendemail.smtpserver smtp.example.org
# A key set only in config.worktree is named, and that file is in the review.
mkdir -p "$TMP/fp/wtc" && "${G[@]}" -C "$TMP/fp/wtc" init -q && "${G[@]}" -C "$TMP/fp/wtc" config extensions.worktreeConfig true
"${G[@]}" -C "$TMP/fp/wtc" config --worktree filter.x.smudge 'x-smudge'
EXTRA_MOUNTS="$TMP/fp" launch "$TMP/app"
grep -qF 'filter.x.smudge' <<<"$(grep -A1 -F 'NOTE: /workspace/fp/wtc/.git is protected for the first time, and its config' "$ERR")" \
  && grep -qF "git config --file $TMP/fp/wtc/.git/config.worktree --list" "$ERR" \
  && pass "G26 a key set only in config.worktree is named, with config.worktree to review" \
  || fail "G26 config.worktree key (stderr: $(grep -A4 'wtc/.git is protected' "$ERR" | tr '\n' ' '))"
nl26="$(grep -A1 -F 'NOTE: /workspace/fp/r/.git is protected for the first time, and its config' "$ERR" | tail -1)"
[[ "$nl26" == *core.sshcommand* && "$nl26" == *core.fsmonitor* && "$nl26" == *filter.lfs.clean* && "$nl26" == *alias.sh* ]] \
  && grep -qF "git config --file $TMP/fp/r/.git/config --list" "$ERR" \
  && pass "G26 the first protection names the keys that run programs, and how to review them" \
  || fail "G26 first-protection NOTE (got: $nl26; stderr: $(grep -A3 'first time' "$ERR" | tr '\n' ' '))"
# An alias that is no shell command is a git command, which may run a program
# an argument names: named last, as what it is (G332).
[[ "$nl26" == *", alias.st (a git command, which may run one itself)." ]] \
  && ! grep -q 'fp/clean/.git is protected for the first time, and its config' "$ERR" \
  && pass "G26 an alias that is no shell command is named last, as what it is; git's own fsmonitor daemon and an SMTP server given as a host name are not named" \
  || fail "G26 the plain alias, or benign keys named (got: $nl26; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
# Two mutants that swapped the two survived every test (GAP-2's slice 2;
# sandbox.sh: `_git_exec_keys()`).
# A config-based hook (hook.<name>.command, git 2.36) runs a program too: it
# was not named (re-review of the GIT-31 fix).
[[ "$nl26" == *hook.lint.command* ]] \
  && pass "G26 a config-based hook is named" \
  || fail "G26 hook.<name>.command not named (got: $nl26)"
[[ "$nl26" == *sendemail.smtpserver* ]] \
  && pass "G26 an SMTP server given as a path is named" \
  || fail "G26 sendemail.smtpserver as a path not named (got: $nl26)"
! grep -qF 'sekrit' "$ERR" && pass "G26 no value is printed" || fail "G26 a value was printed"
EXTRA_MOUNTS="$TMP/fp" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'protected for the first time' "$ERR" \
  && pass "G26 the next launch says nothing: the repository is already protected" \
  || fail "G26 repeated NOTE (rc=$LAUNCH_RC; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/fp"

# ── G27: …and the hooks its hooks/ already holds ──────────────────────────────
# A repository the agent made in a subdirectory arrives with whatever hooks it
# put there, and protecting it freezes them. Only what git would run: a name
# from githooks(5), executable (through a link, too). Nothing when
# core.hooksPath sends git elsewhere; nothing on a later launch.
mkdir -p "$TMP/fh/h" "$TMP/fh/hp" "$TMP/fh/none" "$TMP/fh/wtp" "$TMP/fh/hpw"
for r in h hp none wtp hpw; do "${G[@]}" -C "$TMP/fh/$r" init -q; done
for e in pre-commit post-checkout my-helper; do printf '#!/bin/sh\n' > "$TMP/fh/h/.git/hooks/$e"; done
printf '#!/bin/sh\n' > "$TMP/fh/h/.git/hooks/pre-push"
printf '#!/bin/sh\n' > "$TMP/fh-outside-pm"
chmod 755 "$TMP/fh/h/.git/hooks/pre-commit" "$TMP/fh/h/.git/hooks/post-checkout" \
  "$TMP/fh/h/.git/hooks/my-helper" "$TMP/fh-outside-pm"
chmod 644 "$TMP/fh/h/.git/hooks/pre-push"
ln -s "$TMP/fh-outside-pm" "$TMP/fh/h/.git/hooks/post-merge"
ln -s "$TMP/fh-missing" "$TMP/fh/h/.git/hooks/post-rewrite"
printf '#!/bin/sh\n' > "$TMP/fh/hp/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/hp/.git/hooks/pre-commit"
"${G[@]}" -C "$TMP/fh/hp" config core.hooksPath .githooks
printf '#!/bin/sh\n' > "$TMP/fh/wtp/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/wtp/.git/hooks/pre-commit"
"${G[@]}" -C "$TMP/fh/wtp" config extensions.worktreeConfig true
"${G[@]}" -C "$TMP/fh/wtp" config --worktree core.hooksPath .githooks
# A config.worktree git reads that sets no core.hooksPath leaves the config's in
# force: a mutant that read it whenever it existed, and listed hooks/, survived
# every test (GAP-2's slice 2; sandbox.sh: `_git_runs()`).
printf '#!/bin/sh\n' > "$TMP/fh/hpw/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/hpw/.git/hooks/pre-commit"
"${G[@]}" -C "$TMP/fh/hpw" config core.hooksPath .githooks && "${G[@]}" -C "$TMP/fh/hpw" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$TMP/fh/hpw" config --worktree user.name w27
# Without extensions.worktreeConfig git never reads config.worktree, so a
# core.hooksPath there must not hide what hooks/ runs.
mkdir -p "$TMP/fh/wtx" && "${G[@]}" -C "$TMP/fh/wtx" init -q
printf '#!/bin/sh\n' > "$TMP/fh/wtx/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/wtx/.git/hooks/pre-commit"
"${G[@]}" config --file "$TMP/fh/wtx/.git/config.worktree" core.hooksPath .githooks
EXTRA_MOUNTS="$TMP/fh" launch "$TMP/app"
hk27="$(grep -A1 -F 'NOTE: /workspace/fh/h/.git is protected for the first time, and its hooks/' "$ERR" | tail -1)"
[[ "$hk27" == *pre-commit* && "$hk27" == *post-checkout* && "$hk27" == *post-merge* ]] \
  && grep -qF "ls -l $TMP/fh/h/.git/hooks" "$ERR" \
  && pass "G27 the first protection names the hooks git would run, and how to review them" \
  || fail "G27 hooks NOTE (got: $hk27; stderr: $(grep -A3 'first time' "$ERR" | tr '\n' ' '))"
[[ -n "$hk27" && "$hk27" != *pre-push* && "$hk27" != *my-helper* && "$hk27" != *sample* && "$hk27" != *post-rewrite* ]] \
  && pass "G27 a hook that is not executable, a name git never runs, a .sample and a dangling link are not named" \
  || fail "G27 inert hooks named (got: $hk27)"
grep -qF 'core.hookspath' <<<"$(grep -A1 -F 'NOTE: /workspace/fh/hpw/.git is protected for the first time, and its config' "$ERR")" \
  && ! grep -qE 'fh/(hp|wtp|none|hpw)/\.git is protected for the first time, and its hooks/' "$ERR" \
  && pass "G27 nothing when core.hooksPath (config or config.worktree) sends git elsewhere, or hooks/ holds only samples" \
  || fail "G27 hooks NOTE where git runs none of them (stderr: $(grep -A1 'its hooks/' "$ERR" | tr '\n' ' '))"
grep -qF 'pre-commit' <<<"$(grep -A1 -F 'NOTE: /workspace/fh/wtx/.git is protected for the first time, and its hooks/' "$ERR")" \
  && pass "G27 a core.hooksPath in a config.worktree git does not read hides nothing" \
  || fail "G27 ignored config.worktree hid the hooks (stderr: $(grep -A1 'wtx' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$TMP/fh" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'its hooks/' "$ERR" \
  && pass "G27 the next launch says nothing: the repository is already protected" \
  || fail "G27 repeated hooks NOTE (rc=$LAUNCH_RC; stderr: $(grep -A1 'its hooks/' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/fh" "$TMP/fh-outside-pm"

# ── G93: a repository an earlier launch protected is reported once too ───────
# The first protection is the launch that makes the commondir placeholder, so a
# repository whose placeholder was already there — made by an earlier engine,
# or planted with a repository the agent made in a session — never had its
# keys and hooks named. A record of what was reported, kept on the host, makes
# it once, and once only.
mkdir -p "$TMP/ep/r" "$TMP/ep/clean"
"${G[@]}" -C "$TMP/ep/r" init -q && "${G[@]}" -C "$TMP/ep/clean" init -q \
  || { printf 'SCAFFOLD-FAILED: G93\n'; exit 1; }
"${G[@]}" -C "$TMP/ep/r" config core.sshCommand 'ssh -i sekrit93'
printf '#!/bin/sh\n' > "$TMP/ep/r/.git/hooks/pre-commit"; chmod 755 "$TMP/ep/r/.git/hooks/pre-commit"
for r in r clean; do printf './\n' > "$TMP/ep/$r/.git/commondir"; done
EXTRA_MOUNTS="$TMP/ep" launch "$TMP/app"
k93="$(grep -A1 -F 'NOTE: /workspace/ep/r/.git was protected by an earlier launch that did not report it, and its config sets' "$ERR" | tail -1)"
h93="$(grep -A1 -F 'NOTE: /workspace/ep/r/.git was protected by an earlier launch that did not report it, and its hooks/' "$ERR" | tail -1)"
[[ "$LAUNCH_RC" == 0 && "$k93" == *core.sshcommand* && "$h93" == *pre-commit* ]] \
  && grep -qF "git config --file $TMP/ep/r/.git/config --list" "$ERR" && grep -qF "ls -l $TMP/ep/r/.git/hooks" "$ERR" \
  && pass "G93 a repository protected before the record existed gets its keys and hooks named" \
  || fail "G93 earlier-protected repository not reported (rc=$LAUNCH_RC; stderr: $(grep -A2 'NOTE' "$ERR" | tr '\n' ' '))"
! grep -qF 'NOTE: /workspace/ep/clean' "$ERR" && ! grep -qF 'sekrit93' "$ERR" && ! grep -q 'for the first time' "$ERR" \
  && pass "G93 nothing for a clean one, no value printed, and not called a first protection" \
  || fail "G93 extra output (stderr: $(grep -E 'NOTE: /workspace/ep/clean|sekrit|first time' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$TMP/ep" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'NOTE: /workspace/ep/r/.git' "$ERR" \
  && pass "G93 the next launch says nothing: it was reported" \
  || fail "G93 reported twice (rc=$LAUNCH_RC; stderr: $(grep -A1 'ep/r' "$ERR" | tr '\n' ' '))"
# The record names a git directory, not a path: one made again where a reported
# one was, placeholder and all, is reported again (by birth time where the
# filesystem reuses the inode).
rm -rf "$TMP/ep/r" && mkdir -p "$TMP/ep/r" && "${G[@]}" -C "$TMP/ep/r" init -q
"${G[@]}" -C "$TMP/ep/r" config core.sshCommand 'ssh -i other93'; printf './\n' > "$TMP/ep/r/.git/commondir"
EXTRA_MOUNTS="$TMP/ep" launch "$TMP/app"
grep -qF 'NOTE: /workspace/ep/r/.git was protected by an earlier launch that did not report it, and its config sets' "$ERR" \
  && pass "G93 a repository made again at a reported path is reported again" \
  || fail "G93 re-made repository not reported (rc=$LAUNCH_RC; stderr: $(grep -A1 NOTE "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/ep"

# ── G106: a commondir or hooks/ that is a link ───────────────────────────────
# git reads both through a link, so what they lead to cannot be checked. A
# hooks/ link is reported so, and the launch goes on (with a WARNING of its own).
# Two mutants that made _git_runs fail there ended the launch in silence, under
# set -e, and survived every test (GAP-2's slice 2; sandbox.sh: `_git_runs()`).
# A commondir link refuses the launch since GIT-62: git never makes one, and the
# agent can repoint it (G166); the rescan after a session still names one.
mkdir -p "$TMP/cl/r" && "${G[@]}" -C "$TMP/cl/r" init -q && printf './\n' > "$TMP/cl/target" \
  && ln -s "$TMP/cl/target" "$TMP/cl/r/.git/commondir" || { printf 'SCAFFOLD-FAILED: G106\n'; exit 1; }
EXTRA_MOUNTS="$TMP/cl" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $TMP/cl/r/.git/commondir is a symlink" "$ERR" \
  && pass "G106 a repository whose commondir is a link refuses the launch" \
  || fail "G106 linked commondir at launch (rc=$LAUNCH_RC; stderr: $(grep -A1 'cl/r' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$TMP/cl"
mkdir -p "$TMP/cl/h" "$TMP/cl/githooks" && "${G[@]}" -C "$TMP/cl/h" init -q && rm -rf "$TMP/cl/h/.git/hooks" \
  && ln -s ../../githooks "$TMP/cl/h/.git/hooks" || { printf 'SCAFFOLD-FAILED: G106 hooks\n'; exit 1; }
EXTRA_MOUNTS="$TMP/cl" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF 'hooks/, a link: what git runs through it is not checked' \
    < <(grep -A1 -F 'NOTE: /workspace/cl/h/.git is protected for the first time, and its hooks/' "$ERR") \
  && pass "G106 a repository whose hooks/ is a link is reported as not checked, and the launch goes on" \
  || fail "G106 linked hooks/ at launch (rc=$LAUNCH_RC; stderr: $(grep -A1 'cl/h' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$TMP/cl"

# ── G107: a git directory's identity: device, inode, birth time, link text ──
# A .git link repointed is another one by its target text, which matters where
# the filesystem keeps no birth time and hands the inode back. Where it keeps
# one, as the slice was measured on, G94's repointed link is told apart by its
# birth time alone, so two mutants that dropped the text (and gave it to a
# directory) survived every test; so did one in the BSD stat branch, which only
# a Mac runs (GAP-2's slice 2; sandbox.sh: `_git_ident()`). Checked on the function,
# the BSD branch with a stat that answers as BSD's does.
load_fn _git_ident
mkdir -p "$TMP/id107/d" "$TMP/id107/bin"; ln -s d "$TMP/id107/l"
cat > "$TMP/id107/bin/stat" <<'STAT'
#!/bin/sh
[ "$1" = -f ] && [ "$2" = '%d %i %.9FB' ] && [ "$3" = -- ] && { echo '7 8 9.000000001'; exit 0; }
exit 1
STAT
chmod +x "$TMP/id107/bin/stat"
# This host's own stat first, probed as sandbox.sh probes it.
if stat -c '%i' / >/dev/null 2>&1; then _launcher_stat_gnu=1; else _launcher_stat_gnu=0; fi
i107d="$(_git_ident "$TMP/id107/d")"; i107l="$(_git_ident "$TMP/id107/l")"
[[ -n "$i107d" && "$i107d" != '?'* && "$i107d" != *'->'* && "$i107l" == *' -> d' ]] \
  && pass "G107 a link's identity carries its target, a directory's does not" \
  || fail "G107 identities (directory: '$i107d'; link: '$i107l')"
_launcher_stat_gnu=0; i107b="$(PATH="$TMP/id107/bin:$PATH" _git_ident "$TMP/id107/d")"
[[ "$i107b" == '7 8 9.000000001' ]] \
  && pass "G107 with BSD's stat, the identity is what stat -f printed" \
  || fail "G107 BSD stat identity (got '$i107b')"
rm -rf "$TMP/id107"

# ── G108: the record of reported repositories is read as it is meant ───────
# Every line of it, an empty one and a last one without its newline included
# (a hand edit); and never through a link, as it is never written through one.
# Mutants that stopped at an empty line, or read or wrote the record through a
# link, or ended the launch when it could not be written, survived every test
# (GAP-2's slice 2; sandbox.sh: `_git_reported_load()`; sandbox.sh: `_git_report_record()`).
rec108="$HOME/.ai-containers/git-reported.conf"
mkdir -p "$TMP/rr/r" && "${G[@]}" -C "$TMP/rr/r" init -q && "${G[@]}" -C "$TMP/rr/r" config core.sshCommand 'ssh-108' \
  || { printf 'SCAFFOLD-FAILED: G108\n'; exit 1; }
EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
# The launch's doing, so a FAIL and not SCAFFOLD-FAILED, which the falsify tier
# scores as no verdict at all; the checks that build on it are then skipped.
if grep -qF 'NOTE: /workspace/rr/r/.git is protected for the first time' "$ERR" && [[ -s "$rec108" && ! -L "$rec108" ]]; then
  { printf '\n'; cat "$rec108"; } > "$rec108.new" && printf '%s' "$(cat "$rec108.new")" > "$rec108" && rm -f "$rec108.new"
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'NOTE: /workspace/rr/r/.git' "$ERR" \
    && pass "G108 a record with an empty line, and no newline after its last, is read whole" \
    || fail "G108 reported again (rc=$LAUNCH_RC; stderr: $(grep -A1 'rr/r' "$ERR" | head -2 | tr '\n' ' '))"
  # A repository recorded after such a last line goes on a line of its own:
  # joined to it, both would be named again at every launch.
  mkdir -p "$TMP/rr/s" && "${G[@]}" -C "$TMP/rr/s" init -q && "${G[@]}" -C "$TMP/rr/s" config core.sshCommand 'ssh-108' \
    || { printf 'SCAFFOLD-FAILED: G108 second repository\n'; exit 1; }
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'NOTE: /workspace/rr/(r|s)/\.git' "$ERR" \
    && pass "G108 a repository recorded after a last line with no newline goes on a line of its own" \
    || fail "G108 records joined (rc=$LAUNCH_RC; stderr: $(grep -E 'NOTE: /workspace/rr' "$ERR" | tr '\n' ' '))"
  mv "$rec108" "$TMP/rec108.real" && ln -s "$TMP/rec108.real" "$rec108"; was108="$(cat "$TMP/rec108.real")"
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF 'NOTE: /workspace/rr/r/.git was protected by an earlier launch that did not report it' "$ERR" \
    && pass "G108 a record that is a link is not read, and the launch goes on" \
    || fail "G108 the record was read through a link (rc=$LAUNCH_RC; stderr: $(grep -A1 'rr/r' "$ERR" | head -2 | tr '\n' ' '))"
  [[ "$(cat "$TMP/rec108.real")" == "$was108" ]] \
    && pass "G108 a record that is a link is not written through it" \
    || fail "G108 the record was written through a link"
  rm -f "$rec108"; mv "$TMP/rec108.real" "$rec108"
  # One that is a FIFO is neither read nor written: written, it blocked the
  # launch until something read it.
  mv "$rec108" "$TMP/rec108.real" && mkfifo "$rec108" && rm -rf "$TMP/rr" && mkdir -p "$TMP/rr/f" && "${G[@]}" -C "$TMP/rr/f" init -q \
    && "${G[@]}" -C "$TMP/rr/f" config core.sshCommand 'ssh-108' || { printf 'SCAFFOLD-FAILED: G108 FIFO\n'; exit 1; }
  EXTRA_MOUNTS="$TMP/rr" launch_timed 60 "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF 'NOTE: /workspace/rr/f/.git is protected for the first time' "$ERR" \
    && pass "G108 a record that is a FIFO is neither read nor written, and the launch goes on (${LAUNCH_S}s)" \
    || fail "G108 FIFO record (rc=$LAUNCH_RC; ${LAUNCH_S}s)"
  ( exec 3<>"$rec108" ) 2>/dev/null; rm -f "$rec108"; mv "$TMP/rec108.real" "$rec108"
  # A repository already in the record is protected for the first time again when
  # its placeholder is gone (removed on the host): it is named, and recording it
  # again changes nothing.
  rm -rf "$TMP/rr"; mkdir -p "$TMP/rr/p" && "${G[@]}" -C "$TMP/rr/p" init -q && "${G[@]}" -C "$TMP/rr/p" config core.sshCommand 'ssh-108' \
    || { printf 'SCAFFOLD-FAILED: G108 placeholder\n'; exit 1; }
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"; rm -f "$TMP/rr/p/.git/commondir"; n108="$(wc -l < "$rec108")"
  EXTRA_MOUNTS="$TMP/rr" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF 'NOTE: /workspace/rr/p/.git is protected for the first time' "$ERR" && [[ "$(wc -l < "$rec108")" == "$n108" ]] \
    && pass "G108 a recorded repository protected for the first time again is named, and recorded once" \
    || fail "G108 placeholder removed (rc=$LAUNCH_RC; lines $n108 -> $(wc -l < "$rec108"))"
else
  fail "G108 the first protection was not reported and recorded; the record's checks were skipped (rc=$LAUNCH_RC)"
fi
rm -rf "$TMP/rr"
# A path with a newline is recorded as `printf %q` writes it in the C locale
# ($'…'), which no physical path starts with, so a repository there is named
# once, as any other is (bugs review GIT-90): it was named at every launch. Its
# placeholder made beforehand, so the launch is no first protection and only
# the record decides: a mutant that took it for reported names nothing. The
# same in another locale, where %q spells é otherwise (review of the plan). Any
# other path is recorded as before, so older records stay valid.
nl109="$TMP/rn/a"$'\n'"é"
mkdir -p "$nl109" "$TMP/rn/s p" && "${G[@]}" -C "$nl109" init -q && "${G[@]}" -C "$nl109" config core.sshCommand 'ssh-109' \
  && printf './\n' > "$nl109/.git/commondir" && "${G[@]}" -C "$TMP/rn/s p" init -q \
  || { printf 'SCAFFOLD-FAILED: G109\n'; exit 1; }
LC_ALL=C.UTF-8 EXTRA_MOUNTS="$TMP/rn" launch "$TMP/app"
grep -qF 'core.sshcommand' < <(grep -A1 -F 'was protected by an earlier launch that did not report it, and its config sets' "$ERR") \
  && pass "G109 a repository at a path with a newline, never reported, is named" \
  || fail "G109 a newline path taken for reported (rc=$LAUNCH_RC; stderr: $(grep -A1 NOTE "$ERR" | head -2 | tr '\n' ' '))"
# Recorded in one locale and looked up in the other, both ways round: a second
# repository, made now, is recorded by the launch in C, and looked up in UTF-8.
nl109b="$TMP/rn/b"$'\n'"é"
mkdir -p "$nl109b" && "${G[@]}" -C "$nl109b" init -q && "${G[@]}" -C "$nl109b" config core.sshCommand 'ssh-109b' \
  && printf './\n' > "$nl109b/.git/commondir" || { printf 'SCAFFOLD-FAILED: G109 second\n'; exit 1; }
LC_ALL=C EXTRA_MOUNTS="$TMP/rn" launch "$TMP/app"
nb109="$(grep -c 'did not report it' "$ERR")"
[[ "$LAUNCH_RC" == 0 && "$nb109" == 1 ]] && grep -qF "/workspace/rn/b" < <(grep -F 'did not report it' "$ERR") \
  && pass "G109 … once: the next launch, in the C locale, names only the new one" \
  || fail "G109 named again in C (rc=$LAUNCH_RC; $nb109 NOTE(s): $(grep -F 'did not report it' "$ERR" | head -2 | tr '\n' ' '))"
LC_ALL=C.UTF-8 EXTRA_MOUNTS="$TMP/rn" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'did not report it' "$ERR" \
  && pass "G109 … and the launch after it, in UTF-8, names neither" \
  || fail "G109 named again in UTF-8 (rc=$LAUNCH_RC; stderr: $(grep -F 'did not report it' "$ERR" | head -2 | tr '\n' ' '))"
grep -qE " $TMP/rn/s p/\.git\$" "$HOME/.ai-containers/git-reported.conf" \
  && pass "G109 a path with no newline is recorded as before" \
  || fail "G109 a plain path recorded otherwise ($(grep -F 'rn/s' "$HOME/.ai-containers/git-reported.conf" | head -1))"
rm -rf "$TMP/rn"

# ── G94: a repository the session made is named when the container exits ───
# The scan runs at launch, so a git directory the agent makes during the session
# is protected only by the next launch — and the host's git would run what it
# holds before then. When the container exits, the writable mounts are scanned
# again, and every new git directory that makes git run something is named, as
# is every new .git file or link, which can send git anywhere. A plain `git
# init` or clone is not. The container's exit status is the launcher's.
mkdir -p "$TMP/ps/old" "$TMP/ps/rl" "$TMP/rl94a" "$TMP/rl94b" && "${G[@]}" -C "$TMP/ps/old" init -q \
  && printf 'x\n' > "$TMP/ps/old/f" && "${G[@]}" -C "$TMP/ps/old" add f && "${G[@]}" -C "$TMP/ps/old" commit -qm s \
  && "${G[@]}" -C "$TMP/rl94a" init -q && "${G[@]}" -C "$TMP/rl94b" init -q && ln -s "$TMP/rl94a/.git" "$TMP/ps/rl/.git" \
  || { printf 'SCAFFOLD-FAILED: G94\n'; exit 1; }
sess94="set -e; cd '$TMP/ps'
g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main \"\$@\"; }
mkdir hook cfg plain wt ln
g -C hook init -q; printf '#!/bin/sh\n' > hook/.git/hooks/post-checkout; chmod 755 hook/.git/hooks/post-checkout
g -C cfg init -q; g -C cfg config core.fsmonitor 'run-me-94'
g -C plain init -q
printf 'gitdir: /somewhere94\n' > wt/.git
ln -s '$TMP' ln/.git
printf '#!/bin/sh\n' > old/.git/hooks/pre-push; chmod 755 old/.git/hooks/pre-push
rm rl/.git; ln -s '$TMP/rl94b/.git' rl/.git
mkdir cdl; g -C cdl init -q; printf './\n' > cdl/.git/cd94; ln -s cd94 cdl/.git/commondir
mkdir hl; g -C hl init -q; mkdir hl/githooks; rm -rf hl/.git/hooks; ln -s ../githooks hl/.git/hooks
g init -q m94; g -C m94 commit -q --allow-empty -m s; g -C m94 worktree add -q ../w94
printf '#!/bin/sh\n' > m94/.git/hooks/post-merge; chmod 755 m94/.git/hooks/post-merge
g -C old update-index --add --cacheinfo 160000,0123456789abcdef0123456789abcdef01234567,vendor/x
mkdir -p old/vendor/x; g -C old/vendor/x init -q; g -C old/vendor/x config core.sshCommand 'ssh-94'"
FAKE_SESSION="$sess94" FAKE_DOCKER_RC=7 EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
w94="$(sed -n '/WARNING: the session made/,$p' "$ERR")"
[[ "$w94" == *"$TMP/ps/hook/.git"*post-checkout* && "$w94" == *"$TMP/ps/cfg/.git"*core.fsmonitor* ]] \
  && pass "G94 a repository made in the session with a hook or a key that runs a program is named on exit" \
  || fail "G94 new repositories not named (rc=$LAUNCH_RC; stderr: $(tail -12 "$ERR" | tr '\n' ' '))"
[[ "$w94" == *"$TMP/ps/wt/.git"* && "$w94" == *"$TMP/ps/ln/.git"* ]] \
  && pass "G94 a new .git file and a new .git link are named" \
  || fail "G94 .git file or link not named (warning: $(tr '\n' ' ' <<<"$w94"))"
# Each under its own WARNING: a repository's says what git would run, a .git
# file's or link's says where it leads. Three mutants that swapped the two
# survived every test (GAP-2's slice 2; sandbox.sh: `_git_after_session()`).
r94="$(sed -n '/WARNING: the session made git repositories/,/Review them on the host/p' "$ERR")"
a94="$(sed -n '/WARNING: the session made .git files or links/,/Check where each leads/p' "$ERR")"
[[ "$r94" == *"$TMP/ps/hook/.git"* && "$r94" != *"$TMP/ps/wt/.git"* && "$a94" == *"$TMP/ps/wt/.git"* && "$a94" != *"$TMP/ps/hook/.git"* ]] \
  && pass "G94 a new repository and a new .git file are named under their own WARNINGs" \
  || fail "G94 records under the wrong WARNING (repositories: $(tr '\n' ' ' <<<"$r94"); files: $(tr '\n' ' ' <<<"$a94"))"
[[ "$w94" == *"$TMP/ps/rl/.git"* ]] \
  && pass "G94 a .git link there at launch and repointed in the session is named" \
  || fail "G94 repointed .git link not named (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ "$w94" == *"$TMP/ps/hl/.git"*"hooks/, a link"* ]] \
  && pass "G94 a new repository whose hooks/ is a link is named" \
  || fail "G94 linked hooks/ not named (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ "$w94" == *"$TMP/ps/old/vendor/x/.git"*core.sshcommand* ]] \
  && pass "G94 a repository reached only through a gitlink added in the session is named (the index is read afresh)" \
  || fail "G94 gitlink added in the session not followed (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ "$w94" == *"$TMP/ps/cdl/.git"*commondir* ]] \
  && pass "G94 a new repository whose commondir is a link is named: what git reads through it is not checked" \
  || fail "G94 linked commondir not named (warning: $(tr '\n' ' ' <<<"$w94"))"
# Its commondir sends git to the common directory, not protected at launch, so
# its hooks are what git runs there. Eight mutants of how a commondir that is a
# file is read survived every test (GAP-2's slice 2; sandbox.sh: `_git_runs()`).
[[ "$w94" == *"$TMP/ps/m94/.git/worktrees/w94 (hooks: post-merge)"* ]] \
  && pass "G94 a linked worktree of a repository the session made is named with its common directory's hooks" \
  || fail "G94 new linked worktree not named with the common hooks (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ -n "$w94" && "$w94" != *ps/plain* && "$w94" != *"$TMP/ps/old/.git ("* && "$w94" != *run-me-94* ]] \
  && pass "G94 not a plain new repository, not one protected at launch, and no value" \
  || fail "G94 extra names (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ "$LAUNCH_RC" == 7 ]] && pass "G94 the container's exit status is the launcher's" \
  || fail "G94 exit status (rc=$LAUNCH_RC, want 7)"
rm -rf "$TMP/ps" "$TMP/rl94a" "$TMP/rl94b"; mkdir -p "$TMP/ps/old" && "${G[@]}" -C "$TMP/ps/old" init -q
FAKE_SESSION="cd '$TMP/ps' && git init -q plain" EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
# Nor that the search was cut short: two mutants that said so after every
# session survived every test (GAP-2's slice 2; sandbox.sh: `_git_after_session()`).
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'the session made' "$ERR" && ! grep -qF 'could not all be searched' "$ERR" \
  && pass "G94 a session that made only a plain repository says nothing" \
  || fail "G94 noise for a plain repository (rc=$LAUNCH_RC; stderr: $(tail -5 "$ERR" | tr '\n' ' '))"
# A git directory the session left unlistable is named as not checked: one that
# can be read but not searched hides what is inside as well as one that can be
# neither. A mutant that named only the second survived every test (GAP-2's slice 2;
# sandbox.sh: `_git_after_session()`). Not as root, which can search any directory.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$TMP/pu"
  FAKE_SESSION="cd '$TMP/pu' && git init -q un && chmod 600 un/.git" EXTRA_MOUNTS="$TMP/pu" launch "$TMP/app"
  chmod 700 "$TMP/pu/un/.git" 2>/dev/null
  grep -qF "$TMP/pu/un/.git (cannot be listed, so it was not checked)" "$ERR" \
    && pass "G94 a git directory the session made that cannot be searched is named as not checked" \
    || fail "G94 an unsearchable new git directory (stderr: $(tail -6 "$ERR" | tr '\n' ' '))"
  rm -rf "$TMP/pu"
else
  printf 'SKIP: G94 an unsearchable new git directory: root can search any directory\n'
fi
# A search that stops past SANDBOX_GIT_MAX says so, and is not a refusal: the
# launcher exits with the container's status.
FAKE_SESSION="cd '$TMP/ps' && for i in 1 2 3 4 5 6; do git init -q p\$i; done" FAKE_DOCKER_RC=3 \
  SANDBOX_GIT_MAX=3 EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
[[ "$LAUNCH_RC" == 3 ]] && grep -qF 'could not all be searched for git repositories the session' "$ERR" \
  && pass "G94 a search cut short at SANDBOX_GIT_MAX says so, and the exit status is still the container's" \
  || fail "G94 cut-short search (rc=$LAUNCH_RC; stderr: $(tail -4 "$ERR" | tr '\n' ' '))"
# A refusal inside the scan (more than twenty .git files naming one git
# directory, which git_dirs_in refuses by exiting) cuts the search short, and
# says so; and a scan past its time limit does too.
rm -rf "$TMP/ps"; mkdir -p "$TMP/ps" || { printf 'SCAFFOLD-FAILED: G94b\n'; exit 1; }
sess94b="set -e; cd '$TMP/ps'
g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main \"\$@\"; }
g init -q m; g -C m commit -q --allow-empty -m s; g -C m worktree add -q ../w
wt=\$(ls -d m/.git/worktrees/* | head -1); wt=\$(cd \"\$wt\" && pwd -P)
for n in \$(seq 1 21); do mkdir -p dec/d\$n; printf 'gitdir: %s\n' \"\$wt\" > dec/d\$n/.git; done"
FAKE_SESSION="$sess94b" FAKE_DOCKER_RC=5 EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
[[ "$LAUNCH_RC" == 5 ]] && grep -qF 'could not all be searched for git repositories the session' "$ERR" \
  && pass "G94 a scan that refuses by exiting is said to have cut the search short, and the exit status is kept" \
  || fail "G94 refusal in the rescan (rc=$LAUNCH_RC; stderr: $(tail -4 "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/ps"; mkdir -p "$TMP/ps"
FAKE_SESSION="cd '$TMP/ps' && git init -q h && printf '#!/bin/sh\n' > h/.git/hooks/pre-commit && chmod 755 h/.git/hooks/pre-commit" \
  AI_CONTAINERS_RESCAN_SECONDS=0 EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF 'could not all be searched for git repositories the session' "$ERR" \
  && pass "G94 a rescan past its time limit says the search was cut short" \
  || fail "G94 rescan deadline (rc=$LAUNCH_RC; stderr: $(tail -4 "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/ps"

# ── G127 (GIT-41): where names are compared case-sensitively, the container
# cannot write a read-only git file under another spelling, so a change while
# it ran is the host's own (git push -u, git remote add), and is kept. Where
# TMPDIR ignores case (macOS), test-git-internals-ro-casefold.sh has the cases.
mkdir "$TMP/Cs121" && if [[ ! -d "$TMP/CS121" ]]; then
  FAKE_SESSION="git config --file '$PROJ/.git/config' branch.main.remote origin" launch ..
  [[ "$LAUNCH_RC" == 0 && "$(git config --file "$PROJ/.git/config" branch.main.remote)" == origin ]] \
    && [[ -z "$(find "$PROJ/.git" -maxdepth 1 -name 'config.changed-*')" ]] && ! grep -qF 'changed while the container ran' "$ERR" \
    && pass "G127 a config changed on the host while the container ran is kept where names are case-sensitive" \
    || fail "G127 case-sensitive host change (rc=$LAUNCH_RC; stderr: $(grep -F 'container ran' "$ERR" | head -1))"
  git config --file "$PROJ/.git/config" --unset branch.main.remote
fi
rmdir "$TMP/Cs121"

# ── G229: a slow config does not hide what the session made ──────────────────
# The check after a session reads a new repository's index for its object
# format from its config. A read of that config cut off at the rescan's 2 s
# bound is taken for no answer, sha1, and the index is read all the same: an
# embedded repository it records under vendor/, which the rescan does not walk,
# is named, its config setting core.fsmonitor (GAP-2's whole-file run, batch 3,
# item 8).
REAL_GIT229="$(command -v git)"; mkdir -p "$TMP/sg229"
cat > "$TMP/sg229/git" <<'SLOWGIT'
#!/usr/bin/env bash
if [[ "${1:-}" == config && "${2:-}" == --file && "${3:-}" == "$SLOW229_CFG" && "${4:-}" == extensions.objectformat ]]; then sleep 4; fi
exec "$SLOW229_GIT" "$@"
SLOWGIT
chmod +x "$TMP/sg229/git"
S229="$PROJ/s229"; g229='git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main'
sess229="$g229 init -q '$S229' && $g229 init -q '$S229/vendor/e' && $g229 -C '$S229/vendor/e' commit -q --allow-empty -m e"
sess229+=" && $g229 -C '$S229/vendor/e' config core.fsmonitor ./fsm && $g229 -C '$S229' add vendor/e 2>/dev/null"
SLOW229_CFG="$S229/.git/config" SLOW229_GIT="$REAL_GIT229" PATH="$TMP/sg229:$PATH" FAKE_SESSION="$sess229" launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF 'WARNING: the writable mounts could not all be searched' "$ERR" \
  && grep -qF "$S229/vendor/e/.git (config: core.fsmonitor" < <(grep -A6 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G229 a repository the session's new index records is named, though its config was slow to read" \
  || fail "G229 slow config in the rescan (rc=$LAUNCH_RC; $(grep -A6 -F 'WARNING: the session' "$ERR" | tr '\n' ' '))"
rm -rf "$S229" "$TMP/sg229"

# ── G330: a rebase the session leaves stopped, its todo holding exec lines ───
# A rebase's todo is a file under .git that stays writable, and `git rebase
# --continue` on the host runs each `exec` line of it; `git status` shows the
# next two lines only. A session that left a rebase stopped, an exec placed
# third, had the host run it, and nothing named it (feature-gaps review
# GAP-15). Named when the container exits, and by the next launch while it is
# still stopped; a stopped rebase with no exec line is not.
D330="$TMP/d330"; R330="$D330/r"
mkdir -p "$D330" && "${G[@]}" init -q "$R330" && for i330 in 1 2 3 4; do
  printf '%s\n' "$i330" > "$R330/f$i330" && "${G[@]}" -C "$R330" add "f$i330" && "${G[@]}" -C "$R330" commit -qm "c$i330" || exit 1
done || { printf 'SCAFFOLD-FAILED: G330\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
! grep -qF 'is stopped in these git directories' "$ERR" && pass "G330 no rebase, nothing said" \
  || fail "G330 a false warning ($(grep -F 'is stopped in these git directories' "$ERR" | head -1))"
# A real rebase, stopped by an exec that fails, and a line added third, as an
# agent would add one: git's own state, not a file made to look like it.
export R330 T330="$TMP"
FAKE_SESSION='cd "$R330" && git -c user.email=t@example.invalid -c user.name=t rebase -q -x false HEAD~3 >/dev/null 2>&1; printf "exec echo RAN > %s/ran330\n" "$T330" >> "$R330/.git/rebase-merge/git-rebase-todo"' \
  EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ -f "$R330/.git/rebase-merge/git-rebase-todo" ]] || { printf 'SCAFFOLD-FAILED: G330 the rebase did not stop with a todo\n'; exit 1; }
n330="$(grep -a -c -E $'^[ \t]*(exec|x)([ \t\r]|$)' "$R330/.git/rebase-merge/git-rebase-todo")"
w330="$(grep -A5 -F 'WARNING: a rebase, a cherry-pick or a git am is stopped in these git directories now that the container has exited.' "$ERR")"
[[ "$n330" -ge 2 ]] && grep -qF "$R330/.git (rebase-merge/git-rebase-todo: $n330 exec lines)" <<<"$w330" \
  && grep -qF 'Continuing it on your host (git rebase --continue, git am --continue) acts on what its' <<<"$w330" \
  && pass "G330 a rebase the session left stopped is named on exit, with its exec lines counted ($n330)" \
  || fail "G330 not named on exit (exec lines: $n330; stderr: $(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# The next launch says it too, while the rebase is still stopped.
FAKE_SESSION='' EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'a git am is stopped in these git directories.' "$ERR")" == 1 ]] \
  && grep -qF "$R330/.git (rebase-merge/git-rebase-todo: $n330 exec lines)" "$ERR" \
  && pass "G330 the next launch names it as well" \
  || fail "G330 not named at launch ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# One line, an x after blanks and before a CR, is one; a word that only starts
# so (exclude, xargs) and a comment are none.
printf 'pick 1234567 a\n \tx\r\n#exec no\nexecute no\nxargs no\npick 89abcde b\n' > "$R330/.git/rebase-merge/git-rebase-todo"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (rebase-merge/git-rebase-todo: 1 exec line)" "$ERR" \
  && pass "G330 lines are counted as git reads them" \
  || fail "G330 counting ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# No exec line: a stopped rebase runs nothing of the agent's when continued.
printf 'pick 1234567 a\npick 89abcde b\n' > "$R330/.git/rebase-merge/git-rebase-todo"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
! grep -qF 'is stopped in these git directories' "$ERR" && pass "G330 a stopped rebase with no exec line is not named" \
  || fail "G330 named with no exec line ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# A todo that is a link is not read through, and is named as not read.
printf 'exec true\n' > "$D330/elsewhere" && rm -f "$R330/.git/rebase-merge/git-rebase-todo" \
  && ln -s "$D330/elsewhere" "$R330/.git/rebase-merge/git-rebase-todo" || { printf 'SCAFFOLD-FAILED: G330 link\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (rebase-merge/git-rebase-todo, a link or no regular file: not read)" "$ERR" \
  && pass "G330 a todo that is a link is named as not read" \
  || fail "G330 a linked todo ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# The merge strategy is run too: one that is not git's own is the program
# git-merge-<name>, and a name with a / in it is a path from the checkout.
# `../../x` beside a directory named git-merge-.. ran ./x at `git rebase
# --continue`, with no exec line (measured with git 2.53 while fixing GAP-15).
rm -f "$R330/.git/rebase-merge/git-rebase-todo" && printf 'pick 1234567 a\n' > "$R330/.git/rebase-merge/git-rebase-todo" \
  && printf '../../x\n' > "$R330/.git/rebase-merge/strategy" || { printf 'SCAFFOLD-FAILED: G330 strategy\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (rebase-merge/strategy: a merge strategy that is not git's own, which git runs as a program)" "$ERR" \
  && pass "G330 a stopped rebase whose strategy is not git's own is named" \
  || fail "G330 the strategy ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
ok330=1
for s330 in ort recursive resolve octopus ours subtree; do
  printf '%s\n' "$s330" > "$R330/.git/rebase-merge/strategy"
  EXTRA_MOUNTS="$D330" launch "$TMP/app"
  ! grep -qF 'is stopped in these git directories' "$ERR" || { ok330=""; printf '  named for %s\n' "$s330"; }
done
[[ -n "$ok330" ]] && pass "G330 git's own strategies are not named" || fail "G330 git's own strategies"
# A cherry-pick's or a revert's is among its options (sequencer/opts).
rm -rf "$R330/.git/rebase-merge" && mkdir "$R330/.git/sequencer" && printf 'pick 1234567 a\n' > "$R330/.git/sequencer/todo" \
  && printf '[options]\n\tstrategy = ../../x\n' > "$R330/.git/sequencer/opts" || { printf 'SCAFFOLD-FAILED: G330 sequencer\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (sequencer/opts: a merge strategy that is not git's own, which git runs as a program)" "$ERR" \
  && pass "G330 a stopped cherry-pick whose strategy is not git's own is named" \
  || fail "G330 sequencer/opts ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
printf '[options]\n\tstrategy = ort\n\tmainline = 1\n' > "$R330/.git/sequencer/opts"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
! grep -qF 'is stopped in these git directories' "$ERR" && pass "G330 a stopped cherry-pick with git's own strategy is not named" \
  || fail "G330 sequencer/opts with ort ($(grep -A6 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# A git am's saved options go to git apply as they are: `--build-fake-ancestor`
# there had `git am --continue` write an index over the file it names (review
# of the GAP-15 fix, A2; measured, git 2.53). Anything but the options that
# only say how a patch is matched is named; those, as git am writes them, are
# not.
rm -rf "$R330/.git/sequencer" && mkdir "$R330/.git/rebase-apply" \
  && printf " '--build-fake-ancestor=%s/clobbered'\n" "$D330" > "$R330/.git/rebase-apply/apply-opt" || { printf 'SCAFFOLD-FAILED: G330 am\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (rebase-apply/apply-opt: options for git apply that are not known to write nothing)" "$ERR" \
  && pass "G330 a stopped git am whose saved options could write a file is named" \
  || fail "G330 apply-opt ($(grep -A7 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
# --reject writes .rej files, so it is none of those (re-review, C6).
printf " '--whitespace=fix' '--reject'\n" > "$R330/.git/rebase-apply/apply-opt"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
grep -qF "$R330/.git (rebase-apply/apply-opt: options for git apply that are not known to write nothing)" "$ERR" \
  && pass "G330 a stopped git am with --reject, which writes files, is named" \
  || fail "G330 --reject not named"
printf " '--whitespace=fix' '-C1' '-p2' '--ignore-whitespace' '--ignore-space-change'\n" > "$R330/.git/rebase-apply/apply-opt"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
! grep -qF 'is stopped in these git directories' "$ERR" && pass "G330 a stopped git am with options that only match a patch is not named" \
  || fail "G330 harmless apply-opt named ($(grep -A7 -F 'is stopped in these git directories' "$ERR" | tr '\n' ' '))"
: > "$R330/.git/rebase-apply/apply-opt"
EXTRA_MOUNTS="$D330" launch "$TMP/app"
! grep -qF 'is stopped in these git directories' "$ERR" && pass "G330 …nor one with none" \
  || fail "G330 empty apply-opt named"
rm -rf "$R330/.git/rebase-apply"
# Your own rebase, stopped with exec lines, is said once a launch, when the
# agent gets to write its todo; when the container exits it is said again only
# if what it would run has changed, a line swapped for another included
# (review of the GAP-15 fix, A3).
mkdir "$R330/.git/rebase-merge" && printf 'pick 1234567 a\nexec make test\npick 89abcde b\nexec make test\n' > "$R330/.git/rebase-merge/git-rebase-todo" \
  || { printf 'SCAFFOLD-FAILED: G330 own\n'; exit 1; }
EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'is stopped in these git directories' "$ERR")" == 1 ]] && grep -qF 'a git am is stopped in these git directories.' "$ERR" \
  && pass "G330 a rebase stopped before the launch, and left as it was, is named once" \
  || fail "G330 named $(grep -cF 'is stopped in these git directories' "$ERR") times for a rebase the session left alone"
FAKE_SESSION='printf "pick 1234567 a\nexec make test\npick 89abcde b\nexec ./evil\n" > "$R330/.git/rebase-merge/git-rebase-todo"' \
  EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'is stopped in these git directories' "$ERR")" == 2 ]] \
  && grep -qF 'is stopped in these git directories now that the container has exited.' "$ERR" \
  && pass "G330 …and again on exit when the session swapped one exec line for another" \
  || fail "G330 a changed todo with the same count ($(grep -cF 'is stopped in these git directories' "$ERR") warnings)"
# By what the todo holds, not by a CRC: a todo with one exec line swapped and
# four bytes of its comment adjusted has the cksum and the length of the one
# the launch saw, and was taken for unchanged (re-review of the fix, C2).
printf 'pick 1234567 a\nexec make test\npick 89abcde b\nexec make test\n# pad: AAAA\n' > "$R330/.git/rebase-merge/git-rebase-todo"
printf 'pick 1234567 a\nexec make test\npick 89abcde b\nexec ./evil   \n# pad: \117\163\320\215\n' > "$TMP/forged330"
if command -v cksum >/dev/null 2>&1; then
  [[ "$(cksum < "$TMP/forged330")" == "$(cksum < "$R330/.git/rebase-merge/git-rebase-todo")" ]] \
    || { printf 'SCAFFOLD-FAILED: G330 the forged todo has another cksum\n'; exit 1; }
fi
export F330="$TMP/forged330"
FAKE_SESSION='cat "$F330" > "$R330/.git/rebase-merge/git-rebase-todo"' EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'is stopped in these git directories' "$ERR")" == 2 ]] \
  && pass "G330 a todo forged to the same cksum and length is still named on exit" \
  || fail "G330 a forged todo passed for unchanged ($(grep -cF 'is stopped in these git directories' "$ERR") warnings)"
# A digest that cannot be taken is no proof of anything: the rebase is named
# again on exit, the session having done nothing.
mkdir -p "$TMP/bin330" && printf '#!/bin/sh\nexit 127\n' > "$TMP/bin330/sha256sum" && cp "$TMP/bin330/sha256sum" "$TMP/bin330/shasum" \
  && chmod +x "$TMP/bin330/sha256sum" "$TMP/bin330/shasum" || { printf 'SCAFFOLD-FAILED: G330 digest shim\n'; exit 1; }
PATH="$TMP/bin330:$PATH" EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'is stopped in these git directories' "$ERR")" == 2 ]] \
  && pass "G330 where no digest can be taken, an unchanged rebase is named again rather than trusted" \
  || fail "G330 no digest, and taken for unchanged ($(grep -cF 'is stopped in these git directories' "$ERR") warnings)"
# The strategy counts as the todo does: another one that is not git's own gets
# the same words, and is named on exit all the same.
printf 'pick 1234567 a\n' > "$R330/.git/rebase-merge/git-rebase-todo" && printf 'mine\n' > "$R330/.git/rebase-merge/strategy"
FAKE_SESSION='printf "../../x\n" > "$R330/.git/rebase-merge/strategy"' EXTRA_MOUNTS="$D330" launch "$TMP/app"
[[ "$(grep -cF 'is stopped in these git directories' "$ERR")" == 2 ]] \
  && pass "G330 a strategy swapped for another that is not git's own is named on exit" \
  || fail "G330 a swapped strategy ($(grep -cF 'is stopped in these git directories' "$ERR") warnings)"
rm -rf "$D330" "$TMP/bin330" "$TMP/forged330"

# ── G332: an alias that is no shell command is named too ───────────────────
# `alias.st = rebase --exec ./x` has no `!`, and `git st` on the host runs ./x
# from the checkout; a repository's alias is used over one of the same name in
# your own config (measured, git 2.53). So every alias is named with the keys
# that run programs, as what it is and after the ones that run one for certain;
# and a repository an earlier engine reported, which named none of them, has
# them named once (`al:` in the record of reported repositories;
# sandbox.sh: `_git_alias_once()`).
rec332="$HOME/.ai-containers/git-reported.conf"
D332="$TMP/al332"; O332="$TMP/ov332"
pa332='(a git command, which may run one itself)'
# G107 left the BSD branch chosen for _git_ident; this host's own again.
load_fn _git_ident
if stat -c '%i' / >/dev/null 2>&1; then _launcher_stat_gnu=1; else _launcher_stat_gnu=0; fi
fp332() {   # <repository under /workspace/al332>: the keys its first protection named
  grep -A1 -F "NOTE: /workspace/al332/$1/.git is protected for the first time, and its config" "$ERR" | tail -1
}
al332() {   # <git directory under /workspace>: the aliases named for one reported before
  grep -A1 -F "NOTE: /workspace/$1 was reported by an earlier launch, which named no alias but a shell" "$ERR" | tail -1
}
# The record as an engine before this one left it.
unal332() { grep -v ' al:' "$rec332" > "$rec332.n"; mv "$rec332.n" "$rec332"; }
mkdir -p "$D332" "$O332/l" && : > "$O332/l/sandbox.sh" && : > "$O332/l/sandbox-common.sh" \
  && for r in only many both none wtc late m; do "${G[@]}" init -q "$D332/$r" || exit 1; done \
  && "${G[@]}" init -q "$O332/l/r" && "${G[@]}" -C "$O332/l/r" config alias.ov log \
  && "${G[@]}" -C "$D332/only" config alias.st 'rebase --exec ./x' \
  && for i in 1 2 3 4 5 6 7 8 9 10 11; do "${G[@]}" -C "$D332/many" config "alias.p$i" log || exit 1; done \
  && "${G[@]}" -C "$D332/many" config core.sshCommand 'ssh-332' \
  && printf '[alias]\n\tb = status\n\tb = !./x\n\tsh = !./y\n\tco = checkout\n\tco = switch\n' >> "$D332/both/.git/config" \
  && "${G[@]}" -C "$D332/wtc" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$D332/wtc" config --worktree filter.x.smudge x-smudge \
  && "${G[@]}" -C "$D332/wtc" config --worktree alias.wa log \
  && "${G[@]}" -C "$D332/m" commit -q --allow-empty -m i && "${G[@]}" -C "$D332/m" worktree add -q "$D332/w332" \
  && printf '[alias]\n\tzz = log\n' > "$D332/m/.git/worktrees/w332/config" \
  || { printf 'SCAFFOLD-FAILED: G332\n'; exit 1; }
EXTRA_MOUNTS="$D332 $O332" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(fp332 only)" == *"programs: alias.st $pa332." ]] \
  && pass "G332 a repository whose config sets only an alias that is no shell command has it named, as what it is" \
  || fail "G332 a plain alias alone (rc=$LAUNCH_RC; got: $(fp332 only))"
[[ "$(fp332 many)" == *"programs: core.sshcommand, alias.p1 $pa332, "*"alias.p9 $pa332, and 2 more." ]] \
  && pass "G332 eleven such aliases set before a key that runs a program do not push it out of the ten shown" \
  || fail "G332 the key after eleven aliases (got: $(fp332 many))"
[[ "$(fp332 both)" == *"programs: alias.b, alias.sh, alias.co $pa332." ]] \
  && pass "G332 an alias set both ways is named once, as the shell command git takes it for, and one set twice once" \
  || fail "G332 an alias set both ways, or twice (got: $(fp332 both))"
[[ "$(grep -A1 -F 'NOTE: /workspace/ov332/l/r/.git lies under a read-only overlay and was not reported before, and its config' "$ERR" | tail -1)" == *"alias.ov $pa332." ]] \
  && pass "G332 one under a read-only overlay has its alias named by the launch that first sees it" \
  || fail "G332 an alias under an overlay (stderr: $(grep -A1 -F 'ov332/l/r' "$ERR" | head -3 | tr '\n' ' '))"
# What the first report named is not named again as left over by an earlier
# engine, and a linked worktree's directory reads no config of its own: one
# planted there is not git's.
! grep -qF 'which named no alias but a shell' "$ERR" && ! grep -qF 'alias.zz' "$ERR" \
  && grep -qxF "$(_git_ident "$D332/none/.git") al:$D332/none/.git" "$rec332" \
  && grep -qxF "$(_git_ident "$D332/only/.git") al:$D332/only/.git" "$rec332" \
  && pass "G332 a first report records that the aliases were named, and names none twice" \
  || fail "G332 the first report and the record (stderr: $(grep -A1 -F 'named no alias' "$ERR" | head -4 | tr '\n' ' '); record: $(grep -c ' al:' "$rec332") al lines)"
EXTRA_MOUNTS="$D332 $O332" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'which may run one itself|named no alias|protected for the first time' "$ERR" \
  && pass "G332 the next launch names no alias again" \
  || fail "G332 aliases named twice (rc=$LAUNCH_RC; stderr: $(grep -E 'run one itself|named no alias|first time' "$ERR" | head -3 | tr '\n' ' '))"
# A record an earlier engine left: no `al:` line. And a config.worktree a
# container of such an engine wrote into after the launch that made it.
unal332; printf '[alias]\n\tlate = log\n' >> "$D332/late/.git/config.worktree"
EXTRA_MOUNTS="$D332 $O332" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(al332 al332/only/.git)" == *"Its config sets: alias.st $pa332." ]] \
  && grep -qF "git config --file $D332/only/.git/config --get-regexp '^alias\\.'" "$ERR" \
  && pass "G332 a repository an earlier engine reported has its aliases named once, with the command that shows them" \
  || fail "G332 aliases of one reported before (rc=$LAUNCH_RC; got: $(al332 al332/only/.git); stderr: $(grep -F -- '--get-regexp' "$ERR" | head -2 | tr '\n' ' '))"
[[ "$(al332 al332/both/.git)" == *"Its config sets: alias.co $pa332." && "$(al332 al332/many/.git)" == *"alias.p10 $pa332, and 1 more." ]] \
  && pass "G332 … only those: a shell command was named before; ten at most, and a count" \
  || fail "G332 what is named for one reported before (both: $(al332 al332/both/.git); many: $(al332 al332/many/.git))"
[[ "$(al332 al332/wtc/.git)" == *"Its config sets: alias.wa $pa332." ]] \
  && grep -qF "git config --file $D332/wtc/.git/config.worktree --get-regexp '^alias\\.'" "$ERR" \
  && pass "G332 … those of a config.worktree whose keys a launch has named, too" \
  || fail "G332 a named config.worktree's alias (got: $(al332 al332/wtc/.git))"
[[ "$(al332 ov332/l/r/.git)" == *"Its config sets: alias.ov $pa332." ]] \
  && pass "G332 … and those of one under a read-only overlay" \
  || fail "G332 an overlay repository reported before (got: $(al332 ov332/l/r/.git))"
[[ "$(grep -A1 -F 'NOTE: /workspace/al332/late/.git/config.worktree, which no launch has named before, sets' "$ERR" | tail -1)" == *"programs: alias.late $pa332." \
   && "$(grep -cF 'alias.late' "$ERR")" == 1 ]] \
  && ! grep -qF 'NOTE: /workspace/al332/none/.git' "$ERR" && ! grep -qF 'alias.zz' "$ERR" \
  && grep -qxF "$(_git_ident "$D332/none/.git") al:$D332/none/.git" "$rec332" \
  && pass "G332 an alias written into a config.worktree no launch has named is named with that file, once; a repository with none is recorded and not named" \
  || fail "G332 a later config.worktree alias, or one with none (late: $(grep -cF 'alias.late' "$ERR") times; stderr: $(grep -F 'al332/none' "$ERR" | head -2 | tr '\n' ' '))"
EXTRA_MOUNTS="$D332 $O332" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'which may run one itself|named no alias' "$ERR" \
  && pass "G332 and once only: the launch after says nothing of them" \
  || fail "G332 aliases of one reported before named twice (stderr: $(grep -E 'run one itself|named no alias' "$ERR" | head -3 | tr '\n' ' '))"
# Where git does not run nothing is read, so nothing is recorded as named: the
# next launch with git names them. A PATH with no git, as G98 builds one.
nogit332=""; i332=0
IFS=: read -r -a pd332 <<<"$PATH"
for d332 in "${pd332[@]}"; do
  if [[ -n "$d332" && -x "$d332/git" && ! -d "$d332/git" ]]; then
    i332=$((i332 + 1)); m332="$TMP/nogit332/$i332"; mkdir -p "$m332"
    ln -s "$d332"/* "$m332"/ 2>/dev/null; rm -f "$m332/git"
    d332="$m332"
  fi
  nogit332="${nogit332:+$nogit332:}$d332"
done
PATH="$nogit332" "$BASH" -c 'command -v git' >/dev/null 2>&1 \
  && { printf 'SCAFFOLD-FAILED: G332 git is still on the no-git PATH\n'; exit 1; }
unal332
EXTRA_MOUNTS="$D332" PATH="$nogit332" launch "$TMP/app"
n332="$(grep -c ' al:' "$rec332")"
EXTRA_MOUNTS="$D332" launch "$TMP/app"
[[ "$n332" == 0 && "$(al332 al332/only/.git)" == *"Its config sets: alias.st $pa332." ]] \
  && pass "G332 where git does not run nothing is recorded as named, and the next launch with git names them" \
  || fail "G332 with no git ($n332 al lines recorded; then: $(al332 al332/only/.git))"
# The check after the session: a repository the session made whose config sets
# such an alias is named; a plain git init is not.
mkdir -p "$TMP/ps332"
FAKE_SESSION="set -e; cd '$TMP/ps332'
git -c init.defaultBranch=main init -q pa; git -C pa config alias.st 'rebase --exec ./x'
git -c init.defaultBranch=main init -q plain" EXTRA_MOUNTS="$TMP/ps332" launch "$TMP/app"
w332="$(sed -n '/WARNING: the session made/,$p' "$ERR")"
[[ "$w332" == *"$TMP/ps332/pa/.git"*"alias.st $pa332"* && "$w332" != *"$TMP/ps332/plain/.git"* ]] \
  && pass "G332 a repository the session made with such an alias is named on exit, a plain git init is not" \
  || fail "G332 after the session (rc=$LAUNCH_RC; stderr: $(tail -8 "$ERR" | tr '\n' ' '))"
chmod -R u+rwX "$D332" "$O332" "$TMP/ps332" 2>/dev/null; rm -rf "$D332" "$O332" "$TMP/ps332" "$TMP/nogit332"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
