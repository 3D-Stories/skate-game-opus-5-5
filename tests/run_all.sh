#!/usr/bin/env bash
# Runs every headless Godot test suite (in parallel) plus the full autopilot two-minute run,
# and prints one summary line per suite. Results land in tests/results/.
#   bash tests/run_all.sh            (from the project root)
set -u
cd "$(dirname "$0")/.."
mkdir -p tests/results/logs
G="godot --headless --path ."
run() {  # name, timeout (s), args...
	local name=$1 t=$2; shift 2
	( timeout "$t" $G "$@" > "tests/results/logs/$name.log" 2>&1; echo $? > "tests/results/logs/$name.exit" ) &
}
run scoring    300  -s tests/test_scoring.gd
run flow       600  --fixed-fps 60 -s tests/test_flow.gd
run input      600  --fixed-fps 60 -s tests/test_input.gd
run audio      600  --fixed-fps 60 -s tests/test_audio.gd
run park       600  --fixed-fps 60 -s tests/test_park.gd
run anims      600  -s tests/test_anims.gd
run clips      900  --fixed-fps 60 -s tests/test_clips_in_game.gd
run handling   1200 --fixed-fps 60 -s tests/test_handling.gd
run ragdoll    600  --fixed-fps 60 -s tests/test_ragdoll.gd
run camera     1500 --fixed-fps 60 -s tests/test_camera_run.gd -- --autopilot=test
run fullrun    600  --fixed-fps 60 -- --autopilot=test
wait
printf '%-10s %-5s %s\n' suite exit summary
for n in scoring flow input audio park anims clips handling ragdoll camera fullrun; do
	e=$(cat "tests/results/logs/$n.exit" 2>/dev/null || echo "?")
	s=$(grep -aE "passed|PASSED|failed|\[run\] finished|checks" "tests/results/logs/$n.log" | tail -1 | cut -c1-150)
	printf '%-10s %-5s %s\n' "$n" "$e" "$s"
done
grep -aE "\[run\] finished" tests/results/logs/fullrun.log > tests/results/fullrun.txt
grep -aE "\[run\]|\[goal\]|\[route\]" tests/results/logs/fullrun.log >> tests/results/fullrun.txt
