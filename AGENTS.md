# Tide and Seek — Codex Instructions

## Project overview

Tide and Seek is a solo-first, offline-first sailing companion with optional
account-free crew sharing for iOS and Android. It is derived from Tail End
Charlie's Flutter client, Swift/Kotlin transport bridges, FastAPI/PostgreSQL
relay, and CI.

The repository is currently a product scaffold. Treat inherited motorcycle and
road behaviour as candidate infrastructure, not accepted sailing functionality.

## Entry points

- `PLAN.md` — product scope, safety boundaries, acceptance criteria, and phases.
- `docs/architecture.md` — target architecture and migration boundaries.
- `docs/source-baseline.md` — exact upstream provenance and inherited state.
- `docs/backlog.md` — issue map and suggested order.
- `apps/mobile/` — inherited Flutter application and native shells.
- `apps/server/` — inherited privacy-bounded optional crew relay.

## Narrow verification

```bash
cd apps/mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

```bash
cd apps/server
uv sync --frozen --extra dev
uv run ruff format --check .
uv run ruff check .
uv run pytest
```

## Project rules

- Preserve the offline-first event journal and transport-neutral domain boundary.
- Keep solo voyages fully useful without an account, code, or relay connection.
- Keep crew sharing account-free and scoped to a short code/QR invite.
- Show source, valid time, update/edition status, units, and freshness for charts,
  position, tides, currents, weather, wind, and pilotage content.
- Never imply that crowd notes or discovery content is official pilotage advice.
- Marine charts are not road basemaps. Do not ship or cache chart data without a
  provider and licence that allow the exact mobile/offline use.
- Preserve a clear distinction between GNSS COG/SOG, compass heading, boat-speed
  instruments, forecast current, and calculated values.
- Safety features such as MOB and anchor watch require explicit failure modes,
  background/battery evidence, and prominent limitations.
- Do not enable real domains, provider keys, signing, or deployment until each is
  explicitly selected. Current `*.invalid` values are deliberate safety guards.
- Do not commit credentials, signing assets, private voyage tracks, or restricted
  hydrographic/provider datasets.
