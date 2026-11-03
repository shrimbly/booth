"""Music/background split via Demucs htdemucs (lazy import — heavy)."""

from __future__ import annotations

import contextlib
import itertools
import os
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import numpy as np

# Segments separated at once on the CPU. Each runs its own team of torch threads
# (one per performance core by default), so a second only pays with cores to
# spare: on 18 cores, 150 s of audio takes 11 s instead of 17 s, for ~1 GB more
# memory (a second set of activations).
_WORKERS = 2 if (os.cpu_count() or 1) >= 10 else 1

_model = None


def split_music(audio: np.ndarray, sr: int, device: str = "cpu",
                progress: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """Split mono audio into (vocals, accompaniment) at sr.

    accompaniment is computed as the exact complement (audio - vocals) so the
    decomposition reconstructs the input perfectly.
    """
    import torch

    model = _load_model()
    msr = model.samplerate  # 44100

    x = torch.from_numpy(np.asarray(audio, dtype=np.float32))[None]   # [1, T]
    x44 = _resample(x, sr, msr)
    del x
    mix = x44.expand(2, -1)[None]                               # [1, 2, T] (dup mono -> stereo)

    # Normalize the way demucs.separate does, and undo afterwards.
    ref = mix.mean(dim=1)
    mean, std = ref.mean(), ref.std() + 1e-8
    del ref, mix
    # Both channels are the same, so normalize once and share it (a view, not a copy).
    mix_n = ((x44 - mean) / std).expand(2, -1)[None]
    del x44

    # MPS is ~2.5x faster but stays opt-in: it rounds differently from the CPU (vocals
    # ~6e-7 apart), and on torch 2.2 1-4% of its segment passes varied run to run.
    dev = device
    if device == "auto":
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
    if dev == "cpu":
        with torch.no_grad():
            voc44 = _vocals(model, mix_n, mean, std, "cpu", progress)
    else:
        try:
            with torch.no_grad(), _on_mps(model):
                voc44 = _vocals(model, mix_n, mean, std, dev, progress)
        except Exception:
            with torch.no_grad():  # MPS can lack ops depending on torch version — fall back
                voc44 = _vocals(model, mix_n, mean, std, "cpu", progress)
    del mix_n
    voc = _resample(voc44, msr, sr).squeeze(0).numpy()
    del voc44

    # Match length exactly, then take the exact complement.
    if len(voc) < len(audio):
        voc = np.pad(voc, (0, len(audio) - len(voc)))
    voc = voc[:len(audio)].astype(np.float32, copy=False)
    accomp = (audio - voc).astype(np.float32, copy=False)
    return voc, accomp


def _load_model():
    """htdemucs, loaded once per process and adapted in place for split_music."""
    global _model
    if _model is None:
        from demucs import pretrained
        from demucs.apply import BagOfModels

        model = pretrained.get_model("htdemucs")
        model.eval()
        subs = list(model.models) if isinstance(model, BagOfModels) else [model]
        _route_conv1d_off_nnpack(subs)
        if len(subs) == 1:      # apply_model combines a bag's models source by source
            _keep_vocals(subs[0])
        _model = model
    return _model


def _route_conv1d_off_nnpack(models) -> None:
    """Compute the models' large-batch Conv1d calls as batch-1 conv2d.

    htdemucs's frequency-branch DConv layers run Conv1d over [batch * freq, C, T]:
    batches of 512, 128 and 32 with 6-384 channels and 1 or 3 taps. torch's CPU
    convolution (no MKLDNN in this build) sends the undilated ones to NNPACK,
    whose FFT tiles are slow for kernels this small: 0.45 s of a 1.06 s segment
    pass. The same convolution as one batch-1 conv2d over [1, C, batch * freq, T]
    with a (1, k) kernel takes the im2col + BLAS path in 0.05 s; the dilated ones,
    which were never NNPACK's, also gain from the single GEMM. torch's own switch
    for NNPACK is process-wide, hence the per-module route. Same math in float32,
    rounded differently: vocals move by at most ~7e-7 (128 dB), and are as close
    to a float64 run as before (125-128 dB on a segment either way).
    """
    import torch.nn as nn
    import torch.nn.functional as F

    class Batch1Conv1d(nn.Conv1d):
        def forward(self, x):
            if x.device.type != "cpu" or x.dim() != 3 or x.shape[0] < 16:
                return super().forward(x)          # NNPACK only takes batches >= 16
            y = F.conv2d(x.transpose(0, 1)[None], self.weight[:, :, None], self.bias,
                         (1, self.stride[0]), (0, self.padding[0]), (1, self.dilation[0]),
                         self.groups)
            return y[0].transpose(0, 1).contiguous()

    for model in models:
        for m in model.modules():
            if (type(m) is nn.Conv1d and m.padding_mode == "zeros"
                    and not isinstance(m.padding, str)):
                m.__class__ = Batch1Conv1d


def _keep_vocals(model) -> None:
    """Make an HTDemucs compute only its vocals.

    Its last frequency and time layers are transposed convolutions with no norm
    or activation after them, and their output channels are grouped by source.
    With complex-as-channels output (no Wiener filter mixing the sources) every
    step after them is per source, so keeping the vocals' channels gives the same
    vocals, bit for bit, without the other sources' last layers and inverse STFTs.
    """
    import torch.nn as nn
    from demucs.hdemucs import HDecLayer
    from demucs.htdemucs import HTDemucs

    if not isinstance(model, HTDemucs) or not model.cac:
        return
    last = (model.decoder[-1], model.tdecoder[-1])
    if not all(isinstance(layer, HDecLayer) and layer.last and layer.conv_tr.groups == 1
               and isinstance(layer.norm2, nn.Identity) for layer in last):
        return
    idx = model.sources.index("vocals")
    for layer in last:
        ct = layer.conv_tr
        per = ct.out_channels // len(model.sources)
        keep = slice(idx * per, (idx + 1) * per)
        ct.weight = nn.Parameter(ct.weight.detach()[:, keep].clone(), requires_grad=False)
        ct.bias = nn.Parameter(ct.bias.detach()[keep].clone(), requires_grad=False)
        ct.out_channels = per
    model.sources = ["vocals"]          # a new list: a bag shares the old one, all four sources


@contextlib.contextmanager
def _on_mps(model):
    """Feed the GPU from one CPU thread, and give its memory back afterwards."""
    import torch

    threads = torch.get_num_threads()
    # The CPU only feeds the GPU and runs the STFTs here: one thread keeps up, and
    # more only cost CPU time.
    torch.set_num_threads(1)
    try:
        yield
    finally:
        torch.set_num_threads(threads)
        # empty_cache can't free the heap the weights sit in (~190 MB) while they're on it.
        model.to("cpu")
        torch.mps.empty_cache()


def _resample(x, old_sr: int, new_sr: int, block_frames: int = 1 << 14):
    """julius.resample_frac(x, old_sr, new_sr) for x of shape [1, T], computed a
    block of output frames at a time instead of padding and convolving the
    whole signal at once (same kernel, same replicate padding at the ends)."""
    import julius
    import torch
    import torch.nn.functional as F

    rs = julius.ResampleFrac(old_sr, new_sr)
    if rs.old_sr == rs.new_sr:
        return x
    step, per, width = rs.old_sr, rs.new_sr, rs._width
    kernel = rs.kernel.to(x)
    length = x.shape[-1]
    frames = length // step + 1                    # frames of julius's single convolution
    out_len = int(torch.floor(torch.as_tensor(per * length / step)).long())
    y = torch.empty(1, frames * per, dtype=x.dtype)
    for k0 in range(0, frames, block_frames):
        k1 = min(frames, k0 + block_frames)
        lo, hi = k0 * step - width, (k1 - 1) * step + step + width   # input span, padded coords
        seg = x[:, max(lo, 0):min(hi, length)]
        seg = F.pad(seg[:, None], (max(0, -lo), max(0, hi - length)), mode="replicate")
        ys = F.conv1d(seg, kernel, stride=step)                      # [1, per, k1 - k0]
        y[:, k0 * per:k1 * per] = ys.transpose(1, 2).reshape(1, -1)
    return y[:, :out_len]


def _vocals(model, mix_n, mean, std, device, progress: bool):
    """The vocals source of apply_model(model, mix_n, shifts=0, split=True,
    overlap=0.25), de-normalized and averaged to mono: [1, T].

    apply_model accumulates every source of every segment into whole-file
    tensors. This runs the same segments with the same triangular weights and
    adds them up in the same order, but keeps only the vocals and only the
    segment-long window that is still receiving contributions, so memory does
    not grow with the input. Bags of several models take apply_model's own path.
    """
    import torch
    from demucs.apply import BagOfModels, TensorChunk, apply_model

    vidx = model.sources.index("vocals")
    if isinstance(model, BagOfModels) and len(model.models) != 1:
        out = apply_model(model, mix_n, device=device, shifts=0, split=True, overlap=0.25,
                          progress=progress)
        return (out * std + mean)[0, vidx].mean(dim=0, keepdim=True)

    if isinstance(model, BagOfModels):
        sub, inst_weight = model.models[0], model.weights[0][vidx]
    else:
        sub, inst_weight = model, 1.0
    total_weight = 0.0 + inst_weight
    oidx = sub.sources.index("vocals")      # 0 once _keep_vocals has trimmed the model
    sub.to(device)
    sub.eval()
    channels, length = mix_n.shape[1], mix_n.shape[-1]
    seg = int(sub.samplerate * sub.segment)
    stride = int((1 - 0.25) * seg)
    weight = torch.cat([torch.arange(1, seg // 2 + 1, device=device),
                        torch.arange(seg - seg // 2, 0, -1, device=device)])
    weight = (weight / weight.max()) ** 1.0

    voc = torch.empty(1, length)
    acc = torch.zeros(1, channels, seg + stride)          # covers [start, start + seg + stride)
    acc_w = torch.zeros(seg + stride)
    start = 0

    def finalize(upto: int) -> None:
        """Positions [start, upto) get no more segments: write them out."""
        nonlocal acc, acc_w, start
        n = upto - start
        if n <= 0:
            return
        v = acc[0, :, :n] / acc_w[:n]                       # out /= sum_weight
        v[:] *= inst_weight                                  # bag: out[:, k] *= weight
        v = 0.0 + v                                          # bag: estimates += out
        v /= total_weight                                    # bag: estimates /= totals
        v = v * std + mean
        voc[0, start:upto] = v.mean(dim=0)
        acc = torch.cat([acc[..., n:], torch.zeros(1, channels, n)], dim=-1)
        acc_w = torch.cat([acc_w[n:], torch.zeros(n)])
        start = upto

    def separate(offset: int):
        with torch.no_grad():                               # grad mode is per thread
            return apply_model(sub, TensorChunk(mix_n, offset, seg), shifts=0, split=False,
                               overlap=0.25, device=device)

    # Like demucs's own num_workers, run segments on a thread pool; they are still
    # added up one at a time in order, so the result doesn't depend on the count.
    offsets = range(0, length, stride)
    workers = _WORKERS if device == "cpu" else 1
    with contextlib.closing(_ordered_map(separate, offsets, workers)) as outs:
        if progress:
            import tqdm
            outs = tqdm.tqdm(outs, total=len(offsets), ncols=120, unit="seconds",
                             unit_scale=float(format(stride / sub.samplerate, ".2f")))
        for offset, chunk_out in zip(offsets, outs, strict=True):
            finalize(offset)
            n = chunk_out.shape[-1]
            acc[..., :n] += (weight[:n] * chunk_out[:, oidx]).to(acc.device)
            acc_w[:n] += weight[:n].to(acc.device)
    finalize(length)
    return voc


def _ordered_map(fn, items, workers: int):
    """Yield fn(item) for each of items in order, computing up to `workers` at once."""
    if workers <= 1:
        yield from map(fn, items)
        return
    items = iter(items)
    with ThreadPoolExecutor(workers) as pool:
        pending = deque(pool.submit(fn, item) for item in itertools.islice(items, workers))
        while pending:
            result = pending.popleft().result()
            pending.extend(pool.submit(fn, item) for item in itertools.islice(items, 1))
            yield result
