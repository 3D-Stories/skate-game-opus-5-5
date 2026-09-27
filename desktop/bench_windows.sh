#!/usr/bin/env bash
# The 1080p two-minute benchmark of the Windows build, run natively on this PC (from WSL):
#
#   bash desktop/bench_windows.sh <label> [opengl3|opengl3_angle] [vsync|uncapped] [game options...]
#   e.g. bash desktop/bench_windows.sh gl_vsync opengl3 vsync
#        bash desktop/bench_windows.sh angle_uncapped opengl3_angle uncapped
#        bash desktop/bench_windows.sh gl_ssao_off opengl3 uncapped --nossao --benchsecs=60
#
# Plays the scripted run (--autopilot) with the frame-time report (--bench) in a 1920x1080
# window on a secondary monitor (desktop/run_windows.sh), and writes to tests/results/windows/:
#   <label>.json      the bench report: frame times, settings read back by the game, and the
#                     renderer, driver, GPU, window and screen (the report's "desktop" part)
#   <label>.csv       every frame: run seconds, frame ms, GPU ms (the GPU time of the frame)
#   <label>.log       the game's output
#   <label>_load.csv  GPU load, clock and power (nvidia-smi) and the WSL host's load average,
#                     once a second, to show whether anything else was using the GPU meanwhile
#   <label>_displays.txt  the monitors (bounds, refresh rate) before and after the run
# "uncapped" is Godot's --disable-vsync. Game options go to the game (bench.gd's A/B switches).
# No file name here may contain a bench switch word (nossao, noglow, ...): bench.gd reads its
# switches from the whole command line.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:?usage: $0 <label> [opengl3|opengl3_angle] [vsync|uncapped] [game options...]}"
DRIVER="${2:-opengl3}"
SYNC="${3:-vsync}"
shift $(( $# < 3 ? $# : 3 ))
RES="$ROOT/tests/results/windows"
mkdir -p "$RES"
SMI=/usr/lib/wsl/lib/nvidia-smi
engine=(--rendering-driver "$DRIVER")
[ "$SYNC" = uncapped ] && engine+=(--disable-vsync)
displays() {
	cp "$ROOT/desktop/win/displays.ps1" /mnt/c/Temp/ProSkater/displays.ps1
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\ProSkater\displays.ps1' | tr -d '\r'
}
mkdir -p /mnt/c/Temp/ProSkater
{ echo "before $(date -Is)"; displays; } > "$RES/${LABEL}_displays.txt"
(
	echo "time,gpu_util_pct,gpu_clock_mhz,gpu_power_w,gpu_mem_mib,host_load1"
	while :; do
		g="$("$SMI" --query-gpu=utilization.gpu,clocks.gr,power.draw,memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')"
		echo "$(date +%T),$g,$(cut -d' ' -f1 /proc/loadavg)"
		sleep 1
	done
) > "$RES/${LABEL}_load.csv" &
mon=$!
bash "$ROOT/desktop/run_windows.sh" "$LABEL" "${engine[@]}" -- --autopilot --bench --gpu-time --quit-at-end \
	"--bench-out={out}/$LABEL.json" "--frametimes-out={out}/$LABEL.csv" "$@"
code=$?
kill $mon 2>/dev/null
wait $mon 2>/dev/null
{ echo "after $(date -Is)"; displays; } >> "$RES/${LABEL}_displays.txt"
if [ "$(grep -c "DISPLAY" "$RES/${LABEL}_displays.txt")" -gt 0 ] && \
	! diff <(sed -n '/^before/,/^after/p' "$RES/${LABEL}_displays.txt" | grep DISPLAY) <(sed -n '/^after/,$p' "$RES/${LABEL}_displays.txt" | grep DISPLAY) > /dev/null; then
	echo "WARNING: the monitor layout changed during the run (see ${LABEL}_displays.txt)"
fi
python3 - "$RES/$LABEL.json" "$RES/${LABEL}_load.csv" <<'EOF'
import csv, json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("no bench report: %s" % e)
d = r.get("desktop", {})
rows = list(csv.DictReader(open(sys.argv[2])))
util = [float(x["gpu_util_pct"]) for x in rows if x["gpu_util_pct"] not in ("", "[N/A]")]
print("%s | %s | %s | %s @ %s Hz | vsync %s" % (d.get("rendering_driver"), r.get("gpu"), r.get("api"), r.get("viewport"), d.get("screen_refresh_hz"), d.get("vsync")))
print("frames %d in %.1f s: %.1f fps avg, median %.2f ms, p95 %.2f ms, p99 %.2f ms, 1%% low %.1f fps, >16.7 ms: %d, max %.1f ms" % (
    r["frames"], r["seconds"], r["avg_fps"], r["median_ms"], r["p95_ms"], r["p99_ms"], r["one_pct_low_fps"], r["frames_over_16_7ms"], r["max_ms"]))
print("cpu %.2f ms/frame (p95 %.2f), render submit %.2f ms; msaa %s ssao %s glow %s tonemap %s fog %s shadows %s scale %s; score %d" % (
    r["cpu_ms_mean"], r["cpu_ms_p95"], r["render_submit_ms_mean"], r["msaa"], r["ssao"], r["glow"], r["tonemap"], r["fog"], r["sun_shadows"], r["scale_3d"], r["score"]))
if util:
    print("GPU load during the run: mean %.0f %%, max %.0f %% (%d samples)" % (sum(util) / len(util), max(util), len(util)))
EOF
exit $code
