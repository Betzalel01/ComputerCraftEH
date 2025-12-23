-- Licensing_Tablet.lua
-- Tablet home + Licensing “app”
-- Fixes:
--  * Accept server sender ID 0 (valid)
--  * Clickable buttons (mouse_click + monitor_touch)
--  * Level buttons always fit 1–5
--  * Optional “Waiting for server ACK” supported via server_ack

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
  error("No modem found / rednet not open. Tablet needs a modem.", 0)
end

-------------------------
-- UI UTIL
-------------------------
local function clamp(n, a, b) if n < a then return a elseif n > b then return b else return n end end
local function termSize() return term.getSize() end

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
  return x and y and x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2
end

local function normalize_click(ev, a, b, c)
  if ev == "mouse_click" then return b, c end
  if ev == "monitor_touch" then return b, c end
  return nil, nil
end

-------------------------
-- REDNET SEND
-------------------------
local function send(to, tbl) rednet.send(to, tbl, PROTOCOL) end

local function bind_server(sender)
  -- IMPORTANT: accept sender==0 (valid)
  if SERVER_ID == nil then SERVER_ID = sender end
end

local function announce()
  if SERVER_ID ~= nil then
    send(SERVER_ID, { kind="hello_tablet" })
  else
    rednet.broadcast({ kind="hello_tablet" }, PROTOCOL)
  end
end

-------------------------
-- STATE
-------------------------
local screen = "home" -- home | licensing
local licensing_mode = "idle" -- idle | approve_level | confirm_deny
local pending = {}
local active = nil
local licensing_badge = 0

local waiting_ack = false
local waiting_ack_id = nil

-------------------------
-- LICENSING ACTIONS
-------------------------
local function licensing_send_response(approved, level)
  if SERVER_ID == nil or not active then return end
  send(SERVER_ID, {
    kind = "approval_response",
    id = active.id,
    approved = approved and true or false,
    level = level,
  })
  waiting_ack = true
  waiting_ack_id = active.id
end

local function licensing_next_request()
  active = nil
  licensing_mode = "idle"
  waiting_ack = false
  waiting_ack_id = nil
end

-------------------------
-- RENDER: HOME
-------------------------
local function render_home()
  clear()
  local w, h = termSize()

  centerText(1, "BASE TABLET", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Rednet: OK   Server: " .. tostring(SERVER_ID))
  term.setTextColor(colors.white)

  centerText(4, "APPS", colors.cyan)

  local btns = {}
  local bw = math.min(20, w-6)
  local bx1 = math.floor((w - bw)/2) + 1
  local bx2 = bx1 + bw - 1
  local by1 = 6
  local by2 = 8

  btns.licensing = { x1=bx1, y1=by1, x2=bx2, y2=by2, label="Licensing", bg=colors.gray, fg=colors.white }
  drawButton(btns.licensing)

  if licensing_badge > 0 then
    local badgeText = tostring(licensing_badge)
    local badgeW = #badgeText + 2
    local rx2 = btns.licensing.x2
    local ry1 = btns.licensing.y1
    drawBox(rx2 - badgeW + 1, ry1, rx2, ry1, colors.red)
    term.setCursorPos(rx2 - badgeW + 2, ry1)
    term.setTextColor(colors.white)
    term.write(badgeText)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
  end

  term.setCursorPos(2, h-1)
  term.setTextColor(colors.lightGray)
  term.write("Tip: Open Licensing to approve/deny requests.")
  term.setTextColor(colors.white)

  return btns
end

-------------------------
-- RENDER: LICENSING APP
-------------------------
local function render_licensing()
  clear()
  local w, h = termSize()

  centerText(1, "LICENSING APPROVALS", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Rednet OK. Listening...  ")
  term.setTextColor(colors.white)
  term.write("Server: " .. tostring(SERVER_ID))

  local btns = {}
  btns.back = { x1=2, y1=1, x2=7, y2=1, label="<Back", bg=colors.black, fg=colors.lightGray }
  term.setCursorPos(btns.back.x1, btns.back.y1)
  term.setTextColor(btns.back.fg)
  term.write(btns.back.label)
  term.setTextColor(colors.white)

  if (not active) and (#pending > 0) then
    active = table.remove(pending, 1)
    licensing_mode = "idle"
    waiting_ack = false
    waiting_ack_id = nil
  end

  if not active then
    centerText(math.floor(h/2), "No pending requests.", colors.lightGray)
    return btns
  end

  local panelTop = 4
  local panelBottom = h - 9
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
    term.write(ln:sub(1, w-4))
    y = y + 1
  end

  if waiting_ack then
    term.setCursorPos(3, panelBottom + 1)
    term.setTextColor(colors.yellow)
    term.write("Sending decision... Waiting for server ACK...")
    term.setTextColor(colors.white)
  end

  if licensing_mode == "idle" then
    btns.approve = {
      x1=3, y1=h-7, x2=math.floor(w/2)-1, y2=h-5,
      label="APPROVE", bg=colors.green, fg=colors.white
    }
    btns.deny = {
      x1=math.floor(w/2)+1, y1=h-7, x2=w-2, y2=h-5,
      label="DENY", bg=colors.red, fg=colors.white
    }
    drawButton(btns.approve)
    drawButton(btns.deny)

    term.setCursorPos(3, h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: A=approve  D=deny   (Esc=back)")
    term.setTextColor(colors.white)

  elseif licensing_mode == "approve_level" then
    centerText(h-8, "Select approval level (1-5)", colors.yellow)

    local gap = 1
    local usable = w - 4
    local bw = math.floor((usable - gap*4) / 5)
    if bw < 5 then bw = 5 end  -- keep buttons readable
    local total = bw*5 + gap*4
    local startX = math.floor((w - total)/2) + 1
    if startX < 2 then startX = 2 end

    local x = startX
    for lvl=1,5 do
      local b = {
        x1=clamp(x, 2, w-1), y1=h-7,
        x2=clamp(x+bw-1, 2, w-1), y2=h-5,
        label=tostring(lvl), bg=colors.gray, fg=colors.white, level=lvl
      }
      btns["lvl"..lvl] = b
      drawButton(b)
      x = x + bw + gap
    end

    term.setCursorPos(3, h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: 1-5 choose level  |  Esc cancel")
    term.setTextColor(colors.white)

  elseif licensing_mode == "confirm_deny" then
    centerText(h-8, "Confirm DENY?", colors.yellow)

    btns.no = { x1=3, y1=h-7, x2=math.floor(w/2)-1, y2=h-5, label="CANCEL", bg=colors.gray, fg=colors.white }
    btns.yes = { x1=math.floor(w/2)+1, y1=h-7, x2=w-2, y2=h-5, label="DENY", bg=colors.red, fg=colors.white }
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
-- MAIN LOOP
-------------------------
announce()
local btns = render_home()
local lastAnnounce = os.epoch("utc")

while true do
  local e = { os.pullEvent() }
  local ev = e[1]

  if (os.epoch("utc") - lastAnnounce) > 3000 then
    announce()
    lastAnnounce = os.epoch("utc")
  end

  if ev == "rednet_message" then
    local sender, msg, proto = e[2], e[3], e[4]
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.kind == "hello_server" then
        bind_server(sender)       -- accept sender 0
        announce()
      elseif msg.kind == "approval_request" then
        bind_server(sender)
        table.insert(pending, msg)
        licensing_badge = licensing_badge + 1
      elseif msg.kind == "server_ack" then
        if waiting_ack and waiting_ack_id == msg.id then
          waiting_ack = false
          waiting_ack_id = nil
          licensing_next_request()
        end
      end

      btns = (screen == "home") and render_home() or render_licensing()
    end

  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = normalize_click(ev, e[2], e[3], e[4])

    if screen == "home" then
      if btns.licensing and hit(btns.licensing, x, y) then
        screen = "licensing"
        licensing_badge = 0
        btns = render_licensing()
      end

    elseif screen == "licensing" then
      if btns.back and hit(btns.back, x, y) then
        screen = "home"
        btns = render_home()
      elseif active and not waiting_ack then
        if licensing_mode == "idle" then
          if btns.approve and hit(btns.approve, x, y) then
            licensing_mode = "approve_level"
            btns = render_licensing()
          elseif btns.deny and hit(btns.deny, x, y) then
            licensing_mode = "confirm_deny"
            btns = render_licensing()
          end
        elseif licensing_mode == "approve_level" then
          for lvl=1,5 do
            local b = btns["lvl"..lvl]
            if b and hit(b, x, y) then
              licensing_send_response(true, lvl)
              btns = render_licensing()
              break
            end
          end
        elseif licensing_mode == "confirm_deny" then
          if btns.no and hit(btns.no, x, y) then
            licensing_mode = "idle"
            btns = render_licensing()
          elseif btns.yes and hit(btns.yes, x, y) then
            licensing_send_response(false, nil)
            btns = render_licensing()
          end
        end
      end
    end

  elseif ev == "char" then
    local ch = tostring(e[2])
    if screen == "licensing" and active and not waiting_ack then
      if licensing_mode == "idle" then
        if ch == "a" or ch == "A" then
          licensing_mode = "approve_level"
          btns = render_licensing()
        elseif ch == "d" or ch == "D" then
          licensing_mode = "confirm_deny"
          btns = render_licensing()
        end
      elseif licensing_mode == "approve_level" then
        local lvl = tonumber(ch)
        if lvl and lvl >= 1 and lvl <= 5 then
          licensing_send_response(true, lvl)
          btns = render_licensing()
        end
      end
    end

  elseif ev == "key" then
    local key = e[2]
    if key == keys.esc then
      if screen == "licensing" then
        if licensing_mode == "idle" then
          screen = "home"
          btns = render_home()
        else
          licensing_mode = "idle"
          btns = render_licensing()
        end
      end
    elseif screen == "licensing" and active and licensing_mode == "confirm_deny" and not waiting_ack then
      if key == keys.enter or key == keys.numPadEnter then
        licensing_send_response(false, nil)
        btns = render_licensing()
      end
    end
  end
end

