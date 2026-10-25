#!/usr/bin/env python3
"""Render 1920x1080 caption overlays (transparent PNG) in the screenshot set's fonts/colours."""
import json, sys
from pathlib import Path
from playwright.sync_api import sync_playwright
HERE = Path(__file__).parent
CAPS = json.loads((HERE / "storyboard.json").read_text())["clips"]
HTML = """<html><head><link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@800&family=Inter:wght@700;800&display=block" rel="stylesheet">
<style>html,body{margin:0;width:1920px;height:1080px;background:transparent}
.k{position:absolute;top:44px;width:100%;text-align:center;font:800 26px Inter;letter-spacing:.14em;text-transform:uppercase;color:#6FA8FF}
.h{position:absolute;top:84px;width:100%;text-align:center;font:800 76px 'Plus Jakarta Sans';color:#fff;letter-spacing:-.01em}
.h em{font-style:normal;color:#6FA8FF}</style></head><body><div class=k>{k}</div><div class=h>{h}</div></body></html>"""
out = HERE / "build" / "captions"; out.mkdir(parents=True, exist_ok=True)
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome"); pg = b.new_page(viewport={"width": 1920, "height": 1080})
    for c in CAPS:
        h = c["caption"].replace("*", "<em>", 1).replace("*", "</em>", 1)
        pg.set_content(HTML.replace("{k}", c.get("kicker", "")).replace("{h}", h)); pg.wait_for_timeout(800)
        pg.screenshot(path=str(out / f"{c['name']}.png"), omit_background=True)
        print("caption", c["name"])
    b.close()
