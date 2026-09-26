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
