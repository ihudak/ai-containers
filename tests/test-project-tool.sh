#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# project.sh: the front door (init/report/sync pass through), project naming
# (prj_resolve), and the registry edits (projects.conf, image-projects.conf).
# Hermetic: HOME and an engine copy live in a temp dir; docker is a logging fake
# (tests/lib-project-tool.sh, shared with the other tests/test-project-*.sh).
# shellcheck source=tests/lib-project-tool.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-project-tool.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-project-tool.sh\n'; exit 1; }
# The engine copy's project.sh, named in this file so tests/falsify/derive-targets.sh,
# which reads each file's own assignments, sees that this test runs it.
P="$ENG/project.sh"

# ── dispatch ──
bash "$P" init /p name; rc=$?
ok "init passes its arguments through and returns project-init.sh's status" \
  bash -c '[ "$1" = 7 ] && grep -qxF "project-init.sh /p name" "$2"' _ "$rc" "$STUBLOG"
bash "$P" report --tsv; rc=$?
ok "report passes its arguments through and returns its status" \
  bash -c '[ "$1" = 7 ] && grep -qxF "ai-containers-report.sh --tsv" "$2"' _ "$rc" "$STUBLOG"
bash "$P" sync /p; rc=$?
ok "sync passes its arguments through and returns its status" \
  bash -c '[ "$1" = 7 ] && grep -qxF "sync-to-projects.sh /p" "$2"' _ "$rc" "$STUBLOG"

out="$(bash "$P" 2>&1)"; rc=$?
ok "no command prints usage and exits 0" bash -c '[ "$1" = 0 ] && [[ "$2" == *"./project.sh rm"* ]]' _ "$rc" "$out"
out="$(bash "$P" --help 2>&1)"
ok "--help prints project.sh's usage, not repo.sh's" bash -c '[[ "$1" == *"./project.sh init"* ]] && [[ "$1" != *"repo.sh add"* ]]' _ "$out"
out="$(bash "$P" frobnicate 2>&1)"; rc=$?
ok "an unknown command exits 1 and names it" bash -c '[ "$1" = 1 ] && [[ "$2" == *"unknown command: frobnicate"* ]]' _ "$rc" "$out"
out="$(bash "$P" rm x 2>&1)"; rc=$?
ok "rm reaches project.sh's own cmd_rm, not repo.sh's (which says Nothing to remove, rc 0)" \
  bash -c '[ "$1" = 1 ] && [[ "$2" == *"not a registered project"* ]]' _ "$rc" "$out"
out="$(bash "$P" gc 2>&1 < /dev/null)"; rc=$?
ok "gc reaches project.sh's own cmd_gc, not repo.sh's (which says No working copies found)" \
  bash -c '[ "$1" = 0 ] && [[ "$2" == *"Nothing to collect."* && "$2" != *"No working copies"* ]]' _ "$rc" "$out"

# ── prj_resolve ──
A="$TMP/work/alpha"; B="$TMP/work/two/beta"; C="$TMP/other/beta"; S="$TMP/work/sp ace"
mkdir -p "$A" "$B" "$C" "$S"
ln -s "$A" "$TMP/link-to-alpha"
printf '%s\n%s\n%s\n%s\n' "$A" "$B" "$C" "$S" > "$ENG/projects.conf"

res() {  # <arg> [ok] [cwd] → "root|dot" or the error on stderr; rc
  ( cd "${3:-$TMP}" && source "$P" && prj_resolve "$1" ${2:+"$2"} && printf '%s|%s' "$PRJ_ROOT" "$PRJ_DOT" ) 2>&1
}
r="$(res "$A")";          ok "resolve finds a project by its registered path" [ "$r" = "$A|$A/.ai-containers" ]
r="$(res "$A/")";         ok "resolve finds it with a trailing slash" [ "$r" = "$A|$A/.ai-containers" ]
r="$(res "alpha/../alpha" "" "$TMP/work")"; ok "resolve finds it by a relative path" [ "$r" = "$A|$A/.ai-containers" ]
r="$(res "$TMP/link-to-alpha")"; ok "resolve finds it through a symlink to it" [ "$r" = "$A|$A/.ai-containers" ]
r="$(res "alpha")";       ok "resolve finds it by its unique basename" [ "$r" = "$A|$A/.ai-containers" ]
r="$(res "sp ace")";      ok "resolve handles a path with a space" [ "$r" = "$S|$S/.ai-containers" ]
r="$(res "beta")"; rc=$?
ok "resolve refuses a basename two projects share, naming both" \
  bash -c '[ "$1" != 0 ] && [[ "$2" == *"$3"* && "$2" == *"$4"* ]]' _ "$rc" "$r" "$B" "$C"
r="$(res "$TMP/nowhere")"; rc=$?
ok "resolve refuses an unregistered path" bash -c '[ "$1" != 0 ] && [[ "$2" == *"not a registered project"* ]]' _ "$rc" "$r"
r="$(res "$TMP/nowhere" ok)"; rc=$?
ok "resolve accepts an unregistered path when allowed" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "$3|$3/.ai-containers" ]' _ "$rc" "$r" "$TMP/nowhere"
# A bare name that is also a directory here, not registered, is not taken for
# the registered project of that basename (bugs review PRJ-13): `rm api --yes`
# beside an unregistered ./api removed another project. Which is meant cannot
# be told, so neither is taken, for rm and for mv alike; a path picks one.
mkdir -p "$TMP/here/alpha"; HERE_A="$(cd "$TMP/here/alpha" && pwd -P)"
r="$(res "alpha" "" "$TMP/here")"; rc=$?
ok "resolve refuses a bare name that is an unregistered directory here and a registered basename, naming both" \
  bash -c '[ "$1" != 0 ] && [[ "$2" == *"$3"* && "$2" == *"$4"* && "$2" == *"not a registered project"* ]]' _ "$rc" "$r" "$HERE_A" "$A"
r="$(res "alpha" ok "$TMP/here")"; rc=$?
ok "resolve refuses that bare name when an unregistered path is allowed too (mv)" \
  bash -c '[ "$1" != 0 ] && [[ "$2" == *"$3"* && "$2" == *"$4"* ]]' _ "$rc" "$r" "$HERE_A" "$A"
r="$(res "./alpha" ok "$TMP/here")"; rc=$?
ok "resolve takes ./alpha, a path, as the directory here when allowed" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "$3|$3/.ai-containers" ]' _ "$rc" "$r" "$HERE_A"
rm -rf "$TMP/here"
# The registered project of that name gone (a setup moved by hand), the name is
# still the registered one's: `mv api <new-dir>` from beside the new place
# finishes the move (review of the PRJ-13 fix).
printf '%s\n' "$TMP/gone13/beta13" > "$ENG/projects.conf"; mkdir -p "$TMP/new13/beta13"
r="$(res "beta13" ok "$TMP/new13")"; rc=$?
ok "resolve takes a bare name for its registered project when that one is gone, for mv" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "$3|$3/.ai-containers" ]' _ "$rc" "$r" "$TMP/gone13/beta13"
# For rm it is refused: `rm api --yes` beside an unregistered ./api removed a
# gone project's working copies and line (review of the PRJ-13 fix).
r="$(res "beta13" "" "$TMP/new13")"; rc=$?
ok "resolve refuses that bare name for rm, naming both" \
  bash -c '[ "$1" != 0 ] && [[ "$2" == *"$3"* && "$2" == *"the registered project $4"* ]]' _ "$rc" "$r" "$(cd "$TMP/new13/beta13" && pwd -P)" "$TMP/gone13/beta13"
# mv from beside its <new-dir>, made beforehand, while the old place is still
# there: the directory here is where the project goes, not a second candidate.
mkdir -p "$TMP/gone13/beta13"
r="$( ( cd "$TMP/new13" && source "$P" && prj_resolve beta13 unregistered-ok "$TMP/new13/beta13" && printf '%s' "$PRJ_ROOT" ) 2>&1 )"; rc=$?
ok "resolve takes the registered project for mv when the directory here is <new-dir> itself" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "$3" ]' _ "$rc" "$r" "$TMP/gone13/beta13"
# Standing in a project that holds a subdirectory of its own name: which is
# meant cannot be told either, and both are named.
printf '%s\n' "$TMP/own13/mysite" > "$ENG/projects.conf"; mkdir -p "$TMP/own13/mysite/mysite"
r="$(res "mysite" "" "$TMP/own13/mysite")"; rc=$?
ok "resolve refuses the name of the project it stands in when a subdirectory there has it, naming both" \
  bash -c '[ "$1" != 0 ] && [[ "$2" == *"$4/mysite"* && "$2" == *"the registered project $3"* ]]' _ "$rc" "$r" "$TMP/own13/mysite" "$(cd "$TMP/own13/mysite" && pwd -P)"
# The registered root reached by another path to the same directory (a bind
# mount) is that project, not a directory of the same name (review of the
# PRJ-13 fix). A bind mount needs a mount namespace of one's own.
if unshare -rm true 2>/dev/null; then
  printf '%s\n' "$TMP/real13/api" > "$ENG/projects.conf"; mkdir -p "$TMP/real13/api" "$TMP/view13"
  r="$(unshare -rm bash -c 'mount --bind "$1" "$2" && cd "$2" && source "$3" && prj_resolve api && printf "%s" "$PRJ_ROOT"' _ "$TMP/real13" "$TMP/view13" "$P" 2>&1)"; rc=$?
  ok "resolve takes a bind-mounted view of the registered root for that project" \
    bash -c '[ "$1" = 0 ] && [ "$2" = "$3" ]' _ "$rc" "$r" "$TMP/real13/api"
  rm -rf "$TMP/real13" "$TMP/view13"
else
  printf 'SKIP: the bind-mounted view of a registered root: no unprivileged mount namespace here\n'
fi
rm -rf "$TMP/gone13" "$TMP/new13" "$TMP/own13"
printf '%s\n%s\n%s\n%s\n' "$A" "$B" "$C" "$S" > "$ENG/projects.conf"

# ── registered roots that no longer exist on disk (the rm case) ──
GONE="$TMP/gone/vanished"; GONE2="$TMP/gone/crlf-gone"; GONE3="$TMP/gone/unique-name-gone"
printf '%s/\n%s\r\n%s\n' "$GONE" "$GONE2" "$GONE3" > "$ENG/projects.conf"
r="$(res "$GONE")"
ok "resolve finds a missing root registered with a trailing slash (PRJ_ROOT is the line's text)" [ "$r" = "$GONE/|$GONE/.ai-containers" ]
r="$(res "$GONE2")"
ok "resolve finds a missing root on a CRLF line" [ "$r" = "$GONE2|$GONE2/.ai-containers" ]
r="$(res "unique-name-gone")"
ok "resolve finds a missing root by its unique basename" [ "$r" = "$GONE3|$GONE3/.ai-containers" ]
# The trailing slash is taken off the argument too: a root that is gone has no
# physical directory to match it by, only its text.
r="$(res "$GONE3//")"
ok "resolve finds a missing root given with trailing slashes" [ "$r" = "$GONE3|$GONE3/.ai-containers" ]
r="$(res "")"; rc=$?
ok "resolve refuses an empty argument, rc 1" bash -c '[ "$1" = 1 ] && [[ "$2" == *"ERROR: no project given."* ]]' _ "$rc" "$r"

# ── projects.conf edits ──
cp "$ENG/projects.conf" "$TMP/conf.orig"
printf '# comment\n\n/a/one\r\n/b/two words\n/c/three' > "$ENG/projects.conf"
( source "$P" && prj_conf_remove "/a/one" )
printf '# comment\n\n/b/two words\n/c/three' > "$TMP/expect"
ok "prj_conf_remove keeps every other byte (CRLF, space, no final newline)" cmp -s "$ENG/projects.conf" "$TMP/expect"
printf '# comment\n\n/a/one\r\n/b/two words\n/c/three' > "$ENG/projects.conf"
( source "$P" && prj_conf_remove "/c/three" )
printf '# comment\n\n/a/one\r\n/b/two words\n' > "$TMP/expect"
ok "prj_conf_remove of the last line (no final newline) keeps the rest" cmp -s "$ENG/projects.conf" "$TMP/expect"

printf '# comment\n\n/a/one\r\n/b/two words\n/c/three' > "$ENG/projects.conf"
( source "$P" && prj_conf_replace "/a/one" "/z/moved dir" && prj_conf_replace "/c/three" "/y/new" )
printf '# comment\n\n/z/moved dir\r\n/b/two words\n/y/new' > "$TMP/expect"
ok "prj_conf_replace rewrites the line in place (CR kept)" cmp -s "$ENG/projects.conf" "$TMP/expect"

printf '/a/one\n/c/three' > "$ENG/projects.conf"
( source "$P" && prj_conf_add "/d/four" && prj_conf_add "/d/four" && prj_conf_add "/a/one" )
printf '/a/one\n/c/three\n/d/four\n' > "$TMP/expect"
ok "prj_conf_add appends once (and not a line already there)" cmp -s "$ENG/projects.conf" "$TMP/expect"
rm -f "$ENG/projects.conf"
( source "$P" && prj_conf_add "/a/one" )
ok "prj_conf_add creates a missing projects.conf" bash -c '[ "$(cat "$1")" = "/a/one" ]' _ "$ENG/projects.conf"
printf '/a/one\n' > "$ENG/projects.conf"; chmod 640 "$ENG/projects.conf"
( source "$P" && prj_conf_add "/b/two" )
m="$(ls -l "$ENG/projects.conf" | cut -c1-10)"
ok "a rewrite keeps the file's mode" [ "$m" = "-rw-r-----" ]
ok "a rewrite leaves no temp file behind" bash -c '[ -z "$(ls -A "$1" | grep "^\.projects")" ]' _ "$ENG"

# a link or non-regular projects.conf
printf '/a/one\n' > "$TMP/real-conf"; rm -f "$ENG/projects.conf"; ln -s "$TMP/real-conf" "$ENG/projects.conf"
( source "$P" && prj_conf_remove "/a/one" ) > "$TMP/err" 2>&1; rc=$?
ok "a linked projects.conf is refused and its target unchanged" \
  bash -c '[ "$1" != 0 ] && grep -q ERROR "$2" && [ "$(cat "$3")" = "/a/one" ] && [ -L "$4" ]' _ "$rc" "$TMP/err" "$TMP/real-conf" "$ENG/projects.conf"
rm -f "$ENG/projects.conf"; mkdir "$ENG/projects.conf"
( source "$P" && prj_conf_add "/x" ) > "$TMP/err" 2>&1; rc=$?
ok "a projects.conf that is a directory is refused" bash -c '[ "$1" != 0 ] && grep -q ERROR "$2"' _ "$rc" "$TMP/err"
rmdir "$ENG/projects.conf"

# ── image-projects.conf ──
printf 'sha256:aaa|/p/one\nsha256:bbb|/p/two\nsha256:aaa|/p/one-again\nsha256:aaaa|/p/three\n' > "$IP"
( source "$P" && prj_image_projects_drop "sha256:aaa" )
printf 'sha256:bbb|/p/two\nsha256:aaaa|/p/three\n' > "$TMP/expect"
ok "prj_image_projects_drop removes exactly the lines of that id" cmp -s "$IP" "$TMP/expect"
rm -f "$IP"
( source "$P" && prj_image_projects_drop "sha256:aaa" ); rc=$?
ok "prj_image_projects_drop with no file is rc 0 and writes nothing" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ]' _ "$rc" "$IP"

# ── M3a: a linked image-projects.conf ──
printf 'sha256:aaa|/p/one\n' > "$TMP/real-ip"; ln -s "$TMP/real-ip" "$IP"
( source "$P" && prj_image_projects_drop "sha256:aaa" ) > "$TMP/err" 2>&1; rc=$?
ok "a linked image-projects.conf is refused and its target unchanged" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3")" = "sha256:aaa|/p/one" ] && [ -L "$4" ]' _ "$rc" "$TMP/err" "$TMP/real-ip" "$IP"
rm -f "$IP"

# ── M3b: a failed rewrite leaves no temp file ──
mkdir -p "$TMP/rw"; printf 'x\n' > "$TMP/rw/target"
( source "$P" && _prj_rewrite "$TMP/rw/target" "$TMP/rw/no-such-new-content" ) > /dev/null 2>&1; rc=$?
ok "a failed rewrite is rc 1, leaves no temp file, and the target is unchanged" \
  bash -c '[ "$1" = 1 ] && [ "$(ls -A "$2")" = target ] && [ "$(cat "$2/target")" = x ]' _ "$rc" "$TMP/rw"

# ── a registry edit whose new content cannot be written changes nothing ──
fake_mktemp
edit_fails() {  # <how> <assertion>: each edit, its new content unwritable, is rc 1 with ERROR: and changes nothing
  local how="$1" bad="" op rc
  printf '# c\n/a/one\r\n/b/two\n/c/three' > "$ENG/projects.conf"; cp "$ENG/projects.conf" "$TMP/conf.orig"
  printf 'sha256:aaa|/p/one\nsha256:bbb|/p/two\n' > "$IP"; cp "$IP" "$TMP/ip.orig"
  for op in "prj_conf_remove /b/two" "prj_conf_replace /a/one /z/new" "prj_conf_add /d/four" "prj_image_projects_drop sha256:aaa"; do
    # ulimit: /dev/full reads as endless zeros, and an edit that took it for its
    # new content would copy them until the disk filled.
    # shellcheck disable=SC2086  # the op's words, on purpose
    ( ulimit -f 2048; export FAKE_MKTEMP_BAD='.*.new.*' FAKE_MKTEMP_HOW="$how"; source "$P" && $op ) > "$TMP/err" 2>&1; rc=$?
    [[ "$rc" == 1 ]] && grep -q '^ERROR: cannot read .*, or write its new content beside it' "$TMP/err" || bad+=" [$op: rc=$rc $(tr '\n' ' ' < "$TMP/err")]"
    rm -rf "$ENG"/.projects.conf.new.* "$HOME/.ai-containers"/.image-projects.conf.new.*
  done
  cmp -s "$ENG/projects.conf" "$TMP/conf.orig" || bad+=" [projects.conf changed: $(cat "$ENG/projects.conf")]"
  cmp -s "$IP" "$TMP/ip.orig" || bad+=" [image-projects.conf changed: $(cat "$IP")]"
  ok "$2" bash -c '[ -z "$1" ] || { printf "%s\n" "$1"; false; }' _ "$bad"
}
if [[ -e /dev/full ]]; then
  edit_fails full "a registry edit whose every write fails (a full disk) is rc 1 with ERROR:, both registries byte-identical"
else
  printf 'SKIP: a registry edit on a full disk (no /dev/full here)\n'
fi
edit_fails dir "a registry edit whose new content cannot be opened is rc 1 with ERROR:, both registries byte-identical"
rm -f "$TMP/bin/mktemp"
printf '/a/one\n/b/two\n' > "$ENG/projects.conf"
( export TMPDIR="$TMP/no-such-tmpdir"; source "$P" && prj_conf_remove /a/one ) > "$TMP/err" 2>&1; rc=$?
ok "a registry edit writes its new content beside the file, so an unusable TMPDIR does not stop it" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = /b/two ] && [ -z "$(ls -A "$3" | grep "^\.projects")" ]' _ "$rc" "$ENG/projects.conf" "$ENG"
rm -f "$IP"

# ── M5: a read-only registry is rewritten and stays read-only ──
source "$TESTS_HERE/portability.sh"
printf '/a/one\n/b/two\n' > "$ENG/projects.conf"; chmod 444 "$ENG/projects.conf"
( source "$P" && prj_conf_remove "/a/one" ) > "$TMP/err" 2>&1; rc=$?
ok "a 0444 projects.conf has its line removed and is still 0444" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = /b/two ] && [ "$3" = 444 ]' _ "$rc" "$ENG/projects.conf" "$(p_stat_mode "$ENG/projects.conf")"
chmod 644 "$ENG/projects.conf"

# ── M6: an unreadable registry is refused and leaks nothing ──
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: an unreadable projects.conf (running as root, chmod 000 does not stop reads)\n'
else
  printf '/a/one\n' > "$ENG/projects.conf"; chmod 000 "$ENG/projects.conf"
  mkdir -p "$TMP/tmpd"
  ( export TMPDIR="$TMP/tmpd"; source "$P" && prj_conf_remove "/a/one" ) > "$TMP/err" 2>&1; rc=$?
  ok "an unreadable projects.conf is rc 1 with ERROR: and leaves no file in TMPDIR" \
    bash -c '[ "$1" = 1 ] && grep -q "ERROR.*projects.conf" "$2" && [ -z "$(ls -A "$3")" ]' _ "$rc" "$TMP/err" "$TMP/tmpd"
  chmod 644 "$ENG/projects.conf"
fi


out="$(bash "$P" --help 2>&1)"
ok "the usage says what gc --all is for" \
  bash -c '[[ "$1" == *"./project.sh gc  [--all] [--yes]"* && "$1" == *"gc --all offers those too: copies made before owner labels,"* ]]' _ "$out"

# ── the helpers before cmd_rm, on paths no command here takes (GAP-28) ──
# Called by sourcing, so under project.sh's own set -e: a helper that returns
# non-zero as a statement ends the subshell before its `went on` line.

# confirm reads a terminal, so it runs under script(1)'s pty: only y or Y is yes.
if script -qec true /dev/null </dev/null >/dev/null 2>&1; then
  export CONFIRM_P="$P"; got=""
  for a in y Y n yes ""; do
    # shellcheck disable=SC2016  # expanded by the shell script(1) starts
    r="$(printf '%s\n' "$a" | script -qec 'bash -c '\''source "$CONFIRM_P"; confirm Go && echo ANSWER=yes || echo ANSWER=no'\''' /dev/null 2>&1 \
      | tr -d '\r' | grep -o 'ANSWER=[a-z]*')"
    got+="${a:-<empty>}:${r#ANSWER=} "
  done
  ok "confirm at a terminal takes y and Y for yes, anything else for no" [ "$got" = "y:yes Y:yes n:no yes:no <empty>:no " ]
else
  printf 'SKIP: confirm at a terminal (no util-linux script(1) here)\n'
fi

world
( source "$P"; prj_roots; printf 'went on\n' ) > "$TMP/out" 2>&1; rc=$?
ok "prj_roots with no projects.conf lists nothing, rc 0" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "went on" ]' _ "$rc" "$TMP/out"
printf '/a/one\n/b/two\n' > "$ENG/projects.conf"
( source "$P"; prj_roots >&-; printf 'went on\n' ) > "$TMP/out" 2>&1; rc=$?
ok "prj_roots whose output is gone stops quietly, rc 0" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "went on" ]' _ "$rc" "$TMP/out"

# A registry rewrite that fails at each of its steps is rc 1 and changes nothing.
cp "$ENG/projects.conf" "$TMP/conf.orig"
no_temp() { local f; for f in "$ENG"/.projects*; do [ -e "$f" ] && return 1; done; return 0; }
( source "$P"; mktemp() { return 1; }; prj_conf_remove /a/one ) > "$TMP/err" 2>&1; rc=$?
ok "an edit with no room beside the registry for its new content is rc 1, says so, and changes nothing" \
  bash -c '[ "$1" = 1 ] && [ "$(cat "$2")" = "ERROR: cannot write beside $3." ] && cmp -s "$3" "$4"' _ "$rc" "$TMP/err" "$ENG/projects.conf" "$TMP/conf.orig"
( source "$P"; mktemp() { [[ "$*" == *.new.XXXXXX ]] || return 1; command mktemp "$@"; }; prj_conf_remove /a/one ) > "$TMP/err" 2>&1; rc=$?
ok "a rewrite with no temp file beside the registry is rc 1, says only that, and changes nothing" \
  bash -c '[ "$1" = 1 ] && [ "$(cat "$2")" = "ERROR: cannot write beside $3." ] && cmp -s "$3" "$4"' _ "$rc" "$TMP/err" "$ENG/projects.conf" "$TMP/conf.orig"
ok "  ... and leaves no temp file" no_temp
( source "$P"; cp() { return 1; }; prj_conf_remove /a/one ) > "$TMP/err" 2>&1; rc=$?
ok "a rewrite that cannot copy the registry is rc 1 and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: cannot copy $3." "$2" && cmp -s "$3" "$4"' _ "$rc" "$TMP/err" "$ENG/projects.conf" "$TMP/conf.orig"
ok "  ... and leaves no temp file" no_temp
rm -f "$ENG/projects.conf"
( source "$P"; chmod() { return 1; }; prj_conf_add /a/one ) > "$TMP/err" 2>&1; rc=$?
ok "a new registry whose mode cannot be set is rc 1 and not made" bash -c '[ "$1" = 1 ] && [ ! -e "$2" ]' _ "$rc" "$ENG/projects.conf"
ok "  ... and leaves no temp file" no_temp

r="$( source "$P"; _prj_phys "$TMP/link-to-alpha/gone/deeper" )"
ok "_prj_phys spells a path that is gone from its nearest existing ancestor's physical path" [ "$r" = "$(cd "$A" && pwd -P)/gone/deeper" ]
r="$( source "$P"; w() { if _prj_within "$1" "$2"; then printf 1; else printf 0; fi; }; w /x /; w /x ""; w /a/b /a; w /a/b/ /a/; w /ab /a )"
ok "_prj_within: nothing lies in / or in an empty dir; a path lies in itself and below, not beside" [ "$r" = 00110 ]

mv "$HOME/.ai-containers/project-id.key" "$TMP/key.saved"
r="$( source "$P"; if prj_id "$TMP"; then printf 'rc=0'; else printf 'rc=1'; fi )"
ok "prj_id with no key yet is rc 1, and makes none" bash -c '[ "$1" = rc=1 ] && [ ! -e "$2" ]' _ "$r" "$HOME/.ai-containers/project-id.key"
mv "$TMP/key.saved" "$HOME/.ai-containers/project-id.key"

world; mkdir -p "$W/pr/.ai-containers"
printf 'stranger|img|/elsewhere/x\n' > "$FAKE_RUNNING"
r="$( source "$P"; if prj_running "$W/pr"; then printf 'rc=0'; else printf 'rc=%s' "$?"; fi )"
ok "prj_running does not take a container that mounts only something else for the project's" [ "$r" = rc=1 ]
printf 'stranger|img|/elsewhere/x\nmine|img|/elsewhere/y|%s\n' "$W/pr/.ai-containers/.agent-blocked" > "$FAKE_RUNNING"
r="$( source "$P"; if prj_running "$W/pr"; then printf 'rc=0'; else printf 'rc=%s' "$?"; fi )"
ok "prj_running takes the one that mounts something under its .ai-containers" [ "$r" = $'mine\nrc=0' ]
: > "$FAKE_RUNNING"

# A project nested in another registered one has its own working copies; one
# launched from a directory with sandbox-common.sh but no sandbox.sh is no
# launcher's. The labels come from one listing, not an inspect per volume.
world; mkproj "$W/outer"; mkproj "$W/outer/inner"; mkbase app
mkwc app i1 "$W/outer/inner"
mkdir -p "$W/outer/inner/sub"; : > "$W/outer/inner/sub/sandbox-common.sh"
mkwc app s1 "$W/outer/inner/sub"
( source "$P"; prj_workcopies "$W/outer/inner"; printf 'went on\n' ) > "$TMP/out" 2>&1; rc=$?
ok "prj_workcopies of a project inside another lists its own copies, a half launcher's included, rc 0" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ]' _ "$rc" "$TMP/out" \
  $'ai-containers-repo-app--wc-i1|\nai-containers-repo-app--wc-s1|\nwent on'
ok "  ... reading their labels from one docker volume ls" \
  bash -c 'grep -q "^docker volume ls --filter name=ai-containers-repo- --format {{.Name}}" "$1" && ! grep -q "^docker volume inspect" "$1"' _ "$DOCKER_LOG"

: > "$DOCKER_LOG"
# shellcheck disable=SC2154  # _prj_seed_state is project.sh's, sourced from a computed path
( source "$P"; prj_seed_ready; prj_seed_ready; printf 'state=%s\n' "$_prj_seed_state" ) > "$TMP/out" 2>&1; rc=$?
ok "prj_seed_ready looks for the seed image once, and asked again is rc 0" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = state=ok ] && [ "$(grep -c "^docker image inspect ai-containers-seed" "$3")" = 1 ]' _ "$rc" "$TMP/out" "$DOCKER_LOG"

# What an inspection cut short had reported is said after the reason, and only then.
world; mkbase app
mkwc app t1 "$W/x" $'STALE|no route\nBRANCH|feat|2|x\n'
mkwc app t2 "$W/x" $'STALE|no route\n'
r="$( source "$P"; for v in ai-containers-repo-app--wc-t1 ai-containers-repo-app--wc-t2; do
        if prj_copy_risk "$v"; then printf 'rc=0\n'; else printf 'rc=1\n'; fi; done )"
ok "prj_copy_risk names what a copy it could not check holds, after an em dash, and nothing when it holds none" [ "$r" = \
"NOT CHECKED: the remote could not be reached (no route) — and it holds: feat: 2 unpushed commit(s)
rc=1
NOT CHECKED: the remote could not be reached (no route)
rc=1" ]
r="$( exec 2>/dev/null; export FAKE_NO_SEED=1; source "$P"; if prj_copy_risk ai-containers-repo-app--wc-t2; then printf 'rc=0'; else printf 'rc=1'; fi )"
ok "prj_copy_risk with no seed image says not checked, rc 1" [ "$r" = $'NOT CHECKED: the seed helper image (ai-containers-seed) could not be had\nrc=1' ]

world; printf 'ai-containers.built-at=2026-11-14T00:00:00Z\n' > "$IMGS/oldimg"
( source "$P"; prj_image_remove oldimg "sha256:$(printf '%064d' 1)"; printf 'went on, removed=%s\n' "$PRJ_IMAGE_REMOVED" ) > "$TMP/out" 2>&1; rc=$?
ok "an image of this tool that records no project is said to and kept, and that fails nothing" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ] && [ -f "$4" ] && ! grep -q "^docker rmi" "$5"' _ "$rc" "$TMP/out" \
  $'Image oldimg not removed: it records no project (built before images did).\nwent on, removed=0' "$IMGS/oldimg" "$DOCKER_LOG"

world; mkproj "$W/sh"; mkproj "$W/sh2" "" $'SANDBOX_WORKDIR=@wd\n'
( source "$P"; _prj_shared "$W/sh/.ai-containers"; _prj_shared "$W/sh2/.ai-containers"; printf 'went on\n' ) > "$TMP/out" 2>&1; rc=$?
ok "_prj_shared names a working dir only when it is an @repo, rc 0" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ]' _ "$rc" "$TMP/out" $'group default\ngroup default\nrepo wd\nwent on'

printf '|/recorded\nsha256:a|/one\n\nsha256:b|/two' > "$IP"
r="$( source "$P"; _prj_ip_path ""; printf ';'; _prj_ip_path sha256:b; printf ';'; _prj_ip_path sha256:a )"
ok "_prj_ip_path finds nothing for no id, and a line past a blank one or with no final newline" [ "$r" = ";/two;/one" ]
rm -f "$IP"

g() { ( source "$P"; _prj_guard "$@"; printf 'passed\n' ) > "$TMP/out" 2>&1; }
g /.. "the registered root" remove registered; rc=$?
ok "_prj_guard refuses a registered root that is / by another spelling, naming its line to fix" \
  bash -c '[ "$1" = 1 ] && grep -qF "is not an absolute path to a project directory; refusing." "$2" \
    && grep -qF "Fix or remove its line in $3." "$2" && ! grep -q passed "$2"' _ "$rc" "$TMP/out" "$ENG/projects.conf"
g /.. "the new directory" move; rc=$?
ok "_prj_guard refuses that root unregistered, with no line to fix" \
  bash -c '[ "$1" = 1 ] && grep -qF "is not an absolute path to a project directory; refusing." "$2" \
    && ! grep -qF "Fix or remove" "$2"' _ "$rc" "$TMP/out"
g "$HOME" "the registered root" remove registered; rc=$?
ok "_prj_guard refuses a registered project at HOME, saying to remove its line by hand" \
  bash -c '[ "$1" = 1 ] && grep -qxF "       and the registries live; refusing. Remove its line from $3 by hand." "$2"' _ "$rc" "$TMP/out" "$ENG/projects.conf"
g "$HOME" "the new directory" move; rc=$?
ok "_prj_guard refuses HOME unregistered, with no line to remove" \
  bash -c '[ "$1" = 1 ] && grep -qxF "       and the registries live; refusing." "$2"' _ "$rc" "$TMP/out"

echo
# shellcheck disable=SC2154  # fails is the counter tests/lib-project-tool.sh defines
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
