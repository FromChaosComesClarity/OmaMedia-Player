--[[ =========================================================================
  OmaMedia-Player — the interface.

  mpv is the engine and this script is the whole interface, drawn into mpv's own
  ASS overlay. One process, one window: the reason it works on a 4 GB dual-core
  box driving a tube.

  Sibling to OmaDVD-Player, and deliberately NOT the same program. That one
  knows about CSS keys, title tables and disc menus; this one knows about files.
  Each does one job. A Video DVD found here is handed over rather than
  reimplemented.

  Everything drawn obeys the same 480i rules: measured safe area, no stroke
  thinner than two scanlines, flat fills over hairlines, warm off-white instead
  of #FFF, and no saturated red for text.
========================================================================= ]]

local mp      = require 'mp'
local msg     = require 'mp.msg'
local options = require 'mp.options'
local utils   = require 'mp.utils'

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local o = {
  -- Measured on a real set, not the 5% broadcast standard: this tube crops
  -- noticeably more at the top.
  safe_top     = 0.10,
  safe_bottom  = 0.06,
  safe_left    = 0.05,
  safe_right   = 0.05,
  osd_timeout  = 4,
  -- A still image held indefinitely is the worst thing you can do to a
  -- phosphor, and a browser left open is exactly that.
  blank_after  = 240,
  start_path   = "",
  home         = "",
}
options.read_options(o, "omaplay")

local HOME = (o.home ~= "" and o.home) or os.getenv("HOME") or "/home"

-- ---------------------------------------------------------------------------
-- Forward declarations
--
-- ⚠️ Declared here rather than beside their definitions: callbacks further up
-- the file refer to them, and a local declared later compiles to a global
-- lookup -- nil at runtime, with nothing from luac to warn you.
-- ---------------------------------------------------------------------------
local render, rebuild, open_menu, back, show_browser, enter_dir, play_file

-- ---------------------------------------------------------------------------
-- Palette. ASS colours are written &HBBGGRR& -- blue first.
-- ---------------------------------------------------------------------------
local function c(rgb)
  return "&H" .. rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2) .. "&"
end

local COL = {
  ink    = c("EDEAE2"),   -- warm off-white; #FFF blooms on a tube
  dim    = c("9A968C"),
  accent = c("F0C060"),   -- amber, never red: composite bleeds red worst
  onacc  = c("101008"),
  panel  = c("0E0E0E"),
  row    = c("242424"),
  track  = c("3C3C3C"),
  black  = c("000000"),
}

-- ---------------------------------------------------------------------------
-- Metrics
-- ---------------------------------------------------------------------------
local M = {}
local function round(n) return math.floor(n + 0.5) end

local function measure()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or not h or h <= 0 then w, h = 720, 480 end
  M.w, M.h = w, h
  M.x0 = round(w * o.safe_left)
  M.x1 = round(w * (1 - o.safe_right))
  M.y0 = round(h * o.safe_top)
  M.y1 = round(h * (1 - o.safe_bottom))
  M.cw, M.ch = M.x1 - M.x0, M.y1 - M.y0
  -- Scale on the smaller axis: a compositor can tile the window, and
  -- height-only sizing then overflows the width.
  local sc = math.min(w / 720, h / 480)
  M.sc = sc
  M.fs_head  = round(36 * sc)
  M.fs_row   = round(29 * sc)
  M.fs_small = round(23 * sc)
  M.stroke   = math.max(4, round(4 * sc))   -- two scanlines at 480 lines
  M.pad      = round(15 * sc)
  M.rows_max = 6
  M.head_h   = round(M.fs_head * 1.7)
  M.foot_h   = round(M.fs_small * 1.6)
  M.row_gap  = math.max(2, round(h * 0.008))
  local body = M.ch - M.head_h - M.foot_h
  M.row_h    = math.max(round(34 * sc), math.floor(body / M.rows_max) - M.row_gap)
end

-- ---------------------------------------------------------------------------
-- ASS helpers
-- ---------------------------------------------------------------------------
local function esc(s)
  return tostring(s):gsub("\\", "/"):gsub("{", "("):gsub("}", ")"):gsub("\n", " ")
end

-- Bold sans measures about 0.42 of the point size per glyph here; 0.50 keeps
-- headroom. libass gives us no way to measure properly.
local function fit(s, size, width)
  local maxn = math.floor(width / (size * 0.50))
  if maxn < 1 then maxn = 1 end
  s = tostring(s)
  if #s <= maxn then return s end
  return s:sub(1, math.max(1, maxn - 1)) .. "..."
end

local function rect(a, x, y, w, h, col, alpha)
  w, h = round(w), round(h)
  if w <= 0 or h <= 0 then return end
  a[#a + 1] = string.format(
    "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c%s\\1a&H%02X&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
    round(x), round(y), col, alpha or 0, w, w, h, h)
end

local function text(a, x, y, align, size, col, s)
  a[#a + 1] = string.format(
    "{\\an%d\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\q2\\1c%s}%s",
    align, round(x), round(y), size, col, esc(s))
end

local overlay = mp.create_osd_overlay("ass-events")

local function paint(parts)
  overlay.res_x, overlay.res_y = M.w, M.h
  overlay.data = table.concat(parts, "\n")
  overlay:update()
end

local function wipe() overlay.data = "" overlay:update() end

local function hms(t)
  if not t then return "--:--" end
  t = math.max(0, math.floor(t + 0.5))
  local h, m, s = math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- ---------------------------------------------------------------------------
-- Picture: the same three controls OmaDVD has, for the same reasons
--
-- The framebuffer is 720x480 (3:2 in square pixels) but the tube shows it as
-- 4:3, so its pixel aspect is 8:9. mpv assumes square pixels, so telling it the
-- display aspect is the true one multiplied by (3/2)/(4/3) = 9/8 cancels that:
--
--     4:3  -> 1.3333 * 1.125 = 1.5  -> fills the screen, 1:1
--     16:9 -> 1.7778 * 1.125 = 2.0  -> letterboxed, correct
-- ---------------------------------------------------------------------------
local PAR_FIX = 9 / 8
local ASPECTS = { "auto", "4:3", "16:9", "fill", "native" }
local aspect_i = 1
local src_dar = nil

-- ⚠️ Never read the source aspect back from video-params/aspect: it reflects
-- video-aspect-override once we have set it, so on the next file the correction
-- compounds. The demuxer's own numbers are immune.
local function read_src_dar()
  local n = mp.get_property_number("track-list/count") or 0
  for i = 0, n - 1 do
    local t = "track-list/" .. i .. "/"
    if mp.get_property(t .. "type") == "video" then
      local w   = mp.get_property_number(t .. "demux-w")
      local h   = mp.get_property_number(t .. "demux-h")
      local par = mp.get_property_number(t .. "demux-par") or 1
      if w and h and h > 0 then return (w / h) * par end
      break
    end
  end
  return mp.get_property_number("video-params/aspect")
end

local function apply_aspect()
  local mode, v = ASPECTS[aspect_i], nil
  if mode == "native" then v = -1
  elseif mode == "4:3"  then v = (4 / 3) * PAR_FIX
  elseif mode == "16:9" then v = (16 / 9) * PAR_FIX
  elseif mode == "fill" then v = (M.h > 0) and (M.w / M.h) or 1.5
  else
    local d = src_dar
    v = (d and d > 0) and (d * PAR_FIX) or ((4 / 3) * PAR_FIX)
  end
  mp.set_property_number("video-aspect-override", v)
end

local function aspect_detail()
  local mode = ASPECTS[aspect_i]
  if mode ~= "auto" then return mode end
  local d = src_dar
  if not d then return "auto" end
  if math.abs(d - 4 / 3)  < 0.05 then return "auto (4:3)"  end
  if math.abs(d - 16 / 9) < 0.06 then return "auto (16:9)" end
  return string.format("auto (%.2f)", d)
end

local DEINT = { "no", "bwdif", "yadif" }
local deint_i = 1
local function cycle_deint()
  deint_i = (deint_i % #DEINT) + 1
  local v = DEINT[deint_i]
  mp.set_property("vf", v == "no" and "" or v)
end

local PANSCAN = { 0, 0.5, 1.0 }
local panscan_i = 1

-- ---------------------------------------------------------------------------
-- Media
-- ---------------------------------------------------------------------------
local MEDIA = {}
for ext in ([[mkv mp4 avi mov m4v webm mpg mpeg mpe m2v vob ts m2ts mts wmv asf
              flv ogv ogm rm rmvb divx 3gp f4v mxf y4m
              mp3 flac ogg oga opus wav m4a aac wma alac aiff ape mka]]):gmatch("%S+") do
  MEDIA[ext] = true
end

local function ext_of(name)
  local e = name:match("%.([%w]+)$")
  return e and e:lower() or ""
end

local function is_media(name) return MEDIA[ext_of(name)] == true end

local function basename(p) return (p:match("([^/]+)/?$")) or p end
local function parent(p)
  if p == "/" then return nil end
  local up = p:match("^(.*)/[^/]+/?$")
  if up == "" then return "/" end
  return up
end

-- ---------------------------------------------------------------------------
-- Sources: the disc, anything removable, and the usual folders
--
-- One lsblk call answers all of it, and it needs no privileges -- it reads the
-- udev database. TYPE=rom is the optical drive; RM=1 is anything hot-plugged.
-- ---------------------------------------------------------------------------
local volumes = {}      -- { label, path, kind = "disc" | "usb" }

local function scan_volumes(cb)
  mp.command_native_async({
    name = "subprocess", playback_only = false, capture_stdout = true,
    args = { "lsblk", "-P", "-o", "NAME,RM,TYPE,LABEL,MOUNTPOINT" },
  }, function(ok, res)
    volumes = {}
    local out = (ok and res and res.stdout) or ""
    for line in out:gmatch("[^\n]+") do
      local rm    = line:match('RM="(%d)"')
      local ty    = line:match('TYPE="([^"]*)"')
      local label = line:match('LABEL="([^"]*)"') or ""
      local mnt   = line:match('MOUNTPOINT="([^"]*)"') or ""
      if mnt ~= "" and mnt ~= "/" and (ty == "rom" or rm == "1") then
        volumes[#volumes + 1] = {
          label = (label ~= "" and label:gsub("_", " ")) or basename(mnt),
          path  = mnt,
          kind  = (ty == "rom") and "disc" or "usb",
        }
      end
    end
    if cb then cb() end
  end)
end

-- A Video DVD is OmaDVD-Player's job, not ours. Offer the handover only when it
-- is actually installed; the VOBs underneath stay browsable either way, so a
-- machine without it is not stuck.
local function omadvd_path()
  for _, p in ipairs({ HOME .. "/Applications/OmaDVD-Player.AppImage",
                       HOME .. "/Applications/OmaDVD-Player-x86_64.AppImage" }) do
    local st = utils.file_info(p)
    if st and st.is_file then return p end
  end
  return nil
end

local function is_video_dvd(path)
  local st = utils.file_info(path .. "/VIDEO_TS")
  return st and st.is_dir
end

-- ---------------------------------------------------------------------------
-- Browser state
-- ---------------------------------------------------------------------------
local browse = { path = nil, root = nil }

local function listing(path)
  local dirs  = utils.readdir(path, "dirs")  or {}
  local files = utils.readdir(path, "files") or {}
  local d, f = {}, {}
  for _, n in ipairs(dirs)  do if n:sub(1, 1) ~= "." then d[#d + 1] = n end end
  for _, n in ipairs(files) do if n:sub(1, 1) ~= "." and is_media(n) then f[#f + 1] = n end end
  local function bylower(a, b) return a:lower() < b:lower() end
  table.sort(d, bylower); table.sort(f, bylower)
  return d, f
end

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------
local ui = {
  mode  = "hidden",   -- hidden | menu | osd | loading | blank
  stack = {},
  sel   = {},
  rows  = {},
  title = "",
  osd_until  = 0,
  last_input = 0,
  blank_from = nil,
  drift = 0,
}

local osd_timer, tick_timer
local playing_path = nil

local function flash_osd()
  if ui.mode == "menu" then return end
  ui.mode = "osd"
  ui.osd_until = mp.get_time() + o.osd_timeout
  render()
end

-- ---------------------------------------------------------------------------
-- Tracks
-- ---------------------------------------------------------------------------
-- ⚠️ Matroska tags languages with ISO 639-2 ("por"), containers and DVDs with
-- 639-1 ("pt"). Looking up only the two-letter prefix turns "por" into "PO",
-- misses, and shows the viewer "POR". Both spellings live here.
local LANG = {
  en = "English",    eng = "English",
  es = "Espanol",    spa = "Espanol",
  pt = "Portugues",  por = "Portugues",
  fr = "Francais",   fre = "Francais",   fra = "Francais",
  de = "Deutsch",    ger = "Deutsch",    deu = "Deutsch",
  it = "Italiano",   ita = "Italiano",
  ja = "Japanese",   jpn = "Japanese",
  zh = "Chinese",    chi = "Chinese",    zho = "Chinese",
  nl = "Nederlands", dut = "Nederlands", nld = "Nederlands",
  sv = "Svenska",    swe = "Svenska",
  ru = "Russian",    rus = "Russian",
  ko = "Korean",     kor = "Korean",
  pl = "Polski",     pol = "Polski",
  da = "Dansk",      dan = "Dansk",
  fi = "Suomi",      fin = "Suomi",
  no = "Norsk",      nor = "Norsk",
  tr = "Turkce",     tur = "Turkce",
  ar = "Arabic",     ara = "Arabic",
  he = "Hebrew",     heb = "Hebrew",
  hi = "Hindi",      hin = "Hindi",
  cs = "Cestina",    cze = "Cestina",    ces = "Cestina",
  el = "Greek",      gre = "Greek",      ell = "Greek",
  hu = "Magyar",     hun = "Magyar",
  ro = "Romana",     rum = "Romana",     ron = "Romana",
  th = "Thai",       tha = "Thai",
  uk = "Ukrainian",  ukr = "Ukrainian",
  vi = "Tieng Viet", vie = "Tieng Viet",
}

local function lang_name(code)
  if not code or code == "" then return nil end
  local k = code:lower()
  return LANG[k] or LANG[k:sub(1, 2)] or k:upper()
end

local function tracks_of(kind)
  local out = {}
  local n = mp.get_property_number("track-list/count") or 0
  for i = 0, n - 1 do
    local p = "track-list/" .. i .. "/"
    if mp.get_property(p .. "type") == kind then
      out[#out + 1] = {
        id       = mp.get_property_number(p .. "id"),
        lang     = mp.get_property(p .. "lang"),
        title    = mp.get_property(p .. "title"),
        codec    = mp.get_property(p .. "codec"),
        external = mp.get_property_bool(p .. "external"),
        selected = mp.get_property_bool(p .. "selected"),
      }
    end
  end
  return out
end

local function track_label(t)
  local bits = {}
  if t.title and t.title ~= "" then bits[#bits + 1] = t.title
  elseif lang_name(t.lang)      then bits[#bits + 1] = lang_name(t.lang)
  else bits[#bits + 1] = "Track " .. tostring(t.id) end
  return table.concat(bits, " ")
end

local function track_detail(kind, prop)
  if mp.get_property(prop) == "no" then return "Off" end
  for _, t in ipairs(tracks_of(kind)) do
    if t.selected then return track_label(t) end
  end
  return "Off"
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------
local menus = {}

menus.sources = function()
  local rows = {}
  for _, v in ipairs(volumes) do
    local vol = v
    if vol.kind == "disc" and is_video_dvd(vol.path) and omadvd_path() then
      rows[#rows + 1] = {
        label = vol.label, detail = "Video DVD",
        act = function()
          -- Hand it over. Playing a Video DVD properly means CSS keys, a title
          -- table and a disc menu, and that program already exists.
          mp.command_native({ name = "subprocess", playback_only = false,
                              detach = true, args = { omadvd_path() } })
          mp.command("quit")
        end,
      }
    else
      rows[#rows + 1] = {
        label  = vol.label,
        detail = (vol.kind == "disc") and "Disc" or "USB",
        act    = function() enter_dir(vol.path, vol.path) end,
      }
    end
  end

  for _, d in ipairs({ { "Videos", HOME .. "/Videos" },
                       { "Music",  HOME .. "/Music" },
                       { "Downloads", HOME .. "/Downloads" },
                       { "Home",   HOME } }) do
    local st = utils.file_info(d[2])
    if st and st.is_dir then
      local p = d[2]
      rows[#rows + 1] = { label = d[1], detail = "", act = function() enter_dir(p, p) end }
    end
  end

  rows[#rows + 1] = { label = "Rescan drives", detail = "", keep = true,
                      act = function() scan_volumes(function() rebuild(); render() end) end }
  rows[#rows + 1] = { label = "Quit", detail = "", act = function() mp.command("quit") end }
  return rows, "OmaMedia"
end

menus.browse = function()
  local rows = {}
  local path = browse.path or HOME
  local dirs, files = listing(path)

  if path ~= browse.root and parent(path) then
    local up = parent(path)
    rows[#rows + 1] = { label = "..", detail = "", act = function() enter_dir(up, browse.root) end }
  end
  for _, d in ipairs(dirs) do
    local child = path .. "/" .. d
    rows[#rows + 1] = { label = d, detail = ">", act = function() enter_dir(child, browse.root) end }
  end
  for _, f in ipairs(files) do
    local full = path .. "/" .. f
    rows[#rows + 1] = {
      label  = f:gsub("%.[%w]+$", ""),
      detail = ext_of(f):upper(),
      mark   = (full == playing_path),
      act    = function() play_file(full) end,
    }
  end
  if #rows == 0 then rows[1] = { label = "Nothing playable here", off = true } end
  return rows, basename(path)
end

menus.audio = function()
  local rows = {}
  for _, t in ipairs(tracks_of("audio")) do
    local id = t.id
    rows[#rows + 1] = { label = track_label(t), detail = (t.codec or ""):upper(),
                        mark = t.selected,
                        act = function() mp.set_property_number("aid", id) end }
  end
  if #rows == 0 then rows[1] = { label = "No audio tracks", off = true } end
  return rows, "Audio"
end

menus.subs = function()
  local rows = { { label = "Off", detail = "", mark = (mp.get_property("sid") == "no"),
                   act = function() mp.set_property("sid", "no") end } }
  for _, t in ipairs(tracks_of("sub")) do
    local id = t.id
    rows[#rows + 1] = { label = track_label(t),
                        detail = t.external and "file" or "",
                        mark = t.selected,
                        act = function() mp.set_property_number("sid", id) end }
  end
  return rows, "Subtitles"
end

menus.chapters = function()
  local rows = {}
  local n = mp.get_property_number("chapter-list/count") or 0
  local cur = mp.get_property_number("chapter")
  for i = 0, n - 1 do
    local title = mp.get_property("chapter-list/" .. i .. "/title")
    rows[#rows + 1] = {
      label  = (title and title ~= "") and title or ("Chapter " .. (i + 1)),
      detail = hms(mp.get_property_number("chapter-list/" .. i .. "/time")),
      mark   = (cur == i),
      act    = function() mp.set_property_number("chapter", i) end,
    }
  end
  if n == 0 then rows[1] = { label = "No chapters", off = true } end
  return rows, "Chapters"
end

menus.picture = function()
  return {
    { label = "Aspect", detail = aspect_detail(), keep = true,
      act = function() aspect_i = (aspect_i % #ASPECTS) + 1; apply_aspect() end },
    { label = "Deinterlace", detail = DEINT[deint_i], keep = true, act = cycle_deint },
    { label = "Fill screen", detail = string.format("%.0f%%", PANSCAN[panscan_i] * 100),
      keep = true, act = function()
        panscan_i = (panscan_i % #PANSCAN) + 1
        mp.set_property_number("panscan", PANSCAN[panscan_i])
      end },
  }, "Picture"
end

menus.playing = function()
  local rows = {}
  rows[#rows + 1] = { label = mp.get_property_bool("pause") and "Resume" or "Pause",
                      detail = "", act = function() mp.commandv("cycle", "pause") end }
  rows[#rows + 1] = { label = "Audio",     detail = track_detail("audio", "aid"), sub = "audio" }
  rows[#rows + 1] = { label = "Subtitles", detail = track_detail("sub", "sid"),   sub = "subs" }
  if (mp.get_property_number("chapter-list/count") or 0) > 0 then
    rows[#rows + 1] = { label = "Chapters",
                        detail = tostring(mp.get_property_number("chapter-list/count")),
                        sub = "chapters" }
  end
  rows[#rows + 1] = { label = "Picture", detail = aspect_detail(), sub = "picture" }
  rows[#rows + 1] = { label = "Browse", detail = "", act = function()
    mp.command("stop"); show_browser()
  end }
  rows[#rows + 1] = { label = "Quit", detail = "", act = function() mp.command("quit") end }
  return rows, mp.get_property("media-title") or "Playing"
end

-- ---------------------------------------------------------------------------
-- Menu engine
-- ---------------------------------------------------------------------------
rebuild = function()
  local id = ui.stack[#ui.stack] or "sources"
  local rows, title = (menus[id] or menus.sources)()
  ui.rows, ui.title = rows, title or id
  local sel = ui.sel[id] or 1
  if sel > #rows then sel = #rows end
  if sel < 1 then sel = 1 end
  ui.sel[id] = sel
end

open_menu = function(id)
  ui.stack[#ui.stack + 1] = id
  rebuild()
  ui.mode = "menu"
  render()
end

show_browser = function()
  playing_path = nil
  ui.stack = { browse.path and "browse" or "sources" }
  ui.mode = "menu"
  rebuild()
  render()
end

local function show_sources()
  ui.stack = { "sources" }
  ui.sel["sources"] = ui.sel["sources"] or 1
  ui.mode = "menu"
  rebuild()
  render()
end

enter_dir = function(path, root)
  browse.path = path
  browse.root = root or browse.root or path
  ui.sel["browse"] = 1
  ui.stack = { "browse" }
  ui.mode = "menu"
  rebuild()
  render()
end

local function close_menu()
  ui.stack = {}
  ui.mode = "hidden"
  wipe()
end

play_file = function(path)
  playing_path = path
  ui.mode = "loading"
  render()
  mp.commandv("loadfile", path)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function draw_blank(a)
  rect(a, 0, 0, M.w, M.h, COL.black, 0)
  local n = ui.drift
  text(a, M.x0 + (n % 5) * (M.cw / 6), M.y0 + (math.floor(n / 5) % 4) * (M.ch / 5),
       7, M.fs_small, c("3A3A3A"), "OmaMedia")
end

local function draw_loading(a)
  rect(a, 0, 0, M.w, M.h, COL.black, 0x20)
  local h = round(M.fs_head * 2.2)
  local y = round((M.h - h) / 2)
  rect(a, M.x0, y, M.cw, h, COL.panel, 0x10)
  text(a, M.w / 2, y + round((h - M.fs_head) / 2), 8, M.fs_head, COL.accent, "Loading...")
end

local function draw_osd(a)
  local pos = mp.get_property_number("time-pos") or 0
  local dur = mp.get_property_number("duration") or 0
  local paused = mp.get_property_bool("pause")
  local bar_h = math.max(M.stroke * 2, round(M.h * 0.018))
  local band = round(M.fs_row * 1.5) + bar_h + M.pad * 2 + M.fs_small
  local y = M.y1 - band

  rect(a, M.x0, y, M.cw, band, COL.panel, 0x28)

  local ty = y + M.pad
  text(a, M.x0 + M.pad, ty, 7, M.fs_small, COL.dim,
       fit(mp.get_property("media-title") or "", M.fs_small, M.cw - M.pad * 2))

  ty = ty + M.fs_small + round(M.pad * 0.5)
  text(a, M.x0 + M.pad, ty, 7, M.fs_row, COL.ink, (paused and "|| " or "> ") .. hms(pos))
  text(a, M.x1 - M.pad, ty, 9, M.fs_row, COL.dim, hms(dur))

  ty = ty + M.fs_row * 1.25
  local bw = M.cw - M.pad * 2
  rect(a, M.x0 + M.pad, ty, bw, bar_h, COL.track, 0x10)
  if dur > 0 then
    rect(a, M.x0 + M.pad, ty, bw * math.min(1, pos / dur), bar_h, COL.accent, 0x00)
  end
end

local function draw_menu(a)
  rect(a, 0, 0, M.w, M.h, COL.black, 0x40)
  rect(a, M.x0, M.y0, M.cw, M.ch, COL.panel, 0x18)

  local id  = ui.stack[#ui.stack] or "sources"
  local sel = ui.sel[id] or 1

  local clock = os.date("%H:%M")
  text(a, M.x0 + M.pad, M.y0 + round(M.pad * 0.6), 7, M.fs_head, COL.ink,
       fit(ui.title, M.fs_head, M.cw - M.pad * 2 - M.fs_small * 0.55 * (#clock + 2)))
  text(a, M.x1 - M.pad, M.y0 + round(M.pad * 0.6), 9, M.fs_small, COL.dim, clock)

  local first = 1
  if #ui.rows > M.rows_max then
    first = math.min(math.max(1, sel - math.floor(M.rows_max / 2)), #ui.rows - M.rows_max + 1)
  end

  local y = M.y0 + M.head_h
  for i = first, math.min(#ui.rows, first + M.rows_max - 1) do
    local row = ui.rows[i]
    local on  = (i == sel)
    rect(a, M.x0 + M.pad, y, M.cw - M.pad * 2, M.row_h,
         on and COL.accent or COL.row, on and 0x00 or 0x30)
    local fg = on and COL.onacc or (row.off and COL.dim or COL.ink)
    local ty = y + round((M.row_h - M.fs_row) / 2)
    local label = (row.mark and "* " or "") .. row.label
    if row.sub then label = label .. "  >" end
    local dw = (row.detail and row.detail ~= "") and (#row.detail * M.fs_row * 0.5 + M.pad) or 0
    text(a, M.x0 + M.pad * 2, ty, 7, M.fs_row, fg,
         fit(label, M.fs_row, M.cw - M.pad * 4 - dw))
    if row.detail and row.detail ~= "" then
      text(a, M.x1 - M.pad * 2, ty, 9, M.fs_row, on and COL.onacc or COL.dim, row.detail)
    end
    y = y + M.row_h + M.row_gap
  end

  if #ui.rows > M.rows_max then
    text(a, M.x1 - M.pad, M.y1 - M.foot_h, 9, M.fs_small, COL.dim,
         string.format("%d/%d", sel, #ui.rows))
  end
  local hint = (id == "sources") and "Enter select" or "Enter select    Esc back"
  text(a, M.x0 + M.pad, M.y1 - M.foot_h, 7, M.fs_small, COL.dim, hint)
end

render = function()
  measure()
  mp.set_property_native("user-data/omaplay", {
    mode = ui.mode,
    menu = ui.stack[#ui.stack] or "",
    rows = #ui.rows,
    path = browse.path or "",
    sel  = (function()
      local id = ui.stack[#ui.stack]
      local r  = id and ui.rows[ui.sel[id] or 1]
      return r and r.label or ""
    end)(),
  })
  local a = {}
  if ui.mode == "blank"        then draw_blank(a)
  elseif ui.mode == "loading"  then draw_loading(a)
  elseif ui.mode == "menu"     then draw_menu(a)
  elseif ui.mode == "osd"      then draw_osd(a)
  else wipe() return end
  paint(a)
end

-- ---------------------------------------------------------------------------
-- Input. One key does the obvious thing in the browser and in playback alike.
-- ---------------------------------------------------------------------------
local function wake()
  ui.last_input = mp.get_time()
  if ui.mode == "blank" then
    ui.mode = ui.blank_from or "hidden"
    ui.blank_from = nil
    if ui.mode == "hidden" then wipe() else render() end
    return true
  end
  return false
end

local function move(d)
  local id = ui.stack[#ui.stack] or "sources"
  local n = #ui.rows
  if n == 0 then return end
  local i = ui.sel[id] or 1
  for _ = 1, n do
    i = ((i - 1 + d) % n) + 1
    if not ui.rows[i].off then break end
  end
  ui.sel[id] = i
  render()
end

local function activate()
  local id = ui.stack[#ui.stack] or "sources"
  local row = ui.rows[ui.sel[id] or 1]
  if not row or row.off then return end
  if row.sub then open_menu(row.sub) return end
  if row.act then
    row.act()
    if row.keep then rebuild(); render()
    elseif ui.mode == "menu" and ui.stack[#ui.stack] == id then
      -- Still on the same menu: a track was picked, so show the result.
      rebuild(); render()
    end
  end
end

back = function()
  local id = ui.stack[#ui.stack] or "sources"
  if #ui.stack > 1 then
    table.remove(ui.stack); rebuild(); render(); return
  end
  if id == "browse" then
    -- Up a level, then out to the source list at the top.
    local up = (browse.path ~= browse.root) and parent(browse.path) or nil
    if up then enter_dir(up, browse.root) else show_sources() end
    return
  end
  if id == "playing" then
    close_menu()
    return
  end
  -- At the source list with something playing behind it: go back to the film.
  if mp.get_property("idle-active") ~= "yes" and playing_path then close_menu() end
end

local function bind(key, name, fn, rep)
  mp.add_forced_key_binding(key, "omaplay-" .. name, function()
    ui.last_input = mp.get_time()
    if wake() then return end
    fn()
  end, rep and { repeatable = true } or nil)
end

bind("UP", "up", function()
  if ui.mode == "menu" then move(-1) else mp.commandv("add", "chapter", 1); flash_osd() end
end, true)

bind("DOWN", "down", function()
  if ui.mode == "menu" then move(1) else mp.commandv("add", "chapter", -1); flash_osd() end
end, true)

bind("LEFT", "left", function()
  if ui.mode == "menu" then back() else mp.commandv("seek", "-10"); flash_osd() end
end, true)

bind("RIGHT", "right", function()
  if ui.mode == "menu" then activate() else mp.commandv("seek", "10"); flash_osd() end
end, true)

local function menu_key()
  if ui.mode == "menu" then activate()
  elseif mp.get_property("idle-active") == "yes" then show_browser()
  else open_menu("playing") end
end

bind("ENTER", "select", menu_key)
bind("KP_ENTER", "select2", menu_key)

bind("ESC", "back", function()
  if ui.mode == "menu" then back()
  elseif mp.get_property("idle-active") ~= "yes" then open_menu("playing") end
end)
bind("BS", "back2", function() if ui.mode == "menu" then back() else flash_osd() end end)

bind("SPACE", "playpause", function()
  if ui.mode == "menu" then activate() return end
  mp.commandv("cycle", "pause"); flash_osd()
end)

bind("m", "menu", function()
  if ui.mode == "menu" then
    if ui.stack[#ui.stack] == "playing" then close_menu() else back() end
  else menu_key() end
end)

bind("i", "info", flash_osd)
bind("a", "audio", function() mp.commandv("cycle", "audio"); flash_osd() end)
bind("j", "sub", function() mp.commandv("cycle", "sub"); flash_osd() end)
bind("d", "deint", function() cycle_deint(); flash_osd() end)
bind("q", "quit", function() mp.command("quit") end)

-- ---------------------------------------------------------------------------
-- Burn-in watchdog
--
-- Triggered by "no keypress", not "paused": a browser left open overnight burns
-- in exactly like a paused frame does, and the browser is where this player
-- spends most of its life.
-- ---------------------------------------------------------------------------
tick_timer = mp.add_periodic_timer(1, function()
  local paused = mp.get_property_bool("pause")
  local idle   = mp.get_property("idle-active") == "yes"

  if (paused or idle) and ui.mode ~= "loading"
     and (mp.get_time() - ui.last_input) >= o.blank_after then
    if ui.mode ~= "blank" then ui.blank_from = ui.mode; ui.mode = "blank"; ui.drift = 0 end
    ui.drift = ui.drift + 1
    render()
    return
  end
  if ui.mode == "blank" then
    ui.mode = ui.blank_from or "hidden"
    ui.blank_from = nil
    if ui.mode == "hidden" then wipe() end
  end

  if ui.mode == "loading" then render()
  elseif ui.mode == "osd" then
    if mp.get_time() > ui.osd_until then ui.mode = "hidden"; wipe() else render() end
  elseif ui.mode == "menu" then render()
  end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
mp.register_event("file-loaded", function()
  measure()
  src_dar = read_src_dar()
  apply_aspect()
  ui.stack = {}
  ui.mode = "hidden"
  wipe()
  flash_osd()
end)

mp.register_event("end-file", function(ev)
  local reason = ev and ev.reason
  if reason == "quit" then return end
  -- A finished or stopped file returns to where it was chosen from. The player
  -- is the place you sit; it should never drop you on a black screen.
  mp.add_timeout(0.2, function()
    if mp.get_property("idle-active") == "yes" then show_browser() end
  end)
end)

mp.observe_property("osd-dimensions", "native", function()
  if ui.mode ~= "hidden" then render() end
end)

ui.last_input = mp.get_time()

scan_volumes(function()
  if o.start_path ~= "" then
    local st = utils.file_info(o.start_path)
    if st and st.is_dir then enter_dir(o.start_path, o.start_path) return end
  end
  -- Nothing was asked for and nothing is playing: open on the source list.
  if mp.get_property("idle-active") == "yes" then show_sources() end
end)

msg.info("OmaMedia-Player UI ready")
