#!/usr/bin/env bash
# tests/test-git-internals-ro-index.sh — what a git directory's index, .git
# files and commondir lead to: submodules and linked worktrees outside the scan,
# followed and protected, every cut named.
#
# One of the tests/test-git-internals-ro-*.sh files, which share
# tests/lib-git-internals-ro.sh; the checks keep the G numbers sandbox.sh and
# the reviews cite. Hermetic: a fake docker capturing the run arguments, real
# git repositories. Integration case 465-git-internals-read-only checks that
# the container the agent gets actually refuses the writes, and still commits.
# shellcheck source=tests/lib-git-internals-ro.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-git-internals-ro.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-git-internals-ro.sh\n'; exit 1; }

gi_warm_up

# ── G22: a submodule whose .git is EMBEDDED, under vendor/, found via the index ─
# `git submodule add` of a repository already in place keeps its .git directory
# in the checkout; vendor/ is pruned by name, but the superproject's index
# records the gitlink, and its `git status` runs git in there.
mkdir -p "$PROJ/vendor/emb" && "${G[@]}" -C "$PROJ/vendor/emb" init -q && "${G[@]}" -C "$PROJ/vendor/emb" commit -q --allow-empty -m e
"${G[@]}" -C "$PROJ" -c protocol.file.allow=always submodule --quiet add ./vendor/emb vendor/emb 2>/dev/null
[[ -d "$PROJ/vendor/emb/.git" ]] || printf 'SCAFFOLD-NOTE: git absorbed the embedded .git; G22 then tests the absorbed path\n'
launch ..
{ has_mount "$PROJ/vendor/emb/.git/config:/workspace/proj/vendor/emb/.git/config:ro" \
  || has_mount "$PROJ/vendor/emb/.git:/workspace/proj/vendor/emb/.git:ro"; } \
  && pass "G22 a submodule under vendor/ with an embedded .git is found through the index and protected" \
  || fail "G22 embedded vendor/ submodule (git mounts: $(git_mounts | grep vendor | tr '\n' ' '))"
# The project's own index, the first a launch reads, is read: the read that makes
# the launcher's throwaway repository for an object format reads it too (GAP-2's
# whole-file run, batch 2, item 1). The ; keeps a line for a directory under
# .git/modules from matching.
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index of $PROJ/.git;" "$ERR" \
  && pass "G215 the first index a launch reads, the project's, is read" \
  || fail "G215 the project's index called unreadable (rc=$LAUNCH_RC; $(grep -F 'cannot read the index' "$ERR" | head -2 | tr '\n' ' '))"

# ── G28: reading the index runs no transport ──────────────────────────────────
# git_dirs_in reads each repository's index with the host's git. In a partial
# clone with a sparse index, ls-files expands the index, and a collapsed
# directory whose tree is missing is fetched from the promisor remote — running
# remote.<name>.uploadpack, which the agent can set. fsmonitor has nothing to do
# with it. The agent's repository must be read without running anything.
mkdir -p "$TMP/lz/evil/a" "$TMP/lz/evil/b"
printf 'a\n' > "$TMP/lz/evil/a/f"; printf 'b\n' > "$TMP/lz/evil/b/f"
"${G[@]}" -C "$TMP/lz/evil" init -q && "${G[@]}" -C "$TMP/lz/evil" add -A \
  && "${G[@]}" -C "$TMP/lz/evil" commit -qm init \
  && "${G[@]}" -C "$TMP/lz/evil" sparse-checkout init --cone --sparse-index \
  && "${G[@]}" -C "$TMP/lz/evil" sparse-checkout set a \
  || { printf 'SCAFFOLD-FAILED: cannot create the sparse repository\n'; exit 1; }
lz_tree="$("${G[@]}" -C "$TMP/lz/evil" rev-parse HEAD:b)"
rm -f "$TMP/lz/evil/.git/objects/${lz_tree:0:2}/${lz_tree:2}"
"${G[@]}" -C "$TMP/lz/evil" config core.repositoryformatversion 1
"${G[@]}" -C "$TMP/lz/evil" config extensions.partialClone origin
"${G[@]}" -C "$TMP/lz/evil" config remote.origin.promisor true
"${G[@]}" -C "$TMP/lz/evil" config remote.origin.url "file://$TMP/lz-nowhere"
"${G[@]}" -C "$TMP/lz/evil" config remote.origin.uploadpack "touch $TMP/lz-PWNED; false"
# A repository's own per-protocol setting beats a command-line protocol.allow.
"${G[@]}" -C "$TMP/lz/evil" config protocol.file.allow always
# Control: the same read without the launcher's guards does run it, so the
# fixture really is one where ls-files fetches (on a git that lazy-fetches).
( cd "$TMP/lz/evil" && git -c core.fsmonitor=false ls-files -s -z >/dev/null 2>&1 )
if [[ -e "$TMP/lz-PWNED" ]]; then
  rm -f "$TMP/lz-PWNED"
  EXTRA_MOUNTS="$TMP/lz" launch "$TMP/app"
  [[ ! -e "$TMP/lz-PWNED" ]] \
    && pass "G28 reading a partial clone's sparse index runs no uploadpack on the host" \
    || fail "G28 the launcher's ls-files ran the repository's remote.origin.uploadpack on the host"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$TMP/lz/evil/.git/config:/workspace/lz/evil/.git/config:ro" \
    && pass "G28 that repository is still protected" \
    || fail "G28 repository not protected (rc=$LAUNCH_RC; stderr: $(tr '\n' ' ' < "$ERR"))"
    grep -qF "WARNING: cannot read the index of $TMP/lz/evil/.git" "$ERR" \
    && pass "G28 the unreadable index is named: submodules under it are not followed" \
    || fail "G28 no WARNING for the unreadable index (stderr: $(tr '\n' ' ' < "$ERR"))"
else
  printf 'SKIP: G28 this git (%s) does not lazy-fetch while reading a sparse index\n' "$(git --version)"
fi
rm -rf "$TMP/lz" "$TMP/lz-PWNED"

# ── G33: the index warning names an agent-chosen path quoted ─────────────────
mkdir -p "$PROJ/x33"$'\e]0;pwned\a' && "${G[@]}" -C "$PROJ/x33"$'\e]0;pwned\a' init -q
printf 'garbage' > "$PROJ/x33"$'\e]0;pwned\a/.git/index'
launch ..
# Only this message: the rest of LNCH-3 (READ-ONLY: and friends) is still open.
idx33="$(grep 'cannot read the index of' "$ERR")"
[[ -n "$idx33" && "$idx33" != *$'\e'* ]] \
  && pass "G33 the unreadable-index WARNING quotes the path the agent chose" \
  || fail "G33 index WARNING (stderr: $(grep -A1 'index of' "$ERR" | cat -v | tr '\n' ' '))"
rm -rf "$PROJ/x33"$'\e]0;pwned\a'

# ── G36: a gitlink path from the index stays inside the mount ─────────────────
# The index is the agent's to write, and git reads a hand-made entry such as
# `../../victim` without complaint. Followed as is, it made the launcher pin and
# overlay a repository outside every mount — and write a commondir into it
# (re-review of c0d48d9). Built with index.skipHash, so the patched bytes need no
# new checksum; git before 2.40 rejects such an index as corrupt instead.
ver36="$(git --version | awk '{print $3}')"
if [[ "$(printf '%s\n2.40\n' "$ver36" | sort -V | head -1)" == 2.40 ]] && command -v perl >/dev/null 2>&1; then
  mkdir -p "$TMP/victim36" "$PROJ/dd36" && "${G[@]}" -C "$TMP/victim36" init -q && "${G[@]}" -C "$PROJ/dd36" init -q
  "${G[@]}" -C "$PROJ/dd36" -c index.skipHash=true update-index --add \
    --cacheinfo "160000,$(printf '%040d' 1),aa/bb/victim36"
  perl -0777 -pi -e 's{aa/bb/victim36}{../../victim36}' "$PROJ/dd36/.git/index"
  ls36="$(git -C "$PROJ/dd36" ls-files -s 2>/dev/null)"
  if [[ "$ls36" == *'../../victim36'* ]]; then
    launch ..
    ! grep -qF "$TMP/victim36" "$CAPTURE" && [[ ! -e "$TMP/victim36/.git/commondir" ]] \
      && pass "G36 a gitlink path with .. in it is not followed out of the mount" \
      || fail "G36 gitlink escaped the mount (mounts: $(grep -F victim36 "$CAPTURE" | tr '\n' ' '); commondir: $(ls "$TMP/victim36/.git/commondir" 2>&1))"
    # …and not in silence (GIT-3): a skipped gitlink is a checkout left unprotected.
    grep -qF "records a submodule at ../../victim36" "$ERR" \
      && pass "G36 … and the skipped gitlink is named" || fail "G36 skipped gitlink not named ($(grep -F victim36 "$ERR" | tr '\n' ' '))"
  else
    printf 'SKIP: G36 this git does not list the hand-made entry\n'
  fi
  rm -rf "$TMP/victim36" "$PROJ/dd36"
else
  printf 'SKIP: G36 needs git 2.40+ (index.skipHash) and perl; this is git %s\n' "$ver36"
fi

# ── G37: a split index's shared part cannot hang the read either ──────────────
mkdir -p "$PROJ/si37" && "${G[@]}" -C "$PROJ/si37" init -q && printf 'x\n' > "$PROJ/si37/f" \
  && "${G[@]}" -C "$PROJ/si37" add f && "${G[@]}" -C "$PROJ/si37" update-index --split-index
si37="$(ls "$PROJ/si37/.git"/sharedindex.* 2>/dev/null | head -1)"
if [[ -n "$si37" ]]; then
  rm -f "$si37" && mkfifo "$si37"
  launch_timed 60
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF "cannot read the index of $PROJ/si37/.git" "$ERR" \
    && pass "G37 a FIFO shared index does not hang the launch, and is named (${LAUNCH_S}s)" \
    || fail "G37 split index FIFO (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(grep -F si37 "$ERR" | tr '\n' ' '))"
  ( exec 3<>"$si37" ) 2>/dev/null
else
  fail "G37 SCAFFOLD: update-index --split-index made no sharedindex file"
fi
rm -rf "$PROJ/si37"

# ── G39: a git that dies mid-record is still named ────────────────────────────
# A git that crashes loses what it had buffered, and may stop in the middle of a
# record and print nothing on stderr (no error:/fatal: line). The failure marker
# must not be glued onto that cut-off record, or the read passes for complete.
mkdir -p "$TMP/cut/r" "$TMP/bin39"
"${G[@]}" -C "$TMP/cut/r" init -q && printf 'x\n' > "$TMP/cut/r/f" \
  && "${G[@]}" -C "$TMP/cut/r" add f && "${G[@]}" -C "$TMP/cut/r" commit -qm init \
  || { printf 'SCAFFOLD-FAILED: cannot create the G39 repository\n'; exit 1; }
real_git="$(command -v git)"
cat > "$TMP/bin39/git" <<EOF39
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == ls-files ]] && { printf '160000 %040d 0\tvendor/cu' 1; exit 139; }
done
exec "$real_git" "\$@"
EOF39
chmod +x "$TMP/bin39/git"
PATH="$TMP/bin39:$PATH" EXTRA_MOUNTS="$TMP/cut" launch "$TMP/app"
grep -qF "WARNING: cannot read the index of $TMP/cut/r/.git" "$ERR" \
  && pass "G39 an index read that died mid-record, with nothing on stderr, is named" \
  || fail "G39 a cut-off read passed for complete (rc=$LAUNCH_RC; stderr: $(tr '\n' ' ' < "$ERR"))"
rm -rf "$TMP/cut" "$TMP/bin39"

# ── G43: a gitlink whose checkout is not where the index says is named ───────
# Skipped, rightly — a link on the way could send the protection elsewhere — but
# it used to be skipped in silence, so a real checkout reached through a link (or
# a case or NFC/NFD difference on macOS) got no protection and no word (GIT-3).
mkdir -p "$PROJ/l43/real" && "${G[@]}" -C "$PROJ/l43" init -q
"${G[@]}" -C "$PROJ/l43" update-index --add --cacheinfo "160000,$(printf '%040d' 1),sub"
ln -s real "$PROJ/l43/sub"
launch ..
grep -qF "submodule $PROJ/l43/sub of $PROJ/l43/.git is not where its index says" "$ERR" \
  && pass "G43 a gitlink reached through a link is skipped and named" \
  || fail "G43 gitlink through a link skipped silently ($(grep -F l43 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/l43"

# ── G44: an index read that hangs is bounded ────────────────────────────────
# The FIFO checks are check-then-use: a concurrent container can swap the index
# or a sharedindex file for a FIFO after them, and ls-files then blocked the
# launch for ever (GIT-4). The read runs under timeout(1) where there is one;
# macOS has none, so there it stays unbounded.
if command -v timeout >/dev/null 2>&1; then
  mkdir -p "$TMP/hang/r" "$TMP/bin44"
  "${G[@]}" -C "$TMP/hang/r" init -q && printf 'x\n' > "$TMP/hang/r/f" && "${G[@]}" -C "$TMP/hang/r" add f \
    || { printf 'SCAFFOLD-FAILED: cannot create the G44 repository\n'; exit 1; }
  real_git="$(command -v git)"
  cat > "$TMP/bin44/git" <<EOF44
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == ls-files ]] && exec sleep 120; done
exec "$real_git" "\$@"
EOF44
  chmod +x "$TMP/bin44/git"
  t44=$SECONDS
  PATH="$TMP/bin44:$PATH" EXTRA_MOUNTS="$TMP/hang" launch "$TMP/app"
  t44=$((SECONDS - t44))
  (( t44 < 60 )) && grep -qF "WARNING: cannot read the index of $TMP/hang/r/.git" "$ERR" \
    && pass "G44 an index read that hangs is cut off and named (${t44}s)" \
    || fail "G44 a hanging index read held the launch ${t44}s (stderr: $(grep -F hang/r "$ERR" | head -1))"
  # On a Mac, timeout(1) is Homebrew's gtimeout; a launcher that probed only
  # timeout left the read unbounded there (GIT-16). A gtimeout on PATH is used.
  real_timeout="$(command -v timeout)"
  cat > "$TMP/bin44/gtimeout" <<EOF44
#!/usr/bin/env bash
: > "$TMP/bin44/gtimeout.used"
exec "$real_timeout" "\$@"
EOF44
  chmod +x "$TMP/bin44/gtimeout"
  t44=$SECONDS
  PATH="$TMP/bin44:$PATH" EXTRA_MOUNTS="$TMP/hang" launch "$TMP/app"
  t44=$((SECONDS - t44))
  [[ -e "$TMP/bin44/gtimeout.used" ]] && (( t44 < 60 )) \
    && pass "G44 a gtimeout on PATH bounds the read (${t44}s)" \
    || fail "G44 gtimeout was not used (${t44}s; used: $([[ -e "$TMP/bin44/gtimeout.used" ]] && echo yes || echo no))"
  rm -rf "$TMP/hang" "$TMP/bin44"
else
  printf 'SKIP: G44 needs timeout(1)\n'
fi

# ── G45: a commondir is read as git reads it ───────────────────────────────
# bash's `cd` reads `s/..` lexically, git physically: with s a link into
# A/.git/refs, git's common directory is A/.git while bash's was the worktree's
# own directory, which has no config — so config.worktree was skipped although
# git reads it, and its include was never named (review of batch 9, finding 3).
# git writes no such commondir, and the agent can swap what it steps through:
# it now refuses the launch, as any but ../.. in a worktree's directory does
# (bugs review GIT-64; G165).
A45="$PROJ/a45"; mkdir -p "$A45" && "${G[@]}" -C "$A45" init -q && printf 'x\n' > "$A45/f" \
  && "${G[@]}" -C "$A45" add f && "${G[@]}" -C "$A45" commit -qm init \
  && "${G[@]}" -C "$A45" config extensions.worktreeConfig true \
  || { printf 'SCAFFOLD-FAILED: cannot create the G45 repository\n'; exit 1; }
W45="$A45/.git/worktrees/w"; C45="$PROJ/c45"; mkdir -p "$W45" "$C45"
ln -s "$A45/.git/refs" "$W45/s"; printf 's/..\n' > "$W45/commondir"
printf 'ref: refs/heads/master\n' > "$W45/HEAD"; printf '%s/.git\n' "$C45" > "$W45/gitdir"
printf 'gitdir: %s\n' "$W45" > "$C45/.git"
"${G[@]}" config --file "$W45/config.worktree" include.path "$PROJ/evil45.gitconfig"
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $W45/commondir sends git to s/.. for" "$ERR" \
  && pass "G45 a commondir through a link and .. refuses the launch" \
  || fail "G45 commondir through a link (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|a45' "$ERR" | head -2 | tr '\n' ' '))"
# Read as git reads it: every trailing CR and LF stripped, not one each, so
# ../.. with two CRs is git's own, and its config.worktree is walked.
printf '../..\r\r\n' > "$W45/commondir"
launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "worktrees/w/config.worktree includes" "$ERR" \
  && pass "G45 … with every trailing CR and LF stripped, as git does" \
  || fail "G45 a commondir with two trailing CRs is misread (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|a45' "$ERR" | head -2 | tr '\n' ' '))"
# One that names nothing refuses the launch before anything is made there
# (it got a config.worktree placeholder; security review of 99db199).
printf '%s\n' "$PROJ/nonexistent45" > "$W45/commondir"; rm -f "$W45/config.worktree"
launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$W45/config.worktree" ]] && grep -qF "ERROR: $W45/commondir sends git to" "$ERR" \
  && pass "G45 a commondir naming nothing refuses the launch, and nothing is made" \
  || fail "G45 a commondir naming nothing (rc=$LAUNCH_RC; config.worktree $([[ -e "$W45/config.worktree" ]] && echo made || echo absent))"
rm -rf "$A45" "$C45"

# ── G46: a walk through links has one step budget ────────────────────────────
# The 128-component cap counted the include VALUE; each link on the way splices
# its target in (a ~2,000-component `./././…`), and up to 40 links: one entry
# took 14 s, and the budget allows 1,000 (review of batch 9, finding 2). The walk
# now stops after 256 steps however they arrive, and says the way was not
# followed to the end.
R46="$PROJ/r46"; mkdir -p "$R46" "$PROJ/l46" && "${G[@]}" -C "$R46" init -q
dots46="$(printf './%.0s' $(seq 1 2000))"
for n in $(seq 1 40); do ln -s "${dots46}L$((n + 1))" "$PROJ/l46/L$n"; done
for _ in 1 2 3; do "${G[@]}" config --file "$R46/.git/config" --add include.path ../../l46/L1; done
launch_timed 120
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt 20 ]] && grep -qF "/workspace/proj/r46/.git/config includes ../../l46/L1" "$ERR" \
  && pass "G46 a link chain on an include's way is cut short and named (${LAUNCH_S}s)" \
  || fail "G46 link chain (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(grep -iE 'includes|l46|not every' "$ERR" | head -4 | tr '\n' ' '))"
rm -rf "$R46" "$PROJ/l46"
# A chain OUTSIDE every mount, so no single step is the agent's to change, but 41
# links long: the walk gave up past 40 and printed nothing, which read as safe.
# A way not followed to the end is named.
R46b="$PROJ/r46b"; mkdir -p "$R46b" "$TMP/l46b" && "${G[@]}" -C "$R46b" init -q
for n in $(seq 1 45); do ln -s "L$((n + 1))" "$TMP/l46b/L$n"; done
"${G[@]}" config --file "$R46b/.git/config" include.path "$TMP/l46b/L1"
launch ..
grep -qF "/workspace/proj/r46b/.git/config includes" "$ERR" && grep -qF "not followed to the end" "$ERR" \
  && pass "G46 an include through more links than are followed is named, not taken for safe" \
  || fail "G46 a 45-link include chain passed silently ($(grep -iE 'r46b|not followed' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$R46b" "$TMP/l46b"

# ── G47: a .git file's gitdir: and a commondir are followed ──────────────────
# The scan prunes node_modules/vendor/.venv/target and stops at depth 8, and a
# .git FILE was mounted read-only but the git directory it names never visited:
# `src/.git` = `gitdir: ../node_modules/x/g` left g's config and hooks writable,
# and the host's git in src read them, on every launch (review of batch 9,
# finding 4, HIGH). Followed, as gitlinks are.
mkdir -p "$PROJ/src47" "$PROJ/node_modules/x47"
"${G[@]}" init -q --bare "$PROJ/node_modules/x47/g"
"${G[@]}" config --file "$PROJ/node_modules/x47/g/config" core.bare false
printf 'gitdir: ../node_modules/x47/g\n' > "$PROJ/src47/.git"
launch ..
has_mount "$PROJ/node_modules/x47/g/config:/workspace/proj/node_modules/x47/g/config:ro" \
  && pass "G47 the git directory a .git file names is protected, wherever the scan does not go" \
  || fail "G47 gitdir: target left writable (mounts: $(grep -c node_modules "$CAPTURE"); stderr: $(grep -F x47 "$ERR" | head -2 | tr '\n' ' '))"
# …and a linked worktree's commondir likewise: a worktree of a repository there.
"${G[@]}" init -q "$PROJ/node_modules/x47/common" && "${G[@]}" -C "$PROJ/node_modules/x47/common" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$PROJ/node_modules/x47/common" worktree add -q "$PROJ/wt47" -b wt47 \
  || { printf 'SCAFFOLD-FAILED: G47 worktree\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/x47/common/.git/config:/workspace/proj/node_modules/x47/common/.git/config:ro" \
  && pass "G47 the common directory a commondir names is protected too" \
  || fail "G47 commondir target left writable (stderr: $(grep -F x47 "$ERR" | head -2 | tr '\n' ' '))"
# …and a commondir that is itself a link: git reads through it (security review),
# and the agent can repoint it, which no read-only bind stops, so the launch is
# refused (GIT-62; G166).
"${G[@]}" init -q --bare "$PROJ/node_modules/x47/c2"
mkdir -p "$PROJ/wt47b"; printf '%s\n' "$PROJ/node_modules/x47/c2" > "$PROJ/cd47.txt"
ln -s ../cd47.txt "$PROJ/wt47b/commondir"; printf 'ref: refs/heads/main\n' > "$PROJ/wt47b/HEAD"
launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $PROJ/wt47b/commondir is a symlink" "$ERR" \
  && pass "G47 a commondir that is a link refuses the launch" \
  || fail "G47 a linked commondir not refused (rc=$LAUNCH_RC; stderr: $(grep -F wt47b "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/wt47b" "$PROJ/cd47.txt"
# A target in ANOTHER writable mount (a pruned node_modules of an EXTRA_MOUNTS
# directory, the launcher's own .agent-blocked) is not this mount's scan to
# protect, and was passed in silence: it is named (re-review of batch 9, HIGH).
mkdir -p "$TMP/other47/node_modules" "$PROJ/xm47"; "${G[@]}" init -q --bare "$TMP/other47/node_modules/g"
printf 'gitdir: %s\n' "$TMP/other47/node_modules/g" > "$PROJ/xm47/.git"
EXTRA_MOUNTS="$TMP/other47" launch ..
has_mount "$TMP/other47/node_modules/g/config:/workspace/other47/node_modules/g/config:ro" \
  && ! grep -qF "a git directory in another writable mount" "$ERR" \
  && pass "G47 a gitdir: target in another writable mount is protected in that mount's view" \
  || fail "G47 cross-mount gitdir: target not protected ($(grep -F other47 "$ERR" | head -2 | tr '\n' ' '))"
# A protected repository nested INSIDE the target puts read-only binds inside its
# view, which made it look protected while its own config stayed writable
# (review of 4e7da47, HIGH): protection is now recorded per git directory.
"${G[@]}" init -q "$TMP/other47"; "${G[@]}" init -q "$TMP/other47/node_modules/g/sub"
"${G[@]}" -C "$TMP/other47" update-index --add --cacheinfo "160000,$(printf '%040d' 1),node_modules/g/sub"
EXTRA_MOUNTS="$TMP/other47" launch ..
has_mount "$TMP/other47/node_modules/g/config:/workspace/other47/node_modules/g/config:ro" \
  && pass "G47 a decoy repository nested in the target does not stand in for its protection" \
  || fail "G47 decoy: the target's config left writable ($(grep -F 'node_modules/g' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/other47/.git" "$TMP/other47/node_modules/g/sub"
# …but not when that mount's own scan protects it: a linked worktree as the
# primary with its main checkout in EXTRA_MOUNTS is an ordinary layout, and the
# WARNING fired for a git directory bound :ro just below it (review of dcf7dab).
"${G[@]}" -C "$TMP/other47" init -q -b main main && "${G[@]}" -C "$TMP/other47/main" commit -q --allow-empty -m init \
  && "${G[@]}" -C "$TMP/other47/main" worktree add -q "$PROJ/wt47c" -b feat \
  || { printf 'SCAFFOLD-FAILED: cannot create the G47 worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/other47/main" launch ..
# A refused launch mounts nothing and names nothing: these absences count only for one that ran (GAP-26).
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "a git directory in another writable mount" "$ERR" \
  && pass "G47 a target the other mount's own scan protects is not named" \
  || fail "G47 false 'another writable mount' WARNING (rc=$LAUNCH_RC; $(grep -F 'another writable mount' "$ERR" | head -1))"
rm -rf "$PROJ/wt47c"
# Five decoys that name nothing do not push the real one into a count: it has
# its own path, once per target, never capped (security review of 82183d8).
for n in 1 2 3 4 5 6; do mkdir -p "$PROJ/dec47/d$n"; printf 'gitdir: ../nothing%d\n' "$n" > "$PROJ/dec47/d$n/.git"; done
mkdir -p "$PROJ/xm47"; printf 'gitdir: %s\n' "$TMP/other47/node_modules/g" > "$PROJ/xm47/.git"
EXTRA_MOUNTS="$TMP/other47" launch ..
has_mount "$TMP/other47/node_modules/g/config:/workspace/other47/node_modules/g/config:ro" \
  && pass "G47 decoy .git files do not keep a cross-mount target from being protected" \
  || fail "G47 decoys kept the cross-mount target unprotected"
rm -rf "$TMP/other47" "$PROJ/xm47" "$PROJ/dec47"
# git strips only CR and LF from a .git file: `gitdir: g ` names the directory
# `g ` (with its space), not g (security review of e2741b1).
mkdir -p "$PROJ/sp47"; "${G[@]}" init -q --bare "$PROJ/node_modules/x47/g "
"${G[@]}" config --file "$PROJ/node_modules/x47/g /config" core.bare false
printf 'gitdir: ../node_modules/x47/g \r\n' > "$PROJ/sp47/.git"
launch ..
has_mount "$PROJ/node_modules/x47/g /config:/workspace/proj/node_modules/x47/g /config:ro" \
  && pass "G47 a gitdir: is read as git reads it (only CR and LF stripped)" \
  || fail "G47 gitdir: with a trailing space misread (stderr: $(grep -F x47 "$ERR" | head -2 | tr '\n' ' '))"
# A target that does not exist yet, or one reached through a link the agent can
# repoint, cannot be protected; it is named, never passed in silence.
mkdir -p "$PROJ/miss47"; printf 'gitdir: ../node_modules/x47/later\n' > "$PROJ/miss47/.git"
mkdir -p "$PROJ/lnk47"; ln -s node_modules/x47 "$PROJ/via47"; printf 'gitdir: ../via47/g\n' > "$PROJ/lnk47/.git"
launch ..
grep -qF "names $PROJ/node_modules/x47/later, which does not exist" "$ERR" \
  && pass "G47 a gitdir: naming nothing yet is named" || fail "G47 missing gitdir: target silent ($(grep -F later "$ERR" | head -1))"
grep -qF "$PROJ/lnk47/.git reaches $PROJ/node_modules/x47/g through a link" "$ERR" \
  && pass "G47 a gitdir: reached through a link is named" || fail "G47 gitdir: through a link silent ($(grep -F lnk47 "$ERR" | head -1))"
rm -rf "$PROJ/src47" "$PROJ/node_modules" "$PROJ/wt47" "$PROJ/sp47" "$PROJ/miss47" "$PROJ/lnk47" "$PROJ/via47"

# ── G101: what a .git file or a commondir names that git would refuse is named ─
# git takes a directory for a git directory only with a HEAD, objects/ and
# refs/, and a common directory with objects/ and refs/. Anything less is
# named, and nothing is made in it. Every mutant that took less (no HEAD, no
# objects/, no refs/), and protected it in silence, survived every test
# (GAP-2's slice 2; sandbox.sh: `_is_git_dir()`; sandbox.sh: `_is_common_dir()`).
mkdir -p "$PROJ/nh101/objects" "$PROJ/nh101/refs" "$PROJ/s101a" "$PROJ/no101/refs" "$PROJ/s101b" "$PROJ/nr101/objects"
printf 'gitdir: ../nh101\n' > "$PROJ/s101a/.git"
printf 'ref: refs/heads/main\n' > "$PROJ/no101/HEAD"; printf 'gitdir: ../no101\n' > "$PROJ/s101b/.git"
M101="$PROJ/main101"; "${G[@]}" init -q "$M101" && "${G[@]}" -C "$M101" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M101" worktree add -q "$TMP/lw101" || { printf 'SCAFFOLD-FAILED: G101\n'; exit 1; }
wt101="$(ls -d "$M101/.git/worktrees"/* | head -1)"; printf '%s\n' "$PROJ/nr101" > "$wt101/commondir"
launch ..
grep -qF "$PROJ/s101a/.git names $PROJ/nh101, which is not a git directory" "$ERR" \
  && pass "G101 a gitdir: naming objects/ and refs/ with no HEAD is named" \
  || fail "G101 a gitdir: target with no HEAD (stderr: $(grep -F nh101 "$ERR" | head -1))"
grep -qF "$PROJ/s101b/.git names $PROJ/no101, which is not a git directory" "$ERR" \
  && pass "G101 a gitdir: naming a HEAD and refs/ with no objects/ is named" \
  || fail "G101 a gitdir: target with no objects/ (stderr: $(grep -F no101 "$ERR" | head -1))"
grep -qF "$wt101/commondir names $PROJ/nr101, which is not a git directory" "$ERR" \
  && pass "G101 a commondir naming objects/ with no refs/ is named" \
  || fail "G101 a common directory with no refs/ (stderr: $(grep -F nr101 "$ERR" | head -1))"
[[ ! -e "$PROJ/nh101/commondir" && ! -e "$PROJ/no101/commondir" && ! -e "$PROJ/nr101/commondir" ]] \
  && pass "G101 nothing is made in any of them" \
  || fail "G101 a placeholder was made in what git would refuse ($(ls "$PROJ"/n?101/commondir 2>/dev/null | tr '\n' ' '))"
rm -rf "$PROJ/nh101" "$PROJ/s101a" "$PROJ/no101" "$PROJ/s101b" "$PROJ/nr101" "$M101" "$TMP/lw101"

# ── G102: .git files naming nothing yet are named five at a time ─────────────
# Each is the agent's to write. A mutant that named every one, and counted none
# toward the five, survived every test (GAP-2's slice 2; sandbox.sh: `_gd_resolve()`).
for n in 1 2 3 4 5 6 7; do mkdir -p "$PROJ/c102/d$n"; printf 'gitdir: ../later%s\n' "$n" > "$PROJ/c102/d$n/.git"; done
launch ..
[[ "$(grep -c 'which does not exist; if the agent makes it' "$ERR")" == 5 ]] \
  && grep -qF "… and 2 more .git files or commondirs in $PROJ name what this launch cannot protect." "$ERR" \
  && pass "G102 seven .git files naming nothing give five WARNINGs and a count" \
  || fail "G102 ($(grep -c 'which does not exist' "$ERR") named; $(grep -F 'more .git files' "$ERR"))"
rm -rf "$PROJ/c102"

# ── G48: skipped gitlinks are named a few at a time ──────────────────────────
# Every skipped gitlink got its own WARNING, and the index is the agent's: one
# with 100,000 entries printed 100,000 lines, burying a real WARNING (review of
# batch 9, finding 5). The first five are named, then one line says how many more.
mkdir -p "$PROJ/f48" && "${G[@]}" -C "$PROJ/f48" init -q
for n in $(seq 1 30); do mkdir -p "$PROJ/f48/real$n"; ln -s "real$n" "$PROJ/f48/s$n"
  "${G[@]}" -C "$PROJ/f48" update-index --add --cacheinfo "160000,$(printf '%040d' 1),s$n"; done
launch ..
[[ "$(grep -c 'is not where its index says' "$ERR")" -le 5 ]] && grep -qF "and 25 more submodules of $PROJ/f48/.git" "$ERR" \
  && pass "G48 30 skipped gitlinks give five WARNINGs and a count" \
  || fail "G48 skipped-gitlink WARNINGs ($(grep -c 'is not where its index says' "$ERR") named; $(grep -F 'more submodules' "$ERR"))"
rm -rf "$PROJ/f48"

# ── G50: what a protected cross-mount target names is followed too ───────────
# A queued target is protected, but its commondir was never followed, so the
# common directory it names (with the config and hooks git reads) stayed
# writable, silently (review of 4a4e30c, HIGH).
B50="$TMP/b50"; mkdir -p "$B50/node_modules/x"; "${G[@]}" init -q --bare "$B50/node_modules/x/main"
"${G[@]}" config --file "$B50/node_modules/x/main/config" core.bare false
W50="$B50/node_modules/x/main/worktrees/wt"; mkdir -p "$W50"; printf '../..\n' > "$W50/commondir"
printf 'ref: refs/heads/main\n' > "$W50/HEAD"
mkdir -p "$PROJ/src50"; printf 'gitdir: %s\n' "$W50" > "$PROJ/src50/.git"
EXTRA_MOUNTS="$B50" launch ..
has_mount "$B50/node_modules/x/main/config:/workspace/b50/node_modules/x/main/config:ro" \
  && pass "G50 the common directory of a cross-mount target is protected too" \
  || fail "G50 cross-mount target's common directory left writable (stderr: $(grep -F b50 "$ERR" | head -3 | tr '\n' ' '))"
# One mounted twice (EXTRA_MOUNTS and VAULT_PATH) is protected in both views.
EXTRA_MOUNTS="$B50" VAULT_PATH="$B50" launch ..
has_mount "$B50/node_modules/x/main/config:/workspace/vault/node_modules/x/main/config:ro" \
  && has_mount "$B50/node_modules/x/main/config:/workspace/b50/node_modules/x/main/config:ro" \
  && pass "G50 a directory mounted twice is protected in both views" \
  || fail "G50 a second view left writable"
# A queued target's commondir naming nothing yet is named, as in one mount, and
# refuses the launch as any but ../.. does (G165).
printf '../later50\n' > "$W50/commondir"
EXTRA_MOUNTS="$B50" launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "names $B50/node_modules/x/main/worktrees/later50, which does not exist" "$ERR" \
  && pass "G50 a queued target's commondir that names nothing is named, and refuses the launch" \
  || fail "G50 a queued target's dangling commondir passed in silence ($(grep -F later50 "$ERR" | head -1))"
rm -rf "$B50" "$PROJ/src50"

# ── G51: a target in a named group's directories is protected, and said so ───
# The group's own directories are not scanned — tools re-clone what they hold, and
# a pin there turns that into Resource busy — but a .git file can name one. It is
# protected (left writable, the host's git would run it), and named, so a failed
# re-clone has an explanation (review of 4a4e30c). Five are named, then a count:
# one is named with no count.
GR51="$HOME/.ai-containers/default/.agents/m51"; mkdir -p "$GR51"; "${G[@]}" init -q --bare "$GR51/.git"
mkdir -p "$PROJ/src51"; printf 'gitdir: %s\n' "$GR51/.git" > "$PROJ/src51/.git"
launch ..
grep -qF "inside the container group's own directories" "$ERR" && grep -qF "$PROJ/src51/.git" "$ERR" \
  && ! grep -qF "more in the container group's own directories" "$ERR" \
  && pass "G51 protecting a git directory in the group's directories is named, with no count of more" \
  || fail "G51 group-directory protection not named (stderr: $(grep -F m51 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$GR51" "$PROJ/src51"

# ── G52: a linked worktree's submodules are followed ────────────────────────
# The index was read only for */.git and .git/modules directories, and a linked
# worktree's git directory, which has no objects/, was skipped: a submodule in a
# pruned vendor/ of a linked worktree kept a writable .git file the agent could
# point at a git directory of its own (review of 236d347, HIGH; existed before).
U52="$TMP/up52"; "${G[@]}" init -q "$U52" && "${G[@]}" -C "$U52" commit -q --allow-empty -m u
M52="$PROJ/main52"; "${G[@]}" init -q "$M52" \
  && "${G[@]}" -C "$M52" -c protocol.file.allow=always submodule -q add "$U52" vendor/lib \
  && "${G[@]}" -C "$M52" commit -q -m s && "${G[@]}" -C "$M52" worktree add -q "$PROJ/lw52" \
  && "${G[@]}" -C "$PROJ/lw52" -c protocol.file.allow=always submodule -q update --init \
  || { printf 'SCAFFOLD-FAILED: cannot create the G52 worktree\n'; exit 1; }
launch ..
has_mount "$PROJ/lw52/vendor/lib/.git:/workspace/proj/lw52/vendor/lib/.git:ro" \
  && pass "G52 a submodule of a linked worktree, under a pruned vendor/, is protected" \
  || fail "G52 linked worktree's submodule .git left writable"
rm -rf "$U52" "$M52" "$PROJ/lw52"

# ── G53: a .git file cannot choose a repository's worktree ──────────────────
# The last .git file to name a git directory chose the worktree its index was read
# against: `decoy/.git` = `gitdir: ../.git` made the project's own index read
# against decoy/, so an embedded submodule under a pruned vendor/ was skipped in
# silence, its config writable (review of 3c754aa, HIGH). A .git directory's
# worktree is where it lies; for a linked worktree's, every candidate is read.
U53="$TMP/up53"; "${G[@]}" init -q "$U53" && "${G[@]}" -C "$U53" commit -q --allow-empty -m u
M53="$PROJ/main53"; "${G[@]}" init -q "$M53" && "${G[@]}" clone -q "$U53" "$M53/vendor/lib" \
  && { "${G[@]}" -C "$M53" -c protocol.file.allow=always submodule -q add "$U53" vendor/lib 2>/dev/null || "${G[@]}" -C "$M53" add vendor/lib; } \
  && "${G[@]}" -C "$M53" commit -q -m s || { printf 'SCAFFOLD-FAILED: cannot create the G53 repository\n'; exit 1; }
mkdir -p "$M53/decoy"; printf 'gitdir: ../.git\n' > "$M53/decoy/.git"
launch ..
has_mount "$M53/vendor/lib/.git/config:/workspace/proj/main53/vendor/lib/.git/config:ro" \
  && pass "G53 a decoy .git file does not change which worktree a repository's index is read against" \
  || fail "G53 the embedded submodule was left writable by a decoy .git file"
rm -rf "$U53" "$M53"

# ── G54/G55: an index read is never skipped for want of a worktree ──────────
# G54: a .git/modules/* directory without core.worktree, which git reads against
# the directory of the .git file naming it, got none, so its index was never read
# and an embedded submodule under a pruned vendor/ stayed writable, silently
# (review of 8b3e0c5, MEDIUM; existed before).
U54="$TMP/up54"; "${G[@]}" init -q "$U54" && "${G[@]}" -C "$U54" commit -q --allow-empty -m u
S54="$TMP/us54"; "${G[@]}" init -q "$S54" && "${G[@]}" -C "$S54" commit -q --allow-empty -m s
M54="$PROJ/main54"; "${G[@]}" init -q "$M54" \
  && "${G[@]}" -C "$M54" -c protocol.file.allow=always submodule -q add "$U54" vendor/lib && "${G[@]}" -C "$M54" commit -q -m s \
  && "${G[@]}" clone -q "$S54" "$M54/vendor/lib/vendor/sub" && "${G[@]}" -C "$M54/vendor/lib" add vendor/sub 2>/dev/null \
  && "${G[@]}" -C "$M54/vendor/lib" commit -q -m n \
  && "${G[@]}" config -f "$M54/.git/modules/vendor/lib/config" --unset core.worktree \
  || { printf 'SCAFFOLD-FAILED: cannot create the G54 repository\n'; exit 1; }
launch ..
has_mount "$M54/vendor/lib/vendor/sub/.git/config:/workspace/proj/main54/vendor/lib/vendor/sub/.git/config:ro" \
  && pass "G54 a submodule's git directory without core.worktree is read against its .git file's directory" \
  || fail "G54 an index with no core.worktree was never read"
rm -rf "$U54" "$S54" "$M54"
# G55: a linked worktree in another writable mount than its main repository: only
# this mount sees the .git file naming its git directory, so this mount reads it.
U55="$TMP/up55"; "${G[@]}" init -q "$U55" && "${G[@]}" -C "$U55" commit -q --allow-empty -m u
M55="$TMP/main55"; "${G[@]}" init -q "$M55" && "${G[@]}" -C "$M55" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M55" worktree add -q "$PROJ/lw55" \
  && "${G[@]}" clone -q "$U55" "$PROJ/lw55/vendor/lib" && "${G[@]}" -C "$PROJ/lw55" add vendor/lib 2>/dev/null \
  && "${G[@]}" -C "$PROJ/lw55" commit -q -m n || { printf 'SCAFFOLD-FAILED: cannot create the G55 worktree\n'; exit 1; }
EXTRA_MOUNTS="$M55" launch ..
has_mount "$PROJ/lw55/vendor/lib/.git/config:/workspace/proj/lw55/vendor/lib/.git/config:ro" \
  && pass "G55 a linked worktree's submodules are read when its main repository is in another mount" \
  || fail "G55 a cross-mount linked worktree's index was never read"
rm -rf "$U55" "$M55" "$PROJ/lw55"

# ── G56: an index is read once, however many .git files name its directory ───
# Read once per referrer, every decoy .git file the agent planted cost another
# read and repeated each WARNING: 50 decoys gave 51 identical lines (review of
# 8b3e0c5).
M56="$PROJ/main56"; "${G[@]}" init -q "$M56" && "${G[@]}" -C "$M56" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M56" worktree add -q "$PROJ/lw56" || { printf 'SCAFFOLD-FAILED: cannot create the G56 worktree\n'; exit 1; }
wt56="$(ls -d "$M56/.git/worktrees"/* | head -1)"; printf 'garbage' > "$wt56/index"
for n in $(seq 1 10); do mkdir -p "$PROJ/dec56/d$n"; printf 'gitdir: %s\n' "$wt56" > "$PROJ/dec56/d$n/.git"; done
launch ..
[[ "$(grep -cF "cannot read the index of $wt56" "$ERR")" == 1 ]] \
  && pass "G56 ten .git files naming one git directory read its index once" \
  || fail "G56 index read per referrer ($(grep -cF "cannot read the index of $wt56" "$ERR") WARNINGs)"
rm -rf "$M56" "$PROJ/lw56" "$PROJ/dec56"

# ── G103: a git directory a .git file names is read once ────────────────────
# G56 counts a WARNING the read prints once whatever the reads, so it cannot
# tell. A gitlink not where the index says is named on every read: five
# mutants that queued the directory again, once found and once named, survived
# every test (GAP-2's slice 2; sandbox.sh: `_gdi_follow()`).
"${G[@]}" init -q --bare "$PROJ/gd103" && "${G[@]}" config --file "$PROJ/gd103/config" core.bare false
mkdir -p "$PROJ/dec103/real" "$TMP/wt103"; ln -s real "$PROJ/dec103/s"
printf 'gitdir: ../gd103\n' > "$PROJ/dec103/.git"
"${G[@]}" --git-dir="$PROJ/gd103" --work-tree="$TMP/wt103" update-index --add --cacheinfo "160000,$(printf '%040d' 1),s" \
  || { printf 'SCAFFOLD-FAILED: G103\n'; exit 1; }
launch ..
[[ "$(grep -c "submodule $PROJ/dec103/s of $PROJ/gd103 is not where its index says" "$ERR")" == 1 ]] \
  && pass "G103 a git directory a .git file names is read once" \
  || fail "G103 read more than once ($(grep -c 'dec103/s' "$ERR") WARNINGs)"
rm -rf "$PROJ/gd103" "$PROJ/dec103" "$TMP/wt103"

# ── G57: more .git files naming one git directory than are followed refuses ───
# Past twenty the rest were skipped with a WARNING, and the agent can mint decoys
# that sort before the real one: its checkout's submodules were then not checked
# (automated security review of 3edee25). Refused, as SANDBOX_GIT_MAX refuses.
M57="$PROJ/main57"; "${G[@]}" init -q "$M57" && "${G[@]}" -C "$M57" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M57" worktree add -q "$PROJ/lw57" || { printf 'SCAFFOLD-FAILED: cannot create the G57 worktree\n'; exit 1; }
wt57="$(ls -d "$M57/.git/worktrees"/* | head -1)"
for n in $(seq 1 21); do mkdir -p "$PROJ/dec57/d$n"; printf 'gitdir: %s\n' "$wt57" > "$PROJ/dec57/d$n/.git"; done
launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: more than 20 .git files in $PROJ name $wt57" "$ERR" \
  && [[ "$(awk '/Among them, in:/ {p = 1; next} /Remove the .git files/ {p = 0} p' "$ERR" | grep -c '^         ')" == 5 ]] \
  && pass "G57 more than twenty .git files naming one git directory refuse the launch, naming five of them" \
  || fail "G57 decoy referrers past the cap did not refuse (rc=$LAUNCH_RC; $(grep -F 'more than 20' "$ERR" | head -1))"
rm -rf "$M57" "$PROJ/lw57" "$PROJ/dec57"

# ── G58: a git directory waiting for a worktree is retried until none turns up ─
# A directory with no worktree yet was retried once; the .git file naming it can
# turn up later still, through an index read only after another such retry —
# nested submodules without core.worktree under pruned vendor/ directories
# (automated security review of 3edee25).
U58="$TMP/up58"; S58="$TMP/us58"; T58="$TMP/ut58"
for r in "$U58" "$S58" "$T58"; do "${G[@]}" init -q "$r" && "${G[@]}" -C "$r" commit -q --allow-empty -m r; done
M58="$PROJ/main58"; "${G[@]}" init -q "$M58" \
  && "${G[@]}" -C "$M58" -c protocol.file.allow=always submodule -q add "$U58" vendor/a && "${G[@]}" -C "$M58" commit -q -m a \
  && "${G[@]}" -C "$M58/vendor/a" -c protocol.file.allow=always submodule -q add "$S58" vendor/b \
  && "${G[@]}" -C "$M58/vendor/a" commit -q -m b \
  && "${G[@]}" clone -q "$T58" "$M58/vendor/a/vendor/b/vendor/c" && "${G[@]}" -C "$M58/vendor/a/vendor/b" add vendor/c 2>/dev/null \
  && "${G[@]}" -C "$M58/vendor/a/vendor/b" commit -q -m c \
  || { printf 'SCAFFOLD-FAILED: cannot create the G58 repository\n'; exit 1; }
for d in "$M58/.git/modules/vendor/a" "$M58/.git/modules/vendor/a/modules/vendor/b"; do
  "${G[@]}" config -f "$d/config" --unset core.worktree; done
launch ..
has_mount "$M58/vendor/a/vendor/b/vendor/c/.git/config:/workspace/proj/main58/vendor/a/vendor/b/vendor/c/.git/config:ro" \
  && pass "G58 nested submodules without core.worktree are read until nothing new turns up" \
  || fail "G58 a nested submodule's index was dropped before its .git file turned up"
rm -rf "$U58" "$S58" "$T58" "$M58"

# ── G105: a commondir gives the common directory no worktree ────────────────
# A linked worktree's git directory names its common directory, but is no
# worktree of it: a bare repository's index read against it followed nothing,
# and the WARNING that its submodules are not followed was lost. A mutant that
# took the commondir for a referrer survived every test (GAP-2's slice 2;
# sandbox.sh: `_gdi_follow()`).
B105="$PROJ/b105"; "${G[@]}" init -q --bare "$B105" && "${G[@]}" init -q "$TMP/seed105" \
  && "${G[@]}" -C "$TMP/seed105" commit -q --allow-empty -m s && "${G[@]}" -C "$TMP/seed105" push -q "$B105" main 2>/dev/null \
  && "${G[@]}" --git-dir="$B105" worktree add -q "$TMP/bw105" main && mkdir -p "$TMP/wt105" \
  && "${G[@]}" --git-dir="$B105" --work-tree="$TMP/wt105" update-index --add --cacheinfo "160000,$(printf '%040d' 1),sub" \
  || { printf 'SCAFFOLD-FAILED: G105\n'; exit 1; }
launch ..
grep -qF "no worktree is known for $B105, so the submodules its index records are not followed." "$ERR" \
  && pass "G105 a common directory takes no worktree from a commondir, and its unfollowed submodules are named" \
  || fail "G105 (stderr: $(grep -F b105 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$B105" "$TMP/seed105" "$TMP/bw105" "$TMP/wt105"

# ── G59/G60: the repository a mount sits in is read too ─────────────────────
# G59: a submodule checkout mounted on its own: its git directory is the
# superproject's .git/modules/<name>, outside the mount, and its index (with its
# own submodules) was never read (review of 3edee25, MEDIUM).
U59="$TMP/up59"; S59="$TMP/us59"
for r in "$U59" "$S59"; do "${G[@]}" init -q "$r" && "${G[@]}" -C "$r" commit -q --allow-empty -m r; done
M59="$TMP/main59"; "${G[@]}" init -q "$M59" \
  && "${G[@]}" -C "$M59" -c protocol.file.allow=always submodule -q add "$U59" sub && "${G[@]}" -C "$M59" commit -q -m s \
  && "${G[@]}" clone -q "$S59" "$M59/sub/vendor/lib" && "${G[@]}" -C "$M59/sub" add vendor/lib 2>/dev/null \
  && "${G[@]}" -C "$M59/sub" commit -q -m l || { printf 'SCAFFOLD-FAILED: cannot create the G59 repository\n'; exit 1; }
EXTRA_MOUNTS="$M59/sub" launch ..
has_mount "$M59/sub/vendor/lib/.git/config:/workspace/sub/vendor/lib/.git/config:ro" \
  && pass "G59 a submodule checkout mounted alone has its own submodules protected" \
  || fail "G59 a lone submodule checkout's submodule left writable"
rm -rf "$U59" "$S59" "$M59"
# G60: a subdirectory of a repository mounted alone: the enclosing repository's
# index, outside the mount, records the submodules inside it — one under a
# pruned vendor/ is found nowhere else.
S60="$TMP/us60"; "${G[@]}" init -q "$S60" && "${G[@]}" -C "$S60" commit -q --allow-empty -m s
M60="$TMP/main60"; "${G[@]}" init -q "$M60" && "${G[@]}" clone -q "$S60" "$M60/src/vendor/lib" \
  && "${G[@]}" -C "$M60" add src/vendor/lib 2>/dev/null && "${G[@]}" -C "$M60" commit -q -m l \
  || { printf 'SCAFFOLD-FAILED: cannot create the G60 repository\n'; exit 1; }
EXTRA_MOUNTS="$M60/src" launch ..
has_mount "$M60/src/vendor/lib/.git/config:/workspace/src/vendor/lib/.git/config:ro" \
  && pass "G60 a subdirectory of a repository mounted alone has the submodules in it protected" \
  || fail "G60 a lone subdirectory's submodule left writable"
rm -rf "$S60" "$M60"

# ── G61: a .git the agent plants cannot stop the walk to the enclosing one ───
# With a writable mount nested in another (the project, plus EXTRA_MOUNTS of a
# subdirectory of it), the agent can plant a .git between the two; the walk up
# stopped there and never read the project's index, leaving a submodule under
# the nested mount's pruned vendor/ writable in its view (review of 4e91bf3).
S61="$TMP/us61"; "${G[@]}" init -q "$S61" && "${G[@]}" -C "$S61" commit -q --allow-empty -m s
mkdir -p "$PROJ/a61/b"; "${G[@]}" clone -q "$S61" "$PROJ/a61/b/vendor/x" \
  && "${G[@]}" -C "$PROJ" add a61/b/vendor/x 2>/dev/null || { printf 'SCAFFOLD-FAILED: G61\n'; exit 1; }
mkdir "$PROJ/a61/.git"
EXTRA_MOUNTS="$PROJ/a61/b" launch ..
has_mount "$PROJ/a61/b/vendor/x/.git/config:/workspace/b/vendor/x/.git/config:ro" \
  && pass "G61 a planted .git between two mounts does not hide the enclosing repository" \
  || fail "G61 the walk stopped at a planted .git"
"${G[@]}" -C "$PROJ" rm -q --cached a61/b/vendor/x >/dev/null 2>&1; rm -rf "$S61" "$PROJ/a61"

# ── G62: a referrer that turns up after a git directory was read is used too ──
# A decoy found first made a git directory without core.worktree be read against
# the decoy alone; the real checkout, found later through an index, was never
# used (review of 4e91bf3).
U62="$TMP/up62"; S62="$TMP/us62"
for r in "$U62" "$S62"; do "${G[@]}" init -q "$r" && "${G[@]}" -C "$r" commit -q --allow-empty -m r; done
M62="$PROJ/main62"; "${G[@]}" init -q "$M62" \
  && "${G[@]}" -C "$M62" -c protocol.file.allow=always submodule -q add "$U62" vendor/lib && "${G[@]}" -C "$M62" commit -q -m s \
  && "${G[@]}" clone -q "$S62" "$M62/vendor/lib/vendor/sub" && "${G[@]}" -C "$M62/vendor/lib" add vendor/sub 2>/dev/null \
  && "${G[@]}" -C "$M62/vendor/lib" commit -q -m n \
  && "${G[@]}" config -f "$M62/.git/modules/vendor/lib/config" --unset core.worktree \
  || { printf 'SCAFFOLD-FAILED: G62\n'; exit 1; }
mkdir -p "$PROJ/decoy62"; printf 'gitdir: ../main62/.git/modules/vendor/lib\n' > "$PROJ/decoy62/.git"
launch ..
has_mount "$M62/vendor/lib/vendor/sub/.git/config:/workspace/proj/main62/vendor/lib/vendor/sub/.git/config:ro" \
  && pass "G62 a referrer found after a git directory was read is read against too" \
  || fail "G62 a late referrer was never used"
rm -rf "$U62" "$S62" "$M62" "$PROJ/decoy62"

# ── G104: a referrer found only after the read is read against, once ───────
# G62's decoy and checkout are both found before the git directory is read
# (.git files are followed first), so it no longer reaches the read again; two
# mutants that never read again survived every test, and one that read a .git
# directory again too (GAP-2's slice 2; sandbox.sh: `_gdi_follow()`). Here the late .git file
# is found only through an index the first read leads to, whatever order the
# scan returns: gd104's index, read against dec104, finds the repository at
# dec104/vendor/sub, whose index records r (naming gd104) and r2 (naming
# bad104/.git, already read).
"${G[@]}" init -q --bare "$PROJ/gd104" && "${G[@]}" config --file "$PROJ/gd104/config" core.bare false
mkdir -p "$TMP/wt104" "$PROJ/dec104"; printf 'gitdir: ../gd104\n' > "$PROJ/dec104/.git"
E104="$PROJ/dec104/vendor/sub"
"${G[@]}" --git-dir="$PROJ/gd104" --work-tree="$TMP/wt104" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/sub" \
  && "${G[@]}" init -q "$E104" && mkdir -p "$E104/r" "$E104/r2" \
  && printf 'gitdir: %s\n' "$PROJ/gd104" > "$E104/r/.git" && printf 'gitdir: %s\n' "$PROJ/bad104/.git" > "$E104/r2/.git" \
  && "${G[@]}" -C "$E104" update-index --add --cacheinfo "160000,$(printf '%040d' 1),r" \
  && "${G[@]}" -C "$E104" update-index --add --cacheinfo "160000,$(printf '%040d' 1),r2" \
  && "${G[@]}" init -q "$E104/r/vendor/sub" && "${G[@]}" init -q "$PROJ/bad104" \
  || { printf 'SCAFFOLD-FAILED: G104\n'; exit 1; }
printf 'garbage' > "$PROJ/bad104/.git/index"
launch ..
has_mount "$E104/r/vendor/sub/.git/config:/workspace/proj/dec104/vendor/sub/r/vendor/sub/.git/config:ro" \
  && pass "G104 a referrer found only after a git directory was read is read against too" \
  || fail "G104 the late referrer's submodule was left writable"
[[ "$(grep -cF "cannot read the index of $PROJ/bad104/.git" "$ERR")" == 1 ]] \
  && pass "G104 a .git directory a late .git file names is not read again" \
  || fail "G104 read again ($(grep -cF "cannot read the index of $PROJ/bad104/.git" "$ERR") WARNINGs)"
rm -rf "$PROJ/gd104" "$PROJ/dec104" "$PROJ/bad104" "$TMP/wt104"

# ── G64: a FIFO planted as .git above a mount cannot hang the walk up ───────
# The walk read any .git that was not a directory, and a FIFO there blocked the
# read for ever (automated security review of 4a800a9).
mkdir -p "$PROJ/f64/sub"; mkfifo "$PROJ/f64/.git"
EXTRA_MOUNTS="$PROJ/f64/sub" launch_timed 60
[[ "$LAUNCH_RC" != 124 ]] && pass "G64 a FIFO .git above a nested mount does not hang the launch (${LAUNCH_S}s)" \
  || fail "G64 the walk up hung on a FIFO .git"
( exec 3<>"$PROJ/f64/.git" ) 2>/dev/null; rm -rf "$PROJ/f64"

# ── G90: CDPATH (GIT-17). A submodule's relative core.worktree with no ./ or
# ../ is resolved by `cd`, which an exported CDPATH redirects — and makes print
# the directory it went to. Here core.worktree=wt90 names a link in the
# submodule's git directory to its checkout, and a nested submodule under
# vendor/ (pruned by the scan; its own git directory has no core.worktree) is
# found only through that checkout's index, so a misplaced worktree loses it.
U90="$TMP/up90"; S90="$TMP/us90"; M90="$TMP/m90"; D90="$TMP/decoy90"
for r in "$U90" "$S90"; do "${G[@]}" init -q "$r" && "${G[@]}" -C "$r" commit -q --allow-empty -m r; done
mkdir -p "$D90/wt90"
"${G[@]}" init -q "$M90" \
  && "${G[@]}" -C "$M90" -c protocol.file.allow=always submodule -q add "$U90" vendor/a && "${G[@]}" -C "$M90" commit -q -m a \
  && "${G[@]}" -C "$M90/vendor/a" -c protocol.file.allow=always submodule -q add "$S90" vendor/b \
  && "${G[@]}" -C "$M90/vendor/a" commit -q -m b \
  && ln -s "$M90/vendor/a" "$M90/.git/modules/vendor/a/wt90" \
  && "${G[@]}" config -f "$M90/.git/modules/vendor/a/config" core.worktree wt90 \
  && "${G[@]}" config -f "$M90/.git/modules/vendor/a/modules/vendor/b/config" --unset core.worktree \
  || { printf 'SCAFFOLD-FAILED: cannot create the G90 repository\n'; exit 1; }
want90="$M90/vendor/a/vendor/b/.git:/workspace/m90/vendor/a/vendor/b/.git:ro"
EXTRA_MOUNTS="$M90" launch "$TMP/app"
has_mount "$want90" && pass "G90 (control) a nested submodule found through a relative core.worktree is protected" \
  || fail "G90 control: no $want90 (git mounts: $(git_mounts | grep m90 | tr '\n' ' '))"
CDPATH="$D90" EXTRA_MOUNTS="$M90" launch "$TMP/app"
has_mount "$want90" && pass "G90 an exported CDPATH does not move a relative core.worktree" \
  || fail "G90 with CDPATH set, $want90 is missing (git mounts: $(git_mounts | grep m90 | tr '\n' ' '))"
rm -rf "$U90" "$S90" "$M90" "$D90"

# ── G91: a newline in a directory name (GIT-18). A .git file there naming its
# git directory relatively was given a lexical path cut at the newline, which
# never matched the physical one: a spurious "through a link" WARNING.
M91="$TMP/m91"; NL91="$M91/a"$'\n'"b"
mkdir -p "$NL91" && "${G[@]}" init -q --bare "$M91/real91" \
  && printf 'gitdir: ../real91\n' > "$NL91/.git" \
  || { printf 'SCAFFOLD-FAILED: cannot create the G91 repository\n'; exit 1; }
EXTRA_MOUNTS="$M91" launch "$TMP/app"
grep -q 'reaches .*real91 through a link' "$ERR" \
  && fail "G91 a newline in the .git file's directory gave a spurious link WARNING: $(grep -a 'through a link' "$ERR" | head -1)" \
  || pass "G91 a newline in a directory name does not cut its lexical path"
grep -qF "$M91/real91/config:/workspace/m91/real91/config:ro" <<<"$(mounts)" \
  && pass "G91 (control) the git directory it names is protected" || fail "G91 control: real91 not protected"
rm -rf "$M91"

# ── G73: an exported CDPATH does not move a submodule's worktree ─────────────
# A relative core.worktree with no ./ was resolved through the host shell's
# CDPATH, which put the worktree elsewhere and left an embedded submodule's
# config writable (GIT-17).
U73="$TMP/up73"; "${G[@]}" init -q "$U73" && "${G[@]}" -C "$U73" commit -q --allow-empty -m u
M73="$PROJ/m73"; g73="$M73/.git/modules/sub"
"${G[@]}" init -q "$M73" && mkdir -p "$M73/.git/modules" && "${G[@]}" init -q --separate-git-dir="$g73" "$g73/co73" \
  && "${G[@]}" -C "$g73/co73" commit -q --allow-empty -m i && "${G[@]}" clone -q "$U73" "$g73/co73/vendor/lib" \
  && "${G[@]}" -C "$g73/co73" add vendor/lib 2>/dev/null && "${G[@]}" -C "$g73/co73" commit -q -m s \
  && "${G[@]}" --git-dir="$g73" config core.worktree co73 || { printf 'SCAFFOLD-FAILED: G73\n'; exit 1; }
mkdir -p "$TMP/cd73/co73"
CDPATH="${CD73-$TMP/cd73}" launch ..
has_mount "$g73/co73/vendor/lib/.git/config:/workspace/proj/m73/.git/modules/sub/co73/vendor/lib/.git/config:ro" \
  && pass "G73 an exported CDPATH does not move the worktree a relative core.worktree names" \
  || fail "G73 CDPATH moved the worktree (git mounts: $(git_mounts | grep m73 | tr '\n' ' '))"
rm -rf "$U73" "$M73" "$TMP/cd73"

# ── G74: _lex_norm keeps a component that holds a newline whole (GIT-18) ──────
load_fn _lex_norm
got74="$(_lex_norm "/a/b"$'\n'"c/./d/../e")"
[[ "$got74" == "/a/b"$'\n'"c/e" ]] && pass "G74 _lex_norm keeps a newline inside a component" \
  || fail "G74 _lex_norm truncated a path at a newline (got $(printf %q "$got74"))"

# ── G75: the index-read timeout uses gtimeout where there is no timeout ───────
# macOS has no timeout(1); Homebrew's coreutils installs gtimeout (GIT-16).
load_fn _timeout_prefix
mkdir -p "$TMP/tp75"; printf '#!/bin/sh\nshift 3; exec "$@"\n' > "$TMP/tp75/gtimeout"; chmod +x "$TMP/tp75/gtimeout"
got75="$(PATH="$TMP/tp75" _timeout_prefix 2>/dev/null)"
[[ "$got75" == "gtimeout -k 2 10" ]] && pass "G75 the index read is bounded by gtimeout where there is no timeout" \
  || fail "G75 gtimeout not used (got '$got75')"
rm -rf "$TMP/tp75"

# ── G80: a gitdir rewritten to a path that does not exist is named ───────────
# A linked worktree checked out under a pruned vendor/ is found through its
# gitdir back-pointer; one the agent rewrote to an absolute path outside every
# mount was taken for a worktree checked out elsewhere, and its submodules went
# unprotected in silence even when that path did not exist (GIT-6).
U80="$TMP/up80"; "${G[@]}" init -q "$U80" && "${G[@]}" -C "$U80" commit -q --allow-empty -m u
M80="$PROJ/m80"; "${G[@]}" init -q "$M80" && "${G[@]}" -C "$M80" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$M80" worktree add -q "$PROJ/vendor/wt80" \
  && "${G[@]}" clone -q "$U80" "$PROJ/vendor/wt80/x" && "${G[@]}" -C "$PROJ/vendor/wt80" add x 2>/dev/null \
  && "${G[@]}" -C "$PROJ/vendor/wt80" commit -q -m s || { printf 'SCAFFOLD-FAILED: G80\n'; exit 1; }
printf '%s\n' "/nonexistent80/elsewhere/.git" > "$M80/.git/worktrees/wt80/gitdir"
launch ..
grep -qF "no worktree is known for $M80/.git/worktrees/wt80" "$ERR" \
  && pass "G80 a worktree whose gitdir names a path that does not exist is named" \
  || fail "G80 a rewritten gitdir silenced the worktree ($(grep -F wt80 "$ERR" | head -1))"
# …nor one naming an existing file outside the mounts that is not the worktree's
# .git: any path the agent picks exists somewhere (automated security review of
# 3fd28c7). A worktree really checked out outside every mount, its .git file
# naming this git directory back, stays quiet.
mkdir -p "$TMP/out80"; printf 'x\n' > "$TMP/out80/hostname"
printf '%s\n' "$TMP/out80/hostname" > "$M80/.git/worktrees/wt80/gitdir"
launch ..
warned80=0; grep -qF "no worktree is known for $M80/.git/worktrees/wt80" "$ERR" && warned80=1
mkdir -p "$TMP/out80/wt"; printf 'gitdir: %s\n' "$M80/.git/worktrees/wt80" > "$TMP/out80/wt/.git"
printf '%s\n' "$TMP/out80/wt/.git" > "$M80/.git/worktrees/wt80/gitdir"
launch ..
quiet80=0; grep -qF "no worktree is known for $M80/.git/worktrees/wt80" "$ERR" || quiet80=1
# …but not the worktree's own .git inside the mount, written as a path that leaves
# the mounts and comes back with .. (automated security review of efbfcc3).
printf '%s\n' "$TMP/out80/../proj/vendor/wt80/.git" > "$M80/.git/worktrees/wt80/gitdir"
launch ..
# The back-pointer then names the worktree physically, so its submodule must be
# protected — or, failing that, named.
[[ "$warned80" == 1 && "$quiet80" == 1 ]] \
  && { has_mount "$PROJ/vendor/wt80/x/.git/config:/workspace/proj/vendor/wt80/x/.git/config:ro" \
       || grep -qF "no worktree is known for $M80/.git/worktrees/wt80" "$ERR"; } \
  && pass "G80 … nor one naming an unrelated file, or a mount's own .git by way of ..; a worktree checked out outside the mounts stays quiet" \
  || fail "G80 gitdir check (unrelated file warned: $warned80; real one quiet: $quiet80; by way of ..: $(grep -F wt80 "$ERR" | head -1))"
rm -rf "$U80" "$M80" "$PROJ/vendor/wt80" "$TMP/out80"; rmdir "$PROJ/vendor" 2>/dev/null || true

# ── G82: gitlinks cost one resolve per index, and are followed up to 1000 ────
# Each (gitlink, worktree top) pair forked a subshell when its checkout existed,
# and nothing capped the gitlinks followed, so an index of the agent's with
# thousands of them, and planted .git files naming the worktree, cost minutes
# (GIT-8).
M82="$PROJ/m82"; "${G[@]}" init -q "$M82" && "${G[@]}" -C "$M82" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$M82" worktree add -q "$PROJ/vendor/wt82" || { printf 'SCAFFOLD-FAILED: G82\n'; exit 1; }
sha82="$("${G[@]}" -C "$M82" rev-parse HEAD)"
for n in $(seq 1 1500); do printf '160000 %s\tl%d\n' "$sha82" "$n"; mkdir -p "$PROJ/vendor/wt82/l$n"; done \
  | "${G[@]}" -C "$PROJ/vendor/wt82" update-index --index-info
for n in $(seq 1 19); do mkdir -p "$PROJ/d82/$n"; printf 'gitdir: %s\n' "$M82/.git/worktrees/wt82" > "$PROJ/d82/$n/.git"; done
launch_timed 120
# Past the cap the launch is refused, not warned about: the agent could write
# 1001 gitlinks with the one it wants unprotected last (automated security
# review of the batch 10 branch, MEDIUM), as SANDBOX_GIT_MAX refuses.
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 && "$LAUNCH_S" -lt 30 ]] && grep -qF "ERROR: the index of" "$ERR" && grep -qF "records more than 1000 submodules" "$ERR" \
  && pass "G82 1500 gitlinks under 20 worktree tops cost seconds, and past 1000 the launch is refused (${LAUNCH_S}s)" \
  || fail "G82 gitlinks (rc=$LAUNCH_RC; ${LAUNCH_S}s; $(grep -F 'more than 1000' "$ERR" | head -1))"
rm -rf "$M82" "$PROJ/vendor/wt82" "$PROJ/d82"; rmdir "$PROJ/vendor" 2>/dev/null || true

# ── G95: an index is named as unread only when it cannot be read ──────────────
# A repository with no index (a fresh `git init`) records nothing and is not
# named. One whose index is a directory, or whose config names an object format
# git does not know, cannot be read, and is named: read as "nothing recorded",
# its submodules would go unfollowed with nothing said, and the agent writes
# both the index and the config (GAP-2's sandbox.sh sample: the three checks
# survived every mutant).
rm -rf "$TMP/ix"; mkdir -p "$TMP/ix" || { printf 'SCAFFOLD-FAILED: G95\n'; exit 1; }
"${G[@]}" init -q "$TMP/ix/none" && "${G[@]}" init -q "$TMP/ix/dir" && mkdir "$TMP/ix/dir/.git/index" \
  && "${G[@]}" init -q "$TMP/ix/fmt" && "${G[@]}" -C "$TMP/ix/fmt" commit -q --allow-empty -m f \
  && : > "$TMP/ix/fmt/f" && "${G[@]}" -C "$TMP/ix/fmt" add f \
  && printf '[extensions]\n\tobjectformat = nosuchformat95\n' >> "$TMP/ix/fmt/.git/config" \
  && "${G[@]}" init -q "$TMP/ix/odd" && : > "$TMP/ix/odd/f" && "${G[@]}" -C "$TMP/ix/odd" add f \
  && printf '[extensions]\n\tobjectformat = ../sha1\n' >> "$TMP/ix/odd/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G95 repositories\n'; exit 1; }
[[ ! -e "$TMP/ix/none/.git/index" ]] || { printf 'SCAFFOLD-FAILED: G95 git init made an index\n'; exit 1; }
rm -rf "$TMP/t95"; mkdir -p "$TMP/t95"
TMPDIR="$TMP/t95" EXTRA_MOUNTS="$TMP/ix" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index of $TMP/ix/none/.git" "$ERR" \
  && pass "G95 a repository with no index is not named as unreadable" \
  || fail "G95 no index (rc=$LAUNCH_RC; stderr: $(grep -F "$TMP/ix/none" "$ERR" | head -2 | tr '\n' ' '))"
grep -qF "WARNING: cannot read the index of $TMP/ix/dir/.git" "$ERR" \
  && pass "G95 an index that is a directory is named as unreadable" \
  || fail "G95 directory index not named (stderr: $(grep -F "$TMP/ix/dir" "$ERR" | head -2 | tr '\n' ' '))"
grep -qF "WARNING: cannot read the index of $TMP/ix/fmt/.git" "$ERR" \
  && pass "G95 an index whose config names an unknown object format is named as unreadable" \
  || fail "G95 unknown object format not named (stderr: $(grep -F "$TMP/ix/fmt" "$ERR" | head -2 | tr '\n' ' '))"
# A format that is not even a name (it becomes a directory name below TMPDIR).
grep -qF "WARNING: cannot read the index of $TMP/ix/odd/.git" "$ERR" \
  && pass "G95 an object format that is not a plain name is named as unreadable" \
  || fail "G95 object format '../sha1' not named (stderr: $(grep -F "$TMP/ix/odd" "$ERR" | head -2 | tr '\n' ' '))"
# …and makes nothing beside the launcher's own temporary directory: the format
# names a directory under it, and git init made `../sha1` one level up before
# refusing the format.
[[ ! -e "$TMP/t95/sha1" ]] \
  && pass "G95 an object format that is a path makes no directory outside the launcher's temporary one" \
  || fail "G95 '../sha1' made $TMP/t95/sha1"
rm -rf "$TMP/ix" "$TMP/t95"

# ── G110: a repository with no config has its index read as sha1 ───────────
# git reads one (G49 makes it an empty config at its first protection, after
# the scan has read its index), and with no extensions.objectFormat to say
# otherwise its objects are sha1. A mutant that took the missing config for an
# empty format left its submodules unfollowed, and survived every test
# (GAP-2's slice 2; sandbox.sh: `_git_file_config()`).
S110="$TMP/us110"; "${G[@]}" init -q "$S110" && "${G[@]}" -C "$S110" commit -q --allow-empty -m s
M110="$PROJ/main110"; "${G[@]}" init -q "$M110" && "${G[@]}" clone -q "$S110" "$M110/vendor/lib" \
  && "${G[@]}" -C "$M110" add vendor/lib 2>/dev/null && "${G[@]}" -C "$M110" commit -q -m l \
  && rm "$M110/.git/config" || { printf 'SCAFFOLD-FAILED: G110\n'; exit 1; }
launch ..
has_mount "$M110/vendor/lib/.git/config:/workspace/proj/main110/vendor/lib/.git/config:ro" \
  && ! grep -qF "cannot read the index of $M110/.git" "$ERR" \
  && pass "G110 a repository with no config has its index read, its submodules followed" \
  || fail "G110 (stderr: $(grep -F main110 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$S110" "$M110"

# ── G113: a submodule's core.worktree is resolved physically, as git does ───
# git changes into core.worktree and takes its real path, so a `..` after a
# link steps out of where the link leads. `cd` without -P took it lexically:
# with core.worktree = ../../../a/../node_modules/sm and a -> x/y, the index was
# read against node_modules/sm (a decoy the agent can make) instead of
# x/node_modules/sm, and the nested submodule there, under a pruned
# node_modules, kept its config writable (bugs review GIT-32).
M113="$PROJ/m113"; "${G[@]}" init -q "$M113" && mkdir -p "$M113/x/y" "$M113/x/node_modules/sm" "$M113/node_modules/sm" \
  && ln -s x/y "$M113/a" && "${G[@]}" init -q --bare "$M113/.git/modules/sm" \
  && "${G[@]}" config --file "$M113/.git/modules/sm/config" core.bare false \
  && "${G[@]}" config --file "$M113/.git/modules/sm/config" core.worktree ../../../a/../node_modules/sm \
  && "${G[@]}" --git-dir="$M113/.git/modules/sm" --work-tree="$M113/x/node_modules/sm" \
       update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M113/x/node_modules/sm/vendor/n" \
  || { printf 'SCAFFOLD-FAILED: G113\n'; exit 1; }
[[ "$(cd "$M113/.git/modules/sm" && cd -P -- ../../../a/../node_modules/sm && pwd -P)" == "$M113/x/node_modules/sm" ]] \
  || { printf 'SCAFFOLD-FAILED: G113: the physical path is not the real worktree\n'; exit 1; }
launch ..
has_mount "$M113/x/node_modules/sm/vendor/n/.git/config:/workspace/proj/m113/x/node_modules/sm/vendor/n/.git/config:ro" \
  && pass "G113 a submodule's core.worktree through a link is resolved as git resolves it" \
  || fail "G113 core.worktree read lexically (git mounts: $(git_mounts | grep -c m113))"
rm -rf "$M113"
# And `-` is a directory named `-` to git, not cd's previous directory. Its
# nested submodule lies deeper than the scan goes, so only the index finds it.
M113="$PROJ/m113"; "${G[@]}" init -q "$M113" && "${G[@]}" init -q --bare "$M113/.git/modules/sm" \
  && "${G[@]}" config --file "$M113/.git/modules/sm/config" core.bare false \
  && "${G[@]}" config --file "$M113/.git/modules/sm/config" core.worktree - \
  && mkdir -p "$M113/.git/modules/sm/-" \
  && "${G[@]}" --git-dir="$M113/.git/modules/sm" --work-tree="$M113/.git/modules/sm/-" \
       update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M113/.git/modules/sm/-/vendor/n" \
  || { printf 'SCAFFOLD-FAILED: G113 -\n'; exit 1; }
launch ..
has_mount "$M113/.git/modules/sm/-/vendor/n/.git/config:/workspace/proj/m113/.git/modules/sm/-/vendor/n/.git/config:ro" \
  && pass "G113 a core.worktree of - is the directory named -" \
  || fail "G113 core.worktree - (git mounts: $(git_mounts | grep -c m113))"
rm -rf "$M113"
# A repository's own .git: git uses its core.worktree too, so its index is read
# against that as well as against where the .git lies (review of the GIT-31 fix;
# bugs review GIT-33).
M113="$PROJ/m113"; "${G[@]}" init -q "$M113" && mkdir -p "$M113/w2" \
  && "${G[@]}" config --file "$M113/.git/config" core.worktree ../w2 \
  && "${G[@]}" --git-dir="$M113/.git" --work-tree="$M113/w2" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M113/w2/vendor/n" || { printf 'SCAFFOLD-FAILED: G113 .git core.worktree\n'; exit 1; }
launch ..
has_mount "$M113/w2/vendor/n/.git/config:/workspace/proj/m113/w2/vendor/n/.git/config:ro" \
  && pass "G113 a .git directory's own core.worktree is read too" \
  || fail "G113 .git core.worktree ignored (git mounts: $(git_mounts | grep -c m113))"
rm -rf "$M113"
# git also takes it from config.worktree when extensions.worktreeConfig is on,
# and a decoy in config does not replace it (re-review of the GIT-31 fix).
M113="$PROJ/m113"; "${G[@]}" init -q "$M113" && mkdir -p "$M113/w2" "$M113/decoy" \
  && "${G[@]}" config --file "$M113/.git/config" extensions.worktreeConfig true \
  && "${G[@]}" config --file "$M113/.git/config" core.worktree ../decoy \
  && "${G[@]}" config --file "$M113/.git/config.worktree" core.worktree ../w2 \
  && "${G[@]}" --git-dir="$M113/.git" --work-tree="$M113/w2" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M113/w2/vendor/n" || { printf 'SCAFFOLD-FAILED: G113 config.worktree\n'; exit 1; }
launch ..
has_mount "$M113/w2/vendor/n/.git/config:/workspace/proj/m113/w2/vendor/n/.git/config:ro" \
  && pass "G113 a core.worktree in config.worktree is read, a decoy in config beside it" \
  || fail "G113 config.worktree's core.worktree ignored (git mounts: $(git_mounts | grep -c m113))"
rm -rf "$M113"
# Its value is read as git reads it: a trailing newline is part of the path
# ($(...) dropped it, and a decoy without one was read instead).
M113="$PROJ/m113"; nl113=$'\n'; "${G[@]}" init -q "$M113" && mkdir -p "$M113/wt" "$M113/wt$nl113" \
  && "${G[@]}" config --file "$M113/.git/config" core.worktree "../wt$nl113" \
  && "${G[@]}" --git-dir="$M113/.git" --work-tree="$M113/wt$nl113" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M113/wt$nl113/vendor/n" || { printf 'SCAFFOLD-FAILED: G113 newline core.worktree\n'; exit 1; }
launch ..
# The bind's source and destination hold the newline: docker's argument, one per
# line in the capture, ends on a line of its own.
grep -qxF '/vendor/n/.git/config:ro' "$CAPTURE" \
  && pass "G113 a core.worktree ending in a newline is that directory" \
  || fail "G113 core.worktree's newline dropped (git mounts: $(git_mounts | grep -c m113))"
rm -rf "$M113"
# So is a .git file's gitdir: through a link to a git directory whose name ends
# in a newline, beside a decoy without one, both under a pruned node_modules/
# where only the .git file leads: resolved by $(cd; pwd -P), the newline was
# dropped and the decoy protected.
N113="$PROJ/node_modules/x113"
mkdir -p "$PROJ/s113" "$N113" && "${G[@]}" init -q --bare "$N113/gd$nl113" && "${G[@]}" init -q --bare "$N113/gd" \
  && ln -s "gd$nl113" "$N113/lk" && printf 'gitdir: ../node_modules/x113/lk\n' > "$PROJ/s113/.git" \
  || { printf 'SCAFFOLD-FAILED: G113 newline gitdir\n'; exit 1; }
launch ..
grep -qxF '/config:/workspace/proj/node_modules/x113/gd' "$CAPTURE" \
  && pass "G113 a gitdir: through a link to a name ending in a newline is that directory" \
  || fail "G113 gitdir:'s newline dropped (git mounts: $(git_mounts | grep -c x113))"
rm -rf "$PROJ/s113" "$PROJ/node_modules"

# ── G115: an index is read against every worktree git may use ─────────────
# A submodule's git directory took its core.worktree in place of the .git files
# naming it; once the launch's ./ placeholder exists git ignores a core.worktree
# in config and uses the .git file's directory, so a decoy left the real
# checkout's submodules unread. And a linked worktree's core.worktree in
# config.worktree, which git honours with extensions.worktreeConfig, was never
# read (review of the GIT-31 fix; bugs review GIT-36).
M115="$PROJ/m115"; "${G[@]}" init -q "$M115" && mkdir -p "$M115/decoy" "$M115/new" \
  && "${G[@]}" init -q --bare "$M115/.git/modules/new" && "${G[@]}" config --file "$M115/.git/modules/new/config" core.bare false \
  && "${G[@]}" config --file "$M115/.git/modules/new/config" core.worktree ../../../decoy \
  && printf 'gitdir: ../.git/modules/new\n' > "$M115/new/.git" \
  && "${G[@]}" --git-dir="$M115/.git/modules/new" --work-tree="$M115/new" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M115/new/vendor/n" || { printf 'SCAFFOLD-FAILED: G115 module\n'; exit 1; }
launch ..
launch ..
has_mount "$M115/new/vendor/n/.git/config:/workspace/proj/m115/new/vendor/n/.git/config:ro" \
  && pass "G115 a submodule's index is read against the .git file naming it, a decoy core.worktree beside it" \
  || fail "G115 decoy core.worktree replaced the .git file's directory (git mounts: $(git_mounts | grep -c m115))"
rm -rf "$M115"
M115="$PROJ/m115"; "${G[@]}" init -q "$M115" && "${G[@]}" -C "$M115" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M115" config extensions.worktreeConfig true && "${G[@]}" -C "$M115" worktree add -q "$PROJ/wt115" \
  && mkdir -p "$PROJ/w3_115" && "${G[@]}" -C "$PROJ/wt115" config --worktree core.worktree "$PROJ/w3_115" \
  && wt115="$(ls -d "$M115/.git/worktrees"/* | head -1)" \
  && "${G[@]}" --git-dir="$wt115" --work-tree="$PROJ/w3_115" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$PROJ/w3_115/vendor/n" || { printf 'SCAFFOLD-FAILED: G115 worktree\n'; exit 1; }
launch ..
has_mount "$PROJ/w3_115/vendor/n/.git/config:/workspace/proj/w3_115/vendor/n/.git/config:ro" \
  && pass "G115 a linked worktree's core.worktree in config.worktree is read" \
  || fail "G115 a linked worktree's config.worktree core.worktree ignored (git mounts: $(git_mounts | grep -c w3_115))"
rm -rf "$M115" "$PROJ/wt115" "$PROJ/w3_115"
# A .git directory named by a .git file elsewhere: git uses that file's
# directory as the worktree too (review of the GIT-36/37 fix).
M115="$PROJ/m115"; mkdir -p "$M115/sub" && "${G[@]}" init -q "$M115/other" \
  && printf 'gitdir: ../other/.git\n' > "$M115/sub/.git" \
  && "${G[@]}" --git-dir="$M115/other/.git" --work-tree="$M115/sub" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M115/sub/vendor/n" || { printf 'SCAFFOLD-FAILED: G115 .git referrer\n'; exit 1; }
launch ..
has_mount "$M115/sub/vendor/n/.git/config:/workspace/proj/m115/sub/vendor/n/.git/config:ro" \
  && pass "G115 a .git directory's index is read against a .git file naming it, too" \
  || fail "G115 a .git file's directory not read (git mounts: $(git_mounts | grep -c m115))"
rm -rf "$M115"
# A linked worktree takes the common config's core.worktree when
# extensions.worktreeConfig is on, resolved from its own git directory (review
# of the GIT-36/37 fix).
M115="$PROJ/m115"; "${G[@]}" init -q "$M115" && "${G[@]}" -C "$M115" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M115" worktree add -q "$PROJ/wt115" && "${G[@]}" -C "$M115" config extensions.worktreeConfig true \
  && mkdir -p "$PROJ/alt115" && "${G[@]}" config --file "$M115/.git/config" core.worktree "$PROJ/alt115" \
  && wt115="$(ls -d "$M115/.git/worktrees"/* | head -1)" \
  && "${G[@]}" --git-dir="$wt115" --work-tree="$PROJ/alt115" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$PROJ/alt115/vendor/n" || { printf 'SCAFFOLD-FAILED: G115 common core.worktree\n'; exit 1; }
launch ..
has_mount "$PROJ/alt115/vendor/n/.git/config:/workspace/proj/alt115/vendor/n/.git/config:ro" \
  && pass "G115 a linked worktree's index is read against the common config's core.worktree" \
  || fail "G115 the common config's core.worktree ignored for a worktree (git mounts: $(git_mounts | grep -c alt115))"
rm -rf "$M115" "$PROJ/wt115" "$PROJ/alt115"

# ── G96: a sha256 repository's linked worktree has its submodules followed ────
# The worktree's git directory has no config; its object format is in the
# common directory's, which its `commondir` names, relative and ending in a
# newline as git writes it. Read as sha1, a sha256 index does not load, and the
# submodule under the worktree's pruned vendor/ kept a writable .git file (review
# of 3c754aa). G52 is the same shape in sha1, the default, so it cannot tell.
if "${G[@]}" init -q --object-format=sha256 "$TMP/sha96probe" >/dev/null 2>&1; then
  rm -rf "$TMP/sha96probe"
  U96="$TMP/up96"; M96="$PROJ/main96"
  "${G[@]}" init -q --object-format=sha256 "$U96" && "${G[@]}" -C "$U96" commit -q --allow-empty -m u \
    && "${G[@]}" init -q --object-format=sha256 "$M96" \
    && "${G[@]}" -C "$M96" -c protocol.file.allow=always submodule -q add "$U96" vendor/lib \
    && "${G[@]}" -C "$M96" commit -q -m s && "${G[@]}" -C "$M96" worktree add -q "$PROJ/lw96" \
    && "${G[@]}" -C "$PROJ/lw96" -c protocol.file.allow=always submodule -q update --init \
    || { printf 'SCAFFOLD-FAILED: cannot create the G96 sha256 worktree\n'; exit 1; }
  launch ..
  has_mount "$PROJ/lw96/vendor/lib/.git:/workspace/proj/lw96/vendor/lib/.git:ro" \
    && ! grep -qF "cannot read the index of $M96/.git/worktrees" "$ERR" \
    && pass "G96 a submodule of a sha256 repository's linked worktree, under a pruned vendor/, is protected" \
    || fail "G96 sha256 linked worktree (rc=$LAUNCH_RC; stderr: $(grep -F main96 "$ERR" | head -2 | tr '\n' ' '))"
  rm -rf "$U96" "$M96" "$PROJ/lw96"
else
  printf 'SKIP: G96 this git (%s) cannot make a sha256 repository\n' "$(git --version)"
fi

# ── G143: a linked worktree whose gitdir is relative is followed (GIT-53) ────
# Git 2.48 and later write a linked worktree's pointers relative when asked
# (`git worktree add --relative-paths`, worktree.useRelativePaths): gitdir from
# the worktree's git directory, the checkout's .git file from the checkout.
# Written by hand here, so an older git makes the same layout. The checkout
# under a pruned node_modules was reached only through an absolute gitdir: its
# submodule stayed writable, with "no worktree is known".
U143="$TMP/up143"; "${G[@]}" init -q "$U143" && "${G[@]}" -C "$U143" commit -q --allow-empty -m u \
  && "${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/rw143" -b rw143 \
  && "${G[@]}" clone -q "$U143" "$PROJ/node_modules/rw143/sub" && "${G[@]}" -C "$PROJ/node_modules/rw143" add sub 2>/dev/null \
  && "${G[@]}" -C "$PROJ/node_modules/rw143" commit -q -m n \
  && printf '../../../node_modules/rw143/.git\n' > "$PROJ/.git/worktrees/rw143/gitdir" \
  && printf 'gitdir: ../../.git/worktrees/rw143\n' > "$PROJ/node_modules/rw143/.git" \
  || { printf 'SCAFFOLD-FAILED: G143\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/node_modules/rw143/sub/.git/config:/workspace/proj/node_modules/rw143/sub/.git/config:ro" \
  && ! grep -qF "no worktree is known for $PROJ/.git/worktrees/rw143" "$ERR" \
  && pass "G143 a linked worktree's relative gitdir leads to its checkout, whose submodule is protected" \
  || fail "G143 relative gitdir (rc=$LAUNCH_RC; stderr: $(grep -F rw143 "$ERR" | head -2 | tr '\n' ' '))"
# Its checkout outside every writable mount, pointing back, both pointers
# relative as git writes them: quiet, as with absolute pointers.
mv "$PROJ/node_modules/rw143" "$TMP/rw143" \
  && printf '../../../../rw143/.git\n' > "$PROJ/.git/worktrees/rw143/gitdir" \
  && printf 'gitdir: ../proj/.git/worktrees/rw143\n' > "$TMP/rw143/.git" \
  || { printf 'SCAFFOLD-FAILED: G143 outside\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "no worktree is known for $PROJ/.git/worktrees/rw143" "$ERR" \
  && pass "G143 one whose relative gitdir names a checkout outside every mount that points back is quiet" \
  || fail "G143 relative gitdir, outside (rc=$LAUNCH_RC; stderr: $(grep -F rw143 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/rw143" "$U143" "$PROJ/.git/worktrees/rw143"
"${G[@]}" -C "$PROJ" branch -q -D rw143

# GAP-2 slice 6: G145 to G147 hold conditions of git_dirs_in that, turned,
# survived every test.
U14x="$TMP/up14x"; "${G[@]}" init -q "$U14x" && "${G[@]}" -C "$U14x" commit -q --allow-empty -m u \
  || { printf 'SCAFFOLD-FAILED: G145\n'; exit 1; }
# ── G145: the walk up from a mount to the repository it lies in ─────────────
# A .git above the mount that git does not take for a repository gets nothing
# made in it, in another writable mount past that mount's scan too.
mkdir -p "$TMP/n145/node_modules/y/.git" "$TMP/n145/node_modules/y/z"
EXTRA_MOUNTS="$TMP/n145" launch "$TMP/n145/node_modules/y/z"
[[ "$LAUNCH_RC" == 0 && ! -e "$TMP/n145/node_modules/y/.git/commondir" ]] && ! grep -qF "node_modules/y/.git" < <(mounts) \
  && pass "G145 a .git above the mount that is no repository gets nothing made in it" \
  || fail "G145 non-git .git above (rc=$LAUNCH_RC; in it: $(ls -A "$TMP/n145/node_modules/y/.git" | tr '\n' ' '))"
rm -rf "$TMP/n145"
# A .git FILE above the mount is followed: the git directory it names has its
# index read, and a submodule in the mount under a pruned vendor/ is protected.
"${G[@]}" init -q --separate-git-dir "$TMP/gd145" "$TMP/f145/w" && mkdir -p "$TMP/f145/w/sub/vendor" \
  && "${G[@]}" clone -q "$U14x" "$TMP/f145/w/sub/vendor/sm" && "${G[@]}" -C "$TMP/f145/w" add sub/vendor/sm 2>/dev/null \
  || { printf 'SCAFFOLD-FAILED: G145 .git file\n'; exit 1; }
launch "$TMP/f145/w/sub"
has_mount "$TMP/f145/w/sub/vendor/sm/.git/config:/workspace/sub/vendor/sm/.git/config:ro" \
  && pass "G145 a .git file above the mount is followed to the index of the git directory it names" \
  || fail "G145 .git file above (rc=$LAUNCH_RC; git mounts: $(git_mounts | tr '\n' ' '))"
# That index unreadable: quiet where the git directory is outside every writable
# mount (yours), named where the agent can write it.
cp "$TMP/gd145/index" "$TMP/gd145.idx" && printf 'garbage' > "$TMP/gd145/index"
launch "$TMP/f145/w/sub"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index of $TMP/gd145" "$ERR" \
  && pass "G145 its unreadable index, outside every writable mount, is not named" \
  || fail "G145 quiet outside (rc=$LAUNCH_RC; $(grep -F gd145 "$ERR" | head -1))"
EXTRA_MOUNTS="$TMP/gd145" launch "$TMP/f145/w/sub"
grep -qF "cannot read the index of $TMP/gd145" "$ERR" \
  && pass "G145 its unreadable index, in a writable mount, is named" \
  || fail "G145 named in a writable mount (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/f145" "$TMP/gd145" "$TMP/gd145.idx"
# The repository two levels above the mount is reached, past a dangling .git
# link between, which git passes over too.
"${G[@]}" init -q "$TMP/r145" && mkdir -p "$TMP/r145/a/b/vendor" && "${G[@]}" clone -q "$U14x" "$TMP/r145/a/b/vendor/sm" \
  && "${G[@]}" -C "$TMP/r145" add a/b/vendor/sm 2>/dev/null || { printf 'SCAFFOLD-FAILED: G145 two up\n'; exit 1; }
launch "$TMP/r145/a/b"
has_mount "$TMP/r145/a/b/vendor/sm/.git/config:/workspace/b/vendor/sm/.git/config:ro" \
  && pass "G145 the repository two levels above the mount is read" \
  || fail "G145 two levels up (rc=$LAUNCH_RC; git mounts: $(git_mounts | tr '\n' ' '))"
ln -s "$TMP/nothing145" "$TMP/r145/a/.git"
launch "$TMP/r145/a/b"
has_mount "$TMP/r145/a/b/vendor/sm/.git/config:/workspace/b/vendor/sm/.git/config:ro" \
  && pass "G145 ... and past a dangling .git link between" \
  || fail "G145 past a dangling link (rc=$LAUNCH_RC; git mounts: $(git_mounts | tr '\n' ' '))"
rm -rf "$TMP/r145"
# A .git link above the mount, outside every writable mount, to a directory in
# the mount that is no git directory: nothing made there, and its index-named
# file not read.
mkdir -p "$TMP/l145/m/plain" && printf x > "$TMP/l145/m/plain/f" && printf garbage > "$TMP/l145/m/plain/index" \
  && ln -s "$TMP/l145/m/plain" "$TMP/l145/.git"
launch "$TMP/l145/m"
[[ "$LAUNCH_RC" == 0 && ! -e "$TMP/l145/m/plain/commondir" ]] && ! grep -qF "/workspace/m/plain" < <(mounts) \
  && ! grep -qF "l145/m/plain" "$ERR" \
  && pass "G145 a .git link above the mount to a directory that is no repository is passed over" \
  || fail "G145 link to a non-git directory (rc=$LAUNCH_RC; in it: $(ls "$TMP/l145/m/plain" | tr '\n' ' '); $(grep -F plain "$ERR" | head -1))"
rm -rf "$TMP/l145"
# The walk stops at a .git link it followed: the repository above is not judged,
# and its core.hooksPath into the mount is not named.
"${G[@]}" init -q "$TMP/o145" && "${G[@]}" -C "$TMP/o145" config core.hooksPath i/sub/hooks \
  && "${G[@]}" init -q --bare "$TMP/gl145" && mkdir -p "$TMP/o145/i/sub/hooks" && ln -s "$TMP/gl145" "$TMP/o145/i/.git" \
  || { printf 'SCAFFOLD-FAILED: G145 link\n'; exit 1; }
launch "$TMP/o145/i/sub"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/o145/.git" "$ERR" \
  && pass "G145 the repository above a .git link the walk followed is not judged" \
  || fail "G145 above a link (rc=$LAUNCH_RC; $(grep -F "$TMP/o145/.git" "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/o145" "$TMP/gl145"

# ── G146: a linked worktree's checkout, found through its gitdir ─────────────
# Under a pruned node_modules the gitdir alone reaches the checkout, whose
# submodule is protected.
"${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/aw146" -b aw146 \
  && "${G[@]}" clone -q "$U14x" "$PROJ/node_modules/aw146/sub" && "${G[@]}" -C "$PROJ/node_modules/aw146" add sub 2>/dev/null \
  && "${G[@]}" -C "$PROJ/node_modules/aw146" commit -q -m n || { printf 'SCAFFOLD-FAILED: G146\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/aw146/sub/.git/config:/workspace/proj/node_modules/aw146/sub/.git/config:ro" \
  && ! grep -qF "no worktree is known for $PROJ/.git/worktrees/aw146" "$ERR" \
  && pass "G146 a linked worktree's checkout under a pruned directory is reached through gitdir" \
  || fail "G146 checkout through gitdir (rc=$LAUNCH_RC; $(grep -F aw146 "$ERR" | head -2 | tr '\n' ' '))"
# ... and its .git file, which the scan does not reach either, is read-only:
# writable, the agent could point it at a repository of its own (GIT-58).
has_mount "$PROJ/node_modules/aw146/.git:/workspace/proj/node_modules/aw146/.git:ro" \
  && pass "G146 that checkout's .git file is read-only" \
  || fail "G146 checkout .git file left writable (rc=$LAUNCH_RC; $(mounts | grep -F 'aw146/.git:' | tr '\n' ' '))"
# A gitdir rewritten to name a directory in the mount whose .git does not point
# back is no checkout: the real one is not reached, and that is said (GIT-57).
# Rewritten before any launch bound the real checkout's .git file, that is: one
# a launch bound is in its record, and found again from there (GIT-105).
cp "$PROJ/.git/worktrees/aw146/gitdir" "$TMP/gitdir146" && printf '%s/.git/worktrees/.git\n' "$PROJ" > "$PROJ/.git/worktrees/aw146/gitdir"
launch ..
has_mount "$PROJ/node_modules/aw146/.git:/workspace/proj/node_modules/aw146/.git:ro" \
  && ! grep -qF "no worktree is known for $PROJ/.git/worktrees/aw146" "$ERR" \
  && pass "G146 the checkout's .git file a launch bound is found again from the record, whatever gitdir says" \
  || fail "G146 the recorded .git file (rc=$LAUNCH_RC; $(mounts | grep -cF 'aw146/.git:') binds; $(grep -F WARNING "$ERR" | head -1))"
rec146="$HOME/.ai-containers/git-reported.conf"
grep -vF " file:$PROJ/node_modules/aw146/.git" "$rec146" > "$rec146.146"; mv "$rec146.146" "$rec146"
launch ..
grep -qF "no worktree is known for $PROJ/.git/worktrees/aw146" "$ERR" \
  && pass "G146 a gitdir naming a directory that does not point back silences nothing" \
  || fail "G146 decoy gitdir in the mount (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
cp "$TMP/gitdir146" "$PROJ/.git/worktrees/aw146/gitdir"; rm -f "$TMP/gitdir146"
# A submodule recorded at a path that is a link: named once, though the checkout
# is reached through gitdir and its .git file is followed too (it is the same
# referrer, and the index is read once).
mkdir -p "$PROJ/node_modules/aw146/real146" && ln -s real146 "$PROJ/node_modules/aw146/s146" \
  && "${G[@]}" -C "$PROJ/node_modules/aw146" update-index --add --cacheinfo "160000,$(printf '%040d' 1),s146" \
  || { printf 'SCAFFOLD-FAILED: G146 link gitlink\n'; exit 1; }
launch ..
[[ "$(grep -c "submodule $PROJ/node_modules/aw146/s146 of $PROJ/.git/worktrees/aw146 is not where its index says" "$ERR")" == 1 ]] \
  && pass "G146 its index is read once, the checkout reached through gitdir and its .git file alike" \
  || fail "G146 read twice ($(grep -c 'aw146/s146' "$ERR") WARNINGs)"
"${G[@]}" -C "$PROJ/node_modules/aw146" rm -q --cached s146 >/dev/null 2>&1; rm -rf "$PROJ/node_modules/aw146/s146" "$PROJ/node_modules/aw146/real146"
# Its .git rewritten, in an earlier session, to name a repository of the agent's:
# no longer a checkout of this worktree, but bound read-only and followed all the
# same, so the repository it names is protected too.
cp "$PROJ/node_modules/aw146/.git" "$TMP/dotgit146" && "${G[@]}" init -q --bare "$PROJ/node_modules/evil146" \
  && printf 'gitdir: %s\n' "$PROJ/node_modules/evil146" > "$PROJ/node_modules/aw146/.git" \
  || { printf 'SCAFFOLD-FAILED: G146 rewritten\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/aw146/.git:/workspace/proj/node_modules/aw146/.git:ro" \
  && has_mount "$PROJ/node_modules/evil146/hooks:/workspace/proj/node_modules/evil146/hooks:ro" \
  && pass "G146 a checkout's .git that names another repository is read-only, and that repository protected" \
  || fail "G146 rewritten .git (rc=$LAUNCH_RC; $(mounts | grep -E 'aw146/.git|evil146' | tr '\n' ' '))"
# ... and one made a link is named.
mv "$PROJ/node_modules/aw146/.git" "$PROJ/node_modules/aw146/.gitfile" && ln -s .gitfile "$PROJ/node_modules/aw146/.git"
launch ..
grep -qF "WARNING: $PROJ/node_modules/aw146/.git is a symlink inside a writable mount" "$ERR" \
  && pass "G146 a checkout's .git made a link is named" \
  || fail "G146 linked .git (rc=$LAUNCH_RC; $(grep -F 'aw146/.git' "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$PROJ/node_modules/aw146/.git" "$PROJ/node_modules/aw146/.gitfile"
# ... and one replaced by a repository of the agent's is protected as a .git
# directory the scan finds.
"${G[@]}" init -q "$PROJ/node_modules/aw146" >/dev/null 2>&1 && [[ -d "$PROJ/node_modules/aw146/.git" ]] \
  || { printf 'SCAFFOLD-FAILED: G146 .git directory\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/aw146/.git/config:/workspace/proj/node_modules/aw146/.git/config:ro" \
  && has_mount "$PROJ/node_modules/aw146/.git/hooks:/workspace/proj/node_modules/aw146/.git/hooks:ro" \
  && pass "G146 a checkout's .git replaced by a repository is protected as one" \
  || fail "G146 .git directory (rc=$LAUNCH_RC; $(mounts | grep -F 'aw146/.git' | tr '\n' ' '))"
rm -rf "$PROJ/node_modules/aw146/.git"; cp "$TMP/dotgit146" "$PROJ/node_modules/aw146/.git"
# A core.worktree the agent writes in the worktree's git directory, where git
# never reads one, names the checkout too: its .git is taken all the same.
printf '[core]\n\tworktree = %s\n' "$PROJ/node_modules/aw146" > "$PROJ/.git/worktrees/aw146/config"
launch ..
has_mount "$PROJ/node_modules/aw146/.git:/workspace/proj/node_modules/aw146/.git:ro" \
  && pass "G146 a checkout a planted core.worktree also names keeps its .git read-only" \
  || fail "G146 core.worktree pre-claims the checkout (rc=$LAUNCH_RC; $(mounts | grep -F 'aw146/.git' | tr '\n' ' '))"
rm -f "$PROJ/.git/worktrees/aw146/config"
rm -rf "$TMP/dotgit146" "$PROJ/node_modules/evil146"
"${G[@]}" -C "$PROJ" worktree remove --force "$PROJ/node_modules/aw146"; "${G[@]}" -C "$PROJ" branch -q -D aw146
# A checkout deleted and never pruned, inside the mount, is no worktree to read
# against: its index is not read there, so no "cannot read the index". (Its index
# recording no submodule, nothing else is said either; with one, the launch says
# "no worktree is known", a false warning, bugs review GIT-54.)
"${G[@]}" -C "$PROJ" worktree add -q "$PROJ/gone146" -b gone146 && rm -rf "$PROJ/gone146" || { printf 'SCAFFOLD-FAILED: G146 gone\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$PROJ/.git/worktrees/gone146" "$ERR" \
  && pass "G146 a worktree whose checkout was deleted is not read against it, so not warned about" \
  || fail "G146 prunable (rc=$LAUNCH_RC; $(grep -F gone146 "$ERR" | head -2 | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" worktree prune; "${G[@]}" -C "$PROJ" branch -q -D gone146
# A common config whose core.worktree is set and empty gives a linked worktree
# no checkout either: the git directory itself is not read against, its index
# unread, so nothing is said of it.
R146="$PROJ/r146"; "${G[@]}" init -q "$R146" && "${G[@]}" -C "$R146" commit -q --allow-empty -m r \
  && "${G[@]}" -C "$R146" worktree add -q "$PROJ/w146" -b w146 && rm -rf "$PROJ/w146" \
  && printf 'garbage' > "$R146/.git/worktrees/w146/index" && "${G[@]}" config --file "$R146/.git/config" core.worktree "" \
  || { printf 'SCAFFOLD-FAILED: G146 empty core.worktree\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$R146/.git/worktrees/w146" "$ERR" \
  && pass "G146 an empty core.worktree in the common config gives a linked worktree no checkout" \
  || fail "G146 empty core.worktree (rc=$LAUNCH_RC; $(grep -F w146 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$R146"
# A gitdir naming a checkout outside every mount whose .git does not name it
# back (rewritten, or a decoy) does not make the worktree quiet.
"${G[@]}" -C "$PROJ" worktree add -q "$TMP/wt146" -b wt146 && "${G[@]}" clone -q "$U14x" "$TMP/wt146/sub" \
  && "${G[@]}" -C "$TMP/wt146" add sub 2>/dev/null && "${G[@]}" -C "$TMP/wt146" commit -q -m n \
  && printf 'gitdir: %s\n' "$TMP/elsewhere146" > "$TMP/wt146/.git" || { printf 'SCAFFOLD-FAILED: G146 decoy\n'; exit 1; }
launch ..
grep -qF "no worktree is known for $PROJ/.git/worktrees/wt146" "$ERR" \
  && pass "G146 a checkout outside every mount that does not point back leaves the worktree named" \
  || fail "G146 decoy outside (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/wt146" "$PROJ/.git/worktrees/wt146"; "${G[@]}" -C "$PROJ" branch -q -D wt146
# Nor does one whose .git is a link to a file naming it back: quiet only for a
# regular .git file, since where a link leads is not judged here.
"${G[@]}" -C "$PROJ" worktree add -q "$TMP/wl146" -b wl146 && "${G[@]}" clone -q "$U14x" "$TMP/wl146/sub" \
  && "${G[@]}" -C "$TMP/wl146" add sub 2>/dev/null && "${G[@]}" -C "$TMP/wl146" commit -q -m n \
  && mv "$TMP/wl146/.git" "$TMP/gf146" && ln -s "$TMP/gf146" "$TMP/wl146/.git" || { printf 'SCAFFOLD-FAILED: G146 link\n'; exit 1; }
launch ..
grep -qF "no worktree is known for $PROJ/.git/worktrees/wl146" "$ERR" \
  && pass "G146 a checkout outside every mount whose .git is a link back leaves the worktree named" \
  || fail "G146 linked .git outside (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/wl146" "$TMP/gf146" "$PROJ/.git/worktrees/wl146"; "${G[@]}" -C "$PROJ" branch -q -D wl146

# ── G152: a linked worktree's checkout in another writable mount ─────────────
# A worktree of the primary's repository checked out in an EXTRA_MOUNTS
# directory, under its pruned node_modules: no scan reaches the checkout, and
# only the worktree's gitdir names it. Its .git was left writable in that
# mount's view, for the agent to point at a repository of its own, whose hooks
# your host's git would then run there (GIT-59).
O152="$TMP/o152"; mkdir -p "$O152/node_modules" \
  && "${G[@]}" -C "$PROJ" worktree add -q "$O152/node_modules/aw152" -b aw152 \
  || { printf 'SCAFFOLD-FAILED: G152\n'; exit 1; }
v152=/workspace/o152/node_modules
EXTRA_MOUNTS="$O152" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O152/node_modules/aw152/.git:$v152/aw152/.git:ro" \
  && pass "G152 a linked worktree's checkout in another writable mount has its .git read-only there" \
  || fail "G152 checkout in another mount (rc=$LAUNCH_RC; $(mounts | grep -F 'aw152' | tr '\n' ' '))"
# Its .git rewritten, in an earlier session, to name a repository of the agent's
# in that mount: read-only, and that repository protected there too.
cp "$O152/node_modules/aw152/.git" "$TMP/dotgit152" && "${G[@]}" init -q --bare "$O152/node_modules/evil152" \
  && printf 'gitdir: %s\n' "$O152/node_modules/evil152" > "$O152/node_modules/aw152/.git" \
  || { printf 'SCAFFOLD-FAILED: G152 rewritten\n'; exit 1; }
EXTRA_MOUNTS="$O152" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O152/node_modules/aw152/.git:$v152/aw152/.git:ro" \
  && has_mount "$O152/node_modules/evil152/hooks:$v152/evil152/hooks:ro" \
  && pass "G152 that .git naming another repository is read-only, and the repository protected" \
  || fail "G152 rewritten .git (rc=$LAUNCH_RC; $(mounts | grep -E 'aw152/.git|evil152' | tr '\n' ' '))"
rm -rf "$O152/node_modules/evil152"
# ... made a link: named.
mv "$O152/node_modules/aw152/.git" "$O152/node_modules/aw152/.gitfile" && ln -s .gitfile "$O152/node_modules/aw152/.git"
EXTRA_MOUNTS="$O152" launch ..
grep -qF "WARNING: $O152/node_modules/aw152/.git is a symlink inside a writable mount" "$ERR" \
  && pass "G152 that .git made a link is named" \
  || fail "G152 linked .git (rc=$LAUNCH_RC; $(grep -F 'aw152/.git' "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$O152/node_modules/aw152/.git" "$O152/node_modules/aw152/.gitfile"
# ... and replaced by a repository: protected as one, in that mount's view.
"${G[@]}" init -q "$O152/node_modules/aw152" >/dev/null 2>&1 && [[ -d "$O152/node_modules/aw152/.git" ]] \
  || { printf 'SCAFFOLD-FAILED: G152 .git directory\n'; exit 1; }
EXTRA_MOUNTS="$O152" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O152/node_modules/aw152/.git/config:$v152/aw152/.git/config:ro" \
  && has_mount "$O152/node_modules/aw152/.git/hooks:$v152/aw152/.git/hooks:ro" \
  && pass "G152 that .git replaced by a repository is protected as one" \
  || fail "G152 .git directory (rc=$LAUNCH_RC; $(mounts | grep -F 'aw152/.git' | tr '\n' ' '))"
rm -rf "$O152/node_modules/aw152/.git"; cp "$TMP/dotgit152" "$O152/node_modules/aw152/.git"; rm -f "$TMP/dotgit152"
"${G[@]}" -C "$PROJ" worktree remove --force "$O152/node_modules/aw152" 2>/dev/null
rm -rf "$O152" "$PROJ/.git/worktrees/aw152"; "${G[@]}" -C "$PROJ" branch -q -D aw152 2>/dev/null

# ── G153: a directory the agent made unsearchable on the way to a checkout ───
# The agent owns the directories it can write and can `chmod 000` one in a
# session. Where the scan looks for unlistable directories it finds that one and
# binds it read-only whole; under a pruned name it does not look, and a checkout
# reached only through a pointer (a worktree's gitdir, an index's gitlink, a
# submodule's core.worktree) behind it was neither bound nor named. In the next
# session the agent could restore the mode and point that checkout's .git at a
# repository of its own (GIT-60). The first directory on the way that you cannot
# search is now bound read-only whole, with the chmod that restores it named.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$PROJ/node_modules" && "${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/aw153" -b aw153 \
    || { printf 'SCAFFOLD-FAILED: G153\n'; exit 1; }
  chmod 000 "$PROJ/node_modules"; launch ..; chmod 755 "$PROJ/node_modules"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/node_modules:/workspace/proj/node_modules:ro" \
    && grep -qF "WARNING: $PROJ/node_modules cannot be listed by you" "$ERR" \
    && pass "G153 a pruned directory made unsearchable before a worktree's checkout is read-only whole, and named" \
    || fail "G153 unsearchable node_modules (rc=$LAUNCH_RC; $(mounts | grep -F node_modules | tr '\n' ' '); $(grep -F node_modules "$ERR" | head -2 | tr '\n' ' '))"
  # ... and the checkout itself made unsearchable.
  chmod 000 "$PROJ/node_modules/aw153"; launch ..; chmod 755 "$PROJ/node_modules/aw153"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/node_modules/aw153:/workspace/proj/node_modules/aw153:ro" \
    && pass "G153 a worktree's checkout made unsearchable is read-only whole" \
    || fail "G153 unsearchable checkout (rc=$LAUNCH_RC; $(mounts | grep -F aw153 | tr '\n' ' '); $(grep -F aw153 "$ERR" | head -2 | tr '\n' ' '))"
  # With an agent of another uid and gid, a directory of yours with no bits for
  # anyone still counts: on a share that remaps ownership (Docker Desktop,
  # Colima) what the agent made shows up as yours (LNCH-25). Another user's
  # directory the agent cannot enter is left alone: T25j in
  # tests/test-launcher-dir-ro.sh, since no unprivileged test can make one.
  chmod 000 "$PROJ/node_modules"; SANDBOX_UID=4242 SANDBOX_GID=4242 launch ..; chmod 755 "$PROJ/node_modules"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/node_modules:/workspace/proj/node_modules:ro" \
    && pass "G153 a directory of yours is read-only whole under another agent uid too (LNCH-25)" \
    || fail "G153 a directory out of the agent's reach (rc=$LAUNCH_RC; $(mounts | grep -F node_modules | tr '\n' ' '))"
  "${G[@]}" -C "$PROJ" worktree remove --force "$PROJ/node_modules/aw153" 2>/dev/null
  rm -rf "$PROJ/node_modules/aw153" "$PROJ/.git/worktrees/aw153"; "${G[@]}" -C "$PROJ" branch -q -D aw153 2>/dev/null
  # G22's embedded submodule, which only the index records, with vendor/ made
  # unsearchable: GIT-3's WARNING fired only for the checkout itself.
  [[ -d "$PROJ/vendor/emb/.git" ]] || { printf 'SCAFFOLD-FAILED: G153 needs G22'\''s vendor/emb\n'; exit 1; }
  chmod 000 "$PROJ/vendor"; launch ..; chmod 755 "$PROJ/vendor"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/vendor:/workspace/proj/vendor:ro" \
    && pass "G153 a pruned directory made unsearchable before a submodule the index records is read-only whole" \
    || fail "G153 unsearchable vendor (rc=$LAUNCH_RC; $(mounts | grep -F vendor | tr '\n' ' '); $(grep -F vendor "$ERR" | head -2 | tr '\n' ' '))"
  # ... and that submodule's checkout itself made unsearchable: read-only whole,
  # where GIT-3's WARNING said it was not protected.
  chmod 000 "$PROJ/vendor/emb"; launch ..; chmod 755 "$PROJ/vendor/emb"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/vendor/emb:/workspace/proj/vendor/emb:ro" \
    && ! grep -qF "submodule $PROJ/vendor/emb of $PROJ/.git is not where its index says" "$ERR" \
    && pass "G153 a submodule's checkout made unsearchable is read-only whole" \
    || fail "G153 unsearchable submodule checkout (rc=$LAUNCH_RC; $(mounts | grep -F vendor/emb | tr '\n' ' '); $(grep -F vendor/emb "$ERR" | head -2 | tr '\n' ' '))"
  # An absorbed submodule under a pruned target/, recorded in no index, reached
  # only through its core.worktree, with target/ made unsearchable.
  U153="$TMP/up153"; "${G[@]}" init -q "$U153" && "${G[@]}" -C "$U153" commit -q --allow-empty -m u \
    && "${G[@]}" -C "$PROJ" -c protocol.file.allow=always submodule add -q "$U153" target/sm153 >/dev/null 2>&1 \
    && [[ -f "$PROJ/target/sm153/.git" ]] && "${G[@]}" -C "$PROJ" rm -q --cached target/sm153 >/dev/null \
    || { printf 'SCAFFOLD-FAILED: G153 absorbed\n'; exit 1; }
  chmod 000 "$PROJ/target"; launch ..; chmod 755 "$PROJ/target"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/target:/workspace/proj/target:ro" \
    && pass "G153 a pruned directory made unsearchable before an absorbed submodule's checkout is read-only whole" \
    || fail "G153 unsearchable target (rc=$LAUNCH_RC; $(mounts | grep -F target | tr '\n' ' '); $(grep -F target "$ERR" | head -2 | tr '\n' ' '))"
  "${G[@]}" -C "$PROJ" rm -q --cached .gitmodules >/dev/null 2>&1
  rm -rf "$PROJ/target" "$PROJ/.git/modules/target" "$PROJ/.gitmodules" "$U153"
else
  printf 'NOTE: run as root, which searches any directory; G153 is not applicable\n'
fi

# ── G154: a decoy names a checkout's .git directory first ────────────────────
# A linked worktree's checkout under a pruned node_modules whose .git an earlier
# session replaced by a directory, its HEAD moved aside so that it is no git
# directory, never protected. A decoy .git file in the scan's reach naming it
# marked it seen with a warning that it is not a git directory, and the
# worktree's gitdir then skipped it, where the scan protects any .git directory
# whatever it holds (GIT-61). So does a planted .git/worktrees/<x>/commondir
# naming it, its objects/ moved aside.
"${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/aw154" -b aw154 \
  && cp "$PROJ/node_modules/aw154/.git" "$TMP/dotgit154" && rm -f "$PROJ/node_modules/aw154/.git" \
  && "${G[@]}" init -q "$PROJ/node_modules/aw154" >/dev/null 2>&1 \
  && mv "$PROJ/node_modules/aw154/.git/HEAD" "$PROJ/node_modules/aw154/.git/HEAD.aside" \
  && mkdir -p "$PROJ/dec154" && printf 'gitdir: %s\n' "$PROJ/node_modules/aw154/.git" > "$PROJ/dec154/.git" \
  || { printf 'SCAFFOLD-FAILED: G154\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/node_modules/aw154/.git/config:/workspace/proj/node_modules/aw154/.git/config:ro" \
  && has_mount "$PROJ/node_modules/aw154/.git/hooks:/workspace/proj/node_modules/aw154/.git/hooks:ro" \
  && pass "G154 a checkout's .git directory a decoy .git file names first is protected all the same" \
  || fail "G154 decoy .git file first (rc=$LAUNCH_RC; $(mounts | grep -F 'aw154/.git' | tr '\n' ' '); $(grep -F aw154 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/dec154"
# ... and one a planted worktree's commondir names, its objects/ moved aside: as
# a common directory, it needs only objects/ and refs/.
rm -rf "$PROJ/node_modules/aw154/.git"; "${G[@]}" init -q "$PROJ/node_modules/aw154" >/dev/null 2>&1 \
  && mv "$PROJ/node_modules/aw154/.git/objects" "$PROJ/node_modules/aw154/.git/objects.aside" \
  && mkdir -p "$PROJ/.git/worktrees/x154" && printf '%s\n' "$PROJ/node_modules/aw154/.git" > "$PROJ/.git/worktrees/x154/commondir" \
  && printf 'ref: refs/heads/x154\n' > "$PROJ/.git/worktrees/x154/HEAD" \
  || { printf 'SCAFFOLD-FAILED: G154 commondir\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $PROJ/.git/worktrees/x154/commondir sends git to" "$ERR" \
  && pass "G154 a planted worktree's commondir naming another repository refuses the launch" \
  || fail "G154 decoy commondir first (rc=$LAUNCH_RC; $(mounts | grep -F 'aw154/.git' | tr '\n' ' '); $(grep -F aw154 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/.git/worktrees/x154" "$PROJ/node_modules/aw154/.git"; cp "$TMP/dotgit154" "$PROJ/node_modules/aw154/.git"; rm -f "$TMP/dotgit154"
"${G[@]}" -C "$PROJ" worktree remove --force "$PROJ/node_modules/aw154" 2>/dev/null
rm -rf "$PROJ/node_modules/aw154" "$PROJ/.git/worktrees/aw154"; "${G[@]}" -C "$PROJ" branch -q -D aw154 2>/dev/null
# An embedded submodule's .git directory the index records, its HEAD moved
# aside: protected as the scan protects any .git directory, not skipped for
# being no git directory.
U154="$TMP/up154"; "${G[@]}" init -q "$U154" && "${G[@]}" -C "$U154" commit -q --allow-empty -m u \
  && "${G[@]}" clone -q "$U154" "$PROJ/vendor/em154" && "${G[@]}" -C "$PROJ" add vendor/em154 2>/dev/null \
  && mv "$PROJ/vendor/em154/.git/HEAD" "$PROJ/vendor/em154/.git/HEAD.aside" \
  || { printf 'SCAFFOLD-FAILED: G154 embedded\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/vendor/em154/.git/config:/workspace/proj/vendor/em154/.git/config:ro" \
  && pass "G154 an embedded submodule's .git directory with no HEAD is protected" \
  || fail "G154 embedded .git with no HEAD (rc=$LAUNCH_RC; $(mounts | grep -F 'em154' | tr '\n' ' '))"
mv "$PROJ/vendor/em154/.git/HEAD.aside" "$PROJ/vendor/em154/.git/HEAD"
"${G[@]}" -C "$PROJ" rm -q --cached vendor/em154 >/dev/null 2>&1; rm -rf "$PROJ/vendor/em154" "$U154"

# ── G155: the walk up from a mount, as git walks it ──────────────────────────
# Outside every writable mount, so a layout of your own: a .git that is a link
# to a regular file is a .git file to git, and a .git directory that is no git
# directory is passed over, git going on up (GIT-52). The walk took neither: it
# passed over the link, and stopped at the directory, judging the wrong
# repository or none.
U155="$TMP/up155"; "${G[@]}" init -q "$U155" && "${G[@]}" -C "$U155" commit -q --allow-empty -m u \
  || { printf 'SCAFFOLD-FAILED: G155\n'; exit 1; }
# A .git directory that is no git directory between the mount and the repository.
"${G[@]}" init -q "$TMP/r155" && mkdir -p "$TMP/r155/a/b/vendor" "$TMP/r155/a/.git" \
  && "${G[@]}" clone -q "$U155" "$TMP/r155/a/b/vendor/sm" && "${G[@]}" -C "$TMP/r155" add a/b/vendor/sm 2>/dev/null \
  || { printf 'SCAFFOLD-FAILED: G155 two up\n'; exit 1; }
# The premise: git takes $TMP/r155's repository there.
[[ "$("${G[@]}" -C "$TMP/r155/a/b" rev-parse --absolute-git-dir 2>/dev/null)" == "$TMP/r155/.git" ]] \
  || { printf 'SCAFFOLD-FAILED: G155 git does not pass over the empty .git\n'; exit 1; }
launch "$TMP/r155/a/b"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$TMP/r155/a/b/vendor/sm/.git/config:/workspace/b/vendor/sm/.git/config:ro" \
  && [[ -z "$(ls -A "$TMP/r155/a/.git")" ]] \
  && pass "G155 a .git directory that is no git directory is passed over, as git passes over it" \
  || fail "G155 non-git .git between (rc=$LAUNCH_RC; git mounts: $(git_mounts | tr '\n' ' '))"
rm -rf "$TMP/r155"
# A .git that is a link to a regular file, which names the git directory.
"${G[@]}" init -q --separate-git-dir "$TMP/gd155" "$TMP/l155/w" && mkdir -p "$TMP/l155/w/sub/vendor" \
  && "${G[@]}" clone -q "$U155" "$TMP/l155/w/sub/vendor/sm" && "${G[@]}" -C "$TMP/l155/w" add sub/vendor/sm 2>/dev/null \
  && mv "$TMP/l155/w/.git" "$TMP/gf155" && ln -s "$TMP/gf155" "$TMP/l155/w/.git" \
  || { printf 'SCAFFOLD-FAILED: G155 link to a file\n'; exit 1; }
[[ "$("${G[@]}" -C "$TMP/l155/w/sub" rev-parse --absolute-git-dir 2>/dev/null)" == "$TMP/gd155" ]] \
  || { printf 'SCAFFOLD-FAILED: G155 git does not read the linked .git file\n'; exit 1; }
launch "$TMP/l155/w/sub"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$TMP/l155/w/sub/vendor/sm/.git/config:/workspace/sub/vendor/sm/.git/config:ro" \
  && pass "G155 a .git above the mount that links to a .git file is followed, as git follows it" \
  || fail "G155 link to a .git file (rc=$LAUNCH_RC; git mounts: $(git_mounts | tr '\n' ' '))"
rm -rf "$TMP/l155" "$TMP/gd155" "$TMP/gf155" "$U155"

# ── G156: "no worktree is known", only where none is ─────────────────────────
# Each mount is scanned alone. A linked worktree's git directory in one mount
# (G55's layout: its main repository in EXTRA_MOUNTS, its checkout in the
# primary) waited there for a worktree, and the launch warned that its
# submodules were not followed, though the checkout's mount had read its index
# and protected them. And a worktree whose checkout was deleted and never pruned
# was warned about on every launch, with no checkout to protect (GIT-54).
U156="$TMP/up156"; "${G[@]}" init -q "$U156" && "${G[@]}" -C "$U156" commit -q --allow-empty -m u
M156="$TMP/main156"; "${G[@]}" init -q "$M156" && "${G[@]}" -C "$M156" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M156" worktree add -q "$PROJ/lw156" \
  && "${G[@]}" clone -q "$U156" "$PROJ/lw156/vendor/lib" && "${G[@]}" -C "$PROJ/lw156" add vendor/lib 2>/dev/null \
  && "${G[@]}" -C "$PROJ/lw156" commit -q -m n || { printf 'SCAFFOLD-FAILED: G156\n'; exit 1; }
EXTRA_MOUNTS="$M156" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/lw156/vendor/lib/.git/config:/workspace/proj/lw156/vendor/lib/.git/config:ro" \
  && ! grep -qF "no worktree is known for $M156/.git/worktrees/lw156" "$ERR" \
  && pass "G156 a worktree whose checkout another mount's scan reads is not said to have none" \
  || fail "G156 cross-mount worktree (rc=$LAUNCH_RC; $(grep -F 'no worktree' "$ERR" | head -1))"
# The checkout deleted, the worktree never pruned: still said, since a gitdir
# the agent rewrote to a path that is not there looks the same (G80), but with
# the prune that stops it.
rm -rf "$PROJ/lw156"
EXTRA_MOUNTS="$M156" launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "no worktree is known for $M156/.git/worktrees/lw156" "$ERR" \
  && grep -qF "Its gitdir names $PROJ/lw156, which is not there." "$ERR" \
  && grep -qF "git --git-dir=$M156/.git worktree prune stops this" "$ERR" \
  && pass "G156 a worktree whose checkout is gone is said, with the prune that stops it" \
  || fail "G156 checkout gone (rc=$LAUNCH_RC; $(grep -A2 -F 'no worktree' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$U156" "$M156"

# ── G147: an absorbed submodule's checkout, found through its core.worktree ──
# Its .git file, under a pruned vendor/ and recorded in no index, is read-only.
"${G[@]}" -C "$PROJ" -c protocol.file.allow=always submodule add -q "$U14x" vendor/sm147 >/dev/null 2>&1 \
  && [[ -f "$PROJ/vendor/sm147/.git" ]] && "${G[@]}" -C "$PROJ" rm -q --cached vendor/sm147 >/dev/null \
  || { printf 'SCAFFOLD-FAILED: G147\n'; exit 1; }
launch ..
has_mount "$PROJ/vendor/sm147/.git:/workspace/proj/vendor/sm147/.git:ro" \
  && pass "G147 an absorbed submodule's .git file, reached only through its core.worktree, is read-only" \
  || fail "G147 absorbed .git file (rc=$LAUNCH_RC; $(mounts | grep -F sm147 | tr '\n' ' '))"
# One whose core.worktree leads out of the mount: the .git file there is not
# bound, under any name.
mkdir -p "$TMP/out147" && printf 'gitdir: %s\n' "$PROJ/.git/modules/vendor/sm147" > "$TMP/out147/.git" \
  && "${G[@]}" config --file "$PROJ/.git/modules/vendor/sm147/config" core.worktree "$TMP/out147"
launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/out147" < <(mounts) \
  && pass "G147 a submodule checkout core.worktree puts outside the mount is not bound" \
  || fail "G147 outside checkout bound (rc=$LAUNCH_RC; $(mounts | grep -F out147 | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" rm -q --cached .gitmodules >/dev/null 2>&1
rm -rf "$TMP/out147" "$PROJ/vendor/sm147" "$PROJ/.git/modules/vendor/sm147" "$PROJ/.gitmodules" "$U14x"

# GAP-2 slice 6, continued: G148 and G149.
U148="$TMP/up148"; "${G[@]}" init -q "$U148" && "${G[@]}" -C "$U148" commit -q --allow-empty -m u \
  && h148="$("${G[@]}" -C "$U148" rev-parse HEAD)" || { printf 'SCAFFOLD-FAILED: G148\n'; exit 1; }
# ── G148: a submodule an index records is taken once, a link named ─────────
# Under a pruned vendor/, a submodule whose .git is a link is found only
# through the index, and named as the scan names one.
"${G[@]}" clone -q "$U148" "$TMP/real148" && mkdir -p "$PROJ/vendor/l148" && ln -s "$TMP/real148/.git" "$PROJ/vendor/l148/.git" \
  && "${G[@]}" -C "$PROJ" update-index --add --cacheinfo "160000,$h148,vendor/l148" || { printf 'SCAFFOLD-FAILED: G148 link\n'; exit 1; }
launch ..
grep -qF "WARNING: $PROJ/vendor/l148/.git is a symlink inside a writable mount" "$ERR" \
  && pass "G148 an index-recorded submodule under a pruned directory whose .git is a link is named" \
  || fail "G148 linked .git (rc=$LAUNCH_RC; $(grep -F l148 "$ERR" | head -2 | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" rm -q --cached vendor/l148 >/dev/null; rm -rf "$PROJ/vendor" "$TMP/real148"
# One the scan finds and the index records too is protected, and said so, once.
"${G[@]}" clone -q "$U148" "$PROJ/s148" && "${G[@]}" -C "$PROJ" add s148 2>/dev/null || { printf 'SCAFFOLD-FAILED: G148 twice\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 && -z "$(mounts | cut -d: -f2 | sort | uniq -d)" ]] \
  && [[ "$(grep -c "^READ-ONLY: /workspace/proj/s148/.git: " "$ERR")" == 1 ]] \
  && pass "G148 a submodule both the scan and the index find is protected once" \
  || fail "G148 once (rc=$LAUNCH_RC; READ-ONLY lines: $(grep -c '/workspace/proj/s148/.git: ' "$ERR"))"
"${G[@]}" -C "$PROJ" rm -q --cached s148 >/dev/null; rm -rf "$PROJ/s148"
# ── G149: a git directory is read once the .git file naming it turns up ─────
# The scan finds the git directory first; the .git file naming it is recorded
# only in the index of the repository the mount lies in, read after every git
# directory the scan found. It waits, and is read then: its submodule is
# protected, and it is not named as having no worktree.
O149="$TMP/o149"; "${G[@]}" init -q "$O149" && "${G[@]}" init -q --bare "$O149/m/gd" && mkdir -p "$O149/m/vendor/x" \
  && printf 'gitdir: ../../gd\n' > "$O149/m/vendor/x/.git" \
  && "${G[@]}" -C "$O149" update-index --add --cacheinfo "160000,$h148,m/vendor/x" \
  && "${G[@]}" clone -q "$U148" "$O149/m/vendor/x/sub" \
  && "${G[@]}" --git-dir="$O149/m/gd" --work-tree="$O149/m/vendor/x" update-index --add --cacheinfo "160000,$h148,sub" \
  || { printf 'SCAFFOLD-FAILED: G149\n'; exit 1; }
launch "$O149/m"
has_mount "$O149/m/vendor/x/sub/.git/config:/workspace/m/vendor/x/sub/.git/config:ro" \
  && ! grep -qF "no worktree is known for $O149/m/gd" "$ERR" \
  && pass "G149 a git directory found before the .git file naming it is read once that file turns up" \
  || fail "G149 retry (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$O149" "$U148"
# ── G151: a ./ commondir is not followed ───────────────────────────────────
# The placeholder names the git directory itself. Followed, it was named as a
# git directory a commondir names in another writable mount: for one in the
# group's own directories mounted into /workspace, a NOTE that a .git file
# there is not yours (GAP-2 slice 6: those conditions, turned, survived).
GR151="$HOME/.ai-containers/default/.agents/r151"; mkdir -p "$GR151" && "${G[@]}" init -q "$GR151" \
  && printf './\n' > "$GR151/.git/commondir" || { printf 'SCAFFOLD-FAILED: G151\n'; exit 1; }
EXTRA_MOUNTS="$GR151" launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "inside the container group's own directories" "$ERR" \
  && pass "G151 a ./ commondir is the git directory itself, not one it names" \
  || fail "G151 ./ followed (rc=$LAUNCH_RC; $(grep -F r151 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$GR151"

# ── G162: a commondir followed into another writable mount ───────────────────
# A checkout in the primary whose worktree lives in an EXTRA_MOUNTS directory,
# under its pruned node_modules: the worktree's commondir is followed, and the
# repository it names protected in the mounts that expose it, only there. One
# naming a directory that is no git directory is named where the agent could
# have made it (a writable mount), once, and not where it could not.
B162="$TMP/b162"; mkdir -p "$B162/node_modules/ng" "$TMP/out162/ng" && "${G[@]}" init -q "$B162/node_modules/r" \
  && "${G[@]}" -C "$B162/node_modules/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$B162/node_modules/r" worktree add -q "$PROJ/wt162" -b wt162 \
  || { printf 'SCAFFOLD-FAILED: G162\n'; exit 1; }
w162="$B162/node_modules/r/.git/worktrees"
for n162 in 2 3 4; do
  mkdir -p "$w162/wt162x$n162" "$PROJ/wt162x$n162" && cp "$w162/wt162/HEAD" "$w162/wt162x$n162/HEAD" \
    && printf '%s\n' "$PROJ/wt162x$n162/.git" > "$w162/wt162x$n162/gitdir" \
    && printf 'gitdir: %s\n' "$w162/wt162x$n162" > "$PROJ/wt162x$n162/.git" || { printf 'SCAFFOLD-FAILED: G162 x\n'; exit 1; }
done
# Our ./ placeholder, in a worktree's directory with no objects/: no redirect,
# so nothing to name.
printf './\n' > "$w162/wt162x4/commondir"
for n162 in 2 3; do mv "$w162/wt162x$n162" "$TMP/x$n162.aside162"; done
EXTRA_MOUNTS="$B162" launch ..
m162="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$B162/node_modules/r/.git/config:/workspace/b162/node_modules/r/.git/config:ro" <<<"$m162" \
  && [[ -z "$(awk -F: -v t="$TMP" 'index($2, t)' <<<"$m162")" ]] \
  && pass "G162 a commondir in another writable mount is protected there, and nowhere it does not lie" \
  || fail "G162 commondir across mounts (rc=$LAUNCH_RC; $(grep -F 'b162/node_modules/r/.git/config' <<<"$m162" | tr '\n' ' '))"
# Two that name no git directory, one in a writable mount and one outside
# every mount: named once, where the agent could have made it; both refuse the
# launch, as any commondir but ../.. in a worktree's directory does (G165).
for n162 in 2 3; do mv "$TMP/x$n162.aside162" "$w162/wt162x$n162"; done
printf '%s\n' "$B162/node_modules/ng" > "$w162/wt162x2/commondir"
printf '%s\n' "$TMP/out162/ng" > "$w162/wt162x3/commondir"
EXTRA_MOUNTS="$B162" launch ..
[[ "$LAUNCH_RC" != 0 && "$(grep -c 'which is not a git directory; nothing there is protected' "$ERR")" == 1 ]] \
  && grep -qF "WARNING: $w162/wt162x2/commondir names $B162/node_modules/ng, which is not a git directory" "$ERR" \
  && pass "G162 a commondir naming no git directory is named once, where the agent could have made it" \
  || fail "G162 not a git directory ($(grep -F 'not a git directory' "$ERR" | tr '\n' ' '))"
# A git directory there whose commondir is no regular file (a FIFO) refuses the
# launch as one, unread: it is not followed first, which would block on it.
"${G[@]}" init -q "$B162/node_modules/g" && rm -f "$B162/node_modules/g/.git/commondir" && mkfifo "$B162/node_modules/g/.git/commondir" \
  && mkdir -p "$PROJ/gf162" && printf 'gitdir: %s\n' "$B162/node_modules/g/.git" > "$PROJ/gf162/.git" \
  || { printf 'SCAFFOLD-FAILED: G162 FIFO\n'; exit 1; }
EXTRA_MOUNTS="$B162" launch_timed 60 ..
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $B162/node_modules/g/.git/commondir is not a regular file; refusing the launch." "$ERR" \
  && ! grep -qF 'could not be read within' "$ERR" \
  && pass "G162 a FIFO commondir there refuses the launch, unread (${LAUNCH_S}s)" \
  || fail "G162 FIFO commondir (rc=$LAUNCH_RC; $(grep -E 'ERROR' "$ERR" | head -1))"
rm -rf "$PROJ/gf162"
"${G[@]}" -C "$B162/node_modules/r" worktree remove --force "$PROJ/wt162" 2>/dev/null
rm -rf "$B162" "$TMP/out162" "$PROJ/wt162" "$PROJ/wt162x2" "$PROJ/wt162x3" "$PROJ/wt162x4"

# ── G164: a git directory a .git file names in another writable mount ────────
# It is named unless that mount's view of it is read-only now: one inside a
# launcher the other mount exposes lies under that launcher's read-only overlay
# and is not named; one whose name docker cannot be handed cannot be protected
# there and is named, whatever other read-only binds the launch makes (the
# project's own .git has some). Twenty are named, then a count of the rest:
# one is named with no count.
mkdir -p "$TMP/o164a/.ai-containers" "$PROJ/xm164a" && : > "$TMP/o164a/.ai-containers/sandbox.sh" \
  && : > "$TMP/o164a/.ai-containers/sandbox-common.sh" && "${G[@]}" init -q --bare "$TMP/o164a/.ai-containers/g" \
  && printf 'gitdir: %s\n' "$TMP/o164a/.ai-containers/g" > "$PROJ/xm164a/.git" || { printf 'SCAFFOLD-FAILED: G164 launcher\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o164a" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$TMP/o164a/.ai-containers:/workspace/o164a/.ai-containers:ro" \
  && ! grep -qF "a git directory in another writable mount" "$ERR" \
  && [[ -z "$(mounts | grep -F "/o164a/.ai-containers/g")" ]] \
  && pass "G164 a target under the other mount's launcher overlay is read-only there, and not named" \
  || fail "G164 target under an overlay (rc=$LAUNCH_RC; $(grep -F 'another writable mount' "$ERR" | head -1))"
rm -rf "$TMP/o164a" "$PROJ/xm164a"
# A name that is not UTF-8 where the filesystem takes one; a ':' with a CR
# where it does not (APFS): docker can be handed neither.
n164="bad"$'\xff'; mkdir -p "$TMP/o164b/node_modules" "$PROJ/xm164b" || { printf 'SCAFFOLD-FAILED: G164 dirs\n'; exit 1; }
mkdir "$TMP/o164b/node_modules/$n164" 2>/dev/null || { n164="bad:"$'\r'"y"; mkdir "$TMP/o164b/node_modules/$n164"; } \
  && "${G[@]}" init -q --bare "$TMP/o164b/node_modules/$n164" \
  && printf 'gitdir: %s\n' "$TMP/o164b/node_modules/$n164" > "$PROJ/xm164b/.git" || { printf 'SCAFFOLD-FAILED: G164 name\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o164b" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/.git/config:/workspace/proj/.git/config:ro" \
  && grep -aqF "WARNING: $PROJ/xm164b/.git names $TMP/o164b/node_modules/bad" "$ERR" \
  && grep -aqF "a git directory in another writable mount (/workspace/o164b)," "$ERR" \
  && ! grep -aqF "more git directories in other writable mounts could not be protected" "$ERR" \
  && pass "G164 a target the other mount cannot protect is named, with no count of more" \
  || fail "G164 unprotectable target not named (rc=$LAUNCH_RC; $(grep -aE 'WARNING' "$ERR" | head -2 | tr '\n' ' ' | LC_ALL=C tr -c '[:print:]' '?'))"
rm -rf "$TMP/o164b" "$PROJ/xm164b"

# ── G167: a timeout(1) that refuses an argument that is not UTF-8 (GIT-66) ────
# uutils' timeout, Ubuntu 26.04's, refuses one ("invalid UTF-8 was detected in
# one or more arguments", 125), so every bounded read of a path holding one ran
# nothing, and read as empty: a commondir placeholder `./` read as '' refused
# G164's launch, and an empty pointer could as well have been followed nowhere.
# Such a timeout is not used: GNU's (gnutimeout, which Ubuntu ships beside it)
# is, or none, as on a Mac without Homebrew's coreutils. A fake stands in for
# uutils', so the check runs where timeout is GNU's.
mkdir -p "$TMP/tp167"
printf '#!/bin/bash\nfor a; do if ! iconv -f UTF-8 -t UTF-8 <<<"$a" >/dev/null 2>&1; then echo "error: invalid UTF-8 was detected in one or more arguments" >&2; exit 125; fi; done\nshift 3; exec "$@"\n' > "$TMP/tp167/timeout"
printf '#!/bin/sh\nshift 3; exec "$@"\n' > "$TMP/tp167/gnutimeout"; cp "$TMP/tp167/timeout" "$TMP/tp167/gtimeout"
# gtimeout too: _timeout_prefix asks for Homebrew's name first, and where it is
# installed (a Mac with coreutils) the fake timeout was never reached.
chmod +x "$TMP/tp167/timeout" "$TMP/tp167/gtimeout" "$TMP/tp167/gnutimeout"
got167="$(PATH="$TMP/tp167:/usr/bin:/bin" _timeout_prefix 2>/dev/null)"
[[ "$got167" == "gnutimeout -k 2 10" ]] && pass "G167 a timeout that refuses a non-UTF-8 argument gives way to gnutimeout" \
  || fail "G167 the refusing timeout was taken (got '$got167')"
rm -f "$TMP/tp167/gnutimeout"
got167="$(PATH="$TMP/tp167" _timeout_prefix 2>/dev/null)"
[[ -z "$got167" ]] && pass "G167 with no other, no bound rather than a bound that reads nothing" \
  || fail "G167 the refusing timeout was taken alone (got '$got167')"
# End to end: G164's name docker cannot be handed, the refusing timeout first.
n167="bad"$'\xff'; mkdir -p "$TMP/o167/node_modules" "$PROJ/xm167"
if mkdir "$TMP/o167/node_modules/$n167" 2>/dev/null && "${G[@]}" init -q --bare "$TMP/o167/node_modules/$n167"; then
  printf 'gitdir: %s\n' "$TMP/o167/node_modules/$n167" > "$PROJ/xm167/.git"
  PATH="$TMP/tp167:$PATH" EXTRA_MOUNTS="$TMP/o167" launch ..
  [[ "$LAUNCH_RC" == 0 ]] && ! grep -aqF "commondir sends git to ''" "$ERR" \
    && pass "G167 a git directory with a non-UTF-8 name has its commondir read, under such a timeout" \
    || fail "G167 non-UTF-8 name under a refusing timeout (rc=$LAUNCH_RC; $(grep -aE 'ERROR' "$ERR" | head -1 | LC_ALL=C tr -c '[:print:]' '?'))"
else
  printf 'NOTE: this filesystem takes no name that is not UTF-8; the end-to-end check is not applicable\n'
fi
# A bound that exits 125 itself ran nothing: the read refuses the launch, never
# reads as empty.
printf '#!/bin/sh\ncase "$*" in *commondir*) exit 125 ;; esac\nshift 3; exec "$@"\n' > "$TMP/tp167/timeout"; cp "$TMP/tp167/timeout" "$TMP/tp167/gtimeout"
chmod +x "$TMP/tp167/timeout" "$TMP/tp167/gtimeout"
mkdir -p "$PROJ/r167" && "${G[@]}" init -q "$PROJ/r167"
PATH="$TMP/tp167:$PATH" launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -aqF "the command that bounds the read ran nothing" "$ERR" \
  && pass "G167 a read whose bound exits 125 refuses the launch" \
  || fail "G167 a bound that ran nothing (rc=$LAUNCH_RC; $(grep -aE 'ERROR' "$ERR" | head -1))"
rm -rf "$TMP/o167" "$PROJ/xm167" "$PROJ/r167" "$TMP/tp167"

# ── G168: a common directory in a writable mount, named from outside it ──────
# A checkout in a writable mount whose .git names a linked worktree's directory
# outside every mount, whose commondir names a repository under that mount's
# pruned node_modules: git takes that repository's config and hooks for the
# checkout, so it is protected there; one naming a path not there in the mount
# is named, and one the session then makes a repository is named after it
# (bugs review GIT-65).
B168="$TMP/b168"; O168="$TMP/o168"
mkdir -p "$B168/co" "$B168/co2" "$O168/wt" "$O168/wt2" && "${G[@]}" init -q "$B168/node_modules/c" \
  && "${G[@]}" -C "$B168/node_modules/c" commit -q --allow-empty -m i \
  && for w168 in wt wt2; do
       printf 'ref: refs/heads/main\n' > "$O168/$w168/HEAD" || exit 1
     done \
  && printf '%s\n' "$B168/node_modules/c/.git" > "$O168/wt/commondir" \
  && printf '%s\n' "$B168/co/.git" > "$O168/wt/gitdir" \
  && printf 'gitdir: %s\n' "$O168/wt" > "$B168/co/.git" \
  && printf '%s\n' "$B168/node_modules/n/.git" > "$O168/wt2/commondir" \
  && printf '%s\n' "$B168/co2/.git" > "$O168/wt2/gitdir" \
  && printf 'gitdir: %s\n' "$O168/wt2" > "$B168/co2/.git" \
  && [[ "$("${G[@]}" -C "$B168/co" rev-parse --git-common-dir 2>/dev/null)" == "$B168/node_modules/c/.git" ]] \
  || { printf 'SCAFFOLD-FAILED: G168\n'; exit 1; }
EXTRA_MOUNTS="$B168" launch "$TMP/app"
m168="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] \
  && grep -qxF -- "$B168/node_modules/c/.git/config:/workspace/b168/node_modules/c/.git/config:ro" <<<"$m168" \
  && grep -qxF -- "$B168/node_modules/c/.git/hooks:/workspace/b168/node_modules/c/.git/hooks:ro" <<<"$m168" \
  && pass "G168 a common directory in a writable mount that an outside worktree names is protected there" \
  || fail "G168 common directory named from outside (rc=$LAUNCH_RC; $(grep -F 'node_modules/c/' <<<"$m168" | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
grep -qF "WARNING: $O168/wt2/commondir names $B168/node_modules/n/.git, which does not exist; if the agent makes it" "$ERR" \
  && pass "G168 one naming a path not there in the mount is named" \
  || fail "G168 a path not there ($(grep -F 'wt2' "$ERR" | head -2 | tr '\n' ' '))"
FAKE_SESSION="git init -q '$B168/node_modules/n' && git -C '$B168/node_modules/n' config core.fsmonitor ./fsm" \
  EXTRA_MOUNTS="$B168" launch "$TMP/app"
grep -qF "$B168/node_modules/n/.git (config: core.fsmonitor" \
     < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G168 a repository the session makes there is named after it" \
  || fail "G168 rescan of a path not there ($(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
rm -rf "$B168" "$O168"
# The repository a mount lies in, outside every mount, through a .git directory
# and through a .git link, whose commondir names a repository in the mount.
for k168 in d l; do
  R168="$TMP/r168$k168"; mkdir -p "$R168/s$k168" && "${G[@]}" init -q "$R168/s$k168/node_modules/c" \
    && "${G[@]}" -C "$R168/s$k168/node_modules/c" commit -q --allow-empty -m i || { printf 'SCAFFOLD-FAILED: G168 %s\n' "$k168"; exit 1; }
  if [[ "$k168" == d ]]; then g168="$R168/.git"; else g168="$TMP/gd168"; ln -s "$g168" "$R168/.git"; fi
  mkdir -p "$g168" && printf 'ref: refs/heads/main\n' > "$g168/HEAD" \
    && printf '%s\n' "$R168/s$k168/node_modules/c/.git" > "$g168/commondir" \
    && [[ "$("${G[@]}" -C "$R168/s$k168" rev-parse --git-common-dir 2>/dev/null)" == "$R168/s$k168/node_modules/c/.git" ]] \
    || { printf 'SCAFFOLD-FAILED: G168 %s layout\n' "$k168"; exit 1; }
  EXTRA_MOUNTS="$R168/s$k168" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$R168/s$k168/node_modules/c/.git/config:/workspace/s$k168/node_modules/c/.git/config:ro" \
    && pass "G168 a common directory in the mount that the repository it lies in names is protected ($k168)" \
    || fail "G168 the repository a mount lies in ($k168; rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  rm -rf "$R168" "$TMP/gd168"
done

# ── G169: what a commondir names, not a git directory at launch ──────────────
# A linked worktree's directory outside every mount, which git and the agent
# leave as it is, whose commondir names a directory in a writable mount (under
# its pruned node_modules) that is no git directory gets a WARNING that says
# what follows; a session that makes it one, with no HEAD (a common directory
# needs none) and a config that runs a program, has it named after the session
# (bugs review GIT-63). A worktree's directory in the mount with such a
# commondir refuses the launch: git writes none but ../.. (GIT-67; G165).
B169="$TMP/b169"; O169="$TMP/o169"
mkdir -p "$B169/node_modules/ng" "$B169/co" "$O169/wt" && printf 'ref: refs/heads/main\n' > "$O169/wt/HEAD" \
  && printf '%s\n' "$B169/node_modules/ng" > "$O169/wt/commondir" && printf '%s\n' "$B169/co/.git" > "$O169/wt/gitdir" \
  && printf 'gitdir: %s\n' "$O169/wt" > "$B169/co/.git" || { printf 'SCAFFOLD-FAILED: G169\n'; exit 1; }
sess169="git init -q --bare '$B169/node_modules/ng' && rm -f '$B169/node_modules/ng/HEAD' && git config --file '$B169/node_modules/ng/config' core.fsmonitor ./fsm"
FAKE_SESSION="$sess169" EXTRA_MOUNTS="$B169" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] \
  && grep -qF "if the agent makes it one, your host's git reads it unprotected" \
     < <(grep -A2 -F "WARNING: $O169/wt/commondir names $B169/node_modules/ng, which is not a git directory" "$ERR") \
  && pass "G169 a commondir naming no git directory is named with what follows" \
  || fail "G169 the WARNING (rc=$LAUNCH_RC; $(grep -A2 -F 'not a git directory' "$ERR" | tr '\n' ' '))"
grep -qF "$B169/node_modules/ng (config: core.fsmonitor" \
     < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G169 a common directory with no HEAD the session makes there is named after it" \
  || fail "G169 rescan ($(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
# One naming a path not there: named at launch, and a repository the session
# makes there named after it — the rescan does not look under node_modules.
rm -rf "$B169/node_modules/ng"; printf '%s\n' "$B169/node_modules/nx" > "$O169/wt/commondir"
FAKE_SESSION="git init -q --bare '$B169/node_modules/nx' && git config --file '$B169/node_modules/nx/config' core.fsmonitor ./fsm" \
  EXTRA_MOUNTS="$B169" launch "$TMP/app"
grep -qF "WARNING: $O169/wt/commondir names $B169/node_modules/nx, which does not exist" "$ERR" \
  && grep -qF "$B169/node_modules/nx (config: core.fsmonitor" \
     < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G169 a commondir naming a path not there is named, and a repository the session makes there after it" \
  || fail "G169 not there (rc=$LAUNCH_RC; $(grep -F 'nx' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$B169" "$O169"
# In the mount, a worktree's directory with such a commondir is refused at launch.
mkdir -p "$B169/node_modules/ng" && "${G[@]}" init -q "$B169/node_modules/r" \
  && "${G[@]}" -C "$B169/node_modules/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$B169/node_modules/r" worktree add -q "$PROJ/wt169" -b wt169 \
  && printf '%s\n' "$B169/node_modules/ng" > "$B169/node_modules/r/.git/worktrees/wt169/commondir" \
  || { printf 'SCAFFOLD-FAILED: G169 in the mount\n'; exit 1; }
EXTRA_MOUNTS="$B169" launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $B169/node_modules/r/.git/worktrees/wt169/commondir sends git to" "$ERR" \
  && pass "G169 a worktree's directory in the mount whose commondir names no repository refuses the launch" \
  || fail "G169 in the mount (rc=$LAUNCH_RC; $(grep -E 'ERROR' "$ERR" | head -1))"
"${G[@]}" -C "$B169/node_modules/r" worktree remove --force "$PROJ/wt169" 2>/dev/null
rm -rf "$B169" "$PROJ/wt169"

# ── G171: a common directory named from outside must be a repository's own ───
# An outside worktree's commondir that names, under a writable mount's pruned
# node_modules, a directory holding objects/ and refs/ with a commondir of its
# own (`../..`, a linked worktree's): that directory passes as a linked
# worktree's, so its config is neither made nor bound, and git takes it as the
# common directory, reading the config the agent writes there. Refused, as a
# worktree's `../..` naming one is (bugs review GIT-68).
B171="$TMP/b171"; O171="$TMP/o171"; V171="$B171/node_modules/x/.git/worktrees/v"
mkdir -p "$B171/co" "$O171/wt" && "${G[@]}" init -q "$B171/node_modules/x" \
  && "${G[@]}" -C "$B171/node_modules/x" commit -q --allow-empty -m i \
  && mkdir -p "$V171/objects" "$V171/refs" && printf 'ref: refs/heads/main\n' > "$V171/HEAD" \
  && printf '../..\n' > "$V171/commondir" \
  && printf 'ref: refs/heads/main\n' > "$O171/wt/HEAD" && printf '%s\n' "$V171" > "$O171/wt/commondir" \
  && printf '%s\n' "$B171/co/.git" > "$O171/wt/gitdir" && printf 'gitdir: %s\n' "$O171/wt" > "$B171/co/.git" \
  && [[ "$("${G[@]}" -C "$B171/co" rev-parse --git-common-dir 2>/dev/null)" == "$V171" ]] \
  || { printf 'SCAFFOLD-FAILED: G171\n'; exit 1; }
EXTRA_MOUNTS="$B171" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $O171/wt/commondir names $V171, which is no repository's own git directory" "$ERR" \
  && grep -qF "the agent could write them. Point $O171/wt/commondir at its repository's" "$ERR" \
  && grep -qF "If $V171 is not yours, move it (mv) to a directory you never mount. Do not remove" "$ERR" \
  && grep -qF "$V171/commondir: git would read $V171/config for that checkout all the same." "$ERR" \
  && ! grep -qw rm "$ERR" \
  && pass "G171 an outside commondir naming a linked worktree's directory in a writable mount refuses the launch, its commondir not to be removed" \
  || fail "G171 an outside commondir naming no repository's own (rc=$LAUNCH_RC; $(grep -m1 -E 'ERROR' "$ERR"); config bound: $(mounts | grep -cF "$V171/config"))"
# The same directory under a refs/: nothing there is said to be moved or
# removed, since a branch can be a file by that name (GIT-70).
F171="$B171/node_modules/x/.git/refs/heads/worktrees/v"
mkdir -p "${F171%/*}" && cp -R "$V171" "$F171" && printf '%s\n' "$F171" > "$O171/wt/commondir" || { printf 'SCAFFOLD-FAILED: G171 refs\n'; exit 1; }
EXTRA_MOUNTS="$B171" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $O171/wt/commondir names $F171, which is no repository's own git directory" "$ERR" \
  && grep -qF "Do not remove it: that deletes the branch." "$ERR" && ! grep -qwE 'rm|mv' "$ERR" \
  && pass "G171 one whose target lies under a refs/: nothing is to be moved or removed" \
  || fail "G171 a target under refs/ (rc=$LAUNCH_RC; $(grep -A6 -m1 -E 'ERROR' "$ERR" | tr '\n' ' '))"
rm -rf "$B171/node_modules/x/.git/refs/heads/worktrees" && printf '%s\n' "$V171" > "$O171/wt/commondir" || { printf 'SCAFFOLD-FAILED: G171 refs back\n'; exit 1; }
# …and so does one whose target lies under ANOTHER writable mount's node_modules.
C171="$TMP/c171"; mkdir -p "$C171/node_modules" && mv "$B171/node_modules/x" "$C171/node_modules/x" \
  && printf '%s\n' "$C171/node_modules/x/.git/worktrees/v" > "$O171/wt/commondir" \
  || { printf 'SCAFFOLD-FAILED: G171 two mounts\n'; exit 1; }
EXTRA_MOUNTS="$B171 $C171" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $O171/wt/commondir names $C171/node_modules/x/.git/worktrees/v, which is no repository's own git directory" "$ERR" \
  && pass "G171 one whose target lies in another writable mount refuses the launch too" \
  || fail "G171 a target in another mount (rc=$LAUNCH_RC; $(grep -m1 -E 'ERROR' "$ERR"))"
mv "$C171/node_modules/x" "$B171/node_modules/x" && rm -rf "$C171" && printf '%s\n' "$V171" > "$O171/wt/commondir" \
  || { printf 'SCAFFOLD-FAILED: G171 back\n'; exit 1; }
# …and so does the repository a mount lies in, outside every mount, naming one.
R171="$TMP/r171"; mkdir -p "$R171/.git" "$R171/s" && printf 'ref: refs/heads/main\n' > "$R171/.git/HEAD" \
  && mv "$B171/node_modules" "$R171/s/node_modules" \
  && printf '%s\n' "$R171/s/node_modules/x/.git/worktrees/v" > "$R171/.git/commondir" \
  && [[ "$("${G[@]}" -C "$R171/s" rev-parse --git-common-dir 2>/dev/null)" == "$R171/s/node_modules/x/.git/worktrees/v" ]] \
  || { printf 'SCAFFOLD-FAILED: G171 the repository a mount lies in\n'; exit 1; }
EXTRA_MOUNTS="$R171/s" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $R171/.git/commondir names $R171/s/node_modules/x/.git/worktrees/v, which is no repository's own git directory" "$ERR" \
  && pass "G171 the repository a mount lies in, naming one, refuses the launch" \
  || fail "G171 the repository a mount lies in (rc=$LAUNCH_RC; $(grep -m1 -E 'ERROR' "$ERR"))"
mv "$R171/s/node_modules" "$B171/node_modules" && rm -rf "$R171" || { printf 'SCAFFOLD-FAILED: G171 back\n'; exit 1; }
# With its objects an executable file, which git takes as it takes a directory,
# it is refused all the same (bugs review GIT-69).
rmdir "$V171/objects" && : > "$V171/objects" && chmod +x "$V171/objects" \
  && [[ "$("${G[@]}" -C "$B171/co" rev-parse --git-common-dir 2>/dev/null)" == "$V171" ]] \
  || { printf 'SCAFFOLD-FAILED: G171 objects a file\n'; exit 1; }
EXTRA_MOUNTS="$B171" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $O171/wt/commondir names $V171, which is no repository's own git directory" "$ERR" \
  && pass "G171 one whose objects is an executable file refuses the launch too" \
  || fail "G171 objects a file (rc=$LAUNCH_RC; $(grep -m1 -E 'ERROR|WARNING' "$ERR"))"
rm -f "$V171/objects" && mkdir "$V171/objects" || { printf 'SCAFFOLD-FAILED: G171 objects back\n'; exit 1; }
# Named at launch as not there, and made a worktree's directory by the session:
# git reads ITS config for the outside worktree, so that is what is named after
# the session, not the config its own ../.. names (GIT-69).
N171="$B171/node_modules/x/.git/worktrees/nv"; printf '%s\n' "$N171" > "$O171/wt/commondir" \
  || { printf 'SCAFFOLD-FAILED: G171 not there\n'; exit 1; }
FAKE_SESSION="mkdir -p '$N171/refs' '$N171/objects' && printf 'ref: refs/heads/main\n' > '$N171/HEAD' && printf '../..\n' > '$N171/commondir' && git config --file '$N171/config' core.fsmonitor ./fsm" \
  EXTRA_MOUNTS="$B171" launch "$TMP/app"
grep -qF "WARNING: $O171/wt/commondir names $N171, which does not exist" "$ERR" \
  && grep -qF "$N171 (config: core.fsmonitor" < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G171 a worktree's directory the session makes where an outside commondir points is named, by its own config" \
  || fail "G171 made during the session (rc=$LAUNCH_RC; $(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
rm -rf "$N171" && printf '%s\n' "$V171" > "$O171/wt/commondir" || { printf 'SCAFFOLD-FAILED: G171 back\n'; exit 1; }
# …and one naming a repository's own, under the same node_modules, still launches,
# its config made and bound there (G168), and again once it holds the ./ placeholder.
printf '%s\n' "$B171/node_modules/x/.git" > "$O171/wt/commondir" || { printf 'SCAFFOLD-FAILED: G171 own\n'; exit 1; }
for n171 in first second; do
  EXTRA_MOUNTS="$B171" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$B171/node_modules/x/.git/config:/workspace/b171/node_modules/x/.git/config:ro" \
    && pass "G171 an outside commondir naming a repository's own git directory launches, its config bound ($n171 launch)" \
    || fail "G171 a repository's own ($n171 launch; rc=$LAUNCH_RC; $(grep -m1 -E 'ERROR' "$ERR"))"
done
[[ "$(cat "$B171/node_modules/x/.git/commondir" 2>/dev/null)" == ./ ]] \
  || fail "G171 the second launch did not run with the ./ placeholder ($(cat "$B171/node_modules/x/.git/commondir" 2>&1))"
rm -rf "$B171" "$O171"

# ── G174: a watched directory a commondir and a .git file both name ──────────
# Named at launch as not there by an outside worktree's commondir and by a .git
# file in another writable mount. The session makes it a worktree's directory
# whose commondir names a common directory with a config that runs a program:
# git reads that config for the .git file's checkout, so after the session it is
# named, though the outside commondir's reading (its own config) finds nothing
# (review of GIT-69's fix).
B174="$TMP/b174"; C174="$TMP/c174"; O174="$TMP/o174"; N174="$B174/node_modules/n"; K174="$B174/node_modules/k"
mkdir -p "$B174/co" "$C174/co2" "$O174/wt" && printf 'ref: refs/heads/main\n' > "$O174/wt/HEAD" \
  && printf '%s\n' "$N174" > "$O174/wt/commondir" && printf '%s\n' "$B174/co/.git" > "$O174/wt/gitdir" \
  && printf 'gitdir: %s\n' "$O174/wt" > "$B174/co/.git" && printf 'gitdir: %s\n' "$N174" > "$C174/co2/.git" \
  || { printf 'SCAFFOLD-FAILED: G174\n'; exit 1; }
FAKE_SESSION="mkdir -p '$N174' '$K174/objects' '$K174/refs' && printf 'ref: refs/heads/main\n' > '$N174/HEAD' && printf '%s\n' '$K174' > '$N174/commondir' && git config --file '$K174/config' core.fsmonitor ./fsm" \
  EXTRA_MOUNTS="$B174 $C174" launch "$TMP/app"
grep -qF "$N174 (config: core.fsmonitor" < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G174 a directory a commondir and a .git file both name is read both ways after the session" \
  || fail "G174 both ways (rc=$LAUNCH_RC; $(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
rm -rf "$B174" "$C174" "$O174"

# ── G175: a linked worktree's directory is no frozen common directory ───────
# A .git file names a linked worktree's directory that is not there (named at
# launch). The session gives the real linked worktree's directory objects/,
# refs/ and a config that runs a program, and makes the named one with a
# commondir leading to it: git takes that directory for the checkout's common
# one. The launch bound no config there, so after the session it is read and
# named. A worktree the session adds to a protected repository, whose config the
# launch bound, is not named for it (bugs review GIT-71).
B175="$TMP/b175"; R175="$B175/r"; W175="$R175/.git/worktrees"
mkdir -p "$B175/nco" && "${G[@]}" init -q "$R175" && "${G[@]}" -C "$R175" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$R175" config core.fsmonitor ./fsm \
  && "${G[@]}" -C "$R175" worktree add -q "$B175/w1co" -b w1 \
  && printf 'gitdir: %s\n' "$W175/n" > "$B175/nco/.git" \
  || { printf 'SCAFFOLD-FAILED: G175\n'; exit 1; }
sess175="mkdir -p '$W175/w1co/objects' '$W175/w1co/refs' '$W175/n' && git config --file '$W175/w1co/config' core.fsmonitor ./fsm2"
sess175+=" && printf 'ref: refs/heads/main\n' > '$W175/n/HEAD' && printf '../w1co\n' > '$W175/n/commondir'"
sess175+=" && git -C '$R175' worktree add -q '$B175/w2co' -b w2"
FAKE_SESSION="$sess175" EXTRA_MOUNTS="$B175" launch "$TMP/app"
a175="$(grep -A6 -F 'WARNING: the session made git repositories in a writable mount' "$ERR")"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "$W175/n (config: core.fsmonitor" <<<"$a175" \
  && pass "G175 a linked worktree's directory made a common one in the session is read after it" \
  || fail "G175 frozen worktree directory (rc=$LAUNCH_RC; $(tr '\n' ' ' <<<"$a175"); $(grep -F 'worktrees/n' "$ERR" | head -2 | tr '\n' ' '))"
[[ "$("${G[@]}" -C "$B175/nco" rev-parse --git-common-dir 2>/dev/null)" == "$W175/w1co" ]] \
  && ! grep -qF "$W175/w2" <<<"$a175" \
  && pass "G175 git takes it so; a worktree added to a protected repository is not named for its config" \
  || fail "G175 controls (common dir: $("${G[@]}" -C "$B175/nco" rev-parse --git-common-dir 2>&1); $(tr '\n' ' ' <<<"$a175"))"
rm -rf "$B175"
# A repository under the launcher's read-only overlay has its config frozen as
# well: a git directory the session makes that names it for its common one is
# not named for that config.
"${G[@]}" init -q "$LAUNCHER/sub175" && "${G[@]}" -C "$LAUNCHER/sub175" config core.fsmonitor ./fsm \
  || { printf 'SCAFFOLD-FAILED: G175 overlay\n'; exit 1; }
FAKE_SESSION="mkdir -p '$PROJ/z175' && printf 'ref: refs/heads/main\n' > '$PROJ/z175/HEAD' && printf '%s\n' '$LAUNCHER/sub175/.git' > '$PROJ/z175/commondir'" \
  launch ..
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$PROJ/z175 (config" "$ERR" \
  && pass "G175 a common directory under a read-only overlay is not named for its config after the session" \
  || fail "G175 overlay (rc=$LAUNCH_RC; $(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
rm -rf "$LAUNCHER/sub175" "$PROJ/z175"

# ── G176: a bare repository on the way up from a mount ──────────────────────
# git's discovery asks of each directory, after its .git, whether it is itself a
# git directory. Two writable mounts, the inner one in a bare repository under
# the outer one's pruned node_modules: git in the inner mount reads that
# repository's config, so it is protected in the outer mount's view. One outside
# every mount is judged: a core.hooksPath there that leads into the mount is
# named (bugs review GIT-72).
M176="$TMP/m176"; A176="$M176/node_modules/a"
mkdir -p "$M176" && "${G[@]}" init -q --bare "$A176" && mkdir -p "$A176/b" \
  && "${G[@]}" --git-dir="$A176" config core.worktree "$A176/b" \
  && "${G[@]}" --git-dir="$A176" config core.fsmonitor ./fsm \
  && [[ "$("${G[@]}" -C "$A176/b" rev-parse --absolute-git-dir 2>/dev/null)" == "$A176" ]] \
  || { printf 'SCAFFOLD-FAILED: G176\n'; exit 1; }
EXTRA_MOUNTS="$M176 $A176/b" launch "$TMP/app"
m176="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$A176/config:/workspace/m176/node_modules/a/config:ro" <<<"$m176" \
  && grep -qxF -- "$A176/hooks:/workspace/m176/node_modules/a/hooks:ro" <<<"$m176" \
  && pass "G176 a bare repository an inner mount lies in, under the outer one's node_modules, is protected there" \
  || fail "G176 bare repository on the way up (rc=$LAUNCH_RC; $(grep -F 'node_modules/a/' <<<"$m176" | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# A .git there that is no repository: git passes over it, and asks the
# directory itself.
mkdir "$A176/.git" || { printf 'SCAFFOLD-FAILED: G176 .git\n'; exit 1; }
EXTRA_MOUNTS="$M176 $A176/b" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$A176/config:/workspace/m176/node_modules/a/config:ro" \
  && pass "G176 so is one with a .git in it that is no repository" \
  || fail "G176 bare repository past a .git (rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
rmdir "$A176/.git"
# Its index is read against its core.worktree, as a .git directory's is: a
# repository it records under the inner mount's pruned vendor/ is protected.
# A fresh one, core.bare off as a work tree needs (git finds it on the way up
# all the same).
C176="$M176/node_modules/c"
"${G[@]}" init -q --bare "$C176" && mkdir -p "$C176/b" && "${G[@]}" --git-dir="$C176" config core.bare false \
  && "${G[@]}" --git-dir="$C176" config core.worktree "$C176/b" \
  && "${G[@]}" init -q "$C176/b/vendor/s" && "${G[@]}" -C "$C176/b/vendor/s" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$C176/b" add vendor/s 2>/dev/null \
  && grep -q '^160000' < <("${G[@]}" -C "$C176/b" ls-files -s vendor/s) \
  || { printf 'SCAFFOLD-FAILED: G176 gitlink\n'; exit 1; }
EXTRA_MOUNTS="$M176 $C176/b" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$C176/b/vendor/s/.git/config:/workspace/b/vendor/s/.git/config:ro" \
  && pass "G176 a repository its index records in the inner mount is protected" \
  || fail "G176 gitlink of a bare repository (rc=$LAUNCH_RC; $(grep -F 'vendor/s' <<<"$(mounts)" | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
O176="$TMP/o176.git"
"${G[@]}" init -q --bare "$O176" && mkdir -p "$O176/w/h" && "${G[@]}" --git-dir="$O176" config core.hooksPath w/h \
  || { printf 'SCAFFOLD-FAILED: G176 outside\n'; exit 1; }
EXTRA_MOUNTS="$O176/w" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "$O176" < <(grep -F 'core.hooksPath' "$ERR") \
  && pass "G176 a bare repository outside every mount that a mount lies in is judged" \
  || fail "G176 outside bare repository (rc=$LAUNCH_RC; $(grep -E 'NOTE|WARNING|ERROR' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$M176" "$O176"

# ── G212: what an outside worktree's commondir names is judged only as git takes it
# A worktree's directory outside every writable mount, named by a .git file in
# one, has its common directory judged with it (GIT-44) only where git would
# take it: a directory outside that is no common directory (git refuses the
# worktree) is not judged, and one inside the mount, which the launch protects
# there, is not judged again as one outside, under its host path (GAP-2's
# whole-file run, batch 1, item 3).
B212="$TMP/b212"; O212="$TMP/o212"
mkdir -p "$B212/co4" "$B212/hk4" "$B212/co3" "$O212/wt4" "$O212/nc" "$O212/wt3" \
  && git config --file "$O212/nc/config" core.hooksPath "$B212/hk4" \
  && printf 'ref: refs/heads/main\n' > "$O212/wt4/HEAD" && printf '%s\n' "$O212/nc" > "$O212/wt4/commondir" \
  && printf '%s\n' "$B212/co4/.git" > "$O212/wt4/gitdir" && printf 'gitdir: %s\n' "$O212/wt4" > "$B212/co4/.git" \
  && "${G[@]}" init -q "$B212/node_modules/c" && "${G[@]}" -C "$B212/node_modules/c" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$B212/node_modules/c" config core.hooksPath hk3 \
  && printf 'ref: refs/heads/main\n' > "$O212/wt3/HEAD" && printf '%s\n' "$B212/node_modules/c/.git" > "$O212/wt3/commondir" \
  && printf '%s\n' "$B212/co3/.git" > "$O212/wt3/gitdir" && printf 'gitdir: %s\n' "$O212/wt3" > "$B212/co3/.git" \
  || { printf 'SCAFFOLD-FAILED: G212\n'; exit 1; }
EXTRA_MOUNTS="$B212" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "NOTE: $O212/wt3 runs its git hooks from /workspace/b212/co3/hk3 (core.hooksPath)" "$ERR" \
  && ! grep -qF "NOTE: $O212/nc runs its git hooks" "$ERR" \
  && pass "G212 a directory an outside worktree's commondir names that is no common directory is not judged" \
  || fail "G212 not a common directory (rc=$LAUNCH_RC; $(grep -F 'o212' "$ERR" | head -3 | tr '\n' ' '))"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "NOTE: /workspace/b212/node_modules/c/.git runs its git hooks from" "$ERR" \
  && ! grep -qF "NOTE: $B212/node_modules/c/.git runs its git hooks" "$ERR" \
  && pass "G212 a common directory in the mount it names is judged where it is protected, not again outside" \
  || fail "G212 judged twice (rc=$LAUNCH_RC; $(grep -F 'node_modules/c/.git runs' "$ERR" | tr '\n' ' '))"
rm -rf "$B212" "$O212"

# ── G213: a git directory outside the mounts that git uses with two configs ──
# X, outside every mount, has a store and a commondir naming Y: git takes Y's
# config for the checkout whose .git names X, and X's own for the checkout of a
# worktree W whose commondir names X. Each is judged, whichever mount is
# scanned first: the launcher listed X once, with the config it met first, so
# the other checkout's core.hooksPath went unnamed (bugs review GIT-94).
O213="$TMP/o213"; B213a="$TMP/b213a"; B213b="$TMP/b213b"
mkdir -p "$B213a/coa" "$B213a/hkx" "$B213a/hky" "$B213b/cob" "$O213/W" && "${G[@]}" init -q --bare "$O213/X" \
  && "${G[@]}" init -q --bare "$O213/Y" && printf '%s\n' "$O213/Y" > "$O213/X/commondir" \
  && git config --file "$O213/X/config" core.hooksPath "$B213a/hkx" && git config --file "$O213/Y/config" core.hooksPath "$B213a/hky" \
  && printf 'ref: refs/heads/main\n' > "$O213/W/HEAD" && printf '%s\n' "$O213/X" > "$O213/W/commondir" \
  && printf '%s\n' "$B213b/cob/.git" > "$O213/W/gitdir" \
  && printf 'gitdir: %s\n' "$O213/X" > "$B213a/coa/.git" && printf 'gitdir: %s\n' "$O213/W" > "$B213b/cob/.git" \
  || { printf 'SCAFFOLD-FAILED: G213\n'; exit 1; }
for o213 in "$B213a $B213b" "$B213b $B213a"; do
  EXTRA_MOUNTS="$o213" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF "runs its git hooks from /workspace/b213a/hkx (core.hooksPath)" "$ERR" \
    && grep -qF "runs its git hooks from /workspace/b213a/hky (core.hooksPath)" "$ERR" \
    && pass "G213 a git directory git uses with two configs is judged with each (mounts: ${o213//$TMP\//})" \
    || fail "G213 two configs, mounts ${o213//$TMP\//} (rc=$LAUNCH_RC; $(grep -F 'runs its git hooks' "$ERR" | tr '\n' ' '))"
done
rm -rf "$O213" "$B213a" "$B213b"

# ── G217: no git runs on an index beside a shared part that is no regular file ─
# A sharedindex.* in a git directory that is no regular file and no link to one
# fails the index read before git runs, as a FIFO's does (G37), even where the
# index, not split, names none: here a dangling link, which a concurrent
# container can repoint between this check and the read (GAP-2's whole-file
# run, batch 2, item 4).
B217="$TMP/b217"; mkdir -p "$B217" && "${G[@]}" init -q "$B217/r" && : > "$B217/r/f" && "${G[@]}" -C "$B217/r" add f \
  && ln -s nowhere "$B217/r/.git/sharedindex.0000000000000000000000000000000000000000" \
  || { printf 'SCAFFOLD-FAILED: G217\n'; exit 1; }
EXTRA_MOUNTS="$B217" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "cannot read the index of $B217/r/.git;" "$ERR" \
  && pass "G217 an index beside a sharedindex that is a dangling link is not read" \
  || fail "G217 dangling sharedindex (rc=$LAUNCH_RC; $(grep -E 'index|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$B217"

# ── G240: a .git that is no directory and no file is passed over, as git passes over it
# git's discovery cannot stat a dangling .git link, takes it for no .git, and
# asks the directory itself: in a bare repository's directory it still uses
# that repository. The walk up asked the directory only where there was no
# .git, or a directory that is no repository. With a dangling link there,
# which the agent can make in a writable mount, G176's bare repository lost
# its read-only config and hooks in the outer mount's view; and one outside
# every mount was not judged, the next repository up being judged in its
# place (bugs review GIT-95).
M240="$TMP/m240"; A240="$M240/node_modules/a"
mkdir -p "$M240" && "${G[@]}" init -q --bare "$A240" && mkdir -p "$A240/b" \
  && "${G[@]}" --git-dir="$A240" config core.worktree "$A240/b" && ln -s nowhere "$A240/.git" \
  && [[ "$("${G[@]}" -C "$A240/b" rev-parse --absolute-git-dir 2>/dev/null)" == "$A240" ]] \
  || { printf 'SCAFFOLD-FAILED: G240 git does not pass over a dangling .git link\n'; exit 1; }
EXTRA_MOUNTS="$M240 $A240/b" launch "$TMP/app"
m240="$(mounts)"
[[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$A240/config:/workspace/m240/node_modules/a/config:ro" <<<"$m240" \
  && grep -qxF -- "$A240/hooks:/workspace/m240/node_modules/a/hooks:ro" <<<"$m240" \
  && pass "G240 a bare repository with a dangling .git link in it is protected in the outer mount, as git uses it" \
  || fail "G240 dangling .git link in a bare repository (rc=$LAUNCH_RC; $(grep -F 'node_modules/a/' <<<"$m240" | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# The link is still named: the agent can repoint it at a git directory of its own.
grep -qF "WARNING: $A240/.git is a symlink inside a writable mount (/workspace/m240)" "$ERR" \
  && pass "G240 …and the link is still named" \
  || fail "G240 dangling link not named ($(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# A link that loops cannot be followed either. git 2.45 passes over it as over a
# dangling one, and uses the bare repository; git 2.56 dies there ("error
# reading"). No premise, then: protected whichever git the host has.
rm -f "$A240/.git" && ln -s .git "$A240/.git" || { printf 'SCAFFOLD-FAILED: G240 loop\n'; exit 1; }
EXTRA_MOUNTS="$M240 $A240/b" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$A240/config:/workspace/m240/node_modules/a/config:ro" \
  && has_mount "$A240/hooks:/workspace/m240/node_modules/a/hooks:ro" \
  && pass "G240 so is one with a .git link that loops" \
  || fail "G240 .git link that loops (rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# A FIFO for a .git, which no warning names: git 2.45 passes over that too, and
# git 2.56 dies ("not a regular file"). Nothing here may open it (G64).
rm -f "$A240/.git" && mkfifo "$A240/.git" || { printf 'SCAFFOLD-FAILED: G240 FIFO\n'; exit 1; }
EXTRA_MOUNTS="$M240 $A240/b" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$A240/config:/workspace/m240/node_modules/a/config:ro" \
  && has_mount "$A240/hooks:/workspace/m240/node_modules/a/hooks:ro" \
  && pass "G240 so is one with a FIFO for a .git, which is not opened" \
  || fail "G240 FIFO for a .git (rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# Opened read-write first, as G64 does: a reader a damaged launcher left blocked
# on it, where no timeout bounds a read, is let go.
( exec 3<>"$A240/.git" ) 2>/dev/null; rm -f "$A240/.git"
# Outside every mount: the bare repository is the one judged, and the walk stops
# there, as it does at one with no .git in it (G176).
R240="$TMP/r240"; O240="$R240/o.git"
"${G[@]}" init -q "$R240" && "${G[@]}" -C "$R240" commit -q --allow-empty -m i \
  && "${G[@]}" init -q --bare "$O240" && mkdir -p "$O240/w/h" \
  && "${G[@]}" --git-dir="$O240" config core.hooksPath "$O240/w/h" \
  && "${G[@]}" --git-dir="$R240/.git" config core.hooksPath "$O240/w/h" && ln -s nowhere "$O240/.git" \
  && [[ "$("${G[@]}" -C "$O240/w" rev-parse --absolute-git-dir 2>/dev/null)" == "$O240" ]] \
  || { printf 'SCAFFOLD-FAILED: G240 outside\n'; exit 1; }
EXTRA_MOUNTS="$O240/w" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "NOTE: $O240 runs its git hooks from /workspace/w/h (core.hooksPath)" "$ERR" \
  && pass "G240 a bare repository outside every mount, a dangling .git link in it, is judged" \
  || fail "G240 outside bare repository not judged (rc=$LAUNCH_RC; $(grep -E 'NOTE|WARNING|ERROR' "$ERR" | head -3 | tr '\n' ' '))"
! grep -qF "$R240/.git runs its git hooks" "$ERR" \
  && pass "G240 …and the repository above it, which git does not reach, is not" \
  || fail "G240 the walk went on past the bare repository ($(grep -F 'runs its git hooks' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$M240" "$R240"

# ── G219: a linked worktree's checkout whose .git is a link to a file ────────
# Under a pruned node_modules a checkout reached through its worktree's gitdir
# is read only if its .git names the worktree back (_gdi_points_back(), GIT-57).
# A .git that is a link to such a file is named, never followed, so that check
# alone reaches the checkout: its submodule is protected and the worktree is
# not said to have none (GAP-2's whole-file run, batch 3, item 1).
U219="$TMP/up219"; A219="$PROJ/node_modules/aw219"
"${G[@]}" init -q "$U219" && "${G[@]}" -C "$U219" commit -q --allow-empty -m u \
  && "${G[@]}" -C "$PROJ" worktree add -q "$A219" -b aw219 \
  && "${G[@]}" clone -q "$U219" "$A219/sub" && "${G[@]}" -C "$A219" add sub 2>/dev/null && "${G[@]}" -C "$A219" commit -q -m n \
  && mv "$A219/.git" "$TMP/gf219" && ln -s "$TMP/gf219" "$A219/.git" \
  || { printf 'SCAFFOLD-FAILED: G219\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$A219/sub/.git/config:/workspace/proj/node_modules/aw219/sub/.git/config:ro" \
  && ! grep -qF "no worktree is known for $PROJ/.git/worktrees/aw219" "$ERR" \
  && pass "G219 a checkout whose .git is a link to a file naming its worktree back is read, and its submodule protected" \
  || fail "G219 linked .git under node_modules (rc=$LAUNCH_RC; $(grep -F aw219 "$ERR" | head -2 | tr '\n' ' '))"

# ── G220: a decoy that has a .git file, which does not point back ───────────
# The worktree's gitdir rewritten to name a directory under node_modules whose
# .git file holds no gitdir: line, or names a path outside every mount that is
# not there: neither is the checkout, the real one goes unread, and that is said
# (batch 3, item 1). The decoy is there, so no "which is not there" (item 2).
cp "$PROJ/.git/worktrees/aw219/gitdir" "$TMP/gitdir219"
for k220 in x gone; do
  rm -rf "$PROJ/node_modules/dec220"; mkdir -p "$PROJ/node_modules/dec220"
  if [[ "$k220" == x ]]; then printf 'x\n' > "$PROJ/node_modules/dec220/.git"
  else printf 'gitdir: %s\n' "$TMP/nowhere220" > "$PROJ/node_modules/dec220/.git"; fi
  printf '%s\n' "$PROJ/node_modules/dec220/.git" > "$PROJ/.git/worktrees/aw219/gitdir"
  launch ..
  grep -qF "no worktree is known for $PROJ/.git/worktrees/aw219" "$ERR" \
    && pass "G220 a decoy whose .git does not point back ($k220) leaves the worktree named" \
    || fail "G220 decoy .git $k220 (rc=$LAUNCH_RC; $(grep -F WARNING "$ERR" | head -2 | tr '\n' ' '))"
  [[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "which is not there" "$ERR" \
    && pass "G221 a checkout that is there is not said to be gone ($k220)" \
    || fail "G221 called gone, $k220 (rc=$LAUNCH_RC; $(grep -F 'not there' "$ERR" | head -1))"
done
rm -rf "$PROJ/node_modules/dec220"
# A gitdir naming a path through a link to a directory: a link on the way is not
# "gone" (batch 3, item 2).
mkdir -p "$TMP/lnkd222" && ln -s "$TMP/lnkd222" "$TMP/lnk222" \
  && printf '%s\n' "$TMP/lnk222/missing/.git" > "$PROJ/.git/worktrees/aw219/gitdir" || { printf 'SCAFFOLD-FAILED: G222\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "no worktree is known for $PROJ/.git/worktrees/aw219" "$ERR" && ! grep -qF "which is not there" "$ERR" \
  && pass "G222 a checkout named through a link on the way is not said to be gone" \
  || fail "G222 link on the way (rc=$LAUNCH_RC; $(grep -F 'aw219' "$ERR" | head -3 | tr '\n' ' '))"
cp "$TMP/gitdir219" "$PROJ/.git/worktrees/aw219/gitdir"; rm -rf "$TMP/gitdir219" "$TMP/lnk222" "$TMP/lnkd222"
rm -f "$A219/.git"; mv "$TMP/gf219" "$A219/.git"
"${G[@]}" -C "$PROJ" worktree remove --force "$A219"; "${G[@]}" -C "$PROJ" branch -q -D aw219

# ── G223: a submodule recorded through a link, at a directory you cannot search ─
# The index records l223/sub, l223 a link in the mount to real223, and
# real223/sub cannot be searched. _gdi_blocked() returns at the link, protecting
# nothing there, so the gitlink is still named as not where the index says
# (batch 3, item 3). Not as root, which searches any directory.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$PROJ/real223" && "${G[@]}" clone -q "$U219" "$PROJ/real223/sub" && ln -s real223 "$PROJ/l223" \
    && "${G[@]}" -C "$PROJ" update-index --add --cacheinfo "160000,$(printf '%040d' 1),l223/sub" \
    && chmod 000 "$PROJ/real223/sub" || { printf 'SCAFFOLD-FAILED: G223\n'; exit 1; }
  launch ..
  grep -qF "WARNING: submodule $PROJ/l223/sub of $PROJ/.git is not where its index says" "$ERR" \
    && pass "G223 a gitlink through a link to a directory you cannot search is named" \
    || fail "G223 gitlink through a link (rc=$LAUNCH_RC; $(grep -F l223 "$ERR" | head -2 | tr '\n' ' '))"
  # update-index, not rm --cached, which refuses a gitlink path through a link.
  chmod 755 "$PROJ/real223/sub"; "${G[@]}" -C "$PROJ" update-index --force-remove l223/sub; rm -rf "$PROJ/real223" "$PROJ/l223"
  [[ -z "$("${G[@]}" -C "$PROJ" ls-files -s l223/sub)" ]] || fail "G223 SCAFFOLD: the gitlink l223/sub is still in the project's index"
else
  printf 'NOTE: G223 not run as root, which searches any directory\n'
fi
rm -rf "$U219"

# ── G224: what _gd_resolve() names, and where ────────────────────────────────
# A .git file naming a path that is not there outside every mount: the agent
# cannot make it, so it is not named (batch 3, item 4).
mkdir -p "$PROJ/x224" && printf 'gitdir: %s\n' "$TMP/nowhere224" > "$PROJ/x224/.git" || { printf 'SCAFFOLD-FAILED: G224\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/x224/.git:/workspace/proj/x224/.git:ro" && ! grep -qF "$TMP/nowhere224, which does not exist" "$ERR" \
  && pass "G224 a .git naming a path not there outside every mount is not named" \
  || fail "G224 outside path (rc=$LAUNCH_RC; $(grep -F nowhere224 "$ERR" | head -1))"
rm -rf "$PROJ/x224"
# One whose path reads, its .. taken by name, as outside every mount, while the
# link it goes through lies inside one: named as reached through that link.
mkdir -p "$TMP/realb225/x/y" "$PROJ/b225" && "${G[@]}" init -q --bare "$TMP/realb225/gd" && ln -s "$TMP/realb225/x/y" "$PROJ/lb225" \
  && printf 'gitdir: %s\n' "$PROJ/lb225/../../gd" > "$PROJ/b225/.git" || { printf 'SCAFFOLD-FAILED: G225\n'; exit 1; }
launch ..
grep -qF "WARNING: $PROJ/b225/.git reaches $TMP/realb225/gd through a link inside the mount" "$ERR" \
  && pass "G225 a link inside the mount on a path that reads as outside it is named" \
  || fail "G225 link inside, path outside (rc=$LAUNCH_RC; $(grep -F b225 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/b225" "$PROJ/lb225" "$TMP/realb225"

# ── G290: the directory that blocks a pointer's way is taken where it is ──────
# _gdi_blocked() walked a pointer's path as written. A checkout named through a
# link outside the mounts was then found spelled through the link, under no
# mount's source, and was neither bound nor named once the agent had made it
# unsearchable; and a `..` after such a link was stepped by name, where the
# kernel steps from where the link leads (bugs review GIT-96). The way is now
# walked as the kernel walks it. One launch, a worktree for each way; a mode
# stops nothing as root.
if [[ "$(id -u)" != 0 ]]; then
  nm290="$PROJ/node_modules"; o290="$TMP/o290"; wt290="$PROJ/.git/worktrees"
  mkdir -p "$nm290" "$o290" "$PROJ/sub290" "$PROJ/.venv/a/b" || { printf 'SCAFFOLD-FAILED: G290 dirs\n'; exit 1; }
  for k290 in k1 k2 k3 k4 k6; do
    "${G[@]}" -C "$PROJ" worktree add -q "$nm290/$k290" -b "b290$k290" 2>/dev/null || { printf 'SCAFFOLD-FAILED: G290 %s\n' "$k290"; exit 1; }
  done
  "${G[@]}" -C "$PROJ" worktree add -q "$PROJ/.venv/c5" -b b290c5 2>/dev/null \
    && "${G[@]}" -C "$PROJ" worktree add -q "$o290/k7" -b b290k7 2>/dev/null || { printf 'SCAFFOLD-FAILED: G290 c5, k7\n'; exit 1; }
  # k1: through a link outside the mounts, its target relative.
  ln -s proj/node_modules "$TMP/lk290" && printf '%s\n' "$TMP/lk290/k1/.git" > "$wt290/k1/gitdir"
  # k2: the link is the blocked name itself.
  ln -s "$nm290/k2" "$TMP/lk290b" && printf '%s\n' "$TMP/lk290b/.git" > "$wt290/k2/gitdir"
  # k3: a `..` after a link, which the kernel steps from where the link leads
  # ($PROJ/sub290), not from where it is written ($TMP).
  ln -s "$PROJ/sub290" "$TMP/lk290c" && printf '%s\n' "$TMP/lk290c/../node_modules/k3/.git" > "$wt290/k3/gitdir"
  # k4: a link inside the mount on the way, which the agent could have planted.
  ln -s node_modules "$PROJ/lnk290" && printf '%s\n' "$PROJ/lnk290/k4/.git" > "$wt290/k4/gitdir"
  # c5: `..` out of a link that lies inside the directory that blocks the way.
  # Below .venv nothing can be tested; the way is blocked at .venv itself.
  ln -s a/b "$PROJ/.venv/k5" && printf '%s\n' "$PROJ/.venv/k5/../../c5/.git" > "$wt290/c5/gitdir"
  # k6: a way padded with 300 `./`, none of which is a step the kernel counts.
  pad290="$(printf './%.0s' {1..300})" && printf '%s\n' "$PROJ/${pad290}node_modules/k6/.git" > "$wt290/k6/gitdir"
  # k7: a link loop on the way, which leads nowhere.
  ln -s lp290b "$TMP/lp290a" && ln -s lp290a "$TMP/lp290b" && printf '%s\n' "$TMP/lp290a/k7/.git" > "$wt290/k7/gitdir"
  chmod 000 "$nm290/k1" "$nm290/k2" "$nm290/k3" "$nm290/k4" "$nm290/k6" "$PROJ/.venv"
  launch_timed 120 ..
  m290="$(mounts)"
  [[ "$LAUNCH_RC" == 0 ]] && pass "G290 the launch goes ahead, a link loop on one way" \
    || fail "G290 launch (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -2 | tr '\n' ' '))"
  for k290 in k1 k2 k3 k6; do
    case "$k290" in
      k1) w290="a checkout named through a link outside the mounts" ;;
      k2) w290="one where the link is the checkout itself" ;;
      k3) w290="one behind a .. that follows a link, stepped as the kernel steps it" ;;
      k6) w290="one whose way is padded with ./" ;;
    esac
    grep -qxF -- "$nm290/$k290:/workspace/proj/node_modules/$k290:ro" <<<"$m290" \
      && grep -qF "WARNING: $nm290/$k290 cannot be listed by you" "$ERR" \
      && pass "G290 $w290, made unsearchable, is read-only whole and named" \
      || fail "G290 $k290: $w290 ($(grep -F "/$k290" <<<"$m290" | grep -vF /worktrees/ | tr '\n' ' '); $(grep -F "/$k290 cannot" "$ERR" | head -1))"
  done
  grep -qxF -- "$PROJ/.venv:/workspace/proj/.venv:ro" <<<"$m290" \
    && pass "G290 a way that steps back out of a link inside the blocking directory is blocked at that directory" \
    || fail "G290 c5: .venv not bound ($(grep -F '/.venv' <<<"$m290" | tr '\n' ' '))"
  ! grep -qF -- "$nm290/k4:" <<<"$m290" \
    && pass "G290 a link inside the mount on the way still ends the walk: nothing is bound for it" \
    || fail "G290 k4 bound through a link the agent could have planted ($(grep -F '/k4:' <<<"$m290" | tr '\n' ' '))"
  # With an agent of another id, a directory of yours, mode 000, still counts
  # (LNCH-25): bound whether a link names it or not. Another user's is T25j's.
  SANDBOX_UID=4242 SANDBOX_GID=4242 launch_timed 120 ..
  [[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$nm290/k2:/workspace/proj/node_modules/k2:ro" <<<"$(mounts)" \
    && grep -qxF -- "$nm290/k1:/workspace/proj/node_modules/k1:ro" <<<"$(mounts)" \
    && pass "G290 one of yours under another agent uid is read-only whole, a link to it or not (LNCH-25)" \
    || fail "G290 agent of another id (rc=$LAUNCH_RC; $(mounts | grep -F -e '/k1:' -e '/k2:' | tr '\n' ' '))"
  chmod 755 "$nm290/k1" "$nm290/k2" "$nm290/k3" "$nm290/k4" "$nm290/k6" "$PROJ/.venv"
  rm -rf "$nm290/k1" "$nm290/k2" "$nm290/k3" "$nm290/k4" "$nm290/k6" "$PROJ/.venv" "$PROJ/sub290" "$o290" \
    "$PROJ/lnk290" "$TMP/lk290" "$TMP/lk290b" "$TMP/lk290c" "$TMP/lp290a" "$TMP/lp290b"
  "${G[@]}" -C "$PROJ" worktree prune 2>/dev/null
  for k290 in k1 k2 k3 k4 k6 c5 k7; do "${G[@]}" -C "$PROJ" branch -q -D "b290$k290" 2>/dev/null; done
else
  printf 'NOTE: run as root, which searches any directory; G290 is not applicable\n'
fi

# ── G293: the directory that blocks a pointer's way, spelled as on disk ───────
# _gdi_blocked() compared the directory that blocks the way with the mounts'
# sources as the way spelled it. Where names ignore case (APFS by default), a
# pointer written $TMP/PROJ/… for a mount of $TMP/proj, or through macOS's
# /System/Volumes/Data firmlink, reached the same directory under no source, and
# nothing was bound or said (bugs review GIT-98). Each way where this host has it.
if [[ "$(id -u)" != 0 ]]; then
  nm293="$PROJ/node_modules"; wt293="$PROJ/.git/worktrees"; k293s=()
  [[ "$TMP/PROJ" -ef "$PROJ" ]] && k293s+=(k8)
  [[ -d "/System/Volumes/Data$PROJ" && "/System/Volumes/Data$PROJ" -ef "$PROJ" ]] && k293s+=(k9)
  if (( ${#k293s[@]} )); then
    mkdir -p "$nm293" || { printf 'SCAFFOLD-FAILED: G293 dirs\n'; exit 1; }
    for k293 in "${k293s[@]}"; do
      "${G[@]}" -C "$PROJ" worktree add -q "$nm293/$k293" -b "b293$k293" 2>/dev/null || { printf 'SCAFFOLD-FAILED: G293 %s\n' "$k293"; exit 1; }
    done
    # k8: the mount's own directory in another case. k9: through the firmlink.
    [[ " ${k293s[*]} " != *" k8 "* ]] || printf '%s\n' "$TMP/PROJ/node_modules/k8/.git" > "$wt293/k8/gitdir"
    [[ " ${k293s[*]} " != *" k9 "* ]] || printf '%s\n' "/System/Volumes/Data$PROJ/node_modules/k9/.git" > "$wt293/k9/gitdir"
    for k293 in "${k293s[@]}"; do chmod 000 "$nm293/$k293"; done
    launch_timed 120 ..
    m293="$(mounts)"
    for k293 in "${k293s[@]}"; do
      case "$k293" in
        k8) w293="a checkout named with the mount's directory in another case" ;;
        k9) w293="a checkout named through the /System/Volumes/Data firmlink" ;;
      esac
      [[ "$LAUNCH_RC" == 0 ]] && grep -qxF -- "$nm293/$k293:/workspace/proj/node_modules/$k293:ro" <<<"$m293" \
        && grep -qF "WARNING: $nm293/$k293 cannot be listed by you" "$ERR" \
        && pass "G293 $w293, made unsearchable, is read-only whole and named" \
        || fail "G293 $k293: $w293 (rc=$LAUNCH_RC; $(grep -F "/$k293" <<<"$m293" | grep -vF /worktrees/ | tr '\n' ' '); $(grep -F "/$k293 cannot" "$ERR" | head -1))"
    done
    for k293 in "${k293s[@]}"; do chmod 755 "$nm293/$k293"; rm -rf "${nm293:?}/$k293"; done
    "${G[@]}" -C "$PROJ" worktree prune 2>/dev/null
    for k293 in "${k293s[@]}"; do "${G[@]}" -C "$PROJ" branch -q -D "b293$k293" 2>/dev/null; done
  else
    printf 'NOTE: names here are case-sensitive and there is no firmlink; G293 is not applicable\n'
  fi
else
  printf 'NOTE: run as root, which searches any directory; G293 is not applicable\n'
fi

# ── G291: a very long pointer is walked in time linear in its length ─────────
# _gdi_blocked() took a pointer's way apart one component at a time off the
# front of what was left, copying the rest at every step, so the cost grew with
# the square of the way's length: a core.worktree of 16 KB cost a launch a
# minute, and the check after the session ran out of its time (bugs review
# GIT-97). The way is now split once. The function alone, since a core.worktree
# that long now refuses the launch (GIT-101; G292): 64 KB of `./`, half before
# a link outside the mounts and half after it. The link's target is two
# components, walked in their order, and the first is itself a link, to an
# absolute path: the second waits while that one is followed, and the way then
# goes on. And a directory named `*` on the way, which the split must leave a
# name. G290 and G292 check the walk through a launch. As root a mode stops
# nothing.
if [[ "$(id -u)" != 0 ]]; then
  R291="$TMP/r291"; mkdir -p "$R291/node_modules/*/cw291" && ln -s lkb291/node_modules "$TMP/lk291" && ln -s "$R291" "$TMP/lkb291" \
    && chmod 000 "$R291/node_modules/*/cw291" || { printf 'SCAFFOLD-FAILED: G291\n'; exit 1; }
  printf -v pad291 '%*s' 16000 ''; pad291="${pad291// /./}"
  fns291="$TMP/fns291.sh"
  for f291 in _path_parts _gdi_blocked _readlink_exact _in_writable _cd_bash; do
    awk -v f="$f291() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
  done > "$fns291"
  # The agent's identity unset: every directory counts, as in the check after a session.
  # Spelling as on disk (GIT-98) is G293's; here the directory is spelled as bash does.
  # A way written with ./ in it is not one the record holds (GIT-105): the stub
  # would say so.
  o291="$(p_timeout 30 bash -c 'set -euo pipefail; source "$1"; _cd_phys() { _cd_bash "$@"; }; bsrc=("$2"); declare -A had=(); _gdi_unr=(); unset uid gid
    _git_report_record() { printf "recorded %s\n" "$2"; }
    _gdi_blocked "$3" "$2" && printf "%s\n" "${_gdi_unr[@]}"' _ "$fns291" "$R291" "$TMP/${pad291}lk291/${pad291}*/cw291/x" 2>&1)"
  rc291=$?
  [[ "$rc291" == 0 && "$o291" == "$R291/node_modules/*/cw291" ]] \
    && pass "G291 a way of 64 KB through a link is walked in time, and the directory that blocks it is found" \
    || fail "G291 long pointer (rc=$rc291, 124 is the 30 s clock; got: $(head -c 300 <<<"$o291" | tr '\n' ' '))"
  chmod 755 "$R291/node_modules/*/cw291"; rm -rf "$R291" "$TMP/lk291" "$TMP/lkb291" "$fns291"
else
  printf 'NOTE: run as root, which searches any directory; G291 is not applicable\n'
fi

# ── G292: a core.worktree too long for this launcher to enter ────────────────
# git reads core.worktree from a git directory's config and config.worktree,
# and follows an absolute one a component at a time, whatever its length. The
# launcher enters it with one cd, which the kernel refuses at PATH_MAX: the
# checkout git uses was then no worktree here, the submodules its index
# records were not followed, and one under a pruned node_modules went
# unprotected behind "no worktree is known" (bugs review GIT-101). One of more
# than 1000 bytes that cannot be entered now refuses the launch, naming the
# file and the length, never the value.
mk292() {  # a git directory whose index records the gitlink sm; its work tree, holding sm/.git, under node_modules
  M292="$TMP/m292"; W292="$M292/node_modules/w"; G292="$M292/g.git"
  if [[ -d "$M292" ]]; then chmod -R u+rwx "$M292" 2>/dev/null; rm -rf "$M292"; fi
  mkdir -p "$W292" && "${G[@]}" init -q --bare "$G292" && "${G[@]}" init -q "$W292/sm" \
    && "${G[@]}" -C "$W292/sm" commit -q --allow-empty -m s && "${G[@]}" --git-dir="$G292" config core.bare false \
    && "${G[@]}" --git-dir="$G292" --work-tree="$W292" add sm 2>/dev/null || { printf 'SCAFFOLD-FAILED: G292 layout\n'; exit 1; }
}
pad292() { local s; printf -v s '%*s' "$1" ''; printf '%s' "${s// /./}"; }   # $1 times ./
bytes292() { local LC_ALL=C; printf '%s' "${#1}"; }
fit292() {  # $1 = bytes wanted, $2 = the last component: an absolute path under $M292 of exactly that length
  local v="$M292/" n; n=$(( ($1 - ${#v} - ${#2}) / 2 )); v+="$(pad292 "$n")"
  if (( ${#v} + ${#2} < $1 )); then v+="/"; fi
  printf '%s' "$v$2"
}
set292() { "${G[@]}" config --file "$1" core.worktree "$2" || { printf 'SCAFFOLD-FAILED: G292 config\n'; exit 1; }; }
refused292() {  # $1 = the config file named, $2 = the value
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $1 sets a core.worktree of $(bytes292 "$2") bytes that this launcher cannot enter; refusing the launch." "$ERR"
}
prot292() { [[ "$LAUNCH_RC" == 0 ]] && grep -qF -- "$W292/sm/.git/config:" <<<"$(mounts)"; }
why292() { printf 'rc=%s; %s; sm binds: %s' "$LAUNCH_RC" "$(grep -E '^(ERROR|WARNING)' "$ERR" | head -2 | cut -c1-160 | tr '\n' ' ')" "$(mounts | grep -cF -- "$W292/sm/.git/")"; }
# An absolute one, 6 KB of ./ in it: git uses the directory it names.
mk292; v292="$M292/$(pad292 3000)node_modules/w"; set292 "$G292/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
refused292 "$G292/config" "$v292" \
  && pass "G292 an absolute core.worktree too long to enter refuses the launch, naming the config and the length" \
  || fail "G292 long absolute core.worktree in config ($(why292))"
grep -qF "absolute path of any length, a component at a time" "$ERR" && grep -qF "if it is not, remove the core.worktree from it." "$ERR" \
  && ! grep -qF "$(pad292 20)" "$ERR" \
  && pass "G292 the refusal says why, and never prints the value" \
  || fail "G292 the refusal's words ($(grep -A3 -F 'sets a core.worktree' "$ERR" | cut -c1-200 | tr '\n' ' '))"
# The same in config.worktree, which git reads once the extension is on.
mk292; "${G[@]}" --git-dir="$G292" config extensions.worktreeConfig true; set292 "$G292/config.worktree" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
refused292 "$G292/config.worktree" "$v292" \
  && pass "G292 one in config.worktree refuses the launch too, naming that file" \
  || fail "G292 long core.worktree in config.worktree ($(why292))"
# A relative one of 4094 bytes: git enters it (chdir of the value), and this
# launcher, which writes ./ before it, cannot.
mk292; v292="$(pad292 2038)..//node_modules/w"; set292 "$G292/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
[[ "$(bytes292 "$v292")" == 4094 ]] && refused292 "$G292/config" "$v292" \
  && pass "G292 a relative one of 4094 bytes, which git can still enter, refuses the launch" \
  || fail "G292 relative core.worktree of $(bytes292 "$v292") bytes ($(why292))"
# One of about 1.4 KB that can be entered is followed as before; where it cannot
# (a Mac, whose paths end at 1024 bytes) it is refused.
mk292; v292="$M292/$(pad292 700)node_modules/w"; set292 "$G292/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
if (cd -P -- "$v292") 2>/dev/null; then
  prot292 && pass "G292 a long core.worktree that can be entered is followed, the checkout behind it protected" \
    || fail "G292 long and enterable ($(why292))"
else
  refused292 "$G292/config" "$v292" && pass "G292 a long core.worktree this host cannot enter is refused" \
    || fail "G292 long and not enterable here ($(why292))"
fi
# The bound, on a path that is not there: 1000 bytes is said as before, 1001 refuses.
mk292; v292="$(fit292 1000 gone292)"; set292 "$G292/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
[[ "$(bytes292 "$v292")" == 1000 && "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: no worktree is known for $G292" "$ERR" \
  && pass "G292 one of 1000 bytes that cannot be entered is not refused: no worktree is known, as before" \
  || fail "G292 1000 bytes ($(bytes292 "$v292") bytes; $(why292))"
mk292; v292="$(fit292 1001 gone292)"; set292 "$G292/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
[[ "$(bytes292 "$v292")" == 1001 ]] && refused292 "$G292/config" "$v292" \
  && pass "G292 one of 1001 bytes that cannot be entered refuses the launch" \
  || fail "G292 1001 bytes ($(bytes292 "$v292") bytes; $(why292))"
# Bytes, not characters: 400 characters of three bytes each are 1200 bytes.
# Launched in a UTF-8 locale, where the two counts differ; in the C locale a
# count of characters is one of bytes, and the check would say nothing.
u292=""
while IFS= read -r l292; do
  case "${l292,,}" in c.utf-8|c.utf8|en_us.utf-8|en_us.utf8) u292="$l292" ;; esac
done < <(locale -a 2>/dev/null)
if [[ -n "$u292" ]]; then
  mk292; printf -v v292 '%*s' 400 ''; v292="$M292/${v292// /€}"; set292 "$G292/config" "$v292"
  LC_ALL="$u292" EXTRA_MOUNTS="$M292" launch "$TMP/app"
  (( $(bytes292 "$v292") > 1200 )) && refused292 "$G292/config" "$v292" \
    && pass "G292 the length is counted in bytes: 400 characters of three bytes refuse the launch" \
    || fail "G292 multibyte ($(bytes292 "$v292") bytes, in $u292; $(why292))"
else
  printf 'NOTE: no UTF-8 locale on this host; G292 does not check that the length is counted in bytes\n'
fi
# A short one behind a directory you cannot search: that directory is protected
# whole, as before (GIT-60). As root a mode stops nothing.
if [[ "$(id -u)" != 0 ]]; then
  mk292; set292 "$G292/config" "$W292/sm"; chmod 000 "$W292"
  EXTRA_MOUNTS="$M292" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$W292:/workspace/m292/node_modules/w:ro" && grep -qF "WARNING: $W292 cannot be listed by you" "$ERR" \
    && pass "G292 a short core.worktree behind a directory you cannot search has that directory read-only whole and named" \
    || fail "G292 short and blocked (rc=$LAUNCH_RC; $(mounts | grep -F '/node_modules/w:' | tr '\n' ' '); $(grep -F 'cannot be listed' "$ERR" | head -1))"
  chmod 755 "$W292"
else
  pass "G292 skipped: as root a mode stops nothing"
fi
# With extensions.worktreeConfig on, a linked worktree takes the common
# config's core.worktree from its own git directory: one the repository's .git
# can enter and the worktree's cannot.
mk292; R292="$M292/r"; "${G[@]}" init -q "$R292" && "${G[@]}" -C "$R292" commit -q --allow-empty -m i && mkdir "$R292/sub292" \
  && "${G[@]}" -C "$R292" worktree add -q "$M292/co292" -b b292 2>/dev/null \
  && "${G[@]}" -C "$R292" config extensions.worktreeConfig true || { printf 'SCAFFOLD-FAILED: G292 worktree\n'; exit 1; }
v292="$(pad292 600)../sub292"; set292 "$R292/.git/config" "$v292"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
refused292 "$R292/.git/config" "$v292" \
  && pass "G292 a common core.worktree the linked worktree's directory cannot enter refuses the launch" \
  || fail "G292 the linked worktree's place ($(why292))"
# A repository the session makes with one: the check after it is cut short and
# says so; the next launch refuses.
mk292; v292="$M292/$(pad292 3000)gone292"
FAKE_SESSION="git init -q '$M292/new292' && git -C '$M292/new292' config core.worktree '$v292'" EXTRA_MOUNTS="$M292" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: the writable mounts could not all be searched for git repositories the session" "$ERR" \
  && pass "G292 one in a repository the session made: the check after it says the search was cut short" \
  || fail "G292 after the session (rc=$LAUNCH_RC; $(grep -E '^(ERROR|WARNING)' "$ERR" | head -2 | cut -c1-160 | tr '\n' ' '))"
EXTRA_MOUNTS="$M292" launch "$TMP/app"
refused292 "$M292/new292/.git/config" "$v292" \
  && pass "G292 … and the next launch refuses it" \
  || fail "G292 the launch after the session ($(why292))"
chmod -R u+rwx "$M292" 2>/dev/null; rm -rf "$M292"

# ── G295: a common core.worktree the linked worktree's place cannot enter ────
# With extensions.worktreeConfig on, a linked worktree takes the common
# config's core.worktree, and a relative one from its own git directory, which
# leads elsewhere than from the repository's. Where a directory on that way
# cannot be searched, nothing asked for it, as GIT-60's fallback does for a git
# directory's own config: under a pruned node_modules it was neither bound nor
# named, and the agent, which can chmod a directory it owns, could restore it
# in the next session (bugs review GIT-103). Asked whatever the extension
# says, as config.worktree is read (GIT-81): anything of yours can turn it on.
# As root a mode stops nothing.
M295="$TMP/m295"; R295="$M295/r"; W295="$R295/node_modules/w"
mk295() {  # $1 = the value. A repository with a linked worktree, and a directory under node_modules that ../../../node_modules/w/co reaches from the worktree's git directory alone
  if [[ -d "$M295" ]]; then chmod -R u+rwx "$M295" 2>/dev/null; rm -rf "$M295"; fi
  "${G[@]}" init -q "$R295" && "${G[@]}" -C "$R295" commit -q --allow-empty -m i && mkdir -p "$W295/co" "$R295/src" \
    && "${G[@]}" -C "$R295" worktree add -q "$M295/lw295" -b b295 2>/dev/null \
    && "${G[@]}" config --file "$R295/.git/config" core.worktree "$1" \
    && [[ -d "$R295/.git/worktrees/lw295/../../../node_modules/w/co" && ! -e "$R295/.git/../../../node_modules" ]] \
    && [[ -d "$R295/.git/../src" && ! -e "$R295/.git/worktrees/lw295/../src" ]] \
    || { printf 'SCAFFOLD-FAILED: G295 layout\n'; exit 1; }
}
why295() { printf 'rc=%s; %s; %s' "$LAUNCH_RC" "$(mounts | grep -F '/node_modules/w:' | tr '\n' ' ')" "$(grep -E '^(ERROR|WARNING)' "$ERR" | head -2 | cut -c1-160 | tr '\n' ' ')"; }
if [[ "$(id -u)" != 0 ]]; then
  mk295 ../../../node_modules/w/co; "${G[@]}" config --file "$R295/.git/config" extensions.worktreeConfig true; chmod 000 "$W295"
  EXTRA_MOUNTS="$M295" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$W295:/workspace/m295/r/node_modules/w:ro" && grep -qF "WARNING: $W295 cannot be listed by you" "$ERR" \
    && pass "G295 a directory that blocks a common core.worktree from the linked worktree's directory is read-only whole and named" \
    || fail "G295 the linked worktree's place, blocked ($(why295))"
  mk295 ../../../node_modules/w/co; chmod 000 "$W295"
  EXTRA_MOUNTS="$M295" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$W295:/workspace/m295/r/node_modules/w:ro" && grep -qF "WARNING: $W295 cannot be listed by you" "$ERR" \
    && pass "G295 … and with extensions.worktreeConfig off too, which anything of yours can turn on" \
    || fail "G295 the linked worktree's place, the extension off ($(why295))"
  chmod 755 "$W295"
else
  pass "G295 skipped: as root a mode stops nothing"
fi
# An ordinary repository: core.worktree = ../src, which the repository's .git
# enters and a linked worktree's directory does not, with nothing on the way
# that cannot be searched. The fallback finds nothing, and the launch goes on.
mk295 ../src
EXTRA_MOUNTS="$M295" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF -- "/node_modules/w:" <<<"$(mounts)" && ! grep -qF "cannot be listed" "$ERR" \
  && pass "G295 a common core.worktree that only leads nowhere from the worktree's directory changes nothing" \
  || fail "G295 the linked worktree's place, nothing blocked ($(why295))"
if [[ -d "$M295" ]]; then chmod -R u+rwx "$M295" 2>/dev/null; rm -rf "$M295"; fi

# ── G241 to G251: GAP-2's whole-file run, batch 4 ────────────────────────────
# Each check below kills survivors of the Linux machine's measurement of
# sandbox.sh, by the brief's layouts (feature-gaps review, GAP-2, batch 4).
# As root a mode stops nothing, so G241, G244 and G249 are skipped there.
skip_root() { pass "$1 skipped: as root a mode stops nothing"; }

# G241 (item 1): a gitlink at a directory of yours, mode 000, with an agent of
# another id: _gdi_blocked() counts it as the agent's to reach, since a share
# that remaps ownership shows what the agent made as yours (LNCH-25), and it is
# read-only whole and named. Another user's it cannot enter is T25j's.
if [[ "$(id -u)" != 0 ]]; then
  "${G[@]}" init -q "$PROJ/sm241" && "${G[@]}" -C "$PROJ/sm241" commit -q --allow-empty -m s \
    && "${G[@]}" -C "$PROJ" add sm241 2>/dev/null && chmod 000 "$PROJ/sm241" || { printf 'SCAFFOLD-FAILED: G241\n'; exit 1; }
  SANDBOX_UID=4242 SANDBOX_GID=4242 launch ..
  grep -qF "WARNING: $PROJ/sm241 cannot be listed by you" "$ERR" \
    && pass "G241 a gitlink at a directory of yours, under another agent uid, is read-only whole and named (LNCH-25)" \
    || fail "G241 unreachable gitlink (rc=$LAUNCH_RC; $(grep -F sm241 "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$PROJ/sm241"; "${G[@]}" -C "$PROJ" update-index --force-remove sm241; rm -rf "$PROJ/sm241"
  [[ -z "$("${G[@]}" -C "$PROJ" ls-files -s sm241)" ]] || fail "G241 SCAFFOLD: the gitlink sm241 is still in the project's index"
else skip_root G241; fi

# G242 (item 2): what the walk up names as a .git link: not a .git directory,
# and not a link under a read-only overlay.
M242="$TMP/m242"; mkdir -p "$M242/node_modules/a/b" "$M242/node_modules/a/.git" || { printf 'SCAFFOLD-FAILED: G242\n'; exit 1; }
EXTRA_MOUNTS="$M242 $M242/node_modules/a/b" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "is a symlink inside a writable mount" "$ERR" \
  && pass "G242 a .git directory on the walk up is not named as a link" \
  || fail "G242 directory named as a link (rc=$LAUNCH_RC; $(grep -F symlink "$ERR" | head -1))"
rm -rf "$M242"; mkdir -p "$M242/L/a/b" "$TMP/nongit242" && : > "$M242/L/sandbox.sh" && : > "$M242/L/sandbox-common.sh" \
  && ln -s "$TMP/nongit242" "$M242/L/a/.git" || { printf 'SCAFFOLD-FAILED: G242 overlay\n'; exit 1; }
EXTRA_MOUNTS="$M242 $M242/L/a/b" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$M242/L:/workspace/m242/L:ro" && ! grep -qF "is a symlink inside a writable mount" "$ERR" \
  && pass "G242 a .git link under a read-only overlay is not named" \
  || fail "G242 link under an overlay named (rc=$LAUNCH_RC; $(grep -F symlink "$ERR" | head -1))"
rm -rf "$M242" "$TMP/nongit242"

# G243 (item 3): one scan reaching the same git directory outside the mounts
# twice, by the walk up and by a .git file in the mount: the launch starts.
R243="$TMP/r243"; "${G[@]}" init -q "$R243" && "${G[@]}" -C "$R243" commit -q --allow-empty -m i && mkdir -p "$R243/sub/x" \
  && printf 'gitdir: ../../.git\n' > "$R243/sub/x/.git" || { printf 'SCAFFOLD-FAILED: G243\n'; exit 1; }
launch "$R243/sub"
[[ "$LAUNCH_RC" == 0 && -s "$CAPTURE" ]] \
  && pass "G243 a git directory outside the mounts reached twice by one scan does not end the launch" \
  || fail "G243 reached twice (rc=$LAUNCH_RC; $(tail -n 2 "$ERR" | tr '\n' ' '))"
rm -rf "$R243"

# G244 (item 4): a worktrees/ directory, or one in it, you can search but not
# list, in a git directory reached through a .git file under node_modules:
# refused, as one the scan finds is.
if [[ "$(id -u)" != 0 ]]; then
  S244="$PROJ/node_modules/sgd244"; mkdir -p "$PROJ/node_modules" && "${G[@]}" init -q --separate-git-dir "$S244" "$PROJ/w244" \
    && "${G[@]}" -C "$PROJ/w244" commit -q --allow-empty -m i && "${G[@]}" -C "$PROJ/w244" worktree add -q "$PROJ/w244b" -b wb244 \
    && chmod 300 "$S244/worktrees" || { printf 'SCAFFOLD-FAILED: G244\n'; exit 1; }
  launch ..
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $S244/worktrees can be searched but not listed by you" "$ERR" \
    && pass "G244 a worktrees/ you can search but not list refuses the launch" \
    || fail "G244 worktrees/ (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$S244/worktrees"; rm -rf "$PROJ/w244b"; chmod 300 "$S244/worktrees/w244b"
  launch ..
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $S244/worktrees/w244b can be searched but not listed by you" "$ERR" \
    && pass "G244 a worktree's directory there you can search but not list refuses the launch" \
    || fail "G244 worktree directory (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$S244/worktrees/w244b"; rm -rf "$PROJ/w244" "$S244"; rmdir "$PROJ/node_modules" 2>/dev/null || true
else skip_root G244; fi

# G245 (item 5): the walk up stops at the repository git uses, past a
# repository's .git and past a bare repository with no .git in it.
R245="$TMP/r245"; "${G[@]}" init -q "$R245" && "${G[@]}" init -q "$R245/r" && "${G[@]}" -C "$R245/r" commit -q --allow-empty -m i \
  && mkdir -p "$R245/r/sub/hooks" && "${G[@]}" -C "$R245" config core.hooksPath "$R245/r/sub/hooks" || { printf 'SCAFFOLD-FAILED: G245\n'; exit 1; }
launch "$R245/r/sub"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$R245/.git runs its git hooks" "$ERR" \
  && pass "G245 the walk up stops at a repository's .git, the one above it not judged" \
  || fail "G245 past a .git (rc=$LAUNCH_RC; $(grep -F 'runs its git hooks' "$ERR" | head -1))"
rm -rf "$R245"; "${G[@]}" init -q "$R245" && "${G[@]}" -C "$R245" commit -q --allow-empty -m i && "${G[@]}" init -q --bare "$R245/a" \
  && mkdir -p "$R245/a/b/hooks" && "${G[@]}" --git-dir="$R245/a" config core.worktree "$R245/a/b" \
  && "${G[@]}" -C "$R245" config core.hooksPath "$R245/a/b/hooks" || { printf 'SCAFFOLD-FAILED: G245 bare\n'; exit 1; }
launch "$R245/a/b"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$R245/.git runs its git hooks" "$ERR" \
  && pass "G245 the walk up stops at a bare repository, the one above it not judged" \
  || fail "G245 past a bare repository (rc=$LAUNCH_RC; $(grep -F 'runs its git hooks' "$ERR" | head -1))"
rm -rf "$R245"

# G246 (item 6): a .git file above a nested mount, past the outer mount's scan
# and found by the walk alone, is bound read-only in the outer mount's view.
M246="$TMP/m246"; mkdir -p "$M246/node_modules" && "${G[@]}" init -q --separate-git-dir "$TMP/gdr246" "$M246/node_modules/r" \
  && "${G[@]}" -C "$M246/node_modules/r" commit -q --allow-empty -m i && mkdir "$M246/node_modules/r/sub" || { printf 'SCAFFOLD-FAILED: G246\n'; exit 1; }
EXTRA_MOUNTS="$M246 $M246/node_modules/r/sub" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$M246/node_modules/r/.git:/workspace/m246/node_modules/r/.git:ro" \
  && pass "G246 a .git file above a nested mount, found by the walk, is read-only in the outer mount" \
  || fail "G246 .git file above the mount (rc=$LAUNCH_RC; $(mounts | grep -F 'r/.git' | tr '\n' ' '); $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$M246" "$TMP/gdr246"

# G247 (item 7): a .git link above a nested mount whose target lies in the
# outer mount, past its scan: protected there.
M247="$TMP/m247"; mkdir -p "$M247/node_modules/r/sub" && "${G[@]}" init -q "$TMP/t247" && "${G[@]}" -C "$TMP/t247" commit -q --allow-empty -m i \
  && mv "$TMP/t247/.git" "$M247/node_modules/gd" && ln -s ../gd "$M247/node_modules/r/.git" || { printf 'SCAFFOLD-FAILED: G247\n'; exit 1; }
EXTRA_MOUNTS="$M247 $M247/node_modules/r/sub" launch "$TMP/app"
ok247=1; for f247 in config hooks commondir config.worktree; do has_mount "$M247/node_modules/gd/$f247:/workspace/m247/node_modules/gd/$f247:ro" || ok247=""; done
[[ "$LAUNCH_RC" == 0 && -n "$ok247" ]] \
  && pass "G247 a .git link above a nested mount, its target in the outer mount, is protected there" \
  || fail "G247 link target in the outer mount (rc=$LAUNCH_RC; $(mounts | grep -F 'node_modules/gd' | tr '\n' ' '); $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$M247" "$TMP/t247"

# G248 (item 8): a git directory named through a .git link to a .git file is
# quiet about an index it cannot read out of every mount, and says so in one.
for k248 in out in; do
  Q248="$TMP/q248$k248"; mkdir -p "$Q248/w/sub"
  if [[ "$k248" == out ]]; then g248="$TMP/gd248$k248"; else g248="$Q248/w/sub/gd"; fi
  "${G[@]}" init -q --separate-git-dir "$g248" "$Q248/w" && printf 'x\n' > "$Q248/w/sub/f" && "${G[@]}" -C "$Q248/w" add sub/f \
    && "${G[@]}" -C "$Q248/w" commit -q -m i && mv "$Q248/w/.git" "$TMP/gf248$k248" && ln -s "$TMP/gf248$k248" "$Q248/w/.git" \
    && printf garbage > "$g248/index" || { printf 'SCAFFOLD-FAILED: G248 %s\n' "$k248"; exit 1; }
  launch "$Q248/w/sub"
  if [[ "$k248" == out ]]; then
    [[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index" "$ERR" \
      && pass "G248 an unreadable index out of every mount, reached through a .git link to a file, is not named" \
      || fail "G248 out of every mount (rc=$LAUNCH_RC; $(grep -F 'cannot read the index' "$ERR" | head -1))"
  else
    [[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: cannot read the index of $g248" "$ERR" \
      && pass "G248 one in the mount is named" \
      || fail "G248 in the mount (rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  rm -rf "$Q248" "$TMP/gd248$k248" "$TMP/gf248$k248"
done

# G249 (item 9): a directory you cannot list that only another writable mount
# holds is read-only whole there, and named.
if [[ "$(id -u)" != 0 ]]; then
  A249="$TMP/a249"; B249="$TMP/b249"; "${G[@]}" init -q "$A249/r" && "${G[@]}" -C "$A249/r" commit -q --allow-empty -m i \
    && mkdir -p "$B249/node_modules" && "${G[@]}" -C "$A249/r" worktree add -q "$B249/node_modules/co" -b co249 \
    && chmod 000 "$B249/node_modules/co" || { printf 'SCAFFOLD-FAILED: G249\n'; exit 1; }
  EXTRA_MOUNTS="$A249 $B249" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$B249/node_modules/co:/workspace/b249/node_modules/co:ro" \
    && grep -qF "WARNING: $B249/node_modules/co cannot be listed by you" "$ERR" \
    && pass "G249 a directory you cannot list that only another mount holds is read-only there, and named" \
    || fail "G249 blocked in the other mount (rc=$LAUNCH_RC; $(grep -E 'WARNING|ERROR' "$ERR" | grep -F co | head -2 | tr '\n' ' '))"
  chmod 755 "$B249/node_modules/co"; rm -rf "$A249" "$B249"
else skip_root G249; fi

# G250 (item 10): a directory under a worktrees/ deeper in a .git, under a
# directory that is no git directory, is not taken for a repository.
mkdir -p "$PROJ/.git/x250/worktrees/y" || { printf 'SCAFFOLD-FAILED: G250\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 && -z "$(find "$PROJ/.git/x250/worktrees/y" -mindepth 1)" ]] && ! grep -qF "/.git/x250" < <(mounts) \
  && pass "G250 a directory under a worktrees/ that belongs to no git directory is left alone" \
  || fail "G250 taken for a repository (rc=$LAUNCH_RC; $(ls -A "$PROJ/.git/x250/worktrees/y" | tr '\n' ' '))"
rm -rf "$PROJ/.git/x250"

# G251 (item 11): a bare repository the walk reaches that a .git file lower on
# the same walk named first stops the walk all the same.
R251="$TMP/r251"; "${G[@]}" init -q "$R251" && "${G[@]}" -C "$R251" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$R251" config core.hooksPath "$R251/b/w/hooks" && "${G[@]}" init -q --bare "$R251/b" \
  && mkdir -p "$R251/b/w/hooks" "$R251/b/w/node_modules/p/sub" && printf 'gitdir: %s\n' "$R251/b" > "$R251/b/w/node_modules/p/.git" \
  || { printf 'SCAFFOLD-FAILED: G251\n'; exit 1; }
EXTRA_MOUNTS="$R251/b/w $R251/b/w/node_modules/p/sub" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$R251/.git runs its git hooks" "$ERR" \
  && pass "G251 a bare repository a .git file named first still stops the walk up" \
  || fail "G251 past a named bare repository (rc=$LAUNCH_RC; $(grep -F 'runs its git hooks' "$ERR" | head -1))"
rm -rf "$R251"

# ── G252: the check after a session knows the agent's identity ───────────────
# A directory of yours, mode 000, under an agent of another id: the check after
# the session, which had no agent identity, named it among the repositories the
# session made, though no session made anything (bugs review GIT-99, found with
# batch 4's item 1). Since LNCH-25 the launch names it and binds it read-only
# whole, and the check after the session still does not.
if [[ "$(id -u)" != 0 ]]; then
  "${G[@]}" init -q "$PROJ/sm252" && "${G[@]}" -C "$PROJ/sm252" commit -q --allow-empty -m s \
    && "${G[@]}" -C "$PROJ" add sm252 2>/dev/null && chmod 000 "$PROJ/sm252" || { printf 'SCAFFOLD-FAILED: G252\n'; exit 1; }
  SANDBOX_UID=4242 SANDBOX_GID=4242 launch ..
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: $PROJ/sm252 cannot be listed by you" "$ERR" \
    && ! grep -qF "$PROJ/sm252 (cannot be listed" "$ERR" \
    && pass "G252 a directory of yours the launch named is not reported after the session" \
    || fail "G252 false report after the session (rc=$LAUNCH_RC; $(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
  chmod 755 "$PROJ/sm252"; "${G[@]}" -C "$PROJ" update-index --force-remove sm252; rm -rf "$PROJ/sm252"
  [[ -z "$("${G[@]}" -C "$PROJ" ls-files -s sm252)" ]] || fail "G252 SCAFFOLD: the gitlink sm252 is still in the project's index"
else skip_root G252; fi

# ── G253: the repository a mount lies in, out of every mount, is quiet ───────
# Its unreadable index is the user's own and is not named at every launch (the
# walk up marks it quiet). A .git file the agent writes lower in the mount,
# naming it first, brought the warning back (bugs review GIT-100, batch 4's
# first entry to decide).
R253="$TMP/r253"; "${G[@]}" init -q "$R253" && "${G[@]}" -C "$R253" commit -q --allow-empty -m i \
  && mkdir -p "$R253/w/node_modules/p/sub" && printf 'gitdir: %s\n' "$R253/.git" > "$R253/w/node_modules/p/.git" \
  && printf garbage > "$R253/.git/index" || { printf 'SCAFFOLD-FAILED: G253\n'; exit 1; }
EXTRA_MOUNTS="$R253/w $R253/w/node_modules/p/sub" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index of $R253/.git" "$ERR" \
  && pass "G253 the repository a mount lies in, out of every mount, is quiet though a .git file in the mount names it" \
  || fail "G253 named (rc=$LAUNCH_RC; $(grep -F 'cannot read the index' "$ERR" | head -1))"
# …and without the .git file, as before.
rm -f "$R253/w/node_modules/p/.git"
EXTRA_MOUNTS="$R253/w" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "cannot read the index of $R253/.git" "$ERR" \
  && pass "G253 …and without it" \
  || fail "G253 named without the .git file (rc=$LAUNCH_RC; $(grep -F 'cannot read the index' "$ERR" | head -1))"
rm -rf "$R253"

# ── G270 to G274, G278: GAP-2's whole-file run, batch 5 ──────────────────────
# G270 (item 1): a checkout's .git directory you can search but not list, under
# a pruned node_modules and reached through its worktree's gitdir, refuses the
# launch, as one the scan finds does.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$PROJ/node_modules" && "${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/co270" -b bco270 \
    && rm "$PROJ/node_modules/co270/.git" && "${G[@]}" init -q "$PROJ/node_modules/co270" && chmod 300 "$PROJ/node_modules/co270/.git" \
    || { printf 'SCAFFOLD-FAILED: G270\n'; exit 1; }
  launch ..
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $PROJ/node_modules/co270/.git can be searched but not listed by you" "$ERR" \
    && pass "G270 a checkout's .git directory you can search but not list, in this mount, refuses the launch" \
    || fail "G270 unlistable .git in this mount (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$PROJ/node_modules/co270/.git"; rm -rf "$PROJ/node_modules/co270"; rmdir "$PROJ/node_modules" 2>/dev/null
  "${G[@]}" -C "$PROJ" worktree prune; "${G[@]}" -C "$PROJ" branch -q -D bco270
else skip_root G270; fi

# G271 (item 2): the same in another writable mount.
if [[ "$(id -u)" != 0 ]]; then
  A271="$TMP/a271"; B271="$TMP/b271"; "${G[@]}" init -q "$A271/r" && "${G[@]}" -C "$A271/r" commit -q --allow-empty -m i \
    && mkdir -p "$B271/node_modules" && "${G[@]}" -C "$A271/r" worktree add -q "$B271/node_modules/co" -b co271 \
    && rm "$B271/node_modules/co/.git" && "${G[@]}" init -q "$B271/node_modules/co" && chmod 300 "$B271/node_modules/co/.git" \
    || { printf 'SCAFFOLD-FAILED: G271\n'; exit 1; }
  EXTRA_MOUNTS="$A271 $B271" launch "$TMP/app"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $B271/node_modules/co/.git can be searched but not listed by you" "$ERR" \
    && pass "G271 a checkout's .git directory you can search but not list, in another mount, refuses the launch" \
    || fail "G271 unlistable .git in another mount (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$B271/node_modules/co/.git"; rm -rf "$A271" "$B271"
else skip_root G271; fi

# G272 (item 3): a rewritten gitdir that does not end in /.git is no checkout:
# the worktree is said to have none, and no checkout is said to be gone.
"${G[@]}" -C "$PROJ" worktree add -q "$TMP/o272/co" -b bco272 && "${G[@]}" init -q "$TMP/o272/co/vendor/lib" \
  && "${G[@]}" -C "$TMP/o272/co/vendor/lib" commit -q --allow-empty -m l && "${G[@]}" -C "$TMP/o272/co" add vendor/lib 2>/dev/null \
  && "${G[@]}" -C "$TMP/o272/co" commit -q -m s && printf '%s\n' "$PROJ/gone272/x" > "$PROJ/.git/worktrees/co/gitdir" \
  || { printf 'SCAFFOLD-FAILED: G272\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: no worktree is known for $PROJ/.git/worktrees/co" "$ERR" && ! grep -qF "Its gitdir names" "$ERR" \
  && pass "G272 a gitdir that does not end in /.git is not said to name a checkout that is gone" \
  || fail "G272 (rc=$LAUNCH_RC; $(grep -F -A1 'worktrees/co' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$TMP/o272"; "${G[@]}" -C "$PROJ" worktree prune; "${G[@]}" -C "$PROJ" branch -q -D bco272

# G273 (item 4): a checkout in this mount whose .git file does not point back is
# followed once, not again as one in another mount.
mkdir -p "$PROJ/node_modules" && "${G[@]}" -C "$PROJ" worktree add -q "$PROJ/node_modules/co273" -b bco273 \
  && printf 'gitdir: ../missing273/.git\n' > "$PROJ/node_modules/co273/.git" || { printf 'SCAFFOLD-FAILED: G273\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 && "$(grep -cF "WARNING: $PROJ/node_modules/co273/.git names $PROJ/node_modules/missing273/.git, which does not exist" "$ERR")" == 1 ]] \
  && pass "G273 a checkout in this mount is followed once" \
  || fail "G273 followed twice (rc=$LAUNCH_RC; $(grep -cF 'missing273' "$ERR") lines)"
rm -rf "$PROJ/node_modules/co273"; rmdir "$PROJ/node_modules" 2>/dev/null; "${G[@]}" -C "$PROJ" worktree prune; "${G[@]}" -C "$PROJ" branch -q -D bco273

# G274 (item 5): a worktree whose checkout lies in another mount and points
# back, its index recording a submodule there: the index is not read against a
# checkout this mount does not hold, and that is said.
A274="$TMP/a274"; B274="$TMP/b274"; "${G[@]}" init -q "$A274/r" && "${G[@]}" -C "$A274/r" commit -q --allow-empty -m i \
  && mkdir -p "$B274/node_modules" && "${G[@]}" -C "$A274/r" worktree add -q "$B274/node_modules/co" -b co274 \
  && "${G[@]}" init -q "$B274/node_modules/co/sub" && "${G[@]}" -C "$B274/node_modules/co/sub" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$B274/node_modules/co" add sub 2>/dev/null && "${G[@]}" -C "$B274/node_modules/co" commit -q -m m \
  || { printf 'SCAFFOLD-FAILED: G274\n'; exit 1; }
EXTRA_MOUNTS="$A274 $B274" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: no worktree is known for $A274/r/.git/worktrees/co, so the submodules its index records are not followed." "$ERR" \
  && pass "G274 a worktree whose checkout only another mount holds is said to have none here" \
  || fail "G274 (rc=$LAUNCH_RC; $(grep -F 'worktrees/co' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$A274" "$B274"

# G278 (to decide): a worktree's gitdir naming, through a link and a .., a path
# the kernel can enter, while read as written it names a directory of yours that
# cannot be searched: nothing of that directory is bound or named. git does not
# use it (GIT-96, the Linux agent's, is the converse).
if [[ "$(id -u)" != 0 ]]; then
  "${G[@]}" -C "$PROJ" worktree add -q "$TMP/o278/w" -b bw278 \
    && mkdir -p "$TMP/deep278/x" "$TMP/deep278/proj/node_modules/blk" "$PROJ/node_modules/blk" && ln -s "$TMP/deep278/x" "$TMP/lk278" \
    && printf '%s\n' "$TMP/lk278/../proj/node_modules/blk/.git" > "$PROJ/.git/worktrees/w/gitdir" && chmod 000 "$PROJ/node_modules/blk" \
    || { printf 'SCAFFOLD-FAILED: G278\n'; exit 1; }
  launch ..
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/.git/worktrees/w/gitdir:/workspace/proj/.git/worktrees/w/gitdir:ro" \
    && ! grep -qF "$PROJ/node_modules/blk" < <(mounts) && ! grep -qF "$PROJ/node_modules/blk cannot be listed" "$ERR" \
    && pass "G278 a directory a gitdir names only as written, through a link and a .., is not bound or named" \
    || fail "G278 (rc=$LAUNCH_RC; $(grep -F 'node_modules/blk' "$ERR" | head -1); $(mounts | grep -F 'node_modules/blk' | tr '\n' ' '))"
  chmod 755 "$PROJ/node_modules/blk"; rm -rf "$PROJ/node_modules" "$TMP/o278" "$TMP/deep278" "$TMP/lk278"
  "${G[@]}" -C "$PROJ" worktree prune; "${G[@]}" -C "$PROJ" branch -q -D bw278
else skip_root G278; fi

# ── G301: a directory the launch named, readable and not searchable after ────
# G169's layout. The session makes the directory an outside commondir names a
# repository, takes its HEAD away and leaves it readable but not searchable
# (mode 400). The check after the session cannot look inside, and says so,
# naming it (feature-gaps review GAP-2, the whole-file run, batch 6, item 2).
# Mode 400, not 300: the mount's own scan reaches a 300 directory first and
# names it with the same words. Skipped as root, where a mode stops nothing.
if [[ "$(id -u)" != 0 ]]; then
  B301="$TMP/b301"; O301="$TMP/o301"
  mkdir -p "$B301/node_modules/ng" "$B301/co" "$O301/wt" && printf 'ref: refs/heads/main\n' > "$O301/wt/HEAD" \
    && printf '%s\n' "$B301/node_modules/ng" > "$O301/wt/commondir" && printf '%s\n' "$B301/co/.git" > "$O301/wt/gitdir" \
    && printf 'gitdir: %s\n' "$O301/wt" > "$B301/co/.git" || { printf 'SCAFFOLD-FAILED: G301\n'; exit 1; }
  FAKE_SESSION="git init -q --bare '$B301/node_modules/ng' && rm -f '$B301/node_modules/ng/HEAD' && chmod 400 '$B301/node_modules/ng'" \
    EXTRA_MOUNTS="$B301" launch "$TMP/app"
  if [[ -x "$B301/node_modules/ng" ]]; then
    pass "G301 skipped: mode 400 did not take on this filesystem"
  else
    [[ "$LAUNCH_RC" == 0 ]] \
      && grep -qF "$B301/node_modules/ng (cannot be listed, so it was not checked)" \
         < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
      && pass "G301 a directory the launch named that the session leaves unsearchable is named as not checked" \
      || fail "G301 not searchable after the session (rc=$LAUNCH_RC; $(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
  fi
  chmod 700 "$B301/node_modules/ng" 2>/dev/null; rm -rf "$B301" "$O301"
else skip_root G301; fi

# ── G310: what the check after a session says of a directory a commondir named
# An outside worktree's commondir names $N, a linked worktree's directory of a
# repository under a writable mount's pruned node_modules, not there at launch.
# The session makes it, with a commondir of ../..: the check after the session
# reads it by what that names and by its own config and hooks, and says each
# key and hook once, its own hooks included, with nothing after the last
# (feature-gaps review GAP-2, the whole-file run, batch 7, item 1). The line is
# compared whole: G169 and G171 match its start only.
B310="$TMP/b310"; O310="$TMP/o310"; X310="$B310/node_modules/x"; N310="$X310/.git/worktrees/nv"
mk310() {  # $1 = hooks in x/.git, $2 = hooks the session makes in $N, $3 = 1 to set core.fsmonitor in both
  rm -rf "$B310" "$O310"
  mkdir -p "$B310/co" "$O310/wt" && "${G[@]}" init -q "$X310" && "${G[@]}" -C "$X310" commit -q --allow-empty -m i \
    && rm -f "$X310/.git/hooks/"*.sample && printf 'ref: refs/heads/main\n' > "$O310/wt/HEAD" \
    && printf '%s\n' "$N310" > "$O310/wt/commondir" && printf '%s\n' "$B310/co/.git" > "$O310/wt/gitdir" \
    && printf 'gitdir: %s\n' "$O310/wt" > "$B310/co/.git" || { printf 'SCAFFOLD-FAILED: G310\n'; exit 1; }
  local h s310="mkdir -p '$N310/refs' '$N310/objects' '$N310/hooks' && printf 'ref: refs/heads/main\n' > '$N310/HEAD' && printf '../..\n' > '$N310/commondir'"
  for h in $1; do printf '#!/bin/sh\n' > "$X310/.git/hooks/$h" && chmod +x "$X310/.git/hooks/$h" || { printf 'SCAFFOLD-FAILED: G310 %s\n' "$h"; exit 1; }; done
  for h in $2; do s310+=" && printf '#!/bin/sh\n' > '$N310/hooks/$h' && chmod +x '$N310/hooks/$h'"; done
  if [[ "$3" == 1 ]]; then
    "${G[@]}" config --file "$X310/.git/config" core.fsmonitor ./fsm || { printf 'SCAFFOLD-FAILED: G310 config\n'; exit 1; }
    s310+=" && git config --file '$N310/config' core.fsmonitor ./fsm"
  fi
  FAKE_SESSION="$s310" EXTRA_MOUNTS="$B310" launch "$TMP/app"
  l310="$(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR" | sed 's/^ *//' | grep -F "$N310 (")"
}
mk310 pre-commit pre-commit 1
[[ "$l310" == "$N310 (config: core.fsmonitor; hooks: pre-commit)" ]] \
  && pass "G310 a key and a hook on both reads are each named once" \
  || fail "G310 both reads (rc=$LAUNCH_RC; line: '$l310')"
mk310 pre-commit pre-push 0
[[ "$l310" == "$N310 (hooks: pre-commit, pre-push)" ]] \
  && pass "G310 the directory's own hook is named beside the one its commondir leads to" \
  || fail "G310 a hook of its own (rc=$LAUNCH_RC; line: '$l310')"
mk310 pre-commit "" 0
[[ "$l310" == "$N310 (hooks: pre-commit)" ]] \
  && pass "G310 with no hook of its own nothing is added" \
  || fail "G310 no hook of its own (rc=$LAUNCH_RC; line: '$l310')"
rm -rf "$B310" "$O310"

# ── G311: a directory the session makes that runs nothing is not named ───────
# G169's layout, the directory the outside commondir names not there at launch.
# The session makes it a bare repository with no HEAD, no key and no hook: on a
# host where git runs, the check after the session has nothing to name, and
# never says that git does not run (feature-gaps review GAP-2, the whole-file
# run, batch 7, item 2).
B311="$TMP/b311"; O311="$TMP/o311"
mkdir -p "$B311/node_modules" "$B311/co" "$O311/wt" && printf 'ref: refs/heads/main\n' > "$O311/wt/HEAD" \
  && printf '%s\n' "$B311/node_modules/ng" > "$O311/wt/commondir" && printf '%s\n' "$B311/co/.git" > "$O311/wt/gitdir" \
  && printf 'gitdir: %s\n' "$O311/wt" > "$B311/co/.git" || { printf 'SCAFFOLD-FAILED: G311\n'; exit 1; }
FAKE_SESSION="git init -q --bare '$B311/node_modules/ng' && rm -f '$B311/node_modules/ng/HEAD' '$B311/node_modules/ng/hooks/'*.sample" \
  EXTRA_MOUNTS="$B311" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -d "$B311/node_modules/ng/objects" ]] \
  && grep -qF "WARNING: $O311/wt/commondir names $B311/node_modules/ng, which does not exist" "$ERR" \
  && ! grep -qF 'WARNING: the session made git repositories in a writable mount' "$ERR" \
  && ! grep -qF 'git does not run on this host' "$ERR" \
  && pass "G311 a repository the session makes there that runs nothing is not named" \
  || fail "G311 runs nothing (rc=$LAUNCH_RC; $(grep -A3 -F -e 'the session made' -e 'does not run' "$ERR" | tr '\n' ' '))"
rm -rf "$B311" "$O311"

# ── G312: a directory that is no git directory, named from two mounts ───────
# Two writable mounts, a .git file in each naming one directory in the first
# that is no git directory: each mount's scan names it, the second reaching it
# through a mount not its own, and the launch starts (feature-gaps review
# GAP-2, the whole-file run, batch 7, item 3; the layout is the brief
# reviewer's). In one mount the scan's own record stops the second call.
B312a="$TMP/b312a"; B312b="$TMP/b312b"
mkdir -p "$B312a/n" "$B312a/co1" "$B312b/co2" && printf 'gitdir: %s\n' "$B312a/n" > "$B312a/co1/.git" \
  && printf 'gitdir: %s\n' "$B312a/n" > "$B312b/co2/.git" || { printf 'SCAFFOLD-FAILED: G312\n'; exit 1; }
EXTRA_MOUNTS="$B312a $B312b" launch "$TMP/app"
n312="$(grep -cF "names $B312a/n, which is not a git directory" "$ERR")"
[[ "$LAUNCH_RC" == 0 && -s "$CAPTURE" && "$n312" == 2 ]] \
  && pass "G312 a directory no git directory, named from two mounts, is named from each and the launch starts" \
  || fail "G312 two mounts (rc=$LAUNCH_RC; named $n312 times; $(grep -E 'WARNING|ERROR' "$ERR" | head -3 | tr '\n' ' '))"
rm -rf "$B312a" "$B312b"

# ── G313: a .git you cannot list in a read-only mount a writable one holds ───
# What the scan of a read-only mount finds is carried into the writable
# mount's view: a .git there that can be searched but not listed refuses the
# launch, as one the writable mount's own scan finds does; one that can be
# listed but not searched is read-only whole and named (feature-gaps review
# GAP-2, the whole-file run, batch 7, item 5). Skipped as root.
if [[ "$(id -u)" != 0 ]]; then
  B313="$TMP/b313"; R313="$B313/node_modules/ro/r"
  "${G[@]}" init -q "$R313" && "${G[@]}" -C "$R313" commit -q --allow-empty -m i || { printf 'SCAFFOLD-FAILED: G313\n'; exit 1; }
  chmod 300 "$R313/.git"
  EXTRA_MOUNTS="$B313 $B313/node_modules/ro:ro" launch "$TMP/app"
  if [[ -r "$R313/.git" ]]; then
    pass "G313 skipped: mode 300 did not take on this filesystem"
  else
    [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
      && grep -qF "ERROR: $R313/.git can be searched but not listed by you" "$ERR" \
      && pass "G313 a .git you can search but not list, found in a read-only mount, refuses the launch" \
      || fail "G313 mode 300 (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  chmod 400 "$R313/.git"
  EXTRA_MOUNTS="$B313 $B313/node_modules/ro:ro" launch "$TMP/app"
  if [[ -x "$R313/.git" ]]; then
    pass "G313 skipped: mode 400 did not take on this filesystem"
  else
    [[ "$LAUNCH_RC" == 0 ]] && has_mount "$R313/.git:/workspace/b313/node_modules/ro/r/.git:ro" \
      && grep -qF "WARNING: $R313/.git cannot be listed by you" "$ERR" \
      && pass "G313 one you can list but not search is read-only whole and named" \
      || fail "G313 mode 400 (rc=$LAUNCH_RC; $(mounts | grep -F 'ro/r/.git' | tr '\n' ' '); $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  chmod 700 "$R313/.git"; rm -rf "$B313"
else skip_root G313; fi

# ── G320: a git directory a launch protected stays protected once a session ──
# ── drops what led to it from the index (bugs review GIT-105) ────────────────
# The scan reaches a submodule under a pruned vendor/ only through its
# repository's index, which the launch leaves writable. A session that dropped
# the gitlink left the submodule's config and hooks writable at the next
# launch, with no bind and no warning; put back on the host, `git status` ran
# the core.fsmonitor the session wrote. The launcher's record of what it
# protected (git-reported.conf) now leads the scan to it.
B320="$TMP/b320"; P320="$B320/p"; rec320="$HOME/.ai-containers/git-reported.conf"
mk320() {
  rm -rf "$B320"; mkdir -p "$P320/vendor/lib" && "${G[@]}" init -q "$P320" && "${G[@]}" init -q "$P320/vendor/lib" \
    && : > "$P320/vendor/lib/f" && "${G[@]}" -C "$P320/vendor/lib" add f && "${G[@]}" -C "$P320/vendor/lib" commit -qm x \
    && "${G[@]}" -C "$P320" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P320" commit -qm sub \
    && "${G[@]}" -C "$P320/vendor/lib" config core.fsmonitor /bin/true \
    || { printf 'SCAFFOLD-FAILED: G320\n'; exit 1; }
}
n320() { mounts | grep -cF "$P320/vendor/lib/.git/" || true; }
mk320
export P320
FAKE_SESSION='git -C "$P320" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B320" launch "$TMP/app"
first320="$(n320)"
[[ "$LAUNCH_RC" == 0 && "$first320" -ge 4 ]] && has_mount "$P320/vendor/lib/.git/config:/workspace/b320/p/vendor/lib/.git/config:ro" \
  && [[ -z "$("${G[@]}" -C "$P320" ls-files -s vendor/lib)" ]] \
  && grep -qF 'NOTE: /workspace/b320/p/vendor/lib/.git is protected for the first time, and its config already sets' "$ERR" \
  || fail "G320 the first launch did not protect and report the submodule, or the session did not drop it (rc=$LAUNCH_RC, $first320 binds)"
EXTRA_MOUNTS="$B320" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(n320)" == "$first320" ]] \
  && has_mount "$P320/vendor/lib/.git/config:/workspace/b320/p/vendor/lib/.git/config:ro" \
  && has_mount "$P320/vendor/lib/.git/hooks:/workspace/b320/p/vendor/lib/.git/hooks:ro" \
  && ! grep -qF "$PROJ/.git" <<<"$(mounts)" \
  && pass "G320 a submodule dropped from the index is still protected by the next launch ($first320 binds)" \
  || fail "G320 dropped from the index, and unprotected (rc=$LAUNCH_RC; $(n320) binds, $first320 before; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
# …with its key, which the first launch named, not named again: it is the
# directory the record holds.
! grep -qF '/workspace/b320/p/vendor/lib/.git is protected for the first time' "$ERR" \
  && ! grep -qF '/workspace/b320/p/vendor/lib/.git was protected by an earlier launch' "$ERR" \
  && pass "G320 it is not reported again" \
  || fail "G320 reported again ($(grep -F 'vendor/lib' "$ERR" | head -2 | tr '\n' ' '))"
# The check after the session finds it too, so it is not taken for one the
# session made, though its config runs a program.
EXTRA_MOUNTS="$B320" launch "$TMP/app"
! grep -qF 'the session made git repositories' "$ERR" \
  && pass "G320 the check after the session does not take it for a new repository" \
  || fail "G320 taken for new ($(grep -A2 -F 'the session made' "$ERR" | tr '\n' ' '))"
# Its device is not part of what it is known by: a reboot gives a disk another
# number on some hosts (a WSL disk, LVM, btrfs, APFS), and every record there
# would go stale together.
sed 's/^[0-9][0-9]* /999999 /' "$rec320" > "$rec320.dev" && mv "$rec320.dev" "$rec320" || { printf 'SCAFFOLD-FAILED: G320 record\n'; exit 1; }
EXTRA_MOUNTS="$B320" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(n320)" == "$first320" ]] \
  && pass "G320 it is known by its inode and birth time, whatever number its device has" \
  || fail "G320 another device number lost it (rc=$LAUNCH_RC; $(n320) binds, $first320 before)"
# A directory made again at the path is another one, which no launch protected:
# it is found, like any other under vendor/, by what leads to it, and only so.
# Made beside the old one before it goes, so that it cannot get its inode back.
"${G[@]}" init -q "$P320/vendor/lib.new" && mv "$P320/vendor/lib" "$P320/vendor/lib.old" && mv "$P320/vendor/lib.new" "$P320/vendor/lib" \
  && rm -rf "$P320/vendor/lib.old" || { printf 'SCAFFOLD-FAILED: G320 again\n'; exit 1; }
EXTRA_MOUNTS="$B320" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(n320)" == 0 ]] \
  && pass "G320 a repository made again at the path is not the one the record holds" \
  || fail "G320 the path alone was taken (rc=$LAUNCH_RC; $(n320) binds)"
"${G[@]}" -C "$P320/vendor/lib" commit -q --allow-empty -m y && "${G[@]}" -C "$P320" add vendor/lib 2>/dev/null
EXTRA_MOUNTS="$B320" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(n320)" -ge 4 && "$(grep -cE " $P320/vendor/lib/\.git\$" "$rec320")" -ge 2 ]] \
  && pass "G320 …and is protected, and recorded as another, once its index leads to it" \
  || fail "G320 the new one, recorded in the index (rc=$LAUNCH_RC; $(n320) binds; $(grep -cE " $P320/vendor/lib/\.git\$" "$rec320") record lines)"
rm -rf "$B320"

# ── G325: a recorded git directory now reached through a link is not taken ───
# The record holds the path a directory was protected at. Moved on the host,
# with a link left where it was, it is the same directory at another path: the
# scan protects it where it lies, and nothing is bound through the link, which
# docker would resolve when the container starts (GIT-105).
B325="$TMP/b325"; P325="$B325/p"
mkdir -p "$P325/vendor/lib" && "${G[@]}" init -q "$P325" && "${G[@]}" init -q "$P325/vendor/lib" \
  && "${G[@]}" -C "$P325/vendor/lib" commit -q --allow-empty -m x \
  && "${G[@]}" -C "$P325" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P325" commit -qm sub \
  || { printf 'SCAFFOLD-FAILED: G325\n'; exit 1; }
export P325
FAKE_SESSION='git -C "$P325" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B325" launch "$TMP/app"
mv "$P325/vendor" "$P325/v2" && ln -s v2 "$P325/vendor" || { printf 'SCAFFOLD-FAILED: G325 link\n'; exit 1; }
EXTRA_MOUNTS="$B325" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$P325/v2/lib/.git/config:/workspace/b325/p/v2/lib/.git/config:ro" \
  && ! grep -qF "$P325/vendor/lib/.git" <<<"$(mounts)" \
  && pass "G325 moved, with a link left behind, it is protected where it lies and nothing is bound through the link" \
  || fail "G325 bound through a link (rc=$LAUNCH_RC; $(mounts | grep -F '/lib/.git/config' | tr '\n' ' '))"
rm -rf "$B325"

# ── G321: a .git file a launch bound stays bound once the index drops it ─────
# A submodule whose git directory lies elsewhere has a .git FILE in its
# checkout, and under vendor/ only the index leads to that file. Left writable,
# the session points it at a git directory of its own, whose config and hooks
# the host's git then runs there. The record holds each file a launch bound
# (`file:`), and the next scan takes it (GIT-105).
B321="$TMP/b321"; P321="$B321/p"
mkdir -p "$P321/vendor" "$P321/gd" && "${G[@]}" init -q "$P321" \
  && "${G[@]}" init -q --separate-git-dir "$P321/gd/lib" "$P321/vendor/lib" \
  && : > "$P321/vendor/lib/f" && "${G[@]}" -C "$P321/vendor/lib" add f && "${G[@]}" -C "$P321/vendor/lib" commit -qm x \
  && "${G[@]}" -C "$P321" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P321" commit -qm sub \
  && [[ -f "$P321/vendor/lib/.git" ]] || { printf 'SCAFFOLD-FAILED: G321\n'; exit 1; }
export P321
FAKE_SESSION='git -C "$P321" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B321" launch "$TMP/app"
has_mount "$P321/vendor/lib/.git:/workspace/b321/p/vendor/lib/.git:ro" && grep -qF " file:$P321/vendor/lib/.git" "$HOME/.ai-containers/git-reported.conf" \
  || fail "G321 the first launch did not bind and record the .git file (rc=$LAUNCH_RC; $(grep -cF 'file:' "$HOME/.ai-containers/git-reported.conf") file lines in the record)"
EXTRA_MOUNTS="$B321" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$P321/vendor/lib/.git:/workspace/b321/p/vendor/lib/.git:ro" \
  && pass "G321 a .git file dropped from the index is still bound read-only by the next launch" \
  || fail "G321 the .git file is writable again (rc=$LAUNCH_RC; $(mounts | grep -cF 'vendor/lib/.git') binds; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$B321"

# ── G322: the record's path with a newline is read back, and with no eval ────
# A path holding a newline is recorded as bash's %q writes it in the C locale
# (GIT-90), and the agent names the directories: one the scan could not read
# back was one it could hide under (GIT-105). _git_unq reads every escape that
# quoting writes and nothing else; the record is data, never run.
load_fn _git_unq; load_fn _git_rec_add
ok322=1
for v322 in $'/a/b\nc' $'/x/q\'uo\\te\ty\x01\x7f\xc3\xa9\n' $'/p/"dq"?\e[0m\r\a\b\f\v\n' $'/t/\n123' $'/t/\n\\101' $'/s p/\n$x `y` $(z)'; do
  LC_ALL=C printf -v q322 '%q' "$v322"; o322=""
  _git_unq "$q322" o322 && [[ "$o322" == "$v322" ]] || { ok322=""; printf '  not read back: %s\n' "$q322"; }
done
[[ -n "$ok322" ]] && pass "G322 a path %q wrote is read back as it was" || fail "G322 round trip"
ok322=1
for q322 in "\$'a\\zb'" "\$'a'b'" plain "\$'a\\0b'" "\$'" "\$'a\\400b'" "\$'a\\" "\$'\$(touch $TMP/ran322)'x"; do
  o322=kept; if _git_unq "$q322" o322; then ok322=""; printf '  taken: %s\n' "$q322"; fi
done
[[ -n "$ok322" && ! -e "$TMP/ran322" ]] && pass "G322 anything %q does not write is refused, and nothing in it runs" || fail "G322 refusals"
_git_rec_p=(); _git_rec_i=(); _git_rec_k=()
_git_rec_add "2128 33 1794925040 /a/b c/.git"; _git_rec_add "2128 34 0.5 hooks:/h/.git"; _git_rec_add "2128 35 1 wt:/w/.git"
_git_rec_add "2128 36 1 push:/w/.git/x"; _git_rec_add "? /q/.git"; _git_rec_add "2128 37 1 file:/f/.git"
_git_rec_add "2128 38 1 hooks:\$'/n/a\\nb/.git'"; _git_rec_add "1 2 3 relative"; _git_rec_add "1 2 /only/two"
got322="$(for i in "${!_git_rec_p[@]}"; do printf '%s|%s|%q;' "${_git_rec_k[i]}" "${_git_rec_i[i]}" "${_git_rec_p[i]}"; done)"
[[ "$got322" == "dir|2128 33 1794925040|/a/b\\ c/.git;dir|2128 34 0.5|/h/.git;file|2128 37 1|/f/.git;dir|2128 38 1|\$'/n/a\\nb/.git';" ]] \
  && pass "G322 the record's git directories and .git files are taken, wt:, push: and an unread identity are not" \
  || fail "G322 record lines (got: $got322)"
# A record line is one line: the identity of a link carries its target's text,
# newline and all, so nothing that is a link is recorded, or a target could
# write a line of its own (re-review of the fix).
load_fn _git_reported_load; load_fn _git_report_record; load_fn _git_ident
( ai_containers_root="$TMP/rec322"; _git_reported_file="$ai_containers_root/git-reported.conf"; _git_reported_loaded=""; _git_rec_lost=""
  declare -A _git_reported_set=(); _git_rec_p=(); _git_rec_i=(); _git_rec_k=()
  _git_report_record /p/one "" $'1 2 3 -> x\n0 0 0 want:/forged'
  _git_report_record /p/two "" '1 2 3 -> y'
  _git_report_record /p/three "" '4 5 6'
  [[ "$(cat "$_git_reported_file")" == '4 5 6 /p/three' && "${#_git_rec_p[@]}" == 1 ]] ) \
  && pass "G322 a link's identity, a newline in it or not, is no line of the record" \
  || fail "G322 a link's identity was recorded ($(tr '\n' '|' < "$TMP/rec322/git-reported.conf" 2>/dev/null))"
# End to end: a submodule under a directory with a newline in its name.
B322="$TMP/b322"; P322="$B322/p"; d322=$'ven\ndor'
mkdir -p "$P322/vendor/$d322/lib" && "${G[@]}" init -q "$P322" && "${G[@]}" init -q "$P322/vendor/$d322/lib" \
  && "${G[@]}" -C "$P322/vendor/$d322/lib" commit -q --allow-empty -m x \
  && "${G[@]}" -C "$P322" add "vendor/$d322/lib" 2>/dev/null && "${G[@]}" -C "$P322" commit -qm sub \
  || { printf 'SCAFFOLD-FAILED: G322 newline\n'; exit 1; }
export P322
FAKE_SESSION='git -C "$P322" rm -q --cached -r vendor' EXTRA_MOUNTS="$B322" launch "$TMP/app"
# docker's arguments are captured a line each, so this bind's last line is its own.
n322() { grep -cxF 'dor/lib/.git/config:ro' "$CAPTURE" || true; }
c322="$(n322)"
[[ "$LAUNCH_RC" == 0 && "$c322" == 1 && -z "$("${G[@]}" -C "$P322" ls-files -s)" ]] \
  || fail "G322 the first launch did not protect the submodule, or the session did not drop it (rc=$LAUNCH_RC, $c322 config binds)"
EXTRA_MOUNTS="$B322" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(n322)" == 1 ]] \
  && pass "G322 a recorded path with a newline still leads the scan to its git directory" \
  || fail "G322 newline path, end to end (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$B322"

# ── G323: a record that cannot be kept is said ───────────────────────────────
# The record is what the next scan finds such a directory by; where it cannot
# be written the launch says so, once, instead of losing it in silence.
B323="$TMP/b323"; rec323="$HOME/.ai-containers/git-reported.conf"
mkdir -p "$B323" && "${G[@]}" init -q "$B323/r" || { printf 'SCAFFOLD-FAILED: G323\n'; exit 1; }
mv "$rec323" "$rec323.kept" && mkdir "$rec323" || { printf 'SCAFFOLD-FAILED: G323 record\n'; exit 1; }
EXTRA_MOUNTS="$B323" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(grep -cF 'the record of what launches protect, cannot be kept' "$ERR")" == 1 ]] \
  && grep -qF '(it is not a regular file you can read and write)' "$ERR" \
  && pass "G323 a record that cannot be written is said once, with why" \
  || fail "G323 the lost record (rc=$LAUNCH_RC; $(grep -c 'cannot be kept' "$ERR") warnings)"
rmdir "$rec323" && mv "$rec323.kept" "$rec323"
EXTRA_MOUNTS="$B323" launch "$TMP/app"
! grep -qF 'cannot be kept' "$ERR" && pass "G323 a record that can be written says nothing" \
  || fail "G323 a false warning ($(grep -F 'cannot be kept' "$ERR" | head -1))"
rm -rf "$B323"

# ── G324: a recorded git directory the session made unlistable is bound whole ─
# The agent owns the directory: in the session that drops it from the index it
# can also make it unlistable. Taken from the record, it is bound read-only
# whole, as the scan binds one it finds so, with the chmod that restores it
# (GIT-105). Skipped as root.
if [[ "$(id -u)" != 0 ]]; then
  B324="$TMP/b324"; P324="$B324/p"
  mkdir -p "$P324/vendor/lib" && "${G[@]}" init -q "$P324" && "${G[@]}" init -q "$P324/vendor/lib" \
    && "${G[@]}" -C "$P324/vendor/lib" commit -q --allow-empty -m x \
    && "${G[@]}" -C "$P324" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P324" commit -qm sub \
    || { printf 'SCAFFOLD-FAILED: G324\n'; exit 1; }
  export P324
  FAKE_SESSION='git -C "$P324" update-index --force-remove vendor/lib; chmod 000 "$P324/vendor/lib/.git"' EXTRA_MOUNTS="$B324" launch "$TMP/app"
  if [[ -r "$P324/vendor/lib/.git" ]]; then
    pass "G324 skipped: mode 000 did not take on this filesystem"
  else
    has_mount "$P324/vendor/lib/.git/config:/workspace/b324/p/vendor/lib/.git/config:ro" \
      || fail "G324 the first launch did not protect the submodule (rc=$LAUNCH_RC)"
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
    [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor/lib/.git:/workspace/b324/p/vendor/lib/.git:ro" \
      && grep -qF "WARNING: $P324/vendor/lib/.git cannot be listed by you" "$ERR" \
      && pass "G324 a recorded git directory, dropped from the index and made unlistable, is bound read-only whole" \
      || fail "G324 not bound whole (rc=$LAUNCH_RC; $(mounts | grep -cF 'vendor/lib/.git') binds; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  chmod 700 "$P324/vendor/lib/.git"; rm -rf "$B324"
  # …and one hidden behind a directory the session made unsearchable: the
  # recorded path is not there to look at, so the directory in the way is
  # bound whole, as for a checkout an index names (_gdi_blocked).
  mkdir -p "$P324/vendor/lib" && "${G[@]}" init -q "$P324" && "${G[@]}" init -q "$P324/vendor/lib" \
    && "${G[@]}" -C "$P324/vendor/lib" commit -q --allow-empty -m x \
    && "${G[@]}" -C "$P324" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P324" commit -qm sub \
    || { printf 'SCAFFOLD-FAILED: G324 hidden\n'; exit 1; }
  FAKE_SESSION='git -C "$P324" update-index --force-remove vendor/lib; chmod 000 "$P324/vendor"' EXTRA_MOUNTS="$B324" launch "$TMP/app"
  if [[ -x "$P324/vendor" ]]; then
    pass "G324 skipped: mode 000 did not take on this filesystem"
  else
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
    [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor:/workspace/b324/p/vendor:ro" \
      && pass "G324 a recorded git directory hidden behind an unsearchable directory has that directory bound whole" \
      || fail "G324 hidden, and nothing bound (rc=$LAUNCH_RC; $(mounts | grep -cF "$P324/vendor") binds; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  fi
  chmod 700 "$P324/vendor"; rm -rf "$B324"
  # A checkout made unsearchable before any launch saw its .git: the launch
  # binds the directory whole, sees nothing inside, and had nothing to record.
  # Dropped from the index then, it was bound by no later launch, in silence,
  # with the config the agent gave it; and the WARNING that named it when it
  # was made said the next launch would protect it. The checkout it could not
  # reach is recorded now (`want:`), so the directory is bound whole while it
  # stays unsearchable, and its .git is protected, its keys named, once it can
  # be reached (review of the GIT-105 fix, A1).
  # In a directory of its own: the record holds the paths of the checks above.
  B324="$TMP/b324u"; P324="$B324/p"
  mkdir -p "$P324/vendor/lib" && "${G[@]}" init -q "$P324" && "${G[@]}" init -q "$P324/vendor/lib" \
    && "${G[@]}" -C "$P324/vendor/lib" commit -q --allow-empty -m x \
    && "${G[@]}" -C "$P324/vendor/lib" config core.fsmonitor /bin/true \
    && "${G[@]}" -C "$P324" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P324" commit -qm sub \
    && chmod 000 "$P324/vendor/lib" || { printf 'SCAFFOLD-FAILED: G324 unseen\n'; exit 1; }
  if [[ -x "$P324/vendor/lib" ]]; then
    pass "G324 skipped: mode 000 did not take on this filesystem"
  else
    FAKE_SESSION='git -C "$P324" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B324" launch "$TMP/app"
    has_mount "$P324/vendor/lib:/workspace/b324u/p/vendor/lib:ro" \
      && grep -qF " want:$P324/vendor/lib" "$HOME/.ai-containers/git-reported.conf" \
      && pass "G324 a checkout that cannot be searched is bound whole, and recorded as one a launch could not reach" \
      || fail "G324 the unsearchable checkout (rc=$LAUNCH_RC; $(mounts | grep -cF "$P324/vendor/lib") binds; $(grep -cF 'want:' "$HOME/.ai-containers/git-reported.conf") want lines)"
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
    [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor/lib:/workspace/b324u/p/vendor/lib:ro" \
      && pass "G324 dropped from the index while it cannot be searched, it is still bound whole" \
      || fail "G324 dropped and unsearchable: nothing bound (rc=$LAUNCH_RC; $(mounts | grep -cF "$P324/vendor/lib") binds)"
    chmod 700 "$P324/vendor/lib"
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
    [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor/lib/.git/config:/workspace/b324u/p/vendor/lib/.git/config:ro" \
      && grep -qF 'NOTE: /workspace/b324u/p/vendor/lib/.git is protected for the first time, and its config already sets' "$ERR" \
      && pass "G324 once it can be reached its .git is protected, and the key its config sets is named" \
      || fail "G324 reachable again, and unprotected (rc=$LAUNCH_RC; $(mounts | grep -cF "$P324/vendor/lib/.git/") binds; $(grep -F 'vendor/lib' "$ERR" | head -1))"
  fi
  chmod 700 "$P324/vendor/lib" 2>/dev/null; rm -rf "$B324"
  # What the .git taken so leads to is followed like anything else: a
  # submodule of that checkout, which only its own index names, is protected
  # in the same launch (re-review of the fix, C5).
  B324="$TMP/b324n"; P324="$B324/p"
  mkdir -p "$P324/vendor/lib/vendor/sub" && "${G[@]}" init -q "$P324" && "${G[@]}" init -q "$P324/vendor/lib" \
    && "${G[@]}" init -q "$P324/vendor/lib/vendor/sub" && "${G[@]}" -C "$P324/vendor/lib/vendor/sub" commit -q --allow-empty -m s \
    && "${G[@]}" -C "$P324/vendor/lib" add vendor/sub 2>/dev/null && "${G[@]}" -C "$P324/vendor/lib" commit -qm x \
    && "${G[@]}" -C "$P324" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P324" commit -qm sub \
    && chmod 000 "$P324/vendor/lib" || { printf 'SCAFFOLD-FAILED: G324 nested\n'; exit 1; }
  FAKE_SESSION='git -C "$P324" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B324" launch "$TMP/app"
  chmod 700 "$P324/vendor/lib"
  EXTRA_MOUNTS="$B324" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor/lib/.git/config:/workspace/b324n/p/vendor/lib/.git/config:ro" \
    && has_mount "$P324/vendor/lib/vendor/sub/.git/config:/workspace/b324n/p/vendor/lib/vendor/sub/.git/config:ro" \
    && pass "G324 what a .git taken from the record leads to is followed: its own submodule is protected" \
    || fail "G324 the nested submodule (rc=$LAUNCH_RC; $(mounts | grep -cF '/vendor/sub/.git/') binds)"
  rm -rf "$B324"
  # Whatever the .git of such a checkout is: a file is bound read-only, and a
  # link is named, as the scan treats one it finds; and with a link on the way
  # to the checkout nothing is bound through it.
  for k324 in file link moved; do
    B324="$TMP/b324$k324"; P324="$B324/p"
    mkdir -p "$P324/vendor/lib" "$P324/gd" && "${G[@]}" init -q "$P324" \
      && "${G[@]}" init -q --separate-git-dir "$P324/gd/lib" "$P324/vendor/lib" \
      && "${G[@]}" -C "$P324/vendor/lib" commit -q --allow-empty -m x \
      && "${G[@]}" -C "$P324" add vendor/lib 2>/dev/null && "${G[@]}" -C "$P324" commit -qm sub \
      && chmod 000 "$P324/vendor/lib" || { printf 'SCAFFOLD-FAILED: G324 %s\n' "$k324"; exit 1; }
    FAKE_SESSION='git -C "$P324" update-index --force-remove vendor/lib' EXTRA_MOUNTS="$B324" launch "$TMP/app"
    chmod 700 "$P324/vendor/lib"
    case "$k324" in
      link) rm -f "$P324/vendor/lib/.git" && ln -s ../../gd/lib "$P324/vendor/lib/.git" ;;
      moved) mv "$P324/vendor" "$P324/v2" && ln -s v2 "$P324/vendor" ;;
    esac
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
    case "$k324" in
      file)
        [[ "$LAUNCH_RC" == 0 ]] && has_mount "$P324/vendor/lib/.git:/workspace/b324file/p/vendor/lib/.git:ro" \
          && pass "G324 a .git file of a checkout taken from the record is bound read-only" \
          || fail "G324 a want: checkout's .git file (rc=$LAUNCH_RC; $(mounts | grep -cF 'vendor/lib/.git') binds)" ;;
      link)
        [[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: $P324/vendor/lib/.git is a symlink inside a writable mount" "$ERR" \
          && pass "G324 a .git link of a checkout taken from the record is named" \
          || fail "G324 a want: checkout's .git link (rc=$LAUNCH_RC; $(grep -cF 'is a symlink' "$ERR") warnings)" ;;
      moved)
        [[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$P324/vendor/lib/.git" <<<"$(mounts)" \
          && pass "G324 a checkout taken from the record is not bound through a link on the way to it" \
          || fail "G324 a want: checkout through a link (rc=$LAUNCH_RC; $(mounts | grep -F 'lib/.git' | head -2 | tr '\n' ' '))" ;;
    esac
    rm -rf "$B324"
  done
  # The scan after the session records nothing: what it finds blocked is the
  # next launch's to record, when it binds it.
  B324="$TMP/b324s"; P324="$B324/p"
  mkdir -p "$P324/vendor" && "${G[@]}" init -q "$P324" && "${G[@]}" -C "$P324" commit -q --allow-empty -m i || { printf 'SCAFFOLD-FAILED: G324 rescan\n'; exit 1; }
  FAKE_SESSION='mkdir -p "$P324/vendor/lib" && git init -q "$P324/vendor/lib" && git -C "$P324/vendor/lib" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m x && git -C "$P324" add vendor/lib 2>/dev/null; chmod 000 "$P324/vendor/lib"' \
    EXTRA_MOUNTS="$B324" launch "$TMP/app"
  [[ -n "$("${G[@]}" -C "$P324" ls-files -s vendor/lib)" ]] && ! grep -qF " want:$P324/vendor/lib" "$HOME/.ai-containers/git-reported.conf" \
    && pass "G324 the scan after the session records nothing" \
    || fail "G324 the rescan wrote the record ($(grep -cF " want:$P324" "$HOME/.ai-containers/git-reported.conf") lines; index: $("${G[@]}" -C "$P324" ls-files -s vendor/lib | wc -l))"
  chmod 700 "$P324/vendor/lib"; rm -rf "$B324"
  # Many checkouts behind one unsearchable directory cost the walk once, not
  # once each (the `id` it starts is counted here); and past SANDBOX_GIT_MAX of
  # them a launch is refused, naming five, since each is one index entry and
  # no directory need exist (re-review of the fix, C3).
  B324="$TMP/b324m"; P324="$B324/p"; rec324="$HOME/.ai-containers/git-reported.conf"
  mkdir -p "$P324/vendor/b" "$TMP/bin324" && "${G[@]}" init -q "$P324" && "${G[@]}" -C "$P324" commit -q --allow-empty -m i \
    && chmod 000 "$P324/vendor/b" || { printf 'SCAFFOLD-FAILED: G324 many\n'; exit 1; }
  cp "$rec324" "$rec324.324"
  for i324 in 1 2 3 4 5 6 7 8 9 10; do printf '0 0 0 want:%s/vendor/b/r%s\n' "$P324" "$i324" >> "$rec324"; done
  id324="$(command -v id)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/id324.log" "$id324" > "$TMP/bin324/id" && chmod +x "$TMP/bin324/id"
  : > "$TMP/id324.log"; PATH="$TMP/bin324:$PATH" EXTRA_MOUNTS="$B324" launch "$TMP/app"; base324="$(grep -c . "$TMP/id324.log" || true)"
  cp "$rec324.324" "$rec324"; printf '0 0 0 want:%s/vendor/b/r1\n' "$P324" >> "$rec324"
  : > "$TMP/id324.log"; PATH="$TMP/bin324:$PATH" EXTRA_MOUNTS="$B324" launch "$TMP/app"; one324="$(grep -c . "$TMP/id324.log" || true)"
  [[ "$LAUNCH_RC" == 0 && "$base324" == "$one324" ]] && has_mount "$P324/vendor/b:/workspace/b324m/p/vendor/b:ro" \
    && pass "G324 ten recorded checkouts behind one unsearchable directory cost what one does ($one324 calls of id)" \
    || fail "G324 each recorded checkout behind one directory costs again (rc=$LAUNCH_RC; $base324 calls of id for ten, $one324 for one)"
  mv "$rec324.324" "$rec324"; chmod 700 "$P324/vendor/b"
  for i324 in 1 2 3 4 5; do
    "${G[@]}" -C "$P324" update-index --add --cacheinfo "160000,$(printf '%040d' "$i324"),vendor/b/r$i324" || { printf 'SCAFFOLD-FAILED: G324 gitlinks\n'; exit 1; }
  done
  chmod 000 "$P324/vendor/b"
  SANDBOX_GIT_MAX=4 EXTRA_MOUNTS="$B324" launch "$TMP/app"
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF 'ERROR: more than 4 checkouts that an index names lie behind directories that cannot be' "$ERR" \
    && grep -qF "$P324/vendor/b/r1" "$ERR" \
    && pass "G324 past SANDBOX_GIT_MAX checkouts behind unsearchable directories the launch is refused, naming them" \
    || fail "G324 no bound on checkouts behind an unsearchable directory (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  SANDBOX_GIT_MAX=5 EXTRA_MOUNTS="$B324" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && pass "G324 …and within it the launch goes on" || fail "G324 five within a limit of five (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  chmod 700 "$P324/vendor/b"; rm -rf "$B324" "$TMP/bin324"
else skip_root G324; fi

# ── G331: the record cannot make a launch look at paths without bound ────────
# The record only grows, and each recorded path in a mount that nothing leads
# to any more costs the scan a look. The agent cannot make one at will, a
# protected directory being pinned, but past five times SANDBOX_GIT_MAX of them
# the launch is refused, naming the record, rather than slowed for ever (review
# of the GIT-105 fix, A4).
B331="$TMP/b331"; rec331="$HOME/.ai-containers/git-reported.conf"
mkdir -p "$B331/vendor" || { printf 'SCAFFOLD-FAILED: G331\n'; exit 1; }
cp "$rec331" "$rec331.331"
for i331 in 1 2 3 4 5 6; do
  "${G[@]}" init -q "$B331/vendor/s$i331" && printf '1 2 3 %s\n' "$B331/vendor/s$i331/.git" >> "$rec331" || { printf 'SCAFFOLD-FAILED: G331 lines\n'; exit 1; }
done
SANDBOX_GIT_MAX=1 EXTRA_MOUNTS="$B331" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF 'names more than 5 paths in' "$ERR" && grep -qF "$rec331" "$ERR" \
  && grep -qF 'that are still there, but that no index and no .git file leads to any more' "$ERR" \
  && [[ "$(grep -cE "^ +$B331/vendor/s[0-9]/\.git\$" "$ERR")" == 5 ]] \
  && pass "G331 past five times SANDBOX_GIT_MAX recorded paths to look at, the launch is refused, naming the record and five of them" \
  || fail "G331 no bound on the record's paths (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$B331/vendor/s6"
SANDBOX_GIT_MAX=1 EXTRA_MOUNTS="$B331" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! mounts | grep -F "$B331/vendor/s" >/dev/null \
  && pass "G331 within it they are looked at, and one that is not what was recorded is not taken" \
  || fail "G331 within the bound (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
mv "$rec331.331" "$rec331"; rm -rf "$B331"
# Only what nothing leads to is looked at, or taken: a recorded git directory
# that its index still names is in the scan's hands already, and taken once.
# Taken twice, it would count twice toward SANDBOX_GIT_MAX.
mkdir -p "$B331/p/vendor/lib" && "${G[@]}" init -q "$B331/p" && "${G[@]}" init -q "$B331/p/vendor/lib" \
  && "${G[@]}" -C "$B331/p/vendor/lib" commit -q --allow-empty -m x \
  && "${G[@]}" -C "$B331/p" add vendor/lib 2>/dev/null && "${G[@]}" -C "$B331/p" commit -qm sub || { printf 'SCAFFOLD-FAILED: G331 once\n'; exit 1; }
EXTRA_MOUNTS="$B331" launch "$TMP/app"
SANDBOX_GIT_MAX=2 EXTRA_MOUNTS="$B331" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$B331/p/vendor/lib/.git/config:/workspace/b331/p/vendor/lib/.git/config:ro" \
  && pass "G331 a recorded git directory its index still names is taken once" \
  || fail "G331 taken twice (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$B331"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
