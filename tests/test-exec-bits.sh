#!/usr/bin/env bash
# Guards the executable bit on scripts that are RUN AS PROGRAMS — the ones where
# a lost +x is not a cosmetic inconsistency but a hard failure.
#
# This is the fifth-plus recurrence of the same defect in this project, and the
# existing guard (tests/test-integration-fixtures.sh) covers only ONE of the
# places it happens: tests/integration/fixtures/. The other two are unguarded:
#
#   CI bare-path invocations    A workflow step that runs `./tests/run-all.sh`
#                               (no interpreter) dies with exit 126 the moment
#                               that file is 100644. That exact failure shipped
#                               in mgd-ai-containers and needed its own PR.
#   Dockerfile /usr/local/bin   entrypoint.sh execs the firewall refresher and
#                               both capture daemons DIRECTLY, and gates the
#                               reconcile scripts on `[[ -x ... ]]` before
#                               running them. A COPY into /usr/local/bin whose
#                               chmod +x was forgotten produces a container that
#                               starts fine and silently never refreshes the
#                               ipset or captures blocked traffic — a security
#                               hole with no error message anywhere.
#
# BOTH sets are DERIVED, not hardcoded. A new workflow step or a new COPY is
# covered the day it is written; a hardcoded list would be stale by the next
# commit and would give a false green exactly when it mattered.
#
# Not covered here on purpose: sourced libraries (sandbox-common.sh,
# tools-lib.sh, tests/integration/lib.sh) and files invoked as `bash <file>`
# (every tests/test-*.sh, every integration case). Their mode is irrelevant, so
# demanding +x would be inventing a rule the code does not have.
#
# Hermetic: filesystem + git metadata only, no Docker, no network.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

cd "$REPO_DIR" || { printf 'FAIL: cannot cd to %s\n' "$REPO_DIR"; exit 1; }

# Whether git is usable here at all. A repo bind-mounted into a container as a
# different UID makes `git ls-files` fail exactly like "path not tracked" —
# empty output either way — so assert_executable below must tell a git
# FAILURE apart from a real "not tracked", checked once rather than re-derived
# from an empty result per call.
GIT_USABLE=1
git rev-parse --git-dir >/dev/null 2>&1 || GIT_USABLE=0

# Asserts both modes for one repo-relative path. The working tree and the git
# index diverge silently: `git update-index --chmod=+x` flips the index without
# touching the working tree, and a later `git add` of the same path re-reads the
# working tree and quietly undoes it. Checking one of the two misses that.
assert_executable() {   # $1 = repo-relative path, $2 = why it must be executable
  local rel="$1" why="$2" mode

  if [[ ! -e "$rel" ]]; then
    fail "$rel exists ($why) — referenced but not present in the repo"
    return
  fi

  if [[ -x "$rel" ]]; then
    pass "$rel is executable on disk ($why)"
  else
    local got
    got="$(stat -c '%a' "$rel" 2>/dev/null || stat -f '%Lp' "$rel" 2>/dev/null)"
    fail "$rel is executable on disk ($why) — got mode ${got:-unknown}"
  fi

  mode="$(git ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')"
  if [[ "$mode" == "100755" ]]; then
    pass "$rel is committed as 100755"
  elif [[ -z "$mode" ]]; then
    if [[ "$GIT_USABLE" -eq 1 ]]; then
      fail "$rel is committed as 100755 — not tracked by git"
    else
      fail "$rel is committed as 100755 — git is unusable here (ownership mismatch, unreadable, or not a repository) — nothing was verified"
    fi
  else
    fail "$rel is committed as 100755 — got $mode"
  fi
}

# ── Class A: scripts a CI workflow references ──────────────────────────────────
# Two different assertions, and the distinction matters:
#
#   EVERY referenced script must EXIST where the step would look for it. A
#     `run: bash ./verify-on-host.sh` in a repo that keeps the engine in base/
#     is a job that cannot work, and it fails only when the schedule fires —
#     which for a nightly that has never fired is never. Found exactly that in
#     mgd-ai-containers.
#   Only BARE-PATH invocations must be executable. `bash ./x.sh` does not care
#     about the mode, and flagging it would be a false positive that trains
#     people to ignore this test.
#
# Paths resolve against the step's `working-directory:` when it declares one,
# repo root otherwise. A `cd` inside a `run:` block is NOT tracked — use
# `working-directory:` so the path a reader sees is the path that runs.
#
# The path class excludes "." so "${{ github.event.pull_request.base.sha }}"
# cannot yield a phantom match, and a following alphanumeric is rejected so
# ".sha" is not read as ".sh".
scan_workflow() {   # emits "<working-dir>|<./path>|<0=bare,1=interpreted>"
  awk '
    function flush(   s, tmp, m, rest, pre, interp) {
      if (block == "") return
      wd = "."
      if (match(block, /working-directory:[ \t]*[^ \t\n]+/)) {
        s = substr(block, RSTART, RLENGTH)
        sub(/working-directory:[ \t]*/, "", s)
        gsub(/["'"'"']/, "", s)
        wd = s
      }
      tmp = block
      while (match(tmp, /\.\/[A-Za-z0-9_\/-]+\.sh/)) {
        m    = substr(tmp, RSTART, RLENGTH)
        pre  = substr(tmp, 1, RSTART - 1)
        rest = substr(tmp, RSTART + RLENGTH)
        if (rest !~ /^[A-Za-z0-9_.-]/) {
          interp = (pre ~ /(bash|sh|source|\.)[ \t]+$/) ? 1 : 0
          printf "%s|%s|%d\n", wd, m, interp
        }
        tmp = rest
      }
    }
    # Comments are not invocations. A full-line comment MENTIONING a script
    # (explaining why a step is written the way it is — this repo does that a
    # lot) would otherwise be scanned as a reference, and it inherits the
    # PREVIOUS step block, so it gets checked against the wrong
    # working-directory too. Both a false positive and a misleading one.
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]/ { flush(); block = "" }
    { block = block $0 "\n" }
    END { flush() }
  ' "$1"
}

shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

if [[ "${#workflows[@]}" -eq 0 ]]; then
  fail "at least one workflow exists under .github/workflows/"
else
  pass "found ${#workflows[@]} workflow file(s)"
fi

refs=""
for wf in "${workflows[@]}"; do
  refs="${refs}$(scan_workflow "$wf")"$'\n'
done
refs="$(printf '%s' "$refs" | grep -v '^$' | sort -u || true)"

if [[ -z "$refs" ]]; then
  # A scan that finds nothing must not read as a pass. The workflows DO
  # reference scripts; finding none means the scanner broke, not that the repo
  # got safer — the same "selected 0 cases" trap the integration runner guards.
  fail "the workflow scan found at least one .sh reference (found none — scanner is broken)"
else
  n="$(printf '%s\n' "$refs" | wc -l | tr -d ' ')"
  pass "workflow scan found $n .sh reference(s)"
  while IFS='|' read -r wd ref interp; do
    [[ -z "$ref" ]] && continue
    rel="${ref#./}"
    [[ "$wd" != "." ]] && rel="${wd%/}/$rel"
    if [[ -e "$rel" ]]; then
      pass "$rel exists where its workflow step would look for it"
    else
      fail "$rel exists where its workflow step would look for it — referenced as '$ref'$([[ "$wd" != "." ]] && printf ' in %s' "$wd" || printf ' from the repo root') but not there"
      continue
    fi
    [[ "$interp" == "0" ]] && assert_executable "$rel" "invoked by bare path in a workflow"
  done <<< "$refs"
fi

# ── Class A2: the *.d/ fragment directories a workflow globs ───────────────────
# Same failure as Class A's existence check, on the other kind of path — and it
# shipped for exactly the same reason.
#
# mgd-ai-containers' nightly `allowlist-health` job globbed `allowlist-domains.d/*.txt`
# from the repo root, but that repo keeps the engine in base/. The job could
# never have matched a file. It did not fail silently — the step's own zero-scan
# guard caught it and went red, which is the guard working exactly as designed —
# but it went red at 03:17 UTC on a schedule-only workflow, twice, before anyone
# looked. Class A already checks that a referenced SCRIPT exists where its step
# would look; nothing checked the same for a referenced DIRECTORY, and the
# layout difference is handled per job, so the next job to be added inherits the
# same trap.
#
# Scope is `<name>.d/` deliberately, not "any directory-looking token". That is
# this project's fragment-directory convention — allowlist-domains.d,
# allowlist-cidrs.d, allowlist-proxy-domains.d, tools.d — so the pattern is
# specific enough to carry no false positives, and every match is a real
# repo directory a step expects to find. A general path scanner would flag
# in-container paths, URLs and `${{ }}` expressions, and a check that cries wolf
# gets ignored.
scan_workflow_dirs() {   # emits "<working-dir>|<name.d>"
  awk '
    function flush(   s, tmp, m, rest) {
      if (block == "") return
      wd = "."
      if (match(block, /working-directory:[ \t]*[^ \t\n]+/)) {
        s = substr(block, RSTART, RLENGTH)
        sub(/working-directory:[ \t]*/, "", s)
        gsub(/["'"'"']/, "", s)
        wd = s
      }
      tmp = block
      while (match(tmp, /[A-Za-z0-9_-]+\.d\//)) {
        m    = substr(tmp, RSTART, RLENGTH)
        rest = substr(tmp, RSTART + RLENGTH)
        sub(/\/$/, "", m)
        printf "%s|%s\n", wd, m
        tmp = rest
      }
    }
    # Comments are not references — same reasoning as scan_workflow above, and
    # it matters more here: the allowlist-health step explains itself at length
    # and names allowlist-proxy-domains.d in prose to say why it is deliberately
    # NOT checked. Scanning that would demand the very directory the comment
    # exists to exclude.
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]/ { flush(); block = "" }
    { block = block $0 "\n" }
    END { flush() }
  ' "$1"
}

dir_refs=""
for wf in "${workflows[@]}"; do
  dir_refs="${dir_refs}$(scan_workflow_dirs "$wf")"$'\n'
done
dir_refs="$(printf '%s' "$dir_refs" | grep -v '^$' | sort -u || true)"

if [[ -z "$dir_refs" ]]; then
  # Unlike Class A, finding none is legitimate: a repo whose workflows glob no
  # fragment directory has nothing to check. Say so rather than passing
  # silently, so "0 checked" is never mistaken for "0 problems".
  pass "no *.d/ fragment directory is referenced by any workflow (nothing to check)"
else
  n="$(printf '%s\n' "$dir_refs" | wc -l | tr -d ' ')"
  pass "workflow scan found $n *.d/ directory reference(s)"
  while IFS='|' read -r wd ref; do
    [[ -z "$ref" ]] && continue
    rel="$ref"
    [[ "$wd" != "." ]] && rel="${wd%/}/$ref"
    if [[ -d "$rel" ]]; then
      pass "$rel exists where its workflow step would look for it"
    else
      fail "$rel exists where its workflow step would look for it — globbed as '$ref'$([[ "$wd" != "." ]] && printf ' in %s' "$wd" || printf ' from the repo root') but not there"
      printf '       Declare the location with `working-directory:` on that step.\n'
      printf '       A `cd` inside the run block is deliberately not tracked.\n'
    fi
  done <<< "$dir_refs"
fi

# ── Class B: Dockerfile COPYs into /usr/local/bin (and /entrypoint.sh) ──────────
# These are executed inside the image — directly by entrypoint.sh, or gated on
# [[ -x ]] before a bash call. The repo-side mode does not carry into the image
# (COPY preserves it, but a later `RUN chmod +x` is what the Dockerfile relies
# on), so what matters here is that SOME chmod in the Dockerfile names each
# destination path.
#
# Layout-tolerant, like tests/integration/run.sh: upstream keeps the engine at
# the repo root, mgd-ai-containers keeps it in base/. One file serves both, so
# the two copies cannot drift — which is how the harness fell 117 lines behind
# once already.
dockerfile=""
for cand in Dockerfile base/Dockerfile; do
  [[ -f "$cand" ]] && { dockerfile="$cand"; break; }
done

if [[ -z "$dockerfile" ]]; then
  fail "a Dockerfile exists (looked for ./Dockerfile and ./base/Dockerfile)"
else
  pass "found the Dockerfile at $dockerfile"

  # COPY <src>.sh <dst>   →   resolve <dst> to a full in-image path.
  copied_bins="$(awk '
    $1 == "COPY" && NF >= 3 {
      src = $(NF-1); dst = $NF
      if (src !~ /\.sh$/) next
      if (dst ~ /\/$/) {                    # COPY x.sh /usr/local/bin/
        n = split(src, parts, "/")
        dst = dst parts[n]
      }
      if (dst ~ /^\/usr\/local\/bin\// || dst == "/entrypoint.sh") print dst
    }' "$dockerfile" | sort -u)"

  if [[ -z "$copied_bins" ]]; then
    fail "the Dockerfile scan found at least one .sh COPY into /usr/local/bin or /entrypoint.sh (found none — scanner is broken)"
  else
    n="$(printf '%s\n' "$copied_bins" | wc -l | tr -d ' ')"
    pass "Dockerfile scan found $n executable-destination .sh COPY target(s)"
    # Collect every path any chmod line makes executable. Line continuations
    # mean a single chmod can span many lines, so take the whole file and pull
    # out paths that appear on (or under) a chmod +x / chmod 755 statement.
    chmodded="$(awk '
      /chmod[[:space:]]+(\+x|755)/ { grab = 1 }
      grab {
        for (i = 1; i <= NF; i++) if ($i ~ /^\/[A-Za-z0-9_\/.-]+$/) print $i
        if ($0 !~ /\\[[:space:]]*$/) grab = 0
      }' "$dockerfile" | sort -u)"

    while IFS= read -r bin; do
      [[ -z "$bin" ]] && continue
      if printf '%s\n' "$chmodded" | grep -qxF "$bin"; then
        pass "$bin is made executable by a chmod in the Dockerfile"
      else
        fail "$bin is made executable by a chmod in the Dockerfile — COPYed but never chmodded"
      fi
    done <<< "$copied_bins"
  fi
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
