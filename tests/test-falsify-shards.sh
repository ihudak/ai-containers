#!/usr/bin/env bash
# tests/test-falsify-shards.sh — CI's falsify shards cover the corpus exactly
# once.
#
# hermetic-checks.yml runs the falsify tier as a matrix: one shard per entry
# of `shard: [...]`, each choosing its targets in the `case` of the step
# "Run the falsify mutation corpus". Each shard scores the survivor ledger
# against its own run only, so a target in no shard is never measured and its
# ledger entries are skipped, saying so, while every check stays green. And a
# target in two shards doubles the time the split exists to save.
#
# Checked by EFFECT, not by reading the step's text: the step itself is run,
# once per matrix entry, with the job's FALSIFY_SPLIT_TARGET, against a
# tests/falsify/run.sh that hands its arguments to the real runner with
# --list-targets, so what is compared is the targets the real runner chose.
# Their union must be the unfiltered corpus and no target may appear twice.
# The check is then run against damaged copies of the workflow (a shard
# dropped from the matrix, a case arm that selects the same half twice) and
# must fail on each, so it is seen failing.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
WF="$REPO_DIR/.github/workflows/hermetic-checks.yml"
REAL_RUN="$TESTS_DIR/falsify/run.sh"
STEP='Run the falsify mutation corpus'

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$(( fails + 1 )); }

TMP="$(mktemp -d)"
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# The falsify job's lines, from its key to the next job key.
falsify_job() {  # $1=workflow
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob = ($0 ~ /^  falsify:/); next }
    /^[^ #]/ { injob = 0 }
    injob { print }
  ' "$1"
}

# The run: block of the named step, its indentation removed.
step_run() {  # $1=workflow  $2=step name
  falsify_job "$1" | awk -v want="- name: $2" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    !instep {
      t = $0; sub(/^ +/, "", t)
      if (t == want) { instep = 1; stepind = indent($0) }
      next
    }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if (indent($0) <= runind) exit
      if (!body) body = indent($0)
      print substr($0, body + 1)
      next
    }
    /^ *- / && indent($0) == stepind { exit }
    /^ *run: *[|] *$/ { inrun = 1; runind = indent($0) }
  '
}

matrix_shards() {  # $1=workflow → one shard per line
  falsify_job "$1" | awk '
    /^ +shard: *\[/ {
      s = $0; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
      n = split(s, a, ",")
      for (i = 1; i <= n; i++) { v = a[i]; gsub(/^ +| +$/, "", v); if (v != "") print v }
    }
  '
}

split_target() {  # $1=workflow
  falsify_job "$1" | awk '/^ +FALSIFY_SPLIT_TARGET:/ { v = $0; sub(/^[^:]*: */, "", v); sub(/ +$/, "", v); print v }'
}

# rc 0 when the shards of workflow $1 cover the corpus exactly once.
shards_cover() {  # $1=workflow  $2=label
  local wf="$1" label="$2" sh shards=() split body d out rc all expected dup
  mapfile -t shards < <(matrix_shards "$wf")
  split="$(split_target "$wf")"
  body="$(step_run "$wf" "$STEP")"
  if (( ${#shards[@]} < 2 )); then
    echo "  [$label] the matrix names ${#shards[@]} shard(s): ${shards[*]:-none}"; return 1
  fi
  if [[ -z "$split" || -z "$body" ]]; then
    echo "  [$label] could not read FALSIFY_SPLIT_TARGET ('$split') or the step's run: block"; return 1
  fi
  d="$TMP/$label"; mkdir -p "$d/tests/falsify" "$d/rt"
  printf '#!/usr/bin/env bash\nexec bash %q --list-targets "$@"\n' "$REAL_RUN" > "$d/tests/falsify/run.sh"
  printf '%s\n' "$body" > "$d/step.sh"
  : > "$d/all"
  for sh in "${shards[@]}"; do
    out="$( cd "$d" && RUNNER_TEMP="$d/rt" SHARD="$sh" FALSIFY_SPLIT_TARGET="$split" \
            bash --noprofile --norc -eo pipefail step.sh 2>&1 )"; rc=$?
    if (( rc != 0 )); then
      echo "  [$label] shard '$sh' exited $rc: $(tail -n 3 <<< "$out")"; return 1
    fi
    if [[ ! -s "$d/rt/falsify-run.txt" ]]; then
      echo "  [$label] shard '$sh' selected no target"; return 1
    fi
    cat "$d/rt/falsify-run.txt" >> "$d/all"
  done
  expected="$(bash "$REAL_RUN" --list-targets 2>/dev/null | sort)"
  all="$(sort -u "$d/all")"
  dup="$(sort "$d/all" | uniq -d)"
  if [[ -n "$dup" ]]; then
    echo "  [$label] in more than one shard: $(tr '\n' ' ' <<< "$dup")"; return 1
  fi
  if [[ "$all" != "$expected" ]]; then
    echo "  [$label] in no shard: $(comm -13 <(printf '%s\n' "$all") <(printf '%s\n' "$expected") | tr '\n' ' ')"; return 1
  fi
  echo "  [$label] ${#shards[@]} shards, $(grep -c . <<< "$all") targets, each once"
  return 0
}

# Premise: the unfiltered list is the corpus, not empty.
n_all="$(bash "$REAL_RUN" --list-targets 2>/dev/null | grep -c .)"
if (( n_all >= 2 )); then pass "run.sh --list-targets lists the corpus ($n_all targets)"
else fail "run.sh --list-targets lists the corpus (got $n_all)"; fi

msg="$(shards_cover "$WF" real)"
if [[ $? -eq 0 ]]; then pass "the falsify shards in hermetic-checks.yml cover the corpus exactly once"
else fail "the falsify shards in hermetic-checks.yml cover the corpus exactly once"; fi
printf '%s\n' "$msg"

# Seen failing: a shard dropped from the matrix leaves its half unmeasured.
sed 's/^\( *shard: *\[\)[^,]*, */\1/' "$WF" > "$TMP/drop.yml"
if ! cmp -s "$WF" "$TMP/drop.yml" && ! msg="$(shards_cover "$TMP/drop.yml" drop)"; then
  pass "a matrix with a shard dropped is caught"
else
  fail "a matrix with a shard dropped is caught: $msg"
fi

# Seen failing: an arm that selects the same half as another covers it twice
# and the other half never.
sed 's/select=(--exclude-target /select=(--target /' "$WF" > "$TMP/twice.yml"
if ! cmp -s "$WF" "$TMP/twice.yml" && ! msg="$(shards_cover "$TMP/twice.yml" twice)"; then
  pass "two shards selecting the same targets are caught"
else
  fail "two shards selecting the same targets are caught: $msg"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$(( fails > 0 ))"
