class Voxtype < Formula
  desc "Hold-to-talk voice typing for macOS with on-device Whisper and a local LLM"
  homepage "https://github.com/ompurwar/smart-transcriber"
  url "https://github.com/ompurwar/smart-transcriber/archive/refs/tags/v0.1.1.tar.gz"
  # The version is scanned from the URL, so it is not spelled out here.
  sha256 "071cb7419f2d31240c06bcef73a718bf4df7fa7bde54001a4c5e7ee05b90e879"
  license "MIT"

  depends_on "sox"
  depends_on "python3"

  # whisperkit-cli is Apple Silicon only, which is the same constraint the
  # formula's own description already advertises.
  on_macos do
    on_arm do
      depends_on "whisperkit-cli"
    end
  end

  def install
    bin.install "bin/voxtype"
    pkgshare.install "share/hammerspoon.lua"
  end

  def caveats
    <<~EOS
      voxtype needs a global hotkey, so it installs a Hammerspoon module:

        brew install --cask hammerspoon
        voxtype install-hammerspoon

      Then start Hammerspoon and grant it Microphone and Accessibility
      access in System Settings > Privacy & Security. See:

        https://github.com/ompurwar/smart-transcriber#two-permissions-you-have-to-click

      Pull the local rewrite model once:

        ollama pull qwen2.5:1.5b
        voxtype warmup

      Check the install at any time:

        voxtype doctor
    EOS
  end

  test do
    # `voxtype version` prints the bare version, so match the number rather than
    # the word: asserting on "version" here can never pass.
    assert_match "doctor", shell_output("#{bin}/voxtype help")
    assert_equal version.to_s, shell_output("#{bin}/voxtype version").strip
  end
end
