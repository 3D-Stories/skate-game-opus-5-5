# Pro Skater: The Warehouse

**Play it live: FILL:LIVE_URL**

A Tony Hawk's Pro Skater-style skateboarding game in Godot 4.7.2 (GDScript, Compatibility
renderer, web export), set in an original homage to the THPS1 Warehouse. Every 3D asset -
the skater, the board, the whole park and every prop - is built by Python scripts in
Blender 5.2 (`blender/`), exported as GLB (`assets/`) and loaded by the game. All sound is
synthesised in GDScript at startup.

| Face portrait (Cycles) | Skater mid-kickflip | The Warehouse |
|---|---|---|
| ![portrait](renders/skater_portrait.png) | ![trick](renders/skater_trick.png) | ![park](renders/park.png) |

Gameplay (recorded two-minute run, every goal completed): `evidence/two_minute_run.mp4`.

## Commands

| What | Command (run from the project root) |
|---|---|
| Rebuild every 3D asset + renders, headless | `blender --background --python blender/build_all.py` |
| Export the web build (Thread Support off) | `mkdir -p build/web && godot --headless --path . --export-release "Web" build/web/index.html` |
| Serve it locally | `python3 -m http.server 8765 --directory build/web` then open http://localhost:8765/ |
| Deploy (Vercel) | `npx vercel link --yes --project skate-game-opus-5-5 --cwd build/web` then `npx vercel deploy --prod --yes --cwd build/web` |
| Run every test headless (11 suites, FILL:RUNALL_TIME) | `bash tests/run_all.sh` (results in `tests/results/`) |
| Frame-by-frame check of the run | `godot --path . --fixed-fps 60 --resolution 1920x1080 -s tests/frames.gd -- --autopilot=run --segment=windows` (segments: `start`, `rafter`, `wall_tape`, `windows`, `funbox`, `halfpipe`, `end`, or `all --every=6` for the whole run in about 4 minutes); then `python3 tests/frames_sheet.py /tmp/skate-work/frames/windows --flagged` for contact sheets |

The rebuild takes about 8 minutes on an RTX 4080 (assets about 3 minutes, Cycles renders the
rest). `-- --fast` makes a quick low-quality pass; `-- --only board,park` rebuilds a subset.
The web build needs no special headers (single-threaded), and every path in it is relative.
It uses a Godot 4.7.2 web template rebuilt from the 4.7.2-stable source with one small
Compatibility-renderer patch (`engine/patches/`: SSAO no longer triggers an unused mid-frame
depth copy, which cost about 3.4 ms a frame with 4x MSAA in Chrome on Windows);
`engine/build_web_template.sh` rebuilds it, and the Web preset points at
`engine/godot-4.7.2-web_nothreads_release-patched.zip`.
URL options: `?fps` shows an FPS counter, `?autopilot` plays the scripted two-minute run,
`?bench` records frame-time statistics for the run (`?quality=full` disables adaptive quality).

## Controls

Shown on the start screen and in the pause menu.

| Action | Keyboard | Gamepad |
|---|---|---|
| Steer / push (Up) / brake (Down) | W A S D or arrow keys | Left stick or D-pad |
| Ollie (hold to crouch, release to pop) | Space | A / Cross |
| Flip trick + direction | J | X / Square |
| Grab trick + direction (hold) | K | B / Circle |
| Grind (rail, ledge, coping, pipe, rafter) + direction | L | Y / Triangle |
| Spin in the air | Left / Right, Q / E | Left stick, LB / RB |
| Manual / Nose manual | Up, Down / Down, Up | Up, Down / Down, Up |
| Special trick (special meter full) | Left, Right + J | Left, Right + X |
| Pause / Restart run | Esc or P / R | Start / Back |

The gamepad works through Godot's joypad input (the browser Gamepad API in the web build).

## Tricks and scoring (THPS rules)

| Trick | Points | Input |
|---|---|---|
| Kickflip | 100 | Flip + Left (or no direction) |
| Heelflip | 100 | Flip + Right |
| Pop Shove-It | 100 | Flip + Down |
| 360 Flip | 500 | Flip + Up |
| Indy | 200 + 120/s held | Grab + Right (or no direction) |
| Melon | 200 + 120/s held | Grab + Left |
| Nosegrab | 250 + 120/s held | Grab + Up |
| Tailgrab | 250 + 120/s held | Grab + Down |
| 50-50 | 100 + 150/s | Grind near a rail, ledge, coping, pipe or rafter |
| Boardslide | 150 + 150/s | Grind + Left/Right |
| Manual | 100 + 120/s | Up, Down |
| Nose Manual | 150 + 120/s | Down, Up |
| Spins | 180: 100, 360: 250, 540: 500, 720: 800, 900: 1200, 1080: 1600 | Left/Right or spin buttons in the air |
| **Tiger Claw Tre** (special) | 3000 | Special meter full: Left, Right + Flip |

- **Combo score = (sum of the tricks' points) x (number of tricks in the combo).** Grinds,
  manuals and held grabs keep earning while held. Manuals link air tricks and grinds into
  one combo.
- Repeating a trick inside one combo is worth less: 100%, 75%, 50%, 25%, then 10%.
- Landing banks the combo. Bailing (landing sideways, off balance, losing a grind or manual
  balance, hitting the ground mid-trick, landing still holding a grab) loses it and empties
  the special meter. The skater goes limp as a ragdoll, then gets up and rides on.
- Landed combos fill the special meter; when it is full the special trick unlocks. The Tiger
  Claw Tre is an original special: a double 360 flip under a spread-eagle pose, caught into
  a tweaked indy, authored in `blender/anims.py` like every other clip.
- The combo string and "points X multiplier" show at the bottom of the screen, THPS style.

## The two-minute run and goals

A 2:00 timer and five goals, listed at the top right of the HUD, on the start and pause
screens, and on the end-of-run screen:

1. High score: 25,000
2. Collect S-K-A-T-E (five letters hidden around the park)
3. Find the secret tape (in the hidden room behind the boarded-up wall)
4. Grind the rafters (from the catwalk kicker onto the yellow rafter beam)
5. Break the 5 windows (vert airs off the east quarterpipe, or grinding the wall pipe under them)

## What each Blender script builds

`blender/build_all.py` runs them in this order. The same modules were run in the live
Blender window (through the Blender MCP) while developing; `tests/glb_manifest.py` proves
the live and headless builds are the same assets (see Evidence).

| Script | Builds |
|---|---|
| `lib/common.py` | Shared helpers: scene/collection utilities, Cycles GPU setup, baking, image I/O, procedural noise, seamless tiling, height-to-normal, PBR materials, glTF export. |
| `pickups.py` | `assets/pickups.glb`: the S-K-A-T-E letters (bevelled gold text) and a modelled VHS secret tape with a procedural label. |
| `board.py` | `assets/board.glb`: 80 x 20.3 cm 7-ply deck with kicked nose/tail and concave, griptape (photo source), original tiger graphic, ply edges, bolts, aluminium trucks with bushings and kingpins, 53 mm wheels with bearings; each wheel is a separate spinnable object. |
| `skater.py` | Runs the character stages below in order. |
| `skater_body.py` | Stage 1: the human from MPFB2 (MakeHuman, CC0) - body macros and 48 face/body targets for an original, lean face - baked into the mesh, the `game_engine` skeleton fitted, one subdivision, helper geometry split out. |
| `skater_face.py` | Stage 2: eyeballs (iris from a photo source, procedural sclera, veins, limbal ring) seated under the lid openings with a level gaze, corneas, eyelash and eyebrow hair cards, teeth, tongue. |
| `skater_skin.py` | Stage 3: physically based skin. Region masks (lips, redness, stubble, brows, scalp, nails, under-eye), a Cycles bake of position/normal/masks into the UV layout, pores projected in 3D from a skin macro photo, and a photographic face: an original generated face photo projected onto the head with a 27-landmark thin-plate-spline warp and colour-matched to the body. Random-walk subsurface scattering in the render material; the game shader fakes it with wrapped, red-shifted diffuse. |
| `skater_clothes.py` | Stage 4: a fleece hoodie with hood, ribbed cuffs and drawstrings, loose denim jeans, suede skate shoes with laces, soles and tongues. Garments are cut from the body so they carry its skin weights; folds are sculpted procedurally; a fabric UV set tiles the photo sources at real scale; a layering pass keeps the hoodie hem over the jeans; colour, folds, seams, wear and AO are baked per garment. |
| `skater_hair.py` | Stage 5: a textured-crop haircut from ~2,200 layered hair cards grown on the scalp along a styled flow field, with a procedural strand-clump atlas. |
| `anims.py` | A control rig (foot and hand IK, knee and elbow poles) drives the skeleton; 25 clips authored as Python keyframes: idle, push, ride, ride fakie, crouch, ollie, kickflip, heelflip, pop shove-it, 360 flip, indy, melon, nosegrab, tailgrab, 50-50, boardslide, manual, nose manual, vert air, air, land, bail, two getups (from the back, and from face down: push-up, knees in, lunge, stand) and the special. The board is its own animated bone; the feet are solved onto the deck every frame. Exports `assets/skater.glb`. |
| `park_geo.py` | Geometry builders: ramps with true circular transitions and coping, boxes, rails, I-beams, pipes. |
| `graffiti.py` | Twelve original graffiti pieces drawn in code (text curves, outlines, block shadows, drips, overspray, wear) into one atlas, placed as decals. |
| `bake.py` | Lighting: a warm low sun through the skylights and windows, sky light, 32 hanging fluorescent fixtures, skylight glow, the secret-room lamp; a Cycles lightmap bake (indirect sun + all other light) into `assets/park_lightmap.png`. The game renders the sun in real time with shadows. |
| `park.py` | `assets/park.glb` + `assets/park_data.json`: the Warehouse at real scale (hall 40 x 66 m, 11.5 m roof) - start deck (5 m) with the steep drop-in, halfpipe (3.7 m), a 3.2 m quarterpipe along the east wall under five breakable windows, a 2.4 m corner quarter, funbox with top rail, two kickers, an 18 m rail, a diagonal rail, concrete ledges, the grindable wall pipe, high catwalks with a kicker onto the rafters, two grindable rafters, the boarded-up breakable wall and the secret room with its own rail, crates, barrels, pallets, dumpster, steel columns and trusses, ten skylights, graffiti, and a closed daylight shell outside the east windows (left out of the bake; the game draws the outside view on it); every visual mesh has a `Lightmap` UV set; collision is tagged by surface (wood, concrete, metal, wall). |
| `renders.py` | Cycles renders into `renders/`: face portrait, skater T-pose and mid-kickflip, board and park (high three-quarter cutaway), each as a hero still, an 8-view sheet and an MP4 turntable. |
| `dev_preview.py` | Development helper only (clip contact sheets); not part of the build. |

`blender/textures_src/` holds the photographic texture sources made with the shared image
tool (`generate_sources.sh` lists every prompt); the build only reads them.

**Image count (from `imagegen-log.jsonl`): 17 of the 30 allowed.** denim, hoodie fleece,
suede, skin pores, plywood, brick, griptape, concrete floor, crate wood, painted steel,
corrugated metal, diamond plate, cotton tee, cinder block, deck graphic, iris, face albedo.
No downloaded models, textures, HDRIs, rigs, animations or fonts; the only external generator
is MPFB2 for the base human.

## The game (GDScript)

| Script | Role |
|---|---|
| `scripts/game/main.gd` | Game flow: start screen, the two-minute run, goals, pause, end-of-run screen, restart; adaptive quality; benchmark statistics. |
| `scripts/skater/skater.gd` | Skater physics and tricks: surface-following ground movement with transition momentum and pumping, drop-ins, ollies, vert airs, flips/grabs/spins, grinds with a balance meter, manuals with a balance meter, ragdoll bails (impacts from the ragdoll's contacts: thuds, blood splats, slide smears) with a rigid-body board, sounds. |
| `scripts/skater/skater_model.gd` | The Blender skater and board: clip blending, board on its bone, wheel spin, and the ragdoll: 14 capsules with cone-twist joints (PhysicalBone3D). A bail blends the authored flinch into the physics; once the body lies still, the ragdoll is steered into the first pose of the matching getup clip (on the back or face down) and fades into it. |
| `scripts/game/tricks.gd`, `score_keeper.gd` | Trick table and THPS scoring (unit-tested). |
| `scripts/game/chase_camera.gd` | THPS-style follow camera: ramp-facing view in vert airs, a 3/4 view on grinds with the arm pivoted out towards the open hall (so wall pilasters and rafter hanger rods never cut across it), a sphere-cast spring arm that eases in and out, holds its distance past thin beams and swings round walls instead of collapsing onto the skater, never swings round into a wall after a bounce, turns at most 240 deg/s, and slides sideways past hanger rods to keep them off the line of sight. |
| `scripts/level/level.gd`, `rail.gd`, `glass_burst.gd` | Loads the park, lightmap PBR materials, collision surfaces, rails, breakable windows and wall, pickups. A breaking window keeps jagged shards in its frame and throws out tumbling glass that lands on the quarterpipe below and lies there before fading. |
| `scripts/ui/hud.gd`, `menus.gd` | HUD (score, special meter, timer, goals, letters, combo, balance meters) and menus. |
| `scripts/audio/sfx.gd` | Every sound synthesised into AudioStreamWAV buffers at startup (rolling on concrete/wood/metal, pop, landings, grind scrapes, wind, bail, board clatter, glass, wall break, pickups, UI); pitch and volume driven at runtime. |
| `shaders/` | `park.gdshader` (lightmap + real-time sun PBR for the park), `park_decal.gdshader` (graffiti decals), `skin.gdshader` (skin with faked subsurface scattering), `hair.gdshader` (alpha-tested hair cards with tinted anisotropic highlights), `window_glass.gdshader` (grimy glass; broken panes get irregular straight-edged holes with shards left in the frame), `yard_sky.gdshader` (the outside: utility poles and wires, trees and the next blocks' rooflines at their real distances, a sky with clouds). |
| `scripts/game/autopilot*.gd` | Scripted two-minute run used for the recording, the tests and the benchmark. |

Physics: Jolt (Godot's built-in Jolt Physics engine) for the ragdoll and the loose board; the
skater itself moves with its own shape casts and rays.

Graphics: PBR materials with baked lightmaps and AO from Blender, a real-time sun with
shadows through the skylights, AgX tone mapping, SSAO, glow on the skylights and lamps,
4x MSAA - all in the Compatibility (WebGL 2) renderer.

## Evidence

FILL:EVIDENCE

## Performance

FILL:PERF
