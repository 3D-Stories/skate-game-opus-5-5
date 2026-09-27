"""Headless-browser check of the level select and a downloaded level in the web build.

    python3 tests/web_levels_check.py http://localhost:8797/ [--level baths] [--run]

Checks, recorded in tests/results/web_levels_<host>.json (screenshots in evidence/):
  * the game boots on the default level without fetching any level pack (lean first load)
  * keyboard: Tab opens the level select, Right + Enter picks the level: its pack
    (levels/<id>.pck) downloads (HTTP 200) and mounts, the level loads, Enter starts a run
  * gamepad (a mocked W3C Gamepad API pad): Select, D-pad right, A do the same
  * --run: ?level=<id>&autopilot plays the level's two-minute run in the browser (the pack
    fetched at startup) and the game's end-of-run report shows every goal complete
  * every request succeeds and there are no page or console errors
"""
import json
import os
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from web_check import INIT_AUDIO, INIT_PAD  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(url, level="baths", full_run=False, width=1280, height=720):
    host = urlparse(url).netloc.replace(":", "_")
    shots = os.path.join(ROOT, "evidence")
    goals = [g["id"] for g in json.load(open(os.path.join(ROOT, "levels", level, "level.json")))["game"]["goals"]]
    report = {"url": url, "level": level, "time": time.strftime("%Y-%m-%dT%H:%M:%S"), "checks": {}, "console_errors": [],
              "failed_requests": [], "requests": 0, "downloads": {}}

    def check(name, ok, detail=""):
        report["checks"][name] = {"pass": bool(ok), "detail": detail}
        print(("PASS  " if ok else "FAIL  ") + name + (f"  ({detail})" if detail else ""))

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                                          "--autoplay-policy=no-user-gesture-required"])

        def session(pad=False, query=""):
            ctx = browser.new_context(viewport={"width": width, "height": height})
            page = ctx.new_page()
            logs, packs = [], []
            page.add_init_script(INIT_AUDIO + (INIT_PAD if pad else ""))
            page.on("console", lambda m: logs.append((m.type, m.text)))
            page.on("pageerror", lambda e: report["console_errors"].append("pageerror: " + str(e)))

            def on_response(r):
                report["requests"] += 1
                if r.status >= 400:
                    report["failed_requests"].append(f"{r.status} {r.url}")
                name = r.url.split("?")[0].rsplit("/", 1)[-1]
                if name.endswith(".pck") or name.endswith(".wasm"):
                    report["downloads"][name] = int(r.headers.get("content-length", "0") or 0)
                if name.endswith(".pck") and "/levels/" in r.url:
                    packs.append((r.status, r.url))
            page.on("response", on_response)
            page.on("requestfailed", lambda r: report["failed_requests"].append(f"FAILED {r.url} {r.failure}"))
            page.goto(url + query, wait_until="load", timeout=120000)
            return ctx, page, logs, packs

        def wait_log(page, logs, needle, timeout):
            t0 = time.time()
            while time.time() - t0 < timeout:
                for _, t in logs:
                    if needle in t:
                        return t
                page.wait_for_timeout(250)
            return None

        def pad(page, i, hold=250, after=400):
            page.evaluate(f"() => window.__press({i}, true)")
            page.wait_for_timeout(hold)
            page.evaluate(f"() => window.__press({i}, false)")
            page.wait_for_timeout(after)

        # --- keyboard session
        ctx, page, logs, packs = session()
        booted = wait_log(page, logs, "Godot Engine", 120) is not None
        page.wait_for_timeout(6000)
        check("engine boots to the default level's start screen", booted)
        check("no level pack is fetched at boot (the default level is in index.pck)", not packs, str(packs))
        page.mouse.click(width // 2, height // 2)
        page.keyboard.down("Tab")
        page.wait_for_timeout(200)
        page.keyboard.up("Tab")
        page.wait_for_timeout(1500)
        page.screenshot(path=os.path.join(shots, f"web_levels_{host}_select.png"))
        page.keyboard.press("ArrowRight")
        page.wait_for_timeout(600)
        page.screenshot(path=os.path.join(shots, f"web_levels_{host}_select_{level}.png"))
        t0 = time.time()
        page.keyboard.press("Enter")
        loaded = wait_log(page, logs, f"[level] {level} loaded", 180)
        dt = time.time() - t0
        check(f"keyboard: Tab, Right, Enter picks {level}; its pack downloads and the level loads",
              loaded is not None and any(s == 200 and f"levels/{level}.pck" in u for s, u in packs),
              f"{packs}, loaded after {dt:.1f} s ({report['downloads'].get(level + '.pck', 0) / 1e6:.1f} MB)")
        page.wait_for_timeout(2500)
        page.screenshot(path=os.path.join(shots, f"web_levels_{host}_{level}_start.png"))
        page.keyboard.press("Enter")
        started = wait_log(page, logs, "[run] started", 20)
        check(f"keyboard: Enter starts a run on {level}", started is not None and loaded is not None)
        page.wait_for_timeout(1000)
        page.keyboard.down("w")
        page.wait_for_timeout(3000)
        page.keyboard.up("w")
        page.wait_for_timeout(1500)
        page.screenshot(path=os.path.join(shots, f"web_levels_{host}_{level}_play.png"))
        report["console_keyboard"] = [t for _, t in logs][-30:]
        report["console_errors"] += [t for ty, t in logs if ty == "error" and "ALSA" not in t]
        ctx.close()

        # --- gamepad session (standard mapping: 8 = Select/Back, 15 = D-pad right, 0 = A)
        ctx, page, logs, packs = session(pad=True)
        wait_log(page, logs, "Godot Engine", 120)
        page.wait_for_timeout(6000)
        pad(page, 8, after=1200)
        pad(page, 15, after=600)
        pad(page, 0)
        loaded = wait_log(page, logs, f"[level] {level} loaded", 180)
        check(f"gamepad (Gamepad API): Select, D-pad right, A pick {level} and it loads", loaded is not None, str(packs))
        page.wait_for_timeout(2500)
        pad(page, 0)
        started = wait_log(page, logs, "[run] started", 20)
        check(f"gamepad (Gamepad API): A starts a run on {level}", started is not None and loaded is not None)
        report["console_gamepad"] = [t for _, t in logs][-20:]
        report["console_errors"] += [t for ty, t in logs if ty == "error" and "ALSA" not in t]
        ctx.close()

        # --- the level's full autopilot run in the browser
        if full_run:
            ctx, page, logs, packs = session(query=f"?level={level}&autopilot")
            fin = wait_log(page, logs, "[run] finished", 1200)
            page.screenshot(path=os.path.join(shots, f"web_levels_{host}_{level}_end.png"))
            ok = fin is not None and all(f'"{g}", true' in fin for g in goals)
            check(f"?level={level}&autopilot: the two-minute run completes every goal in the browser", ok, fin or "no finish line")
            report["run_log"] = [t for _, t in logs if t.startswith(("[run]", "[level]", "[quality]"))]
            report["console_errors"] += [t for ty, t in logs if ty == "error" and "ALSA" not in t]
            ctx.close()
        browser.close()

    check("no failed requests", not report["failed_requests"], "; ".join(report["failed_requests"][:5]))
    check("no page or console errors", not report["console_errors"], "; ".join(report["console_errors"][:5]))
    out = os.path.join(ROOT, "tests", "results", f"web_levels_{host}.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    passed = sum(c["pass"] for c in report["checks"].values())
    print(f"{passed}/{len(report['checks'])} checks passed -> {os.path.relpath(out, ROOT)}")
    return all(c["pass"] for c in report["checks"].values())


if __name__ == "__main__":
    a = sys.argv[1:]
    lv = a[a.index("--level") + 1] if "--level" in a else "baths"
    sys.exit(0 if run(a[0], lv, full_run="--run" in a) else 1)
