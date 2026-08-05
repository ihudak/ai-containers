#!/usr/bin/env bash
# Tests for the volume-backed Ruby home (~/.rvm): the rvm_volume_* helpers in
# sandbox-common.sh, and the wiring in sandbox.sh / entrypoint.sh.
#
# WHY ~/.rvm is a docker volume and not a bind mount, on every platform: rvm
# bootstraps by extracting its release tarball, and GNU tar defers symlinks whose
# target contains '..' by first writing a mode-000 placeholder file. macOS virtiofs
# cannot service that, so tar fails on exactly the four such members in the rvm
# tarball and the installer aborts with "Could not extract RVM sources" — while
# plain `ln -s ../x` on the same mount works fine, which is why ~/.ai-tools
# (npm/uv, direct symlink()) is unaffected and stays a bind mount.
#
# The isolation assertions matter most: rvm volumes and repo volumes share a
# prefix, and only the infix ("-rvm-" vs "-repo-") keeps repo.sh's discovery and
# its registry-driven `--all` from ever touching a group's rubies.
#
# Hermetic: HOME points at a temp dir BEFORE sourcing sandbox-common.sh; the few
# docker-calling helpers use a fake `docker` on PATH.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset REPO_VOLUME_PREFIX REPO_BACKEND

# shellcheck disable=SC1091
source "$REPO_DIR/sandbox-common.sh"

# ── Fake docker ─────────────────────────────────────────────────────────────────
FAKE_VOLUMES_DIR="$TMP/fake-volumes"; mkdir -p "$FAKE_VOLUMES_DIR"; export FAKE_VOLUMES_DIR
FAKE_RUN_LOG="$TMP/fake-run.log"; : > "$FAKE_RUN_LOG"; export FAKE_RUN_LOG
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  volume)
    case "$2" in
      inspect)
        name=""; prev=""
        for a in "${@:3}"; do
          if [[ "$prev" == "--format" ]]; then :; elif [[ "$a" != "--format" ]]; then name="$a"; fi
          prev="$a"
        done
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || exit 1
        fmt=""; prev=""
        for a in "${@:3}"; do [[ "$prev" == "--format" ]] && fmt="$a"; prev="$a"; done
        if [[ "$fmt" == *Labels* ]]; then
          key="$(printf '%s' "$fmt" | sed -n 's/.*index \.Labels "\([^"]*\)".*/\1/p')"
          val=""
          [[ -f "$FAKE_VOLUMES_DIR/$name.labels" ]] && \
            val="$(grep "^${key}=" "$FAKE_VOLUMES_DIR/$name.labels" 2>/dev/null | head -1 | cut -d= -f2-)"
          printf '%s\n' "$val"
        else
          printf '%s\n' "$name"
        fi
        exit 0 ;;
      ls)
        substr=""
        for a in "$@"; do case "$a" in name=*) substr="${a#name=}" ;; esac; done
        for f in "$FAKE_VOLUMES_DIR"/*; do
          [[ -f "$f" ]] || continue
          case "$f" in *.labels) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0 ;;
      create)
        name="${@: -1}"; : > "$FAKE_VOLUMES_DIR/$name"; : > "$FAKE_VOLUMES_DIR/$name.labels"
        prev=""
        for a in "$@"; do
          [[ "$prev" == "--label" ]] && printf '%s\n' "$a" >> "$FAKE_VOLUMES_DIR/$name.labels"
          prev="$a"
        done
        exit 0 ;;
      rm) rm -f "$FAKE_VOLUMES_DIR/${3}" "$FAKE_VOLUMES_DIR/${3}.labels"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  run) printf '%s\n' "$*" >> "$FAKE_RUN_LOG"; exit 0 ;;
  ps)  exit 0 ;;
  *)   exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"
export PATH="$FAKE_BIN:$PATH"

# ── Naming ──────────────────────────────────────────────────────────────────────
check "rvm_volume_name uses the -rvm- infix" \
  "ai-containers-rvm-default" "$(rvm_volume_name default)"
check "rvm_volume_name is per-group" \
  "ai-containers-rvm-docs" "$(rvm_volume_name docs)"
check "rvm_volume_name sanitizes an unsafe group token" \
  "ai-containers-rvm-a_b" "$(rvm_volume_name 'a/b')"

# The whole isolation guarantee rests on this one character sequence.
case "$(rvm_volume_name default)" in
  *-repo-*) fail "rvm volume name must NOT contain the repo infix" ;;
  *)        pass "rvm volume name does not contain the repo infix" ;;
esac

# ── Isolation from repo discovery (the load-bearing assertion) ──────────────────
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-default"
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs"
: > "$FAKE_VOLUMES_DIR/ai-containers-repo-app"

check "repo_base_volumes does NOT see rvm volumes" \
  "ai-containers-repo-app" "$(repo_base_volumes | tr '\n' ' ' | sed 's/ $//')"
check "rvm_volumes does NOT see repo volumes" \
  "ai-containers-rvm-default ai-containers-rvm-docs" \
  "$(rvm_volumes | sort | tr '\n' ' ' | sed 's/ $//')"
check "repo_workcopy_volumes does NOT see rvm volumes" \
  "" "$(repo_workcopy_volumes | tr '\n' ' ' | sed 's/ $//')"

# repo.sh's `sync --all` / `reset --all` iterate repo_registry_names (repos.conf),
# never a volume listing — so an rvm volume can never become a --all target. Assert
# the registry stays empty even with rvm volumes present.
check "repo registry is unaffected by existing rvm volumes" \
  "" "$(repo_registry_names | tr '\n' ' ' | sed 's/ $//')"

# ── Labels + group round-trip ───────────────────────────────────────────────────
rm -f "$FAKE_VOLUMES_DIR"/*
out="$(rvm_volume_ensure "docs" "$TMP/nonexistent-group-root" "ai-sandbox" 2>/dev/null)"
check "rvm_volume_ensure echoes the volume name" "ai-containers-rvm-docs" "$out"
check "rvm_volume_ensure labels the volume with its group" \
  "docs" "$(docker_volume_label ai-containers-rvm-docs 'ai-containers.rvm-group')"
check "rvm_group_from_volume round-trips via the label" \
  "docs" "$(rvm_group_from_volume ai-containers-rvm-docs)"
# Fallback path: an unlabeled volume still resolves by stripping the prefix.
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-legacy"
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-legacy.labels"
check "rvm_group_from_volume falls back to the name when unlabeled" \
  "legacy" "$(rvm_group_from_volume ai-containers-rvm-legacy)"

# ── Idempotence: an existing volume is never re-created or re-seeded ────────────
: > "$FAKE_RUN_LOG"
out="$(rvm_volume_ensure "docs" "$TMP/nonexistent-group-root" "ai-sandbox" 2>/dev/null)"
check "rvm_volume_ensure is idempotent for an existing volume" "ai-containers-rvm-docs" "$out"
check "no docker run (seed copy) for an already-existing volume" "" "$(cat "$FAKE_RUN_LOG")"

# ── Migration predicate: only a HEALTHY legacy ~/.rvm is copied in ──────────────
# A group left by a bootstrap that failed on this very bug has a half-extracted
# src/ tree and NO scripts/rvm. Copying that in would hand rvm-reconcile.sh a
# broken rvm to source forever instead of re-bootstrapping cleanly.
rm -f "$FAKE_VOLUMES_DIR"/*; : > "$FAKE_RUN_LOG"
broken="$TMP/group-broken"; mkdir -p "$broken/.rvm/src/rvm" "$broken/.rvm/scripts"
: > "$broken/.rvm/scripts/rvm"                                       # zero bytes = broken
rvm_volume_ensure "broken" "$broken" "ai-sandbox" >/dev/null 2>&1
check "a zero-byte legacy scripts/rvm is NOT migrated" "" "$(cat "$FAKE_RUN_LOG")"

rm -f "$FAKE_VOLUMES_DIR"/*; : > "$FAKE_RUN_LOG"
healthy="$TMP/group-healthy"; mkdir -p "$healthy/.rvm/scripts"
printf 'rvm\n' > "$healthy/.rvm/scripts/rvm"                          # non-empty = healthy
rvm_volume_ensure "healthy" "$healthy" "ai-sandbox" >/dev/null 2>&1
if grep -q -- "$healthy/.rvm:/src:ro" "$FAKE_RUN_LOG" && grep -q 'ai-containers-rvm-healthy:/dst' "$FAKE_RUN_LOG"; then
  pass "a healthy legacy ~/.rvm IS migrated into the volume"
else
  fail "a healthy legacy ~/.rvm IS migrated into the volume (run log: $(cat "$FAKE_RUN_LOG"))"
fi
# Non-destructive: migration must never delete the source directory.
[[ -f "$healthy/.rvm/scripts/rvm" ]] \
  && pass "migration leaves the legacy directory in place" \
  || fail "migration leaves the legacy directory in place"

# ── sandbox.sh / entrypoint.sh wiring ───────────────────────────────────────────
bash -n "$REPO_DIR/sandbox.sh"  && pass "sandbox.sh bash -n"  || fail "sandbox.sh bash -n"
bash -n "$REPO_DIR/group.sh"    && pass "group.sh bash -n"    || fail "group.sh bash -n"
bash -n "$REPO_DIR/entrypoint.sh" && pass "entrypoint.sh bash -n" || fail "entrypoint.sh bash -n"

grep -q 'rvm_volume_ensure "$group" "$group_root" "$image_name"' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh ensures the group's rvm volume" \
  || fail "sandbox.sh ensures the group's rvm volume"
grep -q 'config_mount_flags+=(-v "$rvm_vol:$dev_home/.rvm")' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh mounts the rvm VOLUME" \
  || fail "sandbox.sh mounts the rvm VOLUME"
# Regression guard: the bind mount must not come back for named groups. It is only
# legal inside the host-group branch, whose contract is "mount my real \$HOME".
grep -q 'install -d "$group_root/.rvm"' "$REPO_DIR/sandbox.sh" \
  && fail "sandbox.sh must NOT create a bind-mount .rvm dir for named groups" \
  || pass "sandbox.sh no longer creates a bind-mount .rvm dir"

# A fresh named volume mounts root-owned and setup_sandbox_user's chown is -xdev,
# so without this the sandbox user cannot even open the reconcile lock.
grep -q 'chown_rvm_root' "$REPO_DIR/entrypoint.sh" \
  && pass "entrypoint defines/calls chown_rvm_root" \
  || fail "entrypoint defines/calls chown_rvm_root"
check "chown_rvm_root runs in all three modes, before each reconcile" \
  "3" "$(grep -c '^ *chown_rvm_root$' "$REPO_DIR/entrypoint.sh")"
# Order matters: chowning after the reconcile is useless.
awk '/^ *chown_rvm_root$/{c++} /^ *run_ruby_reconcile$/{r++; if (c<r) bad=1} END{exit bad?1:0}' \
  "$REPO_DIR/entrypoint.sh" \
  && pass "chown_rvm_root precedes run_ruby_reconcile every time" \
  || fail "chown_rvm_root precedes run_ruby_reconcile every time"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
