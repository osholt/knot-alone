# Tide and Seek website and passage planner

The static website contains the public product page and the first browser
passage-planner slice. It reuses the successful Tail End Charlie planner
principles — no framework, no analytics, first-party local drafts, GPX fallback
and a short plan-code handoff — without carrying over road routing, traffic,
motorcycle preferences or cafe discovery.

`planner.html` provides:

- draggable and reorderable marine waypoints;
- rhumb-line true course, nautical-mile distance and time from an explicit
  speed assumption;
- bounded GPX import/export compatible with the mobile parser;
- optional short plan-code publishing through `/api/v1/plans`;
- OpenFreeMap general context and a toggleable OpenSeaMap seamark overlay;
- toggleable EMODnet Bathymetry DTM 2024 depth shading with three transparent
  water-only palettes, on-demand 2/5/10/20/30 m contours dynamically traced at
  screen resolution from the same official multicolour shading surface throughout
  its North Atlantic and European coverage, a coarser GEBCO 2026 fallback elsewhere
  in the world, and EMODnet's generalised 50 m-and-deeper European overlay;
- a zoom-adaptive wind field with downwind arrows, speed/time labels, gust detail,
  a purple passage-time halo near the route and explicit model—not observation—wording;
- a locally entered passage start time, 15-minute time-of-day slider, hour/day
  step controls and a zoom-adaptive model-current field filtered to basemap water:
  teal arrows use current time away from the route, then blend through blue to
  purple at the expected nearest-route time within 8 NM;
- current samples about every 2.5 NM for a current-adjusted passage estimate,
  amber course-to-steer arrows and a dashed model track showing the drift that
  results if each planned ground-track bearing is held without correction;
- tide-adjusted shallow-contour labels where the source depth datum can be
  reconciled: the Solent uses the bundled TICON-4 MSL/LAT offsets with the
  Open-Meteo model sea level, while unsupported datum combinations remain
  visibly unadjusted;
- a map tide table derived from smoothed Open-Meteo sea-level extrema, plus a
  destination daylight chart showing sunrise, sunset, departure, ETA and an
  after-sunset/before-sunrise warning;
- an obvious persistent Light/Dark selector that also chooses the matching
  OpenFreeMap basemap style;
- alternative GEBCO 2026 global terrain context and NOAA's current US-only
  Chart Display Service;
- a reproducible Solent starter catalogue of harbours, marinas, anchorages,
  moorings, slipways, small-craft facilities, marine structures and the three
  bundled tide stations.

The map is deliberately labelled as planning context, not a nautical chart.
Straight route legs do not imply land, depth or hazard avoidance. OpenStreetMap,
OpenSeaMap, EMODnet, tide and weather data remain visibly attributed and carry
their source limitations.

The EMODnet shallow contours are decoded from its official styled-raster colour
ramp and retraced off the main UI thread when the map zooms in. Sub-pixel line
simplification keeps map interaction responsive without visibly changing the
trace, and the result is clipped to water polygons from the visible basemap. The
smoother screen-resolution trace does not add survey precision: the source grid
is still about 115 m in EMODnet coverage and its coastline can differ from the
general-purpose basemap.

Run locally from the repository root:

```sh
python3 -m http.server 4173 --directory apps/website
```

Then open `http://127.0.0.1:4173/planner.html`.

The isolated Docker deployment is defined in `deploy/compose.website.yaml`.
It binds to loopback by default so it cannot accidentally expose a plaintext
service on a public host; see `docs/oracle-web-planner.md`.

The public static build is assembled and deployed to Cloudflare Pages using
`tools/build_website.sh` and `wrangler.jsonc`; see `docs/cloudflare-pages.md`.

Focused verification:

```sh
node --check apps/website/planner.js
node --test apps/website/planner-core.test.mjs apps/website/map-data.test.mjs
python3 -m unittest tools/places/test_generate_sailing_pois.py
python3 -m unittest tools/contours/test_generate_emodnet_shallow_contours.py
```

The `tide-and-seek-api` meta value points at the selected TEC relay baseline at
`https://relay.tailendcharlie.app`. The relay CORS allowlist must include the
canonical Pages and Tide and Seek web origins before plan publishing will work.
