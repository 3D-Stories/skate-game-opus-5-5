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
run levelsel   300  --fixed-fps 60 -s tests/test_level_select.gd
# every kit-built level in levels/registry.json: its park suite (tests/test_level.gd) and its
# own autopilot two-minute run
LEVELS=$(python3 -c "import json
for i in json.load(open('levels/registry.json'))['levels']:
    if 'features' in json.load(open(f'levels/{i}/level.json')).get('build', {}): print(i)")
EXTRA=""
for id in $LEVELS; do
	run "level_$id" 900 --fixed-fps 60 -s tests/test_level.gd -- --level="$id"
	run "fullrun_$id" 600 --fixed-fps 60 -- --level="$id" --autopilot=test --verbose
	EXTRA="$EXTRA level_$id fullrun_$id"
done
wait
printf '%-14s %-5s %s\n' suite exit summary
for n in scoring flow input audio park anims clips handling ragdoll camera fullrun levelsel $EXTRA; do
	e=$(cat "tests/results/logs/$n.exit" 2>/dev/null || echo "?")
	s=$(grep -aE "passed|PASSED|failed|\[run\] finished|checks" "tests/results/logs/$n.log" | tail -1 | cut -c1-150)
	printf '%-14s %-5s %s\n' "$n" "$e" "$s"
done
for id in $LEVELS; do
	grep -aE "^\[ap|^\[run\]" "tests/results/logs/fullrun_$id.log" | grep -v "  hp st" > "tests/results/fullrun_$id.txt"
done
grep -aE "\[run\] finished" tests/results/logs/fullrun.log > tests/results/fullrun.txt
grep -aE "\[run\]|\[goal\]|\[route\]" tests/results/logs/fullrun.log >> tests/results/fullrun.txt
