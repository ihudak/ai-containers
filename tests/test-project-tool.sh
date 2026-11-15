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
# SIGPIPE ignored, as GitHub's hosted runners start every step, and as it stays
# in what they start: a loop that stops reading a pipe early then makes its
# writer fail with EPIPE rather than end quietly, and bash prints "write error:
# Broken pipe" into project.sh's output. Elsewhere SIGPIPE is at its default and
# the same code was silent, so only CI's suite jobs failed (project.sh: `prj_roots()`).
trap '' PIPE
ENG="$TMP/engine"; mkdir -p "$ENG" "$TMP/bin"
# The engine is listed by git BEFORE HOME moves: a checkout owned by another
# user (the floor container runs as root against the host user's mount) is
# trusted only by safe.directory in the real HOME's global config, and with
# HOME in $TMP git refused it and the copy came out empty.
( cd "$REPO_DIR" && git ls-files -z '*.sh' Dockerfile.seed projects.conf.example | grep -zv '^tests/' \
    | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname "{}")" && cp -p "{}" "$1/{}"' _ "$ENG" )
cp -p "$REPO_DIR/project.sh" "$ENG/project.sh"   # tracked once committed; copied by name so a fresh one is seen
[[ -f "$ENG/sandbox-common.sh" && -f "$ENG/repo.sh" ]] \
  || { printf 'SCAFFOLD-FAILED: the engine copy is incomplete (git ls-files in %s)\n' "$REPO_DIR"; exit 1; }
unset SANDBOX_UID SANDBOX_GID XDG_CONFIG_HOME
export HOME="$TMP/home"; mkdir -p "$HOME"
export DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
# The fake docker logs every call ("docker <args>") and keeps a small world:
# volumes are directories under $VOLS, each with a `labels` file (key=value
# lines) and, for a working copy, an `inspect` file holding the records the git
# helper's `inspect` prints for it (none: the helper printed nothing); images
# are files under $IMGS holding their labels; running containers are the lines
# of $FAKE_RUNNING, `name|image|mount source|…`, and once more than
# $FAKE_RUNNING_AFTER `ps` calls (not counting a volume= filter) have been made,
# those of $FAKE_RUNNING.later. A `ps --filter volume=<v>` names the lines with
# a mount source /var/lib/docker/volumes/<v>/_data (where docker keeps a named
# volume), and is counted apart: once more than $FAKE_VOLPS_AFTER of them have
# been made, from $FAKE_RUNNING.later. With -a it also names the stopped
# containers, the lines of $FAKE_STOPPED (same form); `volume rm` of a volume
# a line of $FAKE_RUNNING or $FAKE_STOPPED mounts fails, as docker's does. An
# image is named by its file: `x` is
# also `x:latest`, and `images --format` gives it repository `x`, tag `latest`
# and id `x`, or repository and tag `<none>` for a file named `dangling-…` (an
# image with no tag, removed by its id). An image file with a `.next` beside it is
# replaced by that after its first `image inspect`. FAKE_FAIL_VOLUME_RM (a glob)
# makes `volume rm` of a matching volume fail, FAKE_FAIL_RMI every `rmi`,
# FAKE_PS_FAIL every `ps` (=ancestor: only the one with an ancestor= filter),
# and FAKE_DOCKER_DOWN every call. The seed image is
# there unless FAKE_NO_SEED, which also fails `build`; `info` says nothing, so no
# SELinux option is chosen. A volume's files are its `data` directory: a `run`
# whose script is an rsync copies /src's to /dst's, and one with --dry-run prints
# a change line when they differ; FAKE_COPY_BAD makes the copy add a file the
# source does not have, and FAKE_RUN_TERM=<n> makes the n-th copy, once made,
# send TERM to the shell that ran docker. `volume create` makes a volume with
# its --label values, and leaves one that exists as it is, as docker does.
export VOLS="$TMP/vols" IMGS="$TMP/imgs" FAKE_RUNNING="$TMP/running" FAKE_STOPPED="$TMP/stopped"
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
fmt=""; filt=(); vs=(); pos=(); labs=(); all=0
while (( $# )); do
  case "$1" in
    --format) fmt="$2"; shift 2 ;;
    --filter) filt+=("$2"); shift 2 ;;
    -v) vs+=("$2"); shift 2 ;;
    --label) labs+=("$2"); shift 2 ;;
    -e|--memory|--memory-swap|--pids-limit|--entrypoint|--mount) shift 2 ;;
    -a|--all) all=1; shift ;;
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
      if grep -qF -- "|/var/lib/docker/volumes/$v/_data" < <(cat "$FAKE_RUNNING" "$FAKE_STOPPED" 2>/dev/null); then
        echo "Error response from daemon: remove $v: volume is in use" >&2; exit 1
      fi
      rm -rf "$VOLS/$v"
    done ;;
  "volume create")
    v="${pos[0]}"
    if [[ ! -d "$VOLS/$v" ]]; then
      mkdir -p "$VOLS/$v"; printf '%s\n' ${labs[@]+"${labs[@]}"} > "$VOLS/$v/labels"
    fi ;;
  run)
    if [[ "${pos[1]:-}" == *rsync* ]]; then
      src="" dst=""
      for m in ${vs[@]+"${vs[@]}"}; do
        case "$m" in *:/src|*:/src:ro) src="${m%%:*}" ;; *:/dst|*:/dst:ro) dst="${m%%:*}" ;; esac
      done
      s="$VOLS/$src/data" d="$VOLS/$dst/data"
      if [[ "${pos[1]}" == *--dry-run* ]]; then
        if [[ -d "$s" || -d "$d" ]] && ! diff -r "$s" "$d" >/dev/null 2>&1; then printf '>f+++++++++ differs\n'; fi
      else
        if [[ -d "$s" ]]; then mkdir -p "$d"; cp -R "$s/." "$d/"; fi
        if [[ -n "${FAKE_COPY_BAD:-}" ]]; then mkdir -p "$d"; printf 'x\n' > "$d/extra"; fi
        if [[ -n "${FAKE_RUN_TERM:-}" ]]; then
          n=0; [[ -f "$VOLS.rcount" ]] && n="$(cat "$VOLS.rcount")"
          n=$((n + 1)); printf '%s\n' "$n" > "$VOLS.rcount"
          if (( n == FAKE_RUN_TERM )); then kill -TERM "$PPID"; fi
        fi
      fi
      exit 0
    fi
    for m in ${vs[@]+"${vs[@]}"}; do
      if [[ "$m" == *:/dst ]]; then
        v="${m%:/dst}"
        if [[ -f "$VOLS/$v/inspect" ]]; then cat "$VOLS/$v/inspect"; fi
      fi
    done ;;
  ps)
    anc="" vol=""
    for f in ${filt[@]+"${filt[@]}"}; do
      case "$f" in ancestor=*) anc="${f#ancestor=}" ;; volume=*) vol="${f#volume=}" ;; esac
    done
    if [[ -n "${FAKE_PS_FAIL:-}" ]] && [[ "$FAKE_PS_FAIL" != ancestor || -n "$anc" ]]; then
      echo "Error: cannot list containers" >&2; exit 1
    fi
    if [[ -n "$vol" ]]; then
      n=0; [[ -f "$FAKE_RUNNING.vcount" ]] && n="$(cat "$FAKE_RUNNING.vcount")"
      n=$((n + 1)); printf '%s\n' "$n" > "$FAKE_RUNNING.vcount"
      src="$FAKE_RUNNING"
      if [[ -n "${FAKE_VOLPS_AFTER:-}" ]] && (( n > FAKE_VOLPS_AFTER )); then src="$FAKE_RUNNING.later"; fi
      srcs=("$src"); if (( all )); then srcs+=("$FAKE_STOPPED"); fi
      cat "${srcs[@]}" 2>/dev/null | while IFS= read -r l; do
        if [[ "|$l|" == *"|/var/lib/docker/volumes/$vol/_data|"* ]]; then printf '%s\n' "${l%%|*}"; fi
      done
      exit 0
    fi
    n=0; [[ -f "$FAKE_RUNNING.count" ]] && n="$(cat "$FAKE_RUNNING.count")"
    n=$((n + 1)); printf '%s\n' "$n" > "$FAKE_RUNNING.count"
    src="$FAKE_RUNNING"
    if [[ -n "${FAKE_RUNNING_AFTER:-}" ]] && (( n > FAKE_RUNNING_AFTER )); then src="$FAKE_RUNNING.later"; fi
    while IFS='|' read -r n img _; do
      [[ -n "$n" ]] || continue
      if [[ -z "$anc" || "$img" == "$anc" ]]; then printf '%s\n' "$n"; fi
    done < "$src" ;;
  inspect)
    cat "$FAKE_RUNNING" "$FAKE_RUNNING.later" 2>/dev/null | while IFS= read -r l; do
      [[ "${l%%|*}" == "${pos[0]}" ]] || continue
      rest="${l#*|}"; rest="${rest#*|}"
      IFS='|' read -r -a srcs <<< "$rest"
      for s in ${srcs[@]+"${srcs[@]}"}; do printf '%s\n' "$s"; done
    done ;;
  "image inspect")
    i="${pos[0]}"
    if [[ "$i" == ai-containers-seed ]]; then [[ -z "${FAKE_NO_SEED:-}" ]]; exit; fi
    f="$IMGS/$i"
    if [[ ! -f "$f" && "$i" == *:latest ]]; then f="$IMGS/${i%:latest}"; fi
    [[ -f "$f" ]] || { echo "Error: No such image: $i" >&2; exit 1; }
    if [[ -f "$f.next" ]]; then trap 'mv "$f.next" "$f"' EXIT; fi
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
        [[ "$g" != *.next ]] || continue
        if ! { [[ -f "$g" ]] && grep -qxF -- "${f#label=}" "$g"; }; then continue; fi
        n="${g##*/}"
        if [[ -z "$fmt" ]]; then printf '%s\n' "$n"; continue; fi
        if [[ "$n" == dangling-* ]]; then r='<none>' t='<none>'
        elif [[ "$n" == *:* ]]; then r="${n%:*}" t="${n##*:}"
        else r="$n" t=latest; fi
        o="${fmt//'{{.ID}}'/$n}"; o="${o//'{{.Repository}}'/$r}"; printf '%s\n' "${o//'{{.Tag}}'/$t}"
      done
    done ;;
  rmi)
    [[ -z "${FAKE_FAIL_RMI:-}" ]] || { echo "Error: conflict: the image is used by a stopped container" >&2; exit 1; }
    for i in "${pos[@]}"; do
      if [[ ! -f "$IMGS/$i" && "$i" == *:latest ]]; then i="${i%:latest}"; fi
      [[ -f "$IMGS/$i" ]] || { echo "Error: No such image: $i" >&2; exit 1; }
      rm -f "$IMGS/$i"
    done ;;
  build) [[ -z "${FAKE_NO_SEED:-}" ]] || { echo "Error: cannot pull alpine" >&2; exit 1; } ;;
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

# ── a registry edit whose new content cannot be written changes nothing ──
# mktemp, which FAKE_MKTEMP_BAD=<glob> makes hand out, for a name that matches,
# a file no write reaches: with FAKE_MKTEMP_HOW=full a link to /dev/full (every
# write fails, as on a full disk), with =dir a directory (it cannot be opened).
# Put in place by fake_mktemp, and taken away after use (a process more for
# every mktemp otherwise).
REAL_MKTEMP="$(command -v mktemp)"; export REAL_MKTEMP
fake_mktemp() {
  cat > "$TMP/bin/mktemp" <<'FAKEMKTEMP'
#!/usr/bin/env bash
out="$("$REAL_MKTEMP" "$@")" || exit
# shellcheck disable=SC2053  # a glob on purpose
if [[ -n "${FAKE_MKTEMP_BAD:-}" && "${out##*/}" == $FAKE_MKTEMP_BAD ]]; then
  rm -f "$out"
  if [[ "${FAKE_MKTEMP_HOW:-}" == full ]]; then ln -s /dev/full "$out"; else mkdir "$out"; fi
fi
printf '%s\n' "$out"
FAKEMKTEMP
  chmod +x "$TMP/bin/mktemp"
}
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
# This HOME's ai-containers.owner, which a launch from here labels its working
# copies with: the same keyed hash, over a fixed string.
OWN="sha256:$(printf '%s\n%s' "$KEY" 'ai-containers owner' | sha256)"

W="$TMP/rmw"
world() {   # nothing registered, built, recorded, running or logged
  [[ -d "$W" ]] && chmod -R u+rwx "$W" 2>/dev/null
  rm -rf "$VOLS" "$IMGS" "$W"; mkdir -p "$VOLS" "$IMGS" "$W"
  : > "$FAKE_RUNNING"; : > "$DOCKER_LOG"
  rm -f "$ENG/projects.conf" "$IP" "$FAKE_RUNNING.count" "$FAKE_RUNNING.vcount" "$FAKE_RUNNING.later" "$FAKE_STOPPED" "$VOLS.rcount"
  unset FAKE_FAIL_VOLUME_RM FAKE_FAIL_RMI FAKE_DOCKER_DOWN FAKE_PS_FAIL FAKE_RUNNING_AFTER FAKE_VOLPS_AFTER FAKE_NO_SEED
  unset FAKE_COPY_BAD FAKE_CP_CORRUPT AI_CONTAINERS_MV_COPY FAKE_MV_PLANT FAKE_MV_PLANT_TO FAKE_CP_TERM FAKE_RUN_TERM
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
# mkwc <repo> <tag> <launch dir> [<inspect records>]: a working copy of <repo>,
# made by this HOME (ai-containers.owner=$OWN) unless WC_OWNER says otherwise:
# another's id, or empty for none (a copy made before there was the label)
mkwc() {
  local v="ai-containers-repo-$1--wc-$2" o="${WC_OWNER-$OWN}"
  mkvol "$v" "ai-containers.workcopy=1" "ai-containers.repo=$1" "ai-containers.launch-dir=$3" ${o:+"ai-containers.owner=$o"}
  if [[ -n "${4-}" ]]; then printf '%s' "$4" > "$VOLS/$v/inspect"; fi
}
CLEAN=$'PRIMARY|main\nBRANCH|main|0|current\nWORKTREE|clean\nEND|inspect\n'
rmrun() { ( cd "$TMP" && bash "$P" rm "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
hasx()  { grep -qxF -- "$1" "$TMP/out"; }
has_line() { grep -qF -- "$1" "$TMP/out"; }
lacks() { ! grep -qF -- "$1" "$TMP/out"; }
logged() { grep -qE -- "$1" "$DOCKER_LOG"; }

# the whole of it, by --yes
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$W/beta/.ai-containers"; printf '%s\n' "$W/beta" >> "$ENG/projects.conf"
printf 'sha256:keep-me|/elsewhere\n' >> "$IP"; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
ida="$(tid "$A/.ai-containers")"
rmrun "$A" --yes; rc=$?
ok "rm removes .ai-containers, its projects.conf line and its image-projects.conf line" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && ! grep -qxF "$2" "$3" && grep -qxF "$4" "$3" \
           && ! grep -qF "$5" "$6" && grep -qxF "sha256:keep-me|/elsewhere" "$6"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$W/beta" "$ida" "$IP"
ok "rm removes the image whose label is this project's id, without --force" \
  bash -c '[ ! -e "$1" ] && grep -qxF "docker rmi img-alpha" "$2" && ! grep -q -- "-f" < <(grep "^docker rmi" "$2")' \
  _ "$IMGS/img-alpha" "$DOCKER_LOG"
listing() {
  hasx "  directory   $A/.ai-containers" && hasx "  registry    $A (projects.conf)" && hasx "  image       img-alpha" \
    && hasx "  working copy ai-containers-repo-app--wc-1 (app, launched from $A/.ai-containers) — nothing at risk: every branch pushed, no stash, the checkout clean"
}
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
copy_line() { grep -F "  working copy ai-containers-repo-app--wc-$1 (app, launched from $A/.ai-containers) — " "$TMP/out"; }
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
risk git $'STALE|could not clone\nBRANCH|main|?|current\nSTASH|1\nWORKTREE|?\nEND|inspect\n'
ok "rm lists what a STALE inspection had already seen (a stash) on its not-checked line" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"could not clone"*"a stash (1"* ]]' _ "$(copy_line 1)"
# the copies that cannot be checked at all, each counted
unchecked() {  # <copy line pattern> <assertion name>
  ok "$2" bash -c '[[ "$1" == *"NOT CHECKED"*$3* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' \
    _ "$(grep -F "  working copy ai-containers-repo-app--wc-1 (" "$TMP/out")" "$TMP/out" "$1"
}
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkvol ai-containers-repo-app--wc-1 "ai-containers.workcopy=1" "ai-containers.launch-dir=$A/.ai-containers"
rmrun "$A"; unchecked "no ai-containers.repo label" "rm lists a copy with no repo label as not checked"
world; A="$W/alpha"; mkproj "$A"; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A"; unchecked "is gone" "rm lists a copy whose base volume is gone as not checked"
world; A="$W/alpha"; mkproj "$A"; mkwc app 1 "$A/.ai-containers" "$CLEAN"
mkvol ai-containers-repo-app "ai-containers.repo=other" "ai-containers.type=git" "ai-containers.source=https://example.invalid/other.git"
rmrun "$A"; unchecked "not labelled as repo app" "rm lists a copy whose base volume is labelled for another repo as not checked (REPO-11)"
world; A="$W/alpha"; mkproj "$A"; mkbase app svn; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A"; unchecked "records no repo type" "rm lists a copy whose base volume is neither git nor path as not checked"
# a seed image that cannot be had makes the copies not checked, never stops rm
world; A="$W/alpha"; mkproj "$A"; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"; mkwc app 2 "$A/.ai-containers" "$CLEAN"
export FAKE_NO_SEED=1
rmrun "$A" --yes; rc=$?
unset FAKE_NO_SEED
ok "rm lists copies as not checked when the seed image cannot be had, and finishes" \
  bash -c '[ "$1" = 0 ] && grep -qF "(app, launched from $4/.ai-containers) — NOT CHECKED: the seed helper image" "$2" && [ ! -d "$3/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$TMP/out" "$VOLS" "$A"
ok "  … resolving the seed image once, not per copy" \
  bash -c '[ "$(grep -c "^docker image inspect ai-containers-seed" "$1")" = 1 ]' _ "$DOCKER_LOG"

# the question, and what stops it
unchanged() {  # <root> <id>: nothing of the project was removed
  [[ -d "$1/.ai-containers" ]] && grep -qxF -- "$1" "$ENG/projects.conf" && grep -qF -- "$2" "$IP" \
    && ! logged '^docker (volume rm|rmi)'
}
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
rmrun "$A"; rc=$?
ok "rm refuses on a non-TTY without --yes and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR" "$2" && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' \
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
# docker that cannot list containers is no evidence that none runs
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
export FAKE_PS_FAIL=ancestor
rmrun "$A" --yes; rc=$?
unset FAKE_PS_FAIL
ok "rm refuses when docker cannot list the containers running its image" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker could not list the running containers" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
world; A="$W/alpha"; mkdir -p "$A/.ai-containers"; printf '%s\n' "$A" > "$ENG/projects.conf"
export FAKE_PS_FAIL=1
rmrun "$A" --yes; rc=$?
unset FAKE_PS_FAIL
ok "rm refuses when docker cannot list the running containers, for a project with no settings too" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker could not list the running containers" "$2" && [ -d "$3/.ai-containers" ]' \
  _ "$rc" "$TMP/out" "$A"
# a container launched while the question was asked: the first check makes two
# `ps` calls (mounts, then the image), the one after the question sees it
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
printf 'ctr-late|img-alpha|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING.later"
export FAKE_RUNNING_AFTER=2
rmrun "$A" --yes; rc=$?
unset FAKE_RUNNING_AFTER
ok "rm checks again after the question, and refuses a container started meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "ERROR.*started after the listing.*ctr-late" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
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
ok "rm names an unused group with ./group.sh rm, as unused by this checkout's projects.conf" \
  hasx "NOTE: group lonely is used by no other project in this checkout's projects.conf; remove it with ./group.sh rm lonely"
ok "rm names an unused REPOS repo with ./repo.sh rm" \
  hasx "NOTE: repo solo is used by no other project in this checkout's projects.conf; remove it with ./repo.sh rm solo"
ok "rm does not name a REPOS repo another project uses" lacks "NOTE: repo shared "
ok "rm names an unused SPECS_PATH=@name repo with ./repo.sh rm" \
  hasx "NOTE: repo specsolo is used by no other project in this checkout's projects.conf; remove it with ./repo.sh rm specsolo"
rmrun "$W/a2" --yes
ok "rm does not name a group another project uses" lacks "NOTE: group team "
ok "rm does not name a SPECS_PATH=@name repo another project uses" lacks "NOTE: repo specshared "
rmrun "$W/a3" --yes
ok "rm does not count a registered project whose .ai-containers is gone as using a group" \
  hasx "NOTE: group default is used by no other project in this checkout's projects.conf; it is the"
ok "  … and never suggests removing the default group, which every launch naming none uses" \
  bash -c 'grep -qxF "      group of every launch that names none, so keep it." "$1" && ! grep -qF "group.sh rm default" "$1"' _ "$TMP/out"
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
ok "  … and does not count that spelling as another project using its group" \
  hasx "NOTE: group default is used by no other project in this checkout's projects.conf; it is the"

# an image that cannot be removed keeps the record that names it
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
export FAKE_FAIL_RMI=1
rmrun "$A" --yes; rc=$?
unset FAKE_FAIL_RMI
ok "rm keeps the image-projects.conf line while the image it could not remove carries the id, and finishes the rest" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && ! grep -qxF "$5" "$6" && [ ! -e "$5/.ai-containers" ]' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$A" "$ENG/projects.conf"
ok "  … and says what docker said" has_line "NOTE: could not remove the image img-alpha (docker said: Error: conflict: the image is used by a stopped container)"

# the listing's decision on the image holds: one it said it keeps is not removed,
# though its label has become this project's by the time of removal
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
mv "$IMGS/img-alpha" "$IMGS/img-alpha.next"; printf 'org.opencontainers.image.title=Other\n' > "$IMGS/img-alpha"
rmrun "$A" --yes; rc=$?
ok "rm never removes an image the listing said it keeps" \
  bash -c '[ "$1" = 0 ] && grep -qF "  image       img-alpha — kept: " "$2" && ! grep -q "^docker rmi" "$3" && [ -e "$4" ]' \
  _ "$rc" "$TMP/out" "$DOCKER_LOG" "$IMGS/img-alpha"

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
           && grep -qxF "  image       (unknown — no sandbox.env; ./project.sh gc removes the image image-projects.conf" "$7"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$ida" "$IP" "$VOLS" "$TMP/out"

# what the agent can write reaches the terminal without its escapes
ESC=$'\e'
world
mkproj "$W/a1" "AI_CONTAINER_GROUP=${ESC}[31mred"$'\n'
rmrun "$W/a1" --yes; rc=$?
ok "rm prints an AI_CONTAINER_GROUP holding an ESC byte without it" \
  bash -c '[ "$1" = 0 ] && grep -q "^NOTE: group ?\[31mred " "$2" && ! grep -q "$3" "$2"' _ "$rc" "$TMP/out" "$ESC"
world
mkproj "$W/x/dup${ESC}[2Jn"; mkproj "$W/y/dup${ESC}[2Jn"
rmrun "dup${ESC}[2Jn" --yes; rc=$?
ok "rm names the projects sharing a basename without their ESC bytes" \
  bash -c '[ "$1" = 1 ] && grep -q "is the name of 2 registered projects" "$2" && ! grep -q "$3" "$2"' _ "$rc" "$TMP/out" "$ESC"
rmrun "$W/nope${ESC}[2Jx" --yes; rc=$?
ok "rm names an unregistered project and the registered ones without their ESC bytes" \
  bash -c '[ "$1" = 1 ] && grep -q "is not a registered project" "$2" && grep -q "dup?\[2Jn" "$2" && ! grep -q "$3" "$2"' \
  _ "$rc" "$TMP/out" "$ESC"
world
E="$W/esc${ESC}[2Jdir"; mkproj "$E"
rmrun "$E" --yes; rc=$?
ok "rm prints a registered root holding an ESC byte without it" \
  bash -c '[ "$1" = 0 ] && grep -q "About to remove" "$2" && ! grep -q "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$ESC" "$E"

# never ~/.ai-containers, which holds every group, the id key and the registries,
# nor the engine itself
world
mkdir -p "$HOME/.ai-containers/default/.claude"
printf '%s\n' "$HOME" > "$ENG/projects.conf"
rmrun "$HOME" --yes; rc=$?
ok "rm refuses a project registered at \$HOME, and ~/.ai-containers is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ] \
           && [ "$(cat "$4")" = "$5" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers" "$ENG/projects.conf" "$HOME"
world
ln -s "$HOME" "$W/homelink"; printf '%s\n' "$W/homelink" > "$ENG/projects.conf"
rmrun "$W/homelink" --yes; rc=$?
ok "rm refuses a project whose root is a symlink to \$HOME" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ]' \
  _ "$rc" "$TMP/out" "$HOME/.ai-containers"
world
mkdir -p "$W/eroot/.ai-containers"; cp -a "$ENG" "$W/eroot/.ai-containers/base"
printf '%s\n' "$W/eroot" > "$W/eroot/.ai-containers/base/projects.conf"
( cd "$TMP" && bash "$W/eroot/.ai-containers/base/project.sh" rm "$W/eroot" --yes ) > "$TMP/out" 2>&1 < /dev/null; rc=$?
ok "rm refuses a project whose .ai-containers holds the engine it runs from" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*holds this engine" "$2" && [ -f "$3/project.sh" ]' \
  _ "$rc" "$TMP/out" "$W/eroot/.ai-containers/base"
# compared per path component: ~/.ai-containers-old is not ~/.ai-containers
world
O="$HOME/.ai-containers-old/proj"; mkproj "$O"
rmrun "$O" --yes; rc=$?
ok "rm removes a project under ~/.ai-containers-old, which only starts like ~/.ai-containers" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ -f "$3/project-id.key" ]' _ "$rc" "$O" "$HOME/.ai-containers"
rm -rf "$HOME/.ai-containers-old" "$HOME/.ai-containers/default"

# a copy another home made on a shared daemon — the same user name in another
# WSL distro gives the same paths — is not this project's to remove
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
WC_OWNER="sha256:$(printf '%064d' 9)" mkwc app 2 "$A/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 3 "$A/.ai-containers" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm keeps a working copy another home made, launched from the same path, and removes this home's and an unlabelled one" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] && [ ! -d "$2/ai-containers-repo-app--wc-3" ] \
           && ! grep -qxF "docker volume rm ai-containers-repo-app--wc-2" "$3"' _ "$rc" "$VOLS" "$DOCKER_LOG"
ok "  … naming it as kept" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app, launched from $A/.ai-containers) — kept: made by another home or user on this docker"

# a copy launched from a directory in the project that holds a launcher of its
# own is that (unregistered) project's
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkdir -p "$A/sub/.ai-containers"; : > "$A/sub/.ai-containers/sandbox.sh"; : > "$A/sub/.ai-containers/sandbox-common.sh"
mkwc app 1 "$A/.ai-containers" "$CLEAN"; mkwc app 2 "$A/sub/.ai-containers" "$CLEAN"; mkwc app 3 "$A/sub" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm keeps a working copy launched from a directory in the project that holds a launcher of its own" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] && [ ! -d "$2/ai-containers-repo-app--wc-3" ]' \
  _ "$rc" "$VOLS"
ok "  … naming it as kept, with where it was launched from" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app, launched from $A/sub/.ai-containers) — kept: launched from $A/sub/.ai-containers, which holds a launcher of its own"

# a project whose own sandbox.local.env names its repo volumes under another
# REPO_VOLUME_PREFIX: rm would see other copies than its launcher makes
world; A="$W/alpha"; mkproj "$A" '' $'REPO_VOLUME_PREFIX=other\n'
mkvol other-repo-app "ai-containers.repo=app" "ai-containers.type=git" "ai-containers.source=https://example.invalid/app.git"
mkvol other-repo-app--wc-1 "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$A/.ai-containers" "ai-containers.owner=$OWN"
printf '%s' "$CLEAN" > "$VOLS/other-repo-app--wc-1/inspect"
rmrun "$A" --yes; rc=$?
ok "rm refuses a project whose sandbox.local.env sets another REPO_VOLUME_PREFIX, saying how to run it" \
  bash -c '[ "$1" = 1 ] && grep -qF "names its repo volumes under REPO_VOLUME_PREFIX=other (from its sandbox.local.env)" "$2" \
           && grep -qxF "         REPO_VOLUME_PREFIX=other ./project.sh rm $3" "$2" \
           && [ -d "$3/.ai-containers" ] && grep -qxF "$3" "$4" && ! grep -q "^docker volume rm" "$5"' \
  _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$DOCKER_LOG"
( export REPO_VOLUME_PREFIX=other; rmrun "$A" --yes ); rc=$?
ok "  … and run so, removes the copies under that prefix" \
  bash -c '[ "$1" = 0 ] && [ ! -d "$2/other-repo-app--wc-1" ] && [ ! -e "$3/.ai-containers" ]' _ "$rc" "$VOLS" "$A"

# a project whose root may be on a drive that is not mounted: rm names why, and
# what to do if it was moved, and goes on when told to
world; mkdir -p "$W/other" "$W/drive"; D="$W/drive/proj"; printf '%s\n' "$D" > "$ENG/projects.conf"
rmrun "$D" --yes; rc=$?
ok "rm lists a project whose root may be on an unmounted drive with why, and the mv way out, then removes its line" \
  bash -c '[ "$1" = 0 ] && grep -qxF "  directory   $2/.ai-containers (not there: it may be on a drive that is not mounted: $3 is empty)" "$4" \
           && grep -qxF "              If $2 was moved rather than deleted, answer no and run ./project.sh mv $2 <new-dir>:" "$4" \
           && grep -qxF "              rm would remove its working copies, which mv carries to the new place." "$4" && ! grep -qxF "$2" "$5"' \
  _ "$rc" "$D" "$W/drive" "$TMP/out" "$ENG/projects.conf"
# with no settings and no image-projects.conf line, the image is found by its id only
world; A="$W/alpha"; mkdir -p "$A/.ai-containers"; printf '%s\n' "$A" > "$ENG/projects.conf"; ida="$(tid "$A/.ai-containers")"
rmrun "$A" --yes; rc=$?
ok "rm says how to find the image of a project with no settings that no image-projects.conf line names" \
  bash -c '[ "$1" = 0 ] && grep -qxF "              is listed by docker images --filter label=ai-containers.project=$2)" "$3" \
           && ! grep -qF "./project.sh gc removes the image" "$3"' _ "$rc" "$ida" "$TMP/out"

# ── mv ──
# mv takes emit_env_list from project-init.sh, which the dispatch tests replaced
# with a stub: the real one again.
cp -p "$REPO_DIR/project-init.sh" "$ENG/project-init.sh"
# cp, which FAKE_CP_CORRUPT=<file> makes change that file of a copy it makes to
# a directory named .ai-containers: the copy a move across filesystems makes is
# then not the original, though it holds the same names. FAKE_CP_TERM: see below.
REAL_CP="$(command -v cp)"; export REAL_CP
cat > "$TMP/bin/cp" <<'FAKECP'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit
last="${!#}"
if [[ -n "${FAKE_CP_CORRUPT:-}" && "${last##*/}" == .ai-containers && -f "$last/$FAKE_CP_CORRUPT" ]]; then
  printf 'x\n' >> "$last/$FAKE_CP_CORRUPT"
fi
# FAKE_CP_TERM: once that copy is made, the one who ran cp is sent TERM
if [[ -n "${FAKE_CP_TERM:-}" && "${last##*/}" == .ai-containers ]]; then kill -TERM "$PPID"; fi
exit 0
FAKECP
chmod +x "$TMP/bin/cp"
# mv, which FAKE_MV_PLANT=<path> makes put something at <path> just before it
# moves anything there — a directory holding a file, or with FAKE_MV_PLANT_TO=<dir>
# a link to <dir> — as a process racing the move would.
REAL_MV="$(command -v mv)"; export REAL_MV
cat > "$TMP/bin/mv" <<'FAKEMV'
#!/usr/bin/env bash
last="${!#}"
if [[ -n "${FAKE_MV_PLANT:-}" && "$last" == "$FAKE_MV_PLANT" && ! -e "$last" && ! -L "$last" ]]; then
  if [[ -n "${FAKE_MV_PLANT_TO:-}" ]]; then ln -s "$FAKE_MV_PLANT_TO" "$last"
  else mkdir "$last" && printf 'planted\n' > "$last/planted"; fi
fi
exec "$REAL_MV" "$@"
FAKEMV
chmod +x "$TMP/bin/mv"
mvrun() { ( cd "$TMP" && bash "$P" mv "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
# mvbsd: mv as on a mv without -T (BSD's), where only the check after the move
# stands between a planted directory and the setup moving into it. hash -r: this
# shell found the real mv before the fake one existed.
mvbsd() { ( hash -r && cd "$TMP" && source "$P" && _prj_mv_T=0 && cmd_mv "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
# wcname <repo> <launch dir>: the working copy a launch from there uses
wcname() { ( source "$P" && repo_workcopy_volume_name "$1" "$(workcopy_tag "$2")" ); }
wcdata() { mkdir -p "$VOLS/$1/data"; printf '%s\n' "$2" > "$VOLS/$1/data/work"; }
wcwork() { cat "$VOLS/$1/data/work" 2>/dev/null; }
# moved_nothing <root> <projects.conf as it was>: no volume made or removed, no
# copy run (a read-only check may be), no image removed, the registry as it was
moved_nothing() {
  [[ -d "$1/.ai-containers" ]] && cmp -s "$ENG/projects.conf" "$2" && ! logged '^docker (volume (rm|create)|rmi)' \
    && [[ -z "$(grep '^docker run' "$DOCKER_LOG" | grep -v -- '--dry-run')" ]]
}
# mvproj <root> [<sandbox.env text>] [<sandbox.local.env text>]: a registered
# project in a directory that holds more than its setup, with one working copy of
# app holding work; the registry saved to $TMP/conf.before
mvproj() {
  mkproj "$@"; printf 'hi\n' > "$1/README"; mkbase app
  mkwc app 1 "$1/.ai-containers"; wcdata ai-containers-repo-app--wc-1 unpushed
  cp "$ENG/projects.conf" "$TMP/conf.before"
}
OLDWC=ai-containers-repo-app--wc-1

world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$A/.ai-containers/.agent-blocked"; printf 'log\n' > "$A/.ai-containers/.agent-blocked/blocked.log"
printf '# head\n/x/before\n%s\n/x/after' "$A" > "$ENG/projects.conf"
N="$W/new/place/alpha2"
mvrun "$A" "$N" --yes; rc=$?
printf '# head\n/x/before\n%s\n/x/after' "$N" > "$TMP/expect"
ok "mv moves .ai-containers to <new-dir>, creating it, and rewrites the projects.conf line in place" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ "$(cat "$3/.ai-containers/.agent-blocked/blocked.log")" = log ] && cmp -s "$4" "$5" && [ -f "$2/README" ]' \
  _ "$rc" "$A" "$N" "$ENG/projects.conf" "$TMP/expect"
ok "  … adds the old root to a sandbox.local.env it creates" \
  bash -c '[ "$(cat "$1")" = "EXTRA_MOUNTS=\"$2\"" ]' _ "$N/.ai-containers/sandbox.local.env" "$A"
ok "  … and says nothing of a repository tracking .ai-containers where none does" lacks "repository tracks"
ok "  … printing what it does first, with --yes too" \
  bash -c 'grep -qxF "About to move project $1 to $2:" "$3" && grep -qxF "  directory   $1/.ai-containers → $2/.ai-containers" "$3"' \
  _ "$A" "$N" "$TMP/out"

world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mvrun "$A" "$N" --yes; rc=$?
ok "mv copies each working copy to the new launch dir's volume name and label, then removes the old" \
  bash -c '[ "$1" = 0 ] && [ -n "$3" ] && [ ! -d "$2/$5" ] && [ "$(cat "$2/$3/data/work")" = unpushed ] \
           && grep -qxF "ai-containers.workcopy=1" "$2/$3/labels" && grep -qxF "ai-containers.repo=app" "$2/$3/labels" \
           && grep -qxF "ai-containers.launch-dir=$4/.ai-containers" "$2/$3/labels"' _ "$rc" "$VOLS" "$nv" "$N" "$OLDWC"
ok "  … removing the old one only after the copy's check" \
  bash -c 'c="$(grep -n -- "--dry-run" "$1" | head -1 | cut -d: -f1)"; r="$(grep -nxF "docker volume rm $2" "$1" | cut -d: -f1)"
           [ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ]' _ "$DOCKER_LOG" "$OLDWC"
ok "  … and lists it first" hasx "  working copy $OLDWC (app) → $nv"

world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export FAKE_COPY_BAD=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_COPY_BAD
ok "mv keeps the old working copy and directory when a copy's check finds a difference" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/$9/data/work")" = unpushed ] && [ ! -e "$3/$4" ] \
           && [ -d "$5/.ai-containers" ] && [ ! -e "$6/.ai-containers" ] && cmp -s "$7" "$8"' \
  _ "$rc" "$TMP/out" "$VOLS" "$nv" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before" "$OLDWC"
ok "  … and nothing else" bash -c '[ -e "$1" ] && ! grep -q "^docker rmi" "$2"' _ "$IMGS/img-alpha" "$DOCKER_LOG"

world
A="$W/alpha"; mvproj "$A" '' $'# mine\nEXTRA_MOUNTS="/x/one:ro /x/two"\nREPOS=lib:ro\n'
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf '# mine\nEXTRA_MOUNTS="\n  /x/one:ro\n  /x/two\n  %s\n"\nREPOS=lib:ro\n' "$A" > "$TMP/expect"
ok "mv adds the old root to EXTRA_MOUNTS, one entry per line, keeping existing entries" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
world
A="$W/alpha"; mvproj "$A" '' $'export EXTRA_MOUNTS="\n  /x/one\n\n  /x/two\n"\nPREVIEW_PORTS=3000\n'
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf 'export EXTRA_MOUNTS="\n  /x/one\n  /x/two\n  %s\n"\nPREVIEW_PORTS=3000\n' "$A" > "$TMP/expect"
ok "mv replaces an EXTRA_MOUNTS written over several lines whole, its export kept" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"

world
A="$W/alpha"; mvproj "$A" '' "EXTRA_MOUNTS=\"/x/one $W:z\""$'\n'
cp "$A/.ai-containers/sandbox.local.env" "$TMP/expect"
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv adds nothing when an entry already covers the old root" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
ok "  … and says which" hasx "  EXTRA_MOUNTS $A is already covered by $W:z"

world
A="$W/setup/alpha"; mkproj "$A"; N="$W/dev/alpha"
mvrun "$A" "$N" --yes; rc=$?
ok "mv removes an old root it leaves empty, and adds nothing to EXTRA_MOUNTS" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -d "$3/setup" ] && [ -f "$4/.ai-containers/sandbox.env" ] \
           && [ ! -e "$4/.ai-containers/sandbox.local.env" ]' _ "$rc" "$A" "$W" "$N"
ok "  … listing it first" hasx "  directory   $A (it holds nothing else once .ai-containers is moved)"

# a name the launcher would mount twice
clash() {  # <sandbox.local.env text> <new-dir> <what the error names> <assertion>
  world
  A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n' "$1"; built "$A" img-alpha
  : > "$DOCKER_LOG"
  mvrun "$A" "$2" --yes; rc=$?
  ok "$4" bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && grep -qF -- "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$3" "$2"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
}
clash '' "$W/elsewhere/alpha" "/workspace/alpha" "mv refuses a <new-dir> with the old root's basename, changing nothing"
clash $'EXTRA_MOUNTS="/x/gamma:ro"\n' "$W/new/gamma" "/workspace/gamma" "mv refuses a <new-dir> with an EXTRA_MOUNTS entry's basename"
clash $'REPOS="lib:ro delta:rw"\n' "$W/new/delta" "/workspace/delta" "mv refuses a <new-dir> with a REPOS name"
clash $'EXTRA_MOUNTS=/x/alpha\n' "$W/new/beta" "/workspace/alpha" "mv refuses when the old root it would add to EXTRA_MOUNTS has an entry's basename"

world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; mkdir -p "$N/.ai-containers"; printf 'theirs\n' > "$N/.ai-containers/sandbox.env"
mvrun "$A" "$N" --yes; rc=$?
ok "mv refuses when both the old and the new .ai-containers exist" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/.ai-containers/sandbox.env")" = theirs ]' _ "$rc" "$TMP/out" "$N"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# already moved: by hand, and with the old line gone (gc removed it)
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
printf '/x/before\n%s\n' "$A" > "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv repairs a project already moved by hand" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/before\n%s" "$3")" ] && [ ! -d "$4/$9" ] && [ "$(cat "$4/$5/data/work")" = unpushed ] \
           && [ "$(cat "$3/.ai-containers/sandbox.local.env")" = "EXTRA_MOUNTS=\"$6\"" ] && [ ! -e "$7" ] && [ -e "${10}" ] && ! grep -qF "$8" "${10}" \
           && [ ! -e "$6/.ai-containers" ]' \
  _ "$rc" "$ENG/projects.conf" "$N" "$VOLS" "$nv" "$A" "$IMGS/img-alpha" "$ida" "$OLDWC" "$IP"
ok "  … saying there was nothing to move" hasx "  directory   $N/.ai-containers (already there; nothing to move)"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
printf '/x/other\n' > "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv repairs a project whose line gc removed" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/other\n%s" "$3")" ] && [ ! -d "$4/$9" ] && [ "$(cat "$4/$5/data/work")" = unpushed ] \
           && [ "$(cat "$3/.ai-containers/sandbox.local.env")" = "EXTRA_MOUNTS=\"$6\"" ] && [ ! -e "$7" ] && [ -e "${10}" ] && ! grep -qF "$8" "${10}"' \
  _ "$rc" "$ENG/projects.conf" "$N" "$VOLS" "$nv" "$A" "$IMGS/img-alpha" "$ida" "$OLDWC" "$IP"
world
A="$W/alpha"; mkdir -p "$A"; printf '/x/other\n' > "$ENG/projects.conf"; cp "$ENG/projects.conf" "$TMP/conf.before"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a project that is not registered and was not moved" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*not a registered project" "$2" && [ ! -e "$3" ] && cmp -s "$4" "$5"' \
  _ "$rc" "$TMP/out" "$W/beta" "$ENG/projects.conf" "$TMP/conf.before"

# the image
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; printf 'sha256:keep-me|/elsewhere\n' >> "$IP"; built "$A" img-alpha
ida="$(tid "$A/.ai-containers")"; N="$W/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv removes the old image and its image-projects.conf line, and says the next build rebuilds it" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && grep -qxF "docker rmi img-alpha" "$3" && ! grep -qF "$4" "$5" \
           && grep -qxF "sha256:keep-me|/elsewhere" "$5"' _ "$rc" "$IMGS/img-alpha" "$DOCKER_LOG" "$ida" "$IP"
ok "  … in those words" hasx "NOTE: the next ./build.sh (runme.sh runs it) builds img-alpha again, from the cache."
( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$N/.ai-containers" ) > "$TMP/err" 2>&1; rc=$?
ok "the retag guard passes for IMAGE_NAME right after mv" [ "$rc" = 0 ]
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"; N="$W/beta"
export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
ok "mv keeps an image a stopped container references, and its line, and says so" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && grep -qF "NOTE: could not remove the image img-alpha" "$5" \
           && grep -qF "NOTE: an image still carries this project'"'"'s id" "$5" && ! grep -qF "builds img-alpha again" "$5"' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$TMP/out"
( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$N/.ai-containers" ) > "$TMP/err" 2>&1; rc=$?
ok "  … which the next build replaces, with a NOTE" bash -c '[ "$1" = 0 ] && grep -q "^NOTE: img-alpha was built for" "$2"' _ "$rc" "$TMP/err"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-shared\n'; printf 'ai-containers.project=sha256:%064d\n' 7 > "$IMGS/img-shared"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv keeps an IMAGE_NAME whose label is another project's id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       img-shared — kept: " "$4" \
           && ! grep -qF "builds img-shared again" "$4"' _ "$rc" "$IMGS/img-shared" "$DOCKER_LOG" "$TMP/out"

world
O="$W/outer"; mkproj "$O"; mkproj "$O/inner"; mkbase app
mkwc app 1 "$O/.ai-containers"; mkwc app 2 "$O/inner/.ai-containers"
N="$W/newouter"; nv="$(wcname app "$N/.ai-containers")"
mvrun "$O" "$N" --yes; rc=$?
ok "mv leaves a working copy launched from a nested registered project" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/$3" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "ai-containers.launch-dir=$4/inner/.ai-containers" "$2/ai-containers-repo-app--wc-2/labels" \
           && [ -d "$4/inner/.ai-containers" ] && grep -qxF "$4/inner" "$5"' _ "$rc" "$VOLS" "$nv" "$O" "$ENG/projects.conf"

world
A="$W/alpha"; mvproj "$A"
git -C "$A" init -q 2>/dev/null && git -C "$A" add .ai-containers README
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv notes that the old repository tracks .ai-containers" \
  bash -c '[ "$1" = 0 ] && grep -qxF "NOTE: $2'"'"'s repository tracks .ai-containers/; those files now show as deleted there." "$3"' \
  _ "$rc" "$A" "$TMP/out"

# what stops it
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
printf 'ctr-one|other-image|/somewhere|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses while a container of the project runs, saying nothing was changed" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-one.*nothing was changed\.$" "$2" && ! grep -q "nothing was removed" "$2" && [ ! -e "$3" ]' \
  _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
printf 'ctr-late|img-alpha|/somewhere\n' > "$FAKE_RUNNING.later"
export FAKE_RUNNING_AFTER=4
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_RUNNING_AFTER
ok "mv checks again after the question, and refuses a container started meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to move" "$2" && grep -q "ERROR.*started after the listing.*ctr-late" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/beta"; rc=$?
ok "mv refuses on a non-TTY without --yes" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -q "About to move" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; export FAKE_DOCKER_DOWN=1
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "mv refuses when docker cannot be reached" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker cannot be reached" "$2" && [ -d "$3/.ai-containers" ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$A" "$W/beta"
world
A="$W/alpha"; mvproj "$A"; export FAKE_NO_SEED=1
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_NO_SEED
ok "mv refuses when the seed image that copies the working copies cannot be had" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*seed helper image" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; printf 'EXTRA_MOUNTS=/x/mine\n' > "$TMP/real-local"
ln -s "$TMP/real-local" "$A/.ai-containers/sandbox.local.env"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a linked sandbox.local.env it would add the old root to, and its target is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*sandbox.local.env" "$2" && [ "$(cat "$3")" = EXTRA_MOUNTS=/x/mine ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$TMP/real-local" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; mkdir -p "$W/same"; ln -s "$W" "$W/same/up"
mvrun "$A" "$W/same/up/alpha" --yes; rc=$?
ok "mv refuses a <new-dir> that is the project itself" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*already" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mkdir -p "$W/real-beta"; ln -s "$W/real-beta" "$W/beta-link"
mvrun "$A" "$W/beta-link" --yes; rc=$?
ok "mv refuses a <new-dir> that is a link" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*is a link" "$2" && [ ! -e "$3/.ai-containers" ] && [ -L "$4" ]' \
  _ "$rc" "$TMP/out" "$W/real-beta" "$W/beta-link"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$W/nope/../beta" --yes; rc=$?
ok "mv refuses a <new-dir> with .. where it does not exist yet" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*\.\. where it does not exist" "$2" && [ ! -e "$3" ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$W/nope" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: a <new-dir> that cannot be made (running as root)\n'
else
  mkdir -p "$W/locked"; chmod 555 "$W/locked"
  mvrun "$A" "$W/locked/beta" --yes; rc=$?
  chmod 755 "$W/locked"
  ok "mv refuses a <new-dir> that cannot be made" \
    bash -c '[ "$1" = 1 ] && grep -q "ERROR.*cannot be made" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/locked/beta"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
fi
world
A="$W/alpha"; mkdir -p "$A"; printf '%s\n' "$A" > "$ENG/projects.conf"; cp "$ENG/projects.conf" "$TMP/conf.before"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses when neither the old nor the new .ai-containers exists" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: neither" "$2" && [ ! -e "$3" ] && cmp -s "$4" "$5"' \
  _ "$rc" "$TMP/out" "$W/beta" "$ENG/projects.conf" "$TMP/conf.before"

# a working copy's new name already taken
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers"; wcdata "$nv" unpushed
mvrun "$A" "$N" --yes; rc=$?
ok "mv takes an exact copy already at the new name (a run cut short) as done, and removes the old" \
  bash -c '[ "$1" = 0 ] && [ ! -d "$2/$5" ] && [ "$(cat "$2/$3/data/work")" = unpushed ] && ! grep -q "^docker volume create" "$4"' \
  _ "$rc" "$VOLS" "$nv" "$DOCKER_LOG" "$OLDWC"
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers"; wcdata "$nv" fresh
mvrun "$A" "$N" --yes; rc=$?
ok "mv refuses a working copy whose new name another volume holds" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && grep -qF "$5" "$2" && [ "$(cat "$3/$5/data/work")" = fresh ] \
           && [ "$(cat "$3/$4/data/work")" = unpushed ]' _ "$rc" "$TMP/out" "$VOLS" "$OLDWC" "$nv"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

world
S="$W/my proj"; mkproj "$S" $'IMAGE_NAME=img-space\n'; built "$S" img-space; mkbase app
mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; nv="$(wcname app "$N/.ai-containers")"
mvrun "$S" "$N" --yes; rc=$?
ok "mv works when <new-dir> and the old root have spaces" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$3" ] && grep -qxF "$2" "$4" \
           && ! grep -qxF "$3" "$4" && [ "$(cat "$5/$6/data/work")" = unpushed ] && [ ! -d "$5/$8" ] && [ ! -e "$7" ] \
           && [ ! -e "$2/.ai-containers/sandbox.local.env" ]' \
  _ "$rc" "$N" "$S" "$ENG/projects.conf" "$VOLS" "$nv" "$IMGS/img-space" "$OLDWC"
world
S="$W/my proj"; mvproj "$S"
mvrun "$S" "$W/beta" --yes; rc=$?
ok "mv refuses an old root with whitespace that it would have to mount" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: $3 holds whitespace" "$2" && grep -qF "rename" "$2" && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$S" "$W/beta"
ok "  … changing nothing" moved_nothing "$S" "$TMP/conf.before"
world
O="$W/outer"; S="$O/my proj"; mvproj "$S"
mvrun "$S" "$O" --yes; rc=$?
ok "mv adds nothing for an old root inside <new-dir>, whitespace or not" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$2/.ai-containers/sandbox.local.env" ] \
           && [ -f "$3/README" ] && [ ! -e "$3/.ai-containers" ]' _ "$rc" "$O" "$S"
ok "  … saying the container mounts it there" hasx "  EXTRA_MOUNTS $S lies inside $O, which the container mounts: nothing to add"

# never into or out of ~/.ai-containers, nor into the old .ai-containers
world
mkdir -p "$HOME/.ai-containers/default/.claude"; printf '%s\n' "$HOME" > "$ENG/projects.conf"
mvrun "$HOME" "$W/newhome" --yes; rc=$?
ok "mv refuses a project registered at HOME" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ] \
           && [ ! -e "$4" ] && [ "$(cat "$5")" = "$6" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers" "$W/newhome" "$ENG/projects.conf" "$HOME"
world
A="$W/alpha"; mvproj "$A"
mvrun "$A" "$HOME/.ai-containers/x" --yes; rc=$?
ok "mv refuses a <new-dir> inside ~/.ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers/x"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$A/.ai-containers/sub" --yes; rc=$?
ok "mv refuses a <new-dir> inside the old .ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*inside" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$A/.ai-containers/sub"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
rm -rf "$HOME/.ai-containers/default"

# across filesystems (forced: the test's directories are all on one)
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$A/.ai-containers/.agent-discovery"; printf 'pcap\n' > "$A/.ai-containers/.agent-discovery/cap.pcap"
ln -s ../sandbox.env "$A/.ai-containers/.agent-discovery/link"
N="$W/beta"; export AI_CONTAINERS_MV_COPY=1
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY
ok "mv across filesystems copies .ai-containers, checks the copy, then removes the old" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ "$(cat "$3/.ai-containers/.agent-discovery/cap.pcap")" = pcap ] && [ -L "$3/.ai-containers/.agent-discovery/link" ] \
           && [ "$(ls -A "$3")" = .ai-containers ] && grep -qxF "$3" "$4"' _ "$rc" "$A" "$N" "$ENG/projects.conf"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/p1/p2/beta"; nv="$(wcname app "$N/.ai-containers")"; export AI_CONTAINERS_MV_COPY=1 FAKE_CP_CORRUPT=sandbox.env
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_CP_CORRUPT
ok "mv across filesystems keeps the old .ai-containers and removes the temp copy when the copy differs" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ -z "$(ls -A "$4" 2>/dev/null)" ] && cmp -s "$5" "$6"' _ "$rc" "$TMP/out" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before"
ok "  … and the directories it made for <new-dir>" bash -c '[ ! -e "$1" ] && [ -d "$2" ]' _ "$W/p1" "$W"
ok "  … and the working copies as they were" \
  bash -c '[ "$(cat "$1/$3/data/work")" = unpushed ] && [ ! -e "$1/$2" ] && [ -e "$4" ]' _ "$VOLS" "$nv" "$OLDWC" "$IMGS/img-alpha"

# the setup must land at <new-dir>/.ai-containers itself: something put there
# just before the rename (a racing process) takes it in, on a mv without -T
landed_not() {  # <assertion> <where the setup or its copy went> <old .ai-containers kept: 1|0>
  ok "$1" bash -c '[ "$1" = 1 ] && [ -d "$3" ] && grep -qF -- "$(cd "$3" && pwd -P)" "$2" && cmp -s "$4" "$5" \
                   && [ "$(cat "$6/$8/data/work")" = unpushed ] && [ ! -e "$6/$7" ] && [ -e "$9" ] \
                   && { [ "${10}" = 0 ] || [ -f "${11}/.ai-containers/sandbox.env" ]; } && [ ! -e "$3/sandbox.local.env" ]' \
    _ "$rc" "$TMP/out" "$2" "$ENG/projects.conf" "$TMP/conf.before" "$VOLS" "$nv" "$OLDWC" "$IMGS/img-alpha" "$3" "$A"
}
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export FAKE_MV_PLANT="$N/.ai-containers"
mvbsd "$A" "$N" --yes; rc=$?
unset FAKE_MV_PLANT
landed_not "mv exits 1 when a directory appears where the setup goes, saying where it went, recording nothing" \
  "$N/.ai-containers/.ai-containers" 0
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkdir -p "$W/elsewhere"; export FAKE_MV_PLANT="$N/.ai-containers" FAKE_MV_PLANT_TO="$W/elsewhere"
mvbsd "$A" "$N" --yes; rc=$?
unset FAKE_MV_PLANT FAKE_MV_PLANT_TO
landed_not "mv exits 1 when a link appears where the setup goes, writing nothing through it" "$W/elsewhere/.ai-containers" 0
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export AI_CONTAINERS_MV_COPY=1 FAKE_MV_PLANT="$N/.ai-containers"
mvbsd "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_MV_PLANT
landed_not "mv across filesystems exits 1 when a directory appears where the checked copy goes, keeping the old" \
  "$N/.ai-containers/.ai-containers" 1
ok "  … and leaves no temp directory" bash -c '[ "$(ls -A "$1")" = .ai-containers ]' _ "$N"
pd="$(mktemp -d "$TMP/probe.XXXXXX")"; mkdir "$pd/a"
if "$REAL_MV" -T "$pd/a" "$pd/b" 2>/dev/null; then
  world
  A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"
  export FAKE_MV_PLANT="$N/.ai-containers"
  mvrun "$A" "$N" --yes; rc=$?
  unset FAKE_MV_PLANT
  ok "with mv -T, a directory that appears where the setup goes stops the move" \
    bash -c '[ "$1" = 1 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$3/.ai-containers/.ai-containers" ] && cmp -s "$4" "$5" \
             && grep -qF "it is where it was" "$6"' _ "$rc" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before" "$TMP/out"
else
  printf 'SKIP: mv -T on this mv (it has none)\n'
fi
rm -rf "$pd"

# what the launcher would resolve against the launch directory, which moves
relative() {  # <sandbox.local.env text> <what the error names> <assertion>
  world
  A="$W/alpha"; mvproj "$A" '' "$1"
  mvrun "$A" "$W/beta" --yes; rc=$?
  ok "$3" bash -c '[ "$1" = 1 ] && grep -q "^ERROR: " "$2" && grep -qF -- "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$2" "$W/beta"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
}
relative $'EXTRA_MOUNTS="/x/one ../shared:ro"\n' "EXTRA_MOUNTS entry ../shared:ro" "mv refuses a relative EXTRA_MOUNTS entry, naming it"
relative $'SANDBOX_WORKDIR=@app\n' "SANDBOX_WORKDIR=@app" "mv refuses a SANDBOX_WORKDIR other than .. in sandbox.local.env, naming it"
relative $'VAULT_PATH=notes\n' "VAULT_PATH=notes" "mv refuses a relative pointer in sandbox.local.env, naming it"
world
A="$W/alpha"; mvproj "$A" '' $'SANDBOX_WORKDIR=..\nVAULT_PATH=~/notes\nDOCS_PATH=@docs:ro\nEXTRA_MOUNTS=~/x\n'
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv takes SANDBOX_WORKDIR=.., a ~ path and an @name as they are" bash -c '[ "$1" = 0 ]' _ "$rc"

# an image a stopped container keeps, and the old root it leaves empty
retag() { ( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$1/.ai-containers" ) > "$TMP/err" 2>&1; }
world
mkdir -p "$W/setup"; printf 'x\n' > "$W/setup/other"; A="$W/setup/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/dev/beta"; export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
retag "$N"; rc2=$?
ok "mv removes the old root it left empty though the image stays, so the next build replaces the image" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -e "$3" ] && [ "$4" = 0 ] && grep -q "^NOTE: img-alpha was built for" "$5"' \
  _ "$rc" "$A" "$IMGS/img-alpha" "$rc2" "$TMP/err"
ok "  … and says nothing of the next build refusing" lacks "will refuse to replace"
world
mkdir -p "$W/setup"; A="$W/setup/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/dev/beta"; export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
retag "$N"; rc2=$?
ok "mv says when the next build will refuse the image it could not remove, and how to remove it" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 1 ] && grep -qF "NOTE: the next ./build.sh will refuse to replace img-alpha" "$3" \
           && grep -qF "docker rmi img-alpha" "$3"' _ "$rc" "$rc2" "$TMP/out"

# a move across filesystems: an old .ai-containers it cannot remove whole, and an interrupt
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: an old .ai-containers that cannot be removed whole (running as root)\n'
else
  world
  A="$W/alpha"; mvproj "$A"; mkdir -p "$A/.ai-containers/stuck"; printf 'x\n' > "$A/.ai-containers/stuck/file"
  chmod 555 "$A/.ai-containers/stuck"; N="$W/beta"; export AI_CONTAINERS_MV_COPY=1
  mvrun "$A" "$N" --yes; rc=$?
  unset AI_CONTAINERS_MV_COPY
  ok "mv says to remove by hand what is left of an old .ai-containers it could not remove, not to run it again" \
    bash -c '[ "$1" = 1 ] && grep -qF "what is left of $3/.ai-containers is only a copy" "$2" && grep -qF "remove it by hand" "$2" \
             && ! grep -qF "project.sh mv" "$2" && [ -f "$4/.ai-containers/sandbox.env" ] && grep -qxF "$4" "$5"' \
    _ "$rc" "$TMP/out" "$A" "$N" "$ENG/projects.conf"
fi
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; export AI_CONTAINERS_MV_COPY=1 FAKE_CP_TERM=1
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_CP_TERM
ok "mv interrupted while it copies .ai-containers leaves no temp copy in <new-dir>" \
  bash -c '[ "$1" = 143 ] && [ -z "$(ls -A "$2" 2>/dev/null)" ] && [ -f "$3/.ai-containers/sandbox.env" ] && cmp -s "$4" "$5" \
           && grep -q "ERROR: interrupted" "$6"' _ "$rc" "$N" "$A" "$ENG/projects.conf" "$TMP/conf.before" "$TMP/out"

# a checkout whose .git is a file naming its git directory
world
A="$W/alpha"; mvproj "$A"
git init -q --separate-git-dir "$W/gitdir" "$A" 2>/dev/null && git -C "$A" add .ai-containers
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv notes that the old repository tracks .ai-containers when its .git is a file" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.git" ] && grep -qxF "NOTE: $2'"'"'s repository tracks .ai-containers/; those files now show as deleted there." "$3"' \
  _ "$rc" "$A" "$TMP/out"

# whose copies: this home's are carried and labelled this home's; another
# home's, launched from the same path on a shared daemon, stay
OTHER="sha256:$(printf '%064d' 9)"
world; A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkbase lib; WC_OWNER="$OTHER" mkwc lib 1 "$A/.ai-containers"
mvrun "$A" "$N" --yes; rc=$?
ok "mv labels the copy it makes with this home's owner id, and leaves another home's copy of the same launch dir" \
  bash -c '[ "$1" = 0 ] && grep -qxF "ai-containers.owner=$4" "$2/$3/labels" && [ -d "$2/ai-containers-repo-lib--wc-1" ] \
           && grep -qxF "ai-containers.launch-dir=$5/.ai-containers" "$2/ai-containers-repo-lib--wc-1/labels" \
           && ! grep -q "^docker volume create .*ai-containers.repo=lib" "$6"' _ "$rc" "$VOLS" "$nv" "$OWN" "$A" "$DOCKER_LOG"
ok "  … listing it as staying, and why" \
  hasx "  working copy ai-containers-repo-lib--wc-1 (lib) — stays: made by another home or user on this docker"
world; A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers" "ai-containers.owner=$OTHER"
wcdata "$nv" unpushed
mvrun "$A" "$N" --yes; rc=$?
ok "mv does not take another home's copy at the new name for one a run cut short made, though it is exact" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: the working copy $3 would be copied to $4, which exists and is not an exact copy" "$2" \
           && [ -d "$5/$3" ] && [ -d "$5/$4" ]' _ "$rc" "$TMP/out" "$OLDWC" "$nv" "$VOLS"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
# a copy launched from a directory in the project that holds a launcher of its own
world; A="$W/alpha"; mvproj "$A"; mkdir -p "$A/.ai-containers/base"
: > "$A/.ai-containers/base/sandbox.sh"; : > "$A/.ai-containers/base/sandbox-common.sh"
mkwc app 2 "$A/.ai-containers/base"; N="$W/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv leaves a working copy launched from a directory in the setup that holds a launcher of its own" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && grep -qxF "ai-containers.launch-dir=$3/.ai-containers/base" "$2/ai-containers-repo-app--wc-2/labels"' \
  _ "$rc" "$VOLS" "$A"
ok "  … listing it as staying, and why" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app) — stays: launched from $A/.ai-containers/base, which holds a launcher of its own"

# the pointers the launcher mounts beside the working directory
clash $'VAULT_PATH=/x/notes\n' "$W/new/vault" "and VAULT_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/vault" \
  "mv refuses a <new-dir> named vault where VAULT_PATH is set"
clash $'SPECS_PATH=/x/plans\n' "$W/new/specs" "and SPECS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/specs" \
  "mv refuses a <new-dir> named specs where SPECS_PATH is a host path"
clash $'DOCS_PATH=/x/manual:ro\n' "$W/new/docs" "and DOCS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/docs" \
  "mv refuses a <new-dir> named docs where DOCS_PATH is a host path, its :ro aside"
clash $'ARCHITECTURE_REPO_PATH=~/adr:rw\n' "$W/new/architecture" "and ARCHITECTURE_REPO_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/architecture" \
  "mv refuses a <new-dir> named architecture where ARCHITECTURE_REPO_PATH is set"
clash $'DOCS_PATH=@manual:ro\n' "$W/new/manual" "and DOCS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/manual" \
  "mv refuses a <new-dir> with the name of the repo an @name pointer attaches"
clash $'SPECS_PATH=@plans\n' "$W/new/plans" "and SPECS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/plans" \
  "mv refuses a <new-dir> with the name of SPECS_PATH's @name"
clash "VAULT_PATH=$W/new/vault"$'\n' "$W/new/vault" "/workspace/vault" \
  "mv refuses a <new-dir> named vault that VAULT_PATH itself names: the launcher mounts it twice"
export DOCS_PATH=/x/manual
clash '' "$W/new/docs" "and DOCS_PATH (set in your shell) would both be mounted at /workspace/docs" \
  "mv refuses a <new-dir> named docs where the shell sets DOCS_PATH"
export DOCS_PATH=''
world; A="$W/alpha"; mvproj "$A" '' $'DOCS_PATH=/x/manual\n'
mvrun "$A" "$W/new/docs" --yes; rc=$?
unset DOCS_PATH
ok "mv takes the shell's empty DOCS_PATH over the project's, as the launcher does" bash -c '[ "$1" = 0 ]' _ "$rc"

# EXTRA_MOUNTS and REPOS the shell exports: the launcher reads them over the
# project's sandbox.local.env, so mv checks them too, and says when the old root
# it adds to that file is not in the shell's list (it cannot write the shell).
export EXTRA_MOUNTS=/x/gamma
clash '' "$W/new/gamma" "and the EXTRA_MOUNTS entry /x/gamma (set in your shell) would both be mounted at /workspace/gamma" \
  "mv refuses a <new-dir> with the basename of an EXTRA_MOUNTS entry the shell sets"
export EXTRA_MOUNTS='/x/one ../shared'
relative '' "the EXTRA_MOUNTS entry ../shared in your shell is relative" "mv refuses a relative EXTRA_MOUNTS entry the shell sets, naming it and the shell"
unset EXTRA_MOUNTS
export REPOS='lib:ro delta:rw'
clash '' "$W/new/delta" "and the REPOS repo delta (set in your shell) would both be mounted at /workspace/delta" \
  "mv refuses a <new-dir> with the name of a REPOS repo the shell sets"
unset REPOS
# Not the engine's own: project.sh loads this checkout's sandbox.local.env into
# itself, and that is not what a project's launcher reads.
printf 'EXTRA_MOUNTS=/x/gamma\nREPOS=delta:rw\n' > "$ENG/sandbox.local.env"
world; A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/new/gamma" --yes; rc=$?
world; A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/new/delta" --yes; rc3=$?
rm -f "$ENG/sandbox.local.env"
ok "mv does not take the engine checkout's own EXTRA_MOUNTS or REPOS for the shell's" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 0 ] && [ -f "$3/new/delta/.ai-containers/sandbox.env" ]' _ "$rc" "$rc3" "$W"
# The old root added to sandbox.local.env, which the shell's EXTRA_MOUNTS
# shadows: said before the question and again at the end.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/x/one
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS does not mount the old root still adds it to sandbox.local.env" \
  bash -c '[ "$1" = 0 ] && grep -qxF "EXTRA_MOUNTS=\"$2\"" "$3/.ai-containers/sandbox.local.env"' _ "$rc" "$A" "$N"
ok "  … warning before the question that the shell's list does not mount it" \
  bash -c 'grep -qxF "WARNING: your shell exports EXTRA_MOUNTS, which the launcher reads instead of sandbox.local.env," "$1" \
           && grep -qxF "         and it does not mount $2: add it there, or the container will not see that" "$1" \
           && [ "$(grep -n "^WARNING: your shell" "$1" | cut -d: -f1)" -lt "$(grep -n "^Copied " "$1" | cut -d: -f1)" ]' _ "$TMP/out" "$A"
ok "  … and again at the end" hasx "WARNING: add $A to the EXTRA_MOUNTS your shell exports: the launcher reads that one, not"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="/x/one $W"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS mounts the old root read-write warns of nothing" \
  bash -c '[ "$1" = 0 ] && ! grep -q "your shell" "$2"' _ "$rc" "$TMP/out"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="$W:ro"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS mounts the old root only read-only says so, naming the entry" \
  bash -c '[ "$1" = 0 ] && grep -qxF "         and mounts $2 only read-only ($3:ro): add $2 to it, or the container" "$4"' _ "$rc" "$A" "$W" "$TMP/out"
# The launcher mounts the shell's EXTRA_MOUNTS or sandbox.local.env's, never
# both: the old root mv adds to the file cannot clash with a shell entry, and
# listing the old root there, as the warning says to, must not stop mv.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="$A"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS lists the old root itself moves, warning of nothing" \
  bash -c '[ "$1" = 0 ] && ! grep -q "your shell" "$2" && grep -qxF "EXTRA_MOUNTS=\"$3\"" "$4/.ai-containers/sandbox.local.env"' _ "$rc" "$TMP/out" "$A" "$N"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/mnt/other/alpha
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where a shell entry has the old root's basename moves, and says that adding it there would clash" \
  bash -c '[ "$1" = 0 ] && grep -qxF "         Its entry /mnt/other/alpha has the same basename, /workspace/alpha: the launcher would refuse" "$2"' _ "$rc" "$TMP/out"
# The closing warning is not lost when a later step fails.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/x/one FAKE_FAIL_VOLUME_RM='*--wc-1'
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS FAKE_FAIL_VOLUME_RM
ok "mv that fails to remove an old working copy still says to add the old root to the shell's EXTRA_MOUNTS" \
  bash -c '[ "$1" = 1 ] && grep -qxF "WARNING: add $2 to the EXTRA_MOUNTS your shell exports: the launcher reads that one, not" "$3"' _ "$rc" "$A" "$TMP/out"

world; A="$W/outer/alpha"; mvproj "$A"; N="$W/outer"
export EXTRA_MOUNTS=/x/one
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv into a directory that holds the old root warns of nothing about the shell's EXTRA_MOUNTS" \
  bash -c '[ "$1" = 0 ] && grep -qF "lies inside $3, which the container mounts" "$2" && ! grep -q "your shell" "$2"' _ "$rc" "$TMP/out" "$N"
world; A="$W/alpha"; N="$W/new/docs"; mvproj "$A" '' "DOCS_PATH=$N:ro"$'\n'
mvrun "$A" "$N" --yes; rc=$?
ok "mv takes a <new-dir> named docs that DOCS_PATH itself names: the launcher mounts the working directory once" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ]' _ "$rc" "$N"
world; A="$W/docs"; mvproj "$A" '' $'DOCS_PATH=/x/manual\n'
mvrun "$A" "$W/new/beta" --yes; rc=$?
ok "mv refuses an old root named docs it would add to EXTRA_MOUNTS where DOCS_PATH is set" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: $2, which mv would add to EXTRA_MOUNTS, and DOCS_PATH (set in $2/.ai-containers/sandbox.local.env) would both be mounted at" "$3" \
           && [ ! -e "$4" ]' _ "$rc" "$A" "$TMP/out" "$W/new/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a read-only entry that covers the old root: it was the read-write working
# directory, and the container must not see it read-only after the move
world; A="$W/alpha"; mvproj "$A" '' "EXTRA_MOUNTS=\"/x/one $W:ro\""$'\n'; N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf 'EXTRA_MOUNTS="\n  /x/one\n  %s:ro\n  %s\n"\n' "$W" "$A" > "$TMP/expect"
ok "mv adds the old root itself where only a read-only entry covers it" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
ok "  … saying why" hasx "              $W:ro covers it read-only, and it was the read-write working directory"

# interrupted while it copies the working copies: what it made goes again
world; A="$W/alpha"; mvproj "$A"; mkbase lib; mkwc lib 1 "$A/.ai-containers"; wcdata ai-containers-repo-lib--wc-1 libwork
N="$W/new/beta"; nva="$(wcname app "$N/.ai-containers")"; nvl="$(wcname lib "$N/.ai-containers")"
export FAKE_RUN_TERM=2
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_RUN_TERM
ok "mv interrupted while it copies the working copies removes those it made, the one it was making too" \
  bash -c '[ "$1" = 143 ] && [ ! -e "$2/$3" ] && [ ! -e "$2/$4" ] && [ "$(cat "$2/$5/data/work")" = unpushed ] \
           && [ "$(cat "$2/ai-containers-repo-lib--wc-1/data/work")" = libwork ] && [ -f "$6/.ai-containers/sandbox.env" ] \
           && [ ! -e "$7" ] && cmp -s "$8" "$9"' _ "$rc" "$VOLS" "$nva" "$nvl" "$OLDWC" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before"
ok "  … naming the real <new-dir>, and the command that finishes" \
  bash -c 'grep -qxF "ERROR: interrupted; what was done is listed above, and no temporary copy is left in $2." "$1" \
           && grep -qF "run ./project.sh mv $3 $2 again" "$1"' _ "$TMP/out" "$N" "$A"

# another REPO_VOLUME_PREFIX in the project's sandbox.local.env
world; A="$W/alpha"; mvproj "$A" '' $'REPO_VOLUME_PREFIX=other\n'
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a project whose sandbox.local.env sets another REPO_VOLUME_PREFIX, saying how to run it" \
  bash -c '[ "$1" = 1 ] && grep -qxF "         REPO_VOLUME_PREFIX=other ./project.sh mv $2 $3" "$4" && [ ! -e "$3" ]' _ "$rc" "$A" "$W/beta" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a stopped container that uses an old copy: docker would refuse to remove it
# once the setup had moved
world; A="$W/alpha"; mvproj "$A"
printf 'ctr-old|some-image|/var/lib/docker/volumes/%s/_data\n' "$OLDWC" > "$FAKE_STOPPED"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses up front when a stopped container uses an old working copy, naming it and docker rm" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: the working copy $2 is used by the container(s) ctr-old" "$3" && grep -qF "(docker rm ctr-old;" "$3" \
           && [ ! -e "$4" ]' _ "$rc" "$OLDWC" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a <new-dir> registered already
world; A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; printf '%s/\n' "$N" >> "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
if [[ "$rc" == 0 && "$(sed -n 2p "$TMP/out")" == "WARNING: $N/ is a registered project already, IMAGE_NAME img-alpha: mv takes its .ai-containers" ]]; then
  pass "mv into a <new-dir> registered already warns first, naming its IMAGE_NAME"
else
  fail "mv into a <new-dir> registered already warns first, naming its IMAGE_NAME (rc=$rc; lines 1-3: $(sed -n 1,3p "$TMP/out" | tr '\n' '|'))"
fi
ok "  … and leaves one projects.conf line for it, as it was spelled" bash -c '[ "$(cat "$1")" = "$2/" ]' _ "$ENG/projects.conf" "$N"
world; A="$W/alpha"; mvproj "$A"; N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"
printf '/x/other\n%s/\n' "$N" > "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv of a project gc dropped, into a <new-dir> registered under another spelling, adds no second line" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/other\n%s/" "$3")" ]' _ "$rc" "$ENG/projects.conf" "$N"

# ── gc ──
gcrun() { ( cd "$TMP" && bash "$P" gc "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
# gcworld: world, with $W holding something: a path whose nearest existing
# directory is an empty one may be on a drive that is not mounted, and is kept.
gcworld() { world; mkdir -p "$W/other"; }
gc_nothing() {  # nothing was removed: no volume or image, the registries as saved
  ! logged '^docker (volume rm|rmi)' && cmp -s "$ENG/projects.conf" "$TMP/conf.before" && cmp -s "$IP" "$TMP/ip.before"
}
gc_save() { cp "$ENG/projects.conf" "$TMP/conf.before"; cp "$IP" "$TMP/ip.before"; }

gcworld
mkproj "$W/live"; mkproj "$W/alpha"; rm -rf "$W/alpha/.ai-containers"; printf 'hi\n' > "$W/alpha/README"
mkproj "$W/beta"; rm -rf "$W/beta"
gcrun --yes; rc=$?
ok "gc drops a projects.conf line whose project has no .ai-containers" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ] && [ -f "$4/README" ]' _ "$rc" "$ENG/projects.conf" "$W/live" "$W/alpha"
ok "  … listing each first, with --yes too" \
  bash -c 'grep -qxF "About to remove:" "$1" && grep -qxF "  registry    $2 (projects.conf: it has no .ai-containers)" "$1" \
           && grep -qxF "  registry    $3 (projects.conf: it has no .ai-containers)" "$1"' _ "$TMP/out" "$W/alpha" "$W/beta"

gcworld
mkdir -p "$W/drive" "$W/mnt"; printf '%s\n%s\n' "$W/drive/proj" "$W/mnt" > "$ENG/projects.conf"
mkproj "$W/alpha"; rm -rf "$W/alpha"
gcrun --yes; rc=$?
ok "gc keeps and names a line whose nearest existing directory is empty" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "%s\n%s" "$3/drive/proj" "$3/mnt")" ] \
           && grep -qF "  registry    $3/drive/proj (projects.conf) — kept: it may be on a drive that is not mounted: $3/drive is empty" "$4" \
           && grep -qF "  registry    $3/mnt (projects.conf) — kept: it may be on a drive that is not mounted: $3/mnt is empty" "$4"' \
  _ "$rc" "$ENG/projects.conf" "$W" "$TMP/out"
ok "  … with the way out if it is gone for good" has_line "if it is gone for good, ./project.sh rm $W/drive/proj removes its line"

gcworld
mkproj "$W/live" $'IMAGE_NAME=img-live\n'
printf '# ai-containers: the project each image id names (build.sh). id|path\n' > "$IP"; built "$W/live" img-live
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" >> "$IP"; rm -rf "$A"
idl="$(tid "$W/live/.ai-containers")"
gcrun --yes; rc=$?
printf '# ai-containers: the project each image id names (build.sh). id|path\n%s|%s\n' "$idl" "$(cd "$W/live/.ai-containers" && pwd -P)" > "$TMP/expect"
ok "gc drops an image-projects.conf line whose path is gone and whose id no image carries" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3" && [ -e "$4" ] && ! grep -q "^docker rmi" "$5"' _ "$rc" "$IP" "$TMP/expect" "$IMGS/img-live" "$DOCKER_LOG"

gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
pa="$(cd "$A/.ai-containers" && pwd -P)"; rm -rf "$A"
gcrun --yes; rc=$?
ok "gc lists an image whose project is gone, removes it on --yes, then drops its line" \
  bash -c '[ "$1" = 0 ] && grep -qxF "  image       img-alpha:latest (built for $2, which is gone)" "$3" && [ ! -e "$4" ] \
           && ! grep -q -- " -f" < <(grep "^docker rmi" "$5") && ! grep -qF "$6" "$7" \
           && r="$(grep -n "^docker rmi img-alpha" "$5" | cut -d: -f1)" && c="$(grep -n "^docker images -q" "$5" | tail -1 | cut -d: -f1)" \
           && [ -n "$r" ] && [ -n "$c" ] && [ "$r" -lt "$c" ]' \
  _ "$rc" "$pa" "$TMP/out" "$IMGS/img-alpha" "$DOCKER_LOG" "$ida" "$IP"
gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"; rm -rf "$A"
export FAKE_FAIL_RMI=1
gcrun --yes; rc=$?
unset FAKE_FAIL_RMI
ok "  … and keeps its line while an image it could not remove carries the id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && grep -qF "NOTE: an image still carries" "$5"' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$TMP/out"
gcworld
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"; rm -rf "$A"
printf 'ai-containers.project=%s\n' "$ida" > "$IMGS/dangling-1"
gcrun --yes; rc=$?
ok "gc removes an image that has no tag by its id" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && grep -qxF "docker rmi dangling-1" "$3" && ! grep -qF "$4" "$5"' \
  _ "$rc" "$IMGS/dangling-1" "$DOCKER_LOG" "$ida" "$IP"

gcworld
mkproj "$W/live"; mkbase app
mkwc app 1 "$W/gone1/.ai-containers" "$CLEAN"
mkwc app 2 "$W/gone2/.ai-containers" $'PRIMARY|main\nBRANCH|main|0|current\nBRANCH|feature|2|\nWORKTREE|clean\nEND|inspect\n'
mkwc app 3 "$W/live/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc lists working copies whose launch dir is gone, with their risk, and removes them on --yes" \
  bash -c '[ "$1" = 0 ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $2/gone1/.ai-containers) — nothing at risk: every branch pushed, no stash, the checkout clean" "$3" \
           && grep -qF "  working copy ai-containers-repo-app--wc-2 (app, launched from $2/gone2/.ai-containers) — AT RISK: feature: 2 unpushed" "$3" \
           && grep -qxF "1 working cop(y/ies) at risk or not checked." "$3" \
           && [ "$(sed -n "s/^docker volume rm //p" "$4" | LC_ALL=C sort | tr "\n" " ")" = "ai-containers-repo-app--wc-1 ai-containers-repo-app--wc-2 " ] \
           && [ -d "$5/ai-containers-repo-app--wc-3" ]' _ "$rc" "$W" "$TMP/out" "$DOCKER_LOG" "$VOLS"

gcworld; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
printf 'ctr-wc|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING"
gcrun --yes; rc=$?
ok "gc keeps a working copy a running container uses" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: a running container uses it (ctr-wc)" "$5" \
           && grep -qxF "Nothing to collect." "$5"' _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"; rm -rf "$A"
printf 'ctr-old|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_STOPPED"
gcrun --yes; rc=$?
ok "gc keeps a working copy a stopped container uses, and collects the rest" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$9" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $3/gone/.ai-containers) — kept: a stopped container uses it (ctr-old); docker rm it first" "$4" \
           && [ ! -e "$5" ] && ! grep -qF "$6" "$7" && ! grep -qxF "$3/alpha" "$8"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out" "$IMGS/img-alpha" "$ida" "$IP" "$ENG/projects.conf" "$DOCKER_LOG"
gcworld; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
export FAKE_PS_FAIL=1
gcrun --yes; rc=$?
unset FAKE_PS_FAIL
ok "gc keeps a working copy when docker cannot tell whether a container uses it" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qF "ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: docker could not list" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"

gcworld; A="$W/alpha"; mkproj "$A"; rm -rf "$A"
gcrun; rc=$?
ok "gc points a vanished project at project.sh mv, saying what gc would cost it" \
  bash -c 'grep -qxF "              If $1 was moved rather than deleted, answer no and run ./project.sh mv $1 <new-dir>:" "$2" \
           && grep -qxF "              gc would remove the working copies launched from it, which mv carries to the new" "$2" \
           && grep -qxF "              place; after gc, mv only registers the new place." "$2" && ! grep -qF "also works after gc" "$2"' _ "$A" "$TMP/out"

gcworld
mkproj "$W/live" $'IMAGE_NAME=img-live\n'; built "$W/live" img-live; mkbase app; mkwc app 1 "$W/live/.ai-containers" "$CLEAN"
gc_save
gcrun --yes; rc=$?
ok "gc with nothing stale says so and exits 0" \
  bash -c '[ "$1" = 0 ] && grep -qxF "Nothing to collect." "$2" && ! grep -q "About to remove" "$2" && ! grep -q "^Kept:" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" gc_nothing

gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
gcrun; rc=$?
ok "gc refuses on a non-TTY without --yes, changing nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "^ERROR: " "$2" && grep -qxF "Nothing was removed." "$2" \
           && [ -e "$3" ] && [ -d "$4/ai-containers-repo-app--wc-1" ]' _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$VOLS"
ok "  … and the registries are as they were" gc_nothing

gcworld
mkdir -p "$W/live1/.ai-containers" "$W/live two/.ai-containers"
printf '# comment\n\n%s\r\n%s\nrel/proj\n%s' "$W/alpha" "$W/live two" "$W/live1" > "$ENG/projects.conf"
gcrun --yes; rc=$?
printf '# comment\n\n%s\nrel/proj\n%s' "$W/live two" "$W/live1" > "$TMP/expect"
ok "gc keeps every other projects.conf byte" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$ENG/projects.conf" "$TMP/expect"
ok "  … and names a line that is not an absolute path, which it keeps" \
  has_line "  registry    rel/proj (projects.conf) — kept: it is not an absolute path"

# what may only look gone: a drive that is not mounted, a directory that cannot be searched
gcworld; mkdir -p "$W/drive"; idd="sha256:$(printf '%064d' 5)"
printf '%s|%s\n' "$idd" "$W/drive/proj/.ai-containers" > "$IP"; printf 'ai-containers.project=%s\n' "$idd" > "$IMGS/img-drive"
gcrun --yes; rc=$?
ok "gc keeps an image whose project path may be on an unmounted drive" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && ! grep -q "^docker rmi" "$5" \
           && grep -qxF "  image       img-drive:latest (built for $6/drive/proj/.ai-containers) — kept: it may be on a drive that is not mounted: $6/drive is empty" "$7" \
           && grep -qxF "  registry    $6/drive/proj/.ai-containers (image-projects.conf) — kept: it may be on a drive that is not mounted: $6/drive is empty" "$7"' \
  _ "$rc" "$IMGS/img-drive" "$idd" "$IP" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; mkdir -p "$W/drive"; mkbase app; mkwc app 1 "$W/drive/proj/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy whose launch dir may be on an unmounted drive" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/drive/proj/.ai-containers) — kept: it may be on a drive that is not mounted: $4/drive is empty" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
# a logical path (a projects.conf root, a launch dir) can cross a link whose
# target is on a drive that is not mounted: the link is there and leads nowhere
gcworld; ln -s "$W/nowhere/work" "$W/work"; mkbase app; mkwc app 1 "$W/work/proj/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy whose launch dir is reached through a link that leads nowhere" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/work/proj/.ai-containers) — kept: it may only look gone: $4/work is a link to something that is not there" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; ln -s "$W/nowhere/work" "$W/work"; printf '%s\n' "$W/work/proj" > "$ENG/projects.conf"
gcrun --yes; rc=$?
ok "gc keeps a projects.conf line whose root is reached through a link that leads nowhere" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" \
           && grep -qF "  registry    $2 (projects.conf) — kept: it may only look gone: $4/work is a link to something that is not there" "$5"' \
  _ "$rc" "$W/work/proj" "$ENG/projects.conf" "$W" "$TMP/out"
# a removable-media root (/media/<user>, /Volumes) cannot be made here: the
# helper's own test of one, with _ac_removable_root taking $W/media for one
gcworld; mkdir -p "$W/media/other"
r="$( cd "$TMP" && source "$P" && _ac_removable_root() { [[ "${1%/}" == "$W/media" ]]; } \
      && _prj_maybe_unmounted "$W/media/drive/proj/.ai-containers" )"; rc=$?
ok "gc keeps a path whose nearest existing directory is where removable drives are mounted" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "it may be on a drive that is not mounted: $3/media is where removable drives are mounted" ]' _ "$rc" "$r" "$W"
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: a project under a directory that cannot be searched (running as root)\n'
else
  gcworld; mkproj "$W/locked/proj"; chmod 000 "$W/locked"
  gcrun --yes; rc=$?
  chmod 755 "$W/locked"
  ok "gc keeps a line under a directory it cannot search" \
    bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && grep -qF "  registry    $2 (projects.conf) — kept: it may only look gone: $4 cannot be searched" "$5"' \
    _ "$rc" "$W/locked/proj" "$ENG/projects.conf" "$W/locked" "$TMP/out"
fi

# rm's safety pattern
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
export FAKE_DOCKER_DOWN=1
gcrun --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "gc refuses when docker cannot be reached" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: docker cannot be reached" "$2" && [ -e "$3" ] && [ -d "$4/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$VOLS"
ok "  … changing nothing" gc_nothing
# the listing makes three volume= ps calls for the copy (whether a running or a
# stopped container uses it, and the git helper's read-write check); the one
# after the question sees it in use
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
printf 'ctr-late|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING.later"
export FAKE_VOLPS_AFTER=3
gcrun --yes; rc=$?
unset FAKE_VOLPS_AFTER
ok "gc checks again after the question, and refuses a copy a container started using meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "^ERROR: .*started using .*after the listing.*ctr-late" "$2" \
           && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' _ "$rc" "$TMP/out" "$VOLS" "$IMGS/img-alpha"
ok "  … changing nothing" gc_nothing
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
export FAKE_FAIL_VOLUME_RM='*'
gcrun --yes; rc=$?
unset FAKE_FAIL_VOLUME_RM
ok "gc stops when a working copy cannot be removed, before the images and the registry lines" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: could not remove the working copy" "$2" && [ -e "$3" ] && ! grep -q "^docker rmi" "$4"' \
  _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$DOCKER_LOG"
ok "  … the registries as they were" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ "$ENG/projects.conf" "$TMP/conf.before" "$IP" "$TMP/ip.before"

# links: a project's .ai-containers, and the registries themselves
gcworld; mkdir -p "$W/linky"; ln -s "$W/nowhere" "$W/linky/.ai-containers"; printf '%s\n' "$W/linky" > "$ENG/projects.conf"
gcrun --yes; rc=$?
ok "gc keeps and names a line whose .ai-containers is a link" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && grep -qF "  registry    $2 (projects.conf) — kept: its .ai-containers is a link" "$4"' \
  _ "$rc" "$W/linky" "$ENG/projects.conf" "$TMP/out"
gcworld; mkdir -p "$W/live/.ai-containers"; printf '%s\n%s\n' "$W/live" "$W/gone" > "$TMP/real-conf"
ln -s "$TMP/real-conf" "$ENG/projects.conf"; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc does not read a linked projects.conf, and still collects the rest" \
  bash -c '[ "$1" = 0 ] && [ -L "$2" ] && [ "$(cat "$3")" = "$(printf "%s\n%s" "$4/live" "$4/gone")" ] \
           && grep -qF "  registry    $2 — not read: it is a link" "$5" && [ ! -d "$6/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$ENG/projects.conf" "$TMP/real-conf" "$W" "$TMP/out" "$VOLS"
gcworld; rm -f "$ENG/projects.conf"
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"; rm -rf "$A"; rm -f "$ENG/projects.conf"
printf '%s|%s\n' "$ida" "$A/.ai-containers" > "$TMP/real-ip"; ln -s "$TMP/real-ip" "$IP"
printf 'ai-containers.project=%s\n' "$ida" > "$IMGS/img-alpha"
gcrun --yes; rc=$?
ok "gc does not read a linked image-projects.conf, and removes no image through it" \
  bash -c '[ "$1" = 0 ] && [ -L "$2" ] && [ -e "$3" ] && ! grep -q "^docker rmi" "$4" && grep -qF "  registry    $2 — not read: it is a link" "$5"' \
  _ "$rc" "$IP" "$IMGS/img-alpha" "$DOCKER_LOG" "$TMP/out"
rm -f "$IP"

# a project moved by hand, its line stale: gc says on its copy's line that mv
# carries that copy; after gc, mv has nothing left to carry, and says so
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" $'PRIMARY|main\nBRANCH|main|3|current\nWORKTREE|clean\nEND|inspect\n'; wcdata ai-containers-repo-app--wc-1 unpushed
N="$W/moved"; mv "$A" "$N"
gcrun; rc=$?
ok "gc says on the copy line of a project whose line it drops that mv would carry the copy" \
  bash -c '[ "$1" = 1 ] && awk -v c="  working copy ai-containers-repo-app--wc-1 (app, launched from $2/.ai-containers) — AT RISK: main: 3 unpushed commit(s)" \
             -v h="              From $2, listed above: if it was moved, answer no and run ./project.sh mv, which" \
             '"'"'p { ok = ($0 == h); p = 0 } $0 == c { p = 1 } END { exit !ok }'"'"' "$3"' _ "$rc" "$A" "$TMP/out"
gcrun --yes; rc1=$?
mvrun "$A" "$N" --yes; rc2=$?
ok "  … and once gc removed it, mv only registers the new place, saying no copy is left to carry" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 0 ] && [ ! -e "$3/ai-containers-repo-app--wc-1" ] && [ "$(cat "$4")" = "$5" ] \
           && grep -qxF "  working copy none launched from $6 is left to carry (./project.sh gc, run since the" "$7" \
           && ! grep -qF "Copied the working copy" "$7"' _ "$rc1" "$rc2" "$VOLS" "$ENG/projects.conf" "$N" "$A" "$TMP/out"

# whose copies gc offers: this home's; another home's, on a daemon several share,
# only with --all
gcworld; mkbase app; WC_OWNER="$OTHER" mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy another home made" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && grep -qxF "Nothing to collect." "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: made by another home or user on this docker (./project.sh gc --all offers it)" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
gcrun --all --yes; rc=$?
ok "  … and gc --all offers it, saying whose it is, and removes it" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers; made by another home or user on this docker) — nothing at risk: every branch pushed, no stash, the checkout clean" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
# one with no owner label (made before there was one): offered under a path this
# home's registries know, kept elsewhere
gcworld; mkbase app; mkproj "$W/live"; printf '%s\n' "$W/stale" >> "$ENG/projects.conf"
printf 'sha256:%064d|%s\n' 4 "$W/built/.ai-containers" > "$IP"
WC_OWNER='' mkwc app 1 "$W/nowhere/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 2 "$W/stale/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 3 "$W/built/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 4 "$W/live/gone-sub" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps an unlabelled working copy under no path this home's registries know" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/nowhere/.ai-containers) — kept: unlabelled, under no path this home knows (./project.sh gc --all offers it)" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
ok "  … and removes one under a stale or live projects.conf root, or a project image-projects.conf maps" \
  bash -c '[ ! -e "$1/ai-containers-repo-app--wc-2" ] && [ ! -e "$1/ai-containers-repo-app--wc-3" ] && [ ! -e "$1/ai-containers-repo-app--wc-4" ]' _ "$VOLS"
gcrun --all --yes; rc=$?
ok "  … which gc --all offers, saying it is unlabelled" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/nowhere/.ai-containers; unlabelled, under no path this home knows) — " "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
# with --all, another home's copy is still kept while a container, running or
# stopped, uses it, or while its launch dir may only look gone
gcworld; mkbase app
WC_OWNER="$OTHER" mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
WC_OWNER="$OTHER" mkwc app 2 "$W/gone2/.ai-containers" "$CLEAN"
printf 'ctr-run|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING"
printf 'ctr-old|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-2/_data\n' > "$FAKE_STOPPED"
gcrun --all --yes; rc=$?
ok "gc --all keeps another home's copy a container uses, running or stopped, saying so" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && ! grep -q "^docker volume rm" "$5" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $3/gone/.ai-containers; made by another home or user on this docker) — kept: a running container uses it (ctr-run)" "$4" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-2 (app, launched from $3/gone2/.ai-containers; made by another home or user on this docker) — kept: a stopped container uses it (ctr-old); docker rm it first" "$4"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out" "$DOCKER_LOG"
gcworld; mkbase app; mkdir -p "$W/drive"; WC_OWNER="$OTHER" mkwc app 3 "$W/drive/proj/.ai-containers" "$CLEAN"
gcrun --all --yes; rc=$?
ok "gc --all keeps another home's copy whose launch dir may be on a drive that is not mounted, saying so" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-3" ] && grep -qxF "Nothing to collect." "$4" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-3 (app, launched from $3/drive/proj/.ai-containers; made by another home or user on this docker) — kept: it may be on a drive that is not mounted: $3/drive is empty" "$4"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out"

# a command printed to be pasted keeps a path, or a name the project's files
# give, with a space as one argument: cmd_word <line marker> <after> <before>
# <n> is, on the first line of the output holding <line marker>, the command
# printed between <after> and <before> (the line's end when empty) as a shell
# parses it, its <n>th word
cmd_word() {
  local l c
  local -a w=()
  l="$(grep -F -- "$1" "$TMP/out" | head -1)"
  c="${l#*"$2"}"; if [[ -n "$3" ]]; then c="${c%%"$3"*}"; fi
  eval "w=($c)" 2>/dev/null || return 1
  printf '%s' "${w[$4-1]-}"
}
world; S="$W/my proj"; mkproj "$S" '' $'REPO_VOLUME_PREFIX=other\n'
rmrun "$S" --yes
ok "the REPO_VOLUME_PREFIX refusal's command keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "REPO_VOLUME_PREFIX=other ./project.sh rm" "" "" 4)" "$S"
world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers" "$CLEAN"
export FAKE_FAIL_VOLUME_RM='*'
rmrun "$S" --yes
unset FAKE_FAIL_VOLUME_RM
ok "rm's run-it-again command keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "again once it can be" "run " " again" 3)" "$S"
world; S="$W/my proj"; mkproj "$S"; rm -rf "$S/.ai-containers"
rmrun "$S"
ok "rm's mv hint keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "answer no and run ./project.sh mv" "and run " " <new-dir>" 3)" "$S"
gcworld; S="$W/my proj"; mkproj "$S"; rm -rf "$S"; mkdir -p "$W/drive"; printf '%s\n' "$W/drive/my proj" >> "$ENG/projects.conf"
gcrun
ok "gc's mv hint and its rm hint keep a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "answer no and run ./project.sh mv" "and run " " <new-dir>" 3)" "$S" \
  "$(cmd_word "if it is gone for good" "gone for good, " " removes its line" 3)" "$W/drive/my proj"
world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; export FAKE_FAIL_VOLUME_RM="$OLDWC"
mvrun "$S" "$N" --yes
unset FAKE_FAIL_VOLUME_RM
ok "mv's run-it-again command keeps both paths with a space as one argument each" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "again to remove them" "       " " again" 3)" "$S" \
  "$(cmd_word "again to remove them" "       " " again" 4)" "$N"
world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; export FAKE_RUN_TERM=1
mvrun "$S" "$N" --yes
unset FAKE_RUN_TERM
ok "mv's command after an interrupt keeps both paths with a space as one argument each" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "again to move the project" "; run " " again" 3)" "$S" \
  "$(cmd_word "again to move the project" "; run " " again" 4)" "$N"
world; mkproj "$W/a1" '' $'AI_CONTAINER_GROUP=my group\n'
rmrun "$W/a1" --yes
ok "rm's ./group.sh rm keeps a group name with a space as one argument" \
  bash -c '[ "$1" = "my group" ]' _ "$(cmd_word "remove it with ./group.sh rm" "remove it with " "" 3)"

out="$(bash "$P" --help 2>&1)"
ok "the usage says what gc --all is for" \
  bash -c '[[ "$1" == *"./project.sh gc  [--all] [--yes]"* && "$1" == *"gc --all offers those too: copies made before owner labels,"* ]]' _ "$out"

# gc that cannot rewrite a registry it drops a line from exits 1, and leaves
# what a re-run needs: an image-projects.conf line first (the projects.conf
# lines kept), a projects.conf line last
fake_mktemp
gcworld; A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"; rm -rf "$A"; gc_save
( export FAKE_MKTEMP_BAD='.image-projects.conf.new.*' FAKE_MKTEMP_HOW=dir; gcrun --yes ); rc=$?
rm -rf "$HOME/.ai-containers"/.image-projects.conf.new.*
ok "gc exits 1 when an image-projects.conf line it drops cannot be rewritten, and keeps the projects.conf lines" \
  bash -c '[ "$1" = 1 ] && grep -qxF "       The projects.conf lines are kept; run ./project.sh gc again." "$2" && ! grep -q "^OK:" "$2" \
           && cmp -s "$3" "$4" && cmp -s "$5" "$6"' _ "$rc" "$TMP/out" "$ENG/projects.conf" "$TMP/conf.before" "$IP" "$TMP/ip.before"
gcworld; mkproj "$W/alpha"; rm -rf "$W/alpha"; cp "$ENG/projects.conf" "$TMP/conf.before"
( export FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir; gcrun --yes ); rc=$?
rm -rf "$ENG"/.projects.conf.new.*
ok "gc exits 1 when a projects.conf line it drops cannot be rewritten, saying so" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: cannot read .*projects.conf, or write its new content beside it" "$2" && ! grep -q "^OK:" "$2" \
           && cmp -s "$3" "$4"' _ "$rc" "$TMP/out" "$ENG/projects.conf" "$TMP/conf.before"
rm -f "$TMP/bin/mktemp"

# what a label or a registry line holds reaches the terminal without its escapes
gcworld; E="$W/esc${ESC}[2Jgone"; printf '%s\n' "$E" > "$ENG/projects.conf"; mkbase app; mkwc app 1 "$E/.ai-containers" "$CLEAN"
gcrun; rc=$?
ok "gc prints a registered root and a launch dir holding an ESC byte without it" \
  bash -c '[ "$1" = 1 ] && grep -qF "registry    $2/esc?[2Jgone (projects.conf" "$3" && grep -qF "launched from $2/esc?[2Jgone/.ai-containers" "$3" \
           && ! grep -q "$4" "$3"' _ "$rc" "$W" "$TMP/out" "$ESC"

echo
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
