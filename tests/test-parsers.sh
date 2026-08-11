#!/usr/bin/env bash
# Tests for pure host-side parsing helpers, previously untested:
#   sandbox.sh:         mem_to_bytes, validate_memory_limits,
#                        parse_pointer_spec, pointer_repo_entry
#   sandbox-common.sh:  resolve_path, sanitize_volume_token, validate_group_name
#   project-init.sh:     mem_to_bytes, mem_le, mem_ge
#
# sandbox-common.sh is a pure library (no entry point) and is sourced directly.
# sandbox.sh has NO source guard but its entry point safely no-ops into the
# `usage` branch when its positional params are cleared first (see run_fn
# below).
# project-init.sh has NO source guard AND no safe branch: it runs straight
# into an unconditional interactive prompt loop after its helper functions are
# defined, so it is driven purely as a subprocess with scripted stdin (the
# same technique as tests/test-project-init.sh), observing the mem_le/mem_ge
# gated retry-loop's behaviour on stderr — no implementation logic is copied.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Capture the real HOME BEFORE overriding it, so the final hermeticity check
# can run `git status` the same way the invoking user's shell would (global
# excludesfile etc.), instead of seeing HOME-dependent noise (e.g. a
# ~/.gitignore_global-based ignore of .ai-containers/ that doesn't exist once
# HOME is redirected to a temp dir).
REAL_HOME="$HOME"
# Snapshot the repo's git state up front. Comparing a before/after snapshot is
# self-maintaining: it catches anything THIS test writes into the repo without
# hardcoding a whitelist of unrelated untracked files, which goes stale the
# moment another test file is added.
REPO_STATUS_BEFORE="$(HOME="$REAL_HOME" git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)"

# Isolated HOME throughout: sandbox-common.sh reads ~/.ai-containers.
export HOME="$TMP/home"; mkdir -p "$HOME"

# ══════════════════════════════════════════════════════════════════════════════
# sandbox.sh helpers — via a subshell source with cleared positional params
# ══════════════════════════════════════════════════════════════════════════════

# run_fn <fn-name> [args...] — prints the function's stdout; forwards its rc.
run_fn() {
  ( cd "$TMP" && HOME="$HOME" bash -c '
      src="$1"; fn="$2"; shift 2
      fn_args=("$@")
      set --
      source "$src" >/dev/null   # the source-time usage-branch print is noise
      "$fn" "${fn_args[@]}"
    ' _ "$REPO_DIR/sandbox.sh" "$@"
  )
}

# ── sandbox.sh: mem_to_bytes ─────────────────────────────────────────────────
# Table of inputs shared with project-init.sh's mem_to_bytes further down, to
# pin the two implementations (which are maintained as separate copies) in
# agreement. desc:input:expected_bytes_or_FAIL
MEM_TABLE=(
  "bytes, no suffix:512:512"
  "explicit b suffix:512b:512"
  "kilobytes:2k:2048"
  "megabytes:512m:536870912"
  "gigabytes:2g:2147483648"
  "unlimited sentinel -1:-1:-1"
  "zero:0:0"
  "bad unit t:5t:FAIL"
  "non-numeric:abc:FAIL"
  "empty string::FAIL"
  "negative (not -1):-5:FAIL"
  "trailing garbage:5gg:FAIL"
)

for row in "${MEM_TABLE[@]}"; do
  desc="${row%%:*}"; rest="${row#*:}"
  input="${rest%%:*}"; expected="${rest#*:}"
  out="$(run_fn mem_to_bytes "$input")"; rc=$?
  if [[ "$expected" == "FAIL" ]]; then
    if [[ $rc -ne 0 ]]; then pass "sandbox.sh mem_to_bytes: $desc -> parse failure"
    else fail "sandbox.sh mem_to_bytes: $desc -> parse failure (got rc=0 out='$out')"; fi
  else
    if [[ $rc -eq 0 && "$out" == "$expected" ]]; then pass "sandbox.sh mem_to_bytes: $desc -> $expected"
    else fail "sandbox.sh mem_to_bytes: $desc -> $expected (rc=$rc out='$out')"; fi
  fi
done

# ── sandbox.sh: validate_memory_limits ───────────────────────────────────────
# Sets globals mem_limit/mem_reservation/mem_swap after reconciling
# CONTAINER_MEMORY / _RESERVATION / _SWAP. Drive it via env + run_fn, echoing
# the three globals so the test can assert on them.
run_validate_memory() { # $1=MEMORY $2=RESERVATION $3=SWAP
  ( cd "$TMP" && HOME="$HOME" \
    CONTAINER_MEMORY="$1" CONTAINER_MEMORY_RESERVATION="$2" CONTAINER_MEMORY_SWAP="$3" \
    bash -c '
      src="$1"; shift
      set --
      source "$src" >/dev/null
      validate_memory_limits
      printf "%s %s %s\n" "$mem_limit" "$mem_reservation" "$mem_swap"
    ' _ "$REPO_DIR/sandbox.sh"
  )
}

# Defaults (no env set) -> 4g / 2g / 4g, all within ordering already.
out="$( ( cd "$TMP" && HOME="$HOME" bash -c '
      src="$1"; set --
      source "$src" >/dev/null
      validate_memory_limits
      printf "%s %s %s\n" "$mem_limit" "$mem_reservation" "$mem_swap"
    ' _ "$REPO_DIR/sandbox.sh" ) )"
check "validate_memory_limits defaults" "4g 2g 4g" "$out"

# reservation <= memory <= swap already satisfied -> values pass through unchanged.
out="$(run_validate_memory 4g 2g 4g)"
check "validate_memory_limits: already-valid ordering passes through" "4g 2g 4g" "$out"

# reservation > memory -> reservation is lowered to memory.
out="$(run_validate_memory 2g 4g 2g)"
check "validate_memory_limits: reservation > memory is lowered to memory" "2g 2g 2g" "$out"

# swap < memory -> swap is raised to memory.
out="$(run_validate_memory 4g 2g 1g)"
check "validate_memory_limits: swap < memory is raised to memory" "4g 2g 4g" "$out"

# swap == -1 (unlimited) is always accepted regardless of memory.
out="$(run_validate_memory 4g 2g -1)"
check "validate_memory_limits: swap=-1 is left unlimited" "4g 2g -1" "$out"

# unit suffixes k/m/g are recognised in the ordering check (512m < 1g: reservation ok).
out="$(run_validate_memory 1g 512m 1g)"
check "validate_memory_limits: k/m/g suffixes are compared correctly" "1g 512m 1g" "$out"

# bad CONTAINER_MEMORY -> warns and returns without modifying mem_limit et al
# (the function assigns from the env var directly and returns early on parse
# failure, so mem_limit reflects the unparsed input, not a numeric fallback).
BADOUT="$TMP/bad.err"
( cd "$TMP" && HOME="$HOME" CONTAINER_MEMORY="nonsense" bash -c '
    src="$1"; set --
    source "$src" >/dev/null
    validate_memory_limits
    printf "%s\n" "$mem_limit"
  ' _ "$REPO_DIR/sandbox.sh" >"$TMP/bad.out" 2>"$BADOUT" )
if grep -q 'is not a recognised memory value; skipping memory validation' "$BADOUT" \
   && [[ "$(cat "$TMP/bad.out")" == "nonsense" ]]; then
  pass "validate_memory_limits: bad CONTAINER_MEMORY warns and skips reconciliation"
else
  fail "validate_memory_limits: bad CONTAINER_MEMORY warns and skips reconciliation (err='$(cat "$BADOUT")' out='$(cat "$TMP/bad.out")')"
fi

# ── sandbox.sh: parse_pointer_spec ───────────────────────────────────────────
# parse_pointer_spec <raw> <default_mode> <allow_suffix> sets PTR_KIND/PTR_SRC/PTR_MODE.
run_parse_pointer() { # $1=raw $2=default_mode $3=allow_suffix
  ( cd "$TMP" && HOME="$HOME" bash -c '
      src="$1"; a="$2"; b="$3"; c="$4"
      set --
      source "$src" >/dev/null
      parse_pointer_spec "$a" "$b" "$c"
      printf "%s %s %s\n" "$PTR_KIND" "$PTR_SRC" "$PTR_MODE"
    ' _ "$REPO_DIR/sandbox.sh" "$@"
  )
}

out="$(run_parse_pointer "@myrepo" "ro" "1")"
check "parse_pointer_spec: @name -> volume kind, default mode when no suffix" "volume myrepo ro" "$out"

out="$(run_parse_pointer "@myrepo:rw" "ro" "1")"
check "parse_pointer_spec: @name:rw -> volume kind, rw mode" "volume myrepo rw" "$out"

out="$(run_parse_pointer "@myrepo:ro" "rw" "1")"
check "parse_pointer_spec: @name:ro -> volume kind, ro mode (overrides default)" "volume myrepo ro" "$out"

out="$(run_parse_pointer "/host/path" "ro" "1")"
check "parse_pointer_spec: host path (no @) -> path kind" "path /host/path ro" "$out"

out="$(run_parse_pointer "/host/path:rw" "ro" "1")"
check "parse_pointer_spec: host path with :rw suffix -> path kind, rw mode" "path /host/path rw" "$out"

# allow_suffix=0 -> :ro/:rw suffix is NOT stripped/interpreted; it stays part of PTR_SRC.
out="$(run_parse_pointer "@myrepo:ro" "rw" "0")"
check "parse_pointer_spec: allow_suffix=0 leaves the :ro suffix untouched in PTR_SRC" "volume myrepo:ro rw" "$out"

# default_mode is used verbatim when allow_suffix=1 but no suffix is present.
out="$(run_parse_pointer "@bare" "rw" "1")"
check "parse_pointer_spec: no suffix -> falls back to default_mode" "volume bare rw" "$out"

# ── sandbox.sh: pointer_repo_entry ───────────────────────────────────────────
run_pointer_entry() { # $1=name $2=mode $3..=existing repos_list entries
  ( cd "$TMP" && HOME="$HOME" bash -c '
      src="$1"; shift
      fn_args=("$@")
      set --
      source "$src" >/dev/null
      pointer_repo_entry "${fn_args[@]}"
    ' _ "$REPO_DIR/sandbox.sh" "$@"
  )
}

out="$(run_pointer_entry "newrepo" "ro")"
check "pointer_repo_entry: name not yet listed -> emits name:mode" "newrepo:ro" "$out"

out="$(run_pointer_entry "existing" "ro" "existing:ro" "other:rw")"
check "pointer_repo_entry: name already listed with SAME mode -> emits nothing" "" "$out"

out="$(run_pointer_entry "existing" "rw" "existing:ro" "other:rw" 2>"$TMP/entry.err")"
check "pointer_repo_entry: name already listed with DIFFERENT mode -> emits nothing (existing wins)" "" "$out"
if grep -q "repo 'existing' is already mounted (ro); the pointer's :rw is ignored" "$TMP/entry.err"; then
  pass "pointer_repo_entry: mode divergence is noted on stderr"
else
  fail "pointer_repo_entry: mode divergence is noted on stderr (got '$(cat "$TMP/entry.err")')"
fi

# entries with no explicit mode-suffix default the existing mode to "ro"
# (the e##*: -> name fallback path in pointer_repo_entry).
out="$(run_pointer_entry "bareentry" "rw" "bareentry" 2>"$TMP/entry2.err")"
check "pointer_repo_entry: a bare existing entry (no ':mode') is treated as ro" "" "$out"
grep -q "is already mounted (ro); the pointer's :rw is ignored" "$TMP/entry2.err" \
  && pass "pointer_repo_entry: bare existing entry defaults to ro in the note" \
  || fail "pointer_repo_entry: bare existing entry defaults to ro in the note (got '$(cat "$TMP/entry2.err")')"

# ══════════════════════════════════════════════════════════════════════════════
# sandbox-common.sh helpers — safe to source directly (pure library, no entry point)
# ══════════════════════════════════════════════════════════════════════════════

( set --
  source "$REPO_DIR/sandbox-common.sh"

  # ── resolve_path ────────────────────────────────────────────────────────
  mkdir -p "$TMP/somedir"
  out="$(resolve_path "$TMP/somedir")"
  [[ "$out" == "$TMP/somedir" ]] \
    && printf 'PASS: resolve_path: absolute existing dir resolves to itself\n' \
    || printf "FAIL: resolve_path: absolute existing dir resolves to itself (got '%s')\n" "$out"

  # A path with a trailing slash / './' segments still resolves to the clean absolute form.
  out="$(resolve_path "$TMP/somedir/./")"
  [[ "$out" == "$TMP/somedir" ]] \
    && printf 'PASS: resolve_path: normalises ./ and trailing slash\n' \
    || printf "FAIL: resolve_path: normalises ./ and trailing slash (got '%s')\n" "$out"

  # A relative path (cwd = $TMP) resolves against the CURRENT directory.
  out="$(cd "$TMP" && resolve_path "somedir")"
  [[ "$out" == "$TMP/somedir" ]] \
    && printf 'PASS: resolve_path: relative path resolves against cwd\n' \
    || printf "FAIL: resolve_path: relative path resolves against cwd (got '%s')\n" "$out"

  # A symlink resolves to its target (readlink -f follows symlinks).
  ln -s "$TMP/somedir" "$TMP/symlink-to-somedir"
  out="$(resolve_path "$TMP/symlink-to-somedir")"
  [[ "$out" == "$TMP/somedir" ]] \
    && printf 'PASS: resolve_path: symlink resolves to its target\n' \
    || printf "FAIL: resolve_path: symlink resolves to its target (got '%s')\n" "$out"

  # ── sanitize_volume_token ────────────────────────────────────────────────
  out="$(sanitize_volume_token "my repo!!/name")"
  [[ "$out" == "my_repo___name" ]] \
    && printf 'PASS: sanitize_volume_token: non-conforming chars collapse to underscores\n' \
    || printf "FAIL: sanitize_volume_token: non-conforming chars collapse to underscores (got '%s')\n" "$out"

  out="$(sanitize_volume_token "_leading-underscore")"
  [[ "$out" == "leading-underscore" ]] \
    && printf 'PASS: sanitize_volume_token: a leading underscore separator is stripped\n' \
    || printf "FAIL: sanitize_volume_token: a leading underscore separator is stripped (got '%s')\n" "$out"

  out="$(sanitize_volume_token "already-valid_Token.123")"
  [[ "$out" == "already-valid_Token.123" ]] \
    && printf 'PASS: sanitize_volume_token: an already-conforming token is unchanged\n' \
    || printf "FAIL: sanitize_volume_token: an already-conforming token is unchanged (got '%s')\n" "$out"

  # ── validate_group_name ──────────────────────────────────────────────────
  # Valid names return 0 with no output.
  out="$(validate_group_name "default" 2>&1)"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] \
    && printf 'PASS: validate_group_name: a valid name returns 0 silently\n' \
    || printf "FAIL: validate_group_name: a valid name returns 0 silently (rc=%s out='%s')\n" "$rc" "$out"

  out="$(validate_group_name "team-42" 2>&1)"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] \
    && printf 'PASS: validate_group_name: dashes and digits are allowed\n' \
    || printf "FAIL: validate_group_name: dashes and digits are allowed (rc=%s out='%s')\n" "$rc" "$out"

  # Invalid names: validate_group_name calls `exit 1` directly (not `return`),
  # so it must be driven in its OWN subshell to observe the exit without
  # terminating this whole block.
  out="$( (validate_group_name "Invalid_Name") 2>&1 )"; rc=$?
  [[ $rc -eq 1 ]] && echo "$out" | grep -q 'Invalid AI_CONTAINER_GROUP' \
    && printf 'PASS: validate_group_name: uppercase/underscore name exits 1 with a message\n' \
    || printf "FAIL: validate_group_name: uppercase/underscore name exits 1 with a message (rc=%s out='%s')\n" "$rc" "$out"

  out="$( (validate_group_name "-startswithdash") 2>&1 )"; rc=$?
  [[ $rc -eq 1 ]] \
    && printf 'PASS: validate_group_name: a name starting with a dash is rejected\n' \
    || printf "FAIL: validate_group_name: a name starting with a dash is rejected (rc=%s)\n" "$rc"

  toolong="$(printf 'a%.0s' $(seq 1 33))"   # 33 chars > the 32-char max
  out="$( (validate_group_name "$toolong") 2>&1 )"; rc=$?
  [[ $rc -eq 1 ]] \
    && printf 'PASS: validate_group_name: a name over 32 chars is rejected\n' \
    || printf "FAIL: validate_group_name: a name over 32 chars is rejected (rc=%s)\n" "$rc"

  maxlen="$(printf 'a%.0s' $(seq 1 32))"    # exactly 32 chars is allowed
  out="$( (validate_group_name "$maxlen") 2>&1 )"; rc=$?
  [[ $rc -eq 0 ]] \
    && printf 'PASS: validate_group_name: a name of exactly 32 chars is accepted\n' \
    || printf "FAIL: validate_group_name: a name of exactly 32 chars is accepted (rc=%s out='%s')\n" "$rc" "$out"
) > "$TMP/common.out" 2>&1
cat "$TMP/common.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/common.out") ))

# ══════════════════════════════════════════════════════════════════════════════
# project-init.sh: mem_to_bytes, mem_le, mem_ge — driven as a subprocess
# (no source guard AND an unconditional interactive prompt loop right after
# the helpers, so this file cannot be safely sourced; see header comment).
# ══════════════════════════════════════════════════════════════════════════════

# A throwaway copy of the repo so project-init.sh's file copies / projects.conf
# writes never touch the real tree (mirrors tests/test-project-init.sh).
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
for f in project-init.sh projects.conf.example sandbox-common.sh sandbox.sh build.sh \
         repo.sh entrypoint.sh tools-lib.sh install-tools.sh install-agent-skills.sh \
         bash-floor.sh \
         Dockerfile Dockerfile.seed .dockerignore sandbox.conf \
         refresh-ipset-allowlist.sh capture-blocked-traffic.sh capture-agent-destinations.sh; do
  [[ -f "$REPO_DIR/$f" ]] && cp "$REPO_DIR/$f" "$SCRIPTS/$f"
done
for d in allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d tools.d; do
  [[ -d "$REPO_DIR/$d" ]] && cp -R "$REPO_DIR/$d" "$SCRIPTS/$d"
done

# Drive project-init.sh with scripted stdin far enough to exercise the memory
# prompts, then answer with the group/mounts steps so it always terminates
# (mirrors tests/test-project-init.sh's scripted-answers technique).
# Pre-creating ~/.ai-containers/default makes the conditional "which group to
# init from" menu (project-init.sh step 7) not fire for the default group, so
# every run below follows the SAME fixed prompt order:
#   path, name(def), image(def), cpus(def), memory, reservation, memory+swap,
#   group(def "default"), extra-mounts(empty). That is 1 real answer (path)
# + 3 empty defaults (name/image/cpus) + memory/reservation/swap + 2 empty
# defaults (group/mounts) = 9 lines.
mkdir -p "$HOME/.ai-containers/default"

run_project_init() { # $1=project_dir  $2=memory  $3=reservation  $4=memswap
  local proj="$1" mem="$2" res="$3" swap="$4"
  printf '%s\n\n\n\n%s\n%s\n%s\n\n\n' "$proj" "$mem" "$res" "$swap" \
    | bash "$SCRIPTS/project-init.sh"
}

PROJ_OK="$TMP/proj-ok"; mkdir -p "$PROJ_OK"; git -C "$PROJ_OK" init -q

# Valid reservation (<=memory) and valid swap (>=memory) -> both retry loops
# are satisfied on the first answer; no reprompt messages on stderr.
err="$(run_project_init "$PROJ_OK" "8g" "4g" "8g" 2>&1 1>/dev/null)"
if ! grep -q 'Reservation must be a valid memory value' <<<"$err" \
   && ! grep -q 'memory-swap must be a valid memory value' <<<"$err"; then
  pass "project-init.sh mem_le/mem_ge: valid reservation+swap pass without reprompt"
else
  fail "project-init.sh mem_le/mem_ge: valid reservation+swap pass without reprompt (err='$err')"
fi

# Reservation GREATER than memory must be rejected (mem_le fails) and reprompted;
# answer again with a valid value on the second line so the script still terminates.
PROJ_RES_BAD="$TMP/proj-res-bad"; mkdir -p "$PROJ_RES_BAD"; git -C "$PROJ_RES_BAD" init -q
out="$(printf '%s\n\n\n\n8g\n16g\n4g\n8g\n\n\n' "$PROJ_RES_BAD" | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
if grep -q 'Reservation must be a valid memory value' <<<"$out"; then
  pass "project-init.sh mem_le: reservation > memory is rejected and reprompted"
else
  fail "project-init.sh mem_le: reservation > memory is rejected and reprompted (out='$out')"
fi

# Swap LESS than memory must be rejected (mem_ge fails) and reprompted.
PROJ_SWAP_BAD="$TMP/proj-swap-bad"; mkdir -p "$PROJ_SWAP_BAD"; git -C "$PROJ_SWAP_BAD" init -q
out="$(printf '%s\n\n\n\n8g\n4g\n2g\n8g\n\n\n' "$PROJ_SWAP_BAD" | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
if grep -q 'memory-swap must be a valid memory value' <<<"$out"; then
  pass "project-init.sh mem_ge: swap < memory is rejected and reprompted"
else
  fail "project-init.sh mem_ge: swap < memory is rejected and reprompted (out='$out')"
fi

# swap == -1 (unlimited) is accepted regardless of mem_ge (short-circuited
# by the explicit "-1" check in project-init.sh before calling mem_ge).
PROJ_SWAP_UNLIM="$TMP/proj-swap-unlim"; mkdir -p "$PROJ_SWAP_UNLIM"; git -C "$PROJ_SWAP_UNLIM" init -q
out="$(printf '%s\n\n\n\n8g\n4g\n-1\n\n\n' "$PROJ_SWAP_UNLIM" | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
if ! grep -q 'memory-swap must be a valid memory value' <<<"$out"; then
  pass "project-init.sh: memory-swap=-1 (unlimited) is accepted without reprompt"
else
  fail "project-init.sh: memory-swap=-1 (unlimited) is accepted without reprompt (out='$out')"
fi

# A non-memory-shaped reservation (garbage) is also rejected by mem_le (parse
# failure -> return 2, non-zero either way), reprompted, then corrected.
PROJ_GARBAGE="$TMP/proj-garbage"; mkdir -p "$PROJ_GARBAGE"; git -C "$PROJ_GARBAGE" init -q
out="$(printf '%s\n\n\n\n8g\nnotmemory\n4g\n8g\n\n\n' "$PROJ_GARBAGE" | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
if grep -q 'Reservation must be a valid memory value' <<<"$out"; then
  pass "project-init.sh mem_le: unparseable reservation is rejected and reprompted"
else
  fail "project-init.sh mem_le: unparseable reservation is rejected and reprompted (out='$out')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Cross-check: sandbox.sh's mem_to_bytes and project-init.sh's mem_to_bytes
# agree on the SAME shared table (pins the intentional duplication).
# ══════════════════════════════════════════════════════════════════════════════

# project-init.sh cannot be sourced (see header). To compare its mem_to_bytes
# against sandbox.sh's on the SAME table without copying either
# implementation, drive project-init.sh's memory-reservation retry loop with
# RESERVATION deliberately set to each table value (with MEMORY fixed huge
# enough that any VALID value is <= it) and classify by whether it reprompts:
#   no reprompt -> project-init.sh's mem_to_bytes parsed it as a valid,
#                  <= MEMORY value.
#   reprompt    -> project-init.sh's mem_to_bytes rejected it (FAIL) OR it
#                  parsed but exceeded MEMORY (not applicable here since
#                  MEMORY is fixed at a huge 1024g and every table entry that
#                  parses is far smaller).
BIG_MEMORY="1024g"
idx=0
for row in "${MEM_TABLE[@]}"; do
  desc="${row%%:*}"; rest="${row#*:}"
  input="${rest%%:*}"; expected="${rest#*:}"
  [[ -z "$input" ]] && continue   # project-init's prompt can't submit a truly empty answer meaningfully (re-prompts as "required" via a different check upstream — not exercised here)
  idx=$((idx + 1))
  proj="$TMP/xcheck-$idx"
  mkdir -p "$proj"; git -C "$proj" init -q
  out="$(printf '%s\n\n\n\n%s\n%s\n%s\n\n\n' "$proj" "$BIG_MEMORY" "$input" "$BIG_MEMORY" | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
  reprompted=0
  grep -q 'Reservation must be a valid memory value' <<<"$out" && reprompted=1
  if [[ "$expected" == "FAIL" ]]; then
    if [[ $reprompted -eq 1 ]]; then
      pass "mem_to_bytes agreement: $desc -> both reject '$input'"
    else
      fail "mem_to_bytes agreement: $desc -> both reject '$input' (project-init.sh accepted it; sandbox.sh rejects it)"
    fi
  else
    if [[ $reprompted -eq 0 ]]; then
      pass "mem_to_bytes agreement: $desc -> both accept '$input'"
    else
      fail "mem_to_bytes agreement: $desc -> both accept '$input' (project-init.sh rejected it; sandbox.sh parses it as $expected bytes)"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# Cross-check part 2: MAGNITUDES, not just accept/reject.
#
# The loop above only classifies each value as accepted or rejected, so a drift
# that changes a unit MULTIPLIER in one copy (say m = 1000*1000 instead of
# 1024*1024) while still "accepting" the value is invisible to it. These pairs
# compare a reservation against a memory limit expressed in a DIFFERENT unit, at
# the exact boundary, so the accept/reject outcome depends on the multipliers
# agreeing exactly. sandbox.sh's own byte values are pinned by MEM_TABLE above,
# so agreement here pins both copies to the same scale.
# desc:reservation:memory:expect(accept|reject)
MEM_BOUNDARY_TABLE=(
  "1g == 1024m:1g:1024m:accept"
  "1025m > 1g:1025m:1g:reject"
  "1m == 1024k:1m:1024k:accept"
  "1025k > 1m:1025k:1m:reject"
  "1k == 1024b:1k:1024b:accept"
  "1025b > 1k:1025b:1k:reject"
  "1024m == 1g:1024m:1g:accept"
)
bidx=0
for row in "${MEM_BOUNDARY_TABLE[@]}"; do
  desc="${row%%:*}"; rest="${row#*:}"
  res="${rest%%:*}"; rest="${rest#*:}"
  mem="${rest%%:*}"; expect="${rest#*:}"
  bidx=$((bidx + 1))
  proj="$TMP/xbound-$bidx"
  mkdir -p "$proj"; git -C "$proj" init -q
  out="$(printf '%s\n\n\n\n%s\n%s\n%s\n\n\n' "$proj" "$mem" "$res" "$mem" \
    | bash "$SCRIPTS/project-init.sh" 2>&1 1>/dev/null)"
  reprompted=0
  grep -q 'Reservation must be' <<<"$out" && reprompted=1
  if [[ "$expect" == "accept" ]]; then
    if [[ $reprompted -eq 0 ]]; then
      pass "mem_to_bytes magnitude: $desc -> accepted"
    else
      fail "mem_to_bytes magnitude: $desc -> accepted (project-init.sh rejected it; its unit multipliers have drifted from sandbox.sh's)"
    fi
  else
    if [[ $reprompted -eq 1 ]]; then
      pass "mem_to_bytes magnitude: $desc -> rejected"
    else
      fail "mem_to_bytes magnitude: $desc -> rejected (project-init.sh accepted it; its unit multipliers have drifted from sandbox.sh's)"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# Hermeticity
# ══════════════════════════════════════════════════════════════════════════════

if [[ -e "$REPO_DIR/projects.conf.bak" ]] || ! HOME="$REAL_HOME" git -C "$REPO_DIR" diff --quiet -- projects.conf 2>/dev/null; then
  fail "real repo's projects.conf untouched"
else
  pass "real repo's projects.conf untouched"
fi

REPO_STATUS_AFTER="$(HOME="$REAL_HOME" git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)"
if [[ "$REPO_STATUS_BEFORE" == "$REPO_STATUS_AFTER" ]]; then
  pass "real repo has no unexpected working-tree changes"
else
  fail "real repo has no unexpected working-tree changes"
  diff <(printf '%s\n' "$REPO_STATUS_BEFORE") <(printf '%s\n' "$REPO_STATUS_AFTER") | sed 's/^/    /' >&2
fi

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 )) || exit 1
