"""Headless-browser check of the web build (local or the live Vercel URL).

    python3 tests/web_check.py http://localhost:8765/            # quick check
    python3 tests/web_check.py https://<name>.vercel.app/ --run   # + full autopilot run

Checks, each recorded in tests/results/web_check_<host>.json and screenshots in evidence/:
  * every request succeeds (no 4xx/5xx, no failed loads) and there are no page errors
  * the engine boots to the start screen (screenshot)
  * keyboard: Enter starts the run ("[run] started"), Space pops an ollie, audio plays
  * gamepad: a mocked W3C Gamepad API pad (navigator.getGamepads) - button A starts the run
  * audio: Web Audio context running and sample voices started (AudioBufferSourceNode)
  * --run: the autopilot plays the real two-minute run in the browser and the game's own
    end-of-run report must show every goal complete
"""
import json
import os
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Instrument Web Audio and optionally install a fake standard-mapping gamepad before any
# page script runs (Godot enumerates navigator.getGamepads() when its input starts).
INIT_AUDIO = """
(() => {
  window.__audio = {contexts: [], sources: 0, starts: 0};
  const Orig = window.AudioContext || window.webkitAudioContext;
  if (Orig) {
    const Wrapped = function (...a) { const c = new Orig(...a); window.__audio.contexts.push(c); return c; };
    Wrapped.prototype = Orig.prototype;
    window.AudioContext = Wrapped;
    const cbs = Orig.prototype.createBufferSource;
    Orig.prototype.createBufferSource = function () { window.__audio.sources++; return cbs.call(this); };
    const st = AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start = function (...a) { window.__audio.starts++; return st.apply(this, a); };
  }
})();
"""
INIT_PAD = """
(() => {
  const buttons = Array.from({length: 17}, () => ({pressed: false, touched: false, value: 0}));
  const pad = {id: 'Virtual Pad (STANDARD GAMEPAD Vendor: 045e Product: 028e)', index: 0, connected: true,
               mapping: 'standard', timestamp: 0, axes: [0, 0, 0, 0], buttons, vibrationActuator: null};
  window.__pad = pad;
  window.__press = (i, down) => { pad.buttons[i].pressed = down; pad.buttons[i].value = down ? 1 : 0; pad.timestamp = performance.now(); };
  navigator.getGamepads = () => [pad, null, null, null];
})();
"""


def run(url, full_run=False, width=1280, height=720):
    host = urlparse(url).netloc.replace(":", "_")
    shots = os.path.join(ROOT, "evidence")
    os.makedirs(shots, exist_ok=True)
    report = {"url": url, "time": time.strftime("%Y-%m-%dT%H:%M:%S"), "checks": {}, "console_errors": [],
              "failed_requests": [], "requests": 0}

    def check(name, ok, detail=""):
        report["checks"][name] = {"pass": bool(ok), "detail": detail}
        print(("PASS  " if ok else "FAIL  ") + name + (f"  ({detail})" if detail else ""))

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                                          "--autoplay-policy=no-user-gesture-required"])

        def session(pad=False, query=""):
            ctx = browser.new_context(viewport={"width": width, "height": height})
            page = ctx.new_page()
            logs = []
            page.add_init_script(INIT_AUDIO + (INIT_PAD if pad else ""))
            page.on("console", lambda m: logs.append((m.type, m.text)))
            page.on("pageerror", lambda e: report["console_errors"].append("pageerror: " + str(e)))

            def on_response(r):
                report["requests"] += 1
                if r.status >= 400:
                    report["failed_requests"].append(f"{r.status} {r.url}")
            page.on("response", on_response)
            page.on("requestfailed", lambda r: report["failed_requests"].append(f"FAILED {r.url} {r.failure}"))
            page.goto(url + query, wait_until="load", timeout=120000)
            return ctx, page, logs

        def wait_log(page, logs, needle, timeout):
            # page.wait_for_timeout pumps Playwright's event loop (time.sleep would not)
            t0 = time.time()
            while time.time() - t0 < timeout:
                for _, t in logs:
                    if needle in t:
                        return t
                page.wait_for_timeout(250)
            return None

        # --- keyboard session
        ctx, page, logs = session()
        booted = wait_log(page, logs, "Godot Engine", 120) is not None
        page.wait_for_timeout(6000)
        page.screenshot(path=os.path.join(shots, f"web_{host}_start.png"))
        check("engine boots (Godot banner in console)", booted)
        page.mouse.click(width // 2, height // 2)
        page.keyboard.press("Enter")
        started = wait_log(page, logs, "[run] started", 20)
        check("keyboard: Enter starts the run", started is not None)
        page.wait_for_timeout(1500)
        page.keyboard.down("w")
        page.wait_for_timeout(2500)
        page.keyboard.down("Space")
        page.wait_for_timeout(500)
        page.keyboard.up("Space")
        page.wait_for_timeout(1500)
        page.keyboard.up("w")
        page.screenshot(path=os.path.join(shots, f"web_{host}_play.png"))
        audio = page.evaluate("() => ({states: window.__audio.contexts.map(c => c.state), sources: window.__audio.sources, starts: window.__audio.starts})")
        check("audio: Web Audio context running", "running" in audio["states"], str(audio["states"]))
        check("audio: synthesized sample voices play", audio["starts"] >= 3, f"{audio['starts']} voices started")
        report["audio"] = audio
        report["console_keyboard"] = [t for _, t in logs][-40:]
        errs = [t for ty, t in logs if ty == "error" and "ALSA" not in t]
        report["console_errors"] += errs
        ctx.close()

        # --- gamepad session (W3C Gamepad API, mocked)
        ctx, page, logs = session(pad=True)
        wait_log(page, logs, "Godot Engine", 120)
        page.wait_for_timeout(6000)
        page.evaluate("() => window.__press(0, true)")
        page.wait_for_timeout(300)
        page.evaluate("() => window.__press(0, false)")
        started = wait_log(page, logs, "[run] started", 20)
        check("gamepad (Gamepad API): button A starts the run", started is not None)
        page.evaluate("() => { window.__pad.axes[1] = -1; }")
        page.wait_for_timeout(2500)
        page.evaluate("() => window.__press(0, true)")
        page.wait_for_timeout(450)
        page.evaluate("() => window.__press(0, false)")
        page.wait_for_timeout(800)
        page.evaluate("() => window.__press(9, true)")
        page.wait_for_timeout(300)
        page.evaluate("() => window.__press(9, false)")
        page.wait_for_timeout(800)
        paused = wait_log(page, logs, "[run] paused", 5)
        check("gamepad (Gamepad API): Start pauses the run", paused is not None, paused or "")
        page.wait_for_timeout(1500)
        page.screenshot(path=os.path.join(shots, f"web_{host}_gamepad_pause.png"))
        still = [t for _, t in logs if t.startswith("[run] paused")]
        page.evaluate("() => window.__press(0, true)")
        page.wait_for_timeout(300)
        page.evaluate("() => window.__press(0, false)")
        resumed = wait_log(page, logs, "[run] resumed", 5)
        check("pause freezes the clock (resumed at the paused time)", resumed is not None and still and
              resumed.split(" at ")[1] == still[0].split(" at ")[1], f"{still[0] if still else ''} / {resumed}")
        report["console_gamepad"] = [t for _, t in logs][-30:]
        report["console_errors"] += [t for ty, t in logs if ty == "error"]
        ctx.close()

        # --- full autopilot run in the browser
        if full_run:
            ctx, page, logs = session(query="?autopilot&bench")
            fin = wait_log(page, logs, "[run] finished", 900)
            page.screenshot(path=os.path.join(shots, f"web_{host}_end.png"))
            ok = fin is not None and all(f'"{g}", true' in fin for g in ("score", "skate", "tape", "rafters", "windows"))
            check("autopilot two-minute run completes every goal", ok, fin or "no finish line")
            report["run_log"] = [t for _, t in logs if t.startswith(("[run]", "[bench]", "[quality]"))]
            report["console_errors"] += [t for ty, t in logs if ty == "error"]
            ctx.close()
        browser.close()

    check("no failed requests", not report["failed_requests"], "; ".join(report["failed_requests"][:5]))
    check("no page or console errors", not report["console_errors"], "; ".join(report["console_errors"][:5]))
    out = os.path.join(ROOT, "tests", "results", f"web_check_{host}.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    passed = sum(c["pass"] for c in report["checks"].values())
    print(f"{passed}/{len(report['checks'])} checks passed -> {os.path.relpath(out, ROOT)}")
    return all(c["pass"] for c in report["checks"].values())


if __name__ == "__main__":
    ok = run(sys.argv[1], full_run="--run" in sys.argv)
    sys.exit(0 if ok else 1)
