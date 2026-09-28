-- Elon's Musk on the client: the "spritz" option, and the repel loop. Zombie AI runs on the client that
-- owns the zombie, so the loop runs here for the local players.
require "Cybertruck/CybertruckMusk"

local function spritz(item, playerObj)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    ISTimedActionQueue.add(ISApplyElonsMusk:new(playerObj, item))
end

Events.OnFillInventoryObjectContextMenu.Add(function(pn, context, items)
    local playerObj = getSpecificPlayer(pn)
    for _, entry in ipairs(items) do
        local item = type(entry) == "table" and entry.items and entry.items[1] or entry
        if item and item.getFullType and item:getFullType() == Cybertruck.MUSK then
            local option = context:addOption(getText("ContextMenu_Cybertruck_Spritz"), item, spritz, playerObj)
            if Cybertruck.muskLeft(item) < Cybertruck.MUSK_DOSE - 0.0001 then
                option.notAvailable = true
            end
            return
        end
    end
end)

-- Zombies the musk is holding off: zombie -> tick it was last sent packing. While held they're flagged
-- useless, which stops them spotting or hearing anyone; the flag isn't saved and is cleared on release.
local held = {}
local tick = 0
local wasActive = {}
local AWAY = 8             -- tiles past where it stands
local RELEASE = 1.5        -- let go once past this many radii

local function release(z)
    if z:isUseless() then z:setUseless(false) end
    held[z] = nil
end

Events.OnTick.Add(function()
    tick = tick + 1
    if tick % 5 ~= 0 then return end
    local cell = getCell()
    if not cell then return end
    local scented = {}
    for pn = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(pn)
        local active = player and not player:isDead() and Cybertruck.muskActive(player)
        if player and wasActive[pn] and not active then
            player:setHaloNote(getText("IGUI_Cybertruck_MuskOff"), 200, 200, 200, 300)
        end
        wasActive[pn] = active
        if active then table.insert(scented, player) end
    end

    local r2 = Cybertruck.MUSK_RADIUS * Cybertruck.MUSK_RADIUS
    local keep2 = r2 * RELEASE * RELEASE
    -- Let go of anything dead, gone, or far enough from every scented player.
    for z in pairs(held) do
        local near = false
        if not z:isDead() then
            for _, player in ipairs(scented) do
                local dx, dy = z:getX() - player:getX(), z:getY() - player:getY()
                if dx * dx + dy * dy < keep2 then near = true end
            end
        end
        if not near then release(z) end
    end
    if #scented == 0 then return end

    local zombies = cell:getZombieList()
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if z and not z:isDead() then
            for _, player in ipairs(scented) do
                local dx, dy = z:getX() - player:getX(), z:getY() - player:getY()
                local d2 = dx * dx + dy * dy
                if d2 < r2 and math.floor(z:getZ()) == math.floor(player:getZ()) and (held[z] or not z:isUseless()) then
                    if not held[z] then
                        z:setUseless(true)
                        z:setTarget(nil)
                        z:setTargetSeenTime(0)
                    end
                    if not held[z] or tick - held[z] >= 60 then
                        local d = math.sqrt(d2)
                        if d < 0.01 then dx, dy, d = 1, 0, 1 end
                        z:pathToLocation(math.floor(z:getX() + dx / d * AWAY), math.floor(z:getY() + dy / d * AWAY), math.floor(z:getZ()))
                        -- A zombie that has seen you is "alerted", and alerted zombies won't take the idle->walk
                        -- transition. The pathfind transition doesn't care, so send it that way.
                        z:setVariable("bPathfind", true)
                        held[z] = tick
                    end
                    break
                end
            end
        end
    end
end)
