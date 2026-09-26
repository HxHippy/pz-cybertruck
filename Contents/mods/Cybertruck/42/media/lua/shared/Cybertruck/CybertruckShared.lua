-- Shared bits for the Cybertruck: what counts as one, sandbox lookups, and finding something to charge from.
Cybertruck = Cybertruck or {}
Cybertruck.Create = Cybertruck.Create or {}
Cybertruck.Update = Cybertruck.Update or {}

Cybertruck.SCRIPT = "Base.Cybertruck"
Cybertruck.CABLE_REACH = 12 -- tiles from the truck to a running generator
Cybertruck.OUTLET_REACH = 4 -- tiles from the truck to a powered building square

function Cybertruck.is(vehicle)
    return vehicle ~= nil and vehicle:getScriptName() == Cybertruck.SCRIPT
end

function Cybertruck.opt(name, default)
    local vars = SandboxVars and SandboxVars.Cybertruck
    if vars and vars[name] ~= nil then return vars[name] end
    return default
end

function Cybertruck.batteryPart(vehicle)
    local part = vehicle and vehicle:getPartById("GasTank")
    if part and part:getInventoryItem() then return part end
    return nil
end

function Cybertruck.chargePercent(part)
    local cap = part:getContainerCapacity()
    if cap <= 0 then return 0 end
    return math.floor(part:getContainerContentAmount() / cap * 100 + 0.5)
end

-- Returns "generator", generator  |  "grid"  |  nil
function Cybertruck.findCharger(vehicle)
    local sq = vehicle:getSquare()
    if not sq then return nil end
    local cell = getCell()
    local x0, y0, z = sq:getX(), sq:getY(), sq:getZ()

    local best, bestD
    local r = Cybertruck.opt("CableReach", Cybertruck.CABLE_REACH)
    for x = x0 - r, x0 + r do
        for y = y0 - r, y0 + r do
            local s = cell:getGridSquare(x, y, z)
            local gen = s and s:getGenerator()
            if gen and gen:isActivated() and gen:getFuel() > 0 then
                local d = (x - x0) * (x - x0) + (y - y0) * (y - y0)
                if d <= r * r and (not bestD or d < bestD) then
                    best, bestD = gen, d
                end
            end
        end
    end
    if best then return "generator", best end

    if Cybertruck.opt("GridCharging", true) then
        local g = Cybertruck.OUTLET_REACH
        for x = x0 - g, x0 + g do
            for y = y0 - g, y0 + g do
                local s = cell:getGridSquare(x, y, z)
                if s and s:getRoom() and s:hasGridPower() then return "grid" end
            end
        end
    end
    return nil
end
