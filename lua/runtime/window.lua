local M = {}

local function command_output(cmd)
  local p = io.popen(cmd, "r")
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  if out == "" then return nil end
  return out
end

function M.session_text_scale()
  local gsettings_out = command_output("gsettings get org.cinnamon.desktop.interface text-scaling-factor 2>/dev/null")
  if gsettings_out then
    local scale = tonumber(gsettings_out:match("([%d%.]+)"))
    if scale and scale > 0 then
      return scale
    end
  end

  local xrdb_out = command_output("xrdb -query 2>/dev/null")
  if xrdb_out then
    local dpi = tonumber(xrdb_out:match("Xft%.dpi:%s*([%d%.]+)"))
    if dpi and dpi > 0 then
      return dpi / 96
    end
  end

  return 1.0
end

function M.window_size(frame)
  frame = frame or {}
  local scale = M.session_text_scale()
  return {
    width = math.floor(((frame.width or 1760) / scale) + 0.5),
    height = math.floor(((frame.height or 1400) / scale) + 0.5),
  }
end

return M
