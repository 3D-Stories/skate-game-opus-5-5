# Windows desktop build: report

Branch `windows-build`, worktree `.worktrees/windows-build`, 2026-09-26. Built in WSL on "pc"
(i9-12900KF, RTX 4080, Windows 11 26200, NVIDIA 610.74) and tested natively on its Windows
side. The CI VM "nillerkgames" was not needed and not used: Godot exports Windows builds from
Linux.

## Rebase onto new-level (2026-09-26, evening)

At the coordinator's request the branch was rebased onto `new-level` (7630e89: Eastside Baths,
the level kit, the level registry and level select), which merges first. The pre-rebase head
is kept as the local branch `windows-build-pre-rebase` (83bb571).

- **Conflicts**, all resolved keeping both sides: `tests/run_all.sh` (new-level's level-select
  and per-level suites, plus the desktop suite before `wait` and in the summary),
  `tests/chrome_bench.sh` (new-level's `BENCH_PORT` / `BENCH_PROFILE`, plus `CHROME_POS`; both
  branches had added the same `BENCH_OUT` line), `README.md` (both sides' Commands and Evidence
  rows; the Windows build section after new-level's level numbers). `export_presets.cfg`
  merged by itself into two separate presets: the Web preset now excludes `assets/levels/*`
  (new-level), the Windows preset does not.
- **Levels on desktop: embedded.** The web build keeps Eastside Baths in `levels/baths.pck`,
  downloaded when the level is first chosen. The Windows build has it inside the exe: a desktop
  download is fetched once as a whole, a second file beside the exe could only go missing, and
  `LevelRegistry.available()` already treats assets in the main pack as loaded, so no game
  code changed. The exe grew from 150.6 to 186.5 MB, the zip from 68.0 to 93.7 MB. Every entry
  of the web Baths pack is in the exe; its 52 imported textures / meshes and `baths_data.json`
  are byte-identical (only the `.import` remaps differ: the exporter writes its own short
  form) (`tests/results/windows/embedded_baths.txt`).
- **A gap in my web check, found and fixed.** After the rebase a fresh `--import` picked up the
  13 benchmark load CSVs I had committed in `tests/results/windows/`: Godot imports a `.csv` as
  a translation, with a UID, so a fresh checkout of this branch would have put 13 new UIDs in
  the web pack's UID cache, and one fresh import crashed on them (glibc heap corruption).
  Yesterday's "byte-for-byte identical" held only for the copy my check built, which left out
  `tests/results/`. Fixed: `tests/results/windows/.gdignore`, and
  `tests/web_export_unchanged.sh` now takes what a fresh checkout would hold (every file git
  would commit, through a temporary index; the real index and the stash are untouched),
  builds with `tools/export_web.sh`, compares every file and every pack entry, and defaults to
  the tree before the Windows build (the parent of the commit that added `desktop/desktop.gd`,
  i.e. new-level's 7630e89). Before the `.gdignore`, the fixed check reproduced the failure;
  after it: **PASS**, all 10 files, 521 `index.pck` and 105 `levels/baths.pck` entries
  identical (`tests/results/web_export_unchanged.txt`).
- **Tests**: all 15 suites of `tests/run_all.sh` pass (new-level's 14: the 11 originals with
  653 checks, the level select 19, the Baths park suite 53, and the two full runs with every
  goal; plus the desktop suite), `tests/results/run_all_windows_branch.txt`. The desktop suite
  went from 47 to 55 checks: the Baths is available with no pack URL on desktop, Tab opens the
  level select with no "downloads" tag, Q / B do not quit from it (B goes back), Right + Enter
  loads the Baths and the quit hint returns, and `-- --level=baths --autopilot --quit-at-end`
  completes all six Baths goals (58,951 points). The per-suite result files the run rewrote were
  put back to new-level's versions (only timestamps and run-to-run noise differed; the camera
  suite's closest distance on one grind was 5.77 m and then 5.66 m in two runs of a clean copy
  of new-level itself, 5.83 m here).
- **Native smoke test** (`desktop/smoke_windows.sh`, 1920x1080 window on DISPLAY2, a secondary
  monitor, never focused; DISPLAY4 is primary): **14 / 14 PASS** (`tests/results/windows/smoke.txt`).
  The Warehouse scripted run completes all five goals (69,043 points) and Eastside Baths all
  six (58,951), each quitting by itself with a bench report; the renderer read back is OpenGL
  3.3 on the RTX 4080 at 1920x1080 with 4x MSAA, SSAO, glow, AgX and sun shadows. With the
  keyboard (window messages), Tab, Right + Enter on the start screen load the Baths, Enter
  starts a run, W pushes the skater to 13.0 m/s, Esc pauses and Q twice quits (exit 0), and the
  master bus plays sound. Pictures: `evidence/windows_level_select.jpg`,
  `windows_baths_start.jpg`, `windows_baths_run.jpg`.
- **Both levels, uncapped, back to back** (`desktop/bench_windows.sh ... uncapped`):

  | Level | Frames | Average | Median | p95 | p99 | 1 % low | > 16.7 ms | Slowest |
  |---|---|---|---|---|---|---|---|---|
  | The Warehouse | 80,145 | 667.2 fps | 1.20 ms | 2.77 ms | 3.27 ms | 158.9 fps | 3 | 270.9 ms, at the first window broken (new exe: shader caches cold) |
  | Eastside Baths | 55,759 | 461.0 fps | 2.15 ms | 3.09 ms | 4.41 ms | 124.7 fps | 6 | 21.0 ms |

- **Vsync did not hold today** (NOT VERIFIED why). With the same monitors and launch as
  yesterday's 60.0 fps runs, OpenGL ran at 465-925 fps with vsync read back as enabled; the
  pre-rebase exe, rebuilt from a clean copy, did the same, so it is not the rebase. In one Baths
  smoke run it switched back to 60 Hz mid-run after a 7.4 s stall inside the driver. Details:
  `tests/results/windows/vsync_recheck.txt`. The smoke table's frame rates are therefore not a
  benchmark; the uncapped pair above is.
- **A measurement artefact, fixed**: the first smoke run's Baths report had four 0.72-0.76 s
  frames at exactly 0, 30, 60 and 90 s, spent in script: my `--shots` saving a 1080p PNG.
  The smoke script no longer takes screenshots in a benchmark run, and `desktop.gd`'s header
  says what a shot costs.
- Housekeeping: two test windows outlived their runs (a `timeout` stopped the WSL script, not
  the Windows process; one run was started without `--quit-at-end`). Both were mine, both were
  on DISPLAY2, and both were closed by PID. No window opened on the primary monitor.

The sections below are the report from before the rebase; where the rebase changed a
number, the line above wins.

## Result in short

- `bash desktop/build_windows.sh` makes `build/windows/ProSkater.exe` (151 MB, the pck
  embedded, name / version 1.0.0 / tiger icon set) and
  `build/windows/ProSkater-1.0.0-windows-x86_64.zip` (68 MB: the exe and a `README.txt`) in
  about 15 s. Build artifacts are ignored by git (`build/windows/`).
- Templates: the official Godot 4.7.2 export templates from the Godot GitHub release, SHA-512
  checked (`desktop/install_windows_templates.sh`).
- Renderer: native OpenGL 3.3, measured against ANGLE on Direct3D 11: 626 fps against 104 fps
  uncapped at 1080p, vsync kept (60.0 fps, no missed refresh) where ANGLE did not keep it, and
  the same picture (mean difference 0.1 of 255). AgX, SSAO, glow, 4x MSAA, fog and sun shadows
  are on in every run, read back by the game.
- Run natively from `C:\Temp\ProSkater\`: the autopilot two-minute run completes all five
  goals (69,043 points) in all 13 native benchmark runs and 2 screenshot runs; keyboard,
  sound, pause and quit work;
  F11 goes fullscreen at 1920x1080 on the 1080p monitor and back to a fitted 1764x992 window.
- The web export is byte-for-byte unchanged (all 9 files, all 508 pck entries), for a copy
  of the tree without `tests/results/` (see the rebase section: a fresh checkout would not
  have been; fixed).
- All 11 existing suites pass (653 checks + the full run), plus the new desktop suite (47).
- Known issue: after leaving fullscreen, the never-focused test window keeps showing a stale
  frame (the game renders fine underneath). Whether a normal focused window does it is NOT
  VERIFIED. Gamepad on Windows NOT VERIFIED (no controller connected).

## What was built

| Part | Files |
|---|---|
| Template install, checked against the release's SHA512-SUMS.txt | `desktop/install_windows_templates.sh` |
| "Windows Desktop" export preset (x86_64, pck embedded, S3TC/BPTC, icon, file/product version 1.0.0.0, product name "Pro Skater: The Warehouse") | `export_presets.cfg` (`[preset.1]`; the Web preset is untouched) |
| One-command build + zip + SHA256SUMS | `desktop/build_windows.sh`, `desktop/stage.sh`, `desktop/README.txt` |
| Windows-only project settings: `Desktop` autoload, `windows_native_icon`, user dir `%APPDATA%\ProSkater`, window mode, `gl_compatibility/driver.windows="opengl3"` with `fallback_to_angle` | `desktop/project_windows.cfg` |
| Desktop layer: fullscreen (default) / window toggle on F11 and Alt+Enter, remembered; fitted 16:9 window (1920x1080, or the largest that fits with title bar and taskbar); Q / B twice quits from any menu with an on-screen hint; pause on focus loss (by pressing the game's own pause action); cursor hidden while riding; `--bench-out`, `--frametimes-out`, `--gpu-time`, `--info-out`, `--shots`, `--quit-at-end`, `--window=`, `--input-log` | `desktop/desktop.gd` |
| Icon from the existing deck graphic (no new image; the build is deterministic) | `desktop/make_icon.py` -> `desktop/icon.png`, `desktop/icon.ico` |
| Headless tests of the desktop layer (in the staged project) | `desktop/test_desktop.gd`, `desktop/test_desktop.sh`; added to `tests/run_all.sh` |
| Native test harness (from WSL): never-focused window, monitor picked by name before every run and never the primary, GPU load and monitor layout logged | `desktop/run_windows.sh`, `desktop/win/pick_screen.ps1`, `desktop/win/displays.ps1` |
| Benchmarks, keyboard / sound / fullscreen checks, screenshots | `desktop/bench_windows.sh`, `bench_all_windows.sh`, `bench_summary.py`, `input_test_windows.sh`, `win/drive.ps1`, `shots_windows.sh` |
| Web export check | `tests/web_export_unchanged.sh`, `tests/pck_diff.py` |

### Why the desktop layer sits in a .gdignore'd folder

Feature-tag overrides (`setting.windows=...`) stay in the web export's `project.binary`, and a
desktop script would have to be in the web pck too. Worse, adding *any* file that gets a UID
(a script, an imported PNG) anywhere in the project reorders the UID and class caches inside
the web pck, even when the file is excluded from the export (found by bisecting the pck with
`tests/pck_diff.py`). So `desktop/` has a `.gdignore`, and the build stages a copy of the
project outside the tree (`~/.cache/proskater-windows/<hash>/stage`) where `desktop/` is
visible and `desktop/project_windows.cfg` is appended to `project.godot`. Nothing in the game's
own scripts changed; `desktop.gd` reads the Main scene's state and picks the bench report up
from the game's `[bench] {json}` log line through a `Logger`.

The stage first lived in `build/windows/`, which broke the audio suite: it walks the whole
project tree, `.gdignore`'d folders included, and flagged the staged copies of the test
scripts. Moving the stage out of the tree fixed it.

### Export templates: official, not rebuilt

Option 2 of the task. The tpz (1.28 GB) is downloaded from
`github.com/godotengine/godot/releases/download/4.7.2-stable/`, checked with `sha512sum -c`
against the release's `SHA512-SUMS.txt`, its `version.txt` checked (`4.7.2.stable`), and only
`windows_{release,debug}_x86_64{,_console}.exe` are unpacked (sha256 of the release template
`d34d36f3...0562`). They link ANGLE statically (both drivers come from one exe) and were built
with Fedora MinGW GCC 15. The web template's patch was not applied because it would buy little
here: it removes the depth copy SSAO triggers, which costs time where copying a multisampled
depth buffer is expensive (ANGLE on D3D11). On native OpenGL, SSAO including that copy costs
0.07-0.2 ms of GPU time a frame (`gl_uncapped` vs `gl_uncapped_ssao_off`, two series).

## Commands

```
bash desktop/build_windows.sh                    # -> build/windows/ProSkater.exe + zip
bash desktop/test_desktop.sh                     # desktop layer, headless (also in tests/run_all.sh)
bash tests/run_all.sh                            # all 12 suites
bash tests/web_export_unchanged.sh               # web export byte-for-byte check
bash desktop/bench_all_windows.sh                # every benchmark, native (about 35 min)
bash desktop/input_test_windows.sh               # keyboard, sound, pause / quit, F11, native
bash desktop/shots_windows.sh                    # OpenGL and ANGLE screenshots, native
bash desktop/smoke_windows.sh                    # both levels + level select, native (about 5 min)
ProSkater.exe -- --autopilot --bench --bench-out=bench.json --quit-at-end
```

## Test results

| What | Result | Files |
|---|---|---|
| 11 existing suites | PASS: scoring 40, flow 24, input 178, audio 69, park 111, anims 53, clips 28, handling 48, ragdoll 75, camera 27 (653 checks), full run 69,043 points with all goals | `tests/results/run_all_windows_branch.txt` |
| Desktop layer, headless | PASS 47 / 47 (38 on the main scene, 9 for the command-line run end to end) | `tests/results/desktop.txt` |
| Exe metadata, read by Windows | ProductName / FileDescription "Pro Skater: The Warehouse", FileVersion / ProductVersion 1.0.0.0, the tiger icon on the exe; the export is deterministic (two builds: the same exe sha256 `0a44aa94...`) | `build/windows/SHA256SUMS.txt` (not committed) |
| Final exe, native smoke run | exit 0; OpenGL 3.3 on the RTX 4080, 1920x1080, 4x MSAA, AgX, SSAO, glow, fog, sun shadows, vsync at 60 Hz, read back by the game | `tests/results/windows/final_smoke.log`, `final_smoke_info.json` |
| Web export unchanged | PASS: 9 / 9 files and 508 / 508 pck entries identical to the base commit, with the same import cache | `tests/results/web_export_unchanged.txt` |
| Native autopilot run | PASS: all five goals, 69,043 points, exit 0 | `tests/results/windows_fullrun.txt`, `windows/gl_vsync.log` |
| Native benchmark | see below | `tests/results/windows/bench_summary.md` and per run `.json` (report + settings read back), `.csv.gz` (every frame, GPU time), `_load.csv` (GPU load, host load), `_displays.txt`, `.log` |
| Native keyboard, sound, pause / quit, F11 | 15 / 16 (the failure is the known issue) | `tests/results/windows/input_native.txt`, `kb.log`, `fs.log`, `*_drive.json`, `*_info.json` |
| OpenGL vs ANGLE picture | same: mean difference 0.1 (start screen), 0.2 (0 s, 15 s of the run); later frames differ by the capture instant (camera moving), not the rendering | `tests/results/windows/shots.txt`, `evidence/windows_gl_vs_angle.jpg` |

### Benchmark (1920x1080, scripted two-minute run, same day and monitor)

| Run | Frames | Average | Median | p95 | p99 | 1 % low | > 16.7 ms | Slowest |
|---|---|---|---|---|---|---|---|---|
| OpenGL, vsync, window (60 Hz) | 7,201 | 60.0 fps | 16.67 ms | 16.71 ms | 16.76 ms | 59.3 fps | 495 (0 missed refreshes) | 19.7 ms |
| OpenGL, vsync, fullscreen, 1080p monitor | 7,201 | 60.2 fps | 16.67 ms | 16.70 ms | 16.74 ms | 59.5 fps | 454 (0 missed) | 17.4 ms |
| OpenGL, uncapped | 75,105 | 625.9 fps | 1.43 ms | 2.65 ms | 4.13 ms | 153.0 fps | 3 | 18.0 ms |
| ANGLE D3D11, vsync | 12,958 | 108.0 fps | 9.03 ms | 11.25 ms | 13.88 ms | 64.6 fps | 19 | 19.6 ms |
| ANGLE D3D11, uncapped | 12,435 | 103.6 fps | 9.31 ms | 12.34 ms | 15.93 ms | 52.1 fps | 97 | 33.7 ms |
| ANGLE uncapped, SSAO off | 28,083 | 234.0 fps | 3.67 ms | 8.63 ms | 13.07 ms | 60.8 fps | 109 | 40.6 ms |
| ANGLE uncapped, MSAA off | 36,892 | 307.4 fps | 3.13 ms | 4.88 ms | 6.58 ms | 108.1 fps | 6 | 19.4 ms |
| Web, Chrome 153, normal | 16,493 | 133.9 fps | 6.90 ms | 10.70 ms | 14.00 ms | 27.5 fps | 58 | 3,265.6 ms |
| Web, Chrome 153, uncapped | 18,553 | 154.6 fps | 6.20 ms | 9.10 ms | 10.80 ms | 80.4 fps | 5 | 88.8 ms |

Notes: "> 16.7 ms" at 60 Hz with vsync counts timer jitter of microseconds; the per-frame CSV
shows no frame over 25 ms (1.5 refreshes). The GPU was shared with the desktop session (up to
87 % total load in the uncapped runs), so uncapped figures varied: `gl_uncapped` 625.9 / 628.3
fps and `gl_uncapped_ssao_off` 634.7 / 743.2 fps in two series (the `_r1` files, from the
build before audio-level sampling was taken out of benchmark runs; everything else about the
two builds is the same). The Chrome slowest frames (3.3 s, and in ANGLE's first run 2.0 s) are
shader compiles at the first broken window, 24 s in.

## NOT VERIFIED, and why

- **What makes OpenGL vsync hold or not in a window** (after the rebase it did not, with the
  same monitors and launch as the runs where it did; the pre-rebase exe behaves the same).
  See the rebase section and `tests/results/windows/vsync_recheck.txt`.
- **Gamepad on the level select, natively**: no controller; the headless desktop suite presses
  B there (it goes back and does not quit), and new-level's level-select suite drives it with a
  pad.
- **Gamepad on Windows**: no controller connected; all four XInput slots empty (a paired Xbox
  controller was switched off) and the game's settings report lists no joypads. The bindings
  are Godot joypad events, tested headless by the existing input suite.
- **Leaving fullscreen in a normal, focused window**: see Known issues. A focusable test
  window could take the foreground: the PC's user had been away from the keyboard for 17
  minutes, past Windows' 200 s foreground-lock timeout. Manual check: F11, F11, F11, and the
  park must still move.
- **Physical keys and hearing the sound**: keys went in as `WM_KEYDOWN` / `WM_KEYUP` window
  messages (the path a key press takes into the game) because the test window never takes
  focus. Sound was verified with the game's audio session peak meter from Windows Core Audio,
  tracking the gameplay (menu blip, rolling, ollie, landing, silence while paused), and the
  game's master bus; nobody listened.
- **Other hardware and Windows 10**: only this RTX 4080 on Windows 11 was tested.
- **A true first launch with OpenGL**: `gl_cold` emptied Godot's shader cache but not the
  NVIDIA driver's own; the first-ever OpenGL run (log not kept) had one 0.57 s frame at the
  first broken window.
- **Code signing**: none, as asked. SmartScreen warns on first start (README says how to
  continue).
- **Blender rebuild**: not re-run; no file under `blender/` or `assets/` changed.
- **jev tools**: not connected in this session, so `jev_screen` / `jev_gate` were not used. The
  one web search (Godot issues on leaving fullscreen) found nothing that matched.

## Known issues

1. **Leaving fullscreen (test window)**. After F11 back to a window, Windows keeps showing the
   window's frame from before fullscreen, and the game keeps rendering correctly underneath.
   It happens with OpenGL and ANGLE, with Godot's fullscreen and exclusive-fullscreen modes
   and with a borderless window covering the monitor, and not with a plain resize. It does not
   recover from minimise/restore, vsync off/on, topmost off/on or transparency off/on. The
   test window has Godot's `no_focus` style (`WS_EX_NOACTIVATE | WS_EX_TOPMOST`). Details in
   `tests/results/windows/fullscreen_toggle_investigation.txt`. The game remembers the mode,
   so a restart opens the window correctly; `desktop/README.txt` says so.
2. **Vsync is not dependable in a window** (updated after the rebase: with an unchanged
   display setup it held on one run and not on the next; see the rebase section).
   Originally: **vsync depends on the display setup.** Earlier in the day, with a 30 Hz virtual monitor as
   primary, OpenGL ignored vsync (838 fps) and ANGLE ran at 19 fps. Those runs were before the
   final build and their files were not kept. After the monitors were rearranged (a 175 Hz
   monitor became primary), OpenGL kept to 60 Hz. ANGLE never kept vsync in a window.
3. **ANGLE is slow with SSAO + 4x MSAA** (the depth copy). It is only the fallback for PCs
   without OpenGL 3.3; the web template's patch would fix it if ANGLE ever became the default.
4. **Clipping**: the game's master bus peaks at +1.6 dB on hard landings (Windows meter at full
   scale). This is the existing mix, the same on the web.
5. **Engine behaviours worked around** (Godot 4.7.2): `--windowed` does not override a
   fullscreen project setting (so the build starts windowed and `desktop.gd` goes fullscreen);
   engine options like `--windowed` are not in `OS.get_cmdline_args()` (hence
   `--window=windowed`); window positions are measured from the desktop's top-left, not the
   primary monitor; a lambda connected to `Input.joy_connection_changed` crashed the game on
   exit (0xC0000005), now a method disconnected in `_exit_tree`; `Input.action_release()` does
   not clear a key's own press (Alt+Enter uses the menus' input cooldown instead).

## Incidents during testing

- The first native launch opened fullscreen on the primary monitor for about 18 s, never
  focused, before the placement fixes above. After that every run went through the monitor
  picker, which refuses the primary monitor, and the layout was logged around every
  benchmark. It did not change during any benchmark.
- One screen-pixel capture of the game window's rectangle (`CopyFromScreen`) caught content
  from the user's own windows behind it, because the window was not painting its whole
  rectangle (the known issue). Both captures were deleted at once and never committed, and
  that capture method was removed from the harness. Only `PrintWindow` (the game's window
  alone) and the game's own frames are used.

## Shared files touched

As merged onto new-level (`git diff new-level windows-build`):

- `.gitignore`: `build/windows/`, `tests/results/windows/*.png`, `tests/results/windows/fs_shots/`.
- `export_presets.cfg`: new `[preset.1]` "Windows Desktop" appended; the Web preset (with
  new-level's `assets/levels/*` exclusion) unchanged.
- `tests/run_all.sh`: runs `desktop/test_desktop.sh` next to new-level's suites (one command
  before `wait`, one name at the end of the summary loop).
- `tests/chrome_bench.sh`: `CHROME_POS` for the window position (default unchanged); new-level
  added the same `BENCH_OUT` line and its own `BENCH_PORT` / `BENCH_PROFILE`, all kept.
- `README.md`: a Commands row (the run_all row now names the desktop suite), two Evidence rows,
  and the "Windows build" section after Performance.
- Everything else is new: `desktop/**`, `tests/pck_diff.py`, `tests/web_export_unchanged.sh`,
  `tests/results/{desktop.txt, web_export_unchanged.txt, run_all_windows_branch.txt,
  windows_fullrun.txt, windows/**}` (with `windows/.gdignore`), `tests/results/logs/desktop*`,
  `evidence/windows_*.jpg`, this report. No game script, scene, shader, asset, level file or
  `project.godot` changed, and no per-suite result file of new-level's.
- Outside the repo: the four Windows templates added to
  `~/.local/share/godot/export_templates/4.7.2.stable/`, the tpz cache in
  `~/src/godot-templates-4.7.2/`, the stage in `~/.cache/proskater-windows/`, and on Windows
  `C:\Temp\ProSkater\` (the test copy and outputs) and `%APPDATA%\ProSkater` (the game's shader
  cache and logs; the saved window choice was removed after the tests). The local branch
  `windows-build-pre-rebase` (83bb571) keeps the pre-rebase history; delete it once the merge
  is done.

## Commits

On new-level (7630e89), `git log new-level..windows-build`: `124da20` (preset, templates,
desktop layer, staged export), `cdbdc2a` (desktop tests, Alt+Enter, quit-at-end), `e030b82`
(native harness), `ba334c4` (native results), `9205a93` (README section, report, final smoke
run), `1f9bf8c` (report hashes) are the pre-rebase commits `baa976d`, `ad25285`, `5a4969d`,
`dda0414`, `057b55b`, `83bb571` replayed; then `c24e764` (`.gdignore` for the results, the web
check on a fresh checkout), `37c6a85` (desktop suite covers the levels), and the last commit
(native smoke on both levels, uncapped pair, vsync recheck, README and this report).
