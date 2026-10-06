#!/usr/bin/env bash
# summary:  container.env reaches the agent's shell and never the root entrypoint
# tags:     security delivery
# requires: docker launcher netadmin
#
# container.env is the project's APPLICATION environment (DB_HOST, POSTGRES_*),
# and whoever can commit to the project writes it. `docker run --env-file` hands
# it to the ROOT entrypoint, so XTABLES_LIBDIR=<dir> chose the plugins the
# firewall's own iptables loads, and ALLOWLIST_CIDRS_FILE the allowlist itself.
# Two halves keep it from root:
#
#   sandbox.sh (container_env_filter) refuses what acts before the entrypoint's
#     first line — LD_PRELOAD here — and keys it sets itself — SANDBOX_USER —
#     with a WARNING, and still launches;
#   the entrypoint (stash_app_env) sets every other key aside before it reads the
#     environment, and gives them back only to the sandbox user's processes.
#
# XTABLES_LIBDIR is the probe because no deny-list names it: it shows the
# entrypoint keeps from root even a key nobody thought of. Pointed at nothing, it
# would make restricted mode's first `iptables -m conntrack` fail and the
# container exit — so a firewall that comes up is the proof.
#
# What the agent's shell holds is read from /proc/1/environ, never `docker exec
# printenv`: a docker exec session gets the container's CONFIGURED environment,
# which holds container.env however the entrypoint treated it.
#
# Mutations 320, 321 and 322 demonstrate this case failing.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

scratch="$(it_scratch)"
cat > "$scratch/container.env" <<'EOF'
APP_GREETING=hello from container.env
XTABLES_LIBDIR=/nonexistent/xtables
LD_PRELOAD=/nonexistent/preload.so
SANDBOX_USER=root
EOF
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish

# ── 1. sandbox.sh refused what it must, and launched anyway ──────────────────
err="$(cat "$IT_LAUNCH_ERR")"
if grep -qF 'line 3 not passed to the container: LD_PRELOAD acts on' <<<"$err" \
   && grep -qF 'line 4 not passed to the container: the launcher sets SANDBOX_USER itself' <<<"$err"; then
  pass "the launch warned about LD_PRELOAD and SANDBOX_USER, and started"
else
  fail "the launch warned about LD_PRELOAD and SANDBOX_USER — stderr: $(grep WARNING <<<"$err" | tr '\n' ' ')"
fi

# ── 2. root never saw XTABLES_LIBDIR: restricted mode's firewall is up ───────
# Listed with XTABLES_LIBDIR removed, because this docker exec session itself
# carries the container's configured environment (see above).
rules="$(docker exec "$IT_CID" env -u XTABLES_LIBDIR iptables -S OUTPUT 2>&1)"
if grep -q -- '-P OUTPUT DROP' <<<"$rules" && grep -q -- '--match-set' <<<"$rules" \
   && grep -q -- '-j NFLOG' <<<"$rules"; then
  pass "XTABLES_LIBDIR from container.env never reached root: the firewall came up whole"
else
  fail "the restricted firewall is up — iptables -S OUTPUT: $(tr '\n' ' ' <<<"$rules")"
fi

# ── 3. root's own processes hold none of container.env ───────────────────────
# capture-blocked-traffic.sh is forked by the root entrypoint, after it set the
# keys aside, and stays root: its environment is the entrypoint's.
pid="$(docker exec "$IT_CID" sh -c 'for p in /proc/[0-9]*; do
  c="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
  case "$c" in *capture-blocked-traffic*) echo "${p#/proc/}"; break ;; esac
done')"
renv="$(docker exec "$IT_CID" sh -c "tr '\\0' '\\n' < /proc/$pid/environ" 2>/dev/null)"
if [[ -z "$pid" ]] || ! grep -q '^SANDBOX_UID=' <<<"$renv"; then
  fail "read a root daemon's environment (pid '${pid}') — nothing to judge, the checks below would pass vacuously"
elif grep -qE '^(APP_GREETING|XTABLES_LIBDIR|LD_PRELOAD)=' <<<"$renv"; then
  fail "a root process holds container.env: $(grep -E '^(APP_GREETING|XTABLES_LIBDIR|LD_PRELOAD)=' <<<"$renv" | tr '\n' ' ')"
else
  pass "a root daemon's environment holds none of container.env"
fi
grep -qx 'SANDBOX_USER=root' <<<"$renv" \
  && fail "container.env's SANDBOX_USER reached root" \
  || pass "the launcher's SANDBOX_USER is the one root used"

# ── 4. the agent's shell holds the application environment ───────────────────
aenv="$(agent_exec "$IT_CID" "tr '\\0' '\\n' < /proc/1/environ" 2>&1)"
if ! grep -q '^SANDBOX_UID=' <<<"$aenv"; then
  fail "read the agent shell's environment — got: $(head -c 300 <<<"$aenv" | tr '\n' ' ')"
else
  grep -qx 'APP_GREETING=hello from container.env' <<<"$aenv" \
    && pass "the agent's shell holds container.env's APP_GREETING, exactly" \
    || fail "the agent's shell holds APP_GREETING — it has: $(grep -E '^APP_' <<<"$aenv" | tr '\n' ' ')"
  grep -qx 'XTABLES_LIBDIR=/nonexistent/xtables' <<<"$aenv" \
    && pass "… and XTABLES_LIBDIR, which only root had to be kept from" \
    || fail "the agent's shell holds XTABLES_LIBDIR too"
  grep -q '^LD_PRELOAD=' <<<"$aenv" \
    && fail "a refused key reached the agent's shell: LD_PRELOAD" \
    || pass "a refused key reached no one (LD_PRELOAD)"
fi

it_finish
