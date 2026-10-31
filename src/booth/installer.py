"""`booth setup`: install whatever the default pipeline is missing.

Every install step runs as a child process — uv for the Sidon venv, the Sidon
venv's own Python for its weights, this Python for htdemucs and DeepFilterNet3
— so a cancel kills them with the process group and the main loop stays free
to report progress. Download progress is measured by polling the size of the
cache directories the libraries write into (huggingface_hub, torch hub,
DeepFilterNet), against the known size of each model.
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

from . import requirements as R
from .progress import soft_fraction

TICK_S = 0.25
DEFAULT_RATE = 8e6            # bytes/s assumed until a download has been measured
VENV_SECONDS = 90.0           # typical uv venv + torch/transformers install
VENV_WEIGHT_BYTES = 300e6     # the venv's share of the overall progress bar

# Runs in the Sidon venv; argv names what to fetch ("sidon-weights", "w2v-bert").
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

# The archive DeepFilterNet's own loader fetches (from the repository's main
# branch), pinned by the hashes of the files this release was tested with.
DF3_URL = f"https://github.com/Rikorose/DeepFilterNet/raw/main/models/{R.DF3_MODEL}.zip"
DF3_SHA256 = {
    "config.ini": "415eb925d44990d938fb739f514aa3662c1ec0ea836cff044fa1291b82cb4290",
    "checkpoints/model_120.ckpt.best":
        "23b92884f63ccf54bb026014604625ab231657b6480df65db4095c4c171e6003",
}

# Extracts beside the model folder and moves it in only once every file checks
# out, so a cut-off or changed download never reads as installed.
_DF3_DOWNLOAD = f"""
import hashlib, os, shutil, sys
from df.utils import download_file, get_cache_dir
cache = get_cache_dir()
part = os.path.join(cache, ".{R.DF3_MODEL}.partial")
shutil.rmtree(part, ignore_errors=True)
os.makedirs(part)
try:
    download_file({DF3_URL!r}, part, extract=True)
    for name, digest in {DF3_SHA256!r}.items():
        with open(os.path.join(part, {R.DF3_MODEL!r}, name), "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != digest:
                sys.exit("{R.DF3_MODEL} download doesn't match the tested model: " + name)
    final = os.path.join(cache, {R.DF3_MODEL!r})
    shutil.rmtree(final, ignore_errors=True)
    os.replace(os.path.join(part, {R.DF3_MODEL!r}), final)
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
    label: str                       # "the voice engine", used in messages
    covers: tuple[str, ...]          # requirement ids this task installs
    commands: list[list[str]]
    needs: str | None = None         # label of a task that must finish first
    env: dict | None = None
    state: str = "waiting"           # waiting → running → done | failed
    proc: subprocess.Popen | None = None
    started: float = 0.0
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
    if ids & {"sidon-weights", "w2v-bert"} and not R.sidon_venv_ready():
        ids.add("sidon-venv")         # those downloads run inside the Sidon venv
    env = dict(os.environ, HF_HUB_DISABLE_PROGRESS_BARS="1", HF_HUB_VERBOSITY="error",
               TQDM_DISABLE="1")
    tasks: list[Task] = []
    if "sidon-venv" in ids:
        from .engines import sidon
        R.SIDON_VENV.parent.mkdir(parents=True, exist_ok=True)
        try:
            commands = sidon.bootstrap_commands()
        except RuntimeError as e:
            raise SetupError("Booth couldn't find uv, which it needs to install the "
                             "voice engine.", str(e)) from None
        tasks.append(Task("voice engine", ("sidon-venv",), commands, env=env))
    sidon_items = tuple(i for i in ("sidon-weights", "w2v-bert") if i in ids)
    if sidon_items:
        python = str(R.SIDON_VENV / "bin" / "python")
        tasks.append(Task("Sidon voice model", sidon_items,
                          [[python, "-c", _SIDON_DOWNLOAD, *sidon_items]],
                          needs="voice engine" if "sidon-venv" in ids else None, env=env))
    if "htdemucs" in ids:
        tasks.append(Task("music separation model", ("htdemucs",),
                          [[sys.executable, "-c", _HTDEMUCS_DOWNLOAD]], env=env))
    if "df3" in ids:
        tasks.append(Task("noise model", ("df3",),
                          [[sys.executable, "-c", _DF3_DOWNLOAD]], env=env))
    return tasks


def _byte_roots(missing: list[R.Requirement]) -> dict[Path, int]:
    sizes = {r.id: r.download_bytes for r in missing}
    hub = sum(sizes.get(i, 0) for i in ("sidon-weights", "w2v-bert", "htdemucs"))
    roots = {R.hf_hub_cache(): hub}
    if "htdemucs" in sizes:        # demucs falls back to torch hub when HF fails
        roots[R.torch_hub_checkpoints()] = sizes["htdemucs"]
    if "df3" in sizes:
        roots[R.deepfilter_cache()] = sizes["df3"]
    return {root: expected for root, expected in roots.items() if expected > 0}


def run(emit: Emit, only: set[str] | None = None,
        clock: Callable[[], float] = time.monotonic) -> None:
    """Install everything missing, emitting `setup` events ~4x a second.

    Raises SetupError on failure (running steps are terminated first).
    """
    missing = R.missing(only)
    if any(r.id == "ffmpeg" for r in missing):
        raise SetupError("Booth needs ffmpeg. Install it with Homebrew "
                         "(brew install ffmpeg), then try again.")
    total = R.download_bytes(missing)
    if not missing:
        emit("setup", phase="weights", label="Downloading voice models",
             bytes_done=0, bytes_total=0, eta=0.0, progress=1.0)
        return

    tasks = plan(missing)
    meter = ByteMeter(_byte_roots(missing))
    rates = RateMeter()
    venv_task = next((t for t in tasks if "sidon-venv" in t.covers), None)
    venv_weight = VENV_WEIGHT_BYTES if venv_task else 0.0
    try:
        while True:
            now = clock()
            _advance(tasks, now)
            failed = next((t for t in tasks if t.state == "failed"), None)
            if failed is not None:
                raise SetupError(_failure_message(failed), "\n".join(failed.tail))
            floor = sum(R.BY_ID[i].download_bytes for t in tasks if t.state == "done"
                        for i in t.covers)
            done = meter.measure(floor, total)
            rates.add(now, done)
            emit("setup", **_status(venv_task, venv_weight, done, total, rates.rate(), now))
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

    still = R.missing(only)
    if still:
        names = ", ".join(r.label for r in still)
        raise SetupError(f"Setup finished, but these are still missing: {names}.")


def _advance(tasks: list[Task], now: float) -> None:
    by_label = {t.label: t for t in tasks}
    for t in tasks:
        if t.state == "waiting":
            dep = by_label.get(t.needs) if t.needs else None
            if dep is None or dep.state == "done":
                t.state, t.started = "running", now
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


def _status(venv_task: Task | None, venv_weight: float, done: int, total: int,
            rate: float | None, now: float) -> dict:
    venv_running = venv_task is not None and venv_task.state != "done"
    venv_frac = 1.0
    venv_left = 0.0
    if venv_running:
        elapsed = now - venv_task.started if venv_task.state == "running" else 0.0
        venv_frac = soft_fraction(elapsed / VENV_SECONDS)
        venv_left = max(5.0, VENV_SECONDS - elapsed)
    eta = venv_left + (total - done) / (rate or DEFAULT_RATE)
    progress = (venv_weight * venv_frac + done) / ((venv_weight + total) or 1.0)
    phase, label = (("engine", "Installing the voice engine") if venv_running
                    else ("weights", "Downloading voice models"))
    return {"phase": phase, "label": label, "bytes_done": int(done),
            "bytes_total": int(total), "eta": round(eta, 1),
            "progress": round(min(progress, 0.999), 4)}


def _failure_message(task: Task) -> str:
    last = next((line.strip() for line in reversed(task.tail) if line.strip()), "")
    if task.label == "voice engine":
        msg = "Booth couldn't install the voice engine."
    else:
        msg = f"Booth couldn't download the {task.label}. Check your internet connection."
    return f"{msg} ({last[:160]})" if last else msg
