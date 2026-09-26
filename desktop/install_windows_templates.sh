#!/usr/bin/env bash
# Installs the official Godot 4.7.2 Windows export templates (x86_64 release and debug, and
# their console wrappers) into Godot's export template folder. They come from the Godot
# project's own GitHub release (official engine binaries), and the download is checked
# against the SHA-512 sums published with that release before anything is installed.
#
#   bash desktop/install_windows_templates.sh [cache dir]    (default: ~/src/godot-templates-4.7.2)
#
# The .tpz is 1.3 GB (every platform's templates); it is kept in the cache dir and only the
# four Windows x86_64 files are unpacked. Needs curl, sha512sum and python3.
set -euo pipefail
VER=4.7.2
URL="https://github.com/godotengine/godot/releases/download/$VER-stable"
TPZ="Godot_v$VER-stable_export_templates.tpz"
CACHE="${1:-$HOME/src/godot-templates-$VER}"
DEST="${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates}/$VER.stable"
mkdir -p "$CACHE" "$DEST"
cd "$CACHE"
curl -fsSL -o SHA512-SUMS.txt "$URL/SHA512-SUMS.txt"
grep "  $TPZ\$" SHA512-SUMS.txt > tpz.sha512
if ! sha512sum -c --status tpz.sha512 2>/dev/null; then
	echo "downloading $URL/$TPZ"
	curl -fL --retry 3 -o "$TPZ" "$URL/$TPZ"
fi
sha512sum -c tpz.sha512            # stops here (set -e) if the file does not match
python3 - "$TPZ" "$DEST" "$VER" <<'EOF'
import hashlib, os, sys, zipfile
tpz, dest, ver = sys.argv[1:]
z = zipfile.ZipFile(tpz)
got = z.read("templates/version.txt").decode().strip()
assert got == ver + ".stable", "template version %s, expected %s.stable" % (got, ver)
for mode in ("release", "debug"):
    for suffix in ("", "_console"):
        name = "windows_%s_x86_64%s.exe" % (mode, suffix)
        data = z.read("templates/" + name)      # zipfile checks each member's CRC-32
        with open(os.path.join(dest, name), "wb") as f:
            f.write(data)
        print("installed %-36s %10d bytes  sha256 %s" % (name, len(data), hashlib.sha256(data).hexdigest()))
if not os.path.exists(os.path.join(dest, "version.txt")):
    with open(os.path.join(dest, "version.txt"), "w") as f:
        f.write(ver + ".stable\n")
print("templates in", dest)
EOF
