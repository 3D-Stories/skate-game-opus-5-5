#!/bin/bash
# Builds the Godot 4.7.2 web export template the game ships with (single-threaded release,
# the same configuration as the official "web_nothreads_release" template) from the
# 4.7.2-stable source plus the patches in engine/patches/, and copies it to
# engine/godot-4.7.2-web_nothreads_release-patched.zip (the Web export preset uses it).
#
#   engine/build_web_template.sh [workdir]      (default workdir: ~/src/godot-web-build)
#
# Needs git, python3 and about 3 GB of disk; fetches Emscripten 4.0.11 (the version Godot
# 4.7.2's CI builds web templates with) and SCons into the workdir.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HOME/src/godot-web-build}"
mkdir -p "$WORK"
cd "$WORK"
[ -d emsdk ] || git clone --depth 1 https://github.com/emscripten-core/emsdk.git
(cd emsdk && ./emsdk install 4.0.11 && ./emsdk activate 4.0.11)
source "$WORK/emsdk/emsdk_env.sh"
[ -d venv ] || python3 -m venv venv
. "$WORK/venv/bin/activate"
pip install --quiet scons==4.9.1
[ -d godot ] || git clone --depth 1 --branch 4.7.2-stable https://github.com/godotengine/godot.git
cd godot
git checkout -- .
for p in "$HERE"/patches/*.patch; do
  git apply --verbose "$p"
done
scons platform=web target=template_release threads=no production=yes -j"$(nproc)"
cp bin/godot.web.template_release.wasm32.nothreads.zip "$HERE/godot-4.7.2-web_nothreads_release-patched.zip"
echo "template: $HERE/godot-4.7.2-web_nothreads_release-patched.zip"
