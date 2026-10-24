local M = {
    inputDevice = -1,
    throttle = 0,
    roll = 0,
    pitch = 0,
    yaw = 0,
    buttons = {
        armButton = {},
        disarmButton = {},
        armToggleButton = {},
        toggleSleepButton = {},
        disableAirDragAndFrictionButton = {},
        disableCollisionButton = {},
        savePositionButton = {},
        teleportToPositionButton = {},
        togglePlaybackButton = {},
        toggleGimbalRecordButton = {},
        gimbalModeButton = {},
        gimbalRecenterButton = {},
        inspireModeTButton = {},
        inspireModeNButton = {},
        inspireModeSButton = {},
    }
}
-- Buttons that are one-shot actions: when bound to a latched radio switch (axis), they get a short pulse each time
-- the switch enters its position. The other buttons (hold to disable collision / drag) follow the switch position.
local PULSE_BUTTONS = {
    armButton = true, disarmButton = true, armToggleButton = true, toggleSleepButton = true,
    savePositionButton = true, teleportToPositionButton = true, togglePlaybackButton = true,
    toggleGimbalRecordButton = true, gimbalModeButton = true, gimbalRecenterButton = true,
    inspireModeTButton = true, inspireModeNButton = true, inspireModeSButton = true,
}
local PULSE_DURATION = 0.15

setmetatable(M, { __index = M.buttons })

function M:updateInputDevice()
    self.inputDevice = tonumber(ac.getJoystickIndexByInstanceGUID(Settings.inputDeviceGUID)) or -1
    if self.inputDevice == -1 then
        for i = 0, ac.getJoystickCount()-1 do
            if ac.getJoystickName(i) == Settings.inputDeviceName then
                self.inputDevice = i
                Settings.inputDeviceGUID = ac.getJoystickInstanceGUID(i)
                break
            end
        end
    end
end

function M:update()
    self.throttle = ac.getJoystickAxisValue(self.inputDevice, Settings.throttleAxis)
    self.roll = ac.getJoystickAxisValue(self.inputDevice, Settings.rollAxis)
    self.pitch = ac.getJoystickAxisValue(self.inputDevice, Settings.pitchAxis)
    self.yaw = ac.getJoystickAxisValue(self.inputDevice, Settings.yawAxis)
    self.throttle = (2 * self.throttle - (Settings.throttleFrom + Settings.throttleTo)) / (Settings.throttleTo - Settings.throttleFrom)
    self.roll = (2 * self.roll - (Settings.rollFrom + Settings.rollTo)) / (Settings.rollTo - Settings.rollFrom)
    self.pitch = (2 * self.pitch - (Settings.pitchFrom + Settings.pitchTo)) / (Settings.pitchTo - Settings.pitchFrom)
    self.yaw = (2 * self.yaw - (Settings.yawFrom + Settings.yawTo)) / (Settings.yawTo - Settings.yawFrom)
    if Settings.invertThrottle then self.throttle = self.throttle * -1 end
    if Settings.invertRoll then self.roll = self.roll * -1 end
    if Settings.invertPitch then self.pitch = self.pitch * -1 end
    if Settings.invertYaw then self.yaw = self.yaw * -1 end

    for button, state in pairs(self.buttons) do
        local buttonSettings = Settings[button]

        local buttonDown
        if not (buttonSettings and buttonSettings.type == "axis") then state.inPosition = nil end
        if buttonSettings and buttonSettings.type == "axis" then
            local value = ac.getJoystickAxisValue(self.inputDevice, buttonSettings.key)
            local inPosition = math.abs(value - (buttonSettings.value or 1)) < (buttonSettings.tolerance or 0.25)
            -- no trigger at startup or right after binding: the first sample only records the position
            if state.inPosition == nil then state.inPosition = inPosition end
            if PULSE_BUTTONS[button] then
                local now = os.preciseClock()
                if inPosition and not state.inPosition then state.pulseUntil = now + PULSE_DURATION end
                buttonDown = state.pulseUntil ~= nil and now < state.pulseUntil
            else
                buttonDown = inPosition
            end
            state.inPosition = inPosition
        elseif buttonSettings and buttonSettings.type == "keyboard" then
            buttonDown = ac.isKeyDown(buttonSettings.key)
        elseif buttonSettings and buttonSettings.type == "controller" then
            buttonDown = ac.isJoystickButtonPressed(self.inputDevice, buttonSettings.key)
        end

        state.pressed = buttonDown and not state.down
        state.down = buttonDown
    end
end

return M
