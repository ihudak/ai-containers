#!/usr/bin/env bash
# tests/test-report.sh — ai-containers-report.sh against fabricated registries.
#
# The property this file exists to pin is a NEGATIVE one: the report covers the
# projects registered in ONE base — its own by default — and does not go
# looking for others. It used to `find` every project-init.sh under a --dev-root
# to a depth of 4, which answered a different question ("what does this whole
# machine have") and made the answer depend on where it was run from. A test
# that only checked the rows it prints would pass just as well with the walk
# back, so the fixture below plants a SECOND base one directory down and
# requires its project to be absent.
#
# Everything here is filesystem-only: registries, project directories and
# sandbox.env files in a temp tree. No docker, no network.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/ai-containers-report.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
SRC="$ENGINE_DIR/ai-containers-report.sh"

# p_realdir: the base line is printed from the script's own `pwd -P`, which on
# macOS resolves /var/folders/… to /private/var/folders/… because /var is a
# symlink. Comparing that against the raw `mktemp -d` output is the exact
# unresolved-vs-resolved mismatch tests/portability.sh exists to prevent, and it
# passed everywhere /tmp is not a symlink — CI and the floor container — while
# failing on every Mac.
# shellcheck source=portability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$SRC" ]] || { printf 'SCAFFOLD-FAILED: no ai-containers-report.sh under %s\n' "$ENGINE_DIR"; exit 1; }
bash -n "$SRC" && pass "ai-containers-report.sh bash -n" || fail "ai-containers-report.sh bash -n"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# mk_base <dir> — a base holding a copy of the script, its floor, version.sh and
# a registry. version.sh is a HARD dependency, sourced beside the script exactly
# as bash-floor.sh is: the report reads each project's engine version and schema
# marker through version_engine/version_schema so its columns cannot disagree
# with what `./sandbox.sh --version` says about the same project.
mk_base() {
  mkdir -p "$1" || return 1
  cp "$SRC" "$ENGINE_DIR/bash-floor.sh" "$ENGINE_DIR/version.sh" "$1/" || return 1
  printf '# registry\n' > "$1/projects.conf"
}
# mk_proj <base> <project-dir> <group> <mode> <cpus>
# mk_proj <base> <project-dir> <group> <mode> <cpus> [engine-version] [schema]
# The last two are OPTIONAL and deliberately so: a project copy made before
# `engine-version` existed has neither, and `unknown/unknown` is the answer the
# report must give for it. Passing them models a copy that has been synced.
mk_proj() {
  local base="$1" dir="$2"
  mkdir -p "$dir/.ai-containers"
  {
    printf 'AI_CONTAINER_GROUP=%s\n' "$3"
    printf 'SANDBOX_MODE=%s\n' "$4"
    printf 'CONTAINER_CPUS=%s\n' "$5"
    printf 'CONTAINER_MEMORY=8g\nCONTAINER_MEMORY_RESERVATION=4g\nCONTAINER_MEMORY_SWAP=8g\n'
  } > "$dir/.ai-containers/sandbox.env"
  [[ -n "${6:-}" ]] && printf '%s\n' "$6" > "$dir/.ai-containers/engine-version"
  [[ -n "${7:-}" ]] && printf '# schema-version: %s\n' "$7" > "$dir/.ai-containers/sandbox.conf"
  printf '%s\n' "$dir" >> "$base/projects.conf"
}

run() { OUT="$("$@" 2>&1)"; RC=$?; }
OUT=""; RC=0

# ── the fixture ──────────────────────────────────────────────────────────────
OUTER="$TMP/outer/base"
mk_base "$OUTER" || { printf 'SCAFFOLD-FAILED: mk_base\n'; exit 1; }
mk_proj "$OUTER" "$TMP/outer/web" ihudak  DISCOVERY  4.0 v0.7.0-3-gabc1234 4
mk_proj "$OUTER" "$TMP/outer/api" default RESTRICTED 2.0

# A SECOND, complete base one level down — the thing a filesystem walk would
# find and this report must not.
NESTED="$TMP/outer/nested/base"
mk_base "$NESTED"
mk_proj "$NESTED" "$TMP/outer/nested/buried" default OPEN 1.0

# ── 1. only this base's registry ─────────────────────────────────────────────
run "$OUTER/ai-containers-report.sh" --full-paths
[[ "$RC" -eq 0 ]] && pass "the report exits 0" || fail "the report exits 0 (rc=$RC)
$OUT"

if grep -q ' web ' <<<"$OUT" && grep -q ' api ' <<<"$OUT"; then
  pass "this base's registered projects are reported"
else
  fail "this base's registered projects are reported
$OUT"
fi
if grep -q 'buried' <<<"$OUT"; then
  fail "a base in a SUBDIRECTORY is not searched for — 'buried' was reported
$OUT"
else
  pass "a base in a subdirectory is not searched for"
fi
if grep -q '2 registered project(s)' <<<"$OUT"; then
  pass "the count is this base's registry, not the filesystem's"
else
  fail "the count is this base's registry, not the filesystem's
$(grep -F 'registered project' <<<"$OUT")"
fi

# ── 2. the single-base layout ────────────────────────────────────────────────
if grep -qF "base: $(p_realdir "$TMP/outer/base")" <<<"$OUT"; then
  pass "one base is stated once, above the table"
else
  fail "one base is stated once, above the table
$OUT"
fi
if grep -qE '^VERSION  +SCHEMA  +GROUP  +PROJECT' <<<"$OUT"; then
  pass "… and the BASE column is gone from the header"
else
  fail "… and the BASE column is gone from the header
$(grep -E 'GROUP' <<<"$OUT")"
fi

# ── 3. the values themselves ─────────────────────────────────────────────────
if grep -qE '^v0\.7\.0-3-gabc1234 +4 +ihudak +web +DISCOVERY +4\.0 +8g/4g/8g' <<<"$OUT"; then
  pass "group, network mode, cpus and memory are read from sandbox.env"
else
  fail "group, network mode, cpus and memory are read from sandbox.env
$OUT"
fi

# ── 4. two bases named explicitly ────────────────────────────────────────────
#
# The separator between two BASE_DIR arguments was `$(printf '\n')`, which is
# the EMPTY string — command substitution strips trailing newlines — so the two
# paths concatenated into one nonexistent directory and the run died. Latent
# while a filesystem walk supplied the list; load-bearing now that naming them
# is the only way to report on more than one.
run "$OUTER/ai-containers-report.sh" --full-paths --no-notes "$OUTER" "$NESTED"
if [[ "$RC" -eq 0 ]] && grep -q 'buried' <<<"$OUT" && grep -q ' web ' <<<"$OUT"; then
  pass "two bases named explicitly are BOTH reported"
else
  fail "two bases named explicitly are both reported (rc=$RC)
$OUT"
fi
if grep -qE '^BASE  +VERSION  +SCHEMA  +GROUP' <<<"$OUT"; then
  pass "… and the BASE column comes back when it distinguishes rows"
else
  fail "… and the BASE column comes back when it distinguishes rows
$(grep -E 'GROUP' <<<"$OUT")"
fi

# ── 5. tsv keeps one schema ──────────────────────────────────────────────────
run "$OUTER/ai-containers-report.sh" --tsv
one_base_header="$(head -1 <<<"$OUT")"
run "$OUTER/ai-containers-report.sh" --tsv "$OUTER" "$NESTED"
two_base_header="$(head -1 <<<"$OUT")"
if [[ "$one_base_header" == "$two_base_header" ]] && [[ "$one_base_header" == base* ]]; then
  pass "--tsv emits the same columns either way, base first"
else
  fail "--tsv emits the same columns either way
  one:  $one_base_header
  two:  $two_base_header"
fi

# ── 6. footnotes ─────────────────────────────────────────────────────────────
printf '%s\n' "$TMP/outer/ghost" >> "$OUTER/projects.conf"
mkdir -p "$TMP/outer/nolauncher/.ai-containers"
printf '%s\n' "$TMP/outer/nolauncher" >> "$OUTER/projects.conf"
run "$OUTER/ai-containers-report.sh" --full-paths
if grep -q 'stale registry entry' <<<"$OUT"; then
  pass "a registry entry whose path is gone is called out"
else
  fail "a registry entry whose path is gone is called out
$OUT"
fi
if grep -q 'no .ai-containers/sandbox.env' <<<"$OUT"; then
  pass "a project with no sandbox.env is called out"
else
  fail "a project with no sandbox.env is called out
$OUT"
fi
run "$OUTER/ai-containers-report.sh" --full-paths --no-notes
if ! grep -q 'stale registry entry' <<<"$OUT"; then
  pass "--no-notes suppresses the footnotes"
else
  fail "--no-notes suppresses the footnotes"
fi

# ── 7. markdown ──────────────────────────────────────────────────────────────
run "$OUTER/ai-containers-report.sh" --markdown
if grep -q '^| Version | Schema | Container group | Project |' <<<"$OUT" && ! grep -q '^| Base |' <<<"$OUT"; then
  pass "--markdown drops the Base column for one base too"
else
  fail "--markdown drops the Base column for one base too
$(grep '^|' <<<"$OUT" | head -2)"
fi
run "$OUTER/ai-containers-report.sh" --markdown "$OUTER" "$NESTED"
if grep -q '^| Base | Version | Schema | Container group |' <<<"$OUT"; then
  pass "--markdown restores it for several"
else
  fail "--markdown restores it for several
$(grep '^|' <<<"$OUT" | head -2)"
fi

# ── 6b. the columns that come from the filesystem, not from sandbox.env ──────
#
# .agent-discovery and the pre-rename launcher note are read off disk, and
# nothing above creates either — so both branches were dead in this fixture and
# every mutant of them survived.
mkdir -p "$TMP/outer/web/.ai-containers/.agent-discovery"
head -c 40000 /dev/zero > "$TMP/outer/web/.ai-containers/.agent-discovery/agent-traffic.pcap"
run "$OUTER/ai-containers-report.sh" --full-paths
if grep -qE '^v0\.7\.0-3-gabc1234 +4 +ihudak +web +DISCOVERY +4\.0 +8g/4g/8g +[0-9]' <<<"$OUT"; then
  pass "a project with a capture reports its size, not N/A"
else
  fail "a project with a capture reports its size, not N/A
$(grep ' web ' <<<"$OUT")"
fi
if grep -qE '^unknown +unknown +default +api .* N/A ' <<<"$OUT"; then
  pass "… and a project without one still reports N/A"
else
  fail "… and a project without one still reports N/A
$(grep ' api ' <<<"$OUT")"
fi

# A pre-rename launcher is identified by its `export IMAGE_NAME=` marker, the
# same way sync-to-projects.sh's migration finds it — a file merely named
# *-container.sh is not one.
printf 'export IMAGE_NAME=old\n' > "$TMP/outer/api/.ai-containers/api-container.sh"
printf '# not a launcher\n'      > "$TMP/outer/api/.ai-containers/decoy-container.sh"
run "$OUTER/ai-containers-report.sh" --full-paths
if grep -q 'stale pre-rename launcher(s): api-container.sh' <<<"$OUT"; then
  pass "a pre-rename launcher is reported as a footnote"
else
  fail "a pre-rename launcher is reported as a footnote
$OUT"
fi
if ! grep -q 'decoy-container.sh' <<<"$OUT"; then
  pass "… and a *-container.sh without the marker is not mistaken for one"
else
  fail "… and a *-container.sh without the marker is not mistaken for one
$OUT"
fi

# ── 6c. paths: ~ abbreviation, --path-map, trailing slashes ──────────────────
#
# Every check above passes --full-paths, so the abbreviating branch — the
# default — was never taken.
HOME="$TMP/outer" run "$OUTER/ai-containers-report.sh" --no-notes
# The tilde here is a grep PATTERN matching the literal "~/web" the report
# prints, not a path being expanded — expanding it is the very thing under test.
# shellcheck disable=SC2088  # literal tilde in a grep pattern, by design
if grep -q '~/web' <<<"$OUT" && ! grep -q "$TMP/outer/web" <<<"$OUT"; then
  pass "\$HOME is abbreviated to ~ by default"
else
  fail "\$HOME is abbreviated to ~ by default
$OUT"
fi
HOME="$TMP/outer" run "$OUTER/ai-containers-report.sh" --no-notes --full-paths
if grep -qF "$TMP/outer/web" <<<"$OUT"; then
  pass "--full-paths turns that off"
else
  fail "--full-paths turns that off
$OUT"
fi

# --path-map rewrites where the script LOOKS, never what it PRINTS. Proven by
# moving the projects somewhere the registry does not mention: without the map
# they read as stale, with it they resolve — and the reported path is the
# registry's either way.
MOVED="$TMP/moved"; mkdir -p "$MOVED"
cp -R "$TMP/outer/web" "$MOVED/web"
MAPBASE="$TMP/mapbase"; mk_base "$MAPBASE"
printf '%s\n' "$TMP/outer/web" > "$MAPBASE/projects.conf.tmp"
cat "$MAPBASE/projects.conf.tmp" >> "$MAPBASE/projects.conf"; rm -f "$MAPBASE/projects.conf.tmp"
rm -rf "$TMP/outer/web"          # the registry path no longer exists
run "$MAPBASE/ai-containers-report.sh" --full-paths
if grep -q 'stale registry entry' <<<"$OUT"; then
  pass "without --path-map an unreachable path reads as stale"
else
  fail "without --path-map an unreachable path reads as stale
$OUT"
fi
run "$MAPBASE/ai-containers-report.sh" --full-paths --path-map "$TMP/outer=$MOVED"
if ! grep -q 'stale registry entry' <<<"$OUT" && grep -qE '^v0\.7\.0-3-gabc1234 +4 +ihudak +web +DISCOVERY' <<<"$OUT"; then
  pass "--path-map redirects where the report LOOKS"
else
  fail "--path-map redirects where the report looks
$OUT"
fi
if grep -qF "$TMP/outer/web" <<<"$OUT" && ! grep -qF "$MOVED/web" <<<"$OUT"; then
  pass "… while still printing the path the registry records"
else
  fail "… while still printing the path the registry records
$OUT"
fi
run "$MAPBASE/ai-containers-report.sh" --path-map
if [[ "$RC" -ne 0 ]] && grep -q 'HOST=LOCAL' <<<"$OUT"; then
  pass "--path-map with no value is refused"
else
  fail "--path-map with no value is refused (rc=$RC)"
fi
run "$MAPBASE/ai-containers-report.sh" --path-map nonsense
if [[ "$RC" -ne 0 ]] && grep -q 'HOST=LOCAL' <<<"$OUT"; then
  pass "--path-map without an '=' is refused"
else
  fail "--path-map without an '=' is refused (rc=$RC)"
fi

# A registry line with a trailing slash names the same project.
SLASHB="$TMP/slashbase"; mk_base "$SLASHB"
mk_proj "$SLASHB" "$TMP/slashproj" default OPEN 1.0
printf '%s\n' "$TMP/slashproj///" > "$SLASHB/projects.conf"
run "$SLASHB/ai-containers-report.sh" --full-paths
if grep -qE '^unknown +unknown +default +slashproj +OPEN' <<<"$OUT" && ! grep -q 'stale registry entry' <<<"$OUT"; then
  pass "a registry path with trailing slashes still resolves"
else
  fail "a registry path with trailing slashes still resolves
$OUT"
fi
# Resolving is not the whole job. `[ -d ]` and `basename` both tolerate trailing
# slashes, so the project appears with its right name either way — what the
# stripping actually decides is the path PRINTED. Without this, the loop that
# does it could be removed entirely and the check above would not notice.
if ! grep -qE 'slashproj/+( |$)' <<<"$OUT"; then
  pass "… and the reported path has them stripped"
else
  fail "… and the reported path has them stripped
$(grep slashproj <<<"$OUT")"
fi

# ── 7b. ordering and the summary line ────────────────────────────────────────
run "$OUTER/ai-containers-report.sh" --full-paths --no-notes "$OUTER" "$NESTED"
if [[ "$(grep -c "^$TMP/outer/base" <<<"$OUT")" -ge 1 ]] \
   && awk -v n="$NESTED" -v o="$OUTER" '
        $1 == o { if (seen_nested) bad = 1; seen_outer = 1 }
        $1 == n { seen_nested = 1 }
        END { exit (bad ? 1 : 0) }' <<<"$OUT"; then
  pass "with several bases the rows stay grouped by base"
else
  fail "with several bases the rows stay grouped by base
$OUT"
fi

run "$OUTER/ai-containers-report.sh" --full-paths
if grep -qE '^[0-9]+ registered project\(s\)' <<<"$OUT" && ! grep -q 'base(s)' <<<"$OUT"; then
  pass "one base: the summary counts projects and does not mention bases"
else
  fail "one base: the summary counts projects and does not mention bases
$(grep -F 'registered project' <<<"$OUT")"
fi
run "$OUTER/ai-containers-report.sh" --full-paths "$OUTER" "$NESTED"
if grep -qE '^2 base\(s\), [0-9]+ registered project\(s\)' <<<"$OUT"; then
  pass "several bases: the summary counts both"
else
  fail "several bases: the summary counts both
$(grep -F 'registered project' <<<"$OUT")"
fi

run "$OUTER/ai-containers-report.sh" --markdown --no-notes
if grep -qE '^\| unknown \| unknown \| default \| api \|.*\| `/' <<<"$OUT"; then
  pass "--markdown backticks the path cell only"
else
  fail "--markdown backticks the path cell only
$(grep '^| default' <<<"$OUT" | head -1)"
fi

# ── 8. refusals ──────────────────────────────────────────────────────────────
BARE="$TMP/bare"
mkdir -p "$BARE"
cp "$SRC" "$ENGINE_DIR/bash-floor.sh" "$BARE/"
run "$BARE/ai-containers-report.sh"
if [[ "$RC" -ne 0 ]] && grep -q 'no projects.conf' <<<"$OUT"; then
  pass "a directory with no projects.conf is refused, by name"
else
  fail "a directory with no projects.conf is refused, by name (rc=$RC)
$OUT"
fi

run "$OUTER/ai-containers-report.sh" --frobnicate
if [[ "$RC" -ne 0 ]] && grep -q 'unknown option' <<<"$OUT"; then
  pass "an unknown option is refused"
else
  fail "an unknown option is refused (rc=$RC)"
fi

# The real file, at a command position, rather than the scratch copy behind
# run(). --help depends on no base, so nothing is lost — and it is what lets
# tests/falsify/derive-targets.sh see that this test EXECUTES the target.
# Behind run() the script is only ever an ARGUMENT, which that walker does not
# follow, and the target would enter the mutation tier claiming no oracle.
OUT="$(bash "$SRC" --help 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]] && grep -q 'Usage:' <<<"$OUT" && grep -q 'BASE_DIR' <<<"$OUT"; then
  pass "--help prints the header, however long it is"
else
  fail "--help prints the header (rc=$RC)"
fi
# The removed flags must not linger in the help text.
if ! grep -qE '\-\-dev-root|\-\-depth' <<<"$OUT"; then
  pass "the removed --dev-root/--depth are gone from the help"
else
  fail "the removed --dev-root/--depth are gone from the help
$OUT"
fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-report.sh: all checks passed\n'; exit 0
fi
printf 'test-report.sh: %s check(s) failed\n' "$fails"
exit 1
