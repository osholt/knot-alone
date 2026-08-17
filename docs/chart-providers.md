# Nautical chart sources

Research for [#6](https://github.com/osholt/knot-alone/issues/6) and
[#17](https://github.com/osholt/knot-alone/issues/17). This is a decision
paper, not a decision. It exists so the choice can be made deliberately rather
than by whichever tile URL was easiest to paste in.

Researched August 2026. Licensing terms move, and none of this is legal advice.

## The distinction that matters

Two different things get called "a chart", and conflating them is how a project
like this ends up claiming more than it can support:

- An **official chart** is issued by a national hydrographic office, carries a
  chart edition and Notices to Mariners, and is what SOLAS carriage
  requirements mean. Its licence almost always restricts redistribution and
  caching, because the licence is what guarantees the mariner is looking at a
  current chart.
- A **crowd-sourced or derived layer** is seamark and depth information without
  hydrographic authority behind it. Useful context. Not a chart.

`PLAN.md` requires chart source, edition/update date, cache age and uncovered
areas to be visible, and requires the app to refuse to call an area cached when
required cells are missing or outside validity. Only an official product can
satisfy the first half of that honestly. A derived layer can satisfy the
provenance plumbing while being clear about what it is.

## Options

### UKHO ADMIRALTY (AVCS / ENC)

The obvious answer for UK waters, and the hardest to get.

- ~17,000–23,000 ENCs from hydrographic offices worldwide, quality assured by
  UKHO into one service. Genuinely authoritative, with edition and update
  tracking built in.
- Aimed at **SOLAS commercial shipping and ECDIS**. There is no published
  developer pricing and no self-serve tier; the route is a Value Added Reseller
  agreement, and the documented next step is to email
  `customerservices@ukho.gov.uk`.
- AVCS Online can be embedded as a base layer in web systems, which is the
  closest thing to an app integration story.
- **Assume** redistribution and offline caching are restricted and priced per
  end user. That assumption needs confirming with UKHO before any design
  depends on it.

**Verdict:** the only option that makes "nautical chart" a truthful claim for
UK coastal waters. Blocked on a commercial conversation, not on engineering.

### NOAA ENC / RNC

- Public domain, free, no attribution obligation, redistributable, cacheable.
- **US waters only.** No use for the Bristol Channel or anywhere else in the
  intended sailing envelope.

**Verdict:** ideal terms, wrong ocean. Worth remembering only if the product
ever crosses the Atlantic.

### Navionics / C-MAP and other leisure vendors

- What the leisure chartplotter market actually runs on, with mobile SDKs.
- Commercial, per-seat, and the SDK terms typically constrain how the chart may
  be displayed and whether it may be cached — which collides directly with an
  offline-first design.

**Verdict:** the pragmatic middle if UKHO proves impossible, but the offline
requirement has to be checked against the SDK terms before committing.

### OpenSeaMap

- Seamark layer rendered from OpenStreetMap: buoyage, lights, harbours, some
  depths.
- **Dual licence.** The underlying data is ODbL; the rendered tiles are
  CC-BY-SA 2.0. Both need attributing, and share-alike applies to derived
  tiles.
- Free, and commercial use is permitted with attribution.
- **No published usage policy, rate limit, or availability guarantee**, and the
  FAQ carries no warranty or liability disclaimer at all. For a safety-adjacent
  app, depending on a community tile server with no stated terms of service is
  a real operational risk — the honest mitigation is to render tiles yourself
  from OSM data rather than hammer someone else's server.
- Crowd-sourced, so no chart edition, no Notices to Mariners, and no authority.

**Verdict:** the best way to get seamarks on screen without a commercial
conversation, and the right choice for a first visible layer — provided the UI
says plainly that it is not a chart.

### EMODnet Bathymetry / GEBCO

- Free WMTS covering European seas at EMODnet DTM resolution and the rest of
  the world from GEBCO, in Web Mercator among other projections.
- Capabilities: `https://tiles.emodnet-bathymetry.eu/wmts/1.0.0/WMTSCapabilities.xml`
- Survey-derived and citable, so depth shading has provenance an official chart
  would recognise, even though the product is not a navigational chart.

**Verdict:** the right source for depth *shading* — it makes the water stop
being an empty polygon. Not soundings, not a substitute for charted depths.

## Recommendation

Two tracks, because they are not blocked on the same thing:

1. **Open the UKHO conversation now.** It is the long pole and it is a
   commercial process, not an engineering one. Everything about whether this
   product can honestly say "chart" depends on the answer.
2. **Meanwhile build the provenance plumbing and ship an open layer.** EMODnet
   bathymetry for depth shading plus OpenSeaMap seamarks, behind the source,
   edition, cache-age and coverage surfaces #17 requires. That work is needed
   whichever provider wins, and it replaces the road basemap with something
   marine without waiting.

The trap to avoid: shipping OpenSeaMap and quietly letting the "not for
navigation" warning erode, because the map now looks like a chart. The
provenance UI is what stops that, which is why it is worth building before,
not after, the pretty layer.

## Sources

- [UK Hydrographic Office](https://www.admiralty.co.uk/)
- [ADMIRALTY Vector Chart Service (AVCS)](https://www.navtor.com/charts-publications/digital-charts/avcs)
- [AVCS Online Discovery API](https://api.gov.uk/ukho/avcs-online-discovery-api)
- [OpenSeaMap FAQ](https://www.openseamap.org/index.php?id=faq&L=1)
- [OpenSeaMap sources and licences](https://www.openseamap.org/index.php?id=quellen&L=1)
- [OSMF licence and legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ)
- [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [EMODnet Bathymetry](https://emodnet.ec.europa.eu/en/bathymetry)
- [EMODnet Bathymetry WMTS](https://tiles.emodnet-bathymetry.eu/)
