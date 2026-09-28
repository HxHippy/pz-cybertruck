-- Cybertruck motor sound. The vehicle script's engine sound is silent, because the engine code
-- drives vanilla sounds with RPM parameters and retriggers a plain looping file. Instead, three
-- loops run on the truck's own emitter and get mixed by speed every tick:
--   idle  - the motor's resting tones (700 Hz / 900 Hz / 1.8 kHz, rumble filtered out)
--   whine - the drive recording's tonal harmonics above 400 Hz; pitch follows speed
--   road  - the same recording below 250 Hz; tire and road noise that swells with speed
--   blades - the saw kit's grinder loop; spins up and down instead of snapping
require "Cybertruck/CybertruckShared"

local HEAR = 40            -- tiles; beyond this nothing plays
local LAYERS = { "CybertruckIdle", "CybertruckWhine", "CybertruckRoad", "CybertruckBlades" }
local BLADES = 4
local active = {}          -- vehicle id -> { vehicle, ids = {}, vol = {} }

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Target volume and pitch for each layer at this speed.
local function mix(speed, throttle, blades)
    local s = math.abs(speed)
    local push = 1 + 0.2 * clamp(throttle or 0, 0, 1)
    return {
        { 0.05 + 0.25 * clamp(1 - s / 20, 0, 1), 1.0 },
        { clamp(0.1 + s / 45, 0, 0.8) * push, 0.55 + 0.8 * clamp(s / 110, 0, 1) },
        { clamp(s / 70, 0, 0.6), 0.9 + 0.2 * clamp(s / 100, 0, 1) },
        { blades and 0.35 or 0, blades and 1.0 or 0.35 },
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
        state = { vehicle = v, ids = {}, vol = { 0, 0, 0, 0 }, pitch = { 1, 1, 1, 0.35 } }
        active[key] = state
    end
    local e = v:getEmitter()
    if not e then return end
    local targets = mix(v:getCurrentSpeedKmHour(), v:getThrottle(), Cybertruck.bladesSpinning(v))
    for n, name in ipairs(LAYERS) do
        local id = state.ids[n]
        -- The blade loop only exists while it is audible.
        local wanted = n ~= BLADES or targets[n][1] > 0 or state.vol[n] > 0.01
        if not wanted then
            if id and id ~= 0 then e:stopSound(id) end
            state.ids[n] = nil
        else
            if not id or id == 0 or not e:isPlaying(id) then
                id = e:playSound(name)
                state.ids[n] = id
                state.vol[n] = 0
                if state.sentVol then state.sentVol[n] = nil end
                if state.sentPitch then state.sentPitch[n] = nil end
            end
            -- Ease toward the target so speed changes glide instead of stepping. The blades ease
            -- their pitch too, slower, so they wind up over about a second and wind down after.
            state.vol[n] = state.vol[n] + (targets[n][1] - state.vol[n]) * (n == BLADES and 0.05 or 0.12)
            if n == BLADES then
                state.pitch[n] = state.pitch[n] + (targets[n][2] - state.pitch[n]) * 0.03
            else
                state.pitch[n] = targets[n][2]
            end
            -- The engine logs every setPitch call, so only touch the emitter when the value moved.
            state.sentVol = state.sentVol or {}
            state.sentPitch = state.sentPitch or {}
            if not state.sentVol[n] or math.abs(state.vol[n] - state.sentVol[n]) > 0.01 then
                e:setVolume(id, state.vol[n])
                state.sentVol[n] = state.vol[n]
            end
            if not state.sentPitch[n] or math.abs(state.pitch[n] - state.sentPitch[n]) > 0.01 then
                e:setPitch(id, state.pitch[n])
                state.sentPitch[n] = state.pitch[n]
            end
        end
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
