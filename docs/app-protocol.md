# The Booth app protocol

The Booth menu bar app (`app/`) drives the `booth` CLI as its engine. `--events`
switches a command to JSON Lines on stdout (one object per line, each with an
`event` key); logs and child-process output go to stderr.

```bash
booth app-info                              # {"event":"info","protocol":1,"ready":true,...}
booth setup --events [--check]              # install missing models, with byte progress
booth in.mp4 --events --stems-dir DIR -o out.mp4
booth remix DIR -s 80 -b 5 -m 0 --events    # re-render at a new mix in about a second
```

- **enhance** emits `hello`, `start`, `progress` about four times a second
  (stages `decode` → `separate` → `restore` → `cleanup` → `write`, never
  decreasing, with an ETA from speeds learned in `~/.cache/booth/speed.json`),
  then `done` or an `error` code (`not_found`, `no_audio`, `decode_failed`,
  `engine_failed`, `setup_required`, `internal`: exit 2). Problems that can be
  seen up front — an unreadable or too-short input, a read-only destination,
  an output that would replace the input, an ffmpeg without the encoder the
  video container needs — fail before `start`.
- **Cancel** with SIGTERM to the process group: the CLI leads its own group,
  reports `cancelled`, stops its children and exits 130. The wav, the video
  and the stems are committed together at the end, so a cancel or a failure
  leaves nothing beside the input. If the app goes away (the event pipe
  closes, or the engine is orphaned), the run cancels itself the same way.
- **`--stems-dir`** writes float32 preview stems scaled to the saved output
  plus `manifest.json` (mix, settings, 56-bin bars). Mixing them with the
  slider curves reproduces the output within one 16-bit step; with the
  mossformer2/df3 leveler the live preview is approximate. `remix` replays
  the exact post-mix chain and remuxes the video.
