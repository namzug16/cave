---
name: cave
description: Render macOS SwiftUI screens to PNG with fixture data and check UI edits visually in seconds. Use when changing a SwiftUI view in a macOS app that has cave.json at its root, or when setting cave up in one.
---

# cave

Run `cave guide` once to learn the workflow, and how to set cave up in an app that doesn't have it yet.

Then start every session with `cave status --json`. Its `next` field is the command to run. Pass `--json` to every command, and read every PNG listed in `renders[].path`.
