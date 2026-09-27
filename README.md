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
both models, wires up the hotkeys and sets Hammerspoon to start on login. It is
the recommended path because it is the only one that does all of that for you.
To remove it again, run the installer with `--uninstall`.

Also on Homebrew, if you would rather manage it with `brew`:

```bash
brew install ompurwar/tap/voxtype
```

The formula installs the command and its module, and nothing else, so there are
four steps left. They are listed in order when it finishes, and `brew info
ompurwar/tap/voxtype` shows the same list at any time. In short: install Ollama
and the Hammerspoon cask, run `voxtype install-hammerspoon`, `ollama pull
qwen2.5:1.5b`, then grant the two permissions below.

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

While a dictation is in flight, a small pill sits at the bottom centre of the
screen. It shows a live waveform and an elapsed timer while recording, then the
current stage — transcribing, polishing — and disappears about a second after
the text has been pasted. It is only on screen for the seconds a dictation is
actually running, so it stays out of the way the rest of the time. See
[the overlay](#the-overlay) to resize it.

| Command | What it does |
| --- | --- |
| `voxtype doctor` | check the install and list what is missing |
| `voxtype config` | show resolved model paths and settings |
| `voxtype status` | report whether a recording is in progress |
| `voxtype warmup` | pre-download the whisper model |
| `voxtype config set KEY=VALUE` | store a setting so the hotkey sees it |
| `voxtype recordings` | list the recordings kept for debugging |
| `voxtype overlay` | show or change the overlay's size and look |
| `voxtype install-hint` | print the permission steps again |

## Requirements

- macOS on Apple Silicon. `whisperkit-cli` is not published for Intel.
- About 1.5 GB of downloads: ~500 MB for the whisper model, ~1 GB for `qwen2.5:1.5b`.
- About 3 GB of free disk space is required before the models are downloaded.
- First dictation after install is slow while models load into memory.

## Configuration

Everything is environment variables, so you can set them in your shell profile.

| Variable | Default | Notes |
| --- | --- | --- |
| `VOXTYPE_LANGUAGE` | `en` | `hi`, `mr` … ; set empty for auto-detect |
| `VOXTYPE_SCRIPT` | `auto` | `roman` or `native`; see [languages](#languages) |
| `VOXTYPE_WHISPER_MODEL` | follows the language | `small.en` for English, `medium` for anything else |
| `VOXTYPE_OLLAMA_MODEL` | follows the language | `qwen2.5:1.5b` for English, `qwen2.5:7b` for anything else |
| `VOXTYPE_OLLAMA_URL` | `http://localhost:11434/api/generate` | point at a remote box if you like |
| `VOXTYPE_OLLAMA_TIMEOUT` | `90` | seconds before falling back to the raw transcript |
| `VOXTYPE_MODEL_DIR` | discovered | override the whisper model path |
| `VOXTYPE_NO_PASTE` | unset | `1` prints instead of pasting |
| `VOXTYPE_BIN` | `~/.local/bin/voxtype` | used by the Hammerspoon module |

Setting `VOXTYPE_WHISPER_MODEL` or `VOXTYPE_OLLAMA_MODEL` always wins over the
per-language default.

### Languages

Both models default from `VOXTYPE_LANGUAGE`, because the English pair is a
dead end outside English: `small.en` has no other language in it at all, and the
1.5B rewriter was measured translating rather than cleaning —

```
in : नमस्ते यह एक परीक्षण है um मैं कल बारह बजे मिलूँगा like ठीक है
out: Hello, this is a test. Um, I'll be there at 7:00 PM. That's fine.
```

That is `qwen2.5:1.5b` on the default English prompt. So the defaults move with
the language:

| `VOXTYPE_LANGUAGE` | whisper | rewriter |
| --- | --- | --- |
| `en` (default) | `small.en` | `qwen2.5:1.5b` |
| anything else, or empty (auto) | `medium` | `qwen2.5:7b` |

Hindi and its neighbours get Hinglish. `medium` transcribes the speech
correctly, and its Latin letters are produced by a transliterator built into
`voxtype` rather than by the model (see below), so the rewriter only has to
tidy up text that is already in the script you asked for:

```
in : नमस्ते यह एक परीक्षण है um मैं कल बारह बजे मिलूँगा like ठीक है
out: namaste, yah ek pareekshan hai. Main kal barah baje milunga, theek hai.
```

Set `VOXTYPE_SCRIPT=native` to keep the original script instead, or
`VOXTYPE_SCRIPT=roman` to force Roman for a language not in the default list.

A guard checks the result and refuses to paste a bad one: if the rewrite comes
back in Devanagari, or comes back as English when the transcript was Hindi, the
model has translated instead of rewriting, and you get the raw transcript with a
line in `~/.cache/voxtype/hs.log` rather than a silently mistranslated document.
If you see that line, the rewriter is too small for the language — `qwen2.5:7b`
is the smallest that has been reliable here.

The transliteration is a lookup table in `voxtype`, not a model call, because no
model tested would do it. Whisper returns Devanagari and a Roman-script
`--prompt` does not change that; `qwen3:4b` reasons about the request instead of
answering it (its template appends `<think>` to every prompt, whatever the
thinking flag says) and burns over a thousand tokens doing so; `qwen2.5:7b`
hands the Devanagari straight back; and `qwen2.5:1.5b` translates the words into
English. A table has none of those failure modes and cannot mistranslate, and it
is instant.

### If the transcripts are poor

Three things are worth checking, in order, because they explain almost every bad
transcript seen on the machine this was built on:

1. **Is the language right?** A non-English language on the default English
   model does not fail, it forces the sounds into English words. See
   [languages](#languages).
2. **How loud is the input?** `voxtype recordings` keeps the last N recordings
   with the input peak in each sidecar. Speech should peak around 0.3-0.8; if
   yours sits near 0.1 the microphone gain is low, and `voxtype` lifts it before
   transcribing but it is better fixed at the source.
3. **Is there a lot of silence after you stop talking?** Whisper does not skip
   silence, it invents words for it. `voxtype` trims a long quiet run from either
   end before transcribing for exactly this reason.

### Setting things without a shell profile

`VOXTYPE_LANGUAGE` and friends can be exported in your shell profile, and that
works when you type `voxtype`. It does **not** work for the hotkey: Hammerspoon
is started by launchd and never reads your profile, so the dictation it runs
never sees it. That is the usual reason a setting looks ignored.

Write settings to a file instead:

```bash
voxtype config set LANGUAGE=hi        # takes effect on the next hotkey press
voxtype config                        # show what is in effect and where from
```

They are stored in `~/.config/voxtype/config` and read on every run. An
environment variable still wins, so a one-off override in the terminal is
unaffected.

> **Dictating in anything but English?** Set the language first. The default is
> English with `small.en`, an English-only model, and it does not fail loudly
> for other languages — it forces the sounds into English words. Hindi speech
> comes back as plausible-looking nonsense like *"I can't use the model language
> because it is a bit of an issue"*. `voxtype config set LANGUAGE=hi` switches
> to the multilingual pair.

### Keeping recordings for debugging

By default the audio is deleted after each dictation. To keep the most recent
ones — for working out why a transcript came out wrong — turn it on:

```bash
voxtype config set KEEP_RECORDINGS=50    # 0 is the default: keep nothing
voxtype config set KEEP_MAX_MB=200       # stop the directory growing past this
voxtype recordings                       # list what is being kept
```

Each recording is stored in `~/.cache/voxtype/recordings` under a name built
from the time it finished and the first 12 characters of its sha256, with a
`.json` beside it holding what the pipeline made of it:

```
20260928-001111-9bc9f6b4b45f.wav
20260928-001111-9bc9f6b4b45f.json

{ "when": "2026-09-28 00:11:11",
  "sha256": "9bc9f6b4b45f...",
  "mode": "stopped",              // or cancelled, no-speech, empty
  "language": "hi", "whisper": "small", "rewriter": "qwen2.5:7b",
  "raw_transcript": "...", "final_text": "..." }
```

The hash in the name is what makes this useful: two files with the same digest
are the same audio, so a doubled paste or a re-run is obvious at a glance.

**This keeps your speech on disk**, which the rest of this tool is careful not
to do. It is off unless you ask for it, and `voxtype recordings` exists so you
can see what is there. Delete the directory to be rid of it.

### The overlay

While you dictate, a small pill appears at the bottom of the screen with a
coloured dot, the current stage (`recording`, `transcribing`, `polishing`,
`pasted`), your elapsed time and a live waveform. It disappears on its own a
second after the text is pasted. It is drawn by Hammerspoon, so it needs
`voxtype install-hammerspoon` to have run.

Its size and look are tunable without reinstalling anything:

```bash
voxtype overlay                             # what is in effect right now
voxtype overlay set PILL_H=52 WAVE_H=46     # apply, then reload Hammerspoon
voxtype overlay reset                       # back to the defaults
```

| Setting | Default | Notes |
| --- | --- | --- |
| `VOXTYPE_PILL_W` | `360` | pill width |
| `VOXTYPE_PILL_H` | `52` | pill height |
| `VOXTYPE_PILL_R` | half the height | corner radius; the default is a full pill shape |
| `VOXTYPE_WAVE_H` | `36` | tallest waveform bar |
| `VOXTYPE_BARS` | `24` | how many bars |
| `VOXTYPE_PAD_L` | `26` | inset on the left, where the dot starts |
| `VOXTYPE_PAD_R` | `20` | inset on the right, where the clock finishes |
| `VOXTYPE_TEXT_DY` | `-1` | nudge the label and clock; the default is where they measured centred |

These are written to `~/.cache/voxtype/overlay.conf`. The same names work as
environment variables, which take precedence, but Hammerspoon is started by
launchd and does not see a variable added to your shell profile until you log
out and back in — which is why the conf file is the thing to edit.

Changing the rewrite model:

```bash
ollama pull qwen2.5:7b
export VOXTYPE_OLLAMA_MODEL=qwen2.5:7b
```

For English the default is `qwen2.5:1.5b`, at about 1 GB. Measured against
`qwen2.5:3b` and `qwen2.5:7b` on messy dictation, it was the fastest and handled
the awkward cases better than 3B, most obviously self-corrections (`"no, 3:60"
... "4:50"`, where 3B emitted the literal `3:60`) and text that tries to instruct
the rewriter. `qwen2.5:7b` is still worth trying if you dictate long passages: it
is better at keeping unit suffixes and spelled-out version numbers intact, and
slower.

Outside English it is `qwen2.5:7b`, at about 4.7 GB, because the 1.5B model
translates Hinglish into English rather than cleaning it, and `qwen3:4b` will not
answer without a page of reasoning first (see [languages](#languages)). Both are
Apache-2.0.

> **Do not use `qwen2.5:3b` commercially.** The 3B sizes are the only Qwen2.5
> models published under the Qwen Research License, which is non-commercial only
> and requires a separate license from Alibaba for commercial use. Every other
> Qwen2.5 size, including the 1.5B and 7B defaults here, is Apache-2.0. Check
> any replacement model's license before using it at work.

## Privacy

- Audio is captured by `sox` and transcribed by a CoreML model on your Mac.
- The transcript is sent to `http://localhost:11434` and nowhere else.
- Nothing is written anywhere except `~/.cache/voxtype` (a temporary wav),
  `~/.cache/hammerspoon` and the whisper model's own cache directory, which is
  under `~/Documents/huggingface` on a default install.
- That temporary wav is deleted after each dictation, unless you turn on
  [keeping recordings](#keeping-recordings-for-debugging), which stores the most
  recent ones as audio files in `~/.cache/voxtype/recordings`.

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
| Qwen2.5-1.5B (default rewrite model) | Apache-2.0 |

Full details in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## License

MIT
