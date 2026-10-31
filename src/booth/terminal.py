"""The CLI as a person at a terminal sees it.

Progress, messages and errors go to stderr; each finished file's path goes to
stdout, one per line, so `booth *.mov | xargs open` works. Problems are
one plain sentence (BOOTH_DEBUG=1 adds the traceback). Ctrl-C stops the
run and exits 130; outputs are committed only at the end, so nothing is left
behind. The first run downloads the models it needs before it starts.
"""

from __future__ import annotations

import os
import re
import time
import traceback
from argparse import Namespace
from pathlib import Path
from typing import Callable

from rich.console import Console
from rich.markup import escape
from rich.progress import BarColumn, Progress, TaskProgressColumn, TextColumn

from . import tools
from .progress import ProgressTicker, SpeedBook, plan_enhance, plan_remix

DEBUG = os.environ.get("BOOTH_DEBUG", "") not in ("", "0")
NO_FFMPEG = ("[red]error:[/] Booth needs ffmpeg. Install it with "
             "[bold]brew install ffmpeg[/], then try again.")


class Problem(Exception):
    """A failure to report as one sentence, without a traceback."""


def enhance_files(args: Namespace, make_settings: Callable) -> int:
    """`booth INPUT...`: enhance each input in turn; 1 if any failed."""
    err = Console(stderr=True, highlight=False, emoji=False)
    if tools.missing_ffmpeg_tools():
        err.print(NO_FFMPEG)
        return 1

    # A mistyped name fails now, not after a first-run download of minutes.
    failed = 0
    inputs = []
    for raw in args.inputs:
        path = Path(raw).expanduser()
        try:
            _check_input(path)
        except Problem as p:
            failed += 1
            err.print(f"[red]✗[/] {escape(path.name)}: {escape(str(p))}")
            continue
        inputs.append(path)
    if inputs:
        try:
            _ensure_models(err, args, quiet=args.quiet)
        except KeyboardInterrupt:
            err.print("[yellow]Cancelled.[/] The download will resume where it stopped.")
            return 130
        except Problem as p:
            err.print(f"[red]error:[/] {escape(str(p))}")
            return 1

    for path in inputs:
        name = escape(path.name)
        try:
            out, took, engine = _enhance_one(err, path, args, make_settings)
        except KeyboardInterrupt:
            err.print(f"[yellow]Cancelled.[/] Nothing was written for {name}.")
            return 130
        except Problem as p:
            failed += 1
            err.print(f"[red]✗[/] {name}: {escape(str(p))}")
            continue
        except Exception as e:
            failed += 1
            _report_unexpected(err, path.name, e)
            continue
        # A fallback engine sounds different, so it is reported even with -q.
        fell_back = engine != args.engine
        if fell_back or not args.quiet:
            note = ""
            if fell_back:
                why = "" if args.verbose else " (-v shows why)"
                note = f" [yellow]· {args.engine} couldn't run, so {engine} was used{why}[/]"
            err.print(f"[green]✓[/] {name} [dim]→[/] {escape(_shown(out))} "
                      f"[dim]({_duration(took)})[/]{note}")
        print(out, flush=True)
    if failed and len(args.inputs) > 1:
        err.print(f"[red]{failed} of {len(args.inputs)} files failed.[/]")
    return 1 if failed else 0


def remix_dir(args: Namespace) -> int:
    """`booth remix DIR`: re-render at a new mix without the voice models."""
    from . import stems
    from .pipeline import OutputIsInputError
    from .remix import MissingInputError, remix

    err = Console(stderr=True, highlight=False, emoji=False)
    directory = Path(args.dir).expanduser()
    shown_dir = escape(str(directory))
    try:
        data = stems.read_manifest(directory)
        video = data["has_video"] and not data["settings"]["audio_only"]
        duration, name = data["duration"], escape(data["name"])
    except NotADirectoryError:
        err.print(f"[red]error:[/] {shown_dir} is a file. Give the folder you passed to "
                  "--stems-dir.")
        return 1
    except FileNotFoundError:
        err.print(f"[red]error:[/] {shown_dir} has no stems. Enhance with "
                  "--stems-dir DIR first, then remix DIR.")
        return 1
    except OSError as e:
        err.print(f"[red]error:[/] can't read {shown_dir} ({escape(e.strerror or str(e))}).")
        return 1
    except Exception:                       # not JSON, another protocol, missing fields
        err.print(f"[red]error:[/] {shown_dir} isn't a stems folder from this version of "
                  "Booth. Enhance the file again with --stems-dir.")
        return 1
    tracker = plan_remix(duration=duration, video=video, speeds=SpeedBook())
    try:
        with _bar(err, data["name"], args.quiet) as update, ProgressTicker(tracker, update):
            tracker.begin("write")
            res = remix(directory, args.speech, args.background, args.music, args.output,
                        log=lambda *a, **k: None)
        tracker.finish()
    except KeyboardInterrupt:
        err.print("[yellow]Cancelled.[/] Nothing was written.")
        return 130
    except MissingInputError:
        err.print(f"[red]error:[/] the original {name} is no longer where it was, "
                  "so its video can't be updated. Use --output with a .wav name to remix "
                  "the audio only.")
        return 1
    except OutputIsInputError:
        err.print(f"[red]error:[/] the output would replace the original {name}; "
                  "choose another --output.")
        return 1
    except FileNotFoundError as e:
        err.print(f"[red]error:[/] some of the stems are gone ({escape(str(e))}). "
                  "Enhance the file again.")
        return 1
    except Exception as e:
        _report_unexpected(err, data["name"], e)
        return 1
    out = res["video"] or res["wav"]
    mix = res["mix"]
    if not args.quiet:
        err.print(f"[green]✓[/] {name} [dim]→[/] {escape(_shown(out))} [dim](speech "
                  f"{mix['speech']:.0f}, background {mix['background']:.0f}, music "
                  f"{mix['music']:.0f})[/]")
    print(out, flush=True)
    return 0


def setup_models(only: set[str] | None = None, quiet: bool = False) -> int:
    """`booth setup`: download everything missing, with a progress bar."""
    from . import installer

    err = Console(stderr=True, highlight=False, emoji=False)
    try:
        _download(err, installer, only, quiet)
    except KeyboardInterrupt:
        err.print("[yellow]Cancelled.[/] Run setup again to resume.")
        return 130
    except Problem as p:
        err.print(f"[red]error:[/] {escape(str(p))}")
        return 1
    if not quiet:
        err.print("[green]✓[/] The voice models are ready.")
    return 0


def compare_files(args: Namespace) -> int:
    """`booth eval REF TEST`: how TEST differs from REF."""
    from .eval import compare, print_report

    err = Console(stderr=True, highlight=False, emoji=False)
    if tools.missing_ffmpeg_tools():
        err.print(NO_FFMPEG)
        return 1
    for path in (args.ref, args.test):
        try:
            _check_input(path)
            _probe(path)
        except Problem as p:
            err.print(f"[red]error:[/] {escape(str(path))}: {escape(str(p))}")
            return 1
    try:
        res = compare(args.ref, args.test)
    except KeyboardInterrupt:
        return 130
    except Exception as e:
        _report_unexpected(err, f"{args.ref.name} vs {args.test.name}", e)
        return 1
    print_report(res, str(args.ref), str(args.test))
    return 0


# -- one file ------------------------------------------------------------------

def _check_input(path: Path) -> None:
    """The checks that need neither ffmpeg nor the models."""
    try:
        if not path.exists():
            raise Problem("no such file")
        if path.is_dir():
            raise Problem("that's a folder; give the files inside it instead")
    except OSError as e:                    # the OS refuses even a look
        raise Problem(f"can't open it ({e.strerror or e})") from None


def _probe(path: Path) -> dict:
    """ffprobe's view of an input that has sound."""
    from . import audio as A
    try:
        info = A.probe(path)
    except A.FfmpegError:
        raise Problem("ffmpeg can't read this file. It may be damaged, or not audio "
                      "or video.") from None
    if not info["has_audio"]:
        raise Problem("this file has no sound")
    return info


def _enhance_one(err: Console, path: Path, args: Namespace,
                 make_settings: Callable) -> tuple[str, float, str]:
    """Enhance one input: (output path, seconds taken, engine used)."""
    from . import audio as A
    from .pipeline import (NoAudioError, OutputIsInputError, TooShortError, enhance_file,
                           kept_stem_paths, output_paths, refuse_overwriting_input)

    started = time.monotonic()
    _check_input(path)
    inp = path.resolve()
    info = _probe(inp)

    st = make_settings(args, progress=False)
    keep_video = info["has_video"] and not st.audio_only
    wav_out, vid_out = output_paths(inp, args.output)
    finals = [vid_out, wav_out] if keep_video else [wav_out]
    try:
        refuse_overwriting_input(inp, finals + kept_stem_paths(st.keep_stems))
    except OutputIsInputError as e:
        raise _replaces_input(Path(str(e)), args.output) from None
    if keep_video and not vid_out.suffix:
        raise Problem(f"--output needs a video extension, such as "
                      f"{vid_out.name}{inp.suffix or '.mp4'}")
    if keep_video and A.audio_codec_args(vid_out) is None:
        raise Problem(f"this ffmpeg can't write {A.audio_codec_family(vid_out)} audio into a "
                      f"{vid_out.suffix} video. Use --audio-only, or a different --output "
                      "extension.")
    if keep_video and st.crf is not None and A.video_codec_args(vid_out, st.crf) is None:
        raise Problem(f"this ffmpeg can't re-encode the picture of a {vid_out.suffix} video. "
                      "Leave out --crf to copy it as it is, or use a different --output "
                      "extension.")
    _check_writable(finals)

    stems_dir = Path(args.stems_dir).expanduser().resolve() if args.stems_dir else None
    tracker = plan_enhance(duration=info["duration"], engine=st.engine, split=st.split_music,
                           video=keep_video, stems=stems_dir is not None, speeds=SpeedBook())
    try:
        with _bar(err, path.name, args.quiet) as update, ProgressTicker(tracker, update):
            log = err.print if args.verbose else (lambda *a, **k: None)
            res = enhance_file(inp, args.output, st, log=log, report=tracker,
                               stems_dir=stems_dir)
    except NoAudioError:
        raise Problem("this file has no sound") from None
    except TooShortError:
        raise Problem("too short to enhance") from None
    except OutputIsInputError as e:
        raise _replaces_input(Path(str(e)), args.output) from None
    tracker.finish()
    return str(res["video"] or res["wav"]), time.monotonic() - started, res["engine"]


def _replaces_input(final: Path, output: Path | None) -> Problem:
    """`-o talk.wav` for talk.mp4 also writes the video, as talk.mp4: say so."""
    if output is not None and output.suffix.lower() == ".wav" and final.suffix.lower() != ".wav":
        return Problem(f"--output {output.name} also writes the video as {final.name}, which is "
                       "the input. Add --audio-only, or choose another name.")
    return Problem("the output would replace the input; choose another --output")


def _check_writable(finals: list[Path]) -> None:
    from . import atomic
    for final in finals:
        try:
            atomic.check_writable(final)
        except PermissionError:
            raise Problem(f"can't write to {final.parent}; choose another --output") from None
        except OSError as e:
            if e.errno in (13, 1, 30):         # EACCES, EPERM, EROFS
                raise Problem(f"can't write to {final.parent}; choose another --output") \
                    from None


# -- first run -----------------------------------------------------------------

def _needed(args: Namespace) -> set[str]:
    """The setup items this run's engine reads (ffmpeg is checked separately)."""
    if args.engine == "sidon":
        need = {"sidon-venv", "sidon-weights", "w2v-bert", "df3"}
    else:
        need = {"df3"}
    if not args.no_split:
        need.add("htdemucs")
    return need


def _ensure_models(err: Console, args: Namespace, quiet: bool) -> None:
    from . import installer, requirements

    need = _needed(args) & set(requirements.BY_ID)
    if not requirements.missing(need):
        return
    if not quiet:
        size = requirements.download_bytes(requirements.missing(need)) / 1e9
        err.print(f"First run: downloading the voice models ({size:.1f} GB). "
                  "This happens once.")
    _download(err, installer, need, quiet)


def _download(err: Console, installer, only: set[str] | None, quiet: bool) -> None:
    with _bar(err, "Setup", quiet) as update:
        def emit(event: str, **f) -> None:
            if event == "setup":
                update("progress", progress=f["progress"], label=f["label"], eta=f["eta"])
        try:
            installer.run(emit, only)
        except installer.SetupError as e:
            raise Problem(e.message.replace("Booth couldn't", "Couldn't")) from None


# -- display -------------------------------------------------------------------

class _bar:
    """A one-line progress bar on stderr, fed `progress` events; nothing when quiet
    or when stderr isn't a terminal."""

    def __init__(self, console: Console, name: str, quiet: bool) -> None:
        self._progress = Progress(
            TextColumn("[bold]{task.description}"),
            BarColumn(bar_width=28),
            TaskProgressColumn(),
            TextColumn("[dim]{task.fields[label]}{task.fields[eta]}"),
            console=console, transient=True, disable=quiet or not console.is_terminal)
        self._task = self._progress.add_task(escape(_ellipsized(name, 32)), total=1.0, label="",
                                             eta="")

    def __enter__(self) -> Callable[..., None]:
        self._progress.start()
        return self.update

    def __exit__(self, *exc) -> None:
        self._progress.stop()

    def update(self, event: str, **f) -> None:
        if event != "progress":
            return
        eta = f.get("eta") or 0
        self._progress.update(self._task, completed=f["progress"], label=f["label"],
                              eta=f" · {_duration(eta)} left" if eta >= 1 else "")


def _duration(seconds: float) -> str:
    seconds = round(seconds)
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m"


def _shown(path: str) -> str:
    """A path relative to the working directory when it's inside it."""
    try:
        return str(Path(path).resolve().relative_to(Path.cwd()))
    except ValueError:
        return path.replace(str(Path.home()), "~", 1)


def _ellipsized(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


def _report_unexpected(err: Console, name: str, e: BaseException) -> None:
    from .audio import FfmpegError

    first = next((ln.strip() for ln in str(e).splitlines() if ln.strip()), type(e).__name__)
    if isinstance(e, FfmpegError):
        # ffmpeg's reason, without the "[webm @ 0x7f…] " tag naming its component.
        first = re.sub(r"^\[[^\]]* @ 0x[0-9a-fA-F]+\]\s*", "", first)
    err.print(f"[red]✗[/] {escape(name)}: {escape(first[:300])}")
    if DEBUG:
        err.print("".join(traceback.format_exception(e)), markup=False)
    else:
        err.print("[dim]  Run with BOOTH_DEBUG=1 for the full error.[/]")
