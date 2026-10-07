#!/usr/bin/env bash
# link-node-globals.sh — runs as ROOT at BUILD time, once, after every Dockerfile
# layer that runs `npm install -g`. Puts each command those packages installed
# onto /usr/local/bin, beside the node/npm/npx links the nvm layer makes.
#
# `npm install -g` lands a package's commands in the DEFAULT node's own bin
# directory, and only nvm puts that directory on PATH: in an interactive shell,
# and only while the default node is the active one. `nvm use 20` swaps it for
# 20's directory, and a non-interactive `docker exec … bash -c` never has it, so
# yarn, pnpm, ng, qmd and bun were "command not found" in both.
#
# Two kinds of link:
#   - a symlink, by default. A node script (`#!/usr/bin/env node`) then runs
#     under whichever node is ACTIVE, which is what a package manager must do:
#     the native modules it builds for a project have to match the node that
#     project runs. A native binary (pnpm, bun) runs the same either way.
#   - a wrapper that runs the command under the DEFAULT node, for each package
#     named with --pin: a standalone tool that has nothing to do with the
#     project's modules and should keep the node it was installed and tested
#     with. qmd is one: it requires node 22 or later (its `engines`), and node
#     20.9 cannot even load it, since its command is an extensionless ES module.
#
# Every command a package other than node's own npm and corepack installed is
# linked, so a future `npm install -g` layer needs nothing here — only to run
# BEFORE this script, which tests/test-link-node-globals.sh checks.
#
# It fails the build rather than skip a command: a skipped one is exactly the
# defect this exists to fix, and a `|| true` hid it for bun until now.
#
# Usage: link-node-globals.sh [--pin <package>]...
# NODE_LINK and LINK_DIR replace /usr/local/bin/node (the nvm layer's link to the
# default node) and the destination; they exist for the hermetic test.
set -euo pipefail

log() { printf '[link-node-globals] %s\n' "$*"; }
die() { printf '[link-node-globals] ERROR: %s\n' "$*" >&2; exit 1; }

pins=()
while (( $# )); do
  case "$1" in
    --pin) [[ $# -ge 2 && -n "$2" ]] || die "--pin needs a package name"
           pins+=("$2"); shift 2 ;;
    *)     die "unknown argument: $1" ;;
  esac
done

link_dir="${LINK_DIR:-/usr/local/bin}"
node_link="${NODE_LINK:-/usr/local/bin/node}"
# The nvm layer links /usr/local/bin/node to the default node with one absolute
# link, so the default node's prefix is the directory above where it leads.
# cd and pwd -P, not readlink -f: the hermetic test also runs on macOS, whose
# readlink has no -f before 12.3.
node_real="$node_link"
if [[ -L "$node_link" ]]; then
  node_real="$(readlink "$node_link")"
  [[ "$node_real" == /* ]] || node_real="$(dirname "$node_link")/$node_real"
fi
prefix="$(cd "$(dirname "$node_real")/.." 2>/dev/null && pwd -P)" || die "$node_link does not resolve"
[[ -x "$prefix/bin/node" ]] || die "$node_link does not lead to a node prefix (got $prefix)"

is_pinned() {  # $1=package
  local p
  for p in ${pins[@]+"${pins[@]}"}; do [[ "$p" == "$1" ]] && return 0; done
  return 1
}

sq() {  # $1 → one single-quoted shell word
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# A destination this script may replace: a link to the same command, or a
# wrapper it wrote. Anything else there belongs to someone else.
ours() {  # $1=destination $2=npm's link for the command
  if [[ -L "$1" ]]; then
    [[ "$(readlink "$1")" == "$2" ]]
  else
    [[ -f "$1" ]] && [[ "$(sed -n 2p "$1")" == "# written by link-node-globals.sh" ]]
  fi
}

linked=() pinned=() pins_seen=()
for l in "$prefix"/bin/*; do
  [[ -L "$l" ]] || continue                      # node itself is a regular file
  name="${l##*/}"
  target="$(readlink "$l")"
  # npm links every global command as ../lib/node_modules/<package>/<path>.
  rel="${target#../lib/node_modules/}"
  path="$rel"
  [[ "$rel" == @* ]] && path="${rel#*/}"         # a scoped name is two components
  [[ "$rel" != "$target" && "$path" == ?*/?* ]] \
    || die "$l -> $target is not a link npm makes; cannot tell which package owns $name"
  pkg="${rel%"/${path#*/}"}"
  case "$pkg" in npm|corepack) continue ;; esac   # node's own; the nvm layer links npm/npx

  dest="$link_dir/$name"
  if [[ -e "$dest" || -L "$dest" ]] && ! ours "$dest" "$l"; then
    die "$dest already exists and is not this script's; refusing to replace it with $pkg's $name"
  fi

  if is_pinned "$pkg"; then
    script_dir="$(cd "$prefix/bin/${target%/*}" 2>/dev/null && pwd -P)" \
      || die "$l -> $target does not resolve"
    script="$script_dir/${target##*/}"
    [[ -f "$script" ]] || die "$l -> $target does not resolve"
    [[ "$(head -n 1 "$script")" == '#!'*node* ]] \
      || die "--pin $pkg: $name is not a node script, so there is no node to pin it to"
    rm -f "$dest"
    {
      printf '#!/bin/sh\n'
      printf '# written by link-node-globals.sh\n'
      printf '# %s was installed with this node at image build time; run it there whatever nvm selects.\n' "$pkg"
      printf 'exec %s %s "$@"\n' "$(sq "$prefix/bin/node")" "$(sq "$script")"
    } > "$dest"
    chmod 755 "$dest"
    pinned+=("$name") pins_seen+=("$pkg")
  else
    ln -sfn "$l" "$dest"
    linked+=("$name")
  fi
done

for p in ${pins[@]+"${pins[@]}"}; do
  [[ -f "$prefix/lib/node_modules/$p/package.json" ]] || continue   # not installed in this image
  seen=0
  for s in ${pins_seen[@]+"${pins_seen[@]}"}; do [[ "$s" == "$p" ]] && seen=1; done
  (( seen )) || die "--pin $p: it is installed but put no command in $prefix/bin"
done

log "default node: $prefix"
log "linked into $link_dir: ${linked[*]:-none}"
log "pinned to the default node: ${pinned[*]:-none}"
