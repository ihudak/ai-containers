#!/usr/bin/env bash
# tests/test-git-internals-ro-config.sh — what a protected config holds that the
# host's git would run or read: includes followed to their end, core.hooksPath,
# and what the launch does where git does not run (GIT-24).
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

# ── G19: hooks run from a writable core.hooksPath are named ───────────────────
mkdir -p "$PROJ/.husky/_" && "${G[@]}" -C "$PROJ" config core.hooksPath .husky/_
launch ..
grep -qF "NOTE: /workspace/proj/.git runs its git hooks from /workspace/proj/.husky/_ (core.hooksPath)" "$ERR" \
  && pass "G19 a core.hooksPath in the writable project is named in a NOTE" \
  || fail "G19 hooksPath NOTE (stderr: $(grep -E 'NOTE' "$ERR" | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset core.hooksPath; rm -rf "$PROJ/.husky"

# ── G23: extensions.worktreeConfig as git spells true — a bare key ────────────
printf '[extensions]\n\tworktreeConfig\n' >> "$PROJ/.git/config"
launch ..
[[ -f "$PROJ/.git/config.worktree" ]] && has_mount "$PROJ/.git/config.worktree:/workspace/proj/.git/config.worktree:ro" \
  && pass "G23 a bare 'worktreeConfig' key reads as true, as git reads it, and gets the placeholder" \
  || fail "G23 bare worktreeConfig (git mounts: $(git_mounts | grep worktree | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset extensions.worktreeConfig 2>/dev/null; rm -f "$PROJ/.git/config.worktree"

# ── G24: a hook that is a link into the writable tree is named ────────────────
# hooks/ is read-only, but the link's way out is not. Only names git runs are
# looked at; a link that stays in hooks/, or leaves every mount, is silent.
mkdir -p "$PROJ/scripts" && printf '#!/bin/sh\n' > "$PROJ/scripts/pre-commit"
ln -s ../../scripts/pre-commit "$PROJ/.git/hooks/pre-commit"
: > "$PROJ/.git/hooks/x.sample" && ln -s x.sample "$PROJ/.git/hooks/post-commit"
ln -s "$TMP/home/elsewhere" "$PROJ/.git/hooks/pre-push"
ln -s ../../scripts/pre-commit "$PROJ/.git/hooks/my-helper"
launch ..
grep -qF "NOTE: /workspace/proj/.git/hooks/pre-commit, a hook your host's git runs, is a link the agent can redirect:" "$ERR" \
  && grep -qF "it can change $PROJ/scripts/pre-commit (at /workspace/proj/scripts/pre-commit), which the hook runs." "$ERR" \
  && pass "G24 a hook linked into the writable project is named in a NOTE, with where the agent sees it" \
  || fail "G24 hook link NOTE (stderr: $(grep -A1 'hooks/' "$ERR" | tr '\n' ' '))"
! grep -qE 'hooks/(post-commit|pre-push|my-helper),' "$ERR" \
  && pass "G24 a link staying in hooks/, one leaving every mount, and a name git never runs are silent" \
  || fail "G24 quiet hook links (stderr: $(grep 'hooks/' "$ERR" | tr '\n' ' '))"
rm -f "$PROJ/.git/hooks/pre-commit" "$PROJ/.git/hooks/post-commit" "$PROJ/.git/hooks/pre-push" \
      "$PROJ/.git/hooks/my-helper" "$PROJ/.git/hooks/x.sample"; rm -rf "$PROJ/scripts"

# ── G25: a config that includes a file the agent can write is named ───────────
# git reads an included file as part of the config, so it can set core.fsmonitor
# from wherever it lies — even one that does not exist yet, which the agent can
# create. A relative path resolves from the including file's directory.
"${G[@]}" -C "$PROJ" config include.path ../shared.gitconfig
"${G[@]}" -C "$PROJ" config 'includeIf.gitdir:/x/.path' ../other.gitconfig
"${G[@]}" -C "$PROJ" config --add include.path "$TMP/outside.gitconfig"
"${G[@]}" -C "$PROJ" config --add include.path ../.ai-containers/team.gitconfig
launch ..
grep -qF "WARNING: /workspace/proj/.git/config includes ../shared.gitconfig (include.path), which the agent can redirect:" "$ERR" \
  && grep -qF "it can write $PROJ/shared.gitconfig (at /workspace/proj/shared.gitconfig)" "$ERR" \
  && pass "G25 an include.path into the writable project, not yet there, is named in a WARNING" \
  || fail "G25 include.path WARNING (stderr: $(grep -A1 'includes' "$ERR" | tr '\n' ' '))"
grep -qF "includes ../other.gitconfig (includeif.gitdir:/x/.path)" "$ERR" \
  && pass "G25 so is an includeIf, whatever its condition" \
  || fail "G25 includeIf (stderr: $(grep 'includes' "$ERR" | tr '\n' ' '))"
! grep -qE 'includes .*(outside|team)\.gitconfig' "$ERR" \
  && pass "G25 an include outside every mount, or under the read-only launcher, is silent" \
  || fail "G25 quiet includes (stderr: $(grep 'includes' "$ERR" | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset-all include.path; "${G[@]}" -C "$PROJ" config --remove-section 'includeIf.gitdir:/x/'

# ── G114: paths a config names are resolved physically, as git resolves them ──
# A `..` after a link steps out of where the link leads. core.hooksPath and the
# directory a second-level include is relative to were taken lexically, so a
# hooks path into the writable tree, or an include there, went unnamed (review
# of the GIT-31 fix).
mkdir -p "$TMP/p114/r" && "${G[@]}" -C "$TMP/p114/r" init -q && mkdir -p "$TMP/p114/r/tools/sub" "$TMP/p114/r/tools/hooks" \
  && ln -s ../tools/sub "$TMP/p114/r/.git/x" && "${G[@]}" -C "$TMP/p114/r" config core.hooksPath .git/x/../hooks \
  || { printf 'SCAFFOLD-FAILED: G114 hooksPath\n'; exit 1; }
EXTRA_MOUNTS="$TMP/p114" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/p114/r/tools/hooks (core.hooksPath)" "$ERR" \
  && pass "G114 a core.hooksPath through a link and .. is named where it leads" \
  || fail "G114 hooksPath read lexically (stderr: $(grep -F 'hooks from' "$ERR" | head -1))"
rm -rf "$TMP/p114"
# The second level: r's config includes L/x/../a.cfg, which is L/deep/a.cfg in a
# read-only planted launcher; that includes y.cfg beside it, a link into the
# writable w/. Lexically y.cfg was beside L/a.cfg, which does not exist.
mkdir -p "$TMP/p114/L/deep/sub" "$TMP/p114/w" && : > "$TMP/p114/L/sandbox.sh" && : > "$TMP/p114/L/sandbox-common.sh" \
  && ln -s deep/sub "$TMP/p114/L/x" && printf '[include]\n\tpath = y.cfg\n' > "$TMP/p114/L/deep/a.cfg" \
  && ln -s ../../w/y.cfg "$TMP/p114/L/deep/y.cfg" && : > "$TMP/p114/w/y.cfg" \
  && mkdir -p "$TMP/p114/r" && "${G[@]}" -C "$TMP/p114/r" init -q \
  && "${G[@]}" -C "$TMP/p114/r" config include.path ../../L/x/../a.cfg \
  || { printf 'SCAFFOLD-FAILED: G114 include\n'; exit 1; }
EXTRA_MOUNTS="$TMP/p114" launch "$TMP/app"
grep -qF "includes y.cfg (include.path in" "$ERR" && grep -qF "it can write $TMP/p114/w/y.cfg" "$ERR" \
  && pass "G114 an include relative to an included file is resolved from where that file is" \
  || fail "G114 second-level include read lexically (stderr: $(grep -A1 -F includes "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/p114"

# ── G29: an include inside an included file is followed ───────────────────────
# A file the agent cannot reach can still include one it can: git reads the
# whole chain as the config. Followed from every file that is itself safe, to
# git's own depth (10), and a loop ends.
mkdir -p "$TMP/inc29"
"${G[@]}" config --file "$TMP/inc29/a.gitconfig" include.path "$TMP/inc29/b.gitconfig"
"${G[@]}" config --file "$TMP/inc29/b.gitconfig" include.path ../proj/nested29.gitconfig
"${G[@]}" config --file "$TMP/inc29/b.gitconfig" --add include.path "$TMP/inc29/a.gitconfig"
"${G[@]}" -C "$PROJ" config include.path "$TMP/inc29/a.gitconfig"
launch ..
grep -qF "WARNING: /workspace/proj/.git/config includes ../proj/nested29.gitconfig (include.path in $TMP/inc29/b.gitconfig), which the agent can redirect:" "$ERR" \
  && grep -qF "it can write $PROJ/nested29.gitconfig (at /workspace/proj/nested29.gitconfig)" "$ERR" \
  && pass "G29 an include two files down, into the writable project, is named with the file that includes it" \
  || fail "G29 nested include (rc=$LAUNCH_RC; stderr: $(grep -A1 'includes' "$ERR" | tr '\n' ' '))"
[[ "$LAUNCH_RC" == 0 && "$(grep -c 'nested29.gitconfig (include.path' "$ERR")" -eq 1 ]] \
  && pass "G29 an include loop ends, and each include is named once" \
  || fail "G29 loop (rc=$LAUNCH_RC; named: $(grep -c 'nested29' "$ERR"))"
"${G[@]}" -C "$PROJ" config --unset-all include.path; rm -rf "$TMP/inc29"

# ── G30: what the agent writes in an included file cannot silence the check ───
# The launcher runs from inside the project, and a git started there reads the
# project's config — includes and all — before anything else. An include loop in
# the writable file the config includes made every such git die, and every
# include WARNING with it. The config files are read as files, never as the
# repository the launcher happens to sit in.
"${G[@]}" -C "$PROJ" config include.path ../shared30.gitconfig
"${G[@]}" config --file "$PROJ/shared30.gitconfig" include.path shared30.gitconfig
launch ..
grep -qF "WARNING: /workspace/proj/.git/config includes ../shared30.gitconfig (include.path), which the agent can redirect:" "$ERR" \
  && pass "G30 an include loop in the writable included file does not silence its WARNING" \
  || fail "G30 include WARNING silenced (rc=$LAUNCH_RC; stderr: $(grep -E 'includes|fatal' "$ERR" | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset-all include.path; rm -f "$PROJ/shared30.gitconfig"

# ── G31: what an agent-made repository holds cannot make the launch slow ──────
# Its .git/config is overlaid read-only, so the include walk follows it as safe —
# but every byte of it is the agent's. Includes of the same file spelled two
# ways (./config, .//config) made the walk exponential: 15 s with two, past
# five minutes with four (the review of b3d2362). Each file is read once per
# launch, however it is spelled, and the reads are bounded.
mkdir -p "$PROJ/inc31" && "${G[@]}" -C "$PROJ/inc31" init -q
for sp in ./config .//config .///config ../.git/config; do
  "${G[@]}" config --file "$PROJ/inc31/.git/config" --add include.path "$sp"
done
launch_timed 60
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt 20 ]] \
  && pass "G31 self-includes spelled four ways do not slow the launch (${LAUNCH_S}s)" \
  || fail "G31 include walk (rc=$LAUNCH_RC; ${LAUNCH_S}s)"
rm -rf "$PROJ/inc31"

# ── G32: an include the agent points at a FIFO cannot hang the launch ─────────
# The index read is git's, and git reads the repository's config — includes and
# all — before it reads the index: a FIFO there blocked it in open() forever,
# and /dev/stdin made it parse what you type. The index is read without the
# repository's config.
mkdir -p "$PROJ/fifo32" && "${G[@]}" -C "$PROJ/fifo32" init -q && mkfifo "$PROJ/fifo32/pipe"
"${G[@]}" config --file "$PROJ/fifo32/.git/config" include.path ../pipe
launch_timed 60
[[ "$LAUNCH_RC" == 0 ]] && pass "G32 a FIFO include does not hang the launch (${LAUNCH_S}s)" \
  || fail "G32 FIFO include (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(tail -2 "$ERR" | tr '\n' ' '))"
# Release any reader a failed run left blocked on it, then clean up.
( exec 3<>"$PROJ/fifo32/pipe" ) 2>/dev/null; rm -rf "$PROJ/fifo32"

# ── G34: one repository's walk cannot hide another's. A planted repository
# that includes the same shared file must not mark it read for the launch: the
# user's repository that includes it is still checked, and named (security
# review of c0d48d9).
mkdir -p "$TMP/inc34" "$PROJ/b34" "$PROJ/deep34/a"
"${G[@]}" config --file "$TMP/inc34/shared.gitconfig" include.path ../proj/w34.gitconfig
"${G[@]}" -C "$PROJ/b34" init -q && "${G[@]}" -C "$PROJ/deep34/a" init -q
"${G[@]}" config --file "$PROJ/b34/.git/config" include.path "$TMP/inc34/shared.gitconfig"
"${G[@]}" config --file "$PROJ/deep34/a/.git/config" include.path "$TMP/inc34/shared.gitconfig"
launch ..
grep -qF "WARNING: /workspace/proj/deep34/a/.git/config includes ../proj/w34.gitconfig" "$ERR" \
  && grep -qF "WARNING: /workspace/proj/b34/.git/config includes ../proj/w34.gitconfig" "$ERR" \
  && pass "G34 a shared include is checked for every repository that includes it" \
  || fail "G34 one walk hid another (stderr: $(grep 'w34' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/inc34" "$PROJ/b34" "$PROJ/deep34"

# ── G35: a config whose includes are not all followed says so ─────────────────
mkdir -p "$PROJ/many35" "$TMP/inc35" && "${G[@]}" -C "$PROJ/many35" init -q
for n in $(seq 1 25); do
  : > "$TMP/inc35/f$n.gitconfig"
  "${G[@]}" config --file "$PROJ/many35/.git/config" --add include.path "$TMP/inc35/f$n.gitconfig"
done
launch ..
grep -qF "WARNING: not every include of /workspace/proj/many35/.git/config was followed" "$ERR" \
  && pass "G35 a config past its include budget is named, not skipped in silence" \
  || fail "G35 budget silent (stderr: $(grep -iE 'include' "$ERR" | tr '\n' ' '))"
rm -rf "$PROJ/many35" "$TMP/inc35"

# ── G38: many include entries in one config cannot make the launch slow ───────
# Against the same launch with one entry, timed in the same run: a fixed 15 s
# failed on a busy host, where every launch is slower (GIT-23).
mkdir -p "$PROJ/many38" && "${G[@]}" -C "$PROJ/many38" init -q
printf '[include]\n\tpath = /nonexistent38/f0\n' >> "$PROJ/many38/.git/config"
launch_timed 120; base38="$LAUNCH_S"; brc38="$LAUNCH_RC"
{ for n in $(seq 1 5000); do printf '\tpath = /nonexistent38/f%d\n' "$n"; done; } >> "$PROJ/many38/.git/config"
launch_timed 120
[[ "$brc38" == 0 && "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt $(( base38 + 15 )) ]] \
  && grep -qF "WARNING: not every include of /workspace/proj/many38/.git/config was followed" "$ERR" \
  && pass "G38 5000 include entries in one config cost seconds, and are named (${LAUNCH_S}s, ${base38}s with one)" \
  || fail "G38 include entries (rc=$LAUNCH_RC; ${LAUNCH_S}s, ${base38}s and rc=$brc38 with one; stderr: $(grep -F many38 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/many38"

# ── G40-G42: the include walk is bounded per LAUNCH, not only per config ──────
# 100 entries per config, two configs per git directory and up to 200 planted git
# directories, and _path_walk quadratic in a path's components: 150 planted repos
# took 81 s, one config of 100 deep paths 54 s (review of the batch 1 hotfix; GIT-2).
# G40: entries across many configs share one launch budget, and hitting it is named.
for n in $(seq 1 25); do
  mkdir -p "$PROJ/b40/r$n" && "${G[@]}" -C "$PROJ/b40/r$n" init -q
  { printf '[include]\n'; for m in $(seq 1 90); do printf '\tpath = /nonexistent40/f%d\n' "$m"; done; } >> "$PROJ/b40/r$n/.git/config"
done
launch_timed 120
[[ "$LAUNCH_RC" == 0 ]] && grep -q "not every include of /workspace/proj/b40/r[0-9]*/.git/config was followed" "$ERR" \
  && pass "G40 include entries across many configs share a launch budget, and the cut is named (${LAUNCH_S}s)" \
  || fail "G40 launch-wide include budget (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(grep -c 'not every include' "$ERR") cut warnings)"
rm -rf "$PROJ/b40"
# G41: a path with hundreds of components is not walked step by step; the config is
# named as not fully checked.
mkdir -p "$PROJ/d41" && "${G[@]}" -C "$PROJ/d41" init -q
deep41="$(printf 'a/%.0s' $(seq 1 600))f"
"${G[@]}" config --file "$PROJ/d41/.git/config" include.path "$deep41"
launch_timed 60
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt 20 ]] && grep -qF "not every include of /workspace/proj/d41/.git/config was followed" "$ERR" \
  && pass "G41 a 600-component include path is not walked, and the config is named (${LAUNCH_S}s)" \
  || fail "G41 deep include path (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(grep -F d41 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/d41"
# G42: git reads config.worktree only with extensions.worktreeConfig on, so an
# include there is not the host's git's input otherwise — and not walked.
mkdir -p "$PROJ/w42" && "${G[@]}" -C "$PROJ/w42" init -q
"${G[@]}" config --file "$PROJ/w42/.git/config.worktree" include.path "$PROJ/w42-evil.gitconfig"
launch ..
! grep -qF "w42/.git/config.worktree includes" "$ERR" \
  && pass "G42 config.worktree is not walked while extensions.worktreeConfig is off" \
  || fail "G42 config.worktree walked with worktreeConfig off"
"${G[@]}" -C "$PROJ/w42" config extensions.worktreeConfig true
launch ..
grep -qF "w42/.git/config.worktree includes" "$ERR" \
  && pass "G42 … and is, once extensions.worktreeConfig is on" \
  || fail "G42 config.worktree not walked with worktreeConfig on (stderr: $(grep -F w42 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/w42"
# …and for a LINKED worktree git reads the extension from the common config, not
# from .git/worktrees/<name>/config, which it does not have (security review of
# 1978dff): its config.worktree is walked when the main repository turns it on.
mkdir -p "$PROJ/m42" && "${G[@]}" -C "$PROJ/m42" init -q && printf 'x\n' > "$PROJ/m42/f" \
  && "${G[@]}" -C "$PROJ/m42" add f && "${G[@]}" -C "$PROJ/m42" commit -qm init \
  && "${G[@]}" -C "$PROJ/m42" worktree add -q "$PROJ/m42-wt" \
  && "${G[@]}" -C "$PROJ/m42" config extensions.worktreeConfig true \
  || { printf 'SCAFFOLD-FAILED: cannot create the G42 worktree\n'; exit 1; }
wtgd="$(ls -d "$PROJ/m42/.git/worktrees"/* | head -1)"
"${G[@]}" config --file "$wtgd/config.worktree" include.path "$PROJ/m42-evil.gitconfig"
launch ..
grep -qF "$(basename "$wtgd")/config.worktree includes" "$ERR" \
  && pass "G42 a linked worktree's config.worktree is walked when the common config turns it on" \
  || fail "G42 linked worktree's config.worktree skipped (stderr: $(grep -F m42 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/m42" "$PROJ/m42-wt"

# ── G72: entries that cost nothing to check do not spend the launch's budget ──
# Empty include.path values were counted toward the 1000 entries per launch,
# so planted repositories cut the walk of every later config, yours included
# (GIT-19).
for n in $(seq 1 12); do
  "${G[@]}" init -q "$PROJ/e72/r$n" && for _ in $(seq 1 99); do printf '[include]\n\tpath =\n'; done >> "$PROJ/e72/r$n/.git/config"
done
# Yours is deeper than the planted ones, so it is walked after them.
: > "$TMP/shared72.gitconfig"; "${G[@]}" init -q "$PROJ/z72/a/b/mine" \
  && "${G[@]}" -C "$PROJ/z72/a/b/mine" config include.path "$TMP/shared72.gitconfig"
launch ..
! grep -qF "not every include of /workspace/proj/z72/a/b/mine/.git/config was followed" "$ERR" \
  && pass "G72 empty include entries in planted repositories do not cut the walk of yours" \
  || fail "G72 the launch budget was spent by empty entries"
rm -rf "$PROJ/e72" "$PROJ/z72" "$TMP/shared72.gitconfig"

# ── G98: where git does not run, no config is read by guesswork ──────────────
# The launcher once read extensions.worktreeConfig and core.hooksPath with an awk
# parser where git was missing, and it misread git's syntax both ways: "true",
# 1k or a key on the section's header line read as off, \t0 as on (GIT-24). No
# single default is safe for every caller, so where git does not run each takes
# its own cautious branch: config.worktree is made and mounted in every
# repository, the first protection names every hook in hooks/ whatever
# core.hooksPath says, and one WARNING says what could not be checked.
# A PATH with no git: each directory that holds one is replaced by a copy of its
# links without it, and every other is kept as it is.
nogit98=""; i98=0
IFS=: read -r -a pd98 <<<"$PATH"
for d98 in "${pd98[@]}"; do
  if [[ -n "$d98" && -x "$d98/git" && ! -d "$d98/git" ]]; then
    i98=$((i98 + 1)); m98="$TMP/nogit98/$i98"; mkdir -p "$m98"
    ln -s "$d98"/* "$m98"/ 2>/dev/null; rm -f "$m98/git"
    d98="$m98"
  fi
  nogit98="${nogit98:+$nogit98:}$d98"
done
PATH="$nogit98" "$BASH" -c 'command -v git' >/dev/null 2>&1 \
  && { printf 'SCAFFOLD-FAILED: G98 git is still on the no-git PATH\n'; exit 1; }
R98="$TMP/r98"
for r in plain quoted hp wtp keys; do "${G[@]}" init -q "$R98/$r"; done
# git reads this as true (it removes the quotes); the parser read it as false.
printf '[extensions]\n\tworktreeConfig = "true"\n' >> "$R98/quoted/.git/config"
for r in hp wtp; do printf '#!/bin/sh\n' > "$R98/$r/.git/hooks/pre-commit"; chmod 755 "$R98/$r/.git/hooks/pre-commit"; done
"${G[@]}" -C "$R98/hp" config core.hooksPath .githooks
"${G[@]}" -C "$R98/wtp" config extensions.worktreeConfig true
"${G[@]}" -C "$R98/wtp" config --worktree core.hooksPath .githooks
"${G[@]}" -C "$R98/keys" config core.sshCommand 'ssh -i /dev/null'
printf '#!/bin/sh\n' > "$R98/keys/.git/hooks/pre-commit"; chmod 755 "$R98/keys/.git/hooks/pre-commit"
EXTRA_MOUNTS="$R98" PATH="$nogit98" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && pass "G98 with no git on the host the launch goes ahead" \
  || fail "G98 no-git launch (rc=$LAUNCH_RC: $(tail -3 "$ERR" | tr '\n' ' '))"
ok98=1
for r in plain quoted; do
  [[ -f "$R98/$r/.git/config.worktree" && ! -s "$R98/$r/.git/config.worktree" ]] \
    && has_mount "$R98/$r/.git/config.worktree:/workspace/r98/$r/.git/config.worktree:ro" || ok98=""
done
[[ -n "$ok98" ]] \
  && pass "G98 with no git, every repository gets an empty config.worktree mounted read-only, whatever its config says" \
  || fail "G98 no-git config.worktree (plain: $(ls "$R98/plain/.git/config.worktree" 2>&1); quoted: $(ls "$R98/quoted/.git/config.worktree" 2>&1); git mounts: $(git_mounts | grep -F config.worktree | tr '\n' ' '))"
ok98=1
for r in hp wtp keys; do
  grep -qF 'pre-commit' <<<"$(grep -A1 -F "NOTE: /workspace/r98/$r/.git is protected for the first time, and its hooks/" "$ERR")" || ok98=""
done
[[ -n "$ok98" ]] \
  && pass "G98 with no git, the first protection names the hooks in hooks/ whatever core.hooksPath says" \
  || fail "G98 no-git hooks NOTE (stderr: $(grep -A1 -F 'its hooks/' "$ERR" | tr '\n' ' '))"
[[ "$(grep -c 'WARNING: git is not installed on this host' "$ERR")" == 1 ]] \
  && grep -qF 'protected here (5): includes' "$ERR" \
  && grep -qF 'Install git 2.18 or later on the host' "$ERR" \
  && pass "G98 with no git, one WARNING says what the launcher could not check" \
  || fail "G98 no-git WARNING (stderr: $(grep -A3 -F 'not installed' "$ERR" | tr '\n' ' '))"
# The next launch with no git does not name the hooks again, or claim that no
# earlier launch reported them.
EXTRA_MOUNTS="$R98" PATH="$nogit98" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qE 'r98/(hp|wtp|keys)/\.git (is|was) protected' "$ERR" \
  && pass "G98 the next launch with no git does not report the hooks again" \
  || fail "G98 hooks reported twice (rc=$LAUNCH_RC; stderr: $(grep -F 'protected' "$ERR" | tr '\n' ' '))"
# The launch with git that the WARNING asks for still names the keys the
# config already set: a launch that read none did not spend the one-time report.
# Bounded: the no-git launches made an empty config.worktree in every repository,
# and a mutant whose key loop never ended on an empty list hung here, before
# any FAIL line, so the tier could only call it UNPROVEN (GAP-2's slice 2;
# sandbox.sh: `_git_exec_keys()`).
EXTRA_MOUNTS="$R98" launch_timed 60 "$TMP/app"
rc98a="$LAUNCH_RC"; nw98a="$(grep -c 'git is not installed' "$ERR")"
grep -qi 'core.sshcommand' <<<"$(grep -A1 -F 'NOTE: /workspace/r98/keys/.git was protected by an earlier launch where git did not run, and its config sets' "$ERR")" \
  && ! grep -qF 'NOTE: /workspace/r98/keys/.git was protected by an earlier launch where git did not run, and its hooks/' "$ERR" \
  && pass "G98 a launch with no git leaves the report of a repository's keys to the next launch with git, which does not repeat its hooks" \
  || fail "G98 keys after a no-git launch (rc=$rc98a; stderr: $(grep -A1 -F 'earlier launch' "$ERR" | tr '\n' ' '))"
# Not when git is there, and not when no repository is protected.
PATH="$nogit98" launch "$TMP/app"
nw98b="$(grep -c 'git is not installed' "$ERR")"
[[ "$rc98a" == 0 && "$nw98a" == 0 && "$nw98b" == 0 && "$LAUNCH_RC" == 0 ]] \
  && pass "G98 no such WARNING with git installed, or with no repository to protect" \
  || fail "G98 WARNING out of place (with git: $nw98a, rc=$rc98a; no repository: $nw98b, rc=$LAUNCH_RC)"
# With no git, the rescan when the container exits names every repository the
# session made: it cannot read what their configs set.
sess98="$(printf '%q init -q %q' "$(command -v git)" "$R98/new98")"
FAKE_SESSION="$sess98" EXTRA_MOUNTS="$R98" PATH="$nogit98" launch "$TMP/app"
grep -qF "$R98/new98/.git (config: not read, git does not run on this host)" "$ERR" \
  && pass "G98 with no git, the rescan names a repository the session made, its config unread" \
  || fail "G98 no-git rescan (rc=$LAUNCH_RC; stderr: $(sed -n '/the session made/,$p' "$ERR" | tr '\n' ' '))"
# A git on PATH that does not run — macOS's /usr/bin/git without the Command
# Line Tools offers to install them and exits 1 — is no git either, and is run
# once, to ask: not again for an index (a stale linked worktree's), or in the
# rescan.
mkdir -p "$TMP/brokengit98"
printf '#!/bin/sh\necho x >> "%s"\necho "xcrun: error: invalid active developer path" >&2\nexit 1\n' "$TMP/brokengit98.log" > "$TMP/brokengit98/git"
chmod +x "$TMP/brokengit98/git"
"${G[@]}" init -q "$TMP/r98b/plain" && "${G[@]}" -C "$TMP/r98b/plain" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/r98b/plain" worktree add -q "$TMP/r98b/wt98" && rm -rf "$TMP/r98b/wt98" \
  || { printf 'SCAFFOLD-FAILED: G98 stale worktree\n'; exit 1; }
rm -f "$TMP/brokengit98.log"
EXTRA_MOUNTS="$TMP/r98b" PATH="$TMP/brokengit98:$nogit98" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -f "$TMP/r98b/plain/.git/config.worktree" ]] \
  && [[ "$(grep -c 'WARNING: git is not installed on this host, is older than 2.18, or does not run' "$ERR")" == 1 ]] \
  && pass "G98 a git that is on PATH but does not run is taken for none" \
  || fail "G98 broken git (rc=$LAUNCH_RC; config.worktree: $(ls "$TMP/r98b/plain/.git/config.worktree" 2>&1); stderr: $(grep -A1 -F 'WARNING: git' "$ERR" | tr '\n' ' '))"
[[ "$(wc -l < "$TMP/brokengit98.log" 2>/dev/null | tr -d ' ')" == 1 ]] \
  && pass "G98 … and it is run once, to ask, and never again in the launch" \
  || fail "G98 a git that does not run was run $(wc -l < "$TMP/brokengit98.log" 2>/dev/null | tr -d ' ') times"
# One that exits 0 but does not give the probe's answer — too old for
# --type=bool, or a stub — is none either: an exit status alone is not enough.
mkdir -p "$TMP/mutegit98"; printf '#!/bin/sh\nexit 0\n' > "$TMP/mutegit98/git"; chmod +x "$TMP/mutegit98/git"
"${G[@]}" init -q "$TMP/r98c/plain"
EXTRA_MOUNTS="$TMP/r98c" PATH="$TMP/mutegit98:$nogit98" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && -f "$TMP/r98c/plain/.git/config.worktree" ]] && grep -qF 'WARNING: git is not installed on this host' "$ERR" \
  && pass "G98 a git that exits 0 without the probe's answer is taken for none" \
  || fail "G98 mute git (rc=$LAUNCH_RC; config.worktree: $(ls "$TMP/r98c/plain/.git/config.worktree" 2>&1); stderr: $(grep -A1 -F 'WARNING: git' "$ERR" | tr '\n' ' '))"
# A mount that holds only a linked worktree's checkout, its git directory
# outside every mount: with git, that directory's index would be read.
"${G[@]}" init -q "$TMP/out98" && "${G[@]}" -C "$TMP/out98" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/out98" worktree add -q "$TMP/r98d/wt" \
  || { printf 'SCAFFOLD-FAILED: G98 linked worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/r98d" PATH="$nogit98" launch "$TMP/app"
grep -qF 'protected here (1): includes' "$ERR" \
  && pass "G98 with no git, the WARNING counts a protected .git file too" \
  || fail "G98 no WARNING for a lone .git file (rc=$LAUNCH_RC; stderr: $(grep -A2 -F 'WARNING' "$ERR" | tr '\n' ' '))"
rm -rf "$R98" "$TMP/r98b" "$TMP/r98c" "$TMP/r98d" "$TMP/out98" "$TMP/nogit98" "$TMP/brokengit98" "$TMP/brokengit98.log" "$TMP/mutegit98"

# ── G120: a core.hooksPath is judged as git takes it (GIT-35) ─────────────────
# It was resolved through every link and judged by where it ended, from config
# alone, relative to the directory the .git lies in. So the agent could silence
# the NOTE a writable hooks directory gets by making husky's .husky/_ a link to
# any directory of the host, and repoint it in the session (re-review of the
# GIT-39 fix); a `..` out of a directory it can swap went unnamed; and a
# core.hooksPath set by an include, by config.worktree, or relative to a
# core.worktree, was not looked at. Its way is walked as an include's is.
mk120() {
  rm -rf "$TMP/h120" "$TMP/o120"; mkdir -p "$TMP/h120" "$TMP/o120/hooks" && "${G[@]}" init -q "$TMP/h120/r" \
    || { printf 'SCAFFOLD-FAILED: G120\n'; exit 1; }
}
way120() {  # $1 = label, $2 = where the hooks are, $3 = the line naming the step
  grep -qF "$3" <<<"$(grep -A1 -F "runs its git hooks from $2 (core.hooksPath), and the agent can change the way there:" "$ERR")" \
    && pass "G120 $1" \
    || fail "G120 $1 (rc=$LAUNCH_RC; stderr: $(grep -A1 -F 'git hooks from' "$ERR" | head -2 | tr '\n' ' '))"
}
mk120; mkdir -p "$TMP/h120/r/.husky" && ln -s "$TMP/o120/hooks" "$TMP/h120/r/.husky/_" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath .husky/_ || { printf 'SCAFFOLD-FAILED: G120 husky\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
way120 "a husky .husky/_ made a link to a directory of the host is named, with the link" "$TMP/o120/hooks" \
  "it can repoint $TMP/h120/r/.husky/_ (at /workspace/h120/r/.husky/_), a link on its way."
mk120; mkdir -p "$TMP/h120/sub" && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$TMP/h120/sub/../../o120/hooks" \
  || { printf 'SCAFFOLD-FAILED: G120 ..\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
way120 "a core.hooksPath that steps out (..) of a directory the agent can swap is named" "$TMP/o120/hooks" \
  "it can replace $TMP/h120/sub (at /workspace/h120/sub) with a link"
mk120; mkdir -p "$TMP/h120/hk" && printf '[core]\n\thooksPath = %s\n' "$TMP/h120/hk" > "$TMP/o120/inc.cfg" \
  && "${G[@]}" -C "$TMP/h120/r" config include.path "$TMP/o120/inc.cfg" || { printf 'SCAFFOLD-FAILED: G120 include\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF "NOTE: /workspace/h120/r/.git runs its git hooks from /workspace/h120/hk (core.hooksPath), which the agent" "$ERR" \
  && pass "G120 a core.hooksPath set by an included file is judged" \
  || fail "G120 hooksPath from an include (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
mk120; mkdir -p "$TMP/h120/hk" && "${G[@]}" -C "$TMP/h120/r" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$TMP/h120/r" config --worktree core.hooksPath "$TMP/h120/hk" || { printf 'SCAFFOLD-FAILED: G120 config.worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF "NOTE: /workspace/h120/r/.git runs its git hooks from /workspace/h120/hk (core.hooksPath), which the agent" "$ERR" \
  && pass "G120 a core.hooksPath set in config.worktree, which git reads, is judged" \
  || fail "G120 hooksPath from config.worktree (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
mk120; mkdir -p "$TMP/h120/wt" && "${G[@]}" -C "$TMP/h120/r" config core.worktree "$TMP/h120/wt" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath .husky/_ || { printf 'SCAFFOLD-FAILED: G120 core.worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/h120/wt/.husky/_ (core.hooksPath)" "$ERR" \
  && pass "G120 a relative core.hooksPath is judged from the core.worktree git runs hooks in" \
  || fail "G120 hooksPath from core.worktree (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# Two ways to the hooks that the agent can change at the same step name it once:
# a core.worktree that is where the .git lies.
mk120; "${G[@]}" -C "$TMP/h120/r" config core.worktree "$TMP/h120/r" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath .husky/_ || { printf 'SCAFFOLD-FAILED: G120 once\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$(grep -c 'runs its git hooks from /workspace/h120/r/.husky/_ (core.hooksPath)' "$ERR")" == 1 ]] \
  && pass "G120 two ways to the hooks the agent can change at the same step are named once" \
  || fail "G120 named $(grep -c 'runs its git hooks from /workspace/h120/r/.husky/_' "$ERR") times"
# With core.hooksPath set, git does not run what hooks/ holds: a link there is
# not named.
mk120; printf '#!/bin/sh\n' > "$TMP/h120/w.sh" && ln -s ../../../w.sh "$TMP/h120/r/.git/hooks/pre-commit" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$TMP/o120/hooks" || { printf 'SCAFFOLD-FAILED: G120 hooks/\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'hooks/pre-commit, a hook your host' "$ERR" \
  && pass "G120 with core.hooksPath set, a link in hooks/, which git does not run, is not named" \
  || fail "G120 hooks/ walked with core.hooksPath set (rc=$LAUNCH_RC; stderr: $(grep -F 'pre-commit' "$ERR" | head -1))"
mk120; "${G[@]}" -C "$TMP/h120/r" config core.hooksPath '~root/hooks' || { printf 'SCAFFOLD-FAILED: G120 ~user\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF "NOTE: /workspace/h120/r/.git takes its git hooks from ~root/hooks (core.hooksPath), which the launcher does not expand" "$ERR" \
  && pass "G120 a core.hooksPath in a form the launcher does not expand (~user/) is named as not judged" \
  || fail "G120 ~user/ (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# The way to a core.worktree is walked too: a submodule whose checkout the agent
# moved aside and replaced with a link to a directory of the host was silent, and
# repointed in the session its hooks ran (review of the GIT-35 fix).
mk120; "${G[@]}" init -q "$TMP/h120/sup" && mkdir -p "$TMP/h120/sup/.git/modules" && "${G[@]}" init -q --separate-git-dir "$TMP/h120/sup/.git/modules/sub" "$TMP/h120/sup/realsub" \
  && "${G[@]}" config --file "$TMP/h120/sup/.git/modules/sub/config" core.worktree ../../../sub \
  && "${G[@]}" config --file "$TMP/h120/sup/.git/modules/sub/config" core.hooksPath .husky/_ \
  && ln -s "$TMP/o120" "$TMP/h120/sup/sub" || { printf 'SCAFFOLD-FAILED: G120 submodule\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
way120 "a submodule's core.worktree made a link the agent can repoint is named" "$TMP/o120/.husky/_" \
  "it can repoint $TMP/h120/sup/sub (at /workspace/h120/sup/sub), a link on its way."
# Every way is judged before one is skipped as named: from where the .git lies
# the hooks are out of reach, and from the core.worktree the way steps out of a
# directory the agent can swap, to the same place.
mk120; mkdir -p "$TMP/h120/wt" && "${G[@]}" -C "$TMP/h120/r" config core.worktree "$TMP/h120/wt" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath ../../o120/hooks || { printf 'SCAFFOLD-FAILED: G120 every way\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
way120 "a way the agent can change is named though another way reaches the same hooks" "$TMP/o120/hooks" \
  "it can replace $TMP/h120/wt (at /workspace/h120/wt) with a link"
# A core.hooksPath git may not use — from an includeIf whose condition may not
# hold, or :(optional), which git 2.52 and later fall back from — leaves hooks/
# walked; a value written :(optional) is judged with it and without it.
mk120; printf '#!/bin/sh\n' > "$TMP/h120/w.sh" && ln -s ../../../w.sh "$TMP/h120/r/.git/hooks/pre-commit" \
  && printf '[core]\n\thooksPath = %s\n' "$TMP/o120/hooks" > "$TMP/o120/inc.cfg" \
  && "${G[@]}" -C "$TMP/h120/r" config includeIf.onbranch:no-such-branch.path "$TMP/o120/inc.cfg" \
  || { printf 'SCAFFOLD-FAILED: G120 includeIf\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF 'NOTE: /workspace/h120/r/.git/hooks/pre-commit, a hook your host' "$ERR" \
  && pass "G120 a core.hooksPath from an includeIf leaves the hooks in hooks/ judged" \
  || fail "G120 includeIf hid hooks/ (rc=$LAUNCH_RC; stderr: $(grep -F 'pre-commit' "$ERR" | head -1))"
mk120; mkdir -p "$TMP/h120/hk" && printf '#!/bin/sh\n' > "$TMP/h120/w.sh" && ln -s ../../../w.sh "$TMP/h120/r/.git/hooks/pre-commit" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath ":(optional)$TMP/h120/hk" || { printf 'SCAFFOLD-FAILED: G120 optional\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF "NOTE: /workspace/h120/r/.git runs its git hooks from /workspace/h120/hk (core.hooksPath), which the agent" "$ERR" \
  && grep -qF 'NOTE: /workspace/h120/r/.git/hooks/pre-commit, a hook your host' "$ERR" \
  && pass "G120 a core.hooksPath written :(optional) is judged without it, as git 2.52 takes it, and hooks/ too" \
  || fail "G120 :(optional) (rc=$LAUNCH_RC; stderr: $(grep -E 'git hooks|pre-commit' "$ERR" | head -2 | tr '\n' ' '))"
# One read per config file: the include walk's gives core.hooksPath too. A
# stand-in git counts reads of it alone, on a launch after the first protection
# (which reads it once, to name the hooks already there).
mk120; mkdir -p "$TMP/g120" && printf '[user]\n' > "$TMP/o120/inc.cfg" && "${G[@]}" -C "$TMP/h120/r" config include.path "$TMP/o120/inc.cfg" \
  && printf '#!/bin/bash\ncase " $* " in *" core.hooksPath"*) echo x >> %q;; esac\nexec %q "$@"\n' "$TMP/g120/log" "$(command -v git)" > "$TMP/g120/git" \
  && chmod +x "$TMP/g120/git" && : > "$TMP/g120/log" || { printf 'SCAFFOLD-FAILED: G120 reads\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"; PATH="$TMP/g120:$PATH" EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 && ! -s "$TMP/g120/log" ]] \
  && pass "G120 core.hooksPath costs no read of its own: the include walk's read gives it" \
  || fail "G120 $(wc -l < "$TMP/g120/log") reads of core.hooksPath alone (rc=$LAUNCH_RC)"
rm -rf "$TMP/g120"
# What the check costs is bounded, as the include walk's is (re-review of the
# GIT-35 fix: values times worktrees took a planted repository's launch from
# 0.9 s to 64 s). git takes core.worktree from the config and config.worktree
# alone, never from a file they include, so neither does the check.
mk120; mkdir -p "$TMP/h120/wt2" && printf '[core]\n\tworktree = %s\n' "$TMP/h120/wt2" > "$TMP/o120/inc.cfg" \
  && "${G[@]}" -C "$TMP/h120/r" config include.path "$TMP/o120/inc.cfg" && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath .husky/_ \
  && [[ "$("${G[@]}" -C "$TMP/h120/r" rev-parse --show-toplevel)" == "$TMP/h120/r" ]] \
  || { printf 'SCAFFOLD-FAILED: G120 included core.worktree (does this git take one from an include?)\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF 'runs its git hooks from /workspace/h120/r/.husky/_' "$ERR" && ! grep -qF '/workspace/h120/wt2' "$ERR" \
  && pass "G120 a core.worktree from an included file, which git ignores, is no base" \
  || fail "G120 included core.worktree taken (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# A value with hundreds of components is not walked, and named once, whatever
# the number of worktrees it is judged from.
mk120; mkdir -p "$TMP/h120/wt" && "${G[@]}" -C "$TMP/h120/r" config core.worktree "$TMP/h120/wt" \
  && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$(printf 'a/%.0s' $(seq 1 200))h" || { printf 'SCAFFOLD-FAILED: G120 deep\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$(grep -c 'whose way has too many' "$ERR")" == 1 ]] \
  && pass "G120 a core.hooksPath with hundreds of components is not walked, and is named once" \
  || fail "G120 deep core.hooksPath named $(grep -c 'whose way has too many' "$ERR") times (rc=$LAUNCH_RC)"
# One longer than git can open (PATH_MAX) runs nothing, and is not named.
mk120; "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$(printf 'a%.0s' $(seq 1 4100))" || { printf 'SCAFFOLD-FAILED: G120 long\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'git hooks from' "$ERR" && ! grep -qF 'takes its git hooks' "$ERR" \
  && pass "G120 a core.hooksPath longer than git can open is not named" \
  || fail "G120 long value named (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1 | cut -c1-120))"
# A way not followed to the end (a link loop the agent cannot repoint, in a
# planted launcher) is named once, whatever the number of worktrees it is
# judged from: here the .git's directory, and a core.worktree naming it again.
mk120; mkdir -p "$TMP/h120/L" && : > "$TMP/h120/L/sandbox.sh" && : > "$TMP/h120/L/sandbox-common.sh" && ln -s loop "$TMP/h120/L/loop" \
  && "${G[@]}" -C "$TMP/h120/r" config core.worktree "$TMP/h120/r" && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath ../L/loop/h \
  || { printf 'SCAFFOLD-FAILED: G120 loop\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$(grep -c 'its way was not followed to the end' "$ERR")" == 1 ]] \
  && pass "G120 a way not followed to the end is named once, from however many worktrees" \
  || fail "G120 loop named $(grep -c 'its way was not followed to the end' "$ERR") times (rc=$LAUNCH_RC)"
# Each way counts in the launch's budget, which the include walk spends too;
# past it, a WARNING says which repository's core.hooksPath was not judged —
# each one whose include walk the budget cut, its core.hooksPath set past the cut.
mk120; for n in $(seq 1 13); do
  "${G[@]}" init -q "$TMP/h120/b$n" \
    && { printf '[include]\n'; for m in $(seq 1 90); do printf '\tpath = /nonexistent120/f%d\n' "$m"; done; printf '[core]\n\thooksPath = .husky/_\n'; } >> "$TMP/h120/b$n/.git/config" \
    || { printf 'SCAFFOLD-FAILED: G120 budget\n'; exit 1; }
done
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
cut120="$(sed -n 's|^WARNING: not every include of \(/workspace/h120/b[0-9]*/.git\)/config was followed.*|\1|p' "$ERR")"; miss120=""
for x in $cut120; do grep -qF "WARNING: not every core.hooksPath of $x was judged" "$ERR" || miss120+=" $x"; done
[[ -n "$cut120" && -z "$miss120" ]] \
  && pass "G120 core.hooksPath ways count in the launch's budget, and each repository past it is named" \
  || fail "G120 hooksPath budget (rc=$LAUNCH_RC; include cuts: $(tr '\n' ' ' <<<"$cut120"); not named:${miss120:- none})"
# A core.hooksPath after the point where a config's walk was cut is still judged,
# and core entries count in the config's own budget.
mk120; { printf '[include]\n'; for m in $(seq 1 101); do printf '\tpath = /nonexistent120/f%d\n' "$m"; done; printf '[core]\n\thooksPath = .husky/_\n'; } >> "$TMP/h120/r/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G120 cut\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF 'not every include of /workspace/h120/r/.git/config was followed' "$ERR" && grep -qF 'runs its git hooks from /workspace/h120/r/.husky/_' "$ERR" \
  && pass "G120 a core.hooksPath past the point where its config's walk was cut is still judged" \
  || fail "G120 hooksPath after a cut (rc=$LAUNCH_RC; stderr: $(grep -E 'not every|git hooks' "$ERR" | head -2 | tr '\n' ' '))"
mk120; printf '#!/bin/sh\n' > "$TMP/h120/inc.cfg" && { printf '[core]\n'; for m in $(seq 1 150); do printf '\thooksPath = .husky/_\n'; done; printf '[include]\n\tpath = %s\n' "$TMP/h120/inc.cfg"; } >> "$TMP/h120/r/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G120 core entries\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF 'not every include of /workspace/h120/r/.git/config was followed' "$ERR" && grep -qF 'runs its git hooks from /workspace/h120/r/.husky/_' "$ERR" \
  && pass "G120 core.hooksPath entries count in a config's budget, and the last is still judged" \
  || fail "G120 core entries uncounted (rc=$LAUNCH_RC; stderr: $(grep -E 'not every|git hooks|inc.cfg' "$ERR" | head -2 | tr '\n' ' '))"
# ... and with it: to a git older than 2.52 (Ubuntu 24.04's 2.43, Apple's) it is
# part of a relative path, which the agent can make. Both are judged whatever
# the git the launcher finds, since a host can hold two (third review).
mk120; "${G[@]}" -C "$TMP/h120/r" config core.hooksPath ':(optional).hk' || { printf 'SCAFFOLD-FAILED: G120 old git\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -qF 'runs its git hooks from /workspace/h120/r/:(optional).hk (core.hooksPath)' "$ERR" \
  && grep -qF 'runs its git hooks from /workspace/h120/r/.hk (core.hooksPath)' "$ERR" \
  && pass "G120 a core.hooksPath written :(optional) is judged with it too, as a git older than 2.52 takes it" \
  || fail "G120 :(optional) one reading (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# A core.hooksPath directory is walked once a launch, however many repositories
# name it, and its walks count in the launch's budget, past which a WARNING names
# the repository: hundreds of planted ways took a launch from 1.7 s to 161 s, in
# silence (third review of the GIT-35 fix).
mk120; printf '#!/bin/sh\n' > "$TMP/h120/w.sh" && ln -s "$TMP/h120/w.sh" "$TMP/o120/hooks/pre-commit" \
  && "${G[@]}" init -q "$TMP/h120/r2" && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$TMP/o120/hooks" \
  && "${G[@]}" -C "$TMP/h120/r2" config core.hooksPath "$TMP/o120/hooks" || { printf 'SCAFFOLD-FAILED: G120 once a launch\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$(grep -c "NOTE: $TMP/o120/hooks/pre-commit, a hook your host" "$ERR")" == 1 ]] \
  && pass "G120 a core.hooksPath directory two repositories name is walked once" \
  || fail "G120 walked $(grep -c "NOTE: $TMP/o120/hooks/pre-commit, a hook your host" "$ERR") times"
mk120; for n in $(seq 1 35); do
  "${G[@]}" init -q "$TMP/h120/k$n" && mkdir -p "$TMP/o120/k$n" \
    && for e in pre-commit post-commit pre-push post-merge post-checkout commit-msg prepare-commit-msg pre-rebase post-rewrite \
         applypatch-msg pre-applypatch post-applypatch pre-merge-commit pre-receive update proc-receive post-receive post-update \
         reference-transaction push-to-checkout pre-auto-gc sendemail-validate fsmonitor-watchman p4-changelist \
         p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change; do : > "$TMP/o120/k$n/$e"; done \
    && "${G[@]}" -C "$TMP/h120/k$n" config core.hooksPath "$TMP/o120/k$n" || { printf 'SCAFFOLD-FAILED: G120 hook budget\n'; exit 1; }
done
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -q "WARNING: not every hook in the core.hooksPath directories of /workspace/h120/k[0-9]*/.git was checked" "$ERR" \
  && pass "G120 hooks in core.hooksPath directories count in the launch's budget, and one past it is named" \
  || fail "G120 hook walks unbounded (rc=$LAUNCH_RC; $(grep -c 'not every' "$ERR") cut warnings)"
# A link on the way that the agent cannot repoint — in a planted launcher, under
# a read-only overlay — to a directory outside every mount: nothing to name.
mk120; mkdir -p "$TMP/h120/L" && : > "$TMP/h120/L/sandbox.sh" && : > "$TMP/h120/L/sandbox-common.sh" \
  && ln -s "$TMP/o120/hooks" "$TMP/h120/L/hk" && "${G[@]}" -C "$TMP/h120/r" config core.hooksPath "$TMP/h120/L/hk" \
  || { printf 'SCAFFOLD-FAILED: G120 read-only link\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'git hooks from' "$ERR" \
  && pass "G120 a core.hooksPath through a link under a read-only overlay, to a directory outside every mount, is not named" \
  || fail "G120 read-only link named (rc=$LAUNCH_RC; stderr: $(grep -A1 -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/h120" "$TMP/o120"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
