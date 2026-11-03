"""`booth setup`: install whatever the default pipeline is missing.

Every download runs as a child process of this Python — the Sidon weights,
htdemucs and ffmpeg — so a cancel kills them with the process group and the
main loop stays free to report progress. Download progress is measured by
polling the size of the directories the downloads write into (huggingface_hub,
torch hub, ffmpeg's partial folder), against the known size of each.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from . import __version__, tools
from . import requirements as R

TICK_S = 0.25
DEFAULT_RATE = 8e6            # bytes/s assumed until a download has been measured

# argv names what to fetch ("sidon-weights", "w2v-bert").
_SIDON_DOWNLOAD = f"""
import sys, warnings
warnings.filterwarnings("ignore")
if "sidon-weights" in sys.argv[1:]:
    from huggingface_hub import hf_hub_download
    for name in {R.SIDON_FILES!r}:
        hf_hub_download({R.SIDON_REPO!r}, name, revision={R.SIDON_REVISION!r})
if "w2v-bert" in sys.argv[1:]:
    import transformers   # the same call the runner makes, so the cache matches
    transformers.SeamlessM4TFeatureExtractor.from_pretrained({R.W2V_REPO!r},
                                                             revision={R.W2V_REVISION!r})
"""

_HTDEMUCS_DOWNLOAD = """
from demucs.pretrained import get_model
get_model("htdemucs")
"""

# ffmpeg and ffprobe for a Mac without them: Martin Riedl's static builds of
# FFmpeg 9.0.2 for Apple silicon, signed with his Developer ID. The build server
# keeps every release at its versioned address; the hashes are the ones it
# publishes beside each zip.
FFMPEG_BUILD = "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2"
FFMPEG_SHA256 = {
    "ffmpeg": "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924",
    "ffprobe": "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6",
}
FFMPEG_PARTIAL = tools.BIN_DIR.with_name(tools.BIN_DIR.name + ".partial")

# Unpacks beside the bin folder and moves the tools in only once both check out.
# (The build server turns away Python's default User-Agent.)
_FFMPEG_DOWNLOAD = f"""
import hashlib, os, shutil, sys, urllib.request, zipfile
part, final = {str(FFMPEG_PARTIAL)!r}, {str(tools.BIN_DIR)!r}
shutil.rmtree(part, ignore_errors=True)
os.makedirs(part)
try:
    for name, digest in {FFMPEG_SHA256!r}.items():
        archive = os.path.join(part, name + ".zip")
        request = urllib.request.Request({FFMPEG_BUILD!r} + "/" + name + ".zip",
                                         headers={{"User-Agent": "Booth/{__version__}"}})
        with urllib.request.urlopen(request, timeout=60) as r, open(archive, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
        with open(archive, "rb") as f:
            if hashlib.file_digest(f, "sha256").hexdigest() != digest:
                sys.exit(name + " download doesn't match the tested build")
        with zipfile.ZipFile(archive) as z:
            z.extract(name, part)
        os.chmod(os.path.join(part, name), 0o755)
        os.remove(archive)
    os.makedirs(final, exist_ok=True)
    for name in {tuple(FFMPEG_SHA256)!r}:
        os.replace(os.path.join(part, name), os.path.join(final, name))
finally:
    shutil.rmtree(part, ignore_errors=True)
"""

Emit = Callable[..., None]


class SetupError(Exception):
    def __init__(self, message: str, detail: str | None = None):
        super().__init__(message)
        self.message = message
        self.detail = detail


@dataclass
class Task:
    label: str                       # "music separation model", used in messages
    covers: tuple[str, ...]          # requirement ids this task installs
    commands: list[list[str]]
    env: dict | None = None
    state: str = "waiting"           # waiting → running → done | failed
    proc: subprocess.Popen | None = None
    tail: deque = field(default_factory=lambda: deque(maxlen=40))
    _next: int = 0

    def start_next(self) -> bool:
        """Start the next command; False (and a reason in the tail) if it can't run."""
        cmd = self.commands[self._next]
        self._next += 1
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, env=self.env)
        except OSError as e:
            self.tail.append(f"{cmd[0]}: {e}")
            return False
        os.set_blocking(self.proc.stdout.fileno(), False)
        return True

    def drain(self) -> None:
        if self.proc is None or self.proc.stdout is None:
            return
        try:
            chunk = self.proc.stdout.read()
        except (BlockingIOError, ValueError):
            return
        if chunk:
            self.tail.extend(chunk.decode(errors="replace").splitlines())

    @property
    def has_more(self) -> bool:
        return self._next < len(self.commands)


def dir_size(path: Path) -> int:
    """Bytes in regular files under `path` (symlinks not followed)."""
    total = 0
    stack = [path]
    while stack:
        try:
            with os.scandir(stack.pop()) as entries:
                for e in entries:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(Path(e.path))
                        elif e.is_file(follow_symlinks=False):
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            pass
    return total


class ByteMeter:
    """Download bytes so far, from cache-directory growth against known sizes."""

    def __init__(self, roots: dict[Path, int], size: Callable[[Path], int] = dir_size):
        self._size = size
        self._roots = {root: (size(root), expected) for root, expected in roots.items()}
        self._done = 0

    def measure(self, floor: int, total: int) -> int:
        grown = sum(min(max(0, self._size(root) - base), expected)
                    for root, (base, expected) in self._roots.items())
        self._done = min(total, max(self._done, grown, floor))
        return self._done


class RateMeter:
    """Recent download speed (bytes/s) over a sliding window.

    The window only opens once bytes start flowing, so the seconds spent
    importing torch or resolving packages don't read as a slow connection.
    """

    def __init__(self, window_s: float = 6.0):
        self._samples: deque[tuple[float, int]] = deque()
        self._window = window_s
        self._idle_bytes: int | None = None

    def add(self, t: float, done: int) -> None:
        if self._idle_bytes is None:
            self._idle_bytes = done
        if not self._samples and done == self._idle_bytes:
            return
        self._samples.append((t, done))
        while len(self._samples) > 2 and t - self._samples[0][0] > self._window:
            self._samples.popleft()

    def rate(self) -> float | None:
        """None until enough has arrived to say anything (metadata files don't count)."""
        if len(self._samples) < 2:
            return None
        (t0, b0), (t1, b1) = self._samples[0], self._samples[-1]
        if t1 - t0 < 2.0 or b1 - b0 < 1_000_000:
            return None
        return (b1 - b0) / (t1 - t0)


def check(only: set[str] | None = None) -> dict:
    missing = R.missing(only)
    return {"ready": not missing, "missing": [r.id for r in missing],
            "bytes_total": R.download_bytes(missing)}


def plan(missing: list[R.Requirement]) -> list[Task]:
    ids = {r.id for r in missing}
    env = dict(os.environ, HF_HUB_DISABLE_PROGRESS_BARS="1", HF_HUB_VERBOSITY="error",
               TQDM_DISABLE="1")
    tasks: list[Task] = []
    if "ffmpeg" in ids:
        tasks.append(Task("ffmpeg", ("ffmpeg",), [[sys.executable, "-c", _FFMPEG_DOWNLOAD]],
                          env=env))
    sidon_items = tuple(i for i in ("sidon-weights", "w2v-bert") if i in ids)
    if sidon_items:
        tasks.append(Task("Sidon voice model", sidon_items,
                          [[sys.executable, "-c", _SIDON_DOWNLOAD, *sidon_items]], env=env))
    if "htdemucs" in ids:
        tasks.append(Task("music separation model", ("htdemucs",),
                          [[sys.executable, "-c", _HTDEMUCS_DOWNLOAD]], env=env))
    return tasks


def _byte_roots(missing: list[R.Requirement]) -> dict[Path, int]:
    sizes = {r.id: r.download_bytes for r in missing}
    hub = sum(sizes.get(i, 0) for i in ("sidon-weights", "w2v-bert", "htdemucs"))
    roots = {R.hf_hub_cache(): hub}
    if "htdemucs" in sizes:        # demucs falls back to torch hub when HF fails
        roots[R.torch_hub_checkpoints()] = sizes["htdemucs"]
    if "ffmpeg" in sizes:
        roots[FFMPEG_PARTIAL] = sizes["ffmpeg"]
    return {root: expected for root, expected in roots.items() if expected > 0}


def run(emit: Emit, only: set[str] | None = None,
        clock: Callable[[], float] = time.monotonic) -> None:
    """Install everything missing, emitting `setup` events ~4x a second.

    Raises SetupError on failure (running steps are terminated first).
    """
    tools.remove_leftovers()
    missing = R.missing(only)
    total = R.download_bytes(missing)
    if not missing:
        emit("setup", phase="weights", label="Downloading voice models",
             bytes_done=0, bytes_total=0, eta=0.0, progress=1.0)
        return

    tasks = plan(missing)
    meter = ByteMeter(_byte_roots(missing))
    rates = RateMeter()
    try:
        while True:
            now = clock()
            _advance(tasks)
            failed = next((t for t in tasks if t.state == "failed"), None)
            if failed is not None:
                raise SetupError(_failure_message(failed), "\n".join(failed.tail))
            floor = sum(R.BY_ID[i].download_bytes for t in tasks if t.state == "done"
                        for i in t.covers)
            done = meter.measure(floor, total)
            rates.add(now, done)
            emit("setup", **_status(done, total, rates.rate()))
            if all(t.state == "done" for t in tasks):
                break
            time.sleep(TICK_S)
    finally:
        for t in tasks:
            if t.proc is not None and t.proc.poll() is None:
                t.proc.terminate()
                try:
                    t.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    t.proc.kill()

    tools.ensure_tool_path()         # a downloaded ffmpeg's folder exists now
    still = R.missing(only)
    if still:
        names = ", ".join(r.label for r in still)
        raise SetupError(f"Setup finished, but these are still missing: {names}.")


def _advance(tasks: list[Task]) -> None:
    for t in tasks:
        if t.state == "waiting":
            t.state = "running"
            if not t.start_next():
                t.state = "failed"
        elif t.state == "running":
            t.drain()
            code = t.proc.poll()
            if code is None:
                continue
            t.drain()
            t.proc.stdout.close()
            if code != 0:
                t.state = "failed"
            elif t.has_more:
                if not t.start_next():
                    t.state = "failed"
            else:
                t.state = "done"


def _status(done: int, total: int, rate: float | None) -> dict:
    eta = (total - done) / (rate or DEFAULT_RATE)
    return {"phase": "weights", "label": "Downloading voice models", "bytes_done": int(done),
            "bytes_total": int(total), "eta": round(eta, 1),
            "progress": round(min(done / (total or 1), 0.999), 4)}


def _failure_message(task: Task) -> str:
    last = next((line.strip() for line in reversed(task.tail) if line.strip()), "")
    what = "ffmpeg" if task.label == "ffmpeg" else f"the {task.label}"
    msg = f"Booth couldn't download {what}. Check your internet connection."
    return f"{msg} ({last[:160]})" if last else msg
