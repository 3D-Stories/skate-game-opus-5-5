# New level and level pipeline: report

Branch `new-level`, worktree `skate-game-opus-5-5/.worktrees/new-level`. 2026-09-26.

## What was built

**Eastside Baths**, a second park designed for this game: a drained 1930s municipal pool hall
the locals took over. It is not a THPS level (the idea came from vert skating's drained-pool
roots and the look of old municipal baths; no THPS map was referenced). Real scale: hall
32 x 48 m under a 12.5 m vaulted roof with a glazed lantern; a 25 x 12 m pool (1.7 m shallow
end, 3.2 m deep end) whose tiled walls reach vertical at the coping; north (3.0 m) and east
(2.4 m) quarterpipes; a bank laid over the bleachers from a 4.2 m concourse drop-in; the 4.2 m
high board over the deep end; two kickers, a funbox with a rail, a flat rail, handrails and
ledges; five knock-over "No Diving" signs; a boiler room behind a breakable grille (the hidden
area, with the tape and a 1.8 m quarterpipe); S-K-A-T-E; five named gaps; its own graffiti,
pool signage, depth markings and grime decals (all drawn in code); PBR materials from four new
photo sources (pool mosaic, glazed wall tile, peeling plaster, terrazzo) plus the project's
existing ones; lightmap UVs and a Cycles-baked lightmap with AO. Goals on the two-minute run:
high score 30,000; S-K-A-T-E; the secret tape; knock over 5 No Diving signs; grind the deep
end coping (1.2 s); take the High Dive (a gap off the high board into the pool).

**The level pipeline** (the main deliverable besides the level):

| Part | Where |
|---|---|
| Level kit: generator modules for common features (quarterpipe, halfpipe, bank, kicker, funbox, pool/bowl, rail, ledge, stairs/bleachers, pipes, roofs, breakables, props, pickups, lightmap and graffiti helpers) | `blender/levelkit/` (`geo.py`, `materials.py`, `lighting.py`, `level.py`, `props.py`, `breakables.py`) |
| Level definition format: layout, surfaces, materials, lights, goals, pickups, gaps, test data | `levels/<id>/level.json` (reference in `docs/LEVELS.md` section 3) |
| Scaffold command: a new level skeleton wired into `levels/registry.json`, `build_all.py` and the game | `python3 blender/levelkit/scaffold.py <id> "<Name>"` |
| Data-driven registration in Godot | `levels/registry.json` + `scripts/level/level_registry.gd` (`LevelRegistry`); `level.gd` loads any level by id; goals, run time, lighting and assets come from the level's JSON |
| Test template | `tests/test_level.gd -- --level=<id>` (park suite driven by the level's `test` data), `levels/<id>/autopilot_route.gd` (the two-minute route), `test.segments` in the level JSON for `tests/frames.gd` |
| Guide with the quality-gate checklist | `docs/LEVELS.md` |
| Level select on the start screen (keyboard and gamepad, shows each level's goals) | `scenes/level_select.tscn`, `scripts/ui/level_select.gd`; hook in `menus.gd` is one signal and one line of text |
| Web: a level is downloaded only when chosen | `tools/export_web.sh`, `tools/pack_level.gd`, Web preset excludes `assets/levels/*`, `LevelRegistry.fetch_pack` |
| Texture import settings for kit levels | `tools/level_imports.py` (per-material `texture_px`) |

The Warehouse's `park.py` was refactored onto the kit's shared modules (`park_geo.py` became
`levelkit/geo.py`; materials and bake helpers moved into `levelkit/materials.py` and
`lighting.py`). `park.glb` still rebuilds byte-identical (sha256 `62cfa112...506490`, checked
after every refactor step with the no-bake build and at the end, see Verification).

## How the level was made, and whether the process repeats

Eastside Baths was built through the kit from its `level.json` (no bespoke Blender script): the
kit grew the features it needed (pool with a variable transition radius, bank, bleachers,
vaulted roof, signs, grille, boiler room), and each became a reusable feature type.

Repeatability was then tested with a timed dry run of level 3 ("Harbour Yard") following only
`docs/LEVELS.md` (`evidence/level3_dry_run/`): scaffold + first full build with the bake 79 s,
Godot import 9 s, park suite 18 s; on the untouched starter level the suite passed 36 of 38
checks. The two failures are the autopilot route (the starter route only does halfpipe airs;
the route has to be written for each layout). Friction found by the dry run and by the Baths
(starter signs facing walls and baking black, a starter route that bailed into the halfpipe,
the camera through a roof without collision, a 61 MB web pack) was fixed in the kit and logged
in `docs/LEVELS.md` section 11. The dry-run level was removed from the registry afterwards.

## Verification

All commands run from the worktree root. Results are saved in `tests/results/`.

| Check | Command | Result |
|---|---|---|
| Every headless suite (the 11 existing ones plus the level select and the Baths) | `bash tests/run_all.sh` | PASS, all 14 exit 0 (`run_all.txt`): scoring 40/40, flow 24/24, input 178/178, audio 69/69, park 111/111, anims 53/53, clips 28/28, handling 48/48, ragdoll 75/75, camera 27/27, Warehouse full run all 5 goals at 69,043 points (the same score as before this branch), level select 19/19, Baths park suite 53/53, Baths full run all 6 goals at 58,951 |
| Baths park suite: scale (16 measurements against the design), lightmap UVs (41/41 surfaces in [0,1] with a lightmap material; the bake lights every one), every grind surface grindable (26/26 lines snap the real skater into a grind), breakables break (grille and 5 signs) and reset, the hidden area closed until broken into and then reachable, every pickup reachable (the route collects S-K-A-T-E and the tape) | `godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level=baths` | PASS 53/53 (`level_baths.txt`; the route log is `level_baths_route.txt`) |
| Autopilot two-minute run completes every goal | same suite, and `godot --headless --path . --fixed-fps 60 -- --level=baths --autopilot=test --verbose` | PASS: score, S-K-A-T-E, tape, 5 signs, deep-end coping grind, High Dive; 58,951 points in 121.0 s, no timeouts, bails or unsticks (`fullrun_baths.txt`) |
| Whole-run camera capture with `tests/frames.gd` | `godot --path . --fixed-fps 60 --resolution 1920x1080 -s tests/frames.gd -- --level=baths --autopilot=run --segment=all --every=6` | PASS: 7,201 frames measured, 0 flagged: camera never outside the level or inside geometry, skater never hidden, at most 0.375 m and 5.95 deg of camera movement per frame (`frames_baths_all.json`, sheet `evidence/baths/frames_whole_run_sheet.jpg`). The first capture flagged 208 frames (192 skater hidden, 36 pops, 23 near-plane, 4 behind the lip); each cause was fixed (camera on vertical pool walls, over the lip on drop-ins, roofs with collision), not waved through |
| Handling spot checks on the new transitions | in the park suite (`test.rides`, `test.pump`) | PASS: vert air out over the deep end's north coping and back in (1.21 m peak, walls 89.7 deg at the lip); shallow end pumped up the east wall and aired out onto the deck (2.65 m); carve wall to wall in the deep end; both quarterpipes, the bank, the kicker pool hop, the funbox and the boiler room quarter ridden; pumping the deep end's walls raises the peak pass after pass (2.04 to 3.95 m) while the same ride without pumping loses height (1.51 to 0.44 m) |
| Live-vs-headless build parity (same manifest method as the Warehouse) | live build in the shared Blender window from the worktree's modules (`seconds: 145.8`), then `python3 tests/glb_manifest.py --check <live>/levels/baths assets/levels/baths` | PASS: `baths.glb` (32,930,144 bytes) and `baths_data.json` byte-identical; `baths_lightmap.png` differs on 633 of 4,194,304 texels (0.015 %) by at most 1/255, GPU path-tracing noise (`manifest_baths_check.txt`, `manifest_baths_live.json`, `manifest_baths_headless.json`, `manifest_baths_diff.txt`) |
| The Warehouse is unchanged | no-bake rebuild of `park.glb` after each refactor step; the full rebuild below | PASS: `park.glb` sha256 `62cfa112...506490`, byte-identical to the committed file. The no-bake build leaves out the `lighting` block of `park_data.json` (written only during a bake), which is the same before and after this branch |
| Web build: level select and the new level in a browser | `tools/export_web.sh build/web`, serve `build/web`, `python3 tests/web_levels_check.py http://localhost:8797/ --level baths --run` | PASS 9/9 on the final build (`web_levels_localhost_8797.json`, screenshots `evidence/web_levels_localhost_8797_*.png`): boots to the Warehouse with no pack fetched; keyboard (Tab, Right, Enter) and an emulated Gamepad API pad (Select, D-pad, A) pick the Baths, its 37.6 MB pack downloads (8.3 s from localhost) and the level loads; runs start on it; `?level=baths&autopilot` completes every goal in the browser (58,951); no failed requests, no page or console errors. The Warehouse's own browser check (`tests/web_check.py ... --run`) on the same build: PASS 10/10 (`web_check_localhost_8797.json`): keyboard, gamepad, Web Audio, pause, and its two-minute run completes every goal at 70,615 points, the same score as the published live build |
| 1080p frame-time sample in Chrome | `tests/chrome_bench.sh "level=baths&autopilot&bench"` (with `BENCH_PORT`/`BENCH_OUT`/`BENCH_PROFILE`) | PASS: 174.4 fps average, p99 8.1 ms, 1 % low 105.7 fps, 3 frames over 16.7 ms in 120 s (details below) |
| Every asset rebuilds headless from scratch, including the Baths | `blender --background --python blender/build_all.py` in a clean copy of the worktree (no `blender/work`) | PASS: exit 0 in 865 s (14 min 26 s on the shared GPU): skater 98 s, park 227 s, Baths with its bake 167 s, renders 471 s including the Baths' (`build_all_rebuild_check.txt`). `board.glb`, `pickups.glb`, `skater.glb`, `park.glb`, `park_data.json`, `baths.glb` and `baths_data.json` byte-identical to the committed files; the lightmaps differ only by bake noise (park 0.029 % of texels, max 2/255; Baths 0.015 %, max 1/255) |
| Repeatability: level 3 through the pipeline | `docs/LEVELS.md` steps 1-8, timed | Done by me, 36/38 on the untouched scaffold (see above); `evidence/level3_dry_run/` |

## Web download size

The Web preset now leaves out `assets/levels/*`; each kit-built level is its own pack,
fetched and mounted the first time it is chosen (the browser check confirms no pack is
fetched at boot).

| | Before this branch | After |
|---|---|---|
| Boot download: `index.wasm` + `index.pck` + `index.js` | 88,236,750 B (43,341,911 gzipped) | 88,302,046 B (43,389,020 gzipped), +0.07 % |
| Eastside Baths pack `levels/baths.pck`, only when chosen | - | 37,615,348 B (26,999,891 gzipped) |

The Baths pack was 61.2 MB (48.0 MB gzipped) while every texture was imported at 1024 px;
sizing textures per material like the Warehouse (`texture_px`) brought it to 37.6 MB with no
visible difference (`evidence/baths/texture_sizes_before_after.jpg`).

## Performance (1080p, Chrome on Windows)

Desktop i9-12900KF, RTX 4080 (shared with the other workers), Chrome 153, WebGL 2 through
ANGLE on Direct3D 11, 1920 x 1080 page, vsync, full quality (4x MSAA, SSAO, glow, AgX, fog,
sun shadows, 3D scale 1.0), the scripted two-minute run.

| Run | Frames | Average | p95 | p99 | 1 % low | Over 16.7 ms | Worst frame |
|---|---|---|---|---|---|---|---|
| Eastside Baths | 21,099 | 174.4 fps | 7.1 ms | 8.1 ms | 105.7 fps | 3 | 70.6 ms (first sign knocked over) |
| Eastside Baths, first visit (empty browser cache) | 21,065 | 170.7 fps | 7.3 ms | 8.4 ms | 45.6 fps | 4 | 2,608 ms (first sign knocked over) |
| The Warehouse, this build | 20,792 | 173.3 fps | 7.2 ms | 8.1 ms | 104.8 fps | 5 | 57.4 ms |
| The Warehouse, before this branch (run alternately with the row above) | 20,892 | 174.1 fps | 7.1 ms | 8.0 ms | 106.3 fps | 3 | 55.8 ms |

Files: `tests/results/bench_levels_1080p.jsonl` (rows 1, 2, 6; rows 3 to 5 are Warehouse runs
disturbed by other GPU work on the shared machine or with a partly cold cache, kept for
honesty: 160.6, 142.6 and 170.5 fps), `bench_ab_warehouse_baseline.jsonl` (row 1 cold, row 2
warm). The Baths holds 60 fps with a wide margin on this desktop.

**A first-visit freeze, found and moved out of the run.** With an empty browser shader cache,
Chrome on Windows builds about 50 shader executables the first time the game runs unpaused:
an 18 to 22 s freeze. It landed in the first frame of the first run, for either level: I
reproduced it on the Warehouse by starting the run from a paused screen, which is what every
player's first run does. The Warehouse benchmark never paused, so it had hidden this. A
Chrome trace showed the renderer blocked on program links; a WebGL `linkProgram` log showed no
new GL programs at the run start, so it is ANGLE building Direct3D executables lazily. It is
not the skater, audio, shadows or post-processing (each ruled out by a cold run with it off).
`main.gd` now runs three frames unpaused behind the start or loading screen after a level
loads (web build only), and the freeze happens there, once per browser. Measurements:
`tests/results/bench_first_visit_investigation.jsonl`.

## NOT VERIFIED

- **That someone else can follow `docs/LEVELS.md` unaided.** The level-3 dry run was done by
  me, the author of the guide. A fresh agent or person making level 3 is the real test.
- **60 fps on a laptop or a weaker GPU.** Measured only on the shared RTX 4080 desktop. The
  game's existing adaptive quality (SSAO off, then MSAA 2x at 85 % scale, then 70 %) applies
  to the Baths as it does to the Warehouse, but I did not measure it there.
- **Browsers other than Chrome.** Firefox and Safari were not tested. The first-visit shader
  freeze was measured only in Chrome on Windows (ANGLE D3D11); other backends may differ.
- **A physical gamepad.** The level select was driven with Godot's joypad input in the
  headless suite and with an emulated Gamepad API pad in headless Chromium, not a real pad.
- **The live site.** Not deployed (the coordinator deploys after the merge), so the level
  select and the level pack on https://skate-game-opus-5-5-blush.vercel.app are untested.
  The pack must be deployed with the rest of `build/web/` (`build/web/levels/baths.pck`).
- **The Windows desktop build** (another worker's branch) with the new level: not built or
  run by me. `LevelRegistry` treats a level as available when its assets are in `res://`,
  so a desktop export that includes `assets/levels/` should work without packs, but I have
  not checked it.
- **The `jev_*` tools** named in the global CLAUDE.md are not connected in this session, so
  no jev screening, gate or verification ran.

## Known issues

- **First visit in Chrome on Windows:** the ~20 s shader build still happens once per
  browser, now while the start or loading screen is shown (that screen is frozen for it). It
  used to hit the first seconds of the first run. The first breakable of a run still costs one
  long frame on a first visit (2.6 s for the Baths' first sign, 2.2 s for the Warehouse's
  first window; about 60 ms once the browser has cached it).
- **Baths pack download:** 37.6 MB (27.0 MB gzipped) the first time the level is chosen; the
  level select shows progress. It took about 7 s from localhost; slower connections wait
  longer.
- **The scaffold's starter route** only does halfpipe airs, so a new level's suite fails its
  two route checks until the route is written for the layout (documented).
- **Benchmark noise on the shared machine:** two of the Warehouse runs in
  `bench_levels_1080p.jsonl` (rows 3 and 4) were slowed by other workers' GPU work; the A/B
  pair run back to back is the comparison to use.
- **Lightmap bakes are not bit-exact** between the live window and headless (0.015 % of texels,
  1/255), as for the Warehouse; the GLB and data are exact.

## Shared files touched

Modified (merge with care; all changes are additive or keep the Warehouse's behaviour):

- `scripts/ui/menus.gd`: the start-screen hook: a `level_select_pressed` signal (Tab /
  gamepad Select), the level's name in the title (still "PRO SKATER: THE WAREHOUSE" for the
  Warehouse), one hint line, and the level's "cleared" text on the end screen. 14 lines.
- `scripts/game/main.gd`: goals, run time and lighting from the level's data, the generic
  goal types (break, grind, gap), `switch_level()`, opening the level select, the web
  first-visit compile step, the startup level (`?level=` / `--level=`).
- `scripts/level/level.gd`: loads any registered level; kit-level materials, collision,
  breakables, gaps, vert zones; the Warehouse's paths unchanged.
- `scripts/skater/skater.gd` (12 lines: pool walls ride like ramps, breakable bodies passed to
  the level), `scripts/game/chase_camera.gd` (pools, high boards, lips, roofs),
  `scripts/game/autopilot.gd` (the level's route), `scripts/game/bench.gd` (long frames
  outside the run in the report).
- `blender/park.py`, `blender/bake.py`, `blender/graffiti.py`, `blender/renders.py`,
  `blender/build_all.py`; `blender/park_geo.py` moved to `blender/levelkit/geo.py`.
  `park.glb` is byte-identical.
- `export_presets.cfg` (the Web preset excludes `assets/levels/*`), `tests/run_all.sh` (the
  level select and every registered kit level's suite), `tests/frames.gd` (a level's
  segments; the outside-the-level detector), `tests/glb_manifest.py` (`--check`),
  `tests/chrome_bench.sh` (port / output / profile overrides), `imagegen-log.jsonl` (+4),
  `blender/textures_src/generate_sources.sh`, `README.md`, and refreshed results in
  `tests/results/` (camera, and the rerun suites).

New: `blender/levelkit/`, `levels/`, `assets/levels/baths/`, `scripts/level/level_registry.gd`,
`scripts/ui/level_select.gd`, `scenes/level_select.tscn`, `tests/test_level.gd`,
`tests/test_level_select.gd`, `tests/level_shots.gd`, `tests/web_levels_check.py`,
`tools/export_web.sh`, `tools/pack_level.gd`, `tools/level_imports.py`, `docs/LEVELS.md`,
this report, `renders/baths*`, `evidence/baths/`, `evidence/level3_dry_run/`.

Note for the character-builder merge: both branches add start-screen UI. Mine adds only
the signal and one text line in `menus.gd`; the level select is its own scene.

## Commits

FILL
