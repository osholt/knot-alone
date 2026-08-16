# Tide and Seek

**Name:** Tide and Seek
**Status:** product scaffold; inherited functionality is not yet suitable for navigation at sea

Tide and Seek is a solo-first sailing companion with optional, account-free crew
sharing. It combines offline nautical-chart context, passage and track views,
pilotage/discovery information, tides, currents, weather and wind, while a
six-digit code lets everyone aboard share the same temporary voyage state.

The repository is derived from Tail End Charlie's offline-first Flutter and
FastAPI architecture. Its event journal, six-digit sessions, nearby/internet
relay, location capture, maps, GPX, voice guidance, observer sharing,
simulation, diagnostics, and CI are retained as an implementation baseline.
Motorcycle and road-navigation concepts still present below the new product
surface are migration work, not marine features.

> [!WARNING]
> This is not a chartplotter, a certified navigation system, or a substitute for
> official charts, Notices to Mariners, sound seamanship, or a proper passage
> plan. Do not use it for navigation until the marine-domain, chart licensing,
> data-quality, security, and physical field-test gates in [PLAN.md](PLAN.md)
> are complete.

## Product direction

- Solo by default; no account or server is required to record a local voyage.
- Optional six-digit code/QR to share a temporary voyage with the whole crew.
- Offline nautical charts and passage context from an appropriately licensed
  provider, with chart edition/update status visible.
- Course over ground, speed over ground, heading when available, track, bearing,
  cross-track error, ETA, and clear source/accuracy/freshness.
- Tide heights, tidal streams, weather, wind, gust, sea-state, visibility, and
  forecast validity displayed as context rather than guarantees.
- A discovery and pilotage layer for harbours, marinas, anchorages, hazards,
  facilities, approaches, gates/locks/bridges, and attributable notes.
- Offline-first planning, GPX import/export, voyage recap, diagnostics, and a
  simulator for route, tide, weather, and connectivity scenarios.

See [PLAN.md](PLAN.md), [docs/architecture.md](docs/architecture.md), and
[docs/backlog.md](docs/backlog.md).

## Repository layout

```text
apps/mobile/                 Flutter client plus Swift/Kotlin platform bridges
apps/server/                 FastAPI/PostgreSQL optional crew relay
apps/website/                Safe placeholder for the future public site
deploy/                      Deployment templates; no production credentials
docs/                        Product, architecture, source, and backlog notes
.github/workflows/           Mobile and server CI only
```

## Local verification

The inherited internal Dart/Python names remain `tide_and_seek` for now.

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

All copied network and associated-domain defaults use `*.invalid`. A real
domain, chart/weather/tide providers, and app-store identifiers are separate
release decisions.

## Licence and attribution

This derivative retains the PolyForm Noncommercial License 1.0.0. See
[LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
