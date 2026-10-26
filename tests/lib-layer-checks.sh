#!/usr/bin/env bash
# tests/lib-layer-checks.sh — parser for tests/layer-checks.conf and for the
# narrow slice of workflow YAML the containment guard needs. SOURCED, never
# executed directly, and deliberately NOT named test-*.sh so tests/run-all.sh's
# glob skips it (same reason as tests/lib-verify-repo.sh).
#
# CONTRACT: the sourcing file sets LAYER_CHECKS_CONF to the registry path before
# sourcing. Provides lc_rows(), wf_jobs(), wf_steps(), wf_has_step(),
# wf_job_key(), wf_triggers_on(), wf_if_true(), wf_it_selections().
#
# lc_rows is generic over the registry's row TYPE — it already serves `check`
# and `setup` rows; the `workflow` row type (added to close the containment
# guard's fourth finding — a brand-new pull_request-triggered workflow was
# invisible to a hardcoded two-file classification list) needs no change here,
# only new rows in tests/layer-checks.conf.
#
# EVERY function here fails loudly and non-zero on an empty result, AND on an
# input file that is not there — except where empty is an ordinary answer: the
# predicates (wf_has_step, wf_triggers_on, wf_if_true) and wf_it_selections,
# for which a workflow that runs no integration case is normal. Their callers
# hold the vacuity check (tests/test-layer-containment.sh fails a layer that
# derived to nothing). That is the whole point: a parser returning
# nothing quietly would make its consumer iterate zero rows and report success
# having verified nothing -- the exact defect the guard this feeds was written
# to catch.
#
# Both halves are named because for a long time only the first one was. The
# missing-file guards sat outside the promise, the test followed the promise,
# and `return 1` -> `return 0` in wf_jobs, wf_steps, wf_job_key and lc_rows
# survived the whole suite (backlog F18). test-layer-checks-parser.sh now
# exercises both classes, and asserts the MESSAGE as well as the status: delete
# a missing-file guard outright and the function still fails, one branch later
# and for a different reason, so status alone cannot tell the guard is gone.
#
# The YAML handling is a narrow awk reader for the shape these workflow files
# use (2-space job ids, 4-space `steps:`, 6-space `- ` step starts, 8-space step
# keys), NOT a general YAML parser. yq is not guaranteed on a developer's
# machine and skipping the check when it is absent would mean a check that does
# not run. A reformat that breaks this reader makes the guard RED, never green:
# zero jobs and zero steps are both hard errors.

lc_rows() {  # $1=check|setup → matching rows, type field stripped
  local want="${1:?lc_rows: row type required}" out
  [[ -f "${LAYER_CHECKS_CONF:-}" ]] || {
    echo "lib-layer-checks: LAYER_CHECKS_CONF is unset or missing: ${LAYER_CHECKS_CONF:-<unset>}" >&2
    return 1
  }
  out="$(grep -v '^[[:space:]]*#' "$LAYER_CHECKS_CONF" \
         | grep "^${want}|" \
         | sed "s/^${want}|//")"
  [[ -n "$out" ]] || {
    echo "lib-layer-checks: no '$want' rows in $LAYER_CHECKS_CONF" >&2
    return 1
  }
  printf '%s\n' "$out"
}

_wf_awk() {  # $1=yaml  $2=job filter ('' = list jobs instead of steps)
  awk -v job="$2" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    function grab(s) {
      if (s ~ /^name:[[:space:]]/)      { nm = val(s) }
      else if (s ~ /^uses:[[:space:]]/) { us = val(s) }
    }
    function flush() {
      if (started) { print (nm != "" ? nm : (us != "" ? us : "(unnamed step)")) }
      started = 0; nm = ""; us = ""
    }
    BEGIN { inj = 0; injob = 0; insteps = 0; started = 0; nm = ""; us = "" }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    # Any column-0 key ends the jobs block (permissions:, on:, a trailing key).
    inj && /^[^[:space:]#]/ { flush(); inj = 0; injob = 0; insteps = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      flush()
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur)
      if (job == "") { print cur }
      injob = (cur == job); insteps = 0; next
    }
    injob && /^    steps:[[:space:]]*$/ { insteps = 1; next }
    # A 4-space key after steps: ends the step list (none today, but a job with
    # `steps:` followed by another job-level key must not swallow it).
    injob && insteps && /^    [A-Za-z]/ { flush(); insteps = 0; next }
    insteps && /^      - / {
      flush(); started = 1
      line = $0; sub(/^      - /, "", line); grab(line); next
    }
    insteps && started && /^        [A-Za-z]/ {
      line = $0; sub(/^        /, "", line); grab(line); next
    }
    END { flush() }
  ' "$1"
}

wf_jobs() {  # $1=workflow yaml → job ids, one per line
  local f="${1:?wf_jobs: workflow path required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: no jobs found in $f" >&2; return 1; }
  printf '%s\n' "$out"
}

wf_steps() {  # $1=workflow yaml  $2=job id → step identities, one per line
  local f="${1:?wf_steps: workflow path required}"
  local j="${2:?wf_steps: job id required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "$j")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: job '$j' in $f has no steps" >&2; return 1; }
  printf '%s\n' "$out"
}

# wf_has_step is the ONLY safe way to ask "does this job have this step".
#
# The obvious form — `wf_steps "$f" "$j" | grep -qxF "$step"` — is WRONG under
# `set -o pipefail`, which every consumer here uses. `grep -q` exits the instant
# it matches, and the producer left mid-write takes the broken pipe; pipefail
# then promotes the producer's status over grep's success, so the pipeline
# reports "no such step" for a step that is right there. Measured: with a
# producer larger than the pipe buffer the false negative is 200/200, and with
# a four-line producer it appeared under CPU contention only — which is worse,
# because it makes a REGISTRY-ROW-IS-STALE failure that nothing is stale about,
# arriving only on a loaded machine. It reached this repo through the falsify
# tier, which runs several copies of test-layer-containment.sh at once.
#
# The mirror case is worse and is why the rule is unconditional: a guard written
# `if producer | grep -q BAD; then fail; else pass; fi` reports NO DEFECT at the
# moment BAD appears, because that is the moment grep exits early. Measured
# 50/50. tests/test-grep-q-pipelines.sh enforces the rule repo-wide.
#
# Capturing first cannot race: the producer's status is read directly, and the
# match runs against a value that is already complete.
wf_has_step() {  # $1=yaml  $2=job id  $3=step name → 0 when the job has it
  local f="${1:?wf_has_step: workflow path required}"
  local j="${2:?wf_has_step: job id required}"
  local step="${3:?wf_has_step: step name required}" out
  out="$(wf_steps "$f" "$j" 2>/dev/null)" || return 1
  grep -qxF -- "$step" <<<"$out"
}

# wf_job_key reads a JOB-LEVEL key (4-space indented, directly under a named
# job — e.g. a reusable-workflow caller's `uses:`, or its `if:` gate), as
# opposed to wf_steps' 8-space step keys. Added for the containment guard's
# nightly/PR assertions, which used to `grep -qF` a pattern against the WHOLE
# workflow file — passing on a job commented out in place (the comment still
# contains the string being grepped for). This reuses the same block-aware
# state machine as wf_jobs/wf_steps: a commented-out job's header line
# ("  # hermetic:") does not match the job-start pattern, so it never becomes
# `injob`, and a key read against it fails loudly at its actual cause instead
# of matching stale text.
wf_job_key() {  # $1=yaml  $2=job id  $3=job-level key (e.g. uses, if) → value
  local f="${1:?wf_job_key: workflow path required}"
  local j="${2:?wf_job_key: job id required}"
  local k="${3:?wf_job_key: key required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(awk -v job="$j" -v key="$k" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    BEGIN { inj = 0; injob = 0 }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    # Any column-0 key ends the jobs block, same as _wf_awk.
    inj && /^[^[:space:]#]/ { inj = 0; injob = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur)
      injob = (cur == job)
      next
    }
    injob && /^    [A-Za-z0-9_-]+:/ {
      line = $0; sub(/^    /, "", line)
      k2 = line; sub(/:.*/, "", k2)
      if (k2 == key) { print val(line); exit }
      next
    }
    ' "$f")"
  [[ -n "$out" ]] || {
    echo "lib-layer-checks: job '$j' has no '$k:' key in $f (job absent, key absent, or job commented out)" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# wf_triggers_on is a PREDICATE, unlike every function above it — "the trigger
# is absent" is an ordinary, expected outcome (most workflows do not trigger on
# pull_request), not an empty-result error, so it does not follow this file's
# fail-loudly-on-empty convention. A genuine "no" is a quiet rc=1. A missing
# file/arg, and an `on:` it cannot read, are rc=2 with a message: "cannot tell"
# must never be mistaken for "no".
#
# Added for tests/test-layer-containment.sh to VERIFY a `workflow` row's
# `coverage=exempt` claim against the file's own `on:` block, rather than
# trusting its <why> prose — the same effect-over-text-presence standard this
# project applies everywhere else (see AGENTS.md: "the suite asserts effect,
# not configuration"). It reads every spelling GitHub accepts for the trigger
# list: a scalar (`on: pull_request`), a one-line flow list
# (`on: [push, pull_request]`), a `- name` sequence and a block map, each at any
# indentation, with keys and entries quoted or not. It used to read only the
# block map at exactly two spaces, so `on: [push, pull_request]` passed an
# exempt row as "verified NOT pull_request-triggered" (TST-6). What it still
# cannot read — a flow list spanning lines, a flow map, an `on:` with nothing
# under it, a file with no `on:` at all — is rc=2. Only the first level of the
# block counts: `pull_request:` nested under another trigger is not a trigger,
# and neither is the word inside a step's `run:` script, since the scan stops
# at the next column-0 key.
wf_triggers_on() {  # $1=yaml  $2=trigger name (e.g. pull_request) → rc 0 present, 1 absent, 2 cannot tell
  local f="${1:?wf_triggers_on: workflow path required}"
  local trig="${2:?wf_triggers_on: trigger name required}" rc
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 2; }
  awk -v trig="$trig" -v sq="'" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unq(s) {
      s = trim(s)
      if (length(s) >= 2 && ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
                             (substr(s, 1, 1) == sq && substr(s, length(s), 1) == sq)))
        s = substr(s, 2, length(s) - 2)
      return s
    }
    function nocomment(s) { sub(/^#.*$/, "", s); sub(/[[:space:]]+#.*$/, "", s); return s }
    # A whole value on one line: a flow list, a flow map (unreadable), or a
    # scalar. Used for the rest of the `on:` line and for a value that starts
    # on the line after it.
    function oneline(rest,   n, a, i) {
      if (substr(rest, 1, 1) == "[") {
        if (substr(rest, length(rest), 1) != "]") { bad = 1; return }
        n = split(substr(rest, 2, length(rest) - 2), a, ",")
        for (i = 1; i <= n; i++) if (unq(a[i]) == trig) found = 1
        return
      }
      if (substr(rest, 1, 1) == "{") { bad = 1; return }
      if (unq(rest) == trig) found = 1
    }
    BEGIN { state = 0; seen = 0; first = 0; found = 0; bad = 0 }
    state == 0 && ($0 ~ /^("on"|on):/ || index($0, sq "on" sq ":") == 1) {
      seen = 1
      rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(nocomment(rest))
      if (rest == "") { state = 1; next }
      oneline(rest)
      exit
    }
    state == 1 {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) next
      # A column-0 key ends the block. A column-0 "- " does not: a sequence may
      # sit at its parent key indentation.
      if ($0 ~ /^[^[:space:]-]/) exit
      line = $0
      match(line, /^[[:space:]]*/); ind = RLENGTH
      body = nocomment(substr(line, ind + 1))
      if (!first) {
        first = 1; base = ind
        isseq = (body ~ /^-([[:space:]]|$)/)
        # A flow collection, or a plain scalar (no colon), on the next line.
        if (!isseq && (substr(body, 1, 1) == "[" || substr(body, 1, 1) == "{" || body !~ /:([[:space:]]|$)/)) { oneline(trim(body)); exit }
      }
      if (ind < base) exit
      if (ind > base) next
      if (isseq) {
        if (body !~ /^-([[:space:]]|$)/) { bad = 1; exit }
        v = body; sub(/^-[[:space:]]*/, "", v)
        if (unq(v) == trig) found = 1
      } else {
        if (body ~ /^-([[:space:]]|$)/) { bad = 1; exit }
        k = body; sub(/[[:space:]]*:([[:space:]].*)?$/, "", k)
        if (unq(k) == trig) found = 1
      }
      next
    }
    END {
      if (bad || !seen || (state == 1 && !first)) exit 2
      exit !found
    }
  ' "$f"
  rc=$?
  (( rc == 2 )) && echo "lib-layer-checks: cannot read the on: block of $f (no on: key, nothing under it, a flow map, or a flow list spanning lines)" >&2
  return "$rc"
}

# wf_if_true evaluates a job- or step-level `if:` for one event, on a run where
# nothing has failed. A PREDICATE with a third answer, like wf_triggers_on: rc 0
# runs, rc 1 does not, rc 2 "cannot evaluate". It knows only the shapes these
# workflows use — none, always()/success()/failure()/cancelled(),
# github.event_name ==/!= '<event>', and inputs.<name> ==/!= '<value>' — and
# answers 2 for anything else, compound expressions included, rather than
# guessing. The inputs forms are decidable only because every input is empty
# outside workflow_dispatch, so under that event they are rc 2 too.
wf_if_true() {  # $1=expression ('' = no if:)  $2=event → rc 0 runs, 1 does not, 2 cannot evaluate
  local e="$1" ev="${2:?wf_if_true: event required}" op val
  local re_ev="^github\.event_name[[:space:]]*(==|!=)[[:space:]]*'([A-Za-z_]+)'\$"
  local re_in="^inputs\.[A-Za-z0-9_-]+[[:space:]]*(==|!=)[[:space:]]*'([^']+)'\$"
  e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
  [[ "$e" == \"*\" ]] && { e="${e#\"}"; e="${e%\"}"; }
  if [[ "$e" == '${{'*'}}' ]]; then
    e="${e#'${{'}"; e="${e%'}}'}"
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
  fi
  case "$e" in
    '')                    return 0 ;;
    'always()'|'success()') return 0 ;;
    'failure()'|'cancelled()') return 1 ;;
  esac
  if [[ "$e" =~ $re_ev ]]; then
    op="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$op" == "==" ]]; then [[ "$ev" == "$val" ]] && return 0; return 1; fi
    [[ "$ev" != "$val" ]] && return 0; return 1
  fi
  if [[ "$e" =~ $re_in && "$ev" != workflow_dispatch ]]; then
    [[ "${BASH_REMATCH[1]}" == "!=" ]] && return 0; return 1
  fi
  return 2
}

# _wf_it_awk walks every step of every job and prints one record per
# `tests/integration/run.sh` invocation in a step's `run:`, fields separated by
# the ASCII unit separator (\037) — not a tab, which `read` treats as
# whitespace and so collapses the empty field a step without an if: leaves:
#   <job> US <step identity> US <step if:> US <guarded: 1|0> US <arguments>
# The run: value is decoded first — a literal block (|) line by line, a folded
# block (>) or a plain value folded as YAML folds them, lines joined by a space
# but a blank line kept as a newline — and comment lines are dropped, so an
# invocation commented out in place is not one. Within the
# arguments, the one ${{ }} idiom these workflows use to append a dispatch
# input, `${{ inputs.X && format('…', inputs.X) || '' }}`, is rendered as the
# empty string it is when nothing was dispatched; any other ${{ }} is left for
# the caller to refuse. The arguments end at a trailing comment or at the
# first shell operator — `run.sh … 2>&1 | tee log` passes run.sh nothing after
# its last argument, and a digit run glued to a redirection is its fd. Same
# indentation contract as _wf_awk.
_wf_it_awk() {  # $1=yaml
  awk -v sq="'" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    function key(s) {
      if (s ~ /^name:[[:space:]]/)      { nm = val(s) }
      else if (s ~ /^uses:[[:space:]]/) { us = val(s) }
      else if (s ~ /^if:[[:space:]]/)   { cond = val(s) }
      else if (s ~ /^run:/) {
        v = s; sub(/^run:[[:space:]]*/, "", v)
        if (v ~ /^[|>]/) { inrun = 1; fold = (v ~ /^>/); nrun = 0 }
        else { inrun = 0; nrun = 1; runl[1] = v; plain = 1 }
      }
    }
    # scan() reads one shell line. guarded: whether the shell may skip the
    # invocation — something other than `bash`, `env` or assignments before it
    # on its line, or an earlier line of the same value that may change what
    # runs next: a compound command (if, case, a loop), `&&` or `||`, an `exit`,
    # `return` or `exec`, a function definition, a heredoc (`<<`: what follows
    # is text), or a line ending in `|`, `\` or `{`.
    # ctl() records the second after each line is scanned. It is deliberately
    # coarse: a closed `if … fi`, `timeout 600 run.sh`, or a keyword inside an
    # echo also count, and are refused loudly rather than read.
    function ctl(line) {
      if (line ~ /^[[:space:]]*#/) return
      if (line ~ /(^|[[:space:];&|(])(if|then|else|elif|case|for|while|until|do|select|exit|return|exec|function)([[:space:];]|$)/ ||
          line ~ /&&|[|][|]|<</ || line ~ /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[(][)]/ ||
          line ~ /([|]|\\|[{])[[:space:]]*$/) ctlseen = 1
    }
    function scan(line,   p, a, pre, g) {
      if (line ~ /^[[:space:]]*#/) return
      if (!match(line, /(^|[[:space:];&|(])(bash[[:space:]]+)?(\.\/)?tests\/integration\/run\.sh([[:space:]]|$)/)) return
      p = index(substr(line, RSTART), "tests/integration/run.sh")
      pre = substr(line, 1, RSTART + p - 2); sub(/\.\/$/, "", pre)
      g = ctlseen || pre !~ /^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|bash)[[:space:]]+)*$/
      a = substr(line, RSTART + p - 1 + length("tests/integration/run.sh"))
      gsub(idiom, "", a)
      sub(/[[:space:]]#.*$/, "", a)
      if (match(a, /(^|[[:space:]])[0-9]*[<>]|[;|&]/)) a = substr(a, 1, RSTART - 1)
      sub(/^[[:space:]]+/, "", a); sub(/[[:space:]]+$/, "", a)
      out = out jobname "\037" (nm != "" ? nm : (us != "" ? us : "(unnamed step)")) "\037" cond "\037" g "\037" a "\n"
    }
    function flush(   i, j) {
      if (started) {
        if (fold) {
          # Folded as YAML folds: lines join with a space, but a blank line is
          # a newline, and a more-indented line keeps its own line.
          j = ""
          for (i = 1; i <= nrun; i++) {
            if (runl[i] == "")               { scan(j); ctl(j); j = "" }
            else if (runl[i] ~ /^[[:space:]]/) { scan(j); ctl(j); scan(runl[i]); ctl(runl[i]); j = "" }
            else                             { j = (j == "" ? runl[i] : j " " runl[i]) }
          }
          scan(j)
        } else {
          for (i = 1; i <= nrun; i++) { scan(runl[i]); ctl(runl[i]) }
        }
        printf "%s", out
      }
      started = 0; nm = ""; us = ""; cond = ""; inrun = 0; fold = 0; nrun = 0; plain = 0; out = ""; ctlseen = 0
    }
    BEGIN {
      idiom = "\\$\\{\\{[[:space:]]*inputs\\.[A-Za-z0-9_-]+[[:space:]]*&&[[:space:]]*format\\(" sq "[^" sq "]*" sq ",[[:space:]]*inputs\\.[A-Za-z0-9_-]+\\)[[:space:]]*\\|\\|[[:space:]]*" sq sq "[[:space:]]*\\}\\}"
      inj = 0; injob = 0; insteps = 0; started = 0
    }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    inj && /^[^[:space:]#]/ { flush(); inj = 0; injob = 0; insteps = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      flush()
      jobname = $0; sub(/^  /, "", jobname); sub(/:[[:space:]]*$/, "", jobname)
      injob = 1; insteps = 0; next
    }
    injob && /^    steps:[[:space:]]*$/ { insteps = 1; next }
    injob && insteps && /^    [A-Za-z]/ { flush(); insteps = 0; next }
    # A block scalar owns every line indented past the step keys, blank or not.
    insteps && started && inrun && (/^[[:space:]]*$/ || /^          /) {
      line = $0; sub(/^          /, "", line); runl[++nrun] = line; next
    }
    # A plain value folds: a continuation line joins with a space, a blank line
    # is a newline, so what follows it is a separate command.
    insteps && started && plain && /^[[:space:]]*$/ { runl[++nrun] = ""; next }
    insteps && started && plain && /^          [^[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      runl[nrun] = (runl[nrun] == "" ? line : runl[nrun] " " line); next
    }
    insteps && /^      - / {
      flush(); started = 1
      line = $0; sub(/^      - /, "", line); key(line); next
    }
    insteps && started && /^        [A-Za-z]/ {
      inrun = 0; plain = 0
      line = $0; sub(/^        /, "", line); key(line); next
    }
    END { flush() }
  ' "$1"
}

# _wf_job_has_key: does the named job carry this job-level key, in any form
# (a scalar, a flow list, a block list)? wf_job_key needs a value on the key's
# own line, and `needs:` is often a block list.
_wf_job_has_key() {  # $1=yaml  $2=job id  $3=key → rc 0 when present
  awk -v job="$2" -v key="$3" '
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    inj && /^[^[:space:]#]/ { inj = 0; injob = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur); injob = (cur == job); next
    }
    injob && index($0, "    " key ":") == 1 { found = 1; exit }
    END { exit !found }
  ' "$1"
}

# wf_it_selections answers "which integration cases does this workflow run for
# <event>" in the only terms run.sh can check: the arguments of each
# `tests/integration/run.sh` invocation that actually runs, one line each,
#   <job>|<step identity>|<arguments>
# tests/test-layer-containment.sh hands each line to `run.sh --dry-run` and
# takes the union as the layer (TST-2, GAP-5). Before, that test held its own
# copy of the arguments, so editing a workflow's selection — or deleting a
# whole nightly job — changed nothing it checked.
#
# A workflow the event does not trigger contributes nothing (rc 0, no output).
# A job with a job-level `uses:` is a reusable-workflow call and is not
# followed. Catalogue calls (--list, --list-caps) select nothing and are
# skipped. Everything this cannot decide is rc 1 with the job and step named,
# never a quiet omission: an on: it cannot read, an if: wf_if_true cannot
# evaluate, a job with needs:, an invocation the shell may skip (a shell `if`
# or `&&` around it — the shape integration.yml's Run step had), arguments
# still holding ${{ }} after rendering, or holding any shell expansion or
# quoting ($, `, quotes, backslash) — `run.sh $args` is what a dispatch-only
# step does, which is why such steps must say so in an if: this can evaluate.
# Over-counting is the failure that matters: it credits a layer with cases it
# never runs, while under-counting fails the "every case runs nightly" check
# loudly. workflow_dispatch itself is refused: its inputs are not empty, so
# nothing here renders it truthfully.
# Every selection it COULD decide is printed even when it returns 1, so a
# caller can fail for the one it could not and still use the rest.
wf_it_selections() {  # $1=yaml  $2=event → <job>|<step>|<args> per selection; rc 1 when it cannot decide one
  local f="${1:?wf_it_selections: workflow path required}"
  local ev="${2:?wf_it_selections: event required}"
  local trc jrc src job step cond args jif bad=0
  local -A jif_rc=()
  case "$ev" in
    workflow_dispatch|workflow_call)
      echo "lib-layer-checks: wf_it_selections cannot render $ev: its inputs are not empty" >&2
      return 1 ;;
  esac
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  wf_triggers_on "$f" "$ev"; trc=$?
  (( trc == 1 )) && return 0
  (( trc == 0 )) || return 1
  while IFS=$'\037' read -r job step cond guarded args; do
    if [[ -z "${jif_rc[$job]:-}" ]]; then
      jif="$(wf_job_key "$f" "$job" if 2>/dev/null)" || jif=""
      wf_if_true "$jif" "$ev"; jif_rc[$job]=$?
      [[ "${jif_rc[$job]}" == 2 ]] && { echo "lib-layer-checks: cannot evaluate job '$job' if: $jif ($f)" >&2; bad=1; }
      # needs: makes the job wait on others and skip when they are skipped;
      # nothing here follows that, so a selection behind it is not counted.
      if [[ "${jif_rc[$job]}" == 0 ]] && _wf_job_has_key "$f" "$job" needs; then
        echo "lib-layer-checks: job '$job' has needs:, which this reader does not evaluate ($f)" >&2
        jif_rc[$job]=2; bad=1
      fi
    fi
    [[ "${jif_rc[$job]}" == 0 ]] || continue
    wf_if_true "$cond" "$ev"; src=$?
    (( src == 1 )) && continue
    if (( src == 2 )); then
      echo "lib-layer-checks: cannot evaluate step if: $cond — $job/$step ($f)" >&2; bad=1; continue
    fi
    if [[ "$guarded" == 1 ]]; then
      echo "lib-layer-checks: the run.sh invocation in $job/$step runs under a shell condition this reader cannot evaluate ($f)" >&2
      bad=1; continue
    fi
    if [[ "$args" == *'${{'* || "$args" == *[\$\`\"\'\\]* ]]; then
      echo "lib-layer-checks: cannot render the run.sh arguments of $job/$step ($f): $args" >&2; bad=1; continue
    fi
    read -ra jrc <<<"$args"
    case "${jrc[*]}" in --list|--list-caps) continue ;; esac
    printf '%s|%s|%s\n' "$job" "$step" "${jrc[*]}"
  done < <(_wf_it_awk "$f")
  (( bad == 0 ))
}
