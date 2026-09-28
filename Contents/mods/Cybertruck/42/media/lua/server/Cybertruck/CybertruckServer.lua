-- Cybertruck: drive battery, charging, armor, world spawns and the build recipe.
require "Cybertruck/CybertruckShared"
require "Cybertruck/CybertruckTuning"
require "Vehicles/Vehicles"

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

---------------------------------------------------------------------------------------------------
-- Drive battery (the GasTank part)
---------------------------------------------------------------------------------------------------

function Cybertruck.Create.BatteryPack(vehicle, part)
    local item = VehicleUtils.createPartInventoryItem(part)
    if not item then return end
    local cap = part:getContainerCapacity()
    if SandboxVars.VehicleEasyUse then
        part:setContainerContentAmount(cap)
    else
        -- Parked since the outbreak: somewhere in the sandbox range.
        local lo = Cybertruck.opt("SpawnChargeMin", 30)
        local hi = math.max(lo, Cybertruck.opt("SpawnChargeMax", 90))
        part:setContainerContentAmount(cap * (lo + ZombRand(hi - lo + 1)) / 100)
    end
end

-- Part updates also run on trucks out of range, where the engine hands Lua a VirtualVehicle: a
-- stand-in with the position, engine state and part sync, but no parts lookup, mod data or tuning.
local function isReal(vehicle) return instanceof(vehicle, "BaseVehicle") end

-- Draw per game minute. Idles almost free, scales with speed, heater and lights add a little.
local function drainRate(vehicle)
    local speed = math.abs(vehicle:getCurrentSpeedKmHour())
    local rate = 0.002 + 0.00025 * speed
    local heater = isReal(vehicle) and vehicle:getHeater() or nil
    if heater and heater:getModData().active then rate = rate + 0.004 end
    if vehicle:getHeadlightsOn() then rate = rate + 0.0008 end
    return rate * (SandboxVars.CarGasConsumption or 1.0) * Cybertruck.opt("BatteryDrain", 1.0)
end

local function unplug(md)
    md.plugged = nil
    md.chargeAcc = nil
end

-- Returns the new charge after charging for `minutes`, spending generator fuel as it goes.
local function charge(vehicle, part, amount, minutes)
    local md = part:getModData()
    local cap = part:getContainerCapacity()
    if amount >= cap then return amount end

    local kind, gen = Cybertruck.findCharger(vehicle)
    if not kind then
        unplug(md) -- cable doesn't reach anything live any more
        return amount
    end

    local add = cap / (Cybertruck.opt("ChargeHours", 10) * 60) * minutes
    add = math.min(add, cap - amount)

    if kind == "generator" then
        -- GeneratorFuelPerCharge is "% of a full generator tank for 0 -> 100%".
        local perUnit = Cybertruck.opt("GeneratorFuelPerCharge", 50) / 100 * gen:getMaxFuel() / cap
        if perUnit > 0 then
            local fuel = gen:getFuel()
            local cost = add * perUnit
            if cost > fuel then
                add = fuel / perUnit
                cost = fuel
            end
            gen:setFuel(fuel - cost)
            gen:sync()
        end
    end
    md.chargingFrom = kind
    return amount + add
end

function Cybertruck.Update.BatteryPack(vehicle, part, elapsedMinutes)
    local real = isReal(vehicle)
    if real then Cybertruck.applyVehicleTuning(vehicle) end
    if not part:getInventoryItem() then return end
    local md = part:getModData()
    local cap = part:getContainerCapacity()
    local old = part:getContainerContentAmount()
    local amount = old
    local sendModData = false

    if vehicle:isEngineRunning() then
        if md.plugged then
            unplug(md) -- driving off pulls the cable
            sendModData = true
        end
        if elapsedMinutes > 0 and amount > 0 then
            local blades = real and Cybertruck.spinDrain(vehicle) or 0
            amount = amount - (drainRate(vehicle) + blades) * elapsedMinutes
            -- Regenerative braking: give a little back whenever we slow down.
            local speed = math.abs(vehicle:getCurrentSpeedKmHour())
            local last = md.lastSpeed or speed
            if speed < last - 0.5 then
                amount = amount + (last - speed) * 0.0015 * Cybertruck.opt("RegenStrength", 100) / 100
            end
            md.lastSpeed = speed
        end
    else
        md.lastSpeed = 0
        if md.plugged and elapsedMinutes > 0 then
            -- Charging checks the world for a generator, so do it once per game minute, not every tick.
            md.chargeAcc = (md.chargeAcc or 0) + elapsedMinutes
            -- Out of range the generator's square isn't loaded, so the charger can't be checked. Bank the
            -- minutes and settle them against the generator once the truck is back in range.
            if real and md.chargeAcc >= 1 then
                local minutes = md.chargeAcc
                md.chargeAcc = 0
                local wasPlugged = md.plugged
                amount = charge(vehicle, part, amount, minutes)
                if wasPlugged ~= md.plugged then sendModData = true end
            end
        end
    end

    amount = clamp(amount, 0, cap)
    if amount ~= old then
        part:setContainerContentAmount(amount, false, true)
        amount = part:getContainerContentAmount()
        local precision = (amount < 0.5) and 2 or 1
        if VehicleUtils.compareFloats(old, amount, precision) then sendModData = true end
    end
    if sendModData then vehicle:transmitPartModData(part) end
end

---------------------------------------------------------------------------------------------------
-- Armor: stainless panels and armored glass shrug off most damage, whatever caused it.
-- Weapons are already cut down by part durability; zombie thumps ignore durability, so this
-- hook hands back most of every condition drop. Fractions carry over, so small hits still add up.
---------------------------------------------------------------------------------------------------

function Cybertruck.Update.Armor(vehicle, part, elapsedMinutes)
    local item = part:getInventoryItem()
    local md = part:getModData()
    if not item then
        md.ctItem, md.ctCond, md.ctDebt = nil, nil, nil
        return
    end
    local cond = part:getCondition()
    local id = item:getID()
    if md.ctItem ~= id then
        md.ctItem, md.ctCond, md.ctDebt = id, cond, 0
        return
    end
    local last = md.ctCond or cond
    if cond < last and cond > 0 then
        local keep = 1 - Cybertruck.opt("ArmorAbsorb", 90) / 100
        local dmg = (last - cond) * keep + (md.ctDebt or 0)
        local whole = math.floor(dmg)
        md.ctDebt = dmg - whole
        cond = last - whole
        part:setCondition(cond)
        vehicle:transmitPartCondition(part)
    end
    md.ctCond = cond
end

function Cybertruck.Update.ArmorEngineDoor(vehicle, part, elapsedMinutes)
    Vehicles.Update.EngineDoor(vehicle, part, elapsedMinutes)
    Cybertruck.Update.Armor(vehicle, part, elapsedMinutes)
end

function Cybertruck.Update.ArmorTrunkDoor(vehicle, part, elapsedMinutes)
    Vehicles.Update.TrunkDoor(vehicle, part, elapsedMinutes)
    Cybertruck.Update.Armor(vehicle, part, elapsedMinutes)
end

---------------------------------------------------------------------------------------------------
-- Apocalypse fittings. The truck stays stock until somebody bolts these on.
-- Part updates only fire once per game minute, a couple of real seconds, so anything that has to
-- keep up with a moving truck (the saw, the shredder, bumper-kill speed) runs on the tick instead.
---------------------------------------------------------------------------------------------------

local localPos = Vector3f.new()
local worldPos = Vector3f.new()
local noCharge = {}    -- zombies the roof gun killed; they don't feed impact charging
local recentSpeed = {} -- vehicle id -> { speed, at }: top speed over the last moment
local lastShot = {}    -- vehicle id -> ms of the last round the server let through
local SPEED_MEMORY_MS = 1500

function Cybertruck.spinDrain(vehicle)
    if not Cybertruck.bladesSpinning(vehicle) then return 0 end
    return 0.018 * Cybertruck.opt("BladeDrain", 1)
end

-- Sound and blood for everyone nearby. Single player plays it here; a server hands it to the clients.
function Cybertruck.fx(vehicle, kind, x, y, hit)
    local args = { vehicle = vehicle:getId(), kind = kind, x = x, y = y, hit = hit }
    if isServer() then
        sendServerCommand("Cybertruck", "fx", args)
    elseif Cybertruck.playFx then
        Cybertruck.playFx(args)
    end
end

local function creditKill(killer)
    if killer and killer.setZombieKills then killer:setZombieKills(killer:getZombieKills() + 1) end
end

-- Takes `cost` out of the pack. False if the pack can't cover it.
local function spend(vehicle, cost)
    if cost <= 0 then return true end
    local pack = Cybertruck.batteryPart(vehicle)
    if not pack then return false end
    local amount = pack:getContainerContentAmount()
    if amount < cost then return false end
    pack:setContainerContentAmount(amount - cost, false, true)
    vehicle:transmitPartModData(pack)
    return true
end

-- Across the full body width, so a tree clipping a corner still gets cut instead of stopping the truck.
local LANES = { -0.5, -0.25, 0, 0.25, 0.5 }
local lastPos = {} -- vehicle id -> { x, y }: where the truck was last tick, to sweep what it covered since

-- Fells ordinary trees in the lane the truck is heading into, forward or reverse, far enough out that
-- the trunk is down before the bumper gets there. Giant trees stay up. The wood drops like any felled tree.
local function sawTrees(vehicle, driver, kmh, travel)
    if not Cybertruck.opt("TreeSaw", true) or math.abs(kmh) < 2 then return end
    local dir = kmh > 0 and 1 or -1
    local near = Cybertruck.HALF_L + 0.25
    -- Reach at least 1.5 ticks ahead at the pace the truck is really covering ground. On a slow frame
    -- the truck can jump a tile or more between ticks, and a fixed band would be stepped right over.
    local far = near + 0.6 + math.max(math.abs(kmh) / 3.6 * 0.12, travel * 1.5)
    local cost = 0.4 * Cybertruck.opt("BladeDrain", 1)
    local cell = getCell()
    local z = math.floor(vehicle:getZ())
    -- Half-tile steps from the bumper out, so nothing between the bumper and the far edge slips through.
    for lz = near, far, 0.5 do
        for _, lx in ipairs(LANES) do
            vehicle:getWorldPos(lx, 0, lz * dir, worldPos)
            local sq = cell:getGridSquare(math.floor(worldPos:x()), math.floor(worldPos:y()), z)
            local tree = sq and sq:getTree()
            if tree and tree:getSize() < Cybertruck.GIANT_TREE then
                if not spend(vehicle, cost) then return end
                Cybertruck.fx(vehicle, "saw", sq:getX() + 0.5, sq:getY() + 0.5)
                tree:toppleTree(driver)
            end
        end
    end
end

-- Anything that gets inside the blade line dies: bumpers, and the rockers where they grab at the doors.
local function shred(vehicle, driver, zombies, travel)
    if not Cybertruck.opt("ZombiePlow", true) then return end
    local vx, vy = vehicle:getX(), vehicle:getY()
    local vz = math.floor(vehicle:getZ())
    local w = Cybertruck.HALF_W + Cybertruck.BLADE_REACH
    local l = Cybertruck.HALF_L + Cybertruck.BLADE_REACH
    -- Whatever the truck drove through since the last check is behind it now; the sweep covers that too.
    local back = l + travel
    local kmh = vehicle:getCurrentSpeedKmHour()
    local near2 = (back + 0.5) * (back + 0.5)
    for i = zombies:size() - 1, 0, -1 do
        local z = zombies:get(i)
        if z and not z:isDead() and math.floor(z:getZ()) == vz then
            local zx, zy = z:getX(), z:getY()
            local dx, dy = zx - vx, zy - vy
            if dx * dx + dy * dy < near2 then
                vehicle:getLocalPos(zx, zy, vz, localPos)
                local lz = localPos:z()
                local lo, hi = -l, l
                if kmh > 1 then lo = -back elseif kmh < -1 then hi = back end
                if math.abs(localPos:x()) < w and lz > lo and lz < hi then
                    Cybertruck.fx(vehicle, "shred", zx, zy, true)
                    z:Kill(driver)
                    creditKill(driver)
                end
            end
        end
    end
end

-- Remembers the truck's top speed for a moment, so a body that already slowed it still counts.
local function trackSpeed(vehicle)
    local id = vehicle:getId()
    local now = getTimestampMs()
    local kmh = math.abs(vehicle:getCurrentSpeedKmHour())
    local r = recentSpeed[id]
    if not r then
        recentSpeed[id] = { speed = kmh, at = now }
    elseif kmh >= r.speed or now - r.at > SPEED_MEMORY_MS then
        r.speed, r.at = kmh, now
    end
end

-- Every Cybertruck, found, built or already parked in an old save, gets one full bottle in the glovebox.
-- Marked on the truck so it only happens once, even if the bottle is taken.
local function stockGlovebox(vehicle)
    local md = vehicle:getModData()
    if md.elonsMusk then return end
    local box = vehicle:getPartById("GloveBox")
    local container = box and box:getItemContainer()
    if not container then return end
    local item = container:AddItem("Cybertruck.ElonsMusk")
    if item and isServer() then sendAddItemToContainer(container, item) end
    md.elonsMusk = true
    if isServer() then vehicle:transmitModData() end
end

local tick = 0
Events.OnTick.Add(function()
    -- Clients load this folder too. Trees and kills belong to the server, or to single player.
    if isClient() then return end
    local cell = getCell()
    if not cell then return end
    tick = tick + 1
    local zombies
    local it = cell:getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if Cybertruck.is(v) then
            if tick % 30 == 0 then stockGlovebox(v) end
            trackSpeed(v)
            local id = v:getId()
            local last = lastPos[id]
            local travel = 0
            if last then
                local dx, dy = v:getX() - last.x, v:getY() - last.y
                travel = math.min(math.sqrt(dx * dx + dy * dy), 4)
                last.x, last.y = v:getX(), v:getY()
            else
                lastPos[id] = { x = v:getX(), y = v:getY() }
            end
            if Cybertruck.bladesSpinning(v) then
                local driver = v:getDriver()
                sawTrees(v, driver, v:getCurrentSpeedKmHour(), travel)
                zombies = zombies or cell:getZombieList()
                shred(v, driver, zombies, travel)
            end
        end
    end
end)

local FITTING_PARTS = { BladeKit = true, Sunroof = true, Turret = true }

function Cybertruck.Create.Fitting(vehicle, part)
    if Cybertruck.building or not Cybertruck.opt("FoundWithKit", false) then return end
    if FITTING_PARTS[part:getId()] then VehicleUtils.createPartInventoryItem(part) end
end

-- One round from the shooter's pockets, then from the vault.
local function takeRound(player, vehicle)
    local item = player:getInventory():getFirstTypeRecurse(Cybertruck.AMMO)
    if not item then
        local bed = vehicle:getPartById("TruckBed")
        local vault = bed and bed:getItemContainer()
        item = vault and vault:getFirstTypeRecurse(Cybertruck.AMMO)
    end
    local container = item and item:getContainer()
    if not container then return false end
    container:Remove(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
    return true
end

-- args.x / args.y: where the gunner aimed, snapped by the client to the zombie under the cursor.
-- The server looks again near that point, so a client can't pick targets it has no business hitting.
function Cybertruck.fireGun(player, args)
    if not player or not args then return end
    local vehicle = player:getVehicle()
    if not Cybertruck.canFire(vehicle, player) then return end
    local id = vehicle:getId()
    local now = getTimestampMs()
    if lastShot[id] and now - lastShot[id] < Cybertruck.GUN_COOLDOWN_MS - 40 then return end
    if not takeRound(player, vehicle) then return end
    lastShot[id] = now

    local vx, vy = vehicle:getX(), vehicle:getY()
    getWorldSoundManager():addSound(player, math.floor(vx), math.floor(vy), math.floor(vehicle:getZ()), 70, 80)

    local ax, ay = tonumber(args.x), tonumber(args.y)
    local target = ax and ay and Cybertruck.pickTarget(vehicle, ax, ay)
    if target then
        local dx, dy = target:getX() - vx, target:getY() - vy
        local dist = math.sqrt(dx * dx + dy * dy)
        -- Steady from a parked truck, looser at range and at speed.
        local chance = clamp(95 - dist * 1.5 - math.abs(vehicle:getCurrentSpeedKmHour()) * 0.3, 35, 95)
        if ZombRand(100) < chance then
            Cybertruck.fx(vehicle, "shot", target:getX(), target:getY(), true)
            noCharge[target] = true
            target:Kill(player)
            creditKill(player)
            return
        end
    end
    Cybertruck.fx(vehicle, "shot", ax, ay, false)
end

Events.OnZombieDead.Add(function(zombie)
    if isClient() or not zombie then return end
    if noCharge[zombie] then
        noCharge[zombie] = nil
        return
    end
    if not Cybertruck.opt("ImpactCharge", false) then return end
    local killer = zombie:getAttackedBy()
    local vehicle = killer and killer:getVehicle()
    if not Cybertruck.is(vehicle) or vehicle:getDriver() ~= killer then return end
    local part = Cybertruck.batteryPart(vehicle)
    if not part then return end
    local r = recentSpeed[vehicle:getId()]
    local kmh = math.max(math.abs(vehicle:getCurrentSpeedKmHour()), r and r.speed or 0)
    if kmh < Cybertruck.KILL_SPEED then return end
    local cap = part:getContainerCapacity()
    local amount = part:getContainerContentAmount()
    local add = cap * Cybertruck.opt("ImpactChargePercent", 0.5) / 100
    if add <= 0 or amount >= cap then return end
    part:setContainerContentAmount(math.min(cap, amount + add), false, true)
    vehicle:transmitPartModData(part)
end)

-- The driver's blade switch.
local function setBlades(player, args)
    local vehicle = player and player:getVehicle()
    if not Cybertruck.is(vehicle) or vehicle:getSeat(player) ~= 0 then return end
    if not Cybertruck.installed(vehicle, "BladeKit") then return end
    local part = vehicle:getPartById("BladeKit")
    part:getModData().spin = args and args.on == true or nil
    vehicle:transmitPartModData(part)
end

---------------------------------------------------------------------------------------------------
-- Commands from the client: plug / unplug, the roof gun, the blade switch
---------------------------------------------------------------------------------------------------

function Cybertruck.onCommand(command, player, args)
    if command == "fire" then
        Cybertruck.fireGun(player, args)
        return
    end
    if command == "blades" then
        setBlades(player, args)
        return
    end
    if command ~= "plug" and command ~= "unplug" then return end
    local vehicle = args and args.vehicle and getVehicleById(args.vehicle)
    if not Cybertruck.is(vehicle) then return end
    local part = Cybertruck.batteryPart(vehicle)
    if not part then return end
    local md = part:getModData()
    if command == "plug" then
        if vehicle:isEngineRunning() or not Cybertruck.findCharger(vehicle) then return end
        md.plugged = true
        md.chargeAcc = 0
    else
        unplug(md)
    end
    vehicle:transmitPartModData(part)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module == "Cybertruck" then Cybertruck.onCommand(command, player, args) end
end)

---------------------------------------------------------------------------------------------------
-- World spawns (sandbox: WorldSpawn, SpawnChance)
---------------------------------------------------------------------------------------------------

local function addSpawns()
    if not VehicleZoneDistribution or not Cybertruck.opt("WorldSpawn", true) then return end
    local chance = Cybertruck.opt("SpawnChance", 3)
    local zones = { good = chance, professional = chance, luxuryDealership = chance * 2 }
    for zone, weight in pairs(zones) do
        local dist = VehicleZoneDistribution[zone]
        if dist and dist.vehicles then
            dist.vehicles[Cybertruck.SCRIPT] = { index = -1, spawnChance = weight }
        end
    end
end
Events.OnInitWorld.Add(addSpawns)

---------------------------------------------------------------------------------------------------
-- Build recipe (sandbox: Craftable)
---------------------------------------------------------------------------------------------------

function Cybertruck_ShowBuildRecipe(param)
    return Cybertruck.opt("Craftable", true)
end

local SPAWN_DIRS = { IsoDirections.S, IsoDirections.E, IsoDirections.N, IsoDirections.W }

local function rollOut(character)
    local cell = getCell()
    local px, py, pz = math.floor(character:getX()), math.floor(character:getY()), math.floor(character:getZ())
    for r = 3, 8 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = cell:getGridSquare(px + dx, py + dy, pz)
                    if sq and sq:isFree(false) and not sq:getVehicleContainer() then
                        -- Create.Fitting sees this and leaves the fittings off. Found trucks use the sandbox dial.
                        Cybertruck.building = true
                        local ok, v = pcall(addVehicleDebug, Cybertruck.SCRIPT, SPAWN_DIRS[ZombRand(#SPAWN_DIRS) + 1], nil, sq)
                        Cybertruck.building = false
                        if ok and v then return v end
                    end
                end
            end
        end
    end
    return nil
end

function Cybertruck_OnBuild(craftRecipeData, character)
    local vehicle = rollOut(character)
    if not vehicle then
        character:setHaloNote(getText("IGUI_Cybertruck_NoRoom"), 255, 80, 80, 300)
        return
    end
    vehicle:repair()
    local part = Cybertruck.batteryPart(vehicle)
    if part then
        -- Fresh off the welding bench, the pack ships nearly empty. Go find a generator.
        part:setContainerContentAmount(part:getContainerCapacity() * Cybertruck.opt("BuildCharge", 5) / 100, false, true)
        vehicle:transmitPartModData(part)
    end
    local key = vehicle:createVehicleKey()
    if key then
        character:getInventory():AddItem(key)
        if isServer() then sendAddItemToContainer(character:getInventory(), key) end
    end
end
