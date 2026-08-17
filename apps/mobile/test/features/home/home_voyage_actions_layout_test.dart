import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/home/home_voyage_actions.dart';

/// #28. The actions bar had no width ceiling and its labels had no width floor,
/// so a tablet got two buttons stretched across the whole chart and the terse
/// phone labels at the same time.
void main() {
  final actionRow = find.byKey(const Key('home-voyage-action-row'));

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HomeVoyageActions(
              onCreate: () {},
              onJoin: () {},
              onMore: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('phone', () {
    const iPhone15Pro = Size(393, 852);

    test('sanity: the surface these expectations describe is a phone', () {
      expect(iPhone15Pro.shortestSide, lessThan(700));
    });

    testWidgets('keeps the terse labels that fit 393pt', (tester) async {
      await pumpAt(tester, iPhone15Pro);
      expect(find.text('Join'), findsOneWidget);
      expect(find.text('New voyage'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
    });

    testWidgets('still spans the width, so nothing changed here', (
      tester,
    ) async {
      await pumpAt(tester, iPhone15Pro);
      // 393 less the bar's own 12pt padding either side.
      expect(tester.getSize(actionRow).width, iPhone15Pro.width - 24);
    });
  });

  group('tablet', () {
    const iPadPro13Landscape = Size(1376, 1032);

    testWidgets('says what Join joins', (tester) async {
      await pumpAt(tester, iPadPro13Landscape);
      expect(find.text('Join a voyage'), findsOneWidget);
      expect(find.text('Join'), findsNothing);
    });

    testWidgets('bounds the row instead of stretching it to 1376pt', (
      tester,
    ) async {
      await pumpAt(tester, iPadPro13Landscape);
      final rowWidth = tester.getSize(actionRow).width;
      expect(rowWidth, lessThanOrEqualTo(560));
      // And it is still centred on the bar rather than pushed to one edge.
      final row = tester.getRect(actionRow);
      expect(
        row.center.dx,
        moreOrLessEquals(iPadPro13Landscape.width / 2, epsilon: 1),
      );
    });

    testWidgets('keeps the bar itself full-bleed', (tester) async {
      await pumpAt(tester, iPadPro13Landscape);
      expect(
        tester.getSize(find.byKey(const Key('home-voyage-actions'))).width,
        iPadPro13Landscape.width,
      );
    });
  });
}
