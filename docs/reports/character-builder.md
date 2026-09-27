# Character builder: male and female skaters, clothing choices

Branch `character-builder`, worktree `skate-game-opus-5-5/.worktrees/character-builder`.
Date: 2026-09-26. Godot 4.7.2 (Compatibility), Blender 5.2.2 with MPFB2.

## Update, 2026-09-27: on top of new-level and windows-build

The coordinator asked for this branch to be rebased onto `windows-build` (16b7f78: Eastside
Baths, the level kit and level select, then the Windows build). The work was squashed into one
commit on top of it. The pre-rebase history (commits `d32f30f` to `860241a`, listed below) is
kept locally as `character-builder-pre-rebase`.

Two steps the session's permission checks refused were finished by the coordinator, as the
owner decided (2026-09-27):

1. **The two image-provenance files**, `imagegen-log.jsonl` and
   `blender/textures_src/generate_sources.sh`, keep both sides' 4 new entries (Eastside Baths:
   pool tile, wall tile, plaster, terrazzo; this branch: her face, twill, rib knit, flannel).
   The log holds 25 unique entries in time order, 25 of 30 images, as the README says.
2. **The branch**: the merged work is committed, and it is what the `character-builder` branch
   on GitHub holds.

Commit ids in this report are from the local history. Before the first push to GitHub the
history was trimmed of an oversized old video, so the published commits have different ids
(the file trees are identical).

Conflicts resolved (everything kept from both sides):
- `scripts/ui/menus.gd`: both signals. The start screen names the level and shows both hints
  (`TAB / SELECT: choose a level` and `C / Y  SKATER`). `show_end` keeps the level's
  "cleared" text, then the skater and replay.
- `scripts/game/main.gd`: my Skater screen returns through the level-aware `_show_start()`.
  The end screen gets the level's "cleared" text, and a level switch clears the replay.
- `blender/build_all.py`: the level-kit loop and per-level renders stay; my skater, female
  and `renders_skater` stages are added. A headless `-- --only pickups` run imports every
  module and rebuilds `pickups.glb` byte-identically.
- `tests/run_all.sh`: every suite from both sides, plus the builder, plus a new combined
  suite (`tests/test_builder_levels.gd`).
- `README.md`: every section from both sides (Levels, Character builder, Windows build).
- `tests/results/*`: took `windows-build`'s side, then regenerated them by rerunning.

Checked for interactions that aren't text conflicts: the Windows desktop layer quits on Q / B
"in a menu" (`menus.mode != NONE`), and the Skater screen hides the menus, so Q (turn) and B
(leave) there never quit. Select / Back in the Skater screen ("default skater") doesn't open
the level select. The replay only sets the camera while the tree is paused.

Results on the combined code (`character-builder-rebased` working tree, 16b7f78 + this work):

| Check | Result | File |
|---|---|---|
| `tests/run_all.sh`, all 17 suites | **17 / 17 pass**, 908 checks plus both two-minute runs: scoring 40, flow 24, input 178, audio 69, park 111, anims 118, clips 28, handling 48, ragdoll 75, camera 27, Warehouse run all goals (69,043), level select 19, builder 44, builder with the level select 19, Baths park 53, Baths run all six goals (58,951), desktop 55 | `tests/results/run_all_combined.txt` |
| The Skater screen and the level select together | **19 / 19** (both hints; Tab and Select inside the Skater screen don't open the level select; the skater kept across a switch and at the Baths' spawn; Skater screen, run, end screen and replay on the Baths; the next launch restores her) | `tests/results/builder_levels.txt` |
| The chosen skater on both levels | 4 autopilot runs (female flannel/shorts/hi-tops/beanie and male tee/cargo/navy suede/cap on the Warehouse; female tee/cargo/navy suede/cap and male flannel/shorts/hi-tops/beanie on the Baths): every goal, 69,043 and 58,951 points | `tests/results/fullrun_skaters_both_levels.txt` |
| Her Baths run, frame by frame | 7,201 frames, 0 flagged; one crop a second checked by eye | `tests/results/frames_baths_female.json`, `evidence/baths_female_run_*.jpg` |
| Web (`tools/export_web.sh`), Chrome | builder **13 / 13**, level select and the Baths pack **9 / 9** (the Baths run completes every goal in the browser), web check with the full run **10 / 10** (70,615 points) | `tests/results/web_check_builder_localhost_8791.json`, `web_levels_localhost_8791.json`, `web_check_localhost_8791.json` |
| Web download | boot: **122.06 MB raw, 66.63 MB gzip** (`index.pck` 82.19 / 56.40 MB). The Baths pack is 37.62 / 27.02 MB, downloaded only when chosen. Against the original build's 43.36 MB gzip: +23.27 MB | README, Performance |
| `bash desktop/build_windows.sh` | builds: `ProSkater.exe` 218.6 MB (187 before), zip 115.8 MB (94 before). The builder's files and the Baths are embedded | `build/windows/` (not committed) |

Not done or NOT VERIFIED on the combined code:
- **No native Windows smoke run.** Not required, and it would launch the game on the owner's
  desktop. The desktop layer's headless suite (55/55, in the staged Windows project) did run.
- **`tests/web_export_unchanged.sh`** wasn't run. It checks that the web export equals the tree
  before the Windows build, which this branch changes by design (its assets are in the pack).
- **The clothing-fit test** (`tests/test_outfits.gd`, ~20 min) and a full `build_all.py`
  weren't re-run on the combined code. The skater assets and `skater_model.gd` didn't change
  in the merge, and the pickups run above exercises the merged `build_all.py`.
- **Benchmarks** (Chrome, Windows): not re-run with the builder merged in.

## Summary

The start screen now opens a **Skater** screen (C on the keyboard, Y on a gamepad) with a
lit 3D turntable. The player picks the body (male or female) and a top, bottom, shoes and
headwear, and each change shows at once. The choice is saved in `user://skater.cfg`
(IndexedDB on the web), restored on the next launch, and used in the run, on the end
screen, and in a new instant replay. With nothing saved the game is today's male skater.

- **Female skater**: built with MPFB2 through the same five stages as the male (body,
  face, skin, eyes/brows/lashes, hair). She has her own body macros and face targets, an
  original generated face photo projected with the landmark warp, random-walk SSS skin
  with pore-level normals, and long hair pulled back into a high bun (2,155 hair cards; his
  crop is 2,200).
- **Wardrobe**: 3 tops, 3 bottoms, 3 shoes and 3 headwear options (none, beanie, cap), each
  fitted to both bodies on one shared skeleton. That makes 2 × 3 × 3 × 3 × 3 = 162 skaters.
- **Animation**: the 25 clips are stored once. Her body file carries only a per-clip
  overlay with her legs re-solved onto the deck by the foot IK, plus her arms where a clip
  uses the hand IK. The feet-on-board test runs on both bodies and all three shoes, with the
  same tolerance as before.
- **Web**: the download grew from 43.36 MB to 66.58 MB compressed (**+23.22 MB**), within
  the ~+25 MB aim. Raw files grew by 33.71 MB. The builder passes 13 of 13 checks in the web
  build in Chrome.
- **The default skater differs from today's in one respect, deliberately.** The new
  clothing test found today's outfit coming through itself in extreme poses. You chose to
  have those fixed as well, so his hoodie, hood and jeans have re-fitted skin weights at
  the hip band and the hems. Everything else about him is identical triangle for triangle:
  body, face, hair, garment shapes, UVs, normals, textures, shoes, skeleton and all 25
  clips. The test checks this.
- **Known issue**: in the deepest hip bends (bails and getups), the trousers' waistband
  comes through the top's hem by 13.5–24.0 mm, on both bodies and in every outfit,
  including today's. Skin, hair and socks never come through anything. See Known issues.

## What was built

### 1. The female skater (`blender/skater_profiles.py`, the skater stages take a profile)

- `skater_profiles.py` holds `MALE`, which is exactly the values the original stages used
  (so he builds as before), and `FEMALE`. Every stage (`skater_body`, `skater_face`,
  `skater_skin`, `skater_hair`, `skater_clothes`, `skater_outfit`, `anims`) takes a profile.
- Her body: MPFB2 macros (gender 0, age 0.45, muscle 0.6, weight 0.42, height 0.58,
  proportions 0.85, mixed heritage) and 39 face and body targets. The face shape is
  original: oval head, high cheekbones, full lips, a straight nose with a soft tip, and
  almond eyes. The lower face is lengthened to match the photo's proportions, so the
  projected texture isn't squashed.
- Her face albedo is an original generated woman (`blender/textures_src/face_albedo_f.png`,
  image 1 of 4 used). It is projected with a thin-plate-spline warp from 29 landmark pairs
  measured on the photo and on a front orthographic render of her head. The photo is cleaned
  up where the hair and brows are, with no stubble.
- Skin, eyes, brows and lashes use the male's materials and methods, with her own tones,
  iris tint, 280 brow cards with her arch, and longer lashes.
- Hair (`skater_hair.py: build_bun`): long hair pulled back over the scalp into a high bun,
  with a soft painted scalp fading out under it. The hairline's hard "teeth" came from a
  fine hairline layer and were removed.
- Renders: `renders/skater_female_portrait.png`, `skater_female_tpose.png` + `_sheet.png`
  + `_turntable.mp4`, `skater_female_trick.png` + `_sheet.png` + `_turntable.mp4`, lit like
  the male's (same studio rig in `renders.py`).

### 2. The wardrobe (`blender/skater_outfit.py`, new, about 2,700 lines)

| Slot | Options |
|---|---|
| Top | Red fleece hoodie (default, today's), White graphic tee, Green flannel shirt |
| Bottom | Blue jeans (default, today's), Olive cargo pants, Khaki chino shorts (with crew socks) |
| Shoes | Grey suede low-tops (default, today's), Navy suede low-tops (gum sole), Black canvas hi-tops |
| Headwear | None (default), Mustard rib beanie, Navy six-panel cap |

- Garments are cut from each body and sculpted there, so they carry that body's skin
  weights on the one shared skeleton. Both bodies come from the same MakeHuman mesh, so each
  garment has one UV layout and one set of baked textures (fold normals, AO, albedo,
  roughness) for both bodies. Her GLBs reuse his texture files.
- New fabric sources (images 2–4): flannel plaid, cotton twill (cargo, shorts, cap, hi-top
  canvas), and rib knit (beanie, socks). The prompts are in `generate_sources.sh`.
- Layering follows the existing hem/cuff pass. Every top hangs over every bottom, and
  trouser hems drape over each shoe (radially over the tongue and lace bow). The jeans,
  cargo and socks each have two versions, one for low shoes and one for hi-tops.
- The body mesh is never cut per outfit. Each face records which garments cover it (a bit
  mask in a vertex colour), and `skin.gdshader` / `hair.gdshader` discard what the worn
  garments and hat cover.
- A fit-in-motion pass re-weights the places where layers meet: a smoothed hip-band weight
  field shared by the tops' hems and the waistbands, rigid shoes with rigid trouser hems
  riding on them, and the skin at each opening lending its weights to the garment edge over
  it. It also pushes the tee and flannel clear of the skin, and bridges the bust apexes and
  navel on the tops.
- Contact sheet of every garment on both bodies: `renders/outfits_sheet.png`.

### 3. Animation: one clip library, a per-body overlay (`blender/anims.py`, `skater_model.gd`)

- The 25 clips are baked once on the male skeleton (`assets/skater_anims.glb`, 1.1 MB).
  Her rest pose is aligned to his, so every track plays unchanged on her.
- `anims.build_female` re-solves, per clip and per frame, her legs with the foot IK onto the
  deck (her leg lengths and ankle heights differ). Her arms are re-solved too wherever the
  clip's hand IK holds the board or the ground. Only those tracks go in her GLB, and
  `skater_model.gd` lays them over the shared clips when she is built.
- `tests/test_anims.gd` now runs every feet-on-deck, board-sync, getup and floor check on
  her as well, with the same tolerances. It also checks the actual shoe soles on the deck
  in every clip, for both bodies and all three shoe models.

### 4. The game (`scripts/`)

- `scripts/skater/skater_outfit.gd` (new): the choice (body, top, bottom, shoes, hat), its
  labels, `user://skater.cfg` load and save (per-slot fallback to the default for unknown
  values, and the default for a broken file), `--skater=` / `?skater=` parsing, and the
  input actions.
- `scripts/skater/skater_model.gd`: builds the character from a choice. It loads the chosen
  body and garment GLBs on demand, skins them to one skeleton, sets the cover mask for the
  shaders, merges her overlay into the shared clips, and can rebuild in place when the
  choice changes.
- `scripts/ui/skater_builder.gd` + `scenes/ui/skater_builder.tscn` (new): the Skater screen.
  It has five rows, a live turntable, and its keyboard and gamepad controls listed on screen.
  Enter / A saves, Esc / B leaves without saving, R / Back resets to today's skater.
- `scripts/ui/skater_preview.gd` (new): the lit 3D turntable (its own world, key/fill/rim
  lights and a floor), used by the Skater screen and the end screen. The camera moves
  towards the slot being changed (head for the hat, chest for the top, legs, shoes) and
  follows that body part as the skater turns.
- `scripts/game/replay.gd` (new): the game had no replay, so I added an instant replay. It
  records the last 15 seconds of the run (skater, board and animation state) and plays them
  back with the same skater. It is started with V / X from the end screen.
- The end screen shows the run's skater on a turntable, with the outfit named.

## Commands

```bash
godot --headless --path . --import                         # once, fresh worktree
blender --background --python blender/build_all.py         # everything (both skaters, wardrobe, park, renders)
blender --background --python blender/build_all.py -- --only skater_female   # her alone
blender --background --python blender/build_all.py -- --only renders_skater  # the skater renders alone
python3 tests/texture_imports.py                           # VRAM-compressed imports for the new textures (idempotent)
bash tests/run_all.sh                                      # 12 headless suites (the builder is the 12th)
godot --headless --path . --fixed-fps 60 -s tests/test_builder.gd
godot --headless --path . -s tests/test_anims.gd
godot --headless --path . -s tests/test_outfits.gd -- --fps=30 --only=male     # 452 s
godot --headless --path . -s tests/test_outfits.gd -- --fps=30 --only=female   # 669 s
godot --path . --resolution 1920x1080 -s tests/builder_shots.gd -- --out=res://evidence/builder
godot --headless --path . --fixed-fps 60 -- --autopilot=test --skater=female,flannel,shorts,hitop,beanie
mkdir -p build/web && godot --headless --path . --export-release "Web" build/web/index.html
python3 tests/web_check_builder.py http://localhost:8791/   # with build/web served on :8791
python3 tests/web_check.py http://localhost:8791/ --run
```

## Test results

| Check | Result | File |
|---|---|---|
| Builder: every combination, persistence, keyboard, gamepad, default = today, run, end screen, replay | **44 passed, 0 failed** | `tests/results/builder.txt` |
| Feet on the board, both bodies, all 25 clips, all 3 shoes | **118 passed, 0 failed** (her worst: 1.8 cm in the ollie pop, as his 1.9 cm; deepest into the deck 0.2 cm) | `tests/results/animations.txt` |
| Clothing fit in motion, 9 outfits per body, 25 clips at 30 fps | **male 107 passed, 0 failed, 11 KNOWN; female 109 passed, 0 failed, 9 KNOWN** | `tests/results/outfits_male.txt`, `outfits_female.txt` |
| Clothing fit with the fit pass off (for comparison) | 39 pairings failed; today's jeans 51.9 mm through his hoodie | `tests/results/outfits_without_fit_pass.txt` |
| Her two-minute autopilot run | every goal, 69,043 points (the same as the default skater headless) | `tests/results/fullrun_female.txt` |
| `tests/run_all.sh`, 12 suites (the original 653 checks, now 762: the animation suite runs on both bodies, plus the builder's 44) | final run: **all 12 suites pass**: scoring 40, flow 24, input 178, audio 69, park 111, anims 118, clips 28, handling 48, ragdoll 75, camera 27, the full run completes every goal (69,043 points), builder 44. Of 5 full runs on this branch, 2 had one ragdoll check fail and 1 had one handling check fail. The ragdoll suite fails like this on the original commit too (see below) | `tests/results/*.txt`, `repeat_runs_ragdoll_handling.txt` |
| Full headless rebuild (`build_all.py`) | exit 0 in 872 s. Every file under `assets/` byte-identical to the committed ones except the caps, where the button's triangle order varied; that is now fixed, and two more rebuilds are identical in all 157 files. Renders and lightmap: GPU noise only (at most 4/255 on 0.013 % of pixels) | `tests/results/rebuild_determinism.txt`, `logs/build_all_headless_charbuilder.log` |
| Builder in the web build (Chrome, localhost:8791) | **13 / 13** (start screen names the key, keyboard and gamepad open and change it live, saved in IndexedDB across a reload, the run skated by her, `?skater=`, no page errors) | `tests/results/web_check_builder_localhost_8791.json` |
| Original web check on the same build, with the full run | **10 / 10**, full two-minute run completes every goal | `tests/results/web_check_localhost_8791.json` |

**"Default = today's skater"** (`tests/test_builder.gd`, `tests/data/skater_baseline*.json`).
The baseline was recorded on the original commit (`d32f30f`) before any change. It holds a
per-material fingerprint of every triangle (positions, UVs, normals, weights, textures),
the skeleton, and every clip key. The default build matches it for 28 materials and
172,906 visible triangles, the 54-bone skeleton, and all 25 clips key for key. His hoodie,
hood and jeans match in shape, UVs, normals and textures. Only their skin weights differ
(the re-fit you chose), and the test prints which hashes differ.

**Ragdoll and handling vary from run to run.** Across my `run_all.sh` runs, ragdoll failed
1 of 75 checks twice and handling 1 of 48 once. The first failures' logs were overwritten
before I read them. To find out whether this was new, I ran the original commit
(`696364b`, extracted with `git archive` and imported) side by side with this branch under
the same load (`tests/results/repeat_runs_ragdoll_handling.txt`):

- `run_all.sh`, both at once, 2 rounds: the original's ragdoll suite failed a blood check
  in **both** rounds ("the bail leaves blood", 1 splat where 2 are needed). The branch
  passed all 12 suites in both rounds.
- Ragdoll alone, 5 rounds: the original failed 2 checks once (an arm 3.6 cm into the torso;
  the branch's one failure on the final assets was this check at 3.7 cm). The branch passed
  5 of 5.
- Handling alone, 3 rounds: 3 of 3 on both.
- The cause is original code: `scripts/skater/skater.gd:161` (unchanged) seeds the
  skater's RNG with `randomize()`, so bails differ from run to run. The ragdoll code in
  `skater_model.gd` is line-for-line the original's, and so is the default skeleton it is
  built from. The character builder did not introduce these failures, and I did not relax
  any check.

## Watched frame by frame (`evidence/`)

- `female_bail_showcase.mp4` (hoodie, jeans) and `female_bail_showcase_tee_cargo_hitops.mp4`
  are in-game recordings of her bails, ragdolls and both getups. Their frames were checked:
  `female_bail_ragdoll_getup_frames.jpg`. The ragdoll and the getups are clean in both
  outfits: the garments follow the body, nothing pokes through, and she ends on the board.
- `female_rafter_grind_frames.jpg`: her rafter grind, frame by frame (`tests/frames.gd` +
  `tests/frames_sheet.py`).
- `female_clips_<outfit>_{0,1,2}.jpg`: every clip, 6 moments each, front and back, in three
  outfits (hoodie/jeans/suede, tee/cargo/hi-top/cap, flannel/shorts/navy suede/beanie).
  Feet stay on the deck and sleeves, hems and hats follow in every clip.
- `known_hip_band.jpg`: the four worst hip-band frames close up, from four sides (see Known
  issues).
- `builder/01_start_screen.png` ... `06_start_after_done.png`: the desktop build driven by
  real key events (`tests/builder_shots.gd`): the start screen with the C / Y hint, the
  Skater screen as opened, her body, each slot changed, turned by hand, and the start
  screen after Done. The first screenshots showed the turntable camera aiming at the
  turntable's axis, so in close-ups (hat, shoes) the part swung out of frame as she turned.
  The preview now follows the part (see above), and these screenshots are the fixed version.
- `web_builder_localhost_8791_*.png`: the Skater screen in the web build.

## Web download size

| Build | Raw | Gzip | `index.pck` raw / gzip |
|---|---|---|---|
| Before (original commit, measured at the start) | 88.29 MB | 43.36 MB | 48.42 / 33.13 MB |
| After (both bodies, the whole wardrobe) | 122.00 MB | 66.58 MB | 82.12 / 56.35 MB |
| Difference | +33.71 MB | **+23.22 MB** | |

The live Vercel host serves `index.pck` and `index.wasm` brotli-compressed (checked with a
HEAD request), so the compressed size is what a player downloads. I measured gzip; I had no
brotli tool, so the exact brotli size is not measured. Brotli is normally no larger than
gzip. The clips are in the pack once. With Godot's lossless texture defaults the pack was
111 MB, so `tests/texture_imports.py` gives the new textures the VRAM-compressed import
settings the original skater's textures already used.

## NOT VERIFIED

- **Brotli transfer size** of the new build: not measured (no brotli tool); gzip is +23.22 MB.
- **Performance with the builder**: the Chrome benchmark (`tests/chrome_bench.sh`) was
  not re-run. The default skater's meshes and textures are unchanged, but her frame rate in
  the browser was not measured.
- **Real gamepad hardware**: the gamepad paths are tested with synthetic joypad events
  (headless) and with a virtual Gamepad API pad in Chrome, not with a physical controller.
- **Laptop 60 fps**: still not verified, as before this task.
- **Which checks failed in the first `run_all.sh`** (handling 1, ragdoll 1): unknown, since
  the logs were overwritten. Repeat runs show both suites vary from run to run on the
  original commit too (see Test results).
- **Live-window parity of the new assets**: the committed assets are exactly what the
  headless build produces, but no live-window build of them was made and compared, and
  `manifest_live.json` predates them. Headless determinism is shown instead
  (`tests/results/rebuild_determinism.txt`).
- The **live Vercel site** does not have this work yet; the coordinator deploys after merging.
- The `jev_*` tools named in the global CLAUDE.md are not connected in this session, so
  they were not used.

## Known issues

1. **Hip band, garment through garment.** In the deepest hip bends the waistband comes
   through the top's hem. This is 13.5–24.0 mm at each pairing's worst frame, and every one
   of those frames is in the bail or one of the getups. It happens in every outfit on both
   bodies, including today's hoodie and jeans (17.2 mm in the bail). Both layers now share
   one smoothed weight field (without it: 51.9 mm, and 39 pairings failed), but linear blend
   skinning still folds both layers through each other at those angles. The test reports
   it as KNOWN with its numbers and never counts it as a pass. A real fix needs corrective
   blend shapes on the hip bend, or dual-quaternion skinning (which Godot's skinning
   doesn't offer).
2. **Today's tongue tops.** At rest the top of his grey suede shoes' tongue and lace bow
   stands in front of his jeans hem (76 vertices), as in the original build. The default
   keeps today's shapes, so this stays. Every other trouser is draped over its shoes and
   passes.
3. **The web pack carries every option.** Only the chosen body and garments are loaded
   into memory, but the download includes all of them (+23.22 MB gzip). Splitting options
   into separately downloaded packs was not done.

## Shared files touched

Additive and localised, for the merge:

- `scripts/ui/menus.gd` (+43 / −3): the `skater_pressed` signal, the C / Y key, the hint on
  the start screen, and the end-screen turntable and replay button. The controls table and
  `test_input` are unchanged.
- `scripts/game/main.gd` (+27 / −1): opens the Skater screen, rebuilds the skater after Done,
  creates the Replay, and prints `[skater] skating as ...`.
- `scripts/skater/skater_model.gd` (+239 / −17): restructured to build from a choice. The
  default path builds today's skater. The ragdoll code is unchanged, line for line.
- `shaders/skin.gdshader`, `shaders/hair.gdshader`: +13 / +12 lines for the cover mask
  (no effect when nothing is covered).
- `blender/skater.py`, `skater_body.py`, `skater_face.py`, `skater_skin.py`,
  `skater_hair.py`, `skater_clothes.py`, `anims.py`, `renders.py`, `build_all.py`: profile
  parameters (the male's defaults are unchanged), her hair, the export split, her overlay
  bake and the new renders. New: `skater_profiles.py`, `skater_outfit.py`.
- `tests/test_anims.gd` (runs for both bodies and all shoes), `tests/run_all.sh` (12th
  suite: builder).
- `README.md`: a new "Character builder" section with "Clothing fit", plus Evidence,
  Performance, Commands, Controls and script-table rows.
- `blender/textures_src/generate_sources.sh`, `imagegen-log.jsonl`: the 4 new images.
- Assets: `assets/skater.glb` now holds his body alone. His garments moved to
  `assets/outfit/male_*.glb`, byte-identical textures with renamed files. Added:
  `assets/skater_female.glb`, `assets/skater_anims.glb`, `assets/outfit/*` and
  `catalog.json`. His renders in `renders/` changed with the re-fitted weights.
- No change to `project.godot` (the builder adds its input actions at run time), to
  `.vercel/`, or to `engine/` (checked with `git diff 696364b HEAD`).

## Images

4 of my 8 used (the project is now at 21 of 30): `face_albedo_f.png` (her face),
`flannel.png`, `twill.png` and `rib_knit.png`. They are logged in `imagegen-log.jsonl`, and
the prompts are in `generate_sources.sh`. MPFB2 is the only human generator. No downloaded
models, textures, HDRIs, rigs, animations or sounds.

## Commits

- `d32f30f` Baseline of the original skater: mesh/animation fingerprint and GPU snapshot hashes
- `59f21f6` WIP character builder: female skater (MPFB2), garment library for both bodies, shared clip library + per-body IK overlay, builder screen, replay
- `b3c658e` Clothing fit in motion: rigid shoe/hem overlap, hi-top trouser weightings, smoothed hip band, skin clearance for the new tops
- `6f43fff` Default skater identical to today's again; builder fixes
- `f0cb159` Web budget, hi-top hems, her hoodie and hairline; rest-pose check in the fit test
- `d654e83` Her hairline, trouser hems over the shoes, cargo hem fold fixed; fit test rest check with the exact test criteria
- `91df0a3` Tops bridge the bust apexes and navel; evidence of the female skater; final fit, builder and web results; README
- `84edeae` Deterministic cap export; the Skater screen's camera follows the part being changed; rebuild and repeat-run evidence
- (final) Final test results, web check and report - see `git log` for its hash
