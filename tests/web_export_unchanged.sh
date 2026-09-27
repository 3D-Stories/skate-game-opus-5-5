#!/usr/bin/env bash
# Checks that the working tree exports the same web build as a base commit, byte for byte:
#
#   bash tests/web_export_unchanged.sh [base-commit]
#   -> tests/results/web_export_unchanged.txt, exit 0 when every file is identical
#
# The default base is the tree just before the Windows build: the parent of the commit that
# added desktop/desktop.gd. The web build is tools/export_web.sh where the project has it
# (index.html / .js / .wasm / .pck plus one pack per level, levels/<id>.pck), else the plain
# "Web" export.
#
# The working tree side is what a fresh checkout of it would hold: every file git would commit
# (tracked or new, .gitignore applied), taken through a temporary index, so a file that only
# a fresh checkout would import (a committed .csv becomes a translation with a UID) is
# included, and local ignored files are not. The real index and the stash are not touched.
#
# Both exports use the same import cache. Godot's GLB import is not byte-reproducible (two
# fresh imports of the same commit give imported .scn files that differ by a few bytes), so the
# base commit is imported once into a clean copy and the working tree's copy reuses that .godot.
# Every output file is compared by SHA-256 and every .pck entry by entry (tests/pck_diff.py).
set -u
cd "$(dirname "$0")/.."
FIRST="$(git log --diff-filter=A --format=%H -- desktop/desktop.gd | tail -1)"
BASE="${1:-${FIRST:+$FIRST^}}"
BASE="${BASE:-$(git merge-base HEAD master)}"
OUT=tests/results/web_export_unchanged.txt
W="$(mktemp -d /tmp/web_export_check.XXXXXX)"
mkdir -p "$W/base" "$W/new"
# blender/, renders/, evidence/ are .gdignore'd sources and recordings: not needed to export
git archive "$BASE" -- . ':!blender' ':!renders' ':!evidence' | tar -x -C "$W/base"
TREE="$(export GIT_INDEX_FILE="$W/index"; git read-tree HEAD && git add -A && git write-tree)"
git archive "$TREE" -- . ':!blender' ':!renders' ':!evidence' | tar -x -C "$W/new"
export_web() {  # project dir -> $1.out/ (outside the project, so it is never imported)
	local n; n="$(basename "$1")"
	mkdir -p "$1.out"
	(cd "$1" && godot --headless --path . --import > "../$n.import.log" 2>&1 && if [ -f tools/export_web.sh ]; then
		bash tools/export_web.sh "$1.out" > "../$n.export.log" 2>&1
	else
		godot --headless --path . --export-release "Web" "$1.out/index.html" > "../$n.export.log" 2>&1
	fi)
	echo "export $n: exit $?"
	(cd "$1.out" && find . -type f | sort | xargs sha256sum > "../$n.sums.txt")
}
export_web "$W/base"
cp -a "$W/base/.godot" "$W/new/.godot"
export_web "$W/new"
{
	echo "web export: base $(git rev-parse --short "$BASE") vs working tree of $(git rev-parse --short HEAD) ($(git status --short | wc -l) changed paths), same import cache"
	echo "--- files (sha256)"
	join -a1 -a2 -e MISSING -o 0,1.2,2.2 <(awk '{print $2, $1}' "$W/base.sums.txt" | sort) <(awk '{print $2, $1}' "$W/new.sums.txt" | sort) |
		awk '{printf "%-30s %s  %s\n", substr($1, 3), ($2 == $3 ? "identical" : "DIFFERENT"), substr($2, 1, 16)}'
	echo "--- pck entries"
	pck=0
	for p in $(cd "$W/base.out" && find . -name '*.pck' | sort); do
		python3 tests/pck_diff.py "$W/base.out/$p" "$W/new.out/$p" || pck=1
	done
	if diff -q "$W/base.sums.txt" "$W/new.sums.txt" > /dev/null && [ $pck -eq 0 ]; then
		echo "RESULT: PASS - the web export is byte-for-byte identical"
	else
		echo "RESULT: FAIL - the web export differs"
	fi
} | tee "$OUT"
grep -q "RESULT: PASS" "$OUT" && rm -rf "$W"
grep -q "RESULT: PASS" "$OUT"
