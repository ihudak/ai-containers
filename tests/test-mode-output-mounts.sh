#!/usr/bin/env bash
# What sandbox.sh mounts, and whether it arms the capture, PER MODE.
#
# The sibling file test-mode-capabilities.sh covers the `--cap-add` array on the
# same three modes with the same technique. This one covers the block directly
# below it in sandbox.sh — eight lines that are the rest of what "mode" means:
#
#     local capture_enabled="0"
#     local output_mount_flags=()
#     if   [[ "$mode" == "discovery"  ]]; then capture_enabled="1"; mkdir …; -v …
#     elif [[ "$mode" == "restricted" ]]; then                      mkdir …; -v …
#     fi
#     # open: no firewall capture, no output mounts.
#
# WHY IT NEEDED ITS OWN COVERAGE (falsify backlog F2). test-mode-capabilities.sh
# closed the argv-parsing and mode-DISPATCH half of F2 — all three modes are
# executed — but it asserts only the capability array, so everything the three
# modes do DIFFERENTLY beyond that array was still unexecuted-in-effect: the
# assertions could not see it. The entry stayed open for exactly this remainder.
#
# WHY IT IS WORTH ASSERTING RATHER THAN OBVIOUS. `capture_enabled` becomes
# `-e DISCOVERY_CAPTURE_ENABLED`, which is what decides whether the firewall
# capture runs at all. This project's founding example of a check that reports
# success while doing nothing is a capture daemon that started and logged no
# packets; the flag that arms it had no hermetic assertion of its own.
#
# THE TRAP, MEASURED BEFORE ANY ASSERTION WAS WRITTEN — and it would have made
# this whole file vacuous. `DISCOVERY_CAPTURE_DIR=/workspace/.agent-discovery`
# and `BLOCKED_CAPTURE_DIR=/workspace/.agent-blocked` are passed in ALL THREE
# modes: they are path constants the entrypoint reads, not mode decisions. An
# assertion that grepped for either name would pass in every mode, including the
# one that must not have the mount, and would go on passing with the branch
# deleted. What actually discriminates is the `-v` PAIR and the value of
# DISCOVERY_CAPTURE_ENABLED, so those are what this file reads.
#
# EVERY ASSERTION HERE WAS DEMONSTRATED FAILING, and two of them earn their
# place by failing ALONE — which is the only way to show a check is not just
# riding on its neighbours:
#
#   damage                                            failures
#   cond-negate `[[ "$mode" == "discovery" ]]`              11
#   cmp-flip    that same `==` to `!=`                      11
#   cond-negate the `elif [[ "$mode" == "restricted" ]]`     4  (open gains a mount)
#   set capture_enabled to "0" in the discovery branch       1  ← the flag alone
#   delete the discovery `mkdir`, keep its `-v`              1  ← the dir alone
#
# The last two are the point. The mount and the mkdir are SEPARATE statements
# and only one of them is the mount, so a `-v` pointing at a directory that was
# never created reads as a perfectly good mount on the argv; and
# capture_enabled is a third, independent decision that no mount assertion can
# see. Drop either and the other twelve assertions stay green.
#
# A NOTE ON A DAMAGE THAT DOES NOTHING, because it was in this header first and
# was wrong: turning the `elif` into a plain `if` changes NOTHING observable.
# The two conditions are mutually exclusive, so discovery still takes only the
# first block and restricted only the second. It is written down because
# "obviously that would break it" is how a demonstration ends up proving
# nothing — the break has to reach the value the assertion reads.
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

# Everything off, for the same reason the capability sibling does it: an enabled
# component drags in group dirs and allowlist work this file does not care about.
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF
: > "$SANDBOX_CONF"

LAUNCH="$TMP/launch"
mkdir -p "$LAUNCH" "$TMP/app"

run_mode() {  # $1=mode → populates $CAPTURE and $LAUNCH
  : > "$CAPTURE"
  rm -rf "$LAUNCH/.agent-discovery" "$LAUNCH/.agent-blocked"
  ( cd "$LAUNCH" && bash "$REPO_DIR/sandbox.sh" "$1" "$TMP/app" ) \
    >"$TMP/out.txt" 2>"$TMP/err.txt" </dev/null
}

# Guard the guard. Every "does NOT mount" assertion below passes against an empty
# capture file, so a sandbox.sh that never reached `docker run` would turn the
# negative half of this file — the half that carries its weight — into a row of
# green ticks. Same failure mode the sibling file names, same guard.
capture_ok() { [[ -s "$CAPTURE" ]]; }

# The `-v` pair, not the name. A host path ending in `:/workspace/.agent-X` is a
# MOUNT; `DISCOVERY_CAPTURE_DIR=/workspace/.agent-discovery` is an env constant
# present in every mode, and the ':' is the whole difference between reading one
# and reading the other.
mounts() {   # $1 = discovery|blocked → 0 when that output mount is on the argv
  grep -qE "^.+:/workspace/\.agent-$1\$" "$CAPTURE"
}
capture_flag() { grep -m1 '^DISCOVERY_CAPTURE_ENABLED=' "$CAPTURE" | cut -d= -f2; }

want_mounts() {   # <mode> <discovery:yes|no> <blocked:yes|no>
  local mode="$1" want_d="$2" want_b="$3" got
  for pair in "discovery $want_d" "blocked $want_b"; do
    set -- $pair
    if mounts "$1"; then got=yes; else got=no; fi
    if [[ "$got" == "$2" ]]; then
      if [[ "$2" == "yes" ]]; then pass "$mode mounts .agent-$1"
      else pass "$mode does NOT mount .agent-$1"; fi
    else
      fail "$mode: .agent-$1 mount expected '$2', got '$got'"
    fi
  done
}

want_dirs() {   # <mode> <discovery:yes|no> <blocked:yes|no>
  local mode="$1" n got want
  for pair in "discovery $2" "blocked $3"; do
    set -- $pair; n="$1"; want="$2"
    if [[ -d "$LAUNCH/.agent-$n" ]]; then got=yes; else got=no; fi
    if [[ "$got" == "$want" ]]; then
      if [[ "$want" == "yes" ]]; then pass "$mode creates .agent-$n in the launch dir"
      else pass "$mode leaves no .agent-$n in the launch dir"; fi
    else
      fail "$mode: .agent-$n directory expected '$want', got '$got' — the mkdir and the -v are separate statements and only one of them is the mount"
    fi
  done
}

want_capture() {   # <mode> <0|1>
  local mode="$1" want="$2" got; got="$(capture_flag)"
  if [[ "$got" == "$want" ]]; then
    pass "$mode passes DISCOVERY_CAPTURE_ENABLED=$want"
  else
    fail "$mode passes DISCOVERY_CAPTURE_ENABLED=$want — got '${got:-<absent>}'"
  fi
}

for mode in restricted discovery open; do
  run_mode "$mode"
  if ! capture_ok; then
    fail "$mode: sandbox.sh reached docker run (no args captured — every assertion for this mode would be vacuous)"
    sed 's/^/       /' "$TMP/err.txt" | tail -5
    continue
  fi
  pass "$mode: sandbox.sh reached docker run"
  case "$mode" in
    restricted) want_capture "$mode" 0; want_mounts "$mode" no  yes; want_dirs "$mode" no  yes ;;
    discovery)  want_capture "$mode" 1; want_mounts "$mode" yes no ; want_dirs "$mode" yes no  ;;
    open)       want_capture "$mode" 0; want_mounts "$mode" no  no ; want_dirs "$mode" no  no  ;;
  esac
done

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
