#!/usr/bin/env bash
# container.env (SANDBOX_ENV_FILE) → the container's application environment.
#
# sandbox.sh's side, run against a fake docker (E1–E8): container.env is parsed
# the way docker parses an env-file; every line that would act on the container's
# ROOT entrypoint before it can set the line aside, or that docker would refuse,
# is dropped with a WARNING naming the line and never the value, and the launch
# goes on; the rest reaches docker on a descriptor, with their names in
# AI_CONTAINER_ENV_KEYS. The entrypoint's side, extracted and run (E9–E11): those
# keys are set aside before anything reads the environment and given back only to
# processes run as the sandbox user. Integration case 320-container-env-not-root
# checks the container itself.
#
# NOTE: tests/test-sandbox-env.sh covers a DIFFERENT layer (sandbox.env, the host
# launcher's own config).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/sandbox.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

bash -n "$ENGINE/sandbox.sh" && pass "sandbox.sh passes bash -n" || fail "sandbox.sh bash -n"
bash -n "$ENGINE/entrypoint.sh" && pass "entrypoint.sh passes bash -n" || fail "entrypoint.sh bash -n"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; REAL_HOME="$HOME"
TMP="$(cd "$TMP" && pwd -P)"
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && { rm -rf "$TMP"; export HOME="$REAL_HOME"; }' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export AI_CONTAINER_GROUP=default AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=tester
unset CONTAINER_NAME EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH \
      SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE GITHUB_PERSONAL_ACCESS_TOKEN COPILOT_GITHUB_TOKEN \
      SELF_HEALING_ENABLED ALLOW_IPV6_BYPASS
CAPTURE="$TMP/docker-args.txt"
mkdir -p "$TMP/bin"
# Records the run args one per line, and copies out what --env-file names while
# sandbox.sh still holds the descriptor open.
cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then
  shift; printf '%s\n' "\$@" > "$CAPTURE"
  prev=""
  for a in "\$@"; do
    [[ "\$prev" == --env-file ]] && cat "\$a" > "$CAPTURE.envfile"
    prev="\$a"
  done
fi
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
SANDBOX_CONF="$TMP/sandbox.conf"; export SANDBOX_CONF; : > "$SANDBOX_CONF"

# A project's working copy, as project-init.sh / sync-to-projects.sh lay it out,
# so container.env is auto-detected beside the launcher and nothing a developer
# keeps beside the repo's own sandbox.sh can leak in.
# shellcheck source=shared-files.sh
source "$ENGINE/shared-files.sh"
PROJ="$TMP/proj"; LAUNCHER="$PROJ/.ai-containers"
mkdir -p "$LAUNCHER"
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$LAUNCHER/$f"; done
cp -R "$ENGINE/tools.d" "$ENGINE/services.d" "$LAUNCHER/"
CENV="$LAUNCHER/container.env"
# A CRLF container.env beside the launcher is refused before any of this, by
# host_checkout_preflight (a Windows-side checkout); docker's own CR handling
# matters for a SANDBOX_ENV_FILE kept elsewhere, which is where E1/E2 put theirs.
AENV="$TMP/app.env"
ENVF="$CENV"

ERR="$TMP/err.txt"
launch() {  # extra env via the caller's `VAR=x launch`
  rm -f "$CAPTURE" "$CAPTURE.envfile"
  ( cd "$LAUNCHER" && bash ./sandbox.sh open "$PROJ" ) >/dev/null 2>"$ERR" </dev/null
  LAUNCH_RC=$?
}
ran()       { [[ -s "$CAPTURE" ]]; }
envfile()   { cat "$CAPTURE.envfile" 2>/dev/null; }
keys_arg()  { sed -n 's/^AI_CONTAINER_ENV_KEYS=//p' "$CAPTURE" 2>/dev/null; }
has_flag()  { grep -qxF -- "$1" "$CAPTURE" 2>/dev/null; }
warned()    { grep -qF "$ENVF line $1 not passed to the container: $2" "$ERR"; }
nwarnings() { grep -c '^WARNING: .* not passed to the container' "$ERR"; }

# ── E1: parsed as docker parses an env-file ──────────────────────────────────
# Each rule measured against the docker CLI: a BOM dropped from line 1 only,
# leading Unicode whitespace (NBSP here), one trailing CR; a value literal, quotes,
# `#` and trailing spaces kept; a bare NAME passed bare, for docker to look up in
# this environment; duplicates passed in order, so docker keeps the last.
ENVF="$AENV"
printf '\xef\xbb\xbfFIRST=1\n# a comment\n\n  \xc2\xa0INDENT=nbsp\nCRLF=x\r\nQUOTED="5"\nHASH=a # b\nTRAIL=a b  \nBARE_SET\nBARE_UNSET\nDUP=1\nDUP=2\nLAST=end' > "$AENV"
BARE_SET=hostval SANDBOX_ENV_FILE="$AENV" launch
want=$'FIRST=1\nINDENT=nbsp\nCRLF=x\nQUOTED="5"\nHASH=a # b\nTRAIL=a b  \nBARE_SET\nBARE_UNSET\nDUP=1\nDUP=2\nLAST=end'
[[ "$LAUNCH_RC" == 0 ]] && ran && pass "E1 a well-formed container.env launches" \
  || fail "E1 a well-formed container.env launches (rc=$LAUNCH_RC; $(tr '\n' ' ' <"$ERR"))"
[[ "$(envfile)" == "$want" ]] && pass "E1 docker gets the lines as docker itself would read them" \
  || fail "E1 docker gets the lines as docker itself would read them — got: $(envfile | cat -v | tr '\n' '|')"
[[ "$(keys_arg)" == "FIRST INDENT CRLF QUOTED HASH TRAIL BARE_SET BARE_UNSET DUP LAST" ]] \
  && pass "E1 AI_CONTAINER_ENV_KEYS names each key once, in order" \
  || fail "E1 AI_CONTAINER_ENV_KEYS names each key once — got '$(keys_arg)'"
grep -qE '^/dev/fd/[0-9]+$' < <(sed -n '/^--env-file$/{n;p;}' "$CAPTURE") \
  && pass "E1 the filtered file goes on a descriptor, never to disk" \
  || fail "E1 the filtered file goes on a descriptor — --env-file is '$(sed -n '/^--env-file$/{n;p;}' "$CAPTURE")'"
[[ "$(nwarnings)" == 0 ]] && pass "E1 and nothing in it is warned about" \
  || fail "E1 nothing is warned about — got: $(grep WARNING "$ERR" | tr '\n' ' ')"

# ── E2: a line docker would refuse is dropped, and the launch goes on ─────────
# Each of these makes docker refuse the WHOLE file; one bad line must not cost
# the user the container.
{ printf 'GOOD=1\nexport EXP=s3cr3t-2\nSP ACE=s3cr3t-3\n=s3cr3t-4\nUTF=\xffs3cr3t-5\nNUL=a\x00s3cr3t-6\nTWOCR=s3cr3t-7\r\r\nLONG='
  head -c 65536 /dev/zero | tr '\0' a; printf '\nGOOD2=2\n'; } > "$AENV"
SANDBOX_ENV_FILE="$AENV" launch
[[ "$LAUNCH_RC" == 0 ]] && ran && pass "E2 a container.env docker would refuse still launches" \
  || fail "E2 a container.env docker would refuse still launches (rc=$LAUNCH_RC)"
[[ "$(envfile)" == $'GOOD=1\nGOOD2=2' && "$(keys_arg)" == "GOOD GOOD2" ]] \
  && pass "E2 only the good lines reach docker" \
  || fail "E2 only the good lines reach docker — got: $(envfile | cat -v | tr '\n' '|') keys '$(keys_arg)'"
for spec in "2|docker does not take 'export'" "3|its name holds whitespace" "4|it has no name before the =" \
            "5|it is not valid UTF-8" "6|it holds a NUL byte" "7|its value ends in a carriage return" \
            "8|it is longer than docker reads"; do
  warned "${spec%%|*}" "${spec#*|}" && pass "E2 line ${spec%%|*} warned: ${spec#*|}" \
    || fail "E2 line ${spec%%|*} warned: ${spec#*|} — stderr: $(grep WARNING "$ERR" | tr '\n' ' ')"
done

ENVF="$CENV"

# ── E3: what acts on the container's first process before it can be set aside ─
# The loader, env(1)'s PATH search for `#!/usr/bin/env bash`, bash's own start-up.
: > "$CENV"; i=0
for k in PATH LD_PRELOAD LD_ANYTHING_NEW DYLD_INSERT_LIBRARIES GLIBC_TUNABLES GCONV_PATH LOCPATH \
         BASH_ENV ENV SHELLOPTS BASHOPTS POSIXLY_CORRECT GLOBIGNORE IFS PS4 CDPATH; do
  i=$((i + 1)); printf '%s=s3cr3t-%d\n' "$k" "$i" >> "$CENV"
done
printf 'OK=1\n' >> "$CENV"
launch
i=0; bad=""
for k in PATH LD_PRELOAD LD_ANYTHING_NEW DYLD_INSERT_LIBRARIES GLIBC_TUNABLES GCONV_PATH LOCPATH \
         BASH_ENV ENV SHELLOPTS BASHOPTS POSIXLY_CORRECT GLOBIGNORE IFS PS4 CDPATH; do
  i=$((i + 1)); warned "$i" "$k acts on the container's first process" || bad+=" $k"
done
[[ -z "$bad" ]] && pass "E3 every key that acts before the entrypoint's first line is refused, by name" \
  || fail "E3 not refused:$bad"
[[ "$(envfile)" == "OK=1" && "$(keys_arg)" == "OK" ]] && pass "E3 … and none of them reaches docker" \
  || fail "E3 none of them reaches docker — got: $(envfile | tr '\n' '|')"

# ── E4: what the entrypoint could not set aside or give back unchanged ────────
printf 'HOME=s3cr3t-1\nUSER=s3cr3t-2\nLOGNAME=s3cr3t-3\nUID=s3cr3t-4\nEUID=s3cr3t-5\nPPID=s3cr3t-6\nBASH_ARGV0=s3cr3t-7\na.b=s3cr3t-8\na-b=s3cr3t-9\nBASHO_HOST=riak\n' > "$CENV"
launch
for spec in "1|the container sets HOME" "2|the container sets USER" "3|the container sets LOGNAME" \
            "4|UID is bash's own" "5|EUID is bash's own" "6|PPID is bash's own" "7|BASH_ARGV0 is bash's own" \
            "8|its name is not a shell variable name" "9|its name is not a shell variable name"; do
  warned "${spec%%|*}" "${spec#*|}" && pass "E4 line ${spec%%|*} warned: ${spec#*|}" \
    || fail "E4 line ${spec%%|*} warned: ${spec#*|} — stderr: $(grep WARNING "$ERR" | tr '\n' ' ')"
done
[[ "$(envfile)" == "BASHO_HOST=riak" ]] && pass "E4 a name merely starting with BASH is the application's" \
  || fail "E4 BASHO_HOST passes — got: $(envfile | tr '\n' '|')"

# ── E5: a key the launcher sets is refused — read from the -e flags themselves ─
printf 'SANDBOX_UID=0\nDEV_CONTAINER_MODE=open\nIMAGE_NAME=other\nGITHUB_PERSONAL_ACCESS_TOKEN=from-file\nAI_CONTAINER_ENV_KEYS=PATH\nSELF_HEALING_ENABLED=0\nALLOW_IPV6_BYPASS=1\nAPP=1\n' > "$CENV"
launch
for spec in "1|the launcher sets SANDBOX_UID itself" "2|the launcher sets DEV_CONTAINER_MODE itself" \
            "3|the launcher sets IMAGE_NAME itself" "5|AI_CONTAINER_ENV_KEYS is the launcher's own" \
            "6|only the container's root setup reads SELF_HEALING_ENABLED" \
            "7|only the container's root setup reads ALLOW_IPV6_BYPASS"; do
  warned "${spec%%|*}" "${spec#*|}" && pass "E5 line ${spec%%|*} warned: ${spec#*|}" \
    || fail "E5 line ${spec%%|*} warned: ${spec#*|} — stderr: $(grep WARNING "$ERR" | tr '\n' ' ')"
done
grep -qF 'set it in sandbox.env' "$ERR" && pass "E5 a root-only knob's warning says where it belongs" \
  || fail "E5 a root-only knob's warning says where it belongs"
[[ "$(envfile)" == $'GITHUB_PERSONAL_ACCESS_TOKEN=from-file\nAPP=1' ]] \
  && pass "E5 a key the launcher passes only when set on the host is the file's when it is not" \
  || fail "E5 GITHUB_PERSONAL_ACCESS_TOKEN passes when the host has none — got: $(envfile | tr '\n' '|')"
GITHUB_PERSONAL_ACCESS_TOKEN=from-host launch
warned 4 "the launcher sets GITHUB_PERSONAL_ACCESS_TOKEN itself" && has_flag "GITHUB_PERSONAL_ACCESS_TOKEN=from-host" \
  && pass "E5 … and refused when the host's goes in with -e" \
  || fail "E5 GITHUB_PERSONAL_ACCESS_TOKEN refused when the host sets it — stderr: $(grep WARNING "$ERR" | tr '\n' ' ')"
[[ "$(keys_arg)" == "APP" ]] && pass "E5 AI_CONTAINER_ENV_KEYS is the launcher's, never the file's" \
  || fail "E5 AI_CONTAINER_ENV_KEYS is the launcher's — got '$(keys_arg)'"

# ── E6: no value is ever printed ─────────────────────────────────────────────
# Every refused line above carried a s3cr3t-<n> value; container.env may hold
# credentials whatever the docs advise.
cat "$ERR" > "$TMP/all-err"
grep -q 's3cr3t' "$TMP/all-err" && fail "E6 a refused value was printed: $(grep s3cr3t "$TMP/all-err" | head -2)" \
  || pass "E6 no warning prints a value"

# ── E7: nothing passed → no --env-file and no key list at all ─────────────────
printf 'PATH=/x\nHOME=/y\n' > "$CENV"
launch
ran && ! has_flag --env-file && ! grep -q '^AI_CONTAINER_ENV_KEYS=' "$CAPTURE" \
  && pass "E7 a container.env with nothing left passes neither --env-file nor a key list" \
  || fail "E7 nothing left → no --env-file (args: $(grep -A1 -- '--env-file' "$CAPTURE" | tr '\n' ' '))"
rm -f "$CENV"; launch
ran && ! has_flag --env-file && ! grep -q '^AI_CONTAINER_ENV_KEYS=' "$CAPTURE" \
  && pass "E7 no container.env → no --env-file, no key list" || fail "E7 no container.env → no --env-file"
SANDBOX_ENV_FILE="$TMP/nowhere.env" launch
ran && ! has_flag --env-file && grep -qF "SANDBOX_ENV_FILE=$TMP/nowhere.env not found" "$ERR" \
  && pass "E7 SANDBOX_ENV_FILE naming nothing warns and passes no --env-file" \
  || fail "E7 SANDBOX_ENV_FILE naming nothing warns and passes no --env-file"

# ── E8: a key only root reads is NOT refused — the entrypoint keeps it from root ─
# No list could name every key a root tool reads (XTABLES_LIBDIR picks the plugins
# iptables loads); this one passes, named, so the entrypoint sets it aside.
printf 'XTABLES_LIBDIR=/x\nALLOWLIST_CIDRS_FILE=/y\n' > "$CENV"
launch
[[ "$(keys_arg)" == "XTABLES_LIBDIR ALLOWLIST_CIDRS_FILE" ]] \
  && pass "E8 keys root tools read pass, named in AI_CONTAINER_ENV_KEYS for the entrypoint to set aside" \
  || fail "E8 keys root tools read are named — got '$(keys_arg)'"

# ── the deny-list itself, which sandbox.env's loader shares ──────────────────
eval "$(sed -n '/^env_key_denied()/,/^}/p' "$ENGINE/sandbox-common.sh")"
bad=""
for k in LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_ANY DYLD_INSERT_LIBRARIES DYLD_ANY GCONV_PATH LOCPATH \
         GLIBC_TUNABLES POSIXLY_CORRECT BASH_COMPAT BASH_XTRACEFD GLOBIGNORE BASH_FUNC_x%%; do
  env_key_denied "$k" || bad+=" $k"
done
for k in LDAP_URL DB_HOST XTABLES_LIBDIR; do env_key_denied "$k" && bad+=" (wrongly)$k"; done
[[ -z "$bad" ]] && pass "env_key_denied covers every LD_*/DYLD_*, glibc's load paths and bash's start-up keys" \
  || fail "env_key_denied:$bad"

# ── E9–E11: the entrypoint sets the keys aside and gives them back ───────────
EP="$TMP/ep.sh"
{ printf 'set -euo pipefail\n'
  awk '/^app_env=\(\)$/{print} /^stash_app_env\(\) \{/,/^}$/{print} /^as_sandbox_user\(\) \{/,/^}$/{print}' "$ENGINE/entrypoint.sh"
} > "$EP"
grep -q '^stash_app_env()' "$EP" && grep -q '^as_sandbox_user()' "$EP" && grep -q '^app_env=()' "$EP" \
  || { printf 'SCAFFOLD-FAILED: cannot extract stash_app_env/as_sandbox_user from entrypoint.sh\n'; exit 1; }
# A fake runuser: drops `-u <user> --` and runs the rest, as the sandbox user would.
cat > "$TMP/bin/runuser" <<'RU'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
exec "$@"
RU
chmod +x "$TMP/bin/runuser"
mkdir -p "$TMP/cwd"; : > "$TMP/cwd/GLOBBED"
cat > "$TMP/drive.sh" <<'DRIVE'
. "$1"; stash_app_env
for kv in ${app_env[@]+"${app_env[@]}"}; do printf 'stash:%s\n' "${kv//$'\n'/|}"; done
printf 'root:%s\n' "$(env | grep -E '^(A|B|NL|GLOBBED|AI_CONTAINER_ENV_KEYS)=' | tr '\n' ,)"
sandbox_user=tester
printf 'user-A:%s\n' "$(as_sandbox_user printenv A)"
printf 'user-NL:%s\n' "$(as_sandbox_user printenv NL | tr '\n' '|')"
printf 'reached the end\n'
DRIVE
out="$(cd "$TMP/cwd" && env AI_CONTAINER_ENV_KEYS='A B NL GONE PPID * bad.name' A=1 B='two words' NL=$'x\ny' GLOBBED=1 \
        bash "$TMP/drive.sh" "$EP" 2>&1)"
grep -qx 'reached the end' <<<"$out" && pass "E9 setting keys aside never stops the entrypoint (a readonly PPID, a glob, a bad name)" \
  || fail "E9 setting keys aside never stops the entrypoint — got: $(tr '\n' ' ' <<<"$out")"
[[ "$(grep '^stash:' <<<"$out" | tr '\n' ,)" == "stash:A=1,stash:B=two words,stash:NL=x|y," ]] \
  && ! grep -q '^stash:PPID=' <<<"$out" && ! grep -q '^stash:GLOBBED' <<<"$out" \
  && pass "E9 each set key is kept exactly, newlines too; unset, readonly and globbed names are not" \
  || fail "E9 kept exactly — got: $(grep '^stash:' <<<"$out" | tr '\n' ' ')"
[[ "$(grep '^root:' <<<"$out")" == "root:GLOBBED=1," ]] \
  && pass "E10 root's environment no longer holds them, nor the key list" \
  || fail "E10 root's environment no longer holds them — got: $(grep '^root:' <<<"$out")"
grep -qx 'user-A:1' <<<"$out" && grep -qx 'user-NL:x|y|' <<<"$out" \
  && pass "E11 a process run as the sandbox user gets them back, exactly" \
  || fail "E11 the sandbox user gets them back — got: $(grep '^user-' <<<"$out" | tr '\n' ' ')"
# And every place the entrypoint hands over to the sandbox user does give them
# back: the runuser calls go through as_sandbox_user (run_services' start filters
# app_env itself), and all three modes' final shells pass app_env through capsh.
n_shell="$(grep -cF -- "-- -c 'exec env \"\$@\" /bin/bash -l' bash \${app_env[@]+\"\${app_env[@]}\"}" "$ENGINE/entrypoint.sh")"
n_bare="$(grep -cE 'runuser -u "\$sandbox_user" -- *\\?$' "$ENGINE/entrypoint.sh")"
[[ "$n_shell" == 3 && "$n_bare" == 0 ]] \
  && pass "E11 all three modes' shells, and every runuser hand-over, give container.env back" \
  || fail "E11 hand-overs give container.env back (final shells: $n_shell of 3; bare runuser: $n_bare)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
