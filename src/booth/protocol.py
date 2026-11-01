"""The Booth app protocol, version 1: `app-info`, `setup`, and events-mode
`enhance` / `remix`.

Each command speaks JSON Lines on stdout (see events.py) and ends with exactly
one terminal event — `done` or `error` — followed by exit code 0, 2, or 130
when cancelled. Heavy modules (numpy, torch, the pipeline) are imported inside
the commands so `app-info` stays fast.
"""

from __future__ import annotations

import errno
import json
import subprocess
import sys
import time
import traceback
from collections.abc import Callable
from pathlib import Path

from . import __version__, events, requirements, tools
from .events import PROTOCOL, Cancelled, EventStream, JobError, error_fields
from .progress import ProgressTicker, SpeedBook, plan_enhance, plan_remix, stage_label

ENGINES = ["sidon", "mossformer2", "df3"]


def app_info() -> dict:
    missing = requirements.missing()
    return {"event": "info", "protocol": PROTOCOL, "version": __version__,
            "engines": ENGINES, "ready": not missing, "missing": [r.id for r in missing],
            "python": sys.executable}


def print_line(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")), flush=True)


def format_duration(seconds: float) -> str:
    total = int(round(seconds))
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def media_meta(path: Path, duration: float, has_video: bool, height: int) -> str:
    """"3:12 · MP4 · 1080p" for video, "0:48 · M4A" for audio."""
    parts = [format_duration(duration)]
    ext = path.suffix.lstrip(".").upper()
    if ext:
        parts.append(ext)
    if has_video and height:
        parts.append(f"{height}p")
    return " · ".join(parts)


# -- shared plumbing -----------------------------------------------------------

def _open_session() -> EventStream:
    stream = events.open_event_stream()
    events.become_process_group_leader()
    events.install_cancel_handler(stream)
    return stream


def _stderr_log() -> Callable[..., None]:
    from rich.console import Console

    class _LogConsole(Console):
        def on_broken_pipe(self) -> None:
            # Rich would exit; losing the log is no reason to fail a job. If
            # the app is gone, the event pipe breaks too and cancels the run.
            self.quiet = True

    return _LogConsole(file=sys.stderr, width=160, highlight=False).print


def _run(stream: EventStream, body: Callable[[], None], unexpected_code: str = "internal") -> int:
    """Run a command body; every outcome becomes one terminal event + exit code."""
    try:
        try:
            body()
            return 0
        except JobError as e:
            stream.emit("error", **error_fields(e.code, e.message, e.detail))
        except SystemExit as e:             # a library calling exit()
            stream.emit("error", **error_fields(unexpected_code,
                                                f"Stopped unexpectedly ({e.code}).",
                                                traceback.format_exc()))
        except Exception as e:
            message = f"{type(e).__name__}: {_first_line(e)}"
            stream.emit("error", **error_fields(unexpected_code, message, traceback.format_exc()))
        return 2
    except Cancelled:                       # even while reporting another failure
        return 130                          # the signal handler already reported it


def _first_line(e: BaseException) -> str:
    return next((ln.strip() for ln in str(e).splitlines() if ln.strip()), "")[:300]


def _last_line(e: BaseException) -> str:
    return next((ln.strip() for ln in reversed(str(e).splitlines()) if ln.strip()), "")[:300]


# What ffmpeg / libsndfile say when the OS refuses access (permissions, TCC).
_DENIED_HINTS = ("Permission denied", "Operation not permitted")
_READ_ONLY_HINTS = (*_DENIED_HINTS, "Read-only file system")
_READ_ONLY_ERRNOS = (errno.EACCES, errno.EPERM, errno.EROFS)


def _unreadable(name: str) -> str:
    return f"{name} may be damaged or in a format Booth doesn't support. Nothing was changed."


def _not_allowed(name: str) -> str:
    return (f"Booth isn't allowed to open {name}. Check the file's permissions, or allow Booth "
            "in System Settings › Privacy & Security › Files and Folders. Nothing was changed.")


def _read_only(name: str) -> str:
    return (f"Booth can't save next to {name} because that folder is read-only. "
            "Move the file somewhere you can write to, then try again.")


def _replaces_input(name: str) -> JobError:
    return JobError("engine_failed", f"The enhanced copy would replace {name} itself, so Booth "
                                     "stopped. Nothing was changed.")


def _decode_error(name: str, detail: str) -> JobError:
    """A failure to open or decode the input."""
    if any(hint in detail for hint in _DENIED_HINTS):
        return JobError("decode_failed", _not_allowed(name), detail)
    return JobError("decode_failed", _unreadable(name), detail)


def _is_read_only(e: BaseException) -> bool:
    """Whether a write failed because the destination refuses writes."""
    if isinstance(e, PermissionError):
        return True
    if isinstance(e, OSError) and e.errno in _READ_ONLY_ERRNOS:
        return True
    text = str(e)
    # libsndfile reports any refused open as "Error opening '<temp>': System error."
    return ("Error opening" in text and ".partial" in text) or any(
        hint in text for hint in _READ_ONLY_HINTS)


def _check_writable(finals: list[Path], name: str) -> None:
    """Fail before the run, not after it, when an output folder refuses writes."""
    from . import atomic
    for final in finals:
        try:
            atomic.check_writable(final)
        except OSError as e:
            if isinstance(e, PermissionError) or e.errno in _READ_ONLY_ERRNOS:
                raise JobError("engine_failed", _read_only(name), str(e)) from None
            # Anything else (a full disk, say) is reported by the run itself.


def _classify(e: Exception, stage: str | None, name: str) -> JobError:
    """Map a pipeline exception to a protocol error by type and stage."""
    detail = "".join(traceback.format_exception(e))
    if stage in (None, "decode"):
        return _decode_error(name, detail)
    if stage == "write" and isinstance(e, (RuntimeError, OSError)):
        if _is_read_only(e):
            return JobError("engine_failed", _read_only(name), detail)
        reason = _last_line(e)
        if ".partial" in reason:            # temp-file names mean nothing to the user
            return JobError("engine_failed", f"Booth couldn't save the enhanced copy of {name}.",
                            detail)
        return JobError("engine_failed",
                        f"Booth couldn't save the enhanced copy of {name}: {reason}", detail)
    if isinstance(e, (RuntimeError, OSError, subprocess.SubprocessError)):
        return JobError("engine_failed", f"Enhancing {name} failed: {_last_line(e)}", detail)
    return JobError("internal", f"{type(e).__name__}: {_first_line(e)}", detail)


def _emit_done(stream: EventStream, res: dict, started: float, mix: dict) -> None:
    wav = Path(res["wav"]).resolve()
    video = Path(res["video"]).resolve() if res["video"] else None
    stream.emit("progress", progress=1.0, stage="write", label=stage_label("write", ""), eta=0.0)
    stream.emit("done", output=str(video or wav), wav=str(wav),
                video=str(video) if video else None,
                stems=str(res["stems"]) if res["stems"] else None,
                took=round(time.monotonic() - started, 1), music=bool(res["music"]),
                mix=mix, engine=res["engine"])


# -- enhance -------------------------------------------------------------------

def run_enhance(args, make_settings: Callable) -> int:
    started = time.monotonic()
    stream = _open_session()
    stream.emit("hello", protocol=PROTOCOL, version=__version__)
    return _run(stream, lambda: _enhance(stream, args, make_settings, started))


def _enhance(stream: EventStream, args, make_settings: Callable, started: float) -> None:
    from . import audio as A
    from .pipeline import (NoAudioError, OutputIsInputError, TooShortError, enhance_file,
                           output_paths, refuse_overwriting_input)
    from .stems import mix_values

    path = Path(args.input).expanduser()
    name = path.name
    try:
        # exists() itself raises PermissionError when the OS blocks even a stat.
        if not path.exists():
            raise JobError("not_found",
                           f"Booth couldn't find {name}. It may have been moved or deleted.")
        inp = path.resolve()
        open(inp, "rb").close()
    except PermissionError as e:
        raise JobError("decode_failed", _not_allowed(name), str(e)) from None
    except OSError as e:                    # a folder, an unreadable device, …
        raise JobError("decode_failed", _unreadable(name), str(e)) from None
    if tools.missing_ffmpeg_tools():     # setup downloads it
        raise JobError("setup_required", "Booth needs ffmpeg to read audio.")
    no_sound = f"{name} has a video track but no sound. Nothing was changed."
    try:
        info = A.probe(inp)
    except A.FfmpegError as e:
        raise _decode_error(name, str(e)) from None
    if not info["has_audio"]:
        raise JobError("no_audio" if info["has_video"] else "decode_failed",
                       no_sound if info["has_video"] else _unreadable(name))

    st = make_settings(args, progress=False)
    keep_video = info["has_video"] and not st.audio_only
    wav_out, vid_out = output_paths(inp, args.output)
    finals = [vid_out, wav_out] if keep_video else [wav_out]
    try:
        refuse_overwriting_input(inp, finals)
    except OutputIsInputError:
        raise _replaces_input(name) from None
    if keep_video and A.audio_codec_args(vid_out) is None:
        ext = vid_out.suffix.lstrip(".").upper()
        raise JobError("engine_failed",
                       f"Booth can't write a {ext} video with this ffmpeg. Turn off Keep the "
                       f"original video, or install ffmpeg with {A.audio_codec_family(vid_out)} "
                       "support.")
    _check_writable(finals, name)
    stems_dir = Path(args.stems_dir).expanduser().resolve() if args.stems_dir else None
    tracker = plan_enhance(duration=info["duration"], engine=st.engine, split=st.split_music,
                           video=keep_video, stems=stems_dir is not None, speeds=SpeedBook())
    stream.emit("start", input=str(inp), name=name, duration=round(info["duration"], 3),
                has_video=info["has_video"], has_audio=True,
                meta=media_meta(inp, info["duration"], info["has_video"], info["height"]),
                engine=st.engine, eta=round(tracker.total_expected(), 1))
    try:
        with ProgressTicker(tracker, stream.emit, on_orphaned=stream.reader_gone):
            res = enhance_file(inp, args.output, st, log=_stderr_log(), report=tracker,
                               stems_dir=stems_dir)
    except NoAudioError:
        raise JobError("no_audio", no_sound) from None
    except TooShortError:
        raise JobError("decode_failed", f"{name} is too short to enhance. Nothing was changed.") \
            from None
    except OutputIsInputError:
        raise _replaces_input(name) from None
    except Exception as e:
        raise _classify(e, tracker.current_stage, name) from e
    tracker.finish()
    _emit_done(stream, res, started, mix_values(st.speech, st.background, st.music))


# -- remix ---------------------------------------------------------------------

def run_remix(args) -> int:
    started = time.monotonic()
    stream = _open_session()
    stream.emit("hello", protocol=PROTOCOL, version=__version__)
    return _run(stream, lambda: _remix(stream, args, started))


def _remix(stream: EventStream, args, started: float) -> None:
    from . import stems
    from .pipeline import OutputIsInputError
    from .remix import MissingInputError, remix

    directory = Path(args.dir).expanduser().resolve()
    try:
        data = stems.read_manifest(directory)
    except FileNotFoundError:
        raise JobError("not_found", "The stems for this file are gone, so its mix can't be "
                                    "changed. Enhance it again to remix.") from None
    tracker = plan_remix(duration=data["duration"],
                         video=data["has_video"] and not data["settings"]["audio_only"],
                         speeds=SpeedBook())
    try:
        with ProgressTicker(tracker, stream.emit, on_orphaned=stream.reader_gone):
            tracker.begin("write")
            res = remix(directory, args.speech, args.background, args.music, args.output,
                        log=_stderr_log())
    except MissingInputError:
        raise JobError("not_found", f"The original {data['name']} is no longer there, "
                                    "so its video can't be updated.") from None
    except OutputIsInputError:
        raise _replaces_input(data["name"]) from None
    except FileNotFoundError as e:
        raise JobError("not_found", "Some of the stems for this file are gone. "
                                    "Enhance it again to remix.", str(e)) from None
    except Exception as e:
        raise _classify(e, "write", data["name"]) from e
    tracker.finish()
    _emit_done(stream, res, started, res["mix"])


# -- setup ---------------------------------------------------------------------

def run_setup(args) -> int:
    from . import installer

    only = None
    if args.only:
        only = {item.strip() for item in args.only.split(",") if item.strip()}
        unknown = only - set(requirements.BY_ID)
        if unknown:
            print(f"unknown setup item(s): {', '.join(sorted(unknown))}; "
                  f"known: {', '.join(requirements.BY_ID)}", file=sys.stderr)
            return 2

    if args.check:
        status = installer.check(only)
        if args.events:
            print_line({"event": "setup_status", **status})
        elif status["ready"]:
            print("ready")
        else:
            print(f"missing: {', '.join(status['missing'])} "
                  f"({status['bytes_total'] / 1e9:.2f} GB to download)")
        return 0

    if not args.events:
        from .terminal import setup_models
        return setup_models(only)

    stream = _open_session()

    def body() -> None:
        try:
            installer.run(stream.emit, only)
        except installer.SetupError as e:
            raise JobError("setup_failed", e.message, e.detail) from None
        stream.emit("done", ready=True)

    return _run(stream, body, unexpected_code="setup_failed")
