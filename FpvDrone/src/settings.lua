-- === Default values: the single source of truth ===
-- Everything that has a default lives here (the UI Reset buttons read these tables too).

-- Default drone rates per type (used by the type selector, the Reset button and as a fallback)
local function defaultDroneRates(rateType)
    if rateType == "actual" then
        return {
            type = "actual",
            pitch = { centerSensitivity = 182, maxRate = 667, expo = 0.5 },
            roll = { centerSensitivity = 182, maxRate = 667, expo = 0.5 },
            yaw = { centerSensitivity = 182, maxRate = 667, expo = 0.5 },
        }
    elseif rateType == "kiss" then
        return {
            type = "kiss",
            pitch = { rate = 1, super = 0.7, curve = 0 },
            roll = { rate = 1, super = 0.7, curve = 0 },
            yaw = { rate = 1, super = 0.7, curve = 0 },
        }
    end
    return {
        type = "betaflight",
        pitch = { rate = 1, super = 0.7, expo = 0 },
        roll = { rate = 1, super = 0.7, expo = 0 },
        yaw = { rate = 1, super = 0.7, expo = 0 },
    }
end

-- Dual OP (gimbal) rates, DJI RS 4 Pro style: max speed (deg/s), smoothing (0-100), expo (0-1)
local DEFAULT_GIMBAL_RATES = {
    gimbalPanMaxSpeed = 120, gimbalTiltMaxSpeed = 120, gimbalRollMaxSpeed = 60,
    gimbalPanSmoothing = 20, gimbalTiltSmoothing = 20, gimbalRollSmoothing = 20,
    gimbalPanExpo = 0, gimbalTiltExpo = 0, gimbalRollExpo = 0,
    gimbalFollowSpeed = 25,   -- how fast the gimbal follows the drone in the follow modes (0 = immediate, 100 = very slow)
}

-- Inspire mode (DJI Inspire 3 style flight): three flight modes, each with its own parameters
local INSPIRE_MODE_KEYS = {
    "inspireMaxSpeed", "inspireClimbSpeed", "inspireYawRate", "inspireResponse",
    "inspireMaxAccel", "inspireMaxTilt", "inspireExpo",
}
local INSPIRE_MODES = {
    T = { name = "Tripod", params = { inspireMaxSpeed = 7, inspireClimbSpeed = 3, inspireYawRate = 30, inspireResponse = 1.4,
                                      inspireMaxAccel = 3, inspireMaxTilt = 12, inspireExpo = 0.5 } },
    N = { name = "Normal", params = { inspireMaxSpeed = 20, inspireClimbSpeed = 8, inspireYawRate = 80, inspireResponse = 0.9,
                                      inspireMaxAccel = 6, inspireMaxTilt = 20, inspireExpo = 0.3 } },
    S = { name = "Sport", params = { inspireMaxSpeed = 36, inspireClimbSpeed = 12, inspireYawRate = 100, inspireResponse = 0.8,
                                     inspireMaxAccel = 8, inspireMaxTilt = 25, inspireExpo = 0.3 } },
}
local INSPIRE_MODE_ORDER = { "T", "N", "S" }
local DEFAULT_INSPIRE_MODE = "S"
-- Shared by the three modes
local DEFAULT_INSPIRE_CAMERA = { inspireCameraTilt = 0, inspireCameraFov = 110 }

-- Keybinds: every button the mod reads (see input.lua)
local KEYBIND_NAMES = {
    "armButton", "disarmButton", "armToggleButton", "toggleSleepButton",
    "disableAirDragAndFrictionButton", "disableCollisionButton", "savePositionButton", "teleportToPositionButton",
    "togglePlaybackButton", "toggleGimbalRecordButton", "gimbalModeButton", "gimbalRecenterButton",
    "inspireModeTButton", "inspireModeNButton", "inspireModeSButton",
}

-- Everything the newer features need, so that older settings files and presets always load completely
local DEFAULTS = {
    rates = defaultDroneRates("betaflight"),
    dualOpEnabled = false,
    dualOpPlayback = false,      -- transient
    gimbalRecording = false,     -- transient
    fpvReplay = false,           -- transient: replay of the flight seen from the FPV camera (Record tab)
    gyroflowEnabled = false,     -- Gyroflow style stabilization of the FPV replay
    gyroflowSmoothness = 0.5,    -- seconds
    simulationValue = 0,         -- 0..100: light turbulence and prop wash (0 = off)
    gimbalDeadzone = 0,
    gimbalMode = "lock",         -- lock | pan | pantilt | fpv (Ronin follow modes)
    roninDrift = false,
    focalLength = 20,
    slowMotionEnabled = false,
    slowMotionFactor = 2,
    inspireMode = false,
    inspireFlightMode = DEFAULT_INSPIRE_MODE,
    inspireModeParams = {},      -- per flight mode parameters (the flat inspire* values are the active mode's)
}
for k, v in pairs(DEFAULT_GIMBAL_RATES) do DEFAULTS[k] = v end
for k, v in pairs(DEFAULT_INSPIRE_CAMERA) do DEFAULTS[k] = v end
for _, k in ipairs(INSPIRE_MODE_KEYS) do DEFAULTS[k] = INSPIRE_MODES[DEFAULT_INSPIRE_MODE].params[k] end
for mode, def in pairs(INSPIRE_MODES) do
    DEFAULTS.inspireModeParams[mode] = {}
    for k, v in pairs(def.params) do DEFAULTS.inspireModeParams[mode][k] = v end
end
for _, name in ipairs(KEYBIND_NAMES) do DEFAULTS[name] = { type = "none", key = -1 } end

-- Transient states: never written to a file, never restored
local TRANSIENT = { "dualOpPlayback", "gimbalRecording", "fpvReplay" }

local function copyValue(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copyValue(x) end
    return c
end

local M = {
    path = ac.dirname().."/settings/settings.json",
    presetsPath = ac.dirname().."/settings/presets/",
    presets = {},
    notDeletablePresetsMap = { defaultNoInput = true, dualshock4 = true, xbox360 = true },
    settings = {},
    finalizer = newproxy(true),
    defaults = DEFAULTS,
    defaultDroneRates = defaultDroneRates,
    defaultGimbalRates = DEFAULT_GIMBAL_RATES,
    inspireModes = INSPIRE_MODES,
    inspireModeOrder = INSPIRE_MODE_ORDER,
    keybindNames = KEYBIND_NAMES,
}
-- this saves settings in the json file when the game closes gracefully
getmetatable(M.finalizer).__gc = function(_) M:saveSettings() end

-- isFallback: set when loading the fallback preset, to never loop if that preset is unusable too
function M:load(isFallback)
    local settings = JSON.parse(io.load(self.path))

    -- check if settings file exists and is not empty
    if not (type(settings) == "table" and settings.inputDeviceGUID) and not isFallback then
        local preset = io.load(self.presetsPath .. "defaultNoInput.json")
        if preset then
            -- first launch: the stick deadzone starts at zero whatever the preset says
            local parsed = JSON.parse(preset)
            if type(parsed) == "table" then
                parsed.gimbalDeadzone = 0
                preset = JSON.stringify(parsed)
            end
            io.save(self.path, preset)
            return self:load(true)
        end
    end
    if type(settings) ~= "table" then settings = {} end

    table.clear(self.settings)

    -- Defaults first (avoids UI crashes with settings files / presets written by older versions)
    for k, v in pairs(DEFAULTS) do
        self.settings[k] = copyValue(v)
    end

    -- Then the saved settings. A saved value of the wrong type (damaged file) keeps the default.
    for k, v in pairs(settings) do
        local default = DEFAULTS[k]
        if default == nil or type(default) == type(v) then
            self.settings[k] = v
        end
    end

    -- "Toggle drone" became "Arm": a binding saved by an older version is kept as the Arm binding
    if self.settings.toggleDroneButton ~= nil then
        if settings.armButton == nil and type(settings.toggleDroneButton) == "table" then
            self.settings.armButton = copyValue(settings.toggleDroneButton)
        end
        self.settings.toggleDroneButton = nil
    end

    -- Inspire flight modes: make sure the stored parameter sets are complete and consistent
    local st = self.settings
    if not INSPIRE_MODES[st.inspireFlightMode] then st.inspireFlightMode = DEFAULT_INSPIRE_MODE end
    local savedParams = settings.inspireModeParams
    for mode, def in pairs(INSPIRE_MODES) do
        local set = type(st.inspireModeParams[mode]) == "table" and st.inspireModeParams[mode] or {}
        for _, k in ipairs(INSPIRE_MODE_KEYS) do
            if type(set[k]) ~= "number" then set[k] = def.params[k] end
        end
        st.inspireModeParams[mode] = set
    end
    if type(savedParams) ~= "table" then
        -- file from before the flight modes: its flat values were the settings of the active mode
        for _, k in ipairs(INSPIRE_MODE_KEYS) do st.inspireModeParams[st.inspireFlightMode][k] = st[k] end
    else
        -- the flat values are the active mode's parameters
        for _, k in ipairs(INSPIRE_MODE_KEYS) do st[k] = st.inspireModeParams[st.inspireFlightMode][k] end
    end

    -- Transient states are never restored from a file
    -- (otherwise the drone stayed stuck at load while no flight was recorded)
    for _, k in ipairs(TRANSIENT) do self.settings[k] = DEFAULTS[k] end

    Input:updateInputDevice()
end

-- Switches the Inspire flight mode (T / N / S): the edited parameters of the current mode are kept
function M:setInspireMode(mode)
    local st = self.settings
    if not INSPIRE_MODES[mode] then return end
    local current = st.inspireFlightMode
    if INSPIRE_MODES[current] then
        for _, k in ipairs(INSPIRE_MODE_KEYS) do st.inspireModeParams[current][k] = st[k] end
    end
    for _, k in ipairs(INSPIRE_MODE_KEYS) do st[k] = st.inspireModeParams[mode][k] end
    st.inspireFlightMode = mode
end

-- Resets the active Inspire flight mode (and the shared camera settings) to the defaults
function M:resetInspire()
    local st = self.settings
    local mode = INSPIRE_MODES[st.inspireFlightMode] and st.inspireFlightMode or DEFAULT_INSPIRE_MODE
    for _, k in ipairs(INSPIRE_MODE_KEYS) do
        st[k] = INSPIRE_MODES[mode].params[k]
        st.inspireModeParams[mode][k] = INSPIRE_MODES[mode].params[k]
    end
    for k, v in pairs(DEFAULT_INSPIRE_CAMERA) do st[k] = v end
end

-- Copy of the settings without transient states, for writing to disk
function M:serialize()
    local copy = {}
    for k, v in pairs(self.settings) do copy[k] = v end
    for _, k in ipairs(TRANSIENT) do copy[k] = nil end
    -- keep the active Inspire mode's edits in its stored parameter set
    copy.inspireModeParams = copyValue(self.settings.inspireModeParams)
    local mode = copy.inspireFlightMode
    if copy.inspireModeParams and copy.inspireModeParams[mode] then
        for _, k in ipairs(INSPIRE_MODE_KEYS) do copy.inspireModeParams[mode][k] = copy[k] end
    end
    return JSON.stringify(copy)
end

function M:loadPreset(presetName)
    local preset = io.load(self.presetsPath .. presetName .. ".json")
    if preset then
        io.save(self.path, preset)
        self:load()
    end
end

function M:savePreset(presetName)
    io.save(self.presetsPath .. presetName .. ".json", self:serialize(), true)
end

function M:deletePreset(presetName)
    io.deleteFile(self.presetsPath..presetName..".json")
end

function M:updatePresets()
    table.clear(self.presets)
    io.scanDir(self.presetsPath, "*.json", function (fileName)
        table.insert(self.presets, fileName:match("%w*"))
    end)
end

function M:saveSettings()
    if self.settings.inputDeviceGUID then -- check if settings were loaded
        io.save(self.path, self:serialize(), true)
    end
end

setmetatable(M, {
    __index = M.settings,
    __newindex = M.settings
})

return M
