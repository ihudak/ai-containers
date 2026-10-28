#!/usr/bin/env bash
# Tests the sandbox.env/sandbox.local.env loader (load_env_defaults, precedence
# inline > local > portable) and sandbox.sh's SANDBOX_MODE/SANDBOX_WORKDIR defaulting.
# NOTE: tests/test-env-file.sh covers a DIFFERENT layer (in-container container.env).
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR PREVIEW_PORTS
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass() { printf 'PASS: %s\n' "$1"; }; fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/sandbox-common.sh" && pass "sandbox-common.sh bash -n" || fail "sandbox-common.sh bash -n"
bash -n "$REPO_DIR/sandbox.sh"        && pass "sandbox.sh bash -n"        || fail "sandbox.sh bash -n"

# Load the REAL load_env_defaults + its env_key_denied helper (extract just the
# functions so the file's heavy top-level code does not run).
eval "$(sed -n '/^env_key_denied()/,/^}/p;/^env_key_portable()/,/^}/p;/^env_key_machine_only()/,/^}/p;/^env_value_portable()/,/^}/p;/^_image_repo()/,/^}/p;/^env_portable_workdir()/,/^}/p;/^env_key_tool_config()/,/^}/p;/^load_env_defaults()/,/^}/p' "$REPO_DIR/sandbox-common.sh")"
type load_env_defaults >/dev/null 2>&1 && pass "load_env_defaults defined" || { fail "load_env_defaults defined"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
type env_key_denied >/dev/null 2>&1 && pass "env_key_denied defined" || { fail "env_key_denied defined"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# Apply exactly as sandbox-common.sh does: local first, then portable.
apply() { load_env_defaults "$LOCAL" local; load_env_defaults "$PORTABLE" portable; }
# This file runs under `set -uo pipefail` with NO errexit, so an unguarded
# mktemp leaves an EMPTY path and every assertion after it measures the
# wreckage rather than the loader (falsify backlog F31). SCAFFOLD-FAILED: is the
# channel tests/run-all.sh and the mutation tier both read to say "this run
# never got as far as asserting", instead of scoring the wall of failures that
# follows as a real result.
# Laid out as project-init.sh lays them out — <project>/.ai-containers/ — because a
# portable SANDBOX_WORKDIR is judged against the project that holds the file.
mk() {
  MKD="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d (env files)\n'; exit 1; }
  MKD="$(cd "$MKD" && pwd -P)"; PROJROOT="$MKD/proj"
  mkdir -p "$PROJROOT/.ai-containers" || { printf 'SCAFFOLD-FAILED: mkdir (env files)\n'; exit 1; }
  LOCAL="$PROJROOT/.ai-containers/sandbox.local.env"; PORTABLE="$PROJROOT/.ai-containers/sandbox.env"
  : > "$LOCAL"; : > "$PORTABLE"
}
rmk() { rm -rf "$MKD"; }

# precedence: inline > local > portable
mk; printf 'CONTAINER_MEMORY=2g\n' > "$PORTABLE"; printf 'CONTAINER_MEMORY=4g\n' > "$LOCAL"
( unset CONTAINER_MEMORY; export CONTAINER_MEMORY=8g; apply; [[ "$CONTAINER_MEMORY" == 8g ]] ) \
  && pass "inline wins over local + portable" || fail "inline wins over local + portable"
( unset CONTAINER_MEMORY; apply; [[ "$CONTAINER_MEMORY" == 4g ]] ) \
  && pass "local wins over portable" || fail "local wins over portable"
rmk

# an explicitly-empty inline value is respected (set-if-SET, not set-if-nonempty)
mk; printf 'CONTAINER_MEMORY=2g\n' > "$PORTABLE"
( export CONTAINER_MEMORY=; apply; [[ -z "$CONTAINER_MEMORY" ]] ) \
  && pass "explicit empty inline value is not clobbered" || fail "explicit empty inline value is not clobbered"
rmk

# portable-only key applied
mk; printf 'IMAGE_NAME=proj-img\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == proj-img ]] ) \
  && pass "portable-only key applied" || fail "portable-only key applied"
rmk

# missing local file is a no-op
mk; rm -f "$LOCAL"; printf 'IMAGE_NAME=x\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == x ]] ) \
  && pass "missing sandbox.local.env is a clean no-op" || fail "missing sandbox.local.env is a clean no-op"
rmk

# comments / blank / export prefix / surrounding quotes / non-assignment ignored
mk
{ printf '# comment\n'; printf '\n'; printf 'export PREVIEW_PORTS="3000 8080"\n'; printf 'not an assignment\n'; } > "$PORTABLE"
( unset PREVIEW_PORTS; apply; [[ "$PREVIEW_PORTS" == "3000 8080" ]] ) \
  && pass "export prefix + surrounding quotes handled" || fail "export prefix + surrounding quotes handled"
# a stray command line must NOT execute
# `mktemp -u` only invents a NAME, so a failure here is quieter and worse than
# most: $marker becomes empty, and the assertion below is `[[ ! -e "$marker" ]]`
# — `-e ""` is false, so `! -e ""` is TRUE and the check passes having tested
# nothing at all.
marker="$(mktemp -u)" || { printf 'SCAFFOLD-FAILED: mktemp -u (stray-command marker)\n'; exit 1; }
[[ -n "$marker" ]] || { printf 'SCAFFOLD-FAILED: mktemp -u returned an empty name — the non-execution check below would pass vacuously\n'; exit 1; }
printf 'touch %s\n' "$marker" >> "$PORTABLE"
( apply ) >/dev/null 2>&1
[[ ! -e "$marker" ]] && pass "non-assignment lines do not execute" || { fail "non-assignment lines do not execute"; rm -f "$marker"; }
rmk

# tolerant `export` prefix (tab or multiple spaces, not just a single space)
mk; printf 'export\tCONTAINER_CPUS=3\n' > "$PORTABLE"
( unset CONTAINER_CPUS; apply; [[ "$CONTAINER_CPUS" == 3 ]] ) \
  && pass "tolerates 'export<TAB>KEY=val'" || fail "tolerates 'export<TAB>KEY=val'"
rmk

# Keys that hand control of the SHELL to the file are refused. `sandbox.env` is a TRACKED,
# team-shared file, so a well-formed `BASH_ENV=…` line would otherwise be exported by the
# loader and then executed by the very next child bash that build.sh/sandbox.sh spawn —
# arbitrary code out of a file the design promises is inert data.
mk
evil="$(mktemp)"      || { printf 'SCAFFOLD-FAILED: mktemp (BASH_ENV payload)\n'; exit 1; }
marker2="$(mktemp -u)" || { printf 'SCAFFOLD-FAILED: mktemp -u (BASH_ENV marker)\n'; exit 1; }
[[ -n "$marker2" ]] || { printf 'SCAFFOLD-FAILED: mktemp -u returned an empty name — the BASH_ENV non-execution check would pass vacuously\n'; exit 1; }
printf 'touch %s\n' "$marker2" > "$evil"
printf 'BASH_ENV=%s\nIMAGE_NAME=still-parsed\n' "$evil" > "$PORTABLE"
out_deny="$( ( unset BASH_ENV IMAGE_NAME; apply; printf 'BASH_ENV=[%s] IMAGE_NAME=[%s]\n' "${BASH_ENV:-}" "${IMAGE_NAME:-}"; bash -c 'true' ) 2>&1 )"
grep -q 'BASH_ENV=\[\]' <<<"$out_deny" \
  && pass "BASH_ENV in an env file is refused (not exported)" || fail "BASH_ENV in an env file is refused (got: $out_deny)"
[[ ! -e "$marker2" ]] \
  && pass "a refused BASH_ENV cannot execute code in a child bash" || { fail "a refused BASH_ENV cannot execute code in a child bash"; rm -f "$marker2"; }
grep -q 'IMAGE_NAME=\[still-parsed\]' <<<"$out_deny" \
  && pass "a refused key does not abort parsing of later keys" || fail "a refused key does not abort parsing of later keys"
grep -qi 'WARNING' <<<"$out_deny" \
  && pass "a refused key warns on stderr" || fail "a refused key warns on stderr"
rm -f "$evil"; rmk

# ENV / SHELLOPTS / BASH_FUNC_* are refused for the same reason.
mk; printf 'ENV=/tmp/x.sh\n' > "$PORTABLE"
( unset ENV; apply; [[ -z "${ENV:-}" ]] ) 2>/dev/null \
  && pass "ENV is refused" || fail "ENV is refused"
printf 'BASH_FUNC_foo%%%%=() { echo hi; }\n' > "$PORTABLE"
( unset 'BASH_FUNC_foo%%'; apply ) >/dev/null 2>&1
pass "BASH_FUNC_* line does not crash the loader"
rmk

# Surrounding double quotes are stripped only as a MATCHED pair, so a value that
# legitimately contains a single quote character is not silently mangled.
mk; printf 'PREVIEW_PORTS=30"00\n' > "$PORTABLE"
( unset PREVIEW_PORTS; apply; [[ "$PREVIEW_PORTS" == '30"00' ]] ) \
  && pass "an unmatched quote inside a value is preserved" || fail "an unmatched quote inside a value is preserved"
rmk

# ── The committed sandbox.env takes only the launcher's own keys ─────────────
# Every key it sets is exported into docker, git and every tool the launcher
# runs. A deny-list of shell keys left the rest open: DOCKER_CONFIG made the
# docker CLI load a "plugin" committed next to it, and `docker build` ran it as
# you (bugs review ENV-1). So the portable file is an ALLOW-list; the
# machine-local sandbox.local.env, which nobody else writes, keeps the deny-list
# plus the tool-config families.
mk
printf 'IMAGE_NAME=ok-img\nPREVIEW_PORTS=3000\nSANDBOX_LAUNCHER_MAX=7\nDOCKER_CONFIG=./evil\nDOCKER_HOST=tcp://evil:2375\nGIT_SSH_COMMAND=evil\nREPO_SEED_IMAGE=evil/seed\nGITHUB_PERSONAL_ACCESS_TOKEN=ghp_planted\nFOO_BAR=1\n' > "$PORTABLE"
out_p="$( ( unset IMAGE_NAME PREVIEW_PORTS SANDBOX_LAUNCHER_MAX DOCKER_CONFIG DOCKER_HOST GIT_SSH_COMMAND REPO_SEED_IMAGE GITHUB_PERSONAL_ACCESS_TOKEN FOO_BAR
  apply; printf 'GOT %s|%s|%s|%s|%s|%s|%s|%s|%s\n' "${IMAGE_NAME:-}" "${PREVIEW_PORTS:-}" "${SANDBOX_LAUNCHER_MAX:-}" "${DOCKER_CONFIG:-}" "${DOCKER_HOST:-}" "${GIT_SSH_COMMAND:-}" "${REPO_SEED_IMAGE:-}" "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" "${FOO_BAR:-}" ) 2>&1 )"
grep -qxF 'GOT ok-img|3000|7||||||' <<<"$out_p" \
  && pass "sandbox.env sets the launcher's keys and nothing else (DOCKER_*, GIT_*, a seed image, a token, an unknown key)" \
  || fail "portable allow-list (got: $(grep GOT <<<"$out_p"))"
[[ "$(grep -c "WARNING: ignoring .* in $PORTABLE" <<<"$out_p")" -eq 6 ]] && grep -qF 'sandbox.local.env' <<<"$out_p" \
  && pass "each key it ignores is named once, with where it belongs instead" \
  || fail "portable warnings (got: $(grep WARNING <<<"$out_p" | tr '\n' ' '))"
! grep -qF 'ghp_planted' <<<"$out_p" \
  && pass "an ignored value is never printed" || fail "an ignored token value was printed"
rmk
# What exposes THIS machine is not the shared file's to choose either: a host
# path to mount (EXTRA_MOUNTS, the *_PATH pointers, a working dir outside the
# project), the agent's identity
# (SANDBOX_UID=0 is a root shell), the file container.env is read from.
mk
printf 'EXTRA_MOUNTS=/home/you/.ssh:rw\nVAULT_PATH=/home/you\nDOCS_PATH=/etc\nSPECS_PATH=/x\nARCHITECTURE_REPO_PATH=/y\nSANDBOX_UID=0\nSANDBOX_GID=0\nSANDBOX_ENV_FILE=/home/you/.aws/credentials\nAI_CONTAINER_HOST_ACK=1\nAI_CONTAINER_GROUP_INIT=from:host\nSANDBOX_WORKDIR=/home/you\n' > "$PORTABLE"
out_m="$( ( unset EXTRA_MOUNTS VAULT_PATH DOCS_PATH SPECS_PATH ARCHITECTURE_REPO_PATH SANDBOX_UID SANDBOX_GID SANDBOX_ENV_FILE AI_CONTAINER_HOST_ACK AI_CONTAINER_GROUP_INIT SANDBOX_WORKDIR
  apply; printf 'GOT [%s%s%s%s%s%s%s%s%s%s%s]\n' "${EXTRA_MOUNTS:-}" "${VAULT_PATH:-}" "${DOCS_PATH:-}" "${SPECS_PATH:-}" "${ARCHITECTURE_REPO_PATH:-}" "${SANDBOX_UID:-}" "${SANDBOX_GID:-}" "${SANDBOX_ENV_FILE:-}" "${AI_CONTAINER_HOST_ACK:-}" "${AI_CONTAINER_GROUP_INIT:-}" "${SANDBOX_WORKDIR:-}" ) 2>&1 )"
grep -qxF 'GOT []' <<<"$out_m" && [[ "$(grep -c "WARNING: ignoring" <<<"$out_m")" -eq 11 ]] \
  && pass "sandbox.env cannot choose a host path, the agent's identity or the env file" \
  || fail "machine-only keys from sandbox.env (got: $(grep GOT <<<"$out_m"); warnings: $(grep -c WARNING <<<"$out_m"))"
rmk
mk
# A relative SANDBOX_WORKDIR is resolved where sandbox.env is — following any
# symlink, since a repository can commit one — and accepted only inside the
# project; what is exported is that physical path, so sandbox.sh mounts exactly
# what was checked.
mkdir -p "$PROJROOT/sub" "$PROJROOT/a/b" "$MKD/outside"
ln -s "$MKD/outside" "$PROJROOT/escape"; ln -s ../outside "$PROJROOT/a/rel-escape"
printf 'SANDBOX_WORKDIR=..\nAI_CONTAINER_GROUP=docs\n' > "$PORTABLE"
( unset SANDBOX_WORKDIR AI_CONTAINER_GROUP; cd "$MKD/outside"; apply; [[ "$SANDBOX_WORKDIR" == "$PROJROOT" && "$AI_CONTAINER_GROUP" == docs ]] ) 2>/dev/null \
  && pass "sandbox.env still sets the working dir (resolved to the project, wherever you launch from) and a named group" \
  || fail "portable SANDBOX_WORKDIR=.. / AI_CONTAINER_GROUP=docs (got: $( ( unset SANDBOX_WORKDIR; apply; printf '%s' "${SANDBOX_WORKDIR:-}" ) 2>&1 ))"
wbad=""
# Only the project itself. `.` is the launcher's own directory, mounted writable
# — the agent could then edit what the host runs at the next launch — and a
# subdirectory or @repo is this machine's choice, not the shared file's (the
# review of batch 2: F1, F3, F10).
for w in "..:$PROJROOT" "../:$PROJROOT" "../a/..:$PROJROOT"; do
  printf 'SANDBOX_WORKDIR=%s\n' "${w%%:*}" > "$PORTABLE"
  ( unset SANDBOX_WORKDIR; apply; [[ "$SANDBOX_WORKDIR" == "${w#*:}" ]] ) 2>/dev/null || wbad+=" refused:${w%%:*}"
done
# shellcheck disable=SC2088  # '~/x' is a LITERAL value the loader must refuse, not a path to expand
for w in . ../sub @app ../a/b ../.ai-containers ../.. ../../outside /abs "$MKD/outside" '~/x' '../a/../../outside' ../escape ../a/rel-escape ../missing; do
  printf 'SANDBOX_WORKDIR=%s\n' "$w" > "$PORTABLE"
  ( unset SANDBOX_WORKDIR; apply; [[ -z "${SANDBOX_WORKDIR:-}" ]] ) 2>/dev/null || wbad+=" accepted:$w"
done
[[ -z "$wbad" ]] && pass "a portable SANDBOX_WORKDIR is the project and nothing else, symlinks followed" \
  || fail "portable SANDBOX_WORKDIR:$wbad"
printf 'EXTRA_MOUNTS=/x\nSANDBOX_UID=1234\nAI_CONTAINER_GROUP=work\nSANDBOX_WORKDIR=/abs\n' > "$LOCAL"; : > "$PORTABLE"
( unset EXTRA_MOUNTS SANDBOX_UID AI_CONTAINER_GROUP SANDBOX_WORKDIR; apply
  [[ "$EXTRA_MOUNTS" == /x && "$SANDBOX_UID" == 1234 && "$AI_CONTAINER_GROUP" == work && "$SANDBOX_WORKDIR" == /abs ]] ) 2>/dev/null \
  && pass "sandbox.local.env sets all of those" || fail "machine-only keys refused from sandbox.local.env"
rmk
# Keys that were removed say so, from either file, rather than "move it to
# sandbox.local.env", where they would do nothing (review of batch 11).
mk
printf 'SANDBOX_GIT_FIXTURES=td/a.git\n' > "$PORTABLE"; printf 'AI_CONTAINER_HOST_ACK=1\n' > "$LOCAL"
out_r="$( ( unset SANDBOX_GIT_FIXTURES AI_CONTAINER_HOST_ACK; apply; printf 'GOT [%s%s]\n' "${SANDBOX_GIT_FIXTURES:-}" "${AI_CONTAINER_HOST_ACK:-}" ) 2>&1 )"
grep -qxF 'GOT []' <<<"$out_r" && [[ "$(grep -c 'no longer used' <<<"$out_r")" -eq 2 ]] \
  && pass "a removed key is ignored from either file, saying it is no longer used" \
  || fail "removed keys: $(tr '\n' ' ' <<<"$out_r")"
rmk
# Also machine-only: REPOS mounts registered repos — on Linux, live binds of host
# checkouts — and REPO_VOLUME_PREFIX decides which volumes repo.sh deletes;
# SANDBOX_CONF is read before these files load, so from them it steered only
# --version. IMAGE_NAME cannot be the seed image repo.sh runs as root with your
# ~/.ssh (the review of batch 2: F3, F7, F9).
mk
printf 'REPOS=infra:rw\nREPO_VOLUME_PREFIX=other\nSANDBOX_CONF=/x.conf\nIMAGE_NAME=ai-containers-seed\n' > "$PORTABLE"
( unset REPOS REPO_VOLUME_PREFIX SANDBOX_CONF IMAGE_NAME REPO_SEED_IMAGE; apply
  [[ -z "${REPOS:-}${REPO_VOLUME_PREFIX:-}${SANDBOX_CONF:-}${IMAGE_NAME:-}" ]] ) 2>/dev/null \
  && pass "sandbox.env cannot set REPOS, REPO_VOLUME_PREFIX, SANDBOX_CONF, or the seed image as IMAGE_NAME" \
  || fail "portable REPOS/REPO_VOLUME_PREFIX/SANDBOX_CONF/IMAGE_NAME=seed accepted"
printf 'IMAGE_NAME=my/seed\n' > "$PORTABLE"
( unset IMAGE_NAME; export REPO_SEED_IMAGE=my/seed; apply; [[ -z "${IMAGE_NAME:-}" ]] ) 2>/dev/null \
  && pass "… nor a REPO_SEED_IMAGE override" || fail "portable IMAGE_NAME equal to REPO_SEED_IMAGE accepted"
# Docker reads one image under many names: a tag, the default registry,
# library/, a digest (security review of 0b40d6c).
sbad=""
for v in ai-containers-seed:latest docker.io/ai-containers-seed docker.io/library/ai-containers-seed:latest \
         index.docker.io/library/ai-containers-seed library/ai-containers-seed \
         "ai-containers-seed@sha256:$(printf '%064d' 0)"; do
  printf 'IMAGE_NAME=%s\n' "$v" > "$PORTABLE"
  ( unset IMAGE_NAME REPO_SEED_IMAGE; apply; [[ -z "${IMAGE_NAME:-}" ]] ) 2>/dev/null || sbad+=" $v"
done
printf 'IMAGE_NAME=my/seed:dev\n' > "$PORTABLE"
( unset IMAGE_NAME; export REPO_SEED_IMAGE=docker.io/my/seed; apply; [[ -z "${IMAGE_NAME:-}" ]] ) 2>/dev/null || sbad+=" my/seed:dev(override)"
printf 'IMAGE_NAME=ai-containers-seeder\n' > "$PORTABLE"
( unset IMAGE_NAME REPO_SEED_IMAGE; apply; [[ "${IMAGE_NAME:-}" == ai-containers-seeder ]] ) 2>/dev/null || sbad+=" (refused)ai-containers-seeder"
[[ -z "$sbad" ]] && pass "the seed image is recognised under any of its names, and only it" \
  || fail "seed image names:$sbad"
printf 'REPOS=infra:rw\n' > "$LOCAL"; printf 'IMAGE_NAME=proj-ai\n' > "$PORTABLE"
( unset REPOS IMAGE_NAME REPO_SEED_IMAGE; apply; [[ "$REPOS" == infra:rw && "$IMAGE_NAME" == proj-ai ]] ) 2>/dev/null \
  && pass "sandbox.local.env still sets REPOS, and sandbox.env an ordinary IMAGE_NAME" \
  || fail "REPOS from local / ordinary IMAGE_NAME refused"
rmk
mk
printf 'GITHUB_TOKEN=ghp_mine\nREPO_SEED_IMAGE=my/seed\nFOO_BAR=1\nDOCKER_CONFIG=./evil\nBUILDX_CONFIG=./e\nBUILDKIT_HOST=tcp://e\nGIT_CONFIG_GLOBAL=./e\nSSH_AUTH_SOCK=/e\n' > "$LOCAL"
out_l="$( ( unset GITHUB_TOKEN REPO_SEED_IMAGE FOO_BAR DOCKER_CONFIG BUILDX_CONFIG BUILDKIT_HOST GIT_CONFIG_GLOBAL SSH_AUTH_SOCK
  apply; printf 'GOT %s|%s|%s|%s|%s|%s|%s|%s\n' "${GITHUB_TOKEN:-}" "${REPO_SEED_IMAGE:-}" "${FOO_BAR:-}" "${DOCKER_CONFIG:-}" "${BUILDX_CONFIG:-}" "${BUILDKIT_HOST:-}" "${GIT_CONFIG_GLOBAL:-}" "${SSH_AUTH_SOCK:-}" ) 2>&1 )"
grep -qxF 'GOT ghp_mine|my/seed|1|||||' <<<"$out_l" \
  && pass "sandbox.local.env keeps any key but the shell's and the tool-config families (DOCKER_*, BUILDX_*, BUILDKIT_*, GIT_*, SSH_*)" \
  || fail "local deny-list (got: $(grep GOT <<<"$out_l"))"
rmk
# The allow-list must not drift from what the launcher documents: every variable
# in AGENTS.md's sandbox.sh table is either accepted from sandbox.env or one of
# the few kept to the machine (the tokens).
doc_keys="$(awk '/^\*\*Key env vars for `sandbox.sh`:\*\*/{f=1} f && /^## /{exit} f' "$REPO_DIR/AGENTS.md" \
  | grep -oE '^\| `[A-Z][A-Z0-9_]*`' | grep -oE '[A-Z][A-Z0-9_]*')"
[[ -n "$doc_keys" ]] || { printf 'SCAFFOLD-FAILED: no keys read from AGENTS.md env table\n'; exit 1; }
drift=""
for k in $doc_keys; do
  env_key_portable "$k" || env_key_machine_only "$k" || drift+=" $k"
  if env_key_portable "$k" && env_key_machine_only "$k"; then drift+=" (both)$k"; fi
done
[[ -z "$drift" ]] && pass "every launcher variable AGENTS.md documents is either portable or machine-only, never both ($(wc -w <<<"$doc_keys") keys)" \
  || fail "documented but classified wrongly:$drift"

# A double-quoted value may span lines, so a long list (EXTRA_MOUNTS, REPOS) can
# be written one entry per line. It must arrive EXACTLY as the one-line form
# would — single-space separated — because the lists are split by consumers
# that are not all split_env_list.
mk
printf 'EXTRA_MOUNTS="\n  /a:ro\n\n  # a comment between entries\n\t/b\n  /c:rw\n"\nIMAGE_NAME=after\n' > "$LOCAL"
( unset EXTRA_MOUNTS IMAGE_NAME; apply; [[ "$EXTRA_MOUNTS" == "/a:ro /b /c:rw" ]] ) \
  && pass "multi-line value joins its entries with single spaces" || fail "multi-line value joins its entries with single spaces"
( unset EXTRA_MOUNTS IMAGE_NAME; apply; [[ "$IMAGE_NAME" == after ]] ) \
  && pass "a key after a multi-line value is still parsed" || fail "a key after a multi-line value is still parsed"
rmk

# Text on the closing line belongs to the value too.
mk; printf 'export REPOS="\n  docs:ro\n  cluster:ro\n  agent:ro"\n' > "$LOCAL"
( unset REPOS; apply; [[ "$REPOS" == "docs:ro cluster:ro agent:ro" ]] ) \
  && pass "multi-line value keeps text on its closing line" || fail "multi-line value keeps text on its closing line"
rmk

# Only a bare opening quote opens a value (review of PR #317): a value that lost its
# closing quote by a typo would otherwise run on to the next line that ends with
# `"` — any one-line assignment — and swallow every key on the way, unwarned.
mk; printf 'CONTAINER_NAME="myproj\nEXTRA_MOUNTS="/a /b"\nSANDBOX_MODE=restricted\n' > "$LOCAL"
( unset CONTAINER_NAME EXTRA_MOUNTS SANDBOX_MODE; apply
  [[ "$CONTAINER_NAME" == '"myproj' && "$EXTRA_MOUNTS" == "/a /b" && "$SANDBOX_MODE" == restricted ]] ) \
  && pass "a value with text after its only quote is one line, as before" || fail "a value with text after its only quote is one line, as before"
rmk

# A value left open by mistake swallows the assignments after it, so one inside a
# value is warned about, naming it — and the value is still read as written.
mk; printf 'EXTRA_MOUNTS="\n  /a\nSANDBOX_MODE="open"\nIMAGE_NAME=after\n' > "$LOCAL"
out_sw="$( ( unset EXTRA_MOUNTS SANDBOX_MODE IMAGE_NAME; apply
  printf 'EXTRA_MOUNTS=[%s] SANDBOX_MODE=%s\n' "${EXTRA_MOUNTS:-}" "${SANDBOX_MODE+set}" ) 2>&1 )"
grep -q 'EXTRA_MOUNTS=\[/a SANDBOX_MODE="open\] SANDBOX_MODE=$' <<<"$out_sw" \
  && pass "an assignment inside a multi-line value is part of it" || fail "an assignment inside a multi-line value is part of it (got: $out_sw)"
grep -q 'WARNING.*EXTRA_MOUNTS.*SANDBOX_MODE=' <<<"$out_sw" \
  && pass "and is warned about, naming both keys" || fail "and is warned about, naming both keys (got: $out_sw)"
rmk

# The joined value is used as joined: the matched-pair strip of a one-line value
# does not apply, as the report's reader does not apply it either.
mk; printf 'REPOS="\n  "a\n  b""\n' > "$LOCAL"
( unset REPOS; apply 2>/dev/null; [[ "$REPOS" == '"a b"' ]] ) \
  && pass "a joined value keeps quotes its entries carry" || fail "a joined value keeps quotes its entries carry"
rmk

# A portable key's VALUE check sees the joined value.
mk; printf 'IMAGE_NAME="\n  ghcr.io/x/y\n"\n' > "$PORTABLE"
( unset IMAGE_NAME; apply 2>/dev/null; [[ -z "${IMAGE_NAME+x}" ]] ) \
  && pass "a multi-line portable value is checked as joined" || fail "a multi-line portable value is checked as joined"
rmk

mk; printf 'EXTRA_MOUNTS="\r\n  /a\r\n  /b\r\n"\r\n' > "$LOCAL"
( unset EXTRA_MOUNTS; apply; [[ "$EXTRA_MOUNTS" == "/a /b" ]] ) \
  && pass "multi-line value tolerates CRLF" || fail "multi-line value tolerates CRLF"
rmk

# Only a value whose ONLY quote is the opening one continues. A single-line value
# that merely starts with a quote keeps its old literal meaning, and must not
# swallow the lines after it.
mk; printf 'FOO="a" b\nIMAGE_NAME=next\n' > "$LOCAL"
( unset FOO IMAGE_NAME; apply; [[ "$FOO" == '"a" b' && "$IMAGE_NAME" == next ]] ) \
  && pass "a one-line value with an inner quote is not continued" || fail "a one-line value with an inner quote is not continued"
rmk

# Precedence still holds, and an ignored multi-line value is still CONSUMED: its
# continuation lines must not be read as assignments of their own.
mk; printf 'EXTRA_MOUNTS="\n  /from-file\n  REPOS=smuggled\n"\nIMAGE_NAME=after\n' > "$LOCAL"
( unset REPOS IMAGE_NAME; export EXTRA_MOUNTS=/inline; apply 2>/dev/null
  [[ "$EXTRA_MOUNTS" == /inline && -z "${REPOS+x}" && "$IMAGE_NAME" == after ]] ) \
  && pass "an already-set key consumes its multi-line value unused" || fail "an already-set key consumes its multi-line value unused"
printf 'BASH_ENV="\n  /x\n  REPOS=smuggled\n"\nIMAGE_NAME=after\n' > "$LOCAL"
( unset BASH_ENV REPOS IMAGE_NAME; apply 2>/dev/null
  [[ -z "${BASH_ENV:-}" && -z "${REPOS+x}" && "$IMAGE_NAME" == after ]] ) \
  && pass "a refused key consumes its multi-line value unused" || fail "a refused key consumes its multi-line value unused"
rmk

# A shared sandbox.env cannot set a machine-only list by spreading it over lines:
# the value is read in full first and then refused as one, so nothing inside it —
# here a portable key and a token — is ever parsed as an assignment of its own.
mk; printf 'EXTRA_MOUNTS="\n  /x\n  SANDBOX_MODE=open\n  GITHUB_TOKEN=leak\n"\nIMAGE_NAME=after\n' > "$PORTABLE"
out_mo="$( ( unset EXTRA_MOUNTS SANDBOX_MODE GITHUB_TOKEN IMAGE_NAME; apply
  printf 'EXTRA_MOUNTS=%s SANDBOX_MODE=%s GITHUB_TOKEN=%s IMAGE_NAME=[%s]\n' \
    "${EXTRA_MOUNTS+set}" "${SANDBOX_MODE+set}" "${GITHUB_TOKEN+set}" "${IMAGE_NAME:-}" ) 2>&1 )"
grep -q 'EXTRA_MOUNTS= SANDBOX_MODE= GITHUB_TOKEN= IMAGE_NAME=\[after\]' <<<"$out_mo" \
  && pass "a multi-line machine-only value in sandbox.env is refused whole, lines inside included" \
  || fail "a multi-line machine-only value in sandbox.env is refused whole (got: $out_mo)"
grep -q 'WARNING.*EXTRA_MOUNTS' <<<"$out_mo" \
  && pass "and the refusal names the key" || fail "and the refusal names the key"
rmk

# A value never closed is refused with a warning — never stored as a bare `"`.
mk; printf 'IMAGE_NAME=before\nEXTRA_MOUNTS="\n  /a\n  /b\n' > "$LOCAL"
out_open="$( ( unset EXTRA_MOUNTS IMAGE_NAME; apply
  printf 'EXTRA_MOUNTS=[%s] set=%s IMAGE_NAME=[%s]\n' "${EXTRA_MOUNTS:-}" "${EXTRA_MOUNTS+yes}" "${IMAGE_NAME:-}" ) 2>&1 )"
grep -q 'EXTRA_MOUNTS=\[\] set= ' <<<"$out_open" \
  && pass "an unterminated multi-line value is not set" || fail "an unterminated multi-line value is not set (got: $out_open)"
grep -q 'WARNING.*EXTRA_MOUNTS' <<<"$out_open" \
  && pass "an unterminated multi-line value warns, naming the key" || fail "an unterminated multi-line value warns, naming the key"
grep -q 'IMAGE_NAME=\[before\]' <<<"$out_open" \
  && pass "keys before an unterminated value are kept" || fail "keys before an unterminated value are kept"
rmk

# load ORDER in sandbox-common.sh: local before portable
loc_ln=$(grep -n 'load_env_defaults .*sandbox\.local\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
por_ln=$(grep -n 'load_env_defaults .*/sandbox\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
[[ -n "$loc_ln" && -n "$por_ln" && "$loc_ln" -lt "$por_ln" ]] \
  && pass "sandbox-common.sh loads local before portable ($loc_ln<$por_ln)" \
  || fail "sandbox-common.sh loads local before portable (local=$loc_ln portable=$por_ln)"

# sandbox.sh mode/workdir defaulting (structural — matches test-env-file.sh's grep style)
grep -qF 'command="${1:-${SANDBOX_MODE:-usage}}"' "$REPO_DIR/sandbox.sh" \
  && pass "mode falls back to SANDBOX_MODE (else usage)" || fail "mode falls back to SANDBOX_MODE"
grep -qF '${2:-${SANDBOX_WORKDIR:-}}' "$REPO_DIR/sandbox.sh" \
  && pass "workdir falls back to SANDBOX_WORKDIR" || fail "workdir falls back to SANDBOX_WORKDIR"

# behavioral: a bare ./sandbox.sh with no SANDBOX_MODE resolves mode → usage (docker-free
# path — usage() just prints and exits; no run_container/docker is reached). Hermetic only
# when the repo root has no sandbox.env/sandbox.local.env (the loader would read them and
# could set SANDBOX_MODE, defeating the probe); the committed repo has neither.
if [[ ! -f "$REPO_DIR/sandbox.env" && ! -f "$REPO_DIR/sandbox.local.env" ]]; then
  sbout="$(mktemp)" || { printf 'SCAFFOLD-FAILED: mktemp (usage-probe output)\n'; exit 1; }
  ( unset SANDBOX_MODE SANDBOX_WORKDIR; bash "$REPO_DIR/sandbox.sh" >"$sbout" 2>&1 || true )
  grep -q '^Usage:' "$sbout" && pass "bare ./sandbox.sh (no SANDBOX_MODE) shows usage" || fail "bare ./sandbox.sh (no SANDBOX_MODE) shows usage"
  rm -f "$sbout"
else
  printf 'NOTE: skipping bare-sandbox.sh usage probe (repo-root sandbox.env/local present)\n'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
