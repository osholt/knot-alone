import 'package:flutter/services.dart';

import 'gpx_import_source.dart';

/// Bridges a GPX file handed to the app by the platform's "Open in..." /
/// file-association delivery (as opposed to one the user picked through this
/// app's own file picker). The native side only ever stores the most recent
/// pending file and hands it over on request - there is no live event
/// stream, so there is no ordering race between "native delivered it" and
/// "Dart's listener is attached yet".
class SharedGpxChannel {
  const SharedGpxChannel();

  static const _channel = MethodChannel('me.osholt.ride_relay/gpx_import');

  Future<PickedGpxFile?> consumePending() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'consumePendingGpxImport',
      );
      if (result == null) return null;
      final bytes = result['bytes'] as Uint8List;
      final fileName = result['fileName'] as String? ?? 'shared.gpx';
      return PickedGpxFile(name: fileName, bytes: bytes);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
