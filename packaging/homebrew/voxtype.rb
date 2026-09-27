class Voxtype < Formula
  desc "Hold-to-talk voice typing for macOS with on-device Whisper and a local LLM"
  homepage "https://github.com/ompurwar/smart-transcriber"
  url "https://github.com/ompurwar/smart-transcriber/archive/refs/tags/v0.1.5.tar.gz"
  # The version is scanned from the URL, so it is not spelled out here.
  sha256 "c683759a48e4bcdc137d22c54ad9770e7b1d8c54b33a848fb39000f3897a1ddb"
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

    # Stamp the tag into the binary. The version used to be hardcoded in the
    # script and copied into the formula by hand, so the two drifted apart and
    # the installed binary reported 0.1.0 from a 0.1.1 keg. The tag is the only
    # place the version should be written down.
    inreplace bin/"voxtype", /^VOXTYPE_VERSION=".*"$/, "VOXTYPE_VERSION=\"#{version}\""
  end

  def caveats
    <<~EOS
      This formula installs the voxtype command and its Hammerspoon module, and
      nothing else. Four steps are left, and they are in this order because each
      one needs the previous:

        1. brew install ollama
           ollama serve &

        2. brew install --cask hammerspoon
           voxtype install-hammerspoon

        3. ollama pull qwen2.5:1.5b
           voxtype warmup

      Steps 2 and 3 are the English setup, which is the default. For another
      language, set VOXTYPE_LANGUAGE in your shell profile first (for example
      "hi" for Hindi) and then run step 3 with the model that language wants:
      `ollama pull qwen2.5:7b`. `voxtype config` prints the pair in effect, and
      `voxtype doctor` says so if the models and the language disagree.

        4. Start Hammerspoon, then grant it Microphone and Accessibility access
           in System Settings > Privacy & Security. macOS will not let a script
           do this, so it is the one step that has to be clicked:

             https://github.com/ompurwar/smart-transcriber#two-permissions-you-have-to-click

      Check the install at any time:

        voxtype doctor

      If you would rather have all of the above done for you, the standalone
      installer does every step on this list in one command, and is what the
      README recommends:

        curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash
    EOS
  end

  test do
    # `voxtype version` prints the bare version, so match the number rather than
    # the word: asserting on "version" here can never pass.
    assert_match "doctor", shell_output("#{bin}/voxtype help")
    assert_equal version.to_s, shell_output("#{bin}/voxtype version").strip
  end
end
