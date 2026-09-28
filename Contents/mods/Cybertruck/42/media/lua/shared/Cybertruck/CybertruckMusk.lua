-- Elon's Musk: the glovebox cologne. A spritz keeps zombies off you for an in-game hour.
-- The timed action lives in shared so a server runs complete() and syncs the bottle.
require "TimedActions/ISBaseTimedAction"
require "Cybertruck/CybertruckShared"

Cybertruck.MUSK = "Cybertruck.ElonsMusk"
Cybertruck.MUSK_DOSE = 0.02   -- litres per spritz; a full 0.1 bottle is five
Cybertruck.MUSK_HOURS = 1     -- in-game hours per spritz
Cybertruck.MUSK_RADIUS = 10   -- tiles

function Cybertruck.muskActive(player)
    local untilHour = player and player:getModData().muskUntil
    return untilHour ~= nil and getGameTime():getWorldAgeHours() < untilHour
end

function Cybertruck.muskLeft(item)
    local fc = item and item:getFluidContainer()
    return fc and fc:getAmount() or 0
end

-- Stacks on top of a spritz that's still going, so a second one extends it instead of wasting it.
function Cybertruck.startMusk(player)
    local md = player:getModData()
    local now = getGameTime():getWorldAgeHours()
    md.muskUntil = math.max(md.muskUntil or now, now) + Cybertruck.MUSK_HOURS
end

ISApplyElonsMusk = ISBaseTimedAction:derive("ISApplyElonsMusk")

function ISApplyElonsMusk:isValid()
    local inv = self.character:getInventory()
    local held = isClient() and inv:containsID(self.item:getID()) or inv:contains(self.item)
    return held and Cybertruck.muskLeft(self.item) >= Cybertruck.MUSK_DOSE - 0.0001
end

function ISApplyElonsMusk:start()
    if isClient() then self.item = self.character:getInventory():getItemById(self.item:getID()) end
    self:setActionAnim("WearClothing")
    self:setAnimVariable("WearClothingLocation", "Face")
end

function ISApplyElonsMusk:update() end

function ISApplyElonsMusk:stop()
    ISBaseTimedAction.stop(self)
end

function ISApplyElonsMusk:perform()
    -- The client keeps its own clock for the repel loop; the server's copy is the saved one.
    if isClient() then Cybertruck.startMusk(self.character) end
    self.character:setHaloNote(getText("IGUI_Cybertruck_MuskOn"), 190, 220, 255, 300)
    ISBaseTimedAction.perform(self)
end

function ISApplyElonsMusk:complete()
    local fc = self.item:getFluidContainer()
    fc:adjustAmount(math.max(0, fc:getAmount() - Cybertruck.MUSK_DOSE))
    sendItemStats(self.item)
    Cybertruck.startMusk(self.character)
    return true
end

function ISApplyElonsMusk:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 60
end

function ISApplyElonsMusk:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.maxTime = o:getDuration()
    return o
end
