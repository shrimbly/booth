"""JSON Lines event channel for the Booth app (protocol 1).

In events mode stdout carries nothing but one JSON object per line. Everything
human-readable — our own logs, warnings, tqdm, and the output of every child
process — goes to stderr. To make that hold even for code we don't control,
the real stdout is duplicated to a private descriptor for events and fd 1 is
pointed at stderr.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import threading
import time
from collections.abc import Callable

from . import atomic

PROTOCOL = 1

TERMINAL_EVENTS = {"done", "error"}


class Cancelled(BaseException):
    """Raised in the main thread when the app cancels the run.

    A BaseException so engine fallbacks (`except Exception`) never swallow it.
    """


class JobError(Exception):
    """A failure with a protocol error code and a sentence for the user."""

    def __init__(self, code: str, message: str, detail: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


class EventStream:
    """Thread-safe JSONL writer. Closes itself after a terminal event.

    If the app goes away mid-run (a write fails with EPIPE), the stream marks
    itself `broken` and calls `on_broken` once, which `install_cancel_handler`
    points at the normal cancel path: an orphaned engine must not keep going.
    """

    def __init__(self, fd: int):
        self._fd = fd
        # Re-entrant: the SIGTERM handler runs on the main thread and may
        # interrupt it mid-emit.
        self._lock = threading.RLock()
        self.closed = False          # nothing more will be written
        self.terminal_sent = False   # a done/error line was written in full
        self.broken = False          # the reader went away
        self.on_broken: Callable[[], None] | None = None

    def emit(self, event: str, **fields) -> None:
        line = json.dumps({"event": event, **fields}, ensure_ascii=False,
                          separators=(",", ":")) + "\n"
        data = line.encode("utf-8")
        with self._lock:
            if self.closed:
                return
            terminal = event in TERMINAL_EVENTS
            if terminal:
                self.closed = True
            try:
                while data:
                    data = data[os.write(self._fd, data):]
            except BrokenPipeError:
                if terminal:             # the run is ending anyway
                    self.closed = self.broken = True
                else:
                    self.reader_gone()
                return
            if terminal:
                self.terminal_sent = True

    def reader_gone(self) -> None:
        """The app is gone: stop writing and start the cancel path (once)."""
        with self._lock:
            if self.broken:
                return
            self.closed = self.broken = True
        if self.on_broken is not None:
            self.on_broken()

    @property
    def finishing(self) -> bool:
        """A terminal event was written, or is being written, to a live reader."""
        return self.closed and not self.broken


def open_event_stream() -> EventStream:
    """Claim stdout for events and route every other byte to stderr."""
    sys.stdout.flush()
    events_fd = os.dup(1)
    os.dup2(2, 1)
    return EventStream(events_fd)


def become_process_group_leader() -> None:
    """Own process group, so the app can signal us and all children at once."""
    try:
        os.setpgrp()
    except OSError:
        pass  # already a group or session leader


def install_cancel_handler(stream: EventStream, grace_s: float = 5.0) -> None:
    """SIGTERM/SIGINT → `cancelled` error, children killed, unwind, exit 130.

    The handler raises Cancelled so context managers remove temp files and
    temp dirs on the way out; a watchdog hard-exits if unwinding stalls. A
    broken event pipe (the app died) takes the same path.
    """

    def handle(signum, frame):
        if stream.finishing:
            return  # already finished; let the normal exit happen
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        stream.emit("error", code="cancelled", message="Cancelled.")
        try:
            os.killpg(os.getpgrp(), signal.SIGTERM)  # children; we ignore it now
        except OSError:
            pass
        threading.Thread(target=_hard_exit_after, args=(grace_s,), daemon=True).start()
        raise Cancelled()

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)
    # A lost reader cancels like the app would. Signalling ourselves works
    # from any thread: Python runs the handler on the main thread.
    stream.on_broken = cancel_self


def cancel_self() -> None:
    """Start the cancel path, from any thread."""
    os.kill(os.getpid(), signal.SIGTERM)


def _hard_exit_after(seconds: float) -> None:
    time.sleep(seconds)
    atomic.remove_partials()
    os._exit(130)


def error_fields(code: str, message: str, detail: str | None = None) -> dict:
    fields = {"code": code, "message": message}
    if detail and detail.strip() != message:
        fields["detail"] = detail.strip()[-4000:]
    return fields
