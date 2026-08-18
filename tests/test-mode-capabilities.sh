#!/usr/bin/env bash
# What `--cap-add` sandbox.sh puts on the `docker run` command line, per mode.
#
# WHY THIS IS HERMETIC AND NOT AN INTEGRATION CASE.
#
# The property is a LAUNCHER decision — one line, sandbox.sh's
# `[[ "$mode" == "open" ]] && capabilities=()` — so the honest place to observe
# it is the assembled `docker run` argument list, which a fake `docker` on PATH
# captures without a daemon. An integration case cannot observe it at all:
# tests/integration/lib.sh's sandbox_up composes its OWN `docker run` with its
# own per-mode capability logic (lib.sh:202-203) and never invokes sandbox.sh, so
# a case run through sandbox_up would report on the harness, not the product.
#
# That is not hypothetical. An earlier attempt at this coverage was written as an
# integration case, mutated sandbox.sh, and "demonstrated FAILING" — while the
# mutation had no effect whatsoever on what ran. It failed for an unrelated
# reason, which is worse than not existing: it would have been recorded as proof.
#
# WHY IT WAS WORTH WRITING AT ALL. Measured before it existed: deleting that line
# outright, so open mode launches WITH --cap-add=NET_ADMIN --cap-add=NET_RAW,
# passed all 45 hermetic tests and every integration case. 210 asserts
# reachability, 220 asserts no capture, and 230 — despite its name and its header
# claiming to assert that capabilities "were never granted to begin with" — runs
# in DISCOVERY mode. The only check that mentioned the array
# (tests/test-open-mode.sh) asserts its guarded empty-array EXPANSION idiom, a
# bash-4.3 crash guard, not its contents.
#
# WHAT THIS DOES *NOT* CLAIM. It does not claim an open-mode container holds no
# NET_RAW. Docker's default bounding set includes cap_net_raw (for ping) and
# sandbox.sh issues no --cap-drop anywhere, so the container has it regardless of
# this line. The precise property is narrower and is the one asserted here:
# sandbox.sh REQUESTS no capabilities in open mode, and requests both in
# restricted and discovery. The agent shell holding nothing in every mode is a
# separate belt, enforced by entrypoint.sh's capsh and covered by cases 070/230.
#
# Hermetic: fake `docker`, no daemon, no root.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
trap 'rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean
export SANDBOX_USER=tester
CAPTURE="$TMP/docker-args.txt"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# A sandbox.conf with everything off: this test is about capability flags, and an
# enabled component would drag in group dirs and allowlist work it does not care
# about.
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF
: > "$SANDBOX_CONF"

mkdir -p "$TMP/launch" "$TMP/app"

run_mode() {  # $1=mode → populates $CAPTURE
  : > "$CAPTURE"
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" "$1" "$TMP/app" ) \
    >"$TMP/out.txt" 2>"$TMP/err.txt" </dev/null
}

# Guard the guard: if sandbox.sh never reached `docker run`, $CAPTURE is empty and
# every "does not contain --cap-add" assertion below would pass vacuously. That is
# the single most likely way this file rots into a no-op.
capture_ok() { [[ -s "$CAPTURE" ]]; }

# ── restricted: both capabilities requested ───────────────────────────────────
run_mode restricted
if capture_ok; then
  pass "restricted: sandbox.sh reached docker run"
  for cap in NET_ADMIN NET_RAW; do
    if grep -qx -- "--cap-add=$cap" "$CAPTURE"; then
      pass "restricted requests --cap-add=$cap"
    else
      fail "restricted requests --cap-add=$cap — absent from the docker run args"
    fi
  done
else
  fail "restricted: sandbox.sh reached docker run (no args captured — assertions would be vacuous)"
  sed 's/^/       /' "$TMP/err.txt" | tail -5
fi

# ── discovery: both capabilities requested ────────────────────────────────────
run_mode discovery
if capture_ok; then
  pass "discovery: sandbox.sh reached docker run"
  for cap in NET_ADMIN NET_RAW; do
    if grep -qx -- "--cap-add=$cap" "$CAPTURE"; then
      pass "discovery requests --cap-add=$cap"
    else
      fail "discovery requests --cap-add=$cap — absent from the docker run args"
    fi
  done
else
  fail "discovery: sandbox.sh reached docker run (no args captured)"
  sed 's/^/       /' "$TMP/err.txt" | tail -5
fi

# ── open: NO capability requested. THE assertion this file exists for. ────────
run_mode open
if capture_ok; then
  pass "open: sandbox.sh reached docker run"
  if grep -q -- '--cap-add' "$CAPTURE"; then
    fail "open requests NO capabilities — found: $(grep -- '--cap-add' "$CAPTURE" | tr '\n' ' ')"
  else
    pass "open requests NO capabilities"
  fi
else
  fail "open: sandbox.sh reached docker run (no args captured)"
  sed 's/^/       /' "$TMP/err.txt" | tail -5
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
