# Initial Backlog

The GitHub issues mirror this ordered backlog. Priority is a product priority,
not a claim that every P0 item is small.

| Order | Priority | Issue | Depends on |
|---:|:---:|---|---|
| 1 | P0 | Isolate inherited TEC baseline and keep CI green | — |
| 2 | P0 | Define solo-first voyage lifecycle and optional crew authority | 1 |
| 3 | P0 | Select and spike a licensed offline nautical-chart provider | 1 |
| 4 | P0 | Build marine map, vessel track, and source-aware navigation data | 2, 3 |
| 5 | P0 | Adapt passage planning, waypoint guidance, and GPX round-trip | 4 |
| 6 | P0 | Build sailing simulator and replay test matrix | 2–5 |
| 7 | P0 | Complete security, privacy, no-relay-solo, and field-test gates | 2–6 |
| 8 | P1 | Integrate tide heights and tidal-current context | 4 |
| 9 | P1 | Integrate weather, wind, gust, visibility, and sea-state context | 4 |
| 10 | P1 | Build attributable discovery, pilotage, and offline passage packs | 3, 4 |
| 11 | P1 | Implement six-digit crew sharing, handover, and observations | 2, 4 |
| 12 | P1 | Evaluate anchor watch and manual MOB assistance | 4, 7 |
| 13 | P2 | Explore NMEA instrument and authorised AIS integrations | 4 |
| 14 | P1 | Web passage planner and sailing atlas — [#86](https://github.com/osholt/knot-alone/issues/86) | 3–5, 8–10 |

Each implementation issue must add automated acceptance tests and update the
product claim in `README.md` only after its evidence gate passes.

## Current implementation note

The zero-cost development slice for chart camera, offline Solent tide heights,
area wind forecasts, manual MOB, and local/replay AIS now exists with automated
tests. These backlog items are not release-complete: physical-device, field,
trusted-reference, and representative-receiver evidence remains outstanding.
Network AIS, tidal streams, official charts/depth, and paid or account-based
providers remain deferred.

The web-planner epic now has a local first slice: marine waypoint editing,
rhumb-line leg calculations, GPX import/export, plan-code handoff, OpenSeaMap
seamark context and a reproducible 549-feature Solent sailing-place catalogue.
Public hosting, a real app-link domain, complete tide/wind timelines, pilotage
packs and licensed nautical charts remain open delivery issues #87–#92.
