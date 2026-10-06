#!/usr/bin/env bash
# Integration test for project-init.sh's generated runme.sh launcher.
# Drives project-init non-interactively (scripted stdin) inside an isolated copy
# of the repo so its projects.conf/shared-file writes never touch the real tree,
# then asserts the generated launcher carries the guarded GITHUB_TOKEN block.
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT

# Isolated script_dir: a copy of the repo so projects.conf and shared-file copies
# land in TMP, not the working tree. Exclude heavy/irrelevant dirs.
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' "$REPO_DIR/"/ "$SCRIPTS/"

# Isolated HOME so group-init prompts fire deterministically (no ~/.ai-containers).
export HOME="$TMP/home"; mkdir -p "$HOME"

# Target project (a git repo, as real projects are).
PROJ="$TMP/proj/myproj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q

# Scripted answers, in prompt order:
#   path, name(def), image(def), cpus(def), memory(def), reservation(def),
#   memory+swap(def), group(def "default"), group-init menu(1 → from:host),
#   extra-mounts(empty). Launcher doesn't exist yet, so no overwrite prompt.
printf '%s\n\n\n\n\n\n\n\n\n\n' "$PROJ" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1

LAUNCHER="$PROJ/.ai-containers/runme.sh"
if [[ -f "$LAUNCHER" ]]; then
  pass "launcher generated"
else
  fail "launcher generated (missing $LAUNCHER)"; echo "$fails FAILED"; exit 1
fi

grep -q 'command -v gh' "$LAUNCHER"                    && pass "gh guard present"        || fail "gh guard present"
grep -q ': "${GITHUB_TOKEN:=$(gh auth token' "$LAUNCHER" && pass "non-clobbering assign" || fail "non-clobbering assign"
grep -q 'export GITHUB_TOKEN' "$LAUNCHER"              && pass "token exported"          || fail "token exported"

# The token block must come BEFORE ./build.sh (else the build can't see it).
tok_line="$(grep -n 'export GITHUB_TOKEN' "$LAUNCHER" | head -1 | cut -d: -f1)"
build_line="$(grep -n '^\./build\.sh' "$LAUNCHER" | head -1 | cut -d: -f1)"
if [[ -n "$tok_line" && -n "$build_line" && "$tok_line" -lt "$build_line" ]]; then
  pass "token block precedes ./build.sh"
else
  fail "token block precedes ./build.sh (tok=$tok_line build=$build_line)"
fi

# The generated launcher must be valid bash.
bash -n "$LAUNCHER" && pass "launcher parses" || fail "launcher parses"

# ── §3: launcher config lives in sandbox.env / sandbox.local.env; runme.sh is thin ──
SBENV="$PROJ/.ai-containers/sandbox.env"
grep -q '^IMAGE_NAME='          "$SBENV" && pass "sandbox.env has IMAGE_NAME"      || fail "sandbox.env has IMAGE_NAME"
grep -q '^SANDBOX_MODE=open'    "$SBENV" && pass "sandbox.env has SANDBOX_MODE"    || fail "sandbox.env has SANDBOX_MODE"
grep -q '^SANDBOX_WORKDIR=\.\.' "$SBENV" && pass "sandbox.env has SANDBOX_WORKDIR" || fail "sandbox.env has SANDBOX_WORKDIR"
grep -q '^CONTAINER_CPUS='      "$SBENV" && pass "sandbox.env has CONTAINER_CPUS"  || fail "sandbox.env has CONTAINER_CPUS"
! grep -qE '^export (IMAGE_NAME|CONTAINER_)' "$LAUNCHER" && pass "runme.sh is thin (no baked config exports)" || fail "runme.sh is thin (no baked config exports)"
# The launcher FORWARDS its arguments now, so `./runme.sh --version` and
# `./runme.sh restricted @app` both reach sandbox.sh. A bare `./sandbox.sh`
# would swallow them silently, which is what this pinned the absence of before
# there was anything to forward.
grep -qxF './sandbox.sh "$@"' "$LAUNCHER" && pass "runme.sh forwards its arguments to ./sandbox.sh" || fail "runme.sh forwards its arguments to ./sandbox.sh"
grep -qE '^\s*-V\|--version\|version\)' "$LAUNCHER" && pass "runme.sh answers --version without building" || fail "runme.sh answers --version without building"
grep -qxF 'sandbox.local.env' "$PROJ/.ai-containers/.gitignore" && pass "sandbox.local.env is gitignored" || fail "sandbox.local.env is gitignored"
# PROJ is a NEW group (isolated HOME) → group_init=from:host, host-referential, so it lands
# in sandbox.local.env (not the portable file) even without EXTRA_MOUNTS.
SBLOCAL1="$PROJ/.ai-containers/sandbox.local.env"
{ [[ -f "$SBLOCAL1" ]] && grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL1"; } && pass "GROUP_INIT → sandbox.local.env (new group)" || fail "GROUP_INIT → sandbox.local.env (new group)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBENV" && pass "GROUP_INIT not in portable sandbox.env" || fail "GROUP_INIT not in portable sandbox.env"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL1" && pass "no EXTRA_MOUNTS in local without mounts" || fail "no EXTRA_MOUNTS in local without mounts"

# A second project WITH an extra-mount answer → EXTRA_MOUNTS in sandbox.local.env only.
PROJ2="$TMP/proj/withmounts"; mkdir -p "$PROJ2"; git -C "$PROJ2" init -q
printf '%s\n\n\n\n\n\n\n\n\n%s\n' "$PROJ2" "$TMP" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL="$PROJ2/.ai-containers/sandbox.local.env"
{ [[ -f "$SBLOCAL" ]] && grep -q '^EXTRA_MOUNTS=' "$SBLOCAL"; } && pass "extra mounts → sandbox.local.env" || fail "extra mounts → sandbox.local.env"
! grep -q 'EXTRA_MOUNTS' "$PROJ2/.ai-containers/runme.sh"      && pass "EXTRA_MOUNTS not baked into runme.sh"     || fail "EXTRA_MOUNTS not baked into runme.sh"
! grep -q '^EXTRA_MOUNTS=' "$PROJ2/.ai-containers/sandbox.env" && pass "EXTRA_MOUNTS not in portable sandbox.env" || fail "EXTRA_MOUNTS not in portable sandbox.env"

# A third project reusing the already-bootstrapped "default" group, with no extra
# mounts either → group_init AND extra_mounts are both empty. sandbox.local.env must
# still be written (previously it was skipped entirely in this case), and its header
# must document the SANDBOX_MODE override as a commented example.
mkdir -p "$HOME/.ai-containers/default"  # Simulate group being bootstrapped by PROJ
PROJ3="$TMP/proj/plain"; mkdir -p "$PROJ3"; git -C "$PROJ3" init -q
printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL3="$PROJ3/.ai-containers/sandbox.local.env"
[[ -f "$SBLOCAL3" ]] && pass "sandbox.local.env always written (no mounts, no group-init)" || fail "sandbox.local.env always written (no mounts, no group-init)"
grep -q '^#SANDBOX_MODE=open' "$SBLOCAL3" && pass "sandbox.local.env documents SANDBOX_MODE example" || fail "sandbox.local.env documents SANDBOX_MODE example"
grep -q 'restricted  firewall enabled' "$SBLOCAL3" && pass "sandbox.local.env documents restricted mode" || fail "sandbox.local.env documents restricted mode"
! grep -q '^SANDBOX_MODE=' "$SBLOCAL3" && pass "SANDBOX_MODE stays commented (no live duplicate)" || fail "SANDBOX_MODE stays commented (no live duplicate)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL3" && pass "no stray GROUP_INIT when not answered" || fail "no stray GROUP_INIT when not answered"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL3" && pass "no stray EXTRA_MOUNTS when not answered" || fail "no stray EXTRA_MOUNTS when not answered"

# Regression test (final-review finding): re-running project-init.sh on an existing
# project must back up rather than silently destroy hand-edited sandbox.local.env
# content — nothing in it (REPOS, SANDBOX_WORKDIR, SANDBOX_MODE, ...) is ever re-prompted.
printf 'REPOS="handedited:ro"\n' >> "$SBLOCAL3"
printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
BACKUP3="$PROJ3/.ai-containers/sandbox.local.env.pre-init"
[[ -f "$BACKUP3" ]] && pass "sandbox.local.env backed up before re-init overwrite" || fail "sandbox.local.env backed up before re-init overwrite"
grep -q '^REPOS="handedited:ro"' "$BACKUP3" && pass "backup preserves hand-edited content" || fail "backup preserves hand-edited content"
! grep -q '^REPOS="handedited:ro"' "$SBLOCAL3" && pass "fresh sandbox.local.env does not carry stale hand-edit forward" || fail "fresh sandbox.local.env does not carry stale hand-edit forward"
# Assert the EFFECT (git actually ignores the file), not the literal pattern
# string. The pattern is now a glob — `sandbox.local.env.pre-init*` — because
# repeated re-inits produce timestamped backups, and a `grep -qxF` for the exact
# old string failed against a strictly BROADER pattern that ignores strictly
# more. A test that breaks when the code gets more correct is testing the wrong
# thing.
(
  cd "$PROJ3" || exit 1
  : > .ai-containers/sandbox.local.env.pre-init
  : > ".ai-containers/sandbox.local.env.pre-init.20260101T000000Z"
  : > .ai-containers/runme.sh.pre-migrate
)
for f in sandbox.local.env.pre-init \
         sandbox.local.env.pre-init.20260101T000000Z \
         runme.sh.pre-migrate; do
  if (cd "$PROJ3" && git check-ignore -q ".ai-containers/$f"); then
    pass "git ignores $f"
  else
    fail "git ignores $f"
  fi
done

# ── Group picker (step 6) ─────────────────────────────────────────────────────
# The group prompt lists existing groups by number; anything else is a name, and
# a name with no directory is confirmed before it becomes a new group. Each run
# gets its own HOME so the groups on offer are exactly the ones planted here.
#
# run_init <home> <project> <answer...> — path, six defaults (name, image, cpus,
# memory, reservation, swap), then the given answers from the group prompt on,
# then blank lines for whatever follows (group-init menu row 1, extra mounts).
run_init() {
  local home="$1" proj="$2"; shift 2
  mkdir -p "$proj"; git -C "$proj" init -q
  { printf '%s\n\n\n\n\n\n\n' "$proj"; printf '%s\n' "$@"; printf '\n\n\n'; } \
    | HOME="$home" bash "$SCRIPTS/project-init.sh" >"$proj.out" 2>"$proj.err"
}
group_of() { sed -n 's/^AI_CONTAINER_GROUP=//p' "$1/.ai-containers/sandbox.env"; }
init_of()  { sed -n 's/^AI_CONTAINER_GROUP_INIT=//p' "$1/.ai-containers/sandbox.local.env"; }
check() {  # $1=label $2=actual $3=expected
  [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (got '$2', want '$3')"
}

G="$TMP/pick"
HG="$TMP/home-groups"
mkdir -p "$HG/.ai-containers/"{default,docs,work,Not_A_Group}
HE="$TMP/home-empty"; mkdir -p "$HE"

run_init "$HE" "$G/fresh" ""
grep -qxF '  1) default (new)' "$G/fresh.out" && pass "picker: missing default is labelled (new)" || fail "picker: missing default is labelled (new)"
check "picker: Enter on a fresh machine → default" "$(group_of "$G/fresh")" "default"
check "picker: new default still bootstraps (from:host)" "$(init_of "$G/fresh")" "from:host"

run_init "$HG" "$G/bynum" "2"
grep -qxF '  1) default' "$G/bynum.out" && grep -qxF '  2) docs' "$G/bynum.out" && grep -qxF '  3) work' "$G/bynum.out" \
  && pass "picker: lists default first, then groups sorted" || fail "picker: lists default first, then groups sorted"
! grep -q 'Not_A_Group' "$G/bynum.out" && pass "picker: invalid dir names are not listed" || fail "picker: invalid dir names are not listed"
! grep -q '(new)' "$G/bynum.out" && pass "picker: existing default is not labelled (new)" || fail "picker: existing default is not labelled (new)"
check "picker: row number selects that group" "$(group_of "$G/bynum")" "docs"
check "picker: existing group needs no bootstrap" "$(init_of "$G/bynum")" ""

# The line after the name is an extra-mount path: had a confirmation prompt been
# shown it would have eaten that line instead, and EXTRA_MOUNTS would be missing.
run_init "$HG" "$G/byname" "work" "$TMP"
check "picker: typed existing name selects it" "$(group_of "$G/byname")" "work"
grep -q '^EXTRA_MOUNTS=' "$G/byname/.ai-containers/sandbox.local.env" \
  && pass "picker: existing name asks no confirmation" || fail "picker: existing name asks no confirmation"

run_init "$HG" "$G/typo" "dcos" "" "2"
check "picker: Enter declines creating a mistyped group" "$(group_of "$G/typo")" "docs"
[[ ! -d "$HG/.ai-containers/dcos" ]] && pass "picker: declined name leaves no directory" || fail "picker: declined name leaves no directory"
[[ "$(grep -cxF '  1) default' "$G/typo.out")" == 2 ]] && pass "picker: list shown again after declining" || fail "picker: list shown again after declining"

run_init "$HG" "$G/newgrp" "newgrp" "y" "1"
check "picker: confirmed new name is used" "$(group_of "$G/newgrp")" "newgrp"
check "picker: new group goes on to bootstrap menu" "$(init_of "$G/newgrp")" "from:default"
grep -q "Group 'newgrp' does not exist yet" "$G/newgrp.out" && pass "picker: bootstrap menu shown for new group" || fail "picker: bootstrap menu shown for new group"
! grep -q 'Not_A_Group' "$G/newgrp.out" && pass "bootstrap menu: invalid dir names are not listed" || fail "bootstrap menu: invalid dir names are not listed"

run_init "$HG" "$G/bad" "Bad Name" "3"
check "picker: invalid name re-prompts" "$(group_of "$G/bad")" "work"
grep -q 'Invalid group' "$G/bad.err" && pass "picker: invalid name reports why" || fail "picker: invalid name reports why"

run_init "$HG" "$G/outofrange" "9" "y"
check "picker: out-of-range number is a (confirmed) name" "$(group_of "$G/outofrange")" "9"

# A group that sorts BEFORE `default`. Every fixture above sorts after it
# (docs, work), so building the list WITHOUT pinning `default` to row 1
# produces byte-identical output and no assertion here notices — while on a
# machine that has an `alpha` group, row 1 becomes `alpha` and Enter, the one
# gesture this picker exists to leave unchanged, silently selects the wrong
# group. Verified: that mutation survived every other case in this file.
HA="$TMP/home-alpha"; mkdir -p "$HA/.ai-containers/"{alpha,default,zulu}
run_init "$HA" "$G/alpha" ""
grep -qxF '  1) default' "$G/alpha.out" \
  && pass "picker: default is row 1 even with a group sorting before it" || fail "picker: default is row 1 even with a group sorting before it"
grep -qxF '  2) alpha' "$G/alpha.out" \
  && pass "picker: the other groups follow default, still sorted" || fail "picker: the other groups follow default, still sorted"
check "picker: Enter still means default, not whatever sorts first" "$(group_of "$G/alpha")" "default"

run_init "$HG" "$G/host" "host" "$TMP"
check "picker: typed host selects the host sentinel" "$(group_of "$G/host")" "host"
check "picker: host needs no bootstrap" "$(init_of "$G/host")" ""
grep -q '^EXTRA_MOUNTS=' "$G/host/.ai-containers/sandbox.local.env" \
  && pass "picker: host asks no confirmation" || fail "picker: host asks no confirmation"
! grep -qE '^  [0-9]+\) host' "$G/host.out" && pass "picker: host is not a listed row" || fail "picker: host is not a listed row"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
