# Attribution

Tide and Seek is a derivative of
[Tail End Charlie](https://github.com/osholt/tailendcharlie), scaffolded from
commit `5a90c59da54416a5fb8da67cf45960691543d5b7`.

Copyright and licence terms are retained in [LICENSE](LICENSE). The new product
name does not imply that the inherited motorcycle implementation has been
validated for sailing or marine navigation.

## Web passage planner data and libraries

- Map rendering uses MapLibre GL JS under its BSD 3-Clause licence.
- The general web basemap is served by OpenFreeMap/OpenMapTiles using
  OpenStreetMap data. Map data © OpenStreetMap contributors and is available
  under the Open Database Licence 1.0.
- The optional seamark overlay is OpenSeaMap. Underlying OpenStreetMap data is
  ODbL; rendered OpenSeaMap tiles are attributed under CC BY-SA 2.0.
- European depth shading is the EMODnet Bathymetry DTM 2024, owned by the EU
  and licensed under CC BY 4.0. It is a modelled terrain grid, not soundings.
- Global terrain context is the GEBCO 2026 Grid. It is free to reuse with
  attribution and must not be used for navigation or safety at sea.
- Optional US chart imagery is rendered from current NOAA ENC data by the NOAA
  Chart Display Service. Its US-only coverage and update status remain visible.
- LINZ's free official New Zealand ENC service and CC BY chart imagery are
  linked as regional sources. No protected S-63 data or LDS API key is bundled.
- UKHO wrecks, routeing and maritime-limits data are not copied or rendered:
  their current metadata prohibits use in creating navigational products.
- The committed Solent sailing-place catalogue is a derived OpenStreetMap
  database under ODbL 1.0. Each feature retains its OpenStreetMap source URL and
  stable source identifier.
- Solent tide-station data is TICON-4 via the Neaps tide database, CC BY 4.0.
- User-triggered web wind summaries use Open-Meteo model data, CC BY 4.0.

Except for NOAA imagery within its stated US coverage, these layers are
planning context and do not constitute an official nautical chart, tide table,
weather observation or pilotage publication. NOAA imagery does not remove the
need to check current official products and applicable carriage requirements.
