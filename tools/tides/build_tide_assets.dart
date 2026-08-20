import 'dart:convert';
import 'dart:io';

const databaseCommit = 'ac4b610af86fc38850cd2cdcc6d4a7aed314dd56';
const predictorCommit = '0f4f1523f25b3e78c6523afc544332683d795689';

const stationIds = [
  'lymington-lym-gbr-cco',
  'portsmouth-ptm-gbr-bodc',
  'southampton-sou-gbr-da_idh',
];

Future<void> main(List<String> arguments) async {
  final options = _options(arguments);
  final database = Directory(options['database']!);
  final predictor = Directory(options['predictor']!);
  final output = File(options['output']!);

  await _requireCommit(database, databaseCommit);
  await _requireCommit(predictor, predictorCommit);

  final stations = <Object?>[];
  for (final id in stationIds) {
    final input = File('${database.path}/data/ticon/$id.json');
    final station = jsonDecode(await input.readAsString());
    if (station is! Map<String, Object?>) {
      throw FormatException('Station $id is not a JSON object.');
    }
    final licence = station['license'];
    if (licence is! Map || licence['type'] != 'cc-by-4.0') {
      throw StateError('Station $id is not licensed CC BY 4.0.');
    }
    if (station['type'] != 'reference' || station['chart_datum'] != 'LAT') {
      throw StateError('Station $id is not a LAT reference station.');
    }
    final datums = station['datums'];
    if (datums is! Map || datums['MSL'] is! num || datums['LAT'] is! num) {
      throw StateError('Station $id has no numeric MSL/LAT transform.');
    }
    stations.add({
      'id': id,
      'name': station['name'],
      'latitude': station['latitude'],
      'longitude': station['longitude'],
      'timezone': station['timezone'],
      'qualityNote': station['disclaimers'],
      'datums': datums,
      'chartDatum': station['chart_datum'],
      'harmonics': station['harmonic_constituents'],
    });
  }

  final definitionsFile = File(
    '${predictor.path}/packages/tide-predictor/src/constituents/data.json',
  );
  final definitions = jsonDecode(await definitionsFile.readAsString());
  if (definitions is! List || definitions.isEmpty) {
    throw const FormatException('Neaps constituent definitions are empty.');
  }

  final payload = {
    'schemaVersion': 1,
    'generatedFrom': {
      'databaseRepository': 'https://github.com/openwatersio/tide-database',
      'databaseCommit': databaseCommit,
      'predictorRepository': 'https://github.com/openwatersio/neaps',
      'predictorCommit': predictorCommit,
    },
    'source': {
      'name': 'TICON-4 via Neaps tide-database',
      'url': 'https://www.seanoe.org/data/00980/109129/',
      'licence': 'CC BY 4.0',
      'attribution':
          'TICON-4 harmonic data via the Neaps tide database (CC BY 4.0)',
      'warning':
          'Astronomical prediction only. Not official, not observed, and does '
          'not include weather effects.',
    },
    'stations': stations,
    'constituentDefinitions': definitions,
  };

  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
  );
  stdout.writeln('Wrote ${output.path} with ${stations.length} stations.');
}

Map<String, String> _options(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
      throw const FormatException(
        'Usage: dart run tools/tides/build_tide_assets.dart '
        '--database PATH --predictor PATH --output FILE',
      );
    }
    values[arguments[index].substring(2)] = arguments[index + 1];
  }
  for (final required in ['database', 'predictor', 'output']) {
    if (values[required]?.trim().isEmpty ?? true) {
      throw FormatException('Missing --$required.');
    }
  }
  return values;
}

Future<void> _requireCommit(Directory repository, String expected) async {
  final result = await Process.run('git', [
    '-C',
    repository.path,
    'rev-parse',
    'HEAD',
  ]);
  final actual = '${result.stdout}'.trim();
  if (result.exitCode != 0 || actual != expected) {
    throw StateError(
      '${repository.path} must be pinned at $expected; found '
      '${actual.isEmpty ? 'no Git commit' : actual}.',
    );
  }
}
