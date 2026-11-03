"""Hand memory that macOS's malloc keeps cached after a free back to the system.

libmalloc keeps the last 64 freed large blocks mapped for reuse, whatever
their size, so after demucs its freed activations (1.0 GB on 150 s) still
count against this process while the Sidon runner peaks beside it, and
malloc_zone_pressure_relief leaves that cache alone. Allocating and freeing
more large blocks than the cache holds, never touched so they cost no pages,
pushes the old entries out, and an entry pushed out is unmapped.
"""

from __future__ import annotations

import ctypes
import sys

_BLOCK = 16 << 20       # above the 8 MB medium-allocator limit: a large block
_COUNT = 128            # twice the cache's 64 entries
_libc = None


def release_cached() -> None:
    """Unmap the large blocks malloc keeps cached (~15 ms; nothing off macOS)."""
    global _libc
    if sys.platform != "darwin":
        return
    if _libc is None:
        try:
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        except OSError:
            return
        libc.malloc.restype = ctypes.c_void_p
        libc.malloc.argtypes = [ctypes.c_size_t]
        libc.free.argtypes = [ctypes.c_void_p]
        _libc = libc
    blocks = [_libc.malloc(_BLOCK) for _ in range(_COUNT)]
    for block in blocks:
        if block:
            _libc.free(block)
