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
#                   exists solely to keep it current, so reporting it is
#                   reporting that job's output. An EMPTY value is not "no nvm" —
#                   it means the Dockerfile's own ARG default applies, and the
#                   report says which, because the question being asked is what
#                   the IMAGE will get, not what the file happens to contain.
#
# `git describe --tags`, not `--abbrev=0`: the suffix is the honest part. A copy
# taken five commits after v0.7.0 is not v0.7.0, and `v0.7.0-5-gefce881` says so.

# version_engine [dir] — the engine release for the tree at <dir> (default: the
# directory this file lives in).
version_engine() {
  local dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}" v=""

  # A recorded version WINS over git. In a project copy it is the only truthful
  # answer; and if a copy somehow sits inside an unrelated git repo, deriving
  # from that repo would report a number describing someone else's tree.
  if [[ -f "$dir/engine-version" ]]; then
    v="$(head -1 "$dir/engine-version" 2>/dev/null | tr -d '[:space:]')"
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
  if [[ -f "$dir/project-init.sh" ]] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    v="$(git -C "$dir" describe --tags --dirty 2>/dev/null || true)"
    [[ -z "$v" ]] && v="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
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
