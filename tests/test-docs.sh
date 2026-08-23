#!/usr/bin/env bash
# The documentation gate.
#
# The README this replaced grew to 1133 lines and drifted: four real
# sandbox.conf keys (c-toolchain, gradle, pnpm, scala) were wired up, shipped
# and documented in AGENTS.md while the README never mentioned them. Nothing
# checked, so nothing said so.
#
# Splitting the prose does not fix that on its own — it multiplies the places
# drift can hide. So the split ships with this file, and the checks below are
# chosen for what they can catch MECHANICALLY rather than for what reads well:
# a key added to sandbox.conf and not to the docs is a test failure, in both
# directions, by name.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.conf" ]] || ENGINE_DIR="$REPO_DIR/base"
DOCS_DIR="$ENGINE_DIR/docs"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -d "$DOCS_DIR" ]] || { printf 'SCAFFOLD-FAILED: no docs/ under %s\n' "$ENGINE_DIR"; exit 1; }

# Every markdown page the gate reasons about. Tracked files only — a docs/ copy
# left behind by sync-to-projects.sh is not documentation (see test-bash-floor.sh,
# which learned this the hard way).
mapfile -t PAGES < <(cd "$ENGINE_DIR" && git ls-files 'docs/*.md' 'docs/**/*.md' 'README.md' 2>/dev/null | grep -v '^docs/superpowers/')
# When the engine is a subdirectory (mgd-ai-containers: base/), the repository
# ROOT README is a page too — it is what GitHub shows first — and it is outside
# $ENGINE_DIR, so the listing above cannot see it. An unchecked page is exactly
# what this file exists to prevent; its links are relative to the root, so it is
# checked with the root as its directory.
ROOT_PAGES=()
if [[ "$ENGINE_DIR" != "$REPO_DIR" ]] && [[ -f "$REPO_DIR/README.md" ]]; then
  ROOT_PAGES=("README.md")
fi
if [[ "${#PAGES[@]}" -eq 0 ]]; then
  printf 'SCAFFOLD-FAILED: git ls-files listed no documentation pages under %s\n' "$ENGINE_DIR"
  exit 1
fi
# A DERIVATION THAT FOUND ALMOST NOTHING MUST NOT REPORT SUCCESS. Measured while
# writing this file: with the new pages still untracked, `git ls-files` returned
# README.md alone and five of the six checks below passed VACUOUSLY — nothing to
# link, no keys table to compare, no orphans possible. Requiring the index by
# name is the cheapest thing that cannot be satisfied by an empty tree, and
# `git add -N` is what a work-in-progress checkout needs before this gate means
# anything (the same rule the shellcheck sweep already follows).
_have_index=0
for _p in "${PAGES[@]}"; do [[ "$_p" == "docs/README.md" ]] && _have_index=1; done
if [[ "$_have_index" -eq 0 ]]; then
  printf 'SCAFFOLD-FAILED: docs/README.md is not in the tracked set (%d page(s) seen) — every check here would pass without examining the documentation\n' "${#PAGES[@]}"
  exit 1
fi

# ── 1. Every relative link resolves ───────────────────────────────────────────
# Only repo-relative links. http(s) is not ours to verify, a bare #anchor is
# within-page, and an absolute path is a path INSIDE the container (/etc/…),
# not in this repo.
bad_links=0
for page in "${PAGES[@]}"; do
  dir="$(dirname "$ENGINE_DIR/$page")"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in http://*|https://*|mailto:*|/*|'#'*) continue ;; esac
    target="${target%%#*}"                     # drop any anchor
    [[ -n "$target" ]] || continue
    if [[ ! -e "$dir/$target" ]]; then
      fail "$page links to $target, which does not exist"
      bad_links=$((bad_links+1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$ENGINE_DIR/$page" | sed 's/^](//; s/)$//')
done
for page in "${ROOT_PAGES[@]}"; do
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in http://*|https://*|mailto:*|/*|'#'*) continue ;; esac
    target="${target%%#*}"
    [[ -n "$target" ]] || continue
    if [[ ! -e "$REPO_DIR/$target" ]]; then
      fail "$page (repository root) links to $target, which does not exist"
      bad_links=$((bad_links+1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$REPO_DIR/$page" | sed 's/^](//; s/)$//')
done
(( bad_links == 0 )) && pass "every relative link in the documentation resolves"

# ── 1b. Every ANCHOR resolves, in whichever file it points at ─────────────────
# Splitting one file into twenty MULTIPLIES this failure: every `(#heading)` that
# used to resolve within the old README now has to name the page the heading
# moved to. Fifteen of them did, and a plain file-existence check cannot see it —
# a bare `#anchor` names no file at all.
anchor_of() {  # heading text -> GitHub's anchor form
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9 _-]//g; s/ /-/g'
}
bad_anchors=0
for page in "${PAGES[@]}"; do
  dir="$(dirname "$ENGINE_DIR/$page")"
  while IFS= read -r target; do
    case "$target" in http://*|https://*|mailto:*|/*|'') continue ;; esac
    case "$target" in *'#'*) : ;; *) continue ;; esac
    file="${target%%#*}"; anchor="${target#*#}"
    [[ -n "$anchor" ]] || continue
    if [[ -z "$file" ]]; then target_file="$ENGINE_DIR/$page"; else target_file="$dir/$file"; fi
    [[ -f "$target_file" ]] || continue          # check 1 already reports a missing file
    found=0
    while IFS= read -r h; do
      h="${h#"${h%%[![:space:]#]*}"}"            # strip leading #s and spaces
      [[ "$(anchor_of "$h")" == "$anchor" ]] && { found=1; break; }
    done < <(grep -E '^#{1,6} ' "$target_file" | sed 's/^#\{1,6\} //')
    if (( ! found )); then
      fail "$page links to #$anchor in ${file:-itself}, and no heading there produces that anchor"
      bad_anchors=$((bad_anchors+1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$ENGINE_DIR/$page" | sed 's/^](//; s/)$//')
done
(( bad_anchors == 0 )) && pass "every anchor link resolves to a real heading"

# ── 2. No orphan pages ────────────────────────────────────────────────────────
# A page nothing links to is a page nobody finds. Reachability is transitive:
# the component pages hang off docs/components/README.md, which hangs off the
# index.
declare -A LINKED=()
for page in "${PAGES[@]}"; do
  dir="$(dirname "$page")"; [[ "$dir" == "." ]] && dir=""
  while IFS= read -r target; do
    case "$target" in http://*|https://*|mailto:*|/*|'#'*|'') continue ;; esac
    target="${target%%#*}"
    [[ -n "$target" ]] || continue
    norm="$(cd "$ENGINE_DIR/${dir:-.}" 2>/dev/null && realpath -m --relative-to="$ENGINE_DIR" "$target" 2>/dev/null)"
    [[ -n "$norm" ]] && LINKED["$norm"]=1
  done < <(grep -oE '\]\([^)]+\)' "$ENGINE_DIR/$page" | sed 's/^](//; s/)$//')
done
orphans=0
for page in "${PAGES[@]}"; do
  [[ "$page" == "README.md" || "$page" == "docs/README.md" ]] && continue
  [[ -n "${LINKED[$page]:-}" ]] || { fail "$page is not linked from any other page — nobody will find it"; orphans=$((orphans+1)); }
done
(( orphans == 0 )) && pass "every documentation page is reachable by a link"

# ── 3. sandbox.conf keys and the docs agree, IN BOTH DIRECTIONS ───────────────
# This is the check the old README would have failed. One direction catches a
# new key nobody documented; the other catches a key that was renamed or
# removed while its documentation stayed behind.
keys_real="$(grep -oE '^[a-zA-Z0-9_-]+=' "$ENGINE_DIR/sandbox.conf" | sed 's/=$//' | sort -u)"
keys_doc="$(grep -ohE '^\| `[a-zA-Z0-9_-]+`' "$DOCS_DIR"/components/README.md | tr -d '|` ' | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$keys_real") <(printf '%s\n' "$keys_doc"))"
stale="$(comm -13 <(printf '%s\n' "$keys_real") <(printf '%s\n' "$keys_doc"))"
if [[ -z "$missing" ]]; then
  pass "every sandbox.conf key is documented"
else
  while IFS= read -r k; do fail "sandbox.conf key '$k' is not documented in docs/components/README.md"; done <<< "$missing"
fi
if [[ -z "$stale" ]]; then
  pass "every documented key still exists in sandbox.conf"
else
  while IFS= read -r k; do fail "docs document key '$k', which sandbox.conf no longer has"; done <<< "$stale"
fi

# ── 4. Every repo script the docs name exists ─────────────────────────────────
# Deliberately narrow: `./name.sh` or `path/name.sh` as the docs write them.
# runme.sh is GENERATED into a consumer project by project-init.sh and is
# correctly absent here; /etc/... is a path inside the container.
# `.sh` is also a ccTLD, so a backticked token cannot be told apart from a
# script by SHAPE — `vale.sh` is the Vale project's website and is allowlisted
# as a domain. Anything the documentation also writes with a scheme is a host,
# not a script, and that is checkable rather than guessed.
domains="$(for p in "${PAGES[@]}"; do grep -ohE '://[a-zA-Z0-9_.-]+\.sh' "$ENGINE_DIR/$p"; done | sed 's#^://##' | sort -u)"
missing_scripts=0
while IFS= read -r s; do
  case "$s" in /*|*runme.sh|*://*) continue ;; esac
  # A here-string, not a pipeline: `producer | grep -q` lets grep exit on the
  # first match and SIGPIPE the producer, which under `set -o pipefail` is a
  # non-zero status nobody asked for (tests/test-grep-q-pipelines.sh, backlog
  # F34 — and it caught this line).
  grep -qx -- "${s#./}" <<<"$domains" && continue
  rel="${s#./}"
  # Resolve against the ENGINE dir and the REPO root. They are the same upstream,
  # but in mgd-ai-containers the engine is base/ while migrations/ and the
  # sandbox-version scripts live at the root — so a base/docs/ page naming
  # `migrations/005-drop-rails.sh` is correct, and checking only ENGINE_DIR
  # reported a file that is right there.
  [[ -e "$ENGINE_DIR/$rel" || -e "$REPO_DIR/$rel" ]] \
    || { fail "the docs name $s, which does not exist in this repo"; missing_scripts=$((missing_scripts+1)); }
done < <(for p in "${PAGES[@]}"; do grep -oE '`\.?/?[a-zA-Z0-9_./-]+\.sh`' "$ENGINE_DIR/$p"; done | tr -d '`' | sort -u)
(( missing_scripts == 0 )) && pass "every repository script named in the documentation exists"

# ── 5. Every documented environment variable is read by something ─────────────
# A variable the docs promise and no script reads is a promise the product does
# not keep — the same defect class as an undocumented key, pointing the other way.
unread=0
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  # EXCLUDE THIS FILE. It lists every variable name below, so while it sits
  # inside $ENGINE_DIR it satisfies its own check — measured: upstream passed
  # for $GH_TOKEN, which nothing reads, purely because this file mentions it.
  # mgd-ai-containers put tests/ outside base/ and failed honestly, which is how
  # it was found. A check that can be satisfied by the checker is not a check.
  (cd "$ENGINE_DIR" && git grep -q "$v" -- '*.sh' Dockerfile ':!tests/test-docs.sh' 2>/dev/null) \
    || { fail "the docs describe \$$v, which no script or Dockerfile reads"; unread=$((unread+1)); }
done < <(grep -ohE '\b(AI_[A-Z0-9_]+|CONTAINER_(CPUS|MEMORY)|REPOS|REPO_BACKEND|VAULT_PATH|SPECS_PATH|DOCS_PATH|EXTRA_MOUNTS|NO_CACHE|PREVIEW_PORTS|IMAGE_NAME|GITHUB_TOKEN)\b' "${PAGES[@]/#/$ENGINE_DIR/}" | sort -u)
(( unread == 0 )) && pass "every environment variable the documentation describes is read by the code"

# ── every backlog entry's LATEST heading carries a status ────────────────────
# The falsify backlog is this project's memory, and a heading that states no
# status sends work in the wrong direction. On 2026-08-22 that happened three
# times in one day: the Host Agent listed F57 as remaining when its addendum had
# closed it and declined the follow-up increment; this suite's own reader nearly
# began that increment; and F4 and F1 were reported as open work HOURS AFTER a
# pass that was supposed to have fixed exactly this — because that pass grepped
# for keywords and their resolution headings read "covered, and the coverage
# found a defect" and "slice 4", which are true, informative, and unactionable.
#
# So it is mechanical now. The token is BOLD and immediately after `**`, not a
# bare word: F2 and F7 are titled "…open modes are never executed hermetically"
# and "…named and tagged for open mode", and a bare-word match reads both as
# open when both are FIXED.
#
# Upstream-only — the mgd port carries no copy of this file, and skipping is
# correct there rather than a gap.
BACKLOG="$ENGINE_DIR/docs/superpowers/specs/2026-08-14-falsify-backlog.md"
if [[ ! -f "$BACKLOG" ]]; then
  # SAID OUT LOUD, not skipped in silence. In the mgd port the backlog genuinely
  # does not exist and skipping is correct — but a check that vanishes without a
  # word is indistinguishable from one that vanished because somebody renamed
  # the file, and this whole assertion exists because a status nobody can see is
  # a status nobody acts on.
  printf 'SKIP: no falsify backlog at %s — the heading-status rule has nothing to check here\n' \
    "${BACKLOG#"$ENGINE_DIR/"}"
else
  # Parsed in the shell, not with awk's \\< word boundaries: mawk does not
  # support them, and the first version of this check used them and therefore
  # MATCHED NOTHING — a guard that passed on every input, written the same hour
  # as a fix for exactly that. The heading format does the boundary work
  # instead: ids live before the em dash, as "## F30/F32 — …".
  declare -A bl_status=()
  declare -A bl_text=()
  while IFS= read -r bl_line; do
    for bl_id in $(printf '%s' "${bl_line%%—*}" | grep -oE 'F[0-9]+' || true); do
      # An entry may appear many times; the LAST heading is the current one.
      # UPPERCASE, and bounded by non-letters. Case is the whole discriminator:
      # F2 and F7 are titled "…open modes are never executed hermetically" and
      # "…tagged for open mode", and a case-insensitive match reads both as open
      # when both are FIXED. Requiring the token to be BOLD was the first
      # attempt and was wrong in the other direction — it flagged seven headings
      # that say `— FIXED 2026-08-21.` or `(FIXED)`, which are perfectly clear.
      # No \b: BSD grep does not define it, and this suite runs on macOS.
      # A here-string, not `printf | grep -q`: that pipeline is what
      # tests/test-grep-q-pipelines.sh forbids, and it caught this file doing it
      # twice in one session.
      if grep -qE '(^|[^A-Za-z])(FIXED|RESOLVED|CLOSED|DECLINED|ACCEPTED|OPEN)([^A-Za-z]|$)' <<<"$bl_line"; then
        bl_status["$bl_id"]=1
      else
        bl_status["$bl_id"]=0
      fi
      bl_text["$bl_id"]="$bl_line"
    done
  done < <(grep '^## ' "$BACKLOG")

  # The count, because a parser that finds nothing would otherwise report a
  # clean file. This is the lesson of the empty-corpus lints, applied here.
  if (( ${#bl_status[@]} >= 30 )); then
    pass "the backlog parser found ${#bl_status[@]} entries to check"
  else
    fail "the backlog parser found only ${#bl_status[@]} entries — it is not reading the file"
  fi

  statusless=""
  for bl_id in "${!bl_status[@]}"; do
    (( bl_status["$bl_id"] )) || statusless="${statusless}${bl_id}: ${bl_text[$bl_id]}"$'\n'
  done
  statusless="$(printf '%s' "$statusless" | LC_ALL=C sort)"
  if [[ -z "$statusless" ]]; then
    pass "every falsify-backlog entry's latest heading carries a status"
  else
    fail "every falsify-backlog entry's latest heading carries a status"
    printf '%s\n' "$statusless" | sed 's/^/     /' | head -10
  fi
fi

# ── every spec says where it stands ──────────────────────────────────────────
# A spec with no status is read as live work. F4 and F1 were reported as
# remaining twice on 2026-08-22 for exactly that reason, hours apart, after a
# pass that was supposed to have fixed it — their headings were true,
# informative and carried nothing actionable.
#
# WHAT THIS CANNOT DO, said plainly so nobody mistakes it for more: it checks
# that a status is PRESENT, never that it is TRUE. The auto-update regression
# spec carried `**Status:** OPEN` for a full day after the work shipped and was
# verified three times in a container — this check would have passed it happily.
# Staleness is a review obligation; absence is the part a machine can hold.
SPECS="$ENGINE_DIR/docs/superpowers/specs"
if [[ ! -d "$SPECS" ]]; then
  printf 'SKIP: no docs/superpowers/specs under %s — nothing to check\n' "${SPECS#"$ENGINE_DIR/"}"
else
  statusless=""; n_specs=0
  while IFS= read -r sp; do
    n_specs=$((n_specs + 1))
    # First 15 lines: a status below the fold is one nobody reads either.
    # A here-string, not `head | grep -q` — that pipeline is what
    # tests/test-grep-q-pipelines.sh forbids, and it has now caught this file
    # doing it three times in one day.
    grep -qiE '^\*\*Status:\*\*' <<<"$(head -15 "$sp")" \
      || statusless="${statusless}${statusless:+ }$(basename "$sp")"
  done < <(find "$SPECS" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
  # The count, for the same reason the backlog parser has one: a find that
  # matches nothing would otherwise report a clean sweep.
  if (( n_specs >= 10 )); then
    pass "the spec scan found $n_specs documents to check"
  else
    fail "the spec scan found only $n_specs documents — it is not reading the directory"
  fi
  if [[ -z "$statusless" ]]; then
    pass "every spec states its status in its first 15 lines"
  else
    fail "every spec states its status in its first 15 lines — missing: $statusless"
  fi
fi

printf '\n%d failure(s)\n' "$fails"
[[ "$fails" -eq 0 ]]
