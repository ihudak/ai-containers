#!/usr/bin/env bash
# summary:  PREVIEW_PORTS makes an in-container dev server answer from the host
# tags:     mounts fast
# requires: docker launcher
#
# PREVIEW_PORTS is the one launcher feature whose failure a developer meets as
# "my dev server doesn't work" with no error anywhere: sandbox.sh builds -p
# flags, docker accepts them, the container starts fine, and the browser just
# hangs. Nothing in the repo checked that the mapping arrives.
#
# The assertion is deliberately the RESPONSE BODY, not merely "something
# answered on that port". A host port that happens to be occupied by an
# unrelated service would satisfy a connect-only check and report a working
# publish for a container that published nothing. The port is confirmed free
# before the launch for the same reason.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# A port nothing is listening on right now. Connecting SUCCEEDS when something
# already holds it, which is the case to reject.
pick_free_port() {
  local p i
  for i in 1 2 3 4 5 6 7 8; do
    p=$(( 20000 + RANDOM % 20000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
    exec 3<&- 2>/dev/null || true
  done
  return 1
}

hostport="$(pick_free_port)"
if [[ -n "$hostport" ]]; then
  pass "found a free host port ($hostport)"
else
  fail "found a free host port — eight candidates were all in use"
  it_finish
fi

launcher_prepare || it_finish
export PREVIEW_PORTS="$hostport:8080"
launcher_up open || it_finish

# Same shape as lib.sh's sidecar, run as the agent user: a dev server is
# something the AGENT starts, and a root-only listener would prove less.
docker exec -d -u "$IT_LAUNCH_UID:$IT_LAUNCH_GID" "$IT_CID" \
  node -e 'require("http").createServer(function(q,s){s.end("preview-ok\n")}).listen(8080,"0.0.0.0")' \
  >/dev/null 2>&1

if it_wait 30 docker exec "$IT_CID" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080'; then
  pass "the dev server is listening inside the container"
else
  fail "the dev server is listening inside the container — nothing to publish"
  it_finish
fi

# From the HOST. This is the whole case.
got=""
for _ in $(seq 1 15); do
  got="$(curl -fsS --max-time 3 "http://127.0.0.1:$hostport/" 2>/dev/null | tr -d '\r\n')"
  [[ -n "$got" ]] && break
  sleep 1
done
if [[ "$got" == "preview-ok" ]]; then
  pass "the host reaches the container's dev server on $hostport"
else
  fail "the host reaches the container's dev server on $hostport — got '${got:-<nothing>}'"
  docker port "$IT_CID" 2>&1 | sed 's/^/     published: /'
fi

it_finish
