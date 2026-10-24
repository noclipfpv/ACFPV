local M = {}

local function slider(label, valueOrSettingsKey, min, max, multiplier, decimals, units, description, fn)
    multiplier, decimals = multiplier or 1, decimals or 2
    local isSettingsKey = type(valueOrSettingsKey) == "string"
    local value = isSettingsKey and (Settings[valueOrSettingsKey] or min) or valueOrSettingsKey
    local newValue, changed = ui.slider("##" .. label, value * multiplier, min, max, label .. ": %." .. decimals .. "f " .. (units or ""))
    if ui.itemHovered() and not ui.itemActive() and description then ui.setTooltip(description) end
    if changed then
        if fn then newValue = fn(newValue) end
        newValue = math.round(newValue, decimals) / multiplier
        if isSettingsKey then
            Settings[valueOrSettingsKey] = newValue
        end
    end
    return newValue, changed
end

local listeningAxis = -1
local axisStartValues = {}
local function controllerAxis(label, key)
    ui.alignTextToFramePadding()
    ui.text(label)
    ui.sameLine(0, 2)
    if ui.button((Settings[key] ~= -1 and Settings[key] + 1 or " ") .. "##" .. key, vec2(22, 22), listeningAxis == key and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
        listeningAxis = listeningAxis == key and -1 or key
        if listeningAxis == key then
            table.clear(axisStartValues)
            for i = 0, ac.getJoystickAxisCount(Input.inputDevice) do
                table.insert(axisStartValues, ac.getJoystickAxisValue(Input.inputDevice, i))
            end
        end
    end
    if ui.itemHovered() then ui.setTooltip("Click and move stick to set") end
    if Settings[key] == -1 then ui.addIcon(ui.Icons.QuestionSign, vec2(10, 10), vec2(0.5, 0.5), nil, vec2(0, 0)) end
    if listeningAxis == key then
        for i = 0, ac.getJoystickAxisCount(Input.inputDevice) do
            if math.abs(axisStartValues[i + 1] - ac.getJoystickAxisValue(Input.inputDevice, i)) > 0.3 then
                Settings[key] = i
                listeningAxis = -1
                break
            end
        end
    end
    ui.sameLine(0, 4)
    if ui.button("##" .. key, vec2(22, 22)) then Settings[key] = -1 end
    ui.addIcon(ui.Icons.Cancel, vec2(10, 10), vec2(0.5, 0.5), nil, vec2(0, 0))
end

local listeningKey = -1
local keyAxisStartValues = {}

-- Axes already used by the flight sticks can not be picked as keybinds
local function isFlightAxis(i)
    return i == Settings.throttleAxis or i == Settings.rollAxis or i == Settings.pitchAxis or i == Settings.yawAxis
end

local function keybind(label, key)
    ui.alignTextToFramePadding()
    ui.text(label)
    ui.sameLine(160)
    if not Settings[key] then
        Settings[key] = { type = "none", key = -1 }
    end
    local buttonSettings = Settings[key]
    local buttonLabel = ""
    if buttonSettings.type == "keyboard" then
        buttonLabel = table.indexOf(ui.KeyIndex, buttonSettings.key) or tostring(buttonSettings.key)
    elseif buttonSettings.type == "controller" then
        buttonLabel = "Controller: " .. buttonSettings.key
    elseif buttonSettings.type == "axis" then
        buttonLabel = string.format("Axis %d @ %+.1f", buttonSettings.key + 1, buttonSettings.value or 1)
    end
    if ui.button(buttonLabel .. "##" .. key, vec2(110, 22), listeningKey == key and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
        listeningKey = listeningKey == key and -1 or key
        if listeningKey == key then
            -- snapshot of all axes: a switch that moves later is detected as the new binding
            table.clear(keyAxisStartValues)
            for i = 0, ac.getJoystickAxisCount(Input.inputDevice) - 1 do
                keyAxisStartValues[i] = ac.getJoystickAxisValue(Input.inputDevice, i)
            end
        end
    end
    if ui.itemHovered() then
        ui.setTooltip("Click, then press a key / controller button, or flip a radio switch (axis) to the position that should act as the button")
    end
    if buttonSettings.type == "none" then ui.addIcon(ui.Icons.QuestionSign, vec2(10, 10), vec2(0.5, 0.5), nil, vec2(0, 0)) end
    if listeningKey == key then
        for _, i in pairs(ui.KeyIndex) do
            if ui.keyboardButtonDown(i) then
                Settings[key] = { type = "keyboard", key = i }
                listeningKey = -1
                break
            end
        end
        for i = 0, ac.getJoystickButtonsCount(Input.inputDevice), 1 do
            if ac.isJoystickButtonPressed(Input.inputDevice, i) then
                Settings[key] = { type = "controller", key = i }
                listeningKey = -1
                break
            end
        end
    end
    if listeningKey == key then
        -- Switches / knobs reported as axes (e.g. Taranis): the position they were moved to becomes the "pressed" state
        for i = 0, ac.getJoystickAxisCount(Input.inputDevice) - 1 do
            local start = keyAxisStartValues[i]
            local now = ac.getJoystickAxisValue(Input.inputDevice, i)
            if start and not isFlightAxis(i) and math.abs(now - start) > 0.5 then
                Settings[key] = { type = "axis", key = i, value = math.round(now, 1), tolerance = 0.25 }
                listeningKey = -1
                break
            end
        end
    end
    ui.sameLine(0, 4)
    if ui.button("##" .. key, vec2(22, 22)) then Settings[key] = { type = "none", key = -1 } end
    ui.addIcon(ui.Icons.Cancel, vec2(10, 10), vec2(0.5, 0.5), nil, vec2(0, 0))
end

local saveFlightName = ""

local function fpvDroneTab()
    ui.columns(3, false)
    ui.pushItemWidth(ui.windowWidth() / 3 - 15)
    slider("Batery cells", "batteryCells", 3, 6, 1, 0, "")
    slider("Prop diameter", "propDiameter", 3, 6, 1, 1, "in")
    slider("Prop pitch", "propPitch", 2, 6, 1, 1, "in")
    if ui.checkbox("Linear acceleration", Settings.linearAcceleration) then
        Settings.linearAcceleration = not Settings.linearAcceleration
    end
    if ui.itemHovered() then ui.setTooltip("Make thrust linear to throttle. Motor KV is multiplier") end
    ui.nextColumn()
    ui.pushItemWidth(ui.windowWidth() / 3 - 15)
    slider("Motor KV", "motorKv", 1000, 3000, 1, 0, "")
    slider("Camera angle", "cameraAngle", 0, 90, 1, 0, "", "FPV drone camera. During Dual OP playback (gimbal camera) the angle is automatically 0")
    slider("Camera fov", "cameraFov", 10, 150, 1, 0, "", "FPV drone camera. During Dual OP playback the FOV comes from the focal length")
    if ui.checkbox("Collision", Settings.collision) then
        Settings.collision = not Settings.collision
    end
    if ui.itemHovered() then ui.setTooltip("If you need to temporarily disable collision use \"Disable collision\" keybind") end
    ui.nextColumn()
    ui.pushItemWidth(ui.windowWidth() / 3 - 15)
    slider("Mass", "droneMass", 10, 2000, 1000, 0, "gram")
    slider("Surface Area", "droneSurfaceArea", 0, 500, 1e4, 0, "cm^2")
    slider("MinSurfAreaCoeff", "minimalSurfaceAreaCoefficient", 0, 1, 1, 1, "",
        "Coefficient by which surface area of the drone is multiplied when its going parallel to the airflow")
    ui.columns(1)
end

local function recordTab()
    ui.pushItemWidth(200)
    if not Settings.dualOpEnabled then
        ui.textWrapped("Enable Dual OP (Dual OP tab) and fly a first flight: it is recorded, then replayed from here.")
        return
    end

    local frames = Drone.recordedFlight
    if #frames == 0 then
        ui.textWrapped("No recorded flight yet. Arm the drone and fly: the flight is recorded automatically.")
        return
    end

    -- Flight status
    if Drone.recordedClock == "replay" then
        ui.text(string.format("Recorded flight: replay %.1f s to %.1f s (synced to the replay)", frames[1].time, frames[#frames].time))
    else
        ui.text(string.format("Recorded flight: %.1f s", frames[#frames].time))
    end
    if Settings.dualOpPlayback or Settings.fpvReplay then
        ui.text(string.format("Position in flight: %.2f s", Drone.playbackElapsedTime))
    end

    -- Replays
    ui.separator()
    ui.text("Replay")
    if ui.button("Replay FPV", vec2(0, 0), Settings.fpvReplay and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
        Drone:startFpvReplay()
    end
    if ui.itemHovered() then ui.setTooltip("Replays the flight from the FPV camera (no gimbal), to capture the footage. Uses the Camera angle of the FPV Drone tab (or the Inspire camera tilt) and the Focal length below") end
    ui.sameLine(0, 6)
    if ui.button("Replay gimbal", vec2(0, 0), Settings.dualOpPlayback and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
        Drone:startPlayback()
    end
    if ui.itemHovered() then ui.setTooltip("Replays the flight with the gimbal camera: the sticks control the gimbal (or the recorded gimbal track plays)") end
    if Settings.dualOpPlayback or Settings.fpvReplay then
        ui.sameLine(0, 6)
        if ui.button("Stop") then Drone:stopReplay() end
    end

    ui.pushItemWidth(200)
    slider("Focal length", "focalLength", 6, 200, 1, 0, "mm", "Gimbal camera focal length (full-frame 16:9 sensor), used by Replay FPV and Replay gimbal (the Camera fov of the FPV tab is not changed). Shared with the Dual OP tab")

    -- Gimbal recording
    ui.separator()
    ui.text("Gimbal track")
    if Settings.dualOpPlayback then
        local recLabel = Settings.gimbalRecording and "Stop gimbal rec" or "Record gimbal"
        if ui.button(recLabel) then Drone:toggleGimbalRecording() end
        if ui.itemHovered() then ui.setTooltip("Records your gimbal moves over the flight time. Once recorded they replay automatically, at any replay speed or slow motion. Starting a new recording replaces the track from the current time on") end
        ui.sameLine(0, 10)
    end
    if #Drone.gimbalTrack > 0 then
        if ui.button("Clear gimbal track") then Drone:clearGimbalTrack() end
        if ui.itemHovered() then ui.setTooltip("Deletes the recorded gimbal moves (the flight is kept) so the gimbal is controlled live again") end
        ui.sameLine(0, 10)
    end
    ui.newLine(0)
    if Settings.gimbalRecording then
        ui.textColored("REC gimbal: move the sticks, rewind the replay to redo a part", rgbm(1, 0.3, 0.3, 1))
    elseif #Drone.gimbalTrack > 0 then
        ui.text(string.format("Gimbal track: %.1f s recorded (plays automatically, sticks are ignored)", Drone.gimbalTrack[#Drone.gimbalTrack].time - Drone.gimbalTrack[1].time))
    else
        ui.text("No gimbal track: start \"Replay gimbal\", then \"Record gimbal\" to record one")
    end

    -- Gyroflow
    ui.separator()
    if ui.checkbox("Gyroflow stabilization", Settings.gyroflowEnabled) then
        Settings.gyroflowEnabled = not Settings.gyroflowEnabled
    end
    if ui.itemHovered() then
        ui.setTooltip("Smooths the camera rotation of the replays like the Gyroflow software does: the whole recording is used, so the result follows the flight without any lag")
    end
    slider("Smoothness", "gyroflowSmoothness", 0.05, 3, 1, 2, "", "Smoothing time. Low = only the shaking is removed, high = a very floaty camera that cuts the corners of fast moves")
    ui.textWrapped("Applies to \"Replay FPV\" and \"Replay gimbal\" (the drone attitude the gimbal follows and the recorded gimbal track are smoothed). No crop is needed: the game renders the smoothed view directly.")
end

local function inspireTab()
    ui.pushItemWidth(200)
    if ui.checkbox("Inspire mode", Settings.inspireMode) then
        Settings.inspireMode = not Settings.inspireMode
    end
    if ui.itemHovered() then
        ui.setTooltip("DJI Inspire 3 style flight: the sticks command speeds instead of rotation rates, the drone brakes and holds position when the sticks are released")
    end
    ui.sameLine(0, 10)
    if ui.button("Reset##inspire") then
        Settings:resetInspire()
    end
    if ui.itemHovered() then ui.setTooltip("Resets the parameters of the selected flight mode (and the camera tilt / FOV) to their default values") end
    for _, mode in ipairs(Settings.inspireModeOrder) do
        ui.sameLine(0, 6)
        local active = Settings.inspireFlightMode == mode
        if ui.button(Settings.inspireModes[mode].name .. "##inspireMode" .. mode, vec2(64, 0), active and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
            Settings:setInspireMode(mode)
        end
        if ui.itemHovered() then
            ui.setTooltip("Flight mode " .. Settings.inspireModes[mode].name .. ": each mode keeps its own speed, response and tilt settings (the sliders below edit the selected mode)")
        end
    end
    ui.textWrapped("Pitch = forward speed, Roll = sideways speed, Throttle = climb/descent speed (use a self-centering throttle stick), Yaw = turn rate. The camera stays attached to the body, which tilts into accelerations.")
    ui.separator()
    ui.columns(2, false)
    ui.pushItemWidth(ui.windowWidth() / 2 - 15)
    slider("Max speed", "inspireMaxSpeed", 2, 40, 1, 0, "m/s", "Horizontal speed at full stick (Inspire 3: 26 m/s in Sport)")
    slider("Climb / descent speed", "inspireClimbSpeed", 1, 15, 1, 0, "m/s", "Vertical speed at full throttle stick (Inspire 3: 8 m/s)")
    slider("Yaw rate", "inspireYawRate", 10, 360, 1, 0, "deg/s", "Turn rate at full yaw stick")
    slider("Stick expo", "inspireExpo", 0, 1, 1, 2, "", "Softens the sticks around the center for precise slow moves")
    ui.nextColumn()
    ui.pushItemWidth(ui.windowWidth() / 2 - 15)
    slider("Response", "inspireResponse", 0.1, 3, 1, 2, "s", "Time constant toward the commanded speed. Lower = sharper, higher = more cinematic and floaty")
    slider("Max acceleration", "inspireMaxAccel", 1, 20, 1, 1, "m/s^2", "Limits the acceleration and braking")
    slider("Max tilt", "inspireMaxTilt", 0, 45, 1, 0, "deg", "Maximum tilt of the body (and of the FPV camera) into acceleration")
    slider("Camera tilt", "inspireCameraTilt", -110, 60, 1, 0, "deg", "Tilt of the Inspire FPV camera relative to the horizon (0 = level, negative = down). Replaces the FPV mode Camera angle, which keeps its own value")
    slider("Camera FOV", "inspireCameraFov", 40, 150, 1, 0, "deg", "Vertical FOV of the Inspire FPV camera (separate from the FPV mode Camera fov). Standard perspective projection: no fisheye distortion")
    ui.columns(1)
end

local function dualOpTab()
    ui.pushItemWidth(200)
    if ui.checkbox("Enable Dual OP", Settings.dualOpEnabled) then
        Settings.dualOpEnabled = not Settings.dualOpEnabled
        if not Settings.dualOpEnabled then
            Settings.dualOpPlayback = false
            Settings.fpvReplay = false
        end
    end
    if ui.itemHovered() then ui.setTooltip("Records the first flight") end

    if Settings.dualOpEnabled then
        ui.sameLine(0, 20)
        if ui.button("Delete flight") then
            Drone:clearFlight()
        end
        if ui.itemHovered() then ui.setTooltip("Deletes the recorded flight and restarts recording (same as holding the Replay flight key for 1 s)") end
        if #Drone.recordedFlight > 0 then
            ui.sameLine(0, 10)
            local replaying = Settings.dualOpPlayback or Settings.fpvReplay
            if ui.button(replaying and "Stop replay" or "Replay flight") then
                if replaying then Drone:stopReplay() else Drone:startPlayback() end
            end
            if ui.itemHovered() then ui.setTooltip("Replays the recorded flight with the gimbal camera (same as the Replay flight key)") end
        end

        ui.text("Ronin mode")
        for _, mode in ipairs(Drone.gimbalModeOrder) do
            ui.sameLine(0, 6)
            local active = Settings.gimbalMode == mode
            if ui.button(Drone.gimbalModeNames[mode] .. "##gimbalMode" .. mode, vec2(0, 0), active and ui.ButtonFlags.Active or ui.ButtonFlags.None) then
                Settings.gimbalMode = mode
            end
            if ui.itemHovered() then
                local tips = {
                    lock = "Lock: the gimbal stays fixed in the world, whatever the drone does",
                    pan = "Pan follow: the gimbal follows the drone heading; tilt and roll stay locked",
                    pantilt = "Pan/Tilt follow: the gimbal follows the drone heading and pitch; roll stays locked",
                    fpv = "FPV: the gimbal follows the drone heading, pitch and roll",
                }
                ui.setTooltip(tips[mode] .. ". Your stick moves are added on top of it")
            end
        end
        ui.sameLine(0, 10)
        if ui.button("Recenter") then Drone:recenterGimbal() end
        if ui.itemHovered() then ui.setTooltip("During a playback: brings the camera back in front of the drone (in the selected Ronin mode)") end

        if ui.checkbox("Ronin roll drift simulation", Settings.roninDrift) then
            Settings.roninDrift = not Settings.roninDrift
        end
        if ui.itemHovered() then
            ui.setTooltip("Simulates the horizon drift of a Ronin RS3 Pro under lateral G. Compensate it by hand with the gimbal roll stick")
        end

        ui.separator()
        ui.pushItemWidth(200)
        slider("Focal length", "focalLength", 6, 200, 1, 0, "mm", "Gimbal camera focal length (full-frame 16:9 sensor). Replaces the FOV during Dual OP playback")

        if ui.checkbox("Slow motion", Settings.slowMotionEnabled) then
            Settings.slowMotionEnabled = not Settings.slowMotionEnabled
        end
        if ui.itemHovered() then ui.setTooltip("Slows down the playback of the recorded flight. The gimbal stays controlled in real time") end
        slider("Slow", "slowMotionFactor", 2, 12, 1, 0, "x slow", "Slow motion factor: 2x = twice as slow, 12x = twelve times as slow")

        local frames = Drone.recordedFlight
        if #frames > 0 then
            if Drone.recordedClock == "replay" then
                ui.text(string.format("Recorded flight: replay %.1f s to %.1f s (synced to the replay)", frames[1].time, frames[#frames].time))
                ui.textWrapped("Synced flights follow the replay (pause, rewind, speed). Use the replay speed controls for slow motion: the Slow motion option below is ignored.")
            else
                ui.text(string.format("Recorded flight: %.1f s", frames[#frames].time))
            end
            if Settings.dualOpPlayback or Settings.fpvReplay then
                ui.text(string.format("Position in flight: %.2f s", Drone.playbackElapsedTime))
            end
        else
            ui.text("No recorded flight")
        end

        ui.setNextItemWidth(148)
        ui.combo("##flights", "Load flight", function ()
            for _, flightName in ipairs(Drone.flights) do
                if ui.selectable(flightName) then
                    Drone:loadFlight(flightName)
                end
            end
        end)
        ui.sameLine(0, 4)
        ui.setNextItemWidth(148)
        saveFlightName = ui.inputText("Flight name", saveFlightName, ui.InputTextFlags.Placeholder)
        ui.sameLine(0, 4)
        if ui.button("Save flight") then
            Drone:saveFlight(saveFlightName)
        end
        ui.sameLine(0, 4)
        if ui.button("##openFlightsFolder", vec2(22, 22)) then os.openInExplorer(Drone.flightsPath) end
        if ui.itemHovered() then ui.setTooltip("Open flights folder") end
        ui.addIcon(ui.Icons.Folder, vec2(13, 13), vec2(0.5, 0.5), nil, vec2(0, 0))
        if Drone.flightMessage then
            ui.textWrapped(Drone.flightMessage)
        end
    end
end

local function ratesTab()
    ui.setNextItemWidth(100)
    ui.combo("Rates Type", Settings.rates.type, function()
        for _, rateType in ipairs({ "betaflight", "actual", "kiss" }) do
            if ui.selectable(rateType) then
                Settings.rates = Settings.defaultDroneRates(rateType)
            end
        end
    end)
    ui.sameLine(0, 10)
    if ui.button("Reset##droneRates") then
        Settings.rates = Settings.defaultDroneRates(Settings.rates.type)
    end
    if ui.itemHovered() then ui.setTooltip("Resets the drone rates of the current type to their default values") end
    local rates = Settings.rates
    local rateFunction = Drone.rateFunctions[rates.type]
    ui.columns(3, false)
    ui.text(string.format("Roll: %.2f  Deg/s: %d", Input.roll, rateFunction(Input.roll, rates.roll)))
    ui.nextColumn()
    ui.text(string.format("Pitch: %.2f  Deg/s: %d", Input.pitch, rateFunction(Input.pitch, rates.pitch)))
    ui.nextColumn()
    ui.text(string.format("Yaw: %.2f  Deg/s: %d", Input.yaw, rateFunction(Input.yaw, rates.yaw)))
    ui.nextColumn()
    ui.pushItemWidth(ui.windowWidth() / 3 - 15)
    if rates.type == "betaflight" then
        rates.roll.rate = slider("Roll rate", rates.roll.rate, 0, 3, 1, 2)
        rates.roll.super = slider("Roll super", rates.roll.super, 0, 0.99, 1, 2)
        rates.roll.expo = slider("Roll expo", rates.roll.expo, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.pitch.rate = slider("Pitch rate", rates.pitch.rate, 0, 3, 1, 2)
        rates.pitch.super = slider("Pitch super", rates.pitch.super, 0, 0.99, 1, 2)
        rates.pitch.expo = slider("Pitch expo", rates.pitch.expo, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.yaw.rate = slider("Yaw rate", rates.yaw.rate, 0, 3, 1, 2)
        rates.yaw.super = slider("Yaw super", rates.yaw.super, 0, 0.99, 1, 2)
        rates.yaw.expo = slider("Yaw expo", rates.yaw.expo, 0, 1, 1, 2)
    elseif rates.type == "actual" then
        rates.roll.centerSensitivity = slider("Roll center sensitivity", rates.roll.centerSensitivity, 10, 2000, 1, 0)
        rates.roll.maxRate = slider("Roll max rate", rates.roll.maxRate, 0, 2000, 1, 0)
        rates.roll.expo = slider("Roll expo", rates.roll.expo, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.pitch.centerSensitivity = slider("Pitch center sensitivity", rates.pitch.centerSensitivity, 10, 2000, 1, 0)
        rates.pitch.maxRate = slider("Pitch max rate", rates.pitch.maxRate, 0, 2000, 1, 0)
        rates.pitch.expo = slider("Pitch expo", rates.pitch.expo, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.yaw.centerSensitivity = slider("Yaw center sensitivity", rates.yaw.centerSensitivity, 10, 2000, 1, 0)
        rates.yaw.maxRate = slider("Yaw max rate", rates.yaw.maxRate, 0, 2000, 1, 0)
        rates.yaw.expo = slider("Yaw expo", rates.yaw.expo, 0, 1, 1, 2)
    elseif rates.type == "kiss" then
        rates.roll.rate = slider("Roll rate", rates.roll.rate, 0, 3, 1, 2)
        rates.roll.super = slider("Roll super", rates.roll.super, 0, 0.99, 1, 2)
        rates.roll.curve = slider("Roll curve", rates.roll.curve, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.pitch.rate = slider("Pitch rate", rates.pitch.rate, 0, 3, 1, 2)
        rates.pitch.super = slider("Pitch super", rates.pitch.super, 0, 0.99, 1, 2)
        rates.pitch.curve = slider("Pitch curve", rates.pitch.curve, 0, 1, 1, 2)
        ui.nextColumn()
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        rates.yaw.rate = slider("Yaw rate", rates.yaw.rate, 0, 3, 1, 2)
        rates.yaw.super = slider("Yaw super", rates.yaw.super, 0, 0.99, 1, 2)
        rates.yaw.curve = slider("Yaw curve", rates.yaw.curve, 0, 1, 1, 2)
    end
    ui.columns(1)

    ui.separator()
    ui.text("Dual OP rates (DJI RS 4 Pro)")
    ui.sameLine(0, 10)
    if ui.button("Reset##gimbalRates") then
        for key, value in pairs(Settings.defaultGimbalRates) do Settings[key] = value end
    end
    if ui.itemHovered() then ui.setTooltip("Resets the Dual OP (gimbal) rates to their default values") end
    ui.sameLine(0, 20)
    ui.pushItemWidth(ui.windowWidth() / 3 - 15)
    slider("Follow speed", "gimbalFollowSpeed", 0, 100, 1, 0, "", "How quickly the gimbal follows the drone in the Ronin follow modes (0 = immediately, 100 = very slowly)")
    local gimbalAxes = {
        { name = "Pan", key = "gimbalPan", value = Input.roll, tip = "Maximum pan rotation speed (roll stick). The RS 4 Pro goes up to 360 deg/s" },
        { name = "Tilt", key = "gimbalTilt", value = Input.pitch, tip = "Maximum tilt rotation speed (pitch stick)" },
        { name = "Roll", key = "gimbalRoll", value = Input.yaw, tip = "Maximum roll rotation speed (yaw stick)" },
    }
    ui.columns(3, false)
    for i, axis in ipairs(gimbalAxes) do
        local stick = Drone.applyDeadzone(axis.value, Settings.gimbalDeadzone or 0)
        local degPerSecond = Drone.gimbalRate(stick, Settings[axis.key .. "MaxSpeed"] or 120, Settings[axis.key .. "Expo"] or 0)
        ui.text(string.format("%s: %.2f  Deg/s: %d", axis.name, stick, degPerSecond))
        ui.pushItemWidth(ui.windowWidth() / 3 - 15)
        slider(axis.name .. " max speed", axis.key .. "MaxSpeed", 1, 360, 1, 0, "deg/s", axis.tip)
        slider(axis.name .. " smoothing", axis.key .. "Smoothing", 0, 100, 1, 0, "", "Stick smoothing (0 = immediate response, 100 = very progressive, like the Smoothing of the Ronin app)")
        slider(axis.name .. " expo", axis.key .. "Expo", 0, 1, 1, 2, "", "Stick curve: 0 = linear, 1 = very soft around the centre")
        if i < 3 then ui.nextColumn() end
    end
    ui.columns(1)
end

local function physicsTab()
    ui.columns(2, false)
    ui.pushItemWidth(ui.windowWidth() / 2 - 25)
    slider("Air density", "airDensity", 0, 3, 1, 1, "")
    slider("Air drag", "airDrag", 0, 3, 1, 1, "")
    slider("Time multiplier", "time", 0.05, 2, 1, 1, "")
    slider("Gravity", "gravity", -1, 3, 1, 1, "")
    slider("Simulation value", "simulationValue", 0, 100, 1, 0, "", "Simulated realism: light turbulence and prop wash / vibrations. 0 = off (clean simulation), 100 = full effect")
    ui.nextColumn()
    ui.pushItemWidth(ui.windowWidth() / 2 - 25)
    slider("Ground height", "groundLevel", -5000, 5000, 1, 0, "m", "Height of simulated ground. Prevents the drone from falling under the map forever")
    slider("Drone friction", "groundFriction", 0, 1, 1, 2, "")
    slider("Bounciness", "bounciness", 0, 1, 1, 2, "")
    ui.columns(1)
end

local function keybindsTab()
    ui.columns(2, false)
    keybind("Arm", "armButton")
    keybind("Disarm", "disarmButton")
    keybind("Arm / Disarm", "armToggleButton")
    keybind("Toggle sleep", "toggleSleepButton")
    keybind("Disable drag and friction", "disableAirDragAndFrictionButton")
    keybind("Disable collision", "disableCollisionButton")
    keybind("Save positon", "savePositionButton")
    keybind("Teleport to position", "teleportToPositionButton")
    ui.nextColumn()
    keybind("Replay flight", "togglePlaybackButton")
    keybind("Record gimbal", "toggleGimbalRecordButton")
    keybind("Gimbal mode (cycle)", "gimbalModeButton")
    keybind("Recenter gimbal", "gimbalRecenterButton")
    keybind("Inspire Tripod", "inspireModeTButton")
    keybind("Inspire Normal", "inspireModeNButton")
    keybind("Inspire Sport", "inspireModeSButton")
    ui.columns(1)
end

local function inputTab()
    ui.columns(2, false)
    ui.setNextItemWidth(160)
    ui.combo("Input device", ac.getJoystickName(Input.inputDevice), function ()
        for i = 0, ac.getJoystickCount()-1 do
            local name = ac.getJoystickName(i)
            if name and ui.selectable(name) then
                Settings.inputDeviceName = ac.getJoystickName(i)
                Settings.inputDeviceGUID = ac.getJoystickInstanceGUID(i)
                Input:updateInputDevice()
            end
        end
    end)
    if ui.itemHovered() then ui.setTooltip("Only controllers plugged in at AC launch can be used") end
    ui.nextColumn()
    if ui.checkbox("3D Mode", Settings.mode3d) then Settings.mode3d = not Settings.mode3d end
    if ui.itemHovered() then ui.setTooltip("Lower half of throttle range will spin the motors backwards. Recommended for game controllers") end
    ui.columns(1)

    ui.separator()
    ui.pushItemWidth(200)
    slider("Stick Deadzone", "gimbalDeadzone", 0, 25, 1, 0, "%", "Ignores small unwanted stick movements")
    ui.separator()

    ui.columns(4, false)
    ui.pushItemWidth(ui.windowWidth() / 4 - 15)
    ui.setNextItemWidth(50)
    controllerAxis("Throttle axis:", "throttleAxis")
    if ui.checkbox("Invert throttle", Settings.invertThrottle) then
        Settings.invertThrottle = not Settings.invertThrottle
    end
    slider("Throttle from", "throttleFrom", -1, 1, 1, 1, "", nil, function (value) return math.min(value, Settings.throttleTo - 0.1) end)
    slider("Throttle to", "throttleTo", -1, 1, 1, 1, "", nil, function (value) return math.max(value, Settings.throttleFrom + 0.1) end)
    ui.nextColumn()

    ui.pushItemWidth(ui.windowWidth() / 4 - 15)
    ui.setNextItemWidth(50)
    controllerAxis("Roll axis:", "rollAxis")
    if ui.checkbox("Invert roll", Settings.invertRoll) then Settings.invertRoll = not Settings.invertRoll end
    slider("Roll from", "rollFrom", -1, 1, 1, 1, "", nil, function (value) return math.min(value, Settings.rollTo - 0.1) end)
    slider("Roll to", "rollTo", -1, 1, 1, 1, "", nil, function (value) return math.max(value, Settings.rollFrom + 0.1) end)
    ui.nextColumn()

    ui.pushItemWidth(ui.windowWidth() / 4 - 15)
    ui.setNextItemWidth(50)
    controllerAxis("Pitch axis:", "pitchAxis")
    if ui.checkbox("Invert pitch", Settings.invertPitch) then
        Settings.invertPitch = not Settings.invertPitch
    end
    slider("Pitch from", "pitchFrom", -1, 1, 1, 1, "", nil, function (value) return math.min(value, Settings.pitchTo - 0.1) end)
    slider("Pitch to", "pitchTo", -1, 1, 1, 1, "", nil, function (value) return math.max(value, Settings.pitchFrom + 0.1) end)
    ui.nextColumn()

    ui.pushItemWidth(ui.windowWidth() / 4 - 15)
    ui.setNextItemWidth(50)
    controllerAxis("Yaw axis:", "yawAxis")
    if ui.checkbox("Invert yaw", Settings.invertYaw) then Settings.invertYaw = not Settings.invertYaw end
    slider("Yaw from", "yawFrom", -1, 1, 1, 1, "", nil, function (value) return math.min(value, Settings.yawTo - 0.1) end)
    slider("Yaw to", "yawTo", -1, 1, 1, 1, "", nil, function (value) return math.max(value, Settings.yawFrom + 0.1) end)
    ui.columns(1)
end

local savePresetName = ""
local helpText = require("src/help")
function M.fpvDroneWindow()
    ui.columns(2, false)
    ui.setColumnWidth(0, ui.windowWidth() - 207)
    ui.setColumnWidth(1, 207)
    if ui.button(Drone.active and "Disarm" or "Arm", vec2(60, 0)) then
        Drone:toggle()
    end
    if Drone.active then
        if ui.button(Drone.sleep and "Sleep off" or "Sleep on", vec2(70, 0)) then Drone:toggleSleep() end
    end
    if Drone.errorMessage then
        ui.textWrapped(Drone.errorMessage)
    end

    local square0pos = vec2(ui.windowWidth() / 2 - 26, 54)
    local square1pos = vec2(ui.windowWidth() / 2 + 27, 54)
    local squareSize, circleRadius = 48, 4
    local squareColor = rgbm(table.unpack(Settings.squareColor))
    local circleColor = rgbm(table.unpack(Settings.circleColor))
    ui.drawRectFilled(square0pos + vec2(-squareSize / 2, -squareSize / 2), square0pos + vec2(squareSize / 2, squareSize / 2), squareColor)
    ui.drawRectFilled(square1pos + vec2(-squareSize / 2, -squareSize / 2), square1pos + vec2(squareSize / 2, squareSize / 2), squareColor)
    ui.drawCircleFilled(square0pos + vec2(Input.yaw, -Input.throttle):scale(squareSize / 2 - circleRadius), circleRadius, circleColor)
    ui.drawCircleFilled(square1pos + vec2(Input.roll, -Input.pitch):scale(squareSize / 2 - circleRadius), circleRadius, circleColor)
    ui.nextColumn()

    ui.setNextItemWidth(148)
    ui.combo("##Presets", "Load preset", function ()
        for _, presetName in ipairs(Settings.presets) do
            local defaultPreset = Settings.notDeletablePresetsMap[presetName]
            if ui.selectable(presetName, nil, ui.SelectableFlags.None, defaultPreset and vec2(128, 20) or vec2(108, 20)) then
                Settings:loadPreset(presetName)
            end
            if not defaultPreset then
                ui.sameLine(0, 4)
                if ui.button("##deletePresetButton"..presetName, vec2(20, 20)) then
                    Settings:deletePreset(presetName)
                end
                ui.addIcon(ui.Icons.Delete, vec2(13, 13), vec2(0.5, 0.5), nil, vec2(0, 0))
            end
        end
    end)
    ui.sameLine(0, 4)
    if ui.button("##openPresetFolder", vec2(22, 22)) then os.openInExplorer(Settings.presetsPath) end
    if ui.itemHovered() then ui.setTooltip("Open presets folder") end
    ui.addIcon(ui.Icons.Folder, vec2(13, 13), vec2(0.5, 0.5), nil, vec2(0, 0))

    ui.setNextItemWidth(148)
    savePresetName = ui.inputText("Save preset", savePresetName, ui.InputTextFlags.Placeholder)
    ui.sameLine(0, 4)
    if ui.button("##savePresetBtn", vec2(22, 22)) then
        Settings:savePreset(savePresetName)
        savePresetName = ""
    end
    if ui.itemHovered() then ui.setTooltip("Save preset as") end
    ui.addIcon(ui.Icons.Save, vec2(13, 13), vec2(0.5, 0.5), nil, vec2(0, 0))
    ui.columns(1)

    ui.tabBar("fpvDroneTabBar", function ()
        ui.tabItem("FPV Drone", fpvDroneTab)
        ui.tabItem("Dual OP", dualOpTab)
        ui.tabItem("Record", recordTab)
        ui.tabItem("Inspire", inspireTab)
        ui.tabItem("Rates", ratesTab)
        ui.tabItem("Physics", physicsTab)
        ui.tabItem("Keybinds", keybindsTab)
        ui.tabItem("Input", inputTab)
        ui.tabItem("Help", function() ui.textWrapped(helpText) end)
    end)
end

function M.inputDisplayWindow()
    local squareColor = rgbm(table.unpack(Settings.squareColor))
    local circleColor = rgbm(table.unpack(Settings.circleColor))
    local square0pos = vec2(ui.windowWidth() / 2 - (Settings.squareSize + Settings.squareGap) / 2, ui.windowHeight() - Settings.squareGap - Settings.squareSize / 2)
    local square1pos = vec2(ui.windowWidth() / 2 + (Settings.squareSize + Settings.squareGap) / 2, ui.windowHeight() - Settings.squareGap - Settings.squareSize / 2)
    ui.drawRectFilled(square0pos + vec2(-Settings.squareSize / 2, -Settings.squareSize / 2), square0pos + vec2(Settings.squareSize / 2, Settings.squareSize / 2), squareColor)
    ui.drawRectFilled(square1pos + vec2(-Settings.squareSize / 2, -Settings.squareSize / 2), square1pos + vec2(Settings.squareSize / 2, Settings.squareSize / 2), squareColor)
    ui.drawCircleFilled(square0pos + vec2(Input.yaw, -Input.throttle):scale(Settings.squareSize / 2 - Settings.circleRadius), Settings.circleRadius, circleColor)
    ui.drawCircleFilled(square1pos + vec2(Input.roll, -Input.pitch):scale(Settings.squareSize / 2 - Settings.circleRadius), Settings.circleRadius, circleColor)
end

function M.inputDisplaySettingsWindow()
    slider("Square size", "squareSize", 1, 500, 1, 0, "px")
    slider("Square gap", "squareGap", 0, 500, 1, 0, "px")
    ui.text("Square color")
    ui.setNextItemWidth(150)
    local squareColorS = rgbm(table.unpack(Settings.squareColor))
    if ui.colorPicker("##squareColor", squareColorS) then
        Settings.squareColor = { squareColorS.r, squareColorS.g, squareColorS.b, squareColorS.mult }
    end
    slider("Circle radius", "circleRadius", 1, 100, 1, 0, "px")
    ui.text("Circle color")
    ui.setNextItemWidth(150)
    local circleColorS = rgbm(table.unpack(Settings.circleColor))
    if ui.colorPicker("##circleColor", circleColorS) then
        Settings.circleColor = { circleColorS.r, circleColorS.g, circleColorS.b, circleColorS.mult }
    end
end

return M
