"""Stems directory: preview stems + manifest that let the app remix live.

    DIR/manifest.json
    DIR/preview_clean.wav       G0 · gate(clean)
    DIR/preview_vocals.wav      G0 · gate(vocals)
    DIR/preview_background.wav  G0 · background
    DIR/preview_music.wav       G0 · accompaniment   (only when music was detected)
    DIR/preview_original.wav    original, level-matched to the output for A/B

The gate's gain depends only on its key, so gate(s·clean + (1−s)·vocals) =
s·gate(clean) + (1−s)·gate(vocals), and G0 (the linear output gain of the
saved render) carries through. The app therefore reproduces the saved output
at any mix as s_eff·clean + (1−s_eff)·vocals + b_eff·background + m_eff·music.

All previews are 48 kHz mono float32 and are written unclipped: `remix`
renders from them, so they must hold exactly what the pipeline mixed. The
pipeline's previews are computed one at a time as they are written, so a long
input never holds all five in memory at once.
"""

from __future__ import annotations

import json
import os
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf

from . import atomic, dsp
from . import audio as A
from .events import PROTOCOL

MANIFEST = "manifest.json"
BAR_BINS = 56
STEM_NAMES = ("clean", "vocals", "background", "music", "original")


def preview_file(name: str) -> str:
    return f"preview_{name}.wav"


@dataclass
class Previews:
    clean: np.ndarray
    vocals: np.ndarray
    background: np.ndarray
    music: np.ndarray | None
    original: np.ndarray
    gain: float

    def items(self) -> list[tuple[str, np.ndarray]]:
        signals = [("clean", self.clean), ("vocals", self.vocals),
                   ("background", self.background), ("music", self.music),
                   ("original", self.original)]
        return [(name, sig) for name, sig in signals if sig is not None]


@dataclass
class PendingPreviews:
    """The pipeline's previews, each computed only when it is written."""

    clean: np.ndarray
    vocals: np.ndarray
    background: np.ndarray
    music: np.ndarray | None
    original: np.ndarray
    gate: Callable[[np.ndarray], np.ndarray]
    gain: float
    output_db: float

    def items(self) -> Iterator[tuple[str, np.ndarray]]:
        def scaled(x: np.ndarray) -> np.ndarray:
            return (x * self.gain).astype(np.float32, copy=False)

        yield "clean", scaled(self.gate(self.clean))
        yield "vocals", scaled(self.gate(self.vocals))
        yield "background", scaled(self.background)
        if self.music is not None:
            yield "music", scaled(self.music)
        yield "original", level_matched(self.original, self.output_db)


def make_previews(*, clean: np.ndarray, vocals: np.ndarray, background: np.ndarray,
                  music: np.ndarray | None, original: np.ndarray,
                  gate: Callable[[np.ndarray], np.ndarray], gain: float,
                  output_db: float) -> PendingPreviews:
    """Scale the pipeline's stems into the saved output's level, whose active
    speech level is `output_db`."""
    return PendingPreviews(clean=clean, vocals=vocals, background=background, music=music,
                           original=original, gate=gate, gain=float(gain),
                           output_db=output_db)


def level_matched(original: np.ndarray, output_db: float) -> np.ndarray:
    """The original at the output's active-speech level, so A/B compares
    sound, not loudness. Pulled down further only if it would clip."""
    g = 10 ** ((output_db - dsp.active_speech_db(original)) / 20)
    peak = float(max(original.max(), -original.min())) * g
    if peak > 0.99:
        g *= 0.99 / peak
    return (original * g).astype(np.float32, copy=False)


def bars(x: np.ndarray, bins: int = BAR_BINS) -> list[float]:
    """Raw linear RMS of `x` in `bins` equal time slices."""
    edges = np.linspace(0, len(x), bins + 1).astype(int)
    out = []
    for a, b in zip(edges[:-1], edges[1:], strict=True):
        seg = x[a:b].astype(np.float64)
        out.append(round(float(np.sqrt(np.mean(seg ** 2))), 6) if b > a else 0.0)
    return out


def mix_values(speech: float, background: float, music: float) -> dict:
    def num(v: float) -> float | int:
        return int(v) if float(v).is_integer() else round(float(v), 2)
    return {"speech": num(speech), "background": num(background), "music": num(music)}


def manifest(*, inp: Path, duration: float, has_video: bool, engine: str,
             generative: bool, music: bool, wav: Path, video: Path | None,
             speech: float, background: float, music_level: float, linear: bool,
             level: bool, loudness: str | float | None, crf: int | None,
             audio_only: bool) -> dict:
    """Manifest fields describing a render (bars and preview gain are added on write)."""
    return {
        "protocol": PROTOCOL,
        "input": str(Path(inp).resolve()),
        "name": Path(inp).name,
        "duration": round(duration, 3),
        "has_video": has_video,
        "engine": engine,
        "generative": generative,
        "music": bool(music),
        "sample_rate": A.SR,
        "outputs": outputs(wav, video),
        "mix": mix_values(speech, background, music_level),
        # level: the leveler actually ran (it is skipped for generative engines).
        "settings": {"linear": linear, "level": level, "loudness": loudness,
                     "crf": crf, "audio_only": audio_only},
    }


def outputs(wav: Path, video: Path | None) -> dict:
    return {"wav": str(Path(wav).resolve()),
            "video": str(Path(video).resolve()) if video else None}


def write_stems_dir(directory: Path, previews: Previews | PendingPreviews, fields: dict) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    # The manifest is written last: its presence means the directory is complete.
    (directory / MANIFEST).unlink(missing_ok=True)
    stem_bars = {}
    for name, signal in previews.items():
        with atomic.replacing(directory / preview_file(name)) as tmp:
            sf.write(str(tmp), signal, A.SR, subtype="FLOAT")
        stem_bars[name] = bars(signal)
        del signal
    if previews.music is None:
        (directory / preview_file("music")).unlink(missing_ok=True)
    zeros = [0.0] * BAR_BINS
    save_manifest(directory, {
        **fields,
        "preview_gain": round(previews.gain, 9),
        "previews": {name: preview_file(name) for name in stem_bars},
        "bars": {name: stem_bars.get(name, zeros) for name in STEM_NAMES},
    })


def save_manifest(directory: Path, data: dict) -> None:
    path = directory / MANIFEST
    tmp = path.with_name(f".{MANIFEST}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False))
    os.replace(tmp, path)


def read_manifest(directory: Path) -> dict:
    data = json.loads((directory / MANIFEST).read_text())
    if data.get("protocol") != PROTOCOL:
        raise ValueError(f"unsupported stems manifest protocol: {data.get('protocol')}")
    return data


def load_previews(directory: Path, data: dict) -> Previews:
    def read(name: str) -> np.ndarray | None:
        path = directory / preview_file(name)
        if not path.exists():
            return None
        x, sr = sf.read(str(path), dtype="float32")
        if sr != A.SR:
            raise ValueError(f"{path.name} is {sr} Hz, expected {A.SR}")
        return x

    signals = {name: read(name) for name in STEM_NAMES}
    for name in ("clean", "vocals", "background", "original"):
        if signals[name] is None:
            raise FileNotFoundError(f"{preview_file(name)} is missing from {directory}")
    return Previews(gain=float(data["preview_gain"]), **signals)
