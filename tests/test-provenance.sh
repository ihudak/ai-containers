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
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox-common.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n'"  expected: $2"$'\n'"  got:      $3"; fi; }

# The helpers are sourced, not re-implemented: a copy here could agree with
# itself while disagreeing with the launcher, which is the failure this whole
# file is about.
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
check "every label is preceded by its --label flag" "2" "$(grep -cx -- '--label' <<<"$labels")"

# And the other half of that branch: when the assets ARE a checkout, the commit
# is recorded. Untested, this is the case that silently stops working — the
# central repo is the only place it ever fires.
G="$TMP/gitassets"; mk_assets "$G"
( cd "$G" && git init -q . && git add -A >/dev/null 2>&1 \
    && git -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1 ) || true
if [[ -d "$G/.git" ]]; then
  glabels="$(ai_containers_provenance_labels "$G" 2026-01-01T00:00:00Z)"
  gcommit="$(git -C "$G" rev-parse HEAD 2>/dev/null)"
  grep -qxF "ai-containers.source-commit=$gcommit" <<<"$glabels" \
    && pass "a git checkout records the commit it was built from" \
    || fail "a git checkout records the commit it was built from"
  check "a git checkout carries all three labels" "3" "$(grep -cx -- '--label' <<<"$glabels")"
else
  printf 'SKIP: git could not create a fixture repo\n'
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
# build-time keys with runtime ones, and a warning that fires when `mode=`
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
    # A RUNTIME key. `mode=` picks the firewall the container starts under and
    # rebuilds nothing, so it must leave the digest alone.
    sed 's/^mode=.*/mode=open/' "$ENGINE_DIR/sandbox.conf" > "$TMP/mode.conf"
    check "a runtime-only key (mode=) leaves the config digest alone" \
      "$base_cfg" "$(cfg_of "$TMP/mode.conf")"
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
  setsid timeout -s KILL 25 \
    bash -c 'source "$0" >/dev/null 2>&1' "$dir/build.sh" >/dev/null 2>&1
  rc=$?
  return $(( rc == 137 || rc == 124 ? 1 : 0 ))
}

# The real file, sourced by its own absolute path — the shape that recursed.
if prov_absolute_exec_terminates "$REPO_DIR"; then
  pass "sourcing build.sh by absolute path returns instead of running the build"
else
  fail "sourcing build.sh by absolute path did not return — the sourced-guard is comparing strings, so \$0 matching BASH_SOURCE[0] restarts the build inside ai_containers_config_digest"
fi

# AND THE GUARD IS NOT VACUOUS: it must still let an EXECUTED build.sh run. A
# guard that returns early always would satisfy the assertion above and break
# every build, so the negative case is asserted too — cheaply, by checking that
# an executed build.sh gets far enough to reject a bad argument rather than
# returning silently at the top.
if out="$(cd "$REPO_DIR" && timeout 20 ./build.sh --definitely-not-a-flag 2>&1)"; rc=$?; [[ "$rc" -ne 0 && -n "$out" ]]; then
  pass "  … while an EXECUTED build.sh still runs (the guard is not always-return)"
else
  fail "  … while an EXECUTED build.sh still runs — it returned silently, so the guard fires for execution too (rc=$rc)"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
