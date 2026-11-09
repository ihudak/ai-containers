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
# Each value written :(optional), so git may run hooks/ too, which is still
# walked past the budget: it is the repository's own, and was skipped with the
# rest (automated security review of fe955c3).
mk120; printf '#!/bin/sh\n' > "$TMP/h120/w.sh"; for n in $(seq 1 35); do
  "${G[@]}" init -q "$TMP/h120/k$n" && mkdir -p "$TMP/o120/k$n" && ln -s ../../../w.sh "$TMP/h120/k$n/.git/hooks/pre-commit" \
    && for e in pre-commit post-commit pre-push post-merge post-checkout commit-msg prepare-commit-msg pre-rebase post-rewrite \
         applypatch-msg pre-applypatch post-applypatch pre-merge-commit pre-receive update proc-receive post-receive post-update \
         reference-transaction push-to-checkout pre-auto-gc sendemail-validate fsmonitor-watchman p4-changelist \
         p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change; do : > "$TMP/o120/k$n/$e"; done \
    && "${G[@]}" -C "$TMP/h120/k$n" config core.hooksPath ":(optional)$TMP/o120/k$n" || { printf 'SCAFFOLD-FAILED: G120 hook budget\n'; exit 1; }
done
EXTRA_MOUNTS="$TMP/h120" launch "$TMP/app"
grep -q "WARNING: not every hook in the hook directories of /workspace/h120/k[0-9]*/.git was checked" "$ERR" \
  && pass "G120 hooks in core.hooksPath directories count in the launch's budget, and one past it is named" \
  || fail "G120 hook walks unbounded (rc=$LAUNCH_RC; $(grep -c 'not every' "$ERR") cut warnings)"
cut120="$(sed -n 's|^WARNING: not every hook in the hook directories of \(/workspace/h120/k[0-9]*/.git\) was checked.*|\1|p' "$ERR")"; miss120=""
for x in $cut120; do grep -qF "NOTE: $x/hooks/pre-commit, a hook your host's git runs, is a link the agent can redirect" "$ERR" || miss120+=" $x"; done
[[ -n "$cut120" && -z "$miss120" ]] \
  && pass "G120 past the budget, the repository's own hooks/ is still walked where git may run it" \
  || fail "G120 hooks/ skipped past the budget (cut: $(tr '\n' ' ' <<<"$cut120"); hooks/ not walked:${miss120:- none})"
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

# ── G126: a git directory whose worktree lies elsewhere is judged (GIT-44) ─────
# Only the git directories a launch protects, or finds under a read-only overlay,
# had their config judged, and a linked worktree's core.hooksPath not even then.
# So with only a linked worktree mounted (husky's layout under `git worktree`),
# its repository outside every mount with core.hooksPath=.husky/_, the agent
# wrote feature/.husky/_/pre-commit and the host's next commit there ran it. A
# --separate-git-dir checkout was the same, and inside the mounts a linked
# worktree's config.worktree, and a relative path from a linked worktree or from
# a separate git directory's checkout, went unjudged (reviews of the GIT-35 fix).
mk121() {
  rm -rf "$TMP/h121" "$TMP/o121"; mkdir -p "$TMP/h121" "$TMP/o121" \
    && "${G[@]}" init -q "$TMP/o121/main" && "${G[@]}" -C "$TMP/o121/main" commit -q --allow-empty -m i \
    || { printf 'SCAFFOLD-FAILED: G126\n'; exit 1; }
}
mk121; "${G[@]}" -C "$TMP/o121/main" worktree add -q "$TMP/h121/feature" || { printf 'SCAFFOLD-FAILED: G126 quiet\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/o121" "$ERR" && ! grep -qF 'git hooks from' "$ERR" \
  && pass "G126 a linked worktree mounted alone, its repository setting nothing, is quiet" \
  || fail "G126 noise (rc=$LAUNCH_RC; stderr: $(grep -E 'o121|git hooks' "$ERR" | head -2 | tr '\n' ' '))"
"${G[@]}" -C "$TMP/o121/main" config core.hooksPath .husky/_ || { printf 'SCAFFOLD-FAILED: G126 husky\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/h121/feature/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a linked worktree mounted alone: its repository's core.hooksPath is judged from the worktree" \
  || fail "G126 linked worktree, repository outside (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
printf '#!/bin/sh\n' > "$TMP/h121/w.sh" && ln -s "$TMP/h121/w.sh" "$TMP/o121/main/.git/hooks/pre-commit" \
  && "${G[@]}" -C "$TMP/o121/main" config --unset core.hooksPath && printf '[user]\n' > "$TMP/h121/inc.cfg" \
  && "${G[@]}" -C "$TMP/o121/main" config include.path "$TMP/h121/inc.cfg" || { printf 'SCAFFOLD-FAILED: G126 hooks, include\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "NOTE: $TMP/o121/main/.git/hooks/pre-commit, a hook your host's git runs, is a link the agent can redirect" "$ERR" \
  && pass "G126 that repository's hook linking into a writable mount is named" \
  || fail "G126 hook link of the repository outside (rc=$LAUNCH_RC; stderr: $(grep -F 'pre-commit' "$ERR" | head -1))"
grep -qF "WARNING: $TMP/o121/main/.git/config includes $TMP/h121/inc.cfg (include.path), which the agent can redirect" "$ERR" \
  && pass "G126 that repository's include of a writable file is named" \
  || fail "G126 include of the repository outside (rc=$LAUNCH_RC; stderr: $(grep -F 'includes' "$ERR" | head -1))"
mk121; "${G[@]}" -C "$TMP/o121/main" worktree add -q "$TMP/h121/feature" && printf '[user]\n' > "$TMP/h121/cfg" \
  && mv "$TMP/o121/main/.git/config" "$TMP/h121/cfg" && ln -s "$TMP/h121/cfg" "$TMP/o121/main/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G126 config link\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "WARNING: $TMP/o121/main/.git/config, outside every writable mount, leads somewhere the agent can change" "$ERR" \
  && pass "G126 that repository's config, a link into a writable mount, is named" \
  || fail "G126 config link of the repository outside (rc=$LAUNCH_RC; stderr: $(grep -F 'o121' "$ERR" | head -1))"
mk121; "${G[@]}" init -q --separate-git-dir "$TMP/o121/sep.git" "$TMP/h121/sep" && "${G[@]}" -C "$TMP/h121/sep" config core.hooksPath .husky/_ \
  || { printf 'SCAFFOLD-FAILED: G126 separate outside\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/h121/sep/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a --separate-git-dir checkout mounted alone: its core.hooksPath is judged from the checkout" \
  || fail "G126 separate git dir outside (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# Inside the mounts.
mk121; mkdir -p "$TMP/h121/hk" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/wt" && "${G[@]}" -C "$TMP/h121/m" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$TMP/h121/wt" config --worktree core.hooksPath "$TMP/h121/hk" || { printf 'SCAFFOLD-FAILED: G126 config.worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt runs its git hooks from /workspace/h121/hk (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a linked worktree's own config.worktree core.hooksPath is judged" \
  || fail "G126 linked worktree's config.worktree (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# A config of a linked worktree's own, which git never reads, is not judged.
mk121; mkdir -p "$TMP/h121/hk" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/wt" \
  && printf '[core]\n\thooksPath = %s\n' "$TMP/h121/hk" > "$TMP/h121/m/.git/worktrees/wt/config" || { printf 'SCAFFOLD-FAILED: G126 decoy\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF 'git hooks from /workspace/h121/hk' "$ERR" \
  && pass "G126 a config in a linked worktree's git directory, which git ignores, is not judged" \
  || fail "G126 decoy config judged (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
mk121; mkdir -p "$TMP/o121/hooks" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && mkdir -p "$TMP/h121/a" && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/a/wt" \
  && "${G[@]}" -C "$TMP/h121/m" config core.hooksPath ../../o121/hooks || { printf 'SCAFFOLD-FAILED: G126 relative\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt runs its git hooks from /workspace/h121/o121/hooks (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a relative core.hooksPath is judged from a linked worktree's checkout" \
  || fail "G126 relative from a linked worktree (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# A linked worktree whose checkout lies outside every mount, its git directory
# inside one: judged from that checkout, which its gitdir names.
mk121; mkdir -p "$TMP/o121/a" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/o121/a/wt" && "${G[@]}" -C "$TMP/h121/m" config core.hooksPath ../../../h121/x \
  || { printf 'SCAFFOLD-FAILED: G126 gitdir\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt runs its git hooks from /workspace/h121/x (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a relative core.hooksPath is judged from a linked worktree's checkout outside every mount" \
  || fail "G126 linked worktree's checkout outside (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
mk121; mkdir -p "$TMP/h121/a/b" && "${G[@]}" init -q --separate-git-dir "$TMP/h121/r.git" "$TMP/h121/a/b/r" \
  && "${G[@]}" -C "$TMP/h121/a/b/r" config core.hooksPath ../../hooks || { printf 'SCAFFOLD-FAILED: G126 separate inside\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/h121/a/hooks (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a relative core.hooksPath is judged from a separate git directory's checkout" \
  || fail "G126 separate git dir inside (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# The repository a mount lies in, when the mount is a subdirectory of one:
# husky's layout for a project not at the git root keeps its hooks there
# (review of the GIT-44 fix).
mk121; mkdir -p "$TMP/o121/proj/frontend" && "${G[@]}" init -q "$TMP/o121/proj" \
  && "${G[@]}" -C "$TMP/o121/proj" config core.hooksPath frontend/.husky/_ || { printf 'SCAFFOLD-FAILED: G126 enclosing\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o121/proj/frontend" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/frontend/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 the repository a mount lies in: its core.hooksPath into the mount is judged" \
  || fail "G126 enclosing repository (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# Through a link whose own way out is safe: what it leads to is what git reads.
mk121; "${G[@]}" -C "$TMP/o121/main" worktree add -q "$TMP/h121/feature" && printf '[user]\n' > "$TMP/h121/feature/inc.cfg" \
  && mv "$TMP/o121/main/.git/config" "$TMP/o121/cfg2" && ln -s "$TMP/o121/cfg2" "$TMP/o121/main/.git/config" \
  && "${G[@]}" config --file "$TMP/o121/cfg2" include.path "$TMP/h121/feature/inc.cfg" \
  && mkdir -p "$TMP/o121/hk2" && printf '#!/bin/sh\n' > "$TMP/h121/w.sh" && ln -s "$TMP/h121/w.sh" "$TMP/o121/hk2/pre-commit" \
  && rm -rf "$TMP/o121/main/.git/hooks" && ln -s "$TMP/o121/hk2" "$TMP/o121/main/.git/hooks" || { printf 'SCAFFOLD-FAILED: G126 through links\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "WARNING: $TMP/o121/main/.git/config includes $TMP/h121/feature/inc.cfg (include.path), which the agent can redirect" "$ERR" \
  && pass "G126 a repository outside every mount: an include in a config reached through a link is judged" \
  || fail "G126 config through a link (rc=$LAUNCH_RC; stderr: $(grep -F 'includes' "$ERR" | head -1))"
grep -qF "NOTE: $TMP/o121/main/.git/hooks/pre-commit, a hook your host's git runs, is a link the agent can redirect" "$ERR" \
  && pass "G126 a repository outside every mount: a hook in hooks/ reached through a link is judged" \
  || fail "G126 hooks through a link (rc=$LAUNCH_RC; stderr: $(grep -F 'pre-commit' "$ERR" | head -1))"
# Its hooks/, bound by nothing, is walked as a core.hooksPath directory is: a
# hook file there with another name in a writable mount is named.
mk121; "${G[@]}" -C "$TMP/o121/main" worktree add -q "$TMP/h121/feature" && printf '#!/bin/sh\n' > "$TMP/o121/main/.git/hooks/pre-commit" \
  && ln "$TMP/o121/main/.git/hooks/pre-commit" "$TMP/h121/side" || { printf 'SCAFFOLD-FAILED: G126 hook file\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "it can write $TMP/o121/main/.git/hooks/pre-commit through another name of that file, in $TMP/h121" "$ERR" \
  && pass "G126 a repository outside every mount: a hook file with another name in a writable mount is named" \
  || fail "G126 hook file with a second name (rc=$LAUNCH_RC; stderr: $(grep -A1 -F 'pre-commit' "$ERR" | head -2 | tr '\n' ' '))"
# Only git directories, as git takes them; at most SANDBOX_GIT_MAX, the rest
# named. The .git files lie in a planted launcher, where they count toward
# nothing else.
mk121; mkdir -p "$TMP/h121/L" "$TMP/o121/plain" && : > "$TMP/h121/L/sandbox.sh" && : > "$TMP/h121/L/sandbox-common.sh" \
  && printf '[core]\n\thooksPath = x\n' > "$TMP/o121/plain/config" && mkdir -p "$TMP/h121/p0" \
  && printf 'gitdir: %s\n' "$TMP/o121/plain" > "$TMP/h121/p0/.git" || { printf 'SCAFFOLD-FAILED: G126 plain\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/o121/plain" "$ERR" && ! grep -qF 'git hooks from' "$ERR" \
  && pass "G126 a .git file naming a directory that is not a git directory has nothing judged there" \
  || fail "G126 plain directory judged (rc=$LAUNCH_RC; stderr: $(grep -E 'o121/plain|git hooks' "$ERR" | head -1))"
# Nor a common directory that is not one: a planted .git file naming a
# worktree-shaped directory whose commondir names a plain directory.
mkdir -p "$TMP/o121/fake" "$TMP/o121/plain2" "$TMP/h121/p9" && printf '../plain2\n' > "$TMP/o121/fake/commondir" \
  && printf '[core]\n\thooksPath = y\n' > "$TMP/o121/plain2/config" && printf 'gitdir: %s\n' "$TMP/o121/fake" > "$TMP/h121/p9/.git" \
  || { printf 'SCAFFOLD-FAILED: G126 plain common\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "$TMP/o121/plain2" "$ERR" && ! grep -qF 'git hooks from /workspace/h121/p9/y' "$ERR" \
  && pass "G126 a commondir naming a directory that is not a common directory has nothing judged there" \
  || fail "G126 plain common directory judged (rc=$LAUNCH_RC; stderr: $(grep -E 'plain2|git hooks' "$ERR" | head -1))"
rm -rf "$TMP/h121/p9"
for n in 1 2 3 4 5; do
  "${G[@]}" init -q "$TMP/o121/g$n" && mkdir -p "$TMP/h121/L/p$n" && printf 'gitdir: %s\n' "$TMP/o121/g$n/.git" > "$TMP/h121/L/p$n/.git" \
    || { printf 'SCAFFOLD-FAILED: G126 cap\n'; exit 1; }
done
SANDBOX_GIT_MAX=3 EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF 'WARNING: .git files under read-only overlays here name more than 3 git directories outside' "$ERR" \
  && pass "G126 git directories outside every mount past SANDBOX_GIT_MAX are named, not judged" \
  || fail "G126 cap (rc=$LAUNCH_RC; stderr: $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
# A relative gitdir (git 2.48 and later, worktree.useRelativePaths) is resolved
# from the linked worktree's git directory. That directory is judged too, where
# git runs the hooks of a push into the worktree's checkout (GIT-45; measured,
# git 2.56: it was taken for a place git never runs hooks), and so is it with no
# checkout known, whose own relative core.hooksPath is named as not judged.
mk121; mkdir -p "$TMP/o121/a" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/o121/a/wt" && "${G[@]}" -C "$TMP/h121/m" config core.hooksPath ../../../h121/x \
  && printf '../../../../../o121/a/wt/.git\n' > "$TMP/h121/m/.git/worktrees/wt/gitdir" || { printf 'SCAFFOLD-FAILED: G126 relative gitdir\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt runs its git hooks from /workspace/h121/x (core.hooksPath), which the agent" "$ERR" \
  && [[ "$(grep -F -A3 'git hooks from /workspace/h121/m/h121/x' "$ERR")" == *'git runs them for a push into the repository'* ]] \
  && pass "G126 a relative gitdir is resolved from the linked worktree's git directory, which is judged too, for a push" \
  || fail "G126 relative gitdir (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$TMP/h121/m/.git/worktrees/wt/gitdir"
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF 'git hooks from /workspace/h121/m/h121/x' "$ERR" \
  && grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt takes its git hooks from ../../../h121/x (core.hooksPath) relative to a checkout" "$ERR" \
  && pass "G126 a linked worktree with no checkout known: its relative core.hooksPath named as not judged there, and judged from its git directory, for a push" \
  || fail "G126 git directory taken as a base (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# The re-review of the GIT-44 fix: the repository a mount lies in through a
# .git link (as `repo` checkouts have it), which git follows, was skipped and the
# next repository up judged instead.
mk121; "${G[@]}" init -q "$TMP/o121/repo" && mv "$TMP/o121/repo/.git" "$TMP/o121/proj.git" && mkdir -p "$TMP/o121/proj/frontend" \
  && ln -s ../proj.git "$TMP/o121/proj/.git" && "${G[@]}" -C "$TMP/o121/proj" config core.hooksPath frontend/.husky/_ \
  || { printf 'SCAFFOLD-FAILED: G126 .git link\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o121/proj/frontend" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/frontend/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 the repository a mount lies in, through a .git link, is judged" \
  || fail "G126 enclosing .git link (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
# Through the .git link, its checkout is the worktree its index is read against:
# a submodule under a pruned vendor/ is protected, and no "no worktree is known".
mk121; "${G[@]}" init -q "$TMP/o121/s" && "${G[@]}" -C "$TMP/o121/s" commit -q --allow-empty -m s \
  && "${G[@]}" init -q "$TMP/o121/lp" && "${G[@]}" clone -q "$TMP/o121/s" "$TMP/o121/lp/fe/vendor/lib" \
  && "${G[@]}" -C "$TMP/o121/lp" add fe/vendor/lib 2>/dev/null && "${G[@]}" -C "$TMP/o121/lp" commit -q -m l \
  && mv "$TMP/o121/lp/.git" "$TMP/o121/lp.git" && ln -s ../lp.git "$TMP/o121/lp/.git" || { printf 'SCAFFOLD-FAILED: G126 link index\n'; exit 1; }
EXTRA_MOUNTS="$TMP/o121/lp/fe" launch "$TMP/app"
has_mount "$TMP/o121/lp/fe/vendor/lib/.git/config:/workspace/fe/vendor/lib/.git/config:ro" && ! grep -qF 'no worktree is known' "$ERR" \
  && pass "G126 through a .git link, the repository's index is read against the checkout: its submodule is protected" \
  || fail "G126 .git link's index (rc=$LAUNCH_RC; stderr: $(grep -F 'no worktree' "$ERR" | head -1))"
# ... and a .git link's target inside another writable mount, past its scan, is
# protected there.
mk121; "${G[@]}" init -q "$TMP/o121/tmp" && mkdir -p "$TMP/h121/x/vendor" "$TMP/h121/y/fe" && mv "$TMP/o121/tmp/.git" "$TMP/h121/x/vendor/proj.git" \
  && ln -s "$TMP/h121/x/vendor/proj.git" "$TMP/h121/y/.git" || { printf 'SCAFFOLD-FAILED: G126 link other mount\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121/x $TMP/h121/y/fe" launch "$TMP/app"
has_mount "$TMP/h121/x/vendor/proj.git/config:/workspace/x/vendor/proj.git/config:ro" \
  && pass "G126 a .git link's target inside another writable mount, past its scan, is protected there" \
  || fail "G126 .git link to another mount (rc=$LAUNCH_RC; mounts: $(grep -c 'proj.git' <<<"$(mounts)"))"
# ... and one inside ANOTHER writable mount, past what its scan reaches (vendor/
# is pruned), is protected in that mount's view.
mk121; "${G[@]}" init -q "$TMP/h121/proj" && "${G[@]}" init -q "$TMP/h121/proj/vendor/lib" && mkdir -p "$TMP/h121/proj/vendor/lib/sub" \
  || { printf 'SCAFFOLD-FAILED: G126 other mount\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121/proj $TMP/h121/proj/vendor/lib/sub" launch "$TMP/app"
has_mount "$TMP/h121/proj/vendor/lib/.git/config:/workspace/proj/vendor/lib/.git/config:ro" \
  && pass "G126 the repository a mount lies in, inside another writable mount past its scan, is protected there" \
  || fail "G126 enclosing repository in another mount (rc=$LAUNCH_RC; mounts: $(grep -c 'vendor/lib/.git' <<<"$(mounts)"))"
# Past SANDBOX_GIT_MAX, only those named from under a read-only overlay are cut,
# in the order found: a mounted worktree's repository is judged whatever a
# planted launcher names.
# The planted launcher's mount is scanned first.
mk121; mkdir -p "$TMP/h121/a/L" "$TMP/h121/b" && : > "$TMP/h121/a/L/sandbox.sh" && : > "$TMP/h121/a/L/sandbox-common.sh" \
  || { printf 'SCAFFOLD-FAILED: G126 order\n'; exit 1; }
for n in $(seq 1 12); do
  "${G[@]}" init -q "$TMP/o121/q$n" && mkdir -p "$TMP/h121/a/L/q$n" && printf 'gitdir: %s\n' "$TMP/o121/q$n/.git" > "$TMP/h121/a/L/q$n/.git" \
    || { printf 'SCAFFOLD-FAILED: G126 order\n'; exit 1; }
done
"${G[@]}" -C "$TMP/o121/main" worktree add -q "$TMP/h121/b/feature" && "${G[@]}" -C "$TMP/o121/main" config core.hooksPath .husky/_ \
  || { printf 'SCAFFOLD-FAILED: G126 order worktree\n'; exit 1; }
# ... and named from under an overlay too, in a mount scanned last: the capped
# ones are taken after the others, so it is not cut (final review of the GIT-44
# fix).
mkdir -p "$TMP/h121/c/L2/z1" && : > "$TMP/h121/c/L2/sandbox.sh" && : > "$TMP/h121/c/L2/sandbox-common.sh" \
  && printf 'gitdir: %s\n' "$TMP/o121/main/.git/worktrees/feature" > "$TMP/h121/c/L2/z1/.git" || { printf 'SCAFFOLD-FAILED: G126 order z1\n'; exit 1; }
SANDBOX_GIT_MAX=3 EXTRA_MOUNTS="$TMP/h121/a $TMP/h121/b $TMP/h121/c" launch "$TMP/app"
grep -qF 'WARNING: .git files under read-only overlays here name more than 3 git directories outside' "$ERR" \
  && grep -qF "runs its git hooks from /workspace/b/feature/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 past SANDBOX_GIT_MAX a mounted worktree's repository is still judged; planted ones are cut" \
  || fail "G126 cap order (rc=$LAUNCH_RC; stderr: $(grep -E 'WARNING: .git files|git hooks' "$ERR" | head -2 | tr '\n' ' '))"
# Nor are the repositories mounts lie in, one per mount, whatever their number.
mk121; for n in 1 2 3; do
  "${G[@]}" init -q "$TMP/o121/r$n" && mkdir -p "$TMP/o121/r$n/s$n" && "${G[@]}" -C "$TMP/o121/r$n" config core.hooksPath "s$n/.husky/_" \
    || { printf 'SCAFFOLD-FAILED: G126 enclosing cap\n'; exit 1; }
done
SANDBOX_GIT_MAX=2 EXTRA_MOUNTS="$TMP/o121/r1/s1 $TMP/o121/r2/s2 $TMP/o121/r3/s3" launch "$TMP/app"
n121=0; for n in 1 2 3; do grep -qF "runs its git hooks from /workspace/s$n/.husky/_ (core.hooksPath)" "$ERR" && n121=$((n121 + 1)); done
[[ "$LAUNCH_RC" == 0 && "$n121" == 3 ]] \
  && pass "G126 the repositories mounts lie in are judged past SANDBOX_GIT_MAX: they are one per mount" \
  || fail "G126 enclosing repositories cut ($n121 of 3 judged; rc=$LAUNCH_RC)"
# An absolute core.hooksPath is the same from every worktree, and named once.
mk121; mkdir -p "$TMP/h121/hk" && "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && for n in 1 2 3; do "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/w$n"; done \
  && "${G[@]}" -C "$TMP/h121/m" config core.hooksPath "$TMP/h121/hk" || { printf 'SCAFFOLD-FAILED: G126 absolute\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$(grep -c 'runs its git hooks from /workspace/h121/hk (core.hooksPath)' "$ERR")" == 1 ]] \
  && pass "G126 an absolute core.hooksPath shared by linked worktrees is named once" \
  || fail "G126 named $(grep -c 'runs its git hooks from /workspace/h121/hk (core.hooksPath)' "$ERR") times (rc=$LAUNCH_RC)"
# GIT-46. A linked worktree's gitdir, which names its checkout, is bound
# read-only, as its commondir is: written by the agent, it chose where a relative
# core.hooksPath was judged from (automated security review of c6316af).
mk121; "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/wt" || { printf 'SCAFFOLD-FAILED: G126 gitdir bind\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
has_mount "$TMP/h121/m/.git/worktrees/wt/gitdir:/workspace/h121/m/.git/worktrees/wt/gitdir:ro" \
  && pass "G126 a linked worktree's gitdir is bound read-only" \
  || fail "G126 gitdir writable (rc=$LAUNCH_RC; mounts: $(grep -c 'worktrees/wt/' <<<"$(mounts)"))"
# A gitdir naming a checkout that does not exist — deleted and never pruned, or
# made inside a container with /workspace paths — is judged from where it would
# be: silent outside every mount, named where the agent could make it; never the
# "does not know" NOTE, every launch (final review of the GIT-46 fix).
mk121; "${G[@]}" init -q "$TMP/h121/m" && "${G[@]}" -C "$TMP/h121/m" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/o121/gone" && "${G[@]}" -C "$TMP/h121/m" worktree add -q "$TMP/h121/wt2" \
  && "${G[@]}" -C "$TMP/h121/m" config core.hooksPath .husky/_ && rm -rf "$TMP/o121/gone" "$TMP/h121/wt2" \
  || { printf 'SCAFFOLD-FAILED: G126 gone\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
! grep -qF 'relative to a checkout this launch' "$ERR" && ! grep -qF 'o121/gone' "$ERR" \
  && grep -qF "NOTE: /workspace/h121/m/.git/worktrees/wt2 runs its git hooks from /workspace/h121/wt2/.husky/_ (core.hooksPath)" "$ERR" \
  && pass "G126 a gitdir naming a checkout that is gone is judged from where it would be, and only that is named" \
  || fail "G126 deleted checkouts (rc=$LAUNCH_RC; stderr: $(grep -E 'git hooks|relative to a checkout' "$ERR" | head -3 | tr '\n' ' '))"
# Under a read-only overlay, a hard-linked gitdir refuses the launch, as a
# hard-linked commondir does there.
mk121; mkdir -p "$TMP/h121/pl" "$TMP/h121/vendor" && : > "$TMP/h121/pl/sandbox.sh" && : > "$TMP/h121/pl/sandbox-common.sh" \
  && "${G[@]}" init -q "$TMP/h121/pl/r" && "${G[@]}" -C "$TMP/h121/pl/r" commit -q --allow-empty -m i \
  && "${G[@]}" -C "$TMP/h121/pl/r" worktree add -q "$TMP/h121/vendor/co" && ln "$TMP/h121/pl/r/.git/worktrees/co/gitdir" "$TMP/h121/alias" \
  || { printf 'SCAFFOLD-FAILED: G126 overlay gitdir\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121" launch "$TMP/app"
[[ "$LAUNCH_RC" != 0 ]] && grep -qF "ERROR: $TMP/h121/pl/r/.git/worktrees/co/gitdir has more than one hard link" "$ERR" \
  && pass "G126 under a read-only overlay, a linked worktree's gitdir with a second name refuses the launch" \
  || fail "G126 hard-linked gitdir under an overlay (rc=$LAUNCH_RC; stderr: $(grep -F ERROR "$ERR" | head -1))"
# A .git link whose target lies in the same mount, past what its scan reaches
# (vendor/ is pruned), is protected there, and its core.hooksPath judged from
# the link's checkout; and one in another writable mount is judged from the
# link's checkout too, not from the git directory (final review of c6316af).
mk121; "${G[@]}" init -q "$TMP/o121/tmp" && mkdir -p "$TMP/h121/proj/fe/vendor" && mv "$TMP/o121/tmp/.git" "$TMP/h121/proj/fe/vendor/proj.git" \
  && ln -s fe/vendor/proj.git "$TMP/h121/proj/.git" && "${G[@]}" -C "$TMP/h121/proj" config core.hooksPath fe/.husky/_ \
  || { printf 'SCAFFOLD-FAILED: G126 link same mount\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121/proj/fe" launch "$TMP/app"
has_mount "$TMP/h121/proj/fe/vendor/proj.git/config:/workspace/fe/vendor/proj.git/config:ro" \
  && grep -qF "runs its git hooks from /workspace/fe/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && pass "G126 a .git link's target in the same mount, past its scan, is protected and judged from the checkout" \
  || fail "G126 link target in the same mount (rc=$LAUNCH_RC; mounts: $(grep -c 'proj.git' <<<"$(mounts)"); stderr: $(grep -F 'git hooks' "$ERR" | head -1))"
mk121; "${G[@]}" init -q "$TMP/o121/tmp" && mkdir -p "$TMP/h121/x/vendor" "$TMP/h121/y/fe" && mv "$TMP/o121/tmp/.git" "$TMP/h121/x/vendor/proj.git" \
  && ln -s "$TMP/h121/x/vendor/proj.git" "$TMP/h121/y/.git" && "${G[@]}" config --file "$TMP/h121/x/vendor/proj.git/config" core.hooksPath fe/.husky/_ \
  || { printf 'SCAFFOLD-FAILED: G126 link other mount base\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h121/x $TMP/h121/y/fe" launch "$TMP/app"
grep -qF "runs its git hooks from /workspace/fe/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && ! grep -qF '/workspace/x/vendor/proj.git/fe/.husky/_' "$ERR" \
  && pass "G126 a .git link's target in another writable mount is judged from the link's checkout" \
  || fail "G126 link target judged from its git directory (rc=$LAUNCH_RC; stderr: $(grep -F 'git hooks' "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$TMP/h121" "$TMP/o121"

# ── G132: a relative core.hooksPath from $GIT_DIR, where push hooks run ──────
# git runs the push hooks (pre-receive, update, post-receive, …) in the git
# directory, a non-bare repository's and a linked worktree's too, and a
# relative core.hooksPath is relative to where hooks run (bugs review GIT-45).
# One that stays inside the git directory (no `..`) has its first directory
# there bound read-only, made as you where there is none, so nothing below it
# can be made or changed. One starting with a name git itself keeps there (a
# directory, objects/, logs/, …, or a file, config, HEAD, locked, …) is never
# made or bound, only named. A file or a link on the way refuses the launch;
# hooks already there are named once. One that climbs out of .git is judged
# from it, and named as a push's.
R132="$TMP/p132"
mk132() {  # <hooksPath> — a fresh repository in the writable mount
  rm -rf "$R132"; mkdir -p "$R132" && "${G[@]}" init -q "$R132/r" && "${G[@]}" -C "$R132/r" config core.hooksPath "$1" \
    || { printf 'SCAFFOLD-FAILED: G132\n'; exit 1; }
}
dup132() { mounts | awk -F: '{print $2}' | sort | uniq -d; }
# husky: .git/.husky, made and bound read-only whole; nothing under it bound.
mk132 .husky/_; mkdir -p "$R132/r/.husky/_"
launch "$R132"
if [[ "$LAUNCH_RC" == 0 && -d "$R132/r/.git/.husky" && ! -L "$R132/r/.git/.husky" && -z "$(dup132)" ]] \
   && has_mount "$R132/r/.git/.husky:/workspace/p132/r/.git/.husky:ro" \
   && ! mounts | grep -qF ":/workspace/p132/r/.git/.husky/"; then
  pass "G132 a relative core.hooksPath inside the git directory has its first directory there made and bound read-only"
else
  fail "G132 hooksPath in .git (rc=$LAUNCH_RC; made: $([[ -d "$R132/r/.git/.husky" ]] && echo yes || echo no); git mounts: $(git_mounts | grep -F husky | tr '\n' ' '); $(grep -E 'ERROR|WARNING' "$ERR" | head -2 | tr '\n' ' '))"
fi
grep -qF "runs its git hooks from /workspace/p132/r/.husky/_ (core.hooksPath)" "$ERR" \
  && pass "G132 … and the checkout's .husky/_ is still named, as before" \
  || fail "G132 the worktree's NOTE (stderr: $(grep -F 'hooks from' "$ERR" | tr '\n' ' '))"
# husky's monorepo layout (husky frontend/.husky): .git/frontend.
mk132 frontend/.husky/_
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$R132/r/.git/frontend:/workspace/p132/r/.git/frontend:ro" \
  && ! mounts | grep -qF ":/workspace/p132/r/.git/frontend/" \
  && pass "G132 a deeper one (frontend/.husky/_) has .git/frontend bound read-only, so nothing on its way can be swapped" \
  || fail "G132 frontend/.husky/_ (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F frontend | tr '\n' ' '))"
# .git/hooks, the default spelled from the checkout: from .git, .git/.git,
# bound read-only, and bound once at the next launch too, where the scan finds
# a directory named .git under it.
mk132 .git/hooks
launch "$R132"; launch "$R132"
[[ "$LAUNCH_RC" == 0 && -z "$(dup132)" && ! -e "$R132/r/.git/.git/commondir" ]] \
  && has_mount "$R132/r/.git/.git:/workspace/p132/r/.git/.git:ro" \
  && pass "G132 core.hooksPath=.git/hooks has .git/.git bound read-only, once, launch after launch" \
  || fail "G132 .git/hooks (rc=$LAUNCH_RC; twice: $(dup132 | tr '\n' ' '); git mounts: $(git_mounts | grep -F '.git/.git' | tr '\n' ' '))"
# Under one of git's own directories, or through one of its files: nothing is
# made or bound there, which would break the repository (a .git/logs/HEAD made
# a directory fails every commit; a linked worktree's locked one, git worktree
# list), and it is named.
mk132 info/x
launch "$R132"
[[ "$LAUNCH_RC" == 0 && ! -e "$R132/r/.git/info/x" ]] && ! mounts | grep -qF ":/workspace/p132/r/.git/info" \
  && grep -qF "runs its git hooks from /workspace/p132/r/.git/info/x (core.hooksPath)" "$ERR" \
  && pass "G132 one under .git/info is not made or bound, and is named" \
  || fail "G132 info/x (rc=$LAUNCH_RC; made: $([[ -e "$R132/r/.git/info/x" ]] && echo yes || echo no); git mounts: $(git_mounts | grep -F '/info' | tr '\n' ' '))"
mk132 logs/HEAD/x
launch "$R132"
[[ "$LAUNCH_RC" == 0 && ! -d "$R132/r/.git/logs/HEAD" ]] \
  && pass "G132 logs/HEAD/x in a repository with no commits does not make .git/logs/HEAD a directory" \
  || fail "G132 logs/HEAD/x (rc=$LAUNCH_RC; dir: $([[ -d "$R132/r/.git/logs/HEAD" ]] && echo yes || echo no))"
# HOOKS is not hooks/ where names are compared case-sensitively.
mkdir -p "$TMP/cs132/Ab"
if [[ ! -e "$TMP/cs132/AB" ]]; then
  mk132 HOOKS
  launch "$R132"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$R132/r/.git/HOOKS:/workspace/p132/r/.git/HOOKS:ro" \
    && pass "G132 core.hooksPath=HOOKS is bound read-only where names are case-sensitive, not taken for hooks/" \
    || fail "G132 HOOKS (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -iF '/hooks' | tr '\n' ' '))"
else
  printf 'SKIP: G132 HOOKS — this filesystem ignores case\n'
fi
rm -rf "$TMP/cs132"
# Through one of git's own files (a Rails-style config/git-hooks): nothing is
# made or bound there, and the launch goes on; config.worktree/x, where the
# extension is off and git keeps no such file, is not made a directory either.
mk132 config/git-hooks
launch "$R132"
[[ "$LAUNCH_RC" == 0 && -f "$R132/r/.git/config" ]] && ! mounts | grep -qF ":/workspace/p132/r/.git/config/" \
  && pass "G132 one through .git/config launches, with nothing made or bound there" \
  || fail "G132 config/git-hooks (rc=$LAUNCH_RC; $(grep -aF 'ERROR' "$ERR" | head -1))"
mk132 config.worktree/x
launch "$R132"
[[ "$LAUNCH_RC" == 0 && ! -d "$R132/r/.git/config.worktree" ]] \
  && pass "G132 one through config.worktree, where git keeps no such file, makes nothing there" \
  || fail "G132 config.worktree/x (rc=$LAUNCH_RC; dir: $([[ -d "$R132/r/.git/config.worktree" ]] && echo yes || echo no); $(grep -aF 'ERROR' "$ERR" | head -1))"
# The git directory itself (.) cannot be bound: it is named, for a push.
mk132 .
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "runs its git hooks from /workspace/p132/r/.git (core.hooksPath)" "$ERR" \
  && grep -qF "git runs them for a push into the repository" "$ERR" \
  && pass "G132 core.hooksPath=. is named as a push's, the git directory itself not being bindable" \
  || fail "G132 . (rc=$LAUNCH_RC; stderr: $(grep -F -A2 'hooks from' "$ERR" | tr '\n' ' '))"
# One that cannot be made (the agent made .git read-only in an earlier
# session, to make it writable in the next): refused.
if (( EUID != 0 )); then
  mk132 .husky/_; launch "$R132"; rm -rf "$R132/r/.git/.husky"; chmod a-w "$R132/r/.git"
  launch "$R132"; chmod u+w "$R132/r/.git"
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "cannot make $R132/r/.git/.husky" "$ERR" \
    && pass "G132 a directory that cannot be made refuses the launch" \
    || fail "G132 unmakeable (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); $(grep -aF -A1 'ERROR' "$ERR" | head -2 | tr '\n' ' '))"
else
  printf 'SKIP: G132 a directory that cannot be made — root writes it anyway\n'
fi
# A commondir planted in .git/.husky does not turn the bind off.
mk132 .husky/_; mkdir -p "$R132/r/.git/.husky/_" && printf './\n' > "$R132/r/.git/.husky/commondir"
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$R132/r/.git/.husky:/workspace/p132/r/.git/.husky:ro" \
  && pass "G132 a commondir planted in that directory does not turn its bind off" \
  || fail "G132 planted commondir (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F husky | tr '\n' ' '); $(grep -aF 'ERROR' "$ERR" | head -1))"
# A linked worktree's git directory: a push into its checkout runs hooks there.
mk132 .husky/_; "${G[@]}" -C "$R132/r" commit -q --allow-empty -m init && "${G[@]}" -C "$R132/r" worktree add -q "$R132/wt" \
  || { printf 'SCAFFOLD-FAILED: G132 worktree\n'; exit 1; }
launch "$R132"
[[ "$LAUNCH_RC" == 0 && -z "$(dup132)" ]] && has_mount "$R132/r/.git/worktrees/wt/.husky:/workspace/p132/r/.git/worktrees/wt/.husky:ro" \
  && pass "G132 a linked worktree's git directory gets the same, for a push into its checkout" \
  || fail "G132 linked worktree (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F husky | tr '\n' ' '))"
# A linked worktree's locked/x, with no lock there: not made.
"${G[@]}" -C "$R132/r" config --worktree core.hooksPath locked/x 2>/dev/null || "${G[@]}" -C "$R132/r" config core.hooksPath locked/x
launch "$R132"
[[ "$LAUNCH_RC" == 0 && ! -e "$R132/r/.git/worktrees/wt/locked" ]] \
  && pass "G132 locked/x does not make a linked worktree's locked" \
  || fail "G132 locked/x (rc=$LAUNCH_RC; made: $([[ -e "$R132/r/.git/worktrees/wt/locked" ]] && echo yes || echo no))"
# A value docker cannot be handed (not UTF-8): left to the NOTE, the
# repository keeping all of its own binds.
mk132 $'\xff'/x
launch "$R132"
[[ "$LAUNCH_RC" == 0 && ! -e "$R132/r/.git/"$'\xff' ]] && has_mount "$R132/r/.git/config:/workspace/p132/r/.git/config:ro" \
  && grep -qaF "runs its git hooks from /workspace/p132/r/.git/"$'\xff'"/x" "$ERR" \
  && pass "G132 a value docker cannot be handed is named, and the repository keeps its own binds" \
  || fail "G132 unrepresentable (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F '/r/.git/config' | tr '\n' ' '); $(grep -aE 'WARNING|ERROR' "$ERR" | head -2 | tr '\n' ' '))"
# Hooks already there are named, once: at the first protection, and where an
# earlier engine protected the repository and left the directory writable.
mk132 .husky/_; mkdir -p "$R132/r/.git/.husky/_" && printf '#!/bin/sh\n' > "$R132/r/.git/.husky/_/pre-receive" && chmod +x "$R132/r/.git/.husky/_/pre-receive"
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "holds hooks your host's git runs: pre-receive" "$ERR" && grep -qF "$R132/r/.git/.husky/_" "$ERR" \
  && pass "G132 hooks already in that directory are named" \
  || fail "G132 hooks named (rc=$LAUNCH_RC; stderr: $(grep -F 'NOTE' "$ERR" | tr '\n' ' '))"
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "holds hooks your host's git runs: pre-receive" "$ERR" \
  && pass "G132 … once" \
  || fail "G132 hooks named again (rc=$LAUNCH_RC; stderr: $(grep -F 'NOTE' "$ERR" | tr '\n' ' '))"
rm -rf "$R132"; mkdir -p "$R132" && "${G[@]}" init -q "$R132/r" || { printf 'SCAFFOLD-FAILED: G132 upgrade\n'; exit 1; }
launch "$R132"
"${G[@]}" -C "$R132/r" config core.hooksPath .husky/_ && mkdir -p "$R132/r/.git/.husky/_" \
  && printf '#!/bin/sh\n' > "$R132/r/.git/.husky/_/update" && chmod +x "$R132/r/.git/.husky/_/update"
launch "$R132"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "holds hooks your host's git runs: update" "$ERR" \
  && pass "G132 hooks put there while an earlier launch left it writable are named at the next" \
  || fail "G132 upgrade (rc=$LAUNCH_RC; stderr: $(grep -F 'NOTE' "$ERR" | tr '\n' ' '))"
# A file there, or a link on the way: refused, before docker runs, saying how
# to drop the value.
for kind132 in file link; do
  mk132 .husky/_; mkdir -p "$R132/elsewhere"
  if [[ "$kind132" == file ]]; then mkdir -p "$R132/r/.git/.husky" && : > "$R132/r/.git/.husky/_"; at132="$R132/r/.git/.husky/_"
  else ln -s "$R132/elsewhere" "$R132/r/.git/.husky"; at132="$R132/r/.git/.husky"; fi
  launch "$R132"
  [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -aF "ERROR:" "$ERR" > "$TMP/e132" && grep -qF "$at132" "$TMP/e132" \
    && grep -qF "git config --file $R132/r/.git/config --unset core.hooksPath" "$ERR" \
    && pass "G132 a $kind132 where that directory would be refuses the launch, naming it and the value" \
    || fail "G132 $kind132 there (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); stderr: $(grep -aF -A3 'ERROR' "$ERR" | head -4 | tr '\n' ' '))"
done
# A link to hooks/ there is refused too, not taken for hooks/: the agent could
# plant it before the value is set, and swap it for a directory of hooks in the
# session after.
mk132 .husky/_; ln -s hooks "$R132/r/.git/.husky"
launch "$R132"
[[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -aF "ERROR:" "$ERR" > "$TMP/e132" && grep -qF "$R132/r/.git/.husky is a symlink" "$TMP/e132" \
  && pass "G132 a link to hooks/ where that directory would be refuses the launch too" \
  || fail "G132 link to hooks/ (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); $(grep -aF 'ERROR' "$ERR" | head -1))"
# One that climbs out of .git, into the writable mount: named, for a push. From
# the checkout, the mount's root, it leads out of every mount.
mk132 ../outside132
launch "$R132/r"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "runs its git hooks from /workspace/r/outside132 (core.hooksPath)" "$ERR" \
  && grep -qF "git runs them for a push into the repository" "$ERR" \
  && pass "G132 a relative core.hooksPath that climbs out of .git is judged from it, and named as a push's" \
  || fail "G132 climbing out of .git (rc=$LAUNCH_RC; stderr: $(grep -F -A2 'hooks from' "$ERR" | tr '\n' ' '))"
# A value and one below it (config.worktree's a, config's a/b): .git/a bound
# read-only once, nothing else at or under it; one through a submodule's git
# directory to its hooks/ adds nothing to that directory's own binds.
mk132 a/b; "${G[@]}" -C "$R132/r" config extensions.worktreeConfig true && "${G[@]}" -C "$R132/r" config --worktree core.hooksPath a \
  && "${G[@]}" init -q --bare "$R132/r/.git/modules/sub" || { printf 'SCAFFOLD-FAILED: G132 overlap\n'; exit 1; }
launch "$R132"
if [[ "$LAUNCH_RC" == 0 && -z "$(dup132)" ]] && has_mount "$R132/r/.git/a:/workspace/p132/r/.git/a:ro" \
   && ! mounts | grep -qF ":/workspace/p132/r/.git/a/"; then
  pass "G132 a core.hooksPath below another is bound once, read-only, and nothing is bound twice"
else
  fail "G132 overlap (rc=$LAUNCH_RC; twice: $(dup132 | tr '\n' ' '); under a: $(mounts | grep -F '/.git/a' | tr '\n' ' '))"
fi
"${G[@]}" -C "$R132/r" config --worktree core.hooksPath modules/sub/hooks
launch "$R132"
[[ "$LAUNCH_RC" == 0 && -z "$(dup132)" ]] && has_mount "$R132/r/.git/modules/sub/hooks:/workspace/p132/r/.git/modules/sub/hooks:ro" \
  && pass "G132 one through a submodule's git directory to its hooks/ is left to that directory's own binds" \
  || fail "G132 through a submodule (rc=$LAUNCH_RC; twice: $(dup132 | tr '\n' ' '); $(grep -aF 'ERROR' "$ERR" | head -1))"
rm -rf "$R132" "$TMP/e132"

# ── G133: what the launch must make in a git directory of yours, and cannot ──
# The launch makes what git would honour but a repository lacks — config,
# hooks/, the ./ commondir, config.worktree where the extension is on — so
# there is something to bind read-only. The agent, running as you, can make
# .git read-only in one session, so none of them can be made at the next
# launch, and make it writable again in that session to write one. So one that
# cannot be made in a git directory of yours refuses the launch, naming the
# chmod that undoes it (bugs review GIT-48); another user's gets a WARNING.
R133="$TMP/p133"
mk133() {  # a fresh repository in the writable mount, launched once
  rm -rf "$R133"; mkdir -p "$R133" && "${G[@]}" init -q "$R133/r" || { printf 'SCAFFOLD-FAILED: G133\n'; exit 1; }
  launch "$R133"
  [[ "$LAUNCH_RC" == 0 && -f "$R133/r/.git/commondir" ]] || { printf 'SCAFFOLD-FAILED: G133 first launch (rc=%s)\n' "$LAUNCH_RC"; exit 1; }
}
refused133() {  # <name> <label>: the launch refused, naming it, with docker never run
  chmod a-w "$R133/r/.git"; launch "$R133"; chmod u+w "$R133/r/.git"
  if [[ "$LAUNCH_RC" != 0 && ! -s "$CAPTURE" ]] && grep -qF "cannot make $R133/r/.git/$1," "$ERR" \
     && grep -qF "chmod u+w $R133/r/.git" "$ERR"; then
    pass "G133 $2 that cannot be made in a git directory of yours refuses the launch"
  else
    fail "G133 $2 (rc=$LAUNCH_RC; docker ran: $([[ -s "$CAPTURE" ]] && echo yes || echo no); $(grep -aF -A2 'ERROR' "$ERR" | head -3 | tr '\n' ' '))"
  fi
}
if (( EUID != 0 )); then
  mk133; rm -rf "$R133/r/.git/hooks"; refused133 hooks "a hooks/"
  rm -rf "$R133"; mkdir -p "$R133" && "${G[@]}" init -q "$R133/r" || { printf 'SCAFFOLD-FAILED: G133\n'; exit 1; }
  refused133 commondir "the ./ commondir of a repository launched for the first time"
  mk133; "${G[@]}" -C "$R133/r" config extensions.worktreeConfig true; refused133 config.worktree "a config.worktree, where the extension is on,"
  mk133; rm -f "$R133/r/.git/config"; refused133 config "a config"
  # objects/ moved aside: the .git still counts (review of the GIT-48 fix).
  rm -rf "$R133"; mkdir -p "$R133" && "${G[@]}" init -q "$R133/r" && mv "$R133/r/.git/objects" "$R133/r/.git/o" \
    || { printf 'SCAFFOLD-FAILED: G133 objects\n'; exit 1; }
  refused133 commondir "the ./ commondir of a .git whose objects/ was moved aside"
  # Nothing to make: a read-only .git launches as before.
  mk133; chmod a-w "$R133/r/.git"; launch "$R133"; chmod u+w "$R133/r/.git"
  [[ "$LAUNCH_RC" == 0 ]] && has_mount "$R133/r/.git/config:/workspace/p133/r/.git/config:ro" \
    && pass "G133 a read-only git directory that holds all of them launches" \
    || fail "G133 read-only, nothing to make (rc=$LAUNCH_RC; $(grep -aF 'ERROR' "$ERR" | head -1))"
else
  printf 'SKIP: G133 what cannot be made in a git directory of yours — root writes it anyway\n'
fi
# A .git whose objects/ is moved aside, and an empty .git the agent planted, get
# what the launch makes, bound read-only: with objects/ back, or a repository
# made there, in the next session, git ran a hook the agent wrote (review of
# the GIT-48 fix).
rm -rf "$R133"; mkdir -p "$R133/e/.git" && "${G[@]}" init -q "$R133/r" && rm -rf "$R133/r/.git/hooks" \
  && mv "$R133/r/.git/objects" "$R133/r/.git/o" || { printf 'SCAFFOLD-FAILED: G133 no objects\n'; exit 1; }
launch "$R133"
if [[ "$LAUNCH_RC" == 0 ]] && has_mount "$R133/r/.git/hooks:/workspace/p133/r/.git/hooks:ro" \
   && has_mount "$R133/r/.git/commondir:/workspace/p133/r/.git/commondir:ro" \
   && has_mount "$R133/e/.git/hooks:/workspace/p133/e/.git/hooks:ro" \
   && has_mount "$R133/e/.git/config:/workspace/p133/e/.git/config:ro"; then
  pass "G133 a .git whose objects/ is moved aside, and an empty .git, have hooks/, config and commondir made and bound"
else
  fail "G133 no objects (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F p133 | tr '\n' ' '))"
fi
# A linked worktree's directory with its commondir removed: git never writes
# one without, and the agent could write it back in the next session, with a
# config.worktree git then reads (core.fsmonitor ran on the host; re-review of
# the GIT-48 fix). It gets them too, a ./ commondir among them, inert to git.
rm -rf "$R133"; mkdir -p "$R133" && "${G[@]}" init -q "$R133/r" && "${G[@]}" -C "$R133/r" config extensions.worktreeConfig true \
  && "${G[@]}" -C "$R133/r" commit -q --allow-empty -m init && "${G[@]}" -C "$R133/r" worktree add -q "$R133/wt" \
  && rm -f "$R133/r/.git/worktrees/wt/commondir" "$R133/r/.git/worktrees/wt/config.worktree" \
  || { printf 'SCAFFOLD-FAILED: G133 worktree\n'; exit 1; }
launch "$R133"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$R133/r/.git/worktrees/wt/commondir:/workspace/p133/r/.git/worktrees/wt/commondir:ro" \
  && has_mount "$R133/r/.git/worktrees/wt/config:/workspace/p133/r/.git/worktrees/wt/config:ro" \
  && pass "G133 a linked worktree's directory with no commondir has one made and bound, and a config" \
  || fail "G133 worktree without commondir (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F worktrees/wt | tr '\n' ' '))"
# A submodule's linked worktree names its common directory, and is given
# nothing: no warning that nothing could be made there (re-review of the fix).
rm -rf "$R133"; mkdir -p "$R133/libwt" && "${G[@]}" init -q "$R133/r" && "${G[@]}" init -q --bare "$R133/r/.git/modules/lib" \
  && mkdir -p "$R133/r/.git/modules/lib/worktrees/libwt" && printf '../..\n' > "$R133/r/.git/modules/lib/worktrees/libwt/commondir" \
  && printf '%s/libwt/.git\n' "$R133" > "$R133/r/.git/modules/lib/worktrees/libwt/gitdir" \
  && printf 'ref: refs/heads/main\n' > "$R133/r/.git/modules/lib/worktrees/libwt/HEAD" \
  && printf 'gitdir: %s/r/.git/modules/lib/worktrees/libwt\n' "$R133" > "$R133/libwt/.git" \
  || { printf 'SCAFFOLD-FAILED: G133 submodule worktree\n'; exit 1; }
launch "$R133"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "worktrees/libwt has no" "$ERR" \
  && pass "G133 a submodule's linked worktree draws no warning that nothing could be made there" \
  || fail "G133 submodule worktree (rc=$LAUNCH_RC; $(grep -F 'has no' "$ERR" | head -2 | tr '\n' ' '))"
# One that lost its commondir gets them; repaired on the host, it launches
# again, the placeholder config left there inert (third review of the fix).
rm -f "$R133/r/.git/modules/lib/worktrees/libwt/commondir"; launch "$R133"
r1="$LAUNCH_RC"; printf '../..\n' > "$R133/r/.git/modules/lib/worktrees/libwt/commondir" 2>/dev/null \
  || { chmod u+w "$R133/r/.git/modules/lib/worktrees/libwt"; printf '../..\n' > "$R133/r/.git/modules/lib/worktrees/libwt/commondir"; }
launch "$R133"
[[ "$r1" == 0 && -f "$R133/r/.git/modules/lib/worktrees/libwt/config" && "$LAUNCH_RC" == 0 ]] \
  && pass "G133 a submodule's linked worktree given placeholders launches again once its commondir is repaired" \
  || fail "G133 repaired submodule worktree (first rc=$r1, then rc=$LAUNCH_RC; $(grep -F 'ERROR' "$ERR" | head -1))"
# A repository kept under a directory named worktrees is not a linked
# worktree's: protected once (its ./ commondir made), objects/ moved aside, it
# still gets hooks/ made and bound.
rm -rf "$R133"; mkdir -p "$R133/worktrees" && "${G[@]}" init -q "$R133/worktrees/r" || { printf 'SCAFFOLD-FAILED: G133 under worktrees\n'; exit 1; }
launch "$R133"; rm -rf "$R133/worktrees/r/.git/hooks"; mv "$R133/worktrees/r/.git/objects" "$R133/worktrees/r/.git/o"
launch "$R133"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$R133/worktrees/r/.git/hooks:/workspace/p133/worktrees/r/.git/hooks:ro" \
  && pass "G133 a repository under a directory named worktrees, objects/ moved aside, still has hooks/ made and bound" \
  || fail "G133 under worktrees (rc=$LAUNCH_RC; git mounts: $(git_mounts | grep -F worktrees/r | tr '\n' ' '))"
# Refused where the agent could write the git directory, whoever owns it: its
# uid, group or an ACL (_agent_could_write, asked with the agent's identity);
# another only warns. Another user's directory cannot be made here, so the
# question is answered by a stand-in.
fns133="$TMP/fns133.sh"
for f133 in _term _q _git_cant_make; do
  awk -v f="$f133() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns133"
mkdir -p "$TMP/d133" || { printf 'SCAFFOLD-FAILED: G133 d133\n'; exit 1; }
o133="$(bash -c 'source "$1"; declare -A _gcm_seen=(); uid=4242 gid=4343
  _agent_could_write() { [[ "$2:$3" == 4242:4343 ]]; }
  ( _git_cant_make "$2" no-such-g133 ); printf "rc=%s|" "$?"
  uid=1; ( _git_cant_make "$2" no-such-g133 ); printf "rc=%s|" "$?"' _ "$fns133" "$TMP/d133" 2>&1)"
[[ "$o133" == *"ERROR: cannot make $TMP/d133/no-such-g133,"*"rc=1|"*"WARNING: $TMP/d133 has no no-such-g133"*"rc=0|" ]] \
  && pass "G133 refused where the agent, by its own uid and gid, could write the git directory; another only warns" \
  || fail "G133 the agent's identity (got: $(tr '\n' ' ' <<< "$o133"))"
rm -rf "$R133" "$fns133" "$TMP/d133"

# ── G135: a config entry is split in time linear in its key ────────────────
# git prints a key of any length (an includeIf condition, an alias name), and
# splitting `<key>\n<value>` by pattern was quadratic in it: three planted keys
# of 64 KB took a launch from 2 s to 19 s, in silence (final review of the
# GIT-42 fix; bugs review GIT-49). A key over 256 bytes is not split: the walk
# is cut there, and says so.
fns135="$TMP/fns135.sh"
awk 'index($0, "_git_kv() {") == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh" > "$fns135"
o135="$(bash -c 'source "$1"; set -u
  k=""; v=""; _git_kv $'"'"'core.hookspath\n.husky/_'"'"' k v; printf "%s|%s|" "$k" "$v"
  k=x; v=x; _git_kv "alias.st" k v; printf "%s|%s|" "$k" "$v"
  e="includeif.gitdir:$(printf "%65536s" "" | tr " " a).path"$'"'"'\n/x'"'"'
  s=$SECONDS; if _git_kv "$e" k v; then printf "split|"; else printf "refused|"; fi
  if (( SECONDS - s <= 1 )); then printf "fast"; else printf "%ss" "$(( SECONDS - s ))"; fi' _ "$fns135" 2>&1)"
[[ "$o135" == "core.hookspath|.husky/_|alias.st||refused|fast" ]] \
  && pass "G135 an entry is split at its newline, one with no value too, and a 64 KB key is refused at once" \
  || fail "G135 the split (got: $o135)"
rm -rf "$TMP/h135"; mkdir -p "$TMP/h135" && "${G[@]}" init -q "$TMP/h135/r" || { printf 'SCAFFOLD-FAILED: G135\n'; exit 1; }
{ for i in 1 2 3; do printf '[includeIf "gitdir:%s%d"]\n\tpath = x\n' "$(printf '%65536s' '' | tr ' ' a)" "$i"; done; } >> "$TMP/h135/r/.git/config"
s135=$SECONDS; EXTRA_MOUNTS="$TMP/h135" launch "$TMP/app"; t135=$(( SECONDS - s135 ))
[[ "$LAUNCH_RC" == 0 && "$t135" -le 10 ]] && grep -qF "WARNING: not every include of /workspace/h135/r/.git/config was followed" "$ERR" \
   && grep -qF "(a key of more than 256 characters)" "$ERR" && ! grep -qF "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$ERR" \
  && pass "G135 a config of 64 KB keys is cut, said so, named by size, and the launch stays fast" \
  || fail "G135 long keys (rc=$LAUNCH_RC; ${t135}s; $(grep -cF 'WARNING: not every include' "$ERR") cut warnings)"
# And cheaply: every entry is split, and a bounded regex, compiled on each
# call, made 5000 include entries cost 9 s more than one (review of the fix;
# G38 allows 15). Against the same launch with one, timed in the same run.
mkdir -p "$PROJ/many135" && "${G[@]}" -C "$PROJ/many135" init -q || { printf 'SCAFFOLD-FAILED: G135 many\n'; exit 1; }
printf '[include]\n\tpath = /nonexistent135/f0\n' >> "$PROJ/many135/.git/config"
launch_timed 120; base135="$LAUNCH_S"
{ for n in $(seq 1 5000); do printf '\tpath = /nonexistent135/f%d\n' "$n"; done; } >> "$PROJ/many135/.git/config"
launch_timed 120
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt $(( base135 + 6 )) ]] \
  && pass "G135 5000 entries are split in seconds (${LAUNCH_S}s, ${base135}s with one)" \
  || fail "G135 5000 entries (rc=$LAUNCH_RC; ${LAUNCH_S}s, ${base135}s with one)"
rm -rf "$PROJ/many135"
rm -rf "$TMP/h135" "$fns135"
# ── G134: a program a config has git run, named by a path the agent can change
# The keys that make the host's git run a program (core.fsmonitor, a filter, a
# diff driver, a credential helper, a `!` alias, …) were named once, at the
# first protection, and the programs they name never judged: one in a writable
# mount, one reached through a link there, or one outside every mount with a
# second name in one, could be rewritten by the agent and run by the host's git
# (bugs review GIT-42). The program is the value's first word, after a `!`,
# where it holds a `/`; a relative one is judged from the checkout. Its way is
# walked as a core.hooksPath's is.
mk134() {
  rm -rf "$TMP/h134" "$TMP/o134"; mkdir -p "$TMP/h134" "$TMP/o134" && "${G[@]}" init -q "$TMP/h134/r" \
    || { printf 'SCAFFOLD-FAILED: G134\n'; exit 1; }
}
cfg134() { "${G[@]}" -C "$TMP/h134/r" config "$@" || { printf 'SCAFFOLD-FAILED: G134 config %s\n' "$1"; exit 1; }; }
prog134() {  # $1 = label, $2 = the program as named, $3 = the key, $4 = the line naming the step
  grep -qF "$4" <<<"$(grep -A2 -F "has your host's git run $2 ($3), which leads somewhere the agent can change:" "$ERR")" \
    && pass "G134 $1" \
    || fail "G134 $1 (rc=$LAUNCH_RC; stderr: $(grep -A2 -F "has your host's git run" "$ERR" | head -3 | tr '\n' ' '))"
}
mk134; cfg134 diff.x.textconv ./tools/conv.sh
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "a relative program in the checkout is named" /workspace/h134/r/tools/conv.sh diff.x.textconv \
  "it can change $TMP/h134/r/tools/conv.sh (at /workspace/h134/r/tools/conv.sh)."
mk134; cfg134 credential.helper "!$TMP/h134/helper.sh --store"; cfg134 alias.st '!./scripts/st.sh status'
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "a credential helper run through the shell (!) is judged by its first word" /workspace/h134/helper.sh credential.helper \
  "it can change $TMP/h134/helper.sh (at /workspace/h134/helper.sh)."
prog134 "a ! alias is judged" /workspace/h134/r/scripts/st.sh alias.st \
  "it can change $TMP/h134/r/scripts/st.sh (at /workspace/h134/r/scripts/st.sh)."
mk134; printf '#!/bin/sh\n' > "$TMP/o134/fsm" && chmod +x "$TMP/o134/fsm" && ln "$TMP/o134/fsm" "$TMP/h134/fsm2" \
  || { printf 'SCAFFOLD-FAILED: G134 link\n'; exit 1; }
cfg134 core.fsmonitor "$TMP/o134/fsm"
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "one outside every mount with a second name in one is named, with where" "$TMP/o134/fsm" core.fsmonitor \
  "it can write $TMP/o134/fsm through another name of that file, in $TMP/h134"
mk134; ln -s "$TMP/o134" "$TMP/h134/lnk" && cfg134 core.sshCommand "$TMP/h134/lnk/ssh -v"
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "one reached through a link the agent can repoint is named, with the link" "$TMP/o134/ssh" core.sshcommand \
  "it can repoint $TMP/h134/lnk (at /workspace/h134/lnk), a link on its way."
mk134; printf '[filter "x"]\n\tclean = %s/r/clean.sh %%f\n' "$TMP/h134" > "$TMP/o134/inc.cfg" && cfg134 include.path "$TMP/o134/inc.cfg"
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "one an included file sets is judged" /workspace/h134/r/clean.sh filter.x.clean \
  "it can change $TMP/h134/r/clean.sh (at /workspace/h134/r/clean.sh)."
# Silent: a program found on PATH, a boolean core.fsmonitor, an alias that is
# not a shell command, and one outside every mount with no other name.
mk134; printf '#!/bin/sh\n' > "$TMP/o134/plain" && chmod +x "$TMP/o134/plain" || { printf 'SCAFFOLD-FAILED: G134 plain\n'; exit 1; }
cfg134 filter.lfs.process "git-lfs filter-process"; cfg134 core.fsmonitor true; cfg134 alias.co checkout
cfg134 credential.helper "$TMP/o134/plain"
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -qF "has your host's git run" "$ERR" \
  && pass "G134 a program on PATH, a boolean, a plain alias and a program no one else can write are not named" \
  || fail "G134 silent (rc=$LAUNCH_RC; stderr: $(grep -F -A1 "has your host's git run" "$ERR" | head -2 | tr '\n' ' '))"
# A linked worktree runs the common config's relative program from its own
# checkout: judged from there too.
mk134; cfg134 diff.x.textconv ./tools/conv.sh; "${G[@]}" -C "$TMP/h134/r" commit -q --allow-empty -m init \
  && "${G[@]}" -C "$TMP/h134/r" worktree add -q "$TMP/h134/wt" || { printf 'SCAFFOLD-FAILED: G134 worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "a linked worktree's relative program is judged from its checkout" /workspace/h134/wt/tools/conv.sh diff.x.textconv \
  "it can change $TMP/h134/wt/tools/conv.sh (at /workspace/h134/wt/tools/conv.sh)."
# Named once, however many ways lead there.
[[ "$(grep -cF "has your host's git run /workspace/h134/r/tools/conv.sh (diff.x.textconv)" "$ERR")" == 1 ]] \
  && pass "G134 one program is named once" \
  || fail "G134 named $(grep -cF "has your host's git run /workspace/h134/r/tools/conv.sh (diff.x.textconv)" "$ERR") times"
# The program behind an interpreter, an assignment or exec is judged; one a
# shell expansion or command names is named as not judged rather than judged
# where it is not; a key whose value is a whole path is not split at a space;
# ~user/ is named (review of the GIT-42 fix).
mk134; mkdir -p "$TMP/h134/my tools" || { printf 'SCAFFOLD-FAILED: G134 my tools\n'; exit 1; }
cfg134 filter.x.clean "python3 tools/c.py --x"; cfg134 diff.y.textconv "sh ./tools/t.sh"
cfg134 alias.e '!FOO=1 exec ./scripts/e.sh'; cfg134 alias.h '!$HOME/bin/x'
cfg134 mergetool.m.path "$TMP/h134/my tools/merge"; cfg134 core.editor '~someone/bin/ed'
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
prog134 "an interpreter's script is judged" /workspace/h134/r/tools/c.py filter.x.clean \
  "it can change $TMP/h134/r/tools/c.py (at /workspace/h134/r/tools/c.py)."
prog134 "sh's script is judged" /workspace/h134/r/tools/t.sh diff.y.textconv \
  "it can change $TMP/h134/r/tools/t.sh (at /workspace/h134/r/tools/t.sh)."
prog134 "one after an assignment and exec is judged" /workspace/h134/r/scripts/e.sh alias.e \
  "it can change $TMP/h134/r/scripts/e.sh (at /workspace/h134/r/scripts/e.sh)."
prog134 "a whole path is not split at a space" "/workspace/h134/my tools/merge" mergetool.m.path \
  "it can change $TMP/h134/my tools/merge (at /workspace/h134/my tools/merge)."
if grep -qF "has your host's git run a command (alias.h) the launcher does not follow" "$ERR" \
   && grep -qF "has your host's git run ~someone/bin/ed (core.editor), which the launcher does not expand" "$ERR" \
   && ! grep -qF 'r/$HOME' "$ERR" && ! grep -qF '$HOME/bin/x' "$ERR"; then
  pass "G134 a shell expansion and ~user/ are named as not judged, never judged where they are not"
else
  fail "G134 not judged (stderr: $(grep -F -A1 "has your host's git run" "$ERR" | grep -F -e HOME -e someone | tr '\n' ' '))"
fi
# Read as a shell reads it, and in time linear in its length: a value is the
# agent's to make, and one with 64000 leading spaces took 17 s a call, stalling
# every launch in silence (second review of the fix). An option's argument is
# not taken for the script, `-m mod` runs ./mod.py first, inline code and
# functions are named by the command, never by `-c` or `f()`.
fns134="$TMP/fns134.sh"
awk 'index($0, "_git_prog() {") == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh" > "$fns134"
o134="$(bash -c 'source "$1"; for kv in "alias.p|!python3 -W ignore -m nbstripout --x" "alias.q|!perl -I lib t.pl" \
  "alias.r|!node -pe 1" "alias.s|!nice -n 10 ./n.sh" "alias.t|!timeout 10 ./t.sh" "alias.u|!env -u FOO -C /tmp ./e.sh" \
  "diff.d.textconv|sh -c '"'"'pdftotext \$1 -'"'"' -" "alias.f|!f() { ./x; }; f"; do
    o=(); if _git_prog "${kv%%|*}" "${kv#*|}" o; then printf "%s;" "${o[@]}"; else printf "none;"; fi; printf "|"; done' _ "$fns134" 2>&1)"
want134="p:nbstripout.py;|p:t.pl;|u:inline code;|p:./n.sh;|p:./t.sh;|p:./e.sh;|u:inline code;|u:a shell expansion, quoting or an operator;|"
[[ "$o134" == "$want134" ]] \
  && pass "G134 options and their arguments, -m, inline code and functions are read as a shell reads them" \
  || fail "G134 reading (got: $o134)"
o134="$(bash -c 'source "$1"; for kv in "alias.a|!bash -e ./x.sh" "alias.b|!python3 -E x.py" "alias.c|!python3 -mpkg.mod" \
  "alias.d|!exec -a name ./x" "alias.e|!bash -o pipefail ./p.sh" "alias.f|!node --experimental-vm-modules x.js" \
  "alias.g|!perl -Mfeature=say t.pl" "alias.h|!ruby -rset x.rb" "alias.i|!python3 -Wonce y.py" "alias.j|!node --eval 1"; do
    o=(); if _git_prog "${kv%%|*}" "${kv#*|}" o; then printf "%s;" "${o[@]}"; else printf "none;"; fi; printf "|"; done' _ "$fns134" 2>&1)"
[[ "$o134" == "p:./x.sh;|p:x.py;|p:pkg/mod.py;|p:./x;|p:./p.sh;|p:x.js;|p:t.pl;|p:x.rb;|p:y.py;|u:inline code;|" ]] \
  && pass "G134 an interpreter's own options decide what is inline code and what takes an argument" \
  || fail "G134 interpreter options (got: $o134)"
# Fail closed (automated security review of the fix): another command after
# the program, words that run out before it, and a glob are not followed; a
# wrapper's own arguments are not taken for the program.
o134="$(bash -c 'source "$1"; for kv in "alias.a|!git status; ./evil.sh" "alias.b|!git fetch && git rebase" \
  "alias.c|!A=1 B=2 C=3 D=4 E=5 F=6 G=7 H=8 ./x" "alias.d|!./tools/*.sh" "alias.e|!taskset 0x3 ./x" "alias.f|!sudo -u root ./y" \
  "alias.g|!./a \$(./b)"; do
    o=(); if _git_prog "${kv%%|*}" "${kv#*|}" o; then printf "%s;" "${o[@]}"; else printf "none;"; fi; printf "|"; done' _ "$fns134" 2>&1)"
[[ "$o134" == "u:another command after it;|u:another command after it;|u:more than eight words before the program;|u:a shell expansion, quoting or an operator;|p:./x;|p:./y;|p:./a;u:another command after it;|" ]] \
  && pass "G134 another command after the program, too many words and a glob are not followed; a wrapper's arguments are skipped" \
  || fail "G134 fail closed (got: $o134)"
# After a wrapper, a word with no / is the program found on PATH, its path
# arguments never taken for the program; only taskset's and chrt's positional
# arguments are skipped. Words that run out after an interpreter, before its
# script, are not followed (final review of the fix).
o134="$(bash -c 'source "$1"; for kv in "alias.a|!env GIT_PAGER=cat git log -- ./src" "alias.b|!nice git diff ./file" \
  "alias.c|!sudo -D /srv ./y" "alias.d|!chrt 10 ./c" "alias.e|!/usr/bin/python3 -u -O -B -s -E -I -q x.py" "alias.f|!sudo -n ./x"; do
    o=(); if _git_prog "${kv%%|*}" "${kv#*|}" o; then printf "%s;" "${o[@]}"; else printf "none;"; fi; printf "|"; done' _ "$fns134" 2>&1)"
[[ "$o134" == "none;|none;|p:./y;|p:./c;|p:/usr/bin/python3;u:more than eight words before the program;|u:a wrapper whose program was not found;|" ]] \
  && pass "G134 a wrapper's PATH program ends the reading; interpreter words that run out are not followed" \
  || fail "G134 wrappers (got: $o134)"
t134="$(bash -c 'source "$1"; v="!$(printf "%64000s" "")./x"; s=$SECONDS; o=(); _git_prog alias.x "$v" o; printf "%s|%s" "$(( SECONDS - s ))" "${o[*]}"' _ "$fns134" 2>&1)"
[[ "${t134%%|*}" -le 1 && "${t134#*|}" == "u:a value of 64004 bytes" ]] \
  && pass "G134 a value of 64000 bytes is named, not read, in no time" \
  || fail "G134 a long value (seconds|result: $t134)"
s134=$SECONDS
bash -c 'source "$1"; v="!python3 $(printf "%4000s" "")./x.py"; for i in $(seq 1 200); do o=(); _git_prog alias.x "$v" o; done' _ "$fns134"
[[ $(( SECONDS - s134 )) -le 5 ]] \
  && pass "G134 200 values of 4000 bytes of spaces are read in seconds" \
  || fail "G134 200 long values took $(( SECONDS - s134 )) s"
rm -f "$fns134"
# A command not followed is named by its key and why, never by its value: a
# credential helper's can hold a token, and stderr reaches logs (final review
# of the fix).
mk134; cfg134 credential.helper '!f() { echo username=x; echo password=G134SECRETTOKEN; }; f'
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
grep -qF "has your host's git run a command (credential.helper) the launcher does not follow" "$ERR" \
  && ! grep -qF G134SECRETTOKEN "$ERR" \
  && pass "G134 a credential helper not followed is named by its key, its value never printed" \
  || fail "G134 secret (named: $(grep -cF 'credential.helper' "$ERR"); printed: $(grep -cF G134SECRETTOKEN "$ERR"))"
# A config is read to 1200 entries at most, past every budget a file has: read
# whole, a planted config of keys that run a program filled memory before any
# budget counted them (automated security review of the fix). Its last
# core.hooksPath, past the cut, is still judged and bound, asked of git.
mk134; { printf '[alias]\n'; for i in $(seq 1 1500); do printf '\ta%d = !x%d\n' "$i" "$i"; done; printf '[core]\n\thooksPath = .husky/_\n'; } >> "$TMP/h134/r/.git/config"
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && has_mount "$TMP/h134/r/.git/.husky:/workspace/h134/r/.git/.husky:ro" \
  && grep -qF "runs its git hooks from /workspace/h134/r/.husky/_ (core.hooksPath), which the agent" "$ERR" \
  && grep -qF "WARNING: not every include of /workspace/h134/r/.git/config was followed" "$ERR" \
  && pass "G134 a config read in part is cut, and its core.hooksPath past the cut still judged and bound" \
  || fail "G134 read cap (rc=$LAUNCH_RC; husky mounts: $(mounts | grep -cF '.git/.husky'); $(grep -F 'core.hooksPath' "$ERR" | head -1))"
# A credential.<url> key is named with its user and password blanked: the
# NOTE is printed on every launch (final review of the fix).
mk134; cfg134 'credential.https://u:G134URLTOKEN@host.example.helper' '!f() { echo x; }; f'
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
grep -qF "has your host's git run a command (credential.https://***@host.example.helper)" "$ERR" && ! grep -qF G134URLTOKEN "$ERR" \
  && pass "G134 a credential URL's user and password are never printed" \
  || fail "G134 credential URL (printed: $(grep -cF G134URLTOKEN "$ERR"); $(grep -F 'credential.' "$ERR" | head -1))"
# And cheaply, against the same launch with one, timed in the same run: 5000
# keys that run a program, and 3000 whose names pass 256 characters, cost 13 s
# and 43 s more (final review of the fix).
mk134; cfg134 alias.a0 '!x0'; EXTRA_MOUNTS="$TMP/h134" launch_timed 120 "$TMP/app"; base134="$LAUNCH_S"
{ printf '[alias]\n'; for i in $(seq 1 5000); do printf '\ta%d = !x%d\n' "$i" "$i"; done; } >> "$TMP/h134/r/.git/config"
EXTRA_MOUNTS="$TMP/h134" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt $(( base134 + 6 )) ]] \
  && pass "G134 5000 keys that run a program cost seconds (${LAUNCH_S}s, ${base134}s with one)" \
  || fail "G134 5000 keys (rc=$LAUNCH_RC; ${LAUNCH_S}s, ${base134}s with one)"
mk134; { printf '[alias]\n'; for i in $(seq 1 3000); do printf '\t%s%d = !x\n' "$(printf '%300s' '' | tr ' ' a)" "$i"; done; } >> "$TMP/h134/r/.git/config"
EXTRA_MOUNTS="$TMP/h134" launch_timed 120 "$TMP/app"
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt $(( base134 + 6 )) ]] && grep -qF "WARNING: not every include of /workspace/h134/r/.git/config was followed" "$ERR" \
   && grep -qF "WARNING: not every program the git config of /workspace/h134/r/.git has git run was judged" "$ERR" \
  && pass "G134 3000 keys of 300 characters count among those that run a program, are cut, said so, in seconds (${LAUNCH_S}s)" \
  || fail "G134 long keys (rc=$LAUNCH_RC; ${LAUNCH_S}s, ${base134}s with one; $(grep -cF 'WARNING: not every include' "$ERR") cut warnings)"
# A linked worktree whose checkout this launch does not know: its relative
# programs are named as not judged, never judged from its git directory.
mk134; cfg134 diff.x.textconv ./tools/conv.sh; "${G[@]}" -C "$TMP/h134/r" commit -q --allow-empty -m init \
  && "${G[@]}" -C "$TMP/h134/r" worktree add -q "$TMP/o134/wt" && rm -f "$TMP/h134/r/.git/worktrees/wt/gitdir" \
  || { printf 'SCAFFOLD-FAILED: G134 unknown checkout\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
grep -qF "NOTE: /workspace/h134/r/.git/worktrees/wt has your host's git run ./tools/conv.sh (diff.x.textconv) relative to a checkout this launch" "$ERR" \
  && ! grep -qF "worktrees/wt/tools/conv.sh" "$ERR" \
  && pass "G134 a linked worktree's relative program, its checkout unknown, is named as not judged" \
  || fail "G134 unknown checkout (stderr: $(grep -F -A1 'worktrees/wt' "$ERR" | head -3 | tr '\n' ' '))"
# One the main worktree's config.worktree sets is not a linked worktree's. Set
# after the worktree is added: git 2.36 and later copy config.worktree into a
# new worktree's own, where it is that worktree's too.
mk134; cfg134 extensions.worktreeConfig true; "${G[@]}" -C "$TMP/h134/r" commit -q --allow-empty -m init \
  && "${G[@]}" -C "$TMP/h134/r" worktree add -q "$TMP/h134/wt" \
  && "${G[@]}" -C "$TMP/h134/r" config --worktree diff.x.textconv ./tools/main.sh \
  || { printf 'SCAFFOLD-FAILED: G134 config.worktree\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
grep -qF "has your host's git run /workspace/h134/r/tools/main.sh (diff.x.textconv)" "$ERR" \
  && ! grep -qF "/workspace/h134/wt/tools/main.sh" "$ERR" \
  && pass "G134 one the main worktree's config.worktree sets is judged for it alone" \
  || fail "G134 config.worktree (stderr: $(grep -F 'main.sh' "$ERR" | head -2 | tr '\n' ' '))"
# Across a launch: 21 repositories of 999 such keys each pass the launch's
# budget of 20000, past which the walk is cut and said so (review of the fix:
# planted repositories doubled a launch's time, in silence).
rm -rf "$TMP/h134" "$TMP/o134"; mkdir -p "$TMP/h134" && { printf '[alias]\n'; for i in $(seq 1 999); do printf '\ta%d = !x%d\n' "$i" "$i"; done; } > "$TMP/al134" \
  || { printf 'SCAFFOLD-FAILED: G134 budget\n'; exit 1; }
for i in $(seq 1 21); do "${G[@]}" init -q "$TMP/h134/r$i" && cat "$TMP/al134" >> "$TMP/h134/r$i/.git/config" || { printf 'SCAFFOLD-FAILED: G134 budget %s\n' "$i"; exit 1; }; done
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: not every include of /workspace/h134/r" "$ERR" \
  && pass "G134 past 20000 keys that run a program a launch, the walk is cut, and said so" \
  || fail "G134 launch budget (rc=$LAUNCH_RC; $(grep -cF 'WARNING: not every include' "$ERR") cut warnings)"
rm -f "$TMP/al134"
# And by bytes: 70 values of 4000 bytes pass the launch's 256 KB, past which the
# walk is cut too (final review of the fix: the budget counted calls only).
rm -rf "$TMP/h134"; mkdir -p "$TMP/h134" && "${G[@]}" init -q "$TMP/h134/r" \
  && { printf '[alias]\n'; for i in $(seq 1 70); do printf '\tb%d = "!x%s"\n' "$i" "$(printf '%4000s' '')"; done; } >> "$TMP/h134/r/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G134 bytes\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && grep -qF "WARNING: not every include of /workspace/h134/r/.git/config was followed" "$ERR" \
  && pass "G134 past 256 KB of keys that run a program a launch, the walk is cut, and said so" \
  || fail "G134 byte budget (rc=$LAUNCH_RC; $(grep -cF 'WARNING: not every include' "$ERR") cut warnings)"
# Bounded, and said so: a config of thousands of keys that run a program cuts
# its walk past 1000, and at most 50 programs a git directory are judged.
mk134; { printf '[alias]\n'; for i in $(seq 1 1100); do printf '\ta%d = !./s%d.sh\n' "$i" "$i"; done; } >> "$TMP/h134/r/.git/config" \
  || { printf 'SCAFFOLD-FAILED: G134 many\n'; exit 1; }
EXTRA_MOUNTS="$TMP/h134" launch "$TMP/app"
n134="$(grep -cF "has your host's git run" "$ERR")"
[[ "$LAUNCH_RC" == 0 && "$n134" -ge 1 && "$n134" -le 50 ]] \
  && grep -qF "WARNING: not every include of /workspace/h134/r/.git/config was followed (100 entries, 1000 keys that run a program" "$ERR" \
  && grep -qF "WARNING: not every program the git config of /workspace/h134/r/.git has git run was judged" "$ERR" \
  && pass "G134 thousands of keys that run a program are bounded, and the cut is named" \
  || fail "G134 many (rc=$LAUNCH_RC; named $n134; $(grep -F 'WARNING: not every' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/h134" "$TMP/o134"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
