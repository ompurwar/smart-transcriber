#!/bin/bash
# Shared helpers for the smart-transcriber installer.
# Sourced by install.sh, never executed directly.
#
# Everything here has to run under the bash 3.2 that ships with macOS, so:
# no associative arrays, no mapfile, no ${var^^}.

[ -n "${_ST_LIB:-}" ] && return 0
_ST_LIB=1

# ---------------------------------------------------------------- output

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
warn()  { WARN_COUNT=$((WARN_COUNT + 1)); printf '    %swarn%s  %s\n' "$C_YLW" "$C_OFF" "$*"; }
die()   { printf '\n%serror%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }
have_brew() { have brew || [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; }

# Record something the installer did, so the summary can list real changes
# instead of making the user guess.
note_change() { CHANGES="${CHANGES}${1}
"; }

# ---------------------------------------------------------------- state

# A tiny KEY=VALUE file recording what this installer owns. Uninstall uses it to
# avoid deleting things the user created themselves.
state_file() { printf '%s' "${VOXTYPE_INSTALL_STATE:-${VOXTYPE_STATE_DIR:-$HOME/.cache/voxtype}/install-state}"; }

state_set() {
    local f; f=$(state_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null
    local tmp="$f.tmp.$$"
    [ -f "$f" ] && grep -v "^$1=" "$f" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    mv "$tmp" "$f" 2>/dev/null
}

state_get() {
    local f; f=$(state_file)
    [ -f "$f" ] || return 1
    grep "^$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
}

# A single fixed .voxtype-backup gets clobbered by a second install, so keep
# timestamped copies and never overwrite one.
backup_file() {
    local src="$1"
    [ -f "$src" ] || return 1
    local dest
    dest="$src.voxtype-backup.$(date +%Y%m%d%H%M%S)"
    cp -p "$src" "$dest" 2>/dev/null && printf '%s' "$dest"
}

# ---------------------------------------------------------------- prompts

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# confirm <question> [default: y|n]. Non-interactive runs take the default and
# say so, rather than hanging forever on a pipe.
confirm() {
    local q="$1" def="${2:-y}" hint reply
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        info "$q (assumed yes)"
        return 0
    fi
    if ! is_tty; then
        [ "$def" = "y" ] && return 0 || return 1
    fi
    if [ "$def" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '    %s %s ' "$q" "$hint"
    read -r reply || reply=""
    case "$reply" in
        [yY]*) return 0 ;;
        "")   [ "$def" = "y" ] ;;
        *)    return 1 ;;
    esac
}

# ---------------------------------------------------------------- checks

is_root() { [ "$(id -u)" = "0" ]; }

# Free space in GiB on the filesystem holding a path.
free_gb() {
    local p="${1:-$HOME}"
    df -Pk "$p" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1048576}'
}

# A cheap reachability test for the things we are about to download from.
#
# Any HTTP status counts as reachable, including 403. A 403 from api.github.com
# is what a rate-limited, proxied or authenticated-only network looks like, and
# it proves the network is fine. Only a DNS failure, refused connection or
# timeout is offline, and those all report 000.
net_ok() {
    local code
    code=$(curl -sS -o /dev/null --max-time 8 -w '%{http_code}' "$1" 2>/dev/null)
    case "$code" in
        [1-5][0-9][0-9]) return 0 ;;
        *)                return 1 ;;
    esac
}

# Every copy of a command on PATH, so we can tell the user which one wins.
path_matches() {
    local name="$1" d
    local IFS=:
    for d in $PATH; do
        [ -n "$d" ] || continue
        [ -x "$d/$name" ] && printf '%s\n' "$d/$name"
    done
}

# The copy of a command that actually runs, resolved through PATH.
which_first() { command -v "$1" 2>/dev/null; }

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

# ---------------------------------------------------------------- single run

# Two concurrent installs would fight over the same files, so take an atomic
# lock. A stale lock from a killed run is reclaimed after an hour.
acquire_lock() {
    local lock="${VOXTYPE_STATE_DIR:-$HOME/.cache/voxtype}/install.lock"
    mkdir -p "$(dirname "$lock")" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then
        date +%s > "$lock/pid" 2>/dev/null
        LOCK_DIR="$lock"
        trap 'release_lock' EXIT INT TERM
        return 0
    fi
    local age now
    now=$(date +%s)
    age=$(( now - $(cat "$lock/pid" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 3600 ]; then
        rm -rf "$lock"
        mkdir "$lock" 2>/dev/null && { date +%s > "$lock/pid"; LOCK_DIR="$lock"; trap 'release_lock' EXIT INT TERM; return 0; }
    fi
    die "another install is already running (lock: $lock). If that is wrong, remove it and retry."
}

release_lock() { [ -n "${LOCK_DIR:-}" ] && rm -rf "$LOCK_DIR"; }

# ---------------------------------------------------------------- brew

ensure_homebrew() {
    if have_brew; then
        ok "homebrew $(brew_cmd --version 2>/dev/null | head -1 | awk '{print $2}')"
        return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would install homebrew"
        return 0
    fi
    if ! net_ok https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh; then
        die "homebrew is missing and GitHub is unreachable. Connect to a network and retry."
    fi
    info "installing homebrew (this can take a few minutes)…"
    if ! NONINTERACTIVE="${NONINTERACTIVE:-}" /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        die "homebrew install failed"
    fi
    for p in /opt/homebrew/bin /usr/local/bin; do
        case ":$PATH:" in *":$p:"*) ;; *) export PATH="$p:$PATH" ;; esac
    done
    have_brew || die "homebrew installed but not on PATH - open a new terminal and re-run"
    ok "homebrew"
}

# Install a formula, but only when the command it provides is missing.
# ensure_formula <formula> <provides> [label]
ensure_formula() {
    local formula="$1" provides="$2" label="${3:-$1}"
    shift 2
    [ -n "$label" ] || label="$formula"
    if have "$provides"; then
        ok "$label (already installed)"
        return 0
    fi
    info "installing ${label}…"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: brew install $formula"
        return 0
    fi
    if ! brew_cmd install "$formula" "$@"; then
        die "brew could not install $formula. Install it manually with: brew install $formula"
    fi
    ok "$label"
}

ensure_cask() {
    local cask="$1"
    if [ -d "/Applications/${cask}.app" ]; then
        ok "$cask (already installed)"
        return 0
    fi
    info "installing ${cask}…"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: brew install --cask $cask"
        return 0
    fi
    # A cask that needs an admin password cannot be installed from a pipe.
    if ! brew_cmd install --cask "$cask"; then
        if [ -t 0 ]; then
            die "brew could not install the $cask cask. Install it manually with: brew install --cask $cask"
        fi
        die "brew could not install the $cask cask. Some casks need an admin password, which a piped install cannot supply. Run: brew install --cask $cask"
    fi
    ok "$cask"
}
