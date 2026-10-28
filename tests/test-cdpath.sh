#!/usr/bin/env bash
# tests/test-cdpath.sh — the host entry points find their own directory whatever
# CDPATH the user's shell exports (bugs review GIT-17, GIT-20).
#
# Each entry point resolves its directory with `cd "$(dirname "${BASH_SOURCE[0]}")"`.
# Run as `bash eng/build.sh`, that dirname is the relative `eng`, which `cd` looks
# up through an exported CDPATH first — and then prints the directory it went to,
# into the captured path. So each one is copied into a scratch eng/, beside stub
# bash-floor.sh and sandbox-common.sh that print REAL and exit, and run with
# CDPATH naming a decoy holding an eng/ whose stubs print DECOY. Whatever the
# script sources first must be its own.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work/eng" "$TMP/decoy/eng"
for d in work decoy; do
  word=REAL; [[ "$d" == decoy ]] && word=DECOY
  for s in bash-floor.sh sandbox-common.sh; do
    printf 'printf "%%s\\n" %s; exit 0\n' "$word" > "$TMP/$d/eng/$s"
  done
done

ENTRY_POINTS=(sandbox.sh build.sh repo.sh group.sh project-init.sh sync-to-projects.sh
  extract-discovery.sh migrate-runme.sh ai-containers-report.sh release-title.sh
  changelog-coverage.sh changelog-section.sh check-sandbox-version.sh bump-sandbox-version.sh)
# Sourced only, from entry points above that already unset CDPATH.
LIBS=(sandbox-common.sh version.sh)

# Every root script that resolves its own directory is listed, so a new entry
# point fails here rather than going unchecked.
listed=" ${ENTRY_POINTS[*]} ${LIBS[*]} "
while IFS= read -r p; do
  b="${p##*/}"
  [[ "$listed" == *" $b "* ]] && continue
  fail "$b resolves its own directory with cd \"\$(dirname …)\" and is in neither ENTRY_POINTS nor LIBS here"
done < <(grep -lE 'cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"' "$REPO_DIR"/*.sh)

for f in "${ENTRY_POINTS[@]}"; do
  if [[ ! -f "$REPO_DIR/$f" ]]; then fail "$f: not in this repository"; continue; fi
  cp "$REPO_DIR/$f" "$TMP/work/eng/$f"
  out="$(cd "$TMP/work" && CDPATH="$TMP/decoy" bash "eng/$f" </dev/null 2>&1)"
  first="$(head -n 1 <<<"$out")"
  if [[ "$first" == REAL ]]; then
    pass "$f sources its own directory with CDPATH exported"
  else
    fail "$f followed CDPATH (first line: '$first')"
  fi
done

# The runme.sh project-init.sh generates cd's to its own directory and runs
# ./build.sh there: with a CDPATH holding another project's .ai-containers it
# built and started THAT project, with no error at all (review of GIT-20).
mkdir -p "$TMP/work/proj/.ai-containers" "$TMP/decoy/proj/.ai-containers"
# shellcheck disable=SC1091
( source "$REPO_DIR/project-init.sh" 2>/dev/null; emit_launcher "$TMP/work/proj/.ai-containers/runme.sh" proj )
for d in work decoy; do
  word=REAL; [[ "$d" == decoy ]] && word=DECOY
  for s in build.sh sandbox.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$word" > "$TMP/$d/proj/.ai-containers/$s"
    chmod +x "$TMP/$d/proj/.ai-containers/$s"
  done
done
out="$(cd "$TMP/work" && GITHUB_TOKEN=x CDPATH="$TMP/decoy" bash proj/.ai-containers/runme.sh </dev/null 2>&1)"
[[ "$(head -n 1 <<<"$out")" == REAL ]] && pass "the generated runme.sh builds its own project with CDPATH exported" \
  || fail "the generated runme.sh followed CDPATH (first line: '$(head -n 1 <<<"$out")')"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
