"""Audio I/O and loudness utilities built on ffmpeg (decode/remux/loudnorm) and soundfile."""

from __future__ import annotations

import functools
import json
import re
import shlex
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 48000


class FfmpegError(RuntimeError):
    """ffmpeg or ffprobe failed. The message is ffmpeg's own reason; `cmd` and
    `stderr` keep the command line and everything it printed."""

    def __init__(self, reason: str, cmd: list[str] | None = None, stderr: str = "") -> None:
        super().__init__(reason)
        self.cmd = cmd
        self.stderr = stderr
        # Tracebacks (BOOTH_DEBUG, the app's error details) show these too.
        if cmd:
            self.add_note("command: " + shlex.join(cmd))
        if stderr.strip() and stderr.strip() != reason:
            self.add_note(stderr.strip()[-2000:])


# "[mp4 @ 0x6000...] " before a message, and "[error] " with -loglevel level+...
_CONTEXT = re.compile(r"^(\[[^\]]* @ 0x[0-9a-f]+\] )+")
_LEVEL = re.compile(r"^\[(panic|fatal|error|warning|info|verbose|debug|trace)\] ")
# Lines ffmpeg prints after the real error, about the error it already reported.
_FOLLOW_ON = re.compile(
    r"^(Could not write header|Error sending frames to consumers|Task finished with error"
    r"|Terminating thread with return code|Nothing was written into output file"
    r"|Error opening (input|output) files?[ :.]|Conversion failed)")


def _reason(stderr: str) -> str:
    """ffmpeg's explanation of a failure: its error lines, without the
    "[muxer @ 0x...]" prefixes and the follow-on lines that only repeat it."""
    lines: list[str] = []
    for raw in stderr.splitlines():
        ln = _CONTEXT.sub("", raw.strip())
        if level := _LEVEL.match(ln):
            if level[1] not in ("panic", "fatal", "error"):
                continue
            ln = ln[level.end():]
        ln = ln.strip()
        if ln and ln not in lines:
            lines.append(ln)
    reasons = [ln for ln in lines if not _FOLLOW_ON.match(ln)] or lines
    return "\n".join(reasons[-10:])


def _failed(cmd: list[str], returncode: int, stderr: str) -> FfmpegError:
    return FfmpegError(_reason(stderr) or f"{cmd[0]} exited with code {returncode}", cmd, stderr)


def _run(cmd: list) -> subprocess.CompletedProcess:
    cmd = [str(c) for c in cmd]
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        raise _failed(cmd, p.returncode, p.stderr)
    return p


def _start_time(entry: dict | None) -> float:
    try:
        return float((entry or {}).get("start_time") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def probe(path: str | Path) -> dict:
    p = _run(["ffprobe", "-v", "error", "-print_format", "json",
              "-show_format", "-show_streams", path])
    info = json.loads(p.stdout)
    streams = info.get("streams", [])
    # Cover art in audio files shows up as a one-frame "video" stream.
    video = [s for s in streams if s.get("codec_type") == "video"
             and not s.get("disposition", {}).get("attached_pic")]
    # The track ffmpeg would choose itself: a default one, then the most
    # channels. decode() enhances it and remux() puts the result in its place.
    audio = max((s for s in streams if s.get("codec_type") == "audio"), default=None,
                key=lambda s: (s.get("disposition", {}).get("default", 0), s.get("channels") or 0))
    return {
        "has_video": bool(video),
        "has_audio": audio is not None,
        "duration": float(info.get("format", {}).get("duration", 0.0) or 0.0),
        "audio": audio,
        "streams": streams,
        "tags": info.get("format", {}).get("tags", {}),
        "height": int(video[0].get("height") or 0) if video else 0,
        # Seconds on the input's timeline: where the file, the audio we decode
        # and the picture start. decode() drops the audio offset; remux() restores it.
        "start": _start_time(info.get("format")),
        "audio_start": _start_time(audio),
        "video_start": _start_time(video[0]) if video else 0.0,
        "video_index": int(video[0]["index"]) if video else None,
        "format": info.get("format", {}).get("format_name", ""),
    }


def _unknown_layout(stream: dict) -> bool:
    layout = stream.get("channel_layout") or "unknown"
    return layout == "unknown" or re.fullmatch(r"\d+ channels", layout) is not None


def decode(path: str | Path, sr: int = SR) -> np.ndarray:
    """Decode the audio track probe() picks from any ffmpeg-readable file to
    float32 mono [T] at sr.

    Gaps in the track's timestamps come back as silence, so each sample stays
    where it played in the input; the track's start offset is dropped.
    """
    audio = probe(path)["audio"]
    cmd = ["ffmpeg", "-v", "error", "-i", str(path), "-vn"]
    if audio is not None:
        cmd += ["-map", f"0:{audio['index']}"]
    filters = ["aresample=async=1"]
    channels = (audio or {}).get("channels") or 0
    if channels > 2 and _unknown_layout(audio):
        # Without a layout ffmpeg assumes 5.1 or 7.1 and leaves channel 4 out as
        # LFE. Discrete tracks (a field recorder's mics) are summed equally instead.
        filters.insert(0, "pan=mono|c0<" + "+".join(f"c{i}" for i in range(channels)))
    cmd += ["-af", ",".join(filters),
            "-f", "f32le", "-acodec", "pcm_f32le", "-ac", "1", "-ar", str(sr), "-"]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        raise _failed(cmd, p.returncode, p.stderr.decode(errors="replace"))
    return np.frombuffer(p.stdout, dtype=np.float32).copy()


def write_wav(path: str | Path, audio: np.ndarray, sr: int = SR, subtype: str = "PCM_16") -> None:
    """Write mono audio clipped to ±1, a block at a time (no whole-signal copy)."""
    block = 30 * SR
    with sf.SoundFile(str(path), "w", sr, 1, subtype=subtype) as f:
        for a in range(0, len(audio), block):
            f.write(np.clip(audio[a:a + block], -1.0, 1.0))


def measure_loudnorm(path: str | Path, target_i: float = -16.0,
                     tp: float = -1.5, lra: float = 11.0) -> dict:
    """First loudnorm pass: returns measured input_i / input_tp / input_lra / input_thresh / target_offset."""
    # The result is printed at info level; level tags tell the errors apart from it.
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "level+info", "-i", str(path),
           "-af", f"loudnorm=I={target_i}:TP={tp}:LRA={lra}:print_format=json",
           "-f", "null", "-"]
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    m = re.findall(r"\{[^{}]+\}", p.stderr, re.S)
    if not m:
        raise FfmpegError(_reason(p.stderr) or "loudnorm measurement failed", cmd, p.stderr)
    return json.loads(m[-1])


def integrated_lufs(path: str | Path) -> float:
    return float(measure_loudnorm(path)["input_i"])


def loudness_normalize(in_wav: str | Path, out_wav: str | Path, target_i: float,
                       tp: float = -1.5, lra: float = 11.0) -> None:
    """Two-pass, linear (pure-gain) loudness normalization to target_i LUFS."""
    meas = measure_loudnorm(in_wav, target_i, tp, lra)
    af = (f"loudnorm=I={target_i}:TP={tp}:LRA={lra}:linear=true:"
          f"measured_I={meas['input_i']}:measured_TP={meas['input_tp']}:"
          f"measured_LRA={meas['input_lra']}:measured_thresh={meas['input_thresh']}:"
          f"offset={meas['target_offset']}")
    _run(["ffmpeg", "-y", "-v", "error", "-i", in_wav, "-af", af,
          "-ar", str(SR), "-c:a", "pcm_s16le", out_wav])


# Containers whose muxer rejects AAC, with the encoders to try in order.
_AUDIO_CODECS: dict[str, tuple[str, list[list[str]]]] = {
    ".webm": ("Opus", [["-c:a", "libopus", "-b:a", "160k"],
                       ["-c:a", "opus", "-strict", "-2", "-b:a", "160k"],
                       ["-c:a", "libvorbis", "-b:a", "160k"],
                       ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]]),
    ".mpg": ("MP2", [["-c:a", "mp2", "-b:a", "256k"]]),
    ".mpeg": ("MP2", [["-c:a", "mp2", "-b:a", "256k"]]),
}
_DEFAULT_AUDIO = ["-c:a", "aac", "-b:a", "256k"]
# Containers whose muxer rejects H.264, with the encoder to re-encode the picture
# with. -b:v 0 makes libvpx follow the CRF alone.
_VIDEO_CODECS: dict[str, list[str]] = {
    ".webm": ["-c:v", "libvpx-vp9", "-b:v", "0", "-row-mt", "1"],
}
_DEFAULT_VIDEO = ["-c:v", "libx264", "-preset", "slow"]
# ISO base media files, where +faststart moves the index to the front.
_ISO_BMFF = {".mp4", ".m4v", ".mov", ".qt", ".3gp", ".3g2", ".f4v"}
# Extensions ffmpeg can't infer a muxer from, with the muxer to name.
_MUXERS = {".qt": "mov"}
# Input streams copied next to the picture and the enhanced audio, where the
# container takes them. Data tracks (timecode, iPhone metadata) often can't be copied.
_KEPT_TYPES = ("audio", "subtitle", "attachment")


@functools.cache
def encoders() -> frozenset[str]:
    """Names of the encoders this ffmpeg was built with."""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True)
    lines = p.stdout.splitlines()
    start = next((i + 1 for i, ln in enumerate(lines) if ln.strip().startswith("---")), 0)
    return frozenset(ln.split()[1] for ln in lines[start:] if len(ln.split()) >= 2)


def audio_codec_args(out: str | Path) -> list[str] | None:
    """ffmpeg audio-encoder args for a video written to `out`, chosen by its
    container; None when this ffmpeg has no encoder that container accepts."""
    family = _AUDIO_CODECS.get(Path(out).suffix.lower())
    if family is None:
        return list(_DEFAULT_AUDIO)
    available = encoders()
    return next((list(args) for args in family[1] if args[1] in available), None)


def audio_codec_family(out: str | Path) -> str:
    """The audio format a container needs, for messages ("Opus", "AAC")."""
    return _AUDIO_CODECS.get(Path(out).suffix.lower(), ("AAC", []))[0]


def video_codec_args(out: str | Path, crf: int) -> list[str] | None:
    """ffmpeg video-encoder args to re-encode at `crf` for a video written to
    `out`, chosen by its container; None when this ffmpeg lacks that encoder."""
    args = _VIDEO_CODECS.get(Path(out).suffix.lower(), _DEFAULT_VIDEO)
    if args[1] not in encoders():
        return None
    return [*args, "-crf", str(crf), "-pix_fmt", "yuv420p"]


# Below this, a TS picture that starts after its audio is left to ffmpeg's
# rebasing: the error is under a frame.
_LATE_PICTURE_S = 0.04

# What ffmpeg says when a container won't take one of the copied streams.
_REFUSED_STREAM = ("Could not write header", "not currently supported in container",
                   "Could not find tag for codec", "codec not currently supported")


def remux(video_in: str | Path, wav_in: str | Path, out: str | Path,
          crf: int | None = None) -> None:
    """Replace the video's audio with wav_in. Video is stream-copied unless crf is given.

    wav_in is audio decoded from video_in's main track (see probe), so it starts
    where that track started; it is placed there again, and the picture is never
    cut short. The other audio tracks, subtitles and attachments are copied
    when the container takes them, and so are the file's tags: the recording
    date, and the location and camera details of an iPhone video.
    """
    suffix = Path(out).suffix.lower()
    audio_args = audio_codec_args(out)
    if audio_args is None:
        raise FfmpegError(f"this ffmpeg has no {audio_codec_family(out)} encoder, "
                          f"which {Path(out).suffix} files need")
    video_args = ["-c:v", "copy"] if crf is None else video_codec_args(out, crf)
    if video_args is None:
        encoder = _VIDEO_CODECS.get(suffix, _DEFAULT_VIDEO)[1]
        raise FfmpegError(f"this ffmpeg has no {encoder} encoder, which re-encoding "
                          f"{Path(out).suffix} video needs")
    info = probe(video_in)
    audio, tags = info["audio"], info["tags"]
    video = "v:0" if info["video_index"] is None else str(info["video_index"])

    # ffmpeg rebases every input to start at 0 and keeps the decoded audio's
    # offset from the file's start. MPEG-TS rebases by the mapped streams
    # instead, which loses the offset when the picture starts after the audio;
    # only then, and only when that is a frame or more, keep the input's own
    # timestamps and shift the output once. -copyts also turns off the
    # correction of timestamp jumps (joined TS files), so every other file
    # does without it.
    late_picture = ("mpegts" in info["format"]
                    and info["video_start"] - info["start"] >= _LATE_PICTURE_S)
    head = ["ffmpeg", "-y", "-v", "error"]
    if late_picture:
        head += ["-copyts", "-i", video_in]
        if info["audio_start"]:
            head += ["-itsoffset", f"{info['audio_start']:.6f}"]
    else:
        head += ["-i", video_in]
        if abs(info["audio_start"] - info["start"]) > 0.001:
            head += ["-itsoffset", f"{info['audio_start'] - info['start']:.6f}"]
    head += ["-i", wav_in]

    tail = ["-map_metadata", "0"]
    # The automatic copy drops the recording date, and the muxer ignores a date
    # the input lists twice (in mvhd and as an mdta key), so set it on its own.
    if created := str(tags.get("creation_time") or "").split(";")[0]:
        tail += ["-metadata", f"creation_time={created}"]
    if suffix in _ISO_BMFF:
        movflags = "+faststart"
        if any(k.startswith("com.apple.quicktime.") for k in tags):
            # An iPhone's location, make and model are written only as mdta keys.
            # The brand tags would become keys too; the muxer writes its own.
            movflags += "+use_metadata_tags"
            tail += [x for k in ("major_brand", "minor_version", "compatible_brands")
                     for x in ("-metadata", f"{k}=")]
        tail += ["-movflags", movflags]
    if late_picture and info["start"]:
        tail += ["-output_ts_offset", f"{-info['start']:.6f}"]
    if suffix in _MUXERS:
        tail += ["-f", _MUXERS[suffix]]
    tail.append(out)

    def command(extras: list[int]) -> list:
        cmd = [*head, "-map", f"0:{video}", "-map", "1:a:0"]
        cmd += [x for i in extras for x in ("-map", f"0:{i}")]
        cmd += [*video_args, *audio_args, "-disposition:1", "default"]   # the enhanced audio
        # Any per-stream metadata mapping turns off the automatic one for every
        # stream, so each output stream gets its source's tags (language, title).
        cmd += ["-map_metadata:s:0", f"0:s:{video}"]
        if audio is not None:
            cmd += ["-map_metadata:s:1", f"0:s:{audio['index']}"]
        for o, i in enumerate(extras, start=2):
            cmd += [f"-c:{o}", "copy", f"-map_metadata:s:{o}", f"0:s:{i}"]
            if i in tracks:
                # Two default tracks would both be enabled in a MOV or MP4, and
                # QuickTime would play the original under the enhanced audio.
                cmd += [f"-disposition:{o}", "-default"]
        return [*cmd, *tail]

    kept = [s for s in info["streams"] if s.get("codec_type") in _KEPT_TYPES and s is not audio]
    every = [int(s["index"]) for s in kept]
    tracks = [int(s["index"]) for s in kept if s["codec_type"] == "audio"]
    # A container can refuse a subtitle format, attachments or even a track (SRT
    # in MP4, say). Then keep less, down to just the picture and the new audio.
    attempts = [every, tracks] if tracks != every else [every]
    for extras in (a for a in attempts if a):
        try:
            _run(command(extras))
            return
        except FfmpegError as e:
            if not any(hint in e.stderr for hint in _REFUSED_STREAM):
                raise               # a full disk or a broken input: retrying won't help
    _run(command([]))
