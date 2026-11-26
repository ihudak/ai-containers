# macOS re-check after the `/var/tmp` volume (2026-11-26)

**For:** the agent on a Mac, run by the user.

**Why:** on 2026-11-25, Colima failed GNU tar's `..`-link step on the `/var/tmp` and
`~/.cache` host binds (report: `.superpowers/sdd/2026-11-23-persistent-agent-scratch/mac-check-2026-11-25.md`
on the Linux machine).

**What has changed since:** `main` now puts `/var/tmp` on a per-group Docker volume and
the follow-up fixes. Spec: `docs/superpowers/specs/2026-11-25-var-tmp-volume-design.md`.

Every step here was verified on Linux only. A Mac adds BSD userland, virtiofs, Colima and
Docker Desktop.

## Rules

- **Report only.** Do not change, commit to or push ai-containers, and do not fix
  anything you find. Write the report to `~/mac-recheck-2026-11-26.md`, outside the
  repository, and hand it to the user.
- Run every step under **Colima**. If Docker Desktop is installed, run them again under
  it (`docker context use desktop-linux`, then `docker context use colima` to go back).
  Say which runtimes you could not test.
- Use bash 5.1 or later (Homebrew's `bash`), as the repo requires. macOS's
  `/bin/bash` is 3.2.

## Setup

```bash
cd <your ai-containers checkout> && git pull --ff-only   # main, at or after the commit that added this file
./build.sh                                               # the image the steps use; IMAGE_NAME from sandbox.env
```

## A. The change works on a Mac

**A1. Hermetic suite, on BSD userland.**

```bash
PHASES=5 bash ./verify-on-host.sh
```

This runs the host suite, then the floor suite in `ubuntu:22.04`, then the
symlinked-`TMPDIR` arm. Report each arm's `N test(s), N passed, N failed` line and the
name of every failing test. These cover the change most closely:

- `test-agent-tmp.sh`
- `test-vartmp-volume.sh`
- `test-group-lifecycle.sh`
- `test-rvm-volume.sh`
- `test-entrypoint-wiring.sh`
- `test-git-internals-ro-scan.sh` (its G335 check)

**A2. Integration cases.**

```bash
./tests/integration/run.sh --cases 520-agent-files-persist-across-restart,525-old-var-tmp-named-and-copyable,610-group-rm-removes-both,620-group-gc-collects-orphan
```

Report the `selected / passed / failed / skipped` line, and for any failure its `FAIL:`
lines.

**A3. The original failure, in a real launch.** Start `./sandbox.sh open` from a
project, then run this in the agent's shell:

```bash
echo "TMPDIR=$TMPDIR"
for d in "$TMPDIR" "$HOME/.cache"; do
  ( cd "$d" && rm -rf tt && mkdir -p tt/t/a/b && ln -s ../../x tt/t/a/b/l \
    && tar -C tt/t -cf tt/t.tar a && mkdir tt/u && tar -C tt/u -xf tt/t.tar ) \
    && echo "PASS tar $d" || echo "FAIL tar $d"
  rm -rf "$d/tt"
done
```

**Expected:**

- `TMPDIR=/var/tmp/<YYMMDD-HHMMSS-pid>`;
- `PASS tar` for `$TMPDIR`;
- `FAIL tar` for `~/.cache` on Colima: the stated limit that Part B is about.

## B. Should `~/.cache` become a volume too? Measure, do not change

`~/.cache` stays a host bind, by the user's choice, so that caches can be inspected and
cleared from the host. GNU tar's `..`-link placeholder fails there on a Mac.

What is not known is whether anything in everyday use hits that limit, and what the bind
costs in speed. Most tools that write `~/.cache` use their own extractors, which create
symlinks directly, and that works on virtiofs. That claim has not been checked on a Mac.

**B1. Common tools, with `~/.cache` on the bind.** Run each of these in the agent's shell
of an `open` launch, for every tool the image has. Report PASS or FAIL, and for a FAIL the
last lines it printed.

```bash
uv venv /tmp/uvv && uv pip install -p /tmp/uvv requests numpy          # ~/.cache/uv
python3 -m venv /tmp/pv && /tmp/pv/bin/pip install requests numpy       # ~/.cache/pip
corepack enable --install-directory ~/.local/bin && corepack pnpm --version   # ~/.cache/node/corepack
npx -y node-gyp install                                                 # ~/.cache/node-gyp
npx -y playwright install chromium        # only with playwright= on     # ~/.cache/ms-playwright
```

**B2. Speed: the cache on a bind against the cache on a volume.** Run this on the Mac,
outside any launch. Set `IMG` to the image `./build.sh` made.

```bash
IMG=<image>; H="$(mktemp -d "$HOME/.cachebench-XXXX")"; V=cachebench-$$
docker volume create "$V" >/dev/null
docker run --rm --pull=never --entrypoint chown -v "$V:/c" "$IMG" "$(id -u):$(id -g)" /c
for kind in bind volume; do
  if [[ "$kind" == bind ]]; then m=(-v "$H:/tmp/h/.cache"); else m=(-v "$V:/tmp/h/.cache"); fi
  docker run --rm --pull=never --entrypoint bash -u "$(id -u):$(id -g)" -e HOME=/tmp/h "${m[@]}" "$IMG" -c '
    for run in cold warm; do
      s=$EPOCHREALTIME
      python3 -m venv /tmp/v-$run && /tmp/v-$run/bin/pip install -q --cache-dir "$HOME/.cache/pip" requests numpy pandas >/dev/null 2>&1 || echo "pip failed"
      awk -v s="$s" -v e="$EPOCHREALTIME" -v k="'"$kind"'" -v r="$run" "BEGIN { printf \"%s %s %.1fs\n\", k, r, e - s }"
    done'
done
docker volume rm "$V" >/dev/null; rm -rf "$H"
```

Run it twice and report all eight numbers (bind and volume, cold and warm, two runs).

**B3. What the numbers decide.** The decision is the user's. The rule proposed to them:

- **Move `~/.cache` to a per-group volume** if any B1 tool fails on the bind, or if the
  bind's cold or warm install takes 1.5 times the volume's or longer.
- **Otherwise keep the bind**, with the documented limit.

Moving it would mean:

- a third group volume, which `group.sh` manages like the other two;
- migrating existing caches (the Playwright browsers alone are about 0.5 GB);
- a `group.sh` way to clear a group's cache from the host.

## C. Is trimming the launch's docker calls worth it?

Each launch makes three docker calls it did not make before the change: the temp volume's
label, its owner label, and `docker ps` for the folders in use. Time each, per runtime,
using a group that has launched at least once (`ai-containers-vartmp-default` is the
`default` group's temp volume; use your group's name if it is another):

```bash
avg() { local n=20 i s=$EPOCHREALTIME; for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1; done
        awk -v s="$s" -v e="$EPOCHREALTIME" -v n="$n" 'BEGIN { printf "%.0f ms\n", (e - s) * 1000 / n }'; }
avg docker volume inspect --format '{{if .Labels}}{{index .Labels "ai-containers.vartmp-group"}}{{end}}' ai-containers-vartmp-default
avg docker ps --filter label=ai-containers.tmpslot --format '{{.Label "ai-containers.tmpslot"}}'
```

**The rule proposed:** trim the calls only if the three together cost more than 300 ms a
launch on a runtime. The trim would read both labels in one `inspect`, and skip `docker ps`
while the volume holds no folders.

## D. The report

For each runtime tested, give:

- the A1 lines and failing tests;
- the A2 line;
- the A3 lines;
- the B1 PASS or FAIL per tool;
- the B2 numbers;
- the C two averages.

Add the versions: macOS, chip, `docker version --format '{{.Server.Version}}'`,
`colima version`, and Docker Desktop's version if tested.

## After the report (on the Linux machine, not the Mac)

- The user decides B and C.
- The ledger `.superpowers/sdd/2026-11-23-persistent-agent-scratch/` is deleted.
