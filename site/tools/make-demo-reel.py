"""The website's demo reel: short sections of real recordings, before and after Booth.

Writes site/media/reel.mp4 (the picture, silent), reel-original.m4a and reel-booth.m4a (the two
sound tracks, cut identically, at the same speech level), reel-poster.jpg, and reel.js: the
waveforms, the sections and what Booth fixed in each, which the page draws under the video.

Every mark on the timeline is measured, not written by hand:
  breath  the engine's own breath detector (dsp.breath_frames) on Booth's restored voice
  click   a burst far above the quiet around it in the original, 12 dB or more quieter in Booth's
  noise   the pauses' level in the original against Booth's, when Booth's is 10 dB or more lower;
          marked on up to two free pauses, or where the section begins

Sources are the author's own recordings, outside the repository. Enhance each with the engine
first, keeping the stems:

  .venv/bin/booth enhance IN.mp4 --audio-only --keep-stems RUNS/ID-stems -o RUNS/ID-booth.wav

  .venv/bin/python site/tools/make-demo-reel.py survey RUNS ID IN.mp4    # what's where, and good sections
  .venv/bin/python site/tools/make-demo-reel.py build RUNS               # the reel from SECTIONS below
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy import ndimage, signal

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
from booth import dsp, vad  # noqa: E402

SR = 48000
MEDIA = ROOT / "site" / "media"
NODE_BANANA = Path.home() / "Documents/projects/screenstudio/node banana"

# (run id, source, start s, end s, title). Chosen with `survey`; each starts and ends in a pause.
SECTIONS: list[tuple[str, Path, float, float, str]] = [
    ("nb", NODE_BANANA / "material application.mp4", 73.10, 85.05, "Node Banana: Material application"),
    ("prompt", NODE_BANANA / "Prompt construction.mp4", 169.75, 180.40, "Node Banana: Prompt construction"),
    ("updates", NODE_BANANA / "02-28 updates.mp4", 148.40, 158.30, "Node Banana: February update"),
]

WIDTH, HEIGHT = 1280, 800           # 16:10, the shape of the screen recordings
BACKDROP = "0x0d0c11"               # the recordings' own dark surround, for padding and fades
GAP = 0.6                           # seconds of quiet between sections
FADE = 0.03                         # seconds each section's sound fades in and out
PEAKS_PER_SECOND = 40


def load(path: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).copy()


def runs(mask: np.ndarray, hop_s: float, bridge_s: float = 0.0, min_s: float = 0.0) -> list[tuple[float, float]]:
    """[start, end) seconds of each run of True, joining gaps up to bridge_s, keeping runs of min_s."""
    if bridge_s:
        mask = ndimage.binary_closing(mask, iterations=max(1, int(bridge_s / hop_s)))
    labels, _ = ndimage.label(mask)
    out = []
    for found in ndimage.find_objects(labels):
        a, b = found[0].start * hop_s, found[0].stop * hop_s
        if b - a >= min_s:
            out.append((round(a, 3), round(b, 3)))
    return out


def breaths(clean: np.ndarray) -> list[tuple[float, float]]:
    mask, rel, _ = dsp.breath_frames(clean, vad.speech_probability(clean, SR), SR)
    # Mark only what you can hear of each: a breath's run can trail on into silence.
    heard = runs(mask & (rel > -40), 0.01, bridge_s=0.1, min_s=0.15)
    return [(a, b) for a, b in heard if b - a <= 1.5]


def _hp_energy_db(x: np.ndarray, frame: int) -> np.ndarray:
    sos = signal.butter(4, 1000, "high", fs=SR, output="sos")
    y = signal.sosfiltfilt(sos, x.astype(np.float64))
    n = len(y) // frame
    return 10 * np.log10((y[:n * frame].reshape(n, frame) ** 2).mean(axis=1) + 1e-14)


def clicks(orig: np.ndarray, booth: np.ndarray) -> list[tuple[float, float]]:
    """Short bursts far above the quiet around them in the original that Booth's output lost."""
    frame = SR // 400                                       # 2.5 ms
    o, b = _hp_energy_db(orig, frame), _hp_energy_db(booth, frame)
    b += dsp.active_speech_db(orig) - dsp.active_speech_db(booth)       # same speech level
    n = min(len(o), len(b))
    o, b = o[:n], b[:n]
    lin = 10 ** (o / 10)
    k = np.ones(38) / 38                                    # 25-120 ms either side
    pre = np.convolve(lin, k, "full")[:n]
    pre = np.concatenate([np.full(10, pre[0]), pre[:-10]])
    post = np.convolve(lin[::-1], k, "full")[:n][::-1]
    post = np.concatenate([post[10:], np.full(10, post[-1])])
    ctx = 10 * np.log10(np.maximum(pre, post) + 1e-14)
    speech = dsp.active_speech_db(orig)
    burst = (o - ctx > 18) & (ctx - speech < -25) & (o - b > 12)
    return [(a, e) for a, e in runs(burst, frame / SR) if e - a <= 0.03]


def pause_floor(x: np.ndarray, quiet: np.ndarray) -> float:
    """Median level of the 50 ms frames in `quiet`, in dB re the speech."""
    k = SR // 20
    n = min(len(x) // k, len(quiet))
    db = 10 * np.log10((x[:n * k].reshape(n, k) ** 2).mean(axis=1) + 1e-14) - dsp.active_speech_db(x)
    return float(np.median(db[quiet[:n]])) if quiet[:n].any() else -90.0


def pauses(booth: np.ndarray) -> np.ndarray:
    """50 ms frames well below Booth's speech: the pauses between phrases."""
    k = SR // 20
    n = len(booth) // k
    db = 10 * np.log10((booth[:n * k].reshape(n, k) ** 2).mean(axis=1) + 1e-14) - dsp.active_speech_db(booth)
    return ndimage.binary_erosion(db < -30, iterations=2)


def events(orig: np.ndarray, booth: np.ndarray, clean: np.ndarray) -> list[dict]:
    found = [{"kind": "breath", "start": a, "end": e} for a, e in breaths(clean)]
    found += [{"kind": "click", "start": a, "end": e} for a, e in clicks(orig, booth)]
    return sorted(found, key=lambda ev: ev["start"])


def survey(run_dir: Path, run_id: str, source: Path, length: float = 10.0) -> None:
    orig = load(source)
    booth = load(run_dir / f"{run_id}-booth.wav")
    clean = load(run_dir / f"{run_id}-stems" / "clean_speech.wav")
    n = min(map(len, (orig, booth, clean)))
    orig, booth, clean = orig[:n], booth[:n], clean[:n]
    quiet = pauses(booth)
    print(f"{source.name}: {n / SR:.1f} s; pauses {pause_floor(orig, quiet):.1f} dB in the original, "
          f"{pause_floor(booth, quiet):.1f} dB in Booth's")
    evs = events(orig, booth, clean)
    for ev in evs:
        print(f"  {ev['kind']:7s} {ev['start']:7.2f}-{ev['end']:.2f}")
    # Sections of about `length` s that start and end in a pause, ranked by what happens in them.
    edges = [a * 0.05 for a, _ in runs(quiet, 1.0)]
    starts = [i * 0.05 for i in np.flatnonzero(quiet)]
    pause_times = np.array(starts)
    ranked = []
    for s0 in edges:
        candidates = pause_times[(pause_times > s0 + length - 2) & (pause_times < s0 + length + 2)]
        if not len(candidates):
            continue
        s1 = float(candidates[np.argmin(abs(candidates - (s0 + length)))])
        inside = [ev for ev in evs if ev["start"] >= s0 and ev["end"] <= s1]
        kinds = {ev["kind"] for ev in inside}
        ranked.append((len(inside) + 2 * len(kinds), s0, s1, len(inside), sorted(kinds)))
    ranked.sort(reverse=True)
    print("  best sections:")
    for score, s0, s1, count, kinds in ranked[:6]:
        print(f"    {s0:6.2f}-{s1:6.2f}  {count} events {kinds}")


def noise_events(orig: np.ndarray, booth: np.ndarray, taken: list[dict], a: float, b: float) -> list[dict]:
    """Up to two pauses in [a, b) where the original's background is plain and Booth's isn't."""
    quiet = pauses(booth)
    if pause_floor(orig, quiet) - pause_floor(booth, quiet) < 10:
        return []
    found = []
    for start, end in runs(quiet, 0.05, min_s=0.35):
        start, end = start + 0.05, end - 0.05            # clear of the speech either side
        if start < a or end > b or any(ev["start"] < end and ev["end"] > start for ev in taken + found):
            continue
        found.append({"kind": "noise", "start": start, "end": end})
        if len(found) == 2:
            break
    if not found:
        # Pauses taken by breaths, or none long enough: the noise is under everything, so mark
        # where the section begins, up to whatever is marked first.
        start = a + 0.05
        end = min([a + 1.0] + [ev["start"] - 0.05 for ev in taken if ev["start"] > start])
        if end - start >= 0.4:
            found.append({"kind": "noise", "start": round(start, 3), "end": round(end, 3)})
    return found


def peaks(x: np.ndarray, speech_db: float) -> list[float]:
    """Loudness per 1/PEAKS_PER_SECOND s on a dB scale, 0 at 48 dB under the speech, 1 at 6 over:
    a quiet room's noise still shows, so a waveform without it looks it."""
    k = SR // PEAKS_PER_SECOND
    n = len(x) // k
    db = 10 * np.log10((x[:n * k].reshape(n, k).astype(np.float64) ** 2).mean(axis=1) + 1e-14) - speech_db
    return [round(float(v), 3) for v in np.clip((db + 48) / 54, 0, 1)]


def encode_audio(x: np.ndarray, path: Path) -> None:
    with tempfile.NamedTemporaryFile(suffix=".f32") as raw:
        raw.write(x.astype(np.float32).tobytes())
        raw.flush()
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", raw.name,
                        "-c:a", "aac", "-b:a", "112k", "-movflags", "+faststart", str(path)], check=True)


def build(run_dir: Path) -> None:
    before_parts, after_parts, sections, marks = [], [], [], []
    at = 0.0
    for i, (run_id, source, a, b, title) in enumerate(SECTIONS):
        orig = load(source)
        booth = load(run_dir / f"{run_id}-booth.wav")
        clean = load(run_dir / f"{run_id}-stems" / "clean_speech.wav")
        n = min(map(len, (orig, booth, clean)))
        orig, booth, clean = orig[:n], booth[:n], clean[:n]
        found = [ev for ev in events(orig, booth, clean) if ev["start"] >= a and ev["end"] <= b]
        found += noise_events(orig, booth, found, a, b)
        i0, i1 = int(a * SR), int(b * SR)
        o, k = orig[i0:i1].astype(np.float64), booth[i0:i1].astype(np.float64)
        # The original at Booth's speech level: the difference you hear is the cleanup, not the volume.
        o *= 10 ** ((dsp.active_speech_db(k.astype(np.float32)) - dsp.active_speech_db(o.astype(np.float32))) / 20)
        ramp = np.linspace(0, 1, int(FADE * SR))
        for part in (o, k):
            part[:len(ramp)] *= ramp
            part[-len(ramp):] *= ramp[::-1]
        if i:
            before_parts.append(np.zeros(int(GAP * SR)))
            after_parts.append(np.zeros(int(GAP * SR)))
            at += GAP
        before_parts.append(o)
        after_parts.append(k)
        sections.append({"start": round(at, 3), "end": round(at + (b - a), 3), "title": title})
        found.sort(key=lambda ev: ev["start"])
        marks += [{**ev, "start": round(at + ev["start"] - a, 3), "end": round(at + ev["end"] - a, 3)} for ev in found]
        print(f"{title}: {', '.join(sorted({ev['kind'] for ev in found})) or 'nothing marked'} ({len(found)} marks)")
        at += b - a
    before, after = np.concatenate(before_parts), np.concatenate(after_parts)
    speech = dsp.active_speech_db(after.astype(np.float32))
    peak = max(np.abs(before).max(), np.abs(after).max())
    if peak > 0.98:                                      # both tracks down together, never apart
        before, after = before * 0.98 / peak, after * 0.98 / peak
    MEDIA.mkdir(parents=True, exist_ok=True)
    encode_audio(before, MEDIA / "reel-original.m4a")
    encode_audio(after, MEDIA / "reel-booth.m4a")

    # The picture: each section fitted to 16:10 on the recordings' dark surround, faded in and out,
    # with the same gaps as the sound.
    inputs, chains = [], []
    for i, (_, source, a, b, _) in enumerate(SECTIONS):
        d = b - a
        inputs += ["-ss", f"{a:.3f}", "-t", f"{d:.3f}", "-i", str(source)]
        pad = f",tpad=stop_duration={GAP}:color={BACKDROP}" if i < len(SECTIONS) - 1 else ""
        chains.append(f"[{i}:v]fps=30,scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,"
                      f"pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2:color={BACKDROP},setsar=1,"
                      f"fade=t=in:st=0:d=0.25:color={BACKDROP},fade=t=out:st={d - 0.25:.3f}:d=0.25:color={BACKDROP}{pad}[v{i}]")
    graph = ";".join(chains) + ";" + "".join(f"[v{i}]" for i in range(len(SECTIONS))) + f"concat=n={len(SECTIONS)}:v=1:a=0[out]"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[out]", "-an",
                    "-c:v", "libx264", "-preset", "slow", "-crf", "27", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    str(MEDIA / "reel.mp4")], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "1.0", "-i", str(MEDIA / "reel.mp4"), "-frames:v", "1",
                    "-q:v", "4", str(MEDIA / "reel-poster.jpg")], check=True)

    reel = {"duration": round(len(after) / SR, 3), "sections": sections, "events": marks,
            "peaks": {"before": peaks(before, speech), "after": peaks(after, speech)}}
    (MEDIA / "reel.js").write_text(
        "// Written by site/tools/make-demo-reel.py: the demo reel's sections, waveforms and what Booth fixed.\n"
        f"window.BOOTH_REEL = {json.dumps(reel, separators=(',', ':'))};\n")
    print(f"reel: {reel['duration']:.1f} s, {len(marks)} marks; " + ", ".join(
        f"{p.name} {p.stat().st_size / 1e6:.1f} MB" for p in sorted(MEDIA.glob("reel*"))))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "survey" and len(sys.argv) == 5:
        survey(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]))
    elif mode == "build" and len(sys.argv) == 3:
        build(Path(sys.argv[2]))
    else:
        sys.exit(__doc__)
