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
  [[ -e "$ENGINE_DIR/$rel" ]] || { fail "the docs name $s, which does not exist in this repo"; missing_scripts=$((missing_scripts+1)); }
done < <(for p in "${PAGES[@]}"; do grep -oE '`\.?/?[a-zA-Z0-9_./-]+\.sh`' "$ENGINE_DIR/$p"; done | tr -d '`' | sort -u)
(( missing_scripts == 0 )) && pass "every repository script named in the documentation exists"

# ── 5. Every documented environment variable is read by something ─────────────
# A variable the docs promise and no script reads is a promise the product does
# not keep — the same defect class as an undocumented key, pointing the other way.
unread=0
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  (cd "$ENGINE_DIR" && git grep -q "$v" -- '*.sh' Dockerfile 2>/dev/null) \
    || { fail "the docs describe \$$v, which no script or Dockerfile reads"; unread=$((unread+1)); }
done < <(grep -ohE '\b(AI_[A-Z0-9_]+|CONTAINER_(CPUS|MEMORY)|REPOS|REPO_BACKEND|VAULT_PATH|SPECS_PATH|DOCS_PATH|EXTRA_MOUNTS|NO_CACHE|PREVIEW_PORTS|IMAGE_NAME|GITHUB_TOKEN|GH_TOKEN)\b' "${PAGES[@]/#/$ENGINE_DIR/}" | sort -u)
(( unread == 0 )) && pass "every environment variable the documentation describes is read by the code"

printf '\n%d failure(s)\n' "$fails"
[[ "$fails" -eq 0 ]]
