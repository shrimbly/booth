"""Atomic output files: write to a hidden temp file beside the target, then rename.

A cancelled or crashed run therefore never leaves a half-written output where
the user (or Finder) would see it. The temp name keeps the real extension so
ffmpeg and soundfile still infer the container from it. `transaction` does the
same for a set of files that must appear together or not at all.
"""

from __future__ import annotations

import errno
import os
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

_live: set[Path] = set()


def partial_path(final: Path) -> Path:
    return final.with_name(f".{final.stem}.{os.getpid()}.partial{final.suffix}")


@contextmanager
def replacing(final: str | Path) -> Iterator[Path]:
    """Yield a temp path; on clean exit it atomically replaces `final`."""
    final = Path(final)
    tmp = partial_path(final)
    _live.add(tmp)
    try:
        yield tmp
        os.replace(tmp, final)
    finally:
        _live.discard(tmp)
        tmp.unlink(missing_ok=True)


@contextmanager
def transaction(finals: list[Path]) -> Iterator[list[Path]]:
    """Yield a temp path per final. On clean exit every temp replaces its final,
    in the order given; on any error or cancel all of them are deleted."""
    finals = [Path(f) for f in finals]
    tmps = [partial_path(f) for f in finals]
    _live.update(tmps)
    try:
        yield tmps
        for tmp, final in zip(tmps, finals, strict=True):
            os.replace(tmp, final)
    finally:
        for tmp in tmps:
            _live.discard(tmp)
            tmp.unlink(missing_ok=True)


def check_writable(final: str | Path) -> None:
    """Raise the OSError a write of `final` would hit, without touching `final`.

    Creates and deletes the temp file the real write would use. A folder that
    does not exist yet is judged by its nearest existing parent.
    """
    final = Path(final)
    folder = final.parent
    if not folder.is_dir():
        while not folder.exists() and folder != folder.parent:
            folder = folder.parent
        if not os.access(folder, os.W_OK | os.X_OK):
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(folder))
        return
    tmp = partial_path(final)
    try:
        os.close(os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
    except FileExistsError:
        return                  # a stale temp of ours: the folder takes writes
    os.unlink(tmp)


def remove_partials() -> None:
    """Delete temp files of writes still in flight (last-resort exit path)."""
    for tmp in list(_live):
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
