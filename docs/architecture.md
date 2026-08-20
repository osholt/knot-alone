# Target Architecture

## Starting point

The copied baseline is Flutter with thin Swift/Kotlin platform bridges plus an
optional FastAPI/PostgreSQL relay. State-changing actions are appended to an
idempotent SQLite event journal before relay. Nearby and HTTPS are transport
adapters, not the source of truth.

```text
Solo/crew UI -> Voyage controller -> local event journal
                                      |-> optional nearby relay
                                      |-> optional bounded HTTPS relay

GNSS/instruments -> source-aware observations -> voyage read models
Chart provider -> licensed offline cache -> marine map renderer
Tide/weather/pilotage providers -> timestamped context cache
Passage plan + observations + context -> calculations and explicit alerts
```

## Domain migration

The inherited implementation calls a session a `voyage` and uses Dart/Python
packages named `tide_and_seek`. Keep those internal names until the core domain
boundaries are covered by tests; a broad rename is not a product feature.

| Target concept | Inherited basis | Required change |
|---|---|---|
| Solo/shared voyage | Voyage session/lifecycle | Solo path without membership; marine roles |
| Passage plan | GPX route/revisions | Waypoint legs, notes, assumptions, authority |
| Vessel track | Sailor trail/recorder | Marine sampling, gaps, COG/SOG and quality |
| Nautical chart | MapLibre/offline cache | Licensed marine formats, editions, coverage |
| Crew state | Roster and quick messages | Same-vessel roles, handover, observations |
| Tides/weather | Hazard/provider interfaces | Source/validity-aware marine provider contracts |
| Discovery/pilotage | Discovery catalogue | Attributable marine schema and offline packs |
| Voyage recap | Voyage recap/GPX | Marine metrics, legs, logbook-style export |

## Local-first and shared state

A solo voyage never requires membership and does not contact the relay merely to
record a track. Turning on sharing creates an operation-scoped group around the
existing local voyage and publishes only the authorised plan/state. Turning it
off stops publication without deleting the local log.

Suggested event types include `voyageStarted`, `planRevisionPublished`,
`waypointPassed`, `crewObservationAdded`, `roleHandedOver`, and `voyageEnded`.
Position samples are observations with measurement time, receipt time, source,
accuracy, and optional instrument metadata.

## Marine data model

- Keep COG/SOG from GNSS separate from magnetic/true heading and
  speed-through-water from instruments.
- Every bearing states true/magnetic basis; every depth states datum/source when
  it comes from chart/pilotage data.
- Tide/current and weather values retain station/model, run time, valid time,
  units, and forecast/observed status.
- Pilotage entries retain publisher/author, update date, official/community
  classification, geographic scope, and any licence-required attribution.
- Derived ETA, VMG, cross-track error, and tide gates retain their inputs so the
  UI can explain the result.

## Provider boundaries

Nautical charts, geocoding, tides/currents, weather/wind, pilotage, Notices to
Mariners, and optional AIS/instruments are separate interfaces. Each provider
adapter declares coverage, attribution, caching/redistribution limits, update
metadata, failure mode, and whether data is measured, official, forecast, or
community-authored.

No production provider is selected. General-purpose basemap tiles must not be
relabelled as marine charts, and direct rhumb-line passage legs must state that
they have not been checked against land, depth, hazards or traffic schemes.

## Discovery and pilotage packs

The discovery index is a searchable summary suitable for a map and destination
browser. A pilotage pack is a bounded, versioned offline snapshot for the
planned corridor/destinations. Download status shows partial coverage and age;
community notes cannot override or visually masquerade as official material.

## Safety and verification gates

- Simulator/replay tests for tacking, drift, waypoint passage, route deviation,
  tide/current time changes, stale forecasts, duplicated events, and reconnect.
- Physical iOS/Android tests for GPS/compass behaviour, background recording,
  notifications, nearby transport, battery, salt/wet-screen usability, and audio.
- At-sea comparison against known reference instruments without claiming
  certification.
- Security/privacy threat model and per-device authority before public sharing.
- Written provider/licence decision before checking in or caching marine data.
