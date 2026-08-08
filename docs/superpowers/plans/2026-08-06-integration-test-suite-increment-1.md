# Runtime Integration Test Suite — Increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tagged, three-state (PASS/FAIL/SKIP) runtime integration harness plus 16 cases that observe the container's network enforcement from outside, so a silent security regression like the months-long `capture-blocked-traffic.sh` death cannot recur.

**Architecture:** One image built once per run from a minimal `sandbox.conf`; every scenario is env vars plus a bind-mounted synthetic allowlist. Destinations are sidecar containers on a private Docker network built from the sandbox image itself, so security cases are deterministic and offline. `tests/integration/run.sh` detects capabilities, selects by tag, executes each case as its own process under `timeout`, and reports selection and skips as separate counts. `verify-on-host.sh` shrinks to a platform-adaptive preflight that delegates to the same runner.

**Tech Stack:** bash (3.2-compatible), Docker CLI, iptables/ipset/NFLOG, tshark, tcpdump, Node.js (the sidecar HTTP server), CoreDNS (nightly DNS-backed cases only), GitHub Actions.

**Source spec:** `docs/superpowers/specs/2026-08-06-integration-test-suite-design.md`

---

## Spec corrections applied by this plan

Four claims in the approved spec do not survive contact with the code. The plan implements the corrected version; update the spec in Task 11.

1. **Sidecar runtime.** The spec proposes `--entrypoint python3 … -m http.server`. A minimal image has **no `python3`**: `ubuntu:24.04` ships none, and `Dockerfile:165` only symlinks `$PYENV_ROOT/shims/python3` when `python=` is set. `node` **is** unconditional — `Dockerfile:38-53` always installs the latest LTS and symlinks it to `/usr/local/bin/node`. The sidecar is therefore `--entrypoint node … -e '<http server>'`. Same "no extra image pulled" property.

2. **`NFLOG_GROUP` is not a runtime knob.** `capture-blocked-traffic.sh:21` reads it, but `entrypoint.sh:159` hardcodes `--nflog-group 100` in the iptables rule. Overriding it would silently detach the watcher from the rule. Cases use the default 100 and the harness never sets it.

3. **`085-selfheal-disabled-stays-blocked` moves from `fast` to `needs-dns`.** Self-healing is domain-mediated: `log_blocked` looks the destination IP up in a DNS map that `capture-blocked-traffic.sh` builds by sniffing real port-53 **responses**. `--add-host` produces no DNS traffic, so with no resolver the map is empty, no domain is found, and `SELF_HEALING_ENABLED=0` and `=1` produce byte-identical output — the case would pass for a reason unrelated to what it claims to test. It therefore joins `080` behind the CoreDNS fixture.

   Consequence: the CI-gating `fast` set is **12** cases, not 13. Success criterion 3 in the spec must be corrected to 12.

4. **Success criterion 6 cannot be met in increment 1.** It requires `verify-on-host.sh` to contain "no test logic of its own", but its Phases 1–3 are the *only* coverage of agent-tier tool installs, native-package builds and the Ruby/rvm bootstrap — and the packages tier that would absorb them is explicitly out of scope here. Deleting them to satisfy a criterion is precisely the "green because we did not look" failure this suite exists to prevent. Rescoped to "no **network-mode** test logic"; full criterion 6 lands with the packages tier. See Task 10.

Two additions the spec does not mention, both found while planning:

- **A 16th case, `000-harness-selftest`.** The spec's 15 cases contain nothing that proves the harness itself works. A destination nothing could ever reach is indistinguishable from one the firewall dropped, so every "blocked" assertion is meaningless until the primitives are verified.
- **`run.sh` snapshots and restores the repo's real `allowlist-*.txt`.** `build.sh` regenerates them in place from `sandbox.conf`; building from a minimal config would otherwise leave a developer's real allowlists silently replaced by a stripped-down set until their next `./build.sh`. The snapshot doubles as case `300`'s expected value.

---

## Global Constraints

- **bash 3.2 compatible.** Stock macOS bash. No `declare -A`, no `${var^^}`, no `mapfile` in new harness code. Empty-array expansion must be `"${arr[@]+"${arr[@]}"}"` — a bare `"${arr[@]}"` aborts under `set -u` on 3.2.
- **Scratch lives under `$HOME`.** Any directory that becomes a bind-mount source must be under `$HOME` (`$IT_SCRATCH`, default `$HOME/.cache/ai-containers-it/<run-id>`). macOS `$TMPDIR` (`/var/folders/…`) is **not** shared with the Colima VM: the mount silently resolves inside the VM, the container writes happily, and the host reads an empty directory. This exact bug made a healthy capture daemon look dead.
- **Read container output through `docker exec`, not through a bind mount,** wherever a choice exists. It is platform-proof and removes the entire mount-visibility failure class.
- **Every created resource carries `--label ai-containers.it-run=$IT_RUN_ID`** so a crashed run is swept with one command.
- **Synthetic allowlists always write all three files.** `refresh-ipset-allowlist.sh:14-17` exits 1 when the CIDR file is missing, and `set -e` in `entrypoint.sh` turns that into a dead container with a confusing error.
- **Cases never know whether they are on CI.** They declare `tags:` and `requires:`; the runner decides.
- **A security case is not accepted until it has been demonstrated FAILING** against its known-bad configuration. Every security task below carries an explicit demonstrated-failure step; it is not optional.
- **No extra image is pulled** except `coredns/coredns:1.11.3` in the `needs-dns` cases, which are nightly-only.
- **Per-case timeout** — default 300s, `--timeout` overrides. No case may block the runner.
- **`build.sh` overwrites the repo's real `allowlist-*.txt`.** The runner snapshots them before building and restores them at exit.

---

## File Structure

| File | Responsibility |
|---|---|
| `tests/integration/run.sh` | capability detection, tag selection, execution under timeout, PASS/FAIL/SKIP accounting, `--require` enforcement, image build + allowlist snapshot/restore, resource sweep |
| `tests/integration/lib.sh` | the verbs cases use: sidecar, allowlist synthesis, `sandbox_up`/`exec`/`down`, `reach`, `blocked_entries`, assertions, `it_wait`, diagnostics |
| `tests/integration/cases/*.sh` | one scenario each; header comments declare `summary:`, `tags:`, `requires:` |
| `tests/test-integration-runner.sh` | **hermetic** unit test of selection/skip/require accounting — fake `docker`, synthetic cases, no daemon. Joins the existing `tests/run-all.sh` suite. |
| `tests/test-integration-lib.sh` | **hermetic** unit test of `lib.sh`'s pure verbs (allowlist synthesis, comment filtering, header parsing) |
| `verify-on-host.sh` | shrinks to preflight + delegation; keeps Phases 1–3 as named selections |
| `.github/workflows/tests.yml` | gains `lint` and `integration-fast` jobs alongside the existing `suite` job |
| `.github/workflows/nightly.yml` | new: `integration-full`, `allowlist-health`, `packages` |

`lib.sh` resolves the engine directory tolerantly (`../..`, else `../../base`) so one copy serves both `ai-containers` and `mgd-ai-containers`.

---

## Execution environment note

**This dev container has no Docker daemon.** Tasks 1, 2, 10 and 12 are fully executable here (hermetic bash). Every other task needs a real daemon and is verified one of two ways:

- **a host** — macOS + Colima or a Linux workstation, via `bash ./verify-on-host.sh`;
- **GitHub Actions** — push the working branch and run the `integration` job by `workflow_dispatch` (`gh` is authenticated with `repo` scope here). Task 3 wires this up precisely so later tasks have a Docker host available without leaving the session.

Prefer the CI path while iterating; it is autonomous. Use a host for the final green run on macOS (success criterion 2).

---

## Task 0: Answer the CI capability question before building anything

The whole increment rests on one unverified assumption: that a container on `ubuntu-latest` can create ipsets, install `-m set --match-set` and `NFLOG` iptables rules, and open an `nflog:` capture interface. If it cannot, the security cases can never gate a PR and the design's CI section is wrong. Fifteen cases written against a false assumption is the expensive way to find out.

**Files:**
- Create (temporary, deleted in step 6): `.github/workflows/it-probe.yml`
- Modify: `docs/superpowers/plans/2026-08-06-integration-test-suite-increment-1.md` (record the answer)

**Interfaces:**
- Produces: a recorded yes/no that Task 3's `have_netadmin()` capability detector and Task 11's CI job selection both depend on.

- [ ] **Step 1: Create the probe branch and workflow**

```bash
git checkout -b it-capability-probe
```

Create `.github/workflows/it-probe.yml`:

```yaml
name: IT capability probe
# Throwaway. Answers one question: can a container on ubuntu-latest do what
# restricted mode needs (ipset + match-set + NFLOG + an nflog capture handle)?
# Deleted once the answer is recorded in the increment-1 plan.
on: workflow_dispatch

permissions:
  contents: read

jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Runner kernel and netfilter modules
        run: |
          uname -a
          echo "── currently loaded ──"
          lsmod | grep -E 'ip_set|nfnetlink|nflog' || echo "(none loaded)"
          echo "── modprobe ──"
          sudo modprobe ip_set        && echo "ip_set OK"        || echo "ip_set FAILED"
          sudo modprobe nfnetlink_log && echo "nfnetlink_log OK" || echo "nfnetlink_log FAILED"
          sudo modprobe xt_NFLOG      && echo "xt_NFLOG OK"      || echo "xt_NFLOG FAILED"

      - name: NET_ADMIN + ipset + match-set + NFLOG inside a container
        run: |
          docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
            -e DEBIAN_FRONTEND=noninteractive ubuntu:24.04 bash -c '
              echo "wireshark-common wireshark-common/install-setuid boolean false" \
                | debconf-set-selections
              apt-get update -qq >/dev/null
              apt-get install -y -qq --no-install-recommends \
                iptables ipset tshark curl >/dev/null
              rc() { echo "  -> rc=$?"; }
              echo "ipset create v4:";      ipset create probe_v4 hash:net family inet;  rc
              echo "ipset create v6:";      ipset create probe_v6 hash:net family inet6; rc
              echo "ipset add:";            ipset add probe_v4 10.99.0.1;                rc
              echo "policy DROP:";          iptables -P OUTPUT DROP;                     rc
              echo "match-set rule:";       iptables -A OUTPUT -m set --match-set probe_v4 dst -j ACCEPT; rc
              echo "NFLOG rule:";           iptables -A OUTPUT -j NFLOG --nflog-group 100; rc
              echo "ip6tables policy:";     ip6tables -P OUTPUT DROP;                    rc
              echo "── iptables -S OUTPUT ──"; iptables -S OUTPUT
              echo "── nflog capture handle ──"
              timeout 10 tshark -i nflog:100 -c 1 -T fields -e ip.dst >/tmp/nflog.out 2>/tmp/nflog.err &
              tsh=$!
              sleep 3
              timeout 4 curl -s -o /dev/null http://10.99.0.99/ ; echo "curl to dropped dest rc=$?"
              wait $tsh 2>/dev/null
              echo "nflog stdout: [$(cat /tmp/nflog.out)]"
              echo "nflog stderr: [$(head -3 /tmp/nflog.err)]"
            '

      - name: Minimal image builds, and how long it takes
        run: |
          sed -E 's/^(copilot|kiro|claude-code|codex|gemini|graphify|github-cli|bun|vale|qmd|dtctl|dtmgd|acli|angular-cli|yarn|pnpm|goreleaser|kubectl|aws-cli|azure-cli|imagemagick|wkhtmltopdf)=.*/\1=OFF/' \
            sandbox.conf > /tmp/minimal.conf
          grep -vE '^\s*(#|$)' /tmp/minimal.conf
          start=$SECONDS
          SANDBOX_CONF=/tmp/minimal.conf IMAGE_NAME=ai-sandbox-it ./build.sh ai-sandbox-it
          echo "minimal image build took $((SECONDS - start))s"
          docker image inspect ai-sandbox-it --format '{{.Size}}' \
            | awk '{printf "image size: %.2f GB\n", $1/1024/1024/1024}'
          echo "── node present (the sidecar runtime) ──"
          docker run --rm --entrypoint node ai-sandbox-it --version
          echo "── python3 present? (spec assumed yes; expect NOT) ──"
          docker run --rm --entrypoint bash ai-sandbox-it -c 'command -v python3 || echo "no python3 — confirms correction 1"'
```

- [ ] **Step 2: Push and trigger**

```bash
git add .github/workflows/it-probe.yml
git commit -m "chore(ci): throwaway probe for NET_ADMIN/ipset/NFLOG on ubuntu-latest"
git push -u origin it-capability-probe
gh workflow run it-probe.yml --ref it-capability-probe
```

- [ ] **Step 3: Watch it and capture the output**

```bash
sleep 10
gh run list --workflow=it-probe.yml --limit 1
gh run watch "$(gh run list --workflow=it-probe.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
gh run view "$(gh run list --workflow=it-probe.yml --limit 1 --json databaseId -q '.[0].databaseId')" --log > /tmp/it-probe.log
```

- [ ] **Step 4: Read the answer**

Expected (the design's assumption holds): every `rc=0`, `iptables -S OUTPUT` shows both the match-set and NFLOG rules, and `nflog stdout` contains `10.99.0.99`.

Failure signatures and what each means:
- `ipset create … rc=1` with "Kernel error received: Operation not permitted" → `ip_set` unavailable on the runner. Security cases become local-only; CI runs the non-`netadmin` subset and the `integration-fast` job must be **removed** from `tests.yml`, not left silently skipping.
- NFLOG rule adds but `nflog stderr` says "The capture session could not be initiated" → `nfnetlink_log` missing. Cases `040`, `050`, `060`, `080`, `085` become local-only; `010`/`020`/`030`/`070` (pure enforcement, no capture) still gate PRs.
- Both work → proceed as designed, no plan changes.

- [ ] **Step 5: Record the answer in this plan**

Append a `## Task 0 result` section to this file stating, verbatim from the log: whether ipset/match-set/NFLOG/nflog-capture each worked, the minimal-image build time and size, and which of the three outcomes above applies. This is the input to Task 3's `have_netadmin()` and Task 11's job list.

- [ ] **Step 6: Delete the probe and return to main**

```bash
git rm .github/workflows/it-probe.yml
git commit -m "chore(ci): drop the capability probe — answer recorded in the increment-1 plan"
git push
git checkout main
git branch -D it-capability-probe
git push origin --delete it-capability-probe
```

The plan edit from step 5 is committed separately on the working branch in Task 1.

---

## Task 1: The runner — selection, skip accounting, `--require` enforcement

This is the task that encodes design principle 2 ("a case that cannot run is not a pass") and principle 3 ("one corpus, tags select"). It is entirely hermetic: no Docker needed to build it or to test it.

**Files:**
- Create: `tests/integration/run.sh`
- Create: `tests/test-integration-runner.sh`

**Interfaces:**
- Produces, for `lib.sh` (Task 2) and every case: the exported environment `IT_RUN_ID`, `IT_IMAGE`, `IT_NET`, `IT_SCRATCH`, `IT_LABEL`, `IT_GENERATED_ALLOWLIST_DIR`, `IT_DNS_IMAGE`, `IT_CONNECT_TIMEOUT`, `IT_SETTLE`.
- Produces, for cases: the exit-code contract — **0** = pass, **77** = case-declared skip, **124** = timed out (runner maps to FAIL), anything else = fail. A case exiting 0 having printed no `PASS:` line is a FAIL ("asserted nothing"), matching `tests/run-all.sh:79-84`.
- Produces, for the unit test: `IT_CASES_DIR` (case directory override) and `IT_FORCE_CAPS` (capability-detection override, always reported in the banner).
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing test**

Create `tests/test-integration-runner.sh`:

```bash
#!/usr/bin/env bash
# Hermetic unit test for tests/integration/run.sh — the SELECTION and ACCOUNTING
# logic, with no Docker daemon and no real cases.
#
# What it pins, and why it is the most important test in the suite:
#   Selection and skipping are different things, and conflating them reopens the
#   hole the integration suite exists to close. --tags/--exclude decide what is
#   SELECTED (a deliberate, visible choice recorded in the workflow). A SKIP is a
#   case that WAS selected and then could not run. --require makes a skip inside
#   the selected set fatal. If those two ever collapse into one number, "we chose
#   not to check this" starts reading as "this passed" — which is exactly the
#   false confidence that let a dead capture daemon look green for months.
#
# Hermetic: synthetic cases in a temp dir via IT_CASES_DIR, capabilities forced
# via IT_FORCE_CAPS, fake docker on PATH so nothing can reach a real daemon.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_DIR/tests/integration/run.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$RUN" && pass "run.sh bash -n" || fail "run.sh bash -n"

# ── A fake docker that fails loudly if anything actually calls it ───────────────
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# Only the calls the runner legitimately makes with --reuse-image are allowed.
case "$1 ${2:-}" in
  "network create"|"network rm"|"network inspect") echo "it-net-fake"; exit 0 ;;
  "container prune"|"volume prune"|"network prune") exit 0 ;;
  "image inspect") exit 0 ;;
  *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"

# ── Synthetic corpus ────────────────────────────────────────────────────────────
CASES="$TMP/cases"; mkdir -p "$CASES"
mkcase() {  # $1=name $2=tags $3=requires $4=body
  cat > "$CASES/$1.sh" <<EOF
#!/usr/bin/env bash
# summary:  synthetic $1
# tags:     $2
# requires: $3
$4
EOF
}
mkcase 010-alpha  "security fast"        "docker"          'echo "PASS: alpha"; exit 0'
mkcase 020-beta   "network-mode fast"    "docker"          'echo "PASS: beta"; exit 0'
mkcase 030-gamma  "security fast"        "docker netadmin" 'echo "PASS: gamma"; exit 0'
mkcase 040-delta  "network-mode slow"    "docker"          'echo "PASS: delta"; exit 0'
mkcase 050-eps    "security needs-dns"   "docker dns"      'echo "PASS: eps"; exit 0'
mkcase 060-zeta   "security fast"        "docker"          'echo "FAIL: zeta"; exit 1'
mkcase 070-eta    "security fast"        "docker"          'exit 0'            # asserts nothing
mkcase 080-theta  "security fast"        "docker"          'echo "SKIP: no fixture"; exit 77'

run_it() {  # args… → combined output; exit code appended as a marker line
  local out rc
  out="$(PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" IT_SCRATCH="$TMP/scratch" \
        bash "$RUN" --reuse-image --image fake-img "$@" 2>&1)"
  rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

has() { printf '%s' "$1" | grep -qE "$2"; }
rc_of() { printf '%s' "$1" | sed -n 's/^RC=//p' | tail -1; }

# ── --list needs no capabilities and no daemon ─────────────────────────────────
out="$(IT_CASES_DIR="$CASES" bash "$RUN" --list 2>&1)"
has "$out" '010-alpha' && pass "--list shows a case" || fail "--list shows a case"
has "$out" 'security fast' && pass "--list shows tags" || fail "--list shows tags"

# ── Tag selection ──────────────────────────────────────────────────────────────
out="$(run_it --tags fast --exclude needs-dns IT_FORCE=1)" 2>/dev/null
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags fast)"
has "$out" 'selected 6 of 8' \
  && pass "--tags fast selects exactly the 6 fast cases" \
  || fail "--tags fast selects exactly the 6 fast cases -- got: $(printf '%s' "$out" | grep selected)"

out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags security --exclude needs-dns)"
has "$out" 'selected 5 of 8' \
  && pass "--exclude removes needs-dns from a security selection" \
  || fail "--exclude removes needs-dns from a security selection -- got: $(printf '%s' "$out" | grep selected)"

# ── Selection and skipping are reported SEPARATELY ─────────────────────────────
out="$(IT_FORCE_CAPS="docker" run_it --tags security)"
has "$out" 'selected 6 of 8' \
  && pass "unmet requirements do not change the SELECTED count" \
  || fail "unmet requirements do not change the SELECTED count"
has "$out" 'skipped 3' \
  && pass "skips are counted separately from selection" \
  || fail "skips are counted separately from selection -- got: $(printf '%s' "$out" | grep skipped)"

# ── Every skip prints its unmet requirement ────────────────────────────────────
has "$out" '030-gamma.*SKIP.*netadmin' \
  && pass "a skip names the unmet requirement" \
  || fail "a skip names the unmet requirement"
has "$out" '080-theta.*SKIP.*no fixture' \
  && pass "a case-declared skip (exit 77) reports its own reason" \
  || fail "a case-declared skip (exit 77) reports its own reason"

# ── --require turns a skip inside the selected set into a failure ──────────────
out="$(IT_FORCE_CAPS="docker" run_it --tags security --require security)"
[[ "$(rc_of "$out")" != "0" ]] \
  && pass "--require security fails the run when a security case skipped" \
  || fail "--require security fails the run when a security case skipped"
has "$out" 'required tag .security.' \
  && pass "--require failure names the tag and the skipped cases" \
  || fail "--require failure names the tag and the skipped cases"

# ── ...but --require only applies INSIDE the selected set ──────────────────────
# 050-eps (needs-dns) is deliberately EXCLUDED, not skipped. Excluding it must not
# trip --require: a deliberate selection is not a silent hole.
out="$(IT_FORCE_CAPS="docker netadmin" run_it --tags security --exclude needs-dns --require security)"
[[ "$(rc_of "$out")" == "0" ]] \
  && pass "--require ignores cases removed by --exclude (selection != skip)" \
  || fail "--require ignores cases removed by --exclude -- got rc=$(rc_of "$out")"

# ── Failure accounting ─────────────────────────────────────────────────────────
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags fast)"
has "$out" '060-zeta.*FAIL' && pass "a failing case is reported FAIL" || fail "a failing case is reported FAIL"
[[ "$(rc_of "$out")" != "0" ]] && pass "a failing case fails the run" || fail "a failing case fails the run"

# ── The asserted-nothing guard, carried over from tests/run-all.sh ─────────────
has "$out" '070-eta.*FAIL.*asserted nothing' \
  && pass "exit 0 with no PASS line is FAIL, not a silent pass" \
  || fail "exit 0 with no PASS line is FAIL, not a silent pass"

# ── Timeout is enforced per case, not per run ─────────────────────────────────
mkcase 090-hang "fast" "docker" 'echo "PASS: started"; sleep 60'
out="$(IT_FORCE_CAPS="docker" run_it --tags fast --timeout 2)"
has "$out" '090-hang.*FAIL.*timed out' \
  && pass "a hanging case is killed and reported as timed out" \
  || fail "a hanging case is killed and reported as timed out"
rm -f "$CASES/090-hang.sh"

# ── A forced capability set is never silent ───────────────────────────────────
out="$(IT_FORCE_CAPS="docker" run_it --list-caps)"
has "$out" 'FORCED' \
  && pass "IT_FORCE_CAPS is reported in the banner, never applied silently" \
  || fail "IT_FORCE_CAPS is reported in the banner, never applied silently"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-integration-runner.sh
```
Expected: `FAIL: run.sh bash -n` and every subsequent assertion failing — `run.sh` does not exist yet.

- [ ] **Step 3: Write `tests/integration/run.sh`**

```bash
#!/usr/bin/env bash
# run.sh — the runtime integration test runner.
#
# Cases never know whether they are on CI. They declare `tags:` and `requires:`
# in header comments; this script detects what the machine can actually do,
# SELECTS a subset by tag, executes each selected case as its own process under
# `timeout`, and reports selection and skips as SEPARATE counts.
#
# That separation is the point. --tags/--exclude decide what is selected — a
# deliberate, visible choice recorded in the workflow. A SKIP is a case that WAS
# selected and then could not run because a requirement was unmet. --require
# makes any skip inside the selected set fatal. Collapsing the two would let
# "we chose not to check this" read as "this passed".
#
# Written for bash 3.2 (stock macOS bash).
set -uo pipefail

INT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Layout-tolerant: upstream ai-containers keeps the engine beside tests/;
# mgd-ai-containers keeps it in base/ with tests/ one level up.
REPO_DIR="$(cd "$INT_DIR/../.." && pwd)"
[[ -f "$REPO_DIR/build.sh" ]] || REPO_DIR="$(cd "$INT_DIR/../../base" && pwd)"

CASES_DIR="${IT_CASES_DIR:-$INT_DIR/cases}"
IT_RUN_ID="${IT_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
IT_LABEL="ai-containers.it-run=$IT_RUN_ID"
# Under $HOME, never $TMPDIR: this becomes a bind-mount source, and macOS
# /var/folders is not shared with the Colima VM — the container would write into
# the VM and the host would read an empty directory.
IT_SCRATCH="${IT_SCRATCH:-$HOME/.cache/ai-containers-it/$IT_RUN_ID}"
IT_IMAGE="${IT_IMAGE:-ai-sandbox-it}"
IT_NET="${IT_NET:-ai-containers-it-$IT_RUN_ID}"
IT_DNS_IMAGE="${IT_DNS_IMAGE:-coredns/coredns:1.11.3}"
IT_CONNECT_TIMEOUT="${IT_CONNECT_TIMEOUT:-5}"
IT_SETTLE="${IT_SETTLE:-45}"
IT_GENERATED_ALLOWLIST_DIR="$IT_SCRATCH/generated-allowlists"

want_tags=""; excl_tags=""; req_tags=""
do_list=0; do_list_caps=0; reuse_image=0; keep=0; verbose=0
timeout_secs=300

usage() {
  cat <<'EOF'
Usage: tests/integration/run.sh [options]

  --tags T[,T…]      run only cases carrying at least one of these tags
  --exclude T[,T…]   drop cases carrying any of these tags
  --require T[,T…]   fail the run if any SELECTED case with this tag SKIPPED
  --timeout N        per-case timeout in seconds (default 300)
  --image NAME       image tag to build/use (default ai-sandbox-it)
  --reuse-image      do not build; use the existing --image
  --keep             keep the image, network and scratch dir after the run
  --list             list cases with their tags/requires and exit
  --list-caps        print detected capabilities and exit
  -v, --verbose      stream each case's full output
  -h, --help         this text

Tags: network-mode mounts volumes groups packages | security | fast slow |
      needs-external needs-netadmin needs-dns | harness
Requires: docker netadmin sidecar dns external
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tags)     want_tags="${2//,/ }"; shift 2 ;;
    --exclude)  excl_tags="${2//,/ }"; shift 2 ;;
    --require)  req_tags="${2//,/ }";  shift 2 ;;
    --timeout)  timeout_secs="$2";     shift 2 ;;
    --image)    IT_IMAGE="$2";         shift 2 ;;
    --reuse-image) reuse_image=1; shift ;;
    --keep)     keep=1;    shift ;;
    --list)     do_list=1; shift ;;
    --list-caps) do_list_caps=1; shift ;;
    -v|--verbose) verbose=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'run.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── Case metadata ───────────────────────────────────────────────────────────────
case_meta() {  # $1=file $2=key → the header value, or empty
  sed -n "s/^#[[:space:]]*$2:[[:space:]]*//p" "$1" | head -1
}

list_intersects() {  # $1, $2 = space-separated lists → 0 if they share a member
  local a b
  for a in $1; do for b in $2; do [[ "$a" == "$b" ]] && return 0; done; done
  return 1
}

all_cases() {
  local f
  for f in "$CASES_DIR"/*.sh; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
}

# ── Capability detection ────────────────────────────────────────────────────────
# Memoised, and lazy: --list must work on a machine with no daemon at all.
_caps=""; _caps_forced=0
detect_caps() {
  [[ -n "$_caps" ]] && return 0
  if [[ -n "${IT_FORCE_CAPS:-}" ]]; then
    _caps=" ${IT_FORCE_CAPS} "; _caps_forced=1; return 0
  fi
  local c=""
  if docker info >/dev/null 2>&1; then
    c="$c docker"
    if docker network create --label "$IT_LABEL" "${IT_NET}-probe" >/dev/null 2>&1; then
      c="$c sidecar"
      docker network rm "${IT_NET}-probe" >/dev/null 2>&1 || true
    fi
    if [[ "$reuse_image" -eq 1 ]] || docker image inspect "$IT_IMAGE" >/dev/null 2>&1; then
      probe_netadmin && c="$c netadmin"
    fi
    docker image inspect "$IT_DNS_IMAGE" >/dev/null 2>&1 && c="$c dns"
  fi
  curl -fsS --max-time 8 -o /dev/null https://example.com 2>/dev/null && c="$c external"
  _caps=" $c "
}

# Can a container here create an ipset and install match-set + NFLOG rules?
# This is the single question the whole security tier rests on (see Task 0).
probe_netadmin() {
  docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW --label "$IT_LABEL" \
    --entrypoint bash "$IT_IMAGE" -c '
      ipset create it_probe hash:net family inet   >/dev/null 2>&1 || exit 1
      iptables -A OUTPUT -m set --match-set it_probe dst -j ACCEPT >/dev/null 2>&1 || exit 1
      iptables -A OUTPUT -j NFLOG --nflog-group 100 >/dev/null 2>&1 || exit 1
    ' >/dev/null 2>&1
}

have_cap() { detect_caps; case "$_caps" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

unmet_requirement() {  # $1 = space-separated requires → prints the FIRST unmet one
  local r
  for r in $1; do have_cap "$r" || { printf '%s' "$r"; return 0; }; done
  return 1
}

# ── --list / --list-caps ────────────────────────────────────────────────────────
if [[ "$do_list" -eq 1 ]]; then
  for f in $(all_cases); do
    printf '%-46s  tags: %-34s  requires: %s\n' \
      "$(basename "$f" .sh)" "$(case_meta "$f" tags)" "$(case_meta "$f" requires)"
  done
  exit 0
fi
if [[ "$do_list_caps" -eq 1 ]]; then
  detect_caps
  printf 'capabilities:%s%s\n' "$_caps" \
    "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"
  exit 0
fi

# ── Image build + allowlist snapshot ────────────────────────────────────────────
# build.sh regenerates allowlist-*.txt IN THE REPO from sandbox.conf. Building
# from a minimal config would otherwise leave the developer's real allowlists
# replaced by a stripped-down set, silently, until their next ./build.sh.
saved_allowlists="$IT_SCRATCH/saved-allowlists"
snapshot_real_allowlists() {
  mkdir -p "$saved_allowlists"
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    [[ -f "$REPO_DIR/$f" ]] && cp "$REPO_DIR/$f" "$saved_allowlists/$f"
  done
  return 0
}
restore_real_allowlists() {
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    [[ -f "$saved_allowlists/$f" ]] && cp "$saved_allowlists/$f" "$REPO_DIR/$f"
  done
  return 0
}

build_image() {
  local conf="$IT_SCRATCH/minimal-sandbox.conf"
  # Everything optional OFF: the firewall does not know which fragment a domain
  # came from, so proving admit/drop once proves it for every fragment. Version
  # lists are emptied; boolean keys are turned OFF.
  sed -E 's/^([a-z0-9-]+)=ON$/\1=OFF/; s/^(node|python|ruby|rust|go|openjdk|graalvm-ce|graalvm-oracle|kotlin|scala|maven|gradle|db-clients|angular-cli)=.*/\1=/' \
    "$REPO_DIR/sandbox.conf" > "$conf"
  say "── building $IT_IMAGE from a minimal sandbox.conf…"
  ( cd "$REPO_DIR" && SANDBOX_CONF="$conf" IMAGE_NAME="$IT_IMAGE" ./build.sh "$IT_IMAGE" ) \
    > "$IT_SCRATCH/build.log" 2>&1 || {
      warn "run.sh: image build FAILED — last 40 lines of $IT_SCRATCH/build.log:"
      tail -40 "$IT_SCRATCH/build.log" >&2
      return 1
    }
  # Snapshot what build.sh generated, for the delivery case (300).
  mkdir -p "$IT_GENERATED_ALLOWLIST_DIR"
  local f
  for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
    cp "$REPO_DIR/$f" "$IT_GENERATED_ALLOWLIST_DIR/$f"
  done
  say "   build OK"
}

# ── Teardown ────────────────────────────────────────────────────────────────────
sweep() {
  restore_real_allowlists
  docker ps -aq --filter "label=$IT_LABEL" 2>/dev/null | while read -r c; do
    [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1
  done
  docker network ls -q --filter "label=$IT_LABEL" 2>/dev/null | while read -r n; do
    [[ -n "$n" ]] && docker network rm "$n" >/dev/null 2>&1
  done
  if [[ "$keep" -eq 0 ]]; then
    [[ "$reuse_image" -eq 0 ]] && docker rmi "$IT_IMAGE" >/dev/null 2>&1
    rm -rf "$IT_SCRATCH"
  else
    say "── kept: image $IT_IMAGE, scratch $IT_SCRATCH"
  fi
  return 0
}
trap 'sweep' EXIT

mkdir -p "$IT_SCRATCH/logs"
snapshot_real_allowlists

if [[ "$reuse_image" -eq 0 ]]; then
  build_image || exit 1
fi
docker network create --label "$IT_LABEL" "$IT_NET" >/dev/null 2>&1 || true

export IT_RUN_ID IT_LABEL IT_SCRATCH IT_IMAGE IT_NET IT_DNS_IMAGE \
       IT_CONNECT_TIMEOUT IT_SETTLE IT_GENERATED_ALLOWLIST_DIR

# ── Selection ───────────────────────────────────────────────────────────────────
total=0; selected=""
for f in $(all_cases); do
  total=$((total + 1))
  tags="$(case_meta "$f" tags)"
  [[ -n "$want_tags" ]] && { list_intersects "$tags" "$want_tags" || continue; }
  [[ -n "$excl_tags" ]] && { list_intersects "$tags" "$excl_tags" && continue; }
  selected="${selected:+$selected }$f"
done

detect_caps
printf 'capabilities:%s%s\n\n' "$_caps" \
  "$([[ "$_caps_forced" -eq 1 ]] && printf ' (FORCED via IT_FORCE_CAPS)')"

# ── Execution ───────────────────────────────────────────────────────────────────
n_pass=0; n_fail=0; n_skip=0; n_sel=0
failed_names=""; skipped_names=""; skipped_tags=""
for f in $selected; do
  name="$(basename "$f" .sh)"
  n_sel=$((n_sel + 1))
  tags="$(case_meta "$f" tags)"
  reqs="$(case_meta "$f" requires)"
  log="$IT_SCRATCH/logs/$name.log"

  if missing="$(unmet_requirement "$reqs")"; then
    printf '%-46s  SKIP  (requires: %s)\n' "$name" "$missing"
    n_skip=$((n_skip + 1))
    skipped_names="${skipped_names:+$skipped_names }$name"
    skipped_tags="${skipped_tags}|${name}:${tags}"
    continue
  fi

  started=$SECONDS
  if [[ "$verbose" -eq 1 ]]; then
    timeout "$timeout_secs" bash "$f" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  else
    timeout "$timeout_secs" bash "$f" > "$log" 2>&1; rc=$?
  fi
  took=$((SECONDS - started))
  n_ok="$(grep -c '^PASS:' "$log" 2>/dev/null || echo 0)"

  if [[ "$rc" -eq 77 ]]; then
    printf '%-46s  SKIP  (%s)\n' "$name" \
      "$(grep -m1 '^SKIP:' "$log" | sed 's/^SKIP:[[:space:]]*//')"
    n_skip=$((n_skip + 1))
    skipped_names="${skipped_names:+$skipped_names }$name"
    skipped_tags="${skipped_tags}|${name}:${tags}"
  elif [[ "$rc" -eq 124 ]]; then
    printf '%-46s  FAIL  (timed out after %ss)\n' "$name" "$timeout_secs"
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$rc" -ne 0 ]]; then
    printf '%-46s  FAIL  (exit %s, %ss)\n' "$name" "$rc" "$took"
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  elif [[ "$n_ok" -eq 0 ]]; then
    # Exiting 0 without asserting anything is not a pass: it is a case that
    # silently did nothing (bad guard, early return, renamed helper).
    printf '%-46s  FAIL  (exited 0 but asserted nothing)\n' "$name"
    n_fail=$((n_fail + 1)); failed_names="${failed_names:+$failed_names }$name"
  else
    printf '%-46s  PASS  (%s assertion(s), %ss)\n' "$name" "$n_ok" "$took"
    n_pass=$((n_pass + 1))
  fi

  if [[ "$rc" -ne 0 && "$verbose" -eq 0 ]]; then
    sed 's/^/     /' "$log" | tail -40
  fi
done

# ── Report ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf 'selected %s of %s   passed %s  failed %s  skipped %s\n' \
  "$n_sel" "$total" "$n_pass" "$n_fail" "$n_skip"
[[ -n "$failed_names"  ]] && printf 'failing: %s\n' "$failed_names"
[[ -n "$skipped_names" ]] && printf 'skipped: %s\n' "$skipped_names"

# ── --require: a skip inside the selected set is a failure ─────────────────────
req_violation=0
for t in $req_tags; do
  hit=""
  # skipped_tags entries look like |<name>:<tag> <tag>…
  printf '%s' "$skipped_tags" | tr '|' '\n' | while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    ename="${entry%%:*}"; etags="${entry#*:}"
    list_intersects "$etags" "$t" && printf '%s\n' "$ename"
  done > "$IT_SCRATCH/req-hits.$t"
  hit="$(tr '\n' ' ' < "$IT_SCRATCH/req-hits.$t")"
  if [[ -n "${hit// /}" ]]; then
    printf 'ERROR: required tag "%s" — these selected cases SKIPPED: %s\n' "$t" "$hit" >&2
    printf '       A case that cannot run is not a pass. Fix the environment or\n' >&2
    printf '       exclude the tag deliberately with --exclude.\n' >&2
    req_violation=1
  fi
done

[[ "$n_fail" -gt 0 || "$req_violation" -eq 1 ]] && exit 1
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-integration-runner.sh
```
Expected: `0 failure(s)`. Then confirm it joins the existing suite:
```bash
bash tests/run-all.sh integration-runner
```
Expected: `PASS (N assertion(s))`.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/integration/run.sh tests/test-integration-runner.sh
git add tests/integration/run.sh tests/test-integration-runner.sh \
        docs/superpowers/plans/2026-08-06-integration-test-suite-increment-1.md
git commit -m "test(integration): runner with tag selection and skip-is-not-a-pass accounting

Selection and skipping are reported as separate counts and --require makes a
skip inside the selected set fatal, so 'we chose not to check this' can never
read as 'this passed'. Hermetic unit test drives it with synthetic cases, a
forced capability set, and a fake docker.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: `lib.sh` — the verbs every case uses

**Files:**
- Create: `tests/integration/lib.sh`
- Create: `tests/test-integration-lib.sh`

**Interfaces:**
- Consumes from Task 1: the exported `IT_RUN_ID`, `IT_IMAGE`, `IT_NET`, `IT_SCRATCH`, `IT_LABEL`, `IT_GENERATED_ALLOWLIST_DIR`, `IT_DNS_IMAGE`, `IT_CONNECT_TIMEOUT`, `IT_SETTLE`; the exit-code contract (0/77/other) and the "must print at least one `PASS:`" rule.
- Produces, for every case in Tasks 3–9 — exact signatures:

  | Verb | Signature | Result |
  |---|---|---|
  | `pass` / `fail` | `pass <msg>` | prints `PASS:`/`FAIL:`; `fail` increments `$it_fails` |
  | `skip` | `skip <reason>` | prints `SKIP: <reason>` and exits 77 |
  | `it_finish` | `it_finish` | prints the failure count, exits `$it_fails` |
  | `it_scratch` | `it_scratch` → path | a tracked per-case dir under `$IT_SCRATCH` |
  | `it_wait` | `it_wait <secs> <cmd> [args…]` | 0 when the command first succeeds, 1 on timeout |
  | `allowlist_write` | `allowlist_write <dir> <domains> <cidrs> <proxy>` | writes all three `allowlist-*.txt`; each argument is a space-separated entry list, `""` for none |
  | `sidecar_up` | `sidecar_up` | sets **`$IT_SIDECAR`** (name) and **`$IT_SIDECAR_IP`**; returns 0/1 |
  | `sidecar_down` | `sidecar_down [name]` | removes it |
  | `dns_up` | `dns_up <fqdn> <ip> [<fqdn> <ip>…]` | sets **`$IT_DNS`** and **`$IT_DNS_IP`**; returns 0/1 |
  | `sandbox_up` | `sandbox_up <mode> <allowlist-dir> [docker-run-args…]` | sets **`$IT_CID`**; returns 0/1 |
  | `sandbox_exec` | `sandbox_exec <cid> <bash -c string>` | runs it as root in the container |
  | `sandbox_down` | `sandbox_down <cid>` | removes it |
  | `reach` | `reach <cid> <host> [port=8080]` | 0 reachable, 1 not |
  | `pid1_caps` | `pid1_caps <cid>` → string | decoded effective capabilities **of the agent shell**, not of a new `docker exec` |
  | `blocked_entries` | `blocked_entries <cid> [file=blocked-ips.txt]` | non-comment, non-blank lines only |
  | `assert_reachable` / `assert_blocked` | same args as `reach` | assertion form |
  | `assert_file_exists` / `assert_file_absent` | `<cid> <path>` | in-container file assertions |
  | `assert_log_contains` | `<cid> <ERE>` | asserts `docker logs` matches |

  **Container-returning verbs set a global instead of printing** — a `$(sidecar_up)` would swallow the name into the same stdout as any diagnostic the verb emits. A case needing two sandboxes must copy `$IT_CID` after each call.

- [ ] **Step 1: Write the failing test**

Create `tests/test-integration-lib.sh`:

```bash
#!/usr/bin/env bash
# Hermetic unit test for the PURE verbs in tests/integration/lib.sh — the ones
# with no daemon behind them. The docker verbs are proven for real by the
# 000-harness-selftest case, which is the only honest way to test them.
#
# The comment-filtering assertions are load-bearing: init_output_files seeds
# every capture output file with explanatory headers, so a raw `-s` check reports
# a clean run as "HARD-BLOCKED" and then lists the header lines as if they were
# blocked destinations. That misreading cost a full host round trip.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_DIR/tests/integration/lib.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$LIB" && pass "lib.sh bash -n" || fail "lib.sh bash -n"

# lib.sh refuses to load without the runner's environment — a case run by hand
# would otherwise inherit whatever IT_IMAGE happened to be lying around.
out="$(env -u IT_RUN_ID -u IT_IMAGE -u IT_NET bash -c ". '$LIB'" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "lib.sh refuses to load outside the runner" \
                  || fail "lib.sh refuses to load outside the runner"

export IT_RUN_ID=unit IT_IMAGE=unit-img IT_NET=unit-net IT_SCRATCH="$TMP/scratch"
export IT_LABEL="ai-containers.it-run=unit" IT_DNS_IMAGE=unit-dns
mkdir -p "$IT_SCRATCH"
# shellcheck disable=SC1090
. "$LIB"

# ── allowlist_write ────────────────────────────────────────────────────────────
d="$(it_scratch)"
allowlist_write "$d" "a.example b.example" "10.1.2.3" ""
for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
  # ALL THREE always, even when empty: refresh-ipset-allowlist.sh exits 1 on a
  # missing CIDR file and set -e in entrypoint.sh turns that into a dead
  # container with an error that points nowhere near the real cause.
  [[ -f "$d/$f" ]] && pass "allowlist_write always creates $f" \
                   || fail "allowlist_write always creates $f"
done
check "domains file holds both entries" \
  "a.example|b.example|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-domains.txt" | tr '\n' '|')"
check "cidrs file holds the IP" \
  "10.1.2.3|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-cidrs.txt" | tr '\n' '|')"
check "an empty list yields a comments-only file (the legal degenerate config)" \
  "" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-proxy-domains.txt" | tr '\n' '|')"
[[ -s "$d/allowlist-proxy-domains.txt" ]] \
  && pass "a comments-only allowlist is still NON-EMPTY (why -s is the wrong check)" \
  || fail "a comments-only allowlist is still NON-EMPTY"

# ── it_wait polls a condition instead of sleeping a guess ──────────────────────
touch_later() { ( sleep 1; touch "$TMP/flag" ) & }
rm -f "$TMP/flag"; touch_later
it_wait 10 test -f "$TMP/flag" && pass "it_wait returns as soon as the condition holds" \
                                || fail "it_wait returns as soon as the condition holds"
it_wait 2 test -f "$TMP/never" && fail "it_wait times out on a condition that never holds" \
                               || pass "it_wait times out on a condition that never holds"

# ── The comment filter used by blocked_entries ────────────────────────────────
printf '# header one\n# header two\n\n10.9.9.9\n  \n#trailing\n' > "$TMP/blocked-ips.txt"
check "it_strip_comments keeps only real entries" \
  "10.9.9.9|" "$(it_strip_comments < "$TMP/blocked-ips.txt" | tr '\n' '|')"
check "it_strip_comments on a comments-only file yields nothing" \
  "" "$(printf '# only\n\n' | it_strip_comments | tr '\n' '|')"

# ── pass/fail accounting drives the case exit code ────────────────────────────
( it_fails=0; fail "x" >/dev/null; [[ "$it_fails" -eq 1 ]] ) \
  && pass "fail increments it_fails" || fail "fail increments it_fails"

# ── The repo-dir resolver tolerates both layouts ──────────────────────────────
[[ -f "$IT_REPO_DIR/build.sh" ]] \
  && pass "IT_REPO_DIR resolves to the engine directory ($IT_REPO_DIR)" \
  || fail "IT_REPO_DIR resolves to the engine directory (got $IT_REPO_DIR)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-integration-lib.sh
```
Expected: `FAIL: lib.sh bash -n` — the file does not exist.

- [ ] **Step 3: Write `tests/integration/lib.sh`**

```bash
#!/usr/bin/env bash
# lib.sh — the verbs every integration case uses. SOURCED by a case, never run.
#
# Design rule the whole file follows: assert EFFECT, not configuration. A case
# observes from outside the container — did the packet arrive, does the file
# exist, does the log contain the line. tests/test-entrypoint-wiring.sh asserts
# the capture daemon is WIRED INTO entrypoint.sh, and it passed every single day
# of the outage, because the wiring was correct and the daemon died after being
# started.
#
# Written for bash 3.2 (stock macOS bash): no associative arrays, and empty
# arrays expand as "${a[@]+"${a[@]}"}" because a bare "${a[@]}" aborts under
# set -u on 3.2.

: "${IT_RUN_ID:?lib.sh: run cases through tests/integration/run.sh (IT_RUN_ID unset)}"
: "${IT_IMAGE:?lib.sh: run cases through tests/integration/run.sh (IT_IMAGE unset)}"
: "${IT_NET:?lib.sh: run cases through tests/integration/run.sh (IT_NET unset)}"

IT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IT_REPO_DIR="$(cd "$IT_LIB_DIR/../.." && pwd)"
[[ -f "$IT_REPO_DIR/build.sh" ]] || IT_REPO_DIR="$(cd "$IT_LIB_DIR/../../base" && pwd)"

IT_LABEL="${IT_LABEL:-ai-containers.it-run=$IT_RUN_ID}"
IT_SCRATCH="${IT_SCRATCH:-$HOME/.cache/ai-containers-it/$IT_RUN_ID}"
IT_CONNECT_TIMEOUT="${IT_CONNECT_TIMEOUT:-5}"
IT_SETTLE="${IT_SETTLE:-45}"
IT_SIDECAR=""; IT_SIDECAR_IP=""; IT_CID=""; IT_DNS=""; IT_DNS_IP=""

it_fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; it_fails=$((it_fails + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; exit 77; }
it_finish() { printf '\n%d failure(s)\n' "$it_fails"; exit "$it_fails"; }

# ── Resource tracking ───────────────────────────────────────────────────────────
_it_resources=""
it_track() { _it_resources="${_it_resources}${_it_resources:+ }$1"; }
it_cleanup() {
  local r
  # Diagnostics BEFORE teardown: a failing case that tears down first leaves a
  # human with nothing but the assertion text, which costs a whole round trip.
  if [[ "$it_fails" -gt 0 && -n "$IT_CID" ]]; then it_diagnose "$IT_CID"; fi
  for r in $_it_resources; do
    case "$r" in
      container:*) docker rm -f "${r#container:}" >/dev/null 2>&1 || true ;;
      dir:*)       rm -rf "${r#dir:}" 2>/dev/null || true ;;
    esac
  done
}
trap 'it_cleanup' EXIT

it_scratch() {
  local d="$IT_SCRATCH/case-$$-$RANDOM"
  mkdir -p "$d"; it_track "dir:$d"; printf '%s' "$d"
}

# Poll a condition rather than sleeping a guess.
it_wait() {  # $1=timeout seconds, $2… = command
  local t="$1"; shift
  local i=0
  while [[ "$i" -lt "$t" ]]; do
    "$@" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

it_strip_comments() { awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }'; }

# ── Allowlist synthesis ─────────────────────────────────────────────────────────
_it_alist() {  # $1=path $2=space-separated entries
  { printf '# synthetic allowlist — written by the integration harness\n'
    printf '# %s\n\n' "$IT_RUN_ID"
    local e
    for e in ${2:-}; do printf '%s\n' "$e"; done
  } > "$1"
}
allowlist_write() {  # $1=dir $2=domains $3=cidrs $4=proxy-domains
  local d="$1"; mkdir -p "$d"
  _it_alist "$d/allowlist-domains.txt"       "${2:-}"
  _it_alist "$d/allowlist-cidrs.txt"         "${3:-}"
  _it_alist "$d/allowlist-proxy-domains.txt" "${4:-}"
  chmod 755 "$d"; chmod 644 "$d"/allowlist-*.txt
}

# ── Sidecar: the controllable destination ───────────────────────────────────────
# node, not python3: python3 only exists when python= is set in sandbox.conf
# (Dockerfile:165 symlinks the pyenv shim), while node is unconditional
# (Dockerfile:38-53 always installs the latest LTS and links it). The image is
# built from a MINIMAL config, so python3 is absent there by construction.
sidecar_up() {
  local name="it-sidecar-$$-$RANDOM"
  docker run -d --name "$name" --network "$IT_NET" --label "$IT_LABEL" \
    --entrypoint node "$IT_IMAGE" \
    -e 'require("http").createServer(function(q,s){s.end("sidecar-ok\n")}).listen(8080,"0.0.0.0")' \
    >/dev/null 2>&1 || { fail "sidecar_up: docker run failed"; return 1; }
  it_track "container:$name"
  if ! it_wait "$IT_SETTLE" docker exec "$name" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080'; then
    fail "sidecar_up: nothing listening on 8080 after ${IT_SETTLE}s"
    docker logs "$name" 2>&1 | tail -20 | sed 's/^/     /'
    return 1
  fi
  IT_SIDECAR="$name"
  IT_SIDECAR_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$IT_NET\").IPAddress }}" "$name" 2>/dev/null)"
  [[ -n "$IT_SIDECAR_IP" ]] || { fail "sidecar_up: no IP on network $IT_NET"; return 1; }
  return 0
}
sidecar_down() { docker rm -f "${1:-$IT_SIDECAR}" >/dev/null 2>&1 || true; }

# ── DNS sidecar (needs-dns cases only) ──────────────────────────────────────────
# Self-healing correlates a blocked IP to a domain through a map built by
# sniffing real port-53 RESPONSES. --add-host produces no DNS traffic at all, so
# without a real resolver the map stays empty and self-healing can never fire.
dns_up() {  # <fqdn> <ip> [<fqdn> <ip>…]
  local d name="it-dns-$$-$RANDOM"
  d="$(it_scratch)"
  { printf '.:53 {\n    hosts {\n'
    while [[ $# -ge 2 ]]; do printf '        %s %s\n' "$2" "$1"; shift 2; done
    printf '        fallthrough\n    }\n    errors\n}\n'
  } > "$d/Corefile"
  chmod 644 "$d/Corefile"
  docker run -d --name "$name" --network "$IT_NET" --label "$IT_LABEL" \
    -v "$d/Corefile:/Corefile:ro" "$IT_DNS_IMAGE" -conf /Corefile \
    >/dev/null 2>&1 || { fail "dns_up: docker run failed"; return 1; }
  it_track "container:$name"
  IT_DNS="$name"
  IT_DNS_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$IT_NET\").IPAddress }}" "$name" 2>/dev/null)"
  [[ -n "$IT_DNS_IP" ]] || { fail "dns_up: no IP on network $IT_NET"; return 1; }
  it_wait "$IT_SETTLE" docker logs "$name" 2>&1 >/dev/null || true
  return 0
}

# ── The sandbox under test ──────────────────────────────────────────────────────
sandbox_up() {  # $1=mode $2=allowlist dir; remaining args go to docker run
  local mode="$1" adir="$2"; shift 2
  local caps=""
  case "$mode" in
    restricted|discovery) caps="--cap-add=NET_ADMIN --cap-add=NET_RAW" ;;
    open)                 caps="" ;;   # sandbox.sh passes NO capabilities here
    *) fail "sandbox_up: unknown mode '$mode'"; return 1 ;;
  esac
  local cid
  cid="$(docker run -di --network "$IT_NET" --label "$IT_LABEL" $caps \
      -v "$adir:/it-allowlists:ro" \
      -e DEV_CONTAINER_MODE="$mode" \
      -e ALLOWLIST_DOMAINS_FILE=/it-allowlists/allowlist-domains.txt \
      -e ALLOWLIST_CIDRS_FILE=/it-allowlists/allowlist-cidrs.txt \
      -e ALLOWLIST_PROXY_DOMAINS_FILE=/it-allowlists/allowlist-proxy-domains.txt \
      -e SANDBOX_UID=1000 -e SANDBOX_GID=1000 \
      -e SANDBOX_USER=itsandbox -e SANDBOX_GROUP=itsandbox \
      -e ALLOW_IPV6_BYPASS=1 \
      "$@" "$IT_IMAGE" 2>&1)" || { fail "sandbox_up($mode): docker run failed: $cid"; return 1; }
  it_track "container:$cid"
  # Ready means the entrypoint finished and handed PID 1 to the agent shell:
  # it starts as root and becomes uid 1000 only after `exec capsh --user=`.
  # Anything weaker races the firewall setup and the capture daemon start.
  if ! it_wait "$IT_SETTLE" _it_pid1_is_sandbox "$cid"; then
    fail "sandbox_up($mode): entrypoint never handed over to the agent shell"
    docker logs "$cid" 2>&1 | tail -40 | sed 's/^/     /'
    return 1
  fi
  IT_CID="$cid"
  return 0
}
_it_pid1_is_sandbox() {
  [[ "$(docker exec "$1" awk '/^Uid:/{print $2; exit}' /proc/1/status 2>/dev/null | tr -dc '0-9')" == "1000" ]]
}
sandbox_exec() { docker exec "$1" bash -c "$2"; }
sandbox_down() { docker rm -f "${1:-$IT_CID}" >/dev/null 2>&1 || true; }

# ── The primitive most network cases reduce to ─────────────────────────────────
reach() {  # $1=cid $2=host-or-ip [$3=port]
  docker exec "$1" curl -fsS --connect-timeout "$IT_CONNECT_TIMEOUT" \
    --max-time "$IT_CONNECT_TIMEOUT" -o /dev/null "http://$2:${3:-8080}/" >/dev/null 2>&1
}

# The agent shell's capabilities, NOT a fresh docker exec's. `docker exec` starts
# from the container's capability bounding set and does not inherit the drops
# from `exec capsh --drop=…`, so asking it directly would report NET_ADMIN
# present in a container that correctly dropped it.
pid1_caps() {  # $1=cid
  docker exec "$1" bash -c \
    'capsh --decode=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/1/status) 2>/dev/null' 2>/dev/null
}

blocked_entries() {  # $1=cid [$2=file basename]
  docker exec "$1" cat "/workspace/.agent-blocked/${2:-blocked-ips.txt}" 2>/dev/null \
    | it_strip_comments
}

# ── Assertions ──────────────────────────────────────────────────────────────────
assert_reachable() {  # $1=cid $2=host [$3=port]
  if reach "$@"; then pass "reachable: $2:${3:-8080}"
  else fail "reachable: $2:${3:-8080} — curl could not connect"; fi
}
assert_blocked() {
  if reach "$@"; then fail "blocked: $2:${3:-8080} — it was REACHABLE"
  else pass "blocked: $2:${3:-8080}"; fi
}
assert_file_exists() {  # $1=cid $2=path
  if docker exec "$1" test -f "$2" 2>/dev/null; then pass "exists in container: $2"
  else fail "exists in container: $2"; fi
}
assert_file_absent() {
  if docker exec "$1" test -e "$2" 2>/dev/null; then fail "absent in container: $2 — it EXISTS"
  else pass "absent in container: $2"; fi
}
assert_log_contains() {  # $1=cid $2=ERE
  if docker logs "$1" 2>&1 | grep -qE "$2"; then pass "container log matches: $2"
  else fail "container log matches: $2"; fi
}
assert_no_capability() {  # $1=cid $2=cap name, e.g. cap_net_admin
  local caps; caps="$(pid1_caps "$1")"
  case "$caps" in
    *"$2"*) fail "agent shell dropped $2 — still present in [$caps]" ;;
    *)      pass "agent shell dropped $2" ;;
  esac
}

# ── Diagnostics, printed automatically by it_cleanup when a case failed ────────
it_diagnose() {  # $1=cid
  printf '── DIAGNOSTICS %s ──\n' "$1"
  printf '   ── docker logs (last 60) ──\n'
  docker logs "$1" 2>&1 | tail -60 | sed 's/^/     /'
  printf '   ── iptables -S OUTPUT ──\n'
  docker exec "$1" iptables -S OUTPUT 2>&1 | sed 's/^/     /'
  printf '   ── ipset ──\n'
  docker exec "$1" bash -c \
    'for s in $(ipset list -n 2>/dev/null); do printf "%s: %s entries\n" "$s" "$(ipset list "$s" 2>/dev/null | sed -n "/^Members:/,\$p" | tail -n +2 | grep -c .)"; done' \
    2>&1 | sed 's/^/     /'
  printf '   ── capture dirs ──\n'
  docker exec "$1" bash -c \
    'ls -la /workspace/.agent-blocked /workspace/.agent-discovery 2>&1;
     for f in /workspace/.agent-blocked/*; do [ -f "$f" ] && { echo "--- $f"; head -20 "$f"; }; done' \
    2>&1 | sed 's/^/     /'
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-integration-lib.sh
bash tests/run-all.sh integration
```
Expected: `0 failure(s)` from the first; both integration unit tests PASS in the suite.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test-integration-lib.sh
git add tests/integration/lib.sh tests/test-integration-lib.sh
git commit -m "test(integration): lib.sh verbs — sidecar, allowlist synthesis, reach, assertions

Container-returning verbs set a global rather than printing, so a diagnostic can
never be captured as a container name. pid1_caps reads /proc/1/status because a
fresh docker exec does not inherit the capsh drops and would report NET_ADMIN
present in a container that correctly dropped it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: First real container — harness self-test and a CI Docker host

The first task that needs a daemon. It proves the docker verbs work end to end and, in the same stroke, gives every later task a Docker host reachable from this session. Scaffolding is folded in here because this task's deliverable is the thing that needs it.

**Note on file organisation:** the spec's CI table puts `integration-fast` inside `tests.yml`. This plan gives it its own `integration.yml` instead, triggered by `workflow_dispatch` now and by `pull_request`/`push` in Task 11. One job, one file, no duplication between the dev-iteration trigger and the gating trigger — required checks are configured per job, so gating is unaffected.

**Files:**
- Create: `tests/integration/cases/000-harness-selftest.sh`
- Create: `.github/workflows/integration.yml`

**Interfaces:**
- Consumes: every verb from Task 2, and `run.sh`'s build/network/label/sweep from Task 1.
- Produces: a verified `sidecar_up` / `sandbox_up` / `reach` / `allowlist_write` path that Tasks 4–9 build on without re-proving, and a `workflow_dispatch` entry point (`gh workflow run integration.yml -f tags=…`) used to verify each of them.

- [ ] **Step 1: Write the failing case**

Create `tests/integration/cases/000-harness-selftest.sh`:

```bash
#!/usr/bin/env bash
# summary:  the harness itself works — sidecar serves, an open-mode sandbox reaches it
# tags:     harness fast
# requires: docker sidecar
#
# Proves the primitives before any case that depends on them can lie about a
# security property. If this fails, every "blocked" result below is meaningless:
# a destination nothing could ever reach looks exactly like a destination the
# firewall dropped.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
pass "sidecar started on $IT_NET as $IT_SIDECAR ($IT_SIDECAR_IP)"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""

# open mode: no firewall at all, so reachability here is a property of the
# harness (network, sidecar, curl), not of any enforcement decision.
sandbox_up open "$adir" || it_finish
pass "open-mode sandbox started ($IT_CID)"
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"

# The image must actually carry the sidecar runtime; if node ever stops being
# unconditional, every network case silently loses its destination.
if docker run --rm --entrypoint node "$IT_IMAGE" --version >/dev/null 2>&1; then
  pass "the image ships node (the sidecar runtime)"
else
  fail "the image ships node (the sidecar runtime)"
fi

it_finish
```

- [ ] **Step 2: Create the CI workflow**

Create `.github/workflows/integration.yml`:

```yaml
name: Integration

# workflow_dispatch only for now; Task 11 adds pull_request + push to main once
# the corpus is green. Keeping one file means the trigger that gates a PR and the
# trigger used while iterating can never drift apart.
on:
  workflow_dispatch:
    inputs:
      tags:
        description: 'Comma-separated tags to select (blank = all)'
        required: false
        default: 'fast'
      exclude:
        description: 'Comma-separated tags to exclude'
        required: false
        default: 'needs-external,needs-dns'
      require:
        description: 'Comma-separated tags whose skip fails the run'
        required: false
        default: 'security'
      verbose:
        description: 'Stream each case output'
        type: boolean
        required: false
        default: false

permissions:
  contents: read

jobs:
  integration:
    name: Integration cases
    runs-on: ubuntu-latest
    timeout-minutes: 45

    steps:
      - uses: actions/checkout@v5

      - name: Environment
        run: |
          uname -a
          docker --version
          df -h / | tail -1
          # The security tier rests on these two being loadable.
          sudo modprobe ip_set        && echo "ip_set OK"        || echo "ip_set UNAVAILABLE"
          sudo modprobe nfnetlink_log && echo "nfnetlink_log OK" || echo "nfnetlink_log UNAVAILABLE"

      - name: Detected capabilities
        run: ./tests/integration/run.sh --list-caps

      - name: Case corpus
        run: ./tests/integration/run.sh --list

      - name: Run
        run: |
          args=""
          [ -n "${{ inputs.tags }}" ]    && args="$args --tags ${{ inputs.tags }}"
          [ -n "${{ inputs.exclude }}" ] && args="$args --exclude ${{ inputs.exclude }}"
          [ -n "${{ inputs.require }}" ] && args="$args --require ${{ inputs.require }}"
          [ "${{ inputs.verbose }}" = "true" ] && args="$args -v"
          echo "run.sh $args"
          ./tests/integration/run.sh $args

      - name: Collect diagnostics
        if: failure()
        run: |
          mkdir -p /tmp/it-diag
          cp -r "$HOME/.cache/ai-containers-it" /tmp/it-diag/ 2>/dev/null || true
          docker ps -a --filter 'label=ai-containers.it-run' > /tmp/it-diag/containers.txt 2>&1 || true

      - name: Upload diagnostics
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: it-diagnostics-${{ github.run_id }}
          path: /tmp/it-diag
          retention-days: 7

      - name: Sweep
        if: always()
        run: |
          docker ps -aq  --filter 'label=ai-containers.it-run' | xargs -r docker rm -f
          docker network ls -q --filter 'label=ai-containers.it-run' | xargs -r docker network rm
```

Note the `--keep` interaction: `run.sh` deletes `$IT_SCRATCH` on a clean exit, so the diagnostics step only ever finds content after a failure — which is when it is wanted. The `Sweep` step is belt-and-braces for a `run.sh` killed by the job timeout.

- [ ] **Step 3: Push and run it — expect FAIL**

```bash
git checkout -b integration-suite
git add tests/integration/cases/000-harness-selftest.sh .github/workflows/integration.yml
git commit -m "test(integration): harness self-test case + workflow_dispatch runner"
git push -u origin integration-suite
gh workflow run integration.yml --ref integration-suite -f tags=harness -f exclude= -f require=
```

Watch it:
```bash
sleep 15
id="$(gh run list --workflow=integration.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$id" --exit-status; gh run view "$id" --log-failed
```

Expected on the first run: the case does whatever the primitives actually do — this is the step that finds out. Common first-run failures and their fix:
- `sidecar_up: nothing listening on 8080` → the `node -e` argument is being split by the shell; verify with `docker run --rm --entrypoint node "$IT_IMAGE" -e 'console.log(1)'`.
- `sandbox_up(open): entrypoint never handed over` → `_it_pid1_is_sandbox` never true; check `docker exec <cid> cat /proc/1/status` and `docker logs <cid>`.
- `reachable: … curl could not connect` in **open** mode → the network or the sidecar, not the firewall; there is no firewall in open mode.

- [ ] **Step 4: Fix until green, then confirm on a host too**

Iterate with `gh workflow run` until:
```
000-harness-selftest    PASS  (4 assertion(s), Ns)
selected 1 of 1   passed 1  failed 0  skipped 0
```

Then run the same thing on a real host to confirm platform-neutrality:
```bash
./tests/integration/run.sh --tags harness -v
```

- [ ] **Step 5: Record the build cost**

From the job log, note the minimal-image build time and `docker system df` size. If the build exceeds ~10 minutes, add a note to the plan — the spec deliberately starts with **no BuildKit layer caching** ("a common source of green locally, strange in CI"), and only a measured problem justifies adding it.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test(integration): harness self-test green on Linux CI and on a host

Proves sidecar_up/sandbox_up/reach/allowlist_write before any security case can
depend on them. A destination nothing could ever reach is indistinguishable from
one the firewall dropped, so the primitives are verified first.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 4: Restricted mode — the three reachability cases

**Files:**
- Create: `tests/integration/cases/010-restricted-blocks-unlisted.sh`
- Create: `tests/integration/cases/020-restricted-allows-listed-cidr.sh`
- Create: `tests/integration/cases/030-restricted-allows-listed-domain.sh`

**Interfaces:**
- Consumes: `sidecar_up`, `allowlist_write`, `sandbox_up`, `assert_blocked`, `assert_reachable`, `it_finish`, `$IT_SIDECAR_IP`, `$IT_CID`.
- Produces: nothing later tasks import; `020` and `030` establish the two admission paths (literal IP vs `getent`) that the capture and self-healing cases assume work.

- [ ] **Step 1: Write the three cases**

`010-restricted-blocks-unlisted.sh`:

```bash
#!/usr/bin/env bash
# summary:  restricted mode drops a destination absent from the allowlist
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# The most basic promise the product makes. Deliberately offline: the sidecar is
# a container on a private network, so "blocked" is a decision this firewall made
# and not a property of the internet.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""          # nothing allowed at all
sandbox_up restricted "$adir" || it_finish
assert_blocked "$IT_CID" "$IT_SIDECAR_IP"
it_finish
```

`020-restricted-allows-listed-cidr.sh`:

```bash
#!/usr/bin/env bash
# summary:  restricted mode admits a destination listed in allowlist-cidrs
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# The literal-IP branch of refresh-ipset-allowlist.sh (is_ipv4 → ipset add).
# Without this, 010 could pass because NOTHING is reachable — a firewall that
# drops everything is not the product.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""
sandbox_up restricted "$adir" || it_finish
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"
it_finish
```

`030-restricted-allows-listed-domain.sh`:

```bash
#!/usr/bin/env bash
# summary:  restricted mode admits a listed DOMAIN, exercising the getent path
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# Not a duplicate of 020: refresh-ipset-allowlist.sh has two branches, and the
# allowlist is overwhelmingly domains. --add-host puts the name in /etc/hosts,
# which `getent ahostsv4` resolves through nsswitch exactly as it would DNS, so
# this drives the resolve-then-ipset-add path with no resolver in the picture.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "it-sidecar.test" "" ""
sandbox_up restricted "$adir" --add-host "it-sidecar.test:$IT_SIDECAR_IP" || it_finish
assert_reachable "$IT_CID" "it-sidecar.test"
# The name resolved AND the resolved address reached the ipset — assert the
# second half explicitly, or a case that fails for a DNS reason reads as a
# firewall pass.
if docker exec "$IT_CID" bash -c 'ipset list allowed_ipv4 2>/dev/null' | grep -qF "$IT_SIDECAR_IP"; then
  pass "the resolved address landed in the allowed_ipv4 ipset"
else
  fail "the resolved address landed in the allowed_ipv4 ipset"
fi
it_finish
```

- [ ] **Step 2: Run them — they must PASS**

```bash
git add tests/integration/cases/0[123]0-*.sh
git commit -m "test(integration): restricted-mode reachability trio (010/020/030)"
git push
gh workflow run integration.yml --ref integration-suite \
  -f tags=restricted -f exclude= -f require=security
```

- [ ] **Step 3: Demonstrate each security case FAILING against its known-bad configuration**

This step is not optional. A security case never observed failing manufactures exactly the false confidence the suite exists to eliminate — it is the only thing that separates a real regression test from one that is green because its primitive is broken.

Temporarily mutate each case, run, confirm FAIL, revert:

| Case | Known-bad mutation | Must report |
|---|---|---|
| `010` | `allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""` (allowlist the sidecar) | `FAIL: blocked: … — it was REACHABLE` |
| `020` | `allowlist_write "$adir" "" "" ""` (allowlist nothing) | `FAIL: reachable: … curl could not connect` |
| `030` | drop the `--add-host` argument | `FAIL` on both assertions |

```bash
# for each: edit, then
gh workflow run integration.yml --ref integration-suite -f tags=restricted -f exclude= -f require=
# confirm FAIL in the log, then revert the edit
git checkout -- tests/integration/cases/
```

Record the three observed failure lines in the commit message. Without them there is no evidence the assertions can fail at all.

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "test(integration): demonstrate 010/020/030 failing against known-bad configs

010 with the sidecar allowlisted:      FAIL: blocked: <ip>:8080 — it was REACHABLE
020 with an empty allowlist:           FAIL: reachable: <ip>:8080 — curl could not connect
030 without --add-host:                FAIL: reachable: it-sidecar.test:8080 …

A security case never observed failing is green because its primitive is broken
just as easily as because the product is correct.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 5: The capture tier — 040, 050, 060

The motivating incident. `060` is the regression itself, and unlike `tests/test-blocked-capture.sh` (fake `tshark`, fake `ipset`, no root) it runs against real tshark under real `NET_ADMIN`.

**Files:**
- Create: `tests/integration/cases/040-restricted-records-blocked.sh`
- Create: `tests/integration/cases/050-restricted-capture-starts.sh`
- Create: `tests/integration/cases/060-restricted-empty-allowlist-still-captures.sh`
- Create: `tests/integration/fixtures/capture-blocked-traffic.prefix.sh` (the known-bad script, used only by step 3)

**Interfaces:**
- Consumes: `sidecar_up`, `allowlist_write`, `sandbox_up`, `reach`, `blocked_entries`, `assert_file_exists`, `it_wait`.
- Produces: nothing later tasks import.

- [ ] **Step 1: Write the three cases**

`040-restricted-records-blocked.sh`:

```bash
#!/usr/bin/env bash
# summary:  a blocked attempt is RECORDED as a real (non-comment) entry
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# Enforcement and recording are separate properties, and only enforcement kept
# working during the outage: packets were still dropped, but every record of what
# was dropped was gone. 010 proves the drop; this proves the record.
#
# The "non-comment" qualifier is the whole point. init_output_files seeds each
# output file with explanatory headers, so a plain -s (non-empty) check is true
# on a clean run — which once reported an untouched firewall as HARD-BLOCKED and
# then listed the header lines as if they were blocked destinations.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up restricted "$adir" || it_finish

# Before: the file exists and is non-empty, yet holds no real entries.
before="$(blocked_entries "$IT_CID" blocked-ips.txt)"
[[ -z "$before" ]] \
  && pass "blocked-ips.txt starts with zero real entries (headers are comments)" \
  || fail "blocked-ips.txt starts with zero real entries — got: $before"

reach "$IT_CID" "$IT_SIDECAR_IP" || true    # generate exactly one blocked flow

entry_recorded() { blocked_entries "$1" blocked-ips.txt | grep -qxF "$2"; }
if it_wait 45 entry_recorded "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
else
  fail "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
fi

# blocked.log is the authoritative record: log_blocked returns early after
# self-healing an allowlisted domain and writes the "(auto-allowed)" line to
# blocked.log ONLY. Reading just the two copy-paste files therefore reports
# "blocked nothing" for traffic that WAS dropped and then admitted.
logged() { docker exec "$1" grep -qF "$2" /workspace/.agent-blocked/blocked.log; }
if it_wait 20 logged "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked.log records the destination with a timestamp"
else
  fail "blocked.log records the destination with a timestamp"
fi
it_finish
```

`050-restricted-capture-starts.sh`:

```bash
#!/usr/bin/env bash
# summary:  the blocked-traffic capture daemon reaches init_output_files
# tags:     security network-mode restricted fast
# requires: docker netadmin
#
# The existence of the three output files is the cheapest true signal that the
# daemon survived startup. tests/test-entrypoint-wiring.sh asserts the daemon is
# WIRED IN and passed every day of the outage, because the wiring was correct and
# the process died ~150 lines later.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
# A populated, ordinary configuration — the shape a real user runs.
allowlist_write "$adir" "example.test other.test" "10.250.0.0/24" "*.proxy.test"
sandbox_up restricted "$adir" || it_finish

for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  it_wait 30 docker exec "$IT_CID" test -f "/workspace/.agent-blocked/$f" || true
  assert_file_exists "$IT_CID" "/workspace/.agent-blocked/$f"
done
assert_log_contains "$IT_CID" 'Blocked traffic capture started'
assert_log_contains "$IT_CID" 'self-healing: ON'
it_finish
```

`060-restricted-empty-allowlist-still-captures.sh`:

```bash
#!/usr/bin/env bash
# summary:  a comments-only allowlist does not kill the capture daemon
# tags:     security network-mode restricted fast
# requires: docker netadmin
#
# THE regression. capture-blocked-traffic.sh runs `set -euo pipefail`, and its
# allowlist cache was built with `grep -v '^\s*#' F | grep -v '^\s*$' | sed …`.
# When F has no non-comment, non-blank line the SECOND grep exits 1, pipefail
# propagates it, and set -e killed the daemon ~150 lines before
# init_output_files. Nothing was logged: no blocked.log, no blocked-domains.txt,
# no NFLOG watcher, and — worst — no SELF-HEALING, so dynamic CDN IPs behind an
# allowlisted wildcard silently stopped being admitted.
#
# A comments-only allowlist is a LEGAL configuration: the generated
# allowlist-proxy-domains.txt is nothing but its two header comments whenever no
# proxy-fragment component is enabled, which is why this was invisible to anyone
# running with copilot/claude-code ON.
#
# tests/test-blocked-capture.sh already pins this hermetically with a fake tshark
# and no root. This case is the same property against REAL tshark, REAL NFLOG and
# REAL NET_ADMIN, where a second failure mode could hide.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""     # all three comments-only — the degenerate legal config
sandbox_up restricted "$adir" || it_finish

for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  it_wait 30 docker exec "$IT_CID" test -f "/workspace/.agent-blocked/$f" || true
  assert_file_exists "$IT_CID" "/workspace/.agent-blocked/$f"
done
assert_log_contains "$IT_CID" 'Blocked traffic capture started'

# The daemon must still be ALIVE, not merely have created its files: the NFLOG
# watcher is what self-healing depends on.
if docker exec "$IT_CID" bash -c \
     'grep -l "capture-blocked-traffic" /proc/[0-9]*/cmdline >/dev/null 2>&1'; then
  pass "the capture daemon process is still running"
else
  fail "the capture daemon process is still running"
fi
it_finish
```

- [ ] **Step 2: Run — they must PASS**

```bash
git add tests/integration/cases/0[456]0-*.sh
git commit -m "test(integration): capture tier (040 records, 050 starts, 060 empty-allowlist)"
git push
gh workflow run integration.yml --ref integration-suite \
  -f tags=restricted -f exclude= -f require=security
```

- [ ] **Step 3: Demonstrate them failing — build the known-bad daemon**

Create `tests/integration/fixtures/capture-blocked-traffic.prefix.sh` by copying the current script and reverting `strip_allowlist` to the pre-fix pipeline:

```bash
cp capture-blocked-traffic.sh tests/integration/fixtures/capture-blocked-traffic.prefix.sh
```
then in that copy replace the whole `strip_allowlist` function with the original construct, and change its two call sites to match:

```bash
# KNOWN-BAD, kept ONLY so 060 can be demonstrated failing. Do not "fix" it.
grep -v '^[[:space:]]*#' "$domains_file" \
  | grep -v '^[[:space:]]*$' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$allowed_domains_cache"
grep -v '^[[:space:]]*#' "$proxy_domains_file" \
  | grep -v '^[[:space:]]*$' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$wildcard_patterns_cache"
```

Then temporarily add this line to `060` right before `sandbox_up`, and to `sandbox_up`'s extra arguments:

```bash
bad="$IT_REPO_DIR/tests/integration/fixtures/capture-blocked-traffic.prefix.sh"
sandbox_up restricted "$adir" -v "$bad:/usr/local/bin/capture-blocked-traffic.sh:ro" || it_finish
```

Run. Expected, and this is the exact shape of the original outage:
```
060-restricted-empty-allowlist-still-captures   FAIL
  FAIL: exists in container: /workspace/.agent-blocked/blocked.log
  FAIL: exists in container: /workspace/.agent-blocked/blocked-domains.txt
  FAIL: exists in container: /workspace/.agent-blocked/blocked-ips.txt
  FAIL: container log matches: Blocked traffic capture started
  FAIL: the capture daemon process is still running
```

Then confirm `050` still PASSES with the same known-bad script and a *populated* allowlist — that asymmetry is why the bug survived for months, and demonstrating it is worth more than either case alone.

For `040`, the known-bad mutation is `allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""`: nothing gets blocked, so no entry is ever recorded.

Revert the temporary edits to `060` (keep the fixture — it is the permanent evidence).

- [ ] **Step 4: Commit**

```bash
git add tests/integration/fixtures/capture-blocked-traffic.prefix.sh
git add tests/integration/cases/
git commit -m "test(integration): demonstrate the capture tier failing against the pre-fix daemon

With the pre-fix grep|grep strip_allowlist bind-mounted over the fixed one:
  060 (comments-only allowlist)  FAIL — no output files, daemon dead at startup
  050 (populated allowlist)      PASS — unchanged
That asymmetry is exactly why the outage survived for months: everyone running
with copilot/claude-code ON had a populated allowlist.

040 with the sidecar allowlisted: FAIL — nothing blocked, nothing recorded.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 6: Capability drops and open mode — 070, 210, 220, 230

**Files:**
- Create: `tests/integration/cases/070-restricted-drops-capabilities.sh`
- Create: `tests/integration/cases/210-open-no-firewall.sh`
- Create: `tests/integration/cases/220-open-no-capture.sh`
- Create: `tests/integration/cases/230-open-drops-capabilities.sh`

**Interfaces:**
- Consumes: `sandbox_up`, `assert_no_capability`, `assert_reachable`, `assert_file_absent`, `pid1_caps`, `$IT_SIDECAR_IP`, `$IT_CID`.

- [ ] **Step 1: Write the four cases**

`070-restricted-drops-capabilities.sh`:

```bash
#!/usr/bin/env bash
# summary:  the restricted-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode restricted fast
# requires: docker netadmin
#
# The container is STARTED with both capabilities — the firewall setup and the
# capture daemon need them — and entrypoint.sh drops them from the agent shell
# with `exec capsh --drop=cap_net_admin,cap_net_raw`. Without the drop, the agent
# can simply flush the OUTPUT chain and the entire allowlist is decorative.
#
# Read /proc/1/status, never a fresh `docker exec`: exec starts from the
# container's capability BOUNDING SET and does not inherit capsh's drops, so
# asking it directly reports NET_ADMIN present in a container that dropped it
# correctly. That mistake would make this case permanently, invisibly green.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up restricted "$adir" || it_finish

caps="$(pid1_caps "$IT_CID")"
[[ -n "$caps" ]] && pass "read the agent shell's effective capabilities [$caps]" \
                 || fail "read the agent shell's effective capabilities"
assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw

# And the effect, not only the bit: the agent cannot actually change the rules.
if docker exec -u 1000:1000 "$IT_CID" iptables -P OUTPUT ACCEPT >/dev/null 2>&1; then
  fail "the sandbox user cannot flush the firewall — it SUCCEEDED"
else
  pass "the sandbox user cannot flush the firewall"
fi
it_finish
```

`210-open-no-firewall.sh`:

```bash
#!/usr/bin/env bash
# summary:  open mode applies no firewall — the allowlist that blocks under
#           restricted does not block here
# tags:     network-mode open fast
# requires: docker sidecar
#
# Asserted as an EFFECT, deliberately. The obvious version — "iptables -S shows
# policy ACCEPT" — cannot run: open mode gets no NET_ADMIN (sandbox.sh passes an
# empty capabilities array), so iptables inside the container fails for reasons
# unrelated to what is being tested. The differential against 010, which blocks
# with this exact allowlist, is the honest assertion.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""          # identical to 010's
sandbox_up open "$adir" || it_finish
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"
it_finish
```

`220-open-no-capture.sh`:

```bash
#!/usr/bin/env bash
# summary:  open mode starts no capture daemon and creates no output dirs
# tags:     network-mode open fast
# requires: docker
#
# Open mode's documented promise is "unrestricted egress, NO capture, no
# logging". A capture daemon quietly running in open mode would write the user's
# traffic to disk in the one mode that promises it does not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up open "$adir" || it_finish

assert_file_absent "$IT_CID" /workspace/.agent-blocked/blocked.log
assert_file_absent "$IT_CID" /workspace/.agent-discovery/agent-traffic.pcap
if docker exec "$IT_CID" bash -c \
     'grep -l "capture-" /proc/[0-9]*/cmdline >/dev/null 2>&1'; then
  fail "no capture process is running in open mode"
else
  pass "no capture process is running in open mode"
fi
assert_log_contains "$IT_CID" 'OPEN MODE: outbound network is UNRESTRICTED'
it_finish
```

`230-open-drops-capabilities.sh`:

```bash
#!/usr/bin/env bash
# summary:  the open-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode open fast
# requires: docker
#
# Open mode is "no firewall", not "no isolation". It gets the same capability
# drop as restricted mode, and sandbox.sh additionally passes no --cap-add at
# all, so this asserts both belts.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up open "$adir" || it_finish
assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw
it_finish
```

- [ ] **Step 2: Run — they must PASS**

```bash
git add tests/integration/cases/070-*.sh tests/integration/cases/2[123]0-*.sh
git commit -m "test(integration): capability drops (070/230) and open-mode promises (210/220)"
git push
gh workflow run integration.yml --ref integration-suite \
  -f tags=fast -f exclude=needs-dns,needs-external -f require=security
```

- [ ] **Step 3: Demonstrate the security cases failing**

| Case | Known-bad mutation | Must report |
|---|---|---|
| `070` | in `lib.sh`, temporarily change `pid1_caps` to read a fresh exec (`docker exec "$1" capsh --print \| sed -n 's/^Current: //p'`) | `FAIL: agent shell dropped cap_net_admin — still present` — this is the mistake the comment warns about, and seeing it fail is the proof the `/proc/1/status` version is load-bearing |
| `070` | start the container with `--cap-add=ALL` and no drop: `sandbox_up restricted "$adir" --privileged` | both `assert_no_capability` FAIL |
| `230` | `sandbox_up discovery "$adir"` (discovery keeps NET_RAW on purpose) | `FAIL: agent shell dropped cap_net_raw` |
| `220` | `sandbox_up restricted "$adir"` | `FAIL: absent in container: …/blocked.log — it EXISTS` |

Revert each after observing the failure.

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "test(integration): demonstrate 070/220/230 failing against known-bad configs

The most valuable demonstration is 070 against a pid1_caps that reads a fresh
docker exec instead of /proc/1/status: it reports NET_ADMIN present in a
container that dropped it correctly, which would have made the case permanently
and invisibly green.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 7: Discovery mode — 110 and 120

**Files:**
- Create: `tests/integration/cases/110-discovery-does-not-block.sh`
- Create: `tests/integration/cases/120-discovery-collects.sh`

**Interfaces:**
- Consumes: `sidecar_up`, `allowlist_write`, `sandbox_up`, `assert_reachable`, `it_wait`, `$IT_SIDECAR_IP`, `$IT_CID`.

- [ ] **Step 1: Write both cases**

`110-discovery-does-not-block.sh`:

```bash
#!/usr/bin/env bash
# summary:  discovery mode applies no drop policy — the allowlist that blocks
#           under restricted does not block here
# tags:     network-mode discovery fast
# requires: docker netadmin sidecar
#
# The differential against 010, which uses this exact allowlist and blocks.
# Capture is disabled here so the case measures egress policy and nothing else;
# 120 owns the capture behaviour.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up discovery "$adir" -e DISCOVERY_CAPTURE_ENABLED=0 || it_finish
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"
it_finish
```

`120-discovery-collects.sh`:

```bash
#!/usr/bin/env bash
# summary:  discovery mode captures traffic to a pcap and extraction lists the
#           destination
# tags:     network-mode discovery slow
# requires: docker netadmin
#
# The probe is a DNS QUERY, not an HTTP request, and that is deliberate:
# capture-agent-destinations.sh starts tcpdump with the filter
# 'port 53 or port 443', and extract_capture reads the pcap for dns.qry.name and
# tls.handshake.extensions_server_name. An HTTP request to a sidecar on 8080
# produces a pcap the filter never records, and plain HTTP on 443 produces no SNI
# — either way the case would assert an empty file and pass or fail for reasons
# unrelated to capture. A DNS query to a dead address still LEAVES the container,
# so the packet is captured and the name is extractable, entirely offline.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

probe_name="it-probe-120.test"
dead_resolver="10.253.0.53"       # nothing listens; only the outbound query matters

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up discovery "$adir" || it_finish     # capture ENABLED (the default)
assert_log_contains "$IT_CID" 'Discovery capture started'

it_wait 30 docker exec "$IT_CID" test -f /workspace/.agent-discovery/agent-traffic.pcap || true
assert_file_exists "$IT_CID" /workspace/.agent-discovery/agent-traffic.pcap

docker exec "$IT_CID" nslookup -timeout=1 -retries=1 "$probe_name" "$dead_resolver" \
  >/dev/null 2>&1 || true

pcap_nonempty() { docker exec "$1" test -s /workspace/.agent-discovery/agent-traffic.pcap; }
if it_wait 30 pcap_nonempty "$IT_CID"; then
  pass "the pcap is non-empty after outbound traffic"
else
  fail "the pcap is non-empty after outbound traffic"
fi

# Drive the real extraction path, the one the README tells users to run.
docker exec "$IT_CID" /usr/local/bin/capture-agent-destinations.sh \
  stop /workspace/.agent-discovery >/dev/null 2>&1 || true

if docker exec "$IT_CID" grep -qxF "$probe_name" /workspace/.agent-discovery/agent-dns.txt 2>/dev/null; then
  pass "extraction lists the queried destination in agent-dns.txt"
else
  fail "extraction lists the queried destination in agent-dns.txt"
  docker exec "$IT_CID" bash -c \
    'ls -la /workspace/.agent-discovery; echo "--- dns ---"; cat /workspace/.agent-discovery/agent-dns.txt 2>&1;
     echo "--- tcpdump.log ---"; cat /workspace/.agent-discovery/tcpdump.log 2>&1' | sed 's/^/     /'
fi
it_finish
```

- [ ] **Step 2: Run — they must PASS**

```bash
git add tests/integration/cases/1[12]0-*.sh
git commit -m "test(integration): discovery mode does not block (110) and collects (120)"
git push
gh workflow run integration.yml --ref integration-suite \
  -f tags=discovery -f exclude= -f require=
```

`120` is tagged `slow` deliberately — it waits on tcpdump flushing and on nslookup's retry. If it exceeds 300s, raise only its own budget via `--timeout`, never the default.

- [ ] **Step 3: Demonstrate failure**

| Case | Known-bad mutation | Must report |
|---|---|---|
| `110` | `sandbox_up restricted "$adir"` | `FAIL: reachable: …` — proves the case measures the mode and not the network |
| `120` | `-e DISCOVERY_CAPTURE_ENABLED=0` | `FAIL: exists in container: …/agent-traffic.pcap` |

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "test(integration): demonstrate 110/120 failing against known-bad configs

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 8: Allowlist delivery — 300

Assembly is already covered by 44 hermetic assertions in `tests/test-allowlists.sh`. **Delivery is covered by nothing, anywhere.** `Dockerfile:467-469` does three bare `COPY allowlist-*.txt /tmp/` and no test checks the files landed or that they match what `build.sh` generated. A Dockerfile edit could ship a stale or absent allowlist with every existing test green.

**Files:**
- Create: `tests/integration/cases/300-allowlist-delivered.sh`

**Interfaces:**
- Consumes: `$IT_GENERATED_ALLOWLIST_DIR` (Task 1 — the snapshot `run.sh` takes right after `build.sh` runs), `$IT_IMAGE`.

- [ ] **Step 1: Write the case**

```bash
#!/usr/bin/env bash
# summary:  the allowlists build.sh generated are the ones inside the image
# tags:     delivery fast
# requires: docker
#
# Assembly (component ON -> fragment included) is covered hermetically by
# tests/test-allowlists.sh. DELIVERY — that the generated file actually reaches
# /tmp/ in the image — is covered by nothing: Dockerfile:467-469 are three bare
# COPY lines, and a stale or absent allowlist would ship with every test green.
#
# The refresh script reads these exact paths (refresh-ipset-allowlist.sh:4-6), so
# a mismatch here is a silently wrong firewall, not a cosmetic drift.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[[ -d "$IT_GENERATED_ALLOWLIST_DIR" ]] \
  || skip "no generated-allowlist snapshot (run.sh was invoked with --reuse-image)"

for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
  want="$(cat "$IT_GENERATED_ALLOWLIST_DIR/$f" 2>/dev/null)"
  got="$(docker run --rm --label "$IT_LABEL" --entrypoint cat "$IT_IMAGE" "/tmp/$f" 2>/dev/null)"
  if [[ -z "$got" ]]; then
    fail "/tmp/$f exists in the image (it is empty or absent)"
  elif [[ "$want" == "$got" ]]; then
    pass "/tmp/$f matches what build.sh generated"
  else
    fail "/tmp/$f differs from what build.sh generated"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -20 | sed 's/^/     /'
  fi
done
it_finish
```

- [ ] **Step 2: Run — it must PASS**

```bash
git add tests/integration/cases/300-allowlist-delivered.sh
git commit -m "test(integration): the allowlists in the image match what build.sh generated"
git push
gh workflow run integration.yml --ref integration-suite -f tags=delivery -f exclude= -f require=
```

- [ ] **Step 3: Demonstrate failure**

Temporarily change `Dockerfile:468` to `COPY allowlist-cidrs.txt /tmp/allowlist-cidrs.txt.bak`, run, expect:
```
FAIL: /tmp/allowlist-cidrs.txt exists in the image (it is empty or absent)
```
Revert.

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "test(integration): demonstrate 300 failing when a COPY drops an allowlist

With Dockerfile's COPY of allowlist-cidrs.txt renamed:
  FAIL: /tmp/allowlist-cidrs.txt exists in the image (it is empty or absent)
Every other test in both suites stayed green — which is the gap this case closes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 9: Self-healing, behind a real resolver — 080 and 085

The design's named hard part. Self-healing correlates a blocked IP to a domain through a DNS map that `capture-blocked-traffic.sh` builds by sniffing real port-53 **responses**. `--add-host` produces no DNS traffic, so the map stays empty and self-healing cannot fire. Both cases therefore need a resolver in the test network, and both are `needs-dns` (see spec correction 3).

**Files:**
- Create: `tests/integration/cases/080-selfheal-admits-wildcard.sh`
- Create: `tests/integration/cases/085-selfheal-disabled-stays-blocked.sh`

**Interfaces:**
- Consumes: `dns_up` (Task 2), `sidecar_up`, `allowlist_write`, `sandbox_up`, `reach`, `blocked_entries`, `it_wait`, `$IT_DNS_IP`, `$IT_SIDECAR_IP`.

- [ ] **Step 1: Write both cases**

`080-selfheal-admits-wildcard.sh`:

```bash
#!/usr/bin/env bash
# summary:  a blocked IP whose domain matches an allowlisted wildcard is
#           auto-allowed on the spot, without waiting for the 60s refresh
# tags:     security network-mode restricted needs-dns
# requires: docker netadmin sidecar dns
#
# This is the property that silently died with the capture daemon. Enforcement
# kept working, so nothing looked wrong — but dynamic CDN IPs behind an
# allowlisted wildcard (*.githubcopilot.com is the real-world case) stopped being
# admitted, because the code path that admits them lives inside the dead daemon.
#
# The chain being exercised, end to end:
#   curl -> DNS query (port 53 is unconditionally ACCEPTed) -> CoreDNS answers
#        -> the daemon's DNS-map builder sniffs the RESPONSE and records ip->name
#        -> the connection to that ip is DROPPED and NFLOGged
#        -> log_blocked looks the ip up, matches *.wild.test in the proxy file
#        -> ipset add, immediately -> the retry succeeds
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fqdn="probe.wild.test"
sidecar_up || it_finish
dns_up "$fqdn" "$IT_SIDECAR_IP" || it_finish
pass "resolver up at $IT_DNS_IP answering $fqdn -> $IT_SIDECAR_IP"

adir="$(it_scratch)"
# Nothing in domains or cidrs. The ONLY thing that can admit the sidecar is the
# wildcard in the proxy-domains file, matched by the self-healing path.
allowlist_write "$adir" "" "" "*.wild.test"
sandbox_up restricted "$adir" --dns "$IT_DNS_IP" || it_finish

# First attempt: must be dropped (the ipset cannot contain an address nobody has
# resolved yet), and the drop must produce the auto-allow.
reach "$IT_CID" "$fqdn" || true

healed() {
  docker exec "$1" grep -qE "$2.*\(auto-allowed\)" /workspace/.agent-blocked/blocked.log
}
if it_wait 60 healed "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked.log records $IT_SIDECAR_IP as (auto-allowed)"
else
  fail "blocked.log records $IT_SIDECAR_IP as (auto-allowed)"
fi

in_ipset() { docker exec "$1" bash -c 'ipset list allowed_ipv4 2>/dev/null' | grep -qF "$2"; }
if it_wait 30 in_ipset "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "the address was added to allowed_ipv4 without waiting for the 60s refresh"
else
  fail "the address was added to allowed_ipv4 without waiting for the 60s refresh"
fi

retry_ok() { reach "$1" "$2"; }
if it_wait 30 retry_ok "$IT_CID" "$fqdn"; then
  pass "the retry succeeds — the destination is now reachable"
else
  fail "the retry succeeds — the destination is now reachable"
fi

# A self-healed destination is NOT a hard block: log_blocked returns early and
# never writes to blocked-ips.txt/blocked-domains.txt. Conflating the two is the
# difference between "the firewall is innocent" and "the firewall is involved but
# recovered", and it misread a real host run once.
hard="$(blocked_entries "$IT_CID" blocked-ips.txt)"
case "$hard" in
  *"$IT_SIDECAR_IP"*) fail "a self-healed address must NOT appear in blocked-ips.txt" ;;
  *)                  pass "a self-healed address does not appear in blocked-ips.txt" ;;
esac
it_finish
```

`085-selfheal-disabled-stays-blocked.sh`:

```bash
#!/usr/bin/env bash
# summary:  SELF_HEALING_ENABLED=0 logs the drop and leaves it blocked
# tags:     security network-mode restricted needs-dns
# requires: docker netadmin sidecar dns
#
# The exact fixture as 080 with one env var flipped, because that is the only way
# the assertion means anything. Without a resolver the DNS map is empty, no
# domain is ever found, and SELF_HEALING_ENABLED=0 and =1 produce byte-identical
# output — the case would pass for a reason unrelated to what it claims to test.
# (This is why it is needs-dns rather than fast; see the spec corrections.)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fqdn="probe.wild.test"
sidecar_up || it_finish
dns_up "$fqdn" "$IT_SIDECAR_IP" || it_finish

adir="$(it_scratch)"
allowlist_write "$adir" "" "" "*.wild.test"
sandbox_up restricted "$adir" --dns "$IT_DNS_IP" -e SELF_HEALING_ENABLED=0 || it_finish
assert_log_contains "$IT_CID" 'self-healing: OFF'

reach "$IT_CID" "$fqdn" || true

recorded() { blocked_entries "$1" blocked-domains.txt | grep -qxF "$2"; }
if it_wait 45 recorded "$IT_CID" "$fqdn"; then
  pass "the drop is recorded in blocked-domains.txt as a HARD block"
else
  fail "the drop is recorded in blocked-domains.txt as a HARD block"
fi

if docker exec "$IT_CID" grep -q '(auto-allowed)' /workspace/.agent-blocked/blocked.log 2>/dev/null; then
  fail "no (auto-allowed) line is written when self-healing is off"
else
  pass "no (auto-allowed) line is written when self-healing is off"
fi

if reach "$IT_CID" "$fqdn"; then
  fail "the destination stays blocked on retry — it was REACHABLE"
else
  pass "the destination stays blocked on retry"
fi
it_finish
```

- [ ] **Step 2: Run — they must PASS**

```bash
git add tests/integration/cases/08[05]-*.sh
git commit -m "test(integration): self-healing admits a wildcard match (080) and honours the off switch (085)"
git push
gh workflow run integration.yml --ref integration-suite \
  -f tags=needs-dns -f exclude= -f require=
```

If `dns_up` cannot pull `coredns/coredns:1.11.3`, the runner's `dns` capability is unmet and both cases SKIP with `requires: dns`. That is the correct outcome on a machine without registry access — and because they are excluded from the PR gate by tag, not skipped inside it, the gate stays honest.

- [ ] **Step 3: Demonstrate failure**

| Case | Known-bad mutation | Must report |
|---|---|---|
| `080` | `-e SELF_HEALING_ENABLED=0` | all three of `(auto-allowed)`, ipset membership and the retry FAIL — and this is precisely the outage's observable signature |
| `080` | bind-mount the Task 5 known-bad daemon | same three FAIL, because self-healing lives inside the dead daemon |
| `085` | remove `-e SELF_HEALING_ENABLED=0` | `FAIL: the destination stays blocked on retry — it was REACHABLE` |

The second `080` mutation is the single most valuable demonstration in the suite: it reproduces the original incident end to end and shows this case would have caught it.

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "test(integration): demonstrate 080/085 failing, including against the pre-fix daemon

080 with the pre-fix capture-blocked-traffic.sh bind-mounted: no (auto-allowed)
line, no ipset addition, retry still blocked — the original incident reproduced
end to end, and the proof this case would have caught it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 10: `verify-on-host.sh` delegates instead of duplicating

**Spec correction 4, discovered here.** Success criterion 6 says `verify-on-host.sh` must contain "no test logic of its own". That cannot be met in increment 1 without deleting real coverage: Phases 1–3 are the *only* thing that tests agent-tier tool installs, native-package builds, and the Ruby/rvm bootstrap, and the packages tier that would absorb them is **explicitly out of scope for increment 1**. Deleting them to satisfy a criterion would be exactly the "green because we did not look" failure the suite exists to prevent.

Resolution: Phases 1–3 stay as they are. `verify-on-host.sh` gains **Phase 4**, which owns no test logic and delegates the whole network-mode corpus to `run.sh`. Criterion 6 is rescoped to "no *network-mode* test logic of its own" for increment 1 and restored in full when the packages tier lands.

**Files:**
- Modify: `verify-on-host.sh` (header, `PHASES` default, new Phase 4)

**Interfaces:**
- Consumes: `tests/integration/run.sh` and its `--tags`/`--exclude`/`--require`/`-v` flags.
- Produces: `PHASES=4 bash ./verify-on-host.sh` as the local equivalent of the CI job, on macOS and Linux alike.

- [ ] **Step 1: Update the header and the phase default**

Replace lines 2–3:

```bash
# verify-on-host.sh — run the checks that CANNOT run inside a sandbox container
# (they need a real Docker daemon).
#
# PLATFORM-ADAPTIVE HOST ENTRY POINT, not a macOS one. "Host" means "a machine
# with a real Docker daemon", as opposed to inside the dev container. The same
# command runs on macOS + Colima and on a Linux workstation with native Docker;
# the only platform-specific part is the preflight hints below. There is
# deliberately no verify-on-linux-host.sh — a second entry point would
# reintroduce, at the wrapper level, the duplication this delegation removes.
```

Replace the phase list (lines 13–19) with:

```bash
# Phases (each independent; a later phase still runs if an earlier one fails):
#   0  environment sanity (daemon reachable, buildx, disk; Colima status on macOS)
#   1  BLOCKING GATE: all six agent-tier tools install BEHIND the restricted firewall
#   2  db-clients (pg+mysql+mongo) + imagemagick + wkhtmltopdf actually BUILD on noble
#   3  Ruby runtime reconcile: rvm bootstraps, compiles, persists, and resolves
#      in a NON-login shell
#   4  the runtime integration corpus — delegated in full to
#      tests/integration/run.sh. No test logic lives here.
```

And the default:
```bash
PHASES="${PHASES:-1 2 3 4}"
```

- [ ] **Step 2: Add Phase 4, immediately before the cleanup block at the end**

```bash
# ── Phase 4: the runtime integration corpus ─────────────────────────────────────
# Delegation, not duplication. This script owns three jobs and no test logic: the
# environment banner (Phase 0), a sensible default selection (everything — a
# human running locally wants full coverage), and platform-specific remediation
# hints on failure. The cases themselves live in tests/integration/cases/ and are
# the SAME ones CI runs; CI simply selects a cheaper subset by tag.
#
# The old Phase 3 is why this matters: it kept bind-mounting ~/.rvm for two full
# rounds after the volume fix landed, because it re-implemented what sandbox.sh
# does instead of calling it. A verifier that drifts from what it verifies is
# worse than no verifier.
if want_phase 4; then
say "PHASE 4 — runtime integration corpus (tests/integration/run.sh)"
IT_RUNNER="$TESTS_DIR/integration/run.sh"
if [[ ! -x "$IT_RUNNER" && ! -f "$IT_RUNNER" ]]; then
  sub "SKIP: $IT_RUNNER not found — nothing to delegate to."
else
  sub "capabilities detected on this host:"
  bash "$IT_RUNNER" --list-caps 2>&1 | sed "s/^/$LOG_PREFIX     /"
  # No --tags: a human running this locally wants the whole corpus, including
  # the slow and needs-dns cases CI excludes on cost.
  bash "$IT_RUNNER" --require security ${IT_EXTRA_ARGS:-} 2>&1 | sed "s/^/$LOG_PREFIX   /"
  it_rc="${PIPESTATUS[0]:-1}"
  sub "PHASE 4 exit: $it_rc"
  if [[ "$it_rc" -ne 0 ]]; then
    sub "remediation hints for this platform:"
    if command -v colima >/dev/null 2>&1; then
      sub "  * ipset/NFLOG need the Colima VM's kernel modules. If the security"
      sub "    cases report 'requires: netadmin', restart with more headroom:"
      sub "      colima stop && colima start --cpu 6 --memory 12 --disk 120"
      sub "  * a bind-mount source outside \$HOME is NOT shared with the VM."
    else
      sub "  * ipset/NFLOG need ip_set and nfnetlink_log on this kernel:"
      sub "      sudo modprobe ip_set nfnetlink_log"
      sub "  * a rootless daemon cannot grant NET_ADMIN; the security cases will"
      sub "    report 'requires: netadmin' rather than silently passing."
    fi
  fi
fi
fi
```

- [ ] **Step 3: Verify the script still parses and the phase selector works**

```bash
bash -n verify-on-host.sh && echo "parse OK"
PHASES=4 bash -c 'grep -n "want_phase 4" verify-on-host.sh'
```
Expected: `parse OK` and one match. (Running it needs a Docker host — do that in Task 11's final verification.)

- [ ] **Step 4: Commit**

```bash
git add verify-on-host.sh
git commit -m "refactor(verify): Phase 4 delegates the integration corpus to the shared runner

verify-on-host.sh keeps three jobs and no network-mode test logic: environment
banner, default selection, platform-specific remediation hints. Phases 1-3 stay
until the packages tier absorbs them — deleting them to satisfy a criterion
would delete the only coverage those things have.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 11: Make it a gate — CI, docs, and the spec corrections

**Files:**
- Modify: `.github/workflows/tests.yml` (add the `lint` job)
- Modify: `.github/workflows/integration.yml` (add `pull_request` + `push: main` triggers)
- Create: `.github/workflows/nightly.yml`
- Modify: `AGENTS.md` (Commands section)
- Modify: `docs/superpowers/specs/2026-08-06-integration-test-suite-design.md` (corrections 1–4)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `integration` as a required check on both repos.

- [ ] **Step 1: Add the `lint` job to `tests.yml`**

Append to the `jobs:` map in `.github/workflows/tests.yml`:

```yaml
  lint:
    name: Shell lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      # Parse every script, including the new harness. A syntax error in a case
      # would otherwise surface as a mysterious runtime failure minutes into a
      # container run.
      - name: bash -n over every script
        run: |
          rc=0
          while IFS= read -r f; do
            bash -n "$f" || { echo "PARSE ERROR: $f"; rc=1; }
          done < <(git ls-files '*.sh')
          exit $rc

      - name: shellcheck
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck
          # -e SC1091: sourced files are resolved at runtime, not by the linter.
          # Advisory for now: the existing corpus predates the linter, so failures
          # are surfaced without blocking. Tighten to a gate in a follow-up.
          git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091 || true
```

- [ ] **Step 2: Make `integration.yml` gate PRs**

Replace its `on:` block with:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
    inputs:
      tags:
        description: 'Comma-separated tags to select (blank = all)'
        required: false
        default: ''
      exclude:
        description: 'Comma-separated tags to exclude'
        required: false
        default: ''
      require:
        description: 'Comma-separated tags whose skip fails the run'
        required: false
        default: 'security'
      verbose:
        description: 'Stream each case output'
        type: boolean
        required: false
        default: false
```

and replace the `Run` step so the gating triggers use fixed arguments while a manual dispatch keeps its inputs:

```yaml
      - name: Run
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            args=""
            [ -n "${{ inputs.tags }}" ]    && args="$args --tags ${{ inputs.tags }}"
            [ -n "${{ inputs.exclude }}" ] && args="$args --exclude ${{ inputs.exclude }}"
            [ -n "${{ inputs.require }}" ] && args="$args --require ${{ inputs.require }}"
            [ "${{ inputs.verbose }}" = "true" ] && args="$args -v"
          else
            # The PR gate: the 12 fast cases. needs-dns and slow are excluded by
            # DELIBERATE SELECTION, which the report prints separately from skips
            # — "we chose not to check this" must never read as "this passed".
            # --require security makes any skip INSIDE this selection fatal.
            args="--tags fast --exclude needs-external,needs-dns --require security"
          fi
          echo "run.sh $args"
          ./tests/integration/run.sh $args
```

- [ ] **Step 3: Create `.github/workflows/nightly.yml`**

```yaml
name: Nightly

# Non-blocking but loud. Everything too slow, too external, or too expensive for
# the PR gate runs here, so a case excluded on cost is still a case that RUNS.
on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  integration-full:
    name: Integration — everything
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v5
      - name: Capabilities
        run: ./tests/integration/run.sh --list-caps
      - name: Run the whole corpus
        run: ./tests/integration/run.sh --require security
      - name: Sweep
        if: always()
        run: |
          docker ps -aq  --filter 'label=ai-containers.it-run' | xargs -r docker rm -f
          docker network ls -q --filter 'label=ai-containers.it-run' | xargs -r docker network rm

  allowlist-health:
    name: Allowlist fragment health
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v5
      # Fragments rot silently: a domain that stops resolving stays in the file
      # forever and the only symptom is a tool that mysteriously cannot install.
      - name: Every domain in every fragment still resolves
        run: |
          rc=0
          for f in allowlist-domains.d/*.txt allowlist-proxy-domains.d/*.txt; do
            [ -f "$f" ] || continue
            while IFS= read -r line; do
              case "$line" in ''|'#'*) continue ;; esac
              host="${line#\*.}"
              if ! getent ahosts "$host" >/dev/null 2>&1; then
                echo "UNRESOLVABLE: $host  ($f)"; rc=1
              fi
            done < "$f"
          done
          exit $rc

  packages:
    name: Package installs (real allowlist, per-component images)
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v5
      # Today's verify-on-host.sh Phases 1-3: real installs through the real
      # allowlist. Ported into the case corpus when the packages tier lands.
      - name: Phases 1-3
        run: PHASES="1 2 3" bash ./verify-on-host.sh
```

- [ ] **Step 4: Document it in `AGENTS.md`**

Add to the Commands section, after the "Run the container" block:

```markdown
**Run the runtime integration tests** (needs a real Docker daemon — a host, not a sandbox container):
```bash
./tests/integration/run.sh                       # the whole corpus
./tests/integration/run.sh --list                # cases with their tags/requires
./tests/integration/run.sh --list-caps           # what this machine can actually do
./tests/integration/run.sh --tags fast --exclude needs-dns --require security
```
Cases live in `tests/integration/cases/` and declare `tags:` and `requires:` in
header comments; the runner detects capabilities and selects. **Selection and
skipping are different outcomes and are reported separately** — `--tags`/`--exclude`
choose what runs, a SKIP is a selected case whose requirement was unmet, and
`--require <tag>` makes any such skip fail the run. A case that cannot run is
never counted as a pass.

`bash ./verify-on-host.sh` runs the same corpus (Phase 4) plus the
package/Ruby phases that have no case coverage yet. It is a platform-adaptive
**host** entry point: the identical command on macOS + Colima and on Linux.
```

- [ ] **Step 5: Apply the four spec corrections**

In `docs/superpowers/specs/2026-08-06-integration-test-suite-design.md`:

1. Architecture → "Sidecar destinations": replace `--entrypoint python3 … -m http.server` with `--entrypoint node … -e '<http server>'`, and add: *"`node`, not `python3`: `python3` exists only when `python=` is set in `sandbox.conf`, and the harness image is built from a minimal config."*
2. Architecture → "One image per run": remove `NFLOG_GROUP` from the list of runtime-overridable knobs and add: *"`NFLOG_GROUP` is read by `capture-blocked-traffic.sh` but the matching iptables rule hardcodes group 100 (`entrypoint.sh:159`), so it is not a usable knob."*
3. Self-healing case table: retag `085-disabled-stays-blocked` from `security, fast` to `security, needs-dns`, with the reason. Success criterion 3: "the 13 `fast` cases" → "the 12 `fast` cases".
4. Success criterion 6: → *"`verify-on-host.sh` contains no **network-mode** test logic of its own — only a platform-adaptive host preflight and a call into the shared runner. Phases 1–3 remain until the packages tier absorbs them; full criterion 6 lands with that increment."*

Also add the delivery case count note: the corpus is **16** cases (15 from the spec plus `000-harness-selftest`).

- [ ] **Step 6: Full verification, both platforms**

On Linux CI:
```bash
gh workflow run integration.yml --ref integration-suite -f tags= -f exclude= -f require=security
```
Expected: `selected 16 of 16   passed 16  failed 0  skipped 0` (or `skipped 2` with `requires: dns` if the registry is unreachable — which is a legitimate SKIP, and the reason `--require security` must be reported and understood, not ignored).

On a host (success criterion 2), macOS and Linux both:
```bash
bash ./verify-on-host.sh 2>&1 | tee ./ai-containers-host-verify.log
```

And the unit suite is unaffected:
```bash
bash tests/run-all.sh
```
Expected: 31/31 (29 existing + the two new hermetic tests).

- [ ] **Step 7: Open the PR and make it a required check**

```bash
gh pr create --title "test: runtime integration suite (increment 1)" --body "$(cat <<'EOF'
Adds a tagged, three-state integration harness and 16 cases covering all three
network modes, the blocked-traffic capture tier, self-healing, capability drops,
and allowlist delivery.

The suite exists to make silent security regressions impossible. Every security
case has been demonstrated FAILING against its known-bad configuration — the
commit log records the observed failure lines — including 060 and 080 against
the pre-fix `capture-blocked-traffic.sh`, which reproduces the original outage
end to end.

Selection and skipping are reported as separate counts and `--require security`
makes a skip inside the selected set fatal, so "we chose not to check this" can
never read as "this passed".

Spec: `docs/superpowers/specs/2026-08-06-integration-test-suite-design.md`
Plan: `docs/superpowers/plans/2026-08-06-integration-test-suite-increment-1.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then, in repository settings → Branches → `main`, add **`Integration cases`** and **`Shell test suite`** to the required status checks.

- [ ] **Step 8: Commit and update the changelog**

```bash
git add .github/workflows/ AGENTS.md CHANGELOG.md docs/superpowers/specs/
git commit -m "ci: gate PRs on the integration corpus; nightly runs everything

tests.yml gains a lint job; integration.yml gates on the 12 fast cases with
--require security; nightly.yml runs the full corpus, allowlist fragment health,
and the package phases. Spec corrected on four points found during planning.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push
```

---

## Task 12: Port to `mgd-ai-containers`

The layout differs (engine in `base/`, `tests/` one level up) and the harness is already layout-tolerant — `run.sh` and `lib.sh` both resolve `REPO_DIR` as `../..` falling back to `../../base`. The files should copy verbatim.

**Files:**
- Create in `../../dt-utils/mgd-ai-containers`: `tests/integration/**`, `tests/test-integration-runner.sh`, `tests/test-integration-lib.sh`, `.github/workflows/integration.yml`, `.github/workflows/nightly.yml`
- Modify there: `base/verify-on-host.sh`, `.github/workflows/tests.yml`, `AGENTS.md`

**Interfaces:**
- Consumes: the finished, green corpus from Tasks 1–11.

- [ ] **Step 1: Copy the harness verbatim**

```bash
MGD=../../dt-utils/mgd-ai-containers
cd "$MGD" && git checkout main && git pull && git checkout -b integration-suite
cd - >/dev/null
mkdir -p "$MGD/tests/integration"
cp -a tests/integration/. "$MGD/tests/integration/"
cp tests/test-integration-runner.sh tests/test-integration-lib.sh "$MGD/tests/"
cp .github/workflows/integration.yml .github/workflows/nightly.yml "$MGD/.github/workflows/"
cp verify-on-host.sh "$MGD/base/verify-on-host.sh"
```

**Restore the executable bits after every copy.** `cp` preserves them but `sed -i` does not, and that exact slip has cost two commits in this repo already (`tests/test-sync-project.sh`, `base/sync-to-projects.sh` at exit 126):

```bash
chmod 755 "$MGD"/tests/integration/run.sh "$MGD"/tests/test-integration-*.sh \
          "$MGD"/base/verify-on-host.sh
git -C "$MGD" ls-files -s tests/integration/run.sh tests/test-integration-*.sh | grep 100755
```

- [ ] **Step 2: Confirm the layout resolver actually resolved**

```bash
cd "$MGD"
bash -c 'IT_RUN_ID=x IT_IMAGE=x IT_NET=x IT_SCRATCH=/tmp/x . tests/integration/lib.sh; echo "IT_REPO_DIR=$IT_REPO_DIR"'
```
Expected: a path ending in `/base` — the engine directory, where `build.sh` lives. Anything else means the fallback did not fire and every case would build the wrong thing.

- [ ] **Step 3: Run both hermetic tests, then the corpus**

```bash
bash tests/run-all.sh
gh workflow run integration.yml --ref integration-suite -f tags= -f exclude= -f require=security
```
Expected: the existing 30 tests plus 2 new ones all pass; the corpus result matches upstream.

- [ ] **Step 4: Open a PR**

That repo requires PRs on `main`. Do **not** push to `main` directly — a previous push in this project bypassed that rule and had to be flagged afterwards.

```bash
gh pr create --repo <mgd remote> --title "test: runtime integration suite (increment 1)" \
  --body "Ports the integration harness and all 16 cases from ai-containers. Layout-tolerant: run.sh/lib.sh resolve the engine directory as ../.. falling back to ../../base."
```

- [ ] **Step 5: Add the required checks there too**

Same two checks: `Integration cases`, `Shell test suite`.

---

## Self-review

**Spec coverage.** Every section maps to a task:

| Spec section | Task |
|---|---|
| Principles 1–3 (effect not config; skip ≠ pass; one corpus) | 1 (runner), 2 (lib), enforced per case |
| One image per run | 1 (`build_image`) |
| Sidecar destinations | 2 (`sidecar_up`), 3 (proven) |
| `verify-on-host.sh` platform-adaptive delegation | 10 |
| Layout / case contract / `lib.sh` verbs / tag vocabulary | 1, 2 |
| Restricted 010–070 | 4, 5, 6 |
| Self-healing 080, 085 | 9 |
| Discovery 110, 120 | 7 |
| Open 210, 220, 230 | 6 |
| Delivery 300 | 8 |
| Known hard part (DNS) | 2 (`dns_up`), 9 |
| Authoring rule (demonstrated failure) | step 3 of tasks 4–9 |
| CI `tests.yml` / `nightly.yml` | 11 |
| Operational rules (timeout, labels, diagnostics, disk, no layer cache) | 1 (timeout, labels, sweep), 2 (`it_diagnose`), 3 (build cost), 11 |
| Platform scope (Linux CI only) | 0, 3, 11 |
| Success criteria 1–5 | 11 step 6; criterion 6 rescoped in 10 |

**Gaps found and closed while reviewing:**
- The spec's 15 cases have no case proving the *harness* works. A destination nothing could ever reach is indistinguishable from one the firewall dropped, so `000-harness-selftest` was added — corpus is 16.
- Nothing in the spec addressed `build.sh` overwriting the developer's real `allowlist-*.txt`. `run.sh` now snapshots and restores them (and the snapshot doubles as case `300`'s expectation).
- The spec's `085` is not testable as `fast`; corrected.
- Criterion 6 conflicts with "package installs out of scope"; rescoped in Task 10 rather than met by deleting coverage.

**Type/name consistency:** verbs used in Tasks 3–9 (`sidecar_up`, `dns_up`, `sandbox_up`, `reach`, `blocked_entries`, `pid1_caps`, `assert_reachable`, `assert_blocked`, `assert_file_exists`, `assert_file_absent`, `assert_log_contains`, `assert_no_capability`, `it_wait`, `it_scratch`, `it_finish`, `skip`, `allowlist_write`) all match the Task 2 signature table. Globals `$IT_CID`, `$IT_SIDECAR`, `$IT_SIDECAR_IP`, `$IT_DNS`, `$IT_DNS_IP`, `$IT_REPO_DIR`, `$IT_GENERATED_ALLOWLIST_DIR` are set where the table says and read only after the setting call returns 0.

**Placeholder scan:** none. Every step names exact files, exact commands, and exact expected output.

---

## Task 0 result

Recorded from GitHub Actions run `31086302463` on `ubuntu-latest`.

### Runner kernel modules — all available

```
ip_set                 61440  1 xt_set      (already loaded)
nfnetlink              20480  6 nft_compat,nf_tables,ip_set
ip_set OK
nfnetlink_log OK
xt_NFLOG OK
```

### In-container netfilter — every operation succeeded

All seven printed `rc=0`: `ipset create` (inet and inet6), `ipset add`,
`iptables -P OUTPUT DROP`, `-m set --match-set … -j ACCEPT`,
`-j NFLOG --nflog-group 100`, `ip6tables -P OUTPUT DROP`.

`curl` to a non-allowlisted destination returned **`rc=124`** — it timed out,
i.e. the packet was dropped. Enforcement works on `ubuntu-latest`.

### NFLOG capture — first probe INCONCLUSIVE, re-probed

```
nflog stdout: []
nflog stderr: [Running as user "root" and group "root". This could be dangerous.]
```

stderr carries only the harmless setuid notice — tshark **opened** the handle
without error and then captured nothing. This is not the "capture session could
not be initiated" signature the plan predicted, and it is very likely a defect in
the probe rather than in the runner: the probe backgrounded `tshark -c 1`, slept
3 s, and fired a single `curl`. tshark spends several seconds loading dissectors
before it attaches, and the timestamps show it exiting at exactly its 10 s
timeout having matched nothing.

Treating that as "NFLOG unavailable" would move five capture cases to local-only
on the strength of a race in the test harness. Re-probed against the **real
image and the real entrypoint** (restricted mode, synthetic allowlist, a sidecar
absent from it, then read `blocked-ips.txt`), which is the property the suite
actually depends on. See `## Task 0 result — NFLOG re-probe` below.

### Minimal image

| Metric | Value |
|---|---|
| Build time | **194 s** — no BuildKit layer caching needed |
| Size | **1.42 GB** |
| `node --version` | **v24.19.0** — the sidecar runtime is present |
| `command -v python3` | **`/opt/pyenv/shims/python3`** |

### Correction to spec correction 1

**`python3` IS present in a minimal image**, at `/opt/pyenv/shims/python3` —
pyenv is installed unconditionally because the AI agents need Python. The spec's
`python3 -m http.server` sidecar would therefore work, and the reason given in
spec correction 1 ("a minimal image has no python3") is **wrong**.

The sidecar still uses `node`, for a different and narrower reason: the probe
proved `node` **runs** (`node --version` → `v24.19.0`), whereas it only proved
`python3` **resolves** — `command -v` finds the pyenv shim without ever executing
it, and a shim with no configured version exits non-zero when invoked. Rewrite
correction 1 to say that; do not repeat the "no python3" claim.

---

## Task 0 result — NFLOG re-probe

Run `31100617473`, branch `it-nflog-probe`. Two experiments; the second printed
`NFLOG CAPTURE DID NOT RECORD`, and **that printed verdict is wrong**. The first
experiment explains why.

### A — raw tshark on `nflog:100`, with a real settle and repeated traffic

```
tshark attached after 22s: [Running as user "root" and group "root". …]
── nflog captured ──
10.99.0.99	80      (×9)
── line count: 9 ──
```

**NFLOG works on `ubuntu-latest`.** Nine dropped packets delivered to userspace.
The first probe's empty result was entirely its own 3-second sleep.

### B — the real entrypoint (printed a false negative)

```
agent shell up after 2s
blocked (expected)
── real (non-comment) entries ──      ← empty
NFLOG CAPTURE DID NOT RECORD
```

Same race, one layer up. Experiment A measured the thing that matters:
**tshark takes ~22 seconds to attach to the NFLOG group.** Experiment B waited
only for the agent shell (2 s), fired its one blocked flow at t≈3 s, slept 8 s
and read the file at t≈13 s — nine seconds before the watcher was listening.
The packet was dropped and logged by the kernel; nobody was reading yet.

### The finding this yields, which the plan did not have

`capture-blocked-traffic.sh`'s NFLOG watcher is **not effective for roughly the
first 20+ seconds** of a container's life. On a developer's machine this is
invisible — containers live for hours. In a test it decides the result.

Therefore **`sandbox_up` must be able to wait for capture readiness, not merely
for the agent shell**, and every case that generates traffic it expects to see
recorded (`040`, `060`, `080`, `085`) must use that wait before generating it.
Waiting on the *output files* is not sufficient: `init_output_files` creates them
early, long before tshark attaches — which is exactly the trap `050` is designed
around and a traffic-generating case must not fall into.

The readiness predicate, proven by experiment A, is tshark's own announcement:

```bash
grep -q 'Capturing on' /workspace/.agent-blocked/tshark-nflog-errors.log
```

**Amendments to Task 2 (`lib.sh`):** add a `capture_ready <cid>` verb polling
that predicate, and give `sandbox_up` an opt-in wait for it. Raise `IT_SETTLE`
to at least 60 s. **Amendments to Tasks 5 and 9:** call it before generating
traffic. Without this the capture cases fail intermittently on fast machines and
reliably in CI — and would have been misread as "NFLOG does not work in CI".

### Verdict

**Outcome 1 of Task 0 step 4 applies: everything works; no plan changes to the
CI job list.** The capture tier gates PRs. `ip_set`, `nfnetlink_log`, `xt_NFLOG`,
`-m set --match-set`, `-j NFLOG`, and `nflog:` capture are all available on
`ubuntu-latest`.
