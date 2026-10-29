#!/usr/bin/env bash
# Drives link-agent-tools.sh against a FAKE ~/.ai-tools tree + a throwaway dest dir.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/link-agent-tools.sh" && pass "link-agent-tools.sh bash -n" || fail "link-agent-tools.sh bash -n"

# mk_tool HOME rel/path/binary → creates an executable stub at $HOME/.ai-tools/<rel>.
mk_tool() { install -d "$1/.ai-tools/$(dirname "$2")"; printf '#!/bin/sh\n' > "$1/.ai-tools/$2"; chmod +x "$1/.ai-tools/$2"; }

# ── Links every present tool binary into dest ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" npm/bin/claude; mk_tool "$h" npm/bin/copilot; mk_tool "$h" npm/bin/codex
mk_tool "$h" npm/bin/gemini; mk_tool "$h" uv/bin/graphify; mk_tool "$h" bin/vale
AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
ok=1
[[ -L "$d/claude"   && "$(readlink "$d/claude")"   == "$h/.ai-tools/npm/bin/claude" ]]   || ok=0
[[ -L "$d/graphify" && "$(readlink "$d/graphify")" == "$h/.ai-tools/uv/bin/graphify" ]]   || ok=0
[[ -L "$d/vale"     && "$(readlink "$d/vale")"     == "$h/.ai-tools/bin/vale" ]]          || ok=0
[[ "$ok" == 1 ]] && pass "links all present tools (npm/uv/bin sources)" || fail "links all present tools"
rm -rf "$h" "$d"

# ── mkdocs is a uv tool like graphify, linked only when enabled ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" uv/bin/mkdocs
AI_RUNTIME_TOOLS="mkdocs" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/mkdocs" && "$(readlink "$d/mkdocs")" == "$h/.ai-tools/uv/bin/mkdocs" ]] && pass "links mkdocs from uv/bin" || fail "links mkdocs from uv/bin"
AI_RUNTIME_TOOLS="vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ ! -e "$d/mkdocs" && ! -L "$d/mkdocs" ]] && pass "mkdocs link dropped once mkdocs is not enabled" || fail "mkdocs link dropped once mkdocs is not enabled"
rm -rf "$h" "$d"

# ── Only links what exists (missing gemini is skipped, no dangling link) ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; mk_tool "$h" npm/bin/claude
AI_RUNTIME_TOOLS="claude-code,gemini" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/claude" && ! -L "$d/gemini" ]] && pass "only links existing binaries (no dangling)" || fail "only links existing binaries"
rm -rf "$h" "$d"

# ── Empty tool home → clean no-op ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
AI_RUNTIME_TOOLS="claude-code,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$d")" ]] && pass "empty tool home → exit 0, dest empty" || fail "empty tool home → exit 0, dest empty"
rm -rf "$h" "$d"

# ── No AI_RUNTIME_TOOLS → no-op ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; mk_tool "$h" npm/bin/claude
( unset AI_RUNTIME_TOOLS; bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" ) >/dev/null 2>&1
[[ -z "$(ls -A "$d")" ]] && pass "no AI_RUNTIME_TOOLS is a no-op" || fail "no AI_RUNTIME_TOOLS is a no-op"
rm -rf "$h" "$d"

# ── Present but NOT enabled → not linked. The tool home is group-shared: a sibling
# project with copilot=ON leaves copilot in it, and this project said copilot=OFF. ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" npm/bin/claude; mk_tool "$h" npm/bin/copilot; mk_tool "$h" npm/bin/codex
AI_RUNTIME_TOOLS="claude-code,codex" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/claude" && -L "$d/codex" && ! -e "$d/copilot" && ! -L "$d/copilot" ]] \
  && pass "present-but-disabled tool is not linked" || fail "present-but-disabled tool is not linked"
rm -rf "$h" "$d"

# ── A link an earlier start made for a now-disabled tool is removed ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" npm/bin/claude; mk_tool "$h" npm/bin/copilot
ln -s "$h/.ai-tools/npm/bin/copilot" "$d/copilot"
AI_RUNTIME_TOOLS="claude-code" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/claude" && ! -L "$d/copilot" ]] && pass "stale link for a disabled tool is removed" || fail "stale link for a disabled tool is removed"
rm -rf "$h" "$d"

# ── The key is matched exactly, not as a substring of another entry ──
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" npm/bin/codex
AI_RUNTIME_TOOLS="codex-x" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ ! -L "$d/codex" ]] && pass "enabled-key match is exact" || fail "enabled-key match is exact"
rm -rf "$h" "$d"

# ── The baked PATH must not expose the shared tool home's bin dirs; /usr/local/bin
# (populated above, per project) is the only route. ──
path_line="$(grep -E "'export PATH=" "$REPO_DIR/Dockerfile" | grep -F 'ai-tools' || true)"
[[ -z "$path_line" ]] && pass "Dockerfile does not put ~/.ai-tools bin dirs on PATH" \
  || fail "Dockerfile puts ~/.ai-tools bin dirs on PATH: $path_line"

# ── RT-6: an npm agent CLI runs under the image's default node, whatever nvm selects ──
# A node script linked as is runs under the ACTIVE node: `nvm use 20` in a
# project with node=20 left copilot on a node it does not support (bugs review
# RT-6). Like qmd (link-node-globals.sh --pin), each one gets a wrapper that
# runs it with the default node; PATH is left alone, so the commands the agent
# runs keep the node the project selected.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
n="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
install -d "$n/v22/bin"; printf '#!/bin/sh\necho "node=$0 script=$1 rest=$2"\n' > "$n/v22/bin/node"; chmod +x "$n/v22/bin/node"
ln -s "$n/v22/bin/node" "$n/node"
pkg="$h/.ai-tools/npm/lib/node_modules/@github/copilot"; install -d "$pkg" "$h/.ai-tools/npm/bin"
printf '#!/usr/bin/env node\n' > "$pkg/index.js"; chmod +x "$pkg/index.js"
ln -s ../lib/node_modules/@github/copilot/index.js "$h/.ai-tools/npm/bin/copilot"
mk_tool "$h" npm/bin/codex   # not a node script: a plain link, as before
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot,codex" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
out="$("$d/copilot" hi 2>&1)"
real_pkg="$(cd "$pkg" && pwd -P)"
[[ ! -L "$d/copilot" && "$out" == "node=$n/v22/bin/node script=$real_pkg/index.js rest=hi" ]] \
  && pass "an npm node-script CLI runs under the default node" \
  || fail "copilot does not run under the default node (got: $out; link: $(readlink "$d/copilot"))"
[[ -L "$d/codex" ]] && pass "  … a CLI that is not a node script stays a plain link" || fail "  … codex is no longer a link"
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="codex" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ ! -e "$d/copilot" ]] && pass "  … and its wrapper is dropped once it is not enabled" || fail "  … the copilot wrapper survived disabling"
rm -rf "$h" "$d" "$n"

# ── RT-9: node_script reads only the first 256 bytes, and never a FIFO ──
# Root reads a file of the group-shared tool home, which the agent can write.
# A shebang whose `node` lies past byte 256 is not seen as a node script (the
# read is bounded), and a FIFO where the script should be is not opened at all,
# so the link step neither hangs nor wraps it.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
n="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
install -d "$n/v22/bin"; printf '#!/bin/sh\n' > "$n/v22/bin/node"; chmod +x "$n/v22/bin/node"; ln -s "$n/v22/bin/node" "$n/node"
pkg="$h/.ai-tools/npm/lib/node_modules/@github/copilot"; install -d "$pkg" "$h/.ai-tools/npm/bin"
{ printf '#!/usr/bin/env '; printf '%300s' ''; printf 'node\n'; } > "$pkg/index.js"; chmod +x "$pkg/index.js"
ln -s ../lib/node_modules/@github/copilot/index.js "$h/.ai-tools/npm/bin/copilot"
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/copilot" ]] && pass "RT-9 a shebang whose node lies past byte 256 is not read as a node script" \
  || fail "RT-9 node_script read past its 256-byte bound (copilot was wrapped)"
# Executable, so the link step's own -x test does not skip it before node_script
# runs; under p_timeout, because macOS has no timeout(1) for node_script's own.
rm -f "$pkg/index.js" "$d/copilot"; mkfifo -m 755 "$pkg/index.js"
t9=$SECONDS
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" p_timeout 30 bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1; rc=$?
t9=$((SECONDS - t9))
[[ "$rc" != 124 && "$t9" -lt 3 && ! -f "$d/copilot" ]] && pass "RT-9 a FIFO where the script should be is not opened (${t9}s)" \
  || fail "RT-9 a FIFO in the tool home held the link step (rc $rc, ${t9}s)"
rm -rf "$h" "$d" "$n"

TMP_LINKDIR="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; rmdir "$TMP_LINKDIR"
# ── RT-9: a NUL in the shebang ends it, as it does for the kernel ──
# Stripping NULs made `#!\0/usr/bin/node` read as `#!/usr/bin/node`, a node
# script, and wrapped it.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
n="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
install -d "$n/v22/bin"; printf '#!/bin/sh\n' > "$n/v22/bin/node"; chmod +x "$n/v22/bin/node"; ln -s "$n/v22/bin/node" "$n/node"
pkg="$h/.ai-tools/npm/lib/node_modules/@github/copilot"; install -d "$pkg" "$h/.ai-tools/npm/bin"
printf '#!\000/usr/bin/env node\n' > "$pkg/index.js"; chmod +x "$pkg/index.js"
ln -s ../lib/node_modules/@github/copilot/index.js "$h/.ai-tools/npm/bin/copilot"
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/copilot" ]] && pass "RT-9 a shebang with a NUL after #! is not read as a node script" \
  || fail "RT-9 a NUL in the shebang was stripped (copilot was wrapped)"
rm -rf "$h" "$d" "$n"

# ── RT-9: a real directory at the destination is never linked into ──
# `ln -sfn` onto a real directory makes the link INSIDE it, and a wrapper would
# be written into it; BSD ln has no -T, so the script checks. The other tools
# still link.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
mk_tool "$h" npm/bin/claude; mk_tool "$h" bin/vale
mkdir -p "$d/claude"
out="$(AI_RUNTIME_TOOLS="claude-code,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" 2>&1)"; rc=$?
[[ "$rc" == 0 && -d "$d/claude" && ! -L "$d/claude" && -z "$(ls -A "$d/claude")" && -L "$d/vale" && "$out" == *"is a directory"* ]] \
  && pass "RT-9 a directory at a tool's destination is left alone, with a warning, and the others link" \
  || fail "RT-9 a directory at the destination (rc $rc; inside: $(ls -A "$d/claude" 2>&1); out: $out)"
rm -rf "$h" "$d"
# The same for a tool that gets a WRAPPER (a node script): its `rm -f` and
# redirect would fail on a directory and then chmod it 755. And a LINK to a
# directory standing there is replaced, not entered.
h="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; d="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
n="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
install -d "$n/v22/bin"; printf '#!/bin/sh\n' > "$n/v22/bin/node"; chmod +x "$n/v22/bin/node"; ln -s "$n/v22/bin/node" "$n/node"
pkg="$h/.ai-tools/npm/lib/node_modules/@github/copilot"; install -d "$pkg" "$h/.ai-tools/npm/bin"
printf '#!/usr/bin/env node\n' > "$pkg/index.js"; chmod +x "$pkg/index.js"
ln -s ../lib/node_modules/@github/copilot/index.js "$h/.ai-tools/npm/bin/copilot"
mkdir -m 700 "$d/copilot"
out="$(NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" 2>&1)"
[[ -d "$d/copilot" && -z "$(ls -A "$d/copilot")" && "$(p_stat_mode "$d/copilot")" == 700 && "$out" == *"is a directory"* ]] \
  && pass "RT-9 a directory where a wrapper goes is left alone, its mode untouched" \
  || fail "RT-9 a directory where a wrapper goes (mode $(p_stat_mode "$d/copilot"); inside: $(ls -A "$d/copilot" 2>&1); $out)"
rmdir "$d/copilot"; mkdir -p "$TMP_LINKDIR"; ln -s "$TMP_LINKDIR" "$d/copilot"
NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -f "$d/copilot" && ! -L "$d/copilot" && -z "$(ls -A "$TMP_LINKDIR")" ]] \
  && pass "RT-9 a link to a directory where a wrapper goes is replaced, not entered" \
  || fail "RT-9 a link to a directory at the destination (dest: $(ls -la "$d/copilot" 2>&1); target holds: $(ls -A "$TMP_LINKDIR"))"
# A restarted container finds its own wrapper there, a regular file: it is
# rewritten, not refused as if it were in the way. A different default node this
# time, so a wrapper left as it was would still name the old one.
install -d "$n/v24/bin"; printf '#!/bin/sh\n' > "$n/v24/bin/node"; chmod +x "$n/v24/bin/node"; ln -sfn "$n/v24/bin/node" "$n/node"
out="$(NODE_LINK="$n/node" AI_RUNTIME_TOOLS="copilot" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$out" != *"is a directory"* ]] && grep -qF "$(cd "$n/v24/bin" && pwd -P)/node" "$d/copilot" \
  && pass "  … and a second start rewrites its own wrapper" || fail "  … a second start and its own wrapper (rc $rc; $out; $(cat "$d/copilot"))"
rm -rf "$h" "$d" "$n" "$TMP_LINKDIR"

# ── Guards ──
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/link-agent-tools.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
