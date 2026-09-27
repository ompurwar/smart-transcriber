# Third-party notices

smart-transcriber (`voxtype`) is MIT licensed. See [LICENSE](LICENSE).

## What this project ships

The published artifacts are two files, both original work covered by the MIT
license in this repository:

- `bin/voxtype` — the CLI
- `share/hammerspoon.lua` — the Hammerspoon hotkey module

The Homebrew formula installs exactly those two files. **No third-party source
code is vendored, copied, bundled, linked, or embedded in this repository.**

## What this project depends on

Every dependency below is a separate program, installed independently (usually
by Homebrew) and invoked as a child process. voxtype does not link against any
of them, and does not redistribute them. This is why the copyleft terms of SoX
do not extend to this project: nothing here becomes a derivative work of SoX.

| Component | License | How it is used |
| --- | --- | --- |
| [SoX](https://sox.sourceforge.net/) | GPL-2.0-or-later **and** LGPL-2.1-or-later | `rec` records the microphone |
| [whisperkit-cli](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit) | MIT | on-device transcription |
| [Ollama](https://github.com/ollama/ollama) | MIT | serves the local rewrite model |
| [Hammerspoon](https://www.hammerspoon.org/) | MIT | hosts the global hotkeys |
| [Python](https://www.python.org/) | PSF License | optional; filters bad model output |
| [openai/whisper-small.en](https://huggingface.co/openai/whisper-small.en) | Apache-2.0 | the transcription weights |
| [argmaxinc/whisperkit-coreml](https://github.com/argmaxinc/whisperkit-coreml) | see upstream | the Apple Neural Engine conversion of the weights above |
| [Qwen2.5-7B](https://huggingface.co/Qwen/Qwen2.5-7B) | Apache-2.0 | the default rewrite model |

Full license texts belong to their respective authors and are shipped with each
component. Nothing in this repository changes or supersedes them.

## A note on the rewrite model

The rewrite model is deliberately **not** `qwen2.5:3b`, even though it is smaller
and a reasonable-sounding default. `Qwen/Qwen2.5-3B` and `Qwen/Qwen2.5-3B-Instruct`
are the only Qwen2.5 sizes published under the **Qwen Research License**, which
grants use "for non-commercial purposes only" and requires a separate license
from Alibaba for commercial use. Every other Qwen2.5 size, including the 7B used
here, is Apache-2.0.

Set `VOXTYPE_OLLAMA_MODEL` to change it. Check the license of any replacement
before using it commercially.

## Contributions

By contributing you agree that your contribution is licensed under the MIT
license in [LICENSE](LICENSE).
