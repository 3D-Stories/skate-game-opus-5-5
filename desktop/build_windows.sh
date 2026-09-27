#!/usr/bin/env bash
# Builds the native Windows (x86_64) version of the game, from Linux or WSL:
#
#   bash desktop/build_windows.sh [debug]
#
#   build/windows/ProSkater.exe                          the game; its data is embedded in the exe
#   build/windows/ProSkater-<version>-windows-x86_64.zip  the exe and README.txt, to hand out
#   build/windows/SHA256SUMS.txt, build/windows/export.log
#
# The export runs on a staged copy of the project (made by desktop/stage.sh, outside the
# project tree): there desktop/ is visible to Godot and project.godot has
# desktop/project_windows.cfg appended. In the project itself desktop/ is .gdignore'd, so the
# Windows-only files and settings (the Desktop autoload, the icon, fullscreen start, the
# renderer) never touch the editor, the tests or the web export, which stays byte-for-byte
# the same (tests/web_export_unchanged.sh checks it).
#
# Needs Godot 4.7.2 as `godot` (or GODOT=/path/to/godot), rsync and python3, and the Windows
# export templates: desktop/install_windows_templates.sh installs the official ones (checked
# against the release's SHA-512 sums) when they are missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-release}"
[ "$MODE" = release ] || [ "$MODE" = debug ] || { echo "usage: $0 [release|debug]"; exit 2; }
GODOT="${GODOT:-godot}"
VER="$("$GODOT" --version | cut -d. -f1-3)"
TPL="${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates}/$VER.stable"
[ -f "$TPL/windows_${MODE}_x86_64.exe" ] || bash desktop/install_windows_templates.sh
OUT="$ROOT/build/windows"
mkdir -p "$OUT"
STAGE="$(bash desktop/stage.sh stage)"

rm -f "$OUT/ProSkater.exe" "$OUT/ProSkater.console.exe"
"$GODOT" --headless --path "$STAGE" "--export-$MODE" "Windows Desktop" "$OUT/ProSkater.exe" > "$OUT/export.log" 2>&1 || true
if [ ! -s "$OUT/ProSkater.exe" ] || grep -qE "^ERROR|export failed" "$OUT/export.log"; then
	grep -E "ERROR|WARNING" "$OUT/export.log" || tail -20 "$OUT/export.log"
	echo "export failed (log: $OUT/export.log)"
	exit 1
fi

APPVER="$(sed -n 's/^config\/version="\(.*\)"/\1/p' desktop/project_windows.cfg)"
ZIP="$OUT/ProSkater-$APPVER-windows-x86_64.zip"
python3 - "$OUT" "$ZIP" <<'EOF'
import os, sys, zipfile
out, zp = sys.argv[1:]
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in ("ProSkater.exe", "ProSkater.console.exe"):
        if os.path.exists(os.path.join(out, f)):
            z.write(os.path.join(out, f), "ProSkater/" + f)
    z.write("desktop/README.txt", "ProSkater/README.txt")
EOF
(cd "$OUT" && sha256sum ProSkater*.exe "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "Windows $MODE build (Godot $VER, templates: $TPL):"
(cd "$OUT" && ls -l ProSkater*.exe "$(basename "$ZIP")" | awk '{printf "  %-44s %6.1f MB\n", $9, $5 / 1048576}')
