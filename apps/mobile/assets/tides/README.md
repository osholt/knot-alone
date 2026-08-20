# Bundled Solent tide data

`solent_tides.json` is generated, not hand-edited. It contains the Lymington,
Portsmouth, and Southampton TICON-4 reference stations from the Neaps tide
database plus the matching Neaps/IHO constituent definitions.

Source data is CC BY 4.0. The predictor code is ported from the MIT-licensed
Neaps tide predictor. Predictions are non-official astronomical calculations;
they exclude atmospheric pressure, wind, surge, waves, river flow, and later
changes to the source gauges.

Rebuild from exact upstream checkouts:

```sh
dart run tools/tides/build_tide_assets.dart \
  --database /path/to/tide-database \
  --predictor /path/to/neaps \
  --output apps/mobile/assets/tides/solent_tides.json
```
