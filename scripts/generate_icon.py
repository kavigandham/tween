#!/usr/bin/env python3
"""Generate the Tween app icon: a 1024x1024 PNG with a teal background and a
centered white "T".

Tween's brand teal is #008C8C (see Shared/Tokens.swift). The App Store and the
asset catalog both want a flat 1024x1024 master with no alpha and no rounded
corners — iOS applies the mask itself.

Usage:
    python3 scripts/generate_icon.py [output_path]

Defaults to writing ./AppIcon.png. The collaborator drops the result into the
asset catalog (or replaces it with hand-drawn artwork) on a Mac.

Requires Pillow:  pip install Pillow
"""

import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("This script needs Pillow. Install it with:  pip install Pillow")

SIZE = 1024
TEAL = (0, 140, 140)        # #008C8C — Tokens.Palette.brand
WHITE = (255, 255, 255)


def _load_font(size):
    """Find a bold sans-serif on this machine, falling back to Pillow's default."""
    candidates = [
        "/System/Library/Fonts/Helvetica.ttc",          # macOS
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        "C:/Windows/Fonts/arialbd.ttf",                  # Windows
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",  # Linux
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except (OSError, IOError):
            continue
    return ImageFont.load_default()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"

    # No alpha: the App Store rejects icons with transparency.
    img = Image.new("RGB", (SIZE, SIZE), TEAL)
    draw = ImageDraw.Draw(img)

    font = _load_font(int(SIZE * 0.62))

    # Center the glyph on its actual ink bounds, not the font's metric box, so
    # the bar of the "T" sits optically centered.
    left, top, right, bottom = draw.textbbox((0, 0), "T", font=font)
    x = (SIZE - (right - left)) / 2 - left
    y = (SIZE - (bottom - top)) / 2 - top
    draw.text((x, y), "T", font=font, fill=WHITE)

    img.save(out, "PNG")
    print(f"Wrote {out} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
