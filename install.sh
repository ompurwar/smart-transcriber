#!/bin/bash
# smart-transcriber installer
#
#   curl -fsSL https://raw.githubusercontent.com/ompurwar/smart-transcriber/main/install.sh | bash
#
# Installs the voxtype CLI, its dependencies, the local models, and the global
# hotkeys. Two macOS permissions still need a human click; every script step is
# automated.
#
# The installer is safe to re-run. It records what it owns, so a second run
# updates in place and an uninstall never removes something you created.

set -uo pipefail

REPO_URL="${VOXTYPE_REPO_URL:-https://github.com/ompurwar/smart-transcriber}"
REPO_REF="${VOXTYPE_REF:-main}"

BIN_DIR="${VOXTYPE_BIN_DIR:-$HOME/.local/bin}"
REWRITE_MODEL="${VOXTYPE_OLLAMA_MODEL:-qwen2.5:3b}"
WHISPER_MODEL="${VOXTYPE_WHISPER_MODEL:-small.en}"

DO_MODELS=1
DO_HAMMERSPOON=1
DO_DEPS=1
DRY_RUN=0
UNINSTALL=0
FORCE=0
ASSUME_YES=0

WARN_COUNT=0
CHANGES=""

usage() {
    cat <<EOF
smart-transcriber installer

usage: install.sh [options]

  --dry-run         print what would happen without changing anything
  --no-models       skip the whisper and ollama downloads
  --no-hammerspoon  install the CLI but not the global hotkeys
  --no-deps         assume dependencies are already present
  --force           continue even if another voxtype is found on PATH
  --uninstall       remove voxtype and the things this installer created
  -y, --yes         answer yes to every question (for scripts and CI)
  -h, --help        this text

environment
  VOXTYPE_BIN_DIR     where to install the binary (default ~/.local/bin)
  VOXTYPE_OLLAMA_MODEL rewrite model (default $REWRITE_MODEL)
  VOXTYPE_WHISPER_MODEL whisper variant (default $WHISPER_MODEL)
  VOXTYPE_REF         git ref to install from (default $REPO_REF)
  VOXTYPE_REPO_URL    install from a fork instead
  VOXTYPE_HEADLESS=1  never launch apps or edit login items, for CI and ssh

re-running is safe: the installer records what it owns, updates in place, and
only removes its own changes on --uninstall.
EOF
}

# FORCE and ASSUME_YES are read by the sourced preflight and common scripts,
# which shellcheck cannot see across the file boundary.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
    case "$1" in
        --no-models)      DO_MODELS=0 ;;
        --no-hammerspoon) DO_HAMMERSPOON=0 ;;
        --no-deps)        DO_DEPS=0 ;;
        --dry-run)        DRY_RUN=1 ;;
        --uninstall)      UNINSTALL=1 ;;
        --force)          FORCE=1 ;;
        -y|--yes)         ASSUME_YES=1 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- repo

# Resolve the repo. Piped through stdin there is no script file to read from, so
# fetch the tree first. git is nice to have but not required, and Homebrew is
# not installed yet at this point, so fall back to a tarball.
#
# This runs before scripts/lib/common.sh exists, so it must not use have/info/ok
# or anything else from the library. Using them here silently took the tarball
# path on every piped install, because `have git` could not be found.
fetch_repo() {
    local dest="$1"
    say() { printf '    %s\n' "$1" >&2; }
    mkdir -p "$dest" 2>/dev/null

    if command -v git >/dev/null 2>&1; then
        say "downloading the installer via git…"
        if git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$dest" >/dev/null 2>&1; then
            return 0
        fi
        say "git clone did not work, trying a tarball…"
        rm -rf "$dest"
        mkdir -p "$dest"
    fi

    local tarball="$dest.tar.gz"
    say "downloading a tarball from ${REPO_URL}/archive…"
    if ! curl -fsSL --max-time 120 -o "$tarball" \
        "https://codeload.github.com/${REPO_URL#https://github.com/}/tar.gz/$REPO_REF"; then
        rm -f "$tarball"
        return 1
    fi

    local inner
    inner=$(tar -tzf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)
    [ -n "$inner" ] || { rm -f "$tarball"; return 1; }
    tar -xzf "$tarball" -C "$dest" --strip-components=1 2>/dev/null || {
        rm -f "$tarball"
        return 1
    }
    rm -f "$tarball"
    return 0
}

SELF="${BASH_SOURCE[0]:-$0}"
if [ -f "$SELF" ] && grep -q "smart-transcriber installer" "$SELF" 2>/dev/null; then
    REPO_ROOT="$(cd "$(dirname "$SELF")" && pwd)"
elif [ -d "./bin/voxtype" ] && [ -d "./share" ]; then
    REPO_ROOT="$(pwd)"
else
    REPO_ROOT="$(mktemp -d)"
    CLEANUP_CLONE=1
    if ! fetch_repo "$REPO_ROOT"; then
        echo "error: could not download the installer from ${REPO_URL} (ref ${REPO_REF})" >&2
        echo "       check your connection, or set VOXTYPE_REF to a tag such as v0.1.0" >&2
        exit 1
    fi
fi

# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/preflight.sh
. "$REPO_ROOT/scripts/preflight.sh"
# shellcheck source=scripts/setup-ollama.sh
. "$REPO_ROOT/scripts/setup-ollama.sh"
# shellcheck source=scripts/setup-app.sh
. "$REPO_ROOT/scripts/setup-app.sh"

cleanup() {
    [ -n "${LOCK_DIR:-}" ] && rm -rf "$LOCK_DIR"
    [ -n "${CLEANUP_CLONE:-}" ] && [ -n "${REPO_ROOT:-}" ] && \
        case "$REPO_ROOT" in /tmp/*|/var/folders/*) rm -rf "$REPO_ROOT" ;; esac
    return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- uninstall

do_uninstall() {
    step "removing voxtype"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would remove what this installer created, and nothing else"
        return 0
    fi

    # Stop any recording first, so removing the binary cannot orphan a process.
    if [ -x "$BIN_DIR/voxtype" ]; then
        if [ "$(bash "$BIN_DIR/voxtype" status 2>/dev/null || echo idle)" != "idle" ]; then
            warn "a recording is in progress; stopping it"
            bash "$BIN_DIR/voxtype" cancel >/dev/null 2>&1 || true
        fi
    fi

    # Only remove the login item if we were the ones who added it. A user who
    # already had Hammerspoon in their login items keeps it.
    #
    # Headless runs must not touch login items at all: a CI runner or an ssh
    # session has no business editing the real user's System Events database,
    # and "remove what we added" is unverifiable without a GUI session.
    if [ "${VOXTYPE_HEADLESS:-0}" = "1" ]; then
        info "headless: left the login items alone"
    elif [ "$(state_get WE_MADE_LOGIN_ITEM 2>/dev/null)" = "1" ]; then
        if osascript -e 'tell application "System Events" to delete login item "Hammerspoon"' >/dev/null 2>&1; then
            ok "removed the login item this installer added"
        else
            warn "could not remove the login item; remove it in System Settings > General > Login Items"
        fi
    elif osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
        | tr ',' '\n' | grep -q 'Hammerspoon'; then
        info "keeping the Hammerspoon login item: you had it before voxtype did"
    fi

    if [ -f "$HOME/.hammerspoon/voxtype.lua" ]; then
        rm -f "$HOME/.hammerspoon/voxtype.lua"
        ok "removed the hotkey module"
    fi

    # Restore the user's init.lua. Prefer the newest backup we made.
    local init="$HOME/.hammerspoon/init.lua"
    if [ -f "$init" ] && grep -q 'require("voxtype")' "$init" 2>/dev/null; then
        local newest
        newest=$(ls -1t "$init".voxtype-backup.* 2>/dev/null | head -1)
        if [ -n "$newest" ]; then
            cp "$newest" "$init" && ok "restored your original init.lua from ${newest##*/}"
        elif [ -f "$init.voxtype-backup" ]; then
            mv "$init.voxtype-backup" "$init" && ok "restored your original init.lua"
        else
            # We created init.lua ourselves, so it should not survive as an
            # empty file.
            if [ "$(grep -cv 'require("voxtype")' "$init" 2>/dev/null | tr -d ' ')" = "0" ]; then
                rm -f "$init"
                ok "removed the init.lua this installer created"
            else
                grep -v 'require("voxtype")' "$init" > "$init.tmp" && mv "$init.tmp" "$init"
                ok "removed the require line from init.lua"
            fi
        fi
    fi

    # Reloading is enough to drop the hotkeys now that the module is gone, and it
    # is far less disruptive than quitting an app the user may rely on for other
    # things. Never do it headless: that is a real user's running Hammerspoon.
    if [ "${VOXTYPE_HEADLESS:-0}" = "1" ]; then
        info "headless: did not touch the running Hammerspoon"
    elif pgrep -x Hammerspoon >/dev/null 2>&1; then
        if osascript -e 'tell application "Hammerspoon" to reload' >/dev/null 2>&1; then
            ok "reloaded Hammerspoon to drop the hotkeys"
        else
            info "restart Hammerspoon to drop the hotkeys"
        fi
    fi

    if [ -x "$BIN_DIR/voxtype" ]; then
        rm -f "$BIN_DIR/voxtype"
        ok "removed $BIN_DIR/voxtype"
    fi
    rm -f "$(state_file)" "$(state_file).tmp.$$" 2>/dev/null

    cat <<EOF

voxtype is gone. These were left in place because other tools may use them:

  ~/.cache/whisperkit            the whisper model (about 1 GB)
  ollama list                     downloaded models (${REWRITE_MODEL} is about 2 GB)
  Hammerspoon itself

To remove the models too:

  ollama rm ${REWRITE_MODEL}
  rm -rf ~/.cache/whisperkit

To remove Hammerspoon:  brew uninstall --cask hammerspoon
EOF
}

# ---------------------------------------------------------------- main

main() {
    echo "smart-transcriber - local voice typing for macOS"
    [ "${DRY_RUN:-0}" = "1" ] && echo "${C_DIM}(dry run: nothing will be changed)${C_OFF}"

    if [ "$UNINSTALL" = "1" ]; then
        do_uninstall
        return 0
    fi

    acquire_lock

    step "checking this Mac"
    require_bash
    require_macos
    require_not_root
    require_arch
    require_python3
    check_network
    check_disk
    check_brew_voxtype
    check_existing_voxtype
    check_existing_module

    if [ "$DO_DEPS" = "1" ]; then
        step "dependencies"
        ensure_homebrew
        ensure_formula sox rec "sox"
        ensure_formula whisperkit-cli whisperkit-cli "whisperkit-cli"
    else
        warn "skipping dependency install (--no-deps)"
        local missing=""
        have rec || missing="$missing sox"
        have whisperkit-cli || missing="$missing whisperkit-cli"
        if [ -n "$missing" ]; then
            warn "missing:$missing - voxtype will not work until these are installed"
            info "install them with: brew install sox whisperkit-cli"
        fi
    fi

    install_binary

    local hotkeys=0
    if [ "$DO_HAMMERSPOON" = "1" ]; then
        if [ -d "/Applications/Hammerspoon.app" ] || [ "$DO_DEPS" = "1" ]; then
            setup_hammerspoon
            setup_login_item
            hotkeys=1
        else
            warn "skipping the hotkeys: Hammerspoon is not installed and --no-deps was given"
        fi
    else
        warn "skipping the hotkeys (--no-hammerspoon)"
        info "the CLI still works: run 'voxtype start', speak, then 'voxtype stop'"
    fi

    setup_ollama

    if [ "$DO_MODELS" = "1" ]; then
        step "whisper model"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            info "would run: voxtype warmup"
        else
            VOXTYPE_WHISPER_MODEL="$WHISPER_MODEL" "$BIN_DIR/voxtype" warmup \
                || warn "whisper warmup failed; run 'voxtype warmup' again later"
        fi
    else
        warn "skipping model downloads (--no-models)"
        info "run 'voxtype warmup' once you have the disk space"
    fi

    finish "$hotkeys"
}

finish() {
    local hotkeys="${1:-0}"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '\n%sThis was a dry run.%s Nothing was installed.\n' "$C_YLW" "$C_OFF"
        return 0
    fi

    printf '\n%svoxtype is installed.%s\n' "$C_GRN" "$C_OFF"

    if [ -n "$CHANGES" ]; then
        printf '\n%swhat changed%s\n' "$C_BLU" "$C_OFF"
        printf '%s' "$CHANGES" | while IFS= read -r line; do
            [ -n "$line" ] && printf '    - %s\n' "$line"
        done
    fi

    if [ "$WARN_COUNT" -gt 0 ]; then
        printf '\n%s%d warning%s to review%s (scroll up)\n' \
            "$C_YLW" "$WARN_COUNT" "$([ "$WARN_COUNT" = "1" ] || printf 's')" "$C_OFF"
    fi

    if [ "$hotkeys" = "1" ]; then
        cat <<'EOF'

One last step needs you, because macOS only lets a human grant permissions:

  1. System Settings > Privacy & Security > Microphone
     turn on Hammerspoon
  2. System Settings > Privacy & Security > Accessibility
     turn on Hammerspoon

Then:

  voxtype doctor

and dictate with:

  ctrl+opt+V            start and stop dictation
  ctrl+opt+delete       cancel
  ctrl+opt+R            start over
EOF
    else
        cat <<EOF

The hotkeys were not installed, so use the CLI directly:

  voxtype start     begin recording
  voxtype stop      transcribe, clean up, and print the text

To add the hotkeys later:  brew install --cask hammerspoon && voxtype install-hammerspoon
EOF
    fi

    cat <<'EOF'

Your first dictation is slower while the model loads. Nothing you say leaves
this Mac: transcription is on-device and the cleanup model is local.
EOF
}

main
