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

# ── AN INSTALLER'S OWN FETCHES ARE NOT COVERED BY THE RULE ABOVE ─────────────
# Everything above asks whether each `curl` can fail and can retry. It cannot ask
# anything about what the downloaded script then does, and six vendor installers
# run in this Dockerfile (`bash /tmp/<name>.sh`) that each fetch again from the
# network on their own terms.
#
# nvm is the one with recorded failures, twice. Its install.sh defaults to
# install_nvm_from_git, a bare `git clone --depth=1` against github.com with no
# retry — and on 2026-09-02 GitHub answered an unauthenticated clone of a PUBLIC
# repo with 401 (`could not read Username for 'https://github.com'`, its
# rate-limiting shape), which failed all three image variants and every one of
# the 36 integration cases. The identical build succeeded minutes later with
# nothing changed. So the retry has to wrap the INSTALLER, not just its download.
#
# ASSERTED NARROWLY AND ON PURPOSE. This checks the one installer that has
# actually failed, rather than demanding a retry loop around all six: the other
# five have no recorded failure, and each needs its own idempotency argument for
# what a second attempt does to a half-finished install. Widening this is a
# change that wants evidence, and the evidence would be a failure.
#
# ── EXTRACTING A LAYER, AND KNOWING THE EXTRACTION STOPPED WHERE IT SHOULD ────
# Each block below is cut out of the Dockerfile by a START anchor and an END
# anchor, and every assertion after it is a grep over what was cut. A `-z` guard
# catches a START anchor that has drifted: nothing matched, nothing extracted,
# and the greps would all be vacuous. It cannot catch the other half — and the
# other half is the one that actually happened.
#
# MEASURED, NOT IMAGINED. pyenv's END anchor was written
# `uvx \/usr\/local\/bin\/uvx$`; the line it targets is
# `ln -sf "$PYENV_ROOT/shims/uvx" /usr/local/bin/uvx`, and the QUOTE between the
# two `uvx`es means it never matched. awk therefore ran to EOF, and "the pyenv
# layer" became the whole rest of the Dockerfile — 501 lines instead of 105,
# INCLUDING the install-tools.sh RUN block, which mounts the same
# `github_token` secret. So "the pyenv clone layer mounts the secret" passed
# with that mount DELETED from the pyenv layer. An assertion that cannot fail is
# worse than no assertion: it reports coverage it does not have.
#
# Found-too-much is thus its own verdict, reported apart from found-nothing. awk
# prints a sentinel on the line it exits at; no sentinel means it fell off the
# end and the block is not a block.
LAYER_END_SENTINEL=$'\001END-ANCHOR-MATCHED'

# Pure — prints, never judges. It is called in a command substitution, and a
# `fails=$((fails+1))` inside a subshell is discarded, which would make this
# file under-report exactly the way the defect above did.
extract_layer() {  # $1 start-regex  $2 end-regex  $3 file
  awk -v s="$1" -v e="$2" -v sent="$LAYER_END_SENTINEL" '
    $0 ~ s      { f = 1 }
    f           { print }
    f && $0 ~ e { print sent; exit }
  ' "$3"
}

# Judges — in the CURRENT shell, so pass/fail reach the real counter. Leaves the
# block in LAYER_BODY, empty when either anchor failed.
check_layer() {  # $1 name  $2 raw extraction
  LAYER_BODY=""
  if [[ -z "$2" ]]; then
    fail "the $1 bootstrap RUN block was found — its START anchor matched nothing, so the assertions below are vacuous"
  elif [[ "${2##*$'\n'}" != "$LAYER_END_SENTINEL" ]]; then
    fail "the $1 bootstrap RUN block stopped at its END anchor — it did not, so awk ran to EOF and the block swallowed every later layer; the assertions below would then be satisfied by some OTHER layer's text (this is how the pyenv secret-mount check came to pass with the mount deleted)"
  else
    pass "the $1 bootstrap RUN block was found, and stopped at its END anchor"
    LAYER_BODY="${2%$'\n'"$LAYER_END_SENTINEL"}"
  fi
}

check_layer nvm "$(extract_layer '^ARG NVM_VERSION=' 'ln -sf .*/npx /usr/local/bin/npx' "$REPO_DIR/Dockerfile")"
nvm_run="$LAYER_BODY"
if [[ -n "$nvm_run" ]]; then
  if grep -q 'for attempt in' <<< "$nvm_run"; then
    pass "  … and the installer runs inside a retry loop, not just its download"
  else
    fail "  … and the installer runs inside a retry loop, not just its download — nvm's install.sh git-clones from github.com with no retry of its own, so a rate-limited clone fails the whole build (measured 2026-09-02)"
  fi
  # A retry over the previous attempt's debris is not a retry: install.sh takes
  # its "already installed" branch when $NVM_DIR/.git survives.
  if grep -q 'rm -rf "\$NVM_DIR"' <<< "$nvm_run"; then
    pass "  … and each attempt starts from a clean \$NVM_DIR"
  else
    fail "  … and each attempt starts from a clean \$NVM_DIR — without the reset, install.sh finds a half-finished clone and fetches into it instead of re-cloning"
  fi
fi


# pyenv is the second, reached the same way inside the same rate-limiting window.
# `https://pyenv.run` is a 270-BYTE SHIM whose entire body is
# `curl -s -S -L .../pyenv-installer | bash`; the real installer then runs FOUR
# bare `git clone`s — pyenv, pyenv-doctor, pyenv-update, pyenv-virtualenv — none
# retried. On 2026-09-02 the first of the four answered `fatal: could not read
# Username for 'https://github.com'` and failed the build at the pyenv layer.
#
# ITS RESET IS LOAD-BEARING FOR A STRONGER REASON THAN NVM'S, and the difference
# between them is a trap. pyenv-installer REFUSES TO RUN AT ALL when $PYENV_ROOT
# already exists — "Can not proceed with installation. Kindly remove the '...'
# directory first.", exit 1, before it touches the network (measured, not
# reasoned). With four clones, a PARTIALLY populated $PYENV_ROOT is the likely
# shape of a rate-limited failure rather than an edge case: clone 1 succeeds,
# clone 3 takes the 401, and the directory is left behind. Without `rm -rf`,
# attempts 2 and 3 are then GUARANTEED to fail — a loop that converts one
# transient 401 into three deterministic ones.
#
# And unlike nvm's reset, this one must NOT be followed by `mkdir -p`: nvm's
# install.sh needs $NVM_DIR to exist, pyenv's installer exits 1 because it does.
# Copying the nvm loop verbatim breaks pyenv 100% of the time, so that is
# asserted here rather than left to be rediscovered.
#
# THE END ANCHOR IS THE WHOLE LINE'S TAIL, not a two-token phrase. The line is
# `ln -sf "$PYENV_ROOT/shims/uvx" /usr/local/bin/uvx`, and the earlier attempt to
# name both `uvx`es either side of a space could not match across the quote. The
# install path is unique in this file; check_layer proves the anchor still fires.
check_layer pyenv "$(extract_layer '^ENV PYENV_ROOT=' '/usr/local/bin/uvx$' "$REPO_DIR/Dockerfile")"
pyenv_run="$LAYER_BODY"
if [[ -n "$pyenv_run" ]]; then
  if grep -q 'for attempt in' <<< "$pyenv_run"; then
    pass "  … and the installer runs inside a retry loop, not just its download"
  else
    fail "  … and the installer runs inside a retry loop, not just its download — pyenv.run's installer git-clones four repos from github.com with no retry of its own, so one rate-limited clone fails the whole build (measured 2026-09-02)"
  fi
  if grep -q 'rm -rf "\$PYENV_ROOT"' <<< "$pyenv_run"; then
    pass "  … and each attempt starts from a clean \$PYENV_ROOT"
  else
    fail "  … and each attempt starts from a clean \$PYENV_ROOT — pyenv-installer refuses outright when the directory exists, so without the reset a partial install makes every later attempt fail deterministically"
  fi
  if grep -q 'mkdir -p "\$PYENV_ROOT"' <<< "$pyenv_run"; then
    fail "  … and it does NOT recreate \$PYENV_ROOT after the reset — pyenv-installer exits 1 when the directory exists, so the mkdir that nvm's loop requires is fatal here"
  else
    pass "  … and it does NOT recreate \$PYENV_ROOT after the reset"
  fi
fi
# ── THE CLONES MUST BE ABLE TO AUTHENTICATE, AND THE TOKEN MUST NOT LEAK ──────
# The retry loops above only buy time; they cannot create budget. Anonymous git
# traffic sits in GitHub's low tier, and when that tier throttles an IP the build
# has nothing to fall back on — measured 2026-09-02, an anonymous clone taking
# 401 in the same container where an authenticated one succeeded. `build.sh`
# already passes the host's GITHUB_TOKEN as the `github_token` BuildKit secret;
# for months only install-tools.sh mounted it, so the two layers that actually
# clone ran anonymous with a perfectly good token sitting unused on the host.
#
# IT STAYS OPTIONAL. With no secret the clones are anonymous exactly as before —
# this repo ships no private tool and the token is a rate-limit convenience, not
# a requirement. What is asserted is that the layers can USE one.
#
# AND IT MUST BE A CREDENTIAL HELPER, NOT A URL REWRITE. The obvious form,
# `url.https://x-access-token:$TOK@github.com/.insteadOf`, embeds the token in
# the remote URL, and git echoes that URL in some failure messages — publishing
# the secret into the build log, the one place a BuildKit secret must never
# reach. That is a silent, plausible-looking regression, so it is refused here.
for layer in nvm:"$nvm_run" pyenv:"$pyenv_run"; do
  name="${layer%%:*}"; body="${layer#*:}"
  [[ -n "$body" ]] || continue          # its own vacuity guard already fired above
  if grep -q 'mount=type=secret,id=github_token' <<< "$body"; then
    pass "the $name clone layer can authenticate — it mounts the github_token secret"
  else
    fail "the $name clone layer can authenticate — it mounts the github_token secret; without it the clone is anonymous and has no budget to fall back on when GitHub throttles the IP"
  fi
  # COMMENTS STRIPPED FIRST, for the reason the extractor above strips them: the
  # Dockerfile DISCUSSES the URL-rewrite form in order to explain why it is
  # refused, and a raw scan flags that prose as the defect it warns against.
  code="$(grep -vE '^[[:space:]]*#' <<< "$body")"
  if grep -qE 'insteadOf|x-access-token:\$|@github\.com/' <<< "$code"; then
    fail "  … and the $name layer does NOT put the token in a URL — git prints remote URLs in failure messages, which would leak the secret into the build log; use the credential helper"
  else
    pass "  … and the $name layer does not put the token in a URL"
  fi
done

# ── A DOWNLOADED SCRIPT MUST NOT BE PIPED INTO A SHELL ───────────────────────
# The Dockerfile states this rule itself, at the nvm layer: "`-o` then
# `bash FILE`, not `curl | bash`: a pipe hands bash whatever arrived, so a
# TRUNCATED download executes its prefix and reports success. With a file, a
# short read is curl's failure and the build stops there."
#
# THE PYENV LAYER OBEYED IT FOR A 270-BYTE STUB AND BROKE IT FOR THE REAL
# INSTALLER. `https://pyenv.run` is not the installer; its entire body is
#   index_main() { set -e; curl -s -S -L .../pyenv-installer | bash; }
# so `-o /tmp/pyenv.sh` saved the shim to a file and the shim then piped the
# 2850-byte installer straight into bash — with no `-f`, no `--retry`, and in a
# shell with no `pipefail`, so curl's exit status is discarded entirely.
#
# WHAT THAT COSTS, traced rather than assumed: on a mid-transfer reset curl
# exits 18 while bash has ALREADY executed the prefix, and the pipeline reports
# bash's status. The installer's last four statements are its four `checkout`
# calls, so a truncation after the first yields pyenv with no plugins and
# EXIT 0 — a silently, subtly broken image rather than a failed build.
#
# The fix is the one the nvm layer already uses in this same file: fetch the
# installer itself with `-o` + `--retry` and run it as `bash FILE`. Fetching the
# raw URL is not a new dependency — it is the URL pyenv.run resolves to.
if grep -q 'pyenv\.run' <<< "$(grep -vE '^[[:space:]]*#' <<< "$pyenv_run")"; then
  fail "the pyenv layer does not fetch pyenv.run — that URL is a shim whose whole body is \`curl … | bash\`, so the real installer arrives through a pipe and a truncated one executes its prefix and reports success"
else
  pass "the pyenv layer fetches the installer itself, not the pyenv.run shim"
fi

# The direct form of the same defect, in our own files. Neither has ever had one;
# this refuses the shape rather than waiting for it.
#
# IT NEEDS ITS OWN SCAN, and that is the whole point. `fetch_sites` ends every
# segment at the first `&& || | ;`, because the flags after that belong to the
# NEXT command — so a pipe is exactly what it throws away, and a check built on
# it can never fire. That version was written, passed, and was found vacuous
# only by planting a `curl … | bash` and watching it stay green.
#
# So: join continuations (as Docker does), drop whole-line comments (this file's
# rules are DISCUSSED in prose right above), and look for a curl whose pipeline
# reaches a shell. The boundary matters — `| shasum` starts with "sh" and is not
# a shell; the real pipes in these files go to tar, dd and gpg.
pipe_hits=0
for t in "$REPO_DIR/Dockerfile" "$REPO_DIR/install-tools.sh"; do
  logical=""; lineno=0; origin=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$logical" ]] && origin="$lineno"
    logical="${logical}${raw%\\} "
    [[ "$raw" == *\\ ]] && continue
    if [[ "$logical " =~ curl[^\|]*\|[[:space:]]*(ba)?sh[[:space:]] ]]; then
      printf 'FAIL: %s:%s pipes a fetch into a shell — a truncated download executes its prefix and reports success\n' \
        "${t##*/}" "$origin"
      pipe_hits=$((pipe_hits + 1)); fails=$((fails + 1))
    fi
    logical=""
  done < "$t"
done
(( pipe_hits == 0 )) && pass "no fetch in either build file pipes into a shell interpreter"

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
