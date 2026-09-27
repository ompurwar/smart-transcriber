#!/bin/bash
# Start the Ollama app if it is installed but not running, and pull the rewrite
# model. Sourced by install.sh.

setup_ollama() {
    step "Ollama (local rewrite model)"

    if ! have ollama; then
        # The cask ships the app; the CLI lives inside it.
        if [ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]; then
            export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
        else
            ensure_cask ollama
        fi
    fi

    if have ollama; then
        ok "ollama $(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    elif [ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]; then
        export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
        ok "ollama (from Ollama.app)"
    else
        die "could not find the ollama CLI"
    fi

    if ollama list >/dev/null 2>&1; then
        ok "ollama is running"
    else
        info "starting the Ollama app…"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            info "would run: open -a Ollama"
        else
            open -a Ollama 2>/dev/null || warn "could not launch Ollama.app automatically"
            for _ in $(seq 1 20); do
                ollama list >/dev/null 2>&1 && break
                sleep 1
            done
        fi
        if ollama list >/dev/null 2>&1; then
            ok "ollama is running"
        else
            warn "ollama is not answering. Open Ollama.app manually, then re-run voxtype doctor."
        fi
    fi

    if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$REWRITE_MODEL"; then
        ok "model '$REWRITE_MODEL' (already pulled)"
        return 0
    fi

    info "pulling '$REWRITE_MODEL' (about 2 GB, one time)…"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "would run: ollama pull $REWRITE_MODEL"
        return 0
    fi
    if ollama pull "$REWRITE_MODEL"; then
        ok "model '$REWRITE_MODEL'"
    else
        warn "could not pull '$REWRITE_MODEL'. Run 'ollama pull $REWRITE_MODEL' later."
    fi
}
