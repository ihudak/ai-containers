#!/usr/bin/env bash
# Tests for the repo-volume registry + volume-name helpers in sandbox-common.sh,
# and the pure helpers of repo.sh.
#
# These ~20 functions had ZERO test coverage before this file, and the two most
# recent CHANGELOG "Fixed" entries are both regressions in exactly them:
#   1. repo_name_from_volume used to emit each name with `printf '%s'` (no
#      trailing newline), so cmd_list's per-volume loop ran names together —
#      with repos "cluster" and "docs" it produced a phantom "clusterdocs"
#      entry. It must now emit one name per line (`printf '%s\n'`).
#   2. repo_registry_upsert / repo_registry_names used to glue two records
#      together when repos.conf's last line had no trailing newline. upsert now
#      pads a missing newline before appending; repo_registry_names uses awk,
#      which always newline-terminates its output.
#      NOTE on reproducing it: GNU grep >= 3 always terminates its own output
#      with a newline, so on Linux the padding guard is never the thing that
#      saves you — BSD/macOS grep is, where the missing newline IS preserved.
#      A Linux-only test therefore passes with the guard deleted. The regression
#      case below runs upsert against a BSD-behaving fake `grep` so the guard is
#      actually exercised on every platform.
#
# Hermetic: HOME is pointed at a temp dir BEFORE sourcing sandbox-common.sh, so
# the real ~/.ai-containers/repos.conf is never read or written. No docker
# daemon is required for the pure helpers; the few docker-calling helpers use a
# fake `docker` on PATH (same pattern as test-docs-path.sh).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Snapshot the REAL registry (if any) before doing anything else, so we can
# prove at the end that this test never touched it.
REAL_HOME_REGISTRY="${HOME}/.ai-containers/repos.conf"
REAL_REGISTRY_BEFORE=""
if [[ -f "$REAL_HOME_REGISTRY" ]]; then
  REAL_REGISTRY_BEFORE="$(cat "$REAL_HOME_REGISTRY")"
fi

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_rc() { # check_rc <desc> <expected-rc> <actual-rc>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected rc=$2, got rc=$3)"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point HOME at a temp dir BEFORE sourcing, so repo_registry_file (computed at
# source time from $HOME) resolves inside the sandbox, never the real home.
export HOME="$TMP/home"
mkdir -p "$HOME"
unset REPO_VOLUME_PREFIX REPO_BACKEND

# shellcheck disable=SC1091
source "$REPO_DIR/sandbox-common.sh"

REGISTRY_FILE="${HOME}/.ai-containers/repos.conf"

check "repo_registry_file resolves under the temp HOME" \
  "$REGISTRY_FILE" "$repo_registry_file"

# ── Fake docker (for the handful of helpers that call it) ───────────────────
# State:
#   $FAKE_VOLUMES_DIR  one empty file per "existing" volume, named after it,
#                      plus a matching "<name>.labels" file of "key=value" lines.
#   $FAKE_RUNNING_VOL  volume name a "running container" mounts (docker_volume_in_use)
FAKE_VOLUMES_DIR="$TMP/fake-volumes"
mkdir -p "$FAKE_VOLUMES_DIR"
export FAKE_VOLUMES_DIR
FAKE_RUNNING_VOL="$TMP/fake-running-vol"
: > "$FAKE_RUNNING_VOL"
export FAKE_RUNNING_VOL

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  volume)
    case "$2" in
      inspect)
        # docker volume inspect --format '<fmt>' <name>   OR   docker volume inspect <name>
        fmt=""; name=""; prev=""
        for a in "${@:3}"; do
          if [[ "$prev" == "--format" ]]; then
            fmt="$a"
          elif [[ "$a" != "--format" ]]; then
            name="$a"
          fi
          prev="$a"
        done
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || exit 1
        if [[ -n "$fmt" ]]; then
          case "$fmt" in
            *Labels*)
              key="$(printf '%s' "$fmt" | sed -n 's/.*index \.Labels "\([^"]*\)".*/\1/p')"
              val=""
              if [[ -f "$FAKE_VOLUMES_DIR/$name.labels" ]]; then
                val="$(grep "^${key}=" "$FAKE_VOLUMES_DIR/$name.labels" 2>/dev/null | head -1 | cut -d= -f2-)"
              fi
              printf '%s\n' "$val"
              ;;
            *) printf '%s\n' "$name" ;;
          esac
        else
          printf '%s\n' "$name"
        fi
        exit 0
        ;;
      ls)
        # docker volume ls --quiet --filter "name=<substr>"
        substr=""
        for a in "$@"; do
          case "$a" in name=*) substr="${a#name=}" ;; esac
        done
        for f in "$FAKE_VOLUMES_DIR"/*; do
          [[ -f "$f" ]] || continue
          case "$f" in *.labels) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0
        ;;
      create)
        # docker volume create --label k=v --label k=v <name>
        name="${@: -1}"
        : > "$FAKE_VOLUMES_DIR/$name"
        : > "$FAKE_VOLUMES_DIR/$name.labels"
        prev=""
        for a in "$@"; do
          if [[ "$prev" == "--label" ]]; then printf '%s\n' "$a" >> "$FAKE_VOLUMES_DIR/$name.labels"; fi
          prev="$a"
        done
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  ps)
    # docker ps --quiet --filter "volume=<name>"
    for a in "$@"; do
      case "$a" in
        volume=*)
          v="${a#volume=}"
          running="$(cat "$FAKE_RUNNING_VOL" 2>/dev/null || true)"
          [[ "$v" == "$running" ]] && printf 'fakecontainerid\n'
          ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"

# ─────────────────────────────────────────────────────────────────────────────
# validate_repo_name
# ─────────────────────────────────────────────────────────────────────────────

validate_repo_name "myrepo" >/dev/null 2>&1
check_rc "validate_repo_name accepts a plain lowercase name" 0 $?

validate_repo_name "my-repo-2" >/dev/null 2>&1
check_rc "validate_repo_name accepts dashes and digits" 0 $?

validate_repo_name "a" >/dev/null 2>&1
check_rc "validate_repo_name accepts a single char" 0 $?

validate_repo_name "$(printf 'a%.0s' $(seq 1 64))" >/dev/null 2>&1
check_rc "validate_repo_name accepts exactly 64 chars" 0 $?

validate_repo_name "$(printf 'a%.0s' $(seq 1 65))" >/dev/null 2>&1
check_rc "validate_repo_name rejects 65 chars (too long)" 1 $?

validate_repo_name "-abc" >/dev/null 2>&1
check_rc "validate_repo_name rejects a leading dash" 1 $?

validate_repo_name "ab c" >/dev/null 2>&1
check_rc "validate_repo_name rejects an embedded space" 1 $?

validate_repo_name "a/b" >/dev/null 2>&1
check_rc "validate_repo_name rejects a slash" 1 $?

validate_repo_name "" >/dev/null 2>&1
check_rc "validate_repo_name rejects the empty string" 1 $?

validate_repo_name "Abc" >/dev/null 2>&1
check_rc "validate_repo_name rejects uppercase" 1 $?

err="$(validate_repo_name "a/b" 2>&1 >/dev/null)"
if [[ "$err" == *"Invalid repo name"* ]]; then
  pass "validate_repo_name prints a diagnostic on rejection"
else
  fail "validate_repo_name prints a diagnostic on rejection (got '$err')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# sanitize_volume_token
# ─────────────────────────────────────────────────────────────────────────────

check "sanitize_volume_token passes through an already-safe token" \
  "my-repo_1.2" "$(sanitize_volume_token 'my-repo_1.2')"

check "sanitize_volume_token collapses disallowed chars to underscore" \
  "a_b_c" "$(sanitize_volume_token 'a/b c')"

check "sanitize_volume_token strips a single leading underscore" \
  "abc" "$(sanitize_volume_token '_abc')"

check "sanitize_volume_token strips a leading separator that becomes underscore" \
  "abc" "$(sanitize_volume_token '/abc')"

check "sanitize_volume_token leaves an interior underscore run intact" \
  "a__b" "$(sanitize_volume_token 'a__b')"

# ─────────────────────────────────────────────────────────────────────────────
# repo_volume_name / repo_workcopy_volume_name (default prefix: ai-containers)
# ─────────────────────────────────────────────────────────────────────────────

check "repo_volume_name uses the default 'ai-containers' prefix" \
  "ai-containers-repo-myrepo" "$(repo_volume_name 'myrepo')"

check "repo_volume_name sanitizes its argument" \
  "ai-containers-repo-a_b" "$(repo_volume_name 'a/b')"

check "repo_workcopy_volume_name appends --wc-<tag>" \
  "ai-containers-repo-myrepo--wc-projectA" "$(repo_workcopy_volume_name 'myrepo' 'projectA')"

check "repo_workcopy_volume_name sanitizes both name and tag" \
  "ai-containers-repo-a_b--wc-c_d" "$(repo_workcopy_volume_name 'a/b' 'c d')"

# ── REPO_VOLUME_PREFIX override (re-source with the override set) ──────────
(
  export REPO_VOLUME_PREFIX="customscope"
  unset _SANDBOX_COMMON_SOURCED
  # shellcheck disable=SC1091
  source "$REPO_DIR/sandbox-common.sh"
  actual="$(repo_volume_name 'myrepo')"
  [[ "$actual" == "customscope-repo-myrepo" ]] \
    && printf 'PASS: REPO_VOLUME_PREFIX override is honored by repo_volume_name\n' \
    || printf 'FAIL: REPO_VOLUME_PREFIX override is honored by repo_volume_name (got %s)\n' "$actual"
) > "$TMP/prefix.out" 2>&1
cat "$TMP/prefix.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/prefix.out") ))

# ─────────────────────────────────────────────────────────────────────────────
# repo_name_from_volume — REGRESSION: one name per line (trailing newline)
# ─────────────────────────────────────────────────────────────────────────────

# No label on the fake volume → falls back to stripping the prefix.
vol_a="ai-containers-repo-cluster"
: > "$FAKE_VOLUMES_DIR/$vol_a"
name_a="$(PATH="$FAKE_BIN:$PATH" repo_name_from_volume "$vol_a")"
check "repo_name_from_volume falls back to stripping the volume-name prefix" \
  "cluster" "$name_a"

# Labeled volume → the label wins over the derived name.
vol_b="ai-containers-repo-weird-name-xyz"
: > "$FAKE_VOLUMES_DIR/$vol_b"
printf 'ai-containers.repo=docs\n' > "$FAKE_VOLUMES_DIR/$vol_b.labels"
name_b="$(PATH="$FAKE_BIN:$PATH" repo_name_from_volume "$vol_b")"
check "repo_name_from_volume prefers the docker label over the derived name" \
  "docs" "$name_b"

# THE REGRESSION: each invocation must terminate its output with a newline so
# that concatenating two calls (as cmd_list's per-volume loop effectively does)
# never glues two names together into a phantom third name.
raw_a="$(PATH="$FAKE_BIN:$PATH" repo_name_from_volume "$vol_a"; printf 'END')"
if [[ "$raw_a" == "cluster
END" ]]; then
  pass "repo_name_from_volume output is newline-terminated (regression: used to be printf '%s' with no newline)"
else
  fail "repo_name_from_volume output is newline-terminated (got literal: $(printf '%q' "$raw_a"))"
fi

concatenated="$(
  { PATH="$FAKE_BIN:$PATH" repo_name_from_volume "$vol_a"; PATH="$FAKE_BIN:$PATH" repo_name_from_volume "$vol_b"; } \
    | tr '\n' '|'
)"
check "repo_name_from_volume: two concatenated calls stay two distinct names, not one glued 'clusterdocs' name" \
  "cluster|docs|" "$concatenated"

# ─────────────────────────────────────────────────────────────────────────────
# repo_registry_ensure
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$REGISTRY_FILE" ]]; then
  fail "registry file must not exist before repo_registry_ensure is called"
else
  pass "registry file absent before first use (sourcing alone creates nothing)"
fi

repo_registry_ensure
if [[ -f "$REGISTRY_FILE" ]]; then
  pass "repo_registry_ensure creates the registry file"
else
  fail "repo_registry_ensure creates the registry file"
fi

header_lines="$(grep -c '^#' "$REGISTRY_FILE")"
check "repo_registry_ensure seeds header comment lines" "2" "$header_lines"

repo_registry_ensure
after_second_call="$(cat "$REGISTRY_FILE")"
repo_registry_ensure
check "repo_registry_ensure is idempotent (repeat calls do not alter an existing file)" \
  "$after_second_call" "$(cat "$REGISTRY_FILE")"

# ─────────────────────────────────────────────────────────────────────────────
# repo_registry_upsert / repo_registry_lookup / repo_is_registered
# ─────────────────────────────────────────────────────────────────────────────

# Start from a clean registry for the upsert/lookup block.
rm -f "$REGISTRY_FILE"

repo_registry_upsert "alpha" "git" "git@example.com:org/alpha.git" "100" "200" "volume"
record="$(repo_registry_lookup "alpha")"
check "repo_registry_upsert inserts a new record retrievable by repo_registry_lookup" \
  "alpha|git|git@example.com:org/alpha.git|100|200|volume" "$record"

repo_is_registered "alpha" >/dev/null 2>&1
check_rc "repo_is_registered reports 0 (true) for a registered repo" 0 $?

repo_is_registered "nosuchrepo" >/dev/null 2>&1
check_rc "repo_is_registered reports 1 (false) for an unregistered repo" 1 $?

repo_registry_lookup "nosuchrepo" >/dev/null 2>&1
check_rc "repo_registry_lookup returns non-zero for a missing repo" 1 $?

# Idempotent upsert: same name twice → UPDATE, not a duplicate/append.
repo_registry_upsert "alpha" "git" "git@example.com:org/alpha.git" "100" "999" "volume"
line_count="$(grep -cE '^alpha\|' "$REGISTRY_FILE")"
check "repo_registry_upsert on an existing name updates in place (exactly one 'alpha' record)" \
  "1" "$line_count"

updated_record="$(repo_registry_lookup "alpha")"
check "repo_registry_upsert's update is reflected by a subsequent lookup" \
  "alpha|git|git@example.com:org/alpha.git|100|999|volume" "$updated_record"

# A second, distinct repo must coexist.
repo_registry_upsert "beta" "path" "/home/dev/beta" "300" "300" "bind"
check "repo_registry_upsert adds a second, independent record" \
  "beta|path|/home/dev/beta|300|300|bind" "$(repo_registry_lookup "beta")"
check "repo_registry_upsert on 'beta' left 'alpha' untouched" \
  "alpha|git|git@example.com:org/alpha.git|100|999|volume" "$(repo_registry_lookup "alpha")"

total_records="$(grep -vcE '^[[:space:]]*(#|$)' "$REGISTRY_FILE")"
check "registry has exactly 2 data records after two distinct upserts" "2" "$total_records"

# A name that is a substring/prefix of another must not false-match the anchored
# grep used by lookup/upsert/remove (e.g. "alpha" vs "alphabeta").
repo_registry_upsert "alphabeta" "path" "/home/dev/alphabeta" "1" "1" "bind"
check "repo_registry_upsert distinguishes 'alpha' from a name that starts with it ('alphabeta')" \
  "alphabeta|path|/home/dev/alphabeta|1|1|bind" "$(repo_registry_lookup "alphabeta")"
check "'alpha' record is unaffected by inserting the similarly-named 'alphabeta'" \
  "alpha|git|git@example.com:org/alpha.git|100|999|volume" "$(repo_registry_lookup "alpha")"
repo_registry_remove "alphabeta"

# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION: repo_registry_upsert / repo_registry_names must be robust to a
# repos.conf whose LAST LINE has no trailing newline (records used to get glued
# together on GNU coreutils, where grep/cut preserve a missing final newline).
# ─────────────────────────────────────────────────────────────────────────────

rm -f "$REGISTRY_FILE"
mkdir -p "$(dirname "$REGISTRY_FILE")"
# Deliberately no trailing newline on the last line (printf, not a here-doc).
printf '# comment\n\ngamma|path|/srv/gamma|1|1|bind' > "$REGISTRY_FILE"
if [[ -n "$(tail -c1 "$REGISTRY_FILE")" ]]; then
  pass "fixture setup: repos.conf ends with no trailing newline (precondition)"
else
  fail "fixture setup: repos.conf ends with no trailing newline (precondition)"
fi

repo_registry_upsert "delta" "git" "https://example.com/delta.git" "2" "2" "volume"

# The two original records must not have been glued into one line.
gamma_line_count="$(grep -cE '^gamma\|' "$REGISTRY_FILE")"
check "REGRESSION upsert: appending after a no-trailing-newline file keeps 'gamma' on its own record" \
  "1" "$gamma_line_count"
check "REGRESSION upsert: 'gamma' record content is intact (not glued to 'delta')" \
  "gamma|path|/srv/gamma|1|1|bind" "$(repo_registry_lookup "gamma")"
check "REGRESSION upsert: newly appended 'delta' record is correct and separate" \
  "delta|git|https://example.com/delta.git|2|2|volume" "$(repo_registry_lookup "delta")"

names_after_upsert="$(repo_registry_names | tr '\n' '|')"
check "REGRESSION upsert: repo_registry_names lists both records distinctly (no glued 'gammadelta')" \
  "gamma|delta|" "$names_after_upsert"

# The file must end newline-terminated, whatever it looked like before.
if [[ -z "$(tail -c1 "$REGISTRY_FILE")" ]]; then
  pass "REGRESSION upsert: registry is newline-terminated after appending"
else
  fail "REGRESSION upsert: registry is newline-terminated after appending"
fi

# Same case, but with a grep that behaves like BSD/macOS: it PRESERVES a missing
# final newline instead of adding one. This is what the padding guard in
# repo_registry_upsert actually defends against; with GNU grep the guard is
# unreachable, so deleting it would go unnoticed on Linux.
REAL_GREP="$(command -v grep)"
cat > "$FAKE_BIN/grep" <<GREPBSD
#!/usr/bin/env bash
# Only the "-vE <pattern> <file>" shape used by repo_registry_upsert is emulated.
if [[ "\$1" == "-vE" && \$# -eq 3 ]]; then
  pat="\$2"; file="\$3"; out=""
  while IFS= read -r line || [[ -n "\$line" ]]; do
    [[ "\$line" =~ \$pat ]] || out+="\$line"\$'\n'
  done < "\$file"
  # Preserve the input's missing final newline (the BSD behaviour).
  if [[ -s "\$file" && -n "\$(tail -c1 "\$file")" ]]; then out="\${out%\$'\n'}"; fi
  printf '%s' "\$out"
  exit 0
fi
exec "$REAL_GREP" "\$@"
GREPBSD
chmod +x "$FAKE_BIN/grep"

rm -f "$REGISTRY_FILE"
printf '# comment\n\nepsilon|path|/srv/epsilon|1|1|bind' > "$REGISTRY_FILE"
PATH="$FAKE_BIN:$PATH" repo_registry_upsert "zeta" "git" "https://example.com/zeta.git" "3" "3" "volume"
check "REGRESSION upsert (BSD-behaving grep): 'epsilon' stays on its own record" \
  "epsilon|path|/srv/epsilon|1|1|bind" "$(repo_registry_lookup "epsilon")"
check "REGRESSION upsert (BSD-behaving grep): 'zeta' is appended as a separate record" \
  "zeta|git|https://example.com/zeta.git|3|3|volume" "$(repo_registry_lookup "zeta")"
check "REGRESSION upsert (BSD-behaving grep): no glued 'epsilonzeta' record" \
  "epsilon|zeta|" "$(repo_registry_names | tr '\n' '|')"
rm -f "$FAKE_BIN/grep"

# Now exercise repo_registry_names directly against a no-trailing-newline file
# containing comment/blank lines interleaved, with NO upsert involved.
rm -f "$REGISTRY_FILE"
printf '# ai-containers repo registry\n\nepsilon|path|/srv/epsilon|1|1|bind\n# a comment in the middle\nzeta|git|https://example.com/zeta.git|2|2|volume' > "$REGISTRY_FILE"
if [[ -n "$(tail -c1 "$REGISTRY_FILE")" ]]; then
  pass "fixture setup 2: repos.conf ends with no trailing newline, comments interleaved (precondition)"
else
  fail "fixture setup 2: repos.conf ends with no trailing newline, comments interleaved (precondition)"
fi

names_raw="$(repo_registry_names)"
names_joined="$(printf '%s' "$names_raw" | tr '\n' '|')"
check "REGRESSION repo_registry_names: no-trailing-newline registry still yields distinct names" \
  "epsilon|zeta" "$names_joined"

last_char="$(repo_registry_names | tail -c1)"
if [[ "$last_char" == "" ]] || [[ "$last_char" == $'\n' ]]; then
  pass "REGRESSION repo_registry_names: output for the last record is newline-terminated (awk, not cut)"
else
  fail "REGRESSION repo_registry_names: output for the last record is newline-terminated (got trailing byte '$last_char')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# repo_registry_names — comments / blank lines / absent file / empty file
# ─────────────────────────────────────────────────────────────────────────────

rm -f "$REGISTRY_FILE"
check "repo_registry_names on an absent registry file yields nothing" \
  "" "$(repo_registry_names)"
repo_registry_names >/dev/null 2>&1
check_rc "repo_registry_names on an absent registry file exits 0 (not an error)" 0 $?

: > "$REGISTRY_FILE"
check "repo_registry_names on an empty (0-byte) registry file yields nothing" \
  "" "$(repo_registry_names)"

printf '# just a header\n\n   \n# another comment\n' > "$REGISTRY_FILE"
check "repo_registry_names ignores comment and blank (incl. whitespace-only) lines" \
  "" "$(repo_registry_names)"

printf '# header\ntheta|path|/srv/theta|1|1|bind\n\n# trailer comment\niota|path|/srv/iota|2|2|bind\n' > "$REGISTRY_FILE"
check "repo_registry_names returns only real records, skipping interleaved comments/blanks" \
  "theta|iota" "$(repo_registry_names | tr '\n' '|' | sed 's/|$//')"

# ─────────────────────────────────────────────────────────────────────────────
# repo_registry_remove
# ─────────────────────────────────────────────────────────────────────────────

rm -f "$REGISTRY_FILE"
repo_registry_upsert "kappa" "path" "/srv/kappa" "1" "1" "bind"
repo_registry_upsert "lambda" "path" "/srv/lambda" "2" "2" "bind"

repo_registry_remove "kappa"
repo_registry_lookup "kappa" >/dev/null 2>&1
check_rc "repo_registry_remove deletes the targeted record" 1 $?
check "repo_registry_remove leaves the other record intact" \
  "lambda|path|/srv/lambda|2|2|bind" "$(repo_registry_lookup "lambda")"

# Removing a non-existent record is a harmless no-op.
before_remove="$(cat "$REGISTRY_FILE")"
repo_registry_remove "no-such-repo-at-all"
rc_noop=$?
check_rc "repo_registry_remove on a non-existent name exits 0" 0 "$rc_noop"
check "repo_registry_remove on a non-existent name leaves the registry unchanged" \
  "$before_remove" "$(cat "$REGISTRY_FILE")"

# Removing from an absent registry file is also a harmless no-op.
rm -f "$REGISTRY_FILE"
repo_registry_remove "anything"
check_rc "repo_registry_remove on an absent registry file exits 0" 0 $?
if [[ -f "$REGISTRY_FILE" ]]; then
  fail "repo_registry_remove must not create the registry file as a side effect"
else
  pass "repo_registry_remove must not create the registry file as a side effect"
fi

# ─────────────────────────────────────────────────────────────────────────────
# repo_record_field / repo_record_backend
# ─────────────────────────────────────────────────────────────────────────────

sample_record="myrepo|git|https://example.com/x.git|111|222|volume"
check "repo_record_field extracts field 1 (name)"    "myrepo"                       "$(repo_record_field "$sample_record" 1)"
check "repo_record_field extracts field 2 (type)"    "git"                          "$(repo_record_field "$sample_record" 2)"
check "repo_record_field extracts field 3 (source)"  "https://example.com/x.git"    "$(repo_record_field "$sample_record" 3)"
check "repo_record_field extracts field 4 (added)"   "111"                          "$(repo_record_field "$sample_record" 4)"
check "repo_record_field extracts field 5 (synced)"  "222"                          "$(repo_record_field "$sample_record" 5)"
check "repo_record_field extracts field 6 (backend)" "volume"                       "$(repo_record_field "$sample_record" 6)"

check "repo_record_backend reads the explicit backend field when present" \
  "volume" "$(repo_record_backend "$sample_record")"

# Older record missing field 6 entirely: falls back to repo_effective_backend
# computed from the type (field 2). Force REPO_BACKEND=volume to pin the
# fallback outcome regardless of the host OS running this test.
old_record_git="oldrepo|git|https://example.com/y.git|1|1"
check "repo_record_backend falls back to repo_effective_backend for a record with no field 6 (git → volume, forced)" \
  "volume" "$(REPO_BACKEND=volume repo_record_backend "$old_record_git")"

old_record_path="oldrepo2|path|/srv/oldrepo2|1|1"
check "repo_record_backend falls back to repo_effective_backend for a record with no field 6 (path, forced bind)" \
  "bind" "$(REPO_BACKEND=bind repo_record_backend "$old_record_path")"

garbage_backend_record="weird|path|/srv/weird|1|1|not-a-real-backend"
check "repo_record_backend falls back when field 6 holds neither 'volume' nor 'bind'" \
  "bind" "$(REPO_BACKEND=bind repo_record_backend "$garbage_backend_record")"

# ─────────────────────────────────────────────────────────────────────────────
# repo_effective_backend
# ─────────────────────────────────────────────────────────────────────────────

check "repo_effective_backend: REPO_BACKEND=volume always yields volume for type=path" \
  "volume" "$(REPO_BACKEND=volume repo_effective_backend "path")"
check "repo_effective_backend: REPO_BACKEND=volume always yields volume for type=git" \
  "volume" "$(REPO_BACKEND=volume repo_effective_backend "git")"
check "repo_effective_backend: REPO_BACKEND=bind yields bind for type=path" \
  "bind" "$(REPO_BACKEND=bind repo_effective_backend "path")"
check "repo_effective_backend: REPO_BACKEND=bind yields volume for type=git (no local path to bind)" \
  "volume" "$(REPO_BACKEND=bind repo_effective_backend "git")"

uname_s="$(uname -s)"
if [[ "$uname_s" == "Linux" ]]; then
  check "repo_effective_backend: auto (default) on Linux yields bind for type=path" \
    "bind" "$(REPO_BACKEND=auto repo_effective_backend "path")"
else
  check "repo_effective_backend: auto (default) on non-Linux yields volume for type=path" \
    "volume" "$(REPO_BACKEND=auto repo_effective_backend "path")"
fi
check "repo_effective_backend: auto (default) always yields volume for type=git" \
  "volume" "$(REPO_BACKEND=auto repo_effective_backend "git")"

# ─────────────────────────────────────────────────────────────────────────────
# repo.sh's is_git_url / fmt_epoch (pure helpers) — sourced in a subshell so
# repo.sh's own arg-parsing / dispatch never runs and no side effects occur.
# ─────────────────────────────────────────────────────────────────────────────

(
  set -uo pipefail
  cd "$TMP"   # never the real repo dir, and never triggers a live docker call
  export HOME="$TMP/home2"; mkdir -p "$HOME"
  export PATH="$FAKE_BIN:$PATH"
  # Extract is_git_url and fmt_epoch by sourcing repo.sh's function definitions
  # without running its dispatch: with no args, command="${1:-usage}" defaults to
  # "usage", which the case dispatches to the usage() function (prints to stdout,
  # no exit) — safe to source directly. NOTE: repo.sh itself sets `set -euo
  # pipefail`, which is inherited by this subshell once sourced, so every
  # is_git_url probe below is guarded with `|| true` to capture its return code
  # instead of letting a "false" result (rc=1) trip errexit and abort the block.
  # shellcheck disable=SC1090,SC1091
  source "$REPO_DIR/repo.sh" >/dev/null 2>&1 </dev/null
  rc_dispatch=$?

  # repo.sh itself sets `set -e`, which is inherited by this subshell once
  # sourced, so each is_git_url probe is wrapped in an `if` (not `foo || true`,
  # which would mask the real exit status we need to capture) to observe its
  # return code without tripping errexit on a "false" (rc=1) result.
  if is_git_url "git@github.com:org/repo.git"; then r1=0; else r1=1; fi
  if is_git_url "https://github.com/org/repo.git"; then r2=0; else r2=1; fi
  if is_git_url "ssh://git@github.com/org/repo.git"; then r3=0; else r3=1; fi
  if is_git_url "/home/dev/some/local/path"; then r4=0; else r4=1; fi
  if is_git_url "relative/local/path"; then r5=0; else r5=1; fi

  echo "RC_DISPATCH=$rc_dispatch"
  echo "R1=$r1"; echo "R2=$r2"; echo "R3=$r3"; echo "R4=$r4"; echo "R5=$r5"
  epoch0="$(fmt_epoch 0)"
  epoch_nonnum="$(fmt_epoch abc)"
  epoch_empty="$(fmt_epoch '')"
  printf 'EPOCH0=%q\n' "$epoch0"
  printf 'EPOCH_NONNUM=%q\n' "$epoch_nonnum"
  printf 'EPOCH_EMPTY=%q\n' "$epoch_empty"
) > "$TMP/repo_sh.out" 2>"$TMP/repo_sh.err"
# shellcheck disable=SC1090
source "$TMP/repo_sh.out"

check "is_git_url accepts an scp-like git URL (user@host:path)" "0" "$R1"
check "is_git_url accepts an https:// URL" "0" "$R2"
check "is_git_url accepts an ssh:// URL" "0" "$R3"
check "is_git_url rejects an absolute local filesystem path" "1" "$R4"
check "is_git_url rejects a relative local filesystem path" "1" "$R5"

check "fmt_epoch formats epoch 0 as a non-empty date string (not left as '0')" \
  "true" "$([[ -n "$EPOCH0" && "$EPOCH0" != "0" ]] && echo true || echo false)"
check "fmt_epoch passes a non-numeric value straight through unchanged" \
  "abc" "$EPOCH_NONNUM"
check "fmt_epoch passes an empty value straight through unchanged" \
  "" "$EPOCH_EMPTY"
# ─────────────────────────────────────────────────────────────────────────────
# docker-backed helpers: docker_volume_label, repo_volume_exists,
# docker_volume_in_use, repo_base_volumes, repo_workcopy_volumes
# (fake docker on PATH; no daemon)
# ─────────────────────────────────────────────────────────────────────────────

rm -rf "$FAKE_VOLUMES_DIR"; mkdir -p "$FAKE_VOLUMES_DIR"

base1="ai-containers-repo-cluster"
base2="ai-containers-repo-docs"
wc1="ai-containers-repo-cluster--wc-projA"
wc2="ai-containers-repo-docs--wc-projB"
: > "$FAKE_VOLUMES_DIR/$base1"
: > "$FAKE_VOLUMES_DIR/$base2"
: > "$FAKE_VOLUMES_DIR/$wc1"
: > "$FAKE_VOLUMES_DIR/$wc2"
printf 'ai-containers.repo=cluster\nai-containers.type=git\nai-containers.source=git@x:cluster.git\n' > "$FAKE_VOLUMES_DIR/$base1.labels"

label_val="$(PATH="$FAKE_BIN:$PATH" docker_volume_label "$base1" 'ai-containers.repo')"
check "docker_volume_label returns the requested label's value" "cluster" "$label_val"

label_missing="$(PATH="$FAKE_BIN:$PATH" docker_volume_label "$base1" 'ai-containers.nonexistent')"
check "docker_volume_label returns empty for a label that is not set" "" "$label_missing"

label_gone_vol="$(PATH="$FAKE_BIN:$PATH" docker_volume_label "no-such-volume" 'ai-containers.repo')"
check "docker_volume_label returns empty for a volume that does not exist" "" "$label_gone_vol"

PATH="$FAKE_BIN:$PATH" repo_volume_exists "cluster"
check_rc "repo_volume_exists is true for an existing base volume" 0 $?
PATH="$FAKE_BIN:$PATH" repo_volume_exists "nosuchrepo"
check_rc "repo_volume_exists is false for a repo with no backing volume" 1 $?

base_list="$(PATH="$FAKE_BIN:$PATH" repo_base_volumes | sort | tr '\n' '|')"
check "repo_base_volumes lists only base volumes, excluding --wc- working copies" \
  "ai-containers-repo-cluster|ai-containers-repo-docs|" "$base_list"

all_wc="$(PATH="$FAKE_BIN:$PATH" repo_workcopy_volumes | sort | tr '\n' '|')"
check "repo_workcopy_volumes (no arg) lists every working copy across all repos" \
  "ai-containers-repo-cluster--wc-projA|ai-containers-repo-docs--wc-projB|" "$all_wc"

one_wc="$(PATH="$FAKE_BIN:$PATH" repo_workcopy_volumes "cluster" | sort | tr '\n' '|')"
check "repo_workcopy_volumes <name> scopes to that repo's working copies only" \
  "ai-containers-repo-cluster--wc-projA|" "$one_wc"

# ─────────────────────────────────────────────────────────────────────────────
# Isolation from rvm volumes
# ─────────────────────────────────────────────────────────────────────────────
# A container group's Ruby home is a docker volume too, sharing this same prefix
# and differing ONLY in the infix: "<prefix>-rvm-<group>" vs "<prefix>-repo-<name>".
# That one substring is the entire reason `repo.sh sync/reset --all` cannot reach
# into a group's compiled rubies and wipe them. Assert it directly, so widening the
# discovery filter (or renaming an infix) fails here rather than in someone's
# workspace.
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-default"
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs"
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs--wc-decoy"   # even a --wc--looking one

iso_base="$(PATH="$FAKE_BIN:$PATH" repo_base_volumes | sort | tr '\n' '|')"
check "repo_base_volumes ignores rvm volumes entirely" \
  "ai-containers-repo-cluster|ai-containers-repo-docs|" "$iso_base"

iso_wc="$(PATH="$FAKE_BIN:$PATH" repo_workcopy_volumes | sort | tr '\n' '|')"
check "repo_workcopy_volumes ignores rvm volumes entirely" \
  "ai-containers-repo-cluster--wc-projA|ai-containers-repo-docs--wc-projB|" "$iso_wc"

# `sync --all` / `reset --all` iterate repo_registry_names, not a volume listing —
# so an rvm volume cannot become a --all target even by name collision.
iso_reg="$(repo_registry_names | grep -c 'rvm' || true)"
check "no rvm volume can appear as a sync/reset --all target" "0" "$iso_reg"

rm -f "$FAKE_VOLUMES_DIR"/ai-containers-rvm-*

: > "$FAKE_RUNNING_VOL"  # nothing running
PATH="$FAKE_BIN:$PATH" docker_volume_in_use "$base1"
check_rc "docker_volume_in_use is false when no container mounts the volume" 1 $?

printf '%s' "$base1" > "$FAKE_RUNNING_VOL"
PATH="$FAKE_BIN:$PATH" docker_volume_in_use "$base1"
check_rc "docker_volume_in_use is true when a running container mounts the volume" 0 $?
: > "$FAKE_RUNNING_VOL"

# ─────────────────────────────────────────────────────────────────────────────
# Hermetic guarantee: the real registry must be byte-identical to how it was
# found at the very start of this test (whether that was absent or present).
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$REAL_HOME_REGISTRY" ]]; then
  if [[ -n "$REAL_REGISTRY_BEFORE" ]] && [[ "$(cat "$REAL_HOME_REGISTRY")" == "$REAL_REGISTRY_BEFORE" ]]; then
    pass "the real ~/.ai-containers/repos.conf is unchanged after this test run"
  else
    fail "the real ~/.ai-containers/repos.conf is unchanged after this test run"
  fi
elif [[ -z "$REAL_REGISTRY_BEFORE" ]]; then
  pass "the real ~/.ai-containers/repos.conf still does not exist (this test never created it)"
else
  fail "the real ~/.ai-containers/repos.conf is unchanged after this test run"
fi

# ─────────────────────────────────────────────────────────────────────────────

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 )) || exit 1
exit 0
