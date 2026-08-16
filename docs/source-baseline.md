# Source Baseline

Tide and Seek was scaffolded from `osholt/tailendcharlie` at commit
`5a90c59da54416a5fb8da67cf45960691543d5b7` (Tail End Charlie `origin/main`,
2026-08-15).

Copied:

- Flutter mobile source, native iOS/Android shells, assets, and tests;
- FastAPI/PostgreSQL relay, migrations, and tests;
- deployment examples and local tooling;
- dependency automation plus mobile/server CI; and
- licence, contribution, and security-policy foundations.

Deliberately not copied:

- Git history and the upstream `.git` directory;
- local caches, build outputs, virtual environments, and untracked changes;
- production/release/deployment workflows;
- Tail End Charlie marketing site, screenshots, video, and release notes; and
- any local deployment credential file.

Safety changes made at scaffold time:

- the public brand is `Tide and Seek`;
- provisional development IDs use `dev.osholt.tideandseek`;
- copied domains use `tideandseek.invalid` / `relay.tideandseek.invalid`; and
- no GitHub secret, provider key, signing key, or production endpoint is present.

## Inherited capabilities, not yet product claims

The codebase contains an event journal, anonymous code/QR sessions, nearby and
HTTPS relays, route import/recording, map/offline-region support, live positions,
participant trails, spoken road guidance, observer links, push scaffolding,
diagnostics, simulation, and export. Much of the UI and data remains motorcycle
specific. The backlog defines the evidence required before any capability is
described as suitable for sailors.

## Road and motorcycle surfaces removed during migration

Phase 1 of [PLAN.md](../PLAN.md) removes the inherited road-navigation surfaces
rather than renaming them. Removed so far:

- **CarPlay and Android Auto** — the Dart projection bridge, the Swift CarPlay
  scene/template, the Kotlin car app service, the `androidx.car.app`
  dependencies, the CarPlay entitlements and scene manifest entry, and the
  simulator helper. A projected chartplotter surface, if it is ever wanted, is a
  new marine design rather than a revival of this code.
- **Road ratings and motorcycle discovery** — the rating controller/store/client
  and its end-of-ride card, the road-facts and discovery sheets, the
  `MotorcycleDiscoveryCatalogue` map layers and suggestion queue, the 13.7 MB
  `discovery_catalogue.geojson` asset, and the `tools/discovery` catalogue
  pipeline (overlay build, enrichment, evidence index, publication, ratings).
  The client no longer advertises the `road-ratings-v1` relay capability.

  The marine equivalent — attributable harbour, marina, anchorage, hazard and
  pilotage packs (P1, backlog #10) — needs licensed sources and different
  categories, so it is a fresh build rather than a rename of this.

  **Still present, deliberately:** the relay's own discovery endpoints,
  `discovery_*` tables, and `0008_road_ratings` migration. They are the
  submission/moderation/rate-limit plumbing the pilotage layer will need, so
  they are left for backlog #10 to adopt or replace rather than deleted here.
  `tools/discovery/generate_speed_cameras.py` and `generate_mini_roundabouts.py`
  remain until their own surfaces are removed.
- **Speed limits, enforcement alerts, road hazards, traffic feeds and junction
  markers** — removed as one unit, because `SituationalAwarenessController`,
  `EnforcementAlertDetector` and the marker planner were mutually dependent and
  splitting them would have left the tree unbuildable between commits. Gone:
  the posted-speed sign and its lookup, the speed-camera/police warning bubble
  and border, the bundled fixed-camera layer and its generator, the hazard
  domain/symbols/deduplicator/relevance rules, the TomTom traffic reroute offer,
  the junction-marker plan, assistance, statistics and pass detection, and the
  advisory off-route rejoin planner and its relayed share.

  **Kept, and why:**

  - `SituationalAwarenessController` survives minus its hazard half. It also
    owns rider locations, live presence, the leader trail and route-deviation
    alerts, all of which the marine product needs.
  - The Alerts screen survives as route alerts and location-sharing status.
  - `RideEventType.hazardReported` / `hazardCleared` and `RideRole.marker` stay
    in the journal so rides recorded by an earlier build still decode. Nothing
    writes them now. Replacing the event model is backlog #2's job.
  - `routePrimaryPath` was lifted out of the marker planner into
    `lib/services/route_primary_path.dart`: picking the travelled path out of a
    multi-path route is route geometry, not a marker rule, and waypoint editing
    and route reshaping both still need it.
  - The map compass took over the corner slot it used to share with the speed
    sign.
  - Ride Lab keeps its marker simulation as a pure visual simulation; with the
    journal commands gone it records nothing.

  A marine hazard layer is P1 pilotage work (backlog #10) with licensed sources
  and different categories — a fresh build, not a rename of this.

## Identifiers that do not follow the product name

The `ride_relay` package rename deliberately stopped at these. They are opaque
identifiers whose value is stability, not branding, and moving them would be a
silent protocol or data break rather than a rename:

| Identifier | Where | Why it is pinned |
|---|---|---|
| `ride-relay-internet-token-v1` | mobile + server HMAC domain separation | Changing it invalidates every relay bearer token. A golden-vector test in `apps/server/tests/test_sync.py` guards it, and it caught this during the rename. |
| `me.osholt.ride_relay.relay.v1` | nearby peer discovery service id | Peers must agree; a change partitions old and new installs. |
| `rideRelayNamespace` | MapLibre offline region metadata | Orphans already-downloaded offline regions. |
| `ride_relay_v1.db` | on-device SQLite journal | Orphans the local voyage journal. |
| `ride_relay_invite_secret_v1_`, `ride_relay_observer_grants_v1_`, `ride_relay_observer_assistance_v1_` | keychain / secure storage prefixes | Orphans stored invite secrets and observer grants. |

Each carries its own `v1`. Change one only as a deliberate, versioned migration.

Deployment-facing names *were* renamed and need config updated in step: the
`TIDE_AND_SEEK_*` environment variables, the `tide_and_seek_*` Prometheus metric
names, and the default database URL. `deploy/` was updated in the same commit.
