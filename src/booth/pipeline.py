"""Enhancement pipeline: decode -> separate -> enhance -> remix -> gain -> write/remux.

Decomposition (all mono float32 @ 48 kHz, exact by construction):

    original = vocals + accompaniment          (demucs htdemucs)
    vocals   = clean_speech + background       (DeepFilterNet3 residual)

With the default generative engine (Sidon), clean_speech is instead Sidon's
resynthesis of the raw original — envelope-aligned, level-matched to the DF3
estimate, tone-corrected, and gated by the DF3 speech envelope. The DF3
residual still defines the background stem.

Remix with slider percentages (speech s, background b, music m):

    out = s_eff*clean + (1-s_eff)*vocals + b_eff*background + m*accompaniment

Slider response curves are calibrated against a real Adobe Podcast Enhance v2
reference pair (same input, sliders 54/10/10). Least-squares fitting Adobe's
output onto our stem basis showed their 54% slider corresponds to ~fully clean
speech (their slider is perceptual, not a linear wet/dry), and their measured
gap noise floor (-42.8 dB below speech) implies near-zero raw-stem reinjection:

    s_eff = 1 - (1 - s)^6          (0.54 -> 0.99; endpoints preserved)
    b_eff = b^2                    (0.10 -> 0.01)

Loudness: Adobe normalizes so the speech component lands at ~-29 LUFS
(+6.5 dB on the reference). Default "auto" gain reproduces that.
"""

from __future__ import annotations

import importlib.resources
import math
import os
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile as sf

from . import atomic, dsp
from . import audio as A
from . import stems as stemsdir
from .engines import deepfilter
from .progress import NullReporter, Reporter

# Calibration constants (derived from the Adobe reference pair by calibration
# scripts that have since been removed). Adobe's output at sliders 54/10/10 measured a
# -42.8 dB gap-to-speech noise floor — reinjecting raw stems at face value is
# audible, so the response curves are steep and the music channel is gated.
K_SPEECH = 6.0            # speech-slider response exponent (54% -> 99% clean)
K_BG = 2.0                # background-slider response exponent (10% -> 1%)
MUSIC_GATE_DB = -9.0      # mute music channel below this held-note level re vocals
                          # (measured: speech-only recordings -13..-48, music bed -5)
# Adobe normalizes ACTIVE speech level, not integrated loudness (their refs
# cluster at a fixed active-speech dB while integrated LUFS varies with pause
# density). -29 matches the user-validated reference pair.
SPEECH_ACTIVE_TARGET_DB = -29.0
# Below this active level the voice channel is silence or model residue, not
# speech: lifting it to the target would only raise the noise. The Booth app
# mirrors both values for its live preview.
SPEECH_FLOOR_DB = -70.0
MAX_AUTO_GAIN_DB = 30.0   # the most auto gain lifts a quiet voice
AIR_REL_DB = -27.0        # synthetic air level vs speech core (swept vs Adobe: rel -27.9, flat -5.2)
GENERATIVE = {"sidon"}               # engines that resynthesize the voice


@dataclass
class Settings:
    speech: float = 54.0
    background: float = 10.0
    music: float = 10.0
    engine: str = "sidon"           # "sidon" | "mossformer2" | "df3"
    polish: bool = True             # DF3 pass after mossformer (noise under speech)
    split_music: bool = True
    match_eq: bool = True
    expander: bool = True           # gate residual noise in speech gaps
    low_gate: bool = True           # gate noise-like rumble in the sub-150 Hz band
    air: bool = True                # synthesize breathy high-band air
    level: bool = True              # slow AGC on the voice channel
    smooth: bool = True             # harmonic smoothing (generative engines)
    declick: bool = True            # mouth/tongue click removal (generative engines)
    linear: bool = False            # bypass calibrated slider curves
    loudness: str | float | None = "auto"   # "auto" | LUFS float | None
    device: str = "cpu"
    crf: int | None = None
    audio_only: bool = False
    keep_stems: Path | None = None
    progress: bool = True
    timings: dict = field(default_factory=dict)


MIN_SECONDS = 0.25        # shorter inputs give the analysis nothing to measure


class NoAudioError(SystemExit):
    """The input has no audio stream. A SystemExit so the plain CLI exits with
    the message, as it always has; the app protocol maps it to `no_audio`."""


class TooShortError(SystemExit):
    """The input is shorter than MIN_SECONDS. Like NoAudioError, the plain CLI
    exits with the message; the app protocol maps it to `decode_failed`."""


class OutputIsInputError(ValueError):
    """An output path names the input itself, so writing it would destroy the original."""


def _restore_sidon(src: np.ndarray, vocals: np.ndarray, log,
                   report: Reporter) -> tuple[np.ndarray, np.ndarray]:
    """Sidon restoration, aligned and level-matched; returns (clean, key).

    key = DF3 on the vocals stem: the speech-presence signal for the gate and
    the reference for the background decomposition and output level.
    """
    from .engines import sidon
    key = deepfilter.enhance(vocals, A.SR)
    log(f"  restoring voice with Sidon (~{len(src) / A.SR * 0.3:.0f}s)…")
    restored = sidon.enhance(src, A.SR, log=log, on_progress=report.signal)
    lag = dsp.envelope_lag(src, restored, A.SR)
    restored = dsp.shift(restored, lag)
    if abs(lag) > A.SR // 1000:          # only worth mentioning above 1 ms
        log(f"  (aligned sidon output by {lag} samples)")
    gain_db = dsp.active_speech_db(key) - dsp.active_speech_db(restored)
    restored = restored * 10 ** (gain_db / 20)
    return dsp.restoration_tone(restored, A.SR), key


def _load_eq_profile():
    # Derived for MossFormer2's timbre; generative engines skip it.
    try:
        ref = importlib.resources.files("booth") / "data" / "adobe_v2_eq.npz"
        with importlib.resources.as_file(ref) as p:
            if p.exists():
                d = np.load(p)
                return d["freqs"], d["gain_db"]
    except Exception:
        pass
    return None


def _lufs_of_array(x: np.ndarray) -> float:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
        tmp = Path(tf.name)
    A.write_wav(tmp, x, subtype="FLOAT")
    try:
        return A.integrated_lufs(tmp)
    finally:
        tmp.unlink(missing_ok=True)


def mix_coefficients(speech: float, background: float, music: float,
                     linear: bool) -> tuple[float, float, float]:
    """Slider percentages -> effective stem gains (s_eff, b_eff, m_eff)."""
    s = np.clip(speech / 100.0, 0.0, 1.0)
    b = np.clip(background / 100.0, 0.0, 1.0)
    m = np.clip(music / 100.0, 0.0, 1.0)
    if not linear:
        s = 1.0 - (1.0 - s) ** K_SPEECH
        b = b ** K_BG
        m = m ** K_BG   # music too: Adobe's 10% ≈ −43 dB below speech, not −27
    return s, b, m


def voice_gate(st: Settings, key: np.ndarray | None,
               clean: np.ndarray) -> Callable[[np.ndarray], np.ndarray]:
    """The voice-channel gap gate. Its gain depends only on the key, so it is
    linear in its input — which is what lets the app remix gated stems live.
    A DF3 key's gain is computed here, so the key itself can be released."""
    if not st.expander:
        return lambda x: x
    # Gate residual noise in speech gaps on the voice channel only —
    # background/music stems keep their user-chosen level.
    if key is not None:
        return dsp.speech_gate_gain(key, sr=A.SR)
    return lambda x: dsp.gap_expander(x, key=clean, sr=A.SR)


def output_paths(inp: Path, out: Path | None) -> tuple[Path, Path]:
    """(wav, video) output paths for an input and an optional -o: a file name,
    or an existing folder to write the default names into."""
    if out is not None and Path(out).is_dir():
        inp, out = Path(out) / Path(inp).name, None
    if out is not None:
        out = Path(out)
        wav_out = out if out.suffix.lower() == ".wav" else out.with_suffix(".wav")
        vid_out = out if out.suffix.lower() != ".wav" else out.with_suffix(inp.suffix or ".mp4")
    else:
        stem = inp.with_suffix("")
        wav_out = Path(f"{stem}-enhanced.wav")
        vid_out = Path(f"{stem}-enhanced{inp.suffix if inp.suffix else '.mp4'}")
    return wav_out, vid_out


def kept_stem_paths(directory: Path | None) -> list[Path]:
    """The files --keep-stems writes, in the order enhance_file writes them."""
    if directory is None:
        return []
    return [Path(directory) / f"{name}.wav"
            for name in ("clean_speech", "background", "music", "vocals_raw")]


def refuse_overwriting_input(inp: Path, finals: list[Path]) -> None:
    """Raise OutputIsInputError when an output would replace the input. samefile
    also catches a name that differs only in case on a case-insensitive volume,
    and a path through a symlink; an output that doesn't exist yet can't be it."""
    for final in finals:
        try:
            same = os.path.samefile(final, inp)
        except OSError:
            continue
        if same:
            raise OutputIsInputError(str(final))


def write_output(mix: np.ndarray, voice: np.ndarray, loudness: str | float | None,
                 wav_out: Path, log=print) -> float:
    """Gain-stage the final mix and write it atomically to wav_out.

    Returns the linear gain that maps `mix` onto the written file — the stems
    directory scales its previews by it so the app can reproduce the output.
    """
    with atomic.replacing(wav_out) as tmp:
        return write_mix(mix, dsp.active_speech_db(voice), loudness, tmp, log)


def write_mix(mix: np.ndarray, voice_db: float, loudness: str | float | None,
              path: Path, log=print) -> float:
    """write_output without the atomic rename: writes straight to `path`.
    `voice_db` is dsp.active_speech_db of the voice channel (used by "auto")."""
    if loudness == "auto" and voice_db < SPEECH_FLOOR_DB:
        log(f"  (no speech found at {voice_db:.0f} dB; auto gain skipped)")
        loudness = None
    if loudness == "auto":
        # Match Adobe: gain the mix so ACTIVE speech hits the target level.
        g_db = min(SPEECH_ACTIVE_TARGET_DB - voice_db, MAX_AUTO_GAIN_DB)
        gain = 10 ** (g_db / 20)
        gained = mix * gain
        peak = _peak(gained) or 1.0
        if peak > 0.99:  # keep true-peak headroom; trade a hair of loudness for no clipping
            gained *= 0.99 / peak
            gain *= 0.99 / peak
            log(f"  (auto gain {g_db:+.1f} dB, peak-limited by {20*np.log10(peak/0.99):.1f} dB)")
        else:
            log(f"  (auto gain {g_db:+.1f} dB)")
        A.write_wav(path, gained)
        return float(gain)
    if isinstance(loudness, (int, float)):
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            tmp_float = Path(tf.name)
        try:
            A.write_wav(tmp_float, mix, subtype="FLOAT")
            A.loudness_normalize(tmp_float, path, float(loudness))
            normalized = True
        except A.FfmpegError:
            # A mix entirely under loudnorm's -70 LUFS gate measures -inf, which
            # its second pass rejects. Nothing there to normalize: keep its level.
            if math.isfinite(A.integrated_lufs(tmp_float)):
                raise
            log(f"  (too quiet to normalize to {float(loudness):g} LUFS; level kept)")
            normalized = False
        finally:
            tmp_float.unlink(missing_ok=True)
        if normalized:
            # loudnorm in linear mode is a pure gain; recover it from the file.
            written, _ = sf.read(str(path), dtype="float32")
            n = min(len(written), len(mix))
            energy = float(np.dot(mix[:n], mix[:n]))
            return float(np.dot(written[:n], mix[:n])) / energy if energy > 0 else 1.0
    gain = 1.0
    peak = _peak(mix) or 1.0
    if peak > 0.99:
        gain = 0.99 / peak
        mix = mix * gain
    A.write_wav(path, mix)
    return gain


def _peak(x: np.ndarray) -> float:
    """float(np.abs(x).max()), without an absolute-value copy of x."""
    return float(max(x.max(), -x.min())) if len(x) else 0.0


def enhance_file(inp: Path, out: Path | None, st: Settings, log=print,
                 report: Reporter | None = None, stems_dir: Path | None = None) -> dict:
    """Enhance one file. `report` receives stage changes for progress display;
    `stems_dir` additionally writes the preview stems + manifest for live remixing."""
    report = report or NullReporter()
    t_all = time.time()
    inp = Path(inp)
    info = A.probe(inp)
    if not info["has_audio"]:
        raise NoAudioError(f"input has no audio stream: {inp}")
    keep_video = info["has_video"] and not st.audio_only
    wav_out, vid_out = output_paths(inp, out)
    finals = [vid_out, wav_out] if keep_video else [wav_out]
    refuse_overwriting_input(inp, finals + kept_stem_paths(st.keep_stems))

    def stage(name):
        st.timings[name] = time.time()

    def done(name):
        st.timings[name] = time.time() - st.timings[name]
        log(f"  {name}: {st.timings[name]:.1f}s")

    report.begin("decode")
    stage("decode")
    orig = A.decode(inp)
    if orig.size == 0:
        raise A.FfmpegError(f"no audio samples could be decoded from {inp}")
    if len(orig) < MIN_SECONDS * A.SR:
        raise TooShortError(f"{inp.name} is too short to enhance. Nothing was changed.")
    done("decode")

    if st.split_music:
        report.begin("separate")
        stage("separate (demucs)")
        from .separate import split_music
        vocals, accomp = split_music(orig, A.SR, device=st.device, progress=st.progress)
        done("separate (demucs)")
    else:
        vocals, accomp = orig, None         # no music channel at all

    music_present = False
    if st.split_music:
        mv_db = dsp.music_to_voice_db(accomp, vocals, A.SR)
        music_present = mv_db >= MUSIC_GATE_DB
        log(f"  (music: {mv_db:.0f} dB re voice — "
            f"{'kept' if music_present else 'none detected, channel muted'})")
    # Music gate: on speech-only content the accompaniment stem is demucs
    # leakage (noise, hum), not music — muting it keeps the music slider from
    # reintroducing hiss. Detected by held-note content, not stem level.
    if not music_present:
        accomp = None                       # a muted channel adds nothing to the mix

    report.begin("restore")
    engine_name = st.engine
    used_engine = st.engine
    key = None              # speech-presence key for the gate (generative engines)
    stage("enhance")
    if st.engine == "sidon":
        try:
            # Raw input restores best — even under loud music (UTMOS 3.55 vs
            # 3.25 on demucs vocals): separation artifacts hurt it more than
            # music does. demucs only feeds the music slider and the gate key.
            clean, key = _restore_sidon(orig, vocals, log, report)
            engine_name = "Sidon"
        except Exception as e:
            log(f"  (sidon unavailable — falling back to mossformer2: {e})")
            st.engine = used_engine = "mossformer2"
            report.switch_engine("mossformer2")
    if key is not None:
        pass                    # restored, aligned and level-matched above
    elif st.engine == "mossformer2":
        try:
            from .engines import mossformer
            clean = mossformer.enhance(vocals, A.SR)
            engine_name = "MossFormer2_SE_48K"
            if st.polish:
                # DF3 pass on the already-clean signal: strips the noise that
                # discriminative models let ride under active speech.
                clean = deepfilter.enhance(clean, A.SR)
                engine_name += "+DF3"
        except Exception as e:
            log(f"  (mossformer2 unavailable — falling back to DeepFilterNet3: {e})")
            used_engine = "df3"
            report.switch_engine("df3")
            clean = deepfilter.enhance(vocals, A.SR)
            engine_name = "DeepFilterNet3 (fallback)"
    else:
        clean = deepfilter.enhance(vocals, A.SR)
        engine_name = "DeepFilterNet3"
    lag = 0
    if key is None:
        lag, clean = dsp.align(vocals, clean)
        if abs(lag) > 0:
            log(f"  (aligned enhance output by {lag} samples)")
        # Least-squares level fit of clean onto vocals: keeps the stem decomposition
        # exact even if the engine's output level drifts from its input.
        s_fit = float(np.dot(vocals, clean)) / (float(np.dot(clean, clean)) + 1e-9)
        if 0.25 < s_fit < 4.0 and abs(s_fit - 1.0) > 0.01:
            clean = (clean * s_fit).astype(np.float32)
    st.timings["enhance"] = time.time() - st.timings["enhance"]
    log(f"  enhance ({engine_name}): {st.timings['enhance']:.1f}s")

    report.begin("cleanup")
    # Resynthesized speech isn't phase-locked to the input, so vocals − clean
    # would be mostly speech; the DF3 residual is the true background stem.
    background = (vocals - (clean if key is None else key)).astype(np.float32, copy=False)
    generative = st.engine in GENERATIVE
    # A DF3 key's gate gain is fixed now; nothing else needs the key.
    gate = voice_gate(st, key, clean) if key is not None else None
    key = None

    # The EQ / rumble gate / air below compensate for what discriminative
    # enhancers strip; generative engines rebuild those themselves.
    if st.match_eq and not generative:
        prof = _load_eq_profile()
        if prof is not None:
            freqs, gain_db = prof
            taps = dsp.design_match_fir(freqs, gain_db, A.SR)
            clean = dsp.apply_fir(clean, taps)

    if st.low_gate and not generative:
        # The match-EQ boosts 40-150 Hz to restore voice body; gate that band on
        # its own envelope so the boost passes voiced lows, not rumble.
        clean = dsp.low_band_gate(clean, A.SR)

    if st.air and not generative:
        # Adobe's regenerative model produces breathy 8-16 kHz air that
        # discriminative enhancers strip; synthesize it at calibrated level.
        clean = dsp.air_exciter(clean, A.SR, AIR_REL_DB)

    if generative and st.declick:
        # Resynthesis rebuilds mouth clicks as sharp full-band bursts.
        clean = dsp.declick(clean, A.SR)
    if generative and st.smooth:
        # Clean up the noise between harmonics that makes a resynthesized
        # voice sound rough/"wobbly" next to Adobe's.
        clean = dsp.harmonic_smooth(clean, A.SR)

    s, b, m = mix_coefficients(st.speech, st.background, st.music, st.linear)
    if gate is None:
        gate = voice_gate(st, None, clean)
    leveler = st.level and not generative   # measured −0.07 UTMOS on Sidon output, which is already level
    voice = s * clean
    voice += (1 - s) * vocals               # in place: the same sum, one array fewer
    voice = gate(voice)
    if leveler:
        voice = dsp.level_voice(voice, A.SR)
    voice_db = dsp.active_speech_db(voice)  # all the writer needs of the voice channel
    mix, voice = voice, None                # the mix is built on the voice, in place
    mix += b * background
    if accomp is not None:
        mix += m * accomp

    report.begin("write")
    wav_out.parent.mkdir(parents=True, exist_ok=True)
    vid_out.parent.mkdir(parents=True, exist_ok=True)

    if st.keep_stems:
        st.keep_stems.mkdir(parents=True, exist_ok=True)
        music = accomp if accomp is not None else np.zeros(len(orig), np.float32)
        for path, sig in zip(kept_stem_paths(st.keep_stems),
                             (clean, background, music, vocals), strict=True):
            A.write_wav(path, sig)
        del music

    # The wav and the video appear together, after the stems, or not at all:
    # a cancel or a failed remux leaves nothing beside the input.
    with atomic.transaction(finals) as partials:
        wav_tmp = partials[-1]
        stage("gain + write")
        gain = write_mix(mix, voice_db, st.loudness, wav_tmp, log)
        done("gain + write")
        # Only the output's level is needed from here on.
        output_db = dsp.active_speech_db(mix, scale=gain) if stems_dir is not None else 0.0
        del mix

        result = {"wav": wav_out, "video": None, "lag": lag, "engine": used_engine,
                  "music": bool(music_present), "stems": None, "gain": gain,
                  "total": time.time() - t_all}

        if keep_video:
            stage("remux video")
            A.remux(inp, wav_tmp, partials[0], crf=st.crf)
            result["video"] = vid_out
            done("remux video")

        if stems_dir is not None:
            previews = stemsdir.make_previews(
                clean=clean, vocals=vocals, background=background,
                music=accomp if music_present else None, original=orig,
                gate=gate, gain=gain, output_db=output_db)
            stemsdir.write_stems_dir(Path(stems_dir), previews, stemsdir.manifest(
                inp=inp, duration=len(orig) / A.SR, has_video=info["has_video"],
                engine=used_engine, generative=generative, music=music_present,
                wav=wav_out, video=result["video"],
                speech=st.speech, background=st.background, music_level=st.music,
                linear=st.linear, level=leveler, loudness=st.loudness, crf=st.crf,
                audio_only=st.audio_only))
            result["stems"] = Path(stems_dir)

    result["total"] = time.time() - t_all
    return result
