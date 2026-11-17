#!/usr/bin/env bash
# Integration tests for DOCS_PATH handling in sandbox.sh.
# Uses a fake `docker` on PATH to capture the assembled `docker run` args
# without launching a container.
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR REPO_VOLUME_PREFIX

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

setup() {
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  # RESOLVED once, here, rather than compared unresolved later. sandbox.sh
  # canonicalises every mount source before it reaches the docker argv, so a
  # test that greps the captured argv for the raw `mktemp -d` path is comparing
  # an unresolved value against a resolved one. That is invisible wherever the
  # temp directory is not a symlink — CI, the floor container — and fails on
  # every macOS run, where /var is a symlink to /private/var. Resolving TMP at
  # the source fixes every assertion in this file at once instead of each in
  # turn. Reproduced on Linux with TMPDIR pointed at a symlink.
  TMP="$(p_realdir "$TMP")"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export AI_CONTAINER_GROUP_INIT=clean   # non-interactive group bootstrap
  # Isolate from any VAULT_PATH/SPECS_PATH/ARCHITECTURE_REPO_PATH exported in the
  # invoking shell (e.g. a host profile, or this very repo's own dev container)
  # so the qmd-warning cases only ever see the corpora each case sets up itself.
  unset VAULT_PATH SPECS_PATH ARCHITECTURE_REPO_PATH
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/docker-calls.txt"
# A working copy's seeding run (--entrypoint bash): FAKE_SEED_FAIL makes it fail,
# FAKE_SEED_TERM kills the launcher while it runs (LNCH-31).
if [[ "\$1" == "run" && "\$*" == *"--entrypoint bash"* ]]; then
  [[ -n "\${FAKE_SEED_FAIL:-}" ]] && exit 125
  if [[ -n "\${FAKE_SEED_TERM:-}" ]]; then kill -TERM "\$PPID"; sleep 0.3; exit 143; fi
  # FAKE_SEED_HANG: a copy that goes on after the launcher is told to stop.
  if [[ -n "\${FAKE_SEED_HANG:-}" ]]; then kill -TERM "\$PPID"; sleep 30; exit 0; fi
fi
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
# The daemon's id, which a seeding record is kept under (FAKE_DAEMON_ID).
if [[ "\$1" == info && "\$*" == *'{{.ID}}'* ]]; then printf '%s\n' "\${FAKE_DAEMON_ID:-}"; exit 0; fi
# The project image is there unless FAKE_NO_IMAGE.
if [[ "\$1 \$2" == "image inspect" ]]; then [[ -z "\${FAKE_NO_IMAGE:-}" ]]; exit; fi
# Volume queries succeed with no output: a registered repo's volume counts as
# PRESENT, so a volume-backed repo can be exercised without a daemon. Without
# this, sandbox.sh stops at "its docker volume is missing" before reaching any
# mount decision, and a case meant to test that decision never gets there.
# A label query answers the volume's entry in FAKE_LABELS ("vol=owner ..."), else
# FAKE_REPO_LABEL (empty by default: an unlabelled volume). FAKE_WC_MISSING makes
# a working copy absent, so :rwcopy seeds it.
if [[ "\$1" == "volume" ]]; then
  vol="\${!#}"
  if [[ "\$*" == *Labels* ]]; then
    lbl="\${FAKE_REPO_LABEL:-}"
    for kv in \${FAKE_LABELS:-}; do [[ "\${kv%%=*}" == "\$vol" ]] && lbl="\${kv#*=}"; done
    printf '%s\n' "\$lbl"; exit 0
  fi
  # A missing volume is answered as docker answers it: the launcher tells "no
  # such volume" from a daemon that could not say (LNCH-31's review);
  # FAKE_INSPECT_ERR is the latter for a working copy.
  if [[ "\$2" == inspect && "\$vol" == *--wc-* && -n "\${FAKE_INSPECT_ERR:-}" ]]; then
    echo "Error response from daemon: context deadline exceeded" >&2; exit 1
  fi
  # FAKE_WC_SEEDING_NOW=<record>: another launch begins seeding the working
  # copy as this one looks at it: its record appears (FAKE_WC_SEEDING_ID) and
  # its half-made volume is there.
  if [[ "\$2" == inspect && "\$vol" == *--wc-* && -n "\${FAKE_WC_SEEDING_NOW:-}" ]]; then
    mkdir -p "\${FAKE_WC_SEEDING_NOW%/*}"; printf '%s\n' "\$FAKE_WC_SEEDING_ID" > "\$FAKE_WC_SEEDING_NOW"; exit 0
  fi
  # FAKE_WC_APPEARS: the working copy is missing at the first look and there
  # at the next, as when another launch seeds it in between.
  if [[ "\$2" == inspect && "\$vol" == *--wc-* && -n "\${FAKE_WC_APPEARS:-}" ]]; then
    if [[ ! -e "$TMP/looked-\$vol" ]]; then : > "$TMP/looked-\$vol"; echo "Error: get \$vol: no such volume" >&2; exit 1; fi
    exit 0
  fi
  if [[ "\$2" == inspect && "\$vol" == *--wc-* && -n "\${FAKE_WC_MISSING:-}" && ! -e "$TMP/made-\$vol" ]]; then
    echo "Error response from daemon: get \$vol: no such volume" >&2; exit 1
  fi
  [[ "\$2" == create ]] && : > "$TMP/made-\$vol"
  [[ "\$2" == rm ]] && rm -f "$TMP/made-\$vol"
  # FAKE_VOL_MISSING: no base volume either (a registered repo whose volume is gone).
  if [[ "\$2" == inspect && -n "\${FAKE_VOL_MISSING:-}" ]]; then
    echo "Error response from daemon: get \$vol: no such volume" >&2; exit 1
  fi
  exit 0
fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; unset DOCS_PATH VAULT_PATH SPECS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS SANDBOX_CONF REPOS; }

# run sandbox.sh restricted <primary>; sets RC and writes stderr to $ERR.
run_sandbox() {
  ERR="$TMP/stderr.txt"
  # Launched from a temp dir: sandbox.sh writes its .agent-blocked/.agent-discovery
  # output dirs into $PWD, which must not be the repo.
  mkdir -p "$TMP/launch"
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# run_sandbox under a clock (GIT-25): RC is 124 when the launch was cut off. In
# a process group of its own, KILLed whole at the clock: killing the launcher
# alone left the git it ran blocked on the FIFO for good.
run_sandbox_bounded() {  # <seconds> <sandbox.sh args>...
  local secs="$1" pid waited=0; shift
  ERR="$TMP/stderr.txt"
  mkdir -p "$TMP/launch"
  set -m
  ( cd "$TMP/launch" && exec bash "$REPO_DIR/sandbox.sh" restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null && (( waited < secs * 10 )); do sleep 0.1; waited=$(( waited + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    RC=124
  else
    wait "$pid"; RC=$?
  fi
}

# Register a GIT-sourced repo plus a local checkout whose `origin` is that URL.
# The registry holds a URL for these, so identity cannot come from a path
# comparison — sandbox.sh asks the pointer's own checkout what it was cloned
# from. Call AFTER setup().
register_git_repo() {  # $1=name $2=url $3=local-checkout-dir
  mkdir -p "$HOME/.ai-containers" "$3"
  printf '%s|git|%s|0|0|volume\n' "$1" "$2" >> "$HOME/.ai-containers/repos.conf"
  ( cd "$3" && git init -q && git remote add origin "$2" ) >/dev/null 2>&1
}

# Register a bind-backend 'path' repo in the temp HOME registry (no docker volume
# needed on Linux: the repo loop bind-mounts the source directly). Call AFTER setup().
register_repo() {  # $1=name $2=source-dir
  mkdir -p "$HOME/.ai-containers"
  printf '%s|path|%s|0|0|bind\n' "$1" "$2" >> "$HOME/.ai-containers/repos.conf"
}

# Case 1: DOCS_PATH set, dir exists, not primary → :ro mount + env re-export.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if grep -q "/workspace/docs:ro" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE" \
   && ! grep -q "DOCS_PATH has been removed" "$ERR"; then
  pass "ro mount + env re-export"; else fail "ro mount + env re-export"; fi
teardown

# Case 2: DOCS_PATH set to a missing dir → WARNING, no docs mount.
setup
mkdir -p "$TMP/app"
export DOCS_PATH="$TMP/nope"
run_sandbox "$TMP/app"
if grep -q "WARNING: DOCS_PATH is set but directory does not exist" "$ERR" \
   && ! grep -q "/workspace/docs:ro" "$CAPTURE"; then
  pass "missing dir → warning, no mount"; else fail "missing dir → warning, no mount"; fi
teardown

# Case 3: name 'docs' already claimed (EXTRA_MOUNTS) → collision error, non-zero exit.
setup
mkdir -p "$TMP/docs" "$TMP/mydocs" "$TMP/app"
export EXTRA_MOUNTS="$TMP/docs"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if [[ $RC -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
  pass "collision on docs → error"; else fail "collision on docs → error"; fi
teardown

# Case 4: docs repo passed as the primary (== $DOCS_PATH) → re-point, no grounding mount.
setup
mkdir -p "$TMP/productdocs" "$TMP/app"
export DOCS_PATH="$TMP/productdocs"
run_sandbox "$TMP/productdocs"
if grep -q ":/workspace/productdocs:rw" "$CAPTURE" \
   && grep -qx "DOCS_PATH=/workspace/productdocs" "$CAPTURE" \
   && ! grep -q ":/workspace/docs:" "$CAPTURE"; then
  pass "docs==workdir → re-point, no grounding mount"; else fail "docs==workdir → re-point, no grounding mount"; fi
teardown

# Case 5: qmd=OFF + DOCS mounted → exactly one warning naming DOCS_PATH.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
sed 's/^qmd=.*/qmd=OFF/' "$REPO_DIR/sandbox.conf" > "$TMP/conf-off"
export SANDBOX_CONF="$TMP/conf-off"   # force qmd=OFF; don't couple to the committed default
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if grep -q "qmd=OFF in sandbox.conf, but markdown corpora are mounted (DOCS_PATH)" "$ERR" \
   && [[ "$(grep -c 'qmd=OFF' "$ERR")" -eq 1 ]]; then
  pass "qmd=OFF → one consolidated warning"; else fail "qmd=OFF → one consolidated warning"; fi
teardown

# Case 6: qmd=ON (via SANDBOX_CONF) + DOCS mounted → no qmd warning.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
sed 's/^qmd=.*/qmd=ON/' "$REPO_DIR/sandbox.conf" > "$TMP/conf-on"
export SANDBOX_CONF="$TMP/conf-on"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "qmd=ON → no warning"; else fail "qmd=ON → no warning"; fi
teardown

# Case 7: no corpus mounted → no qmd warning.
setup
mkdir -p "$TMP/app"
run_sandbox "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "no corpus → no warning"; else fail "no corpus → no warning"; fi
teardown

# Case V: VAULT_PATH set → mounted rw at /workspace/vault (not /workspace/obsidian).
setup
mkdir -p "$TMP/mykb" "$TMP/app"
export VAULT_PATH="$TMP/mykb"
run_sandbox "$TMP/app"
if grep -q ":/workspace/vault:rw" "$CAPTURE" && grep -qx "VAULT_PATH=/workspace/vault" "$CAPTURE" \
   && ! grep -q "obsidian" "$CAPTURE"; then
  pass "VAULT_PATH → /workspace/vault"; else fail "VAULT_PATH → /workspace/vault"; fi
teardown

# Case 8: DOCS_PATH=@name (registered) → mount at /workspace/<name> ro + env re-point.
setup
mkdir -p "$TMP/docsvol" "$TMP/app"
register_repo docs2 "$TMP/docsvol"
export DOCS_PATH="@docs2"
run_sandbox "$TMP/app"
if grep -q ":/workspace/docs2:ro" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs2" "$CAPTURE"; then
  pass "DOCS_PATH=@name → /workspace/docs2 ro"; else fail "DOCS_PATH=@name → /workspace/docs2 ro"; fi
teardown

# Case 9: SPECS_PATH=@name (registered) → mount at /workspace/<name> rw + env re-point.
setup
mkdir -p "$TMP/specsvol" "$TMP/app"
register_repo specs2 "$TMP/specsvol"
export SPECS_PATH="@specs2"
run_sandbox "$TMP/app"
if grep -q ":/workspace/specs2:rw" "$CAPTURE" && grep -qx "SPECS_PATH=/workspace/specs2" "$CAPTURE"; then
  pass "SPECS_PATH=@name → /workspace/specs2 rw"; else fail "SPECS_PATH=@name → /workspace/specs2 rw"; fi
teardown

# Case 10: DOCS_PATH=<path>:rw (not primary) → grounding mount is rw.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs:rw"
run_sandbox "$TMP/app"
if grep -q ":/workspace/docs:rw" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "DOCS_PATH=path:rw → /workspace/docs rw"; else fail "DOCS_PATH=path:rw → /workspace/docs rw"; fi
teardown

# ── The pointer names a directory that is ALREADY mounted ─────────────────────
#
# Reported 2026-08-21: DOCS_PATH exported once on the host for every project,
# and the docs project itself attached as repo `docs`. Both wanted
# /workspace/docs, so the container refused to start:
#
#   ERROR: name 'docs' is used by REPOS, but DOCS_PATH also mounts at /workspace/docs.
#
# Nothing was wrong with the setup. The pointer and the repo were the same
# checkout, and the only remedies were to unset a global variable for one
# project or rename the repo.

# Case 11: DOCS_PATH is the SAME checkout as a repo attached under the name
# 'docs' → re-point, do not mount twice, do not refuse.
setup
mkdir -p "$TMP/docsrepo" "$TMP/app"
register_repo docs "$TMP/docsrepo"
export DOCS_PATH="$TMP/docsrepo" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE" \
   && [[ "$(grep -c "$TMP/docsrepo:" "$CAPTURE")" -eq 1 ]]; then
  pass "DOCS_PATH == repo 'docs' → re-points, single mount, starts"
else
  fail "DOCS_PATH == repo 'docs' → re-points, single mount, starts (rc=$RC)"
fi
teardown

# Case 12: same checkout, but the repo is attached under a DIFFERENT name → the
# pointer follows it there. The name 'docs' is free; mounting again would still
# be a duplicate of the same directory.
setup
mkdir -p "$TMP/docsrepo" "$TMP/app"
register_repo mydocs "$TMP/docsrepo"
export DOCS_PATH="$TMP/docsrepo" REPOS="mydocs:ro"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/mydocs" "$CAPTURE" \
   && [[ "$(grep -c "$TMP/docsrepo:" "$CAPTURE")" -eq 1 ]]; then
  pass "DOCS_PATH == repo under another name → follows it"
else
  fail "DOCS_PATH == repo under another name → follows it (rc=$RC)"
fi
teardown

# Case 13: THE REGRESSION GUARD. A DIFFERENT directory, with the name 'docs'
# already taken, must still be refused — the fix must not turn a real collision
# into a silent wrong mount.
setup
mkdir -p "$TMP/docsrepo" "$TMP/otherdocs" "$TMP/app"
register_repo docs "$TMP/docsrepo"
export DOCS_PATH="$TMP/otherdocs" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
  pass "a DIFFERENT directory colliding on 'docs' is still refused"
else
  fail "a DIFFERENT directory colliding on 'docs' is still refused (rc=$RC)"
fi
teardown

# Case 14: the same accommodation for SPECS_PATH.
setup
mkdir -p "$TMP/specsrepo" "$TMP/app"
register_repo specs "$TMP/specsrepo"
export SPECS_PATH="$TMP/specsrepo" REPOS="specs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "SPECS_PATH=/workspace/specs" "$CAPTURE"; then
  pass "SPECS_PATH == repo 'specs' → re-points"; else fail "SPECS_PATH == repo 'specs' → re-points (rc=$RC)"; fi
teardown

# Case 15: and for VAULT_PATH.
setup
mkdir -p "$TMP/vaultrepo" "$TMP/app"
register_repo vault "$TMP/vaultrepo"
export VAULT_PATH="$TMP/vaultrepo" REPOS="vault:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "VAULT_PATH=/workspace/vault" "$CAPTURE"; then
  pass "VAULT_PATH == repo 'vault' → re-points"; else fail "VAULT_PATH == repo 'vault' → re-points (rc=$RC)"; fi
teardown

# Case 16: the repo was seeded from a GIT URL, and DOCS_PATH is a local checkout
# of the same repository. The registry has no host path to compare, so identity
# comes from the checkout's own `origin`. Reported 2026-08-21: the first fix
# covered path-sourced repos only, and this is the shape a real user had.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE" \
   && [[ "$(grep -c "$TMP/docsco:" "$CAPTURE")" -eq 0 ]]; then
  pass "DOCS_PATH is a checkout of the git-sourced repo → re-points, no second mount"
else
  fail "DOCS_PATH is a checkout of the git-sourced repo → re-points, no second mount (rc=$RC)"
fi
teardown

# Case 17: URL SPELLING must not decide it. Same repository written scp-style
# and without .git; the registry has the ssh:// form.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
( cd "$TMP/docsco" && git remote set-url origin git@example.org:team/docs ) >/dev/null 2>&1
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "scp-form and ssh:// spellings of one repository match"
else
  fail "scp-form and ssh:// spellings of one repository match (rc=$RC)"
fi
teardown

# Case 18: THE REGRESSION GUARD for the git path. A DIFFERENT repository must
# still be refused — proving the match is on identity, not on "is a git repo".
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
mkdir -p "$TMP/other"; ( cd "$TMP/other" && git init -q && git remote add origin ssh://git@example.org/team/OTHER.git ) >/dev/null 2>&1
export DOCS_PATH="$TMP/other" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
  pass "a DIFFERENT git repository colliding on 'docs' is still refused"
else
  fail "a DIFFERENT git repository colliding on 'docs' is still refused (rc=$RC)"
fi
teardown

# GIT-25: the checkout's origin is read from its config FILE, bounded and with
# no includes, never by running git there. `git remote get-url` read the
# repository's config, includes and all, with no bound: a FIFO an include named
# hung the launch before anything was mounted, and the message named nothing.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
git -C "$TMP/docsco" config include.path "$TMP/inc25" >/dev/null 2>&1
mkfifo "$TMP/inc25"
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox_bounded 30 "$TMP/app"
( exec 3<>"$TMP/inc25" ) 2>/dev/null
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 an include in the pointer's config that names a FIFO does not hold the launch"
else
  fail "GIT-25 an include that names a FIFO held the launch, or the pointer did not re-point (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# GIT-89: a config of very many origin URLs is not read whole in a bash loop
# under the read bound, which refused the launch as "host may be busy": past
# 1200 the origin is taken for unknown, as for a config that cannot be read.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
awk 'BEGIN { print "[remote \"origin\"]"; for (i = 0; i < 300000; i++) print "\turl = ssh://git@example.org/team/docs.git" }' >> "$TMP/docsco/.git/config"
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox_bounded 60 "$TMP/app"
if [[ "$RC" -ne 124 ]] && ! grep -q 'could not be read within' "$ERR"; then
  pass "GIT-89 a config of 300,000 origin URLs is not read whole (rc=$RC)"
else
  fail "GIT-89 300,000 origin URLs (rc=$RC; $(grep -m1 -E 'ERROR|could not' "$ERR"))"
fi
teardown

# A linked worktree: its .git file's gitdir: and its commondir are followed to
# the config that holds origin.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
( cd "$TMP/docsco" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m s \
    && git worktree add -q "$TMP/docswt" ) >/dev/null 2>&1
export DOCS_PATH="$TMP/docswt" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ -f "$TMP/docswt/.git" && "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 a linked worktree of the git-sourced repo re-points"
else
  fail "GIT-25 a linked worktree of the git-sourced repo did not re-point (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# A subdirectory of the checkout: its repository is found as git finds it, the
# nearest .git above, as before the fix.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
mkdir -p "$TMP/docsco/guide"
export DOCS_PATH="$TMP/docsco/guide" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 a subdirectory of the checkout re-points, as git -C did"
else
  fail "GIT-25 a subdirectory of the checkout did not re-point (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# With no git-sourced repo attached there is nothing to compare an origin with,
# and the checkout's config, which the agent can write, is not read at all.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/git-calls.txt" "$(command -v git)" > "$TMP/bin/git"
chmod +x "$TMP/bin/git"; : > "$TMP/git-calls.txt"
export DOCS_PATH="$TMP/docsco"
run_sandbox "$TMP/app"
# Any git call naming the checkout counts: `git -C <checkout> remote get-url` too.
if [[ "$RC" -eq 0 ]] && grep -q ":/workspace/docs:ro" "$CAPTURE" && ! grep -q -e docsco -e get-url "$TMP/git-calls.txt"; then
  pass "GIT-25 with no git-sourced repo attached, the pointer's origin is not read"
else
  fail "GIT-25 the pointer's origin was read with nothing to compare it with (rc=$RC; $(grep -c -e docsco -e get-url "$TMP/git-calls.txt") read(s))"
fi
teardown

# A shorthand your own config expands (url.<base>.insteadOf) is expanded, as
# `git remote get-url` expanded it: the registry holds the URL repo.sh cloned,
# and its seed container has no ~/.gitconfig, so a shorthand never reaches it.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
printf '[url "ssh://git@example.org/"]\n\tinsteadOf = ex:\n' >> "$HOME/.gitconfig"
git -C "$TMP/docsco" config remote.origin.url ex:team/docs >/dev/null 2>&1
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 an origin written as an insteadOf shorthand matches the repo it expands to"
else
  fail "GIT-25 an origin written as an insteadOf shorthand did not match (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# An empty `url =` empties the list, as git reads remote.<name>.url: the first
# URL after it decides.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
git -C "$TMP/docsco" config remote.origin.url ssh://git@example.org/team/OTHER.git >/dev/null 2>&1
git -C "$TMP/docsco" config --add remote.origin.url "" >/dev/null 2>&1
git -C "$TMP/docsco" config --add remote.origin.url ssh://git@example.org/team/docs.git >/dev/null 2>&1
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 an empty origin URL resets the list, as in git"
else
  fail "GIT-25 an empty origin URL did not reset the list (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# macOS's /usr/bin/git when xcode-select -p fails outright, as on a Mac that
# never had the Command Line Tools: git does not run there (_git_usable), so the
# pointer's origin is not read and the pointer is refused as any collision is.
# Faked with uname and xcode-select (review of the GIT-28 fix, L2).
if [[ "$(command -v git)" == /usr/bin/git ]]; then
  setup
  mkdir -p "$TMP/app" "$TMP/mac"
  register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
  printf '#!/bin/sh\necho Darwin\n' > "$TMP/mac/uname"; printf '#!/bin/sh\nexit 2\n' > "$TMP/mac/xcode-select"
  chmod +x "$TMP/mac/uname" "$TMP/mac/xcode-select"
  export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
  # /usr//bin first: still the shim, which a string compare missed (-ef does not).
  PATH="$TMP/mac:$TMP/bin:/usr//bin:$PATH" run_sandbox "$TMP/app"
  if [[ "$RC" -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
    pass "GIT-25 macOS's git shim is not taken for git when xcode-select -p fails"
  else
    fail "GIT-25 macOS's git shim was taken for git when xcode-select -p failed (rc=$RC; $(head -1 "$ERR"))"
  fi
  teardown
  # What -p names decides only through the git under it: a developer directory
  # since removed, or one without git, is no git (third review of the GIT-24
  # fix), and one with a git is. Mutants that took -p's answer alone, or
  # refused a developer directory holding a git, survived every test (GAP-2's slice 2;
  # sandbox.sh: `_git_usable()`).
  for xdev in none git; do
    setup
    mkdir -p "$TMP/app" "$TMP/mac" "$TMP/xdev"
    register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
    if [[ "$xdev" == git ]]; then
      mkdir -p "$TMP/xdev/usr/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/xdev/usr/bin/git"; chmod +x "$TMP/xdev/usr/bin/git"
    fi
    printf '#!/bin/sh\necho Darwin\n' > "$TMP/mac/uname"; printf '#!/bin/sh\necho %s\n' "$TMP/xdev" > "$TMP/mac/xcode-select"
    chmod +x "$TMP/mac/uname" "$TMP/mac/xcode-select"
    export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
    PATH="$TMP/mac:$TMP/bin:/usr/bin:$PATH" run_sandbox "$TMP/app"
    if [[ "$xdev" == none ]]; then
      if [[ "$RC" -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
        pass "GIT-25 macOS's git shim is not taken for git when xcode-select -p names a directory without git"
      else
        fail "GIT-25 macOS's git shim was taken for git with no git under xcode-select -p (rc=$RC; $(head -1 "$ERR"))"
      fi
    elif [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
      pass "GIT-25 macOS's git is taken for git when xcode-select -p names a directory with git"
    else
      fail "GIT-25 macOS's git was refused with a git under xcode-select -p (rc=$RC; $(head -1 "$ERR"))"
    fi
    teardown
  done
else
  printf 'NOTE: git is not /usr/bin/git here; the macOS shim check is not applicable\n'
fi

# Two origin URLs: the first decides, as `git remote get-url` printed it.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
git -C "$TMP/docsco" config --add remote.origin.url ssh://git@example.org/team/OTHER.git >/dev/null 2>&1
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "GIT-25 of two origin URLs the first decides"
else
  fail "GIT-25 of two origin URLs the first did not decide (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# Where git does not run (here, one that fails the probe, as git before 2.18
# does), git is not asked about the checkout, and the pointer is refused as any
# collision is, as when git -C found no git.
setup
mkdir -p "$TMP/app"
register_git_repo docs ssh://git@example.org/team/docs.git "$TMP/docsco"
register_git_repo lib25 ssh://git@example.org/team/lib.git "$TMP/libco"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$TMP/git-calls.txt" > "$TMP/bin/git"
chmod +x "$TMP/bin/git"; : > "$TMP/git-calls.txt"
export DOCS_PATH="$TMP/docsco" REPOS="docs:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR" \
   && ! grep -q -e remote -e docsco "$TMP/git-calls.txt"; then
  pass "GIT-25 where git does not run, the checkout is not asked, and the pointer is refused"
else
  fail "GIT-25 where git does not run (rc=$RC; git calls: $(grep -e remote -e docsco "$TMP/git-calls.txt" | head -2 | tr '\n' ';'))"
fi
# Asked once per launch, in the launcher's own shell, before the pointer checks:
# asked first in their $(…), the answer was lost and asked again for the overlay.
: > "$TMP/git-calls.txt"; : > "$CAPTURE"
export REPOS="lib25:rw"
run_sandbox "$TMP/app"
n25="$(grep -c -e '--type=bool' "$TMP/git-calls.txt")"
if [[ "$RC" -eq 0 && "$n25" == 1 ]] && grep -q ":/workspace/docs:ro" "$CAPTURE"; then
  pass "GIT-25 whether git runs is asked once per launch"
else
  fail "GIT-25 whether git runs was asked $n25 times (rc=$RC; $(head -1 "$ERR"))"
fi
teardown

# REPO-13: a repo volume is attached by name, and under a nested
# REPO_VOLUME_PREFIX two repos' names collide. A base volume labelled for
# another repo is refused, never handed to the agent; its own label, or none
# (a volume made before labels), attaches as before.
setup
mkdir -p "$TMP/app" "$TMP/lib13"
register_git_repo lib13 "git@example.invalid:lib13.git" "$TMP/lib13"
export REPOS="lib13:rw"
FAKE_REPO_LABEL=other run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 && ! -s "$CAPTURE" ]] && grep -q "labelled for repo 'other'" "$ERR"; then
  pass "REPO-13 a repo volume labelled for another repo is refused, and nothing is launched"
else
  fail "REPO-13 another repo's volume was attached (rc=$RC; $(grep -c 'repo-lib13' "$CAPTURE") mount(s); $(head -1 "$ERR"))"
fi
: > "$CAPTURE"
FAKE_REPO_LABEL=lib13 run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -q 'ai-containers-repo-lib13:/workspace/lib13' "$CAPTURE" \
  && pass "REPO-13 a repo volume labelled for itself attaches" \
  || fail "REPO-13 a correctly labelled repo volume did not attach (rc=$RC; $(head -1 "$ERR"))"
: > "$CAPTURE"
FAKE_REPO_LABEL='' run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -q 'ai-containers-repo-lib13:/workspace/lib13' "$CAPTURE" \
  && pass "REPO-13 an unlabelled repo volume attaches as before" \
  || fail "REPO-13 an unlabelled repo volume did not attach (rc=$RC; $(head -1 "$ERR"))"
# :rwcopy reuses an existing working copy, and working-copy names collide under
# a nested prefix too: one labelled for another repo is refused.
: > "$CAPTURE"
export REPOS="lib13:rwcopy"
FAKE_LABELS="$(printf 'ai-containers-repo-lib13=lib13')" FAKE_REPO_LABEL=other run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 && ! -s "$CAPTURE" ]] && grep -q "lib13--wc-.* is labelled for repo 'other'" "$ERR"; then
  pass "REPO-13 a :rwcopy working copy labelled for another repo is refused"
else
  fail "REPO-13 another repo's working copy was attached (rc=$RC; $(head -1 "$ERR"))"
fi
# Every entry is checked before any is seeded: a refused later entry leaves no
# working copy made for an earlier one.
mkdir -p "$TMP/good13"; register_git_repo good13 "git@example.invalid:good13.git" "$TMP/good13"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
export REPOS="good13:rwcopy lib13:rw"
FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13 ai-containers-repo-lib13=other" run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && ! grep -q '^volume create' "$TMP/docker-calls.txt" && ! grep -q '^run' "$TMP/docker-calls.txt"; then
  pass "REPO-13 a refused later entry: nothing was seeded or run for an earlier one"
else
  fail "REPO-13 seeding ran before a later entry was refused (rc=$RC; $(grep -E '^(volume create|run)' "$TMP/docker-calls.txt" | head -2 | tr '\n' ';'))"
fi
# A working copy is used only once its seeding finished (bugs review LNCH-31):
# one left by a copy cut short was taken as seeded, and mounted empty or in
# part at every later launch. The copy's failure, or the launcher's death
# during it, removes the volume; an image not built is named before any is made.
export REPOS="good13:rwcopy"
seeded() { # <label> <rc expected: 0|nonzero> <grep in stderr>: one launch's checks
  local wc; wc="$(grep -o '^volume create .*' "$TMP/docker-calls.txt" | awk '{print $NF}')"
  if [[ "$1" == ok ]]; then
    [[ "$RC" -eq 0 && -n "$wc" ]] && grep -q -- "--entrypoint bash" "$TMP/docker-calls.txt" \
      && ! grep -q '^volume rm' "$TMP/docker-calls.txt" && grep -q "^$wc:/workspace/good13\$" "$CAPTURE"
  else
    [[ "$RC" -ne 0 && -n "$wc" ]] && grep -qx "volume rm $wc" "$TMP/docker-calls.txt" \
      && grep -q "rm -f $wc-seed-" "$TMP/docker-calls.txt" && grep -qF -- "$2" "$ERR" && [[ ! -s "$CAPTURE" ]]
  fi
}
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_SEED_FAIL=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
seeded fail 'is removed; the next launch seeds it again' \
  && pass "LNCH-31 a failed seeding run removes the working copy and ends the launch" \
  || fail "LNCH-31 a failed seeding run (rc=$RC; $(grep -E '^(volume|rm|run)' "$TMP/docker-calls.txt" | tr '\n' ';' | cut -c1-300); $(grep -F working "$ERR" | head -2 | tr '\n' ' '))"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_SEED_TERM=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
seeded fail 'is removed; the next launch seeds it again' \
  && pass "LNCH-31 a launcher killed while seeding removes the working copy" \
  || fail "LNCH-31 a launcher killed while seeding (rc=$RC; $(grep -E '^(volume|rm|run)' "$TMP/docker-calls.txt" | tr '\n' ';' | cut -c1-300))"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_NO_IMAGE=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 ]] && ! grep -q '^volume create' "$TMP/docker-calls.txt" && grep -qF 'is not built, so the working copy' "$ERR" \
  && pass "LNCH-31 an image not built is named before any working copy is made" \
  || fail "LNCH-31 an image not built (rc=$RC; $(grep -c '^volume create' "$TMP/docker-calls.txt") created; $(head -1 "$ERR"))"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
seeded ok \
  && pass "LNCH-31 a seeding that finishes keeps its working copy and mounts it" \
  || fail "LNCH-31 a finished seeding (rc=$RC; $(grep -E '^(volume|rm|run)' "$TMP/docker-calls.txt" | tr '\n' ';' | cut -c1-300))"
# The seeding is recorded on the host, outside the volume, and the record goes
# only once the copy has finished (review of the LNCH-31 fix): a launcher killed
# with no chance to clean up (SIGKILL, the VM stopped) left a volume the next
# launch mounted as seeded.
wc31="$(grep -o '^volume create .*' "$TMP/docker-calls.txt" | awk '{print $NF}')"; rec31="$HOME/.ai-containers/.seeding/unknown/$wc31"
[[ -n "$wc31" && ! -e "$rec31" && -d "$HOME/.ai-containers/.seeding/unknown" ]] \
  && pass "LNCH-31 a seeding that finishes leaves no record" || fail "LNCH-31 a record left after a finished seeding ($wc31)"
# A record whose launcher is gone: the volume was never mounted, so it is
# removed and seeded again.
printf '999999999 1\n' > "$rec31"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 && ! -e "$rec31" ]] && grep -qx "volume rm $wc31" "$TMP/docker-calls.txt" && grep -q "^volume create .*$wc31\$" "$TMP/docker-calls.txt" \
  && grep -qF "was left half-seeded by a launch that did not finish" "$ERR" && grep -q "^$wc31:/workspace/good13\$" "$CAPTURE" \
  && pass "LNCH-31 a working copy whose seeding launcher died is removed and seeded again" \
  || fail "LNCH-31 a dead launcher's record (rc=$RC; $(grep -E '^(volume|run)' "$TMP/docker-calls.txt" | tr '\n' ';' | cut -c1-300); $(head -2 "$ERR" | tr '\n' ' '))"
# A record whose launcher still runs: another launch is seeding it now, and
# this one neither copies into nor removes it. This shell stands in for it.
me31="$(bash -c 'eval "$(awk "/^_seed_proc\\(\\) \\{/,/^}\$/" "$1")"; _seed_proc "$2"' _ "$REPO_DIR/sandbox.sh" "$$")"
printf '%s\n' "$me31" > "$rec31"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 && ! -s "$CAPTURE" && -e "$rec31" ]] && ! grep -qE '^volume (rm|create)' "$TMP/docker-calls.txt" \
  && grep -qF "is being seeded by another launch (pid $$)" "$ERR" \
  && pass "LNCH-31 a working copy another launch is seeding is neither copied into nor removed: the launch is refused" \
  || fail "LNCH-31 a live launcher's record (rc=$RC; $(grep -E '^volume' "$TMP/docker-calls.txt" | tr '\n' ';'); $(head -2 "$ERR" | tr '\n' ' '))"
rm -f "$rec31"
# A docker that cannot say whether the working copy exists is not taken to say
# it does not: nothing is made or copied over.
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_INSPECT_ERR=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 && ! -s "$CAPTURE" ]] && ! grep -qE '^volume create|--entrypoint bash' "$TMP/docker-calls.txt" \
  && grep -qF 'docker could not say whether the working copy' "$ERR" \
  && pass "LNCH-31 an inspect that fails for another reason than no such volume refuses the launch" \
  || fail "LNCH-31 an inspect error (rc=$RC; $(grep -E '^volume' "$TMP/docker-calls.txt" | tr '\n' ';'); $(head -1 "$ERR"))"
# A dead launcher's record, and a docker that cannot say whether the volume is
# there: nothing is removed, and the record stays for the next launch.
printf '999999999 1\n' > "$rec31"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_INSPECT_ERR=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 && -e "$rec31" ]] && ! grep -qE '^volume (rm|create)' "$TMP/docker-calls.txt" \
  && pass "LNCH-31 a dead launcher's record with a docker that cannot answer removes nothing and keeps the record" \
  || fail "LNCH-31 a dead record and an inspect error (rc=$RC; $(grep -E '^volume' "$TMP/docker-calls.txt" | tr '\n' ';'))"
# A record that holds nothing is no launch's (records are linked into place
# whole): its volume is removed and seeded again.
: > "$rec31"; : > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 && ! -e "$rec31" ]] && grep -qx "volume rm $wc31" "$TMP/docker-calls.txt" \
  && pass "LNCH-31 an empty record is no launch's: its volume is removed and seeded again" \
  || fail "LNCH-31 an empty record (rc=$RC; $(grep -E '^volume' "$TMP/docker-calls.txt" | tr '\n' ';'))"
# A record is a daemon's: a dead launcher's record kept for another daemon
# removes nothing on this one, whose working copy is taken as seeded.
mkdir -p "$HOME/.ai-containers/.seeding/daemonA"; printf '999999999 1\n' > "$HOME/.ai-containers/.seeding/daemonA/$wc31"
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_DAEMON_ID=daemonB FAKE_WC_MISSING=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 && -e "$HOME/.ai-containers/.seeding/daemonA/$wc31" ]] && ! grep -qE '^volume (rm|create)' "$TMP/docker-calls.txt" \
  && grep -q "^$wc31:/workspace/good13\$" "$CAPTURE" \
  && pass "LNCH-31 a record of another daemon removes nothing on this one" \
  || fail "LNCH-31 another daemon's record (rc=$RC; $(grep -E '^volume' "$TMP/docker-calls.txt" | tr '\n' ';'))"
rm -rf "$HOME/.ai-containers/.seeding/daemonA"
# Another launch that begins seeding as this one looks at the volume: the
# record is read after the volume, so its half copy is not taken for a seeded
# one (review of the LNCH-31 fix: read before, it was mounted).
docker_rm_made() { rm -f "$TMP/made-$wc31" "$TMP/looked-$wc31"; }
: > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_SEEDING_NOW="$rec31" FAKE_WC_SEEDING_ID="$me31" FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 && ! -s "$CAPTURE" ]] && grep -qF "is being seeded by another launch (pid $$)" "$ERR" && ! grep -qE '^volume (rm|create)' "$TMP/docker-calls.txt" \
  && pass "LNCH-31 a seeding that begins as the launch looks is seen: its half copy is not mounted" \
  || fail "LNCH-31 a seeding that begins as the launch looks (rc=$RC; $(head -2 "$ERR" | tr '\n' ' '))"
rm -f "$rec31"
# A working copy that another launch seeds between this one's look and its
# record is that launch's: this one copies nothing and mounts it.
docker_rm_made; : > "$CAPTURE"; : > "$TMP/docker-calls.txt"
FAKE_WC_APPEARS=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 && ! -e "$rec31" ]] && ! grep -qE '^volume create|--entrypoint bash' "$TMP/docker-calls.txt" \
  && grep -q "^$wc31:/workspace/good13\$" "$CAPTURE" \
  && pass "LNCH-31 a working copy seeded by another launch in between is mounted, not copied into" \
  || fail "LNCH-31 a copy that appears in between (rc=$RC; $(grep -E '^(volume|run)' "$TMP/docker-calls.txt" | tr '\n' ';' | cut -c1-300))"
# A copy that goes on after the launcher is told to stop: the EXIT trap removes
# its container first, then stops it, and the launch ends at once.
docker_rm_made; : > "$CAPTURE"; : > "$TMP/docker-calls.txt"; t31=$SECONDS
FAKE_WC_MISSING=1 FAKE_SEED_HANG=1 FAKE_LABELS="ai-containers-repo-good13=good13" run_sandbox "$TMP/app"
[[ "$RC" -ne 0 && $(( SECONDS - t31 )) -lt 15 && ! -e "$rec31" ]] && grep -q "^rm -f $wc31-seed-" "$TMP/docker-calls.txt" \
  && grep -qx "volume rm $wc31" "$TMP/docker-calls.txt" \
  && pass "LNCH-31 a copy that goes on after the launcher stops is ended, and its working copy removed" \
  || fail "LNCH-31 a copy that goes on (rc=$RC; $(( SECONDS - t31 )) s; $(grep -E '^(volume|rm)' "$TMP/docker-calls.txt" | tr '\n' ';'))"
unset -f seeded docker_rm_made
# A repo whose name is a mode keeps the mode written (bugs review LNCH-34): "no
# mode given" was told by the mode equalling the name, so `rw:rw` mounted :ro and
# `@rw` was refused as a read-only working directory.
register_git_repo rw "git@example.invalid:rw.git" "$TMP/rwck"
register_git_repo ro "git@example.invalid:ro.git" "$TMP/rock"
: > "$CAPTURE"; REPOS="rw:rw" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -qx 'ai-containers-repo-rw:/workspace/rw' "$CAPTURE" && grep -qF 'REPO: /workspace/rw  (rw,' "$ERR" \
  && pass "LNCH-34 a repo named rw attached :rw is mounted writable" \
  || fail "LNCH-34 rw:rw (rc=$RC; $(grep -F '/workspace/rw' "$CAPTURE"); $(grep -F 'REPO:' "$ERR"))"
: > "$CAPTURE"; REPOS="ro" run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -qx 'ai-containers-repo-ro:/workspace/ro:ro' "$CAPTURE" \
  && pass "LNCH-34 a repo named ro with no mode given is mounted read-only, the default" \
  || fail "LNCH-34 ro with no mode (rc=$RC; $(grep -F '/workspace/ro' "$CAPTURE"))"
: > "$CAPTURE"; REPOS="" run_sandbox @rw
[[ "$RC" -eq 0 ]] && grep -qx 'ai-containers-repo-rw:/workspace/rw' "$CAPTURE" && grep -qx '/workspace/rw' "$CAPTURE" \
  && pass "LNCH-34 @rw is the writable working directory" \
  || fail "LNCH-34 @rw (rc=$RC; $(grep -F 'ERROR' "$ERR" | head -1))"
# So does the REPO-13 check before anything is attached: a repo named rwcopy
# given with no mode is :ro, and no working copy of it is looked at, so one
# labelled for another repo under that name refuses nothing.
register_git_repo rwcopy "git@example.invalid:rwcopy.git" "$TMP/rwcck"
: > "$CAPTURE"; REPOS="rwcopy" FAKE_LABELS="ai-containers-repo-rwcopy=rwcopy" FAKE_REPO_LABEL=other run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -qx 'ai-containers-repo-rwcopy:/workspace/rwcopy:ro' "$CAPTURE" \
  && pass "LNCH-34 a repo named rwcopy with no mode is attached :ro, no working copy of it judged" \
  || fail "LNCH-34 rwcopy with no mode (rc=$RC; $(grep -F ERROR "$ERR" | head -1))"
# The pointer's desugar (pointer_repo_entry) reads an entry's mode the same way.
: > "$CAPTURE"; REPOS="rw:rw" DOCS_PATH=@rw run_sandbox "$TMP/app"
[[ "$RC" -eq 0 ]] && grep -qF "NOTE: repo 'rw' is already mounted (rw); the pointer's :ro is ignored." "$ERR" \
  && grep -qx 'ai-containers-repo-rw:/workspace/rw' "$CAPTURE" \
  && pass "LNCH-34 a pointer to a repo named rw already attached :rw sees it as rw" \
  || fail "LNCH-34 DOCS_PATH=@rw beside rw:rw (rc=$RC; $(grep -F "repo 'rw'" "$ERR" | head -1))"
teardown

# ── An @<repo> primary, and the refusals of a mount, by their status ────────
# A refusal stops the launch with a status that is not 0: `runme.sh` and any
# script that launches the sandbox read it. Most of these were checked by their
# message alone, or not at all, so `exit 0` in place of `exit 1` went unnoticed
# (GAP-2 slice 8). The refusal named is the last one printed: a later one stopping
# the launch instead would mean this one let it past.
refused() {  # <check> <what stderr says>
  if [[ "$RC" -ne 0 && ! -s "$CAPTURE" && "$(grep -E '^(ERROR|Invalid)' "$ERR" | tail -n 1)" == *"$2"* ]]; then pass "$1"
  else fail "$1 (rc=$RC; $(grep -E '^(ERROR|Invalid)' "$ERR" | tail -n 1))"; fi
}
workdir_is() { [[ "$(awk 'p { print; exit } $0 == "-w" { p = 1 }' "$CAPTURE")" == "$1" ]]; }
# A registered repo named with @ is the working directory, attached writable.
setup
mkdir -p "$TMP/src/app" "$TMP/src/lib"; register_repo app "$TMP/src/app"; register_repo lib "$TMP/src/lib"
run_sandbox @app
if [[ "$RC" -eq 0 ]] && workdir_is /workspace/app && grep -qx "$TMP/src/app:/workspace/app:rw" "$CAPTURE"; then
  pass "@app: a registered repo is the working directory, attached :rw"
else
  fail "@app (rc=$RC; -w $(awk 'p { print; exit } $0 == "-w" { p = 1 }' "$CAPTURE"); $(grep -m1 -E 'ERROR|Invalid' "$ERR"))"
fi
# …beside the REPOS it does not name, which keep their own mode…
: > "$CAPTURE"; export REPOS="lib:ro"
run_sandbox @app
if [[ "$RC" -eq 0 ]] && grep -qx "$TMP/src/app:/workspace/app:rw" "$CAPTURE" && grep -qx "$TMP/src/lib:/workspace/lib:ro" "$CAPTURE"; then
  pass "@app with REPOS=lib:ro: app is attached :rw beside lib :ro"
else
  fail "@app beside REPOS=lib:ro (rc=$RC; $(grep -E '/workspace/(app|lib)' "$CAPTURE" | tr '\n' ' '))"
fi
# …and one REPOS lists :ro is refused, never attached twice.
: > "$CAPTURE"; export REPOS="app:ro"
run_sandbox @app
refused "@app listed in REPOS as :ro refuses the launch" "primary repo 'app' is attached :ro, but the working directory must be writable"
unset REPOS
: > "$CAPTURE"; run_sandbox @Bad_Name
refused "@ with an invalid repo name refuses the launch" "Invalid repo name 'Bad_Name'"
: > "$CAPTURE"; run_sandbox @nope
refused "@ naming an unregistered repo refuses the launch" "primary repo 'nope' (selected with @) is not registered"
teardown
# A primary path, EXTRA_MOUNTS and REPOS entries that cannot be mounted.
setup
mkdir -p "$TMP/app" "$TMP/x/app" "$TMP/src/app" "$TMP/src/lib" "$TMP/x/lib" "$TMP/x/vault" "$TMP/x/specs" "$TMP/myvault" "$TMP/myspecs"
register_repo app "$TMP/src/app"; register_repo lib "$TMP/src/lib"; register_repo gone "$TMP/src/gone"
register_git_repo vol "git@example.invalid:vol.git" "$TMP/co/vol"
run_sandbox "$TMP/nope"
refused "a primary directory that does not exist refuses the launch" "primary workspace directory does not exist: $TMP/nope"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/nope" run_sandbox "$TMP/app"
refused "an EXTRA_MOUNTS path that does not exist refuses the launch" "EXTRA_MOUNTS path does not exist: $TMP/nope"
mkdir -p "$TMP/y/lib"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/x/lib $TMP/y/lib" run_sandbox "$TMP/app"
refused "two EXTRA_MOUNTS entries of one name refuse the launch" "name 'lib' (EXTRA_MOUNTS) collides with EXTRA_MOUNTS at /workspace/lib"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/x/app" run_sandbox "$TMP/app"
refused "a primary whose name an EXTRA_MOUNTS entry takes refuses the launch" "primary path basename 'app' collides with EXTRA_MOUNTS"
: > "$CAPTURE"; REPOS="Bad_Name" run_sandbox "$TMP/app"
refused "a REPOS entry with an invalid name refuses the launch" "Invalid repo name 'Bad_Name'"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/x/lib" REPOS="lib:ro" run_sandbox "$TMP/app"
refused "a REPOS entry whose name EXTRA_MOUNTS takes refuses the launch" "name 'lib' is used by both EXTRA_MOUNTS and REPOS"
: > "$CAPTURE"; REPOS="nope:ro" run_sandbox "$TMP/app"
refused "an unregistered REPOS entry refuses the launch" "REPOS entry 'nope' is not a registered repo"
: > "$CAPTURE"; REPOS="app:rwcopy" run_sandbox "$TMP/x/lib"
refused "a bind-backed repo asked for :rwcopy refuses the launch" "repo 'app': :rwcopy needs a volume backend"
: > "$CAPTURE"; REPOS="gone:ro" run_sandbox "$TMP/app"
refused "a bind-backed repo whose source is gone refuses the launch" "repo 'gone' bind source does not exist on this host"
: > "$CAPTURE"; REPOS="vol:ro" FAKE_VOL_MISSING=1 run_sandbox "$TMP/app"
refused "a volume-backed repo whose volume is gone refuses the launch" "repo 'vol' is registered but its docker volume (ai-containers-repo-vol) is missing"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/x/vault" VAULT_PATH="$TMP/myvault" run_sandbox "$TMP/app"
refused "VAULT_PATH beside another mount named vault refuses the launch" "name 'vault' is used by EXTRA_MOUNTS, but VAULT_PATH also mounts"
: > "$CAPTURE"; EXTRA_MOUNTS="$TMP/x/specs" SPECS_PATH="$TMP/myspecs" run_sandbox "$TMP/app"
refused "SPECS_PATH beside another mount named specs refuses the launch" "name 'specs' is used by EXTRA_MOUNTS, but SPECS_PATH also mounts"
# SPECS_PATH naming the primary is the working directory, not a second mount,
# as DOCS_PATH and ARCHITECTURE_REPO_PATH are.
: > "$CAPTURE"; SPECS_PATH="$TMP/myspecs" run_sandbox "$TMP/myspecs"
if [[ "$RC" -eq 0 ]] && grep -qx "SPECS_PATH=/workspace/myspecs" "$CAPTURE" && ! grep -q ':/workspace/specs:' "$CAPTURE"; then
  pass "SPECS_PATH naming the primary re-points to the working directory, with no second mount"
else
  fail "SPECS_PATH = the primary (rc=$RC; $(grep -E 'SPECS_PATH=|/workspace/specs' "$CAPTURE" | tr '\n' ' '))"
fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
