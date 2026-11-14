#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# project.sh: the front door (init/report/sync pass through), project naming
# (prj_resolve), and the registry edits (projects.conf, image-projects.conf).
# Hermetic: HOME and an engine copy live in a temp dir; docker is a logging fake.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
ok()   { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR
unset SANDBOX_UID SANDBOX_GID XDG_CONFIG_HOME
export HOME="$TMP/home"; mkdir -p "$HOME"
ENG="$TMP/engine"; mkdir -p "$ENG" "$TMP/bin"
( cd "$REPO_DIR" && git ls-files -z '*.sh' Dockerfile.seed projects.conf.example | grep -zv '^tests/' \
    | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname "{}")" && cp -p "{}" "$1/{}"' _ "$ENG" )
cp -p "$REPO_DIR/project.sh" "$ENG/project.sh"   # tracked once committed; copied by name so a fresh one is seen
export DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
printf '#!/bin/sh\necho "docker $*" >> "$DOCKER_LOG"\nexit 0\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
STUBLOG="$TMP/stub.log"; : > "$STUBLOG"
for s in project-init ai-containers-report sync-to-projects; do
  printf '#!/bin/sh\necho "%s.sh $*" >> "%s"\nexit 7\n' "$s" "$STUBLOG" > "$ENG/$s.sh"
done
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
ok "rm reaches project.sh's own stub, not repo.sh's cmd_rm" bash -c '[ "$1" = 1 ] && [[ "$2" == *"not yet"* ]]' _ "$rc" "$out"
out="$(bash "$P" gc 2>&1)"; rc=$?
ok "gc reaches project.sh's own stub, not repo.sh's cmd_gc" bash -c '[ "$1" = 1 ] && [[ "$2" == *"not yet"* ]]' _ "$rc" "$out"

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

# ── registered roots that no longer exist on disk (the rm case) ──
GONE="$TMP/gone/vanished"; GONE2="$TMP/gone/crlf-gone"; GONE3="$TMP/gone/unique-name-gone"
printf '%s/\n%s\r\n%s\n' "$GONE" "$GONE2" "$GONE3" > "$ENG/projects.conf"
r="$(res "$GONE")"
ok "resolve finds a missing root registered with a trailing slash (PRJ_ROOT is the line's text)" [ "$r" = "$GONE/|$GONE/.ai-containers" ]
r="$(res "$GONE2")"
ok "resolve finds a missing root on a CRLF line" [ "$r" = "$GONE2|$GONE2/.ai-containers" ]
r="$(res "unique-name-gone")"
ok "resolve finds a missing root by its unique basename" [ "$r" = "$GONE3|$GONE3/.ai-containers" ]

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
mkdir -p "$HOME/.ai-containers"
IP="$HOME/.ai-containers/image-projects.conf"
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

# ── M5: a read-only registry is rewritten and stays read-only ──
source "$REPO_DIR/tests/portability.sh"
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

echo
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
