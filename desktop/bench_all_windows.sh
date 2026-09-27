#!/usr/bin/env bash
# Every benchmark behind README "Windows build" and docs/reports/windows-build.md, run
# natively on this PC's Windows side (from WSL) with the build in build/windows/:
#
#   bash desktop/bench_all_windows.sh [native] [web]      (both by default; about 35 minutes)
#
# native: the Windows build, 1920x1080 window on a secondary monitor, the scripted two-minute
#   run with the frame-time report (desktop/bench_windows.sh), in this order:
#   gl_cold          OpenGL 3.3, vsync, first launch: the shader cache is emptied first
#   gl_vsync         OpenGL 3.3, vsync (the build's default settings)
#   gl_uncapped      OpenGL 3.3, --disable-vsync
#   angle_cold       ANGLE on Direct3D 11, vsync, its first launch (its shaders are not cached yet)
#   angle_vsync      ANGLE on Direct3D 11, vsync
#   angle_uncapped   ANGLE on Direct3D 11, --disable-vsync
#   angle_uncapped_ssao_off, angle_uncapped_msaa_off, gl_uncapped_ssao_off
#                    A/B runs that show where ANGLE's frame time goes
#   gl_fullscreen    OpenGL 3.3, vsync, fullscreen on the 1920x1080 monitor (FS_SCREEN, DISPLAY3)
# web: the web build (build/web) in Chrome, 1920x1080 page on the same monitor as the native
#   runs (tests/chrome_bench.sh via tests/bench_server.py): web_vsync, web_uncapped
# Results: tests/results/windows/<label>.json|.csv|.log|_load.csv and bench_summary.md.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RES="$ROOT/tests/results/windows"
mkdir -p "$RES"
WHAT="${*:-native web}"
B="bash desktop/bench_windows.sh"
if [[ " $WHAT " == *" native "* ]]; then
	# the game's own shader cache (Godot keeps compiled GL programs in its user folder)
	APPDATA_DIR="$(wslpath "$(powershell.exe -NoProfile -Command '$env:APPDATA' | tr -d '\r')")"
	[ -d "$APPDATA_DIR/ProSkater" ] && rm -rf "$APPDATA_DIR/ProSkater/shader_cache"
	$B gl_cold opengl3 vsync
	$B gl_vsync opengl3 vsync
	$B gl_uncapped opengl3 uncapped
	$B angle_cold opengl3_angle vsync
	$B angle_vsync opengl3_angle vsync
	$B angle_uncapped opengl3_angle uncapped
	$B angle_uncapped_ssao_off opengl3_angle uncapped --nossao
	$B angle_uncapped_msaa_off opengl3_angle uncapped --nomsaa
	$B gl_uncapped_ssao_off opengl3 uncapped --nossao
	# fullscreen on the 1080p monitor: a small window is opened there, then made fullscreen
	WIN_SCREEN="${FS_SCREEN:-DISPLAY3}" WIN_SIZE=1280x720 $B gl_fullscreen opengl3 vsync --window=fullscreen
fi
if [[ " $WHAT " == *" web "* ]]; then
	python3 tests/bench_server.py --port 8790 --out "$RES/web_bench_runs.jsonl" > "$RES/web_bench_server.log" 2>&1 &
	srv=$!
	sleep 2
	cp desktop/win/pick_screen.ps1 /mnt/c/Temp/ProSkater/pick_screen.ps1
	for mode in vsync uncapped; do
		n0=$(cat "$RES/web_bench_runs.jsonl" 2>/dev/null | wc -l)
		# Chrome's window (1936x1119 for a 1920x1080 page) on the native runs' monitor
		PICK="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\ProSkater\pick_screen.ps1' -name "${WIN_SCREEN:-DISPLAY2}" -w 1936 -h 1119 -top 0 | tr -d '\r')"
		case "$PICK" in *primary=False*) ;; *) echo "refusing the web run: $PICK"; break ;; esac
		read -r CX CY _ <<< "$PICK"
		CHROME_POS="$CX,$CY" BENCH_OUT="$RES/web_bench_runs.jsonl" \
			bash tests/chrome_bench.sh "autopilot&bench" "$([ $mode = uncapped ] && echo uncapped)" > "$RES/web_$mode.log" 2>&1
		sed -n "$((n0 + 1))p" "$RES/web_bench_runs.jsonl" > "$RES/web_$mode.json"
	done
	kill $srv
fi
python3 desktop/bench_summary.py "$RES" | tee "$RES/bench_summary.md"
