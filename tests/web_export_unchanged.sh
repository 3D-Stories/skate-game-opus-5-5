#!/usr/bin/env bash
# Checks that the working tree exports the same web build as a base commit, byte for byte:
#
#   bash tests/web_export_unchanged.sh [base-commit]     (default: the merge-base with main)
#   -> tests/results/web_export_unchanged.txt, exit 0 when every file is identical
#
# Both exports use the same import cache. Godot's GLB import is not byte-reproducible (two
# fresh imports of the same commit give imported .scn files that differ by a few bytes), so the
# base commit is imported once into a clean copy and the working tree's copy reuses that .godot.
# Every output file is compared by SHA-256 and the .pck entry by entry (tests/pck_diff.py).
set -u
cd "$(dirname "$0")/.."
BASE="${1:-$(git merge-base HEAD main)}"
OUT=tests/results/web_export_unchanged.txt
W="$(mktemp -d /tmp/web_export_check.XXXXXX)"
mkdir -p "$W/base" "$W/new"
# blender/, renders/, evidence/ are .gdignore'd sources and recordings: not needed to export
git archive "$BASE" -- . ':!blender' ':!renders' ':!evidence' | tar -x -C "$W/base"
rsync -a --exclude /.git --exclude /.godot/ --exclude /build/ --exclude /blender/ --exclude /renders/ \
	--exclude /evidence/ --exclude /tests/results/ ./ "$W/new/"
export_web() {  # project dir -> $1.out/ (outside the project, so it is never imported)
	mkdir -p "$1.out"
	(cd "$1" && godot --headless --path . --import > ../"$(basename "$1")".import.log 2>&1 \
		&& godot --headless --path . --export-release "Web" "$1.out/index.html" > ../"$(basename "$1")".export.log 2>&1)
	echo "export $1: exit $?"
	(cd "$1.out" && sha256sum * > ../"$(basename "$1")".sums.txt)
}
export_web "$W/base"
cp -a "$W/base/.godot" "$W/new/.godot"
export_web "$W/new"
{
	echo "web export: base $(git rev-parse --short "$BASE") vs working tree of $(git rev-parse --short HEAD) ($(git status --short | wc -l) changed paths), same import cache"
	echo "--- files (sha256)"
	paste -d' ' <(awk '{print $2, $1}' "$W/base.sums.txt") <(awk '{print $1}' "$W/new.sums.txt") |
		awk '{printf "%-28s %s  %s\n", $1, ($2 == $3 ? "identical" : "DIFFERENT"), substr($2, 1, 16)}'
	echo "--- pck entries"
	python3 tests/pck_diff.py "$W/base.out/index.pck" "$W/new.out/index.pck"
	pck=$?
	if diff -q "$W/base.sums.txt" "$W/new.sums.txt" > /dev/null && [ $pck -eq 0 ]; then
		echo "RESULT: PASS - the web export is byte-for-byte identical"
	else
		echo "RESULT: FAIL - the web export differs"
	fi
} | tee "$OUT"
grep -q "RESULT: PASS" "$OUT" && rm -rf "$W"
grep -q "RESULT: PASS" "$OUT"
