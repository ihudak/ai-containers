#!/usr/bin/env bash
# minimal-conf.sh <source sandbox.conf> [key=value…] → a minimal conf on stdout
#
# Every optional component OFF and every version list emptied. Two callers, one
# definition, deliberately:
#
#   run.sh build_image  — the firewall does not know which fragment a domain
#                         came from, so proving admit/drop once proves it for
#                         every fragment; N per-component images buy nothing.
#   lib.sh launcher_up  — a case drives the REAL sandbox.sh, which reads
#                         sandbox.conf at LAUNCH time, not build time. Without
#                         this the launcher would read the developer's own conf:
#                         a `ruby=3.4.5` there creates a group rvm volume and
#                         bootstraps rvm over the network before the agent shell
#                         appears, turning a 10-second mount case into a
#                         multi-minute one whose failures have nothing to do
#                         with mounts.
#
# They must agree. When they drifted apart in an earlier draft the image had a
# component the launcher then did not mount, and the case failed on a missing
# directory that was correct behaviour.
#
# Overrides are applied AFTER the minimisation, so `launcher_conf claude-code=ON`
# turns exactly one component back on and leaves the rest off.
set -uo pipefail

src="${1:?minimal-conf.sh: source sandbox.conf required}"
shift || true
[[ -f "$src" ]] || { printf 'minimal-conf.sh: no such file: %s\n' "$src" >&2; exit 1; }

# GUARDED. This file carries no errexit and its STDOUT is a sandbox.conf, so an
# empty $tmp makes the sed redirect fail and the closing `cat "$tmp"` print
# nothing — the caller writes an EMPTY config.
#
# What it does NOT do is let that pass unnoticed, and the distinction is worth
# writing down rather than overstating: the only caller
# (tests/integration/run.sh:633) already does `… > "$conf" || { … }`, and the
# failing `cat` exits non-zero, so the run stops either way. What changes is
# WHAT IT SAYS — one named line on stderr instead of zero bytes on stdout and a
# bare non-zero to work backwards from.
tmp="$(mktemp)" || { printf 'minimal-conf.sh: mktemp failed — refusing to emit a config, because an empty one would be accepted silently\n' >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT

sed -E 's/^([a-z0-9-]+)=ON$/\1=OFF/; s/^(node|python|ruby|rust|go|openjdk|graalvm-ce|graalvm-oracle|kotlin|scala|maven|gradle|db-clients|angular-cli)=.*/\1=/' \
  "$src" > "$tmp"

for kv in "$@"; do
  key="${kv%%=*}"; val="${kv#*=}"
  if grep -qE "^${key}=" "$tmp"; then
    # -i.bak, not -i: BSD sed (stock macOS) requires an argument to -i, and this
    # suite runs there too.
    sed -i.bak -E "s|^${key}=.*|${key}=${val}|" "$tmp" && rm -f "$tmp.bak"
  else
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
done

cat "$tmp"
