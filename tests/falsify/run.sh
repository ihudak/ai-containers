#!/usr/bin/env bash
# tests/falsify/run.sh — the mutation tier's runner: damage ONE line of a target
# file, run the hermetic test that covers it, and record whether anything
# noticed. A mutant nothing noticed — a SURVIVOR — is evidence that an assertion
# is missing or cannot fail.
#
#   bash tests/falsify/run.sh [--target <file>] [--jobs N] [--timeout S]
#                            [--operators <list>]
#
# ── THE OUTPUT FORMAT (the survivor ledger's input; parse THIS, not stderr) ────
# Every machine-readable record goes to STDOUT, pipe-delimited, one per line.
# Progress, warnings and errors go to STDERR and are never part of the contract.
#
#   RUN|repo=<path>|conf=<path>|jobs=<n>|timeout=<s>|operators=<list>|targets=<n>|mutants=<n>
#   BASELINE|<target>|<oracle>|PASS|<ms>
#   MUTANT|<verdict>|<identity>|<oracle>|<seq>|<lineno>|<signal>|<ms>|<mutated-line>
#   NOTE|<what>|<identity>|<detail>
#   TARGET|<target>|<oracle>|<total>|<killed>|<survived>|<unproven>|<timeouts>|<ms>
#   TOTAL|<targets>|<total>|<killed>|<survived>|<unproven>|<timeouts>|<unresolved-pct>|<ms>
#
#   identity   <file>:<operator>:<sha1-of-trimmed-original-line> — the ledger
#              identity, NEVER file:line, because a line number changes on every
#              edit above it while the sha1 of the line does not.
#   verdict    KILLED | SURVIVED | UNPROVEN. UNPROVEN means nothing was observed
#              asserting — the oracle timed out, said it could not set ITSELF
#              up, or was killed by a SIGNAL — in every case without ever
#              printing a FAIL: line. It is not a kill and must not be read as
#              one — see the note on falsify_verdict. It is owed a ledger entry
#              like a survivor.
#   oracle     the row's oracle field verbatim, which may name SEVERAL tests
#              separated by commas. They are one invocation, not several: a
#              target's code can be driven by more tests than the single one
#              that is dedicated to it, and naming only that one made real kills
#              read as survivors. A FAIL: from any member is this target's kill.
#   seq        1-based index of this mutant within its target's generated list.
#              Identity is NOT unique on its own: a line holding two `&&` yields
#              two logic-flip mutants that share operator AND sha1. seq (with
#              lineno) is what tells those two apart; identity is what survives
#              an unrelated edit elsewhere in the file.
#   signal     what happened: `exit`, `failline`, `timeout`, `scaffold`,
#              `signal`, joined by `+`, or `none` for a survivor. `timeout`
#              WITHOUT `failline` yields UNPROVEN, never KILLED;
#              `timeout+failline` is a genuine kill that merely ran long.
#              `scaffold` means the oracle said it could not set ITSELF up — it
#              outranks every other signal and always yields UNPROVEN, because a
#              test that never ran cannot have noticed anything (see
#              falsify_has_scaffold_failure). `signal` means the oracle was
#              TERMINATED rather than having exited: `wait` returned 128+N, the
#              signature the OOM killer leaves on a memory-capped host running
#              $(nproc) workers. It is never combined with `exit`, because the
#              driver did not choose that status (see falsify_died_of_signal).
#   <mutated-line> is LAST because a shell line may itself contain a `|`. A
#              parser reads the first 8 fields and takes the rest verbatim.
#
# MUTANT lines stream in COMPLETION order, so with --jobs > 1 they are not
# ordered. Each line is self-describing; sort downstream if order matters.
#
# ── ISOLATION: THE WORKING TREE IS NEVER MUTATED ──────────────────────────────
# This is the single most damaging thing this harness could get wrong, so it is
# structural rather than careful:
#
#   1. A PRISTINE CACHE is seeded once from the repo — every tracked file plus
#      .git (~20 MB here). Nothing ever writes into it after that.
#   2. Each worker slot gets its OWN tree, copied from that cache.
#   3. A mutant is written into a WORKER tree, the oracle runs there, and the
#      file is restored from the cache immediately afterwards.
#   4. After the restore the worker tree is compared against the fingerprint it
#      had when it was seeded (`git status --porcelain`). An oracle that leaves
#      the tree changed — a mutated tests/integration/mutate.sh that actually
#      applies a patch, say — would otherwise contaminate every LATER mutant in
#      that slot and report kills that measure the debris. A mismatch re-seeds
#      the slot from the cache and says so with a NOTE| line.
#
# The repo itself is only ever READ. tests/integration/mutate.sh patches the real
# tree on purpose, for hand-driven demonstrations; this runner is the opposite
# choice, and both are correct for their purpose.
#
# ── THE ORACLE IS `tests/run-all.sh <name>`, NEVER THE TEST FILE ──────────────
# The verdict is then literally the suite's own code path, so the two cannot
# drift: the driver's "exited 0 but printed FAIL:" and "exited 0 but asserted
# nothing" gates are part of the oracle, for free. It is invoked in the WORKER
# tree, so it runs that tree's copy of the suite (tests/run-all.sh is #EXCLUDED
# from mutation — a mutated measuring instrument measures nothing).
#
# Two relied-upon properties of that driver, both asserted by
# tests/test-falsify-run.sh rather than assumed here:
#   * a filter matching NOTHING exits 2. Every mutant would otherwise be
#     reported KILLED by a misspelled oracle name that ran zero tests. This
#     runner refuses to mutate a target whose oracle is not green on the
#     PRISTINE tree, and names rc=2 for what it is.
#   * a DIRTY tree does not by itself change the verdict. It cannot be allowed
#     to: a worker tree always has one modified file — the mutant. If tree
#     dirtiness alone failed an oracle (mutate.sh's `cmd_apply` does carry a
#     `git diff --quiet` gate), every kill would be spurious.
#
# KILLED = the oracle exited non-zero OF ITS OWN ACCORD, OR its output carries a
# `FAIL:` line. A TIMEOUT alone is UNPROVEN, not KILLED, and so is a SIGNAL
# DEATH — 128+N is the process being shot, not the driver reporting failures. The disjunction is not redundant. The exit code is
# exactly the signal that rots — run-all.sh's own header records a real case of
# a test printing FAIL: lines and exiting 0 anyway — and the driver's own gate
# for that is anchored at `^FAIL:`, so an INDENTED `  FAIL:` still slips past it
# and reports PASS. The oracle therefore runs with -v (the test's own output is
# streamed into what we read) and the FAIL:-line check is not anchored.
#
# ── WHICH TARGETS ─────────────────────────────────────────────────────────────
# The uncommented rows of tests/falsify/targets.conf, parsed by
# derive-targets.sh --rows (one grammar, one parser). GREPPED-ONLY rows are
# skipped by category. An active EXECUTED-PARTIAL row is REFUSED: mutating the
# whole file when only some functions are ever executed manufactures survivors
# that measure a missing harness rather than a missing assertion, and the
# generator has no per-function mutation unit yet.
#
# ── ENV ───────────────────────────────────────────────────────────────────────
#   FALSIFY_REPO       repo to mutate copies of      (default: this repo)
#   FALSIFY_CONF       targets map                   (default: ./targets.conf)
#   FALSIFY_JOBS       worker slots                  (default: 1)
#   FALSIFY_TIMEOUT    per-mutant seconds            (default: 60)
#   FALSIFY_OPERATORS  passed through to generate.sh; name `stream-flip` to
#                      reach the operator that is off by default
#   FALSIFY_KEEP=1     keep the scratch trees for inspection
#
# Exit: 0 the run completed (survivors are DATA, not failure) · 1 an operational
# failure (an oracle not green on the pristine tree, a worker that produced no
# verdict) · 2 usage, or a selection that matches nothing.
#
# SOURCEABLE: sourcing defines the functions and runs nothing, so a test can
# drive falsify_seed_tree / falsify_run_oracle / the verdict predicates directly
# instead of asserting on this file's source text.

FR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FR_TESTS_DIR="$(cd "$FR_HERE/.." && pwd)"
FR_GENERATE="$FR_HERE/generate.sh"
FR_DERIVE="$FR_HERE/derive-targets.sh"

FR_REPO="${FALSIFY_REPO:-$(cd "$FR_TESTS_DIR/.." && pwd)}"
FR_CONF="${FALSIFY_CONF:-$FR_HERE/targets.conf}"
FR_JOBS="${FALSIFY_JOBS:-1}"
FR_TIMEOUT="${FALSIFY_TIMEOUT:-60}"
FR_TARGET=""

# The suite driver, as a repo-relative path DERIVED from where this file lives,
# not hardcoded: upstream keeps tests/ at the repo root, the mgd port keeps the
# engine in base/ with tests/ one level up, and both must resolve their own
# run-all.sh.
FR_DRIVER_REL="${FR_TESTS_DIR#"$(cd "$FR_TESTS_DIR/.." && pwd)"/}/run-all.sh"

# ── micro-helpers ─────────────────────────────────────────────────────────────
# EPOCHREALTIME, not a forked `date`: this runs thousands of times per run. The
# decimal separator is locale-dependent, so both are stripped.
fr_now_us() { local t="${EPOCHREALTIME//[.,]/}"; printf '%s' "$t"; }
fr_ms_since() { local t="${EPOCHREALTIME//[.,]/}"; printf '%s' "$(( ( t - $1 ) / 1000 ))"; }
fr_warn() { printf 'falsify: %s\n' "$*" >&2; }
fr_err()  { printf 'ERROR: %s\n' "$*" >&2; }

# ── the two verdict predicates ────────────────────────────────────────────────
# Deliberately one tiny function each, and each one line of logic:
# tests/test-falsify-run.sh BREAKS them one at a time (rewriting the body to
# `return 1`) and requires a known-killable mutant to flip to SURVIVED, which is
# only a proof if each signal can be disabled on its own.
falsify_exit_kills() {   # <oracle exit status> → 0 when that status is a kill
  [[ "$1" -ne 0 ]] && ! falsify_died_of_signal "$1"
}

# THE ORACLE DID NOT EXIT — IT WAS TERMINATED BY A SIGNAL, and `wait` reports
# that as 128+N. That is not the driver counting failures; it is the process
# being shot, and the two were indistinguishable to falsify_exit_kills above.
#
# The trigger is not hypothetical. The tier runs `--jobs $(nproc)` workers, each
# running a WHOLE `run-all.sh`, and on a memory-capped host the kernel picks one
# and SIGKILLs it: this container's own cgroup reports `oom_kill 7` against an
# 8 GiB `memory.max`. `wait` then returns 137, no FAIL: line was ever printed,
# no watchdog flag was set — and the mutant was recorded KILLED, signal `exit`.
# A mutant nothing asserted about, counted as caught. That is the same inversion
# backlog F12 found in the timeout path and F31 found in the scaffold path,
# arriving through a third channel, and it is the one direction this tier must
# never fail in: it removes a survivor the ledger was owed, so the coverage
# claim grows while the coverage does not.
#
# The boundary is sound rather than conventional: tests/run-all.sh exits 0, 1 or
# 2 and nothing else — never a failure COUNT — so no honest driver status can
# reach 128. tests/test-falsify-run.sh pins that premise by running the real
# driver all three ways, rather than trusting this sentence.
falsify_died_of_signal() {   # <oracle exit status> → 0 when a signal ended it
  [[ "$1" -ge 128 ]]
}

falsify_has_fail_line() {   # <oracle output file> → 0 when it carries a FAIL: line
  grep -qE '(^|[[:space:]])FAIL:' "$1"
}

# THE ORACLE'S OWN SCAFFOLDING BROKE, which is not the same event as an
# assertion failing and must never be scored as one.
#
# A test builds itself a workspace before it can assert anything — `mktemp -d`,
# the dirs and fixtures under it, its fake binaries. If that fails, everything
# afterwards measures the wreckage: reads come back empty, assertions compare
# defaults to expectations, and the test prints a wall of FAIL: lines that are
# all true and all about the environment. To this tier that is indistinguishable
# from "the mutation was noticed" — and worse, a collapsed workspace can make an
# otherwise UNREACHABLE guard reachable, so the mutation really is detected, in a
# state no honest run is ever in. Measured: backlog F31, where a failed
# `mktemp -d` inside test-tools-d.sh scored tools-lib.sh's TOOLS_D_DIR guard
# KILLED on macOS and turned a real GAP invisible.
#
# The channel is a MARKER LINE, not an exit status, because the oracle is
# `tests/run-all.sh <name>` and that driver reports its own aggregate status —
# a reserved exit code from one test would never reach this function.
falsify_has_scaffold_failure() {   # <oracle output file> → 0 when the oracle could not set itself up
  grep -qE '(^|[[:space:]])SCAFFOLD-FAILED:' "$1"
}

# ── seeding a tree ────────────────────────────────────────────────────────────
_fr_flush_batch() {   # <dest-dir> <src-file>...
  local dir="$1"; shift
  (( $# > 0 )) || return 0
  mkdir -p "$dir" || return 1
  # -P, not a bare -p: three tracked files are symlinks (CLAUDE.md → AGENTS.md
  # and friends). Dereferencing them would make the copy differ from the origin
  # in a way `git status` reports as a typechange in every worker tree.
  cp -Pp "$@" "$dir/" || return 1
}

falsify_seed_tree() {   # <repo> <dest> — tracked files + .git, nothing else
  local repo="$1" dest="$2"
  local -a files=() batch=()
  local f d prev=""
  if [[ ! -d "$repo/.git" ]]; then
    fr_err "$repo has no .git directory — the oracles need a real git work tree"
    return 1
  fi
  mkdir -p "$dest" || return 1
  mapfile -d '' -t files < <(cd "$repo" && git ls-files -z 2>/dev/null)
  if (( ${#files[@]} == 0 )); then
    fr_err "$repo has no tracked files — nothing to seed"
    return 1
  fi
  # `git ls-files` output is sorted, so same-directory entries are contiguous:
  # one mkdir and one cp per DIRECTORY instead of two forks per file.
  for f in "${files[@]}"; do
    d="${f%/*}"; [[ "$d" == "$f" ]] && d="."
    if [[ "$d" != "$prev" ]]; then
      if (( ${#batch[@]} > 0 )); then
        _fr_flush_batch "$dest/$prev" "${batch[@]}" || return 1
      fi
      batch=(); prev="$d"
    fi
    batch+=("$repo/$f")
  done
  if (( ${#batch[@]} > 0 )); then
    _fr_flush_batch "$dest/$prev" "${batch[@]}" || return 1
  fi
  cp -a "$repo/.git" "$dest/.git" 2>/dev/null || cp -R "$repo/.git" "$dest/.git" || return 1
}

falsify_tree_fingerprint() {   # <tree> → what `git status` says about it
  ( cd "$1" && git status --porcelain 2>&1 )
}

# ── writing one mutant ────────────────────────────────────────────────────────
falsify_write_mutant() {   # <pristine-file> <dest-file> <lineno> <text>
  local src="$1" dest="$2" lineno="$3" text="$4" idx
  local -a lines=()
  mapfile -t lines < "$src" || return 1
  idx=$(( lineno - 1 ))
  if (( idx < 0 || idx >= ${#lines[@]} )); then
    fr_err "line $lineno is outside $src"
    return 1
  fi
  # A redirect into the EXISTING file, so its mode (the executable bit) survives.
  printf '%s\n' "${lines[@]:0:idx}" "$text" "${lines[@]:idx+1}" > "$dest" || return 1
}

# ── running the oracle, with a per-mutant timeout ─────────────────────────────
# Sets FALSIFY_RC, FALSIFY_TIMED_OUT, FALSIFY_MS. No `timeout(1)`: it is GNU
# coreutils, absent from a stock macOS, and this is a host-side script.
FALSIFY_RC=0
FALSIFY_TIMED_OUT=0
FALSIFY_MS=0
falsify_run_oracle() {   # <tree> <oracle-set> <outfile> <timeout-seconds>
  local tree="$1" oracle="$2" out="$3" limit="$4"
  local flag="$out.timedout" pid dog t0
  # The oracle field is a SET: `a.sh,b.sh` names ONE invocation running both,
  # because run-all.sh OR-combines its filters and reports one aggregate status
  # — so a FAIL: from any member is this target's kill signal, and the baseline
  # requires every member green. Split into an array rather than relying on word
  # splitting: an unquoted `${oracle//,/ }` at the command position would also
  # glob, and a `*` reaching run-all.sh as a filter would select the whole suite.
  local -a onames=()
  IFS=',' read -r -a onames <<<"$oracle"
  rm -f "$flag"
  t0="$(fr_now_us)"
  # Monitor mode so each background job leads its own process group and a
  # timeout can kill the oracle's WHOLE tree of children (run-all.sh forks a
  # bash per test), not just the driver.
  set -m
  ( cd "$tree" && exec bash "$FR_DRIVER_REL" -v "${onames[@]}" ) >"$out" 2>&1 &
  pid=$!
  ( sleep "$limit"
    : > "$flag"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null ) &
  dog=$!
  set +m
  wait "$pid" 2>/dev/null
  FALSIFY_RC=$?
  kill -TERM -"$dog" 2>/dev/null || kill -TERM "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  FALSIFY_MS="$(fr_ms_since "$t0")"
  FALSIFY_TIMED_OUT=0
  [[ -f "$flag" ]] && FALSIFY_TIMED_OUT=1
  rm -f "$flag"
  return 0
}

# ── the verdict ───────────────────────────────────────────────────────────────
# Sets FALSIFY_VERDICT and FALSIFY_SIGNAL from the three signals.
FALSIFY_VERDICT=""
FALSIFY_SIGNAL=""
falsify_verdict() {   # <rc> <outfile> <timed-out 0|1>
  local sig="" timed_out=0
  (( $3 == 1 )) && { sig="timeout"; timed_out=1; }
  falsify_exit_kills "$1" && sig="${sig:+$sig+}exit"
  falsify_has_fail_line "$2" && sig="${sig:+$sig+}failline"
  # Checked BEFORE the survived branch, not only before the kill branch: a
  # collapsed oracle that happens to exit 0 without printing FAIL: would
  # otherwise be recorded SURVIVED, which is the worse error of the two. A
  # survivor is a claim that the suite ran and noticed nothing; this oracle
  # never ran.
  if falsify_has_scaffold_failure "$2"; then
    FALSIFY_VERDICT="UNPROVEN"; FALSIFY_SIGNAL="${sig:+$sig+}scaffold"
    return 0
  fi
  # Same reasoning, third channel: an oracle killed by a signal observed
  # nothing either. Ordered AFTER scaffold (a collapsed workspace is the more
  # specific diagnosis) and BEFORE the survived branch, because SURVIVED is a
  # claim that the suite ran and noticed nothing — this one never finished
  # running. A FAIL: line printed before the signal still wins: the assertion
  # WAS observed failing, and the process dying afterwards does not unsee it.
  if falsify_died_of_signal "$1" && (( timed_out == 0 )) && ! falsify_has_fail_line "$2"; then
    FALSIFY_VERDICT="UNPROVEN"; FALSIFY_SIGNAL="${sig:+$sig+}signal"
    return 0
  fi
  if [[ -z "$sig" ]]; then
    FALSIFY_VERDICT="SURVIVED"; FALSIFY_SIGNAL="none"
    return 0
  fi
  # A TIMEOUT IS NOT A KILL, and folding it into one inverted this whole tool.
  #
  # A kill means an assertion was observed failing. A timeout means the oracle
  # never finished, so nothing was observed at all — and the two were reported
  # identically. That is not a cosmetic mislabel: a SLOW oracle then silently
  # reclassifies a real SURVIVOR as killed, and a survivor is the only output
  # this tier exists to produce. It hides exactly what it was built to find.
  #
  # Demonstrated on a real host (2026-08-16), not theorised: the fixture mutant
  # in a function NOTHING CALLS — which cannot hang — timed out under load and
  # was reported KILLED. Backlog F12 predicted the shape from the tools-lib.sh
  # run; that host run produced it.
  #
  # UNPROVEN is therefore its own verdict. A timeout that ALSO produced a
  # `FAIL:` line is still a kill: the assertion was observed failing before the
  # clock ran out, and the run was merely slow. Everything else that timed out
  # is unproven and owed a ledger entry exactly like a survivor.
  if (( timed_out )) && ! falsify_has_fail_line "$2"; then
    FALSIFY_VERDICT="UNPROVEN"; FALSIFY_SIGNAL="$sig"
  else
    FALSIFY_VERDICT="KILLED"; FALSIFY_SIGNAL="$sig"
  fi
}

# ── scratch layout ────────────────────────────────────────────────────────────
FR_SCRATCH=""
FR_CACHE=""
FR_WORK=""
FR_OUT=""

fr_cleanup() {
  local p
  for p in "${!FR_PID_SLOT[@]}"; do kill -TERM "$p" 2>/dev/null; done
  if [[ -n "$FR_SCRATCH" && -d "$FR_SCRATCH" ]]; then
    if [[ -n "${FALSIFY_KEEP:-}" ]]; then
      fr_warn "kept scratch trees: $FR_SCRATCH"
    else
      rm -rf "$FR_SCRATCH"
    fi
  fi
}

# Where a worker slot's tree lives. A FUNCTION, and a one-liner, because
# tests/test-falsify-run.sh demonstrates the isolation guard failing by
# rewriting exactly this line to hand back the origin repo instead — the break
# has to reach the tree that gets written to, or it proves nothing.
fr_slot_tree() { printf '%s/w%s' "$FR_WORK" "$1"; }

fr_seed_slot() {   # <slot> — a fresh tree from the cache, plus its fingerprint
  local slot="$1" tree
  tree="$(fr_slot_tree "$slot")"
  rm -rf "$tree"
  cp -a "$FR_CACHE" "$tree" 2>/dev/null || cp -R "$FR_CACHE" "$tree" || return 1
  falsify_tree_fingerprint "$tree" > "$FR_OUT/w$slot.porcelain"
}

# ── one mutant, start to finish (runs in a forked child) ───────────────────────
fr_run_mutant() {   # <slot> <target> <oracle> <seq> <lineno> <op> <sha> <text> <resultfile>
  local slot="$1" target="$2" oracle="$3" seq="$4" lineno="$5" op="$6" sha="$7" text="$8" res="$9"
  local tree out ident
  tree="$(fr_slot_tree "$slot")"
  out="$FR_OUT/w$slot.log"
  ident="$target:$op:$sha"

  if ! falsify_write_mutant "$FR_CACHE/$target" "$tree/$target" "$lineno" "$text"; then
    printf 'NOTE|write-failed|%s|could not apply the mutant to %s\n' "$ident" "$tree/$target" > "$res"
    return 0
  fi

  falsify_run_oracle "$tree" "$oracle" "$out" "$FR_TIMEOUT"
  falsify_verdict "$FALSIFY_RC" "$out" "$FALSIFY_TIMED_OUT"

  printf 'MUTANT|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$FALSIFY_VERDICT" "$ident" "$oracle" "$seq" "$lineno" \
    "$FALSIFY_SIGNAL" "$FALSIFY_MS" "$text" > "$res"

  # Restore FIRST, then ask whether anything else in the tree moved. An oracle
  # that left debris behind would make every later mutant in this slot a lie.
  cp -Pp "$FR_CACHE/$target" "$tree/$target"
  if [[ "$(falsify_tree_fingerprint "$tree")" != "$(cat "$FR_OUT/w$slot.porcelain")" ]]; then
    printf 'NOTE|reseed|%s|the oracle left the worker tree changed; slot %s re-seeded\n' \
      "$ident" "$slot" >> "$res"
    fr_seed_slot "$slot"
  fi
  return 0
}

# ── the worker pool ───────────────────────────────────────────────────────────
declare -A FR_PID_SLOT=()
declare -A FR_PID_RESULT=()
FR_FREE_SLOTS=()
FR_KILLED=0
FR_SURVIVED=0
FR_UNPROVEN=0
FR_TIMEOUTS=0
FR_BROKEN=0
FR_T_KILLED=0
FR_T_SURVIVED=0
FR_T_UNPROVEN=0
FR_T_TIMEOUTS=0

fr_harvest() {   # <pid> — print that mutant's records and tally them
  local pid="$1"
  local slot="${FR_PID_SLOT[$pid]}" res="${FR_PID_RESULT[$pid]}"
  local line f2 f3 f7
  unset "FR_PID_SLOT[$pid]" "FR_PID_RESULT[$pid]"
  FR_FREE_SLOTS+=("$slot")
  if [[ ! -s "$res" ]]; then
    fr_err "a mutant worker produced no verdict at all (slot $slot) — not counted as a kill"
    FR_BROKEN=$(( FR_BROKEN + 1 ))
    rm -f "$res"
    return 0
  fi
  while IFS= read -r line; do
    printf '%s\n' "$line"
    IFS='|' read -r _ f2 f3 _ _ _ f7 _ <<< "$line"
    case "$line" in
      'MUTANT|'*)
        case "$f2" in
          KILLED)   FR_KILLED=$(( FR_KILLED + 1 ));   FR_T_KILLED=$(( FR_T_KILLED + 1 )) ;;
          SURVIVED) FR_SURVIVED=$(( FR_SURVIVED + 1 )); FR_T_SURVIVED=$(( FR_T_SURVIVED + 1 )) ;;
          UNPROVEN) FR_UNPROVEN=$(( FR_UNPROVEN + 1 )); FR_T_UNPROVEN=$(( FR_T_UNPROVEN + 1 )) ;;
        esac
        case "$f7" in
          *timeout*)
            FR_TIMEOUTS=$(( FR_TIMEOUTS + 1 )); FR_T_TIMEOUTS=$(( FR_T_TIMEOUTS + 1 ))
            # A timeout WITH a failline is still a kill — the assertion was seen
            # failing before the clock ran out. Say which happened.
            if [[ "$f2" == "UNPROVEN" ]]; then
              fr_warn "TIMEOUT after ${FR_TIMEOUT}s (UNPROVEN — nothing was observed asserting): $f3"
            else
              fr_warn "TIMEOUT after ${FR_TIMEOUT}s (killed before the clock ran out): $f3"
            fi ;;
        esac
        # A signal death is UNPROVEN, and silently so it would look like an
        # ordinary assertion gap in the ledger. Name the likely cause where the
        # reader can act on it: --jobs workers each run a whole run-all.sh, and
        # on a memory-capped host the kernel picks one.
        case "$f7" in
          *signal*) fr_warn "ORACLE KILLED BY A SIGNAL (UNPROVEN — nothing was observed asserting; check the host's memory cap against --jobs $FR_JOBS): $f3" ;;
        esac ;;
      'NOTE|write-failed|'*) FR_BROKEN=$(( FR_BROKEN + 1 )) ;;
    esac
  done < "$res"
  rm -f "$res"
}

fr_wait_for_slot() {   # block until at least one slot is free
  local p rc harvested=0
  while (( harvested == 0 )); do
    (( ${#FR_PID_SLOT[@]} > 0 )) || return 0
    wait -n 2>/dev/null
    rc=$?
    for p in "${!FR_PID_SLOT[@]}"; do
      kill -0 "$p" 2>/dev/null && continue
      fr_harvest "$p"
      harvested=$(( harvested + 1 ))
    done
    # 127 is `wait -n`'s "there is nothing left to wait for". Draining here is
    # what keeps this loop from spinning if a child is gone but unaccounted for.
    if (( harvested == 0 && rc == 127 )); then
      for p in "${!FR_PID_SLOT[@]}"; do
        fr_harvest "$p"
        harvested=$(( harvested + 1 ))
      done
    fi
  done
}

fr_drain() { while (( ${#FR_PID_SLOT[@]} > 0 )); do fr_wait_for_slot; done; }

# ── target selection ──────────────────────────────────────────────────────────
FR_TARGETS=()
FR_ORACLES=()

fr_load_targets() {
  local kind lineno target category oracle skipped=0
  # The 6th and 7th fields (functions, reason) belong to the DEFERRED/EXCLUDED
  # grammar; an ACTIVE row never carries them, so they are read into `_`.
  while IFS='|' read -r kind lineno target category oracle _; do
    [[ "$kind" == "ACTIVE" ]] || continue
    [[ -n "$target" ]] || continue
    case "$category" in
      GREPPED-ONLY) skipped=$(( skipped + 1 )); continue ;;
      EXECUTED-PARTIAL)
        fr_err "$FR_CONF:$lineno: $target is an ACTIVE EXECUTED-PARTIAL row, and the generator has no per-function mutation unit — mutating the whole file would manufacture survivors in functions the suite never executes. Defer the row or slice the unit first."
        return 2 ;;
      EXECUTED-WHOLE) ;;
      *)
        fr_err "$FR_CONF:$lineno: $target has category '${category:-<empty>}', which this runner does not know"
        return 2 ;;
    esac
    if [[ -n "$FR_TARGET" && "$target" != "$FR_TARGET" && "${target##*/}" != "$FR_TARGET" ]]; then
      continue
    fi
    if [[ ! -f "$FR_REPO/$target" ]]; then
      fr_err "$FR_CONF:$lineno: $target does not exist under $FR_REPO"
      return 2
    fi
    if [[ -z "$oracle" || "$oracle" == "-" ]]; then
      fr_err "$FR_CONF:$lineno: $target has no oracle test"
      return 2
    fi
    FR_TARGETS+=("$target")
    FR_ORACLES+=("$oracle")
  done < <(bash "$FR_DERIVE" --rows "$FR_CONF")
  (( skipped > 0 )) && fr_warn "skipped $skipped GREPPED-ONLY row(s): the suite never executes them, so every mutant would survive as noise"
  if (( ${#FR_TARGETS[@]} == 0 )); then
    if [[ -n "$FR_TARGET" ]]; then
      fr_err "--target $FR_TARGET matches no active row in $FR_CONF"
    else
      fr_err "$FR_CONF has no active EXECUTED-WHOLE row — there is nothing to mutate"
    fi
    return 2
  fi
  return 0
}

fr_usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── main ──────────────────────────────────────────────────────────────────────
falsify_main() {
  local i n target oracle mutants total=0 t_run t_target
  local seq op lineno sha text slot res rc=0

  while (( $# > 0 )); do
    case "$1" in
      --target) FR_TARGET="${2:-}"; shift 2 || return 2 ;;
      --jobs) FR_JOBS="${2:-}"; shift 2 || return 2 ;;
      --timeout) FR_TIMEOUT="${2:-}"; shift 2 || return 2 ;;
      --operators) FALSIFY_OPERATORS="${2:-}"; export FALSIFY_OPERATORS; shift 2 || return 2 ;;
      -h|--help) fr_usage; return 0 ;;
      *) fr_err "unknown option: $1"; fr_usage >&2; return 2 ;;
    esac
  done
  if [[ ! "$FR_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    fr_err "--jobs must be a positive integer, got '${FR_JOBS}'"; return 2
  fi
  if [[ ! "$FR_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    fr_err "--timeout must be a positive integer (seconds), got '${FR_TIMEOUT}'"; return 2
  fi
  if [[ ! -f "$FR_CONF" ]]; then fr_err "no such targets map: $FR_CONF"; return 2; fi
  if [[ ! -f "$FR_GENERATE" ]]; then fr_err "no generator at $FR_GENERATE"; return 2; fi

  fr_load_targets || return 2

  FR_SCRATCH="$(mktemp -d)" || return 1
  trap fr_cleanup EXIT INT TERM
  FR_CACHE="$FR_SCRATCH/pristine"
  FR_WORK="$FR_SCRATCH/work"
  FR_OUT="$FR_SCRATCH/out"
  mkdir -p "$FR_WORK" "$FR_OUT" || return 1

  t_run="$(fr_now_us)"
  falsify_seed_tree "$FR_REPO" "$FR_CACHE" || return 1
  if [[ ! -f "$FR_CACHE/$FR_DRIVER_REL" ]]; then
    fr_err "the seeded tree has no suite driver at $FR_DRIVER_REL — the oracle contract cannot hold"
    return 1
  fi

  # Generate everything up front: the RUN header then carries real totals, and a
  # generator that suddenly matches nothing is reported before an hour of oracle
  # runs rather than after.
  for (( i = 0; i < ${#FR_TARGETS[@]}; i++ )); do
    target="${FR_TARGETS[i]}"
    mutants="$FR_OUT/mutants.$i.tsv"
    if ! bash "$FR_GENERATE" "$FR_CACHE/$target" > "$mutants"; then
      fr_err "the generator failed on $target"
      return 1
    fi
    n="$(grep -c . "$mutants")"
    if (( n == 0 )); then
      fr_err "$target generated NO mutant — the operators matched nothing, which measures the generator, not the suite"
      return 1
    fi
    total=$(( total + n ))
  done

  printf 'RUN|repo=%s|conf=%s|jobs=%s|timeout=%s|operators=%s|targets=%s|mutants=%s\n' \
    "$FR_REPO" "$FR_CONF" "$FR_JOBS" "$FR_TIMEOUT" \
    "${FALSIFY_OPERATORS-<default>}" "${#FR_TARGETS[@]}" "$total"

  # Worker trees, seeded in parallel: each is a ~20 MB copy and they are
  # independent, so N of them cost about as long as one.
  FR_FREE_SLOTS=()
  for (( i = 0; i < FR_JOBS; i++ )); do fr_seed_slot "$i" & done
  wait
  for (( i = 0; i < FR_JOBS; i++ )); do
    if [[ ! -d "$(fr_slot_tree "$i")" ]]; then
      fr_err "worker slot $i could not be seeded"
      return 1
    fi
    FR_FREE_SLOTS+=("$i")
  done

  for (( i = 0; i < ${#FR_TARGETS[@]}; i++ )); do
    target="${FR_TARGETS[i]}"
    oracle="${FR_ORACLES[i]}"
    mutants="$FR_OUT/mutants.$i.tsv"
    FR_KILLED=0; FR_SURVIVED=0; FR_UNPROVEN=0; FR_TIMEOUTS=0
    t_target="$(fr_now_us)"

    # ── the pristine baseline ───────────────────────────────────────────────
    # An oracle that is not green on the UNMUTATED tree cannot distinguish
    # anything: every mutant would be reported KILLED. rc=2 is named for what
    # it is, because that is what a misspelled oracle looks like.
    falsify_run_oracle "$(fr_slot_tree 0)" "$oracle" "$FR_OUT/baseline.log" "$FR_TIMEOUT"
    falsify_verdict "$FALSIFY_RC" "$FR_OUT/baseline.log" "$FALSIFY_TIMED_OUT"
    if [[ "$FALSIFY_VERDICT" != "SURVIVED" ]]; then
      if (( FALSIFY_RC == 2 )); then
        fr_err "oracle '$oracle' matched NO test (run-all.sh exit 2) — a misspelled oracle name would report every mutant of $target as KILLED. Skipping $target."
      else
        fr_err "oracle '$oracle' is not green on the PRISTINE tree (rc=$FALSIFY_RC, signal=$FALSIFY_SIGNAL) — every mutant of $target would be reported KILLED. Skipping $target."
      fi
      sed 's/^/    /' "$FR_OUT/baseline.log" | tail -20 >&2
      rc=1
      continue
    fi
    printf 'BASELINE|%s|%s|PASS|%s\n' "$target" "$oracle" "$FALSIFY_MS"

    seq=0
    while IFS=$'\t' read -r op lineno sha text; do
      [[ -n "$op" ]] || continue
      seq=$(( seq + 1 ))
      while (( ${#FR_FREE_SLOTS[@]} == 0 )); do fr_wait_for_slot; done
      slot="${FR_FREE_SLOTS[0]}"
      FR_FREE_SLOTS=("${FR_FREE_SLOTS[@]:1}")
      res="$FR_OUT/result.$slot.$seq"
      rm -f "$res"
      fr_run_mutant "$slot" "$target" "$oracle" "$seq" "$lineno" "$op" "$sha" "$text" "$res" &
      FR_PID_SLOT["$!"]="$slot"
      FR_PID_RESULT["$!"]="$res"
    done < "$mutants"
    fr_drain

    printf 'TARGET|%s|%s|%s|%s|%s|%s|%s|%s\n' "$target" "$oracle" \
      "$(( FR_KILLED + FR_SURVIVED + FR_UNPROVEN ))" "$FR_KILLED" "$FR_SURVIVED" \
      "$FR_UNPROVEN" "$FR_TIMEOUTS" "$(fr_ms_since "$t_target")"
  done

  local done_total pct
  done_total=$(( FR_T_KILLED + FR_T_SURVIVED + FR_T_UNPROVEN ))
  pct=0
  # UNPROVEN counts toward the numerator: it names a place where nothing was
  # observed asserting, which is what a survivor names too. Reporting it inside
  # the kill rate is what made a slow oracle look like a working assertion.
  (( done_total > 0 )) && pct=$(( ( FR_T_SURVIVED + FR_T_UNPROVEN ) * 100 / done_total ))
  printf 'TOTAL|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${#FR_TARGETS[@]}" "$done_total" "$FR_T_KILLED" "$FR_T_SURVIVED" "$FR_T_UNPROVEN" \
    "$FR_T_TIMEOUTS" "$pct" "$(fr_ms_since "$t_run")"

  if (( FR_BROKEN > 0 )); then
    fr_err "$FR_BROKEN mutant(s) produced no verdict — they are NOT counted as kills"
    rc=1
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  falsify_main "$@"
  exit $?
fi
