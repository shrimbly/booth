"""Generative speech restoration via Sidon (sarulab-speech/sidon-v0.1, MIT).

Same model class as Adobe Podcast Enhance: a w2v-BERT 2.0 feature predictor
maps noisy speech to clean self-supervised features, and a vocoder
resynthesizes 48 kHz studio speech from them — so it rebuilds harmonics and
bandwidth instead of masking noise. On the benchmark pairs it matches Adobe's
DNSMOS/UTMOS (UTMOS 3.70 vs Adobe 3.72; MossFormer2 scored 2.80).

Runs out-of-process in a self-bootstrapped venv at ~/.cache/booth
(torch 2.15 + transformers 5.21, which conflict with this project's pinned
torch 2.2.2 stack; every package is pinned in requirements.SIDON_PINS).
Weights (~1 GB) download from the HF hub on first use, at pinned commits.
CPU only: the traced graph uses float64 ops that MPS rejects. ~0.4x realtime
on an M-series CPU.

Feed it the raw recording: demucs vocals or a pre-denoise pass both scored
lower (the model is trained on in-the-wild noise and handles it better than
it handles separation artifacts).
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from collections import deque
from collections.abc import Callable
from pathlib import Path

import numpy as np

from .. import audio as A
from .. import requirements as R
from .. import tools
from ..requirements import SIDON_VENV as VENV

# Lines the runner prints on stderr so the caller can show real progress.
PROGRESS_PREFIX = "@@sidon "

# Run by this Python to build the venv. It holds a lock beside the venv for the
# whole install, so a second setup (another terminal, or Booth while the CLI
# installs) waits and then finds the venv ready instead of deleting it under
# the first; the kernel drops the lock if the installer is killed. The venv
# starts over, because an interrupted install can leave a package half linked
# that uv then counts as installed. The "installing" marker keeps a failed
# install from being adopted as a venv from before markers
# (requirements.sidon_venv_ready).
_INSTALL = """
import fcntl, os, pathlib, shutil, signal, subprocess, sys
venv, marker, installing, ready, lock, uv, verify, *pins = sys.argv[1:]
child = None

def stop(signum, frame):
    if child is not None and child.poll() is None:
        child.terminate()
    sys.exit(128 + signum)

signal.signal(signal.SIGTERM, stop)
with open(lock, "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    marker = pathlib.Path(marker)
    if marker.exists() and marker.read_text() == ready:
        sys.exit(0)
    if os.path.lexists(venv):
        shutil.rmtree(venv)
    os.makedirs(venv)
    marker.write_text(installing)
    python = os.path.join(venv, "bin", "python")
    for cmd in ([uv, "venv", "--allow-existing", "--python", "3.11", venv],
                [uv, "pip", "install", "--python", python, *pins],
                [python, "-c", verify, str(marker), ready]):
        child = subprocess.Popen(cmd)
        if child.wait() != 0:
            sys.exit(child.returncode)
"""

# Run by the venv's Python after the install: the marker names the pins only
# once everything the runner imports actually loads.
_VERIFY = """
import pathlib, sys
import huggingface_hub, numpy, scipy.signal, soundfile, torch, transformers
transformers.SeamlessM4TFeatureExtractor
pathlib.Path(sys.argv[1]).write_text(sys.argv[2])
"""

_RUNNER = '''
import sys, warnings
warnings.filterwarnings("ignore")
import numpy as np, soundfile as sf, torch, transformers
from huggingface_hub import hf_hub_download
from scipy import signal

inp, outp, repo, rev, w2v, w2v_rev = sys.argv[1:7]
chunk_s = float(sys.argv[7])
fe = torch.jit.load(hf_hub_download(repo, "feature_extractor_cpu.pt", revision=rev),
                    map_location="cpu")
dec = torch.jit.load(hf_hub_download(repo, "decoder_cpu.pt", revision=rev), map_location="cpu")
pre = transformers.SeamlessM4TFeatureExtractor.from_pretrained(w2v, revision=w2v_rev)

x, sr = sf.read(inp, dtype="float32")
assert sr == 48000, sr
g = 0.9 / (float(np.abs(x).max()) + 1e-9)
x = signal.sosfiltfilt(signal.butter(2, 50, "high", fs=sr, output="sos"), x * g).astype(np.float32)
x16 = signal.resample_poly(x, 1, 3).astype(np.float32)
CTX = 2 * 16000                     # context each side of a chunk, discarded


def restore(seg):
    w = torch.nn.functional.pad(torch.from_numpy(seg), (0, 24000))
    with torch.inference_mode():
        f = pre(torch.nn.functional.pad(w, (160, 160)).numpy(),
                sampling_rate=16000, return_tensors="pt")["input_features"]
        y = dec(fe(f)["last_hidden_state"].transpose(1, 2)).view(-1)[:-960].numpy()
    y = y[:len(seg) * 3]
    return np.pad(y, (0, len(seg) * 3 - len(y)))


sos_b = signal.butter(4, [300, 4000], "band", fs=48000, output="sos")
sos_l = signal.butter(2, 200, fs=48000, output="sos")


def env(y):
    e = signal.sosfiltfilt(sos_l, np.abs(signal.sosfilt(sos_b, y.astype(np.float64))))
    return e - e.mean()


def lag(ref, y, m=2400):
    c = signal.fftconvolve(env(y), env(ref)[::-1], "full")
    mid = len(ref) - 1
    return int(np.argmax(c[mid - m:mid + m + 1])) - m


def shift(y, k):
    return np.concatenate([y[k:], np.zeros(k, y.dtype)]) if k >= 0 else \
        np.concatenate([np.zeros(-k, y.dtype), y[:k]])


# Chunk at the quietest 20 ms near each target length: w2v-BERT degrades on
# very long context (96 s chunks: UTMOS 3.35 vs 3.50 at 30 s on a 112 s file).
L, fr = int(chunk_s * 16000), 320
cuts = [0]
while len(x16) - cuts[-1] > L * 1.25:
    lo, hi = cuts[-1] + int(L * 0.75), cuts[-1] + int(L * 1.25)
    e = (x16[lo:hi - (hi - lo) % fr].reshape(-1, fr) ** 2).mean(axis=1)
    cuts.append(lo + int(np.argmin(e)) * fr + fr // 2)
cuts.append(len(x16))
print(f"@@sidon loaded 0 {len(x16)}", file=sys.stderr, flush=True)

out = np.zeros(len(x16) * 3 + 480, np.float32)   # x16 rounds up; trimmed at write
prev = None                          # (a0, b0, aligned output) of the previous chunk
for a, b in zip(cuts[:-1], cuts[1:]):
    a0, b0 = max(0, a - CTX), min(len(x16), b + CTX)
    y = restore(x16[a0:b0])
    y = shift(y, lag(x[a0 * 3:b0 * 3], y))           # per-chunk latency
    if prev is not None:                              # level-chain across the shared context
        pa0, pb0, py = prev
        o0, o1 = a0, min(pb0, b0)
        p_seg = py[(o0 - pa0) * 3:(o1 - pa0) * 3]
        c_seg = y[(o0 - a0) * 3:(o1 - a0) * 3]
        pe, ce = float((p_seg ** 2).mean()), float((c_seg ** 2).mean())
        if ce > 1e-9 and pe > 1e-9:
            y = y * np.clip(np.sqrt(pe / ce), 0.5, 2.0)
    prev = (a0, b0, y)
    seg = y[(a - a0) * 3:(b - a0) * 3]
    xf = min(480, len(seg))                           # 10 ms crossfade at the quiet cut
    if a > 0:
        r = np.linspace(0, 1, xf, dtype=np.float32)
        seg = seg.copy()
        seg[:xf] = out[a * 3:a * 3 + xf] * (1 - r) + seg[:xf] * r
    out[a * 3:a * 3 + len(seg)] = seg
    if b < len(x16):                                  # tail for the next crossfade
        tail = y[(b - a0) * 3:(b - a0) * 3 + 480]
        out[b * 3:b * 3 + len(tail)] = tail
    print(f"@@sidon chunk {b} {len(x16)}", file=sys.stderr, flush=True)
sf.write(outp, out[:len(x)] / g, 48000, subtype="FLOAT")
'''


def bootstrap_commands() -> list[list[str]]:
    """Commands that build the Sidon venv from scratch with uv and mark it ready."""
    uv = tools.uv_path()
    if uv is None:
        raise RuntimeError("uv is required to install the Sidon engine but was not found")
    VENV.parent.mkdir(parents=True, exist_ok=True)
    return [[sys.executable, "-c", _INSTALL, str(VENV), str(R.SIDON_MARKER), R.SIDON_INSTALLING,
             R.sidon_marker_text(), str(VENV.with_name(VENV.name + ".lock")), uv, _VERIFY,
             *R.SIDON_PINS]]


def _bootstrap(log=print) -> None:
    if R.sidon_venv_ready():
        return
    log("  (bootstrapping sidon env — one-time, ~2 min + 1 GB weights)")
    VENV.parent.mkdir(parents=True, exist_ok=True)
    for cmd in bootstrap_commands():
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"bootstrap failed: {' '.join(cmd)}\n{p.stderr[-800:]}")


ProgressCallback = Callable[[str, int, int], None]


def enhance(audio: np.ndarray, sr: int, chunk_s: float = 30.0, log=print,
            on_progress: ProgressCallback | None = None) -> np.ndarray:
    """Restore mono float32 speech. Returns 48 kHz audio, same length as input.

    Output is resynthesized: level is not tied to the input, and timing is only
    envelope-aligned (phase is regenerated) — callers should level-match it.
    `on_progress(name, done, total)` receives "sidon.loaded" once the models
    are in memory and "sidon.chunk" (input samples restored so far) per chunk.
    """
    _bootstrap(log)
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        inp, out, runner = td / "in.wav", td / "out.wav", td / "runner.py"
        A.write_wav(inp, audio, sr, subtype="FLOAT")
        assert sr == 48000, "sidon runner expects 48 kHz input"
        runner.write_text(_RUNNER)
        returncode, output_tail = _run_runner(
            [str(VENV / "bin" / "python"), str(runner), str(inp), str(out),
             R.SIDON_REPO, R.SIDON_REVISION, R.W2V_REPO, R.W2V_REVISION, str(chunk_s)],
            on_progress)
        if returncode != 0 or not out.exists():
            raise RuntimeError(f"sidon engine failed:\n{output_tail[-1200:]}")
        y = A.decode(out, sr)
    if len(y) < len(audio):
        y = np.pad(y, (0, len(audio) - len(y)))
    return y[:len(audio)].astype(np.float32)


def _run_runner(cmd: list[str], on_progress: ProgressCallback | None) -> tuple[int, str]:
    """Run the runner, forwarding its progress lines; returns (code, output tail)."""
    tail: deque[str] = deque(maxlen=80)
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, bufsize=1) as p:
        try:
            for line in p.stdout:
                if line.startswith(PROGRESS_PREFIX):
                    _forward_progress(line[len(PROGRESS_PREFIX):], on_progress)
                else:
                    tail.append(line)
        except BaseException:
            p.kill()                   # cancelled: don't leave the runner behind
            raise
    return p.returncode, "".join(tail)


def _forward_progress(payload: str, on_progress: ProgressCallback | None) -> None:
    if on_progress is None:
        return
    try:
        name, done, total = payload.split()
        on_progress(f"sidon.{name}", int(done), int(total))
    except ValueError:
        pass
