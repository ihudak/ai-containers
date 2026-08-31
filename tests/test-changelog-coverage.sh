#!/usr/bin/env bash
# tests/test-changelog-coverage.sh — changelog-coverage.sh reports what a
# release would contain, and raises its one mechanical alarm correctly.
#
# THE ALARM IS THE ONLY THING WITH A VERDICT, so it is the only thing asserted
# as one: non-docs commits exist since the last tag AND Unreleased is empty.
# Everything else the script prints is material for a human to read the notes
# against, and a test that pinned that wording would be testing prose.
#
# THE CASE THAT MATTERS MOST IS THE RELEASE COMMIT. A release MOVES entries out
# of Unreleased into a dated section, so immediately afterwards Unreleased is
# empty by construction. Any rule keyed on "Unreleased is empty" therefore fires
# on every release unless docs-only changes are excluded — which is exactly the
# false positive that ruled out the per-PR gate this script replaced, measured
# at eight in fourteen sampled commits.
#
# AND THE MERGE-DIFF TRAP, which this script nearly shipped: a merge commit has
# no diff of its own, so `git show --name-only <merge>` prints NOTHING. A
# classifier built on it calls every merge docs-only and the alarm can never
# fire. The fixture below lands its change as a real merge commit for that
# reason — a squashed commit would pass against the broken implementation too.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$REPO_DIR/changelog-coverage.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -x "$SCRIPT" ]] || { printf 'SCAFFOLD-FAILED: no executable changelog-coverage.sh\n'; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'SCAFFOLD-FAILED: git is required\n'; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# A world: a tagged release, then one merge of the caller's choosing.
# `changelog-coverage.sh` resolves both its own directory and the repo from
# $BASH_SOURCE, so the script is COPIED in rather than pointed at.
#
# AND SO IS bash-floor.sh, WHICH THE SCRIPT SOURCES FROM BESIDE ITSELF. Copying
# the tool alone builds a world the tool cannot run in: the source fails, bash
# prints `bash-floor.sh: No such file or directory` into every assertion's
# captured output, and — because the script does not `set -e` — execution
# carries on with the floor guard never loaded. Fourteen assertions passed that
# way, and deleting the source line outright would not have failed one of them.
# A fixture that is not the tool's real environment tests a tool that does not
# ship.
seed_world_files() {   # <dir>
  cp "$SCRIPT" "$1/changelog-coverage.sh"
  cp "$REPO_DIR/bash-floor.sh" "$1/bash-floor.sh"
}
mk_world() {   # <dir> <unreleased-body> <file-to-touch>
  local d="$1" body="$2" file="$3"
  rm -rf "$d"; mkdir -p "$d/docs"
  seed_world_files "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  printf '# Changelog\n\n## Unreleased\n\n## v1.0.0 — 2026-01-01\n\n### something\n\nreleased.\n' > "$d/CHANGELOG.md"
  printf 'base\n' > "$d/base.txt"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  git -C "$d" tag v1.0.0
  # A REAL MERGE, not a squash: see the header. A branch, a commit on it, then
  # a --no-ff merge back, so the merge commit has two parents exactly as a
  # merged pull request does.
  git -C "$d" checkout -q -b work
  mkdir -p "$d/$(dirname "$file")" 2>/dev/null || true
  printf 'changed\n' > "$d/$file"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "work: touch $file"
  git -C "$d" checkout -q -
  git -C "$d" merge -q --no-ff work -m "Merge pull request #99 from x/work" >/dev/null
  if [[ -n "$body" ]]; then
    # awk, NOT python3: the bash-floor arm runs ubuntu:22.04, which HAS NO
    # python3. tests/portability.sh records that fact a few files away, and this
    # fixture used python3 anyway -- the injection silently did nothing there, so
    # Unreleased stayed empty, the alarm fired correctly, and two assertions
    # failed as though the SUBJECT were broken. Six arms green, one red, and the
    # red one was the test.
    awk -v b="$body" '
      {print}
      /^## Unreleased$/ && !seen { print ""; print "### " b; print ""; print "prose."; seen=1 }
    ' "$d/CHANGELOG.md" > "$d/CHANGELOG.new" && mv "$d/CHANGELOG.new" "$d/CHANGELOG.md"
    # THE FIXTURE ASSERTS ITSELF. Without this, any future injection failure
    # reads as a defect in changelog-coverage.sh rather than a broken world --
    # which is exactly how the python3 dependency presented.
    if ! grep -q "^### $body$" "$d/CHANGELOG.md"; then
      printf 'SCAFFOLD-FAILED: could not inject an Unreleased entry into the fixture\n'
      exit 1
    fi
    git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "docs: note it"
  fi
}

# ${2:+"$2"} and NOT "${2:-}": the latter passes an EMPTY STRING when no flag is
# wanted, which the script rightly refuses as an unknown argument — six of these
# assertions failed that way on the first run, all of them scaffolding rather
# than a defect in the subject.
run() { ( cd "$1" && ./changelog-coverage.sh ${2:+"$2"} 2>&1 ); }
rc_of() { ( cd "$1" && ./changelog-coverage.sh ${2:+"$2"} >/dev/null 2>&1 ); printf '%s' "$?"; }

# ── 1. the alarm: a code change, and nothing written about it ────────────────
mk_world "$TMP/bare" "" "sandbox.sh"
out="$(run "$TMP/bare")"
if grep -q "EMPTY UNRELEASED" <<< "$out"; then
  pass "a non-docs merge with an empty Unreleased raises the alarm"
else
  fail "a non-docs merge with an empty Unreleased raises the alarm (got: $(tr '\n' '|' <<< "$out"))"
fi
# The merge must be COUNTED, which is the part the merge-diff trap breaks.
if grep -qE '1 touching non-docs files' <<< "$out"; then
  pass "  … and the merge is counted, so the classifier read its first-parent diff"
else
  fail "  … and the merge is counted — a merge has no diff of its own, so this is the \`git show\` trap (got: $(tr '\n' '|' <<< "$out"))"
fi
check_rc() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected rc $2, got $3)"; fi; }
check_rc "  … --check exits 1 on it" "1" "$(rc_of "$TMP/bare" --check)"
check_rc "  … and without --check it still exits 0, so a report is not a gate" "0" "$(rc_of "$TMP/bare")"

# ── 2. the same change, described: silence ───────────────────────────────────
mk_world "$TMP/noted" "a real entry" "sandbox.sh"
out="$(run "$TMP/noted")"
if grep -q "EMPTY UNRELEASED" <<< "$out"; then
  fail "a described change raises no alarm — it did"
else
  pass "a described change raises no alarm"
fi
check_rc "  … and --check exits 0" "0" "$(rc_of "$TMP/noted" --check)"

# ── 3. THE RELEASE COMMIT: docs-only work, empty Unreleased, no alarm ────────
# This is the case that ruled out the per-PR gate. Immediately after a release
# the Unreleased section is empty BY CONSTRUCTION; if docs-only changes counted,
# every release would trip its own check.
mk_world "$TMP/docsonly" "" "docs/note.md"
out="$(run "$TMP/docsonly")"
if grep -q "EMPTY UNRELEASED" <<< "$out"; then
  fail "docs-only merges with an empty Unreleased raise NO alarm — this is the release commit, and it fired"
else
  pass "docs-only merges with an empty Unreleased raise no alarm (the release-commit case)"
fi
check_rc "  … --check exits 0 there" "0" "$(rc_of "$TMP/docsonly" --check)"

# ── 4. environments where the question does not apply ────────────────────────
notgit="$TMP/notgit"; rm -rf "$notgit"; mkdir -p "$notgit"
seed_world_files "$notgit"
printf '# Changelog\n\n## Unreleased\n' > "$notgit/CHANGELOG.md"
out="$(run "$notgit")"
if grep -q "^SKIP: not a git repository" <<< "$out"; then
  pass "a project copy is not a git repo: it SKIPs rather than reporting a clean bill of health"
else
  fail "a project copy SKIPs (got: $(tr '\n' '|' <<< "$out"))"
fi
check_rc "  … exiting 0" "0" "$(rc_of "$notgit")"

untagged="$TMP/untagged"; rm -rf "$untagged"; mkdir -p "$untagged"
seed_world_files "$untagged"
printf '# Changelog\n\n## Unreleased\n' > "$untagged/CHANGELOG.md"
git -C "$untagged" init -q; git -C "$untagged" config user.email t@t
git -C "$untagged" config user.name t; git -C "$untagged" config commit.gpgsign false
git -C "$untagged" add -A >/dev/null; git -C "$untagged" commit -qm base
out="$(run "$untagged")"
if grep -q "^SKIP: no tags yet" <<< "$out"; then
  pass "with no tags there is no 'since the last release', and it says so"
else
  fail "with no tags it SKIPs (got: $(tr '\n' '|' <<< "$out"))"
fi

# ── 5. an unknown argument is refused, not ignored ───────────────────────────
check_rc "an unknown argument exits 2 rather than silently reporting" "2" "$(rc_of "$TMP/bare" --nonsense)"

# ── 6. the two exit statuses that are easy to get backwards ──────────────────
# --help SUCCEEDS. Asking a tool how to use it is not an error, and a non-zero
# --help fails any wrapper that runs it with `set -e` to build a usage message.
check_rc "--help exits 0 — asking how to use a tool is not an error" "0" "$(rc_of "$TMP/bare" --help)"
out="$(run "$TMP/bare" --help)"
if grep -q 'Usage: changelog-coverage.sh' <<< "$out"; then
  pass "  … and prints usage rather than a report"
else
  fail "  … and prints usage rather than a report (got: $(head -c 120 <<< "$out"))"
fi

# AND THE SKIP EXITS 0 TOO. "No tags yet" is not a failure — it is the state of
# a fresh clone, and a non-zero there would make the release step fail on every
# repository that has never been tagged. Asserted separately from the message,
# because a SKIP that says the right thing and exits 1 is the shape that breaks
# a caller while reading correctly to a human.
check_rc "the no-tags SKIP exits 0, so a fresh clone does not fail its release step" "0" "$(rc_of "$untagged")"
check_rc "  … and --check does not turn that SKIP into a failure" "0" "$(rc_of "$untagged" --check)"

# ── 7. the floor the script sources is LOADED, and can stop it ───────────────
# Two assertions, because they fail differently. The first says the source line
# runs at all; the second says what it loads is allowed to refuse. Without the
# pair, a fixture missing bash-floor.sh reads exactly like a fixture whose floor
# passed — which is the state every assertion above was in until this section
# existed.
#
# A STAND-IN, not the real floor: bash-floor.sh ASSIGNS
# AI_CONTAINERS_BASH_FLOOR_MAJOR/MINOR unconditionally, so the environment
# cannot raise the floor to provoke a refusal, and the running bash clears the
# real one by definition. What is under test is the wiring — that the script
# loads a file named bash-floor.sh from beside itself and lets it have its say.
if grep -q 'bash-floor.sh' "$SCRIPT"; then
  pass "changelog-coverage.sh sources a bash floor at all"
else
  fail "changelog-coverage.sh sources a bash floor at all — it does not, so section 7 tests nothing"
fi
floorw="$TMP/floor"; rm -rf "$floorw"; mkdir -p "$floorw"
seed_world_files "$floorw"
printf '# Changelog\n\n## Unreleased\n' > "$floorw/CHANGELOG.md"
printf '#!/usr/bin/env bash\nprintf "FLOOR-LOADED\\n" >&2\n' > "$floorw/bash-floor.sh"
out="$(run "$floorw")"
if grep -q 'FLOOR-LOADED' <<< "$out"; then
  pass "the floor beside the script is actually sourced, not merely named in it"
else
  fail "the floor beside the script is actually sourced (got: $(tr '\n' '|' <<< "$out"))"
fi

printf '#!/usr/bin/env bash\nprintf "FLOOR-REFUSED\\n" >&2\nexit 1\n' > "$floorw/bash-floor.sh"
out="$(run "$floorw")"; rc="$(rc_of "$floorw")"
if [[ "$rc" == "1" ]] && grep -q 'FLOOR-REFUSED' <<< "$out" && ! grep -q '^SKIP:' <<< "$out"; then
  pass "  … and a floor that refuses stops the tool before it reports anything"
else
  fail "  … and a floor that refuses stops the tool before it reports anything (rc=$rc, out: $(tr '\n' '|' <<< "$out"))"
fi

# AND NO WORLD ABOVE WAS MISSING IT. The report is the point: an assertion that
# greps for one phrase passes happily while bash writes a sourcing error beside
# it, which is exactly what happened here.
noisy=""
for w in "$TMP/bare" "$TMP/noted" "$TMP/docsonly" "$notgit" "$untagged"; do
  grep -q 'No such file or directory' <<< "$(run "$w")" && noisy="${noisy}${noisy:+ }${w##*/}"
done
if [[ -z "$noisy" ]]; then
  pass "no fixture makes the script report a missing file — each is the environment it ships in"
else
  fail "these fixtures run the script in an environment it could not load: $noisy"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
