-- status_display.lua
-- Standalone Fission Reactor PLC front-panel clone (display only)
-- Monitor is assumed to be attached on TOP of the computer.

-------------------------------------------------------
-- monitor / term setup
-------------------------------------------------------
local mon = peripheral.wrap("top")
if not mon then
    error("No monitor found on top side")
end

mon.setTextScale(0.5)
local oldTerm = term.current()
term.redirect(mon)

local w, h = term.getSize()

-------------------------------------------------------
-- colors & simple drawing helpers
-------------------------------------------------------
local COL_BG        = colors.gray
local COL_FRAME     = colors.lightGray
local COL_HEADER_BG = colors.gray
local COL_TEXT      = colors.white
local COL_TEXT_DIM  = colors.lightGray
local COL_LED_OFF   = colors.gray
local COL_LED_RED   = colors.red
local COL_LED_GRN   = colors.lime
local COL_LED_YEL   = colors.yellow
local COL_PANEL_DK  = colors.gray
local COL_PANEL_LT  = colors.lightGray

local function filled_rect(x, y, rw, rh, col)
    term.setBackgroundColor(col)
    for yy = y, y + rh - 1 do
        term.setCursorPos(x, yy)
        term.write(string.rep(" ", rw))
    end
end

local function frame_rect(x, y, rw, rh, borderCol, fillCol)
    if fillCol then
        filled_rect(x, y, rw, rh, fillCol)
    end
    term.setBackgroundColor(borderCol)
    -- top
    term.setCursorPos(x, y)
    term.write(string.rep(" ", rw))
    -- bottom
    term.setCursorPos(x, y + rh - 1)
    term.write(string.rep(" ", rw))
    -- sides
    for yy = y + 1, y + rh - 2 do
        term.setCursorPos(x, yy)
        term.write(" ")
        term.setCursorPos(x + rw - 1, yy)
        term.write(" ")
    end
end

local function write_text(x, y, s, fg, bg)
    term.setTextColor(fg or COL_TEXT)
    term.setBackgroundColor(bg or COL_BG)
    term.setCursorPos(x, y)
    term.write(s)
end

local function center_text(y, s, fg, bg)
    local x = math.floor((w - #s) / 2) + 1
    write_text(x, y, s, fg, bg)
end

-- LED: 2x1 colored block + label beginning at x+3
local function draw_led(x, y, label, col)
    term.setBackgroundColor(col)
    term.setCursorPos(x, y)
    term.write("  ")
    term.setBackgroundColor(COL_BG)
    term.setTextColor(COL_TEXT)
    term.setCursorPos(x + 3, y)
    term.write(label)
end

-- single colored bullet only (no label)
local function led_only(x, y, col)
    term.setBackgroundColor(col)
    term.setCursorPos(x, y)
    term.write("  ")
end

-------------------------------------------------------
-- static frame & layout
-------------------------------------------------------
local function draw_static_frame()
    term.setBackgroundColor(COL_BG)
    term.clear()

    -- outer frame
    frame_rect(1, 1, w, h, COL_FRAME, COL_BG)

    -- main inner background
    filled_rect(2, 2, w - 2, h - 2, COL_BG)

    -- header band
    filled_rect(3, 2, w - 4, 1, COL_HEADER_BG)
    center_text(2, "FISSION REACTOR PLC - UNIT 1", COL_TEXT, COL_HEADER_BG)

    -- left “system” background block (for appearance)
    filled_rect(3, 4, 24, 16, COL_BG)

    -- middle top reactor status panel (RCT ACTIVE / EMER COOLANT)
    filled_rect(29, 4, 25, 3, COL_PANEL_DK)

    -- RPS TRIP banner area
    filled_rect(29, 7, 25, 3, COL_PANEL_LT)

    -- SCRAM / RESET panel
    filled_rect(29, 10, 25, 4, COL_PANEL_LT)

    -- right RPS fault list area
    filled_rect(37, 4, 18, 16, COL_PANEL_DK)

    -- footer version text
    write_text(4, h - 1, "FW: v1.9.1", COL_TEXT_DIM, COL_BG)
    write_text(4, h,     "NT: v3.0.8", COL_TEXT_DIM, COL_BG)
end

-------------------------------------------------------
-- dynamic contents (LEDs etc.)
-------------------------------------------------------
local state = {
    heartbeat_on  = false,
    rps_trip      = false,
    rct_active    = false,
    emer_coolant  = false,

    -- left group
    status_on     = true,
    reactor_on    = true,
    modem_on      = true,
    network_on    = false,
    rt_main_on    = true,
    rt_rps_on     = true,
    rt_tx_on      = true,
    rt_rx_on      = true,
    rt_spctl_on   = true,

    -- RPS cause flags (for now only some demo ones)
    cause_manual  = false,
    cause_auto    = true,
    cause_timeout = false,
    cause_plcflt  = false,
    cause_rctflt  = true,
    cause_damage  = false,
    cause_temp    = false,
    cause_lofuel  = false,
    cause_waste   = false,
    cause_locool  = false,
    cause_hicool  = false,
}

local function draw_contents()
    -- LEFT COLUMN --------------------------------------------------------
    local lx = 5
    local y  = 5

    draw_led(lx, y, "STATUS",      state.status_on   and COL_LED_GRN or COL_LED_RED)
    y = y + 1
    draw_led(lx, y, "HEARTBEAT",   state.heartbeat_on and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "REACTOR",     state.reactor_on  and COL_LED_YEL or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "MODEM (1)",   state.modem_on    and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "NETWORK",     state.network_on  and COL_LED_GRN or COL_LED_OFF)

    y = y + 1
    draw_led(lx, y, "RT MAIN",     state.rt_main_on  and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "RT RPS",      state.rt_rps_on   and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "RT COMMS TX", state.rt_tx_on    and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "RT COMMS RX", state.rt_rx_on    and COL_LED_GRN or COL_LED_OFF)
    y = y + 1
    draw_led(lx, y, "RT SPCTL",    state.rt_spctl_on and COL_LED_GRN or COL_LED_OFF)

    -- MIDDLE TOP (RCT ACTIVE / EMER COOLANT) ----------------------------
    local mx = 31
    local my = 5
    draw_led(mx,   my,   "RCT ACTIVE",   state.rct_active   and COL_LED_GRN or COL_LED_OFF)
    draw_led(mx,   my+1, "EMER COOLANT", state.emer_coolant and COL_LED_YEL or COL_LED_OFF)

    -- RPS TRIP banner ----------------------------------------------------
    center_text(8, "RPS TRIP", COL_TEXT, COL_PANEL_LT)
    -- small LED at banner left
    led_only(30, 8, state.rps_trip and COL_LED_RED or COL_LED_OFF)

    -- SCRAM / RESET buttons (visual only) -------------------------------
    local btnW = 9
    local btnH = 3
    local totalW = btnW * 2 + 3
    local startX = math.floor((w - totalW) / 2) + 1
    local btnY = 11

    -- SCRAM
    filled_rect(startX, btnY, btnW, btnH, COL_LED_RED)
    write_text(startX + math.floor((btnW - 5)/2), btnY + 1, "SCRAM", colors.black, COL_LED_RED)

    -- RESET
    local resetX = startX + btnW + 3
    filled_rect(resetX, btnY, btnW, btnH, COL_LED_YEL)
    write_text(resetX + math.floor((btnW - 5)/2), btnY + 1, "RESET", colors.black, COL_LED_YEL)

    -- RIGHT COLUMN (RPS causes) -----------------------------------------
    local rx = 39
    local ry = 5

    draw_led(rx, ry,   "MANUAL",      state.cause_manual  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "AUTOMATIC",   state.cause_auto    and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "TIMEOUT",     state.cause_timeout and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "PLC FAULT",   state.cause_plcflt  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "RCT FAULT",   state.cause_rctflt  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 2
    draw_led(rx, ry,   "HI DAMAGE",   state.cause_damage  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "HI TEMP",     state.cause_temp    and COL_LED_RED or COL_LED_OFF)
    ry = ry + 2
    draw_led(rx, ry,   "LO FUEL",     state.cause_lofuel  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "HI WASTE",    state.cause_waste   and COL_LED_RED or COL_LED_OFF)
    ry = ry + 2
    draw_led(rx, ry,   "LO CCOOLANT", state.cause_locool  and COL_LED_RED or COL_LED_OFF)
    ry = ry + 1
    draw_led(rx, ry,   "HI HCOOLANT", state.cause_hicool  and COL_LED_RED or COL_LED_OFF)
end

-------------------------------------------------------
-- initial draw
-------------------------------------------------------
draw_static_frame()
draw_contents()

-------------------------------------------------------
-- simple heartbeat animation loop
-- (purely cosmetic for now; Ctrl+T to stop)
-------------------------------------------------------
local heartbeat_period = 0.8  -- seconds

local timer = os.startTimer(heartbeat_period)

while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == timer then
        state.heartbeat_on = not state.heartbeat_on
        draw_contents()
        timer = os.startTimer(heartbeat_period)
    end
end

-- (term is intentionally left redirected to the monitor
--  while the panel is running)
