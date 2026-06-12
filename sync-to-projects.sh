#!/usr/bin/env bash
# sync-to-projects.sh — push shared ai-containers files to all registered projects.
#
# Usage:
#   ./sync-to-projects.sh          # sync all projects in projects.conf
#   ./sync-to-projects.sh <path>   # sync a single project (not required to be registered)
#
# What is synced (shared infrastructure):
#   Dockerfile, Dockerfile.seed, .dockerignore, *.sh scripts,
#   allowlist-*.d/ component fragments and base.txt (custom.txt is never touched).
#
# What is NOT synced (project-specific):
#   sandbox.conf, sandbox.env, allowlist-*.d/custom.txt, <project>-container.sh, projects.conf
#   (sandbox.env is created/backfilled if missing, but never overwritten.)
#
# sandbox.conf diff warning:
#   If sandbox.conf in a project differs from the one in this repo, a warning is
#   printed so you can review and merge new options manually.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
projects_conf="${script_dir}/projects.conf"

# ── Helpers ────────────────────────────────────────────────────────────────────

# Backfill sandbox.env (persisted IMAGE_NAME) for projects initialised before
# sandbox.env existed. Never overwrites an existing file. The image name is read
# from the project's generated launcher (export IMAGE_NAME=...).
backfill_sandbox_env() {
  local dest="$1"
  [[ -f "${dest}/sandbox.env" ]] && return 0

  local img=""
  # Find a launcher's literal IMAGE_NAME. We scan all *.sh (launcher names are
  # not always "<name>-container.sh") and keep the first `export IMAGE_NAME=`
  # whose value is a literal — skipping templates like the `${project_name}-...`
  # line in a copied project-init.sh.
  while IFS= read -r val; do
    [[ -z "$val" || "$val" == *'$'* ]] && continue
    img="$val"; break
  done < <(grep -hE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "$dest"/*.sh 2>/dev/null \
            | sed -E 's/^[^=]*=//; s/^["'\'']//; s/["'\'']$//')

  if [[ -z "$img" ]]; then
    printf '  WARN  could not determine IMAGE_NAME — sandbox.env not written.\n'
    printf '        Create %s/sandbox.env manually with: IMAGE_NAME=<your-image>\n' "$dest"
    return 0
  fi

  cat > "${dest}/sandbox.env" <<EOF
# sandbox.env — persisted environment for this project's AI sandbox.
# Read by sandbox-common.sh so build.sh / runme.sh / repo.sh agree on the image
# name (hence the repo-volume names) even when run outside the launcher. An
# exported IMAGE_NAME (e.g. from the generated launcher) takes precedence.
# Not overwritten by sync-to-projects.sh.
IMAGE_NAME=${img}
EOF
  printf '  Wrote sandbox.env (IMAGE_NAME=%s).\n' "$img"
}

# Ensure the project's root .gitignore ignores its .ai-containers/ working copy.
# The per-project .ai-containers/ is a synced copy of the central repo and the
# launcher embeds machine-specific absolute paths (EXTRA_MOUNTS), so it should
# not be committed to the project. Idempotent, git-repos only; to keep it under
# version control instead, remove the added line. AI_CONTAINERS_NO_GITIGNORE=1
# skips this entirely.
ensure_ai_containers_ignored() {
  local project_path="$1"
  [[ "${AI_CONTAINERS_NO_GITIGNORE:-0}" == "1" ]] && return 0
  git -C "$project_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$project_path" check-ignore -q .ai-containers 2>/dev/null && return 0
  local gi="${project_path}/.gitignore"
  if [[ -f "$gi" && -s "$gi" && -n "$(tail -c1 "$gi" 2>/dev/null)" ]]; then
    printf '\n' >> "$gi"
  fi
  {
    printf '# AI sandbox tooling — local working copy synced from the central ai-containers repo\n'
    printf '# (the launcher embeds machine-specific paths). Remove this line to version it instead.\n'
    printf '/.ai-containers/\n'
  } >> "$gi"
  printf '  Added /.ai-containers/ to %s/.gitignore\n' "$(basename "$project_path")"
}

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
  for f in Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh runme.sh repo.sh entrypoint.sh \
            refresh-ipset-allowlist.sh capture-blocked-traffic.sh \
            capture-agent-destinations.sh install-dt-tools.sh README.md; do
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

  # sandbox.env — never overwritten; backfilled from the launcher if missing.
  backfill_sandbox_env "$dest"

  # Keep the project's .ai-containers/ working copy out of the project's repo.
  ensure_ai_containers_ignored "$project_path"

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
