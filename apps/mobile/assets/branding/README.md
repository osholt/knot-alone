# Tide and Seek app icon

`tide-and-seek-icon.svg` is the source of truth. Everything else is generated
from it, so edit the SVG and re-render rather than touching a PNG.

`tide-and-seek-app-icon-master.png` is the 1024px opaque square master.
Derivative iOS and Android sizes are checked into their platform asset folders.

## The mark

A masthead sloop low and left, a flybridge motor cruiser high and right, and
two chevrons carrying the eye from one to the other. It keeps the composition
of the inherited Tail End Charlie relay mark — hero vessel in the foreground,
follower behind, direction of travel between them — with the two adventure
motorcycles replaced by vessels and the purple field replaced by green.

Original artwork. It uses no manufacturer's trademarks, badging or model
names, and no Bavaria or other builder's design cues beyond the generic
proportions of a modern production cruiser.

## Re-rendering

```bash
cd apps/mobile
python3 - <<'PY'
import json, subprocess, pathlib
SVG = 'assets/branding/tide-and-seek-icon.svg'
iconset = pathlib.Path('ios/Runner/Assets.xcassets/AppIcon.appiconset')
seen = set()
for img in json.load(open(iconset / 'Contents.json'))['images']:
    fn, size, scale = img.get('filename'), img['size'], img['scale']
    if not fn or fn in seen:
        continue
    seen.add(fn)
    px = round(float(size.split('x')[0]) * int(scale.rstrip('x')))
    subprocess.run(['rsvg-convert', '-w', str(px), '-h', str(px), SVG,
                    '-o', str(iconset / fn)], check=True)
for d, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
              'xxhdpi': 144, 'xxxhdpi': 192}.items():
    subprocess.run(['rsvg-convert', '-w', str(px), '-h', str(px), SVG, '-o',
                    f'android/app/src/main/res/mipmap-{d}/ic_launcher.png'],
                   check=True)
PY
# iOS rejects an app icon with an alpha channel.
for f in ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png; do
  magick "$f" -background "#0C6B4F" -alpha remove -alpha off "$f"
done
rsvg-convert -w 1024 -h 1024 assets/branding/tide-and-seek-icon.svg \
  -o assets/branding/tide-and-seek-app-icon-master.png
```

Requires `librsvg` and `imagemagick`.

## Palette

| Role | Hex |
|---|---|
| Field | `#0C6B4F` |
| Hero vessel | `#FDF6E3` |
| Follower | `#9FD2BE` |
| Chevrons | `#F5C542` |

Every shape is outlined in the field colour. Without that, the mainsail, genoa
and hull share a fill, fuse into one silhouette, and the rig disappears — which
is what the first two drafts did.
