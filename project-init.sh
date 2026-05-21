#!/usr/bin/env bash
# project-init.sh — initialise a project to use ai-containers.
#
# Usage:
#   ./project-init.sh <project-path> [project-name]
#
#   project-path   Absolute or relative path to the project root.
#   project-name   Optional. Defaults to the basename of project-path.
#                  Used as the Docker image name and the prefix of the
#                  generated launch script (<project-name>-container.sh).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
projects_conf="${script_dir}/projects.conf"

# ── Args ───────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s <project-path> [project-name]\n' "$(basename "$0")" >&2
  exit 1
fi

project_path="$(cd "$1" 2>/dev/null && pwd)" || {
  printf 'ERROR: project path does not exist: %s\n' "$1" >&2
  exit 1
}

project_name="${2:-$(basename "$project_path")}"

dest="${project_path}/.ai-containers"
launch_script="${dest}/${project_name}-container.sh"

# ── Copy shared files ──────────────────────────────────────────────────────────

printf 'Initialising %s → %s\n' "$project_name" "$dest"
mkdir -p "$dest"

# Shared infrastructure files
rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-domains.d/"    "${dest}/allowlist-domains.d/"
rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-proxy-domains.d/" "${dest}/allowlist-proxy-domains.d/"
rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-cidrs.d/"     "${dest}/allowlist-cidrs.d/"

for f in Dockerfile .dockerignore runme.sh entrypoint.sh \
          refresh-ipset-allowlist.sh capture-blocked-traffic.sh \
          capture-agent-destinations.sh install-dt-tools.sh; do
  [[ -f "${script_dir}/${f}" ]] && cp "${script_dir}/${f}" "${dest}/${f}"
done

# sandbox.conf — copy only if not already present
if [[ ! -f "${dest}/sandbox.conf" ]]; then
  cp "${script_dir}/sandbox.conf" "${dest}/sandbox.conf"
  printf '  Copied sandbox.conf — edit it to choose components before building.\n'
else
  printf '  sandbox.conf already exists — skipping (not overwritten).\n'
fi

# Ensure custom.txt files exist (copy from .example if needed)
for dir in allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d; do
  custom="${dest}/${dir}/custom.txt"
  example="${dest}/${dir}/custom.txt.example"
  if [[ ! -f "$custom" && -f "$example" ]]; then
    cp "$example" "$custom"
    printf '  Created %s/%s/custom.txt from template.\n' "$(basename "$dest")" "$dir"
  fi
done

# ── Generate launch script ─────────────────────────────────────────────────────

if [[ -f "$launch_script" ]]; then
  printf '  %s already exists — skipping.\n' "$(basename "$launch_script")"
else
  cat > "$launch_script" <<EOF
#!/usr/bin/env bash
# ${project_name}-container.sh — launch the AI sandbox for ${project_name}.
# Edit the variables below, then run this script.
set -euo pipefail

cd "\$(dirname "\${BASH_SOURCE[0]}")"

export IMAGE_NAME="${project_name}-ai-container"

# Container group: selects which dotfile tree under ~/.ai-containers/ to mount.
# Uncomment to use a project-specific group (isolated auth state, skills, MCP config).
# Special values: 'default' (the implicit default), 'host' (mount \$HOME directly).
# On first use of a new group, runme.sh prompts for how to initialize it (or
# set AI_CONTAINER_GROUP_INIT=clean|from:host|from:<group> to skip the prompt).
#export AI_CONTAINER_GROUP="${project_name}"

# Uncomment and set to mount additional repositories inside the container.
# Paths with spaces are not supported. Append :ro for read-only.
#export EXTRA_MOUNTS=""

# Uncomment to publish dev-server ports to the host (e.g. for Claude Code previews).
#export PREVIEW_PORTS="3000 5173"

# ── Commands ──────────────────────────────────────────────────────────────────
# Build the image (run after editing sandbox.conf or updating shared files):
# ./runme.sh build

# Run in restricted mode (firewall enabled):
./runme.sh restricted ..

# Run in discovery mode (unrestricted egress, captures destinations):
# ./runme.sh discovery ..
EOF
  chmod +x "$launch_script"
  printf '  Created %s\n' "$(basename "$launch_script")"
fi

# ── Register project ───────────────────────────────────────────────────────────

# Bootstrap projects.conf from the example if it does not exist yet
if [[ ! -f "$projects_conf" ]]; then
  cp "${script_dir}/projects.conf.example" "$projects_conf"
  printf '  Created projects.conf from template.\n'
fi

if grep -qxF "$project_path" "$projects_conf" 2>/dev/null; then
  printf '  %s already registered in projects.conf.\n' "$project_path"
else
  printf '%s\n' "$project_path" >> "$projects_conf"
  printf '  Registered %s in projects.conf.\n' "$project_path"
fi

printf '\nDone. Next steps:\n'
printf '  1. Edit %s to choose components.\n' "${dest}/sandbox.conf"
printf '  2. Edit %s to review mounts and settings.\n' "$(basename "$launch_script")"
printf '  3. Run: cd %s && ./runme.sh build\n' "$dest"
printf '  4. Run: %s\n' "$launch_script"
