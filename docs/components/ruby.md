# Ruby (via rvm)

`ruby` accepts a **comma-separated list** of versions, exactly like `node` and
`python` — useful for installing more than one Ruby, e.g. while migrating a
project between versions:

```bash
ruby=3.4.5,3.3.6
```

Leave empty (`ruby=`) to skip Ruby entirely.

**Per-user, group-scoped, installed at runtime.** Nothing Ruby-related is
baked into the image. rvm itself, every version listed in `ruby=`, and all
installed gems live in `~/.rvm`, scoped to the active container **group** —
so state is shared by every project that uses that group and survives
container restarts and rebuilds.

Unlike the agent dotfile dirs, `~/.rvm` is backed by a **Docker named volume**
(`ai-containers-rvm-<group>`, or `$REPO_VOLUME_PREFIX-rvm-<group>` if you set
that), not a host bind mount, on every platform. It has
to be: rvm bootstraps by extracting its release tarball, and GNU tar defers
symlinks whose target contains `..` by first writing a mode-000 placeholder
file — an operation macOS virtiofs (Colima, Docker Desktop) cannot service. tar
fails on exactly the four such members in the rvm tarball and the installer
aborts with `Could not extract RVM sources`, so a bind-mounted `~/.rvm` can
never hold a working rvm on macOS. (Plain symlink creation works there, which
is why `~/.ai-tools` — npm/uv, direct `symlink()` — is unaffected and stays a
bind mount.) Linux uses the volume too: one code path is worth more than
host-inspectability of a tool cache, and a macOS-only branch is exactly the
kind of divergence that let this go unnoticed.

Practical consequences:

- The volume is created on first use. If the group already had a working
  bind-mounted `~/.rvm` (from before this change), it is **migrated into the
  volume once**, so you don't recompile; the old directory is left in place and
  you're told to remove it. A directory holding only the debris of a failed
  bootstrap is ignored and the group starts clean.
- Deleting a group is no longer just `rm -rf` — use
  [`./group.sh rm <group>`](../groups.md), which removes the directory and
  the volume together. `./group.sh gc` cleans up volumes orphaned by a manual
  `rm -rf`.
- `AI_CONTAINER_GROUP=host` keeps the plain bind mount, because that group's
  whole contract is "mount my real `$HOME`". On macOS that means rvm cannot
  bootstrap in the `host` group at all — use a named group for Ruby work.

At container start, an additive reconcile (`rvm-reconcile.sh`, run as the
sandbox user and `flock`-guarded against concurrent same-group container
starts) installs whichever configured versions are missing from the group's
`~/.rvm`:
- **First start after adding a version** — rvm bootstraps (if the group's
  `~/.rvm` is still empty) and then compiles that Ruby from source, the same
  one-time cost a local rvm/asdf install pays; this can take several minutes.
- **Every later start** — the version is already present, so reconcile is a
  no-op and the container starts instantly.

Reconcile is purely additive: nothing already installed is ever removed, and
the first version installed becomes the group's rvm default only if the group
has no default yet — a later container in the same group never re-points an
existing default. If a requested version fails to install (every attempt,
including the `rvm get stable` retry), reconcile logs a clear
`FAILED: ruby-<version>` line and, rather than pointing the default at a
version that isn't there, sets the default to the first version that *did*
install (or none, if all failed).

**Non-interactive Ruby.** After the reconcile, the default Ruby's executables
(`ruby`, `gem`, `bundle`, `bundler`, `rake`, `irb`, `erb`) are symlinked onto
`/usr/local/bin` so they resolve in **non-interactive, non-login** shells too —
e.g. `docker exec -T <container> bash -c "bin/rails runner …"`, which would
otherwise get `command not found` (login and interactive shells pick up rvm via
`/etc/profile.d/rvm.sh` and `/etc/bash.bashrc`). These symlinks expose the
**default** Ruby only; per-project version/gemset selection still comes from a
project's `.ruby-version`/`.ruby-gemset` when a shell sources rvm, so a
non-interactive caller that needs a non-default project gemset should run
through a login shell (`bash -lc "…"`).

Because bootstrapping rvm and compiling Ruby pull from the network,
`restricted` mode allowlists the hosts this needs
(`allowlist-domains.d/rvm.txt`): `cache.ruby-lang.org` (and rvm's fallback
`ftp.ruby-lang.org`) plus `www.ruby-lang.org` for the Ruby source tarball,
alongside the existing RubyGems hosts (`rubygems.org`, `api.rubygems.org`,
`index.rubygems.org`, `rubygems-updates.s3.amazonaws.com`) for
`bundle`/`gem install`.

The bootstrap itself needs two hosts that are easy to miss, because they are
reached by *redirect* and *fallback* rather than by any URL in this repo:
`https://get.rvm.io` is a permanent redirect to
`https://bitbucket.org/mpapis/rvm/raw/master/binscripts/rvm-installer`, so
**`bitbucket.org`** is allowlisted too — `rvm get stable` (reconcile's
install-failure retry) goes through the same redirect; and the installer
resolves the `stable` tag from `api.github.com` with **`api.bitbucket.org`** as
its fallback, which matters because anonymous `api.github.com` is rate-limited
per public IP and every container behind one NAT shares that budget. rvm is
then downloaded from GitHub over hosts `base.txt` already covers
(`github.com`, `codeload.github.com`, `release-assets.githubusercontent.com`)
and its signature verified against the rvm signing keys pre-seeded into
`/etc/skel/.gnupg` at build time.

That seeding covers the usual case but not every case, which is why
`keyserver.ubuntu.com` is allowlisted rather than left out. `entrypoint.sh`
populates a new home with `cp -rn /etc/skel/.` — **no-clobber** — so a group
whose home already carries its own `~/.gnupg` keyring keeps it, and never
receives the rvm keys. The `host` group is the concrete case: its whole contract
is to mount your real `$HOME`, which usually has a keyring already. There the
installer falls back to fetching the keys, and the allowlist entry is what lets
it.

rvm also HEAD-probes all three of its prebuilt-binary mirrors on **every**
`rvm install`, whichever Ruby you asked for, so those are allowlisted too:
`rvm-io.global.ssl.fastly.net`, `rubies.travis-ci.org`, and — surprisingly —
`repo1.maven.org`, which is Maven Central, where JRuby is published. Installing
CRuby 3.4.5 still issues a HEAD for
`repo1.maven.org/maven2/org/jruby/jruby-dist/ruby-3.4.5.tar.bz2`. See
`allowlist-domains.d/rvm.txt`, which keeps the list in sync by rvm's config
field names.

> **The `rails` key has been removed.** Rails is an ordinary per-project gem
> installed with `bundle install`/`gem install`, like any other — it never
> needed its own `sandbox.conf` key or a build-time pairing with a single
> `ruby=` version. A project synced from an older `sandbox.conf` has its
> `rails` line stripped automatically (schema v4,
> `migrations/004-drop-rails.sh`); see
> [sandbox.conf schema versioning](../components/README.md#schema-versioning).

---

[← Components](README.md) · [Documentation index](../README.md)
