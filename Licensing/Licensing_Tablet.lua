-- Licensing_Tablet.lua
-- Fixes:
--  1) CLICKING: tablets often emit monitor_touch (not mouse_click). Now supports BOTH.
--  2) LEVEL BUTTONS CUT OFF: button width is now computed from screen width (no fixed 7),
--     so 1–5 always fit (even on small pocket/tablet screens).
--  3) Keeps number centering (labels centered inside each button).
--
-- Behavior:
--  * APPROVE -> level select 1–5 (click OR press 1–5)
--  * DENY -> confirm (click OR Enter), Esc cancels.

local PROTOCOL = "licensing_v1"
local SERVER_ID = nil -- optional hard-code

-------------------------
-- REDNET INIT
-------------------------
local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    pcall(rednet.open, s)
    if rednet.isOpen() then return true end
  end
  return false
end

if not ensure_rednet() then
  error("No modem found / rednet not open. Tablet needs a (wireless/ender) modem.", 0)
end

-------------------------
-- UI UTIL
-------------------------
local function clamp(n, a, b)
  if n < a then return a elseif n > b then return b else return n end
end

local function termSize()
  local w, h = term.getSize()
  return w, h
end

local function clear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
end

local function centerText(y, text, color)
  local w = (select(1, termSize()))
  local x = math.floor((w - #text)/2) + 1
  term.setCursorPos(clamp(x,1,w), y)
  if color then term.setTextColor(color) end
  term.write(text)
  term.setTextColor(colors.white)
end

local function drawBox(x1,y1,x2,y2,bg)
  term.setBackgroundColor(bg or colors.gray)
  for y=y1,y2 do
    term.setCursorPos(x1,y)
    term.write(string.rep(" ", x2-x1+1))
  end
  term.setBackgroundColor(colors.black)
end

local function drawButton(btn)
  drawBox(btn.x1, btn.y1, btn.x2, btn.y2, btn.bg or colors.gray)

  term.setTextColor(btn.fg or colors.white)
  local bw = (btn.x2 - btn.x1 + 1)
  local bh = (btn.y2 - btn.y1 + 1)

  local cx = btn.x1 + math.floor((bw - #btn.label)/2)
  local cy = btn.y1 + math.floor(bh/2)

  term.setCursorPos(cx, cy)
  term.write(btn.label)

  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
end

local function hit(btn, x, y)
  return x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2
end

-------------------------
-- STATE
-------------------------
local pending = {}
local mode = "idle" -- idle | approve_level | confirm_deny
local active = nil

-------------------------
-- REDNET SEND
-------------------------
local function send(to, tbl)
  rednet.send(to, tbl, PROTOCOL)
end

local function bind_server(sender)
  if not SERVER_ID then SERVER_ID = sender end
end

local function announce()
  if SERVER_ID then
    send(SERVER_ID, { kind="hello_tablet" })
  else
    rednet.broadcast({ kind="hello_tablet" }, PROTOCOL)
  end
end

-------------------------
-- ACTIONS
-------------------------
local function send_response(approved, level)
  if not SERVER_ID or not active then return end
  send(SERVER_ID, {
    kind = "approval_response",
    id = active.id,
    approved = approved and true or false,
    level = level,
  })
end

local function next_request()
  active = nil
  mode = "idle"
end

-------------------------
-- RENDER
-------------------------
local function render()
  clear()
  local w, h = termSize()

  centerText(1, "LICENSING APPROVALS", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Rednet OK. Listening...  ")
  term.setTextColor(colors.white)
  term.write("Server: " .. tostring(SERVER_ID or "nil"))

  -- Pull next request if needed
  if (not active) and (#pending > 0) then
    active = table.remove(pending, 1)
    mode = "idle"
  end

  if not active then
    centerText(math.floor(h/2), "No pending requests.", colors.lightGray)
    return {}
  end

  -- Request panel
  local panelTop = 4
  local panelBottom = h - 7
  drawBox(2, panelTop, w-1, panelBottom, colors.black)

  term.setCursorPos(3, panelTop)
  term.setTextColor(colors.cyan)
  term.write("Pending Request")
  term.setTextColor(colors.white)

  local lines = {
    "From: " .. tostring(active.requester),
    "Text: " .. tostring(active.request_text),
    "ID:   " .. tostring(active.id),
  }

  local y = panelTop + 2
  for _, ln in ipairs(lines) do
    term.setCursorPos(3, y)
    term.setTextColor(colors.white)
    term.write(ln:sub(1, w-4))
    y = y + 1
  end

  local btns = {}

  if mode == "idle" then
    btns.approve = {
      x1=3, y1=h-5,
      x2=math.floor(w/2)-1, y2=h-3,
      label="APPROVE",
      bg=colors.green,
      fg=colors.white, -- important
    }
    btns.deny = {
      x1=math.floor(w/2)+1, y1=h-5,
      x2=w-2, y2=h-3,
      label="DENY",
      bg=colors.red,
      fg=colors.white,
    }
    drawButton(btns.approve)
    drawButton(btns.deny)

    term.setCursorPos(3, h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: A=approve  D=deny")
    term.setTextColor(colors.white)

  elseif mode == "approve_level" then
    centerText(h-6, "Select approval level (1-5)", colors.yellow)

    -- Dynamic button sizing so 1–5 always fit on the current screen
    local gap = 1
    local leftMargin = 2
    local rightMargin = 2
    local usable = w - leftMargin - rightMargin
    local bw = math.floor((usable - gap*4) / 5)
    if bw < 3 then bw = 3 end -- still clickable
    -- If we're tight, shrink margins automatically
    local total = bw*5 + gap*4
    local startX = math.floor((w - total)/2) + 1
    if startX < 2 then startX = 2 end
    local x = startX

    for lvl=1,5 do
      local x1 = x
      local x2 = x + bw - 1
      -- Clamp to screen just in case
      x1 = clamp(x1, 2, w-1)
      x2 = clamp(x2, 2, w-1)

      local b = {
        x1=x1, y1=h-5,
        x2=x2, y2=h-3,
        label=tostring(lvl),
        bg=colors.gray,
        fg=colors.white,
        level=lvl
      }
      btns["lvl"..lvl] = b
      drawButton(b)
      x = x + bw + gap
    end

    term.setCursorPos(3, h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: 1-5 choose level  |  Esc to cancel")
    term.setTextColor(colors.white)

  elseif mode == "confirm_deny" then
    centerText(h-6, "Confirm DENY?", colors.yellow)

    btns.no = {
      x1=3, y1=h-5,
      x2=math.floor(w/2)-1, y2=h-3,
      label="CANCEL",
      bg=colors.gray,
      fg=colors.white
    }
    btns.yes = {
      x1=math.floor(w/2)+1, y1=h-5,
      x2=w-2, y2=h-3,
      label="DENY",
      bg=colors.red,
      fg=colors.white
    }
    drawButton(btns.no)
    drawButton(btns.yes)

    term.setCursorPos(3, h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: Enter=deny  Esc=cancel")
    term.setTextColor(colors.white)
  end

  return btns
end

-------------------------
-- INPUT NORMALIZATION (mouse_click + monitor_touch)
-------------------------
local function normalize_click(ev, a, b, c)
  -- mouse_click: (button, x, y)
  if ev == "mouse_click" then
    return b, c
  end
  -- monitor_touch: (side, x, y)
  if ev == "monitor_touch" then
    return b, c
  end
  return nil, nil
end

-------------------------
-- MAIN LOOP
-------------------------
announce()
local btns = render()
local lastAnnounce = os.epoch("utc")

while true do
  local e = { os.pullEvent() }
  local ev = e[1]

  -- periodic announce (server restarts)
  if (os.epoch("utc") - lastAnnounce) > 3000 then
    announce()
    lastAnnounce = os.epoch("utc")
  end

  if ev == "rednet_message" then
    local sender, msg, proto = e[2], e[3], e[4]
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.kind == "hello_server" then
        bind_server(sender)
        announce()
        btns = render()
      elseif msg.kind == "approval_request" then
        bind_server(sender)
        table.insert(pending, msg)
        btns = render()
      end
    end

  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = normalize_click(ev, e[2], e[3], e[4])
    if x and y then
      if mode == "idle" and active then
        if btns.approve and hit(btns.approve, x, y) then
          mode = "approve_level"
          btns = render()
        elseif btns.deny and hit(btns.deny, x, y) then
          mode = "confirm_deny"
          btns = render()
        end

      elseif mode == "approve_level" and active then
        for lvl=1,5 do
          local b = btns["lvl"..lvl]
          if b and hit(b, x, y) then
            send_response(true, lvl)
            next_request()
            btns = render()
            break
          end
        end

      elseif mode == "confirm_deny" and active then
        if btns.no and hit(btns.no, x, y) then
          mode = "idle"
          btns = render()
        elseif btns.yes and hit(btns.yes, x, y) then
          send_response(false, nil)
          next_request()
          btns = render()
        end
      end
    end

  elseif ev == "char" then
    local ch = tostring(e[2])

    if mode == "idle" and active then
      if ch == "a" or ch == "A" then
        mode = "approve_level"
        btns = render()
      elseif ch == "d" or ch == "D" then
        mode = "confirm_deny"
        btns = render()
      end

    elseif mode == "approve_level" and active then
      local lvl = tonumber(ch)
      if lvl and lvl >= 1 and lvl <= 5 then
        send_response(true, lvl)
        next_request()
        btns = render()
      end
    end

  elseif ev == "key" then
    local key = e[2]
    if key == keys.esc then
      if mode ~= "idle" then
        mode = "idle"
        btns = render()
      end

    elseif mode == "confirm_deny" and active then
      if key == keys.enter or key == keys.numPadEnter then
        send_response(false, nil)
        next_request()
        btns = render()
      end
    end
  end
end
