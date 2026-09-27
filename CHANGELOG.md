# Changelog

## v0.1.0

First release.

- `ctrl+opt+V` hold-to-talk dictation, `ctrl+opt+delete` to cancel,
  `ctrl+opt+R` to start over.
- On-device transcription via WhisperKit (`whisperkit-cli`), with the model
  directory discovered from the cache rather than hardcoded.
- Local rewrite pass via Ollama.
- A guard that discards model output which answers the prompt or leaks its own
  scaffolding, falling back to the raw transcript.
- Whisper's bracketed non-speech annotations (`[Music]`, `(laughter)`,
  `[BLANK_AUDIO]`) are stripped before the rewrite.
- The rewrite prompt drops a speaker's self-correction, keeping only the value
  they settled on, so "no, 4:50" becomes "4:50" and not "3:60".
- `voxtype doctor` for install diagnostics, `voxtype rewrite` for tuning the
  model against a transcript on stdin, `voxtype warmup` to pre-download.
- Installer handles dependencies, both model downloads, the Hammerspoon
  module, and the login item. An existing `~/.hammerspoon/init.lua` is backed
  up and restored on uninstall.
