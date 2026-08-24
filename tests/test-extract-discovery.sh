#!/usr/bin/env bash
# tests/test-extract-discovery.sh — drives extract-discovery.sh against a
# STUBBED docker. No daemon, no image, no network.
#
# What is worth asserting here is exactly what the script adds over the
# hand-typed command the docs used to carry, because the extraction itself is
# already covered end-to-end by tests/integration/cases/120-discovery-collects.sh
# and re-testing it here would only re-test capture-agent-destinations.sh:
#
#   - the image name it resolves (sandbox.env, and inline env beating it)
#   - the capture directory it finds, and what it says when it finds none
#   - the docker argv it composes
#   - the coverage verdict — which observed hostnames the image does NOT allow
#   - the deletions, in all three states: none by default, raw-only on --clean,
#     everything on --discard
#
# The coverage verdict is the part with real logic in it, so it is checked
# against a fixture that includes the two cases a careless implementation gets
# wrong: an apex domain that must NOT be considered covered by "*.apex" (that is
# what matches_wildcard_domain() does in capture-blocked-traffic.sh, and this
# report is only worth reading if it agrees with the daemon), and a hostname
# that differs from an allowlisted one only in case and a trailing dot.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/extract-discovery.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$ENGINE_DIR/extract-discovery.sh" ]] \
  || { printf 'SCAFFOLD-FAILED: no extract-discovery.sh under %s\n' "$ENGINE_DIR"; exit 1; }

bash -n "$ENGINE_DIR/extract-discovery.sh" \
  && pass "extract-discovery.sh bash -n" \
  || fail "extract-discovery.sh bash -n"

SCRATCH="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

# ── Scaffold ──────────────────────────────────────────────────────────────────

# A tree that looks like a project's .ai-containers/ working copy: the script,
# the library it sources, and a sandbox.env carrying the image name.
mk_tree() {   # $1 = tree root
  local d="$1" f
  mkdir -p "$d/engine" "$d/bin" "$d/launch/.agent-discovery" || return 1
  for f in extract-discovery.sh sandbox-common.sh bash-floor.sh tools-lib.sh; do
    cp "$ENGINE_DIR/$f" "$d/engine/$f" || return 1
  done
  cp -R "$ENGINE_DIR/tools.d" "$d/engine/tools.d" 2>/dev/null || true
  printf 'IMAGE_NAME=test-image\n' > "$d/engine/sandbox.env"

  # A capture directory as discovery mode leaves it.
  printf 'PCAPPCAPPCAP\n' > "$d/launch/.agent-discovery/agent-traffic.pcap"
  printf 'listening on any\n'   > "$d/launch/.agent-discovery/tcpdump.log"
  printf '4242\n'               > "$d/launch/.agent-discovery/tcpdump.pid"

  # What the stubbed extract will write out. The second DNS line is
  # comma-separated on purpose: tshark emits repeated fields that way, and one
  # line can therefore carry several names.
  cat > "$d/dns-lines.txt" <<'DNS'
github.com
telemetry.acme.dev,cdn.example.com
GitHub.com.
example.com
DNS
  cat > "$d/sni-lines.txt" <<'SNI'
api.github.com
storage.acme.dev
SNI

  # The allowlists as the image bakes them, comments and blanks included so the
  # stripping is exercised rather than assumed.
  cat > "$d/allow-domains.txt" <<'EXACT'
# base.txt — always included

github.com
  api.github.com
EXACT
  cat > "$d/allow-proxy.txt" <<'WILD'
# custom.txt — wildcard proxy-domain patterns
*.example.com
WILD

  mk_docker_stub "$d/bin/docker"
}

# The stub reads $STUB_DIR out of the environment, so the heredoc below needs no
# escaping and says exactly what the file will contain.
mk_docker_stub() {   # $1 = path to write
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_DIR/docker-argv.log"

if [[ "$1" == "image" ]]; then
  [[ "${STUB_IMAGE_MISSING:-0}" == "1" ]] && exit 1
  exit 0
fi

case "$*" in
  *allowlist-proxy-domains.txt*)
    [[ "${STUB_CAT_FAIL:-0}" == "1" ]] && exit 1
    cat "$STUB_DIR/allow-proxy.txt"; exit 0 ;;
  *allowlist-domains.txt*)
    [[ "${STUB_CAT_FAIL:-0}" == "1" ]] && exit 1
    cat "$STUB_DIR/allow-domains.txt"; exit 0 ;;
esac

[[ "${STUB_EXTRACT_FAIL:-0}" == "1" ]] && exit 3

# The host side of the -v flag is where the extracted lists must land.
src=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-v" ]] && src="${a%%:*}"
  prev="$a"
done
[[ -d "$src" ]] || { echo "stub: no host dir in -v" >&2; exit 4; }
cp "$STUB_DIR/dns-lines.txt" "$src/agent-dns.txt"
cp "$STUB_DIR/sni-lines.txt" "$src/agent-sni.txt"
printf 'DNS queries saved to %s/agent-dns.txt\n' "$src"
printf 'TLS SNI hostnames saved to %s/agent-sni.txt\n' "$src"
exit 0
STUB
  chmod +x "$1"
}

# run_in <tree> <cwd> [args...] — run the script, capture stdout+stderr in OUT
# and the status in RC. Per-call inputs are the three RUN_* variables below,
# reset by reset_run_env.
#
# The invocation is a bare `bash <path>` at a command position ON PURPOSE. It
# used to prefix an `env` with an array of per-call assignments, which reads and
# runs identically — but tests/falsify/derive-targets.sh walks command positions
# to decide which tests EXECUTE which file, and its `env` rule stops at the
# first token that is neither a flag nor an assignment. An array expansion is
# neither, so the `bash` behind it was never seen and this file was classified
# NOT-EXECUTED: extract-discovery.sh would have entered the mutation tier
# claiming no oracle, and every mutant would have "survived" a test that in fact
# kills them. IMAGE_NAME is unset explicitly instead, because it is FORWARDED
# into these very containers — running the suite inside one would otherwise let
# the host's image name beat the sandbox.env this test is checking.
OUT=""; RC=0
RUN_IMAGE=""; RUN_IMAGE_MISSING=0; RUN_EXTRACT_FAIL=0; RUN_CAT_FAIL=0; RUN_STDIN=/dev/null
reset_run_env() {
  RUN_IMAGE=""; RUN_IMAGE_MISSING=0; RUN_EXTRACT_FAIL=0; RUN_CAT_FAIL=0; RUN_STDIN=/dev/null
}
run_in() {
  local tree="$1" cwd="$2"; shift 2
  local out
  out="$(
    cd "$cwd" || exit 90
    unset IMAGE_NAME
    [[ -n "$RUN_IMAGE" ]] && export IMAGE_NAME="$RUN_IMAGE"
    export STUB_DIR="$tree"
    export STUB_IMAGE_MISSING="$RUN_IMAGE_MISSING"
    export STUB_EXTRACT_FAIL="$RUN_EXTRACT_FAIL"
    export STUB_CAT_FAIL="$RUN_CAT_FAIL"
    export PATH="$tree/bin:$PATH"
    bash "$tree/engine/extract-discovery.sh" "$@" 2>&1 < "$RUN_STDIN"
  )"
  RC=$?
  OUT="$out"
}

fresh() {   # echoes a new tree root
  local d="$SCRATCH/t$RANDOM$RANDOM"
  mk_tree "$d" >/dev/null 2>&1 || { printf 'SCAFFOLD-FAILED: mk_tree\n' >&2; exit 1; }
  printf '%s' "$d"
}

# ── 1. Image name comes from sandbox.env, and inline env beats it ─────────────

T="$(fresh)"; reset_run_env
run_in "$T" "$T/launch"
if [[ "$RC" -eq 0 ]] && grep -q 'image:   test-image' <<<"$OUT"; then
  pass "IMAGE_NAME resolves from sandbox.env"
else
  fail "IMAGE_NAME resolves from sandbox.env (rc=$RC)
$OUT"
fi
if grep -q 'test-image extract /workspace/.agent-discovery' <<<"$(cat "$T/docker-argv.log")"; then
  pass "the extract runs in the resolved image"
else
  fail "the extract runs in the resolved image
$(cat "$T/docker-argv.log")"
fi

T="$(fresh)"; RUN_IMAGE=inline-image
run_in "$T" "$T/launch"
reset_run_env
if grep -q 'image:   inline-image' <<<"$OUT"; then
  pass "inline IMAGE_NAME beats sandbox.env"
else
  fail "inline IMAGE_NAME beats sandbox.env
$OUT"
fi

# ── 2. Capture-directory resolution ───────────────────────────────────────────

T="$(fresh)"
run_in "$T" "$T/launch"
if grep -qF "capture: $T/launch/.agent-discovery" <<<"$OUT"; then
  pass "finds .agent-discovery in the current directory"
else
  fail "finds .agent-discovery in the current directory
$OUT"
fi

# Launched from somewhere else entirely: the copy beside the script is the
# fallback, which is what makes ./extract-discovery.sh work from the engine dir.
T="$(fresh)"
mkdir -p "$T/engine/.agent-discovery"
cp "$T/launch/.agent-discovery/agent-traffic.pcap" "$T/engine/.agent-discovery/"
mkdir -p "$T/elsewhere"
run_in "$T" "$T/elsewhere"
if grep -qF "capture: $T/engine/.agent-discovery" <<<"$OUT"; then
  pass "falls back to .agent-discovery beside the script"
else
  fail "falls back to .agent-discovery beside the script
$OUT"
fi

T="$(fresh)"; mkdir -p "$T/elsewhere"
run_in "$T" "$T/elsewhere"
if [[ "$RC" -ne 0 ]] \
   && grep -qF "$T/elsewhere/.agent-discovery" <<<"$OUT" \
   && grep -qF "$T/engine/.agent-discovery" <<<"$OUT"; then
  pass "with no capture dir anywhere it fails naming both paths tried"
else
  fail "with no capture dir anywhere it fails naming both paths tried (rc=$RC)
$OUT"
fi

# An explicit directory argument wins over both.
T="$(fresh)"
run_in "$T" "$T/elsewhere2" 2>/dev/null
mkdir -p "$T/elsewhere2"
run_in "$T" "$T/elsewhere2" "$T/launch/.agent-discovery"
if [[ "$RC" -eq 0 ]] && grep -qF "capture: $T/launch/.agent-discovery" <<<"$OUT"; then
  pass "an explicit capture-dir argument is used"
else
  fail "an explicit capture-dir argument is used (rc=$RC)
$OUT"
fi

# ── 3. The composed docker argv ───────────────────────────────────────────────

T="$(fresh)"
run_in "$T" "$T/launch"
argv="$(cat "$T/docker-argv.log")"
if grep -qF -- "-v $T/launch/.agent-discovery:/workspace/.agent-discovery" <<<"$argv"; then
  pass "mounts the capture dir at the in-container capture path"
else
  fail "mounts the capture dir at the in-container capture path
$argv"
fi
if grep -qF -- "--entrypoint capture-agent-destinations.sh" <<<"$argv"; then
  pass "runs capture-agent-destinations.sh as the entrypoint"
else
  fail "runs capture-agent-destinations.sh as the entrypoint
$argv"
fi

# ── 4. The coverage verdict ───────────────────────────────────────────────────

# Fixture recap: allowed exactly = github.com, api.github.com; allowed by
# wildcard = *.example.com. Observed = those two, plus GitHub.com. (case +
# trailing dot), cdn.example.com, example.com, telemetry.acme.dev,
# storage.acme.dev.
T="$(fresh)"
run_in "$T" "$T/launch"
report="$OUT"
not_covered_block="$(sed -n '/^Not covered by this image/,/^$/p' <<<"$report")"

check_absent() {  # $1 = host, $2 = why
  if grep -qE "^  ${1//./\\.}$" <<<"$not_covered_block"; then
    fail "$2 — '$1' was reported as not covered
$not_covered_block"
  else
    pass "$2"
  fi
}
check_present() {  # $1 = host, $2 = why
  if grep -qE "^  ${1//./\\.}$" <<<"$not_covered_block"; then
    pass "$2"
  else
    fail "$2 — '$1' is missing from the not-covered list
$not_covered_block"
  fi
}

check_absent  github.com        "an exactly-allowlisted host is covered"
check_absent  cdn.example.com   "a host under a *.wildcard is covered"
# Not check_absent "github.com": that is already the exact-match check above, and
# it stays green when "GitHub.com." is reported unnormalised. What must be true
# is that NO spelling of the host reaches the list.
if grep -qi 'github' <<<"$not_covered_block"; then
  fail "case and a trailing dot are normalised before comparing — a github.com variant reached the not-covered list
$not_covered_block"
else
  pass "case and a trailing dot are normalised before comparing"
fi
check_present example.com       "the apex is NOT covered by *.apex (matches the runtime daemon)"
check_present telemetry.acme.dev "an unallowed host from a comma-separated field is reported"
check_present storage.acme.dev  "an unallowed host from the SNI list is reported"

if grep -q '3 of 6 observed' <<<"$report"; then
  pass "the counts name both the uncovered and the observed totals"
else
  fail "the counts name both the uncovered and the observed totals
$(grep -F 'Not covered' <<<"$report")"
fi

# With everything already allowed there is no list to print, and saying so is
# not the same as printing an empty list.
T="$(fresh)"
cat "$T/sni-lines.txt" >> "$T/allow-domains.txt"
tr ',' '\n' < "$T/dns-lines.txt" >> "$T/allow-domains.txt"
run_in "$T" "$T/launch"
if grep -q 'is already covered by this image' <<<"$OUT"; then
  pass "a fully-covered capture says so instead of printing an empty list"
else
  fail "a fully-covered capture says so instead of printing an empty list
$OUT"
fi

# A capture in which the agent resolved nothing is not the same as a capture in
# which everything was allowed, and must not report as "0 observed, all covered".
T="$(fresh)"
: > "$T/dns-lines.txt"; : > "$T/sni-lines.txt"
run_in "$T" "$T/launch"
if grep -q 'No hostnames in the capture' <<<"$OUT"; then
  pass "an empty capture says nothing was observed, not that all of it was covered"
else
  fail "an empty capture says nothing was observed, not that all of it was covered
$OUT"
fi

# The counts line is the extract's own receipt. Nothing asserted it, so
# count_lines() could return 0 for a file that exists and no test would notice.
T="$(fresh)"
run_in "$T" "$T/launch"
if grep -q '^4 DNS queries, 2 TLS SNI hostnames\.$' <<<"$OUT"; then
  pass "the counts line reports both files' line counts"
else
  fail "the counts line reports both files' line counts
$OUT"
fi

# A comments-only proxy list is the REAL configuration whenever no proxy-fragment
# component is enabled — the one that once killed capture-blocked-traffic.sh
# outright. One empty list must not be read as "could not read the allowlists".
T="$(fresh)"
printf '# custom.txt — wildcard proxy-domain patterns\n\n' > "$T/allow-proxy.txt"
run_in "$T" "$T/launch"
if grep -q 'Not covered by this image' <<<"$OUT" && ! grep -q 'Could not read' <<<"$OUT"; then
  pass "a comments-only proxy list still produces a coverage report"
else
  fail "a comments-only proxy list still produces a coverage report
$OUT"
fi
# ... and with that list empty, the wildcard no longer covers anything.
if grep -qE '^  cdn\.example\.com$' <<<"$OUT"; then
  pass "with no wildcard patterns, a formerly-covered subdomain is reported"
else
  fail "with no wildcard patterns, a formerly-covered subdomain is reported
$OUT"
fi

T="$(fresh)"; RUN_CAT_FAIL=1
run_in "$T" "$T/launch"
reset_run_env
if grep -q 'Could not read the allowlists out of test-image' <<<"$OUT" && [[ "$RC" -eq 0 ]]; then
  pass "unreadable allowlists skip the coverage report instead of failing the run"
else
  fail "unreadable allowlists skip the coverage report instead of failing the run (rc=$RC)
$OUT"
fi

# ── 5. Sizes ──────────────────────────────────────────────────────────────────

# human_size's branches are only reachable through a real file size, so the
# fixture's pcap is resized rather than the function called directly.
size_case() {   # $1 = dd block size, $2 = count, $3 = expected rendering
  local t; t="$(fresh)"
  rm -f "$t/launch/.agent-discovery/tcpdump.log" "$t/launch/.agent-discovery/tcpdump.pid"
  dd if=/dev/zero of="$t/launch/.agent-discovery/agent-traffic.pcap" \
     bs="$1" count="$2" >/dev/null 2>&1
  run_in "$t" "$t/launch"
  if grep -qF "Raw capture still on disk: $3." <<<"$OUT"; then
    pass "a ${3} capture is reported as ${3}"
  else
    fail "a ${3} capture is reported as ${3}
$(grep -F 'Raw capture' <<<"$OUT")"
  fi
}
size_case 1024 2048 "2.0 MB"
size_case 1024 2    "2 KB"

# ── 5. Deletions ──────────────────────────────────────────────────────────────

T="$(fresh)"
run_in "$T" "$T/launch"
if [[ -f "$T/launch/.agent-discovery/agent-traffic.pcap" ]]; then
  pass "the default run deletes nothing"
else
  fail "the default run deletes nothing — the pcap is gone"
fi
if grep -q 'Raw capture still on disk' <<<"$OUT"; then
  pass "the default run says the raw capture is still there"
else
  fail "the default run says the raw capture is still there
$OUT"
fi

T="$(fresh)"
run_in "$T" "$T/launch" --clean
d="$T/launch/.agent-discovery"
if [[ ! -f "$d/agent-traffic.pcap" && ! -f "$d/tcpdump.log" && ! -f "$d/tcpdump.pid" ]]; then
  pass "--clean removes the raw capture"
else
  fail "--clean removes the raw capture ($(ls "$d"))"
fi
if [[ -f "$d/agent-dns.txt" && -f "$d/agent-sni.txt" ]]; then
  pass "--clean keeps the extracted hostname lists"
else
  fail "--clean keeps the extracted hostname lists ($(ls "$d"))"
fi

T="$(fresh)"
run_in "$T" "$T/launch" --discard --yes
d="$T/launch/.agent-discovery"
if [[ ! -f "$d/agent-traffic.pcap" && ! -f "$d/agent-dns.txt" ]]; then
  pass "--discard --yes removes the whole capture"
else
  fail "--discard --yes removes the whole capture ($(ls "$d"))"
fi
if [[ "$RC" -eq 0 ]] && grep -q 'freed ' <<<"$OUT"; then
  pass "--discard --yes exits 0 and reports what it freed"
else
  fail "--discard --yes exits 0 and reports what it freed (rc=$RC)
$OUT"
fi

# The prompt itself, answered for real — --yes bypasses it, so without this the
# only exercised path through the confirmation is the one that declines.
T="$(fresh)"
printf 'yes\n' > "$T/answer"
RUN_STDIN="$T/answer"
run_in "$T" "$T/launch" --discard
reset_run_env
if [[ "$RC" -eq 0 ]] && [[ ! -f "$T/launch/.agent-discovery/agent-traffic.pcap" ]]; then
  pass "answering yes at the prompt removes the capture"
else
  fail "answering yes at the prompt removes the capture (rc=$RC)
$OUT"
fi

# A capture directory with nothing in it is not an error.
T="$(fresh)"
rm -f "$T"/launch/.agent-discovery/*
run_in "$T" "$T/launch" --discard --yes
if [[ "$RC" -eq 0 ]] && grep -q 'Nothing to discard' <<<"$OUT"; then
  pass "--discard on an empty capture directory says so and exits 0"
else
  fail "--discard on an empty capture directory says so and exits 0 (rc=$RC)
$OUT"
fi
if [[ ! -s "$T/docker-argv.log" ]]; then
  pass "--discard never touches docker"
else
  fail "--discard never touches docker
$(cat "$T/docker-argv.log")"
fi

# Unconfirmed --discard must be a no-op. run_in feeds /dev/null on stdin, so the
# prompt reads EOF — the case a user gets by piping or by hitting Ctrl-D.
T="$(fresh)"
run_in "$T" "$T/launch" --discard
if [[ -f "$T/launch/.agent-discovery/agent-traffic.pcap" ]] && [[ "$RC" -eq 0 ]]; then
  pass "an unconfirmed --discard removes nothing"
else
  fail "an unconfirmed --discard removes nothing (rc=$RC)
$OUT"
fi

# ── 6. Refusals ───────────────────────────────────────────────────────────────

T="$(fresh)"
run_in "$T" "$T/launch" --clean --discard
if [[ "$RC" -ne 0 ]] && grep -q 'mutually exclusive' <<<"$OUT"; then
  pass "--clean with --discard is refused"
else
  fail "--clean with --discard is refused (rc=$RC)
$OUT"
fi

T="$(fresh)"
run_in "$T" "$T/launch" --frobnicate
if [[ "$RC" -ne 0 ]] && grep -q 'unknown option' <<<"$OUT"; then
  pass "an unknown option is refused"
else
  fail "an unknown option is refused (rc=$RC)
$OUT"
fi

T="$(fresh)"
rm -f "$T/launch/.agent-discovery/agent-traffic.pcap"
run_in "$T" "$T/launch"
if [[ "$RC" -ne 0 ]] && grep -q 'no capture file' <<<"$OUT" && [[ ! -s "$T/docker-argv.log" ]]; then
  pass "a capture dir with no pcap fails before any docker call"
else
  fail "a capture dir with no pcap fails before any docker call (rc=$RC)
$OUT"
fi

T="$(fresh)"; RUN_IMAGE_MISSING=1
run_in "$T" "$T/launch"
reset_run_env
if [[ "$RC" -ne 0 ]] && grep -q 'image not found locally: test-image' <<<"$OUT"; then
  pass "a missing image is reported by name"
else
  fail "a missing image is reported by name (rc=$RC)
$OUT"
fi

T="$(fresh)"; RUN_EXTRACT_FAIL=1
run_in "$T" "$T/launch"
reset_run_env
if [[ "$RC" -ne 0 ]] && grep -q 'the extract failed inside' <<<"$OUT"; then
  pass "a failed extract is reported, and says the pcap is untouched"
else
  fail "a failed extract is reported, and says the pcap is untouched (rc=$RC)
$OUT"
fi
if [[ -f "$T/launch/.agent-discovery/agent-traffic.pcap" ]]; then
  pass "a failed extract leaves the pcap in place"
else
  fail "a failed extract leaves the pcap in place"
fi

# ── 7. --help ─────────────────────────────────────────────────────────────────

T="$(fresh)"
run_in "$T" "$T/launch" --help
if [[ "$RC" -eq 0 ]] && grep -q 'Usage:' <<<"$OUT" && [[ ! -s "$T/docker-argv.log" ]]; then
  pass "--help prints usage and touches nothing"
else
  fail "--help prints usage and touches nothing (rc=$RC)"
fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-extract-discovery.sh: all checks passed\n'
  exit 0
fi
printf 'test-extract-discovery.sh: %s check(s) failed\n' "$fails"
exit 1
