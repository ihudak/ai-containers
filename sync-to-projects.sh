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
#   sandbox.conf, sandbox.env, allowlist-*.d/custom.txt, runme.sh (launcher), projects.conf
#   (sandbox.env is created/backfilled if missing, but never overwritten.)
#
# sandbox.conf reconcile:
#   A project's sandbox.conf is reconciled against this repo's on every sync:
#   pending migrations/ hooks run, any new upstream keys are appended (a key the
#   project already set is never touched), and the '# schema-version:' marker is
#   ensured. See README "sandbox.conf schema versioning".
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
# Read by sandbox-common.sh so build.sh / sandbox.sh / repo.sh agree on the image
# name (hence the repo-volume names) even when run outside the launcher. An
# exported IMAGE_NAME (e.g. from the generated launcher) takes precedence.
# Not overwritten by sync-to-projects.sh.
IMAGE_NAME=${img}
EOF
  printf '  Wrote sandbox.env (IMAGE_NAME=%s).\n' "$img"
}

# Echo the schema-version integer recorded in a sandbox.conf ($1); 0 if absent.
conf_schema_version() {
  local f="$1" v
  v="$(grep -E '^# schema-version:[[:space:]]*[0-9]+' "$f" 2>/dev/null | head -1 \
        | sed -E 's/^# schema-version:[[:space:]]*([0-9]+).*/\1/')"
  printf '%s' "${v:-0}"
}

# Ensure FILE ($1) carries '# schema-version: N' ($2): update in place if the
# marker exists, else append it. Unconditional — called every reconcile.
conf_set_version() {
  local f="$1" n="$2"
  if grep -qE '^# schema-version:' "$f" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    sed -E "s/^# schema-version:.*/# schema-version: ${n}/" "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
  else
    printf '# schema-version: %s\n' "$n" >> "$f"
  fi
}

# Reconcile a project's sandbox.conf ($2) against central ($1) using the hooks in
# MIGRATIONS_DIR ($3):
#   1. run every NNN-*.sh whose NNN > the project's recorded version, ascending;
#   2. additively append any central key the project lacks, under one dated banner
#      (a key the project already has is NEVER touched, whatever its value);
#   3. unconditionally ensure the project's marker matches central's version.
reconcile_sandbox_conf() {
  local central="$1" project="$2" migrations_dir="$3"
  local central_version project_version
  central_version="$(conf_schema_version "$central")"
  project_version="$(conf_schema_version "$project")"

  # 1. Pending migration hooks, ascending numeric order.
  if [[ -d "$migrations_dir" ]]; then
    local hook nnn
    for hook in "$migrations_dir"/[0-9][0-9][0-9]-*.sh; do
      [[ -e "$hook" ]] || continue          # no hooks → glob stays literal
      nnn="$(basename "$hook")"; nnn="${nnn%%-*}"
      # 10#$nnn forces base-10 (leading zeros must not be read as octal).
      if (( 10#$nnn > project_version )); then
        bash "$hook" "$project"
      fi
    done
  fi

  # 2. Additive backfill of central keys the project lacks.
  local added=() key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    grep -qE "^${key}=" "$project" 2>/dev/null || added+=("$key")
  done < <(grep -E '^[A-Za-z0-9_-]+=' "$central" | sed -E 's/^([A-Za-z0-9_-]+)=.*/\1/')

  if (( ${#added[@]} > 0 )); then
    {
      printf '\n# New options synced from upstream (%s)\n' "$(date +%Y-%m-%d)"
      for key in "${added[@]}"; do
        printf '%s=%s\n' "$key" "$(grep -E "^${key}=" "$central" | head -1 | cut -d= -f2-)"
      done
    } >> "$project"
    printf '  Reconciled sandbox.conf: appended %d new key(s): %s\n' \
      "${#added[@]}" "${added[*]}"
  fi

  # 3. Ensure the marker, unconditionally (backfills pre-marker/v0 files).
  conf_set_version "$project" "$central_version"
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

# One-time migration for the runme.sh<->launcher naming swap.
# Old layout: runme.sh = engine (no IMAGE_NAME marker), <project>-container.sh = launcher.
# New layout: sandbox.sh = engine,                      runme.sh              = launcher.
# Discriminator: only a launcher sets `export IMAGE_NAME=<literal>`. Idempotent.
migrate_launcher_naming() {
  local dest="$1"

  # 1. Remove a stale old-engine runme.sh (present AND has no IMAGE_NAME marker).
  if [[ -f "${dest}/runme.sh" ]] \
     && ! grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "${dest}/runme.sh"; then
    rm -f "${dest}/runme.sh"
  fi

  # 2. Rename a legacy <project>-container.sh launcher to runme.sh, unless a
  #    runme.sh launcher (marker-bearing) already exists (already migrated).
  if [[ ! -f "${dest}/runme.sh" ]] \
     || ! grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "${dest}/runme.sh"; then
    local legacy
    for legacy in "${dest}"/*-container.sh; do
      [[ -e "$legacy" ]] || continue
      if grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "$legacy"; then
        mv "$legacy" "${dest}/runme.sh"
        break
      fi
    done
  fi

  # 3. Repoint the launcher's engine call to ./sandbox.sh (idempotent).
  #    Portable in-place edit: GNU sed needs no suffix, BSD/macOS sed requires
  #    one, so pass an explicit `.bak` suffix (works on both) and remove it.
  if [[ -f "${dest}/runme.sh" ]]; then
    sed -i.bak 's#\./runme\.sh#./sandbox.sh#g' "${dest}/runme.sh" && rm -f "${dest}/runme.sh.bak"
  fi
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
  rsync -a "${script_dir}/tools.d/" "${dest}/tools.d/"

  # Migrate legacy runme.sh<->launcher naming before copying shared files.
  migrate_launcher_naming "$dest"

  # Shared scripts and build files
  for f in Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh sandbox.sh repo.sh entrypoint.sh \
            refresh-ipset-allowlist.sh capture-blocked-traffic.sh \
            capture-agent-destinations.sh install-tools.sh install-agent-skills.sh tools-lib.sh; do
    if [[ -f "${script_dir}/${f}" ]]; then
      cp "${script_dir}/${f}" "${dest}/${f}"
    fi
  done

  # README documents central-repo orchestration (project-init/sync) that doesn't
  # exist in a child working copy. Children are leaves: runtime files only.
  [[ -f "${dest}/README.md" ]] && rm -f "${dest}/README.md"

  # sandbox.conf reconcile — migrate + additively backfill, never clobber a key
  # the project already set. Marker is ensured unconditionally (see spec §1, §3).
  if [[ -f "${dest}/sandbox.conf" ]]; then
    reconcile_sandbox_conf "${script_dir}/sandbox.conf" "${dest}/sandbox.conf" "${script_dir}/migrations"
  fi

  # sandbox.env — never overwritten; backfilled from the launcher if missing.
  backfill_sandbox_env "$dest"

  # Keep the project's .ai-containers/ working copy out of the project's repo.
  ensure_ai_containers_ignored "$project_path"

  printf '  OK\n'
}

# Allow tests to source this file for its reconcile helpers without running a sync.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

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
