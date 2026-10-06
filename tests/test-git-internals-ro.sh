#!/usr/bin/env bash
# What the HOST's git runs from a repository must not be writable from inside
# the container: its hooks/, and config, whose keys run programs (core.hooksPath,
# core.fsmonitor, core.sshCommand, filters). sandbox.sh mounts them read-only
# inside every writable mount that exposes a git directory, pins the directories
# above them so .git cannot be renamed away, and leaves objects, refs and the
# index writable (launcher_ro_overlay, git_dirs_in).
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
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE
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
[[ "$(git_mounts | wc -l | tr -d ' ')" == 3 ]] \
  && pass "G1 and nothing else of .git: objects, refs and the index stay writable" \
  || fail "G1 exactly three git mounts (got: $(git_mounts | tr '\n' ' '))"
grep -qF 'READ-ONLY: /workspace/proj/.git: config, hooks' "$ERR" \
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
: > "$PROJ/.git/config.worktree"
launch ..
has_mount "$PROJ/.git/config.worktree:/workspace/proj/.git/config.worktree:ro" \
  && pass "G3 config.worktree is read-only too, where it exists" \
  || fail "G3 config.worktree (git mounts: $(git_mounts | tr '\n' ' '))"
rm -f "$PROJ/.git/config.worktree"

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
launch ..
has_mount "$PROJ/.git/modules/lib/config:/workspace/proj/.git/modules/lib/config:ro" \
  && has_mount "$PROJ/.git/modules/lib/hooks:/workspace/proj/.git/modules/lib/hooks:ro" \
  && has_mount "$PROJ/.git/modules:/workspace/proj/.git/modules:rw" \
  && pass "G5 a submodule's git directory gets the same, the way down pinned" \
  || fail "G5 submodule gitdir (git mounts: $(git_mounts | tr '\n' ' '))"
has_mount "$PROJ/lib/.git:/workspace/proj/lib/.git:ro" \
  && pass "G5 its checkout's .git file is read-only" \
  || fail "G5 submodule .git file (git mounts: $(git_mounts | tr '\n' ' '))"

# ── G6: a bare repository a writable mount exposes ────────────────────────────
mkdir -p "$TMP/extra" && "${G[@]}" init -q --bare "$TMP/extra/origin.git"
EXTRA_MOUNTS="$TMP/extra" launch "$TMP/app"
has_mount "$TMP/extra/origin.git/config:/workspace/extra/origin.git/config:ro" \
  && has_mount "$TMP/extra/origin.git/hooks:/workspace/extra/origin.git/hooks:ro" \
  && pass "G6 a bare repository is matched by content and protected the same way" \
  || fail "G6 bare repo (mounts: $(mounts | grep extra | tr '\n' ' '))"

# ── G7: a read-only mount needs nothing ───────────────────────────────────────
EXTRA_MOUNTS="$TMP/extra:ro" launch "$TMP/app"
[[ -s "$CAPTURE" ]] && ! mounts | grep -q 'origin.git/' \
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
has_mount "$TMP/wrap/eng:/workspace/wrap/eng:ro" && ! mounts | grep -q 'wrap/eng/.git' \
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
! mounts | grep -q '/app/docs' && pass "G11 a stray HEAD file is not taken for a git directory" \
  || fail "G11 stray HEAD (mounts: $(mounts | grep '/app/' | tr '\n' ' '))"

# ── G12: depth — a checkout six levels down is found, seven is not ────────────
mkdir -p "$TMP/deep/1/2/3/4/5/6/7"
"${G[@]}" -C "$TMP/deep/1/2/3/4/5/6" init -q 2>/dev/null; "${G[@]}" -C "$TMP/deep/1/2/3/4/5/6/7" init -q 2>/dev/null
EXTRA_MOUNTS="$TMP/deep" launch "$TMP/app"
has_mount "$TMP/deep/1/2/3/4/5/6/.git/config:/workspace/deep/1/2/3/4/5/6/.git/config:ro" \
  && ! mounts | grep -q '/6/7/.git' \
  && pass "G12 a checkout six levels below the mount root is protected; seven is past the limit" \
  || fail "G12 depth (mounts: $(mounts | grep '/deep/' | tr '\n' ' '))"
rm -rf "$TMP/deep"

# ── G13: the concurrent-swap manifest records every git mount ─────────────────
launch ..
ok=1
for d in /workspace/proj/.git /workspace/proj/.git/config /workspace/proj/.git/hooks; do
  tr '\0' '\n' < "$CAPTURE.manifest" 2>/dev/null | grep -qxF -- "$d" || ok=""
done
[[ -n "$ok" ]] && pass "G13 the verify manifest covers the .git pin and its read-only mounts" \
  || fail "G13 manifest (has: $(tr '\0' ' ' < "$CAPTURE.manifest" 2>/dev/null | head -c 400))"

# ── G14: no repository, no git mounts ─────────────────────────────────────────
launch "$TMP/app"
[[ -s "$CAPTURE" && -z "$(git_mounts)" ]] && pass "G14 a mount with no repository gets no git mounts" \
  || fail "G14 no repo (git mounts: $(git_mounts | tr '\n' ' '))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
