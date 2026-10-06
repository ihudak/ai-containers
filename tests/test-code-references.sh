#!/usr/bin/env bash
# tests/test-code-references.sh — comments cite code by what it SAYS, not by
# the line it happens to sit on.
#
# Line numbers were the convention, and they rot on every edit above them, which
# is the common edit. Measured 2026-10-02: 21 of the ~55 numbered references
# under tests/ pointed at the wrong line (ai-containers #260). Not one was blank,
# so the guard that existed — test-docs.sh's, which flagged a reference only when
# it landed on a blank line or past the end of its file — caught none of them.
# A guard that instead checked each numbered line's CONTENT would fire on every
# edit above every reference, and a gate that cries wolf that often is the one
# people learn to step around.
#
# Numbers also cannot be right in two repositories at once. Several of these
# files are byte-identical in mgd-ai-containers while the files they cite are
# not, so the same reference was correct in one repo and wrong in the other.
# A snippet reads the same in both.
#
# THE FORM. A citation is a file, a colon, a space and a backticked snippet,
# all on one line:
#
#     <file>: `<snippet>`
#
# The snippet is a function name written as `name()`, or a short literal copied
# from the line meant. It goes stale only when that code is renamed or removed —
# exactly when the sentence around it needs reading again.
#
# THE RULES, each checked over every tracked *.sh, *.yml, *.md, *.patch and
# Dockerfile:
#   1. a citation's snippet occurs, verbatim, in the file it names;
#   2. no <file>:<line> reference to a TRACKED file — unless the line carries
#      `ref-lint: allow: <reason>`, reason required, for a number that something
#      else already pins by content (the integration shim's own test is the case
#      in point). A reference to an UNTRACKED file is skipped: a fixture this
#      suite writes at run time, or nvm's own source, is not this repo's code;
#   3. a citation split across lines — the snippet wrapping onto the next one,
#      or the line breaking right after `<file>:` with the snippet opening the
#      next — is refused, because this guard reads one line at a time and
#      would otherwise never check it. A sentence that merely ends in a file
#      name and a colon, and carries on in words, is prose and is left alone.
#
# RESOLVING <file>. A path with a slash matches a tracked path exactly or as a
# suffix, so the same text resolves under mgd-ai-containers' base/. A bare name
# is tried beside the citing file first, then as a basename anywhere in the
# repo. Two candidates is a failure, not a guess: a reference a reader cannot
# follow to one file is not a reference.
#
# NOT SCANNED: CHANGELOG.md, docs/superpowers/ and specs/ (dated records of what
# was true when written, which is what a number in them means), the falsify
# ledger's own data files (*.txt, *.conf, the same reason), and symlinks
# (.github/copilot-instructions.md and its sibling are AGENTS.md, checked once).
#
# WHAT IT CANNOT CATCH, stated so nobody overestimates it: a snippet that still
# occurs but now means something else — this proves the cited text exists, not
# that the sentence around it is still true — and a number written as prose
# ("line 24"), which no pattern here recognises.
set -uo pipefail
export LC_ALL=C   # the character classes below are byte ranges, not a locale's idea of a letter

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# A path as these comments write one: optional directories, then a name with a
# scoped extension, or a Dockerfile. REF_EDGE is what may sit just before a path
# without being part of it, so `x/tests/run.sh` is never read as `run.sh`.
REF_FILE='([A-Za-z0-9._-]+/)*([A-Za-z0-9_][A-Za-z0-9._-]*\.(sh|yml|md|patch)|Dockerfile(\.seed)?)'
REF_EDGE='(^|[^A-Za-z0-9._/-])'
REF_ALLOW='ref-lint: allow: *[^[:space:]]'

# _ref_resolve <citing file> <cited path> — sets REF_TO and REF_N (candidates).
# Reads `tracked` and `by_base` from ref_check's scope (bash locals are dynamic).
_ref_resolve() {
  local from="$1" p="${2#./}" d c
  REF_TO=""; REF_N=0
  if [[ "$p" == */* ]]; then
    for c in "${!tracked[@]}"; do
      if [[ "$c" == "$p" || "$c" == */"$p" ]]; then REF_TO="$c"; REF_N=$((REF_N + 1)); fi
    done
    return 0
  fi
  d="${from%/*}"; [[ "$d" == "$from" ]] && d=""
  if [[ -n "${tracked[${d:+$d/}$p]:-}" ]]; then REF_TO="${d:+$d/}$p"; REF_N=1; return 0; fi
  while IFS= read -r c; do
    [[ -n "$c" ]] && { REF_TO="$c"; REF_N=$((REF_N + 1)); }
  done <<< "${by_base[$p]:-}"
  return 0
}

# ref_check <git work tree> — prints "PROBLEM <file>:<line>: <message>" per
# problem, then "COUNTS <files scanned> <citations checked> <numbers allowed>".
ref_check() {
  local root="$1" rec meta path b f ln line rest m p snip num
  local -A tracked=() by_base=()
  local -a scope=()
  local n_cite=0 n_allow=0
  while IFS= read -r -d '' rec; do        # "<mode> <sha> <stage>\t<path>"
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    tracked["$path"]=1
    b="${path##*/}"; by_base["$b"]+="$path"$'\n'
    [[ "${meta%% *}" == 120000 ]] && continue
    case "$path" in
      CHANGELOG.md|*/CHANGELOG.md|docs/superpowers/*|*/docs/superpowers/*|specs/*) continue ;;
      *.sh|*.yml|*.md|*.patch|Dockerfile|Dockerfile.seed|*/Dockerfile|*/Dockerfile.seed) scope+=("$path") ;;
    esac
  done < <(git -C "$root" ls-files -s -z)

  local cite_re="${REF_EDGE}(${REF_FILE}): \`([^\`]+)\`"
  local num_re="${REF_EDGE}(${REF_FILE}):([0-9]+)"
  local wrap_re="${REF_EDGE}(${REF_FILE}): \`[^\`]*\$"
  local split_re="${REF_EDGE}(${REF_FILE}):[[:space:]]*\$"
  while IFS= read -r rec; do
    f="${rec%%:*}"; rest="${rec#*:}"; ln="${rest%%:*}"; line="${rest#*:}"
    if [[ "$line" =~ $REF_ALLOW ]]; then
      n_allow=$((n_allow + 1)); continue
    fi
    rest="$line"
    while [[ "$rest" =~ $cite_re ]]; do
      m="${BASH_REMATCH[0]}"; p="${BASH_REMATCH[2]}"; snip="${BASH_REMATCH[7]}"
      rest="${rest#*"$m"}"
      n_cite=$((n_cite + 1))
      _ref_resolve "$f" "$p"
      if (( REF_N == 0 )); then
        printf 'PROBLEM %s:%s: cites %s, which is not a tracked file\n' "$f" "$ln" "$p"
      elif (( REF_N > 1 )); then
        printf 'PROBLEM %s:%s: %s matches %d tracked files — write its path\n' "$f" "$ln" "$p" "$REF_N"
      elif ! grep -qF -- "$snip" "$root/$REF_TO"; then
        printf 'PROBLEM %s:%s: `%s` does not occur in %s\n' "$f" "$ln" "$snip" "$REF_TO"
      fi
    done
    rest="$line"
    while [[ "$rest" =~ $num_re ]]; do
      m="${BASH_REMATCH[0]}"; p="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[7]}"
      rest="${rest#*"$m"}"
      _ref_resolve "$f" "$p"
      (( REF_N == 0 )) && continue
      printf 'PROBLEM %s:%s: cites %s by line number (%s) — cite a snippet from it instead\n' "$f" "$ln" "$p" "$num"
    done
    if [[ "$line" =~ $wrap_re ]]; then
      printf 'PROBLEM %s:%s: a citation of %s wraps onto the next line — keep the snippet on one line\n' "$f" "$ln" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ $split_re ]]; then
      p="${BASH_REMATCH[2]}"
      # Only when the snippet opens the NEXT line; anything else is prose.
      if [[ "$(sed -n "$((ln + 1))p" "$root/$f")" =~ ^[[:space:]]*(#[[:space:]]*)?\` ]]; then
        printf 'PROBLEM %s:%s: a citation of %s breaks after its colon — keep the file and its snippet on one line\n' "$f" "$ln" "$p"
      fi
    fi
  done < <(cd "$root" && (( ${#scope[@]} )) && grep -HnE "${REF_FILE}:([0-9]| \`|[[:space:]]*\$)" -- "${scope[@]}")
  printf 'COUNTS %d %d %d\n' "${#scope[@]}" "$n_cite" "$n_allow"
}

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Confined to the owning process (F30/F32/F64; tests/test-exit-trap-ownership.sh).
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# ── the guard can fail: one fixture tree, every rule broken once ──────────────
# Built with printf from separated pieces, so THIS file's source never contains
# the shapes it scans for — otherwise the real-tree run below would trip over
# the fixture text instead of checking the repo.
fx="$TMP/fx"
mkdir -p "$fx/a" "$fx/b" || { printf 'SCAFFOLD-FAILED: fixture dirs\n'; exit 1; }
BT='`'
printf '#!/bin/sh\nfoo_bar() {\n  :\n}\n' > "$fx/target.sh"
printf 'y\n' > "$fx/a/x.sh"
printf 'y\n' > "$fx/b/x.sh"
{
  printf '# good: %s: %sfoo_bar()%s\n'          target.sh "$BT" "$BT"   # 1 ok
  printf '# stale: %s: %sno_such_thing%s\n'     target.sh "$BT" "$BT"   # 2 PROBLEM
  printf '# numbered: %s:%s\n'                  target.sh 3             # 3 PROBLEM
  printf '# pinned: %s:%s  # %s: %s pinned\n'   target.sh 3 ref-lint 'allow:'  # 4 ok, allowed
  printf '# no reason: %s:%s  # %s: %s\n'       target.sh 3 ref-lint 'allow:'  # 5 PROBLEM
  printf '# external: %s:%s\n'                  ghost.sh 9              # 6 ok, untracked
  printf '# wrapped: %s: %sfoo_bar\n'           target.sh "$BT"         # 7 PROBLEM
  printf '# ambiguous: %s: %sy%s\n'             x.sh "$BT" "$BT"        # 8 PROBLEM
  printf '# missing: %s: %sz%s\n'               ghost.sh "$BT" "$BT"    # 9 PROBLEM
  printf '# by path: %s: %sy%s\n'               a/x.sh "$BT" "$BT"      # 10 ok
  printf '# split: %s:\n'                       target.sh               # 11 PROBLEM
  printf '# %sfoo_bar()%s\n'                    "$BT" "$BT"             # 12 ok, prose
  printf '# a sentence ending in %s:\n'         target.sh               # 13 ok, prose
  printf '# and carrying on in words\n'                                # 14 ok
} > "$fx/cite.sh"
printf '# beside me: %s: %sy%s\n' x.sh "$BT" "$BT" > "$fx/a/near.sh"    # ok: a/x.sh is beside it
printf '# history: %s:%s\n' target.sh 3 > "$fx/CHANGELOG.md"            # ok: not scanned
printf '# data: %s:%s\n' target.sh 3 > "$fx/ledger.txt"                 # ok: not scanned
ln -s cite.sh "$fx/alias.sh"                                            # ok: a symlink, scanned once
if ! git -C "$fx" init -q 2>/dev/null || ! git -C "$fx" add -A 2>/dev/null; then
  printf 'SCAFFOLD-FAILED: could not make the fixture a git work tree\n'; exit 1
fi

fx_out="$(ref_check "$fx")"
got="$(grep '^PROBLEM ' <<< "$fx_out" | sed -E 's/^PROBLEM ([^:]+:[0-9]+):.*/\1/' | sort)"
want="$(printf 'cite.sh:%s\n' 2 3 5 7 8 9 11 | sort)"
if [[ "$got" == "$want" ]]; then
  pass "the guard reports exactly the seven broken fixture lines (stale, numbered, reasonless allow, wrapped, ambiguous, missing file, split after the colon)"
else
  fail "the guard reports exactly the seven broken fixture lines"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/     /'
  grep '^PROBLEM ' <<< "$fx_out" | sed 's/^/     /'
fi
read -r _ fx_files _ fx_allow <<< "$(grep '^COUNTS ' <<< "$fx_out")"
if [[ "${fx_allow:-}" == 1 ]]; then
  pass "a numbered reference with a reasoned ref-lint marker is allowed, and counted"
else
  fail "a numbered reference with a reasoned ref-lint marker is allowed, and counted (counted ${fx_allow:-none})"
fi
if [[ "${fx_files:-}" == 5 ]]; then
  pass "scope is the five fixture scripts — CHANGELOG.md, the .txt and the symlink are not scanned"
else
  fail "scope is the five fixture scripts — CHANGELOG.md, the .txt and the symlink are not scanned (scanned ${fx_files:-none})"
fi

# ── the real tree ─────────────────────────────────────────────────────────────
GIT_ROOT="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || { printf 'SCAFFOLD-FAILED: %s is not a git work tree\n' "$REPO_DIR"; exit 1; }
out="$(ref_check "$GIT_ROOT")"
problems="$(grep '^PROBLEM ' <<< "$out" | sed 's/^PROBLEM //')"
read -r _ n_files n_cites n_allow <<< "$(grep '^COUNTS ' <<< "$out")"
if [[ -n "$problems" ]]; then
  while IFS= read -r p; do fail "$p"; done <<< "$problems"
fi
# A guard that inspected nothing must not report success: a scope glob that
# stops matching, or a tree with no citations at all, would be a green no-op.
if (( ${n_files:-0} > 0 && ${n_cites:-0} > 0 )); then
  [[ -z "$problems" ]] && pass "every code reference resolves: $n_cites citation(s) found in their files, no numbered reference without a reason ($n_allow allowed), across $n_files file(s)"
else
  fail "the scan checked ${n_cites:-0} citation(s) across ${n_files:-0} file(s) — nothing was verified"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
