#!/usr/bin/env bash
# version.sh — what this engine reports about itself.
#
# Three numbers, three different sources, and only one of them can lie:
#
#   ENGINE RELEASE  git tags in the base repo. A project's .ai-containers/ is a
#                   working COPY, not a git repo, so it cannot ask — it has to
#                   have been told, and project-init.sh/sync-to-projects.sh tell
#                   it by writing `engine-version` at copy time. A copy that was
#                   never told says `unknown`; it does not fall back to the git
#                   repo the caller happens to be standing in, which would report
#                   a version belonging to some other tree entirely.
#   SCHEMA VERSION  sandbox.conf's `# schema-version:` marker.
#   nvm VERSION     sandbox.conf's `nvm-version=`. This one is pinned rather than
#                   detected because nvm's latest cannot be resolved at build
#                   time behind a rate limit; .github/workflows/update-nvm-version.yml
#                   exists solely to keep the Dockerfile's ARG NVM_VERSION
#                   current, which the empty default reports, so reporting it is
#                   normally reporting that job's output. An EMPTY value is not "no nvm" —
#                   it means the Dockerfile's own ARG default applies, and the
#                   report says which, because the question being asked is what
#                   the IMAGE will get, not what the file happens to contain.
#
# `git describe --tags`, not `--abbrev=0`: the suffix is the honest part. A copy
# taken five commits after v0.7.0 is not v0.7.0, and `v0.7.0-5-gefce881` says so.

# ── Asking the engine's git, safely (bugs review GIT-28) ─────────────────────
# The engine checkout is the agent's to write when a launch mounts it, and its
# config can include a file the agent writes. `git describe --tags --dirty`
# read that config, includes and all, with no bound, so a FIFO an include names
# hung `--version` and every sync; --dirty refreshed the index, which ran
# core.fsmonitor and a clean filter (measured, git 2.56); and a commit missing
# from a partial clone started a fetch, which ran the remote's uploadpack, a
# bundle URI's helper and a credential helper the config named (reviews of the
# fix). Patching what git reads there one key at a time found a new key each
# review, and copying the repository's files for git to read let links and hard
# links the agent planted fill memory and TMPDIR. So git never reads anything
# of the checkout but its objects (_ver_git_version): HEAD, the branch and the
# tags are read here as small regular files, never through a link, and written
# for git as data; -dirty, which needs the index and the worktree, is not
# reported at all (the user's choice). Every call is bounded (_ver_secs,
# _ver_run). Nothing here asks git anything on macOS without the Command Line
# Tools (_ver_git_runs).
_ver_secs=10 _ver_cur="" _ver_cur_dir="" _ver_dir="" _ver_n=0
# _ver_stop: the INT, TERM and HUP traps of the subshells that ask git. The
# command _ver_run runs as a background job never gets a signal sent to the
# subshell alone, and it ignores SIGINT, as an asynchronous command of a shell
# without job control does, so it is killed here: a git blocked on a FIFO an
# include names outlived the interrupt. Its FIFO is in _ver_dir, which the
# trap removes.
_ver_stop() {
  if [[ -n "$_ver_cur" ]]; then kill -KILL "$_ver_cur" 2>/dev/null; fi
}

# _ver_git_runs: whether to run git at all. Not macOS's /usr/bin/git shim when
# no developer directory holds a git: run, it opens the Command Line Tools'
# installer. sandbox.sh's _git_usable decides the same way; not every caller of
# this file has sandbox.sh.
_ver_git_runs() {
  local g p
  g="$(command -v git 2>/dev/null)" || return 1
  # xcode-select -p fails outright on a Mac that never had the tools, and an
  # empty answer made the test the shim's own /usr/bin/git (review of the GIT-28
  # fix, L2). -ef, not ==: through PATH it can be /usr//bin/git, or a link to it.
  ! [[ "$g" -ef /usr/bin/git && "$(uname -s 2>/dev/null)" == Darwin ]] \
    || { p="$(xcode-select -p 2>/dev/null)" && [[ -n "$p" && -x "$p/usr/bin/git" ]]; }
}

# _ver_run <out-var> <command>...: <command>'s output, as it is, into <out-var>,
# all of it read within _ver_secs (not trimmed here: a trim of trailing newlines
# in bash is quadratic in their number, and a planted packed-refs of them held
# --version for hours, SIGINT and all; sixth review of the GIT-28 fix); returns <command>'s status, or
# 124 when it was killed at the bound. <out-var> is not to be trusted when it
# fails. <command> runs as a background job writing into a FIFO of this call's
# own, so the kill reaches the command itself, not a shell above it, and its
# status comes from a wait on a job. Not from a wait on a process substitution:
# once one has finished, bash 5.1 to 5.3 report that wait failed now and then
# under load (7 of 48,000 in bash 5.2.21), and the version came out unknown
# (bugs review GIT-50, TST-29). The FIFO is made in _ver_dir, a directory the
# caller removes, where it set one, and otherwise in a directory made and
# removed here: one fewer program for each of _ver_git_version's calls. No
# directory, no answer.
_ver_run() {
  local -n _vr_out=$1
  local _vr_fd _vr_p _vr_f _vr_rc=0 _vr_was="${!:-}"
  shift
  if [[ -n "$_ver_dir" ]]; then
    _ver_n=$(( _ver_n + 1 ))
    _vr_f="$_ver_dir/fifo.$_ver_n"
  else
    _ver_cur_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-version-run.XXXXXX" 2>/dev/null)" || { _ver_cur_dir=""; return 1; }
    _vr_f="$_ver_cur_dir/fifo"
  fi
  if ! mkfifo -m 600 "$_vr_f" 2>/dev/null; then _ver_run_done; return 1; fi
  # The job opens the FIFO to write, which waits for this end to open it to read.
  "$@" > "$_vr_f" 2>/dev/null &
  # A shell that could not start it leaves $! as it was, naming no job of this call's.
  if [[ "${!:-}" == "$_vr_was" ]]; then _ver_run_done; return 1; fi
  _vr_p=$!
  # The command running now, for the INT, TERM and HUP traps; cleared once it is done.
  _ver_cur="$_vr_p"
  # A shell with no descriptor left for {fd} says why on stderr, silenced; the
  # caller says unknown. The command it started is killed and reaped.
  if ! { exec {_vr_fd}< "$_vr_f"; } 2>/dev/null; then
    kill -KILL "$_vr_p" 2>/dev/null; wait "$_vr_p" 2>/dev/null
    _ver_run_done
    return 1
  fi
  # At most 16 MiB of it: a find over a directory the agent fills is the
  # largest output here.
  IFS= read -r -N 16777216 -t "$_ver_secs" -u "$_vr_fd" _vr_out || _vr_rc=$?
  exec {_vr_fd}<&-
  if (( _vr_rc > 128 )); then
    kill -KILL "$_vr_p" 2>/dev/null; wait "$_vr_p" 2>/dev/null
    _ver_run_done
    return 124
  fi
  _vr_rc=0
  wait "$_vr_p" 2>/dev/null || _vr_rc=$?
  _ver_run_done
  return "$_vr_rc"
}
# _ver_run_done: the end of a _ver_run, its command done: nothing left for the
# traps, and the directory it made removed.
_ver_run_done() {
  _ver_cur=""
  if [[ -n "$_ver_cur_dir" ]]; then rm -rf "$_ver_cur_dir"; _ver_cur_dir=""; fi
}

# _ver_read <out-var> <file>: a small file the agent can write, read bounded,
# trailing CR and LF dropped as git drops them from a .git file or a commondir.
_ver_read() {
  local -n _vrd_out=$1
  [[ -f "$2" ]] && _ver_run _vrd_out head -c 4096 -- "$2" || return
  _vrd_out="${_vrd_out%"${_vrd_out##*[!$'\r\n']}"}"
}

# _ver_git_version <dir>: `git describe --tags` of the checkout <dir> is in;
# its short commit when no tag describes it. Prints nothing when it cannot
# answer, and a NOTE when git did not answer in time. The checkout is found as
# git finds it, the nearest .git at or above <dir>, a .git file's gitdir: and a
# commondir followed. Of it, as data, and never through a link:
#  - its config's extensions.objectFormat, extensions.refStorage (the reftable
#    format is not read) and core.abbrev, by `git config --file`, no includes;
#  - HEAD, the branch it names, every tag, from loose files of at most 512 bytes
#    read 100 bytes each and from packed-refs (at most 2 MiB, filtered by grep),
#    and shallow, each line kept only with an object id (git refuses a HEAD that is not one by itself); a
#    link, or a loose branch that is not a regular file, gives no answer (git
#    follows links);
#  - its objects, through a directory of links to its pack/ and fan-out
#    directories only, so objects/info/alternates is never read.
# git then runs in a bare git directory made for the purpose, holding those refs
# as packed-refs and HEAD, in the repository's object format and the files ref
# format whatever the user's default, with no transport (GIT_ALLOW_PROTOCOL,
# GIT_NO_LAZY_FETCH). So nothing the checkout's config names can run, and
# nothing planted there is read whole. A subshell, so an interrupt kills what it
# runs and removes its directory.
_ver_git_version() (
  local dir="$1" d gd cdir t="" fmt=sha1 abbrev="" out="" line head="" ref="" oid name tmp="" v="" rc=0 e c lines files
  local hexre='^[0-9a-f]{40}$'
  local -A tags=()
  trap '_ver_stop; rm -rf "$tmp"; exit 130' INT
  trap '_ver_stop; rm -rf "$tmp"; exit 143' TERM
  trap '_ver_stop; rm -rf "$tmp"; exit 129' HUP
  # Made first, so that every _ver_run has its FIFO there (_ver_dir), and
  # removed on every way out of this subshell, a SIGPIPE at the answer's printf
  # included; git runs in it too, further down.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-version.XXXXXX" 2>/dev/null)" || exit
  trap 'rm -rf "$tmp"' EXIT
  _ver_dir="$tmp"
  d="$(cd "$dir" 2>/dev/null && pwd -P)" || exit
  while [[ ! -e "$d/.git" ]]; do
    [[ -n "$d" ]] || exit
    d="${d%/*}"
  done
  if [[ -d "$d/.git" ]]; then
    gd="$d/.git"
  else
    _ver_read t "$d/.git" && [[ "$t" == "gitdir: "* ]] || exit
    t="${t#gitdir: }"; [[ "$t" == /* ]] || t="$d/$t"
    gd="$t"
  fi
  cdir="$gd"
  if [[ -e "$gd/commondir" ]]; then
    _ver_read t "$gd/commondir" || exit
    [[ "$t" == /* ]] || t="$gd/$t"
    cdir="$t"
  fi
  # GIT_ALLOC_LIMIT here too: a value of a sparse 3 GiB took git config to
  # gigabytes, where a port's base/ mounted alone leaves the config writable.
  if [[ -f "$cdir/config" ]] && _ver_run out env GIT_DIR=/dev/null GIT_ALLOC_LIMIT=64m git config --file "$cdir/config" \
       --get-regexp '^(extensions\.(objectformat|refstorage)|core\.abbrev)$'; then
    mapfile -t lines <<< "${out%$'\n'}"
    # A value with a newline in it prints as lines of their own: more than the
    # three keys, or one not asked for, is not decided on.
    (( ${#lines[@]} <= 3 )) || exit
    for line in "${lines[@]}"; do
      case "${line%% *}" in
        extensions.objectformat) [[ "${line#* }" =~ ^(sha1|sha256)$ ]] || exit; fmt="${line#* }" ;;
        extensions.refstorage) [[ "${line#* }" == files ]] || exit ;;
        core.abbrev) [[ "${line#* }" =~ ^(auto|no|[0-9]{1,2})$ ]] || exit; abbrev="${line#* }" ;;
        *) exit ;;
      esac
    done
  fi
  if [[ "$fmt" == sha256 ]]; then hexre='^[0-9a-f]{64}$'; fi
  # HEAD: a commit, or a branch, loose (which git reads first) or packed.
  [[ -f "$gd/HEAD" && ! -L "$gd/HEAD" ]] && _ver_read t "$gd/HEAD" || exit
  t="${t%"${t##*[![:space:]]}"}"
  if [[ "$t" == ref:* ]]; then
    ref="${t#ref:}"; ref="${ref#"${ref%%[![:space:]]*}"}"
    # A branch, nothing that steps out of refs/heads to read some other file.
    [[ "$ref" == refs/heads/?* && "$ref" != *..* ]] || exit
    # A loose one there in any form but a regular file is not read, and not
    # passed over for a packed one git would not read either.
    if [[ -e "$cdir/$ref" || -L "$cdir/$ref" ]]; then
      [[ -f "$cdir/$ref" && ! -L "$cdir/$ref" ]] && _ver_read t "$cdir/$ref" || exit
      head="${t%"${t##*[![:space:]]}"}"
    fi
  else
    head="$t"
  fi
  if [[ -f "$cdir/packed-refs" && ! -L "$cdir/packed-refs" ]]; then
    _ver_run out head -c 2097153 -- "$cdir/packed-refs" || exit
    (( ${#out} <= 2097152 )) || exit
    # Only the lines git could read, picked out by grep, in time linear in the
    # file: a bash loop over 2 MiB of planted newlines took minutes. What this
    # writes for git must not make it refuse the file.
    mapfile -t lines < <(grep -E -m 20000 "${hexre%\$} refs/(heads|tags)/." <<< "$out")
    for line in ${lines[@]+"${lines[@]}"}; do
      oid="${line%% *}" name="${line#* }"
      if [[ "$name" == refs/tags/?* ]]; then tags[$name]="$oid"
      elif [[ -z "$head" && "$name" == "$ref" ]]; then head="$oid"; fi
    done
  fi
  # Loose tags, which git reads over packed ones: regular files only, at most
  # 512 bytes, 2000 of them, 100 bytes of each read by bash itself.
  # find -P does not follow refs/tags if it is a link.
  if [[ -d "$cdir/refs/tags" ]]; then
    _ver_run out find -P "$cdir/refs/tags" -type f -size -2 || exit
    if [[ -n "$out" ]]; then
      mapfile -t files <<< "${out%$'\n'}"
      (( ${#files[@]} <= 2000 )) || exit
      # An empty or unreadable one is passed over, not the loop's last status,
      # and one written without its newline is read as git reads it.
      _ver_run out "$BASH" -c 'for f; do if IFS= read -r -n 100 l < "$f" || [[ -n "$l" ]]; then printf "%s %s\n" "$l" "$f"; fi; done' _ "${files[@]}" || exit
      mapfile -t lines <<< "${out%$'\n'}"
      for line in ${lines[@]+"${lines[@]}"}; do
        oid="${line%% *}" name="${line#* }"; name="${name#"$cdir"/}"
        if [[ "$oid" =~ $hexre && "$name" == refs/tags/?* ]]; then tags[$name]="$oid"; fi
      done
    fi
  fi
  if _ver_run out env GIT_DEFAULT_REF_FORMAT=files GIT_TERMINAL_PROMPT=0 \
       git init -q --bare --template= --object-format="$fmt" "$tmp/g" \
     && mkdir "$tmp/objects" \
     && _ver_run out find -P "$cdir/objects" -mindepth 1 -maxdepth 1 -type d \
          \( -name pack -o -name '[0-9a-f][0-9a-f]' \); then
    # find -P lists no link, and at most 257 names match.
    mapfile -t files <<< "${out%$'\n'}"
    if _ver_run out ln -s -- "${files[@]}" "$tmp/objects/"; then
      printf '%s\n' "$head" > "$tmp/g/HEAD"
      for name in "${!tags[@]}"; do printf '%s %s\n' "${tags[$name]}" "$name"; done > "$tmp/g/packed-refs"
      # The commits a shallow clone has no parents for: git stops there, and
      # without them walked on to a tag git cannot reach (sixth review).
      # Through a link as git reads it: at most 1 MiB, object ids only.
      if [[ -f "$cdir/shallow" ]] && _ver_run out head -c 1048576 -- "$cdir/shallow"; then
        grep -E -x -m 20000 "${hexre#^}" <<< "$out" > "$tmp/g/shallow"
      fi
      if [[ -n "$abbrev" ]]; then c=(-c "core.abbrev=$abbrev"); fi
      # GIT_ALLOC_LIMIT: a forged loose object declaring 1.5 GiB took git to
      # that much memory (sixth review).
      e=(env GIT_DIR="$tmp/g" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALLOW_PROTOCOL=none GIT_NO_LAZY_FETCH=1
         GIT_ALLOC_LIMIT=64m GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat git ${c[@]+"${c[@]}"})
      # describe prints only when it succeeds.
      # Its newline goes in version_engine's $(…).
      _ver_run v "${e[@]}" describe --tags || rc=$?
      if (( rc == 124 )); then
        printf 'NOTE: git did not answer within %s s in %s, so the engine version is not known.\n' "$_ver_secs" "$dir" >&2
      elif [[ -z "$v" ]]; then
        _ver_run v "${e[@]}" rev-parse --short HEAD || v=""
      fi
    fi
  fi
  # $tmp goes with the EXIT trap, which bash runs when the printf meets a caller
  # killed alone, its pipe closed (seventh review of the GIT-28 fix; measured,
  # bash 5.1 and 5.3).
  printf '%s' "$v"
)

# version_engine [dir] — the engine release for the tree at <dir> (default: the
# directory this file lives in).
version_engine() {
  local dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}" v=""

  # A recorded version WINS over git. In a project copy it is the only truthful
  # answer; and if a copy somehow sits inside an unrelated git repo, deriving
  # from that repo would report a number describing someone else's tree.
  # Read bounded, its first line, as every small file the agent can write is:
  # `head -1` read a planted sparse file of no newline for hours, and a FIFO
  # swapped in after the -f test for ever (seventh review of the GIT-28 fix).
  if _ver_read v "$dir/engine-version"; then
    v="${v%%$'\n'*}"; v="${v//[[:space:]]/}"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi

  # GIT IS ONLY EVER ASKED ABOUT AN ENGINE TREE. `git -C` resolves the ENCLOSING
  # repository, and it does so for an ignored directory exactly as for a tracked
  # one -- so a project's .ai-containers/ that was never told its version used to
  # answer with the PROJECT's own `git describe`. A project tagged v9.1.2 reported
  # `ai-containers  v9.1.2`: a real release string, for entirely the wrong tree,
  # with nothing marking it as a guess. That is the exact thing the header above
  # says cannot happen, and docs/configuration.md promises does not ("reports
  # `unknown` ... and says so rather than guessing") -- and it was the COMMON
  # case, not a corner: every project synced before `engine-version` existed is
  # in that state until its next sync.
  #
  # project-init.sh is the discriminator because it is BASE-REPO ONLY: it is
  # deliberately absent from AI_CONTAINERS_SHARED_FILES (see shared-files.sh and
  # AGENTS.md), so no project copy has ever had one, while every engine tree does
  # -- upstream's repository root and this port's base/ alike. A predicate over
  # the directory's own contents also keeps working where "is this a git repo"
  # cannot: a release tarball has no .git at all, and a project copy is ignored
  # by, but still inside, its project's repository.
  #
  # Asked without letting git run what the checkout's config names, and bounded
  # (_ver_git_version; bugs review GIT-28).
  if [[ -f "$dir/project-init.sh" ]] && _ver_git_runs; then
    # Only its output counts: it leaves early with the status of the test
    # that stopped it.
    v="$(_ver_git_version "$dir")" || v=""
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi

  printf 'unknown'
}

# version_record <src-dir> <dest-dir> — write <src-dir>'s engine version into
# <dest-dir>/engine-version. Called by project-init.sh and sync-to-projects.sh
# so a copy carries the version of the tree it was copied FROM, at the moment it
# was copied. Never fatal: a project that cannot be told its version still works,
# it just reports `unknown`.
version_record() {
  local src="$1" dest="$2" v
  v="$(version_engine "$src")"
  if [[ "$v" == "unknown" ]]; then
    # REMOVE a stale record; do not leave it standing. After this call the copy
    # is a copy of THIS tree, so a number recorded from some earlier tree now
    # describes something the copy did not come from -- and `--version` would
    # report it with no hint that it is describing the wrong tree. The realistic
    # trigger is a release tarball or any .git-less export of the engine: a
    # project recorded once from a git checkout and re-synced from one of those
    # kept reporting the old release forever.
    #
    # Removing, NOT writing the literal `unknown`: version_engine already reports
    # `unknown` for an absent file, so absence keeps meaning exactly one thing
    # and a later sync can still tell "never recorded" from "recorded once,
    # badly". Non-fatal like the write below -- both callers run under `set -e`
    # and call this bare.
    rm -f "$dest/engine-version" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$v" > "$dest/engine-version" 2>/dev/null || return 0
}

# version_schema [dir] — the `# schema-version:` marker in <dir>'s sandbox.conf,
# or `unknown`. A FUNCTION because two callers need it: version_report below and
# ai-containers-report.sh, which reports the marker per registered project.
# SANDBOX_CONF overrides the location, as everywhere else in this engine.
version_schema() {
  local dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local conf="${SANDBOX_CONF:-$dir/sandbox.conf}" schema=""
  if [[ -f "$conf" ]]; then
    schema="$(grep -E '^# schema-version:[[:space:]]*[0-9]+' "$conf" 2>/dev/null | head -1 \
                | sed -E 's/^# schema-version:[[:space:]]*([0-9]+).*/\1/')"
  fi
  printf '%s' "${schema:-unknown}"
}

# version_report [dir] — the human-facing report, one field per line.
version_report() {
  local dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local conf="${SANDBOX_CONF:-$dir/sandbox.conf}"
  local schema nvm="" nvm_note=""

  schema="$(version_schema "$dir")"
  if [[ -f "$conf" ]]; then
    nvm="$(grep -E '^nvm-version=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  fi

  # An unset nvm-version means the Dockerfile's ARG default is what the image
  # gets. Report THAT, labelled, rather than an empty field that is accurate
  # about the file and useless about the image.
  if [[ -z "$nvm" ]]; then
    if [[ -f "$dir/Dockerfile" ]]; then
      nvm="$(grep -oE '^ARG NVM_VERSION=.*' "$dir/Dockerfile" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi
    if [[ -n "$nvm" ]]; then nvm_note="  (Dockerfile default)"; else nvm="unknown"; fi
  fi

  printf '%-16s%s\n' "ai-containers" "$(version_engine "$dir")"
  printf '%-16sschema %s\n' "sandbox.conf" "$schema"
  printf '%-16s%s%s\n' "nvm" "$nvm" "$nvm_note"
}
