"""Score candidate outputs against Adobe references on the benchmark clips.

For each clip id and each variant tag, reads test-output/bench/<clip>_<tag>.wav
and reports:
  - DNSMOS P.835 (ovr/sig/bak) — perceptual quality, noise intrusiveness
  - UTMOS (utmos22 strong, 10 s-window mean) — naturalness MOS, sensitive to
    artifacts/muffling
  - mel-LSD vs Adobe — log-mel spectral distance after active-level matching
    (how close the timbre/texture is to Adobe's output; lower is better)
  - gap floor — noise level in speech gaps relative to active speech (dB)
  - octave-band deltas vs Adobe (dB)

Usage: uv run python scripts/bench.py <tag> [<tag> ...]   (tag "adobe" and
"in" are the reference and the original)
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from scipy import signal

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from booth import audio as A          # noqa: E402
from booth import dsp, mos            # noqa: E402
from booth.eval import BANDS, band_energies_db  # noqa: E402

B = Path(__file__).resolve().parents[1] / "test-output" / "bench"
CLIPS = ["njt", "ww", "cr", "nb"]

_utmos = None


def utmos(x: np.ndarray) -> float:
    global _utmos
    import torch
    import julius
    if _utmos is None:
        _utmos = torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong",
                                trust_repo=True)
    # Mean over 10 s windows (5 s hop): whole-file scores are noisy, and long
    # inputs are out of UTMOS's training distribution.
    w = julius.resample_frac(torch.from_numpy(x.astype(np.float32))[None], 48000, 16000)[0]
    win, hop = 160000, 80000
    segs = [w[i:i + win] for i in range(0, max(1, len(w) - win + 1), hop)] or [w]
    with torch.no_grad():
        return float(np.mean([float(_utmos(s[None], 16000).mean()) for s in segs]))


def mel_db(x: np.ndarray, sr: int = 48000) -> np.ndarray:
    n_fft, hop, n_mels = 2048, 480, 96
    f, _, Z = signal.stft(x, fs=sr, nperseg=n_fft, noverlap=n_fft - hop)
    p = np.abs(Z) ** 2
    # triangular mel filterbank 50 Hz..20 kHz
    mel = lambda hz: 2595 * np.log10(1 + hz / 700)
    imel = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = imel(np.linspace(mel(50), mel(20000), n_mels + 2))
    fb = np.zeros((n_mels, len(f)))
    for i in range(n_mels):
        lo, c, hi = pts[i], pts[i + 1], pts[i + 2]
        fb[i] = np.clip(np.minimum((f - lo) / (c - lo), (hi - f) / (hi - c)), 0, None)
    return 10 * np.log10(fb @ p + 1e-10)


def mel_lsd(test: np.ndarray, ref: np.ndarray) -> float:
    """RMS log-mel difference over ref's speech-active frames (dB)."""
    mt, mr = mel_db(test), mel_db(ref)
    n = min(mt.shape[1], mr.shape[1])
    mt, mr = mt[:, :n], mr[:, :n]
    e = mr.mean(axis=0)
    act = e >= np.quantile(e, 0.5)
    return float(np.sqrt(((mt[:, act] - mr[:, act]) ** 2).mean()))


def gap_floor(x: np.ndarray, sr: int = 48000) -> float:
    n = sr // 50
    k = len(x) // n
    db = 10 * np.log10((x[:k * n].reshape(k, n) ** 2).mean(axis=1) + 1e-14)
    return float(np.quantile(db, 0.10) - np.quantile(db, 0.90))


def level_match(x: np.ndarray, target_db: float = -26.0) -> np.ndarray:
    return x * 10 ** ((target_db - dsp.active_speech_db(x)) / 20)


def main() -> int:
    tags = sys.argv[1:] or ["in", "adobe"]
    rows = []
    for clip in CLIPS:
        ref = level_match(A.decode(B / f"{clip}_adobe.wav"))
        eb_ref = band_energies_db(ref, 48000)
        for tag in tags:
            p = B / f"{clip}_{tag}.wav"
            if not p.exists():
                continue
            x = A.decode(p)
            x = dsp.shift(x, dsp.envelope_lag(ref, x))
            n = min(len(x), len(ref))
            x = level_match(x[:n])
            m = mos.score(x)
            eb = band_energies_db(x, 48000)
            rows.append((clip, tag, m["ovr"], m["sig"], m["bak"], utmos(x),
                         mel_lsd(x, ref[:n]), gap_floor(x),
                         [eb[f] - eb_ref[f] for f in BANDS]))
    hdr = f"{'clip':5s} {'tag':18s} {'OVR':>5s} {'SIG':>5s} {'BAK':>5s} {'UTMOS':>6s} {'LSD':>5s} {'gap':>6s}  " \
          + " ".join(f"{b if b < 1000 else str(b // 1000) + 'k':>5}" for b in BANDS)
    print(hdr)
    for r in rows:
        print(f"{r[0]:5s} {r[1]:18s} {r[2]:5.2f} {r[3]:5.2f} {r[4]:5.2f} {r[5]:6.2f} {r[6]:5.2f} {r[7]:6.1f}  "
              + " ".join(f"{d:+5.1f}" for d in r[8]))
    # per-tag means
    print()
    for tag in tags:
        sel = [r for r in rows if r[1] == tag]
        if sel:
            a = np.array([r[2:8] for r in sel])
            mu = a.mean(axis=0)
            print(f"{'mean':5s} {tag:18s} {mu[0]:5.2f} {mu[1]:5.2f} {mu[2]:5.2f} {mu[3]:6.2f} {mu[4]:5.2f} {mu[5]:6.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
