#!/usr/bin/env bash
# tests/test-exit-trap-ownership.sh — a fixture-removing EXIT trap, in a script
# that forks, must be confined to the process that owns the fixture.
#
# THE RULE IS NOT STYLE. A forked child inherits its parent's EXIT trap, and can
# run it. When that trap is `rm -rf "$TMP"`, the child deletes the fixture the
# PARENT is still using — and the parent then fails on missing files, reporting
# several symptoms of one fact with nothing naming the cause.
#
# That is F30/F32/F64: five sightings over nine days of a falsify control going
# red with `dir=n exists=n size=? left=0`, reproduced 2026-08-30 and traced to
# exactly this. `p_timeout` backgrounds the command it times AND a watchdog
# beside it, so any caller with such a trap hands both children a loaded
# `rm -rf` aimed at its own fixture:
#
#   TRAPFIRE pid=2284480 bashpid=2285462 subshell=1
#            cmd=[local cmd_pid=$!] fn=[p_timeout main]
#
# BASH_SUBSHELL=1, BASHPID != $$ — the trap running in a forked child.
#
# THE FIX, AND WHY $BASHPID. `$$` is the SCRIPT's pid and is unchanged in a
# subshell, so comparing it to itself would guard nothing. `$BASHPID` is the pid
# of the process actually executing:
#
#   TMP="$(mktemp -d)"; TMP_OWNER="$BASHPID"
#   trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
#
# SCOPE, MEASURED RATHER THAN ASSUMED. 52 test files carry a temp-removing EXIT
# trap, and an earlier note of mine put the exposure at "47 files" — that was the
# count matching the trap PATTERN, not the count at risk, and it overstated the
# hazard. A trap can only fire in a child if the script HAS a child: the rule
# below therefore applies to scripts that fork, which at the time of writing is
# six of the fifty-two. A script that gains its first `&` later gains the rule
# with it, which is the whole reason this is a mechanical check and not a sweep.
#
# A file that must keep an unguarded trap opts out in this repo's usual idiom,
# with a reason that is checked rather than assumed:
#
#   # exit-trap-ok: <reason>
#
# on the trap's own line or the line above.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# ── 1. The hazard itself, measured here, so the rule is not an opinion ────────
# Without this the scan below asserts a preference. With it, the cost of an
# unguarded trap is demonstrated in both directions before any file is judged.
haz="$TMP/haz"; mkdir -p "$haz"
cat > "$TMP/unguarded.sh" <<'U'
#!/usr/bin/env bash
TMP="$1"; trap 'rm -rf "$TMP"' EXIT
( : ) &                       # a forked child, exactly as p_timeout makes
wait
[ -d "$TMP" ] && echo PRESENT || echo GONE
U
cat > "$TMP/guarded.sh" <<'G'
#!/usr/bin/env bash
TMP="$1"; TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
( : ) &
wait
[ -d "$TMP" ] && echo PRESENT || echo GONE
G
# The child running the trap's ACTION is the deterministic half of the hazard;
# whether a real child fires it is load-dependent, which is why F64 took nine
# days to see once and why nothing here races it.
cat > "$TMP/fire.sh" <<'F'
#!/usr/bin/env bash
TMP="$1"; shift
if [[ "${1:-}" == "guarded" ]]; then
  TMP_OWNER="$BASHPID"
  trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
else
  trap 'rm -rf "$TMP"' EXIT
fi
action="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
( eval "$action" )            # a real forked child, running what the trap runs
[ -d "$TMP" ] && echo PRESENT || echo GONE
F
chmod +x "$TMP/unguarded.sh" "$TMP/guarded.sh" "$TMP/fire.sh"

d1="$TMP/d1"; mkdir -p "$d1"; r1="$(bash "$TMP/fire.sh" "$d1" unguarded)"
d2="$TMP/d2"; mkdir -p "$d2"; r2="$(bash "$TMP/fire.sh" "$d2" guarded)"
[[ "$r1" == "GONE" ]] \
  && pass "the hazard is real: an unguarded trap run in a forked child destroys the fixture" \
  || fail "the hazard is real: an unguarded trap run in a forked child destroys the fixture (got '$r1')"
[[ "$r2" == "PRESENT" ]] \
  && pass "the guard prevents it: the same action in a child leaves the fixture alone" \
  || fail "the guard prevents it: the same action in a child leaves the fixture alone (got '$r2')"
# And the guard must still clean up for its owner, or it trades one leak for
# another — the shape four tests shipped before run-all.sh grew a leak counter.
d3="$TMP/d3"; mkdir -p "$d3"; bash "$TMP/guarded.sh" "$d3" >/dev/null 2>&1
[[ ! -d "$d3" ]] \
  && pass "a guarded trap still removes the fixture in its owning process" \
  || fail "a guarded trap still removes the fixture in its owning process — it leaked"

# ── 2. The scan ──────────────────────────────────────────────────────────────
# A script is IN SCOPE when it both removes a temp dir from an EXIT trap and
# forks a child. Forking is a line ending in a single `&` (never `&&`), or any
# use of p_timeout, which backgrounds two children of its own.
scanned=0; in_scope=0; offenders=""
while IFS= read -r f; do
  case "$f" in tests/*.sh) ;; *) continue ;; esac
  [[ -f "$REPO_DIR/$f" ]] || continue
  scanned=$((scanned + 1))
  grep -qE "trap .*rm -rf.*EXIT" "$REPO_DIR/$f" || continue
  if ! grep -qE '(^|[^&])&[[:space:]]*$' "$REPO_DIR/$f" && ! grep -q 'p_timeout' "$REPO_DIR/$f"; then
    continue                                   # no child: the trap cannot run anywhere else
  fi
  in_scope=$((in_scope + 1))
  # Guarded, or opted out with a stated reason on the trap line or the one above.
  grep -qE 'BASHPID.*==.*TMP_OWNER|TMP_OWNER.*==.*BASHPID' "$REPO_DIR/$f" && continue
  grep -qE '# exit-trap-ok: *[^ ]' "$REPO_DIR/$f" && continue
  offenders="${offenders}${offenders:+ }$(basename "$f")"
done < <(cd "$REPO_DIR" && git ls-files 'tests/*.sh')

if [[ "$scanned" -gt 20 ]]; then
  pass "the scan read $scanned tracked test script(s)"
else
  fail "the scan read $scanned tracked test script(s) — it is not reading the tree"
fi
# The in-scope count is asserted as non-zero for the same reason: a detector that
# matched nothing would report a clean sweep while checking no file at all.
if [[ "$in_scope" -gt 0 ]]; then
  pass "$in_scope of them both remove a temp dir on EXIT and fork a child"
else
  fail "the scan found no in-scope file — the fork/trap detector matches nothing"
fi
if [[ -z "$offenders" ]]; then
  pass "every in-scope script confines its fixture removal to the owning process"
else
  fail "these scripts fork and carry an UNGUARDED fixture-removing EXIT trap, so a child can delete the fixture the script is still using: $offenders"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
