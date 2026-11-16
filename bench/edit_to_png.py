#!/usr/bin/env python3
"""End-to-end check and benchmark: time from a saved Swift edit to a fresh PNG, host already running.

Run from the repository root:  python3 bench/edit_to_png.py [runs]
"""
import hashlib
import json
import pathlib
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
VIEW = ROOT / "Examples/CaveDemo/CaveDemo/LibraryView.swift"
CAVE = ROOT / ".build/release/cave"
LABEL = '"Mark as Read"'


def cave(*arguments):
    result = subprocess.run([str(CAVE), *arguments, "--json"], cwd=ROOT, capture_output=True, text=True)
    report = json.loads(result.stdout)
    assert report["ok"], report
    return report


def png_digest(report):
    [render] = report["renders"]
    return hashlib.sha256(pathlib.Path(render["path"]).read_bytes()).hexdigest()


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    subprocess.run(["swift", "build", "-c", "release", "--product", "cave"], cwd=ROOT, check=True, capture_output=True)
    original = VIEW.read_text()
    assert LABEL in original, f"{VIEW} no longer contains {LABEL}"
    try:
        up = cave("up")
        print(f"cave up: {up['timings']}")
        render_arguments = ("--render", "library.populated", "--size", "900x600")
        previous = png_digest(cave("reload", *render_arguments))
        totals = []
        for run in range(1, runs + 1):
            VIEW.write_text(original.replace(LABEL, f'"Mark as Read #{run}"'))
            start = time.monotonic()
            report = cave("reload", *render_arguments)
            totals.append((time.monotonic() - start) * 1000)
            digest = png_digest(report)
            assert digest != previous, f"run {run}: the PNG did not change after the edit"
            assert not report["stale_files"], report["stale_files"]
            previous = digest
            print(f"run {run}: {totals[-1]:.0f} ms  {report['timings']}")
        print(f"edit to PNG, median of {runs}: {statistics.median(totals):.0f} ms (min {min(totals):.0f}, max {max(totals):.0f})")
    finally:
        VIEW.write_text(original)


if __name__ == "__main__":
    main()
