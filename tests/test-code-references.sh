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
# Two other spellings are in use and are checked as well (feature-gaps review
# GAP-25): file and snippet inside one pair of backticks, and the file
# backticked on its own before a backticked snippet. In those two, a path that is
# no tracked file is prose (a quoted message that starts with a file name), and
# is left alone.
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
#      next, in any of the three spellings — is refused, because this guard
#      reads one line at a time and would otherwise never check it. A sentence that merely ends in a file
#      name and a colon, and carries on in words, is prose and is left alone.
#
# RESOLVING <file>. A path with a slash matches a tracked path exactly or as a
# suffix, so the same text resolves under mgd-ai-containers' base/. A bare name
# is tried beside the citing file first, then as a basename anywhere in the
# repo. Two candidates is a failure, not a guess: a reference a reader cannot
# follow to one file is not a reference.
#
# NOT SCANNED: CHANGELOG.md, docs/superpowers/ and specs/ (dated records of what
# was true when written, which is what a number in them means), the two other
# spellings in docs/reviews/ (a review log quotes in them the code it found
# wrong, which its fix removes; the form above is checked there), the falsify
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

# _ref_cite <citing file> <line> <cited path> <snippet> [strict]: one citation
# checked, its PROBLEM printed. rc 1 when the path resolves to no tracked file
# and the citation was not strict: then it is prose, and not counted.
_ref_cite() {
  _ref_resolve "$1" "$3"
  if (( REF_N == 0 )); then
    [[ -n "${5:-}" ]] || return 1
    printf 'PROBLEM %s:%s: cites %s, which is not a tracked file\n' "$1" "$2" "$3"
  elif (( REF_N > 1 )); then
    printf 'PROBLEM %s:%s: %s matches %d tracked files — write its path\n' "$1" "$2" "$3" "$REF_N"
  elif ! grep -qF -- "$4" "$root/$REF_TO"; then
    printf 'PROBLEM %s:%s: `%s` does not occur in %s\n' "$1" "$2" "$4" "$REF_TO"
  fi
  return 0
}

# ref_check <git work tree> — prints "PROBLEM <file>:<line>: <message>" per
# problem, then "COUNTS <files scanned> <citations checked> <numbers allowed>".
ref_check() {
  local root="$1" rec meta path b f ln line rest m p snip num re
  local -A tracked=() by_base=() dated=()
  local -a scope=()
  local n_cite=0 n_allow=0
  while IFS= read -r -d '' rec; do        # "<mode> <sha> <stage>\t<path>"
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    tracked["$path"]=1
    b="${path##*/}"; by_base["$b"]+="$path"$'\n'
    [[ "${meta%% *}" == 120000 ]] && continue
    case "$path" in
      # Dated records, which cite code as it stood when they were written.
      CHANGELOG.md|*/CHANGELOG.md|docs/superpowers/*|*/docs/superpowers/*|specs/*) continue ;;
      # A review log is checked for the form above, as it was before GAP-25,
      # but not for the two other spellings, in which its entries quote the code
      # they found wrong, which their fixes remove (review of the GAP-25 fix).
      docs/reviews/*.md|*/docs/reviews/*.md) dated["$path"]=1; scope+=("$path") ;;
      *.sh|*.yml|*.md|*.patch|Dockerfile|Dockerfile.seed|*/Dockerfile|*/Dockerfile.seed) scope+=("$path") ;;
    esac
  done < <(git -C "$root" ls-files -s -z)

  local cite_re="${REF_EDGE}(${REF_FILE}): \`([^\`]+)\`"
  # The two other spellings in use (feature-gaps review GAP-25): file and
  # snippet inside one pair of backticks, and the file backticked on its own.
  local cite_in_re="\`(${REF_FILE}): ([^\`]+)\`"
  local cite_bt_re="\`(${REF_FILE})\`: \`([^\`]+)\`"
  local num_re="${REF_EDGE}(${REF_FILE}):([0-9]+)"
  local wrap_re="${REF_EDGE}(${REF_FILE}): \`[^\`]*\$"
  local split_re="${REF_EDGE}(${REF_FILE}):[[:space:]]*\$"
  # The other two spellings cut short: a backtick opened on a path and a colon
  # and not closed on that line; a backticked path whose snippet's backtick is
  # not closed, or opens the next line.
  local open_in_re="\`(${REF_FILE}):([[:space:]][^\`]*)?\$"
  local wrap_bt_re="\`(${REF_FILE})\`: \`[^\`]*\$"
  local split_bt_re="\`(${REF_FILE})\`:[[:space:]]*\$"
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
      _ref_cite "$f" "$ln" "$p" "$snip" strict
    done
    # The other two spellings: a path that is no tracked file there is prose
    # (a message quoted with its file name), as for numbered references.
    [[ -z "${dated[$f]:-}" ]] && for re in "$cite_in_re" "$cite_bt_re"; do
      rest="$line"
      while [[ "$rest" =~ $re ]]; do
        m="${BASH_REMATCH[0]}"; p="${BASH_REMATCH[1]}"; snip="${BASH_REMATCH[6]}"
        rest="${rest#*"$m"}"
        _ref_cite "$f" "$ln" "$p" "$snip" && n_cite=$((n_cite + 1))
      done
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
      # Only when the snippet opens the NEXT line, with one backtick; anything
      # else is prose, a Markdown code fence (three) among it.
      if [[ "$(sed -n "$((ln + 1))p" "$root/$f")" =~ ^[[:space:]]*(#[[:space:]]*)?\`[^\`] ]]; then
        printf 'PROBLEM %s:%s: a citation of %s breaks after its colon — keep the file and its snippet on one line\n' "$f" "$ln" "$p"
      fi
    fi
    # The other two spellings, cut short the same ways (review of the GAP-25
    # fix); one whose path is no tracked file is prose.
    if [[ -z "${dated[$f]:-}" ]]; then
      p=""
      if [[ "$line" =~ $open_in_re || "$line" =~ $wrap_bt_re ]]; then
        p="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ $split_bt_re ]]; then
        p="${BASH_REMATCH[1]}"
        # Only when the snippet opens the NEXT line, with one backtick; a fence is prose.
        [[ "$(sed -n "$((ln + 1))p" "$root/$f")" =~ ^[[:space:]]*(#[[:space:]]*)?\`[^\`] ]] || p=""
      fi
      if [[ -n "$p" ]]; then
        _ref_resolve "$f" "$p"
        (( REF_N == 0 )) || printf 'PROBLEM %s:%s: a citation of %s is cut at the end of the line — keep the file and its snippet on one line\n' "$f" "$ln" "$p"
      fi
    fi
  done < <(cd "$root" && (( ${#scope[@]} )) && grep -HnE "${REF_FILE}:([0-9]| \`|[[:space:]]*\$)|\`${REF_FILE}(: |\`: \`|\`:[[:space:]]*\$)" -- "${scope[@]}")
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
  printf '# inside: %s%s: foo_bar()%s\n'        "$BT" target.sh "$BT"   # 15 ok
  printf '# inside, stale: %s%s: no_such()%s\n' "$BT" target.sh "$BT"  # 16 PROBLEM
  printf '# apart: %s%s%s: %sfoo_bar()%s\n'      "$BT" target.sh "$BT" "$BT" "$BT"  # 17 ok
  printf '# apart, stale: %s%s%s: %sgone()%s\n'  "$BT" target.sh "$BT" "$BT" "$BT"  # 18 PROBLEM
  printf '# quoted message: %s%s: line 3: oops%s\n' "$BT" ghost.sh "$BT"          # 19 ok, prose
  printf '# inside, wrapped: %s%s: foo_bar\n'   "$BT" target.sh         # 20 PROBLEM
  printf '# apart, wrapped: %s%s%s: %sfoo_bar\n' "$BT" target.sh "$BT" "$BT"      # 21 PROBLEM
  printf '# apart, split: %s%s%s:\n'            "$BT" target.sh "$BT"   # 22 PROBLEM
  printf '# %sfoo_bar()%s\n'                    "$BT" "$BT"             # 23 ok, prose
  printf '# open message: %s%s: no closing\n'   "$BT" ghost.sh          # 24 ok, prose
  printf '# a fence after %s:\n'                target.sh               # 25 ok: a fence is no snippet
  printf '# %s%s%sbash\n'                       "$BT" "$BT" "$BT"       # 26 ok
  printf '# and after %s%s%s:\n'                "$BT" target.sh "$BT"   # 27 ok: the same, backticked
  printf '# %s%s%s\n'                           "$BT" "$BT" "$BT"       # 28 ok
} > "$fx/cite.sh"
mkdir -p "$fx/docs/reviews" || { printf 'SCAFFOLD-FAILED: fixture dirs\n'; exit 1; }
{
  printf '# a log: %s%s: gone_in_a_log()%s\n'   "$BT" target.sh "$BT"   # 1 ok: a log quotes code its fix removed
  printf '# a log: %s: %sgone_too()%s\n'        target.sh "$BT" "$BT"   # 2 PROBLEM: the form is checked in logs
} > "$fx/docs/reviews/log.md"
printf '# beside me: %s: %sy%s\n' x.sh "$BT" "$BT" > "$fx/a/near.sh"    # ok: a/x.sh is beside it
printf '# history: %s:%s\n' target.sh 3 > "$fx/CHANGELOG.md"            # ok: not scanned
printf '# data: %s:%s\n' target.sh 3 > "$fx/ledger.txt"                 # ok: not scanned
ln -s cite.sh "$fx/alias.sh"                                            # ok: a symlink, scanned once
if ! git -C "$fx" init -q 2>/dev/null || ! git -C "$fx" add -A 2>/dev/null; then
  printf 'SCAFFOLD-FAILED: could not make the fixture a git work tree\n'; exit 1
fi

fx_out="$(ref_check "$fx")"
got="$(grep '^PROBLEM ' <<< "$fx_out" | sed -E 's/^PROBLEM ([^:]+:[0-9]+):.*/\1/' | sort)"
want="$( { printf 'cite.sh:%s\n' 2 3 5 7 8 9 11 16 18 20 21 22; printf 'docs/reviews/log.md:2\n'; } | sort)"
if [[ "$got" == "$want" ]]; then
  pass "the guard reports exactly the thirteen broken fixture lines (stale, numbered, reasonless allow, wrapped, ambiguous, missing file, split after the colon, a stale citation in each of the two other spellings, each of those wrapped or split, and a stale citation in a review log's form)"
else
  fail "the guard reports exactly the thirteen broken fixture lines"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/     /'
  grep '^PROBLEM ' <<< "$fx_out" | sed 's/^/     /'
fi
read -r _ fx_files _ fx_allow <<< "$(grep '^COUNTS ' <<< "$fx_out")"
if [[ "${fx_allow:-}" == 1 ]]; then
  pass "a numbered reference with a reasoned ref-lint marker is allowed, and counted"
else
  fail "a numbered reference with a reasoned ref-lint marker is allowed, and counted (counted ${fx_allow:-none})"
fi
if [[ "${fx_files:-}" == 6 ]]; then
  pass "scope is the five fixture scripts and the review log — CHANGELOG.md, the .txt and the symlink are not scanned"
else
  fail "scope is the five fixture scripts and the review log — CHANGELOG.md, the .txt and the symlink are not scanned (scanned ${fx_files:-none})"
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
