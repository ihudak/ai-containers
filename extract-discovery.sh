#!/usr/bin/env bash
# extract-discovery.sh — turn a discovery-mode capture into hostname lists, on
# the host, without anyone having to remember the docker incantation.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
# Discovery mode writes a pcap into the launch directory's .agent-discovery/,
# and entrypoint.sh prints the command that turns it into hostname lists. That
# command carries three things the reader has to get right at the one moment
# they are least able to: after the container has exited, with the banner
# scrolled away. All three are already knowable from where this file sits.
# IMAGE_NAME resolves through sandbox-common.sh exactly as it does for
# build.sh/sandbox.sh (sandbox.local.env, then sandbox.env, with inline env
# still winning), and the capture is looked for in the launch directory — which
# in a CONSUMER PROJECT is the directory this script ships in, because that is
# where the generated runme.sh cd's to before launching. In the BASE REPO it is
# not: the engine sits at the repository root while the container is launched
# from the synced .ai-containers/ working copy, so that directory is searched
# too. Either way the normal invocation carries no arguments at all:
#
#   ./extract-discovery.sh
#
# It also answers the question the extract only sets up: of everything the agent
# reached for, WHICH hostnames restricted mode would not already allow. That
# verdict is read out of the image's own baked /tmp/allowlist-domains.txt and
# /tmp/allowlist-proxy-domains.txt, applying the same two matching rules
# capture-blocked-traffic.sh applies at runtime — exact, full-line match for the
# first; strip the leading "*" and suffix-match for the second. Reading the
# image rather than re-assembling the fragments means this cannot disagree with
# what the running container would actually do, and duplicates none of build.sh.
#
# ── WHY IT DELETES NOTHING BY DEFAULT ─────────────────────────────────────────
# The pcap is the only raw evidence, it is the only file here that reaches
# gigabytes, and re-extracting is possible exactly as long as it exists. So the
# default reports its size and the command to drop it; --clean drops it once the
# extract has succeeded; --discard drops a capture you have decided not to
# extract at all. Both remove only the specific filenames this script knows
# about — never `rm -rf` on a directory handed in — the same narrow-cleanup
# discipline remove_replaced_image() follows in sandbox-common.sh.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/sandbox-common.sh
source "${_here}/sandbox-common.sh"

# The files a capture directory holds, split by what losing them costs.
RAW_FILES=(agent-traffic.pcap tcpdump.log tcpdump.pid)   # big, re-creatable only by re-running discovery
DERIVED_FILES=(agent-dns.txt agent-sni.txt)              # small, and the whole point of the exercise

usage() {
  cat <<'EOF'
Usage:
  ./extract-discovery.sh [options] [capture-dir]

Turns a discovery-mode pcap into DNS and TLS-SNI hostname lists, then reports
which of those hostnames this image's allowlist does not already cover.

With no capture-dir, looks for .agent-discovery/ in the current directory, in
./.ai-containers/, then in those same two places beside this script. The
argument may be the capture directory or the launch directory holding it.

Options:
  --clean        after a successful extract, delete the raw capture
                 (agent-traffic.pcap, tcpdump.log, tcpdump.pid) and keep the
                 extracted hostname lists
  --discard      delete the capture WITHOUT extracting — for a session you have
                 decided not to analyse. Prompts unless --yes is given.
  --yes          answer the --discard prompt with "yes"
  -h, --help     this message

Environment:
  IMAGE_NAME     image to run the extract in (default: resolved from
                 sandbox.local.env / sandbox.env, else "ai-sandbox")
EOF
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# Bytes of a file, portably. `wc -c <file` avoids stat's GNU/BSD flag split
# (tests/portability.sh documents that divergence); macOS pads the number with
# leading spaces, hence the strip.
file_bytes() {  # $1 = path
  local n
  n="$(wc -c < "$1" 2>/dev/null)" || { printf '0'; return 0; }
  n="${n//[^0-9]/}"
  printf '%s' "${n:-0}"
}

human_size() {  # $1 = bytes
  local b="$1"
  if   (( b >= 1073741824 )); then printf '%d.%d GB' "$(( b / 1073741824 ))" "$(( b % 1073741824 * 10 / 1073741824 ))"
  elif (( b >= 1048576 ));    then printf '%d.%d MB' "$(( b / 1048576 ))"    "$(( b % 1048576 * 10 / 1048576 ))"
  elif (( b >= 1024 ));       then printf '%d KB'    "$(( b / 1024 ))"
  else                             printf '%d B'     "$b"
  fi
}

# Sum the sizes of the named files that exist in $capture_dir.
bytes_of() {  # $@ = basenames
  local total=0 f
  for f in "$@"; do
    [[ -f "$capture_dir/$f" ]] && total=$(( total + $(file_bytes "$capture_dir/$f") ))
  done
  printf '%s' "$total"
}

# Remove the named files from $capture_dir, reporting what went and how much it
# freed. Only these basenames, only inside this directory: never a recursive
# delete of a path the caller supplied.
remove_files() {  # $@ = basenames
  local freed=0 removed=0 f bytes
  for f in "$@"; do
    [[ -f "$capture_dir/$f" ]] || continue
    bytes="$(file_bytes "$capture_dir/$f")"
    if rm -f "$capture_dir/$f"; then
      freed=$(( freed + bytes )); removed=$(( removed + 1 ))
      printf '  removed %s (%s)\n' "$f" "$(human_size "$bytes")"
    else
      printf '  WARNING: could not remove %s\n' "$f" >&2
    fi
  done
  if (( removed == 0 )); then
    printf '  nothing to remove in %s\n' "$capture_dir"
  else
    printf '  freed %s\n' "$(human_size "$freed")"
  fi
}

# ── Arguments ─────────────────────────────────────────────────────────────────

do_clean=0
do_discard=0
assume_yes=0
capture_arg=""

while (( $# > 0 )); do
  case "$1" in
    --clean)     do_clean=1 ;;
    --discard)   do_discard=1 ;;
    --yes|-y)    assume_yes=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          usage >&2; die "unknown option: $1" ;;
    *)
      [[ -z "$capture_arg" ]] || { usage >&2; die "unexpected extra argument: $1"; }
      capture_arg="$1"
      ;;
  esac
  shift
done

# --clean says "delete the raw capture once I have the lists"; --discard says
# "delete it without producing lists at all". Together they are a contradiction,
# not a stronger form of either, so they are refused rather than ranked.
(( do_clean && do_discard )) && die "--clean and --discard are mutually exclusive: --clean keeps the extracted lists, --discard does not."

# ── Locate the capture directory ──────────────────────────────────────────────

# The places a capture can be, in order. `.ai-containers/` is in the list
# because "this script ships beside sandbox.sh, which IS the launch directory"
# holds for a consumer project and NOT for the base repo: there the engine sits
# at the repository root while the container is launched from the synced
# .ai-containers/ working copy, so the capture lands one level down from both
# $PWD and this script. Deduplicated, because in that same repo those two are
# the same directory and an error listing one path twice reads as a bug in the
# error message rather than as the answer to a question.
candidates=()
add_candidate() {
  local c
  for c in ${candidates[@]+"${candidates[@]}"}; do [[ "$c" == "$1" ]] && return 0; done
  candidates+=("$1")
}
add_candidate "$PWD/.agent-discovery"
add_candidate "$PWD/.ai-containers/.agent-discovery"
add_candidate "${_here}/.agent-discovery"
add_candidate "${_here}/.ai-containers/.agent-discovery"
# One level above the script, for the layout the mgd port uses: engine in
# base/, working copy at the repository root, so the launch directory is the
# script's PARENT's .ai-containers rather than its own. This repo already
# tolerates that split everywhere else it matters (tests resolve ENGINE_DIR as
# "$REPO_DIR" or "$REPO_DIR/base"; verify-on-host.sh does the same for tests/),
# and without it the fix above would land in mgd broken in precisely the way it
# was broken here.
add_candidate "$(cd "${_here}/.." 2>/dev/null && pwd)/.ai-containers/.agent-discovery"

capture_dir=""
if [[ -n "$capture_arg" ]]; then
  [[ -d "$capture_arg" ]] || die "no such directory: $capture_arg"
  # A LAUNCH directory is accepted as readily as a capture directory: passing
  # `.ai-containers/` is the natural thing to reach for, and answering "no pcap
  # in there" is a worse reply than looking one level down for the thing that
  # obviously is in there.
  if [[ -d "$capture_arg/.agent-discovery" ]]; then
    capture_dir="$(cd "$capture_arg/.agent-discovery" && pwd)"
  else
    capture_dir="$(cd "$capture_arg" && pwd)"
  fi
else
  for cand in "${candidates[@]}"; do
    if [[ -d "$cand" ]]; then capture_dir="$(cd "$cand" && pwd)"; break; fi
  done
  if [[ -z "$capture_dir" ]]; then
    printf 'ERROR: no .agent-discovery/ found. Looked in:\n' >&2
    printf '         %s\n' "${candidates[@]}" >&2
    printf '       Run ./sandbox.sh discovery first, or pass the launch\n' >&2
    printf '       directory (or the capture directory) explicitly.\n' >&2
    exit 1
  fi
fi

pcap="$capture_dir/agent-traffic.pcap"

# ── --discard: no extraction, no docker ───────────────────────────────────────

if (( do_discard )); then
  bytes="$(bytes_of "${RAW_FILES[@]}" "${DERIVED_FILES[@]}")"
  if (( bytes == 0 )); then
    printf 'Nothing to discard: %s holds none of the capture files.\n' "$capture_dir"
    exit 0
  fi
  printf 'Discard the capture in %s WITHOUT extracting it?\n' "$capture_dir"
  printf 'This removes the pcap and any extracted hostname lists (%s).\n' "$(human_size "$bytes")"
  if (( ! assume_yes )); then
    # `read` fails at EOF, and under `set -e` that kills the script before the
    # abort message ever prints — piped or Ctrl-D input would look like a crash
    # instead of the no-op it must be.
    read -r -p 'Type yes to confirm: ' answer || answer=""
    case "$answer" in
      yes|YES|y|Y) ;;
      *) printf 'Aborted; nothing removed.\n'; exit 0 ;;
    esac
  fi
  remove_files "${RAW_FILES[@]}" "${DERIVED_FILES[@]}"
  exit 0
fi

# ── Extract ───────────────────────────────────────────────────────────────────

[[ -f "$pcap" ]] || die "no capture file at $pcap
       Discovery mode writes it while the container runs; it appears once
       tcpdump has started. Run ./sandbox.sh discovery first."

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."

image="${IMAGE_NAME:-ai-sandbox}"
docker image inspect "$image" >/dev/null 2>&1 \
  || die "image not found locally: $image
       Build it with ./build.sh, or set IMAGE_NAME to the image you ran."

printf 'image:   %s\n' "$image"
printf 'capture: %s\n\n' "$capture_dir"

# The capture directory is mounted AT the in-container capture path, rather than
# mounting the whole launch directory at /workspace as the hand-typed command
# does. Same result for the extract, and the container sees only the one
# directory it reads.
if ! docker run --rm --entrypoint capture-agent-destinations.sh \
     -v "$capture_dir:/workspace/.agent-discovery" \
     "$image" extract /workspace/.agent-discovery; then
  die "the extract failed inside $image. The pcap is untouched at $pcap."
fi

dns_out="$capture_dir/agent-dns.txt"
sni_out="$capture_dir/agent-sni.txt"

count_lines() {  # $1 = path
  local n=0
  [[ -f "$1" ]] && { n="$(wc -l < "$1")"; n="${n//[^0-9]/}"; }
  printf '%s' "${n:-0}"
}

printf '\n%s DNS queries, %s TLS SNI hostnames.\n' "$(count_lines "$dns_out")" "$(count_lines "$sni_out")"

# ── What this image would not already allow ───────────────────────────────────

# Both allowlists come out of the image that just ran the extract, so the
# comparison is against what restricted mode would actually enforce — not
# against a re-derivation of it here.
read_from_image() {  # $1 = in-image path
  docker run --rm --entrypoint /bin/cat "$image" "$1" 2>/dev/null || true
}

# Strip comments, blanks and surrounding whitespace — the same normalisation
# strip_allowlist() applies in capture-blocked-traffic.sh.
strip_list() {  # stdin -> stdout
  awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ {
         gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print
       }'
}

# Captured into a variable FIRST, deliberately. A command substitution inside a
# here-string WORD has its exit status discarded, so nesting these directly into
# `strip_list <<<"$(read_from_image …)"` would make read_from_image's `|| true`
# inert — the two programs, with and without it, would be indistinguishable. An
# assignment propagates the status, which is what makes the fallback mean
# something under `set -e` when the image cannot be read.
raw_exact="$(read_from_image /tmp/allowlist-domains.txt)"
raw_wild="$(read_from_image /tmp/allowlist-proxy-domains.txt)"
exact_blob="$(strip_list <<<"$raw_exact")"
wild_blob="$(strip_list <<<"$raw_wild")"

if [[ -z "$exact_blob" && -z "$wild_blob" ]]; then
  printf '\nCould not read the allowlists out of %s — skipping the coverage report.\n' "$image"
  printf 'The hostname lists are in %s\n' "$capture_dir"
else
  mapfile -t wild_list < <(printf '%s\n' "$wild_blob")

  covered() {  # $1 = hostname
    local host="$1" p
    if grep -qxF -- "$host" <<<"$exact_blob"; then return 0; fi
    for p in "${wild_list[@]}"; do
      [[ -n "$p" ]] || continue
      # "*.example.com" → ".example.com", matched as a suffix, exactly as
      # matches_wildcard_domain() does in capture-blocked-traffic.sh.
      [[ "$host" == *"${p#\*}" ]] && return 0
    done
    return 1
  }

  # tshark emits repeated fields comma-separated, so one line can carry several
  # names. Lower-case them and drop the FQDN's trailing dot before comparing.
  #
  # Lower-casing is a DELIBERATE deviation from the daemon, which compares what
  # it sniffed verbatim. It is right for this report's purpose — "GitHub.com" and
  # "github.com" are one line to add to custom.txt, not two — and the allowlist
  # side is left verbatim, so the deviation can only ever make this report say
  # "not covered" about something spelled unusually, never the reverse.
  mapfile -t observed < <(
    awk -F, '{ for (i = 1; i <= NF; i++) {
                 h = $i; gsub(/[[:space:]]/, "", h); sub(/\.$/, "", h)
                 if (h != "") print tolower(h)
               } }' "$dns_out" "$sni_out" 2>/dev/null | sort -u
  )

  uncovered=()
  for host in "${observed[@]}"; do
    covered "$host" || uncovered+=("$host")
  done

  if (( ${#observed[@]} == 0 )); then
    printf '\nNo hostnames in the capture — the agent resolved nothing and opened no\n'
    printf 'TLS connection while it ran. Nothing to add to an allowlist.\n'
  elif (( ${#uncovered[@]} == 0 )); then
    printf '\nEvery hostname observed (%s) is already covered by this image.\n' "${#observed[@]}"
  else
    printf '\nNot covered by this image (%s of %s observed):\n' "${#uncovered[@]}" "${#observed[@]}"
    printf '  %s\n' "${uncovered[@]}"
    printf '\nAdd the ones you want to allowlist-domains.d/custom.txt (or a wildcard\n'
    printf 'pattern to allowlist-proxy-domains.d/custom.txt), then ./build.sh and\n'
    printf 'switch to restricted mode.\n'
  fi
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

raw_bytes="$(bytes_of "${RAW_FILES[@]}")"
if (( do_clean )); then
  printf '\nRemoving the raw capture (--clean); the hostname lists stay.\n'
  remove_files "${RAW_FILES[@]}"
elif (( raw_bytes > 0 )); then
  printf '\nRaw capture still on disk: %s. Re-run with --clean to remove it,\n' "$(human_size "$raw_bytes")"
  printf 'or --discard to drop a capture without extracting it.\n'
fi
