#!/usr/bin/env bash
# Hermetic tests for tests/integration/docker-shim.sh — the pass-through `docker`
# the mounts/groups/volumes cases put on PATH while driving the REAL sandbox.sh.
#
# No daemon: IT_REAL_DOCKER points at a recorder that writes its argv to a file,
# so every assertion here is about the exact command the shim would have run.
# The shim working against a real daemon is proven separately by run.sh's
# probe_launcher, which is the only honest way to test that half.
#
# The load-bearing test in this file is the LAST one — the single-`-it` premise.
# The shim identifies the container under test by the `-it` flag, which is sound
# only while sandbox.sh:805 is the only `docker run -it` a launcher run can
# reach. If that stops being true, the shim silently renames and detaches
# somebody else's container and the affected case fails somewhere far away. This
# test makes the premise itself the thing that breaks.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$REPO_DIR/tests/integration/docker-shim.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n'"       expected: $2"$'\n'"       got:      $3"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$SHIM" && pass "docker-shim.sh bash -n" || fail "docker-shim.sh bash -n"
[[ -x "$SHIM" ]] && pass "docker-shim.sh is executable" || fail "docker-shim.sh is executable"

# ── A recorder standing in for the real docker ─────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/realdocker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC"
EOF
chmod +x "$TMP/bin/realdocker"
ln -sf "$SHIM" "$TMP/bin/docker"

export REC="$TMP/recorded.txt"
export IT_REAL_DOCKER="$TMP/bin/realdocker"
export IT_LABEL="ai-containers.it-run=unit"
export IT_LAUNCH_NAME="it-launch-unit"

# argv joined with | so a rewrite that merges or splits arguments is visible.
shim() { : > "$REC"; "$TMP/bin/docker" "$@" >/dev/null 2>&1; tr '\n' '|' < "$REC"; }

# ── The container under test: -it → -d -i, plus name and label ─────────────────
check "main run: -it becomes -d -i, name and label injected" \
  "run|--label|ai-containers.it-run=unit|--name|it-launch-unit|-d|-i|--rm|ai-sandbox|" \
  "$(shim run -it --rm ai-sandbox)"

check "main run: -ti is the same flag pair and is rewritten too" \
  "run|--label|ai-containers.it-run=unit|--name|it-launch-unit|-d|-i|--rm|ai-sandbox|" \
  "$(shim run -ti --rm ai-sandbox)"

# The image must stay last and every injected flag must precede it, or docker
# reads the injection as the container's command.
out="$(shim run -it --rm -v /a:/b:ro -w /workspace ai-sandbox)"
check "main run: injected flags precede the image, image stays last" \
  "run|--label|ai-containers.it-run=unit|--name|it-launch-unit|-d|-i|--rm|-v|/a:/b:ro|-w|/workspace|ai-sandbox|" \
  "$out"

# ── Helper runs are labelled but NEVER renamed or detached ─────────────────────
# seed_workcopy_volume's copy container and repo.sh's seeding containers are
# synchronous and their output is parsed by the caller. Detaching one would
# return an empty result to a script that expected content; renaming two of them
# in the same run would collide outright.
check "helper run: labelled, not renamed, not detached" \
  "run|--label|ai-containers.it-run=unit|--rm|--entrypoint|bash|img|-c|cp -a /src/. /dst/|" \
  "$(shim run --rm --entrypoint bash img -c 'cp -a /src/. /dst/')"

# ── Volumes and networks are labelled so the runner's sweep can find them ──────
check "volume create: labelled" \
  "volume|create|--label|ai-containers.it-run=unit|ai-containers-rvm-g|" \
  "$(shim volume create ai-containers-rvm-g)"
check "network create: labelled" \
  "network|create|--label|ai-containers.it-run=unit|netname|" \
  "$(shim network create netname)"
check "volume rm is passed through untouched (no label injection)" \
  "volume|rm|somevol|" \
  "$(shim volume rm somevol)"
check "an unrelated subcommand is passed through untouched" \
  "ps|-aq|--filter|name=x|" \
  "$(shim ps -aq --filter name=x)"
check "inspect is passed through untouched" \
  "volume|inspect|v|" \
  "$(shim volume inspect v)"

# ── Refusals ───────────────────────────────────────────────────────────────────
# A shim that silently did nothing when misconfigured would run the case against
# an un-renamed, foreground container — i.e. hang, then time out.
out="$(env -u IT_REAL_DOCKER "$TMP/bin/docker" run -it img 2>&1)"; rc=$?
if [[ "$rc" -eq 127 ]] && grep -q 'IT_REAL_DOCKER is unset' <<< "$out"; then
  pass "refuses with 127 when IT_REAL_DOCKER is unset"
else
  fail "refuses with 127 when IT_REAL_DOCKER is unset (rc=$rc, out=$out)"
fi

out="$(IT_REAL_DOCKER="$TMP/bin/nonexistent" "$TMP/bin/docker" run -it img 2>&1)"; rc=$?
if [[ "$rc" -eq 127 ]] && grep -q 'not executable' <<< "$out"; then
  pass "refuses with 127 when IT_REAL_DOCKER is not executable"
else
  fail "refuses with 127 when IT_REAL_DOCKER is not executable (rc=$rc, out=$out)"
fi

# Pointing the shim at itself would fork until the process table gives out.
out="$(IT_REAL_DOCKER="$TMP/bin/docker" "$TMP/bin/docker" run -it img 2>&1)"; rc=$?
if [[ "$rc" -eq 127 ]] && grep -q 'points back at the shim' <<< "$out"; then
  pass "refuses when IT_REAL_DOCKER points back at the shim"
else
  fail "refuses when IT_REAL_DOCKER points back at the shim (rc=$rc, out=$out)"
fi

# Without IT_LAUNCH_NAME there is nothing to exec into, but the shim must still
# detach — otherwise a caller that forgot it blocks forever instead of failing.
check "main run without IT_LAUNCH_NAME: still detached, no --name" \
  "run|--label|ai-containers.it-run=unit|-d|-i|--rm|img|" \
  "$(: > "$REC"; env -u IT_LAUNCH_NAME "$TMP/bin/docker" run -it --rm img >/dev/null 2>&1; tr '\n' '|' < "$REC")"

# ── The premise the whole mechanism rests on ───────────────────────────────────
# Scope: the scripts a launcher run can actually reach through the shim. Not
# entrypoint.sh (runs inside the container, never under this PATH) and not
# verify-on-host.sh (a host entry point that calls the runner, never the reverse)
# — constraining those would fail this test for a change that cannot affect the
# shim, and a test that cries wolf gets deleted.
#
# Comments are stripped first. A comment mentioning `docker run -it` — this
# file's own header does exactly that — is prose, not an invocation, and a
# scanner that cannot tell the difference flags the text explaining the rule.
# Layout-tolerant, like run.sh and lib.sh: upstream keeps the engine beside
# tests/, mgd-ai-containers keeps it in base/. Hits are reported by BARE
# filename so the expected value is one string in both repos — the shared files
# are byte-identical, so the line number is too.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
if [[ ! -f "$ENGINE_DIR/sandbox.sh" ]]; then
  fail "cannot locate sandbox.sh at the repo root or in base/ — the premise scan checked nothing"
  printf '\n%d failure(s)\n' "$fails"
  exit "$fails"
fi
reachable=(sandbox.sh sandbox-common.sh repo.sh group.sh tools-lib.sh)
hits=""
for f in "${reachable[@]}"; do
  [[ -f "$ENGINE_DIR/$f" ]] || continue
  while IFS= read -r n; do
    hits="${hits:+$hits }$f:$n"
  done < <(awk '!/^[[:space:]]*#/ && /(^|[[:space:]])-(it|ti)([[:space:]]|$)/ { print NR }' "$ENGINE_DIR/$f")
done
check "exactly one -it/-ti in the scripts a launcher run reaches" "sandbox.sh:805" "$hits"
if [[ "$hits" != "sandbox.sh:805" ]]; then
  printf '       The shim identifies the container under test by the -it flag.\n'
  printf '       If a second one now exists, either give the new call a distinct\n'
  printf '       marker or teach docker-shim.sh to tell them apart — and update\n'
  printf '       its header, which states this premise as verified.\n'
fi

# The scan must be capable of finding a violation, or it is decorative. Prove it
# against a file that has one, rather than trusting a clean result.
printf 'docker run -ti --rm x\n' > "$TMP/violator.sh"
found="$(awk '!/^[[:space:]]*#/ && /(^|[[:space:]])-(it|ti)([[:space:]]|$)/ { print NR }' "$TMP/violator.sh")"
check "the -it scan actually detects a violation" "1" "$found"
# …and must not be fooled by the same text in a comment.
printf '# docker run -it --rm x\n' > "$TMP/commented.sh"
found="$(awk '!/^[[:space:]]*#/ && /(^|[[:space:]])-(it|ti)([[:space:]]|$)/ { print NR }' "$TMP/commented.sh")"
check "the -it scan ignores a commented-out occurrence" "" "$found"

# ── Every reference to the pinned line agrees with reality ────────────────────
# This file already pins sandbox.sh:<N> for its OWN two references, which is why
# a shift breaks it loudly. It knew nothing about the other references to the
# same line, and two of them (docker-shim.sh, run.sh) sat 30 lines stale until
# an unrelated comment edit exposed them. A named list can only police what it
# names — so derive the list instead.
want_line="$(grep -n 'docker run -it' "$REPO_DIR/sandbox.sh" | cut -d: -f1)"
[[ -n "$want_line" ]] \
  || fail "no 'docker run -it' found in sandbox.sh — this whole file's premise is gone"
# AGENTS.md (M4): the canonical doc names this same line (sandbox.sh:805, in its
# "Two tiers, two verbs" section) and had to be hand-fixed once already when the
# line moved — scoping this scan to '*.sh' alone let it rot again with nothing
# catching it. Verified: a literal 'AGENTS.md' pathspec (no wildcard) matches
# ONLY the exact root-relative path, so this reaches the canonical file but not
# its symlinked copies (.github/copilot-instructions.md,
# .kiro/steering/AGENTS.md — same bytes, so nothing is lost) and not anything
# under docs/superpowers/**, which stays excluded on purpose — those are
# historical records of what was true when written, like CHANGELOG.md (also not
# scanned here), not live documentation that must track the current line
# number.
bad="$(cd "$REPO_DIR" && git grep -hoE 'sandbox\.sh:[0-9]+' -- '*.sh' 'AGENTS.md' \
         | sort -u | grep -v "^sandbox\.sh:${want_line}$" || true)"
[[ -z "$bad" ]] \
  && pass "every sandbox.sh:<line> reference in tracked scripts points at $want_line" \
  || fail "stale sandbox.sh line reference(s): $(printf '%s' "$bad" | tr '\n' ' ')(actual: $want_line)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
