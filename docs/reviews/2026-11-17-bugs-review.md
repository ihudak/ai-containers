# Bugs review — 2026-11-17

- **Review date:** 2026-11-17
- **Last reviewed commit:** `104fcc8` (`104fcc8f5db456c1aef4bb11737da4f30c056c8c`, main, 2026-11-16 — "docs(reviews): GIT-102 is closed as a stated limit, the user's choice")
- **Window reviewed:** everything changed since the last whole review ([2026-10-26](2026-10-26-bugs-review.md), which stopped at `bec1c57`), so `bec1c57..104fcc8`: 441 non-merge commits, 245 files, 51,320 lines added. Pre-window code was in scope where a reviewer hit a real defect; such findings say "Introduced: before the window". 24 of the 39 do, at least in part: the window's own reviews were narrow, one fix at a time, so older code next to it was rarely looked at again.
- **Rule:** only defects present at `104fcc8`. Nothing already in the 2026-10-26 logs is filed again, nor any stated limit or closed decision there (GIT-12, GIT-13, LNCH-7, GIT-87, GIT-92, GIT-102, BLD-8's trade, PLAT-4, AGENTS.md's "Not covered" lists). A finding that an older fix left incomplete names that fix.
- **Method:** seven area reviewers on Fable (Claude Fable 5.2), run in parallel. Each had the same brief and its own scope. All of them worked in a detached worktree at `104fcc8` with read-only access to the code, and reproduced hermetically, as the suite does: fake `docker`, private `HOME` and `TMPDIR`, no real container, image or volume. The coordinator (Opus 5.5) checked the findings before logging them:
  - It re-ran GIT-105 through `tests/lib-git-internals-ro.sh`. Launch 1 makes 5 binds and launch 2 makes 0, with no warning. The host's `git status` then ran the agent's `core.fsmonitor`.
  - It checked RT-13, RT-14, LNCH-29, PRJ-13 and REPO-22 against the code at `104fcc8`.
- **Who picks up what:** assigned 2026-11-17 in the "Who picks up what" table of [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md): RT to the Linux agent, REPO and ENV to the WSL native agent, LNCH-32 to the Mac agent, GIT to a Fable 5.2 session the user starts, and the rest to the review agent.
- **Companion:** [2026-11-17-feature-gaps-review.md](2026-11-17-feature-gaps-review.md) (GAP-15 to GAP-29).
- **Numbering:** IDs continue the 2026-10-26 series. GIT-105 to GIT-107 and LNCH-29 to LNCH-34 are this review's; the WSL native agent's brief in the feature-gaps review now reserves GIT-108 and LNCH-35 onward for what it finds.
- **Confidence:** CONFIRMED = reproduced, or unambiguous from the code. PLAUSIBLE = strong reasoning, not reproduced (needs macOS, Colima, Docker Desktop, a real `tshark`, …); each such entry says what would confirm it.
- **Citations** are by snippet, per AGENTS.md "Citing code". Repro paths were scratch directories that no longer exist; each entry describes its repro in full.

## Summary

39 bugs: 3 HIGH, 8 MEDIUM, 28 LOW. No SVC or BLD findings. TST-41, found while fixing them, is in section 9.

### HIGH — fix first

| ID | Confidence | Summary |
|---|---|---|
| GIT-105 | CONFIRMED | a repository protected through an index gitlink is unprotected, in silence, once a session drops the gitlink from the index |
| RT-13 | CONFIRMED | the blocked-traffic daemon, as root, appends to files in a directory the agent owns, so a symlink there writes the firewall's allowlist |
| RT-14 | CONFIRMED | self-healing trusts any DNS answer seen on the wire, so the agent can have any address allowed; docs/security.md says it cannot |

### MEDIUM

| ID | Confidence | Summary |
|---|---|---|
| LNCH-29 | CONFIRMED | the group's `hosts.yml` is read through a link the agent can plant, and the host's real `gh` token is passed into the container |
| LNCH-31 | CONFIRMED | a working copy whose first seed failed is mounted empty (or half-copied) on every later launch, silently |
| PRJ-12 | CONFIRMED | an interrupt while `mv` removes the old `.ai-containers` (move across filesystems) leaves two setups, and the re-run it tells you to make is refused |
| PRJ-13 | CONFIRMED | `rm`/`mv` take an existing, unregistered directory named on the command line for the basename of another registered project |
| REPO-19 | CONFIRMED | `inspect` runs git on a volume that still holds nested `.git`s, so the agent can hang every `repo.sh reset` (and `project.sh rm`'s check) for ever |
| REPO-20 | CONFIRMED | `sync` and `reset` delete `.git/modules/<name>` with its unpushed commits, and neither says so |
| REPO-21 | CONFIRMED | `reset` drops the commits of a detached HEAD and its summary counts nothing at risk |
| REPO-22 | CONFIRMED | a reset whose remote cannot be cloned says it continues with a "LOCAL reset", removes every working copy, changes nothing else and ends "OK: reset complete" |

### LOW

| ID | Confidence | Summary |
|---|---|---|
| GIT-106 | CONFIRMED | a program a config key runs is passed in silence when the shell reaches it through a builtin, a keyword, an assignment or an interpreter's load option |
| GIT-107 | CONFIRMED | planted `.git` files are all followed before `SANDBOX_GIT_MAX` refuses: 3000 take 43 s |
| LNCH-30 | CONFIRMED | on drvfs/SMB (or a case-aliasing directory) a pointer or `EXTRA_MOUNTS` path inside a writable mount now refuses the launch, as "mounted read-only" |
| LNCH-32 | CONFIRMED | on Colima, a launch whose verify paths pass xargs' command-line limit is refused: each xargs batch prints the header again and the reader loses its place |
| LNCH-33 | CONFIRMED | the entrypoint prints a mismatched mount's destination to the terminal as it is |
| LNCH-34 | CONFIRMED | a repo named `ro`, `rw` or `rwcopy` attached with the mode of the same name is mounted read-only |
| PRJ-14 | CONFIRMED | `mv` cannot carry two working copies of one repo launched through two spellings of the project path |
| PRJ-15 | CONFIRMED | `ai-containers-report.sh` prints `sandbox.env` values to the terminal and into `--tsv` unrendered |
| PRJ-16 | CONFIRMED | `group.sh gc` removes the Ruby volume of a group that exists only in another home on a shared daemon |
| PRJ-17 | PLAUSIBLE | "refuses while a container of the project runs" rests on `docker inspect`'s mount sources being host paths |
| PRJ-18 | CONFIRMED | `~/.ai-containers/restored`, the launcher's own directory, is a group to `group.sh` and `project-init.sh` |
| REPO-23 | CONFIRMED | `reset` writes the checkout through the agent's untracked `.gitattributes`, so the "clean checkout" differs from the remote |
| ENV-10 | CONFIRMED | `version_engine` reads `engine-version` through a link, and a sync copies the first line of the file it names into every project |
| ENV-11 | CONFIRMED | the engine version is printed, and recorded into projects, with the control characters the checkout's writer put in it |
| REPO-24 | CONFIRMED | `sync --all` stops at the first repo it refuses and never reaches the rest |
| REPO-25 | CONFIRMED | `repo.sh rm` reports "OK: removed" and drops the registry line when docker refused to remove the volume |
| REPO-26 | CONFIRMED | `repo.sh add` writes a host path holding `\|` into the registry, and it reads back as another directory |
| REPO-27 | CONFIRMED | a first clone that fails leaves an empty, labelled base volume that neither `sync` nor `reset` can mend |
| RT-15 | CONFIRMED | a `tcpdump.pid` the agent leaves behind makes the next discovery launch record nothing, under a banner saying everything is captured |
| RT-16 | CONFIRMED | extract-discovery.sh prints a file the agent chose to the host terminal, unrendered |
| RT-17 | CONFIRMED | the tool and Ruby reconciles wait for the group lock with no bound, so one container can hang every later start of the group |
| TST-38 | CONFIRMED | `verify-on-host.sh` prints `RESULT: PASSED` and exits 0 for a `PHASES` value that selects no phase |
| TST-39 | CONFIRMED | `update-nvm-version.yml` pastes the upstream release tag into a shell script and a `sed` program, unchecked, in a job with `contents: write` |
| TST-40 | CONFIRMED | `tests/run-all.sh` runs no test when the checkout's path holds whitespace |
| DOC-14 | CONFIRMED | troubleshooting.md still says Codex cannot update itself and is reinstalled at every start |
| DOC-15 | CONFIRMED | the Unreleased CHANGELOG says `repo.sh gc` does not read the owner label, and 160 lines later that it does |
| DOC-16 | CONFIRMED | the group-mount table in docs/repos-and-mounts.md leaves out five mounts the launcher makes |
| DOC-17 | CONFIRMED | two counts in AGENTS.md no longer match the code |
| TST-41 | CONFIRMED | `tests/test-report.sh` fails wherever `TMPDIR` lies under `HOME` (found while fixing PRJ-15) |

---

## 1. Host-side launcher: git internals

### GIT-105: a repository protected through an index gitlink is unprotected, in silence, once a session drops the gitlink from the index
- **Status: FIXED** (2026-11-17, Fable 5.2 session). The record of what launches reported (`~/.ai-containers/git-reported.conf`) is now also read by path (`sandbox.sh`: `_git_rec_add()`), and `git_dirs_in()` takes from it every git directory, and every `.git` file a launch bound (new `file:<path>` lines), that lies in the mount it scans and that the scan did not find, while it is the directory or file recorded (inode and birth time; not the device, whose number a reboot changes on some hosts) and no link lies on the way; one that can no longer be listed is bound whole, and so is a directory on the way that the session made unsearchable (`_gdi_blocked()`). The scan after the session reads the same record, so such a directory is not taken for one the session made. A record line that cannot be written is said in a `WARNING:`. The review of the fix found that a checkout bound whole, because the agent had made it unsearchable before any launch saw its `.git`, was in no record, and was bound by no launch once dropped from the index: `_gdi_blocked()` now records the checkout it could not reach (`want:<path>`), which is bound whole while it stays unsearchable and has its `.git` taken once it can be reached (G324). The record is read after everything else is followed, and past five times `SANDBOX_GIT_MAX` recorded paths that are still there but that nothing leads to, the launch is refused, naming the record and five of them (G331). The re-review found that `want:` lines cost the agent nothing to make (an index entry each, no directory needed) and each cost every later launch a walk: a recorded path behind a directory already bound whole now costs nothing more, and past `SANDBOX_GIT_MAX` checkouts behind unsearchable directories a launch is refused, naming five (G324). It also found lines with no check, each now covered: what a `.git` taken from the record leads to (a nested submodule), a `want:` checkout whose `.git` is a file or a link, or with a link on the way, that the scan after the session records nothing, and that what an index still names is taken once. A link's identity, which carries its target's text, is no line of the record. A path recorded with a newline (`$'…'`, GIT-90) is read back with no eval (`_git_unq()`). Stated limits, in AGENTS.md: the record is this home's on this machine, and a directory made again at the path is another one. `tests/test-git-internals-ro-index.sh` G320 to G325 and G331: the reviewer's repro (4 binds at launch 1, 4 at launch 2, was 0), a `.git` file, a path with a newline, a record that cannot be written, a directory made unlistable or hidden behind an unsearchable one in the session, a record whose device number is another, and a directory moved with a link left behind; each seen failing against the unfixed launcher or a mutant of the line it covers. Was: OPEN (filed 2026-11-17).
- **Severity:** HIGH
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `git_dirs_in()`, `[[ "${rec%% *}" == 160000 ]] || continue` (the only way a git directory under a pruned `vendor`, `node_modules`, `.venv` or `target`, or deeper than the scan, is found when its `.git` is an embedded directory); `sandbox.sh`: `_git_after_session()`; `sandbox.sh`: `_git_reported()`
- **Introduced:** before the window (`91fac80`, gitlinks followed from the index). The index is the one input to "what is protected" that the launch itself leaves writable.
- **What happens:** a superproject records `vendor/lib` as a gitlink whose `.git` is a directory in the checkout. Launch 1 finds it through the index and binds its `config`, `hooks/`, `commondir`, `config.worktree`. In that session the agent removes the gitlink from the index (`git update-index --force-remove vendor/lib`, `git rm --cached`, or simply `git checkout` of a branch that does not record it: the index is writable by design). Launch 2 no longer finds `vendor/lib/.git`: no bind, no pin, no `WARNING:`. In session 2 the agent writes `vendor/lib/.git/config` (or `hooks/`). The check after session 2 says nothing: the directory is under a pruned name and no index records it. On the host the user sees `D  vendor/lib`, puts it back (`git reset`), and the next `git status` runs the agent's `core.fsmonitor` in the submodule. Launch 3 finds the repository again and freezes the agent's config; it does not name `core.fsmonitor`, because `git-reported.conf` still holds the repository from launch 1 (same device, inode, birth time and path). Only the per-launch program NOTE of GIT-42 remains, and GIT-106 below switches that off. The same holds for a submodule's own submodules (its index is writable too) and for a gitlinked repository deeper than the scan's depth.
  AGENTS.md promises the opposite for every other route: "so an agent that moves `HEAD`, `objects/` or `refs/` aside cannot hide a directory protected before". The known neighbours all warn: an unreadable index gets a `WARNING:` at every launch. This one is silent.
- **Repro:** (script kept nowhere; rebuild from this)
  ```
  source tests/lib-git-internals-ro.sh      # TMPDIR set to a scratch directory
  mkdir -p "$PROJ/vendor/lib"; "${G[@]}" -C "$PROJ/vendor/lib" init -q
  : > "$PROJ/vendor/lib/f"; "${G[@]}" -C "$PROJ/vendor/lib" add f; "${G[@]}" -C "$PROJ/vendor/lib" commit -qm x
  "${G[@]}" -C "$PROJ" add vendor/lib; "${G[@]}" -C "$PROJ" commit -qm sub
  export P="$PROJ" T="$TMP"
  FAKE_SESSION='git -C "$P" update-index --force-remove vendor/lib' launch ..
  git_mounts | grep -c vendor/lib          # 5: protected by launch 1
  FAKE_SESSION='printf "echo RAN > %s/ran\n" "$T" > "$P/evil.sh"; chmod +x "$P/evil.sh"; printf "[core]\n\tfsmonitor = %s/evil.sh\n" "$P" >> "$P/vendor/lib/.git/config"' launch ..
  git_mounts | grep -c vendor/lib          # 0; $ERR holds no WARNING, at launch or after the session
  ( cd "$PROJ"; "${G[@]}" reset -q; "${G[@]}" status --short >/dev/null ); ls "$TMP/ran"   # exists
  launch ..; grep -c 'core.fsmonitor.*sets\|sets$' "$ERR"   # launch 3: no "config already sets" NOTE
  ```
- **Expected:** a git directory a launch protected stays protected, or the launch that no longer finds it says so, whatever the session did to an index.
- **Suggested fix:** the launcher already keeps a record of every repository it protected (`git-reported.conf`: identity and path). At each launch, a recorded path inside a writable mount that the scan did not return and that still is the same directory (identity) is queued as a git directory all the same (it also still holds the `./` `commondir` the launch made). And `_git_after_session()` should name a directory the launch protected that its own scan no longer reaches.

### GIT-106: a program a config key runs is passed in silence when the shell reaches it through a builtin, a keyword, an assignment or an interpreter's load option
- **Status: FIXED** (2026-11-17, Fable 5.2 session). `sandbox.sh`: `_git_prog()` names as not followed what the shell itself runs or reads as code (`.`, `source`, `eval`, `time`, `trap`, `if`, …), an assignment before the program (every one: a list of dangerous names would never be whole; the program after it is still judged), an interpreter's option that is not known to load nothing, and a module loaded by name; what an option loads by path is judged (`node -r ./x.js`, `perl -I ./lib`, `ruby -r ./x`, `bash --rcfile`). Each interpreter's options are its own (`_git_prog_iopt()`). Found on the way in the same function, and fixed the same way: a wrapper named by a path was passed over unjudged (`./env true`); one list of options served every wrapper, so an option it lacked had its argument taken for the program, found on PATH, and the program went unread (`ionice -c 3 ./x`, `stdbuf -o L ./x`, `xargs -L 1 ./x`), now each wrapper's own (`_git_prog_wopt()`), an unknown one not followed; `env -C dir ./x` and `sudo -D dir ./x` were judged from the checkout, not from `dir`; an interpreter given no script said nothing, though `diff.x.textconv = sh` runs the file git hands it; `perl5.36` and `python3.12` were programs found on PATH; `git diff <(./x)` was not another command; `PATH+=:./bin tool` was no assignment. The review of the fix found three more, fixed: `chrt -b " 0" ./x`, where chrt takes more for a priority than digits (a word that is neither a plain number nor a path is now not followed); `ruby -F ./x.rb /safe.rb`, where a bare `-F` takes no argument and `./x.rb` is the script; and `"~/bin/tool"` in quotes, which the shell runs from a directory named `~` under the checkout while it was judged in your home. The re-review found the same of a `~` attached to an option (`perl -I~/lib`) and in a module's name (`python3 -m ~.x`): a `~` is now your home only at the start of a word outside quotes, and judged both ways where the program may expand it itself (ruby, a key run with no shell). And three of git's own keys were missing from `_git_prog_keys`: `remote.<name>.vcs`, `gc.recentObjectsHook`, `uploadpack.packObjectsHook`. Kept as it is, on record: every assignment is named, so `LESS=FRX less` gets a `NOTE:` at each launch; the names that matter are no closed list (`LESS` itself can name a lesskey file). Stated in AGENTS.md: a program found on PATH is not judged and its arguments are not read (`ssh -F ./cfg`, `awk -f ./x`, `make`). `tests/test-git-internals-ro-config.sh` G327 (unit and a launch), with the older G134 expectations that change (`perl -I lib` now judges `lib`; `env -C`, `sudo -D` not followed; `sudo -n ./x` followed; an assignment named); all seen failing against the unfixed function. Was: OPEN (filed 2026-11-17).
- **Severity:** LOW (MEDIUM together with GIT-105: it removes the only notice left there)
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `_git_prog()`, `if [[ -z "$_gp_s" && "$_gp_w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi`, and its last branch (`_gp_t=1` for a first word with no `/`)
- **Introduced:** `809ee06` (GIT-42)
- **What happens:** AGENTS.md says a program a key has git run "is judged … and gets a `NOTE:` where the agent can change it", and one that cannot be followed "is named as not judged". These values are neither judged nor named, and the host's `git status` runs the agent-writable file in each case (run):
  `. ./evil.sh`, `source ./evil.sh`, `eval ./evil.sh`, `time ./evil.sh` (the first word has no `/`, so it is "found on PATH" and its arguments are not looked at); `PATH=./bin tool` and `env PATH=./bin tool` (the assignment is stepped over, then `tool` is "found on PATH", which the assignment just changed); `BASH_ENV=./evil.sh bash /dev/null`; `node -r ./evil.js /usr/lib/x.js`, `node --require=./evil.js …`, `perl -I ./lib -MEvil /usr/bin/x.pl`, `ruby -r ./evil …`, `php -d auto_prepend_file=./evil.php …` (the option's argument is skipped as an argument, only the script is judged). `if ./x` likewise. The config is one the agent wrote before the first protection (a repository it made in a session), so the agent picks the form.
- **Repro:** after one `launch ..`, append `[core]` / `fsmonitor = . ./evil.sh` to `$PROJ/.git/config`, make `$PROJ/evil.sh` (`echo RAN > $TMP/ran`), `launch ..`: `$ERR` holds no NOTE naming `core.fsmonitor` or the script, and `( cd "$PROJ" && git status )` creates `$TMP/ran`. With `fsmonitor = ./evil.sh` the NOTE is printed. Same result for `eval ./evil.sh`, `time ./evil.sh`, `PATH=./bin tool`, `BASH_ENV=./evil.sh bash /dev/null`. Unit level: `_git_prog core.fsmonitor '. ./evil.sh' o` fails with `o` empty; `_git_prog core.fsmonitor 'node -r ./evil.js /usr/lib/tool.js' o` gives only `p:/usr/lib/tool.js`.
- **Expected:** each is judged, or named as not judged.
- **Suggested fix:** fail closed, as the function already does elsewhere: a first word that is a shell builtin or keyword that runs or reads its argument (`.`, `source`, `eval`, `time`, `if`, `while`, `until`, `!`, `{`) is `u:`; an assignment to `PATH`, `BASH_ENV`, `ENV`, `LD_*`, `DYLD_*`, `PYTHONPATH`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `NODE_PATH`, `PERL5LIB`, `PERL5OPT`, `RUBYLIB`, `RUBYOPT`, `GIT_*` before the program is `u:`; an interpreter option that loads code (`-r`, `--require`, `--import`, `-I`, `-M`, `-m`, `-d`, `-l`, `--rcfile`, `--init-file`) gives its argument as a `p:` entry instead of skipping it.

### GIT-107: planted `.git` files are all followed before `SANDBOX_GIT_MAX` refuses: 3000 take 43 s
- **Status: FIXED** (2026-11-17, Fable 5.2 session). `sandbox.sh`: `git_dirs_in()` stops following once git directories and `.git` files together pass `SANDBOX_GIT_MAX`, and names five of either kind; the refusal says "git directories and .git files". Only the files the protection itself counts: one under a read-only overlay (in a launcher directory) counts toward no limit there, and `tests/test-git-internals-ro-config.sh` G126 pins that such a tree launches. A read-only mount nested in a writable one is judged where it lands in that mount's view. Those are still read, each at every launch, so the cost the review measured remains for files planted inside a planted launcher; past the limit a `NOTE:` says how many lie there and names five. A stated limit, like GIT-102's: slower, with nothing left unprotected. The reviewer's 3000 files: refused in 2 s here, was 43 s. `tests/test-git-internals-ro-scan.sh` G326 asserts it by the reads made (a `head` shim: none of 40 planted files is read with a limit of 5), not by a clock; seen failing against the unfixed scan (40 of 40 read). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `git_dirs_in()`, `if (( ${#_gdi_dirs[@]} > ${gitmax:-200} )); then gover=1;` (counts git directories only; `_gdi_files` is never counted)
- **Introduced:** `86427b0` (GIT-9's fix; GIT-84 repeated it for directories only)
- **What happens:** every `.git` file costs a bounded read and a `cd -P` subshell (about 14 ms here), and each is one more place toward `SANDBOX_GIT_MAX` in the protection loop, which refuses past 200. The scan's own cut looks only at `_gdi_dirs`, so 3000 `.git` files naming directories that do not exist are all read and resolved, and the launch is refused after 43 s; the cost is linear (20,000: about five minutes). AGENTS.md: "A scan that passes `SANDBOX_GIT_MAX` stops following, and the launch is refused"; GIT-84 measured 3,000 planted `.git` directories at 1 s.
- **Repro:** after one `launch ..`: `for ((i=0;i<3000;i++)); do d="$PROJ/p/$((i/100))/d$i"; mkdir -p "$d"; printf 'gitdir: /nonexistent/x%s\n' "$i" > "$d/.git"; done; time launch ..` gives rc 1, `ERROR: the writable mounts hold more than 200 git directories to protect`, 43 s.
- **Expected:** refused in about the time 200 take.
- **Suggested fix:** cut the queue when `${#_gdi_dirs[@]} + ${#_gdi_files[@]}` passes `gitmax`, and name the first five of either kind in `_gdi_over`.


---

## 2. Host-side launcher: mounts, binds and the verify manifest

### LNCH-29: the group's `hosts.yml` is read through a link the agent can plant, and the host's real `gh` token is passed into the container
- **Status: FIXED** (2026-11-17, review agent). `sandbox.sh`: `_group_gh_token()` reads `hosts.yml` only when it is a regular file and not a link, and only through an open that is the very file judged so (by its inode, which the launcher records at the check), in a child under a 5 s bound where a `timeout(1)` is installed (`_gh_read_prog`); it reads the first 64 KiB. A link, a FIFO, a file that cannot be read, one swapped in between the check and the open, or a read that runs out of time, is a `WARNING:`, and the launch goes on with no token. The reviews of the fix found the open unbounded (a sibling container swapping a FIFO in hung the launch) and the check after the open untested; both are fixed. Where no `timeout(1)` is installed (a Mac without Homebrew's coreutils) the read is not bounded, as no bounded read of this launcher is. `tests/test-tool-config-mounts.sh`: a link, a FIFO and a mode-000 file; a FIFO and a link to the host's file each swapped in between the check and the open (through a `timeout` on PATH, which the bounded read runs); and a sibling swapping the file 300 times. Each was seen failing first, or against its mutant.
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `run_container()`, `copilot_token="$(awk '/oauth_token:/{print $2; exit}' "$gh_hosts")"`
- **Introduced:** before the window (`8bcaa0e` carries the line)
- **What happens:** with `copilot=ON` and no `COPILOT_GITHUB_TOKEN` on the host (the default,
  "auto from `gh`"), every launch reads `~/.ai-containers/<group>/.config/gh/hosts.yml` on the
  host, guarded only by `[[ -f "$gh_hosts" ]]`, which follows links. That directory is the
  agent's `~/.config/gh`, mounted writable. In one session the agent replaces `hosts.yml`
  with a link to an absolute host path (it knows the host user and home from `SANDBOX_USER`
  and `HOST_WORKSPACE_DIR`): your real `~/.config/gh/hosts.yml`, or another group's. In the
  container the link dangles or loops; on the host, the next launch follows it, takes the
  second field of the first `oauth_token:` line, and passes it as
  `-e COPILOT_GITHUB_TOKEN=…`. The agent gets a credential the group was made to keep from
  it (the host's `gh` token, usually wider than a "Copilot Requests" PAT), with no warning:
  `_warn_group_link_out()` looks only at the mounted directories, not at this file.
  Second symptom, same line: the agent runs `chmod 000` on its `hosts.yml` (it is the
  owner), and every later launch of every project of the group dies under `set -e` with
  `awk: fatal: cannot open file … Permission denied` (rc 2), before docker runs.
- **Repro:** in a hermetic launcher copy with `copilot=ON` in `sandbox.conf`, after one launch:
  ```
  printf 'github.com:\n    oauth_token: gho_REAL_HOST_TOKEN\n' > "$HOME/.config/gh/hosts.yml"
  ln -sfn "$HOME/.config/gh/hosts.yml" "$HOME/.ai-containers/default/.config/gh/hosts.yml"
  ( cd proj/.ai-containers && ./sandbox.sh restricted .. )
  ```
  The fake docker's recorded arguments hold `COPILOT_GITHUB_TOKEN=gho_REAL_HOST_TOKEN`; rc 0,
  no WARNING. With a regular `hosts.yml` at mode 000 instead: rc 2, no `docker run`, the
  awk error above.
- **Expected:** the launcher reads only a regular file that is the group's own (not a link,
  one link count), and a file it cannot read is a HINT, not the end of the launch.
- **Suggested fix:** refuse to read when `hosts.yml` (or `.config/gh` below the group root)
  is a link or not a regular file, with a `WARNING:`; read it bounded and make a failed
  read non-fatal (`|| copilot_token=""`). Add both cases to `tests/test-tool-config-mounts.sh`.

### LNCH-30: on drvfs/SMB (or a case-aliasing directory) a pointer or `EXTRA_MOUNTS` path inside a writable mount now refuses the launch, as "mounted read-only"
- **Status: FIXED** (2026-11-17, review agent). The GIT-41 refusal loop in `launcher_ro_overlay()` passes over the verify list's mounted host paths (`_host_verified`), so it judges overlays, pins and file binds only, as before LNCH-27. Confirmed first on a real drvfs drive (`/mnt/c`, Docker Desktop's WSL): `EXTRA_MOUNTS=<C:>/data DOCS_PATH=<C:>/data/docs` was refused at `HEAD` and launches with the fix. `tests/test-launcher-dir-ro.sh` T92 (with `_win_fs()` taking one directory for Windows's): a `:ro` and a writable pointer inside such a writable mount launch (seen failing first), and a launcher planted there is still refused.
- **Severity:** LOW
- **Confidence:** CONFIRMED (with `_win_fs()` overridden for one directory; not on a real drive)
- **Location:** `sandbox.sh`: `launcher_ro_overlay()`, the loop `for ((k = 0; k < ${#_vrfy[@]}; k += 2)); do` that prints `is mounted read-only, but %s is on a filesystem where`
- **Introduced:** `46dc786` (fix(sandbox): every mounted host path is verified … (LNCH-27))
- **What happens:** GIT-41's refusal walks every entry of the verify list, which until
  LNCH-27 held only overlays, pins and read-only file binds. LNCH-27 appends every mounted
  host path (`_vrfy+=("$fin" "${hdst[k]}")`). A host path that lies inside another writable
  mount on a Windows filesystem is therefore taken for a read-only bind that an 8.3 name
  gets round: a launch with `EXTRA_MOUNTS=/mnt/c/data` and `VAULT_PATH=/mnt/c/data/notes`
  (or `DOCS_PATH=/mnt/c/data/docs`), which needs no overlay at all and started before
  `46dc786`, is refused with "ERROR: /workspace/vault is mounted read-only, but /mnt/c/data
  is on a filesystem where Windows looks names up …". The vault is mounted writable; and
  for a `:ro` pointer the directory is writable through the outer mount on any filesystem,
  so the refusal protects nothing. The `_ci_alias_fs` branch (`ignores case and the kernel
  does not`) takes the same entries.
- **Repro:** hermetic launcher copy, `_win_fs() { [[ "$1" == "$FAKE_WIN" || "$1" == "$FAKE_WIN"/* ]]; }`
  inserted before the entry point, `FAKE_WIN=$T/win`, `mkdir -p $T/win/data/docs $T/win/data/notes`:
  `EXTRA_MOUNTS=$T/win/data` → rc 0; `EXTRA_MOUNTS=$T/win/data DOCS_PATH=$T/win/data/docs` → rc 1
  with the message above for `/workspace/docs`; with `VAULT_PATH=$T/win/data/notes` → rc 1 for
  `/workspace/vault`. The same launch with `git show 46dc786^:sandbox.sh` → rc 0.
- **Expected:** only overlays, pins and file binds are judged there (AGENTS.md: "a launch
  that needs any overlay, pin or file bind below a writable mount root is refused").
- **Suggested fix:** skip entries marked in `_host_verified` in that loop (or run it over the
  entries added by the overlay and git passes only). Add a T-case beside T62/T63 with
  `_win_fs` overridden.

### LNCH-31: a working copy whose first seed failed is mounted empty (or half-copied) on every later launch, silently
- **Status: FIXED** (2026-11-17, review agent). `sandbox.sh`: `seed_workcopy_volume()` records a seeding in `~/.ai-containers/.seeding/<daemon id>/<volume>`, put in place whole and exclusively by a hard link before the volume is made, holding the launcher's pid and start time (`_seed_proc()`: `/proc` on Linux, `ps` in UTC and the C locale elsewhere), and removes the record only once the copy has finished. A launch reads the record after it has asked docker about the volume (`_seed_rec_state()`). While a record is there no launch mounts the volume: one whose launcher runs refuses a second launch; one whose launcher is gone (killed, the VM stopped), or that holds nothing, has its volume, never mounted, removed and seeded again; one that vanishes as it is read means that seeding finished. A copy that fails, or a launcher stopped during it, has the EXIT trap's `_seed_wc_drop()` remove the copy's container, stop its client, and then remove the volume. An `inspect` that fails for any other reason than "no such volume" refuses the launch (`_seed_vol_state()`), and an image not built is named before any volume is made. Two reviews of the fix found the kill and VM-stop case, a concurrent second launch (the record read before the volume, and one being written taken for a dead one), records shared across daemons, a 10 s wait on a copy that ignores TERM, and the trap's own `set -e` exposure; all are fixed. Another home on the same daemon keeps records of its own: the collision of two homes' identical launch paths is the stated limit of docs/troubleshooting.md, "Several homes on one docker". `tests/test-docs-path.sh`: thirteen cases, a failed copy, a launcher killed during it, a copy that goes on after it, an image not built, a finished copy leaving no record, a dead, a live, an empty and another daemon's record, an `inspect` error alone and with a dead record, a seeding that begins as the launch looks, and one that finishes in between; `tests/test-launcher-dir-ro.sh` T73. Each was seen failing first. A volume an earlier engine left half-seeded has no record and is still mounted; the CHANGELOG says how to remove it.
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `seed_workcopy_volume()`, `if docker volume inspect "$wc_vol" >/dev/null 2>&1; then`
- **Introduced:** before the window (`8bcaa0e` carries it)
- **What happens:** `REPOS="app:rwcopy"`. The function creates the volume, then copies with
  `docker run --rm --pull=never --entrypoint bash … "$image_name" -c 'cp -a /src/. /dst/'`.
  When that run fails (the image is not built yet, which `--pull=never` now turns into an
  error; an interrupt during a large copy; a full disk) the launch ends under `set -e`,
  and the volume stays, labelled as a working copy. The next launch finds it by
  `docker volume inspect`, returns 0 without copying, and mounts it writable at
  `/workspace/app`: an empty directory (root-owned, since `cp -a` never ran), or a part of
  the repository, printed as `REPO: /workspace/app  (rwcopy, working copy …)`.
- **Repro:** hermetic launcher copy, registry line `app|path|<dir>|…|volume`, a fake docker
  that keeps volumes as files and fails the `--entrypoint bash` run once:
  launch 1 → rc 125, "No such image", the `--wc-` volume exists; launch 2 → rc 0,
  `REPO: /workspace/app  (rwcopy, working copy ai-containers-repo-app--wc-…)`, and no
  seed run among the docker calls.
- **Expected:** a working copy is used only once its seed finished; a failed seed leaves
  nothing that the next launch takes for one.
- **Suggested fix:** remove the volume when the copy fails (`docker run … || { docker volume rm "$wc_vol"; exit 1; }`),
  and/or have the copy write a marker file last and re-seed a volume that lacks it. Check the
  image exists before creating the volume.

### LNCH-32: on Colima, a launch whose verify paths pass xargs' command-line limit is refused: each xargs batch prints the header again and the reader loses its place
- **Status: FIXED** (2026-11-17, Mac agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED on Colima (2026-11-17, the Mac agent: macOS 26.7.3, Colima 0.10.3). Before this, PLAUSIBLE: the mechanism was confirmed only locally, with a fake `colima` running the VM's program under GNU xargs 4.10. On the real VM, `_vm_dev_ino_load()` on directories with ~275-byte paths recorded 100 of 100 and 400 of 400 (109 KB), but only 477 of 1200 (329 KB).
- **Location:** `sandbox.sh`: `_vm_dev_ino_load()`, whose `colima ssh` ran the VM's program, share list and all, under xargs directly
- **Introduced:** `e51e472` (fix(sandbox): on Colima, read the verify manifest through held directories in the VM (PLAT-11))
- **What happens:** `_vm_hold_prog` prints the VM's share list and a NUL first, then three
  NUL-ended fields per path. The reader takes one header, then triples. GNU xargs passes at
  most about 128 KiB of arguments to one command and starts another `sh` for the rest, which
  prints the header again: one extra field, so every triple of the second and third batch
  is read shifted and dropped (the fourth lines up again). The dropped sources are recorded
  `0:0` and the entrypoint refuses the launch as swapped mounts. Before `e51e472` the
  command was `xargs -0 stat`, where a split changed nothing.
- **Repro:** `_colima_profile`, `_vm_dev_ino_load`, `_timeout_prefix` and `_vm_hold_prog`
  loaded from `sandbox.sh`; `colima` on `PATH` as a script that runs what follows `--`;
  `DOCKER_HOST=unix://$HOME/.colima/default/docker.sock`; N directories with ~280-byte paths:
  ```
  paths=400  bytes=112290 recorded=400
  paths=1200 bytes=337290 recorded=465
  paths=3000 bytes=844890 recorded=1147
  ```
  A real launch needs about 128 KiB of overlay, pin and file-bind sources: some 150 or more
  repositories under one writable mount (the default `SANDBOX_GIT_MAX` is 200, five binds
  and the pins each), or fewer with long paths. To confirm on a Mac: such a launch on
  Colima ends in the entrypoint's "expected 0:0".
- **Expected:** every path the VM can stat is recorded, however many there are.
- **Suggested fix:** print the header once, outside xargs (a fixed `sh -c` that prints the
  shares and then `exec xargs -0 sh -c …`), or tag each record so a header in the middle is
  recognised. AGENTS.md still says the paths go "to a fixed `xargs -0 stat`"; update it.
- **Fix:** the first of those. `colima ssh` runs `_vm_hold_main`, which prints the share list and its NUL once and then `exec`s `xargs -0` with the per-path program, `_vm_hold_prog`, as its argument. A new batch therefore prints only triples. The paths stay on stdin, and `colima ssh`'s argv holds no path. After the fix, on the real VM, 400, 1200 and 3000 paths (824 KB) were all recorded. AGENTS.md now names both programs.
- **Tests:** T66 in `tests/test-launcher-dir-ro.sh` gained a check that runs `_vm_dev_ino_load()` on 40 paths of ~230 bytes. It uses the fake VM, with a fake `xargs` that splits at 4 KiB so that GNU and BSD xargs both split. It was seen red before the fix, recording 18 of 40, and green after. T66's argv check now expects the new command, and T73 loads both programs.

### LNCH-33: the entrypoint prints a mismatched mount's destination to the terminal as it is
- **Status: FIXED** (2026-11-17, review agent). `entrypoint.sh`: `verify_launcher_mounts()` replaces C0, DEL, UTF-8's C1 controls and the bidi controls in a refused destination, as `sandbox.sh`: `_term()` does on the host. `tests/test-launcher-verify.sh` case 7, seen failing first. Takes effect after a `./build.sh`.
- **Severity:** LOW
- **Confidence:** CONFIRMED (from the code, and by running the function on a crafted manifest)
- **Location:** `entrypoint.sh`: `verify_launcher_mounts()`, `printf 'ERROR: %s is not the directory it was checked as (expected %s, got %s).\n' "$dst"`
- **Introduced:** before the window (`a5e9948`)
- **What happens:** a manifest destination is where an overlay or pin lands in the
  container, so it holds directory names the agent chose (a planted launcher, an unlistable
  directory, a repository). The host side passes every such name through `_term()`; the
  entrypoint, whose output goes to the same terminal (`docker run -it`), does not. An agent
  in a concurrent container on the same tree plants `<ESC>]0;…<BEL><ESC>[2K/.ai-containers`
  and keeps swapping it between two directories; a launch that loses the race prints the
  name raw: the window title is set, lines of the refusal are erased or rewritten.
- **Repro:** `verify_launcher_mounts()` loaded from `entrypoint.sh` with `/run/ai-launcher`
  pointed at a scratch directory, a manifest entry `1`, `2`,
  `/workspace/p/$'\e]0;PWNED\a\e[2K'/.ai-containers`, and the matching anchor:
  `od -c` of stderr shows `033 ] 0 ; P W N E D \a 033 [ 2 K` inside the ERROR line.
- **Expected:** control characters replaced, as `_term()` does on the host.
- **Suggested fix:** print `$dst` with `%q`, or copy `_term()`'s three substitutions into the
  entrypoint; assert it in `tests/test-launcher-verify.sh`.

### LNCH-34: a repo named `ro`, `rw` or `rwcopy` attached with the mode of the same name is mounted read-only
- **Status: FIXED** (2026-11-17, review agent). "No mode given" is now an entry with no `:`, in `run_container()`'s REPOS loop, its REPO-13 pre-check and `pointer_repo_entry()`. `tests/test-docs-path.sh`: `rw:rw`, a bare `ro`, `@rw`, and `DOCS_PATH=@rw` beside `rw:rw`; all but the bare `ro` (the control) seen failing first.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `sandbox.sh`: `run_container()`, `[[ "$rmode" == "$rname" ]] && rmode="ro"` (and the same test in `pointer_repo_entry()`)
- **Introduced:** before the window (`8bcaa0e`)
- **What happens:** "no mode given" is detected by the mode equalling the name. `REPOS="rw:rw"`
  for a registered repo `rw` mounts it `:ro`; `./sandbox.sh restricted @rw` adds `rw:rw`
  itself and then fails with "primary repo 'rw' is attached :ro, but the working directory
  must be writable". `validate_repo_name` accepts those names.
- **Repro:** registry line `rw|path|<dir>|…|volume`; `REPOS="rw:rw" ./sandbox.sh restricted ..` →
  `REPO: /workspace/rw  (ro, shared volume ai-containers-repo-rw)` and `-v ai-containers-repo-rw:/workspace/rw:ro`;
  `./sandbox.sh restricted @rw` → rc 1 with the ERROR above.
- **Expected:** the mode written is the mode used.
- **Suggested fix:** test for the separator (`[[ "$entry" == *:* ]]`), not for equality.


---

## 3. Host lifecycle scripts (project.sh, init, sync, report, group)

### PRJ-12: an interrupt while `mv` removes the old `.ai-containers` (move across filesystems) leaves two setups, and the re-run it tells you to make is refused
- **Status: FIXED** (2026-11-17, review agent). `project.sh`: `_prj_move_dot()` marks the move landed (`_prj_mv_landed`, with the inode of what lands) just before the rename that lands it, a copy's across filesystems or the directory itself on one, and `_prj_mv_interrupted()` takes it as landed only once that inode is at `<new-dir>`. It then keeps the new working copies, names what is left of the old directory with the `rm -rf` that removes it where there is one, and says that running `mv` again finishes the move. Two reviews of the fix found the window between the rename and the mark, the move on one filesystem with no way forward, and messages that named steps already done. `tests/test-project-tool.sh`: a TERM during the removal, just after it, right after the copy lands, right after a rename on one filesystem, and before a rename with something planted where the copy goes, each followed by the way out it names; each was seen failing first, or against its mutant.
- **Severity:** MEDIUM (narrow window, but it is the "half-done mv that cannot be resumed" case, and the way out it leaves can lose `sandbox.local.env`)
- **Confidence:** CONFIRMED
- **Location:** `project.sh`: `_prj_move_dot()` (`if [[ -L "$old" ]] || ! rm -rf -- "$old"`), `_prj_mv_interrupted()`, and `cmd_mv()`: `ERROR: both %s and %s exist; remove or move one of them first`
- **Introduced:** `2fc5856` (feat(project): project.sh mv …), trap in `7da3f99`
- **What happens:** across filesystems `_prj_move_dot()` copies, checks, renames the copy into `<new-dir>/.ai-containers`, and only then `rm -rf`s the old directory. Ctrl-C (or TERM) during that `rm -rf` — which is not instant when `.agent-discovery/` holds a pcap — runs `_prj_mv_interrupted()` while `_prj_mv_undo` is still 1: it removes the new working copies, prints "The old working copies are as they were; run ./project.sh mv … again to move the project", and exits. Now the old `.ai-containers` is partly deleted, the new one is complete, and `projects.conf` still names the old root. The re-run stops at `both … exist; remove or move one of them first. Nothing was changed.`, without saying which of the two is whole. A user who trusts the registry and removes the new one loses whatever `rm` had already deleted from the old (in the repro: `sandbox.env` and `sandbox.local.env`). `docs/multiple-projects.md` promises "An interrupt (Ctrl-C) before the old copies start to go removes the copies made so far; the old ones are untouched, and running `mv` again starts over."
- **Repro:** harness; `mkproj "$W/alpha" $'IMAGE_NAME=img\n' $'VAULT_PATH=/v\n'`, a file beside it, `mkbase app`, `mkwc app 1 "$W/alpha/.ai-containers" "$CLEAN"`. Put a fake `rm` first on PATH that, when an argument is `$W/alpha/.ai-containers`, deletes `sandbox.env` and `sandbox.local.env` there, sends `kill -TERM $PPID` and exits 130 (else `exec /bin/rm "$@"`). Run `AI_CONTAINERS_MV_COPY=1 bash project.sh mv "$W/alpha" "$W/new" --yes`. Output ends `ERROR: interrupted; … Removed the new copy … again. The old working copies are as they were; run … again`. State: old dir holds only `runme.sh`, new dir holds all three files, registry unchanged. Remove the fake `rm`, run the same `mv` again: `ERROR: both …/alpha/.ai-containers and …/new/.ai-containers exist; remove or move one of them first. Nothing was changed.`
- **Expected:** a re-run finishes the move (the new directory is the checked copy), or the interrupt message says the new directory is complete and the old one is the leftover.
- **Suggested fix:** once the checked copy has landed, record that (a flag the trap reads) so the trap neither undoes the volume copies nor claims a clean restart, and names the old directory as a leftover to remove; or have `cmd_mv()` recognise "both exist and the new one is `_prj_tree`-equal-or-superset of the old" as a move to finish. Add a test with a TERM during the removal (the existing `FAKE_CP_TERM` covers only the copy).

### PRJ-13: `rm`/`mv` take an existing, unregistered directory named on the command line for the basename of another registered project
- **Status: FIXED** (2026-11-17, review agent). `project.sh`: `prj_resolve()` refuses a bare name that is both an unregistered directory here and a registered project's basename, naming both; a path (`./api`) picks one. `mv` (`unregistered-ok`) takes the registered one where it is gone (a setup moved by hand) or where the directory here is its `<new-dir>`. A registered root reached by another path to the same directory (a bind mount, a macOS firmlink) is matched by identity. Standing in a project that holds a subdirectory of its own name is refused, both named, and the docs say so. Two reviews of the fix found the gone and bind-mount cases blocked, the gone case then reopened for `rm`, and tests that compared logical paths with the physical ones the refusal prints. `tests/test-project-tool.sh`: each case, seen failing first.
- **Severity:** MEDIUM (a wrong destructive target; it needs `--yes` or an unread listing to bite)
- **Confidence:** CONFIRMED
- **Location:** `project.sh`: `prj_resolve()` (`# 3. a basename exactly one registered root has`)
- **Introduced:** `98ea89f` (feat(project): project.sh fronts init, report and sync, and names a project)
- **What happens:** step 3 runs for any argument without a `/`, whether or not that argument is a directory that exists. In a directory that holds an unregistered `./api`, `./project.sh rm api --yes` resolves `api` as a path, finds no registered root there, and then falls through to the basename rule and removes the setup, image and working copies of a different project registered as `/somewhere/else/api`. `mv api <new>` picks the other project the same way. The docs say `<project>` is "a registered path, a path to it, or the basename of exactly one registered project"; an existing path that is not registered is neither.
- **Repro:** harness; `mkproj "$W/work/api" $'IMAGE_NAME=img-api\n'`, `mkbase app`, `mkwc app 1 "$W/work/api/.ai-containers" $'PRIMARY|main\nBRANCH|main|3|current\nWORKTREE|changed\nEND|inspect\n'`; `mkdir -p "$W/elsewhere/api"`; `( cd "$W/elsewhere" && bash project.sh rm api --yes )`. Output: `About to remove project …/work/api: … AT RISK: main: 3 unpushed commit(s), uncommitted work in the checkout … Removed the working copy ai-containers-repo-app--wc-1. Removed …/work/api/.ai-containers. … OK: removed project …/work/api.`
- **Expected:** an argument that names an existing directory is a path: when no registered root is that directory, refuse ("not a registered project") rather than match it as a name; at least say in the listing that the project was chosen by name, not by the directory given.
- **Suggested fix:** in `prj_resolve()`, skip step 3 when `$phys` is set (the argument is an existing directory), or refuse with both candidates named.

### PRJ-14: `mv` cannot carry two working copies of one repo launched through two spellings of the project path
- **Status: FIXED** (2026-11-17, review agent). `project.sh`: `cmd_mv()` refuses, before the question, two working copies that would take one new name, naming both with where each was launched from. `tests/test-project-tool.sh`: the reviewer's repro, seen failing first.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `project.sh`: `cmd_mv()` (`nl="$(_prj_rebase "$ldir" "$old_dot" "$new_dot")"` … `wc_new+=(…)`) and `prj_copy_volume()` (`a volume named %s exists already`)
- **Introduced:** `2fc5856`
- **What happens:** a working copy's name comes from the launch directory as spelled (`workcopy_tag`), so launching once through a symlinked path and once through the physical one makes two copies of the same repo. `_prj_rebase()` maps both launch directories to the same new one, so both get the same new volume name. The listing shows both lines with the same target and no warning; after the question the first is copied, the second fails with "a volume named … exists already", the first copy is undone and `mv` exits 1. Nothing is lost, but every `mv` of that project fails the same way and the message does not say why or what to do.
- **Repro:** harness; `mkdir "$W/real"; ln -s "$W/real" "$W/link"`; `mkproj "$W/real/alpha" …`, a file beside it; `mkbase app`; `mkwc app 1 "$W/real/alpha/.ai-containers" "$CLEAN"`; `mkwc app 2 "$W/link/alpha/.ai-containers" "$CLEAN"`; `bash project.sh mv "$W/real/alpha" "$W/new" --yes` → both listed as `→ ai-containers-repo-app--wc-.ai-containers_<n>`, then `ERROR: a volume named … exists already; ai-containers-repo-app--wc-2 is not copied over it.` / `Removed the new copy … again.` rc 1.
- **Expected:** refused before the question, naming the two copies that would share a name and saying one has to be removed or pushed first.
- **Suggested fix:** after building `wc_new`, check it for duplicates and refuse in the "Nothing was changed" block with both old volumes and their launch directories.

### PRJ-15: `ai-containers-report.sh` prints `sandbox.env` values to the terminal and into `--tsv` unrendered
- **Status: FIXED** (2026-11-17, review agent). `ai-containers-report.sh`: every field of a row, every note, and the multi-base note's project and base go through `_rterm()` (`_ac_term()`'s substitutions; the script does not source sandbox-common.sh). `tests/test-report.sh`: a project whose group holds tabs, whose mode, CPUs, memory, engine version (a C1 control among them), name and a stale launcher's name hold control characters, registered in two bases, keeps its `--tsv` columns, and no control character reaches the table or its notes. The review of the first fix found its control-character check could never fail (a newline in the `grep` class) and most fields untested. Seen failing first. TST-41 was found running it.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `ai-containers-report.sh`: `env_var()` and `printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base_label" "$engver" …`
- **Introduced:** before the window (the values have always been printed raw; `0940160` rewrote the reader)
- **What happens:** group, network mode, CPUs and memory are read from each project's `sandbox.env` / `sandbox.local.env` and printed as they are. `sandbox.env` is the committed, shared file (and the agent's to write where `.ai-containers` is a writable mount root), so an escape sequence in a value reaches the host terminal (retitle, erase the line and overwrite the row), and a tab in a value shifts every later column of the `--tsv` output, whose schema AGENTS.md says is stable. `project.sh` renders the same sources through `_ac_term()`; LNCH-3 fixed the same class in the launcher.
- **Repro:** harness with the real `ai-containers-report.sh` copied into the engine; `mkproj "$W/alpha" $'IMAGE_NAME=img\nCONTAINER_CPUS=\e]0;PWNED\a4\nSANDBOX_MODE=open\e[2K\rrestricted\nAI_CONTAINER_GROUP=g\tx\ty\n'`; `bash ai-containers-report.sh | cat -v` shows `OPEN^[[2K^MRESTRICTED  ^[]0;PWNED^G4`; `--tsv` prints the row with 12 fields under a 10-field header (`g	x	y	alpha	…`).
- **Expected:** control characters (tab included) replaced before a value is printed or written as a TSV field.
- **Suggested fix:** pass every value read from a project's files through one renderer (`_ac_term`'s substitutions; the script does not source `sandbox-common.sh`, so a local copy or an awk `gsub(/[[:cntrl:]]/, "?")` in `env_var()`).

### PRJ-16: `group.sh gc` removes the Ruby volume of a group that exists only in another home on a shared daemon
- **Status: FIXED, the rest a stated limit** (2026-11-17, review agent; the user's choice). `sandbox-common.sh`: `rvm_volume_ensure()` labels a new volume with `ai_containers_owner_id()`. `group.sh`: `gc` takes only this home's orphans; another home's and an unlabelled one are kept and named, and `--all` takes them, still named. `rm` keeps a volume another home made and removes this home's directory. Neither reads a failed `docker ps` as no container using a volume (`_vol_busy()`), nor a docker that cannot be reached as one with no volume (`_docker_answers()`; `list` then shows each group's volume as unknown, rc 1), and `gc` exits 1 when it skipped a volume it could not judge. With no group directory left, `list` still names the orphaned volumes, where it returned before its orphan check. With no owner key, `rm` says the volume it keeps may be this home's own, made before the key was lost. A group of the same name in two homes still shares one volume, which the home that made it can remove: a stated limit, said at launch and in `docs/troubleshooting.md`, with `REPO_VOLUME_PREFIX` to keep homes apart. Three reviews of the fix found the messages and docs that overstated the protection. `list` says which orphans `gc` keeps, and a home whose owner key is gone says why its own volumes look like another's. `tests/test-group-lifecycle.sh` and `tests/test-rvm-volume.sh`, each seen failing first. The review of the fix found that two homes on one docker with a group of the same name share one volume, `rvm_volume_name()` having no home in it, so the home that made it can still remove it from under the other's live group. The user chose a stated limit over renaming every volume: the launch that mounts a volume another home made names it in a `NOTE:` (`sandbox-common.sh`: `_rvm_shared_note()`, `tests/test-rvm-volume.sh`), and docs/troubleshooting.md, "Several homes on one docker", says what sharing a docker does (that, and another user's uid on shared volumes) and how a `REPO_VOLUME_PREFIX` per home keeps them apart.
- **Severity:** LOW (a regenerable cache, listed and confirmed first; minutes per Ruby to rebuild)
- **Confidence:** CONFIRMED (from the code)
- **Location:** `group.sh`: `cmd_gc()` (`[[ -d "$groups_root/$g" ]] && continue          # group still exists — keep`), and the same test in `cmd_list()`'s orphan list
- **Introduced:** before the window; the shared-daemon case was recognised in the window for working copies only (`46e529c`, `7733768`)
- **What happens:** an rvm volume is "orphaned" when `~/.ai-containers/<group>` is missing in *this* HOME. Docker Desktop serves one daemon to every WSL distro (the case `project.sh gc` and `repo.sh gc` now handle with `ai-containers.owner`), so a group `docs` made in distro B has its `ai-containers-rvm-docs` listed as orphaned and removed by `./group.sh gc` in distro A, unless a container happens to be running on it. `docker_volume_in_use()` also reads a failed `docker ps` as "not in use".
- **Repro:** `group.sh`: `cmd_gc()` — `g="$(rvm_group_from_volume "$v")"; [[ -d "$groups_root/$g" ]] && continue; docker_volume_in_use "$v" && { … continue; }; targets=…`; no owner is recorded (`rvm_volume_ensure()` labels only `ai-containers.rvm-group`).
- **Expected:** as for working copies: a volume this home did not make is kept and named, with an `--all` to take it.
- **Suggested fix:** label the rvm volume with `ai_containers_owner_id()` at creation and have `gc`/`list` keep another owner's (and say that an unlabelled one may be another home's).

### PRJ-17: "refuses while a container of the project runs" rests on `docker inspect`'s mount sources being host paths
- **Status: NOT REPRODUCIBLE on WSL** (2026-11-17, review agent). Measured on Docker Desktop 29.9.3 with WSL integration: a container run with `-v <distro path>:/x` reports `.Mounts[].Source` as that distro path, the same as `.HostConfig.Binds`, so `prj_running()`'s mount check holds there; a native Engine reports host paths by construction. Docker Desktop for Mac is not measured: the Mac agent's machine has none (PLAT-3). No code changed.
- **Severity:** LOW
- **Confidence:** PLAUSIBLE
- **Location:** `project.sh`: `prj_running()` (`{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}`)
- **Introduced:** `72014a5` (feat(project): project.sh rm …)
- **What happens:** the mount half of the check compares each running container's `.Mounts[].Source` with the project's `.ai-containers` path. On Docker Desktop with WSL integration a bind mount from the distro's own filesystem is, as far as I know, reported there as `/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/<distro>/<hash>` (the path as given stays in `.HostConfig.Binds`), and older Docker Desktop for Mac reported `/host_mnt/...`. Where that holds, only the `ancestor=<IMAGE_NAME>` half is left: a project whose settings are gone (`_prj_has_env` false, "by mounts only"), or a container started with another `IMAGE_NAME` (the shell's, or one changed since), is not seen as running, and `rm` deletes `.ai-containers` (its `.agent-blocked`/`.agent-discovery` mounted in the container) under it; `mv` moves it.
- **Repro:** not reproduced: no container may be run here. To confirm, on Docker Desktop + WSL: `docker run -d --name t -v "$HOME/x:/x" alpine sleep 60; docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}{{json .HostConfig.Binds}}' t`.
- **Expected:** the check holds on every supported engine.
- **Suggested fix:** read `.HostConfig.Binds` (the source as the launcher passed it) as well as `.Mounts`, or have `sandbox.sh` label the container with the launch directory and filter on the label. Either way add an integration case: the hermetic fake returns host paths by construction.

### PRJ-18: `~/.ai-containers/restored`, the launcher's own directory, is a group to `group.sh` and `project-init.sh`
- **Status: FIXED** (2026-11-17, review agent). What a launch keeps from a protected git file's place goes to the hidden `~/.ai-containers/.restored/` (`sandbox.sh`: `_ro_files_restore()`), a name no group can have, so no listing, menu or `rm` takes it for a group, and `restored` stays an ordinary group name. The first fix reserved the name `restored`, which the review found would strand a user's group of that name; it was undone. `tests/test-group-lifecycle.sh`, `tests/test-git-internals-ro-reads.sh` G136, and `tests/test-git-internals-ro-casefold.sh` where it runs. An earlier launch's `restored` directory is still listed as a group; the CHANGELOG says what to do with it.
- **Severity:** LOW
- **Confidence:** CONFIRMED (from the code)
- **Location:** `group.sh`: `group_names()`; `project-init.sh`: `existing_groups()`; made by `sandbox.sh`: `rd="$ai_containers_root/restored/$(date +%Y%m%d%H%M%S)-$$"`
- **Introduced:** `7b43d4d` (fix(sandbox): keep the changed git file outside its directory (GIT-41 review))
- **What happens:** on a host share that ignores case (Colima), `_ro_files_restore()` keeps what an agent left at a protected git file's name under `~/.ai-containers/restored/<time>-<pid>/`. `restored` passes `validate_group_name`, and both group listings take every directory of `~/.ai-containers` for a group: `./group.sh list` shows a group `restored`, `./group.sh rm restored` deletes the kept files as "group", `project-init.sh` offers it as a container group, and choosing it (or `AI_CONTAINER_GROUP=restored`) mounts its dot-directories from the directory that holds agent-written files.
- **Repro:** `mkdir -p "$HOME/.ai-containers/restored/20261117-1"` in a scratch HOME, then `./group.sh list` (fake docker) prints a `restored` row; `existing_groups` in `project-init.sh` prints it.
- **Expected:** the directory is not a group: a name no group can have (a leading dot, as `.verify-*` has), or `restored` reserved in `validate_group_name` and skipped by both listings.
- **Suggested fix:** keep the copies under `~/.ai-containers/.restored/`, or refuse and skip the name `restored` wherever `host` is refused.


---

## 4. Repo volumes, env layers, version and build

### REPO-19: `inspect` runs git on a volume that still holds nested `.git`s, so the agent can hang every `repo.sh reset` (and `project.sh rm`'s check) for ever
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `repo-git-reset.sh`: `worktree_state()`, called from `cmd_inspect()` after `check_volume "$dir" list`
- **Introduced:** `aff5b8a` (feat(repo): inspect reports whether a checkout's files differ from its branch (WORKTREE))
- **What happens:** `check_volume`'s `list` mode only lists a `.git` below the top level (REPO-5). `worktree_state()` then uses the volume as a work tree for `read-tree <tip>`, `update-index --refresh`, `diff-files --ignore-submodules=all` and `ls-files --others`. The tip is the volume's own branch (read through the alternate object store), so the agent chooses its tree. With a gitlink at `sub` in a local commit and a `sub/.git` file naming a git directory inside the volume, `diff-files` opens that repository and reads its `config`, includes and all (`--ignore-submodules=all` is applied after `ce_compare_gitlink()`). An `include.path = /proc/1/fd/1` there is the helper's own stdout pipe in the seed container (pid 1, `docker run` without a tty): git opens it for reading and blocks until someone writes, which the helper only does after git returns. No FIFO or device is in the volume, so `check_volume` passes. `repo.sh reset` runs `inspect` first, with or without `--yes`, so the volume can never be reset (the "way out" every sync refusal names); `project.sh rm`'s working-copy check hangs the same way. The header of the file and AGENTS.md both say git never reads a nested `.git` ("removes it with `rm -rf` before any git runs", "so git never reads one"). A link `commondir -> /dev/zero` in a nested git directory is read by `ls-files --others` too (memory, bounded by `REPO_HELPER_MEMORY`).
- **Repro:**
  ```
  git init -q --bare -b main rem.git; git clone -q rem.git seed
  (cd seed; echo a > a; git add a; git commit -qm a; git push -q origin HEAD:main)
  git clone -q rem.git vol; cd vol
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),sub"; git commit -qm local-gitlink
  mkdir -p sub hidden; git init -q --bare hidden/g; printf 'gitdir: ../hidden/g\n' > sub/.git; cd ..
  timeout 15 bash -c 'printf "[include]\n\tpath = /proc/%s/fd/1\n" $$ >> vol/hidden/g/config
     AI_REPO_URL=$PWD/rem.git exec bash '"$H"' inspect $PWD/vol' | cat; echo "rc=${PIPESTATUS[0]}"
  ```
  Prints `NESTED|sub/.git`, `PRIMARY|main`, `BRANCH|main|1|current`, then nothing; `rc=124`. With `GIT_TRACE` the last line is `git diff-files --ignore-submodules=all --quiet`. With a FIFO include and a writer that opens it after 15 s, inspect takes 16 s and ends `WORKTREE|clean`.
- **Expected:** no git of `inspect` uses the volume as a work tree while a `.git` below its top level is there; inspect ends, with the state unknown.
- **Suggested fix:** in `cmd_inspect()`, print `WORKTREE|?` without calling `worktree_state()` when `nested_in` found anything (project.sh already counts `?` as at risk). Add the case to `tests/test-repo-git-reset.sh` beside the REPO-5 gitlink fixture, bounded by `p_timeout`.
- **Fix:** `cmd_inspect()` prints `WORKTREE|?` without calling `worktree_state()` when `check_volume`'s list mode found a `.git` below the top level (`NESTED_FOUND`), so no git of `inspect` uses the volume as a work tree while one is there. `project.sh` already counts `?` at risk. The header's "so git never reads one" is true again.
- **Tests:** in `tests/test-repo-git-reset.sh`, the review's shape: a local commit with a gitlink at `sub`, a `sub/.git` naming a git directory whose config includes a FIFO outside the volume, under `p_timeout` with a writer that releases the FIFO after 20 s. It requires `NESTED|sub/.git`, `WORKTREE|?` and `END|inspect` in under 15 s. With the check removed it failed, taking 21 s (the hang, until the writer). Closes GAP-21.

### REPO-20: `sync` and `reset` delete `.git/modules/<name>` with its unpushed commits, and neither says so
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `repo-git-reset.sh`: `cmd_pull()` (the checks before `install_git_dir "$dir"`) and `cmd_inspect()`
- **Introduced:** `2a8d666` (refactor(repo): never run git on a repo volume's own .git)
- **What happens:** `pull` refuses a stash, notes, linked worktrees, tags on no remote, refs outside heads/tags/remotes and operations in progress, because `.git` is replaced whole. A submodule's repository lives in `.git/modules/<name>` and is not checked. While the submodule is checked out, `sub/.git` makes sync refuse ("remove it (rm -rf from a container), or reset … then retry"). Once that `.git` file is gone — by following that message, or by `git submodule deinit -f sub`, the ordinary way to put a submodule away — sync succeeds and the submodule's repository, with any commit never pushed to the submodule's remote, is gone. `reset` does the same; its confirmation lists a `NESTED` `.git` in the work tree but nothing for `.git/modules`.
- **Repro:**
  ```
  # rem.git has a submodule `sub` (subrem.git); vol is a clone of rem.git
  cd vol; git -c protocol.file.allow=always submodule -q update --init
  (cd sub; echo work > w; git add w; git commit -qm "UNPUSHED submodule work"); sm=$(git -C sub rev-parse HEAD)
  git submodule -q deinit -f sub; ls .git/modules        # -> sub
  cd ..; (cd seed; echo b > b; git add b; git commit -qm b; git push -q origin HEAD:main)
  AI_REPO_URL=$PWD/rem.git bash $H pull $PWD/vol; echo rc=$?   # AT|7666423, rc=0, no WARN
  ls vol/.git/modules                                  # No such file or directory
  ```
- **Expected:** `sync` refuses while `.git/modules` holds a repository (as it does for a stash or `refs/wip/*`), or carries the directory over; `reset`'s summary lists each as lost, counted at risk.
- **Suggested fix:** in `cmd_pull()`, die when `find "$gd/modules" -mindepth 1 -print -quit` finds anything ("the repository holds submodule repositories in .git/modules; push their work and remove them, or use reset"). In `cmd_inspect()`, emit a record per directory under `.git/modules` and have `collect_inspections()` list it at risk.
- **Fix:** `cmd_pull()` refuses while `.git/modules` holds anything ("the repository holds submodule repositories in .git/modules; push their work and remove them, or use reset"), a `find` that fails refusing too. `cmd_inspect()` emits `MODULE|<entry>` for each entry there (50, then `MODULE-MORE|<n>`), which `collect_inspections()` lists as `REMOVE .git/modules/<entry>` and `project.sh` as at risk, each counted.
- **Tests:** in `tests/test-repo-git-reset.sh`, a real submodule with a commit never pushed to its remote, put away with `git submodule deinit -f`: `pull` refuses and the commit is still readable in `.git/modules/sub`; `inspect` prints `MODULE|sub`. In `tests/test-repo-destructive.sh` and `tests/test-project-tool.sh`, the summary and the risk line. Each was seen red with its half of the fix removed. With GAP-23's other half.

### REPO-21: `reset` drops the commits of a detached HEAD and its summary counts nothing at risk
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `repo-git-reset.sh`: `cmd_inspect()` (`volume_head` is used only for the `current` flag); `repo.sh`: `collect_inspections()`
- **Introduced:** `2a8d666` (before it the old `.git`, and its reflog, survived a reset); the summary's list was completed for the stash, tags and the primary in `f603639` without this case
- **What happens:** a volume whose HEAD is detached with commits made on it (an agent that ran `git checkout origin/main` or `git checkout <tag>` and committed; a rebase stopped halfway). `inspect` reports only `refs/heads/*`, so the summary reads `- app: switches to 'main'` with no line under it and no `WARNING: N item(s) … hold work that is on no remote`. `reset` then replaces `.git`, and the commits are unreachable and gone. AGENTS.md: "Every run … first prints the branch it will switch to and each branch it will drop, marking those whose commits are on no remote branch".
- **Repro:**
  ```
  git clone -q rem.git vol; cd vol; git checkout -q --detach
  echo w1 > w1; git add w1; git commit -qm "unpushed 1"; c=$(git rev-parse HEAD); cd ..
  AI_REPO_URL=$PWD/rem.git bash $H inspect $PWD/vol
  #  PRIMARY|main / BRANCH|main|0| / WORKTREE|? / END|inspect      <- nothing about HEAD
  AI_REPO_URL=$PWD/rem.git bash $H reset $PWD/vol main      # ON|main AT|… DELETED-COUNT|0, rc=0
  git -C vol cat-file -t $c                                 # fatal: could not get object info
  ```
- **Expected:** the confirmation names the detached HEAD with its count of commits on no remote branch or tag (or "unknown"), counted at risk.
- **Suggested fix:** in `cmd_inspect()`, when HEAD holds an object id, emit `BRANCH|(detached HEAD)|<count>|current` (or a `DETACHED|<count>` record) computed as the branch counts are; render it in `collect_inspections()`.
- **Fix:** `volume_detached()` reads `HEAD` as text; when it names no branch, `cmd_inspect()` prints `DETACHED|<n>`, the commits on no remote branch or tag counted as the branches are (`?` when they cannot be, or when `HEAD` holds no object id). `collect_inspections()` lists `DROP the detached HEAD — <n> commit(s) not on any remote` (or "unpushed count unknown"), counted at risk, and nothing when the count is 0; `project.sh` likewise.
- **Tests:** in `tests/test-repo-git-reset.sh`, a detached HEAD with two local commits (`DETACHED|2`), one on a pushed commit (`DETACHED|0`), a `HEAD` holding neither (`DETACHED|?`) and one on a branch (no record). In `tests/test-repo-destructive.sh`, the summary for 2, `?` and 0; in `tests/test-project-tool.sh`, the risk line. Each was seen red with its half of the fix removed. With GAP-23's other half.

### REPO-22: a reset whose remote cannot be cloned says it continues with a "LOCAL reset", removes every working copy, changes nothing else and ends "OK: reset complete"
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** MEDIUM
- **Confidence:** CONFIRMED
- **Location:** `repo.sh`: `cmd_reset()` (`Continuing with the LOCAL reset`), `collect_inspections()` (`no branch to reset onto (detached HEAD, no usable remote)`), `reset_one()`
- **Introduced:** the text is from before the window (`14bd8a6`); it became false in `2a8d666`, since when reset needs the remote
- **What happens:** offline, or with the remote gone, `inspect` prints `STALE|<reason>` and no `PRIMARY`. The summary's `(STALE: fetch failed)` note sits on the branch where a primary is known, which cannot happen with `STALE`, so the summary never says STALE: it says "no branch to reset onto (detached HEAD, no usable remote)". After the confirmation the launcher prints "Continuing with the LOCAL reset: the tree will be clean and on the primary branch, but at the remote tip as last fetched", which no code does. `reset_one()` then removes every `:rwcopy` working copy of the repo (where the active edits are, unchecked for unpushed work), leaves the base volume alone, and the run ends `OK: reset complete.` with status 0. `docs/repos-and-mounts.md`: "No network, no credentials, or a remote that has gone away leaves the repo **untouched**, with the reason in the summary (`STALE`)". The same summary and the same removal follow when `git_helper_run()` refuses because a running container mounts the base volume read-write (its `ERROR:` goes to stderr, the summary still says "detached HEAD").
- **Repro:** a fake `docker` whose `run … inspect /dst` prints `STALE|ssh: Could not resolve hostname example.invalid`, `BRANCH|main|?|current`, `END|inspect`, whose `volume ls` lists `ai-containers-repo-app--wc-proj_1234`, registry line `app|git|git@example.invalid:x/app.git|1|1|volume`:
  ```
  PATH=$T/f/bin:$PATH SANDBOX_CONF=/dev/null bash WT/repo.sh reset app --yes
  #  - app: no branch to reset onto (detached HEAD, no usable remote) — its base volume will be left untouched; its working copies are still removed
  #  WARNING: app: fetch failed (ssh: Could not resolve hostname example.invalid).
  #           Continuing with the LOCAL reset: the tree will be clean and on the primary branch, …
  #    app: removed working copy ai-containers-repo-app--wc-proj_1234
  #    app: no branch to reset onto (detached HEAD, no usable remote) — left untouched.
  #  OK: reset complete.          rc=0
  ```
- **Expected:** the summary gives the reason (`STALE: <reason>`, or "a running container mounts it read-write") before the question; nothing of that repo is removed, its working copies included, as the docs say; the run does not end "OK" with status 0 for a repo it did not reset.
- **Suggested fix:** in `collect_inspections()` build the STALE summary line from `$stale` and mark the repo skipped; in `reset_one()` return before the working copies when there is no primary; drop the "LOCAL reset" text; exit non-zero when any target was skipped. `tests/test-repo-destructive.sh` has no STALE case: add one.
- **Fix:** `collect_inspections()` gives the reason in the summary before the question: `STALE: its recorded remote could not be cloned (<reason>)`, `it could not be inspected (the error is above)` (the helper did not run: `git_helper_run()` refused), or `its remote has no primary branch to reset onto (no HEAD, main or master)`, each "will be left untouched, its working copies included". `reset_one()` returns before it removes any working copy when a git repo with a base volume has no primary, saying why. The "LOCAL reset" text is gone, and `cmd_reset()` ends `ERROR: not reset: <names>` with status 1 rather than `OK: reset complete.`. This reverses the REPO-11 fix's choice that the working copies still go, as the docs' "untouched" says. Its review found the working copies were still removed before every other step that can fail (a re-seed with no network, a path source gone, a `reset_git` refused at reset time), so `reset_one()` now removes them only once the base volume's reset has succeeded.
- **Tests:** in `tests/test-repo-destructive.sh` (GAP-22): a fake helper printing `STALE|…`, one printing nothing and failing, and the existing no-primary case, which now requires a non-zero exit, the reason and nothing removed; and `reset --all` with STALE remotes names every repo. Each was seen red with the skip, the STALE reason or the exit removed. A reset that fails, and a re-seed whose clone fails, remove no working copy: seen red with the removal moved back before the base volume's step.

### REPO-23: `reset` writes the checkout through the agent's untracked `.gitattributes`, so the "clean checkout" differs from the remote
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `repo-git-reset.sh`: `cmd_reset()` (`checkout --quiet --force -B "$primary"` runs before `clean -ffdxq`)
- **Introduced:** `2a8d666`
- **What happens:** the clone's index is empty, so `checkout --force` writes every file, and git applies the attributes of a `.gitattributes` in the work tree where the tree being checked out has none at that path. An untracked `.gitattributes` holding `* text eol=crlf` (or `working-tree-encoding=UTF-16`, `ident`) converts every file written; `clean` then deletes the `.gitattributes`, so nothing shows why. After `reset` every text file has CRLF endings (`#!/bin/sh\r` no longer runs), `git status` shows them modified, and the next `sync` refuses with "uncommitted changes … use reset". No filter can run (the clone's config has no driver), so content is damaged, not chosen.
- **Repro:**
  ```
  # rem.git tracks bin/run.sh ("#!/bin/sh\necho hi\n") and a.txt; vol is a clone
  printf '* text eol=crlf\n' > vol/.gitattributes
  AI_REPO_URL=$PWD/rem.git bash $H reset $PWD/vol main      # rc=0
  od -c vol/bin/run.sh | head -1     # #   !   /   b   i   n   /   s   h  \r  \n …
  git -C vol status --short          #  M a.txt /  M bin/run.sh ; no .gitattributes left
  ```
- **Expected:** after `reset` the files are the remote's bytes and `git status` is clean.
- **Suggested fix:** empty the work tree first (run the `clean -ffdxq` before the checkout: with the clone's empty index everything is untracked), or check out with `--attr-source="refs/remotes/origin/$primary"` where the seed image's git has it. Assert `git status --porcelain` is empty after a reset over a planted `.gitattributes`.
- **Fix:** `cmd_reset()` runs `clean -ffdxq` before the checkout: with the clone's empty index everything in the work tree is untracked, so the checkout writes into an empty tree and no untracked `.gitattributes` applies.
- **Tests:** in `tests/test-repo-git-reset.sh`, an untracked `.gitattributes` holding `* text eol=crlf` before a reset: afterwards `git status --porcelain` is empty and the files hold no CR. Seen red with the clean moved back after the checkout.

### ENV-10: `version_engine` reads `engine-version` through a link, and a sync copies the first line of the file it names into every project
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `version.sh`: `version_engine()` (`if _ver_read v "$dir/engine-version"`), `_ver_read()` (`[[ -f "$2" ]]`), `version_record()`
- **Introduced:** the read is from `734e75b`, before the window; `cd36db1` (GIT-28) made every other read "never through a link" and left this one
- **What happens:** the precondition is GIT-28's: an engine checkout the agent can write (mounted as a mount root, which stays writable with a `NOTE:`). The recorded version wins over git in an engine tree too. The agent makes `engine-version` a link to a host file whose first line is a secret (`~/.git-credentials`: `https://user:token@github.com`; `~/.npmrc`: `//registry.npmjs.org/:_authToken=…`; `~/.netrc`). The next `./sync-to-projects.sh` on the host calls `version_record`, which writes that line, whitespace removed, as `<project>/.ai-containers/engine-version` of every registered project, where any container of those projects reads it. `./sandbox.sh --version` prints it too. AGENTS.md says of HEAD, refs and tags "from regular files never reached through a link" and of this file "read the same bounded way".
- **Repro:**
  ```
  printf 'https://alice:ghp_SECRETTOKEN@github.com\n' > $HOME/.git-credentials
  mkdir -p e/engine e/proj; cp WT/version.sh e/engine/; ln -s $HOME/.git-credentials e/engine/engine-version
  bash -c 'source e/engine/version.sh; version_record "$PWD/e/engine" "$PWD/e/proj"; cat e/proj/engine-version'
  #  https://alice:ghp_SECRETTOKEN@github.com
  ```
- **Expected:** a linked (or non-regular) `engine-version` is not read; the version is taken from git or is `unknown`.
- **Suggested fix:** in `version_engine()`, read it only when `[[ -f … && ! -L … ]]`, and accept only a version's characters (see ENV-11), which no credential line survives.
- **Fix:** `version_engine()` reads `engine-version` only when it is a regular file and not a link, naming one that is not on stderr, never what it holds or leads to; the version is then git's, in an engine tree, or `unknown`. The read itself (`_ver_cat_own()`, run as `_ver_run()`'s bounded job) opens the name and keeps what it read only when the open descriptor's device and inode are those of the name itself, stat without `-L`, so a link swapped in after the `-L` test and out again gives nothing. What it read must also be a version (ENV-11), which a credential line is not.
- **Tests:** in `tests/test-version.sh`, a linked `engine-version` is neither read nor recorded into a project, and is named without its target's line; `_ver_cat_own()` refuses a link at the name; an engine tree with a linked one reports git's tag; a FIFO there is not read; one that cannot be opened is named and not read (added for a survivor of the falsify run, the open's failure returning 0). Each seen red with its guard removed: the `-L` test (its note), the identity check (the secret came back), both together (only the version check then kept the line out).
- **macOS (2026-11-17, the Mac agent):** at `9e4c7b0` `tests/test-version.sh` failed 8 checks on macOS 26.7.3: fdescfs reports its own device for a stat of `/dev/fd/3` (227567474 against the file's 16777231), with the open file's inode, so the identity never matched and every recorded version read as `unknown`, failing closed as the PR said it would. `_ver_cat_own()` now asks the descriptor by fstat through stdin (GNU `stat -`, BSD `stat` with no operand). The file then passes on macOS with BSD `stat`, and with GNU `stat` 9.12 first on `PATH`, and on the floor container (ubuntu:22.04, GNU `stat` 8.32).

### ENV-11: the engine version is printed, and recorded into projects, with the control characters the checkout's writer put in it
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `version.sh`: `version_engine()` (`v="${v//[[:space:]]/}"`), `_ver_git_version()` (`_ver_run v "${e[@]}" describe --tags`), `version_report()`
- **Introduced:** `734e75b` for the recorded file (before the window); `cd36db1` for the tag path
- **What happens:** same precondition as GIT-28. (a) `engine-version` holding `v1.0\e]0;PWNED\a\e[2J` is printed as it is by `./sandbox.sh --version`, `./runme.sh --version` and `ai-containers-report.sh`: only whitespace is removed. (b) With no recorded file, `git describe --tags` prints the name written **inside** an annotated tag object, not the ref's name, so the ref-name check git applies to `packed-refs` does not cover it: a tag object whose `tag` line holds an escape sequence comes out in the version. Both are also written into each project's `engine-version` by a sync. LNCH-3 fixed this class for the launcher's messages (`_term()`); `sandbox-common.sh` has `_ac_term()`; version.sh uses neither.
- **Repro:**
  ```
  printf 'v1.0\033]0;PWNED\007\033[2J\n' > e1/engine-version      # e1 holds version.sh
  bash -c 'source e1/version.sh; version_report "$PWD/e1"' | od -c | head -2
  #  a i - c o n t a i n e r s … v 1 . 0 033 ] 0 ; P W N E D \a 033 [ 2 J
  # (b) in a repository holding version.sh and project-init.sh, one commit $c:
  t=$(printf 'object %s\ntype commit\ntag v9\033]0;PWNED\007\ntagger a <a@b> 1 +0000\n\nm\n' $c | git hash-object -t tag -w --stdin --literally)
  echo $t > .git/refs/tags/v9
  bash -c 'source ./version.sh; version_engine "$PWD"' | od -c
  #  v 9 033 ] 0 ; P W N E D \a - 0 - g c 1 2 d a 4 c
  ```
- **Expected:** a version is `[A-Za-z0-9._+-]` and nothing else; anything else is `unknown` (or rendered as `_ac_term()` renders a label).
- **Suggested fix:** one check at the end of `version_engine()`: `[[ "$v" =~ ^[A-Za-z0-9._+-]{1,128}$ ]] || v=unknown`, for the recorded value and git's alike. `sandbox.conf`'s `nvm-version` and the Dockerfile's `ARG NVM_VERSION`, printed by `version_report()` after `tr -d '[:space:]'`, want the same.
- **Fix:** `_ver_ok()` accepts 1 to 128 of `[A-Za-z0-9._+-]`, and `version_engine()` asks it of the recorded value and of git's alike: a recorded one that fails is not used (git's, in an engine tree, or `unknown`, with a `NOTE:`), and a `describe` that fails is `unknown` with a `NOTE:`. The recorded value loses only its leading and trailing whitespace now, so whitespace inside it is no version. `version_report()` asks the same of `nvm-version` and the Dockerfile's `ARG NVM_VERSION`, printing `unknown  (the value set is not a version)`. `version_record()` writes only what `version_engine()` returns, so nothing else reaches a project.
- **Tests:** in `tests/test-version.sh`, an `engine-version` holding an escape sequence reports `unknown` and is not recorded; `v1 .2` is no version and ` v1.2.3+build_7 ` is `v1.2.3+build_7`; an annotated tag object naming itself with an escape sequence reports `unknown`; an `nvm-version` holding one reports `unknown`, saying why. Each seen red with its check removed (the version check made always true, git's answer checked only for being non-empty, the nvm check removed, every whitespace dropped again).

### REPO-24: `sync --all` stops at the first repo it refuses and never reaches the rest
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `repo.sh`: `cmd_sync()` (`sync_one "$target"` under `set -e`), `sync_from_git()` (`return "$rc"`)
- **Introduced:** before the window; it matters more since `371cbfd`…`a0d9c9f`, which made `sync` refuse a dozen ordinary states by design
- **What happens:** `docs/repos-and-mounts.md` calls `sync --all` "the usual start-of-day refresh" that "brings every registered repo up to date in one command". One repo with uncommitted changes, a stash or an unpushed branch makes the helper exit 1; `sync_one` returns it, `set -e` ends the script, and every repo after it in the registry is neither synced nor named. `reset --all` has the same shape in `reset_one()` → `reset_git()` (`return 1`), after that repo's working copies are already removed.
- **Repro:** registry lines `aaa`, `bbb`, `ccc` (git, volume); a fake `docker` whose `run` for `ai-containers-repo-aaa:/dst` prints the helper's refusal on stderr and exits 1:
  ```
  PATH=$T/f/bin:$PATH SANDBOX_CONF=/dev/null bash WT/repo.sh sync --all; echo rc=$?
  #  Pulling latest into volume "ai-containers-repo-aaa" …
  #  repo-git-reset: the checkout has uncommitted changes; commit and push them, or use reset
  #  rc=1                      <- no line for bbb or ccc
  ```
- **Expected:** with `--all`, each repo is tried, each failure is named, and the exit status is non-zero if any failed.
- **Suggested fix:** in the `--all` loops call `sync_one "$target" || failed+=("$target")` (and the same for `reset_one`), print the list at the end and exit 1 when it is not empty.
- **Fix:** `cmd_sync()` and `cmd_reset()` call `sync_one`/`reset_one` as `… || failed+=(…)`, print `ERROR: not synced: …` / `not reset: …` at the end and exit 1. Since bash ignores `set -e` in a function called from a `||` list, `sync_one()` and `reset_one()` now check every step themselves (`|| return 1`), and `seed_binds_check()`, `seed_from_path()`, `seed_from_git()` and `sync_from_path()` return where they exited. A working copy `reset` cannot remove is now named too, and fails that repo.
- **Tests:** in `tests/test-repo-destructive.sh`, the review's shape: the helper refuses the first repo of three; `sync --all` syncs the other two, names the first and exits 1, and `reset --all` does the same. Each was seen red with the `||` removed.

### REPO-25: `repo.sh rm` reports "OK: removed" and drops the registry line when docker refused to remove the volume
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `repo.sh`: `cmd_rm()` (`docker volume rm "$vol" >/dev/null 2>&1 || true`)
- **Introduced:** before the window (`c094411`)
- **What happens:** a base volume or working copy a container (stopped ones included) still uses cannot be removed. The error is discarded, the registry line is removed and `OK: removed repo "app".` is printed with status 0. The volume stays, now unregistered; a later `./repo.sh add app …` refuses with "Remove the stray volume first". `cmd_gc()` reports the same failure (`WARN: could not remove`).
- **Repro:** fake `docker` whose `volume rm` exits 1: `PATH=$T/f/bin:$PATH bash WT/repo.sh rm app --yes` prints `OK: removed repo "app".`, `rc=0`, and `repos.conf` no longer holds `app`.
- **Expected:** each volume that could not be removed is named, the registry line is kept while the base volume exists, and the status is non-zero.
- **Suggested fix:** check each `docker volume rm`, as `cmd_gc()` does; remove the registry line only once the base volume is gone.
- **Fix:** `cmd_rm()` checks each `docker volume rm`, removes the base volume only when one exists, keeps the registry line while it is there, names every volume docker refused with the `docker ps -a --filter volume=` that finds its user, and exits 1.
- **Tests:** in `tests/test-repo-destructive.sh`, a fake `docker` refusing the base volume (the registry line kept, the volume named, status 1, no "OK: removed") and refusing one working copy (named, the rest removed, the line dropped with the base volume). Seen red with the base volume's check removed. The bind-backend case no longer expects a `volume rm` of a volume that does not exist.

### REPO-26: `repo.sh add` writes a host path holding `|` into the registry, and it reads back as another directory
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `repo.sh`: `cmd_add()`; `sandbox-common.sh`: `repo_registry_upsert()`, `repo_record_field()`
- **Introduced:** before the window; `cmd_reindex()` got the check in the window (`source == *[$'|\n\r']*`), `cmd_add()` did not
- **What happens:** the registry is `|`-delimited. `./repo.sh add pipe "/data/src|x"` on Linux (bind backend) writes `pipe|path|/data/src|x|<ts>|<ts>|bind`. Field 3 reads back as `/data/src`: `sync` says "source /data/src is live", and a launch with `REPOS=pipe:rw` binds `/data/src`, a different directory, writable, if it exists. A path with a newline splits the record.
- **Repro:** `mkdir -p "$T/src|x" "$T/src"; bash WT/repo.sh add pipe "$T/src|x"` prints "will bind-mount …/src|x"; `bash WT/repo.sh sync pipe` prints "source …/src is live".
- **Expected:** `add` refuses a source the registry cannot hold, as `reindex` skips one.
- **Suggested fix:** in `cmd_add()`, after the path is resolved: refuse a `source` matching `*[$'|\n\r']*` with the message `cmd_reindex()` prints.
- **Fix:** `cmd_add()` refuses a source holding `|`, a newline or a CR, after a path is resolved and before anything is registered or made, as `cmd_reindex()` leaves such a volume out.
- **Tests:** in `tests/test-repo-destructive.sh`, a directory named `pipe|src` and a URL holding `|`: refused, nothing registered, no `volume create`. Seen red with the check removed.

### REPO-27: a first clone that fails leaves an empty, labelled base volume that neither `sync` nor `reset` can mend
- **Status: FIXED** (2026-11-17, WSL native agent). Was: OPEN (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED (from the code)
- **Location:** `repo.sh`: `cmd_add()`, `sync_one()` and `reset_one()` (`repo_base_volume_create …` then `seed_from_git …` under `set -e`)
- **Introduced:** before the window
- **What happens:** `repo_base_volume_create "$name" "$type" "$source"` runs, then `seed_from_git "$vol" "$source"`; a clone that fails (no network, a wrong key) ends the script by `set -e` with the empty volume in place. After `add`, the next `add` refuses ("already exists but … is not registered"), which at least names `docker volume rm`. After a re-seed from `sync` or `reset` (registered repo, volume missing), the volume now exists, so every later `sync` runs the helper, which dies "not a git repository: /dst (.git is missing…)", and `reset` reports "no branch to reset onto (detached HEAD, no usable remote) — left untouched": the only way out is `rm` and `add`, which nothing says.
- **Repro:** the three call sites quoted above; no cleanup or trap follows any of them.
- **Expected:** a seed that fails removes the volume it just made (it is empty), so the next run seeds again.
- **Suggested fix:** `seed_from_git … || { docker volume rm "$vol" >/dev/null 2>&1; exit 1; }` at the three sites (and the same for `seed_from_path`).
- **Fix:** `seed_new_volume()` makes the base volume and seeds it; a seed that fails removes the volume it just made (or names the `docker volume rm` when that fails too) and returns non-zero. `cmd_add()`, `sync_one()` and `reset_one()` all go through it.
- **Tests:** in `tests/test-repo-destructive.sh`, a fake `docker` whose clone fails: `add` leaves no volume and no registry line, and a `sync` or `reset` that re-seeds a missing base volume leaves none either. Seen red with the removal skipped.


---

## 5. Container-start runtime and the capture daemons

### RT-13: the blocked-traffic daemon, as root, appends to files in a directory the agent owns, so a symlink there writes the firewall's allowlist
- **Status: OPEN** (filed 2026-11-17).
- **Severity:** HIGH
- **Confidence:** CONFIRMED (the write through the link and the refresh picking it up, with the suite's fakes; that the daemon is root and the directory is the agent's is from `entrypoint.sh` and the mount layout)
- **Location:** `capture-blocked-traffic.sh`: `log_blocked()` (`printf '%s\n' "$dst_ip" >> "$blocked_ips"`), and `init_output_files()`, which takes a link for the file (`[[ ! -f "$blocked_ips" ]]`)
- **Introduced:** before the window
- **What happens:** `entrypoint.sh` starts `capture-blocked-traffic.sh "$blocked_capture_dir" &` as root, before the capability drop, and it runs for the whole session. Its outputs are in `/workspace/.agent-blocked`, a host bind the agent owns and can write. The agent replaces `blocked-ips.txt` with a link to `/tmp/allowlist-cidrs.txt` (root-owned, but the link is in the agent's own directory, so `fs.protected_symlinks` does not apply), then connects once to any address with no DNS name behind it. Root appends that bare address to the allowlist, and the refresh loop (`while sleep 60`) loads it into `allowed_ipv4` within a minute. A bare IPv4 address is a valid line of that file, so the refresh does not fail. The same works with `blocked-domains.txt` linked to `/tmp/allowlist-domains.txt` for a name. The firewall is lifted for every destination the agent picks, permanently for the container, with self-healing on or off.
  The same pattern gives root an append of partly agent-chosen text to any file of the container (`blocked.log`), and a truncate at the next start (`2>"$capture_dir/tshark-dns-errors.log"`, `tshark-nflog-errors.log`): the directory persists on the host between launches. Not reproduced, but worth weighing when fixing: `blocked.log` linked to `/etc/ld.so.preload` puts a line holding a DNS name the agent chose (see RT-14) where every later root process, the refresh loop's included, reads it.
- **Repro:** hermetic, in an empty directory `$R` (fake `tshark` prints `$FAKE_SCN/dns` for `-i any` and, after `sleep 1`, `$FAKE_SCN/nflog` for `-i nflog:*`; fake `ipset` logs its arguments; fake `getent` exits 0):
  ```
  printf '# cidrs\n10.0.0.0/8\n' > $R/allowlist-cidrs.txt; printf 'github.com\n' > $R/allowlist-domains.txt
  mkdir -p $R/cap $R/int $R/scn; ln -s $R/allowlist-cidrs.txt $R/cap/blocked-ips.txt
  printf '203.0.113.7||443|\n' > $R/scn/nflog
  PATH="$R/bin:$PATH" FAKE_SCN=$R/scn BLOCKED_INTERNAL_DIR=$R/int ALLOWLIST_DOMAINS_FILE=$R/allowlist-domains.txt \
    bash WT/capture-blocked-traffic.sh $R/cap; sleep 3
  cat $R/allowlist-cidrs.txt        # ... 10.0.0.0/8, then 203.0.113.7
  PATH="$R/bin:$PATH" bash WT/refresh-ipset-allowlist.sh $R/allowlist-domains.txt $R/allowlist-cidrs.txt
  # ipset log: add allowed_ipv4_tmp 203.0.113.7 -exist
  ```
- **Expected:** nothing root writes can be redirected by the agent. The allowlist the refresh loop reloads holds only what the image baked.
- **Suggested fix:** keep everything the daemon writes in the root-only `$internal_dir` and publish to the capture directory without following links: write as the sandbox user (`setpriv`/`runuser` for the append), or create a fresh file and `rename` it over the name. Also have the refresh loop read a copy of the allowlists made at start in a root-only directory, so no later write to `/tmp/allowlist-*.txt` can matter. Add a case to `tests/test-blocked-capture.sh` with each output a link.

### RT-14: self-healing trusts any DNS answer seen on the wire, so the agent can have any address allowed; docs/security.md says it cannot
- **Status: OPEN** (filed 2026-11-17).
- **Severity:** HIGH
- **Confidence:** CONFIRMED for the decision (reproduced with the suite's fake `tshark`) and for the firewall rule that lets the answer in (quoted). PLAUSIBLE for the variant that needs no server at all: confirming it takes a real `tshark` in a container.
- **Location:** `capture-blocked-traffic.sh`: `start_dns_map_builder()` (`-f "port 53"` with `-Y "dns.flags.response == 1 and (dns.a or dns.aaaa)"`) and `log_blocked()`; `entrypoint.sh`: `iptables -A OUTPUT -p udp --dport 53 -j ACCEPT`
- **Introduced:** before the window
- **What happens:** the DNS map records `<address> <name>` for every DNS response on any interface, whoever sent it and whichever resolver it came from. The firewall allows port 53 to every destination. So the agent asks a DNS server it or anyone controls for an allowlisted name (`dig @ns.attacker.example github.com`), gets `A 6.6.6.6`, the map holds `6.6.6.6 github.com`, the agent connects to 6.6.6.6, the packet is dropped once, `is_allowlisted_domain` matches and `auto_allow_ip` adds 6.6.6.6 to the live set. Repeat per address; an entry lasts until the next refresh swaps the set, and is re-added the same way.
  No raw socket is needed, so dropping `CAP_NET_RAW` does not prevent it. Probably no server is needed either: the capture filter does not look at direction, so an ordinary UDP datagram sent to any address on port 53, with the response bit set and an answer record in it, is itself "a DNS response" to the filter.
  docs/security.md, item 5, promises the opposite: "This cannot be exploited by the sandbox user: … `CAP_NET_RAW` is dropped so DNS responses cannot be spoofed."
  A side effect in the same function: `grep -qxF "$domain" "$allowed_domains_cache"` has no `--`, and a DNS name may start with `-`. A name `-v` makes that grep read the loop's stdin (the NFLOG feed) and return 0.
- **Repro:** the same harness as RT-13, with `printf 'github.com|6.6.6.6|\n' > $R/scn/dns` and `printf '6.6.6.6||443|\n' > $R/scn/nflog`: the ipset log shows `add allowed_ipv4 6.6.6.6 -exist` and `blocked.log` shows `6.6.6.6 … github.com (auto-allowed)`.
- **Expected:** an address is self-healed only when a resolver the container itself trusts gave it for that name.
- **Suggested fix:** on a block, have root resolve the candidate name itself (`getent ahosts`, as the refresh does) and add the address only if it is among the answers; or build the map only from responses whose source is a nameserver in `/etc/resolv.conf` and whose destination is not port 53. Pass `--` to every `grep` that takes a sniffed name. Correct docs/security.md either way.

### RT-15: a `tcpdump.pid` the agent leaves behind makes the next discovery launch record nothing, under a banner saying everything is captured
- **Status: OPEN** (filed 2026-11-17).
- **Severity:** LOW (the agent can also swap the pcap during a session, since it owns the directory; this one silently disables a later session's capture)
- **Confidence:** CONFIRMED
- **Location:** `capture-agent-destinations.sh`: `tcpdump_running()` and `start_capture()`
- **Introduced:** before the window
- **What happens:** `.agent-discovery` persists on the host and the agent can write it. `start_capture` runs as root, finds `tcpdump.pid`, and `kill -0 "$(cat "$pid_file")"` succeeds for any live pid; root can signal pid 1, which always exists. It prints `Capture already running with PID 1` and exits 0 without starting `tcpdump`. `apply_discovery_firewall()` then prints "Discovery capture started in …" and the entrypoint's banner says "ALL traffic is being captured to a pcap". The same function writes `tcpdump.log`, `tcpdump.pid` and the pcap as root through any link planted at those names.
- **Repro:** with a fake `tcpdump` first on `PATH` that records that it ran:
  ```
  mkdir -p $R/cap; echo $$ > $R/cap/tcpdump.pid
  bash WT/capture-agent-destinations.sh start $R/cap   # "Capture already running with PID <pid>", rc=0, tcpdump never ran
  ```
  (`$$` stands in for pid 1, which only root may signal.)
- **Expected:** a container that has just started has no capture running: `start` removes a pid file it finds, or checks that the pid is a `tcpdump` it started, and refuses a link at any of the three names.
- **Suggested fix:** in `start`, ignore a pid file unless `/proc/<pid>/comm` is `tcpdump`, or have the entrypoint remove `tcpdump.pid` before the call; keep the pid file in a root-only directory under `/run`.

### RT-16: extract-discovery.sh prints a file the agent chose to the host terminal, unrendered
- **Status: OPEN** (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED (with a fake `docker`; that the in-container write through the link fails is from the code: `sort -u > "$dns_out" || true`)
- **Location:** `extract-discovery.sh`: `printf '  %s\n' "${uncovered[@]}"`, fed by `awk … "$dns_out" "$sni_out"`
- **Introduced:** before the window
- **What happens:** the agent leaves `agent-dns.txt` in `.agent-discovery` as a link to an absolute host path that does not exist in the extract container (a file it wrote in the project; host paths are in the container's `/proc/self/mountinfo` and in `HOST_WORKSPACE_DIR`). In the container the redirect through the link fails and `|| true` hides it. On the host the script then reads the link's target and prints each "hostname" under "Not covered by this image": only whitespace is removed and letters lower-cased, so escape sequences (window title, clear screen, OSC 52) reach the terminal, and the lines are offered as names to add to the allowlist. A link to any host file the user can read is printed the same way.
- **Repro:**
  ```
  mkdir -p $R/proj/.agent-discovery; : > $R/proj/.agent-discovery/agent-traffic.pcap
  printf 'evil\033]0;OWNED\007\033[2Jhost.example\n' > $R/proj/payload.txt
  ln -s $R/proj/payload.txt $R/proj/.agent-discovery/agent-dns.txt
  # fake docker: `image` and `run` exit 0; `run … /bin/cat` prints github.com
  HOME=$R/home PATH="$R/bin:$PATH" IMAGE_NAME=x bash WT/extract-discovery.sh $R/proj/.agent-discovery | cat -v
  #   evil^[]0;owned^G^[[2jhost.example
  ```
- **Expected:** the lists are read only if they are regular files the extract just wrote, and every name is rendered for the terminal as the launcher's `_q()` does (LNCH-3).
- **Suggested fix:** remove `agent-dns.txt` and `agent-sni.txt` (links included) before the extract and refuse them afterwards unless `-f` and not `-L`; print only names matching a hostname pattern, or through the same quoting helper the launcher uses.

### RT-17: the tool and Ruby reconciles wait for the group lock with no bound, so one container can hang every later start of the group
- **Status: OPEN** (filed 2026-11-17).
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `agent-tools-reconcile.sh`: `flock 9`; `rvm-reconcile.sh`: `flock 9`
- **Introduced:** before the window
- **What happens:** both take an exclusive lock on a file in the group-shared, agent-writable home (`~/.ai-tools/.reconcile.lock`, `~/.rvm/.reconcile.lock`) and, when it is held, wait forever. An agent in one container that runs `flock ~/.ai-tools/.reconcile.lock sleep infinity`, or any process an installer leaves running with fd 9 inherited (the installers are started with it open; `install-agent-skills.sh` closes it with `9>&-`, these two do not), stops every other container of the group at "another container in this group is installing tools — waiting…", before the shell. The entrypoint's `|| true` covers a failure, not a hang. `install-agent-skills.sh: take_lock()` already bounds the same wait at 60 s "so it can never hold up a start".
- **Repro:**
  ```
  mkdir -p $R/home/.ai-tools; ( flock 9; sleep 8 ) 9>$R/home/.ai-tools/.reconcile.lock &
  HOME=$R/home AI_RUNTIME_TOOLS=nosuch timeout 4 bash WT/agent-tools-reconcile.sh; echo $?   # waiting…, 124
  ```
- **Expected:** a bounded wait that is long enough for a real install (a first Ruby compile takes minutes), then a message and a start without the reconcile; children do not inherit the lock.
- **Suggested fix:** `flock -w <limit>` with a `NOTE:` and `exit 0` past it, and run the installers with `9>&-`.


---

## 6. Test harness and CI

### TST-38: `verify-on-host.sh` prints `RESULT: PASSED` and exits 0 for a `PHASES` value that selects no phase
- **Status: FIXED** (2026-11-17, review agent). `verify-on-host.sh` reads the words `PHASES` names, whatever whitespace separates them and never as a glob, rejoins them for `want_phase()`, and records a failure when there is none. `PHASES=0`, the banner alone, is documented in the script and still passes. The review of the fix found that a newline or a tab between phases passed the check and then ran no phase but 0. `tests/test-verify-exit-code.sh`: `PHASES=" "` fails naming why, `PHASES=0` passes, phases separated by a newline or a tab both run (both made to fail), and `[5]` beside a file named 5 is refused as written; seen failing first.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `verify-on-host.sh`: `PHASES="${PHASES:-4 5 6 7}"` and `for _requested_phase in $PHASES; do`
- **Introduced:** before the window
- **What happens:** a `PHASES` that is only whitespace (`PHASES="$UNSET "`, a trailing-space slip) or only `0` passes the unknown-phase loop, because that loop only looks at the words it finds. No `want_phase` matches, nothing records a `phase_fail`, and the script reports success having run no check.
- **Repro:** from WT, `PHASES=" " bash ./verify-on-host.sh; echo $?` prints `RESULT: PASSED — phases [ ]` and `0`. `PHASES="0"` prints `RESULT: PASSED — phases [0]` and `0`.
- **Expected:** AGENTS.md, "Run everything a host can": a `PHASES` value that "silently verifies nothing" is what `tests/test-verify-exit-code.sh` guards. A selection that runs no real phase should fail, as an unknown phase number does.
- **Suggested fix:** after the validation loop, count the requested phases that are in `4 5 6 7`; when the count is zero, `phase_fail` with "PHASES selects no phase". Add the two values to `tests/test-verify-exit-code.sh`.

### TST-39: `update-nvm-version.yml` pastes the upstream release tag into a shell script and a `sed` program, unchecked, in a job with `contents: write`
- **Status: FIXED** (2026-11-17, review agent). `.github/workflows/update-nvm-version.yml`: the fetch step refuses a tag that is not `vX.Y.Z`, and the update step takes both tags through `env:`, checking the shape again. `tests/test-nvm-update-workflow.sh` runs both steps' own scripts with a fake `curl`: a tag holding a command substitution, or an `&` that sed would take for the matched text, is refused, nothing runs and nothing changes; the update step runs with the environment its own `env:` mapping gives, rendered, which must name both tags, and runs once more with the Dockerfile's own version, which must change nothing, so a mapping that swapped or lost either tag fails. Each was seen failing against its mutant (the review of the fix found that the test set the names itself, and that a slash was refused by sed with no check at all).
- **Severity:** LOW
- **Confidence:** CONFIRMED (from the code; not run)
- **Location:** `.github/workflows/update-nvm-version.yml`: `latest="${{ steps.latest.outputs.tag }}"` and `sed -i "s/^ARG NVM_VERSION=.*/ARG NVM_VERSION=${latest}/" Dockerfile`
- **Introduced:** before the window
- **What happens:** `tag` is whatever `tag_name` the GitHub API returns for nvm-sh/nvm's latest release; only empty and `null` are refused. GitHub substitutes `${{ … }}` into the script text before bash parses it, so a tag holding `"` or `$(…)` runs as code on the runner, with a token that can write contents and pull requests. A tag holding `/` or `&` corrupts the `sed` replacement instead. The same value goes into the branch name, the commit message and the PR title. It needs a hostile or mistaken tag upstream, hence LOW.
- **Repro:** the two lines quoted above, with the `Get latest nvm release tag` step, whose only checks are `-z "$tag"` and `== "null"`.
- **Expected:** the tag is data: checked against the shape nvm uses before anything consumes it, and handed to the script through `env:`.
- **Suggested fix:** in the `latest` step refuse a tag that does not match `^v[0-9]+\.[0-9]+\.[0-9]+$`; pass both outputs to the update step as `env:` variables instead of `${{ }}` inside `run:`. Pin the rule in `tests/test-nvm-update-workflow.sh`.

### TST-40: `tests/run-all.sh` runs no test when the checkout's path holds whitespace
- **Status: FIXED** (2026-11-17, review agent). `tests/run-all.sh` keeps the selection by name and runs each test as `"$tests_dir/$name"`. `tests/test-run-all.sh`: two tests under `sp ace/tests/` run, in `RA_ORDER`'s order; seen failing first.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `tests/run-all.sh`: `selected="${selected:+$selected }$t"` and `for t in $selected; do`
- **Introduced:** before the window
- **What happens:** the selected tests are kept as one space-separated string of absolute paths and split again by word. Under a directory such as `~/my projects/ai-containers` every path splits in two, each half is run as a script, and every one exits 127. The run is red, so nothing passes falsely, but the suite, both `verify-on-host.sh` suite runs and every falsify oracle are unusable there, and the output names neither the cause nor the path.
- **Repro:** `mkdir -p "$TMPDIR/sp ace/tests"; cp tests/run-all.sh "$TMPDIR/sp ace/tests/"; printf 'echo "PASS: x"\n' > "$TMPDIR/sp ace/tests/test-a.sh"; bash "$TMPDIR/sp ace/tests/run-all.sh"` prints `── sp`, `FAIL (exit 127)`, `── test-a.sh`, `FAIL (exit 127)`, `2 test(s), 0 passed, 2 failed`.
- **Expected:** the one test runs and passes; the launcher itself goes to great lengths to carry such paths.
- **Suggested fix:** keep the selection as basenames (the tests all live in `$tests_dir`, and `RA_ORDER`, the clocks and the "not run" list already work by basename) and run `"$tests_dir/$name"`; or refuse a `tests_dir` with whitespace in one line that says so.


---

## 7. Documentation vs code

### DOC-14: troubleshooting.md still says Codex cannot update itself and is reinstalled at every start
- **Status: FIXED** (2026-11-17, review agent). docs/troubleshooting.md names Codex with Claude Code and Copilot as never printing it, Gemini as the one the reconcile reinstalls, and what a Codex that prints it means.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `docs/troubleshooting.md`: `**Codex** does hit it, and **Gemini** has no updater at all, which is why the reconcile re-installs either one at container start`
- **Introduced:** text from `2354abc` (before the window); made false by `aba7f0b` (feat(agent-tools): Codex installs standalone and updates itself (GAP-7)), which updated docs/agent-tools.md and AGENTS.md but not this line. The line was edited in the window (the Claude sentence) and the Codex half was left.
- **What happens:** a user whose Codex prints an update error reads that this is expected, that the reconcile reinstalls Codex at each start, and that `npm-agent-tools update -g` is the manual way. At 104fcc8 Codex is a standalone install, install-if-missing (agent-tools-reconcile.sh: `install_codex_standalone()`), and updates with `codex update`; `npm-agent-tools update -g` would at most update a leftover npm copy that `link-agent-tools.sh` no longer links. The same page contradicts docs/agent-tools.md ("Codex CLI | **yes** — standalone installer") and AGENTS.md's table.
- **Repro:** `grep -n 'Codex\*\* does hit it' docs/troubleshooting.md`; `grep -n 'codex)' agent-tools-reconcile.sh` prints `codex)       install_codex_standalone ;;`.
- **Expected:** Codex named with Claude Code and Copilot as never printing this; only Gemini reinstalled by the reconcile; a Codex that prints it is the leftover npm copy (standalone install failed), with the pointer to docs/agent-tools.md.
- **Suggested fix:** rewrite the sentence; "re-installs either one" becomes Gemini only.

### DOC-15: the Unreleased CHANGELOG says `repo.sh gc` does not read the owner label, and 160 lines later that it does
- **Status: FIXED** (2026-11-17, review agent). The Added entry's false sentence is gone.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `CHANGELOG.md`: `` `repo.sh gc` and `repo.sh list --copies` do not read the label yet. `` (Unreleased, Added) against `**\`repo.sh gc\` keeps another home's working copies.**` (Unreleased, Fixed)
- **Introduced:** `37fd86b` wrote the first; `7733768` (fix(repo,project): repo.sh gc keeps another home's working copies) made it false the same day and did not remove it.
- **What happens:** the release notes will publish both. The Added entry is the wrong one: repo.sh: `wc_owner()` is read by `gc` (kept "unless given --all") and by `list --copies`. A reader of the first entry expects `repo.sh gc` to remove every copy, another distro's included.
- **Repro:** `grep -n 'do not read the label yet\|keeps another home' CHANGELOG.md`; `grep -n 'wc_owner' repo.sh`.
- **Expected:** one statement, the true one.
- **Suggested fix:** delete the last sentence of the Added entry (the design spec's copy of it is a dated record and can stay, or take a "since built" note).

### DOC-16: the group-mount table in docs/repos-and-mounts.md leaves out five mounts the launcher makes
- **Status: FIXED** (2026-11-17, review agent). docs/repos-and-mounts.md's table has the five rows, and acli is in the footnote, docs/overview.md and AGENTS.md's list.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `docs/repos-and-mounts.md`: `| Host source (within group root) | Container path | Mode | Component |` and footnote `currently \`dtctl\`, \`dtmgd\``
- **Introduced:** before the window (each mount was added without its row); the table was edited in the window (the `.rvm` row, the closing sentence).
- **What happens:** the table is presented as what a container gets from the group. Missing, though the launcher makes each of them: `<group>/.local/share/claude` and `<group>/.local/state/claude` (`claude-code`; sandbox.sh: `"$group_root/.local/share/claude" "$group_root/.local/state/claude"`), `<group>/.cache/qmd` (`qmd`), `<group>/.cache/ms-playwright` (`playwright`), and `<group>/.config/acli` (tools.d/acli.conf: `config_dir=.config/acli`, which holds acli's credentials). Footnote 2, docs/overview.md ("currently Dynatrace's `dtctl` and `dtmgd`") and AGENTS.md's Conditional-installs section (`tools.d/`-described tools (`dtctl`, `dtmgd`)) also omit acli, which AGENTS.md lists elsewhere. docs/groups.md does name the caches, so the two user pages disagree.
- **Repro:** `grep -n 'share/claude\|cache/qmd\|ms-playwright\|config/acli' docs/repos-and-mounts.md` prints only footnote 3's mention; `grep -n 'cache/qmd\|local/state/claude' sandbox.sh`.
- **Expected:** one row per mount, and acli in the footnote.
- **Suggested fix:** add the five rows; say "currently `dtctl`, `dtmgd`, `acli`".

### DOC-17: two counts in AGENTS.md no longer match the code
- **Status: FIXED** (2026-11-17, review agent). AGENTS.md drops the counts of the scripts that source bash-floor.sh, and names the five that source version.sh.
- **Severity:** LOW
- **Confidence:** CONFIRMED
- **Location:** `AGENTS.md`: `nine other entry points that don't need the rest of \`sandbox-common.sh\` source it directly` (and "the same reasoning that has nine entry points sourcing `bash-floor.sh` directly"); `AGENTS.md`: `` `version.sh` is sourced by `sandbox.sh`, `project-init.sh` and `sync-to-projects.sh` **directly** ``
- **Introduced:** in the window for the growth (`multiline-env.sh`, `project.sh`); the sentences predate it.
- **What happens:** twelve scripts besides sandbox-common.sh source bash-floor.sh (ai-containers-report, project-init, release-title, bump-sandbox-version, changelog-coverage, verify-on-host, capture-on-host, changelog-section, check-sandbox-version, migrate-runme, multiline-env, sync-to-projects). version.sh is sourced by five: the three named, `ai-containers-report.sh` (which AGENTS.md says elsewhere) and `project.sh`. Unchecked prose: test-code-references.sh reads only backticked snippets.
- **Repro:** `grep -lE '^\s*(source|\.) .*bash-floor\.sh' *.sh`; `grep -lE '^\s*(source|\.) .*version\.sh"?$' *.sh`.
- **Expected:** no number, or the right one.
- **Suggested fix:** drop the counts ("the entry points that don't need the rest…"), and add project.sh and the report to the version.sh sentence.


---

## 8. What each reviewer covered

Each reviewer's own account of what it read, what it ran, what it checked and found sound, and what it could not cover. A "suspicion not filed" here is a lead, not a finding.

### GIT

Files read: `sandbox.sh` (the git half of `launcher_ro_overlay()` up to the include walk, `git_dirs_in()` and the `_gdi_*` helpers, `_is_git_dir()`, `_git_dir_nocd()`, `_cd_*`, `_git_cd_check()`, `_gd_resolve()`, `_git_index_read()`, the bounded reads, `_path_parts()`, `_gdi_blocked()`, `_gdi_follow()`, `_git_usable()`, `_git_kv()`, `_git_prog()`, `_git_exec_keys()`, `_git_file_config()`, `_git_walk_keys()`, the reports, `_git_runs()`, `_git_after_session()`, `_ro_fifo_search()`, `_fs_*`, `_ro_files_snapshot()`, `_ro_files_restore()`), `tests/lib-git-internals-ro.sh`, AGENTS.md's "git internals" bullet, and the bugs review for the IDs named below.

What I could not cover, and why: the hooks half of the post-pass (`_git_push_hooks()`, the `core.hooksPath` and hook-link judging after the include walk) and `_walk_exposed()` were only skimmed; the case-folding code (`_ci_*`, `_disk_spell()`, `_win_*`) and `_ro_files_snapshot()`/`_ro_files_restore()` were read but not run (they need macOS, Colima or drvfs). The seven `tests/test-git-internals-ro-*.sh` files were not read for assertions that cannot fail. Every repro below ran through `tests/lib-git-internals-ro.sh` (fake `docker`, `HOME` and `TMPDIR` in the area directory), git 2.x on Linux.

#### Checked and found sound (no finding)

- `set -e`/`pipefail`: the `A && B` lines in loops and function tails in scope, `_rd_run()`/`_rd_fail()` (`local -; set +e`), `_git_ptr_read()` and `_cd_ours()` under process substitution; launches with repository names holding a newline, tab, CR, glob characters, a leading `-`, `:`, quotes, a backslash and bytes that are not UTF-8, with linked worktrees among them, under `LC_ALL=C` and `C.UTF-8`: rc 0, no shell error, each reported once in `git-reported.conf`.
- `commondir`, `.git` file and `gitdir` reads against git's own reading (trailing CR/LF, NUL, empty file, unreadable file): each mismatch fails closed.
- A bare repository made of the mount root itself with the protected `.git`'s `HEAD` moved aside: named by `_git_after_session()`, then protected and named by the next launch.
- An `include.path` written `~user/…`: judged as a relative path, which still warns for a protected repository (the path under `.git` is one the agent could make); not filed.
- `_git_exec_keys()`'s key list against git's own keys that run programs: complete as far as I could tell (the lfs keys aside).

### LNCH

Files read: `sandbox.sh` (the start of the file to the end of the launcher half of
`launcher_ro_overlay()`; the launcher-link pass, the case/Windows refusal and the end of
`launcher_ro_overlay()`; `_walk_exposed()` to `launcher_dirs_in()`; `_cd_phys()` to
`_lex_link_dir()`; `seed_workcopy_volume()` to the end of the file), `sandbox-common.sh`
(`resolve_path()`, `_bind_mount_arg()`, `_mount_representable()`, `_utf8_valid()`,
`docker_bind()`, `_copy_dereferenced()`), `entrypoint.sh` (`stash_app_env()`,
`verify_launcher_mounts()`, `refuse_root_identity()`), the head of
`tests/test-launcher-dir-ro.sh` and `tests/test-host-binds.sh`.

Reproduced hermetically (a copy of the launcher under a private `HOME`, a fake `docker`
first on `PATH`, as `tests/test-launcher-dir-ro.sh` does). The repro trees are deleted.

What I could not cover, and why:
- Nothing was run on macOS, on Colima or on a real drvfs mount. LNCH-30 was shown with
  `_win_fs()` overridden for one directory; LNCH-32 with a fake `colima` that runs the
  VM's program locally under GNU xargs 4.10.
- The git-internals half of `launcher_ro_overlay()`, `_fs_*`, `_ro_fifo_search()` and
  `git_dirs_in()` were out of scope and read only where the launcher half calls them.
- `_agent_bits_writable()`'s ACL branch (`getfacl`, uutils `ls`) and the `_ci_*` /
  `_ds_readdir()` spelling code were read, not exercised: no case-insensitive filesystem here.
- The test files `tests/test-env-file.sh`, `tests/test-docs-path.sh`, `tests/test-repos-path.sh` and
  `tests/test-launcher-verify.sh` were not read in full; I checked only that none covers the
  findings below.

Checked and found sound (no finding): `container_env_filter()` against the entrypoint's
`stash_app_env()` (reserved names, launcher `-e` names, bare names, `AI_CONTAINER_ENV_KEYS`
always passed with `-e` when any line passes); `_bind_mount_arg()` / `_bind_read()` round
trip for names holding `:`, `,`, `"`, spaces and newlines; `_term()` in `C` and `C.UTF-8`;
LNCH-26's judgement for trailing slashes, `//`, `./`, relative paths, `..` steps and
links; LNCH-27's held-parent read for the same spellings and for a launch through a link;
launcher names holding `]`, `*`, `@`, `"`, a newline, a leading `-` (no crash, no
expansion); `set -e` in the `&&` lists of `run_container()`; `refuse_root_identity()`.


### PRJ

Files read: `project.sh` (whole), `project-files.sh` (whole), `sync-to-projects.sh`, `project-init.sh`, `multiline-env.sh`, `migrate-runme.sh`, `ai-containers-report.sh`, `group.sh`, `shared-files.sh`, `launcher-templates/4.tmpl`; in `sandbox-common.sh`: `load_env_defaults()`, the `env_key_*` lists, `ai_containers_project_id()`, `ai_containers_owner_id()`, the volume-label table and `_ac_term()`; in `repo.sh` / `repo-git-reset.sh` only what `prj_copy_risk()` calls (`git_helper_run()`, `cmd_inspect`). Specs: the AGENTS.md sections named in the task, `docs/multiple-projects.md` (the project.sh part), the design `docs/superpowers/specs/2026-11-14-project-tool-design.md`.

Reproductions used the scaffold of `tests/test-project-tool.sh` (its lines from `unset VAULT_PATH` to `P="$ENG/project.sh"`: an engine copy, a HOME and the fake `docker` in a temp dir) plus its `mkproj`/`mkbase`/`mkwc`/`wcdata` helpers; "harness" below means that. `tests/test-project-tool.sh` itself passes here (316 PASS, 65 s).

What I could not cover, and why: `docs/groups.md` and the plan `2026-11-14-project-tool.md` were not read line by line; the tests other than `tests/test-project-tool.sh` were not audited for assertions that cannot fail (time); nothing was run on macOS or against a real daemon, so `_proj_fd_is()`'s fdescfs branch, BSD `mv`, and what `docker inspect` reports for a bind mount's source on Docker Desktop are unverified (see PRJ-17).


### REPO

Files read: `repo.sh`, `repo-git-reset.sh`, `sandbox-common.sh` (all of it; the project-id helpers only read, not reviewed), `build.sh`, `version.sh`, `Dockerfile.seed`, `install-node-lts.sh`, `tools-lib.sh`, `host-preflight.sh`, `bash-floor.sh`, the launcher template `launcher-templates/4.tmpl`; the diffs since `bec1c57` of `Dockerfile`, `install-tools.sh`, `allowlist-cidrs.d/`, `allowlist-domains.d/`; `docs/repos-and-mounts.md`; the AGENTS.md sections named in the task; the three review logs for every finding below.

What I could not cover, and why:
- `Dockerfile` and `install-tools.sh` outside their diffs since `bec1c57` (time; no build may be run).
- The addresses in `allowlist-cidrs.d/base.txt` and `github-copilot.txt` were checked for syntax and duplicates only, not against `api.github.com/meta`.
- Nothing was run in the seed image (Alpine, musl, git 2.4x): every repro ran `repo-git-reset.sh` directly with the host's git 2.53, as `tests/test-repo-git-reset.sh` does, and `repo.sh` against a fake `docker`.
- macOS and Colima paths of `sandbox-common.sh` (`resolve_path`, `_utf8_valid`) were read, not run.
- The tests named in the task were read for what they cover, not mutated.

Every repro below ran under `TMPDIR=<review-tmp>/REPO`, `HOME=<that>/home`, `GIT_CONFIG_GLOBAL` an empty file and `GIT_CONFIG_SYSTEM=/dev/null`; `$H` is the review worktree's `repo-git-reset.sh`, `$T` the temp dir. All of it is removed.


### RT

Files read: `entrypoint.sh`, `agent-tools-reconcile.sh`, `link-agent-tools.sh`, `link-default-ruby.sh`, `install-agent-skills.sh`, `rvm-reconcile.sh`, `start-services.sh`, `services.d/{postgres,mysql,mariadb,mongo,redis}.sh`, `refresh-ipset-allowlist.sh`, `capture-blocked-traffic.sh`, `capture-agent-destinations.sh`, `extract-discovery.sh`, the Dockerfile lines that copy and configure them (the `ENV PATH` lines, `/etc/profile.d/ai-tools.sh`, the `COPY allowlist-*.txt /tmp/` block), `docs/security.md`'s security model, and the RT/SVC entries of the bugs review.

What I could not cover, and why:
- `link-node-globals.sh` (build time only) and `tools-lib.sh` were not read line by line.
- Nothing here ran with a real `tshark`, `tcpdump`, `psql`, `mysqld` or root: all repros use fakes, as the suite does. Where a finding depends on what the real program does on the wire, the entry says so.
- The service adapters were read for trust-boundary and `set -e` problems only; their SQL was not exercised. One suspicion not filed for lack of a PostgreSQL to measure with: `pg_ctl -w` (services.d/postgres.sh: `svc_start()`) runs with the app's `PG*` variables, unlike `_pg_sql()`, and a `PGHOSTADDR` or `PGSERVICE` in `container.env` may send its readiness ping elsewhere.

All five bugs are in code the window did not change.


### TST

Files read: `tests/run-all.sh` (whole); `tests/falsify/run.sh` (the verdict
predicates, `falsify_run_oracle()`, `falsify_verdict()`, `fr_run_mutant()`,
`fr_run_control()`, `fr_run_baseline()`, `fr_harvest()`, `fr_load_targets()`,
`fr_apply_deep()`, `fr_cover_target()`, `falsify_main()`);
`tests/falsify/check-ledger.sh` (whole), `deep.conf`;
`tests/test-layer-containment.sh`, `tests/layer-checks.conf`,
`tests/lib-layer-checks.sh` (`wf_it_selections()` only);
`tests/bash-dialect-lint.sh`, `tests/test-code-references.sh`;
`verify-on-host.sh` (whole); every `.github/workflows/*.yml`;
`tests/integration/run.sh` (variants, capabilities, selection), the diff of
`tests/integration/lib.sh`, cases 250, 460, 640, 650, 710;
`tests/lib-git-internals-ro.sh`; samples of `tests/test-git-internals-ro-*.sh`,
`tests/test-launcher-dir-ro.sh`, `tests/test-project-tool.sh`,
`tests/test-repo-git-reset.sh`.

Checks run:
- All 87 patches under `tests/integration/mutations/` pass `git apply --check`.
- `tests/falsify/check-ledger.sh --lint` is clean (88 entries).
- Every packages case has an `image:` that one of nightly's four variant runs names, so no case falls between `--exclude packages` and the `--variant` jobs.
- A script over the sampled test files found one `pass` with no `fail` beside it (`skip_root()`, deliberate).
- An instrumented copy of `tests/test-git-internals-ro-scan.sh` ran about two thirds of the file (to its check G214) before I stopped it. Every launch that exited non-zero in that part was one whose check expects a refusal.
- Check G72 was seen failing under a planted mutant (the launch budget counting empty include entries).

What I could not cover, and why:
- `tests/falsify/generate.sh`, `tests/falsify/derive-targets.sh`, the watchdog and CPU-budget code of `tests/falsify/run.sh`, and most of `tests/lib-layer-checks.sh`: about 5,000 lines, read only where a verdict or selection depends on them.
- `tests/portability.sh`, `tests/integration/minimal-conf.sh`, `tests/integration/docker-shim.sh`, `tests/integration/mutate.sh`: not read.
- The other five git-internals test files, `tests/test-launcher-dir-ro.sh`, `tests/test-project-tool.sh` and `tests/test-repo-git-reset.sh` were sampled by script and by reading about 40 checks, not run. The casefold file needs a case-insensitive `TMPDIR`.
- Nothing that needs a docker daemon, macOS or GitHub itself was run.


### DOC

Files read: the diff `bec1c57..104fcc8` of README.md, docs/*.md, docs/components/*.md and sandbox.conf (every added line); AGENTS.md (whole, as given); CHANGELOG.md Unreleased (Added, Changed, Removed in full; the headlines of Fixed and Security); docs/troubleshooting.md, docs/groups.md, docs/security.md items 6 to 8, docs/repos-and-mounts.md's mount table; docs/superpowers/specs/2026-11-13-agent-git-directory-design.md (first half; status ON HOLD, "nothing here is built"), specs/2026-11-14-project-tool-design.md (whole), plans/2026-11-14-project-tool.md (task list), to-test.md (whole), the diffs of the falsify backlog and the auto-update regression spec; the feature-gaps review's entry list. Code checked against: sandbox.sh, sandbox-common.sh, repo.sh, project.sh, build.sh, Dockerfile (npm layer), agent-tools-reconcile.sh, multiline-env.sh, verify-on-host.sh, tests/integration/run.sh, tests/falsify/run.sh and targets.conf, .github/workflows/hermetic-checks.yml, allowlist fragments.

Checked and found in step with the code: every `./<script>.sh` command and flag the user docs print (repo.sh, group.sh, project.sh, multiline-env.sh, run.sh, falsify run.sh); the env-var table of docs/configuration.md against AGENTS.md's (names and defaults, by script) and the defaults against the code; the portable / machine-only key lists; the `npm=` key (build.sh, Dockerfile); the bootstrap prompt and group-name rule; `repo.sh reset`'s summary strings; every `tests/…` path and integration case the docs name (all exist); the falsify shards against the workflow; launcher template number (4); `PHASES` default and `VALID_PHASES`; Codex/Claude allowlist hosts. `tests/test-code-references.sh` and `tests/test-docs.sh` pass at 104fcc8 (run alone, TMPDIR and HOME in my area dir).

What I could not cover, and why: the ~900 lines of CHANGELOG Fixed/Security were checked by headline only; AGENTS.md's git-internals paragraph (the G-numbered claims) was not checked claim by claim against sandbox.sh, which belongs to the launcher reviewers and would take the whole budget; docs/testing.md's diff was checked only for the falsify shards; project.sh's refusal list in docs/multiple-projects.md was matched to function names, not exercised.

No TODO, FIXME, "follow-up" or "deferred" marker added to code since bec1c57 promises unbuilt work, other than the DEFERRED falsify rows (GAP-28). to-test.md has one open box (the nvm bump PR body, TST-8), which waits on the next automated PR and is stated.


---

## 9. Found while fixing this review's findings

### TST-41: `tests/test-report.sh` fails wherever `TMPDIR` lies under `HOME`
- **Status: FIXED** (2026-11-17, review agent). The check accepts a path cell starting with `/` or `~`.
- **Severity:** LOW (test only)
- **Confidence:** CONFIRMED
- **Location:** `tests/test-report.sh`: the `--markdown backticks the path cell only` check
- **Introduced:** before the window
- **What happens:** the check wants the markdown path cell to start with `` `/ ``, but the report shortens a path under `$HOME` to `~/…` (`ai-containers-report.sh`: `display_path()`). With `TMPDIR` under `HOME` (Claude Code's own scratch directories are; so is any `TMPDIR=~/tmp`), the check fails at `HEAD`, and passes with `TMPDIR=/tmp`. Found running the file for PRJ-15.
- **Repro:** `TMPDIR="$HOME/some-dir" bash tests/test-report.sh` → `FAIL: --markdown backticks the path cell only`.
- **Expected:** the suite passes wherever `TMPDIR` is.
