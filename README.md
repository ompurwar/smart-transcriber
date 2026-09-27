# smart-transcriber

Hold-to-talk voice typing for macOS that never sends your voice anywhere.

Press a hotkey, talk, press it again, and clean prose lands in whatever app you
were using. Transcription runs on-device with WhisperKit; the cleanup pass runs
against a local Ollama model. There is no account, no API key, and no network
call at dictation time.

```
ctrl+opt+V            start / stop dictation
ctrl+opt+delete       cancel
ctrl+opt+R            start over
```

## Why

macOS dictation is good but it dictates *exactly* what it hears: "uh can you
send me the or report". Voxtype transcribes the same way, then a small local
model rewrites it into what you meant: "Can you send me the report?"

Every "smart dictation" tool I could find sent audio to a cloud service and
charged for it. This does the same job with two local models and no subscription.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash
```

The installer pulls in `sox`, `whisperkit-cli`, Ollama and Hammerspoon, downloads
both models, wires up the hotkeys, and sets Hammerspoon to start on login.

Prefer Homebrew:

```bash
brew install ompurwar/tap/voxtype
brew install --cask hammerspoon
voxtype install-hammerspoon
```

Preview the installer without touching your machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash -s -- --dry-run
```

## Two permissions you have to click

macOS does not let a script grant these, so the installer stops here. It takes
about fifteen seconds.

1. **System Settings > Privacy & Security > Microphone** — turn on Hammerspoon.
   `sox` records as a child of Hammerspoon, so Hammerspoon is the app that needs
   the permission.
2. **System Settings > Privacy & Security > Accessibility** — turn on Hammerspoon.
   The paste keystroke is an accessibility action.

Then confirm:

```bash
voxtype doctor
```

## Use it

Focus any text field, press `ctrl+opt+V`, talk, press `ctrl+opt+V` again. Text
appears after roughly two seconds.

| Command | What it does |
| --- | --- |
| `voxtype doctor` | check the install and list what is missing |
| `voxtype config` | show resolved model paths and settings |
| `voxtype status` | report whether a recording is in progress |
| `voxtype warmup` | pre-download the whisper model |
| `voxtype install-hint` | print the permission steps again |

## Requirements

- macOS on Apple Silicon. `whisperkit-cli` is not published for Intel.
- About 5.5 GB of downloads: ~500 MB for the whisper model, ~4.7 GB for `qwen2.5:7b`.
- About 7 GB of free disk space is required before the models are downloaded.
- First dictation after install is slow while models load into memory.

## Configuration

Everything is environment variables, so you can set them in your shell profile.

| Variable | Default | Notes |
| --- | --- | --- |
| `VOXTYPE_LANGUAGE` | `en` | set empty for auto-detect |
| `VOXTYPE_WHISPER_MODEL` | `small.en` | `tiny.en`, `base.en`, `small.en`, `medium.en` |
| `VOXTYPE_OLLAMA_MODEL` | `qwen2.5:7b` | see the model notes below |
| `VOXTYPE_OLLAMA_URL` | `http://localhost:11434/api/generate` | point at a remote box if you like |
| `VOXTYPE_OLLAMA_TIMEOUT` | `90` | seconds before falling back to the raw transcript |
| `VOXTYPE_MODEL_DIR` | discovered | override the whisper model path |
| `VOXTYPE_NO_PASTE` | unset | `1` prints instead of pasting |
| `VOXTYPE_BIN` | `~/.local/bin/voxtype` | used by the Hammerspoon module |

Changing the rewrite model:

```bash
ollama pull qwen3:4b
export VOXTYPE_OLLAMA_MODEL=qwen3:4b
```

The default is `qwen2.5:7b`. Measured on an M-series Mac: it is measurably
better than smaller models on long sentences and noticeably slower. If you want
a lighter setup, `qwen2.5:1.5b` is about 1 GB instead of 4.7 GB.

> **Do not use `qwen2.5:3b` commercially.** The 3B sizes are the only Qwen2.5
> models published under the Qwen Research License, which is non-commercial only
> and requires a separate license from Alibaba for commercial use. Every other
> Qwen2.5 size, including the 7B default here, is Apache-2.0. Check any
> replacement model's license before using it at work.

## Privacy

- Audio is captured by `sox` and transcribed by a CoreML model on your Mac.
- The transcript is sent to `http://localhost:11434` and nowhere else.
- Nothing is written anywhere except `~/.cache/voxtype` (a temporary wav, deleted
  after each dictation) and `~/.cache/whisperkit` (the model).

If you want proof, unplug the network. It keeps working.

## Troubleshooting

**The hotkey does nothing.** Run `voxtype doctor`. If Hammerspoon is not
listed as running, `open -a Hammerspoon`. If the config is stale, use the
menu bar icon and pick *Reload Config*.

**"recorder exited immediately"** means macOS denied microphone access. Grant
Hammerspoon the permission, then quit and reopen Hammerspoon.

**The paste does not happen, but the text is on your clipboard.** The
Accessibility permission is missing. Grant it and retry.

**The output is unpolished or the model talks back.** Small models sometimes
answer the prompt instead of rewriting it. Voxtype detects that and falls back
to the raw transcript, but a larger `VOXTYPE_OLLAMA_MODEL` helps.

**Nothing happens and no notification appears.** Check
`~/.cache/voxtype/hs.log`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash -s -- --uninstall
```

This removes the binary, the hotkey module, and the login item, and restores your
original `~/.hammerspoon/init.lua` if it had one. It deliberately leaves
Hammerspoon, the downloaded models, and Ollama alone, because other tools may
share them. The printed output tells you how to remove those too.

## Development

```bash
tests/test-voxtype.sh    # unit tests, no models or network needed
shellcheck install.sh bin/voxtype scripts/lib/*.sh scripts/*.sh
```

## Third-party components

voxtype ships two files, both original MIT-licensed work: the CLI and the
Hammerspoon module. It does not vendor, bundle, link or embed any third-party
code. Every dependency is a separate program, installed independently and run as
a child process, which is why the copyleft terms of SoX do not extend to it.

| Component | License |
| --- | --- |
| SoX | GPL-2.0-or-later and LGPL-2.1-or-later |
| whisperkit-cli (WhisperKit) | MIT |
| Ollama | MIT |
| Hammerspoon | MIT |
| Python | PSF License |
| openai/whisper-small.en | Apache-2.0 |
| Qwen2.5-7B (default rewrite model) | Apache-2.0 |

Full details in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## License

MIT
