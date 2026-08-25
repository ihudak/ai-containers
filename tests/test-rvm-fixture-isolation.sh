#!/usr/bin/env bash
# tests/test-rvm-fixture-isolation.sh — a fixture that models "this tool is
# absent" must not be able to find the HOST's copy of it.
#
# WHY THIS EXISTS. test-rvm-reconcile.sh's boot_case models "rvm bootstrapped
# but the loader gave us no usable rvm" by OMITTING its own `rvm` stub, then
# asserts the reconcile hits bash's `rvm: command not found`. It composed the
# child's PATH as `"$bin:$PATH"` — its stub directory PREPENDED to whatever the
# developer happened to have. Omitting the stub therefore means "rvm is
# unresolvable" only on a machine that has no rvm.
#
# On a machine that has one — which, for a repo whose feature set IS rvm
# support, is most developer machines — the call resolved to the host's real
# rvm, the reconcile succeeded, and the case failed with a diagnostic that
# pointed at the product rather than at the fixture. Measured on 2026-08-25: the
# reconcile reported `ruby-3.4.5 already present`, which was the version
# installed in the DEVELOPER'S ~/.rvm, not in the test's temp home.
#
# CI never saw it. GitHub's runners have no rvm, so the case passed there for
# the thirteen days between f95cd57 (2026-08-12, the commit that made the case
# reach that branch at all) and its discovery. verify-on-host.sh's Phase 5 runs
# the same suite, so the LOCAL layer — the one the containment invariant calls
# a superset of nightly — was the only layer that could fail, and did.
#
# That is the same shape as the two path-resolution failures this repo has
# already paid for (macOS's /var -> /private/var, and the symlinked TMPDIR):
# an assumption that holds in CI's environment and not in a developer's,
# invisible to the layer that runs most often. test-symlinked-tmp-guard.sh
# guards that class; this file guards this one, in the same way and for the
# same reason — BY DEMONSTRATION, not description.
#
# A naive fixture must be shown finding the planted rvm (proving the hostile arm
# is genuinely hostile), a sanitised one must be shown not finding it (proving
# the sanitising is what does the work), and the REAL fixture must survive the
# hostile arm end to end (which is the assertion that fails on an unfixed tree).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── The hostile arm: a host that has rvm installed ────────────────────────────
# Modelled on the real thing rather than on a bare `exit 0`: the defect was only
# legible because the host's rvm ANSWERED `list strings` with a version, which
# carried the reconcile all the way through to "already present" and "done"
# instead of failing somewhere obvious.
HOSTILE="$TMP/hostbin"; mkdir -p "$HOSTILE" || { printf 'SCAFFOLD-FAILED: mkdir\n'; exit 1; }
cat > "$HOSTILE/rvm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list strings") printf 'ruby-3.4.5\n' ;;
esac
exit 0
EOF
chmod +x "$HOSTILE/rvm" || { printf 'SCAFFOLD-FAILED: chmod\n'; exit 1; }

# A PATH with no rvm on it at all, to serve as the benign arm. Derived from the
# real PATH rather than hardcoded to /usr/bin:/bin, because the fixtures below
# need the same ordinary tools the reconcile does, wherever this platform keeps
# them (Homebrew's prefix is not /usr/bin, and a hardcoded list would make the
# benign arm fail for reasons unrelated to rvm).
path_without_rvm() {  # $1 = a PATH value → the same value minus every dir providing `rvm`
  # `kept`, not `out`: shellcheck's array/scalar type tracking is not
  # scope-aware, so a local ARRAY named `out` here makes the scalar `out=` used
  # for command output further down read as the same variable and falsely
  # trigger SC2178/SC2128. build.sh:tool_versions_arg documents the same
  # collision and the same remedy — rename, rather than suppress a rule that is
  # right about every other call site.
  local d kept=() IFS=':'
  read -ra _dirs <<< "$1"
  for d in "${_dirs[@]}"; do
    [[ -n "$d" ]] || continue
    [[ -x "$d/rvm" ]] && continue
    kept+=("$d")
  done
  printf '%s' "${kept[*]}"
}
BENIGN="$(path_without_rvm "$PATH")"

# ── Scaffold premises, checked before anything is concluded from them ─────────
# Both arms must actually differ in the property under test, or every assertion
# below is vacuous — the failure mode this file exists to refuse.
if PATH="$HOSTILE:$BENIGN" command -v rvm >/dev/null 2>&1; then
  pass "scaffold: the hostile arm really does provide an rvm"
else
  printf 'SCAFFOLD-FAILED: planted rvm at %s is not resolvable\n' "$HOSTILE/rvm"; exit 1
fi
if PATH="$BENIGN" command -v rvm >/dev/null 2>&1; then
  printf 'SCAFFOLD-FAILED: the benign arm still provides an rvm (%s)\n' "$(PATH="$BENIGN" command -v rvm)"; exit 1
else
  pass "scaffold: the benign arm provides none"
fi

# ── Demonstration 1: the naive composition is defeated by the hostile arm ─────
# This is boot_case's original PATH expression, in miniature. It must find the
# planted rvm — if it did not, the hostile arm would not be modelling the defect
# and the end-to-end assertion below would prove nothing.
naive_sees_rvm() {  # $1 = the ambient PATH → rc 0 if a stub-less fixture still resolves rvm
  local stub="$TMP/stubbin"; mkdir -p "$stub"
  PATH="$stub:$1" command -v rvm >/dev/null 2>&1
}
if naive_sees_rvm "$HOSTILE:$BENIGN"; then
  pass "demonstration: the naive PATH composition resolves the host's rvm"
else
  fail "demonstration: the naive PATH composition resolves the host's rvm — the hostile arm is not hostile, so nothing below means anything"
fi
if naive_sees_rvm "$BENIGN"; then
  fail "demonstration: the naive composition finds no rvm on a clean host"
else
  pass "demonstration: the naive composition finds no rvm on a clean host (which is why CI never saw this)"
fi

# ── Demonstration 2: sanitising the PATH is what closes it ────────────────────
sanitised_sees_rvm() {  # $1 = the ambient PATH → rc 0 if rvm still resolves after sanitising
  local stub="$TMP/stubbin2"; mkdir -p "$stub"
  PATH="$stub:$(path_without_rvm "$1")" command -v rvm >/dev/null 2>&1
}
if sanitised_sees_rvm "$HOSTILE:$BENIGN"; then
  fail "demonstration: sanitising the PATH removes the host's rvm"
else
  pass "demonstration: sanitising the PATH removes the host's rvm"
fi

# ── The end-to-end assertion ──────────────────────────────────────────────────
# The REAL fixture, run under a PATH that provides an rvm. This is the assertion
# that fails on an unfixed tree, and the only one here that exercises the
# shipped test rather than a miniature of it.
#
# HOME is redirected too: test-rvm-reconcile.sh builds its own temp homes, but a
# developer's real $HOME/.rvm is the other half of how a host rvm leaks in, and
# a guard that closed one route while leaving the other would be reporting on a
# fixture nobody runs.
out="$(HOME="$TMP/home" PATH="$HOSTILE:$BENIGN" bash "$REPO_DIR/tests/test-rvm-reconcile.sh" 2>&1)"
rc=$?
if (( rc == 0 )) && ! grep -q '^FAIL:' <<<"$out"; then
  pass "test-rvm-reconcile.sh passes on a host that HAS rvm installed"
else
  fail "test-rvm-reconcile.sh does not survive a host with rvm installed (exit $rc) — its fixture is resolving the host's rvm instead of modelling its absence"
  grep '^FAIL:' <<<"$out" | head -3 | sed 's/^/     /'
fi

# The control: it must pass on a clean host too. Without this, the assertion
# above could be satisfied by a test that fails everywhere equally.
out_clean="$(HOME="$TMP/home2" PATH="$BENIGN" bash "$REPO_DIR/tests/test-rvm-reconcile.sh" 2>&1)"
rc_clean=$?
if (( rc_clean == 0 )) && ! grep -q '^FAIL:' <<<"$out_clean"; then
  pass "test-rvm-reconcile.sh passes on a host that has none (the control)"
else
  fail "test-rvm-reconcile.sh fails even on a clean host (exit $rc_clean) — this is not the isolation defect"
  grep '^FAIL:' <<<"$out_clean" | head -3 | sed 's/^/     /'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
