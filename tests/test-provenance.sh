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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
