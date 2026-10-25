#!/usr/bin/env python3
"""Assemble the SnipClip Mac App Preview (1920x1080, 30fps, H.264 + silent stereo AAC).
Each clip: trim (start/dur) -> crop (x,y,w,h px, 2:1 aspect) -> 1680x840 box on the navy
background with rounded corners -> caption overlay. Clips joined with 0.35s crossfades."""
import json, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
HERE = Path(__file__).parent; B = HERE / "build"; B.mkdir(exist_ok=True)
SB = json.loads((HERE / "storyboard.json").read_text())
W, H, BX, BY, BW, BH, R, XF = 1920, 1080, 120, 210, 1680, 840, 22, 0.35

def backgrounds():
    bg = Image.new("RGB", (W, H), "#0d1f3d")
    glow = Image.new("RGB", (W, H), "#0d1f3d"); d = ImageDraw.Draw(glow)
    d.ellipse((-400, -700, 1300, 500), fill="#1f4a8a"); d.ellipse((900, 500, 2600, 1700), fill="#16376b")
    bg = Image.blend(bg, glow.filter(ImageFilter.GaussianBlur(220)), 0.85)
    shadow = Image.new("L", (W, H), 0); ImageDraw.Draw(shadow).rounded_rectangle((BX, BY + 18, BX + BW, BY + BH + 18), R, fill=150)
    bg = Image.composite(Image.new("RGB", (W, H), "#050b18"), bg, shadow.filter(ImageFilter.GaussianBlur(28)))
    bg.save(B / "bg.png")
    hole = Image.new("L", (W, H), 255); ImageDraw.Draw(hole).rounded_rectangle((BX, BY, BX + BW, BY + BH), R, fill=0)
    mask = bg.copy().convert("RGBA"); mask.putalpha(hole); mask.save(B / "mask.png")

def clip(c):
    out = B / f"{c['name']}.mp4"
    x, y, w, h = c["crop"]
    sp = c.get("speed", 1.0); out_d = round(c["dur"] / sp, 3)
    vf = (f"[0:v]trim=start={c['start']}:duration={c['dur']},setpts=(PTS-STARTPTS)/{sp},fps=30,"
          f"crop={w}:{h}:{x}:{y},scale={BW}:{BH}:flags=lanczos[f];"
          f"[1:v][f]overlay={BX}:{BY}[a];[a][2:v]overlay=0:0[b];[b][3:v]overlay=0:0,format=yuv420p[v]")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(HERE / "raw" / f"{c['name']}.mov"),
                    "-loop", "1", "-i", str(B / "bg.png"), "-loop", "1", "-i", str(B / "mask.png"),
                    "-loop", "1", "-i", str(B / "captions" / f"{c['name']}.png"),
                    "-filter_complex", vf, "-map", "[v]", "-t", str(out_d), "-an",
                    "-c:v", "libx264", "-preset", "slow", "-crf", "16", str(out)], check=True)
    return out, out_d

def join(parts):
    ins, fl, prev, t = [], [], "0:v", 0.0
    for p, _ in parts: ins += ["-i", str(p)]
    for i in range(1, len(parts)):
        t += parts[i - 1][1] - XF
        fl.append(f"[{prev}][{i}:v]xfade=transition=fade:duration={XF}:offset={t:.3f}[x{i}]"); prev = f"x{i}"
    total = sum(d for _, d in parts) - XF * (len(parts) - 1)
    out = HERE / "SnipClip-AppPreview-1920x1080.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *ins, "-f", "lavfi", "-t", f"{total:.3f}", "-i", "anullsrc=r=44100:cl=stereo",
                    "-filter_complex", ";".join(fl), "-map", f"[{prev}]", "-map", f"{len(parts)}:a",
                    "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p",
                    "-r", "30", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", "-shortest", str(out)], check=True)
    print(f"{out.name}: {total:.2f}s")

backgrounds()
join([clip(c) for c in SB["clips"]])
