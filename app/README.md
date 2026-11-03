# Booth

Booth is a macOS menu bar app for the local speech enhancer in this repository (see the
[README](../README.md)). You give it a recording and it writes `<name>-enhanced` next to the
original. There are several ways to give it one: drop the file on the menu bar icon or the popover,
press ⌃⌥E with files selected in Finder, use the **Enhance with Booth** Quick Action, or use
**Open With › Booth**. Everything runs on your Mac. Nothing is uploaded.

When a file is done, you can play it in the popover and hold ⌥ to hear the original. For a video,
**Video** shows the picture in step with the sound. **Mix** shows the Speech, Background and Music
sliders, so you can change the mix and save again. The voice models don't run a second time, so a
new mix saves in a few seconds. **Done** takes you back to the drop zone.

## Requirements

- macOS 14 (Sonoma) or later on Apple silicon.
- The Command Line Tools for Xcode, with Swift 5.10 or later (Booth is developed with Swift 6.1).
  You don't need Xcode. To install the tools, run `xcode-select --install`.
- For real jobs, Booth's engine. If the repository's `.venv` exists, Booth uses it.
  Otherwise Booth installs its own engine the first time it runs. For that it needs `uv` (the build
  bundles the copy on your `PATH` when there is one) and a network connection for about 1.1 GB of
  models.
- `ffmpeg` and `ffprobe` for every file, audio or video. Booth looks in the `PATH` it was started
  with, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, and then asks your
  login shell. Without them, setup downloads a static build of both into `~/.cache/booth/bin`
  (57 MB), which comes last on the engine's `PATH`, so an ffmpeg you install later takes over.

## Build, run, install

```bash
app/scripts/build-app.sh              # release build → app/build/Booth.app
app/scripts/build-app.sh --open       # … then launch it
app/scripts/build-app.sh --install    # … then copy it to ~/Applications/Booth.app
app/scripts/build-app.sh --debug      # debug configuration instead of release
app/scripts/build-app.sh --dist       # for other Macs: no link to this checkout's engine
app/scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"   # see below
app/scripts/make-signing-identity.sh  # once: a local identity, so macOS stops asking after rebuilds
app/scripts/make-dmg.sh               # package app/build/Booth.app as Booth-<version>.dmg
app/scripts/release.sh                # tests, a --dist build and the image, into dist/
app/scripts/set-release-secrets.sh    # the release workflow's signing and notarization secrets
```

Releasing is described in the [root README](../README.md#build-and-release).

The script prints the path of the finished app on stdout and its progress on stderr, so
`app=$(app/scripts/build-app.sh)` works. You can run it as often as you like: every run assembles
the bundle again from scratch, and if a run fails, the previous `Booth.app` stays in place. These are
the steps:

1. `swift build -c release --product Booth`. A release build doesn't compile in the source-tree
   fallback described below.
2. Render the icon with `make-icon.swift`. The script reuses the cached
   `app/build/icon/Booth.icns` until `make-icon.swift` changes. The icon's 1024 px preview is
   `app/build/icon/Booth-1024.png`.
3. Assemble `Booth.app`:
   - Copy the `Resources/Info.plist` template, and set its version from `pyproject.toml` (the build
     number is the commit count, or `BOOTH_BUILD_NUMBER`). Unless `--dist`, if
     `<repo>/.venv/bin/booth` exists, add its path as `BoothEnginePath`.
   - Copy the executable. With `--dist`, strip its debug map (`strip -S`), which names this Mac's
     build folder.
   - Copy the fonts to `Contents/Resources/Fonts`. `ATSApplicationFontsPath` registers them.
   - Copy the root `LICENSE` and `THIRD_PARTY_NOTICES.md` (uv's and Geist Serif's notices) to
     `Contents/Resources`.
   - Copy the engine source (`src/` without `__pycache__`, `pyproject.toml`, `uv.lock`, `README.md`)
     to `Contents/Resources/engine`.
   - Copy `uv` to `Contents/Resources/bin/uv` (a `--dist` build fails without one), and
     `Resources/bin/booth` beside it. That script is the `booth` command Homebrew links
     onto `PATH`: it runs the managed engine, and installs or updates it first when needed. It
     never installs when `BOOTH_NO_INSTALL` is set, which Booth sets for every engine it starts.
4. Sign with the hardened runtime, which notarization requires: first `uv`, then the app with
   `Resources/Booth.entitlements` (Apple Events, for ⌃⌥E). The identity is
   - the one given by `--sign` or `BOOTH_SIGN_IDENTITY` (`-` means ad hoc);
   - otherwise the local identity from `make-signing-identity.sh`, if you made one;
   - otherwise ad hoc.

   A Developer ID signature also gets a secure timestamp. The script decides that from the
   certificate, so it works whether you give the identity by name or by its SHA-1 hash. Then verify
   with `plutil -lint`, check for the required keys, and run `codesign --verify --deep --strict`.
   Last, check that the app's signature has the entitlement, and that the app's and uv's signatures
   have the hardened runtime and, with a Developer ID, the secure timestamp notarization needs.
5. `--install`:
   - Quit a Booth that is running from `~/Applications`, then replace that copy.
   - Register the new copy with LaunchServices and refresh the Services menu.
6. `--open`: quit a Booth that is running from the same path, then launch the new one.

The script reads these environment variables. Most of them exist so you can test the script itself:

| Variable | Default | Purpose |
|---|---|---|
| `BOOTH_PACKAGE_DIR` | `app/` | SwiftPM package to build (its `Resources/` is used too) |
| `BOOTH_BUILD_DIR` | `$BOOTH_PACKAGE_DIR/build` | where `Booth.app` and `icon/` go |
| `BOOTH_REPO_DIR` | the repo holding the script | Booth checkout to bundle and point `BoothEnginePath` at |
| `BOOTH_INSTALL_DIR` | `~/Applications` | destination for `--install` |
| `BOOTH_UV` | `command -v uv` | uv binary to bundle; set it to an empty value to skip |
| `BOOTH_SIGN_IDENTITY` | the local identity, else `-` (ad hoc) | the same as `--sign` |
| `BOOTH_SIGNING_DIR` | `~/Library/Application Support/Booth Signing` | where `make-signing-identity.sh` keeps the local identity |

### Keep macOS permissions across rebuilds

macOS remembers a permission (Documents, Finder automation) for one app signature. An ad hoc
signature is different for every build, so macOS asks again after each rebuild. Run
`app/scripts/make-signing-identity.sh` once. It makes a self-signed certificate,
"Booth Local Signing", in its own keychain in `~/Library/Application Support/Booth Signing`. That
keychain isn't added to your keychain list, so it doesn't appear in Keychain Access. From then on,
`build-app.sh` signs with it, and every build has the same signature, so a permission you give
once carries over. The certificate only works on this Mac. Gatekeeper doesn't trust it, so you
can't use it to give Booth to anyone else. To remove it, delete that folder.

For development without a bundle, a debug build (`swift build`, `swift run`, `swift test`) falls
back to `app/Resources` in the source tree, and to this checkout for the engine source. Release
builds leave it out, so they use only what is in the bundle:

```bash
cd app
swift build
swift run Booth --demo --open                      # simulated engine, popover open
BOOTH_LOG_DIR=/tmp/booth-tests swift test          # keeps test logs out of ~/Library/Logs
```

## Launch flags

These flags work on `swift run Booth …` and on the built binary,
`app/build/Booth.app/Contents/MacOS/Booth …`.

| Flag | Effect |
|---|---|
| `--demo` | Simulated engine. No Python needed. Jobs take 6–11 s. A file name containing `silent` or `no-audio` fails with "no audio", `corrupt` fails with a decoding error, and `music` or `mus_` counts as music detected. |
| `--open` | Show the popover right after launch. |
| `--enqueue PATH…` | Queue files at launch. `open -a Booth file.wav` does the same through the document types. |
| `--engine PATH` | Use this engine executable and skip the search. |
| `--reset-defaults` | Clear Booth's preferences before starting. |
| `--render-states DIR` | Write PNGs of every popover screen in light and dark (`<screen>-<light\|dark>.png`, 2×) and exit. |
| `--motion-probe` | Play the popover's transitions (drop hover, Working, Done, Mix, Idle, Settings and back) in a window at the top left of the main screen, then quit. Record it with `screencapture -v -V 13 -R160,80,360,280 probe.mov` and step through the frames to check motion. |
| `--render-glyphs DIR` | Write the menu bar glyph in every state and exit. |
| `--render-demo DIR` | Write the website's demo video as frames (`frame-0001.png`…, 30 fps, 2×) from the real popover views and exit. `DIR/wallpaper.jpg` is the desktop and `DIR/poster.jpg` a still of the dragged video; `site/tools/make-demo-video.sh` fills both in and encodes the result. |
| `--selftest-engine FILE` | Run one real job on `FILE` without the UI, report the result and exit. |
| `--selftest-engine-name NAME` | Engine for the self-test: `sidon` (default), `mossformer2` or `df3`. |

Booth also reads these environment variables. They only reach Booth when you start the binary from
a terminal; Finder and `open` don't pass them on.

| Variable | Effect |
|---|---|
| `BOOTH_ENGINE` | Engine executable (searched after `--engine` and the `enginePath` preference). |
| `BOOTH_LOG_DIR` | Write `booth.log` here instead of `~/Library/Logs/Booth`. |
| `BOOTH_DEMO_FIRSTRUN=1` | With `--demo`, simulate a first-run setup that takes about 7 s. |
| `BOOTH_DEMO_SETUP_FAIL=1` | With `--demo`, make the first setup attempt fail. |
| `BOOTH_DEMO_ENGINE_WAIT=SECONDS` | With `--demo`, make the engine take this long to answer, so the first-run screen shows "Waiting for the engine" until then. |

## Using Booth

- **Ways in:**
  - Drop files on the menu bar icon. If you hover there for 0.7 s, the popover opens.
  - Drop files on the open popover.
  - Click "or choose a file".
  - Press ⌃⌥E to enhance the files selected in Finder.
  - Use the Finder Quick Action **Enhance with Booth**.
  - Use **Open With › Booth**.

  Booth leaves out files that aren't audio or video. If none of the files are, it says so: the
  popover shows an error, or for ⌃⌥E the capsule under the menu bar does. The file chooser only
  offers the types Booth takes. Booth works on one file at a time and queues the rest.
- **Outputs:**
  - Booth writes `<name>-enhanced.<ext>` in the input's folder. If that name is taken, it adds
    ` 2`, ` 3` and so on.
  - An audio input gives a `.wav` file.
  - A video input keeps its container (with the video stream copied, not re-encoded), and its
    `.wav` is written alongside.
- **While a file is in the booth:**
  - The whole popover is the progress bar: the percent on the left, the file name on the right.
    The fill spreads from the left like sound from a speaker, with faint rings moving through it.
  - The name stays out of focus until the fill passes under it.
  - **×** cancels the file and starts the next one in the queue. VoiceOver reads the stage, the
    time left and what's queued as the bar's value.
- **When a file finishes:**
  - If the popover is open, the bar fills to 100% and rests there for a moment, then the
    popover moves to the Done screen.
  - The Done screen has a play button, the waveform and two toggles:
    - **Video** (video files only) shows the picture at the top, with the play button and the
      waveform over its bottom edge. It plays muted, in step with the preview, so the sliders and
      ⌥ still change what you hear. Booth allows for the delay of your speakers or headphones, so
      lips stay in step with the voice on Bluetooth too. Click the picture to play or pause. Booth
      remembers the choice for the next video.
    - **Mix** shows the Speech, Background and Music sliders. It starts closed for each file.
  - On the right of the same row, **Open** shows the file in Finder, and **Done** moves on: to the
    next finished file you haven't seen, else to the file in the booth if one is running, else
    back to the drop zone. While the mix has unsaved changes, **Revert** and **Save** take their
    place.
  - If the popover shows something else when a file finishes (another file's Done screen,
    Settings or an error), the file waits its turn and **Done** moves on to it. If you were
    watching it when you opened Settings, **Back** shows its Done screen.
  - If the popover is closed, the icon shows a solid lamp and a notification says
    "<name> is out of the booth." The notification has **Show in Finder** and **Compare** buttons.
    When nothing is in the booth, opening the popover shows the oldest finished file you haven't
    seen, and **Done** moves on to the next.
  - Booth keeps up to ten finished files waiting to be seen. After you have seen a file's Done
    screen and moved on, Booth can't show it again, but its output stays where Booth wrote it.
- **Settings** (the gear in the popover):
  - Engine: **Studio** (Sidon, best quality), **Clean** (MossFormer2) or **Quick** (DeepFilterNet3).
  - **Keep the original video.** When it's off, Booth writes audio only.
  - **Skip music separation.** This is faster, but the Music slider goes away.
  - **Open at login.** This only takes effect when Booth is in `/Applications` or `~/Applications`.
  - **Updates: Check now** asks GitHub for the latest release of Booth. When it's newer than yours,
    **Download** opens its disk image in your browser. Booth only checks when you click.

## The engine

### How Booth finds it

Booth checks each candidate below in order. To check a candidate, it runs `booth app-info`,
which must answer with protocol 1. Most engines answer within 5 s. If a candidate is slower than
that, Booth doesn't skip it: it waits up to 3 minutes for that candidate and shows "Waiting for
the engine" in the meantime (see Troubleshooting). Booth uses the first candidate that passes:

1. `--engine PATH`
2. the `enginePath` preference (`defaults write studio.booth.Booth enginePath /path/to/booth`)
3. `BOOTH_ENGINE`
4. `BoothEnginePath` in `Info.plist` (the build adds `<repo>/.venv/bin/booth` when it exists)
5. the managed install, `~/Library/Application Support/Booth/engine/.venv/bin/booth`
6. `~/.local/bin/booth`
7. `command -v booth` in your login shell

Booth skips its own `booth` command (`Booth.app/Contents/Resources/bin/booth`, and links
to it such as Homebrew's `/opt/homebrew/bin/booth`). That command only starts the managed
install, and it would install the engine itself instead of letting Booth do it with progress.

Booth doesn't run a managed install that is older than the engine bundled with Booth, or whose
last install didn't finish. The search stops there and setup updates it (see below).

### First-run setup

Booth creates the managed install only when every candidate is missing or broken. An engine that
is slow to answer doesn't count as broken. These are the steps:

1. It looks for uv, and for `ffmpeg` and `ffprobe` (step 4 downloads those two if they're missing).
2. It copies `Booth.app/Contents/Resources/engine` to `~/Library/Application Support/Booth/engine`.
3. It runs `uv sync --frozen --python 3.11` there, with the bundled uv or the system's. Then it
   deletes `~/.cache/booth/sidon-venv`, the separate environment earlier versions ran Sidon in.
4. It runs `booth setup --events`.

The same steps update the managed install after you upgrade Booth. The copy keeps `.venv`, so
`uv sync` only installs what changed. `engine/.booth-engine-version` records the engine version
of the last `uv sync` that succeeded. Booth and the `booth` command both empty it before they
change anything and write it when they finish, and both compare it with the bundled engine's
version. So an update that fails or is interrupted is done again the next time. A managed install
from before this file existed counts as up to date when its source has the bundled version.

If an engine passes the check but reports `ready: false`, Booth runs only
`booth setup --events`.

Setup downloads these, about 1.1 GB in total (the engine reports the exact figure, which the popover shows):

- the Sidon weights and the w2v-BERT preprocessor
- htdemucs
- ffmpeg and ffprobe, only when they aren't installed: Martin Riedl's static build of FFmpeg 9.0.2,
  checked against pinned SHA-256 hashes

The popover shows the progress. **Run in background** closes the popover while setup continues.
Files you drop in the meantime wait in the queue and start when setup finishes.

### Protocol (version 1)

The app and the engine talk over JSON Lines on the engine's stdout. Each line is one object with an
`"event"` key and is flushed immediately. Human-readable output (logs, progress bars, warnings) goes
to stderr, which Booth copies to its log. Each side ignores keys and events it doesn't know.

| Command | Output |
|---|---|
| `booth app-info` | One `info` line, fast (no torch import): `{"event":"info","protocol":1,"version":"0.1.0","engines":["sidon","mossformer2","df3"],"ready":true,"missing":[],"python":"…"}` |
| `booth setup --events --check` | `{"event":"setup_status","ready":false,"missing":["sidon-weights",…],"bytes_total":N}` |
| `booth setup --events` | `setup` events (about 4 per second) with `phase`, `label`, `bytes_done`, `bytes_total`, `eta` and an overall `progress` (0–1, which also moves while the Sidon environment installs and no bytes are counted), then `done` or `error` |
| `booth enhance IN --events --stems-dir DIR -o OUT --engine sidon\|mossformer2\|df3 [--no-split] [--audio-only] -s 54 -b 10 -m 10` | `hello`, `start`, `progress` (about 4 per second, never goes backwards), then `done` or `error` |
| `booth remix DIR -s S -b B -m M --events [-o OUT]` | `hello`, `progress`, then `done` or `error`. It renders the output again from the stems at a new mix. |

These are the events of an enhance run, in order:

```json
{"event":"hello","protocol":1,"version":"0.1.0"}
{"event":"start","input":"/abs/in.mp4","name":"in.mp4","duration":192.0,"has_video":true,"has_audio":true,"meta":"3:12 · MP4 · 1080p","engine":"sidon","eta":109.0}
{"event":"progress","progress":0.52,"stage":"restore","label":"Restoring the voice","eta":61.0}
{"event":"done","output":"/abs/in-enhanced.mp4","wav":"/abs/in-enhanced.wav","video":"/abs/in-enhanced.mp4","stems":"/abs/DIR","took":108.7,"music":true,"mix":{"speech":54,"background":10,"music":10}}
```

- **Stages.** The stages are `decode` (Reading audio), `separate` (Separating music; skipped with
  `--no-split`), `restore` (Restoring the voice), `cleanup` (Removing clicks) and `write` (Writing
  the file). Clean and Quick show "Removing noise" and "Cleaning up" for the middle two.
- **Errors.** An error is `{"event":"error","code":…,"message":"…"}`. The engine then exits with 2,
  or with 130 when the job was cancelled. The codes are:
  - `not_found`
  - `no_audio`
  - `decode_failed`
  - `engine_failed`
  - `cancelled`
  - `setup_required`
  - `internal`
  - `setup_failed` (only from setup)

  Falling back from one model to another (Sidon → MossFormer2 → DF3) doesn't count as an error.
- **Cancelling.** With `--events`, the engine puts itself in its own process group. To cancel,
  Booth sends SIGTERM to that group, then SIGKILL after 3 s. The engine writes every output to a
  temporary file and then renames it, so a cancelled job never leaves a half-written file.
- **Stems directory.** Booth passes `~/Library/Caches/Booth/jobs/<uuid>` as the stems directory.
  It holds `manifest.json` and 48 kHz mono previews: `preview_clean`, `preview_vocals`,
  `preview_background`, `preview_music` (only when there is music) and `preview_original`.
  The player rebuilds the output at any mix from these files:

  `s_eff·clean + (1−s_eff)·vocals + b_eff·background + m_eff·music`,
  with `s_eff = 1−(1−s)^6`, `b_eff = b²` and `m_eff = m²`.

  The waveform comes from `manifest.bars`: 56 RMS bins for each stem.

  Booth keeps a job's stems while something can still use them: the file in the booth, the files
  in the queue, the file on screen, finished files waiting to be seen, and any file whose Save is
  running. Of the other jobs' stems, it keeps only the ten newest. Each launch deletes what earlier
  sessions left, except stems changed in the last hour, which may belong to another running Booth.

## Architecture

```
app/
  Package.swift              SwiftPM package "Booth": macOS 14, Swift 5 mode, no dependencies
  Sources/BoothCore/         Foundation-only logic, unit tested
    EngineProtocol.swift       EngineEvent + line decoder, LineBuffer
    StemsManifest.swift        manifest.json (Codable)
    Job.swift                  Job, JobState, JobResult, JobError
    PopoverLogic.swift         which screen to show on open, glyph mode
    SetupState.swift           first-run setup progress
    Formatting.swift           every user-facing string (status line, ETA, queue, …)
    Mix.swift                  slider curves, live waveform bar heights
    SignatureWave.swift        the "Booth" signature's soft focus, and the focus under the pointer
    SignatureReveal.swift      the signature coming forward through fog as the popover opens
    RippleBar.swift            the Working bar's rings, ripple timing and text fades
    OutputNaming.swift         "-enhanced", " 2", " 3"; supported file types
    EngineSearch.swift …       engine search order, engine process environment
    LaunchOptions.swift        command-line flags
  Sources/Booth/             the app (AppKit + SwiftUI)
    main.swift, AppDelegate    startup, headless modes, document opening, quitting
    Model/                     AppModel (the single source of truth), Settings, Log,
                               dependency protocols, and the fakes used by --demo and tests
    Engine/                    engine search, job runner (Process + JSON Lines), setup, remix
    Audio/                     preview player (AVAudioEngine stem mixer, A/B with the original)
    UI/                        the popover's SwiftUI screens, theme tokens, signature
    Shell/                     menu bar item and glyph, panel, drag and drop, ⌃⌥E, Services,
                               notifications, capsule HUD, login item
    Debug/                     --render-states snapshot renderer, --render-demo, --motion-probe
  Tests/                     Swift Testing: BoothCoreTests (pure logic), BoothTests (AppModel)
  Resources/                 Info.plist template, Booth.entitlements, Fonts/ (Geist Serif + OFL),
                             bin/booth (the command line shim bundled in the app)
  scripts/                   build-app.sh, make-dmg.sh, release.sh, set-release-secrets.sh,
                             make-icon.swift, make-signing-identity.sh
```

`AppModel` is where everything connects. The UI reads its state and calls its intents. The shell
(the menu bar item, drops, the hot key, Services, notifications) drives it. Engine events feed it.
Its dependencies come in two injected bundles: `EngineServices` (locator, job runner, setup,
remixer, preview player) and `SystemServices` (notifications, login item, workspace). `--demo` and
the tests replace the engine bundle with fakes.

## Logs and files

| What | Where |
|---|---|
| App log | `~/Library/Logs/Booth/booth.log`, rotated to `booth.log.1` at 5 MB. It records engine command lines, every engine stdout line, the end of stderr when a job fails, and state changes. |
| Unified log | `log stream --predicate 'subsystem == "studio.booth.Booth"'` |
| Preferences | `defaults read studio.booth.Booth` (`engine`, `keepVideo`, `noSplit`, `openAtLogin`, `enginePath`) |
| Job stems (live mixing) | `~/Library/Caches/Booth/jobs/<uuid>/` |
| Managed engine | `~/Library/Application Support/Booth/engine/` |
| Models and engine caches | `~/.cache/booth/` (Sidon environment, learned stage speeds, checkpoints), Hugging Face and torch caches |

## Troubleshooting

Start with the log: `tail -f ~/Library/Logs/Booth/booth.log`.

- **Booth always shows "Setting up", or setup fails.**
  - Run the engine yourself to see what it reports: `.venv/bin/booth app-info` and
    `.venv/bin/booth setup --events --check`.
  - Setup needs network access.
  - If the log says uv is missing, install uv (`brew install uv`) or rebuild with uv on your
    `PATH`, so the build bundles it.
  - "Couldn't download ffmpeg": setup downloads ffmpeg when it can't find one. If you have one
    installed somewhere else, Booth finds it the way a login shell does: check that
    `zsh -l -c 'command -v ffmpeg'` prints its path. If it only works in Terminal, move the line
    that adds its folder to `PATH` from `~/.zshrc` to `~/.zprofile`.
- **"Booth would like to access files in your Documents folder", or Booth shows "Waiting for the
  engine".** macOS holds Booth responsible for the engine it starts. If the checkout (and so
  `.venv` and the engine's source) is in `~/Documents`, `~/Desktop` or `~/Downloads`, the engine's
  first file access waits on that privacy prompt. While the prompt is unanswered, Booth shows
  "Waiting for the engine" for up to 3 minutes. It doesn't install anything in the meantime.
  Choose Allow and Booth continues. If the wait runs out, the first-run screen says the engine
  isn't answering. Choose Allow, then click **Try again** to search for it again. Booth only
  creates its own managed engine when no engine exists or every one is broken. The same prompt
  appears the first time Booth enhances a file in one of those folders. If macOS asks again after
  every rebuild, the build is signed ad hoc: see [Keep macOS permissions across rebuilds](#keep-macos-permissions-across-rebuilds).
  To start over, run `tccutil reset SystemPolicyDocumentsFolder studio.booth.Booth`.
- **The Booth icon isn't in the menu bar.** When the menu bar is crowded, or the screen has a
  notch, macOS hides the menu bar icons that don't fit. They disappear behind the notch. To bring
  Booth back, quit other menu bar apps, or hold ⌘ and drag other icons out of the menu bar to make
  room. When the Booth icon shows again, hold ⌘ and drag it further right so it stays visible.
  Until then you can still give Booth files with ⌃⌥E, the Finder Quick Action **Enhance with
  Booth**, or **Open With › Booth**. If you open Booth again from Finder or Spotlight, it shows the
  popover at the top right of the screen.
- **Booth doesn't find an engine you installed.** An app started from Finder doesn't get your
  shell's `PATH`. Booth asks your login shell as a last resort. If that fails, set the path
  yourself with `defaults write studio.booth.Booth enginePath /path/to/booth`, or start Booth
  with `--engine`.
- **"Enhance with Booth" is missing from Quick Actions.**
  1. Start Booth once. It registers its service at launch.
  2. Run `/System/Library/CoreServices/pbs -update`.
  3. Check that the service is on in System Settings › Keyboard › Keyboard Shortcuts › Services ›
     Files and Folders.
- **⌃⌥E does nothing, or says "Select audio or video in Finder first" when files are selected.**
  - Booth needs permission to control Finder: System Settings › Privacy & Security › Automation ›
    Booth › Finder.
  - If macOS asks again after every rebuild, see
    [Keep macOS permissions across rebuilds](#keep-macos-permissions-across-rebuilds). To start
    over, run `tccutil reset AppleEvents studio.booth.Booth`.
  - Another app may already use ⌃⌥E.
  - "Booth can't enhance the selected files" means none of the selected files are audio or video
    that Booth can read.
  - "Finder didn't answer in time" means Finder was busy for 10 seconds, for example on a stalled
    network volume or a long copy. Press ⌃⌥E again once Finder responds.
- **No notification when a file finishes.**
  - Booth only notifies while the popover is closed.
  - Allow notifications in System Settings › Notifications › Booth.
- **Open at login doesn't stick.** It only registers when Booth runs from `/Applications` or
  `~/Applications`. Use `build-app.sh --install`.
- **Open With or the Quick Action starts the wrong copy.** LaunchServices remembers every copy of
  Booth it has seen. Delete old copies, or unregister one with
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /path/to/Booth.app`.
- **The build fails.**
  - Run `swift build --package-path app` to see the compiler errors.
  - Delete `app/.build` for a clean build.
  - Check the Command Line Tools with `xcode-select -p`.
- **The UI looks wrong.** Run `Booth --render-states /tmp/booth-states` and compare the PNGs with the
  design.
