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

# ── G45: a commondir is resolved as git resolves it, physically ──────────────
# bash's `cd` reads `s/..` lexically, git physically: with s a link into
# A/.git/refs, git's common directory is A/.git while bash's was the worktree's
# own directory, which has no config — so config.worktree was skipped although
# git reads it, and its include was never named (review of batch 9, finding 3).
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
grep -qF "worktrees/w/config.worktree includes" "$ERR" \
  && pass "G45 a commondir through a link and .. is resolved as git does; its config.worktree is walked" \
  || fail "G45 config.worktree skipped (stderr: $(grep -F a45 "$ERR" | head -2 | tr '\n' ' '))"
# Read as git reads it: every trailing CR and LF stripped, not one each.
printf 's/..\r\r\n' > "$W45/commondir"
launch ..
grep -qF "worktrees/w/config.worktree includes" "$ERR" \
  && pass "G45 … with every trailing CR and LF stripped, as git does" \
  || fail "G45 a commondir with two trailing CRs is misread"
# One that cannot be resolved fails closed: its placeholder is made (security
# review of 99db199), so the agent cannot add a config.worktree after the launch.
printf '%s\n' "$PROJ/nonexistent45" > "$W45/commondir"; rm -f "$W45/config.worktree"
launch ..
[[ -f "$W45/config.worktree" ]] \
  && pass "G45 an unresolvable commondir still gets its config.worktree placeholder" \
  || fail "G45 no config.worktree placeholder for an unresolvable commondir"
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
# …and a linked worktree's commondir likewise.
"${G[@]}" init -q --bare "$PROJ/node_modules/x47/common"
mkdir -p "$PROJ/wt47"; printf '%s\n' "$PROJ/node_modules/x47/common" > "$PROJ/wt47/commondir"
printf 'ref: refs/heads/main\n' > "$PROJ/wt47/HEAD"
launch ..
has_mount "$PROJ/node_modules/x47/common/config:/workspace/proj/node_modules/x47/common/config:ro" \
  && pass "G47 the common directory a commondir names is protected too" \
  || fail "G47 commondir target left writable (stderr: $(grep -F x47 "$ERR" | head -2 | tr '\n' ' '))"
# …and a commondir that is itself a link: git reads through it (security review).
"${G[@]}" init -q --bare "$PROJ/node_modules/x47/c2"
mkdir -p "$PROJ/wt47b"; printf '%s\n' "$PROJ/node_modules/x47/c2" > "$PROJ/cd47.txt"
ln -s ../cd47.txt "$PROJ/wt47b/commondir"; printf 'ref: refs/heads/main\n' > "$PROJ/wt47b/HEAD"
launch ..
has_mount "$PROJ/node_modules/x47/c2/config:/workspace/proj/node_modules/x47/c2/config:ro" \
  && pass "G47 a commondir that is a link is read through, as git reads it" \
  || fail "G47 a linked commondir's target left writable (stderr: $(grep -F c2 "$ERR" | head -2 | tr '\n' ' '))"
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
! grep -qF "a git directory in another writable mount" "$ERR" \
  && pass "G47 a target the other mount's own scan protects is not named" \
  || fail "G47 false 'another writable mount' WARNING ($(grep -F 'another writable mount' "$ERR" | head -1))"
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
mkdir -p "$B50/node_modules/x/wt"; printf '../main\n' > "$B50/node_modules/x/wt/commondir"
printf 'ref: refs/heads/main\n' > "$B50/node_modules/x/wt/HEAD"
mkdir -p "$PROJ/src50"; printf 'gitdir: %s\n' "$B50/node_modules/x/wt" > "$PROJ/src50/.git"
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
# A queued target's commondir naming nothing yet is named, as in one mount.
printf '../later50\n' > "$B50/node_modules/x/wt/commondir"
EXTRA_MOUNTS="$B50" launch ..
grep -qF "names $B50/node_modules/x/later50, which does not exist" "$ERR" \
  && pass "G50 a queued target's commondir that names nothing is named" \
  || fail "G50 a queued target's dangling commondir passed in silence ($(grep -F later50 "$ERR" | head -1))"
rm -rf "$B50" "$PROJ/src50"

# ── G51: a target in a named group's directories is protected, and said so ───
# The group's own directories are not scanned — tools re-clone what they hold, and
# a pin there turns that into Resource busy — but a .git file can name one. It is
# protected (left writable, the host's git would run it), and named, so a failed
# re-clone has an explanation (review of 4a4e30c).
GR51="$HOME/.ai-containers/default/.agents/m51"; mkdir -p "$GR51"; "${G[@]}" init -q --bare "$GR51/.git"
mkdir -p "$PROJ/src51"; printf 'gitdir: %s\n' "$GR51/.git" > "$PROJ/src51/.git"
launch ..
grep -qF "inside the container group's own directories" "$ERR" && grep -qF "$PROJ/src51/.git" "$ERR" \
  && pass "G51 protecting a git directory in the group's directories is named" \
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
  && pass "G57 more than twenty .git files naming one git directory refuse the launch" \
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
mkdir -p "$TMP/tp75"; printf '#!/bin/sh\nexec "$@"\n' > "$TMP/tp75/gtimeout"; chmod +x "$TMP/tp75/gtimeout"
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
