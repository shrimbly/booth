"""What the default (Sidon) pipeline needs on disk, checked without heavy imports.

`app-info` must answer in well under two seconds, so nothing here imports
torch, huggingface_hub or the engines' model code: every check is a
filesystem probe of the same cache locations those libraries use.
"""

from __future__ import annotations

import csv
import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import tools

SIDON_VENV = tools.CACHE_DIR / "sidon-venv"
# The venv's install writes SIDON_INSTALLING here before it starts, and the pins
# once they have installed and imported. A venv with no marker predates it.
SIDON_MARKER = SIDON_VENV / ".booth-install"
SIDON_INSTALLING = "installing\n"
# Every package in the Sidon venv at an exact version: the runner's imports and
# everything they pull in, as uv resolved them for Python 3.11 on macOS arm64.
# A new torch, transformers or other upstream release can't change the engine.
SIDON_PINS = (
    "torch==2.15.0", "transformers==5.21.0", "huggingface_hub==2.3.0",
    "soundfile==0.14.0", "numpy==2.4.6", "scipy==1.17.1",
    "annotated-doc==0.0.5", "anyio==4.15.1", "cffi==2.1.1", "click==8.5.0",
    "filelock==4.2.4", "fsspec==2026.9.0", "h11==0.16.0", "hf-xet==1.7.1",
    "httpcore2==2.16.0", "httpx2==2.16.0", "idna==3.20", "jinja2==3.1.6",
    "markdown-it-py==4.2.0", "markupsafe==3.0.4", "mdurl==0.1.2", "mpmath==1.3.0",
    "networkx==3.6.1", "packaging==26.3", "pycparser==3.12", "pygments==2.21.0",
    "pyyaml==6.0.3", "regex==2026.9.29", "rich==15.0.0", "safetensors==0.8.0",
    "setuptools==84.2.1", "shellingham==1.5.4", "sympy==1.14.0", "tokenizers==0.23.3",
    "tqdm==4.70.1", "truststore==0.10.5", "typer==0.27.3", "typing-extensions==4.16.0",
)
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
DF3_MODEL = "DeepFilterNet3"


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


def deepfilter_cache() -> Path:
    """DeepFilterNet's model cache (appdirs.user_cache_dir, as df.utils uses)."""
    try:
        from appdirs import user_cache_dir
        return Path(user_cache_dir("DeepFilterNet"))
    except ImportError:
        if sys.platform == "darwin":
            return Path.home() / "Library" / "Caches" / "DeepFilterNet"
        return Path.home() / ".cache" / "DeepFilterNet"


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


def sidon_marker_text() -> str:
    return "\n".join(SIDON_PINS) + "\n"


def sidon_venv_ready() -> bool:
    """True once an install of the current pins finished (see SIDON_MARKER).

    A venv set up before the marker existed is adopted, marker written, when
    every pinned package is on disk in full, so a working one isn't rebuilt.
    """
    if not (SIDON_VENV / "bin" / "python").exists():
        return False
    try:
        return SIDON_MARKER.read_text() == sidon_marker_text()
    except FileNotFoundError:
        pass
    except OSError:
        return False
    sites = (SIDON_VENV / "lib").glob("python3*/site-packages")
    if not any(_pins_installed(site) for site in sites):
        return False
    try:
        SIDON_MARKER.write_text(sidon_marker_text())
    except OSError:
        pass                      # still complete: adopted again next time
    return True


def _dist_name(name: str) -> str:
    return re.sub(r"[-_.]+", "_", name).lower()


def _pins_installed(site: Path) -> bool:
    """Every pinned package is installed once, at its pinned version, with every
    file its RECORD lists (an interrupted install leaves some missing)."""
    found: dict[str, list[tuple[str, Path]]] = {}
    for info in site.glob("*.dist-info"):
        name, _, version = info.name.removesuffix(".dist-info").rpartition("-")
        found.setdefault(_dist_name(name), []).append((version, info))
    infos = []
    for pin in SIDON_PINS:
        name, _, version = pin.partition("==")
        have = found.get(_dist_name(name), [])
        if [v for v, _ in have] != [version]:
            return False
        infos.append(have[0][1])
    try:
        for info in infos:
            with open(info / "RECORD", newline="") as f:
                if not all(os.path.lexists(site / row[0]) for row in csv.reader(f) if row):
                    return False
    except OSError:
        return False
    return True


def _htdemucs_present() -> bool:
    return (hf_has(HTDEMUCS_REPO, HTDEMUCS_FILES)
            or (torch_hub_checkpoints() / HTDEMUCS_LEGACY).is_file())


def _df3_present() -> bool:
    model = deepfilter_cache() / DF3_MODEL
    try:
        return (model / "config.ini").is_file() and any((model / "checkpoints").iterdir())
    except OSError:
        return False


@dataclass(frozen=True)
class Requirement:
    id: str
    label: str
    download_bytes: int       # what a fresh install fetches (0: not a model download)
    present: Callable[[], bool]


# Sizes are the published file sizes (Sidon 795 498 929 + 209 824 877,
# HTDemucs 84 025 440 + yaml, DeepFilterNet3 archive ≈ its 8.7 MB contents).
REQUIREMENTS: tuple[Requirement, ...] = (
    Requirement("ffmpeg", "ffmpeg", 0, lambda: not tools.missing_ffmpeg_tools()),
    Requirement("sidon-venv", "voice engine", 0, sidon_venv_ready),
    Requirement("sidon-weights", "Sidon voice model", 1_005_323_806,
                lambda: hf_has(SIDON_REPO, SIDON_FILES, SIDON_REVISION)),
    Requirement("w2v-bert", "w2v-BERT preprocessor", 275,
                lambda: hf_has(W2V_REPO, W2V_FILES, W2V_REVISION)),
    Requirement("htdemucs", "music separation model", 84_025_461, _htdemucs_present),
    Requirement("df3", "DeepFilterNet3 model", 8_716_140, _df3_present),
)

BY_ID = {r.id: r for r in REQUIREMENTS}


def missing(only: set[str] | None = None) -> list[Requirement]:
    return [r for r in REQUIREMENTS if (only is None or r.id in only) and not r.present()]


def download_bytes(reqs: list[Requirement]) -> int:
    return sum(r.download_bytes for r in reqs)
