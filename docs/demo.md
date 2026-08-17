# Running the demo

What this build can honestly show today, and how to get it onto a phone.

> [!WARNING]
> There are still no nautical charts. The chart-provider decision is a blocking
> open question in [PLAN.md](../PLAN.md), so the map is a road-derived
> OpenStreetMap basemap. This demo is the voyage-recording and crew-sharing
> loop, not navigation. Do not take it to sea.

## What works

- **Solo voyage.** Create a voyage, start it, record a live GPS track on the
  offline-capable basemap, watch COG/SOG and distance, end it, and read the
  recap. No account, no server, no network.
- **Crew sharing.** A six-digit code (or its QR) adds other phones to the same
  temporary voyage. Positions, roles and quick messages flow between them.
- **GPX.** Import a route, export the recorded track.
- **Ride Lab.** Replays the bundled demo GPX so the app can be shown sitting
  still indoors, without walking around for a real track.

## What is not there

Tides, tidal streams, weather, wind, sea state, pilotage, anchor watch, and
charts. All are P0/P1 items in [PLAN.md](../PLAN.md) behind licensing and
provider decisions that have not been made.

## Solo, on one phone

Nothing to set up. Build, install, open the app, create a voyage, start it.
The relay is never contacted — that is asserted by a test, not just claimed.

## Crew sharing, on two or more phones

Crew sharing needs the relay reachable from both phones, and this is the part
of the demo with real setup cost. Be aware of what `deploy/` actually is before
you start: a production stack. It fronts everything with Caddy on 443, demands
`TIDE_AND_SEEK_DOMAIN`, a Postgres password, a data-encryption key and a
cursor-signing key, and it exposes no plain HTTP port at all. It is not a
one-command dev server.

Two honest options:

**Run the server directly, without compose.** Simplest for a LAN demo.

```bash
cd apps/server
uv run uvicorn tide_and_seek_server.app:default_app --host 0.0.0.0 --port 8000
```

That still needs the required settings in the environment — see
`deploy/.env.example` for the full list; `TIDE_AND_SEEK_DATA_ENCRYPTION_KEY`
and `TIDE_AND_SEEK_CURSOR_SIGNING_KEY` have no defaults, and
`TIDE_AND_SEEK_AUTO_CREATE_SCHEMA=true` saves running migrations by hand
against a scratch database.

**Or bring up the full stack** with a real domain and certificate, which is
what `deploy/compose.yaml` is built for. Worth it only if you want the demo to
survive past this session.

Either way, find the address the phones should use — the Mac's LAN IP, never
`localhost`:

```bash
ipconfig getifaddr en0
```

The base URL is compiled in, so it is a build-time argument:

```bash
flutter build ios --release --dart-define=TIDE_AND_SEEK_API_BASE_URL=http://<mac-lan-ip>:8000/api
```

On one phone create a voyage and read the six-digit code from the voyage
screen; on the other, join with that code. Both should appear in the roster
within a few seconds.

Two things that will cost you an hour if you skip them:

- **iOS blocks cleartext HTTP.** There is no `NSAppTransportSecurity`
  exception in `ios/Runner/Info.plist`, so a plain `http://` LAN relay will be
  refused by the OS before the app sees it. Either add a local-networking ATS
  exception for the demo, or terminate TLS in front of the server.
- **Client-isolated Wi-Fi.** On guest networks the phones cannot reach the Mac
  at all, and the failure presents as the six-digit code being rejected rather
  than as a network error.

If crew sharing turns into a yak-shave on the day, the solo voyage demo needs
none of it and still shows the core loop.

## Installing on an iPhone

The bundle identifier is `dev.osholt.tideandseek`. The old provisioning
profiles were tied to the previous identifier and no longer apply, so the
project is set to **automatic** signing: Xcode creates the App ID and profile
against your team by itself, and the developer portal does not need visiting.

**Build `--release`, never `--debug`.** Since iOS 14 a debug Flutter build
cannot be launched by tapping the home-screen icon at all: debug mode uses a
JIT that requires an attached debugger, so the app dies on signal 11 with
"Cannot create a FlutterEngine instance in debug mode without Flutter tooling
or Xcode". It looks exactly like a crash in the app. Debug builds only run
under `flutter run` or from Xcode; anything you hand someone to tap must be
`--release` (or `--profile`).

Signing itself can be done from the command line — `flutter build ios` passes
`-allowProvisioningUpdates` to xcodebuild, which creates the App ID and profile
against the team in the project. That needs Xcode already signed in to the
Apple ID; Claude will not enter credentials.

1. `open apps/mobile/ios/Runner.xcworkspace`
2. Select the **Runner** target, then **Signing & Capabilities**.
3. Confirm **Automatically manage signing** is ticked and pick your team
   (`UY4624PH6X`, or your personal team).
4. Plug in the iPhone, select it as the run destination, and press Run.
5. First install only: on the phone, **Settings → General → VPN & Device
   Management**, and trust the developer certificate.

If signing fails on the push or associated-domains capability, the demo needs
neither. Remove `aps-environment` and `com.apple.developer.associated-domains`
from `ios/Runner/DebugProfile.entitlements` and try again.

## Simulator

The simulator has no GPS, so the Makefile feeds it a fixed position:

```bash
make ios-simulator
```

`IOS_SIMULATOR_LOCATION` overrides the position, and
`TIDE_AND_SEEK_API_BASE_URL` the relay.
