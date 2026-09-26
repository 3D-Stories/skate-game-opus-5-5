#!/usr/bin/env bash
# Native keyboard, sound, pause / quit and fullscreen checks of the Windows build on this PC
# (from WSL), with the build in build/windows/:
#
#   bash desktop/input_test_windows.sh      -> tests/results/windows/input_native.txt (+ logs, JSON)
#
# 1. kb:  the game in a 1920x1080 window on a secondary monitor, never focused. Keys go in as
#    WM_KEYDOWN / WM_KEYUP window messages (desktop/win/drive.ps1), the path a key press takes
#    into the game: Enter starts the run, W pushes, Space ollies, Space + J kickflips, Esc
#    pauses, Enter resumes, Esc then Q twice quits. Meanwhile the game's audio session on
#    the default output device is read through Windows Core Audio (its peak meter).
# 2. fs:  a 1280x720 window on the 1920x1080 monitor (DISPLAY3): F11 makes it fullscreen at
#    1920x1080, F11 again gives the fitted window for that screen, then Q twice quits from the
#    start screen. The saved window choice is removed afterwards (a player starts fullscreen).
# 3. The joypads the game sees (Godot's SDL joypad input), from the settings report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RES="$ROOT/tests/results/windows"
W=/mnt/c/Temp/ProSkater
mkdir -p "$RES" "$W/out"
cp desktop/win/drive.ps1 "$W/drive.ps1"
drive() {  # label steps
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\ProSkater\drive.ps1' \
		-exe 'C:\Temp\ProSkater\ProSkater.exe' -steps "$2" -out "C:\\Temp\\ProSkater\\out\\$1_drive.json" > /dev/null 2>&1
}
KB="wait:7000;tap:Return;wait:1500;hold:W:2500;wait:400;hold:Space:350;wait:1500;hold:W:1500;hold:Space:300;tap:J;wait:1500"
KB="$KB;shot:C:\\Temp\\ProSkater\\out\\kb_window.png;tap:Escape;wait:1500;shot:C:\\Temp\\ProSkater\\out\\kb_pause.png;tap:Return;wait:1500"
KB="$KB;tap:Escape;wait:1000;tap:Q;wait:700;tap:Q"
bash desktop/run_windows.sh kb -- --input-log "--info-out={out}/kb_info.json" &
game=$!
drive kb "$KB"
wait $game
kb_code=$?
FS="wait:7000;tap:F11;wait:3000;shot:C:\\Temp\\ProSkater\\out\\fs_fullscreen.png;tap:F11;wait:3000;shot:C:\\Temp\\ProSkater\\out\\fs_windowed.png;tap:Q;wait:600;tap:Q"
WIN_SCREEN="${FS_SCREEN:-DISPLAY3}" WIN_SIZE=1280x720 bash desktop/run_windows.sh fs -- --input-log "--info-out={out}/fs_info.json" &
game=$!
drive fs "$FS"
wait $game
fs_code=$?
cp "$W/out/kb_drive.json" "$W/out/fs_drive.json" "$W/out/kb_window.png" "$W/out/kb_pause.png" "$W/out/fs_fullscreen.png" "$W/out/fs_windowed.png" "$RES/" 2>/dev/null
APPDATA_DIR="$(wslpath "$(powershell.exe -NoProfile -Command '$env:APPDATA' | tr -d '\r')")"
rm -f "$APPDATA_DIR/ProSkater/desktop.cfg"
python3 - "$RES" "$kb_code" "$fs_code" <<'EOF' | tee "$RES/input_native.txt"
import json, re, sys
res, kb_code, fs_code = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = []
def check(ok, what, detail=""):
    out.append(("PASS  " if ok else "FAIL  ") + what + ("  (%s)" % detail if detail else ""))
def load(p):
    try:
        return json.loads(open(p, encoding="utf-8-sig").read())
    except Exception:
        return {}
kb = open(res + "/kb.log", errors="replace").read()
fs = open(res + "/fs.log", errors="replace").read()
d = load(res + "/kb_drive.json")
info = load(res + "/kb_info.json")
print("native Windows run of build/windows/ProSkater.exe: %s | %s | %s" % (info.get("rendering_driver"), info.get("adapter"), info.get("os")))
check("[run] started" in kb and "key Enter down  actions: confirm" in kb, "keyboard: Enter on the start screen starts the run")
sp = [float(x) for x in re.findall(r"run \d+ s: speed ([0-9.]+)", kb)]
check(len(sp) > 3 and max(sp) > 3.0 and "actions: up" in kb, "keyboard: holding W pushes the skater", "top speed %.1f m/s" % max(sp or [0]))
check("skater AIR" in kb and "actions: jump" in kb, "keyboard: Space pops an ollie (the skater is in the air)")
tricks = re.findall(r"trick: (.+)", kb)
check(any("flip" in t.lower() for t in tricks), "keyboard: Space then J in the air is a flip trick", ", ".join(tricks))
check("[run] paused" in kb and "[run] resumed" in kb, "keyboard: Esc pauses, Enter resumes")
check("quit from the pause screen" in kb and kb_code == 0, "keyboard: Q twice in the pause menu quits, exit code 0", "exit %d" % kb_code)
au = d.get("audio", [])
active = [a for a in au if a.get("peak", -1) > 0.001]
check(len(active) > 10, "sound: the game's Windows audio session is playing (peak meter above zero)",
      "%d of %d samples, max peak %.3f; audio driver %s, device %s, %d Hz" % (len(active), len(au), max([a.get("peak", 0) for a in au] or [0]),
       info.get("audio", {}).get("driver"), info.get("audio", {}).get("output_device"), info.get("audio", {}).get("mix_rate", 0)))
lv = info.get("audio", {}).get("run_levels", {})
check(lv.get("frames_with_sound", 0) > 0 and len(lv.get("sounds_played", [])) > 0, "sound: the game's master bus carried sound during the run",
      "%d of %d frames, peak %.1f dB, synthesised sounds heard: %s" % (lv.get("frames_with_sound", 0), lv.get("frames", 0), lv.get("max_peak_db", -200), ", ".join(sorted(lv.get("sounds_played", [])))))
shots = [k for k in d.get("keys", []) if "shot" in k]
check(all(s.get("ok") for s in shots) and len(shots) == 2, "window pictures (PrintWindow) taken", ", ".join("%s %s" % (s["shot"].split("\\")[-1], s["size"]) for s in shots))
full = re.findall(r"window fullscreen \((\d+), (\d+)\)", fs)
win = re.findall(r"window windowed \((\d+), (\d+)\)", fs)
check(full == [("1920", "1080")], "F11: fullscreen on the 1920x1080 monitor renders 1920x1080", str(full))
ok = bool(win) and int(win[-1][1]) + 39 <= 1032 and abs(int(win[-1][0]) / int(win[-1][1]) - 16 / 9) < 0.01
check(ok, "F11 again: a 16:9 window that fits that screen with its title bar and taskbar", str(win))
check("quit from the start screen" in fs and fs_code == 0, "Q twice on the start screen quits, exit code 0", "exit %d" % fs_code)
pads = info.get("joypads", [])
print("\n".join(out))
print("joypads seen by the game (Godot's SDL joypad input): %s" % (json.dumps(pads) if pads else "none connected"))
print("%d checks passed, %d failed" % (sum(o.startswith("PASS") for o in out), sum(o.startswith("FAIL") for o in out)))
EOF
