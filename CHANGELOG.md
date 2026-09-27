# Changelog

## Unreleased

- Multi-language dictation. The whisper and rewrite models now default from
  `VOXTYPE_LANGUAGE`: English keeps the fast `small.en` + `qwen2.5:1.5b` pair,
  anything else gets the multilingual `small` + `qwen2.5:7b`. Previously every
  language was forced through an English-only whisper model, and the 1.5B
  rewriter was measured translating Hindi into English rather than cleaning it.
- Hindi and its neighbours come out in Latin script (Hinglish) by default.
  Whisper still returns Devanagari, and no model would convert it — `qwen3:4b`
  will not answer without a page of reasoning first, `qwen2.5:7b` returns the
  Devanagari unchanged, and `qwen2.5:1.5b` translates the words — so the
  conversion is a transliteration table inside `voxtype` instead. The rewriter
  then only cleans up text that is already Roman. `VOXTYPE_SCRIPT=native` keeps
  Devanagari for anyone who wants it.
- A script guard refuses to paste a rewrite that came back in Devanagari, or as
  English when the transcript was Hindi, and falls back to the raw transcript
  with a line in the log.
- An empty `VOXTYPE_LANGUAGE` now really means auto-detect. It used to be
  turned into `en`, which also selected the English-only models.
- `voxtype doctor` and `voxtype warmup` now check that the whisper model is
  complete, not merely that its directory exists. An interrupted download used
  to look like a working model until the first transcription failed to load it.
- Fixed a double paste: two quick hotkey presses ran two processes that both
  decided to stop and paste, putting the same text in twice. The hotkey path is
  now serialised with a lock, with stale locks reaped so a crash cannot wedge
  dictation.
- Fixed the overlay's rounded corners. It set `roundedRadius`, which is not an
  attribute in this build of Hammerspoon and was dropped silently, so the pill
  and the waveform bars stayed square no matter what the value was.
- The overlay's waveform now covers ~16 ms of audio per bar instead of 6
  samples, so it traces the shape of speech rather than a shimmer, and the
  auto-gain is actually applied to the bars instead of being computed and
  discarded.
- The overlay's waveform scrolled the wrong way: the newest bar was drawn at the
  left edge, so it drifted right, against every other waveform a person has
  seen. The newest bar is now on the right and history moves left.
- Overlay polish: the recording dot breathes so you can tell the microphone is
  live rather than the pill being stuck; the clock is brighter and monospaced so
  the digits stop shifting as the seconds change; the pill has a shadow so it
  stays legible over a light desktop; and the space freed by shortening the
  "on your clipboard" label to "copied" went to the waveform.
- The overlay's label and clock are now centred on the pill's midline. There is
  no vertical alignment attribute in this build of Hammerspoon, and the
  `hs.drawing.textSize` the module was calling does not exist in it, so the old
  code silently fell back to a fraction of the point size and the label sat
  about 2px high. The offsets are now measured by rendering the text onto a
  canvas and reading the glyph rows back with `imageFromCanvas`; the label and
  the clock both land dead on the midline. Menlo, used for the clock's digits,
  sits 2px higher in its frame than the system font and gets its own nudge.
- The pill reacts on the key press instead of a moment later. The stage was
  published after a 350ms liveness sleep and two `osascript` spawns (the beep
  and the notification), so starting felt sluggish; measured with real sox it
  went from 887ms to 55ms between the key and the pill. Stopping was the same
  story in reverse -- the stage was published after the wait for sox to close
  the file -- and went from 278ms to 55ms. The cosmetic calls are now background
  and the liveness check runs out of band.
- The recording stage now always draws the waveform. A recording needs about a
  third of a second of audio before a bar can be measured, and the renderer
  fell back to the three pulsing dots for that gap, so the transcribing
  animation showed up at the start of every recording.
- The newest waveform bar was never drawn: the bars were collected with a
  zero-based index, which left the first one outside the array part of the
  table, so only 23 of the 24 reached the renderer.
- The overlay used to hide itself in the middle of any dictation longer than
  45 seconds. The stage timestamp is written once, when the recording starts,
  and it was being treated as a deadline; a two-minute recording lost its
  overlay a minute in. A recording is now judged alive by its wav file, which
  sox appends to continuously, rather than by its age.
- The overlay also survives its state file being removed. It falls back to the
  recorder's own wav, so a deleted `ui.state` no longer hides the overlay while
  a recording is running, and the clock is recovered from the file's length.
- The pill's end insets are settable (`VOXTYPE_PAD_L`, `VOXTYPE_PAD_R`) and the
  left one is a little wider than the right, which is what stops the dot's side
  looking tighter than the clock's.

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
