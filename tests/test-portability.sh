#!/usr/bin/env bash
# The GNU/BSD-neutral helpers must agree with the platform's own tools.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

printf 'content\n' > "$TMP/f"; chmod 644 "$TMP/f"

[[ "$(p_stat_mode "$TMP/f")" == "644" ]] \
  && pass "p_stat_mode reports the octal mode" \
  || fail "p_stat_mode reports the octal mode — got '$(p_stat_mode "$TMP/f")'"

chmod 755 "$TMP/f"
[[ "$(p_stat_mode "$TMP/f")" == "755" ]] \
  && pass "p_stat_mode tracks a mode change" \
  || fail "p_stat_mode tracks a mode change — got '$(p_stat_mode "$TMP/f")'"

# The digest helpers must be stable and must differ for differing content.
a="$(p_sha1 "$TMP/f")"; b="$(p_sha1 "$TMP/f")"
[[ -n "$a" && "$a" == "$b" ]] \
  && pass "p_sha1 is non-empty and stable" || fail "p_sha1 is non-empty and stable"
printf 'other\n' > "$TMP/g"
[[ "$(p_sha1 "$TMP/f")" != "$(p_sha1 "$TMP/g")" ]] \
  && pass "p_sha1 distinguishes different content" \
  || fail "p_sha1 distinguishes different content"

# p_sha1 must pick the tool the PLATFORM actually has. The two assertions above
# cannot see that: this machine carries BOTH sha1sum and shasum and they print
# the same digest for the same bytes, so inverting the probe -- `cond-negate` of
# `command -v sha1sum` (falsify backlog F23) -- changes which tool runs and
# changes nothing observable. Its p_md5 sibling only dies by an accident of tool
# population (`md5 -q` does not exist on Linux, so the inverted probe prints
# empty and the non-empty check catches it), which measures the platform rather
# than the branch, and stops working the moment a host carries both.
#
# So make the branch decide the answer: run p_sha1 with a PATH holding exactly
# ONE of the two tools. Whichever half runs, the inverted probe reaches for the
# tool that is absent and yields an empty digest.
#
#   PATH has sha1sum only:  pristine -> sha1sum (correct);  mutated -> shasum   (absent)
#   PATH has shasum only:   pristine -> shasum  (correct);  mutated -> sha1sum  (absent)
#
# The expected digest is a literal rather than a second call to p_sha1: checking
# a helper against itself is `assert f(x) == f(x)`, which is how the branch went
# unasserted in the first place. shasum is a perl script with an absolute
# shebang, so restricting PATH does not break it.
sha1_want="7fe70820e08a1aac0ef224d9c66ab66831cc4ab1"   # sha1 of the 8 bytes "content\n"
if [[ "$(cat "$TMP/f")" != "content" ]]; then
  fail "p_sha1 branch-selection fixture still holds the bytes sha1_want was computed for"
else
  sha1_stub="$TMP/stub-bin"; mkdir -p "$sha1_stub"
  ln -sf "$(command -v cut)" "$sha1_stub/cut"
  sha1_tools_seen=0
  for sha1_tool in sha1sum shasum; do
    command -v "$sha1_tool" >/dev/null 2>&1 || continue
    sha1_tools_seen=$((sha1_tools_seen + 1))
    ln -sf "$(command -v "$sha1_tool")" "$sha1_stub/$sha1_tool"
    sha1_got="$( export PATH="$sha1_stub"; p_sha1 "$TMP/f" )"
    if [[ "$sha1_got" == "$sha1_want" ]]; then
      pass "p_sha1 digests correctly when $sha1_tool is the only digest tool on PATH"
    else
      fail "p_sha1 digests correctly when $sha1_tool is the only digest tool on PATH — want '$sha1_want', got '$sha1_got'"
    fi
    rm -f "$sha1_stub/$sha1_tool"
  done
  if [[ "$sha1_tools_seen" -gt 0 ]]; then
    pass "p_sha1 branch selection was exercised against $sha1_tools_seen digest tool(s)"
  else
    fail "p_sha1 branch selection was exercised — neither sha1sum nor shasum exists, so the assertions above ran zero times"
  fi
fi

m="$(p_md5 "$TMP/f")"
[[ -n "$m" && "$m" == "$(p_md5 "$TMP/f")" ]] \
  && pass "p_md5 is non-empty and stable" || fail "p_md5 is non-empty and stable"
[[ "$(p_md5 "$TMP/f")" != "$(p_md5 "$TMP/g")" ]] \
  && pass "p_md5 distinguishes different content" \
  || fail "p_md5 distinguishes different content"

# p_stat_meta: assert the VALUE, not merely non-emptiness. The branch selector
# in tests/portability.sh can be inverted -- both the `cmp-flip` and the
# `cond-negate` of `[[ "$_P_STAT_GNU" == "1" ]]` -- and the `[[ -n "$meta" ]]`
# check below passed against the result for as long as it stood alone, because
# on GNU `stat -f` is NOT an invalid option that falls through: it means
# --file-system, so the swapped branch prints a multi-line filesystem report
# plus an error rather than nothing, and that garbage is non-empty. Measured
# (falsify backlog F25):
#
#   pristine:  f 8 1787173959
#   mutated:   stat: cannot read file system information for '%N %z %m': ...
#                File: "f"
#                  ID: 622806a99446626e Namelen: 255     Type: overlayfs
#              (and four more lines)
#
# What separates them is the SHAPE and the VALUE -- exactly three fields, the
# middle one the file's real byte size -- which is the assertion p_stat_mode one
# line up has always carried and this helper did not. That asymmetry is why the
# meta line looked covered by association while both of its mutants survived the
# whole suite.
#
# Called from inside $TMP with a bare filename so "exactly three fields" is a
# property of the helper rather than of whether TMPDIR happens to contain a
# space.
meta="$(cd "$TMP" && p_stat_meta f)"
[[ -n "$meta" ]] && pass "p_stat_meta returns something" || fail "p_stat_meta returns something"

meta_want_size="$(wc -c < "$TMP/f")"; meta_want_size="${meta_want_size//[[:space:]]/}"
# shellcheck disable=SC2206  # deliberate: splitting on whitespace IS how the field count is measured
meta_fields=($meta)
if [[ "${#meta_fields[@]}" -eq 3 ]]; then
  pass "p_stat_meta returns exactly three fields (got '$meta')"
else
  fail "p_stat_meta returns exactly three fields — got ${#meta_fields[@]} in '$meta'"
fi
if [[ "${meta_fields[1]:-}" == "$meta_want_size" ]]; then
  pass "p_stat_meta's second field is the file's byte size ($meta_want_size)"
else
  fail "p_stat_meta's second field is the file's byte size — want '$meta_want_size', got '${meta_fields[1]:-}' from '$meta'"
fi
if [[ "${meta_fields[2]:-}" =~ ^[0-9]+$ ]]; then
  pass "p_stat_meta's third field is a numeric mtime (${meta_fields[2]})"
else
  fail "p_stat_meta's third field is a numeric mtime — got '${meta_fields[2]:-}' from '$meta'"
fi

# p_realdir: independent (cd + pwd -P, not readlink -f) directory canonicalisation.
mkdir -p "$TMP/dirA" "$TMP/dirB"
rA="$(p_realdir "$TMP/dirA")"; rA2="$(p_realdir "$TMP/dirA")"
[[ -n "$rA" && "$rA" == "$rA2" ]] \
  && pass "p_realdir is non-empty and stable" \
  || fail "p_realdir is non-empty and stable (got '$rA' then '$rA2')"

rB="$(p_realdir "$TMP/dirB")"
[[ -n "$rB" && "$rA" != "$rB" ]] \
  && pass "p_realdir distinguishes different directories" \
  || fail "p_realdir distinguishes different directories (rA='$rA' rB='$rB')"

# A trailing-slash / './' form of the SAME directory must canonicalise identically.
rA3="$(p_realdir "$TMP/dirA/./")"
[[ "$rA3" == "$rA" ]] \
  && pass "p_realdir normalises ./ and a trailing slash to the same answer" \
  || fail "p_realdir normalises ./ and a trailing slash to the same answer (got '$rA3', want '$rA')"

# p_timeout: the BOUND the falsify tier was missing, so a damage that makes a
# call non-terminating fails an assertion BY NAME instead of expiring run.sh's
# per-mutant clock with nothing observed (backlog F22). Three properties, each
# separately breakable:
#
#   1. a command that finishes in time yields ITS OWN status, not the bound's
#   2. a command that does not finish yields 124 rather than hanging forever
#   3. the bounded command is actually DEAD afterwards -- a bound that returns
#      124 and leaves the process spinning would poison every test after it,
#      and both oracles this was written for spin at 100% CPU when damaged
#
# Property 1 carries the mutation coverage: inverting either the liveness probe
# (`while kill -0 …`) or the deadline comparison (`-ge`) makes p_timeout report
# 124 for a command that completed, and that status is what this reads.
p_timeout 3 bash -c 'exit 7'; to_rc=$?
if [[ "$to_rc" -eq 7 ]]; then
  pass "p_timeout returns the command's own exit status when it finishes in time"
else
  fail "p_timeout returns the command's own exit status when it finishes in time -- want 7, got $to_rc"
fi

to_out="$(p_timeout 3 bash -c 'printf ok')"
if [[ "$to_out" == "ok" ]]; then
  pass "p_timeout passes the bounded command's stdout through"
else
  fail "p_timeout passes the bounded command's stdout through -- want 'ok', got '$to_out'"
fi

# Property 2, and with it the only honest form of property 3. The first draft
# of this block checked that the bounded command was no longer alive after
# p_timeout returned -- a check that CANNOT FAIL, because p_timeout ends with
# `wait "$cmd_pid"`, which by definition does not return until the child is
# dead. It passed against a damage that removed the kill outright.
#
# What is actually falsifiable is that the bound CUTS THE COMMAND SHORT: bound a
# 30-second sleep at 1 second and require both the 124 and an elapsed time
# nowhere near 30. Remove the kills and the status stays 124 (the watchdog still
# marks the flag) while `wait` sits out the full thirty seconds -- so the status
# alone would call that a working bound, and only the clock catches it.
to_t0=$SECONDS
p_timeout 1 bash -c 'sleep 30'
to_slow_rc=$?
to_elapsed=$(( SECONDS - to_t0 ))
if [[ "$to_slow_rc" -eq 124 ]]; then
  pass "p_timeout returns 124 when the clock expires"
else
  fail "p_timeout returns 124 when the clock expires -- got $to_slow_rc"
fi
if [[ "$to_elapsed" -lt 10 ]]; then
  pass "p_timeout cuts the command short rather than outliving it (${to_elapsed}s for a 30s command bounded at 1s)"
else
  fail "p_timeout cuts the command short rather than outliving it -- a 30s command bounded at 1s took ${to_elapsed}s, so nothing was actually killed"
fi

# No helper may leave the caller with an empty answer on THIS platform: an empty
# string compares equal to another empty string, which is how a portability bug
# turns into a test that passes by accident.
for h in p_stat_mode p_sha1 p_md5 p_stat_meta; do
  if [[ -n "$($h "$TMP/f")" ]]; then pass "$h is non-empty on this platform"
  else
    fail "$h returned empty — comparisons using it would pass vacuously"
    # WHY it was empty, because the last time this fired nobody could tell.
    # CI, 2026-08-21 (mgd-ai-containers PR #76, run 32523718531): p_md5 AND
    # p_stat_meta both returned empty in ONE control run, while the same run
    # measured the corpus normally — a pristine oracle going red under the
    # tier's own load (backlog F30/F32). The report named the symptom and
    # nothing else, and the helpers are why: p_md5 and p_sha1 are PIPELINES
    # (`md5sum … | cut`), so a failing md5sum still leaves `cut` succeeding with
    # empty output, and p_stat_meta's error goes to stderr with stdout empty.
    # Both hide the cause. Two facts separate the candidates — did the file
    # vanish, or did the tool fail on a file that is right there?
    printf '     diag: file=%s exists=%s size=%s\n' "$TMP/f" \
      "$([[ -e "$TMP/f" ]] && printf y || printf n)" \
      "$(wc -c <"$TMP/f" 2>/dev/null | tr -d ' ' || printf '?')" >&2
    printf '     diag: %s stderr: %s\n' "$h" "$( $h "$TMP/f" 2>&1 >/dev/null | head -2 | tr '\n' ' ' )" >&2
  fi
done

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
