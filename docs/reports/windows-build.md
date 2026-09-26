# Windows desktop build: report

Branch `windows-build`, worktree `.worktrees/windows-build`, 2026-09-26. Built in WSL on "pc"
(i9-12900KF, RTX 4080, Windows 11 26200, NVIDIA 610.74) and tested natively on its Windows
side. The CI VM "nillerkgames" was not needed and not used: Godot exports Windows builds from
Linux.

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
- The web export is byte-for-byte unchanged (all 9 files, all 508 pck entries).
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
2. **Vsync depends on the display setup.** Earlier in the day, with a 30 Hz virtual monitor as
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

- `.gitignore`: `build/windows/`, `tests/results/windows/*.png`, `tests/results/windows/fs_shots/`.
- `export_presets.cfg`: new `[preset.1]` "Windows Desktop" appended; the Web preset unchanged.
- `tests/run_all.sh`: runs `desktop/test_desktop.sh` as a 12th suite (one line, one name in
  the summary loop).
- `tests/chrome_bench.sh`: `CHROME_POS` and `BENCH_OUT` (defaults unchanged), because the
  hard-coded window position is off-screen in today's monitor layout.
- `README.md`: a Commands row, the suite count, an Evidence row, and the new "Windows build"
  section at the end.
- Everything else is new: `desktop/**`, `tests/pck_diff.py`, `tests/web_export_unchanged.sh`,
  `tests/results/{desktop.txt, web_export_unchanged.txt, run_all_windows_branch.txt,
  windows_fullrun.txt, windows/**}`, `tests/results/logs/desktop*`, `evidence/windows_*.jpg`,
  this report. No game script, scene, shader, asset or `project.godot` changed.
- Outside the repo: the four Windows templates added to
  `~/.local/share/godot/export_templates/4.7.2.stable/`, the tpz cache in
  `~/src/godot-templates-4.7.2/`, the stage in `~/.cache/proskater-windows/`, and on Windows
  `C:\Temp\ProSkater\` (the test copy and outputs) and `%APPDATA%\ProSkater` (the game's shader
  cache and logs; the saved window choice was removed after the tests).

## Commits

See `git log 696364b..windows-build`: `baa976d` (preset, templates, desktop layer, staged
export), `ad25285` (desktop tests, Alt+Enter, quit-at-end), `5a4969d` (native harness),
`dda0414` (native results), and the final commit with this report and the README section.
