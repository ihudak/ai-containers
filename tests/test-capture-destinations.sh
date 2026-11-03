#!/usr/bin/env bash
# Tests capture-agent-destinations.sh, discovery mode's packet capture: `start`
# runs tcpdump in the background and records its pid, `stop` ends it and
# extracts the DNS names and TLS SNI hostnames, `extract` and `status` do what
# they say. Until this test it was GREPPED-ONLY in the falsify tier, covered
# only by integration cases (feature-gaps review GAP-3).
#
# Hermetic: fake tcpdump (sleeps until killed, writes a marker pcap) and fake
# tshark (answers from a fixture by the -Y filter it is given), no root, no
# network.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/capture-agent-destinations.sh" ]] && ENGINE="$REPO_DIR/base"
SCRIPT="$ENGINE/capture-agent-destinations.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# A tcpdump left running by a failed case must not outlive the test.
# Every fake tcpdump records its own pid in <case>/started.<pid> as it starts,
# so this reaps each one whether or not a pid file still names it (a damaged
# script may start two, or never run `stop`).
cleanup() {
  local f
  for f in "$TMP"/*/started.*; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

bash -n "$SCRIPT" && pass "capture-agent-destinations.sh bash -n" || fail "capture-agent-destinations.sh bash -n"

BASH_BIN="$(command -v bash)"
BIN="$TMP/bin"; mkdir -p "$BIN"
# fake tcpdump: records its arguments, writes a pcap marker to its -w file, and
# waits to be killed — the way the real one runs until `stop`.
{ printf '#!%s\n' "$BASH_BIN"; cat <<'FAKE'
w=""; prev=""
for a in "$@"; do [[ "$prev" == -w ]] && w="$a"; prev="$a"; done
printf '%s\n' "$*" > "$CAP_STATE/tcpdump.args"
printf 'PCAP\n' > "$w"
printf '%s\n' "$$" > "$CAP_STATE/started.$$"
trap 'printf "%s\n" TERM > "$CAP_STATE/tcpdump.term"; exit 0' TERM
while :; do sleep 0.1; done
FAKE
} > "$BIN/tcpdump"
# fake tshark: `-r FILE -Y FILTER …` prints the fixture's lines for that filter,
# in a deliberately unsorted order with a duplicate, and logs what it read.
{ printf '#!%s\n' "$BASH_BIN"; cat <<'FAKE'
r="" y="" prev=""
for a in "$@"; do
  [[ "$prev" == -r ]] && r="$a"; [[ "$prev" == -Y ]] && y="$a"; prev="$a"
done
printf '%s|%s\n' "$r" "$y" >> "$CAP_STATE/tshark.log"
case "$y" in
  dns.qry.name) printf 'zeta.example.com\napi.example.com\nzeta.example.com\n' ;;
  tls.handshake.extensions_server_name) printf 'sni-b.example.com\nsni-a.example.com\nsni-b.example.com\n' ;;
esac
FAKE
} > "$BIN/tshark"
chmod +x "$BIN/tcpdump" "$BIN/tshark"
# A PATH with the fakes first and nothing else of theirs (no real tcpdump/tshark).
SYS="$TMP/sys"; mkdir -p "$SYS"
for t in bash cat sort mkdir rm kill nohup sleep; do
  p="$(command -v "$t")" && [[ "$p" == /* ]] && ln -s "$p" "$SYS/$t"
done

run_cap() {   # run_cap <PATH> <args…>  → out, rc
  local path="$1"; shift
  out="$(CAP_STATE="$STATE" PATH="$path" bash "$ENGINE/capture-agent-destinations.sh" "$@" 2>&1)"; rc=$?
}
wait_for() { local _; for _ in $(seq 1 50); do [[ -e "$1" ]] && return 0; sleep 0.1; done; return 1; }

# ── C1: start launches tcpdump in the background and records it ──────────────
STATE="$TMP/c1"; mkdir -p "$STATE"; CAP="$STATE/capture"
run_cap "$BIN:$SYS" start "$CAP"
[[ $rc -eq 0 && -d "$CAP" ]] && pass "C1 start succeeds and makes the capture directory" || fail "C1 start rc=$rc: $out"
pid="$(cat "$CAP/tcpdump.pid" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
  && pass "C1 the pid file names a running tcpdump" || fail "C1 pid file '$pid' is not a running process"
grep -qF "Capture started with PID $pid" <<<"$out" && grep -qF "Writing pcap to $CAP/agent-traffic.pcap" <<<"$out" \
  && pass "C1 start says which pid and which pcap" || fail "C1 start output: $out"
wait_for "$STATE/tcpdump.args"
args="$(cat "$STATE/tcpdump.args" 2>/dev/null)"
[[ "$args" == "-i any -n -s 0 -U -w $CAP/agent-traffic.pcap port 53 or port 443" ]] \
  && pass "C1 tcpdump captures DNS and TLS on every interface into the pcap" || fail "C1 tcpdump args: '$args'"
[[ -f "$CAP/tcpdump.log" ]] && pass "C1 the capture log exists" || fail "C1 no tcpdump.log"

# ── C2: a second start does not launch a second tcpdump ──────────────────────
before="$(ls "$STATE"/started.* 2>/dev/null | wc -l)"
run_cap "$BIN:$SYS" start "$CAP"
sleep 0.3
after="$(ls "$STATE"/started.* 2>/dev/null | wc -l)"
[[ $rc -eq 0 && "$before" -eq "$after" && "$(cat "$CAP/tcpdump.pid")" == "$pid" ]] \
  && grep -qF "Capture already running with PID $pid" <<<"$out" \
  && pass "C2 start while running reports the running pid and starts nothing" \
  || fail "C2 rc=$rc started $before→$after pid=$(cat "$CAP/tcpdump.pid"): $out"

# ── C3: status while running ─────────────────────────────────────────────────
run_cap "$BIN:$SYS" status "$CAP"
[[ $rc -eq 0 ]] && grep -qF "Capture is running with PID $pid" <<<"$out" && grep -qF "Capture file: $CAP/agent-traffic.pcap" <<<"$out" \
  && pass "C3 status reports the running capture and its file" || fail "C3 status rc=$rc: $out"

# ── C4: stop kills tcpdump, removes the pid file, and extracts ───────────────
run_cap "$BIN:$SYS" stop "$CAP"
[[ $rc -eq 0 ]] && pass "C4 stop succeeds" || fail "C4 stop rc=$rc: $out"
wait_for "$STATE/tcpdump.term" && ! kill -0 "$pid" 2>/dev/null \
  && pass "C4 tcpdump was signalled and is gone" || fail "C4 tcpdump $pid still running or never got TERM"
[[ ! -e "$CAP/tcpdump.pid" ]] && pass "C4 the pid file is removed" || fail "C4 pid file left behind"
[[ "$(cat "$CAP/agent-dns.txt" 2>/dev/null | tr '\n' ' ')" == "api.example.com zeta.example.com " ]] \
  && pass "C4 DNS names extracted, sorted and deduplicated" || fail "C4 agent-dns.txt: '$(cat "$CAP/agent-dns.txt" 2>/dev/null | tr '\n' ' ')'"
[[ "$(cat "$CAP/agent-sni.txt" 2>/dev/null | tr '\n' ' ')" == "sni-a.example.com sni-b.example.com " ]] \
  && pass "C4 SNI hostnames extracted, sorted and deduplicated" || fail "C4 agent-sni.txt: '$(cat "$CAP/agent-sni.txt" 2>/dev/null | tr '\n' ' ')'"
grep -qxF "$CAP/agent-traffic.pcap|dns.qry.name" "$STATE/tshark.log" \
  && grep -qxF "$CAP/agent-traffic.pcap|tls.handshake.extensions_server_name" "$STATE/tshark.log" \
  && pass "C4 both extractions read the capture's own pcap" || fail "C4 tshark reads: $(tr '\n' ';' < "$STATE/tshark.log")"
grep -qF "DNS queries saved to $CAP/agent-dns.txt" <<<"$out" && grep -qF "TLS SNI hostnames saved to $CAP/agent-sni.txt" <<<"$out" \
  && pass "C4 stop names both output files" || fail "C4 stop output: $out"

# ── C5: status when stopped ──────────────────────────────────────────────────
run_cap "$BIN:$SYS" status "$CAP"
[[ $rc -eq 0 ]] && grep -qxF "Capture is not running" <<<"$out" && grep -qF "Capture file: $CAP/agent-traffic.pcap" <<<"$out" \
  && pass "C5 status after stop: not running, file still named" || fail "C5 status rc=$rc: $out"
# A pid file naming a process that is gone does not count as running.
printf '999999999\n' > "$CAP/tcpdump.pid"
run_cap "$BIN:$SYS" status "$CAP"
grep -qxF "Capture is not running" <<<"$out" && pass "C5 a stale pid file is not a running capture" || fail "C5 stale pid: $out"
rm -f "$CAP/tcpdump.pid"
STATE="$TMP/c5b"; mkdir -p "$STATE"
run_cap "$BIN:$SYS" status "$STATE/empty"
[[ $rc -eq 0 ]] && grep -qxF "Capture is not running" <<<"$out" && ! grep -q 'Capture file' <<<"$out" \
  && pass "C5 status with no capture names no file" || fail "C5 empty status rc=$rc: $out"

# ── C6: stop with nothing running refuses ────────────────────────────────────
STATE="$TMP/c6"; mkdir -p "$STATE/cap"
run_cap "$BIN:$SYS" stop "$STATE/cap"
[[ $rc -eq 1 ]] && grep -qF "No capture PID file found at $STATE/cap/tcpdump.pid" <<<"$out" \
  && pass "C6 stop with no pid file refuses (rc 1)" || fail "C6 rc=$rc: $out"

# ── C7: extract ──────────────────────────────────────────────────────────────
STATE="$TMP/c7"; mkdir -p "$STATE/cap"
run_cap "$BIN:$SYS" extract "$STATE/cap"
[[ $rc -eq 1 ]] && grep -qF "No capture file found at $STATE/cap/agent-traffic.pcap" <<<"$out" && [[ ! -e "$STATE/cap/agent-dns.txt" ]] \
  && pass "C7 extract with no pcap refuses (rc 1) and writes nothing" || fail "C7 no pcap: rc=$rc: $out"
printf 'PCAP\n' > "$STATE/cap/agent-traffic.pcap"
run_cap "$BIN:$SYS" extract "$STATE/cap"
[[ $rc -eq 0 && "$(tr '\n' ' ' < "$STATE/cap/agent-dns.txt")" == "api.example.com zeta.example.com " ]] \
  && pass "C7 extract on an existing pcap writes the lists" || fail "C7 extract rc=$rc: $out"
run_cap "$SYS" extract "$STATE/cap"
[[ $rc -eq 1 ]] && grep -qF "Required command not found: tshark" <<<"$out" \
  && pass "C7 extract with no tshark refuses (rc 1)" || fail "C7 no tshark: rc=$rc: $out"
run_cap "$SYS" start "$STATE/cap"
[[ $rc -eq 1 ]] && grep -qF "Required command not found: tcpdump" <<<"$out" && [[ ! -e "$STATE/cap/tcpdump.pid" ]] \
  && pass "C7 start with no tcpdump refuses (rc 1)" || fail "C7 no tcpdump: rc=$rc: $out"

# ── C8: a capture path that is a file, and an unknown command ────────────────
STATE="$TMP/c8"; mkdir -p "$STATE"; : > "$STATE/afile"
run_cap "$BIN:$SYS" start "$STATE/afile"
[[ $rc -eq 1 ]] && grep -qF "Capture path exists but is not a directory: $STATE/afile" <<<"$out" \
  && pass "C8 a capture path that is a file refuses (rc 1)" || fail "C8 rc=$rc: $out"
run_cap "$BIN:$SYS" bogus "$STATE/x"
[[ $rc -eq 1 ]] && grep -q 'Usage: .*{start|stop|extract|status}' <<<"$out" \
  && pass "C8 an unknown command prints usage (rc 1)" || fail "C8 usage rc=$rc: $out"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
