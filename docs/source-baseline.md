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
