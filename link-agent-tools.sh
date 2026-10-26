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
  "mkdocs:mkdocs:$home_root/uv/bin/mkdocs"
)

# Exact-member test against the comma list: `codex` must not match `codex-foo`.
enabled() { [[ ",${AI_RUNTIME_TOOLS:-}," == *",$1,"* ]]; }

# A node script linked as is runs under the ACTIVE node, so `nvm use 20` in a
# project with node=20 left copilot on a node it does not support (bugs review
# RT-6). Each npm-installed command that is a node script gets a wrapper running
# it with the image's DEFAULT node, as link-node-globals.sh --pin does for qmd;
# PATH is left alone, so the commands the agent runs keep the project's node.
# NODE_LINK replaces /usr/local/bin/node (the nvm layer's link to the default
# node) for the hermetic test.
marker="# written by link-agent-tools.sh"
default_node=""
node_link="${NODE_LINK:-/usr/local/bin/node}"
if [[ -L "$node_link" ]]; then
  default_node="$(readlink "$node_link")"
  [[ "$default_node" == /* ]] || default_node="$(dirname "$node_link")/$default_node"
  [[ -x "$default_node" ]] || default_node=""
fi
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
# node_script <npm bin entry>: the script it leads to, if that is a node script.
node_script() {
  local l="$1" t dir
  [[ -L "$l" ]] || return 1
  t="$(readlink "$l")"; [[ "$t" == /* ]] || t="$(dirname "$l")/$t"
  dir="$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)" || return 1
  # Root reads a file of the group-shared tool home: only its first 256 bytes, under
  # a timeout, so a huge file with no newline or a FIFO swapped in cannot stall the
  # start (review of batch 3, finding 3).
  local head1
  [[ -f "$dir/${t##*/}" ]] || return 1
  head1="$(timeout -k 1 5 head -c 256 "$dir/${t##*/}" 2>/dev/null)"; head1="${head1%%$'\n'*}"
  [[ "$head1" == '#!'*node* ]] || return 1
  printf '%s' "$dir/${t##*/}"
}
ours() { [[ -L "$1" ]] || { [[ -f "$1" ]] && [[ "$(sed -n 2p "$1")" == "$marker" ]]; }; }

linked=""
for entry in "${srcs[@]}"; do
  key="${entry%%:*}"; rest="${entry#*:}"
  name="${rest%%:*}"; path="${rest#*:}"
  if ! enabled "$key"; then
    # A restarted container keeps /usr/local/bin; drop a link or wrapper an earlier start made.
    ours "$bin_dest/$name" && rm -f "$bin_dest/$name"
    continue
  fi
  if [[ -x "$path" ]]; then
    script=""
    [[ -n "$default_node" && "$path" == "$home_root/npm/bin/"* ]] && script="$(node_script "$path")"
    if [[ -n "$script" ]]; then
      rm -f "$bin_dest/$name"
      {
        printf '#!/bin/sh\n%s\n' "$marker"
        printf '# %s runs under the default node whatever nvm selects.\n' "$name"
        printf 'exec %s %s "$@"\n' "$(sq "$default_node")" "$(sq "$script")"
      } > "$bin_dest/$name"
      chmod 755 "$bin_dest/$name"
    else
      ln -sfn "$path" "$bin_dest/$name"
    fi
    linked="${linked:+$linked }$name"
  fi
done
[[ -n "${AI_RUNTIME_TOOLS:-}" ]] && log "linked agent tools into $bin_dest: ${linked:-none}"
exit 0
