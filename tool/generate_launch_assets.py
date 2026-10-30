"""Export the existing approved mark and a static wordmark for native/Flutter launch.

Run on macOS with Pillow. No font file is bundled: typography is rendered once
into the shared lockup so it stays identical before and after Flutter starts.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SCALE = 4
SIDE = 240
mark = Image.open(ROOT / "assets/branding/app-icon.png").convert("RGB")
lockup = Image.new("RGB", (SIDE * SCALE, SIDE * SCALE), "black")
lockup.paste(mark.resize((96 * SCALE, 96 * SCALE), Image.Resampling.LANCZOS),
             (72 * SCALE, 72 * SCALE))
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 32 * SCALE)
font.set_variation_by_name("Semibold")
draw = ImageDraw.Draw(lockup)
parts = [("dog", "#F5F5F5"), (".", "#B7F34C"), ("codes", "#F5F5F5")]
x = (SIDE * SCALE - sum(draw.textlength(text, font=font) for text, _ in parts)) / 2
for text, color in parts:
    draw.text((x, 219 * SCALE), text, fill=color, font=font, anchor="ls")
    x += draw.textlength(text, font=font)


def export(image, path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)


export(lockup, ROOT / "assets/branding/launch-lockup.png", SIDE * 3)
ios = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
for scale in [1, 2, 3]:
    suffix = "" if scale == 1 else f"@{scale}x"
    export(lockup, ios / f"LaunchImage{suffix}.png", SIDE * scale)

# Android 12 masks a 288dp icon to its central 192dp circle. The actual 96dp
# mark remains within that safe area and matches Flutter's centered mark.
icon = Image.new("RGB", (288 * SCALE, 288 * SCALE), "black")
icon.paste(mark.resize((96 * SCALE, 96 * SCALE), Image.Resampling.LANCZOS),
           (96 * SCALE, 96 * SCALE))
for density, scale in [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]:
    directory = ROOT / f"android/app/src/main/res/drawable-{density}"
    export(lockup, directory / "splash_lockup.png", round(SIDE * scale))
    export(icon, directory / "splash_icon.png", round(288 * scale))
