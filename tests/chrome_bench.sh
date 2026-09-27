#!/bin/sh
# Runs the browser benchmark in Windows Chrome (from WSL) and waits for its report.
#
#   tests/chrome_bench.sh "<query>" [uncapped]
#     query     URL query for the game, e.g. "autopilot&bench"  or "autopilot&bench&benchsecs=60&nossao"
#               (the script adds &benchreport: the game then posts its report to this server)
#     uncapped  launch Chrome with --disable-gpu-vsync --disable-frame-rate-limit
#   CHROME_EXTRA="--use-angle=d3d11on12" tests/chrome_bench.sh ...   adds Chrome flags
#   CHROME_POS=4190,-1320 tests/chrome_bench.sh ...   window position (Windows desktop pixels)
#   BENCH_OUT=<file> tests/chrome_bench.sh ...        report file (tests/bench_server.py --out)
#
# Needs tests/bench_server.py running on port 8790 (it appends each report to
# tests/results/bench_runs.jsonl). Chrome gets its own profile (C:\Temp\skatebench),
# device scale 1 and a 1920x1080 page, on the left monitor, pinned topmost without focus so
# Windows does not throttle it. BENCH_PORT, BENCH_OUT and BENCH_PROFILE override the port, the
# report file and the profile name (two worktrees benchmarking at once must not share a profile:
# each run closes the Chrome windows of its own profile).
Q="$1"
FLAGS=""
[ "$2" = "uncapped" ] && FLAGS="--disable-gpu-vsync --disable-frame-rate-limit"
FLAGS="$FLAGS $CHROME_EXTRA"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${BENCH_OUT:-$DIR/results/bench_runs.jsonl}"
PORT="${BENCH_PORT:-8790}"
PROFILE="${BENCH_PROFILE:-skatebench}"
kill_chrome() {
  powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { \$_.CommandLine -like '*$PROFILE*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" > /dev/null 2>&1
}
kill_chrome
sleep 3
n0=$(cat "$OUT" 2>/dev/null | wc -l)
CH="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
(nohup "$CH" --user-data-dir="C:\\Temp\\$PROFILE" --no-first-run --no-default-browser-check --force-device-scale-factor=1 $FLAGS \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling \
  --disable-features=CalculateNativeWinOcclusion --window-position=${CHROME_POS:--3400,40} --window-size=1936,1119 \
  --app="http://localhost:$PORT/?$Q&benchreport" > /tmp/chrome_bench_run.log 2>&1 &)
sleep 8
sed "s/\*skatebench\*/*$PROFILE*/" "$DIR/chrome_topmost.ps1" > "/mnt/c/Temp/${PROFILE}_top.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\\Temp\\${PROFILE}_top.ps1" 2>&1 | tr -d '\r'
until [ "$(cat "$OUT" 2>/dev/null | wc -l)" -gt "$n0" ]; do sleep 2; done
kill_chrome
tail -1 "$OUT"
