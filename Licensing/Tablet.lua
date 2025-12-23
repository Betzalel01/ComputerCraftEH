-- Licensing_Tablet.lua
-- Tablet UI wrapper (Home -> Licensing app)
-- Uses rednet.host/lookup (no binding/IDs). Clickable + typeable.

local PROTOCOL = "licensing_v1"

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

pcall(rednet.unhost, PROTOCOL, "licensing_tablet")
rednet.host(PROTOCOL, "licensing_tablet")

local function server_id() return rednet.lookup(PROTOCOL, "licensing_server") end

-------------------------
-- UI UTIL
-------------------------
local function clamp(n,a,b) if n<a then return a elseif n>b then return b else return n end end
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

local function hit(btn,x,y)
  return x>=btn.x1 and x<=btn.x2 and y>=btn.y1 and y<=btn.y2
end

local function normalize_click(ev,a,b,c)
  if ev=="mouse_click" then return b,c end
  if ev=="monitor_touch" then return b,c end
  return nil,nil
end

-------------------------
-- REDNET SEND
-------------------------
local function send(tbl)
  local sid = server_id()
  if not sid then return false end
  rednet.send(sid, tbl, PROTOCOL)
  return true
end

-------------------------
-- STATE
-------------------------
local screen = "home" -- home | licensing
local mode = "idle"   -- idle | approve_level | deny_level
local pending = {}
local active = nil
local badge = 0

local function next_request()
  active = nil
  mode = "idle"
end

-------------------------
-- RENDER HOME
-------------------------
local function render_home()
  clear()
  local w,h = termSize()

  centerText(1, "BASE TABLET", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Server: " .. tostring(server_id() or "nil"))
  term.setTextColor(colors.white)

  centerText(4, "APPS", colors.cyan)

  local btns = {}
  local bw = math.min(20, w-6)
  local bx1 = math.floor((w-bw)/2)+1
  local bx2 = bx1 + bw - 1
  btns.lic = {x1=bx1,y1=6,x2=bx2,y2=8,label="Licensing",bg=colors.gray,fg=colors.white}
  drawButton(btns.lic)

  if badge > 0 then
    local txt = tostring(badge)
    local bw2 = #txt + 2
    drawBox(btns.lic.x2-bw2+1, btns.lic.y1, btns.lic.x2, btns.lic.y1, colors.red)
    term.setCursorPos(btns.lic.x2-bw2+2, btns.lic.y1)
    term.setTextColor(colors.white)
    term.write(txt)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
  end

  return btns
end

-------------------------
-- RENDER LICENSING
-------------------------
local function render_licensing(status_line)
  clear()
  local w,h = termSize()

  centerText(1, "LICENSING APPROVALS", colors.white)
  term.setCursorPos(2,2)
  term.setTextColor(colors.lightGray)
  term.write("Rednet OK. Server: "..tostring(server_id() or "nil"))
  term.setTextColor(colors.white)

  local btns = {}
  btns.back = {x1=2,y1=1,x2=7,y2=1,label="<Back",bg=colors.black,fg=colors.lightGray}
  term.setCursorPos(btns.back.x1, btns.back.y1)
  term.setTextColor(btns.back.fg)
  term.write(btns.back.label)
  term.setTextColor(colors.white)

  if (not active) and (#pending>0) then
    active = table.remove(pending,1)
    mode = "idle"
  end

  if not active then
    centerText(math.floor(h/2), "No pending requests.", colors.lightGray)
    return btns
  end

  term.setCursorPos(3,4)
  term.setTextColor(colors.cyan) term.write("Pending Request")
  term.setTextColor(colors.white)
  term.setCursorPos(3,6) term.write("From: "..tostring(active.requester))
  term.setCursorPos(3,7) term.write("Text: "..tostring(active.request_text))
  term.setCursorPos(3,8) term.write("ID:   "..tostring(active.id))

  if status_line then
    term.setCursorPos(3, h-7)
    term.setTextColor(colors.lightGray)
    term.write(status_line:sub(1,w-4))
    term.setTextColor(colors.white)
  end

  if mode=="idle" then
    btns.approve = {x1=3,y1=h-5,x2=math.floor(w/2)-1,y2=h-3,label="APPROVE",bg=colors.green,fg=colors.black}
    btns.deny    = {x1=math.floor(w/2)+1,y1=h-5,x2=w-2,y2=h-3,label="DENY",bg=colors.red,fg=colors.white}
    drawButton(btns.approve)
    drawButton(btns.deny)
    term.setCursorPos(3,h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: A=approve  D=deny  Esc=back")
    term.setTextColor(colors.white)

  elseif mode=="approve_level" or mode=="deny_level" then
    centerText(h-6, mode=="approve_level" and "Select approval level (1-5)" or "Select deny level (1-5)", colors.yellow)

    local gap=1
    local usable = w - 4
    local bw = math.floor((usable - gap*4)/5)
    if bw < 5 then bw = 5 end
    local total = bw*5 + gap*4
    local startX = math.floor((w-total)/2)+1
    if startX < 2 then startX=2 end

    local x=startX
    for lvl=1,5 do
      btns["lvl"..lvl] = {x1=x,y1=h-5,x2=x+bw-1,y2=h-3,label=tostring(lvl),bg=colors.gray,fg=colors.white,level=lvl}
      drawButton(btns["lvl"..lvl])
      x = x + bw + gap
    end

    term.setCursorPos(3,h-2)
    term.setTextColor(colors.lightGray)
    term.write("Keys: 1-5 choose level  |  Esc cancel")
    term.setTextColor(colors.white)
  end

  return btns
end

-------------------------
-- MAIN LOOP
-------------------------
local btns = render_home()

while true do
  local e = { os.pullEvent() }
  local ev = e[1]

  if ev=="rednet_message" then
    local sender, msg, proto = e[2], e[3], e[4]
    if proto==PROTOCOL and type(msg)=="table" and msg.kind=="approval_request" then
      table.insert(pending, msg)
      badge = badge + 1
      if screen=="home" then btns = render_home() else btns = render_licensing() end
    end

  elseif ev=="mouse_click" or ev=="monitor_touch" then
    local x,y = normalize_click(ev, e[2], e[3], e[4])

    if screen=="home" then
      if btns.lic and hit(btns.lic,x,y) then
        screen="licensing"
        badge=0
        btns = render_licensing()
      end

    else -- licensing
      if btns.back and hit(btns.back,x,y) then
        screen="home"
        btns = render_home()
      elseif active then
        if mode=="idle" then
          if btns.approve and hit(btns.approve,x,y) then
            mode="approve_level"
            btns = render_licensing()
          elseif btns.deny and hit(btns.deny,x,y) then
            mode="deny_level"
            btns = render_licensing()
          end
        else
          for lvl=1,5 do
            local b = btns["lvl"..lvl]
            if b and hit(b,x,y) then
              if mode=="approve_level" then
                send({kind="approval_response", id=active.id, approved=true, level=lvl})
              else
                send({kind="approval_response", id=active.id, approved=false, level=lvl})
              end
              next_request()
              btns = render_licensing("Decision sent.")
              break
            end
          end
        end
      end
    end

  elseif ev=="char" then
    local ch = tostring(e[2])
    if screen=="licensing" and active then
      if mode=="idle" then
        if ch=="a" or ch=="A" then mode="approve_level"; btns=render_licensing()
        elseif ch=="d" or ch=="D" then mode="deny_level"; btns=render_licensing() end
      else
        local lvl = tonumber(ch)
        if lvl and lvl>=1 and lvl<=5 then
          if mode=="approve_level" then
            send({kind="approval_response", id=active.id, approved=true, level=lvl})
          else
            send({kind="approval_response", id=active.id, approved=false, level=lvl})
          end
          next_request()
          btns = render_licensing("Decision sent.")
        end
      end
    end

  elseif ev=="key" then
    local k = e[2]
    if k==keys.esc then
      if screen=="licensing" then
        if mode=="idle" then
          screen="home"; btns=render_home()
        else
          mode="idle"; btns=render_licensing()
        end
      end
    end
  end
end
