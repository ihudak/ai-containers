#!/usr/bin/env bash
# tests/falsify/derive-targets.sh — derive which repo scripts the HERMETIC suite
# actually EXECUTES, and gate tests/falsify/targets.conf against that derivation.
#
# WHY THIS EXISTS: mutating a file only proves something if the suite RUNS that
# file's code. A test that merely greps a file's text kills no mutant — every
# one of them survives, and a mutation tier fed by a hand-written target list
# would report that survival as an assertion gap. It is not: it is a
# classification error in the list. So the list is DERIVED here and CHECKED
# against, never trusted.
#
# WHAT COUNTS AS EXECUTION, and what deliberately does not:
#   counts       source/. <file>            (the file's code runs in-process)
#                bash/sh <file>             (the file's code runs as a child)
#                "$VAR" / ./x.sh at command position (ditto)
#                a symlink or copy of a repo file, invoked under its new name
#                  (tests/test-integration-shim.sh reaches docker-shim.sh ONLY
#                   through `ln -sf "$SHIM" "$TMP/bin/docker"`)
#                a path printf'd INTO A FILE as a source/bash line
#                  (tests/test-lib-verify-repo.sh:79 builds its harness with
#                   `printf 'source %q\n' "$REPO_DIR/tests/lib-verify-repo.sh"
#                   >> "$h"`, which is that library's ONLY dedicated oracle)
#                a path handed to `bash -c BODY _ <path>` whose body runs it as
#                  "$1"/"$@" (tests/test-parsers.sh and tests/test-tools-d.sh
#                   reach sandbox.sh only this way)
#                transitively: what an executed file itself executes
#   never        bash -n <file>             (parses; runs nothing)
#                a grep/sed/awk/cat/shellcheck read of <file>  (text, not code)
#                a heredoc BODY that happens to contain shell syntax
#                a stub fake written into a scratch repo under a repo file's
#                  name — see OPAQUE below
#
# OPAQUE nodes stop the transitive walk. verify-on-host.sh is one: the hermetic
# suite runs the REAL verify-on-host.sh, but tests/lib-verify-repo.sh builds it
# a scratch repo whose tests/run-all.sh, check-sandbox-version.sh and
# bash-dialect-lint.sh are instrumented STUBS. Walking through it would credit
# those three with an execution that never happened — the exact
# misclassification this file exists to prevent.
#
# RESOLUTION IS TEXTUAL, and the trade-off is deliberate: over-approximating
# costs one explicit `#EXCLUDED|` row with a reason, while under-approximating
# would silently drop a target from the tier. Precision is spent where a false
# positive would be dangerous instead of merely noisy: `bash -n` is vetoed per
# TOKEN, not per line, because a `bash -n "$X"`-only reference wrongly read as
# execution would let a grepped-only file in as an active mutation target.
#
# The two run-time shapes above are read COARSELY for that same reason. The
# printf rule does not verify that the file written is later executed, and the
# argv rule hands every argument of a `bash -c` to the body rather than binding
# the positionals. Binding them properly was tried on paper and still misses
# both shapes this repo actually contains — a body that copies "$1" into a
# local before sourcing it, and one that `shift`s before `exec bash "$@"` — so
# the coarse rule is not a shortcut to the precise one; it is the one that
# works. What keeps it honest is the direction of the error: it can only ever
# ADD an executor, and an added executor shows up as an evidence line naming
# the exact file:line that produced it.
#
# Usage:
#   derive-targets.sh                 # <target>|EXECUTED|<oracles>  per candidate
#   derive-targets.sh --all           # ... plus the out-of-scope candidates
#   derive-targets.sh --evidence      # every resolved reference, with file:line
#   derive-targets.sh --scope         # the scope rules and their reasons
#   derive-targets.sh --rows [conf]   # targets.conf parsed into uniform records
#   derive-targets.sh --check [conf]  # gate targets.conf against the derivation
#
# Env overrides (used by tests/test-falsify-targets.sh to drive the derivation
# against a synthetic fixture repo, so the derivation itself is falsifiable):
#   FALSIFY_REPO        repo root to derive over          (default: this repo)
#   FALSIFY_TESTS_DIR   directory holding test-*.sh       (default: $REPO/tests)
#   FALSIFY_CONF        default conf for --check
#   FALSIFY_DERIVED     reuse a derivation already computed (test accelerator)
set -uo pipefail

_ft_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FT_TESTS_DIR="${FALSIFY_TESTS_DIR:-$(dirname "$_ft_here")}"
FT_REPO="${FALSIFY_REPO:-$(dirname "$FT_TESTS_DIR")}"
FT_CONF_DEFAULT="${FALSIFY_CONF:-$_ft_here/targets.conf}"
FT_MAXDEPTH=3

FT_CATEGORIES="EXECUTED-WHOLE EXECUTED-PARTIAL GREPPED-ONLY"

# The shape of a well-formed oracle field: one or more test basenames separated
# by single commas. The character class is a WHITELIST rather than "anything but
# a comma or a space", so a glob metacharacter cannot reach the field at all —
# the split below is an array read for the same reason, and a rule that holds
# structurally beats one that holds because of how the value happens to be
# consumed. Held as a variable because a regex written inline at the `=~` would
# have to survive quoting rules that differ between bash versions.
FT_ORACLE_RE='^[A-Za-z0-9._+-]+(,[A-Za-z0-9._+-]+)*$'

# Nodes whose outbound references are stubbed out by the harness that runs them.
FT_OPAQUE="verify-on-host.sh"
FT_OPAQUE_WHY="tests/lib-verify-repo.sh runs the real script against a scratch repo whose checks are instrumented stubs, so its outbound references execute fakes, not repo files"

declare -A D_VMAP=()      # "<file>|<NAME>" → first literal assignment
declare -A D_VMAP_DONE=()  # files whose var map has been read
declare -A D_ALIAS=()     # "<file>|<dest>" → <src> (ln/cp/install/rsync)
declare -A D_HITS=()      # "<candidate>" → " oracle oracle "
declare -A D_VISITED=()   # "<oracle>|<file>"
declare -A D_BASENAME=()  # basename → candidate path (unique ones only)
declare -A D_ISCAND=()    # candidate path → 1
D_EVIDENCE=()
FT_CANDIDATES=()

# ── Scope ─────────────────────────────────────────────────────────────────────
# Out-of-scope candidates are PRINTED (with --all), never silently dropped: a
# hidden allowlist inside the deriver would defeat the map it is checking.
ft_scope_rules() {
  cat <<'SCOPE'
in-scope|every tracked *.sh not excluded below
out-of-scope|tests/test-*.sh|the ORACLES themselves; mutating an oracle measures the oracle's oracle, which is Task 9's meta-tier, not this one
out-of-scope|tests/integration/cases/*|integration cases, not hermetic-suite code; their mutation tier already exists as tests/integration/mutations/
out-of-scope|tests/falsify/*|the mutation tier's own machinery; a tier that mutates itself is self-referential, and Task 9's meta-tier owns that question
SCOPE
}

_ft_out_of_scope() {  # $1=repo-relative path → 0 if out of scope
  case "$1" in
    tests/test-*.sh|*/tests/test-*.sh) return 0 ;;
    tests/integration/cases/*|*/tests/integration/cases/*) return 0 ;;
    tests/falsify/*|*/tests/falsify/*) return 0 ;;
  esac
  return 1
}

_ft_all_scripts() {  # every tracked *.sh, repo-relative; find-fallback for a non-git fixture repo
  local out
  out="$(git -C "$FT_REPO" ls-files '*.sh' 2>/dev/null)"
  if [[ -z "$out" ]]; then
    out="$(cd "$FT_REPO" && find . -name '*.sh' -type f | sed 's|^\./||' | sort)"
  fi
  printf '%s\n' "$out"
}

ft_candidates() { printf '%s\n' "${FT_CANDIDATES[@]}"; }

_ft_load_candidates() {
  local p b
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    _ft_out_of_scope "$p" && continue
    FT_CANDIDATES+=("$p")
    D_ISCAND["$p"]=1
    b="${p##*/}"
    if [[ -n "${D_BASENAME[$b]:-}" ]]; then
      D_BASENAME["$b"]="AMBIGUOUS"
    else
      D_BASENAME["$b"]="$p"
    fi
  done < <(_ft_all_scripts)
  if [[ "${#FT_CANDIDATES[@]}" -eq 0 ]]; then
    echo "derive-targets.sh: no candidate scripts found under $FT_REPO" >&2
    return 1
  fi
}

# ── Reference extraction ──────────────────────────────────────────────────────
# A quote-aware tokeniser plus a command-position walk, in awk. Emits one
# `<lineno>\t<kind>\t<arg>\t<arg2>` record per reference; kinds are source,
# bash, exec and alias (alias carries dest in arg and src in arg2).
_ft_refs() {  # $1 = absolute file
  awk '
    BEGIN { SQ = sprintf("%c", 39) }   # a single quote, unwritable inline here
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

    # Quote-aware, with a stack for command substitution: `"$(cmd arg)"` opens a
    # fresh UNQUOTED context inside a double-quoted string, exactly as the shell
    # does. Without the stack, `out="$(bash "$MUTATE" list)"` collapsed into one
    # token (spaces are literal inside quotes) and every reference inside a
    # command substitution was invisible. QEND carries the quote state at
    # end-of-line so the caller can skip a multi-line single-quoted STRING,
    # which is data, not code.
    function tokenize(line, T,    i, L, c, cur, started, q, n, sp, st) {
      n = 0; cur = ""; started = 0; q = ""; sp = 0
      L = length(line)
      for (i = 1; i <= L; i++) {
        c = substr(line, i, 1)
        if (q == SQ) { if (c == SQ) { q = "" } else { cur = cur c } started = 1; continue }
        if (q == "\"") {
          if (c == "\"") { q = ""; started = 1; continue }
          if (c == "$" && substr(line, i + 1, 1) == "(") {
            if (started) { T[++n] = cur; cur = ""; started = 0 }
            st[++sp] = q; q = ""
            T[++n] = ";"; i++; continue
          }
          cur = cur c; started = 1; continue
        }
        if (c == "\\") { i++; cur = cur substr(line, i, 1); started = 1; continue }
        if (c == SQ || c == "\"") { q = c; started = 1; continue }
        if (c == "#" && !started) { break }
        if (c == " " || c == "\t") { if (started) { T[++n] = cur; cur = ""; started = 0 } continue }
        if (c == "$" && substr(line, i + 1, 1) == "(") {
          if (started) { T[++n] = cur; cur = ""; started = 0 }
          st[++sp] = q; q = ""
          T[++n] = ";"; i++; continue
        }
        if (c == ")") {
          if (started) { T[++n] = cur; cur = ""; started = 0 }
          if (sp > 0) { q = st[sp--] }
          T[++n] = ";"; continue
        }
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == "{" || c == "}" || c == "`") {
          if (started) { T[++n] = cur; cur = ""; started = 0 }
          T[++n] = ";"; continue
        }
        cur = cur c; started = 1
      }
      if (started) T[++n] = cur
      QEND = q
      return n
    }

    function iskw(t) {
      return (t == "if" || t == "then" || t == "else" || t == "elif" || t == "fi" ||
              t == "while" || t == "until" || t == "do" || t == "done" || t == "!" ||
              t == "exec" || t == "command" || t == "time" || t == "nohup" || t == "eval")
    }
    function isassign(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }
    function ispath(t)   { return (t ~ /\// || t ~ /\$/) }

    # Every reference is printed through here, so DOLLARSEEN records the one
    # fact the argv rule below turns on: the walker met a command whose target
    # it cannot name literally.
    function emitref(ln, kind, a) {
      print ln "\t" kind "\t" a "\t"
      if (a ~ /\$/) DOLLARSEEN = 1
    }

    # `bash -c BODY _ ARG…` — the body names its input as "$1" or "$@", so the
    # only place the real path is written is ARG. Emitted as kind `argv`, and
    # deliberately COARSE: binding the positionals properly would still miss
    # both shapes this repo actually uses — a body that copies "$1" into a
    # local before sourcing it (tests/test-parsers.sh:79) and a body that
    # shifts before `exec bash "$@"` (tests/test-tools-d.sh:806) — while a
    # rule that simply reads the arguments catches both. Guarded by
    # DOLLARSEEN, so a `bash -c` body that names its target literally does not
    # also drag its arguments in.
    function emit_argv(T, from, n, ln,    k) {
      for (k = from; k <= n; k++) {
        if (T[k] == ";") return
        if (T[k] ~ /^[0-9]*[<>]/ || T[k] ~ /^-/) continue
        if (ispath(T[k])) print ln "\t" "argv" "\t" T[k] "\t"
      }
    }

    # A file redirect is what separates a printf that WRITES A SCRIPT from the
    # hundreds whose text is prose for a human. `>&2` and `2>&1` tokenise as a
    # bare `>`/`2>` followed by the `&` separator, so neither counts.
    function has_file_redirect(T, from, n,    k) {
      for (k = from; k <= n; k++) {
        if (T[k] == ";") return 0
        if (T[k] ~ /^[0-9]*>>?$/) { if (k < n && T[k + 1] != ";") return 1; continue }
        if (T[k] ~ /^[0-9]*>>?./) return 1
      }
      return 0
    }

    # Rebuild what a `printf FMT ARG…`/`echo` would actually write: %-directives
    # consume the arguments in order, `\n` becomes a command separator so each
    # emitted line lands at a command position, and the format repeats while
    # arguments remain, exactly as printf does. The result is walked as code.
    function printf_synth(T, from, n,    k, na, A, ai, prev, out, i2, c, L, fmt) {
      na = 0
      for (k = from; k <= n; k++) {
        if (T[k] == ";") break
        if (T[k] ~ /^[0-9]*[<>]/) break
        if (na == 0 && T[k] ~ /^-/) continue
        A[++na] = T[k]
      }
      if (na == 0) return ""
      fmt = A[1]; L = length(fmt); out = ""; ai = 1
      do {
        prev = ai
        for (i2 = 1; i2 <= L; i2++) {
          c = substr(fmt, i2, 1)
          if (c == "\\") { i2++; c = substr(fmt, i2, 1); out = out ((c == "n") ? " ; " : " "); continue }
          if (c == "%") {
            if (substr(fmt, i2 + 1, 1) == "%") { i2++; out = out "%"; continue }
            i2++
            while (i2 <= L && substr(fmt, i2, 1) ~ /[-+ #0-9.*]/) i2++
            out = out (++ai <= na ? A[ai] : "")
            continue
          }
          out = out c
        }
        if (ai == prev) break
      } while (ai < na)
      return out
    }

    function walk(T, n, ln, depth, cmd0,    i, t, j, k, veto, m, cmd, U, S, ns) {
      i = 1; cmd = (cmd0 ? 0 : 1)
      while (i <= n) {
        t = T[i]
        if (t == ";") { cmd = 1; i++; continue }
        if (!cmd) { i++; continue }
        if (isassign(t) || iskw(t)) { i++; continue }
        if (t == "env") {
          i++
          while (i <= n && (T[i] ~ /^-/ || isassign(T[i]))) { if (T[i] == "-u") i++; i++ }
          continue
        }
        if (t == "source" || t == ".") {
          j = i + 1
          while (j <= n && T[j] ~ /^-/) j++
          if (j <= n && T[j] != ";") { emitref(ln, "source", T[j]) }
          cmd = 0; i = j + 1; continue
        }
        if (t == "bash" || t == "sh") {
          veto = 0; j = i + 1
          while (j <= n && T[j] ~ /^-/) {
            # -n parses without running: NOT an execution, vetoed per token.
            if (T[j] ~ /^-[A-Za-z]*n/) veto = 1
            if (T[j] == "-c") {
              if (!veto && j + 1 <= n && depth < 2) {
                DOLLARSEEN = 0
                m = tokenize(T[j + 1], U); walk(U, m, ln, depth + 1, 0); delete U
                if (DOLLARSEEN) emit_argv(T, j + 2, n, ln)
              }
              veto = 1; j = j + 2
              break
            }
            j++
          }
          if (!veto && j <= n && T[j] != ";") { emitref(ln, "bash", T[j]) }
          cmd = 0; i = j + 1; continue
        }
        if (t == "ln" || t == "cp" || t == "install" || t == "rsync") {
          ns = 0; j = i + 1
          while (j <= n && T[j] != ";") { if (T[j] !~ /^-/) { S[++ns] = T[j] } j++ }
          if (ns >= 2) { for (k = 1; k < ns; k++) print ln "\t" "alias" "\t" S[ns] "\t" S[k] }
          delete S
          cmd = 0; i = j; continue
        }
        if (t == "printf" || t == "echo") {
          if (depth < 2 && has_file_redirect(T, i + 1, n)) {
            S2 = printf_synth(T, i + 1, n)
            if (S2 != "") { m = tokenize(S2, U); walk(U, m, ln, depth + 1, 0); delete U }
          }
          cmd = 0; i++; continue
        }
        if (ispath(t)) { emitref(ln, "exec", t); cmd = 0; i++; continue }
        cmd = 0; i++
      }
    }

    {
      raw = $0; start = FNR
      # Join line continuations so a reference split across lines is still seen.
      while (raw ~ /\\$/) {
        if ((getline nxt) <= 0) break
        sub(/\\[ \t]*$/, " ", raw); raw = raw nxt
      }
      if (hd != "") { if (trim(raw) == hd) hd = ""; next }
      # ── multi-line single-quoted strings ──────────────────────────────────
      # A single-quoted string spanning lines is one of two things, and the
      # difference decides whether its contents are executions:
      #
      #   DATA  an awk program, or a harness body written to a file. Skipped.
      #         tests/test-entrypoint-wiring.sh:20 is why: a multi-line awk
      #         program whose LAST line then names entrypoint.sh as the awk
      #         input file, which read as code looks like executing it. And
      #         tests/test-lib-verify-repo.sh:297 names $r/tests/run-all.sh —
      #         the instrumented STUB planted in a scratch repo, not the real
      #         tests/run-all.sh.
      #   CODE  a `bash -c` body. Walked line by line.
      #         tests/test-allowlists.sh:172 sources sandbox-common.sh and
      #         build.sh from inside one.
      #
      # Either way the STATE is tracked to the closing quote, so the quote that
      # ends a two-line body is never mistaken for one that opens a new string.
      if (insq) {
        p = index(raw, SQ)
        if (insq_code) {
          body = (p == 0 ? raw : substr(raw, 1, p - 1))
          n = tokenize(body, T); walk(T, n, start, 0, 0); delete T
        }
        if (p == 0) next
        raw = substr(raw, p + 1)
        # A `bash -c` body that spans lines puts its ARGUMENTS after the closing
        # quote; same rule as the single-line form, just reached from here.
        if (insq_code && DOLLARSEEN) { na = tokenize(raw, A); emit_argv(A, 1, na, start); delete A }
        insq = 0
        # Text after a closing quote continues the arguments of the SAME
        # command; it is not a fresh command position.
        resumed = 1
      }
      if (raw ~ /^[ \t]*#/) next
      if (match(raw, "<<-?[ \t]*[\"" SQ "]?[A-Za-z_][A-Za-z0-9_]*")) {
        w = substr(raw, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", w); gsub(/["]/, "", w); gsub(SQ, "", w)
        hd = w
      }
      n = tokenize(raw, T)
      if (QEND == SQ) {
        insq = 1; insq_at = start
        insq_code = (raw ~ /(bash|sh)[ \t]+-[A-Za-z]*c/)
      }
      walk(T, n, start, 0, resumed)
      resumed = 0
      delete T
    }
    END {
      # Under-approximating is the dangerous direction — a target silently
      # dropped from the map — so an unterminated string is reported, never
      # swallowed.
      if (insq && !insq_code) {
        printf "derive-targets.sh: WARNING: %s ends inside the single-quoted string opened at line %d; later references were not scanned\n", FILENAME, insq_at > "/dev/stderr"
      }
    }
  ' "$1"
}

_ft_load_vmap() {  # $1 = absolute file, $2 = map key
  local f="$1" key="$2" line name val
  [[ -z "${D_VMAP_DONE[$key]:-}" ]] || return 0
  D_VMAP_DONE["$key"]=1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
    case "$val" in
      '"'*) val="${val#\"}"; val="${val%%\"*}" ;;
      "'"*) val="${val#\'}"; val="${val%%\'*}" ;;
      *)    val="${val%%[[:space:];]*}" ;;
    esac
    # A value built by a command substitution is not resolvable textually; leave
    # the variable unexpanded and let suffix/basename matching do the work.
    case "$val" in *'$('*|*'`'*|'') continue ;; esac
    [[ -n "${D_VMAP["$key|$name"]:-}" ]] || D_VMAP["$key|$name"]="$val"
  done < "$f"
}

_ft_expand() {  # $1=map key, $2=ref → ref with resolvable vars expanded
  local key="$1" s="$2" i pre name post val
  for ((i = 0; i < 8; i++)); do
    [[ "$s" =~ ^([^$]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$ ]] || break
    pre="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; post="${BASH_REMATCH[3]}"
    val="${D_VMAP["$key|$name"]:-}"
    [[ -n "$val" ]] || break
    s="$pre$val$post"
  done
  printf '%s' "$s"
}

_ft_norm() {  # $1=path-ish string → normalised
  local s="$1"
  while [[ "$s" == *//* ]]; do s="${s//\/\//\/}"; done
  s="${s#./}"; s="${s%/}"
  printf '%s' "$s"
}

_ft_match() {  # $1=map key, $2=expanded ref, $3=alias hops → candidate path or ""
  local key="$1" s b c hops="${3:-0}" via
  s="$(_ft_norm "$2")"
  [[ -n "$s" ]] || return 0
  for c in "${FT_CANDIDATES[@]}"; do
    if [[ "$s" == "$c" || "$s" == *"/$c" ]]; then printf '%s' "$c"; return 0; fi
  done
  via="${D_ALIAS["$key|$s"]:-}"
  if [[ -n "$via" && "$hops" -lt 3 ]]; then
    _ft_match "$key" "$via" "$((hops + 1))"
    return 0
  fi
  b="${s##*/}"
  c="${D_BASENAME[$b]:-}"
  if [[ -n "$c" && "$c" != "AMBIGUOUS" ]]; then printf '%s' "$c"; return 0; fi
  return 0
}

_ft_is_opaque() {  # $1=candidate
  local o
  for o in $FT_OPAQUE; do [[ "$1" == "$o" || "$1" == */"$o" ]] && return 0; done
  return 1
}

_ft_walk_file() {  # $1=absolute file, $2=map key, $3=oracle, $4=depth
  local f="$1" key="$2" oracle="$3" depth="$4"
  local lineno kind a1 a2 exp hit dest src
  [[ -f "$f" ]] || return 0
  [[ -z "${D_VISITED["$oracle|$f"]:-}" ]] || return 0
  D_VISITED["$oracle|$f"]=1
  _ft_load_vmap "$f" "$key"
  # Alias edges first: a later reference may resolve only through one of them.
  while IFS=$'\t' read -r lineno kind a1 a2; do
    [[ "$kind" == "alias" ]] || continue
    dest="$(_ft_norm "$(_ft_expand "$key" "$a1")")"
    src="$(_ft_expand "$key" "$a2")"
    [[ -n "$dest" && -n "$src" ]] || continue
    D_ALIAS["$key|$dest"]="$src"
    D_ALIAS["$key|$dest/${src##*/}"]="$src"
  done < <(_ft_refs "$f")
  while IFS=$'\t' read -r lineno kind a1 a2; do
    case "$kind" in source|bash|exec|argv) ;; *) continue ;; esac
    exp="$(_ft_expand "$key" "$a1")"
    hit="$(_ft_match "$key" "$exp")"
    [[ -n "$hit" ]] || continue
    case " ${D_HITS[$hit]:-} " in
      *" $oracle "*) ;;
      *) D_HITS["$hit"]="${D_HITS[$hit]:-}${D_HITS[$hit]:+ }$oracle" ;;
    esac
    D_EVIDENCE+=("$hit|$oracle|${f#"$FT_REPO"/}:$lineno|$kind|$exp")
    if [[ "$depth" -lt "$FT_MAXDEPTH" ]] && ! _ft_is_opaque "$hit"; then
      _ft_walk_file "$FT_REPO/$hit" "$hit" "$oracle" "$((depth + 1))"
    fi
  done < <(_ft_refs "$f")
}

# A derivation costs a few seconds (it walks every hermetic test). FALSIFY_DERIVED
# lets a caller supply one already computed, in this file's own default output
# format, so tests/test-falsify-targets.sh can drive a dozen negative fixtures
# against ONE derivation. It is an accelerator, never the gate: the test also
# runs --check with no cache at all, and CI only ever runs it that way.
_ft_load_derived() {  # $1 = a file of <target>|EXECUTED|<oracles> lines
  local f="$1" target verdict oracles b
  while IFS='|' read -r target verdict oracles; do
    [[ -n "$target" ]] || continue
    [[ "$verdict" == "OUT-OF-SCOPE" ]] && continue
    FT_CANDIDATES+=("$target")
    D_ISCAND["$target"]=1
    b="${target##*/}"
    if [[ -n "${D_BASENAME[$b]:-}" ]]; then D_BASENAME["$b"]="AMBIGUOUS"; else D_BASENAME["$b"]="$target"; fi
    [[ "$verdict" == "EXECUTED" ]] && D_HITS["$target"]="${oracles//,/ }"
  done < "$f"
  if [[ "${#FT_CANDIDATES[@]}" -eq 0 ]]; then
    echo "derive-targets.sh: FALSIFY_DERIVED=$f held no verdict rows" >&2
    return 1
  fi
}

ft_derive() {
  local t base
  if [[ -n "${FALSIFY_DERIVED:-}" ]]; then
    if [[ ! -s "${FALSIFY_DERIVED}" ]]; then
      echo "derive-targets.sh: FALSIFY_DERIVED=$FALSIFY_DERIVED is missing or empty" >&2
      return 1
    fi
    _ft_load_derived "$FALSIFY_DERIVED"
    return
  fi
  _ft_load_candidates || return 1
  local -a tests=()
  while IFS= read -r t; do [[ -n "$t" ]] && tests+=("$t"); done \
    < <(find "$FT_TESTS_DIR" -maxdepth 1 -name 'test-*.sh' -type f | sort)
  if [[ "${#tests[@]}" -eq 0 ]]; then
    echo "derive-targets.sh: no test-*.sh files under $FT_TESTS_DIR" >&2
    return 1
  fi
  for t in "${tests[@]}"; do
    base="${t##*/}"
    _ft_walk_file "$t" "$base" "$base" 0
  done
}

ft_print_verdicts() {  # $1 = "all" to include out-of-scope rows
  local c p
  for c in "${FT_CANDIDATES[@]}"; do
    if [[ -n "${D_HITS[$c]:-}" ]]; then
      printf '%s|EXECUTED|%s\n' "$c" "$(printf '%s' "${D_HITS[$c]}" | tr ' ' ',')"
    else
      printf '%s|NOT-EXECUTED|\n' "$c"
    fi
  done | sort
  [[ "${1:-}" == "all" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    _ft_out_of_scope "$p" && printf '%s|OUT-OF-SCOPE|\n' "$p"
  done < <(_ft_all_scripts) | sort
}

ft_print_evidence() {
  [[ "${#D_EVIDENCE[@]}" -gt 0 ]] || return 0
  printf '%s\n' "${D_EVIDENCE[@]}" | sort
}

# ── targets.conf ──────────────────────────────────────────────────────────────
# Row grammar (see the header of tests/falsify/targets.conf for the contract):
#   ACTIVE    <target>|<category>|<oracle>[|<functions>]
#   DEFERRED  #DEFERRED|<target>|<category>|<oracle>|<functions|->|<reason>
#   EXCLUDED  #EXCLUDED|<target>|<reason>
# Emits `<kind>|<lineno>|<target>|<category>|<oracle>|<functions>|<reason>`.
ft_conf_rows() {  # $1=conf
  local conf="$1" line n=0 rest
  local target category oracle funcs reason
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    case "$line" in
      '') continue ;;
      '#DEFERRED|'*)
        rest="${line#\#DEFERRED|}"
        IFS='|' read -r target category oracle funcs reason <<<"$rest"
        printf 'DEFERRED|%s|%s|%s|%s|%s|%s\n' "$n" "$target" "$category" "$oracle" "$funcs" "$reason"
        ;;
      '#EXCLUDED|'*)
        rest="${line#\#EXCLUDED|}"
        IFS='|' read -r target reason <<<"$rest"
        printf 'EXCLUDED|%s|%s||||%s\n' "$n" "$target" "$reason"
        ;;
      '#'*) continue ;;
      *)
        IFS='|' read -r target category oracle funcs <<<"$line"
        printf 'ACTIVE|%s|%s|%s|%s|%s|\n' "$n" "$target" "$category" "$oracle" "$funcs"
        ;;
    esac
  done < "$conf"
}

_ft_oracle_matches() {  # $1=oracle filter → count of tests/test-*.sh it selects
  local f n=0 b
  for f in "$FT_TESTS_DIR"/test-*.sh; do
    [[ -f "$f" ]] || continue
    b="${f##*/}"
    case "$b" in *"$1"*) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

ft_check() {  # $1=conf
  local conf="${1:-$FT_CONF_DEFAULT}"
  local kind lineno target category oracle funcs reason
  local problems=0 rows=0 executed=0 active=0 grepped=0 deferred=0 excluded=0 fn
  declare -A seen=()
  declare -A mapped=()

  if [[ ! -f "$conf" ]]; then
    printf 'ERROR: no such targets map: %s\n' "$conf" >&2
    return 1
  fi
  ft_derive || return 1

  while IFS='|' read -r kind lineno target category oracle funcs reason; do
    rows=$((rows + 1))
    if [[ -z "$target" ]]; then
      printf 'ERROR: %s:%s: row has no target field\n' "$conf" "$lineno" >&2
      problems=$((problems + 1)); continue
    fi
    if [[ -n "${seen[$target]:-}" ]]; then
      printf 'ERROR: %s:%s: duplicate row for %s (already at line %s)\n' \
        "$conf" "$lineno" "$target" "${seen[$target]}" >&2
      problems=$((problems + 1)); continue
    fi
    seen["$target"]="$lineno"

    if [[ -z "${D_ISCAND[$target]:-}" ]]; then
      printf 'ERROR: %s:%s: %s is not an in-scope candidate (missing file, or out of scope — see --scope)\n' \
        "$conf" "$lineno" "$target" >&2
      problems=$((problems + 1)); continue
    fi

    if [[ "$kind" == "EXCLUDED" ]]; then
      # An empty reason suppresses NOTHING: the target stays unmapped and the
      # executed-but-unmapped gate below names it, exactly like the repo's
      # `# dialect-lint: allow RULE-ID: reason` marker.
      if [[ -z "$(printf '%s' "$reason" | tr -d '[:space:]')" ]]; then
        printf 'ERROR: %s:%s: #EXCLUDED| for %s has an empty reason — an empty reason suppresses nothing\n' \
          "$conf" "$lineno" "$target" >&2
        problems=$((problems + 1)); continue
      fi
      mapped["$target"]="EXCLUDED"
      excluded=$((excluded + 1))
      continue
    fi

    if [[ "$kind" == "DEFERRED" && -z "$(printf '%s' "$reason" | tr -d '[:space:]')" ]]; then
      printf 'ERROR: %s:%s: #DEFERRED| for %s has an empty reason — a deferral must state why\n' \
        "$conf" "$lineno" "$target" >&2
      problems=$((problems + 1)); continue
    fi

    case " $FT_CATEGORIES " in
      *" $category "*) ;;
      *)
        printf 'ERROR: %s:%s: %s has unknown category %s (expected one of: %s)\n' \
          "$conf" "$lineno" "$target" "${category:-<empty>}" "$FT_CATEGORIES" >&2
        problems=$((problems + 1)); continue
        ;;
    esac
    mapped["$target"]="$category"
    if [[ "$kind" == "DEFERRED" ]]; then
      deferred=$((deferred + 1))
    elif [[ "$category" == "GREPPED-ONLY" ]]; then
      grepped=$((grepped + 1))
    else
      active=$((active + 1))
    fi

    # ── Gate: a mutation target the suite never executes is unkillable noise ──
    if [[ "$category" == EXECUTED-* && -z "${D_HITS[$target]:-}" ]]; then
      printf 'ERROR: %s:%s: %s is classified %s but the hermetic suite never EXECUTES it — every mutant would survive as noise; classify it GREPPED-ONLY\n' \
        "$conf" "$lineno" "$target" "$category" >&2
      problems=$((problems + 1))
    fi
    if [[ "$category" == "GREPPED-ONLY" && -n "${D_HITS[$target]:-}" ]]; then
      printf 'ERROR: %s:%s: %s is classified GREPPED-ONLY but the hermetic suite EXECUTES it (%s) — it belongs in the tier\n' \
        "$conf" "$lineno" "$target" "${D_HITS[$target]}" >&2
      problems=$((problems + 1))
    fi

    # ── Gate: EVERY oracle named must exist AND select exactly one test ───────
    # tests/run-all.sh exits 2 when its filter matches nothing, so a typo'd
    # oracle would run ZERO tests and report every mutant killed.
    #
    # The field is a SET, comma-separated: `a.sh,b.sh` is ONE oracle invocation
    # running both, because a target's code can be driven by several hermetic
    # tests while only one of them is its dedicated 1:1 test. Each member is
    # checked ON ITS OWN — a gate that validated only the first would let a typo
    # in a later one contribute nothing while the row still claimed its coverage,
    # which is the same quiet success this gate exists to refuse. The shape check
    # comes first because the split silently DROPS a trailing empty member
    # (`IFS=, read -a` on `a,` yields one element), so `a,` would otherwise pass
    # as `a` and the author's second oracle would vanish without a word.
    if [[ "$category" == EXECUTED-* || ( -n "$oracle" && "$oracle" != "-" ) ]]; then
      if [[ -z "$oracle" || "$oracle" == "-" ]]; then
        printf 'ERROR: %s:%s: %s is classified %s with no oracle test\n' \
          "$conf" "$lineno" "$target" "$category" >&2
        problems=$((problems + 1))
      elif [[ ! "$oracle" =~ $FT_ORACLE_RE ]]; then
        printf 'ERROR: %s:%s: %s has a malformed oracle field "%s" — comma-separated test basenames drawn from [A-Za-z0-9._+-], with no spaces, no glob characters, no empty members and no leading or trailing comma\n' \
          "$conf" "$lineno" "$target" "$oracle" >&2
        problems=$((problems + 1))
      else
        local o nmatch seen_o=""
        local -a onames=()
        IFS=',' read -r -a onames <<<"$oracle"
        for o in "${onames[@]}"; do
          case " $seen_o " in
            *" $o "*)
              printf 'ERROR: %s:%s: %s names oracle %s twice — run-all.sh selects a test once however many filters match it, so the repetition buys no coverage and hides a typo for the oracle that was meant\n' \
                "$conf" "$lineno" "$target" "$o" >&2
              problems=$((problems + 1)); continue ;;
          esac
          seen_o="$seen_o $o"
          if [[ ! -f "$FT_TESTS_DIR/$o" ]]; then
            printf 'ERROR: %s:%s: %s names oracle %s, which does not exist at %s/%s — run-all.sh would exit 2 (no tests matched) and report every mutant killed\n' \
              "$conf" "$lineno" "$target" "$o" "${FT_TESTS_DIR#"$FT_REPO"/}" "$o" >&2
            problems=$((problems + 1))
            continue
          fi
          nmatch="$(_ft_oracle_matches "$o")"
          if [[ "$nmatch" -ne 1 ]]; then
            printf 'ERROR: %s:%s: %s names oracle %s, which run-all.sh selects %s test(s) for — an oracle must select exactly one\n' \
              "$conf" "$lineno" "$target" "$o" "$nmatch" >&2
            problems=$((problems + 1))
            continue
          fi
          # ── Gate: the oracle must actually EXECUTE the target ──────────────
          # A real test that never runs this file kills nothing, so every
          # mutant SURVIVES and each one is owed a ledger entry it does not
          # deserve — the tier's debt grows while its coverage does not. This
          # is checked only for EXECUTED-* rows: a GREPPED-ONLY target is by
          # definition executed by nobody, and its oracle asserts about the
          # file's text instead.
          #
          # There is deliberately NO per-row escape hatch. If a genuine oracle
          # is invisible here the derivation is wrong, and this file is the
          # place that gets fixed — the whole design is that the map is derived
          # and checked against, never trusted. `--evidence` shows what the
          # derivation did see.
          if [[ "$category" == EXECUTED-* && -n "${D_HITS[$target]:-}" ]]; then
            case " ${D_HITS[$target]} " in
              *" $o "*) ;;
              *)
                printf 'ERROR: %s:%s: %s names oracle %s, which the derivation never observes EXECUTING it (it is executed by: %s) — that oracle can kill no mutant of this target, so every one survives and is owed a ledger entry it did not earn. Fix the row, or fix the derivation if the execution is real but unseen (see --evidence)\n' \
                  "$conf" "$lineno" "$target" "$o" "${D_HITS[$target]}" >&2
                problems=$((problems + 1))
                ;;
            esac
          fi
        done
      fi
    fi

    # ── Gate: EXECUTED-PARTIAL exists to NAME the functions ──────────────────
    if [[ "$category" == "EXECUTED-PARTIAL" ]]; then
      if [[ -z "$funcs" || "$funcs" == "-" ]]; then
        printf 'ERROR: %s:%s: %s is EXECUTED-PARTIAL with an empty function list (4th field) — that category exists to name the functions that are the mutation unit\n' \
          "$conf" "$lineno" "$target" >&2
        problems=$((problems + 1))
      else
        for fn in ${funcs//,/ }; do
          if ! grep -qE "^[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "$FT_REPO/$target"; then
            printf 'ERROR: %s:%s: %s is EXECUTED-PARTIAL naming function %s, which is not defined in %s\n' \
              "$conf" "$lineno" "$target" "$fn" "$target" >&2
            problems=$((problems + 1))
          fi
        done
      fi
    elif [[ -n "$funcs" && "$funcs" != "-" ]]; then
      printf 'ERROR: %s:%s: %s is %s but lists functions (%s) — only EXECUTED-PARTIAL has a mutation unit smaller than the file\n' \
        "$conf" "$lineno" "$target" "$category" "$funcs" >&2
      problems=$((problems + 1))
    fi
  done < <(ft_conf_rows "$conf")

  # ── Gate: an executed file missing from the map fails, BY NAME ─────────────
  local c
  for c in "${FT_CANDIDATES[@]}"; do
    if [[ -n "${D_HITS[$c]:-}" ]]; then
      executed=$((executed + 1))
      if [[ -z "${mapped[$c]:-}" ]]; then
        printf 'ERROR: %s is EXECUTED by the hermetic suite (%s) but has no row in %s — add a row, or exclude it with "#EXCLUDED|%s|<reason>"\n' \
          "$c" "${D_HITS[$c]}" "$conf" "$c" >&2
        problems=$((problems + 1))
      fi
    elif [[ -z "${mapped[$c]:-}" ]]; then
      printf 'ERROR: %s is an in-scope candidate with no row in %s — the map is the tier inventory; classify it (GREPPED-ONLY if the suite only reads its text)\n' \
        "$c" "$conf" >&2
      problems=$((problems + 1))
    fi
  done

  printf '%s: %s row(s) = %s active + %s grepped-only + %s deferred + %s excluded; %s of %s candidate(s) EXECUTED; %s problem(s)\n' \
    "${conf#"$FT_REPO"/}" "$rows" "$active" "$grepped" "$deferred" "$excluded" \
    "$executed" "${#FT_CANDIDATES[@]}" "$problems"
  [[ "$problems" -eq 0 ]]
}

ft_main() {
  case "${1:-}" in
    --scope) ft_scope_rules; printf 'opaque|%s|%s\n' "$FT_OPAQUE" "$FT_OPAQUE_WHY" ;;
    --check) shift; ft_check "${1:-$FT_CONF_DEFAULT}" ;;
    --rows) shift; ft_conf_rows "${1:-$FT_CONF_DEFAULT}" ;;
    --evidence) ft_derive && ft_print_evidence ;;
    --all) ft_derive && ft_print_verdicts all ;;
    ''|--list) ft_derive && ft_print_verdicts ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) printf 'derive-targets.sh: unknown option: %s\n' "$1" >&2; return 2 ;;
  esac
}

# Sourced by tests/test-falsify-targets.sh for its negative paths; run directly
# everywhere else.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ft_main "$@"
fi
