#!/usr/bin/env bash
# Native smoke test of the Windows build, both levels, on this PC's Windows side (from WSL):
#
#   bash desktop/smoke_windows.sh        -> tests/results/windows/smoke.txt   (exit 0 when all pass)
#
# 1. The Warehouse:     -- --autopilot --bench --quit-at-end        all five goals, a bench report
# 2. Eastside Baths:    -- --level=baths --autopilot --bench ...    all six goals, a bench report
# 3. The level select, with the keyboard (window messages, desktop/win/drive.ps1): at the start
#    screen Tab opens it, Right + Enter loads Eastside Baths, Enter starts a run there, W rides,
#    Esc pauses, Q twice quits. Screenshots: the game's own frames (--shots) and its window
#    (PrintWindow), in this run only: saving a 1080p PNG holds up the frame it is taken in
#    (about 0.75 s), so a benchmark run never takes any.
# Every run is a 1920x1080 window on a secondary monitor that never takes the focus
# (desktop/run_windows.sh refuses the primary monitor). Needs build/windows/ProSkater.exe.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RES="$ROOT/tests/results/windows"
W=/mnt/c/Temp/ProSkater
O='C:\Temp\ProSkater\out'
SHOTS="${SMOKE_SHOTS:-/tmp/proskater_smoke_shots}"   # screenshots stay out of the repo
mkdir -p "$RES" "$W/out" "$SHOTS"
cp desktop/win/drive.ps1 "$W/drive.ps1"

bash desktop/run_windows.sh smoke_warehouse -- --autopilot --bench "--bench-out={out}/smoke_warehouse_bench.json" \
	"--info-out={out}/smoke_warehouse_info.json" --quit-at-end
wh=$?
bash desktop/run_windows.sh smoke_baths -- --level=baths --autopilot --bench "--bench-out={out}/smoke_baths_bench.json" \
	"--info-out={out}/smoke_baths_info.json" --quit-at-end
ba=$?

LS="wait:8000;shot:$O\\smoke_levelsel_1_start.png;tap:Tab;wait:1500;tap:Right;wait:800;shot:$O\\smoke_levelsel_2_select.png"
LS="$LS;tap:Return;wait:10000;shot:$O\\smoke_levelsel_3_baths_start.png;tap:Return;wait:1500;hold:W:3000;wait:500"
LS="$LS;shot:$O\\smoke_levelsel_4_riding.png;tap:Escape;wait:1500;shot:$O\\smoke_levelsel_5_pause.png;tap:Q;wait:700;tap:Q"
rm -rf "$W/out/smoke_levelsel_shots"
bash desktop/run_windows.sh smoke_levelsel -- --input-log "--info-out={out}/smoke_levelsel_info.json" \
	"--shots={out}/smoke_levelsel_shots" --shot-every=1 &
game=$!
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\ProSkater\drive.ps1' -exe 'C:\Temp\ProSkater\ProSkater.exe' \
	-steps "$LS" -out "$O\\smoke_levelsel_drive.json" > /dev/null 2>&1
wait $game
ls=$?
mv "$RES"/smoke_levelsel_*.png "$SHOTS/" 2>/dev/null
cp "$W/out/smoke_levelsel_shots/"*.png "$SHOTS/" 2>/dev/null
cp "$W/out/smoke_levelsel_drive.json" "$RES/" 2>/dev/null

python3 - "$RES" "$wh" "$ba" "$ls" <<'EOF' | tee "$RES/smoke.txt"
import json, sys
res, wh_code, ba_code, ls_code = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
out = []
def check(ok, what, detail=""):
    out.append(("PASS  " if ok else "FAIL  ") + what + ("  (%s)" % detail if detail else ""))
def load(p):
    try:
        return json.loads(open(p, encoding="utf-8-sig").read())
    except Exception:
        return {}
def text(p):
    try:
        return open(p, errors="replace").read()
    except Exception:
        return ""
def goals(info):
    return {k: v for g in info.get("run", {}).get("goals", []) for k, v in g.items()}
bench_rows = []
for lvl, code, n in [("warehouse", wh_code, 5), ("baths", ba_code, 6)]:
    name = {"warehouse": "the Warehouse", "baths": "Eastside Baths"}[lvl]
    log, info, b = text(f"{res}/smoke_{lvl}.log"), load(f"{res}/smoke_{lvl}_info.json"), load(f"{res}/smoke_{lvl}_bench.json")
    d = b.get("desktop", {})
    check(code == 0 and "[run] finished" in log and "SCRIPT ERROR" not in log,
          f"{name}: the scripted run ends, the game quits by itself (exit 0), no script errors", "exit %d" % code)
    g = goals(info)
    check(info.get("when") == "end" and len(g) == n and all(g.values()), f"{name}: all {n} goals complete", str(g))
    check(b.get("frames", 0) > 7000 and b.get("seconds", 0) > 119,
          f"{name}: bench report for the whole 120 s run", "%s frames, %s s" % (b.get("frames"), b.get("seconds")))
    check(d.get("rendering_driver") == "opengl3" and d.get("adapter") == "NVIDIA GeForce RTX 4080" and d.get("render_size") == "1920x1080"
          and b.get("msaa") == "4x" and b.get("ssao") and b.get("glow") and b.get("tonemap") == "agx" and b.get("sun_shadows"),
          f"{name}: OpenGL 3.3 on the RTX 4080 at 1920x1080 with 4x MSAA, SSAO, glow, AgX, sun shadows (read back)",
          "%s, %s, %s" % (d.get("rendering_driver"), d.get("adapter"), d.get("render_size")))
    bench_rows.append((name, b, d))
ls_log, ls_info = text(f"{res}/smoke_levelsel.log"), load(f"{res}/smoke_levelsel_info.json")
keys = ls_info.get("input", {}).get("keys", {})
check(all(keys.get(k, 0) >= 1 for k in ["Tab", "Right", "Enter", "W", "Escape"]) and keys.get("Q", 0) >= 2,
      "level select run: the game got the keys (Tab, Right, Enter, W, Esc, Q twice)", str(keys))
check("[level] baths loaded" in ls_log, "level select run: Tab, Right + Enter at the start screen load Eastside Baths")
g = goals(ls_info)
want = [x["id"] for x in json.load(open("levels/baths/level.json"))["game"]["goals"]]
check(sorted(g) == sorted(want), "level select run: the run that follows has the Baths goals", str(sorted(g)))
speeds = [float(l.rsplit("speed ", 1)[1].split()[0]) for l in ls_log.splitlines() if "[desktop] run " in l and "speed" in l]
check(max(speeds, default=0) > 3.0, "level select run: W pushes the skater on the Baths", "top speed %.1f m/s" % max(speeds, default=0))
check("quit from the pause screen" in ls_log and ls_code == 0, "level select run: Esc pauses, Q twice quits (exit 0)", "exit %d" % ls_code)
au = ls_info.get("audio", {}).get("run_levels", {})
check(au.get("frames_with_sound", 0) > 0, "level select run: the game's master bus plays sound on the Baths",
      "%s of %s frames, sounds: %s" % (au.get("frames_with_sound"), au.get("frames"), ", ".join(sorted(au.get("sounds_played", [])))))
p = sum(1 for l in out if l.startswith("PASS"))
f = sum(1 for l in out if l.startswith("FAIL"))
print("Windows build, native smoke test (desktop/smoke_windows.sh), both levels: %d passed, %d failed" % (p, f))
print("\n".join(out))
print()
print("| Level | Frames | Average | Median | p95 | p99 | 1 % low | > 16.7 ms | Slowest | Score | Window |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for name, b, d in bench_rows:
    print("| %s | %s | %s fps | %s ms | %s ms | %s ms | %s fps | %s | %s ms | %s | %s %s on screen %s, %s Hz, vsync %s |" % (
        name, int(b.get("frames", 0)), b.get("avg_fps"), b.get("median_ms"), b.get("p95_ms"), b.get("p99_ms"), b.get("one_pct_low_fps"),
        int(b.get("frames_over_16_7ms", 0)), b.get("max_ms"), int(b.get("score", 0)), d.get("window_mode"), d.get("window_size"),
        d.get("screen"), d.get("screen_refresh_hz"), d.get("vsync")))
sys.exit(0 if f == 0 else 1)
EOF
