#!/usr/bin/env bash
# tests/test-provenance.sh — does an image know which files made it?
#
# THE EVENT THIS EXISTS FOR. On 2026-08-19 an image was rebuilt and still
# carried /etc/skel/.npmrc, a file deleted from the Dockerfile on 2026-08-06.
# The build was faithful; the project's .ai-containers/ had simply not been
# synced since before that date. Nothing could say so — not `docker images`,
# not the launcher, not the container — so the conclusion drawn was "I must
# have missed an image", and a fixed bug stayed live for three days in a
# container that looked freshly built.
#
# The stamp is a LABEL, not a file in the image: a label costs no layer, so
# recording provenance cannot itself invalidate one.
#
# Hermetic: every case runs against a fixture directory in $TMP. Nothing here
# builds an image, starts a container, or reads the developer's own assets.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# p_timeout: a portable bound. `timeout` is GNU-only and absent on macOS, where
# it returns 127 — a non-zero status that silently satisfies a naive check.
# shellcheck source=./portability.sh
. "$TESTS_DIR/portability.sh"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox-common.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# GUARDED, because this file now FORKS: prov_absolute_exec_terminates runs
# build.sh as a background job to bound and reap it. A backgrounded FUNCTION
# inherits the parent's EXIT trap and runs it when signalled, so an unguarded
# `rm -rf "$TMP"` would let the child delete the fixture the parent is still
# using. tests/test-exit-trap-ownership.sh caught this the moment the fork was
# added — the rule working, not a false positive.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n'"  expected: $2"$'\n'"  got:      $3"; fi; }

# The helpers are sourced, not re-implemented: a copy here could agree with
# itself while disagreeing with the launcher, which is the failure this whole
# file is about.
# A HOME of its own: the project label's key is made there (ENV-8).
export HOME="$TMP/home"; mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$ENGINE_DIR/sandbox-common.sh" >/dev/null 2>&1

# A project's .ai-containers/ in miniature: engine scripts, the build recipe,
# allowlist fragments, tools.d — plus the four kinds of file that must NOT
# count towards the digest.
mk_assets() {   # <dir>
  local d="$1"
  mkdir -p "$d/allowlist-domains.d" "$d/tools.d"
  printf 'FROM ubuntu\n'      > "$d/Dockerfile"
  printf 'FROM ubuntu\n'      > "$d/Dockerfile.seed"
  printf '.git\n'             > "$d/.dockerignore"
  printf 'engine\n'           > "$d/sandbox.sh"
  printf 'engine\n'           > "$d/build.sh"
  printf 'example.com\n'      > "$d/allowlist-domains.txt"
  printf 'base.example\n'     > "$d/allowlist-domains.d/base.txt"
  printf 'local.example\n'    > "$d/allowlist-domains.d/custom.txt"
  printf 'name=dtctl\n'       > "$d/tools.d/dtctl.conf"
  # excluded, each for its own reason
  printf 'generated\n'        > "$d/runme.sh"
  printf 'generated\n'        > "$d/runme.sh.pre-migrate"
  printf 'mode=restricted\n'  > "$d/sandbox.conf"
  printf 'FOO=1\n'            > "$d/sandbox.env"
}
A="$TMP/assets"; mk_assets "$A"
files="$(ai_containers_payload_files "$A")"

# ── what counts, and what deliberately does not ──────────────────────────────
for f in Dockerfile Dockerfile.seed .dockerignore sandbox.sh build.sh \
         allowlist-domains.txt allowlist-domains.d/base.txt \
         allowlist-domains.d/custom.txt tools.d/dtctl.conf; do
  grep -qxF "$f" <<<"$files" && pass "the digest set includes $f" \
                             || fail "the digest set includes $f"
done
# custom.txt is NOT synced from the central repo, and is included anyway: it is
# composed into the image at build time, so an image built before it changed is
# genuinely out of date.
for f in runme.sh runme.sh.pre-migrate sandbox.conf sandbox.env; do
  grep -qxF "$f" <<<"$files" && fail "the digest set excludes $f" \
                             || pass "the digest set excludes $f"
done
check "the file list is sorted, so the digest cannot depend on readdir order" \
  "$(LC_ALL=C sort -u <<<"$files")" "$files"

# ── the digest itself ────────────────────────────────────────────────────────
d1="$(ai_containers_payload_digest "$A")"
check "the same directory digests the same twice" "$d1" "$(ai_containers_payload_digest "$A")"

printf 'engine CHANGED\n' > "$A/sandbox.sh"
d2="$(ai_containers_payload_digest "$A")"
[[ "$d2" != "$d1" ]] && pass "changing an included file changes the digest" \
                     || fail "changing an included file changes the digest"

printf 'mode=open\n' > "$A/sandbox.conf"
check "changing an excluded file does NOT change the digest" "$d2" "$(ai_containers_payload_digest "$A")"

# Names are hashed alongside content, so a deletion cannot be absorbed by
# another file's bytes — the failure a content-only digest would miss.
rm -f "$A/allowlist-domains.d/custom.txt"
d3="$(ai_containers_payload_digest "$A")"
[[ "$d3" != "$d2" ]] && pass "deleting an included file changes the digest" \
                     || fail "deleting an included file changes the digest"

ai_containers_payload_digest "$TMP/no-such-dir" >/dev/null 2>&1 \
  && fail "a missing directory cannot be digested" \
  || pass "a missing directory cannot be digested"

# ── the labels ───────────────────────────────────────────────────────────────
labels="$(ai_containers_provenance_labels "$A" 2026-01-01T00:00:00Z)"
grep -qxF "ai-containers.payload-digest=$d3" <<<"$labels" \
  && pass "the labels carry the payload digest" || fail "the labels carry the payload digest"
grep -qxF "ai-containers.built-at=2026-01-01T00:00:00Z" <<<"$labels" \
  && pass "the labels carry the build time" || fail "the labels carry the build time"
# A project's asset dir is a COPY with no history. Recording no commit there is
# the honest answer, and inventing one would be worse than silence.
grep -q "source-commit" <<<"$labels" \
  && fail "no source-commit outside a git checkout" || pass "no source-commit outside a git checkout"
grep -qxF "ai-containers.project=$(ai_containers_project_id "$(cd "$A" && pwd -P)")" <<<"$labels" \
  && pass "the labels carry the project the image is for, by its id (ENV-7, ENV-8)" || fail "the labels carry the project"
check "every label is preceded by its --label flag" "3" "$(grep -cx -- '--label' <<<"$labels")"

# And the other half of that branch: when the assets ARE a checkout, the commit
# is recorded. Untested, this is the case that silently stops working — the
# central repo is the only place it ever fires.
# An ENGINE tree: project-init.sh is base-repo only, the mark version_engine
# goes by too (GIT-26).
G="$TMP/gitassets"; mk_assets "$G"; : > "$G/project-init.sh"
( cd "$G" && git init -q . && git add -A >/dev/null 2>&1 \
    && git -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1 ) || true
if [[ -d "$G/.git" ]]; then
  glabels="$(ai_containers_provenance_labels "$G" 2026-01-01T00:00:00Z)"
  gcommit="$(git -C "$G" rev-parse HEAD 2>/dev/null)"
  grep -qxF "ai-containers.source-commit=$gcommit" <<<"$glabels" \
    && pass "a git checkout records the commit it was built from" \
    || fail "a git checkout records the commit it was built from"
  check "a git checkout carries all four labels" "4" "$(grep -cx -- '--label' <<<"$glabels")"
else
  printf 'SKIP: git could not create a fixture repo\n'
fi

# ── GIT-26: the commit is read as files, and git never runs ─────────────────
# build.sh ran `git -C <dir> rev-parse HEAD`, which reads the repository's
# config, includes and all, with no bound: a FIFO an include names hung every
# build, naming nothing. On a Mac without the Command Line Tools it ran the shim
# that opens their installer. And git walked up from a project's .ai-containers/
# to the PROJECT's repository, so every project image recorded the project's
# commit as the engine's, which docs/multiple-projects.md says is absent there.
gq() { git -c user.email=t@t -c user.name=t "$@"; }
mk_engine() {   # <dir>: an engine tree that is its own checkout, one commit
  mk_assets "$1"; : > "$1/project-init.sh"
  ( cd "$1" && git init -q . && git add -A && gq commit -qm seed ) >/dev/null 2>&1
}
commit_label() {   # <dir> → the source-commit its labels record, or nothing
  ai_containers_provenance_labels "$1" 2026-01-01T00:00:00Z 2>/dev/null \
    | sed -n 's/^ai-containers\.source-commit=//p'
}
# commit_label in a process group of its own, KILLed whole at <seconds>: killing
# the function's shell alone left the git it ran blocked on a FIFO for good.
commit_label_bounded() {   # <seconds> <dir> <out-file> → 0, or 124 when cut off
  local secs="$1" pid waited=0
  set -m
  commit_label "$2" > "$3" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null && (( waited < secs * 10 )); do sleep 0.1; waited=$(( waited + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}
E26="$TMP/e26"; mk_engine "$E26"
if [[ -d "$E26/.git" ]]; then
  want26="$(git -C "$E26" rev-parse HEAD)"
  # Git is not run at all: a git on PATH that only records its calls.
  mkdir -p "$TMP/fakegit26"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$TMP/git26.log" > "$TMP/fakegit26/git"
  chmod +x "$TMP/fakegit26/git"; : > "$TMP/git26.log"
  got26="$(PATH="$TMP/fakegit26:$PATH" commit_label "$E26")"
  if [[ "$got26" == "$want26" && ! -s "$TMP/git26.log" ]]; then
    pass "GIT-26 the commit is read from the checkout's files, and git is not run"
  else
    fail "GIT-26 git ran, or the commit was not read (got '$got26', git calls: $(head -2 "$TMP/git26.log" | tr '\n' ';'))"
  fi
  # An include naming a FIFO: the config is not read at all.
  E26i="$TMP/e26i"; mk_engine "$E26i"
  git -C "$E26i" config include.path "$TMP/inc26" >/dev/null 2>&1; mkfifo "$TMP/inc26"
  commit_label_bounded 20 "$E26i" "$TMP/out26i"; rc26=$?
  ( exec 3<>"$TMP/inc26" ) 2>/dev/null; rm -f "$TMP/inc26"
  if [[ "$rc26" == 0 && "$(cat "$TMP/out26i")" == "$(git -C "$E26i" rev-parse HEAD)" ]]; then
    pass "GIT-26 an include that names a FIFO does not hold the build"
  else
    fail "GIT-26 an include that names a FIFO held the build (rc=$rc26, got '$(cat "$TMP/out26i")')"
  fi
  # A HEAD that is a FIFO: no commit, and no wait.
  E26h="$TMP/e26h"; mk_engine "$E26h"; rm -f "$E26h/.git/HEAD"; mkfifo "$E26h/.git/HEAD"
  commit_label_bounded 20 "$E26h" "$TMP/out26h"; rc26=$?
  ( exec 3<>"$E26h/.git/HEAD" ) 2>/dev/null
  if [[ "$rc26" == 0 && ! -s "$TMP/out26h" ]]; then
    pass "GIT-26 a HEAD that is a FIFO records no commit, and does not hold the build"
  else
    fail "GIT-26 a HEAD that is a FIFO (rc=$rc26, got '$(cat "$TMP/out26h")')"
  fi
  # Packed refs: the branch's loose file gone, its tip in packed-refs.
  E26p="$TMP/e26p"; mk_engine "$E26p"; git -C "$E26p" pack-refs --all >/dev/null 2>&1
  b26="$(git -C "$E26p" symbolic-ref HEAD 2>/dev/null)"
  if [[ -n "$b26" && ! -e "$E26p/.git/$b26" ]]; then
    check "GIT-26 a branch in packed-refs is read" "$(git -C "$E26p" rev-parse HEAD)" "$(commit_label "$E26p")"
  else
    fail "GIT-26 scaffold: pack-refs left the loose ref (${b26:-no branch})"
  fi
  # packed-refs is read a line at a time, each cut at 4200 bytes, and within the
  # bound: awk held a line whole, and one that was the whole file took gigabytes
  # within it (review of the fix, L1). A long line is passed over...
  E26b="$TMP/e26b"; mk_engine "$E26b"; git -C "$E26b" pack-refs --all >/dev/null 2>&1
  b26="$(git -C "$E26b" symbolic-ref HEAD)"; o26="$(git -C "$E26b" rev-parse HEAD)"
  { printf '# pack-refs with: peeled fully-peeled sorted\n'; printf '%05000d\n' 0; printf '%s %s\n' "$o26" "$b26"; } > "$E26b/.git/packed-refs"
  check "GIT-26 a branch after a line longer than 4200 bytes in packed-refs is read" "$o26" "$(commit_label "$E26b")"
  # ...and one that never ends (a link to /dev/zero swapped in after the -f
  # test) is given up at the bound, its reader killed, never held whole.
  ln -s /dev/zero "$TMP/zero26"; t26=$SECONDS
  ( _ac_read_secs=1; _ac_packed_ref v26 "$TMP/zero26" refs/heads/main ); rc26=$?
  sleep 0.3; left26="$(pgrep -f -- "cat -- $TMP/zero26" 2>/dev/null | head -1)"
  if [[ "$rc26" == 2 && -z "$left26" ]] && (( SECONDS - t26 < 10 )); then
    pass "GIT-26 a packed-refs that never ends is given up at the bound, its reader gone"
  else
    fail "GIT-26 a packed-refs that never ends (rc=$rc26, $((SECONDS - t26)) s, reader ${left26:-gone})"
    if [[ -n "$left26" ]]; then kill -KILL "$left26" 2>/dev/null; fi
  fi
  # A detached HEAD holds the commit itself.
  E26d="$TMP/e26d"; mk_engine "$E26d"; gq -C "$E26d" commit -q --allow-empty -m two >/dev/null 2>&1
  git -C "$E26d" checkout -q --detach HEAD~1 >/dev/null 2>&1
  check "GIT-26 a detached HEAD is read" "$(git -C "$E26d" rev-parse HEAD)" "$(commit_label "$E26d")"
  # A linked worktree: its .git file and commondir followed, its own HEAD read.
  if git -C "$E26p" worktree add -q "$TMP/wt26" -b wt26 >/dev/null 2>&1; then
    gq -C "$TMP/wt26" commit -q --allow-empty -m wt >/dev/null 2>&1
    w26="$(git -C "$TMP/wt26" rev-parse HEAD)"
    if [[ "$w26" != "$(git -C "$E26p" rev-parse HEAD)" ]]; then
      check "GIT-26 a linked worktree records its own commit" "$w26" "$(commit_label "$TMP/wt26")"
    else
      fail "GIT-26 scaffold: the worktree's commit is its main checkout's"
    fi
    # A .git file is trimmed of CR and LF only, as git reads it: `gitdir: <path> `
    # names `<path> `, which does not exist, so git has no commit there either.
    t26="$(cat "$TMP/wt26/.git")"; printf '%s \n' "$t26" > "$TMP/wt26/.git"
    if ! git -C "$TMP/wt26" rev-parse HEAD >/dev/null 2>&1; then
      check "GIT-26 a .git file is read as git reads it, trailing space and all" "" "$(commit_label "$TMP/wt26")"
    else
      fail "GIT-26 scaffold: git still reads the worktree with a space after its gitdir"
    fi
    printf '%s\n' "$t26" > "$TMP/wt26/.git"
  else
    fail "GIT-26 scaffold: git worktree add failed"
  fi
  # An engine tree inside a larger repository (a port's base/): the enclosing
  # repository's commit, as version_engine reads its version from there.
  M26="$TMP/m26"; mkdir -p "$M26"; mk_assets "$M26/base"; : > "$M26/base/project-init.sh"
  ( cd "$M26" && git init -q . && git add -A && gq commit -qm m ) >/dev/null 2>&1
  check "GIT-26 an engine tree inside a repository records that repository's commit" \
    "$(git -C "$M26" rev-parse HEAD 2>/dev/null)" "$(commit_label "$M26/base")"
  # A project's copy, inside the project's repository: no commit at all.
  P26="$TMP/p26"; mkdir -p "$P26"; mk_assets "$P26/.ai-containers"
  ( cd "$P26" && git init -q . && git add -A && gq commit -qm p ) >/dev/null 2>&1
  check "GIT-26 a project's .ai-containers/ records no commit, not the project's" "" "$(commit_label "$P26/.ai-containers")"
  # A read cut off says so; the image is still built, with no commit.
  out26n="$( ( _ac_read_bounded() { return 2; }
               ai_containers_provenance_labels "$E26" 2026-01-01T00:00:00Z ) 2>&1 >/dev/null )"
  grep -q 'NOTE: .*records no source commit' <<<"$out26n" \
    && pass "GIT-26 a read cut off is named" || fail "GIT-26 a read cut off is not named ('$out26n')"
  # The bound itself: the reader is killed, not left blocked on the FIFO.
  # The reader writes its pid, then becomes cat, blocked opening the FIFO.
  mkfifo "$TMP/f26"; t26=$SECONDS; : > "$TMP/pid26"
  # shellcheck disable=SC2016  # $$ is the reader's, expanded by its own sh
  ( _ac_read_secs=1; _ac_read_bounded v26 sh -c 'echo $$ > "$1"; exec cat -- "$2"' sh "$TMP/pid26" "$TMP/f26" ); rc26=$?
  sleep 0.2; p26="$(cat "$TMP/pid26")"
  if [[ "$rc26" == 2 && -n "$p26" ]] && (( SECONDS - t26 < 10 )) && ! kill -0 "$p26" 2>/dev/null; then
    pass "GIT-26 a read past its bound fails, and its reader is gone"
  else
    fail "GIT-26 the bounded read (rc=$rc26, $((SECONDS - t26)) s, reader ${p26:-?} $(kill -0 "${p26:-0}" 2>/dev/null && printf 'left running' || printf 'gone'))"
  fi
  ( exec 3<>"$TMP/f26" ) 2>/dev/null; rm -f "$TMP/f26"
else
  fail "GIT-26 scaffold: git could not create a fixture repo"
fi

# ── the warning ──────────────────────────────────────────────────────────────
# `docker` is shadowed so no daemon is touched: the function's whole contract is
# what it does with the label it reads back.
warn_out() {   # <label the fake image reports> → stderr of the warning
  ( FAKE_LABEL="$1"
    # Only ever called as `docker image inspect --format … <image>`.
    docker() { [[ "$1" == "image" ]] && printf '%s\n' "$FAKE_LABEL"; }
    # stdout discarded FIRST, then stderr into the capture: the warning is the
    # only thing under test. Written with the braces because the bare
    # `2>&1 1>/dev/null` ordering is right but reads like the classic mistake.
    { ai_containers_provenance_warn img "$A" 1>/dev/null; } 2>&1 )
}
out="$(warn_out "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")"
grep -q "was NOT built from the files" <<<"$out" \
  && pass "a mismatched image warns" || fail "a mismatched image warns"
grep -q "${d3:0:12}" <<<"$out" \
  && pass "the warning names the digest the assets actually have" \
  || fail "the warning names the digest the assets actually have"
check "a matching image says nothing" "" "$(warn_out "$d3")"
# An image built before this existed has no label. Silence is right: that is not
# evidence of drift, and a warning nobody can act on is the kind that gets
# ignored along with the real ones.
check "an image with no provenance label says nothing" "" "$(warn_out "")"
check "an unset label reads as absent, not as a mismatch" "" "$(warn_out "<no value>")"
# NEVER a refusal: being wrong about provenance must not stop somebody working.
( docker() { [[ "$1" == "image" ]] && printf 'nope\n'; }
  ai_containers_provenance_warn img "$A" >/dev/null 2>&1 )
check "the warning never fails the launch" "0" "$?"

# ── the config digest: build-time keys only ──────────────────────────────────
# sandbox.conf is not in the payload digest, and must not be: it mixes
# build-time keys with runtime ones, and a warning that fires when `mkdocs=`
# changes — which rebuilds nothing — is a warning people learn to dismiss,
# taking the true ones with it. So what is digested is what build.sh DERIVES
# from the config: the --build-arg list, which contains every build-time key by
# construction and no runtime key at all.
#
# Against the REAL engine, because the fixture's build.sh is a stub with no
# build_args_from_config to call. Both directions, since only the pair is
# evidence: one of them alone would pass against a digest that ignored the file
# entirely, and the other against one that digested the whole thing.
if [[ -f "$ENGINE_DIR/sandbox.conf" && -f "$ENGINE_DIR/build.sh" ]]; then
  cfg_of() { ( export SANDBOX_CONF="$1"; ai_containers_config_digest "$ENGINE_DIR" ); }
  base_cfg="$(cfg_of "$ENGINE_DIR/sandbox.conf")"
  if [[ ! "$base_cfg" =~ ^[0-9a-f]{64}$ ]]; then
    fail "the config digest is computable from the real engine (got '${base_cfg:0:20}')"
  else
    pass "the config digest is computable from the real engine"
    # A BUILD-time key. `ruby=` decides whether the runtime toolchain and the
    # rvm layer are in the image, so an image built before it changed is stale.
    sed 's/^ruby=.*/ruby=3.3/' "$ENGINE_DIR/sandbox.conf" > "$TMP/ruby.conf"
    grep -q '^ruby=' "$TMP/ruby.conf" || printf 'ruby=3.3\n' >> "$TMP/ruby.conf"
    if [[ "$(cfg_of "$TMP/ruby.conf")" != "$base_cfg" ]]; then
      pass "a build-time key (ruby=) moves the config digest"
    else
      fail "a build-time key (ruby=) moves the config digest"
    fi
    # A RUNTIME key. `mkdocs=` is installed at container start into the
    # group's ~/.ai-tools and rebuilds nothing, so it must leave the digest
    # alone. The edit is checked to have changed the file: this once toggled a
    # `mode=` key sandbox.conf does not have, and compared the file with an
    # identical copy (batch 8 review).
    if grep -q '^mkdocs=ON' "$ENGINE_DIR/sandbox.conf"; then mk=OFF; else mk=ON; fi
    sed "s/^mkdocs=.*/mkdocs=$mk/" "$ENGINE_DIR/sandbox.conf" > "$TMP/mkdocs.conf"
    if cmp -s "$ENGINE_DIR/sandbox.conf" "$TMP/mkdocs.conf"; then
      fail "the runtime-key fixture changes sandbox.conf (no mkdocs= line to toggle)"
    else
      check "a runtime-only key (mkdocs=) leaves the config digest alone" \
        "$base_cfg" "$(cfg_of "$TMP/mkdocs.conf")"
    fi
  fi
  reallabels="$(ai_containers_provenance_labels "$ENGINE_DIR" 2026-01-01T00:00:00Z)"
  grep -q "ai-containers.config-digest=" <<<"$reallabels" \
    && pass "the labels carry the config digest" || fail "the labels carry the config digest"
fi

# A config that has drifted while the FILES have not is its own message: "you
# synced and did not rebuild" and "you changed a build-time key and did not
# rebuild" send a reader to different places, though both end in ./build.sh.
warn_two() {   # <payload label> <config label> → stderr of the warning
  ( FAKE="$1 $2"
    docker() { [[ "$1" == "image" ]] && printf '%s\n' "$FAKE"; }
    { ai_containers_provenance_warn img "$A" 1>/dev/null; } 2>&1 )
}
out2="$(warn_two "$(ai_containers_payload_digest "$A")" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")"
if [[ -z "$out2" ]]; then
  # $A's stub build.sh yields no args, so the config digest is uncomputable
  # there and the check is correctly skipped rather than guessed at.
  pass "an asset dir with no usable build.sh skips the config check rather than guessing"
else
  grep -q 'sandbox.conf' <<<"$out2" \
    && pass "a drifted config names sandbox.conf, not just the files" \
    || fail "a drifted config names sandbox.conf, not just the files"
fi

# ── the wiring, by name ──────────────────────────────────────────────────────
# The helpers above can be perfect and never called. These two assertions are
# what tie them to the launcher and the builder.
grep -q 'ai_containers_provenance_warn "\$image_name" "\$script_dir"' "$ENGINE_DIR/sandbox.sh" \
  && pass "sandbox.sh calls the provenance warning" || fail "sandbox.sh calls the provenance warning"
grep -q 'ai_containers_provenance_labels "\$script_dir"' "$ENGINE_DIR/build.sh" \
  && pass "build.sh stamps the image with the provenance labels" \
  || fail "build.sh stamps the image with the provenance labels"
# Before the container starts, not after: a warning printed once the agent shell
# has taken the terminal is a warning nobody sees.
warn_line="$(grep -n 'ai_containers_provenance_warn' "$ENGINE_DIR/sandbox.sh" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'docker run -it --rm' "$ENGINE_DIR/sandbox.sh" | head -1 | cut -d: -f1)"
if [[ -n "$warn_line" && -n "$run_line" ]] && (( warn_line < run_line )); then
  pass "the warning is printed before the container starts"
else
  fail "the warning is printed before the container starts (warn=$warn_line run=$run_line)"
fi

# ── build.sh must know it is being SOURCED, however it was invoked ───────────
# ai_containers_config_digest sources "$dir/build.sh" to read the build args out
# of it. build.sh must return early there — if it does not, the whole build body
# runs INSIDE this function and computes the digest again: unbounded recursion.
#
# THE GUARD USED TO BE `[[ "${BASH_SOURCE[0]}" != "${0}" ]]`, a STRING compare,
# which is right only because people usually type `./build.sh`. Execute it by the
# same absolute path this function sources and $0 is byte-identical to
# BASH_SOURCE[0]: the guard concludes "not sourced" and the recursion begins.
# Measured 2026-09-01 through the only caller that invoked by absolute path (a
# gated smoke test, deleted in the same change as superseded): 1077 build.sh
# processes over two hours, never reaching `docker build`. That caller is gone;
# this assertion is what keeps the defect from coming back, and unlike the smoke
# test it needs no docker, no network and under a second.
#
# ASSERTED BY EFFECT, AND BOUNDED. The subject is a script that spawns without
# limit when broken, so the assertion runs it under a hard clock in its own
# process group and reaps that group afterwards: a test for a fork bomb must not
# be able to leave one behind. `timeout` alone is not enough — it kills the
# child it spawned, not the tree beneath it.
prov_absolute_exec_terminates() {   # → 0 when an absolute-path exec finishes
  local dir="$1" rc
  # --no-build-arg-probe: nothing here needs docker. The digest path is reached
  # long before any daemon call, and the recursion (when present) happens there.
  # `bash -c 'script' NAME` sets $0 to NAME, so this reproduces the exact
  # condition: BASH_SOURCE[0] and $0 both the absolute path. Passing the path as
  # $1 with a placeholder $0 does NOT — the strings differ, the old guard works,
  # and the assertion passes against the very defect it exists for. (Measured:
  # the first version of this test did precisely that and was vacuous.)
  #
  # NEITHER `setsid` NOR `timeout` EXISTS ON macOS, and the first version of
  # this assertion used both. Absent, each returns 127 — which is neither 137
  # nor 124, so the check below concluded "terminated" and PASSED. Measured
  # 2026-09-01: with the broken string guard restored, this file reported
  # `PASS (41 assertions)` on macOS and both new assertions were vacuous. A
  # guard for a defect that passes on the platform running it is the same
  # nothing the deleted smoke test was.
  #
  # `set -m` is the portable equivalent of the `setsid` half: with job control
  # on, each background job becomes a process-group leader, so `kill -"$pid"`
  # reaps the TREE. tests/falsify/run.sh: `set -m` is exactly this, for exactly this
  # reason. The clock is a poll rather than `timeout`, for the same portability.
  local pid waited=0
  set -m
  bash -c 'source "$0" >/dev/null 2>&1' "$dir/build.sh" >/dev/null 2>&1 &
  pid=$!
  set +m
  while (( waited < 250 )); do            # 25s, in 0.1s steps
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1; waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # Still alive at the deadline: it is recursing. Kill the GROUP — killing the
    # leader alone leaves the fork bomb running, and a test for one must never
    # leave one behind.
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi
  wait "$pid" 2>/dev/null
  return 0
}

# $ENGINE_DIR, NEVER $REPO_DIR. Every other reference in this file resolves the
# engine through the ENGINE_DIR fallback at the top of it, because the mgd port
# keeps the engine under `base/` with tests at the root. These two assertions
# were written against $REPO_DIR, where in that layout there is no build.sh at
# all — so `source` failed instantly, the bound saw a process that terminated,
# and the assertion PASSED. Measured 2026-09-02 by restoring the pre-#218 string
# guard in both layouts: the flat one FAILS (the assertion works), the `base/`
# one PASSES against the very fork bomb it exists for.
#
# THE SUBJECT IS ASSERTED PRESENT FIRST, so "the file is not where I looked" can
# never again be reported as "the guard is correct" — which is the failure mode
# this whole batch of work is about.
if [[ ! -f "$ENGINE_DIR/build.sh" ]]; then
  fail "sourcing build.sh by absolute path returns instead of running the build — there is no build.sh under $ENGINE_DIR, so both assertions here would be vacuous"
  fail "  … while an EXECUTED build.sh still runs — same missing subject"
else
  # The real file, sourced by its own absolute path — the shape that recursed.
  if prov_absolute_exec_terminates "$ENGINE_DIR"; then
    pass "sourcing build.sh by absolute path returns instead of running the build"
  else
    fail "sourcing build.sh by absolute path did not return — the sourced-guard is comparing strings, so \$0 matching BASH_SOURCE[0] restarts the build inside ai_containers_config_digest"
  fi

  # AND THE GUARD IS NOT VACUOUS: it must still let an EXECUTED build.sh run. A
  # guard that returns early always would satisfy the assertion above and break
  # every build, so the negative case is asserted too — cheaply, by checking that
  # an executed build.sh gets far enough to reject a bad argument rather than
  # returning silently at the top.
  # `p_timeout`, not `timeout`: see the portability note above — a bare `timeout`
  # is absent on macOS, returns 127, and satisfies this test's own `rc -ne 0`
  # condition while running nothing at all.
  out="$(cd "$ENGINE_DIR" && p_timeout 20 ./build.sh --definitely-not-a-flag 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 124 && -n "$out" ]]; then
    pass "  … while an EXECUTED build.sh still runs (the guard is not always-return)"
  else
    fail "  … while an EXECUTED build.sh still runs — it returned silently, so the guard fires for execution too (rc=$rc)"
  fi
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
