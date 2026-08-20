# ADR-001: Underway chart, live marine layers, and MOB recovery

**Status:** Accepted

**Date:** 20 August 2026

**Deciders:** Product owner

**Related issues:** #7, #11, #15, #16, #78, #79, #80, #81, #82

## Implementation status

The zero-cost development slice is implemented in the current mobile working
tree:

- source-aware tide, wind, and AIS contracts retain provenance, validity,
  receipt time, units, freshness, and limitations;
- the underway chart is flat, starts farther out, and has follow, pan, pinch,
  rotate, plus, and minus controls;
- three curated Solent stations provide bundled offline astronomical height
  predictions, curves, turns, datum, attribution, and quality warnings;
- Open-Meteo supplies a bounded, time-selectable area wind forecast with arrows,
  speed, gust, valid time, forecast status, and attribution;
- manual MOB activation and explicit recovery/false-alarm resolution are stored
  as critical voyage events and drive a fixed chart marker, elapsed time,
  bearing, distance, and recovery framing; and
- received AIS targets can come from a boat-local NMEA 0183 TCP stream, with a
  deterministic synthetic replay when no equipment is available.

Automated checks cover the data contracts, camera behaviour, harmonic goldens,
wind parsing/UI, MOB reducer/workflow, AIS fragmentation/merge/staleness, chart
rendering, and TCP reconnect. This is not release approval: the physical phone,
tablet, background/battery, wet/gloved MOB, trusted tide comparison, and
representative receiver checks in the verification matrix remain open. Network
AIS and all paid/account-based providers remain deferred.

## Context

The underway chart needs a flatter and wider camera, tide and wind context,
nearby AIS targets, and a manual man-overboard recovery mode. These features do
not have the same data or safety properties:

- chart camera and MOB state can work entirely on the device;
- astronomical tide predictions can be calculated offline from licensed
  harmonic constituents;
- observed tide, wind forecast, and network AIS require external providers;
- local AIS can work offline through an onboard receiver;
- network AIS is incomplete and may be delayed even when a provider calls it
  real time.

The implementation must keep solo voyages useful without an account or relay,
must not embed provider secrets in the mobile app, and must preserve source,
time, units, datum, freshness, and observed/forecast/calculated status.

### Cost and contract constraint

The accepted plan has a **£0 provider and hardware budget** for the current
phase. Do not purchase a subscription, API plan, receiver, chart pack, or other
hardware, and do not enter a negotiated provider, reseller, or redistribution
agreement without a new explicit decision.

Current implementation may use:

- bundled data under an existing open licence, including the curated CC BY
  TICON-4/Neaps tide subset;
- public open-data APIs such as the Environment Agency OGL tide-gauge service;
- Open-Meteo's free non-commercial endpoint within its published limits and
  attribution requirements;
- simulator/replay fixtures; and
- local AIS hardware only if suitable equipment is already owned or can be
  tested without purchase or contract.

UKHO subscriptions, Kpler/MarineTraffic, paid Open-Meteo access, AISHub
contributor commitments, AISstream account/provider integration, and any new
hardware purchase are deferred. Keeping their adapter boundaries in the design
does not authorise registration, contact, purchase, or integration.

## Source findings

### AIS

| Option | What it provides | Terms and operational fit | Decision |
|---|---|---|---|
| Onboard AIS through NMEA or Signal K | VHF messages received by the sailor's own equipment | Offline, lowest latency, no third-party redistribution; requires hardware and local-network integration | Production-first AIS source |
| [Kpler/MarineTraffic Data Services](https://www.kpler.com/product/maritime/data-services) | Global terrestrial/satellite AIS through APIs, OGC WFS/WMS, or raw NMEA streams | Commercial/contact-sales product; current documentation supports position time, insertion time, source, COG, SOG, and heading | Deferred under the £0/no-contract constraint |
| [AISstream.io](https://aisstream.io/) | Free WebSocket AIS stream selected by bounding box | Requires an API key; its documentation says browser clients are unsupported and recommends a backend so the key is not exposed; throttling and public production terms still need confirming | Account and integration deferred; use replay fixtures meanwhile |
| [AISHub](https://www.aishub.net/join-us) | Aggregated contributor AIS feed and JSON/XML/CSV API | Free only to contributors providing a qualifying live receiver feed; API calls are limited to once per minute | Deferred and unsuitable for primary underway traffic without an existing qualifying shore station |
| Scraping a public vessel-tracking website | Whatever the public map happens to render | Unstable and normally outside site/data terms | Rejected |

The AIS product wording must say **received AIS targets**, not all nearby
vessels. No source can show vessels without AIS, messages outside receiver
coverage, switched-off equipment, or messages the provider missed.

### Tides

There is a usable open-data path for an MVP; UKHO is not the only option.

| Option | What it provides | Terms and limitations | Decision |
|---|---|---|---|
| [Neaps tide database](https://github.com/openwatersio/tide-database) using TICON-4 | Harmonic constituents, datums, epochs, and quality notes for global stations | Code is MIT; each station carries its own licence and the TICON-4 entries inspected are CC BY 4.0. Predictions are astronomical, research-derived, non-official, and exclude weather residuals | Offline prediction source for v1, after curating and validating the UK subset |
| [Neaps predictor](https://github.com/openwatersio/neaps) | MIT harmonic prediction engine and automated NOAA validation | TypeScript rather than Dart and explicitly not for navigation | Reference implementation and golden-fixture generator; port the required algorithm to tested Dart rather than add a JavaScript runtime |
| [Environment Agency Tide Gauge API](https://environment.data.gov.uk/flood-monitoring/doc/tidegauge) | Near-real-time observations at 44 UK coastal locations | OGL v3, no registration; 15-minute means normally lag 15–30 minutes and are relative to local datum or mAOD, not automatically chart datum | Optional observed layer, always separate from the prediction curve |
| [UKHO Tidal API Discovery](https://www.api.gov.uk/ukho/uk-tidal-api-discovery/) | Authoritative current day plus six days of events for 607 UK stations | Free one-year subscription, but in-app navigation, caching, and crew display terms still require written confirmation | Later official provider adapter; no longer blocks the open-data MVP |
| [Open-Meteo Marine API](https://open-meteo.com/en/docs/marine-weather-api) | Model sea-level height and ocean current direction/rate | CC BY 4.0, but about 8 km resolution and explicitly unsuitable for coastal navigation | Optional experimental model context later; never substitute it for a harbour tide station or licensed tidal-stream atlas |

A source audit on 20 August 2026 found 151 TICON records labelled `United
Kingdom` in the Neaps database, about 1.2 MB uncompressed, including Lymington,
Portsmouth, Southampton, Bournemouth, and Weymouth. The records contain
duplicates from different upstream gauges and some carry quality warnings, so
the app must ship a curated manifest rather than automatically treating every
record as equivalent.

Tidal height and tidal stream are different products. V1 will show station
height predictions. It will not infer current direction or rate from a height
curve.

### Wind

The app already fetches one-position Open-Meteo wind and wave context in
`marine_forecast.dart`. The [forecast API](https://open-meteo.com/en/docs)
supports hourly values and multiple coordinates in one request, so the existing
provider can be extended to a bounded spatial/time sample instead of adding a
second weather provider. Free API use remains non-commercial and rate-limited;
a commercial build must use a paid endpoint while retaining CC BY attribution.

## Decision

Implement the features through transport-neutral provider interfaces and ship
them in this order:

1. flat, wider, manually controllable chart camera;
2. offline astronomical tide heights from a curated TICON-4/Neaps subset;
3. time-aware Open-Meteo wind layer;
4. offline manual MOB marker and recovery mode;
5. local onboard AIS receive/display;
6. optional network AIS adapter only after a later decision authorises provider
   registration/terms, cost, and secret handling.

Network AIS is deliberately last because it is the only requested feature that
cannot be made both useful and independent of internet/provider availability.
Local AIS remains useful when the phone has no mobile signal.

## Target architecture

```text
Map controls --------------------------> chart camera state
Bundled TICON data -> Dart predictor --> tide read model ----+
EA gauge API --------------------------> observed tide model |
Open-Meteo API ------------------------> wind field model ---+--> chart layers
Local NMEA/Signal K -> AIS decoder ----> AIS target store ---+
Network AIS gateway -> AIS adapter ----> AIS target store ---+

MOB button -> append-only event journal -> MOB reducer -> recovery layer
```

### Shared source model

Introduce a reusable `MarineDataSource`/`MarineDatum<T>` boundary rather than
stretching `ChartSource` further. Every externally sourced or calculated value
must retain:

- provider/source identifier and attribution;
- authority class: official, measured, forecast, calculated, or community;
- measurement/valid time and device receipt/fetch time;
- units and reference basis, including chart datum or mAOD where relevant;
- freshness/expiry policy and quality flags;
- caching and redistribution permissions.

Keep separate provider interfaces for `TideProvider`, `WindFieldProvider`, and
`AisTargetSource`. UI widgets consume read models, not provider response JSON or
NMEA sentences.

### Storage and privacy

- Bundle only the reviewed UK tide manifest and constituents, with upstream
  commit/version, per-station licence, attribution, and checksum.
- Cache wind and observed-tide context separately from the append-only voyage
  journal; cache entries retain their original valid and fetched times.
- Keep AIS targets ephemeral by default. Do not upload or retain a vessel-history
  database as a side effect of showing nearby traffic.
- Store MOB activation and resolution as critical append-only voyage events.
- Keep network-AIS credentials on the server. The mobile app requests only a
  bounded nearby window and never receives the upstream provider key.
- The optional network-AIS gateway must not turn the account-free crew relay
  into a general public AIS redistribution service.

## Delivery plan

Day ranges below are engineering estimates, not release commitments. Each phase
ends with a reviewable vertical slice.

### Phase 0 — Provider contracts and replay fixtures (2–3 days)

Issues: #7, #11, #16

1. Add source-aware tide, wind-field, AIS-target, and MOB domain models.
2. Define provider interfaces and explicit unavailable/stale/disconnected
   states.
3. Add deterministic tide, wind, AIS, camera, and GPS-loss replay fixtures.
4. Add feature flags with no production provider keys or real domains.
5. Add an attribution/provenance sheet that can represent all three marine data
   layers without calling research data official.

Exit: simulator data can drive the read models without a network or map widget.

### Phase 1 — Flat and user-controlled chart (3–5 days)

Issue: #78

1. Replace the speed-driven road camera in `navigation_camera.dart` with a
   marine camera plan: pitch `0`, wider route-aware scale, own vessel visible,
   and bounded look-ahead only when following.
2. Model camera state explicitly as `following`, `manual`, or `overview`.
3. Make any pan, pinch, or rotate gesture enter `manual` immediately and stop
   automatic camera commands.
4. Add large `Follow vessel`, `+`, and `−` controls for wet/gloved/mounted use.
5. Keep north-up/course-up explicit and prevent accidental ambiguous rotation.
6. Exercise the same behaviour in MapLibre and FlutterMap fallbacks.

Exit: physical phone and tablet tests confirm the chart never snaps back after
manual movement and can be re-centred in one action.

### Phase 2 — Offline tide-height MVP (6–10 days)

Issues: #11 and #80

1. Create a reproducible build tool that reads a pinned Neaps tide-database
   release, filters the UK/Solent stations, preserves source/licence/epoch/
   quality metadata, and produces a compact Flutter asset.
2. Curate duplicates using recency, quality flags, datum availability, and
   geographic usefulness; do not merge incompatible gauges silently.
3. Port the required harmonic calculation and nodal corrections from the MIT
   Neaps predictor to pure Dart with attribution.
4. Generate golden predictions with the pinned upstream Neaps version for
   Lymington, Portsmouth, and Southampton across spring/neap cycles, leap years,
   UTC/BST boundaries, and dates far from the source epoch.
5. Add independent spot comparisons against a current published reference
   without checking proprietary tide-table data into the repository.
6. Render station pins, current predicted height/trend, next high/low, and a
   selectable curve. Always display station, distance, LAT/datum, valid time,
   source, calculated status, and quality warning.
7. Add the Environment Agency adapter as an optional measured layer. Never
   subtract or combine its mAOD/local-datum reading with a LAT prediction unless
   a documented station-specific datum transform exists.

Exit: tide heights and curves work in airplane mode and are labelled
`astronomical prediction — calculated from TICON-4 harmonics`, not official or
observed.

### Phase 3 — Time-aware wind layer (4–7 days)

Issue: #81

1. Extend `OpenMeteoForecastService` from `current` at one point to hourly wind
   speed/direction/gust samples at multiple bounded coordinates.
2. Sample a small adaptive grid or passage points, debounce camera changes, cap
   request size, and cache by provider/model coordinates and valid hour.
3. Render decluttered arrows/barbs plus a speed/gust legend without covering
   route, vessel, tide, AIS, or MOB layers.
4. Add a time selector with one-action return to `now`.
5. Preserve forecast valid time, fetched time, source, units, and stale/offline
   state. Keep future measured NMEA wind visually separate.

Exit: a cached passage-area wind layer can be scrubbed through time in airplane
mode and never reads as a current observation or safe-course recommendation.

### Phase 4 — Manual MOB recovery mode (5–8 days plus physical tests)

Issues: #15 and #82

1. Append `mobActivated` and `mobResolved` event types to `VoyageEventType`;
   never reorder existing event values.
2. On activation, atomically append the best available position, UTC time,
   location source, accuracy, and stale/no-fix state before any relay work.
3. Add a reducer that restores active MOB state after navigation or supported
   restart/reconnect paths.
4. Keep a reachable MOB control on the underway chart and validate the final
   tap/hold protection under stress, gloves, rain, and mounted-device use.
5. Show a fixed last-known marker, elapsed time, current bearing/distance, own
   track since activation, fix quality, and a one-action camera fit of own vessel
   plus MOB point.
6. Require explicit recovery/end confirmation. Do not transmit distress, imply
   a live casualty position, or depend on the internet.
7. Complete #15's denied-permission, background, force-quit, audio, notification,
   battery, and physical-device evidence before making product claims.

Exit: replay and physical iOS/Android tests show that activation is immediate,
offline, persistent, explicit about failure, and hard to clear accidentally.

### Phase 5 — AIS in two increments

Issues: #16 and #79

#### 5A: Local receiver (implemented in code; physical gate open)

1. Implement an `AisTargetSource` backed by replayed NMEA `!AIVDM/!AIVDO`
   messages, then add a local Signal K WebSocket or NMEA TCP/UDP transport.
   The implemented transport is NMEA TCP; Signal K and UDP remain future work.
2. Handle fragmented messages, Class A/B position reports, static/voyage
   messages, invalid sentinel values, duplicates, out-of-order updates, source
   reconnect, and MMSI identity changes.
3. Preserve position message time separately from receipt time and keep COG,
   SOG, heading, rate of turn, name, and navigational status independently
   nullable.
4. Add source-appropriate stale and expiry policies; disconnected targets must
   never remain visually live.
5. Render target symbols, density controls, target detail, source/age, and an
   incomplete-AIS warning. CPA/TCPA and collision alarms remain out of scope.
6. Validate iOS local-network permission, Android networking behaviour, battery,
   reconnect, and a representative onboard receiver.

Code exit: replay and loopback TCP integration pass. Delivery exit remains open
until the display works in airplane mode with a representative boat-local
receiver on physical iOS and Android devices. See
[`ais-local-receiver.md`](ais-local-receiver.md).

#### 5B: Optional network AIS (deferred; 5–8 days after later approval)

1. Obtain explicit approval before creating a provider account, accepting
   provider-specific terms, requesting a quote, or adding a real provider key.
2. If approved later, run a Solent coverage/latency spike with AISstream through
   a development-only server adapter; record missing-target rate, message age,
   reconnect behaviour, and terms before retaining the adapter.
3. If a paid option is later acceptable, request a Kpler/MarineTraffic quote
   covering mobile in-app display, bounding-box access, caching, derived target
   state, crew display, and redistribution.
4. Select a provider only after written terms and cost are acceptable.
5. Add a disabled-by-default FastAPI gateway that holds the key, validates and
   clamps bounding boxes, rate-limits anonymous clients, emits only the required
   target fields, and stores no target history.
6. Label network targets and their age distinctly from local VHF targets.

Exit: provider credentials never enter the app, the gateway cannot be used as
an unrestricted AIS proxy, and a delayed network target cannot be mistaken for
local real-time reception.

## Verification matrix

| Layer | Unit/contract | Replay/integration | Physical/field |
|---|---|---|---|
| Camera | scale, flat pitch, follow/manual transitions | both renderers, route/no-route, resize | wet/gloved phone and mounted tablet |
| Tide | constituent math, extrema, datum, UTC/BST, quality | pinned Neaps goldens, offline asset, EA failure/stale states | compare representative stations/times with a current trusted reference |
| Wind | hourly parsing, direction convention, caching | grid/time scrub, rate limits, offline and partial cache | legibility and interaction on phone/tablet |
| MOB | event validation, reducer, recovery geometry | no-fix, stale fix, crash/restart, duplicate activation, relay loss | iOS/Android latency, audio/haptic, background, battery |
| AIS | NMEA decode, target merge, stale/expiry | dense traffic, reconnect, out-of-order, local/network distinction | representative receiver plus measured network coverage/latency |

## Trade-offs and consequences

- Open harmonics make tide heights available offline without waiting for UKHO,
  but the UI must call them calculated astronomical predictions and expose
  station quality. They are not official ADMIRALTY predictions.
- Environment Agency readings improve situational context but cannot be merged
  with chart-datum predictions without a proven datum relationship.
- Local AIS gives the most honest underway traffic picture but asks the sailor
  to own compatible equipment.
- Network AIS improves convenience and demoability but introduces recurring
  cost, internet dependency, key abuse risk, provider coverage gaps, and data
  redistribution restrictions.
- The first field-test release should ship camera, offline tide, wind, and manual
  MOB before network AIS. Local AIS may join it if representative hardware is
  available for validation.

## Approval gates

- [x] Approve TICON-4/Neaps as a non-official astronomical prediction source.
- [ ] Review the curated UK station manifest and validation results.
- [ ] Complete the #15 MOB feasibility and physical-test decision.
- [ ] Select a representative local AIS/Signal K or NMEA receiver for testing.
- [ ] Reconsider AISstream production terms only if a network adapter is later
      authorised; no adapter or account exists today.
- [ ] Obtain and approve Kpler/MarineTraffic commercial terms before production
      network integration.
- [ ] Obtain explicit product-owner approval before any provider registration,
      subscription, contract, quote request, purchase, or paid endpoint.
- [ ] Keep real domains, keys, deployment, and signing disabled until separately
      authorised.
