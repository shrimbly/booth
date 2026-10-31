#!/usr/bin/env python3
"""Make the website's before/after demo from two aligned recordings.

    python3 site/tools/make-demo.py ORIGINAL ENHANCED [--start S] [--length L]

Writes site/media/before.m4a, site/media/after.m4a and site/media/demo.js (the
waveform and duration the page draws before any audio has loaded). Both clips are
matched to the same loudness, so the comparison is about clarity, not volume:
Booth leaves speech at Adobe Podcast's level, which is often quieter than
the original. Needs ffmpeg; uses only the standard library.
"""

from __future__ import annotations

import argparse
import array
import json
import math
import re
import subprocess
import sys
from pathlib import Path

MEDIA = Path(__file__).resolve().parent.parent / "media"
TARGET_LUFS = -18.0
PEAK_CEILING_DB = -1.0
BARS = 64
PEAK_RATE = 8000


def measure(path: Path, start: float, length: float | None) -> tuple[float, float]:
    """Integrated loudness (LUFS) and true peak (dBFS) of the excerpt."""
    cmd = ["ffmpeg", "-nostats", "-hide_banner", "-ss", str(start)]
    if length:
        cmd += ["-t", str(length)]
    cmd += ["-i", str(path), "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"]
    text = subprocess.run(cmd, capture_output=True, text=True, check=True).stderr
    loudness = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", text)[-1])
    peak = float(re.findall(r"Peak:\s+(-?[\d.inf]+) dBFS", text)[-1])
    return loudness, peak


def encode(path: Path, out: Path, gain_db: float, start: float, length: float | None) -> None:
    cmd = ["ffmpeg", "-y", "-v", "error", "-ss", str(start)]
    if length:
        cmd += ["-t", str(length)]
    cmd += ["-i", str(path), "-af", f"volume={gain_db:.2f}dB", "-ac", "1", "-ar", "48000",
            "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", str(out)]
    subprocess.run(cmd, check=True)


def levels(path: Path) -> tuple[list[float], float]:
    """The level of each of BARS slices, and the duration in seconds. A slice's level is
    the mean dB of its 20 ms frames, so pauses (and the noise in them) pull it down."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1",
                          "-ar", str(PEAK_RATE), "-f", "s16le", "-"],
                         capture_output=True, check=True).stdout
    samples = array.array("h", raw)
    if sys.byteorder != "little":
        samples.byteswap()
    frame = PEAK_RATE // 50
    frames = []
    for i in range(0, len(samples) - frame + 1, frame):
        chunk = samples[i:i + frame]
        rms = math.sqrt(sum(s * s for s in chunk) / frame) / 32768
        frames.append(20 * math.log10(rms + 1e-9))
    size = max(1, len(frames) // BARS)
    out = [sum(frames[i * size:(i + 1) * size]) / size for i in range(BARS)]
    return out, len(samples) / PEAK_RATE


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("original", type=Path)
    ap.add_argument("enhanced", type=Path)
    ap.add_argument("--start", type=float, default=0.0, help="excerpt start, seconds")
    ap.add_argument("--length", type=float, default=None, help="excerpt length, seconds")
    args = ap.parse_args()

    MEDIA.mkdir(parents=True, exist_ok=True)
    measured = {name: measure(path, args.start, args.length)
                for name, path in (("before", args.original), ("after", args.enhanced))}
    # One target for both, lowered if either would clip.
    target = min([TARGET_LUFS] + [loud + PEAK_CEILING_DB - peak
                                  for loud, peak in measured.values()])
    for name, path in (("before", args.original), ("after", args.enhanced)):
        loud, _ = measured[name]
        encode(path, MEDIA / f"{name}.m4a", target - loud, args.start, args.length)
        print(f"{name}: {loud:.1f} LUFS → {target:.1f} LUFS", file=sys.stderr)

    before, duration = levels(MEDIA / "before.m4a")
    after, _ = levels(MEDIA / "after.m4a")
    top = max(before + after)
    floor = top - 40.0                      # 40 dB of range from the loudest bar down

    def shape(values: list[float]) -> list[float]:
        return [round(max(0.06, min(1.0, (v - floor) / (top - floor))), 3) for v in values]

    demo = {"duration": round(duration, 2), "before": shape(before), "after": shape(after)}
    (MEDIA / "demo.js").write_text(
        "// Written by site/tools/make-demo.py. Waveform heights (0–1) for each clip.\n"
        f"window.BOOTH_DEMO = {json.dumps(demo, separators=(',', ':'))};\n")
    print(f"wrote {MEDIA}/before.m4a, after.m4a and demo.js ({duration:.1f}s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
