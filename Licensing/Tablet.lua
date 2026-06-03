-- ============================================================
--  XLicensing_Tablet.lua  |  TABLET / COMPUTER (admin UI)
--  Version: v2.0.0
--
--  Screens / navigation:
--    home          - app launcher grid with badge overlays
--    licensing     - approval request queue (unchanged)
--    reactor       - subsystem list for the reactor
--    reactor.gates - live gate status + control buttons
--
--  Adding a new top-level app:
--    1. Add an entry to APPS table (id, label, screen, color).
--    2. Add a draw_<screen>() function.
--    3. Add a click handler block for the screen in the click
--       section of the main loop.
--    4. That's it — home screen, badge, and navigation are
--       handled automatically.
--
--  Adding a new reactor subsystem:
--    1. Add an entry to REACTOR_SECTIONS table.
--    2. Add a draw_reactor_<id>() function.
--    3. Add a click handler block for "reactor.<id>".
--
--  PROTOCOLS
--    licensing_v1 : approval workflow (unchanged)
--    gate_v1      : gate commands and state broadcasts
--
--  CHANGELOG
--  v2.0.0 - Refactored home screen into a data-driven app
--           registry (APPS table) so adding future apps requires
--           no changes to draw/click logic.
--           Added Reactor app with Gates subsection: live gate
--           open/closed + cooldown display, toggle buttons for
--           each gate, Open All, Lockdown On/Off buttons.
--           Added gate_v1 protocol handler for state broadcasts
--           and command sending.
-- ============================================================

local LIC_PROTO  = "licensing_v1"
local GATE_PROTO = "gate_v1"
local ANNOUNCE_MS = 3000

-- ============================================================
--  REDNET
-- ============================================================
local function open_rednet()
  if rednet.isOpen() then return true end
  for _, side in ipairs({ "left","right","top","bottom","front","back" }) do
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

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

local function clear_screen()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function center(row, text, fg, bg)
  local x = clamp(math.floor((W - #text) / 2) + 1, 1, W)
  term.setCursorPos(x, row)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(text)
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
end

local function fill_rect(x1, y1, x2, y2, bg)
  term.setBackgroundColor(bg)
  for row = y1, y2 do
    term.setCursorPos(x1, row)
    term.write(string.rep(" ", x2 - x1 + 1))
  end
  term.setBackgroundColor(colors.black)
end

local function draw_button(x1, y1, x2, y2, label, bg, fg)
  bg = bg or colors.gray
  fg = fg or colors.white
  fill_rect(x1, y1, x2, y2, bg)
  local lx = x1 + math.floor((x2 - x1 + 1 - #label) / 2)
  local ly = y1 + math.floor((y2 - y1) / 2)
  term.setCursorPos(lx, ly)
  term.setBackgroundColor(bg)
  term.setTextColor(fg)
  term.write(label)
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
  return { x1=x1, y1=y1, x2=x2, y2=y2, label=label }
end

local function hit(b, x, y)
  return b and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2
end

local function click_pos(ev, ...)
  local a = { ... }
  if ev == "mouse_click"   then return a[2], a[3] end
  if ev == "monitor_touch" then return a[2], a[3] end
  return nil, nil
end

-- Draw a standard back link in top-left; returns its hit region.
local function draw_back()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.lightGray)
  term.write("<Back")
  term.setTextColor(colors.white)
  return { x1=1, y1=1, x2=5, y2=1 }
end

-- Draw a standard screen header and status bar.
local function draw_header(title, status_text)
  center(1, title, colors.white)
  term.setCursorPos(2, 2)
  term.setTextColor(colors.lightGray)
  term.write(status_text)
  term.setTextColor(colors.white)
  term.setCursorPos(1, 3)
  term.setTextColor(colors.gray)
  term.write(string.rep("-", W))
  term.setTextColor(colors.white)
end

-- ============================================================
--  APP REGISTRY
--  Each entry defines a home-screen app button.
--    id     : unique string; also used as the screen name
--    label  : text shown on the button
--    color  : button background color
--    badge  : function() -> number  (0 = no badge)
-- ============================================================
local function licensing_badge() return 0 end  -- updated by runtime below

local APPS = {
  { id="licensing", label="Licensing", color=colors.gray,  badge=function() return licensing_badge() end },
  { id="reactor",   label="Reactor",   color=colors.cyan,  badge=function() return 0 end },
}

-- ============================================================
--  REACTOR SECTIONS
--  Each entry defines a button in the Reactor subsystem list.
--    id    : appended to "reactor." to form the screen name
--    label : button text
--    color : button background color
-- ============================================================
local REACTOR_SECTIONS = {
  { id="gates", label="Gates", color=colors.orange },
}

-- ============================================================
--  NETWORK STATE
-- ============================================================
local server_id     = nil   -- licensing server
local gate_id       = nil   -- gate controller computer
local last_announce = os.epoch("utc")

-- Gate state received from GateController broadcasts
local gate_state = {
  gate_open    = { false, false, false, false },
  lockdown     = false,
  cooldown_rem = { 0, 0, 0, 0 },
}

local function net_send_lic(tbl)
  if not server_id then return end
  rednet.send(server_id, tbl, LIC_PROTO)
end

local function net_send_gate(tbl)
  if not gate_id then
    rednet.broadcast(tbl, GATE_PROTO)
  else
    rednet.send(gate_id, tbl, GATE_PROTO)
  end
end

local function announce()
  if server_id then
    rednet.send(server_id, { kind="hello_tablet" }, LIC_PROTO)
  else
    rednet.broadcast({ kind="hello_tablet" }, LIC_PROTO)
  end
  -- Also broadcast to discover gate controller
  rednet.broadcast({ kind="hello_tablet" }, GATE_PROTO)
  last_announce = os.epoch("utc")
end

-- ============================================================
--  APP STATE
-- ============================================================
local screen  = "home"
local mode    = "idle"

local queue   = {}
local active  = nil
local _badge  = 0

local pending_ack_id = nil

-- Patch the badge function to read live value
licensing_badge = function() return _badge end

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
  active = nil; mode = "idle"; pending_ack_id = nil
  dequeue_next()
end

local function send_decision(approved, level)
  if not active or pending_ack_id then return end
  pending_ack_id = active.id
  mode = "waiting"
  net_send_lic({
    kind=    "approval_response",
    id=      active.id,
    approved= approved and true or false,
    level=   level,
  })
end

-- ============================================================
--  SCREEN: HOME
-- ============================================================
local function draw_home()
  clear_screen()
  W, H = term.getSize()

  center(1, "BASE TABLET", colors.white)
  term.setCursorPos(2, 2)
  term.setTextColor(colors.lightGray)
  term.write("Server: " .. (server_id and tostring(server_id) or "searching..."))
  term.setTextColor(colors.white)
  center(4, "APPS", colors.cyan)

  local btns   = {}
  local bw     = math.min(22, W - 6)
  local bx1    = math.floor((W - bw) / 2) + 1
  local bx2    = bx1 + bw - 1
  local row    = 6

  for _, app in ipairs(APPS) do
    btns[app.id] = draw_button(bx1, row, bx2, row + 2, app.label, app.color, colors.white)

    -- Badge overlay
    local n = app.badge()
    if n > 0 then
      local lbl = " " .. n .. " "
      local blen = #lbl
      local badgex = bx2 - blen + 1
      fill_rect(badgex, row, bx2, row, colors.red)
      term.setCursorPos(badgex, row)
      term.setBackgroundColor(colors.red)
      term.setTextColor(colors.white)
      term.write(lbl)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
    end

    row = row + 4
  end

  term.setCursorPos(2, H)
  term.setTextColor(colors.lightGray)
  term.write("Select an app to continue.")
  term.setTextColor(colors.white)
  return btns
end

-- ============================================================
--  SCREEN: LICENSING  (unchanged from v1.x)
-- ============================================================
local function draw_licensing()
  clear_screen()
  W, H = term.getSize()
  center(1, "LICENSING APPROVALS", colors.white)
  local btns = {}
  btns.back = draw_back()
  draw_header("LICENSING APPROVALS",
    "Server: " .. (server_id and tostring(server_id) or "none")
    .. "  Queue: " .. #queue)

  if not active then
    center(math.floor(H / 2), "No pending requests.", colors.lightGray)
    return btns
  end

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
    term.setCursorPos(2, y); term.write(ln:sub(1, W - 2)); y = y + 1
  end
  term.setCursorPos(1, y)
  term.setTextColor(colors.gray)
  term.write(string.rep("-", W))
  term.setTextColor(colors.white)
  y = y + 1

  local btn_top    = H - 4
  local btn_bottom = H - 2
  local half       = math.floor(W / 2)

  if mode == "waiting" then
    center(btn_top - 1, "Sending decision, awaiting server ACK...", colors.yellow)
    return btns
  end

  if mode == "idle" then
    btns.approve = draw_button(2, btn_top, half - 1, btn_bottom, "APPROVE", colors.green, colors.white)
    btns.deny    = draw_button(half + 1, btn_top, W - 1, btn_bottom, "DENY", colors.red, colors.white)
    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("A = approve    D = deny")
    term.setTextColor(colors.white)
    return btns
  end

  if mode == "pick_level" then
    center(btn_top - 1, "Select access level (1-5):", colors.yellow)
    local gap=1; local n=5; local usable=W-4
    local bw2 = clamp(math.floor((usable - gap*(n-1))/n), 3, 10)
    local total = bw2*n + gap*(n-1)
    local startX = math.floor((W-total)/2)+1
    local x = startX
    for lvl = 1, 5 do
      local key = "lvl"..lvl
      btns[key] = draw_button(x, btn_top, x+bw2-1, btn_bottom, tostring(lvl), colors.gray, colors.white)
      btns[key].level = lvl
      x = x + bw2 + gap
    end
    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("1-5 = select level    Esc = cancel")
    term.setTextColor(colors.white)
    return btns
  end

  if mode == "confirm_deny" then
    center(btn_top - 1, "Confirm: DENY this request?", colors.red)
    btns.cancel = draw_button(2, btn_top, half-1, btn_bottom, "CANCEL", colors.gray, colors.white)
    btns.yes    = draw_button(half+1, btn_top, W-1, btn_bottom, "DENY", colors.red, colors.white)
    term.setCursorPos(2, H)
    term.setTextColor(colors.lightGray)
    term.write("Enter = confirm deny    Esc = cancel")
    term.setTextColor(colors.white)
    return btns
  end

  return btns
end

-- ============================================================
--  SCREEN: REACTOR  (subsystem list)
-- ============================================================
local function draw_reactor()
  clear_screen()
  W, H = term.getSize()
  local btns = {}
  btns.back = draw_back()
  draw_header("REACTOR", "Select a subsystem")

  local bw   = math.min(22, W - 6)
  local bx1  = math.floor((W - bw) / 2) + 1
  local bx2  = bx1 + bw - 1
  local row  = 5

  for _, sec in ipairs(REACTOR_SECTIONS) do
    btns[sec.id] = draw_button(bx1, row, bx2, row + 2, sec.label, sec.color, colors.white)
    row = row + 4
  end

  return btns
end

-- ============================================================
--  SCREEN: REACTOR > GATES
-- ============================================================
local GATE_NAME = { "Gate 1", "Gate 2", "Gate 3", "Gate 4" }

local function draw_reactor_gates()
  clear_screen()
  W, H = term.getSize()
  local btns = {}
  btns.back = draw_back()
  draw_header("REACTOR > GATES",
    "GateCtrl: " .. (gate_id and tostring(gate_id) or "searching..."))

  -- Gate status rows (rows 4-7)
  for g = 1, 4 do
    local open = gate_state.gate_open[g]
    local cd   = gate_state.cooldown_rem[g] or 0
    local locked = gate_state.lockdown

    -- State label
    local state_label, state_col
    if locked then
      state_label = "LOCKED"; state_col = colors.orange
    elseif open then
      state_label = "OPEN  "; state_col = colors.green
    else
      state_label = "closed"; state_col = colors.lightGray
    end

    local row = 3 + g
    term.setCursorPos(2, row)
    term.setTextColor(colors.white)
    term.write(GATE_NAME[g] .. ": ")
    term.setTextColor(state_col)
    term.write(state_label)
    term.setTextColor(colors.white)

    if cd > 0 then
      term.setTextColor(colors.yellow)
      term.write(" [" .. cd .. "s]")
      term.setTextColor(colors.white)
    end

    -- Toggle button (right side of row)
    local btn_label = open and "Close" or "Open"
    local btn_col   = locked and colors.gray or (open and colors.red or colors.green)
    local bx1 = W - 8
    btns["gate"..g] = draw_button(bx1, row, W - 1, row, btn_label, btn_col, colors.white)
  end

  -- Separator
  term.setCursorPos(1, 9)
  term.setTextColor(colors.gray)
  term.write(string.rep("-", W))
  term.setTextColor(colors.white)

  -- Global controls (rows 10-12)
  local half = math.floor(W / 2)

  if gate_state.lockdown then
    btns.lockdown_off = draw_button(2, 10, W - 1, 12, "RELEASE LOCKDOWN", colors.orange, colors.white)
  else
    btns.open_all    = draw_button(2,        10, half - 1, 12, "OPEN ALL",  colors.green, colors.white)
    btns.lockdown_on = draw_button(half + 1, 10, W - 1,    12, "LOCKDOWN",  colors.red,   colors.white)
  end

  -- Hint
  term.setCursorPos(2, H)
  term.setTextColor(colors.lightGray)
  term.write(gate_id and "Commands sent directly to gate ctrl." or "Searching for gate controller...")
  term.setTextColor(colors.white)

  return btns
end

-- ============================================================
--  RENDER DISPATCHER
-- ============================================================
local function render()
  if screen == "home"          then return draw_home()          end
  if screen == "licensing"     then return draw_licensing()     end
  if screen == "reactor"       then return draw_reactor()       end
  if screen == "reactor.gates" then return draw_reactor_gates() end
  -- Fallback
  clear_screen()
  center(math.floor(H/2), "Unknown screen: " .. screen, colors.red)
  return {}
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
announce()
local btns = render()

while true do
  if os.epoch("utc") - last_announce >= ANNOUNCE_MS then announce() end

  local e  = { os.pullEvent() }
  local ev = e[1]

  -- ---- NETWORK ----
  if ev == "rednet_message" then
    local sender, msg, proto = e[2], e[3], e[4]

    -- Licensing protocol
    if proto == LIC_PROTO and type(msg) == "table" then
      if msg.kind == "hello_server" then
        server_id = sender

      elseif msg.kind == "approval_request" then
        if server_id ~= sender then server_id = sender end
        table.insert(queue, msg)
        _badge = _badge + 1
        dequeue_next()

      elseif msg.kind == "decision_ack" then
        if pending_ack_id and msg.id == pending_ack_id then
          pending_ack_id = nil
          if msg.ok then dismiss_active() else mode = "idle" end
        end
      end
      btns = render()
    end

    -- Gate protocol
    if proto == GATE_PROTO and type(msg) == "table" then
      if msg.kind == "gate_state" then
        gate_id = sender
        gate_state.gate_open    = msg.gate_open    or gate_state.gate_open
        gate_state.lockdown     = msg.lockdown     or false
        gate_state.cooldown_rem = msg.cooldown_rem or gate_state.cooldown_rem
        btns = render()
      end
    end

  -- ---- CLICK / TOUCH ----
  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = click_pos(ev, table.unpack(e, 2))
    if x and y then

      -- HOME
      if screen == "home" then
        for _, app in ipairs(APPS) do
          if hit(btns[app.id], x, y) then
            screen = app.id
            if screen == "licensing" then _badge = 0; dequeue_next() end
            btns = render()
            break
          end
        end

      -- LICENSING
      elseif screen == "licensing" then
        if hit(btns.back, x, y) then screen = "home"; btns = render()
        elseif active and mode ~= "waiting" then
          if mode == "idle" then
            if hit(btns.approve, x, y) then mode = "pick_level"; btns = render()
            elseif hit(btns.deny, x, y) then mode = "confirm_deny"; btns = render() end
          elseif mode == "pick_level" then
            for lvl = 1, 5 do
              if hit(btns["lvl"..lvl], x, y) then send_decision(true, lvl); btns = render(); break end
            end
          elseif mode == "confirm_deny" then
            if hit(btns.cancel, x, y) then mode = "idle"; btns = render()
            elseif hit(btns.yes, x, y) then send_decision(false, nil); btns = render() end
          end
        end

      -- REACTOR
      elseif screen == "reactor" then
        if hit(btns.back, x, y) then screen = "home"; btns = render()
        else
          for _, sec in ipairs(REACTOR_SECTIONS) do
            if hit(btns[sec.id], x, y) then
              screen = "reactor." .. sec.id
              btns = render()
              break
            end
          end
        end

      -- REACTOR > GATES
      elseif screen == "reactor.gates" then
        if hit(btns.back, x, y) then
          screen = "reactor"; btns = render()
        elseif not gate_state.lockdown then
          -- Individual gate toggles
          for g = 1, 4 do
            if hit(btns["gate"..g], x, y) then
              net_send_gate({ kind="gate_cmd", cmd="toggle", gate=g })
              break
            end
          end
          if hit(btns.open_all, x, y) then
            net_send_gate({ kind="gate_cmd", cmd="open_all" })
          elseif hit(btns.lockdown_on, x, y) then
            net_send_gate({ kind="gate_cmd", cmd="lockdown_on" })
          end
        else
          -- Lockdown active: only release button shown
          if hit(btns.lockdown_off, x, y) then
            net_send_gate({ kind="gate_cmd", cmd="lockdown_off" })
          end
        end
        btns = render()
      end
    end

  -- ---- KEYBOARD ----
  elseif ev == "char" then
    local ch = e[2]
    if screen == "licensing" and active and mode ~= "waiting" then
      if mode == "idle" then
        if ch == "a" or ch == "A" then mode = "pick_level"; btns = render()
        elseif ch == "d" or ch == "D" then mode = "confirm_deny"; btns = render() end
      elseif mode == "pick_level" then
        local lvl = tonumber(ch)
        if lvl and lvl >= 1 and lvl <= 5 then send_decision(true, lvl); btns = render() end
      end
    end

  elseif ev == "key" then
    local key = e[2]
    if key == keys.escape or key == keys.esc then
      if screen == "licensing" then
        if mode ~= "idle" and mode ~= "waiting" then mode = "idle"; btns = render()
        elseif mode == "idle" then screen = "home"; btns = render() end
      elseif screen == "reactor" then
        screen = "home"; btns = render()
      elseif screen == "reactor.gates" then
        screen = "reactor"; btns = render()
      end
    elseif key == keys.enter or key == keys.numPadEnter then
      if screen == "licensing" and active and mode == "confirm_deny" then
        send_decision(false, nil); btns = render()
      end
    end
  end
end
