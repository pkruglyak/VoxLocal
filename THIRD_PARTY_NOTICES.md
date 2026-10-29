# Third-Party Notices

VoxLocal bundles or uses the following third-party software.

## whisper.cpp (bundled)

- Source: https://github.com/ggml-org/whisper.cpp — pinned to tag **v1.9.5**
- Usage: compiled to the `whisper-cli` executable that ships inside `VoxLocal.app/Contents/MacOS/` and performs on-device speech recognition (includes ggml and its Metal backend).
- License: MIT

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

## Whisper models (downloaded by the user, not bundled)

- Source: https://huggingface.co/ggerganov/whisper.cpp (ggml conversions of OpenAI Whisper weights)
- Original model: OpenAI Whisper — https://github.com/openai/whisper — MIT License.
- Models are downloaded only on explicit user action and stored in `~/Library/Application Support/VoxLocal/models`.

## NVIDIA NeMo-Speech.cpp (bundled)

- Source: https://github.com/NVIDIA/NeMo-Speech.cpp — pinned to release **v0.2.0**
- Usage: the Apple Silicon Metal runtime is bundled as the `nemo-speech` executable and supporting dynamic libraries for local Parakeet file transcription.
- License: Apache License 2.0. The upstream license and third-party notices are copied into the application bundle at build time.

## NVIDIA Parakeet TDT 0.6B v3 (downloaded on request)

- Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 — pinned to revision `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`
- Usage: optional multilingual speech-recognition model downloaded only after explicit user confirmation; it is not included in the application archive.
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)

## Sparkle (bundled)

- Source: https://github.com/sparkle-project/Sparkle — version **2.10.0**
- Usage: secure update discovery, download, verification and installation.
- License: MIT

## CMake (build tool only, not distributed)

- Source: https://cmake.org (Kitware), version 3.30.5, downloaded into `vendor/tools/` by `scripts/bootstrap.sh` **only if** cmake is not already installed.
- License: BSD 3-Clause. CMake is used exclusively at build time and is not part of the application bundle.

## Ollama (optional, user-installed)

- https://ollama.com — MIT License. Not bundled, not required. VoxLocal only talks to a user-installed Ollama server over localhost when refinement is enabled.

## Apple frameworks

AppKit, SwiftUI, AVFoundation, CoreAudio, Carbon (HIToolbox), ApplicationServices, ServiceManagement — used under the Apple SDK license as part of macOS.
