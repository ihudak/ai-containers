# ImageMagick and wkhtmltopdf

Two independent `ON`/`OFF` toggles for image and PDF tooling commonly needed at runtime:

```bash
imagemagick=ON    # install ImageMagick (mini_magick / image_processing / carrierwave)
wkhtmltopdf=ON    # install wkhtmltopdf runtime libs + the official standalone binary
```

- **`imagemagick`** — installs the `imagemagick` apt package. Off by default.
- **`wkhtmltopdf`** — installs the Qt/X11/font runtime libraries the `wkhtmltopdf` binary links against (so a gem-vendored binary, e.g. via `wkhtmltopdf-binary`, can actually run) **and** the official standalone `wkhtmltox` binary from the `wkhtmltopdf/packaging` GitHub releases, so non-Ruby projects get a working `wkhtmltopdf` too. No conflict between the two: a gem like `wicked_pdf` points at its own vendored binary, and the system binary on `PATH` does not override it. Off by default.

---

[← Components](README.md) · [Documentation index](../README.md)
