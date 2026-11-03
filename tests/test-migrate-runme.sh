#!/usr/bin/env bash
# Tests migrate-runme.sh, and the project-init.sh contract it depends on.
#
# The bug this pins: migrate-runme.sh sourced project-init.sh to reuse
# emit_launcher(), on the stated assumption that project-init.sh "returns early
# when sourced". NEITHER existed — no emit_launcher anywhere in the repo, and no
# sourcing guard. Two failure modes, both silent or destructive:
#
#   empty stdin      project-init.sh's first `read -r -p` returns non-zero on
#                    EOF; under the inherited `set -euo pipefail` that killed the
#                    whole process at the source line — EXIT 1, ZERO OUTPUT. And
#                    because the source happened BEFORE argument parsing, even
#                    --dry-run could not save you.
#   non-empty stdin  the full interactive wizard RAN as a side effect, rsyncing
#                    files and appending to projects.conf for whatever path was
#                    on stdin — not necessarily the project being migrated.
#
# That is the same shape as the data-loss bug this script exists to help recover
# from: something that "succeeds" while mutating the wrong thing.
#
# Hermetic: throwaway project dirs, an isolated projects.conf, empty stdin
# everywhere (the non-interactive case that used to die silently).
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like verify-on-host.sh's TESTS_DIR and the integration runner:
# upstream keeps the engine at the repo root, mgd-ai-containers keeps it in
# base/. One copy serves both verbatim — a second copy is how mgd's harness
# silently fell 117 lines behind.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/migrate-runme.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

bash -n "$ENGINE_DIR/migrate-runme.sh" && pass "migrate-runme.sh bash -n" \
  || fail "migrate-runme.sh bash -n"
bash -n "$ENGINE_DIR/project-init.sh" && pass "project-init.sh bash -n" \
  || fail "project-init.sh bash -n"

# ── The contract migrate-runme.sh depends on ────────────────────────────────────
# Sourcing project-init.sh must be SILENT (no wizard) and must define the helpers
# and globals the caller needs. Each of these was false before the fix.
src_out="$(cd "$ENGINE_DIR" && bash -c '
    source ./project-init.sh </dev/null 2>&1
    printf "rc=%s\n" "$?"
    declare -F emit_launcher    >/dev/null && printf "emit_launcher=yes\n"
    declare -F valid_group_name >/dev/null && printf "valid_group_name=yes\n"
    [[ -n "${projects_conf:-}" ]] && printf "projects_conf=set\n"
  ' 2>&1)"

case "$src_out" in
  *"rc=0"*) pass "sourcing project-init.sh succeeds (guard returns early)" ;;
  *)        fail "sourcing project-init.sh succeeds — got: $src_out" ;;
esac
case "$src_out" in
  *emit_launcher=yes*)    pass "sourcing defines emit_launcher" ;;
  *)                      fail "sourcing defines emit_launcher" ;;
esac
case "$src_out" in
  *valid_group_name=yes*) pass "sourcing defines valid_group_name" ;;
  *)                      fail "sourcing defines valid_group_name" ;;
esac
# The guard must sit AFTER these globals: too early and the caller gets an
# unbound projects_conf, too late and the wizard has already started prompting.
case "$src_out" in
  *projects_conf=set*)    pass "sourcing leaves projects_conf set (guard is after the globals)" ;;
  *)                      fail "sourcing leaves projects_conf set (guard is after the globals)" ;;
esac
# The wizard's own output must NOT appear — that would mean it ran.
case "$src_out" in
  *"Project name"*|*"already exists"*|*"Wrote "*)
      fail "sourcing project-init.sh does not run the wizard — it produced wizard output" ;;
  *)  pass "sourcing project-init.sh does not run the wizard" ;;
esac

# ── A real migration, non-interactively ─────────────────────────────────────────
proj="$TMP/proj"
mkdir -p "$proj/.ai-containers"
cat > "$proj/.ai-containers/runme.sh" <<'OLD'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export IMAGE_NAME=proj-ai-container
export EXTRA_MOUNTS="/some/path:ro"
./build.sh
./sandbox.sh restricted @app
OLD
chmod +x "$proj/.ai-containers/runme.sh"

out="$(cd "$ENGINE_DIR" && bash ./migrate-runme.sh \
        --projects-conf "$TMP/projects.conf" "$proj" </dev/null 2>&1)"
rc=$?

# Exit 0 with output is the whole point: the pre-fix script exited 1 silently.
[[ "$rc" -eq 0 ]] && pass "migrate-runme.sh exits 0 on a real migration (was: silent exit 1)" \
                  || fail "migrate-runme.sh exits 0 on a real migration (exit $rc): $out"
[[ -n "$out" ]] && pass "migrate-runme.sh produces output (was: none at all)" \
                || fail "migrate-runme.sh produces output"

[[ -f "$proj/.ai-containers/sandbox.env" ]] \
  && pass "wrote sandbox.env" || fail "wrote sandbox.env"
[[ -f "$proj/.ai-containers/runme.sh.pre-migrate" ]] \
  && pass "backed the old launcher up as .pre-migrate" \
  || fail "backed the old launcher up as .pre-migrate"

# The launcher must be the THIN one, i.e. emit_launcher actually ran.
grep -q 'Thin wrapper generated by' "$proj/.ai-containers/runme.sh" \
  && pass "emitted the thin runme.sh (emit_launcher ran)" \
  || fail "emitted the thin runme.sh (emit_launcher ran)"
grep -q './sandbox.sh' "$proj/.ai-containers/runme.sh" \
  && pass "the thin launcher calls ./sandbox.sh" \
  || fail "the thin launcher calls ./sandbox.sh"

# Machine-specific settings must survive the migration, not be silently dropped.
grep -q 'EXTRA_MOUNTS="/some/path:ro"' "$proj/.ai-containers/sandbox.local.env" 2>/dev/null \
  && pass "preserved EXTRA_MOUNTS into sandbox.local.env" \
  || fail "preserved EXTRA_MOUNTS into sandbox.local.env"
grep -q 'SANDBOX_MODE=restricted' "$proj/.ai-containers/sandbox.env" 2>/dev/null \
  && pass "parsed SANDBOX_MODE=restricted from the old launcher" \
  || fail "parsed SANDBOX_MODE=restricted from the old launcher"

# ── --dry-run must change nothing ──────────────────────────────────────────────
proj2="$TMP/proj2"
mkdir -p "$proj2/.ai-containers"
cp "$proj/.ai-containers/runme.sh.pre-migrate" "$proj2/.ai-containers/runme.sh"
before="$(ls "$proj2/.ai-containers" | sort | tr '\n' ' ')"
(cd "$ENGINE_DIR" && bash ./migrate-runme.sh --dry-run \
   --projects-conf "$TMP/projects.conf2" "$proj2" </dev/null >/dev/null 2>&1)
after="$(ls "$proj2/.ai-containers" | sort | tr '\n' ' ')"
[[ "$before" == "$after" ]] \
  && pass "--dry-run writes nothing" \
  || fail "--dry-run writes nothing (before: $before / after: $after)"

# The first migration's launcher ran `restricted @app`: a working dir other than
# the project itself is this machine's, which a shared sandbox.env cannot set —
# it lands in sandbox.local.env (re-review of 3529f22, F4).
! grep -q '^SANDBOX_WORKDIR=@app' "$proj/.ai-containers/sandbox.env" \
  && grep -qx 'SANDBOX_WORKDIR=@app' "$proj/.ai-containers/sandbox.local.env" 2>/dev/null \
  && grep -qx 'SANDBOX_WORKDIR=..' "$proj/.ai-containers/sandbox.env" \
  && pass "a non-portable working dir migrates into sandbox.local.env" \
  || fail "workdir after migration: $(grep -h SANDBOX_WORKDIR "$proj/.ai-containers/"sandbox*.env 2>&1 | tr '\n' ' ')"

# ── An old launcher in the host group ───────────────────────────────────────────
# The host group, which mounted this machine's real $HOME dot-directories, is
# gone: the migration moves the project to the default group and says how to
# start one from those files (AI_CONTAINER_GROUP_INIT=from:host).
hproj="$TMP/hproj"; mkdir -p "$hproj/.ai-containers"
cat > "$hproj/.ai-containers/runme.sh" <<'OLD'
#!/usr/bin/env bash
export IMAGE_NAME=hproj-ai-container
export AI_CONTAINER_GROUP=host
./build.sh
./sandbox.sh restricted ..
OLD
hout="$( cd "$ENGINE_DIR" && bash ./migrate-runme.sh --projects-conf "$TMP/projects.conf" "$hproj" </dev/null 2>&1 )"
grep -qx 'AI_CONTAINER_GROUP=default' "$hproj/.ai-containers/sandbox.env" \
  && ! grep -qs '^AI_CONTAINER_GROUP=host' "$hproj/.ai-containers/sandbox.env" "$hproj/.ai-containers/sandbox.local.env" \
  && grep -qF 'AI_CONTAINER_GROUP_INIT=from:host' <<<"$hout" \
  && pass "a host-group launcher migrates to the default group, saying how to start it from \$HOME" \
  || fail "host group after migration: $(grep -h AI_CONTAINER_GROUP "$hproj/.ai-containers/"sandbox*.env 2>&1 | tr '\n' ' '); $(grep -F host <<<"$hout" | head -2 | tr '\n' ' ')"

# ── Every path through a run says what it did, and only that ───────────────────
# A clean migration names no error and no dry run, and counts itself once.
case "$out" in
  *"ERROR processing"*|*"(dry-run"*|*"is a link or not a regular file"*)
        fail "a clean migration reports no error, no dry run, no odd sandbox.env: $out" ;;
  *"Migrated: 1  Skipped: 0"*) pass "a clean migration reports no error, no dry run, and counts itself" ;;
  *)    fail "a clean migration counts itself (Migrated: 1  Skipped: 0): $out" ;;
esac
# The old launcher had neither PREVIEW_PORTS nor `--no-cache`, so neither is written or noted.
! grep -q '^PREVIEW_PORTS' "$proj/.ai-containers/sandbox.env" && [[ "$out" != *"--no-cache active"* ]] \
  && pass "no PREVIEW_PORTS line and no --no-cache NOTE when the old launcher had neither" \
  || fail "no PREVIEW_PORTS line and no --no-cache NOTE when the old launcher had neither: $out"
# The host-group launcher ran `restricted ..` and set nothing machine-local: no sandbox.local.env.
[[ ! -e "$hproj/.ai-containers/sandbox.local.env" ]] \
  && pass "nothing machine-local means no sandbox.local.env" \
  || fail "nothing machine-local means no sandbox.local.env: $(cat "$hproj/.ai-containers/sandbox.local.env")"

mig() { (cd "$ENGINE_DIR" && bash ./migrate-runme.sh --projects-conf "$TMP/none.conf" "$@" </dev/null 2>&1); }
# mkproj NAME — a project whose old launcher is stdin; prints its path.
mkproj() { mkdir -p "$TMP/$1/.ai-containers" && cat > "$TMP/$1/.ai-containers/runme.sh" && printf '%s' "$TMP/$1"; }
fat="$TMP/proj/.ai-containers/runme.sh.pre-migrate"

# A dry run says so and counts the project, with no error.
dout="$(mig --dry-run "$proj2")"
[[ "$dout" == *"(dry-run: nothing was written)"* && "$dout" == *"Migrated: 1  Skipped: 0"* && "$dout" != *"ERROR processing"* ]] \
  && pass "--dry-run says so and counts the project" || fail "--dry-run says so and counts the project: $dout"

# ── Arguments ──────────────────────────────────────────────────────────────────
mig --help >/dev/null; rc=$?
[[ $rc -eq 0 ]] && pass "--help exits 0" || fail "--help exits 0 (exit $rc)"
aout="$(mig --bogus)"; rc=$?
[[ $rc -ne 0 && "$aout" == *"unknown argument: --bogus"* ]] && pass "an unknown option is refused" \
  || fail "an unknown option is refused (exit $rc): $aout"
nout="$(cd "$ENGINE_DIR" && bash ./migrate-runme.sh --projects-conf "$TMP/no-such.conf" </dev/null 2>&1)"; rc=$?
[[ $rc -ne 0 && "$nout" == *"ERROR: no projects.conf at $TMP/no-such.conf"* ]] \
  && pass "no paths and no projects.conf is refused" || fail "no paths and no projects.conf is refused (exit $rc): $nout"
# Paths from projects.conf: blank lines and comments are not projects.
cproj="$(mkproj cproj <<'OLD'
export IMAGE_NAME=cproj-img
./sandbox.sh open ..
OLD
)"
printf '# a comment\n\n%s\n' "$cproj" > "$TMP/list.conf"
cout="$(cd "$ENGINE_DIR" && bash ./migrate-runme.sh --projects-conf "$TMP/list.conf" </dev/null 2>&1)"; rc=$?
[[ $rc -eq 0 && "$cout" == *"Migrated: 1  Skipped: 0"* && "$cout" != *ERROR* ]] \
  && grep -qx 'IMAGE_NAME=cproj-img' "$cproj/.ai-containers/sandbox.env" \
  && pass "projects.conf: its one project is migrated, its comment and blank line are skipped" \
  || fail "projects.conf: its one project is migrated, its comment and blank line are skipped (exit $rc): $cout"

# ── Values carried over ────────────────────────────────────────────────────────
# IMAGE_NAME, PREVIEW_PORTS and AI_CONTAINER_GROUP from the old launcher; the
# existing sandbox.env and sandbox.local.env are backed up byte for byte.
f1="$(mkproj f1 <<'OLD'
export IMAGE_NAME=custom-img
export PREVIEW_PORTS="3000:3000"
export AI_CONTAINER_GROUP=team
./build.sh --no-cache
./sandbox.sh restricted ..
OLD
)"; d1="$f1/.ai-containers"
printf 'IMAGE_NAME=from-env\n' > "$d1/sandbox.env"
printf 'GITHUB_TOKEN=mine\n' > "$d1/sandbox.local.env"
o1="$(mig "$f1")"
grep -qx 'IMAGE_NAME=custom-img' "$d1/sandbox.env" \
  && pass "the old launcher's IMAGE_NAME wins over sandbox.env's" \
  || fail "the old launcher's IMAGE_NAME wins over sandbox.env's: $(grep IMAGE_NAME "$d1/sandbox.env")"
grep -qx 'PREVIEW_PORTS="3000:3000"' "$d1/sandbox.env" && pass "PREVIEW_PORTS is carried into sandbox.env" \
  || fail "PREVIEW_PORTS is carried into sandbox.env"
[[ "$o1" == *"--no-cache active"* && "$o1" != *"WARN: parsed AI_CONTAINER_GROUP"* && "$o1" != *"ERROR"* ]] \
  && grep -qx 'AI_CONTAINER_GROUP=team' "$d1/sandbox.env" \
  && pass "an active --no-cache is noted; a valid group is kept with no warning" \
  || fail "an active --no-cache is noted; a valid group is kept with no warning: $o1"
[[ "$(cat "$d1/sandbox.env.pre-migrate" 2>/dev/null)" == IMAGE_NAME=from-env \
   && "$(cat "$d1/sandbox.local.env.pre-migrate" 2>/dev/null)" == GITHUB_TOKEN=mine ]] \
  && [[ -z "$(compgen -G "$d1/*.pre-migrate.*")" && "$o1" != *"is a link"* ]] \
  && pass "sandbox.env and sandbox.local.env are backed up as *.pre-migrate" \
  || fail "sandbox.env and sandbox.local.env are backed up as *.pre-migrate: $(ls -A "$d1") $o1"
# The second migration of a project keeps the first backups, and backs up beside them.
f2="$(mkproj f2 < "$d1/runme.sh.pre-migrate")"; d2="$f2/.ai-containers"
printf 'IMAGE_NAME=second\n' > "$d2/sandbox.env"
printf 'X=second\n' > "$d2/sandbox.local.env"
for f in sandbox.env runme.sh sandbox.local.env; do printf 'FIRST\n' > "$d2/$f.pre-migrate"; done
o2="$(mig "$f2")"
ok=1
for f in sandbox.env runme.sh sandbox.local.env; do
  [[ "$(cat "$d2/$f.pre-migrate")" == FIRST ]] || ok=0
  [[ -n "$(compgen -G "$d2/$f.pre-migrate.*")" ]] || ok=0
done
[[ $ok -eq 1 && "$(cat "$d2"/sandbox.env.pre-migrate.*)" == IMAGE_NAME=second \
   && "$(cat "$d2"/sandbox.local.env.pre-migrate.*)" == X=second ]] \
  && pass "an existing .pre-migrate is kept; the new backup is timestamped beside it" \
  || fail "an existing .pre-migrate is kept; the new backup is timestamped beside it: $(ls -A "$d2") $o2"
# No IMAGE_NAME in the old launcher: sandbox.env's is kept.
f3="$(mkproj f3 <<'OLD'
export AI_CONTAINER_GROUP=bad/name
./sandbox.sh open ..
OLD
)"; d3="$f3/.ai-containers"
printf 'IMAGE_NAME=from-env\n' > "$d3/sandbox.env"
o3="$(mig "$f3")"
grep -qx 'IMAGE_NAME=from-env' "$d3/sandbox.env" && pass "with no IMAGE_NAME in the old launcher, sandbox.env's is kept" \
  || fail "with no IMAGE_NAME in the old launcher, sandbox.env's is kept: $(grep IMAGE_NAME "$d3/sandbox.env")"
[[ "$o3" == *"WARN: parsed AI_CONTAINER_GROUP=bad/name looks invalid"* ]] && pass "an invalid group is warned about" \
  || fail "an invalid group is warned about: $o3"

# sandbox.local.env holds exactly what was set, and only when something was.
r1="$(mkproj r1 <<'OLD'
export EXTRA_MOUNTS="/m:ro"
./sandbox.sh open ..
OLD
)"
r2="$(mkproj r2 <<'OLD'
export AI_CONTAINER_GROUP_INIT=from:host
./sandbox.sh open ..
OLD
)"
r3="$(mkproj r3 <<'OLD'
export REPOS="app:rw"
./sandbox.sh open ..
OLD
)"
mig "$r1" "$r2" "$r3" >/dev/null
[[ "$(grep -v '^#' "$r1/.ai-containers/sandbox.local.env" 2>/dev/null)" == 'EXTRA_MOUNTS="/m:ro"' ]] \
  && pass "EXTRA_MOUNTS alone: sandbox.local.env holds just that" \
  || fail "EXTRA_MOUNTS alone: sandbox.local.env holds just that: $(cat "$r1/.ai-containers/sandbox.local.env" 2>&1)"
[[ "$(grep -v '^#' "$r2/.ai-containers/sandbox.local.env" 2>/dev/null)" == 'AI_CONTAINER_GROUP_INIT=from:host' ]] \
  && pass "AI_CONTAINER_GROUP_INIT alone: sandbox.local.env holds just that" \
  || fail "AI_CONTAINER_GROUP_INIT alone: sandbox.local.env holds just that: $(cat "$r2/.ai-containers/sandbox.local.env" 2>&1)"
[[ "$(grep -v '^#' "$r3/.ai-containers/sandbox.local.env" 2>/dev/null)" == 'REPOS="app:rw"' ]] \
  && pass "REPOS alone: sandbox.local.env holds just that" \
  || fail "REPOS alone: sandbox.local.env holds just that: $(cat "$r3/.ai-containers/sandbox.local.env" 2>&1)"

# A sandbox.env that is a link is named, not backed up, and replaced by a file.
o4="$(mkproj o4 <<'OLD'
./sandbox.sh open ..
OLD
)"
ln -s "$TMP/no-such-target" "$o4/.ai-containers/sandbox.env"
oo4="$(mig "$o4")"
[[ "$oo4" == *"sandbox.env is a link or not a regular file"* && -f "$o4/.ai-containers/sandbox.env" \
   && ! -L "$o4/.ai-containers/sandbox.env" && ! -e "$TMP/no-such-target" ]] \
  && pass "a linked sandbox.env is named and replaced, not followed" \
  || fail "a linked sandbox.env is named and replaced, not followed: $oo4"

# ── Skipped projects are skipped, not errors ───────────────────────────────────
s_link="$TMP/s_link"; mkdir -p "$s_link/.ai-containers"; ln -s "$fat" "$s_link/.ai-containers/runme.sh"
s_none="$TMP/s_none"; mkdir -p "$s_none/.ai-containers"
s_big="$TMP/s_big"; mkdir -p "$s_big/.ai-containers"; head -c 16777217 /dev/zero > "$s_big/.ai-containers/runme.sh"
sout="$(mig "$s_link" "$s_none" "$s_big" "$proj")"
[[ "$sout" == *"Migrated: 0  Skipped: 4"* && "$sout" != *ERROR* && "$sout" == *"already thin"* \
   && "$sout" == *"could not be read as a regular file"* && "$sout" == *"runme.sh is a link"* ]] \
  && pass "a linked, missing, unreadable or already thin runme.sh is skipped, not an error" \
  || fail "a linked, missing, unreadable or already thin runme.sh is skipped, not an error: $sout"
rm -f "$s_big/.ai-containers/runme.sh"

# ── Failures stop that project and say so ─────────────────────────────────────
# fails_with WHAT OUTPUT PATTERN — OUTPUT holds PATTERN and the per-project
# "ERROR processing" line, which only a non-zero process_project prints.
fails_with() {
  [[ "$2" == *"$3"* && "$2" == *"ERROR processing"* ]] && pass "$1" || fail "$1: $2"
}
e_link="$TMP/e_link"; mkdir -p "$e_link" "$TMP/e_link_target"; ln -s "$TMP/e_link_target" "$e_link/.ai-containers"
fails_with "a .ai-containers that is a link is an error" "$(mig "$e_link")" "is a link; refusing"
# Fakes on PATH: an mktemp that fails, an mv that fails onto one named file.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
real_mv="$(command -v mv)"; real_mktemp="$(command -v mktemp)"
printf '#!/bin/sh\n[ -n "$FAKE_MKTEMP_FAIL" ] && exit 1\nexec "%s" "$@"\n' "$real_mktemp" > "$FAKE/mktemp"
printf '#!/bin/sh\nfor a; do last="$a"; done\n[ -n "$FAKE_MV_FAIL" ] && [ "${last##*/}" = "$FAKE_MV_FAIL" ] && exit 1\nexec "%s" "$@"\n' "$real_mv" > "$FAKE/mv"
chmod +x "$FAKE/mktemp" "$FAKE/mv"
e_mk="$(mkproj e_mk < "$fat")"
fails_with "a failed mktemp is an error" "$(PATH="$FAKE:$PATH" FAKE_MKTEMP_FAIL=1 mig "$e_mk")" "ERROR"
e_big="$(mkproj e_big < "$fat")"
head -c 16777217 /dev/zero > "$e_big/.ai-containers/sandbox.env"
fails_with "a sandbox.env that cannot be read is an error" "$(mig "$e_big")" "cannot read"
[[ ! -e "$e_big/.ai-containers/runme.sh.pre-migrate" ]] && ! grep -q 'Thin wrapper generated by' "$e_big/.ai-containers/runme.sh" \
  && pass "... and that project is left as it was" || fail "... and that project is left as it was: $(ls -A "$e_big/.ai-containers")"
rm -f "$e_big/.ai-containers/sandbox.env"
if [[ "$(id -u)" != 0 ]]; then
  e_pin="$(mkproj e_pin < "$fat")"
  chmod 311 "$e_pin/.ai-containers"
  pout="$(mig "$e_pin")"
  chmod 755 "$e_pin/.ai-containers"
  fails_with "a .ai-containers that cannot be held open is an error" "$pout" "cannot hold"
else
  pass "a .ai-containers that cannot be held open is an error (not checkable as root)"
fi
for target in sandbox.env.pre-migrate runme.sh.pre-migrate sandbox.local.env.pre-migrate \
              sandbox.env sandbox.local.env runme.sh; do
  ew="$(mkproj "ew-$target" < "$fat")"
  printf 'IMAGE_NAME=x\n' > "$ew/.ai-containers/sandbox.env"
  printf 'X=1\n' > "$ew/.ai-containers/sandbox.local.env"
  fails_with "a failed write of $target is an error" \
    "$(PATH="$FAKE:$PATH" FAKE_MV_FAIL="$target" mig "$ew")" "ERROR: could not"
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
