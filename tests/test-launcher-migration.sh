#!/usr/bin/env bash
# Verifies sync migrates a pre-swap project (old-engine runme.sh + <proj>-container.sh)
# to (sandbox.sh engine + runme.sh launcher calling ./sandbox.sh), idempotently.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source sync-to-projects.sh for its helpers without running a sync.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/sync-to-projects.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dest="$TMP/proj/.ai-containers"; mkdir -p "$dest"

# Old engine (marker-less) named runme.sh:
printf '#!/usr/bin/env bash\n# old engine\necho engine\n' > "$dest/runme.sh"
# Old launcher <project>-container.sh (has the IMAGE_NAME marker, calls ./runme.sh):
printf '#!/usr/bin/env bash\nexport IMAGE_NAME=proj-ai-container\n./runme.sh discovery ..\n' > "$dest/proj-container.sh"

migrate_launcher_naming "$dest"

fail=0
grep -q 'export IMAGE_NAME=' "$dest/runme.sh" 2>/dev/null || { echo "FAIL: runme.sh is not the launcher"; fail=1; }
grep -q './sandbox.sh' "$dest/runme.sh" 2>/dev/null       || { echo "FAIL: launcher still calls old engine"; fail=1; }
[[ ! -f "$dest/proj-container.sh" ]]                       || { echo "FAIL: legacy launcher not renamed"; fail=1; }
grep -q 'old engine' "$dest/runme.sh" 2>/dev/null          && { echo "FAIL: stale engine survived as runme.sh"; fail=1; }

# Idempotency: second run must not change anything.
before="$(sha1sum "$dest/runme.sh")"
migrate_launcher_naming "$dest"
after="$(sha1sum "$dest/runme.sh")"
[[ "$before" == "$after" ]] || { echo "FAIL: second migration mutated the launcher"; fail=1; }

(( fail == 0 )) && echo "PASS: launcher migration" || exit 1
