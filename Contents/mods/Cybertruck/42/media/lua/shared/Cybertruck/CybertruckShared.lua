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
    -- Single player can opt in to Options > Mods values (CybertruckOptions.lua).
    if Cybertruck.localOverride then
        local v = Cybertruck.localOverride(name)
        if v ~= nil then return v end
    end
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

---------------------------------------------------------------------------------------------------
-- Apocalypse fittings: blade kit, roof hatch, roof gun.
---------------------------------------------------------------------------------------------------

-- Front-right seat. The driver is seat 0.
Cybertruck.GUN_SEAT = 1
-- IsoTree.SIZE_JUMBO. Smaller trees come down. The giant ones stay.
Cybertruck.GIANT_TREE = 5
-- A zombie killed at or above this speed counts as a bumper kill for impact charging.
Cybertruck.KILL_SPEED = 12
-- Body half-extents in tiles (cybertruck.txt extents / 2). The blades reach past them.
Cybertruck.HALF_W = 0.434
Cybertruck.HALF_L = 1.093
-- A zombie beating on a door stands about 0.93 tiles off the centerline (measured in game).
Cybertruck.BLADE_REACH = 0.6
-- Roof gun: range and how far from the cursor it will look for a target, in tiles.
Cybertruck.GUN_RANGE = 22
Cybertruck.GUN_SNAP = 2.5
Cybertruck.GUN_COOLDOWN_MS = 150
Cybertruck.AMMO = "Base.556Bullets"
-- Below this the truck counts as stopped: the driver may take the gun.
Cybertruck.STOPPED_KMH = 3

function Cybertruck.installed(vehicle, id)
    local part = vehicle and vehicle:getPartById(id)
    return part ~= nil and part:getInventoryItem() ~= nil
end

function Cybertruck.gunReady(vehicle)
    return Cybertruck.installed(vehicle, "Sunroof") and Cybertruck.installed(vehicle, "Turret")
end

-- The driver's switch on the blade kit. Stored on the part so every client sees it.
function Cybertruck.bladesOn(vehicle)
    if not Cybertruck.installed(vehicle, "BladeKit") then return false end
    return vehicle:getPartById("BladeKit"):getModData().spin == true
end

-- Actually turning: switched on, motor running, charge in the pack.
function Cybertruck.bladesSpinning(vehicle)
    if not Cybertruck.bladesOn(vehicle) or not vehicle:isEngineRunning() then return false end
    local pack = Cybertruck.batteryPart(vehicle)
    return pack ~= nil and pack:getContainerContentAmount() > 0
end

function Cybertruck.stopped(vehicle)
    return math.abs(vehicle:getCurrentSpeedKmHour()) < Cybertruck.STOPPED_KMH
end

-- The gunner's seat always has the gun. The driver gets it only with the truck stopped.
function Cybertruck.canFire(vehicle, player)
    if not Cybertruck.is(vehicle) or not Cybertruck.gunReady(vehicle) then return false end
    local seat = vehicle:getSeat(player)
    return seat == Cybertruck.GUN_SEAT or (seat == 0 and Cybertruck.stopped(vehicle))
end

-- Zombie the roof gun locks onto. With an aim point: the one nearest the point, within GUN_SNAP.
-- Without one (controller): the nearest one in range. `visible` filters out what can't be seen.
function Cybertruck.pickTarget(vehicle, ax, ay, visible)
    local ox, oy = vehicle:getX(), vehicle:getY()
    local list = getCell():getZombieList()
    local best, bestScore
    local range2 = Cybertruck.GUN_RANGE * Cybertruck.GUN_RANGE
    local snap2 = Cybertruck.GUN_SNAP * Cybertruck.GUN_SNAP
    local vz = math.floor(vehicle:getZ())
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() and math.floor(z:getZ()) == vz then
            local dx, dy = z:getX() - ox, z:getY() - oy
            local d2 = dx * dx + dy * dy
            if d2 > 1.5 and d2 < range2 then
                local score
                if ax then
                    local sx, sy = z:getX() - ax, z:getY() - ay
                    score = sx * sx + sy * sy
                    if score > snap2 then score = nil end
                else
                    score = d2
                end
                if score and (not bestScore or score < bestScore) and (not visible or visible(z)) then
                    best, bestScore = z, score
                end
            end
        end
    end
    return best
end
