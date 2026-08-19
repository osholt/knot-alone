@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #41. The launch screen shipped as Flutter's placeholder: three 68-byte
/// transparent PNGs on a white background. Every launch of a dark app therefore
/// flashed white and showed nothing, and `flutter build ipa` warned about it on
/// every release.
///
/// These are structural checks on files Xcode consumes, not on Dart. They exist
/// because nothing else in the build fails when a launch asset regresses - the
/// app still compiles, still runs, and only looks wrong for the half second
/// nobody screenshots.
void main() {
  const assets = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
  final storyboard = File('ios/Runner/Base.lproj/LaunchScreen.storyboard');

  group('the launch image is a real image', () {
    // The placeholder is 68 bytes: a 1x1 fully transparent PNG.
    const placeholderBytes = 68;

    for (final (name, width, height) in [
      ('LaunchImage.png', 144, 160),
      ('LaunchImage@2x.png', 288, 320),
      ('LaunchImage@3x.png', 432, 480),
    ]) {
      test('$name is drawn and $width x $height', () {
        final file = File('$assets/$name');
        expect(file.existsSync(), isTrue, reason: '$name is missing');

        final bytes = file.readAsBytesSync();
        expect(
          bytes.length,
          greaterThan(placeholderBytes * 10),
          reason: '$name is still the transparent placeholder',
        );

        // PNG dimensions live in the IHDR chunk, bytes 16-23, big-endian.
        int at(int offset) =>
            (bytes[offset] << 24) |
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
        expect(at(16), width, reason: '$name width');
        expect(at(20), height, reason: '$name height');
      });
    }

    test('the three scales are the same picture at three sizes', () {
      final sizes = [
        for (final name in [
          'LaunchImage.png',
          'LaunchImage@2x.png',
          'LaunchImage@3x.png',
        ])
          File('$assets/$name').readAsBytesSync().length,
      ];
      // Strictly increasing, which a copy-pasted set would not be.
      expect(sizes[0], lessThan(sizes[1]));
      expect(sizes[1], lessThan(sizes[2]));
    });
  });

  group('the launch background matches the app', () {
    test('it is the scaffold colour, not white', () {
      final xml = storyboard.readAsStringSync();

      // 0xFF0D1117, the app's scaffoldBackgroundColor, as sRGB components.
      expect(xml, contains('red="0.050980392156862744"'));
      expect(xml, contains('green="0.06666666666666667"'));
      expect(xml, contains('blue="0.09019607843137255"'));
      expect(
        xml,
        isNot(contains('red="1" green="1" blue="1" alpha="1"')),
        reason: 'a white launch screen flashes before a dark app',
      );
    });
  });
}
