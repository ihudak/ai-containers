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

# p_realdir: an independently-derived physical path, for asserting against a
# mount that repo.sh resolved. See its use in setup_path_world below.
# shellcheck source=./portability.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"

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
export TMP_LABELS="$TMP/.labels.tmp"
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
  "volume create")
    name=""; : > "$TMP_LABELS"
    for a in "${@:3}"; do
      case "$a" in
        --label) ;;
        *=*) [[ "$prev_label" == "--label" ]] && printf '%s\n' "$a" >> "$TMP_LABELS" || name="$a" ;;
        *) [[ "$a" == --* ]] || name="$a" ;;
      esac
      prev_label="$a"
    done
    [[ -n "$name" ]] && { : > "$VOLS/$name"; cp "$TMP_LABELS" "$VOLS/$name.labels"; }
    exit 0 ;;
  "volume rm")
    for a in "${@:3}"; do [[ "$a" == --* ]] || rm -f "$VOLS/$a"; done
    exit 0 ;;
  "image inspect") exit 0 ;;
esac
# `docker run` of the git helper. A fake that returned nothing would leave
# repo.sh with no PRIMARY record, sending every reset down the "no branch to
# reset onto" path — and the assertions in SLICE 2 would still pass, because
# they were written before there was a git half to miss. So the inspect call
# answers with a canned report, which exercises repo.sh's record parsing, its
# summary, and the threading of the primary branch into the reset call.
# What the helper does to a real repository is asserted in
# tests/test-repo-git-reset.sh, which runs it against real git.
if [[ "$1" == "run" ]]; then
  case "$*" in
    *" inspect /dst"*)
      # HELPER_NO_PRIMARY: the helper found no branch to reset onto — a detached
      # HEAD with no usable remote. repo.sh must leave that repo untouched and
      # still report SUCCESS: a skip is not a failure, and under --all one such
      # repo must not fail the whole run.
      [[ -n "${HELPER_NO_PRIMARY:-}" ]] || printf 'PRIMARY|main\n'
      printf 'BRANCH|main|0|current\n'
      printf 'BRANCH|feat/unpushed|3|\n'
      printf 'BRANCH|fix/pushed|0|\n'
      exit 0 ;;
    *" reset /dst"*)
      # HELPER_RESET_FAILS: the git reset failed inside the seed container. The
      # opposite obligation to the one above — a destructive command that could
      # not do the work must never exit 0.
      [[ -z "${HELPER_RESET_FAILS:-}" ]] || exit 1
      # The records repo.sh renders into prose. SOMETHING-NEW is deliberate: a
      # record type this version of repo.sh does not know must still reach the
      # user, because silence is the one thing a destructive command must never
      # report.
      printf 'DELETED|feat/unpushed\n'
      printf 'DELETED|fix/pushed\n'
      printf 'KEPT|stubborn|could not delete\n'
      printf 'WARN|chown failed\n'
      printf 'ON|main\n'
      printf 'AT|abc1234\n'
      printf 'DELETED-COUNT|2\n'
      printf 'SOMETHING-NEW|from a future helper\n'
      exit 0 ;;
  esac
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/docker"

# A machine that has never registered a repo: no volumes, no registry entries.
# Every "nothing to do" path in repo.sh is reached from here, and this is the
# state a fresh checkout is in — the one a provisioning script meets first.
setup_empty_world() {
  export HOME="$TMP/home"; rm -rf "$HOME"; mkdir -p "$HOME/.ai-containers"
  rm -rf "$VOLS"; mkdir -p "$VOLS"
  : > "$DOCKER_LOG"; : > "$INUSE"
  : > "$HOME/.ai-containers/repos.conf"
}

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

# ── 8b. reset RUNS the git helper, and hands it what the summary promised ─────
#
# The three assertions below are what stands between "reset removed the working
# copies" — which was the whole of this file's reset coverage — and "reset
# actually reset the checkout". Without them the git half could be deleted
# entirely and SLICE 2 would stay green.
setup_world
run_repo reset docs --yes
check "reset --yes exits 0 (git helper path)" "0" "$RC"

if grep -q -- 'repo-git-reset.sh:/repo-git-reset.sh:ro' "$DOCKER_LOG"; then
  pass "reset mounts the git helper into the seed container, read-only"
else
  fail "reset mounts the git helper into the seed container, read-only
$(grep '^run ' "$DOCKER_LOG" | head -3)"
fi

if grep -q -- ' inspect /dst' "$DOCKER_LOG"; then
  pass "reset inspects BEFORE destroying — that pass is also the fetch"
else
  fail "reset inspects before destroying
$(grep '^run ' "$DOCKER_LOG" | head -3)"
fi

# The fake reports PRIMARY|main, so "main" is the name the summary showed and
# therefore the name reset must be handed. A reset that re-derived its own
# target could differ from what the user approved.
if grep -qE -- " reset /dst main [0-9]+:[0-9]+" "$DOCKER_LOG"; then
  pass "the primary branch from the inspection is the one reset is given"
else
  fail "the primary branch from the inspection is the one reset is given
$(grep '^run ' "$DOCKER_LOG" | head -3)"
fi

# ── 8c. the summary names the branches, and marks the ones carrying work ──────
#
# Printed on BOTH paths, not only before the prompt: the hermetic tier has no
# tty and can never reach the prompt, so a summary printed only there would be
# unassertable — and under --yes the user would get no record of what went.
if grep -q 'DELETE feat/unpushed — 3 commit(s) not on any remote' "$OUT"; then
  pass "the summary names a branch that will be deleted, with its unpushed count"
else
  fail "the summary names a branch that will be deleted, with its unpushed count
$(cat "$OUT")"
fi
if grep -q 'DELETE fix/pushed — pushed' "$OUT"; then
  pass "… and distinguishes one that is fully pushed"
else
  fail "… and distinguishes one that is fully pushed
$(cat "$OUT")"
fi
if grep -q "switches to 'main'" "$OUT"; then
  pass "… and says which branch the checkout will end up on"
else
  fail "… and says which branch the checkout will end up on
$(cat "$OUT")"
fi
if grep -q 'carry commits that are on no remote' "$OUT"; then
  pass "unpushed work raises an explicit warning above the confirmation"
else
  fail "unpushed work raises an explicit warning above the confirmation
$(cat "$OUT")"
fi
# The primary branch itself must never be in the deletion list.
if ! grep -q 'DELETE main' "$OUT"; then
  pass "the primary branch is never listed for deletion"
else
  fail "the primary branch is never listed for deletion
$(cat "$OUT")"
fi

# ── 8d. the helper's records are rendered as prose, not leaked ────────────────
#
# The helper speaks records so that tests can read them; a person should not
# have to. Unrendered they arrive as `DELETED|throwaway` / `AT|3500160`, which
# reads like debug output leaking through — observed on a real macOS run.
setup_world
run_repo reset docs --yes
if grep -q '^  removed branch feat/unpushed$' "$OUT" && grep -q '^  removed branch fix/pushed$' "$OUT"; then
  pass "each deleted branch is named in prose"
else
  fail "each deleted branch is named in prose
$(cat "$OUT")"
fi
if grep -q '^  now on main at abc1234$' "$OUT"; then
  pass "the final state is one readable line"
else
  fail "the final state is one readable line
$(cat "$OUT")"
fi
if ! grep -qE '^(DELETED|ON|AT|DELETED-COUNT)\|' "$OUT"; then
  pass "no raw record reaches the terminal"
else
  fail "no raw record reaches the terminal
$(grep -E '^[A-Z-]+\|' "$OUT")"
fi
# A record repo.sh does not recognise must still be shown. Dropping the unknown
# ones would be the tidier-looking loop and the one that hides a future helper's
# output entirely.
if grep -q 'SOMETHING-NEW|from a future helper' "$OUT"; then
  pass "an unrecognised record is passed through verbatim, not swallowed"
else
  fail "an unrecognised record is passed through verbatim, not swallowed
$(cat "$OUT")"
fi
# Trouble goes to stderr, where it is not lost in a successful run's output.
if grep -q 'kept branch stubborn' "$ERR" && grep -q 'chown failed' "$ERR"; then
  pass "a branch that could not be deleted, and a failed chown, go to stderr"
else
  fail "a branch that could not be deleted, and a failed chown, go to stderr
$(cat "$ERR")"
fi

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

# ═════════════════════════════════════════════════════════════════════════════
# SLICE 3 — `add`, `sync`, `reindex`. Nothing here deletes, but the seeding
# helpers mount HOST paths and the host's PRIVATE KEYS into a container, and the
# mount MODE is the only thing standing between "read the source" and "write to
# it". That is argv, and argv is what this file already records.
# ═════════════════════════════════════════════════════════════════════════════

# The `docker run` argv, one invocation per line, for grepping mount flags.
runs() { sed -n 's/^run //p' "$DOCKER_LOG"; }
# `runs | grep -q …` is a producer piped into grep -q, which under `pipefail`
# can report the opposite of what it observed (backlog F34, enforced over every
# tracked script by tests/test-grep-q-pipelines.sh). A herestring has no pipe.
run_has() { grep -q -- "$1" <<< "$(runs)"; }

# ── 18. Seeding from a host path mounts the SOURCE READ-ONLY ─────────────────
# `-v <real>:/src:ro`. Drop the `:ro` and the seed helper — running as root —
# can write back into the developer's working tree through the bind. Nothing
# in the container ever needs to.
#
# REPO_BACKEND=volume is required, not incidental: on Linux `auto` resolves a
# path source to the `bind` backend, which seeds nothing and would make every
# assertion here vacuous.
setup_world
mkdir -p "$TMP/newsrc"
REPO_BACKEND=volume run_repo add fresh "$TMP/newsrc"
check "add <path> exits 0" "0" "$RC"
if run_has "-v $(cd "$TMP/newsrc" && pwd -P):/src:ro"; then
  pass "add: the host source is mounted READ-ONLY into the seed helper"
else
  fail "add: the host source is NOT mounted read-only — the seed helper runs as root and could write back into the developer's tree: $(runs | head -1)"
fi
if run_has "-v ai-containers-repo-fresh:/dst"; then
  pass "  … and the destination volume is mounted writable at /dst"
else
  fail "  … and the destination volume is mounted writable at /dst: $(runs | head -1)"
fi

# ── 19. Seeding from a git URL mounts the HOST'S PRIVATE KEYS read-only ──────
# `-v $HOME/.ssh:/root/.ssh-host:ro`. This is the developer's actual SSH
# identity. The helper copies it to a writable location inside the container on
# purpose (accept-new has to record); the HOST side must never be writable.
setup_world
run_repo add gitrepo 'git@example.com:acme/thing.git'
check "add <git-url> exits 0" "0" "$RC"
if run_has "-v $HOME/.ssh:/root/.ssh-host:ro"; then
  pass "add: the host ~/.ssh is mounted READ-ONLY into the clone helper"
else
  fail "add: the host ~/.ssh is NOT mounted read-only — the clone helper runs as root over the developer's private keys: $(runs | head -1)"
fi

# ── 20. The chown honours SANDBOX_UID/SANDBOX_GID ────────────────────────────
# repo.sh hardcoded `id -u`/`id -g` once, which broke the documented override
# and left seeded volumes owned by the wrong UID — the agent then hit permission
# errors inside the container with nothing here to say why.
setup_world
mkdir -p "$TMP/newsrc"
REPO_BACKEND=volume SANDBOX_UID=4242 SANDBOX_GID=4343 run_repo add fresh "$TMP/newsrc"
if run_has '4242:4343'; then
  pass "add: the seeded volume is chowned to SANDBOX_UID:SANDBOX_GID, not to id -u"
else
  fail "add: the chown ignored SANDBOX_UID/SANDBOX_GID — seeded volumes end up owned by the wrong UID: $(runs | head -1)"
fi

# ── 21. add refuses everything it cannot safely do ───────────────────────────
setup_world
run_repo add docs "$TMP/newsrc"
[[ "$RC" -ne 0 ]] && pass "add refuses a name that is already registered (rc=$RC)"                  || fail "add re-registered an existing repo (rc=$RC)"
grep -q 'already registered' "$ERR"   && pass "  … pointing at sync and rm instead"   || fail "  … pointing at sync and rm instead (got: $(tr '\n' ' ' < "$ERR"))"

setup_world
: > "$VOLS/ai-containers-repo-stray"
REPO_BACKEND=volume run_repo add stray "$TMP/newsrc"
[[ "$RC" -ne 0 ]] && pass "add refuses when a STRAY volume exists but nothing is registered (rc=$RC)"                  || fail "add seeded over a stray volume (rc=$RC)"
grep -q 'Remove the stray volume first' "$ERR"   && pass "  … naming the volume and how to remove it"   || fail "  … naming the volume and how to remove it (got: $(tr '\n' ' ' < "$ERR"))"
[[ -f "$VOLS/ai-containers-repo-stray" ]]   && pass "  … and leaving that volume alone"   || fail "  … and leaving that volume alone — add DELETED a volume it refused to use"

setup_world
run_repo add '../../etc' "$TMP/newsrc"
[[ "$RC" -ne 0 ]] && pass "add refuses an invalid repo name (rc=$RC)"                  || fail "add accepted '../../etc' (rc=$RC)"
check "  … before issuing a single docker command" "" "$(cat "$DOCKER_LOG")"

setup_world
REPO_BACKEND=volume run_repo add fresh "$TMP/no-such-directory"
[[ "$RC" -ne 0 ]] && pass "add refuses a path source that does not exist (rc=$RC)"                  || fail "add accepted a non-existent path source (rc=$RC)"
check "  … before issuing a single docker command" "" "$(cat "$DOCKER_LOG")"

setup_world; run_repo add onlyname
[[ "$RC" -ne 0 ]] && pass "add with no source is a usage error (rc=$RC)"                  || fail "add with no source was accepted (rc=$RC)"

# ── 22. sync mounts the source read-only too, and skips what it must ─────────
setup_world
run_repo sync docs
check "sync <git repo> exits 0" "0" "$RC"
if run_has "-v $HOME/.ssh:/root/.ssh-host:ro"; then
  pass "sync: the host ~/.ssh is mounted READ-ONLY into the pull helper"
else
  fail "sync: the host ~/.ssh is NOT mounted read-only: $(runs | head -1)"
fi
check "  … and no volume is removed by a sync" "" "$(removed)"

setup_world
run_repo sync localsrc
check "sync on a bind-backend repo exits 0" "0" "$RC"
check "  … issuing no docker command at all" "" "$(cat "$DOCKER_LOG")"
grep -q 'nothing to sync' "$OUT"   && pass "  … and saying the source is live"   || fail "  … and saying the source is live (got: $(tr '\n' ' ' < "$OUT"))"

setup_world
run_repo sync --all
check "sync --all exits 0" "0" "$RC"
check "  … and removes nothing" "" "$(removed)"
for r in docs docs-archive cluster; do
  grep -q "OK: $r synced" "$OUT"     && pass "  … having synced $r"     || fail "  … having synced $r (got: $(tr '\n' ' ' < "$OUT"))"
done

# ── 23. reindex is additive: it never removes a registry entry ───────────────
# Its whole contract is "recover a lost registry from volume labels". A reindex
# that dropped the bind entry would silently unregister a repo that has no
# volume to be rediscovered from — unrecoverable, and invisible until the next
# launch failed.
setup_world
for v in docs docs-archive cluster; do
  printf 'ai-containers.repo=%s\nai-containers.type=git\nai-containers.source=git@x:%s.git\n' "$v" "$v"     > "$VOLS/ai-containers-repo-$v.labels"
done
run_repo reindex
check "reindex exits 0" "0" "$RC"
check "  … removing nothing" "" "$(removed)"
check "  … and the bind-backend entry, which has no volume, survives" "1"   "$(grep -c '^localsrc|' "$HOME/.ai-containers/repos.conf")"
check "  … while every volume-backed repo is still registered" "3"   "$(grep -cE '^(docs|docs-archive|cluster)\|' "$HOME/.ai-containers/repos.conf")"

# ── 24. list refuses what it cannot understand ───────────────────────────────
# Not a destructive path, and included anyway: the measurement below found that
# `exit 1` -> `exit 0` SURVIVED on both of these lines, so `repo.sh list
# --nonsense` printed an error and reported success, and any script checking its
# status was told the listing was fine. The same refusal is asserted for `gc`
# and `reset` above; `list` was simply missed.
setup_world
run_repo list --nonsense
[[ "$RC" -ne 0 ]] && pass "list rejects an unknown flag (rc=$RC)" \
                 || fail "list accepted an unknown flag and reported success (rc=$RC)"
grep -q 'unknown flag' "$ERR" \
  && pass "  … naming it" \
  || fail "  … naming it (got: $(tr '\n' ' ' < "$ERR"))"
setup_world
run_repo list stray-argument
[[ "$RC" -ne 0 ]] && pass "list rejects an unexpected positional argument (rc=$RC)" \
                 || fail "list accepted a stray argument and reported success (rc=$RC)"
grep -q 'unexpected argument' "$ERR" \
  && pass "  … naming it" \
  || fail "  … naming it (got: $(tr '\n' ' ' < "$ERR"))"
# The control: the two flags it DOES take must still work, or the case above
# would pass on a `list` that refused everything.
setup_world; run_repo list
check "control: bare list exits 0" "0" "$RC"
setup_world; run_repo list --copies
check "control: list --copies exits 0" "0" "$RC"

# ═════════════════════════════════════════════════════════════════════════════
# SLICE 4 — THE SUMMARY SOMEBODY READS BEFORE TYPING `yes`.
# ═════════════════════════════════════════════════════════════════════════════
#
# Measured 2026-08-21: after slices 1-3 asserted every DECISION these
# subcommands make, 129 of 249 mutants still survived, and they cluster here —
# in what the user is TOLD, not in what is done. That summary is not cosmetic.
# It is the entire basis on which a person consents to deleting a volume, and
# every mutant of it survived: flip the `has_base` test and `rm` offers to
# remove a volume that is not there while staying silent about the one that is;
# flip the working-copies test and it deletes copies holding uncommitted work
# WITHOUT LISTING THEM.
#
# All of this is asserted on the REFUSAL path — no `--yes` — because cmd_rm and
# cmd_gc print the summary BEFORE they ask. Nothing is deleted by any case here,
# which is also why they can assert the dangerous shapes at all.
#
# WHAT CANNOT BE ASSERTED HERE, stated rather than quietly skipped: the
# confirmation itself (`[[ -t 0 ]]` and `[[ "$reply" == "yes" ]]`). Every case in
# this file drives the non-interactive path; `read -r -p` needs a tty and
# nothing hermetic has one. Those mutants stay alive and the ledger will keep
# owing them.

# ── 25. rm names the base volume it is about to destroy ──────────────────────
setup_world
run_repo rm docs
grep -q -- '- base volume:    ai-containers-repo-docs' "$OUT" \
  && pass "rm's summary names the base volume by its real name" \
  || fail "rm's summary names the base volume by its real name (got: $(tr '\n' '|' < "$OUT"))"
grep -q 'no volume — bind-mount backend' "$OUT" \
  && fail "rm's summary claimed there is no volume while one exists — the has_base test is inverted" \
  || pass "  … and does not also claim there is no volume"

# ── 26. …and says so plainly when there ISN'T one ────────────────────────────
# A bind-backend repo has no volume to remove; saying "base volume: <name>" for
# one would offer to destroy something that does not exist while leaving the
# reader to assume the host source is at risk. The message says the opposite,
# in as many words.
setup_world
run_repo rm localsrc
grep -q 'no volume — bind-mount backend; host source is left untouched' "$OUT" \
  && pass "rm's summary says when there is NO volume, and that the host source is safe" \
  || fail "rm's summary says when there is NO volume (got: $(tr '\n' '|' < "$OUT"))"
grep -q -- '- base volume:' "$OUT" \
  && fail "  … rather than naming a base volume that does not exist" \
  || pass "  … rather than naming a base volume that does not exist"

# ── 27. THE ONE THAT MATTERS: working copies are LISTED before they are lost ─
# These are the volumes that may hold uncommitted work. Deleting them is the
# most destructive thing this script does, and the list is the only warning.
setup_world
run_repo rm docs
grep -q 'working copies (may contain UNCOMMITTED changes)' "$OUT" \
  && pass "rm warns that the working copies may hold UNCOMMITTED changes" \
  || fail "rm warns that the working copies may hold UNCOMMITTED changes (got: $(tr '\n' '|' < "$OUT"))"
for wc in projA projB; do
  grep -q "ai-containers-repo-docs--wc-$wc" "$OUT" \
    && pass "  … and names $wc, which is about to be destroyed" \
    || fail "  … and names $wc, which is about to be destroyed (got: $(tr '\n' '|' < "$OUT"))"
done
grep -q 'docs-archive--wc-' "$OUT" \
  && fail "  … while not listing another repo's copy, which it is not going to touch" \
  || pass "  … while not listing another repo's copy, which it is not going to touch"

# ── 28. …and stays silent about working copies when there are none ───────────
# The control for case 27: a summary that always printed the block would pass
# every assertion above while telling the reader nothing.
setup_world
rm -f "$VOLS"/ai-containers-repo-docs--wc-*
run_repo rm docs
grep -q 'working copies' "$OUT" \
  && fail "rm listed a working-copies section when the repo has none" \
  || pass "rm says nothing about working copies when there are none"
grep -q -- '- base volume:    ai-containers-repo-docs' "$OUT" \
  && pass "  … while still naming the base volume it will remove" \
  || fail "  … while still naming the base volume it will remove"

# ── 29. rm names the registry file it is going to edit ───────────────────────
setup_world
run_repo rm docs
grep -q "registry entry in $HOME/.ai-containers/repos.conf" "$OUT" \
  && pass "rm's summary names the registry file it will edit" \
  || fail "rm's summary names the registry file it will edit (got: $(tr '\n' '|' < "$OUT"))"

# ── 30. gc's table says which repo each copy belongs to, and where it came from
# A working-copy volume name is `<base>--wc-<tag>`; the REPO and LAUNCH DIR
# columns come from its labels, and they are how a reader decides whether the
# copy in front of them is the one holding their work.
setup_world
run_repo gc
grep -qE 'ai-containers-repo-docs--wc-projA +docs +/tmp/docs--wc-projA' "$OUT" \
  && pass "gc's table shows each copy's repo and launch dir, from its labels" \
  || fail "gc's table shows each copy's repo and launch dir (got: $(tr '\n' '|' < "$OUT"))"

# ── 31. …and admits when it does not know ────────────────────────────────────
# An unlabelled volume is exactly the one a reader most needs flagged: it cannot
# be attributed to a repo or a directory. Printing an empty column would read as
# "no launch dir"; `?` and `(unlabeled)` read as "unknown", which is the truth.
setup_world
rm -f "$VOLS"/ai-containers-repo-docs--wc-projA.labels
run_repo gc
grep -qE 'ai-containers-repo-docs--wc-projA +\? +\(unlabeled\)' "$OUT" \
  && pass "gc marks an unlabelled copy '?' and '(unlabeled)' rather than blank" \
  || fail "gc marks an unlabelled copy '?' and '(unlabeled)' (got: $(tr '\n' '|' < "$OUT"))"

# ── 32. gc's count matches the number it is actually about to remove ─────────
setup_world
run_repo gc
grep -q 'About to remove 3 working-copy volume(s). These may hold UNCOMMITTED work.' "$OUT" \
  && pass "gc's count matches the copies it listed (3)" \
  || fail "gc's count matches the copies it listed (got: $(grep -o 'About to remove [0-9]* working-copy' "$OUT"))"
setup_world
printf 'ai-containers-repo-docs--wc-projA\n' > "$INUSE"
run_repo gc --unused
grep -q 'About to remove 2 working-copy volume(s)' "$OUT" \
  && pass "  … and drops to 2 when --unused spares the one in use" \
  || fail "  … and drops to 2 when --unused spares the one in use (got: $(grep -o 'About to remove [0-9]* working-copy' "$OUT"))"

# ── the PRE-CONSENT SUMMARY: what the user is told before typing yes ──────────
# targets.conf names this as the next slice, from its own measurement: cmd_rm
# and cmd_gc still carry mutation survivors DESPITE the destructive slices,
# "because those assertions check what was REMOVED, not what was PRINTED before
# the removal".
#
# For a destructive command the summary IS the consent. A user types `yes` to
# the list they were shown, not to the argv repo.sh later hands docker, and the
# two are only the same thing while something checks. Under-report and they
# consent to less than happens; over-report and they refuse a safe operation.
# Every assertion below is on the OUTPUT, and the last of them is the one that
# ties output to action.
setup_world
run_repo rm docs --yes
check "rm of a registered repo succeeds" "0" "$RC"
grep -q 'About to remove repo "docs"' "$OUT" \
  && pass "the summary names the repo being removed" \
  || fail "the summary names the repo being removed (got: $(tr '\n' ' ' < "$OUT"))"
grep -q -- '- base volume: *ai-containers-repo-docs$' "$OUT" \
  && pass "the summary names the base volume it will destroy" \
  || fail "the summary names the base volume it will destroy (got: $(tr '\n' ' ' < "$OUT"))"
# BOTH copies, not "some". A summary listing one of two is the under-report that
# makes consent mean the wrong thing, and it is invisible to any assertion that
# only checks a copy was mentioned.
for wc in ai-containers-repo-docs--wc-projA ai-containers-repo-docs--wc-projB; do
  grep -q "^ *$wc\$" "$OUT" \
    && pass "the summary lists working copy ${wc##*--wc-}" \
    || fail "the summary lists working copy ${wc##*--wc-} (got: $(tr '\n' ' ' < "$OUT"))"
done
grep -q 'UNCOMMITTED' "$OUT" \
  && pass "the summary warns that working copies may hold uncommitted work" \
  || fail "the summary warns that working copies may hold uncommitted work"
# The bystander whose name PREFIXES the subject's. Over-reporting is the other
# half of a wrong summary: a user shown docs-archive would refuse a safe removal.
grep -q 'docs-archive' "$OUT" \
  && fail "the summary must not name the bystander docs-archive (got: $(tr '\n' ' ' < "$OUT"))" \
  || pass "the summary names no repo other than the one being removed"

# THE ONE THAT TIES THEM TOGETHER. Every volume named in the summary, compared
# against every volume repo.sh actually asked docker to destroy. Equality is the
# property that makes the summary consent rather than decoration; either
# direction failing is a different, and equally real, defect.
summary_vols() {
  { sed -n 's/^ *- base volume: *//p' "$OUT"
    sed -n 's/^ *\(ai-containers-repo-[^ ]*\)$/\1/p' "$OUT"
  } | sort -u | tr '\n' '|'
}
check "the volumes named in the summary are EXACTLY those removed" "$(summary_vols)" "$(removed)"

# A bind-backend repo destroys no volume, and the summary has to say so — the
# host source is the user's own directory and "removing the repo" must not read
# as removing it.
setup_world
run_repo rm localsrc --yes
check "rm of a bind-backend repo succeeds" "0" "$RC"
grep -q 'host source is left untouched' "$OUT" \
  && pass "the summary states the host source survives a bind-backend removal" \
  || fail "the summary states the host source survives (got: $(tr '\n' ' ' < "$OUT"))"
# NOT "nothing was removed": cmd_rm issues `docker volume rm "$vol" || true`
# unconditionally, which for a bind-backend repo asks docker to remove a volume
# that does not exist. That is deliberate defensive cleanup — a repo re-registered
# from volume to bind would otherwise strand its old volume — and asserting
# "nothing" would pin a bug rather than the behaviour. What must hold is that
# nothing belonging to ANOTHER repo is touched.
check "removing a bind-backend repo touches no other repo's volume" "ai-containers-repo-localsrc|" "$(removed)"
check "the host source directory still exists afterwards" "uncommitted work" "$(cat "$TMP/hostsrc/DIRTY" 2>/dev/null)"

# gc's summary is a COUNT, which is the same promise in a shorter form: the
# number the user consents to must be the number that goes.
setup_world
printf '%s\n' ai-containers-repo-docs--wc-projB > "$INUSE"
run_repo gc --unused --yes
check "gc --unused succeeds" "0" "$RC"
gc_claimed="$(sed -n 's/^About to remove \([0-9]*\) working-copy volume(s).*/\1/p' "$OUT" | head -1)"
gc_actual="$(sed -n 's/^volume rm //p' "$DOCKER_LOG" | tr ' ' '\n' | grep -c '^ai-containers-repo-')"
check "the count gc asks consent for is the count it removes" "$gc_claimed" "$gc_actual"
# `[in use — kept]` is printed only under --unused; without it gc removes in-use
# copies by design, which is why this arm passes the flag.
grep -q 'in use — kept' "$OUT" \
  && pass "gc --unused marks an in-use copy as kept" \
  || fail "gc --unused marks an in-use copy as kept (got: $(tr '\n' ' ' < "$OUT"))"
# And keeping it must mean not destroying it — the listing and the action again.
if grep -q 'volume rm.*docs--wc-projB' "$DOCKER_LOG"; then
  fail "gc --unused removed the copy it reported as kept"
else
  pass "the copy gc reported as kept is not among those removed"
fi

# ── ERROR PATHS MUST EXIT NON-ZERO ────────────────────────────────────────────
# Measured 2026-08-30: of repo.sh's 123 surviving mutants, 27 are `return-flip`
# and the sampled ones are all the same shape — `exit 1` turned into `exit 0` on
# an argument-validation path, so repo.sh PRINTS "ERROR: unknown flag" and then
# reports success. Nothing asserted the status of those paths, only the message.
#
# That is not cosmetic: a wrapper, a Makefile or a CI step reads $?, not stderr.
# `repo.sh sync a b || echo failed` stays silent while nothing was synced.
#
# This slice exists because the slice targets.conf PRESCRIBED did not work. Its
# survivor census was by FUNCTION ("cmd_list 15 · list_copies 8 …") and read as
# "assert what is PRINTED" — but the census by OPERATOR is 54 cond-negate, 35
# logic-flip, 27 return-flip, 7 cmp-flip and ZERO that damage a printf's text,
# because the generator has no value-damage operator (hole #4 of the historical
# scorecard). Asserting the text could not kill them. Asserting the STATUS can.
# Every entry below reaches a DISTINCT `exit 1` in repo.sh; the line number is
# named so a future edit can tell whether a path lost its coverage or merely
# moved. `run_repo` redirects stdin from /dev/null, so the three consent paths
# take the non-interactive refusal branch rather than blocking on a prompt.
bad_invocations=(
  "nosuchcmd"                 # :847  dispatch — unknown subcommand
  "add"                       # :258  add — no arguments
  "add onlyname"              # :258  add — missing <source>
  "add ../../etc /tmp"        # :259  add — validate_repo_name
  "add docs /tmp"             # :265  add — name already registered
  "add fresh /no/such/path"   # :275  add — source path does not exist
  "sync"                      # :361  sync — no arguments
  "sync --nope"               # :351  sync — unknown flag
  "sync a b"                  # :352  sync — two names
  "sync docs --all"           # :358  sync — <name> and --all together
  "sync ../../etc"            # :373  sync — validate_repo_name
  "sync nosuchrepo"           # :376  sync — name is not registered
  "list --nope"               # :416  list — unknown flag
  "list extra"                # :417  list — unexpected argument
  "rm"                        # :484  rm — no arguments
  "rm ../../etc"              # :485  rm — validate_repo_name
  "rm docs"                   # :516  rm — non-interactive without --yes
  "reset"                     # :675  reset — no arguments
  "reset --nope"              # :665  reset — unknown flag
  "reset a b"                 # :666  reset — two names
  "reset docs --all"          # :672  reset — <name> and --all together
  "reset ../../etc --yes"     # :687  reset — validate_repo_name
  "reset nosuchrepo --yes"    # :690  reset — name is not registered
  "reset docs"                # :717  reset — non-interactive without --yes
  "gc --repo"                 # :742  gc — --repo with no value
  "gc --nope"                 # :745  gc — unknown flag
  "gc extra"                  # :746  gc — unexpected argument
  "gc --repo ../../etc"       # :750  gc — validate_repo_name
  "gc"                        # :786  gc — non-interactive without --yes
)
for bad in "${bad_invocations[@]}"; do
  setup_world
  # shellcheck disable=SC2086
  run_repo $bad
  if [[ "$RC" -ne 0 ]]; then
    pass "\`repo.sh $bad\` exits non-zero"
  else
    fail "\`repo.sh $bad\` exits 0 despite failing (stderr: $(tr '\n' ' ' < "$ERR"))"
  fi
  check "  … and destroys nothing" "" "$(removed)"
done

# ── NO-OP PATHS MUST REPORT SUCCESS ──────────────────────────────────────────
# The mirror of the block above, and the other half of what `return-flip`
# damages. Measured on this host 2026-08-30, after the error-path slice: 17
# return-flip survivors remained, and NINE were "nothing to do" early returns.
# Flipping their `return 0` makes repo.sh report FAILURE for a legitimate no-op,
# and nothing asserted otherwise.
#
# This is the more dangerous direction of the two. A provisioning script running
# `./repo.sh sync --all` on a machine with no repos registered yet would abort
# the whole run — and `|| true` is exactly the workaround that gets added, which
# then hides a real sync failure later. An error path that wrongly succeeds is
# caught the first time someone looks; a no-op that wrongly fails trains people
# to suppress the status altogether.
noop_ok() {   # <label> <args…> — must exit 0 AND destroy nothing
  local label="$1"; shift
  run_repo "$@"
  if [[ "$RC" -eq 0 ]]; then
    pass "$label exits 0"
  else
    fail "$label exits $RC (stderr: $(tr '\n' ' ' < "$ERR"))"
  fi
  check "  … and destroys nothing" "" "$(removed)"
}

setup_empty_world
noop_ok '`sync --all` on a machine with no repos registered' sync --all       # :370
noop_ok '`list` with no repos and no volumes'                list             # :441
noop_ok '`reset --all --yes` with an empty registry'         reset --all --yes # :684
noop_ok '`gc --yes` with no working copies anywhere'         gc --yes         # :755
noop_ok '`list --copies` when no working copies exist'       list --copies    # :395

# victims empty for a different reason: copies EXIST, but --unused filters every
# one of them out. Distinct from :755 above, where none existed at all.
setup_world
printf '%s\n' ai-containers-repo-docs--wc-projA \
               ai-containers-repo-docs--wc-projB \
               ai-containers-repo-docs-archive--wc-projA > "$INUSE"
noop_ok '`gc --unused --yes` when every copy is in use'      gc --unused --yes # :776

# A repo the helper cannot resolve a primary branch for is LEFT UNTOUCHED, and
# that is a success: reset skips it rather than inventing the target of a
# destructive operation.
setup_world
export HELPER_NO_PRIMARY=1
run_repo reset docs --yes                                                      # :571
if [[ "$RC" -eq 0 ]]; then
  pass '`reset --yes` on a repo with no branch to reset onto exits 0'
else
  fail "\`reset --yes\` on a repo with no branch to reset onto exits $RC (stderr: $(tr '\n' ' ' < "$ERR"))"
fi
# Deliberately NOT noop_ok: this one is not a no-op. `reset` removes the repo's
# working copies BEFORE it learns the helper has no primary branch to offer, so
# `destroys nothing` is false here — measured, not assumed. The skip is about
# the base volume's checkout, not about the working copies, whose removal is
# reset's contract either way. Asserting emptiness here would have been an
# assertion about an ordering this slice has no opinion on.
grep -q 'no branch to reset onto' "$OUT" \
  && pass 'the run says WHY the repo was left untouched' \
  || fail "the run does not explain the skip (stdout: $(tr '\n' ' ' < "$OUT"))"
unset HELPER_NO_PRIMARY

# ── AND THE CONVERSE: a reset that FAILED must not report success ─────────────
# repo.sh runs under `set -euo pipefail`, so reset_one's non-zero return does
# propagate even though cmd_reset discards it — verified against the real
# script, not assumed from reading the loop. That makes :232 a live guard, and
# flipping its `return 1` would make a failed destructive operation silent.
setup_world
export HELPER_RESET_FAILS=1
run_repo reset docs --yes
if [[ "$RC" -ne 0 ]]; then
  pass "a git reset that failed inside the seed container exits non-zero"
else
  fail "a failed git reset reported success (stdout: $(tr '\n' ' ' < "$OUT"))"
fi
grep -q 'OK: reset complete' "$OUT" \
  && fail "repo.sh printed 'OK: reset complete.' after the reset had failed" \
  || pass "repo.sh does not claim the reset completed after it failed"
unset HELPER_RESET_FAILS

# ── sync_from_path: the one function nothing ever executed (backlog F1) ───────
# Measured 2026-08-29 by instrumenting every function in repo.sh and running the
# three repo test files: 21 of its 22 functions run. `sync_from_path` was the
# only one that never did, and the reason is a gap in the FIXTURES rather than
# in the tests — reaching it needs a repo that is `path`-TYPED and
# `volume`-BACKED, and every path repo in this file is bind-backed, which
# sync_one answers with "nothing to sync" before it gets there.
#
# That combination is not exotic. On Linux `auto` registers a path repo as a
# bind alias, but on macOS it cannot — bind mounts are the thing repo volumes
# exist to avoid there — so on a Mac EVERY path repo is volume-backed and every
# `repo.sh sync` of one runs this function. The single unexecuted function was
# the one an entire platform takes on its normal path.
#
# It also deletes. `rsync -a --delete /src/ /dst/` mirrors, so the guard below
# is not a nicety: with the source gone and the guard removed, the mirror runs
# from nothing and the volume's contents are what gets deleted.
setup_path_world() {
  export HOME="$TMP/home"; rm -rf "$HOME"; mkdir -p "$HOME/.ai-containers"
  rm -rf "$VOLS"; mkdir -p "$VOLS"; : > "$DOCKER_LOG"; : > "$INUSE"
  : > "$VOLS/ai-containers-repo-localvol"
  printf 'localvol|path|%s|1700000000|1700000000|volume\n' "$TMP/pathsrc" \
    > "$HOME/.ai-containers/repos.conf"
  rm -rf "$TMP/pathsrc"; mkdir -p "$TMP/pathsrc"
  printf 'real content\n' > "$TMP/pathsrc/FILE"
  # sync_from_path RESOLVES the source before mounting it, so the mount carries
  # the physical path — which is NOT $TMP/pathsrc whenever TMPDIR contains a
  # symlink. That is the ordinary case on macOS (/var → /private/var) and it is
  # what the suite's symlinked-TMPDIR arm exists to catch; asserting against the
  # unresolved value passes on an ordinary Linux host and fails on every Mac.
  #
  # p_realdir, not readlink -f: resolve_path itself uses readlink -f, and
  # canonicalising the EXPECTED value with the same primitive as the code under
  # test is `assert f(x) == f(x)`. p_realdir reaches the same physical answer
  # through `cd` + `pwd -P`, a different mechanism.
  PATHSRC_REAL="$(p_realdir "$TMP/pathsrc")"
}
# The `docker run` lines only — `volume inspect` also names the volume, and a
# grep over the whole log would pass on that instead of on the mirror.
runs() { grep '^run ' "$DOCKER_LOG"; }
# Captured FIRST, then matched from a here-string. `runs | grep -q …` would be a
# producer piped into `grep -q` under pipefail — the shape
# tests/test-grep-q-pipelines.sh forbids, because grep exits on its first match,
# the producer dies 141 on the broken pipe, and pipefail promotes that over
# grep's success. A regression guard written that way reports "no defect" at
# exactly the moment the defect returns.
has_run() { local out; out="$(runs)"; grep -q -- "$1" <<<"$out"; }

# 1. The happy path reaches the mirror at all, and mounts BOTH ends of it.
setup_path_world
run_repo sync localvol
check "a path-typed, volume-backed repo syncs successfully" "0" "$RC"
if has_run "-v $PATHSRC_REAL:/src:ro"; then
  pass "the mirror mounts the host source at /src, READ-ONLY"
else
  fail "the mirror mounts the host source at /src read-only — got: $(runs | head -1)"
fi
if has_run "-v ai-containers-repo-localvol:/dst"; then
  pass "the mirror mounts the repo's own volume at /dst"
else
  fail "the mirror mounts the repo's own volume at /dst — got: $(runs | head -1)"
fi
# `:ro` is the whole reason a sync cannot damage the developer's checkout. As a
# separate assertion from the mount above, because a mount without it would
# still satisfy that one.
if has_run ":/src:ro"; then
  pass "the source mount carries :ro, so a sync can never write to the host tree"
else
  fail "the source mount carries :ro — got: $(runs | head -1)"
fi
check "the host source file is untouched by a sync" "real content" "$(cat "$TMP/pathsrc/FILE" 2>/dev/null)"

# 2. THE GUARD. Source gone → refuse, and above all run NOTHING: the mirror
#    deletes, so mirroring from a vanished source is how a volume gets emptied
#    by the command meant to update it.
setup_path_world
rm -rf "$TMP/pathsrc"
run_repo sync localvol
check "a sync whose source path has vanished fails" "1" "$RC"
if grep -q 'source path no longer exists' "$ERR"; then
  pass "… and says which path, on stderr"
else
  fail "… and says which path, on stderr — got: $(cat "$ERR")"
fi
if has_run ":/dst"; then
  fail "a vanished source must start NO mirror — one ran: $(runs | head -1)"
else
  pass "a vanished source starts no mirror at all, so the volume cannot be emptied"
fi

# 3. `reset` of a path repo routes through the same function (repo.sh:562), and
#    that arm has never run either. Same guard, same consequence.
setup_path_world
run_repo reset localvol --yes
check "resetting a path-typed repo succeeds" "0" "$RC"
if has_run "-v ai-containers-repo-localvol:/dst"; then
  pass "reset re-mirrors the path repo into its volume"
else
  fail "reset re-mirrors the path repo into its volume — got: $(runs | tr '\n' ';')"
fi

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
