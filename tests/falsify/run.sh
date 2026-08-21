#!/usr/bin/env bash
# tests/falsify/run.sh — the mutation tier's runner: damage ONE line of a target
# file, run the hermetic test that covers it, and record whether anything
# noticed. A mutant nothing noticed — a SURVIVOR — is evidence that an assertion
# is missing or cannot fail.
#
#   bash tests/falsify/run.sh [--target <file>] [--jobs N|auto] [--timeout S]
#                            [--operators <list>] [--max-unproven-pct N]
#                            [--max-assertless N] [--controls N]
#
#   --jobs auto             workers = min(what the OS reports, the cgroup CPU
#                           quota). `nproc` reads the affinity mask and does not
#                           see a `--cpus` quota, so it over-reports inside a
#                           container — see fr_cpu_budget for the measurement.
#   --max-unproven-pct N    fail the run when more than N% of mutants produced
#                           no verdict. Opt-in: an UNPROVEN mutant is machine
#                           state, so only the REFERENCE environment sets it.
#   --controls N            interleave N PRISTINE oracle runs per target, in real
#                           worker slots, under the same load as the mutants
#                           around them. A control that FAILS means the oracle
#                           went red without any mutation present, so the kills
#                           in that run may be the machine's rather than the
#                           damage's — the run says so and exits non-zero.
#                           Default 2; 0 disables. (backlog F30, F32)
#   --max-assertless N      fail the run when more than N kills arrived with no
#                           FAIL: line — the oracle exited non-zero without
#                           being seen to assert anything. Unlike the unproven
#                           fraction this is a property of the oracle's CODE,
#                           not of the machine, so it is satisfiable everywhere
#                           at once and CI passes 0. Opt-in all the same: see
#                           the note beside the check for why.
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
#   ASSERTLESS|<kills-with-no-failline>|<killed>
#
#   identity   <file>:<operator>:<sha1-of-trimmed-original-line> — the ledger
#              identity, NEVER file:line, because a line number changes on every
#              edit above it while the sha1 of the line does not.
#   verdict    KILLED | SURVIVED | UNPROVEN. UNPROVEN means nothing was observed
#              asserting — the oracle timed out, said it could not set ITSELF
#              up, or was killed by a SIGNAL — in every case without ever
#              printing a FAIL: line. It is not a kill and must not be read as
#              one — see the note on falsify_verdict. It is ACCEPTED in the
#              ledger like a survivor but NOT REQUIRED there: the timeout that
#              produced it is a property of the machine, and a ratchet that
#              cannot be satisfied everywhere at once is not a ratchet (backlog
#              F27; check-ledger.sh's check B carries the same note). The price
#              of that exemption is that unproven mutants leave the measured set
#              silently, which is what --max-unproven-pct bounds.
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
# ── the effective CPU budget ──────────────────────────────────────────────────
# `nproc` IS NOT THE NUMBER OF CPUS THIS PROCESS MAY BURN. It reads the affinity
# MASK, while `docker run --cpus=N` — which is how this repo's own sandbox.sh
# starts every container, defaulting to 1.0 — imposes a CFS QUOTA and leaves the
# mask alone. Inside such a container nproc reports the HOST's count, and
# `--jobs $(nproc)` oversubscribes the quota by whatever the ratio happens to be.
#
# That is a correctness question, not a throughput one. Every worker runs a
# whole run-all.sh, so the oversubscription lands on the per-mutant clock that
# --timeout is measured against — and a mutant that trips it is scored UNPROVEN,
# which check-ledger.sh deliberately does not require an entry for. A mutant
# that WAS killed therefore leaves the measured set with nothing failing.
#
# Measured here, one target (tests/lib-verify-repo.sh: 49 mutants, no structural
# timeouts), nproc 12, cgroup quota 8, verdicts identical on every row:
#
#   --jobs        1     2     4     8*    12    16    32     48
#   wall        55s   31s   20s   16s   15s   15s   17s    18s
#   ms/mutant  1041  1124  1351  1901  2881  3539  7541  11294
#                                ^quota  ^nproc
#
# Wall-clock stops improving AT the quota and then gets worse, while the
# per-mutant clock climbs to 10.9x. Going from the quota to nproc's 12 buys one
# second of wall-clock and spends 52% of every mutant's timeout budget.
# How many PRISTINE control runs to interleave among each target's mutants.
# See fr_run_control: this is the only thing that asks "is this oracle green
# UNDER THESE CONDITIONS", which is the question a per-target baseline taken on
# a quiet machine cannot answer (backlog F30, F32).
FR_CONTROLS="${FALSIFY_CONTROLS:-2}"
FR_MAX_UNPROVEN_PCT="${FALSIFY_MAX_UNPROVEN_PCT:-}"
FR_MAX_ASSERTLESS="${FALSIFY_MAX_ASSERTLESS:-}"
FR_CGROUP="${FALSIFY_CGROUP:-/sys/fs/cgroup}"

fr_host_cpus() {   # what the OS reports, before any quota is applied
  local n
  n="$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=4
  printf '%s' "$n"
}

# The cgroup CPU quota in whole CPUs, or NOTHING when there is no quota. Both
# layouts are read because both are in service: v2 states it in one file as
# "<quota> <period>" (or the literal `max`), v1 in two files where -1 means
# unlimited. Anything unparseable is treated as "no quota" — this must never
# invent a limit that is not there.
fr_quota_cpus() {
  local q p n
  if [[ -r "$FR_CGROUP/cpu.max" ]]; then
    read -r q p < "$FR_CGROUP/cpu.max" || return 0
  elif [[ -r "$FR_CGROUP/cpu/cpu.cfs_quota_us" && -r "$FR_CGROUP/cpu/cpu.cfs_period_us" ]]; then
    read -r q < "$FR_CGROUP/cpu/cpu.cfs_quota_us" || return 0
    read -r p < "$FR_CGROUP/cpu/cpu.cfs_period_us" || return 0
  else
    return 0
  fi
  # ONE rejection, deliberately. v2 spells "no quota" as the literal `max`, v1
  # spells it -1, and a layout nobody has met yet will spell it a third way —
  # all three are the same answer, and one guard that states it (a positive
  # integer pair, or no quota) is worth more than three that each catch one
  # spelling. Three DID exist here, and the test could not break any of them
  # individually: an assertion no single change can falsify is not a guard.
  [[ "$q" =~ ^[1-9][0-9]*$ && "$p" =~ ^[1-9][0-9]*$ ]] || return 0
  # FLOOR, and never zero: half a CPU of quota still gets one worker, because
  # zero workers is not a smaller measurement, it is no measurement.
  n=$(( q / p ))
  (( n < 1 )) && n=1
  printf '%s' "$n"
}

fr_cpu_budget() {   # workers this host can actually run: min(reported, quota)
  local host quota
  host="$(fr_host_cpus)"
  quota="$(fr_quota_cpus)"
  if [[ -n "$quota" ]] && (( quota < host )); then printf '%s' "$quota"; else printf '%s' "$host"; fi
}

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
# Milliseconds as seconds, for notes that must report a MEASUREMENT rather than
# repeat back the setting they were configured with. Non-numeric input yields
# `?` rather than a shell arithmetic error: this formats a field parsed out of a
# worker's record, and a note is the wrong place to die.
fr_secs() {   # <milliseconds> → "N.Ms", or "?" when the record carried no number
  case "${1:-}" in
    (''|*[!0-9]*) printf '?' ;;
    (*)           printf '%d.%ds' $(( $1 / 1000 )) $(( ( $1 % 1000 ) / 100 )) ;;
  esac
}
fr_err()  { printf 'ERROR: %s\n' "$*" >&2; }

# ── who armed a timeout flag ──────────────────────────────────────────────────
# The token written into a slot's timeout flag, and the sentence printed when the
# flag turns out to belong to somebody else. Both are FUNCTIONS, and both are
# pure, because the open question they serve is an identification problem: a
# watchdog from another invocation killed a live oracle twice in one run and the
# NOTE could not say which one, because it printed the FOREIGN token with nothing
# to compare it against (backlog F53).
#
# `<label>.<pid>.<microseconds>`. $BASHPID, never $$ — inside a forked worker $$
# is still the top-level shell's pid, which every slot would share, which is the
# property F50 was fixed to establish. The LABEL is what F53 adds: a bare pid
# names a process that has already exited by the time anyone reads it, while
# `s3.m47` names the slot and the mutant whose watchdog wrote it.
fr_token() {   # <label> → this invocation's timeout-flag token
  printf '%s.%s.%s' "${1:-?}" "$BASHPID" "$(fr_now_us)"
}

# ARMING THE FLAG MUST BE ATOMIC. `printf '%s' "$token" > "$flag"` is TWO steps:
# the redirection creates and truncates the destination, and only then does the
# token land in it. A reader between those steps sees a file that EXISTS and
# does not yet hold the token — and falsify_flag_is_mine can only report that as
# somebody else's.
#
# That is not a theory. Measured on macOS, 2026-08-20, --jobs 32 --timeout 5:
#
#   slot 1 held a timeout flag armed by s1.m2.67442.1787254686507373, not by
#   this invocation, whose own token was s1.m2.67442.1787254686507373
#
# The same string, on both sides of "not by this invocation". The predicate read
# the flag once and got an incomplete file; the reporter read it again a few
# microseconds later and got the whole token. There was never a foreign
# watchdog — the leak F53 was filed for is a worker mistaking its OWN flag,
# because the write it was racing had no atomicity.
#
# The rename removes the window: a reader sees no file, or the whole token.
# Never a half-written one. mv within a directory is a rename, so there is no
# instant at which the destination exists holding part of the token.
falsify_arm_flag() {   # <flagfile> <token> → 0 iff the flag now holds the token
  local tmp="$1.$BASHPID.arming"
  printf '%s' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

fr_foreign_note() {   # <ident> <slot> <foreign token> <own token> → the NOTE line
  printf 'NOTE|foreign-timeout-flag|%s|slot %s held a timeout flag armed by %s, not by this invocation, whose own token was %s\n' \
    "$1" "$2" "$3" "$4"
}

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
# ── the timeout flag, and why it carries a token ──────────────────────────────
# The flag is a SIGNAL ON A SHARED PATH: `out` is "$FR_OUT/w$slot.log", one file
# per WORKER SLOT, reused by every mutant that ever runs in that slot across
# every target. So "the flag exists" only ever meant "somebody wrote it", and it
# was read as "MY oracle timed out".
#
# It is not the same thing, and the difference was measured. macOS, 2026-08-20,
# --jobs 8 --timeout 600, five mutants carrying a `timeout` signal:
#
#   59.8s  KILLED    timeout+exit+failline  tests/integration/mutate.sh:return-flip:7efad11b
#    6.6s  KILLED    timeout+exit+failline  tests/lib-layer-checks.sh:logic-flip:62fc80a5
#   39.8s  KILLED    timeout+exit+failline  tests/lib-verify-repo.sh:cond-negate:6c630c05
#   12.3s  UNPROVEN  timeout                tests/bash-dialect-lint.sh:cond-negate:f204b4ce
#   12.7s  UNPROVEN  timeout                tests/bash-dialect-lint.sh:logic-flip:b3f102dc
#
# Every one ran a fraction of its 600-second clock, so none of them timed out.
# The last two settle what wrote the flag: a bare `timeout` signal means the
# oracle exited with a NON-killing status and printed no FAIL: line — it ran to
# completion and passed. A watchdog that had actually fired would have TERMed it
# and left `timeout+signal`. So the flag was armed by a watchdog that was not
# watching this oracle: a stale one, from an earlier invocation in the same
# slot, whose own `kill` hit a pid that no longer exists and was swallowed by
# `2>/dev/null`, leaving only the write.
#
# The cost is not the wrong label. `timeout` without `failline` is UNPROVEN, and
# UNPROVEN is accepted-but-not-required in the ledger because a real timeout is
# machine state — so those two SURVIVORS left the measured set owing nothing and
# saying nothing. That is this tier's one job, lost through the exemption.
#
# Two layers, because they fail differently. The watchdog now refuses to arm a
# flag for an oracle that has already exited, which stops a stale one at the
# source; and the flag carries the TOKEN of the invocation that armed it, so a
# flag this run did not write can never be read as this run's timeout however it
# got there. The second layer also makes the event visible instead of silent:
# a foreign flag is reported, not just ignored.
# A watchdog that sleeps its whole clock is STALE for as long as it outlives the
# oracle it was watching, and a stale one is not merely useless: it goes on to
# run `kill -TERM -"$pid"` against a pid recorded up to <timeout> seconds ago. On
# a busy macOS host that pid — and its process group id — can have been recycled
# by then, so the kill lands on ANOTHER WORKER'S LIVE ORACLE and truncates it.
#
# That is what made the false timeouts of 2026-08-20 more than a labelling bug.
# Two `tests/bash-dialect-lint.sh` mutants were recorded UNPROVEN on a bare
# `timeout` — neither a killing exit nor a FAIL: line — and were read here as
# survivors. They are not: measured on the same host once the flag was owned,
# that target is 27 mutants, 27 KILLED, 0 timeouts. Their oracles had been cut
# short mid-run, which is why they produced no verdict of their own.
#
# So the interference corrupts the RUN, not just its label, and therefore is not
# conservative: a suite truncated after some other test has already printed a
# FAIL: line reads as `exit+failline`, which is a KILL — and a false kill is how
# a survivor disappears. Backlog F50.
#
# The fix is for the watchdog to stop existing when its subject does. Polling is
# the right shape HERE, unlike in tests/portability.sh's p_timeout (F22), which
# is itself a mutation target where a negated liveness probe must stay killable:
# tests/falsify/run.sh is the measuring instrument and is never mutated.
falsify_watch_until() {   # <pid> <seconds> → 0 the pid went away first, 1 the clock ran out
  local pid="$1" secs="$2" i
  for (( i = 0; i < secs; i++ )); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  # Once more after the last sleep: a pid that exits during the final second has
  # still exited before the clock, and firing on it would be the same staleness
  # one second smaller.
  kill -0 "$pid" 2>/dev/null || return 0
  return 1
}

falsify_run_oracle() {   # <tree> <oracle-set> <outfile> <timeout-seconds> [<label>]
  local tree="$1" oracle="$2" out="$3" limit="$4" label="${5:-?}"
  local flag="$out.timedout" pid dog t0 token
  # The oracle field is a SET: `a.sh,b.sh` names ONE invocation running both,
  # because run-all.sh OR-combines its filters and reports one aggregate status
  # — so a FAIL: from any member is this target's kill signal, and the baseline
  # requires every member green. Split into an array rather than relying on word
  # splitting: an unquoted `${oracle//,/ }` at the command position would also
  # glob, and a `*` reaching run-all.sh as a filter would select the whole suite.
  local -a onames=()
  IFS=',' read -r -a onames <<<"$oracle"
  rm -f "$flag"
  # Unique to THIS invocation, and self-describing: see fr_token.
  token="$(fr_token "$label")"
  FALSIFY_TOKEN="$token"
  t0="$(fr_now_us)"
  # Monitor mode so each background job leads its own process group and a
  # timeout can kill the oracle's WHOLE tree of children (run-all.sh forks a
  # bash per test), not just the driver.
  set -m
  ( cd "$tree" && exec bash "$FR_DRIVER_REL" -v "${onames[@]}" ) >"$out" 2>&1 &
  pid=$!
  ( # Returns the moment the oracle exits, so this watchdog is never stale for
    # more than a second — and a pid cannot be recycled into another worker's
    # oracle inside a window that small.
    falsify_watch_until "$pid" "$limit" && exit 0
    falsify_arm_flag "$flag" "$token"
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
  FALSIFY_FOREIGN_FLAG=""
  if [[ -f "$flag" ]]; then
    if falsify_flag_is_mine "$flag" "$token"; then
      FALSIFY_TIMED_OUT=1
    else
      # Not this invocation's flag. Not a timeout, and not silence either: the
      # caller reports it, so a leak that gets past the liveness guard above is
      # a named event rather than a mutant quietly leaving the measured set.
      FALSIFY_FOREIGN_FLAG="$(cat "$flag" 2>/dev/null || true)"
      FALSIFY_FOREIGN_FLAG="${FALSIFY_FOREIGN_FLAG:-<empty>}"
    fi
  fi
  rm -f "$flag"
  return 0
}

# Kept apart from its caller so it can be asserted directly: the whole defect
# was that "the flag exists" and "this run armed the flag" were the same
# expression. An empty flag — the form the old code wrote — is deliberately NOT
# mine: a flag with no owner is exactly what cannot be attributed.
falsify_flag_is_mine() {   # <flagfile> <token> → 0 iff this invocation armed it
  [[ -f "$1" ]] || return 1
  [[ -n "$2" ]] || return 1
  [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]
}

# ── the verdict ───────────────────────────────────────────────────────────────
# Sets FALSIFY_VERDICT and FALSIFY_SIGNAL from the three signals.
FALSIFY_VERDICT=""
FALSIFY_SIGNAL=""
# Set by falsify_run_oracle when the slot's flag was armed by some other
# invocation. Declared here so `set -u` holds even if a future caller reads it
# before the first oracle runs.
FALSIFY_FOREIGN_FLAG=""
# The token THIS invocation armed its own flag with. Only meaningful next to
# FALSIFY_FOREIGN_FLAG: one foreign token names nothing, two tokens name a pair.
FALSIFY_TOKEN=""
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
  # is unproven — accepted in the ledger like a survivor, but NOT required
  # there, because the timeout is machine state (check-ledger.sh's check B,
  # backlog F27). What bounds that exemption is --max-unproven-pct, not the
  # ledger.
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

  falsify_run_oracle "$tree" "$oracle" "$out" "$FR_TIMEOUT" "s$slot.m$seq"
  falsify_verdict "$FALSIFY_RC" "$out" "$FALSIFY_TIMED_OUT"

  printf 'MUTANT|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$FALSIFY_VERDICT" "$ident" "$oracle" "$seq" "$lineno" \
    "$FALSIFY_SIGNAL" "$FALSIFY_MS" "$text" > "$res"

  # A flag this invocation did not arm reached this slot. Recorded against the
  # mutant it would have mislabelled, and naming the SLOT, because the slot is
  # the shared thing — if these cluster, they name the leak.
  if [[ -n "$FALSIFY_FOREIGN_FLAG" ]]; then
    fr_foreign_note "$ident" "$slot" "$FALSIFY_FOREIGN_FLAG" "$FALSIFY_TOKEN" >> "$res"
  fi

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

# ── one CONTROL run: the pristine oracle, under load ──────────────────────────
# A KILL is only trustworthy if the oracle would have PASSED under the same
# conditions. `run.sh` already runs each target's oracle on the pristine tree and
# requires PASS — but once, at the start, with no workers running. That
# establishes the oracle is green on a QUIET machine, which is not the condition
# the mutants are measured under, and the tier itself is what loads the machine.
#
# The failure that matters is not a slow oracle (F12 closed that) but a
# FAILING-because-loaded one: measured 2026-08-17, a contaminated oracle failed
# with signal `exit+failline` in 2.5 seconds — no timeout at all. A false KILL
# then deletes the evidence a survivor would have provided: the mutant never
# reaches the survivor set, check-ledger.sh never demands an entry, and the gap
# becomes invisible. That is the tier's own failure mode inverted (backlog F30).
#
# So this runs the UNMUTATED tree through a real worker slot, interleaved among
# the mutants, and asks the only question that detects it: is this oracle green
# under THESE conditions? A control that fails does not identify which kills are
# contaminated — it says the run's kills cannot be trusted, which is the honest
# claim and is enough to refuse the run.
fr_run_control() {   # <slot> <target> <oracle> <n> <resultfile>
  local slot="$1" target="$2" oracle="$3" n="$4" res="$5"
  local tree out verdict
  tree="$(fr_slot_tree "$slot")"
  out="$FR_OUT/w$slot.log"
  falsify_run_oracle "$tree" "$oracle" "$out" "$FR_TIMEOUT" "c$slot.n$n"
  falsify_verdict "$FALSIFY_RC" "$out" "$FALSIFY_TIMED_OUT"
  # SURVIVED is falsify_verdict's word for "the oracle noticed nothing", which
  # on an unmutated tree is exactly PASS. Anything else means the oracle went
  # red with no mutation present.
  if [[ "$FALSIFY_VERDICT" == "SURVIVED" ]]; then verdict=PASS; else verdict=FAIL; fi
  printf 'CONTROL|%s|%s|%s|%s|%s|%s\n' \
    "$verdict" "$target" "$oracle" "$n" "$FALSIFY_SIGNAL" "$FALSIFY_MS" > "$res"

  # A FAILED CONTROL THAT CANNOT SAY WHAT FAILED IS HALF A FINDING. `$out` is
  # "$FR_OUT/w<slot>.log" — per SLOT, reused by the next mutant that lands
  # there, and removed with the scratch tree at exit. So by the time anyone
  # reads the error, the oracle's own FAIL: lines are gone.
  #
  # Measured the hard way: the first real macOS run to trip a control
  # (2026-08-21, jobs=8) reported `exit+failline` on
  # tests/bash-dialect-lint.sh and nothing whatsoever about WHICH assertion
  # went red — which is the one fact needed to tell a load-sensitive oracle
  # from a defect in it, and F32's standing advice is to look for a mechanism
  # before reaching for --timeout.
  #
  # Carried as NOTE records rather than dumped to stderr, because fr_harvest
  # already prints every record line to stdout: the diagnosis then lands in the
  # run log beside the CONTROL record it explains, in order, instead of
  # interleaved with whatever other workers were writing at the time.
  if [[ "$verdict" == "FAIL" ]]; then
    # THE CONTINUATION LINES MATTER AS MUCH AS THE FAIL: LINE. This repo's
    # `check` helper prints the failure name on the FAIL: line and the
    # `expected:` / `got:` values INDENTED underneath it. Grepping only `^FAIL:`
    # therefore captures the name of the assertion and discards the evidence —
    # measured on the first host run that produced a diagnosis (2026-08-21):
    # five of six captured lines were bare names, and the only one that told
    # anybody anything was the case whose message happened to be on one line.
    awk '
      /^(FAIL:|SCAFFOLD-FAILED:)/ { if (n++ < 6) { keep = 1; print; next } keep = 0; next }
      keep && /^[[:space:]]/      { print; next }
      { keep = 0 }
    ' "$out" 2>/dev/null | head -30 \
      | while IFS= read -r cl; do
          printf 'NOTE|control-output|%s|%s\n' "$target" "$cl" >> "$res"
        done
    # An oracle that went red with no FAIL: line at all is a DIFFERENT event —
    # a bare non-zero exit — and saying nothing would read as "no output was
    # captured" rather than "there was none".
    if ! grep -qE '^(FAIL:|SCAFFOLD-FAILED:)' "$out" 2>/dev/null; then
      printf 'NOTE|control-output|%s|(no FAIL: or SCAFFOLD-FAILED: line — the oracle exited non-zero in silence; last line was: %s)\n' \
        "$target" "$(tail -1 "$out" 2>/dev/null | tr -d '|')" >> "$res"
    fi
  fi
  return 0
}

# ── the worker pool ───────────────────────────────────────────────────────────
declare -A FR_PID_SLOT=()
declare -A FR_PID_RESULT=()
# What `wait` said about each finished worker. Parallel to the two maps above
# and populated by fr_wait_for_slot, because the status is the ONLY thing that
# distinguishes a worker that gave up from one that was killed — see
# fr_exit_cause.
declare -A FR_PID_STATUS=()
FR_FREE_SLOTS=()
FR_KILLED=0
FR_SURVIVED=0
FR_UNPROVEN=0
FR_TIMEOUTS=0
FR_ASSERTLESS=0
FR_BROKEN=0
# A target whose PRISTINE baseline is not green is skipped WHOLE, and every one
# of its mutants leaves the corpus without ever being attempted. That is not the
# same event as a mutant that ran and produced nothing (FR_BROKEN), and it is
# invisible in TOTAL, whose first field counts the targets fr_load_targets
# ACCEPTED — not the ones that were measured (backlog F54).
FR_SKIPPED_TARGETS=0
FR_SKIPPED_MUTANTS=0
# Control runs: the PRISTINE oracle, executed in a real worker slot, under the
# same load as the mutants around it. See fr_run_control.
FR_CONTROLS_OK=0
FR_CONTROLS_FAILED=0
FR_T_KILLED=0
FR_T_SURVIVED=0
FR_T_UNPROVEN=0
FR_T_TIMEOUTS=0
FR_T_ASSERTLESS=0

# Why a worker produced nothing, from its `wait` status. A FUNCTION, and a pure
# one, because tests/test-falsify-run.sh asserts on the sentence directly: the
# defect it closes is that this sentence did not exist at all. "A worker
# produced no verdict" and "a worker was SIGKILLed by something else" are the
# same observation until somebody prints the status, and on macOS 158 of 264
# mutants left the measured set through that silence (backlog F52).
fr_exit_cause() {   # <wait status, possibly empty> → a clause for the error line
  local st="${1:-}" sig
  case "$st" in
    ''|*[!0-9]*) printf 'exit status not captured'; return 0 ;;
  esac
  # `> 128`, never `>= 128`: 128 is an exit status of 128, and reading it as
  # signal 0 would name a signal that does not exist for a worker that simply
  # exited.
  if (( st == 0 )); then
    printf 'it exited 0 and wrote nothing'
  elif (( st > 128 && st <= 192 )); then
    sig="$(kill -l "$(( st - 128 ))" 2>/dev/null)"
    printf 'it was KILLED BY SIG%s' "${sig:-$(( st - 128 ))}"
  else
    printf 'it exited %s' "$st"
  fi
}

fr_harvest() {   # <pid> — print that mutant's records and tally them
  local pid="$1"
  local slot="${FR_PID_SLOT[$pid]}" res="${FR_PID_RESULT[$pid]}"
  local line f2 f3 f7 c_target c_oracle c_sig c_ms co_line
  local cause
  cause="$(fr_exit_cause "${FR_PID_STATUS[$pid]:-}")"
  unset "FR_PID_SLOT[$pid]" "FR_PID_RESULT[$pid]" "FR_PID_STATUS[$pid]"
  FR_FREE_SLOTS+=("$slot")
  if [[ ! -s "$res" ]]; then
    fr_err "a mutant worker produced no verdict at all (slot $slot; $cause) — not counted as a kill"
    FR_BROKEN=$(( FR_BROKEN + 1 ))
    rm -f "$res"
    return 0
  fi
  while IFS= read -r line; do
    printf '%s\n' "$line"
    IFS='|' read -r _ f2 f3 f4 _ _ f7 f8 _ <<< "$line"
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
            #
            # AND SAY HOW LONG IT ACTUALLY RAN. This note used to print the
            # CONFIGURED clock — "TIMEOUT after 600s" — for a mutant whose own
            # record says it finished in well under a second. That is not a
            # loose way of saying the same thing: it is the reporter stating a
            # measurement it never took, and it hid a live contradiction for as
            # long as it stood. Measured on macOS, 2026-08-20, --timeout 600:
            # tests/integration/docker-shim.sh reported 3 timeouts inside a
            # target whose entire wall time was 64s, and tests/lib-layer-checks.sh
            # reported 1 inside 54s. Neither is possible against a 600-second
            # clock, and one of them turned a SURVIVED mutant into an UNPROVEN
            # one — which drops a ledger obligation in silence, the single thing
            # this tier exists to stop. Backlog F50.
            #
            # $f8 is the mutant's own measured elapsed, from the record printed
            # three lines above. Both numbers are named because it is the
            # RELATIONSHIP that carries the meaning: a real timeout ran at least
            # as long as its clock, and anything else is the tier reporting a
            # verdict it did not observe.
            if [[ "$f2" == "UNPROVEN" ]]; then
              fr_warn "TIMEOUT: the oracle ran $(fr_secs "$f8") against a ${FR_TIMEOUT}s clock (UNPROVEN — nothing was observed asserting): $f3"
            else
              fr_warn "TIMEOUT: the oracle ran $(fr_secs "$f8") against a ${FR_TIMEOUT}s clock (killed before the clock ran out): $f3"
            fi ;;
        esac
        # A signal death is UNPROVEN, and silently so it would look like an
        # ordinary assertion gap in the ledger. Name the likely cause where the
        # reader can act on it: --jobs workers each run a whole run-all.sh, and
        # on a memory-capped host the kernel picks one.
        case "$f7" in
          *signal*) fr_warn "ORACLE KILLED BY A SIGNAL (UNPROVEN — nothing was observed asserting; check the host's memory cap against --jobs $FR_JOBS): $f3" ;;
        esac
        # A KILL WITH NO ASSERTION ATTACHED. The oracle exited non-zero and
        # never printed a FAIL: line — it did not time out, was not signalled,
        # and did not report a scaffold failure, all of which are UNPROVEN
        # above. What is left is a test that aborted somewhere without
        # reporting, and the tier reads that as "the mutation was noticed".
        #
        # This is the third member of a family found one mutant at a time, by
        # hand, never by the gate: F35 (a signal death scored as a kill), F30
        # (a load-induced one), F43 (an errexit abort, where two of
        # shared-files.sh's mutants were "killed" by an oracle that never
        # reached an assertion). The evidence column has recorded which channel
        # produced every kill since the tier was written; nothing read it.
        if [[ "$f2" == "KILLED" && "$f7" != *failline* ]]; then
          FR_ASSERTLESS=$(( FR_ASSERTLESS + 1 )); FR_T_ASSERTLESS=$(( FR_T_ASSERTLESS + 1 ))
          fr_warn "KILLED WITH NO ASSERTION ATTACHED (signal=$f7 — the oracle exited non-zero without printing a FAIL: line, so nothing was observed asserting): $f3"
        fi ;;
      'CONTROL|PASS|'*) FR_CONTROLS_OK=$(( FR_CONTROLS_OK + 1 )) ;;
      'CONTROL|FAIL|'*)
        FR_CONTROLS_FAILED=$(( FR_CONTROLS_FAILED + 1 ))
        # Its own split: a CONTROL record is 7 fields and a MUTANT record is 9,
        # so the shared positional read above lands `signal` and `ms` in the
        # wrong variables. Contorting the record to line up with MUTANT's
        # layout would be the other way to do this, and would make the grammar
        # answer to the parser instead of the other way round.
        IFS='|' read -r _ _ c_target c_oracle _ c_sig c_ms <<< "$line"
        # Named at the moment it happens, not only in the summary: this is the
        # line that says every kill around it is suspect.
        fr_err "CONTROL FAILED — the PRISTINE oracle went red under this run's own load (signal=${c_sig:-none}, $(fr_secs "$c_ms")): $c_target via $c_oracle. Kills recorded near it cannot be trusted." ;;
      'NOTE|control-output|'*)
        # Echoed to stderr as well as stdout: the CONTROL FAILED error above it
        # is on stderr, and a reader following the failure must not have to
        # cross streams to find out what went red.
        IFS='|' read -r _ _ _ co_line <<< "$line"
        fr_warn "  control output: $co_line" ;;
      'NOTE|write-failed|'*) FR_BROKEN=$(( FR_BROKEN + 1 )) ;;
      'NOTE|foreign-timeout-flag|'*)
        # Never silent. This is the event that used to arrive as an UNPROVEN
        # mutant and take a survivor out of the ledger's reach with it.
        fr_warn "FOREIGN TIMEOUT FLAG — $f4. Not scored as a timeout: $f3" ;;
    esac
  done < "$res"
  rm -f "$res"
}

fr_wait_for_slot() {   # block until at least one slot is free
  local p rc reaped harvested=0
  local -a ended=()
  while (( harvested == 0 )); do
    (( ${#FR_PID_SLOT[@]} > 0 )) || return 0
    # `-p` names the pid that finished, so this loop learns WHICH worker ended
    # and keeps the status `wait` already returned. Bare `wait -n` threw the
    # status away and then identified the finished worker with `kill -0`, which
    # answers "does some process hold this pid" — not "is this still my
    # worker". Both halves of that mattered: the discarded status is the one
    # fact that says why a worker produced nothing, and on a host that recycles
    # pids quickly the `kill -0` answer can be about somebody else's process.
    # `wait -n -p` is bash 5.0; bash-floor.sh declares 5.1.
    reaped=""
    wait -n -p reaped 2>/dev/null
    rc=$?
    # `-p` DOES NOT SET ITS VARIABLE AT THE DECLARED FLOOR. Measured by the
    # bash-floor CI job: the same commit passes this file's §11d wiring
    # assertion on bash 5.2 (ubuntu:24.04) and fails it on 5.1 (ubuntu:22.04)
    # with "exit status not captured". The reason inside bash is not established
    # here and this comment will not invent one — what matters is that the
    # status must still be attributable at 5.1, which bash-floor.sh declares.
    #
    # `wait -n` returned A status; the scan says WHICH workers ended. When
    # exactly one did, those are the same worker and the attribution is sound.
    # When two ended in the same instant it is not, so nothing is attributed and
    # fr_exit_cause says "not captured" rather than picking one.
    if [[ -z "$reaped" ]]; then
      ended=()
      for p in "${!FR_PID_SLOT[@]}"; do
        kill -0 "$p" 2>/dev/null || ended+=("$p")
      done
      (( ${#ended[@]} == 1 )) && reaped="${ended[0]}"
    fi
    if [[ -n "$reaped" && -n "${FR_PID_SLOT[$reaped]:-}" ]]; then
      # 127 IS `wait`'s OWN "there are no unwaited-for children", not a status
      # any child exited with. At the declared floor, bash 5.1 returns it
      # intermittently for a child that has ALREADY terminated — measured, not
      # inferred: the bash-floor CI job reported `it exited 127` for a worker
      # the test had SIGKILLed, and the identical job passed on re-run.
      # Recording it as the worker's exit status makes fr_exit_cause state a
      # number nothing measured, which is the one thing this whole channel
      # exists to stop.
      if (( rc == 127 )); then FR_PID_STATUS["$reaped"]=""; else FR_PID_STATUS["$reaped"]="$rc"; fi
      fr_harvest "$reaped"
      harvested=$(( harvested + 1 ))
      continue
    fi
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
  local i n target oracle mutants total=0 t_run t_target skipped_n
  local n_mut ctl_at ctl_n ci ctl_pos cslot cres
  local seq op lineno sha text slot res rc=0

  while (( $# > 0 )); do
    case "$1" in
      --target) FR_TARGET="${2:-}"; shift 2 || return 2 ;;
      --jobs) FR_JOBS="${2:-}"; shift 2 || return 2 ;;
      --controls) FR_CONTROLS="${2:-}"; shift 2 || return 2 ;;
      --max-unproven-pct) FR_MAX_UNPROVEN_PCT="${2:-}"; shift 2 || return 2 ;;
      --max-assertless) FR_MAX_ASSERTLESS="${2:-}"; shift 2 || return 2 ;;
      --timeout) FR_TIMEOUT="${2:-}"; shift 2 || return 2 ;;
      --operators) FALSIFY_OPERATORS="${2:-}"; export FALSIFY_OPERATORS; shift 2 || return 2 ;;
      -h|--help) fr_usage; return 0 ;;
      *) fr_err "unknown option: $1"; fr_usage >&2; return 2 ;;
    esac
  done
  if [[ "$FR_JOBS" == "auto" ]]; then
    local _host _quota
    _host="$(fr_host_cpus)"; _quota="$(fr_quota_cpus)"
    FR_JOBS="$(fr_cpu_budget)"
    # Said out loud, with BOTH numbers: "jobs=8" alone leaves a reader unable to
    # tell a quota from a small machine, and the gap is the whole finding.
    # Branch on whether a quota EXISTS, never on whether it currently BINDS.
    # A quota equal to the machine's CPU count is still a quota, and saying "no
    # cgroup CPU quota in effect" there is a lie that costs a reader the one
    # fact they came for. Caught by a 2-CPU CI runner against a planted 2-CPU
    # quota, where `quota < host` is false and the message said the opposite of
    # the truth.
    if [[ -n "$_quota" ]]; then
      fr_warn "--jobs auto -> $FR_JOBS (the OS reports $_host CPU(s), the cgroup quota allows $_quota; nproc does not see the quota)"
    else
      fr_warn "--jobs auto -> $FR_JOBS (the OS reports $_host CPU(s), no cgroup CPU quota in effect)"
    fi
  fi
  if [[ ! "$FR_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    fr_err "--jobs must be a positive integer or 'auto', got '${FR_JOBS}'"; return 2
  fi
  if [[ ! "$FR_CONTROLS" =~ ^[0-9]+$ ]]; then
    fr_err "--controls must be a non-negative integer, got '${FR_CONTROLS}'"; return 2
  fi
  if [[ -n "$FR_MAX_UNPROVEN_PCT" && ! "$FR_MAX_UNPROVEN_PCT" =~ ^[0-9]+$ ]]; then
    fr_err "--max-unproven-pct must be a non-negative integer, got '${FR_MAX_UNPROVEN_PCT}'"; return 2
  fi
  if [[ -n "$FR_MAX_ASSERTLESS" && ! "$FR_MAX_ASSERTLESS" =~ ^[0-9]+$ ]]; then
    fr_err "--max-assertless must be a non-negative integer, got '${FR_MAX_ASSERTLESS}'"; return 2
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
    FR_KILLED=0; FR_SURVIVED=0; FR_UNPROVEN=0; FR_TIMEOUTS=0; FR_ASSERTLESS=0
    t_target="$(fr_now_us)"

    # ── the pristine baseline ───────────────────────────────────────────────
    # An oracle that is not green on the UNMUTATED tree cannot distinguish
    # anything: every mutant would be reported KILLED. rc=2 is named for what
    # it is, because that is what a misspelled oracle looks like.
    falsify_run_oracle "$(fr_slot_tree 0)" "$oracle" "$FR_OUT/baseline.log" "$FR_TIMEOUT" "baseline"
    falsify_verdict "$FALSIFY_RC" "$FR_OUT/baseline.log" "$FALSIFY_TIMED_OUT"
    if [[ "$FALSIFY_VERDICT" != "SURVIVED" ]]; then
      if (( FALSIFY_RC == 2 )); then
        fr_err "oracle '$oracle' matched NO test (run-all.sh exit 2) — a misspelled oracle name would report every mutant of $target as KILLED. Skipping $target."
      else
        fr_err "oracle '$oracle' is not green on the PRISTINE tree (rc=$FALSIFY_RC, signal=$FALSIFY_SIGNAL) — every mutant of $target would be reported KILLED. Skipping $target."
      fi
      sed 's/^/    /' "$FR_OUT/baseline.log" | tail -20 >&2
      # ON STDOUT, beside MUTANT/TARGET/TOTAL, because stderr is where this
      # event already was and stderr is what a summary reader filters out. The
      # count is what leaves the corpus: every mutant of this target, none of
      # which will be attempted.
      skipped_n="$(grep -c . "$mutants" 2>/dev/null || printf 0)"
      printf 'SKIPPED|%s|%s|%s|%s\n' "$target" "$oracle" "$skipped_n" \
        "$( (( FALSIFY_RC == 2 )) && printf 'no-test-matched' || printf 'baseline-not-green' )"
      FR_SKIPPED_TARGETS=$(( FR_SKIPPED_TARGETS + 1 ))
      FR_SKIPPED_MUTANTS=$(( FR_SKIPPED_MUTANTS + skipped_n ))
      rc=1
      continue
    fi
    printf 'BASELINE|%s|%s|PASS|%s\n' "$target" "$oracle" "$FALSIFY_MS"

    # ── where the control runs go ───────────────────────────────────────────
    # Evenly through the target's sequence, so they sample the run early, in the
    # middle and late rather than clustering where the machine happens to be
    # quiet. A target with fewer mutants than controls simply gets fewer: the
    # positions are computed from its own count, never from a fixed stride.
    n_mut="$(grep -c . "$mutants" 2>/dev/null || printf 0)"
    ctl_at=""
    if (( FR_CONTROLS > 0 && n_mut > 0 )); then
      for (( ci = 1; ci <= FR_CONTROLS; ci++ )); do
        ctl_pos=$(( ci * n_mut / (FR_CONTROLS + 1) ))
        (( ctl_pos < 1 )) && ctl_pos=1
        ctl_at="$ctl_at $ctl_pos "
      done
    fi
    ctl_n=0

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

      # A control goes into a slot of its own, right after the mutant at this
      # position, so it competes with the same workers rather than waiting for
      # a gap. The slot's tree is pristine here: fr_run_mutant restores the
      # target file before it returns, and re-seeds if anything else moved.
      if [[ "$ctl_at" == *" $seq "* ]]; then
        ctl_n=$(( ctl_n + 1 ))
        while (( ${#FR_FREE_SLOTS[@]} == 0 )); do fr_wait_for_slot; done
        cslot="${FR_FREE_SLOTS[0]}"
        FR_FREE_SLOTS=("${FR_FREE_SLOTS[@]:1}")
        cres="$FR_OUT/control.$cslot.$ctl_n"
        rm -f "$cres"
        fr_run_control "$cslot" "$target" "$oracle" "$ctl_n" "$cres" &
        FR_PID_SLOT["$!"]="$cslot"
        FR_PID_RESULT["$!"]="$cres"
      fi
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

  # ── HOW MANY OF THOSE KILLS CAME WITH AN ASSERTION ──────────────────────────
  # Always emitted, even at zero, and on its own line rather than as a tenth
  # TOTAL field: the ratchet, check-ledger.sh and verify-on-host.sh all parse
  # TOTAL positionally, and a number nobody can read is the state this counter
  # exists to end. `run.sh` has recorded which channel produced every kill since
  # the tier was written and nothing consumed it, which is how three separate
  # false-kill mechanisms each had to be found by hand, on one mutant, by
  # somebody looking closely (F35, F30, F43).
  #
  # Zero is the honest reading today, in both repos: all 262 kills are
  # `exit+failline`. That is precisely when to start reporting it — the number
  # can only go up from here, and the state with nothing left to look at is the
  # state in which nobody looks.
  printf 'ASSERTLESS|%s|%s\n' "$FR_T_ASSERTLESS" "$FR_T_KILLED"

  # ── HOW MUCH OF THE CORPUS WAS NEVER ATTEMPTED ──────────────────────────────
  # Always emitted, even at zero, and on its own line for the same reason
  # ASSERTLESS is: TOTAL is parsed POSITIONALLY by check-ledger.sh,
  # verify-on-host.sh and this repo's own tests, so it does not grow a tenth
  # field. And zero is exactly when to start printing it — the number can only
  # go up, and the state with nothing to look at is the state in which nobody
  # looks.
  #
  # TOTAL's first field is the targets fr_load_targets ACCEPTED and its second
  # is the verdicts PRODUCED. On macOS at --jobs 32 --timeout 5 that read
  # `TOTAL|9|106|…` for a run in which four targets and 158 mutants were never
  # attempted at all, and no line said so (backlog F54). This one does.
  printf 'UNATTEMPTED|%s|%s|%s\n' "$FR_SKIPPED_TARGETS" "$FR_SKIPPED_MUTANTS" "$total"

  # ── WAS THE ORACLE GREEN UNDER THIS RUN'S OWN LOAD ──────────────────────────
  # Always emitted, at zero-failed like ASSERTLESS and UNATTEMPTED. A run with
  # no controls says so with a zero in the first field, which is a different
  # statement from "controls ran and passed" and must not read the same.
  printf 'CONTROLS|%s|%s\n' "$(( FR_CONTROLS_OK + FR_CONTROLS_FAILED ))" "$FR_CONTROLS_FAILED"
  if (( FR_CONTROLS_FAILED > 0 )); then
    fr_err "$FR_CONTROLS_FAILED of $(( FR_CONTROLS_OK + FR_CONTROLS_FAILED )) control run(s) FAILED: the PRISTINE oracle went red under this run's own load, so a mutant scored KILLED here may have been killed by the machine rather than by the damage. Re-run with fewer --jobs before trusting the kill count."
    rc=1
  fi

  if (( FR_BROKEN > 0 )); then
    fr_err "$FR_BROKEN mutant(s) produced no verdict — they are NOT counted as kills"
    rc=1
  fi
  # ── HOW MUCH THIS RUN ACTUALLY MEASURED ──────────────────────────────────────
  # An UNPROVEN mutant is not owed a ledger entry — deliberately, because the
  # timeout that produced it is a property of the MACHINE and a ratchet that
  # cannot be satisfied everywhere at once is not a ratchet (backlog F27). The
  # cost of that exemption is that an UNBOUNDED number of mutants can drop out
  # of the measured set with nothing failing: a run reporting 210 killed where
  # the reference reports 223 scores exactly as green.
  #
  # So the fraction is bounded HERE, where the run's own trustworthiness is
  # already judged, and only when a caller asks for it. Opt-in, because a
  # developer host legitimately times out and failing there would be the same
  # everywhere-at-once mistake; the REFERENCE environment (CI) is what passes
  # a value.
  if [[ -n "$FR_MAX_UNPROVEN_PCT" ]] && (( done_total > 0 )); then
    local unp_pct=$(( FR_T_UNPROVEN * 100 / done_total ))
    if (( unp_pct > FR_MAX_UNPROVEN_PCT )); then
      fr_err "$FR_T_UNPROVEN of $done_total mutant(s) (${unp_pct}%) produced no verdict, over the --max-unproven-pct ${FR_MAX_UNPROVEN_PCT} budget — this run measured materially less than it appears to. Check --jobs against the CPU quota (try --jobs auto) and --timeout before trusting the kill count"
      rc=1
    fi
  fi
  # Bounded only when a caller asks, exactly like --max-unproven-pct above and
  # for the mirror of its reason. An assertless kill is a property of the
  # ORACLE'S CODE, not of the machine — a timeout, a signal death and a
  # collapsed scaffold are all UNPROVEN before they ever reach this counter —
  # so unlike the unproven fraction it IS satisfiable everywhere at once, and
  # CI passes 0.
  #
  # MEASURED, not merely argued (backlog F51). The claim was challenged when this
  # counter read 2 on one macOS run and 0 on every other, which is the shape of a
  # machine-dependent number. `--jobs 32 --timeout 5` in the dev container — four
  # workers per CPU against a five-second clock — induced 58 timeouts across the
  # 264-mutant corpus, 29 of them UNPROVEN and 29 killed `timeout+failline`, and
  # left this counter at ZERO. Machine pressure landed in the timeout channel
  # exactly as the argument above says it must. The one non-zero reading came
  # from a run riddled with F50's forged timeout flags, where a stale watchdog
  # was truncating OTHER workers' oracles mid-run — an oracle cut short exits
  # non-zero having printed no FAIL: line, which is precisely an assertless kill.
  # It has read 0 on both platforms since that was fixed.
  #
  # It stays opt-in anyway: a test whose contract genuinely IS its
  # exit status would be a legitimate non-zero here, and discovering that on
  # somebody's laptop mid-task is not how it should be raised. The fix for a
  # real one is to make the oracle print the FAIL: line it owes; raising this
  # bound is the deliberate alternative, not the quiet one.
  if [[ -n "$FR_MAX_ASSERTLESS" ]] && (( FR_T_ASSERTLESS > FR_MAX_ASSERTLESS )); then
    fr_err "$FR_T_ASSERTLESS of $FR_T_KILLED kill(s) arrived with NO ASSERTION ATTACHED, over the --max-assertless ${FR_MAX_ASSERTLESS} budget — each one is an oracle that exited non-zero without printing a FAIL: line, so the mutation was not observed being noticed. Grep this run for 'KILLED WITH NO ASSERTION ATTACHED' for the list"
    rc=1
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  falsify_main "$@"
  exit $?
fi
