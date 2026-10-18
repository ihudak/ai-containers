#!/usr/bin/env bash
# SELinux daemons: every `docker run` that bind-mounts a host path carries
# --security-opt label=disable (sandbox-common.sh: selinux_security_opt()).
#
# WHY. On a Docker daemon with "selinux-enabled": true (openSUSE Tumbleweed and
# Fedora ship it so), a container runs as container_t, and container_t may read
# only files labelled for containers. Measured on openSUSE Tumbleweed, Docker
# 29.7.2, 2026-10-17: `docker run -v ~/dev/x:/w:ro alpine ls /w` fails with
# `Permission denied`, while a named volume works. The same label kept the
# restricted-mode firewall from starting: `ipset create t hash:net` gave "set
# type not supported", because container_t may not make the kernel load
# ip_set_hash_net, nfnetlink_log or xt_NFLOG. With label=disable both work.
# Not `:z`, which would relabel the user's real repos, vault and specs on every
# launch and would not fix the module loading.
#
# WHAT IS ASSERTED. The helper's decision for each SELINUX_LABEL value against
# the two daemon shapes, then the flag on each launch that mounts a host path:
# sandbox.sh's container, all five repo.sh seed containers (a source tree or
# ~/.ssh), and the rvm migration copy. extract-discovery.sh is asserted in
# tests/test-extract-discovery.sh, its falsify oracle, and verify-on-host.sh's
# floor container in tests/test-verify-exit-code.sh, beside its other floor
# assertions.
#
# Hermetic: fake `docker`, no daemon, no root.
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR
unset REPO_VOLUME_PREFIX REPO_SEED_IMAGE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# mgd-ai-containers keeps the engine under base/; resolve it, and refuse to run
# against nothing.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || { printf 'SCAFFOLD-FAILED: no sandbox.sh under %s\n' "$REPO_DIR"; exit 1; }
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
trap 'rm -rf "$TMP"; export HOME="$REAL_HOME"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean
export SANDBOX_USER=tester

# What `docker info --format '{{json .SecurityOptions}}'` printed, verbatim. The
# first is the openSUSE Tumbleweed daemon above; the second is Docker on Ubuntu,
# where AppArmor confines containers and host bind mounts were never refused.
SELINUX_DAEMON='["name=seccomp,profile=builtin","name=selinux","name=cgroupns"]'
APPARMOR_DAEMON='["name=apparmor","name=seccomp,profile=builtin","name=cgroupns"]'

# ── Fake docker ─────────────────────────────────────────────────────────────────
# info answers from FAKE_SECURITY_OPTIONS (or fails with FAKE_INFO_RC); run
# appends its argv as one line to FAKE_RUN_LOG; volumes are files in
# FAKE_VOLUMES_DIR, so a repo added in one call exists for the next.
export FAKE_RUN_LOG="$TMP/run.log" FAKE_VOLUMES_DIR="$TMP/volumes"
export FAKE_SECURITY_OPTIONS="$APPARMOR_DAEMON" FAKE_INFO_RC=0
: > "$FAKE_RUN_LOG"; mkdir -p "$FAKE_VOLUMES_DIR" "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info)
    (( FAKE_INFO_RC == 0 )) || exit "$FAKE_INFO_RC"
    [[ "$*" == *SecurityOptions* ]] && printf '%s\n' "$FAKE_SECURITY_OPTIONS"
    exit 0 ;;
  run) printf '%s\n' "$*" >> "$FAKE_RUN_LOG"; exit 0 ;;
  volume)
    case "$2" in
      inspect) [[ -f "$FAKE_VOLUMES_DIR/${*: -1}" ]] || exit 1; printf '\n'; exit 0 ;;
      create)  : > "$FAKE_VOLUMES_DIR/${*: -1}"; exit 0 ;;
      *)       exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# A sandbox.conf with everything off: no component may add a docker run of its own.
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF
: > "$SANDBOX_CONF"

# True when the docker argv line $1 carries label=disable, in either spelling.
has_label_disable() {
  [[ " $1 " == *" --security-opt=label=disable "* || " $1 " == *" --security-opt label=disable "* ]]
}

# ── 1. The decision, per SELINUX_LABEL value ──────────────────────────────────
# Set, never unset: an exported value (even empty) wins over a SELINUX_LABEL in
# the developer's own sandbox.local.env, which sourcing the library would load.
opt_for() {  # $1=SELINUX_LABEL  $2=daemon's SecurityOptions → OPT, RC, ERR
  OPT="$(SELINUX_LABEL="$1" FAKE_SECURITY_OPTIONS="$2" \
    bash -c 'source "$1/sandbox-common.sh" && selinux_security_opt' _ "$ENGINE_DIR" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
expect_opt() {  # $1=label  $2=expected stdout  $3=expected rc
  if [[ "$OPT" == "$2" && "$RC" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2' rc=$3, got '$OPT' rc=$RC; stderr: $ERR)"; fi
}

opt_for auto "$SELINUX_DAEMON"
expect_opt "auto on an SELinux daemon disables labelling" "--security-opt=label=disable" 0
opt_for "" "$SELINUX_DAEMON"
expect_opt "an empty SELINUX_LABEL means auto" "--security-opt=label=disable" 0
opt_for auto "$APPARMOR_DAEMON"
expect_opt "auto on an AppArmor daemon adds nothing" "" 0
FAKE_INFO_RC=1 opt_for auto "$SELINUX_DAEMON"
expect_opt "auto adds nothing when docker info fails (docker run reports the daemon)" "" 0
opt_for disable "$APPARMOR_DAEMON"
expect_opt "disable forces the flag on any daemon" "--security-opt=label=disable" 0
opt_for keep "$SELINUX_DAEMON"
expect_opt "keep never adds the flag, even on an SELinux daemon" "" 0

opt_for Disable "$SELINUX_DAEMON"
if [[ "$RC" != 0 && -z "$OPT" && "$ERR" == *SELINUX_LABEL* && "$ERR" == *Disable* ]]; then
  pass "an unknown SELINUX_LABEL is refused, naming the variable and the value"
else
  fail "an unknown SELINUX_LABEL is refused (rc=$RC, stdout '$OPT', stderr: $ERR)"
fi

# ── 2. sandbox.sh's container ─────────────────────────────────────────────────
mkdir -p "$TMP/launch" "$TMP/app"
launch() {  # $1=SELINUX_LABEL  $2=daemon → LAUNCH (the container's argv line), RC
  : > "$FAKE_RUN_LOG"
  ( cd "$TMP/launch" && SELINUX_LABEL="$1" FAKE_SECURITY_OPTIONS="$2" \
      bash "$ENGINE_DIR/sandbox.sh" restricted "$TMP/app" ) >"$TMP/out" 2>"$TMP/err" </dev/null
  RC=$?
  LAUNCH="$(grep -e '--cpus=' "$FAKE_RUN_LOG")"
}

launch auto "$SELINUX_DAEMON"
if [[ -z "$LAUNCH" ]]; then
  fail "sandbox.sh reached docker run on an SELinux daemon (rc=$RC: $(tail -3 "$TMP/err" | tr '\n' ' '))"
elif has_label_disable "$LAUNCH"; then
  pass "sandbox.sh's container runs with label=disable on an SELinux daemon"
else
  fail "sandbox.sh's container runs with label=disable on an SELinux daemon (argv: $LAUNCH)"
fi

launch auto "$APPARMOR_DAEMON"
if [[ -z "$LAUNCH" ]]; then
  fail "sandbox.sh reached docker run on an AppArmor daemon (rc=$RC: $(tail -3 "$TMP/err" | tr '\n' ' '))"
elif [[ "$LAUNCH" == *label=disable* ]]; then
  fail "sandbox.sh's container keeps its label on an AppArmor daemon (argv: $LAUNCH)"
else
  pass "sandbox.sh's container keeps its label on an AppArmor daemon"
fi

launch bogus "$SELINUX_DAEMON"
if [[ "$RC" != 0 && ! -s "$FAKE_RUN_LOG" ]] && grep -q 'SELINUX_LABEL' "$TMP/err"; then
  pass "sandbox.sh refuses an unknown SELINUX_LABEL before any docker run"
else
  fail "sandbox.sh refuses an unknown SELINUX_LABEL before any docker run (rc=$RC, runs: $(wc -l < "$FAKE_RUN_LOG"); stderr: $(tail -3 "$TMP/err" | tr '\n' ' '))"
fi

# ── 3. repo.sh's seed containers ──────────────────────────────────────────────
# REPO_BACKEND=volume: on Linux a path repo is otherwise a bind alias and no seed
# container runs. One command per seed function; each must reach a docker run.
export REPO_BACKEND=volume
mkdir -p "$TMP/src"
repo() {  # $1=SELINUX_LABEL  $2=daemon  $3…=repo.sh args → RUNS, RC
  : > "$FAKE_RUN_LOG"
  SELINUX_LABEL="$1" FAKE_SECURITY_OPTIONS="$2" bash "$ENGINE_DIR/repo.sh" "${@:3}" \
    >"$TMP/out" 2>"$TMP/err" </dev/null
  RC=$?
  RUNS="$(cat "$FAKE_RUN_LOG")"
}
expect_seed_flag() {  # $1=label  $2=a mount the run must carry
  if [[ -z "$RUNS" ]]; then
    fail "$1 — no docker run (rc=$RC: $(tail -3 "$TMP/err" | tr '\n' ' '))"
  elif [[ "$RUNS" != *"$2"* ]]; then
    fail "$1 — the run does not mount $2 (argv: $RUNS)"
  elif has_label_disable "$RUNS"; then
    pass "$1"
  else
    fail "$1 (argv: $RUNS)"
  fi
}

# repo.sh mounts the source's physical path, which differs from $TMP's under a
# symlinked TMPDIR (CI's symlinked-TMPDIR job).
SRC_REAL="$(cd "$TMP/src" && pwd -P)"
repo auto "$SELINUX_DAEMON" add app "$TMP/src"
expect_seed_flag "repo.sh add <path> seeds with label=disable" "$SRC_REAL:/src:ro"
repo auto "$SELINUX_DAEMON" sync app
expect_seed_flag "repo.sh sync <path repo> mirrors with label=disable" "$SRC_REAL:/src:ro"
repo auto "$SELINUX_DAEMON" add lib git@example.com:org/lib.git
expect_seed_flag "repo.sh add <git url> clones with label=disable" ".ssh:/root/.ssh-host:ro"
repo auto "$SELINUX_DAEMON" sync lib
expect_seed_flag "repo.sh sync <git repo> pulls with label=disable" ".ssh:/root/.ssh-host:ro"
repo auto "$SELINUX_DAEMON" reset lib --yes
expect_seed_flag "repo.sh reset <git repo> inspects with label=disable" "repo-git-reset.sh:/repo-git-reset.sh:ro"

repo auto "$APPARMOR_DAEMON" sync app
if [[ -n "$RUNS" && "$RUNS" != *label=disable* ]]; then
  pass "repo.sh's seed container keeps its label on an AppArmor daemon"
else
  fail "repo.sh's seed container keeps its label on an AppArmor daemon (rc=$RC, argv: $RUNS)"
fi

repo bogus "$SELINUX_DAEMON" add bad "$TMP/src"
if [[ "$RC" != 0 && -z "$RUNS" && ! -e "$FAKE_VOLUMES_DIR/ai-containers-repo-bad" ]] \
     && grep -q 'SELINUX_LABEL' "$TMP/err"; then
  pass "repo.sh refuses an unknown SELINUX_LABEL before creating the volume"
else
  fail "repo.sh refuses an unknown SELINUX_LABEL before creating the volume (rc=$RC, volume: $([[ -e "$FAKE_VOLUMES_DIR/ai-containers-repo-bad" ]] && echo created || echo absent); stderr: $(tail -3 "$TMP/err" | tr '\n' ' '))"
fi
unset REPO_BACKEND

# ── 4. The rvm migration copy ─────────────────────────────────────────────────
# A group made before ~/.rvm moved to a volume holds a healthy bind-mounted one;
# rvm_volume_ensure copies it in from the host path.
migrate() {  # $1=daemon → RUNS
  rm -f "$FAKE_VOLUMES_DIR"/ai-containers-rvm-*; : > "$FAKE_RUN_LOG"
  SELINUX_LABEL=auto FAKE_SECURITY_OPTIONS="$1" bash -c \
    'source "$1/sandbox-common.sh" && rvm_volume_ensure old "$2" ai-sandbox' _ "$ENGINE_DIR" "$TMP/group-old" \
    >/dev/null 2>&1
  RUNS="$(cat "$FAKE_RUN_LOG")"
}
mkdir -p "$TMP/group-old/.rvm/scripts"; printf 'rvm\n' > "$TMP/group-old/.rvm/scripts/rvm"

migrate "$SELINUX_DAEMON"
if [[ "$RUNS" == *"$TMP/group-old/.rvm:/src:ro"* ]] && has_label_disable "$RUNS"; then
  pass "the rvm migration copies from the host with label=disable on an SELinux daemon"
else
  fail "the rvm migration copies from the host with label=disable on an SELinux daemon (argv: ${RUNS:-none})"
fi
migrate "$APPARMOR_DAEMON"
if [[ "$RUNS" == *"$TMP/group-old/.rvm:/src:ro"* && "$RUNS" != *label=disable* ]]; then
  pass "the rvm migration keeps its label on an AppArmor daemon"
else
  fail "the rvm migration keeps its label on an AppArmor daemon (argv: ${RUNS:-none})"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
