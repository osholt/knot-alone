# Map archives

Place an operator-approved `.mbtiles` or `.pmtiles` archive here before
starting the `maps` Compose profile. The archive and its schema must match the
MapLibre style in `../styles` and the style must include all required sprite and
glyph URLs. Large map archives are intentionally not committed.

Martin exposes each archive by its file stem below `/maps/tiles/`. Confirm the
catalog and a representative tile before compiling its HTTPS style URL into
the mobile app.
