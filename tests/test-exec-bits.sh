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
    fail "$rel is committed as 100755 — not tracked by git"
  else
    fail "$rel is committed as 100755 — got $mode"
  fi
}

# ── Class A: scripts a CI workflow invokes by bare path ─────────────────────────
# Matches a literal "./path/to/x.sh". The path class excludes "." so that
# "${{ github.event.pull_request.base.sha }}" cannot yield a phantom "./…sh"
# match, and \b after .sh keeps ".sha" from matching as ".sh".
#
# A match preceded by an interpreter (bash/sh/source/.) is SKIPPED: the exec bit
# genuinely does not matter there, and flagging it would be a false positive
# that trains people to ignore this test.
workflow_scripts=""
shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

if [[ "${#workflows[@]}" -eq 0 ]]; then
  fail "at least one workflow exists under .github/workflows/"
else
  pass "found ${#workflows[@]} workflow file(s)"
fi

for wf in "${workflows[@]}"; do
  while IFS= read -r line; do
    for m in $(printf '%s\n' "$line" | grep -oE '\./[A-Za-z0-9_/-]+\.sh\b' || true); do
      # Interpreter-prefixed? Then the mode is irrelevant — skip it.
      case "$line" in
        *"bash $m"*|*"sh $m"*|*"source $m"*|*". $m"*) continue ;;
      esac
      workflow_scripts="${workflow_scripts}${m#./}"$'\n'
    done
  done < "$wf"
done

workflow_scripts="$(printf '%s' "$workflow_scripts" | grep -v '^$' | sort -u || true)"

if [[ -z "$workflow_scripts" ]]; then
  # A scan that finds nothing must not read as a pass. The workflows DO invoke
  # scripts by bare path; finding none means the scanner broke, not that the
  # repo got safer — the same "selected 0 cases" trap the integration runner
  # already guards against.
  fail "the workflow scan found at least one bare-path .sh invocation (found none — scanner is broken)"
else
  n="$(printf '%s\n' "$workflow_scripts" | wc -l | tr -d ' ')"
  pass "workflow scan found $n bare-path .sh invocation(s)"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    assert_executable "$rel" "invoked by bare path in a workflow"
  done <<< "$workflow_scripts"
fi

# ── Class B: Dockerfile COPYs into /usr/local/bin (and /entrypoint.sh) ──────────
# These are executed inside the image — directly by entrypoint.sh, or gated on
# [[ -x ]] before a bash call. The repo-side mode does not carry into the image
# (COPY preserves it, but a later `RUN chmod +x` is what the Dockerfile relies
# on), so what matters here is that SOME chmod in the Dockerfile names each
# destination path.
if [[ ! -f Dockerfile ]]; then
  fail "Dockerfile exists"
else
  pass "Dockerfile exists"

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
    }' Dockerfile | sort -u)"

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
      }' Dockerfile | sort -u)"

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
