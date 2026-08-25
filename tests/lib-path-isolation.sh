#!/usr/bin/env bash
# tests/lib-path-isolation.sh — make one tool unresolvable on a PATH, without
# taking anything else with it.
#
# A fixture that models "this tool is absent" cannot do it by prepending a stub
# directory: prepending SHADOWS a tool, it does not remove one, so a fixture
# that deliberately omits its stub still resolves the host's copy. That was a
# real defect (tests/test-rvm-fixture-isolation.sh records it), and removing the
# providing directory outright is the obvious repair.
#
# It is also a trap this repo has already sprung once. test-verify-exit-code.sh
# records it: filtering out "any directory containing shellcheck" also removed
# bash, git and sed, because on that machine they shared a directory, and the
# run died at exit 127 on a PATH self-inflicted wound. The same is possible
# here — rvm's usual installs give it a directory of its own (~/.rvm/bin,
# /usr/local/rvm/bin), but a system-wide install symlinked into /usr/local/bin
# would take that whole directory with it, and on a Homebrew prefix that is most
# of the toolchain.
#
# So a directory is dropped only when the tool is ALL it provides. Otherwise it
# is replaced by a shadow of symlinks to everything except the tool, which costs
# nothing in the common case (no shadow is built at all) and stays correct in
# the rare one.
set -uo pipefail

# path_without_tool <tool> <scratch-dir> [path] → a PATH value on which <tool>
# does not resolve and everything else still does. The scratch directory is the
# CALLER's to create and remove; this function only writes inside it.
path_without_tool() {
  local tool="$1" scratch="$2" src="${3-$PATH}"
  local d entry base n=0 kept=() IFS=':'
  read -ra _dirs <<< "$src"
  for d in "${_dirs[@]}"; do
    [[ -n "$d" ]] || continue
    if [[ ! -x "$d/$tool" ]]; then kept+=("$d"); continue; fi

    # This directory provides the tool. Rebuild it minus the tool, but only if
    # it provides anything else — the common case is a directory of its own,
    # where the answer is simply to drop it.
    local shadow="" made=0
    for entry in "$d"/*; do
      [[ -e "$entry" ]] || continue          # unmatched glob
      base="${entry##*/}"
      [[ "$base" == "$tool" ]] && continue
      if (( ! made )); then
        n=$((n+1)); shadow="$scratch/shadow-$n"
        mkdir -p "$shadow" || return 1
        made=1
      fi
      ln -sfn "$entry" "$shadow/$base" 2>/dev/null || true
    done
    (( made )) && kept+=("$shadow")
  done
  printf '%s' "${kept[*]}"
}
