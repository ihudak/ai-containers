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
  && pass "G26 a plain alias, and git's own fsmonitor daemon, are not named" \
  || fail "G26 benign keys named (got: $nl26; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
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
mkdir -p "$TMP/fh/h" "$TMP/fh/hp" "$TMP/fh/none" "$TMP/fh/wtp"
for r in h hp none wtp; do "${G[@]}" -C "$TMP/fh/$r" init -q; done
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
! grep -qE 'fh/(hp|wtp|none)/\.git is protected for the first time, and its hooks/' "$ERR" \
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
[[ -n "$w94" && "$w94" != *ps/plain* && "$w94" != *"$TMP/ps/old/.git ("* && "$w94" != *run-me-94* ]] \
  && pass "G94 not a plain new repository, not one protected at launch, and no value" \
  || fail "G94 extra names (warning: $(tr '\n' ' ' <<<"$w94"))"
[[ "$LAUNCH_RC" == 7 ]] && pass "G94 the container's exit status is the launcher's" \
  || fail "G94 exit status (rc=$LAUNCH_RC, want 7)"
rm -rf "$TMP/ps" "$TMP/rl94a" "$TMP/rl94b"; mkdir -p "$TMP/ps/old" && "${G[@]}" -C "$TMP/ps/old" init -q
FAKE_SESSION="cd '$TMP/ps' && git init -q plain" EXTRA_MOUNTS="$TMP/ps" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'the session made' "$ERR" \
  && pass "G94 a session that made only a plain repository says nothing" \
  || fail "G94 noise for a plain repository (rc=$LAUNCH_RC; stderr: $(tail -5 "$ERR" | tr '\n' ' '))"
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
