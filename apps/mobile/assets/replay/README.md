# AIS replay fixture

`solent_ais.nmea` contains synthetic `!AIVDM` messages for deterministic
decoder and chart testing. It is not observed vessel data and must never be
presented as live traffic.

Regenerate it from the repository root with:

```sh
dart run tools/ais/build_replay_fixture.dart
```

The fixture includes fragmented type 5 static/voyage messages, type 24 Class B
static messages, and Class A/B position updates for three invented vessels.
