#!/usr/bin/env bash
# Tests that capture-blocked-traffic.sh actually STARTS — the daemon that gives
# restricted mode its only record of what the firewall dropped — AND that it can
# actually RECORD a blocked packet once started. Those are two separate bugs,
# both pinned here.
#
# Bug 1 (startup): the script runs `set -euo pipefail`, and its allowlist-cache
# build used `grep -v '^\s*#' F | grep -v '^\s*$' | sed …`. When F has no
# non-comment, non-blank line the second grep exits 1, pipefail propagates, and
# `set -e` killed the whole daemon ~150 lines before init_output_files. Nothing was
# logged: no blocked.log, no blocked-domains.txt, no NFLOG watcher, and — worst —
# no SELF-HEALING, so dynamic CDN IPs behind an allowlisted wildcard silently
# stopped being admitted. An empty allowlist is a legal configuration:
# allowlist-proxy-domains.txt is nothing but its two header comments whenever no
# proxy-fragment component is enabled, which is why this was invisible to anyone
# running with copilot/claude-code ON.
#
# Bug 2 (parsing, task-5 2026-08-06): even past startup, the NFLOG/DNS read loops
# used `IFS=$'\t' read`. Tab is IFS WHITESPACE, and bash's `read` collapses RUNS
# of it and strips it from a line's edges. Every real IPv4 packet leaves tshark's
# ipv6.dst field empty, so the true field-output for a blocked TCP packet was
# shaped like "IP\t\tPORT\t" — the doubled tab collapsed to one delimiter, the
# trailing one was stripped, the port landed in the wrong variable, and
# `[[ -z "$dst" || -z "$port" ]] && continue` silently discarded the packet —
# every single one, forever, while the daemon kept announcing itself and creating
# its output files normally. A fake tshark that exits at once proves nothing
# about this path; it survived undetected because nothing before task-5 asserted
# that a real blocked packet produces a real row.
#
# Past those two, what the daemon DECIDES is pinned too (GAP-1): which addresses
# self-healing hands to ipset and into which set, what each output file holds and
# how it deduplicates, the DNS map's cap, and that both read loops end when
# tshark exits.
#
# Hermetic: fake tshark/ipset on PATH, temp capture + internal dirs, no root.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }

# Every daemon this test starts is its own process group (`set -m`, below), so a
# read loop that never ends can be found and killed. The EXIT trap kills any
# group still alive: a test that leaves a spinning loop behind would heat the
# machine long after it reported.
LAUNCHED=()
cleanup() {
  local g
  for g in "${LAUNCHED[@]}"; do kill -KILL -- "-$g" 2>/dev/null; done
  rm -rf "$TMP"
}
# Confined to the owning process: this file forks (fakes started in the
# background), and a child running this trap would remove the fixture the
# test is still using (tests/test-exit-trap-ownership.sh).
TRAP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TRAP_OWNER" ]] && cleanup' EXIT

bash -n "$REPO_DIR/capture-blocked-traffic.sh" \
  && pass "capture-blocked-traffic.sh bash -n" || fail "capture-blocked-traffic.sh bash -n"

# ── The fakes ───────────────────────────────────────────────────────────────────
# tshark replays a scenario: $FAKE_SCN/dns on `-i any` (dns.resp.name, dns.a,
# dns.aaaa) and $FAKE_SCN/nflog on `-i nflog:<group>` (ip.dst, ipv6.dst,
# tcp.dstport, udp.dstport), one packet per line with `;` between fields, and
# exits — so each read loop sees EOF once its feed is spent. A scenario with no
# feed emits nothing, which is the startup-only case.
#
# It honours the `-E separator=<val>` it is given, defaulting to tshark's real
# default (tab), so the separator/`read` pairing tested is the script's own and
# not a separately maintained assumption about it. Bug 2's trigger was exactly a
# line with one field empty: every IPv4 line in the nflog feed below leaves
# ipv6.dst empty, as a real IPv4 packet does, and every A-only response leaves
# dns.aaaa empty. A stub that never leaves a field empty could never catch it.
#
# The nflog side waits for $FAKE_SCN/go, which the test creates once the DNS map
# holds what the scenario needs: in the real container a name is resolved before
# its address is dropped, and without the wait the two loops race.
# $FAKE_SCN/prefill (a line count) stands for a DNS map that has grown over a
# long run: written before the first response, just after the script emptied it.
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tshark" <<'FAKETSHARK'
#!/usr/bin/env bash
sep=$'\t'; iface=""; prev=""
for a in "$@"; do
  case "$prev" in
    -i) iface="$a" ;;
    -E) [[ "$a" == separator=* ]] && sep="${a#separator=}" ;;
  esac
  prev="$a"
done
case "$sep" in /t) sep=$'\t' ;; /s) sep=' ' ;; esac
# What the real one prints on stderr as it attaches, which the daemon keeps in
# tshark-<loop>-errors.log (the integration harness waits on that line).
printf 'Capturing on %s\n' "$iface" >&2
replay() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//;/$sep}"
  done < "$1"
}
[[ -n "${FAKE_SCN:-}" ]] || exit 0
case "$iface" in
  any)
    if [[ -f "$FAKE_SCN/prefill" ]]; then
      awk -v n="$(cat "$FAKE_SCN/prefill")" 'BEGIN {
        for (i = 1; i <= n; i++)
          printf "10.%d.%d.%d prefill%d.example.test\n", int(i / 65536) % 256, int(i / 256) % 256, i % 256, i
      }' >> "$BLOCKED_INTERNAL_DIR/dns-map.txt"
    fi
    [[ -f "$FAKE_SCN/dns" ]] && replay "$FAKE_SCN/dns"
    ;;
  nflog:*)
    if [[ -f "$FAKE_SCN/nflog" ]]; then
      i=0
      while [[ ! -e "$FAKE_SCN/go" ]] && (( i < 600 )); do sleep 0.1; i=$((i + 1)); done
      replay "$FAKE_SCN/nflog"
    fi
    ;;
esac
exit 0
FAKETSHARK
chmod +x "$FAKE_BIN/tshark"
# ipset records every call, so self-healing is observed as the call it makes.
cat > "$FAKE_BIN/ipset" <<'FAKEIPSET'
#!/usr/bin/env bash
[[ -n "${FAKE_SCN:-}" ]] && printf '%s\n' "$*" >> "$FAKE_SCN/ipset.log"
exit 0
FAKEIPSET
chmod +x "$FAKE_BIN/ipset"
# getent answers `ahosts <name>` from $FAKE_SCN/hosts ("<name> <address>..." per
# line), in glibc's shape: one "<address> STREAM <name>" line per address, exit 2
# for a name it does not know. It stands for the container's own resolver, which
# self-healing asks before it trusts a name the DNS map took off the wire (RT-14).
cat > "$FAKE_BIN/getent" <<'FAKEGETENT'
#!/usr/bin/env bash
[[ "${1:-}" == ahosts && -n "${FAKE_SCN:-}" && -f "$FAKE_SCN/hosts" ]] || exit 2
rc=2
while read -r n rest; do
  [[ "$n" == "${2:-}" ]] || continue
  for ip in $rest; do printf '%-15s STREAM %s\n' "$ip" "$n"; rc=0; done
done < "$FAKE_SCN/hosts"
exit "$rc"
FAKEGETENT
chmod +x "$FAKE_BIN/getent"
# rm, only where a scenario sets FAKE_RM_RELINK=<target>: removes as asked, then
# puts a link to <target> where it removed, as a second container writing the same
# directory could between the daemon's removal and its open.
cat > "$FAKE_BIN/rm" <<'FAKERM'
#!/usr/bin/env bash
command -p rm "$@"; rc=$?
if [[ -n "${FAKE_RM_RELINK:-}" ]]; then
  for a in "$@"; do [[ "$a" == -* ]] || ln -s "$FAKE_RM_RELINK" "$a" 2>/dev/null; done
fi
exit "$rc"
FAKERM
chmod +x "$FAKE_BIN/rm"
# The script runs in the container, which has util-linux flock; macOS has none,
# and without it no DNS-map write ever happened. Only where the host lacks one,
# a stand-in that takes no lock: `flock <file> <cmd…>` runs the command.
if ! command -v flock >/dev/null 2>&1; then
  cat > "$FAKE_BIN/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do shift; done
(( $# > 1 )) || exit 0
shift; exec "$@"
FAKEFLOCK
  chmod +x "$FAKE_BIN/flock"
fi

# ── Running the daemon, bounded ─────────────────────────────────────────────────
# The script backgrounds its two read loops and returns at once. Each loop must
# end when tshark exits; one that does not (a `while ! read`) spins forever at
# 100% CPU. So the daemon runs in its own process group (`set -m` makes a
# background job a group leader — portable where `setsid` is not, see
# tests/test-provenance.sh), and a scenario is over when its group is empty.
# That is also the one sync point the outputs need: an empty group means every
# packet was processed.
#
# WAIT is the bound, in 0.1 s ticks. 30 s is headroom against a loaded machine
# (oracle runs on macOS are ~18x slower than on Linux before any contention),
# not an estimate of the work, which takes milliseconds; the polls break on the
# first tick when the daemon is prompt. After the first bound is reached the
# test is already red, so later waits shrink to 1 s: several full waits in one
# run would outlast the falsify tier's per-mutant timeout and turn a kill into
# an UNPROVEN.
WAIT=300

launch() {   # $1 = scenario dir, $2 = domains file, $3 = proxy file, [NAME=value ...]
  local scn="$1"
  mkdir -p "$scn/cap" "$scn/int"
  set -m
  # One subshell exporting the scenario, then the script on a line of its own:
  # derive-targets.sh reads `bash <file>` at command position, and a `bash`
  # behind an `env …` continuation is not one it can see.
  (
    export PATH="$FAKE_BIN:$PATH" BLOCKED_INTERNAL_DIR="$scn/int" \
      ALLOWLIST_DOMAINS_FILE="$2" ALLOWLIST_PROXY_DOMAINS_FILE="$3" FAKE_SCN="$scn"
    for kv in "${@:4}"; do export "${kv?}"; done
    bash "$REPO_DIR/capture-blocked-traffic.sh" "$scn/cap"
  ) >"$scn/stdout" 2>&1 &
  LAUNCH_PGID=$!
  set +m
  LAUNCHED+=("$LAUNCH_PGID")
  # The script itself returns at once, its loops in the background. One that
  # does not (it blocked opening an output, as the daemon did on a FIFO there
  # before RT-13) is stopped at the bound rather than hanging the suite.
  local n=0
  while kill -0 "$LAUNCH_PGID" 2>/dev/null && (( n < WAIT )); do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$LAUNCH_PGID" 2>/dev/null; then
    fail "${scn##*/}: the daemon had not returned after $((n / 10))s (blocked at start?)"
    kill -KILL -- "-$LAUNCH_PGID" 2>/dev/null
    WAIT=10
  fi
  wait "$LAUNCH_PGID"
  LAUNCH_RC=$?
}

await_map() {   # $1 = scenario dir, then the "ip name" lines the DNS map must hold
  local scn="$1" n=0 want missing; shift
  while :; do
    missing=""
    for want in "$@"; do
      grep -qxF "$want" "$scn/int/dns-map.txt" 2>/dev/null || { missing="$want"; break; }
    done
    [[ -z "$missing" ]] && break
    if (( n >= WAIT )); then
      fail "${scn##*/}: the DNS map never held '$missing' after $((n / 10))s — got: $(tr '\n' '|' < "$scn/int/dns-map.txt" 2>/dev/null | cut -c1-300)"
      WAIT=10
      break
    fi
    sleep 0.1; n=$((n + 1))
  done
  : > "$scn/go"
}

await_end() {   # $1 = scenario dir
  local scn="$1" n=0
  while kill -0 -- "-$LAUNCH_PGID" 2>/dev/null && (( n < WAIT )); do
    sleep 0.1; n=$((n + 1))
  done
  if kill -0 -- "-$LAUNCH_PGID" 2>/dev/null; then
    fail "${scn##*/}: a read loop was still running $((n / 10))s after tshark exited (a loop that does not end at EOF spins forever)"
    kill -KILL -- "-$LAUNCH_PGID" 2>/dev/null
    WAIT=10
    return 1
  fi
  pass "${scn##*/}: both read loops end when tshark exits"
}

# Data lines of an output file, without the header the daemon writes first.
# A FIFO there (one the daemon failed to replace) is named, not read: the read
# would wait for a writer forever.
data_lines() { if [[ -p "$1" ]]; then printf '(a FIFO)\n'; else grep -v -e '^#' -e '^$' "$1" 2>/dev/null; fi; }
# blocked.log rows without the timestamp, single-spaced: "PROTO:PORT IP DOMAIN [...]".
log_rows() { awk 'NR > 2 { $1 = ""; sub(/^ /, ""); print }' "$1" 2>/dev/null; }

expect_eq() {   # $1 = label, $2 = expected, $3 = got
  if [[ "$3" == "$2" ]]; then pass "$1"
  else fail "$1 — expected [$(tr '\n' '|' <<<"$2")] got [$(tr '\n' '|' <<<"$3")]"; fi
}

# ── The regression: comments-only allowlists ────────────────────────────────────
# No feed: tshark exits at once, so both read loops see EOF on their first read.
comments_only="$TMP/proxy-comments-only.txt"
printf '# AUTO-GENERATED by build.sh — do not edit directly.\n# Edit files in allowlist-proxy-domains.d/ and run: ./build.sh\n\n' \
  > "$comments_only"
populated="$TMP/domains.txt"
printf '# header\n  github.com  \n\nregistry.npmjs.org\n' > "$populated"

scn="$TMP/startup"
launch "$scn" "$populated" "$comments_only"
await_end "$scn"
[[ "$LAUNCH_RC" == "0" ]] \
  && pass "survives a comments-only proxy-domains file (exit 0)" \
  || fail "survives a comments-only proxy-domains file (exit $LAUNCH_RC)"
grep -q 'Blocked traffic capture started' "$scn/stdout" \
  && pass "announces itself (reached the end of startup)" \
  || fail "announces itself (reached the end of startup) — got: $(cat "$scn/stdout")"
grep -qxF '  self-healing: ON (exact + wildcard domain matching)' "$scn/stdout" \
  && pass "announces self-healing ON by default" \
  || fail "announces self-healing ON by default — got: $(cat "$scn/stdout")"
for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  [[ -f "$scn/cap/$f" ]] \
    && pass "init_output_files created $f" \
    || fail "init_output_files created $f"
done

# ── Both files comments-only — the most degenerate legal config ─────────────────
scn="$TMP/startup-both-comments"
launch "$scn" "$comments_only" "$comments_only"
await_end "$scn"
[[ "$LAUNCH_RC" == "0" ]] \
  && pass "survives when BOTH allowlists are comments-only" \
  || fail "survives when BOTH allowlists are comments-only (exit $LAUNCH_RC)"

# ── A missing file must still be tolerated ──────────────────────────────────────
scn="$TMP/startup-missing"
launch "$scn" "$populated" "$TMP/does-not-exist.txt"
await_end "$scn"
[[ "$LAUNCH_RC" == "0" ]] \
  && pass "survives a missing proxy-domains file" \
  || fail "survives a missing proxy-domains file (exit $LAUNCH_RC)"

# ── The cache content itself must be unchanged by the awk rewrite ───────────────
mixed="$TMP/mixed.txt"
printf '# comment\n  spaced.example.com  \n\n*.wild.example.com\n\t# indented comment\n' > "$mixed"
scn="$TMP/startup-cache"
launch "$scn" "$mixed" "$mixed"
await_end "$scn"
got="$(tr '\n' '|' < "$scn/int/allowed-domains-cache" 2>/dev/null)"
[[ "$got" == "spaced.example.com|*.wild.example.com|" ]] \
  && pass "cache still strips comments/blanks and trims whitespace" \
  || fail "cache still strips comments/blanks and trims whitespace (got '$got')"

# ── Blocked packets, end to end: the rows, the deduplication, self-healing ──────
# One allowlisted name (exact), one wildcard, and names that are neither — one of
# them ending in the wildcard's text without its dot, which a suffix match must
# not take. Each line of the nflog feed is one case:
#   192.0.2.10            exact name               healed into the IPv4 set
#   2001:db8::11          wildcard, IPv6           healed into the IPv6 set
#   192.0.2.11            wildcard, IPv4           healed into the IPv4 set
#   2001:db8::20          AAAA-only response       healed into the IPv6 set
#   192.0.2.12/.13, ::12  one blocked name thrice  logged thrice, listed once
#   192.0.2.14            notwild.example.test     not healed
#   198.51.100.7 twice    UDP, no name             logged twice, listed once
#   198.51.100.8          no port (ICMP)           ignored
#   (no address)          port only                ignored
#   198.51.100.9          both ports               TCP, the TCP port
#   198.51.100.10         TCP, no name             listed
# A response with no name (`;192.0.2.99;`) must not enter the map.
heal_domains="$TMP/heal-domains.txt"; printf '# exact names\nexact.example.test\n' > "$heal_domains"
heal_proxy="$TMP/heal-proxy.txt";     printf '# wildcards\n*.wild.example.test\n' > "$heal_proxy"
write_feeds() {   # $1 = scenario dir
  mkdir -p "$1"
  cat > "$1/dns" <<'DNS'
exact.example.test;192.0.2.10;
deep.sub.wild.example.test,deep.sub.wild.example.test;192.0.2.11;2001:db8::11
blocked.example.test;192.0.2.12,192.0.2.13;2001:db8::12
notwild.example.test;192.0.2.14;
;192.0.2.99;
v6only.wild.example.test;;2001:db8::20
DNS
  cat > "$1/nflog" <<'NFLOG'
192.0.2.10;;443;
;2001:db8::11;443;
192.0.2.11;;443;
;2001:db8::20;443;
192.0.2.12;;443;
192.0.2.13;;8443;
;2001:db8::12;443;
192.0.2.14;;80;
198.51.100.7;;;53
198.51.100.7;;;53
198.51.100.8;;;
;;9999;
198.51.100.9;;8080;5353
198.51.100.10;;22;
NFLOG
  # What the container's resolver answers: the same addresses the wire gave.
  cat > "$1/hosts" <<'HOSTS'
exact.example.test 192.0.2.10
deep.sub.wild.example.test 192.0.2.11 2001:db8::11
v6only.wild.example.test 2001:db8::20
HOSTS
}
map_lines=(
  "192.0.2.10 exact.example.test"
  "192.0.2.11 deep.sub.wild.example.test"
  "2001:db8::11 deep.sub.wild.example.test"
  "192.0.2.12 blocked.example.test"
  "192.0.2.13 blocked.example.test"
  "2001:db8::12 blocked.example.test"
  "192.0.2.14 notwild.example.test"
  "2001:db8::20 v6only.wild.example.test"
)

scn="$TMP/heal-on"
write_feeds "$scn"
launch "$scn" "$heal_domains" "$heal_proxy"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
expect_eq "the DNS map holds every A and AAAA address under its first name, and nothing for a nameless response" \
  "$(printf '%s\n' "${map_lines[@]}")" "$(cat "$scn/int/dns-map.txt" 2>/dev/null)"
expect_eq "self-healing adds exactly the exact and wildcard matches, each to its family's set" \
  "add allowed_ipv4 192.0.2.10 -exist
add allowed_ipv6 2001:db8::11 -exist
add allowed_ipv4 192.0.2.11 -exist
add allowed_ipv6 2001:db8::20 -exist" "$(cat "$scn/ipset.log" 2>/dev/null)"
expect_eq "blocked.log has one row per dropped packet with a port and an address, healed rows marked" \
  "TCP:443 192.0.2.10 exact.example.test (auto-allowed)
TCP:443 2001:db8::11 deep.sub.wild.example.test (auto-allowed)
TCP:443 192.0.2.11 deep.sub.wild.example.test (auto-allowed)
TCP:443 2001:db8::20 v6only.wild.example.test (auto-allowed)
TCP:443 192.0.2.12 blocked.example.test
TCP:8443 192.0.2.13 blocked.example.test
TCP:443 2001:db8::12 blocked.example.test
TCP:80 192.0.2.14 notwild.example.test
UDP:53 198.51.100.7 (no domain)
UDP:53 198.51.100.7 (no domain)
TCP:8080 198.51.100.9 (no domain)
TCP:22 198.51.100.10 (no domain)" "$(log_rows "$scn/cap/blocked.log")"
expect_eq "blocked-domains.txt lists each unhealed name once, and no healed one" \
  "blocked.example.test
notwild.example.test" "$(data_lines "$scn/cap/blocked-domains.txt")"
expect_eq "blocked-ips.txt lists each nameless address once" \
  "198.51.100.7
198.51.100.9
198.51.100.10" "$(data_lines "$scn/cap/blocked-ips.txt")"
# Here-strings, not pipes: under pipefail a `head | grep -q` can report the
# opposite of what it saw (tests/test-grep-q-pipelines.sh).
grep -qxF '# Blocked IPs with no known domain — copy-paste into allowlist-cidrs.txt' <<<"$(head -n 1 "$scn/cap/blocked-ips.txt")" \
  && grep -qxF '# Blocked domains — copy-paste these lines into allowlist-domains.txt' <<<"$(head -n 1 "$scn/cap/blocked-domains.txt")" \
  && pass "a new list starts with its header" \
  || fail "a new list starts with its header — got: $(head -n 1 "$scn/cap/blocked-ips.txt") / $(head -n 1 "$scn/cap/blocked-domains.txt")"
grep -qxF 'Capturing on any' "$scn/cap/tshark-dns-errors.log" 2>/dev/null \
  && grep -qxF 'Capturing on nflog:100' "$scn/cap/tshark-nflog-errors.log" 2>/dev/null \
  && pass "each tshark's stderr is kept in its own log in the capture directory" \
  || fail "tshark's stderr logs — dns: [$(cat "$scn/cap/tshark-dns-errors.log" 2>/dev/null)] nflog: [$(cat "$scn/cap/tshark-nflog-errors.log" 2>/dev/null)]"

# ── RT-14: a DNS answer off the wire is not trusted on its own ──────────────────
# Port 53 is open to every address, so anyone can put a response on the wire
# that names an allowlisted host: here exact.example.test at 6.6.6.6, which the
# container's resolver does not give for it. A name starting with `-` is never
# taken for an option (grep read the feed on its stdin for `-v`), nor asked of
# the resolver, even where it would answer.
scn="$TMP/forged"
mkdir -p "$scn"
# -x.example.test matches the wildcard and the resolver here answers for it,
# but a name starting with `-` is no host name: getent would take it for an
# option, so it is never asked.
printf 'exact.example.test;6.6.6.6;\n-v;6.6.6.7;\n-x.example.test;6.6.6.8;\n' > "$scn/dns"
printf '6.6.6.6;;443;\n6.6.6.7;;443;\n6.6.6.8;;443;\n' > "$scn/nflog"
printf 'exact.example.test 192.0.2.10\n-v 6.6.6.7\n-x.example.test 6.6.6.8\n' > "$scn/hosts"
printf '*.example.test\n' > "$scn/proxy"
launch "$scn" "$heal_domains" "$scn/proxy"
await_map "$scn" "6.6.6.6 exact.example.test" "6.6.6.7 -v" "6.6.6.8 -x.example.test"
await_end "$scn"
if [[ -s "$scn/ipset.log" ]]; then
  fail "a forged DNS answer for an allowlisted name heals its address (RT-14) — ipset: $(tr '\n' '|' < "$scn/ipset.log")"
else
  pass "a forged DNS answer for an allowlisted name heals nothing: the resolver does not give that address (RT-14)"
fi
expect_eq "  … and blocked.log says why the address was not auto-allowed" \
  "TCP:443 6.6.6.6 exact.example.test (not auto-allowed: the resolver does not give this address for it)
TCP:443 6.6.6.7 -v
TCP:443 6.6.6.8 -x.example.test (not auto-allowed: the resolver does not give this address for it)" "$(log_rows "$scn/cap/blocked.log")"

# ── RT-13: nothing the agent plants in the capture directory is written through ─
# Every name the daemon writes is a link to a sentinel (the firewall's allowlist,
# in the container); the tshark error logs too, which were truncated at start.
# Each sentinel must stay as it was, and each name must end up a regular file
# holding what the daemon wrote.
sentinel_check() {   # $1 = label, then sentinel files
  local label="$1" f bad=""; shift
  for f in "$@"; do [[ "$(cat "$f")" == "SENTINEL $(basename "$f")" ]] || bad+=" ${f##*/}"; done
  if [[ -z "$bad" ]]; then pass "$label"; else fail "$label — changed:$bad"; fi
}
scn="$TMP/links"
write_feeds "$scn"
mkdir -p "$scn/cap" "$scn/sent"
for f in blocked.log blocked-domains.txt blocked-ips.txt tshark-dns-errors.log tshark-nflog-errors.log; do
  printf 'SENTINEL %s' "$f" > "$scn/sent/$f"; ln -s "$scn/sent/$f" "$scn/cap/$f"
done
launch "$scn" "$heal_domains" "$heal_proxy"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
sentinel_check "links planted at every output are never written through, nor truncated (RT-13)" "$scn"/sent/*
links_left=""
for f in blocked.log blocked-domains.txt blocked-ips.txt tshark-dns-errors.log tshark-nflog-errors.log; do
  [[ -L "$scn/cap/$f" || ! -f "$scn/cap/$f" ]] && links_left+=" $f"
done
[[ -z "$links_left" ]] && pass "  … each link is replaced by a regular file" \
  || fail "  … each link is replaced by a regular file — not:$links_left"
expect_eq "  … which holds what the daemon recorded" \
  "198.51.100.7
198.51.100.9
198.51.100.10" "$(data_lines "$scn/cap/blocked-ips.txt")"

# A second name of a file elsewhere (a hard link) is a regular file at that name,
# but writing it writes the other: refused, with a WARNING, and nothing written.
# A FIFO is removed, as a link is, rather than opened.
scn="$TMP/hardlink"
write_feeds "$scn"
mkdir -p "$scn/cap" "$scn/sent"
printf 'SENTINEL blocked-ips.txt' > "$scn/sent/blocked-ips.txt"
ln "$scn/sent/blocked-ips.txt" "$scn/cap/blocked-ips.txt"
mkfifo "$scn/cap/blocked-domains.txt"
launch "$scn" "$heal_domains" "$heal_proxy"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
sentinel_check "a hard link at an output is not written (RT-13)" "$scn/sent/blocked-ips.txt"
grep -q 'WARNING: .*blocked-ips.txt is not a regular file of its own' "$scn/stdout" \
  && pass "  … and the daemon says it is not writing it" \
  || fail "  … and the daemon says it is not writing it — got: $(cat "$scn/stdout")"
expect_eq "  … while a FIFO at another output is replaced by the file it should be" \
  "blocked.example.test
notwild.example.test" "$(data_lines "$scn/cap/blocked-domains.txt")"

# A link swapped in after the daemon removed what was there and before it opens
# the name: the descriptor is then not the file at that name, and it is refused.
scn="$TMP/relink"
write_feeds "$scn"
mkdir -p "$scn/cap" "$scn/sent"
printf 'SENTINEL allowlist' > "$scn/sent/allowlist"
ln -s "$scn/sent/allowlist" "$scn/cap/blocked-ips.txt"
launch "$scn" "$heal_domains" "$heal_proxy" FAKE_RM_RELINK="$scn/sent/allowlist"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
sentinel_check "a link swapped in between the removal and the open is refused, not written through (RT-13)" "$scn/sent/allowlist"

# Lists from an earlier session are kept and still deduplicate: the daemon reads
# them through its own descriptor and appends after them.
scn="$TMP/stale"
write_feeds "$scn"
mkdir -p "$scn/cap"
# old.example.test is not seen again this session: it must survive as it was.
printf '# old header\n\nold.example.test\nblocked.example.test\n' > "$scn/cap/blocked-domains.txt"
launch "$scn" "$heal_domains" "$heal_proxy"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
expect_eq "a list kept from an earlier session is appended to, each name still once" \
  "old.example.test
blocked.example.test
notwild.example.test" "$(data_lines "$scn/cap/blocked-domains.txt")"
grep -qxF '# old header' <<<"$(head -n 1 "$scn/cap/blocked-domains.txt")" \
  && pass "  … its own header kept, no second one written" \
  || fail "  … its own header kept — got: $(head -n 3 "$scn/cap/blocked-domains.txt")"

# A kept list whose last line has no newline (edited by hand): the next name
# goes on a line of its own, and that last line still deduplicates.
scn="$TMP/stale-nonl"
write_feeds "$scn"
mkdir -p "$scn/cap"
printf '# old header\n\nblocked.example.test' > "$scn/cap/blocked-domains.txt"
launch "$scn" "$heal_domains" "$heal_proxy"
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
expect_eq "a kept list with no final newline is appended on a new line, its last name still once" \
  "blocked.example.test
notwild.example.test" "$(data_lines "$scn/cap/blocked-domains.txt")"

# ── Self-healing OFF: the same traffic, logged only ─────────────────────────────
scn="$TMP/heal-off"
write_feeds "$scn"
launch "$scn" "$heal_domains" "$heal_proxy" SELF_HEALING_ENABLED=0
await_map "$scn" "${map_lines[@]}"
await_end "$scn"
grep -qxF '  self-healing: OFF (logging only)' "$scn/stdout" \
  && pass "announces self-healing OFF when SELF_HEALING_ENABLED=0" \
  || fail "announces self-healing OFF when SELF_HEALING_ENABLED=0 — got: $(cat "$scn/stdout")"
if [[ -s "$scn/ipset.log" ]]; then
  fail "SELF_HEALING_ENABLED=0 calls ipset — got: $(tr '\n' '|' < "$scn/ipset.log")"
else
  pass "SELF_HEALING_ENABLED=0 never calls ipset"
fi
expect_eq "with self-healing OFF an allowlisted name is listed like any other" \
  "exact.example.test
deep.sub.wild.example.test
v6only.wild.example.test
blocked.example.test
notwild.example.test" "$(data_lines "$scn/cap/blocked-domains.txt")"
if grep -qF '(auto-allowed)' "$scn/cap/blocked.log" 2>/dev/null; then
  fail "with self-healing OFF no row is marked (auto-allowed)"
else
  pass "with self-healing OFF no row is marked (auto-allowed)"
fi

# ── A full DNS map keeps its newest half ────────────────────────────────────────
# The map is capped at 10000 lines: the next new entry first cuts it to its last
# 5000, then is appended. Once for an A record and once for an AAAA record, which
# take separate branches.
for fam in 4 6; do
  scn="$TMP/map-cap-v$fam"
  mkdir -p "$scn"
  printf '10000\n' > "$scn/prefill"
  if [[ "$fam" == 4 ]]; then
    new="192.0.2.200 trunc.example.test"
    printf 'trunc.example.test;192.0.2.200;\n' > "$scn/dns"
  else
    new="2001:db8::200 trunc.example.test"
    printf 'trunc.example.test;;2001:db8::200\n' > "$scn/dns"
  fi
  launch "$scn" "$comments_only" "$comments_only"
  await_map "$scn" "$new"
  await_end "$scn"
  lines="$(wc -l < "$scn/int/dns-map.txt" 2>/dev/null | tr -d ' ')"
  first="$(head -n 1 "$scn/int/dns-map.txt" 2>/dev/null)"
  last="$(tail -n 1 "$scn/int/dns-map.txt" 2>/dev/null)"
  tmp_left=no; [[ -e "$scn/int/dns-map.txt.tmp" ]] && tmp_left=yes
  if [[ "$lines" == 5001 && "$first" == *" prefill5001.example.test" && "$last" == "$new" && "$tmp_left" == no ]]; then
    pass "a full DNS map is cut to its newest 5000 lines before a new IPv$fam entry"
  else
    fail "a full DNS map is cut to its newest 5000 lines before a new IPv$fam entry — got $lines lines, first '$first', last '$last', .tmp left: $tmp_left"
  fi
done

# ── Regression guard on the construct itself ────────────────────────────────────
# Any `grep … | grep …` here is one empty allowlist away from killing the daemon
# again. Comments are stripped first so prose describing the old pipeline is fine.
if grep -qE 'grep[^|]*\|[[:space:]]*grep' \
     < <(grep -vE '^[[:space:]]*#' "$REPO_DIR/capture-blocked-traffic.sh"); then
  fail "allowlist parsing must not use a grep|grep pipeline under set -e"
else
  pass "allowlist parsing uses no fail-prone grep|grep pipeline"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
