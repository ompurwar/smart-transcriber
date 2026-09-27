# Limitations

## Apple Silicon only

`whisperkit-cli` is published for Apple Silicon only. Intel Macs cannot run
voxtype; the installer exits rather than failing later with a confusing error.

## Two permissions cannot be automated

macOS requires a human to approve Microphone and Accessibility access in
System Settings. The installer prints the steps and stops. This is a platform
restriction, not a limitation of the installer.

## sox is in maintenance

`sox` is unmaintained upstream and the Homebrew formula is old, but it still
works and still ships a working `rec` for macOS. If it ever disappears, the
replacement is `ffmpeg -f avfoundation -i ":0"`.

## Small models sometimes misbehave

The rewrite step uses a 3B-parameter model. It occasionally answers the prompt
instead of rewriting it. Voxtype detects the common shapes of that and falls
back to the unpolished transcript, but raising `VOXTYPE_OLLAMA_MODEL` is the
real fix.

## No multiple languages in one dictation

`VOXTYPE_LANGUAGE` is fixed per run. Set it empty for auto-detect if you switch
between languages, at the cost of some accuracy.

## No app-specific behaviour

voxtype does not know which app it is typing into, so it cannot apply
capitalisation rules, code formatting, or domain vocabulary. The rewrite prompt
is generic.
