# Changelog

Each release's section is published as its GitHub release notes.

## 0.1.0 - 2026-11-18

First release.

- `cave up` builds the app's Debug scheme and starts it as a hidden render host. A failed build
  leaves the old host running.
- `cave render` renders a registered fixture to PNG at any number of sizes, in light and dark
  appearance, at the display's pixel scale. Liquid Glass and other backdrop effects render.
- `cave reload` patches the Swift files edited since the last build into the running host and
  renders again, usually in under two seconds, and lists edited views it can't show in
  `stale_files`.
- `cave status`, `cave list` and `cave guide` tell an agent what runs, what it can render and the
  next command to run. Every command takes `--json`.
- `cave down` stops the host, `cave clean` deletes rendered PNGs, and `cave version` prints the
  version.
- Install with `brew install namzug16/tap/cave` or the `install.sh` script.
