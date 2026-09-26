#!/usr/bin/env bash
# link-agent-tools.sh — runs as ROOT at container start, AFTER agent-tools-reconcile.sh
# installs the enabled tools into the group-mounted ~/.ai-tools home. Symlinks each
# installed tool's executable onto the global PATH (/usr/local/bin) so NON-interactive,
# NON-login shells resolve them without sourcing profile.d — e.g. `docker exec -T <ctr>
# bash -c "claude …"` — and, since the tool home's own bin dirs are deliberately NOT on
# PATH (see the Dockerfile's /etc/profile.d/ai-tools.sh), login/interactive shells too.
#
# ONLY TOOLS THIS PROJECT ENABLED ARE LINKED, not every binary present. ~/.ai-tools is
# shared by every project in the group, so a tool another project turned ON is sitting
# in it: linking by presence alone handed `copilot` to a project whose sandbox.conf says
# copilot=OFF — and without its ~/.copilot mount or allowlist fragment, both of which
# sandbox.sh/build.sh gate on the key. AI_RUNTIME_TOOLS is the project's enabled set.
# No `set -u` (parity with link-default-ruby.sh; tolerate unset envs).
set -o pipefail

dev_home="${1:-$HOME}"
bin_dest="${2:-/usr/local/bin}"   # override only for testing; entrypoint uses the default
home_root="$dev_home/.ai-tools"

log(){ printf '[link-agent-tools] %s\n' "$*"; }

# Claude Code is installed NATIVELY (see agent-tools-reconcile.sh), so its launcher is
# ~/.local/bin/claude, not a binary under the npm prefix. Prefer that, and fall back to a
# leftover npm copy so a group provisioned before that change keeps resolving `claude` in
# non-login shells until the npm copy is cleared. Order matters: the native install is the
# one that can self-update, so it must win whenever both are present.
claude_src="$dev_home/.local/bin/claude"
[[ -x "$claude_src" ]] || claude_src="$home_root/npm/bin/claude"

# sandbox.conf key → tool binary → its location under the group home (npm prefix, uv
# bin, or plain bin).
srcs=(
  "claude-code:claude:$claude_src"
  "copilot:copilot:$home_root/npm/bin/copilot"
  "codex:codex:$home_root/npm/bin/codex"
  "gemini:gemini:$home_root/npm/bin/gemini"
  "graphify:graphify:$home_root/uv/bin/graphify"
  "vale:vale:$home_root/bin/vale"
)

# Exact-member test against the comma list: `codex` must not match `codex-foo`.
enabled() { [[ ",${AI_RUNTIME_TOOLS:-}," == *",$1,"* ]]; }

linked=""
for entry in "${srcs[@]}"; do
  key="${entry%%:*}"; rest="${entry#*:}"
  name="${rest%%:*}"; path="${rest#*:}"
  if ! enabled "$key"; then
    # A restarted container keeps /usr/local/bin; drop a link an earlier start made.
    [[ -L "$bin_dest/$name" ]] && rm -f "$bin_dest/$name"
    continue
  fi
  if [[ -x "$path" ]]; then
    ln -sf "$path" "$bin_dest/$name"
    linked="${linked:+$linked }$name"
  fi
done
[[ -n "${AI_RUNTIME_TOOLS:-}" ]] && log "linked agent tools into $bin_dest: ${linked:-none}"
exit 0
