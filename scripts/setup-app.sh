#!/bin/bash
# Install the voxtype binary, the Hammerspoon hotkey module, and the login item.
# Sourced by install.sh.

install_binary() {
    step "voxtype binary"

    local src="$REPO_ROOT/bin/voxtype"
    [ -f "$src" ] || die "missing $src"

    mkdir -p "$BIN_DIR"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would install $src -> $BIN_DIR/voxtype"
    else
        install -m 0755 "$src" "$BIN_DIR/voxtype"
        ok "$BIN_DIR/voxtype"
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            warn "$BIN_DIR is not on your PATH"
            _profile="$HOME/.zshrc"
            [ -f "$HOME/.bash_profile" ] && ! [ -f "$HOME/.zshrc" ] && _profile="$HOME/.bash_profile"
            if [ "${DRY_RUN:-0}" = "1" ]; then
                info "would add this to $_profile:"
            else
                printf '\n# voxtype\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$_profile"
            fi
            info 'export PATH="'"$BIN_DIR"':$PATH"'
            ;;
    esac
}

setup_hammerspoon() {
    step "Hammerspoon hotkeys"

    if [ ! -d "/Applications/Hammerspoon.app" ]; then
        ensure_cask hammerspoon
    else
        ok "hammerspoon (already installed)"
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: voxtype install-hammerspoon"
        return 0
    fi

    VOXTYPE_SHARE_DIR="$REPO_ROOT/share" "$BIN_DIR/voxtype" install-hammerspoon \
        || die "could not install the hotkey config"

    ok "hotkeys installed"

    # Make sure Hammerspoon is up and has reloaded the new config. A fixed sleep
    # here was not enough: the hotkeys were sometimes still dead seconds after a
    # fresh install, so wait for the module's own load marker instead.
    if pgrep -x Hammerspoon >/dev/null 2>&1; then
        osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
    open -a Hammerspoon 2>/dev/null || warn "could not launch Hammerspoon"

    local marker="$HOME/.cache/voxtype/hs.log"
    local loaded=0
    for _ in $(seq 1 30); do
        if [ -f "$marker" ] && grep -aq 'hotkeys loaded' "$marker" 2>/dev/null; then
            loaded=1
            break
        fi
        sleep 1
    done

    if pgrep -x Hammerspoon >/dev/null 2>&1; then
        ok "hammerspoon running"
    else
        warn "hammerspoon is not running. Launch it from Spotlight."
    fi

    if [ "$loaded" = "1" ]; then
        ok "ctrl+opt+V is live"
    else
        warn "the hotkeys did not report as loaded. Check $marker, then open -a Hammerspoon."
    fi
}

setup_login_item() {
    step "start on login"

    if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
        | tr ',' '\n' | grep -q 'Hammerspoon'; then
        ok "Hammerspoon login item (already present)"
        return 0
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would add a Hammerspoon login item"
        return 0
    fi

    if osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Hammerspoon.app", hidden:true, name:"Hammerspoon"}' >/dev/null 2>&1; then
        ok "Hammerspoon will start on login"
    else
        warn "could not add the login item. Add Hammerspoon in System Settings > General > Login Items."
    fi
}
