#!/usr/bin/env bash
# Unit tests for the `playwright` sandbox.conf key.
#
# The key buys ONE thing at build time — the OS packages Playwright's browsers
# link against — and two things at run time: the allowlist entries that let
# `npx playwright install` fetch browser binaries through the firewall, and a
# group-scoped ~/.cache/ms-playwright so that ~500 MB download survives the
# container exiting (sandbox.sh runs `docker run --rm`).
#
# It cannot be a runtime install. entrypoint.sh permanently drops root via
# `capsh --user=` before the agent shell exists, so nothing inside the container
# can ever run `apt-get install`. Baked at build time or not at all.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring assertions —
# that the key produces the right build arg, the right allowlist, the right
# mount and the right --shm-size. That the resulting LAYER BUILDS is a different
# claim, and integration case 770-playwright-deps-present.sh (packages tier,
# `native` variant) is where it is made, with mutation 770 to demonstrate it
# failing. Neither substitutes for the other.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── Part A: sandbox.conf value → PLAYWRIGHT_VERSION build arg ──────────────────
# The grammar is dtctl's: ON | x.y.z | OFF. `ON` cannot be passed through as the
# literal string "ON" (npx would try to install playwright@ON), so it maps to
# `latest`; a pinned version passes through verbatim; everything else is empty,
# which is what the Dockerfile layer tests for.

# build_arg_for <conf-body> <build-arg-name> — echo that build arg's VALUE, or
# nothing if build.sh never emitted it. Sources the real build.sh, so the
# assertion is against the shipped function and not a copy of its logic.
build_arg_for() {
  local body="$1" want="$2" tmp
  tmp="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n' >&2; return 1; }
  printf '# schema-version: 4\n%s\n' "$body" > "$tmp/sandbox.conf"
  (
    export SANDBOX_CONF="$tmp/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    local a
    for a in "${args[@]}"; do
      [[ "$a" == "${want}="* ]] && { printf '%s' "${a#"${want}"=}"; break; }
    done
  )
  rm -rf "$tmp"
}

got="$(build_arg_for 'playwright=ON' PLAYWRIGHT_VERSION)"
[[ "$got" == "latest" ]] \
  && pass "playwright=ON → PLAYWRIGHT_VERSION=latest" \
  || fail "playwright=ON → PLAYWRIGHT_VERSION=latest (got '$got')"

got="$(build_arg_for 'playwright=1.58.2' PLAYWRIGHT_VERSION)"
[[ "$got" == "1.58.2" ]] \
  && pass "playwright=1.58.2 → PLAYWRIGHT_VERSION=1.58.2 (pinned, verbatim)" \
  || fail "playwright=1.58.2 → PLAYWRIGHT_VERSION=1.58.2 (got '$got')"

# An explicit OFF must reach the Dockerfile as EMPTY, never as the string "OFF".
# This is the version-list-OFF defect the repo already hit once with ruby=OFF:
# the literal value sailed through into the container and was treated as a
# version. Here it would become `npx playwright@OFF install-deps`.
got="$(build_arg_for 'playwright=OFF' PLAYWRIGHT_VERSION)"
[[ -z "$got" ]] \
  && pass "playwright=OFF → PLAYWRIGHT_VERSION empty (never the literal 'OFF')" \
  || fail "playwright=OFF → PLAYWRIGHT_VERSION empty (got '$got')"

got="$(build_arg_for 'playwright=' PLAYWRIGHT_VERSION)"
[[ -z "$got" ]] \
  && pass "playwright= (empty) → PLAYWRIGHT_VERSION empty" \
  || fail "playwright= (empty) → PLAYWRIGHT_VERSION empty (got '$got')"

got="$(build_arg_for 'copilot=ON' PLAYWRIGHT_VERSION)"
[[ -z "$got" ]] \
  && pass "playwright key absent → PLAYWRIGHT_VERSION empty" \
  || fail "playwright key absent → PLAYWRIGHT_VERSION empty (got '$got')"

# The key buys browser LIBRARIES, not a compiler. c-toolchain is the key for
# that, and conflating them would grow every Playwright image by a toolchain
# nothing asked for — the same argument that keeps `go=` from implying it.
got="$(build_arg_for 'playwright=ON' KEEP_BUILD_TOOLCHAIN)"
[[ "$got" == "0" ]] \
  && pass "playwright=ON does not drag in the build toolchain" \
  || fail "playwright=ON does not drag in the build toolchain (KEEP_BUILD_TOOLCHAIN=$got)"

got="$(build_arg_for 'playwright=ON' RUBY_RUNTIME)"
[[ "$got" == "0" ]] \
  && pass "playwright=ON does not drag in the Ruby runtime" \
  || fail "playwright=ON does not drag in the Ruby runtime (RUBY_RUNTIME=$got)"

# ── Part B: validate_config rejects a version LIST ─────────────────────────────
# One layer runs one `npx playwright@<ver> install-deps`, so a comma-separated
# value has no meaning. angular-cli is the precedent for catching this in
# validate_config with a clear message rather than letting it reach npx, where
# the failure reads as a registry error about a package named "1.50.0,1.58.2".
VC_TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
printf '# schema-version: 4\nplaywright=1.50.0,1.58.2\n' > "$VC_TMP/sandbox.conf"
vc_out="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
vc_rc=$?
if (( vc_rc != 0 )) && [[ "$vc_out" == *playwright* ]]; then
  pass "validate_config rejects a comma-separated playwright value, by name"
else
  fail "validate_config rejects a comma-separated playwright value (rc=$vc_rc, out='$vc_out')"
fi

# The control: a single pinned version must NOT be rejected, or the check above
# would be satisfied by a validate_config that refuses everything.
printf '# schema-version: 4\nplaywright=1.58.2\n' > "$VC_TMP/sandbox.conf"
if SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" >/dev/null 2>&1; then
  pass "validate_config accepts a single pinned playwright version"
else
  fail "validate_config accepts a single pinned playwright version"
fi
rm -rf "$VC_TMP"

# ── Part C: the allowlist fragment, gated by the REAL generate_allowlists ──────
# Asserted by running the shipped function over an isolated copy of the repo and
# reading the file it produces — not by grepping build.sh for a line that looks
# like it does the right thing. test-db-clients.sh established this pattern for
# the mongo fragment after the text-matching version of it proved able to pass
# while the gating was wrong.
[[ -f "$REPO_DIR/allowlist-domains.d/playwright.txt" ]] \
  && pass "playwright.txt fragment exists" \
  || { fail "playwright.txt fragment missing"; }

GA_TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
cp "$REPO_DIR/build.sh" "$REPO_DIR/sandbox-common.sh" "$REPO_DIR/tools-lib.sh" \
   "$REPO_DIR/bash-floor.sh" "$GA_TMP/"
cp -r "$REPO_DIR/allowlist-domains.d" "$REPO_DIR/allowlist-proxy-domains.d" \
      "$REPO_DIR/allowlist-cidrs.d" "$GA_TMP/"
mkdir -p "$GA_TMP/tools.d"

# A host that appears ONLY in the playwright fragment, so its presence in the
# generated file can mean nothing else. Read from the fragment rather than
# hardcoded here, so changing the fragment cannot silently un-test this.
PW_HOST="$(grep -vE '^\s*(#|$)' "$REPO_DIR/allowlist-domains.d/playwright.txt" 2>/dev/null | head -1)"
if [[ -z "$PW_HOST" ]]; then
  fail "playwright.txt has no host entries — the gating assertions below cannot mean anything"
else
  gen_has_host() {  # $1 = sandbox.conf body → rc 0 if the generated allowlist has PW_HOST
    printf '%s\n' "$1" > "$GA_TMP/sandbox.conf"
    ( cd "$GA_TMP" && SANDBOX_CONF="$GA_TMP/sandbox.conf" \
        bash -c 'source ./build.sh; generate_allowlists' ) >/dev/null 2>&1 || true
    grep -qx -- "$PW_HOST" "$GA_TMP/allowlist-domains.txt" 2>/dev/null
  }

  gen_has_host 'playwright=ON' \
    && pass "generate_allowlists includes playwright.txt when the key is ON" \
    || fail "generate_allowlists includes playwright.txt when the key is ON"

  # THE ASSERTION THAT CATCHES is_enabled. `is_enabled` matches only the literal
  # ON, so gating the fragment with it would leave a PINNED install unable to
  # download a single browser through the firewall — a failure that looks like a
  # network problem and points nowhere near this key. `is_active` is the correct
  # helper (non-empty and not OFF), and this is what tells the two apart.
  gen_has_host 'playwright=1.58.2' \
    && pass "generate_allowlists includes playwright.txt for a PINNED version (is_active, not is_enabled)" \
    || fail "generate_allowlists includes playwright.txt for a PINNED version (is_active, not is_enabled)"

  gen_has_host 'playwright=OFF' \
    && fail "generate_allowlists excludes playwright.txt when the key is OFF" \
    || pass "generate_allowlists excludes playwright.txt when the key is OFF"

  gen_has_host 'copilot=ON' \
    && fail "generate_allowlists excludes playwright.txt when the key is absent" \
    || pass "generate_allowlists excludes playwright.txt when the key is absent"
fi
rm -rf "$GA_TMP"

# ── Part D: sandbox.sh — the browser cache mount and --shm-size ────────────────
# Driven through a fake `docker` on PATH that captures the assembled `docker run`
# argv, the harness test-tool-config-mounts.sh established. No daemon involved.
REAL_HOME="$HOME"

pw_setup() {  # $1 = sandbox.conf body
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  export HOME="$TMP/home"; mkdir -p "$HOME"
  # Canonicalise HOME independently of the function under test: sandbox.sh
  # resolve_path()s every mount source, so on a host whose temp root is reached
  # through a symlink (macOS /var -> /private/var) an uncanonicalised
  # expectation mismatches a canonicalised -v argument and reads as a missing
  # mount that is really there.
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP CONTAINER_SHM_SIZE

  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 4\n%s\n' "$1" > "$SANDBOX_CONF"

  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"

  GROUP_ROOT="$HOME/.ai-containers/default"
  mkdir -p "$TMP/app" "$TMP/launch"
}
pw_teardown() {
  rm -rf "$TMP"
  unset SANDBOX_CONF AI_CONTAINER_GROUP AI_CONTAINER_GROUP_INIT SANDBOX_USER CONTAINER_SHM_SIZE
  export HOME="$REAL_HOME"
}
pw_run() { ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) >/dev/null 2>&1 </dev/null; }

# ON: the cache is group-scoped, so the browser download survives `--rm`.
pw_setup 'playwright=ON'
pw_run
if [[ -d "$GROUP_ROOT/.cache/ms-playwright" ]]; then
  pass "playwright=ON: group browser-cache dir created"
else
  fail "playwright=ON: group browser-cache dir created"
fi
if grep -qx -- "$GROUP_ROOT/.cache/ms-playwright:/home/dev/.cache/ms-playwright:rw" "$CAPTURE"; then
  pass "playwright=ON: browser cache mounted from the group"
else
  fail "playwright=ON: browser cache mounted from the group"
fi
# /dev/shm, not RAM, is what kills headless Chromium in Docker: the default is
# 64 MB and CONTAINER_MEMORY does not govern it, so a container with 16 GB still
# crashes. Playwright's own docs reach for --ipc=host; that shares the host IPC
# namespace, which this project's isolation posture will not spend, so
# --shm-size buys the same fix without it.
if grep -qx -- '--shm-size=1g' "$CAPTURE"; then
  pass "playwright=ON: --shm-size=1g passed (64MB default crashes Chromium)"
else
  fail "playwright=ON: --shm-size=1g passed (64MB default crashes Chromium)"
fi
if grep -qx -- '--ipc=host' "$CAPTURE"; then
  fail "--ipc=host is never passed (it would share the host IPC namespace)"
else
  pass "--ipc=host is never passed (it would share the host IPC namespace)"
fi
pw_teardown

# A pinned version is just as active as ON — same reasoning as the allowlist
# assertion above, applied to the mount and the shm flag.
pw_setup 'playwright=1.58.2'
pw_run
if grep -qx -- "$GROUP_ROOT/.cache/ms-playwright:/home/dev/.cache/ms-playwright:rw" "$CAPTURE"; then
  pass "playwright=<pinned>: browser cache mounted (is_active, not is_enabled)"
else
  fail "playwright=<pinned>: browser cache mounted (is_active, not is_enabled)"
fi
if grep -qx -- '--shm-size=1g' "$CAPTURE"; then
  pass "playwright=<pinned>: --shm-size passed (is_active, not is_enabled)"
else
  fail "playwright=<pinned>: --shm-size passed (is_active, not is_enabled)"
fi
pw_teardown

# CONTAINER_SHM_SIZE overrides the default, matching the CONTAINER_CPUS /
# CONTAINER_MEMORY / CONTAINER_NOFILE idiom.
pw_setup 'playwright=ON'
export CONTAINER_SHM_SIZE=2g
pw_run
if grep -qx -- '--shm-size=2g' "$CAPTURE"; then
  pass "CONTAINER_SHM_SIZE overrides the default"
else
  fail "CONTAINER_SHM_SIZE overrides the default"
fi
pw_teardown

# OFF: every container that does not ask for Playwright is what it is today —
# no mount, no group dir, and no --shm-size flag at all.
pw_setup 'playwright=OFF'
pw_run
if [[ ! -e "$GROUP_ROOT/.cache/ms-playwright" ]]; then
  pass "playwright=OFF: no group browser-cache dir"
else
  fail "playwright=OFF: no group browser-cache dir"
fi
if grep -q 'ms-playwright' "$CAPTURE"; then
  fail "playwright=OFF: browser cache not mounted"
else
  pass "playwright=OFF: browser cache not mounted"
fi
if grep -q -- '--shm-size' "$CAPTURE"; then
  fail "playwright=OFF: no --shm-size flag (non-Playwright containers unchanged)"
else
  pass "playwright=OFF: no --shm-size flag (non-Playwright containers unchanged)"
fi
pw_teardown

# ...but CONTAINER_SHM_SIZE remains honoured on its own, so the escape hatch is
# not silently tied to one component's key.
pw_setup 'playwright=OFF'
export CONTAINER_SHM_SIZE=512m
pw_run
if grep -qx -- '--shm-size=512m' "$CAPTURE"; then
  pass "CONTAINER_SHM_SIZE works without playwright"
else
  fail "CONTAINER_SHM_SIZE works without playwright"
fi
pw_teardown

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
# The build arg is the whole interface, exactly as KEEP_BUILD_TOOLCHAIN is for
# the toolchain layer (test-db-clients.sh, backlog F60). That is what lets the
# integration case prove `PLAYWRIGHT_VERSION=<v> → working deps` once and have
# it hold for every value of the key, including values added later.
DF="$REPO_DIR/Dockerfile"
if [[ ! -f "$DF" ]]; then
  fail "the Dockerfile is where the playwright layer lives"
else
  if grep -qE '^ARG PLAYWRIGHT_VERSION=' "$DF"; then
    pass "the Dockerfile declares ARG PLAYWRIGHT_VERSION"
  else
    fail "the Dockerfile declares ARG PLAYWRIGHT_VERSION"
  fi

  # The layer must sit AFTER the unconditional cleanup purge, or that purge
  # strips what it just installed. imagemagick and wkhtmltopdf are both placed
  # this way; wkhtmltopdf's survival is what integration case 730 observes.
  purge_line="$(grep -n 'apt-get purge -y --auto-remove' "$DF" | head -1 | cut -d: -f1)"
  pw_line="$(grep -n '^ARG PLAYWRIGHT_VERSION=' "$DF" | head -1 | cut -d: -f1)"
  if [[ -n "$purge_line" && -n "$pw_line" ]] && (( pw_line > purge_line )); then
    pass "the playwright layer is placed after the cleanup purge (line $pw_line > $purge_line)"
  else
    fail "the playwright layer is placed after the cleanup purge (purge=$purge_line playwright=$pw_line)"
  fi

  # The RUN block reads PLAYWRIGHT_VERSION and nothing else. A layer that also
  # consulted INSTALL_* or DB_CLIENTS would break the composition argument
  # above: the integration case proves one arg value, not a matrix.
  pw_block="$(awk '/^ARG PLAYWRIGHT_VERSION=/{inb=1} inb{print} inb&&/^[[:space:]]*fi;?[[:space:]]*\\?[[:space:]]*$/{exit}' "$DF")"
  if [[ -z "$pw_block" ]]; then
    fail "the playwright RUN block is findable for inspection"
  else
    offenders="$(printf '%s\n' "$pw_block" | grep -nE '\$(INSTALL_|DB_CLIENTS|RUBY_RUNTIME|KEEP_BUILD_TOOLCHAIN)' || true)"
    if [[ -z "$offenders" ]]; then
      pass "the playwright layer reads PLAYWRIGHT_VERSION and no other build arg"
    else
      fail "the playwright layer reads PLAYWRIGHT_VERSION and no other build arg"
      printf '%s\n' "$offenders" | sed 's/^/     /'
    fi
    # An empty value must be the skip. If the guard tested anything else — say
    # `!= "OFF"` — then `playwright=` would run `npx playwright@ install-deps`.
    # A here-string, not `printf | grep -q`: grep exits on the first match and
    # SIGPIPEs the producer, which under `set -o pipefail` is a non-zero status
    # nobody asked for (backlog F34, tests/test-grep-q-pipelines.sh — which
    # caught this exact line).
    if grep -qE '\-n "\$PLAYWRIGHT_VERSION"' <<<"$pw_block"; then
      pass "the playwright layer skips on an EMPTY PLAYWRIGHT_VERSION"
    else
      fail "the playwright layer skips on an EMPTY PLAYWRIGHT_VERSION"
    fi
  fi
fi

# ── Part F: what the shipped sandbox.conf propagates to projects ──────────────
# sync-to-projects.sh's reconcile_sandbox_conf appends a new upstream key to
# every project USING THIS REPO'S VALUE for it. Shipping anything but OFF would
# switch Playwright on across every registered project on their next sync, and
# grow each of their images by several hundred MB nobody asked for.
if grep -qx 'playwright=OFF' "$REPO_DIR/sandbox.conf"; then
  pass "sandbox.conf ships playwright=OFF (so sync-to-projects propagates OFF)"
else
  fail "sandbox.conf ships playwright=OFF (so sync-to-projects propagates OFF)"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
