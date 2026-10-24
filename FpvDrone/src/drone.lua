local function thrust(isLinearAcceleration, airDensity, propDiameter, propPitch, motorKv, batteryCells, throttle, inflowVelocity)
    local force
    if not isLinearAcceleration then
        local a = airDensity * (3.14 * ((0.0254 * propDiameter) ^ 2) / 4) * ((propDiameter / (3.29547 * (propPitch + 0.5))) ^ 1.5) * 1.5 * 4
        local maxRPM = math.min(motorKv * batteryCells * 3.7 * (5.4 / (propDiameter ^ 1.1)), motorKv * batteryCells * 3.7)
        local rpm = throttle * maxRPM
        local maxVe = maxRPM * 0.0254 * (propPitch + 0.5) / 60
        local Ve = rpm * 0.0254 * (propPitch + 0.5) / 60
        local ic = math.max(0.2, (maxVe - math.abs(inflowVelocity)) / maxVe)
        force = a * (math.abs(Ve) * Ve) * ic
    else
        force = throttle * motorKv / 30
    end
    return force
end

local function airDragForceFn(density, velocity, coefficient, area, minAreaCoeff, inflowCoefficient)
    local areaCoeff = inflowCoefficient + minAreaCoeff * (1 - inflowCoefficient)
    return velocity:clone():normalize():scale(-0.5 * density * velocity:length() ^ 2 * (2.5 * coefficient) * (area * areaCoeff))
end

local function vectorAngle(vec1, vec2)
    local angle = math.acos(vec1:dot(vec2) / (vec1:length() * vec2:length()))
    return angle == angle and angle or 0
end

local function excludeVector(v, vectorToExclude)
    return v - vectorToExclude * v:dot(vectorToExclude)
end

local function getClosestCar(toPosition)
    local closestCarIndex = 0
    local minDistance = 1e9
    for i = 0, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isActive then
            local distanceToPosition = (car.position - toPosition):length()
            if distanceToPosition < minDistance then
                closestCarIndex = i
                minDistance = distanceToPosition
            end
        end
    end
    return ac.getCar(closestCarIndex)
end

local function applyDeadzone(value, deadzonePercent)
    local deadzone = deadzonePercent / 100
    if math.abs(value) < deadzone then
        return 0
    end
    local sign = value < 0 and -1 or 1
    return sign * (math.abs(value) - deadzone) / (1 - deadzone)
end

-- === Ronin roll drift ===
local RONIN_DRIFT_DEG_PER_G = 4    -- degrees of drift per lateral G
local RONIN_DRIFT_MAX_DEG = 20     -- maximum drift
local RONIN_DRIFT_TAU = 1.5        -- seconds (how fast the drift builds up / fades away)
local RONIN_DRIFT_SIGN = 1         -- set to -1 if the horizon drifts the wrong way

-- === Camera du gimbal (Cam OP) ===
local GIMBAL_CAMERA_ANGLE = 0      -- camera angle is automatically 0 during playback
-- Tilt range of the underslung gimbal (DJI RS 4 Pro mechanical tilt range: 326 deg, -112 to +214).
-- Mounted upside down under the drone the axis is mirrored: it can look past straight down (top shot)
local GIMBAL_TILT_MIN = -214
local GIMBAL_TILT_MAX = 112
local SENSOR_HEIGHT_MM = 20.25     -- hauteur du capteur (plein format en 16:9 : 36 x 20.25 mm), sert a convertir focale -> FOV vertical

-- === Gimbal rates ===
local GIMBAL_SMOOTHING_MAX_TAU = 1.5   -- smoothing time constant (s) at maximum (100)

-- === Vols sauvegardes ===
local INSPIRE_TILT_TAU = 0.25      -- seconds, how softly the body tilts into accelerations
local INSPIRE_HORIZON_TAU = 0.05   -- seconds per stage of the Inspire camera horizon hold (2 stages)
local FLIGHTS_PATH = ac.dirname() .. "/settings/flights/"

-- Stick smoothing, framerate independent: 0 = immediate, 100 = 1.5 s time constant
local function smoothingAlpha(smoothing, dt)
    if smoothing <= 0 then return 1 end
    return 1 - math.exp(-dt / math.max(smoothing / 100 * GIMBAL_SMOOTHING_MAX_TAU, 1e-3))
end

local function focalToFov(focalMm)
    return math.deg(2 * math.atan(SENSOR_HEIGHT_MM / (2 * math.max(focalMm, 1))))
end

-- Dernier index i tel que frames[i].time <= t (borne entre 1 et #frames - 1)
local function findFrameIndex(frames, t)
    local lo, hi = 1, #frames
    if hi < 2 then return 1 end
    while lo < hi - 1 do
        local mid = math.floor((lo + hi) / 2)
        if frames[mid].time <= t then lo = mid else hi = mid end
    end
    return lo
end

-- Replay clock: time in seconds of the replay currently shown, or nil outside of a replay.
-- The replay only reports a frame index (sim.replayCurrentFrame * sim.replayFrameMs), which moves in steps of
-- one replay frame. Using it directly makes everything synced to it stutter, so the clock runs continuously
-- with sim.dt (0 when paused, follows replay slow motion / fast forwarding) and is only kept inside the
-- window of the current replay frame, which corrects the drift without ever restarting the clock.
local replayClock = { time = nil, frame = -1, direction = 1 }
local function getReplayTime(sim)
    if not sim.isReplayActive or sim.replayFrames <= 0 or sim.replayFrameMs <= 0 then
        replayClock.time = nil
        replayClock.frame = -1
        return nil
    end
    local frameS = sim.replayFrameMs / 1000
    local frame = sim.replayCurrentFrame
    local windowStart = frame * frameS
    local step = math.abs(sim.dt)

    if replayClock.time == nil or replayClock.frame < 0
        or math.abs(frame - replayClock.frame) > step / frameS * 2 + 2 then
        -- first frame in the replay, or the replay jumped (seek): restart from the reported frame
        replayClock.time = windowStart
    else
        if frame ~= replayClock.frame then replayClock.direction = frame > replayClock.frame and 1 or -1 end
        replayClock.time = math.clamp(replayClock.time + step * replayClock.direction, windowStart, windowStart + frameS)
    end
    replayClock.frame = frame
    return replayClock.time
end

-- === Ronin follow modes ===
-- Which axes follow the drone body: lock = none (fully stabilized in the world), pan = heading, pantilt = heading + pitch,
-- fpv = heading + pitch + roll.
local GIMBAL_MODES = {
    lock = { yaw = false, pitch = false, roll = false },
    pan = { yaw = true, pitch = false, roll = false },
    pantilt = { yaw = true, pitch = true, roll = false },
    fpv = { yaw = true, pitch = true, roll = true },
}
local GIMBAL_MODE_ORDER = { "lock", "pan", "pantilt", "fpv" }
local GIMBAL_MODE_NAMES = { lock = "Lock", pan = "Pan follow", pantilt = "Pan/Tilt follow", fpv = "FPV" }

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local WORLD_UP = vec3(0, 1, 0)

local function wrapAngle(deg)
    return (deg + 180) % 360 - 180
end

-- Direction toward which a vector moves under a small positive rotation about an axis. Using the library's own
-- rotations keeps every angle below in the same sign convention as the gimbal chain, whatever the handedness.
local function rotationStep(v, axis)
    return v:clone():rotate(quat.fromAngleAxis(0.1, axis)):sub(v):normalize()
end

-- Attitude of a body (look/up vectors) as gimbal angles in degrees: yaw about the world up, pitch about the right axis,
-- roll about the heading. Exact for small bank angles, approximate for extreme attitudes.
local function bodyAttitude(look, up)
    local h = vec3(look.x, 0, look.z)
    local yaw, pitch, roll = nil, 0, 0
    if h:length() > 0.1 then
        h:normalize()
        local z = vec3(0, 0, 1)
        yaw = math.deg(atan2(h:dot(rotationStep(z, WORLD_UP)), h:dot(z)))
        local right = math.cross(h, WORLD_UP):normalize()
        pitch = math.deg(atan2(look:dot(rotationStep(h, right)), look:dot(h)))
    else
        pitch = look.y > 0 and 90 or -90
    end
    local levelUp = WORLD_UP - look * WORLD_UP:dot(look)
    if levelUp:length() > 0.1 then
        levelUp:normalize()
        roll = math.deg(atan2(up:dot(rotationStep(levelUp, look)), up:dot(levelUp)))
    end
    return yaw, pitch, roll
end

-- === Gyroflow style stabilization (FPV replay) ===
-- Gyroflow smooths the recorded camera rotation offline, so the result has no lag: it can look at the future of
-- the footage. The recorded orientation is resampled at 60 Hz and low-pass filtered forward then backward
-- (zero phase). No crop is needed here, the game simply renders what the smoothed camera sees.
local STAB_STEP = 1 / 60

local function smoothVectors(list, alpha)
    local function step(prev, raw)
        local v = prev + (raw - prev) * alpha
        if v:length() < 1e-4 then return raw:clone() end
        return v:normalize()
    end
    local n = #list
    for i = 2, n do list[i] = step(list[i - 1], list[i]) end
    for i = n - 1, 1, -1 do list[i] = step(list[i + 1], list[i]) end
end

local function buildStabilization(frames, tau)
    local n = #frames
    if n < 2 then return nil end
    local t0, t1 = frames[1].time, frames[n].time
    if t1 <= t0 then return nil end
    local count = math.floor((t1 - t0) / STAB_STEP) + 1
    local looks, ups = {}, {}
    for i = 1, count do
        local t = t0 + (i - 1) * STAB_STEP
        local idx = findFrameIndex(frames, t)
        local a, b = frames[idx], frames[idx + 1] or frames[idx]
        local f = b.time > a.time and math.clamp((t - a.time) / (b.time - a.time), 0, 1) or 0
        looks[i] = a.look:clone():addScaled(b.look - a.look, f):normalize()
        ups[i] = a.up:clone():addScaled(b.up - a.up, f):normalize()
    end
    local alpha = 1 - math.exp(-STAB_STEP / math.max(tau, 0.02))
    smoothVectors(looks, alpha)
    smoothVectors(ups, alpha)
    return { t0 = t0, count = count, looks = looks, ups = ups }
end

local function sampleStabilization(cache, t)
    local x = math.clamp((t - cache.t0) / STAB_STEP, 0, cache.count - 1)
    local i = math.floor(x) + 1
    local j = math.min(i + 1, cache.count)
    local f = x - (i - 1)
    local look = cache.looks[i]:clone():addScaled(cache.looks[j] - cache.looks[i], f):normalize()
    local up = cache.ups[i]:clone():addScaled(cache.ups[j] - cache.ups[i], f)
    up:addScaled(look, -up:dot(look))
    if up:length() < 1e-4 then return nil end
    return look, up:normalize()
end

-- Gimbal track: samples {time, yaw, pitch, roll} (degrees), keyed by flight time like the flight frames
local function sampleGimbalTrack(track, t)
    local n = #track
    if n == 0 then return nil end
    if n == 1 or t <= track[1].time then return track[1].yaw, track[1].pitch, track[1].roll end
    if t >= track[n].time then return track[n].yaw, track[n].pitch, track[n].roll end
    local a = track[findFrameIndex(track, t)]
    local b = track[findFrameIndex(track, t) + 1]
    local f = b.time > a.time and math.clamp((t - a.time) / (b.time - a.time), 0, 1) or 0
    return a.yaw + (b.yaw - a.yaw) * f, a.pitch + (b.pitch - a.pitch) * f, a.roll + (b.roll - a.roll) * f
end

-- Records the current gimbal angles at flight time t. Paused: the last sample is overwritten.
-- Time went back (replay rewound): everything from that point on is cut and recorded again.
local function recordGimbalSample(track, t, yaw, pitch, roll)
    local last = track[#track]
    if last and t < last.time - 0.001 then
        while #track > 0 and track[#track].time >= t do table.remove(track) end
        last = nil
    end
    local entry = { time = t, yaw = yaw, pitch = pitch, roll = roll }
    if last and t <= last.time then
        track[#track] = entry
    else
        track[#track + 1] = entry
    end
end

-- Gyroflow smoothing of a recorded gimbal track (angles in degrees), zero phase like the body stabilization
local function buildTrackStabilization(track, tau)
    local n = #track
    if n < 2 then return nil end
    local t0, t1 = track[1].time, track[n].time
    if t1 <= t0 then return nil end
    local count = math.floor((t1 - t0) / STAB_STEP) + 1
    local yaw, pitch, roll = {}, {}, {}
    for i = 1, count do
        yaw[i], pitch[i], roll[i] = sampleGimbalTrack(track, t0 + (i - 1) * STAB_STEP)
    end
    local alpha = 1 - math.exp(-STAB_STEP / math.max(tau, 0.02))
    for _, list in ipairs({ yaw, pitch, roll }) do
        for i = 2, count do list[i] = list[i - 1] + (list[i] - list[i - 1]) * alpha end
        for i = count - 1, 1, -1 do list[i] = list[i + 1] + (list[i] - list[i + 1]) * alpha end
    end
    return { t0 = t0, count = count, yaw = yaw, pitch = pitch, roll = roll }
end

local function sampleTrackStabilization(cache, t)
    local x = math.clamp((t - cache.t0) / STAB_STEP, 0, cache.count - 1)
    local i = math.floor(x) + 1
    local j = math.min(i + 1, cache.count)
    local f = x - (i - 1)
    return cache.yaw[i] + (cache.yaw[j] - cache.yaw[i]) * f,
        cache.pitch[i] + (cache.pitch[j] - cache.pitch[i]) * f,
        cache.roll[i] + (cache.roll[j] - cache.roll[i]) * f
end

-- Simulated realism: layered sines (incommensurate frequencies) give a smooth noise in [-1, 1]
local function layeredNoise(t, seed, f)
    return (math.sin(t * f + seed) + 0.6 * math.sin(t * f * 2.31 + seed * 1.7) + 0.4 * math.sin(t * f * 4.97 + seed * 2.3)) / 2
end

local function vecToArr(v)
    return { math.round(v.x, 4), math.round(v.y, 4), math.round(v.z, 4) }
end
local function arrToVec(a)
    return vec3(a[1], a[2], a[3])
end

local M = {
    camera = nil, ---@type ac.GrabbedCamera
    previousCameraMode = nil,
    active = false,
    sleep = false,
    position = vec3(),
    rotation = { look = vec3(), up = vec3() },
    velocity = vec3(),
    savedState = nil,
    inspireHeading = nil,
    inspireTiltPitch = 0,
    inspireTiltRoll = 0,
    inspireTiltLag = 0, -- delayed + smoothed copy of the body pitch tilt, used by the camera to hold the horizon
    inspireTiltLag1 = 0, -- first stage of that smoothing
    recordedFlight = {},
    gimbalTrack = {}, -- recorded gimbal moves (yaw/pitch/roll in degrees over flight time)
    recordedInspire = nil, -- true/false: flight recorded in Inspire mode (nil = unknown, old flights)
    recordedClock = nil, -- "replay" when frame times are replay times, "live" for a flight recorded in a live session
    playbackIndex = 1,
    recordingTime = 0,
    playbackElapsedTime = 0,
    gimbalPitch = 0,
    gimbalYaw = 0,
    gimbalRoll = 0,
    -- gimbal angles above are the final ones (reference + operator offset). Reference = what the follow mode takes from the drone.
    gimbalRef = { yaw = 0, pitch = 0, roll = 0 },
    gimbalOff = { yaw = 0, pitch = 0, roll = 0 },
    gimbalAppliedMode = nil,
    gimbalAlign = false,       -- at the start of a playback the follow modes start aligned with the drone
    gimbalRecentering = false,
    gimbalLastDroneYaw = 0,
    stabCache = nil, -- smoothed orientation of the recorded flight (Gyroflow option)
    currentGimbalYawSpeed = 0,
    currentGimbalPitchSpeed = 0,
    currentGimbalRollSpeed = 0,
    resetHoldTimer = 0,
    stoppedByHold = false,
    isRecording = true,
    roninDrift = 0,
    playbackSpec = nil,
    flights = {},
    flightMessage = nil,
}

function M:toggle()
    if not self.active then
        self.camera, self.errorMessage = ac.grabCamera("Fpv Drone")
        if not self.camera then return end

        self.position = ac.getCameraPosition()
        local cameraAngleQuat = quat.fromAngleAxis(-math.rad(Settings.cameraAngle), ac.getCameraSide())
        self.rotation.look = ac.getCameraForward():rotate(cameraAngleQuat)
        self.rotation.up = ac.getCameraUp():rotate(cameraAngleQuat)
        self.velocity = getClosestCar(self.position).velocity:clone():add(vec3(0, 10, 0))

        self.previousCameraMode = ac.getSim().cameraMode
        ac.setCurrentCamera(ac.CameraMode.Drivable)

        self.active = true
        self.sleep = false
        self.lastPosition = nil
        self.roninDrift = 0
        self.inspireHeading = nil
    else
        if self.previousCameraMode then ac.setCurrentCamera(self.previousCameraMode) end
        self.active = false
        self.camera:dispose()
    end
end

function M:toggleSleep()
    self.sleep = not self.sleep
end

-- === Recorded flight management ===

function M:clearFlight()
    Settings.dualOpPlayback = false
    Settings.fpvReplay = false
    self.stabCache = nil
    self.recordedFlight = {}
    self.gimbalTrack = {}
    Settings.gimbalRecording = false
    self.recordedClock = nil
    self.recordedInspire = nil
    self.isRecording = true
    self.playbackIndex = 1
    self.recordingTime = 0
    self.playbackElapsedTime = 0
    self.playbackSpec = nil
    self.roninDrift = 0
end

function M:startPlayback()
    if #self.recordedFlight == 0 then return end
    Settings.dualOpPlayback = true
    Settings.fpvReplay = false
    self.playbackIndex = 1
    self.playbackElapsedTime = self.recordedClock == "replay" and self.recordedFlight[1].time or 0
    self.gimbalPitch = 0
    self.gimbalYaw = 0
    self.gimbalRoll = 0
    self.gimbalAppliedMode = nil
    self.gimbalAlign = true
    self.gimbalRecentering = false
    self.currentGimbalYawSpeed = 0
    self.currentGimbalPitchSpeed = 0
    self.currentGimbalRollSpeed = 0
    self.playbackSpec = nil
    self.roninDrift = 0
    self.isRecording = false
end

function M:clearGimbalTrack()
    self.gimbalTrack = {}
    Settings.gimbalRecording = false
end

function M:toggleGimbalRecording()
    if Settings.gimbalRecording then
        Settings.gimbalRecording = false
    elseif Settings.dualOpEnabled and Settings.dualOpPlayback and #self.recordedFlight > 0 then
        Settings.gimbalRecording = true
    end
end

-- Replays the flight seen from the FPV camera (no gimbal), for capturing the footage
function M:startFpvReplay()
    if #self.recordedFlight == 0 then return end
    Settings.dualOpPlayback = false
    Settings.gimbalRecording = false
    Settings.fpvReplay = true
    self.playbackIndex = 1
    self.playbackElapsedTime = self.recordedClock == "replay" and self.recordedFlight[1].time or 0
    self.playbackSpec = nil
    self.roninDrift = 0
    self.isRecording = false
end

function M:stopReplay()
    Settings.dualOpPlayback = false
    Settings.fpvReplay = false
    Settings.gimbalRecording = false
end

-- Orientation of the recorded flight smoothed by the Gyroflow option, at flight time t
function M:stabilizedAttitude(t)
    local frames = self.recordedFlight
    local tau = Settings.gyroflowSmoothness or 0.5
    local cache = self.stabCache
    -- Smoothness being dragged: keep the previous result until the value rests for 0.3 s (avoids a rebuild per tick)
    local now = os.preciseClock()
    if cache and cache.frames == frames and cache.count0 == #frames and cache.tau ~= tau then
        if self.stabTau ~= tau then self.stabTau, self.stabTauSince = tau, now end
        if now - self.stabTauSince < 0.3 then tau = cache.tau end
    end
    if not cache or cache.frames ~= frames or cache.count0 ~= #frames or cache.tau ~= tau then
        cache = buildStabilization(frames, tau) or { count = 0 }
        cache.frames, cache.count0, cache.tau = frames, #frames, tau
        self.stabCache = cache
    end
    if cache.count < 2 then return nil end
    return sampleStabilization(cache, t)
end

-- Gimbal track angles at flight time t, smoothed by the Gyroflow option
function M:stabilizedTrack(t)
    local track = self.gimbalTrack
    local tau = Settings.gyroflowSmoothness or 0.5
    local cache = self.trackStabCache
    local now = os.preciseClock()
    if cache and cache.track == track and cache.count0 == #track and cache.tau ~= tau then
        if self.trackTau ~= tau then self.trackTau, self.trackTauSince = tau, now end
        if now - self.trackTauSince < 0.3 then tau = cache.tau end
    end
    if not cache or cache.track ~= track or cache.count0 ~= #track or cache.tau ~= tau then
        cache = buildTrackStabilization(track, tau) or { count = 0 }
        cache.track, cache.count0, cache.tau = track, #track, tau
        self.trackStabCache = cache
    end
    if cache.count < 2 then return sampleGimbalTrack(track, t) end
    return sampleTrackStabilization(cache, t)
end

-- Simulation value (Physics tab): light turbulence (acceleration, m/s2) and prop wash / vibrations (angular rates,
-- rad/s). Returns nothing when the value is 0 (the behavior is then exactly the one without this feature).
-- throttle: 0..1, airborne: false on the ground
function M:simulationNoise(dt, throttle, airborne)
    local k = math.clamp((Settings.simulationValue or 0) / 100, 0, 1)
    if k <= 0 or not airborne then return nil end
    self.simClock = (self.simClock or 0) + dt
    local t = self.simClock
    -- Gusts: slow, mostly horizontal
    local gust = vec3(layeredNoise(t, 1.3, 0.9), layeredNoise(t, 4.1, 1.3) * 0.5, layeredNoise(t, 7.7, 1.1)) * (1.6 * k)
    -- Prop wash: fast wobble, stronger with throttle and while descending through its own wash
    local descent = math.clamp(-self.velocity.y / 8, 0, 1)
    local amount = k * (0.25 + 0.75 * throttle) * (1 + 1.5 * descent)
    local wash = {
        roll = layeredNoise(t, 2.9, 31) * math.rad(35) * amount,
        pitch = layeredNoise(t, 5.3, 27) * math.rad(35) * amount,
        yaw = layeredNoise(t, 9.1, 19) * math.rad(12) * amount,
    }
    return gust, wash
end

function M:updateFlightList()
    table.clear(self.flights)
    pcall(function()
        io.scanDir(FLIGHTS_PATH, "*.json", function(fileName)
            table.insert(self.flights, (fileName:gsub("%.json$", "")))
        end)
    end)
end

function M:saveFlight(name)
    name = (tostring(name or ""):gsub("[^%w_%-]", ""))
    if name == "" then name = "flight" end
    local frames = self.recordedFlight
    if #frames == 0 then
        self.flightMessage = "No flight to save."
        return
    end

    -- keep at most 60 frames per second to limit the file size
    local out, lastT, n = {}, -1, #frames
    for i, f in ipairs(frames) do
        if i == 1 or i == n or f.time - lastT >= 1 / 60 then
            out[#out + 1] = {
                t = math.round(f.time, 4),
                p = vecToArr(f.position),
                l = vecToArr(f.look),
                u = vecToArr(f.up),
                s = f.spec and vecToArr(f.spec) or nil,
            }
            lastT = f.time
        end
    end
    -- gimbal track (at most 60 samples per second)
    local gOut, gLast = {}, -1
    for i, g in ipairs(self.gimbalTrack) do
        if i == 1 or i == #self.gimbalTrack or g.time - gLast >= 1 / 60 then
            gOut[#gOut + 1] = { math.round(g.time, 4), math.round(g.yaw, 3), math.round(g.pitch, 3), math.round(g.roll, 3) }
            gLast = g.time
        end
    end
    local data = { version = 1, clock = self.recordedClock or "live", inspire = self.recordedInspire, frames = out, gimbal = gOut }

    local ok, err = pcall(function()
        pcall(io.createDir, FLIGHTS_PATH)
        io.save(FLIGHTS_PATH .. name .. ".json", JSON.stringify(data), true)
    end)
    if ok then
        self.flightMessage = string.format("Flight \"%s\" saved (%d frames).", name, #out)
        self:updateFlightList()
    else
        self.flightMessage = "Could not save: " .. tostring(err)
    end
end

function M:loadFlight(name)
    local ok, data = pcall(function() return JSON.parse(io.load(FLIGHTS_PATH .. name .. ".json")) end)
    if not (ok and type(data) == "table" and type(data.frames) == "table" and #data.frames > 0) then
        self.flightMessage = "Could not load flight \"" .. tostring(name) .. "\"."
        return
    end

    local frames = {}
    for _, f in ipairs(data.frames) do
        frames[#frames + 1] = {
            time = f.t,
            position = arrToVec(f.p),
            look = arrToVec(f.l),
            up = arrToVec(f.u),
            spec = f.s and arrToVec(f.s) or nil,
        }
    end

    local track = {}
    if type(data.gimbal) == "table" then
        for _, g in ipairs(data.gimbal) do
            track[#track + 1] = { time = g[1], yaw = g[2], pitch = g[3], roll = g[4] }
        end
    end

    Settings.dualOpPlayback = false
    Settings.fpvReplay = false
    Settings.gimbalRecording = false
    self.stabCache = nil
    self.recordedFlight = frames
    self.gimbalTrack = track
    self.recordedClock = data.clock == "replay" and "replay" or "live"
    if type(data.inspire) == "boolean" then self.recordedInspire = data.inspire else self.recordedInspire = nil end
    self.recordingTime = frames[#frames].time
    self.playbackIndex = 1
    self.playbackElapsedTime = 0
    self.isRecording = false
    self.flightMessage = string.format("Flight \"%s\" loaded (%.1f s).", name, frames[#frames].time)
end

-- === Ronin ===

-- === Ronin modes ===

function M:cycleGimbalMode()
    local current = 1
    for i, m in ipairs(GIMBAL_MODE_ORDER) do if m == Settings.gimbalMode then current = i end end
    Settings.gimbalMode = GIMBAL_MODE_ORDER[current % #GIMBAL_MODE_ORDER + 1]
end

-- Brings the camera back in front of the drone (as the current mode defines "front")
function M:recenterGimbal()
    if Settings.dualOpPlayback then self.gimbalRecentering = true end
end

function M:updateGimbal(dt, cleanRoll, cleanPitch, cleanYaw)
    local mode = GIMBAL_MODES[Settings.gimbalMode] and Settings.gimbalMode or "lock"
    local follow = GIMBAL_MODES[mode]
    local ref, off = self.gimbalRef, self.gimbalOff

    -- Attitude of the drone body
    local droneYaw, dronePitch, droneRoll = bodyAttitude(self.rotation.look, self.rotation.up)
    if droneYaw then self.gimbalLastDroneYaw = droneYaw else droneYaw = self.gimbalLastDroneYaw end

    if self.gimbalAppliedMode ~= mode then
        -- First frame or mode change: the camera must not move, so the offsets take what the references give up
        local yaw, pitch, roll = self.gimbalYaw, self.gimbalPitch, self.gimbalRoll
        ref.yaw = follow.yaw and (yaw + wrapAngle(droneYaw - yaw)) or 0
        ref.pitch = follow.pitch and dronePitch or 0
        ref.roll = follow.roll and (roll + wrapAngle(droneRoll - roll)) or 0
        if self.gimbalAlign then
            off.yaw, off.pitch, off.roll = 0, 0, 0
        else
            off.yaw, off.pitch, off.roll = yaw - ref.yaw, pitch - ref.pitch, roll - ref.roll
        end
        self.gimbalAppliedMode = mode
        self.gimbalAlign = false
    else
        -- The followed axes trail the drone (Follow speed): 0 = immediate, 100 = very slow
        local alpha = smoothingAlpha(Settings.gimbalFollowSpeed or 25, dt)
        ref.yaw = follow.yaw and (ref.yaw + wrapAngle(droneYaw - ref.yaw) * alpha) or 0
        ref.pitch = follow.pitch and (ref.pitch + (dronePitch - ref.pitch) * alpha) or 0
        ref.roll = follow.roll and (ref.roll + wrapAngle(droneRoll - ref.roll) * alpha) or 0
    end

    local track = self.gimbalTrack
    if #track > 0 and not Settings.gimbalRecording then
        -- A gimbal track exists: play it back (follows the flight time, so replay speed / slow motion apply).
        -- The track holds the final angles, so the playback does not depend on the follow state.
        if Settings.gyroflowEnabled then
            self.gimbalYaw, self.gimbalPitch, self.gimbalRoll = self:stabilizedTrack(self.playbackElapsedTime)
        else
            self.gimbalYaw, self.gimbalPitch, self.gimbalRoll = sampleGimbalTrack(track, self.playbackElapsedTime)
        end
        self.currentGimbalYawSpeed, self.currentGimbalPitchSpeed, self.currentGimbalRollSpeed = 0, 0, 0
        self.gimbalRecentering = false
        -- keep the offsets consistent so that a new recording can start without any jump
        off.yaw, off.pitch, off.roll = self.gimbalYaw - ref.yaw, self.gimbalPitch - ref.pitch, self.gimbalRoll - ref.roll
        return
    end

    if cleanRoll ~= 0 or cleanPitch ~= 0 or cleanYaw ~= 0 then self.gimbalRecentering = false end

    if self.gimbalRecentering then
        local finalYaw = ref.yaw + off.yaw
        local targetYaw = follow.yaw and ref.yaw or (finalYaw + wrapAngle(droneYaw - finalYaw))
        local targetPitch = follow.pitch and ref.pitch or 0
        local targetRoll = follow.roll and ref.roll or 0
        local a = 1 - math.exp(-dt / 0.12)
        local dYaw, dPitch, dRoll = (targetYaw - ref.yaw) - off.yaw, (targetPitch - ref.pitch) - off.pitch, (targetRoll - ref.roll) - off.roll
        off.yaw, off.pitch, off.roll = off.yaw + dYaw * a, off.pitch + dPitch * a, off.roll + dRoll * a
        self.currentGimbalYawSpeed, self.currentGimbalPitchSpeed, self.currentGimbalRollSpeed = 0, 0, 0
        if math.abs(dYaw) < 0.3 and math.abs(dPitch) < 0.3 and math.abs(dRoll) < 0.3 then self.gimbalRecentering = false end
    else
        -- Target gimbal speeds (DJI RS 4 Pro style: max speed and expo per axis)
        local targetYaw = -M.gimbalRate(cleanRoll, Settings.gimbalPanMaxSpeed or 120, Settings.gimbalPanExpo or 0)
        local targetPitch = M.gimbalRate(cleanPitch, Settings.gimbalTiltMaxSpeed or 120, Settings.gimbalTiltExpo or 0)
        local targetRoll = M.gimbalRate(cleanYaw, Settings.gimbalRollMaxSpeed or 60, Settings.gimbalRollExpo or 0)

        -- Ronin-style inertia: per-axis stick smoothing
        self.currentGimbalYawSpeed = self.currentGimbalYawSpeed + (targetYaw - self.currentGimbalYawSpeed) * smoothingAlpha(Settings.gimbalPanSmoothing or 20, dt)
        self.currentGimbalPitchSpeed = self.currentGimbalPitchSpeed + (targetPitch - self.currentGimbalPitchSpeed) * smoothingAlpha(Settings.gimbalTiltSmoothing or 20, dt)
        self.currentGimbalRollSpeed = self.currentGimbalRollSpeed + (targetRoll - self.currentGimbalRollSpeed) * smoothingAlpha(Settings.gimbalRollSmoothing or 20, dt)

        off.yaw = off.yaw + self.currentGimbalYawSpeed * dt
        off.pitch = off.pitch + self.currentGimbalPitchSpeed * dt
        off.roll = off.roll + self.currentGimbalRollSpeed * dt
    end

    -- The tilt limit applies to the final angle
    off.pitch = math.clamp(ref.pitch + off.pitch, GIMBAL_TILT_MIN, GIMBAL_TILT_MAX) - ref.pitch

    self.gimbalYaw, self.gimbalPitch, self.gimbalRoll = ref.yaw + off.yaw, ref.pitch + off.pitch, ref.roll + off.roll

    if Settings.gimbalRecording then
        recordGimbalSample(track, self.playbackElapsedTime, self.gimbalYaw, self.gimbalPitch, self.gimbalRoll)
    end
end

-- === Inspire mode (DJI Inspire 3 style: GPS-assisted flight) ===
-- The sticks command velocities, not rotation rates: pitch/roll = horizontal speed (forward/sideways),
-- throttle = climb/descent speed, yaw = yaw rate. Releasing the sticks brakes the drone to a standstill.
-- The body only tilts into the acceleration (and leans a little with speed), like the real aircraft.
function M:updateInspire(dt, positionDt, cleanRoll, cleanPitch, cleanYaw, cleanThrottle)
    local worldUp = vec3(0, 1, 0)

    -- Heading: horizontal direction the nose points to
    if not self.inspireHeading then
        local h = vec3(self.rotation.look.x, 0, self.rotation.look.z)
        if h:length() < 0.2 then h = vec3(0, 0, 1) end
        self.inspireHeading = h:normalize()
        self.inspireTiltPitch, self.inspireTiltRoll, self.inspireTiltLag, self.inspireTiltLag1 = 0, 0, 0, 0
    end

    local expo = Settings.inspireExpo or 0.3
    local function shape(x) return x * (1 - expo) + x * x * x * expo end

    -- Yaw (same sign convention as the FPV mode)
    local yawRate = math.rad(shape(cleanYaw) * (Settings.inspireYawRate or 100))
    self.inspireHeading:rotate(quat.fromAngleAxis(-yawRate * dt, worldUp)):normalize()
    local heading = self.inspireHeading

    -- Horizontal directions that the stick pitch / roll push toward. They are measured with the same
    -- quaternions as the FPV mode, so stick directions and inversions behave exactly like in the FPV mode.
    local side0 = math.cross(heading, worldUp):normalize()
    local fwdDir = worldUp:clone():rotate(quat.fromAngleAxis(-0.1, side0))
    fwdDir.y = 0
    fwdDir:normalize()
    local rightDir = worldUp:clone():rotate(quat.fromAngleAxis(0.1, heading))
    rightDir.y = 0
    rightDir:normalize()

    -- Target velocity from the sticks
    local vmax = Settings.inspireMaxSpeed or 26
    local targetH = fwdDir * (shape(cleanPitch) * vmax) + rightDir * (shape(cleanRoll) * vmax)
    if targetH:length() > vmax then targetH:scale(vmax / targetH:length()) end
    local targetV = shape(cleanThrottle) * (Settings.inspireClimbSpeed or 8)

    -- Acceleration toward the target velocity (first order response, limited)
    local tau = math.max(Settings.inspireResponse or 0.8, 0.05)
    local maxAccel = Settings.inspireMaxAccel or 8
    local v = self.velocity
    local ah = vec3((targetH.x - v.x) / tau, 0, (targetH.z - v.z) / tau)
    if ah:length() > maxAccel then ah:scale(maxAccel / ah:length()) end
    local av = math.clamp((targetV - v.y) / tau, -maxAccel * 0.6, maxAccel * 0.6)
    local acceleration = vec3(ah.x, av, ah.z)

    -- Specific force for the Ronin drift (accelerometer): acceleration minus gravity
    local lastFrame = M.recordedFlight[#M.recordedFlight]
    if Settings.dualOpEnabled and M.isRecording and lastFrame then
        lastFrame.spec = acceleration + vec3(0, 9.8 * Settings.gravity, 0)
    end

    -- Simulation value: light turbulence and vibrations (nothing at 0)
    local gust, wash = self:simulationNoise(dt, 0.5 + 0.5 * math.abs(shape(cleanThrottle)),
        self.position.y > Settings.groundLevel + 0.5)
    if gust then acceleration = acceleration + gust end

    self.velocity:addScaled(acceleration, dt)
    self.position:addScaled(self.velocity, positionDt)

    if self.position.y < Settings.groundLevel + 0.1 then
        self.position.y = Settings.groundLevel + 0.1
        self.velocity.y = 0.01
    end

    self:collision()

    -- Body attitude: tilt into the acceleration, plus a small lean with the speed
    local maxTilt = math.rad(Settings.inspireMaxTilt or 25)
    local tiltPitchTarget = math.clamp(math.atan((ah:dot(fwdDir) + self.velocity:dot(fwdDir) * 0.1) / 9.8), -maxTilt, maxTilt)
    local tiltRollTarget = math.clamp(math.atan((ah:dot(rightDir) + self.velocity:dot(rightDir) * 0.1) / 9.8), -maxTilt, maxTilt)
    local alpha = 1 - math.exp(-dt / INSPIRE_TILT_TAU)
    self.inspireTiltPitch = self.inspireTiltPitch + (tiltPitchTarget - self.inspireTiltPitch) * alpha
    self.inspireTiltRoll = self.inspireTiltRoll + (tiltRollTarget - self.inspireTiltRoll) * alpha
    if wash then
        -- the airframe vibrates a little (the camera compensates the pitch, so the horizon stays calm)
        self.inspireTiltPitch = self.inspireTiltPitch + wash.pitch * 0.25 * dt
        self.inspireTiltRoll = self.inspireTiltRoll + wash.roll * 0.25 * dt
    end

    -- The camera counter-rotates the body pitch, with a small delay (like a gimbal catching up).
    -- Two cascaded low-pass stages: the same short delay but a smooth start instead of a sudden catch-up.
    local lagAlpha = 1 - math.exp(-dt / INSPIRE_HORIZON_TAU)
    self.inspireTiltLag1 = self.inspireTiltLag1 + (self.inspireTiltPitch - self.inspireTiltLag1) * lagAlpha
    self.inspireTiltLag = self.inspireTiltLag + (self.inspireTiltLag1 - self.inspireTiltLag) * lagAlpha

    local q = quat.fromAngleAxis(-self.inspireTiltPitch, side0) * quat.fromAngleAxis(self.inspireTiltRoll, heading)
    self.rotation.look = heading:clone():rotate(q):normalize()
    self.rotation.up = worldUp:clone():rotate(q):normalize()

    return math.cross(self.rotation.look, self.rotation.up)
end

function M:updateRoninDrift(dt, camSide)
    local target = 0
    if self.playbackSpec then
        -- force specifique (ce que mesure l'accelerometre du Ronin) projetee sur l'axe lateral de la camera
        local latG = self.playbackSpec:dot(camSide) / 9.8
        target = math.clamp(RONIN_DRIFT_SIGN * RONIN_DRIFT_DEG_PER_G * latG, -RONIN_DRIFT_MAX_DEG, RONIN_DRIFT_MAX_DEG)
    end
    self.roninDrift = self.roninDrift + (target - self.roninDrift) * (1 - math.exp(-dt / RONIN_DRIFT_TAU))
    return self.roninDrift
end

function M:update(dt)
    Input:update()
    if Input.toggleSleepButton.pressed then self:toggleSleep() end
    -- Arm / disarm: three separate keybinds (arm only, disarm only, toggle)
    if Input.armButton.pressed and not self.active then self:toggle() end
    if Input.disarmButton.pressed and self.active then self:toggle() end
    if Input.armToggleButton.pressed then self:toggle() end

    -- Inspire flight modes and Ronin modes
    if Input.inspireModeTButton.pressed then Settings:setInspireMode("T") end
    if Input.inspireModeNButton.pressed then Settings:setInspireMode("N") end
    if Input.inspireModeSButton.pressed then Settings:setInspireMode("S") end
    if Input.gimbalModeButton.pressed then M:cycleGimbalMode() end
    if Input.gimbalRecenterButton.pressed then M:recenterGimbal() end

    -- Self-heal: playback cannot be active without a recorded flight
    -- (this used to leave the drone stuck at load: dualOpPlayback stayed true in settings.json)
    if (Settings.dualOpPlayback or Settings.fpvReplay) and (not Settings.dualOpEnabled or #M.recordedFlight == 0) then
        Settings.dualOpPlayback = false
        Settings.fpvReplay = false
    end

    if Settings.gimbalRecording and not Settings.dualOpPlayback then
        Settings.gimbalRecording = false
    end
    if Input.toggleGimbalRecordButton and Input.toggleGimbalRecordButton.pressed then
        M:toggleGimbalRecording()
    end

    -- Gestion du Keybind Playback
    if Input.togglePlaybackButton and Settings.dualOpEnabled then
        if Input.togglePlaybackButton.down then
            M.resetHoldTimer = M.resetHoldTimer + dt
            if M.resetHoldTimer >= 1.0 and not M.stoppedByHold then
                M:clearFlight()
                M.stoppedByHold = true
            end
        else
            if M.resetHoldTimer > 0 and M.resetHoldTimer < 1.0 and not M.stoppedByHold then
                if #M.recordedFlight > 0 then
                    if Settings.dualOpPlayback or Settings.fpvReplay then
                        M:stopReplay()
                    else
                        M:startPlayback()
                    end
                end
            end
            M.resetHoldTimer = 0
            M.stoppedByHold = false
        end
    end

    if not self.active or self.sleep then return end

    local dz = Settings.gimbalDeadzone or 0
    local cleanRoll = applyDeadzone(Input.roll, dz)
    local cleanPitch = applyDeadzone(Input.pitch, dz)
    local cleanYaw = applyDeadzone(Input.yaw, dz)

    local sim = ac.getSim()
    local replayTime = getReplayTime(sim)

    dt = dt * Settings.time

    -- positionDt synchronised on the car timestamp (removes car jitter)
    local positionDt = dt
    -- (not in replays: car timestamps do not advance there, which used to freeze the drone; the scan of all the
    -- cars is skipped there too)
    if replayTime then
        self.lastClosestCarTimestamp = nil
    else
        local closestCar = getClosestCar(self.position)
        if self.lastClosestCarTimestamp and not closestCar.extrapolatedMovement then
            positionDt = (closestCar.timestamp - self.lastClosestCarTimestamp) / 1000
        end
        self.lastClosestCarTimestamp = closestCar.timestamp
    end

    local sideVector = math.cross(self.rotation.look, self.rotation.up)
    local lookVector = self.rotation.look
    local upVector = self.rotation.up

    -- Mode Relecture Dual OP
    if Settings.dualOpEnabled and (Settings.dualOpPlayback or Settings.fpvReplay) then
        local frames = M.recordedFlight
        if #frames > 0 then
            -- Advance the playback time, synchronised on the car ticks
            -- Slow motion: 2x to 12x slower (the gimbal stays real-time)
            if replayTime and M.recordedClock == "replay" then
                -- Synced to the replay: follows pause, rewind, jumps and replay speed by itself
                M.playbackElapsedTime = replayTime
            else
                local speed = Settings.slowMotionEnabled and 1 / math.max(Settings.slowMotionFactor or 2, 1) or 1
                M.playbackElapsedTime = math.max(0, M.playbackElapsedTime + positionDt * speed)
            end
            M.playbackIndex = findFrameIndex(frames, M.playbackElapsedTime)

            local frameA = frames[M.playbackIndex]
            local frameB = frames[M.playbackIndex + 1]

            if frameA and frameB then
                local tA = frameA.time
                local tB = frameB.time
                local factor = 0
                if tB > tA then
                    factor = math.clamp((M.playbackElapsedTime - tA) / (tB - tA), 0, 1)
                end

                self.position = frameA.position:clone():addScaled(frameB.position - frameA.position, factor)
                self.rotation.look = frameA.look:clone():addScaled(frameB.look - frameA.look, factor):normalize()
                self.rotation.up = frameA.up:clone():addScaled(frameB.up - frameA.up, factor):normalize()

                if frameA.spec and frameB.spec then
                    M.playbackSpec = frameA.spec:clone():addScaled(frameB.spec - frameA.spec, factor)
                else
                    M.playbackSpec = nil
                end
            elseif frameA then
                self.position = frameA.position:clone()
                self.rotation.look = frameA.look:clone()
                self.rotation.up = frameA.up:clone()
                M.playbackSpec = frameA.spec
            end

            -- Gyroflow option: the recorded body attitude is stabilized (FPV replay, and the reference that the
            -- gimbal follows in the Ronin follow modes)
            if Settings.gyroflowEnabled then
                local look, up = M:stabilizedAttitude(M.playbackElapsedTime)
                if look then
                    self.rotation.look, self.rotation.up = look, up
                end
            end
            if Settings.dualOpPlayback then
                M:updateGimbal(dt, cleanRoll, cleanPitch, cleanYaw)
            else
                sideVector = math.cross(self.rotation.look, self.rotation.up)
            end
        end
    else
        -- Recording / free flight
        if Settings.dualOpEnabled and self.active and M.isRecording then
            local frames = M.recordedFlight
            if #frames == 0 then
                M.recordedClock = replayTime and "replay" or "live"
                M.recordedInspire = Settings.inspireMode and true or false
                M.recordingTime = replayTime or 0
            end

            local entry
            if M.recordedClock == "replay" and replayTime then
                -- Frames are keyed by replay time. Replay paused: the last frame is overwritten.
                -- Replay rewound: the take is cut at that point and recorded again from there.
                local last = frames[#frames]
                local replayLength = sim.replayFrames * sim.replayFrameMs / 1000
                if last and replayTime < last.time - 1 and last.time >= replayLength - 0.5 then
                    -- The replay reached its end and started over: the flight is complete, it must not be overwritten
                    M.isRecording = false
                    M.flightMessage = "End of the replay reached: recording stopped, the flight is kept."
                    last = nil
                    entry = nil
                elseif last and replayTime < last.time - 0.001 then
                    while #frames > 0 and frames[#frames].time >= replayTime do table.remove(frames) end
                    last = nil
                end
                if M.isRecording then
                    M.recordingTime = replayTime
                    entry = { time = replayTime }
                    if last and replayTime <= last.time then
                        frames[#frames] = entry
                    else
                        frames[#frames + 1] = entry
                    end
                end
            elseif M.recordedClock == "live" and not replayTime then
                if #frames > 0 then M.recordingTime = M.recordingTime + dt end
                entry = { time = M.recordingTime }
                frames[#frames + 1] = entry
            end
            -- (a flight can not mix live and replay recording: frames are skipped in the other mode)

            if entry then
                entry.position = self.position:clone()
                entry.look = self.rotation.look:clone()
                entry.up = self.rotation.up:clone()
            end
        end

        if Settings.inspireMode then
            sideVector = self:updateInspire(dt, positionDt, cleanRoll, cleanPitch, cleanYaw,
                applyDeadzone(Input.throttle, dz))
        else
            self.inspireHeading = nil
            local inflowCoefficient = 1 - math.sin(vectorAngle(upVector:clone(), self.velocity:clone()))
            local inflowVelocity = self.velocity:length() * inflowCoefficient

            local thrustForce = upVector:clone():scale(thrust(Settings.linearAcceleration, Settings.airDensity,
                Settings.propDiameter, Settings.propPitch, Settings.motorKv, Settings.batteryCells,
                Settings.mode3d and Input.throttle or (Input.throttle + 1) / 2, inflowVelocity))

            local airDragForce = vec3()
            if not Input.disableAirDragAndFrictionButton.down then
                airDragForce = airDragForceFn(1.2 * Settings.airDensity, self.velocity, Settings.airDrag,
                    Settings.droneSurfaceArea, Settings.minimalSurfaceAreaCoefficient, inflowCoefficient)
            end

            local force = thrustForce + airDragForce
            local acceleration = force / Settings.droneMass + vec3(0, -9.8 * Settings.gravity, 0)

            -- Simulation value: light turbulence and prop wash (nothing at 0)
            local gust, wash = self:simulationNoise(dt, Settings.mode3d and math.abs(Input.throttle) or (Input.throttle + 1) / 2,
                self.position.y > Settings.groundLevel + 0.5)
            if gust then acceleration = acceleration + gust end

            -- Store the specific force in the recorded frame (Ronin accelerometer)
            local lastFrame = M.recordedFlight[#M.recordedFlight]
            if Settings.dualOpEnabled and M.isRecording and lastFrame then
                lastFrame.spec = force / Settings.droneMass
            end

            self.velocity:addScaled(acceleration, dt)

            self.position:addScaled(self.velocity, positionDt)

            if self.position.y < Settings.groundLevel + 0.1 then
                self.position.y = Settings.groundLevel + 0.1
                self.velocity.y = 0.01
            end

            self:collision()

            local rateFunction = self.rateFunctions[Settings.rates.type]
            local rotation = {
                roll = math.rad(rateFunction(cleanRoll, Settings.rates.roll)) * dt,
                pitch = math.rad(rateFunction(cleanPitch, Settings.rates.pitch)) * dt,
                yaw = math.rad(rateFunction(cleanYaw, Settings.rates.yaw)) * dt
            }
            if wash then
                rotation.roll = rotation.roll + wash.roll * dt
                rotation.pitch = rotation.pitch + wash.pitch * dt
                rotation.yaw = rotation.yaw + wash.yaw * dt
            end

            local rotationQuat =
                quat.fromAngleAxis(-rotation.pitch, sideVector) *
                quat.fromAngleAxis(rotation.roll, lookVector) *
                quat.fromAngleAxis(-rotation.yaw, upVector)

            self.rotation.look:rotate(rotationQuat):normalize()
            sideVector:rotate(rotationQuat):normalize()
            self.rotation.up = self.rotation.look:clone():rotate(quat.fromAngleAxis(math.rad(90), sideVector))
        end
    end

    -- Final camera position with the drone elevation offset
    local cameraPosition = self.position + self.rotation.up * 0.1
    local finalLook, finalUp

    local playbackActive = Settings.dualOpEnabled and Settings.dualOpPlayback and #M.recordedFlight > 0
    local cameraFov = Settings.cameraFov

    if playbackActive then
        local worldUp = vec3(0, 1, 0)
        local defaultLook = vec3(0, 0, 1)
        local defaultRight = math.cross(defaultLook, worldUp):normalize()

        -- Gimbal chain (pan -> roll -> tilt, like the RS 4 Pro): tilt happens around the camera's own
        -- right axis AFTER the roll, so with a rolled horizon the camera tilts diagonally.
        -- No gimbal lock at 90 deg tilt: the tilt axis can go past straight down (top shot).
        local yawQuat = quat.fromAngleAxis(math.rad(M.gimbalYaw), worldUp)

        -- Level (horizon-aligned) right axis, used by the Ronin drift
        local levelRight = math.cross(defaultLook:clone():rotate(yawQuat), worldUp):normalize()

        local driftDeg = 0
        if Settings.roninDrift then
            driftDeg = self:updateRoninDrift(dt, levelRight)
        else
            self.roninDrift = 0
        end

        local gimbalQuat = yawQuat
                         * quat.fromAngleAxis(math.rad(M.gimbalRoll + driftDeg), defaultLook)
                         * quat.fromAngleAxis(math.rad(M.gimbalPitch), defaultRight)

        finalLook = defaultLook:clone():rotate(gimbalQuat)
        finalUp = worldUp:clone():rotate(gimbalQuat)

        -- Gimbal camera angle (kept at 0)
        if GIMBAL_CAMERA_ANGLE ~= 0 then
            local finalRightVec = math.cross(finalLook, finalUp):normalize()
            local cameraAngleQuat = quat.fromAngleAxis(math.rad(GIMBAL_CAMERA_ANGLE), finalRightVec)
            finalLook:rotate(cameraAngleQuat)
            finalUp:rotate(cameraAngleQuat)
        end

        cameraFov = focalToFov(Settings.focalLength or 35)
    else
        self.roninDrift = 0
        -- Inspire mode: the FPV camera angle is ignored (its value is kept for the FPV mode); the camera holds the
        -- horizon by compensating the (delayed) body pitch, plus the Inspire camera tilt offset.
        local camAngle = Settings.cameraAngle
        -- FPV replay: the camera behaves like in the mode the flight was recorded in, not like the current mode
        local inspireCamera = Settings.inspireMode
        if Settings.dualOpEnabled and Settings.fpvReplay and M.recordedInspire ~= nil then
            inspireCamera = M.recordedInspire
        end
        if inspireCamera then
            if Settings.dualOpEnabled and Settings.fpvReplay then
                -- replay: the horizon is held from the recorded body pitch itself (no live state to lag)
                camAngle = (Settings.inspireCameraTilt or 0) - math.deg(math.asin(math.clamp(self.rotation.look.y, -1, 1)))
            else
                camAngle = (Settings.inspireCameraTilt or 0) + math.deg(self.inspireTiltLag)
            end
            cameraFov = Settings.inspireCameraFov or 110
        end
        -- FPV replay (Record tab): the lens is the Record focal length; the FPV / Inspire FOV settings stay untouched
        if Settings.dualOpEnabled and Settings.fpvReplay then
            cameraFov = focalToFov(Settings.focalLength or 20)
        end
        local cameraAngleQuat = quat.fromAngleAxis(math.rad(camAngle), sideVector)
        finalLook = self.rotation.look:clone():rotate(cameraAngleQuat)
        finalUp = self.rotation.up:clone():rotate(cameraAngleQuat)
    end

    -- CSP fix: writing into self.camera.transform is required to unlock rotation while keeping LOD and smoothness
    if self.camera and self.camera.transform then
        self.camera.transform.position = cameraPosition
        self.camera.transform.look = finalLook
        self.camera.transform.up = finalUp
        self.camera.fov = cameraFov
    else
        ac.setCameraPosition(cameraPosition)
        ac.setCameraDirection(finalLook, finalUp)
        ac.setCameraFOV(cameraFov)
    end

    if Input.savePositionButton.pressed then
        self.savedState = {
            position = self.position:clone(),
            look = self.rotation.look:clone(),
            up = self.rotation.up:clone(),
            velocity = self.velocity:clone(),
        }
    end
    if Input.teleportToPositionButton.pressed and self.savedState then
        self.position = self.savedState.position:clone()
        self.rotation.look = self.savedState.look:clone()
        self.rotation.up = self.savedState.up:clone()
        self.velocity = self.savedState.velocity:clone()
        self.lastPosition = nil
    end
end

local trackRoot = ac.findNodes("trackRoot:yes")
local hitMesh = ac.emptySceneReference()

local function collisionRaycast(fromPos, toPos, scene)
    local vec, point, normal = toPos - fromPos, vec3(), vec3()
    local distance = scene:raycast(render.createRay(fromPos, vec, vec:length()), hitMesh, point, normal, nil, 0)
    local hit = point:length() ~= 0

    if hit then
        local meshTransform = hitMesh:getWorldTransformationRaw()
        point = fromPos + vec:clone():normalize():scale(distance)
        normal = mat4x4.translation(normal):mulSelf(mat4x4.look(vec3(), -meshTransform.look, meshTransform.up):inverseSelf()).position

        local v0 = point:clone():addScaled(normal, 0.05)
        local r1 = point:clone():sub(v0):rotate(quat.fromAngleAxis(math.pi / 4, math.cross(normal, vec3(0, 1, 0)):normalize())):normalize()
        local r2 = r1:clone():rotate(quat.fromAngleAxis(math.pi / 2, normal))
        local d1 = hitMesh:raycast(render.createRay(v0, r1, 0.2))
        local d2 = hitMesh:raycast(render.createRay(v0, r2, 0.2))
        if d1 ~= -1 and d2 ~= -1 then
            local p1 = v0:clone():addScaled(r1, d1)
            local p2 = v0:clone():addScaled(r2, d2)
            normal = math.cross(point:clone():sub(p1), point:clone():sub(p2)):normalize()
        end
    end

    return hit, point, normal
end

function M:collision()
    if self.lastPosition then
        -- Hovering / resting: the drone barely moved, no raycast (the movement keeps adding up until it matters)
        local d = self.position - self.lastPosition
        if d:dot(d) < 1e-6 then return end
    end
    if self.lastPosition and Settings.collision and not Input.disableCollisionButton.down then
        for i = 1, 2 do
            local hit, point, normal = collisionRaycast(self.lastPosition, self.position, trackRoot)

            if not hit then
                break
            else
                self.velocity = self.velocity - normal * self.velocity:dot(normal) * (1 + Settings.bounciness)

                if not Input.disableAirDragAndFrictionButton.down then
                    self.velocity = self.velocity - excludeVector(self.velocity:clone():normalize(), normal)
                        * math.min(1, self.velocity:length() * Settings.groundFriction * 0.5)
                end

                if i == 1 then
                    self.position = point + excludeVector(self.position - point, normal) + normal / 500
                else
                    self.position = self.lastPosition + (point - self.lastPosition) * 0.2
                end
            end
        end
    end
    self.lastPosition = self.position:clone()
end

M.rateFunctions = {
    betaflight = function(input, parameters)
        local inputAbs = math.abs(input)
        local rcCommandf = input * inputAbs^3 * parameters.expo + input * (1 - parameters.expo);
        local rcRate = parameters.rate
        if rcRate > 2 then
            rcRate = rcRate + 14.54 * (rcRate - 2)
        end
        local rcSuperfactor = 1 / (math.clamp(1 - (inputAbs * parameters.super), 0.01, 1))
        local angleRate = 200 * rcRate * rcCommandf * rcSuperfactor
        return angleRate
    end,
    actual = function(input, parameters)
        local inputAbs = math.abs(input)
        local expo = inputAbs * (input^5 * parameters.expo + input * (1 - parameters.expo))
        local stickMovement = math.max(0, parameters.maxRate - parameters.centerSensitivity);
        local angleRate = input * parameters.centerSensitivity + stickMovement * expo;
        return angleRate
    end,
    kiss = function(input, parameters)
        local inputAbs = math.abs(input)
        local kissRpyUseRates = 1 / math.clamp(1 - (inputAbs * parameters.super), 0.01, 1)
        local kissRcCommandf = (input^3 * parameters.curve + input * (1 - parameters.curve)) * (parameters.rate / 10)
        local kissAngle = math.clamp(2000 * kissRpyUseRates * kissRcCommandf, -1998, 1998)
        return kissAngle
    end,
}

-- Rotation speed (deg/s) for a stick position between -1 and 1: expo curve, then max speed
function M.gimbalRate(input, maxSpeed, expo)
    return (input * (1 - expo) + input * input * input * expo) * maxSpeed
end
M.applyDeadzone = applyDeadzone
M.gimbalModeOrder = GIMBAL_MODE_ORDER
M.gimbalModeNames = GIMBAL_MODE_NAMES
M.flightsPath = FLIGHTS_PATH
M:updateFlightList()

return M
