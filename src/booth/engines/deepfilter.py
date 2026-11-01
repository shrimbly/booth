"""Speech enhancement via DeepFilterNet3 (48 kHz native), on onnxruntime.

The network is `data/deepfilternet3.onnx`, exported from the DeepFilterNet3
checkpoint (MIT or Apache 2.0) by scripts/export-deepfilternet3.py: its
convolutions, GRUs and output layers. Everything around it is numpy, computed
as libdf and df.enhance do: the STFT, the ERB and complex features with their
running normalization, the ERB mask, deep filtering, the post-filter and the
inverse STFT. It matches the torch model to float rounding (−106 dB or less)
without torch.

DF3 is causal apart from two frames of lookahead, so it runs block by block
with all of its state carried across blocks — STFT overlap, feature
normalization, GRU states and the conv context — and gives the same output as
one whole-file pass with memory that does not grow with the input length.
"""

from __future__ import annotations

import importlib.resources
import math

import numpy as np
from scipy import signal

SR = 48000
N_FFT = 960
HOP = 480
NB_DF = 96                  # bins the deep filter covers
DF_ORDER = 5                # taps: two past frames, this one, two ahead
ERB_WIDTHS = np.array([2] * 13 + [5, 5, 7, 7, 8, 10, 12, 13, 15, 18, 20, 24, 28, 31, 37, 42, 50, 56, 67])
ALPHA = np.float32(0.99)    # feature normalization: exp(-hop / sr / 1 s), as df rounds it
PF_BETA = 0.02              # post-filter strength (Valin et al.)
HIDDEN = 256

# DF3 outputs digital silence when active speech is below about -47 dBFS, so quieter
# input is raised to a typical level for the model and its output lowered to match.
QUIET_SPEECH_DB = -40.0
MODEL_SPEECH_DB = -26.0
MAX_LIFT_DB = 40.0

BLOCK_FRAMES = 1000         # 10 s of 10 ms frames per model call
CONTEXT_FRAMES = 6          # past frames the convs need: 3-frame input conv + 5-frame DF pathway
LOOKAHEAD_FRAMES = 2        # future frames: feature lookahead and DF lookahead

_session = None


def _init():
    global _session
    if _session is None:
        import onnxruntime as ort
        ref = importlib.resources.files("booth") / "data" / "deepfilternet3.onnx"
        with importlib.resources.as_file(ref) as path:
            _session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    return _session


def enhance(audio: np.ndarray, sr: int) -> np.ndarray:
    """Denoise mono float32 speech at 48 kHz. Returns clean speech, same length."""
    assert sr == SR, f"DeepFilterNet runs at {SR} Hz, got {sr}"
    lift = _lift(audio, sr)
    if lift != 1.0:
        audio = audio * lift
    out = _Stream(_init()).run(np.asarray(audio, dtype=np.float32))
    return out / lift if lift != 1.0 else out


def _lift(audio: np.ndarray, sr: int) -> float:
    """The gain that brings quiet speech up to MODEL_SPEECH_DB (1.0 when it isn't quiet,
    or is silence), never past full scale."""
    from .. import dsp

    level = dsp.active_speech_db(audio, sr)
    if not -120.0 < level < QUIET_SPEECH_DB:
        return 1.0
    lift = 10 ** (min(MODEL_SPEECH_DB - level, MAX_LIFT_DB) / 20)
    peak = float(np.abs(audio).max())
    return float(min(lift, 0.99 / peak)) if peak > 0 else 1.0


# libdf's Vorbis window, and where each ERB band starts.
_WINDOW = np.sin(0.5 * np.pi * np.sin(np.pi * (np.arange(N_FFT) + 0.5) / N_FFT) ** 2).astype(np.float32)
_EDGES = np.concatenate([[0], np.cumsum(ERB_WIDTHS)[:-1]])


class _Stream:
    """df.enhance.enhance(model, df_state, audio, pad=True), one block at a time.

    Output frame t depends on spectrum frames t-2..t+2, on feature frames
    t-6..t+2 through the convolutions, and on every earlier frame through the
    GRUs and the running feature normalization. Each block feeds the model its
    frames plus that context, carries the GRU states and normalization states
    to the next block, and keeps only its own frames.
    """

    def __init__(self, session):
        self.session = session
        # libdf's initial normalization states.
        lo, hi = np.float32(-60.0), np.float32(-90.0)
        nb_erb = len(ERB_WIDTHS)
        self.erb_state = lo + (hi - lo) / np.float32(nb_erb - 1) * np.arange(nb_erb, dtype=np.float32)
        self.unit_state = np.linspace(0.001, 0.0001, NB_DF, dtype=np.float32)
        self.h = {"h_enc": np.zeros((1, 1, HIDDEN), np.float32),
                  "h_erb": np.zeros((2, 1, HIDDEN), np.float32),
                  "h_df": np.zeros((2, 1, HIDDEN), np.float32)}

    def run(self, audio: np.ndarray) -> np.ndarray:
        # pad=True: the input runs on for one FFT of silence, and the STFT starts
        # one hop early, so frame k covers padded samples [(k-1)*hop, (k+1)*hop).
        x = _Padded(audio)
        total = (len(audio) + N_FFT) // HOP
        out = np.zeros(len(audio), np.float32)
        delay = N_FFT - HOP          # the STFT/ISTFT loop's algorithmic delay
        tail = np.zeros(N_FFT - HOP, np.float32)   # the last frame's overlap, not yet added
        frames = _Frames()
        for s in range(0, total, BLOCK_FRAMES):
            e = min(total, s + BLOCK_FRAMES)
            want = min(total, e + LOOKAHEAD_FRAMES)
            if frames.end < want:
                self._analyze(frames, x, frames.end, want)
            frames.drop_before(s - CONTEXT_FRAMES)
            spec_e = self._forward(frames, s, e)
            y = np.fft.irfft(spec_e, n=N_FFT, axis=1).astype(np.float32) * np.float32(N_FFT) * _WINDOW
            hops = y[:, :HOP].copy()
            hops[0] += tail
            hops[1:] += y[:-1, HOP:]
            tail = y[-1, HOP:].copy()
            a = s * HOP - delay       # where this block's samples land in the output
            y = hops.reshape(-1)
            lo, hi = max(0, a), min(len(audio), a + len(y))
            if hi > lo:
                out[lo:hi] = y[lo - a:hi - a]
        return out

    def _analyze(self, frames: _Frames, x: _Padded, f0: int, f1: int) -> None:
        """Analyze frames [f0, f1) of the padded input and normalize their features."""
        windows = np.lib.stride_tricks.sliding_window_view(x.slice(f0 * HOP, (f1 + 1) * HOP), N_FFT)[::HOP]
        spec = (np.fft.rfft(windows * _WINDOW, axis=1) / N_FFT).astype(np.complex64)   # [T, F]
        # Both normalizations are running means, mean = alpha * mean + (1 - alpha) * x.
        a, b = [np.float32(1.0), -ALPHA], [np.float32(1.0) - ALPHA]
        power = spec.real ** 2 + spec.imag ** 2
        erb_db = 10 * np.log10(np.add.reduceat(power, _EDGES, axis=1) / ERB_WIDTHS.astype(np.float32)
                               + np.float32(1e-10))
        erb_mean, _ = signal.lfilter(b, a, erb_db, axis=0, zi=(ALPHA * self.erb_state)[None])
        self.erb_state = erb_mean[-1]
        erb_feat = ((erb_db - erb_mean) / np.float32(40.0)).astype(np.float32)
        low = spec[:, :NB_DF]
        unit_mean, _ = signal.lfilter(b, a, np.abs(low), axis=0, zi=(ALPHA * self.unit_state)[None])
        self.unit_state = unit_mean[-1]
        unit_feat = (low / np.sqrt(unit_mean)).astype(np.complex64)
        frames.append(spec, erb_feat, unit_feat)

    def _forward(self, frames: _Frames, s: int, e: int) -> np.ndarray:
        """Enhanced spectrum of frames [s, e) as [e-s, F] complex64."""
        lo, hi = frames.start, frames.end            # frames fed: [s - context, e + lookahead)
        j0, n = s - lo, e - s                        # this block's frames within them
        w = hi - lo
        # The model shifts features left by the lookahead and zero-fills the end.
        # Inside the file the zero-filled frames are lookahead context only; the
        # last block ends at the file's end, where the whole-file pass pads too.
        feat_erb = np.zeros((1, 1, w, len(ERB_WIDTHS)), np.float32)
        feat_spec = np.zeros((1, 2, w, NB_DF), np.float32)
        feat_erb[0, 0, :w - LOOKAHEAD_FRAMES] = frames.erb[LOOKAHEAD_FRAMES:]
        feat_spec[0, 0, :w - LOOKAHEAD_FRAMES] = frames.unit[LOOKAHEAD_FRAMES:].real
        feat_spec[0, 1, :w - LOOKAHEAD_FRAMES] = frames.unit[LOOKAHEAD_FRAMES:].imag
        mask, coefs, h_enc, h_erb, h_df = self.session.run(None, {
            "feat_erb": feat_erb, "feat_spec": feat_spec,
            "core": np.arange(j0, j0 + n, dtype=np.int64), **self.h})
        self.h = {"h_enc": h_enc, "h_erb": h_erb, "h_df": h_df}

        spec = frames.spec
        spec_core = spec[j0:j0 + n]
        spec_e = spec_core * np.repeat(mask[0, 0], ERB_WIDTHS, axis=1)          # the ERB mask
        # Deep filtering of the low bins: each output frame is a complex FIR over
        # spectrum frames t-2..t+2 (zero outside the frames fed, as the model pads).
        taps = np.ascontiguousarray(coefs[0]).reshape(n, NB_DF, DF_ORDER, 2).view(np.complex64)[..., 0]
        padded = np.zeros((w + DF_ORDER - 1, NB_DF), np.complex64)
        before = DF_ORDER - 1 - LOOKAHEAD_FRAMES
        padded[before:before + w] = spec[:, :NB_DF]
        filtered = np.zeros((n, NB_DF), np.complex64)
        for o in range(DF_ORDER):
            filtered += padded[j0 + o:j0 + o + n] * taps[..., o]
        spec_e[:, :NB_DF] = filtered

        # The post-filter: a little more attenuation where the model already attenuates.
        eps = np.float32(1e-12)
        pf_mask = np.clip(np.abs(spec_e) / (np.abs(spec_core) + eps), eps, 1)
        mask_sin = pf_mask * np.maximum(np.sin(np.float32(math.pi) * pf_mask / 2), eps)
        pf = (1 + PF_BETA) / (1 + PF_BETA * (pf_mask / mask_sin) ** 2)
        return (spec_e * pf.astype(np.float32)).astype(np.complex64)


class _Padded:
    """`audio` with a hop of silence before it and an FFT's worth after, sliced on demand."""

    def __init__(self, audio: np.ndarray):
        self.audio = audio

    def slice(self, a: int, b: int) -> np.ndarray:
        out = np.zeros(b - a, np.float32)
        lo, hi = max(a - HOP, 0), min(b - HOP, len(self.audio))
        if hi > lo:
            out[lo - (a - HOP):hi - (a - HOP)] = self.audio[lo:hi]
        return out


class _Frames:
    """A sliding window of analyzed frames: spectrum and normalized features."""

    def __init__(self):
        self.start = self.end = 0
        self.spec = self.erb = self.unit = None

    def append(self, spec: np.ndarray, erb: np.ndarray, unit: np.ndarray) -> None:
        if self.spec is None:
            self.spec, self.erb, self.unit = spec, erb, unit
        else:
            self.spec = np.concatenate([self.spec, spec])
            self.erb = np.concatenate([self.erb, erb])
            self.unit = np.concatenate([self.unit, unit])
        self.end += len(spec)

    def drop_before(self, frame: int) -> None:
        k = max(0, frame - self.start)
        if k:
            self.spec, self.erb, self.unit = self.spec[k:], self.erb[k:], self.unit[k:]
            self.start += k
