"""Headless-browser check of the character builder in the web build (local or live).

    python3 tests/web_check_builder.py http://localhost:8765/

Checks, recorded in tests/results/web_check_builder_<host>.json, screenshots in evidence/:
  * a fresh browser starts with today's skater (nothing saved)
  * keyboard: C opens the Skater screen, Right picks the female skater, Down + Right her tee,
    live on the turntable; Enter saves it
  * the choice persists in the browser's user:// (IndexedDB): after a reload the game
    starts as her, and Enter starts the run with her
  * gamepad (a mocked W3C Gamepad API pad): Y opens the screen, the D-pad changes it, A saves
  * ?skater=... in the URL picks a skater for that visit
  * every request succeeds and there are no page errors
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
DEFAULT = "male,hoodie,jeans,suede,none"


def run(url, width=1280, height=720):
    host = urlparse(url).netloc.replace(":", "_")
    shots = os.path.join(ROOT, "evidence")
    os.makedirs(shots, exist_ok=True)
    report = {"url": url, "time": time.strftime("%Y-%m-%dT%H:%M:%S"), "checks": {}, "console_errors": [],
              "failed_requests": [], "requests": 0, "console": {}}

    def check(name, ok, detail=""):
        report["checks"][name] = {"pass": bool(ok), "detail": detail}
        print(("PASS  " if ok else "FAIL  ") + name + (f"  ({detail})" if detail else ""))

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                                          "--autoplay-policy=no-user-gesture-required"])

        def context(pad=False):
            ctx = browser.new_context(viewport={"width": width, "height": height})
            ctx.add_init_script(INIT_AUDIO + (INIT_PAD if pad else ""))
            return ctx

        def open_page(ctx, query=""):
            page = ctx.new_page()
            logs = []
            page.on("console", lambda m: logs.append(m.text))
            page.on("pageerror", lambda e: report["console_errors"].append("pageerror: " + str(e)))

            def on_response(r):
                report["requests"] += 1
                if r.status >= 400:
                    report["failed_requests"].append(f"{r.status} {r.url}")
            page.on("response", on_response)
            page.on("requestfailed", lambda r: report["failed_requests"].append(f"FAILED {r.url} {r.failure}"))
            page.goto(url + query, wait_until="load", timeout=120000)
            return page, logs

        def wait_log(page, logs, needle, timeout, start=0):
            t0 = time.time()
            while time.time() - t0 < timeout:
                for t in logs[start:]:
                    if needle in t:
                        return t
                page.wait_for_timeout(250)
            return None

        def key(page, k, settle=900):
            page.keyboard.press(k)
            page.wait_for_timeout(settle)

        def pad(page, i, settle=900):
            page.evaluate(f"() => window.__press({i}, true)")
            page.wait_for_timeout(150)
            page.evaluate(f"() => window.__press({i}, false)")
            page.wait_for_timeout(settle)

        # --- keyboard: a fresh browser, today's skater, then her
        ctx = context()
        page, logs = open_page(ctx)
        first = wait_log(page, logs, "[skater] skating as", 180)
        check("a fresh browser starts with today's skater", first is not None and first.endswith(DEFAULT), first or "no log")
        page.wait_for_timeout(5000)
        page.screenshot(path=os.path.join(shots, f"web_builder_{host}_start.png"))
        n = len(logs)
        key(page, "c", 2500)
        opened = wait_log(page, logs, "[skater] screen open", 30, n)
        check("keyboard: C opens the Skater screen", opened is not None, opened or "no log")
        page.wait_for_timeout(3000)
        page.screenshot(path=os.path.join(shots, f"web_builder_{host}_open.png"))
        n = len(logs)
        key(page, "ArrowRight", 3000)
        her = wait_log(page, logs, "[skater] preview female", 30, n)
        check("Right picks the female skater, live on the turntable", her is not None, her or "no log")
        key(page, "ArrowDown")
        n = len(logs)
        key(page, "ArrowRight", 3000)
        tee = wait_log(page, logs, "[skater] preview female,tee", 30, n)
        check("Down, Right: her tee", tee is not None, tee or "no log")
        page.wait_for_timeout(2500)
        page.screenshot(path=os.path.join(shots, f"web_builder_{host}_female_tee.png"))
        n = len(logs)
        key(page, "Enter", 3000)
        saved = wait_log(page, logs, "[skater] saved female,tee", 30, n)
        check("Enter saves her", saved is not None, saved or "no log")
        page.wait_for_timeout(4000)                 # (the web filesystem syncs to IndexedDB)
        report["console"]["keyboard"] = [t for t in logs if t.startswith("[")][-20:]
        page.close()
        # the same browser, the next visit
        page, logs = open_page(ctx)
        again = wait_log(page, logs, "[skater] skating as", 180)
        check("after a reload the saved skater comes back (user:// in IndexedDB)", again is not None and "female,tee" in again,
              again or "no log")
        page.wait_for_timeout(5000)
        n = len(logs)
        key(page, "Enter", 1500)
        started = wait_log(page, logs, "[run] started", 30, n)
        check("Enter starts the run with her", started is not None)
        page.keyboard.down("w")
        page.wait_for_timeout(2500)
        page.keyboard.up("w")
        page.screenshot(path=os.path.join(shots, f"web_builder_{host}_run.png"))
        report["console"]["reload"] = [t for t in logs if t.startswith("[")][-20:]
        page.close()
        ctx.close()

        # --- gamepad: a fresh browser with a mocked standard pad
        ctx = context(pad=True)
        page, logs = open_page(ctx)
        wait_log(page, logs, "[skater] skating as", 180)
        page.wait_for_timeout(5000)
        n = len(logs)
        pad(page, 3, 2500)                          # Y
        opened = wait_log(page, logs, "[skater] screen open", 30, n)
        check("gamepad: Y opens the Skater screen", opened is not None, opened or "no log")
        n = len(logs)
        pad(page, 15, 3000)                         # D-pad right
        her = wait_log(page, logs, "[skater] preview female", 30, n)
        check("gamepad: the D-pad picks the female skater", her is not None, her or "no log")
        n = len(logs)
        pad(page, 0, 3000)                          # A
        saved = wait_log(page, logs, "[skater] saved female", 30, n)
        check("gamepad: A saves her", saved is not None, saved or "no log")
        report["console"]["gamepad"] = [t for t in logs if t.startswith("[")][-20:]
        page.close()
        ctx.close()

        # --- the URL option
        ctx = context()
        page, logs = open_page(ctx, "?skater=female,flannel,cargo,hitop,beanie")
        q = wait_log(page, logs, "[skater] skating as", 180)
        check("?skater= picks the skater for the visit", q is not None and q.endswith("female,flannel,cargo,hitop,beanie"), q or "no log")
        page.wait_for_timeout(5000)
        page.screenshot(path=os.path.join(shots, f"web_builder_{host}_url_option.png"))
        page.close()
        ctx.close()
        browser.close()

    check("no failed requests", not report["failed_requests"], "; ".join(report["failed_requests"][:5]))
    check("no page or console errors", not report["console_errors"], "; ".join(report["console_errors"][:5]))
    out = os.path.join(ROOT, "tests", "results", f"web_check_builder_{host}.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    passed = sum(c["pass"] for c in report["checks"].values())
    print(f"{passed}/{len(report['checks'])} checks passed -> {os.path.relpath(out, ROOT)}")
    return all(c["pass"] for c in report["checks"].values())


if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1]) else 1)
