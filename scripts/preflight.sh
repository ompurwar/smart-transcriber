#!/bin/bash
# Preflight checks. Everything here runs before the installer changes anything,
# so a problem is reported while it is still cheap to walk away from.
# Sourced by install.sh.

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "voxtype only runs on macOS (found $(uname -s))"
    ok "macOS $(sw_vers -productVersion 2>/dev/null)"
}

# whisperkit-cli is published for Apple Silicon only, so an Intel Mac can never
# get a working install. Failing here beats failing later with a confusing error.
require_arch() {
    local arch; arch=$(uname -m)
    if [ "$arch" = "arm64" ]; then
        ok "Apple Silicon"
        return 0
    fi
    printf '\n%sunsupported%s\n' "$C_YLW" "$C_OFF"
    info "This Mac is $arch. whisperkit-cli, which does the transcription, is only"
    info "published for Apple Silicon, so voxtype cannot work here."
    info
    info "Alternatives:"
    info "  - Run voxtype on a Mac with Apple Silicon and dictate remotely"
    info "  - macOS built-in dictation: System Settings > Keyboard > Dictation"
    info "    (hold Control twice, or set a hotkey in Keyboard Shortcuts)"
    printf '\n'
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    exit 1
}

# macOS still ships bash 3.2 and some users pipe into it. Catch anything older
# than we have actually tested.
require_bash() {
    # ${BASH_VERSINFO[0]} is unset under sh/ksh/zsh, which is the case to catch.
    local major="${BASH_VERSINFO[0]:-}"
    if [ -z "$major" ]; then
        die "this installer must run under bash, not ${0##*/}. Use: bash install.sh"
    fi
    local v="$major.${BASH_VERSINFO[1]:-0}"
    if [ "$major" -lt 3 ]; then
        die "bash $v is too old. voxtype is tested on bash 3.2 and newer."
    fi
    ok "bash $v"
}

# Running under sudo moves HOME to /var/root, which silently installs
# everything for the wrong user.
require_not_root() {
    if is_root; then
        die "do not run this with sudo. It would install into /var/root instead of your account. Re-run without sudo; if a step needs your password it will ask for it."
    fi
    ok "running as $(id -un)"
}

# Homebrew's installer refuses to run as root for the same reason.
require_not_root_brew() {
    if is_root; then
        die "do not run this with sudo: homebrew refuses to install as root, and your files would land in /var/root."
    fi
}

check_network() {
    [ "${SKIP_NET_CHECK:-0}" = "1" ] && { warn "skipping the network check"; return 0; }
    if net_ok https://api.github.com/; then
        ok "network reachable"
        return 0
    fi
    die "cannot reach github.com. voxtype downloads Homebrew, dependencies and about 5.5 GB of models, so it needs a working connection. Re-run when you are online, or pass --no-deps --no-models to install only the script."
}

# The models are the biggest thing we download, so fail before starting rather
# than 20 minutes in. The default rewrite model is qwen2.5:1.5b at about 1 GB,
# plus the whisper model.
check_disk() {
    [ "${DO_MODELS:-1}" = "1" ] || return 0
    local need=3 avail
    avail=$(free_gb "$HOME")
    case "$avail" in
        ''|*[!0-9.]*) warn "could not determine free disk space; continuing"; return 0 ;;
    esac
    if awk "BEGIN{exit !($avail < $need)}"; then
        printf '\n%snot enough disk%s\n' "$C_YLW" "$C_OFF"
        info "voxtype needs about ${need} GB free for the models, and this disk has ${avail} GB."
        info
        info "Options:"
        info "  - free up space and re-run"
        info "  - install without the models now:  --no-models"
        info "    (then run 'voxtype warmup' later, once there is room)"
        info "  - skip the rewrite model entirely:  VOXTYPE_OLLAMA_MODEL= (falls back to the raw transcript)"
        printf '\n'
        [ "${DRY_RUN:-0}" = "1" ] && return 0
        exit 1
    fi
    ok "${avail} GB free"
}

require_python3() {
    if have python3; then
        ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
        return 0
    fi
    # Not fatal: the rewrite still works without the junk filter, it just falls
    # back to the raw transcript more often.
    warn "python3 not found; bad model output will not be filtered out"
    warn "install the command line tools with: xcode-select --install"
}

# ---------------------------------------------------------------- conflicts

# Report anything already on PATH named voxtype, so a fresh install does not
# quietly lose to an older copy.
check_existing_voxtype() {
    local target="$BIN_DIR/voxtype"
    local matches first
    matches=$(path_matches voxtype)
    [ -n "$matches" ] || return 0

    first=$(printf '%s\n' "$matches" | head -1)

    if [ "$first" = "$target" ]; then
        local have_ver want_ver
        have_ver=$("$first" version 2>/dev/null || echo unknown)
        want_ver=$(bash "$REPO_ROOT/bin/voxtype" version 2>/dev/null || echo unknown)
        if [ "$have_ver" = "$want_ver" ]; then
            ok "voxtype $have_ver already installed"
        else
            info "upgrading voxtype: installed $have_ver, installer has $want_ver"
        fi
        return 0
    fi

    printf '\n%sconflict%s\n' "$C_YLW" "$C_OFF"
    info "Another 'voxtype' already exists and comes first on your PATH:"
    info "  $first"
    if [ -f "$first" ] && "$first" version >/dev/null 2>&1; then
        info "  (version $("$first" version 2>/dev/null))"
    fi
    info
    info "Installing to $target would be shadowed by the copy above, so your"
    info "hotkeys and shell would keep using the old one."
    info
    info "Options:"
    info "  - remove the old copy first:   rm -f $first"
    info "  - install over the top:       --force"
    info "  - install alongside, and fix PATH yourself afterwards"
    printf '\n'
    if [ "${FORCE:-0}" != "1" ]; then
        [ "${DRY_RUN:-0}" = "1" ] && return 0
        exit 1
    fi
    warn "--force given, continuing anyway"
}

# A homebrew-managed voxtype should be updated with brew, not by this script.
check_brew_voxtype() {
    have_brew || return 0
    brew_cmd list --versions voxtype >/dev/null 2>&1 || return 0
    local v
    v=$(brew_cmd list --versions voxtype 2>/dev/null | awk '{print $2}')
    printf '\n%snote%s\n' "$C_YLW" "$C_OFF"
    info "voxtype ${v} is installed through Homebrew, at $(which_first voxtype 2>/dev/null)"
    info
    info "Homebrew owns that copy, so this installer will not replace it. Keep it"
    info "up to date with:  brew upgrade voxtype"
    info "Installing now to $BIN_DIR/voxtype gives you a second copy, and which one"
    info "wins depends on your PATH."
    info
    info "To use the Homebrew copy exclusively, re-run with:  --no-deps --no-hammerspoon"
    info "and then run 'brew install --cask hammerspoon' and 'voxtype install-hammerspoon'."
    printf '\n'
    note_change "left the Homebrew-managed voxtype ${v} in place"
}

# Overwriting a Hammerspoon module that we did not write would lose someone's
# edits, so surface it first.
check_existing_module() {
    local module="$HOME/.hammerspoon/voxtype.lua"
    [ -f "$module" ] || return 0
    local recorded; recorded=$(state_get MODULE_OWNED 2>/dev/null)
    if [ "$recorded" = "1" ]; then
        return 0
    fi
    if cmp -s "$module" "$REPO_ROOT/share/hammerspoon.lua" 2>/dev/null; then
        return 0
    fi
    # A rendered module always points at an absolute path, so compare loosely.
    if grep -q 'VOXTYPE_BIN' "$module" 2>/dev/null; then
        return 0
    fi
    printf '\n%snote%s\n' "$C_YLW" "$C_OFF"
    info "$HOME/.hammerspoon/voxtype.lua already exists and was not written by this"
    info "installer. It will be replaced, and the old one kept as:"
    info "  $module.voxtype-backup.<timestamp>"
    printf '\n'
    note_change "replaced an existing ~/.hammerspoon/voxtype.lua"
}
