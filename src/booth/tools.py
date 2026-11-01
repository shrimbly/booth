"""Locating external tools and the engine's own cache directory.

Apps launched from Finder get a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
so ffmpeg and uv from Homebrew or ~/.local/bin would be invisible to every
subprocess. `ensure_tool_path()` appends the usual install locations, and the
ffmpeg setup downloads when there is none (see `BIN_DIR`).
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

# Engine-owned state: learned speeds, MossFormer2 checkpoints, downloaded ffmpeg.
CACHE_DIR = Path.home() / ".cache" / "booth"
# The ffmpeg and ffprobe setup downloads when none is installed. It comes last on
# PATH, so an ffmpeg of the user's own always wins.
BIN_DIR = CACHE_DIR / "bin"
# What earlier engines kept here and this one doesn't use: Sidon's own Python
# environment (about 850 MB) and its install lock.
LEFTOVERS = (CACHE_DIR / "sidon-venv", CACHE_DIR / "sidon-venv.lock")

_EXTRA_PATHS = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    str(Path.home() / ".local" / "bin"),
    str(Path.home() / ".cargo" / "bin"),
    str(BIN_DIR),
)


def ensure_tool_path() -> None:
    """Append common tool directories to PATH (idempotent; existing order wins).
    Only directories that exist are added, so call it again once setup has made one."""
    parts = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    missing = [p for p in _EXTRA_PATHS if p not in parts and os.path.isdir(p)]
    if missing:
        os.environ["PATH"] = os.pathsep.join(parts + missing)


def uv_path() -> str | None:
    """The uv executable: $BOOTH_ENGINE_UV, then PATH."""
    explicit = os.environ.get("BOOTH_ENGINE_UV")
    if explicit and os.access(explicit, os.X_OK):
        return explicit
    return shutil.which("uv")


def missing_ffmpeg_tools() -> list[str]:
    return [tool for tool in ("ffmpeg", "ffprobe") if shutil.which(tool) is None]


def remove_leftovers() -> None:
    """Delete LEFTOVERS. Setup does this, rather than every run, so an older Booth still
    installed alongside isn't pulled out from under a job."""
    for path in LEFTOVERS:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                path.unlink()
            except OSError:
                pass
