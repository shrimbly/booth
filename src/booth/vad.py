"""Speech presence from Silero VAD 6.2.3 (MIT), run with onnxruntime.

`data/silero_vad.onnx` is the model from the silero-vad package. It tells
breaths and mouth noise from quiet speech by context, which level and pitch
alone can't: the breath remover (dsp.breath_gain) asks it before it takes
anything out of the voice.
"""

from __future__ import annotations

import importlib.resources

import numpy as np
from scipy import signal

RATE = 16000                # the model's rate
CHUNK = 512                 # samples per answer: 32 ms
CONTEXT = 64                # the end of the last chunk, fed in front of the next
HOP_S = CHUNK / RATE
_BLOCK = 1875               # chunks resampled at a time: 60 s


def speech_probability(x: np.ndarray, sr: int = 48000) -> np.ndarray:
    """The probability of speech in each 32 ms of `x`, from the start."""
    import onnxruntime as ort

    ref = importlib.resources.files("booth") / "data" / "silero_vad.onnx"
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = opts.inter_op_num_threads = 1   # one chunk at a time
    with importlib.resources.as_file(ref) as path:
        session = ort.InferenceSession(str(path), opts, providers=["CPUExecutionProvider"])

    step = sr // RATE
    n = len(x) // step // CHUNK
    probs = np.empty(n, np.float32)
    state = np.zeros((2, 1, 128), np.float32)
    context = np.zeros((1, CONTEXT), np.float32)
    rate = np.array(RATE, dtype=np.int64)
    margin = 64 * step                          # the resampler's reach
    for c0 in range(0, n, _BLOCK):
        c1 = min(n, c0 + _BLOCK)
        a, b = c0 * CHUNK * step, c1 * CHUNK * step
        s0, s1 = max(0, a - margin), min(len(x), b + margin)
        y = signal.resample_poly(x[s0:s1].astype(np.float64), 1, step).astype(np.float32)
        y = y[(a - s0) // step:(a - s0) // step + (c1 - c0) * CHUNK]
        for i in range(c1 - c0):
            chunk = np.concatenate([context, y[None, i * CHUNK:(i + 1) * CHUNK]], axis=1)
            out, state = session.run(None, {"input": chunk, "state": state, "sr": rate})
            context = chunk[:, -CONTEXT:]
            probs[c0 + i] = out[0, 0]
    return probs
