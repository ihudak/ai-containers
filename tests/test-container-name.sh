#!/usr/bin/env bash
# The --name sandbox.sh puts on `docker run`.
#
# Default: <project-folder>-<PID>, where the project folder is the PARENT of the
# launch dir (the documented launch is `cd <project>/.ai-containers && ./sandbox.sh`,
# and ".ai-containers-<pid>" is rejected by Docker for its leading dot — which is
# how the first version of this feature failed on a real launch). A project
# folder whose name starts with something Docker refuses (".hidden", "-scratch")
# has that prefix stripped; one with nothing usable falls back to "workspace".
# CONTAINER_NAME overrides all of it.
#
# Hermetic: fake `docker` capturing the run args, no daemon.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/sandbox.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
trap 'rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF; : > "$SANDBOX_CONF"
mkdir -p "$TMP/app"

# $1 = project folder name; launches from <it>/.ai-containers. Prints the --name value.
name_for() {
  local launch="$TMP/p/$1/.ai-containers"
  mkdir -p "$launch"; : > "$CAPTURE"
  ( cd "$launch" && bash "$ENGINE/sandbox.sh" restricted "$TMP/app" ) \
    >/dev/null 2>"$TMP/err.txt" </dev/null
  awk 'prev=="--name"{print; exit} {prev=$0}' "$CAPTURE"
}

n="$(name_for myproj)"
if [[ -s "$CAPTURE" ]]; then pass "sandbox.sh reached docker run"
else fail "sandbox.sh reached docker run (no args captured)"; tail -5 "$TMP/err.txt"; fi
[[ "$n" =~ ^myproj-[0-9]+$ ]] && pass "default is <project-folder>-<pid> ($n)" \
  || fail "default is <project-folder>-<pid>, got '$n'"
[[ "$(grep -cx -- '--name' "$CAPTURE")" -eq 1 ]] && pass "exactly one --name" \
  || fail "exactly one --name"

n="$(name_for '.hidden')"
[[ "$n" =~ ^hidden-[0-9]+$ ]] && pass "leading '.' is stripped ($n)" || fail "leading '.' is stripped, got '$n'"

n="$(name_for 'my proj+x')"
[[ "$n" =~ ^my_proj_x-[0-9]+$ ]] && pass "disallowed characters are replaced ($n)" \
  || fail "disallowed characters are replaced, got '$n'"

n="$(name_for '---')"
[[ "$n" =~ ^workspace-[0-9]+$ ]] && pass "nothing usable falls back to workspace ($n)" \
  || fail "nothing usable falls back to workspace, got '$n'"

# Every derived name must satisfy Docker's own rule.
bad=0
for p in myproj .hidden 'my proj+x' --- '_x' 'a.b-c'; do
  n="$(name_for "$p")"
  [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { fail "'$p' → '$n' is not a valid Docker name"; bad=1; }
done
[[ "$bad" -eq 0 ]] && pass "every derived name matches [a-zA-Z0-9][a-zA-Z0-9_.-]*"

n="$(CONTAINER_NAME=pinned-one name_for myproj)"
[[ "$n" == "pinned-one" ]] && pass "CONTAINER_NAME overrides the default" \
  || fail "CONTAINER_NAME overrides the default, got '$n'"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
