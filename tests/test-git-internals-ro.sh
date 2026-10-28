#!/usr/bin/env bash
# What the HOST's git runs from a repository must not be writable from inside
# the container: its hooks/, and config, whose keys run programs (core.hooksPath,
# core.fsmonitor, core.sshCommand, filters). sandbox.sh mounts them read-only
# inside every writable mount that exposes a git directory, pins the directories
# above them so .git cannot be renamed away, and leaves objects, refs and the
# index writable (launcher_ro_overlay, git_dirs_in). What it cannot freeze is
# named: a hook that links out, an include of a file the agent can write, and —
# once, at the first protection — the keys a config already sets that run programs.
#
# Hermetic: a fake `docker` capturing the run args, real git repositories.
# Integration case 465-git-internals-read-only checks that the container the
# agent gets actually refuses the writes, and still commits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/sandbox.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
# shellcheck source=tests/portability.sh
source "$ROOT/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
# Physical path: on macOS mktemp hands out /var/..., a symlink to /private/var/...,
# and sandbox.sh resolves every mount source.
TMP="$(cd "$TMP" && pwd -P)"
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; export HOME="$REAL_HOME"; }' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH \
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE SANDBOX_GIT_MAX SANDBOX_LAUNCHER_MAX
# The repositories below are made with the test's own identity, never the host's.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main)
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
  prev=""
  for a in "\$@"; do
    if [[ "\$prev" == -v && "\$a" == *:/run/ai-launcher:ro ]]; then
      cp "\${a%:/run/ai-launcher:ro}/manifest" "$CAPTURE.manifest" 2>/dev/null
    fi
    prev="\$a"
  done
fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF; : > "$SANDBOX_CONF"

# A project's working copy, as project-init.sh lays it out, in a git repository.
# shellcheck source=shared-files.sh
source "$ENGINE/shared-files.sh"
PROJ="$TMP/proj"; LAUNCHER="$PROJ/.ai-containers"
mkdir -p "$LAUNCHER" "$TMP/app"
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$LAUNCHER/$f"; done
cp -R "$ENGINE/tools.d" "$LAUNCHER/"
# services.d only where the engine has one: mgd-ai-containers has no database servers.
[[ ! -d "$ENGINE/services.d" ]] || cp -R "$ENGINE/services.d" "$LAUNCHER/"
"${G[@]}" -C "$PROJ" init -q && printf 'x\n' > "$PROJ/README" && "${G[@]}" -C "$PROJ" add README \
  && "${G[@]}" -C "$PROJ" commit -qm init \
  || { printf 'SCAFFOLD-FAILED: cannot create the project repository\n'; exit 1; }

ERR="$TMP/err.txt"
launch() {  # $1 = primary; extra env via the caller's `VAR=x launch …`
  rm -f "$CAPTURE" "$CAPTURE.manifest"
  ( cd "$LAUNCHER" && bash ./sandbox.sh restricted "$1" ) >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?
}
# Every mount, rendered `src:dst:opts`, whether docker got it as -v or --mount.
mounts() {
  awk '
    function csv(s, f,   n, i, c, q, cur) {
      n = 0; cur = ""; q = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q) {
          if (c == "\"") { if (substr(s, i + 1, 1) == "\"") { cur = cur "\""; i++ } else q = 0 }
          else cur = cur c
        } else if (c == "\"") q = 1
        else if (c == ",") { f[++n] = cur; cur = "" }
        else cur = cur c
      }
      f[++n] = cur
      return n
    }
    prev == "-v" { print }
    prev == "--mount" {
      n = csv($0, f); src = dst = ""; ro = 0
      for (k = 1; k <= n; k++) {
        if (f[k] ~ /^source=/)           src = substr(f[k], 8)
        else if (f[k] ~ /^destination=/) dst = substr(f[k], 13)
        else if (f[k] == "readonly" || f[k] == "ro") ro = 1
      }
      printf "%s:%s:%s\n", src, dst, (ro ? "ro" : "rw")
    }
    { prev = $0 }
  ' "$CAPTURE" 2>/dev/null
}
has_mount() { grep -qxF -- "$1" <<<"$(mounts)"; }
# The git-related mounts: anything whose source is or lies under a .git, plus
# pins (src == dst's host path) of the directories above one.
git_mounts() { mounts | grep -E '/\.git(:|/)' || true; }

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

# ── G19: hooks run from a writable core.hooksPath are named ───────────────────
mkdir -p "$PROJ/.husky/_" && "${G[@]}" -C "$PROJ" config core.hooksPath .husky/_
launch ..
grep -qF "NOTE: /workspace/proj/.git runs its git hooks from /workspace/proj/.husky/_ (core.hooksPath)" "$ERR" \
  && pass "G19 a core.hooksPath in the writable project is named in a NOTE" \
  || fail "G19 hooksPath NOTE (stderr: $(grep -E 'NOTE' "$ERR" | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset core.hooksPath; rm -rf "$PROJ/.husky"

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

# ── G26: the launch that first protects a repository names what its config ────
# already runs — the one moment that can only be what was set before the
# protection existed. Once: a later launch says nothing. Names, never values.
mkdir -p "$TMP/fp/r" "$TMP/fp/clean"
"${G[@]}" -C "$TMP/fp/r" init -q && "${G[@]}" -C "$TMP/fp/clean" init -q
"${G[@]}" -C "$TMP/fp/r" config core.sshCommand 'ssh -i sekrit-key'
"${G[@]}" -C "$TMP/fp/r" config core.fsmonitor .git/hooks/fsmonitor-watchman
"${G[@]}" -C "$TMP/fp/r" config filter.lfs.clean 'git-lfs clean -- %f'
"${G[@]}" -C "$TMP/fp/r" config alias.sh '!echo hi'
"${G[@]}" -C "$TMP/fp/r" config alias.st status
"${G[@]}" -C "$TMP/fp/clean" config core.fsmonitor true
# A key set only in config.worktree is named, and that file is in the review.
mkdir -p "$TMP/fp/wtc" && "${G[@]}" -C "$TMP/fp/wtc" init -q && "${G[@]}" -C "$TMP/fp/wtc" config extensions.worktreeConfig true
"${G[@]}" -C "$TMP/fp/wtc" config --worktree filter.x.smudge 'x-smudge'
EXTRA_MOUNTS="$TMP/fp" launch "$TMP/app"
grep -qF 'filter.x.smudge' <<<"$(grep -A1 -F 'NOTE: /workspace/fp/wtc/.git is protected for the first time, and its config' "$ERR")" \
  && grep -qF "git config --file $TMP/fp/wtc/.git/config.worktree --list" "$ERR" \
  && pass "G26 a key set only in config.worktree is named, with config.worktree to review" \
  || fail "G26 config.worktree key (stderr: $(grep -A4 'wtc/.git is protected' "$ERR" | tr '\n' ' '))"
nl26="$(grep -A1 -F 'NOTE: /workspace/fp/r/.git is protected for the first time, and its config' "$ERR" | tail -1)"
[[ "$nl26" == *core.sshcommand* && "$nl26" == *core.fsmonitor* && "$nl26" == *filter.lfs.clean* && "$nl26" == *alias.sh* ]] \
  && grep -qF "git config --file $TMP/fp/r/.git/config --list" "$ERR" \
  && pass "G26 the first protection names the keys that run programs, and how to review them" \
  || fail "G26 first-protection NOTE (got: $nl26; stderr: $(grep -A3 'first time' "$ERR" | tr '\n' ' '))"
[[ "$nl26" != *alias.st* ]] && ! grep -q 'fp/clean/.git is protected for the first time, and its config' "$ERR" \
  && pass "G26 a plain alias, and git's own fsmonitor daemon, are not named" \
  || fail "G26 benign keys named (got: $nl26; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
! grep -qF 'sekrit' "$ERR" && pass "G26 no value is printed" || fail "G26 a value was printed"
EXTRA_MOUNTS="$TMP/fp" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'protected for the first time' "$ERR" \
  && pass "G26 the next launch says nothing: the repository is already protected" \
  || fail "G26 repeated NOTE (rc=$LAUNCH_RC; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/fp"

# ── G27: …and the hooks its hooks/ already holds ──────────────────────────────
# A repository the agent made in a subdirectory arrives with whatever hooks it
# put there, and protecting it freezes them. Only what git would run: a name
# from githooks(5), executable (through a link, too). Nothing when
# core.hooksPath sends git elsewhere; nothing on a later launch.
mkdir -p "$TMP/fh/h" "$TMP/fh/hp" "$TMP/fh/none" "$TMP/fh/wtp"
for r in h hp none wtp; do "${G[@]}" -C "$TMP/fh/$r" init -q; done
for e in pre-commit post-checkout my-helper; do printf '#!/bin/sh\n' > "$TMP/fh/h/.git/hooks/$e"; done
printf '#!/bin/sh\n' > "$TMP/fh/h/.git/hooks/pre-push"
printf '#!/bin/sh\n' > "$TMP/fh-outside-pm"
chmod 755 "$TMP/fh/h/.git/hooks/pre-commit" "$TMP/fh/h/.git/hooks/post-checkout" \
  "$TMP/fh/h/.git/hooks/my-helper" "$TMP/fh-outside-pm"
chmod 644 "$TMP/fh/h/.git/hooks/pre-push"
ln -s "$TMP/fh-outside-pm" "$TMP/fh/h/.git/hooks/post-merge"
ln -s "$TMP/fh-missing" "$TMP/fh/h/.git/hooks/post-rewrite"
printf '#!/bin/sh\n' > "$TMP/fh/hp/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/hp/.git/hooks/pre-commit"
"${G[@]}" -C "$TMP/fh/hp" config core.hooksPath .githooks
printf '#!/bin/sh\n' > "$TMP/fh/wtp/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/wtp/.git/hooks/pre-commit"
"${G[@]}" -C "$TMP/fh/wtp" config extensions.worktreeConfig true
"${G[@]}" -C "$TMP/fh/wtp" config --worktree core.hooksPath .githooks
# Without extensions.worktreeConfig git never reads config.worktree, so a
# core.hooksPath there must not hide what hooks/ runs.
mkdir -p "$TMP/fh/wtx" && "${G[@]}" -C "$TMP/fh/wtx" init -q
printf '#!/bin/sh\n' > "$TMP/fh/wtx/.git/hooks/pre-commit"; chmod 755 "$TMP/fh/wtx/.git/hooks/pre-commit"
"${G[@]}" config --file "$TMP/fh/wtx/.git/config.worktree" core.hooksPath .githooks
EXTRA_MOUNTS="$TMP/fh" launch "$TMP/app"
hk27="$(grep -A1 -F 'NOTE: /workspace/fh/h/.git is protected for the first time, and its hooks/' "$ERR" | tail -1)"
[[ "$hk27" == *pre-commit* && "$hk27" == *post-checkout* && "$hk27" == *post-merge* ]] \
  && grep -qF "ls -l $TMP/fh/h/.git/hooks" "$ERR" \
  && pass "G27 the first protection names the hooks git would run, and how to review them" \
  || fail "G27 hooks NOTE (got: $hk27; stderr: $(grep -A3 'first time' "$ERR" | tr '\n' ' '))"
[[ -n "$hk27" && "$hk27" != *pre-push* && "$hk27" != *my-helper* && "$hk27" != *sample* && "$hk27" != *post-rewrite* ]] \
  && pass "G27 a hook that is not executable, a name git never runs, a .sample and a dangling link are not named" \
  || fail "G27 inert hooks named (got: $hk27)"
! grep -qE 'fh/(hp|wtp|none)/\.git is protected for the first time, and its hooks/' "$ERR" \
  && pass "G27 nothing when core.hooksPath (config or config.worktree) sends git elsewhere, or hooks/ holds only samples" \
  || fail "G27 hooks NOTE where git runs none of them (stderr: $(grep -A1 'its hooks/' "$ERR" | tr '\n' ' '))"
grep -qF 'pre-commit' <<<"$(grep -A1 -F 'NOTE: /workspace/fh/wtx/.git is protected for the first time, and its hooks/' "$ERR")" \
  && pass "G27 a core.hooksPath in a config.worktree git does not read hides nothing" \
  || fail "G27 ignored config.worktree hid the hooks (stderr: $(grep -A1 'wtx' "$ERR" | tr '\n' ' '))"
EXTRA_MOUNTS="$TMP/fh" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'its hooks/' "$ERR" \
  && pass "G27 the next launch says nothing: the repository is already protected" \
  || fail "G27 repeated hooks NOTE (rc=$LAUNCH_RC; stderr: $(grep -A1 'its hooks/' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/fh" "$TMP/fh-outside-pm"

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

# ── G31: what an agent-made repository holds cannot make the launch slow ──────
# Its .git/config is overlaid read-only, so the include walk follows it as safe —
# but every byte of it is the agent's. Includes of the same file spelled two
# ways (./config, .//config) made the walk exponential: 15 s with two, past
# five minutes with four (the review of b3d2362). Each file is read once per
# launch, however it is spelled, and the reads are bounded.
launch_timed() {  # $1 = seconds; leaves LAUNCH_RC (124 on timeout) and LAUNCH_S
  local t0=$SECONDS
  rm -f "$CAPTURE" "$CAPTURE.manifest"
  p_timeout "$1" bash -c 'cd "$1" && exec bash ./sandbox.sh restricted ..' _ "$LAUNCHER" >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?; LAUNCH_S=$((SECONDS - t0))
}
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

# ── G38: many include entries in one config cannot make the launch slow ───────
mkdir -p "$PROJ/many38" && "${G[@]}" -C "$PROJ/many38" init -q
{ printf '[include]\n'; for n in $(seq 1 5000); do printf '\tpath = /nonexistent38/f%d\n' "$n"; done; } >> "$PROJ/many38/.git/config"
launch_timed 120
[[ "$LAUNCH_RC" == 0 && "$LAUNCH_S" -lt 15 ]] \
  && grep -qF "WARNING: not every include of /workspace/proj/many38/.git/config was followed" "$ERR" \
  && pass "G38 5000 include entries in one config cost seconds, and are named (${LAUNCH_S}s)" \
  || fail "G38 include entries (rc=$LAUNCH_RC; ${LAUNCH_S}s; stderr: $(grep -F many38 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/many38"

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
for e in 1 2 3; do "${G[@]}" config --file "$R46/.git/config" --add include.path ../../l46/L1; done
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

# ── G64: a FIFO planted as .git above a mount cannot hang the walk up ───────
# The walk read any .git that was not a directory, and a FIFO there blocked the
# read for ever (automated security review of 4a800a9).
mkdir -p "$PROJ/f64/sub"; mkfifo "$PROJ/f64/.git"
EXTRA_MOUNTS="$PROJ/f64/sub" launch_timed 60
[[ "$LAUNCH_RC" != 124 ]] && pass "G64 a FIFO .git above a nested mount does not hang the launch (${LAUNCH_S}s)" \
  || fail "G64 the walk up hung on a FIFO .git"
( exec 3<>"$PROJ/f64/.git" ) 2>/dev/null; rm -rf "$PROJ/f64"

# ── G65: a git directory's config or commondir as a FIFO cannot hang a launch ─
# Since a config is no longer required to take a directory for a git directory,
# one the agent made with a FIFO config, or commondir, hung every read of it:
# hooksPath, objectformat, core.worktree, the own-repository test (review of
# 1a30bb4, MEDIUM; a regression from 236d347).
for v in config commondir; do
  mkdir -p "$PROJ/ff65/.git/objects" "$PROJ/ff65/.git/refs"; printf 'ref: refs/heads/main\n' > "$PROJ/ff65/.git/HEAD"
  mkfifo "$PROJ/ff65/.git/$v"
  launch_timed 60
  # Refused, not just skipped: a FIFO mounted read-only can still be written, so
  # the agent would feed the host's git whatever config it reads there
  # (automated security review of 455fa85).
  [[ "$LAUNCH_RC" != 124 && "$LAUNCH_RC" != 0 ]] && grep -qF "ff65/.git/$v is not a regular file" "$ERR" \
    && pass "G65 a FIFO $v in a git directory refuses the launch, without hanging (${LAUNCH_S}s)" \
    || fail "G65 a FIFO $v (rc=$LAUNCH_RC; $(grep -F ff65 "$ERR" | head -1))"
  ( exec 3<>"$PROJ/ff65/.git/$v" ) 2>/dev/null; rm -rf "$PROJ/ff65"
done

# ── G66-G69: a read-only bind does not make a FIFO read-only ────────────────
# On Linux a FIFO under a read-only bind can still be opened for writing, so the
# agent could feed the host's git a config through any FIFO in what the launcher
# binds read-only: reproduced through an unlistable .git, a .git inside a planted
# launcher (review of 56c91c4, HIGH). Any FIFO or device in a read-only bind
# source refuses the launch, as does a git directory searchable but not listable.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$PROJ/u66" && "${G[@]}" -C "$PROJ/u66" init -q && rm -f "$PROJ/u66/.git/config" \
    && mkfifo "$PROJ/u66/.git/config" && chmod 0300 "$PROJ/u66/.git"
  launch_timed 60
  [[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "u66/.git" "$ERR" \
    && pass "G66 a searchable but unlistable .git refuses the launch" \
    || fail "G66 unlistable .git with a FIFO config (rc=$LAUNCH_RC; $(grep -F u66 "$ERR" | head -1))"
  chmod 0755 "$PROJ/u66/.git"; ( exec 3<>"$PROJ/u66/.git/config" ) 2>/dev/null; rm -rf "$PROJ/u66"
fi
mkdir -p "$PROJ/tools67/x"; : > "$PROJ/tools67/x/sandbox.sh"; : > "$PROJ/tools67/x/sandbox-common.sh"
"${G[@]}" init -q "$PROJ/tools67/x" && rm -f "$PROJ/tools67/x/.git/config" && mkfifo "$PROJ/tools67/x/.git/config"
launch_timed 60
[[ "$LAUNCH_RC" != 0 && "$LAUNCH_RC" != 124 ]] && grep -qF "tools67/x/.git/config" "$ERR" \
  && pass "G67 a FIFO inside a planted launcher's read-only overlay refuses the launch" \
  || fail "G67 FIFO under a launcher overlay (rc=$LAUNCH_RC; $(grep -F tools67 "$ERR" | head -1))"
( exec 3<>"$PROJ/tools67/x/.git/config" ) 2>/dev/null; rm -rf "$PROJ/tools67"
# G68: git takes a symlinked HEAD; one the agent made was never taken for a git
# directory, so its config stayed writable, silently (review of 56c91c4, HIGH).
mkdir -p "$PROJ/h68" && "${G[@]}" -C "$PROJ/h68" init -q && rm -f "$PROJ/h68/.git/HEAD" && ln -s refs/heads/main "$PROJ/h68/.git/HEAD"
launch ..
has_mount "$PROJ/h68/.git/config:/workspace/proj/h68/.git/config:ro" \
  && pass "G68 a git directory whose HEAD is a symlink is protected" \
  || fail "G68 symlinked-HEAD repository left writable"
rm -rf "$PROJ/h68"
# G69: a worktree or submodule named config is not taken for a FIFO config (the
# recheck matched names; review of 56c91c4).
M69="$PROJ/main69"; "${G[@]}" init -q "$M69" && "${G[@]}" -C "$M69" commit -q --allow-empty -m s \
  && "${G[@]}" -C "$M69" worktree add -q "$PROJ/config" || { printf 'SCAFFOLD-FAILED: G69\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" == 0 ]] && pass "G69 a worktree named config launches" \
  || fail "G69 a worktree named config refused (rc=$LAUNCH_RC; $(grep -F ERROR "$ERR" | head -1))"
rm -rf "$M69" "$PROJ/config"

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

# ── G90: CDPATH (GIT-17). A submodule's relative core.worktree with no ./ or
# ../ is resolved by `cd`, which an exported CDPATH redirects — and makes print
# the directory it went to. Here core.worktree=wt72 names a link in the
# submodule's git directory to its checkout, and a nested submodule under
# vendor/ (pruned by the scan; its own git directory has no core.worktree) is
# found only through that checkout's index, so a misplaced worktree loses it.
U72="$TMP/up72"; S72="$TMP/us72"; M72="$TMP/m72"; D72="$TMP/decoy72"
for r in "$U72" "$S72"; do "${G[@]}" init -q "$r" && "${G[@]}" -C "$r" commit -q --allow-empty -m r; done
mkdir -p "$D72/wt72"
"${G[@]}" init -q "$M72" \
  && "${G[@]}" -C "$M72" -c protocol.file.allow=always submodule -q add "$U72" vendor/a && "${G[@]}" -C "$M72" commit -q -m a \
  && "${G[@]}" -C "$M72/vendor/a" -c protocol.file.allow=always submodule -q add "$S72" vendor/b \
  && "${G[@]}" -C "$M72/vendor/a" commit -q -m b \
  && ln -s "$M72/vendor/a" "$M72/.git/modules/vendor/a/wt72" \
  && "${G[@]}" config -f "$M72/.git/modules/vendor/a/config" core.worktree wt72 \
  && "${G[@]}" config -f "$M72/.git/modules/vendor/a/modules/vendor/b/config" --unset core.worktree \
  || { printf 'SCAFFOLD-FAILED: cannot create the G90 repository\n'; exit 1; }
want72="$M72/vendor/a/vendor/b/.git:/workspace/m72/vendor/a/vendor/b/.git:ro"
EXTRA_MOUNTS="$M72" launch "$TMP/app"
has_mount "$want72" && pass "G90 (control) a nested submodule found through a relative core.worktree is protected" \
  || fail "G90 control: no $want72 (git mounts: $(git_mounts | grep m72 | tr '\n' ' '))"
CDPATH="$D72" EXTRA_MOUNTS="$M72" launch "$TMP/app"
has_mount "$want72" && pass "G90 an exported CDPATH does not move a relative core.worktree" \
  || fail "G90 with CDPATH set, $want72 is missing (git mounts: $(git_mounts | grep m72 | tr '\n' ' '))"
rm -rf "$U72" "$S72" "$M72" "$D72"

# ── G91: a newline in a directory name (GIT-18). A .git file there naming its
# git directory relatively was given a lexical path cut at the newline, which
# never matched the physical one: a spurious "through a link" WARNING.
M73="$TMP/m73"; NL73="$M73/a"$'\n'"b"
mkdir -p "$NL73" && "${G[@]}" init -q --bare "$M73/real73" \
  && printf 'gitdir: ../real73\n' > "$NL73/.git" \
  || { printf 'SCAFFOLD-FAILED: cannot create the G91 repository\n'; exit 1; }
EXTRA_MOUNTS="$M73" launch "$TMP/app"
grep -q 'reaches .*real73 through a link' "$ERR" \
  && fail "G91 a newline in the .git file's directory gave a spurious link WARNING: $(grep -a 'through a link' "$ERR" | head -1)" \
  || pass "G91 a newline in a directory name does not cut its lexical path"
grep -qF "$M73/real73/config:/workspace/m73/real73/config:ro" <<<"$(mounts)" \
  && pass "G91 (control) the git directory it names is protected" || fail "G91 control: real73 not protected"
rm -rf "$M73"

# Loads one function from the launcher, which cannot be sourced whole (it runs).
load_fn() { eval "$(awk -v f="$1() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh")"; }

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

# ── G84: a small git file swapped for a FIFO cannot hang the read ───────────
# .git files, commondir, gitdir and config are checked as regular files, then
# read; a concurrent container can swap one for a FIFO in between, which blocked
# the launch for ever. Each read is bounded (_rd, and _git_file_config) (GIT-10).
load_fn _timeout_prefix; load_fn _rd_prep; load_fn _rd; _rd_t=(); _rd_init=""
# The bound alone, here in the test's own shell: _rd_fail would signal it (G86).
_rd_fail() { :; }
if [[ -n "$(_timeout_prefix)" ]]; then
  mkfifo "$TMP/f84"; t84=$SECONDS
  _rd 4096 "$TMP/f84" >/dev/null 2>&1; d84=$((SECONDS - t84))
  ( exec 3<>"$TMP/f84" ) 2>/dev/null; rm -f "$TMP/f84"
  (( d84 <= 6 )) && pass "G84 a read of a FIFO swapped in for a small git file is cut off (${d84}s)" \
    || fail "G84 a FIFO read took ${d84}s"
else
  printf 'SKIP: G84 — no timeout or gtimeout here\n'
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

# ── G86: a read cut off by its bound refuses the launch, it is not "unset" ──
# G84's bound turned a hang into a key read as absent, which fails open for the
# checks that read a config (automated security review of 116129d, HIGH); and
# the awk fallback, where there is no git, read only the first MiB of a config
# (MEDIUM). Either now signals the launcher (USR1), which refuses. Each case runs
# as its own process, as the launcher does: the signal goes to $$.
fns86="$TMP/fns86.sh"
for f86 in _term _timeout_prefix _rd_prep _rd _rd_fail _git_file_config _git_config_bool; do
  awk -v f="$f86() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {exit}' "$ENGINE/sandbox.sh"
done > "$fns86"; printf '_rd_t=(); _rd_init=""\nexec {_rd_errfd}>&2\ntrap "exit 3" USR1\n' >> "$fns86"
if [[ -n "$(_timeout_prefix)" ]]; then
  mkfifo "$TMP/f86"
  # 2>/dev/null, as every real caller has: the ERROR still reaches the launcher's
  # stderr (review of the batch 10 branch: it was silent).
  bash -c 'source "$1"; _rd 4096 "$2" >/dev/null 2>/dev/null; echo continued' _ "$fns86" "$TMP/f86" >"$TMP/o86" 2>"$TMP/e86"; rc86=$?
  ( exec 3<>"$TMP/f86" ) 2>/dev/null; rm -f "$TMP/f86"
  [[ "$rc86" == 3 && ! -s "$TMP/o86" ]] && grep -qF 'could not be read' "$TMP/e86" \
    && pass "G86 a small git file whose read is cut off stops the launch" \
    || fail "G86 cut-off read (rc=$rc86; $(cat "$TMP/o86" "$TMP/e86" | tr '\n' ' '))"
fi
mkdir -p "$TMP/nogit86"; for t in awk head wc timeout gtimeout uname tr mktemp rm; do p86="$(command -v "$t" 2>/dev/null)" && ln -sf "$p86" "$TMP/nogit86/$t"; done
# Past the cap in plain bytes, and in NUL bytes, which a shell variable drops
# (automated security review of 37c5ace).
for pad86 in '#' 'NUL'; do
  if [[ "$pad86" == NUL ]]; then
    { printf '[extensions]\n\tworktreeConfig = false\n'; head -c 1100000 /dev/zero; printf '\n'; } > "$TMP/big86.config"
  else
    { printf '[extensions]\n\tworktreeConfig = false\n'; head -c 1100000 /dev/zero | tr '\0' '#'; printf '\n'; } > "$TMP/big86.config"
  fi
  PATH="$TMP/nogit86" "$BASH" -c 'source "$1"; _git_config_bool "$2" extensions.worktreeConfig; echo continued' _ "$fns86" "$TMP/big86.config" >"$TMP/o86" 2>"$TMP/e86"; rc86=$?
  [[ "$rc86" == 3 && ! -s "$TMP/o86" ]] && pass "G86 the awk fallback refuses a config past its read cap ($pad86 padding)" \
    || fail "G86 awk fallback on a big config, $pad86 padding (rc=$rc86; $(cat "$TMP/o86" "$TMP/e86" | tr '\n' ' '))"
done
rm -rf "$TMP/nogit86" "$TMP/big86.config" "$TMP/o86" "$TMP/e86" "$fns86"

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
mkdir -p "$TMP/elsewhere92"; ln -s "$TMP/elsewhere92" "$HOME/.ai-containers/g92"
AI_CONTAINER_GROUP=g92 launch ..
[[ "$LAUNCH_RC" != 0 && ! -e "$CAPTURE" ]] && grep -qF 'is a link' "$ERR" \
  && pass "G92 a group directory that is a link refuses the launch, before docker" \
  || fail "G92 a linked group directory (rc=$LAUNCH_RC; $(grep -E 'ERROR|link' "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$HOME/.ai-containers/g92"; rm -rf "$TMP/elsewhere92"
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
# A committed sandbox.env that names the host group, which the loader once
# ignored, now refuses the launch, naming the file (review of batch 11).
[[ -f "$LAUNCHER/sandbox.env" ]] && cp "$LAUNCHER/sandbox.env" "$TMP/se92.bak"
printf 'AI_CONTAINER_GROUP=host\n' >> "$LAUNCHER/sandbox.env"
( unset AI_CONTAINER_GROUP; launch .. )
grep -qF "AI_CONTAINER_GROUP=host is set in $LAUNCHER/sandbox.env" "$ERR" && grep -qF 'from:host' "$ERR" && [[ ! -e "$CAPTURE" ]] \
  && pass "G92 a committed sandbox.env naming the host group refuses the launch, naming the file" \
  || fail "G92 host group from sandbox.env ($(grep -E 'ERROR|NOTE' "$ERR" | head -2 | tr '\n' ' '))"
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
