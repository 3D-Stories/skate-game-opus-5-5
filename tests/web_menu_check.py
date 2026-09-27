#!/usr/bin/env python3
"""Headless-browser check of the start screen menu and the saved game in the web build.

    python3 tests/web_menu_check.py http://localhost:8765/     (build/web served there)
    python3 tests/web_menu_check.py https://skate-game-opus-5-5-blush.vercel.app/

A fresh browser: Resume game is greyed out; the mouse clicks Level select and Controls (Esc
comes back from each); Enter on Start new game starts a run. The same browser, next visit:
the saved game is back (user:// in IndexedDB), Resume game is picked and Enter starts its
run; the pause menu's Main menu (clicked) leaves the run; Start new game asks first and a
click on Yes starts over. The menu logs where each choice is ("[menu] start: id@x,y ..." as
fractions of the screen), which is where the mouse clicks.
Writes tests/results/web_menu_<host>.json and evidence/web_menu_<host>_*.png.
"""
import json
import os
import re
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from web_check import INIT_AUDIO  # noqa: E402

MENU = re.compile(r"^\[menu\] (start|pause|end|controls|confirm): (.*)  picked (\S*)$")


def parse(line):
    """'[menu] start: resume_game(off)@0.3,0.4 ...  picked new_game' -> screen, {id: (x, y, on)}, picked"""
    m = MENU.match(line)
    items = {}
    for part in m.group(2).split():
        name, xy = part.split("@")
        x, y = (float(v) for v in xy.split(","))
        items[name.replace("(off)", "")] = (x, y, "(off)" not in name)
    return m.group(1), items, m.group(3)


def run(url, width=1280, height=720):
    host = urlparse(url).netloc.replace(":", "_")
    shots = os.path.join(ROOT, "evidence")
    report = {"url": url, "time": time.strftime("%Y-%m-%dT%H:%M:%S"), "checks": {}, "console_errors": [],
              "failed_requests": [], "console": {}}

    def check(name, ok, detail=""):
        report["checks"][name] = {"pass": bool(ok), "detail": detail}
        print(("PASS  " if ok else "FAIL  ") + name + (f"  ({detail})" if detail else ""))

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                                          "--autoplay-policy=no-user-gesture-required"])
        ctx = browser.new_context(viewport={"width": width, "height": height})
        ctx.add_init_script(INIT_AUDIO)

        def open_page():
            page = ctx.new_page()
            logs = []
            page.on("console", lambda m: logs.append(m.text))
            page.on("pageerror", lambda e: report["console_errors"].append("pageerror: " + str(e)))
            page.on("response", lambda r: r.status >= 400 and report["failed_requests"].append(f"{r.status} {r.url}"))
            page.on("requestfailed", lambda r: report["failed_requests"].append(f"FAILED {r.url} {r.failure}"))
            page.goto(url, wait_until="load", timeout=120000)
            return page, logs

        def wait_log(page, logs, needle, timeout, start=0):
            t0 = time.time()
            while time.time() - t0 < timeout:
                for t in logs[start:]:
                    if needle in t:
                        return t
                page.wait_for_timeout(250)
            return None

        def menu(page, logs, screen, start, timeout=60):
            """The next menu layout line for `screen` after log index `start`."""
            t0 = time.time()
            while time.time() - t0 < timeout:
                for t in logs[start:]:
                    if t.startswith(f"[menu] {screen}: "):
                        return parse(t)
                page.wait_for_timeout(250)
            return None, {}, ""

        def click(page, items, name, settle=1500):
            x, y, _ = items[name]
            page.mouse.move(x * width, y * height)
            page.wait_for_timeout(300)
            page.mouse.click(x * width, y * height)
            page.wait_for_timeout(settle)

        def key(page, k, settle=1200):
            page.keyboard.press(k)
            page.wait_for_timeout(settle)

        # --- a fresh browser
        page, logs = open_page()
        _, items, picked = menu(page, logs, "start", 0, 180)
        check("a fresh browser opens on the start menu: Resume game greyed out, Start new game picked",
              list(items) == ["resume_game", "new_game", "level", "skater", "controls"] and not items["resume_game"][2]
              and picked == "new_game", f"{list(items)}, picked {picked}")
        page.wait_for_timeout(4000)
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_start.png"))
        n = len(logs)
        click(page, items, "level", 2500)
        check("the mouse: a click on Level select opens it", wait_log(page, logs, "[menu] level", 20, n) is not None)
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_level_select.png"))
        n = len(logs)
        key(page, "Escape", 2000)
        _, items, picked = menu(page, logs, "start", n)
        check("Esc comes back to the start menu", bool(items), f"picked {picked}")
        n = len(logs)
        click(page, items, "controls", 2000)
        scr, _, _ = menu(page, logs, "controls", n)
        check("a click on Controls opens the controls screen", scr == "controls")
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_controls.png"))
        n = len(logs)
        key(page, "Escape", 2000)
        _, items, picked = menu(page, logs, "start", n)
        check("Esc goes back from Controls", bool(items) and picked == "controls", f"picked {picked}")
        key(page, "ArrowUp")                       # Controls -> Customize character -> Level select -> Start new game
        key(page, "ArrowUp")
        key(page, "ArrowUp")
        n = len(logs)
        key(page, "Enter", 2000)
        started = wait_log(page, logs, "[run] started", 30, n)
        check("the keyboard: Up to Start new game, Enter starts a run",
              wait_log(page, logs, "[menu] new_game", 5, n) is not None and started is not None)
        page.wait_for_timeout(5000)                # (the web filesystem syncs user:// to IndexedDB)
        report["console"]["first_visit"] = [t for t in logs if t.startswith("[")][-25:]
        page.close()

        # --- the same browser, the next visit: the saved game
        page, logs = open_page()
        _, items, picked = menu(page, logs, "start", 0, 180)
        check("after a reload the saved game is back: Resume game on and picked",
              items.get("resume_game", (0, 0, False))[2] and picked == "resume_game", f"picked {picked}")
        page.wait_for_timeout(4000)
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_saved.png"))
        n = len(logs)
        key(page, "Enter", 2000)
        check("Enter on Resume game starts its run", wait_log(page, logs, "[menu] resume_game", 5, n) is not None
              and wait_log(page, logs, "[run] started", 30, n) is not None)
        page.wait_for_timeout(1500)
        n = len(logs)
        key(page, "Escape", 1500)
        _, items, picked = menu(page, logs, "pause", n)
        check("Esc: the pause menu with Resume, Restart run, Main menu", list(items) == ["resume_run", "restart", "main_menu"], str(list(items)))
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_pause.png"))
        n = len(logs)
        click(page, items, "main_menu", 2500)
        _, items, picked = menu(page, logs, "start", n)
        check("a click on Main menu leaves the run for the start menu",
              wait_log(page, logs, "[run] left for the main menu", 10, n) is not None and bool(items))
        key(page, "ArrowDown")
        n = len(logs)
        key(page, "Enter", 1500)
        _, items, picked = menu(page, logs, "confirm", n)
        check("Start new game with a save asks first (No picked)", list(items) == ["no_keep", "yes_new"] and picked == "no_keep",
              f"{list(items)}, picked {picked}")
        page.screenshot(path=os.path.join(shots, f"web_menu_{host}_confirm.png"))
        n = len(logs)
        click(page, items, "yes_new", 2000)
        check("a click on Yes starts over with a run", wait_log(page, logs, "[menu] yes_new", 5, n) is not None
              and wait_log(page, logs, "[run] started", 30, n) is not None)
        report["console"]["second_visit"] = [t for t in logs if t.startswith("[")][-25:]
        page.close()
        browser.close()

    check("no failed requests", not report["failed_requests"], "; ".join(report["failed_requests"][:3]))
    check("no page or console errors", not report["console_errors"], "; ".join(report["console_errors"][:3]))
    ok = all(c["pass"] for c in report["checks"].values())
    out = os.path.join(ROOT, "tests", "results", f"web_menu_{host}.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=1)
    print(f"{sum(c['pass'] for c in report['checks'].values())}/{len(report['checks'])} checks passed -> {os.path.relpath(out, ROOT)}")
    return ok


if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1]) else 1)
