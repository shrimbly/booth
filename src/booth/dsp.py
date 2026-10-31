"""DSP helpers: alignment, SI-SDR, spectrum analysis, and match-EQ filtering.

Everything on the enhance path works through long signals a block at a time
(BLOCK samples plus a margin wide enough for the filter or transform), so its
memory stays flat however long the input is. Block results match a whole-file
pass to float rounding: margins outlast every filter's reach, STFT blocks are
frame-aligned, and statistics that span the whole file (quantiles, means) are
gathered first and applied afterwards.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator

import numpy as np
from scipy import fft as sp_fft
from scipy import signal

BLOCK = 30 * 48000          # samples per block for long signals


def _spans(n: int, block: int = BLOCK, align: int = 1) -> list[tuple[int, int]]:
    """Consecutive [a, b) spans covering [0, n); each start is a multiple of `align`."""
    step = max(align, block // align * align)
    return [(a, min(n, a + step)) for a in range(0, n, step)]


def _mean_square(x: np.ndarray, frame: int, k: int, scale: float = 1.0) -> np.ndarray:
    """((x * scale)[:k*frame].reshape(k, frame) ** 2).mean(axis=1), without forming
    the scaled or squared signal all at once."""
    out = np.empty(k, dtype=np.result_type(x.dtype, np.float32))
    per = max(1, BLOCK // frame)
    for i in range(0, k, per):
        j = min(k, i + per)
        blk = x[i * frame:j * frame]
        if scale != 1.0:
            blk = blk * scale
        out[i:j] = (blk.reshape(j - i, frame) ** 2).mean(axis=1)
    return out


def _apply_gain(x: np.ndarray, gain_at: Callable[[int, int], np.ndarray]) -> np.ndarray:
    """(x * gain).astype(float32), where gain_at(a, b) is the gain of samples [a, b)."""
    out = np.empty(len(x), np.float32)
    for a, b in _spans(len(x)):
        out[a:b] = x[a:b] * gain_at(a, b)
    return out


def _stft_frames(x: np.ndarray, sr: int, nperseg: int,
                 hop: int) -> Iterator[tuple[int, np.ndarray, np.ndarray]]:
    """Yield (k0, f, Z): Z[:, j] is frame k0 + j of
    signal.stft(x, sr, nperseg=nperseg, noverlap=nperseg - hop), block by block."""
    n = len(x)
    total = -(-n // hop) + 1                     # frames of the whole-file transform
    reach = -(-(nperseg // 2) // hop) * hop      # half a window, rounded up to whole hops
    per = max(1, BLOCK // hop)
    for k0 in range(0, total, per):
        k1 = min(total, k0 + per)
        s1 = min(n, (k1 - 1) * hop + reach)
        # At least one whole window, or stft would shrink it (the last frames are padding).
        s0 = max(0, min(k0 * hop - reach, (s1 - nperseg) // hop * hop))
        f, _, Z = signal.stft(x[s0:s1], sr, nperseg=nperseg, noverlap=nperseg - hop)
        j0 = k0 - s0 // hop
        yield k0, f, Z[:, j0:j0 + k1 - k0]


def _stft_filter(x: np.ndarray, sr: int, nperseg: int, hop: int,
                 modify: Callable[[np.ndarray, int], None]) -> np.ndarray:
    """istft(modify(stft(x))) trimmed or zero-padded to len(x), block by block.

    modify(Z, k0) edits a block's frames in place; Z[:, j] is frame k0 + j of
    the whole-file transform. Frames at a block's edges see zeros instead of
    signal, but they only reach samples in the margin, which the neighbouring
    block recomputes — so if modify depends only on the frame index (and on
    its next neighbours), the result matches the whole-file transform.
    """
    n = len(x)
    margin = -(-2 * nperseg // hop) * hop        # a window plus room for neighbour smoothing
    out = np.zeros(n, np.float32)
    for a, b in _spans(n, align=hop):
        s0, s1 = max(0, a - margin), min(n, b + margin)
        _, _, Z = signal.stft(x[s0:s1], sr, nperseg=nperseg, noverlap=nperseg - hop)
        modify(Z, s0 // hop)
        _, y = signal.istft(Z, sr, nperseg=nperseg, noverlap=nperseg - hop)
        seg = y[a - s0:b - s0]
        out[a:a + len(seg)] = seg
    return out


def _fir_span(src: np.ndarray, src_start: int, taps: np.ndarray, a: int, b: int) -> np.ndarray:
    """Samples [a, b) of apply_fir's output. `src` holds the input from sample
    `src_start` on; the input counts as zero wherever `src` has no samples."""
    k = len(taps)
    delay = k // 2
    lo, hi = a + delay - k + 1, b + delay                 # input samples the span needs
    seg = np.zeros(hi - lo)
    s0, s1 = max(lo, src_start), min(hi, src_start + len(src))
    if s1 > s0:
        seg[s0 - lo:s1 - lo] = src[s0 - src_start:s1 - src_start]
    return signal.fftconvolve(seg, taps, mode="valid").astype(np.float32)


class _NoiseStream:
    """np.random.default_rng(seed).standard_normal(n), read in windows that move forward."""

    def __init__(self, seed: int):
        self._rng = np.random.default_rng(seed)
        self._buf = np.zeros(0)
        self._start = 0

    def take(self, a: int, b: int) -> np.ndarray:
        end = self._start + len(self._buf)
        if b > end:
            self._buf = np.concatenate([self._buf, self._rng.standard_normal(b - end)])
        self._buf, self._start = self._buf[a - self._start:], a
        return self._buf[:b - a]


def align(ref: np.ndarray, x: np.ndarray, sr: int = 48000,
          max_lag: int = 4800, window_s: float = 30.0) -> tuple[int, np.ndarray]:
    """Shift x so it best aligns with ref (searching ±max_lag samples).

    Uses FFT cross-correlation on a window from the middle of the signals.
    Returns (lag, aligned_x): lag > 0 means x was late relative to ref.
    """
    n = min(len(ref), len(x))
    w = int(min(window_s * sr, n))
    start = (n - w) // 2
    a = ref[start:start + w].astype(np.float64)
    b = x[start:start + w].astype(np.float64)
    corr = signal.fftconvolve(a, b[::-1], mode="full")
    center = len(b) - 1
    lo = max(0, center - max_lag)
    hi = min(len(corr), center + max_lag + 1)
    lag = int(np.argmax(corr[lo:hi])) + lo - center
    return lag, shift(x, lag)


def envelope_lag(ref: np.ndarray, x: np.ndarray, sr: int = 48000,
                 max_lag: int = 4800) -> int:
    """Lag of x relative to ref from speech-band envelopes (phase-independent).

    Waveform cross-correlation locks onto wrong periodic peaks when x was
    resynthesized by a generative model (phase is regenerated); the 300 Hz-4 kHz
    amplitude envelope survives resynthesis. Returns k such that shift(x, k)
    aligns x to ref (k > 0: x was late). The envelopes are built, and the ±max_lag
    correlation summed, a block at a time.
    """
    sos_b = signal.butter(4, [300, 4000], btype="band", fs=sr, output="sos")
    sos_l = signal.butter(2, 200, fs=sr, output="sos")
    n = min(len(ref), len(x))
    margin = sr // 4                        # both filters settle within a few ms

    def env(y, r0, r1):
        """Samples [r0, r1) of sosfiltfilt(sos_l, |sosfilt(sos_b, y[:n])|)."""
        s0, s1 = max(0, r0 - margin), min(n, r1 + margin)
        u = np.abs(signal.sosfilt(sos_b, y[s0:s1].astype(np.float64)))
        return signal.sosfiltfilt(sos_l, u)[r0 - s0:r1 - s0]

    spans = _spans(n)
    mean_a = sum(float(env(ref, a, b).sum()) for a, b in spans) / n
    mean_b = sum(float(env(x, a, b).sum()) for a, b in spans) / n
    lag = min(max_lag, n - 1)
    corr = np.zeros(2 * lag + 1)            # corr[k + lag] = sum_t b[t + k] * a[t]
    for t0, t1 in spans:
        seg = np.zeros(t1 - t0 + 2 * lag)
        s0, s1 = max(0, t0 - lag), min(n, t1 + lag)
        seg[s0 - (t0 - lag):s1 - (t0 - lag)] = env(x, s0, s1) - mean_b
        corr += signal.correlate(seg, env(ref, t0, t1) - mean_a, mode="valid", method="fft")
    return int(np.argmax(corr)) - lag


def shift(x: np.ndarray, k: int) -> np.ndarray:
    """Shift left by k (k>0: x was late — drop head, pad tail)."""
    if k == 0:
        return x
    if k > 0:
        return np.concatenate([x[k:], np.zeros(k, dtype=x.dtype)])
    return np.concatenate([np.zeros(-k, dtype=x.dtype), x[:k]])


def si_sdr(est: np.ndarray, ref: np.ndarray, eps: float = 1e-9) -> float:
    """Scale-invariant SDR of est against ref, in dB."""
    n = min(len(est), len(ref))
    est = est[:n].astype(np.float64) - est[:n].mean()
    ref = ref[:n].astype(np.float64) - ref[:n].mean()
    s = (np.dot(est, ref) / (np.dot(ref, ref) + eps)) * ref
    e = est - s
    return float(10 * np.log10((np.dot(s, s) + eps) / (np.dot(e, e) + eps)))


def active_spectrum(x: np.ndarray, sr: int, nfft: int = 4096,
                    keep: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """Average power spectrum over the loudest `keep` fraction of frames (speech-active)."""
    hop = nfft // 2
    f, _, Z = signal.stft(x, fs=sr, nperseg=nfft, noverlap=nfft - hop, padded=False)
    power = (np.abs(Z) ** 2)
    frame_e = power.sum(axis=0)
    thresh = np.quantile(frame_e, 1.0 - keep)
    mask = frame_e >= thresh
    if mask.sum() == 0:
        mask[:] = True
    return f, power[:, mask].mean(axis=1)


def octave_smooth(freqs: np.ndarray, mag_db: np.ndarray, frac: float = 6.0) -> np.ndarray:
    """Smooth a dB spectrum with a 1/frac-octave sliding window (log-frequency domain)."""
    out = np.copy(mag_db)
    for i, f0 in enumerate(freqs):
        if f0 <= 0:
            continue
        lo, hi = f0 * 2 ** (-0.5 / frac), f0 * 2 ** (0.5 / frac)
        sel = (freqs >= lo) & (freqs <= hi)
        out[i] = mag_db[sel].mean()
    return out


def design_match_fir(freqs: np.ndarray, gain_db: np.ndarray, sr: int,
                     ntaps: int = 2047) -> np.ndarray:
    """Linear-phase FIR whose magnitude follows gain_db over freqs."""
    grid = np.concatenate([[0.0], freqs, [sr / 2]])
    gains = np.concatenate([[gain_db[0]], gain_db, [gain_db[-1]]])
    # firwin2 needs strictly increasing normalized freqs in [0, 1]
    norm = grid / (sr / 2)
    norm, idx = np.unique(np.clip(norm, 0, 1), return_index=True)
    lin = 10 ** (gains[idx] / 20)
    return signal.firwin2(ntaps, norm, lin)


def apply_fir(x: np.ndarray, taps: np.ndarray) -> np.ndarray:
    """Zero-latency application of a linear-phase FIR (compensates group delay)."""
    out = np.empty(len(x), np.float32)
    for a, b in _spans(len(x)):
        out[a:b] = _fir_span(x, 0, taps, a, b)
    return out


def gap_expander(voice: np.ndarray, key: np.ndarray, sr: int,
                 max_atten_db: float = 10.0, thresh_rel_db: float = -38.0,
                 attack_ms: float = 8.0, release_ms: float = 220.0) -> np.ndarray:
    """Downward expander on `voice`, keyed by the clean-speech envelope `key`.

    Attenuates residual noise in speech gaps by up to max_atten_db, leaving
    speech untouched. Threshold is relative to the key's active-speech RMS.
    """
    frame = max(1, sr // 200)  # 5 ms control rate
    n = len(voice) // frame
    env = np.sqrt(_mean_square(key, frame, n))
    env_db = 20 * np.log10(env + 1e-12)
    speech_rms_db = float(np.quantile(env_db, 0.9))
    thresh = speech_rms_db + thresh_rel_db

    # Static curve: 0 dB above threshold, ramping to -max_atten below it.
    gain_db = np.clip((env_db - thresh) * 1.5, -max_atten_db, 0.0)

    # Smooth: fast attack (gain rising toward 0), slow release.
    a_att = float(np.exp(-1.0 / max(1e-9, (attack_ms / 1000) * 200)))
    a_rel = float(np.exp(-1.0 / max(1e-9, (release_ms / 1000) * 200)))
    sm = np.empty_like(gain_db)
    g = gain_db[0]
    for i, x in enumerate(gain_db):
        a = a_att if x > g else a_rel
        g = a * g + (1 - a) * x
        sm[i] = g

    # Each frame's gain on its samples; samples past the last frame keep its gain.
    frame_gain = 10 ** (sm / 20)
    return _apply_gain(voice, lambda a, b: frame_gain[np.minimum(np.arange(a, b) // frame, n - 1)])


def low_band_gate(x: np.ndarray, sr: int, fc: float = 150.0,
                  max_atten_db: float = 14.0, nfft: int = 4096) -> np.ndarray:
    """Per-bin spectral gate below fc: keep voice harmonics, drop the rumble.

    A time-domain gate cannot remove noise that coexists with speech in the
    same instant, so this works per STFT bin: each low bin's noise floor is
    estimated from speech-active frames (lower quartile), and bins near that
    floor are attenuated while strong (harmonic) bins pass — making the low
    band tonal like a regenerated voice rather than boosted broadband rumble.
    """
    hop = nfft // 4
    # Pass 1: every frame's energy and low-band magnitudes (small arrays).
    energies, mags = [], []
    for _, f, Z in _stft_frames(x, sr, nfft, hop):
        sel = f < fc
        energies.append((np.abs(Z) ** 2).sum(axis=0))
        mags.append(np.abs(Z[sel]))
    frame_e = np.concatenate(energies)
    mag = np.concatenate(mags, axis=1)

    active = frame_e >= np.quantile(frame_e, 0.40)
    ref = mag[:, active] if active.any() else mag
    floor = np.quantile(ref, 0.35, axis=1, keepdims=True) + 1e-12

    # Soft knee: unity gain at 7x the floor, max attenuation at the floor.
    snr = mag / floor
    gain = np.clip((snr - 1.0) / 6.0, 0.0, 1.0)
    gain = np.maximum(np.sqrt(gain), 10 ** (-max_atten_db / 20))
    # Light temporal smoothing to avoid musical noise.
    kernel = np.ones(3) / 3.0
    gain = np.apply_along_axis(lambda g: np.convolve(g, kernel, mode="same"), 1, gain)

    # Pass 2: apply the gains block by block.
    def modify(Z, k0):
        Z[sel] *= gain[:, k0:k0 + Z.shape[1]]

    return _stft_filter(x, sr, nfft, hop, modify)


def air_exciter(x: np.ndarray, sr: int, air_rel_db: float = -31.5,
                lo: float = 8000.0, hi: float = 16000.0, seed: int = 0) -> np.ndarray:
    """Synthesize breathy high-band "air" like a regenerative enhancer.

    Band-limited noise (lo..hi) modulated by the 4-8 kHz speech envelope, so it
    breathes with the voice and vanishes in gaps. Level is set relative to the
    300 Hz-3 kHz speech core. Deterministic (fixed seed).
    """
    sos_env = signal.butter(4, [4000, 8000], btype="band", fs=sr, output="sos")
    sos_air = signal.butter(4, [lo, min(hi, sr / 2 * 0.98)], btype="band",
                            fs=sr, output="sos")
    sos_core = signal.butter(4, [300, 3000], btype="band", fs=sr, output="sos")
    k = max(1, int(sr * 0.01))
    n = len(x)
    margin = sr // 2 + k                    # the band-passes settle in a few ms
    noise = _NoiseStream(seed)
    air = np.empty(n, np.float32)           # unscaled air; float32 is far below its level
    core_sq = air_sq = 0.0
    for a, b in _spans(n):
        s0, s1 = max(0, a - margin), min(n, b + margin)
        x64 = x[s0:s1].astype(np.float64)
        env = np.abs(signal.sosfiltfilt(sos_env, x64))
        env = np.convolve(env, np.ones(k) / k, mode="same")
        blk = (signal.sosfiltfilt(sos_air, noise.take(s0, s1)) * env)[a - s0:b - s0]
        core = signal.sosfiltfilt(sos_core, x64)[a - s0:b - s0]
        core_sq += float(np.dot(core, core))
        air_sq += float(np.dot(blk, blk))
        air[a:b] = blk

    core_rms = float(np.sqrt(core_sq / n))
    air_rms = float(np.sqrt(air_sq / n)) + 1e-12
    scale = core_rms * 10 ** (air_rel_db / 20) / air_rms
    out = np.empty(n, np.float32)
    for a, b in _spans(n):
        out[a:b] = x[a:b].astype(np.float64) + air[a:b].astype(np.float64) * scale
    return out


def level_voice(x: np.ndarray, sr: int, max_db: float = 3.5,
                frame_s: float = 0.4) -> np.ndarray:
    """Slow AGC: nudge active-speech level toward its own mean (±max_db).

    Adds the level consistency of processed broadcast voice without pumping:
    400 ms frames, gain frozen during gaps, smoothed over ~1 s.
    """
    n = int(sr * frame_s)
    k = len(x) // n
    if k < 3:
        return x
    rms = np.sqrt(_mean_square(x, n, k))
    db = 20 * np.log10(rms + 1e-12)
    active = db >= np.quantile(db, 0.60)
    target = float(db[active].mean())

    g = np.clip(target - db, -max_db, max_db)
    last = 0.0
    for i in range(k):                      # freeze gain in gaps
        if active[i]:
            last = g[i]
        else:
            g[i] = last
    sm = np.empty_like(g)                   # ~1 s one-pole smoothing
    a = float(np.exp(-frame_s / 1.0))
    acc = g[0]
    for i in range(k):
        acc = a * acc + (1 - a) * g[i]
        sm[i] = acc

    frame_gain = 10 ** (sm / 20)            # samples past the last frame keep its gain
    return _apply_gain(x, lambda a, b: frame_gain[np.minimum(np.arange(a, b) // n, k - 1)])


def active_speech_db(x: np.ndarray, sr: int = 48000, frame_s: float = 0.05,
                     scale: float = 1.0) -> float:
    """Mean dBFS RMS over the top-40% energy frames (of x * scale).

    Pause-density-independent speech level — Adobe's outputs cluster tightly on
    this measure while their integrated LUFS varies with how much silence a
    recording contains.
    """
    n = int(sr * frame_s)
    k = len(x) // n
    if k == 0:
        return -120.0                       # shorter than one frame: silence
    rms = np.sqrt(_mean_square(x, n, k, scale))
    db = 20 * np.log10(rms + 1e-12)
    return float(db[db >= np.quantile(db, 0.60)].mean())


def speech_gate(x: np.ndarray, key: np.ndarray, sr: int = 48000,
                thresh_rel_db: float = -40.0, range_db: float = 12.0,
                look_ms: float = 60.0, hold_ms: float = 150.0,
                release_ms: float = 250.0) -> np.ndarray:
    """Downward expander on x, keyed by a separate speech-presence signal.

    For resynthesized voices: the generative model regenerates low-level
    rumble and reproduces clicks in gaps, so its own envelope is a poor key.
    A discriminative denoiser's output (DF3) marks where speech actually is.
    Lookahead + hold keep onsets and word tails intact; range is limited so
    gaps land near Adobe's measured floor (~-50 dB) rather than dead silence,
    which listeners (and UTMOS) hear as unnatural.
    """
    return speech_gate_gain(key[:len(x)], sr, thresh_rel_db, range_db, look_ms, hold_ms,
                            release_ms)(x)


def speech_gate_gain(key: np.ndarray, sr: int = 48000,
                     thresh_rel_db: float = -40.0, range_db: float = 12.0,
                     look_ms: float = 60.0, hold_ms: float = 150.0,
                     release_ms: float = 250.0) -> Callable[[np.ndarray], np.ndarray]:
    """speech_gate with its gain fixed from `key`: returns gate(x) for signals of
    the key's length. The gate keeps only the per-frame gains, not the key."""
    frame = sr // 200                                  # 5 ms control rate
    n = len(key) // frame
    if n < 4:
        return lambda x: x
    env = np.sqrt(_mean_square(key, frame, n))
    db = 20 * np.log10(env + 1e-12)
    active = float(db[db >= np.quantile(db, 0.6)].mean())
    tgt = np.clip((db - (active + thresh_rel_db)) * 2.0, -range_db, 0.0)

    look, hold = int(look_ms / 5), int(hold_ms / 5)    # gain(i) = max over [i-hold, i+look]
    padded = np.pad(tgt, (hold, look), constant_values=-range_db)
    win = np.lib.stride_tricks.sliding_window_view(padded, hold + look + 1).max(axis=1)

    a = float(np.exp(-5.0 / release_ms))               # instant open, smooth close
    g = np.empty_like(win)
    acc = win[0]
    for i, v in enumerate(win):
        acc = v if v > acc else a * acc + (1 - a) * v
        g[i] = acc
    centers, gains = np.arange(n) * frame + frame / 2, 10 ** (g / 20)
    return lambda x: _apply_gain(x, lambda a, b: np.interp(np.arange(a, b), centers, gains))


def restoration_tone(x: np.ndarray, sr: int = 48000, hp_hz: float = 40.0,
                     shelf_db: float = -6.0, lp_hz: float = 20000.0) -> np.ndarray:
    """Tone correction for Sidon output, measured against Adobe references.

    Sidon's midrange tracks Adobe within each clip's natural variance, but it is
    consistently 6-8 dB hotter above 12 kHz (audible as fizz/haze) and extends
    to Nyquist where Adobe rolls off at ~20 kHz. It also regenerates sub-40 Hz
    rumble that dominates the gap noise floor.
    """
    sos = signal.butter(2, hp_hz, "high", fs=sr, output="sos")
    fr = np.array([0.0, 11000.0, 14000.0, lp_hz - 500.0, lp_hz + 1000.0, sr / 2])
    g = np.array([0.0, 0.0, shelf_db, shelf_db, -60.0, -60.0])
    taps = design_match_fir(fr, g, sr)
    n = len(x)
    margin = len(taps) + sr // 2            # the FIR's reach plus time for the high-pass to settle
    out = np.empty(n, np.float32)
    for a, b in _spans(n):
        s0, s1 = max(0, a - margin), min(n, b + margin)
        hp = signal.sosfiltfilt(sos, x[s0:s1].astype(np.float64))
        out[a:b] = _fir_span(hp, s0, taps, a, b)
    return out


def music_to_voice_db(accomp: np.ndarray, vocals: np.ndarray, sr: int = 48000) -> float:
    """Level of *musical* content in the demucs accompaniment stem, dB re vocals.

    On speech-only recordings demucs dumps room noise, hum and speech leakage
    into the accompaniment — often louder than real music beds — so raw stem
    level is a bad music detector. Music shows up as held notes: spectral peaks
    that persist >= ~250 ms but move around over the clip. Stationary peaks
    (hum, fan whine: same bins in most frames) and broadband noise are excluded.
    """
    from scipy.ndimage import binary_opening, median_filter

    nper, hop = 8192, 2048
    # Pass 1: energy of every frame in the 100 Hz-6 kHz band.
    energies = []
    for _, f, Z in _stft_frames(accomp, sr, nper, hop):
        band = (f >= 100) & (f <= 6000)
        energies.append((np.abs(Z) ** 2)[band].sum(axis=0))
    e = np.concatenate(energies)
    keep = e >= np.quantile(e, 0.5)
    # Pass 2: power and spectral peaks of the louder half of the frames.
    powers, peaks = [], []
    for k0, _, Z in _stft_frames(accomp, sr, nper, hop):
        p = (np.abs(Z) ** 2)[band][:, keep[k0:k0 + Z.shape[1]]]
        lp = 10 * np.log10(p + 1e-20)
        powers.append(p)
        peaks.append((lp - median_filter(lp, size=(31, 1))) > 10)   # >10 dB above local floor
    p = np.concatenate(powers, axis=1)
    peak = np.concatenate(peaks, axis=1)
    held = binary_opening(peak, structure=np.ones((1, 6)))    # 6 hops ≈ 256 ms
    stationary = peak.mean(axis=1, keepdims=True) > 0.5
    frac = float((p * (held & ~stationary)).sum() / (p.sum() + 1e-20))
    a_rms = float(np.sqrt((accomp ** 2).mean()) + 1e-12)
    v_rms = float(np.sqrt((vocals ** 2).mean()) + 1e-12)
    return 20 * np.log10(a_rms / v_rms) + 10 * np.log10(frac + 1e-9)


def track_f0(x: np.ndarray, sr: int = 48000, fmin: float = 60.0, fmax: float = 400.0,
             hop_s: float = 0.01, frame_s: float = 0.04,
             voicing: float = 0.6) -> tuple[np.ndarray, np.ndarray]:
    """Fast F0 track: normalized autocorrelation per frame at 16 kHz.

    Returns (f0, voiced) at hop_s; f0 = 0 where unvoiced. Octave-down errors
    are corrected by preferring half the lag when it correlates almost as
    well (harmonic_smooth treats octave-up errors as the dangerous kind).
    """
    sos = signal.butter(4, [fmin, 3000], btype="band", fs=16000, output="sos")
    n, hop = int(frame_s * 16000), int(hop_s * 16000)
    ylen = -(-len(x) // 3)                              # length at 16 kHz
    k = max(0, (ylen - n) // hop + 1)
    if k == 0:
        return np.zeros(0), np.zeros(0, bool)
    window = np.hanning(n)
    nfft = 1 << (2 * n - 1).bit_length()
    w = np.correlate(np.hanning(n), np.hanning(n), "full")[n - 1:]
    w_norm = np.maximum(w / w[0], 1e-3)
    lo, hi = int(16000 / fmax), min(int(16000 / fmin), n - 2)
    f0, corr, energy = np.empty(k), np.empty(k), np.empty(k)
    margin = 16000                                      # 1 s for the filters to settle
    per = max(1, BLOCK // (3 * hop))
    for k0 in range(0, k, per):                         # frames [k0, k1), block by block
        k1 = min(k, k0 + per)
        y0, y1 = max(0, k0 * hop - margin), min(ylen, (k1 - 1) * hop + n + margin)
        y = signal.resample_poly(x[3 * y0:3 * y1].astype(np.float64), 1, 3)
        y = signal.sosfiltfilt(sos, y)
        frames = np.lib.stride_tricks.sliding_window_view(y, n)[k0 * hop - y0::hop][:k1 - k0]
        frames = frames * window
        m = len(frames)
        ac = np.fft.irfft(np.abs(np.fft.rfft(frames, nfft)) ** 2, nfft)[:, :n]
        ac = ac / (ac[:, :1] + 1e-12) / w_norm
        seg = ac[:, lo:hi]
        lag = seg.argmax(axis=1) + lo
        peak = seg.max(axis=1)
        half = lag // 2                                 # octave-down correction
        ok = (half >= lo) & (ac[np.arange(m), half] > 0.85 * peak)
        lag = np.where(ok, half, lag)
        a, b, c = ac[np.arange(m), lag - 1], ac[np.arange(m), lag], ac[np.arange(m), lag + 1]
        den = a - 2 * b + c
        frac = np.where(np.abs(den) > 1e-9, 0.5 * (a - c) / den, 0.0)   # parabolic interp
        f0[k0:k1] = 16000.0 / (lag + np.clip(frac, -0.5, 0.5))
        corr[k0:k1] = b
        energy[k0:k1] = (frames ** 2).mean(axis=1)
    voiced = (corr > voicing) & (energy > np.quantile(energy, 0.3) * 0.1)
    return np.where(voiced, f0, 0.0), voiced


def harmonic_smooth(x: np.ndarray, sr: int = 48000, fmax: float = 3500.0,
                    floor_db: float = -6.0, nfft: int = 4096, hop: int = 480) -> np.ndarray:
    """Pitch-adaptive comb: turn down inter-harmonic energy in voiced frames.

    Sidon's resynthesized voice has fuzzy, noise-filled harmonics (heard as a
    rough "something in the throat" quality); Adobe's are clean lines. In
    voiced frames below fmax, bins between harmonics of the tracked F0 are
    attenuated by up to floor_db (cos^2 shape, so harmonic peaks are untouched).
    Measured: voiced periodicity +0.025 toward Adobe; -6 dB preferred by ear
    over -10 dB (which starts to sound processed).
    """
    f0, voiced = track_f0(x, sr)
    if not voiced.any():
        return x
    track_t = np.arange(len(f0)) * 0.01 + 0.02                  # F0 frame centres
    f = sp_fft.rfftfreq(nfft, 1 / sr)
    sel = f < fmax
    fs = f[sel][:, None]
    fade = np.clip((fmax - fs) / 500.0, 0, 1)                   # blend out toward fmax

    def modify(Z, k0):
        t = (k0 + np.arange(Z.shape[1])) * hop / sr              # STFT frame centres
        ft = np.interp(t, track_t, f0)
        vt = np.interp(t, track_t, voiced.astype(float))
        f0t = np.maximum(ft, 1.0)[None, :]
        r = fs / f0t
        d = np.abs(r - np.round(r))
        g = np.maximum(np.cos(np.pi * d) ** 2, 10 ** (floor_db / 20))
        g = np.where(fs < 0.5 * f0t, 1.0, g)                    # below F0: untouched
        w = np.clip((vt - 0.5) / 0.5, 0, 1)[None, :] * (ft > 0)[None, :]
        Z[sel] *= ndimage_uniform(1 - (1 - g) * w * fade)        # bins above fmax: gain 1

    return _stft_filter(x, sr, nfft, hop, modify)


def ndimage_uniform(G: np.ndarray) -> np.ndarray:
    """3-frame temporal smoothing of a gain mask (avoids frame-edge flutter)."""
    from scipy.ndimage import uniform_filter1d
    return uniform_filter1d(G, 3, axis=1, mode="nearest")


def declick(x: np.ndarray, sr: int = 48000, frame_ms: float = 2.5,
            ctx_ms: tuple[float, float] = (25.0, 120.0)) -> np.ndarray:
    """Attenuate isolated mouth clicks / tongue clicks / mouse clicks.

    Generative restoration rebuilds a click as a sharp full-band burst (Adobe
    softens it 15-40 dB). A click is a short burst far above BOTH its preceding
    and following context — plosives (p/t/k) are followed by their vowel within
    tens of ms, so they fail the "after" test and are left alone. Rule
    (validated against Adobe on 4 clips — every flagged event was louder in ours
    by 15-44 dB or inaudibly quiet):
      >=5 ms burst, >=20 dB over context, context >=28 dB under speech; or
      any >=15 dB burst in deep quiet (context >=33 dB under speech).
    Each click is pulled down to 6 dB above its context.
    """
    fr = int(sr * frame_ms / 1000)
    n = len(x) // fr
    if n < 10:
        return x
    sos = signal.butter(4, 1000, "high", fs=sr, output="sos")
    margin = 100 * fr                                       # the high-pass settles in ~1 ms
    e = np.empty(n)
    for a, b in _spans(n * fr, align=fr):                   # energy of each 1 kHz high-passed frame
        s0, s1 = max(0, a - margin), min(len(x), b + margin)
        y = signal.sosfiltfilt(sos, x[s0:s1].astype(np.float64))[a - s0:b - s0]
        e[a // fr:b // fr] = (y.reshape(-1, fr) ** 2).mean(axis=1)
    edb = 10 * np.log10(e + 1e-14)
    c0, c1 = int(ctx_ms[0] / frame_ms), int(ctx_ms[1] / frame_ms)
    kern = np.ones(c1 - c0 + 1) / (c1 - c0 + 1)
    mid = c0 + (c1 - c0) // 2
    sm = np.convolve(e, kern, "same")
    pre, post = np.roll(sm, mid), np.roll(sm, -mid)            # mean of [-c1,-c0] / [c0,c1]
    ctx = 10 * np.log10(np.maximum(pre, post) + 1e-14)
    act = active_speech_db(x, sr)
    rise, ctx_rel = edb - ctx, ctx - act

    from scipy.ndimage import label
    lab, nl = label((rise > 15.0) & (edb > act - 45.0))
    gain_db = np.zeros(n)
    for i in range(1, nl + 1):
        idx = np.where(lab == i)[0]
        dur = len(idx) * frame_ms
        r, cr = float(rise[idx].max()), float(ctx_rel[idx].max())
        if dur > 30.0:
            continue
        if (dur >= 5.0 and r >= 20.0 and cr <= -28.0) or cr <= -33.0:
            lo, hi = max(0, idx[0] - 1), min(n, idx[-1] + 2)     # ±1 frame margin
            gain_db[lo:hi] = np.minimum(gain_db[lo:hi], -min(35.0, r - 6.0))
    if not gain_db.any():
        return x
    t = np.arange(n) * fr + fr / 2
    return _apply_gain(x, lambda a, b: 10 ** (np.interp(np.arange(a, b), t, gain_db) / 20))


