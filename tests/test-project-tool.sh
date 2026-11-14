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
# The fake docker logs every call ("docker <args>") and keeps a small world:
# volumes are directories under $VOLS, each with a `labels` file (key=value
# lines) and, for a working copy, an `inspect` file holding the records the git
# helper's `inspect` prints for it (none: the helper printed nothing); images
# are files under $IMGS holding their labels; running containers are the lines
# of $FAKE_RUNNING, `name|image|mount source|…`. FAKE_FAIL_VOLUME_RM (a glob)
# makes `volume rm` of a matching volume fail, FAKE_FAIL_RMI every `rmi`, and
# FAKE_DOCKER_DOWN every call. The seed image is always there; `info` says
# nothing, so no SELinux option is chosen.
export VOLS="$TMP/vols" IMGS="$TMP/imgs" FAKE_RUNNING="$TMP/running"
mkdir -p "$VOLS" "$IMGS"; : > "$FAKE_RUNNING"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
[[ -z "${FAKE_DOCKER_DOWN:-}" ]] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
lbl() {  # <labels file> <key> → its value; rc 1 when it has none
  local l
  [[ -f "$1" ]] || return 1
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ "${l%%=*}" == "$2" ]]; then printf '%s' "${l#*=}"; return 0; fi
  done < "$1"
  return 1
}
cmd="$1"; shift; sub=""
case "$cmd" in volume|image) sub="$1"; shift ;; esac
fmt=""; filt=(); vs=(); pos=()
while (( $# )); do
  case "$1" in
    --format) fmt="$2"; shift 2 ;;
    --filter) filt+=("$2"); shift 2 ;;
    -v) vs+=("$2"); shift 2 ;;
    -e|--memory|--memory-swap|--pids-limit|--entrypoint|--mount|--label) shift 2 ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
case "$cmd${sub:+ $sub}" in
  "volume ls")
    name=""
    for f in ${filt[@]+"${filt[@]}"}; do [[ "$f" == name=* ]] && name="${f#name=}"; done
    for d in "$VOLS"/*/; do
      [[ -d "$d" ]] || continue
      v="${d%/}"; v="${v##*/}"
      [[ -z "$name" || "$v" == *"$name"* ]] || continue
      if [[ -z "$fmt" ]]; then printf '%s\n' "$v"; continue; fi
      line="$v"; rest="$fmt"
      while [[ "$rest" == *'.Label "'* ]]; do
        rest="${rest#*.Label \"}"; key="${rest%%\"*}"
        val="$(lbl "$VOLS/$v/labels" "$key")" || val=""
        line+=$'\x1f'"\"$val\""
      done
      printf '%s\n' "$line"
    done ;;
  "volume inspect")
    v="${pos[0]}"
    [[ -d "$VOLS/$v" ]] || { echo "Error: no such volume: $v" >&2; exit 1; }
    if [[ "$fmt" == *'index .Labels "'* ]]; then
      k="${fmt#*index .Labels \"}"; k="${k%%\"*}"
      lbl "$VOLS/$v/labels" "$k"; printf '\n'
    else
      printf '%s\n' "$v"
    fi ;;
  "volume rm")
    for v in "${pos[@]}"; do
      # shellcheck disable=SC2053  # a glob on purpose
      if [[ -n "${FAKE_FAIL_VOLUME_RM:-}" && "$v" == $FAKE_FAIL_VOLUME_RM ]]; then
        echo "Error response from daemon: remove $v: volume is in use" >&2; exit 1
      fi
      [[ -d "$VOLS/$v" ]] || { echo "Error: no such volume: $v" >&2; exit 1; }
      rm -rf "$VOLS/$v"
    done ;;
  run)
    for m in ${vs[@]+"${vs[@]}"}; do
      if [[ "$m" == *:/dst ]]; then
        v="${m%:/dst}"
        if [[ -f "$VOLS/$v/inspect" ]]; then cat "$VOLS/$v/inspect"; fi
      fi
    done ;;
  ps)
    anc=""
    for f in ${filt[@]+"${filt[@]}"}; do
      case "$f" in ancestor=*) anc="${f#ancestor=}" ;; volume=*) exit 0 ;; esac
    done
    while IFS='|' read -r n img _; do
      [[ -n "$n" ]] || continue
      if [[ -z "$anc" || "$img" == "$anc" ]]; then printf '%s\n' "$n"; fi
    done < "$FAKE_RUNNING" ;;
  inspect)
    while IFS= read -r l; do
      [[ "${l%%|*}" == "${pos[0]}" ]] || continue
      rest="${l#*|}"; rest="${rest#*|}"
      IFS='|' read -r -a srcs <<< "$rest"
      for s in ${srcs[@]+"${srcs[@]}"}; do printf '%s\n' "$s"; done
    done < "$FAKE_RUNNING" ;;
  "image inspect")
    i="${pos[0]}"
    [[ "$i" == ai-containers-seed ]] && exit 0
    f="$IMGS/$i"
    [[ -f "$f" ]] || { echo "Error: No such image: $i" >&2; exit 1; }
    case "$fmt" in
      *'json .Config.Labels'*)
        j=""
        while IFS= read -r l; do
          [[ -n "$l" ]] || continue
          j+="${j:+,}\"${l%%=*}\":\"${l#*=}\""
        done < <(LC_ALL=C sort "$f")
        if [[ -n "$j" ]]; then printf '{%s}\n' "$j"; else printf 'null\n'; fi ;;
      *'index .Config.Labels "'*)
        k="${fmt#*index .Config.Labels \"}"; k="${k%%\"*}"
        lbl "$f" "$k" || printf '<no value>'
        printf '\n' ;;
      *) printf '[{"Id":"sha256:%s"}]\n' "$i" ;;
    esac ;;
  images)
    for f in ${filt[@]+"${filt[@]}"}; do
      [[ "$f" == label=* ]] || continue
      for g in "$IMGS"/*; do
        if [[ -f "$g" ]] && grep -qxF -- "${f#label=}" "$g"; then printf '%s\n' "${g##*/}"; fi
      done
    done ;;
  rmi)
    [[ -z "${FAKE_FAIL_RMI:-}" ]] || { echo "Error: conflict: the image is used by a stopped container" >&2; exit 1; }
    for i in "${pos[@]}"; do
      [[ -f "$IMGS/$i" ]] || { echo "Error: No such image: $i" >&2; exit 1; }
      rm -f "$IMGS/$i"
    done ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/docker"
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
ok "rm reaches project.sh's own cmd_rm, not repo.sh's (which says Nothing to remove, rc 0)" \
  bash -c '[ "$1" = 1 ] && [[ "$2" == *"not a registered project"* ]]' _ "$rc" "$out"
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

# ── rm ──
# The project id build.sh stamps on an image and records in image-projects.conf,
# derived here from a key of the test's own rather than by project.sh's code.
KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
rm -f "$HOME/.ai-containers/project-id.key"
( umask 077; printf '%s\n' "$KEY" > "$HOME/.ai-containers/project-id.key" )
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
tid() { printf 'sha256:%s' "$(printf '%s\n%s' "$KEY" "$(cd "$1" && pwd -P)" | sha256)"; }   # <existing dir>

W="$TMP/rmw"
world() {   # nothing registered, built, recorded, running or logged
  [[ -d "$W" ]] && chmod -R u+rwx "$W" 2>/dev/null
  rm -rf "$VOLS" "$IMGS" "$W"; mkdir -p "$VOLS" "$IMGS" "$W"
  : > "$FAKE_RUNNING"; : > "$DOCKER_LOG"; rm -f "$ENG/projects.conf" "$IP"
  unset FAKE_FAIL_VOLUME_RM FAKE_FAIL_RMI FAKE_DOCKER_DOWN
}
# mkproj <root> [<sandbox.env text>] [<sandbox.local.env text>]: a registered project
mkproj() {
  mkdir -p "$1/.ai-containers"
  printf '%s' "${2-}" > "$1/.ai-containers/sandbox.env"
  if [[ -n "${3-}" ]]; then printf '%s' "$3" > "$1/.ai-containers/sandbox.local.env"; fi
  printf '#!/bin/sh\n' > "$1/.ai-containers/runme.sh"
  printf '%s\n' "$1" >> "$ENG/projects.conf"
}
# built <root> <image>: the image build.sh made for that project, and its record
built() {
  local id; id="$(tid "$1/.ai-containers")"
  printf 'ai-containers.built-at=2026-11-14T00:00:00Z\nai-containers.project=%s\n' "$id" > "$IMGS/$2"
  printf '%s|%s\n' "$id" "$(cd "$1/.ai-containers" && pwd -P)" >> "$IP"
}
mkvol()  { mkdir -p "$VOLS/$1"; printf '%s\n' "${@:2}" > "$VOLS/$1/labels"; }
mkbase() { mkvol "ai-containers-repo-$1" "ai-containers.repo=$1" "ai-containers.type=${2:-git}" "ai-containers.source=https://example.invalid/$1.git"; }
# mkwc <repo> <tag> <launch dir> [<inspect records>]: a working copy of <repo>
mkwc() {
  local v="ai-containers-repo-$1--wc-$2"
  mkvol "$v" "ai-containers.workcopy=1" "ai-containers.repo=$1" "ai-containers.launch-dir=$3"
  if [[ -n "${4-}" ]]; then printf '%s' "$4" > "$VOLS/$v/inspect"; fi
}
CLEAN=$'PRIMARY|main\nBRANCH|main|0|current\nWORKTREE|clean\nEND|inspect\n'
rmrun() { ( cd "$TMP" && bash "$P" rm "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
hasx()  { grep -qxF -- "$1" "$TMP/out"; }
lacks() { ! grep -qF -- "$1" "$TMP/out"; }
logged() { grep -qE -- "$1" "$DOCKER_LOG"; }

# the whole of it, by --yes
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$W/beta/.ai-containers"; printf '%s\n' "$W/beta" >> "$ENG/projects.conf"
printf 'sha256:keep-me|/elsewhere\n' >> "$IP"; built "$A" img-alpha
ida="$(tid "$A/.ai-containers")"
rmrun "$A" --yes; rc=$?
ok "rm removes .ai-containers, its projects.conf line and its image-projects.conf line" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && ! grep -qxF "$2" "$3" && grep -qxF "$4" "$3" \
           && ! grep -qF "$5" "$6" && grep -qxF "sha256:keep-me|/elsewhere" "$6"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$W/beta" "$ida" "$IP"
ok "rm removes the image whose label is this project's id, without --force" \
  bash -c '[ ! -e "$1" ] && grep -qxF "docker rmi img-alpha" "$2" && ! grep "^docker rmi" "$2" | grep -q -- "-f"' \
  _ "$IMGS/img-alpha" "$DOCKER_LOG"
listing() { hasx "  directory   $A/.ai-containers" && hasx "  registry    $A (projects.conf)" && hasx "  image       img-alpha"; }
ok "rm --yes still prints the listing" listing

# the image: only the one this project's id is on
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-shared\n'
printf 'ai-containers.project=sha256:%064d\n' 7 > "$IMGS/img-shared"
rmrun "$A" --yes; rc=$?
ok "rm keeps an IMAGE_NAME whose label is another project's id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       img-shared — kept: " "$4"' \
  _ "$rc" "$IMGS/img-shared" "$DOCKER_LOG" "$TMP/out"
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=ubuntu:24.04\n'
printf 'org.opencontainers.image.title=Ubuntu\n' > "$IMGS/ubuntu:24.04"
rmrun "$A" --yes; rc=$?
ok "rm keeps an IMAGE_NAME with no ai-containers labels" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       ubuntu:24.04 — kept: " "$4"' \
  _ "$rc" "$IMGS/ubuntu:24.04" "$DOCKER_LOG" "$TMP/out"

# the working copies launched from it, in either spelling of its path
world
mkdir -p "$W/real/alpha" "$W/real/alphax"; ln -s "$W/real" "$W/lnk"
A="$W/lnk/alpha"; mkproj "$A"; mkproj "$W/beta"; mkbase app; mkbase lib
mkwc app 1 "$A/.ai-containers" "$CLEAN"
mkwc app 2 "$W/real/alpha/.ai-containers" "$CLEAN"
mkwc lib 3 "$W/real/alpha/sub" "$CLEAN"
mkwc app 4 "$W/beta/.ai-containers" "$CLEAN"
mkwc app 5 "$W/real/alphax/.ai-containers" "$CLEAN"
mkvol ai-containers-repo-app--wc-6 "ai-containers.workcopy=1" "ai-containers.repo=app"
rmrun "$A" --yes; rc=$?
printf '%s\n' ai-containers-repo-app--wc-1 ai-containers-repo-app--wc-2 ai-containers-repo-lib--wc-3 > "$TMP/expect"
ok "rm removes exactly the working copies launched from this project" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2" | LC_ALL=C sort)" = "$(cat "$3")" ]' _ "$rc" "$DOCKER_LOG" "$TMP/expect"

world
O="$W/outer"; mkproj "$O"; mkproj "$O/inner"; mkbase app
mkwc app 1 "$O/.ai-containers" "$CLEAN"; mkwc app 2 "$O/inner/.ai-containers" "$CLEAN"
rmrun "$O" --yes; rc=$?
ok "rm leaves a working copy launched from a nested registered project" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2")" = ai-containers-repo-app--wc-1 ] \
           && [ -d "$3/ai-containers-repo-app--wc-2" ] && [ -d "$4/inner/.ai-containers" ] && grep -qxF "$4/inner" "$5"' \
  _ "$rc" "$DOCKER_LOG" "$VOLS" "$O" "$ENG/projects.conf"

# what a working copy would lose, listed before the question
risk() {  # <base type> <records>: one copy of app, listed; the answer is no
  world; A="$W/alpha"; mkproj "$A"; mkbase app "$1"
  mkwc app 1 "$A/.ai-containers" "$2"
  rmrun "$A"
}
copy_line() { grep -F "  working copy ai-containers-repo-app--wc-$1 (app) — " "$TMP/out"; }
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkwc app 1 "$A/.ai-containers" $'PRIMARY|main\nBRANCH|main|0|current\nBRANCH|feature|2|\nWORKTREE|clean\nEND|inspect\n'
mkwc app 2 "$A/.ai-containers" "$CLEAN"
rmrun "$A"
ok "rm lists a copy with 2 unpushed commits as at risk" \
  bash -c '[[ "$1" == *"AT RISK"*"feature"*"2 unpushed"* ]] && [[ "$2" != *"AT RISK"* ]] \
           && grep -qxF "1 working cop(y/ies) at risk or not checked." "$3"' _ "$(copy_line 1)" "$(copy_line 2)" "$TMP/out"
risk git $'PRIMARY|main\nBRANCH|main|0|current\nWORKTREE|changed\nEND|inspect\n'
ok "rm lists a copy with WORKTREE|changed as holding uncommitted work" \
  bash -c '[[ "$1" == *"AT RISK"*"uncommitted work"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk path ""
ok "rm lists a copy of a path repo as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"path repo"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'STALE|could not clone\nBRANCH|main|?|current\nWORKTREE|?\nEND|inspect\n'
ok "rm lists a copy whose remote is STALE as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"could not clone"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'NESTED|vendor/lib\nPRIMARY|main\nBRANCH|main|0|current\nSTASH|2\nTAG|v5|no|no\nTAG|v6|moved|?\nTAG|v7|yes|yes\nWORKTREE|?\nEND|inspect\n'
ok "rm lists a stash, tags whose commit may be on no remote, a nested repository and an unknown checkout as at risk" \
  bash -c '[[ "$1" == *"AT RISK"* && "$1" == *"a stash (2"* && "$1" == *"tag v5"* && "$1" == *"tag v6"* && "$1" != *"tag v7"* \
            && "$1" == *"vendor/lib"* && "$1" == *"uncommitted work unknown"* ]]' _ "$(copy_line 1)"
# kept by the remote as repo.sh reset counts it: the tag itself, another on its
# commit, or the commit on a remote branch or tag
risk git $'PRIMARY|main\nBRANCH|main|0|current\nTAG|v1|yes|yes\nTAG|v2|same|no\nTAG|v3|moved|yes\nTAG|v4|no|yes\nWORKTREE|clean\nEND|inspect\n'
ok "rm lists a copy whose tags the remote keeps as nothing at risk" \
  bash -c '[[ "$1" == *"nothing at risk"* ]] && ! grep -q "at risk or not checked" "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'PRIMARY|main\nBRANCH|main|0|current\n'
ok "rm lists a copy whose inspection was cut short as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"cut short"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"

# the question, and what stops it
unchanged() {  # <root> <id>: nothing of the project was removed
  [[ -d "$1/.ai-containers" ]] && grep -qxF -- "$1" "$ENG/projects.conf" && grep -qF -- "$2" "$IP" \
    && ! logged '^docker (volume rm|rmi)'
}
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
rmrun "$A"; rc=$?
ok "rm refuses on a non-TTY without --yes and changes nothing" \
  bash -c '[ "$1" != 0 ] && grep -q "ERROR" "$2" && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' \
  _ "$rc" "$TMP/out" "$VOLS" "$IMGS/img-alpha"
ok "  … and the directory and both lines are intact" unchanged "$A" "$ida"

printf 'ctr-one|other-image|/somewhere|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING"; : > "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "rm refuses while a container mounts the project's .ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-one" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
printf 'ctr-two|img-alpha|/somewhere\n' > "$FAKE_RUNNING"; : > "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "rm refuses while a container runs its image" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-two" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
world
mkdir -p "$W/real"; ln -s "$W/real" "$W/lnk"; L="$W/lnk/alpha"; mkproj "$L"
printf 'ctr-three|other-image|%s/.ai-containers\n' "$(cd "$W/real/alpha" && pwd -P)" > "$FAKE_RUNNING"
rmrun "$L" --yes; rc=$?
ok "rm refuses while a container mounts the project's .ai-containers by its physical path" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-three" "$2" && [ -d "$3/.ai-containers" ]' _ "$rc" "$TMP/out" "$L"
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'
export FAKE_DOCKER_DOWN=1
rmrun "$A" --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "rm refuses when docker cannot be reached, and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR" "$2" && [ -d "$3/.ai-containers" ] && grep -qxF "$3" "$4"' \
  _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf"

# groups and repos no other registered project uses are named, never removed
world
mkproj "$W/a1" $'AI_CONTAINER_GROUP=lonely\n' $'REPOS="solo:ro shared:rw"\nSPECS_PATH=@specsolo\n'
mkproj "$W/a2" $'AI_CONTAINER_GROUP=team\n' $'SPECS_PATH=@specshared\n'
mkproj "$W/a3" ''
mkproj "$W/b" $'AI_CONTAINER_GROUP=team\n' $'REPOS=shared:rwcopy\nDOCS_PATH=@specshared:ro\n'
mkdir -p "$W/gone"; printf '%s\n' "$W/gone" >> "$ENG/projects.conf"   # its .ai-containers deleted by hand
rmrun "$W/a1" --yes; cp "$TMP/out" "$TMP/out1"
ok "rm names an unused group with ./group.sh rm" \
  hasx "NOTE: group lonely is used by no other registered project; remove it with ./group.sh rm lonely"
ok "rm names an unused REPOS repo with ./repo.sh rm" \
  hasx "NOTE: repo solo is used by no other registered project; remove it with ./repo.sh rm solo"
ok "rm does not name a REPOS repo another project uses" lacks "NOTE: repo shared "
ok "rm names an unused SPECS_PATH=@name repo with ./repo.sh rm" \
  hasx "NOTE: repo specsolo is used by no other registered project; remove it with ./repo.sh rm specsolo"
rmrun "$W/a2" --yes
ok "rm does not name a group another project uses" lacks "NOTE: group team "
ok "rm does not name a SPECS_PATH=@name repo another project uses" lacks "NOTE: repo specshared "
rmrun "$W/a3" --yes
ok "rm does not count a registered project whose .ai-containers is gone as using a group" \
  hasx "NOTE: group default is used by no other registered project; remove it with ./group.sh rm default"
ok "rm names nothing shared for a project that set nothing but the group" \
  bash -c '[ "$(grep -c "^NOTE: " "$1")" = 1 ]' _ "$TMP/out"

# the root it leaves
world
mkproj "$W/empty-after"; mkproj "$W/with-files"; printf 'hi\n' > "$W/with-files/README"
rmrun "$W/empty-after" --yes; rc1=$?
ok "rm removes the project root when it is left empty" bash -c '[ "$1" = 0 ] && [ ! -e "$2" ]' _ "$rc1" "$W/empty-after"
ok "  … and lists it first" hasx "  directory   $W/empty-after (it holds nothing else)"
rmrun "$W/with-files" --yes; rc2=$?
ok "rm keeps a root with other files" \
  bash -c '[ "$1" = 0 ] && [ "$(ls -A "$2")" = README ]' _ "$rc2" "$W/with-files"
ok "  … and does not list it" lacks "  directory   $W/with-files (it holds nothing else)"

# asking for an id makes no key
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
mv "$HOME/.ai-containers/project-id.key" "$TMP/key.saved"
rmrun "$A" --yes; rc=$?
ok "rm makes no project-id.key where there was none, and keeps the image it cannot tie to this project" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -e "$3" ]' _ "$rc" "$HOME/.ai-containers/project-id.key" "$IMGS/img-alpha"
rm -f "$HOME/.ai-containers/project-id.key"; mv "$TMP/key.saved" "$HOME/.ai-containers/project-id.key"

# what it refuses to follow or touch
world
mkdir -p "$W/target-dir" "$W/linky"; printf 'keep\n' > "$W/target-dir/sandbox.env"
ln -s "$W/target-dir" "$W/linky/.ai-containers"; printf '%s\n' "$W/linky" >> "$ENG/projects.conf"
mkbase app; mkwc app 1 "$W/linky/.ai-containers" "$CLEAN"
rmrun "$W/linky" --yes; rc=$?
ok "rm refuses a .ai-containers that is a symlink, and the link's target is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ -L "$3/.ai-containers" ] && [ "$(cat "$4/sandbox.env")" = keep ] \
           && grep -qxF "$3" "$5" && ! grep -q "^docker volume rm" "$6"' \
  _ "$rc" "$TMP/out" "$W/linky" "$W/target-dir" "$ENG/projects.conf" "$DOCKER_LOG"
ok "  … before anything is listed or removed" lacks "About to remove"

# the same directory registered under another spelling is this project, not one inside it
world
A="$W/alpha"; mkproj "$A"; ln -s . "$A/self"; printf '%s\n' "$A/self" >> "$ENG/projects.conf"; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm takes the same directory registered under another spelling as this project, not a nested one" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2")" = ai-containers-repo-app--wc-1 ]' _ "$rc" "$DOCKER_LOG"

# an image that cannot be removed keeps the record that names it
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
export FAKE_FAIL_RMI=1
rmrun "$A" --yes; rc=$?
unset FAKE_FAIL_RMI
ok "rm keeps the image-projects.conf line while the image it could not remove carries the id, and finishes the rest" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && ! grep -qxF "$5" "$6" && [ ! -e "$5/.ai-containers" ]' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$A" "$ENG/projects.conf"

world
printf '/\n' > "$ENG/projects.conf"
if [[ -e /.ai-containers ]]; then
  printf 'SKIP: a registered root of / (this machine has a /.ai-containers)\n'
else
  rmrun / --yes; rc=$?
  ok "rm refuses a registered root of / and changes nothing" \
    bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3")" = / ]' _ "$rc" "$TMP/out" "$ENG/projects.conf"
fi
world
mkdir -p "$W/cwd/relproj/.ai-containers"; printf 'relproj\n' > "$ENG/projects.conf"
( cd "$W/cwd" && bash "$P" rm relproj --yes ) > "$TMP/out" 2>&1 < /dev/null; rc=$?
ok "rm refuses a registered root that is not absolute and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ -d "$3/relproj/.ai-containers" ] && [ "$(cat "$4")" = relproj ]' \
  _ "$rc" "$TMP/out" "$W/cwd" "$ENG/projects.conf"

world
S="$W/my proj"; mkproj "$S" $'IMAGE_NAME=img-space\n'; built "$S" img-space; mkbase app
mkwc app 1 "$S/.ai-containers" "$CLEAN"
rmrun "$S" --yes; rc=$?
ok "rm works on a project whose path has a space" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && ! grep -qF "$2" "$3" && [ ! -e "$4" ] && [ ! -e "$5/ai-containers-repo-app--wc-1" ] && [ ! -s "$6" ]' \
  _ "$rc" "$S" "$ENG/projects.conf" "$IMGS/img-space" "$VOLS" "$IP"

# a failure part-way leaves what a re-run needs to finish
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
export FAKE_FAIL_VOLUME_RM='*'
rmrun "$A" --yes; rc=$?
unset FAKE_FAIL_VOLUME_RM
ok "rm keeps the projects.conf line when a working copy cannot be removed" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -qxF "$3" "$4" && [ -d "$3/.ai-containers" ] && [ -e "$5" ] \
           && ! grep -q "^docker rmi" "$6"' _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$IMGS/img-alpha" "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "  … and a re-run with the volume removable completes" \
  bash -c '[ "$1" = 0 ] && ! grep -qxF "$2" "$3" && [ ! -e "$2" ] && [ ! -d "$4/ai-containers-repo-app--wc-1" ] && ! grep -qF "$5" "$6"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$VOLS" "$ida" "$IP"

if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: an .ai-containers that cannot be removed (running as root)\n'
else
  world
  A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
  mkdir -p "$A/.ai-containers/stuck"; printf 'x\n' > "$A/.ai-containers/stuck/file"; chmod 555 "$A/.ai-containers/stuck"
  rmrun "$A" --yes; rc=$?
  ok "rm keeps both registry lines when .ai-containers cannot be removed" \
    bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -qxF "$3" "$4" && grep -qF "$5" "$6"' \
    _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$ida" "$IP"
  chmod 755 "$A/.ai-containers/stuck"
fi

world
A="$W/alpha"; mkdir -p "$A/.ai-containers"
printf '# comment\n\n%s\r\n/b/two words\n/c/three' "$A" > "$ENG/projects.conf"
rmrun "$A" --yes; rc=$?
printf '# comment\n\n/b/two words\n/c/three' > "$TMP/expect"
ok "rm keeps every other projects.conf byte" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$ENG/projects.conf" "$TMP/expect"

# a project whose .ai-containers was already deleted by hand
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
rm -f "$IMGS/img-alpha"; rm -rf "$A/.ai-containers"; printf 'hi\n' > "$A/README"
rmrun "$A" --yes; rc=$?
ok "rm finishes a project whose .ai-containers is already gone" \
  bash -c '[ "$1" = 0 ] && ! grep -qxF "$2" "$3" && ! grep -qF "$4" "$5" && [ ! -d "$6/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  image       (unknown — no sandbox.env; ./project.sh gc removes it by its label)" "$7"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$ida" "$IP" "$VOLS" "$TMP/out"

echo
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
