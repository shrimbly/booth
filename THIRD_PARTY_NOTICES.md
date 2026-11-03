# Third-party notices

Booth is MIT licensed; see `LICENSE`. This file covers the third-party software
that Booth.app carries, and the software the engine downloads when it is first set up. Booth.app
has copies of both files in `Contents/Resources`.

## In Booth.app

### uv

`Contents/Resources/bin/uv` is [uv](https://github.com/astral-sh/uv), which Booth uses to install
its engine. uv is licensed under the MIT License or the Apache License 2.0, at your option. Booth
redistributes it under the MIT License:

```
MIT License

Copyright (c) 2025 Astral Software Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Silero VAD

`Contents/Resources/engine/src/booth/data/silero_vad.onnx` (`src/booth/data` in the repository) is
the speech detector of [Silero VAD](https://github.com/snakers4/silero-vad) 6.2.3, which the engine
asks before it takes a breath out of the voice. It is licensed under the MIT License:

```
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### DeepFilterNet3

`Contents/Resources/engine/src/booth/data/deepfilternet3.onnx` (`src/booth/data` in the repository)
is the network of [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet)3, exported from its
checkpoint by `scripts/export-deepfilternet3.py`. It is the `df3` engine, and finds where the speech
is for the pause gate. DeepFilterNet is licensed under the MIT License or the Apache License 2.0,
at your option. Booth redistributes it under the MIT License:

```
The MIT License (MIT)
Copyright (c) 2021 Hendrik Schröter

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Geist Serif

`Contents/Resources/Fonts/GeistSerif-Regular.ttf` (`app/Resources/Fonts` in the repository) is the
Geist Serif typeface, Copyright (c) 2023 Vercel, in collaboration with basement.studio. It is
licensed under the SIL Open Font License 1.1, whose full text ships beside the font as
`GeistSerif-OFL.txt`.

## Downloaded by the engine

Booth.app doesn't contain these. The engine downloads them from their publishers the first time it
is set up, or the first time a feature needs them, and they stay under their own licenses:

| Software | What Booth uses it for | License |
|---|---|---|
| [Sidon](https://huggingface.co/sarulab-speech/sidon-v0.1) | the default engine, which restores the voice | MIT |
| [w2v-BERT 2.0](https://huggingface.co/facebook/w2v-bert-2.0) | the speech features Sidon works from | MIT |
| [Demucs](https://github.com/adefossez/demucs) (HTDemucs) | separating speech from music | MIT |
| [ClearVoice](https://github.com/modelscope/ClearerVoice-Studio) (MossFormer2_SE_48K) | the `mossformer2` engine | Apache 2.0 |
| [DNSMOS P.835](https://github.com/microsoft/DNS-Challenge) | the quality scores in `booth eval` | MIT |
| [FFmpeg](https://ffmpeg.org) 9.0.2, [built by Martin Riedl](https://ffmpeg.martin-riedl.de) | reading and writing audio and video, on a Mac without ffmpeg of its own | GPL 3.0 or later |

The Python packages the engine installs (PyTorch, NumPy, SciPy and the others that `uv.lock`
names) come from the Python Package Index, each under its own license.
