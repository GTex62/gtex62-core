-- gtex62-core/lua/runtime/fonts.lua
-- Shared font-availability detection for suite theme files.
--
-- This answers one question only: "is this font family installed on this
-- machine" (via fc-list), cached because the shell-out is relatively slow
-- and the answer never changes within a session. Which families a suite
-- prefers, which open-source family it falls back to, and any per-font
-- metric correction (size/offset) stay suite-owned, in the suite's own
-- theme file — this module has no opinion on font choice, only font fact.

local M = {}

local HOME = os.getenv("HOME") or ""
local CACHE_DIR = os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR")
               or (HOME .. "/.cache/gtex62-core")
local FONT_CACHE = CACHE_DIR .. "/runtime/font_cache.txt"

-- One cache per machine, not per suite: "is Eurostile installed" doesn't
-- vary by which suite is asking.
local cache = nil

local function load_cache()
  if cache then return cache end
  cache = {}
  local f = io.open(FONT_CACHE, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(.-)=(%d)$")
      if k then cache[k] = (v == "1") end
    end
    f:close()
  end
  return cache
end

local function save_cache()
  if not cache then return end
  os.execute("mkdir -p " .. CACHE_DIR .. "/runtime")
  local f = io.open(FONT_CACHE, "w")
  if not f then return end
  for k, v in pairs(cache) do
    f:write(k, "=", v and "1" or "0", "\n")
  end
  f:close()
end

--- Returns true if `family` (optionally "Family:style=...") is installed,
--- per fc-list. Result is cached under GTEX62_CACHE_DIR/runtime/font_cache.txt.
function M.font_installed(family)
  local name = family:match("^([^:]+)") or family
  local c = load_cache()
  if c[name] ~= nil then
    return c[name]
  end

  local safe = name:gsub("'", "'\\''")
  local cmd_family = "sh -lc \"fc-list : family | grep -qi '" .. safe .. "'\""
  local ok = os.execute(cmd_family)
  if ok == true or ok == 0 then
    c[name] = true
    save_cache()
    return true
  end

  local cmd_any = "sh -lc \"fc-list | grep -qi '" .. safe .. "'\""
  ok = os.execute(cmd_any)
  local found = (ok == true or ok == 0)
  c[name] = found
  save_cache()
  return found
end

--- Returns the first family in `preferred` (a list) that is installed, or
--- `fallback` if none are.
function M.pick_font(preferred, fallback)
  for _, family in ipairs(preferred) do
    if M.font_installed(family) then
      return family
    end
  end
  return fallback
end

return M
