#!/usr/bin/env bash
# Unit tests for tools-lib.sh descriptor parsing.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TOOLS_D_DIR="$TMP/tools.d"; mkdir -p "$TOOLS_D_DIR"
cat > "$TOOLS_D_DIR/foo.conf" <<'EOF'
repo=acme/foo
binary=foo
private=yes
config_dir=.config/foo
allowlist_fragment=acme
skills=yes
skills_crossclient=--for cross-client   # inline comment ignored
EOF
cat > "$TOOLS_D_DIR/bar.conf" <<'EOF'
repo=acme/bar
EOF

# shellcheck source=/dev/null
source "$REPO_DIR/tools-lib.sh"

names="$(tools_list_names | sort | tr '\n' ' ')"
[[ "$names" == "bar foo " ]] && pass "list names" || fail "list names ($names)"

tools_read_descriptor foo
[[ "$TOOL_repo" == "acme/foo" ]] && pass "repo" || fail "repo ($TOOL_repo)"
# shellcheck disable=SC2154  # TOOL_private: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_private" == "yes" ]] && pass "private" || fail "private"
[[ "$TOOL_config_dir" == ".config/foo" ]] && pass "config_dir" || fail "config_dir"
# shellcheck disable=SC2154  # TOOL_skills_crossclient: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_skills_crossclient" == "--for cross-client" ]] && pass "crossclient trims comment" || fail "crossclient ($TOOL_skills_crossclient)"

# Defaults + reset: bar omits everything; binary defaults to name, private to no,
# and foo's values must not leak.
tools_read_descriptor bar
# shellcheck disable=SC2154  # TOOL_binary: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_binary" == "bar" ]] && pass "binary default" || fail "binary default ($TOOL_binary)"
[[ "$TOOL_private" == "no" ]] && pass "private default" || fail "private default"
[[ -z "$TOOL_config_dir" ]] && pass "no leak" || fail "no leak ($TOOL_config_dir)"

# A '#' inside a VALUE is data, not a comment: a URL may carry a fragment or a
# '#' in a query string, and a blind ${line%%#*} silently truncated it (losing
# the rest of the URL, placeholders included) with no warning.
cat > "$TOOLS_D_DIR/hashy.conf" <<'EOF'
url=https://vendor.example/dl?token=abc#frag&arch=${ARCH}
binary=hashy   # this trailing comment IS stripped
EOF
tools_read_descriptor hashy
# shellcheck disable=SC2154  # TOOL_url: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_url" == 'https://vendor.example/dl?token=abc#frag&arch=${ARCH}' ]] \
  && pass "a '#' inside a value survives (URL fragment / query)" \
  || fail "'#' inside a value ($TOOL_url)"
[[ "$TOOL_binary" == "hashy" ]] \
  && pass "a whitespace-preceded '#' is still a comment" || fail "trailing comment ($TOOL_binary)"
rm -f "$TOOLS_D_DIR/hashy.conf"

tools_read_descriptor missing && fail "missing returns 0" || pass "missing returns 1"

# --- install=repo-file + multi-path config_dir ----------------------------------
# A descriptor for a tool whose prebuilt binary is COMMITTED IN a repo instead of
# published as a release asset, and whose state spans two directories.
cat > "$TOOLS_D_DIR/ext.conf" <<'EOF'
repo=acme/vendored
binary=ext-cli
install=repo-file
repo_path=utils/ext/ext-cli-linux-${ARCH}
ref=main
config_dir=.ext .config/ext-cli
EOF
tools_read_descriptor ext
# shellcheck disable=SC2154  # TOOL_install: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_install" == "repo-file" ]] && pass "install parsed" || fail "install parsed ($TOOL_install)"
[[ "$TOOL_repo_path" == 'utils/ext/ext-cli-linux-${ARCH}' ]] \
  && pass "repo_path parsed verbatim (\${ARCH} not expanded at parse time)" \
  || fail "repo_path parsed ($TOOL_repo_path)"
[[ "$TOOL_ref" == "main" ]] && pass "ref parsed" || fail "ref parsed ($TOOL_ref)"
[[ "$TOOL_config_dir" == ".ext .config/ext-cli" ]] \
  && pass "config_dir keeps a space-separated list" || fail "config_dir list ($TOOL_config_dir)"
got="$(set -- $TOOL_config_dir; printf '%s|' "$@")"
[[ "$got" == ".ext|.config/ext-cli|" ]] \
  && pass "config_dir splits into 2 paths" || fail "config_dir splits ($got)"
tools_read_descriptor foo
[[ "$TOOL_install" == "release" ]] && pass "install defaults to release" || fail "install default ($TOOL_install)"
[[ -z "$TOOL_repo_path" && -z "$TOOL_ref" ]] && pass "repo_path/ref do not leak" || fail "repo_path/ref leak"
rm -f "$TOOLS_D_DIR/ext.conf"

# Real descriptors: pin the dtctl/dtmgd cross-client invocations, which differ
# by a subtle space (--cross-client vs --for cross-client). Field-level, not
# list-level, so this holds in repos that ship additional descriptors.
_saved_td="$TOOLS_D_DIR"; export TOOLS_D_DIR="$REPO_DIR/tools.d"
tools_read_descriptor dtctl
[[ "$TOOL_repo" == "dynatrace-oss/dtctl" && "$TOOL_skills_crossclient" == "--cross-client" ]] \
  && pass "dtctl descriptor" || fail "dtctl descriptor ($TOOL_repo / $TOOL_skills_crossclient)"
tools_read_descriptor dtmgd
[[ "$TOOL_repo" == "dynatrace-oss/dtmgd" && "$TOOL_skills_crossclient" == "--for cross-client" ]] \
  && pass "dtmgd descriptor" || fail "dtmgd descriptor ($TOOL_repo / $TOOL_skills_crossclient)"
tools_read_descriptor acli
# shellcheck disable=SC2154  # TOOL_allowlist_fragment: set by tools_read_descriptor() in tools-lib.sh (sourced with source=/dev/null above, so shellcheck can't see it)
[[ "$TOOL_install" == "url" && "$TOOL_binary" == "acli" && -z "$TOOL_repo" \
   && "$TOOL_url" == 'https://acli.atlassian.com/${OS}/latest/acli_${OS}_${ARCH}.tar.gz' \
   && "$TOOL_config_dir" == ".config/acli" && "$TOOL_allowlist_fragment" == "atlassian" ]] \
  && pass "acli descriptor (install=url, vendor host, group-scoped config)" \
  || fail "acli descriptor ($TOOL_install / $TOOL_binary / $TOOL_url / $TOOL_config_dir / $TOOL_allowlist_fragment)"
# The fragment it names must exist in both families, and the key must exist, or
# acli installs but cannot reach Atlassian / cannot be switched on at all.
# Derived from the descriptor, so renaming allowlist_fragment= without adding the
# matching fragment files is caught here rather than at container runtime.
_frag="$TOOL_allowlist_fragment"
[[ -n "$_frag" && -f "$REPO_DIR/allowlist-domains.d/${_frag}.txt" \
   && -f "$REPO_DIR/allowlist-proxy-domains.d/${_frag}.txt" ]] \
  && pass "acli's allowlist_fragment resolves to real fragment files" \
  || fail "acli's allowlist_fragment ($_frag) resolves to real fragment files"
grep -qx 'api.atlassian.com'  "$REPO_DIR/allowlist-domains.d/atlassian.txt" \
  && grep -qx 'auth.atlassian.com' "$REPO_DIR/allowlist-domains.d/atlassian.txt" \
  && grep -qx 'acli.atlassian.com' "$REPO_DIR/allowlist-domains.d/atlassian.txt" \
  && grep -qx '\*.atlassian.net'   "$REPO_DIR/allowlist-proxy-domains.d/atlassian.txt" \
  && pass "atlassian fragments carry the gateway, download and site hosts" \
  || fail "atlassian fragments carry the gateway, download and site hosts"
grep -qx 'acli=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "acli key present in sandbox.conf, default OFF" \
  || fail "acli key present in sandbox.conf, default OFF"
export TOOLS_D_DIR="$_saved_td"

# --- install-tools.sh pure helpers ---------------------------------------------
export TOOLS_LIB="$REPO_DIR/tools-lib.sh"
# shellcheck disable=SC2034  # OS/ARCH: pin install-tools.sh's `${OS:-...}`/`${ARCH:-...}` defaults deterministically; consumed via that expansion once sourced below (source=/dev/null hides it from shellcheck)
OS=linux ARCH=amd64
# shellcheck source=/dev/null
source "$REPO_DIR/install-tools.sh"   # sourced, not executed (guarded main)

[[ "$(asset_name dtctl v0.25.0)" == "dtctl_0.25.0_linux_amd64.tar.gz" ]] \
  && pass "asset_name" || fail "asset_name ($(asset_name dtctl v0.25.0))"

# --- ARCH resolution --------------------------------------------------------------
# Both fetch modes key off ARCH: asset_name embeds it, and repo_path may template
# ${ARCH}. A wrong value installs a binary for the wrong machine and only fails at
# runtime with "cannot execute binary file", so pin the uname mapping. ARCH comes
# from `uname -m` INSIDE the build container, i.e. the image's own platform.
for _pair in "x86_64:amd64" "aarch64:arm64"; do
  _u="${_pair%%:*}"; _want="${_pair##*:}"
  mkdir -p "$TMP/un-$_u"
  printf '#!/usr/bin/env bash\nif [[ "$1" == "-s" ]]; then echo Linux; else echo %s; fi\n' "$_u" \
    > "$TMP/un-$_u/uname"
  chmod +x "$TMP/un-$_u/uname"
  _got="$(PATH="$TMP/un-$_u:$PATH" TOOLS_LIB="$REPO_DIR/tools-lib.sh" \
    bash -c 'unset ARCH OS; source "$TOOLS_LIB"; source '"$REPO_DIR"'/install-tools.sh; printf "%s/%s" "$OS" "$ARCH"')"
  [[ "$_got" == "linux/$_want" ]] \
    && pass "ARCH: uname -m $_u -> $_want" || fail "ARCH: uname -m $_u -> $_got (want linux/$_want)"
done

got="$(parse_versions 'dtctl=0.25.0;toolx=latest;empty=' | tr '\t' ':' | tr '\n' ' ')"
[[ "$got" == "dtctl:0.25.0 toolx:latest empty: " ]] \
  && pass "parse_versions" || fail "parse_versions ($got)"

# --- install=repo-file fetch (fake curl; nothing leaves the machine) -----------
cat > "$TOOLS_D_DIR/ext.conf" <<'EOF'
repo=acme/vendored
binary=ext-cli
install=repo-file
repo_path=utils/ext/ext-cli-linux-${ARCH}
EOF
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
CURL_LOG="$TMP/curl.log"
cat > "$FAKEBIN/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CURL_LOG"
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
[[ -n "\$out" ]] && printf 'ELF-ish payload\n' > "\$out"
exit 0
CURL
chmod +x "$FAKEBIN/curl"

# BIN_DIR is resolved from TOOLS_BIN_DIR when install-tools.sh is SOURCED (which
# already happened above), so set the in-scope variable directly. Belt and braces:
# also export TOOLS_BIN_DIR for anything that re-reads it.
export TOOLS_BIN_DIR="$TMP/bin"; mkdir -p "$TOOLS_BIN_DIR"
BIN_DIR="$TOOLS_BIN_DIR"
: > "$CURL_LOG"
out="$(PATH="$FAKEBIN:$PATH" ARCH=arm64 install_one ext latest 2>&1)"
if grep -q 'https://api.github.com/repos/acme/vendored/contents/utils/ext/ext-cli-linux-arm64$' "$CURL_LOG"; then
  pass "repo-file: contents API URL built, \${ARCH} expanded, no ref for latest"
else
  fail "repo-file URL ($(grep '^https' "$CURL_LOG" | head -1))"; fi
if grep -qx 'Accept: application/vnd.github.raw' "$CURL_LOG"; then
  pass "repo-file: raw media type requested"; else fail "repo-file: raw media type requested"; fi
if [[ -x "$TOOLS_BIN_DIR/ext-cli" ]]; then
  pass "repo-file: binary installed executable"; else fail "repo-file: binary installed executable"; fi

# An explicit ref (from the sandbox.conf value) must reach the URL.
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
PATH="$FAKEBIN:$PATH" ARCH=amd64 install_one ext 9f3c1ab >/dev/null 2>&1
if grep -q 'contents/utils/ext/ext-cli-linux-amd64?ref=9f3c1ab$' "$CURL_LOG"; then
  pass "repo-file: sandbox.conf value used as git ref"; else fail "repo-file ref ($(grep '^https' "$CURL_LOG" | head -1))"; fi

# The descriptor's own ref= is the default when the key is just ON (latest).
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\nref=release-1\n' \
  > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
PATH="$FAKEBIN:$PATH" install_one ext latest >/dev/null 2>&1
if grep -q 'contents/utils/ext/ext-cli?ref=release-1$' "$CURL_LOG"; then
  pass "repo-file: descriptor ref= is the default for ON"; else fail "repo-file descriptor ref ($(grep '^https' "$CURL_LOG" | head -1))"; fi

# A private repo-file tool with no token must skip BEFORE any curl.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nprivate=yes\nrepo_path=utils/ext/ext-cli\n' \
  > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
out="$( unset GITHUB_TOKEN; PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1 )"
if [[ "$out" == *"requires GITHUB_TOKEN"* ]] && [[ ! -s "$CURL_LOG" ]] && [[ ! -e "$TOOLS_BIN_DIR/ext-cli" ]]; then
  pass "repo-file: private with no token skips before any fetch"
else
  fail "repo-file private/no-token guard"; fi

# A failed download must warn and install NOTHING. Until this case existed every
# fake curl in this file exited 0, so a "report success on failure" bug was
# invisible by construction.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLFAIL'
#!/usr/bin/env bash
exit 22   # what curl -f returns for an HTTP 4xx
CURLFAIL
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/ext-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"download failed"* ]] && [[ "$out" != *"Installed ext"* ]] && [[ ! -e "$BIN_DIR/ext-cli" ]]; then
  pass "repo-file: failed download warns and installs nothing"
else
  fail "repo-file: failed download ($out)"; fi
# ... and leaves no temp file behind.
if ! ls "${TMPDIR:-/tmp}"/ext-cli.* >/dev/null 2>&1; then
  pass "repo-file: failed download leaves no temp file"; else fail "repo-file: failed download leaves no temp file"; fi

# A JSON payload (what the contents API returns for a DIRECTORY path) must NOT be
# installed as the binary — curl -f cannot tell it from a file.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLJSON'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && printf '[{"name":"ext-cli-linux-arm64","type":"file"}]\n' > "$out"
exit 0
CURLJSON
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/ext-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"returned JSON"* ]] && [[ ! -e "$BIN_DIR/ext-cli" ]]; then
  pass "repo-file: JSON payload (directory path) rejected"; else fail "repo-file: JSON payload rejected ($out)"; fi

# An unwritable install dir must warn, not claim success.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLOK'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && printf 'payload\n' > "$out"
exit 0
CURLOK
chmod +x "$FAKEBIN/curl"
_saved_bin="$BIN_DIR"; BIN_DIR="$TMP/nonexistent-dir/bin"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"could not install"* ]] && [[ "$out" != *"Installed ext"* ]]; then
  pass "repo-file: unwritable install dir warns instead of claiming success"
else
  fail "repo-file: unwritable install dir ($out)"; fi
BIN_DIR="$_saved_bin"

# A repo-file descriptor missing repo_path warns instead of building a bad URL.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\n' > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"repo_path"* ]] && [[ ! -s "$CURL_LOG" ]]; then
  pass "repo-file: missing repo_path warns, no fetch"; else fail "repo-file missing repo_path ($out)"; fi
# Nothing may have leaked into the image's real install dir.
[[ ! -e /usr/local/bin/ext-cli ]] \
  && pass "repo-file: test never wrote to the real /usr/local/bin" \
  || fail "repo-file: test never wrote to the real /usr/local/bin"
unset TOOLS_BIN_DIR; BIN_DIR=/usr/local/bin
rm -f "$TOOLS_D_DIR/ext.conf"

# --- install=url (vendor-hosted download) --------------------------------------
# Driven with a fake curl that serves a locally built archive, so no network is
# touched. The archive deliberately NESTS the binary in a version-named
# directory, which is how Atlassian actually packages acli
# (acli_1.3.22-stable_linux_arm64/acli) — a plain `tar -C` would not find it.
cat > "$TOOLS_D_DIR/vend.conf" <<'EOF'
binary=vend-cli
install=url
url=https://vendor.example/${OS}/latest/vend_${OS}_${ARCH}.tar.gz
EOF
export TOOLS_BIN_DIR="$TMP/bin"; mkdir -p "$TOOLS_BIN_DIR"; BIN_DIR="$TOOLS_BIN_DIR"
# Point the installer's mktemp at our own dir: asserting on a shared /tmp glob
# would make the cleanup check depend on unrelated leftovers.
export TMPDIR="$TMP/work"; mkdir -p "$TMPDIR"
NEST="$TMP/nest/vend_1.2.3-stable_linux_arm64"; mkdir -p "$NEST"
# NOT executable in the archive: the installer's own chmod +x must be what makes
# it runnable, otherwise tar preserving the bit would mask a missing chmod.
printf '#!/bin/sh\necho vend 1.2.3\n' > "$NEST/vend-cli"; chmod 644 "$NEST/vend-cli"
( cd "$TMP/nest" && tar czf "$TMP/vend.tar.gz" . )
cat > "$FAKEBIN/curl" <<CURLURL
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CURL_LOG"
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
[[ -n "\$out" ]] && cp "$TMP/vend.tar.gz" "\$out"
exit 0
CURLURL
chmod +x "$FAKEBIN/curl"

: > "$CURL_LOG"; rm -f "$BIN_DIR/vend-cli"
out="$(PATH="$FAKEBIN:$PATH" OS=linux ARCH=arm64 install_one vend latest 2>&1)"
if grep -qx 'https://vendor.example/linux/latest/vend_linux_arm64.tar.gz' "$CURL_LOG"; then
  pass "install=url: \${OS}/\${ARCH} expanded in the URL"
else
  fail "install=url URL ($(grep '^https' "$CURL_LOG" | head -1))"; fi
if [[ -x "$BIN_DIR/vend-cli" ]] && "$BIN_DIR/vend-cli" | grep -q 'vend 1.2.3'; then
  pass "install=url: binary found inside a version-named directory and installed"
else
  fail "install=url: nested binary install ($out)"; fi
if [[ -z "$(ls -A "$TMPDIR" 2>/dev/null)" ]]; then
  pass "install=url: work directory cleaned up"; else fail "install=url: work directory cleaned up ($(ls -A "$TMPDIR" | tr '\n' ' '))"; fi
# The installed file must be executable because install_url chmod'ed it (the
# archive member is mode 644).
if [[ -x "$BIN_DIR/vend-cli" ]]; then
  pass "install=url: installed binary made executable"; else fail "install=url: installed binary made executable"; fi
# curl must be invoked with -f, or an HTTP error page would be installed as the
# binary, and with a retry so a flaky CDN does not fail the build.
if grep -qx -- '-fsSL' "$CURL_LOG" && grep -qx -- '--retry' "$CURL_LOG"; then
  pass "install=url: curl uses -f and retries"; else fail "install=url: curl flags ($(tr '\n' ' ' < "$CURL_LOG"))"; fi

# A bare (non-archive) URL is the binary itself.
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/bin/vend-cli\n' > "$TOOLS_D_DIR/vend.conf"
cat > "$FAKEBIN/curl" <<CURLBARE
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CURL_LOG"
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
printf '#!/bin/sh\necho bare-binary\n' > "\$out"
exit 0
CURLBARE
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/vend-cli"
PATH="$FAKEBIN:$PATH" install_one vend latest >/dev/null 2>&1
if [[ -x "$BIN_DIR/vend-cli" ]] && "$BIN_DIR/vend-cli" | grep -q 'bare-binary'; then
  pass "install=url: a non-archive URL is installed as the binary"; else fail "install=url: bare binary"; fi

# ${VERSION} comes from the sandbox.conf value.
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/v${VERSION}/vend\n' > "$TOOLS_D_DIR/vend.conf"
: > "$CURL_LOG"; rm -f "$BIN_DIR/vend-cli"
PATH="$FAKEBIN:$PATH" install_one vend 2.5.0 >/dev/null 2>&1
grep -qx 'https://vendor.example/v2.5.0/vend' "$CURL_LOG" \
  && pass "install=url: \${VERSION} expanded from the sandbox.conf value" \
  || fail "install=url: \${VERSION} ($(grep '^https' "$CURL_LOG" | head -1))"

# An archive with no matching binary must warn, not install junk.
printf 'binary=absent-cli\ninstall=url\nurl=https://vendor.example/x.tar.gz\n' > "$TOOLS_D_DIR/vend.conf"
cat > "$FAKEBIN/curl" <<CURLURL2
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
cp "$TMP/vend.tar.gz" "\$out"
exit 0
CURLURL2
chmod +x "$FAKEBIN/curl"
out="$(PATH="$FAKEBIN:$PATH" install_one vend latest 2>&1)"
if [[ "$out" == *"no 'absent-cli' file inside the archive"* ]] && [[ ! -e "$BIN_DIR/absent-cli" ]]; then
  pass "install=url: archive without the named binary warns"; else fail "install=url: missing binary in archive ($out)"; fi

# REGRESSION: an archive URL with a query string or fragment must still be
# unpacked. Matching on the whole URL let a signed/CDN link fall through to the
# "this is the binary" branch, which installed the tarball itself and reported
# success.
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/vend_${OS}_${ARCH}.tar.gz?token=abc\n' \
  > "$TOOLS_D_DIR/vend.conf"
cat > "$FAKEBIN/curl" <<CURLQ
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
cp "$TMP/vend.tar.gz" "\$out"
exit 0
CURLQ
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/vend-cli"
PATH="$FAKEBIN:$PATH" OS=linux ARCH=arm64 install_one vend latest >/dev/null 2>&1
if [[ -x "$BIN_DIR/vend-cli" ]] && "$BIN_DIR/vend-cli" 2>/dev/null | grep -q 'vend 1.2.3'; then
  pass "install=url: .tar.gz?query is still unpacked, not installed raw"
else
  fail "install=url: .tar.gz?query unpacked (got $(head -c4 "$BIN_DIR/vend-cli" 2>/dev/null | od -An -c | tr -s ' '))"; fi

# An archive holding two files with the target name must refuse to guess.
AMB="$TMP/amb"; mkdir -p "$AMB/a" "$AMB/b"
printf '#!/bin/sh\necho A\n' > "$AMB/a/vend-cli"; printf '#!/bin/sh\necho B\n' > "$AMB/b/vend-cli"
( cd "$AMB" && tar czf "$TMP/amb.tar.gz" . )
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/amb.tar.gz\n' > "$TOOLS_D_DIR/vend.conf"
cat > "$FAKEBIN/curl" <<CURLAMB
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
cp "$TMP/amb.tar.gz" "\$out"
exit 0
CURLAMB
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/vend-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one vend latest 2>&1)"
if [[ "$out" == *"refusing to guess"* ]] && [[ ! -e "$BIN_DIR/vend-cli" ]]; then
  pass "install=url: ambiguous archive refuses to guess"; else fail "install=url: ambiguous archive ($out)"; fi

# A pinned version that the url= template cannot express must say so.
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/latest/vend.tar.gz\n' > "$TOOLS_D_DIR/vend.conf"
out="$(PATH="$FAKEBIN:$PATH" install_one vend 9.9.9 2>&1)"
[[ "$out" == *"cannot be pinned"* ]] \
  && pass "install=url: pinned version with no \${VERSION} in url= warns" \
  || fail "install=url: pin warning ($out)"

# A failed download installs nothing.
printf 'binary=vend-cli\ninstall=url\nurl=https://vendor.example/x.tar.gz\n' > "$TOOLS_D_DIR/vend.conf"
printf '#!/usr/bin/env bash\nexit 22\n' > "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/vend-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one vend latest 2>&1)"
if [[ "$out" == *"download failed"* ]] && [[ ! -e "$BIN_DIR/vend-cli" ]]; then
  pass "install=url: failed download installs nothing"; else fail "install=url: failed download ($out)"; fi

# An empty url= warns instead of curling nothing.
printf 'binary=vend-cli\ninstall=url\n' > "$TOOLS_D_DIR/vend.conf"
out="$(PATH="$FAKEBIN:$PATH" install_one vend latest 2>&1)"
[[ "$out" == *"url= is empty"* ]] && pass "install=url: empty url= warns" || fail "install=url: empty url= ($out)"
unset TOOLS_BIN_DIR TMPDIR; BIN_DIR=/usr/local/bin
rm -f "$TOOLS_D_DIR/vend.conf"

# --- enabled_agents_csv --------------------------------------------------------
CONF="$TMP/sandbox.conf"
cat > "$CONF" <<'EOF'
claude-code=ON
copilot=ON
codex=OFF
gemini=OFF
kiro=OFF
EOF
export SANDBOX_CONF="$CONF"
# shellcheck source=/dev/null
source "$REPO_DIR/sandbox-common.sh"
[[ "$(enabled_agents_csv)" == "claude-code,copilot" ]] \
  && pass "enabled_agents_csv" || fail "enabled_agents_csv ($(enabled_agents_csv))"

# Every agent key must be reachable: with only OFF fixtures, dropping a key from
# the function's own list would go unnoticed. Flip each one ON in turn.
for _agent in claude-code copilot codex gemini kiro; do
  printf 'claude-code=OFF\ncopilot=OFF\ncodex=OFF\ngemini=OFF\nkiro=OFF\n' > "$CONF"
  conf_set() { sed -i.bak "s/^${1}=OFF/${1}=ON/" "$CONF" && rm -f "$CONF.bak"; }
  conf_set "$_agent"
  [[ "$(enabled_agents_csv)" == "$_agent" ]] \
    && pass "enabled_agents_csv: $_agent alone" \
    || fail "enabled_agents_csv: $_agent alone ($(enabled_agents_csv))"
done
# All five together, to pin the order the container relies on.
printf 'claude-code=ON\ncopilot=ON\ncodex=ON\ngemini=ON\nkiro=ON\n' > "$CONF"
[[ "$(enabled_agents_csv)" == "claude-code,copilot,codex,gemini,kiro" ]] \
  && pass "enabled_agents_csv: all five, stable order" \
  || fail "enabled_agents_csv: all five ($(enabled_agents_csv))"
# Restore the fixture the later build.sh assertions append to.
printf 'claude-code=ON\ncopilot=ON\ncodex=OFF\ngemini=OFF\nkiro=OFF\n' > "$CONF"

# --- build.sh pure helpers -----------------------------------------------------
# Reuse the earlier foo(private)/bar descriptors; enable foo (pinned) + bar (ON).
cat >> "$CONF" <<'EOF'
foo=1.2.3
bar=ON
EOF
# shellcheck source=/dev/null
source "$REPO_DIR/build.sh"   # guarded: sourcing must not build
set +e   # build.sh's `set -euo pipefail` leaks into this file via source; restore
         # this suite's intended mode so later non-idiom lines can't abort it.

tv="$(tool_versions_arg)"
[[ "$tv" == *"foo=1.2.3"* && "$tv" == *"bar=latest"* ]] \
  && pass "tool_versions_arg" || fail "tool_versions_arg ($tv)"

frags="$(active_tool_fragments | tr '\n' ' ')"
[[ "$frags" == *"acme"* ]] && pass "active_tool_fragments" || fail "active_tool_fragments ($frags)"

# Dedup: two DISTINCT active tools naming the same fragment must yield it once
# (the case sort -u exists for — dtctl and dtmgd both use `dynatrace`). Isolated
# in a subshell with its own TOOLS_D_DIR/SANDBOX_CONF so the main fixture is untouched.
_ddir="$TMP/dedup.d"; mkdir -p "$_ddir"
printf 'allowlist_fragment=shared\n' > "$_ddir/aa.conf"
printf 'allowlist_fragment=shared\n' > "$_ddir/bb.conf"
printf 'aa=ON\nbb=ON\n' > "$TMP/dedup.conf"
dedup_out="$(TOOLS_D_DIR="$_ddir" SANDBOX_CONF="$TMP/dedup.conf" bash -c '
  source "'"$REPO_DIR"'/sandbox-common.sh"; source "'"$REPO_DIR"'/build.sh"
  active_tool_fragments' | tr '\n' ' ')"
[[ "$dedup_out" == "shared " ]] && pass "active_tool_fragments dedup" || fail "active_tool_fragments dedup ($dedup_out)"


# foo is private + no token → preflight must warn on stderr, non-fatally.
( unset GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; preflight_private_tools ) 2>"$TMP/pf.err"
grep -q "PRIVATE tool is enabled" "$TMP/pf.err" && pass "preflight warns" || fail "preflight warns"

# --- sandbox.sh group-scoped tool config + AI_AGENTS_ENABLED ---------------------
RTMP="$(mktemp -d)"
export HOME="$RTMP/home"; mkdir -p "$HOME/.config/dtctl"; echo hostcfg > "$HOME/.config/dtctl/config"
export AI_CONTAINER_GROUP_INIT=clean
unset VAULT_PATH SPECS_PATH DOCS_PATH
unset TOOLS_D_DIR   # earlier sections in this file point it at a synthetic foo/bar
                    # dir; sandbox.sh must resolve the real repo tools.d (dtctl/dtmgd).
RCONF="$RTMP/sandbox.conf"
cat > "$RCONF" <<'EOF'
claude-code=ON
copilot=OFF
codex=OFF
gemini=OFF
kiro=OFF
dtctl=0.25.0
dtmgd=OFF
EOF
export SANDBOX_CONF="$RCONF"
mkdir -p "$RTMP/bin" "$RTMP/app"; CAP="$RTMP/args.txt"
cat > "$RTMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAP"; exit 0; fi
exit 1
DOCKER
chmod +x "$RTMP/bin/docker"
PATH="$RTMP/bin:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$RTMP" "$REPO_DIR/sandbox.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true

grep -q "\.ai-containers/.*/\.config/dtctl:" "$CAP" && pass "dtctl config mounted from group" || fail "dtctl config mount"
grep -qx "AI_AGENTS_ENABLED=claude-code" "$CAP" && pass "AI_AGENTS_ENABLED passed" || fail "AI_AGENTS_ENABLED"
# Seed: group copy created from host, containing the host's file.
GROOT="$HOME/.ai-containers"
find "$GROOT" -path '*/.config/dtctl/config' | grep -q . && pass "group dtctl seeded from host" || fail "seed from host"

# Second run: group dir already exists → must NOT be re-seeded (group state wins).
# Prove it by changing the host file and confirming the group copy is untouched.
echo hostcfg-changed > "$HOME/.config/dtctl/config"
PATH="$RTMP/bin:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$RTMP" "$REPO_DIR/sandbox.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true
GROUP_CFG="$(find "$GROOT" -path '*/.config/dtctl/config' | head -n1)"
[[ -n "$GROUP_CFG" ]] && [[ "$(cat "$GROUP_CFG")" == "hostcfg" ]] \
  && pass "group dtctl not re-seeded on second run" || fail "group dtctl not re-seeded on second run"
rm -rf "$RTMP"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
