#!/usr/bin/env bash
# project-init.sh — interactively configure a project to use ai-containers.
#
# Prompts for image name, project location, container group (with optional
# from-which-group bootstrap), CPU/memory limits, and extra mounts. Then
# copies the shared .ai-containers infrastructure into the project, registers
# it in projects.conf, and writes a ready-to-run <project-name>-container.sh
# launcher modelled on ihudak-claude-plugins/.ai-containers/claude-plugins.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
projects_conf="${script_dir}/projects.conf"

# ── Prompt helpers ─────────────────────────────────────────────────────────────

prompt_with_default() {
  # Usage: prompt_with_default "Question" "default" varname
  local q="$1" def="$2" varname="$3" reply
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " reply
    printf -v "$varname" '%s' "${reply:-$def}"
  else
    read -r -p "$q: " reply
    printf -v "$varname" '%s' "$reply"
  fi
}

valid_group_name() {
  # Mirrors validate_group_name() in runme.sh.
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
}

# ── 1. Project path ────────────────────────────────────────────────────────────

while true; do
  prompt_with_default "Project path" "" project_path_input
  if [[ -z "$project_path_input" ]]; then
    printf '  Path is required.\n' >&2
    continue
  fi
  if project_path="$(cd "$project_path_input" 2>/dev/null && pwd)"; then
    break
  fi
  printf '  ERROR: path does not exist: %s\n' "$project_path_input" >&2
done

# ── 2. Project name ────────────────────────────────────────────────────────────

default_name="$(basename "$project_path")"
prompt_with_default "Project name" "$default_name" project_name

# ── 3. Image name ──────────────────────────────────────────────────────────────

default_image="${project_name}-ai-container"
prompt_with_default "Image name" "$default_image" image_name

# ── 4. CPUs ────────────────────────────────────────────────────────────────────

prompt_with_default "Container CPUs" "4.0" container_cpus

# ── 5. Memory ──────────────────────────────────────────────────────────────────

prompt_with_default "Container memory" "8g" container_memory

# ── 6. Group ───────────────────────────────────────────────────────────────────

while true; do
  prompt_with_default "Container group (AI_CONTAINER_GROUP)" "default" group_name
  if valid_group_name "$group_name"; then
    break
  fi
  printf '  Invalid group. Allowed: lowercase letters, digits, dashes; 1-32 chars; must start with alphanum.\n' >&2
done

# ── 7. Group init (conditional) ────────────────────────────────────────────────

group_init=""
group_root="$HOME/.ai-containers/$group_name"
if [[ "$group_name" != "host" && ! -d "$group_root" ]]; then
  printf "\nGroup '%s' does not exist yet. Initialize from:\n" "$group_name"

  init_values=()
  init_labels=()

  if [[ -d "$HOME/.ai-containers/default" && "$group_name" != "default" ]]; then
    init_values+=("from:default"); init_labels+=("default (recommended)")
  fi
  init_values+=("from:host"); init_labels+=("host (\$HOME)")

  if [[ -d "$HOME/.ai-containers" ]]; then
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      name="$(basename "$dir")"
      [[ "$name" == "default" || "$name" == "$group_name" ]] && continue
      init_values+=("from:$name"); init_labels+=("$name")
    done < <(find "$HOME/.ai-containers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  init_values+=("clean"); init_labels+=("<empty>")

  for i in "${!init_labels[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${init_labels[$i]}"
  done

  while true; do
    read -r -p "[1]: " reply
    [[ -z "$reply" ]] && reply=1
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#init_values[@]} )); then
      group_init="${init_values[$((reply-1))]}"
      break
    fi
    printf '  Invalid choice. Enter a number 1-%d.\n' "${#init_values[@]}" >&2
  done
fi

# ── 8. Extra mounts ────────────────────────────────────────────────────────────

prompt_with_default "Extra mounts (space-separated host paths, append :ro for read-only; empty to skip)" "" extra_mounts

# ── Copy shared files ──────────────────────────────────────────────────────────

dest="${project_path}/.ai-containers"
launch_script="${dest}/${project_name}-container.sh"

printf '\nInitialising %s → %s\n' "$project_name" "$dest"
mkdir -p "$dest"

rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-domains.d/"       "${dest}/allowlist-domains.d/"
rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-proxy-domains.d/" "${dest}/allowlist-proxy-domains.d/"
rsync -a --exclude='custom.txt' \
  "${script_dir}/allowlist-cidrs.d/"         "${dest}/allowlist-cidrs.d/"

for f in Dockerfile .dockerignore runme.sh entrypoint.sh \
          refresh-ipset-allowlist.sh capture-blocked-traffic.sh \
          capture-agent-destinations.sh install-dt-tools.sh; do
  [[ -f "${script_dir}/${f}" ]] && cp "${script_dir}/${f}" "${dest}/${f}"
done

if [[ ! -f "${dest}/sandbox.conf" ]]; then
  cp "${script_dir}/sandbox.conf" "${dest}/sandbox.conf"
  printf '  Copied sandbox.conf — edit it to choose components before building.\n'
else
  printf '  sandbox.conf already exists — skipping (not overwritten).\n'
fi

for dir in allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d; do
  custom="${dest}/${dir}/custom.txt"
  example="${dest}/${dir}/custom.txt.example"
  if [[ ! -f "$custom" && -f "$example" ]]; then
    cp "$example" "$custom"
    printf '  Created %s/%s/custom.txt from template.\n' "$(basename "$dest")" "$dir"
  fi
done

# ── Write launcher ─────────────────────────────────────────────────────────────

write_launcher=1
if [[ -f "$launch_script" ]]; then
  read -r -p "  $(basename "$launch_script") already exists. Overwrite? [y/N]: " ow
  case "$ow" in
    y|Y|yes|YES) write_launcher=1 ;;
    *) write_launcher=0 ;;
  esac
fi

if (( write_launcher )); then
  {
    cat <<EOF
#!/usr/bin/env bash
# ${project_name}-container.sh — launch the AI sandbox for ${project_name}.
# Generated by project-init.sh. Re-run project-init.sh to regenerate.
set -euo pipefail

cd "\$(dirname "\${BASH_SOURCE[0]}")"

export IMAGE_NAME=${image_name}
export CONTAINER_CPUS="${container_cpus}"
export CONTAINER_MEMORY="${container_memory}"
export AI_CONTAINER_GROUP=${group_name}
EOF
    [[ -n "$group_init"   ]] && printf 'export AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
    [[ -n "$extra_mounts" ]] && printf 'export EXTRA_MOUNTS="%s"\n' "$extra_mounts"
    cat <<'EOF'

./runme.sh build
#./runme.sh --no-cache build
#./runme.sh restricted ..
./runme.sh discovery ..
EOF
  } > "$launch_script"
  chmod +x "$launch_script"
  printf '  Wrote %s\n' "$(basename "$launch_script")"
else
  printf '  Kept existing %s.\n' "$(basename "$launch_script")"
fi

# ── Register project ───────────────────────────────────────────────────────────

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

# ── Next steps ─────────────────────────────────────────────────────────────────

printf '\nDone. Next steps:\n'
printf '  1. (Optional) Edit %s to choose components.\n' "${dest}/sandbox.conf"
printf '  2. Run: %s\n' "$launch_script"
