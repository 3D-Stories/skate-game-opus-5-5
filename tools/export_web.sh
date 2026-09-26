#!/usr/bin/env bash
# The web build: the "Web" export (index.html / .js / .wasm / .pck) plus one resource pack
# per level that declares a "pack" in its levels/<id>/level.json. The Web preset excludes
# assets/levels/*, so a kit-built level is downloaded only when the player chooses it
# (LevelRegistry.fetch_pack); the Warehouse stays in index.pck.
#
#   tools/export_web.sh [out_dir]        (default build/web; run `godot --headless --path . --import` first)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/web}"
mkdir -p "$OUT"
godot --headless --path . --export-release "Web" "$OUT/index.html"
python3 - "$OUT" <<'PY' | while read -r id pack; do
import json, sys
for i in json.load(open("levels/registry.json"))["levels"]:
    p = json.load(open(f"levels/{i}/level.json"))["game"].get("pack", "")
    if p:
        print(i, p)
PY
  godot --headless --path . --script res://tools/pack_level.gd -- --level="$id" --out="$OUT/$pack"
done
ls -l "$OUT"/index.* "$OUT"/levels/*.pck 2>/dev/null || true
