# Local AIS receiver setup

Tide and Seek can display **received AIS targets** from a boat-local NMEA 0183
TCP stream without an account, internet AIS service, provider key, or relay.
This is a development integration until it has passed the physical-device and
receiver checks in
[`implementation-plan-live-marine-layers.md`](implementation-plan-live-marine-layers.md).

## Run against an existing receiver

The receiver must expose newline-delimited `!AIVDM` or `!AIVDO` sentences over
TCP on the same local network as the phone. Start the app with compile-time
configuration:

```sh
cd apps/mobile
flutter run \
  --dart-define=TIDE_AND_SEEK_AIS_NMEA_HOST=192.168.1.20 \
  --dart-define=TIDE_AND_SEEK_AIS_NMEA_PORT=10110
```

The port defaults to `10110`. No receiver is contacted when the host is absent.
The chart's **Received AIS status** sheet shows the configured source,
connection state, message age, and the incomplete-coverage warning. The client
reconnects after an interruption and immediately marks retained targets stale
while disconnected.

iOS asks for local-network access using the purpose string in
`ios/Runner/Info.plist`; Android uses the existing internet/network permission.
The current adapter supports NMEA TCP only. Signal K, UDP, serial/Bluetooth,
NMEA 2000 gateways, and measured device/battery behaviour remain future work.

## Test without equipment

With no host configured, open the chart menu and choose **Start AIS replay
demo**. It plays the bundled synthetic Solent fixture and labels it as replay,
not live traffic. Choose **Stop AIS replay demo** to remove it.

Regenerate the deterministic fixture from the repository root:

```sh
dart run tools/ais/build_replay_fixture.dart
```

## Safety and privacy boundary

- AIS is incomplete: vessels may not transmit, may be out of receiver range, or
  may send missing or inaccurate fields.
- The layer is not a collision alarm and does not calculate CPA or TCPA.
- Targets are held in memory only; this adapter does not upload or build vessel
  history.
- Disconnected or aged targets cannot remain visually live.
- The bundled replay contains invented vessels and no observed traffic.
- The feature does not replace a lookout, proper onboard equipment, official
  charts, or the Collision Regulations.

No MarineTraffic/Kpler, AISstream, AISHub, or other network-AIS integration is
enabled. Adding one still requires an explicit later decision on terms, cost,
coverage, credential handling, and redistribution rights.
