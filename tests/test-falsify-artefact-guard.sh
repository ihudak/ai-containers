#!/usr/bin/env bash
# tests/test-falsify-artefact-guard.sh — a KILL is only a kill if the scratch
# could still hold a file (backlog F31 ADDENDUM).
#
# THE DEFECT. F31's addendum measured, on the affected host, four kinds of
# damage injected into an UNMUTATED tree — each scored `KILLED | exit+failline`.
# The tier reported kills with no mutation present at all. A false KILL inflates
# the coverage claim exactly as a false green does, and unlike a survivor it is
# owed no ledger entry, so nothing downstream ever questions it.
#
# WHY AN EXISTENCE CHECK CANNOT SEE IT. The two filesystem shapes fail
# differently, and the field report matches the one an existence check passes:
#
#   HFS+   fails at open()      → the artefact is ABSENT
#   APFS   `cat > f` succeeds   → the artefact EXISTS and is EMPTY (17 of 30)
#
# `[[ -e ]]` and `[[ -r ]]` are true for the second, which is why F31's first
# guard never fired. The probe therefore writes a token and READS IT BACK.
#
# REPRODUCING THE APFS SHAPE ON LINUX. /dev/full is exactly it: a write returns
# ENOSPC, and a read comes back empty. That is the whole shape — "the write did
# not stick" — expressed with a device rather than by filling a disk, so this
# test needs no root, no loopback mount, and leaves nothing behind.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$TESTS_DIR/falsify/run.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$RUN" ]] || { printf 'SCAFFOLD-FAILED: no falsify/run.sh at %s\n' "$RUN"; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# run.sh is a script, not a library; IT_SOURCE_ONLY has no equivalent here, so
# the functions are exercised through a helper that sources it the way
# tests/test-falsify-run.sh already does.
# NO FALSIFY_SOURCE_ONLY: that variable exists nowhere in run.sh, which guards
# itself with `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`. Setting it steered nothing
# and implied a mechanism that does not exist; the five other `. "$RUN"` sites
# in this file correctly omit it.
callfn() { bash -c '. "$1"; shift; "$@"' _ "$RUN" "$@"; }

# ── 1. the probe, in the three states that matter ────────────────────────────
healthy="$TMP/healthy"; mkdir -p "$healthy"
if callfn fr_scratch_intact "$healthy"; then
  pass "fr_scratch_intact accepts a healthy directory"
else
  fail "fr_scratch_intact accepts a healthy directory"
fi

# The HFS+ shape: the write cannot happen at all.
#
# NON-ROOT ONLY. `chmod 500` does not constrain uid 0, so as root the write
# succeeds and this case cannot be posed at all — it would assert that a
# writable directory is unwritable. The suite runs as root in exactly one arm,
# CI's `suite-floor` container, where actions/checkout has made the tree
# root-owned; everywhere else it runs as a normal user. Skipped rather than
# faked, and the APFS case below — the one that matters, and the shape the field
# report matches — is unaffected because ENOSPC ignores uid.
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'SKIP: the unwritable-directory case needs a non-root uid — chmod does not constrain root\n'
else
  unwritable="$TMP/unwritable"; mkdir -p "$unwritable"; chmod 500 "$unwritable"
  if callfn fr_scratch_intact "$unwritable"; then
    fail "fr_scratch_intact rejects a directory it cannot write to"
  else
    pass "fr_scratch_intact rejects a directory it cannot write to"
  fi
  chmod 700 "$unwritable"
fi

# THE APFS SHAPE, and the one an existence check misses: the write SUCCEEDS as
# far as the shell is concerned, and nothing comes back. /dev/full gives exactly
# that. The probe file is pre-created as a symlink so the helper's own
# `printf > "$probe"` lands on the device.
apfs="$TMP/apfs"; mkdir -p "$apfs"
ln -sf /dev/full "$apfs/.fr-scratch-probe.$$"
# The premise, asserted rather than assumed — if this shell's write to /dev/full
# did NOT look like a full disk, the case below would prove nothing.
if printf 'x' > "$apfs/.fr-scratch-probe.$$" 2>/dev/null; then
  fail "fixture: writing to /dev/full must fail — it did not, so the APFS case cannot be posed here"
else
  pass "fixture: /dev/full reproduces a write that cannot stick"
fi
# fr_scratch_intact computes its own probe name from $BASHPID, so point that one
# at the device too.
apfs2="$TMP/apfs2"; mkdir -p "$apfs2"
apfs_out="$(
  # shellcheck disable=SC2016
  bash -c '
    . "$1"; d="$2"
    ln -sf /dev/full "$d/.fr-scratch-probe.$BASHPID"
    fr_scratch_intact "$d" && echo INTACT || echo BROKEN
  ' _ "$RUN" "$apfs2" 2>/dev/null
)"
if [[ "$apfs_out" == "BROKEN" ]]; then
  pass "fr_scratch_intact rejects the APFS shape: a write that returns nothing on read-back"
else
  fail "fr_scratch_intact rejects the APFS shape (got '$apfs_out')"
fi

# THE RESERVE BAND — the shape a ~25-byte probe cannot see, and the reason this
# guard needed a second fix. Measured on a real APFS volume 2026-08-30 (a
# 20 MB sparse image driven into its reserve): `df` reported 1176 KB free while
# a 25-byte write SUCCEEDED, 96 KiB SUCCEEDED, and 128 KiB came back TRUNCATED.
# The token-sized probe read back INTACT there, so the verdict stayed KILLED —
# this guard's own defect, of exactly the class it exists to catch.
#
# `ulimit -f` reproduces that band with no privileges, no disk image and no
# platform branch: under a small file-size limit a tiny write sticks and a block
# write is truncated. That equivalence is not assumed — both were run side by
# side against the real APFS volume, and the two probes agreed on both:
#
#            real APFS reserve band     ulimit -f 1
#   old      INTACT (false kill)        INTACT (false kill)
#   new      fires                      fires
band="$TMP/band"; mkdir -p "$band"
band_out="$(
  # shellcheck disable=SC2016
  bash -c '
    trap "" XFSZ
    ulimit -f 1 2>/dev/null || { echo NOLIMIT; exit 0; }
    . "$1"; d="$2"
    # THE PREMISE, asserted rather than assumed: a tiny write must still stick
    # here. If it does not, this is an ordinary full disk — a case the /dev/full
    # arm above already covers — and it would prove nothing about the band.
    printf x > "$d/.tiny" 2>/dev/null || { echo NOSMALL; exit 0; }
    [[ "$(wc -c < "$d/.tiny" | tr -d " ")" == "1" ]] || { echo NOSMALL; exit 0; }
    rm -f "$d/.tiny"
    fr_scratch_intact "$d" && echo INTACT || echo BROKEN
  ' _ "$RUN" "$band" 2>/dev/null
)"
case "$band_out" in
  NOLIMIT)
    printf 'SKIP: this shell cannot set ulimit -f, so the reserve band cannot be posed here\n' ;;
  NOSMALL)
    fail "fixture: under ulimit -f a small write must still stick — it did not, so the band case cannot be posed here" ;;
  BROKEN)
    pass "fixture: ulimit -f poses the band — a small write sticks"
    pass "fr_scratch_intact rejects the reserve band: a token-sized write sticks, a block write does not" ;;
  *)
    fail "fr_scratch_intact rejects the reserve band (got '$band_out')" ;;
esac
# Nothing may be left behind there either — the truncated probe included.
# ONLY WHEN THE PROBE ACTUALLY RAN. On the NOLIMIT path above, fr_scratch_intact
# was never called against $band and the directory is trivially empty, so this
# reported a property of a skipped test as a PASS. A skip is reported as a skip.
band_left="$(ls -A "$band" | wc -l | tr -d ' ')"
if [[ "$band_out" == NOLIMIT* ]]; then
  printf 'SKIP: the probe leaves nothing behind after a truncated write — no reserve band was posed\n'
elif [[ "$band_left" == "0" ]]; then
  pass "the probe leaves nothing behind after a truncated write"
else
  fail "the probe leaves nothing behind after a truncated write — found $band_left file(s)"
fi

# It must also clean up after itself, or a probe on the KILLED path litters the
# scratch once per kill — hundreds of files in a corpus run.
probe_left="$(ls -A "$healthy" | wc -l | tr -d ' ')"
if [[ "$probe_left" == "0" ]]; then
  pass "the probe leaves nothing behind"
else
  fail "the probe leaves nothing behind — found $probe_left file(s) in the probed directory"
fi

# ── 2. the verdict: a failing oracle on a broken scratch is NOT a kill ────────
# This is the defect itself. rc=1 with a FAIL: line is the shape that scored
# KILLED for four injected damages on an unmutated tree.
outfile="$TMP/oracle.log"; printf 'FAIL: something\n' > "$outfile"

healthy2="$TMP/healthy2"; mkdir -p "$healthy2"
v_healthy="$(
  bash -c '. "$1"; FR_SCRATCH="$2"; falsify_verdict 1 "$3" 0; printf "%s|%s" "$FALSIFY_VERDICT" "$FALSIFY_SIGNAL"' \
    _ "$RUN" "$healthy2" "$outfile" 2>/dev/null
)"
if [[ "$v_healthy" == KILLED* ]]; then
  pass "a failing oracle on a HEALTHY scratch is still scored KILLED"
else
  fail "a failing oracle on a healthy scratch is still scored KILLED (got '$v_healthy')"
fi

broken="$TMP/broken"; mkdir -p "$broken"
v_broken="$(
  bash -c '
    . "$1"; FR_SCRATCH="$2"
    ln -sf /dev/full "$FR_SCRATCH/.fr-scratch-probe.$BASHPID"
    falsify_verdict 1 "$3" 0
    printf "%s|%s" "$FALSIFY_VERDICT" "$FALSIFY_SIGNAL"' \
    _ "$RUN" "$broken" "$outfile" 2>/dev/null
)"
if [[ "$v_broken" == UNPROVEN* ]]; then
  pass "the same failing oracle on a BROKEN scratch is UNPROVEN, not a kill"
else
  fail "the same failing oracle on a broken scratch is UNPROVEN, not a kill (got '$v_broken')"
fi
# The channel must name itself, because UNPROVEN already has three sub-channels
# and a reader has to know which one fired — that distinction is what F27 and
# the ledger's check B are built on.
if [[ "$v_broken" == *artefact* ]]; then
  pass "the unproven verdict names the artefact channel"
else
  fail "the unproven verdict names the artefact channel (got '$v_broken')"
fi

# ── 3. the guard must not reach the verdicts it has no business touching ─────
# A SURVIVED verdict observed nothing failing, so there is no environmental
# failure to misattribute; probing there would only add a write to the hot loop.
: > "$TMP/clean.log"
v_surv="$(
  bash -c '
    . "$1"; FR_SCRATCH="$2"
    ln -sf /dev/full "$FR_SCRATCH/.fr-scratch-probe.$BASHPID"
    falsify_verdict 0 "$3" 0
    printf "%s|%s" "$FALSIFY_VERDICT" "$FALSIFY_SIGNAL"' \
    _ "$RUN" "$broken" "$TMP/clean.log" 2>/dev/null
)"
if [[ "$v_surv" == SURVIVED* ]]; then
  pass "a SURVIVED verdict is unaffected by a broken scratch"
else
  fail "a SURVIVED verdict is unaffected by a broken scratch (got '$v_surv')"
fi

# And with FR_SCRATCH unset — every existing caller in the hermetic tests — the
# verdict must behave exactly as before, or this guard breaks the suite that
# exercises it.
v_unset="$(
  bash -c '. "$1"; unset FR_SCRATCH; falsify_verdict 1 "$2" 0; printf "%s|%s" "$FALSIFY_VERDICT" "$FALSIFY_SIGNAL"' \
    _ "$RUN" "$outfile" 2>/dev/null
)"
if [[ "$v_unset" == KILLED* ]]; then
  pass "with no scratch configured the verdict is unchanged (KILLED)"
else
  fail "with no scratch configured the verdict is unchanged (got '$v_unset')"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
