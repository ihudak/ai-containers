#!/usr/bin/env bash
# Drives agent-tools-reconcile.sh against STUBBED npm/uv/curl/tar/dpkg (no network).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/agent-tools-reconcile.sh" && pass "agent-tools-reconcile.sh bash -n" || fail "agent-tools-reconcile.sh bash -n"

# Create a fake toolchain in $1(bin dir), writing installs into $2(home). NPM_FAIL=1
# makes npm exit 1 (simulate offline). Each fake records to $2/calls.log.
mk_stubs() {
  local bin="$1" home="$2"
  cat > "$bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$home/calls.log"
[[ "\${NPM_FAIL:-0}" == "1" ]] && exit 1
# Match the package name anywhere in the argv rather than at a fixed position:
# the real invocation is "install -g --prefix <dir> <pkg>", i.e. the package is
# the LAST arg, not \$3 — a fixed-position check would silently stop detecting
# installs the moment --prefix was inserted, hiding a regression instead of
# catching it.
case "\$*" in
  *@anthropic-ai/claude-code*) b=claude ;; *@github/copilot*) b=copilot ;;
  *@openai/codex*) b=codex ;; *@google/gemini-cli*) b=gemini ;; *) b="" ;;
esac
if [[ "\$1" == "install" && -n "\$b" ]]; then
  install -d "$home/.ai-tools/npm/bin"; printf '#!/bin/sh\n' > "$home/.ai-tools/npm/bin/\$b"; chmod +x "$home/.ai-tools/npm/bin/\$b"
fi
exit 0
EOF
  cat > "$bin/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$home/calls.log"
if [[ "\$1 \$2" == "tool install" ]]; then
  d="\${UV_TOOL_BIN_DIR:-$home/.ai-tools/uv/bin}"; install -d "\$d"; printf '#!/bin/sh\n' > "\$d/graphify"; chmod +x "\$d/graphify"
fi
exit 0
EOF
  cat > "$bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$home/calls.log"
for a in "\$@"; do case "\$a" in *releases/latest) echo "https://github.com/vale-cli/vale/releases/tag/v3.0.0"; exit 0;; esac; done
# Claude Code's NATIVE installer is fetched and piped to bash, so this stub must emit a
# SCRIPT on stdout rather than write a file. What it emits mirrors what the real one does
# — a versions dir plus the ~/.local/bin/claude launcher — because the reconcile keys
# install-if-missing on exactly those two paths. CLAUDE_FAIL=1 makes it emit a script that
# exits non-zero, which is how the offline case is exercised without a second stub.
for a in "\$@"; do case "\$a" in *claude.ai/install.sh)
  if [[ "\${CLAUDE_FAIL:-0}" == "1" ]]; then echo 'exit 1'; exit 0; fi
  cat <<'INNER'
install -d "\$HOME/.local/share/claude/versions/9.9.9" "\$HOME/.local/state/claude" "\$HOME/.local/bin"
printf '#!/bin/sh\n' > "\$HOME/.local/bin/claude"; chmod +x "\$HOME/.local/bin/claude"
INNER
  exit 0;; esac; done
prev=""; for a in "\$@"; do [[ "\$prev" == "-o" ]] && : > "\$a"; prev="\$a"; done
exit 0
EOF
  cat > "$bin/tar" <<EOF
#!/usr/bin/env bash
echo "tar \$*" >> "$home/calls.log"
d=""; prev=""; for a in "\$@"; do [[ "\$prev" == "-C" ]] && d="\$a"; prev="\$a"; done
[[ -n "\$d" ]] && { printf '#!/bin/sh\n' > "\$d/vale"; chmod +x "\$d/vale"; }
exit 0
EOF
  printf '#!/usr/bin/env bash\necho amd64\n' > "$bin/dpkg"
  printf '#!/usr/bin/env bash\n[ "$1" = "-m" ] && echo x86_64 || echo Linux\n' > "$bin/uname"
  chmod +x "$bin/npm" "$bin/uv" "$bin/curl" "$bin/tar" "$bin/dpkg" "$bin/uname"
}

# run_case WANT [HOME] [NPM_FAIL] -> echoes the home dir it used (caller inspects & cleans).
run_case() {
  local want="$1" home="${2:-$(mktemp -d)}" npm_fail="${3:-0}"
  local bin; bin="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  mk_stubs "$bin" "$home"
  PATH="$bin:$PATH" HOME="$home" AI_RUNTIME_TOOLS="$want" NPM_FAIL="$npm_fail" \
    bash "$REPO_DIR/agent-tools-reconcile.sh" >"$home/out.log" 2>&1
  rm -rf "$bin"
  printf '%s' "$home"
}

# ── All six install on a fresh home ──
h="$(run_case "claude-code,copilot,codex,gemini,graphify,vale")"
c="$h/calls.log"
# Claude Code installs NATIVELY, never through npm. Both directions are asserted: the
# installer must be fetched, AND no npm install may name the package. Checking only the
# first would still pass if npm were reintroduced alongside, which is the configuration
# that reinstates ~300 MB of dead weight and lets the npm copy shadow the native launcher.
grep -q 'curl .*claude\.ai/install\.sh' "$c" && pass "installs claude-code natively" || fail "installs claude-code natively"
! grep -q 'npm install .*@anthropic-ai/claude-code' "$c" && pass "claude-code is NOT installed via npm" || fail "claude-code is NOT installed via npm"
grep -q 'npm install -g --prefix .*@github/copilot' "$c"           && pass "installs copilot"     || fail "installs copilot"
grep -q 'npm install -g --prefix .*@openai/codex' "$c"             && pass "installs codex"       || fail "installs codex"
grep -q 'npm install -g --prefix .*@google/gemini-cli' "$c"        && pass "installs gemini"      || fail "installs gemini"
grep -q 'uv tool install graphifyy' "$c"                && pass "installs graphify"    || fail "installs graphify"
grep -q 'tar ' "$c"                                     && pass "installs vale (tar)"  || fail "installs vale (tar)"
{ grep -q 'vale_.*_Linux_64-bit\.tar\.gz' "$c" && ! grep -q 'Linux_amd64' "$c"; } \
  && pass "vale downloads the correct GoReleaser arch asset (64-bit on x86_64)" \
  || fail "vale downloads the correct GoReleaser arch asset (64-bit on x86_64)"
[[ -x "$h/.ai-tools/bin/vale" ]] && pass "vale binary lands at .ai-tools/bin/vale" || fail "vale binary lands at .ai-tools/bin/vale"
# The native installer owns ~/.local/bin/claude. It must be a REAL executable, not a
# symlink into the npm prefix — a symlink here would mean the leftover-npm fallback fired
# and shadowed the native install, which is the one that can self-update.
[[ -x "$h/.local/bin/claude" ]] && pass "claude launcher present at ~/.local/bin/claude" || fail "claude launcher present at ~/.local/bin/claude"
[[ ! -L "$h/.local/bin/claude" ]] && pass "claude launcher is the native one, not an npm symlink" || fail "claude launcher is the native one, not an npm symlink"
[[ -d "$h/.local/share/claude" ]] && pass "native install dir ~/.local/share/claude created" || fail "native install dir ~/.local/share/claude created"
[[ -f "$h/.ai-tools/.reconcile.lock" ]] && pass "reconcile lock file created" || fail "reconcile lock file created"

# Bug 1: every npm install must target ~/.ai-tools/npm via an explicit --prefix flag,
# NOT a baked ~/.npmrc — a baked prefix makes nvm's nvm_die_on_prefix fail `nvm use
# <version>` outright (see agent-tools-reconcile.sh / AGENTS.md "Agent-tier tools").
# THREE, not four: claude-code left the npm set when it moved to the native installer.
# The number is asserted rather than a mere ">0" because the failure this guards against
# is an EXTRA npm call reappearing, not a missing one.
n_prefix_calls="$(grep -cE -- '--prefix[[:space:]]+[^[:space:]]*/\.ai-tools/npm([[:space:]]|$)' "$c")"
[[ "$n_prefix_calls" -eq 3 ]] && pass "all 3 npm installs pass --prefix .../.ai-tools/npm explicitly ($n_prefix_calls)" \
  || fail "all 3 npm installs pass --prefix .../.ai-tools/npm explicitly (got $n_prefix_calls, want 3)"
rm -rf "$h"

# ── Idempotent for the tools that can keep THEMSELVES current ──
# claude-code (native, self-updates), copilot (self-updates), graphify and vale are
# install-if-missing, so a second run on the same home must not re-fetch them.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; run_case "claude-code,copilot,graphify,vale" "$h" >/dev/null; : > "$h/calls.log"; run_case "claude-code,copilot,graphify,vale" "$h" >/dev/null
{ ! grep -q 'claude\.ai/install\.sh' "$h/calls.log" \
  && ! grep -q '@github/copilot' "$h/calls.log" \
  && ! grep -q 'uv tool install' "$h/calls.log"; } \
  && pass "idempotent: self-updating tools not reinstalled" || fail "idempotent: self-updating tools not reinstalled"
rm -rf "$h"

# ── NOT idempotent, deliberately: codex and gemini are UPDATED every start ──
# Neither can self-update in this environment — codex's own `update` shells out to a bare
# `npm install -g` and dies EACCES 243, and gemini ships no updater at all — so the
# reconcile is what keeps them current. A second run MUST re-issue their installs; if this
# ever starts passing as "idempotent", those two have silently frozen at whatever version
# the group first saw, which is the exact defect this pair of cases exists to separate.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; run_case "codex,gemini" "$h" >/dev/null; : > "$h/calls.log"; run_case "codex,gemini" "$h" >/dev/null
{ grep -q 'npm install -g --prefix .*@openai/codex' "$h/calls.log" \
  && grep -q 'npm install -g --prefix .*@google/gemini-cli' "$h/calls.log"; } \
  && pass "codex and gemini are re-installed (updated) on every run" || fail "codex and gemini are re-installed (updated) on every run"
rm -rf "$h"

# ── A group still carrying the pre-native npm Claude keeps working ──
# Those groups exist (~300 MB under ~/.ai-tools/npm) and are deliberately not deleted, so
# the fallback must fire ONLY when no native install is present.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
install -d "$h/.ai-tools/npm/bin"; printf '#!/bin/sh\n' > "$h/.ai-tools/npm/bin/claude"; chmod +x "$h/.ai-tools/npm/bin/claude"
bin="$(mktemp -d)"; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code" CLAUDE_FAIL=1 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rm -rf "$bin"
{ [[ -L "$h/.local/bin/claude" ]] && [[ "$(readlink "$h/.local/bin/claude")" == "$h/.ai-tools/npm/bin/claude" ]]; } \
  && pass "leftover npm claude is used when the native install is absent" || fail "leftover npm claude is used when the native install is absent"
rm -rf "$h"

# ── Empty AI_RUNTIME_TOOLS → no-op ──
h="$(run_case "")"; [[ ! -s "$h/calls.log" ]] && pass "empty AI_RUNTIME_TOOLS is a no-op" || fail "empty AI_RUNTIME_TOOLS is a no-op"; rm -rf "$h"

# ── Selective: only codex requested → only codex installed ──
h="$(run_case "codex")"; { grep -q 'npm install -g --prefix .*@openai/codex' "$h/calls.log" && ! grep -q '@google/gemini-cli' "$h/calls.log"; } && pass "installs only requested tools" || fail "installs only requested tools"; rm -rf "$h"

# ── Offline npm: FAILED logged, non-fatal, other tools still attempted ──
# Driven through codex, not claude-code: claude-code no longer touches npm, so NPM_FAIL
# would not reach it and this case would assert nothing while still reporting a pass.
h="$(run_case "codex,graphify" "" 1)"
{ grep -q 'FAILED' "$h/out.log" && grep -q 'uv tool install graphifyy' "$h/calls.log"; } && pass "npm failure is non-fatal; other tools proceed" || fail "npm failure is non-fatal; other tools proceed"; rm -rf "$h"

# ── Offline native installer: FAILED logged, non-fatal, other tools still attempted ──
# The claude-code equivalent of the case above. Without it, a broken native install would
# be the one failure path with no coverage.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
bin="$(mktemp -d)"; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code,graphify" CLAUDE_FAIL=1 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rm -rf "$bin"
{ grep -q 'FAILED' "$h/out.log" && grep -q 'uv tool install graphifyy' "$h/calls.log"; } \
  && pass "native install failure is non-fatal; other tools proceed" || fail "native install failure is non-fatal; other tools proceed"; rm -rf "$h"

# ── Exit code: script must exit 0 whether or not an install fails (non-fatal) ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; bin="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" NPM_FAIL=0 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rc=$?
rm -rf "$bin" "$h"
[[ "$rc" -eq 0 ]] && pass "exit code 0 when all installs succeed" || fail "exit code 0 when all installs succeed"

h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; bin="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code,graphify" NPM_FAIL=1 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rc=$?
rm -rf "$bin" "$h"
[[ "$rc" -eq 0 ]] && pass "exit code 0 when npm install fails (non-fatal)" || fail "exit code 0 when npm install fails (non-fatal)"

# ── Guards ──
grep -qE 'flock[[:space:]]+9' "$REPO_DIR/agent-tools-reconcile.sh" && pass "flock-guarded (real call, not just the header comment)" || fail "flock-guarded (real call, not just the header comment)"
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/agent-tools-reconcile.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

# ── Bug 1 static guards: no baked npm global prefix; reconcile targets ~/.ai-tools/npm ──
# A $HOME/.npmrc `prefix=` (or `globalconfig=`) line is what makes nvm's
# nvm_die_on_prefix fail `nvm use <version>` outright (verified against nvm's
# upstream source, not assumed) — so nothing baked into the image may write one.
if grep -q '/etc/skel/.npmrc' "$REPO_DIR/Dockerfile"; then
  fail "Dockerfile no longer bakes a global npm prefix via /etc/skel/.npmrc (breaks nvm use <version>)"
else
  pass "Dockerfile bakes no /etc/skel/.npmrc (no global npm prefix)"
fi
grep -qE "printf[^|]*(^|[^A-Za-z_])(prefix|globalconfig)=" "$REPO_DIR/Dockerfile" \
  && fail "Dockerfile must not bake a prefix=/globalconfig= line anywhere" \
  || pass "Dockerfile bakes no prefix=/globalconfig= line anywhere"
grep -qF 'npm-agent-tools() { npm --prefix "$HOME/.ai-tools/npm" "$@"; }' "$REPO_DIR/Dockerfile" \
  && pass "Dockerfile bakes an npm-agent-tools wrapper targeting ~/.ai-tools/npm (preserves 'npm update -g' workflow)" \
  || fail "Dockerfile bakes an npm-agent-tools wrapper targeting ~/.ai-tools/npm (preserves 'npm update -g' workflow)"
grep -qE 'npm install -g --prefix "\$npm_prefix"' "$REPO_DIR/agent-tools-reconcile.sh" \
  && pass "reconcile passes --prefix explicitly per npm invocation (not via a baked .npmrc)" \
  || fail "reconcile passes --prefix explicitly per npm invocation (not via a baked .npmrc)"

# ── the CONSEQUENCE of having no prefix, which the docs have to carry ─────────
# The two assertions above keep the prefix out of the image. The price of that
# is paid by the user: with no prefix configured anywhere, `npm prefix -g`
# resolves to nvm's own root-owned node directory, so an agent CLI's built-in
# auto-updater fails there rather than in ~/.ai-tools/npm where it is actually
# installed. That is a design consequence and it is permanent — nvm inspects all
# four npmrc locations (builtin, global, user, project) plus $PREFIX and
# $NPM_CONFIG_PREFIX, so no configuration satisfies both it and the updater.
#
# It reached a user as an error with no explanation on 2026-08-22, because
# docs/agent-tools.md said the opposite: that each tool "can self-update in
# place using its own updater (e.g. the agent CLI's own /update or
# auto-updater, npm update -g …)". Both of those are wrong here, and the one
# command that works — the baked npm-agent-tools wrapper — appeared only in
# AGENTS.md. A guard on the Dockerfile alone cannot notice that: the image was
# correct and the documentation was not.
#
# $REPO_DIR is the ENGINE root in both repos (the mgd port sets it to base/),
# so this path resolves without either copy needing its own logic.
doc="$REPO_DIR/docs/agent-tools.md"
if [[ ! -f "$doc" ]]; then
  fail "docs/agent-tools.md exists to document the no-prefix consequence"
else
  # The wrapper by name: it is the only supported way to update the npm-based
  # CLIs, and a rewrite of that paragraph that drops it leaves the user with
  # nothing that works.
  if grep -Fq 'npm-agent-tools update -g' "$doc"; then
    pass "the docs name the npm-agent-tools wrapper the no-prefix design requires"
  else
    fail "the docs name the npm-agent-tools wrapper the no-prefix design requires"
  fi
  # And the SYMPTOM, verbatim, so the person reading the error can find the
  # page by searching for what their terminal actually said.
  if grep -Fq 'no write permission to npm prefix' "$doc"; then
    pass "the docs quote the error the built-in updater fails with"
  else
    fail "the docs quote the error the built-in updater fails with"
  fi
fi
grep -qF 'npm_prefix="$home_root/npm"' "$REPO_DIR/agent-tools-reconcile.sh" \
  && pass "reconcile's npm_prefix resolves to \$home_root/npm (~/.ai-tools/npm)" \
  || fail "reconcile's npm_prefix resolves to \$home_root/npm (~/.ai-tools/npm)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
