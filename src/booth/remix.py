"""Re-render an enhanced file at a new mix from its stems directory.

Runs the same post-mix chain as `pipeline.enhance_file` — leveler (when the
render used it), gain staging, peak guard, atomic write, video remux — on the
preview stems, so a remix at the original sliders reproduces the original
output and any other mix matches what a fresh enhance would have produced.
"""

from __future__ import annotations

import time
from pathlib import Path

import numpy as np

from . import atomic, dsp, stems
from . import audio as A
from .pipeline import mix_coefficients, output_paths, refuse_overwriting_input, write_mix


class MissingInputError(FileNotFoundError):
    """The original video is gone, so its enhanced copy can't be re-muxed."""


def remix(directory: Path, speech: float | None = None, background: float | None = None,
          music: float | None = None, out: Path | None = None, log=print) -> dict:
    """Render `directory`'s stems at the given mix (None keeps the saved value)."""
    t0 = time.time()
    directory = Path(directory)
    data = stems.read_manifest(directory)
    saved = data["mix"]
    speech = saved["speech"] if speech is None else speech
    background = saved["background"] if background is None else background
    music = saved["music"] if music is None else music
    settings = data["settings"]
    inp = Path(data["input"])

    wants_video = data["has_video"] and not settings["audio_only"]
    if wants_video and not inp.exists():
        # Without the original the video can't be re-muxed; a .wav -o asks for the audio alone.
        if out is None or Path(out).suffix.lower() != ".wav":
            raise MissingInputError(str(inp))
        wants_video = False
    if out is not None:
        wav_out, vid_out = output_paths(inp, Path(out))
    else:
        wav_out = Path(data["outputs"]["wav"])
        vid_out = Path(data["outputs"]["video"] or output_paths(inp, None)[1])
    finals = [vid_out, wav_out] if wants_video else [wav_out]
    refuse_overwriting_input(inp, finals)

    previews = stems.load_previews(directory, data)
    s, b, m = mix_coefficients(speech, background, music, settings["linear"])
    voice = (s * previews.clean + (1 - s) * previews.vocals).astype(np.float32)
    if settings["level"]:
        voice = dsp.level_voice(voice, A.SR)     # scale-invariant: fine on G0-scaled stems
    mix = voice + b * previews.background
    if previews.music is not None:
        mix = mix + m * previews.music
    # Undo the preview gain so gain staging sees exactly what enhance saw.
    g0 = previews.gain
    voice = (voice / g0).astype(np.float32)
    mix = (mix / g0).astype(np.float32)

    log(f"remix: speech {speech:g}%  background {background:g}%  music {music:g}%")
    wav_out.parent.mkdir(parents=True, exist_ok=True)
    # New wav and video replace the old pair together, or neither does.
    with atomic.transaction(finals) as partials:
        write_mix(mix, dsp.active_speech_db(voice), settings["loudness"], partials[-1], log)
        if wants_video:
            A.remux(inp, partials[-1], partials[0], crf=settings["crf"])
    video = vid_out if wants_video else None

    data["mix"] = stems.mix_values(speech, background, music)
    data["outputs"] = stems.outputs(wav_out, video)
    stems.save_manifest(directory, data)
    return {"wav": wav_out.resolve(), "video": video.resolve() if video else None,
            "music": bool(data["music"]), "mix": data["mix"], "engine": data["engine"],
            "stems": directory.resolve(), "total": time.time() - t0}
