# Third-party notices

Lockstep is free software under the GNU General Public License, version 3 or later (see
`LICENSE`). It uses the open source work listed here. Each part keeps its own licence.

## Rubber Band Library

- What it does in Lockstep: stretches and squeezes recorded voice without changing its pitch,
  and makes the pitched and resized voices of doubles and of a track's Voice.
- Version: 4.0.0 (commit `1d95888bec3ae0a17c0c4af791810d5a63f6bc35`).
- Where: the library's source files, unchanged, in `LockstepKit/Sources/CRubberBand/vendor/rubberband/`.
  It is built into the app.
- Copyright 2007-2024 Particular Programs Ltd.
- Licence: GNU General Public License, version 2 or later. The full text is in
  `LockstepKit/Sources/CRubberBand/vendor/rubberband/COPYING`.
- Source: <https://breakfastquay.com/rubberband/>

Rubber Band is the reason Lockstep as a whole is under the GPL. Breakfast Quay also sells a
commercial licence for Rubber Band. Anyone who wants to distribute Lockstep, or a program
made from it, under terms other than the GPL needs that licence first.

## Beat This!

- What it does in Lockstep: finds the beats and bar starts of a song.
- Not part of this repository. `Scripts/install-beat-model.sh` downloads the published model
  weights (checkpoint `final0`, checked against a SHA-256 checksum), converts them to Core ML
  with the `beat-this` Python package and installs the result on the Mac that runs it, at
  `~/Library/Application Support/Lockstep/Models/BeatThis.mlpackage`. Lockstep's own Swift
  code prepares the sound for the model and reads its answer the way the original code does.
- Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria.
- Licence: MIT. The project says that its code and its published model weights are under
  this licence. Some of the data the model was trained on is under other terms; see the
  project's README.
- Source: <https://github.com/CPJKU/beat_this>

```
MIT License

Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria

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

## whisper.cpp

whisper.cpp writes out the words of clips. The app includes the prebuilt framework of
whisper.cpp build b5454, the commit of v1.9.5, which Swift Package Manager downloads as
`LockstepSpeechKit/Package.swift` says.

- Source: https://github.com/ggml-org/whisper.cpp
- Licence: MIT

```
MIT License

Copyright (c) 2023-2026 The ggml authors

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

## Speech models

The models are not part of this repository or the app. `Scripts/install-speech-model.sh`
downloads them from Hugging Face onto your Mac.

### KB-Whisper Small (Swedish)

KBLab, the data lab of the National Library of Sweden, made this model. The script
downloads `ggml-model.bin` of commit `066ef166dd25b4b27039517ca77af30c1c10688a`.

- Source: https://huggingface.co/KBLab/kb-whisper-small
- Licence: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0

### Whisper large-v3-turbo (any language)

This is OpenAI's Whisper model in the q5_0 form that the whisper.cpp project publishes. The
script downloads `ggml-large-v3-turbo-q5_0.bin` of commit `5359861c739e955e79d9a303bcbc70fb988958b1`.

- Model: https://github.com/openai/whisper
- File: https://huggingface.co/ggerganov/whisper.cpp
- Licence: MIT

```
MIT License

Copyright (c) 2022 OpenAI

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

## Tools used only to build or install

The model install script and the test reference script run Python packages (among them
`beat-this`, `torch`, `torchaudio` and `coremltools`), which `uv` downloads into its own
cache. They convert the model on your Mac and are not part of the app or of this repository.
