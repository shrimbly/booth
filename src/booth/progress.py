"""Stage-based progress and ETA for the app protocol.

The pipeline only says which stage it is in (`begin`) and, where cheap, how far
through real work it is (`signal`, e.g. Sidon chunk i of n). Everything else is
time-based: each stage has an expected duration from a fixed + per-audio-second
cost model, corrected by per-machine scales learned from earlier runs and by
how this run's finished stages compared with their estimates. Inside a stage,
progress follows elapsed / expected but eases off before the stage end, so it
never claims a stage is finished before it is. Reported progress never
decreases.
"""

from __future__ import annotations

import json
import math
import os
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from .tools import CACHE_DIR

STAGE_ORDER = ("decode", "separate", "restore", "cleanup", "write")


def stage_label(stage: str, engine: str) -> str:
    if stage == "restore":
        return "Restoring the voice" if engine == "sidon" else "Removing noise"
    if stage == "cleanup":
        return "Removing clicks" if engine == "sidon" else "Cleaning up"
    return {"decode": "Reading audio", "separate": "Separating music",
            "write": "Writing the file"}[stage]


@dataclass(frozen=True)
class Cost:
    fixed: float          # seconds regardless of length (imports, model loads)
    per_second: float     # seconds per second of audio

    def seconds(self, duration: float) -> float:
        return self.fixed + self.per_second * duration


# Measured on an M-series CPU with 8, 30 and 90 s speech clips. Whole sidon
# pipeline ≈ 0.6x realtime, demucs and Sidon about 40 % each on long files.
DEFAULT_COSTS: dict[str, Cost] = {
    "decode": Cost(0.03, 0.002),
    "separate": Cost(2.0, 0.42),
    "restore.sidon": Cost(3.5, 0.23),
    "restore.mossformer2": Cost(2.2, 0.05),     # warm uv env; the first run builds it
    "restore.df3": Cost(0.40, 0.027),
    "cleanup.sidon": Cost(0.05, 0.007),
    "cleanup.mossformer2": Cost(0.03, 0.008),
    "cleanup.df3": Cost(0.03, 0.008),
    "write": Cost(0.03, 0.002),
    "write.remux": Cost(0.15, 0.005),
    "write.stems": Cost(0.02, 0.005),
    "remix": Cost(0.08, 0.004),
}

# After Sidon's last chunk: decode its output, align, tone-correct.
_SIDON_TAIL = Cost(0.2, 0.012)


def cost_key(stage: str, engine: str) -> str:
    return f"{stage}.{engine}" if stage in ("restore", "cleanup") else stage


class Reporter(Protocol):
    """What the pipeline tells a progress observer."""

    def begin(self, stage: str) -> None: ...
    def switch_engine(self, engine: str) -> None: ...
    def signal(self, name: str, done: int, total: int) -> None: ...


class NullReporter:
    def begin(self, stage: str) -> None:
        pass

    def switch_engine(self, engine: str) -> None:
        pass

    def signal(self, name: str, done: int, total: int) -> None:
        pass


class SpeedBook:
    """Per-stage correction factors learned from finished runs (EMA), on disk."""

    ALPHA = 0.35
    VERSION = 1

    def __init__(self, path: Path | None = None):
        self.path = path or CACHE_DIR / "speed.json"
        self._stages: dict[str, dict] = self._load()

    def _load(self) -> dict[str, dict]:
        try:
            data = json.loads(self.path.read_text())
            if data.get("version") == self.VERSION and isinstance(data.get("stages"), dict):
                return data["stages"]
        except (OSError, ValueError, AttributeError):
            pass
        return {}

    def scale(self, key: str) -> float:
        entry = self._stages.get(key)
        return float(entry["scale"]) if entry else 1.0

    def learn(self, key: str, actual: float, predicted: float) -> None:
        """Fold in one observation; `predicted` is the unscaled model estimate."""
        if predicted <= 0 or actual <= 0:
            return
        observed = min(5.0, max(0.2, actual / predicted))
        entry = self._stages.get(key)
        if entry is None:
            self._stages[key] = {"scale": round(observed, 4), "runs": 1}
            return
        scale = (1 - self.ALPHA) * float(entry["scale"]) + self.ALPHA * observed
        self._stages[key] = {"scale": round(scale, 4), "runs": int(entry.get("runs", 0)) + 1}

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_name(f".{self.path.name}.{os.getpid()}.tmp")
            tmp.write_text(json.dumps({"version": self.VERSION, "stages": self._stages},
                                      indent=1, sort_keys=True))
            os.replace(tmp, self.path)
        except OSError:
            pass  # a lost speed sample is harmless


@dataclass
class _Stage:
    id: str
    key: str              # SpeedBook key
    label: str
    base: float           # unscaled model seconds
    planned: float        # base x learned scale
    expected: float = 0.0     # live estimate of this stage's total seconds
    weight: float = 0.0
    started: float | None = None
    finished: float | None = None
    learnable: bool = True


def soft_fraction(f: float) -> float:
    """Linear to 80 %, then an exponential approach that never reaches 1."""
    if f <= 0.8:
        return max(0.0, f)
    return min(0.995, 0.8 + 0.2 * (1.0 - math.exp(-(f - 0.8) / 0.2)))


class ProgressTracker:
    """Thread-safe: the pipeline calls begin/signal, a ticker thread snapshots."""

    def __init__(self, stages: list[_Stage], duration: float, speeds: SpeedBook,
                 clock: Callable[[], float] = time.monotonic):
        self._stages = stages
        self._by_id = {s.id: s for s in stages}
        self._duration = duration
        self._speeds = speeds
        self._clock = clock
        self._lock = threading.Lock()
        self._current: _Stage | None = None
        self._last_progress = 0.0
        self._sidon_loaded_at: float | None = None
        # Called on every stage change, so even stages shorter than a ticker
        # interval are reported.
        self.on_stage: Callable[[], None] | None = None
        total = sum(s.planned for s in stages) or 1.0
        for s in stages:
            s.weight = s.planned / total
            s.expected = s.planned

    @property
    def current_stage(self) -> str | None:
        return self._current.id if self._current else None

    def total_expected(self) -> float:
        return sum(s.planned for s in self._stages)

    # -- Reporter -------------------------------------------------------------

    def begin(self, stage: str) -> None:
        with self._lock:
            target = self._by_id.get(stage)
            if target is None or target is self._current:
                return
            now = self._clock()
            for s in self._stages:      # close the current stage and any skipped ones
                if s is target:
                    break
                if s.started is None:
                    s.started, s.learnable = now, False
                if s.finished is None:
                    s.finished = now
            target.started = now
            target.expected = target.planned * self._run_factor()
            self._current = target
        if self.on_stage is not None:
            self.on_stage()

    def switch_engine(self, engine: str) -> None:
        """Engine fallback: re-plan the rest of restore and cleanup."""
        with self._lock:
            now = self._clock()
            for s in self._stages:
                if s.id not in ("restore", "cleanup") or s.finished is not None:
                    continue
                s.key = cost_key(s.id, engine)
                s.label = stage_label(s.id, engine)
                s.base = DEFAULT_COSTS[s.key].seconds(self._duration)
                s.planned = s.base * self._speeds.scale(s.key)
                if s.started is None:
                    s.expected = s.planned
                else:                    # mixed-engine timing is not a clean sample
                    s.learnable = False
                    s.expected = (now - s.started) + s.planned

    def signal(self, name: str, done: int, total: int) -> None:
        """Real progress from inside a stage (Sidon: models loaded, chunk done)."""
        with self._lock:
            now = self._clock()
            if name == "sidon.loaded":
                self._sidon_loaded_at = now
                return
            cur = self._current
            if (name != "sidon.chunk" or cur is None or cur.id != "restore"
                    or self._sidon_loaded_at is None or total <= 0 or done <= 0):
                return
            frac = min(1.0, done / total)
            rate = (now - self._sidon_loaded_at) / frac
            remaining = rate * (1.0 - frac) + _SIDON_TAIL.seconds(self._duration)
            cur.expected = max(1e-3, (now - cur.started) + remaining)

    # -- reading --------------------------------------------------------------

    def snapshot(self) -> dict:
        with self._lock:
            now = self._clock()
            cur = self._current
            done = sum(s.weight for s in self._stages if s.finished is not None)
            if cur is not None:
                elapsed = now - cur.started
                done += cur.weight * soft_fraction(elapsed / cur.expected)
            progress = max(self._last_progress, min(0.999, done))
            self._last_progress = progress
            shown = cur or self._stages[0]
            return {"progress": round(progress, 4), "stage": shown.id,
                    "label": shown.label, "eta": round(self._eta(now), 1)}

    def finish(self, learn: bool = True) -> float:
        """Close the last stage; learn speeds from clean samples. Returns run seconds."""
        with self._lock:
            now = self._clock()
            for s in self._stages:
                if s.started is None:
                    s.started, s.learnable = now, False
                if s.finished is None:
                    s.finished = now
            self._last_progress = 1.0
            if learn:
                for s in self._stages:
                    if s.learnable:
                        self._speeds.learn(s.key, s.finished - s.started, s.base)
                self._speeds.save()
            first = self._stages[0].started
            return now - first if first is not None else 0.0

    # -- internals (lock held) ------------------------------------------------

    def _run_factor(self) -> float:
        """How much slower or faster this run is going than planned."""
        finished = [s for s in self._stages
                    if s.finished is not None and s.learnable and s.planned > 0]
        planned = sum(s.planned for s in finished)
        if planned <= 0:
            return 1.0
        ratio = sum(s.finished - s.started for s in finished) / planned
        confidence = min(1.0, planned / 15.0)
        return min(2.5, max(0.4, ratio)) ** confidence

    def _eta(self, now: float) -> float:
        remaining = 0.0
        factor = self._run_factor()
        for s in self._stages:
            if s.finished is not None:
                continue
            if s.started is None:
                remaining += s.planned * factor
                continue
            elapsed = now - s.started
            # Running late: the longer past its estimate, the more time we
            # assume it still needs, instead of a frozen "almost done".
            overrun = max(0.0, elapsed - s.expected)
            remaining += max(s.expected - elapsed, 0.1 * s.expected + 0.5 * overrun)
        return remaining


def plan_enhance(*, duration: float, engine: str, split: bool, video: bool,
                 stems: bool, speeds: SpeedBook) -> ProgressTracker:
    stages = []
    for stage in STAGE_ORDER:
        if stage == "separate" and not split:
            continue
        key = cost_key(stage, engine)
        base = DEFAULT_COSTS[key].seconds(duration)
        if stage == "write":
            if video:
                base += DEFAULT_COSTS["write.remux"].seconds(duration)
            if stems:
                base += DEFAULT_COSTS["write.stems"].seconds(duration)
        stages.append(_Stage(stage, key, stage_label(stage, engine), base,
                             base * speeds.scale(key)))
    return ProgressTracker(stages, duration, speeds)


def plan_remix(*, duration: float, video: bool, speeds: SpeedBook) -> ProgressTracker:
    base = DEFAULT_COSTS["remix"].seconds(duration)
    if video:
        base += DEFAULT_COSTS["write.remux"].seconds(duration)
    stage = _Stage("write", "remix", stage_label("write", ""), base,
                   base * speeds.scale("remix"))
    return ProgressTracker([stage], duration, speeds)


@dataclass
class ProgressTicker:
    """Emits the tracker's snapshot as a `progress` event about four times a second.

    `on_orphaned` is called once if this process is reparented (the app that
    started it died), even when nothing has noticed a broken pipe yet.
    """

    tracker: ProgressTracker
    emit: Callable[..., None]
    interval: float = 0.25
    on_orphaned: Callable[[], None] | None = None
    _stop: threading.Event = field(default_factory=threading.Event)
    # Snapshot and emit together, so events from the ticker thread and from
    # stage changes on the main thread reach the stream in progress order.
    _publish_lock: threading.Lock = field(default_factory=threading.Lock)
    _thread: threading.Thread | None = None

    def __enter__(self) -> ProgressTicker:
        self.tracker.on_stage = self.publish
        self._thread = threading.Thread(target=self._run, name="progress", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self.tracker.on_stage = None
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def publish(self) -> None:
        with self._publish_lock:
            self.emit("progress", **self.tracker.snapshot())

    def _run(self) -> None:
        parent = os.getppid()
        while not self._stop.wait(self.interval):
            if self.on_orphaned is not None and os.getppid() != parent:
                self.on_orphaned()
                return
            self.publish()
