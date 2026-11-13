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
[[ "$nl26" != *alias.st* ]] && ! grep -q 'fp/clean/.git is protected for the first time, and its config' "$ERR" \
  && pass "G26 a plain alias, git's own fsmonitor daemon, and an SMTP server given as a host name are not named" \
  || fail "G26 benign keys named (got: $nl26; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
