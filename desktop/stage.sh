#!/usr/bin/env bash
# Makes the Windows build's staged project: a copy of the project in which desktop/ is visible
# to Godot and project.godot has desktop/project_windows.cfg appended.
#
#   bash desktop/stage.sh <name>     prints the staged project's path when it is ready
#                                    (used by desktop/build_windows.sh and test_desktop.sh)
#
# In the project itself desktop/ carries a .gdignore: Godot never scans it, so the editor, the
# tests and the web export are exactly as they were (even an unexported new file would reorder
# the UID and class caches inside the web .pck). The copy keeps the import cache and its mtimes,
# so only desktop/ is imported there. It lives outside the project (the test suites walk the
# whole project tree, .gdignore'd folders included), in a folder per checkout:
# $PROSKATER_STAGE, or ~/.cache/proskater-windows/<hash of the project path>/<name>.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: $0 <name>}"
BASE="${PROSKATER_STAGE:-${XDG_CACHE_HOME:-$HOME/.cache}/proskater-windows/$(printf %s "$ROOT" | sha1sum | cut -c1-12)}"
STAGE="$BASE/$NAME"
GODOT="${GODOT:-godot}"
cd "$ROOT"
[ -d .godot/imported ] || "$GODOT" --headless --path . --import > /dev/null 2>&1 || true
mkdir -p "$STAGE"
rsync -a --delete --exclude /.git --exclude /build/ --exclude /blender/ --exclude /renders/ \
	--exclude /evidence/ --exclude /engine/ --exclude /tests/results/ \
	--exclude /desktop/.gdignore --exclude /desktop/icon.png ./ "$STAGE/"
{ echo; cat desktop/project_windows.cfg; } >> "$STAGE/project.godot"
"$GODOT" --headless --path "$STAGE" --import > "$STAGE.import.log" 2>&1 || { tail -20 "$STAGE.import.log" >&2; exit 1; }
if grep -qE "SCRIPT ERROR|Parse Error" "$STAGE.import.log"; then
	grep -E -A2 "SCRIPT ERROR|Parse Error" "$STAGE.import.log" >&2
	exit 1
fi
echo "$STAGE"
