"""DNSMOS P.835 perceptual scoring (Microsoft DNS-Challenge onnx model).

Predicts MOS for speech quality (SIG), background intrusiveness (BAK), and
overall (OVRL) — the standard objective stand-in for human listening tests.
Model (~1 MB) downloads to ~/.cache/booth on first use.
"""

from __future__ import annotations

import hashlib
import urllib.request
from pathlib import Path

import numpy as np

from . import atomic

MODEL_URL = ("https://github.com/microsoft/DNS-Challenge/raw/master/"
             "DNSMOS/DNSMOS/sig_bak_ovr.onnx")
# The model the output mapping below belongs to; anything else is fetched again.
MODEL_SHA256 = "269fbebdb513aa23cddfbb593542ecc540284a91849ac50516870e1ac78f6edd"
CACHE = Path.home() / ".cache" / "booth" / "sig_bak_ovr.onnx"
FS = 16000
SEG = int(9.01 * FS)          # 144160 samples per model window
HOP = FS                      # 1 s hop

# Non-personalized output mapping (from dnsmos_local.py)
P_SIG = np.poly1d([-0.08397278, 1.22083953, 0.0052439])
P_BAK = np.poly1d([-0.13166888, 1.60915514, -0.39604546])
P_OVR = np.poly1d([-0.06766283, 1.11546468, 0.04602535])

_session = None


def _get_session():
    global _session
    if _session is None:
        import onnxruntime as ort
        if not _cached_model_ok():
            _download_model()
        _session = ort.InferenceSession(str(CACHE), providers=["CPUExecutionProvider"])
    return _session


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _cached_model_ok() -> bool:
    """True if the cached model is intact; a cut-off or different one is deleted."""
    try:
        if _sha256(CACHE) == MODEL_SHA256:
            return True
        CACHE.unlink()
    except FileNotFoundError:
        pass
    return False


def _download_model() -> None:
    """Download beside the cache path; only a complete, matching file replaces it."""
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    with atomic.replacing(CACHE) as tmp:
        urllib.request.urlretrieve(MODEL_URL, tmp)
        if _sha256(tmp) != MODEL_SHA256:
            raise RuntimeError(f"DNSMOS model download doesn't match its checksum ({MODEL_URL})")


def score(audio: np.ndarray, sr: int = 48000) -> dict:
    """DNSMOS {'sig','bak','ovr'} for mono float32 audio at sr."""
    import julius
    import torch

    x = julius.resample_frac(torch.from_numpy(audio.astype(np.float32))[None],
                             sr, FS).squeeze(0).numpy()
    if len(x) < SEG:
        x = np.pad(x, (0, SEG - len(x)))
    sess = _get_session()

    sig, bak, ovr = [], [], []
    n_segs = max(1, (len(x) - SEG) // HOP + 1)
    for i in range(n_segs):
        seg = x[i * HOP: i * HOP + SEG]
        if len(seg) < SEG:
            break
        out = sess.run(None, {"input_1": seg[np.newaxis, :].astype(np.float32)})[0][0]
        sig.append(float(P_SIG(out[0])))
        bak.append(float(P_BAK(out[1])))
        ovr.append(float(P_OVR(out[2])))
    return {"sig": float(np.mean(sig)), "bak": float(np.mean(bak)),
            "ovr": float(np.mean(ovr))}
