"""What the default (Sidon) pipeline needs on disk, checked without heavy imports.

`app-info` must answer in well under two seconds, so nothing here imports
torch, huggingface_hub or the engines' model code: every check is a
filesystem probe of the same cache locations those libraries use.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import tools

# Model files are pinned to the Hugging Face commits the engine was tested with.
SIDON_REPO = "sarulab-speech/sidon-v0.1"
SIDON_REVISION = "b3b02d8bbd55fdbc410e6e46e76ef95ace4fbf52"
SIDON_FILES = ("feature_extractor_cpu.pt", "decoder_cpu.pt")
W2V_REPO = "facebook/w2v-bert-2.0"
W2V_REVISION = "da985ba0987f70aaeb84a80f2851cfac8c697a7b"
W2V_FILES = ("preprocessor_config.json",)
HTDEMUCS_REPO = "adefossez/HTDemucs"
HTDEMUCS_FILES = ("htdemucs.yaml", "955717e8.safetensors")
HTDEMUCS_LEGACY = "955717e8-8726e21a.th"     # demucs' fallback download (torch hub)


def hf_hub_cache() -> Path:
    """huggingface_hub's cache root, resolved from the same env vars it reads."""
    explicit = os.environ.get("HF_HUB_CACHE") or os.environ.get("HUGGINGFACE_HUB_CACHE")
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("HF_HOME") or os.path.join(
        os.environ.get("XDG_CACHE_HOME", "~/.cache"), "huggingface")
    return Path(home).expanduser() / "hub"


def torch_hub_checkpoints() -> Path:
    home = os.environ.get("TORCH_HOME") or os.path.join(
        os.environ.get("XDG_CACHE_HOME", "~/.cache"), "torch")
    return Path(home).expanduser() / "hub" / "checkpoints"


def _hf_repo_dir(repo: str) -> Path:
    return hf_hub_cache() / f"models--{repo.replace('/', '--')}"


def hf_has(repo: str, files: tuple[str, ...], revision: str | None = None) -> bool:
    """True if the cached snapshot of `repo` at `revision` (a commit hash; None:
    any snapshot) has every file (symlinks resolved)."""
    snapshots = _hf_repo_dir(repo) / "snapshots"
    try:
        snaps = [snapshots / revision] if revision else list(snapshots.iterdir())
        return any(all((snap / f).is_file() for f in files) for snap in snaps)
    except OSError:
        return False


def _htdemucs_present() -> bool:
    return (hf_has(HTDEMUCS_REPO, HTDEMUCS_FILES)
            or (torch_hub_checkpoints() / HTDEMUCS_LEGACY).is_file())


@dataclass(frozen=True)
class Requirement:
    id: str
    label: str
    download_bytes: int       # what a fresh install fetches (0: not a model download)
    present: Callable[[], bool]


# Sizes are the published file sizes (Sidon 795 498 929 + 209 824 877,
# HTDemucs 84 025 440 + yaml, ffmpeg.zip 28 395 699 + ffprobe.zip 28 317 701).
# ffmpeg is only downloaded when none is installed, so an installed one counts
# as present. DeepFilterNet3 and Silero VAD ship with the engine.
REQUIREMENTS: tuple[Requirement, ...] = (
    Requirement("ffmpeg", "ffmpeg", 56_713_400, lambda: not tools.missing_ffmpeg_tools()),
    Requirement("sidon-weights", "Sidon voice model", 1_005_323_806,
                lambda: hf_has(SIDON_REPO, SIDON_FILES, SIDON_REVISION)),
    Requirement("w2v-bert", "w2v-BERT preprocessor", 275,
                lambda: hf_has(W2V_REPO, W2V_FILES, W2V_REVISION)),
    Requirement("htdemucs", "music separation model", 84_025_461, _htdemucs_present),
)

BY_ID = {r.id: r for r in REQUIREMENTS}


def missing(only: set[str] | None = None) -> list[Requirement]:
    return [r for r in REQUIREMENTS if (only is None or r.id in only) and not r.present()]


def download_bytes(reqs: list[Requirement]) -> int:
    return sum(r.download_bytes for r in reqs)
