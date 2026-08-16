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

Each implementation issue must add automated acceptance tests and update the
product claim in `README.md` only after its evidence gate passes.
