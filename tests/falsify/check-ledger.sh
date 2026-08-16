#!/usr/bin/env bash
# tests/falsify/check-ledger.sh — the RATCHET on tests/falsify/survivors.txt.
#
# A surviving mutant is evidence that an assertion is missing or cannot fail.
# The ledger is where every one of them is written down and classified, and this
# script is what stops a NEW hole landing silently: a survivor that nobody has
# looked at fails the gate, and an entry that has outlived the mutant it
# excused fails it too.
#
#   bash tests/falsify/run.sh … | bash tests/falsify/check-ledger.sh --run-output -
#   bash tests/falsify/check-ledger.sh --run-output run.txt [--ledger FILE]
#   bash tests/falsify/check-ledger.sh --lint          # ledger grammar only
#   bash tests/falsify/check-ledger.sh --list          # what it parsed, one line each
#
# Exit: 0 clean · 1 findings (every one printed as an `ERROR:` line) · 2 usage,
# or a run output this gate cannot honestly check.
#
# ── THE FOUR HARD FAILURES ────────────────────────────────────────────────────
#   A  an entry with no GAP:/EQUIVALENT: classification, or with a marker whose
#      reason is EMPTY. Checked in every mode, because it is a property of the
#      entry rather than of any run. In a full run every in-scope entry is a
#      survivor (check D guarantees it), so A there is exactly "a survivor with
#      no classification" — the ratchet.
#   B  a SURVIVOR with no entry at all.
#   C  an entry whose identity matches no mutant this run generated — stale, in
#      the same way a patch that no longer applies is stale.
#   D  an entry whose mutants are now all KILLED — obsolete amnesty; delete it.
#
# ── CLASSIFICATION IS MANDATORY, AND AN EMPTY REASON SUPPRESSES NOTHING ───────
# `GAP:` and `EQUIVALENT:` are different claims. `EQUIVALENT:` asserts that NO
# test could ever kill this mutant — the mutated program is observably the same
# program. "No test currently does" is a `GAP:`. That distinction is a review
# obligation this format states and a human enforces; what is MECHANICAL here is
# that a marker is present and that its reason is non-empty, the same idiom as
# this repo's `# dialect-lint: allow RULE-ID: reason` and targets.conf's
# `#EXCLUDED|<target>|<reason>`, whose reasons are likewise checked for.
#
# ── LEDGER GRAMMAR ────────────────────────────────────────────────────────────
# Column 0 opens; indentation continues. Blank lines and `#` comments are
# ignored wherever they appear.
#
#   GROUP: <name>            optional, column 0 — names the entry that follows
#   <identity>               column 0; one or more CONSECUTIVE lines
#     <context>              indented free text (the original line, typically)
#     GAP: <reason>          indented; or EQUIVALENT: <reason>
#     <more reason>          indented continuation lines
#
# Consecutive identity lines share the one classification that follows them:
# that is the NAMED GROUP the format allows, and it is what keeps N survivors
# from one underlying cause from costing N pieces of prose. Context lines come
# BEFORE the classification; everything indented after the marker is read as
# continuation of the reason.
#
# ── IDENTITY, AND THE FACT THAT IT IS NOT UNIQUE ─────────────────────────────
# An identity is `<file>:<operator>:<sha1-of-trimmed-original-line>`, exactly as
# run.sh emits it — never `file:line`, which every edit above the line would
# invalidate wholesale. The sha1 is the full 40 hex digits the generator
# produces (the increment-5 spec's illustrative example abbreviates it to 7 for
# readability; this gate compares the string run.sh actually prints, so it is
# the full digest that belongs in the file).
#
# Identity is deliberately NOT unique, and run.sh's own header says so: one line
# holding two `&&` yields two logic-flip mutants sharing operator AND sha1, told
# apart only by `seq`/`lineno`. Both of those are run-local — a line number
# moves when anything above it moves — so neither can be part of a durable key.
#
# THE RULE, therefore: ONE ENTRY COVERS EVERY MUTANT SHARING ITS IDENTITY.
# Colliding mutants damage the SAME original line with the SAME operator, so
# they share the thing the ledger is actually recording: which line no assertion
# is watching. An entry is satisfied if AT LEAST ONE mutant carrying its
# identity survived (D), and is required as soon as any of them does (B). Where
# the collision is between genuinely different damages — `while ! IFS= read …`
# versus `while IFS= read … || [[ ! -n … ]]`, both cond-negate on one line — the
# entry's prose must account for all of them; the gate reports the count so an
# entry cannot quietly cover more than its author saw.
#
# DEDUPE (backlog F10): a single-clause `if [[ X ]];` yields two cond-negate
# mutants whose mutated TEXT is identical — the same damage, generated twice.
# Survivors are therefore deduplicated by (identity, mutated line) before being
# counted, so the survivor count this gate reports is a count of distinct
# damages. Deduping here rather than suppressing generation is deliberate: two
# mutants that coincide today may diverge if the operator changes.
#
# ── SCOPE: A PARTIAL RUN DOES NOT CONDEMN THE WHOLE LEDGER ───────────────────
# `run.sh --target tools-lib.sh` measures one file. Every entry for another file
# is then unmeasured, NOT stale — reporting it as stale would make the ledger
# unusable with any selection but the full corpus. The run's scope is the set of
# files named by its `TARGET|` lines, and an entry outside it is skipped and
# said to be skipped on stderr, never silently. A run output carrying no
# `TARGET|` line at all is refused (exit 2) rather than reported clean: a gate
# fed nothing must not pass.
#
# This reads run.sh's STDOUT only. run.sh's own exit status is a separate
# signal — an oracle that was not green on the pristine tree makes it exit 1 —
# and a caller must honour both.
#
# SOURCEABLE: sourcing defines the functions and runs nothing.

CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL_LEDGER="$CL_HERE/survivors.txt"
CL_GENERATE="$CL_HERE/generate.sh"

CL_MARKERS="GAP EQUIVALENT"

# Findings are counted BY cl_err itself rather than returned up a call chain: a
# check that both prints its findings and hands back a count has to be invoked
# in a `$(…)`, which captures the very ERROR: lines the caller exists to show.
CL_FINDINGS=0
cl_err() { printf 'ERROR: %s\n' "$*"; CL_FINDINGS=$(( CL_FINDINGS + 1 )); }
cl_note() { printf 'check-ledger: %s\n' "$*" >&2; }

cl_trim() {   # $1 = text → same text without leading/trailing whitespace
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The operator vocabulary is generate.sh's, taken FROM it rather than restated:
# an operator added there must not need a second edit here to be spellable in
# the ledger. generate.sh is sourceable and runs nothing when sourced.
CL_OPERATORS=""
cl_load_operators() {
  if [[ -z "${FALSIFY_ALL_OPERATORS:-}" && -f "$CL_GENERATE" ]]; then
    # shellcheck source=./generate.sh
    source "$CL_GENERATE"
  fi
  if [[ -z "${FALSIFY_ALL_OPERATORS:-}" ]]; then
    cl_err "cannot read the operator list from $CL_GENERATE — an identity's operator field could not be validated"
    return 1
  fi
  CL_OPERATORS=" $FALSIFY_ALL_OPERATORS "
  return 0
}

cl_valid_identity() {   # <text> → 0 when it is a well-formed ledger identity
  local ident="$1" sha rest op file
  case "$ident" in *[[:space:]]*) return 1 ;; esac
  [[ "$ident" == *:*:* ]] || return 1
  sha="${ident##*:}"; rest="${ident%:*}"
  op="${rest##*:}";   file="${rest%:*}"
  [[ -n "$file" && -n "$op" ]] || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$CL_OPERATORS" in *" $op "*) return 0 ;; esac
  return 1
}

# ── the ledger parser ─────────────────────────────────────────────────────────
# Entries are numbered; an identity maps to the entry that owns it.
CL_ENTRY_CLASS=()      # idx → GAP | EQUIVALENT | ""
CL_ENTRY_REASON=()     # idx → the collected reason, trimmed
CL_ENTRY_NAME=()       # idx → the GROUP: name, or ""
CL_IDENTS=()           # every identity, in file order
declare -A CL_IDENT_ENTRY=()
declare -A CL_IDENT_LINE=()
CL_PARSE_ERRORS=0

cl_parse_ledger() {   # <ledger file>
  local file="$1" line n=0 trimmed indented body_seen=0 cur=-1 pending_name="" force_new=0
  local marker rest first prev
  CL_ENTRY_CLASS=(); CL_ENTRY_REASON=(); CL_ENTRY_NAME=()
  CL_IDENTS=(); CL_IDENT_ENTRY=(); CL_IDENT_LINE=()
  CL_PARSE_ERRORS=0
  if [[ ! -f "$file" ]]; then
    cl_err "no such ledger: $file"
    CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$(( n + 1 ))
    trimmed="$(cl_trim "$line")"
    [[ -z "$trimmed" ]] && continue
    case "$trimmed" in '#'*) continue ;; esac
    indented=0
    case "$line" in [[:space:]]*) indented=1 ;; esac

    if (( indented == 0 )); then
      # ── column 0: GROUP: or an identity ──
      if [[ "$trimmed" == GROUP:* ]]; then
        pending_name="$(cl_trim "${trimmed#GROUP:}")"
        if [[ -z "$pending_name" ]]; then
          cl_err "$file:$n: GROUP: with an empty name — a group must be named"
          CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
        fi
        force_new=1
        continue
      fi
      if ! cl_valid_identity "$trimmed"; then
        cl_err "$file:$n: not an entry identity and not a GROUP: line — '$trimmed'"
        CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
        continue
      fi
      if [[ -n "${CL_IDENT_ENTRY[$trimmed]:-}" ]]; then
        prev="${CL_IDENT_LINE[$trimmed]}"
        cl_err "$file:$n: duplicate entry for $trimmed (first at $file:$prev)"
        CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
        continue
      fi
      # A run of CONSECUTIVE identities shares one classification. Anything
      # indented in between ends the run, so the next identity opens a new entry.
      if (( cur < 0 || body_seen == 1 || force_new == 1 )); then
        cur=${#CL_ENTRY_CLASS[@]}
        CL_ENTRY_CLASS+=("")
        CL_ENTRY_REASON+=("")
        CL_ENTRY_NAME+=("$pending_name")
        pending_name=""
        force_new=0
        body_seen=0
      fi
      CL_IDENTS+=("$trimmed")
      # +1: an empty string would be indistinguishable from "absent" under -u.
      CL_IDENT_ENTRY["$trimmed"]=$(( cur + 1 ))
      CL_IDENT_LINE["$trimmed"]="$n"
      continue
    fi

    # ── indented: the current entry's body ──
    if (( cur < 0 )); then
      cl_err "$file:$n: indented text before any entry identity — '$trimmed'"
      CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
      continue
    fi
    body_seen=1
    first="${trimmed%%:*}"
    marker=""
    case " $CL_MARKERS " in
      *" $first "*) [[ "$trimmed" == "$first":* ]] && marker="$first" ;;
    esac
    if [[ -n "$marker" ]]; then
      if [[ -n "${CL_ENTRY_CLASS[cur]}" ]]; then
        cl_err "$file:$n: a second classification ($marker:) for an entry already classified ${CL_ENTRY_CLASS[cur]}: — one entry carries one classification"
        CL_PARSE_ERRORS=$(( CL_PARSE_ERRORS + 1 ))
        continue
      fi
      CL_ENTRY_CLASS[cur]="$marker"
      rest="$(cl_trim "${trimmed#"$marker":}")"
      CL_ENTRY_REASON[cur]="$rest"
      continue
    fi
    # Everything indented AFTER the marker continues the reason; before it, it
    # is context (the original line) and is not read.
    if [[ -n "${CL_ENTRY_CLASS[cur]}" ]]; then
      CL_ENTRY_REASON[cur]="$(cl_trim "${CL_ENTRY_REASON[cur]} $trimmed")"
    fi
  done < "$file"
  (( CL_PARSE_ERRORS == 0 ))
}

# ── check A: classification is present and its reason is non-empty ────────────
cl_check_classification() {   # <ledger file>
  local ident idx
  for ident in "${CL_IDENTS[@]}"; do
    idx=$(( ${CL_IDENT_ENTRY[$ident]} - 1 ))
    if [[ -z "${CL_ENTRY_CLASS[idx]}" ]]; then
      cl_err "$ident ($1:${CL_IDENT_LINE[$ident]}) has no GAP:/EQUIVALENT: classification — a survivor recorded without one is a hole landing silently"
    elif [[ -z "${CL_ENTRY_REASON[idx]}" ]]; then
      cl_err "$ident ($1:${CL_IDENT_LINE[$ident]}) has an empty ${CL_ENTRY_CLASS[idx]}: reason — an empty reason suppresses nothing"
    fi
  done
}

# ── the run output ────────────────────────────────────────────────────────────
declare -A CL_SURVIVED=()    # identity → count of DISTINCT surviving damages
declare -A CL_UNPROVEN=()    # identity → 1 when at least one record was UNPROVEN
declare -A CL_SEEN=()        # identity → 1 when the run generated it at all
declare -A CL_SURV_TEXT=()   # "identity|text" → 1, the F10 dedupe key
declare -A CL_SCOPE=()       # target file → 1
CL_MUTANTS=0

cl_read_run() {   # <run output file or ->
  local src="$1" line rest verdict ident text target
  CL_SURVIVED=(); CL_SEEN=(); CL_SURV_TEXT=(); CL_SCOPE=(); CL_MUTANTS=0
  CL_UNPROVEN=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'TARGET|'*)
        rest="${line#TARGET|}"
        target="${rest%%|*}"
        [[ -n "$target" ]] && CL_SCOPE["$target"]=1
        ;;
      'MUTANT|'*)
        # The mutated line is the LAST field and may itself contain `|`, so the
        # first eight fields are peeled off and the remainder taken verbatim —
        # exactly what run.sh's header specifies a parser must do.
        rest="${line#MUTANT|}"
        verdict="${rest%%|*}"; rest="${rest#*|}"
        ident="${rest%%|*}";   rest="${rest#*|}"
        rest="${rest#*|}"   # oracle
        rest="${rest#*|}"   # seq
        rest="${rest#*|}"   # lineno
        rest="${rest#*|}"   # signal
        rest="${rest#*|}"   # ms
        text="$rest"
        [[ -n "$ident" ]] || continue
        CL_MUTANTS=$(( CL_MUTANTS + 1 ))
        CL_SEEN["$ident"]=1
        # UNPROVEN is treated exactly like SURVIVED here, and that is the whole
        # point of the verdict existing. Both name a place where NOTHING was
        # observed asserting — a survivor because no assertion fired, an
        # unproven because the oracle never finished. Letting UNPROVEN through
        # unclassified would reopen the hole the verdict was added to close: a
        # slow oracle quietly retiring a mutant nobody ever demonstrated a test
        # against. See run.sh's falsify_verdict note.
        if [[ "$verdict" == "SURVIVED" || "$verdict" == "UNPROVEN" ]]; then
          if [[ -z "${CL_SURV_TEXT["$ident|$text"]:-}" ]]; then
            CL_SURV_TEXT["$ident|$text"]=1
            CL_SURVIVED["$ident"]=$(( ${CL_SURVIVED[$ident]:-0} + 1 ))
          fi
          # Remember WHICH it was, so the finding names what actually happened.
          # "SURVIVED" on an unproven mutant would send a reader hunting for a
          # missing assertion when the truth is that the oracle never finished.
          [[ "$verdict" == "UNPROVEN" ]] && CL_UNPROVEN["$ident"]=1
        fi
        ;;
    esac
  done < <(if [[ "$src" == "-" ]]; then cat; else cat "$src"; fi)
}

cl_in_scope() {   # <identity> → 0 when this run measured that identity's file
  local file="${1%%:*}"
  [[ -n "${CL_SCOPE[$file]:-}" ]]
}

# ── checks B, C, D ────────────────────────────────────────────────────────────
cl_check_run() {   # <ledger file>
  local ident skipped=0
  # B: every survivor is written down. Sorted, so a run's findings are stable
  # across the arbitrary iteration order of an associative array.
  while IFS= read -r ident; do
    [[ -n "$ident" ]] || continue
    if [[ -z "${CL_IDENT_ENTRY[$ident]:-}" ]]; then
      local what="SURVIVED"
    [[ -n "${CL_UNPROVEN[$ident]:-}" ]] \
      && what="UNPROVEN (the oracle never finished; nothing was observed asserting)"
    cl_err "$ident $what (${CL_SURVIVED[$ident]} distinct mutant(s)) but has no entry in $1 — every survivor must be classified GAP: or EQUIVALENT:"
    fi
  done < <(printf '%s\n' "${!CL_SURVIVED[@]}" | sort)
  # C and D: every in-scope entry still describes a live, still-surviving mutant.
  for ident in "${CL_IDENTS[@]}"; do
    if ! cl_in_scope "$ident"; then
      skipped=$(( skipped + 1 ))
      cl_note "SKIPPED $ident — ${ident%%:*} was not among this run's targets"
      continue
    fi
    if [[ -z "${CL_SEEN[$ident]:-}" ]]; then
      cl_err "$ident is a ledger entry ($1:${CL_IDENT_LINE[$ident]}) for a mutant that no longer exists — stale, delete it"
    elif [[ -z "${CL_SURVIVED[$ident]:-}" ]]; then
      cl_err "$ident is a ledger entry ($1:${CL_IDENT_LINE[$ident]}) for a mutant that is now KILLED — obsolete amnesty, delete it"
    fi
  done
  (( skipped > 0 )) && cl_note "$skipped ledger entr(y/ies) skipped: outside this run's ${#CL_SCOPE[@]} target(s)"
  return 0
}

cl_list() {
  local ident idx
  for ident in "${CL_IDENTS[@]}"; do
    idx=$(( ${CL_IDENT_ENTRY[$ident]} - 1 ))
    printf '%s|%s|%s|%s\n' "$ident" "${CL_ENTRY_CLASS[idx]}" \
      "${CL_ENTRY_NAME[idx]}" "${CL_ENTRY_REASON[idx]}"
  done
}

cl_usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cl_main() {
  local run_output="" mode="full"
  while (( $# > 0 )); do
    case "$1" in
      --ledger) CL_LEDGER="${2:-}"; shift 2 || return 2 ;;
      --run-output) run_output="${2:-}"; shift 2 || return 2 ;;
      --lint) mode="lint"; shift ;;
      --list) mode="list"; shift ;;
      -h|--help) cl_usage; return 0 ;;
      *) printf 'ERROR: unknown option: %s\n' "$1" >&2; cl_usage >&2; return 2 ;;
    esac
  done
  cl_load_operators || return 2
  if [[ "$mode" == "full" && -z "$run_output" ]]; then
    printf 'ERROR: --run-output is required (use --lint to check the ledger alone) — a gate given no run output must not report success\n' >&2
    return 2
  fi

  cl_parse_ledger "$CL_LEDGER"

  if [[ "$mode" == "list" ]]; then
    cl_list
    (( CL_FINDINGS == 0 )) || return 1
    return 0
  fi

  cl_check_classification "$CL_LEDGER"

  if [[ "$mode" == "full" ]]; then
    cl_read_run "$run_output"
    if (( ${#CL_SCOPE[@]} == 0 )); then
      printf 'ERROR: the run output carries no TARGET| line — refusing to check the ledger against a run that measured nothing\n' >&2
      return 2
    fi
    cl_check_run "$CL_LEDGER"
    cl_note "$CL_MUTANTS mutant record(s), ${#CL_SURVIVED[@]} surviving identit(y/ies), ${#CL_IDENTS[@]} ledger entr(y/ies)"
  fi

  if (( CL_FINDINGS > 0 )); then
    printf '%s problem(s)\n' "$CL_FINDINGS"
    return 1
  fi
  printf 'OK: 0 problem(s) — %s ledger entr(y/ies)\n' "${#CL_IDENTS[@]}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  cl_main "$@"
  exit $?
fi
