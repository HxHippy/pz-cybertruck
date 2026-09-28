-- Cybertruck: plug in / unplug from the vehicle context menu and the V radial menu.
require "Cybertruck/CybertruckShared"
require "TimedActions/ISBaseTimedAction"
require "Vehicles/ISUI/ISVehicleMenu"
require "Vehicles/ISUI/ISCarMechanicsOverlay"

-- Mechanics screen: borrow the 4-door SUV layout.
ISCarMechanicsOverlay.CarList[Cybertruck.SCRIPT] = ISCarMechanicsOverlay.CarList["Base.SUV"]

---------------------------------------------------------------------------------------------------
-- Plug / unplug action: walk to the charge port, fiddle with the cable, tell the server.
---------------------------------------------------------------------------------------------------

CybertruckPlugAction = ISBaseTimedAction:derive("CybertruckPlugAction")

function CybertruckPlugAction:isValid()
    return self.vehicle and not self.vehicle:isRemovedFromWorld() and Cybertruck.batteryPart(self.vehicle) ~= nil
end

function CybertruckPlugAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function CybertruckPlugAction:update()
    self.character:faceThisObject(self.vehicle)
end

function CybertruckPlugAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
end

function CybertruckPlugAction:perform()
    local command = self.plug and "plug" or "unplug"
    local args = { vehicle = self.vehicle:getId() }
    if isClient() then
        sendClientCommand(self.character, "Cybertruck", command, args)
    else
        Cybertruck.onCommand(command, self.character, args) -- single player: no server to ask
    end
    -- The truck's own emitter plays file clips reliably; the character's doesn't for these.
    self.vehicle:getEmitter():playSound(self.plug and "CybertruckPlugIn" or "CybertruckPlugOut")
    local key = self.plug and ("IGUI_Cybertruck_Charging_" .. self.kind) or "IGUI_Cybertruck_Unplugged"
    self.character:setHaloNote(getText(key), 120, 220, 255, 300)
    ISBaseTimedAction.perform(self)
end

function CybertruckPlugAction:new(character, vehicle, plug, kind)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.plug = plug
    o.kind = kind
    o.maxTime = 80
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

local function queue(playerObj, vehicle, plug)
    local kind
    if plug then
        kind = Cybertruck.findCharger(vehicle)
        if not kind then
            playerObj:setHaloNote(getText("IGUI_Cybertruck_NoCharger"), 255, 120, 80, 300)
            return
        end
    end
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(playerObj, vehicle, "GasTank"))
    ISTimedActionQueue.add(CybertruckPlugAction:new(playerObj, vehicle, plug, kind))
end

function Cybertruck.onPlug(playerObj, vehicle) queue(playerObj, vehicle, true) end
function Cybertruck.onUnplug(playerObj, vehicle) queue(playerObj, vehicle, false) end

---------------------------------------------------------------------------------------------------
-- Menus: FillPartMenu feeds both the right-click menu and the outside radial menu.
---------------------------------------------------------------------------------------------------

local fillPartMenu = ISVehicleMenu.FillPartMenu

function ISVehicleMenu.FillPartMenu(playerIndex, context, slice, vehicle)
    fillPartMenu(playerIndex, context, slice, vehicle)
    if not Cybertruck.is(vehicle) then return end
    local playerObj = getSpecificPlayer(playerIndex)
    if playerObj:getVehicle() or playerObj:DistToProper(vehicle) >= 4 then return end
    local part = Cybertruck.batteryPart(vehicle)
    if not part then return end

    local pct = tostring(Cybertruck.chargePercent(part)) .. "%"
    local text, fn
    if part:getModData().plugged then
        text, fn = getText("ContextMenu_Cybertruck_Unplug", pct), Cybertruck.onUnplug
    elseif not vehicle:isEngineRunning() then
        text, fn = getText("ContextMenu_Cybertruck_Plug", pct), Cybertruck.onPlug
    else
        return
    end

    if slice then
        slice:addSlice(text, getTexture("media/ui/vehicles/vehicle_refuel_from_pump.png"), fn, playerObj, vehicle)
    elseif context then
        context:addOption(text, playerObj, fn, vehicle)
    end
end

---------------------------------------------------------------------------------------------------
-- Apocalypse fittings: meshes, the blade switch and hatch on the V menu, the roof gun, the plow.
---------------------------------------------------------------------------------------------------

local velocity = Vector3f.new()

local SAWS = 8

local function showModel(part, modelId, visible)
    part:setModelVisible(modelId, visible)
end

-- The player's own truck when they're on its gun; the one whose turret follows their aim.
local function mannedTruck()
    local playerObj = getSpecificPlayer(0)
    local vehicle = playerObj and playerObj:getVehicle()
    if vehicle and Cybertruck.canFire(vehicle, playerObj) then return vehicle end
    return nil
end

-- Part models all share one script, so a rotation set on a model turns it on every Cybertruck.
-- Each moving piece therefore comes in a pair: the moving copy is shown only where it should move
-- (spinning saws, the gun the local player is manning) and a still copy everywhere else.
function Cybertruck.applyLooks(vehicle)
    if not Cybertruck.is(vehicle) then return end
    local kit = vehicle:getPartById("BladeKit")
    if kit then
        local shown = Cybertruck.installed(vehicle, "BladeKit") and Cybertruck.opt("BladeAppearance", true)
        local spinning = shown and Cybertruck.bladesSpinning(vehicle)
        for i = 1, SAWS do
            showModel(kit, "SawSpin" .. i, spinning)
            showModel(kit, "SawStill" .. i, shown and not spinning)
        end
    end
    local hatch = vehicle:getPartById("Sunroof")
    if hatch then showModel(hatch, "Sunroof", Cybertruck.installed(vehicle, "Sunroof")) end
    local turret = vehicle:getPartById("Turret")
    if turret then
        local installed = Cybertruck.installed(vehicle, "Turret")
        local live = installed and mannedTruck() == vehicle
        showModel(turret, "TurretLive", live)
        showModel(turret, "TurretIdle", installed and not live)
    end
end

-- Handles on the shared script models that move: the saws spin, the gun swivels.
local moving = nil
local function movingModels()
    if moving then return moving end
    local script = getScriptManager():getVehicle(Cybertruck.SCRIPT)
    local kit = script and script:getPartById("BladeKit")
    local turret = script and script:getPartById("Turret")
    if not kit or not turret then return nil end
    moving = { saws = {}, gun = turret:getModelById("TurretLive") }
    for i = 1, SAWS do
        local m = kit:getModelById("SawSpin" .. i)
        if m then table.insert(moving.saws, m:getRotate()) end
    end
    if moving.gun then moving.gun = moving.gun:getRotate() end
    return moving
end

-- Degrees per tick. Not a multiple of the 18-degree tooth pitch, so the teeth visibly travel
-- instead of strobing in place.
local SAW_STEP = 31
local sawAngle, gunYaw = 0, 0
Cybertruck.TURRET_SIGN = 1
local aimLocal = Vector3f.new()

-- Yaw of the gun relative to the truck's nose, in degrees, toward world point (x, y).
local function yawToward(vehicle, x, y)
    vehicle:getLocalPos(x, y, vehicle:getZ(), aimLocal)
    return math.deg(math.atan2(aimLocal:x(), aimLocal:z()))
end
Cybertruck.yawToward = yawToward

Events.OnTick.Add(function()
    local m = movingModels()
    if not m then return end
    sawAngle = (sawAngle + SAW_STEP) % 360
    for _, rot in ipairs(m.saws) do rot:set(0, sawAngle, 0) end
    if not m.gun then return end
    local truck = mannedTruck()
    local target = 0
    if truck and Cybertruck.aimPoint then
        target = yawToward(truck, Cybertruck.aimPoint.x, Cybertruck.aimPoint.y) * Cybertruck.TURRET_SIGN
    end
    -- Swing at up to 12 degrees a tick, the short way round.
    local diff = (target - gunYaw + 540) % 360 - 180
    gunYaw = gunYaw + math.max(-12, math.min(12, diff))
    m.gun:set(0, gunYaw, 0)
end)

local function nearbyTrucks(player, radius, fn)
    local it = getCell():getVehicles():iterator()
    local r2 = radius * radius
    while it:hasNext() do
        local v = it:next()
        if Cybertruck.is(v) and v:DistToSquared(player) < r2 then fn(v) end
    end
end

local lookTick = 0
Events.OnTick.Add(function()
    lookTick = lookTick + 1
    if lookTick % 15 ~= 0 then return end
    local player = getSpecificPlayer(0)
    if player and getCell() then nearbyTrucks(player, 50, Cybertruck.applyLooks) end
end)

---------------------------------------------------------------------------------------------------
-- Effects the server (or single player) asks for
---------------------------------------------------------------------------------------------------

local function bloodAt(x, y, z, n)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), z)
    local chunk = sq and sq:getChunk()
    if not chunk then return end
    for _ = 1, n do
        chunk:addBloodSplat(x + (ZombRand(100) - 50) / 120, y + (ZombRand(100) - 50) / 120, z, ZombRand(20))
    end
end

function Cybertruck.playFx(args)
    local vehicle = args and args.vehicle and getVehicleById(args.vehicle)
    if not vehicle then return end
    local player = getSpecificPlayer(0)
    if player and vehicle:DistToSquared(player) > 80 * 80 then return end
    local z = math.floor(vehicle:getZ())
    local emitter = vehicle:getEmitter()
    if args.kind == "shot" then
        -- A touch of pitch spread so a long burst doesn't sound like one clip on repeat.
        local volume = Cybertruck.gunVolume and Cybertruck.gunVolume() or 0.4
        if volume > 0 then
            local id = emitter:playSound("CybertruckGun")
            if id and id ~= 0 then
                emitter:setVolume(id, volume)
                emitter:setPitch(id, 0.94 + ZombRand(13) / 100)
            end
        end
        if args.hit and args.x then bloodAt(args.x, args.y, z, 3) end
    elseif args.kind == "shred" or args.kind == "saw" then
        -- The blades biting: same pitch spread as the gun, so a run through a crowd doesn't repeat one clip.
        local id = emitter:playSound("CybertruckShred")
        if id and id ~= 0 then emitter:setPitch(id, 0.94 + ZombRand(13) / 100) end
        if args.kind == "shred" and args.x then bloodAt(args.x, args.y, z, 7) end
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == "Cybertruck" and command == "fx" then Cybertruck.playFx(args) end
end)

---------------------------------------------------------------------------------------------------
-- Blade switch and roof gun on the V menu
---------------------------------------------------------------------------------------------------

local function send(playerObj, command, args)
    if isClient() then
        sendClientCommand(playerObj, "Cybertruck", command, args)
    else
        Cybertruck.onCommand(command, playerObj, args)
    end
end

local function toggleBlades(playerObj, vehicle)
    local on = not Cybertruck.bladesOn(vehicle)
    send(playerObj, "blades", { on = on })
    Cybertruck.applyLooks(vehicle)
    if on and not vehicle:isEngineRunning() then
        playerObj:setHaloNote(getText("IGUI_Cybertruck_BladesArmed"), 255, 200, 80, 250)
    end
end

-- Controller players have no cursor: a three-round burst at whatever is nearest.
local burst = nil

local function fireBurst(playerObj)
    burst = { player = playerObj, left = 3, next = 0 }
end

local showRadial = ISVehicleMenu.showRadialMenu
function ISVehicleMenu.showRadialMenu(playerObj)
    -- The vanilla call toggles: open closes it. Decide from the state before the call, because a
    -- menu that just opened doesn't report itself visible until it has rendered once.
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    local wasOpen = menu ~= nil and menu:isReallyVisible()
    showRadial(playerObj)
    local vehicle = playerObj:getVehicle()
    if wasOpen or not menu or not Cybertruck.is(vehicle) then return end
    local speed = UIManager.getSpeedControls()
    if speed and speed:getCurrentGameSpeed() == 0 then return end -- vanilla doesn't open while paused
    local seat = vehicle:getSeat(playerObj)

    if seat == 0 and Cybertruck.installed(vehicle, "BladeKit") then
        local key = Cybertruck.bladesOn(vehicle) and "ContextMenu_Cybertruck_BladesOff" or "ContextMenu_Cybertruck_BladesOn"
        menu:addSlice(getText(key), getTexture("media/ui/vehicles/vehicle_ignitionON.png"), toggleBlades, playerObj, vehicle)
    end
    if not Cybertruck.gunReady(vehicle) then return end
    if seat ~= Cybertruck.GUN_SEAT and not vehicle:getCharacter(Cybertruck.GUN_SEAT) and (seat ~= 0 or Cybertruck.stopped(vehicle)) then
        menu:addSlice(getText("ContextMenu_Cybertruck_Hatch"), getTexture("media/ui/vehicles/vehicle_changeseats.png"), ISVehicleMenu.onSwitchSeat, playerObj, Cybertruck.GUN_SEAT)
    end
    if Cybertruck.canFire(vehicle, playerObj) and JoypadState.players[playerObj:getPlayerNum() + 1] then
        menu:addSlice(getText("ContextMenu_Cybertruck_Fire"), getTexture("media/ui/FirearmRadial_BulletsIntoFirearm.png"), fireBurst, playerObj)
    end
end

---------------------------------------------------------------------------------------------------
-- Roof gun. Hold left mouse (or the Fire key) from the gun seat. The zombie nearest the cursor
-- lights up red; that's what the gun is on.
---------------------------------------------------------------------------------------------------

local mouseHeld = false
local marked = nil
local nextShot = 0
local warnedAt = 0

Events.OnMouseDown.Add(function() mouseHeld = true end)
Events.OnMouseUp.Add(function() mouseHeld = false end)

local function unmark()
    if marked then
        marked:setOutlineHighlight(0, false)
        marked = nil
    end
end

local function mark(z)
    if z == marked then return end
    unmark()
    marked = z
end

-- The engine wipes every character outline at render time unless it was set during this frame's
-- UI pass, so the red outline has to be re-applied from a UI draw callback, every frame.
Events.OnPreUIDraw.Add(function()
    if not marked then return end
    if marked:isDead() then
        marked = nil
        return
    end
    marked:setOutlineHighlightCol(0, 1.0, 0.15, 0.1, 1.0)
    marked:setOutlineHighlight(0, true)
end)

local function hasAmmo(playerObj, vehicle)
    if playerObj:getInventory():getFirstTypeRecurse(Cybertruck.AMMO) then return true end
    local bed = vehicle:getPartById("TruckBed")
    local vault = bed and bed:getItemContainer()
    return vault ~= nil and vault:getFirstTypeRecurse(Cybertruck.AMMO) ~= nil
end

local function shoot(playerObj, vehicle, target, now)
    nextShot = now + Cybertruck.GUN_COOLDOWN_MS
    if not hasAmmo(playerObj, vehicle) then
        if now - warnedAt > 1500 then
            playerObj:setHaloNote(getText("IGUI_Cybertruck_NoAmmo"), 255, 120, 80, 220)
            warnedAt = now
        end
        return
    end
    local args = {}
    if target then args.x, args.y = target:getX(), target:getY() end
    send(playerObj, "fire", args)
end

local function gunTick()
    local playerObj = getSpecificPlayer(0)
    local vehicle = playerObj and playerObj:getVehicle()
    if not vehicle or not Cybertruck.canFire(vehicle, playerObj) then
        unmark()
        burst = nil
        Cybertruck.aimPoint = nil
        return
    end
    local pn = playerObj:getPlayerNum()
    -- Line of sight, not the gunner's view cone: the ring turns, the gunner's head doesn't have to.
    local function visible(z)
        local sq = z:getCurrentSquare()
        return sq ~= nil and sq:isCouldSee(pn)
    end
    local now = getTimestampMs()

    if burst and burst.player == playerObj then
        if now >= burst.next then
            local target = Cybertruck.pickTarget(vehicle, nil, nil, visible)
            mark(target)
            if target then Cybertruck.aimPoint = { x = target:getX(), y = target:getY() } end
            shoot(playerObj, vehicle, target, now)
            burst.left = burst.left - 1
            burst.next = now + Cybertruck.GUN_COOLDOWN_MS
            if burst.left <= 0 then burst = nil end
        end
        return
    end
    if JoypadState.players[pn + 1] then
        unmark()
        return
    end

    local z = math.floor(vehicle:getZ())
    local ax = screenToIsoX(pn, getMouseX(), getMouseY(), z)
    local ay = screenToIsoY(pn, getMouseX(), getMouseY(), z)
    -- A world point to aim at instead of the cursor ({ x, y }), for scripted tests and recordings.
    if Cybertruck.aimOverride then ax, ay = Cybertruck.aimOverride.x, Cybertruck.aimOverride.y end
    local target = Cybertruck.pickTarget(vehicle, ax, ay, visible)
    mark(target)
    Cybertruck.aimPoint = target and { x = target:getX(), y = target:getY() } or { x = ax, y = ay }

    local key = Cybertruck.fireKey and Cybertruck.fireKey()
    local held = (mouseHeld and isMouseButtonDown(0)) or (key and key > 0 and isKeyDown(key))
    if not isMouseButtonDown(0) then mouseHeld = false end
    if held and now >= nextShot then shoot(playerObj, vehicle, target, now) end
end

Events.OnTick.Add(gunTick)

---------------------------------------------------------------------------------------------------
-- Plow. Every zombie the truck touches pushes back on it by its own weight and the truck's speed
-- (BaseVehicle.applyImpulseFromHitPedestrian). With the blades spinning, the driver's machine,
-- which owns the truck's physics, pushes the same amount the other way, so bodies stop costing
-- speed. Walls, cars and trees are untouched.
---------------------------------------------------------------------------------------------------

local function plowTick()
    local playerObj = getSpecificPlayer(0)
    local vehicle = playerObj and playerObj:getVehicle()
    if not Cybertruck.is(vehicle) or vehicle:getDriver() ~= playerObj then return end
    if not Cybertruck.opt("ZombiePlow", true) or not Cybertruck.bladesSpinning(vehicle) then return end
    vehicle:getLinearVelocity(velocity)
    local vx, vy = velocity:x(), velocity:z()
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 0.05 then return end
    local cx, cy = vehicle:getX(), vehicle:getY()
    local reach = Cybertruck.HALF_L + 1.2
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local zed = list:get(i)
        -- Vanilla skips the push for a zombie whose state can't be hit, so skip the answer too.
        if zed and zed:isVehicleCollision() and zed:canBeHitByVehicle(vehicle) then
            local px, py = zed:getX() - cx, zed:getY() - cy
            local len = math.sqrt(px * px + py * py)
            if len > 0.01 and len < reach then
                -- Same terms as vanilla: dot of travel against the push, zombie mass, prone or standing.
                local dot = (vx * -px + vy * -py) / (len * speed)
                if dot < 0 then
                    local strength = -dot * zed:getMass() * (zed:isProne() and 0.2 or 0.8) * speed
                    vehicle:applyImpulseFromHitObject(zed, -strength)
                end
            end
        end
    end
end

Cybertruck.plowTick = plowTick -- the test harness drives it directly
Events.OnTick.Add(plowTick)
