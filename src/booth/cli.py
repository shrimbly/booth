"""The booth command line.

Usage:
    booth INPUT... [options]         # enhance (implicit)
    booth enhance INPUT... [options]
    booth remix DIR [-s S -b B -m M] # re-render from a --stems-dir
    booth setup [--check]            # install missing models
    booth eval REF TEST              # compare two audio files
    booth app-info                   # one JSON line for the Booth app

`--events` switches enhance/remix/setup to the Booth app protocol: JSON Lines
on stdout, everything human-readable on stderr (see protocol.py). Without it,
terminal.py draws progress on stderr and prints each finished file on stdout.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import __version__

DESCRIPTION = "Studio-quality voice for your recordings. Runs entirely on this Mac."

EXAMPLES = """\
examples:
  booth talk.mp4                  writes talk-enhanced.mp4 (and .wav) beside it
  booth *.mov                     enhances every file, one after another
  booth talk.mp4 -s 80 -b 0 -m 0  stronger voice, no background, no music
  booth podcast.wav -o clean.wav  choose where the result goes
  booth talk.mp4 --engine df3     fastest: removes noise without restoring the voice
  booth setup                     download the voice models ahead of the first run

The first run downloads about 1.1 GB of voice models. Nothing is uploaded.
Run `booth enhance --help` for every option."""


class _Formatter(argparse.RawDescriptionHelpFormatter):
    """`-s, --speech 0-100` rather than `-s 0-100, --speech 0-100`, and no stray
    `COMMAND` line above the command list."""

    def _format_action_invocation(self, action: argparse.Action) -> str:
        if not action.option_strings or action.nargs == 0:
            return super()._format_action_invocation(action)
        metavar = self._format_args(action, self._get_default_metavar_for_optional(action))
        return f"{', '.join(action.option_strings)} {metavar}"

    def _format_action(self, action: argparse.Action) -> str:
        text = super()._format_action(action)
        if action.nargs == argparse.PARSER:
            text = text.split("\n", 1)[1]
        return text


def percent(text: str) -> float:
    """A mix level: a number from 0 to 100."""
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} isn't a number from 0 to 100") from None
    if not 0 <= value <= 100:
        raise argparse.ArgumentTypeError(f"{text} is outside 0–100")
    return value


def lufs(text: str) -> float:
    """A loudness target from -70 to -5 LUFS, the range ffmpeg's loudnorm takes."""
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} isn't a loudness in LUFS, such as -16") \
            from None
    if not -70 <= value <= -5:
        hint = f"; loudness targets are negative, such as -{value:g}" if 5 <= value <= 70 else ""
        raise argparse.ArgumentTypeError(f"{text} is outside -70 to -5 LUFS{hint}")
    return value


def _add_enhance_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("inputs", type=Path, nargs="+", metavar="INPUT",
                   help="video or audio files")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="log each processing step and its timing")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="no progress; print only the finished files, errors and engine "
                        "fallbacks")

    mix = p.add_argument_group("mix")
    mix.add_argument("-s", "--speech", type=percent, default=54.0, metavar="0-100",
                     help="enhancement strength (default 54)")
    mix.add_argument("-b", "--background", type=percent, default=10.0, metavar="0-100",
                     help="room tone and other background sound (default 10)")
    mix.add_argument("-m", "--music", type=percent, default=10.0, metavar="0-100",
                     help="music level (default 10)")

    out = p.add_argument_group("output")
    out.add_argument("-o", "--output", type=Path, default=None, metavar="PATH",
                     help="where to write: a file name, or a folder for "
                          "<input>-enhanced.<ext> (default: beside the input); one input only")
    out.add_argument("--audio-only", action="store_true",
                     help="write only the enhanced .wav, not a new video")
    out.add_argument("--crf", type=int, default=None, metavar="N",
                     help="re-encode the video at this CRF (default: copy it losslessly)")
    out.add_argument("--stems-dir", type=Path, default=None, metavar="DIR",
                     help="also keep preview stems here, so `booth remix DIR` can "
                          "change the mix in seconds; one input only")
    out.add_argument("--keep-stems", type=Path, default=None, metavar="DIR",
                     help="write the clean/background/music stems here for inspection; "
                          "one input only")

    eng = p.add_argument_group("engine")
    eng.add_argument("--engine", choices=["sidon", "mossformer2", "df3"], default="sidon",
                     help="sidon (default) restores the voice generatively; mossformer2 and "
                          "df3 only remove noise, df3 fastest")
    eng.add_argument("--no-split", action="store_true",
                     help="skip music separation: about twice as fast, music slider inert")
    eng.add_argument("--device", choices=["cpu", "mps", "auto"], default="cpu",
                     help="compute device for music separation (default cpu)")

    tune = p.add_argument_group("fine-tuning")
    tune.add_argument("--no-smooth", action="store_true",
                      help="keep Sidon's raw harmonics (no harmonic smoothing)")
    tune.add_argument("--no-declick", action="store_true",
                      help="keep mouth and tongue clicks (sidon)")
    tune.add_argument("--no-breaths", action="store_true",
                      help="keep the breaths between phrases")
    tune.add_argument("--no-expander", action="store_true",
                      help="no pause gate on the voice channel")
    tune.add_argument("--no-polish", action="store_true",
                      help="skip the DF3 polish pass after mossformer2")
    tune.add_argument("--no-low-gate", action="store_true",
                      help="no sub-150 Hz rumble gate")
    tune.add_argument("--no-air", action="store_true",
                      help="no synthetic high-band air (mossformer2/df3)")
    tune.add_argument("--no-leveler", action="store_true",
                      help="no slow voice leveler (mossformer2/df3)")
    tune.add_argument("--no-match-eq", action="store_true",
                      help="no Adobe-matched EQ on the clean speech (mossformer2/df3)")
    tune.add_argument("--linear", action="store_true",
                      help="linear slider response instead of the calibrated curves")
    tune.add_argument("--lufs", type=lufs, default=None, metavar="N",
                      help="normalize the final mix to N LUFS, -70 to -5 (default: automatic "
                           "speech gain)")
    tune.add_argument("--no-normalize", action="store_true",
                      help="no gain staging at all; keep the natural mix level")

    p.add_argument("--events", action="store_true", help=argparse.SUPPRESS)


def _add_remix_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("dir", type=Path, help="stems directory written by enhance --stems-dir")
    p.add_argument("-s", "--speech", type=percent, default=None, metavar="0-100",
                   help="enhancement strength (default: the saved mix)")
    p.add_argument("-b", "--background", type=percent, default=None, metavar="0-100",
                   help="background level (default: the saved mix)")
    p.add_argument("-m", "--music", type=percent, default=None, metavar="0-100",
                   help="music level (default: the saved mix)")
    p.add_argument("-o", "--output", type=Path, default=None, metavar="PATH",
                   help="write here instead of over the original outputs (a .wav name "
                        "needs no original video)")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="no progress; print only the finished file and errors")
    p.add_argument("--events", action="store_true", help=argparse.SUPPRESS)


def _add_setup_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--check", action="store_true",
                   help="only report what is missing; install nothing")
    p.add_argument("--events", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--only", default=None, help=argparse.SUPPRESS)  # testing: subset of items


def _quiet_libraries() -> None:
    """Silence third-party noise that reads like an error but isn't."""
    import os
    import warnings
    # Public models don't need a token; huggingface_hub warns anyway.
    os.environ.setdefault("HF_HUB_VERBOSITY", "error")
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    warnings.filterwarnings("ignore", category=FutureWarning)


def _settings(args: argparse.Namespace, progress: bool):
    from .pipeline import Settings

    loudness: str | float | None = "auto"
    if args.no_normalize:
        loudness = None
    elif args.lufs is not None:
        loudness = args.lufs

    return Settings(
        speech=args.speech, background=args.background, music=args.music,
        engine=args.engine, polish=not args.no_polish,
        split_music=not args.no_split, low_gate=not args.no_low_gate,
        air=not args.no_air, level=not args.no_leveler,
        smooth=not args.no_smooth, declick=not args.no_declick, breaths=not args.no_breaths,
        match_eq=not args.no_match_eq, expander=not args.no_expander,
        linear=args.linear, loudness=loudness,
        device=args.device, crf=args.crf, audio_only=args.audio_only,
        keep_stems=args.keep_stems, progress=progress,
    )


def _run_enhance(args: argparse.Namespace, ap: argparse.ArgumentParser) -> int:
    if args.output is not None and len(args.inputs) > 1:
        ap.error("-o/--output takes one input; without it each result goes beside its input")
    if (args.stems_dir is not None or args.keep_stems is not None) and len(args.inputs) > 1:
        ap.error("--stems-dir and --keep-stems take one input; each file's stems would "
                 "replace the last one's")
    _quiet_libraries()
    if args.events:
        if len(args.inputs) > 1:
            ap.error("--events takes one input")
        args.input = args.inputs[0]
        from .protocol import run_enhance
        return run_enhance(args, _settings)

    from .terminal import enhance_files
    return enhance_files(args, _settings)


def _run_eval(args: argparse.Namespace) -> int:
    from .terminal import compare_files
    return compare_files(args)


def _run_remix(args: argparse.Namespace) -> int:
    _quiet_libraries()
    if args.events:
        from .protocol import run_remix
        return run_remix(args)
    from .terminal import remix_dir
    return remix_dir(args)


def _run_setup(args: argparse.Namespace) -> int:
    _quiet_libraries()
    from .protocol import run_setup
    return run_setup(args)


SUBCOMMANDS = {"enhance", "eval", "remix", "setup", "app-info"}


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="booth", usage="booth INPUT... [options]\n       booth COMMAND ...",
        description=DESCRIPTION, epilog=EXAMPLES, formatter_class=_Formatter)
    ap.add_argument("--version", action="version", version=f"booth {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="COMMAND", title="commands")

    pe = sub.add_parser("enhance", help="enhance video or audio files (the default command)",
                        prog="booth", formatter_class=_Formatter,
                        description="Enhance the voice in video or audio files. Each result "
                                    "is written beside its input as <name>-enhanced.<ext>.",
                        usage="booth [enhance] INPUT... [options]")
    _add_enhance_args(pe)
    pe.set_defaults(parser=pe)

    pr = sub.add_parser("remix", help="change the mix of an enhanced file in seconds",
                        prog="booth remix", formatter_class=_Formatter,
                        description="Re-render a file enhanced with --stems-dir at a new mix, "
                                    "without running the voice models again.")
    _add_remix_args(pr)

    ps = sub.add_parser("setup", help="download the voice models now instead of on first use",
                        prog="booth setup",
                        description="Download the voice models and engine environment the "
                                    "default pipeline needs (about 1.1 GB).")
    _add_setup_args(ps)

    pv = sub.add_parser("eval", help="compare two audio files (SI-SDR, LUFS, band deltas)",
                        prog="booth eval")
    pv.add_argument("ref", type=Path)
    pv.add_argument("test", type=Path)

    sub.add_parser("app-info")          # for the Booth app; left out of the help on purpose
    return ap


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    from .tools import ensure_tool_path
    ensure_tool_path()
    if argv[:1] == ["app-info"]:      # fast path: no argparse tree, no heavy imports
        from .protocol import app_info, print_line
        print_line(app_info())
        return 0

    ap = _parser()
    if not argv:
        ap.print_help()
        return 0
    # Implicit enhance: `booth file.mp4 ...`
    if argv[0] not in SUBCOMMANDS | {"-h", "--help", "--version"}:
        argv.insert(0, "enhance")

    args = ap.parse_args(argv)
    if args.cmd == "eval":
        return _run_eval(args)
    if args.cmd == "remix":
        return _run_remix(args)
    if args.cmd == "setup":
        return _run_setup(args)
    return _run_enhance(args, args.parser)


if __name__ == "__main__":
    raise SystemExit(main())
