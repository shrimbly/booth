"""Music/background split via Demucs htdemucs (lazy import — heavy)."""

from __future__ import annotations

import numpy as np

_model = None


def split_music(audio: np.ndarray, sr: int, device: str = "cpu",
                progress: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """Split mono audio into (vocals, accompaniment) at sr.

    accompaniment is computed as the exact complement (audio - vocals) so the
    decomposition reconstructs the input perfectly.
    """
    global _model
    import torch
    from demucs import pretrained

    if _model is None:
        _model = pretrained.get_model("htdemucs")
        _model.eval()
    model = _model
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

    dev = device
    if device == "auto":
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
    try:
        with torch.no_grad():
            voc44 = _vocals(model, mix_n, mean, std, dev, progress)
    except Exception:
        if dev == "cpu":
            raise
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
    tensors. This runs the same segments in the same order with the same
    triangular weights, but keeps only the vocals and only the segment-long
    window that is still receiving contributions, so memory does not grow with
    the input. Bags of several models take apply_model's own path.
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
    sub.to(device)
    sub.eval()
    channels, length = mix_n.shape[1], mix_n.shape[-1]
    seg = int(sub.samplerate * sub.segment)
    stride = int((1 - 0.25) * seg)
    weight = torch.cat([torch.arange(1, seg // 2 + 1, device=device),
                        torch.arange(seg - seg // 2, 0, -1, device=device)])
    weight = (weight / weight.max()) ** 1.0
    offsets = range(0, length, stride)
    if progress:
        import tqdm
        offsets = tqdm.tqdm(offsets, unit_scale=float(format(stride / sub.samplerate, ".2f")),
                            ncols=120, unit="seconds")

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

    for offset in offsets:
        finalize(offset)
        chunk_out = apply_model(sub, TensorChunk(mix_n, offset, seg), shifts=0, split=False,
                                overlap=0.25, device=device)
        n = chunk_out.shape[-1]
        acc[..., :n] += (weight[:n] * chunk_out[:, vidx]).to(acc.device)
        acc_w[:n] += weight[:n].to(acc.device)
    finalize(length)
    return voc
