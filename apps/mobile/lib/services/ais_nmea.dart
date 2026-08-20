import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../domain/ais_target.dart';
import '../domain/marine_data.dart';

const _aisCoverageWarning =
    'Received AIS targets only. Vessels without AIS, outside receiver range, or missed by the receiver are not shown.';

const _replayAisSource = MarineDataSource(
  id: 'tide-and-seek-ais-replay',
  displayName: 'Bundled AIS replay',
  kind: MarineDataKind.replay,
  authority: MarineDataAuthority.onboard,
  licence: MarineDataLicence(
    name: 'Tide and Seek test fixture',
    attribution: 'Synthetic AIS replay generated for Tide and Seek testing',
    permitsOfflineCache: true,
  ),
  coverageNote: _aisCoverageWarning,
);

const _localNmeaAisSource = MarineDataSource(
  id: 'local-nmea-ais',
  displayName: 'On-board NMEA AIS receiver',
  kind: MarineDataKind.observation,
  authority: MarineDataAuthority.onboard,
  licence: MarineDataLicence(
    name: 'Locally received vessel transmissions',
    attribution: 'AIS messages received by this device from an on-board source',
  ),
  coverageNote: _aisCoverageWarning,
);

class AisNmeaDecoder {
  AisNmeaDecoder({
    required this.kind,
    required this.source,
    this.staleAfter = const Duration(minutes: 2),
    this.expireAfter = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  factory AisNmeaDecoder.replay({DateTime Function()? clock}) => AisNmeaDecoder(
    kind: AisSourceKind.replay,
    source: _replayAisSource,
    staleAfter: const Duration(seconds: 90),
    expireAfter: const Duration(minutes: 5),
    clock: clock,
  );

  factory AisNmeaDecoder.localNmea({DateTime Function()? clock}) =>
      AisNmeaDecoder(
        kind: AisSourceKind.localNmea,
        source: _localNmeaAisSource,
        clock: clock,
      );

  final AisSourceKind kind;
  final MarineDataSource source;
  final Duration staleAfter;
  final Duration expireAfter;
  final DateTime Function() _clock;

  final Map<int, AisTarget> _targets = {};
  final Map<int, _AisStaticData> _staticData = {};
  final Map<String, _AisFragments> _fragments = {};
  final Map<String, DateTime> _recentSentences = {};

  bool ingest(String sentence, {DateTime? receivedAt}) {
    final received = (receivedAt ?? _clock()).toUtc();
    final parsed = _parseSentence(sentence);
    if (parsed == null || _isDuplicate(parsed.raw, received)) return false;
    final payload = _assemble(parsed, received);
    if (payload == null) return false;
    final bits = _AisBits(payload.payload, payload.fillBits);
    if (!bits.isUsable || bits.length < 38) return false;
    final messageType = bits.unsigned(0, 6);
    final mmsi = bits.unsigned(8, 30);
    if (mmsi <= 0) return false;

    switch (messageType) {
      case 1:
      case 2:
      case 3:
        final position = _classAPosition(bits, mmsi, received);
        return position == null ? false : _storePosition(position, received);
      case 18:
      case 19:
        final position = _classBPosition(bits, mmsi, received);
        if (position == null) return false;
        if (messageType == 19 && bits.length >= 271) {
          _mergeStatic(
            mmsi,
            _AisStaticData(
              name: bits.text(143, 120),
              shipType: _optionalShipType(bits.unsigned(263, 8)),
            ),
          );
        }
        return _storePosition(position, received);
      case 5:
        if (bits.length < 240) return false;
        return _storeStatic(
          mmsi,
          _AisStaticData(
            callSign: bits.text(70, 42),
            name: bits.text(112, 120),
            shipType: _optionalShipType(bits.unsigned(232, 8)),
          ),
        );
      case 24:
        if (bits.length < 40) return false;
        final part = bits.unsigned(38, 2);
        if (part == 0 && bits.length >= 160) {
          return _storeStatic(mmsi, _AisStaticData(name: bits.text(40, 120)));
        }
        if (part == 1 && bits.length >= 132) {
          return _storeStatic(
            mmsi,
            _AisStaticData(
              shipType: _optionalShipType(bits.unsigned(40, 8)),
              callSign: bits.text(90, 42),
            ),
          );
        }
        return false;
      default:
        return false;
    }
  }

  AisTargetSnapshot snapshot({
    AisConnectionState connectionState = AisConnectionState.connected,
    DateTime? receivedAt,
  }) {
    final now = (receivedAt ?? _clock()).toUtc();
    _targets.removeWhere(
      (_, target) => now.difference(target.receivedAt.toUtc()) > expireAfter,
    );
    final disconnected =
        connectionState != AisConnectionState.connected &&
        connectionState != AisConnectionState.replay;
    final values = _targets.values.toList()
      ..sort((left, right) => left.mmsi.compareTo(right.mmsi));
    return AisTargetSnapshot(
      sourceKind: kind,
      receivedAt: now,
      source: source,
      connectionState: connectionState,
      warning: _aisCoverageWarning,
      targets: [
        for (final target in values)
          MarineDatum(
            value: target,
            source: source,
            validAt: target.positionReportedAt ?? target.receivedAt,
            receivedAt: target.receivedAt,
            staleAfter: disconnected ? Duration.zero : staleAfter,
            unit: 'WGS84 position; SOG kn; COG/heading °T',
            qualityNote: disconnected
                ? 'AIS source disconnected; target is not live.'
                : _aisCoverageWarning,
          ),
      ],
    );
  }

  bool _isDuplicate(String sentence, DateTime receivedAt) {
    _recentSentences.removeWhere(
      (_, time) => receivedAt.difference(time) > const Duration(minutes: 5),
    );
    final previous = _recentSentences[sentence];
    _recentSentences[sentence] = receivedAt;
    return previous != null &&
        receivedAt.difference(previous) < const Duration(seconds: 2);
  }

  _AssembledPayload? _assemble(_NmeaSentence sentence, DateTime receivedAt) {
    if (sentence.fragmentCount == 1) {
      return _AssembledPayload(sentence.payload, sentence.fillBits);
    }
    final key =
        '${sentence.formatter}:${sentence.channel}:${sentence.sequenceId}:'
        '${sentence.fragmentCount}';
    _fragments.removeWhere(
      (_, fragments) =>
          receivedAt.difference(fragments.firstReceivedAt) >
          const Duration(seconds: 30),
    );
    final fragments = _fragments.putIfAbsent(
      key,
      () => _AisFragments(sentence.fragmentCount, receivedAt),
    );
    if (fragments.fragmentCount != sentence.fragmentCount) {
      _fragments.remove(key);
      return null;
    }
    fragments.payloads[sentence.fragmentNumber - 1] = sentence.payload;
    fragments.fillBits = sentence.fillBits;
    if (fragments.payloads.any((part) => part == null)) return null;
    _fragments.remove(key);
    return _AssembledPayload(fragments.payloads.join(), fragments.fillBits);
  }

  _AisPosition? _classAPosition(_AisBits bits, int mmsi, DateTime receivedAt) {
    if (bits.length < 143) return null;
    return _position(
      mmsi: mmsi,
      longitudeRaw: bits.signed(61, 28),
      latitudeRaw: bits.signed(89, 27),
      speedRaw: bits.unsigned(50, 10),
      courseRaw: bits.unsigned(116, 12),
      headingRaw: bits.unsigned(128, 9),
      reportSecond: bits.unsigned(137, 6),
      receivedAt: receivedAt,
      navigationStatus: _navigationStatus(bits.unsigned(38, 4)),
      rateOfTurn: _rateOfTurn(bits.signed(42, 8)),
    );
  }

  _AisPosition? _classBPosition(_AisBits bits, int mmsi, DateTime receivedAt) {
    if (bits.length < 139) return null;
    return _position(
      mmsi: mmsi,
      longitudeRaw: bits.signed(57, 28),
      latitudeRaw: bits.signed(85, 27),
      speedRaw: bits.unsigned(46, 10),
      courseRaw: bits.unsigned(112, 12),
      headingRaw: bits.unsigned(124, 9),
      reportSecond: bits.unsigned(133, 6),
      receivedAt: receivedAt,
    );
  }

  _AisPosition? _position({
    required int mmsi,
    required int longitudeRaw,
    required int latitudeRaw,
    required int speedRaw,
    required int courseRaw,
    required int headingRaw,
    required int reportSecond,
    required DateTime receivedAt,
    String? navigationStatus,
    double? rateOfTurn,
  }) {
    final longitude = longitudeRaw / 600000;
    final latitude = latitudeRaw / 600000;
    if (!longitude.isFinite ||
        !latitude.isFinite ||
        longitude.abs() > 180 ||
        latitude.abs() > 90) {
      return null;
    }
    return _AisPosition(
      mmsi: mmsi,
      latitude: latitude,
      longitude: longitude,
      speedOverGroundKnots: speedRaw >= 1023 ? null : speedRaw / 10,
      courseOverGroundDegrees: courseRaw >= 3600 ? null : courseRaw / 10,
      headingDegrees: headingRaw >= 511 ? null : headingRaw.toDouble(),
      rateOfTurnDegreesPerMinute: rateOfTurn,
      navigationStatus: navigationStatus,
      positionReportedAt: _reportedAt(receivedAt, reportSecond),
    );
  }

  bool _storePosition(_AisPosition position, DateTime receivedAt) {
    final existing = _targets[position.mmsi];
    if (existing != null && receivedAt.isBefore(existing.receivedAt)) {
      return false;
    }
    final staticData = _staticData[position.mmsi];
    _targets[position.mmsi] = AisTarget(
      mmsi: position.mmsi,
      latitude: position.latitude,
      longitude: position.longitude,
      receivedAt: receivedAt,
      positionReportedAt: position.positionReportedAt,
      name: staticData?.name ?? existing?.name,
      callSign: staticData?.callSign ?? existing?.callSign,
      shipType: staticData?.shipType ?? existing?.shipType,
      courseOverGroundDegrees: position.courseOverGroundDegrees,
      speedOverGroundKnots: position.speedOverGroundKnots,
      headingDegrees: position.headingDegrees,
      rateOfTurnDegreesPerMinute: position.rateOfTurnDegreesPerMinute,
      navigationStatus: position.navigationStatus,
    );
    return true;
  }

  bool _storeStatic(int mmsi, _AisStaticData next) {
    final merged = _mergeStatic(mmsi, next);
    final existing = _targets[mmsi];
    if (existing == null) return false;
    _targets[mmsi] = AisTarget(
      mmsi: existing.mmsi,
      latitude: existing.latitude,
      longitude: existing.longitude,
      receivedAt: existing.receivedAt,
      positionReportedAt: existing.positionReportedAt,
      name: merged.name,
      callSign: merged.callSign,
      shipType: merged.shipType,
      courseOverGroundDegrees: existing.courseOverGroundDegrees,
      speedOverGroundKnots: existing.speedOverGroundKnots,
      headingDegrees: existing.headingDegrees,
      rateOfTurnDegreesPerMinute: existing.rateOfTurnDegreesPerMinute,
      navigationStatus: existing.navigationStatus,
    );
    return true;
  }

  _AisStaticData _mergeStatic(int mmsi, _AisStaticData next) {
    final previous = _staticData[mmsi];
    final merged = _AisStaticData(
      name: next.name ?? previous?.name,
      callSign: next.callSign ?? previous?.callSign,
      shipType: next.shipType ?? previous?.shipType,
    );
    _staticData[mmsi] = merged;
    return merged;
  }
}

class ReplayAisTargetSource implements AisTargetSource {
  ReplayAisTargetSource({
    required this.loadFixture,
    this.interval = const Duration(milliseconds: 650),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _decoder = AisNmeaDecoder.replay(clock: clock);

  final Future<String> Function() loadFixture;
  final Duration interval;
  final DateTime Function() _clock;
  final AisNmeaDecoder _decoder;
  final StreamController<AisTargetSnapshot> _snapshots =
      StreamController.broadcast();
  Timer? _timer;
  List<String> _sentences = const [];
  int _index = 0;

  @override
  AisSourceKind get kind => AisSourceKind.replay;

  @override
  MarineDataSource get source => _replayAisSource;

  @override
  Stream<AisTargetSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start() async {
    if (_timer != null) return;
    final fixture = await loadFixture();
    _sentences = const LineSplitter()
        .convert(fixture)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
    if (_sentences.isEmpty) {
      throw const FormatException('The AIS replay fixture has no sentences.');
    }
    _index = 0;
    _emit(AisConnectionState.replay);
    _timer = Timer.periodic(interval, (_) {
      final receivedAt = _clock().toUtc();
      final changed = _decoder.ingest(
        _sentences[_index],
        receivedAt: receivedAt,
      );
      _index = (_index + 1) % _sentences.length;
      if (changed) _emit(AisConnectionState.replay, receivedAt);
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _emit(AisConnectionState.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
  }

  void _emit(AisConnectionState state, [DateTime? receivedAt]) {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      _decoder.snapshot(
        connectionState: state,
        receivedAt: receivedAt ?? _clock(),
      ),
    );
  }
}

class AisNmeaTcpConfiguration {
  const AisNmeaTcpConfiguration({required this.host, required this.port});

  final String host;
  final int port;

  bool get isConfigured => host.trim().isNotEmpty && port > 0 && port <= 65535;

  static AisNmeaTcpConfiguration? fromEnvironment() {
    const configuration = AisNmeaTcpConfiguration(
      host: String.fromEnvironment('TIDE_AND_SEEK_AIS_NMEA_HOST'),
      port: int.fromEnvironment(
        'TIDE_AND_SEEK_AIS_NMEA_PORT',
        defaultValue: 10110,
      ),
    );
    return configuration.isConfigured ? configuration : null;
  }
}

typedef AisSocketConnector =
    Future<Socket> Function(String host, int port, Duration timeout);

class NmeaTcpAisTargetSource implements AisTargetSource {
  NmeaTcpAisTargetSource({
    required this.configuration,
    this.reconnectDelay = const Duration(seconds: 5),
    AisSocketConnector? connector,
    DateTime Function()? clock,
  }) : _connector = connector ?? _connectSocket,
       _clock = clock ?? DateTime.now,
       _decoder = AisNmeaDecoder.localNmea(clock: clock);

  final AisNmeaTcpConfiguration configuration;
  final Duration reconnectDelay;
  final AisSocketConnector _connector;
  final DateTime Function() _clock;
  final AisNmeaDecoder _decoder;
  final StreamController<AisTargetSnapshot> _snapshots =
      StreamController.broadcast();
  Socket? _socket;
  StreamSubscription<String>? _lines;
  Timer? _reconnectTimer;
  bool _running = false;
  bool _connectedOnce = false;
  bool _reconnectScheduled = false;

  @override
  AisSourceKind get kind => AisSourceKind.localNmea;

  @override
  MarineDataSource get source => _localNmeaAisSource;

  @override
  Stream<AisTargetSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _connect();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectScheduled = false;
    await _lines?.cancel();
    _lines = null;
    _socket?.destroy();
    _socket = null;
    _emit(AisConnectionState.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    _emit(
      _connectedOnce
          ? AisConnectionState.reconnecting
          : AisConnectionState.connecting,
    );
    try {
      final socket = await _connector(
        configuration.host,
        configuration.port,
        const Duration(seconds: 5),
      );
      if (!_running) {
        socket.destroy();
        return;
      }
      _socket = socket;
      _connectedOnce = true;
      _reconnectScheduled = false;
      _emit(AisConnectionState.connected);
      _lines = socket
          .map<List<int>>((bytes) => bytes)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final now = _clock().toUtc();
              if (_decoder.ingest(line, receivedAt: now)) {
                _emit(AisConnectionState.connected, now);
              }
            },
            onError: (_) => _scheduleReconnect(),
            onDone: _scheduleReconnect,
            cancelOnError: true,
          );
    } on Object {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectScheduled) return;
    _reconnectScheduled = true;
    _lines = null;
    _socket?.destroy();
    _socket = null;
    _emit(AisConnectionState.disconnected);
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectScheduled = false;
      unawaited(_connect());
    });
  }

  void _emit(AisConnectionState state, [DateTime? receivedAt]) {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      _decoder.snapshot(
        connectionState: state,
        receivedAt: receivedAt ?? _clock(),
      ),
    );
  }

  static Future<Socket> _connectSocket(
    String host,
    int port,
    Duration timeout,
  ) => Socket.connect(host, port, timeout: timeout);
}

class _AisPosition {
  const _AisPosition({
    required this.mmsi,
    required this.latitude,
    required this.longitude,
    required this.positionReportedAt,
    this.courseOverGroundDegrees,
    this.speedOverGroundKnots,
    this.headingDegrees,
    this.rateOfTurnDegreesPerMinute,
    this.navigationStatus,
  });

  final int mmsi;
  final double latitude;
  final double longitude;
  final DateTime? positionReportedAt;
  final double? courseOverGroundDegrees;
  final double? speedOverGroundKnots;
  final double? headingDegrees;
  final double? rateOfTurnDegreesPerMinute;
  final String? navigationStatus;
}

class _AisStaticData {
  const _AisStaticData({this.name, this.callSign, this.shipType});

  final String? name;
  final String? callSign;
  final int? shipType;
}

class _NmeaSentence {
  const _NmeaSentence({
    required this.raw,
    required this.formatter,
    required this.fragmentCount,
    required this.fragmentNumber,
    required this.sequenceId,
    required this.channel,
    required this.payload,
    required this.fillBits,
  });

  final String raw;
  final String formatter;
  final int fragmentCount;
  final int fragmentNumber;
  final String sequenceId;
  final String channel;
  final String payload;
  final int fillBits;
}

class _AisFragments {
  _AisFragments(this.fragmentCount, this.firstReceivedAt)
    : payloads = List.filled(fragmentCount, null);

  final int fragmentCount;
  final DateTime firstReceivedAt;
  final List<String?> payloads;
  int fillBits = 0;
}

class _AssembledPayload {
  const _AssembledPayload(this.payload, this.fillBits);

  final String payload;
  final int fillBits;
}

class _AisBits {
  _AisBits(String payload, int fillBits) {
    final values = <int>[];
    for (final code in payload.codeUnits) {
      var value = code - 48;
      if (value > 40) value -= 8;
      if (value < 0 || value > 63) {
        _usable = false;
        return;
      }
      for (var bit = 5; bit >= 0; bit -= 1) {
        values.add((value >> bit) & 1);
      }
    }
    if (fillBits < 0 || fillBits > 5 || fillBits > values.length) {
      _usable = false;
      return;
    }
    _bits = values.sublist(0, values.length - fillBits);
  }

  List<int> _bits = const [];
  bool _usable = true;

  bool get isUsable => _usable;
  int get length => _bits.length;

  int unsigned(int start, int bitCount) {
    if (start < 0 || bitCount < 0 || start + bitCount > length) return 0;
    var value = 0;
    for (var index = start; index < start + bitCount; index += 1) {
      value = (value << 1) | _bits[index];
    }
    return value;
  }

  int signed(int start, int bitCount) {
    final value = unsigned(start, bitCount);
    final sign = 1 << (bitCount - 1);
    return value & sign == 0 ? value : value - (1 << bitCount);
  }

  String? text(int start, int bitCount) {
    if (bitCount % 6 != 0 || start + bitCount > length) return null;
    const alphabet =
        '@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !"#\$%&\'()*+,-./0123456789:;<=>?';
    final buffer = StringBuffer();
    for (var index = start; index < start + bitCount; index += 6) {
      buffer.write(alphabet[unsigned(index, 6)]);
    }
    final value = buffer.toString().replaceAll('@', ' ').trim();
    return value.isEmpty ? null : value;
  }
}

_NmeaSentence? _parseSentence(String input) {
  final raw = input.trim();
  if (!raw.startsWith('!') || !raw.contains('*')) return null;
  final checksumAt = raw.lastIndexOf('*');
  if (checksumAt <= 1 || checksumAt + 3 > raw.length) return null;
  final expected = int.tryParse(
    raw.substring(checksumAt + 1, checksumAt + 3),
    radix: 16,
  );
  if (expected == null) return null;
  var checksum = 0;
  for (final code in raw.substring(1, checksumAt).codeUnits) {
    checksum ^= code;
  }
  if (checksum != expected) return null;
  final fields = raw.substring(1, checksumAt).split(',');
  if (fields.length != 7 || (fields[0] != 'AIVDM' && fields[0] != 'AIVDO')) {
    return null;
  }
  final fragmentCount = int.tryParse(fields[1]);
  final fragmentNumber = int.tryParse(fields[2]);
  final fillBits = int.tryParse(fields[6]);
  if (fragmentCount == null ||
      fragmentNumber == null ||
      fillBits == null ||
      fragmentCount < 1 ||
      fragmentNumber < 1 ||
      fragmentNumber > fragmentCount ||
      fillBits < 0 ||
      fillBits > 5 ||
      fields[5].isEmpty) {
    return null;
  }
  return _NmeaSentence(
    raw: raw,
    formatter: fields[0],
    fragmentCount: fragmentCount,
    fragmentNumber: fragmentNumber,
    sequenceId: fields[3],
    channel: fields[4],
    payload: fields[5],
    fillBits: fillBits,
  );
}

DateTime? _reportedAt(DateTime receivedAt, int second) {
  if (second < 0 || second > 59) return null;
  var candidate = DateTime.utc(
    receivedAt.year,
    receivedAt.month,
    receivedAt.day,
    receivedAt.hour,
    receivedAt.minute,
    second,
  );
  if (candidate.isAfter(receivedAt.add(const Duration(seconds: 5)))) {
    candidate = candidate.subtract(const Duration(minutes: 1));
  }
  return candidate;
}

double? _rateOfTurn(int encoded) {
  if (encoded == -128) return null;
  if (encoded.abs() == 127) return encoded.isNegative ? -708 : 708;
  final magnitude = math.pow(encoded.abs() / 4.733, 2).toDouble();
  return encoded.isNegative ? -magnitude : magnitude;
}

int? _optionalShipType(int value) => value == 0 ? null : value;

String? _navigationStatus(int value) => switch (value) {
  0 => 'Under way using engine',
  1 => 'At anchor',
  2 => 'Not under command',
  3 => 'Restricted manoeuvrability',
  4 => 'Constrained by draught',
  5 => 'Moored',
  6 => 'Aground',
  7 => 'Engaged in fishing',
  8 => 'Under way sailing',
  15 => null,
  _ => 'Reserved status $value',
};
