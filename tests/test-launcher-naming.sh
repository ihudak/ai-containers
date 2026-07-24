#!/usr/bin/env bash
# Verifies project-init.sh emits a runme.sh launcher that calls ./sandbox.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
proj="$TMP/myproj"; mkdir -p "$proj"

# Isolated HOME so the group-init prompt fires deterministically regardless of
# what the real operator's ~/.ai-containers looks like (mirrors
# tests/test-project-init.sh's isolation rationale).
export HOME="$TMP/home"; mkdir -p "$HOME"

# Drive project-init non-interactively: register the project dir, accept
# defaults for every remaining prompt. Actual prompt order is: path, name,
# image, cpus, memory, memory-reservation, memory-swap, group, group-init
# menu (fires because $HOME/.ai-containers/default doesn't exist), extra
# mounts — i.e. path plus 9 blank/default lines. No overwrite prompt fires
# on a first run (launcher doesn't exist yet).
printf '%s\n\n\n\n\n\n\n\n\n\n' "$proj" | ( cd "$SCRIPT_DIR" && ./project-init.sh ) >/dev/null 2>&1 || true

launcher="$proj/.ai-containers/runme.sh"
fail=0
[[ -f "$launcher" ]] || { echo "FAIL: launcher not named runme.sh"; fail=1; }
[[ ! -f "$proj/.ai-containers/myproj-container.sh" ]] || { echo "FAIL: legacy <project>-container.sh still emitted"; fail=1; }
grep -q './sandbox.sh' "$launcher" 2>/dev/null || { echo "FAIL: launcher does not call ./sandbox.sh"; fail=1; }
grep -q 'export IMAGE_NAME=' "$launcher" 2>/dev/null || { echo "FAIL: launcher missing IMAGE_NAME marker"; fail=1; }
(( fail == 0 )) && echo "PASS: launcher naming" || exit 1
