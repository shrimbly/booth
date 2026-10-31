"""Speech enhancement via ClearVoice MossFormer2_SE_48K (48 kHz native).

clearvoice's dependency pins conflict with this project's stack, so it runs
out-of-process in its own uv-managed environment (`uv run --no-project
--with clearvoice`). uv caches that env after the first run. Callers should
catch failures and fall back to DeepFilterNet3.

ClearVoice downloads its checkpoint to `checkpoints/` relative to the working
directory, so the runner always starts in the engine cache directory — the
caller's cwd (the app runs us inside a per-job folder) must not matter.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import numpy as np

from .. import audio as A
from .. import tools

_RUNNER = """
import sys
from clearvoice import ClearVoice
cv = ClearVoice(task="speech_enhancement", model_names=["MossFormer2_SE_48K"])
wav = cv(input_path=sys.argv[1], online_write=False)
cv.write(wav, output_path=sys.argv[2])
"""


def enhance(audio: np.ndarray, sr: int) -> np.ndarray:
    """Denoise mono float32 speech at 48 kHz. Returns clean speech, same length."""
    with tempfile.TemporaryDirectory() as td:
        inp, out = Path(td) / "in.wav", Path(td) / "out.wav"
        A.write_wav(inp, audio, sr, subtype="FLOAT")
        uv = tools.uv_path()
        if uv is None:
            raise RuntimeError("mossformer2 engine needs uv, which was not found")
        tools.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        p = subprocess.run(
            [uv, "run", "--no-project", "--python", "3.11",
             "--with", "clearvoice", "python", "-c", _RUNNER, str(inp), str(out)],
            capture_output=True, text=True, cwd=tools.CACHE_DIR)
        if p.returncode != 0 or not out.exists():
            raise RuntimeError(f"mossformer2 engine failed:\n{p.stderr[-1200:]}")
        y = A.decode(out, sr)
    if len(y) < len(audio):
        y = np.pad(y, (0, len(audio) - len(y)))
    return y[:len(audio)].astype(np.float32)
