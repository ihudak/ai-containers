#!/usr/bin/env bash
# tests/test-git-internals-ro-scan.sh — which git directories a launch finds,
# and what it mounts read-only, pins and refuses: the scan, the placeholders,
# the limits and the group's directories.
#
# One of the tests/test-git-internals-ro-*.sh files, which share
# tests/lib-git-internals-ro.sh; the checks keep the G numbers sandbox.sh and
# the reviews cite. Hermetic: a fake docker capturing the run arguments, real
# git repositories. Integration case 465-git-internals-read-only checks that
# the container the agent gets actually refuses the writes, and still commits.
# shellcheck source=tests/lib-git-internals-ro.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-git-internals-ro.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-git-internals-ro.sh\n'; exit 1; }

# ── G1: the documented launch — the project's .git internals read-only ───────
launch ..
[[ "$LAUNCH_RC" == 0 && -s "$CAPTURE" ]] && pass "G1 the launch reaches docker run and exits 0" \
  || fail "G1 the launch reaches docker run (rc=$LAUNCH_RC: $(tail -2 "$ERR" | tr '\n' ' '))"
has_mount "$PROJ/.git:/workspace/proj/.git:rw" \
  && pass "G1 .git is pinned (bound onto itself), so it cannot be renamed away" \
  || fail "G1 .git pinned (git mounts: $(git_mounts | tr '\n' ' '))"
has_mount "$PROJ/.git/config:/workspace/proj/.git/config:ro" && has_mount "$PROJ/.git/hooks:/workspace/proj/.git/hooks:ro" \
  && pass "G1 .git/config and .git/hooks are mounted read-only in place" \
  || fail "G1 config and hooks read-only (git mounts: $(git_mounts | tr '\n' ' '))"
# git reads commondir in ANY git directory, and a repository's own has none —
# so one is made, holding `./` (this directory, which git, libgit2, dulwich and
# gitoxide all treat as none — libgit2 refuses a bare `.`), and mounted
# read-only, or the agent could make one pointing git elsewhere.
[[ "$(cat "$PROJ/.git/commondir" 2>/dev/null)" == ./ ]] && has_mount "$PROJ/.git/commondir:/workspace/proj/.git/commondir:ro" \
  && pass "G1 a commondir holding './' is made and mounted read-only, so the agent cannot make one" \
  || fail "G1 commondir placeholder (content: '$(cat "$PROJ/.git/commondir" 2>/dev/null)'; git mounts: $(git_mounts | tr '\n' ' '))"
[[ "$(git_mounts | wc -l | tr -d ' ')" == 4 ]] \
  && pass "G1 and nothing else of .git: objects, refs and the index stay writable" \
  || fail "G1 exactly four git mounts (got: $(git_mounts | tr '\n' ' '))"
[[ "$("${G[@]}" -C "$PROJ" rev-parse --git-common-dir)" == "$PROJ/.git" && "$("${G[@]}" -C "$PROJ" log -1 --format=%s)" == init ]] \
  && pass "G1 git on the host still reads the repository as before (common dir = .git)" \
  || fail "G1 host git with the placeholder (common dir: $("${G[@]}" -C "$PROJ" rev-parse --git-common-dir 2>&1))"
grep -qF 'READ-ONLY: /workspace/proj/.git: config, commondir, hooks' "$ERR" \
  && pass "G1 the launch says what it made read-only" \
  || fail "G1 READ-ONLY line (stderr: $(grep -E 'READ-ONLY|WARNING' "$ERR" | tr '\n' ' '))"
# In a .git the launch makes placeholders in, the absence of config.worktree
# (the extension off) and gitdir, which it does not make, draws no warning.
! grep -qF 'could not be made' "$ERR" \
  && pass "G1 a plain repository draws no 'could not be made' warning" \
  || fail "G1 false 'could not be made' warning ($(grep -F 'could not be made' "$ERR" | head -2 | tr '\n' ' '))"
has_mount "$LAUNCHER:/workspace/proj/.ai-containers:ro" \
  && pass "G1 the launcher overlay is still there beside them" || fail "G1 launcher overlay"

# ── G2: a repository without hooks/ gets one, so there is something to protect ─
rm -rf "$PROJ/.git/hooks"
launch ..
[[ -d "$PROJ/.git/hooks" ]] && has_mount "$PROJ/.git/hooks:/workspace/proj/.git/hooks:ro" \
  && pass "G2 a missing hooks/ is made, as you, and mounted read-only" \
  || fail "G2 missing hooks/ (exists: $([[ -d "$PROJ/.git/hooks" ]] && echo y || echo n); git mounts: $(git_mounts | tr '\n' ' '))"

# ── G3: config.worktree, which git reads with extensions.worktreeConfig ───────
# Off (the default): git ignores the file, so none is made.
launch ..
[[ ! -e "$PROJ/.git/config.worktree" ]] && pass "G3 with extensions.worktreeConfig off, no config.worktree is made" \
  || fail "G3 config.worktree made with the extension off"
# On: git would read one the agent made, so an empty one is made and mounted.
"${G[@]}" -C "$PROJ" config extensions.worktreeConfig true
launch ..
[[ -f "$PROJ/.git/config.worktree" && ! -s "$PROJ/.git/config.worktree" ]] \
  && has_mount "$PROJ/.git/config.worktree:/workspace/proj/.git/config.worktree:ro" \
  && pass "G3 with it on, an empty config.worktree is made and mounted read-only" \
  || fail "G3 config.worktree placeholder (git mounts: $(git_mounts | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset extensions.worktreeConfig; rm -f "$PROJ/.git/config.worktree"

# ── G4: a linked worktree inside the mount ─────────────────────────────────────
"${G[@]}" -C "$PROJ" worktree add -q "$PROJ/wt" -b wt 2>/dev/null
launch ..
has_mount "$PROJ/wt/.git:/workspace/proj/wt/.git:ro" && has_mount "$PROJ/wt:/workspace/proj/wt:rw" \
  && pass "G4 the worktree's .git file is read-only and its directory pinned" \
  || fail "G4 worktree .git file (git mounts: $(git_mounts | tr '\n' ' '))"
has_mount "$PROJ/.git/worktrees/wt/commondir:/workspace/proj/.git/worktrees/wt/commondir:ro" \
  && has_mount "$PROJ/.git/worktrees/wt:/workspace/proj/.git/worktrees/wt:rw" \
  && pass "G4 its git directory's commondir is read-only, the directory pinned" \
  || fail "G4 worktree gitdir (git mounts: $(git_mounts | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" worktree remove --force "$PROJ/wt" 2>/dev/null

# ── G5: a submodule's git directory and checkout ──────────────────────────────
mkdir -p "$TMP/libsrc" && "${G[@]}" -C "$TMP/libsrc" init -q && "${G[@]}" -C "$TMP/libsrc" commit -q --allow-empty -m l
"${G[@]}" -C "$PROJ" -c protocol.file.allow=always submodule --quiet add "$TMP/libsrc" lib 2>/dev/null
# … and one under vendor/, which the scan prunes by name: found anyway, through
# its git directory's core.worktree.
"${G[@]}" -C "$PROJ" -c protocol.file.allow=always submodule --quiet add "$TMP/libsrc" vendor/lib 2>/dev/null
launch ..
has_mount "$PROJ/.git/modules/lib/config:/workspace/proj/.git/modules/lib/config:ro" \
  && has_mount "$PROJ/.git/modules/lib/hooks:/workspace/proj/.git/modules/lib/hooks:ro" \
  && has_mount "$PROJ/.git/modules:/workspace/proj/.git/modules:rw" \
  && pass "G5 a submodule's git directory gets the same, the way down pinned" \
  || fail "G5 submodule gitdir (git mounts: $(git_mounts | tr '\n' ' '))"
has_mount "$PROJ/lib/.git:/workspace/proj/lib/.git:ro" \
  && pass "G5 its checkout's .git file is read-only" \
  || fail "G5 submodule .git file (git mounts: $(git_mounts | tr '\n' ' '))"
has_mount "$PROJ/.git/modules/vendor/lib/config:/workspace/proj/.git/modules/vendor/lib/config:ro" \
  && has_mount "$PROJ/vendor/lib/.git:/workspace/proj/vendor/lib/.git:ro" \
  && pass "G5 a submodule under vendor/ is protected too: its git directory, and its checkout's .git" \
  || fail "G5 vendor/ submodule (git mounts: $(git_mounts | tr '\n' ' '))"

# ── G6: a bare repository a writable mount exposes ────────────────────────────
mkdir -p "$TMP/extra" && "${G[@]}" init -q --bare "$TMP/extra/origin.git"
EXTRA_MOUNTS="$TMP/extra" launch "$TMP/app"
has_mount "$TMP/extra/origin.git/config:/workspace/extra/origin.git/config:ro" \
  && has_mount "$TMP/extra/origin.git/hooks:/workspace/extra/origin.git/hooks:ro" \
  && pass "G6 a bare repository is matched by content and protected the same way" \
  || fail "G6 bare repo (mounts: $(mounts | grep extra | tr '\n' ' '))"

# ── G7: a read-only mount needs nothing ───────────────────────────────────────
EXTRA_MOUNTS="$TMP/extra:ro" launch "$TMP/app"
[[ -s "$CAPTURE" ]] && ! grep -q 'origin.git/' <<<"$(mounts)" \
  && pass "G7 a :ro mount gets no git overlays" || fail "G7 :ro mount (mounts: $(mounts | grep extra | tr '\n' ' '))"

# ── G8: a repository inside a launcher is already read-only with it ───────────
mkdir -p "$TMP/eng" && cp -p "$ENGINE/sandbox.sh" "$ENGINE/sandbox-common.sh" "$TMP/eng/" && "${G[@]}" -C "$TMP/eng" init -q
EXTRA_MOUNTS="$TMP/eng" launch "$TMP/app"
has_mount "$TMP/eng:/workspace/eng:rw" && grep -qF 'NOTE: '"$TMP/eng"' holds a launcher' "$ERR" \
  && pass "G8a (a launcher that is a mount root stays writable, with its NOTE)" || fail "G8a launcher root NOTE"
has_mount "$TMP/eng/.git/config:/workspace/eng/.git/config:ro" \
  && pass "G8a … but its .git internals are still protected" \
  || fail "G8a a launcher root's .git (mounts: $(mounts | grep eng | tr '\n' ' '))"
mkdir -p "$TMP/wrap" && mv "$TMP/eng" "$TMP/wrap/eng"
EXTRA_MOUNTS="$TMP/wrap" launch "$TMP/app"
has_mount "$TMP/wrap/eng:/workspace/wrap/eng:ro" && ! grep -q 'wrap/eng/.git' <<<"$(mounts)" \
  && pass "G8b a repository inside a launcher overlaid read-only needs nothing more" \
  || fail "G8b repo inside a read-only launcher (mounts: $(mounts | grep wrap | tr '\n' ' '))"
rm -rf "$TMP/wrap"

# ── G9: a .git symlink cannot be pinned — warned about ────────────────────────
mkdir -p "$TMP/ln/real" && "${G[@]}" -C "$TMP/ln/real" init -q && mkdir -p "$TMP/ln/co" && ln -s ../real/.git "$TMP/ln/co/.git"
EXTRA_MOUNTS="$TMP/ln" launch "$TMP/app"
grep -qF "WARNING: $TMP/ln/co/.git is a symlink inside a writable mount" "$ERR" \
  && pass "G9 a .git symlink is named in a WARNING (it would be replaced, not renamed)" \
  || fail "G9 .git symlink (stderr: $(grep -E 'WARNING' "$ERR" | tr '\n' ' '))"
has_mount "$TMP/ln/real/.git/config:/workspace/ln/real/.git/config:ro" \
  && pass "G9 … and the git directory it names, inside the mount, is protected" \
  || fail "G9 the linked-to gitdir (mounts: $(mounts | grep '/ln/' | tr '\n' ' '))"

# ── G10: a .git you cannot list is mounted read-only whole ────────────────────
mkdir -p "$TMP/hid/r" && "${G[@]}" -C "$TMP/hid/r" init -q && chmod 000 "$TMP/hid/r/.git"
if [[ -r "$TMP/hid/r/.git" ]]; then
  printf 'SKIP: G10 — chmod does not constrain root\n'
else
  EXTRA_MOUNTS="$TMP/hid" launch "$TMP/app"
  has_mount "$TMP/hid/r/.git:/workspace/hid/r/.git:ro" && has_mount "$TMP/hid/r:/workspace/hid/r:rw" \
    && grep -qF "WARNING: $TMP/hid/r/.git cannot be listed by you" "$ERR" && grep -qF 'chmod u+rx' "$ERR" \
    && pass "G10 a .git you cannot list is read-only whole, its parent pinned, with a WARNING and the fix" \
    || fail "G10 unlistable .git (mounts: $(mounts | grep '/hid/' | tr '\n' ' '); stderr: $(grep WARNING "$ERR" | tr '\n' ' '))"
fi
chmod 755 "$TMP/hid/r/.git"; rm -rf "$TMP/hid"

# ── G11: files named HEAD and config are not a repository ─────────────────────
# Matched by content: HEAD with config AND objects/ (or commondir). A project's own
# directory that happens to hold HEAD and config must keep its config writable.
mkdir -p "$TMP/app/docs" && printf 'ref: x\n' > "$TMP/app/docs/HEAD" && printf 'k=v\n' > "$TMP/app/docs/config"
launch "$TMP/app"
! grep -q '/app/docs' <<<"$(mounts)" && pass "G11 a stray HEAD file is not taken for a git directory" \
  || fail "G11 stray HEAD (mounts: $(mounts | grep '/app/' | tr '\n' ' '))"

# ── G12: depth — a checkout six levels down is found, seven is not ────────────
mkdir -p "$TMP/deep/1/2/3/4/5/6/7"
"${G[@]}" -C "$TMP/deep/1/2/3/4/5/6" init -q 2>/dev/null; "${G[@]}" -C "$TMP/deep/1/2/3/4/5/6/7" init -q 2>/dev/null
EXTRA_MOUNTS="$TMP/deep" launch "$TMP/app"
has_mount "$TMP/deep/1/2/3/4/5/6/.git/config:/workspace/deep/1/2/3/4/5/6/.git/config:ro" \
  && ! grep -q '/6/7/.git' <<<"$(mounts)" \
  && pass "G12 a checkout six levels below the mount root is protected; seven is past the limit" \
  || fail "G12 depth (mounts: $(mounts | grep '/deep/' | tr '\n' ' '))"
rm -rf "$TMP/deep"

# ── G13: the concurrent-swap manifest records every git mount ─────────────────
launch ..
ok=1
for d in /workspace/proj/.git /workspace/proj/.git/config /workspace/proj/.git/commondir /workspace/proj/.git/hooks; do
  grep -qxF -- "$d" <<<"$(tr '\0' '\n' < "$CAPTURE.manifest" 2>/dev/null)" || ok=""
done
[[ -n "$ok" ]] && pass "G13 the verify manifest covers the .git pin and its read-only mounts" \
  || fail "G13 manifest (has: $(tr '\0' ' ' < "$CAPTURE.manifest" 2>/dev/null | head -c 400))"

# ── G14: no repository, no git mounts ─────────────────────────────────────────
launch "$TMP/app"
[[ -s "$CAPTURE" && -z "$(git_mounts)" ]] && pass "G14 a mount with no repository gets no git mounts" \
  || fail "G14 no repo (git mounts: $(git_mounts | tr '\n' ' '))"

# ── G15: a commondir already there that is not './' refuses the launch ──────
# git never writes one in a repository's own git directory, and it already sends
# the host's git elsewhere for config and hooks: mounting it read-only would only
# freeze the redirect.
mkdir -p "$TMP/cd/r" && "${G[@]}" -C "$TMP/cd/r" init -q && printf '../elsewhere\n' > "$TMP/cd/r/.git/commondir"
EXTRA_MOUNTS="$TMP/cd" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $TMP/cd/r/.git/commondir sends git to" "$ERR" \
  && [[ "$(cat "$TMP/cd/r/.git/commondir")" == ../elsewhere ]] \
  && pass "G15 a commondir that is not './' refuses the launch, naming it, and is left for you to inspect" \
  || fail "G15 foreign commondir (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|WARNING' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/cd"

# ── G16: a directory inside .git you cannot list is mounted read-only whole ───
# The agent owns .git/modules and can `chmod 000` it in one session, to hide the
# submodules' git directories from the next launch's scan.
chmod 000 "$PROJ/.git/modules"
if [[ -r "$PROJ/.git/modules" ]]; then
  printf 'SKIP: G16 — chmod does not constrain root\n'
else
  launch ..
  has_mount "$PROJ/.git/modules:/workspace/proj/.git/modules:ro" \
    && grep -qF "WARNING: $PROJ/.git/modules cannot be listed by you" "$ERR" \
    && pass "G16 an unlistable directory inside .git is read-only whole, with a WARNING" \
    || fail "G16 unlistable .git/modules (git mounts: $(git_mounts | tr '\n' ' '))"
fi
chmod 755 "$PROJ/.git/modules"

# ── G17: a named group's own directories are not scanned ──────────────────────
# The host's git never runs inside ~/.ai-containers/<group>/, and repositories
# there (plugin marketplaces) are deleted and re-cloned by the tools that own
# them, which a pin would turn into EBUSY.
mkdir -p "$HOME/.ai-containers/default/.agents/r" && "${G[@]}" -C "$HOME/.ai-containers/default/.agents/r" init -q
launch "$TMP/app"
[[ -s "$CAPTURE" ]] && ! grep -q '/.agents/r/.git' <<<"$(mounts)" \
  && pass "G17 a repository in a named group's directory gets no git mounts" \
  || fail "G17 group repo (mounts: $(mounts | grep agents | tr '\n' ' '))"

# ── G18: shallowest first — a repository under another's read-only hooks/ ─────
mkdir -p "$PROJ/.git/hooks/inner" && "${G[@]}" -C "$PROJ/.git/hooks/inner" init -q
launch ..
! grep -q ':/workspace/proj/.git/hooks:rw$' <<<"$(mounts)" && ! grep -q 'hooks/inner' <<<"$(mounts)" \
  && pass "G18 a repository inside another's read-only hooks/ is left under it, never pinned writable" \
  || fail "G18 ordering (git mounts: $(git_mounts | grep hooks | tr '\n' ' '))"
rm -rf "$PROJ/.git/hooks/inner"

# ── G20: a mount rooted inside a .git is named ────────────────────────────────
EXTRA_MOUNTS="$PROJ/.git/hooks" launch "$TMP/app"
grep -qF "NOTE: $PROJ/.git/hooks lies inside a git directory and is mounted writable" "$ERR" \
  && pass "G20 a writable mount rooted inside a .git gets a NOTE" \
  || fail "G20 mount inside .git (stderr: $(grep NOTE "$ERR" | tr '\n' ' '))"

# ── G21: every repository is protected; past 30 the cost is named ─────────────
# No cap that leaves some writable: the agent can make repositories, and would
# fill one to push a real repository past it.
mkdir -p "$TMP/many"
for n in $(seq -w 1 32); do mkdir -p "$TMP/many/r$n" && "${G[@]}" -C "$TMP/many/r$n" init -q; done
mkdir -p "$TMP/many/zz/deep" && "${G[@]}" -C "$TMP/many/zz/deep" init -q
EXTRA_MOUNTS="$TMP/many" launch "$TMP/app"
nro="$(grep -c '^READ-ONLY: /workspace/many/.*/\.git: ' "$ERR")"
[[ "$LAUNCH_RC" == 0 && "$nro" == 33 ]] && grep -q 'zz/deep/.git/config' <<<"$(mounts)" \
  && grep -qF 'NOTE: 33 git directories were protected' "$ERR" \
  && pass "G21 all 33 repositories are protected, and the start-up cost is named in a NOTE" \
  || fail "G21 every repository (rc=$LAUNCH_RC; protected: $nro; stderr: $(grep -E 'NOTE: [0-9]|WARNING' "$ERR" | tr '\n' ' '))"
# Past 200 the launch is refused rather than leaving any writable.
for n in $(seq -w 33 201); do mkdir -p "$TMP/many/r$n" && "${G[@]}" -C "$TMP/many/r$n" init -q; done
EXTRA_MOUNTS="$TMP/many" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF 'ERROR: the writable mounts hold more than 200 git directories' "$ERR" \
  && grep -qE "^         $TMP/many/r[0-9]+/\.git$" "$ERR" \
  && pass "G21 past 200 the launch is refused, never left partly protected, naming git directories past the limit" \
  || fail "G21 refusal past 200 (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|^         ' "$ERR" | head -4 | tr '\n' ' '))"
# A tree that legitimately holds more (an AOSP-style checkout) can raise it.
SANDBOX_GIT_MAX=300 EXTRA_MOUNTS="$TMP/many" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(grep -c '^READ-ONLY: /workspace/many/.*/\.git: ' "$ERR")" == 202 ]] \
  && pass "G21 SANDBOX_GIT_MAX raises the limit, and then all 202 are protected" \
  || fail "G21 SANDBOX_GIT_MAX=300 (rc=$LAUNCH_RC; protected: $(grep -c '^READ-ONLY: /workspace/many/' "$ERR"))"
SANDBOX_GIT_MAX=abc EXTRA_MOUNTS="$TMP/many" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'SANDBOX_GIT_MAX must be a whole number' "$ERR" \
  && pass "G21 a SANDBOX_GIT_MAX that is not a number refuses the launch" \
  || fail "G21 SANDBOX_GIT_MAX=abc (rc=$LAUNCH_RC)"
rm -rf "$TMP/many"

# ── G49: a git directory is what git takes for one ───────────────────────────
# git needs HEAD, objects/ and refs/, not a config: one without was not taken for
# a git directory, so nothing was protected and the agent could add a config the
# host's git then reads (automated security review of 4a4e30c). It is protected,
# with an empty config made as a placeholder, as commondir is.
mkdir -p "$PROJ/nc49" && "${G[@]}" -C "$PROJ/nc49" init -q && rm -f "$PROJ/nc49/.git/config"
launch ..
[[ -f "$PROJ/nc49/.git/config" ]] && has_mount "$PROJ/nc49/.git/config:/workspace/proj/nc49/.git/config:ro" \
  && pass "G49 a git directory with no config is protected, with an empty config made for it" \
  || fail "G49 config-less git directory left unprotected (stderr: $(grep -F nc49 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/nc49"
# …including one our ./ commondir placeholder marks (made by an earlier launch).
mkdir -p "$PROJ/nc49b" && "${G[@]}" -C "$PROJ/nc49b" init -q && rm -f "$PROJ/nc49b/.git/config"
printf './\n' > "$PROJ/nc49b/.git/commondir"
launch ..
[[ -f "$PROJ/nc49b/.git/config" ]] && has_mount "$PROJ/nc49b/.git/config:/workspace/proj/nc49b/.git/config:ro" \
  && pass "G49 … and one whose commondir is our ./ placeholder" \
  || fail "G49 config-less repository with ./ commondir left unprotected"
rm -rf "$PROJ/nc49b"

# ── G63: ordinary repositories do not warn on every launch ───────────────────
# A submodule removed with git rm, one deinit'd, and a linked worktree checked
# out outside every mount each have a git directory with no known worktree; only
# one whose index records a submodule is worth naming (review of 4e91bf3).
S63="$TMP/us63"; "${G[@]}" init -q "$S63" && "${G[@]}" -C "$S63" commit -q --allow-empty -m s
A63="$PROJ/app63"; "${G[@]}" init -q "$A63" && "${G[@]}" -C "$A63" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$A63" -c protocol.file.allow=always submodule -q add "$S63" gone \
  && "${G[@]}" -C "$A63" -c protocol.file.allow=always submodule -q add "$S63" dein && "${G[@]}" -C "$A63" commit -q -m n \
  && "${G[@]}" -C "$A63" rm -q gone && "${G[@]}" -C "$A63" commit -q -m rm \
  && "${G[@]}" -C "$A63" submodule -q deinit dein && "${G[@]}" -C "$A63" worktree add -q "$TMP/outside63" \
  || { printf 'SCAFFOLD-FAILED: G63\n'; exit 1; }
launch ..
! grep -qF "no worktree is known" "$ERR" \
  && pass "G63 removed, deinit'd and outside-worktree git directories do not warn" \
  || fail "G63 ordinary repositories warn every launch ($(grep -F 'no worktree is known' "$ERR"))"
rm -rf "$S63" "$A63" "$TMP/outside63"

# ── G70: a FIFO HEAD hid the repository from the scan, silently, and the host's
# git accepts one while something writes it (review of c687370, HIGH).
mkdir -p "$PROJ/h70" && "${G[@]}" -C "$PROJ/h70" init -q && rm -f "$PROJ/h70/.git/HEAD" && mkfifo "$PROJ/h70/.git/HEAD"
launch_timed 60
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "h70/.git/HEAD" "$ERR" \
  && pass "G70 a FIFO HEAD refuses the launch" \
  || fail "G70 FIFO HEAD (rc=$LAUNCH_RC; $(grep -F h70 "$ERR" | head -1))"
( exec 3<>"$PROJ/h70/.git/HEAD" ) 2>/dev/null; rm -rf "$PROJ/h70"

# ── G71: a HEAD that is a link to a directory: git takes any HEAD link whose
# text starts refs/ without following it, and the scan took it for a directory,
# protecting nothing (review of 7b41327, HIGH).
mkdir -p "$PROJ/h71" && "${G[@]}" -C "$PROJ/h71" init -q && rm -f "$PROJ/h71/.git/HEAD" && ln -s refs/heads "$PROJ/h71/.git/HEAD"
launch ..
has_mount "$PROJ/h71/.git/config:/workspace/proj/h71/.git/config:ro" \
  && pass "G71 a git directory whose HEAD links to a directory is protected" \
  || fail "G71 HEAD -> refs/heads left the repository writable (rc=$LAUNCH_RC)"
rm -rf "$PROJ/h71"
# ── G100: a bare repository is still taken by its HEAD, a link included ─────
# G68's and G71's repositories are .git directories, protected whatever
# their HEAD holds since G77, so neither checked the HEAD rule any more: a
# repository not named .git (a bare one) is found by its HEAD, and taken for
# one with objects/ and refs/. A mutant that took a HEAD link to a directory
# for no HEAD survived every test (GAP-2's slice 2; sandbox.sh: `_is_git_dir()`).
"${G[@]}" init -q --bare "$PROJ/b100" && rm -f "$PROJ/b100/HEAD" && ln -s refs/heads "$PROJ/b100/HEAD"
launch ..
has_mount "$PROJ/b100/config:/workspace/proj/b100/config:ro" \
  && pass "G100 a bare repository whose HEAD links to a directory is protected" \
  || fail "G100 HEAD -> refs/heads left a bare repository writable (rc=$LAUNCH_RC)"
rm -rf "$PROJ/b100"

# ── G76: the unlistable hint names the right way back ────────────────────────
# chmod for yours; the sandbox identity's for one SANDBOX_UID owns (LNCH-12); its
# owner otherwise (GIT-14, which printed chmod for another user's .git). As a
# non-root user, / is another user's: root's, the "sandbox identity" when 0 is
# passed as SANDBOX_UID. Root owns /, so as root the other two cannot be told
# apart here.
load_fn _term; load_fn _q; load_fn _unlistable_hint
mkdir -p "$TMP/h76"
h76a="$(_unlistable_hint "$TMP/h76" '' 4242 2>&1)"
if [[ "$(id -u)" != 0 ]]; then
  h76b="$(_unlistable_hint / '' 0 2>&1)"; h76c="$(_unlistable_hint / '' 4242 2>&1)"
else
  h76b="It belongs to the sandbox identity (SANDBOX_UID=0)"; h76c="It is not yours"
fi
[[ "$h76a" == "Restore: chmod u+rx $TMP/h76" && "$h76b" == *"It belongs to the sandbox identity (SANDBOX_UID=0)"* && "$h76c" == "It is not yours"* ]] \
  && pass "G76 the unlistable hint is chmod for yours, the sandbox identity's for SANDBOX_UID's, the owner's otherwise" \
  || fail "G76 unlistable hint (yours: $h76a | sandbox's: $h76b | other: $h76c)"
rm -rf "$TMP/h76"

# ── G77: a repository whose HEAD the agent removed stays protected ───────────
# A git directory was recognised only by its HEAD, which is not bound, so `mv
# .git/HEAD .git/H` in one session left the next launch binding nothing; the
# agent put HEAD back and wrote the config the host's git then ran (GIT-7). A
# .git directory is protected whatever its HEAD, and a bare one a .git file
# names by the commondir placeholder an earlier launch made. A bare one only the
# scan finds gets no placeholder (GIT-11; G79), so it is not covered.
"${G[@]}" init -q "$PROJ/h77" && "${G[@]}" init -q --bare "$PROJ/b77.git" \
  && mkdir -p "$PROJ/w77" && printf 'gitdir: ../b77.git\n' > "$PROJ/w77/.git"
launch ..
mv "$PROJ/h77/.git/HEAD" "$PROJ/h77/.git/H"; mv "$PROJ/b77.git/HEAD" "$PROJ/b77.git/H"
launch ..
has_mount "$PROJ/h77/.git/config:/workspace/proj/h77/.git/config:ro" \
  && has_mount "$PROJ/b77.git/config:/workspace/proj/b77.git/config:ro" \
  && pass "G77 a repository, or a bare one a .git file names, whose HEAD was removed is still protected" \
  || fail "G77 a removed HEAD hid the repository (git mounts: $(git_mounts | grep -E 'h77|b77' | tr '\n' ' '))"
rm -rf "$PROJ/h77" "$PROJ/b77.git" "$PROJ/w77"

# ── G78: a linked worktree's or a submodule's git directory without its HEAD ─
# G77's fix covered a .git directory and a bare one, but not the git directories
# inside a .git: one under .git/worktrees or .git/modules whose HEAD the agent
# removed was still dropped (automated security review of 855d205, HIGH).
U78="$TMP/up78"; "${G[@]}" init -q "$U78" && "${G[@]}" -C "$U78" commit -q --allow-empty -m u
M78="$PROJ/m78"; "${G[@]}" init -q "$M78" && "${G[@]}" -C "$M78" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$M78" worktree add -q "$PROJ/w78" \
  && "${G[@]}" -C "$M78" -c protocol.file.allow=always submodule -q add "$U78" sub 2>/dev/null \
  && "${G[@]}" -C "$M78" commit -q -m s || { printf 'SCAFFOLD-FAILED: G78\n'; exit 1; }
launch ..
mv "$M78/.git/worktrees/w78/HEAD" "$M78/.git/worktrees/w78/H"; mv "$M78/.git/modules/sub/HEAD" "$M78/.git/modules/sub/H"
launch ..
has_mount "$M78/.git/worktrees/w78/commondir:/workspace/proj/m78/.git/worktrees/w78/commondir:ro" \
  && has_mount "$M78/.git/modules/sub/config:/workspace/proj/m78/.git/modules/sub/config:ro" \
  && pass "G78 a linked worktree's and a submodule's git directory stay protected without their HEAD" \
  || fail "G78 a removed HEAD hid an inner git directory (git mounts: $(git_mounts | grep -E 'worktrees/w78|modules/sub' | tr '\n' ' '))"
# …nor without objects/ (the agent can move it aside as it can HEAD), nor a
# linked worktree of a bare repository (automated security review of 7429d87).
mv "$M78/.git/modules/sub/objects" "$M78/.git/modules/sub/O"
"${G[@]}" init -q --bare "$PROJ/b78.git" && "${G[@]}" --git-dir="$PROJ/b78.git" commit-tree -m x "$("${G[@]}" --git-dir="$PROJ/b78.git" write-tree)" >/dev/null 2>&1
"${G[@]}" --git-dir="$PROJ/b78.git" update-ref refs/heads/main "$("${G[@]}" --git-dir="$PROJ/b78.git" commit-tree -m x "$("${G[@]}" --git-dir="$PROJ/b78.git" write-tree)")" \
  && "${G[@]}" --git-dir="$PROJ/b78.git" worktree add -q "$PROJ/bw78" main 2>/dev/null || { printf 'SCAFFOLD-FAILED: G78 bare worktree\n'; exit 1; }
launch ..
mv "$PROJ/b78.git/worktrees/bw78/HEAD" "$PROJ/b78.git/worktrees/bw78/H"
launch ..
has_mount "$M78/.git/modules/sub/config:/workspace/proj/m78/.git/modules/sub/config:ro" \
  && has_mount "$PROJ/b78.git/worktrees/bw78/commondir:/workspace/proj/b78.git/worktrees/bw78/commondir:ro" \
  && pass "G78 a submodule's git directory without objects/, and a bare repository's worktree without HEAD, stay protected" \
  || fail "G78 objects/ or a bare worktree's HEAD hid it (git mounts: $(git_mounts | grep -E 'modules/sub|b78' | tr '\n' ' '))"
rm -rf "$U78" "$M78" "$PROJ/w78" "$PROJ/b78.git" "$PROJ/bw78"

# ── G79: a tracked bare fixture gets its placeholders; .gitignore keeps it clean
# A project that tracks a config-less fixture (testdata/fixture.git) gets config,
# commondir and hooks/ written into it at its first protected launch (GIT-11).
# Nothing can exempt one: the SANDBOX_GIT_FIXTURES list that did was dropped,
# because a committed list could name a bare repository you push to, which the
# host's git runs (LNCH-16, GIT-21; the user's choice). Two fixtures, one
# config-less and one as `git init --bare` left it, minus its config; the old
# key, set anyway, changes nothing. The empty hooks/ is not shown by git, so two
# .gitignore lines leave the project's status clean.
mkdir -p "$PROJ/td79" && "${G[@]}" init -q --bare "$PROJ/td79/fx.git" \
  && rm -rf "$PROJ/td79/fx.git/config" "$PROJ/td79/fx.git/hooks" "$PROJ/td79/fx.git/description" "$PROJ/td79/fx.git/info" \
  && "${G[@]}" init -q --bare "$PROJ/td79/full.git" && rm -f "$PROJ/td79/full.git/config" \
  && "${G[@]}" -C "$PROJ" add -f td79 && "${G[@]}" -C "$PROJ" commit -q -m fixtures79 || { printf 'SCAFFOLD-FAILED: G79\n'; exit 1; }
SANDBOX_GIT_FIXTURES="td79/fx.git td79/full.git" launch ..
ok79=1
for r in fx full; do
  [[ -f "$PROJ/td79/$r.git/commondir" && -f "$PROJ/td79/$r.git/config" ]] || ok79=""
  has_mount "$PROJ/td79/$r.git/commondir:/workspace/proj/td79/$r.git/commondir:ro" || ok79=""
done
[[ -n "$ok79" ]] && pass "G79 a tracked bare fixture gets its placeholders, SANDBOX_GIT_FIXTURES or not" \
  || fail "G79 a fixture was left without placeholders ($(git_mounts | grep td79 | tr '\n' ' '))"
printf 'td79/*.git/commondir\ntd79/*.git/config\n' > "$PROJ/td79/.gitignore.79"
st79="$("${G[@]}" -C "$PROJ" -c core.excludesFile="$PROJ/td79/.gitignore.79" status --porcelain --untracked-files=all -- td79 2>&1)"
[[ "$st79" == "?? td79/.gitignore.79" ]] && pass "G79 two .gitignore lines leave the fixtures' status clean" \
  || fail "G79 status with the ignore lines: $(tr '\n' ' ' <<<"$st79")"
"${G[@]}" -C "$PROJ" rm -rq --cached td79 && "${G[@]}" -C "$PROJ" commit -q -m unfixtures79; rm -rf "$PROJ/td79"

# ── G81: a bare repository another mount's worktree uses keeps its placeholders
# GIT-11 exempts a bare repository only the scan finds; one a linked worktree's
# commondir reaches from another writable mount is one the host's git uses, and
# was exempted too, where that mount's own scan cannot see it (a pruned
# node_modules) (automated security review of 26dd7cf, MEDIUM).
X81="$TMP/x81"; mkdir -p "$X81/node_modules" && "${G[@]}" init -q --bare "$X81/node_modules/b81.git" \
  && "${G[@]}" --git-dir="$X81/node_modules/b81.git" update-ref refs/heads/main "$("${G[@]}" --git-dir="$X81/node_modules/b81.git" commit-tree -m x "$("${G[@]}" --git-dir="$X81/node_modules/b81.git" write-tree)")" \
  && "${G[@]}" --git-dir="$X81/node_modules/b81.git" worktree add -q "$PROJ/w81" main 2>/dev/null || { printf 'SCAFFOLD-FAILED: G81\n'; exit 1; }
EXTRA_MOUNTS="$X81" launch ..
[[ -f "$X81/node_modules/b81.git/commondir" ]] && has_mount "$X81/node_modules/b81.git/config:/workspace/x81/node_modules/b81.git/config:ro" \
  && pass "G81 a bare repository a worktree in another mount uses gets its placeholders" \
  || fail "G81 the bare common directory was exempted (commondir: $([[ -f "$X81/node_modules/b81.git/commondir" ]] && echo made || echo missing); $(git_mounts | grep b81 | tr '\n' ' '))"
rm -rf "$X81" "$PROJ/w81"

# ── G83: past SANDBOX_GIT_MAX the scan stops reading indexes ─────────────────
# Every planted repository was followed and its index read before the protection
# loop counted it, so 20k of them cost minutes before the refusal they were
# always going to get (GIT-9). Each unreadable index prints a WARNING when read.
if [[ "$(id -u)" != 0 ]]; then
  for n in $(seq 1 50); do "${G[@]}" init -q "$PROJ/p83/r$n" && : > "$PROJ/p83/r$n/.git/index" && chmod 000 "$PROJ/p83/r$n/.git/index"; done
  SANDBOX_GIT_MAX=5 launch ..
  nw83="$(grep -c 'cannot read the index of' "$ERR")"
  [[ "$LAUNCH_RC" != 0 && "$nw83" -le 10 ]] && grep -qF 'more than 5 git directories' "$ERR" \
    && pass "G83 past SANDBOX_GIT_MAX the scan stops reading indexes ($nw83 read for 50 repositories)" \
    || fail "G83 indexes read past the limit (rc=$LAUNCH_RC; $nw83 read; $(grep -F 'git directories' "$ERR" | head -1))"
  chmod -R u+rwx "$PROJ/p83"; rm -rf "$PROJ/p83"
else
  printf 'SKIP: G83 — chmod does not constrain root\n'
fi

# ── G85: a scan that stopped past SANDBOX_GIT_MAX refuses the launch ─────────
# The scan's stop counts what it queued; the refusal counted what the protection
# loop binds, which skips a repository under a read-only overlay. Ten planted
# inside a launcher stopped the scan, then counted for nothing, and the launch
# went ahead with what came after them unfollowed (automated security review
# of 630f5b0, HIGH).
L85="$PROJ/l85"; mkdir -p "$L85"; : > "$L85/sandbox.sh"; : > "$L85/sandbox-common.sh"
for n in $(seq 1 10); do "${G[@]}" init -q "$L85/r$n"; done
SANDBOX_GIT_MAX=5 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'more than 5 git directories' "$ERR" \
  && pass "G85 a scan stopped past SANDBOX_GIT_MAX refuses the launch, whatever the protection loop would count" \
  || fail "G85 a stopped scan let the launch go ahead (rc=$LAUNCH_RC)"
rm -rf "$L85"

# ── G87: a bare repository git made gets its placeholders, fixture or not ───
# A bare repository you push to — say ./remote.git in the project — is one the
# host's git runs: the agent wrote a commondir into one that had none, pointing
# at a copy with its own post-receive, and the next `git push` ran it (review of
# the batch 10 branch, under GIT-11). Nothing exempts one (G79).
"${G[@]}" init -q --bare "$PROJ/remote87.git"
launch ..
[[ -f "$PROJ/remote87.git/commondir" ]] && has_mount "$PROJ/remote87.git/commondir:/workspace/proj/remote87.git/commondir:ro" \
  && pass "G87 a bare repository only the scan finds gets its placeholders" \
  || fail "G87 a pushed-to bare repository was left without a commondir ($(git_mounts | grep remote87 | tr '\n' ' '))"
rm -rf "$PROJ/remote87.git"

# ── G88: a bare repository's worktree, checked out outside every mount ──────
# Its git directory (b88.git/worktrees/wt) is not under a .git, and no .git file
# in a mount names it: once its HEAD is moved aside, only its commondir marks
# it, which the scan must report (review of the batch 10 branch: deleting that
# clause passed every test).
"${G[@]}" init -q --bare "$PROJ/b88.git" \
  && "${G[@]}" --git-dir="$PROJ/b88.git" update-ref refs/heads/main "$("${G[@]}" --git-dir="$PROJ/b88.git" commit-tree -m x "$("${G[@]}" --git-dir="$PROJ/b88.git" write-tree)")" \
  && "${G[@]}" --git-dir="$PROJ/b88.git" worktree add -q "$TMP/out88/wt" main 2>/dev/null || { printf 'SCAFFOLD-FAILED: G88\n'; exit 1; }
launch ..
mv "$PROJ/b88.git/worktrees/wt/HEAD" "$PROJ/b88.git/worktrees/wt/H"
launch ..
has_mount "$PROJ/b88.git/worktrees/wt/commondir:/workspace/proj/b88.git/worktrees/wt/commondir:ro" \
  && pass "G88 a bare repository's worktree checked out outside the mounts stays protected without its HEAD" \
  || fail "G88 only the commondir marked it, and the scan missed it ($(git_mounts | grep b88 | tr '\n' ' '))"
rm -rf "$PROJ/b88.git" "$TMP/out88"

# ── G92: a group directory that is a link is refused; the group skip is narrow ─
# With the host group gone, ~/.ai-containers/<group> as a link to $HOME was the
# one way left to mount the real dot-directories, and the scan, which skips the
# group's own directories, then skipped every repository under the link's
# target too (review of batch 11). A link is refused before anything is made…
# …before anything is made: no docker call at all (not even `docker info`), and
# no output directory in the launch directory (LNCH-20).
mkdir -p "$TMP/elsewhere92"; ln -s "$TMP/elsewhere92" "$HOME/.ai-containers/g92"
rm -rf "$LAUNCHER/.agent-blocked"
AI_CONTAINER_GROUP=g92 launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$CAPTURE" ]] && grep -qF 'is a link' "$ERR" \
  && pass "G92 a group directory that is a link refuses the launch, before docker" \
  || fail "G92 a linked group directory (rc=$LAUNCH_RC; $(grep -E 'ERROR|link' "$ERR" | head -2 | tr '\n' ' '))"
[[ ! -e "$CAPTURE.calls" && ! -e "$LAUNCHER/.agent-blocked" ]] \
  && pass "G92 …and before any docker call or output directory" \
  || fail "G92 the linked-group refusal came late (docker: $(tr '\n' ';' < "$CAPTURE.calls" 2>/dev/null); .agent-blocked: $([[ -e "$LAUNCHER/.agent-blocked" ]] && echo made))"
grep -qF 'link ~/.ai-containers itself' "$ERR" \
  && pass "G92 a link elsewhere says to link ~/.ai-containers itself" || fail "G92 the hint for a link elsewhere ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/g92"; rm -rf "$TMP/elsewhere92"
# The hint follows where the link leads (LNCH-20): nowhere; a file; another group;
# a directory there that is no group; somewhere inside $HOME.
ln -s "$TMP/nowhere92" "$HOME/.ai-containers/n92"
AI_CONTAINER_GROUP=n92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'leads nowhere' "$ERR" \
  && pass "G92 a dangling group link says it leads nowhere" || fail "G92 the hint for a dangling link ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/n92"
: > "$TMP/file92"; ln -s "$TMP/file92" "$HOME/.ai-containers/f92"
AI_CONTAINER_GROUP=f92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && ! grep -qF 'leads nowhere' "$ERR" && grep -qF 'not a directory' "$ERR" \
  && pass "G92 a group link to a file says so, not that it leads nowhere" || fail "G92 the hint for a link to a file ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/f92" "$TMP/file92"
mkdir -p "$HOME/.ai-containers/other92"; ln -s "$HOME/.ai-containers/other92" "$HOME/.ai-containers/o92"
AI_CONTAINER_GROUP=o92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'use AI_CONTAINER_GROUP=other92' "$ERR" && grep -qF 'from:other92' "$ERR" \
  && pass "G92 a group link to another group names that group" || fail "G92 the hint for a link to another group ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/o92"; rm -rf "$HOME/.ai-containers/other92"
mkdir -p "$HOME/.ai-containers/.verify-92"; ln -s "$HOME/.ai-containers/.verify-92" "$HOME/.ai-containers/v92"
AI_CONTAINER_GROUP=v92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && ! grep -qF 'AI_CONTAINER_GROUP=.verify' "$ERR" \
  && pass "G92 a link to a directory that is no group does not offer it as one" || fail "G92 a .verify-* directory offered as a group ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/v92"; rm -rf "$HOME/.ai-containers/.verify-92"
mkdir -p "$HOME/sub92"; ln -s "$HOME/sub92" "$HOME/.ai-containers/s92"
AI_CONTAINER_GROUP=s92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && ! grep -qF 'another disk' "$ERR" && grep -qF "rm $HOME/.ai-containers/s92" "$ERR" \
  && pass "G92 a link into \$HOME says to remove it, not to move groups to another disk" || fail "G92 the hint for a link into \$HOME ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/s92"; rm -rf "$HOME/sub92"
# Linked to $HOME itself — the case the check exists for — the way out is a
# group made as a copy (from:host), never `cp -a $HOME/.`, which copies the whole
# home, every other group included (review of 18011da).
ln -s "$HOME" "$HOME/.ai-containers/h92"
AI_CONTAINER_GROUP=h92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'AI_CONTAINER_GROUP_INIT=from:host' "$ERR" && ! grep -qF 'cp -a' "$ERR" \
  && pass "G92 a group linked to \$HOME is refused, pointing at from:host, not a cp of the home" \
  || fail "G92 the hint for a group linked to \$HOME ($(grep -E 'ERROR|cp|from:host' "$ERR" | head -3 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/h92"
# …and a group directory that is $HOME by another route — ~/.ai-containers moved
# to $HOME's parent, the group named after $HOME — is refused too.
H92="$TMP/h92/me"; mkdir -p "$H92"; ln -s "$TMP/h92" "$H92/.ai-containers"
HOME="$H92" AI_CONTAINER_GROUP=me launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$CAPTURE" ]] && grep -qF 'is your home directory' "$ERR" \
  && pass "G92 a group directory that resolves to \$HOME is refused" \
  || fail "G92 a group directory resolving to \$HOME (rc=$LAUNCH_RC; $(grep -E 'ERROR' "$ERR" | head -1))"
rm -rf "$TMP/h92"
# …and so is one that is $HOME under another path — a bind mount, a macOS firmlink,
# another case on a case-insensitive filesystem — told apart by device:inode, not
# by path (LNCH-19). A `stat` that reports $HOME's for the group stands in for the
# alias, which needs root to make.
mkdir -p "$HOME/.ai-containers/al92" "$TMP/shim92"
cat > "$TMP/shim92/stat" <<SHIM
#!/usr/bin/env bash
real="\$(PATH="${PATH#"$TMP/bin:"}" command -v stat)"
a=()
for x in "\$@"; do case "\$x" in "$HOME/.ai-containers/al92"|"$HOME/.ai-containers/al92/.") a+=("$HOME") ;; *) a+=("\$x") ;; esac; done
exec "\$real" "\${a[@]}"
SHIM
chmod +x "$TMP/shim92/stat"
PATH="$TMP/shim92:$PATH" AI_CONTAINER_GROUP=al92 launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$CAPTURE" ]] && grep -qF 'is your home directory' "$ERR" \
  && pass "G92 a group directory that is \$HOME by device:inode is refused" \
  || fail "G92 a group directory aliasing \$HOME (rc=$LAUNCH_RC; $(grep -E 'ERROR' "$ERR" | head -1))"
rm -rf "$HOME/.ai-containers/al92" "$TMP/shim92"
# A group LINK to such an alias leads to your home too, and its hint is the
# from:host one, not the one for a link elsewhere (GAP-2 slice 8).
mkdir -p "$TMP/alias92" "$TMP/shim92"; ln -s "$TMP/alias92" "$HOME/.ai-containers/la92"
cat > "$TMP/shim92/stat" <<SHIM
#!/usr/bin/env bash
real="\$(PATH="${PATH#"$TMP/bin:"}" command -v stat)"
a=()
for x in "\$@"; do case "\$x" in "$HOME/.ai-containers/la92/.") a+=("$HOME") ;; *) a+=("\$x") ;; esac; done
exec "\$real" "\${a[@]}"
SHIM
chmod +x "$TMP/shim92/stat"
PATH="$TMP/shim92:$PATH" AI_CONTAINER_GROUP=la92 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'It leads to your home directory' "$ERR" && grep -qF 'AI_CONTAINER_GROUP_INIT=from:host' "$ERR" \
  && pass "G92 a group link to \$HOME under another path says it leads to your home" \
  || fail "G92 the hint for a group link to an alias of \$HOME ($(grep -v ERROR "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/la92"; rm -rf "$TMP/alias92" "$TMP/shim92"
# Where stat cannot report $HOME's device:inode, the path alone still refuses a
# group directory that resolves to $HOME.
H92="$TMP/h92/me"; mkdir -p "$H92" "$TMP/shim92"; ln -s "$TMP/h92" "$H92/.ai-containers"
cat > "$TMP/shim92/stat" <<SHIM
#!/usr/bin/env bash
real="\$(PATH="${PATH#"$TMP/bin:"}" command -v stat)"
for x in "\$@"; do [[ "\$x" == "$H92/." ]] && { : > "$TMP/shim92.fired"; exit 1; }; done
exec "\$real" "\$@"
SHIM
chmod +x "$TMP/shim92/stat"
rm -f "$TMP/shim92.fired"
PATH="$TMP/shim92:$PATH" HOME="$H92" AI_CONTAINER_GROUP=me launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$CAPTURE" && -e "$TMP/shim92.fired" ]] && grep -qF 'is your home directory' "$ERR" \
  && pass "G92 a group directory that resolves to \$HOME is refused by path where stat cannot tell" \
  || fail "G92 the path check alone (rc=$LAUNCH_RC; shim: $([[ -e "$TMP/shim92.fired" ]] && echo fired || echo unused); $(grep -E 'ERROR' "$ERR" | head -1))"
rm -rf "$TMP/h92" "$TMP/shim92" "$TMP/shim92.fired"
# A committed sandbox.env that names the host group, which the loader once
# ignored, now refuses the launch, naming the file (review of batch 11).
[[ -f "$LAUNCHER/sandbox.env" ]] && cp "$LAUNCHER/sandbox.env" "$TMP/se92.bak"
printf 'AI_CONTAINER_GROUP=host\n' >> "$LAUNCHER/sandbox.env"
( unset AI_CONTAINER_GROUP; launch .. )
grep -qF "AI_CONTAINER_GROUP=host is set in $LAUNCHER/sandbox.env" "$ERR" && grep -qF 'from:host' "$ERR" && [[ ! -e "$CAPTURE" ]] \
  && pass "G92 a committed sandbox.env naming the host group refuses the launch, naming the file" \
  || fail "G92 host group from sandbox.env ($(grep -E 'ERROR|NOTE' "$ERR" | head -2 | tr '\n' ' '))"
# The file named is the one whose line the loader kept (LNCH-20): not a
# sandbox.local.env whose `AI_CONTAINER_GROUP = host` the loader ignores…
[[ -f "$LAUNCHER/sandbox.local.env" ]] && cp "$LAUNCHER/sandbox.local.env" "$TMP/sl92.bak"
printf 'AI_CONTAINER_GROUP = host\n' >> "$LAUNCHER/sandbox.local.env"
( unset AI_CONTAINER_GROUP; launch .. )
grep -qF "AI_CONTAINER_GROUP=host is set in $LAUNCHER/sandbox.env" "$ERR" && ! grep -qF "set in $LAUNCHER/sandbox.local.env" "$ERR" \
  && pass "G92 the NOTE names the file the loader read the host group from" \
  || fail "G92 the NOTE named a line the loader ignores ($(grep -E 'NOTE' "$ERR" | head -1))"
# …and a sandbox.local.env that exports it quoted is the one named.
if [[ -f "$TMP/sl92.bak" ]]; then cp "$TMP/sl92.bak" "$LAUNCHER/sandbox.local.env"; else rm -f "$LAUNCHER/sandbox.local.env"; fi
printf 'export AI_CONTAINER_GROUP="host"\n' >> "$LAUNCHER/sandbox.local.env"
( unset AI_CONTAINER_GROUP; launch .. )
grep -qF "AI_CONTAINER_GROUP=host is set in $LAUNCHER/sandbox.local.env" "$ERR" \
  && pass "G92 an exported, quoted host group in sandbox.local.env is named" \
  || fail "G92 the NOTE for an exported host group ($(grep -E 'NOTE' "$ERR" | head -1))"
if [[ -f "$TMP/sl92.bak" ]]; then cp "$TMP/sl92.bak" "$LAUNCHER/sandbox.local.env"; else rm -f "$LAUNCHER/sandbox.local.env"; fi
rm -f "$TMP/sl92.bak"
if [[ -f "$TMP/se92.bak" ]]; then cp "$TMP/se92.bak" "$LAUNCHER/sandbox.env"; else rm -f "$LAUNCHER/sandbox.env"; fi
# …and a repository mounted into /workspace from inside the group's directory is
# protected: only the group's own mounts are skipped, not every source under it.
mkdir -p "$HOME/.ai-containers/default/work92" && "${G[@]}" init -q "$HOME/.ai-containers/default/work92/r" \
  || { printf 'SCAFFOLD-FAILED: G92\n'; exit 1; }
w92="$(cd "$HOME/.ai-containers/default/work92" && pwd -P)"
EXTRA_MOUNTS="$w92" launch "$TMP/app"
has_mount "$w92/r/.git/hooks:/workspace/work92/r/.git/hooks:ro" \
  && pass "G92 a repository mounted from inside the group's directory is still protected" \
  || fail "G92 a repository under the group's directory was skipped ($(git_mounts | grep work92 | tr '\n' ' '))"
rm -rf "$HOME/.ai-containers/default/work92"

# ── G125: on a filesystem that heeds case, nothing is spelled ───────────────
# Only a path that crosses a directory ignoring case, or lies on a Windows
# filesystem, is spelled as on disk (from readdir or getcwd), and only those
# count toward the budget of 5000 (AI_CONTAINERS_SPELL_MAX). Spelling every path
# cost a process per directory and, past the budget, refused an ordinary launch
# (GAP-2 slice 3: the guard, damaged, survived). Skipped where TMP needs
# spelling: a directory above it ignores case (macOS's APFS, a case-sensitive
# directory on a Windows drive), or it may lie on a Windows filesystem. Decided
# here, not by the launcher's own _ci_path/_win_path: a falsify run mutates
# those, and one that says "spell" everywhere would skip the check that kills
# it (final review of slice 3). stat -f cannot tell one FUSE filesystem from
# another (smbnetfs, ntfs-3g, sshfs and virtiofs all report FUSE's magic, which
# current GNU stat prints as fuse and older ones as fuseblk), so any of them
# skips.
needs_spell125() {   # <absolute path>
  local p="" r="${1#/}" c f
  while [[ -n "$r" ]]; do
    c="${r%%/*}"; if [[ "$r" == */* ]]; then r="${r#*/}"; else r=""; fi
    f="$(printf '%s' "$c" | LC_ALL=C tr 'A-Za-z' 'a-zA-Z')"
    if [[ "$f" != "$c" && ! -L "$p/$f" && "$p/$f" -ef "$p/$c" ]]; then return 0; fi
    p="$p/$c"
  done
  [[ "$OSTYPE" == linux* ]] || return 1
  case "$(stat -f -c %T -- "$1" 2>/dev/null)" in v9fs|cifs|smb|smb2|smb3|ntfs|fuseblk|fuse) return 0 ;; esac
  return 1
}
mkdir "$TMP/Probe125" || { printf 'SCAFFOLD-FAILED: G125\n'; exit 1; }
if needs_spell125 "$TMP/Probe125"; then
  printf 'SKIP: G125 — a directory above TMPDIR ignores case, or is on a Windows or FUSE filesystem\n'
else
  mkdir -p "$PROJ/lib125" && "${G[@]}" init -q "$PROJ/lib125" || { printf 'SCAFFOLD-FAILED: G125 repo\n'; exit 1; }
  AI_CONTAINERS_SPELL_MAX=0 launch ..
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/lib125/.git/config:/workspace/proj/lib125/.git/config:ro" \
    && pass "G125 where every directory heeds case, no directory is spelled, and none counts toward the budget" \
    || fail "G125 spell budget on a case-sensitive tree (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"
  rm -rf "$PROJ/lib125"
fi
rmdir "$TMP/Probe125"

# ── G142: what one mount's scan finds is protected in every writable mount ────
# that exposes it (GIT-51). An outer EXTRA_MOUNTS directory whose scan does not
# reach the inner primary (node_modules is pruned, or it lies too deep) left the
# primary's .git config and hooks writable in the outer mount's view, while the
# launch said they were read-only.
O142="$TMP/o142"; mkdir -p "$O142/node_modules/x" && "${G[@]}" init -q "$O142/node_modules/x" \
  || { printf 'SCAFFOLD-FAILED: G142\n'; exit 1; }
EXTRA_MOUNTS="$O142" launch "$O142/node_modules/x"
v142=/workspace/o142/node_modules/x/.git
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O142/node_modules/x/.git/config:/workspace/x/.git/config:ro" \
  && has_mount "$O142/node_modules/x/.git/config:$v142/config:ro" && has_mount "$O142/node_modules/x/.git/hooks:$v142/hooks:ro" \
  && has_mount "$O142/node_modules/x/.git/commondir:$v142/commondir:ro" && has_mount "$O142/node_modules/x/.git:$v142:rw" \
  && pass "G142 a repository only the inner mount's scan reaches is read-only, and pinned, in the outer mount's view too" \
  || fail "G142 pruned (rc=$LAUNCH_RC; git mounts: $(git_mounts | sed "s#$TMP#T#g" | tr '\n' ' '))"
# Too deep for the outer scan: eight levels down.
D142="$TMP/d142"; mkdir -p "$D142/1/2/3/4/5/6/7/p" && "${G[@]}" init -q "$D142/1/2/3/4/5/6/7/p" \
  || { printf 'SCAFFOLD-FAILED: G142 deep\n'; exit 1; }
EXTRA_MOUNTS="$D142" launch "$D142/1/2/3/4/5/6/7/p"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$D142/1/2/3/4/5/6/7/p/.git/config:/workspace/d142/1/2/3/4/5/6/7/p/.git/config:ro" \
  && has_mount "$D142/1/2/3/4/5/6/7/p/.git/hooks:/workspace/d142/1/2/3/4/5/6/7/p/.git/hooks:ro" \
  && pass "G142 one past the outer scan's depth is read-only in the outer mount's view too" \
  || fail "G142 deep (rc=$LAUNCH_RC; git mounts: $(git_mounts | sed "s#$TMP#T#g" | tr '\n' ' '))"
rm -rf "$D142"
# A linked worktree's .git file, its git directory outside every mount.
"${G[@]}" -C "$O142/node_modules/x" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$O142/node_modules/x" worktree add -q "$O142/node_modules/x/wt" -b w142 \
  || { printf 'SCAFFOLD-FAILED: G142 worktree\n'; exit 1; }
EXTRA_MOUNTS="$O142" launch "$O142/node_modules/x"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O142/node_modules/x/wt/.git:/workspace/x/wt/.git:ro" \
  && has_mount "$O142/node_modules/x/wt/.git:/workspace/o142/node_modules/x/wt/.git:ro" \
  && has_mount "$O142/node_modules/x/wt:/workspace/o142/node_modules/x/wt:rw" \
  && pass "G142 a .git file only the inner mount's scan reaches is read-only in the outer mount's view too" \
  || fail "G142 .git file (rc=$LAUNCH_RC; mounts: $(mounts | grep -F 'wt/.git' | sed "s#$TMP#T#g" | tr '\n' ' '))"
"${G[@]}" -C "$O142/node_modules/x" worktree remove --force "$O142/node_modules/x/wt"
# One you cannot list is read-only whole in both views.
mkdir -p "$O142/node_modules/x/u" && "${G[@]}" init -q "$O142/node_modules/x/u" && chmod 000 "$O142/node_modules/x/u/.git"
if [[ -r "$O142/node_modules/x/u/.git" ]]; then
  printf 'SKIP: G142 unlistable — chmod does not constrain root\n'
else
  EXTRA_MOUNTS="$O142" launch "$O142/node_modules/x"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$O142/node_modules/x/u/.git:/workspace/x/u/.git:ro" \
    && has_mount "$O142/node_modules/x/u/.git:/workspace/o142/node_modules/x/u/.git:ro" \
    && has_mount "$O142/node_modules/x/u:/workspace/o142/node_modules/x/u:rw" \
    && pass "G142 a .git you cannot list, only the inner mount's scan reaches, is read-only whole in the outer mount's view too" \
    || fail "G142 unlistable (rc=$LAUNCH_RC; mounts: $(mounts | grep -F 'u/.git' | sed "s#$TMP#T#g" | tr '\n' ' '))"
fi
chmod 755 "$O142/node_modules/x/u/.git"; rm -rf "$O142"
# One both mounts' scans reach is protected once in each view, and its config is
# judged once: a core.hooksPath into the mount is named once, not per view.
N142="$TMP/n142"; mkdir -p "$N142/a/.husky" && "${G[@]}" init -q "$N142/a" && "${G[@]}" -C "$N142/a" config core.hooksPath .husky \
  || { printf 'SCAFFOLD-FAILED: G142 both\n'; exit 1; }
EXTRA_MOUNTS="$N142" launch "$N142/a"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$N142/a/.git/config:/workspace/a/.git/config:ro" \
  && has_mount "$N142/a/.git/config:/workspace/n142/a/.git/config:ro" \
  && [[ -z "$(mounts | cut -d: -f2 | sort | uniq -d)" ]] \
  && [[ "$(grep -c '(core.hooksPath), which the agent' "$ERR")" == 1 ]] \
  && pass "G142 one both scans reach is bound once in each view, and judged once" \
  || fail "G142 both (rc=$LAUNCH_RC; duplicate destinations: $(mounts | cut -d: -f2 | sort | uniq -d | tr '\n' ' '); hooksPath NOTEs: $(grep -c '(core.hooksPath), which the agent' "$ERR"))"
rm -rf "$N142/a"
# ... and once when one view puts it under a read-only overlay and the other
# protects it: the primary a launcher, overlaid only in the outer view.
# Its hooks a link out of every mount: named once, at the view where it is under
# the overlay, though the view kept for judging is the protected one.
mkdir -p "$N142/node_modules/x/r/.husky" "$TMP/h142" && : > "$N142/node_modules/x/sandbox.sh" && : > "$N142/node_modules/x/sandbox-common.sh" \
  && "${G[@]}" init -q "$N142/node_modules/x/r" && "${G[@]}" -C "$N142/node_modules/x/r" config core.hooksPath .husky \
  && rm -rf "$N142/node_modules/x/r/.git/hooks" && ln -s "$TMP/h142" "$N142/node_modules/x/r/.git/hooks" \
  || { printf 'SCAFFOLD-FAILED: G142 overlay\n'; exit 1; }
EXTRA_MOUNTS="$N142" launch "$N142/node_modules/x"
[[ "$LAUNCH_RC" == 0 && "$(grep -c '(core.hooksPath), which the agent' "$ERR")" == 1 ]] \
  && [[ "$(grep -c 'under a read-only overlay, is a symlink' "$ERR")" == 1 ]] \
  && grep -qF "WARNING: /workspace/n142/node_modules/x/r/.git/hooks, under a read-only overlay, is a symlink" "$ERR" \
  && pass "G142 one protected in one view and under a read-only overlay in another is judged once, its links as the overlaid view's" \
  || fail "G142 overlay and protected (rc=$LAUNCH_RC; hooksPath NOTEs: $(grep -c '(core.hooksPath), which the agent' "$ERR"); $(grep -F 'under a read-only overlay' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/h142"
rm -rf "$N142"
# The walk up from the primary, past the outer mount's scan (GIT-55): a .git
# file there is read-only in the outer mount's view, where the agent could
# otherwise point it at a repository of its own; a .git link there is named, and
# the repository it leads to is protected there.
W142="$TMP/w142"; "${G[@]}" init -q "$TMP/m142" && "${G[@]}" -C "$TMP/m142" commit -q --allow-empty -m m \
  && mkdir -p "$W142/node_modules" && "${G[@]}" -C "$TMP/m142" worktree add -q "$W142/node_modules/x" -b w142 \
  && mkdir -p "$W142/node_modules/x/sub" || { printf 'SCAFFOLD-FAILED: G142 walk up\n'; exit 1; }
EXTRA_MOUNTS="$W142" launch "$W142/node_modules/x/sub"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$W142/node_modules/x/.git:/workspace/w142/node_modules/x/.git:ro" \
  && pass "G142 a .git file above the primary, past the outer scan, is read-only in the outer mount's view" \
  || fail "G142 .git file above (rc=$LAUNCH_RC; $(mounts | grep -F 'x/.git' | tr '\n' ' '))"
"${G[@]}" -C "$TMP/m142" worktree remove --force "$W142/node_modules/x"; rm -rf "$TMP/m142" "$W142"
mkdir -p "$W142/node_modules/q/sub" && "${G[@]}" init -q --bare "$W142/node_modules/.evil" \
  && ln -s ../.evil "$W142/node_modules/q/.git" || { printf 'SCAFFOLD-FAILED: G142 link above\n'; exit 1; }
EXTRA_MOUNTS="$W142" launch "$W142/node_modules/q/sub"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: $W142/node_modules/q/.git is a symlink inside a writable mount" "$ERR" \
  && [[ "$(grep -cF "$W142/node_modules/q/.git is a symlink" "$ERR")" == 1 ]] \
  && has_mount "$W142/node_modules/.evil/config:/workspace/w142/node_modules/.evil/config:ro" \
  && pass "G142 a .git link above the primary, past the outer scan, is named once and what it leads to protected" \
  || fail "G142 .git link above (rc=$LAUNCH_RC; $(grep -F 'q/.git' "$ERR" | head -2 | tr '\n' ' '); $(mounts | grep -F '.evil' | tr '\n' ' '))"
# A .git link to a FILE there, which git reads as a .git file, is followed to the
# git directory that file names, protected in the outer view too.
rm -rf "$W142"; mkdir -p "$W142/node_modules/q/sub" && "${G[@]}" init -q --bare "$W142/node_modules/.evil" \
  && printf 'gitdir: ../.evil\n' > "$W142/node_modules/q/.gitfile" && ln -s .gitfile "$W142/node_modules/q/.git" \
  || { printf 'SCAFFOLD-FAILED: G142 link to a file\n'; exit 1; }
EXTRA_MOUNTS="$W142" launch "$W142/node_modules/q/sub"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: $W142/node_modules/q/.git is a symlink inside a writable mount" "$ERR" \
  && has_mount "$W142/node_modules/.evil/config:/workspace/w142/node_modules/.evil/config:ro" \
  && pass "G142 a .git link to a file above the primary is named, and the git directory the file names protected" \
  || fail "G142 .git link to a file (rc=$LAUNCH_RC; $(grep -F 'q/.git' "$ERR" | head -1); $(mounts | grep -F '.evil' | tr '\n' ' '))"
# Reached by the outer mount's scan too, it is named once.
rm -rf "$W142"; mkdir -p "$W142/q/sub" && "${G[@]}" init -q --bare "$W142/.evil" && ln -s ../.evil "$W142/q/.git" \
  || { printf 'SCAFFOLD-FAILED: G142 link reached\n'; exit 1; }
EXTRA_MOUNTS="$W142" launch "$W142/q/sub"
[[ "$LAUNCH_RC" == 0 && "$(grep -cF "$W142/q/.git is a symlink" "$ERR")" == 1 ]] \
  && pass "G142 a .git link above the primary that the outer scan reaches is named once" \
  || fail "G142 .git link named twice (rc=$LAUNCH_RC; $(grep -cF "$W142/q/.git is a symlink" "$ERR") times)"
rm -rf "$W142"
# Past SANDBOX_GIT_MAX, where every place counts, a repository the listing names
# twice is named the second time with where it lands.
C142="$TMP/c142"; for r142 in "$C142/a1" "$C142/a2" "$C142/node_modules/x/r1" "$C142/node_modules/x/r2" "$C142/node_modules/x/r3" "$C142/node_modules/x/r4"; do
  mkdir -p "$r142" && "${G[@]}" init -q "$r142" || { printf 'SCAFFOLD-FAILED: G142 cap\n'; exit 1; }
done
SANDBOX_GIT_MAX=4 EXTRA_MOUNTS="$C142" launch "$C142/node_modules/x"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'in each mount that exposes it' "$ERR" \
  && grep -qE "^         $C142/node_modules/x/r[1-4]/\.git \(at /workspace/c142/node_modules/x/r[1-4]/\.git\)$" "$ERR" \
  && pass "G142 past SANDBOX_GIT_MAX a name listed twice says where the second one lands" \
  || fail "G142 cap listing (rc=$LAUNCH_RC; $(grep -E 'ERROR|^         ' "$ERR" | head -7 | tr '\n' ' '))"
rm -rf "$C142"

# ── G157: a repository mounted read-only inside a writable mount ─────────────
# A read-only mount was not scanned, since nothing can be written through it.
# But one inside a writable mount whose scan does not reach it (an EXTRA_MOUNTS
# directory, its node_modules pruned) is writable through that mount, and its
# .git config and hooks stayed writable there (GIT-56). It is now scanned for
# what to protect in the writable mount's view.
O157="$TMP/o157"; mkdir -p "$O157/node_modules/x" && "${G[@]}" init -q "$O157/node_modules/x" \
  || { printf 'SCAFFOLD-FAILED: G157\n'; exit 1; }
v157=/workspace/o157/node_modules/x/.git
EXTRA_MOUNTS="$O157" DOCS_PATH="$O157/node_modules/x" launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$O157/node_modules/x:/workspace/docs:ro" \
  && has_mount "$O157/node_modules/x/.git/config:$v157/config:ro" && has_mount "$O157/node_modules/x/.git/hooks:$v157/hooks:ro" \
  && pass "G157 a repository mounted read-only inside a writable mount is read-only through that mount too" \
  || fail "G157 read-only inside writable (rc=$LAUNCH_RC; git mounts: $(git_mounts | sed "s#$TMP#T#g" | tr '\n' ' '))"
# Nothing is bound in the read-only mount's own view: it is read-only whole.
! grep -qF ":/workspace/docs/.git" < <(mounts) \
  && pass "G157 nothing is bound in the read-only mount's own view" \
  || fail "G157 binds in the read-only view ($(mounts | grep -F ':/workspace/docs/' | tr '\n' ' '))"
rm -rf "$O157"

# ── G144: what the scan takes for a git directory inside a .git ──────────────
# GAP-2 slice 6: each condition here, turned, survived every test.
# A .git, or a directory inside one, that you can read but not search is as
# unlistable as one you can do neither with (G10, G16): read-only whole, named.
mkdir -p "$TMP/probe144"; chmod 000 "$TMP/probe144"
if [[ -r "$TMP/probe144" ]]; then
  printf 'SKIP: G144 unsearchable — chmod does not constrain root\n'
else
  mkdir -p "$TMP/u144/r" && "${G[@]}" init -q "$TMP/u144/r" && chmod 0600 "$TMP/u144/r/.git"
  EXTRA_MOUNTS="$TMP/u144" launch "$TMP/app"
  has_mount "$TMP/u144/r/.git:/workspace/u144/r/.git:ro" && grep -qF "WARNING: $TMP/u144/r/.git cannot be listed by you" "$ERR" \
    && pass "G144 a .git you can read but not search is read-only whole, and named" \
    || fail "G144 .git 0600 (rc=$LAUNCH_RC; $(mounts | grep -F /u144/ | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$TMP/u144/r/.git"; mkdir -p "$TMP/u144/r/.git/modules/m" && chmod 0600 "$TMP/u144/r/.git/modules/m"
  EXTRA_MOUNTS="$TMP/u144" launch "$TMP/app"
  has_mount "$TMP/u144/r/.git/modules/m:/workspace/u144/r/.git/modules/m:ro" \
    && grep -qF "WARNING: $TMP/u144/r/.git/modules/m cannot be listed by you" "$ERR" \
    && pass "G144 a directory inside a .git you can read but not search is read-only whole, and named" \
    || fail "G144 dir in .git 0600 (rc=$LAUNCH_RC; $(mounts | grep -F /u144/ | tr '\n' ' '); $(grep -E 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$TMP/u144/r/.git/modules/m"; rm -rf "$TMP/u144"
fi
chmod 755 "$TMP/probe144"; rmdir "$TMP/probe144"
# A directory elsewhere in .git holding a gitdir is no linked worktree's: nothing
# is made in it. One in .git/worktrees with neither commondir nor gitdir was
# passed over too, and is now taken by where it lies, with the placeholders any
# git directory gets (bugs review GIT-78; G189).
mkdir -p "$PROJ/.git/worktrees/e144" "$PROJ/.git/f144" && printf 'ref: refs/heads/main\n' > "$PROJ/.git/worktrees/e144/HEAD" \
  && printf 'x\n' > "$PROJ/.git/f144/gitdir" || { printf 'SCAFFOLD-FAILED: G144 worktrees\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 && ! -e "$PROJ/.git/f144/commondir" ]] \
  && ! grep -qE '/\.git/f144' < <(git_mounts) \
  && pass "G144 a directory in .git that is no linked worktree's gets nothing made in it" \
  || fail "G144 not a worktree (rc=$LAUNCH_RC; $(ls "$PROJ/.git/f144" | tr '\n' ' '))"
[[ "$LAUNCH_RC" == 0 && "$(cat "$PROJ/.git/worktrees/e144/commondir" 2>/dev/null)" == ./ ]] \
  && has_mount "$PROJ/.git/worktrees/e144/commondir:/workspace/proj/.git/worktrees/e144/commondir:ro" \
  && pass "G144 one in .git/worktrees with neither commondir nor gitdir gets the placeholder, read-only" \
  || fail "G144 under worktrees (rc=$LAUNCH_RC; $(ls "$PROJ/.git/worktrees/e144" | tr '\n' ' '))"
rm -rf "$PROJ/.git/worktrees/e144" "$PROJ/.git/f144"
# One whose commondir is a link (to a regular file), with no HEAD and no gitdir,
# is a linked worktree's still: the scan's find skips the link, so only the
# directory's own check finds it, and the link refuses the launch (GIT-62; G166).
mkdir -p "$PROJ/.git/worktrees/l144" && printf '../..\n' > "$PROJ/.git/cd144" && ln -s ../../cd144 "$PROJ/.git/worktrees/l144/commondir"
launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $PROJ/.git/worktrees/l144/commondir is a symlink" "$ERR" \
  && pass "G144 a linked worktree's directory whose commondir is a link is found, and the link refuses the launch" \
  || fail "G144 linked commondir (rc=$LAUNCH_RC; $(grep -F l144 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/.git/worktrees/l144" "$PROJ/.git/cd144"; rmdir "$PROJ/.git/worktrees" 2>/dev/null
# A submodule's git directory with no HEAD is protected holding any one of
# objects/, refs/, config, hooks/ or index; a plain directory inside one is not,
# nor the info/ that git gc writes refs in, a file (review of GIT-69's fix).
for x144 in objects refs config hooks index; do
  mkdir -p "$PROJ/.git/modules/m$x144"
  case "$x144" in objects|refs|hooks) mkdir -p "$PROJ/.git/modules/m$x144/$x144" ;; *) : > "$PROJ/.git/modules/m$x144/$x144" ;; esac
done
mkdir -p "$PROJ/.git/modules/mconfig/plain" "$PROJ/.git/modules/mconfig/info" && : > "$PROJ/.git/modules/mconfig/info/refs" \
  || { printf 'SCAFFOLD-FAILED: G144 info\n'; exit 1; }
launch ..
m144=""; for x144 in objects refs config hooks index; do has_mount "$PROJ/.git/modules/m$x144/config:/workspace/proj/.git/modules/m$x144/config:ro" || m144+=" $x144"; done
[[ "$LAUNCH_RC" == 0 && -z "$m144" && ! -e "$PROJ/.git/modules/mconfig/plain/commondir" && ! -e "$PROJ/.git/modules/mconfig/info/commondir" ]] \
  && ! grep -qF "$PROJ/.git/modules/mconfig/info" < <(git_mounts) \
  && pass "G144 a submodule's git directory with no HEAD is protected holding any one of what git keeps there" \
  || fail "G144 module directories (rc=$LAUNCH_RC; not protected:$m144; in plain: $(ls "$PROJ/.git/modules/mconfig/plain" | tr '\n' ' '))"
rm -rf "$PROJ/.git/modules"

# ── G158: what the SANDBOX_GIT_MAX refusal names, exactly ────────────────────
# Each scan stays within the limit, so the protection loop is what refuses,
# counting every place a mount exposes a repository: here one repository in
# three views, and one deeper that only the outer scan finds. Named: the rest
# at the depth it stopped at and every deeper one, whichever scan found it;
# not the one already protected. A name a second time says where it lands, the
# first time it is bare; and a listing shorter than five ends.
C158="$TMP/c158"
for r158 in "$C158/o/a/b/c" "$C158/o/node_modules/x/s"; do
  mkdir -p "$r158" && "${G[@]}" init -q "$r158" || { printf 'SCAFFOLD-FAILED: G158\n'; exit 1; }
done
SANDBOX_GIT_MAX=1 EXTRA_MOUNTS="$C158/o $C158/o/node_modules" launch_timed 60 "$C158/o/node_modules/x"
l158="$(awk '/Among those past the limit:/ {p = 1; next} p && /^         / {print} p && !/^         / {p = 0}' "$ERR")"
w158="$(printf '         %s\n' "$C158/o/node_modules/x/s/.git" "$C158/o/a/b/c/.git" \
          "$C158/o/node_modules/x/s/.git (at /workspace/o/node_modules/x/s/.git)")"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 && ! -s "$CAPTURE" && "$l158" == "$w158" ]] \
  && pass "G158 past SANDBOX_GIT_MAX the refusal names exactly the places past the limit (${LAUNCH_S}s)" \
  || fail "G158 cap listing (rc=$LAUNCH_RC; named: $(tr '\n' '|' <<<"$l158"))"
rm -rf "$C158"

# ── G159: a git directory's file of the wrong type: what to do about it ──────
# A HEAD, config or hooks of the wrong type (here a directory, or a file for
# hooks) refuses the launch, saying what to do: a HEAD is replaced with a ref,
# anything else removed.
for v159 in HEAD config hooks; do
  mkdir -p "$PROJ/r159" && "${G[@]}" init -q "$PROJ/r159" || { printf 'SCAFFOLD-FAILED: G159\n'; exit 1; }
  rm -rf "${PROJ:?}/r159/.git/$v159"
  if [[ "$v159" == hooks ]]; then : > "$PROJ/r159/.git/hooks"; else mkdir "$PROJ/r159/.git/$v159"; fi
  launch ..
  case "$v159" in
    HEAD) h159="Replace it on the host with a regular file, e.g. printf 'ref: refs/heads/main\\n' > $PROJ/r159/.git/HEAD"; t159="regular file" ;;
    config) h159="would read what it writes. Remove it on the host (rm $PROJ/r159/.git/config)."; t159="regular file" ;;
    hooks) h159="would read what it writes. Remove it on the host (rm $PROJ/r159/.git/hooks)."; t159="directory" ;;
  esac
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $PROJ/r159/.git/$v159 is not a $t159; refusing the launch." "$ERR" \
    && grep -qF -- "$h159" "$ERR" \
    && pass "G159 a $v159 that is not a $t159 refuses the launch, saying what to do" \
    || fail "G159 $v159 (rc=$LAUNCH_RC; $(grep -A2 -F 'r159' "$ERR" | head -3 | tr '\n' ' '))"
  rm -rf "$PROJ/r159"
done

# ── G160: which git directories get placeholders, and which commondir refuses ─
# A git directory under .git/modules counts as a repository's own whatever it
# holds, its objects/ moved aside too, so a commondir other than ./ there
# refuses the launch.
mkdir -p "$PROJ/r160" && "${G[@]}" init -q "$PROJ/r160" && mkdir -p "$PROJ/r160/.git/modules/m/refs" \
  && printf 'ref: refs/heads/main\n' > "$PROJ/r160/.git/modules/m/HEAD" && : > "$PROJ/r160/.git/modules/m/config" \
  && printf '../..\n' > "$PROJ/r160/.git/modules/m/commondir" || { printf 'SCAFFOLD-FAILED: G160 module\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $PROJ/r160/.git/modules/m/commondir sends git to" "$ERR" \
  && pass "G160 a module's git directory with no objects/ and a commondir of its own refuses the launch" \
  || fail "G160 module commondir (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/r160"
# A linked worktree's directory whose commondir is our ./ is a repository's
# own: what it lacks is made again, and bound.
mkdir -p "$PROJ/r160" && "${G[@]}" init -q "$PROJ/r160" && mkdir -p "$PROJ/r160/.git/worktrees/w" \
  && printf 'ref: refs/heads/main\n' > "$PROJ/r160/.git/worktrees/w/HEAD" && printf './\n' > "$PROJ/r160/.git/worktrees/w/commondir" \
  || { printf 'SCAFFOLD-FAILED: G160 worktree\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 && -f "$PROJ/r160/.git/worktrees/w/config" && -d "$PROJ/r160/.git/worktrees/w/hooks" ]] \
  && has_mount "$PROJ/r160/.git/worktrees/w/config:/workspace/proj/r160/.git/worktrees/w/config:ro" \
  && pass "G160 a worktree's directory with our ./ commondir gets its config and hooks/ made and bound" \
  || fail "G160 ./ worktree (rc=$LAUNCH_RC; $(ls -A "$PROJ/r160/.git/worktrees/w" | tr '\n' ' '))"
rm -rf "$PROJ/r160"
# A .git with no config whose commondir names another repository's git
# directory was read as a linked worktree's, which let the agent choose the
# config git reads (bugs review GIT-64's review): nothing makes that layout, and
# it refuses the launch, as one beside a config does (G165).
mkdir -p "$PROJ/c160" "$PROJ/r160" && "${G[@]}" init -q "$PROJ/c160" && mkdir -p "$PROJ/r160/.git/refs" \
  && printf 'ref: refs/heads/main\n' > "$PROJ/r160/.git/HEAD" && printf '%s\n' "$PROJ/c160/.git" > "$PROJ/r160/.git/commondir" \
  || { printf 'SCAFFOLD-FAILED: G160 common\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $PROJ/r160/.git/commondir sends git to" "$ERR" \
  && pass "G160 a .git with no config and a commondir naming a repository refuses the launch" \
  || fail "G160 foreign commondir (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/c160" "$PROJ/r160"

# ── G165: a commondir git does not write (GIT-64) ───────────────────────────
# git takes the configuration and hooks of the directory a commondir leads to.
# With no config, one leading back to its own git directory had nothing made or
# bound there, and one naming another directory let the agent choose the config
# git reads: one with a commondir of its own, one made a repository later, one
# reached through a link it repoints (bugs review GIT-64 and its review). git
# writes a commondir only in a linked worktree's directory, as ../.. (libgit2:
# that directory's full path), so any other refuses the launch, in any git
# directory, a config beside it or not.
refused16x() {  # <check> <commondir> <what the ERROR says of it>: the launch was refused for it
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $2 $3" "$ERR"; then pass "$1"
  else fail "$1 (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"; fi
}
mk165() {  # a .git with no config and no hooks/, its commondir reading $1
  rm -rf "$PROJ/r165"; mkdir -p "$PROJ/r165" && "${G[@]}" init -q "$PROJ/r165" \
    && rm -rf "$PROJ/r165/.git/config" "$PROJ/r165/.git/hooks" \
    && printf '%s\n' "$1" > "$PROJ/r165/.git/commondir" || { printf 'SCAFFOLD-FAILED: G165\n'; exit 1; }
}
for v165 in . ./. .// ../.git "$PROJ/r165/.git" ''; do
  mk165 "$v165"; launch ..
  refused16x "G165 a .git with no config whose commondir reads '$v165' refuses the launch" "$PROJ/r165/.git/commondir" "sends git to"
done
mk165 .; mv "$PROJ/r165/.git/objects" "$PROJ/r165/.git/objects.165" || { printf 'SCAFFOLD-FAILED: G165 objects\n'; exit 1; }
launch ..
refused16x "G165 … with its objects/ moved aside too" "$PROJ/r165/.git/commondir" "sends git to"
# A linked worktree's directory, which needs no objects/, and a separate git
# directory not named .git, with objects/ moved aside, the same.
rm -rf "$PROJ/r165"; mkdir -p "$PROJ/r165" && "${G[@]}" init -q "$PROJ/r165" && mkdir -p "$PROJ/r165/.git/worktrees/w" \
  && printf 'ref: refs/heads/main\n' > "$PROJ/r165/.git/worktrees/w/HEAD" && printf '.\n' > "$PROJ/r165/.git/worktrees/w/commondir" \
  || { printf 'SCAFFOLD-FAILED: G165 worktree\n'; exit 1; }
launch ..
refused16x "G165 a linked worktree's directory whose commondir reads '.' refuses the launch" \
  "$PROJ/r165/.git/worktrees/w/commondir" "sends git to"
rm -rf "$PROJ/r165"; mkdir -p "$PROJ/r165" && "${G[@]}" init -q --separate-git-dir="$PROJ/r165/gd" "$PROJ/r165/co" \
  && rm -rf "$PROJ/r165/gd/config" "$PROJ/r165/gd/hooks" && mv "$PROJ/r165/gd/objects" "$PROJ/r165/gd/objects.165" \
  && printf '.\n' > "$PROJ/r165/gd/commondir" || { printf 'SCAFFOLD-FAILED: G165 separate\n'; exit 1; }
launch ..
refused16x "G165 a separate git directory whose commondir leads back to it refuses the launch" "$PROJ/r165/gd/commondir" "sends git to"
# Naming another repository's git directory, with no config: refused too, as
# nothing makes that layout (it was read as a linked worktree's, G160), and
# whatever it names. One that has a commondir of its own, which git does not
# follow, so its config is the one read; a directory that is no repository yet,
# which the agent can make one; and one reached past a link that `..` cancels,
# which the agent can repoint later.
mkdir -p "$PROJ/c165" && "${G[@]}" init -q "$PROJ/c165" || { printf 'SCAFFOLD-FAILED: G165 c165\n'; exit 1; }
mk165 "$PROJ/c165/.git"; launch ..
refused16x "G165 a .git with no config whose commondir names another repository refuses the launch" "$PROJ/r165/.git/commondir" "sends git to"
mk165 ../b165/.git; mkdir -p "$PROJ/r165/b165" && "${G[@]}" init -q "$PROJ/r165/b165" \
  && rm -rf "$PROJ/r165/b165/.git/config" "$PROJ/r165/b165/.git/hooks" && printf '%s\n' "$PROJ/c165/.git" > "$PROJ/r165/b165/.git/commondir" \
  || { printf 'SCAFFOLD-FAILED: G165 chain\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "ERROR: $PROJ/r165/" "$ERR" && grep -qF '/.git/commondir sends git to' "$ERR" \
  && pass "G165 a chain of commondirs with no config refuses the launch" \
  || fail "G165 a chain of commondirs (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
mk165 ../x165; mkdir -p "$PROJ/r165/x165" || { printf 'SCAFFOLD-FAILED: G165 empty\n'; exit 1; }
launch ..
refused16x "G165 a .git with no config whose commondir names a directory that is no repository yet refuses the launch" \
  "$PROJ/r165/.git/commondir" "sends git to"
mk165 ../l165/../../c165/.git; mkdir -p "$PROJ/r165/sub165" && ln -s "$PROJ/r165/sub165" "$PROJ/r165/l165" \
  || { printf 'SCAFFOLD-FAILED: G165 link\n'; exit 1; }
launch ..
refused16x "G165 a .git with no config whose commondir steps past a link refuses the launch" "$PROJ/r165/.git/commondir" "sends git to"
rm -rf "$PROJ/r165" "$PROJ/c165"
# In a linked worktree's directory, only what git and libgit2 write, and only
# naming a .git or a directory that holds objects/ and refs/, which the launch
# finds and protects. A spelling git resolves apart from the kernel (HEAD/..), a
# step through a directory the agent can swap for a link, or a link `..`
# cancels, refuses the launch, and so does ../.. naming a directory that is no
# repository yet, which the agent could fill (bugs review GIT-64's second
# review).
rm -rf "$PROJ/r165"; mkdir -p "$PROJ/r165" && "${G[@]}" init -q "$PROJ/r165" && "${G[@]}" -C "$PROJ/r165" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$PROJ/r165" worktree add -q "$PROJ/r165/w" -b w165 && W165="$PROJ/r165/.git/worktrees/w" \
  && mkdir -p "$W165/sub" && ln -s "$W165" "$W165/L" || { printf 'SCAFFOLD-FAILED: G165 worktree forms\n'; exit 1; }
for v165 in HEAD/../../.. sub/../../.. L/../../.. ../../ ./../..; do
  printf '%s\n' "$v165" > "$W165/commondir"; launch ..
  refused16x "G165 a linked worktree's commondir reading '$v165' refuses the launch" "$W165/commondir" "sends git to"
done
printf '%s/\n' "$PROJ/r165/.git" > "$W165/commondir"; launch ..
# A linked worktree's directory takes hooks/ from its repository: it gets no
# placeholders, and no warning that one could not be made (GIT-48, GIT-64).
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$W165/commondir:/workspace/proj/r165/.git/worktrees/w/commondir:ro" \
  && [[ ! -e "$W165/config" && ! -e "$W165/hooks" ]] && ! grep -qF "WARNING: $W165 has no" "$ERR" \
  && pass "G165 a linked worktree's commondir naming its repository's git directory by its full path, as libgit2 writes it, is taken" \
  || fail "G165 libgit2's commondir (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
mkdir -p "$PROJ/r165/t/worktrees/T/refs" && printf 'ref: refs/heads/main\n' > "$PROJ/r165/t/worktrees/T/HEAD" \
  && printf '../..\n' > "$PROJ/r165/t/worktrees/T/commondir" || { printf 'SCAFFOLD-FAILED: G165 dormant\n'; exit 1; }
printf '../..\n' > "$W165/commondir"; launch ..
refused16x "G165 a worktree's ../.. naming a directory that is no repository refuses the launch" "$PROJ/r165/t/worktrees/T/commondir" \
  "names $PROJ/r165/t, which is no repository's own git directory"
rm -rf "$PROJ/r165/t"
# Nor one that holds objects/ and refs/ but has a commondir of its own (a
# worktree's directory nested in another's): git reads its config, which as no
# repository's own is neither made nor bound (bugs review GIT-64's third review).
V165="$PROJ/r165/.git/worktrees/wv"; mkdir -p "$V165/objects" "$V165/refs" "$V165/worktrees/w2" "$PROJ/r165/co2" \
  && printf 'ref: refs/heads/main\n' > "$V165/HEAD" && printf '../..\n' > "$V165/commondir" \
  && printf 'ref: refs/heads/main\n' > "$V165/worktrees/w2/HEAD" && printf '../..\n' > "$V165/worktrees/w2/commondir" \
  && printf '%s/co2/.git\n' "$PROJ/r165" > "$V165/worktrees/w2/gitdir" && printf 'gitdir: %s\n' "$V165/worktrees/w2" > "$PROJ/r165/co2/.git" \
  || { printf 'SCAFFOLD-FAILED: G165 nested\n'; exit 1; }
launch ..
refused16x "G165 a worktree's ../.. naming one with a commondir of its own refuses the launch" "$V165/worktrees/w2/commondir" \
  "names $V165, which is no repository's own git directory"
rm -rf "$V165" "$PROJ/r165/co2"
# Nor a .git with objects/ moved aside, which git would not take for a common
# directory either: what counts is objects/ and refs/, not the name.
X165="$PROJ/node_modules/x165"; mkdir -p "$PROJ/co3" && "${G[@]}" init -q "$X165" \
  && rm -rf "$X165/.git/config" && mv "$X165/.git/objects" "$X165/.git/objects.165" && mkdir -p "$X165/.git/worktrees/w" \
  && printf 'ref: refs/heads/main\n' > "$X165/.git/worktrees/w/HEAD" && printf '../..\n' > "$X165/.git/worktrees/w/commondir" \
  && printf '%s/co3/.git\n' "$PROJ" > "$X165/.git/worktrees/w/gitdir" && printf 'gitdir: %s\n' "$X165/.git/worktrees/w" > "$PROJ/co3/.git" \
  || { printf 'SCAFFOLD-FAILED: G165 pruned\n'; exit 1; }
launch ..
refused16x "G165 a worktree's ../.. naming a .git with no objects/ refuses the launch" "$X165/.git/worktrees/w/commondir" \
  "names $X165/.git, which is no repository's own git directory"
rm -rf "$PROJ/node_modules" "$PROJ/co3"
"${G[@]}" -C "$PROJ/r165" worktree remove --force "$PROJ/r165/w" 2>/dev/null
rm -rf "$PROJ/r165"

# ── G166: a commondir that is a link (GIT-62) ───────────────────────────────
# git reads the path through the link, which the agent can repoint in every
# session; a dangling one is no commondir to git, which then takes the
# directory itself (with objects/ and refs/ there; measured with git 2.56). In a
# repository's own git directory one left nothing made or bound, or was only
# named (bugs review GIT-62), and elsewhere it was named and read through. git
# never makes one: it refuses the launch, in any git directory.
mk166() {  # a fresh repository, with the regular file cd166 beside its .git reading $1
  rm -rf "$PROJ/r166"; mkdir -p "$PROJ/r166" && "${G[@]}" init -q "$PROJ/r166" \
    && printf '%s\n' "$1" > "$PROJ/r166/cd166" || { printf 'SCAFFOLD-FAILED: G166\n'; exit 1; }
}
mk166 ./; rm -rf "$PROJ/r166/.git/config" "$PROJ/r166/.git/hooks" "$PROJ/r166/.git/objects" \
  && ln -s /nonexistent166 "$PROJ/r166/.git/commondir" || { printf 'SCAFFOLD-FAILED: G166 dangling\n'; exit 1; }
launch ..
refused16x "G166 a .git with no config whose commondir is a dangling link refuses the launch" "$PROJ/r166/.git/commondir" "is a symlink"
mk166 ./; ln -s ../cd166 "$PROJ/r166/.git/commondir" || { printf 'SCAFFOLD-FAILED: G166 config\n'; exit 1; }
launch ..
refused16x "G166 a .git with a config whose commondir is a link to our ./ refuses the launch" "$PROJ/r166/.git/commondir" "is a symlink"
mk166 ../..; mkdir -p "$PROJ/r166/.git/modules/m/refs" && printf 'ref: refs/heads/main\n' > "$PROJ/r166/.git/modules/m/HEAD" \
  && ln -s ../../../cd166 "$PROJ/r166/.git/modules/m/commondir" || { printf 'SCAFFOLD-FAILED: G166 module\n'; exit 1; }
launch ..
refused16x "G166 a module's git directory whose commondir is a link refuses the launch" "$PROJ/r166/.git/modules/m/commondir" "is a symlink"
# A linked worktree's directory: one leading back to it, one dangling (objects/
# and refs/ there, so git takes the directory itself), and one leading to the
# repository's own, as git writes it but through a link (G144 found it).
for k166 in ./ dangling ../..; do
  mk166 "$k166"; mkdir -p "$PROJ/r166/.git/worktrees/w" && printf 'ref: refs/heads/main\n' > "$PROJ/r166/.git/worktrees/w/HEAD" \
    || { printf 'SCAFFOLD-FAILED: G166 worktree\n'; exit 1; }
  if [[ "$k166" == dangling ]]; then
    mkdir -p "$PROJ/r166/.git/worktrees/w/objects" "$PROJ/r166/.git/worktrees/w/refs" \
      && ln -s /nonexistent166 "$PROJ/r166/.git/worktrees/w/commondir" || { printf 'SCAFFOLD-FAILED: G166 dangling worktree\n'; exit 1; }
  else
    ln -s ../../../cd166 "$PROJ/r166/.git/worktrees/w/commondir" || { printf 'SCAFFOLD-FAILED: G166 linked worktree\n'; exit 1; }
  fi
  launch ..
  refused16x "G166 a linked worktree's directory whose commondir is a link ($k166) refuses the launch" \
    "$PROJ/r166/.git/worktrees/w/commondir" "is a symlink"
done
rm -rf "$PROJ/r166"

# ── G172: a worktree's ../.. naming a repository whose own commondir is wrong ─
# A mount rooted at a repository's worktrees/ directory, the repository outside
# every mount: its linked worktree's ../.. is git's own, and what is wrong is the
# repository's own commondir, a link here. The refusal names that file as what
# is wrong, to be removed, not git's ../.. (review of GIT-68's fix; what it
# says to do is tests/test-git-internals-ro-wayout.sh's, G184).
R172="$TMP/r172"; mkdir -p "$R172" && "${G[@]}" init -q "$R172" && "${G[@]}" -C "$R172" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$R172" worktree add -q "$TMP/wt172" -b wt172 && printf './\n' > "$TMP/dot172" \
  && ln -s "$TMP/dot172" "$R172/.git/commondir" || { printf 'SCAFFOLD-FAILED: G172\n'; exit 1; }
EXTRA_MOUNTS="$R172/.git/worktrees" launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $R172/.git/worktrees/wt172/commondir names $R172/.git, which is no repository's own git directory" "$ERR" \
  && grep -qF "$R172/.git/commondir is what is wrong." "$ERR" && grep -qF "(cd -P -- $R172/.git && " "$ERR" \
  && ! grep -qF "(cd -P -- $R172/.git/worktrees/wt172 " "$ERR" && ! grep -qE '\(rm [^)]*\)' "$ERR" \
  && pass "G172 a worktree whose repository's own commondir is wrong: the refusal names that commondir" \
  || fail "G172 the grandparent's commondir (rc=$LAUNCH_RC; $(grep -A4 -m1 ERROR "$ERR" | tr '\n' ' '))"
rm -rf "$R172" "$TMP/wt172" "$TMP/dot172"
# …and where that repository is a real linked worktree's directory in a writable
# mount, its ../.. git's own, the planted worktree inside it is what is named,
# to be moved out: removing git's ../.. handed the host's git the agent's
# config there (final review of GIT-68's fix; GIT-70).
A172="$PROJ/.git/worktrees/wta172"; W172="$A172/worktrees/w"
"${G[@]}" -C "$PROJ" worktree add -q "$TMP/wta172" -b wta172 && mkdir -p "$A172/objects" "$A172/refs" "$W172" \
  && printf 'ref: refs/heads/main\n' > "$W172/HEAD" && printf '../..\n' > "$W172/commondir" \
  || { printf 'SCAFFOLD-FAILED: G172 nested\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] \
  && grep -qF "ERROR: $W172/commondir names $A172, which is no repository's own git directory" "$ERR" \
  && grep -qF "Move $W172 (mv) to a directory you never mount." "$ERR" && ! grep -qw rm "$ERR" \
  && pass "G172 a worktree planted in a real linked worktree's directory: the refusal names the planted commondir" \
  || fail "G172 nested in a real worktree (rc=$LAUNCH_RC; $(grep -A4 -m1 ERROR "$ERR" | tr '\n' ' '))"
rm -rf "$W172" "$A172/worktrees" "$A172/objects"
"${G[@]}" -C "$PROJ" worktree remove --force "$TMP/wta172" 2>/dev/null || { rm -rf "$TMP/wta172"; "${G[@]}" -C "$PROJ" worktree prune; }
"${G[@]}" -C "$PROJ" branch -q -D wta172 2>/dev/null
[[ ! -e "$A172" ]] || { rm -rf "$A172"; "${G[@]}" -C "$PROJ" worktree prune; }

# ── G161: under a launcher's read-only overlay, a second name still counts ───
# A repository inside a launcher another mount exposes gets no binds of its
# own, but a .git file, or a hook, with a second hard link in a writable mount
# refuses the launch, as anywhere else.
for v161 in gitfile hook; do
  H161="$TMP/h161"; mkdir -p "$H161/p/.ai-containers/sub" && : > "$H161/p/.ai-containers/sandbox.sh" \
    && : > "$H161/p/.ai-containers/sandbox-common.sh" || { printf 'SCAFFOLD-FAILED: G161\n'; exit 1; }
  if [[ "$v161" == gitfile ]]; then
    mkdir -p "$H161/gd" && "${G[@]}" init -q --bare "$H161/gd" && printf 'gitdir: %s\n' "$H161/gd" > "$H161/p/.ai-containers/sub/.git"
    n161="$H161/p/.ai-containers/sub/.git"
  else
    "${G[@]}" init -q "$H161/p/.ai-containers/sub" && printf '#!/bin/sh\n' > "$H161/p/.ai-containers/sub/.git/hooks/pre-commit"
    chmod +x "$H161/p/.ai-containers/sub/.git/hooks/pre-commit"; n161="$H161/p/.ai-containers/sub/.git/hooks/pre-commit"
  fi
  ln "$n161" "$H161/second" || { printf 'SCAFFOLD-FAILED: G161 link\n'; exit 1; }
  EXTRA_MOUNTS="$H161" launch "$TMP/app"
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF -- "-xdev -samefile $n161" "$ERR" \
    && pass "G161 a hard-linked $v161 in a repository under a launcher's overlay refuses the launch" \
    || fail "G161 $v161 (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  rm -rf "$H161"
done

# ── G163: a group directory that links out of the group ─────────────────────
# Left by an older copy, or made by hand: the launch warns and mounts where it
# leads, and that is a directory of the host's like any other, so the git
# directories in it are protected in the group's view. Only the group's own
# directory is left unscanned.
X163="$TMP/x163"; mkdir -p "$X163" && "${G[@]}" init -q "$X163/r" && gs163="$HOME/.ai-containers/default/.ssh" \
  && mkdir -p "$gs163" && mv "$gs163" "$TMP/ssh163" && ln -s "$X163" "$gs163" || { printf 'SCAFFOLD-FAILED: G163\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: $gs163 is a link out of the group" "$ERR" \
  && has_mount "$X163/r/.git/config:/home/tester/.ssh/r/.git/config:ro" \
  && has_mount "$X163/r/.git/hooks:/home/tester/.ssh/r/.git/hooks:ro" \
  && pass "G163 a repository in a group directory that links out of the group is protected there" \
  || fail "G163 group link out (rc=$LAUNCH_RC; $(git_mounts | grep -F x163 | tr '\n' ' '))"
rm -f "$gs163"; mv "$TMP/ssh163" "$gs163"; rm -rf "$X163"

# ── G173: a git directory whose objects or refs is a file (GIT-69) ───────────
# git takes a directory for a git directory when it can reach objects and refs
# (access X_OK), whatever they are: an executable file passes, and a reftable
# repository keeps working with refs one. The launcher wanted directories, so a
# bare repository planted in a writable mount, or a separate git directory, so
# made was none to it: nothing bound, nothing named, and the host's git ran the
# config the agent wrote there (bugs review GIT-69).
mk173() {  # <dir> <objects|refs, the one made an executable file>
  mkdir -p "$1" && printf 'ref: refs/heads/main\n' > "$1/HEAD" && printf '[core]\n\tbare = true\n' > "$1/config" \
    && if [[ "$2" == objects ]]; then mkdir -p "$1/refs" && : > "$1/objects" && chmod +x "$1/objects"
       else mkdir -p "$1/objects" && : > "$1/refs" && chmod +x "$1/refs"; fi
}
for k173 in objects refs; do
  mk173 "$PROJ/b173" "$k173" && [[ "$("${G[@]}" -C "$PROJ/b173" rev-parse --absolute-git-dir 2>/dev/null)" == "$PROJ/b173" ]] \
    || { printf 'SCAFFOLD-FAILED: G173 bare (%s)\n' "$k173"; exit 1; }
  launch ..
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/b173/config:/workspace/proj/b173/config:ro" \
    && [[ "$(cat "$PROJ/b173/commondir" 2>/dev/null)" == ./ ]] \
    && pass "G173 a bare repository in a writable mount with $k173 a file is protected" \
    || fail "G173 a bare repository with $k173 a file (rc=$LAUNCH_RC; $(git_mounts | grep -c b173) binds; $(grep -m1 -E 'ERROR|b173' "$ERR"))"
  rm -rf "$PROJ/b173"
done
# More than git: objects a dangling link and refs a file that is not
# executable, which git passes over, count too, since the agent can make either
# what git takes later (review of the fix).
mkdir -p "$PROJ/b173" && printf 'ref: refs/heads/main\n' > "$PROJ/b173/HEAD" && ln -s nowhere173 "$PROJ/b173/objects" \
  && : > "$PROJ/b173/refs" && chmod -x "$PROJ/b173/refs" || { printf 'SCAFFOLD-FAILED: G173 more than git\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/b173/config:/workspace/proj/b173/config:ro" \
  && pass "G173 one with objects a dangling link and refs a plain file is protected too" \
  || fail "G173 more than git (rc=$LAUNCH_RC; $(git_mounts | grep -c b173) binds; $(grep -m1 -E 'ERROR|b173' "$ERR"))"
rm -rf "$PROJ/b173"
# A submodule's git directory under .git/modules whose HEAD a session moved
# aside, its objects and refs files, counts as one does with directories (G78).
M173="$PROJ/.git/modules/m173"; mkdir -p "$M173" && : > "$M173/objects" && : > "$M173/refs" \
  && chmod +x "$M173/objects" "$M173/refs" || { printf 'SCAFFOLD-FAILED: G173 module\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$M173/config:/workspace/proj/.git/modules/m173/config:ro" \
  && pass "G173 a module's git directory with no HEAD, objects and refs files, is protected" \
  || fail "G173 a module's git directory with objects and refs files (rc=$LAUNCH_RC; $(git_mounts | grep -c m173) binds)"
rm -rf "$M173"
# A separate git directory so made, named by a checkout's .git file.
mkdir -p "$PROJ/co173" && mk173 "$PROJ/gd173" objects && printf 'gitdir: %s\n' "$PROJ/gd173" > "$PROJ/co173/.git" \
  && [[ "$("${G[@]}" -C "$PROJ/co173" rev-parse --absolute-git-dir 2>/dev/null)" == "$PROJ/gd173" ]] \
  || { printf 'SCAFFOLD-FAILED: G173 separate\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$PROJ/gd173/config:/workspace/proj/gd173/config:ro" \
  && ! grep -qF "names $PROJ/gd173, which is not a git directory" "$ERR" \
  && pass "G173 a separate git directory with objects a file is protected" \
  || fail "G173 a separate git directory with objects a file (rc=$LAUNCH_RC; $(grep -m1 -F gd173 "$ERR"))"
rm -rf "$PROJ/co173" "$PROJ/gd173"
# Made during a session, it is named after it.
FAKE_SESSION="mkdir -p '$PROJ/s173/refs' && printf 'ref: refs/heads/main\n' > '$PROJ/s173/HEAD' && : > '$PROJ/s173/objects' && chmod +x '$PROJ/s173/objects' && git config --file '$PROJ/s173/config' core.fsmonitor ./fsm" \
  launch ..
grep -qF "$PROJ/s173 (config: core.fsmonitor" < <(grep -A3 -F 'WARNING: the session made git repositories in a writable mount' "$ERR") \
  && pass "G173 one the session makes with objects a file is named after it" \
  || fail "G173 made during the session ($(grep -A3 -F 'the session made' "$ERR" | tr '\n' ' '))"
rm -rf "$PROJ/s173"

# ── G187: no placeholder where git would then ignore core.worktree ───────────
# git takes a git directory with a commondir for a linked worktree's, and reads
# core.worktree for one only from config.worktree: a ./ placeholder made git
# take the current directory for the work tree of one whose config sets it
# (a "dotfiles" repository used with --git-dir). There none is made; its config
# and hooks are still read-only; a commondir the session makes there is named
# after it; one an earlier launch made is named, with the rm that removes it. A
# submodule's git directory, which git reaches through the .git file in its
# checkout, keeps the placeholder (bugs review GIT-73).
D187="$TMP/d187"; mkdir -p "$D187/wt" "$D187/elsewhere" && "${G[@]}" init -q --bare "$D187/dot.git" \
  && "${G[@]}" --git-dir="$D187/dot.git" config core.bare false \
  && "${G[@]}" --git-dir="$D187/dot.git" config core.worktree "$D187/wt" && printf 'x\n' > "$D187/wt/f177" \
  || { printf 'SCAFFOLD-FAILED: G187\n'; exit 1; }
EXTRA_MOUNTS="$D187" launch "$TMP/app"
m187="$(mounts)"
[[ "$LAUNCH_RC" == 0 && ! -e "$D187/dot.git/commondir" ]] \
  && grep -qxF -- "$D187/dot.git/config:/workspace/d187/dot.git/config:ro" <<<"$m187" \
  && grep -qxF -- "$D187/dot.git/hooks:/workspace/d187/dot.git/hooks:ro" <<<"$m187" \
  && grep -qF "NOTE: /workspace/d187/dot.git sets core.worktree in its config" "$ERR" \
  && ! grep -qF "has no commondir and one could not be made" "$ERR" \
  && pass "G187 a git directory whose config sets core.worktree gets no placeholder, and is protected" \
  || fail "G187 core.worktree (rc=$LAUNCH_RC; commondir: $(cat "$D187/dot.git/commondir" 2>&1); $(grep -F 'dot.git' "$ERR" | head -3 | tr '\n' ' '))"
[[ "$(cd "$D187/elsewhere" && "${G[@]}" --git-dir="$D187/dot.git" rev-parse --show-toplevel 2>/dev/null)" == "$D187/wt" ]] \
  && pass "G187 git still takes its core.worktree after the launch" \
  || fail "G187 git's work tree ($(cd "$D187/elsewhere" && "${G[@]}" --git-dir="$D187/dot.git" rev-parse --show-toplevel 2>&1))"
FAKE_SESSION="printf '%s\n' '$D187/elsewhere' > '$D187/dot.git/commondir'" EXTRA_MOUNTS="$D187" launch "$TMP/app"
grep -qF "$D187/dot.git/commondir" < <(grep -A3 -F 'WARNING: the session made .git files or links in a writable mount' "$ERR") \
  && pass "G187 a commondir the session makes there is named after it" \
  || fail "G187 commondir made in the session ($(grep -A3 -F 'WARNING: the session' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$D187" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $D187/dot.git/commondir sends git to" "$ERR" \
  && pass "G187 and refuses the next launch" \
  || fail "G187 next launch (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
printf './\n' > "$D187/dot.git/commondir"
EXTRA_MOUNTS="$D187" launch "$TMP/app"
w187="$(grep -A5 -F "WARNING: $D187/dot.git/commondir" "$ERR")"
c187="$(grep -F '&& rm commondir)' <<<"$w187" | sed 's/^ *//')"
[[ "$LAUNCH_RC" == 0 && "$c187" == "(cd -P -- $D187/dot.git "* ]] && ( cd "$D187/elsewhere" && bash -c "$c187" ) \
  && [[ ! -e "$D187/dot.git/commondir" ]] \
  && pass "G187 a placeholder an earlier launch made there is named, with the command that removes it" \
  || fail "G187 earlier placeholder (rc=$LAUNCH_RC; $(tr '\n' ' ' <<<"$w187"))"
# The command removes nothing but our ./.
printf '%s\n' "$D187/elsewhere" > "$D187/dot.git/commondir"
( cd "$D187/elsewhere" && bash -c "$c187" ) 2>/dev/null
[[ -f "$D187/dot.git/commondir" ]] && pass "G187 …and removes no commondir but ./" \
  || fail "G187 the command removed another commondir"
# Nor does it wait at one that has become a FIFO: it read the file first, and
# hung there until killed (bugs review GIT-83).
rm -f "$D187/dot.git/commondir"; mkfifo "$D187/dot.git/commondir"
( cd "$D187/elsewhere" && p_timeout 10 bash -c "$c187" ) 2>/dev/null; r187=$?
[[ -n "$c187" && "$r187" != 124 && -p "$D187/dot.git/commondir" ]] \
  && pass "G187 …and returns at once, removing nothing, where the commondir has become a FIFO" \
  || fail "G187 a FIFO commondir (exit $r187; $(ls -l "$D187/dot.git/commondir" 2>&1 | cut -c1-10))"
# Lets go a reader the command left waiting, where it still reads first.
( exec 3<>"$D187/dot.git/commondir" ) 2>/dev/null
rm -f "$D187/dot.git/commondir"
"${G[@]}" init -q "$D187/up" && "${G[@]}" -C "$D187/up" commit -q --allow-empty -m i && "${G[@]}" init -q "$D187/sup" \
  && "${G[@]}" -C "$D187/sup" -c protocol.file.allow=always submodule add -q "$D187/up" s 2>/dev/null \
  && [[ -n "$("${G[@]}" --git-dir="$D187/sup/.git/modules/s" config core.worktree)" ]] \
  || { printf 'SCAFFOLD-FAILED: G187 submodule\n'; exit 1; }
EXTRA_MOUNTS="$D187" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(cat "$D187/sup/.git/modules/s/commondir" 2>/dev/null)" == ./ ]] \
  && pass "G187 a submodule's git directory keeps the placeholder" \
  || fail "G187 submodule (rc=$LAUNCH_RC; commondir: $(cat "$D187/sup/.git/modules/s/commondir" 2>&1))"
rm -rf "$D187"

# ── G188: every directory under a git directory's worktrees/ is checked ───────
# A linked worktree's directory holds no objects or refs: what made it a git
# directory to the scan was a regular commondir, or inside a .git a regular
# gitdir. With the commondir a dangling link or a FIFO (and the gitdir gone) the
# launch never asked _git_cd_check, bound nothing and said nothing; the session
# then made the link's target, and the host's git in the checkout ran the
# agent's config. So every directory there is taken, whatever it holds (bugs
# review GIT-78).
D188="$TMP/d188"; O188="$TMP/out188"; mkdir -p "$D188" "$O188" \
  && "${G[@]}" init -q --bare "$D188/b.git" && "${G[@]}" -C "$PROJ" push -q "$D188/b.git" HEAD:refs/heads/main 2>/dev/null \
  && "${G[@]}" --git-dir="$D188/b.git" worktree add -q "$O188/co" main 2>/dev/null \
  && "${G[@]}" init -q "$D188/r" && "${G[@]}" -C "$D188/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$D188/r" worktree add -q "$O188/rco" -b wb 2>/dev/null \
  || { printf 'SCAFFOLD-FAILED: G188\n'; exit 1; }
wb188="$D188/b.git/worktrees/co"; wr188="$D188/r/.git/worktrees/rco"
EXTRA_MOUNTS="$D188" launch "$TMP/app"
m188="$(mounts | grep -F '/worktrees/' | LC_ALL=C sort)"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$wb188/commondir:/workspace/d188/b.git/worktrees/co/commondir:ro" \
  && has_mount "$wr188/commondir:/workspace/d188/r/.git/worktrees/rco/commondir:ro" \
  && pass "G188 control: a bare repository's and a checkout's linked worktree are protected" \
  || fail "G188 control (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); $(tr '\n' ' ' <<<"$m188"))"
# A second launch changes nothing of what a real worktree gets.
EXTRA_MOUNTS="$D188" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(mounts | grep -F '/worktrees/' | LC_ALL=C sort)" == "$m188" && "$(wc -l <<<"$m188" | tr -d ' ')" == 6 ]] \
  && pass "G188 …and get the same six mounts at every launch" \
  || fail "G188 mounts changed (rc=$LAUNCH_RC; $(wc -l <<<"$m188") before; now: $(mounts | grep -F '/worktrees/' | LC_ALL=C sort | tr '\n' ' '))"
# The bare repository's: its commondir replaced by a dangling link, then a FIFO.
rm -f "$wb188/commondir" && ln -s ../../../cdfile "$wb188/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $wb188/commondir is a symlink" "$ERR" \
  && pass "G188 a bare repository's worktree with a dangling link for its commondir refuses the launch" \
  || fail "G188 bare, dangling link (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$wb188/commondir" && mkfifo "$wb188/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $wb188/commondir is not a regular file" "$ERR" \
  && pass "G188 …and so does a FIFO there" \
  || fail "G188 bare, FIFO (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$wb188/commondir" && printf '../..\n' > "$wb188/commondir"
# The checkout's: with its gitdir removed as well, nothing else made it one.
rm -f "$wr188/commondir" "$wr188/gitdir" && ln -s ../../../cdfile "$wr188/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $wr188/commondir is a symlink" "$ERR" \
  && pass "G188 a checkout's worktree with no gitdir and a dangling link for its commondir refuses the launch" \
  || fail "G188 checkout, dangling link (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$wr188/commondir" && mkfifo "$wr188/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $wr188/commondir is not a regular file" "$ERR" \
  && pass "G188 …and so does a FIFO there" \
  || fail "G188 checkout, FIFO (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
# With nothing else in the directory at all.
rm -f "$wr188/commondir"; find "$wr188" -mindepth 1 -delete; ln -s /nonexistent/cd "$wr188/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $wr188/commondir is a symlink" "$ERR" \
  && pass "G188 …and a directory that holds nothing but that link" \
  || fail "G188 checkout, only the link (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$wr188/commondir"
# A link in worktrees/, which git follows to the worktree's directory.
mkdir -p "$D188/ev" && ln -s /nonexistent/cd "$D188/ev/commondir" && ln -s "$D188/ev" "$D188/b.git/worktrees/lw"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $D188/b.git/worktrees/lw is a symlink" "$ERR" \
  && ! grep -qE '^ +\(cd -P|rm ' "$ERR" \
  && pass "G188 a link in worktrees/ refuses the launch, and no command is printed" \
  || fail "G188 link in worktrees/ (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$D188/b.git/worktrees/lw" "$D188/ev"
# What is neither a directory nor a link there is passed over.
printf 'x\n' > "$D188/b.git/worktrees/afile"
EXTRA_MOUNTS="$D188" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "worktrees/afile" < <(mounts) \
  && pass "G188 a plain file in worktrees/ is passed over" \
  || fail "G188 plain file in worktrees/ (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$D188/b.git/worktrees/afile"
# Where git does not run: the directories are listed before anything git reads.
ng188=""; i188=0
IFS=: read -r -a pd188 <<<"$PATH"
for d188 in "${pd188[@]}"; do
  if [[ -n "$d188" && -x "$d188/git" && ! -d "$d188/git" ]]; then
    i188=$((i188 + 1)); n188="$TMP/nogit188/$i188"; mkdir -p "$n188"
    ln -s "$d188"/* "$n188"/ 2>/dev/null; rm -f "$n188/git"
    d188="$n188"
  fi
  ng188="${ng188:+$ng188:}$d188"
done
PATH="$ng188" "$BASH" -c 'command -v git' >/dev/null 2>&1 \
  && { printf 'SCAFFOLD-FAILED: G188 git is still on the no-git PATH\n'; exit 1; }
mkdir -p "$D188/b.git/worktrees/ng" && ln -s /nonexistent/cd "$D188/b.git/worktrees/ng/commondir"
PATH="$ng188" EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $D188/b.git/worktrees/ng/commondir is a symlink" "$ERR" \
  && pass "G188 …where git does not run, too" \
  || fail "G188 without git (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$D188/b.git/worktrees/ng" "$TMP/nogit188"
# A repository's own git directory that is none to the scan (its objects/ and
# HEAD moved aside before any launch protected it): the worktree's directory,
# with its HEAD, is taken by a commondir of any kind.
H188="$TMP/h188"; mkdir -p "$H188" && "${G[@]}" init -q --bare "$H188/b.git" \
  && "${G[@]}" -C "$PROJ" push -q "$H188/b.git" HEAD:refs/heads/main 2>/dev/null \
  && "${G[@]}" --git-dir="$H188/b.git" worktree add -q "$O188/hco" main 2>/dev/null \
  && mv "$H188/b.git/objects" "$H188/b.git/o" && mv "$H188/b.git/HEAD" "$H188/b.git/H" \
  && rm -f "$H188/b.git/worktrees/hco/commondir" && ln -s /nonexistent/cd "$H188/b.git/worktrees/hco/commondir" \
  || { printf 'SCAFFOLD-FAILED: G188 hidden\n'; exit 1; }
EXTRA_MOUNTS="$H188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $H188/b.git/worktrees/hco/commondir is a symlink" "$ERR" \
  && pass "G188 a worktree's directory with a HEAD and a dangling commondir link is taken where its repository is not" \
  || fail "G188 hidden repository (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$H188/b.git/worktrees/hco/commondir" && mkfifo "$H188/b.git/worktrees/hco/commondir"
EXTRA_MOUNTS="$H188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $H188/b.git/worktrees/hco/commondir is not a regular file" "$ERR" \
  && pass "G188 …and with a FIFO for its commondir" \
  || fail "G188 hidden repository, FIFO (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$H188"

# ── G189: one with no commondir gets the placeholder, so none can be made ─────
# An empty directory there, and one with a HEAD and a config that sets
# core.worktree: GIT-73's rule (no placeholder beside such a config) is not for
# these, or a planted config would leave the commondir for the session to make.
mkdir -p "$D188/b.git/worktrees/junk" && printf 'ref: refs/heads/main\n' > "$wr188/HEAD" \
  && printf '[core]\n\tworktree = /nonexistent\n' > "$wr188/config"
EXTRA_MOUNTS="$D188" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(cat "$D188/b.git/worktrees/junk/commondir" 2>/dev/null)" == ./ ]] \
  && has_mount "$D188/b.git/worktrees/junk/commondir:/workspace/d188/b.git/worktrees/junk/commondir:ro" \
  && has_mount "$D188/b.git/worktrees/junk/config:/workspace/d188/b.git/worktrees/junk/config:ro" \
  && has_mount "$D188/b.git/worktrees/junk/hooks:/workspace/d188/b.git/worktrees/junk/hooks:ro" \
  && pass "G189 an empty directory under worktrees/ gets commondir, config and hooks, read-only" \
  || fail "G189 empty directory (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); $(mounts | grep -F /junk/ | tr '\n' ' '))"
[[ "$LAUNCH_RC" == 0 && "$(cat "$wr188/commondir" 2>/dev/null)" == ./ ]] \
  && has_mount "$wr188/commondir:/workspace/d188/r/.git/worktrees/rco/commondir:ro" \
  && ! grep -qF "worktrees/rco sets core.worktree in its config" "$ERR" \
  && pass "G189 one whose config sets core.worktree gets the placeholder all the same" \
  || fail "G189 core.worktree (rc=$LAUNCH_RC; commondir: $(cat "$wr188/commondir" 2>&1); $(grep -F rco "$ERR" | head -2 | tr '\n' ' '))"
# One the scan took before, by its gitdir, is held to the same.
mkdir -p "$D188/r/.git/worktrees/wc" && printf '%s\n' "$O188/gone/.git" > "$D188/r/.git/worktrees/wc/gitdir" \
  && printf '[core]\n\tworktree = /nonexistent\n' > "$D188/r/.git/worktrees/wc/config"
EXTRA_MOUNTS="$D188" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(cat "$D188/r/.git/worktrees/wc/commondir" 2>/dev/null)" == ./ ]] \
  && has_mount "$D188/r/.git/worktrees/wc/commondir:/workspace/d188/r/.git/worktrees/wc/commondir:ro" \
  && pass "G189 …and so does one with a gitdir, which the scan took before" \
  || fail "G189 core.worktree beside a gitdir (rc=$LAUNCH_RC; commondir: $(cat "$D188/r/.git/worktrees/wc/commondir" 2>&1); $(grep -F /wc "$ERR" | head -2 | tr '\n' ' '))"
"${G[@]}" --git-dir="$D188/b.git" worktree list >/dev/null 2>&1 && "${G[@]}" -C "$D188/r" status >/dev/null 2>&1 \
  && [[ "$(cd "$O188/co" && "${G[@]}" rev-parse --git-common-dir 2>/dev/null)" == "$D188/b.git" ]] \
  && pass "G189 git on the host still works in both repositories and in the real worktree" \
  || fail "G189 host git after the placeholders"
# They count toward SANDBOX_GIT_MAX, as any git directory the agent plants does.
mkdir -p "$D188/b.git/worktrees"/{p1,p2,p3,p4,p5}
SANDBOX_GIT_MAX=7 EXTRA_MOUNTS="$D188" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "more than 7 git directories" "$ERR" && grep -qF "$D188/b.git/worktrees/p" "$ERR" \
  && pass "G189 directories planted under worktrees/ count toward SANDBOX_GIT_MAX, and are named" \
  || fail "G189 SANDBOX_GIT_MAX (rc=$LAUNCH_RC; $(grep -F -A4 ERROR "$ERR" | tr '\n' ' '))"
rmdir "$D188/b.git/worktrees"/{p1,p2,p3,p4,p5}

# ── G190: worktrees/ itself: a link refuses, one you cannot list is bound whole ─
# The checks for one you cannot list held before this fix as well, the
# launcher's and the git scan's own binding those: two pin the mount and its
# WARNING, two that it is bound once. G191's, under a pruned directory, are
# the ones the fix made pass.
mv "$D188/r/.git/worktrees" "$D188/r/.git/wtreal" && ln -s wtreal "$D188/r/.git/worktrees" \
  && rm -f "$D188/r/.git/wtreal/rco/commondir" && ln -s /nonexistent/cd "$D188/r/.git/wtreal/rco/commondir"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $D188/r/.git/worktrees is a symlink" "$ERR" \
  && pass "G190 a worktrees that is a link refuses the launch" \
  || fail "G190 worktrees link (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$D188/r/.git/worktrees" && ln -s /nonexistent/wt "$D188/r/.git/worktrees"
EXTRA_MOUNTS="$D188" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $D188/r/.git/worktrees is a symlink" "$ERR" \
  && ! grep -qE '^ +\(cd -P|rm ' "$ERR" \
  && pass "G190 …a dangling one too, and no command is printed for either" \
  || fail "G190 dangling worktrees link (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); $(grep -E '^ +\(cd -P|rm ' "$ERR" | head -2))"
rm -f "$D188/r/.git/worktrees"; rm -f "$D188/r/.git/wtreal/rco/commondir"; mv "$D188/r/.git/wtreal" "$D188/r/.git/worktrees"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$D188/b.git/worktrees"
  EXTRA_MOUNTS="$D188" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$D188/b.git/worktrees:/workspace/d188/b.git/worktrees:ro" \
    && grep -qF "WARNING: $D188/b.git/worktrees cannot be listed by you" "$ERR" \
    && pass "G190 a bare repository's worktrees/ you cannot list is mounted read-only whole, and named" \
    || fail "G190 unlistable worktrees/ (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$D188/b.git/worktrees"; chmod 000 "$D188/b.git/worktrees/junk"
  EXTRA_MOUNTS="$D188" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$D188/b.git/worktrees/junk:/workspace/d188/b.git/worktrees/junk:ro" \
    && grep -qF "WARNING: $D188/b.git/worktrees/junk cannot be listed by you" "$ERR" \
    && pass "G190 …and so is a directory in it" \
    || fail "G190 unlistable directory in worktrees/ (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$D188/b.git/worktrees/junk"
  # Inside a .git the scan queues it as well: bound once.
  chmod 000 "$D188/r/.git/worktrees"
  EXTRA_MOUNTS="$D188" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 && "$(mounts | grep -cxF "$D188/r/.git/worktrees:/workspace/d188/r/.git/worktrees:ro")" == 1 ]] \
    && pass "G190 a .git's worktrees/ you cannot list is bound once" \
    || fail "G190 unlistable .git/worktrees (rc=$LAUNCH_RC; $(mounts | grep -cF "/r/.git/worktrees:") mounts; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$D188/r/.git/worktrees"
  # Seven levels down, past where the launcher scan looks for unlistable
  # directories: the git scan queues it, and so does the listing of worktrees/.
  mkdir -p "$D188/a/b/c/d" && "${G[@]}" init -q "$D188/a/b/c/d/r" && mkdir "$D188/a/b/c/d/r/.git/worktrees" \
    && chmod 000 "$D188/a/b/c/d/r/.git/worktrees"
  EXTRA_MOUNTS="$D188" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 && "$(mounts | grep -cxF "$D188/a/b/c/d/r/.git/worktrees:/workspace/d188/a/b/c/d/r/.git/worktrees:ro")" == 1 ]] \
    && pass "G190 …and so is one seven levels down" \
    || fail "G190 unlistable .git/worktrees, deep (rc=$LAUNCH_RC; $(mounts | grep -cF "/d/r/.git/worktrees:") mounts; $(grep -F ERROR "$ERR" | head -1))"
  chmod 755 "$D188/a/b/c/d/r/.git/worktrees"; rm -rf "$D188/a"
else
  pass "G190 an unlistable worktrees/ (skipped as root, who can list anything)"
  pass "G190 an unlistable directory in worktrees/ (skipped as root)"
  pass "G190 an unlistable .git/worktrees (skipped as root)"
  pass "G190 an unlistable .git/worktrees seven levels down (skipped as root)"
fi

# ── G191: a git directory only a .git file reaches, and one under an overlay ──
# A separate git directory under a pruned node_modules, in this mount and in
# another; and a repository inside a launcher, which gets no binds of its own.
D191="$TMP/d191"; E191="$TMP/e191"; mkdir -p "$D191/node_modules" "$E191/node_modules" "$D191/lz" \
  && "${G[@]}" init -q --separate-git-dir "$D191/node_modules/sep.git" "$D191/co" \
  && "${G[@]}" -C "$D191/co" commit -q --allow-empty -m i && "${G[@]}" -C "$D191/co" worktree add -q "$O188/s1" -b s1 2>/dev/null \
  && "${G[@]}" init -q --separate-git-dir "$E191/node_modules/sep.git" "$D191/co2" \
  && "${G[@]}" -C "$D191/co2" commit -q --allow-empty -m i && "${G[@]}" -C "$D191/co2" worktree add -q "$O188/s2" -b s2 2>/dev/null \
  && : > "$D191/lz/sandbox.sh" && : > "$D191/lz/sandbox-common.sh" \
  && "${G[@]}" init -q "$D191/lz/r" && "${G[@]}" -C "$D191/lz/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$D191/lz/r" worktree add -q "$O188/s3" -b s3 2>/dev/null \
  || { printf 'SCAFFOLD-FAILED: G191\n'; exit 1; }
EXTRA_MOUNTS="$D191 $E191" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && pass "G191 control: the three repositories launch" \
  || fail "G191 control (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
for w191 in "$D191/node_modules/sep.git/worktrees/s1" "$E191/node_modules/sep.git/worktrees/s2" "$D191/lz/r/.git/worktrees/s3"; do
  rm -f "$w191/commondir" "$w191/gitdir" && ln -s /nonexistent/cd "$w191/commondir"
  EXTRA_MOUNTS="$D191 $E191" launch_timed 120 "$TMP/app"
  [[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $w191/commondir is a symlink" "$ERR" \
    && pass "G191 refused: ${w191#"$TMP"/}" \
    || fail "G191 ${w191#"$TMP"/} (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
  rm -f "$w191/commondir"; printf '../..\n' > "$w191/commondir"
done
# One you cannot list, where neither scan looks (the launcher scan prunes
# node_modules too): bound read-only whole, as inside a .git.
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$D191/node_modules/sep.git/worktrees"
  EXTRA_MOUNTS="$D191 $E191" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$D191/node_modules/sep.git/worktrees:/workspace/d191/node_modules/sep.git/worktrees:ro" \
    && grep -qF "WARNING: $D191/node_modules/sep.git/worktrees cannot be listed by you" "$ERR" \
    && pass "G191 a worktrees/ you cannot list, under a pruned directory, is mounted read-only whole, and named" \
    || fail "G191 unlistable worktrees/ (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$D191/node_modules/sep.git/worktrees"
  # A directory in it, here and in the other mount's view.
  chmod 000 "$D191/node_modules/sep.git/worktrees/s1" "$E191/node_modules/sep.git/worktrees/s2"
  EXTRA_MOUNTS="$D191 $E191" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$D191/node_modules/sep.git/worktrees/s1:/workspace/d191/node_modules/sep.git/worktrees/s1:ro" \
    && has_mount "$E191/node_modules/sep.git/worktrees/s2:/workspace/e191/node_modules/sep.git/worktrees/s2:ro" \
    && grep -qF "WARNING: $E191/node_modules/sep.git/worktrees/s2 cannot be listed by you" "$ERR" \
    && pass "G191 …and so is a directory in one, in this mount and in another" \
    || fail "G191 unlistable directories in worktrees/ (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '); $(mounts | grep -F /worktrees/ | tr '\n' ' '))"
  chmod 755 "$D191/node_modules/sep.git/worktrees/s1" "$E191/node_modules/sep.git/worktrees/s2"
  chmod 000 "$E191/node_modules/sep.git/worktrees"
  EXTRA_MOUNTS="$D191 $E191" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$E191/node_modules/sep.git/worktrees:/workspace/e191/node_modules/sep.git/worktrees:ro" \
    && pass "G191 …and a worktrees/ in the other mount" \
    || fail "G191 unlistable worktrees/ in the other mount (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
  chmod 755 "$E191/node_modules/sep.git/worktrees"
else
  pass "G191 an unlistable worktrees/ under a pruned directory (skipped as root, who can list anything)"
  pass "G191 unlistable directories in worktrees/ (skipped as root)"
  pass "G191 an unlistable worktrees/ in the other mount (skipped as root)"
fi

# ── G192: one the session makes is named when the container exits ─────────────
D192="$TMP/d192"; mkdir -p "$D192" && "${G[@]}" init -q "$D192/r" && "${G[@]}" -C "$D192/r" commit -q --allow-empty -m i \
  || { printf 'SCAFFOLD-FAILED: G192\n'; exit 1; }
EXTRA_MOUNTS="$D192" launch "$TMP/app"
FAKE_SESSION="mkdir -p '$D192/r/.git/worktrees/new' && ln -s /nonexistent/cd '$D192/r/.git/worktrees/new/commondir'" EXTRA_MOUNTS="$D192" launch "$TMP/app"
grep -qF "$D192/r/.git/worktrees/new (" < <(grep -A3 -F 'WARNING: the session made git repositories' "$ERR") \
  && pass "G192 a directory the session makes under worktrees/, its commondir a link, is named after it" \
  || fail "G192 after the session ($(grep -A3 -F 'WARNING: the session' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$D192" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "ERROR: $D192/r/.git/worktrees/new/commondir is a symlink" "$ERR" \
  && pass "G192 …and refuses the next launch" \
  || fail "G192 next launch (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
chmod -R u+rwx "$D188" "$D191" "$E191" 2>/dev/null; rm -rf "$D188" "$O188" "$D191" "$E191" "$D192"

# ── G193: a file that only shares the name commondir is no git directory ──────
# A regular commondir made its directory a git directory by itself, and
# _git_cd_check then refused the launch, since git writes no such commondir: a
# branch or a tag by that name in a bare repository or a separate git
# directory, a plain file, and one in a directory above the mount each refused
# every launch. git takes no directory without a HEAD, so one with no HEAD is
# taken only when the file holds the ./ a launch writes there, which is what
# finds a repository again that a launch protected and a session then hid, or
# lies where git keeps a linked worktree's directory (bugs review GIT-79, GIT-7).
D193="$TMP/d193"; mkdir -p "$D193/notes" "$D193/up/m" \
  && "${G[@]}" init -q --bare "$D193/b.git" && "${G[@]}" -C "$PROJ" push -q "$D193/b.git" HEAD:refs/heads/commondir HEAD:refs/tags/x/commondir 2>/dev/null \
  && "${G[@]}" init -q --separate-git-dir "$D193/sep" "$D193/co" && "${G[@]}" -C "$D193/co" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$D193/co" branch fix/commondir && printf 'my notes\n' > "$D193/notes/commondir" \
  && printf 'a\0b\n' > "$D193/up/commondir" \
  && [[ -f "$D193/b.git/refs/heads/commondir" && -f "$D193/b.git/refs/tags/x/commondir" && -f "$D193/sep/refs/heads/fix/commondir" ]] \
  || { printf 'SCAFFOLD-FAILED: G193\n'; exit 1; }
EXTRA_MOUNTS="$D193/b.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'ERROR|refs/(heads|tags)' "$ERR" \
  && [[ "$("${G[@]}" --git-dir="$D193/b.git" rev-parse refs/heads/commondir 2>/dev/null)" == "$("${G[@]}" -C "$PROJ" rev-parse HEAD)" ]] \
  && [[ -z "$(find "$D193/b.git/refs" -name config -o -name hooks)" ]] \
  && pass "G193 a bare repository with a branch and a tag named commondir launches, its refs untouched" \
  || fail "G193 branch named commondir (rc=$LAUNCH_RC; $(grep -E 'ERROR|refs/' "$ERR" | head -2 | tr '\n' ' '))"
EXTRA_MOUNTS="$D193/sep $D193/co" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'ERROR|refs/heads' "$ERR" \
  && pass "G193 a separate git directory with a branch fix/commondir launches" \
  || fail "G193 separate git directory (rc=$LAUNCH_RC; $(grep -E 'ERROR|refs/' "$ERR" | head -2 | tr '\n' ' '))"
EXTRA_MOUNTS="$D193/notes" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(cat "$D193/notes/commondir")" == "my notes" ]] && ! grep -qF "$D193/notes" < <(mounts | grep -v ":/workspace/notes:") \
  && [[ "$(find "$D193/notes" -mindepth 1 | wc -l | tr -d ' ')" == 1 ]] \
  && pass "G193 a plain file named commondir launches, and nothing is made or bound beside it" \
  || fail "G193 plain file (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); $(ls -A "$D193/notes" | tr '\n' ' '))"
# Above the mount: the walk up from it asks whether each directory is a bare
# repository (GIT-72), and one holding a NUL refused every launch.
EXTRA_MOUNTS="$D193/up/m" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$D193/up" < <(grep -E 'ERROR|WARNING' "$ERR") \
  && pass "G193 a file named commondir in the directory above a mount does not refuse the launch" \
  || fail "G193 above the mount (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -1))"
# What a launch protected is still found by its ./, whatever the session hid.
"${G[@]}" init -q --bare "$D193/p.git" && "${G[@]}" -C "$PROJ" push -q "$D193/p.git" HEAD:refs/heads/main 2>/dev/null
EXTRA_MOUNTS="$D193/p.git" launch "$TMP/app"
mv "$D193/p.git/HEAD" "$D193/p.git/H" && mv "$D193/p.git/objects" "$D193/p.git/o"
EXTRA_MOUNTS="$D193/p.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$D193/p.git/config:/workspace/p.git/config:ro" && has_mount "$D193/p.git/commondir:/workspace/p.git/commondir:ro" \
  && pass "G193 a bare repository a launch protected is found by its ./ with its HEAD and objects moved aside" \
  || fail "G193 protected, then hidden (rc=$LAUNCH_RC; $(mounts | grep -F p.git | tr '\n' ' '))"
# A HEAD beside a commondir git does not write still refuses, of any kind.
mkdir -p "$D193/h" && printf 'ref: refs/heads/main\n' > "$D193/h/HEAD" && printf '/nonexistent/cd\n' > "$D193/h/commondir"
EXTRA_MOUNTS="$D193/h" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $D193/h/commondir sends git to" "$ERR" \
  && pass "G193 a HEAD beside a commondir git does not write still refuses the launch" \
  || fail "G193 HEAD beside a commondir (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
# With no HEAD and outside a worktrees/<name> directory, only the launcher's
# own ./ makes a git directory: a path, absolute or relative, does not.
mkdir -p "$D193/h2" "$D193/h3" && printf '/nonexistent/cd\n' > "$D193/h2/commondir" && printf '../x\n' > "$D193/h3/commondir"
for h193 in h2 h3; do
  EXTRA_MOUNTS="$D193/$h193" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 && "$(find "$D193/$h193" -mindepth 1 | wc -l | tr -d ' ')" == 1 ]] \
    && pass "G193 a commondir holding a path ($(cat "$D193/$h193/commondir")), with no HEAD, is left alone" \
    || fail "G193 a path, no HEAD, $h193 (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
done
# Where git keeps a linked worktree's directory, any regular commondir still
# counts. A bare repository never protected, its HEAD moved aside; its worktree's
# directory, HEAD moved aside too, its commondir naming a directory of the
# agent's: left alone, the session put both HEADs back and the host's git in the
# checkout ran that directory's config (final review of this fix).
mkdir -p "$D193/t" && "${G[@]}" init -q --bare "$D193/t/w.git" && "${G[@]}" -C "$PROJ" push -q "$D193/t/w.git" HEAD:refs/heads/main 2>/dev/null \
  && "${G[@]}" --git-dir="$D193/t/w.git" worktree add -q "$TMP/out193t" main 2>/dev/null \
  && mkdir -p "$D193/t/w.git/evil/objects" "$D193/t/w.git/evil/refs" && printf '[core]\n\tfsmonitor = /bin/true\n' > "$D193/t/w.git/evil/config" \
  && mv "$D193/t/w.git/HEAD" "$D193/t/w.git/H" && mv "$D193/t/w.git/worktrees/out193t/HEAD" "$D193/t/w.git/worktrees/out193t/H" \
  && printf '../../evil\n' > "$D193/t/w.git/worktrees/out193t/commondir" || { printf 'SCAFFOLD-FAILED: G193 trap\n'; exit 1; }
EXTRA_MOUNTS="$D193/t" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $D193/t/w.git/worktrees/out193t/commondir sends git to" "$ERR" \
  && pass "G193 a worktree's directory with no HEAD and a commondir git does not write still refuses, its repository hidden too" \
  || fail "G193 hidden repository's worktree (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -1))"
rm -rf "$TMP/out193t" "$D193/t"
# So a file of yours by that name in a directory worktrees/<name>/ is still taken.
mkdir -p "$D193/docs/worktrees/guide" && printf 'my notes\n' > "$D193/docs/worktrees/guide/commondir"
EXTRA_MOUNTS="$D193/docs" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $D193/docs/worktrees/guide/commondir sends git to" "$ERR" \
  && grep -qF "A file of yours that only shares the name: rename it" "$ERR" \
  && pass "G193 a file named commondir in a directory worktrees/<name>/ is still refused, and said to be renamed" \
  || fail "G193 file under worktrees/<name>/ (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
# A link by that name with no HEAD beside it was never taken, and is not now:
# the scan does not meet it, and one a .git file names is no git directory.
mkdir -p "$D193/h4/d" "$D193/h4/co" && printf './\n' > "$D193/h4/target" && ln -s ../target "$D193/h4/d/commondir" \
  && printf 'gitdir: %s\n' "$D193/h4/d" > "$D193/h4/co/.git"
EXTRA_MOUNTS="$D193/h4" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "names $D193/h4/d, which is not a git directory" "$ERR" \
  && pass "G193 a link named commondir, with no HEAD, makes no git directory" \
  || fail "G193 link, no HEAD (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -1))"
# A repository protected with no placeholder (its config sets core.worktree,
# GIT-73) and its linked worktree, both HEADs moved aside in a session: the
# worktree's ../.. still finds both.
mkdir -p "$D193/w" && "${G[@]}" init -q --bare "$D193/w/dot.git" && "${G[@]}" -C "$PROJ" push -q "$D193/w/dot.git" HEAD:refs/heads/main 2>/dev/null \
  && "${G[@]}" --git-dir="$D193/w/dot.git" worktree add -q "$TMP/out193" main 2>/dev/null \
  && "${G[@]}" --git-dir="$D193/w/dot.git" config core.bare false && "${G[@]}" --git-dir="$D193/w/dot.git" config core.worktree "$D193/w" \
  || { printf 'SCAFFOLD-FAILED: G193 worktree\n'; exit 1; }
EXTRA_MOUNTS="$D193/w" launch "$TMP/app"
n193="$(mounts | grep -cF "$D193/w/dot.git/")"
mv "$D193/w/dot.git/HEAD" "$D193/w/dot.git/H" && mv "$D193/w/dot.git/worktrees/out193/HEAD" "$D193/w/dot.git/worktrees/out193/H"
EXTRA_MOUNTS="$D193/w" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$n193" -gt 0 && "$(mounts | grep -cF "$D193/w/dot.git/")" == "$n193" ]] \
  && has_mount "$D193/w/dot.git/config:/workspace/w/dot.git/config:ro" \
  && pass "G193 a repository with no placeholder and its worktree, their HEADs moved aside, keep their $n193 mounts" \
  || fail "G193 HEADs moved aside (rc=$LAUNCH_RC; $n193 before, $(mounts | grep -cF "$D193/w/dot.git/") after)"
rm -rf "$TMP/out193"
# A .git file naming a directory with a commondir and no HEAD: named, and
# looked at again after the session, which names it once it has a HEAD. In
# this mount, and in another, where nothing was said (bugs review GIT-86).
for m193 in f "f2 g2"; do
  # shellcheck disable=SC2086  # split on purpose: one name, or two
  set -- $m193; a193="$D193/$1"; b193="$D193/${2:-$1}"; w193="this mount"; [[ -z "${2:-}" ]] || w193="another mount"
  mkdir -p "$a193/co" "$b193/node_modules/gd" "$b193/node_modules/cd/objects" "$b193/node_modules/cd/refs" \
    && printf '../cd\n' > "$b193/node_modules/gd/commondir" \
    && printf 'gitdir: %s\n' "$b193/node_modules/gd" > "$a193/co/.git" && printf '[core]\n\tfsmonitor = /bin/true\n' > "$b193/node_modules/cd/config"
  e193="$a193"; [[ "$a193" == "$b193" ]] || e193="$a193 $b193"
  FAKE_SESSION="printf 'ref: refs/heads/main\n' > '$b193/node_modules/gd/HEAD'" EXTRA_MOUNTS="$e193" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && grep -qF "names $b193/node_modules/gd, which is not a git directory" "$ERR" \
    && grep -qF "$b193/node_modules/gd (" < <(grep -A3 -F 'WARNING: the session made git repositories' "$ERR") \
    && pass "G193 a .git file naming one with no HEAD is named, and named again once the session writes the HEAD ($w193)" \
    || fail "G193 named by a .git file, $w193 (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -3 | tr '\n' ' '))"
  EXTRA_MOUNTS="$e193" launch "$TMP/app"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $b193/node_modules/gd/commondir sends git to" "$ERR" \
    && pass "G193 …and refuses the next launch ($w193)" \
    || fail "G193 next launch, $w193 (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
done
set --
# A target the agent cannot write, outside every writable mount, is not named.
mkdir -p "$D193/f3/co" "$TMP/out193b/x" && printf 'gitdir: %s\n' "$TMP/out193b/x" > "$D193/f3/co/.git"
EXTRA_MOUNTS="$D193/f3" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/out193b/x, which is not a git directory" "$ERR" \
  && pass "G193 a .git file naming a directory outside every writable mount that is no git directory is not named" \
  || fail "G193 target outside every mount (rc=$LAUNCH_RC; $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/out193b"

# ── G194: remote-tracking refs named HEAD, objects and refs are no repository ──
# In a bare repository, a remote whose HEAD is set and that has branches objects
# and refs leaves three loose refs that passed for a git directory: the launch
# made commondir, config and hooks/ among them, and git gc then failed (bugs
# review GIT-74). Passed over only where git itself turns them down: under the
# refs/ or logs/ of a git directory, objects and refs regular files with no
# execute bit, and nothing else of a git directory beside them.
D194="$TMP/d194"; mkdir -p "$D194" && "${G[@]}" init -q "$D194/src" && "${G[@]}" -C "$D194/src" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$D194/src" branch objects && "${G[@]}" -C "$D194/src" branch refs \
  && "${G[@]}" init -q --bare "$D194/b.git" && "${G[@]}" --git-dir="$D194/b.git" remote add o "$D194/src" \
  && "${G[@]}" --git-dir="$D194/b.git" -c protocol.file.allow=always fetch -q o 2>/dev/null \
  && "${G[@]}" --git-dir="$D194/b.git" remote set-head o main \
  && [[ -f "$D194/b.git/refs/remotes/o/HEAD" && -f "$D194/b.git/refs/remotes/o/objects" && -f "$D194/b.git/refs/remotes/o/refs" ]] \
  || { printf 'SCAFFOLD-FAILED: G194\n'; exit 1; }
o194="$D194/b.git/refs/remotes/o"
EXTRA_MOUNTS="$D194/b.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && ! -e "$o194/commondir" && ! -e "$o194/hooks" && ! -e "$o194/config" ]] \
  && ! grep -qF "refs/remotes/o" < <(mounts) \
  && [[ -z "$("${G[@]}" --git-dir="$D194/b.git" for-each-ref 2>&1 >/dev/null)" ]] \
  && "${G[@]}" --git-dir="$D194/b.git" gc -q 2>/dev/null \
  && pass "G194 loose remote-tracking refs HEAD, objects and refs get nothing made among them, and git gc still works" \
  || fail "G194 refs taken for a repository (rc=$LAUNCH_RC; $(ls "$o194" 2>/dev/null | tr '\n' ' '); gc: $("${G[@]}" --git-dir="$D194/b.git" gc -q 2>&1 | head -1))"
# With branches named config and hooks beside them as well: git turns the
# directory down before it reads either.
rm -rf "$D194/b.git"; "${G[@]}" -C "$D194/src" branch config && "${G[@]}" -C "$D194/src" branch hooks \
  && "${G[@]}" init -q --bare "$D194/b.git" && "${G[@]}" --git-dir="$D194/b.git" remote add o "$D194/src" \
  && "${G[@]}" --git-dir="$D194/b.git" -c protocol.file.allow=always fetch -q o 2>/dev/null \
  && "${G[@]}" --git-dir="$D194/b.git" remote set-head o main && [[ -f "$o194/config" && -f "$o194/hooks" && -f "$o194/objects" ]] \
  || { printf 'SCAFFOLD-FAILED: G194 config and hooks\n'; exit 1; }
EXTRA_MOUNTS="$D194/b.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && ! -e "$o194/commondir" && -f "$o194/hooks" && -s "$o194/config" ]] && ! grep -qF "refs/remotes/o" < <(mounts) \
  && pass "G194 …with branches named config and hooks beside them too" \
  || fail "G194 config and hooks branches (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1); $(ls -F "$o194" 2>/dev/null | tr '\n' ' '))"
# The guards: each of these is still taken, and protected.
g194() {  # NAME, then what to do in the candidate $c194 before the launch
  local n="$1"; shift
  c194="$D194/g.git/refs/x"; rm -rf "$D194/g.git" "$D194/co"
  "${G[@]}" init -q --bare "$D194/g.git" && mkdir -p "$c194" && printf 'ref: refs/heads/main\n' > "$c194/HEAD" \
    && printf '%040d\n' 1 > "$c194/objects" && printf '%040d\n' 2 > "$c194/refs" && "$@" \
    || { printf 'SCAFFOLD-FAILED: G194 %s\n' "$n"; exit 1; }
  EXTRA_MOUNTS="$D194/g.git" launch "$TMP/app"
  { { [[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $c194/commondir sends git to" "$ERR"; } \
      || { [[ "$LAUNCH_RC" == 0 ]] && has_mount "$c194/config:/workspace/g.git/refs/x/config:ro"; }; } \
    && pass "G194 still taken: $n" \
    || fail "G194 passed over: $n (rc=$LAUNCH_RC; $(mounts | grep -F /refs/x | tr '\n' ' '))"
}
# The shape the guards start from is itself passed over, so each shows something.
c194="$D194/g.git/refs/x"; "${G[@]}" init -q --bare "$D194/g.git" && mkdir -p "$c194" && printf 'ref: refs/heads/main\n' > "$c194/HEAD" \
  && printf '%040d\n' 1 > "$c194/objects" && printf '%040d\n' 2 > "$c194/refs" || { printf 'SCAFFOLD-FAILED: G194 shape\n'; exit 1; }
EXTRA_MOUNTS="$D194/g.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && ! -e "$c194/commondir" && ! -e "$c194/config" ]] && ! grep -qF "/refs/x" < <(mounts) \
  && pass "G194 the same three files under any git directory's refs/ are passed over" \
  || fail "G194 the shape itself (rc=$LAUNCH_RC; $(ls "$c194" | tr '\n' ' '))"
x194() { chmod 0744 "$c194/objects"; };                       g194 "objects executable by its owner" x194
o194x() { chmod 0645 "$c194/refs"; };                         g194 "refs executable by others only, which root's git takes" o194x
g194x() { chmod 0654 "$c194/refs"; };                         g194 "refs executable by its group only" g194x
d194() { rm "$c194/objects" "$c194/refs" && mkdir "$c194/objects" "$c194/refs"; }; g194 "objects and refs directories" d194
c194f() { printf '../y\n' > "$c194/commondir"; };            g194 "a commondir beside them" c194f
l194() { rm "$c194/refs" && ln -s objects "$c194/refs"; };    g194 "refs a link to a file" l194
# One a .git file names is taken as before, whatever its place.
n194() { mkdir -p "$D194/g.git/co" && printf 'gitdir: %s\n' "$c194" > "$D194/g.git/co/.git"; }; g194 "the same, named by a .git file" n194
# Under the logs/ of a git directory it is passed over too.
rm -rf "$D194/g.git"; "${G[@]}" init -q --bare "$D194/g.git" && mkdir -p "$D194/g.git/logs/refs/remotes/o" \
  && for x194 in HEAD objects refs; do printf '0 1 t\n' > "$D194/g.git/logs/refs/remotes/o/$x194"; done
EXTRA_MOUNTS="$D194/g.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && ! -e "$D194/g.git/logs/refs/remotes/o/commondir" ]] && ! grep -qF "/logs/refs" < <(mounts) \
  && pass "G194 reflogs named HEAD, objects and refs are passed over too" \
  || fail "G194 under logs/ (rc=$LAUNCH_RC; $(ls "$D194/g.git/logs/refs/remotes/o" | tr '\n' ' '))"
# Under a directory named refs that belongs to no git directory.
rm -rf "$D194/g.git"; mkdir -p "$D194/plain/refs/x" && printf 'ref: refs/heads/main\n' > "$D194/plain/refs/x/HEAD" \
  && printf '%040d\n' 1 > "$D194/plain/refs/x/objects" && printf '%040d\n' 2 > "$D194/plain/refs/x/refs"
EXTRA_MOUNTS="$D194/plain" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$D194/plain/refs/x/config:/workspace/plain/refs/x/config:ro" \
  && pass "G194 still taken: the same under a refs/ that is no git directory's" \
  || fail "G194 passed over under a plain refs/ (rc=$LAUNCH_RC; $(mounts | grep -F /refs/x | tr '\n' ' '))"
# In a git directory, but not under its refs/ or logs/.
rm -rf "$D194/plain"; "${G[@]}" init -q --bare "$D194/g.git" && mkdir -p "$D194/g.git/other/x" && printf 'ref: refs/heads/main\n' > "$D194/g.git/other/x/HEAD" \
  && printf '%040d\n' 1 > "$D194/g.git/other/x/objects" && printf '%040d\n' 2 > "$D194/g.git/other/x/refs"
EXTRA_MOUNTS="$D194/g.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$D194/g.git/other/x/config:/workspace/g.git/other/x/config:ro" \
  && pass "G194 still taken: the same in a git directory, outside its refs/ and logs/" \
  || fail "G194 passed over outside refs/ (rc=$LAUNCH_RC; $(mounts | grep -F /other/x | tr '\n' ' '))"
rm -rf "$D194/g.git"
# A real bare repository kept under another's refs/.
rm -rf "$D194/plain"; "${G[@]}" init -q --bare "$D194/g.git" && "${G[@]}" init -q --bare "$D194/g.git/refs/inner.git"
EXTRA_MOUNTS="$D194/g.git" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$D194/g.git/refs/inner.git/config:/workspace/g.git/refs/inner.git/config:ro" \
  && pass "G194 still taken: a real bare repository under another's refs/" \
  || fail "G194 a repository under refs/ (rc=$LAUNCH_RC; $(mounts | grep -F inner.git | tr '\n' ' '))"
chmod -R u+rwx "$D193" "$D194" 2>/dev/null; rm -rf "$D193" "$D194"

# ── G195: a repository protected with no placeholder is found again ───────────
# One whose config sets core.worktree gets no ./ (GIT-73), and the ./ was what
# found a protected git directory again once a session had moved its HEAD
# aside: with none, and no linked worktree, the next launch bound nothing of
# it, the session wrote its config and put the HEAD back, and the host's git
# ran it. Its config and hooks/ are bound, so they are what finds it: a
# directory with no HEAD holding a hooks/ and a config that sets core.worktree
# (bugs review GIT-85, GIT-7).
D195="$TMP/d195"; mkdir -p "$D195/wt" && "${G[@]}" init -q --bare "$D195/dot.git" \
  && "${G[@]}" -C "$PROJ" push -q "$D195/dot.git" HEAD:refs/heads/main 2>/dev/null \
  && "${G[@]}" --git-dir="$D195/dot.git" config core.bare false && "${G[@]}" --git-dir="$D195/dot.git" config core.worktree "$D195/wt" \
  || { printf 'SCAFFOLD-FAILED: G195\n'; exit 1; }
EXTRA_MOUNTS="$D195" launch "$TMP/app"
m195="$(mounts | grep -F "$D195/dot.git" | LC_ALL=C sort)"
[[ "$LAUNCH_RC" == 0 && ! -e "$D195/dot.git/commondir" ]] && has_mount "$D195/dot.git/config:/workspace/d195/dot.git/config:ro" \
  && pass "G195 control: it is protected, with no placeholder" \
  || fail "G195 control (rc=$LAUNCH_RC; $(tr '\n' ' ' <<<"$m195"))"
mv "$D195/dot.git/objects" "$D195/dot.git/o" && mv "$D195/dot.git/refs" "$D195/dot.git/r"
EXTRA_MOUNTS="$D195" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -n "$m195" && "$(mounts | grep -F "$D195/dot.git" | LC_ALL=C sort)" == "$m195" ]] \
  && pass "G195 with its objects and refs moved aside it keeps the same mounts" \
  || fail "G195 objects and refs moved aside (rc=$LAUNCH_RC; before: $(wc -l <<<"$m195" | tr -d ' '); after: $(mounts | grep -cF "$D195/dot.git"))"
mv "$D195/dot.git/HEAD" "$D195/dot.git/H"
EXTRA_MOUNTS="$D195" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(mounts | grep -F "$D195/dot.git" | LC_ALL=C sort)" == "$m195" ]] \
  && pass "G195 …and with its HEAD moved aside as well" \
  || fail "G195 HEAD moved aside (rc=$LAUNCH_RC; after: $(mounts | grep -cF "$D195/dot.git"))"
mv "$D195/dot.git/o" "$D195/dot.git/objects" && mv "$D195/dot.git/r" "$D195/dot.git/refs"
EXTRA_MOUNTS="$D195" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$(mounts | grep -F "$D195/dot.git" | LC_ALL=C sort)" == "$m195" ]] \
  && pass "G195 …and with only its HEAD moved aside" \
  || fail "G195 only HEAD moved aside (rc=$LAUNCH_RC; after: $(mounts | grep -cF "$D195/dot.git"))"
# A commondir the session made there, whatever it holds, refuses the next
# launch with the HEAD moved aside too: a relative path with no HEAD beside it
# is none of git's elsewhere (GIT-79), and would have hidden this one.
printf '../evil\n' > "$D195/dot.git/commondir"
EXTRA_MOUNTS="$D195" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $D195/dot.git/commondir sends git to" "$ERR" \
  && pass "G195 a commondir made there refuses the next launch, its HEAD moved aside or not" \
  || fail "G195 commondir and no HEAD (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -f "$D195/dot.git/commondir"
# What makes it one: a hooks/ and a config that sets core.worktree, both.
mkdir -p "$D195/p1/hooks" "$D195/p2/hooks" "$D195/p3" && printf '[core]\n\tbare = false\n' > "$D195/p1/config" \
  && printf '[core]\n\tworktree = /x\n' > "$D195/p3/config" && printf 'port = 80\n[core]\n' > "$D195/p2/config"
EXTRA_MOUNTS="$D195" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE "/d195/p[123]/" < <(mounts) && [[ ! -e "$D195/p1/commondir" && ! -e "$D195/p3/hooks" ]] \
  && pass "G195 a config with a hooks/ but no core.worktree, or with it and no hooks/, makes no git directory" \
  || fail "G195 lookalikes (rc=$LAUNCH_RC; $(mounts | grep -E "/d195/p[123]/" | tr '\n' ' '))"
chmod -R u+rwx "$D195" 2>/dev/null; rm -rf "$D195"

# ── G196: what is read and found to be no git directory is bounded ────────────
# A file named commondir beside no HEAD, loose refs, and a config beside a
# hooks/ each take a read to turn down, and the agent can plant any number:
# past SANDBOX_GIT_MAX the launch is refused, naming five (final review of
# GIT-79's fix).
D196="$TMP/d196"; mkdir -p "$D196/a" "$D196/b" "$D196/c" && "${G[@]}" init -q --bare "$D196/b/g.git"
for i196 in 1 2 3 4 5; do
  mkdir -p "$D196/a/n$i196" "$D196/b/g.git/refs/x$i196" "$D196/c/k$i196/hooks" && printf 'notes\n' > "$D196/a/n$i196/commondir" \
    && printf 'ref: refs/heads/main\n' > "$D196/b/g.git/refs/x$i196/HEAD" && printf '%040d\n' 1 > "$D196/b/g.git/refs/x$i196/objects" \
    && printf '%040d\n' 2 > "$D196/b/g.git/refs/x$i196/refs" && printf '[core]\n\tbare = false\n' > "$D196/c/k$i196/config"
done
for w196 in a b c; do
  SANDBOX_GIT_MAX=4 EXTRA_MOUNTS="$D196/$w196" launch "$TMP/app"
  [[ "$LAUNCH_RC" != 0 ]] && grep -qF "holds more than 4 directories this launch had to read" "$ERR" \
    && [[ "$(grep -cE "^ +$D196/$w196/" "$ERR")" == 5 ]] \
    && pass "G196 five look-alikes past a limit of four refuse the launch, and are named ($w196)" \
    || fail "G196 $w196 (rc=$LAUNCH_RC; $(grep -F -A2 ERROR "$ERR" | head -3 | tr '\n' ' '))"
  SANDBOX_GIT_MAX=5 EXTRA_MOUNTS="$D196/$w196" launch "$TMP/app"
  [[ "$LAUNCH_RC" == 0 ]] && pass "G196 …and five within a limit of five launch ($w196)" \
    || fail "G196 $w196 within the limit (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
done
# Only what took a read is counted: a file named config or HEAD with nothing of
# a git directory beside it costs none, and any number of them launch.
mkdir -p "$D196/d"
for i196 in 1 2 3 4 5; do
  mkdir -p "$D196/d/c$i196" "$D196/d/h$i196" && printf 'port = 80\n' > "$D196/d/c$i196/config" && printf 'title\n' > "$D196/d/h$i196/HEAD"
done
SANDBOX_GIT_MAX=4 EXTRA_MOUNTS="$D196/d" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && pass "G196 files named config or HEAD that cost no read are not counted" \
  || fail "G196 uncounted (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$D196"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
