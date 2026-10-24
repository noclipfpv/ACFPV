# AC FPV PRO

An FPV drone for **Assetto Corsa** (Custom Shaders Patch 0.3.0+), extended with a cinema workflow:
a DJI Inspire 3 style flight mode, a two-operator **Dual OP** setup with a Ronin-style gimbal, flight
recording and replay, and Gyroflow-style stabilization.

## Credits

This mod is built on the **FPV Drone mod for Assetto Corsa by [sug44](https://github.com/sug44)**,
the original modder: the drone physics, the rates, the input handling and the app are his work.
Thank you sug44!

The additions in this version are by **NoclipFPV**, published with sug44's agreement.

## What this version adds

- **Arm / Disarm** buttons and keybinds (arm, disarm, toggle).
- **Axis keybinds**: map the switches of an RC radio (Taranis, etc.) that are reported as axes, as well
  as keys and gamepad buttons.
- **Dual OP**: fly a first flight (recorded, synced to the replay), then replay it and operate a gimbal
  camera with the sticks. Ronin follow modes (Lock, Pan, Pan/Tilt, FPV), DJI RS 4 Pro style rates,
  roll drift simulation, focal length 6-200 mm, slow motion.
- **Gimbal track recording**: record your gimbal moves and replay them at any speed.
- **Record tab**: Replay FPV and Replay gimbal, Gyroflow style stabilization with a smoothness slider.
- **Inspire mode**: velocity flight like a DJI Inspire 3, with Tripod / Normal / Sport modes, horizon
  holding camera and its own camera tilt / FOV.
- **Simulation value** (Physics tab): light turbulence and prop wash, from 0 (clean) to 100.
- Save / load flights by name, presets for all the new settings, a single in-app Help tab.

## Install

Download `FpvDrone.zip` from the [latest release](../../releases/latest) and install it with Content
Manager, or copy the `FpvDrone` folder of this repository to `assettocorsa/apps/lua/`.
Requires **Custom Shaders Patch 0.3.0 or above**. Start the game and open the "Fpv Drone" app.
If you already have the original mod, this version replaces it; your `settings` folder (settings and
presets) is kept if you copy over it.

Please report problems in the issues.

## Documentation

### New to FPV drones
FPV drones are hard to fly just starting out, but it's rewarding once you get the hang of it.
By default 3D mode is enabled, which makes the lower half of the throttle spin the motors backwards.
This is not how FPV drones work, the motors can only spin one way.
3D mode makes it much easier to fly with a game controller.

### Install
Requires Custom Shaders Patch 0.3.0 or above.
Make sure the downloaded folder/zip is named "FpvDrone".
Drag the downloaded FpvDrone folder/zip into content manager, click on the menu icon(3 horizontal lines) at the top right corner, and click install.

### Setup
When in game open the "Fpv Drone" app. If you use dualshock4 or xbox360 controllers select the corresponding preset and check if "Input device" setting in "Input" tab is right.
For other controllers go to the "Input" tab and adjust every setting so the Input Display at the top of the app displays correctly.
If you can't see your controller in the "Input device" menu make sure it was plugged in at AC launch and it's listed in the Windows "Game controllers" menu (Win+R, type "joy.cpl", Enter).

You can put any value in a slider by Ctrl+LeftClicking on it and typing in the value.

### Arm / Disarm
The "Arm" button of the app (it becomes "Disarm" once armed) turns the drone on and off. There are three keybinds: Arm (arms only), Disarm (disarms only) and Arm / Disarm (toggles). The binding that was "Toggle drone" in older versions is kept as the Arm keybind.

### Dual OP (two operators)
Dual OP simulates a drone pilot and a separate gimbal operator, like on a real shoot.
1. Tick "Enable Dual OP" and fly a first flight. The flight is recorded automatically. In a replay it is keyed to the replay time, so it follows pause, rewind and the replay speed. Outside a replay it is recorded live.
2. Open the Record tab and press "Replay gimbal" (in the Dual OP tab: "Replay flight"; or use the Replay flight key). The drone flies the recorded flight by itself and the sticks now control the gimbal: roll stick = pan, pitch stick = tilt, yaw stick = gimbal roll.
3. "Stop" (Record tab) ends the playback. "Delete flight" (Dual OP tab, or holding the Replay flight key for 1 s) erases the flight, the gimbal track and restarts recording.
Flights can be saved and loaded by name with "Save flight" / "Load flight". The gimbal track is saved in the same file.

Slow motion (live flights only) slows the playback down. For flights recorded in a replay, use the replay speed controls instead: the Slow motion option is ignored there.
Focal length replaces the FOV during the playback (full-frame 16:9 sensor).
Ronin roll drift simulation makes the horizon drift under lateral G like a real Ronin; compensate it with the gimbal roll stick.

### Gimbal rates (Rates tab)
Max speed, Smoothing and Expo for pan, tilt and roll, DJI RS 4 Pro style. The Reset button restores the defaults. Smoothing is framerate independent. The tilt can go past straight down (top shot with the gimbal mounted upside down).

### Ronin modes
In the Dual OP tab, choose how the gimbal reacts to the drone (like the follow modes of the RS 4 Pro):
- Lock: the gimbal is fully stabilized in the world and ignores what the drone does (the behaviour of the first versions).
- Pan follow: the gimbal follows the drone heading, tilt and roll stay locked.
- Pan/Tilt follow: it also follows the drone pitch.
- FPV: it follows the heading, the pitch and the roll of the drone.
Your stick moves are always added on top of the followed motion. "Follow speed" (Rates tab) sets how quickly the gimbal follows (0 = immediately, 100 = very slowly). "Recenter" (or the Recenter gimbal keybind) brings the camera back in front of the drone. The "Gimbal mode (cycle)" keybind switches between the four modes; the camera does not jump when the mode changes.
In the follow modes the camera starts aligned with the drone at the beginning of a playback. The follow is exact for small tilts and approximate for extreme attitudes. A recorded gimbal track stores the final camera angles, so it replays the same whatever the Ronin mode is when it is played.

### Recording the gimbal
During a playback press "Record gimbal" in the Record tab (or the Record gimbal key, which can be a radio switch) and move the gimbal. Press again to stop.
- Once a gimbal track exists it replays automatically with the flight, at any replay speed or slow motion, and the sticks are ignored. "Clear gimbal track" deletes it and gives the gimbal back to the sticks.
- Starting a new recording replaces everything from the current time on. To redo a part, rewind the replay to where it should start and record again.
- While paused, the gimbal can still be moved and the last sample is overwritten.

### Record tab
The Record tab holds everything about capturing a flight once it is recorded:
- Replay FPV replays the flight seen from the FPV camera (no gimbal), just to capture it. It uses the Camera angle of the FPV Drone tab (or the Camera tilt of the Inspire tab when Inspire mode is ticked) and the Focal length of this tab; the Camera fov settings are left untouched (the horizon is then held from the recorded pitch).
- Replay gimbal replays it with the gimbal camera, and Stop ends either replay.
- Record gimbal / Clear gimbal track manage the gimbal track (see "Recording the gimbal").
- Gyroflow stabilization smooths the camera rotation of Replay FPV and Replay gimbal like the Gyroflow software: the whole recording is used, so the smoothed view has no lag. Smoothness is the smoothing time (low = only the shaking goes away, high = a floaty camera that cuts the corners). In Replay gimbal the drone attitude that the Ronin follow modes use and the recorded gimbal track are smoothed. No crop is needed because the game renders the smoothed view directly.
- Focal length (Record tab, shared with the Dual OP tab) sets the lens of Replay FPV and Replay gimbal; back in flight mode the Camera fov of the FPV tab applies again; the default is 20 mm.
- Physics tab, Simulation value (0-100): simulated realism. 0 keeps the clean simulation; the higher it is, the more light turbulence (gusts) and prop wash / vibrations (stronger with throttle and in descents) the drone gets, in FPV and in Inspire mode. Stick deadzone starts at 0 on the first launch.
Both replays follow the replay (pause, rewind, speed) when the flight was recorded in a replay.

### Inspire mode (DJI Inspire 3 style flight)
Tick "Inspire mode" in the Inspire tab. The sticks command speeds instead of rotation rates:
- Pitch = forward speed, Roll = sideways speed, Throttle = climb / descent speed, Yaw = turn rate. Use a self-centering throttle stick.
- Releasing the sticks brakes the drone to a standstill and holds the position.
- The body tilts into accelerations (Max tilt), the FPV camera holds the horizon with a small delay. Camera tilt offsets the camera (-110 to +60 deg). Camera FOV is separate from the FPV mode FOV, and the FPV Camera angle is ignored in this mode (its value is kept).
- Three flight modes, like the Inspire 3: Tripod (slow and precise), Normal and Sport (the original settings). Choose them with the three buttons next to Reset, or with the three Inspire keybinds. Each mode keeps its own Max speed, Climb speed, Yaw rate, Response, Max acceleration, Max tilt and Stick expo, and the sliders edit the selected mode. Reset restores the selected mode only. Camera tilt and Camera FOV are shared by the three modes.
- Response: lower = sharper, higher = floatier. Max acceleration limits starts and stops. Stick expo softens the center of the sticks.
Dual OP works with the Inspire mode too (the Ronin drift follows its accelerations).

### Keybinds
Click a keybind, then press a key, a controller button, or flip a radio switch that is reported as an axis (Taranis, etc.) to the position that should act as the button. Axis binds show as "Axis N @ value".
- One-shot actions (Arm, Disarm, Arm / Disarm, Toggle sleep, Save position, Teleport, Replay flight, Record gimbal, Gimbal mode, Recenter gimbal, the Inspire modes) fire when the switch enters its position.
- "Disable collision" and "Disable drag and friction" stay active as long as the switch stays in its position.
- Holding Replay flight to delete the flight only works with a key or a button, not with a switch.

### Presets
Presets store all the settings, including the Dual OP, gimbal and Inspire ones. Presets made before these features load fine: the missing values use their defaults.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2022 sug44 for the original FPV Drone mod, and copyright (c) 2026
NoclipFPV for the additions and modifications. Redistributed with the agreement of sug44.
