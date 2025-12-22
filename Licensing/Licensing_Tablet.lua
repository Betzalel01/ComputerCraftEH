-- Licensing_Tablet.lua
-- Pocket computer (tablet) UI for licensing approvals
--
-- IMPORTANT:
-- Your error shows `rednet.open("back")` fails because this pocket does NOT have a modem.
-- That means either:
--   (A) You're on a CC:Tweaked version/config where pockets require a Wireless Modem upgrade, OR
--   (B) This "tablet" item is not actually a pocket computer with networking enabled.
--
-- FIX:
--   1) Install a WIRELESS MODEM on the pocket computer (upgrade it).
--   2) Then this program will work.
--
-- This file also runs on a normal computer with an attached modem, unchanged.

local REDNET_PROTOCOL = "licensing_v1"

-------------------------
-- REDNET INIT (robust)
-------------------------
local function ensure_rednet()
  if rednet.isOpen() then return true end

  -- Try all normal sides (computers)
  local sides = {"left","right","top","bottom","front","back"}
  for _, s in ipairs(sides) do
    local ok = pcall(rednet.open, s)
    if ok and rednet.isOpen() then
      return true
    end
  end

  return false
end

if not ensure_rednet() then
  term.clear()
  term.setCursorPos(1,1)
  print("ERROR: Rednet not available.")
  print("")
  print("Pocket computers in your setup need a WIRELESS MODEM upgrade.")
  print("Install it, then rerun this program.")
  print("")
  print("Also ensure the turtle/computer you talk to has a wireless modem too.")
  return
end

-------------------------
-- UI HELPERS
-------------------------
local W, H = term.getSize()
local queue, idx = {}, 1

local function clamp_idx()
  if #queue == 0 then idx = 1 return end
  if idx < 1 then idx = 1 end
  if idx > #queue then idx = #queue end
end

local function center(y, text)
  local x = math.max(1, math.floor((W - #text) / 2))
  term.setCursorPos(x, y)
  term.write(text)
end

local function draw_box(x1, y1, x2, y2)
  for y = y1, y2 do
    term.setCursorPos(x1, y)
    term.write(string.rep(" ", math.max(0, x2 - x1 + 1)))
  end
end

local function draw_button(x1, y1, x2, y2, label)
  draw_box(x1, y1, x2, y2)
  local lx = x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2))
  local ly = y1 + math.floor((y2 - y1) / 2)
  term.setCursorPos(lx, ly)
  term.write(label)
end

local function hit(x, y, x1, y1, x2, y2)
  return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function current()
  if #queue == 0 then return nil end
  clamp_idx()
  return queue[idx]
end

local function pop_current()
  if #queue == 0 then return end
  clamp_idx()
  table.remove(queue, idx)
  clamp_idx()
end

local function redraw()
  term.clear()
  term.setCursorPos(1,1)
  center(1, "LICENSING APPROVALS")
  center(2, "Rednet OK. Listening...")

  if #queue == 0 then
    center(4, "No pending requests.")
  else
    clamp_idx()
    local r = queue[idx]
    center(4, ("Request %d/%d"):format(idx, #queue))
    term.setCursorPos(1,6); term.write(("From:   %s"):format(tostring(r.requester or "?")))
    term.setCursorPos(1,7); term.write(("Text:   %s"):format(tostring(r.request_text or "?")))
    term.setCursorPos(1,8); term.write(("Req ID: %s"):format(tostring(r.id or "?")))
    term.setCursorPos(1,9); term.write(("Server: %s"):format(tostring(r.server_id or "?")))
  end

  local yb = math.max(10, H - 6)
  draw_button(2,  yb,     12, yb + 2, "DENY")
  draw_button(14, yb,     24, yb + 2, "APP 1")
  draw_button(26, yb,     36, yb + 2, "APP 2")
  draw_button(38, yb,     48, yb + 2, "APP 3")
  draw_button(50, yb,     60, yb + 2, "APP 4")

  draw_button(14, yb + 3, 24, yb + 5, "APP 5")
  draw_button(26, yb + 3, 36, yb + 5, "NEXT")
  draw_button(38, yb + 3, 60, yb + 5, "CLEAR ALL")
end

local function send_decision(approved, level)
  local r = current()
  if not r then return end

  local resp = {
    kind = "approval_response",
    id = r.id,
    approved = approved,
    level = level,
  }

  if r.server_id then
    rednet.send(r.server_id, resp, REDNET_PROTOCOL)
  else
    rednet.broadcast(resp, REDNET_PROTOCOL)
  end

  pop_current()
end

-------------------------
-- MAIN
-------------------------
redraw()

while true do
  local ev, a, b, c = os.pullEvent()

  if ev == "rednet_message" then
    local sender, msg, proto = a, b, c
    if proto == REDNET_PROTOCOL and type(msg) == "table" and msg.kind == "approval_request" then
      msg.server_id = sender
      table.insert(queue, msg)
      idx = #queue
      redraw()
    end

  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y
    if ev == "mouse_click" then x, y = b, c else x, y = b, c end

    local yb = math.max(10, H - 6)

    if hit(x, y, 2, yb, 12, yb + 2) then
      send_decision(false, nil); redraw()
    elseif hit(x, y, 14, yb, 24, yb + 2) then
      send_decision(true, 1); redraw()
    elseif hit(x, y, 26, yb, 36, yb + 2) then
      send_decision(true, 2); redraw()
    elseif hit(x, y, 38, yb, 48, yb + 2) then
      send_decision(true, 3); redraw()
    elseif hit(x, y, 50, yb, 60, yb + 2) then
      send_decision(true, 4); redraw()
    elseif hit(x, y, 14, yb + 3, 24, yb + 5) then
      send_decision(true, 5); redraw()
    elseif hit(x, y, 26, yb + 3, 36, yb + 5) then
      if #queue > 0 then
        idx = idx + 1
        if idx > #queue then idx = 1 end
      end
      redraw()
    elseif hit(x, y, 38, yb + 3, 60, yb + 5) then
      queue, idx = {}, 1
      redraw()
    end
  end
end
