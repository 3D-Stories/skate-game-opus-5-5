#!/usr/bin/env bash
# Runs the Windows build natively on this PC's Windows side, from WSL, and collects its files:
#
#   bash desktop/run_windows.sh <label> [engine options] [-- game options]
#   e.g. bash desktop/run_windows.sh gl_bench -- --autopilot --bench --bench-out={out}/gl_bench.json --quit-at-end
#
# - copies build/windows/ProSkater.exe to C:\Temp\ProSkater\ (running it from \\wsl$ is slow)
# - writes C:\Temp\ProSkater\override.cfg (read by Godot from the exe's folder; for these
#   test runs only, not part of the build): the window is never activated, so it cannot take
#   the keyboard from whoever is using the PC (display/window/size/no_focus), it is a
#   WIN_SIZE (default 1920x1080) window, always on top, centred on monitor WIN_SCREEN (default
#   DISPLAY2, a 60 Hz 3440x1440 screen here), and every print is flushed to the log at once.
#   NOFOCUS=0 drops the no-focus line. Game option --window=fullscreen then makes it
#   fullscreen on that monitor.
# - refuses to start unless WIN_SCREEN exists, fits the window and is not the primary monitor
#   (the PC's user works on the primary one); desktop/win/pick_screen.ps1 asks Windows again
#   before every run, as the monitors can be rearranged at any time
# - {out} in any option stands for C:/Temp/ProSkater/out. The game's output goes to
#   tests/results/windows/<label>.log, and every C:/Temp/ProSkater/out/<label>* file is copied
#   to tests/results/windows/ afterwards
# The exit status is the game's.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:?usage: $0 <label> [engine options] [-- game options]}"
shift
WIN_DIR=/mnt/c/Temp/ProSkater
WIN_OUT='C:/Temp/ProSkater/out'
RES="$ROOT/tests/results/windows"
mkdir -p "$WIN_DIR/out" "$RES"
# Clear this label's previous results first, so a run that is refused or fails to start
# leaves nothing behind for desktop/smoke_windows.sh to read as a pass.
rm -f "$RES/$LABEL.log" "$RES/${LABEL}_"* "$WIN_DIR/out/$LABEL"*
EXE="$ROOT/build/windows/ProSkater.exe"
[ -s "$EXE" ] || { echo "no $EXE: run desktop/build_windows.sh first"; exit 2; }
cmp -s "$EXE" "$WIN_DIR/ProSkater.exe" || cp "$EXE" "$WIN_DIR/ProSkater.exe"
SCREEN_NAME="${WIN_SCREEN:-DISPLAY2}"
SIZE="${WIN_SIZE:-1920x1080}"
SW="${SIZE%x*}"
SH="${SIZE#*x}"
cp "$ROOT/desktop/win/pick_screen.ps1" "$WIN_DIR/pick_screen.ps1"
PICK="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Temp\ProSkater\pick_screen.ps1' -name "$SCREEN_NAME" -w "$SW" -h "$SH" | tr -d '\r')"
case "$PICK" in *primary=False*) ;; *) echo "[run_windows] refusing: no secondary monitor $SCREEN_NAME that fits a $SIZE window ($PICK)"; exit 3 ;; esac
read -r PX PY SCREEN <<< "$PICK"
ORIGIN="${PICK##*origin=}"
OX="${ORIGIN%,*}"               # Godot places windows from the desktop's top-left corner
OY="${ORIGIN#*,}"
{
	echo "; test runs only (desktop/run_windows.sh), not part of the build"
	echo "[application]"
	echo "run/flush_stdout_on_print=true"
	echo "[display]"
	echo "window/size/mode=0"
	echo "window/size/initial_position_type=0"
	echo "window/size/initial_position=Vector2i($((PX - OX)), $((PY - OY)))"
	[ "${TOPMOST:-1}" = 1 ] && echo "window/size/always_on_top=true"
	[ "${NOFOCUS:-1}" = 1 ] && echo "window/size/no_focus=true"
} > "$WIN_DIR/override.cfg"
args=()
placed=0
for a in "$@"; do
	[ "$a" = "--" ] && break
	a="${a//\{out\}/$WIN_OUT}"
	case "$a" in -f|--fullscreen|-w|--windowed|--resolution|--position|--screen|-m|--maximized) placed=1 ;; esac
	args+=("$a")
done
user=()
seen=0
for a in "$@"; do
	[ $seen = 1 ] && user+=("${a//\{out\}/$WIN_OUT}")
	[ "$a" = "--" ] && seen=1
done
# --window=windowed keeps desktop.gd from switching to fullscreen (it cannot see engine options)
[ $placed = 1 ] || args+=(--resolution "$SIZE")
case " ${user[*]} " in *" --window="*) ;; *) [ $placed = 1 ] || user=(--window=windowed "${user[@]}") ;; esac
rm -f "$WIN_DIR/out/$LABEL"*
cd "$WIN_DIR"
echo "[run_windows] $LABEL on $SCREEN: ProSkater.exe ${args[*]} -- ${user[*]}"
start=$(date +%s)
./ProSkater.exe "${args[@]}" -- "${user[@]}" > "$RES/$LABEL.log" 2>&1
code=$?
echo "[run_windows] $LABEL: exit $code after $(( $(date +%s) - start )) s"
cp "$WIN_DIR/out/$LABEL"* "$RES/" 2>/dev/null
ls -1 "$RES/$LABEL"* 2>/dev/null | sed "s#^$ROOT/#  #"
exit $code
