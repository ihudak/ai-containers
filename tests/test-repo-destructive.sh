#!/usr/bin/env bash
# tests/test-repo-destructive.sh — repo.sh's DESTRUCTIVE subcommands, exercised.
#
# repo.sh owns the operations that delete data shared by every project on the
# machine: `rm` removes a repo's base volume and its working copies, `reset`
# discards local state, `gc` collects orphans. Until this file, the hermetic
# suite ran exactly TWO of repo.sh's nineteen functions — `is_git_url` and
# `fmt_epoch` — because tests/test-repo-registry.sh sources it in a subshell
# deliberately arranged so dispatch never runs, which is the right call for a
# file that must not seed real Docker volumes (backlog F1).
#
# The consequence was that nothing anywhere asserted WHICH volumes `rm` deletes.
# A widened filter, a dropped guard, or an inverted confirmation check would
# have removed other repos' data with the whole suite green.
#
# HOW THIS IS SAFE. repo.sh is run as a REAL SUBPROCESS — dispatch included —
# against a fake `docker` on PATH that never contacts a daemon. Volumes are
# marker files in a temp directory; `docker volume rm` deletes a marker and, more
# importantly, APPENDS ITS ARGV TO A LOG. The assertions read that log, so what
# is being checked is the exact set of volumes repo.sh asked to destroy — not a
# side effect that happened to be survivable.
#
# HOME is redirected before repo.sh runs, so ~/.ai-containers/repos.conf is
# never read or written; the real registry is snapshotted and compared at the end.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/repo.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
REPO_SH="$ENGINE_DIR/repo.sh"

REAL_HOME="$HOME"
REAL_REGISTRY="$HOME/.ai-containers/repos.conf"
REAL_REGISTRY_BEFORE=""
[[ -f "$REAL_REGISTRY" ]] && REAL_REGISTRY_BEFORE="$(cat "$REAL_REGISTRY")"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'export HOME="$REAL_HOME"; rm -rf "$TMP"' EXIT

# ── the fake docker ───────────────────────────────────────────────────────────
# Deliberately minimal, and deliberately RECORDING. `volume rm` is the whole
# subject of this file, so every invocation is logged before anything else
# happens — a fake that only simulated the effect could not tell "removed the
# right volume" from "removed nothing at all".
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
export VOLS="$TMP/volumes"
export DOCKER_LOG="$TMP/docker.log"
# One volume name per line = "a running container has it mounted". `gc --unused`
# is the only caller, and it is the only reason this fake knows `docker ps`.
export INUSE="$TMP/inuse.txt"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "volume inspect")
    fmt=""; name=""; prev=""
    for a in "${@:3}"; do
      if [[ "$prev" == "--format" ]]; then fmt="$a"
      elif [[ "$a" != "--format" ]]; then name="$a"; fi
      prev="$a"
    done
    [[ -f "$VOLS/$name" ]] || exit 1
    if [[ "$fmt" == *Labels* ]]; then
      key="$(printf '%s' "$fmt" | sed -n 's/.*index \.Labels \\*"\([^\\"]*\).*/\1/p')"
      val=""
      [[ -f "$VOLS/$name.labels" ]] && val="$(grep "^${key}=" "$VOLS/$name.labels" 2>/dev/null | head -1 | cut -d= -f2-)"
      printf '%s\n' "$val"; exit 0
    fi
    printf '%s\n' "$name"; exit 0 ;;
  "ps "*|"ps")
    v=""
    for a in "$@"; do case "$a" in volume=*) v="${a#volume=}" ;; esac; done
    [[ -n "$v" ]] && grep -qx -- "$v" "$INUSE" 2>/dev/null && printf 'fake-container-id\n'
    exit 0 ;;
  "volume ls")
    substr=""
    for a in "$@"; do case "$a" in name=*) substr="${a#name=}" ;; esac; done
    for f in "$VOLS"/*; do
      [[ -f "$f" ]] || continue
      b="$(basename "$f")"
      [[ "$b" == *.labels ]] && continue          # sidecar, not a volume
      [[ -z "$substr" || "$b" == *"$substr"* ]] && printf '%s\n' "$b"
    done
    exit 0 ;;
  "volume rm")
    for a in "${@:3}"; do [[ "$a" == --* ]] || rm -f "$VOLS/$a"; done
    exit 0 ;;
  "image inspect") exit 0 ;;
esac
exit 0
FAKE
chmod +x "$FAKE_BIN/docker"

# ── a world: two repos, each with a working copy ──────────────────────────────
# `docs` is the SUBJECT. `docs-archive` is the BYSTANDER, and its name begins
# with the subject's — which is the shape a substring filter gets wrong.
setup_world() {
  export HOME="$TMP/home"; rm -rf "$HOME"; mkdir -p "$HOME/.ai-containers"
  rm -rf "$VOLS"; mkdir -p "$VOLS"
  : > "$DOCKER_LOG"
  : > "$VOLS/ai-containers-repo-docs"
  : > "$VOLS/ai-containers-repo-docs--wc-projA"
  : > "$VOLS/ai-containers-repo-docs--wc-projB"
  : > "$VOLS/ai-containers-repo-docs-archive"
  : > "$VOLS/ai-containers-repo-docs-archive--wc-projA"
  : > "$VOLS/ai-containers-repo-cluster"
  : > "$INUSE"
  # Labels are what `gc` reads to report a working copy's repo and launch dir.
  for wc in docs--wc-projA docs--wc-projB docs-archive--wc-projA; do
    printf 'ai-containers.repo=%s\nai-containers.launch-dir=/tmp/%s\n' "${wc%%--wc-*}" "$wc" \
      > "$VOLS/ai-containers-repo-$wc.labels"
  done
  {
    printf 'docs|git|git@x:docs.git|1700000000|1700000000|volume\n'
    printf 'docs-archive|git|git@x:docs-archive.git|1700000000|1700000000|volume\n'
    printf 'cluster|git|git@x:cluster.git|1700000000|1700000000|volume\n'
    # A bind-backend repo: no volume anywhere, and its source is a REAL host
    # directory this test creates, so "did it touch host files" is observable.
    printf 'localsrc|path|%s|1700000000|1700000000|bind\n' "$TMP/hostsrc"
  } > "$HOME/.ai-containers/repos.conf"
  rm -rf "$TMP/hostsrc"; mkdir -p "$TMP/hostsrc"
  printf 'uncommitted work\n' > "$TMP/hostsrc/DIRTY"
}

run_repo() {   # <args…> — repo.sh as a real subprocess; sets RC, OUT, ERR
  OUT="$TMP/out.txt"; ERR="$TMP/err.txt"
  PATH="$FAKE_BIN:$PATH" bash "$REPO_SH" "$@" >"$OUT" 2>"$ERR" </dev/null
  RC=$?
}

# What repo.sh asked docker to destroy, one per line, sorted.
removed() { sed -n 's/^volume rm //p' "$DOCKER_LOG" | tr ' ' '\n' | grep -v '^--' | sort | tr '\n' '|'; }

# ── 1. It refuses non-interactively without --yes, and destroys nothing ───────
# stdin is /dev/null, so `[[ -t 0 ]]` is false — the shape a script or a CI job
# has. The refusal is worth little on its own; the assertion that matters is
# that NOTHING was removed, because a guard that prints and continues looks
# identical in the log.
setup_world
run_repo rm docs
check "rm without --yes is refused non-interactively (rc=1)" "1" "$RC"
grep -q 'refusing to remove non-interactively' "$ERR" \
  && pass "  … saying why, by name" \
  || fail "  … saying why, by name (got: $(tr '\n' ' ' < "$ERR"))"
check "  … and NOTHING was removed" "" "$(removed)"
[[ -f "$VOLS/ai-containers-repo-docs" ]] \
  && pass "  … the base volume is still there" \
  || fail "  … the base volume is still there"

# ── 2. With --yes it removes the base volume and that repo's working copies ───
setup_world
run_repo rm docs --yes
check "rm --yes exits 0" "0" "$RC"
check "rm --yes removes the base volume and BOTH of its working copies" \
  "ai-containers-repo-docs|ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|" \
  "$(removed)"

# ── 3. THE BLAST RADIUS. A bystander whose name STARTS WITH the subject's ─────
# `docker volume ls --filter name=X` is a SUBSTRING match, so the working-copy
# filter must be anchored by the `--wc-` suffix or `docs` takes `docs-archive`
# with it. Asserted as an explicit absence, because case 2's expected set would
# also pass if the bystander had merely been removed first.
if [[ -f "$VOLS/ai-containers-repo-docs-archive" ]]; then
  pass "another repo's base volume is left alone"
else
  fail "another repo's base volume was REMOVED — 'rm docs' destroyed docs-archive"
fi
if [[ -f "$VOLS/ai-containers-repo-docs-archive--wc-projA" ]]; then
  pass "  … and so is its working copy"
else
  fail "  … and so is its working copy — the --wc- filter is not scoped to the named repo"
fi
if [[ -f "$VOLS/ai-containers-repo-cluster" ]]; then
  pass "  … and an unrelated repo is untouched"
else
  fail "  … and an unrelated repo is untouched"
fi

# ── 4. The registry entry goes, and ONLY that entry ───────────────────────────
check "rm --yes removes the registry entry" "" \
  "$(grep -c '^docs|' "$HOME/.ai-containers/repos.conf" 2>/dev/null | grep -v '^0$')"
check "  … and leaves the other two" "2" \
  "$(grep -cE '^(docs-archive|cluster)\|' "$HOME/.ai-containers/repos.conf" 2>/dev/null)"

# ── 5. An unregistered name with no volume removes nothing ────────────────────
setup_world
run_repo rm no-such-repo --yes
check "rm on an unknown repo exits 0" "0" "$RC"
grep -q 'Nothing to remove' "$OUT" \
  && pass "  … and says there was nothing to remove" \
  || fail "  … and says there was nothing to remove (got: $(tr '\n' ' ' < "$OUT"))"
check "  … having removed nothing" "" "$(removed)"

# ── 6. An invalid name is refused BEFORE any docker call ─────────────────────
# validate_repo_name runs first; if it did not, a name with a slash or a glob
# would reach `docker volume ls --filter` and could match anything.
setup_world
run_repo rm '../../etc' --yes
[[ "$RC" -ne 0 ]] \
  && pass "rm refuses an invalid repo name (rc=$RC)" \
  || fail "rm accepted '../../etc' (rc=$RC)"
check "  … before issuing a single docker command" "" "$(cat "$DOCKER_LOG")"

# ── 7. `rm` with no name at all is a usage error, not a wildcard ─────────────
setup_world
run_repo rm
[[ "$RC" -ne 0 ]] \
  && pass "rm with no name is refused (rc=$RC)" \
  || fail "rm with no name was accepted (rc=$RC)"
check "  … and removed nothing" "" "$(removed)"

# ═════════════════════════════════════════════════════════════════════════════
# SLICE 2 — `reset` and `gc`, the other two subcommands that delete data.
# ═════════════════════════════════════════════════════════════════════════════
#
# `reset` and `rm` destroy different things and the difference is the point:
# `rm` takes the base volume away, `reset` puts the base volume BACK to a clean
# state and removes only the working copies. A reset that removed the base would
# still look like success — the repo would simply be re-seeded on next use — so
# "the base volume survived" is asserted explicitly rather than inferred.

# ── 8. reset refuses non-interactively without --yes, and destroys nothing ────
setup_world
run_repo reset docs
check "reset without --yes is refused non-interactively (rc=1)" "1" "$RC"
grep -q 'refusing to reset non-interactively' "$ERR" \
  && pass "  … saying why, by name" \
  || fail "  … saying why, by name (got: $(tr '\n' ' ' < "$ERR"))"
check "  … and NOTHING was removed" "" "$(removed)"

# ── 9. reset --yes removes the working copies and KEEPS the base volume ───────
setup_world
run_repo reset docs --yes
check "reset --yes exits 0" "0" "$RC"
check "reset --yes removes that repo's working copies" \
  "ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|" \
  "$(removed)"
[[ -f "$VOLS/ai-containers-repo-docs" ]] \
  && pass "  … and the BASE volume survives — reset is not rm" \
  || fail "  … and the BASE volume survives — reset is not rm: the base volume was removed"

# ── 10. THE BLAST RADIUS, again, on the other subcommand ──────────────────────
[[ -f "$VOLS/ai-containers-repo-docs-archive--wc-projA" ]] \
  && pass "reset leaves another repo's working copy alone" \
  || fail "reset leaves another repo's working copy alone — 'reset docs' reached docs-archive"

# ── 11. A bind-backend repo is not touched AT ALL ─────────────────────────────
# A bind-backend repo has no volume: the container mounts the host path directly,
# so "reset it to a clean state" is not this script's to do, and `reset_one`
# returns early saying so and printing the git commands to do it by hand.
#
# Drop that early return and it treats the repo as volume-backed: it SEEDS A
# VOLUME from the host path and reports "reset to a clean state". Nothing is
# deleted — which is exactly why this needs an assertion. The user is told the
# repo they are about to run against was reset, while the thing that was reset
# is a volume no container will mount. The `DIRTY` file below is a control, not
# the guard: it must survive either way, and asserting it is how this file says
# that out loud rather than leaving a reader to assume the worse story.
setup_world
run_repo reset localsrc --yes
check "reset on a bind-backend repo exits 0" "0" "$RC"
check "  … removing no volumes" "" "$(removed)"
[[ -f "$TMP/hostsrc/DIRTY" ]] \
  && pass "  … and leaving the host source untouched" \
  || fail "  … and leaving the host source untouched — reset reached the host source, which nothing in this path should ever write to"
grep -q 'not touching host files' "$OUT" \
  && pass "  … and saying so, with the command to do it by hand" \
  || fail "  … and saying so (got: $(tr '\n' ' ' < "$OUT"))"

# ── 12. reset refuses what it cannot scope ───────────────────────────────────
setup_world
run_repo reset no-such-repo --yes
[[ "$RC" -ne 0 ]] && pass "reset on an unregistered repo is refused (rc=$RC)" \
                 || fail "reset accepted an unregistered repo (rc=$RC)"
check "  … removing nothing" "" "$(removed)"
setup_world; run_repo reset docs --all --yes
[[ "$RC" -ne 0 ]] && pass "reset with BOTH a name and --all is refused (rc=$RC)" \
                 || fail "reset accepted a name and --all together (rc=$RC)"
check "  … removing nothing" "" "$(removed)"
setup_world; run_repo reset --yes
[[ "$RC" -ne 0 ]] && pass "reset with neither a name nor --all is refused (rc=$RC)" \
                 || fail "reset with no target was accepted (rc=$RC)"
check "  … removing nothing" "" "$(removed)"
setup_world; run_repo reset docs --nonsense --yes
[[ "$RC" -ne 0 ]] && pass "reset rejects an unknown flag (rc=$RC)" \
                 || fail "reset accepted an unknown flag (rc=$RC)"
check "  … removing nothing" "" "$(removed)"

# ── 13. gc refuses non-interactively without --yes ───────────────────────────
setup_world
run_repo gc
check "gc without --yes is refused non-interactively (rc=1)" "1" "$RC"
check "  … and NOTHING was removed" "" "$(removed)"

# ── 14. gc --yes removes EVERY working copy and NO base volume ───────────────
# The scope is the danger here: gc with no --repo is repo-wide by design, so the
# assertion that matters is the one about what it must NOT touch.
setup_world
run_repo gc --yes
check "gc --yes exits 0" "0" "$RC"
check "gc --yes removes every working copy, across all repos" \
  "ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|ai-containers-repo-docs-archive--wc-projA|" \
  "$(removed)"
for base in ai-containers-repo-docs ai-containers-repo-docs-archive ai-containers-repo-cluster; do
  [[ -f "$VOLS/$base" ]] \
    && pass "  … and never a base volume ($base)" \
    || fail "  … and never a base volume — gc removed $base, which holds the repo itself"
done

# ── 15. gc --repo scopes to that repo, and the prefix bystander survives ─────
setup_world
run_repo gc --repo docs --yes
check "gc --repo docs removes only that repo's working copies" \
  "ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|" \
  "$(removed)"
[[ -f "$VOLS/ai-containers-repo-docs-archive--wc-projA" ]] \
  && pass "  … and docs-archive's working copy survives the substring filter" \
  || fail "  … and docs-archive's working copy survives the substring filter — gc --repo docs took it"

# ── 16. gc --unused keeps a copy a running container is using ────────────────
setup_world
printf 'ai-containers-repo-docs--wc-projA\n' > "$INUSE"
run_repo gc --unused --yes
check "gc --unused keeps the in-use copy and removes the rest" \
  "ai-containers-repo-docs--wc-projB|ai-containers-repo-docs-archive--wc-projA|" \
  "$(removed)"
grep -q 'in use — kept' "$OUT" \
  && pass "  … and says which one it kept, and why" \
  || fail "  … and says which one it kept, and why (got: $(tr '\n' ' ' < "$OUT"))"
# THE CONTROL: without --unused the same in-use copy IS removed, so the case
# above cannot pass merely because something else spared it.
setup_world
printf 'ai-containers-repo-docs--wc-projA\n' > "$INUSE"
run_repo gc --yes
case "$(removed)" in
  *ai-containers-repo-docs--wc-projA*) pass "  … control: without --unused, an in-use copy is still removed" ;;
  *) fail "  … control: without --unused, an in-use copy is still removed — got: $(removed)" ;;
esac

# ── 17. gc refuses what it cannot scope ──────────────────────────────────────
setup_world
run_repo gc --repo '../../etc' --yes
[[ "$RC" -ne 0 ]] && pass "gc rejects an invalid --repo name (rc=$RC)" \
                 || fail "gc accepted '../../etc' as --repo (rc=$RC)"
check "  … before issuing a single docker command" "" "$(cat "$DOCKER_LOG")"
setup_world; run_repo gc --repo
[[ "$RC" -ne 0 ]] && pass "gc rejects --repo with no name (rc=$RC)" \
                 || fail "gc accepted a bare --repo (rc=$RC)"
setup_world; run_repo gc --nonsense --yes
[[ "$RC" -ne 0 ]] && pass "gc rejects an unknown flag (rc=$RC)" \
                 || fail "gc accepted an unknown flag (rc=$RC)"
check "  … removing nothing" "" "$(removed)"

# ── Hermeticity ───────────────────────────────────────────────────────────────
export HOME="$REAL_HOME"
if [[ -n "$REAL_REGISTRY_BEFORE" ]]; then
  check "the real registry is byte-identical afterwards" "$REAL_REGISTRY_BEFORE" "$(cat "$REAL_REGISTRY" 2>/dev/null)"
elif [[ -f "$REAL_REGISTRY" ]]; then
  fail "this test CREATED $REAL_REGISTRY — HOME was not redirected for every run"
else
  pass "the real registry was never created"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
