-- Cybertruck: drive battery, charging, armor, world spawns and the build recipe.
require "Cybertruck/CybertruckShared"
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
        -- Parked since the outbreak: somewhere between a third and nearly full.
        part:setContainerContentAmount(ZombRand(math.floor(cap * 0.3), math.floor(cap * 0.9)))
    end
end

-- Draw per game minute. Idles almost free, scales with speed, heater and lights add a little.
local function drainRate(vehicle)
    local speed = math.abs(vehicle:getCurrentSpeedKmHour())
    local rate = 0.002 + 0.00025 * speed
    local heater = vehicle:getHeater()
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
            amount = amount - drainRate(vehicle) * elapsedMinutes
            -- Regenerative braking: give a little back whenever we slow down.
            local speed = math.abs(vehicle:getCurrentSpeedKmHour())
            local last = md.lastSpeed or speed
            if speed < last - 0.5 then
                amount = amount + (last - speed) * 0.0015
            end
            md.lastSpeed = speed
        end
    else
        md.lastSpeed = 0
        if md.plugged and elapsedMinutes > 0 then
            -- Charging checks the world for a generator, so do it once per game minute, not every tick.
            md.chargeAcc = (md.chargeAcc or 0) + elapsedMinutes
            if md.chargeAcc >= 1 then
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
-- Plug / unplug from the client
---------------------------------------------------------------------------------------------------

function Cybertruck.onCommand(command, player, args)
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
                        local v = addVehicleDebug(Cybertruck.SCRIPT, SPAWN_DIRS[ZombRand(#SPAWN_DIRS) + 1], nil, sq)
                        if v then return v end
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
        part:setContainerContentAmount(part:getContainerCapacity() * 0.05, false, true)
        vehicle:transmitPartModData(part)
    end
    local key = vehicle:createVehicleKey()
    if key then
        character:getInventory():AddItem(key)
        if isServer() then sendAddItemToContainer(character:getInventory(), key) end
    end
end
