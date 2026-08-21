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

**Verdict:** the only option that lets the product use the word "chart" without
qualification. Not required for leisure use — see below — so this is a
positioning choice rather than a prerequisite, and the commercial conversation
can wait until there is a reason to have it.

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
- The companion WMS exposes three depth colour styles and a generalised contour
  layer. Those contours start at 50 m (then 100, 200, 500, 1,000, 2,000 and
  5,000 m), so they add offshore shape but not chart-like shallow-water detail.
- The public mean-depth WCS supports bounded derived contours. The web planner
  requests a capped grid for the current view at zoom 8 and closer, then derives
  2/5/10/20/30 m lines in the browser across the service's North Atlantic and
  European coverage (including every English coast). Wider views deliberately
  use a reduced-resolution preview; zooming closer restores model detail. The
  planner requests a similarly bounded subset of the global 15 arc-second GEBCO
  2026 grid through CEDA OPeNDAP outside that coverage and derives the same levels
  as a substantially coarser worldwide fallback. The result remains interpolation
  rather than charted soundings, surveyed marina depth or safe clearance.
- Non-negative land and shoreline cells are retained as an explicit wet/dry
  mask. The contour generator omits any cell with a dry corner instead of interpolating
  a depth line across that coastal transition. This creates deliberate coastal
  gaps and avoids apparent over-land lines such as the mixed cells around St
  Anthony Head; the roughly 115 m DTM and the basemap coastline can still differ.
- Survey-derived and citable, so depth shading has provenance an official chart
  would recognise, even though the product is not a navigational chart.

**Verdict:** the right source for depth *shading* — it makes the water stop
being an empty polygon. Not soundings, not a substitute for charted depths.

### Open-Meteo marine currents and sea level

- The free marine endpoint supplies hourly ocean-current velocity and direction
  plus sea-level height relative to MSL. The current combines Eulerian flow,
  waves and tides; it is not a pure tidal-atlas prediction.
- The underlying current/tide model is about 0.08° (roughly 8 km). Open-Meteo
  explicitly says coastal accuracy is limited and the data is not suitable for
  coastal navigation.
- The planner uses a zoom-adaptive grid across the visible map. Samples farther
  than 8 NM from the route use current time; samples nearer the route smoothly
  blend to the expected time at the closest route point and are colour coded
  teal, blue and purple. Route calculations sample about every 2.5 NM, project
  each vector onto the planned track, show an amber course-to-steer estimate and
  separately plot the drift expected if the uncorrected ground-track bearing is
  held. The still-water estimate remains visible and none of these calculations
  is presented as helm guidance.
- EMODnet depths are LAT-referenced, while the model sea level is MSL-referenced.
  The planner only adjusts those contour labels within 60 km of one of the three
  bundled TICON-4 Solent stations, using that station's explicit MSL↔LAT offset.
  GEBCO's MSL reference can be adjusted directly, but remains much too coarse
  for local clearance decisions.

**Verdict:** useful planning context for visualising likely set and drift and
comparing departure times. It is not a tidal atlas, observed current, or an
under-keel-clearance calculation.

## Do you legally need official charts?

No, not for leisure use, and this is the finding that changes the plan.

SOLAS V passage-planning duties do apply to pleasure craft, but there is no
statutory requirement for *official* charts aboard a UK pleasure vessel under
13.7 m. MCA guidance (MGN 599, MGN 610) expects a careful assessment of the
intended voyage using "appropriate charts and publications" — a duty on the
skipper, not on a piece of software. Nothing obliges this app to carry licensed
ENCs.

What the app is obliged to do is not imply it is a chart when it is not. That
is a truthfulness constraint, and it is satisfied by provenance UI rather than
by a licence.

## What UKHO gives away free

More than expected, and separately from the charts:

| Data set | Licence |
|---|---|
| Wrecks and obstructions — 94,000+, global, quarterly | Open Government Licence, explicitly free of charge |
| Bathymetry surfaces — 4,000+, 1970 to present | UKHO Bathymetry Data Licence, OGL-like |
| Maritime limits and boundaries, ships' routeing measures, offshore infrastructure | Via the ADMIRALTY Marine Data Portal; licence not stated on the access page and needs confirming before use |

The ENCs themselves are not in that list. Those are AVCS, and they are
commercial with no published price and no self-serve tier.

### The free data may carry a field-of-use restriction that blocks this app

The table above says "OGL" and "OGL-like", and that is not the whole story. Two
different formulations are in circulation, and the difference decides whether
this app may use the data at all.

The INSPIRE metadata for `Bathymetry_Mosaic_Depth` records the licence as "Open
Government Licence", with the limitation:

> These data are not suitable for use in marine navigation. Acknowledgement of
> Originator/Owner as source is required.

That is a **fitness warning**. It says the data is not good enough for
navigation, which is a statement this app already makes about every layer it
draws, and it does not restrict what you may build.

UKHO's own portal terms, however, have been published as:

> 1. The data sets must not be used for navigation or in the creation of
>    navigational products.

That is a **field-of-use prohibition**, and Tide and Seek is a navigational
product by any reading — it draws a chart-like surface, plots a route on it and
shows the vessel's position against it. Under that wording, rendering UKHO
bathymetry as depth shading is outside the licence no matter how the UI is
captioned, and the same wording would also cover the wrecks and obstructions
data this repo has already modelled as OGL-clean.

Two further points worth holding onto:

- The restriction has been publicly criticised as incompatible with the Open
  Definition, precisely because a licence must not "restrict anyone from making
  use of the work in a specific field of endeavour", with the suggestion that
  UKHO should express it as a warning in the documentation rather than as a
  binding term. That is an argument about what UKHO *ought* to publish. It is
  not authority that the term is unenforceable, and it cannot be relied on.
- The current ADMIRALTY Marine Data Portal does not publish its terms inline, so
  the governing text for a download made today could not be established from
  public pages.

**Consequence.** The bathymetry work is blocked on a licence question, not an
engineering one, and no pipeline should be built until it is answered. This is
also the concrete question worth putting to UKHO in writing, and a better one
than asking about the copyright reproduction licence below:

> May UKHO bathymetry surfaces and the wrecks and obstructions data set be
> rendered in a leisure sailing application as depth shading and hazard markers,
> where the application states prominently that it is not for navigation and
> carries the required attribution? If the "creation of navigational products"
> restriction applies, what licence would permit it?

Until there is an answer, the wrecks entry in `marine_layers.dart` carries this
caveat beside it, and neither data set is drawn.

## Is there a free UKHO licence? Not one that helps

There is a genuinely free UKHO licence, and it is the wrong shape for this.

UKHO runs a free online **copyright reproduction** licence, one year, for
non-commercial or low-value commercial use. Qualifying means meeting at least
one of: the product has no commercial value; total commercial value of all
products containing the material is under £10,000 a year; limited tidal
predictions or small extracts in a periodical; use on television or in film; or
website display of images with **fewer than 1,000 page impressions per day**.

Three clauses kill it for a navigation app:

- **You must already have bought or legally obtained the material you copy.**
  It is a licence to reproduce something you own, not a way to obtain chart
  data.
- **Navigation use is excluded** unless used with the original material.
- Mobile apps are not addressed at all; the permitted surfaces are print,
  broadcast and low-traffic websites.

So emailing them about this licence will not produce ENC data for an app. It is
the licence for reproducing a chart extract in a club newsletter or a pilot
book. Chart data for a navigation product is the commercial AVCS route, and
there is no free tier of that.

Application: `https://copyright.ukho.gov.uk/onlineapplication.aspx`

## Other cruising grounds

Free official charts are the exception, not the rule, and the exceptions are
mostly not where a UK yacht goes.

| Country | Official charts free? |
|---|---|
| USA (NOAA) | **Yes** — ENC and RNC, public domain |
| New Zealand (LINZ) | **Yes** — raster and ENC |
| Brazil (DHN/CHM) | **Yes** — ENC and raster packs |
| Norway (Kartverket) | Raster via an online viewer |
| South China Sea (EAHC) | Small-scale ENCs only |
| Inland European waterways (RIS) | **Yes** — vector, but rivers and canals, not coastal |
| UK, Greece, Croatia, Italy, Spain, Turkey | **No** |

That last row is the problem: essentially every Mediterranean charter
destination, and home waters, is commercial.

- **Greece (HNHS)** distributes official ENCs to the maritime market, encrypted,
  and began an S-101 series in early 2026. It publishes a WMS rendered from ENC
  data, but that service carries **no vector data and is explicitly not for
  navigation**.
- **Croatia (HHI)** distributes through **PRIMAR**, the regional ENC
  coordinating centre, and its authorised distributors. Its WMS is available
  only after concluding a distribution agreement through PRIMAR.

**PRIMAR is the thing to know about.** It aggregates many European hydrographic
offices into one distribution channel, so it — not a country-by-country
scramble — is the single commercial conversation for European coverage, in the
same way AVCS is for worldwide.

### The model that avoids redistribution entirely

Worth considering before any licensing conversation: let the **sailor** bring
their own charts. They buy official ENCs for their cruising ground and the app
renders them, so the app never distributes chart data. This is how OpenCPN and
o-charts work, at leisure prices per region rather than commercial per-vessel
rates.

The catch, and it needs confirming before the architecture depends on it:
official ENCs are protected under **IHO S-63**, and decrypting them requires
the software to be registered with the RENC and issued a manufacturer key bound
to an installation. That is a process, not a payment, but it is not nothing —
and it is the reason a hobby app cannot simply open a purchased ENC.

## Recommendation

**Build on the unambiguous free stack, and do not open the UKHO commercial
conversation yet.** EMODnet Bathymetry DTM depth shading and OpenSeaMap
seamarks and buoyage make a legitimate, attributable passage-planning aid when
their limitations remain prominent. GEBCO is a global fallback for terrain
context, not near-shore clearance. Do not ingest UKHO bathymetry, wrecks or
obstructions until UKHO confirms in writing that the field-of-use wording
permits this navigational product.

The August 2026 re-check found the same restriction in current Marine Data
Portal metadata for wrecks and obstructions, ships' routeing measures, and UK
territorial limits: the data is not suitable for marine navigation **or for the
creation of navigational products**. The planner therefore links to the UKHO
source and explains the restriction but does not copy, query, cache or render
those features. "Free to download" is not permission for this field of use.

For real charted soundings, use official national ENCs only where their terms
allow it. NOAA supplies free current S-57 ENCs and derived web/offline display
services for US waters; LINZ supplies free regularly updated S-63 ENCs after
registration for New Zealand and its charted regions. These are provider
adapters for those regions, not a free route to UK chart coverage.

Revisit paid ENCs only on a deliberate product decision — that Tide and Seek
should claim to be a chart plotter, or should carry commercial credibility.
That is positioning, not a technical blocker, which means #17 is not blocked on
licensing after all.

The trap to avoid is unchanged, and is now the main risk: shipping a layer that
looks like a chart and letting the "not for navigation" position erode because
the map got prettier. The provenance UI — source, edition or vintage, cache
age, uncovered areas — is what prevents that, and it is worth building before
the layer rather than after.

An earlier draft of this document concluded that UKHO ENCs were the only
honest option. That was right about the word "chart" and wrong as a conclusion
about what to build.

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
- [UKHO marine data sets](https://www.admiralty.co.uk/access-data/marine-data)
- [MGN 599: pleasure vessels — regulations and exemptions](https://www.gov.uk/government/publications/mgn-599-m-amendment-1-m-pleasure-vessels-regulations-and-exemptions-guidance-and-best-practice-advice/mgn-599-m-amendment-1m-pleasure-vessels-regulations-and-exemptions-guidance-and-best-practice-advice)
- [MGN 610: SOLAS chapter V guidance](https://www.gov.uk/government/publications/mgn-610-mf-amendment-1-solas-chapter-v-guidance-on-the-merchant-shipping-safety-of-navigation-regulations-2020/mgn-610-mf-amendment-1-navigation-solas-chapter-v-guidance-on-the-merchant-shipping-safety-of-navigation-regulations-2020)
- [RYA pleasure craft regulations](https://www.rya.org.uk/regulations/pleasure-craft-regulations/)
- [INSPIRE metadata for `Bathymetry_Mosaic_Depth`](https://ckan.publishing.service.gov.uk/api/2/rest/harvestobject/60caa433-7602-4f1c-9598-9d1f6f155e18/html) — the "not suitable for use in marine navigation" limitation
- [Owen Boswarva, "That's not how the OGL works"](https://www.owenboswarva.com/blog/archive/mg/20131209.htm) — quotes UKHO's "must not be used for navigation or in the creation of navigational products" term and argues it is incompatible with the Open Definition
- [ADMIRALTY Marine Data Portal](https://datahub.admiralty.co.uk/portal/apps/sites/#/marine-data-portal) — terms not published inline
- [UKHO copyright licensing](https://copyright.ukho.gov.uk/datasets.aspx)
