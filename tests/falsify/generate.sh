#!/usr/bin/env bash
# tests/falsify/generate.sh — enumerate the single-line mutants of ONE shell file.
#
# CONTRACT (the runner depends on this exactly):
#
#   bash tests/falsify/generate.sh <file>
#
# prints one line per mutant to STDOUT, tab-separated, four fields:
#
#   <operator>\t<line-no>\t<sha1-of-trimmed-original-line>\t<mutated-line-text>
#
# NOTHING else reaches stdout. Diagnostics — the per-file tally and every
# discarded candidate — go to stderr. The mutated-line text is the LAST field on
# purpose: a shell line may itself contain a tab, and a consumer reading with
# `IFS=$'\t' read -r op lineno sha text` then still gets the whole line back.
#
# THE TARGET FILE IS NEVER MODIFIED. This generator only PRINTS mutants; writing
# one anywhere is the runner's job, and the runner does it in a scratch tree.
# That is the opposite choice from tests/integration/mutate.sh, which patches the
# real working tree on purpose for hand-driven demonstrations. Both are correct
# for their purpose.
#
# The sha1 is of the ORIGINAL line, trimmed of leading/trailing whitespace, with
# no trailing newline — the third component of the ledger identity
# `<file>:<operator>:<sha1>`. Line numbers shift on every edit and are carried
# here only as a convenience for applying the mutant; they are NOT identity.
#
# OPERATORS. Four are on by default; `stream-flip` exists, is reachable, and is
# OFF unless FALSIFY_OPERATORS names it — measured at 100 % survival across the
# candidate corpus, which is worse signal than `num-bump` ever had, so it is
# opt-in per target rather than deleted (see the increment-5 design doc).
#
#   cond-negate   `[[ x ]]` → `[[ ! x ]]`, and `if/elif/while/until cmd;` → `… ! cmd;`
#   logic-flip    `&&` ↔ `||`
#   return-flip   `return 0` ↔ `return 1`, `exit 0` ↔ `exit 1`
#   cmp-flip      `-eq`↔`-ne`, `-lt`↔`-ge`, `-gt`↔`-le`, `==`↔`!=`, `<`↔`>`
#   stream-flip   `>&2` → `>&1`                                   [off by default]
#
# ONE MUTANT PER APPLICABLE TOKEN OCCURRENCE, not per line: a line with two `&&`
# yields two mutants, because a test may kill one and be blind to the other.
#
# `<` and `>` are flipped ONLY inside a `[[ … ]]` or `(( … ))` span, tracked by
# this file's own scanner. Everywhere else they are redirections, and "mutating" a
# redirection produces a file-clobbering candidate that tests nothing about any
# assertion.
#
# SKIPPED, because a mutant there is not code the oracle can observe: heredoc
# bodies (and their terminators), full-line comments, the shebang, blank lines,
# and — quote-aware — the trailing-comment part of a code line.
#
# EVERY EMITTED MUTANT PASSES `bash -n`. The candidate is applied to a scratch
# copy of the whole file and parsed; a candidate that does not parse is DISCARDED
# and tallied separately, because a syntax error proves nothing about any
# assertion. On the staged targets the discard count is 0 — a non-zero count
# means this generator emits malformed output and is a bug here, not a tolerance.
# tests/test-falsify-generate.sh demonstrates that gate by feeding malformed
# candidates through falsify_check_syntax, the same function the loop below uses.
#
# ENV
#   FALSIFY_OPERATORS  comma- or space-separated operator names. UNSET → the four
#                      defaults; EXPLICITLY EMPTY → refused, because a caller that
#                      computed an empty list must not be answered with the full
#                      default set. An unknown name is a hard error too, never a
#                      silent "generated nothing".
#   FALSIFY_TMPDIR     scratch directory to use instead of a private mktemp -d.
#                      Set it when SOURCING this file, so the caller's own trap
#                      owns the cleanup.
#
# SOURCEABLE: sourcing defines the functions and runs nothing, so a test can
# drive falsify_check_syntax / falsify_scan_line directly instead of asserting on
# this file's source text.

FALSIFY_ALL_OPERATORS="cond-negate logic-flip return-flip cmp-flip stream-flip"
FALSIFY_DEFAULT_OPERATORS="cond-negate logic-flip return-flip cmp-flip"

_FALSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../portability.sh
source "$_FALSIFY_LIB_DIR/../portability.sh"

# ── scratch space ─────────────────────────────────────────────────────────────
# Created lazily and reused for every candidate: a per-mutant mktemp would cost
# more than the bash -n it exists to feed.
_FALSIFY_TMPDIR=""
_FALSIFY_TMPDIR_OWNED=0
_FALSIFY_SYNTAX_TMP=""
_FALSIFY_SHA_TMP=""

# CREATED IN THE PARENT OR NOT AT ALL. `mktemp -d` inside a command substitution
# makes the directory on disk but sets _FALSIFY_TMPDIR and _FALSIFY_TMPDIR_OWNED
# in a SUBSHELL, where both die -- so the parent's release has nothing to
# release and the directory survives the process. falsify_sha1_string is called
# as `sha="$(falsify_sha1_string ...)"` (line ~475), so whichever call got there
# first leaked one directory per invocation: measured 2026-08-28, a 16-target
# corpus left 16 behind, and a machine that had run this tier for weeks held
# thousands in a temp directory shared with everything else on the host.
#
# falsify_generate now calls this once up front, in the parent, so no subshell
# ever reaches the mktemp branch. Kept lazy rather than made eager at load time
# because this file is also SOURCED, and a sourcing test that never generates
# anything should not pay for a scratch directory.
_falsify_tmpdir() {
  [[ -n "$_FALSIFY_TMPDIR" ]] && return 0
  if [[ -n "${FALSIFY_TMPDIR:-}" ]]; then
    _FALSIFY_TMPDIR="$FALSIFY_TMPDIR"
    mkdir -p "$_FALSIFY_TMPDIR" || return 1
  else
    _FALSIFY_TMPDIR="$(mktemp -d)" || return 1
    _FALSIFY_TMPDIR_OWNED=1
  fi
  _FALSIFY_SYNTAX_TMP="$_FALSIFY_TMPDIR/candidate.sh"
  _FALSIFY_SHA_TMP="$_FALSIFY_TMPDIR/line.txt"
}

_falsify_tmpdir_release() {
  [[ "$_FALSIFY_TMPDIR_OWNED" == "1" && -n "$_FALSIFY_TMPDIR" ]] || return 0
  rm -rf "$_FALSIFY_TMPDIR"
  _FALSIFY_TMPDIR=""
  _FALSIFY_TMPDIR_OWNED=0
}

# ── small helpers ─────────────────────────────────────────────────────────────
falsify_trim() {   # $1 = text → same text without leading/trailing whitespace
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

falsify_sha1_string() {   # $1 = text → sha1 hex of exactly that text, no newline
  _falsify_tmpdir || return 1
  printf '%s' "$1" > "$_FALSIFY_SHA_TMP" || return 1
  # p_sha1 (tests/portability.sh) rather than a local sha1sum/shasum fallback:
  # the suite runs on GNU CI and on a BSD-userland host, and that difference is
  # resolved in exactly one place by project rule.
  p_sha1 "$_FALSIFY_SHA_TMP"
}

# falsify_operator_set — echo the normalised, validated enabled-operator list.
falsify_operator_set() {
  # `-`, not `:-`: UNSET means "use the defaults", but an explicitly EMPTY value
  # means the caller asked for no operator at all, which can only ever produce an
  # empty corpus. That is refused below rather than silently answered with the
  # full default set — the same rule the integration runner applies to a
  # selection that matches no case.
  local raw="${FALSIFY_OPERATORS-$FALSIFY_DEFAULT_OPERATORS}" name out=""
  local -a names=()
  raw="${raw//,/ }"
  read -r -a names <<< "$raw"
  for name in "${names[@]}"; do
    case " $FALSIFY_ALL_OPERATORS " in
      *" $name "*) ;;
      *) printf 'falsify: unknown operator %s (known: %s)\n' \
           "$name" "$FALSIFY_ALL_OPERATORS" >&2
         return 2 ;;
    esac
    case " $out " in *" $name "*) continue ;; esac
    out="${out:+$out }$name"
  done
  if [[ -z "$out" ]]; then
    printf 'falsify: FALSIFY_OPERATORS selected no operator\n' >&2
    return 2
  fi
  printf '%s' "$out"
}

# ── the bash -n gate ──────────────────────────────────────────────────────────
# Applies ONE candidate to a scratch copy of the whole file and parses it. Whole
# file, not the line alone: a line ending in a backslash continuation, a `case`
# arm, or a loop body is not a parseable program by itself, so line-only checking
# would discard perfectly good mutants and hide bad ones.
_FALSIFY_CACHE_FILE=""
_FALSIFY_CACHE_LINES=()

# A CANDIDATE THAT DOES NOT PARSE AND A CHECK THAT COULD NOT RUN ARE DIFFERENT
# ANSWERS, and conflating them silently shrinks the corpus. `bash -n` separates
# them cleanly and always has — measured, not assumed:
#
#   syntax error       rc 2
#   well-formed        rc 0
#   cannot be run at all (unreadable/missing file, and the shape a failed fork
#                      takes under memory or process pressure)   rc 127
#
# The old code returned `bash -n`'s status directly and the caller discarded on
# ANY non-zero, so a check that never ran was recorded as "bash -n rejected the
# candidate". On a loaded macOS host — where every oracle run forks constantly
# and is ~18x slower than Linux — that turns fork pressure into a QUIETLY
# SMALLER mutant set, which is the one failure a mutation tier must never have:
# coverage that shrinks without the number that reports it moving.
#
#   0  the candidate parses
#   1  the candidate does NOT parse — a real discard
#   2  the check could not be performed — the caller must not call this a discard
falsify_check_syntax() {   # <file> <line-no> <candidate-line>
  local file="$1" lineno="$2" text="$3" idx rc
  _falsify_tmpdir || return 2
  if [[ "$file" != "$_FALSIFY_CACHE_FILE" ]]; then
    _FALSIFY_CACHE_LINES=()
    mapfile -t _FALSIFY_CACHE_LINES < "$file" || return 2
    _FALSIFY_CACHE_FILE="$file"
  fi
  idx=$((lineno - 1))
  if (( idx < 0 || idx >= ${#_FALSIFY_CACHE_LINES[@]} )); then
    printf 'falsify: line %s is outside %s\n' "$lineno" "$file" >&2
    return 2
  fi
  printf '%s\n' "${_FALSIFY_CACHE_LINES[@]:0:idx}" "$text" \
                "${_FALSIFY_CACHE_LINES[@]:idx+1}" > "$_FALSIFY_SYNTAX_TMP" || return 2
  bash -n "$_FALSIFY_SYNTAX_TMP" 2>/dev/null
  rc=$?
  # 0 and 2 are bash's own verdicts on the program. Anything else means bash
  # never got to judge it. A STUBBED gate (tests replace the `bash -n` line with
  # `true`) yields 0 and still reads as "parses", so the demonstration that the
  # gate is load-bearing keeps working.
  case "$rc" in
    0) return 0 ;;
    2) return 1 ;;
    *) printf 'falsify: bash -n could not run (rc=%s) on %s:%s — not a verdict on the candidate\n' \
         "$rc" "$file" "$lineno" >&2
       return 2 ;;
  esac
}

# ── the line scanner ──────────────────────────────────────────────────────────
# One left-to-right pass, quote-aware, tracking `[[`/`((` nesting depth. Results:
#   SCAN_OPS[i] / SCAN_TEXTS[i]   the i'th mutant of this line
#   SCAN_HEREDOC[i]               "<dash>|<delimiter>" per heredoc opened here
#
# Known limits, recorded rather than papered over: quoting nested inside `${…}`
# (as in `"${v#"${v%%x*}"}"`) is read as two adjacent quoted runs, and a POSIX
# class closing a bracket expression (`*[[:space:]]*`) ends a `[[` span early.
# Both can only ever cost a mutant, never invent a malformed one — and the
# bash -n gate is the backstop if that reasoning is ever wrong.
SCAN_OPS=()
SCAN_TEXTS=()
SCAN_HEREDOC=()
_FALSIFY_LINE=""
_FALSIFY_ENABLED=" $FALSIFY_DEFAULT_OPERATORS "

_falsify_tok() {   # <operator> <pos> <len> <replacement>
  case "$_FALSIFY_ENABLED" in *" $1 "*) ;; *) return 0 ;; esac
  SCAN_OPS+=("$1")
  SCAN_TEXTS+=("${_FALSIFY_LINE:0:$2}$4${_FALSIFY_LINE:$(($2 + $3))}")
}

# True when position $2 starts a word — i.e. what precedes it cannot be part of
# an identifier, a glob, or a path. Keeps `[[` in `*[[:space:]]*` and `-lt` in
# `--filter=lt` from being read as operators.
_falsify_word_before() {   # <line> <pos>
  (( $2 == 0 )) && return 0
  case "${1:$2-1:1}" in
    [[:space:]]|';'|'&'|'|'|'('|'!'|'{') return 0 ;;
  esac
  return 1
}

_falsify_word_after() {    # <line> <pos-just-past-the-token>
  (( $2 >= ${#1} )) && return 0
  case "${1:$2:1}" in
    [[:space:]]|';'|'&'|'|'|')'|']') return 0 ;;
  esac
  return 1
}

falsify_scan_line() {   # $1 = raw line text, $2 = incoming span depth (default 0)
  _FALSIFY_LINE="$1"
  SCAN_OPS=(); SCAN_TEXTS=(); SCAN_HEREDOC=()
  local line="$1"
  local n=${#line} i=0 sq=0 dq=0 depth="${2:-0}" code_end=${#line}
  local c t2 t3 rep len kw ws val dash delim code head_len

  while (( i < n )); do
    c="${line:i:1}"

    if (( sq )); then
      [[ "$c" == "'" ]] && sq=0
      i=$((i + 1)); continue
    fi
    if (( dq )); then
      if [[ "$c" == '\' ]]; then i=$((i + 2)); continue; fi
      [[ "$c" == '"' ]] && dq=0
      i=$((i + 1)); continue
    fi

    case "$c" in
      "'") sq=1; i=$((i + 1)); continue ;;
      '"') dq=1; i=$((i + 1)); continue ;;
      '\') i=$((i + 2)); continue ;;
      '#')
        # A '#' opens a comment only at the start of a word. That is what keeps
        # `${f##*/}`, `${v%%[[:space:]]#*}` and `*#*` out of the comment logic.
        if _falsify_word_before "$line" "$i"; then code_end=$i; break; fi
        i=$((i + 1)); continue ;;
    esac

    t2="${line:i:2}"
    t3="${line:i:3}"

    # Herestring before heredoc before `<` — `<<<` must not be read as a heredoc
    # whose delimiter is the string that follows it.
    if [[ "$t3" == '<<<' ]]; then i=$((i + 3)); continue; fi

    if [[ "$t3" == '>&2' ]]; then
      _falsify_tok stream-flip "$i" 3 '>&1'
      i=$((i + 3)); continue
    fi

    if [[ "$t2" == '<<' ]]; then
      if [[ "${line:i+2}" =~ ^(-?)[[:space:]]*(\"([^\"]+)\"|\'([^\']+)\'|([A-Za-z_][A-Za-z0-9_]*)) ]]; then
        dash="${BASH_REMATCH[1]}"
        delim="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        SCAN_HEREDOC+=("$dash|$delim")
      fi
      i=$((i + 2)); continue
    fi

    case "$t2" in
      '[[')
        # `[[ ` (with the space) is the test keyword; `[[:` is a POSIX class.
        if _falsify_word_before "$line" "$i" && [[ "${line:i+2:1}" == [[:space:]] ]]; then
          depth=$((depth + 1))
          _falsify_tok cond-negate "$i" 2 '[[ !'
        fi
        i=$((i + 2)); continue ;;
      ']]')
        # `:]]` closes a bracket expression, not a test.
        if [[ "${line:i-1:1}" != ':' ]] && (( depth > 0 )); then depth=$((depth - 1)); fi
        i=$((i + 2)); continue ;;
      '((') depth=$((depth + 1)); i=$((i + 2)); continue ;;
      '))') (( depth > 0 )) && depth=$((depth - 1)); i=$((i + 2)); continue ;;
      '&&') _falsify_tok logic-flip "$i" 2 '||'; i=$((i + 2)); continue ;;
      '||') _falsify_tok logic-flip "$i" 2 '&&'; i=$((i + 2)); continue ;;
      '==') _falsify_tok cmp-flip "$i" 2 '!='; i=$((i + 2)); continue ;;
      '!=') _falsify_tok cmp-flip "$i" 2 '=='; i=$((i + 2)); continue ;;
    esac

    case "$t3" in
      -eq|-ne|-lt|-ge|-gt|-le)
        if _falsify_word_before "$line" "$i" && _falsify_word_after "$line" $((i + 3)); then
          case "$t3" in
            -eq) rep='-ne' ;; -ne) rep='-eq' ;;
            -lt) rep='-ge' ;; -ge) rep='-lt' ;;
            -gt) rep='-le' ;;  *)  rep='-gt' ;;
          esac
          _falsify_tok cmp-flip "$i" 3 "$rep"
          i=$((i + 3)); continue
        fi ;;
    esac

    if [[ "$c" == 'r' || "$c" == 'e' ]] \
       && [[ "${line:i}" =~ ^(return|exit)([[:space:]]+)([01])($|[^[:alnum:]_]) ]] \
       && _falsify_word_before "$line" "$i"; then
      kw="${BASH_REMATCH[1]}"; ws="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
      if [[ "$val" == '0' ]]; then rep='1'; else rep='0'; fi
      len=$(( ${#kw} + ${#ws} + 1 ))
      _falsify_tok return-flip "$i" "$len" "$kw$ws$rep"
      i=$((i + len)); continue
    fi

    # `<`/`>` are comparisons only inside a test or arithmetic span. `<<`, `>>`
    # and `>&` are excluded outright — those are never comparisons.
    if (( depth > 0 )); then
      if [[ "$c" == '<' && "${line:i+1:1}" != '<' && "${line:i-1:1}" != '<' ]]; then
        _falsify_tok cmp-flip "$i" 1 '>'
      elif [[ "$c" == '>' && "${line:i+1:1}" != '>' && "${line:i+1:1}" != '&' \
              && "${line:i-1:1}" != '>' ]]; then
        _falsify_tok cmp-flip "$i" 1 '<'
      fi
    fi

    i=$((i + 1))
  done

  # cond-negate's second form, negating the head of a compound command. Line
  # level, not token level: it needs the whole head, and it must NOT fire on a
  # head that continues onto the next line (`if (( a \`), where inserting `!`
  # after the keyword would be a mutant of a fragment. Requiring `; then`/`; do`
  # in the code region is exactly that check.
  code="${line:0:code_end}"
  if [[ "$code" =~ ^([[:space:]]*)(if|elif|while|until)[[:space:]] ]]; then
    head_len=$(( ${#BASH_REMATCH[1]} + ${#BASH_REMATCH[2]} ))
    if [[ "$code" =~ \;[[:space:]]*(then|do)([[:space:]]|$) ]]; then
      case "$_FALSIFY_ENABLED" in
        *' cond-negate '*)
          SCAN_OPS=(cond-negate "${SCAN_OPS[@]}")
          SCAN_TEXTS=("${line:0:head_len} !${line:head_len}" "${SCAN_TEXTS[@]}") ;;
      esac
    fi
  fi

  # ── stream-flip, the OTHER direction: stdout → stderr ────────────────────────
  # `>&2` → `>&1` alone is one-directional, and that made the tier blind to the
  # exact shape of historical hole #6 (7d1970f): a `printf` whose output belongs
  # on STDOUT, asserted by a test helper that folded stderr INTO stdout, so the
  # assertion could not fail either way. Catching that needs the reverse move —
  # push a stdout line to stderr and see whether anything notices.
  #
  # Line-level, not token-level: there is no token to rewrite, only a redirect to
  # append. Deliberately narrow — a bare `printf`/`echo` whose code region holds
  # no redirection of any kind and does not end in a pipe, `&&`, `||`, `\` or a
  # `;`-chained continuation. Anything more ambitious would append a redirect
  # into the middle of a compound command; the bash -n gate is the backstop, but
  # a discarded candidate is wasted work, not a caught bug.
  case "$_FALSIFY_ENABLED" in
    *' stream-flip '*)
      code="${line:0:code_end}"
      code="${code%"${code##*[![:space:]]}"}"          # rstrip
      if [[ "$code" =~ ^[[:space:]]*(printf|echo)[[:space:]] ]] \
         && [[ "$code" != *'>'* ]] && [[ "$code" != *'|'* ]] \
         && [[ "$code" != *'&&'* ]] && [[ "$code" != *'||'* ]] \
         && [[ "$code" != *';'* ]] && [[ "$code" != *'\' ]]; then
        SCAN_OPS+=(stream-flip)
        SCAN_TEXTS+=("$code >&2${line:code_end}")
      fi ;;
  esac

  # The span depth this line ENDS at, for a caller continuing onto the next
  # physical line. See the continuation note at the call site.
  SCAN_DEPTH_END="$depth"
}

# ── the generator ─────────────────────────────────────────────────────────────
FALSIFY_MUTANTS=0
FALSIFY_DISCARDED=0

falsify_generate() {   # <file>
  # Before anything runs in a subshell — see _falsify_tmpdir's note.
  _falsify_tmpdir || return 1
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    printf 'usage: generate.sh <file>\n' >&2
    return 2
  fi
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf 'falsify: not a readable file: %s\n' "$file" >&2
    return 2
  fi
  local ops
  ops="$(falsify_operator_set)" || return 2
  _FALSIFY_ENABLED=" $ops "

  local -a lines=() heredoc_q=()
  mapfile -t lines < "$file" || return 2

  local idx lineno line trimmed sha k h dash delim cand
  local carry_depth=0
  FALSIFY_MUTANTS=0
  FALSIFY_DISCARDED=0

  for (( idx = 0; idx < ${#lines[@]}; idx++ )); do
    line="${lines[idx]}"
    lineno=$((idx + 1))

    # Inside a heredoc body: nothing here is code. The terminator line is not
    # code either, so it is consumed and skipped like the body.
    if (( ${#heredoc_q[@]} > 0 )); then
      h="${heredoc_q[0]}"
      dash="${h%%|*}"
      delim="${h#*|}"
      if [[ "$dash" == '-' ]]; then cand="$(falsify_trim "$line")"; else cand="$line"; fi
      if [[ "$cand" == "$delim" ]]; then heredoc_q=("${heredoc_q[@]:1}"); fi
      continue
    fi

    # Blank lines, the shebang, and full-line comments carry no code. The
    # shebang needs no separate rule — it IS a full-line comment.
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # A `[[ … ]]` / `(( … ))` span may run across a backslash continuation, and
    # `<`/`>` are only ever mutated INSIDE such a span. Scanning each physical
    # line from depth 0 therefore made every comparison on a continued line
    # invisible — silently under-generating, which is the worse failure
    # direction for a tool whose whole job is finding gaps.
    #
    # The instance that exposed it is not incidental: bash-floor.sh:40-42 is the
    # bash floor check ITSELF, the comparison deciding whether this repo refuses
    # to run at all, and it holds two `<` that no mutant could reach.
    #
    # Carrying the depth forward is sound because the continuation is part of the
    # SAME shell command; each mutant is still written back to its own physical
    # line, so identity and line numbers are unaffected.
    falsify_scan_line "$line" "$carry_depth"
    if [[ "$line" == *\\ ]]; then carry_depth="$SCAN_DEPTH_END"; else carry_depth=0; fi

    for h in "${SCAN_HEREDOC[@]}"; do heredoc_q+=("$h"); done

    (( ${#SCAN_OPS[@]} > 0 )) || continue

    trimmed="$(falsify_trim "$line")"
    sha="$(falsify_sha1_string "$trimmed")"
    if [[ -z "$sha" ]]; then
      printf 'falsify: could not hash %s:%s — refusing to emit an identity-less mutant\n' \
        "$file" "$lineno" >&2
      FALSIFY_DISCARDED=$((FALSIFY_DISCARDED + ${#SCAN_OPS[@]}))
      continue
    fi

    for (( k = 0; k < ${#SCAN_OPS[@]}; k++ )); do
      falsify_check_syntax "$file" "$lineno" "${SCAN_TEXTS[k]}"
      case "$?" in
        0) printf '%s\t%s\t%s\t%s\n' "${SCAN_OPS[k]}" "$lineno" "$sha" "${SCAN_TEXTS[k]}"
           FALSIFY_MUTANTS=$((FALSIFY_MUTANTS + 1)) ;;
        1) FALSIFY_DISCARDED=$((FALSIFY_DISCARDED + 1))
           printf 'falsify: DISCARD %s:%s %s — bash -n rejected the candidate\n' \
             "$file" "$lineno" "${SCAN_OPS[k]}" >&2 ;;
        # NOT a discard, and not silent: the corpus would be short by one mutant
        # for a reason having nothing to do with the mutant. Fail the whole
        # generation instead, so the caller cannot proceed on a short list
        # believing it complete.
        *) printf 'falsify: ABORTING %s:%s — the syntax gate could not run\n' \
             "$file" "$lineno" >&2
           _falsify_tmpdir_release
           return 1 ;;
      esac
    done
  done

  printf 'falsify: %s: %s mutant(s), %s discarded [%s]\n' \
    "$file" "$FALSIFY_MUTANTS" "$FALSIFY_DISCARDED" "$ops" >&2
  _falsify_tmpdir_release
  return 0
}

# BY BEHAVIOUR, NOT BY STRING (#218): `return` succeeds outside a function only
# in a sourced file, so this cannot be fooled by an absolute-path invocation.
if ! (return 0 2>/dev/null); then
  set -uo pipefail
  # EVERY exit path, not the two that call it by hand. Measured 2026-08-28: one
  # `mktemp -d` per invocation survived the run, so a 16-target corpus left 16
  # behind and a machine that had run the tier for weeks held thousands. On a
  # host whose temp directory is shared with everything else (macOS's
  # /var/folders), that is litter this harness has no business creating.
  #
  # INSIDE the main guard, deliberately. tests/test-falsify-generate.sh and
  # tests/test-falsify-historical.sh SOURCE this file, and an unconditional EXIT
  # trap would replace the `rm -rf "$TMP"` trap those tests set on themselves --
  # fixing a one-directory leak by creating a much larger one.
  trap '_falsify_tmpdir_release' EXIT
  falsify_generate "$@"
  exit $?
fi
