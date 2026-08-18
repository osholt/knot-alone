import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'gpx_parser.dart';

/// The bundled demonstration passage.
///
/// "Use demo route" is the one option that needs no file and no typing, so it is
/// what a new sailor is most likely to tap first — which makes it the app's
/// self-description. It used to load a 10.9-mile **motorcycle road route** from a
/// Kingswood car park to a pub in Old Sodbury, complete with four turn
/// instructions, a "very twisty" score and a waypoint called "second-bike-drop
/// marker point" (#35).
///
/// It is now a Solent crossing: Lymington to Cowes, four legs, 8.6 nautical miles.
/// The track is sampled along the rhumb line between each mark, so the drawn line
/// is the course actually steered and the leg table (#32) reads properly.
///
/// The bundled manoeuvre fixture is gone rather than translated. A passage has no
/// turns to enumerate, and the guidance surfaces already say so when a route
/// carries none — inventing marine "manoeuvres" would have been the same mistake
/// in a different coat.
///
/// The GPX's own description says the mark positions are approximate and that it
/// is not a planned passage. A demo route in a navigation app must not look like
/// checked chart work.
class BundledDemoRouteLoader {
  const BundledDemoRouteLoader();

  Future<ImportedRoute> load() async {
    final data = await rootBundle.load('assets/demo_route.gpx');
    return const GpxParser().parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      routeId: const Uuid().v4(),
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.now(),
    );
  }
}
