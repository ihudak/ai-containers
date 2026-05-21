#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./runme.sh build [image-name]
  ./runme.sh restricted [workspace-dir]
  ./runme.sh discovery [workspace-dir]

Commands:
  build       Build the AI sandbox image (reads sandbox.conf, regenerates allowlists)
  restricted  Run the container with the firewall enabled (agent runs as non-root, NET_ADMIN/NET_RAW dropped)
  discovery   Run the container with unrestricted egress and background capture (runs as sandbox user)

Flags:
  --no-cache  Pass --no-cache to docker build (also: NO_CACHE=1 ./runme.sh build)

Environment variables:
  IMAGE_NAME          Image to use or build (default: ai-sandbox)
  SSH_SCOPE_DIR       Host SSH subdirectory to mount as ~/.ssh (default: ~/.ssh)
  SANDBOX_UID         UID for the container user (default: host user's id -u)
  SANDBOX_GID         GID for the container user (default: host user's id -g)
  SANDBOX_USER        Username for the container user (default: host username from id -un)
  SANDBOX_GROUP       Group name for the container user (default: host primary group from id -gn)
  EXTRA_MOUNTS        Space-separated list of extra host directories to mount under /repos.
                      Append :ro or :rw to control access per directory (default: rw).
                      Examples:
                        EXTRA_MOUNTS="/path/to/repo"              # read-write (default)
                        EXTRA_MOUNTS="/path/to/repo:ro"           # read-only
                        EXTRA_MOUNTS="/path/to/a:ro /path/to/b"  # a=read-only, b=read-write
  DOCS_PATH           Host directory mounted as /docs inside the container.
  SPECS_PATH          Host directory mounted as /specs inside the container.
  VAULT_PATH          Host Obsidian vault mounted as /obsidian inside the container.
                      When set, VAULT_PATH=/obsidian is also exported into the
                      container so agent skills/workflows resolve correctly.
                      Requires qmd=ON in sandbox.conf for in-container search.
  SELF_HEALING_ENABLED  Set to 0 to disable self-healing allowlist (default: 1).
                        When disabled, blocked traffic is logged but IPs are never auto-allowed.
  GITHUB_TOKEN          Build-time only. Passed to docker build as a BuildKit secret
                        (--secret id=github_token) so install-dt-tools.sh can use the
                        authenticated GitHub API (5000 req/h vs 60 req/h). Never
                        written into any image layer or visible in `docker history`.
                        Not forwarded into the running container. If unset,
                        GITHUB_PERSONAL_ACCESS_TOKEN is used as a fallback so you
                        don't have to export a second name just for the build.
  GITHUB_PERSONAL_ACCESS_TOKEN
                        Runtime: forwarded into the container as-is for tools that
                        expect this exact variable name (e.g. the
                        `github/github-mcp-server` / `@modelcontextprotocol/server-github`
                        stdio MCP servers, and Claude Code's official github plugin).
                        Build-time fallback: used as the BuildKit github_token secret
                        when GITHUB_TOKEN is not set. NOT consumed by Copilot CLI or
                        gh CLI — those authenticate via ~/.copilot/config.json and
                        ~/.config/gh/hosts.yml respectively, both already mounted.
                        `GH_TOKEN` and `GITHUB_TOKEN` are deliberately NOT forwarded
                        into the container, because Copilot CLI would otherwise
                        prefer them over its OAuth login and fail with
                        `401 "Personal Access Token does not have 'Copilot Requests'
                        permission"` whenever the PAT lacks that fine-grained
                        permission.
  PREVIEW_PORTS       Space-separated list of ports (or host:container pairs) to publish so
                      your host browser can reach dev servers started inside the container.
                      Useful for Claude Code's UI preview feature and any other dev server.
                      Examples:
                        PREVIEW_PORTS="3000"            # publish container port 3000 → host 3000
                        PREVIEW_PORTS="3000 5173"       # publish two ports
                        PREVIEW_PORTS="8080:3000"       # host port 8080 → container port 3000
                        PREVIEW_PORTS="3000 8080:8080"  # mix of both forms
  NO_CACHE            Set to 1 to pass --no-cache to docker build (default: unset, uses cache).
  CONTAINER_CPUS      CPU limit for the running container (default: 4.0). Must fit
                      within the resources allocated to your Docker engine
                      (e.g. on Colima, set with `colima start --cpu N`).
  CONTAINER_MEMORY    Memory limit for the running container (default: 8g). Same
                      sizing rules apply as for CONTAINER_CPUS.

Configuration:
  Edit sandbox.conf to enable or disable optional components before building.
EOF
}

# ── Config helpers ─────────────────────────────────────────────────────────────

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${script_dir}/sandbox.conf"
image_name="${IMAGE_NAME:-ai-sandbox}"

check_config() {
  if [[ ! -f "$config_file" ]]; then
    printf 'ERROR: sandbox.conf not found in %s\n' "$script_dir" >&2
    exit 1
  fi
}

# Returns 0 if the component is set to ON in sandbox.conf, 1 otherwise.
# Uses get_versions internally so it tolerates whitespace (e.g. "copilot = ON").
is_enabled() {
  [[ "$(get_versions "$1")" == "ON" ]]
}

# Returns 0 if at least one of the given components is ON.
any_enabled() {
  local c
  for c in "$@"; do
    if is_enabled "$c"; then return 0; fi
  done
  return 1
}

# Returns 0 if a key is ON or has a non-empty version value (i.e. the component is active).
# Uses get_versions so inline comments are stripped consistently.
is_active() {
  local val; val=$(get_versions "$1")
  [[ -n "$val" && "$val" != "OFF" ]]
}

# Returns 0 if at least one of the given keys is active.
any_active() {
  local k
  for k in "$@"; do
    if is_active "$k"; then return 0; fi
  done
  return 1
}
# Returns empty string if the key is absent or has no value.
get_versions() {
  local key="$1"
  local raw
  raw=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2-)
  # Strip inline comments (e.g. "21 # LTS version" → "21")
  raw="${raw%%#*}"
  # Trim whitespace
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

# Returns 0 if the version-list key has at least one version set.
has_versions() {
  local val
  val="$(get_versions "$1")"
  [[ -n "$val" ]]
}

# Returns 0 if any of the given version-list keys have at least one version set.
any_has_versions() {
  local k
  for k in "$@"; do
    if has_versions "$k"; then return 0; fi
  done
  return 1
}

# Convert a comma-separated version list to a space-separated list for build args.
versions_to_space() {
  printf '%s' "$1" | tr ',' ' '
}

# ── Validation ─────────────────────────────────────────────────────────────────

validate_config() {
  # rails requires ruby
  if has_versions rails && ! has_versions ruby; then
    printf 'ERROR: rails is set in sandbox.conf but ruby is empty. Rails requires Ruby (via rvm).\n' >&2
    exit 1
  fi
  # ruby and rails only support a single version each (rvm can manage multiple
  # rubies but Rails-on-Ruby pairing is ambiguous with multiple versions)
  local ruby_val; ruby_val=$(get_versions ruby)
  if [[ "$ruby_val" == *,* ]]; then
    printf 'ERROR: ruby only supports a single version (got: "%s").\n' "$ruby_val" >&2
    printf '       Use a single version, e.g.: ruby=3.4.3\n' >&2
    exit 1
  fi
  local rails_val; rails_val=$(get_versions rails)
  if [[ "$rails_val" == *,* ]]; then
    printf 'ERROR: rails only supports a single version (got: "%s").\n' "$rails_val" >&2
    printf '       Use a single version, e.g.: rails=8.0.2\n' >&2
    exit 1
  fi
  # angular-cli only supports a single version (ON, a version number, or OFF)
  local angular_val; angular_val=$(get_versions angular-cli)
  if [[ "$angular_val" == *,* ]]; then
    printf 'ERROR: angular-cli only supports a single version (got: "%s").\n' "$angular_val" >&2
    printf '       Use ON (latest), a single version number (e.g. 19), or OFF.\n' >&2
    exit 1
  fi
  # SDKMAN requires full patch versions (e.g. 21.0.5, not 21).
  # Validate that every version in each JVM key contains at least one dot.
  local jvm_key jvm_val ver
  for jvm_key in openjdk graalvm-ce graalvm-oracle kotlin scala maven gradle; do
    jvm_val=$(get_versions "$jvm_key")
    [[ -z "$jvm_val" ]] && continue
    IFS=',' read -ra _vers <<< "$jvm_val"
    for ver in "${_vers[@]}"; do
      ver="${ver// /}"
      if [[ "$ver" != *.* ]]; then
        printf 'ERROR: %s version "%s" looks like a major version only.\n' "$jvm_key" "$ver" >&2
        printf '       SDKMAN requires full patch versions, e.g. 21.0.5 not 21.\n' >&2
        printf '       Run "sdk list java" inside a container to see valid identifiers.\n' >&2
        exit 1
      fi
    done
  done
}
# ── Allowlist generation ────────────────────────────────────────────────────────

# Append a fragment file to stdout; silently skip if the file does not exist.
include_fragment() {
  local fragment="$1"
  if [[ -f "$fragment" ]]; then cat "$fragment"; fi
}

# Append a fragment only when at least one of the listed boolean components is enabled.
include_if_enabled() {
  local fragment="$1"; shift
  if any_enabled "$@"; then
    include_fragment "$fragment"
  fi
}

# Append a fragment only when at least one of the listed version-list keys has versions.
include_if_has_versions() {
  local fragment="$1"; shift
  if any_has_versions "$@"; then
    include_fragment "$fragment"
  fi
}

generate_allowlists() {
  local domains_d="${script_dir}/allowlist-domains.d"
  local proxy_d="${script_dir}/allowlist-proxy-domains.d"
  local cidrs_d="${script_dir}/allowlist-cidrs.d"

  # Auto-create custom.txt from the .example template if it doesn't exist yet.
  # This lets new users run ./runme.sh build without any manual setup.
  for f in "$domains_d/custom.txt" "$proxy_d/custom.txt" "$cidrs_d/custom.txt"; do
    if [[ ! -f "$f" && -f "${f}.example" ]]; then
      cp "${f}.example" "$f"
      printf 'Created %s from template (gitignored — add your own entries there)\n' "$f"
    fi
  done

  printf 'Generating allowlists from sandbox.conf...\n'

  # allowlist-domains.txt
  {
    printf '# AUTO-GENERATED by runme.sh — do not edit directly.\n'
    printf '# Edit files in allowlist-domains.d/ and run: ./runme.sh build\n\n'
    include_fragment         "$domains_d/base.txt"
    include_if_enabled       "$domains_d/github-cli.txt"      github-cli
    include_if_enabled       "$domains_d/github-copilot.txt"  copilot
    include_if_enabled       "$domains_d/kiro.txt"            kiro
    include_if_enabled       "$domains_d/claude-code.txt"     claude-code
    include_if_enabled       "$domains_d/codex.txt"           codex
    include_if_enabled       "$domains_d/gemini.txt"          gemini
    include_if_enabled       "$domains_d/graphify.txt"        graphify
    include_if_enabled       "$domains_d/yarn.txt"            yarn
    include_if_enabled       "$domains_d/kubectl.txt"         kubectl
    include_if_enabled       "$domains_d/aws-cli.txt"         aws-cli
    include_if_enabled       "$domains_d/azure-cli.txt"       azure-cli
    # dtctl/dtmgd use version values (ON, x.y.z) not boolean ON/OFF
    if any_active dtctl dtmgd; then include_fragment "$domains_d/dynatrace.txt"; fi
    # Version-manager fragments
    include_if_has_versions  "$domains_d/sdkman.txt"          openjdk graalvm-ce graalvm-oracle kotlin scala maven gradle
    include_if_has_versions  "$domains_d/openjdk.txt"         openjdk graalvm-ce graalvm-oracle
    include_fragment         "$domains_d/nvm.txt"
    include_fragment         "$domains_d/pyenv.txt"
    include_if_has_versions  "$domains_d/rvm.txt"             ruby rails
    include_if_has_versions  "$domains_d/rust.txt"            rust
    include_if_has_versions  "$domains_d/go.txt"              go
    if is_active angular-cli; then include_fragment "$domains_d/angular-cli.txt"; fi
    include_fragment         "$domains_d/custom.txt"
  } > "${script_dir}/allowlist-domains.txt"

  # allowlist-proxy-domains.txt
  {
    printf '# AUTO-GENERATED by runme.sh — do not edit directly.\n'
    printf '# Edit files in allowlist-proxy-domains.d/ and run: ./runme.sh build\n\n'
    include_if_enabled  "$proxy_d/github-copilot.txt"  copilot
    include_if_enabled  "$proxy_d/kiro.txt"            kiro
    include_if_enabled  "$proxy_d/claude-code.txt"     claude-code
    include_if_enabled  "$proxy_d/codex.txt"           codex
    include_if_enabled  "$proxy_d/gemini.txt"          gemini
    include_if_enabled  "$proxy_d/graphify.txt"        graphify
    if any_active dtctl dtmgd; then include_fragment "$proxy_d/dynatrace.txt"; fi
    include_fragment    "$proxy_d/custom.txt"
  } > "${script_dir}/allowlist-proxy-domains.txt"

  # allowlist-cidrs.txt
  {
    printf '# AUTO-GENERATED by runme.sh — do not edit directly.\n'
    printf '# Edit files in allowlist-cidrs.d/ and run: ./runme.sh build\n\n'
    include_fragment    "$cidrs_d/base.txt"
    include_if_enabled  "$cidrs_d/github-copilot.txt"  copilot
    include_fragment    "$cidrs_d/custom.txt"
  } > "${script_dir}/allowlist-cidrs.txt"
}

# ── Build-arg generation ───────────────────────────────────────────────────────

# Populate the named array with --build-arg flags derived from sandbox.conf.
build_args_from_config() {
  local -n _args=$1

  # ── Boolean ON/OFF components ──────────────────────────────────────────────
  local component arg value
  local bool_mappings=(
    "copilot:INSTALL_COPILOT"
    "kiro:INSTALL_KIRO"
    "claude-code:INSTALL_CLAUDE_CODE"
    "codex:INSTALL_CODEX"
    "gemini:INSTALL_GEMINI"
    "graphify:INSTALL_GRAPHIFY"
    "kubectl:INSTALL_KUBECTL"
    "aws-cli:INSTALL_AWS_CLI"
    "azure-cli:INSTALL_AZURE_CLI"
    "github-cli:INSTALL_GITHUB_CLI"
    "yarn:INSTALL_YARN"
    "qmd:INSTALL_QMD"
    "bun:INSTALL_BUN"
  )
  for mapping in "${bool_mappings[@]}"; do
    component="${mapping%%:*}"
    arg="${mapping##*:}"
    if is_enabled "$component"; then value=1; else value=0; fi
    _args+=(--build-arg "${arg}=${value}")
  done

  # ── dtctl / dtmgd: ON = latest, x.y.z = pinned version, OFF = skip ────────
  # These use a separate ARG (DTCTL_VERSION / DTMGD_VERSION) instead of a bool.
  for tool in dtctl dtmgd; do
    local raw; raw=$(get_versions "$tool")
    local arg_name; arg_name="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION"
    if [[ "$raw" == "ON" ]]; then
      _args+=(--build-arg "${arg_name}=latest")
    elif [[ -n "$raw" && "$raw" != "OFF" ]]; then
      _args+=(--build-arg "${arg_name}=${raw}")
    else
      _args+=(--build-arg "${arg_name}=")
    fi
  done

  # ── angular-cli: ON = latest, version number = pinned, OFF = skip ─────────
  local angular_raw; angular_raw=$(get_versions angular-cli)
  if [[ "$angular_raw" == "ON" ]]; then
    _args+=(--build-arg "ANGULAR_CLI_VERSION=latest")
  elif [[ -n "$angular_raw" && "$angular_raw" != "OFF" ]]; then
    _args+=(--build-arg "ANGULAR_CLI_VERSION=${angular_raw}")
  else
    _args+=(--build-arg "ANGULAR_CLI_VERSION=")
  fi

  # ── SDKMAN: auto-on if any JVM component has versions ─────────────────────
  local jvm_keys=(openjdk graalvm-ce graalvm-oracle kotlin scala maven gradle)
  if any_has_versions "${jvm_keys[@]}"; then
    _args+=(--build-arg "INSTALL_SDKMAN=1")
  else
    _args+=(--build-arg "INSTALL_SDKMAN=0")
  fi

  # ── Version-list components ────────────────────────────────────────────────
  # Pass space-separated version strings as build args.
  local ver
  ver="$(get_versions openjdk)"
  _args+=(--build-arg "OPENJDK_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions graalvm-ce)"
  _args+=(--build-arg "GRAALVM_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions graalvm-oracle)"
  _args+=(--build-arg "GRAALVM_ORACLE_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions kotlin)"
  _args+=(--build-arg "KOTLIN_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions scala)"
  _args+=(--build-arg "SCALA_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions maven)"
  _args+=(--build-arg "MAVEN_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions gradle)"
  _args+=(--build-arg "GRADLE_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions node)"
  _args+=(--build-arg "NODE_EXTRA_VERSIONS=$(versions_to_space "$ver")")

  # nvm version pin (optional — falls back to Dockerfile default if empty)
  ver="$(get_versions nvm-version)"
  if [[ -n "$ver" ]]; then
    _args+=(--build-arg "NVM_VERSION=$ver")
  fi

  ver="$(get_versions python)"
  _args+=(--build-arg "PYTHON_EXTRA_VERSIONS=$(versions_to_space "$ver")")

  ver="$(get_versions ruby)"
  _args+=(--build-arg "RUBY_VERSION=$ver")

  ver="$(get_versions rails)"
  _args+=(--build-arg "RAILS_VERSION=$ver")

  ver="$(get_versions rust)"
  _args+=(--build-arg "RUST_TOOLCHAIN=$ver")

  ver="$(get_versions go)"
  _args+=(--build-arg "GO_VERSION=$ver")
}

# ── Build ──────────────────────────────────────────────────────────────────────

build_image() {
  check_config
  validate_config
  local build_image_name="${1:-$image_name}"
  local build_args=()

  generate_allowlists
  build_args_from_config build_args

  if [[ "${NO_CACHE:-0}" == "1" ]]; then
    build_args+=(--no-cache)
  fi

  # Pass a GitHub token as a BuildKit secret (never stored in image layers or history)
  # so install-dt-tools.sh can use the authenticated GitHub API (5000 req/h vs 60 req/h
  # unauthenticated). Prefer GITHUB_TOKEN, fall back to GITHUB_PERSONAL_ACCESS_TOKEN.
  # Falls back gracefully if neither is set — install-dt-tools.sh handles the missing token.
  local _gh_build_token="${GITHUB_TOKEN:-${GITHUB_PERSONAL_ACCESS_TOKEN:-}}"
  if [[ -n "$_gh_build_token" ]]; then
    export GITHUB_TOKEN="$_gh_build_token"
    build_args+=(--secret id=github_token,env=GITHUB_TOKEN)
  fi

  docker build "${build_args[@]}" -t "$build_image_name" "$script_dir"
}

# ── Run ────────────────────────────────────────────────────────────────────────

# Resolve symlinks to their real path; falls back to the original if not found.
resolve_path() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

# Append bind-mount flags to an array only if the resolved source directory exists.
add_mount_if_exists() {
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  if [[ -d "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  else
    printf 'WARNING: skipping mount — directory not found: %s\n' "$original_src" >&2
  fi
}

# Same as add_mount_if_exists but for individual files.
add_file_mount_if_exists() {
  local -n _flags=$1
  local original_src="$2" dst="$3" opts="${4:-rw}"
  local src
  src="$(resolve_path "$original_src")"
  if [[ -f "$src" ]]; then
    _flags+=(-v "$src:$dst:$opts")
  fi
}

run_container() {
  check_config
  local mode="$1"
  local workspace_dir
  workspace_dir="$(resolve_path "${2:-$PWD}")"
  local capture_dir_name="${DISCOVERY_CAPTURE_DIR_NAME:-.agent-discovery}"
  local capture_enabled="0"
  local ssh_scope_dir
  ssh_scope_dir="$(resolve_path "${SSH_SCOPE_DIR:-$HOME/.ssh}")"

  if [[ ! -d "$workspace_dir" ]]; then
    printf 'ERROR: workspace directory does not exist: %s\n' "${2:-$PWD}" >&2
    exit 1
  fi

  local capabilities=(--cap-add=NET_ADMIN --cap-add=NET_RAW)

  local sandbox_username="${SANDBOX_USER:-$(id -un)}"
  local dev_home="/home/$sandbox_username"
  if [[ "$mode" == "discovery" ]]; then
    capture_enabled="1"
    mkdir -p "$workspace_dir/$capture_dir_name"
  fi

  # Validate and build EXTRA_MOUNTS flags; abort early if any path is missing.
  local extra_mount_flags=()
  if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
    for entry in $EXTRA_MOUNTS; do
      local dir opt real_dir
      dir="${entry%%:*}"
      opt="${entry##*:}"
      [[ "$opt" == "$dir" ]] && opt="rw"
      real_dir="$(resolve_path "${dir/#\~/$HOME}")"
      if [[ ! -d "$real_dir" ]]; then
        printf 'ERROR: EXTRA_MOUNTS path does not exist: %s\n' "$dir" >&2
        exit 1
      fi
      extra_mount_flags+=(-v "$real_dir:/repos/$(basename "$dir"):$opt")
    done
  fi

  # Optional documentation / spec / vault mounts driven by host env vars.
  # DOCS_PATH  → /docs        (read-write)
  # SPECS_PATH → /specs       (read-write)
  # VAULT_PATH → /obsidian    (read-write); also exports VAULT_PATH=/obsidian
  #              inside the container so agent skills/workflows that rely on
  #              the variable resolve to the in-container mount point.
  local doc_mount_flags=()
  local vault_env_args=()
  if [[ -n "${DOCS_PATH:-}" ]]; then
    add_mount_if_exists doc_mount_flags "$DOCS_PATH" "/docs"
  fi
  if [[ -n "${SPECS_PATH:-}" ]]; then
    add_mount_if_exists doc_mount_flags "$SPECS_PATH" "/specs"
  fi
  if [[ -n "${VAULT_PATH:-}" ]]; then
    local vault_real
    vault_real="$(resolve_path "${VAULT_PATH/#\~/$HOME}")"
    if [[ -d "$vault_real" ]]; then
      doc_mount_flags+=(-v "$vault_real:/obsidian:rw")
      vault_env_args+=(-e VAULT_PATH=/obsidian)
      if ! is_enabled qmd; then
        printf 'WARNING: VAULT_PATH is set but qmd=OFF in sandbox.conf. Set qmd=ON and rebuild for in-container search.\n' >&2
      fi
    else
      printf 'WARNING: VAULT_PATH is set but directory does not exist: %s\n' "$VAULT_PATH" >&2
    fi
  fi

  # Mount credential directories for enabled components only.
  local config_mount_flags=()
  add_mount_if_exists      config_mount_flags "$ssh_scope_dir"       "$dev_home/.ssh"       ro
  add_mount_if_exists      config_mount_flags "$HOME/.agents"        "$dev_home/.agents"
  add_file_mount_if_exists config_mount_flags "$HOME/.gitconfig"     "$dev_home/.gitconfig" ro

  # ── macOS host: separate dotfile dirs for Keychain-affected tools ───────────
  # On macOS, gh/copilot/claude-code/kiro store OAuth tokens in the system
  # Keychain and use their dotfile dirs only for non-token state. Sharing those
  # dirs with the Linux container would (a) carry no token across the boundary
  # anyway, and (b) expose the container's SQLite/state writes to host writes
  # over virtio-fs (Copilot's session-store.db, Kiro state, etc.).
  #
  # Solution: on macOS, back these mounts with parallel host paths under
  # ~/.ai-containers/<dotname>/ instead of ~/<dotname>/. Every container on
  # this host (any project, any image) shares the same ~/.ai-containers/ tree,
  # so a one-time in-container /login persists across all of them. The host's
  # native CLIs continue to use the original ~/.* paths, untouched.
  #
  # Other tools (aws, azure, kube, yarn, codex, gemini, dtctl, dtmgd) do not
  # use Keychain on macOS and store cross-platform data; they stay shared.
  local container_dotroot="$HOME"
  if [[ "$(uname -s)" == "Darwin" ]] && any_enabled copilot kiro claude-code github-cli; then
    container_dotroot="$HOME/.ai-containers"
    mkdir -p "$container_dotroot"
    is_enabled copilot     && mkdir -p "$container_dotroot/.copilot"
    any_enabled github-cli copilot && mkdir -p "$container_dotroot/.config/gh"
    if is_enabled kiro; then
      mkdir -p "$container_dotroot/.kiro"
      mkdir -p "$container_dotroot/.local/share/kiro-cli"
    fi
    if is_enabled claude-code; then
      mkdir -p "$container_dotroot/.claude"
      [[ -e "$container_dotroot/.claude.json" ]] || printf '{}' > "$container_dotroot/.claude.json"
    fi
  fi

  if any_enabled github-cli copilot; then
    add_mount_if_exists config_mount_flags "$container_dotroot/.config/gh" "$dev_home/.config/gh"
  fi
  if is_enabled copilot; then
    add_mount_if_exists config_mount_flags "$container_dotroot/.copilot" "$dev_home/.copilot"
  fi
  if is_enabled kiro; then
    add_mount_if_exists config_mount_flags "$container_dotroot/.kiro" "$dev_home/.kiro"
    # Kiro CLI data dir: Linux uses XDG (~/.local/share/kiro-cli); macOS uses
    # ~/Library/Application Support/kiro-cli for the host Kiro. Sharing the
    # macOS dir directly with the Linux container would conflict because that
    # dir holds a per-arch Mach-O `bun` runtime; the Linux container expects
    # an ELF. On macOS we therefore route the container's data dir to a
    # parallel host path under ~/.ai-containers/, which the host Mac Kiro
    # never touches. KB indexes and history then persist across container
    # runs and across projects, identical to the Linux behaviour.
    if [[ "$(uname -s)" == "Darwin" ]]; then
      add_mount_if_exists config_mount_flags "$container_dotroot/.local/share/kiro-cli" "$dev_home/.local/share/kiro-cli"
    else
      add_mount_if_exists config_mount_flags "$HOME/.local/share/kiro-cli" "$dev_home/.local/share/kiro-cli"
    fi
  fi
  if is_enabled claude-code; then
    add_mount_if_exists      config_mount_flags "$container_dotroot/.claude"      "$dev_home/.claude"
    add_file_mount_if_exists config_mount_flags "$container_dotroot/.claude.json" "$dev_home/.claude.json"
  fi

  if is_enabled codex; then
    add_mount_if_exists config_mount_flags "$HOME/.codex" "$dev_home/.codex"
  fi
  if is_enabled gemini; then
    add_mount_if_exists config_mount_flags "$HOME/.gemini" "$dev_home/.gemini"
  fi
  if is_enabled yarn; then
    add_mount_if_exists config_mount_flags "$HOME/.yarn" "$dev_home/.yarn"
  fi
  if is_enabled aws-cli; then
    add_mount_if_exists config_mount_flags "$HOME/.aws" "$dev_home/.aws"
  fi
  if is_enabled azure-cli; then
    add_mount_if_exists config_mount_flags "$HOME/.azure" "$dev_home/.azure"
  fi
  if is_enabled kubectl; then
    add_mount_if_exists config_mount_flags "$HOME/.kube" "$dev_home/.kube"
  fi
  if is_active dtctl; then
    add_mount_if_exists config_mount_flags "$HOME/.config/dtctl" "$dev_home/.config/dtctl"
  fi
  if is_active dtmgd; then
    add_mount_if_exists config_mount_flags "$HOME/.config/dtmgd" "$dev_home/.config/dtmgd"
  fi

  # Build -p flags from PREVIEW_PORTS (space-separated port or host:container pairs).
  local port_flags=()
  if [[ -n "${PREVIEW_PORTS:-}" ]]; then
    for p in $PREVIEW_PORTS; do
      port_flags+=(-p "$p")
    done
  fi

  docker run -it --rm \
    "${capabilities[@]}" \
    --add-host=host.docker.internal:host-gateway \
    ${port_flags[@]+"${port_flags[@]}"} \
    --cpus="${CONTAINER_CPUS:-4.0}" \
    --memory="${CONTAINER_MEMORY:-8g}" \
    -e DEV_CONTAINER_MODE="$mode" \
    -e DISCOVERY_CAPTURE_ENABLED="$capture_enabled" \
    -e DISCOVERY_CAPTURE_DIR="/workspace/$capture_dir_name" \
    -e HOST_WORKSPACE_DIR="$workspace_dir" \
    -e IMAGE_NAME="$image_name" \
    -e SANDBOX_UID="${SANDBOX_UID:-$(id -u)}" \
    -e SANDBOX_GID="${SANDBOX_GID:-$(id -g)}" \
    -e SANDBOX_USER="${SANDBOX_USER:-$(id -un)}" \
    -e SANDBOX_GROUP="${SANDBOX_GROUP:-$(id -gn)}" \
    ${SELF_HEALING_ENABLED:+-e SELF_HEALING_ENABLED="$SELF_HEALING_ENABLED"} \
    ${GITHUB_PERSONAL_ACCESS_TOKEN:+-e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"} \
    ${vault_env_args[@]+"${vault_env_args[@]}"} \
    -v "$workspace_dir:/workspace" \
    ${extra_mount_flags[@]+"${extra_mount_flags[@]}"} \
    ${doc_mount_flags[@]+"${doc_mount_flags[@]}"} \
    ${config_mount_flags[@]+"${config_mount_flags[@]}"} \
    -w /workspace \
    "$image_name"
}

# ── Entry point ────────────────────────────────────────────────────────────────

# Parse --no-cache flag (can appear anywhere in args)
args=()
for arg in "$@"; do
  if [[ "$arg" == "--no-cache" ]]; then
    NO_CACHE=1
  else
    args+=("$arg")
  fi
done
set -- "${args[@]+"${args[@]}"}"

command="${1:-usage}"

case "$command" in
  build)
    build_image "${2:-$image_name}"
    ;;
  restricted|discovery)
    run_container "$command" "${2:-$PWD}"
    ;;
  -h|--help|help|usage)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
