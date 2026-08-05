#!/usr/bin/env bash
set -euo pipefail

mode="${DEV_CONTAINER_MODE:-restricted}"
domains_file="${ALLOWLIST_DOMAINS_FILE:-/tmp/allowlist-domains.txt}"
cidrs_file="${ALLOWLIST_CIDRS_FILE:-/tmp/allowlist-cidrs.txt}"
ipv4_set_name="${ALLOWLIST_IPV4_SET:-allowed_ipv4}"
ipv6_set_name="${ALLOWLIST_IPV6_SET:-allowed_ipv6}"
capture_dir="${DISCOVERY_CAPTURE_DIR:-/workspace/.agent-discovery}"
capture_enabled="${DISCOVERY_CAPTURE_ENABLED:-1}"
blocked_capture_dir="${BLOCKED_CAPTURE_DIR:-/workspace/.agent-blocked}"
blocked_capture_enabled="${BLOCKED_CAPTURE_ENABLED:-1}"
sandbox_user="${SANDBOX_USER:-user}"

# Install/refresh agent skills for the enabled AI agents, as the sandbox user.
# Offline and non-fatal — never blocks container start.
run_agent_skill_install() {
  [[ -x /usr/local/bin/install-agent-skills.sh ]] || return 0
  runuser -u "$sandbox_user" -- \
    env AI_AGENTS_ENABLED="${AI_AGENTS_ENABLED:-}" \
    bash /usr/local/bin/install-agent-skills.sh || true
}

# ~/.rvm is a docker NAMED VOLUME for named groups, and Docker creates a fresh one
# root-owned: it only copies ownership from the image for a path the image already
# contains, and /home/<user> is created at runtime. setup_sandbox_user's recursive
# chown uses -xdev, which by design does not cross into mounts. Without this the
# sandbox user cannot even open the reconcile lock. Non-recursive on purpose —
# rvm creates everything beneath as that user, and a seeded volume already carries
# the right ownership below the root.
chown_rvm_root() {
  [[ -n "${RUBY_VERSIONS:-}" ]] || return 0
  local d="/home/$sandbox_user/.rvm"
  [[ -d "$d" ]] || return 0
  chown "${SANDBOX_UID:-1000}:${SANDBOX_GID:-1000}" "$d" 2>/dev/null || true
}

# Bootstrap/reconcile the per-user rvm (~/.rvm, group-mounted) as the sandbox
# user. Offline-tolerant, non-fatal — never blocks container start.
run_ruby_reconcile() {
  [[ -n "${RUBY_VERSIONS:-}" ]] || return 0
  [[ -x /usr/local/bin/rvm-reconcile.sh ]] || return 0
  runuser -u "$sandbox_user" -- \
    env HOME="/home/$sandbox_user" RUBY_VERSIONS="${RUBY_VERSIONS}" \
    bash /usr/local/bin/rvm-reconcile.sh || true
}

# Expose the default Ruby on the global PATH (/usr/local/bin) so non-interactive,
# non-login shells resolve ruby/gem/bundle without sourcing rvm. Runs as ROOT (this
# writes /usr/local/bin) AFTER run_ruby_reconcile has set the default. Non-fatal.
link_default_ruby() {
  [[ -n "${RUBY_VERSIONS:-}" ]] || return 0
  [[ -x /usr/local/bin/link-default-ruby.sh ]] || return 0
  env RUBY_VERSIONS="${RUBY_VERSIONS}" \
    bash /usr/local/bin/link-default-ruby.sh "/home/$sandbox_user" || true
}

# Bootstrap/reconcile the enabled agent-tier tools into the group-mounted ~/.ai-tools
# as the sandbox user. Offline-tolerant, non-fatal — never blocks container start.
run_agent_tools_reconcile() {
  [[ -n "${AI_RUNTIME_TOOLS:-}" ]] || return 0
  [[ -x /usr/local/bin/agent-tools-reconcile.sh ]] || return 0
  runuser -u "$sandbox_user" -- \
    env HOME="/home/$sandbox_user" AI_RUNTIME_TOOLS="${AI_RUNTIME_TOOLS}" \
    bash /usr/local/bin/agent-tools-reconcile.sh || true
}

# Expose the enabled agent tools on the global PATH (/usr/local/bin) for non-interactive,
# non-login shells. Runs as ROOT AFTER run_agent_tools_reconcile. Non-fatal.
link_agent_tools() {
  [[ -n "${AI_RUNTIME_TOOLS:-}" ]] || return 0
  [[ -x /usr/local/bin/link-agent-tools.sh ]] || return 0
  env AI_RUNTIME_TOOLS="${AI_RUNTIME_TOOLS}" \
    bash /usr/local/bin/link-agent-tools.sh "/home/$sandbox_user" || true
}

# Create the sandbox user at startup with the host user's name, UID, and GID so
# that files in bind-mounted volumes (/workspace and its sub-mounts) are accessible
# without any chown. useradd -m creates the home directory with correct ownership.
setup_sandbox_user() {
  local uid="${SANDBOX_UID:-1000}"
  local gid="${SANDBOX_GID:-1000}"
  local username="${SANDBOX_USER:-user}"
  local groupname="${SANDBOX_GROUP:-user}"

  # Create group only if the GID is not yet known; fall back to a synthetic name
  # if the requested group name is already taken by a different GID.
  if ! getent group "$gid" &>/dev/null; then
    if getent group "$groupname" &>/dev/null; then
      groupname="sandbox_${gid}"
    fi
    groupadd -g "$gid" "$groupname"
  fi

  # Create or adopt the user for this UID.
  if getent passwd "$uid" &>/dev/null; then
    # UID already exists (e.g. ubuntu:24.04 ships 'ubuntu' at UID 1000).
    # Rename it to the desired username so $HOME paths align with bind-mount targets.
    local current_name
    current_name="$(getent passwd "$uid" | cut -d: -f1)"
    if [[ "$current_name" != "$username" ]]; then
      if getent passwd "$username" &>/dev/null; then
        username="sandbox_${uid}"
      fi
      # Rename without -m: the home dir may already exist as a Docker bind-mount
      # target; usermod -m refuses to move into an existing directory.
      usermod -l "$username" -d "/home/$username" -g "$gid" "$current_name"
    fi
  else
    # UID is new — create the user without a home dir; we set it up below.
    if getent passwd "$username" &>/dev/null; then
      username="sandbox_${uid}"
    fi
    useradd -M -s /bin/bash -u "$uid" -g "$gid" -d "/home/$username" "$username"
  fi

    # Ensure the home directory exists with skel defaults and correct ownership.
  # cp -rn (no-clobber) won't overwrite bind-mounted subdirectories like .ssh.
  # chown uses -xdev to recurse fully without crossing into bind-mounted volumes.
  local home_dir="/home/$username"
  mkdir -p "$home_dir"
  cp -rn /etc/skel/. "$home_dir/" 2>/dev/null || true
  # Recursively chown only the container's own filesystem, skipping bind-mounted
  # volumes (.ssh, .copilot, .config/gh, .local/share/kiro-cli, etc.) by using
  # -xdev to stay on the same filesystem as $home_dir.
  chown "$uid:$gid" "$home_dir"
  find "$home_dir" -xdev -exec chown "$uid:$gid" {} + 2>/dev/null || true

  sandbox_user="$(getent passwd "$uid" | cut -d: -f1)"
}

# /workspace is an in-image umbrella directory (root-owned by default) onto which
# repos, extra mounts, the vault, and the output dirs are mounted as subdirs. Make
# the umbrella root itself writable by the sandbox user so it can cd/create there;
# sub-mounts under it carry their own ownership and are untouched (no -R).
chown_workspace_root() {
  mkdir -p /workspace
  chown "${SANDBOX_UID:-1000}:${SANDBOX_GID:-1000}" /workspace 2>/dev/null || true
}

apply_restricted_firewall() {
  /usr/local/bin/refresh-ipset-allowlist.sh \
    "$domains_file" \
    "$cidrs_file" \
    "$ipv4_set_name" \
    "$ipv6_set_name"

  iptables -F OUTPUT
  iptables -P OUTPUT DROP
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  iptables -A OUTPUT -m set --match-set "$ipv4_set_name" dst -j ACCEPT
  # Send blocked packets to userspace via NFLOG so capture-blocked-traffic.sh
  # can read them with tshark.  The classic LOG target writes to the kernel ring
  # buffer (dmesg), but many environments — notably WSL2 with the nf_tables
  # backend — silently drop those messages.  NFLOG works everywhere.
  iptables -A OUTPUT -j NFLOG --nflog-prefix "BLOCKED" --nflog-group 100

  # IPv6 firewall — some WSL2 / container kernels lack ip6table_filter; skip gracefully.
  if ip6tables -F OUTPUT 2>/dev/null; then
    ip6tables -P OUTPUT DROP
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
    ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    ip6tables -A OUTPUT -m set --match-set "$ipv6_set_name" dst -j ACCEPT
    ip6tables -A OUTPUT -j NFLOG --nflog-prefix "BLOCKED" --nflog-group 100
  else
    printf '╔══════════════════════════════════════════════════════════════════╗\n' >&2
    printf '║  WARNING: ip6tables not available — IPv6 egress is UNRESTRICTED  ║\n' >&2
    printf '║  The firewall only covers IPv4. Any IPv6-capable destination     ║\n' >&2
    printf '║  can be reached without restriction.                             ║\n' >&2
    printf '║  To suppress: set ALLOW_IPV6_BYPASS=1                            ║\n' >&2
    printf '╚══════════════════════════════════════════════════════════════════╝\n' >&2
    if [[ "${ALLOW_IPV6_BYPASS:-0}" != "1" ]]; then
      printf 'Hint: set ALLOW_IPV6_BYPASS=1 to acknowledge this and hide the warning.\n' >&2
    fi
  fi

  # Background ipset refresh: runs as root, retains NET_ADMIN after exec capsh below.
  (
    while sleep 60; do
      /usr/local/bin/refresh-ipset-allowlist.sh \
        "$domains_file" \
        "$cidrs_file" \
        "$ipv4_set_name" \
        "$ipv6_set_name" || \
        printf 'WARNING: ipset refresh failed at %s — using stale allowlist\n' "$(date -u '+%Y-%m-%dT%H:%M:%S')" >&2
    done
  ) &
}

apply_discovery_firewall() {
  iptables -F OUTPUT
  iptables -P OUTPUT ACCEPT

  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

  if [[ "$capture_enabled" == "1" ]]; then
    /usr/local/bin/capture-agent-destinations.sh start "$capture_dir"
    local host_workspace="${HOST_WORKSPACE_DIR:-\$(pwd)}"
    printf 'Discovery capture started in %s\n' "$capture_dir"
    printf 'When done, exit the container (Ctrl+D). The pcap file persists on the host.\n'
    printf 'Then extract DNS and TLS hostname lists with:\n'
    printf '  docker run --rm --entrypoint capture-agent-destinations.sh \\\n'
    printf '    -v "%s:/workspace" %s extract %s\n' "$host_workspace" "${IMAGE_NAME:-ai-sandbox}" "$capture_dir"
  fi
}

case "$mode" in
  restricted)
    apply_restricted_firewall
    setup_sandbox_user
    chown_workspace_root

    printf '╔══════════════════════════════════════════════════════════════════╗\n'
    printf '║  NOTE: DNS (port 53) is unrestricted — all resolvers reachable. ║\n'
    printf '║  DNS tunneling is theoretically possible. For higher security,  ║\n'
    printf '║  add --dns 8.8.8.8 to the docker run command and restrict the   ║\n'
    printf '║  iptables DNS rules in entrypoint.sh to a specific resolver.    ║\n'
    printf '╚══════════════════════════════════════════════════════════════════╝\n'

    # Start the blocked-traffic capture daemon before dropping capabilities.
    # This process is forked here as root and retains CAP_NET_RAW after the exec below.
    if [[ "$blocked_capture_enabled" == "1" ]]; then
      mkdir -p "$blocked_capture_dir"
      /usr/local/bin/capture-blocked-traffic.sh \
        "$blocked_capture_dir" &
    fi

    # Hand control to the sandbox user with dangerous capabilities dropped.
    # Background processes forked above are unaffected by this exec and keep their capabilities.
    chown_rvm_root
    run_ruby_reconcile
    link_default_ruby
    run_agent_tools_reconcile
    link_agent_tools
    run_agent_skill_install

    exec capsh \
      --drop=cap_net_admin,cap_net_raw \
      --user="$sandbox_user" \
      -- -l
    ;;
  discovery)
    apply_discovery_firewall
    setup_sandbox_user
    chown_workspace_root

    # Run the interactive shell as the sandbox user so that files created
    # during discovery (e.g. agent sessions in ~/.copilot, ~/.kiro, ~/.config/gh)
    # are owned by the sandbox UID/GID — not root. This prevents permission
    # errors when the container is later run in restricted mode.
    # NET_RAW is kept (not dropped) so the sandbox user can run tcpdump if needed.
    chown_rvm_root
    run_ruby_reconcile
    link_default_ruby
    run_agent_tools_reconcile
    link_agent_tools
    run_agent_skill_install

    exec capsh \
      --drop=cap_net_admin \
      --user="$sandbox_user" \
      -- -l
    ;;
  open)
    setup_sandbox_user
    chown_workspace_root

    printf '╔══════════════════════════════════════════════════════════════════╗\n'
    printf '║  OPEN MODE: outbound network is UNRESTRICTED and NOT captured.   ║\n'
    printf '║  No firewall, no allowlist, no traffic logging. Use only for     ║\n'
    printf '║  projects that do not require network isolation.                 ║\n'
    printf '╚══════════════════════════════════════════════════════════════════╝\n'

    chown_rvm_root
    run_ruby_reconcile
    link_default_ruby
    run_agent_tools_reconcile
    link_agent_tools
    run_agent_skill_install

    exec capsh \
      --drop=cap_net_admin,cap_net_raw \
      --user="$sandbox_user" \
      -- -l
    ;;
  *)
    printf 'Unsupported DEV_CONTAINER_MODE: %s\n' "$mode" >&2
    exit 1
    ;;
esac

