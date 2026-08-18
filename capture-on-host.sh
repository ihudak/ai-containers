#!/usr/bin/env bash
# capture-on-host.sh — run the falsify mutation tier with the scaffolding
# capture ARMED, and record the machine state next to the result.
#
#   bash ./capture-on-host.sh                      # whole corpus
#   bash ./capture-on-host.sh --target tools-lib.sh --jobs 6 --timeout 300
#
# Every argument is forwarded verbatim to tests/falsify/run.sh.
#
# ── WHY THIS EXISTS, AND WHY IT IS NOT PART OF verify-on-host.sh ──────────────
# Phase 6 already runs this tier. What it cannot do is say WHY an oracle
# collapsed, because the evidence does not survive the run: tests/falsify/run.sh
# writes each oracle's output to $FR_OUT/w<slot>.log, OVERWRITES it for the next
# mutant in that slot, and deletes the whole scratch tree when it finishes. So a
# collapse that happens once in a corpus leaves a verdict and nothing else.
#
# This script sets SCAFFOLD_CAPTURE_LOG, which tests/test-tools-d.sh appends its
# SCAFFOLD-CAPTURE blocks to — a path OUTSIDE the scratch tree, so they outlive
# it. It also samples free space and APFS local-snapshot count for the duration,
# whether or not anything fails.
#
# THAT SAMPLING IS NOT PADDING. The named hypothesis is that APFS local Time
# Machine snapshots pin space `df` still reports as free — the documented macOS
# "full disk with free space" mode — which fits the measurement that started
# this: `df` reads healthy while writes come back EMPTY. A capture that only
# speaks when the fault fires can confirm that hypothesis but never refute it;
# a timeline taken on every run can do both, because a green run that shows
# snapshots pinning space at the same moment is most of the answer.
#
# It is a separate entry point rather than a flag on verify-on-host.sh because
# that script's phase contract and its exit-code ledger are pinned by
# tests/test-verify-exit-code.sh, and this changes neither: it measures the same
# tier under an extra observer. Phase 0's Docker gate is also skipped
# deliberately — nothing here needs a daemon, and requiring one would stop this
# running at exactly the times it is most wanted.
set -uo pipefail

REPO="${REPO:-$PWD}"
LOG_PREFIX="[host-capture]"
say() { printf '\n%s %s\n' "$LOG_PREFIX" "$*"; }
sub() { printf '%s   %s\n' "$LOG_PREFIX" "$*"; }

[[ -f "$REPO/build.sh" && -f "$REPO/sandbox.conf" ]] || {
  echo "ERROR: run this from an ai-containers checkout (or set REPO=/path/to/checkout)." >&2
  echo "       In mgd-ai-containers the engine lives in base/ — run it from there." >&2
  exit 2
}

# shellcheck source=SCRIPTDIR/bash-floor.sh
source "$REPO/bash-floor.sh"

# Layout-tolerant, for the same reason verify-on-host.sh is: upstream keeps
# tests/ beside build.sh, mgd keeps the engine in base/ and tests/ one level up.
TESTS_DIR="$REPO/tests"
[[ -d "$TESTS_DIR" ]] || TESTS_DIR="$REPO/../tests"
FALSIFY_DIR="$TESTS_DIR/falsify"
[[ -f "$FALSIFY_DIR/run.sh" ]] || { echo "ERROR: no $FALSIFY_DIR/run.sh" >&2; exit 2; }

# Output OUTSIDE the repo by default, so a capture run never shows up in
# `git status` and never needs a .gitignore entry. Override with CAPTURE_OUT.
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${CAPTURE_OUT:-${TMPDIR:-/tmp}/ai-containers-capture/$STAMP}"
mkdir -p "$OUT" || exit 1

SCAFFOLD_CAPTURE_LOG="$OUT/scaffold-captures.log"
export SCAFFOLD_CAPTURE_LOG
: > "$SCAFFOLD_CAPTURE_LOG"

say "capture run $STAMP"
sub "output:      $OUT"
sub "capture log: $SCAFFOLD_CAPTURE_LOG"
sub "bash:        $(bash --version | head -1)"

# One sample per 30 s: free space as `df` sees it, and how many APFS local
# snapshots exist. `tmutil` is macOS-only and absent in the container and on
# Linux, where the count is simply reported as n/a.
snapshot_count() {
  command -v tmutil >/dev/null 2>&1 || { printf 'n/a'; return 0; }
  tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine'
}
( while :; do
    printf '%s df_tmp=%s df_root=%s snapshots=%s\n' \
      "$(date '+%H:%M:%S')" \
      "$(df -k "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2{print $4}')" \
      "$(df -k / 2>/dev/null | awk 'NR==2{print $4}')" \
      "$(snapshot_count)"
    sleep 30
  done > "$OUT/timeline.log" ) &
sampler=$!
# shellcheck disable=SC2064  # $sampler must expand NOW, not when the trap fires
trap "kill $sampler 2>/dev/null" EXIT

say "running the corpus (args: ${*:-<none>})"
bash "$FALSIFY_DIR/run.sh" "$@" > "$OUT/corpus.out" 2> "$OUT/corpus.err"
corpus_rc=$?
sub "corpus exit: $corpus_rc"
grep -E '^(TARGET|TOTAL)\|' "$OUT/corpus.out" | while IFS= read -r l; do sub "$l"; done

say "survivor-ledger ratchet"
bash "$FALSIFY_DIR/check-ledger.sh" --run-output "$OUT/corpus.out" \
  --ledger "$FALSIFY_DIR/survivors.txt" > "$OUT/ledger.log" 2>&1
ledger_rc=$?
sub "ledger exit: $ledger_rc"
tail -1 "$OUT/ledger.log" | while IFS= read -r l; do sub "$l"; done

kill "$sampler" 2>/dev/null
trap - EXIT

say "machine state across the run"
awk '{gsub(/[a-z_]+=/,"")}
     NR==1{mt=$2;xt=$2;ms=$4;xs=$4}
     {if($2<mt)mt=$2; if($2>xt)xt=$2; if($4!="n/a"){if(ms=="n/a"||$4<ms)ms=$4; if(xs=="n/a"||$4>xs)xs=$4}}
     END{if(NR)printf "samples=%s  df(TMPDIR) min=%s max=%s KB  local snapshots min=%s max=%s\n", NR,mt,xt,ms,xs}' \
  "$OUT/timeline.log" | while IFS= read -r l; do sub "$l"; done

# `grep -c` PRINTS 0 and EXITS 1 when there is no match, so a `|| printf 0`
# fallback appends a second line and the count becomes "0\n0" — which is not
# "0", and the branch below then fires on every clean run. Take the count and
# ignore the status.
captures="$(grep -c '^SCAFFOLD-CAPTURE:' "$SCAFFOLD_CAPTURE_LOG" 2>/dev/null)"
captures="${captures:-0}"
sub "SCAFFOLD-CAPTURE blocks: $captures"
if (( captures > 0 )); then
  say "AN ORACLE COULD NOT SET ITSELF UP — this is what the run was for"
  sed 's/^/  /' "$SCAFFOLD_CAPTURE_LOG" | head -60
  sub "full capture: $SCAFFOLD_CAPTURE_LOG"
fi

say "DONE. corpus=$corpus_rc ledger=$ledger_rc captures=$captures"
sub "everything under: $OUT"
# The corpus and the ratchet are the verdict; the capture is evidence, never a
# pass/fail of its own.
[[ "$corpus_rc" -eq 0 && "$ledger_rc" -eq 0 ]] || exit 1
