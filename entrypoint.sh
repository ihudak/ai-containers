#!/usr/bin/env bash
set -euo pipefail

# container.env is the project's APPLICATION environment, and whoever can commit to
# the project writes it — yet `docker run --env-file` hands it to this ROOT process,
# where XTABLES_LIBDIR would choose the plugins iptables loads and ALLOWLIST_CIDRS_FILE
# the firewall's own allowlist. sandbox.sh names every key it passed from the file in
# AI_CONTAINER_ENV_KEYS; they are set aside here, before anything below reads the
# environment, and handed back only to processes that run as the sandbox user
# (as_sandbox_user, and the final shell). What acts before this line can — the
# loader, env(1)'s PATH search for bash, bash's own start-up — sandbox.sh refuses
# outright (sandbox.sh: container_env_filter()).
# Every name here starts _aice_, which sandbox.sh refuses from container.env: a
# key named like a variable of this function (k, set, app_env…) would otherwise
# be unset in its place — aborting the entrypoint under set -u, leaving the key
# in root's environment, or emptying what was stashed. The list is split by
# parameter expansion, not `read` (which a TMOUT key would time out) nor an
# unquoted word list (which would glob, letting a file name a key). `unset -v`,
# because a bare unset of a name with no variable removes a FUNCTION of that
# name. A name bash will not unset (readonly, such as PPID) holds bash's value,
# not the file's, and is left alone.
_aice_app_env=()
stash_app_env() {
  local _aice_rest="${AI_CONTAINER_ENV_KEYS:-}" _aice_k _aice_v _aice_set
  while [[ -n "$_aice_rest" ]]; do
    _aice_k="${_aice_rest%% *}"
    if [[ "$_aice_rest" == *' '* ]]; then _aice_rest="${_aice_rest#* }"; else _aice_rest=""; fi
    [[ "$_aice_k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$_aice_k" != _aice_* ]] || continue
    _aice_set=0; _aice_v=""
    if [[ -n "${!_aice_k+x}" ]]; then _aice_set=1; _aice_v="${!_aice_k}"; fi
    unset -v "$_aice_k" 2>/dev/null || continue
    if (( _aice_set )); then _aice_app_env+=("$_aice_k=$_aice_v"); fi
  done
  unset AI_CONTAINER_ENV_KEYS
}
stash_app_env

# runuser … -- <command> as the sandbox user, with container.env given back.
as_sandbox_user() {
  runuser -u "$sandbox_user" -- env ${_aice_app_env[@]+"${_aice_app_env[@]}"} "$@"
}

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
  as_sandbox_user \
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
  as_sandbox_user \
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
  as_sandbox_user \
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

# Start the in-container database servers sandbox.conf enabled (AI_SERVICES).
# `prepare` runs as ROOT and creates directories and hands them to the sandbox
# user; `start` runs as the sandbox user, so no server process is ever root. Both
# are non-fatal: a server that fails to start must not cost the user their shell.
# The runner's path is fixed on purpose: no project data file may choose what
# root executes. For the same reason root's prepare starts from an EMPTY
# environment (env -i) holding only a fixed PATH, AI_SERVICES and
# SANDBOX_UID/GID: an adapter reads its own knobs in prepare too (the postgres
# one runs "<lib root>/<major>/bin/postgres --version" and chowns its socket
# directory), so stripping a named few would leave every knob added later
# reaching root — container.env is set aside from root already (stash_app_env),
# and prepare does not depend on that alone. `start` runs as the sandbox user
# with container.env given back, since it needs its POSTGRES_* — minus the
# runner's test-only path overrides, so prepare and start agree on the
# directories.
run_services() {
  [[ -n "${AI_SERVICES:-}" ]] || return 0
  [[ -x /usr/local/bin/start-services.sh ]] || return 0
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    AI_SERVICES="$AI_SERVICES" SANDBOX_UID="${SANDBOX_UID:-1000}" SANDBOX_GID="${SANDBOX_GID:-1000}" \
    /usr/local/bin/start-services.sh prepare || true
  local kv start_env=()
  for kv in ${_aice_app_env[@]+"${_aice_app_env[@]}"}; do
    case "${kv%%=*}" in
      AI_SERVICES_DIR|AI_SERVICES_STATE_ROOT|AI_SERVICES_LOG_ROOT) ;;
      *) start_env+=("$kv") ;;
    esac
  done
  runuser -u "$sandbox_user" -- env -u AI_SERVICES_DIR -u AI_SERVICES_STATE_ROOT -u AI_SERVICES_LOG_ROOT \
    ${start_env[@]+"${start_env[@]}"} /usr/local/bin/start-services.sh start || true
}

# Create the sandbox user at startup with the host user's name, UID, and GID so
# that files in bind-mounted volumes (/workspace and its sub-mounts) are accessible
# without any chown. useradd -m creates the home directory with correct ownership.
# useradd warns for EVERY macOS host user:
#
#   useradd warning: ivan's uid 502 outside of the UID_MIN 1000 and UID_MAX 60000 range.
#
# macOS starts human UIDs at 501; shadow-utils expects 1000+. Matching the host
# UID is the ENTIRE POINT of this design — it is what makes bind-mounted files
# writable without a chown — so that line describes the feature working, and it
# is one of the first things a new user sees on every single start.
#
# Dropped BY PATTERN, not by silencing the command: every other line of stderr
# is passed through and the exit status is preserved, because a useradd that
# genuinely fails must still say so and still stop the start.
useradd_matching_host_uid() {
  local err rc=0
  # useradd writes nothing to stdout, so capturing stderr alone loses nothing.
  err="$(useradd "$@" 2>&1 >/dev/null)" || rc=$?
  if [[ -n "$err" ]]; then
    grep -v 'outside of the UID_MIN' <<<"$err" >&2 || true
  fi
  return "$rc"
}

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
    useradd_matching_host_uid -M -s /bin/bash -u "$uid" -g "$gid" -d "/home/$username" "$username"
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
  trust_repositories_for_sandbox_user
}

# git refuses a repository another user owns ("detected dubious ownership"), and
# on Colima a host bind's mount root shows as owned by root in here, so git
# refused every command in a host-path primary. Trust every repository for the
# SANDBOX USER ONLY, in its own global config. Never in the image's system
# config: root reads that too, and root's git would then run what an agent wrote
# into a repository's .git/config (core.fsmonitor, a hook) the first time a
# `docker exec` as root, docker's default here, ran git in it. That is root with
# the container's NET_ADMIN, which can lift the firewall.
#
# ~/.config/git/config, not ~/.gitconfig: that one is the host's, mounted
# read-only. Written AS the user, so root never writes into a directory the
# agent owns. A failure costs git on Colima, not the start. Case 315 asserts both.
trust_repositories_for_sandbox_user() {
  # shellcheck disable=SC2016  # expanded by the user's shell, with its HOME
  as_sandbox_user sh -c 'mkdir -p "$HOME/.config/git" &&
    git config --file "$HOME/.config/git/config" --replace-all safe.directory "*"' \
    || printf 'WARNING: could not set safe.directory for %s; git may refuse a mounted repository\n' "$sandbox_user" >&2
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
    printf 'Then, ON THE HOST, in %s:\n' "$host_workspace"
    printf '  ./extract-discovery.sh             # hostname lists + what this image would block\n'
    printf '  ./extract-discovery.sh --clean     # ... and delete the pcap once extracted\n'
    printf '  ./extract-discovery.sh --discard   # drop the capture without extracting it\n'
    printf 'That script ships beside sandbox.sh. If you launched from somewhere it is not:\n'
    printf '  docker run --rm --entrypoint capture-agent-destinations.sh \\\n'
    printf '    -v "%s:/workspace" %s extract %s\n' "$host_workspace" "${IMAGE_NAME:-ai-sandbox}" "$capture_dir"
  fi
}

# Refuse to start if a launcher mount is not the directory sandbox.sh resolved.
# sandbox.sh records each launcher overlay/pin source's device:inode and its
# destination in /run/ai-launcher/manifest, mounted read-only from a directory
# only that launch could reach. A concurrent container sharing a writable tree
# could swap a mount's SOURCE for a symlink between sandbox.sh's scan and the
# moment Docker resolved it, so this new container would have mounted an
# arbitrary host path — writable, for a pin. Re-checking here, as root and
# before the agent shell exists, closes that window: a swapped mount lands on a
# different inode (verified), so its device:inode no longer matches.
#
# The verify directory is itself the anchor: AI_LAUNCHER_ANCHOR is its own
# device:inode as sandbox.sh saw it. If that does not survive the mount, this
# filesystem does not preserve device:inode across a bind (some file-sharing
# layers do not), so no mount here can be checked that way — say so and skip,
# rather than refuse every launch. Nothing an agent writes can reach this: the
# manifest and the anchor come from sandbox.sh's own -v/-e, not container.env.
verify_launcher_mounts() {
  [[ -n "${AI_LAUNCHER_ANCHOR:-}" && -f /run/ai-launcher/manifest ]] || return 0
  local got dev ino dst bad=0
  got="$(stat -c '%d:%i' /run/ai-launcher 2>/dev/null || true)"
  if [[ "$got" != "$AI_LAUNCHER_ANCHOR" ]]; then
    # Expected on every launch on such a host (macOS file sharing), and nothing
    # to act on there: one line, not an alarm people learn to skip.
    printf 'NOTE: this filesystem does not preserve device/inode across a bind mount; launcher mounts are not verified against a concurrent-container swap.\n' >&2
    return 0
  fi
  while IFS= read -r -d '' dev && IFS= read -r -d '' ino && IFS= read -r -d '' dst; do
    got="$(stat -c '%d:%i' "$dst" 2>/dev/null || true)"
    if [[ "$got" != "$dev:$ino" ]]; then
      printf 'ERROR: %s is not the directory it was checked as (expected %s, got %s).\n' "$dst" "$dev:$ino" "${got:-none}" >&2
      bad=1
    fi
  done < /run/ai-launcher/manifest
  if (( bad )); then
    printf 'ERROR: a launcher mount changed between the host scan and the mount — refusing to\n' >&2
    printf '       start. A container already running on an overlapping tree may have swapped\n' >&2
    printf '       it. Stop other containers on this workspace and relaunch.\n' >&2
    exit 1
  fi
}

verify_launcher_mounts

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
    # In every mode the shell capsh starts as that user gives container.env back
    # (stash_app_env) and execs the login shell — after the switch, so no root
    # process ever holds it.
    chown_rvm_root
    run_ruby_reconcile
    link_default_ruby
    run_agent_tools_reconcile
    link_agent_tools
    run_agent_skill_install
    run_services

    exec capsh \
      --drop=cap_net_admin,cap_net_raw \
      --user="$sandbox_user" \
      -- -c 'exec env "$@" /bin/bash -l' bash ${_aice_app_env[@]+"${_aice_app_env[@]}"}
    ;;
  discovery)
    apply_discovery_firewall
    setup_sandbox_user
    chown_workspace_root

    # This is the only mode combining unrestricted egress with a pcap that
    # persists on the host after the container exits — say so plainly, the
    # same way restricted/open state their own risk, so a user cannot land
    # here without knowing traffic is both unfiltered and being recorded.
    printf '╔══════════════════════════════════════════════════════════════════╗\n'
    printf '║  DISCOVERY MODE: outbound network is UNRESTRICTED (no firewall,  ║\n'
    printf '║  no allowlist). ALL traffic is being captured to a pcap that     ║\n'
    printf '║  persists on the host after this container exits — a pcap can    ║\n'
    printf '║  contain sensitive material from this session.                   ║\n'
    printf '╚══════════════════════════════════════════════════════════════════╝\n'

    # Run the interactive shell as the sandbox user so that files created
    # during discovery (e.g. agent sessions in ~/.copilot, ~/.kiro, ~/.config/gh)
    # are owned by the sandbox UID/GID — not root. This prevents permission
    # errors when the container is later run in restricted mode.
    # The --drop below names only cap_net_admin, but the agent shell ends up with
    # NO capabilities at all: capsh --user= setuids from root, and the kernel
    # clears the permitted and effective sets on that transition unless
    # PR_SET_KEEPCAPS is set (capsh --keep=1, which is not used here). So
    # --drop=cap_net_admin and --drop=cap_net_admin,cap_net_raw are equivalent.
    #
    # This comment used to claim "NET_RAW is kept so the sandbox user can run
    # tcpdump if needed". That never worked, and keeping it would be the wrong
    # fix: the pcap daemon is started as ROOT (`capture-agent-destinations.sh start`), before the exec below,
    # so it retains its own capabilities and needs nothing from the agent shell.
    # Granting the agent raw-socket access to satisfy a comment would widen its
    # capability surface for a convenience nobody has asked for, in a mode that
    # already captures everything automatically. Case 230-discovery-drops-
    # capabilities asserts the drop.
    chown_rvm_root
    run_ruby_reconcile
    link_default_ruby
    run_agent_tools_reconcile
    link_agent_tools
    run_agent_skill_install
    run_services

    exec capsh \
      --drop=cap_net_admin \
      --user="$sandbox_user" \
      -- -c 'exec env "$@" /bin/bash -l' bash ${_aice_app_env[@]+"${_aice_app_env[@]}"}
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
    run_services

    exec capsh \
      --drop=cap_net_admin,cap_net_raw \
      --user="$sandbox_user" \
      -- -c 'exec env "$@" /bin/bash -l' bash ${_aice_app_env[@]+"${_aice_app_env[@]}"}
    ;;
  *)
    printf 'Unsupported DEV_CONTAINER_MODE: %s\n' "$mode" >&2
    exit 1
    ;;
esac

