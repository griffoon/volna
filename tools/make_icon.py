"""Draws the Volna app icon: a black field of 0/1 glyphs with an acid wave glowing through it.

Run inside WSL:  /root/umx/venv/bin/python tools/make_icon.py
Writes Resources/AppIcon.png (1024x1024, opaque, as iOS requires).
"""
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
INK = (5, 5, 6)
ACID = (198, 255, 0)
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
CELL = 46  # glyph grid step in pixels; big enough to read at home-screen size

random.seed(7)
out = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"
out.parent.mkdir(exist_ok=True)

font = ImageFont.truetype(FONT_PATH, int(CELL * 0.95))
glyphs = Image.new("RGB", (SIZE, SIZE), INK)
draw = ImageDraw.Draw(glyphs)


def wave_y(x: float, phase: float, amp: float) -> float:
    t = x / SIZE
    return SIZE * 0.52 + amp * math.sin(t * 2 * math.pi * 1.15 + phase) * (0.6 + 0.4 * math.sin(t * math.pi))


cols = SIZE // CELL + 1
rows = SIZE // CELL + 1
for row in range(rows):
    for col in range(cols):
        x = col * CELL + CELL / 2
        y = row * CELL + CELL / 2
        # Distance to the three wave strands; the nearest decides how bright this glyph is.
        d = min(abs(y - wave_y(x, 0.0, 170)),
                abs(y - wave_y(x, 0.9, 120)) * 1.4,
                abs(y - wave_y(x, 1.8, 80)) * 2.0)
        glow = max(0.0, 1.0 - d / 130)
        if glow < 0.04:
            # Faint background field: sparse dots, like the visualizer at rest.
            if random.random() < 0.18:
                draw.text((x, y), ".", font=font, fill=(40, 44, 36), anchor="mm")
            continue
        char = random.choice("01") if glow > 0.25 else random.choice("0.1.")
        level = min(1.0, glow ** 1.1 * 1.25)
        color = tuple(int(INK[i] + (ACID[i] - INK[i]) * level) for i in range(3))
        draw.text((x, y), char, font=font, fill=color, anchor="mm")

# Soft bloom under the glyphs so the wave glows like on the screen.
bloom = glyphs.filter(ImageFilter.GaussianBlur(18))
icon = Image.blend(bloom, glyphs, 0.7)
icon = Image.composite(glyphs, icon, glyphs.convert("L").point(lambda v: 255 if v > 120 else 0))

icon.save(out, "PNG")
print(f"wrote {out}")
