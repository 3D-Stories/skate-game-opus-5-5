#!/usr/bin/env bash
# Vercel's build step (vercel.json "buildCommand"). Pushes to master deploy through
# Vercel's GitHub integration; Vercel's build image (Amazon Linux 2023) has no Godot, so
# this installs the official Godot 4.7.2 Linux binary, checked against its pinned SHA-512
# from the release's SHA512-SUMS.txt, imports the project and runs the same web export as
# tools/export_web.sh into build/web (the Web preset's release template is the patched
# one committed in engine/). Runs anywhere with bash, curl and unzip or python3.
set -euo pipefail
cd "$(dirname "$0")/.."

VER=4.7.2-stable
ZIP="Godot_v${VER}_linux.x86_64.zip"
SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
TOOLS="${GODOT_TOOLS_DIR:-/tmp/godot-$VER}"

if [ ! -x "$TOOLS/godot" ]; then
  mkdir -p "$TOOLS"
  curl -fsSL --retry 3 -o "$TOOLS/$ZIP" "https://github.com/godotengine/godot/releases/download/$VER/$ZIP"
  echo "$SHA512  $TOOLS/$ZIP" | sha512sum -c -
  if command -v unzip >/dev/null; then
    unzip -q -o "$TOOLS/$ZIP" -d "$TOOLS"
  else
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$TOOLS/$ZIP" "$TOOLS"
  fi
  mv "$TOOLS/Godot_v${VER}_linux.x86_64" "$TOOLS/godot"
  chmod +x "$TOOLS/godot"
fi
export PATH="$TOOLS:$PATH"
godot --version

godot --headless --path . --import
bash tools/export_web.sh build/web
