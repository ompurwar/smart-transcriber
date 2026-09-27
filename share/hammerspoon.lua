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

-- Bind every hotkey, then say so honestly.
--
-- An earlier version called hs.hotkey.bind and wrote a 'hotkeys loaded' marker
-- straight afterwards, unconditionally. The installer and `voxtype doctor` both
-- treat that marker as proof the hotkeys are live, so a bind that silently
-- failed still produced a confident all-clear. Bind failures are now counted,
-- logged with the key that failed, and the marker only claims success when
-- every hotkey really is bound.
local BINDS = {
  { mods = { "ctrl", "alt" }, key = "v",      arg = "hotkey"  },
  { mods = { "ctrl", "alt" }, key = "delete", arg = "cancel"  },
  { mods = { "ctrl", "alt" }, key = "r",      arg = "restart" },
}

local bound, failed = 0, {}
for _, b in ipairs(BINDS) do
  -- pcall, because a bad key name raises rather than returning nil, and an
  -- uncaught error here would abort the rest of the config.
  local ok, hk = pcall(hs.hotkey.bind, b.mods, b.key, function() fire(b.arg) end)
  if ok and hk then
    hk:enable()
    bound = bound + 1
  else
    local why = ok and "no hotkey object" or tostring(hk)
    log.e(string.format("could not bind ctrl+opt+%s: %s", b.key, why))
    table.insert(failed, b.key)
  end
end

if bound == #BINDS then
  log.i(string.format("loaded - ctrl+opt+V dictation, ctrl+opt+delete cancel, ctrl+opt+R restart (%d/%d bound)", bound, #BINDS))
else
  log.e(string.format("loaded with problems - only %d/%d hotkeys bound (failed: %s)",
    bound, #BINDS, table.concat(failed, ", ")))
end

-- The marker the installer waits for and `voxtype doctor` reports on. It is
-- only written when every hotkey is really bound, so a false all-clear is not
-- possible.
do
  local f = io.open(LOG, "a")
  if f then
    if bound == #BINDS then
      f:write(string.format("=== hotkeys loaded %s (%d/%d) ===\n",
        os.date("%Y-%m-%dT%H:%M:%S"), bound, #BINDS))
    else
      f:write(string.format("=== hotkeys PARTIAL %s (%d/%d) ===\n",
        os.date("%Y-%m-%dT%H:%M:%S"), bound, #BINDS))
    end
    f:close()
  end
end
