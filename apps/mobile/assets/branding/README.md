# Tide and Seek app icon

`tide-and-seek-app-icon-master.png` is the 1024px opaque square master and the
source of truth. Derivative iOS and Android sizes are generated from it and
checked into their platform asset folders.

`tide-and-seek-google-play-icon.png` is the checked-in 512px opaque derivative
for the Google Play store listing. Regenerate it from the master rather than
editing it independently.

`tide-and-seek-google-play-feature-graphic.png` is the 1024×500 Google Play
feature graphic. The four 1080×1920 files in `play-store/` are field-test
screenshots covering onboarding, the chart home, a simulated live voyage, and
the MOB recovery view. The voyage screenshot uses simulator data rather than
claiming a live network AIS feed.

## The mark

A masthead sloop low and left, a flybridge motor cruiser high and right, and
two chevrons carrying the eye from one to the other. It keeps the composition
of the inherited Tail End Charlie relay mark — hero vessel in the foreground,
follower behind, direction of travel between them — with the two adventure
motorcycles replaced by vessels and the purple field replaced by green.

Original artwork. It carries no manufacturer's trademarks, badging or model
names, and no builder's design cues beyond the generic proportions of a modern
production cruiser.

| Role | Hex |
|---|---|
| Field | `#0C6B4F` |
| Hero vessel | `#FDF6E3` |
| Follower | `#9FD2BE` |
| Chevrons | `#F5C542` |

## Provenance, and what that costs

The master is a **generated raster**, not vector art. Two consequences worth
knowing before editing it:

- It cannot be scaled beyond 1254px, which is the size it was generated at.
  1024 is a downscale, so there is no headroom for a larger asset.
- There is a faint vignette in the field rather than a perfectly flat fill. It
  is invisible at icon sizes and was left alone.

Changing the mark therefore means regenerating it rather than editing paths.
The prompt that produced it is recorded below so that is reproducible.

> Generate a square 1024x1024 flat-vector mobile app icon, solid fills only,
> crisp edges, no gradients, no shadows, no texture, no text, no outline
> border, bold enough to read at 40px. Background: solid green #0C6B4F filling
> the whole square. Lower left, LARGE, in cream #FDF6E3: a stylised modern
> production sailing yacht in side profile with the bow pointing RIGHT — a 40ft
> cruiser like a Bavaria, near-plumb bow, long low hull, low coachroof, one
> mast, with a clearly SEPARATE mainsail behind the mast and an overlapping
> genoa in front of the mast, plus a fin keel under the hull; the mast must
> read as a distinct line and the two sails must not merge into a single
> triangle. Upper right, about half the size, in pale sea green #9FD2BE: a
> stylised flybridge motor cruiser in side profile, bow also pointing RIGHT,
> raked windscreen, small flybridge. Between the two boats, in yellow #F5C542:
> two chevrons like >> pointing right, from the yacht towards the motor
> cruiser. Separate every shape from its neighbours with a thin gap of the
> green background so the silhouettes stay legible, and keep a comfortable
> margin so nothing touches the edges. No people, no birds, no sun, no waves,
> nothing else in the frame.

Two things that went wrong generating it, so they are not repeated:

- A multi-paragraph prompt submits at the first newline, so only the opening
  sentence arrived and the model filled the rest from unrelated context. Send
  the whole brief as one line.
- The image download control next to a later image saved the *earlier* one.
  Fetch the specific image instead of trusting the button.

## Re-rendering the derivatives

```bash
cd apps/mobile
python3 - <<'PY'
import json, subprocess, pathlib
MASTER = 'assets/branding/tide-and-seek-app-icon-master.png'
iconset = pathlib.Path('ios/Runner/Assets.xcassets/AppIcon.appiconset')
seen = set()
for img in json.load(open(iconset / 'Contents.json'))['images']:
    fn, size, scale = img.get('filename'), img['size'], img['scale']
    if not fn or fn in seen:
        continue
    seen.add(fn)
    px = round(float(size.split('x')[0]) * int(scale.rstrip('x')))
    # iOS rejects an app icon with an alpha channel.
    subprocess.run(['magick', MASTER, '-resize', f'{px}x{px}',
                    '-background', '#0C6B4F', '-alpha', 'remove', '-alpha', 'off',
                    str(iconset / fn)], check=True)
for d, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
              'xxhdpi': 144, 'xxxhdpi': 192}.items():
    subprocess.run(['magick', MASTER, '-resize', f'{px}x{px}',
                    f'android/app/src/main/res/mipmap-{d}/ic_launcher.png'],
                   check=True)
subprocess.run(['magick', MASTER, '-resize', '512x512', '-strip',
                'assets/branding/tide-and-seek-google-play-icon.png'],
               check=True)
PY
```

Requires `imagemagick`.

The feature graphic was generated from the checked-in Play icon as its visual
reference, then centre-cropped and downscaled to exactly 1024×500. Its prompt
requested the same emerald, cream, mint, and gold palette; a foreground sailing
yacht; a companion motor vessel; subtle chart contours and route line; and no
text, device frame, or third-party mark.
