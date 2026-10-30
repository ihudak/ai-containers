#!/usr/bin/env bash
# tests/test-repo-git-reset.sh — repo-git-reset.sh against REAL git repositories.
#
# This file is the reason repo-git-reset.sh is a file at all. The rest of
# repo.sh's container-side work is a bash string inside `docker run … -c`, and
# tests/test-repo-destructive.sh's fake docker can only record that string — it
# cannot run git, so it can assert that a reset was ASKED FOR and never that a
# branch was deleted, a head moved, or work destroyed. Those are the only facts
# that matter for a destructive command.
#
# git is available hermetically; docker is not. So every repository below is a
# real one built by `git init`, with real commits, real branches, real
# remote-tracking refs and real unpushed work, and every assertion reads the
# repository's own state afterwards.
#
# The remote is a local bare repo, so there is no network and no auth: a `fetch`
# genuinely succeeds, and the offline path is exercised by deleting the remote
# rather than by pretending.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/repo-git-reset.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
SCRIPT="$ENGINE_DIR/repo-git-reset.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$SCRIPT" ]] || { printf 'SCAFFOLD-FAILED: no repo-git-reset.sh under %s\n' "$ENGINE_DIR"; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'SCAFFOLD-FAILED: no git\n'; exit 1; }

bash -n "$SCRIPT" && pass "repo-git-reset.sh bash -n" || fail "repo-git-reset.sh bash -n"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Owned by this shell only: p_timeout forks, and a child's EXIT must not delete
# the fixture this script is still using.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# Isolated git identity/config: these tests must not read or write the
# developer's real ~/.gitconfig, and must not depend on what it says.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
: > "$GIT_CONFIG_GLOBAL"

g() { git -C "$1" "${@:2}"; }
commit_in() {  # $1 = repo, $2 = filename
  printf '%s\n' "$2" > "$1/$2"
  g "$1" add -A >/dev/null 2>&1
  g "$1" commit -qm "add $2" >/dev/null 2>&1
}

# mk_repo <case-name> [default-branch] — a bare "remote" with a default branch
# and one extra branch, cloned into a working repo. Echoes the working repo path.
mk_repo() {
  local name="$1" head="${2:-main}"
  local remote="$TMP/$name.git" work="$TMP/$name"
  git init -q --bare --initial-branch="$head" "$remote" >/dev/null 2>&1
  local seed="$TMP/$name.seed"
  git init -q --initial-branch="$head" "$seed" >/dev/null 2>&1
  commit_in "$seed" first
  g "$seed" remote add origin "$remote" >/dev/null 2>&1
  g "$seed" push -q origin "$head" >/dev/null 2>&1
  # A second branch that exists on the remote too, so "pushed" is a real state.
  g "$seed" checkout -q -b shared >/dev/null 2>&1
  commit_in "$seed" shared-file
  g "$seed" push -q origin shared >/dev/null 2>&1
  g "$seed" checkout -q "$head" >/dev/null 2>&1
  git clone -q "$remote" "$work" >/dev/null 2>&1
  printf '%s' "$work"
}

# The helper fetches only from the URL repo.sh pins (AI_REPO_URL, from the
# volume's own label): here, the bare remote mk_repo made beside each checkout.
run_script() {  # $@ -> OUT / RC
  OUT="$(AI_REPO_URL="${AI_REPO_URL-${2:-}.git}" "$SCRIPT" "$@" 2>&1)"; RC=$?
}
OUT=""; RC=0

# ── 1. inspect: primary, branches, and what is genuinely unpushed ─────────────

W="$(mk_repo basic)"
g "$W" checkout -q -b feat/local >/dev/null 2>&1     # 2 commits on no remote
commit_in "$W" a
commit_in "$W" b
g "$W" checkout -q -b tracked origin/shared >/dev/null 2>&1   # fully pushed
g "$W" checkout -q main >/dev/null 2>&1

run_script inspect "$W"
if grep -q '^PRIMARY|main$' <<<"$OUT"; then
  pass "inspect names the remote's primary branch"
else
  fail "inspect names the remote's primary branch
$OUT"
fi
if grep -q '^BRANCH|feat/local|2|$' <<<"$OUT"; then
  pass "inspect counts commits that are on no remote"
else
  fail "inspect counts commits that are on no remote
$OUT"
fi
if grep -q '^BRANCH|tracked|0|$' <<<"$OUT"; then
  pass "a branch whose commits are all on a remote counts 0"
else
  fail "a branch whose commits are all on a remote counts 0
$OUT"
fi
if grep -q '^BRANCH|main|0|current$' <<<"$OUT"; then
  pass "inspect flags the checked-out branch"
else
  fail "inspect flags the checked-out branch
$OUT"
fi
if ! grep -q '^STALE|' <<<"$OUT"; then
  pass "a reachable remote produces no STALE record"
else
  fail "a reachable remote produces no STALE record
$OUT"
fi

# ── 1b. inspect: the stash and the tags replacing .git loses (REPO-8) ───────────
W="$(mk_repo losses)"
g "$W" checkout -q -b feat/local >/dev/null 2>&1; commit_in "$W" a
g "$W" tag lonely >/dev/null 2>&1                          # on a commit no remote has
g "$W" tag -a -m ann annlonely >/dev/null 2>&1             # annotated, on the same commit
g "$W" checkout -q main >/dev/null 2>&1
g "$W" tag onpushed >/dev/null 2>&1                        # local tag, pushed commit
g "$W" tag shipped >/dev/null 2>&1; g "$W" push -q origin shipped >/dev/null 2>&1
printf 'wip\n' >> "$W/first"; g "$W" stash -q >/dev/null 2>&1
run_script inspect "$W"
grep -qx 'STASH|1' <<<"$OUT" && pass "inspect reports the stash and its entry count" \
  || fail "inspect reports the stash
$OUT"
grep -qx 'TAG|lonely|no|no' <<<"$OUT" && grep -qx 'TAG|onpushed|no|yes' <<<"$OUT" && grep -qx 'TAG|shipped|yes|yes' <<<"$OUT" \
  && grep -qx 'TAG|annlonely|no|no' <<<"$OUT" \
  && pass "inspect reports each tag: kept by the remote, and whether its commit is on a remote branch" \
  || fail "inspect's TAG records
$OUT"
[[ "$(tail -n 1 <<<"$OUT")" == 'END|inspect' ]] && pass "inspect's last record is END (REPO-16)" \
  || fail "inspect's output does not end with END|inspect
$OUT"
# REPO-15: what the clone keeps, through the remote's tags as well as its
# branches; a tag the remote has at another object is "moved".
W="$(mk_repo tagkeep)"
g "$W" checkout -q -b feat/rt >/dev/null 2>&1; commit_in "$W" rt
g "$W" tag rt-remote >/dev/null 2>&1; g "$W" push -q origin rt-remote >/dev/null 2>&1   # only a remote TAG reaches it
g "$W" tag alsohere >/dev/null 2>&1                                                   # local tag, same commit
commit_in "$W" lost; g "$W" tag mvlost-src >/dev/null 2>&1                            # a commit no remote has
g "$W" checkout -q main >/dev/null 2>&1
g "$W" tag mvkept >/dev/null 2>&1; g "$W" tag mvlost >/dev/null 2>&1
g "$W" push -q origin mvkept mvlost >/dev/null 2>&1
g "$W" tag -f mvkept origin/shared >/dev/null 2>&1                                    # moved; its commit is on a remote branch
g "$W" tag -f mvlost mvlost-src >/dev/null 2>&1                                       # moved; its commit is on no remote ref
g "$W" tag -d mvlost-src >/dev/null 2>&1
run_script inspect "$W"
grep -qx 'TAG|alsohere|no|yes' <<<"$OUT" && grep -qx 'TAG|rt-remote|yes|yes' <<<"$OUT" \
  && grep -qx 'BRANCH|feat/rt|1|' <<<"$OUT" \
  && pass "a tag on a commit only a remote tag reaches is kept by the remote, not lost, nor counted unpushed" \
  || fail "a tag on a commit a remote tag reaches
$OUT"
grep -qx 'TAG|mvkept|moved|yes' <<<"$OUT" && grep -qx 'TAG|mvlost|moved|no' <<<"$OUT" \
  && pass "a tag the remote has at another object is reported moved, with whether its commit is kept" \
  || fail "a tag the remote has at another object
$OUT"
# With alternates of the volume's own its objects are not linked into the clone,
# so a commit the clone cannot see is unknown, never "no".
W="$(mk_repo tagalt)"
g "$W" checkout -q -b feat/alt >/dev/null 2>&1; commit_in "$W" alt; g "$W" tag alt >/dev/null 2>&1
g "$W" checkout -q main >/dev/null 2>&1
mkdir -p "$TMP/tagalt.extra/objects"; printf '%s\n' "$TMP/tagalt.extra/objects" > "$W/.git/objects/info/alternates"
run_script inspect "$W"
grep -qx 'TAG|alt|no|?' <<<"$OUT" && pass "a tag whose commit the clone cannot see is unknown, not lost" \
  || fail "a tag whose commit the clone cannot see
$OUT"
# The volume's objects are an alternate store in inspect, and git reads a
# commit-graph from an alternate too. One the agent forged, giving the remote
# tip a local-only commit as its parent, makes rev-list walk into that commit,
# so a branch whose work is on no remote counted 0 unpushed, and reset deleted
# it as pushed; the counts read no commit-graph. (for-each-ref --contains, which
# on_remote uses, is not fooled by this forgery on git 2.56; on_remote reads no
# commit-graph either, as defence.) The graph's first-parent field is rewritten
# by a small script (python3; skipped without it, as the socket check below is).
if command -v python3 >/dev/null 2>&1; then
  CG_FORGE="$TMP/cg-forge.py"
  cat > "$CG_FORGE" <<'FORGE'
# cg-forge.py <commit-graph> <commit-hex> <new-parent-hex>: rewrite <commit>'s
# first parent in a commit-graph file to <new-parent>, and its trailing hash.
import hashlib, struct, sys
path, target, parent = sys.argv[1], bytes.fromhex(sys.argv[2]), bytes.fromhex(sys.argv[3])
d = bytearray(open(path, 'rb').read())
assert d[:4] == b'CGPH', 'not a commit-graph'
hl = 20 if d[5] == 1 else 32
chunks = {}
for i in range(d[6] + 1):
    off = 8 + 12 * i
    chunks[bytes(d[off:off + 4])] = struct.unpack('>Q', bytes(d[off + 4:off + 12]))[0]
n = struct.unpack('>I', bytes(d[chunks[b'OIDF'] + 255 * 4:chunks[b'OIDF'] + 256 * 4]))[0]
oids = [bytes(d[chunks[b'OIDL'] + i * hl:chunks[b'OIDL'] + (i + 1) * hl]) for i in range(n)]
rec = chunks[b'CDAT'] + oids.index(target) * (hl + 16)
d[rec + hl:rec + hl + 4] = struct.pack('>I', oids.index(parent))
d[-hl:] = (hashlib.sha1 if hl == 20 else hashlib.sha256)(bytes(d[:-hl])).digest()
open(path, 'wb').write(d)
FORGE
  W="$(mk_repo cgforge)"; S="$TMP/cgforge.seed"
  commit_in "$S" c2; commit_in "$S" c3; g "$S" push -q origin main >/dev/null 2>&1
  g "$W" pull -q --ff-only >/dev/null 2>&1
  g "$W" checkout -q -b loc "$(g "$W" rev-list --max-parents=0 HEAD)" >/dev/null 2>&1
  printf 'l\n' > "$W/l"; g "$W" add l
  GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' g "$W" commit -qm local >/dev/null 2>&1
  g "$W" tag cgtag; lc="$(g "$W" rev-parse HEAD)"; g "$W" checkout -q main >/dev/null 2>&1
  g "$W" -c commitGraph.generationVersion=1 commit-graph write --reachable >/dev/null 2>&1
  chmod u+w "$W/.git/objects/info/commit-graph"                    # git writes it read-only
  python3 -I "$CG_FORGE" "$W/.git/objects/info/commit-graph" "$(g "$W" rev-parse origin/main)" "$lc"
  if [[ "$(g "$W" rev-list --count "$lc" --not --remotes=origin)" == 0 \
        && "$(g "$W" -c core.commitGraph=false rev-list --count "$lc" --not --remotes=origin)" == 1 ]]; then
    run_script inspect "$W"
    grep -qx 'BRANCH|loc|1|' <<<"$OUT" && grep -qx 'TAG|cgtag|no|no' <<<"$OUT" \
      && pass "a forged commit-graph in the volume does not make local work look pushed" \
      || fail "a forged commit-graph in the volume
$OUT"
  else
    fail "commit-graph fixture: the forged graph does not make rev-list walk into $lc"
  fi
else
  printf 'SKIP: the forged commit-graph check needs python3\n'
fi
# A hand-written tag file whose name ends in a newline is one record, its state
# unknown, never matched as "kept" (review of REPO-8; one record since REPO-10).
W="$(mk_repo tagnl)"
g "$W" checkout -q -b feat/x >/dev/null 2>&1; commit_in "$W" a
g "$W" rev-parse HEAD > "$W/.git/refs/tags/wip"$'\n'
g "$W" checkout -q main >/dev/null 2>&1
run_script inspect "$W"
grep -qx 'TAG|wip?|?|?' <<<"$OUT" && [[ "$(grep -c '^TAG|' <<<"$OUT")" == 1 ]] && ! grep -q '^TAG|.*|yes|' <<<"$OUT" \
  && pass "a tag name with a newline is one record, reported unknown, not kept" \
  || fail "a tag name with a newline
$OUT"
# REPO-10: a branch file named with a newline split into a fake BRANCH record
# (here one claiming a pushed branch named "fake"); it is one record, unknown.
W="$(mk_repo branchnl)"
g "$W" rev-parse HEAD > "$W/.git/refs/heads/feat"$'\n'"fake"
run_script inspect "$W"
grep -qx 'BRANCH|feat?fake|?|' <<<"$OUT" && ! grep -q '^BRANCH|fake|' <<<"$OUT" \
  && pass "a branch name with a newline is one record, not two" \
  || fail "a branch name with a newline
$OUT"
W="$(mk_repo branchtab)"
g "$W" rev-parse HEAD > "$W/.git/refs/heads/feat"$'\t'"fake"
run_script inspect "$W"
grep -qx 'BRANCH|feat?fake|?|' <<<"$OUT" && ! grep -q '^BRANCH|feat|' <<<"$OUT" \
  && pass "a branch name with a tab is one record, its state unknown" \
  || fail "a branch name with a tab
$OUT"
# A tag the remote has at another object but on the same commit (lightweight
# here, annotated there) is "same": its commit is kept.
W="$(mk_repo tagsame)"; S="$TMP/tagsame.seed"
g "$S" tag -a -m 'the release' v1 >/dev/null 2>&1; g "$S" push -q origin v1 >/dev/null 2>&1
g "$W" tag v1 "$(g "$S" rev-parse 'v1^{commit}')" >/dev/null 2>&1
run_script inspect "$W"
grep -qx 'TAG|v1|same|yes' <<<"$OUT" && pass "a tag the remote has as another object on the same commit is reported same" \
  || fail "a retyped tag on the same commit
$OUT"
# A stash whose reflog is gone is still a stash (its count unknown).
W="$(mk_repo stashnolog)"
printf 'wip\n' >> "$W/first"; g "$W" stash -q >/dev/null 2>&1; rm -f "$W/.git/logs/refs/stash"
run_script inspect "$W"
grep -qx 'STASH|?' <<<"$OUT" && pass "inspect reports a stash with no reflog, its count unknown" \
  || fail "inspect missed a stash with no reflog
$OUT"
# With the remote gone nothing about a tag is known: never a guessed "no".
W="$(mk_repo tagoffline)"
g "$W" tag t1 >/dev/null 2>&1; rm -rf "$TMP/tagoffline.git"
run_script inspect "$W"
grep -qx 'TAG|t1|?|?' <<<"$OUT" && pass "with the remote unreachable, a tag's state is unknown, not 'no'" \
  || fail "a tag's state with the remote unreachable
$OUT"
[[ "$(tail -n 1 <<<"$OUT")" == 'END|inspect' ]] && pass "  … and a STALE inspection still ends with END" \
  || fail "a STALE inspection does not end with END|inspect
$OUT"
W="$(mk_repo nolosses)"
run_script inspect "$W"
! grep -q '^STASH|' <<<"$OUT" && ! grep -q '^TAG|' <<<"$OUT" && pass "no stash and no tags: no such records" \
  || fail "spurious STASH/TAG records
$OUT"

# ── 2. reset: on primary, at the remote tip, other branches gone ──────────────

W="$(mk_repo doreset)"
g "$W" checkout -q -b feat/local >/dev/null 2>&1
commit_in "$W" a
g "$W" checkout -q -b another >/dev/null 2>&1
printf 'dirty\n' > "$W/first"          # uncommitted change
printf 'junk\n'  > "$W/untracked.txt"  # untracked file
mkdir -p "$W/subdir" && printf 'x\n' > "$W/subdir/deep.txt"

run_script reset "$W" main
if [[ "$RC" -eq 0 ]]; then pass "reset exits 0"; else fail "reset exits 0 (rc=$RC)
$OUT"; fi

if [[ "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "reset leaves the checkout ON the primary branch"
else
  fail "reset leaves the checkout ON the primary branch (on $(g "$W" symbolic-ref --short HEAD))"
fi

remaining="$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
if [[ "$remaining" == "main " ]]; then
  pass "every other local branch is deleted"
else
  fail "every other local branch is deleted (left: $remaining)"
fi

if [[ "$(g "$W" rev-parse HEAD)" == "$(g "$W" rev-parse origin/main)" ]]; then
  pass "reset moves the primary branch to the remote tip"
else
  fail "reset moves the primary branch to the remote tip"
fi

if [[ ! -f "$W/untracked.txt" && ! -d "$W/subdir" ]] && [[ -z "$(g "$W" status --porcelain)" ]]; then
  pass "the working tree is clean — untracked files and edits are gone"
else
  fail "the working tree is clean ($(g "$W" status --porcelain | tr '\n' ' '))"
fi

if grep -q '^DELETED|feat/local$' <<<"$OUT" && grep -q '^DELETED-COUNT|2$' <<<"$OUT"; then
  pass "reset reports each branch it deleted, and how many"
else
  fail "reset reports each branch it deleted, and how many
$OUT"
fi
# A branch git REFUSES to delete reports KEPT, and the count above still looks
# right — so "the count is 2" alone cannot tell a clean run from one that tried
# to delete the checked-out branch and failed.
if ! grep -q '^KEPT|' <<<"$OUT"; then
  pass "a clean reset keeps nothing back"
else
  fail "a clean reset keeps nothing back
$OUT"
fi

# ── 3. the primary branch it is TOLD to use is the one it uses ────────────────

# The prompt names a branch; reset must honour that name rather than re-deriving
# one, or what was approved and what happens can differ.
W="$(mk_repo told)"
g "$W" checkout -q -b shared origin/shared >/dev/null 2>&1
g "$W" checkout -q main >/dev/null 2>&1
run_script reset "$W" shared
if [[ "$(g "$W" symbolic-ref --short HEAD)" == "shared" ]]; then
  pass "reset honours the primary branch it was given, not one it re-derives"
else
  fail "reset honours the primary branch it was given (on $(g "$W" symbolic-ref --short HEAD))"
fi
# The clone checks out the remote's HEAD branch (main) as well; reset deletes
# it from the clone before installing its .git, or the volume keeps a branch
# that it was asked to drop.
remaining="$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | tr '\n' ' ')"
if [[ "$remaining" == "shared " ]]; then
  pass "… and the remote's default branch is not left behind beside it"
else
  fail "… and the remote's default branch is not left behind beside it (left: $remaining)"
fi

# ── 4. a primary branch that exists only on the remote ────────────────────────

W="$(mk_repo remoteonly)"
g "$W" checkout -q -b work origin/shared >/dev/null 2>&1
g "$W" branch -D main >/dev/null 2>&1       # no local main at all
run_script reset "$W" main
if [[ "$RC" -eq 0 && "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "a primary branch present only on the remote is created and checked out"
else
  fail "a primary branch present only on the remote is created and checked out (rc=$RC)
$OUT"
fi

# ── 5. master, not main — the name is never assumed ───────────────────────────

W="$(mk_repo oldschool master)"
run_script inspect "$W"
if grep -q '^PRIMARY|master$' <<<"$OUT"; then
  pass "a repository whose default is master is detected as master"
else
  fail "a repository whose default is master is detected as master
$OUT"
fi

# ── 5b. a default branch that is neither main nor master ─────────────────────
#
# With main/master fixtures alone, every step of the fallback chain returns the
# same answer, so inverting or skipping any of them changes nothing observable.
# A default of `trunk` — with something ELSE checked out, so the last-resort
# fallback would give a different answer — is what makes the steps distinguishable.
W="$(mk_repo trunkrepo trunk)"
g "$W" checkout -q -b shared origin/shared >/dev/null 2>&1
run_script inspect "$W"
if grep -q '^PRIMARY|trunk$' <<<"$OUT"; then
  pass "the remote's own HEAD wins over guessing, and over what is checked out"
else
  fail "the remote's own HEAD wins over guessing, and over what is checked out
$OUT"
fi

# ── 5c. no origin/HEAD to read: the main/master guesses ──────────────────────
#
# The helper clones the recorded URL afresh, so the volume's own origin is never
# read. The guess loop runs when the REMOTE's HEAD names a branch it does not
# have: the clone then records no origin/HEAD. This case used to delete the
# volume's origin/HEAD instead, which the fresh clone never sees, so it went
# through origin/HEAD and reached no guess (TST-11). Nothing else in this file
# reaches that loop.
W="$(mk_repo guessing)"
git -C "$TMP/guessing.git" symbolic-ref HEAD refs/heads/gone
run_script inspect "$W"
if [[ "$RC" -eq 0 ]] && grep -qx 'PRIMARY|main' <<<"$OUT"; then
  pass "with no origin/HEAD, the first EXISTING guess is used"
else
  fail "with no origin/HEAD, the first existing guess is used (rc=$RC)
$OUT"
fi
# Neither guess exists: no PRIMARY at all, rather than an empty one.
W="$(mk_repo guessnone trunk)"
git -C "$TMP/guessnone.git" symbolic-ref HEAD refs/heads/gone
run_script inspect "$W"
if [[ "$RC" -eq 0 ]] && ! grep -q '^PRIMARY|' <<<"$OUT"; then
  pass "with no origin/HEAD and no main or master, no primary branch is named"
else
  fail "with no origin/HEAD and no main or master, no primary branch is named (rc=$RC)
$OUT"
fi

# ── 6. offline: the remote is gone ───────────────────────────────────────────

W="$(mk_repo offline)"
g "$W" checkout -q -b feat/x >/dev/null 2>&1
commit_in "$W" a
rm -rf "$TMP/offline.git"                    # the remote no longer exists
run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT"; then
  pass "an unreachable remote is reported as STALE"
else
  fail "an unreachable remote is reported as STALE
$OUT"
fi
# Nothing in the volume names the primary or proves a branch pushed: the refs
# there are the agent's to write. Without the remote, neither is claimed.
if ! grep -q '^PRIMARY|' <<<"$OUT" && grep -qx 'BRANCH|feat/x|?|current' <<<"$OUT"; then
  pass "… with no primary claimed and every count unknown"
else
  fail "… with no primary claimed and every count unknown
$OUT"
fi
stale_line="$(grep '^STALE|' <<<"$OUT")"
if [[ "$(wc -l <<<"$stale_line")" -eq 1 ]]; then
  pass "the STALE reason is one line — the record-per-line contract holds"
else
  fail "the STALE reason is one line — a multi-line git error corrupts parsing
$stale_line"
fi
printf 'edit\n' > "$W/a"
run_script reset "$W" main
if [[ "$RC" -ne 0 && "$OUT" == *"cannot clone the recorded remote"* && "$(cat "$W/a")" == edit ]] \
   && [[ "$(g "$W" symbolic-ref --short HEAD)" == "feat/x" ]]; then
  pass "reset refuses offline, and leaves the checkout exactly as it was"
else
  fail "offline reset (rc=$RC)
$OUT"
fi

# ── 7. a repository with no remote at all ────────────────────────────────────

W="$TMP/noremote"; git init -q --initial-branch=main "$W" >/dev/null 2>&1
commit_in "$W" first
g "$W" checkout -q -b side >/dev/null 2>&1
commit_in "$W" side-file
# The recorded URL is the only remote, whatever the .git says, and here it leads
# nowhere: STALE says so, both branches are listed, and nothing is claimed.
run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT" && ! grep -q '^PRIMARY|' <<<"$OUT" \
   && grep -qx 'BRANCH|side|?|current' <<<"$OUT" && grep -qx 'BRANCH|main|?|' <<<"$OUT"; then
  pass "with no reachable remote, STALE says why, the branches are listed, and no primary is claimed"
else
  fail "with no reachable remote
$OUT"
fi
run_script reset "$W" main
if [[ "$RC" -ne 0 && "$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | wc -l)" -eq 2 ]]; then
  pass "… and reset refuses it, deleting nothing"
else
  fail "reset without a remote (rc=$RC)
$OUT"
fi

# ── 7b. a detached HEAD with no remote — there is no branch to name ──────────
#
# The one path where detect_primary has no answer at all. Every other fixture
# reaches one of the fallbacks, so its "found nothing" return was unobservable
# and could be flipped to success with no test noticing.
W="$TMP/detached"; git init -q --initial-branch=main "$W" >/dev/null 2>&1
commit_in "$W" first
commit_in "$W" second
g "$W" checkout -q --detach HEAD~1 >/dev/null 2>&1
run_script inspect "$W"
if ! grep -q '^PRIMARY|' <<<"$OUT"; then
  pass "a detached HEAD with no remote yields NO primary — not an empty one"
else
  fail "a detached HEAD with no remote yields no primary
$OUT"
fi

# ── 8. refusals ──────────────────────────────────────────────────────────────

run_script reset "$TMP" main
if [[ "$RC" -ne 0 ]] && grep -q 'not a git repository' <<<"$OUT"; then
  pass "a directory that is not a git repository is refused"
else
  fail "a directory that is not a git repository is refused (rc=$RC)
$OUT"
fi

W="$(mk_repo nosuch)"
run_script reset "$W" nonexistent-branch
if [[ "$RC" -ne 0 ]] && grep -q 'the remote has no branch named' <<<"$OUT"; then
  pass "a primary branch that exists nowhere is refused, not invented"
else
  fail "a primary branch that exists nowhere is refused, not invented (rc=$RC)
$OUT"
fi
if [[ "$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | wc -l)" -ge 1 ]]; then
  pass "… and nothing was deleted on the way to that refusal"
else
  fail "… and nothing was deleted on the way to that refusal"
fi

# By its OWN message: with no argument the directory check downstream also
# fails, so a bare "rc != 0" passes whether or not the argument guard exists.
run_script inspect
if [[ "$RC" -ne 0 ]] && grep -q 'inspect needs a directory' <<<"$OUT"; then
  pass "inspect with no directory is refused by the argument guard"
else
  fail "inspect with no directory is refused by the argument guard (rc=$RC)
$OUT"
fi
# By its own message: with a directory but no primary, the checks downstream
# also fail, so a bare "rc != 0" passes whether or not this guard exists.
run_script reset "$W"
if [[ "$RC" -ne 0 ]] && grep -q 'reset needs a directory and a primary branch' <<<"$OUT"; then
  pass "reset without a primary branch is refused by the argument guard"
else
  fail "reset without a primary branch is refused by the argument guard (rc=$RC)
$OUT"
fi

# A primary that is not a branch name is refused by name, before the clone: a
# leading dash (which check-ref-format refuses as well, so the dash test is not
# what kills it), and a name git's own rules refuse.
for bad in -x 'a..b'; do
  run_script reset "$W" "$bad"
  if [[ "$RC" -ne 0 ]] && grep -qF "not a branch name: $bad" <<<"$OUT"; then
    pass "reset refuses the primary '$bad' as not a branch name"
  else
    fail "reset refuses the primary '$bad' as not a branch name (rc=$RC)
$OUT"
  fi
done

run_script frobnicate "$W"
if [[ "$RC" -ne 0 ]]; then pass "an unknown subcommand is refused"; else fail "an unknown subcommand is refused"; fi

# ── 9. the global git config is written ONLY as root ─────────────────────────
#
# Read with `git config`, not `grep`. This assertion first grepped the file for
# the string "safe.directory" — which git never writes: the on-disk form is a
# `[safe]` section with a `directory =` key. The grep could not match on any
# input, so the check passed unconditionally and every mutant of the root guard
# it was meant to cover survived. That is the exact shape of guard this suite
# exists to keep out, and it got in anyway.
safe_dirs="$(GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" git config --global --get-all safe.directory 2>/dev/null)"
if [[ "$(id -u)" == "0" ]]; then
  if [[ -n "$safe_dirs" ]]; then
    pass "running as root, the repo is marked a safe.directory — the container case this is for"
  else
    fail "running as root, the repo is marked a safe.directory (got nothing)"
  fi
else
  if [[ -z "$safe_dirs" ]]; then
    pass "running as a normal user, no global safe.directory is written"
  else
    fail "running as a normal user, no global safe.directory is written (got: $safe_dirs)"
  fi
fi

# ── 10. the ownership argument ───────────────────────────────────────────────
#
# Optional, and the only part of reset with a visible failure mode that is not
# a git operation. Chowning to your own identity succeeds unprivileged; an
# identity that does not exist fails for root and non-root alike, so neither
# case depends on who runs the suite.
W="$(mk_repo owned)"
run_script reset "$W" main "$(id -u):$(id -g)"
if [[ "$RC" -eq 0 ]] && ! grep -q '^WARN|' <<<"$OUT"; then
  pass "a valid owner is applied without complaint"
else
  fail "a valid owner is applied without complaint (rc=$RC)
$OUT"
fi

W="$(mk_repo unowned)"
run_script reset "$W" main "nosuchuser99999:nosuchgroup99999"
if grep -q '^WARN|chown failed' <<<"$OUT"; then
  pass "an owner that cannot be applied is reported, not swallowed"
else
  fail "an owner that cannot be applied is reported, not swallowed
$OUT"
fi
if [[ "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "… and the reset itself still happened"
else
  fail "… and the reset itself still happened"
fi

# ── The helper runs as ROOT in the seed container, with your ~/.ssh keys and an
# open network, on a .git the agent can write through any :rw repo volume — the
# launcher's git-internals overlay covers host binds, not volumes. Nothing that
# .git holds may run: not config keys, not includes, not hooks (bugs-review
# re-review of batch 2, F6). The config is cut to the keys a fetch and a
# checkout need, and a .git holding anything but files and directories, or not
# a directory at all, is refused.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"
W="$(mk_repo poisoned)"
M="$TMP/ran-poisoned"
printf 'x\n' > "$TMP/evil.gitconfig"
git -C "$W" config core.fsmonitor "sh -c 'echo fsmonitor >> $M'"
git -C "$W" config include.path "$TMP/evil.gitconfig"
git config --file "$TMP/evil.gitconfig" core.fsmonitor "sh -c 'echo include >> $M'"
git -C "$W" config filter.evil.smudge "sh -c 'echo smudge >> $M; cat'"
printf '* filter=evil\n' > "$W/.git/info/attributes"
for h in post-checkout post-merge reference-transaction pre-auto-gc post-rewrite; do
  printf '#!/bin/sh\necho %s >> %s\n' "$h" "$M" > "$W/.git/hooks/$h"; chmod +x "$W/.git/hooks/$h"
done
url_before="$(git -C "$W" remote get-url origin)"
run_script inspect "$W"
run_script reset "$W" main; out_r="$OUT"
if [[ ! -e "$M" ]]; then pass "nothing the .git holds runs: config keys, an include, a filter, hooks"
else fail "the agent's .git ran: $(tr '\n' ' ' < "$M")"; fi
if [[ "$out_r" == *"ON|main"* && "$(git -C "$W" remote get-url origin)" == "$url_before" ]]; then
  pass "… and the reset still works, with the remote kept"
else
  fail "reset after sanitising (out: $out_r)"
fi
if ! git config --file "$W/.git/config" --get core.fsmonitor >/dev/null && ! git config --file "$W/.git/config" --get include.path >/dev/null \
   && ! git config --file "$W/.git/config" --get filter.evil.smudge >/dev/null; then
  pass "the config is cut to what a fetch and a checkout need"
else
  fail "dangerous keys survived: $(git config --file "$W/.git/config" --list | tr '\n' ' ')"
fi
rm -f "$M"

W="$(mk_repo fifo)"
mkfifo "$W/.git/refs/heads/evil"
AI_REPO_URL="$TMP/fifo.git" p_timeout 20 "$SCRIPT" inspect "$W" >"$TMP/fifo.out" 2>&1; rc=$?
if [[ "$rc" != 0 && "$rc" != 124 ]] && grep -q 'not a regular file or directory' "$TMP/fifo.out"; then
  pass "a FIFO in .git is refused, not read (no hang)"
else
  fail "FIFO in .git (rc=$rc: $(tr '\n' ' ' < "$TMP/fifo.out"))"
fi
( exec 3<>"$W/.git/refs/heads/evil" ) 2>/dev/null

W="$(mk_repo gitfile)"
mv "$W/.git" "$TMP/gitfile-real.git"; printf 'gitdir: %s\n' "$TMP/gitfile-real.git" > "$W/.git"
run_script inspect "$W"
if [[ "$RC" != 0 && "$OUT" == *"is a file or link"* ]]; then pass "a .git FILE (pointing anywhere) is refused"
else fail ".git file accepted (rc=$RC: $OUT)"; fi

W="$(mk_repo gitlink-top)"
mv "$W/.git" "$TMP/gitlink-top-real.git"; ln -s "$TMP/gitlink-top-real.git" "$W/.git"
run_script inspect "$W"
if [[ "$RC" != 0 && "$OUT" == *"is a file or link"* ]]; then pass "a .git that is a symlink is refused"
else fail ".git symlink accepted (rc=$RC: $OUT)"; fi
# Nested more than one level: a repository inside a nested one is listed and
# removed too, and sync refuses it.
W="$(mk_repo nest2)"; mkdir -p "$W/a/.git" "$W/a/b/c/.git"
run_script inspect "$W"
if grep -qx 'NESTED|a/.git' <<<"$OUT" && grep -qx 'NESTED|a/b/c/.git' <<<"$OUT"; then pass "inspect lists a repository nested inside a nested one"
else fail "two levels of nesting (out: $OUT)"; fi
run_script pull "$W"
[[ "$RC" != 0 && "$OUT" == *"inside the checkout"* ]] && pass "  … sync refuses them" || fail "sync and two levels of nesting (rc=$RC; out: $OUT)"
run_script reset "$W" main
if [[ "$RC" == 0 && ! -e "$W/a/.git" && ! -e "$W/a/b/c/.git" ]]; then pass "  … and reset removes both"
else fail "reset and two levels of nesting (rc=$RC; out: $OUT)"; fi

# The remote is the one repo.sh recorded, not the one the .git names: the agent
# could point origin at any repository your SSH key reads, and the next sync
# would fetch it into a volume it reads (security review of 6f5dd80).
W="$(mk_repo pinned)"; mk_repo other >/dev/null
git -C "$W" remote set-url origin "$TMP/other.git"
git -C "$W" remote add extra "$TMP/other.git"
run_script inspect "$W"
grep -qx 'PRIMARY|main' <<<"$OUT" || fail "inspect read the remote the .git names (out: $(tr '\n' ' ' <<<"$OUT"))"
run_script reset "$W" main
if [[ "$(git -C "$W" remote get-url origin)" == "$TMP/pinned.git" ]] && ! git -C "$W" remote get-url extra >/dev/null 2>&1 \
   && [[ "$(git config --file "$W/.git/config" --get remote.origin.fetch)" == '+refs/heads/*:refs/remotes/origin/*' ]]; then
  pass "the remote is the recorded URL, with the standard refspec, and no other remote is kept"
else
  fail "remote not pinned (origin: $(git -C "$W" remote get-url origin); remotes: $(git -C "$W" remote | tr '\n' ' '))"
fi
AI_REPO_URL="" run_script inspect "$W"
if [[ "$RC" != 0 && "$OUT" == *"no recorded URL"* ]]; then pass "without a recorded URL the helper runs no git at all"
else fail "helper ran without AI_REPO_URL (rc=$RC: $OUT)"; fi
if grep -qF -- '-c fetch.recurseSubmodules=false' "$SCRIPT" && grep -qF -- '-c submodule.recurse=false' "$SCRIPT"; then
  pass "submodules are never recursed into (their config is not sanitised)"
else
  fail "the git wrapper does not turn submodule recursion off"
fi

# With .git/config deleted, git falls back to a legacy .git/remotes/origin (or
# .git/branches/origin) for the remote: the pin must not depend on a config file
# being there to rewrite (re-review of b86cfe6).
W="$(mk_repo legacy)"; mk_repo secret >/dev/null
S2="$TMP/secret.seed"; commit_in "$S2" SECRET-CONTENT; g "$S2" push -q origin main >/dev/null 2>&1
rm -f "$W/.git/config"; mkdir -p "$W/.git/remotes" "$W/.git/branches"
printf 'URL: %s\nPull: refs/heads/*:refs/remotes/origin/*\n' "$TMP/secret.git" > "$W/.git/remotes/origin"
printf '%s\n' "$TMP/secret.git" > "$W/.git/branches/origin"
run_script inspect "$W"; run_script reset "$W" main
log_l="$(git -C "$W" log --all --format=%s 2>/dev/null)"
if [[ $'\n'"$log_l"$'\n' != *$'\nadd SECRET-CONTENT\n'* ]] \
   && [[ ! -e "$W/.git/remotes" && ! -e "$W/.git/branches" ]]; then
  pass "a deleted config with a legacy remotes file still fetches only the recorded URL"
else
  fail "legacy remote file was used (log: $(git -C "$W" log --all --format=%s 2>&1 | tr '\n' ' '); out: $OUT)"
fi
# An alternates chain into the worktree can end in a FIFO the scan of .git never
# sees: a seed clone has no alternates, so the file is not kept (re-review, F2).
W="$(mk_repo alt)"
mkdir -p "$W/evil/info" && mkfifo "$W/evil/info/alternates"
printf '%s\n' "$W/evil" > "$W/.git/objects/info/alternates"
AI_REPO_URL="$TMP/alt.git" p_timeout 20 "$SCRIPT" inspect "$W" >"$TMP/alt.out" 2>&1; rc=$?
# Either guard stops it: the FIFO in the worktree is refused, or the alternates
# file that leads to it is dropped. What must never happen is the hang.
if [[ "$rc" != 124 ]] && { [[ ! -e "$W/.git/objects/info/alternates" ]] || grep -q 'not a regular file or directory' "$TMP/alt.out"; }; then
  pass "an alternates chain to a FIFO hangs nothing"
else fail "alternates (rc=$rc: $(tr '\n' ' ' < "$TMP/alt.out"))"; fi
( exec 3<>"$W/evil/info/alternates" ) 2>/dev/null
# A branch named like an option is a refname the agent can write; it is never
# handed to git where an option is parsed (re-review, F3).
W="$(mk_repo dash)"
g "$W" update-ref "refs/heads/--output=$TMP/dash-pwned" HEAD
run_script inspect "$W"
run_script reset "$W" main
if [[ ! -e "$TMP/dash-pwned" ]]; then pass "a branch named --output=… is not parsed as an option"
else fail "a branch name was parsed as an option ($TMP/dash-pwned was written)"; fi

# reset promises the remote's tip and a clean slate; refs the agent can write
# must not redirect it (re-review of the batch 2 fixes, G1-G5).
evil_commit() {  # $1 = repo → a commit whose f says EVIL, on no branch
  local t; t="$(printf 'EVIL\n' | git -C "$1" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\tfirst\n' "$t" | git -C "$1" mktree)"
  git -C "$1" commit-tree "$t" -m evil </dev/null
}
W="$(mk_repo tagjack)"; g "$W" tag origin/main "$(evil_commit "$W")"
run_script inspect "$W"; run_script reset "$W" main
if [[ "$(cat "$W/first")" == first ]]; then pass "a tag named origin/<primary> does not take over reset's target"
else fail "reset landed on the agent's tag (first: $(cat "$W/first"); out: $OUT)"; fi
W="$(mk_repo replace)"; g "$W" replace -f "$(g "$W" rev-parse origin/main)" "$(evil_commit "$W")"
run_script inspect "$W"; run_script reset "$W" main
if [[ "$(cat "$W/first")" == first && -z "$(g "$W" for-each-ref refs/replace)" ]]; then
  pass "a replace ref neither swaps reset's content nor survives it"
else fail "replace ref (first: $(cat "$W/first"); refs: $(g "$W" for-each-ref refs/replace | tr '\n' ' '))"; fi
W="$(mk_repo ambig)"; g "$W" checkout -q -b rel >/dev/null 2>&1; commit_in "$W" r1; commit_in "$W" r2
g "$W" checkout -q main >/dev/null 2>&1; g "$W" tag rel main
run_script inspect "$W"
if grep -qx 'BRANCH|rel|2|' <<<"$OUT"; then pass "a branch that shares its name with a tag is reported by its name, with its unpushed count"
else fail "ambiguous branch (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
run_script reset "$W" main
if ! g "$W" show-ref --verify --quiet refs/heads/rel && grep -qx 'DELETED|rel' <<<"$OUT"; then pass "… and reset really deletes it"
else fail "reset of ambiguous branch (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
W="$(mk_repo hide)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" w1; commit_in "$W" w2; commit_in "$W" w3
g "$W" update-ref refs/remotes/elsewhere/work work; g "$W" checkout -q main >/dev/null 2>&1
run_script inspect "$W"
if grep -qx 'BRANCH|work|3|' <<<"$OUT"; then pass "unpushed work is counted against origin, not refs the agent can plant"
else fail "unpushed count fooled (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
W="$(mk_repo attrfifo)"; mkfifo "$W/.gitattributes"
AI_REPO_URL="$TMP/attrfifo.git" p_timeout 20 "$SCRIPT" reset "$W" main >"$TMP/af.out" 2>&1; rc=$?
if [[ "$rc" != 124 ]] && grep -q 'not a regular file or directory' "$TMP/af.out"; then pass "a FIFO in the worktree is refused, not read (no hang)"
else fail "worktree FIFO (rc=$rc: $(tr '\n' ' ' < "$TMP/af.out"))"; fi
( exec 3<>"$W/.gitattributes" ) 2>/dev/null

# refs/remotes/origin is the agent's to write; a successful fetch overwrites it
# with the remote's tips, but a failed one leaves it as planted — so then no
# count is trusted (security review of 61f7806).
W="$(mk_repo staleref)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" s1
g "$W" update-ref refs/remotes/origin/work work; g "$W" checkout -q main >/dev/null 2>&1
AI_REPO_URL="$TMP/does-not-exist.git" run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT" && grep -qx 'BRANCH|work|?|' <<<"$OUT"; then
  pass "after a failed fetch every unpushed count is unknown, not read from planted refs"
else
  fail "stale refs trusted (out: $(tr '\n' ' ' <<<"$OUT"))"
fi

# A symbolic ref under refs/remotes/origin survives fetch --prune; it must not
# make unpushed work look pushed (security review of cbf90aa).
W="$(mk_repo symref)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" y1; commit_in "$W" y2
g "$W" checkout -q main >/dev/null 2>&1; g "$W" symbolic-ref refs/remotes/origin/planted refs/heads/work
run_script inspect "$W"
if grep -qx 'BRANCH|work|2|' <<<"$OUT"; then pass "a planted symbolic ref under refs/remotes/origin hides no unpushed work"
else fail "symbolic ref hid unpushed work (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# … nor with a .lock beside it (security review of f6368d6): the volume's refs
# are never what a count is made against.
W="$(mk_repo symlock)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" z1
g "$W" checkout -q main >/dev/null 2>&1; g "$W" symbolic-ref refs/remotes/origin/planted refs/heads/work
: > "$W/.git/refs/remotes/origin/planted.lock"
run_script inspect "$W"
if grep -qx 'BRANCH|work|1|' <<<"$OUT"; then pass "a planted symbolic ref that cannot be removed hides no unpushed work"
else fail "undeletable symref trusted (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# The replace-ref cleanup is itself a ref update: an agent's reference-transaction
# hook must not run through it (re-review of 61f7806, H1).
W="$(mk_repo hookreplace)"; M2="$TMP/ran-hookreplace"
g "$W" replace -f "$(g "$W" rev-parse HEAD)" "$(evil_commit "$W")"
printf '#!/bin/sh\necho ran >> %s\n' "$M2" > "$W/.git/hooks/reference-transaction"; chmod +x "$W/.git/hooks/reference-transaction"
run_script inspect "$W"; run_script reset "$W" main
if [[ ! -e "$M2" && -z "$(g "$W" for-each-ref refs/replace)" && ! -e "$W/.git/hooks/reference-transaction" ]]; then
  pass "a replace ref and a hook in the volume's .git run nothing, and are gone after reset"
else fail "hook ran during replace-ref cleanup ($(cat "$M2" 2>/dev/null | wc -l) times)"; fi
# A socket in the checkout does not hang git and clean -ffdx removes it, so it
# is not refused; a FIFO is (re-review, H5).
W="$(mk_repo sock)"
if command -v python3 >/dev/null 2>&1; then
  python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$W/app.sock"
  run_script reset "$W" main
  if [[ "$RC" == 0 ]]; then pass "a stale socket in the checkout does not refuse the reset"
  else fail "socket refused (rc=$RC: $OUT)"; fi
fi
# The grafts setting must not bury a fetch error under git's deprecation hint.
W="$(mk_repo hint)"
AI_REPO_URL="$TMP/does-not-exist.git" run_script inspect "$W"
if grep -q '^STALE|fatal: repository .*does-not-exist.git' <<<"$OUT" && ! grep -qi 'graft' <<<"$OUT"; then
  pass "an unreachable remote's STALE reason is git's error, not a grafts hint"
else fail "STALE reason (out: $(grep STALE <<<"$OUT" | cut -c1-160))"; fi

# pull: the fast-forward repo.sh sync runs, through the same guarded path.
W="$(mk_repo pull)"
S="$TMP/pull.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
git -C "$W" config core.fsmonitor "sh -c 'echo fsmonitor >> $M'"
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/newer" && ! -e "$M" ]]; then pass "pull fast-forwards, and runs nothing the .git holds"
else fail "pull (rc=$RC; newer: $([[ -f "$W/newer" ]] && echo yes || echo no); ran: $(cat "$M" 2>/dev/null); out: $OUT)"; fi
rm -f "$M"

# REPO-9: a branch other than the checked-out one keeps tracking its namesake on
# origin; only the checked-out one was re-tracked.
W="$(mk_repo track)"
g "$W" checkout -q -b shared origin/shared >/dev/null 2>&1; g "$W" checkout -q main >/dev/null 2>&1
S="$TMP/track.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && "$(git -C "$W" config branch.shared.merge)" == refs/heads/shared \
      && "$(git -C "$W" config branch.shared.remote)" == origin ]]; then
  pass "pull keeps every branch's upstream on origin, not only the checked-out one's"
else
  fail "pull dropped another branch's upstream (rc=$RC; shared.merge: $(git -C "$W" config branch.shared.merge))"
fi

# …but not a branch that diverged from its namesake (merged elsewhere, then the
# remote's force-pushed): tracking it would report "diverged".
W="$(mk_repo trackdiv)"
S="$TMP/trackdiv.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
g "$W" fetch -q origin >/dev/null 2>&1; g "$W" branch -f shared origin/main >/dev/null 2>&1
g "$W" config --unset branch.shared.merge >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && -z "$(git -C "$W" config branch.shared.merge)" ]]; then
  pass "pull gives no upstream to a branch that is not behind its namesake on origin"
else
  fail "pull tracked a diverged branch (rc=$RC; shared.merge: $(git -C "$W" config branch.shared.merge); $OUT)"
fi

# REPO-6: a failure after the fast-forward, while the new .git is copied in,
# puts the checkout back rather than leaving it at the remote's tip under the
# old .git. A cp that fails on that one copy stands in for a full disk.
W="$(mk_repo undo)"
S="$TMP/undo.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
mkdir -p "$TMP/cp-bin"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */.git-install.*) exit 1 ;; esac; done\nexec %s "$@"\n' "$(command -v cp)" > "$TMP/cp-bin/cp"
chmod +x "$TMP/cp-bin/cp"
before="$(git -C "$W" rev-parse HEAD)"
PATH="$TMP/cp-bin:$PATH" run_script pull "$W"
if [[ "$RC" != 0 && ! -e "$W/newer" && -z "$(git -C "$W" status --porcelain)" \
      && "$(git -C "$W" rev-parse HEAD)" == "$before" && "$OUT" == *"put back as it was"* ]]; then
  pass "a pull that fails after the fast-forward puts the checkout back, and says so"
else
  fail "a failed pull left the checkout (rc=$RC; newer: $([[ -e "$W/newer" ]] && echo yes || echo no); status: $(git -C "$W" status --porcelain | head -2 | tr '\n' ' '); $OUT)"
fi

# Once the old .git is being removed it is not whole, and the fast-forward is not
# undone: the new .git, which matches the checkout, is kept and named, and the
# move it names gives a clean checkout (review of the REPO-6 fix).
W="$(mk_repo mvfail)"
S="$TMP/mvfail.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
mkdir -p "$TMP/mv-bin"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */.git-install.*/.git) exit 1 ;; esac; done\nexec %s "$@"\n' "$(command -v mv)" > "$TMP/mv-bin/mv"
chmod +x "$TMP/mv-bin/mv"
PATH="$TMP/mv-bin:$PATH" run_script pull "$W"
stage="$(sed -n 's/.*: mv \(.*\.git-install\.[^ ]*\/\.git\) .*/\1/p' <<<"$OUT" | head -1)"
if [[ "$RC" != 0 && "$OUT" != *"put back"* && -n "$stage" && -d "$stage" && -e "$W/newer" ]] \
   && mv "$stage" "$W/.git" && [[ -z "$(git -C "$W" status --porcelain)" ]]; then
  pass "a failed install keeps the new .git, names the move, and the move gives a clean checkout"
else
  fail "a failed install (rc=$RC; stage: ${stage:-none}; $OUT)"
fi
if [[ "$(id -u)" != 0 ]]; then
  W="$(mk_repo rmfail)"
  S="$TMP/rmfail.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
  mkdir -p "$W/.git/keep"; : > "$W/.git/keep/f"; chmod 555 "$W/.git/keep"
  run_script pull "$W"
  stage="$(sed -n 's/.*then: mv \(.*\.git-install\.[^ ]*\/\.git\) .*/\1/p' <<<"$OUT" | head -1)"
  chmod 755 "$W/.git/keep"
  if [[ "$RC" != 0 && "$OUT" != *"put back"* && -n "$stage" && -d "$stage" ]] \
     && rm -rf "$W/.git" && mv "$stage" "$W/.git" && [[ -z "$(git -C "$W" status --porcelain)" ]]; then
    pass "a partly removed old .git keeps the new one and names the way to finish"
  else
    fail "a partly removed old .git (rc=$RC; stage: ${stage:-none}; $OUT)"
  fi
else
  printf 'SKIP: the partly-removed .git case needs a non-root run\n'
fi

# ── The redesign's own promises ──────────────────────────────────────────────
# R1 of the review of f6368d6: a dangling symbolic ref for origin/main and a
# .lock that stops set-head made reset keep the agent's commit on main. Nothing
# in the volume's .git is read for that decision any more.
W="$(mk_repo dangle)"; commit_in "$W" evil.txt
g "$W" symbolic-ref refs/remotes/origin/main refs/heads/nonexistent
rm -f "$W/.git/refs/remotes/origin/HEAD"; : > "$W/.git/refs/remotes/origin/HEAD.lock"
tip_r="$(git -C "$TMP/dangle.git" rev-parse --short main)"
run_script inspect "$W"; grep -qx 'PRIMARY|main' <<<"$OUT" || fail "dangle: no PRIMARY (out: $(tr '\n' ' ' <<<"$OUT"))"
grep -qx 'BRANCH|main|1|current' <<<"$OUT" || fail "dangle: main's unpushed commit not counted (out: $(tr '\n' ' ' <<<"$OUT"))"
run_script reset "$W" main
if [[ "$OUT" == *"AT|$tip_r"* && ! -e "$W/evil.txt" && "$(git -C "$W" rev-parse --short HEAD)" == "$tip_r" ]]; then
  pass "planted refs and locks cannot keep reset off the remote's tip"
else
  fail "reset landed off the remote tip (out: $(tr '\n' ' ' <<<"$OUT"))"
fi
if [[ -z "$(git -C "$W" for-each-ref refs/remotes/origin/HEAD.lock 2>/dev/null)" && ! -e "$W/.git/refs/remotes/origin/HEAD.lock" ]]; then
  pass "… and after reset the .git is the fresh clone's, nothing the agent left"
else fail "agent's .git leftovers survived reset"; fi

# sync keeps what it can and refuses what it cannot: untracked files and pushed
# branches stay; an edit, an unpushed branch or a diverged branch refuses.
W="$(mk_repo keep)"; S="$TMP/keep.seed"
commit_in "$S" upstream-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'scratch\n' > "$W/untracked.txt"
g "$W" branch --track shared origin/shared >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/upstream-new" && -f "$W/untracked.txt" ]] && g "$W" show-ref --verify --quiet refs/heads/shared; then
  pass "pull fast-forwards, keeping untracked files and branches already on the remote"
else fail "pull lost something (rc=$RC; out: $OUT)"; fi
# Keeping `shared` and passing no owner are both quiet: a WARN here means a
# branch it kept, or a chown it was never asked for, was reported as a failure.
if ! grep -q '^WARN|' <<<"$OUT"; then pass "… and a clean pull warns about nothing"
else fail "a clean pull printed a WARN (out: $OUT)"; fi
# With an owner, as repo.sh passes one: chowning to yourself works unprivileged.
W="$(mk_repo pullowned)"; S="$TMP/pullowned.seed"
commit_in "$S" po-new; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W" "$(id -u):$(id -g)"
if [[ "$RC" == 0 && -f "$W/po-new" ]] && ! grep -q '^WARN|' <<<"$OUT"; then
  pass "pull applies a valid owner without complaint"
else fail "pull with a valid owner (rc=$RC; out: $OUT)"; fi
# Chowning to yourself changes nothing on disk, so whether pull ran chown at all
# is read from a chown on PATH that records its arguments and then runs the real
# one: called with the owner when given one, never without.
mkdir -p "$TMP/chown-bin"; real_chown="$(command -v chown)"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/chown.log" "$real_chown" > "$TMP/chown-bin/chown"
chmod +x "$TMP/chown-bin/chown"
for given in yes no; do
  W="$(mk_repo "pullchown-$given")"; S="$TMP/pullchown-$given.seed"
  commit_in "$S" pc-new; g "$S" push -q origin main >/dev/null 2>&1
  : > "$TMP/chown.log"
  if [[ "$given" == yes ]]; then PATH="$TMP/chown-bin:$PATH" run_script pull "$W" "$(id -u):$(id -g)"
  else PATH="$TMP/chown-bin:$PATH" run_script pull "$W"; fi
  calls="$(cat "$TMP/chown.log")"
  if [[ "$given" == yes ]]; then want="-R $(id -u):$(id -g) $W" what="pull chowns the checkout to the owner it is given"
  else want="" what="pull runs no chown when given no owner"; fi
  if [[ "$RC" == 0 && "$calls" == "$want" ]]; then pass "$what"
  else fail "pull's chown calls with owner given=$given (rc=$RC; calls: '$calls'; want: '$want'; out: $OUT)"; fi
done
# The tip of the checked-out branch must be readable: a ref file holding no
# object id is refused by name, before anything is cloned.
W="$(mk_repo badtip)"; printf 'garbage\n' > "$W/.git/refs/heads/main"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"cannot read the tip of main"* ]]; then pass "pull refuses a checked-out branch whose tip it cannot read"
else fail "pull with an unreadable tip (rc=$RC; out: $OUT)"; fi
# A packed ref outside heads, tags and remotes is refused only when it holds an
# object id: a line that is not a ref, or names nothing, drops no commit.
W="$(mk_repo junkpacked)"; S="$TMP/junkpacked.seed"
commit_in "$S" jp-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'not-an-oid refs/wip/junk\n%s HEAD\n' "$(g "$W" rev-parse HEAD)" >> "$W/.git/packed-refs"
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/jp-new" ]]; then pass "pull ignores packed-refs lines that hold no ref"
else fail "pull refused on packed-refs lines that hold no ref (rc=$RC; out: $OUT)"; fi
W="$(mk_repo dirty)"; S="$TMP/dirty.seed"
commit_in "$S" newer2; g "$S" push -q origin main >/dev/null 2>&1
printf 'edited\n' > "$W/first"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"uncommitted changes"* && "$(cat "$W/first")" == edited ]]; then
  pass "pull refuses a checkout with uncommitted changes, and keeps them"
else fail "pull over uncommitted changes (rc=$RC; out: $OUT)"; fi
W="$(mk_repo unpushed)"
g "$W" checkout -q -b local-work >/dev/null 2>&1; commit_in "$W" lw; g "$W" checkout -q main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"local-work has commits on no remote"* ]] && g "$W" show-ref --verify --quiet refs/heads/local-work; then
  pass "pull refuses while a local branch holds unpushed work, and keeps it"
else fail "pull with an unpushed branch (rc=$RC; out: $OUT)"; fi
W="$(mk_repo diverged)"; S="$TMP/diverged.seed"
commit_in "$W" mine; commit_in "$S" theirs; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/mine" ]]; then pass "pull refuses a branch with commits of its own"
else fail "pull of a diverged branch (rc=$RC; out: $OUT)"; fi

# sync must lose nothing the old `git pull --ff-only` kept (review of d9b56a8, P1):
# an untracked file the remote now tracks, a stash, a tag on no remote, a linked
# worktree — each refuses, and is kept.
W="$(mk_repo collide)"; S="$TMP/collide.seed"
commit_in "$S" notes.txt; g "$S" push -q origin main >/dev/null 2>&1
printf 'mine\n' > "$W/notes.txt"
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/notes.txt")" == mine ]]; then pass "pull refuses to overwrite an untracked file the remote now tracks"
else fail "pull overwrote an untracked file (rc=$RC; notes: $(cat "$W/notes.txt"); out: $OUT)"; fi
W="$(mk_repo stash)"; S="$TMP/stash.seed"; commit_in "$S" s-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'wip\n' > "$W/first"; g "$W" stash -q
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *stash* ]] && g "$W" rev-parse -q --verify refs/stash >/dev/null; then pass "pull refuses while a stash would be lost"
else fail "pull with a stash (rc=$RC; out: $OUT)"; fi
# A stash is any one of its three traces: the ref without its reflog, or the ref
# packed with no loose file and no reflog.
for shape in noreflog packed; do
  W="$(mk_repo "stash-$shape")"; S="$TMP/stash-$shape.seed"; commit_in "$S" s-new; g "$S" push -q origin main >/dev/null 2>&1
  printf 'wip\n' > "$W/first"; g "$W" stash -q
  if [[ "$shape" == packed ]]; then
    g "$W" pack-refs --all
    [[ ! -e "$W/.git/refs/stash" ]] || fail "SCAFFOLD: pack-refs --all left refs/stash loose; the packed case tests nothing"
  fi
  rm -f "$W/.git/logs/refs/stash"
  run_script pull "$W"
  # By its own message: other_ref() refuses refs/stash too, as a ref outside
  # heads and tags, so "*stash*" alone passes without this check.
  if [[ "$RC" != 0 && "$OUT" == *"the repository has a stash"* ]]; then pass "pull refuses a stash ($shape)"
  else fail "pull with a stash ($shape; rc=$RC; out: $OUT)"; fi
done
W="$(mk_repo ltag)"; S="$TMP/ltag.seed"; commit_in "$S" t-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" tag -a -m mine v-local; commit_in "$W" only-local; g "$W" tag lone; g "$W" reset -q --hard HEAD~1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *tag* ]] && g "$W" rev-parse -q --verify refs/tags/lone >/dev/null; then pass "pull refuses while a tag on no remote would be lost"
else fail "pull with a local tag (rc=$RC; out: $OUT)"; fi
W="$(mk_repo wt)"; S="$TMP/wt.seed"; commit_in "$S" w-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" worktree add -q "$TMP/wt-linked" shared >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *worktree* ]]; then pass "pull refuses while a linked worktree would be cut off"
else fail "pull with a linked worktree (rc=$RC; out: $OUT)"; fi
# A failed install never leaves the volume without a .git (P4); a ref file with
# no newline and no end is read only so far (P6).
W="$(mk_repo hugeref)"; head -c 5000000 /dev/zero | tr '\0' a > "$W/.git/refs/heads/huge"
run_script inspect "$W"
if [[ "$RC" == 0 ]] && grep -qx 'BRANCH|huge|?|' <<<"$OUT"; then pass "a ref file that is not a ref is read only as far as needed, and counted unknown"
else fail "huge ref file (rc=$RC; out: $(head -c 300 <<<"$OUT"))"; fi
# The volume's own alternates are not followed for the counts (P3).
W="$(mk_repo altout)"; mkdir -p "$TMP/elsewhere"; git init -q "$TMP/elsewhere"; commit_in "$TMP/elsewhere" far
oid_far="$(g "$TMP/elsewhere" rev-parse HEAD)"
printf '%s\n' "$TMP/elsewhere/.git/objects" > "$W/.git/objects/info/alternates"
printf '%s\n' "$oid_far" > "$W/.git/refs/heads/elsewhere"
run_script inspect "$W"
if grep -qx 'BRANCH|elsewhere|?|' <<<"$OUT"; then pass "inspect does not follow the volume's own alternates out of it"
else fail "volume alternates followed (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# Tags live only in .git, which sync replaces: each local tag comes back at the
# value it had — one on a pushed commit, one re-pointed with tag -f — as
# `git pull --ff-only` would have left them (review of fb1705e, Q1).
W="$(mk_repo keeptag)"; S="$TMP/keeptag.seed"; commit_in "$S" kt-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" tag mylabel HEAD
run_script pull "$W"
if [[ "$RC" == 0 && "$(g "$W" rev-parse -q --verify refs/tags/mylabel 2>/dev/null)" == "$(g "$W" rev-parse HEAD~1)" ]]; then
  pass "a local tag on a pushed commit survives sync, at its own commit"
else fail "local tag lost by sync (rc=$RC; tags: $(g "$W" tag -l | tr '\n' ' '); out: $OUT)"; fi
if ! grep -q '^WARN|' <<<"$OUT"; then pass "… and keeping it warns about nothing"
else fail "keeping a tag printed a WARN (out: $OUT)"; fi
# Messages on stderr carry names from the volume too (Q2).
W="$(mk_repo escerr)"; printf 'ref: refs/heads/z\e]0;pwned\a\n' > "$W/.git/HEAD"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" != *$'\e'* && "$OUT" != *$'\a'* ]]; then pass "a name in an error message is shown as ?, not raw"
else fail "raw control characters in an error (out: $(cat -v <<<"$OUT"))"; fi
# A git directory the agent puts anywhere in the worktree (where the remote has
# a submodule, say) is read by git during checkout (Q3), and a .git FILE
# redirects git (gitdir:) to a directory the agent chose (security review of
# 8f5e5b9). sync refuses either; reset, which deletes them anyway, removes them
# before any git runs, so neither is ever read (REPO-5): the link to /dev/zero
# is not followed, and what the gitdir: file names is left alone.
W="$(mk_repo subgit)"; mkdir -p "$W/sub/.git/refs/heads"; ln -s /dev/zero "$W/sub/.git/refs/heads/x"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"sub/.git"*"inside the checkout"* ]]; then pass "sync refuses a nested .git holding a link"
else fail "sync over a nested .git link (rc=$RC; out: $OUT)"; fi
run_script reset "$W" main
if [[ "$RC" == 0 && ! -e "$W/sub/.git" && -z "$(git -C "$W" status --porcelain)" ]]; then pass "reset removes a nested .git holding a link, and git never reads it"
else fail "reset over a nested .git link (rc=$RC; left: $([[ -e "$W/sub/.git" ]] && echo yes || echo no); out: $OUT)"; fi
W="$(mk_repo subgitfile)"; mkdir -p "$W/sub" "$TMP/elsewhere"; : > "$TMP/elsewhere/keep"; printf 'gitdir: %s\n' "$TMP/elsewhere" > "$W/sub/.git"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"sub/.git"*"inside the checkout"* ]]; then pass "sync refuses a nested .git file (gitdir: redirect)"
else fail "sync over a nested .git file (rc=$RC; out: $OUT)"; fi
run_script inspect "$W"
if [[ "$RC" == 0 ]] && grep -qx 'NESTED|sub/.git' <<<"$OUT" && ! grep -q '^NESTED-MORE|' <<<"$OUT"; then pass "inspect lists a nested .git for reset's confirmation"
else fail "inspect's NESTED record (rc=$RC; out: $OUT)"; fi
run_script reset "$W" main
if [[ "$RC" == 0 && ! -e "$W/sub/.git" && -e "$TMP/elsewhere/keep" ]]; then pass "reset removes a nested .git file and leaves what it names alone"
else fail "reset over a nested .git file (rc=$RC; elsewhere kept: $([[ -e "$TMP/elsewhere/keep" ]] && echo yes || echo no); out: $OUT)"; fi
# Past 50 the listing stops and says how many more.
W="$(mk_repo manynested)"
for i in $(seq 1 52); do mkdir -p "$W/n$i/.git"; done
run_script inspect "$W"
if [[ "$RC" == 0 && "$(grep -c '^NESTED|' <<<"$OUT")" == 50 ]] && grep -qx 'NESTED-MORE|2' <<<"$OUT"; then pass "inspect lists 50 nested repositories and counts the rest"
else fail "inspect's listing past 50 ($(grep -c '^NESTED|' <<<"$OUT") listed; $(grep NESTED-MORE <<<"$OUT"))"; fi
# Removed BEFORE git uses the volume as a worktree, not left to `clean`: where the
# remote has a gitlink at sub, checkout reads sub/.git, and a gitdir: there to a
# repository whose config includes a FIFO outside the volume hung it (review of
# REPO-5). Run under a timeout: a hang is the failure.
W="$(mk_repo gitlink)"
S="$TMP/gitlink.seed"
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),sub" >/dev/null 2>&1
g "$S" commit -q -m gitlink >/dev/null 2>&1; g "$S" push -q origin main >/dev/null 2>&1
git init -q --bare "$TMP/evil.git"; mkfifo "$TMP/evil.fifo"
printf '[include]\n\tpath = %s\n' "$TMP/evil.fifo" >> "$TMP/evil.git/config"
mkdir -p "$W/sub"; printf 'gitdir: %s\n' "$TMP/evil.git" > "$W/sub/.git"
# Bounded on a regression: a git blocked opening the FIFO is released after 20 s
# by a writer (O_RDWR never blocks), reads nothing and goes on, so the test fails
# instead of hanging the suite. p_timeout alone is not enough: the orphaned git
# keeps the capture's pipe open.
( sleep 20; exec 3<>"$TMP/evil.fifo"; sleep 1 ) &
fifo_writer=$!
t5=$SECONDS
OUT="$(AI_REPO_URL="$TMP/gitlink.git" p_timeout 60 "$SCRIPT" reset "$W" main 2>&1)"; RC=$?
t5=$((SECONDS - t5))
kill "$fifo_writer" 2>/dev/null; wait "$fifo_writer" 2>/dev/null
if [[ "$RC" == 0 && ! -e "$W/sub/.git" && "$t5" -lt 15 ]] && grep -qx 'REMOVED|sub/.git' <<<"$OUT"; then
  pass "reset removes a nested .git before checkout reads it, and names it"
else
  fail "reset read a nested .git, or did not remove it (rc=$RC; ${t5}s; $OUT)"
fi
# find follows no link: a linked directory holding a .git outside the volume is
# neither listed nor removed.
W="$(mk_repo linkparent)"; mkdir -p "$TMP/outside/.git"; : > "$TMP/outside/.git/precious"
ln -s "$TMP/outside" "$W/lnk"
run_script inspect "$W"
nested_listed="$(grep -c '^NESTED|' <<<"$OUT")"
run_script reset "$W" main
if [[ "$nested_listed" == 0 && "$RC" == 0 && -e "$TMP/outside/.git/precious" ]]; then
  pass "a .git reached through a linked directory is neither listed nor removed"
else
  fail "a .git through a linked directory (listed: $nested_listed; rc=$RC; kept: $([[ -e "$TMP/outside/.git/precious" ]] && echo yes || echo no))"
fi
# A reset that cannot go ahead removes nothing: the nested repo survives an
# unreachable remote.
W="$(mk_repo nestnoremote)"; mkdir -p "$W/vendor/lib/.git"; : > "$W/vendor/lib/.git/keep"
AI_REPO_URL="$TMP/does-not-exist.git" run_script reset "$W" main
if [[ "$RC" != 0 && -e "$W/vendor/lib/.git/keep" ]]; then pass "a reset that cannot clone the remote removes no nested repository"
else fail "a failed reset removed a nested repository (rc=$RC)"; fi
# REPO-17: the volume's own path is matched literally. find -path takes a glob,
# so in a directory named gl[o]b* the top-level .git was not pruned: inspect
# listed it as nested and reset removed it. sync too: other_ref, unquoted, took
# refs/heads/main for a ref outside heads and tags and refused.
W="$(mk_repo 'pull gl[o]b*')"; S="$TMP/pull gl[o]b*.seed"; commit_in "$S" pg-new; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
[[ "$RC" == 0 && -e "$W/pg-new" ]] && pass "pull in a volume path holding glob characters" \
  || fail "pull in a volume path holding glob characters (rc=$RC; out: $OUT)"
run_script inspect "$W/"
[[ "$RC" != 0 && "$OUT" == *"must not end in a slash"* ]] && pass "a volume path ending in a slash is refused" \
  || fail "a volume path ending in a slash (rc=$RC; out: $OUT)"
W="$(mk_repo 'gl[o]b*')"
run_script inspect "$W"
nested_listed="$(grep -c '^NESTED' <<<"$OUT")"
run_script reset "$W" main
if [[ "$nested_listed" == 0 && "$RC" == 0 ]] && ! grep -q '^REMOVED|' <<<"$OUT" && [[ "$(g "$W" branch --show-current 2>/dev/null)" == main ]]; then
  pass "a volume path holding glob characters keeps its own .git"
else
  fail "a volume path holding glob characters (listed: $nested_listed; rc=$RC; $OUT)"
fi
# A nested .git that is a link is removed as a link: its target survives.
W="$(mk_repo sublink)"; mkdir -p "$W/sub" "$TMP/linktarget/.git"; : > "$TMP/linktarget/.git/HEAD"
ln -s "$TMP/linktarget/.git" "$W/sub/.git"
run_script reset "$W" main
if [[ "$RC" == 0 && ! -e "$W/sub/.git" && ! -L "$W/sub/.git" && -e "$TMP/linktarget/.git/HEAD" ]]; then pass "a nested .git that is a link is removed as a link, its target kept"
else fail "reset over a nested .git link (rc=$RC; target kept: $([[ -e "$TMP/linktarget/.git/HEAD" ]] && echo yes || echo no); out: $OUT)"; fi
W="$(mk_repo subgitdir)"; git init -q "$W/sub"; printf '%s\n' "$TMP/elsewhere" > "$W/sub/.git/commondir"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"sub/.git"*"inside the checkout"* ]]; then pass "a nested git directory (commondir) is refused"
else fail "nested git directory accepted (rc=$RC; out: $OUT)"; fi
grep -q -- 'diff-files --ignore-submodules=all' "$SCRIPT" \
  && pass "diff-files never opens a submodule's repository" || fail "diff-files without --ignore-submodules=all"
# Staged changes live in the volume's index only: a change staged and then
# undone in the file (status MM) looks clean to a fresh index, and sync replaced
# the index with it (review of 82698a0, F1).
W="$(mk_repo staged)"; S="$TMP/staged.seed"; commit_in "$S" st-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'staged\n' > "$W/first"; g "$W" add first; printf 'first\n' > "$W/first"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"staged changes"* && "$(g "$W" diff --cached --name-only)" == first ]]; then pass "pull refuses staged changes the worktree no longer shows"
else fail "staged change lost or accepted (rc=$RC; out: $OUT)"; fi
# REPO-10: diff-index trusts an index's cache-tree, so a hand-crafted index can
# hide a staged entry: d/f's object name is rewritten in the file itself, past
# git, which would have invalidated d/'s cached tree, and the trailing checksum
# recomputed. The check now reads the entries into a fresh index.
W="$(mk_repo cachetree)"; S="$TMP/cachetree.seed"
mkdir -p "$S/d"; printf 'one\n' > "$S/d/f"; g "$S" add d/f; g "$S" commit -q -m d; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1
commit_in "$S" ct-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" update-index --index-version 2; g "$W" write-tree >/dev/null      # d/f first, every cached tree valid
two="$(printf 'two\n' | g "$W" hash-object -w --stdin)"
idx="$W/.git/index"
[[ "$(g "$W" ls-files | head -n 1)" == d/f ]] || fail "cache-tree fixture: d/f is not the first entry"
# Entry 1's object name sits after the 12-byte header and 40 bytes of stat data.
printf "$(sed 's/../\\x&/g' <<<"$two")" | dd of="$idx" bs=1 seek=52 conv=notrunc 2>/dev/null
n=$(( $(wc -c < "$idx") - 20 )); head -c "$n" "$idx" > "$TMP/ct.body"
printf "$(p_sha1 "$TMP/ct.body" | sed 's/../\\x&/g')" | dd of="$idx" bs=1 seek="$n" conv=notrunc 2>/dev/null
if [[ "$(g "$W" ls-files -s d/f | cut -d' ' -f2)" != "$two" ]] || ! g "$W" diff-index --cached --quiet HEAD; then
  fail "cache-tree fixture: the hand-written index is not the one this test needs ($(g "$W" ls-files -s d/f))"
fi
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"staged changes"* ]]; then pass "pull refuses a staged entry its index's cache-tree hides"
else fail "a staged entry hidden by the cache-tree went unseen (rc=$RC; out: $OUT)"; fi
# Intent to add (`git add -N`) stages nothing that sync would lose: accepted,
# and the file kept. An unmerged entry is refused by name.
W="$(mk_repo ita)"; S="$TMP/ita.seed"; commit_in "$S" ita-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'draft\n' > "$W/draft.txt"; g "$W" add -N draft.txt
run_script pull "$W"
if [[ "$RC" == 0 && "$(cat "$W/draft.txt")" == draft && -e "$W/ita-new" ]]; then pass "pull accepts an intent-to-add entry, keeping the file"
else fail "pull and an intent-to-add entry (rc=$RC; out: $OUT)"; fi
W="$(mk_repo unmerged)"; S="$TMP/unmerged.seed"; commit_in "$S" um-new; g "$S" push -q origin main >/dev/null 2>&1
oid="$(g "$W" rev-parse HEAD:first)"
printf '100644 %s 1\tfirst\n100644 %s 2\tfirst\n100644 %s 3\tfirst\n' "$oid" "$oid" "$oid" | g "$W" update-index --index-info
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"unmerged entries"* ]]; then pass "pull refuses unmerged index entries, by name"
else fail "pull and unmerged entries (rc=$RC; out: $OUT)"; fi
# Only an ADDED empty blob is an intent to add: a tracked file staged as empty
# is a staged change like any other.
W="$(mk_repo stagedempty)"; S="$TMP/stagedempty.seed"; commit_in "$S" se-new; g "$S" push -q origin main >/dev/null 2>&1
: > "$W/first"; g "$W" add first; printf 'first\n' > "$W/first"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"staged changes"* ]]; then pass "pull refuses a tracked file staged as empty"
else fail "a tracked file staged as empty went unseen (rc=$RC; out: $OUT)"; fi
# An index git cannot read at all is refused, not taken as clean.
W="$(mk_repo badindex)"; S="$TMP/badindex.seed"; commit_in "$S" bi-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'DIRC garbage\n' > "$W/.git/index"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"cannot read the checkout's index"* ]]; then pass "pull refuses an index it cannot read"
else fail "pull and a damaged index (rc=$RC; out: $OUT)"; fi
# An ignored file the remote now tracks was overwritten in silence, as
# `git pull --ff-only` does; sync keeps it (REPO-10).
W="$(mk_repo ignored)"; S="$TMP/ignored.seed"
printf 'build/\n' > "$S/.gitignore"; g "$S" add .gitignore; g "$S" commit -q -m ignore; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1
mkdir -p "$S/build"; printf "remote's\n" > "$S/build/out"; g "$S" add -f build/out; g "$S" commit -q -m out; g "$S" push -q origin main >/dev/null 2>&1
mkdir -p "$W/build"; printf 'mine\n' > "$W/build/out"
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/build/out")" == mine && "$OUT" == *"untracked or ignored"* ]]; then pass "pull refuses to overwrite an ignored file the remote now tracks"
else fail "pull and an ignored file the remote now tracks (rc=$RC; content: $(cat "$W/build/out"); out: $OUT)"; fi
# What the remote turns from a directory into something else: clean, it is no
# obstacle (the review of REPO-10 found these refused, where `git pull` takes
# them); holding an ignored file, it is refused and the file kept.
for kind in file link gitlink; do
  W="$(mk_repo "dirto$kind")"; S="$TMP/dirto$kind.seed"
  mkdir -p "$S/foo"; printf 'a\n' > "$S/foo/a"; g "$S" add foo; g "$S" commit -q -m foo; g "$S" push -q origin main >/dev/null 2>&1
  g "$W" pull -q --ff-only >/dev/null 2>&1
  g "$S" rm -q -r foo
  case "$kind" in
    file)    printf 'now a file\n' > "$S/foo"; g "$S" add foo ;;
    link)    ln -s first "$S/foo"; g "$S" add foo ;;
    gitlink) g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),foo" ;;
  esac
  g "$S" commit -q -m "foo becomes a $kind"; g "$S" push -q origin main >/dev/null 2>&1
  run_script pull "$W"
  [[ "$RC" == 0 ]] && pass "pull fast-forwards a directory the remote turns into a $kind" \
    || fail "pull refused a directory turned into a $kind (rc=$RC; out: $OUT)"
done
W="$(mk_repo dirtofileign)"; S="$TMP/dirtofileign.seed"
mkdir -p "$S/foo"; printf 'a\n' > "$S/foo/a"; printf 'out.o\n' > "$S/.gitignore"; g "$S" add -A; g "$S" commit -q -m foo; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; printf 'built\n' > "$W/foo/out.o"
g "$S" rm -q -r foo; printf 'now a file\n' > "$S/foo"; g "$S" add foo; g "$S" commit -q -m file; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/foo/out.o" 2>/dev/null)" == built && "$OUT" == *"holds untracked or ignored files"* ]]; then
  pass "pull refuses a directory the remote turns into a file while it holds an ignored file, and keeps it"
else fail "pull and an ignored file in a directory turned into a file (rc=$RC; out: $OUT)"; fi
# A rename over a tracked compatibility link: the tip has doc/ and docs -> doc;
# the remote removes the link and moves doc to docs.
W="$(mk_repo compatlink)"; S="$TMP/compatlink.seed"
mkdir -p "$S/doc"; printf 'g\n' > "$S/doc/guide.md"; ln -s doc "$S/docs"; g "$S" add -A; g "$S" commit -q -m doc; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1
g "$S" rm -q docs; g "$S" mv doc docs; g "$S" commit -q -m rename; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/docs/guide.md" && ! -L "$W/docs" ]]; then pass "pull fast-forwards a rename over a tracked link"
else fail "pull and a rename over a tracked link (rc=$RC; out: $OUT)"; fi
# A submodule UNDER a directory the remote turns into a link: ls-files -o never
# lists a submodule's directory, and read-tree deleted it with the directory
# above, files and all (second review of REPO-10, M-1).
W="$(mk_repo subunder)"; S="$TMP/subunder.seed"
mkdir -p "$S/tp"; printf 'r\n' > "$S/tp/README"; g "$S" add tp
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),tp/libfoo"; g "$S" commit -q -m tp; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/tp/libfoo"; printf 'patched\n' > "$W/tp/libfoo/foo.c"
g "$S" rm -q -r --cached tp; rm -rf "$S/tp"; ln -s first "$S/tp"; g "$S" add tp; g "$S" commit -q -m link; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/tp/libfoo/foo.c" 2>/dev/null)" == patched && "$OUT" == *"submodule's directory holding files"* ]]; then
  pass "pull refuses a directory turned into a link while a submodule's directory under it holds files, and keeps them"
else fail "pull and a submodule's files under a directory turned into a link (rc=$RC; out: $OUT)"; fi
# The same where the submodule's files are all there is to lose, under a
# directory named like pathspec magic: the submodules under it are listed with
# literal pathspecs too, or `:x/` matched none and they went (third review).
W="$(mk_repo oddsub)"; S="$TMP/oddsub.seed"
mkdir -p "$S/:x"; printf 'r\n' > "$S/:x/README"; g "$S" add ./:x
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),:x/libfoo"; g "$S" commit -q -m odd; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/:x/libfoo"; printf 'patched\n' > "$W/:x/libfoo/foo.c"
g "$S" rm -q -r --cached ./:x; rm -rf "$S/:x"; printf 'now a file\n' > "$S/:x"; g "$S" add ./:x; g "$S" commit -q -m file; g "$S" push -q origin main >/dev/null 2>&1
[[ -f "$S/:x" ]] || fail "oddsub fixture: the remote's :x is not a file"
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/:x/libfoo/foo.c" 2>/dev/null)" == patched ]]; then
  pass "pull refuses the same under a directory named like pathspec magic (:x)"
else fail "pull and a submodule's files under :x (rc=$RC; out: $OUT)"; fi
# A submodule's directory under a retyped directory that holds only directories
# is no obstacle.
W="$(mk_repo subunderdirs)"; S="$TMP/subunderdirs.seed"
mkdir -p "$S/tp"; printf 'r\n' > "$S/tp/README"; g "$S" add tp
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),tp/libfoo"; g "$S" commit -q -m tp; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/tp/libfoo/build/out"
g "$S" rm -q -r --cached tp; rm -rf "$S/tp"; ln -s first "$S/tp"; g "$S" add tp; g "$S" commit -q -m link; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
[[ "$RC" == 0 && -L "$W/tp" ]] && pass "  … and fast-forwards when that directory holds only directories" \
  || fail "pull and a submodule directory of directories under a retyped directory (rc=$RC; out: $OUT)"
# A parent the tip tracks as a DIRECTORY, holding only a submodule, can be an
# ignored file in the checkout (diff-files ignores submodules); the remote's new
# file under it would replace it (third review).
W="$(mk_repo parenttree)"; S="$TMP/parenttree.seed"
printf 'c\n' > "$S/.gitignore"; g "$S" add .gitignore
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),c/sub"; g "$S" commit -q -m c; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; rm -rf "$W/c"; printf 'mine\n' > "$W/c"
mkdir -p "$S/c"; printf 'x\n' > "$S/c/x"; g "$S" add -f c/x; g "$S" commit -q -m cx; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/c" && "$(cat "$W/c")" == mine ]]; then pass "pull refuses an ignored file where the tip has a directory of only a submodule"
else fail "pull and an ignored file over a submodule-only directory (rc=$RC; out: $OUT)"; fi
# A directory the remote turns into a submodule keeps its untracked files, as
# git does, so it fast-forwards; an ignored LINK standing at that path instead
# is replaced, so it is refused (third review).
W="$(mk_repo dirtosub)"; S="$TMP/dirtosub.seed"
mkdir -p "$S/foo"; printf 'a\n' > "$S/foo/a"; g "$S" add foo; g "$S" commit -q -m foo; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; printf 'mine\n' > "$W/foo/untracked.txt"
g "$S" rm -q -r --cached foo; rm -rf "$S/foo"; g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),foo"
g "$S" commit -q -m submodule; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
[[ "$RC" == 0 && "$(cat "$W/foo/untracked.txt" 2>/dev/null)" == mine ]] \
  && pass "pull fast-forwards a directory turned into a submodule, keeping its untracked files" \
  || fail "pull and a directory turned into a submodule (rc=$RC; out: $OUT)"
W="$(mk_repo linktosub)"; S="$TMP/linktosub.seed"
printf 'p\n' > "$S/.gitignore"; g "$S" add .gitignore
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),p/inner"; g "$S" commit -q -m p; g "$S" push -q origin main >/dev/null 2>&1
# A link to nothing: read-tree refuses one that leads to a file by itself.
g "$W" pull -q --ff-only >/dev/null 2>&1; rm -rf "$W/p"; ln -s "precious target" "$W/p"
g "$S" rm -q -r --cached p; g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),p"; g "$S" commit -q -m sub; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -L "$W/p" && "$(readlink "$W/p")" == "precious target" ]]; then pass "  … and refuses an ignored link standing where that directory was"
else fail "pull and an ignored link turned over by a submodule (rc=$RC; out: $OUT)"; fi
# And an ignored file standing where the tip has an EMPTY tree (plumbing makes
# one) that the remote turns into a submodule.
W="$(mk_repo emptytosub)"; S="$TMP/emptytosub.seed"
printf '/p\n' > "$S/.gitignore"; g "$S" add .gitignore; g "$S" commit -q -m ignore
et="$(g "$S" hash-object -t tree -w /dev/null)"
c="$(g "$S" commit-tree "$( { g "$S" ls-tree HEAD; printf '040000 tree %s\tp\n' "$et"; } | g "$S" mktree)" -p HEAD -m emptytree)"
g "$S" reset -q --hard "$c"; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; printf 'precious notes\n' > "$W/p"
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),p"; g "$S" commit -q -m sub; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/p" && "$(cat "$W/p")" == "precious notes" ]]; then pass "  … and an ignored file standing where the tip has an empty tree"
else fail "pull and an ignored file over an empty tree turned into a submodule (rc=$RC; out: $OUT)"; fi
# Each git and find in the walk fails closed: one made to fail refuses, where
# its empty output read as "nothing in the way" (third review). A PATH shim
# fails the one call named in FAIL_ON.
mkdir -p "$TMP/walk-bin"
cat > "$TMP/walk-bin/git" <<SHIM
#!/bin/sh
case "\$*" in *"\$FAIL_ON"*) exit 1 ;; esac
exec $(command -v git) "\$@"
SHIM
cat > "$TMP/walk-bin/find" <<SHIM
#!/bin/sh
case "\$*" in *"\$FAIL_ON"*) exit 1 ;; esac
exec $(command -v find) "\$@"
SHIM
chmod +x "$TMP/walk-bin/git" "$TMP/walk-bin/find"
W="$(mk_repo walkfail)"; S="$TMP/walkfail.seed"
mkdir -p "$S/foo"; printf 'a\n' > "$S/foo/a"; g "$S" add foo
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),foo/sub"; g "$S" commit -q -m foo; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/foo/sub"
g "$S" rm -q -r --cached foo; rm -rf "$S/foo"; printf 'f\n' > "$S/foo"; g "$S" add foo; g "$S" commit -q -m file; g "$S" push -q origin main >/dev/null 2>&1
for f in "diff-tree -r -z --raw:cannot list what the remote changes" "ls-files -o:cannot list the untracked files" \
         "ls-tree -r -z:cannot list the submodules" "-mindepth 1 ! -type d:cannot search"; do
  FAIL_ON="${f%%:*}" PATH="$TMP/walk-bin:$PATH" run_script pull "$W"
  if [[ "$RC" != 0 && "$OUT" == *"${f#*:}"* ]]; then pass "the walk refuses when \`${f%%:*}\` fails"
  else fail "the walk with \`${f%%:*}\` failing (rc=$RC; out: $OUT)"; fi
done
run_script pull "$W"
[[ "$RC" == 0 ]] && pass "  … and that fixture fast-forwards with nothing failing" || fail "walkfail fixture (rc=$RC; out: $OUT)"
# An odd name through the same check, ignored file and all: the paths are
# literal pathspecs, so `:x` is a directory, not pathspec magic.
W="$(mk_repo oddname)"; S="$TMP/oddname.seed"
mkdir -p "$S/:x"; printf 'a\n' > "$S/:x/a"; printf 'out.o\n' > "$S/.gitignore"; g "$S" add -A; g "$S" commit -q -m odd; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; printf 'built\n' > "$W/:x/out.o"
# ./:x, not :x: a pathspec that starts with a colon is magic to the fixture's git too.
g "$S" rm -q -r ./:x; printf 'now a file\n' > "$S/:x"; g "$S" add ./:x; g "$S" commit -q -m file; g "$S" push -q origin main >/dev/null 2>&1
[[ -f "$S/:x" ]] || fail "oddname fixture: the remote's :x is not a file"
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/:x/out.o" 2>/dev/null)" == built && "$OUT" == *"holds untracked or ignored files"* ]]; then
  pass "pull refuses the same for a directory named like pathspec magic (:x)"
else fail "pull and an ignored file in a directory named :x (rc=$RC; out: $OUT)"; fi
# A tracked file the remote turns into a link is a clean replacement, and an
# empty untracked directory where the remote adds a file holds nothing to lose.
W="$(mk_repo filetolink)"; S="$TMP/filetolink.seed"
g "$S" rm -q first; ln -s shared-file "$S/first"; g "$S" add first; g "$S" commit -q -m link; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
[[ "$RC" == 0 && -L "$W/first" ]] && pass "pull fast-forwards a tracked file the remote turns into a link" \
  || fail "pull refused a tracked file turned into a link (rc=$RC; out: $OUT)"
W="$(mk_repo emptydir)"; S="$TMP/emptydir.seed"
mkdir -p "$W/added/inner"; commit_in "$S" added; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
[[ "$RC" == 0 && -f "$W/added" ]] && pass "pull fast-forwards over an empty untracked directory where the remote adds a file" \
  || fail "pull refused an empty directory in the way (rc=$RC; out: $OUT)"
# A submodule the remote turns into a file deleted the untracked files in its
# directory (review of REPO-10): refused, and kept; an empty one is no obstacle.
for has in files empty; do
  W="$(mk_repo "subtofile$has")"; S="$TMP/subtofile$has.seed"
  g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),sub"; g "$S" commit -q -m sub; g "$S" push -q origin main >/dev/null 2>&1
  g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/sub"
  [[ "$has" == empty ]] || printf 'precious\n' > "$W/sub/precious.c"
  g "$S" rm -q --cached sub; printf 'now a file\n' > "$S/sub"; g "$S" add sub; g "$S" commit -q -m file; g "$S" push -q origin main >/dev/null 2>&1
  run_script pull "$W"
  if [[ "$has" == files ]]; then
    if [[ "$RC" != 0 && "$(cat "$W/sub/precious.c" 2>/dev/null)" == precious && "$OUT" == *"submodule's directory holding files"* ]]; then
      pass "pull refuses a submodule the remote turns into a file while its directory holds files, and keeps them"
    else fail "pull and files in a submodule's directory (rc=$RC; out: $OUT)"; fi
  else
    [[ "$RC" == 0 && -f "$W/sub" ]] && pass "  … and fast-forwards it when the directory is empty" \
      || fail "pull and an empty submodule directory turned into a file (rc=$RC; out: $OUT)"
  fi
done
# The index bound, on a sparse file: nothing is written, and busybox's find
# (no M suffix) is what the seed image has, which case 640 runs this under.
W="$(mk_repo bigindex)"; S="$TMP/bigindex.seed"; commit_in "$S" bx-new; g "$S" push -q origin main >/dev/null 2>&1
rm -f "$W/.git/index"; dd if=/dev/zero of="$W/.git/index" bs=1048576 count=0 seek=600 2>/dev/null
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"larger than 512 MiB"* ]]; then pass "pull refuses an index larger than 512 MiB"
else fail "pull and a 600 MiB index (rc=$RC; out: $OUT)"; fi
# A NEW file staged with content is a staged change: only the empty blob is an
# intent to add.
W="$(mk_repo stagednew)"; S="$TMP/stagednew.seed"; commit_in "$S" sn-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'staged\n' > "$W/new.txt"; g "$W" add new.txt; printf 'changed\n' > "$W/new.txt"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"staged changes"* ]]; then pass "pull refuses a new file staged with content"
else fail "a new file staged with content went unseen (rc=$RC; out: $OUT)"; fi
# A parent of a path the remote adds: an ignored FILE there is in the way and
# refused, kept; an untracked DIRECTORY of other files is not, and stays.
W="$(mk_repo parentfile)"; S="$TMP/parentfile.seed"
printf 'x\n' > "$S/.gitignore"; g "$S" add .gitignore; g "$S" commit -q -m ignore; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1
printf 'my x\n' > "$W/x"
mkdir -p "$S/x"; printf 'y\n' > "$S/x/y"; printf '!x/\n' > "$S/.gitignore"; g "$S" add -A; g "$S" commit -q -m xy; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/x" && "$(cat "$W/x")" == "my x" && "$OUT" == *"where the remote now has a directory"* ]]; then
  pass "pull refuses an ignored file where the remote adds a directory, and keeps it"
else fail "pull and an ignored file where the remote adds a directory (rc=$RC; out: $OUT)"; fi
W="$(mk_repo parentdir)"; S="$TMP/parentdir.seed"
mkdir -p "$W/newdir"; printf 'mine\n' > "$W/newdir/other"
mkdir -p "$S/newdir"; printf 'a\n' > "$S/newdir/a"; g "$S" add newdir/a; g "$S" commit -q -m newdir; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && "$(cat "$W/newdir/other")" == mine && -f "$W/newdir/a" ]]; then
  pass "pull fast-forwards past an untracked directory the remote adds files to, keeping it"
else fail "pull and an untracked directory the remote adds files to (rc=$RC; out: $OUT)"; fi
# A submodule's path turned into a link was kept by sync, --ignore-submodules
# hiding it (REPO-10).
W="$(mk_repo gitlinkpath)"; S="$TMP/gitlinkpath.seed"
g "$S" update-index --add --cacheinfo "160000,$(g "$S" rev-parse HEAD),sub"; g "$S" commit -q -m gitlink; g "$S" push -q origin main >/dev/null 2>&1
g "$W" pull -q --ff-only >/dev/null 2>&1; mkdir -p "$W/sub"
commit_in "$S" gl-new; g "$S" push -q origin main >/dev/null 2>&1
rmdir "$W/sub"; ln -s "$TMP" "$W/sub"
run_script pull "$W"
if [[ "$RC" != 0 && -L "$W/sub" && "$OUT" == *"is a submodule"* ]]; then pass "pull refuses a submodule's path that is a link"
else fail "pull and a submodule's path that is a link (rc=$RC; out: $OUT)"; fi
rm -f "$W/sub"; printf 'a file\n' > "$W/sub"
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/sub" && "$OUT" == *"is a submodule"* ]]; then pass "  … and one that is a regular file"
else fail "pull and a submodule's path that is a file (rc=$RC; out: $OUT)"; fi
rm -f "$W/sub"; mkdir "$W/sub"
run_script pull "$W"
[[ "$RC" == 0 ]] && pass "  … and accepts it as the empty directory it should be" || fail "pull and an empty submodule directory (rc=$RC; out: $OUT)"
# A packed-refs line longer than the readers' 4200-byte cut is refused by sync,
# which keeps refs by name, not read as another ref's name; inspect and reset,
# where a cut name is only shown, still work (reset is the way out).
W="$(mk_repo longref)"; g "$W" pack-refs --all
printf '%s refs/heads/%s\n' "$(g "$W" rev-parse HEAD)" "$(head -c 4300 /dev/zero | tr '\0' a)" >> "$W/.git/packed-refs"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"longer than 4200 bytes"* ]]; then pass "a packed-refs line longer than 4200 bytes is refused"
else fail "a long packed-refs line (rc=$RC; out: $OUT)"; fi
run_script inspect "$W"; irc=$RC
run_script reset "$W" main
[[ "$irc" == 0 && "$RC" == 0 ]] && pass "  … while inspect and reset still work on it" || fail "inspect/reset and a long packed-refs line (inspect rc=$irc; reset rc=$RC; $OUT)"
# A commit held by a ref outside heads and tags (refs/wip/*, refs/original,
# a tool's keep refs) is dropped with .git: refused, loose or packed (F1).
for packed in "" packed; do
  W="$(mk_repo "wipref$packed")"
  commit_in "$W" wip; g "$W" update-ref refs/wip/save HEAD; g "$W" reset -q --hard HEAD~1
  [[ -z "$packed" ]] || g "$W" pack-refs --all
  run_script pull "$W"
  if [[ "$RC" != 0 && "$OUT" == *"refs/wip/save"* ]]; then pass "pull refuses a ref outside heads and tags${packed:+ (packed)}"
  else fail "custom ref dropped by pull${packed:+ (packed)} (rc=$RC; out: $OUT)"; fi
done
# REPO-2: an operation still in progress lives only in .git, which sync replaces:
# a stopped `git am` lost the patches only rebase-apply/ held. Refused, as
# `git pull --ff-only` would have kept them.
for st in rebase-apply rebase-merge sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_START; do
  W="$(mk_repo "inprog-$st")"
  case "$st" in rebase-*|sequencer) mkdir -p "$W/.git/$st"; : > "$W/.git/$st/x" ;; *) g "$W" rev-parse HEAD > "$W/.git/$st" ;; esac
  run_script pull "$W"
  if [[ "$RC" != 0 && "$OUT" == *"in progress"* ]]; then pass "pull refuses while $st says an operation is in progress"
  else fail "pull ignored $st (rc=$RC; out: $OUT)"; fi
done
# REPO-4: a reftable repository has a stub refs/heads FILE and no loose or packed
# refs, so every mode misread it — inspect named no branch at risk and reset then
# deleted them. Refused in every mode.
W="$(mk_repo reftable)"; rm -rf "$W/.git/refs/heads"; : > "$W/.git/refs/heads"; mkdir -p "$W/.git/reftable"
for mode in inspect pull; do
  run_script "$mode" "$W"
  if [[ "$RC" != 0 && "$OUT" == *"reftable"* ]]; then pass "$mode refuses a reftable repository"
  else fail "$mode misread a reftable repository (rc=$RC; out: $OUT)"; fi
done
run_script reset "$W" main
[[ "$RC" != 0 && "$OUT" == *"reftable"* ]] && pass "reset refuses a reftable repository" || fail "reset ran on a reftable repository (rc=$RC; out: $OUT)"
# A reftable/ directory is enough, whatever refs/heads is: here it is still the
# usual directory.
W="$(mk_repo reftable-dir)"; mkdir -p "$W/.git/reftable"
run_script inspect "$W"
[[ "$RC" != 0 && "$OUT" == *"reftable"* ]] && pass "a reftable/ directory beside a refs/heads directory is refused" \
  || fail "a reftable/ directory beside refs/heads was accepted (rc=$RC; out: $OUT)"

# REPO-3: a split index (core.splitIndex) is read with the sharedindex file it
# names, copied beside the copy: refusing it with "use reset" wiped far more
# than a sync. A staged change is found wherever it lies, in the shared part
# (staged, then split) or in the split index itself (split, then staged).
W="$(mk_repo splitidx)"; S="$TMP/splitidx.seed"; commit_in "$S" si-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" update-index --split-index
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/si-new" ]]; then pass "a split index is read, and the checkout fast-forwarded"
else fail "pull and a split index (rc=$RC; out: $OUT)"; fi
for order in staged-then-split split-then-staged; do
  W="$(mk_repo "si-$order")"; S="$TMP/si-$order.seed"; commit_in "$S" sx-new; g "$S" push -q origin main >/dev/null 2>&1
  [[ "$order" == split-then-staged ]] && g "$W" update-index --split-index
  printf 'staged\n' > "$W/first"; g "$W" add first; printf 'first\n' > "$W/first"
  [[ "$order" == staged-then-split ]] && g "$W" update-index --split-index
  run_script pull "$W"
  if [[ "$RC" != 0 && "$OUT" == *"staged changes"* && ! -e "$W/sx-new" ]]; then pass "a split index's staged change is found ($order)"
  else fail "a split index's staged change ($order; rc=$RC; out: $OUT)"; fi
done
# The shared part must be a regular file of that name, and the two parts are
# bounded together as the index alone was: missing, a directory, or 512 MiB
# beside the split index (a sparse file) is refused, a link as anything in .git
# that is neither file nor directory is, and one that is not an index, or whose
# trailing checksum is not the one named, is refused as damaged.
for how in missing dir link big other trailer; do
  W="$(mk_repo "si-$how")"; S="$TMP/si-$how.seed"; commit_in "$S" sy-new; g "$S" push -q origin main >/dev/null 2>&1
  g "$W" update-index --split-index; sf="$(ls "$W"/.git/sharedindex.* | head -n 1)"
  case "$how" in
    missing) rm -f "$sf" ;;
    dir) rm -f "$sf"; mkdir "$sf" ;;
    link) mv "$sf" "$TMP/si-$how.shared"; ln -s "$TMP/si-$how.shared" "$sf" ;;
    big) rm -f "$sf"; dd if=/dev/zero of="$sf" bs=1048576 count=0 seek=512 2>/dev/null ;;
    other) printf 'not an index\n' > "$sf" ;;
    # The trailer's last byte is the name's last two hex digits: write another.
    trailer) if [[ "${sf: -2}" == ff ]]; then printf '\376'; else printf '\377'; fi \
      | dd of="$sf" bs=1 seek="$(( $(wc -c < "$sf") - 1 ))" conv=notrunc 2>/dev/null ;;
  esac
  run_script pull "$W"
  case "$how" in
    missing|dir) want="is missing or not a file" ;; link) want="is not a regular file or directory" ;;
    big) want="larger than 512 MiB together" ;; other|trailer) want="split index (damaged)" ;;
  esac
  if [[ "$RC" != 0 && "$OUT" == *"$want"* && ! -e "$W/sy-new" ]]; then pass "a split index whose shared part is $how is refused"
  else fail "a split index whose shared part is $how (rc=$RC; out: $OUT)"; fi
done
# A SHA-256 repository names its shared part with 64 hex digits.
W="$(GIT_DEFAULT_HASH=sha256 mk_repo si-sha256)"; S="$TMP/si-sha256.seed"; commit_in "$S" s2-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" update-index --split-index
run_script pull "$W"
if [[ "$(g "$W" rev-parse --show-object-format 2>/dev/null)" == sha256 && "$RC" == 0 && -f "$W/s2-new" ]]; then
  pass "a SHA-256 repository's split index is read, and the checkout fast-forwarded"
else fail "pull and a SHA-256 split index (rc=$RC; out: $OUT)"; fi
# git's errors are bounded: it prints a line for each extension it ignores,
# about three times the index's size, and the first version read them whole. An
# 8 MiB index of them, ended by one git refuses, under a 150 MB address space:
# read whole, the helper ran out of memory; bounded, it needs a sixth of that
# (review of the REPO-3 fix). Small, as this file is the falsify tier's oracle.
W="$(mk_repo si-noisy)"; S="$TMP/si-noisy.seed"; commit_in "$S" sn2-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'ZZZZ\0\0\0\0' > "$TMP/ext"
for _ in $(seq 20); do cat "$TMP/ext" "$TMP/ext" > "$TMP/ext2"; mv "$TMP/ext2" "$TMP/ext"; done
{ printf 'DIRC\0\0\0\2\0\0\0\0'; cat "$TMP/ext"; printf 'zzzz\0\0\0\0%020d' 0; } > "$W/.git/index"; rm -f "$TMP/ext"
OUT="$(AI_REPO_URL="$W.git" bash -c 'ulimit -v 150000 2>/dev/null; exec "$@"' _ "$SCRIPT" pull "$W" 2>&1)"; RC=$?
if [[ "$RC" != 0 && "$OUT" == *"sparse or damaged"* ]]; then pass "pull refuses an 8 MiB index of ignored extensions within 150 MB, its errors bounded"
else fail "pull and an index of ignored extensions (rc=$RC; ${OUT:0:300})"; fi
# An index git cannot read that names no shared part is damaged, not split.
W="$(mk_repo si-none)"; S="$TMP/si-none.seed"; commit_in "$S" sz-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'DIRC but not an index\n' > "$W/.git/index"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"cannot read the checkout's index (sparse or damaged)"* ]]; then pass "a damaged index that is not split is refused as damaged"
else fail "a damaged index that is not split (rc=$RC; out: $OUT)"; fi

# The volume checks fail closed: a directory find cannot search hides what is
# inside it from them (review of 82698a0, F3).
if [[ "$(id -u)" != 0 ]]; then
  W="$(mk_repo locked)"; mkdir -p "$W/locked/sub"; chmod 000 "$W/locked"
  run_script inspect "$W"
  chmod 755 "$W/locked"
  if [[ "$RC" != 0 && "$OUT" == *"cannot check"* ]]; then pass "a directory the checks cannot search refuses the volume"
  else fail "unsearchable directory accepted (rc=$RC; out: $OUT)"; fi
fi
grep -qE -- '--memory[ =]' "$REPO_DIR/repo.sh" 2>/dev/null || grep -qE -- '--memory[ =]' "$(dirname "$SCRIPT")/repo.sh" \
  && pass "the seed containers that run git are given a memory limit" || fail "no --memory on the git helper's container"

# Branch names are read as file names, which git's rules do not bind: one holding
# terminal escapes reaches the confirmation only as ? (security review of d9b56a8).
W="$(mk_repo esc)"; cp "$W/.git/refs/heads/main" "$W/.git/refs/heads/x"$'\e]0;pwned\a'
run_script inspect "$W"
if [[ "$OUT" != *$'\e'* && "$OUT" != *$'\a'* ]] && grep -q '^BRANCH|x?]0;pwned?|' <<<"$OUT"; then
  pass "control characters in a branch file's name are shown as ?"
else fail "raw control characters in the records ($(cat -v <<<"$OUT" | tr '\n' ' '))"; fi
W="$(mk_repo c1)"; cp "$W/.git/refs/heads/main" "$W/.git/refs/heads/y"$'\xc2\x9b'"31m"
run_script inspect "$W"
if [[ "$OUT" != *$'\xc2\x9b'* && "$OUT" != *$'\x9b'* ]] && grep -q '^BRANCH|y??31m|' <<<"$OUT"; then
  pass "an 8-bit (C1) control sequence in a branch file's name is shown as ?"
else fail "C1 control in the records ($(cat -v <<<"$OUT" | tr '\n' ' '))"; fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-repo-git-reset.sh: all checks passed\n'; exit 0
fi
printf 'test-repo-git-reset.sh: %s check(s) failed\n' "$fails"
exit 1
