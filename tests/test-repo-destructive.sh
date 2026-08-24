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
      printf 'PRIMARY|main\n'
      printf 'BRANCH|main|0|current\n'
      printf 'BRANCH|feat/unpushed|3|\n'
      printf 'BRANCH|fix/pushed|0|\n'
      exit 0 ;;
    *" reset /dst"*)
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
