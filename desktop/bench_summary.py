#!/usr/bin/env python3
"""Summarises the Windows and web benchmark runs in tests/results/windows/ as a Markdown table.

    python3 desktop/bench_summary.py [results dir]   -> stdout (bench_all_windows.sh saves it as bench_summary.md)

Per run (<label>.json, <label>.csv or .csv.gz, <label>_load.csv): the bench report's own figures (bench.gd: average fps, median / p95 / p99 frame,
1 % low, frames over 16.7 ms, slowest frame, main-thread CPU per frame), and from the per-frame
CSV the median GPU time and the frames that missed a refresh: longer than 1.5 refresh
intervals (25 ms at 60 Hz). At 60 Hz with vsync every frame takes about 16.7 ms, so "over
16.7 ms" there mostly counts timer jitter of a few microseconds; the missed-refresh count is the
one that shows a visible stutter. GPU load is nvidia-smi's, once a second, for the whole GPU.
"""
import csv
import gzip
import json
import os
import sys

ORDER = ["gl_cold", "gl_vsync", "gl_vsync_r1", "gl_uncapped", "gl_uncapped_r1", "angle_cold", "angle_vsync", "angle_uncapped", "angle_uncapped_ssao_off",
         "angle_uncapped_msaa_off", "gl_uncapped_ssao_off", "gl_uncapped_ssao_off_r1", "gl_fullscreen", "web_vsync", "web_uncapped"]


def main():
    res = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "tests", "results", "windows")
    print("| Run | Renderer | Window | Frames | Average | Median | p95 | p99 | 1 % low | > 16.7 ms | Missed refresh | Slowest | CPU / frame | GPU / frame | GPU load |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for label in ORDER:
        p = os.path.join(res, label + ".json")
        if not os.path.exists(p) or os.path.getsize(p) == 0:
            continue
        text = open(p).read().strip()
        r = json.loads(text) if text.startswith("{\n") else json.loads(text.splitlines()[-1])
        d = r.get("desktop", {})
        hz = d.get("screen_refresh_hz") or 60.0
        if d:
            rend = {"opengl3": "OpenGL 3.3", "opengl3_angle": "ANGLE, D3D11"}.get(d.get("rendering_driver"), d.get("rendering_driver"))
            win = "%s %s, %s, %.0f Hz" % (d.get("window_mode"), r.get("viewport"), "vsync" if d.get("vsync") == "enabled" else "no vsync", hz)
        else:
            rend = "Chrome, WebGL 2 (ANGLE, D3D11)"
            win = "page %s" % r.get("viewport")
        gpu, missed = "-", "-"
        cp = os.path.join(res, label + ".csv")
        if os.path.exists(cp) or os.path.exists(cp + ".gz"):
            rows = list(csv.DictReader(open(cp) if os.path.exists(cp) else gzip.open(cp + ".gz", "rt")))
            g = sorted(float(x["gpu_ms"]) for x in rows if x.get("gpu_ms"))
            if g and g[len(g) // 2] > 0:
                gpu = "%.2f ms" % g[len(g) // 2]
            if d.get("vsync") == "enabled":
                missed = str(sum(1 for x in rows if float(x["frame_ms"]) > 1.5 * 1000.0 / hz))
        load = "-"
        lp = os.path.join(res, label + "_load.csv")
        if os.path.exists(lp):
            u = [float(x["gpu_util_pct"]) for x in csv.DictReader(open(lp)) if x.get("gpu_util_pct", "").replace(".", "").isdigit()]
            if u:
                load = "%.0f %%" % (sum(u) / len(u))
        opts = ", ".join(r.get("options", {}))
        print("| %s%s | %s | %s | %d | %.1f fps | %.2f ms | %.2f ms | %.2f ms | %.1f fps | %d | %s | %.1f ms | %.2f ms | %s | %s |" % (
            label, " (%s)" % opts if opts else "", rend, win, r["frames"], r["avg_fps"], r["median_ms"], r["p95_ms"], r["p99_ms"],
            r["one_pct_low_fps"], r["frames_over_16_7ms"], missed, r["max_ms"], r["cpu_ms_mean"], gpu, load))


if __name__ == "__main__":
    main()
