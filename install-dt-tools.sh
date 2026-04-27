#!/usr/bin/env bash
# install-dt-tools.sh — installs dtctl and/or dtmgd from GitHub releases.
# Called during Docker build via: RUN --mount=type=secret,id=github_token ...
#
# Env vars:
#   DTCTL_VERSION  "latest" | "x.y.z" | "" (skip)
#   DTMGD_VERSION  "latest" | "x.y.z" | "" (skip)
#   GITHUB_TOKEN   optional; raises GitHub API rate limit from 60 to 5000 req/h
#
# Non-fatal: rate-limit failures print a clear error and exit 0.
set -euo pipefail

ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "GitHub token provided — using authenticated API (5000 req/h limit)."
  AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
else
  echo "No GITHUB_TOKEN — using unauthenticated GitHub API (60 req/h limit)."
  echo "Tip: if this fails, export GITHUB_TOKEN on your host and run: ./runme.sh build"
  echo "     Or pin a specific version in sandbox.conf, e.g.: dtctl=0.25.0"
  AUTH_ARGS=()
fi

gh_latest_tag() {
  local repo="$1" tag="" i
  # NOTE: Parses JSON with grep/sed because jq is not available at this build stage.
  # This is fragile if the GitHub API response format changes.
  for i in 1 2 3; do
    tag=$(curl -fsSL ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "https://api.github.com/repos/${repo}/releases/latest" \
          | grep '"tag_name"' | head -1 \
          | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [ -n "$tag" ] && break
    echo "Attempt $i failed, retrying in 5s..." >&2; sleep 5
  done
  if [ -z "$tag" ]; then
    echo "ERROR: Could not fetch latest release tag for ${repo}." >&2
    echo "       GitHub API rate limit may have been exceeded." >&2
    echo "       Fix: export GITHUB_TOKEN=<token> then run: ./runme.sh build" >&2
    echo "       Or pin a version in sandbox.conf, e.g.: dtctl=0.25.0" >&2
  fi
  printf '%s' "$tag"
}

install_tool() {
  local repo="$1" name="$2" version="$3"

  if [ -z "$version" ]; then
    return 0  # skip
  fi

  local tag
  if [ "$version" = "latest" ]; then
    tag=$(gh_latest_tag "$repo")
    if [ -z "$tag" ]; then
      echo "WARNING: Skipping ${name} — could not determine latest version."
      return 0
    fi
  else
    # Normalize: accept "0.25.0" or "v0.25.0"
    tag="v${version#v}"
  fi

  echo "Installing ${name} ${tag}..."
  if ! curl -fsSL "https://github.com/${repo}/releases/download/${tag}/${name}_${tag#v}_${OS}_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin "$name"; then
    echo "WARNING: Failed to download/extract ${name} ${tag} — skipping."
    echo "         Check that version '${tag#v}' exists at https://github.com/${repo}/releases"
    return 0
  fi
  chmod +x "/usr/local/bin/${name}"
  echo "Installed ${name} ${tag}"
}

install_tool dynatrace-oss/dtctl  dtctl  "${DTCTL_VERSION:-}"
install_tool dynatrace-oss/dtmgd  dtmgd  "${DTMGD_VERSION:-}"
