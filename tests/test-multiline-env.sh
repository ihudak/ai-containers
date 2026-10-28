#!/usr/bin/env bash
# Tests multiline-env.sh — the converter that rewrites one-line lists in a
# project's sandbox.local.env one entry per line.
#
# What it must never do is the thing that makes a converter worse than no
# converter: change what the launcher reads. So every case that writes reads the
# result back with the REAL loader, and the refusal cases check the file is left
# byte-for-byte alone — above all for a project whose own engine copy predates
# multi-line values, where a converted list would load as a bare `"`.
#
# Hermetic: throwaway project dirs, an isolated projects.conf, empty stdin.
set -uo pipefail
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: upstream keeps the engine at the repo root, mgd-ai-containers in base/.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/multiline-env.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

bash -n "$ENGINE_DIR/multiline-env.sh" && pass "multiline-env.sh bash -n" || fail "multiline-env.sh bash -n"

convert() { bash "$ENGINE_DIR/multiline-env.sh" "$@" </dev/null 2>&1; }

# read_back <env-file> — what the real loader sets for every key the fixture uses.
# A list is compared as its ENTRIES: every consumer splits it on whitespace, so
# the double space in the fixture below and the single one the converter writes
# are the same list. Every other key is compared exactly.
read_back() {
  bash -c '
    eval "$(sed -n "/^[A-Za-z_][A-Za-z0-9_]*() *{/,/^}/p" "$1")"
    unset EXTRA_MOUNTS REPOS PREVIEW_PORTS SANDBOX_MODE CONTAINER_CPUS
    load_env_defaults "$2" local
    for k in EXTRA_MOUNTS REPOS PREVIEW_PORTS; do
      read -r -a e <<<"${!k-unset}"; printf "%s=[%s]\n" "$k" "${e[*]}"
    done
    for k in SANDBOX_MODE CONTAINER_CPUS; do printf "%s=[%s]\n" "$k" "${!k-unset}"; done
  ' _ "$ENGINE_DIR/sandbox-common.sh" "$1"
}

# new_project <name> — a project whose .ai-containers/ carries the CURRENT loader.
new_project() {
  local p="$TMP/$1"
  mkdir -p "$p/.ai-containers"
  cp "$ENGINE_DIR/sandbox-common.sh" "$p/.ai-containers/sandbox-common.sh"
  printf '%s' "$p"
}

FIXTURE='# sandbox.local.env — a hand comment that must survive
SANDBOX_MODE=discovery
EXTRA_MOUNTS="/a:ro  /b /c:ro"
export REPOS="docs:ro cluster:ro"
PREVIEW_PORTS="4000:4000"
CONTAINER_CPUS=2
'

# ── Converts, and the launcher reads exactly what it read before ───────────────
P1="$(new_project one)"; F1="$P1/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F1"
want_values="$(read_back "$F1")"
out1="$(convert "$P1")"

want_file='# sandbox.local.env — a hand comment that must survive
SANDBOX_MODE=discovery
EXTRA_MOUNTS="
  /a:ro
  /b
  /c:ro
"
export REPOS="
  docs:ro
  cluster:ro
"
PREVIEW_PORTS="4000:4000"
CONTAINER_CPUS=2'
[[ "$(cat "$F1")" == "$want_file" ]] \
  && pass "lists of two or more go one per line; every other line is kept as it was" \
  || fail "lists of two or more go one per line — got:
$(cat "$F1")"
[[ "$(read_back "$F1")" == "$want_values" ]] \
  && pass "the loader reads the converted file back to the same values" \
  || fail "the loader reads the converted file back to the same values — want:
$want_values
got:
$(read_back "$F1")"
[[ "$(cat "$F1.pre-multiline" 2>/dev/null)" == "$(printf '%s' "$FIXTURE")" ]] \
  && pass "the old file is backed up as sandbox.local.env.pre-multiline" || fail "the old file is backed up as sandbox.local.env.pre-multiline"
grep -q 'Converted: 1' <<<"$out1" && pass "the summary counts the conversion" || fail "the summary counts the conversion — got: $out1"

# ── Idempotent: a second run finds nothing to do and writes no second backup ────
before_second="$(cat "$F1")"
out1b="$(convert "$P1")"
[[ "$(cat "$F1")" == "$before_second" ]] && grep -q 'SKIP' <<<"$out1b" \
  && pass "a second run changes nothing" || fail "a second run changes nothing — got: $out1b"
n_backups="$(find "$P1/.ai-containers" -name 'sandbox.local.env.pre-multiline*' | wc -l | tr -d ' ')"
[[ "$n_backups" == 1 ]] && pass "a second run writes no second backup" || fail "a second run writes no second backup (found $n_backups)"

# ── An existing backup is never overwritten ─────────────────────────────────────
P2="$(new_project two)"; F2="$P2/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F2"
printf 'the first backup\n' > "$F2.pre-multiline"
convert "$P2" >/dev/null
[[ "$(cat "$F2.pre-multiline")" == 'the first backup' ]] \
  && pass "an existing backup is not overwritten" || fail "an existing backup is not overwritten"
n_backups2="$(find "$P2/.ai-containers" -name 'sandbox.local.env.pre-multiline.*' | wc -l | tr -d ' ')"
[[ "$n_backups2" == 1 ]] && pass "the new backup takes a timestamped name instead" || fail "the new backup takes a timestamped name instead (found $n_backups2)"

# ── --dry-run writes nothing ────────────────────────────────────────────────────
P3="$(new_project three)"; F3="$P3/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F3"
out3="$(convert --dry-run "$P3")"
[[ "$(cat "$F3")" == "$(printf '%s' "$FIXTURE")" && ! -e "$F3.pre-multiline" ]] \
  && pass "--dry-run leaves the file and writes no backup" || fail "--dry-run leaves the file and writes no backup"
grep -q '^    +  /b$' <<<"$out3" && pass "--dry-run shows the change as a diff" || fail "--dry-run shows the change as a diff — got: $out3"

# ── An engine copy that cannot read a multi-line value is left alone ────────────
# The loader as it was before multi-line values: one line, one assignment.
P4="$TMP/four"; mkdir -p "$P4/.ai-containers"; F4="$P4/.ai-containers/sandbox.local.env"
cat > "$P4/.ai-containers/sandbox-common.sh" <<'EOF'
env_key_denied() {
  return 1
}
load_env_defaults() {
  local file="$1" line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ ${#val} -ge 2 && "$val" == '"'*'"' ]]; then val="${val:1:${#val}-2}"; fi
    [[ -n "${!key+x}" ]] && continue
    printf -v "$key" '%s' "$val"; export "$key"
  done < "$file"
}
EOF
printf '%s' "$FIXTURE" > "$F4"
out4="$(convert "$P4")"
[[ "$(cat "$F4")" == "$(printf '%s' "$FIXTURE")" && ! -e "$F4.pre-multiline" ]] \
  && pass "a project whose loader predates multi-line values is left unchanged" \
  || fail "a project whose loader predates multi-line values is left unchanged"
grep -q 'sync-to-projects' <<<"$out4" && pass "and the skip says to sync first" || fail "and the skip says to sync first — got: $out4"

# ── A conversion that would read back differently is refused ────────────────────
# An entry starting with `#` is part of a one-line value, but on a line of its own
# it is a comment the loader skips. The read-back check is what catches that.
P9="$(new_project nine)"; F9="$P9/.ai-containers/sandbox.local.env"
printf 'EXTRA_MOUNTS="/a #b"\n' > "$F9"
out9="$(convert "$P9")"
[[ "$(cat "$F9")" == 'EXTRA_MOUNTS="/a #b"' && ! -e "$F9.pre-multiline" ]] && grep -q 'would not read back' <<<"$out9" \
  && pass "a conversion that would read back differently is refused" || fail "a conversion that would read back differently is refused — got: $out9"

# ── Only sandbox.local.env: the shared sandbox.env is never touched ─────────────
P5="$(new_project five)"
printf 'PREVIEW_PORTS="4000:4000 4001:4001"\n' > "$P5/.ai-containers/sandbox.env"
printf 'REPOS="a:ro b:ro"\n' > "$P5/.ai-containers/sandbox.local.env"
convert "$P5" >/dev/null
[[ "$(cat "$P5/.ai-containers/sandbox.env")" == 'PREVIEW_PORTS="4000:4000 4001:4001"' ]] \
  && pass "the portable sandbox.env is not converted" || fail "the portable sandbox.env is not converted"

# ── Nothing to convert, and no file at all ──────────────────────────────────────
P6="$(new_project six)"; F6="$P6/.ai-containers/sandbox.local.env"
printf 'REPOS="docs:ro"\nSANDBOX_MODE=open\n' > "$F6"
out6="$(convert "$P6")"
[[ "$(cat "$F6")" == "$(printf 'REPOS="docs:ro"\nSANDBOX_MODE=open')" && ! -e "$F6.pre-multiline" ]] && grep -q SKIP <<<"$out6" \
  && pass "a one-entry list is left on one line" || fail "a one-entry list is left on one line — got: $out6"
P7="$(new_project seven)"
grep -q 'SKIP' <<<"$(convert "$P7")" && pass "a project with no sandbox.local.env is skipped" || fail "a project with no sandbox.local.env is skipped"

# ── Nothing is written through a symbolic link ──────────────────────────────────
# .ai-containers/ is inside the project, where an agent may be able to plant a link;
# this runs on the host, so following one would overwrite a host file of its choice.
P10="$(new_project ten)"; F10="$P10/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$TMP/elsewhere.env"
ln -s "$TMP/elsewhere.env" "$F10"
out10="$(convert "$P10")"
[[ "$(cat "$TMP/elsewhere.env")" == "$(printf '%s' "$FIXTURE")" && -L "$F10" ]] && grep -q 'symbolic link' <<<"$out10" \
  && pass "a sandbox.local.env that is a link is not written through" || fail "a sandbox.local.env that is a link is not written through — got: $out10"

P11="$(new_project eleven)"; F11="$P11/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F11"
ln -s "$TMP/planted-dangling" "$F11.pre-multiline"
printf 'precious\n' > "$TMP/planted-existing"
convert "$P11" >/dev/null
[[ ! -e "$TMP/planted-dangling" ]] \
  && pass "a dangling link at the backup name is not written through" || fail "a dangling link at the backup name is not written through"
grep -qx '  /b' "$F11" && pass "and the conversion still happens, with a timestamped backup" || fail "and the conversion still happens, with a timestamped backup"
P12="$(new_project twelve)"; F12="$P12/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F12"
ln -s "$TMP/planted-existing" "$F12.pre-multiline"
convert "$P12" >/dev/null
[[ "$(cat "$TMP/planted-existing")" == precious ]] \
  && pass "a link to an existing file at the backup name is not written through" || fail "a link to an existing file at the backup name is not written through"

# ── With no paths it works through --projects-conf ──────────────────────────────
P8="$(new_project eight)"; F8="$P8/.ai-containers/sandbox.local.env"
printf '%s' "$FIXTURE" > "$F8"
printf '# registry\n%s\n' "$P8" > "$TMP/projects.conf"
convert --projects-conf "$TMP/projects.conf" >/dev/null
grep -qx '  /b' "$F8" && pass "with no paths, every project in --projects-conf is converted" \
  || fail "with no paths, every project in --projects-conf is converted"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
