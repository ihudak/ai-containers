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
  # Mirrors validate_group_name() in sandbox-common.sh.
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
}

# Ensure the project's root .gitignore ignores its .ai-containers/ working copy.
# The per-project .ai-containers/ is a synced copy of the central repo and the
# launcher embeds machine-specific absolute paths (EXTRA_MOUNTS), so it should
# not be committed to the project. Idempotent, git-repos only; to keep it under
# version control instead (e.g. to share sandbox config with a team), remove the
# added line. Honour AI_CONTAINERS_NO_GITIGNORE=1 to skip entirely.
ensure_ai_containers_ignored() {
  local project_path="$1"
  [[ "${AI_CONTAINERS_NO_GITIGNORE:-0}" == "1" ]] && return 0
  git -C "$project_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$project_path" check-ignore -q .ai-containers 2>/dev/null && return 0
  local gi="${project_path}/.gitignore"
  # Guarantee a trailing newline before appending to an existing, non-empty file.
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

# Parse a docker-style memory string (e.g. 512m, 2g, 1073741824, or -1) into bytes.
# Echoes the byte count (or "-1") and returns 0; returns 1 on parse failure.
mem_to_bytes() {
  local v="${1,,}"
  if [[ "$v" == "-1" ]]; then printf '%s' "-1"; return 0; fi
  if [[ "$v" =~ ^([0-9]+)([bkmg]?)$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
      b|"") printf '%s' "$num" ;;
      k)    printf '%s' "$(( num * 1024 ))" ;;
      m)    printf '%s' "$(( num * 1024 * 1024 ))" ;;
      g)    printf '%s' "$(( num * 1024 * 1024 * 1024 ))" ;;
    esac
    return 0
  fi
  return 1
}

# mem_le A B → true if both parse and A <= B.
mem_le() {
  local a b
  a="$(mem_to_bytes "$1")" || return 2
  b="$(mem_to_bytes "$2")" || return 2
  (( a <= b ))
}

# mem_ge A B → true if both parse and A >= B.
mem_ge() {
  local a b
  a="$(mem_to_bytes "$1")" || return 2
  b="$(mem_to_bytes "$2")" || return 2
  (( a >= b ))
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

prompt_with_default "Container memory (hard limit)" "8g" container_memory

# ── 5b. Memory reservation (soft limit, must be <= memory) ─────────────────────

while true; do
  prompt_with_default "Container memory reservation (soft limit, must be <= memory)" "4g" container_memory_reservation
  if mem_le "$container_memory_reservation" "$container_memory"; then
    break
  fi
  printf '  Reservation must be a valid memory value (e.g. 2g) and <= memory (%s). Got: %s\n' "$container_memory" "$container_memory_reservation" >&2
done

# ── 5c. Memory + swap total (must be >= memory, or -1 for unlimited) ───────────
# Recommended: equal to memory (disables swap) for predictable agent performance.

while true; do
  prompt_with_default "Container memory+swap total (>= memory; equal to memory disables swap; -1 = unlimited)" "$container_memory" container_memory_swap
  if [[ "$container_memory_swap" == "-1" ]] || mem_ge "$container_memory_swap" "$container_memory"; then
    break
  fi
  printf '  memory-swap must be a valid memory value >= memory (%s), or -1. Got: %s\n' "$container_memory" "$container_memory_swap" >&2
done

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

for f in Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh runme.sh repo.sh entrypoint.sh \
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

# Persist IMAGE_NAME so sandbox-common.sh resolves the same image (and therefore
# the same repo-volume names) for build.sh / runme.sh / repo.sh, even when a
# script is run directly instead of through the launcher below.
cat > "${dest}/sandbox.env" <<EOF
# sandbox.env — persisted environment for this project's AI sandbox.
# Read by sandbox-common.sh so build.sh / runme.sh / repo.sh agree on the image
# name (hence the repo-volume names) even when run outside the launcher. An
# exported IMAGE_NAME (e.g. from the generated launcher) takes precedence.
# Not overwritten by sync-to-projects.sh.
IMAGE_NAME=${image_name}
EOF
printf '  Wrote sandbox.env (IMAGE_NAME=%s).\n' "$image_name"

for dir in allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d; do
  custom="${dest}/${dir}/custom.txt"
  example="${dest}/${dir}/custom.txt.example"
  if [[ ! -f "$custom" && -f "$example" ]]; then
    cp "$example" "$custom"
    printf '  Created %s/%s/custom.txt from template.\n' "$(basename "$dest")" "$dir"
  fi
done

# Ensure the project's .ai-containers/.gitignore covers outputs + generated files.
gi="${dest}/.gitignore"
for pat in '.agent-blocked/' '.agent-discovery/' \
           'allowlist-domains.txt' 'allowlist-proxy-domains.txt' 'allowlist-cidrs.txt' \
           'allowlist-domains.d/custom.txt' 'allowlist-proxy-domains.d/custom.txt' 'allowlist-cidrs.d/custom.txt'; do
  if [[ ! -f "$gi" ]] || ! grep -qxF "$pat" "$gi" 2>/dev/null; then
    printf '%s\n' "$pat" >> "$gi"
  fi
done
printf '  Ensured %s/.gitignore covers outputs and generated files.\n' "$(basename "$dest")"

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
export CONTAINER_MEMORY_RESERVATION="${container_memory_reservation}"
export CONTAINER_MEMORY_SWAP="${container_memory_swap}"
export AI_CONTAINER_GROUP=${group_name}
EOF
    [[ -n "$group_init"   ]] && printf 'export AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
    [[ -n "$extra_mounts" ]] && printf 'export EXTRA_MOUNTS="%s"\n' "$extra_mounts"
    # If this project IS the host's $DOCS_PATH docs repo, unset DOCS_PATH so the
    # read-only /workspace/docs grounding mount does not collide with (or
    # duplicate) the docs repo mounted here as the working dir.
    if [[ -n "${DOCS_PATH:-}" ]]; then
      docs_real="$(cd "${DOCS_PATH/#\~/$HOME}" 2>/dev/null && pwd || true)"
      if [[ -n "$docs_real" && "$docs_real" == "$project_path" ]]; then
        printf 'unset DOCS_PATH  # this project IS your $DOCS_PATH docs repo; mounted here as the working dir\n'
      fi
    fi
    cat <<'EOF'

# Attach shared, native-speed repo volumes (register first with ./repo.sh add):
#export REPOS="cluster:ro lib:ro app:rw"
# On macOS, for a FAST primary repo, register it and use it as the working dir:
#   ./repo.sh add <name> ..   then   ./runme.sh discovery @<name>

./build.sh
#./build.sh --no-cache
#./runme.sh restricted ..
./runme.sh discovery ..
EOF
  } > "$launch_script"
  chmod +x "$launch_script"
  printf '  Wrote %s\n' "$(basename "$launch_script")"
else
  printf '  Kept existing %s.\n' "$(basename "$launch_script")"
fi

# Keep the project's .ai-containers/ working copy out of the project's own repo.
ensure_ai_containers_ignored "$project_path"

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
