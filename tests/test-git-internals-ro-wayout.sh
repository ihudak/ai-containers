#!/usr/bin/env bash
# tests/test-git-internals-ro-wayout.sh — what a refusal over a commondir tells
# you to do, and that doing it is safe (bugs review GIT-70).
#
# A refusal used to print one `rm`, chosen from what the directory held, which
# the agent writes: following it removed the ../.. git wrote in a linked
# worktree's directory, and git then read the config the agent had planted
# beside it. The advice is now built from a few fixed parts, chosen by where
# the directory lies and by which check failed, never by what it holds
# (sandbox.sh: _cd_way_out()). The checks here: which parts each place gets;
# that the text is the same whatever the directory holds; and that running the
# printed command, then launching again, ends in a launch that starts with the
# host's git running nothing of the agent's and every repository as it was.
#
# One of the tests/test-git-internals-ro-*.sh files, which share
# tests/lib-git-internals-ro.sh. Hermetic: a fake docker, real git repositories.
# shellcheck source=tests/lib-git-internals-ro.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-git-internals-ro.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-git-internals-ro.sh\n'; exit 1; }

gi_warm_up

has() { grep -qF -- "$1" "$ERR"; }
# The two commands, exactly as printed for directory $1.
k_cmd() { printf '         (cd -P -- %s && [ "$(pwd -P)" = %s ] && [ . -ef %s ] && rm -rf commondir && (set -C; printf '\''../..\\n'\'' > commondir))' "$1" "$1" "$1"; }
r_cmd() { printf '         (cd -P -- %s && [ "$(pwd -P)" = %s ] && [ . -ef %s ] && rm commondir)' "$1" "$1" "$1"; }
# Nothing a refusal here may ever print: the old `(rm <path>)`, a recursive
# removal of anything but the commondir a command has entered the directory of,
# and a removal of a commondir in a worktrees/<name> place that does not write
# ../.. back.
clean() {
  local l
  ! grep -qE '\(rm [^)]*\)' "$ERR" || return 1
  l="$(grep -F 'rm -r' "$ERR" | grep -vF '&& rm -rf commondir && (set -C; printf' || true)"; [[ -z "$l" ]] || return 1
  l="$(grep -E '/worktrees/[^/ ]+ \] && rm commondir\)' "$ERR" | grep -v '/\.git \] && rm commondir)' || true)"; [[ -z "$l" ]] || return 1
  ! grep -qF 'remove it on the host.' "$ERR"
}
refused() { [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]]; }
why() { printf 'rc=%s; %s' "$LAUNCH_RC" "$(grep -A7 -m1 ERROR "$ERR" | cut -c1-160 | tr '\n' ' ')"; }
# The refusal itself, from its ERROR line on: what must not change with content.
block() { sed -n '/^ERROR/,$p' "$ERR"; }
# Runs the command a refusal printed, as you would paste it.
follow() { local c; c="$(grep -m1 -F '(cd -P -- ' "$ERR")" && [[ -n "$c" ]] || return 99; bash -c "$c" >/dev/null 2>&1; }
# A program that says it ran, and a config that makes git run it.
FSM="$TMP/fsm"; printf '#!/bin/sh\necho FSMON-RAN >&2\n' > "$FSM" && chmod +x "$FSM" || { printf 'SCAFFOLD-FAILED: fsm\n'; exit 1; }
plant() {  # $1 = directory, $2 = where its objects come from: what makes it a repository of the agent's
  mkdir -p "$1/objects" "$1/refs" && cp -R "$2/objects/." "$1/objects/" \
    && printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = %s\n' "$FSM" > "$1/config"
}
# The host's git in checkout $1 works and ran nothing of the agent's. Bounded: git waits at a FIFO.
gst() { p_timeout 20 "${G[@]}" -C "$1" status -s 2>&1; }
quiet() { local o; o="$(gst "$1")" && [[ "$o" != *FSMON-RAN* && "$o" != *fatal:* ]]; }
cdval() { if [[ -f "$1" && ! -L "$1" ]]; then head -c 64 "$1" | tr -d '\0'; else printf '(no regular file)'; fi; }  # a commondir's text
# A repository in the mount with a linked worktree checked out outside every
# mount: R, its checkout CO, and the worktree's directory D.
mk() {  # $1 = name
  R="$PROJ/$1"; CO="$TMP/co-$1/w"; D="$R/.git/worktrees/w"
  rm -rf "$R" "$TMP/co-$1"; mkdir -p "$R" "$TMP/co-$1" && "${G[@]}" init -q "$R" \
    && "${G[@]}" -C "$R" commit -q --allow-empty -m i && "${G[@]}" -C "$R" worktree add -q "$CO" -b "w-$1" \
    || { printf 'SCAFFOLD-FAILED: %s\n' "$1"; exit 1; }
}
# The same with a bare repository: B, CO and D.
mkb() {  # $1 = name
  B="$PROJ/$1/b.git"; CO="$TMP/co-$1/w"; D="$B/worktrees/w"
  rm -rf "${PROJ:?}/$1" "$TMP/co-$1"; mkdir -p "$PROJ/$1" "$TMP/co-$1" && "${G[@]}" init -q "$TMP/up-$1" \
    && "${G[@]}" -C "$TMP/up-$1" commit -q --allow-empty -m i && "${G[@]}" clone -q --bare "$TMP/up-$1" "$B" \
    && "${G[@]}" -C "$B" worktree add -q "$CO" -b "w-$1" && rm -rf "$TMP/up-$1" \
    || { printf 'SCAFFOLD-FAILED: %s\n' "$1"; exit 1; }
}
spoil() {  # $1 = kind, $2 = directory: its commondir made one git does not write
  rm -rf "$2/commondir"
  case "$1" in
    junk) printf '../x\n' > "$2/commondir" ;;
    link) ln -s ../../../cd "$2/commondir" ;;
    fifo) mkfifo "$2/commondir" ;;
    dir)  mkdir "$2/commondir" ;;
    nul)  printf '../..\0\n' > "$2/commondir" ;;
  esac
}
says() {  # $1 = kind: what the ERROR line says of that commondir
  case "$1" in
    junk) printf 'sends git to' ;; link) printf 'is a symlink' ;; nul) printf 'holds what git reads otherwise' ;;
    *) printf 'is not a regular file' ;;
  esac
}

# ── G177: a linked worktree's directory under a .git: ../.. is put back ──────
# Whatever is wrong with its commondir, and whatever the agent planted beside
# it, the one command writes git's ../.. back and removes nothing else: the
# planted config is then never read. Nothing says to remove the commondir.
for k in junk link fifo dir nul; do
  mk wo177; plant "$D" "$R/.git"; spoil "$k" "$D"
  launch_timed 120 ..
  refused && has "ERROR: $D/commondir $(says "$k")" && has "$(k_cmd "$D")" \
    && has "git writes ../.. there, in a linked worktree's directory. To put that back, stop every" && has "in bash or zsh:" \
    && has "If $D is not yours, move it (mv) to a directory you never mount instead." \
    && has "A file of yours that only shares the name: rename it instead; the command overwrites it." \
    && ! has "$(r_cmd "$D")" && ! has "directory named worktrees" && clean \
    && pass "G177 a worktree's commondir ($k): the refusal says to put ../.. back, and to remove nothing" \
    || fail "G177 a worktree's commondir, $k ($(why))"
  block > "$TMP/b177"
  follow; launch_timed 120 ..
  [[ "$LAUNCH_RC" == 0 && "$(cdval "$D/commondir")" == ../.. ]] && quiet "$CO" \
    && pass "G177 …and with that done the launch starts, the planted config unread ($k)" \
    || fail "G177 after the command, $k (rc=$LAUNCH_RC; commondir: $(cdval "$D/commondir"); $(grep -m1 ERROR "$ERR"); git: $(gst "$CO" | head -2 | tr '\n' ' '))"
  # The same text for a directory that holds nothing of the agent's but the
  # commondir, and for one with a forged gitdir and no HEAD: what is there
  # does not choose the advice.
  mk wo177; spoil "$k" "$D"; launch_timed 120 ..; block > "$TMP/b177a"
  mk wo177; plant "$D" "$R/.git"; spoil "$k" "$D"; printf '/nonexistent/x/.git\n' > "$D/gitdir"; rm -f "$D/HEAD"
  launch_timed 120 ..; block > "$TMP/b177b"
  [[ -s "$TMP/b177" ]] && cmp -s "$TMP/b177" "$TMP/b177a" && cmp -s "$TMP/b177" "$TMP/b177b" \
    && pass "G177 …and the refusal reads the same whatever the directory holds ($k)" \
    || fail "G177 the text changes with the directory's content, $k ($(diff "$TMP/b177" "$TMP/b177b" | head -4 | tr '\n' ' '))"
  ( exec 3<>"$D/commondir" ) 2>/dev/null; rm -rf "$R" "$TMP/co-wo177"
done

# ── G178: a link swapped in for the directory is not followed ───────────────
# A container still running on the tree can replace the directory the command
# names with a link, here to the repository's own git directory: the command
# enters it physically and stops, where one that followed the link wrote ../..
# over that directory's commondir.
mk wo178; spoil junk "$D"; launch_timed 120 ..
mv "$D" "$R/.git/worktrees/aside" && ln -s .. "$D" && printf './\n' > "$R/.git/commondir" || { printf 'SCAFFOLD-FAILED: G178 swap\n'; exit 1; }
follow; rc178=$?
[[ "$rc178" != 0 && "$rc178" != 99 && "$(cdval "$R/.git/commondir")" == ./ && "$(cdval "$R/.git/worktrees/aside/commondir")" == ../x ]] \
  && pass "G178 the command stops at a directory swapped for a link, the commondir behind the link untouched" \
  || fail "G178 a swapped directory (rc=$rc178; behind the link: $(cdval "$R/.git/commondir"); aside: $(cdval "$R/.git/worktrees/aside/commondir"))"
rm -rf "$R" "$TMP/co-wo178"
# …and a directory whose name the shell would read as more than a name is
# quoted in it: pasted unquoted, the agent's `touch` in that name ran.
N178="$PROJ/wo178/a b;touch PWNED;\$(touch PWNED2)"
mkdir -p "$TMP/cwd178" "$PROJ/wo178" && "${G[@]}" init -q "$N178" && printf '../x\n' > "$N178/.git/commondir" || { printf 'SCAFFOLD-FAILED: G178 name\n'; exit 1; }
launch_timed 120 ..
( cd "$TMP/cwd178" && follow ); rc178=$?
[[ "$rc178" == 0 && ! -e "$N178/.git/commondir" && -z "$(ls -A "$TMP/cwd178")" ]] \
  && pass "G178 a directory named with a space, a semicolon and a \$(…) is quoted: the command removes its commondir and runs nothing else" \
  || fail "G178 a name the shell would read as a command (rc=$rc178; made: $(ls -A "$TMP/cwd178" | tr '\n' ' '); commondir: $(cdval "$N178/.git/commondir"); $(why))"
rm -rf "$PROJ/wo178" "$TMP/cwd178"

# ── G179: a bare repository's worktree, and a repository under worktrees/ ────
# Outside a .git a directory under worktrees/ may be a linked worktree's (a
# bare repository's, a submodule's) or a repository of its own that only lies
# in a directory by that name, and nothing the agent cannot write tells them
# apart: ../.. is still what is put back, never removed, and a repository of
# its own is moved out of there instead.
for k in junk nul; do
  mkb wo179; plant "$D" "$B"; spoil "$k" "$D"
  launch_timed 120 ..
  refused && has "ERROR: $D/commondir $(says "$k")" && has "$(k_cmd "$D")" && ! has "$(r_cmd "$D")" \
    && has "If it is a bare repository of yours that only lies in a directory named worktrees, move" && clean \
    && pass "G179 a bare repository's worktree ($k): ../.. is put back, or a bare repository of yours moved out" \
    || fail "G179 a bare repository's worktree, $k ($(why))"
  follow; launch_timed 120 ..
  [[ "$LAUNCH_RC" == 0 ]] && quiet "$CO" && pass "G179 …and with that done the launch starts, the planted config unread ($k)" \
    || fail "G179 after the command, $k (rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"); git: $(gst "$CO" | head -2 | tr '\n' ' '))"
  rm -rf "$PROJ/wo179" "$TMP/co-wo179"
done
# A real bare repository in a directory named worktrees, a commondir planted in it.
O179="$PROJ/wo179/worktrees/own.git"
mkdir -p "$PROJ/wo179/worktrees" && "${G[@]}" init -q "$TMP/up179" && "${G[@]}" -C "$TMP/up179" commit -q --allow-empty -m i \
  && "${G[@]}" clone -q --bare "$TMP/up179" "$O179" && rm -rf "$TMP/up179" \
  || { printf 'SCAFFOLD-FAILED: G179 own\n'; exit 1; }
refs179="$("${G[@]}" --git-dir="$O179" for-each-ref)"
[[ -n "$refs179" ]] && printf '../x\n' > "$O179/commondir" || { printf 'SCAFFOLD-FAILED: G179 refs\n'; exit 1; }
launch_timed 120 ..
refused && has "$(k_cmd "$O179")" && ! has "$(r_cmd "$O179")" \
  && has "it out of there instead, and launch again." && clean \
  && pass "G179 a repository of its own under worktrees/: it is to be moved out, its commondir not removed there" \
  || fail "G179 a repository of its own under worktrees/ ($(why))"
# Taken for a linked worktree's by mistake, ../.. written: the launch is
# refused again, with nothing to remove, and nothing was lost.
follow; launch_timed 120 ..
refused && ! has '(cd -P -- ' && has "holds no objects or no refs" && has "Do not remove $O179/commondir" && clean \
  && pass "G179 …and ../.. written there by mistake is refused again, with no command and nothing lost" \
  || fail "G179 ../.. written into a repository of its own ($(why))"
# Moved out, as the refusal says: there its commondir is one to remove, and
# after that the launch starts, the repository's refs as they were.
printf '../x\n' > "$O179/commondir"; mv "$O179" "$PROJ/wo179/own.git"; O179="$PROJ/wo179/own.git"
launch_timed 120 ..
refused && has "$(r_cmd "$O179")" && has "git then reads $O179/config and $O179/hooks: read them first." \
  && has "If you did not make it, stop every container running on this tree and remove it on the" && clean \
  && pass "G179 …moved out of worktrees/, its commondir is one to remove, after a look at its config and hooks" \
  || fail "G179 moved out of worktrees/ ($(why))"
follow; launch_timed 120 ..
[[ "$LAUNCH_RC" == 0 && "$("${G[@]}" --git-dir="$O179" for-each-ref 2>&1)" == "$refs179" ]] \
  && pass "G179 …and with it removed the launch starts, the repository's refs as they were" \
  || fail "G179 after the removal (rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"))"
rm -rf "$PROJ/wo179"

# ── G180: a repository's own git directory, and a file that shares the name ──
# Where git keeps no worktree's directory a commondir is none of git's: it is
# removed, by a command that enters the directory physically, after a look at
# the config and hooks git reads once it is gone. A directory by that name is
# not removed by it.
for k in junk link dir; do
  rm -rf "$PROJ/wo180"; "${G[@]}" init -q "$PROJ/wo180" && "${G[@]}" -C "$PROJ/wo180" commit -q --allow-empty -m i \
    || { printf 'SCAFFOLD-FAILED: G180\n'; exit 1; }
  D="$PROJ/wo180/.git"; spoil "$k" "$D"
  launch_timed 120 ..
  refused && has "ERROR: $D/commondir $(says "$k")" && has "$(r_cmd "$D")" && ! has '&& rm -rf commondir' \
    && has "A directory is not removed by" && has "A file of yours that only shares the name: rename it." && clean \
    && pass "G180 a repository's own commondir ($k): the refusal says to remove it, and what git reads then" \
    || fail "G180 a repository's own commondir, $k ($(why))"
  follow; rc180=$?
  if [[ "$k" == dir ]]; then
    [[ "$rc180" != 0 && "$rc180" != 99 && -d "$D/commondir" ]] && pass "G180 …and the command removes no directory" \
      || fail "G180 the command on a directory (rc=$rc180)"
  else
    launch_timed 120 ..
    [[ "$rc180" == 0 && "$LAUNCH_RC" == 0 ]] && pass "G180 …and with it removed the launch starts ($k)" \
      || fail "G180 after the removal, $k (command rc=$rc180; launch rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"))"
  fi
  rm -rf "$PROJ/wo180"
done
# One this launcher cannot read as git does is met while the mount is scanned,
# before every read-only overlay is decided: no removal is printed, since
# whether one covers the directory is not known yet.
"${G[@]}" init -q "$PROJ/wo180" && spoil nul "$PROJ/wo180/.git" || { printf 'SCAFFOLD-FAILED: G180 nul\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $PROJ/wo180/.git/commondir $(says nul)" && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" \
  && has "If it is a repository of yours, it holds no commondir: git reads $PROJ/wo180/.git/config and" \
  && has "before you remove it. A file of yours that only shares the name: rename it." && clean \
  && pass "G180 a commondir with a NUL, met while the mount is scanned: no command, and what git reads once it is gone" \
  || fail "G180 a commondir with a NUL ($(why))"
rm -rf "$PROJ/wo180"
# A checkout's own .git in a directory named worktrees is no linked worktree's
# directory: ../.. there is not git's, whatever the directory above holds, and
# it is one to remove (the test _git_cd_check() and the advice share).
mkdir -p "$PROJ/wo180/objects" "$PROJ/wo180/refs" && "${G[@]}" init -q "$PROJ/wo180/worktrees" \
  && printf '../..\n' > "$PROJ/wo180/worktrees/.git/commondir" || { printf 'SCAFFOLD-FAILED: G180 worktrees/.git\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $PROJ/wo180/worktrees/.git/commondir sends git to" && has "$(r_cmd "$PROJ/wo180/worktrees/.git")" && clean \
  && pass "G180 ../.. in a .git that lies in a directory named worktrees is refused, and is one to remove" \
  || fail "G180 worktrees/.git with ../.. ($(why))"
rm -rf "$PROJ/wo180"
# A file of yours named commondir is left alone by itself (GIT-79; G193 in the
# scan file); with one named HEAD beside it the directory is still taken.
mkdir -p "$PROJ/wo180/notes" && printf 'the shared directory\n' > "$PROJ/wo180/notes/commondir" \
  && printf 'the first line\n' > "$PROJ/wo180/notes/HEAD" || { printf 'SCAFFOLD-FAILED: G180 notes\n'; exit 1; }
launch_timed 120 ..
refused && has "If you did not make it, stop every container running on this tree and remove it on the" \
  && has "A file of yours that only shares the name: rename it." && clean \
  && pass "G180 files of yours named HEAD and commondir: the refusal says to rename it" \
  || fail "G180 plain files named HEAD and commondir ($(why))"
rm -rf "$PROJ/wo180"

# ── G181: under refs/ or logs/ nothing is to be removed or moved ────────────
# A branch named commondir is a file by that name among a bare repository's
# refs, and the launch took its directory for a git directory. The old `rm`
# deleted the branch, the only name of its commits, and beside a branch named
# hooks the refusal for a hooks that is no directory printed one too. No
# command is printed there, for any of them, and nothing says to remove or
# move anything. Since GIT-79's fix such a directory is taken only with a HEAD
# in it, which a remote whose HEAD is set leaves beside its branches (G193 in
# the scan file has the ones that now launch).
norm181() { ! has '(cd -P -- ' && ! grep -qwE 'rm|mv' "$ERR" && has "Do not remove it: that deletes the branch." && clean; }
for b in commondir worktrees/x/commondir "commondir hooks"; do
  rm -rf "$PROJ/wo181"; mkdir -p "$PROJ/wo181" && "${G[@]}" init -q --bare "$PROJ/wo181/b.git" || { printf 'SCAFFOLD-FAILED: G181\n'; exit 1; }
  for n in $b; do "${G[@]}" -C "$PROJ" push -q "$PROJ/wo181/b.git" "HEAD:refs/remotes/o/$n" || { printf 'SCAFFOLD-FAILED: G181 push\n'; exit 1; }; done
  h181="${b%% *}"; h181="refs/remotes/o/${h181%commondir}HEAD"
  "${G[@]}" --git-dir="$PROJ/wo181/b.git" symbolic-ref "$h181" "refs/remotes/o/${b%% *}" && [[ -f "$PROJ/wo181/b.git/$h181" ]] \
    || { printf 'SCAFFOLD-FAILED: G181 HEAD\n'; exit 1; }
  before181="$("${G[@]}" --git-dir="$PROJ/wo181/b.git" for-each-ref)"
  launch_timed 120 ..
  refused && has "ERROR: $PROJ/wo181/b.git/refs/remotes/o/" && norm181 \
    && has "It lies under a refs or logs directory:" && has "whose name ends in ${b##*[ /]}, or its log, is such a file" \
    && [[ -n "$before181" && "$("${G[@]}" --git-dir="$PROJ/wo181/b.git" for-each-ref)" == "$before181" ]] \
    && pass "G181 a remote's branch named ${b// / beside one named }, its HEAD set: no command, and nothing to remove" \
    || fail "G181 a branch named $b ($(why))"
done
# A file git's ../.. was written into, under refs/: the directory it names holds
# no objects, and what the refusal says then moves nothing either.
rm -rf "$PROJ/wo181"; mkdir -p "$PROJ/wo181" && "${G[@]}" init -q --bare "$PROJ/wo181/b.git" \
  && mkdir -p "$PROJ/wo181/b.git/refs/heads/worktrees/x" && printf '../..\n' > "$PROJ/wo181/b.git/refs/heads/worktrees/x/commondir" \
  || { printf 'SCAFFOLD-FAILED: G181 ../..\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $PROJ/wo181/b.git/refs/heads/worktrees/x/commondir names $PROJ/wo181/b.git/refs/heads, which is no" && norm181 \
  && pass "G181 ../.. in a file under refs/: no command, and nothing to move" \
  || fail "G181 ../.. under refs/ ($(why))"
rm -rf "$PROJ/wo181"

# ── G182: under a read-only overlay no command is printed ───────────────────
# A repository inside a launcher gets no binds and no first-protection NOTE,
# so its commondir removed made git read a config nothing had named. There the
# refusal prints no command: what is not yours is moved out, and a repository
# of yours is told what git reads once its commondir is gone. A worktree's
# directory there is told what git writes, by hand.
E182="$PROJ/ev182"
mk182() {  # $1 = the git directory under the launcher that gets the commondir
  rm -rf "$E182"; mkdir -p "$E182/.git/objects" "$E182/.git/refs/heads" "$E182/cd" "$1" && : > "$E182/sandbox.sh" && : > "$E182/sandbox-common.sh" \
    && printf 'ref: refs/heads/main\n' > "$E182/.git/HEAD" && printf 'ref: refs/heads/main\n' > "$1/HEAD" && printf '../cd\n' > "$1/commondir" \
    && printf '[core]\n\tfsmonitor = %s\n' "$FSM" > "$1/config" || { printf 'SCAFFOLD-FAILED: G182\n'; exit 1; }
}
mk182 "$E182/.git"; launch_timed 120 ..
refused && has "ERROR: $E182/.git/commondir sends git to" && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" \
  && has "If $E182/.git is not yours, move it (mv) to a directory you never mount." \
  && has "$E182/.git/hooks once that is gone, and no launch names what they set there: read them" && clean \
  && pass "G182 a commondir under a read-only overlay: no command, and what git reads once it is gone" \
  || fail "G182 under a read-only overlay ($(why))"
mk182 "$E182/.git/worktrees/w"; launch_timed 120 ..
refused && has "ERROR: $E182/.git/worktrees/w/commondir sends git to" && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" \
  && has "If $E182/.git/worktrees/w is not yours, move it (mv) to a directory you never mount." \
  && has "In a linked worktree's directory git writes ../.. there: write that back by hand." \
  && has "A file of yours that only shares the name: rename it." && clean \
  && pass "G182 a worktree's commondir under a read-only overlay: no command either, and what git writes there" \
  || fail "G182 a worktree's directory under a read-only overlay ($(why))"
rm -rf "$E182"
# The git directory itself the launcher: a bare repository holding the two files.
E182="$PROJ/ev182.git"
mkdir -p "$E182/objects" "$E182/refs/heads" "$PROJ/cd" && : > "$E182/sandbox.sh" && : > "$E182/sandbox-common.sh" \
  && printf 'ref: refs/heads/main\n' > "$E182/HEAD" && printf '../cd\n' > "$E182/commondir" \
  && printf '[core]\n\tbare = true\n\tfsmonitor = %s\n' "$FSM" > "$E182/config" || { printf 'SCAFFOLD-FAILED: G182 root\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $E182/commondir sends git to" && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" \
  && has "If $E182 is not yours, move it (mv) to a directory you never mount." && clean \
  && pass "G182 a git directory that is itself what is mounted read-only: no command either" \
  || fail "G182 the overlay's own root ($(why))"
rm -rf "$E182" "$PROJ/cd"

# ── G183: the repository a worktree names holds no objects or no refs ────────
# git's own ../.. in a linked worktree's directory, the repository's objects
# moved aside and a repository planted in the worktree's directory: the old
# refusal said to remove that ../.., and git then ran the planted config. Now
# it says to put the objects back, and that the commondir stays.
for v in git bare; do
  if [[ "$v" == git ]]; then mk wo183; C183="$R/.git"; else mkb wo183; C183="$B"; fi
  plant "$D" "$C183"; mv "$C183/objects" "$C183/objects.aside" || { printf 'SCAFFOLD-FAILED: G183\n'; exit 1; }
  launch_timed 120 ..
  refused && has "ERROR: $D/commondir names $C183, which is no repository's own git directory" \
    && has "$C183 holds no objects or no refs. If it is your repository's git directory, put them back, or" \
    && has "Do not remove $D/commondir: git would then read $D/config." \
    && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" && clean \
    && { if [[ "$v" == git ]]; then ! has "directory named worktrees"; else has "directory named worktrees"; fi; } \
    && pass "G183 a worktree whose repository lost its objects ($v): they are to be put back, the commondir kept" \
    || fail "G183 the repository's objects moved aside, $v ($(why))"
  block > "$TMP/b183"
  mv "$C183/objects.aside" "$C183/objects"; launch_timed 120 ..
  [[ "$LAUNCH_RC" == 0 ]] && quiet "$CO" && pass "G183 …and with them back the launch starts, the planted config unread ($v)" \
    || fail "G183 after the objects are back, $v (rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"); git: $(gst "$CO" | head -2 | tr '\n' ' '))"
  # The same text with nothing planted in the worktree's directory.
  if [[ "$v" == git ]]; then mk wo183; C183="$R/.git"; else mkb wo183; C183="$B"; fi
  mv "$C183/objects" "$C183/objects.aside"; launch_timed 120 ..; block > "$TMP/b183a"
  [[ -s "$TMP/b183" ]] && cmp -s "$TMP/b183" "$TMP/b183a" \
    && pass "G183 …and the refusal reads the same whatever the worktree's directory holds ($v)" \
    || fail "G183 the text changes with the directory's content, $v ($(diff "$TMP/b183" "$TMP/b183a" | head -4 | tr '\n' ' '))"
  rm -rf "$PROJ/wo183" "$TMP/co-wo183"
done

# ── G184: the directory a worktree names has a commondir of its own ─────────
# A worktree's directory planted inside a real linked worktree's, which holds
# git's ../..: the planted one is to be moved out, and nothing is said to be
# removed from the real one (the old refusal's `rm` there handed git the
# agent's config).
mk wo184; W184="$D/worktrees/n"
plant "$D" "$R/.git"; mkdir -p "$W184" && printf 'ref: refs/heads/main\n' > "$W184/HEAD" && printf '../..\n' > "$W184/commondir" \
  || { printf 'SCAFFOLD-FAILED: G184\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $W184/commondir names $D, which is no repository's own git directory" \
  && has "$D has a commondir of its own." && has "$W184 does not belong in it" \
  && has "Move $W184 (mv) to a directory you never mount." && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" && clean \
  && pass "G184 a worktree planted in a real worktree's directory: it is to be moved out, nothing removed" \
  || fail "G184 nested in a real worktree ($(why))"
mv "$W184" "$TMP/out184"; launch_timed 120 ..
[[ "$LAUNCH_RC" == 0 ]] && quiet "$CO" && pass "G184 …and with it moved out the launch starts, the planted config unread" \
  || fail "G184 after the move (rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"); git: $(gst "$CO" | head -2 | tr '\n' ' '))"
rm -rf "$R" "$TMP/co-wo184" "$TMP/out184"
# A mount rooted at a repository's worktrees/, the repository outside every
# mount with a commondir of its own, a link: that one is what is wrong, and no
# worktree's directory lies there, so it is the one to remove.
R184="$TMP/r184"; mkdir -p "$R184" && "${G[@]}" init -q "$R184" && "${G[@]}" -C "$R184" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$R184" worktree add -q "$TMP/co184" -b co184 && printf './\n' > "$TMP/dot184" \
  && ln -s "$TMP/dot184" "$R184/.git/commondir" || { printf 'SCAFFOLD-FAILED: G184 outside\n'; exit 1; }
EXTRA_MOUNTS="$R184/.git/worktrees" launch_timed 120 ..
refused && has "ERROR: $R184/.git/worktrees/co184/commondir names $R184/.git, which is no repository's own git directory" \
  && has "$R184/.git has a commondir of its own." && has "$R184/.git/commondir is what is wrong." \
  && has "$(r_cmd "$R184/.git")" && ! has "$(k_cmd "$R184/.git/worktrees/co184")" && clean \
  && pass "G184 a worktree whose repository's own commondir is wrong: that one is to be removed" \
  || fail "G184 the repository's own commondir ($(why))"
follow; EXTRA_MOUNTS="$R184/.git/worktrees" launch_timed 120 ..
[[ "$LAUNCH_RC" == 0 ]] && pass "G184 …and with it removed the launch starts" || fail "G184 after the removal (rc=$LAUNCH_RC; $(grep -m1 ERROR "$ERR"))"
rm -rf "$R184" "$TMP/co184" "$TMP/dot184"

# ── G185: the place decides, by the directory's physical path ───────────────
# _cd_way_out() itself: which part each place gets, however the path is
# spelled; no command under a read-only overlay, and no removal where the
# overlays are not all known yet (while a mount is scanned, and in the search
# just before docker, which runs outside the pass that knows them).
for f in _term _q _cd_bash _cd_wt_loc _cd_refs_loc _cd_refs_say _cd_under_ro _cd_cmd _cd_way_out; do load_fn "$f"; done
if ! declare -F _cd_way_out >/dev/null; then
  fail "G185 sandbox.sh has no _cd_way_out()"
else
  mkdir -p "$TMP/u185/.git/worktrees/w" "$TMP/u185/b.git/WORKTREES/w" "$TMP/u185/b.git/refs/heads/worktrees/x" \
    "$TMP/u185/b.git/LOGS/x" "$TMP/u185/worktrees/.git" "$TMP/u185/plain" "$TMP/u185/lnch/.git/worktrees/w" \
    "$TMP/u185/nl"$'\n' || { printf 'SCAFFOLD-FAILED: G185\n'; exit 1; }
  # shellcheck disable=SC2034  # bsrc, bdst and ro_dsts are what the loaded _cd_under_ro() reads
  u185() {  # $1 = directory, as spelled; $2 = known: the pass's arrays are in scope and complete
    if [[ -n "${2:-}" ]]; then
      ( _cd_ro_known=1; bsrc=("$TMP/u185"); bdst=(/workspace/u); ro_dsts=(/workspace/u/lnch); _cd_way_out "$1" ) 2>&1
    else ( unset _cd_ro_known; bsrc=("$TMP/u185"); bdst=(/workspace/u); ro_dsts=(); _cd_way_out "$1" ) 2>&1; fi
  }
  U="$TMP/u185"
  [[ "$(u185 "$U/.git/worktrees/w/." known)" == *"$(k_cmd "$U/.git/worktrees/w")"* && "$(u185 "$U/.git/worktrees/w/../w" known)" != *"named worktrees"* ]] \
    && pass "G185 a worktree's directory spelled with a trailing /. is still one: ../.. is put back" \
    || fail "G185 a path spelled with /. ($(u185 "$U/.git/worktrees/w/." known | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/b.git/WORKTREES/w" known)" == *"$(k_cmd "$U/b.git/WORKTREES/w")"*"named worktrees"* ]] \
    && pass "G185 worktrees in another case counts, as git's does where case is ignored" \
    || fail "G185 WORKTREES ($(u185 "$U/b.git/WORKTREES/w" known | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/worktrees/.git" known)" == *"$(r_cmd "$U/worktrees/.git")"* ]] \
    && pass "G185 a .git in a directory named worktrees is a repository's own: its commondir is removed" \
    || fail "G185 worktrees/.git ($(u185 "$U/worktrees/.git" known | head -3 | tr '\n' ' '))"
  for d in "$U/b.git/refs/heads/worktrees/x" "$U/b.git/LOGS/x"; do
    [[ "$(u185 "$d" known)" == *"under a refs or logs directory"* && "$(u185 "$d" known)" != *'(cd -P'* && "$(u185 "$d" known)" != *'(mv)'* ]] \
      && pass "G185 under ${d#"$U/b.git/"}: no command, worktrees/ in the path or not" \
      || fail "G185 under ${d#"$U/b.git/"} ($(u185 "$d" known | head -3 | tr '\n' ' '))"
  done
  # Reached through a link whose name says nothing: it is where it leads that counts.
  ln -s b.git/refs/heads/worktrees/x "$U/lnk" || { printf 'SCAFFOLD-FAILED: G185 link\n'; exit 1; }
  [[ "$(u185 "$U/lnk" known)" == *"under a refs or logs directory"* && "$(u185 "$U/lnk" known)" != *'(cd -P'* ]] \
    && pass "G185 a directory under refs/ reached through a link gets no command" \
    || fail "G185 under refs/ through a link ($(u185 "$U/lnk" known | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/plain" known)" == *"$(r_cmd "$U/plain")"* && "$(u185 "$U/lnch/.git" known)" != *'(cd -P'* \
     && "$(u185 "$U/lnch/.git" known)" == *"is not yours, move it (mv)"*"no launch names what they set there"* ]] \
    && pass "G185 under a read-only overlay no command; beside it, the removal" \
    || fail "G185 the overlay ($(u185 "$U/lnch/.git" known | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/lnch/.git/worktrees/w" known)" != *'(cd -P'* && "$(u185 "$U/lnch/.git/worktrees/w" known)" == *"write that back by hand"* ]] \
    && pass "G185 a worktree's directory under a read-only overlay gets no command either" \
    || fail "G185 a worktree's directory under the overlay ($(u185 "$U/lnch/.git/worktrees/w" known | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/plain")" != *'(cd -P'* && "$(u185 "$U/plain")" == *"is not yours, move it (mv)"* \
     && "$(u185 "$U/.git/worktrees/w")" == *"$(k_cmd "$U/.git/worktrees/w")"* ]] \
    && pass "G185 where the overlays are not all known no removal is printed; ../.. is still put back" \
    || fail "G185 the overlays unknown ($(u185 "$U/plain" | head -3 | tr '\n' ' '))"
  [[ "$(u185 "$U/gone/x" known)" != *'(cd -P'* && "$(u185 "$U/gone/x" known)" == *"cannot be entered by a command printed here"* \
     && "$(u185 "$U/nl"$'\n' known)" != *'(cd -P'* && "$(u185 "$U/nl"$'\n' known)" == *"cannot be entered by a command printed here"* \
     && "$(u185 "$U/b.git/refs/gone/x" known)" == *"under a refs or logs directory"* ]] \
    && pass "G185 a directory that is not there, or whose name ends in a newline, gets no command; under refs/ it is still said to be a branch" \
    || fail "G185 a directory no command can enter ($(u185 "$U/nl"$'\n' known | head -3 | tr '\n' ' '))"
  rm -rf "$TMP/u185"
fi

# ── G186: a FIFO named commondir that only the FIFO search finds ────────────
# Under a hooks/ the launch binds read-only no scan takes the directory for a
# git directory, and the search for FIFOs in what is bound is what refuses.
# It printed `rm <the FIFO>`; for that name it now says what any other
# refusal over a commondir says there, under a read-only bind: no command.
mk wo186; mkdir -p "$R/.git/hooks/sub" && mkfifo "$R/.git/hooks/sub/commondir" || { printf 'SCAFFOLD-FAILED: G186\n'; exit 1; }
launch_timed 120 ..
refused && has "ERROR: $R/.git/hooks/sub/commondir is a FIFO or device inside what this launch binds read-only" \
  && ! has '(cd -P -- ' && ! grep -qw rm "$ERR" \
  && has "If $R/.git/hooks/sub is not yours, move it (mv) to a directory you never mount." && clean \
  && pass "G186 a FIFO named commondir under a hooks/ bound read-only: no command" \
  || fail "G186 a FIFO the search finds ($(why))"
rm -rf "$R" "$TMP/co-wo186"

# ── G198: what a gitdir or a .git file to remove is for ───────────────────────
# The refusals over one said only to remove it. With its gitdir gone, git gc
# removes a linked worktree's directory, its HEAD, index and own refs with it;
# with its .git file gone a checkout is detached. They now say so, and for a
# gitdir what to write in its place, by hand: no command is printed, since one
# that reads the repository does what the agent's files choose (bugs review
# GIT-82, whose first fix advised `git worktree repair` and was withdrawn).
nocmd198() { ! grep -qF '`' "$ERR" && ! has '(cd -P' && ! grep -qE 'git (worktree|submodule) ' "$ERR"; }
D198="$TMP/d198"; mkdir -p "$D198" && "${G[@]}" init -q "$D198/r" && "${G[@]}" -C "$D198/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$D198/r" worktree add -q "$D198/co" -b wb 2>/dev/null || { printf 'SCAFFOLD-FAILED: G198\n'; exit 1; }
w198="$D198/r/.git/worktrees/co"
printf 'x\0y\n' > "$w198/gitdir"
EXTRA_MOUNTS="$D198" launch_timed 120 "$TMP/app"
refused && has "ERROR: $w198/gitdir holds what git reads otherwise" && has "If you did not make it, remove it on the host." \
  && has "with the gitdir gone, git gc" && has "removes the directory, its HEAD, index and own refs with it (unless the worktree is locked)." \
  && has "the full path of the .git file in the checkout you made for that worktree" && nocmd198 && ! grep -qw rm "$ERR" \
  && pass "G198 a gitdir this launcher cannot read: what removing it costs, and what to write in its place, with no command" \
  || fail "G198 odd gitdir ($(why))"
# Doing that by hand: the file removed, the path written.
rm -f "$w198/gitdir" && printf '%s\n' "$D198/co/.git" > "$w198/gitdir"
EXTRA_MOUNTS="$D198" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -z "$("${G[@]}" -C "$D198/r" worktree prune -n 2>&1)" ]] && quiet "$D198/co" \
  && pass "G198 …and with it written by hand the launch starts, nothing is to be pruned, and the checkout works" \
  || fail "G198 after writing it (rc=$LAUNCH_RC; prune: $("${G[@]}" -C "$D198/r" worktree prune -n 2>&1 | head -1))"
rm -f "$w198/gitdir" && mkfifo "$w198/gitdir"
EXTRA_MOUNTS="$D198" launch_timed 120 "$TMP/app"
refused && has "ERROR: $w198/gitdir" && has "with the gitdir gone, git gc" && nocmd198 \
  && pass "G198 a FIFO for a gitdir: the same" \
  || fail "G198 FIFO gitdir ($(why))"
rm -f "$w198/gitdir" && printf '%s\n' "$D198/co/.git" > "$w198/gitdir"
# A FIFO by that name where git keeps no worktree's directory gets none of it.
mkfifo "$D198/r/.git/hooks/gitdir"
EXTRA_MOUNTS="$D198" launch_timed 120 "$TMP/app"
refused && has "ERROR: $D198/r/.git/hooks/gitdir is a FIFO or device" && ! has "git gc" && ! has "checkout" \
  && pass "G198 a FIFO named gitdir in a hooks/ gets nothing added" \
  || fail "G198 FIFO in hooks/ ($(why))"
rm -f "$D198/r/.git/hooks/gitdir"
printf 'gitdir: x\0y\n' > "$D198/co/.git"
EXTRA_MOUNTS="$D198" launch_timed 120 "$TMP/app"
refused && has "ERROR: $D198/co/.git holds what git reads otherwise" && has "If this directory is a checkout of yours" \
  && has "once it is removed, the checkout is detached from it." && ! grep -qE 'write (it|the file)' "$ERR" && nocmd198 && ! grep -qw rm "$ERR" \
  && pass "G198 a .git file this launcher cannot read: what it is for, and nothing to write or run" \
  || fail "G198 odd .git file ($(why))"
rm -rf "$D198"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
