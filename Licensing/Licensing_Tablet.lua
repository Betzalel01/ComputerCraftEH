-- Tablet.lua (drop-in replacement)
-- CC:Tweaked Advanced Pocket Computer / Tablet
-- Home Screen + "Licensing" app wrapper
--
-- Fixes:
--  * Clickable buttons (mouse_click + monitor_touch) + typeable keys
--  * Proper 1–5 layout (always visible)
--  * Debounce + ACK handshake to prevent approve/level spam loops
--  * Dedupes requests by ID (server resend won’t duplicate queue)
--  * Badge shows count of pending requests

local PROTOCOL = "licensing_v1"
local SERVER_ID = nil -- optional hard-code (number) if you want

-------------------------
-- REDNET INIT
-------------------------
local function ensure_rednet()
  if rednet.isOpen() then return true end
  for _, s in ipairs({ "left","right","top","bottom","front","back" }) do
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
  return term.getSize()
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
  return x and y and x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2
end

local function normalize_click(ev, a, b, c)
  if ev == "mouse_click" then return b, c end       -- (button, x, y)
  if ev == "monitor_touch" then return b, c end     -- (side, x, y)
  return nil, nil
end

-------------------------
-- REDNET SEND / BIND
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
-- STATE
-------------------------
local screen = "home" -- home | licensing
local licensing_mode = "idle" -- idle | approve_level | confirm_deny
local pending = {}            -- queue of requests
local pending_by_id = {}      -- id -> true (dedupe)
local active = nil            -- current request

-- Badge count for home
local licensing_badge = 0

-- ACK / debounce
local awaiting_ack = false
local awaiting_id = nil
local status_line = ""        -- small status message in licensing app

-------------------------
-- QUEUE HELPERS
-------------------------
local function recompute_badge()
  licensing_badge = #pending + (active and 1 or 0)
end

local function enqueue_request(req)
  if not req or not req.id then return end
  if pending_by_id[req.id] then return end
  pending_by_id[req.id] = true
  table.insert(pending, req)
  recompute_badge()
end

local function pop_next_request()
  active = nil
  awaiting_ack = false
  awaiting_id = nil
  status_line = ""

  while #pending > 0 do
    local req = table.remove(pending, 1)
    if req and req.id and pending_by_id[req.id] then
      active = req
      break
    end
  end
  licensing_mode = "idle"
  recompute_badge()
end

local function clear_request(id)
  if id then pending_by_id[id] = nil end
  if active and active.id == id then
    active = nil
  end
  recompute_badge()
end

-------------------------
-- LICENSING ACTIONS (ACK SAFE)
-------------------------
local function licensing_send_response(approved, level)
  if not SERVER_ID or not active then return end
  if awaiting_ack then return end -- debounce: do not send again

  awaiting_ack = true
  awaiting_id = active.id
  status_line = "Sending decision..."

  send(SERVER_ID, {
    kind = "approval_response",
    id = active.id,
    approved = approved and true or false,
    level = level,
  })
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
  term.write("Rednet: OK   Server: " .. tostring(SERVER_ID or "nil"))
  term.setTextColor(colors.white)

  centerText(4, "APPS", colors.cyan)

  local btns = {}

  local bw = math.min(22, w-6)
  local bx1 = math.floor((w - bw)/2) + 1
  local bx2 = bx1 + bw - 1
  local by1 = 6
  local by2 = 8

  btns.licensing = { x1=bx1, y1=by1, x2=bx2, y2=by2, label="Licensing", bg=colors.gray, fg=colors.white }
  drawButton(btns.licensing)

  -- Badge (top-right of app button)
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
  local btns = {}

  centerText(1, "LICENSING APPROVALS", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Rednet OK. Listening...  ")
  term.setTextColor(colors.white)
  term.write("Server: " .. tostring(SERVER_ID or "nil"))

  -- Back button
  btns.back = { x1=2, y1=1, x2=7, y2=1, label="<Back", bg=colors.black, fg=colors.lightGray }
  term.setCursorPos(btns.back.x1, btns.back.y1)
  term.setTextColor(btns.back.fg)
  term.write(btns.back.label)
  term.setTextColor(colors.white)

  -- Ensure active
  if (not active) then
    pop_next_request()
  end

  if not active then
    centerText(math.floor(h/2), "No pending requests.", colors.lightGray)
    return btns
  end

  -- Request panel
  local panelTop = 4
  local panelBottom = h - 7

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

  -- Status line (ACK / send progress)
  if status_line and status_line ~= "" then
    term.setCursorPos(3, panelBottom)
    term.setTextColor(colors.lightGray)
    term.write(status_line:sub(1, w-4))
    term.setTextColor(colors.white)
  end

  if licensing_mode == "idle" then
    btns.approve = {
      x1=3, y1=h-5,
      x2=math.floor(w/2)-1, y2=h-3,
      label="APPROVE",
      bg=colors.green,
      fg=colors.white,
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
    term.write("Keys: A=approve  D=deny   (Esc=back)")
    term.setTextColor(colors.white)

    if awaiting_ack then
      -- Lock out clicks while awaiting ACK
      term.setCursorPos(3, h-6)
      term.setTextColor(colors.yellow)
      term.write("Waiting for server ACK...")
      term.setTextColor(colors.white)
    end

  elseif licensing_mode == "approve_level" then
    centerText(h-6, "Select approval level (1-5)", colors.yellow)

    -- Layout that always fits (no clamping that hides buttons)
    local gap = 1
    local margin = 2
    local usable = w - margin*2
    local bw = math.floor((usable - gap*4) / 5)
    if bw < 3 then bw = 3 end
    local total = bw*5 + gap*4

    -- If still too wide, shrink bw until it fits
    while total > usable and bw > 3 do
      bw = bw - 1
      total = bw*5 + gap*4
    end

    local startX = margin + math.floor((usable - total)/2)

    local x = startX
    for lvl=1,5 do
      local b = {
        x1=x, y1=h-5,
        x2=x+bw-1, y2=h-3,
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
    term.write("Keys: 1-5 choose level  |  Esc cancel")
    term.setTextColor(colors.white)

    if awaiting_ack then
      term.setCursorPos(3, h-6)
      term.setTextColor(colors.yellow)
      term.write("Waiting for server ACK...")
      term.setTextColor(colors.white)
    end

  elseif licensing_mode == "confirm_deny" then
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

    if awaiting_ack then
      term.setCursorPos(3, h-6)
      term.setTextColor(colors.yellow)
      term.write("Waiting for server ACK...")
      term.setTextColor(colors.white)
    end
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

      elseif msg.kind == "approval_request" then
        bind_server(sender)
        enqueue_request(msg)

      elseif msg.kind == "approval_ack" then
        bind_server(sender)
        -- ACK for the request we just sent
        if awaiting_ack and awaiting_id and msg.id == awaiting_id then
          awaiting_ack = false
          awaiting_id = nil

          if msg.ok == false then
            status_line = "Server rejected decision: " .. tostring(msg.reason or "unknown")
            licensing_mode = "idle" -- keep active so you can retry
          else
            -- Clear this request and move on
            status_line = "Decision accepted."
            clear_request(active and active.id or msg.id)
            pop_next_request()
          end
        end
      end

      recompute_badge()

      -- re-render current screen
      if screen == "home" then
        btns = render_home()
      else
        btns = render_licensing()
      end
    end

  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = normalize_click(ev, e[2], e[3], e[4])

    if screen == "home" then
      if btns.licensing and hit(btns.licensing, x, y) then
        screen = "licensing"
        -- do not forcibly clear badge here; badge now reflects queue state
        btns = render_licensing()
      end

    elseif screen == "licensing" then
      -- Back
      if btns.back and hit(btns.back, x, y) then
        screen = "home"
        btns = render_home()

      elseif active and not awaiting_ack then
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

    if screen == "licensing" and active and not awaiting_ack then
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
        if awaiting_ack then
          -- do nothing; wait for ack (prevents half-state)
          btns = render_licensing()
        elseif licensing_mode == "idle" then
          screen = "home"
          btns = render_home()
        else
          licensing_mode = "idle"
          btns = render_licensing()
        end
      end

    elseif screen == "licensing" and active and (licensing_mode == "confirm_deny") and not awaiting_ack then
      if key == keys.enter or key == keys.numPadEnter then
        licensing_send_response(false, nil)
        btns = render_licensing()
      end
    end
  end
end
