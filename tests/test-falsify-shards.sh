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
# once per matrix entry, with the job's FALSIFY_* variables, against a
# tests/falsify/run.sh that hands its arguments to the real runner with
# --list-targets, so what is compared is the targets the real runner chose.
# Their union must be the unfiltered corpus and no target may appear twice,
# except as slices (`run.sh --slice K/N` lists `<target> K/N`): the shards
# that run slices of one target must name one N and each K from 1 to N once.
# The check is then run against damaged copies of the workflow (a shard
# dropped from the matrix, a case arm that selects the same half twice, a
# slice no shard runs, an arm that runs every slice whole) and must fail on
# each, so it is seen failing.
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

# Every FALSIFY_* variable of the job's env:, as NAME=value, one per line: the
# step reads each target that has a shard of its own from one of them.
split_env() {  # $1=workflow
  falsify_job "$1" | awk '/^ +FALSIFY_[A-Z_]+:/ { n = $0; sub(/^ +/, "", n); v = n; sub(/:.*$/, "", n); sub(/^[^:]*: */, "", v); sub(/ +$/, "", v); print n "=" v }'
}

# rc 0 when the shards of workflow $1 cover the corpus exactly once.
shards_cover() {  # $1=workflow  $2=label
  local wf="$1" label="$2" sh shards=() split body d out rc all expected dup envs=()
  mapfile -t shards < <(matrix_shards "$wf")
  mapfile -t envs < <(split_env "$wf")
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
    # The deep shard re-runs a few targets under extra operators; it is not a
    # slice of the corpus, so it is checked on its own below, not counted here.
    [[ "$sh" == deep ]] && continue
    out="$( cd "$d" && env RUNNER_TEMP="$d/rt" SHARD="$sh" "${envs[@]}" \
            bash --noprofile --norc -eo pipefail step.sh 2>&1 )"; rc=$?
    if (( rc != 0 )); then
      echo "  [$label] shard '$sh' exited $rc: $(tail -n 3 <<< "$out")"; return 1
    fi
    if [[ ! -s "$d/rt/falsify-run.txt" ]]; then
      echo "  [$label] shard '$sh' selected no target"; return 1
    fi
    cat "$d/rt/falsify-run.txt" >> "$d/all"
  done
  # Slices: every `<target> K/N` line of one target names the same N, and
  # its Ks are 1..N, each once. The target then counts once.
  local sliced
  sliced="$(awk '
    NF == 2 {
      split($2, kn, "/"); t = $1
      if (t in n && n[t] != kn[2]) { printf "%s is cut into %s and %s slices\n", t, n[t], kn[2]; bad = 1 }
      n[t] = kn[2]
      if (++seen[t, kn[1]] > 1) { printf "%s slice %s runs twice\n", t, $2; bad = 1 }
      if (kn[1] < 1 || kn[1] > kn[2]) { printf "%s has slice %s\n", t, $2; bad = 1 }
    }
    END {
      for (t in n) for (k = 1; k <= n[t]; k++) if (!((t, k) in seen)) { printf "%s slice %d/%d is in no shard\n", t, k, n[t]; bad = 1 }
      exit bad
    }' "$d/all")" || { echo "  [$label] $(tr '\n' ';' <<< "$sliced")"; return 1; }
  awk 'NF == 2 { if (!($1 in s)) { s[$1] = 1; print $1 }; next } { print }' "$d/all" > "$d/all.t"
  mv "$d/all.t" "$d/all"
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

# rc 0 when workflow $1's `deep` shard runs exactly the deep pass: the targets
# `run.sh --deep` selects, which are deep.conf's.
deep_shard_ok() {  # $1=workflow  $2=label
  local wf="$1" label="$2" body d out rc got want envs=()
  body="$(step_run "$wf" "$STEP")"
  mapfile -t envs < <(split_env "$wf")
  d="$TMP/$label"; mkdir -p "$d/tests/falsify" "$d/rt"
  printf '#!/usr/bin/env bash\nexec bash %q --list-targets "$@"\n' "$REAL_RUN" > "$d/tests/falsify/run.sh"
  printf '%s\n' "$body" > "$d/step.sh"
  out="$( cd "$d" && env RUNNER_TEMP="$d/rt" SHARD=deep "${envs[@]}" \
          bash --noprofile --norc -eo pipefail step.sh 2>&1 )"; rc=$?
  if (( rc != 0 )); then echo "  [$label] shard 'deep' exited $rc: $(tail -n 3 <<< "$out")"; return 1; fi
  got="$(sort "$d/rt/falsify-run.txt" 2>/dev/null)"
  want="$(bash "$REAL_RUN" --deep --list-targets 2>/dev/null | sort)"
  if [[ -z "$want" || "$got" != "$want" ]]; then
    echo "  [$label] the deep shard selected '$(tr '\n' ' ' <<< "$got")', run.sh --deep selects '$(tr '\n' ' ' <<< "$want")'"; return 1
  fi
  echo "  [$label] the deep shard runs the $(grep -c . <<< "$got") deep target(s)"
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

grep -qE '^ +shard: *\[.*\bdeep\b' <(falsify_job "$WF") \
  && pass "the matrix has the deep shard" || fail "the matrix has the deep shard"
msg="$(deep_shard_ok "$WF" deep-real)"
if [[ $? -eq 0 ]]; then pass "the deep shard runs run.sh --deep's targets"
else fail "the deep shard runs run.sh --deep's targets"; fi
printf '%s\n' "$msg"
# Seen failing: a deep arm that runs the default pass instead.
sed 's/deep) select=(--deep) ;;/deep) select=(--target "$FALSIFY_SPLIT_TARGET") ;;/' "$WF" > "$TMP/deepwrong.yml"
if cmp -s "$WF" "$TMP/deepwrong.yml"; then
  fail "a deep arm that does not run --deep is caught: the damage no longer applies to the workflow"
elif msg="$(deep_shard_ok "$TMP/deepwrong.yml" deep-wrong)"; then
  fail "a deep arm that does not run --deep is caught: $msg"
else
  pass "a deep arm that does not run --deep is caught"
fi

# Seen failing: each damaged copy of the workflow below must be caught. A
# damage whose sed no longer changes the workflow tests nothing, and says so,
# rather than passing or printing the message of the damage before it.
caught() {  # $1=label  $2=sed program  $3=what must be caught
  local label="$1" prog="$2" what="$3" out
  sed "$prog" "$WF" > "$TMP/$label.yml"
  if cmp -s "$WF" "$TMP/$label.yml"; then
    fail "$what: the damage no longer applies to the workflow ($prog)"
  elif out="$(shards_cover "$TMP/$label.yml" "$label")"; then
    fail "$what: $out"
  else
    pass "$what"
  fi
}
# A shard dropped from the matrix leaves its part unmeasured.
caught drop 's/^\( *shard: *\[\)[^,]*, */\1/' "a matrix with a shard dropped is caught"
# An arm that selects the same targets as another covers them twice and its
# own never.
caught twice 's/select=(--exclude-target /select=(--target /' "two shards selecting the same targets are caught"
# A slice of project.sh dropped from the matrix is never run.
caught slicedrop 's/ project-3,//' "a matrix missing a slice of project.sh is caught"
# FALSIFY_PROJECT_SLICES raised without a shard for the new slice, which no
# job would run.
caught slicecount 's/FALSIFY_PROJECT_SLICES: [0-9]*/FALSIFY_PROJECT_SLICES: 7/' "a slice count the matrix does not match is caught"
# A rest arm that forgets one of the targets with a shard of its own runs
# that target twice.
caught forgot 's/ --exclude-target "$FALSIFY_PROJECT_TARGET"//' "a rest shard that does not leave out every split target is caught"
# repo-git-reset.sh and rest run in slices too (bugs review TST-43): the same
# damages to theirs, and a rest arm that runs every slice whole.
caught rgrdrop 's/ repo-git-reset-2,//' "a matrix missing a slice of repo-git-reset.sh is caught"
caught rgrcount 's/FALSIFY_SPLIT_SLICES: [0-9]*/FALSIFY_SPLIT_SLICES: 3/' "a repo-git-reset.sh slice count the matrix does not match is caught"
caught restdrop 's/ rest-2,//' "a matrix missing a slice of rest is caught"
caught restcount 's/FALSIFY_REST_SLICES: [0-9]*/FALSIFY_REST_SLICES: 3/' "a rest slice count the matrix does not match is caught"
caught restwhole 's/ --slice "${SHARD#rest-}\/$FALSIFY_REST_SLICES"//' "a rest arm that does not slice is caught"

# ── Phase 6 runs each target with the flags CI runs it with ──────────────────
# verify-on-host.sh's Phase 6 runs the corpus on a developer host, and runs each
# target as CI's falsify job does: CI's project.sh shards add --select-oracles
# --stop-at-kill, every other shard neither (the user's choice, 2026-11-27).
# Both maps are taken by effect, `<target>|<flags>` per line. CI's: the step of
# every shard but deep, run against a run.sh that lists, through the real
# runner, what the arguments it was handed select, with which of the two flags
# it was handed. Phase 6's: PHASES=6 run in a stub repo holding the workflow,
# against the same run.sh, for every pass but the deep one. Each map must name
# every target of the corpus once, and the two must be equal.
ENGINE_DIR="$REPO_DIR"
VERIFY="$REPO_DIR/verify-on-host.sh"
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
# shellcheck source=tests/lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"
# shellcheck source=tests/lib-verify-repo.sh
source "$REPO_DIR/tests/lib-verify-repo.sh"
cat > "$TMP/flag-run.sh" <<'EOF_FLAGRUN'
#!/usr/bin/env bash
# A run of the falsify tier, as a list: `--list-targets` itself goes to the real
# runner; any other run appends `<target>|<flags>` to $FLAG_OUT for each target
# its arguments select (the deep pass, which is not a share of the corpus, adds
# nothing), then prints the records a clean run ends with.
for a in "$@"; do [[ "$a" == --list-targets ]] && exec bash "$FLAG_REAL" "$@"; done
f="" deep=0
for a in "$@"; do
  case "$a" in
    --select-oracles) f="$f select" ;;
    --stop-at-kill) f="$f stop" ;;
    --deep) deep=1 ;;
  esac
done
if (( ! deep )); then
  bash "$FLAG_REAL" --list-targets "$@" 2>/dev/null | while IFS=' ' read -r t _; do
    printf '%s|%s\n' "$t" "${f# }" >> "$FLAG_OUT"
  done
fi
printf 'TARGET|tests/portability.sh|test-portability.sh|1|1|0|0|0|1\nTOTAL|1|1|1|0|0|0|0|1\nASSERTLESS|0|1\n'
EOF_FLAGRUN
# The map of the shards of workflow $1, on stdout.
ci_flag_map() {  # $1=workflow
  local wf="$1" sh body d envs=() out
  mapfile -t envs < <(split_env "$wf")
  body="$(step_run "$wf" "$STEP")"
  d="$TMP/cimap"; rm -rf "$d"; mkdir -p "$d/tests/falsify" "$d/rt"
  cp "$TMP/flag-run.sh" "$d/tests/falsify/run.sh"
  printf '%s\n' "$body" > "$d/step.sh"
  out="$TMP/cimap.out"; : > "$out"
  while IFS= read -r sh; do
    [[ "$sh" == deep ]] && continue
    ( cd "$d" && env RUNNER_TEMP="$d/rt" SHARD="$sh" FLAG_REAL="$REAL_RUN" FLAG_OUT="$out" "${envs[@]}" \
        bash --noprofile --norc -eo pipefail step.sh ) >/dev/null 2>&1
  done < <(matrix_shards "$wf")
  sort -u "$out"
}
# The map of Phase 6 of verify-on-host.sh $2, run with workflow $1, on stdout;
# rc 1 when the phase failed.
p6_flag_map() {  # $1=workflow  $2=verify-on-host.sh
  local r out rc
  r="$(mk_repo 0)"
  cp "$2" "$r/verify-on-host.sh"
  mkdir -p "$r/.github/workflows" && cp "$1" "$r/.github/workflows/hermetic-checks.yml"
  cp "$TMP/flag-run.sh" "$r/tests/falsify/run.sh"
  out="$TMP/p6map.out"; : > "$out"
  rc="$(run_verify "$r" 6 FLAG_REAL="$REAL_RUN" FLAG_OUT="$out")"
  sort "$out"
  [[ "$rc" == 0 ]]
}
# rc 0 when Phase 6 of verify-on-host.sh $2 runs every target of the corpus once,
# each with the flags the shards of workflow $1 run it with.
flags_agree() {  # $1=workflow  $2=verify-on-host.sh
  local ci p6 corpus
  corpus="$(bash "$REAL_RUN" --list-targets 2>/dev/null | sort)"
  ci="$(ci_flag_map "$1")"
  if [[ "$(cut -d'|' -f1 <<< "$ci" | sort)" != "$corpus" ]]; then
    echo "CI's map does not name every target once: $(cut -d'|' -f1 <<< "$ci" | sort | uniq -d | tr '\n' ' ')"; return 1
  fi
  if ! p6="$(p6_flag_map "$1" "$2")"; then
    echo "Phase 6 failed: $(grep -E 'FAIL|ERROR' "$TMP/out.log" | head -3 | tr '\n' ' ')"; return 1
  fi
  if [[ "$(cut -d'|' -f1 <<< "$p6" | sort)" != "$corpus" ]]; then
    echo "Phase 6 does not run every target once: twice: $(cut -d'|' -f1 <<< "$p6" | sort | uniq -d | tr '\n' ' ') none: $(comm -13 <(cut -d'|' -f1 <<< "$p6" | sort -u) <(printf '%s\n' "$corpus") | tr '\n' ' ')"; return 1
  fi
  if [[ "$p6" != "$ci" ]]; then
    echo "the flags differ: CI $(comm -23 <(printf '%s\n' "$ci") <(printf '%s\n' "$p6") | tr '\n' ' ')/ Phase 6 $(comm -13 <(printf '%s\n' "$ci") <(printf '%s\n' "$p6") | tr '\n' ' ')"; return 1
  fi
  echo "$(grep -c . <<< "$p6") targets, $(grep -c '|select stop$' <<< "$p6") with oracle selection"
}
if msg="$(flags_agree "$WF" "$VERIFY")"; then
  pass "Phase 6 runs every target once, with the flags CI's shards run it with ($msg)"
else
  fail "Phase 6 runs every target once, with the flags CI's shards run it with: $msg"
fi
# Seen failing, each: a workflow whose version shard gains the flags; a Phase 6
# whose project.sh pass drops them; a Phase 6 whose first pass does not leave
# project.sh out, which then runs twice.
p6_caught() {  # $1=label  $2=sed program  $3=file to damage (WF or VERIFY)  $4=what must be caught
  local label="$1" prog="$2" which="$3" what="$4" src dmg out
  src="$WF"; [[ "$which" == VERIFY ]] && src="$VERIFY"
  dmg="$TMP/$label.dmg"
  sed "$prog" "$src" > "$dmg"
  if cmp -s "$src" "$dmg"; then
    fail "$what: the damage no longer applies ($prog)"; return
  fi
  if [[ "$which" == VERIFY ]]; then out="$(flags_agree "$WF" "$dmg")"; else out="$(flags_agree "$dmg" "$VERIFY")"; fi
  if [[ $? -eq 0 ]]; then fail "$what: $out"; else pass "$what"; fi
}
p6_caught ciflags 's/version) select=(--target "$FALSIFY_VERSION_TARGET") ;;/version) select=(--target "$FALSIFY_VERSION_TARGET" --select-oracles --stop-at-kill) ;;/' WF \
  "a CI shard that gains the flags Phase 6 does not give its target is caught"
p6_caught p6noflags 's/--target "$fl_t" --select-oracles --stop-at-kill/--target "$fl_t"/' VERIFY \
  "a Phase 6 that runs project.sh without CI's flags is caught"
p6_caught p6twice 's/fl_excl+=(--exclude-target "$fl_t")/:/' VERIFY \
  "a Phase 6 whose first pass does not leave project.sh out is caught"

printf '\n%d failure(s)\n' "$fails"
exit "$(( fails > 0 ))"
