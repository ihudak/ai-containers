#!/usr/bin/env bash
# GAP-6: sync-to-projects.sh brings a project's generated runme.sh up to the
# current template while nobody has edited it, and leaves an edited one alone.
#
# launcher-templates/<n>.sh holds every thin launcher project-init.sh has ever
# generated, the project name replaced by @@PROJECT_NAME@@; the highest number is
# the one emit_launcher() writes now. reconcile_launcher() recognises a launcher
# as one of them — as generated, or as earlier syncs left it (their sed turned
# every `./runme.sh` into `./sandbox.sh`, comments included, and GIT-20's
# backfill inserted `unset CDPATH`) — and rewrites it with emit_launcher().
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck disable=SC1090
source "$REPO_DIR/sync-to-projects.sh"
set +e  # it turns errexit on; the checks below read non-zero returns
declare -F reconcile_launcher >/dev/null || { printf 'FAIL: sync-to-projects.sh defines no reconcile_launcher\n'; exit 1; }

TPL="$REPO_DIR/launcher-templates"
PH='@@PROJECT_NAME@@'

# emit NAME FILE — what project-init.sh would write today.
emit() {
  # shellcheck disable=SC1090
  ( source "$REPO_DIR/project-init.sh" 2>/dev/null; emit_launcher "$2" "$1" )
}
# render N NAME — template N with the project's name in it (literal, any bytes).
render() {
  local s; s="$(cat "$TPL/$1.sh"; printf x)"; s="${s%x}"
  printf '%s' "${s//"$PH"/"$2"}"
}
# What earlier syncs did to a launcher in place, modelled from their code
# (migrate_launcher_naming's sed before this change, then GIT-20's backfill).
old_sync() {
  # shellcheck disable=SC2016  # the cd line is matched as text
  sed 's#\./runme\.sh#./sandbox.sh#g' | awk -v cdline='cd "$(dirname "${BASH_SOURCE[0]}")"' '
    !done && index($0, cdline) == 1 && !seen {
      print "# A CDPATH from your shell would send this cd to another project'"'"'s launcher."
      print "unset CDPATH"; done = 1 }
    /^unset CDPATH/ { seen = 1 }
    { print }'
}
newproj() { local d="$TMP/$1/.ai-containers"; mkdir -p "$d"; printf '%s' "$d"; }

# ── 1. The templates: numbered 1..N, distinct, and N is what emit_launcher writes ──
n=0; while [[ -f "$TPL/$((n+1)).sh" ]]; do n=$((n+1)); done
count="$(find "$TPL" -type f | wc -l | tr -d ' ')"
(( n >= 4 && count == n )) && pass "launcher-templates holds 1..$n and nothing else" \
  || fail "launcher-templates holds 1..N and nothing else (N=$n, files=$count)"
emit "$PH" "$TMP/now.sh"
cmp -s "$TMP/now.sh" "$TPL/$n.sh" && pass "emit_launcher writes launcher-templates/$n.sh" \
  || fail "emit_launcher writes launcher-templates/$n.sh — a changed template needs a new numbered file: $(diff "$TPL/$n.sh" "$TMP/now.sh" | head -5)"
grep -qF "(launcher template $n)" "$TMP/now.sh" && pass "the launcher names its template number ($n)" \
  || fail "the launcher names its template number ($n)"
dups="$(for f in "$TPL"/*.sh; do p_sha1 "$f"; done | sort | uniq -d)"
[[ -z "$dups" ]] && pass "no two templates are the same" || fail "no two templates are the same"

# ── 2. Every earlier template, as generated and as old syncs left it, is replaced ──
names=(fip.srv 'odd & name \1 $HOME "q" `x`')
for (( i = 1; i < n; i++ )); do
  for name in "${names[@]}"; do
    for form in generated synced; do
      d="$(newproj "p$i-$form-$RANDOM")"
      if [[ "$form" == generated ]]; then render "$i" "$name" > "$d/runme.sh"
      else render "$i" "$name" | old_sync > "$d/runme.sh"; fi
      chmod 755 "$d/runme.sh"
      out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
      emit "$name" "$TMP/want.sh"
      if (( rc == 0 )) && cmp -s "$d/runme.sh" "$TMP/want.sh" && [[ -x "$d/runme.sh" && ! -L "$d/runme.sh" ]] \
         && [[ "$out" == *"template $n"* ]] && { [[ "$form" == synced ]] || [[ "$out" == *"template $i "* ]]; }; then
        pass "template $i ($form, name '${name:0:8}…') is regenerated as template $n"
      else
        fail "template $i ($form, name '$name') is regenerated as template $n (rc=$rc, out=$out): $(diff "$TMP/want.sh" "$d/runme.sh" | head -6)"
      fi
      leftover="$(find "$d" -mindepth 1 ! -name runme.sh)"
      [[ -z "$leftover" ]] || fail "regeneration left files behind: $leftover"
    done
  done
done

# ── 3. The current launcher is left exactly as it is, in silence ──
d="$(newproj cur)"; emit "fip.srv" "$d/runme.sh"; touch -t 202001010000 "$d/runme.sh"
before="$(p_sha1 "$d/runme.sh") $(p_stat_meta "$d/runme.sh")"
out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" && "$before" == "$(p_sha1 "$d/runme.sh") $(p_stat_meta "$d/runme.sh")" ]] \
  && pass "a current launcher is not rewritten and nothing is said" \
  || fail "a current launcher is not rewritten and nothing is said (rc=$rc, out=$out)"

# ── 4. An edited launcher is left alone, with a note saying how to compare ──
d="$(newproj edited)"; render 2 "fip.srv" > "$d/runme.sh"
sed -i.bak 's|^#\./build.sh --no-cache|./build.sh --no-cache|' "$d/runme.sh"; rm -f "$d/runme.sh.bak"
before="$(p_sha1 "$d/runme.sh")"
out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
[[ $rc -ne 0 && "$before" == "$(p_sha1 "$d/runme.sh")" && "$out" == *"edited"* && "$out" == *"launcher-templates/$n.sh"* ]] \
  && pass "an edited launcher is kept, named as edited, with the template to compare" \
  || fail "an edited launcher is kept, named as edited, with the template to compare (rc=$rc, out=$out)"

# ── 5. A fat launcher points at migrate-runme.sh ──
d="$(newproj fat)"
printf '#!/usr/bin/env bash\n# runme.sh — launch the AI sandbox for x.\nexport IMAGE_NAME=x\n./sandbox.sh\n' > "$d/runme.sh"
before="$(p_sha1 "$d/runme.sh")"
out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
[[ $rc -ne 0 && "$before" == "$(p_sha1 "$d/runme.sh")" && "$out" == *migrate-runme.sh* ]] \
  && pass "a fat launcher is kept and migrate-runme.sh is named" \
  || fail "a fat launcher is kept and migrate-runme.sh is named (rc=$rc, out=$out)"

# ── 6. A runme.sh that is a link is never written through, even to an old template ──
d="$(newproj link)"; render 2 "fip.srv" > "$TMP/elsewhere.sh"
ln -s "$TMP/elsewhere.sh" "$d/runme.sh"
before="$(p_sha1 "$TMP/elsewhere.sh")"
out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
[[ $rc -ne 0 && -L "$d/runme.sh" && "$before" == "$(p_sha1 "$TMP/elsewhere.sh")" && "$out" == *link* ]] \
  && pass "a linked runme.sh is not followed, and the link is named" \
  || fail "a linked runme.sh is not followed, and the link is named (rc=$rc, out=$out)"
# …nor by the legacy repairs a launcher sync does not recognise gets.
migrate_launcher_naming "$d"; backfill_launcher_cdpath "$d" >/dev/null
[[ -L "$d/runme.sh" && "$before" == "$(p_sha1 "$TMP/elsewhere.sh")" ]] \
  && pass "the legacy repairs leave a linked runme.sh and its target alone" \
  || fail "the legacy repairs leave a linked runme.sh and its target alone"

# ── 7. No runme.sh: nothing is made, nothing is said ──
d="$(newproj none)"
out="$(reconcile_launcher "$d" 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" && ! -e "$d/runme.sh" ]] && pass "no runme.sh: nothing made, nothing said" \
  || fail "no runme.sh: nothing made, nothing said (rc=$rc, out=$out)"

# ── 8. The legacy self-call repair no longer rewrites comments ──
d="$(newproj comments)"
printf '#!/usr/bin/env bash\n# One-off:  SANDBOX_MODE=restricted ./runme.sh\n./runme.sh discovery ..\n' > "$d/runme.sh"
migrate_launcher_naming "$d"
[[ "$(sed -n 2p "$d/runme.sh")" == '# One-off:  SANDBOX_MODE=restricted ./runme.sh' && "$(sed -n 3p "$d/runme.sh")" == './sandbox.sh discovery ..' ]] \
  && pass "migrate_launcher_naming repoints the self-call and leaves comments alone" \
  || fail "migrate_launcher_naming repoints the self-call and leaves comments alone: $(cat "$d/runme.sh")"

# ── 9. End to end: sync_project regenerates an old launcher ──
proj="$TMP/e2e"; mkdir -p "$proj/.ai-containers"
git -C "$proj" init -q 2>/dev/null
render 1 "e2e" | old_sync > "$proj/.ai-containers/runme.sh"; chmod 755 "$proj/.ai-containers/runme.sh"
printf '# schema-version: 1\n' > "$proj/.ai-containers/sandbox.conf"
sync_project "$proj" >"$TMP/sync.out" 2>&1; rc=$?
emit "e2e" "$TMP/want.sh"
[[ $rc -eq 0 ]] && cmp -s "$proj/.ai-containers/runme.sh" "$TMP/want.sh" \
  && pass "sync_project regenerates an old launcher" \
  || fail "sync_project regenerates an old launcher (rc=$rc): $(tail -5 "$TMP/sync.out")"

(( fails == 0 )) || { printf '%d failure(s)\n' "$fails"; exit 1; }
printf 'All launcher-template checks passed.\n'
