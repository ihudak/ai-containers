#!/usr/bin/env bash
# tests/test-host-binds.sh — the host paths the entry points other than
# sandbox.sh's launch bind into a container reach docker intact (bugs review
# LNCH-23): repo.sh's seed containers (a path source, your ~/.ssh). docker's
# `-v` splits at every ':', so a path holding one goes as a `--mount` record;
# a name that is not valid UTF-8, which the CLI rewrites to U+FFFD, is refused
# before any container runs (sandbox-common.sh: docker_bind()).
# extract-discovery.sh, the rvm migration and verify-on-host.sh's floor
# container have theirs checked in their own tests.
#
# Hermetic: a fake `docker` that records each argument on a line of its own.
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
mkdir -p "$TMP/bin"
unset SANDBOX_UID SANDBOX_GID REPO_SEED_IMAGE REPO_VOLUME_PREFIX SELINUX_LABEL
export REPO_BACKEND=volume
export DOCKER_ARGV="$TMP/argv"
# Each `run`'s arguments, one per line, and a line `--` between runs.
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${2:-}" >> "$DOCKER_ARGV.calls"
case "$1 ${2:-}" in
  "image inspect") exit 0 ;;
  "volume inspect")
    # FAKE_VOL: the volume exists, labelled for repo FAKE_VOL_REPO with source FAKE_VOL_SRC.
    if [[ -n "${FAKE_VOL:-}" ]]; then
      case "$*" in
        *ai-containers.repo*) printf '%s\n' "${FAKE_VOL_REPO:-}" ;;
        *ai-containers.source*) printf '%s\n' "${FAKE_VOL_SRC:-}" ;;
        *) printf '\n' ;;
      esac
      exit 0
    fi
    exit 1 ;;
  "info "*|"info") printf '[]\n'; exit 0 ;;
esac
if [[ "$1" == run ]]; then printf '%s\n' "$@" -- >> "$DOCKER_ARGV"; fi
exit 0
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# repo <args…>: repo.sh under $HOME, its docker runs' arguments in $DOCKER_ARGV.
repo() {
  : > "$DOCKER_ARGV"; : > "$DOCKER_ARGV.calls"
  bash "$ENGINE_DIR/repo.sh" "$@" >"$TMP/out" 2>&1 </dev/null
  RC=$?
}
has_arg() { grep -qxF -- "$1" "$DOCKER_ARGV"; }

export HOME="$TMP/home"; mkdir -p "$HOME"
# ── A path source holding ':' — seeded, then synced ─────────────────────────
SRC="$TMP/s:rc"; mkdir -p "$SRC" && printf 'x\n' > "$SRC/file"
# repo.sh hands docker the resolved source; TMPDIR may be a symlink.
SRC_REAL="$(cd "$SRC" && pwd -P)"
repo add colon "$SRC"
[[ "$RC" == 0 ]] && has_arg --mount && has_arg "type=bind,\"source=$SRC_REAL\",\"destination=/src\",readonly" \
  && ! grep -qF -- "$SRC_REAL:/src" "$DOCKER_ARGV" \
  && pass "repo.sh add: a source path holding ':' reaches the seed container as a read-only --mount" \
  || fail "add, ':' source (rc=$RC; argv: $(grep -F 's:rc' "$DOCKER_ARGV" | tr '\n' ' '); out: $(tr '\n' ' ' < "$TMP/out"))"
FAKE_VOL=1 FAKE_VOL_REPO=colon repo sync colon
[[ "$RC" == 0 ]] && has_arg "type=bind,\"source=$SRC_REAL\",\"destination=/src\",readonly" && ! grep -qF 're-seeding' "$TMP/out" \
  && pass "repo.sh sync: so does it when the volume is refreshed" \
  || fail "sync, ':' source (rc=$RC; argv: $(grep -F 's:rc' "$DOCKER_ARGV" | tr '\n' ' '); out: $(tr '\n' ' ' < "$TMP/out"))"
# ── A path source that is not UTF-8: refused before any container runs ──────
BAD="$TMP/s"$'\xff'
if mkdir "$BAD" 2>/dev/null; then
  repo add badname "$BAD"
  [[ "$RC" != 0 && ! -s "$DOCKER_ARGV" ]] && grep -qF 'cannot be bound into the container' "$TMP/out" \
    && ! grep -q '^volume create' "$DOCKER_ARGV.calls" \
    && pass "repo.sh add: a source path that is not UTF-8 is refused before any volume is made or container runs" \
    || fail "add, non-UTF-8 source (rc=$RC; runs: $(grep -c -- '^--$' "$DOCKER_ARGV"); out: $(tr '\n' ' ' < "$TMP/out"))"
  # Registered (an older engine, or the bind backend, which never seeds), its
  # volume gone: sync re-seeds it, and is refused the same way before the
  # volume is made again. In a UTF-8 locale, where GNU grep suppresses the line.
  printf 'oldbad|path|%s|2026-01-01|2026-01-01|volume\n' "$BAD" >> "$HOME/.ai-containers/repos.conf"
  LC_ALL=C.UTF-8 repo sync oldbad
  [[ "$RC" != 0 && ! -s "$DOCKER_ARGV" ]] && ! grep -q '^volume create' "$DOCKER_ARGV.calls" \
    && grep -qF 'cannot be bound into the container' "$TMP/out" \
    && pass "repo.sh sync: re-seeding a registered source that is not UTF-8 is refused before the volume is made" \
    || fail "sync re-seed, non-UTF-8 source (rc=$RC; calls: $(tr '\n' ' ' < "$DOCKER_ARGV.calls"); out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-200))"
  sed -i '/^oldbad|/d' "$HOME/.ai-containers/repos.conf" 2>/dev/null || true
else
  printf 'SKIP: a name that is not UTF-8 — this filesystem refuses it\n'
fi
# A registry line holding such a byte is read back whole, whether or not the
# directory can exist here (bugs review REPO-18): GNU grep took it for binary,
# so a rewrite of the registry for another repo dropped it.
mkdir -p "$TMP/other"
printf 'ghost|path|%s|2026-01-01|2026-01-01|volume\n' "$TMP/g"$'\xff' >> "$HOME/.ai-containers/repos.conf"
LC_ALL=C.UTF-8 repo add other "$TMP/other"
grep -aqF "ghost|path|$TMP/g"$'\xff'"|" "$HOME/.ai-containers/repos.conf" \
  && pass "a registry line holding a byte that is not UTF-8 survives a rewrite for another repo" \
  || fail "registry rewrite dropped the non-UTF-8 line (rc=$RC; registry: $(grep -ac . "$HOME/.ai-containers/repos.conf") lines)"
LC_ALL=C.UTF-8 repo rm other --yes
grep -aqF "ghost|path|$TMP/g"$'\xff'"|" "$HOME/.ai-containers/repos.conf" \
  && pass "… and one that removes another repo's entry" \
  || fail "registry removal dropped the non-UTF-8 line (rc=$RC; out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-200))"
# ── A git source under a HOME holding ':': ~/.ssh as a --mount ──────────────
# Without ~/.ssh there first: nothing of it is bound (-v made a missing one,
# root-owned; --mount refuses one).
export HOME="$TMP/h:ome"; mkdir -p "$HOME"
repo add gitnossh https://example.invalid/n.git
[[ "$RC" == 0 ]] && ! grep -qE -- '(destination=/root/\.ssh-host|:/root/\.ssh-host:ro$)' "$DOCKER_ARGV" \
  && pass "repo.sh add of a git URL with no ~/.ssh binds none" \
  || fail "add, git, no ~/.ssh (rc=$RC; argv: $(grep -F '.ssh' "$DOCKER_ARGV" | tr '\n' ' '); out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-200))"
mkdir -p "$HOME/.ssh"
repo add gitrepo https://example.invalid/r.git
[[ "$RC" == 0 ]] && has_arg "type=bind,\"source=$HOME/.ssh\",\"destination=/root/.ssh-host\",readonly" \
  && pass "repo.sh add of a git URL: ~/.ssh under a HOME holding ':' reaches the clone as a read-only --mount" \
  || fail "add, git, ':' HOME (rc=$RC; argv: $(grep -F '.ssh' "$DOCKER_ARGV" | tr '\n' ' '); out: $(tr '\n' ' ' < "$TMP/out"))"

# The git helper that reset and sync of a git repo run (git_helper_run): ~/.ssh
# under a HOME holding ':' as a --mount too.
FAKE_VOL=1 FAKE_VOL_REPO=gitrepo FAKE_VOL_SRC=https://example.invalid/r.git repo sync gitrepo
[[ "$RC" == 0 ]] && ! grep -qF 're-seeding' "$TMP/out" \
  && has_arg "type=bind,\"source=$HOME/.ssh\",\"destination=/root/.ssh-host\",readonly" \
  && pass "repo.sh sync of a git repo: the helper gets ~/.ssh under a HOME holding ':' as a read-only --mount" \
  || fail "sync, git, ':' HOME (rc=$RC; argv: $(grep -F '.ssh' "$DOCKER_ARGV" | tr '\n' ' '); out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-300))"

# An empty source, however a record came to hold one, is never the current
# directory (bugs review REPO-18).
export HOME="$TMP/home"
printf 'nosrc|path||2026-01-01|2026-01-01|volume\n' >> "$HOME/.ai-containers/repos.conf"
mkdir -p "$TMP/src-cwd" && cd "$TMP/src-cwd" && repo sync nosrc; cd "$TMP" || exit 1
[[ "$RC" != 0 && ! -s "$DOCKER_ARGV" ]] && ! grep -q '^volume create' "$DOCKER_ARGV.calls" \
  && pass "a record with no source is refused, never seeded from the current directory" \
  || fail "empty source (rc=$RC; argv: $(tr '\n' ' ' < "$DOCKER_ARGV" | cut -c1-200); out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-200))"
# … nor mirrored into its existing volume (rsync with deletes).
cd "$TMP/src-cwd" && FAKE_VOL=1 FAKE_VOL_REPO=nosrc repo sync nosrc; cd "$TMP" || exit 1
[[ "$RC" != 0 && ! -s "$DOCKER_ARGV" ]] \
  && pass "a record with no source is refused, never mirrored from the current directory into its volume" \
  || fail "empty source, volume there (rc=$RC; argv: $(tr '\n' ' ' < "$DOCKER_ARGV" | cut -c1-200); out: $(tr '\n' ' ' < "$TMP/out" | cut -c1-200))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
