#!/bin/bash
# smart-transcriber installer
#
#   curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash
#
# Installs the voxtype CLI, its dependencies, the local models, and the global
# hotkeys. Two macOS permissions still need a human click; every script step is
# automated. Run with --dry-run to preview, or --uninstall to remove.

set -uo pipefail

REPO_URL="https://github.com/ompurwar/smart-transcriber"

BIN_DIR="${VOXTYPE_BIN_DIR:-$HOME/.local/bin}"
REWRITE_MODEL="${VOXTYPE_OLLAMA_MODEL:-qwen2.5:3b}"
WHISPER_MODEL="${VOXTYPE_WHISPER_MODEL:-small.en}"
DO_MODELS=1
DO_HAMMERSPOON=1
DO_DEPS=1
DRY_RUN=0
UNINSTALL=0

usage() {
    cat <<EOF
smart-transcriber installer

usage: install.sh [options]

  --no-models       skip the whisper and ollama downloads
  --no-hammerspoon  install the CLI but not the global hotkeys
  --no-deps         assume dependencies are already present
  --dry-run         print what would happen without changing anything
  --uninstall       remove voxtype, its hotkeys, and its login item
  -h, --help        this text

environment
  VOXTYPE_BIN_DIR     where to install the binary (default ~/.local/bin)
  VOXTYPE_OLLAMA_MODEL rewrite model (default $REWRITE_MODEL)
  VOXTYPE_WHISPER_MODEL whisper variant (default $WHISPER_MODEL)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-models)      DO_MODELS=0 ;;
        --no-hammerspoon) DO_HAMMERSPOON=0 ;;
        --no-deps)        DO_DEPS=0 ;;
        --dry-run)        DRY_RUN=1 ;;
        --uninstall)      UNINSTALL=1 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# Locate the repo. Normally the installer runs from a clone or from stdin, so
# REPO_ROOT is derived from this script's location when that is possible.
SELF="${BASH_SOURCE[0]:-$0}"
if [ -f "$SELF" ] && grep -q "smart-transcriber installer" "$SELF" 2>/dev/null; then
    REPO_ROOT="$(cd "$(dirname "$SELF")" && pwd)"
elif [ -d "./bin/voxtype" ] && [ -d "./share" ]; then
    REPO_ROOT="$(pwd)"
else
    # Piped through stdin: fetch a shallow clone into a temp dir.
    REPO_ROOT="$(mktemp -d)"
    echo "smart-transcriber installer"
    echo "cloning $REPO_URL…"
    if ! git clone --depth 1 --branch main "$REPO_URL" "$REPO_ROOT" 2>/dev/null; then
        echo "error: could not clone $REPO_URL" >&2
        exit 1
    fi
    CLEANUP_CLONE=1
fi

cleanup() { [ -n "${CLEANUP_CLONE:-}" ] && rm -rf "$REPO_ROOT"; }
trap cleanup EXIT

# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/setup-ollama.sh
. "$REPO_ROOT/scripts/setup-ollama.sh"
# shellcheck source=scripts/setup-app.sh
. "$REPO_ROOT/scripts/setup-app.sh"

do_uninstall() {
    step "removing voxtype"

    if [ "$(bash "$BIN_DIR/voxtype" status 2>/dev/null || echo idle)" != "idle" ]; then
        warn "a recording is in progress; quitting voxtype first"
        "$BIN_DIR/voxtype" cancel >/dev/null 2>&1 || true
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would remove $BIN_DIR/voxtype, ~/.hammerspoon/voxtype.lua, the login item"
        info "would leave dependencies and downloaded models alone"
        return 0
    fi

    rm -f "$BIN_DIR/voxtype"
    ok "removed $BIN_DIR/voxtype"

    rm -f "$HOME/.hammerspoon/voxtype.lua"
    ok "removed the hotkey module"

    if [ -f "$HOME/.hammerspoon/init.lua" ]; then
        if grep -q 'require("voxtype")' "$HOME/.hammerspoon/init.lua"; then
            if [ -f "$HOME/.hammerspoon/init.lua.voxtype-backup" ]; then
                mv "$HOME/.hammerspoon/init.lua.voxtype-backup" "$HOME/.hammerspoon/init.lua"
                ok "restored your original ~/.hammerspoon/init.lua"
            else
                grep -v 'require("voxtype")' "$HOME/.hammerspoon/init.lua" > "$HOME/.hammerspoon/init.lua.tmp" \
                    && mv "$HOME/.hammerspoon/init.lua.tmp" "$HOME/.hammerspoon/init.lua"
                ok "removed the require line from init.lua"
            fi
        fi
    fi

    osascript -e 'tell application "System Events" to delete login item "Hammerspoon"' >/dev/null 2>&1 \
        && ok "removed the login item" || true

    if pgrep -x Hammerspoon >/dev/null 2>&1; then
        osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
    fi

    cat <<EOF

voxtype is gone. These were left in place because other tools may use them:

  ~/.cache/whisperkit            whisper models
  ollama list                     downloaded models

To remove those too:  ollama rm $REWRITE_MODEL
                      rm -rf ~/.cache/whisperkit
EOF
}

main() {
    echo "smart-transcriber - local voice typing for macOS"
    [ "${DRY_RUN:-0}" = "1" ] && echo "${C_DIM}(dry run: nothing will be changed)${C_OFF}"

    if [ "$UNINSTALL" = "1" ]; then
        do_uninstall
        return 0
    fi

    require_macos
    require_arch
    require_python3

    if [ "$DO_DEPS" = "1" ]; then
        ensure_homebrew
        step "dependencies"
        ensure_formula sox rec "sox"
        ensure_formula whisperkit-cli whisperkit-cli "whisperkit-cli"
    else
        warn "skipping dependency install (--no-deps)"
    fi

    install_binary

    if [ "$DO_HAMMERSPOON" = "1" ]; then
        if [ "$DO_DEPS" = "1" ]; then
            setup_hammerspoon
        elif [ -d "/Applications/Hammerspoon.app" ]; then
            setup_hammerspoon
        else
            warn "skipping hotkeys (--no-deps and Hammerspoon is not installed)"
        fi
        [ "$DO_DEPS" = "1" ] && setup_login_item
    fi

    setup_ollama

    if [ "$DO_MODELS" = "1" ]; then
        step "whisper model"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            info "would run: voxtype warmup"
        else
            VOXTYPE_WHISPER_MODEL="$WHISPER_MODEL" "$BIN_DIR/voxtype" warmup || warn "whisper warmup failed"
        fi
    else
        warn "skipping model downloads (--no-models)"
    fi

    finish
}

require_python3() {
    if have python3; then
        ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
    else
        warn "python3 not found - it is only used to reject bad model output"
        warn "install Xcode Command Line Tools with: xcode-select --install"
    fi
}

finish() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '\n%sThis was a dry run.%s Nothing was installed.\n' "$C_YLW" "$C_OFF"
        return 0
    fi

    cat <<EOF

$(printf '%s' "$C_GRN")voxtype is installed.$(printf '%s' "$C_OFF")

One last step needs you, because macOS only lets a human grant these:

  1. System Settings > Privacy & Security > Microphone
     turn on Hammerspoon
  2. System Settings > Privacy & Security > Accessibility
     turn on Hammerspoon

Then check everything:

  voxtype doctor

And dictate with:

  ctrl+opt+V            start and stop dictation
  ctrl+opt+delete       cancel
  ctrl+opt+R            start over

Your first dictation will be slower while the model loads. Nothing you say
leaves this Mac: transcription is on-device and the cleanup model is local.
EOF
}

main
