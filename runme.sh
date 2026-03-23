#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./runme.sh build [image-name]
  ./runme.sh restricted [workspace-dir]
  ./runme.sh discovery [workspace-dir]

Commands:
  build       Build the dev-container image from this asset directory
  restricted  Run the container with the firewall enabled
  discovery   Run the container with unrestricted egress and background capture
EOF
}

command="${1:-restricted}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_name="${IMAGE_NAME:-bookstore-copilot}"

build_image() {
  local build_image_name="${1:-$image_name}"
  docker build -t "$build_image_name" "$script_dir"
}

run_container() {
  local mode="$1"
  local workspace_dir="${2:-$PWD}"
  local capture_dir_name="${DISCOVERY_CAPTURE_DIR_NAME:-.copilot-discovery}"
  local capture_enabled="0"
  local capabilities=(--cap-add=NET_ADMIN)
  local ssh_scope_dir="${SSH_SCOPE_DIR:-$HOME/.ssh/bookstore}"

  if [[ "$mode" == "discovery" ]]; then
    capabilities+=(--cap-add=NET_RAW)
    capture_enabled="1"
    mkdir -p "$workspace_dir/$capture_dir_name"
  fi

  docker run -it --rm \
    "${capabilities[@]}" \
    --add-host=host.docker.internal:host-gateway \
    --cpus="4.0" \
    --memory="8g" \
    -e DEV_CONTAINER_MODE="$mode" \
    -e DISCOVERY_CAPTURE_ENABLED="$capture_enabled" \
    -e DISCOVERY_CAPTURE_DIR="/workspace/$capture_dir_name" \
    -v "$workspace_dir:/workspace" \
    -v "$ssh_scope_dir:/root/.ssh:ro" \
    -v "$HOME/.config/gh:/root/.config/gh" \
    -v "$HOME/.copilot:/root/.copilot" \
    -v "$HOME/.aws:/root/.aws" \
    -v "$HOME/.azure:/root/.azure" \
    -v "$HOME/.kube:/root/.kube" \
    -w /workspace \
    "$image_name"
}

case "$command" in
  build)
    build_image "${2:-$image_name}"
    ;;
  restricted|discovery)
    run_container "$command" "${2:-$PWD}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
