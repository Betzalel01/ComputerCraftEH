-- status_display.lua
-- PLC-style front panel for the fission reactor
-- Uses only vanilla term/monitor APIs (no external graphics libs).
-- Designed for a 3×3 advanced monitor that reports size 57×24.

----------------------------
-- CONFIG
----------------------------

local MONITOR_SIDE = "top"   -- monitor side
local MODEM_SIDE   = "back"  -- modem side (for heartbeat/status packets)

-- Channel to listen on for status packets from the core controller.
-- Expected packet format:
-- {
--   type        = "status",
--   powered     = true/false,   -- reactor actually running
--   manualTrip  = bool,
--   autoTrip    = bool,
--   hiDamage    = bool,
--   hiTemp      = bool,
--   loFuel      = bool,
--   hiWaste     = bool,
--   loCCoolant  = bool,
--   hiHCoolant  = bool,
-- }
-- Any missing field is simply ignored.
local STATUS_CHANNEL = 600

-- Seconds with no packet before heartbeat/network are considered failed
local HEARTBEAT_TIMEOUT = 20

----------------------------
-- PERIPHERALS
----------------------------

local mon = peripheral.wrap(MONITOR_SIDE)
if not mon then
    error("No monitor on side '" .. MONITOR_SIDE .. "'")
end

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

local function led(x, y, on, color_on, color_off)
    color_on  = color_on  or colors.lime
    color_off = color_off or colors.gray
    mon.setBackgroundColor(on and color_on or color_off)
    mon.setCursorPos(x, y)
    mon.write("  ")
end

----------------------------
-- LAYOUT CONSTANTS
----------------------------

local FRAME_BG   = colors.gray
local BORDER_COL = colors.yellow
local TITLE      = "FISSION REACTOR PLC - UNIT 1"

-- Left column
local L_BASE_X, L_BASE_Y = 4, 4
-- Right column
local R_BASE_X, R_BASE_Y = 34, 6
-- Center row for RPS TRIP block
local CENTER_Y = 11

----------------------------
-- STATIC BACKGROUND
----------------------------

local function draw_frame()
    -- outer border
    mon.setBackgroundColor(BORDER_COL)
    mon.clear()
    fill(2, 2, W - 1, H - 1, FRAME_BG)

    -- title bar
    fill(3, 3, W - 2, 4, FRAME_BG)
    local title_x = math.floor((W - #TITLE) / 2)
    write_at(title_x, 3, TITLE, colors.white, FRAME_BG)
end

local function draw_static_labels()
    mon.setTextColor(colors.white)

    -- left group
    local y = L_BASE_Y
    write_at(L_BASE_X + 3, y, "STATUS",    colors.white, FRAME_BG); y = y + 2
    write_at(L_BASE_X + 3, y, "HEARTBEAT", colors.white, FRAME_BG); y = y + 2
    write_at(L_BASE_X + 3, y, "REACTOR",   colors.white, FRAME_BG); y = y + 2
    write_at(L_BASE_X + 3, y, "MODEM (1)", colors.white, FRAME_BG); y = y + 2
    write_at(L_BASE_X + 3, y, "NETWORK",   colors.white, FRAME_BG)

    -- center label
    write_at(math.floor(W / 2) - 3, CENTER_Y - 1, "RPS TRIP", colors.white, FRAME_BG)

    -- right group
    local x  = R_BASE_X
    local y2 = R_BASE_Y
    write_at(x + 3, y2, "MANUAL",    colors.white, FRAME_BG); y2 = y2 + 2
    write_at(x + 3, y2, "AUTOMATIC", colors.white, FRAME_BG); y2 = y2 + 3

    write_at(x + 3, y2, "HI DAMAGE", colors.white, FRAME_BG); y2 = y2 + 2
    write_at(x + 3, y2, "HI TEMP",   colors.white, FRAME_BG); y2 = y2 + 3

    write_at(x + 3, y2, "LO FUEL",   colors.white, FRAME_BG); y2 = y2 + 2
    write_at(x + 3, y2, "HI WASTE",  colors.white, FRAME_BG); y2 = y2 + 3

    write_at(x + 3, y2, "LO CCOOLANT", colors.white, FRAME_BG); y2 = y2 + 2
    write_at(x + 3, y2, "HI HCOOLANT", colors.white, FRAME_BG)
end

local function draw_static()
    draw_frame()
    draw_static_labels()
end

----------------------------
-- DYNAMIC LED DRAW
----------------------------

local function draw_leds()
    -- left LEDs
    local x_led = L_BASE_X
    local y = L_BASE_Y

    -- STATUS = reactor OK (powered and not tripped)
    led(x_led, y, state.reactor_ok, colors.lime, colors.red); y = y + 2
    -- HEARTBEAT
    led(x_led, y, state.heartbeat_ok, colors.lime, colors.red); y = y + 2
    -- REACTOR (mirror STATUS for now)
    led(x_led, y, state.reactor_ok, colors.lime, colors.red); y = y + 2
    -- MODEM
    led(x_led, y, state.modem_ok, colors.lime, colors.red);   y = y + 2
    -- NETWORK
    led(x_led, y, state.network_ok, colors.lime, colors.red)

    -- center RPS TRIP block
    local trip_on = state.manualTrip or state.autoTrip
    local box_w   = 13
    local x1      = math.floor(W / 2 - box_w / 2)
    local x2      = x1 + box_w - 1
    local y1      = CENTER_Y
    local y2      = CENTER_Y + 2
    fill(x1, y1, x2, y2, trip_on and colors.red or colors.gray)
    write_at(
        x1 + 3, CENTER_Y + 1,
        trip_on and "TRIPPED" or "NORMAL",
        colors.white,
        trip_on and colors.red or colors.gray
    )

    -- right LEDs
    local x_r_led = R_BASE_X
    local yr      = R_BASE_Y

    led(x_r_led, yr, state.manualTrip, colors.red, colors.gray); yr = yr + 2
    led(x_r_led, yr, state.autoTrip,   colors.red, colors.gray); yr = yr + 3

    led(x_r_led, yr, state.hiDamage,   colors.red, colors.gray); yr = yr + 2
    led(x_r_led, yr, state.hiTemp,     colors.red, colors.gray); yr = yr + 3

    led(x_r_led, yr, state.loFuel,     colors.red, colors.gray); yr = yr + 2
    led(x_r_led, yr, state.hiWaste,    colors.red, colors.gray); yr = yr + 3

    led(x_r_led, yr, state.loCCoolant, colors.red, colors.gray); yr = yr + 2
    led(x_r_led, yr, state.hiHCoolant, colors.red, colors.gray)
end

----------------------------
-- HEARTBEAT HANDLING
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

----------------------------
-- PACKET HANDLING
----------------------------

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
