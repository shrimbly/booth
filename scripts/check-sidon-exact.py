"""Check that Sidon's fast models compute the traced models' exact bits on this Mac.

The Sidon runner (src/booth/engines/sidon.py) re-runs the traced w2v-BERT encoder
and DAC vocoder in faster eager forms that match them bit for bit on the M5 Pro
they were written on; Accelerate may round differently on other chips. This runs
the runner's own code up to its first chunk, then both forms of each model on
every chunk it cut, and reports any difference (exit status 1).

Usage: uv run python scripts/check-sidon-exact.py <audio file>
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from booth import audio as A           # noqa: E402
from booth import requirements as R    # noqa: E402
from booth.engines import sidon        # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "in.wav"
        A.write_wav(wav, A.decode(sys.argv[1], 48000), 48000, subtype="FLOAT")
        sys.argv[1:] = [str(wav), str(Path(td) / "out.wav"), R.SIDON_REPO, R.SIDON_REVISION,
                        R.W2V_REPO, R.W2V_REVISION, "30.0"]
        run: dict = {}
        # Everything up to restoring: the models, the fast pair and the chunk cuts.
        prefix, found, _ = sidon._RUNNER.partition('tell(f"@@sidon loaded')
        assert found, "the runner's 'loaded' line has moved; update this script"
        exec(prefix, run)
    if run["fast"] is None:
        return 1                        # the runner has said why
    encoder, vocoder = run["fast"]
    x16, cuts, ctx = run["x16"], run["cuts"], run["CTX"]
    exact = True
    for i, (a, b) in enumerate(zip(cuts[:-1], cuts[1:]), 1):
        with torch.inference_mode():
            f = run["features"](x16[max(0, a - ctx):min(len(x16), b + ctx)])
            h = run["fe"](f)["last_hidden_state"]
            enc = torch.equal(encoder(f)["last_hidden_state"], h)
            h = h.transpose(1, 2)
            voc = np.array_equal(vocoder.decode(h), run["dec"](h).view(-1).numpy())
        print(f"chunk {i}/{len(cuts) - 1} ({h.shape[-1]} frames): "
              f"encoder {'identical' if enc else 'DIFFERS'}, "
              f"vocoder {'identical' if voc else 'DIFFERS'}", flush=True)
        exact &= enc and voc
    print("bit-identical" if exact else "NOT bit-identical: the fast models change Sidon's "
          "output on this Mac")
    return 0 if exact else 1


if __name__ == "__main__":
    sys.exit(main())
