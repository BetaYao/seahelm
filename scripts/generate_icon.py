#!/usr/bin/env python3
"""Generate the Seahelm app icon from the hand-made source logo.

Loads assets/sea_ship_wheel_logo_2048.png (a ship's-wheel + sea-wave disc on a
transparent field), trims its transparent margins, and centers it on a white
rounded-square badge at every required icon size.
"""

from PIL import Image, ImageDraw
import os
import json

SOURCE_REL = os.path.join("assets", "sea_ship_wheel_logo_2048.png")
BADGE_BG = (255, 255, 255, 255)  # white squircle field (parent "sea" brand)
FILL_FRAC = 0.88                 # logo span as a fraction of the tile
PAD_FRAC = 0.04                  # squircle inset
CORNER_FRAC = 0.225              # squircle corner radius


def _load_trimmed_logo(project_dir):
    src = Image.open(os.path.join(project_dir, SOURCE_REL)).convert("RGBA")
    bbox = src.getchannel("A").getbbox()
    return src.crop(bbox) if bbox else src


def draw_icon(logo, size):
    """Compose the trimmed logo, centered, on a white squircle of `size`px."""
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    pad = int(size * PAD_FRAC)
    ImageDraw.Draw(mask).rounded_rectangle(
        [pad, pad, size - pad, size - pad], radius=int(size * CORNER_FRAC), fill=255
    )
    base.paste(Image.new("RGBA", (size, size), BADGE_BG), (0, 0), mask)

    target = int(size * FILL_FRAC)
    scale = target / max(logo.size)
    art = logo.resize(
        (max(1, int(logo.size[0] * scale)), max(1, int(logo.size[1] * scale))),
        Image.LANCZOS,
    )
    base.alpha_composite(art, ((size - art.size[0]) // 2, (size - art.size[1]) // 2))
    return base


def main():
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    asset_dir = os.path.join(project_dir, "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(asset_dir, exist_ok=True)

    logo = _load_trimmed_logo(project_dir)

    # Render the 1024 master from the source, then each smaller size directly
    # from the source too (sharper than downscaling the master).
    for sz in [1024, 512, 256, 128, 64, 32, 16]:
        icon = draw_icon(logo, sz)
        path = os.path.join(asset_dir, f"icon_{sz}x{sz}.png")
        icon.save(path, "PNG")
        print(f"Saved {path}")

    # Write Contents.json
    contents = {
        "images": [
            {"filename": "icon_16x16.png",     "idiom": "mac", "scale": "1x", "size": "16x16"},
            {"filename": "icon_32x32.png",     "idiom": "mac", "scale": "2x", "size": "16x16"},
            {"filename": "icon_32x32.png",     "idiom": "mac", "scale": "1x", "size": "32x32"},
            {"filename": "icon_64x64.png",     "idiom": "mac", "scale": "2x", "size": "32x32"},
            {"filename": "icon_128x128.png",   "idiom": "mac", "scale": "1x", "size": "128x128"},
            {"filename": "icon_256x256.png",   "idiom": "mac", "scale": "2x", "size": "128x128"},
            {"filename": "icon_256x256.png",   "idiom": "mac", "scale": "1x", "size": "256x256"},
            {"filename": "icon_512x512.png",   "idiom": "mac", "scale": "2x", "size": "256x256"},
            {"filename": "icon_512x512.png",   "idiom": "mac", "scale": "1x", "size": "512x512"},
            {"filename": "icon_1024x1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    contents_path = os.path.join(asset_dir, "Contents.json")
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
    print(f"Saved {contents_path}")

    # Write Assets.xcassets/Contents.json if missing
    xcassets_contents = os.path.join(project_dir, "Assets.xcassets", "Contents.json")
    if not os.path.exists(xcassets_contents):
        with open(xcassets_contents, "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        print(f"Saved {xcassets_contents}")


if __name__ == "__main__":
    main()
