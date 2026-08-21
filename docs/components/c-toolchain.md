# c-toolchain — a C compiler for cgo and native extensions

```bash
c-toolchain=ON
```

Installs `build-essential` (gcc, make, headers) plus `libyaml-dev`, `zlib1g-dev` and `libssl-dev`, and **keeps them in the finished image**. Off by default, because most projects never need a compiler at runtime and the layer is not small.

## When you need it

Anything that compiles C **inside the container**, rather than at image-build time:

- **`go test -race`, or any cgo build.** cgo needs a C compiler, and without one the failure is `cgo: C compiler "gcc" not found: exec: "gcc": executable file not found in $PATH`.
- Native extensions built at runtime — a gem, a Python wheel with no matching binary, an npm package that compiles on install.

## When you do not

If your project already enables **`ruby`** or **`db-clients`**, the toolchain is retained anyway — both need it to build native extensions — so setting this key changes nothing.

## Why it is not implied by `go=`

Most Go builds never touch cgo, and wiring the compiler to the language key would grow every Go image for a capability few of them use. It is opt-in for the same reason `db-clients` is. Go tools installed with `go install` — `golangci-lint`, `govulncheck` — are pure Go and need no C compiler.

## What it replaces

Without this key, the only ways to get a compiler were to switch on an unrelated language runtime, or to work around it by hand. One real session did the latter: relocating 31 architecture-specific `.deb` packages into `~/.local`, then wrapping `gcc` with `-B` flags (a displaced `cc1` cannot find its own support objects) and `LD_LIBRARY_PATH` (`cc1` links against libisl, libmpc and libmpfr). One key and a rebuild replaces all of it.

---

[← Components](README.md) · [Documentation index](../README.md)
