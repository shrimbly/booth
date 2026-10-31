"""Speech enhancement via DeepFilterNet3 (48 kHz native).

DF3 is causal apart from two frames of lookahead, so it runs block by block
with all of its state carried across blocks — STFT memories, feature
normalization, GRU states and the conv context — and gives the same output as
one whole-file pass with memory that does not grow with the input length.
"""

from __future__ import annotations

import math

import numpy as np

_state = None

# DF3 outputs digital silence when active speech is below about -47 dBFS, so quieter
# input is raised to a typical level for the model and its output lowered to match.
QUIET_SPEECH_DB = -40.0
MODEL_SPEECH_DB = -26.0
MAX_LIFT_DB = 40.0

BLOCK_FRAMES = 1000         # 10 s of 10 ms frames per model call
CONTEXT_FRAMES = 6          # past frames the convs need: 3-frame input conv + 5-frame DF pathway
LOOKAHEAD_FRAMES = 2        # future frames: feature lookahead and DF lookahead


def _init():
    global _state
    if _state is None:
        # Silence loguru's default INFO spam before df touches it.
        try:
            from loguru import logger
            logger.remove()
        except Exception:
            pass
        # df probes its own git checkout for a version string at init; outside
        # a git repo that prints "fatal: not a git repository" to the terminal.
        import df.logger
        import df.utils
        df.utils.get_git_root = lambda: None
        df.logger.get_commit_hash = lambda: None
        df.logger.get_branch_name = lambda: None
        from df.enhance import init_df
        # post_filter: perceptual post-filter, measured ~2 dB extra noise attenuation
        _state = init_df(post_filter=True, log_level="WARNING", log_file=None)  # DeepFilterNet3
    return _state


def enhance(audio: np.ndarray, sr: int) -> np.ndarray:
    """Denoise mono float32 speech at 48 kHz. Returns clean speech, same length."""
    import torch

    model, df_state, _ = _init()
    assert df_state.sr() == sr, f"DeepFilterNet runs at {df_state.sr()} Hz, got {sr}"
    model.eval()                    # as df.enhance does: init_df returns it in training mode

    lift = _lift(audio, sr)
    if lift != 1.0:
        audio = audio * lift
    with torch.no_grad():
        if _Stream.supports(model):
            out = _Stream(model, df_state).run(np.asarray(audio, dtype=np.float32))
        else:                       # an unfamiliar model layout: whole-file pass
            from df.enhance import enhance as df_enhance
            y = df_enhance(model, df_state, torch.from_numpy(audio.astype(np.float32))[None])
            out = y.squeeze(0).cpu().numpy().astype(np.float32)
    # Guarantee equal length
    if len(out) < len(audio):
        out = np.pad(out, (0, len(audio) - len(out)))
    out = out[:len(audio)]
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


class _Stream:
    """df.enhance.enhance(model, df_state, audio, pad=True), one block at a time.

    Output frame t depends on spectrum frames t-2..t+2, on feature frames
    t-6..t+2 through the convolutions, and on every earlier frame through the
    GRUs and the running feature normalization. Each block feeds the model its
    frames plus that context, carries the GRU states and normalization states
    to the next block, and keeps only its own frames.
    """

    @staticmethod
    def supports(model) -> bool:
        def temporal_kernel(module) -> int:
            conv = next(m for m in module.modules() if hasattr(m, "kernel_size"))
            return conv.kernel_size[0]
        try:
            dec = model.erb_dec
            per_frame = [model.enc.erb_conv1, model.enc.erb_conv2, model.enc.erb_conv3,
                         model.enc.df_conv1, dec.conv3p, dec.convt3, dec.conv2p, dec.convt2,
                         dec.conv1p, dec.convt1, dec.conv0p, dec.conv0_out]
            return (model.run_erb and model.run_df and not model.lsnr_droput
                    and model.df_lookahead == LOOKAHEAD_FRAMES
                    and model.pad_feat.padding[2:] == (-LOOKAHEAD_FRAMES, LOOKAHEAD_FRAMES)
                    and temporal_kernel(model.enc.erb_conv0) == 3
                    and temporal_kernel(model.enc.df_conv0) == 3
                    and temporal_kernel(model.df_dec.df_convp) - 1 + 2 <= CONTEXT_FRAMES
                    and all(temporal_kernel(m) == 1 for m in per_frame)
                    and model.df_op.frame_size - 1 - model.df_op.lookahead <= CONTEXT_FRAMES)
        except (AttributeError, StopIteration, TypeError):
            return False

    def __init__(self, model, df_state):
        from df.utils import get_norm_alpha
        from libdf import unit_norm_init

        self.model, self.df = model, df_state
        self.alpha = np.float32(get_norm_alpha(False))
        self.erb_fb = df_state.erb_widths()
        self.nb_df = model.nb_df
        nb_erb = len(self.erb_fb)
        # libdf's initial normalization states (verified bit-exact against it).
        lo, hi = np.float32(-60.0), np.float32(-90.0)
        self.erb_state = lo + (hi - lo) / np.float32(nb_erb - 1) * np.arange(nb_erb,
                                                                          dtype=np.float32)
        self.unit_state = unit_norm_init(self.nb_df).reshape(-1).astype(np.float32)
        self.h_enc = self.h_erb = self.h_df = None

    def run(self, audio: np.ndarray) -> np.ndarray:
        df = self.df
        n_fft, hop = df.fft_size(), df.hop_size()
        assert n_fft == 2 * hop, "block overlap below assumes 50 % STFT overlap"
        x = _Padded(audio, n_fft)                       # pad=True, without a copy
        total = x.length // hop
        out = np.zeros(len(audio), np.float32)
        delay = n_fft - hop         # the STFT/ISTFT loop's algorithmic delay
        frames = _Frames()
        last = None                 # the previous block's last enhanced frame
        for s in range(0, total, BLOCK_FRAMES):
            e = min(total, s + BLOCK_FRAMES)
            want = min(total, e + LOOKAHEAD_FRAMES)
            if frames.end < want:
                self._analyze(frames, x, frames.end, want)
            frames.drop_before(s - CONTEXT_FRAMES)
            spec_e = self._forward(frames, s, e)
            # libdf's synthesis starts each call with empty overlap memory, which
            # holds the previous frame: feed that frame again and drop its samples.
            # (It also overwrites its input, so keep the frame before the call.)
            fed = spec_e if last is None else np.concatenate([last, spec_e], axis=1)
            last = spec_e[:, -1:].copy()
            y = df.synthesis(fed)[0][(0 if fed is spec_e else hop):]
            a = s * hop - delay       # where this block's samples land in the output
            lo, hi = max(0, a), min(len(audio), a + len(y))
            if hi > lo:
                out[lo:hi] = y[lo - a:hi - a]
        return out

    def _analyze(self, frames: _Frames, x: _Padded, f0: int, f1: int) -> None:
        """Analyze frames [f0, f1) of the padded input `x` and normalize their features."""
        from libdf import erb, erb_norm, unit_norm

        hop = self.df.hop_size()
        # libdf's analysis starts each call with empty overlap memory, which
        # holds the previous hop of input: analyze one hop early and drop that frame.
        if f0 == 0:
            spec = self.df.analysis(x.slice(0, f1 * hop))           # [1, T, F] complex64
        else:
            spec = np.ascontiguousarray(self.df.analysis(x.slice((f0 - 1) * hop, f1 * hop))[:, 1:])
        a, one = self.alpha, np.float32(1.0)
        erb_db = erb(spec, self.erb_fb)                    # [1, T, E]
        erb_feat = erb_norm(erb_db.copy(), float(a), self.erb_state[None].copy())
        unit_feat = unit_norm(spec[..., :self.nb_df], float(a), self.unit_state[None].copy())
        for k in range(spec.shape[1]):                     # carry the states, as libdf does
            self.erb_state = erb_db[0, k] * (one - a) + self.erb_state * a
            self.unit_state = np.abs(spec[0, k, :self.nb_df]) * (one - a) + self.unit_state * a
        frames.append(spec[0], erb_feat[0], unit_feat[0])

    def _forward(self, frames: _Frames, s: int, e: int) -> np.ndarray:
        """Enhanced spectrum of frames [s, e) as [1, e-s, F] complex64."""
        import torch
        from df.utils import as_complex, as_real

        m = self.model
        lo, hi = frames.start, frames.end            # frames fed: [s - context, e + lookahead)
        j0, n = s - lo, e - s                        # this block's frames within them
        spec = as_real(torch.as_tensor(frames.spec[None, None]))           # [1, 1, T, F, 2]
        feat_erb = torch.as_tensor(frames.erb[None, None])                 # [1, 1, T, E]
        feat_spec = as_real(torch.as_tensor(frames.unit[None, None]))      # [1, 1, T, F', 2]
        # The model shifts features left by the lookahead and zero-fills the end.
        # Inside the file the zero-filled frames are lookahead context only; the
        # last block ends at the file's end, where the whole-file pass pads too.
        feat_spec = feat_spec.squeeze(1).permute(0, 3, 1, 2)
        feat_erb, feat_spec = m.pad_feat(feat_erb), m.pad_feat(feat_spec)

        enc = m.enc
        e0 = enc.erb_conv0(feat_erb)
        e1 = enc.erb_conv1(e0)
        e2 = enc.erb_conv2(e1)
        e3 = enc.erb_conv3(e2)
        c0 = enc.df_conv0(feat_spec)
        c1 = enc.df_conv1(c0)
        core = slice(j0, j0 + n)
        cemb = enc.df_fc_emb(c1[:, :, core].permute(0, 2, 3, 1).flatten(2))
        emb = enc.combine(e3[:, :, core].permute(0, 2, 3, 1).flatten(2), cemb)
        emb, self.h_enc = enc.emb_gru(emb, self.h_enc)

        dec = m.erb_dec
        b, _, t, f8 = e3[:, :, core].shape
        demb, self.h_erb = dec.emb_gru(emb, self.h_erb)
        demb = demb.view(b, t, f8, -1).permute(0, 3, 1, 2)
        d3 = dec.convt3(dec.conv3p(e3[:, :, core]) + demb)
        d2 = dec.convt2(dec.conv2p(e2[:, :, core]) + d3)
        d1 = dec.convt1(dec.conv1p(e1[:, :, core]) + d2)
        mask = dec.conv0_out(dec.conv0p(e0[:, :, core]) + d1)
        spec_core = spec[:, :, core]
        spec_m = m.mask(spec_core, mask)

        ddec = m.df_dec
        c, self.h_df = ddec.df_gru(emb, self.h_df)
        if ddec.df_skip is not None:
            c = c + ddec.df_skip(emb)
        c0p = ddec.df_convp(c0)[:, :, core].permute(0, 2, 3, 1)
        c = ddec.df_out(c).view(b, t, ddec.df_bins, ddec.df_out_ch) + c0p
        coefs = torch.zeros((b, hi - lo, ddec.df_bins, ddec.df_out_ch))
        coefs[:, core] = c
        spec_e = m.df_op(spec.clone(), m.df_out_transform(coefs))[:, :, core]
        spec_e[..., self.nb_df:, :] = spec_m[..., self.nb_df:, :]

        if m.post_filter:
            beta, eps = m.post_filter_beta, 1e-12
            pf_mask = (as_complex(spec_e).abs() / as_complex(spec_core).abs().add(eps)).clamp(eps, 1)
            mask_sin = pf_mask * torch.sin(math.pi * pf_mask / 2).clamp_min(eps)
            pf = (1 + beta) / (1 + beta * pf_mask.div(mask_sin).pow(2))
            spec_e = spec_e * pf.unsqueeze(-1)
        return np.ascontiguousarray(as_complex(spec_e.squeeze(1)).numpy())


class _Padded:
    """`audio` followed by `pad` zeros, sliced on demand as [1, n] float32."""

    def __init__(self, audio: np.ndarray, pad: int):
        self.audio, self.length = audio, len(audio) + pad

    def slice(self, a: int, b: int) -> np.ndarray:
        out = np.zeros((1, b - a), np.float32)
        real = self.audio[a:min(b, len(self.audio))]
        out[0, :len(real)] = real
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
