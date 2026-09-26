PRO SKATER: THE WAREHOUSE - Windows build
==========================================

Run ProSkater.exe. Nothing to install; 64-bit Windows 10 or 11 (tested on 11), with an OpenGL 3.3 graphics
driver (without one the game switches to Direct3D 11 by itself).

The exe is not code-signed, so the first time you start it Windows SmartScreen may say
"Windows protected your PC". Click "More info", then "Run anyway".

The game starts fullscreen. F11 or Alt+Enter switches between fullscreen and a window
(1920x1080, or smaller on a smaller screen); the choice is kept for next time. If the
picture ever stops moving after leaving fullscreen, restart the game: it opens in the window.

CONTROLS            Keyboard                 Gamepad (Xbox layout)
Steer / push / brake  W A S D or arrow keys   Left stick or D-pad
Ollie               Space (hold, release)    A
Flip trick          J + direction            X
Grab trick          K + direction (hold)     B
Grind               L + direction            Y
Spin                Left / Right, Q / E      Left stick, LB / RB
Manual              Up, Down / Down, Up      Up, Down / Down, Up
Special             Left, Right + J          Left, Right + X
Pause / restart     Esc or P / R             Start / Back
Quit (in a menu)    Q, twice                 B, twice
Fullscreen          F11 or Alt+Enter

The game pauses by itself when its window loses focus.

COMMAND LINE (after --)
  ProSkater.exe -- --autopilot           the scripted two-minute run that clears every goal
  ProSkater.exe -- --autopilot --bench --bench-out=bench.json --quit-at-end
                                         the same run as a frame-time benchmark, saved as JSON
  ProSkater.exe -- --fps                 frame-rate counter
  ProSkater.exe --resolution 1600x900 -- --window=windowed
                                         start in a window of that size
  ProSkater.exe --rendering-driver opengl3_angle      use Direct3D 11 (through ANGLE)

Settings and saves live in %APPDATA%\ProSkater.
