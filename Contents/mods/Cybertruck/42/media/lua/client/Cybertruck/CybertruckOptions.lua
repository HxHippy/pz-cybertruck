-- Cybertruck in Options > Mods: a signpost to the world (sandbox) settings, and in single player
-- an opt-in copy of every dial that takes effect immediately. On servers the world settings win.
require "Cybertruck/CybertruckShared"
require "Cybertruck/CybertruckTuning"

local options = PZAPI.ModOptions:create("Cybertruck", getText("IGUI_VehicleNameCybertruck"))
options:addDescription(getText("UI_Cybertruck_WhereSettings"))
local override = options:addTickBox("override", getText("UI_Cybertruck_Override"), false, getText("UI_Cybertruck_Override_tip"))

local dials = {}
local function tick(id, default)
    dials[id] = options:addTickBox(id, getText("Sandbox_Cybertruck_" .. id), default, getText("Sandbox_Cybertruck_" .. id .. "_tooltip"))
end
local function slider(id, min, max, step, default)
    dials[id] = options:addSlider(id, getText("Sandbox_Cybertruck_" .. id), min, max, step, default, getText("Sandbox_Cybertruck_" .. id .. "_tooltip"))
end

options:addTitle(getText("UI_Cybertruck_Spawning"))
tick("WorldSpawn", true)
slider("SpawnChance", 1, 100, 1, 3)
slider("SpawnChargeMin", 0, 100, 5, 30)
slider("SpawnChargeMax", 0, 100, 5, 90)
tick("Craftable", true)
slider("BuildCharge", 0, 100, 5, 5)

options:addTitle(getText("UI_Cybertruck_Battery"))
slider("BatteryDrain", 0.1, 10, 0.1, 1.0)
slider("RegenStrength", 0, 300, 10, 100)
slider("ChargeHours", 1, 72, 1, 10)
slider("GeneratorFuelPerCharge", 0, 400, 5, 50)
slider("CableReach", 3, 40, 1, 12)
tick("GridCharging", true)

options:addTitle(getText("UI_Cybertruck_Performance"))
slider("EnginePower", 25, 150, 5, 100)
slider("TopSpeed", 25, 200, 5, 100)
slider("MotorLoudness", 0, 150, 5, 20)
slider("OffroadGrip", 0.5, 4, 0.1, 2.0)

options:addTitle(getText("UI_Cybertruck_Protection"))
local cabin = options:addComboBox("CabinProtection", getText("Sandbox_Cybertruck_CabinProtection"), getText("Sandbox_Cybertruck_CabinProtection_tooltip"))
for i = 1, 3 do cabin:addItem("Sandbox_Cybertruck_CabinProtectionValues_option" .. i, i == 1) end
dials.CabinProtection = cabin
slider("ArmorAbsorb", 0, 100, 5, 90)
slider("GlassDurability", 1, 500, 1, 60)
slider("PanelDurability", 1, 500, 1, 60)

options:addTitle(getText("UI_Cybertruck_Fittings"))
tick("FoundWithKit", false)
tick("BladeAppearance", true)
tick("ZombiePlow", true)
tick("TreeSaw", true)
slider("BladeDrain", 0, 5, 0.1, 1.0)
tick("ImpactCharge", false)
slider("ImpactChargePercent", 0, 5, 0.1, 0.5)

-- Always yours, single player or not: which key fires the roof gun besides the left mouse button.
local fireKey = options:addKeyBind("FireKey", getText("UI_Cybertruck_FireKey"), Keyboard.KEY_K, getText("UI_Cybertruck_FireKey_tip"))
Cybertruck.fireKey = function() return fireKey:getValue() end
-- The 20 mm shot is mastered hot. Percent of full; 0 mutes it.
local gunVolume = options:addSlider("GunVolume", getText("UI_Cybertruck_GunVolume"), 0, 100, 5, 40, getText("UI_Cybertruck_GunVolume_tip"))
Cybertruck.gunVolume = function() return gunVolume:getValue() / 100 end

-- Only a solo game runs the server-side code in this same Lua state, so only there can a
-- player's own settings drive the truck.
local function singlePlayer() return not isClient() and not isServer() end

Cybertruck.localOverride = function(name)
    if not singlePlayer() or not override:getValue() then return nil end
    local d = dials[name]
    if d then return d:getValue() end
    return nil
end

function options:apply()
    if singlePlayer() and getPlayer() then Cybertruck.applyScriptTuning() end
end
