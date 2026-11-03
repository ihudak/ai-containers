#!/usr/bin/env bash
# Tests refresh-ipset-allowlist.sh, the restricted firewall's allowlist loader:
# every 60 s it resolves allowlist-domains.txt and reloads the two ipsets the
# iptables OUTPUT chain matches. Until this test it was GREPPED-ONLY in the
# falsify tier — covered by integration cases that need NET_ADMIN, and by no
# assertion anyone had seen fail (feature-gaps review GAP-3).
#
# Hermetic: the script runs against a fake `ipset` that keeps each set as a file
# and a fake `getent` that answers from a table, on a PATH holding nothing else
# it needs but awk and sort, so a missing command is really missing. No root, no
# network, no kernel.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/refresh-ipset-allowlist.sh" ]] && ENGINE="$REPO_DIR/base"
SCRIPT="$ENGINE/refresh-ipset-allowlist.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

bash -n "$SCRIPT" && pass "refresh-ipset-allowlist.sh bash -n" || fail "refresh-ipset-allowlist.sh bash -n"

BASH_BIN="$(command -v bash)"
# Every tool the script needs, as its own directory, so a case can leave one out.
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for t in bash awk sort; do
  p="$(command -v "$t")" || { printf 'SCAFFOLD-FAILED: no %s on PATH\n' "$t"; exit 1; }
  ln -s "$p" "$TOOLS/$t"
done

# fake ipset: one file per set under $IPSET_STATE (first line: family, then one
# entry per line), every call appended to $IPSET_STATE/log. Like the real one it
# refuses to create an existing set or add an existing entry without -exist, and
# refuses an entry of the wrong family.
# The fakes run on the test's own PATH, not the script's: the script's PATH is
# only $TOOLS, and the fakes themselves need head, tail, grep and mv.
fake_head() { printf '#!%s\nPATH=%q\n' "$BASH_BIN" "$PATH"; }
{ fake_head; cat <<'FAKE'
s="$IPSET_STATE"; printf '%s\n' "$*" >> "$s/log"
exist=0; for a in "$@"; do [[ "$a" == -exist ]] && exist=1; done
case "$1" in
  create)
    [[ -f "$s/set.$2" ]] && { (( exist )) && exit 0; echo "ipset: set $2 exists" >&2; exit 1; }
    printf '%s\n' "$5" > "$s/set.$2" ;;
  flush)   [[ -f "$s/set.$2" ]] || exit 1; head -n1 "$s/set.$2" > "$s/f" && mv "$s/f" "$s/set.$2" ;;
  add)
    [[ -f "$s/set.$2" ]] || { echo "ipset: no set $2" >&2; exit 1; }
    fam="$(head -n1 "$s/set.$2")"
    if [[ "$fam" == inet && "$3" == *:* ]] || [[ "$fam" == inet6 && "$3" != *:* ]]; then
      echo "ipset: $3 is not $fam" >&2; exit 1
    fi
    if grep -qxF -- "$3" <(tail -n +2 "$s/set.$2"); then (( exist )) && exit 0; echo "ipset: $3 already in $2" >&2; exit 1; fi
    printf '%s\n' "$3" >> "$s/set.$2" ;;
  swap)    [[ -f "$s/set.$2" && -f "$s/set.$3" ]] || exit 1
           mv "$s/set.$2" "$s/x" && mv "$s/set.$3" "$s/set.$2" && mv "$s/x" "$s/set.$3" ;;
  destroy) [[ -f "$s/set.$2" ]] || exit 1; rm -f "$s/set.$2" ;;
  *) echo "fake ipset: unexpected $*" >&2; exit 1 ;;
esac
FAKE
} > "$TOOLS/ipset"
# fake getent: `getent ahostsv4|ahostsv6 NAME` prints what $GETENT_TABLE says
# NAME resolves to, three lines per address (STREAM/DGRAM/RAW) as glibc's does;
# exit 2, no output, when it has nothing — glibc's "not found".
{ fake_head; cat <<'FAKE'
printf '%s\n' "$*" >> "$IPSET_STATE/getent.log"
db="$1" name="$2" hit=0
while read -r d n ip; do
  [[ "$d" == "$db" && "$n" == "$name" ]] || continue
  hit=1; for k in STREAM DGRAM RAW; do printf '%-15s %s %s\n' "$ip" "$k" "$name"; done
done < "$GETENT_TABLE"
(( hit )) || exit 2
FAKE
} > "$TOOLS/getent"
chmod +x "$TOOLS/ipset" "$TOOLS/getent"

cat > "$TMP/table" <<'EOF'
ahostsv4 api.example.com 192.0.2.20
ahostsv4 api.example.com 192.0.2.10
ahostsv4 api.example.com 192.0.2.20
ahostsv6 api.example.com 2001:db8::20
ahostsv4 v4only.example.com 198.51.100.7
ahostsv6 v6only.example.com 2001:db8::66
EOF

# run_refresh <case> <domains-text> <cidrs-text> [extra args…] — fresh state,
# runs the script on PATH=$TOOLS (+ any $EXTRA_PATH), leaves out=/rc=/state.
run_refresh() {
  local c="$1" dom="$2" cid="$3"; shift 3
  state="$TMP/$c"; mkdir -p "$state"
  printf '%s' "$dom" > "$state/domains"; printf '%s' "$cid" > "$state/cidrs"
  out="$(cd "$state" && IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" \
         bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" "$@" 2>&1)"; rc=$?
}
members() { tail -n +2 "$state/set.$1" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# ── R1: a domains file and a cidrs file go into the two sets ─────────────────
run_refresh r1 $'# comment\n\n   api.example.com   \n  # indented comment\n203.0.113.5\n203.0.113.0/24\n2001:db8:1::/48\nunknown.example.com\nv4only.example.com\nv6only.example.com' \
               $'# cidrs\n10.0.0.0/8\n\n 172.16.0.1 \nfd00::/8\n100.64.0.0/10'
[[ $rc -eq 0 ]] && pass "R1 a valid allowlist loads (rc 0)" || fail "R1 a valid allowlist loads — rc=$rc: $out"
want4="10.0.0.0/8 100.64.0.0/10 172.16.0.1 192.0.2.10 192.0.2.20 198.51.100.7 203.0.113.0/24 203.0.113.5 "
want6="2001:db8:1::/48 2001:db8::20 2001:db8::66 fd00::/8 "
[[ "$(members allowed_ipv4)" == "$want4" ]] && pass "R1 allowed_ipv4 holds exactly the IPv4 literals, CIDRs and resolved addresses" \
  || fail "R1 allowed_ipv4 is '$(members allowed_ipv4)', want '$want4'"
[[ "$(members allowed_ipv6)" == "$want6" ]] && pass "R1 allowed_ipv6 holds exactly the IPv6 literals and resolved addresses" \
  || fail "R1 allowed_ipv6 is '$(members allowed_ipv6)', want '$want6'"
grep -q '^ahostsv4 api.example.com$' "$state/getent.log" \
  && pass "R1 a name is looked up trimmed" || fail "R1 'api.example.com' was not looked up as such: $(tr '\n' ';' < "$state/getent.log")"
if grep -q 'comment\|203\.0\.113\|2001:db8:1::' "$state/getent.log"; then
  fail "R1 comments or address literals were sent to getent: $(tr '\n' ';' < "$state/getent.log")"
else pass "R1 comments and literals are never resolved"; fi
grep -q 'unknown.example.com' <<<"$out" && pass "R1 a name that resolves to nothing is warned about" \
  || fail "R1 no warning for unknown.example.com: $out"
grep -q 'api.example.com\|v4only\|v6only' <<<"$out" \
  && fail "R1 a name that resolved was warned about: $out" || pass "R1 names that resolve are not warned about"
# 'v6only' has no IPv4 and 'v4only' no IPv6; each still loads (one family is enough).
sets=("$state"/set.*)
[[ ${#sets[@]} -eq 2 ]] && pass "R1 only the two live sets remain (temporary sets destroyed)" \
  || fail "R1 sets left behind: ${sets[*]##*/}"

# ── R2: the reload is a swap — stale entries go, the live set is never flushed ─
state="$TMP/r2"; mkdir -p "$state"
printf 'inet\n192.0.2.99\n' > "$state/set.allowed_ipv4"; printf 'inet6\n2001:db8::99\n' > "$state/set.allowed_ipv6"
printf '203.0.113.5\n' > "$state/domains"; printf '2001:db8:2::/48\n' > "$state/cidrs"
out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(members allowed_ipv4)" == "203.0.113.5 " && "$(members allowed_ipv6)" == "2001:db8:2::/48 " ]] \
  && pass "R2 a reload replaces the live sets' contents, stale entries gone" \
  || fail "R2 rc=$rc v4='$(members allowed_ipv4)' v6='$(members allowed_ipv6)': $out"
if grep -qE '^flush allowed_ipv(4|6)( |$)' "$state/log"; then
  fail "R2 a live set was flushed — traffic drops until it is refilled: $(grep '^flush' "$state/log" | tr '\n' ';')"
else pass "R2 the live sets are never flushed"; fi
grep -qx 'swap allowed_ipv4_tmp allowed_ipv4' "$state/log" && grep -qx 'swap allowed_ipv6_tmp allowed_ipv6' "$state/log" \
  && pass "R2 both families are swapped in" || fail "R2 no swap of both sets: $(tr '\n' ';' < "$state/log")"
[[ ! -e "$state/set.allowed_ipv4_tmp" && ! -e "$state/set.allowed_ipv6_tmp" ]] \
  && pass "R2 the old sets are destroyed after the swap" || fail "R2 a _tmp set survived the reload"

# ── R3: a stale _tmp set from a reload that died is emptied before reuse ─────
state="$TMP/r3"; mkdir -p "$state"
printf 'inet\n192.0.2.77\n' > "$state/set.allowed_ipv4_tmp"; printf 'inet6\n2001:db8::77\n' > "$state/set.allowed_ipv6_tmp"
printf '203.0.113.5\n' > "$state/domains"; printf '2001:db8:2::/48\n' > "$state/cidrs"
out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(members allowed_ipv4)" == "203.0.113.5 " && "$(members allowed_ipv6)" == "2001:db8:2::/48 " ]] \
  && pass "R3 leftovers of an interrupted reload never reach the live sets" \
  || fail "R3 rc=$rc v4='$(members allowed_ipv4)' v6='$(members allowed_ipv6)': $out"

# ── R4: an invalid cidrs line refuses, and the live sets are left as they were ─
for bad in 'not-an-address' '10.0.0.0/33' '10.0.0/8'; do
  state="$TMP/r4.$RANDOM"; mkdir -p "$state"
  printf 'inet\n192.0.2.99\n' > "$state/set.allowed_ipv4"; printf 'inet6\n2001:db8::99\n' > "$state/set.allowed_ipv6"
  printf '203.0.113.5\n' > "$state/domains"; printf '10.1.0.0/16\n%s\n' "$bad" > "$state/cidrs"
  out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" 2>&1)"; rc=$?
  [[ $rc -eq 1 ]] && grep -qF "Invalid IP address or CIDR in $state/cidrs: $bad" <<<"$out" \
    && pass "R4 cidrs line '$bad' is refused by name (rc 1)" || fail "R4 cidrs line '$bad': rc=$rc: $out"
  [[ "$(members allowed_ipv4)" == "192.0.2.99 " && "$(members allowed_ipv6)" == "2001:db8::99 " ]] \
    && pass "R4 after '$bad' the live sets are untouched" \
    || fail "R4 after '$bad' v4='$(members allowed_ipv4)' v6='$(members allowed_ipv6)'"
done

# ── R5: the last line counts even with no newline after it ───────────────────
run_refresh r5 'v4only.example.com' '10.9.0.0/16'
[[ $rc -eq 0 && "$(members allowed_ipv4)" == "10.9.0.0/16 198.51.100.7 " ]] \
  && pass "R5 an unterminated last line in either file is read" \
  || fail "R5 rc=$rc v4='$(members allowed_ipv4)': $out"

# ── R6: set names come from arguments 3 and 4 ────────────────────────────────
run_refresh r6 '203.0.113.5' '2001:db8:2::/48' v4name v6name
[[ $rc -eq 0 && "$(members v4name)" == "203.0.113.5 " && "$(members v6name)" == "2001:db8:2::/48 " && ! -e "$state/set.allowed_ipv4" ]] \
  && pass "R6 the set names given as arguments are the ones loaded" \
  || fail "R6 rc=$rc v4name='$(members v4name)' v6name='$(members v6name)': $out"
[[ "$(head -n1 "$state/set.v4name")" == inet && "$(head -n1 "$state/set.v6name")" == inet6 ]] \
  && pass "R6 each set is created with its own family" || fail "R6 families: $(head -n1 "$state/set.v4name") / $(head -n1 "$state/set.v6name")"

# ── R7: missing inputs and missing commands refuse before touching any set ───
state="$TMP/r7a"; mkdir -p "$state"; : > "$state/cidrs"
out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/nope" "$state/cidrs" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -qF "Domains file not found: $state/nope" <<<"$out" && [[ ! -e "$state/log" ]] \
  && pass "R7 a missing domains file refuses (rc 1), no ipset call" || fail "R7 missing domains file: rc=$rc: $out"
state="$TMP/r7b"; mkdir -p "$state"; : > "$state/domains"
out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/nope" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -qF "CIDR file not found: $state/nope" <<<"$out" && [[ ! -e "$state/log" ]] \
  && pass "R7 a missing cidrs file refuses (rc 1), no ipset call" || fail "R7 missing cidrs file: rc=$rc: $out"
for missing in ipset getent; do
  NOTOOL="$TMP/no-$missing"; mkdir -p "$NOTOOL"
  for t in bash awk sort ipset getent; do [[ "$t" == "$missing" ]] || ln -s "$TOOLS/$t" "$NOTOOL/$t"; done
  state="$TMP/r7-$missing"; mkdir -p "$state"; printf '203.0.113.5\n' > "$state/domains"; : > "$state/cidrs"
  out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$NOTOOL" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" 2>&1)"; rc=$?
  [[ $rc -eq 1 ]] && grep -qF "Required command not found: $missing" <<<"$out" && ! ls "$state"/set.* >/dev/null 2>&1 \
    && pass "R7 no $missing on PATH refuses (rc 1) before any set is made" || fail "R7 no $missing: rc=$rc: $out"
done

# ── R8: an IPv4 CIDR with an impossible mask is not taken as an address ──────
state="$TMP/r8"; mkdir -p "$state"
printf 'inet\n192.0.2.99\n' > "$state/set.allowed_ipv4"; printf 'inet6\n2001:db8::99\n' > "$state/set.allowed_ipv6"
# As a domains line it is looked up as a name, resolves to nothing and is
# warned about; it must not reach ipset as an address.
printf '192.0.2.0/40\n203.0.113.5\n' > "$state/domains"; : > "$state/cidrs"
out="$(IPSET_STATE="$state" GETENT_TABLE="$TMP/table" PATH="$TOOLS" bash "$ENGINE/refresh-ipset-allowlist.sh" "$state/domains" "$state/cidrs" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(members allowed_ipv4)" == "203.0.113.5 " ]] && grep -q '192.0.2.0/40' <<<"$out" \
  && pass "R8 an out-of-range mask in the domains file is a name that resolves to nothing" \
  || fail "R8 rc=$rc v4='$(members allowed_ipv4)': $out"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
