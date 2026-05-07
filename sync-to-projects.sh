#!/usr/bin/env bash
# sync-to-projects.sh — push shared ai-containers files to all registered projects.
#
# Usage:
#   ./sync-to-projects.sh          # sync all projects in projects.conf
#   ./sync-to-projects.sh <path>   # sync a single project (not required to be registered)
#
# What is synced (shared infrastructure):
#   Dockerfile, .dockerignore, *.sh scripts,
#   allowlist-*.d/ component fragments and base.txt (custom.txt is never touched).
#
# What is NOT synced (project-specific):
#   sandbox.conf, allowlist-*.d/custom.txt, <project>-container.sh, projects.conf
#
# sandbox.conf diff warning:
#   If sandbox.conf in a project differs from the one in this repo, a warning is
#   printed so you can review and merge new options manually.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
projects_conf="${script_dir}/projects.conf"

# ── Helpers ────────────────────────────────────────────────────────────────────

sync_project() {
  local project_path="$1"
  local dest="${project_path}/.ai-containers"

  if [[ ! -d "$project_path" ]]; then
    printf '  SKIP  %s — directory not found\n' "$project_path"
    return
  fi

  if [[ ! -d "$dest" ]]; then
    printf '  SKIP  %s — .ai-containers not found (run project-init.sh first)\n' "$project_path"
    return
  fi

  printf 'Syncing → %s\n' "$dest"

  # Allowlist fragment directories (exclude custom.txt)
  rsync -a --exclude='custom.txt' \
    "${script_dir}/allowlist-domains.d/"       "${dest}/allowlist-domains.d/"
  rsync -a --exclude='custom.txt' \
    "${script_dir}/allowlist-proxy-domains.d/" "${dest}/allowlist-proxy-domains.d/"
  rsync -a --exclude='custom.txt' \
    "${script_dir}/allowlist-cidrs.d/"         "${dest}/allowlist-cidrs.d/"

  # Shared scripts and build files
  for f in Dockerfile .dockerignore runme.sh entrypoint.sh \
            refresh-ipset-allowlist.sh capture-blocked-traffic.sh \
            capture-agent-destinations.sh install-dt-tools.sh; do
    if [[ -f "${script_dir}/${f}" ]]; then
      cp "${script_dir}/${f}" "${dest}/${f}"
    fi
  done

  # sandbox.conf diff warning — never overwrite, just inform
  if [[ -f "${dest}/sandbox.conf" ]]; then
    if ! diff -q "${script_dir}/sandbox.conf" "${dest}/sandbox.conf" > /dev/null 2>&1; then
      printf '  WARN  sandbox.conf differs from upstream. New options may be available.\n'
      printf '        Review with: diff %s/sandbox.conf %s/sandbox.conf\n' \
        "$script_dir" "$dest"
    fi
  fi

  printf '  OK\n'
}

# ── Main ───────────────────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
  # Single project passed on the command line
  project_path="$(cd "$1" 2>/dev/null && pwd)" || {
    printf 'ERROR: path does not exist: %s\n' "$1" >&2
    exit 1
  }
  sync_project "$project_path"
  exit 0
fi

# Sync all registered projects
if [[ ! -f "$projects_conf" ]]; then
  printf 'ERROR: projects.conf not found. Run project-init.sh to register a project,\n' >&2
  printf '       or copy projects.conf.example to projects.conf and edit it.\n' >&2
  exit 1
fi

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines and comments
  [[ -z "$line" || "$line" == \#* ]] && continue
  sync_project "$line"
  (( count++ )) || true
done < "$projects_conf"

if [[ $count -eq 0 ]]; then
  printf 'No projects registered in projects.conf.\n'
  printf 'Run ./project-init.sh <project-path> to register one.\n'
fi
