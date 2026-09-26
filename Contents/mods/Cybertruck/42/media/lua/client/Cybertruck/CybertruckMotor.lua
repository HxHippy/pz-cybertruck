-- Cybertruck motor sound. The vehicle script's engine sound is silent, because the engine code
-- drives vanilla sounds with RPM parameters and retriggers a plain looping file. Instead, three
-- loops run on the truck's own emitter and get mixed by speed every tick:
--   idle  - the motor's resting tones (700 Hz / 900 Hz / 1.8 kHz, rumble filtered out)
--   whine - the drive recording's tonal harmonics above 400 Hz; pitch follows speed
--   road  - the same recording below 250 Hz; tire and road noise that swells with speed
require "Cybertruck/CybertruckShared"

local HEAR = 40            -- tiles; beyond this nothing plays
local LAYERS = { "CybertruckIdle", "CybertruckWhine", "CybertruckRoad" }
local active = {}          -- vehicle id -> { vehicle, ids = {}, vol = {} }

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Target volume and pitch for each layer at this speed.
local function mix(speed, throttle)
    local s = math.abs(speed)
    local push = 1 + 0.2 * clamp(throttle or 0, 0, 1)
    return {
        { 0.05 + 0.25 * clamp(1 - s / 20, 0, 1), 1.0 },
        { clamp(0.1 + s / 45, 0, 0.8) * push, 0.55 + 0.8 * clamp(s / 110, 0, 1) },
        { clamp(s / 70, 0, 0.6), 0.9 + 0.2 * clamp(s / 100, 0, 1) },
    }
end

local function stopAll(state)
    local e = state.vehicle:getEmitter()
    for i, id in pairs(state.ids) do
        if id and id ~= 0 and e then e:stopSound(id) end
        state.ids[i] = nil
    end
end

local function tend(v, seen)
    local key = v:getId()
    seen[key] = true
    local state = active[key]
    if not state or state.vehicle ~= v then
        state = { vehicle = v, ids = {}, vol = { 0, 0, 0 } }
        active[key] = state
    end
    local e = v:getEmitter()
    if not e then return end
    local targets = mix(v:getCurrentSpeedKmHour(), v:getThrottle())
    for n, name in ipairs(LAYERS) do
        local id = state.ids[n]
        if not id or id == 0 or not e:isPlaying(id) then
            id = e:playSound(name)
            state.ids[n] = id
            state.vol[n] = 0
        end
        -- Ease toward the target so speed changes glide instead of stepping.
        state.vol[n] = state.vol[n] + (targets[n][1] - state.vol[n]) * 0.12
        e:setVolume(id, state.vol[n])
        e:setPitch(id, targets[n][2])
    end
end

local function update()
    local player = getSpecificPlayer(0)
    local seen = {}
    if player then
        local it = getCell():getVehicles():iterator()
        while it:hasNext() do
            local v = it:next()
            if Cybertruck.is(v) and v:isEngineRunning() and v:DistToSquared(player) < HEAR * HEAR then
                tend(v, seen)
            end
        end
    end
    for key, state in pairs(active) do
        if not seen[key] then
            stopAll(state)
            active[key] = nil
        end
    end
end

Events.OnTick.Add(update)
