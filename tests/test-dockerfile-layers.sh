#!/usr/bin/env bash
# Runs the TEXT of two Dockerfile layers — taken from the Dockerfile itself, under
# its own SHELL (bash -euo pipefail -c) — against fake curl/gpg/apt-get/sdk, to
# show that a failed install fails the layer instead of shipping an image without
# what sandbox.conf asked for (bugs review BLD-1, BLD-2). No docker build: the
# absolute paths the mongo arm writes are redirected into a temp root.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/Dockerfile" ]] || ENGINE_DIR="$REPO_DIR/base"
DF="$ENGINE_DIR/Dockerfile"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# layer <fixed string>: the shell text of the first RUN whose first line holds it,
# continuations joined the way docker joins them.
layer() {
  awk -v want="$1" '
    !on && /^RUN / && index($0, want) { on = 1; sub(/^RUN /, "") }
    on { if (sub(/\\$/, "")) { printf "%s", $0; next } print; exit }
  ' "$DF"
}
# The SHELL every RUN gets; asserted, not assumed, since the cases depend on it.
grep -qx 'SHELL \["/bin/bash", "-euo", "pipefail", "-c"\]' "$DF" \
  && pass "the Dockerfile SHELL is bash -euo pipefail -c" || fail "the Dockerfile SHELL changed; these cases model the old one"

# ── BLD-2: a bad SDKMAN version that is not the last ─────────────────────────
# Each loop runs in a nested `bash -c`, which does not get -e, so the loop's
# status was its LAST iteration's: `openjdk=21.0.5,17.0.99` (a typo in the
# second) built green without 17.
mkdir -p "$TMP/sdkman/bin"
cat > "$TMP/sdkman/bin/sdkman-init.sh" <<EOF
sdk() { echo "sdk \$*" >> "$TMP/sdk.log"; case "\$*" in *99*) return 1 ;; esac; }
EOF
for spec in 'OPENJDK_VERSIONS|sdk install java \${ver}-tem' 'GRAALVM_VERSIONS|-graalce; done' \
            'GRAALVM_ORACLE_VERSIONS|-graal; done' 'KOTLIN_VERSIONS|sdk install kotlin' \
            'SCALA_VERSIONS|sdk install scala' 'MAVEN_VERSIONS|sdk install maven' 'GRADLE_VERSIONS|sdk install gradle'; do
  var="${spec%%|*}"
  text="$(layer "[ -n \"\$$var\" ]")"
  [[ -n "$text" ]] || { fail "SCAFFOLD: no RUN layer for $var"; continue; }
  # The links after the loop write /usr/local/bin, which a non-root run could not:
  # redirected, or every case here would fail for that reason alone.
  text="${text//\/usr\/local\/bin/$TMP/localbin}"; mkdir -p "$TMP/localbin"
  # Both runs, so a layer that fails for any OTHER reason (a missing init script,
  # a path it cannot write) cannot pass the bad-version case (review of batch 6).
  : > "$TMP/sdk.log"
  env -i PATH="$PATH" HOME="$TMP" SDKMAN_DIR="$TMP/sdkman" INSTALL_SDKMAN=1 "$var=1.0.0 2.0.0" \
    bash -euo pipefail -c "$text" >/dev/null 2>&1
  rc=$?
  [[ "$rc" == 0 && "$(grep -c '^sdk install' "$TMP/sdk.log")" == 2 ]] && pass "$var: the layer installs every good version" \
    || fail "$var: the layer failed with good versions (rc=$rc; $(tr '\n' ';' < "$TMP/sdk.log"))"
  : > "$TMP/sdk.log"
  env -i PATH="$PATH" HOME="$TMP" SDKMAN_DIR="$TMP/sdkman" INSTALL_SDKMAN=1 "$var=1.0.99 2.0.0" \
    bash -euo pipefail -c "$text" >/dev/null 2>&1
  rc=$?
  [[ "$rc" != 0 ]] && grep -q '1\.0\.99' "$TMP/sdk.log" && pass "$var: a failed install that is not the last fails the layer" \
    || fail "$var: the layer succeeded although '1.0.99' failed ($(tr '\n' ';' < "$TMP/sdk.log"))"
done

# ── BLD-1: the db-clients=mongo arm ──────────────────────────────────────────
# One && list inside a for/case, followed by `rm -rf …; fi`: under -e a failure
# anywhere but its last command was ignored, and the layer exited with the rm's 0.
mongo="$(layer '[ -n "$DB_CLIENTS" ]')"
[[ -n "$mongo" ]] || fail "SCAFFOLD: no DB_CLIENTS layer"
mongo="${mongo//\/usr\/share\/keyrings/$TMP/root/keyrings}"
mongo="${mongo//\/etc\/apt\/sources.list.d/$TMP/root/apt}"
mongo="${mongo//\/var\/lib\/apt\/lists/$TMP/root/lists}"
mongo="${mongo//\/usr\/bin\/mongosh/$TMP/root/bin/mongosh}"
mkdir -p "$TMP/fake"
cat > "$TMP/fake/curl" <<'EOF'
#!/bin/sh
[ "${CURL_FAIL:-0}" = 1 ] && exit 22
echo "-----BEGIN PGP PUBLIC KEY BLOCK-----"
EOF
cat > "$TMP/fake/gpg" <<'EOF'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
cat >/dev/null; [ -n "$out" ] && : > "$out"
EOF
cat > "$TMP/fake/apt-get" <<EOF
#!/bin/sh
case "\$*" in
  *update*) [ "\${UPDATE_FAIL:-0}" = 1 ] && case "\$*" in *--error-on=any*) exit 100 ;; esac; exit 0 ;;
  *mongodb-mongosh*) [ "\${NO_MONGOSH:-0}" = 1 ] || { mkdir -p "$TMP/root/bin"; printf '#!/bin/sh\n' > "$TMP/root/bin/mongosh"; chmod +x "$TMP/root/bin/mongosh"; }; exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho amd64\n' > "$TMP/fake/dpkg"
chmod +x "$TMP/fake/"*
mongo_run() {  # <ENV=value>… → rc
  rm -rf "$TMP/root"; mkdir -p "$TMP/root/keyrings" "$TMP/root/apt" "$TMP/root/lists"
  env -i PATH="$TMP/fake:$PATH" DB_CLIENTS=mongo "$@" bash -euo pipefail -c "$mongo" >/dev/null 2>&1
}
mongo_run; [[ $? == 0 && -x "$TMP/root/bin/mongosh" ]] && pass "db-clients=mongo: the arm succeeds when every step does" \
  || fail "db-clients=mongo: the arm fails with every step succeeding"
mongo_run CURL_FAIL=1; [[ $? != 0 ]] && pass "db-clients=mongo: a failed key fetch fails the layer" \
  || fail "db-clients=mongo: a failed key fetch left the layer green"
mongo_run UPDATE_FAIL=1; [[ $? != 0 ]] && pass "db-clients=mongo: a repository that did not load fails the layer" \
  || fail "db-clients=mongo: apt-get update ignored a repository that did not load"
mongo_run NO_MONGOSH=1; [[ $? != 0 ]] && pass "db-clients=mongo: no mongosh after the install fails the layer" \
  || fail "db-clients=mongo: the layer succeeded with no /usr/bin/mongosh"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
