# Tide and Seek — Product Requirements and Delivery Plan

Status: concept scaffold

Name: **Tide and Seek**

Platforms: iOS and Android
Initial users: UK coastal yacht sailors, primarily solo or small crews

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

- **Blocking — licensing/product:** Which nautical-chart provider permits the
  required UK coverage, offline use, attribution, and update-status display?
- **Blocking — licensing:** Which tide/current, weather/wind, and pilotage sources
  permit caching and crew redistribution?
- **Blocking — product:** Is the initial sailing envelope coastal passages only,
  and what vessel/area constraints define the field test?
- **Blocking — safety:** Which calculations are useful context versus too easy to
  mistake for a safe-course recommendation?
- **Blocking — privacy:** Exact shared-position retention and observer precision.
- **Non-blocking — design:** Final product name, domains, icon, and permanent IDs.
- **Non-blocking — engineering:** First external-instrument integration target.

## Delivery phases

1. **Foundation:** isolate the derivative, settle the voyage model, remove
   motorcycle/road UI and data, and keep inherited CI green.
2. **Core solo slice:** licensed chart decision/spike, local voyage, marine map,
   track, route/waypoints, core calculations, offline readiness, and simulator.
3. **Crew and context:** anonymous sharing, tides/currents, weather/wind,
   discovery/pilotage packs, and exports.
4. **Release evidence:** security protocol, privacy/licence review, battery and
   background tests, at-sea field matrix, accessibility, and store review.
