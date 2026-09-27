#!/usr/bin/env bash
# Headless tests of the Windows build's desktop layer, in the staged Windows project:
#
#   bash desktop/test_desktop.sh        -> tests/results/desktop.txt   (exit 0 when all pass)
#
# 1. desktop/test_desktop.gd: menus, quit, fullscreen toggle, focus-loss pause, window sizing,
#    bench-report pickup, settings report (on the real main scene).
# 2. The command-line equivalents of the web URL options, end to end: the full scripted run
#    with -- --autopilot --bench --bench-out=... --frametimes-out=... --info-out=... --quit-at-end,
#    then the files it wrote (all five goals, the settings) and that it quit by itself; and the
#    same on Eastside Baths with --level=baths (all six goals).
#    Headless Godot renders no frames, so the bench report itself comes from the native runs.
# The native Windows runs (desktop/run_windows.sh, bench_windows.sh) cover the real window,
# renderer, bench report, audio device and input; these tests need no display.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
GODOT="${GODOT:-godot}"
RES="$ROOT/tests/results"
T="$(mktemp -d /tmp/desktop_test.XXXXXX)"
mkdir -p "$RES/logs"
STAGE="$(bash desktop/stage.sh stage-test)" || { echo "staging failed"; exit 1; }
timeout 600 "$GODOT" --headless --path "$STAGE" --fixed-fps 60 -s res://desktop/test_desktop.gd -- "$T/unit.txt" > "$RES/logs/desktop_unit.log" 2>&1
unit=$?
# the same on Eastside Baths (--level=baths), at the same time
timeout 900 "$GODOT" --headless --path "$STAGE" --fixed-fps 60 -- --level=baths --autopilot --quit-at-end \
	"--info-out=$T/info_baths.json" > "$RES/logs/desktop_cli_baths.log" 2>&1 &
baths_pid=$!
timeout 900 "$GODOT" --headless --path "$STAGE" --fixed-fps 60 -- --autopilot --bench --quit-at-end \
	"--bench-out=$T/bench.json" "--frametimes-out=$T/frames.csv" "--info-out=$T/info.json" > "$RES/logs/desktop_cli.log" 2>&1
cli=$?
wait $baths_pid
baths=$?
python3 - "$T" "$unit" "$cli" "$RES/logs/desktop_cli.log" "$baths" "$RES/logs/desktop_cli_baths.log" > "$T/cli.txt" <<'EOF'
import csv, json, os, sys
t, unit_code, cli_code, log = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
baths_code, baths_log = int(sys.argv[5]), sys.argv[6]
res = []
def check(ok, what, detail=""):
    res.append(("PASS  " if ok else "FAIL  ") + what + ("  (%s)" % detail if detail else ""))
check(unit_code == 0, "desktop/test_desktop.gd exits 0", "exit %d" % unit_code)
check(cli_code == 0, "the scripted run with --quit-at-end quits by itself, exit 0", "exit %d" % cli_code)
logtext = open(log, errors="replace").read()
check("[run] finished" in logtext, "the run reaches the end screen")
check("SCRIPT ERROR" not in logtext, "no script errors in the run's log")
# headless Godot renders no frames, so bench.gd has nothing to report: --quit-at-end must
# still quit (after waiting 10 s for the report); the native runs write the real reports
check("no bench report came" in logtext and not os.path.exists(os.path.join(t, "bench.json")),
      "--bench without rendered frames: no report, and --quit-at-end still quits")
rows = open(os.path.join(t, "frames.csv")).read().splitlines() if os.path.exists(os.path.join(t, "frames.csv")) else []
check(rows[:1] == ["run_s,frame_ms"], "--frametimes-out: the file is written (no rows without rendered frames)", "%d rows" % (len(rows) - 1))
try:
    i = json.load(open(os.path.join(t, "info.json")))
except Exception:
    i = {}
goals = {k: v for g in i.get("run", {}).get("goals", []) for k, v in g.items()}
check(i.get("when") == "end" and len(goals) == 5 and all(goals.values()), "--info-out: written at the end, all five goals complete", str(goals))
check(i.get("run", {}).get("score", 0) >= 25000, "the scripted run scores over 25,000", str(i.get("run", {}).get("score")))
check(i.get("audio", {}).get("run_levels", {}).get("frames", 0) > 0, "the settings report samples the audio levels during the run")
# Eastside Baths: -- --level=baths --autopilot --quit-at-end
blog = open(baths_log, errors="replace").read()
check(baths_code == 0 and "[run] finished" in blog and "SCRIPT ERROR" not in blog,
      "--level=baths: the Baths scripted run ends and quits by itself, no script errors", "exit %d" % baths_code)
try:
    b = json.load(open(os.path.join(t, "info_baths.json")))
except Exception:
    b = {}
bg = {k: v for g in b.get("run", {}).get("goals", []) for k, v in g.items()}
want = [g["id"] for g in json.load(open("levels/baths/level.json"))["game"]["goals"]]
check(b.get("when") == "end" and sorted(bg) == sorted(want) and all(bg.values()),
      "--level=baths: all six Eastside Baths goals complete", str(bg))
check(b.get("run", {}).get("score", 0) >= 25000, "the Baths scripted run scores over 25,000", str(b.get("run", {}).get("score")))
print("\n".join(res))
EOF
{
	cat "$T/unit.txt" 2>/dev/null || echo "desktop/test_desktop.gd wrote no results (see tests/results/logs/desktop_unit.log)"
	echo
	echo "command-line options, end to end (headless scripted run):"
	cat "$T/cli.txt"
} > "$RES/desktop.txt"
p=$(grep -c "^PASS" "$RES/desktop.txt")
f=$(grep -c "^FAIL" "$RES/desktop.txt")
echo "desktop: $p checks passed, $f failed" | tee -a "$RES/desktop.txt"
rm -rf "$T"
[ "$f" -eq 0 ] && [ "$p" -gt 0 ]
