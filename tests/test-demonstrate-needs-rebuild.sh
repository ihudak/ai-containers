#!/usr/bin/env bash
# tests/test-demonstrate-needs-rebuild.sh — the parts of
# tests/integration/demonstrate-needs-rebuild.sh that need no Docker daemon
# (TST-7):
#
#   --help   printed a line-number range of its own header, which had drifted
#            onto the tail of the NAMING paragraph and the first usage line.
#   cleanup  its interrupt trap removed three of run.sh's five variant tags,
#            so an interrupted services or mariadb rebuild left a multi-GB
#            image behind (run.sh's own per-variant rmi never ran).
#
# The demonstrator is run in a SCRATCH COPY of the tree: its cleanup reverts
# mutations and checks out the cases directory, which in the real checkout
# would discard a developer's uncommitted edits. docker is a stub that records
# its arguments.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/build.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
DEMO_REL="tests/integration/demonstrate-needs-rebuild.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" <<<"$2"; }

[[ -f "$REPO_DIR/$DEMO_REL" ]] || { fail "$DEMO_REL exists"; printf '\n%d failure(s)\n' "$fails"; exit 1; }

# ── the scratch copy ──────────────────────────────────────────────────────────
COPY="$TMP/repo"
rel_engine="${ENGINE_DIR#"$REPO_DIR"}"
mkdir -p "$COPY/tests" "$COPY$rel_engine" \
  && cp -R "$REPO_DIR/tests/integration" "$COPY/tests/" \
  && cp "$ENGINE_DIR/Dockerfile" "$ENGINE_DIR/build.sh" "$COPY$rel_engine/" \
  || { printf 'SCAFFOLD-FAILED: could not copy the integration tree into %s\n' "$COPY"; exit 1; }
( cd "$COPY" \
    && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
    && git add -A && git -c user.email=t@example -c user.name=t commit -q -m copy ) >/dev/null 2>&1 \
  || { printf 'SCAFFOLD-FAILED: could not commit the scratch copy (the demonstrator refuses a dirty tree)\n'; exit 1; }

mkdir -p "$TMP/bin"
DOCKER_LOG="$TMP/docker.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$DOCKER_LOG" > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

# ── --help prints the usage, not whatever lines a range now lands on ─────────
help="$(PATH="$TMP/bin:$PATH" bash "$COPY/$DEMO_REL" --help 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && pass "--help exits 0" || fail "--help exits 0 (got $rc)"
[[ "$(head -n 1 <<<"$help")" == "Usage:" ]] \
  && pass "--help starts at the Usage: block" \
  || fail "--help starts at the Usage: block (first line: '$(head -n 1 <<<"$help")')"
for opt in --dry-run --budget-minutes --variant; do
  has "$opt" "$help" && pass "--help documents $opt" || fail "--help documents $opt"
done
# The old range printed the end of the NAMING paragraph ("is meant to stay").
has "meant to stay" "$help" && fail "--help prints none of the header's prose (it printed the NAMING paragraph)" \
  || pass "--help prints none of the header's prose"
grep -q '^#' <<<"$help" && fail "--help strips the header's comment markers" \
  || pass "--help strips the header's comment markers"

# ── cleanup removes the tag of EVERY variant run.sh can build ─────────────────
# Asked of run.sh itself, as the demonstrator must: KNOWN_VARIANTS and
# variant_image() are the authority.
want_tags="$(
  # shellcheck disable=SC2034  # read by run.sh, sourced on the next lines
  IT_SOURCE_ONLY=1
  set --
  # shellcheck source=integration/run.sh
  source "$COPY/tests/integration/run.sh" >/dev/null 2>&1 || exit 1
  # shellcheck disable=SC2086  # KNOWN_VARIANTS is run.sh's space-separated list
  for v in $KNOWN_VARIANTS; do variant_image "$v"; printf '\n'; done )"
n_want="$(grep -c . <<<"$want_tags")"
if (( n_want >= 5 )); then
  pass "run.sh names $n_want image variants"
else
  fail "run.sh names $n_want image variants — the cleanup check below would prove little"
fi
# A selection that matches nothing exits 2 AFTER the trap is set and with
# --dry-run off, which is the shape of an interrupt: cleanup runs, nothing else.
: > "$DOCKER_LOG"
PATH="$TMP/bin:$PATH" bash "$COPY/$DEMO_REL" zzz-selects-nothing >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && pass "an empty selection exits 2" || fail "an empty selection exits 2 (got $rc)"
rmi="$(grep -E '^rmi ' "$DOCKER_LOG")"
missing=""
while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  [[ " $rmi " == *" $tag "* ]] || missing+="$tag "
done <<<"$want_tags"
if [[ -n "$rmi" && -z "$missing" ]]; then
  pass "the cleanup trap removes every variant's image tag"
else
  fail "the cleanup trap removes every variant's image tag — it left: ${missing:-<no rmi at all>}"
fi

# ── an interrupt stops the run ────────────────────────────────────────────────
# `trap cleanup … INT` with no exit ran the cleanup and then carried on: the
# loop applied the next patch and rebuilt for it, so one Ctrl-C reverted the
# tree under a running case and started the next rebuild. A docker that waits
# stands in for a build; the demonstrator gets a SIGINT while it waits, sent to
# its whole process group as a terminal sends Ctrl-C (`set -m` gives the job a
# group of its own; setsid is not on macOS).
# The first patch its own --dry-run selects (the row after the PATCH header).
rebuild_id="$(PATH="$TMP/bin:$PATH" bash "$COPY/$DEMO_REL" --dry-run 2>/dev/null \
  | awk 'go && NF { print $1; exit } $1 == "PATCH" { go = 1 }')"
WAITING="$TMP/docker-waiting"
# Only the first call waits, and never an rmi: run.sh's own teardown calls
# docker too, and must not wait out a stand-in build of its own.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = rmi ] && exit 0\n[ -e "%s" ] && exit 0\n: > "%s"\nsleep 30\n' \
  "$DOCKER_LOG" "$WAITING" "$WAITING" > "$TMP/bin/docker"
: > "$DOCKER_LOG"
if [[ -z "$rebuild_id" ]]; then
  fail "a rebuild patch exists to drive the interrupt check"
else
  out_file="$TMP/interrupt.out"
  set -m
  PATH="$TMP/bin:$PATH" bash "$COPY/$DEMO_REL" "$rebuild_id" > "$out_file" 2>&1 &
  demo=$!
  set +m
  for _ in $(seq 1 300); do [[ -e "$WAITING" ]] && break; sleep 0.1; done
  if [[ ! -e "$WAITING" ]]; then
    fail "the demonstrator reached docker (it never called it)"
    kill -KILL -- "-$demo" 2>/dev/null
  else
    kill -INT -- "-$demo" 2>/dev/null
    for _ in $(seq 1 200); do kill -0 "$demo" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$demo" 2>/dev/null; then
      kill -KILL -- "-$demo" 2>/dev/null
      fail "an interrupt stops the demonstrator (still running 20s after SIGINT)"
    fi
  fi
  wait "$demo" 2>/dev/null; rc=$?
  [[ "$rc" == 130 ]] && pass "an interrupt exits 130" \
    || fail "an interrupt exits 130 (got $rc; output: $(tr '\n' ' ' < "$out_file"))"
  has "FAILED" "$(cat "$out_file")" \
    && fail "an interrupt does not go on to the next step (it reported the preflight FAILED)" \
    || pass "an interrupt does not go on to the next step"
  rmi="$(grep -E '^rmi ' "$DOCKER_LOG")"
  [[ -n "$rmi" ]] && pass "an interrupt still runs the cleanup" || fail "an interrupt still runs the cleanup (no rmi)"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
