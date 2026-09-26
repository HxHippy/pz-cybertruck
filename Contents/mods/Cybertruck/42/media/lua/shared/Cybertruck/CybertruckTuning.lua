-- Cybertruck sandbox dials that change the truck itself.
--   Script-wide (every Cybertruck): off-road grip, crash damage multiplier.
--   Per truck, re-applied whenever the game resets them (it rebuilds physics on load):
--   motor power, motor loudness, top speed, glass and panel strength.
require "Cybertruck/CybertruckShared"

Cybertruck.BASE_TOP_SPEED = 120   -- maxSpeed in media/scripts/vehicles/cybertruck.txt

local GLASS = { "Windshield", "WindshieldRear", "WindowFrontLeft", "WindowFrontRight", "WindowRearLeft", "WindowRearRight" }
local PANELS = { "DoorFrontLeft", "DoorFrontRight", "DoorRearLeft", "DoorRearRight", "EngineDoor", "TrunkDoor" }

-- 1 = plush tank (no crash injuries), 2 = reinforced (light damage only), 3 = vanilla
function Cybertruck.cabinMode()
    return Cybertruck.opt("CabinProtection", 1)
end

function Cybertruck.applyScriptTuning()
    local script = getScriptManager():getVehicle(Cybertruck.SCRIPT)
    if not script then return end
    script:setOffroadEfficiency(Cybertruck.opt("OffroadGrip", 2.0))
    -- The game multiplies occupant crash damage by this; vanilla cars sit around 1.1.
    script:setPlayerDamageProtection(Cybertruck.cabinMode() == 3 and 1.1 or 0.15)
end

local function setDurability(vehicle, ids, value)
    for _, id in ipairs(ids) do
        local part = vehicle:getPartById(id)
        if part and part:getDurability() ~= value then part:setDurability(value) end
    end
end

function Cybertruck.applyVehicleTuning(vehicle)
    local script = vehicle:getScript()
    -- Same power curve the game uses when it creates an engine, then the dial on top.
    local quality = vehicle:getEngineQuality()
    local qualityModifier = math.max(0.6, math.min(quality * 1.6, 100) / 100)
    local power = math.floor(script:getEngineForce() * qualityModifier * Cybertruck.opt("EnginePower", 100) / 100)
    -- setEngineFeature stores loudness * 0.37037 (VehicleEngine.setFeatures), so pass the target
    -- divided by that. The game also rebuilds loudness from the script value whenever parts
    -- change; this runs every update, so it puts the dial's value straight back.
    local loud = math.floor(Cybertruck.opt("MotorLoudness", 20) * (SandboxVars.ZombieAttractionMultiplier or 1))
    if vehicle:getEnginePower() ~= power or vehicle:getEngineLoudness() ~= loud then
        vehicle:setEngineFeature(quality, math.ceil(loud / 0.37037036), power)
    end
    local top = Cybertruck.BASE_TOP_SPEED * Cybertruck.opt("TopSpeed", 100) / 100
    if math.abs(vehicle:getMaxSpeed() - top) > 0.5 then vehicle:setMaxSpeed(top) end
    setDurability(vehicle, GLASS, Cybertruck.opt("GlassDurability", 60))
    setDurability(vehicle, PANELS, Cybertruck.opt("PanelDurability", 60))
end

Events.OnGameStart.Add(Cybertruck.applyScriptTuning)
Events.OnInitGlobalModData.Add(Cybertruck.applyScriptTuning)
