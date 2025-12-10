-- status_display.lua
-- PLC-style front panel for the fission reactor
-- No external graphics libs, only term/monitor.
-- Designed for a 3x3 advanced monitor (57x24).

----------------------------
-- CONFIG
----------------------------

local MONITOR_SIDE = "top"   -- monitor side
local MODEM_SIDE   = "back"  -- modem side

-- Status packets from the core:
-- {
--   type        = "status",
--   powered     = bool,
--   manualTrip  = bool,
--   autoTrip    = bool,
--   hiDamage    = bool,
--   hiTemp      = bool,
--   loFuel      = bool,
--   hiWaste     = bool,
--   loCCoolant  = bool,
--   hiHCoolant  = bool,
-- }
local STATUS_CHANNEL = 600

local HEARTBEAT_TIMEOUT = 20   -- seconds

----------------------------
-- PERIPHERALS
----------------------------

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then error("No monitor on side '" .. MONITOR_SIDE .. "'") end

mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.wrap(MODEM_SIDE)
if modem then
    if not modem.isOpen(STATUS_CHANNEL) then
        modem.open(STATUS_CHANNEL)
    end
end

----------------------------
-- STATE
----------------------------

local state = {
    heartbeat_ok = false,
    reactor_ok   = false,
    modem_ok     = modem ~= nil,
    network_ok   = modem ~= nil,

    manualTrip   = false,
    autoTrip     = false,

    hiDamage     = false,
    hiTemp       = false,
    loFuel       = false,
    hiWaste      = false,
    loCCoolant   = false,
    hiHCoolant   = false,
}

local last_heartbeat = 0

----------------------------
-- DRAW HELPERS
----------------------------

local function fill(x1, y1, x2, y2, bg)
    mon.setBackgroundColor(bg)
    for y = y1, y2 do
        mon.setCursorPos(x1, y)
        mon.write(string.rep(" ", x2 - x1 + 1))
    end
end

local function write_at(x, y, text, fg, bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x, y)
    mon.write(text)
end

-- 1x1 LED: a single space with background colour
local function led(x, y, on, color_on, color_off)
    color_on  = color_on  or colors.lime
    color_off = color_off or colors.gray
    mon.setBackgroundColor(on and color_on or color_off)
    mon.setCursorPos(x, y)
    mon.write(" ")
end

----------------------------
-- LAYOUT CONSTANTS
----------------------------

local BG_OUTER   = colors.yellow
local BG_MAIN    = colors.gray
local BG_PANEL   = colors.black
local BG_PANEL2  = colors.gray

local TITLE      = "FISSION REACTOR PLC - UNIT 1"

-- Left column baseline
local L_LED_X    = 6
local L_TEXT_X   = 9
local L_FIRST_Y  = 6

-- Right column baseline
local R_LED_X    = 37
local R_TEXT_X   = 40
local R_FIRST_Y  = 8

-- Center RPS TRIP panel
local RPS_W      = 17
local RPS_H      = 4
local RPS_Y      = 11
local RPS_X      = math.floor(W / 2 - RPS_W / 2)

----------------------------
-- STATIC BACKGROUND
----------------------------

local function draw_frame()
    -- outer yellow border
    mon.setBackgroundColor(BG_OUTER)
    mon.clear()

    -- inner dark main area
    fill(2, 2, W - 1, H - 1, BG_MAIN)

    -- inner darker panel where content lives
    fill(4, 4, W - 3, H - 3, BG_PANEL)

    -- top title strip
    fill(4, 4, W - 3, 5, BG_MAIN)
    local title_x = math.floor((W - #TITLE) / 2)
    write_at(title_x, 4, TITLE, colors.white, BG_MAIN)
end

local function draw_static_labels()
    -- left labels
    local y = L_FIRST_Y
    write_at(L_TEXT_X, y, "STATUS",    colors.white, BG_PANEL); y = y + 2
    write_at(L_TEXT_X, y, "HEARTBEAT", colors.white, BG_PANEL); y = y + 2
    write_at(L_TEXT_X, y, "REACTOR",   colors.white, BG_PANEL); y = y + 2
    write_at(L_TEXT_X, y, "MODEM (1)", colors.white, BG_PANEL); y = y + 2
    write_at(L_TEXT_X, y, "NETWORK",   colors.white, BG_PANEL)

    -- centre "RPS TRIP" caption above the box
    write_at(RPS_X + math.floor((RPS_W - #"RPS TRIP") / 2), RPS_Y - 1,
             "RPS TRIP", colors.white, BG_PANEL)

    -- right labels
    local y2 = R_FIRST_Y
    write_at(R_TEXT_X, y2, "MANUAL",    colors.white, BG_PANEL); y2 = y2 + 2
    write_at(R_TEXT_X, y2, "AUTOMATIC", colors.white, BG_PANEL); y2 = y2 + 3

    write_at(R_TEXT_X, y2, "HI DAMAGE", colors.white, BG_PANEL); y2 = y2 + 2
    write_at(R_TEXT_X, y2, "HI TEMP",   colors.white, BG_PANEL); y2 = y2 + 3

    write_at(R_TEXT_X, y2, "LO FUEL",   colors.white, BG_PANEL); y2 = y2 + 2
    write_at(R_TEXT_X, y2, "HI WASTE",  colors.white, BG_PANEL); y2 = y2 + 3

    write_at(R_TEXT_X, y2, "LO CCOOLANT", colors.white, BG_PANEL); y2 = y2 + 2
    write_at(R_TEXT_X, y2, "HI HCOOLANT", colors.white, BG_PANEL)
end

local function draw_static_panels()
    -- Left “group” bar background, just to visually echo the real PLC
    fill(5, 5, 26, 16, BG_PANEL)

    -- Right side background area
    fill(34, 6, W - 4, 18, BG_PANEL)

    -- RPS TRIP box (centre)
    fill(RPS_X, RPS_Y, RPS_X + RPS_W - 1, RPS_Y + RPS_H - 1, BG_PANEL2)
end

local function draw_static()
    draw_frame()
    draw_static_panels()
    draw_static_labels()
end

----------------------------
-- DYNAMIC LED DRAW
----------------------------

local function draw_leds()
    -- left LEDs
    local y = L_FIRST_Y
    led(L_LED_X, y, state.reactor_ok, colors.lime, colors.red); y = y + 2
    led(L_LED_X, y, state.heartbeat_ok, colors.lime, colors.red); y = y + 2
    led(L_LED_X, y, state.reactor_ok, colors.lime, colors.red); y = y + 2
    led(L_LED_X, y, state.modem_ok, colors.lime, colors.red);   y = y + 2
    led(L_LED_X, y, state.network_ok, colors.lime, colors.red)

    -- RPS TRIP centre block
    local trip_on = state.manualTrip or state.autoTrip
    local box_bg  = trip_on and colors.red or BG_PANEL2
    fill(RPS_X, RPS_Y, RPS_X + RPS_W - 1, RPS_Y + RPS_H - 1, box_bg)

    local label = trip_on and "TRIPPED" or "NORMAL"
    local lx    = RPS_X + math.floor((RPS_W - #label) / 2)
    local ly    = RPS_Y + math.floor(RPS_H / 2)
    write_at(lx, ly, label, colors.white, box_bg)

    -- right LEDs
    local y2 = R_FIRST_Y
    led(R_LED_X, y2, state.manualTrip, colors.red, colors.gray); y2 = y2 + 2
    led(R_LED_X, y2, state.autoTrip,   colors.red, colors.gray); y2 = y2 + 3

    led(R_LED_X, y2, state.hiDamage,   colors.red, colors.gray); y2 = y2 + 2
    led(R_LED_X, y2, state.hiTemp,     colors.red, colors.gray); y2 = y2 + 3

    led(R_LED_X, y2, state.loFuel,     colors.red, colors.gray); y2 = y2 + 2
    led(R_LED_X, y2, state.hiWaste,    colors.red, colors.gray); y2 = y2 + 3

    led(R_LED_X, y2, state.loCCoolant, colors.red, colors.gray); y2 = y2 + 2
    led(R_LED_X, y2, state.hiHCoolant, colors.red, colors.gray)
end

----------------------------
-- HEARTBEAT & PACKETS
----------------------------

local function update_heartbeat()
    if last_heartbeat <= 0 then
        state.heartbeat_ok = false
        return
    end
    local now = os.clock()
    if now - last_heartbeat > HEARTBEAT_TIMEOUT then
        state.heartbeat_ok = false
        state.network_ok   = false
    else
        state.heartbeat_ok = true
        state.network_ok   = true
    end
end

local function handle_status_packet(pkt)
    if type(pkt) ~= "table" then return end
    if pkt.type ~= "status" then return end

    last_heartbeat = os.clock()

    if pkt.powered ~= nil then
        state.reactor_ok = pkt.powered and not (pkt.manualTrip or pkt.autoTrip)
    end

    if pkt.manualTrip ~= nil then state.manualTrip = pkt.manualTrip end
    if pkt.autoTrip   ~= nil then state.autoTrip   = pkt.autoTrip   end

    if pkt.hiDamage   ~= nil then state.hiDamage   = pkt.hiDamage   end
    if pkt.hiTemp     ~= nil then state.hiTemp     = pkt.hiTemp     end
    if pkt.loFuel     ~= nil then state.loFuel     = pkt.loFuel     end
    if pkt.hiWaste    ~= nil then state.hiWaste    = pkt.hiWaste    end
    if pkt.loCCoolant ~= nil then state.loCCoolant = pkt.loCCoolant end
    if pkt.hiHCoolant ~= nil then state.hiHCoolant = pkt.hiHCoolant end
end

----------------------------
-- MAIN LOOP
----------------------------

local function main()
    draw_static()
    draw_leds()

    while true do
        update_heartbeat()
        draw_leds()

        local timeout = 0.5
        if modem then
            local e, side, ch, rch, msg, dist =
                os.pullEventTimeout("modem_message", timeout)
            if e == "modem_message" and ch == STATUS_CHANNEL then
                handle_status_packet(msg)
            end
        else
            sleep(timeout)
        end
    end
end

main()
