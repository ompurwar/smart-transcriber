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

-- ------------------------------------------------------------------ overlay
--
-- A waveform and stage pill at the bottom centre of the screen, shown only while
-- a dictation is in flight, so it never sits on top of a click the user needs.
--
-- voxtype publishes its stage to ui.state and this polls it. The pill is drawn
-- with the element API (appendElements), because this build of Hammerspoon has
-- no rectangle()/fillColor() drawing methods and no hs.window.new().
do
    local built, build_err = pcall(function()
    local UI_STATE = HOME .. "/.cache/voxtype/ui.state"

    -- The Hammerspoon console is the only place log.e goes, and nobody has it
    -- open, so overlay failures are appended to the same log file the installer
    -- already uses. A broken overlay should explain itself in a file the user
    -- can read.
    local function dlog(fmt, ...)
      local f = io.open(LOG, "a")
      if not f then return end
      if select("#", ...) > 0 then fmt = string.format(fmt, ...) end
      f:write(string.format("%s %s\n", os.date("%Y-%m-%dT%H:%M:%S"), fmt))
      f:close()
    end
    local reported = false


    -- Overrides, so the overlay can be resized without editing this file and
    -- reinstalling. Read from the environment first, then from an optional
    -- conf file, because Hammerspoon is launched by launchd and picking up a
    -- new environment means a logout, not just a restart.
    --
    --   VOXTYPE_PILL_W   pill width                (default 360)
    --   VOXTYPE_PILL_H   pill height               (default 52)
    --   VOXTYPE_PILL_R   corner radius             (default half the height)
    --   VOXTYPE_WAVE_H   tallest waveform bar      (default 36)
    --   VOXTYPE_BARS     number of bars            (default 24)
    --   VOXTYPE_TEXT_DY  nudge label and clock     (default -3)
    local OVERRIDE_FILE = HOME .. "/.cache/voxtype/overlay.conf"
    local overrides = {}
    do
      local f = io.open(OVERRIDE_FILE, "r")
      if f then
        for line in f:lines() do
          -- the value may be negative: the text nudge is a correction and
          -- -3 is its normal setting
          local k, v = line:match("^%s*(VOXTYPE_[%w_]+)%s*=%s*(-?[%d.]+)%s*$")
          if k then overrides[k] = tonumber(v) end
        end
        f:close()
      end
    end
    local function num(name, default)
      local v = tonumber(os.getenv(name))
      if not v then v = overrides[name] end
      if v and v > 0 then return v end
      return default
    end
    -- For a setting that is a correction rather than a measurement, so zero and
    -- negative are perfectly good values and must not be thrown away the way
    -- num() throws them away for a size.
    local function snum(name, default)
      local v = tonumber(os.getenv(name))
      if not v then v = overrides[name] end
      if v then return v end
      return default
    end

    -- A wide, short pill with the waveform given the full height of it. The
    -- first attempt stacked a label above the waveform inside a tall pill, which
    -- wasted vertical space and left the bars looking stubby.
    local PILL_W = num("VOXTYPE_PILL_W", 360)
    local PILL_H = num("VOXTYPE_PILL_H", 52)
    local PILL_R = num("VOXTYPE_PILL_R", PILL_H / 2)
    local MAX_H  = num("VOXTYPE_WAVE_H", 36)
    local BARS   = math.floor(num("VOXTYPE_BARS", 24))
    local LABEL_SZ, CLOCK_SZ = 13, 12
    -- The inset at each end of the pill. The dot starts after the left one and
    -- the clock, being right aligned, finishes before the right one. They are
    -- separate settings because they do not want the same value: the clock has
    -- the waveform running up to it, so a little more air on the dot's side looks
    -- even while the same number on the clock's side looks tight.
    local PAD_L = num("VOXTYPE_PAD_L", 26)
    local PAD_R = num("VOXTYPE_PAD_R", 20)
    local DOT_X, DOT_R = PAD_L, 4.5
    -- The widest label is "nothing heard" at about 84px; the old 112 reserved
    -- space for "on your clipboard", which is now the shorter "copied". The
    -- width saved here is given to the waveform, which is the part worth
    -- looking at.
    local LABEL_X, LABEL_W = PAD_L + 12, 98
    local WAV_X = 140
    local TIME_W = 34
    local TIME_X = PILL_W - PAD_R - TIME_W
    local WAV_W = TIME_X - WAV_X - 10

    local CY = PILL_H / 2
    local BAR_MS = 16      -- of audio behind each bar, so the bars trace the
                           -- shape of speech instead of flickering sample to
                           -- sample, which just reads as a shimmer
    local TICK = 1 / 12      -- seconds between repaints
    local STALE_AFTER = 45   -- hide if a stage has not been refreshed by now
    local DONE_FOR = 1.0     -- how long "pasted" stays up
    -- Centring text on the pill is done by measurement, not by a fraction of the
    -- point size: where the glyphs land inside a frame depends on the font's
    -- ascender and on which characters are present, and a guess left the label
    -- sitting below the stage dot.
    --
    -- The numbers baked in here were read back off a rendered canvas: the text
    -- is drawn onto a black canvas at a known frame, the canvas is snapshotted
    -- with hs.canvas:imageFromCanvas(), and the rows containing glyph pixels give
    -- the real centre. There is no vertical alignment attribute in this build of
    -- Hammerspoon, and hs.drawing.textSize does not exist in it either, so
    -- measuring the pixels is the only way to know.
    --
    --   "recording" 13 system font, frame 15.2..30.8 -> glyphs 18..30, centre 24.0
    --   "0:00"      12 system font, frame 15.8..30.2 -> glyphs 19..28, centre 23.5
    --   "0:00"      12 Menlo,       frame 15.8..30.2 -> glyphs 17..27, centre 22.0
    --
    -- CY was 26, so the system font needs +2 and Menlo needs +4. TEXT_DY carries
    -- the first as a default (-1, because CY - size*0.6 is already +2 from here),
    -- and Menlo's extra 2 is CLOCK_DY.
    local TEXT_DY = snum("VOXTYPE_TEXT_DY", -1)
    local CLOCK_DY = 2.0
    local function text_frame(x, w, size, text, dy)
      local box = size * 1.2
      return { x = x, y = CY - box / 2 + (dy or TEXT_DY), w = w, h = box }
    end

    local STAGE = {
      recording     = { label = "recording",    dot = { red = 1.00, green = 0.30, blue = 0.34, alpha = 1 } },
      transcribing  = { label = "transcribing", dot = { red = 1.00, green = 0.72, blue = 0.26, alpha = 1 } },
      polishing     = { label = "polishing",    dot = { red = 0.42, green = 0.66, blue = 1.00, alpha = 1 } },
      done          = { label = "pasted",       dot = { red = 0.36, green = 0.90, blue = 0.56, alpha = 1 } },
      empty         = { label = "nothing heard", dot = { red = 0.70, green = 0.72, blue = 0.78, alpha = 1 } },
      cancelled     = { label = "cancelled",    dot = { red = 0.70, green = 0.72, blue = 0.78, alpha = 1 } },
      blocked       = { label = "copied", dot = { red = 1.00, green = 0.78, blue = 0.35, alpha = 1 } },
    }

    -- ------------------------------------------------------- reading the wav
    --
    -- sox writes 32-bit signed mono PCM at 48kHz through WAVE_FORMAT_EXTENSIBLE,
    -- so the samples do not start at the usual byte 44 and are not 16-bit. The
    -- header is parsed for the data offset, width and channel count rather than
    -- assumed, because a different sox or input device changes all three.
    local hdr_cache = { path = nil }

    local function parse_header(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local head = f:read(256)
      f:close()
      if not head or #head < 48 then return nil end

      local p = head:find("data", 13, true)
      if not p or p + 8 > #head then return nil end

      local bits = head:byte(35) + head:byte(36) * 256
      local chans = head:byte(23) + head:byte(24) * 256
      local rate = head:byte(25) + head:byte(26) * 256 +
                   head:byte(27) * 65536 + head:byte(28) * 16777216
      if not bits or bits <= 0 then return nil end

      return {
        off  = p + 8,          -- first data byte, as a 1-based string index
        bps  = bits / 8,
        ch   = (chans and chans > 0) and chans or 1,
        rate = (rate and rate > 0) and rate or 48000,
      }
    end

    local function header_for(path)
      if hdr_cache.path ~= path then
        hdr_cache.path = path
        hdr_cache.hdr = parse_header(path)
      end
      return hdr_cache.hdr
    end

    -- Peak amplitude of one sample, normalised to 0..1.
    local function sample_peak(blob, i, bps)
      if bps == 4 then
        local a, b, c, d = blob:byte(i, i + 3)
        if not d then return 0 end
        local u = a + b * 256 + c * 65536 + d * 16777216
        if u >= 2147483648 then u = 4294967296 - u end
        return u / 2147483648
      elseif bps == 2 then
        local a, b = blob:byte(i, i + 1)
        if not b then return 0 end
        local u = a + b * 256
        if u >= 32768 then u = 65536 - u end
        return u / 32768
      end
      return 0
    end

    -- Newest audio last: bar 0 is the most recent slice, and the renderer lays
    -- them out right to left. Each bar covers a slice of wall-clock time, not a
    -- fixed handful of samples: six samples at 48kHz is an eighth of a
    -- millisecond per bar, so the bars were all showing the same instant of
    -- noise and the whole thing read as a shimmer instead of a waveform.
    local function read_levels(path)
      local h = header_for(path)
      if not h or h.bps ~= 4 and h.bps ~= 2 then return nil end

      local per_bar = math.max(1, math.floor(h.rate * BAR_MS / 1000))
      local f = io.open(path, "rb")
      if not f then return nil end
      local size = f:seek("end")
      local want = BARS * per_bar * h.bps * h.ch
      local start = math.max(h.off - 1, size - want)
      if start >= size - 1 then f:close() return nil end
      f:seek("set", start)
      local blob = f:read(size - start)
      f:close()
      if not blob or #blob < h.bps * 2 then return nil end

      local out = {}
      for bar = 0, BARS - 1 do
        local peak = 0
        for s = 0, per_bar - 1 do
          local k = bar * per_bar + s
          local first = #blob - (k + 1) * h.bps * h.ch + 1
          if first >= 1 then
            local v = sample_peak(blob, first, h.bps)
            if v > peak then peak = v end
          end
        end
        out[bar] = peak
      end
      return out
    end

    -- A quiet microphone would otherwise render a flat line, so the scale
    -- follows the loudest recent sound and decays slowly back down.
    local gain = 0.05
    local function auto_gain(levels)
      local loudest = 0
      for _, v in ipairs(levels) do
        if v > loudest then loudest = v end
      end
      if loudest > gain then gain = loudest end
      gain = gain * 0.995
      if gain < 0.02 then gain = 0.02 end
    end

    -- This has to be here rather than inside render: auto_gain only decides the
    -- scale, and if the levels are handed on unscaled then the bars keep their
    -- raw amplitude, which for normal speech is a couple of percent and looks
    -- like a row of identical stubs no matter how the gain is set.
    local function scaled(levels)
      local out = {}
      for i, v in ipairs(levels) do
        out[i] = math.min(1, v / gain)
      end
      return out
    end

    -- -------------------------------------------------------------- drawing
    local canvas = nil
    local shown = false
    -- Wall-clock accumulator for the animation, in seconds. It has to be counted
    -- up rather than taken from os.time() because that only has one-second
    -- resolution, and a whole tick of it would be visible as a stutter.
    local anim = 0

    local function place()
      local s = hs.screen.mainScreen():frame()
      local x = s.x + math.floor((s.w - PILL_W) / 2)
      local y = s.y + s.h - PILL_H - 46
      return x, y
    end

    local function ensure_canvas()
      if canvas then return canvas end
      local x, y = place()
      local c = hs.canvas.new({ x = x, y = y, w = PILL_W, h = PILL_H })
      local B = hs.canvas.windowBehaviors
      c:behavior((B.canJoinAllSpaces or 1) + (B.ignoresCycle or 64) +
                 (B.stationary or 16) + (B.transient or 8) +
                 (B.fullScreenAuxiliary or 256))
      -- screenSaver level is used deliberately: in this build the window sat
      -- behind ordinary app windows at the 'overlay' level, and a pill you
      -- cannot see is worse than one that briefly floats above everything.
      c:level(hs.canvas.windowLevels.screenSaver)
      c:alpha(1.0)
      canvas = c
      return c
    end

    local function bar_elements(cx, cy, max_h, pitch, width, colour, value, floor)
      local h = floor + value * (max_h - floor)
      return {
        type = "rectangle", action = "fill", fillColor = colour,
        frame = { x = cx, y = cy - h / 2, w = width, h = h },
        roundedRectRadii = { xRadius = width / 2, yRadius = width / 2 },
      }
    end

    local function render(stage, levels, elapsed)
      local c = ensure_canvas()
      local spec = STAGE[stage] or STAGE.cancelled
      local els = {}

      els[#els + 1] = {
        type = "rectangle", action = "fill",
        fillColor = { red = 0.09, green = 0.09, blue = 0.11, alpha = 0.93 },
        frame = { x = 0, y = 0, w = PILL_W, h = PILL_H },
        roundedRectRadii = { xRadius = PILL_R, yRadius = PILL_R },
        -- A shadow is what keeps the pill legible over a light desktop. Without
        -- it the dark pill sits directly on the background and the edge is the
        -- only thing separating them.
        withShadow = true,
        shadow = { blurRadius = 14, color = { alpha = 0.38 },
                   offset = { h = 0, w = 0 } },
      }
      els[#els + 1] = {
        type = "rectangle", action = "stroke",
        strokeColor = { white = 1.0, alpha = 0.10 },
        strokeWidth = 1,
        frame = { x = 0.5, y = 0.5, w = PILL_W - 1, h = PILL_H - 1 },
        -- the fill is half a pixel taller than this one, so the outline needs
        -- half a pixel less radius or the two silhouettes do not line up and
        -- the ends stop looking fully rounded
        roundedRectRadii = { xRadius = PILL_R - 0.5, yRadius = PILL_R - 0.5 },
      }

      -- stage dot, label, and the elapsed clock, laid out left to right.
      --
      -- While recording the dot breathes. It is the only moving thing on a stage
      -- whose waveform is stopped (silence still draws short bars), so it is
      -- what tells you the microphone is actually live rather than the overlay
      -- being stuck on screen.
      local dot_r = DOT_R
      if stage == "recording" then
        dot_r = DOT_R * (1 + 0.22 * math.sin(anim * 4.2))
      end
      els[#els + 1] = {
        type = "rectangle", action = "fill", fillColor = spec.dot,
        frame = { x = DOT_X, y = CY - dot_r, w = dot_r * 2, h = dot_r * 2 },
        roundedRectRadii = { xRadius = dot_r, yRadius = dot_r },
      }
      els[#els + 1] = {
        type = "text", action = "fill", text = spec.label,
        textColor = { white = 1.0, alpha = 0.96 }, textSize = LABEL_SZ,
        frame = text_frame(LABEL_X, LABEL_W, LABEL_SZ, spec.label),
        textAlignment = "left",
      }
      if stage == "recording" and elapsed then
        els[#els + 1] = {
          type = "text", action = "fill",
          text = string.format("%d:%02d", math.floor(elapsed / 60),
            math.floor(elapsed) % 60),
          -- 0.45 was too faint to read at a glance, which is the one thing the
          -- clock is for. Monospaced so the digits do not shift width as the
          -- seconds tick over.
          textColor = { white = 1.0, alpha = 0.62 }, textSize = CLOCK_SZ,
          textFont = "Menlo",
          -- Menlo sits higher in its frame than the system font does, so it
          -- needs CLOCK_DY on top of TEXT_DY to share a centre line with the
          -- label. Measured, not guessed: see text_frame.
          frame = text_frame(TIME_X, TIME_W, CLOCK_SZ,
            string.format("%d:%02d", math.floor(elapsed / 60),
              math.floor(elapsed) % 60), TEXT_DY + CLOCK_DY),
          textAlignment = "right",
        }
      end

      if levels then
        -- Scrolling waveform: newest on the right, history moving left, which is
        -- how every other waveform the user has seen behaves. levels[1] is the
        -- newest slice, so it is placed at the last bar, not the first. Drawing
        -- it at the first bar made the waveform scroll the wrong way and was a
        -- mismatch with the comment that had always claimed this.
        local pitch = WAV_W / BARS
        local width = pitch * 0.65
        for i = 0, BARS - 1 do
          local v = levels[i + 1] or 0
          els[#els + 1] = bar_elements(WAV_X + (BARS - 1 - i) * pitch, CY,
                                        MAX_H, pitch, width, spec.dot, v, 4)
        end
      else
        -- Indeterminate: three dots in the same place the waveform would be, so
        -- the pill does not change size between stages. They travel a pulse
        -- through each other rather than blinking in unison, and each one grows
        -- and shrinks on its way, which is what makes it read as a wave.
        local mid = WAV_X + WAV_W / 2
        local gap = 22
        for i = 0, 2 do
          local s = math.sin(anim * 6 - i * 1.1)
          local d = 6.5 + 3.5 * s
          els[#els + 1] = {
            type = "rectangle", action = "fill",
            fillColor = { red = spec.dot.red, green = spec.dot.green,
                          blue = spec.dot.blue,
                          alpha = 0.45 + 0.55 * (s * 0.5 + 0.5) },
            frame = { x = mid - gap + i * gap - d / 2, y = CY - d / 2,
                      w = d, h = d },
            roundedRectRadii = { xRadius = d / 2, yRadius = d / 2 },
          }
        end
      end

      c:replaceElements(els)
      c:show()
      shown = true
    end

    local function hide()
      if canvas and shown then
        canvas:hide()
        shown = false
      end
    end

    -- ------------------------------------------------------------ the poller
    --
    -- `expired` is what stops the short-lived stages from popping back. Once
    -- 'pasted' has been shown for DONE_FOR it is hidden and `current` is left
    -- alone: clearing it used to make the very next tick see the stage as new,
    -- reset `since` to zero, and put the pill back on screen, forever, because
    -- the timer could never reach DONE_FOR again.
    local current, since, last_epoch, expired = nil, 0, nil, false

    local function poll()
      local stage, epoch, wav
      local f = io.open(UI_STATE, "r")
      if f then
        local line = f:read("*l")
        f:close()
        if line then
          local a, b, c = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
          if not a then a = line end
          stage, epoch, wav = a, tonumber(b), c
        end
      end

      if not stage or stage == "" then
        hide() current, since, expired = nil, 0, false return
      end
      if not STAGE[stage] then
        hide() current, since, expired = nil, 0, false return
      end

      local now = os.time()
      if epoch and (now - epoch) > STALE_AFTER then
        hide() current, since, expired = nil, 0, false return
      end

      -- A new epoch counts as a new stage even when the name repeats, which is
      -- what makes a second dictation start its clock and its 'pasted' timer
      -- over instead of inheriting the first one's.
      if stage ~= current or epoch ~= last_epoch then
        current, since, last_epoch, expired = stage, 0, epoch, false
      else
        since = since + TICK
      end
      anim = anim + TICK

      -- short-lived stages, then get out of the way
      local transient = (stage == "done" or stage == "empty" or
                         stage == "cancelled" or stage == "blocked")
      if transient and since > DONE_FOR then
        if not expired then hide() expired = true end
        return
      end

      local levels
      if stage == "recording" and wav and wav ~= "" then
        levels = read_levels(wav)
        if levels then auto_gain(levels) levels = scaled(levels) end
      end

      local elapsed = nil
      if stage == "recording" and epoch then elapsed = now - epoch end

      local ok, err = pcall(render, stage, levels, elapsed)
      if not ok then
        dlog("overlay render failed (%s): %s", stage, tostring(err))
        hide()
      elseif not reported then
        reported = true
        -- The geometry in the same line, because a wrong-looking overlay is
        -- otherwise impossible to diagnose without being able to see the screen.
        dlog("overlay up on stage %s (pill %dx%d r=%.1f, wave %d, %d bars of %dms, text dy %.1f)",
          stage, PILL_W, PILL_H, PILL_R, MAX_H, BARS, BAR_MS, TEXT_DY)
      end
    end

    local timer = hs.timer.new(TICK, poll)
    timer:start()
    _G.__voxtype_overlay_timer = timer
    _G.__voxtype_overlay_read = read_levels
  end)

  if not built then
    log.e("overlay disabled: " .. tostring(build_err))
    do
      local f = io.open(LOG, "a")
      if f then
        f:write(string.format("%s overlay disabled: %s\n",
          os.date("%Y-%m-%dT%H:%M:%S"), tostring(build_err)))
        f:close()
      end
    end
  end
end
