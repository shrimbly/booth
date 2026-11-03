"""Generative speech restoration via Sidon (sarulab-speech/sidon-v0.1, MIT).

Same model class as Adobe Podcast Enhance: a w2v-BERT 2.0 feature predictor
maps noisy speech to clean self-supervised features, and a vocoder
resynthesizes 48 kHz studio speech from them — so it rebuilds harmonics and
bandwidth instead of masking noise. On the benchmark pairs it matches Adobe's
DNSMOS/UTMOS (UTMOS 3.70 vs Adobe 3.72; MossFormer2 scored 2.80).

Runs in a child process of the engine's own Python (torch 2.15 + transformers
5.21, pinned in pyproject.toml), so the ~4 GB it holds while it works goes
back to the system the moment it finishes. A `Job` starts that process early:
it loads the models and prepares the input, then waits for `release()`. The
caller releases it once its own heaviest work (demucs) is done, so the two
don't compete for cores, and does its lighter work while the runner restores.
Weights (~1 GB) download from the HF hub on first use, at pinned commits.
CPU only: the traced graph uses float64 ops that MPS rejects. About 0.1x
realtime on an M5 Pro CPU.

Feed it the raw recording: demucs vocals or a pre-denoise pass both scored
lower (the model is trained on in-the-wild noise and handles it better than
it handles separation artifacts).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import threading
from collections import deque
from collections.abc import Callable
from pathlib import Path

import numpy as np
import soundfile as sf

from .. import audio as A
from .. import requirements as R

# Lines the runner prints on stderr so the caller can show real progress.
PROGRESS_PREFIX = "@@sidon "
# The line it prints when its fast models fail and it carries on with the traced ones.
FALLBACK_PREFIX = "sidon: falling back"

_RUNNER = r'''
import sys, warnings
warnings.filterwarnings("ignore")
import numpy as np, soundfile as sf, torch, transformers
from huggingface_hub import hf_hub_download
from scipy import signal
import ast, os, re, shutil, types
from concurrent.futures import ThreadPoolExecutor

inp, outp, repo, rev, w2v, w2v_rev = sys.argv[1:7]
chunk_s = float(sys.argv[7])
fe = torch.jit.load(hf_hub_download(repo, "feature_extractor_cpu.pt", revision=rev),
                    map_location="cpu")
dec = torch.jit.load(hf_hub_download(repo, "decoder_cpu.pt", revision=rev), map_location="cpu")
pre = transformers.SeamlessM4TFeatureExtractor.from_pretrained(w2v, revision=w2v_rev)
aten = torch.ops.aten

# fe and dec run in the eager forms below, which compute their exact bits in about
# half the time and a third of the memory (scripts/check-sidon-exact.py checks that
# a Mac's Accelerate rounds them alike). If building or running those fails, the
# rest of the run uses the traced models.


# The w2v-BERT encoder runs from the trace's own TorchScript source, with two of
# its ops on a faster path that computes the same bits:
# - the depthwise conv (groups=1024): without oneDNN, CPU torch loops over 1024
#   single-channel convs; one unfold + bmm issues the very same per-channel sgemm
#   (m=T, n=1, k=31) without the per-group overhead;
# - the relative-position term einsum("bhld,lrd->bhlr", q, E[idx]): gathering
#   q @ E^T gives the same 64-term dot products without the [T, T, 64] tensor
#   (0.8-1 GB per layer).
# Each local is freed after its last use, as the TorchScript interpreter does,
# and the attention scores are updated in place.
class RelPos:                           # an embedding lookup left for einsum to gather
    def __init__(self, table, idx):
        self.table, self.idx = table, idx


class EncoderOps:
    """What the encoder's source calls as torch.*: aten ops, plus the fast paths."""
    DTYPES = {4: torch.int64, 6: torch.float32, 7: torch.float64}

    def __getattr__(self, name):
        return getattr(aten, name)

    def size(self, t, d):
        return t.size(d)

    def to(self, t, dtype):
        return t if isinstance(t, RelPos) else aten.to.dtype(t, self.DTYPES[dtype])

    def softmax_(self, t, dim):
        return aten._softmax.out(t, dim, False, out=t)

    def conv1d(self, x, w, b=None, stride=(1,), padding=(0,), dilation=(1,), groups=1):
        if groups == 1:
            return aten.conv1d(x, w, b, stride, padding, dilation, groups)
        C, _, K = w.shape
        assert groups == C and b is None and x.shape[0] == 1 and list(stride) == [1] \
            and list(padding) == [0] and list(dilation) == [1]
        T = x.shape[-1] - K + 1
        out = x.new_empty((1, C, T))
        for c0 in range(0, C, 256):         # bounded im2col buffer
            c1 = min(C, c0 + 256)
            cols = x[0, c0:c1].unfold(1, K, 1).transpose(1, 2).contiguous()
            aten.bmm.out(w[c0:c1].view(c1 - c0, 1, K), cols,
                         out=out[0, c0:c1].view(c1 - c0, 1, T))
        return out

    def embedding(self, table, idx):    # the relative-position table, already float32
        assert table.shape == (73, 64) and table.dtype == torch.float32, table.shape
        return RelPos(table, idx)

    def einsum(self, eq, ops):
        q, p = ops
        assert eq == "bhld,lrd->bhlr" and isinstance(p, RelPos), eq
        b, h, L, _ = q.shape
        return aten.gather(aten.matmul(q, p.table.t()), 3, p.idx.expand(b, h, L, p.idx.shape[1]))


def free_after_last_use(src):
    """`src`'s straight-line function with each local deleted after its last use."""
    mod = ast.parse(src)
    fn = mod.body[0]
    assert all(isinstance(st, (ast.Assign, ast.Return)) for st in fn.body)
    last = {}
    for i, st in enumerate(fn.body):
        for n in ast.walk(st):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load):
                last[n.id] = i
    body = []
    for i, st in enumerate(fn.body):
        body.append(st)
        dead = sorted({n.id for n in ast.walk(st) if isinstance(n, ast.Name)
                       and n.id not in ("C", "OPS", "torch", "self") and last.get(n.id, -1) <= i})
        if dead and not isinstance(st, ast.Return):
            body.append(ast.Delete(targets=[ast.Name(id=d, ctx=ast.Del()) for d in dead]))
    fn.body = body
    return ast.unparse(ast.fix_missing_locations(mod))


def eager_encoder(traced):
    """A function computing traced(f), eagerly."""
    code, consts = traced.code_with_constants
    src = code.replace("CONSTANTS.", "C.").replace('torch.device("cpu")', "DEVICE")
    src = re.sub(r"\btorch\.(\w+)\(", r"OPS.\1(", src).replace("DEVICE", 'torch.device("cpu")')
    src = src.replace("Dict[str, Tensor]", "dict").replace(": Tensor", "")
    src, n_div = re.subn(r"(\w+) = OPS\.div\((\w+), C\.c22\)", r"\1 = OPS.div_(\2, C.c22)", src)
    src, n_add = re.subn(r"(scores\d*) = OPS\.add\((scores\d*), (_\d+)\)",
                         r"\1 = OPS.add_(\2, \3)", src)
    src, n_sm = re.subn(r"(\w+) = OPS\.softmax\((scores\d+), -1\)", r"\1 = OPS.softmax_(\2, -1)",
                        src)
    # 8 layers, each scaling its scores and relative-position term, adding them,
    # taking the softmax and looking up its one position table
    counts = n_div, n_add, n_sm, src.count("OPS.embedding("), src.count("OPS.einsum(")
    assert counts == (16, 8, 8, 8, 8), counts
    ns = {"C": types.SimpleNamespace(**consts.const_mapping), "OPS": EncoderOps(), "torch": torch}
    exec(free_after_last_use(src), ns)
    return lambda f: ns["forward"](None, f)


# The vocoder is a traced DAC decoder: conv, 5 x [snake, transposed conv, 3
# residual units], snake, conv, tanh. dec(h) on a whole chunk peaks at ~7 GB and
# keeps ~1.5 cores busy, so it runs eagerly from the trace's own constants, in
# overlapping windows of hidden frames, several at a time, with the same bits:
# - each conv is the addmm PyTorch's conv kernels issue (bias as C), each snake
#   the trace's ops in its order (pow(t, 2) is t * t), each transposed conv the
#   same GEMM, the same two-tap overlap-add, then the bias;
# - a window's output differs from the whole chunk's only within 9393 samples
#   (9.8 frames) of its edges, so VOC_MARGIN frames each side are discarded;
# - the final 48 -> 1 conv is a one-row GEMM whose last N % 512 columns, and
#   every column of a call under ~6k wide, round differently, so windows, and
#   that conv's pieces, start on a multiple of 8 frames (7680 samples), pieces
#   overlap by 15360 samples (rewritten by the next piece) and none is narrow.
# Accelerate runs each GEMM on one core, so the windows in flight use the cores.
VOC_WINDOW, VOC_MARGIN = 200, 16        # hidden frames per window / context each side
VOC_PARALLEL = 3 if (os.cpu_count() or 1) >= 12 else 2      # windows in flight
VOC_THREADS = 3                         # torch threads per window
VOC_PIECE = 32 << 20                    # bytes of im2col columns per GEMM, at most
HOP, GRID = 960, 7680                   # output samples per hidden frame / per 8 frames


class Vocoder:
    """The traced vocoder's layers, from its constants; decode(h) computes traced(h)."""

    def __init__(self, traced):
        code, consts = traced.code_with_constants
        c = consts.const_mapping
        assert len(c) == 146, len(c)
        it = (c[f"c{i}"] for i in range(len(c)))
        calls = []                          # each conv's arguments after the bias

        def conv(k, d):
            w, b = next(it), next(it)
            assert w.shape[2] == k and b.shape == w.shape[:1], (w.shape, b.shape)
            p = d * (k - 1) // 2
            calls.append(("conv1d", "" if k == 1 else
                          f", [1], [{p}]" + (f", [{d}]" if d > 1 else "")))
            return w.reshape(w.shape[0], -1), b.view(-1, 1), w.shape[1], k, d, p

        def snake():
            a, inv = next(it), next(it)
            assert a.shape == inv.shape == (1, a.shape[1], 1), (a.shape, inv.shape)
            return a.view(-1, 1), inv.view(-1, 1)

        self.conv_in, self.stages = conv(7, 1), []
        for s, p in zip((8, 5, 4, 3, 2), (4, 3, 2, 2, 1)):
            sn, w, b = snake(), next(it), next(it)
            cin, cout, k = w.shape
            assert k == 2 * s and b.shape == (cout,), (w.shape, b.shape)
            calls.append(("conv_transpose1d", f", [{s}], [{p}]"))
            up = w.reshape(cin, cout * k).t(), b.view(-1, 1), cout, s, p
            self.stages.append((sn, up, [(snake(), conv(7, d), snake(), conv(1, 1))
                                         for d in (1, 3, 9)]))
        self.snake_out, self.conv_out = snake(), conv(7, 1)
        traced_calls = re.findall(r"torch\.(conv1d|conv_transpose1d)\(\w+, CONSTANTS\.c\d+, "
                                  r"CONSTANTS\.c\d+((?:, \[\d+\])*)\)", code)
        assert traced_calls == calls, traced_calls

    @staticmethod
    def snake_(x, ab):                      # x + inv * sin(a * x) ** 2, in place
        t = torch.mul(x, ab[0])
        t.sin_()
        t.mul_(t)
        t.mul_(ab[1])
        return x.add_(t)

    @staticmethod
    def padded_snake(x, ab, p):             # snake(x) with p zeros each side
        C, L = x.shape
        buf = torch.empty(C, L + 2 * p)
        buf[:, :p] = 0
        buf[:, L + p:] = 0
        Vocoder.snake_(buf[:, p:p + L].copy_(x), ab)
        return buf

    @staticmethod
    def cols(buf, l0, n, cin, k, d):        # im2col of n output columns from l0
        return buf[:, l0:].as_strided((cin, k, n), (buf.stride(0), d, 1)).reshape(cin * k, n)

    def conv(self, buf, cv, L):             # buf: the padded input
        w, b, cin, k, d, p = cv
        out = torch.empty(w.shape[0], L)
        pieces = -(-L * cin * k * 4 // VOC_PIECE)
        step = -(-L // pieces)              # equal pieces: a GEMM a few columns wide rounds
        for l0 in range(0, L, step):        # differently from the same columns in a wide one
            n = min(step, L - l0)
            torch.addmm(b, w, self.cols(buf, l0, n, cin, k, d), out=out[:, l0:l0 + n])
        return out

    @staticmethod
    def upsample(x, up):
        w, b, cout, s, p = up
        n = x.shape[1]
        cols = torch.mm(w, x).view(cout, 2 * s, n)
        full = torch.zeros(cout, n + 1, s)
        full[:, :n].add_(cols[:, :s].transpose(1, 2))     # tap j < s of frame i
        full[:, 1:].add_(cols[:, s:].transpose(1, 2))     # tap j + s of frame i - 1
        return full.view(cout, (n + 1) * s)[:, p:(n + 1) * s - p].add(b)

    def final(self, x):
        w, b, cin, k, d, p = self.conv_out
        L = x.shape[1]
        buf = self.padded_snake(x, self.snake_out, p)
        y = torch.empty(L)
        step = 8 * GRID                     # pieces overlap by 2 * GRID: the last one is
        for l0 in range(0, L, step):        # never narrow (< ~6k columns rounds differently)
            n = min(L - l0, step + 2 * GRID)
            y[l0:l0 + n] = torch.addmm(b, w, self.cols(buf, l0, n, cin, k, d))[0]
            if l0 + n == L:
                break
        return torch.tanh(y)

    def __call__(self, h):                  # [1, 1024, t] -> [HOP * t - 26]
        p = self.conv_in[5]
        x = self.conv(torch.nn.functional.pad(h[0], (p, p)), self.conv_in, h.shape[-1])
        for sn, up, units in self.stages:
            x = self.upsample(self.snake_(x, sn), up)
            for s1, c7, s2, (w1, b1, *_) in units:
                y = self.conv(self.padded_snake(x, s1, c7[5]), c7, x.shape[1])
                x = torch.addmm(b1, w1, self.snake_(y, s2)).add_(x)
        return self.final(x)

    def decode(self, h):                    # == dec(h).view(-1).numpy()
        T = h.shape[-1]
        out = np.empty(HOP * T - 26, np.float32)

        def window(c0):
            c1 = min(T, c0 + VOC_WINDOW)
            s, e = max(0, c0 - VOC_MARGIN), min(T, c1 + VOC_MARGIN)
            with torch.inference_mode():
                y = self(h[..., s:e]).numpy()
            y = y[HOP * (c0 - s):HOP * (c1 - s) if c1 < T else None]
            out[HOP * c0:HOP * c0 + len(y)] = y

        threads = torch.get_num_threads()
        torch.set_num_threads(VOC_THREADS)  # the pool's new threads take it at their first op
        pool = ThreadPoolExecutor(VOC_PARALLEL)
        try:
            list(pool.map(window, range(0, T, VOC_WINDOW)))
        finally:
            pool.shutdown(cancel_futures=True)
            torch.set_num_threads(threads)  # the encoder's bits depend on its count
        return out


def gone():
    """The caller has died: remove this run's folder, with its copy of the input, and stop."""
    shutil.rmtree(os.path.dirname(os.path.abspath(inp)), ignore_errors=True)
    os._exit(1)


def tell(line):
    """One line to the caller, who reads them as they come."""
    try:
        print(line, file=sys.stderr, flush=True)
    except BrokenPipeError:
        gone()


def fall_back(e):
    """Use the traced models for the rest of the run, saying why on one line."""
    global fast
    fast = None
    why = " ".join(f"{type(e).__name__}: {e}".split())[:300]
    tell(f"sidon: falling back to the traced models: {why}")


fast = None                             # (encoder, vocoder) while they work
try:
    fast = eager_encoder(fe), Vocoder(dec)
except Exception as e:
    fall_back(e)

x, sr = sf.read(inp, dtype="float32")
assert sr == 48000, sr
g = 0.9 / (float(np.abs(x).max()) + 1e-9)
x = signal.sosfiltfilt(signal.butter(2, 50, "high", fs=sr, output="sos"), x * g).astype(np.float32)
x16 = signal.resample_poly(x, 1, 3).astype(np.float32)
CTX = 2 * 16000                     # context each side of a chunk, discarded


def features(seg):                      # the models' input: seg and 1.5 s of silence
    w = torch.nn.functional.pad(torch.from_numpy(seg), (0, 24000))
    return pre(torch.nn.functional.pad(w, (160, 160)).numpy(),
               sampling_rate=16000, return_tensors="pt")["input_features"]


def restore(seg):
    with torch.inference_mode():
        f = features(seg)
        y = None
        if fast is not None:
            try:
                encoder, vocoder = fast
                y = vocoder.decode(encoder(f)["last_hidden_state"].transpose(1, 2))
            except Exception as e:
                fall_back(e)
        if y is None:
            y = dec(fe(f)["last_hidden_state"].transpose(1, 2)).view(-1).numpy()
    y = y[:-960][:len(seg) * 3]
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
# Wait for the caller's go. End of input means it has died: a caller that stops
# the runner kills it before closing the gate.
if sys.argv[8:] == ["gate"] and not sys.stdin.readline():
    gone()
tell(f"@@sidon loaded 0 {len(x16)}")

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
    tell(f"@@sidon chunk {b} {len(x16)}")
sf.write(outp, out[:len(x)] / g, 48000, subtype="FLOAT")
'''


ProgressCallback = Callable[[str, int, int], None]


def enhance(audio: np.ndarray, sr: int, chunk_s: float = 30.0,
            on_progress: ProgressCallback | None = None) -> np.ndarray:
    """Restore mono float32 speech. Returns 48 kHz audio, same length as input.

    Output is resynthesized: level is not tied to the input, and timing is only
    envelope-aligned (phase is regenerated) — callers should level-match it.
    `on_progress(name, done, total)` receives "sidon.loaded" once the models
    are in memory and "sidon.chunk" (input samples restored so far) per chunk.
    """
    with Job(audio, sr, chunk_s, on_progress) as job:
        return job.result()


class Job:
    """One `enhance`, by a runner that starts at once: it loads the models and
    prepares the input, then waits for `release()` to restore.

    Use it as a context manager: leaving the block, however it is left, stops
    the runner and removes its files. `on_progress` gets what `enhance`'s
    does, after the release and from a reader thread.
    """

    def __init__(self, audio: np.ndarray, sr: int, chunk_s: float = 30.0,
                 on_progress: ProgressCallback | None = None,
                 log: Callable[[str], None] | None = None):
        assert sr == 48000, "sidon runner expects 48 kHz input"
        self._length = len(audio)
        self._log = log
        self._tail: deque[str] = deque(maxlen=80)
        self._released = False
        self._proc: subprocess.Popen | None = None
        self._reader: threading.Thread | None = None
        self._dir = tempfile.TemporaryDirectory(prefix="booth-sidon-")
        d = Path(self._dir.name)
        inp, self._out, runner = d / "in.wav", d / "out.wav", d / "runner.py"
        try:
            A.write_wav(inp, audio, sr, subtype="FLOAT")
            runner.write_text(_RUNNER)
            # stdin is the gate: a line opens it, and if this process dies the
            # runner reads end of input and exits instead of restoring.
            self._proc = subprocess.Popen(
                [sys.executable, str(runner), str(inp), str(self._out), R.SIDON_REPO,
                 R.SIDON_REVISION, R.W2V_REPO, R.W2V_REVISION, str(chunk_s), "gate"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors="replace", bufsize=1)
            # Draining the output as it comes also keeps the runner from
            # blocking on a full pipe while this process is busy.
            reader = threading.Thread(target=self._read, args=(on_progress,),
                                      name="sidon-output", daemon=True)
            reader.start()
            self._reader = reader
        except BaseException:
            self.close()
            raise

    def release(self) -> None:
        """Let the runner restore as soon as its models are loaded. Idempotent."""
        if self._released:
            return
        self._released = True
        try:
            os.write(self._proc.stdin.fileno(), b"\n")
        except BrokenPipeError:
            pass                        # it has already exited; result() says why

    def result(self) -> np.ndarray:
        """Wait for the restored audio (released first if need be): 48 kHz,
        the length of the input."""
        self.release()
        returncode = self._proc.wait()
        self._reader.join()
        if returncode != 0 or not self._out.exists():
            raise RuntimeError(f"sidon engine failed:\n{''.join(self._tail)[-1200:]}")
        y, _ = sf.read(str(self._out), dtype="float32")
        if len(y) < self._length:
            y = np.pad(y, (0, self._length - len(y)))
        return y[:self._length]

    def close(self) -> None:
        """Stop the runner if it is still going and remove its files. Idempotent."""
        if self._proc is not None:
            if self._proc.poll() is None:
                self._proc.kill()
            self._proc.wait()
            self._proc.stdin.close()
            if self._reader is not None:
                self._reader.join()
            self._proc.stdout.close()
        self._dir.cleanup()

    def __enter__(self) -> Job:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def _read(self, on_progress: ProgressCallback | None) -> None:
        """Forward progress lines, and log a fallback to the traced models (slower,
        and heavier on memory); keep the rest for an error message."""
        for line in self._proc.stdout:
            if line.startswith(PROGRESS_PREFIX):
                _forward_progress(line[len(PROGRESS_PREFIX):], on_progress)
                continue
            if line.startswith(FALLBACK_PREFIX) and self._log is not None:
                try:
                    self._log(f"  ({line.strip()})")
                except Exception:
                    pass                # this thread must go on draining the pipe
            self._tail.append(line)


def _forward_progress(payload: str, on_progress: ProgressCallback | None) -> None:
    if on_progress is None:
        return
    try:
        name, done, total = payload.split()
        on_progress(f"sidon.{name}", int(done), int(total))
    except ValueError:
        pass
