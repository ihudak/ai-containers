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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
