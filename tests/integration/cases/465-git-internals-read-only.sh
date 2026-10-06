#!/usr/bin/env bash
# summary:  a repository's .git hooks and config are read-only inside the container; committing still works
# tags:     security mounts fast
# requires: docker launcher
#
# The documented launch mounts the whole project read-write, .git included, and
# the HOST's git runs what .git holds: hooks/ at the next commit, and config
# keys that run programs (core.hooksPath, core.fsmonitor, core.sshCommand,
# filters) at the next commit or even `git status`. None of it shows in git
# status or git diff. sandbox.sh mounts hooks/ and config read-only in place and
# pins .git, so it cannot be renamed out from under them.
# tests/test-git-internals-ro.sh checks the ARGUMENTS it builds; this checks
# that the container the agent gets refuses each write, and still commits.
#
# Paired, as in cases 400 and 450: the agent writes the project and commits to
# it with the same primitive that fails on .git's internals, so "cannot write"
# can be neither "nothing is writable" nor "git is broken here".
#
# Mutations 465, 466 and 467 demonstrate this case failing.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

proj="$(it_scratch)/proj"
launcher_engine_in "$proj" || it_finish
hostgit() { git -C "$proj" -c user.email=host@example.invalid -c user.name=host "$@"; }
if ! { hostgit init -q -b main && printf 'x\n' > "$proj/README" && hostgit add README && hostgit commit -qm init; }; then
  fail "could not create the project repository on the host"; it_finish
fi
before="$(cat "$proj/.git/config")"

# open mode: this case is about mounts, as 450 is.
launcher_up open "$proj" || it_finish
agit() { agent_exec "$IT_CID" "cd /workspace/proj && git -c user.email=agent@example.invalid -c user.name=agent $1"; }

assert_writable "$IT_CID" /workspace/proj

# Committing is what the agent is there to do: objects, refs and the index.
if agit "commit -q --allow-empty -m from-the-agent" >/dev/null 2>&1 \
   && [[ "$(hostgit log -1 --format=%s)" == from-the-agent ]]; then
  pass "the agent commits, and the host sees the commit"
else
  fail "the agent commits, and the host sees the commit (host HEAD: $(hostgit log -1 --format=%s))"
fi

# A hook the host's next `git commit` would run.
if agent_exec "$IT_CID" 'echo "touch /tmp/pwned" > /workspace/proj/.git/hooks/pre-commit' >/dev/null 2>&1; then
  fail "the agent cannot write .git/hooks/pre-commit — the write SUCCEEDED"
else
  pass "the agent cannot write .git/hooks/pre-commit"
fi
[[ ! -e "$proj/.git/hooks/pre-commit" ]] && pass "the host has no pre-commit hook" \
  || fail "the host has no pre-commit hook — it has one"

# A config key that runs a program on the host — or points hooks elsewhere.
agit "config core.hooksPath /workspace/proj/hooks" >/dev/null 2>&1
[[ -z "$(hostgit config --get core.hooksPath)" && "$(cat "$proj/.git/config")" == "$before" ]] \
  && pass "the agent cannot change .git/config (core.hooksPath unset, the file unchanged)" \
  || fail "the agent cannot change .git/config — core.hooksPath is '$(hostgit config --get core.hooksPath)'"

# git reads .git/commondir in ANY git directory, and a repository's own has
# none — written by the agent, it would point the host's git at a config and
# hooks of its own. sandbox.sh makes one holding `.` and mounts it read-only.
if agent_exec "$IT_CID" 'printf "../planted\n" > /workspace/proj/.git/commondir' >/dev/null 2>&1; then
  fail "the agent cannot write .git/commondir — the write SUCCEEDED"
else
  pass "the agent cannot write .git/commondir"
fi
[[ "$(cat "$proj/.git/commondir" 2>/dev/null)" == . && "$(hostgit rev-parse --git-common-dir)" == "$proj/.git" ]] \
  && pass "the host's git still takes its config and hooks from .git itself" \
  || fail "the host's git still takes its config and hooks from .git itself — common dir: $(hostgit rev-parse --git-common-dir)"

# The overlays are mounts on .git's entries; without the pin, renaming .git
# would carry them away and leave room for a .git of the agent's own.
if agent_exec "$IT_CID" 'mv /workspace/proj/.git /workspace/proj/.git-away' >/dev/null 2>&1; then
  fail "the agent cannot rename .git — the rename SUCCEEDED"
else
  pass "the agent cannot rename .git away from the read-only mounts"
fi
[[ -d "$proj/.git" && ! -e "$proj/.git-away" ]] && pass "the host's .git is where it was" \
  || fail "the host's .git is where it was"

it_finish
