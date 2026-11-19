#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# tests/lib-project-tool.sh — what the tests/test-project-*.sh files share: an
# engine copy and HOME in a temp dir, a fake docker keeping a small world of
# volumes, images and containers, and the helpers that make projects, images and
# working copies in it. Sourced, never run.
#
# One file was one oracle of two minutes, which kept project.sh out of the
# falsify tier (feature-gaps review GAP-28); split by command, each mutant can be
# run against the file whose coverage reaches it.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: the engine is here at the repo root, and in base/ in a
# checkout that keeps it there (mgd-ai-containers), as ENGINE_DIR is elsewhere.
# REPO_DIR names the engine; TESTS_HERE names this directory.
# shellcheck disable=SC2034  # TESTS_HERE is read by the test files that source this
TESTS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$REPO_DIR/sandbox.sh" ]] || REPO_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
ok()   { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# chmod first: a mutant can leave a directory here that its owner cannot
# enter, and a bare rm -rf then leaves the whole tree behind in TMPDIR.
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
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
# send TERM to the shell that ran docker, and FAKE_VOLRM_TERM=<volume> does so
# once that volume is removed. `volume create` makes a volume with
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
      [[ "$v" != "${FAKE_VOLRM_TERM:-}" ]] || kill -TERM "$PPID"
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


# The image-projects.conf build.sh keeps.
mkdir -p "$HOME/.ai-containers"
IP="$HOME/.ai-containers/image-projects.conf"

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
# Another home's, for a copy made by a home on the same daemon that is not this one.
# shellcheck disable=SC2034  # read by the test files that source this
OTHER="sha256:$(printf '%064d' 9)"

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
# shellcheck disable=SC2034  # read by the test files that source this
CLEAN=$'PRIMARY|main\nBRANCH|main|0|current\nWORKTREE|clean\nEND|inspect\n'
rmrun() { ( cd "$TMP" && bash "$P" rm "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
hasx()  { grep -qxF -- "$1" "$TMP/out"; }
has_line() { grep -qF -- "$1" "$TMP/out"; }
lacks() { ! grep -qF -- "$1" "$TMP/out"; }
logged() { grep -qE -- "$1" "$DOCKER_LOG"; }
# mv, and a working copy's files (gc's checks run it too)
mvrun() { ( cd "$TMP" && bash "$P" mv "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
wcdata() { mkdir -p "$VOLS/$1/data"; printf '%s\n' "$2" > "$VOLS/$1/data/work"; }

# what the agent can write reaches the terminal without its escapes
# shellcheck disable=SC2034  # read by the test files that source this
ESC=$'\e'


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
