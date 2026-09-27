#!/bin/bash
# Install the voxtype binary, the Hammerspoon hotkey module, and the login item.
# Sourced by install.sh.

install_binary() {
    step "voxtype binary"

    local src="$REPO_ROOT/bin/voxtype"
    [ -f "$src" ] || die "missing $src"

    mkdir -p "$BIN_DIR" 2>/dev/null || die "cannot create $BIN_DIR"

    # A pre-existing binary here that we did not write is a surprise worth
    # backing up rather than silently replacing.
    if [ -f "$BIN_DIR/voxtype" ] && [ "$(state_get BIN_OWNED 2>/dev/null)" != "1" ]; then
        if ! grep -q 'VOXTYPE_VERSION' "$BIN_DIR/voxtype" 2>/dev/null; then
            local b; b=$(backup_file "$BIN_DIR/voxtype" || true)
            warn "replaced an unrecognised $BIN_DIR/voxtype${b:+ (kept as ${b##*/})}"
        fi
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -n "$detected_version" ]; then
            info "would install $src -> $BIN_DIR/voxtype (version $detected_version)"
        else
            info "would install $src -> $BIN_DIR/voxtype"
        fi
    else
        install -m 0755 "$src" "$BIN_DIR/voxtype" || die "could not write $BIN_DIR/voxtype"
        # Stamp the installed copy, not $src. Stamping the source edited the
        # repo checkout in place, so a second install inherited the first
        # install's version.
        stamp_version "$BIN_DIR/voxtype" "$detected_version"
        state_set BIN_OWNED 1
        state_set BIN_PATH "$BIN_DIR/voxtype"
        if [ -n "$detected_version" ]; then
            ok "$BIN_DIR/voxtype (version $detected_version)"
        else
            ok "$BIN_DIR/voxtype"
        fi
        note_change "installed $BIN_DIR/voxtype"
    fi

    # The Hammerspoon module has to live somewhere on disk, not just in this
    # repo, or 'voxtype install-hammerspoon' cannot work for a user who only has
    # the installed binary. That is the command the installer and the README both
    # tell people to run when they skipped the hotkeys.
    local share="$SHARE_DIR"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would install $REPO_ROOT/share/hammerspoon.lua -> $share/hammerspoon.lua"
    elif mkdir -p "$share" 2>/dev/null; then
        if install -m 0644 "$REPO_ROOT/share/hammerspoon.lua" "$share/hammerspoon.lua" 2>/dev/null; then
            state_set SHARE_OWNED 1
            state_set SHARE_PATH "$share/hammerspoon.lua"
            ok "$share/hammerspoon.lua"
        else
            warn "could not write $share/hammerspoon.lua"
            warn "'voxtype install-hammerspoon' will not work until the module is there"
        fi
    else
        warn "could not create $share"
    fi

    ensure_path_has_bin_dir
}

# A binary that is not on PATH is installed but unusable from the shell, which
# is a confusing half-success. Fix it or say clearly why not.
ensure_path_has_bin_dir() {
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            return 0 ;;
    esac

    printf '\n%snote%s\n' "$C_YLW" "$C_OFF"
    info "$BIN_DIR is not on your PATH, so 'voxtype' will not work in a new shell"
    info "until that is fixed."
    printf '\n'

    local rc="" cand
    for cand in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [ -f "$cand" ] && { rc="$cand"; break; }
    done
    if [ -z "$rc" ] && [ -f "$HOME/.zshrc" ]; then
        rc="$HOME/.zshrc"
    fi
    [ -n "$rc" ] || rc="$HOME/.zshrc"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would append to $rc:  export PATH=\"$BIN_DIR:\$PATH\""
        return 0
    fi

    if ! confirm "Add it to $rc now?" y; then
        info "skipped. Add this yourself when you want it:"
        info "  export PATH=\"$BIN_DIR:\$PATH\""
        note_change "left $BIN_DIR off your PATH (you declined)"
        return 0
    fi

    local block
    block=$(printf '\n# voxtype\nexport PATH="%s:$PATH"\n' "$BIN_DIR")
    if printf '%s' "$block" >> "$rc" 2>/dev/null; then
        ok "added $BIN_DIR to $rc"
        info "open a new terminal, or run:  source $rc"
        note_change "added $BIN_DIR to PATH in $rc"
    else
        warn "could not write $rc"
        info "add this yourself:  export PATH=\"$BIN_DIR:\$PATH\""
    fi
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
    note_change "installed the hotkey module in ~/.hammerspoon"

    # Without a GUI login session there is nothing to launch and nothing to wait
    # for. This is the normal case on a CI runner or over plain ssh.
    if [ "${VOXTYPE_HEADLESS:-0}" = "1" ]; then
        info "headless: not launching Hammerspoon"
        return 0
    fi

    # A fixed wait was not enough: the hotkeys were sometimes still dead seconds
    # after a fresh install. Wait for the module's own load marker instead.
    #
    # The previous run's marker has to go first, or a reinstall finds yesterday's
    # 'hotkeys loaded' already in the log, reports success instantly, and the
    # hotkeys are in fact still dead. Keep the old log as hs.log.1 for debugging.
    local marker="$HOME/.cache/voxtype/hs.log"
    if [ -f "$marker" ]; then
        mv -f "$marker" "$marker.1" 2>/dev/null || rm -f "$marker" 2>/dev/null
    fi

    if pgrep -x Hammerspoon >/dev/null 2>&1; then
        osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
    open -a Hammerspoon 2>/dev/null || warn "could not launch Hammerspoon"

    local loaded=0
    for _ in $(seq 1 30); do
        if [ -f "$marker" ] && grep -q 'hotkeys loaded' "$marker" 2>/dev/null; then
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
        warn "the hotkeys did not report as loaded"
        info "check $marker, then run: open -a Hammerspoon"
    fi
}

# Only ever delete the login item on uninstall if this installer created it.
# A login item the user added themselves is theirs to keep.
setup_login_item() {
    step "start on login"

    # Adding a login item needs a GUI session, so a headless run reports the
    # step the user still has to do rather than failing.
    if [ "${VOXTYPE_HEADLESS:-0}" = "1" ]; then
        warn "headless: skipped the login item"
        info "add it in System Settings > General > Login Items, or Hammerspoon"
        info "will need launching after every reboot."
        return 0
    fi

    if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
        | tr ',' '\n' | grep -q 'Hammerspoon'; then
        ok "Hammerspoon login item (already present)"
        state_set WE_MADE_LOGIN_ITEM 0
        return 0
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would add a Hammerspoon login item"
        return 0
    fi

    if osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Hammerspoon.app", hidden:true, name:"Hammerspoon"}' >/dev/null 2>&1; then
        state_set WE_MADE_LOGIN_ITEM 1
        ok "Hammerspoon will start on login"
        note_change "added a Hammerspoon login item"
    else
        warn "could not add the login item"
        info "add it in System Settings > General > Login Items, or voxtype will"
        info "need Hammerspoon running after every reboot."
    fi
}
