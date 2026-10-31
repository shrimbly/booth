# How Booth works

The engine behind Booth and the `booth` command. For installing and using them, see the [README](../README.md).

## The pipeline

```
original ──Sidon (generative restoration)──▶ studio speech ─▶ tone + gate ─┐
original ──demucs──▶ vocals ──DeepFilterNet3──▶ speech key + background    ├─▶ mix
                     music ────────────────────────────────────────────────┘
output  = s·speech + (1−s)·vocals + b·background + m·music
```

The default engine is **Sidon** ([sarulab-speech/sidon-v0.1](https://huggingface.co/sarulab-speech/sidon-v0.1),
MIT), the same kind of model as Adobe Podcast. A w2v-BERT 2.0 encoder predicts
clean speech features, and a vocoder **resynthesizes** 48 kHz studio speech
from them. It rebuilds harmonics and bandwidth instead of masking noise, which
is where the clarity comes from. Discriminative denoisers (MossFormer2,
DeepFilterNet) can only subtract noise, so they sound muffled.

Sidon runs in its own Python environment, `~/.cache/booth/sidon-venv`,
because it needs a newer torch and transformers than the rest of the engine.
Every package in it is pinned to an exact version, and the Sidon and w2v-BERT
files are pinned to exact Hugging Face commits, so an upstream release can't
change the results below. Setup also checks the downloaded DeepFilterNet3
files against the SHA-256 hashes of the tested copy. The environment counts as
installed only once its install has finished and its packages import. Setup
rebuilds it from scratch if an install was interrupted or failed, or if the
pins changed. An environment set up before this check is kept as long as every
pinned package is fully installed.

Measured against Adobe Podcast Enhance v2 on four real recordings (30 s clips,
three held out from all earlier calibration; `scripts/bench.py`):

| | DNSMOS OVR | UTMOS | spectral distance to Adobe |
|---|---|---|---|
| original | 2.46 | 2.05 | 9.6 dB |
| previous default (MossFormer2 + DF3 + EQ/air) | 3.12 | 2.71 | 7.4 dB |
| **Sidon (new default)** | **3.37** | **3.56** | **6.2 dB** |
| Adobe Podcast | 3.35 | 3.60 | — |

UTMOS is a learned naturalness MOS (1–5). It's the metric that tracked the
"muffled vs clear" difference by ear; DNSMOS barely separated the engines.

Sidon-specific post-processing, each step measured on the benchmark:

- **Raw input.** Sidon gets the original, not the demucs vocals. Separation
  artifacts hurt it more than noise or even loud music (UTMOS 3.55 vs 3.25 on
  a speech + music test). demucs now only feeds the music slider and the gate key.
- **30 s chunks** split at quiet points. Each chunk is aligned to its own input
  and level-chained to the previous one across 2 s of shared context. Longer
  context degrades the model (96 s chunks: UTMOS 3.77 vs 3.89 on a 112 s file).
- **Tone correction.** Sidon runs 6–8 dB hotter than Adobe above 12 kHz on every
  lossless pair (audible as fizz), so the chain applies a −6 dB shelf from
  12 kHz, a 20 kHz rolloff, and a 40 Hz high-pass for regenerated rumble.
- **Speech gate keyed by DeepFilterNet3.** The generative model reproduces
  mouse clicks and low-level noise in pauses. DF3's output marks where speech
  actually is, and a lookahead gate with a 12 dB range drops pauses to around
  Adobe's floor without clipping word onsets.
- **Click removal.** Resynthesis rebuilds mouth, tongue and mouse clicks as
  sharp full-band bursts, while Adobe softens them by 15–40 dB. `dsp.declick`
  pulls down short bursts that stand far above the audio on *both* sides, so
  p/t/k bursts are kept because their vowel follows immediately. Off with
  `--no-declick`.
- **Harmonic smoothing.** Sidon's harmonics are fuzzier than Adobe's, which
  is heard as a slightly rough, "wobbly" voice. A pitch-following filter turns
  down the energy between harmonics by up to 6 dB below 3.5 kHz. Voiced
  periodicity goes from 0.80 to 0.83 (Adobe: 0.87). The −6 dB depth was chosen
  by ear; −10 dB starts to sound processed. Off with `--no-smooth`.
- **Music detection by held notes.** The music channel mutes unless the
  accompaniment stem has sustained, moving tonal peaks. Room noise and hum
  that demucs labels "accompaniment" no longer pass as music.

The other engines remain. `--engine mossformer2` is ClearVoice MossFormer2_SE_48K
plus a DF3 polish pass, with the calibrated EQ, air and leveler described below.
`--engine df3` is fastest and runs in-process. If Sidon can't run, the
pipeline falls back to mossformer2. (Resemble Enhance was also evaluated and
removed: it's generative too, but scored UTMOS 2.92.)

### Calibration (mossformer2 / df3 engines)

The slider curves, EQ, and gain staging were calibrated against a real Adobe
Podcast Enhance v2 reference pair (same input, sliders 54/10/10), by
least-squares fitting Adobe's output onto this pipeline's stem basis:

- **Adobe's sliders are perceptual, not linear** — at "54%" their output is
  ~fully-cleaned speech, and their measured gap noise floor (−42.8 dB below
  speech) implies near-zero raw-stem reinjection. We reproduce that:
  `s_eff = 1−(1−s)^6`, `b_eff = b²`, `m_eff = m²` (bypass with `--linear`).
- **Match-EQ**: a 1/6-octave FIR profile derived from the reference pair shapes
  the clean speech toward Adobe's timbre (`--no-match-eq` to disable). It
  restores the low-end voice body (40–150 Hz, up to +14 dB) that enhancement
  models strip — measured result: every octave band within ±1.8 dB of Adobe.
- **Auto gain**: Adobe normalizes *active speech* level (their outputs cluster
  at a fixed active-speech dB while integrated LUFS varies with pause density);
  `booth` targets the same measure (−29 dB, validated by ear) with a
  true-peak guard. It lifts by at most +30 dB, and a voice channel below
  −70 dB (silence, or only model residue) keeps its level, as does a mix too
  quiet for `--lufs N`. Override with `--lufs N` or `--no-normalize`.
- **Air**: a synthetic 8–16 kHz breath layer, modulated by the speech envelope
  and level-swept against Adobe's measured air signature — replicates the
  regenerative-model sheen that discriminative enhancers strip (`--no-air`).
- **Leveler**: slow ±3.5 dB AGC on the voice channel (`--no-leveler`).
- **Calibration data**: 5 real Adobe pairs. The EQ uses the 5-pair median where
  the pairs agree tightly (250 Hz–8 kHz, std ≈1 dB) and the lossless
  ear-validated pair in the divergent bands (<200 Hz, >11 kHz).
- **DNSMOS**: `booth eval` reports P.835 perceptual scores (OVR/SIG/BAK)
  alongside the physical metrics. The model downloads once to
  `~/.cache/booth` and is checked against its SHA-256. A cut-off or
  damaged copy is deleted and downloaded again.

## Video and multitrack files

ffmpeg reads the input and writes the enhanced copy (`audio.py`).

- **The track that's enhanced** is the one ffmpeg would pick itself: a
  default track first, then the one with the most channels. It's mixed down to
  mono. Files with more than two channels and no channel layout (a field
  recorder's poly WAV, for example) are summed with equal weights. Otherwise
  ffmpeg would guess a 5.1 or 7.1 layout and leave channel 4 out as LFE.
- **Timing.** Gaps in the track's timestamps, such as a dropout in a stream
  capture, are decoded as silence, so everything after a gap stays in sync.
  The enhanced audio goes back where the track started on the input's own
  timeline. A picture that starts before or after the sound keeps that offset
  in every container, MPEG-TS and AVCHD `.mts` included.
- **The picture** is copied as it is. With `--crf N` it's re-encoded with H.264,
  or with VP9 for `.webm` (where CRF runs 0–63).
- **Other streams.** The enhanced audio becomes the first, default audio track.
  The other audio tracks, subtitles and attachments are copied if the output
  container accepts them. If it refuses some (SRT subtitles in an MP4, for
  example), the copy keeps just the other audio tracks. If those are refused
  too, it keeps only the picture and the enhanced audio. Data tracks
  (timecode, an iPhone's timed metadata) are left out.
- **Tags** of the file and of each track are kept where the container can hold
  them: the recording date, track languages, and an iPhone video's location,
  make and model.

## Benchmarking

`scripts/bench.py` scores outputs against Adobe references on 30 s clips in
`test-output/bench/` (`<clip>_in.wav`, `<clip>_adobe.wav`, `<clip>_<tag>.wav`).
It reports DNSMOS, UTMOS, mel spectral distance to Adobe, pause noise floor
and octave-band deltas. Alignment uses speech envelopes, because
resynthesized output isn't phase-locked to the input.

```bash
uv run python scripts/bench.py in adobe <tag> ...
```

