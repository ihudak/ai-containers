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
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE SANDBOX_GIT_MAX
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
cp -R "$ENGINE/tools.d" "$ENGINE/services.d" "$LAUNCHER/"
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
grep -qF 'filter.x.smudge' <<<"$(grep -A1 -F 'NOTE: /workspace/fp/wtc/.git is protected for the first time' "$ERR")" \
  && grep -qF "git config --file $TMP/fp/wtc/.git/config.worktree --list" "$ERR" \
  && pass "G26 a key set only in config.worktree is named, with config.worktree to review" \
  || fail "G26 config.worktree key (stderr: $(grep -A4 'wtc/.git is protected' "$ERR" | tr '\n' ' '))"
nl26="$(grep -A1 -F 'NOTE: /workspace/fp/r/.git is protected for the first time' "$ERR" | tail -1)"
[[ "$nl26" == *core.sshcommand* && "$nl26" == *core.fsmonitor* && "$nl26" == *filter.lfs.clean* && "$nl26" == *alias.sh* ]] \
  && grep -qF "git config --file $TMP/fp/r/.git/config --list" "$ERR" \
  && pass "G26 the first protection names the keys that run programs, and how to review them" \
  || fail "G26 first-protection NOTE (got: $nl26; stderr: $(grep -A3 'first time' "$ERR" | tr '\n' ' '))"
[[ "$nl26" != *alias.st* ]] && ! grep -q 'fp/clean/.git is protected for the first time' "$ERR" \
  && pass "G26 a plain alias, and git's own fsmonitor daemon, are not named" \
  || fail "G26 benign keys named (got: $nl26; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
! grep -qF 'sekrit' "$ERR" && pass "G26 no value is printed" || fail "G26 a value was printed"
EXTRA_MOUNTS="$TMP/fp" launch "$TMP/app"
[[ "$LAUNCH_RC" == 0 ]] && ! grep -q 'protected for the first time' "$ERR" \
  && pass "G26 the next launch says nothing: the repository is already protected" \
  || fail "G26 repeated NOTE (rc=$LAUNCH_RC; stderr: $(grep 'first time' "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/fp"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
