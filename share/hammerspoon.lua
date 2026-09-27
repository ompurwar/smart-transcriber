-- smart-transcriber / voxtype hotkeys
--
-- Loaded from ~/.hammerspoon/init.lua via:  require("voxtype")
--
-- The dictation pipeline runs as a detached shell process and talks back
-- through the clipboard, so Hammerspoon never blocks. (hs.task in this build
-- neither forwards arguments nor captures stdout.)
--
-- Do NOT add explicit require() calls below. This build lazy-loads extensions,
-- and an explicit require("hs.execute") hangs the config load forever.

local HOME = os.getenv("HOME") or ""
local VOXTYPE = os.getenv("VOXTYPE_BIN") or (HOME .. "/.local/bin/voxtype")
local LOG = HOME .. "/.cache/voxtype/hs.log"

local log = hs.logger.new("voxtype", "info")

-- Fire and forget. The trailing & lets the shell return immediately, so even
-- hs.execute's short timeout is never reached.
local function fire(arg)
  hs.execute(string.format("%s %s >>%s 2>&1 &", VOXTYPE, arg, LOG), true, 1)
end

-- ctrl+opt+V - start / stop dictation
hs.hotkey.bind({ "ctrl", "alt" }, "V", function() fire("hotkey") end)

-- ctrl+opt+delete - throw away the current recording
hs.hotkey.bind({ "ctrl", "alt" }, "delete", function() fire("cancel") end)

-- ctrl+opt+R - cancel, then start listening again
hs.hotkey.bind({ "ctrl", "alt" }, "R", function() fire("restart") end)

log.i("loaded - ctrl+opt+V dictation, ctrl+opt+delete cancel, ctrl+opt+R restart")

-- Leave a timestamped marker so the installer can wait for the hotkeys to be
-- genuinely live, and `voxtype doctor` can tell "Hammerspoon is running" apart
-- from "the hotkeys actually loaded".
do
  local f = io.open(LOG, "a")
  if f then
    f:write(string.format("=== hotkeys loaded %s ===\n", os.date("%Y-%m-%dT%H:%M:%S")))
    f:close()
  end
end
