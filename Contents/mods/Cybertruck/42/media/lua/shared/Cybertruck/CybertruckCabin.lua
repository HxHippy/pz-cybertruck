-- Cybertruck cabin: a plush tank. The game hurts occupants on hard impacts (addRandomDamageFromCrash):
-- base damage scales with playerDamageProtection, but fractures, deep wounds and glass roll off
-- impact speed alone. So while someone rides in a Cybertruck we keep a copy of their body state,
-- and when the game reports CARCRASHDAMAGE we put it back. Everything else still hurts normally.
require "Cybertruck/CybertruckShared"

local snapshots = {}   -- player object -> list of part states

local function snapshot(player)
    local parts = player:getBodyDamage():getBodyParts()
    local s = {}
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        s[i] = {
            health = p:getHealth(),
            fracture = p:getFractureTime(),
            deep = p:deepWounded(), deepTime = p:getDeepWoundTime(),
            glass = p:haveGlass(),
            scratched = p:scratched(), scratchTime = p:getScratchTime(),
            cut = p:isCut(), cutTime = p:getCutTime(),
            bleedTime = p:getBleedingTime(),
        }
    end
    return s
end

local function restore(player, s)
    local parts = player:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local p, o = parts:get(i), s[i]
        if o then
            p:SetHealth(o.health)
            p:setFractureTime(o.fracture)
            p:setDeepWounded(o.deep)
            p:setDeepWoundTime(o.deepTime)
            p:setHaveGlass(o.glass)
            p:setScratched(o.scratched, false)
            p:setScratchTime(o.scratchTime)
            p:setCut(o.cut)
            p:setCutTime(o.cutTime)
            p:setBleedingTime(o.bleedTime)
        end
    end
end

Events.OnPlayerUpdate.Add(function(player)
    if Cybertruck.is(player:getVehicle()) then
        snapshots[player] = snapshot(player)
    else
        snapshots[player] = nil
    end
end)

Events.OnPlayerGetDamage.Add(function(character, damageType, damage)
    if damageType ~= "CARCRASHDAMAGE" then return end
    local s = snapshots[character]
    if s and Cybertruck.is(character:getVehicle()) then restore(character, s) end
end)
