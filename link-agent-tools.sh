#!/usr/bin/env bash
# link-agent-tools.sh — runs as ROOT at container start, AFTER agent-tools-reconcile.sh
# installs the enabled tools into the group-mounted ~/.ai-tools home. Symlinks each
# installed tool's executable onto the global PATH (/usr/local/bin) so NON-interactive,
# NON-login shells resolve them without sourcing profile.d — e.g. `docker exec -T <ctr>
# bash -c "claude …"`. Login/interactive shells already get them via /etc/profile.d/ai-tools.sh.
# No `set -u` (parity with link-default-ruby.sh; tolerate unset envs).
set -o pipefail

[[ -n "${AI_RUNTIME_TOOLS:-}" ]] || exit 0   # nothing enabled → nothing to expose

dev_home="${1:-$HOME}"
bin_dest="${2:-/usr/local/bin}"   # override only for testing; entrypoint uses the default
home_root="$dev_home/.ai-tools"

log(){ printf '[link-agent-tools] %s\n' "$*"; }

# tool binary → its location under the group home (npm prefix, uv bin, or plain bin).
srcs=(
  "claude:$home_root/npm/bin/claude"
  "copilot:$home_root/npm/bin/copilot"
  "codex:$home_root/npm/bin/codex"
  "gemini:$home_root/npm/bin/gemini"
  "graphify:$home_root/uv/bin/graphify"
  "vale:$home_root/bin/vale"
)

linked=""
for entry in "${srcs[@]}"; do
  name="${entry%%:*}"; path="${entry#*:}"
  if [[ -x "$path" ]]; then
    ln -sf "$path" "$bin_dest/$name"
    linked="${linked:+$linked }$name"
  fi
done
log "linked agent tools into $bin_dest: ${linked:-none}"
