-- Minimal stub databus for front_panel GUI only

local ps_stub = {}

-- front_panel just calls subscribe() via element:register(ps, key, cb)
function ps_stub.subscribe(_key, _cb)
    -- no-op: we are not wiring to a real SCADA backend yet
end

local databus = {
    ps = ps_stub
}

return databus
