import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/voyage_layout.dart';

/// Real device sizes in logical points, so the expectations below are claims
/// about hardware rather than about arbitrary numbers.
const _iPhoneSePortrait = Size(375, 667);
const _iPhoneSeLandscape = Size(667, 375);
const _iPhone15ProPortrait = Size(393, 852);
const _iPhone15ProLandscape = Size(852, 393);
const _iPadMiniPortrait = Size(744, 1133);
const _iPadMiniLandscape = Size(1133, 744);
const _iPadPro13Portrait = Size(1032, 1376);
const _iPadPro13Landscape = Size(1376, 1032);

/// Half of a landscape iPad Pro under Split View — the case that motivates
/// deriving layout from size rather than from the device.
const _iPadSplitViewHalf = Size(678, 1032);

void main() {
  group('phones', () {
    test('are never treated as tablets', () {
      for (final size in [
        _iPhoneSePortrait,
        _iPhoneSeLandscape,
        _iPhone15ProPortrait,
        _iPhone15ProLandscape,
      ]) {
        expect(
          VoyageLayout(size: size).isTablet,
          isFalse,
          reason: '$size should not be a tablet',
        );
      }
    });

    test('are compact in height only in landscape', () {
      expect(VoyageLayout(size: _iPhone15ProPortrait).isCompactHeight, isFalse);
      expect(VoyageLayout(size: _iPhone15ProLandscape).isCompactHeight, isTrue);
      expect(VoyageLayout(size: _iPhoneSePortrait).isCompactHeight, isFalse);
      expect(VoyageLayout(size: _iPhoneSeLandscape).isCompactHeight, isTrue);
    });

    test('cannot host a side panel in either orientation', () {
      expect(
        VoyageLayout(size: _iPhone15ProLandscape).canHostSidePanel,
        isFalse,
      );
      expect(
        VoyageLayout(size: _iPhone15ProPortrait).canHostSidePanel,
        isFalse,
      );
    });
  });

  group('tablets', () {
    test('are recognised in both orientations', () {
      for (final size in [
        _iPadMiniPortrait,
        _iPadMiniLandscape,
        _iPadPro13Portrait,
        _iPadPro13Landscape,
      ]) {
        expect(
          VoyageLayout(size: size).isTablet,
          isTrue,
          reason: '$size should be a tablet',
        );
      }
    });

    // The regression this whole class exists for. The old code compacted the
    // chrome whenever the surface was landscape, which on an iPad is the
    // roomiest configuration there is.
    test('are never height-compacted, landscape included', () {
      for (final size in [
        _iPadMiniPortrait,
        _iPadMiniLandscape,
        _iPadPro13Portrait,
        _iPadPro13Landscape,
      ]) {
        final layout = VoyageLayout(size: size);
        expect(
          layout.isCompactHeight,
          isFalse,
          reason: '$size has ${size.height}pt of height and is not cramped',
        );
        expect(layout.usesCompactDensity, isFalse);
        expect(layout.toolbarHeight, 52);
        expect(layout.chromeIconSize, 24);
      }
    });

    test('host a side panel only in landscape', () {
      expect(VoyageLayout(size: _iPadPro13Landscape).canHostSidePanel, isTrue);
      expect(VoyageLayout(size: _iPadMiniLandscape).canHostSidePanel, isTrue);
      expect(VoyageLayout(size: _iPadPro13Portrait).canHostSidePanel, isFalse);
      expect(VoyageLayout(size: _iPadMiniPortrait).canHostSidePanel, isFalse);
    });

    test('get a larger overview inset and a larger tap target', () {
      final tablet = VoyageLayout(size: _iPadPro13Landscape);
      final phone = VoyageLayout(size: _iPhone15ProLandscape);
      expect(
        tablet.groupMiniMapSize.width,
        greaterThan(phone.groupMiniMapSize.width),
      );
      expect(
        tablet.groupMiniMapSize.height,
        greaterThan(phone.groupMiniMapSize.height),
      );
      expect(tablet.minimumTapTarget, greaterThan(phone.minimumTapTarget));
    });
  });

  group('multitasking', () {
    // Split View hands the app a window, not a device. A narrow slice of an iPad
    // has to lay out like the space it actually has.
    test(
      'a narrow Split View slice loses its side panel but keeps its height',
      () {
        final layout = VoyageLayout(size: _iPadSplitViewHalf);
        expect(layout.isCompactWidth, isFalse); // 678pt still fits side by side
        expect(layout.isCompactHeight, isFalse);
        expect(layout.canHostSidePanel, isFalse); // taller than wide
      },
    );

    test('a very narrow slice is treated as compact in width', () {
      expect(VoyageLayout(size: const Size(320, 1032)).isCompactWidth, isTrue);
    });
  });

  group('breakpoint edges', () {
    test('compact height excludes the boundary itself', () {
      const h = VoyageBreakpoints.compactHeight;
      expect(VoyageLayout(size: Size(400, h - 1)).isCompactHeight, isTrue);
      expect(VoyageLayout(size: Size(400, h)).isCompactHeight, isFalse);
    });

    test('tablet detection includes the boundary itself', () {
      const s = VoyageBreakpoints.tabletShortestSide;
      expect(VoyageLayout(size: Size(s, 900)).isTablet, isTrue);
      expect(VoyageLayout(size: Size(s - 1, 900)).isTablet, isFalse);
    });

    test('an exactly square surface is not landscape', () {
      expect(VoyageLayout(size: const Size(800, 800)).isLandscape, isFalse);
    });
  });

  test('equality is by size, so it is cheap to rebuild with', () {
    expect(
      VoyageLayout(size: _iPadMiniLandscape),
      VoyageLayout(size: _iPadMiniLandscape),
    );
    expect(
      VoyageLayout(size: _iPadMiniLandscape),
      isNot(VoyageLayout(size: _iPadMiniPortrait)),
    );
  });
}
