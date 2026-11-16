---
name: cave
description: Render macOS SwiftUI screens to PNG with fixture data and check UI edits visually in seconds. Use when changing a SwiftUI view in a macOS app that has cave.json at its root.
---

# cave

`cave` renders registered fixtures of the app's real SwiftUI screens to PNG through a hidden render host (the app's Debug build). Always pass `--json`.

## Loop

1. `cave up --json` once per session, and again after a `--full` hint. It builds the app and starts the host (several seconds).
2. `cave render <fixture> --size 900x600 --appearance light,dark --json`, then read each `renders[].path` PNG.
3. Edit the Swift view.
4. `cave reload --render <fixture> --size 900x600 --appearance light,dark --json` patches the edit in and renders in about 2 s. Read the PNGs again.

Fixtures are registered in the fixtures file named in `cave.json`. To render a new screen or state, add `registry.add("name") { SomeView(...) }` there, then reload. An unknown fixture name fails with the list of registered names.

## Reading the result

- `ok: false` comes with `errors` (with `file`/`line` for compile errors) and a `hint`. Follow the hint.
- `stale_files`: these edits are not in the render, because no fixture or patched view names their types. Edit the parent view that embeds them as well, or run `cave reload --full`.
- `changed_since_reload` on a render: files on disk that are newer than the code in the host. Run `cave reload`.
- `host_log_tail`: the host crashed, usually from a `fatalError` or a failed precondition in the view. Fix it and reload. The host restarts by itself.
- If a patch fails to compile but the code builds in Xcode (e.g. new stored properties), run `cave reload --full`.

## Limits

Content only, without a titlebar or toolbar. The host runs outside the app sandbox.
