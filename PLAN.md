# Tide and Seek — Product Requirements and Delivery Plan

Status: **inherited app renamed and de-roaded; marine capability barely started**

Last reviewed: 18 August 2026. See "Where this actually is" for the honest state,
which is some way behind what the requirements below describe.

Name: **Tide and Seek**

Platforms: iOS and Android
Initial users: UK coastal yacht sailors, primarily solo or small crews

## Where this actually is

The requirements below describe the product. This section describes the build, so
the two are not confused. Written 18 August 2026, updated 19 August 2026.

### Working

Inherited from Tail End Charlie and carried across intact: the live group map,
six-digit voyage codes and QR join, roster and roles, SOS and quick messages, GPX
import and export, offline tile caching, the local voyage journal, recap, and the
simulator. Roughly 1,700 tests.

Done since the rename: the road features stripped, the full domain rename, vessel
icons and the marine glyph set, chart-provenance UI, size-driven layout for iPad,
and passage legs that are no longer road routes.

Done since: a passage leg table in nautical units, marks placed and named on the
chart, navigation instruments that degrade with fix age, Open-Meteo wind and sea
state, a Solent demo passage, and the chart sitting beside the detail on a tablet
in landscape.

**Build 22 (1.0.1) is on TestFlight**, internal testing only. That is the first
time any of this has been on a device that is not a simulator, and it immediately
found user-visible road vocabulary the earlier passes missed (#49).

### Not started

**Tides. Weather. Depth. Real charts. Anchor watch. MOB. AIS. NMEA.** No code
exists for any of them. Every occurrence of the word "tide" in the source is the
app's own name.

### Known to be wrong or missing

| Area | State | Issue |
|---|---|---|
| Charts | A road basemap with an OpenSeaMap seamark overlay painted on. No depth, no soundings, no contours. | #17, #6 |
| Depth shading | Blocked on whether UKHO's "not for use in the creation of navigational products" clause governs its free data | #29 |
| Passage planning | Rhumb-line legs with a leg table; marks can be placed, named and removed on the chart. No land avoidance, no tidal gates, no drag-to-move, no leg reordering | #8, #32 |
| Tides | Nothing | #11 |
| Weather | Open-Meteo wind, gusts, pressure, visibility and open-water wave, labelled a forecast rather than an observation. No GRIB, no routing | #12 |
| Instruments | COG, SOG, XTE, bearing and distance to the active mark, all dimming together once the fix is stale. Never verified against a real GNSS fix | #34 |
| Onboarding | Sells crew coordination first on a solo-first app, and its crew-facing name field cannot be skipped | #49 |
| Safety gates | No at-sea testing has happened at all | #10 |
| Road leftovers | Valhalla, the engine dispatcher, the track matcher and the motorcycle cafe catalogue are gone — 5,500 lines. OSRM survives only as the manoeuvre parser the turn-guidance tests need | #31, #63 |
| Turn-by-turn guidance | 2,350 lines that can never fire: a passage emits no manoeuvres. Needs a decision, not a deletion — a mark approach may still want "in 2 cables, alter to 072" | #63 |
| Crew roles | `Marker` is the road role where a rider holds a junction; #3 removed junction markers and the role outlived them | #57 |

### The honest summary

This is a **crew-coordination app that speaks marine**, and it has started to
grow a boating app inside it. The coordination half is real and tested. The
sailing half is now a passage you can plan, tabulate and steer to, with wind and
sea state beside it - on top of a road basemap with a seamark overlay, and with
no tide, no depth and no chart.

Tide is the gap that matters most for UK coastal sailing, and it is the one
gated on a licence question nobody has answered (#29). Until then a passage this
app plans is a passage in still water.

Nothing here should be relied on at sea. #10 exists because none of it has been
near water, and being on TestFlight does not change that.

## Problem statement

Sailors often assemble passage plans, charts, tides, forecasts, pilotage notes,
and voyage tracks from several disconnected sources. A solo sailor needs a calm,
offline-capable view with minimal setup, while a crew benefits from sharing the
same plan, observations, and progress without everyone creating an account.

## Product principles

1. **Solo first, crew when useful.** The local voyage works without login,
   connectivity, or a server; sharing is an optional six-digit session.
2. **Offline is ordinary.** Plans, permitted charts, pilotage packs, and important
   events are committed locally before departure.
3. **Provenance over polish.** Every chart, tide, forecast, and pilotage datum
   exposes its source, relevant time, update/edition status, and limitations.
4. **No false precision.** Measured, forecast, calculated, stale, and unknown
   values remain distinguishable.
5. **A companion, not a single point of failure.** The app does not replace
   official charts, navigation equipment, or seamanship.
6. **Privacy ends with the voyage.** Shared precise positions expire after a
   short recovery window unless explicitly exported or retained.

## Goals

- A solo sailor can plan, start, record, pause, resume, and export a voyage
  without creating an account or contacting the relay.
- A skipper can share a voyage with a small crew by code/QR in under two minutes.
- A sailor can cache the licensed chart/pilotage corridor and verify its coverage
  and update status before leaving connectivity.
- The active view combines track, route, COG, SOG, bearing, cross-track error,
  tide/current, and wind without obscuring data freshness or provenance.
- A destination's pilotage/discovery card provides attributable, time-stamped
  information and separates official material from community notes.

## Non-goals for the first field-test release

- Certified ECDIS/ECS, statutory carriage compliance, or replacement of official
  charts and Notices to Mariners.
- Collision avoidance, autonomous steering, or automatic helm commands.
- Public vessel tracking, a social network, or permanent crew profiles.
- An assurance that a berth, anchorage, depth, bridge opening, or tidal gate is
  safe or available.
- Automatic distress transmission or emergency-service contact.
- Scraping, copying, or redistributing chart/pilotage data without permission.

## Personas and user stories

### Solo sailor

- As a solo sailor, I want to start a local voyage immediately so account setup
  never blocks departure.
- As a solo sailor, I want a legible active-navigation view and optional spoken
  prompts so I can minimise screen interaction.
- As a solo sailor, I want to know exactly which charts and forecasts are cached
  and current before losing signal.

### Skipper / navigator

- As a skipper, I want to share a temporary voyage by six-digit code so everyone
  aboard sees the same plan without creating accounts.
- As a navigator, I want route, track, COG/SOG, cross-track error, tide and wind
  on one view while retaining each value's source and valid time.
- As a navigator, I want pilotage notes grouped by approach and destination so I
  can prepare rather than hunt across apps underway.

### Crew member

- As crew, I want the current leg, next waypoint, ETA, and agreed observations so
  I can understand the plan without altering it accidentally.
- As crew, I want an explicit handover of helm/navigator role so authority is
  visible and survives reconnection.

## Requirements

### P0 — private field-test release

#### Solo-first voyage lifecycle

- Create, plan, start, pause, resume, end, retain, delete, and export a local
  voyage without a relay or membership flow.
- Optional shared-voyage roles: skipper, helm, navigator, crew, and observer.
- Code/QR sharing adds a temporary crew session while the canonical plan remains
  available offline.

Acceptance:

- [ ] Airplane mode does not prevent a new solo voyage or local track recording.
- [ ] Enabling sharing never replaces or loses the existing local plan/track.
- [ ] Five devices join a shared voyage in under two minutes on a healthy link.
- [ ] Ending sharing stops publication without deleting the sailor's local log.

#### Licensed nautical chart foundation

- Select a provider only after coverage, raster/vector format, offline caching,
  attribution, update/edition metadata, pricing, and redistribution rights are
  documented.
- Render chart data independently of road-map assumptions and verify cached
  coverage along the passage plus an adjustable safety margin.
- Make chart source, last update/edition, cache age, and uncovered areas visible.

Acceptance:

- [ ] The app refuses to call an area cached when required chart tiles/cells are
  missing or outside their permitted validity.
- [ ] Attribution remains visible in offline use.
- [ ] A stale/missing chart state cannot be confused with a current chart.
- [ ] Provider terms are recorded next to the implementation decision.

#### Marine map, track, and navigation state

- Show route, waypoints, actual track, own vessel, optional crew observations,
  scale, north/heading state, and chart-source status.
- Show GNSS COG/SOG, bearing, distance, cross-track error, VMG where its basis is
  explicit, ETA, and fix age/accuracy with selectable nautical units.
- Keep compass heading and external speed-through-water distinct from GNSS values.

Acceptance:

- [ ] Unit and north-reference choices are persistent and unambiguous.
- [ ] A stale or inaccurate fix degrades every dependent calculation visibly.
- [ ] Replayed duplicate fixes do not alter the canonical track.
- [ ] Simulator tests cover stationary drift, tacking, waypoint pass, route
  deviation, GPS loss, and clock skew.

#### Passage planning and guidance

- Import/export GPX, create/edit/reorder waypoints, define legs, and attach notes.
- Calculate per-leg distance/bearing and an ETA range based on explicit speed and
  tide/current assumptions.
- Provide optional spoken waypoint, cross-track, and stale-data prompts without
  pretending to choose a safe course.

Acceptance:

- [ ] Offline route edits persist and sync deterministically when sharing.
- [ ] ETA identifies measured versus assumed inputs and recomputes predictably.
- [ ] Guidance can be muted and never issues helm commands.
- [ ] GPX round-trips preserve route and track geometry within documented limits.

#### Security, privacy, and diagnostics

- Retain the local journal, deduplication, bounded relay, QR bootstrap,
  diagnostics, and explicit stale states inherited from Tail End Charlie.
- Replace the inherited group-HMAC trust model with per-device authority and
  encrypted payloads before public shared-voyage release.
- Solo mode sends no server traffic unless the sailor deliberately enables a
  network-backed feature whose behaviour is explained.

Acceptance:

- [ ] Network tests prove solo local recording contacts no relay.
- [ ] Logs redact codes, secrets, exact tracks, contact details, and provider keys.
- [ ] A participant can leave a shared voyage and remove their local copy.
- [ ] Connectivity recovery requires no manual conflict-repair screen.

### P1 — high-value sailing context

#### Tides and currents

- Tide-station selection, heights and curves, datum/source, forecast validity,
  springs/neaps context, and daylight-aware times.
- Tidal-stream/current layers or route-leg estimates only where licensed data
  supports them; calculated gates expose assumptions and uncertainty.

#### Weather and wind

- Wind speed/direction/gust, pressure, precipitation, visibility, wave context,
  forecast run/valid time, source, units, and offline age.
- Time/altitude controls where the provider supports them, with observed and
  forecast values clearly separated.

#### Discovery and pilotage

- Search and browse harbours, marinas, anchorages, moorings, fuel/water, repair,
  launch/slip points, gates/locks/bridges, hazards, regulations, and contacts.
- Organise pilotage into preparation, approach, arrival, facilities, and
  departure; preserve source, date, geography, and official/community status.
- Download a bounded pilotage pack for the planned route.

#### Safety-assistance features

- Anchor watch and manual MOB marker only after notification/background/battery
  behaviour and failure modes pass physical-device tests.
- Prominent disclaimer and last-known accuracy; no automatic distress call.

### P2 — future considerations

- NMEA 0183/NMEA 2000 gateway integrations for heading, depth, wind, log, and GPS.
- AIS receive/display from an authorised local or network source, with clear age
  and no collision-avoidance claims.
- GRIB import and offline weather-routing exploration.
- Club flotillas, race support, and several-vessel shared passages.

## Success metrics

Leading indicators:

- 90% of field testers create and begin a solo voyage on their first attempt.
- 80% of invited crew devices join successfully on their first attempt.
- 100% of displayed chart/tide/weather/pilotage panels expose source and time.
- Zero stale position fixes retain the live visual state in automated replay tests.
- 95% of field testers correctly identify whether their passage chart pack is
  complete in an offline-readiness task.

Lagging indicators:

- 70% of started test voyages reach a deliberate end-and-review action.
- Fewer than 5% of voyages need manual state reset after connectivity changes.
- At least 80% of testers rate provenance/freshness clarity 4/5 or better.

## Open questions

Answers found since this was written are recorded here rather than left as
questions, because a stale open question reads as "nobody has looked".

### Answered

**Which chart provider permits UK coverage, offline use and update-status
display?** None, free. `docs/chart-providers.md` has the working: official charts
for UK and Mediterranean waters are commercial without exception, and UKHO AVCS
has no self-serve tier. Free official charts exist only for the USA, New Zealand,
Brazil, Norway and inland EU waters. What is drawn today is OpenSeaMap seamarks
over a general basemap, labelled as not a chart.

**Do UK leisure sailors legally need official charts?** No. SOLAS V
passage-planning duties apply to pleasure craft, but no statute requires *official*
charts aboard a UK pleasure vessel under 13.7 m; MCA guidance places the duty on
the skipper. So this is a positioning choice, not a prerequisite — but the app
must not imply it is a chart when it is not.

**Which tide source?** The **UKHO Tidal API** has a free *Discovery* tier: a
one-year subscription, current plus six days of tidal events for 607 UK stations,
10 requests/second and 10,000/month. *Premium* is £300+VAT a year and adds a year
of predictions plus tidal-stream locations. This is the most promising licensed
marine data found so far — **subject to the same licence check that blocked the
bathymetry** (#11).

**Which weather source?** **Open-Meteo**. The data is CC BY 4.0, so caching and
showing it to crew are permitted with attribution — which the `ChartSource` model
already knows how to express. The free endpoint is for non-commercial use at
10,000 calls/day; commercial use needs a paid subscription. A marine endpoint
provides wave forecasts (#12).

**What should passage planning do?** Rhumb-line legs between the sailor's own
waypoints, stating plainly that they are not checked against land or hazards
(#19). Road routing is gone. Land avoidance needs chart data the build does not
have, so it is not attempted rather than approximated.

### Still open

- **Blocking — licensing:** Does the UKHO Tidal API licence permit use in a
  navigation app, offline caching, and display to crew? The bathymetry precedent
  says do not assume: UKHO has published "the data sets must not be used for
  navigation or in the creation of navigational products" as a term on top of the
  OGL. One email answers this and #29 together.
- **Blocking — product:** Is the sailing envelope coastal passages only, and what
  vessel and area define the field test?
- **Blocking — safety:** Which calculations are useful context versus too easily
  mistaken for a safe-course recommendation? Tidal gates are the sharp case: a
  "you can cross at 14:20" that is wrong is worse than no gate at all.
- **Blocking — privacy:** Exact shared-position retention and observer precision.
- **Blocking — commercial:** Does this stay a personal app? It decides the
  Open-Meteo tier, whether Premium tides are worth £300/yr, and whether paid
  charts (#6) are ever on the table.
- **Non-blocking — engineering:** First external-instrument integration target.

## Delivery phases

Ordered by what unblocks what, and by what is dangerous if left. Each item names
its issue; the issues carry the detail.

### Phase 1 — Foundation (done)

Isolate the derivative, settle the voyage model, strip the road features and
vocabulary, keep CI green. Remaining scraps: #31 (dead road engines), #24
(motorcycle words in comments), #20 (biker-places data), #27 (repo name).

### Phase 2 — Stop being wrong (mostly done)

Everything here is about the app not asserting things that are false.

- [x] Chart provenance on screen, and "not for navigation" said plainly — #17
- [x] Passage legs that are courses, not road routes — #19
- [x] Marine iconography and vocabulary — #30
- [ ] Settle the UKHO licence question, which gates both depth and tides — #29

### Phase 3 — A passage you can actually plan

The first phase that adds sailing capability rather than removing road
assumptions. Tides before weather: for UK coastal sailing the tide decides
whether the passage works at all, and the data is more tractable.

- [x] Weather and wind from Open-Meteo, with forecast run time and age — #12
- [x] Navigation instruments: COG, SOG, XTE, fix age — #34 *(never seen a real fix)*
- [ ] Waypoint editing on the chart, with a leg table: course, distance, ETA — #32
      *(leg table, mark placing, naming and removal done; drag-to-move, leg
      reordering and tap-a-leg-to-centre remain)*
- [ ] Tidal heights and curves from the UKHO Tidal API, with provenance — #11
      *(parked: the licence question, #29)*
- [ ] Tidal windows and gates, built on the heights — #33 *(parked behind #11)*

### Phase 4 — Trustworthy offline

Making the above survive losing signal, which is the normal condition at sea.

- [ ] Offline passage packs: chart corridor, tides, forecast, verified — #13
- [ ] Coastal depth, if the licence permits — #29
- [ ] Crew sharing hardened: per-device authority, encrypted payloads — #14, #25

### Phase 4a — What TestFlight found

Not planned; discovered by putting build 22 on a device. Kept as its own group
because "we shipped it and then looked at it" is a different kind of work from
the phases around it, and there will be more of it after every build.

- [x] Crew roles and onboarding copy spoke road, and onboarding was crew-first
      on a solo-first app — #49
- [x] Associated Domains pointed at a placeholder that could never resolve, and
      every invitation led with a link that could not open — #40, #51
- [x] The iOS launch image was the Flutter placeholder — #41
- [x] Release builds were hand-assembled and not reproducible — #42
- [x] A solo sailor with no voyage was told to wait for the skipper's route,
      the wrong answer removed — #53 stays open for the right one
- [ ] The `Marker` role outlived junction markers — #57
- [x] The app talked like a motorcycle app on live screens, and the destination
      planner offered inert road switches including "Avoid ferries" — #61
- [x] The motorcycle router, engine dispatcher and track matcher deleted — #31
- [x] The motorcycle cafe catalogue and its map pins deleted — #20

**Build 23 (1.0.2)** carries all of the above. Nine of the eleven things in this
phase were found by putting a build on a device rather than by reading the code,
which is the argument for doing it early and often.

### Phase 4b — Make the passage coherent

The fitness review of build 24 found the app half-joined-up: a passage can be
planned in detail and then not sailed. The plan, the instruments and the voice
all exist and none of them speak to each other. This phase joins them, and it is
what turns a chart-table aid into something usable under way.

- [x] Stop reporting a correct passage as broken — #72
- [ ] `PassageGuidance`: one service reading the plan, the alterations and the
      live fix, and answering "what leg am I on, what is next, how far, and what
      does the plan ask for there" — #63
- [ ] The under-way banner reads it, replacing the road guidance planner
- [ ] Spoken prompts read it: a mark at 1 NM and 2 cables, cross-track beyond a
      threshold, a stale fix — #73
- [ ] Retire what that leaves dead: `OsrmRoadRoutingService`, the roundabout and
      lane machinery, `roundabout_exit_bucket.dart`,
      `assets/mini_roundabouts.geojson`, `tools/discovery` — the rest of #31

The order matters. Each step is useless without the one before it, and the last
cannot happen until the first four have taken over everything the road stack
was still feeding.

### Phase 5 — Evidence before anyone sails with it

- [ ] Security and privacy review, log redaction, retention — #10
- [ ] Battery, background and notification behaviour on real devices
- [ ] At-sea field-test matrix — the gate nothing else substitutes for — #10
- [ ] Anchor watch and manual MOB, only after the above — #15

### Later

Paid charts (#6), NMEA and AIS (#16), GRIB and weather routing, flotillas.

## Sequencing note

Phases 3 and 4 both assume the licence answers. If UKHO says no to tides, Phase 3
loses its first item and the honest fallback is harmonic prediction from published
constituents — a bigger build with its own accuracy caveats. That answer is worth
chasing before committing to the phase.
