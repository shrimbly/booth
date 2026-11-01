"""Export DeepFilterNet3's network as the ONNX graph the engine runs (src/booth/data/deepfilternet3.onnx).

The graph is the model's convolutions, GRUs and output layers, as booth.engines.deepfilter
streams them a block at a time; everything around them (the STFT, the features and their
normalization, the ERB mask, deep filtering, the post-filter) is numpy in that module.

  inputs   feat_erb [1, 1, W, 32]   normalized ERB features, already shifted by the lookahead
           feat_spec [1, 2, W, 96]  unit-normalized complex features (re, im), shifted the same
           core [n] int64           the window frames this call produces (indices into W)
           h_enc [1, 1, 256], h_erb [2, 1, 256], h_df [2, 1, 256]   GRU states
  outputs  mask [1, 1, n, 32]       ERB gains
           coefs [1, n, 96, 10]     deep filter taps (5 complex, re/im interleaved per tap)
           h_enc_out, h_erb_out, h_df_out   the GRU states after the core frames

It needs the old torch stack, which the engine no longer installs:

  uv run --no-project --python 3.11 --with deepfilternet==0.5.6 --with torch==2.2.2 \\
      --with torchaudio==2.2.2 --with 'numpy<2' --with onnx==1.16.2 \\
      scripts/export-deepfilternet3.py src/booth/data/deepfilternet3.onnx

The checkpoint is DeepFilterNet's own download, checked against the hashes Booth was tested with.
"""

import hashlib
import os
import sys
import warnings

warnings.filterwarnings("ignore")

import torch
from torch import nn

# The files of the DeepFilterNet3 checkpoint the engine was tested with.
SHA256 = {
    "config.ini": "415eb925d44990d938fb739f514aa3662c1ec0ea836cff044fa1291b82cb4290",
    "checkpoints/model_120.ckpt.best": "23b92884f63ccf54bb026014604625ab231657b6480df65db4095c4c171e6003",
}


def load():
    """DeepFilterNet3 with its post-filter, as df.enhance.init_df loads it."""
    from loguru import logger
    logger.remove()
    import df.logger
    import df.modules
    import df.utils
    # df probes its own git checkout for a version string; outside one that prints an error.
    df.utils.get_git_root = lambda: None
    df.logger.get_commit_hash = lambda: None
    df.logger.get_branch_name = lambda: None

    def grouped_forward(self, x):
        # GroupedLinearEinsum, with the time axis left symbolic for export.
        x = x.reshape(x.shape[0], -1, self.groups, self.ws)
        x = torch.einsum("btgi,gih->btgh", x, self.weight)
        return x.flatten(2, 3)

    df.modules.GroupedLinearEinsum.forward = grouped_forward
    from df.enhance import init_df
    model, _, _ = init_df(post_filter=True, log_level="WARNING", log_file=None)
    base = os.path.join(df.utils.get_cache_dir(), "DeepFilterNet3")
    for name, digest in SHA256.items():
        with open(os.path.join(base, name), "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != digest:
                sys.exit(f"{name} isn't the DeepFilterNet3 checkpoint Booth was tested with")
    return model.eval()


class Core(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.m = model

    def forward(self, feat_erb, feat_spec, core, h_enc, h_erb, h_df):
        m = self.m
        enc = m.enc
        e0 = enc.erb_conv0(feat_erb)
        e1 = enc.erb_conv1(e0)
        e2 = enc.erb_conv2(e1)
        e3 = enc.erb_conv3(e2)
        c0 = enc.df_conv0(feat_spec)
        c1 = enc.df_conv1(c0)

        def pick(x):
            return x.index_select(2, core)

        e0, e1, e2, e3, c1 = pick(e0), pick(e1), pick(e2), pick(e3), pick(c1)
        c0p = pick(m.df_dec.df_convp(c0)).permute(0, 2, 3, 1)          # [1, n, 96, 10]

        cemb = enc.df_fc_emb(c1.permute(0, 2, 3, 1).flatten(2))
        emb = enc.combine(e3.permute(0, 2, 3, 1).flatten(2), cemb)
        emb, h_enc = enc.emb_gru(emb, h_enc)

        dec = m.erb_dec
        demb, h_erb = dec.emb_gru(emb, h_erb)
        demb = demb.reshape(1, -1, 8, 64).permute(0, 3, 1, 2)
        d3 = dec.convt3(dec.conv3p(e3) + demb)
        d2 = dec.convt2(dec.conv2p(e2) + d3)
        d1 = dec.convt1(dec.conv1p(e1) + d2)
        mask = dec.conv0_out(dec.conv0p(e0) + d1)

        ddec = m.df_dec
        c, h_df = ddec.df_gru(emb, h_df)
        if ddec.df_skip is not None:
            c = c + ddec.df_skip(emb)
        coefs = ddec.df_out(c).reshape(1, -1, ddec.df_bins, ddec.df_out_ch) + c0p
        return mask, coefs, h_enc, h_erb, h_df


def main(out):
    core = Core(load()).eval()
    w, n = 40, 32
    args = (torch.randn(1, 1, w, 32), torch.randn(1, 2, w, 96), torch.arange(6, 6 + n),
            torch.zeros(1, 1, 256), torch.zeros(2, 1, 256), torch.zeros(2, 1, 256))
    with torch.no_grad():
        torch.onnx.export(
            core, args, out, opset_version=17,
            input_names=["feat_erb", "feat_spec", "core", "h_enc", "h_erb", "h_df"],
            output_names=["mask", "coefs", "h_enc_out", "h_erb_out", "h_df_out"],
            dynamic_axes={"feat_erb": {2: "W"}, "feat_spec": {2: "W"}, "core": {0: "n"},
                          "mask": {2: "n"}, "coefs": {1: "n"}},
            do_constant_folding=True)
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1])
