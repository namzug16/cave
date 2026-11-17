# Plato's Cave (`cave`)

An agent-first CLI that renders native macOS SwiftUI screens to PNG. A coding agent renders a real screen with fixture data, reads the PNG, edits the view and renders it again in under two seconds, without Xcode previews.

```sh
cave up                                   # build the Debug app, start the render host
cave render library.populated --size 900x600 --size 1280x800 --appearance light,dark --json
# ...edit LibraryView.swift...
cave reload --render library.populated --size 900x600 --json   # patch the edit in, render
cave down
```

Agents should start with `cave status --json`. Its `next` field names the command to run, and `cave guide` explains the rest.

## Install

```sh
make install                 # cave in ~/.local/bin, CaveKit.swift and SKILL.md in ~/.local/share/cave
make install PREFIX=/usr/local
```

## Setup

1. **Add [`Templates/CaveKit.swift`](Templates/CaveKit.swift)** to your macOS app target, unchanged. `make install` also puts a copy in `~/.local/share/cave/`.
2. **Add a fixtures file** to the app target that registers screens with fixture data:
   ```swift
   import SwiftUI

   func caveFixtures(_ registry: CaveRegistry) {
       registry.add("library.populated") { LibraryView(books: .samples, selection: 1) }
   }
   ```
3. **Call the host from `App.init()`.** Normal launches are untouched; render mode starts only when `cave` launches the app with `--cave-socket`:
   ```swift
   init() { CaveHost.runIfRequested(caveFixtures) }
   ```

Then add `cave.json` at the repository root (paths relative to it), and add `.cave/` to `.gitignore`:

```json
{ "project": "App.xcodeproj", "scheme": "App", "fixtures": "App/CaveFixtures.swift" }
```

[`Examples/CaveDemo`](Examples/CaveDemo) is a complete app set up this way, and this repository's `cave.json` points at it.

## Commands

| Command | What it does |
|---|---|
| `cave status` | Whether the host runs, the files it doesn't have yet, the fixtures, and `next`: the exact command to run now. Read-only. |
| `cave list` | The fixtures you can render. |
| `cave guide` | The agent workflow: the loop, how to read each JSON field, and how to set cave up in a new app. |
| `cave up` | `xcodebuild` the scheme in Debug, then replace the running host with the new build. A failed build leaves the old host running. |
| `cave render <fixture>` | Render a fixture at every `--size WxH` (points, repeatable, default 1024x768) crossed with `--appearance light,dark` (default light), at @2x. |
| `cave reload [--render <fixture> …]` | Patch the Swift files edited since the last build into the host, then render. `--full` runs `cave up` instead. |
| `cave down` | Stop the host. |

PNGs go to `.cave/renders/<fixture>/<W>x<H>-<appearance>.png`. With `--json` every command prints one JSON object:

```json
{"ok": true,
 "renders": [{"path": ".../900x600-dark.png", "width": 900, "height": 600, "appearance": "dark", "ms": 139}],
 "patched_files": [".../LibraryView.swift", ".../CaveFixtures.swift"],
 "stale_files": [],
 "timings": {"compile_ms": 1107, "apply_ms": 370, "render_ms": 149, "total_ms": 1637}}
```

Failures exit 1 with `{"ok": false, "errors": [{"file", "line", "column", "message"}] | [{"message"}], "hint": "...", "host_log_tail": "..."}`. Compile errors point at your file and line. If a view crashes the host, the error carries the crash from the host log, and the next command restarts the host.

## How it works

- **The render host is your Debug app.** `cave up` builds it with `xcodebuild` into `.cave/DerivedData`, clones the `.app` into `.cave/host` and re-signs the clone ad hoc *without entitlements*. Outside the app sandbox the host can listen on its socket and load patches from `.cave` without prompts. `CFFIXED_USER_HOME` points its home folder at `.cave/home`, so its preferences and files stay out of your real ones.
- **Rendering** puts the fixture in an `NSHostingView` in a borderless window with the requested size and `NSAppearance`. The window sits on the sharpest display, below the desktop window so nobody sees it, and the window server captures it with `CGWindowListCreateImage`. That's the only capture path that composites Liquid Glass and other backdrop effects (`cacheDisplay` and `CARenderer` leave them blank). An app may capture its own windows without the Screen Recording permission. Windows larger than the display are captured piece by piece and stitched. The PNG has the display's pixel scale, reported as `scale`. `controlActiveState` is forced to `.key`, so controls draw as in a focused window.
- **Hot reload** (adapted from [Simless](https://github.com/abacusai/simless)) compiles the files edited since the last build, plus the fixtures file, into a dylib whose module `@testable import`s the app and links with `-undefined dynamic_lookup`. The host `dlopen`s it and calls its `cave_patch_entry`, which re-registers every fixture from the patch's copy of the code. Compiler flags (Swift version, default isolation, upcoming features, conditions) come from the build settings.
- The CLI talks to the host over a Unix socket in `$TMPDIR`, one JSON line per request. Commands are serialized per worktree with a lock in `.cave/`.

## Limits

- **An edited view renders anew only where the patch constructs it.** If you edit a child view that only an unedited parent embeds, the render still shows the built child. `cave reload` lists such files in `stale_files`. Touch the parent too, or run `cave reload --full`. Detection matches type names: one pass, no declaration graph.
- **Some changes can't be patched,** such as stored properties added to a type that other, unedited code uses. These fail to compile or misbehave, so use `--full`. Editing `CaveKit.swift` always needs `--full`.
- **Content only:** no titlebar, toolbar or window chrome.
- **Glass looks like it does in a background window.** Plain glass renders, sampling what's behind it, but tinted glass (`.glassEffect(.regular.tint(…))`) comes out gray instead of tinted. SwiftUI takes glass's active look from the app being frontmost, and the host never activates so it doesn't take focus.
- **Capture relies on `CGWindowListCreateImage`,** which the macOS SDK marks obsolete; it is looked up at run time. If macOS removes it, ScreenCaptureKit is the replacement, and that needs the Screen Recording permission.
- **The host runs unsandboxed,** so code that depends on the sandbox container behaves differently.
- **About 350 ms of each reload is macOS scanning the new dylib** the first time it is loaded, which every freshly written binary pays. Adding your terminal under *System Settings › Privacy & Security › Developer Tools* may remove it (not yet measured).

## Performance

`python3 bench/edit_to_png.py` measures the time from a saved edit to a fresh PNG, with the host already running. On the demo app (M1, Xcode 27.2) the median of 5 runs is **1.6–1.9 s** (single runs 1.56–2.17 s): compile 1.0–1.6 s, apply ~0.37 s, render ~0.17 s. `cave up` takes about 7 s warm.
