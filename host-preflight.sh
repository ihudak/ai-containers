# shellcheck shell=bash
# host-preflight.sh — refuse a checkout the scripts cannot run correctly from,
# and warn about one they run from badly. Sourced by build.sh, sandbox.sh,
# project-init.sh and sync-to-projects.sh, each calling
# `host_checkout_preflight "$script_dir"` itself; sourcing runs nothing.
#
# Both checks exist for Windows, where a checkout can look healthy and not be:
#
# CRLF — REFUSED. Git for Windows commonly defaults to core.autocrlf=true, and
#   an editor on the Windows side writes CRLF too. A script with CRLF dies on
#   `$'\r': command not found` partway through; an allowlist fragment with CRLF
#   is worse, because `example.com\r` resolves to nothing and the domain is
#   silently NOT allowed. The repo's .gitattributes pins LF for fresh clones;
#   this catches a checkout made before it, or a file edited afterwards. Only
#   files the engine executes or bakes are scanned — sandbox.conf and
#   sandbox*.env are parsed CR-tolerantly and are left alone.
#
# WSL /mnt/<drive> — WARNED. A checkout on the Windows filesystem works, but
#   bind mounts from there go through WSL's 9p bridge (slow), and the repo's
#   symlinks (CLAUDE.md, .github/copilot-instructions.md,
#   .kiro/steering/AGENTS.md) become WSL reparse points that Windows-side git
#   tools cannot read. Cloning inside WSL (e.g. ~/dev) avoids both.

# host_is_wsl — true under WSL. A function so tests can redefine it.
host_is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

# host_real_path <dir> — the symlink-free path, so a /mnt/c checkout reached
# through a ~/link is still recognised. A function so tests can redefine it.
host_real_path() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

# host_crlf_files <dir> — print, one per line and relative to <dir>, every
# engine file under <dir> that contains a carriage return.
host_crlf_files() {
  local dir="$1" f
  local -a files=()
  local restore; restore="$(shopt -p nullglob)"
  shopt -s nullglob
  files=("$dir"/*.sh "$dir"/Dockerfile* "$dir"/container.env
         "$dir"/tools.d/*.conf "$dir"/allowlist-*.d/*.txt)
  eval "$restore"
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q $'\r' "$f" 2>/dev/null; then printf '%s\n' "${f#"$dir"/}"; fi
  done
}

# host_checkout_preflight <dir> — returns 1 (after explaining) on CRLF, 0
# otherwise; prints a warning for a WSL /mnt/<drive> checkout.
host_checkout_preflight() {
  local dir="$1" real crlf f
  crlf="$(host_crlf_files "$dir")"
  if [[ -n "$crlf" ]]; then
    printf 'ERROR: these files have Windows (CRLF) line endings, which break them here:\n' >&2
    while IFS= read -r f; do printf '         %s\n' "$f" >&2; done <<<"$crlf"
    printf '       Usually a Windows-side git (core.autocrlf=true) or editor. Fix, in WSL:\n' >&2
    printf '         sed -i '"'"'s/\\r$//'"'"' <file>...\n' >&2
    printf '       or re-clone inside WSL (e.g. ~/dev), not under /mnt/c.\n' >&2
    return 1
  fi
  if host_is_wsl; then
    real="$(host_real_path "$dir")"
    if [[ "$real" =~ ^/mnt/[a-zA-Z]/ ]]; then
      printf 'WARNING: %s is on the Windows filesystem (%s).\n' "$dir" "${real:0:6}" >&2
      printf '         It works, but mounts from there are slow and its symlinks are unreadable\n' >&2
      printf '         to Windows-side git tools. Clone inside WSL instead (e.g. ~/dev).\n' >&2
    fi
  fi
  return 0
}
