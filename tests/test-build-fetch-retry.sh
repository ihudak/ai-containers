#!/usr/bin/env bash
# tests/test-build-fetch-retry.sh — every build-time fetch must be able to FAIL
# and must be able to RETRY, and neither is true unless both flags are present.
#
# THE RULE, AND WHY IT IS TWO HALVES THAT ONLY WORK TOGETHER.
#
#   --retry   a transient failure is survived rather than failing the build
#   -f        an HTTP error IS a failure
#
# Without `-f`, curl treats a 404 or a 503 as a successful transfer of an error
# page: it exits 0, writes the body to the output file, and `--retry-all-errors`
# retries nothing because nothing failed. So `-f` is not tidiness — it is the
# precondition that makes the retry mean anything at all.
#
# MEASURED, NOT REASONED (2026-08-31, against a real 404 on dl.k8s.io):
#
#   curl -sL  --retry 2 --retry-all-errors -o f URL   → rc=0, f = 260-byte XML
#   curl -fsSL --retry 1 --retry-all-errors -o f URL  → rc=22, retried once
#
# WHAT WENT WRONG WITHOUT THIS FILE. v0.9.9's sweep added
# `--retry 5 --retry-delay 2 --retry-all-errors` to fifteen fetches and its
# notes claimed all fifteen now retry. Three of them — kubectl, aws-cli and
# azure-cli — had no `-f`, so the flags were inert at exactly those sites, and
# kubectl's `curl -LO` on a 404 would leave an XML error document in a file
# named `kubectl` that the next line installed as the binary. The convention was
# real, correct, and written down in prose; prose is what let three sites miss
# it, and a fourth would have missed it next time.
#
# SCOPE. The two files that fetch at build time. `wget` is checked too, but only
# to refuse it: it is installed in the image for interactive use and no build
# step fetches with it, so rather than write a second flag vocabulary this file
# fails if one appears — at which point a human decides what the rule is.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Confined to the owning process (F30/F32/F64; tests/test-exit-trap-ownership.sh).
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT


# ── the extractor ─────────────────────────────────────────────────────────────
# One record per INVOCATION, as "<lineno>|<segment>".
#
# CONTINUATIONS ARE JOINED FIRST, exactly as Docker joins them (and as the shell
# does), because command position cannot be read off a PHYSICAL line. In
#
#   RUN apt-get install -y --no-install-recommends \
#     ca-certificates curl gnupg lsb-release \
#     wget iputils-ping \
#
# both `curl` and `wget` are PACKAGE NAMES, and both sit at column 0 of their
# own line. Judging physical lines calls those two invocations; judging the
# joined line sees `ca-certificates curl` and `lsb-release wget` and calls
# neither. Whole-line comments are dropped before the join, again as Docker
# does — and this repo's Dockerfile discusses curl invocations at length in
# exactly the comment block this rule exists to guard.
#
# COMMAND POSITION, then, is: the start of the logical line, after one of
# `; & | ( ) { !` — which covers `&&`, `||`, `$(`, a `case` arm's `mongo)`, and
# `if !` — or after one of the words that introduce a command without being one,
# `RUN then do else`. That list is not decorative: seven of this Dockerfile's
# thirteen fetches sit behind `then` or a `case` arm, and a rule that knew only
# separators found six of them and reported the file clean.
#
# The segment ends at the first `&& || | ;` after the tool token: the flags
# belong to this invocation, and what follows belongs to the next command.
fetch_sites() {   # <file> <tool> → "<lineno>|<segment>" records
  local file="$1" tool="$2"
  local -a lines=() ofs=() src=()
  local i logical="" piece raw off pre seg trimmed k origin
  mapfile -t lines < "$file"
  for (( i = 0; i <= ${#lines[@]}; i++ )); do
    if (( i < ${#lines[@]} )); then
      raw="${lines[i]}"
      [[ "$raw" =~ ^[[:space:]]*# ]] && continue
      piece="${raw%\\}"
      ofs+=( "${#logical}" ); src+=( "$(( i + 1 ))" )
      logical="${logical}${piece} "
      [[ "$raw" == *\\ ]] && continue        # …more of this logical line follows
    fi
    # The logical line is complete (or the file ended): scan it.
    if [[ "$logical" == *"$tool "* ]]; then
      off=0
      while :; do
        seg="${logical:off}"
        [[ "$seg" == *"$tool "* ]] || break
        pre="${seg%%"$tool "*}"
        off=$(( off + ${#pre} + ${#tool} + 1 ))
        trimmed="${logical:0:$(( off - ${#tool} - 1 ))}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if [[ -z "$trimmed" || "$trimmed" =~ [\&\|\;\(\)\{\!]$ \
              || "$trimmed" =~ (^|[[:space:]])(RUN|then|do|else)$ ]]; then
          origin="${src[0]}"
          for (( k = 0; k < ${#ofs[@]}; k++ )); do
            (( ofs[k] < off )) && origin="${src[k]}"
          done
          seg="$tool ${logical:off}"
          seg="${seg%%&&*}"; seg="${seg%%||*}"; seg="${seg%%|*}"; seg="${seg%%;*}"
          printf '%s|%s\n' "$origin" "$seg"
        fi
      done
    fi
    logical=""; ofs=(); src=()
  done
}

# ── the checker ───────────────────────────────────────────────────────────────
# `--retry` must be its own token: `--retry-delay` and `--retry-all-errors` both
# START with it and neither makes curl retry anything on their own, so a
# substring test would pass a fetch that retries zero times.
has_retry() { [[ "$1" =~ (^|[[:space:]])--retry([[:space:]]|=) ]]; }
# `-f` lives in a cluster (`-fsSL`, `-fLO`) far more often than alone, so the
# test is per short-option TOKEN, not a substring: `-sSL` and `-LO` must not
# satisfy it, and neither must a filename that happens to contain an f.
has_fail() {
  local tok
  case "$1" in *' --fail '*|*' --fail-with-body '*) return 0 ;; esac
  for tok in $1; do
    [[ "$tok" =~ ^-[A-Za-z]+$ && "$tok" == *f* ]] && return 0
  done
  return 1
}
# → prints one "<lineno>: <reason>" per offending site
audit() {   # <file> <tool>
  local rec no seg
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    no="${rec%%|*}"; seg="${rec#*|}"
    has_fail " $seg " || printf '%s: no -f, so an HTTP error is not a failure\n' "$no"
    has_retry "$seg"  || printf '%s: no --retry, so a transient failure is fatal\n' "$no"
  done < <(fetch_sites "$1" "$2")
}

# ── 1. the checker itself, both directions ───────────────────────────────────
# Without this the scan below asserts a preference. With it, each of the three
# shapes that actually shipped is shown being caught, and its fix shown passing.
cat > "$TMP/bad" <<'BAD'
RUN apt-get install -y ca-certificates curl gnupg && \
    echo done
# a comment that names curl -sL https://example.invalid at command position
RUN curl -LO --retry 5 --retry-all-errors "https://example.invalid/kubectl" && \
      install kubectl /usr/local/bin/kubectl
RUN curl --retry 5 "https://example.invalid/a.zip" -o a.zip
RUN curl -sL --retry 5 -o /tmp/x.sh https://example.invalid/x && bash /tmp/x.sh
RUN curl -fsSL "https://example.invalid/ok.tgz" | tar xz -C /usr/local
BAD
bad_out="$(audit "$TMP/bad" curl)"
n_bad="$(grep -c . <<< "$bad_out")"
if [[ "$n_bad" == "4" ]]; then
  pass "the checker flags exactly the four defects planted, and nothing else"
else
  fail "the checker flags exactly the four defects planted (got $n_bad: $(tr '\n' '/' <<< "$bad_out"))"
fi
for want in '4: no -f' '6: no -f' '7: no -f' '8: no --retry'; do
  if grep -q "^${want}" <<< "$bad_out"; then
    pass "  … including line ${want%%:*} (${want#*: })"
  else
    fail "  … including line ${want%%:*} (${want#*: }) — got: $(tr '\n' '/' <<< "$bad_out")"
  fi
done
# THE PACKAGE-LIST LINE IS THE ONE THAT BREAKS A NAIVE RULE, so it is named.
if ! grep -q '^1:' <<< "$bad_out"; then
  pass "  … and NOT the apt line that names curl as a package"
else
  fail "  … and NOT the apt line that names curl as a package — it was flagged"
fi
if ! grep -q '^3:' <<< "$bad_out"; then
  pass "  … and NOT a comment that names an unflagged fetch"
else
  fail "  … and NOT a comment that names an unflagged fetch — it was flagged"
fi

cat > "$TMP/good" <<'GOOD'
RUN curl -fLO --retry 5 --retry-delay 2 --retry-all-errors "https://example.invalid/kubectl"
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://example.invalid/a.zip" -o a.zip
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      -o /tmp/x.sh \
      https://example.invalid/x && bash /tmp/x.sh
GOOD
good_out="$(audit "$TMP/good" curl)"
if [[ -z "$good_out" ]]; then
  pass "the fixed forms of all three pass, including flags split across a continuation"
else
  fail "the fixed forms pass (got: $(tr '\n' '/' <<< "$good_out"))"
fi
# A checker that matched nothing would also print nothing above.
n_good="$(fetch_sites "$TMP/good" curl | grep -c .)"
if [[ "$n_good" == "3" ]]; then
  pass "  … and it found all three of them rather than none"
else
  fail "  … and it found all three of them rather than none (found $n_good)"
fi

# ── 2. the real files ────────────────────────────────────────────────────────
declare -a targets=("$REPO_DIR/Dockerfile" "$REPO_DIR/install-tools.sh")
total=0
for t in "${targets[@]}"; do
  rel="${t#"$REPO_DIR"/}"
  if [[ ! -f "$t" ]]; then
    fail "$rel is missing — this rule scans a file that is not there"
    continue
  fi
  n="$(fetch_sites "$t" curl | grep -c .)"
  total=$(( total + n ))
  out="$(audit "$t" curl)"
  if [[ -z "$out" ]]; then
    pass "$rel: all $n fetch(es) can fail and can retry"
  else
    fail "$rel: $(grep -c . <<< "$out") fetch(es) cannot: $(sed "s|^|$rel:|" <<< "$out" | tr '\n' ' ')"
  fi
  w="$(fetch_sites "$t" wget | grep -c .)"
  if [[ "$w" == "0" ]]; then
    pass "  … and none of them fetches with wget, which this rule does not describe"
  else
    fail "  … but $w wget invocation(s) appeared, which this rule does not describe — decide the rule for them"
  fi
done
# THE COUNT IS ASSERTED for the same reason the in-scope count is asserted in
# tests/test-exit-trap-ownership.sh: an extractor that matched nothing would
# report a clean sweep having examined no fetch at all. Thirteen in the
# Dockerfile and five in install-tools.sh at the time of writing.
if (( total >= 15 )); then
  pass "the scan read $total fetch site(s) across both files"
else
  fail "the scan read only $total fetch site(s) — the extractor is not reading the tree"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
