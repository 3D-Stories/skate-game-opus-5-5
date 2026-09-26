#!/usr/bin/env bash
# Makes the Windows build's staged project: a copy of the project in which desktop/ is visible
# to Godot and project.godot has desktop/project_windows.cfg appended.
#
#   bash desktop/stage.sh <stage dir>        (used by desktop/build_windows.sh and test_desktop.sh)
#
# In the project itself desktop/ carries a .gdignore: Godot never scans it, so the editor, the
# tests and the web export are exactly as they were (even an unexported new file would reorder
# the UID and class caches inside the web .pck). The copy keeps the import cache and its mtimes,
# so only desktop/ is imported here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: $0 <stage dir>}"
GODOT="${GODOT:-godot}"
cd "$ROOT"
[ -d .godot/imported ] || "$GODOT" --headless --path . --import > /dev/null 2>&1
mkdir -p "$STAGE"
rsync -a --delete --exclude /.git --exclude /build/ --exclude /blender/ --exclude /renders/ \
	--exclude /evidence/ --exclude /engine/ --exclude /tests/results/ \
	--exclude /desktop/.gdignore --exclude /desktop/icon.png ./ "$STAGE/"
{ echo; cat desktop/project_windows.cfg; } >> "$STAGE/project.godot"
"$GODOT" --headless --path "$STAGE" --import > "$STAGE.import.log" 2>&1 || { tail -20 "$STAGE.import.log"; exit 1; }
if grep -qE "SCRIPT ERROR|Parse Error" "$STAGE.import.log"; then
	grep -E -A2 "SCRIPT ERROR|Parse Error" "$STAGE.import.log"
	exit 1
fi
