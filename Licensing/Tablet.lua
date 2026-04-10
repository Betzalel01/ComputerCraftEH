-- ============================================================
--  XLicensing_Tablet.lua  |  TABLET / COMPUTER (admin UI)
--  Role: Receive approval requests from server, display them
--        to an admin, send approve/deny decisions back.
--
--  Screens:
--    HOME       - app launcher with pending badge
--    LICENSING  - request queue with approve/deny UI
--      idle         : shows request, APPROVE / DENY buttons
--      pick_level   : number buttons 1-5
--      confirm_deny : confirmation before sending deny
--      waiting      : sent to server, awaiting ACK
-- ============================================================

local PROTOCOL    = "licensing_v1"
local ANNOUNCE_MS = 3000

-- ============================================================
--  REDNET
-- ============================================================
local function open_rednet()
  if rednet.isOpen() then return true end
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    pcall(rednet.open, side)
    if rednet.isOpen() then return true end
  end
  return false
end

assert(open_rednet(), "Tablet: no modem found. Attach a wireless modem.")

-- ============================================================
--  TERMINAL HELPERS
-- ============================================================
local W, H = term.getSize()

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

local function clear_screen()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

--- Write text centred on a given row.
local function center(row, text, fg, bg)
  local x = clamp(math.floor((W - #text) / 2) + 1, 1, W)
  term.setCursorPos(x, row)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(text)
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
end

--- Fill a rectangle with a background colour.
local function fill_rect(x1, y1, x2, y2, bg)
  term.setBackgroundColor(bg)
  for row = y1, y2 do
    term.setCursorPos(x1, row)
    term.write(string.rep(" ", x2 - x1 + 1))
  end
  term.setBackgroundColor(colors.black)
end

--- Draw a labelled button and return its hit-test table.
local function draw_button(x1, y1, x2, y2, label, bg, fg)
  bg = bg or colors.gray
  fg = fg or colors.white
  fill_rect(x1, y1, x2, y2, bg)

  local bw = x2 - x1 + 1
  local bh = y2 - y1 + 1
  local lx = x1 + math.floor((bw - #label) / 2)
  local ly = y1 + math.floor(bh / 2)

  term.setCursorPos(lx, ly)
  term.setBackgroundColor(bg)
  term.setTextColor(fg)
  term.write(label)
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)

  return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, label = label }
end

--- Returns true if (x, y) is inside button b.
local function hit(b, x, y)
  return b and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2
end

--- Normalise click events from both mouse and monitor.
local function click_pos(ev, ...)
  local args = { ... }
  if ev == "mouse_click"   then return args[2], args[3] end
  if ev == "monitor_touch" then return args[2], args[3] end
  return nil, nil
end

--- Wrap a string to a max width, returning a list of lines.
local function wrap(text, max_w)
  local lines = {}
  for word in text:gmatch("%S+") do
    if #lines == 0 then
      lines[1] = word
    elseif #lines[#lines] + 1 + #word <= max_w then
      lines[#lines] = lines[#lines] .. " " .. word
    else
      lines[#lines + 1] = word
    end
  end
  return lines
end

-- ============================================================
--  NETWORK STATE
-- ============================================================
local server_id    = nil
local last_announce = os.epoch("utc")

local function net_send(tbl)
  if not server_id then return end
  rednet.send(server_id, tbl, PROTOCOL)
end

local function announce()
  if server_id then
    rednet.send(server_id, { kind = "hello_tablet" }, PROTOCOL)
  else
    rednet.broadcast({ kind = "hello_tablet" }, PROTOCOL)
  end
  last_announce = os.epoch("utc")
end

-- ============================================================
--  APP STATE
-- ============================================================
local screen  = "home"    -- "home" | "licensing"
local mode    = "idle"    -- "idle" | "pick_level" | "confirm_deny" | "waiting"

local queue   = {}        -- pending approval_request messages
local active  = nil       -- currently displayed request
local badge   = 0         -- unread count shown on home screen

local pending_ack_id = nil  -- set while waiting for decision_ack

-- ============================================================
--  QUEUE MANAGEMENT
-- ============================================================
local function dequeue_next()
  if #queue > 0 and not active then
    active = table.remove(queue, 1)
    mode   = "idle"
    pending_ack_id = nil
  end
end

local function dismiss_active()
  active         = nil
  mode           = "idle"
  pending_ack_id = nil
  dequeue_next()
end

-- ============================================================
--  SEND DECISION
-- ============================================================
local function send_decision(approved, level)
  if not active or pending_ack_id then return end
  pending_ack_id = active.id
  mode = "waiting"
  net_send({
    kind     = "approval_response",
    id       = active.id,
    approved = approved and true or false,
    level    = level,
  })
end

-- ============================================================
--  SCREENS
-- ============================================================

--- Draw the home screen. Returns button table.
local function draw_home()
  clear_screen()
  W, H = term.getSize()

  center(1, "BASE TABLET", colors.white)

  -- status line
  term.setCursorPos(2, 2)
  term.setTextColor(colors.lightGray)
  term.write("Server: " .. (server_id and tostring(server_id) or "searching..."))
  term.setTextColor(colors.white)

  center(4, "APPS", colors.cyan)

  local bw   = math.min(22, W - 6)
  local bx1  = math.floor((W - bw) / 2) + 1
  local bx2  = bx1 + bw - 1
  local btns = {}

  btns.licensing = draw_button(bx1, 6, bx2, 8, "Licensing", colors.gray, colors.white)

  -- badge overlay
  if badge > 0 then
    local label = " " .. badge .. " "
    local blen  = #label
    local bx    = bx2 - blen + 1
    fill_rect(bx, 6, bx2, 6, colors.red)
    term.setCursorPos(bx, 6)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(label)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end

  -- hint
  term.setCursorPos(2, H)
  term.setTextColor(colors.lightGray)
  term.write("Open Licensing to approve or deny requests.")
  term.setTextColor(colors.white)

  return btns
end

--- Draw the licensing screen. Returns button table.
local function draw_licensing()
  clear_screen()
  W, H = term.getSize()

  -- header
  center(1, "LICENSING APPROVALS", colors.white)
  local btns = {}
  btns.back = { x1 = 1, y1 = 1, x2 = 6, y2 = 1 }
  term.setCursorPos(1, 1)
  term.setTextColor(colors.lightGray)
  term.write("<Back")
  term.setTextColor(colors.white)

  -- status
  term.setCursorPos(2, 2)
  term.setTextColor(colors.lightGray)
  term.write("Server: " .. (server_id and tostring(server_id) or "none")
    .. "  Queue: " .. #queue)
  term.setTextColor(colors.white)

  -- separator
  term.setCursorPos(1, 3)
  term.setTextColor(colors.gray)
  term.write(string.rep("-", W))
  term.setTextColor(colors.white)

  -- no active request
  if not active then
    center(math.floor(H / 2), "No pending requests.", colors.lightGray)
    return btns
  end

  -- request card
  local card_top = 4
  term.setCursorPos(2, card_top)
  term.setTextColor(colors.cyan)
  term.write("Pending Request")
  term.setTextColor(colors.white)

  local lines = {
    "Player : " .. tostring(active.requester),
    "Request: " .. tostring(active.request_text or active.request_kind or "?"),
    "ID     : " .. tostring(active.id):sub(1, W - 10),
  }
  local y = card_top + 1
  for _, ln in ipairs(lines) do
    term.setCursorPos(2, y)
    term.write(ln:sub(1, W - 2))
    y = y + 1
  end

  -- separator
  term.setCursorPos(1, y)
  term.setTextColor(colors.gray)
  term.write(string.rep("-", W))
  term.setTextColor(colors.white)
  y = y + 1

  local btn_top    = H - 4
  local btn_bottom = H - 2
  local half       = math.floor(W / 2)

  -- ---- WAITING FOR ACK ----
  if mode == "waiting" then
    center(btn_top - 1, "Sending decision, awaiting server ACK...", colors.yellow)
    return btns
  end

  -- ---- IDLE: show APPROVE / DENY ----
  if mode == "idle" then
    btns.approve = draw_button(2,        btn_top, half - 1,  btn_bottom, "APPROVE", colors.green, colors.white)
    btns.deny    = draw_button(half + 1, btn_top, W - 1,     btn_bottom, "DENY",    colors.red,   colors.white)

    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("A = approve    D = deny")
    term.setTextColor(colors.white)
    return btns
  end

  -- ---- PICK LEVEL (1-5) ----
  if mode == "pick_level" then
    center(btn_top - 1, "Select access level (1-5):", colors.yellow)

    local gap     = 1
    local n       = 5
    local usable  = W - 4
    local bw      = math.floor((usable - gap * (n - 1)) / n)
    bw = clamp(bw, 3, 10)
    local total   = bw * n + gap * (n - 1)
    local startX  = math.floor((W - total) / 2) + 1

    local x = startX
    for lvl = 1, 5 do
      local key = "lvl" .. lvl
      btns[key] = draw_button(x, btn_top, x + bw - 1, btn_bottom, tostring(lvl), colors.gray, colors.white)
      btns[key].level = lvl
      x = x + bw + gap
    end

    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("1-5 = select level    Esc = cancel")
    term.setTextColor(colors.white)
    return btns
  end

  -- ---- CONFIRM DENY ----
  if mode == "confirm_deny" then
    center(btn_top - 1, "Confirm: DENY this request?", colors.red)
    btns.cancel = draw_button(2,        btn_top, half - 1, btn_bottom, "CANCEL", colors.gray,  colors.white)
    btns.yes    = draw_button(half + 1, btn_top, W - 1,    btn_bottom, "DENY",   colors.red,   colors.white)

    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("Enter = confirm deny    Esc = cancel")
    term.setTextColor(colors.white)
    return btns
  end

  return btns
end

-- ============================================================
--  RENDER DISPATCHER
-- ============================================================
local function render()
  if screen == "home" then
    return draw_home()
  else
    return draw_licensing()
  end
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
announce()
local btns = render()

while true do
  -- periodic keepalive
  if os.epoch("utc") - last_announce >= ANNOUNCE_MS then
    announce()
  end

  local e = { os.pullEvent() }
  local ev = e[1]

  -- ---- NETWORK ----
  if ev == "rednet_message" then
    local sender, msg, proto = e[2], e[3], e[4]
    if proto == PROTOCOL and type(msg) == "table" then

      if msg.kind == "hello_server" then
        if server_id ~= sender then
          server_id = sender
        end

      elseif msg.kind == "approval_request" then
        if server_id ~= sender then server_id = sender end
        table.insert(queue, msg)
        badge = badge + 1
        dequeue_next()

      elseif msg.kind == "decision_ack" then
        if pending_ack_id and msg.id == pending_ack_id then
          pending_ack_id = nil
          if msg.ok then
            dismiss_active()
          else
            -- server rejected (e.g. id_mismatch) — let admin retry
            mode = "idle"
          end
        end
      end

      btns = render()
    end

  -- ---- CLICK / TOUCH ----
  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = click_pos(ev, table.unpack(e, 2))
    if x and y then

      if screen == "home" then
        if hit(btns.licensing, x, y) then
          screen = "licensing"
          badge  = 0
          dequeue_next()
          btns = render()
        end

      elseif screen == "licensing" then
        if hit(btns.back, x, y) then
          screen = "home"
          btns   = render()

        elseif active and mode ~= "waiting" then
          if mode == "idle" then
            if hit(btns.approve, x, y) then
              mode = "pick_level"
              btns = render()
            elseif hit(btns.deny, x, y) then
              mode = "confirm_deny"
              btns = render()
            end

          elseif mode == "pick_level" then
            for lvl = 1, 5 do
              if hit(btns["lvl" .. lvl], x, y) then
                send_decision(true, lvl)
                btns = render()
                break
              end
            end

          elseif mode == "confirm_deny" then
            if hit(btns.cancel, x, y) then
              mode = "idle"
              btns = render()
            elseif hit(btns.yes, x, y) then
              send_decision(false, nil)
              btns = render()
            end
          end
        end
      end
    end

  -- ---- KEYBOARD ----
  elseif ev == "char" then
    local ch = e[2]
    if screen == "licensing" and active and mode ~= "waiting" then
      if mode == "idle" then
        if ch == "a" or ch == "A" then
          mode = "pick_level"; btns = render()
        elseif ch == "d" or ch == "D" then
          mode = "confirm_deny"; btns = render()
        end
      elseif mode == "pick_level" then
        local lvl = tonumber(ch)
        if lvl and lvl >= 1 and lvl <= 5 then
          send_decision(true, lvl); btns = render()
        end
      end
    end

  elseif ev == "key" then
    local key = e[2]
    if key == keys.escape or key == keys.esc then
      if screen == "licensing" then
        if mode ~= "idle" and mode ~= "waiting" then
          mode = "idle"; btns = render()
        elseif mode == "idle" then
          screen = "home"; btns = render()
        end
      end
    elseif key == keys.enter or key == keys.numPadEnter then
      if screen == "licensing" and active and mode == "confirm_deny" then
        send_decision(false, nil); btns = render()
      end
    end
  end
end
