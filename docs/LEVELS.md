# Making a level

This is the pipeline every level after the Warehouse is made with. Eastside Baths
(`levels/baths/`) was built this way, and the timed dry run in
`evidence/level3_dry_run/` makes a third level ("Harbour Yard") from the scaffold. Follow the
steps in order. The checklist at the end is the quality bar a level has to meet before it
ships.

A level is:

| What | Where | Made by |
|---|---|---|
| The level definition: game data, test data, build data | `levels/<id>/level.json` | you (the scaffold starts it) |
| Its two-minute autopilot route | `levels/<id>/autopilot_route.gd` | you (the scaffold starts it) |
| Optional custom feature types | `levels/<id>/features.py` (`def f_<type>(L, spec)`) | you |
| Its entry in the level list | `levels/registry.json` | the scaffold |
| The GLB, the data JSON for the game, the baked lightmap | `assets/levels/<id>/` | `blender/build_all.py` (the level kit) |
| The Godot import settings of its textures | `assets/levels/<id>/*.import` | `tools/level_imports.py` |
| Renders: hero still, contact sheet, turntable | `renders/<id>.png`, `_sheet.png`, `_turntable.mp4` | `blender/build_all.py` |
| Its web download | `build/web/levels/<id>.pck` | `tools/export_web.sh` |

Nothing in the game's code names a level. `LevelRegistry` (`scripts/level/level_registry.gd`)
lists the levels from `levels/registry.json`, the level select shows one card per level with
its goals, and `scripts/level/level.gd` loads a level's GLB and data by id when it is chosen.
The Warehouse stays the default and is still built by `blender/park.py`. It has a
`levels/warehouse/level.json` for its game data only.

## 1. Quick start

```bash
python3 blender/levelkit/scaffold.py yard "Harbour Yard" --blurb "A dockside shed with a halfpipe."
~/.local/bin/blender --background --python blender/build_all.py -- --only yard          # ~80 s with the bake
godot --headless --path . --import && python3 tools/level_imports.py yard && godot --headless --path . --import
godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level=yard       # ~20 s
godot --path . -- --level=yard                                                        # play it (or Tab on the start screen)
```

The scaffold writes a small but complete starter park: a 30 x 40 m hall, a drop-in, a halfpipe,
a kicker, a funbox with a rail, a flat rail, a ledge, three knock-over signs, a storeroom behind
a breakable grille with the tape in it, S-K-A-T-E, a gap, lights and graffiti. It also
registers the level. The first build, import and test all work straight away: in the dry run
the suite passed 36 of 38 checks on a level nobody had touched. The two failures are the
autopilot route, because the starter route only does halfpipe airs. Everything after that is
design work: move, replace and add features in `level.json`, rebuild, and extend the route
until the suite passes.

`-- --fast --only yard` builds with a quick 1024 px, 48-sample bake, for looking at layout
changes. Do a full build before you commit.

## 2. Coordinates and units

- Metres, everywhere.
- **In `level.json`, both `build` and `test` use Blender coordinates:** x east, y north, z up.
  `facing` is degrees about z, with 0 facing +y (north) and 90 facing -x.
- **In the game, the data JSON and `autopilot_route.gd` use Godot coordinates:** x east, y up,
  -z north. Blender (x, y, z) is Godot (x, z, -y). The kit converts everything it writes to the
  data JSON.
- Real-world sizes that play well with the skater's physics (1.8 m tall, pushes to about
  8 m/s, pumps to about 12 m/s):
  - quarterpipes and halfpipes: 1.8–3.2 m high, radius 2.4–2.9 m (radius < height gives a
    vertical top: vert airs)
  - kickers: 0.5–0.65 m high, 1.6–1.8 m long
  - rails: 0.4–0.5 m high
  - ledges: 0.4–0.5 m
  - doorways: at least 1.5 m wide and 2.2 m high
  - pools: 1.7–3.2 m deep
  - bleacher steps: 0.6 m rise, 0.85 m tread

## 3. The level definition (`levels/<id>/level.json`)

```jsonc
{
 "id": "yard", "format": 1,
 "game":  { ... },   // read by the game (LevelRegistry, level.gd, main.gd, the level select)
 "test":  { ... },   // read by tests/test_level.gd, tests/frames.gd, tests/level_shots.gd
 "build": { ... }    // read by the level kit (blender/levelkit/level.py)
}
```

### `game`

| Key | Meaning |
|---|---|
| `name`, `blurb` | shown on the level select card and the start screen |
| `assets` | `glb`, `data`, `lightmap`: `res://assets/levels/<id>/...` |
| `pack` | the web download, relative to `index.html` (`levels/<id>.pck`); `""` means it ships in `index.pck` |
| `run_time` | 120: every level is one two-minute run |
| `cleared` | the end-screen title when every goal is done |
| `autopilot` | `res://levels/<id>/autopilot_route.gd` |
| `goals` | see below; the order is the order on the HUD and the card |
| `environment` | `ambient_color`, `ambient_energy`, `fog_color`, `fog_density`, `sun_color`, `sun_energy`, `exposure`; the rest of the look (SSAO, glow, tone mapping, the park shader) is shared |

Goal types (THPS style: one high score, the letters, the tape, and at least two of the level's own):

| `type` | Keys | Done when |
|---|---|---|
| `score` | `target` | the run's score reaches the target |
| `letters` | | S-K-A-T-E are all collected (`build.letters`) |
| `tape` | | the secret tape is collected (`build.tape`) |
| `break` | `group`, `count` | `count` breakables of that `group` are broken |
| `grind` | `rails` (grind line names), `time` (s) | one grind on one of those lines lasts `time` |
| `gap` | `gap` (a `build.gaps` id) | the gap is hit (take off in `from`, land in `to`, same air) |

The Warehouse's `rafters` and `windows` goals are specific to that level.

### `build`

| Key | Meaning |
|---|---|
| `builder` | `"levelkit"` |
| `material_prefix`, `object_prefix` | e.g. `"yard_"`, `"Yard_"`: material and object names in the GLB |
| `materials` | name → PBR texture set from a photo source (see below) |
| `special_materials` | emissive (`lamp`, `skylight`, `frosted`, ...) and glass; `game_boost` brightens them in the game |
| `shading` | per material, in the game: `metallic`, `normal_depth` |
| `lights` | `sun` (dir, color, strength, angle), `sky` (color, strength), `lm_scale`, `areas` [{name, at, size, energy, color, rot}], `points` [...] |
| `lightmap` | `margin`, `weights` (per material: UV2 texel density), `breakable_weight` |
| `graffiti` | the signage and graffiti atlas: `cells` (rects in the atlas), `pieces` (what each cell holds), `placements` (where on the walls and floors) |
| `decals` | more atlases the same way (the Baths' grime: stains, a drain ring, rust streaks, leaves) |
| `features` | the layout: a list of `{"type": ..., ...}` (see §4) |
| `spawn` | `{at, dir}`: where a run starts |
| `respawns` | where a bail can put the skater back |
| `hall_centre` | the middle of the open floor (the camera's grind-side pick) |
| `letters` | `[{letter, at}]`, five of them |
| `tape` | `{at}` |
| `gaps` | `[{id, name, points, from: [lo, hi], to: [lo, hi]}]` (boxes) |
| `render` | the hero render: `target`, `dist`, `elev`, `az`, `lens`, `cut_z` (cut away above this height to see in), `samples` |

### `test`

| Key | Meaning |
|---|---|
| `scale` | raycast measurements against the design: `{what, down: [x, y], expect: [lo, hi], surface?}` (height of the first surface below), `{what, up: [x, y, z], expect}` (ceiling), `{what, width: [x, y, z], axis: [dx, dy, dz], expect}` (wall-to-wall distance), `{what, steps: {from, to, n, count}, expect}` (stair risers), `{what, mesh_top: "<Mesh>", expect}` (a mesh with no collision) |
| `rides` | the real skater on your transitions: `{what, at, dir, speed, frames, hold?: ["up"], expect: {air, rev, air_above, top_above, wood_above, below, end_below, end_above, end_in, far, steep, surface, no_bail}}` |
| `pump` | `{what, at, axis, speed, seconds}`: a transition pair to pump across (it has to gain height; not pumping has to lose it) |
| `segments` | name → [from, to] seconds of the autopilot run, for `tests/frames.gd --segment=<name>` |
| `shots` | `{name, at, dir}`: in-game stills (`tests/level_shots.gd`) |

## 4. Feature types (the level kit)

The generators live in `blender/levelkit/`:
- `geo.py`: ramps, bowls, stairs, rails, walls, roofs
- `materials.py`: texture sets
- `lighting.py`: lights and the two-pass Cycles bake
- `breakables.py`: grilles, boarded walls, signs
- `props.py`: lamps, chairs, ladders, clock, boilers
- `level.py`: reads the definition and runs the build

The Warehouse's `park.py` uses the same `geo`, `materials` and `lighting` modules.

Keys marked `*` are required.

| `type` | Keys | Makes |
|---|---|---|
| `hall` | `rect*` [x0,y0,x1,y1], `height*`, `bands*` [[z0, z1, mat]], `openings` {side: [{kind: window\|door, x\|y, z}]}, `pilasters`, `roof` {type: flat\|vault, rise, lantern, ...}, `floor` {mat, col, holes} | the building: walls in bands, windows with frames, glazing and sills, doorways, a flat or vaulted roof (with collision), the floor round every hole |
| `room` | `rect*`, `height*`, `door` {side, x\|y, z}, `bands`, `floor_mat`, `ceiling_mat`, `label`, `hidden` (default true) | a room against the hall; a hidden area in the data |
| `quarterpipe` | `at*`, `facing*`, `width*`, `radius*`, `height*`, `deck`, `coping` (grind line name) | a quarterpipe with deck, coping and back wall |
| `halfpipe` | `center*`, `axis*`, `width*`, `radius*`, `height*`, `deck`, `flat`, `coping_a`, `coping_b` | a halfpipe (and its vert zone, the THPS auto-align) |
| `spine` | `center*`, `axis*`, `width*`, `radius*`, `height*`, `coping` | two quarters back to back |
| `bank` | `at*`, `facing*`, `width*`, `height*`, `angle`, `fillet`, `round_top`, `edge_rail` | a bank with a curved foot and a rounded top |
| `kicker` | `at*`, `facing*`, `width*`, `length*`, `height*` | a launch ramp with a steel lip |
| `funbox` | `center*`, `top*` [w, l], `height*`, `bank*`, `edge_rails`, `rail` {a, b, height, name} | a four-sided funbox, grindable edges, a rail on top |
| `bowl` | `rect*`, `corner*`, `radius*` (number or [[y, r], ...] along the length), `depth*` [[y, d], ...], `margin`, `ring_w`, `materials`, `coping` {side: name}, `lanes`, `vert_zones` | a pool: tiled walls and floor, a band, lane lines, a coping ring, deck (it cuts its own hole in the floor) |
| `rail` | `points*`, `height`, `name`, `tag` | a round rail on posts |
| `ledge` | `a*`, `b*`, `width`, `height`, `name` | a concrete ledge with a steel edge (grindable both edges) |
| `bench` | `a*`, `b*`, `height`, `depth` | a bench (grindable) |
| `stairs` | `at*`, `facing*`, `width*`, `n*`, `rise*`, `tread*`, `ledges` [step numbers], `handrails` [{x, name, height}] | stairs or bleachers, grindable nosings and handrails |
| `bridge` | `a*`, `b*`, `z*`, `width`, `thick`, `rails` {left, right}, `rail_height`, `posts` | a raised walkway or gantry with handrails |
| `box`, `cylinder`, `beam`, `quad`, `strip` | shapes (`edge_rails` on boxes make ledges) | plinths, walls, beams, painted lines |
| `pipe` | `points*`, `r`, `wall_side`, `name`, `tag` | a pipe run on brackets (grindable when named) |
| `crates`, `barrels`, `boiler`, `lifeguard_chair`, `ladder`, `clock`, `bunting`, `lamps` | see `level.py` | props; `lamps` hang globes and add their light to the bake |
| `grille` | `name*`, `group`, `label`, `plane` x\|y, `at*`, `span*`, `z*`, `spacing`, `points` | a steel grille that closes a doorway, smashed at speed (kind `impact`) |
| `boards` | as `grille` | a boarded-up opening (kind `impact`) |
| `sign` | `at*`, `facing`, `group`, `cell` (graffiti cell for its face), `height` | a sign on a post, knocked over (kind `touch`) |

A new kind of feature can live in the level without touching the kit: put
`def f_mything(L, spec)` in `levels/<id>/features.py` and use `{"type": "mything"}`. `L.B` is
the geometry builder (`quad`, `box`, `cylinder`, `strip`), and `L.add_rail(points, kind, tag, name)`
adds a grind line. If it would be useful in other levels, move it into the kit.

### Materials and textures

Each material is `{src, tile, tint?, desat?, flat?, flat_mix?, rough: [lo, hi], normal, metallic?, rough_invert?, texture_px?}`.
`src` is a photo source in `blender/textures_src/`. The kit derives the albedo, roughness and
normal maps from it at 1024 px. `texture_px` (256, 512 or 1024; default 512) is the size the
game loads it at, set by `tools/level_imports.py`: 1024 for the big walls, floors and ramp
surfaces the camera sees up close, 256 for small props (rails, flags, grilles), as the
Warehouse does. A shared normal map takes the largest size of its materials. It is the main
lever on the level's web download (the Baths pack went from 61 to 38 MB when its textures were
sized this way instead of all at 1024). Reuse the sources that are there (concrete, brick, plywood,
diamond plate, painted steel, crate wood, pool tile, glazed wall tile, plaster, terrazzo,
cotton) before making a new one. New sources can only come from the shared image tool, within
the project's image budget (30 in total; `imagegen-log.jsonl` counts them). No downloaded
textures, models, HDRIs or sounds.

### Graffiti, signage, grime

`graffiti.pieces` styles are:
- `sign` (a painted panel with text)
- `piece` (a two-tone graffiti piece with a 3D block)
- `banner`
- `throwup`
- `stencil`
- `tag`
- `smiley`

`decals` add the grime styles `stain`, `ring`, `streaks` and `leaves`. All of them are drawn in Python
(`blender/graffiti.py`), with no images. A placement is
`[cell, [x, y, z], [normal], width, rotation]` on a wall, or
`{floor: true, key, at, up, width}` on the floor. Put wall pieces 1.5 cm off the wall.

## 5. Lighting and the bake

The bake is Cycles, two passes: every light, then the sun's bounce. It writes
`<id>_lightmap.png` (2048 px, 200 samples; about 2 minutes for the Baths, 1 minute for the starter park). The GLB carries UV2
for every lightmapped mesh, and the game's park shader multiplies the albedo by the lightmap
on UV2. The real-time sun, SSAO, glow and ACES tone mapping are added on top.
- Put an area light behind every window (energy 450–700, warm or cool) and one or more in the
  roof. Emissive materials alone don't light a bake enough.
- `lamps` add a point light per globe.
- Faces pointing at a wall 5 m away get almost no light. In the dry run the suite caught two
  signs baked nearly black; turn them to face the room.
- `lightmap.weights`: give small, detailed or grindable things more texels (coping, rails:
  2.0) and big dull ones fewer (roof: 0.3).

## 6. Breakables, hidden areas, pickups, gaps

- An `impact` breakable (a grille, boards) is a collision box. The skater smashes through it
  above 3.5 m/s. A `touch` breakable (a sign) has no collision and is knocked over when ridden
  through. `group` is what `break` goals count.
- A `room` is a hidden area. Put the tape in it and close its door with an `impact`
  breakable, the THPS way.
- Letters and the tape float where an air or a grind will pass through them. The suite checks
  that each one is in open space above solid ground, and that the route collects it.
- Gaps: `from` is the take-off box and `to` is the landing box. The game names and scores
  the gap on landing.

## 7. The autopilot route (`levels/<id>/autopilot_route.gd`)

`route()` returns a list of steps, played through the same input interface as a player. It
never moves the skater directly. The helpers are in `scripts/game/autopilot_route.gd`:
- `R.go(point, note, {radius, max_speed, timeout})` steers to a point (Godot coordinates).
- `R.until(cond, note, {steer, hold, stick, input, timeout})` holds inputs until
  `cond(ap)` (for example `R.in_air`, `R.on_ground`, `R.grinding`).
- `R.tap(actions, note, {tap_stick, tap_time})` presses buttons (a flip or grab in the air).
- `{"do": "halfpipe", "z", "airs": [...], "count", "timeout"}` pumps and does vert airs
  across a halfpipe or pool running along x at that z, with a scripted trick list per air.

Run it with `godot --headless --path . --fixed-fps 60 -- --level=<id> --autopilot=test --verbose`.
Every step, TIMEOUT, BAIL, letter, gap and goal is logged. At a fixed 60 fps a run is
deterministic, so change one step at a time. Tips from the Baths:
- Slow down before a transition you want to ride across (`max_speed` 5 into a halfpipe's mouth).
- Waypoints on the line the skater actually takes. The log shows where it went; a waypoint it
  passes 1.6 m away from times out.
- Leave room round kickers. A kicker's tall back is a wall; the Baths' boiler room needed a
  narrower kicker and a way round it.
- Finish with the halfpipe or pool step to the buzzer; it builds the high score.

## 8. Tests

| Command | What | Result file |
|---|---|---|
| `godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level=<id>` | the park suite: registry and level select, `test.scale`, rail and ledge heights, doorways, lightmap UVs and bake, every grind line on real geometry and grindable by the real skater, every breakable breaks and resets, hidden areas closed then reachable, pickups in open space, `test.rides`, `test.pump`, and the level's own autopilot route collecting every pickup and completing every goal | `tests/results/level_<id>.txt` |
| `godot --headless --path . --fixed-fps 60 -- --level=<id> --autopilot=test --verbose` | the two-minute run on its own | `tests/results/fullrun_<id>.txt` (written by `run_all.sh`) |
| `godot --path . --fixed-fps 60 --resolution 1920x1080 -s tests/frames.gd -- --level=<id> --autopilot=run --segment=all --every=6` | camera, frame by frame over the whole run: pops, near-plane clipping, the camera outside the level (past a wall or the roof), the skater hidden | `/tmp/skate-work/frames/<id>_all/report.json`; `python3 tests/frames_sheet.py DIR --flagged` |
| `godot --path . --resolution 1920x1080 -s tests/level_shots.gd -- --level=<id>` | in-game stills at `test.shots` | PNGs |
| `bash tests/run_all.sh` | every suite, including the park suite and the autopilot run of every kit-built level in the registry | `tests/results/` |

To fix a flagged frame, read `camdbg` in `frames.jsonl` around it: the arm's wanted length,
what blocks it, the swing, lift and glide. Shared camera rules belong in
`scripts/game/chase_camera.gd`, and must keep the Warehouse's camera suite
(`tests/test_camera_run.gd`) passing.

## 9. Parity, web, renders

- **Live vs headless:** run the level's build in the live Blender window (the MCP) into a
  scratch assets folder, then
  `python3 tests/glb_manifest.py --check <live>/levels/<id> assets/levels/<id>`. The GLB and
  data JSON must be byte-identical. The lightmap may differ only by GPU path-tracing noise
  (4/255 on up to 0.2 % of texels).
- **Web:** `tools/export_web.sh` runs the Web export, whose preset leaves out
  `assets/levels/*`, then `tools/pack_level.gd` for every level with a `pack`. The first time
  a player picks the level, the game downloads `levels/<id>.pck` next to `index.html` and
  mounts it. Deploy the whole `build/web/` folder.
- **Renders:** `blender --background --python blender/build_all.py -- --only <id>_renders`:
  a 1920x1080 hero still, an 8-view contact sheet and a 24-frame turntable, lit by the bake's
  own lights.

## 10. Quality gates (the checklist)

A level ships when every box is ticked, with the evidence saved:

- [ ] `levels/<id>/level.json` names the level, has a blurb, a `score` goal and at least two goals of its own, on a 120 s run
- [ ] `blender/build_all.py -- --only <id>` builds it headless (full bake); a second build gives a byte-identical GLB
- [ ] Real-world scale: every `test.scale` measurement is inside its design range; rails 0.25–1.25 m, ledges are edges, doorways at least 1.5 x 2.2 m
- [ ] Lightmap: every lightmapped mesh has UV2 in [0,1]; the bake has light everywhere a surface samples it; the only unlightmapped meshes are emissive or glass
- [ ] PBR materials from the project's own texture sources; the level's own graffiti or signage
- [ ] Varied transitions (quarterpipes, and a halfpipe or bowl), rails, ledges and gaps; every grind line grindable by the real skater
- [ ] Something breakable (it breaks, and `reset_run` restores it) and a hidden area (closed until broken into, then reachable)
- [ ] S-K-A-T-E and a secret tape, each in open space; the route collects every one
- [ ] `tests/test_level.gd -- --level=<id>`: 0 failed (`tests/results/level_<id>.txt`)
- [ ] The autopilot two-minute run completes every goal (`tests/results/fullrun_<id>.txt`)
- [ ] `tests/frames.gd --segment=all`: 0 flagged frames, or every flagged frame explained and fixed; look at the contact sheet too (a detector can't see what has no collision)
- [ ] Handling spot checks in `test.rides` / `test.pump`: air out of the halfpipe or bowl and back in, pumping gains height
- [ ] `tests/run_all.sh`: every suite passes, including the Warehouse's (the camera and handling code are shared)
- [ ] Live-vs-headless manifest check passes
- [ ] Web: `tools/export_web.sh`; in a browser, the level select shows the level, choosing it downloads its pack and it plays; a 1080p frame-time sample holds 60 fps
- [ ] Renders in `renders/`; in-game shots in `evidence/`; the README's level list updated

## 11. Friction met so far (and what was done about it)

| Where | Friction | Now |
|---|---|---|
| Baths: the pool's shallow end | a constant transition radius made the shallow end's walls too mellow to air out of and back in | `radius` can vary along the pool: mellow shallow end for transfers, vert in the deep end |
| Baths: the boiler room | the kicker inside the door left no way back out; the autopilot stuck behind it | a narrower kicker, a longer room, and the route goes round it |
| Baths: camera on vertical pool walls | the arm started touching the tiles and collapsed; dropping in over the lip hid the skater | the camera eases off steep walls, cranes up over a lip, glides instead of jumping, and ignores thin rail tubes |
| Baths: camera through the roof | the roof had no collision, so neither the camera nor the frame detectors saw it | kit roofs have collision; `frames.gd` flags a camera outside the level's volume |
| Dry run: starter signs | two faced walls and baked nearly black (the suite caught it) | they face the room; brighter starter lighting |
| Dry run: starter route | ran into the halfpipe at 10 m/s and bailed | slows into the mouth |
| Baths: web download | every texture was imported at 1024 px, so the level's pack was 61 MB, over twice the Warehouse's texture weight | `texture_px` per material (1024 / 512 / 256, like the Warehouse): 38 MB |
| Tests | `preload()` of the autopilot in a `-s` script compiles `skater.gd` before the `Sfx` autoload exists | the suite `load()`s it at run time |
