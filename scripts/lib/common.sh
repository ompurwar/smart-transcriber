#!/bin/bash
# Shared helpers for the smart-transcriber installer.
# Sourced by install.sh, never executed directly.

[ -n "${_ST_LIB:-}" ] && return 0
_ST_LIB=1

# C_DIM is consumed by install.sh, which shellcheck cannot see across files.
# shellcheck disable=SC2034
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

step()  { printf '\n%s==>%s %s%s\n' "$C_BLU" "$C_OFF" "$C_BLU" "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %sgood%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '    %swarn%s  %s\n' "$C_YLW" "$C_OFF" "$*"; }
die()   { printf '\n%serror%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }
have_brew() { have brew || [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; }

# Run a command unless --dry-run is set. Keeps the installer's blast radius
# small when someone wants to preview it.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: $*"
    else
        "$@"
    fi
}

brew_cmd() {
    if [ -x /opt/homebrew/bin/brew ]; then
        /opt/homebrew/bin/brew "$@"
    else
        brew "$@"
    fi
}

# Install a formula, but only when the command it provides is missing.
# ensure_formula <formula> <provides> [label]
ensure_formula() {
    local formula="$1" provides="$2" label="${3:-$1}"
    shift 2 2>/dev/null
    [ -n "$label" ] || label="$formula"
    if have "$provides"; then
        ok "$label (already installed)"
        return 0
    fi
    info "installing $formula…"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: brew install $formula"
        return 0
    fi
    if ! brew_cmd install "$formula" "$@"; then
        die "brew could not install $formula"
    fi
    ok "$label"
}

ensure_cask() {
    local cask="$1"
    if [ -d "/Applications/${cask}.app" ]; then
        ok "$cask (already installed)"
        return 0
    fi
    info "installing $cask…"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: brew install --cask $cask"
        return 0
    fi
    if ! brew_cmd install --cask "$cask"; then
        die "brew could not install the $cask cask"
    fi
    ok "$cask"
}

ensure_homebrew() {
    have_brew && { ok "homebrew $(brew_cmd --version 2>/dev/null | head -1 | awk '{print $2}')"; return 0; }
    [ "${DRY_RUN:-0}" = "1" ] && { info "would install homebrew"; return 0; }
    info "installing homebrew (this opens no window, it just runs the script)…"
    if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        die "homebrew install failed"
    fi
    for p in /opt/homebrew/bin /usr/local/bin; do
        case ":$PATH:" in *":$p:"*) ;; *) export PATH="$p:$PATH" ;; esac
    done
    have_brew || die "homebrew installed but not on PATH - open a new terminal and re-run"
    ok "homebrew"
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "voxtype only runs on macOS"
    ok "macOS $(sw_vers -productVersion 2>/dev/null)"
}

# whisperkit-cli is published for Apple Silicon only, so an Intel Mac can never
# get a working install. Failing here beats failing later with a confusing error.
require_arch() {
    local arch
    arch=$(uname -m)
    [ "$arch" = "arm64" ] && { ok "Apple Silicon"; return 0; }
    warn "this Mac is $arch. whisperkit-cli only ships for Apple Silicon."
    warn "voxtype will not work here. See docs/LIMITATIONS.md."
    if [ "${DRY_RUN:-0}" = "1" ]; then return 0; fi
    exit 1
}
