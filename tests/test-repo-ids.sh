#!/usr/bin/env bash
# repo.sh chowns what it seeds to SANDBOX_UID:SANDBOX_GID, inside seed containers
# that run a bash script as root — and the ones that sync a git repository have
# the host's ~/.ssh mounted. Those values come from the environment or from a
# committed sandbox.env, so they must never become script text: repo.sh refuses
# anything but numeric ids (the rule sandbox.sh applies) before any docker
# command, and hands the valid ones to the script as an argument (bugs review
# ENV-2).
#
# Hermetic: a fake `docker` that logs every call and runs nothing.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/repo.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
REAL_HOME="$HOME"
trap 'export HOME="$REAL_HOME"; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin" "$TMP/src"
printf 'x\n' > "$TMP/src/file"
unset SANDBOX_UID SANDBOX_GID REPO_SEED_IMAGE REPO_VOLUME_PREFIX SELINUX_LABEL
export REPO_BACKEND=volume
export DOCKER_LOG="$TMP/docker.log"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 ${2:-}" in
  "image inspect") exit 0 ;;
  "volume inspect") exit 1 ;;
  "info "*|"info") printf '[]\n'; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

add() {  # $1 = repo name; extra env via the caller
  : > "$DOCKER_LOG"; rm -f "$HOME/.ai-containers/repos.conf"
  bash "$ENGINE_DIR/repo.sh" add "$1" "$TMP/src" >"$TMP/out" 2>&1 </dev/null
  RC=$?
}

for bad in '1000 /dst; touch /tmp/pwned; true' '1000:0' '-1' '4294967295' 'abc'; do
  SANDBOX_UID="$bad" add demo
  if [[ "$RC" != 0 ]] && ! grep -q '^run ' "$DOCKER_LOG" \
     && grep -qF 'SANDBOX_UID/SANDBOX_GID must be numeric ids from 0 to 4294967294' "$TMP/out"; then
    pass "SANDBOX_UID=$(printf '%q' "$bad") is refused before any container runs"
  else
    fail "SANDBOX_UID=$(printf '%q' "$bad") (rc=$RC; runs: $(grep -c '^run ' "$DOCKER_LOG"); out: $(tr '\n' ' ' < "$TMP/out"))"
  fi
done
SANDBOX_GID='1000; id' add demo
[[ "$RC" != 0 ]] && ! grep -q '^run ' "$DOCKER_LOG" \
  && pass "a SANDBOX_GID that is not numeric is refused too" \
  || fail "SANDBOX_GID='1000; id' (rc=$RC; out: $(tr '\n' ' ' < "$TMP/out"))"

SANDBOX_UID=1234 SANDBOX_GID=5678 add demo
run_line="$(grep '^run ' "$DOCKER_LOG" | head -1)"
[[ "$RC" == 0 && "$run_line" == *' 1234:5678' ]] \
  && pass "valid ids are handed to the seed script as an argument" \
  || fail "valid ids (rc=$RC; run: $run_line; out: $(tr '\n' ' ' < "$TMP/out"))"
[[ "$run_line" != *'chown -R 1234'* ]] \
  && pass "the ids are never part of the script text" \
  || fail "ids spliced into the script (run: $run_line)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
