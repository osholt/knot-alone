# Offline route endpoint places

`generate_route_places.py` extracts only `populatedPlace` features from the
official OS Open Names CSV download and converts their British National Grid
coordinates to WGS84. The compact result labels saved routes without sending a
sailor's start or finish to a geocoder.

Source: [OS Open Names](https://osdatahub.os.uk/downloads/open/OpenNames), used
under the Open Government Licence. The generated asset carries the required
attribution: “Contains OS data © Crown copyright and database right 2026”.

Regenerate after an intentional dataset update:

```bash
curl -fL 'https://api.os.uk/downloads/v1/products/OpenNames/downloads?area=GB&format=CSV&redirect' -o /tmp/os-open-names.zip
uv run --with pyproj tools/places/generate_route_places.py \
  /tmp/os-open-names.zip \
  apps/mobile/assets/route_places.json \
  --source-version 2026-07
```

The source download is about 100 MB compressed and is not committed. The app
asset is Great Britain-only. A route outside the index receives neutral copy;
it never falls back to a network reverse geocoder.

Run the generator unit test from the repository root with:

```bash
python3 -m unittest tools/places/test_generate_route_places.py
```

## Sailing POIs for the web planner

`generate_sailing_pois.py` converts bounded Overpass JSON exports into the
source-attributed GeoJSON used by `apps/website/planner.html`. It recognises
harbours, marinas, anchorages, small-craft moorings, slipways, boat services,
rescue stations, locks, gates and bridges, then adds the three bundled Solent
tide stations. The committed catalogue is a reproducible starter snapshot, not
an official pilotage directory.

Refresh only after intentionally downloading current Overpass exports for the
documented Solent bounds. Never make the public planner query Overpass on every
map movement.

```sh
python3 tools/places/generate_sailing_pois.py \
  /tmp/tide-and-seek-solent-nodes.json \
  /tmp/tide-and-seek-solent-ways.json \
  /tmp/tide-and-seek-solent-relations.json \
  /tmp/tide-and-seek-solent-moorings.json \
  /tmp/tide-and-seek-solent-ports.json \
  --tide-data apps/mobile/assets/tides/solent_tides.json \
  --output apps/website/data/sailing-pois.geojson

python3 -m unittest tools/places/test_generate_sailing_pois.py
```

## On-demand shallow-depth contours

`tools/contours/generate_emodnet_shallow_contours.py` is an offline diagnostic
that downloads the public EMODnet 2024 mean-depth WCS grid for a bounded area
and derives 2, 5, 10, 20 and 30 m linework with marching squares. The web
planner now performs the same bounded derivation on demand for its current map
view across EMODnet's coverage, so it is not limited to a committed Solent
file. Outside that coverage it derives the same levels from a bounded GEBCO
2026 OPeNDAP subset as a coarser worldwide fallback. Generated linework is model
context, not surveyed marina depth, a charted sounding or an under-keel-clearance
source.

```sh
python3 tools/contours/generate_emodnet_shallow_contours.py \
  --output /tmp/emodnet-shallow-contours.geojson

python3 -m unittest tools/contours/test_generate_emodnet_shallow_contours.py
```
