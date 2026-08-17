import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/features/voyage/voyage_recap_card.dart';
import 'package:tide_and_seek/services/voyage_summary_exporter.dart';

void main() {
  testWidgets('renders headline stats', (tester) async {
    final summary = _summary();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoyageRecapCard(
            summary: summary,
            routePoints: const [
              GeoPoint(latitude: 51, longitude: -1),
              GeoPoint(latitude: 51.01, longitude: -1),
            ],
            distanceUnit: DistanceUnit.kilometres,
          ),
        ),
      ),
    );

    expect(find.text('VOYAGE ABC123'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.textContaining('km'), findsOneWidget);
  });

  testWidgets('shows a placeholder without a recorded route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoyageRecapCard(summary: _summary(), routePoints: const []),
        ),
      ),
    );

    expect(find.text('No recorded route for this voyage'), findsOneWidget);
  });

  group('the shared image never ends a word in an ellipsis (#308)', () {
    /// The card as it is actually exported: the recap screen lays it out inside
    /// 20 logical pixels of padding on a phone-width viewport, and the card
    /// itself is 4:5. Measured at the real size on purpose — this defect is
    /// invisible at any width where the header happens to fit.
    Future<void> pumpAtExportSize(
      WidgetTester tester, {
      double width = 350,
      String voyageCode = 'ABC123',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: VoyageRecapCard(
                  summary: _summary(voyageCode: voyageCode),
                  routePoints: const [
                    GeoPoint(latitude: 51, longitude: -1),
                    GeoPoint(latitude: 51.01, longitude: -1),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// Whether the rendered text was cut short. True is the bug: the exported
    /// PNG reads "TAIL END CHA…" and a stranger sees that first.
    bool clipped(WidgetTester tester, String text) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(text, findRichText: true),
      );
      return paragraph.didExceedMaxLines;
    }

    /// How much of its natural size the text was allowed, 1.0 being all of it.
    ///
    /// Compared between cases rather than against an absolute, because the
    /// test font makes every glyph a square of the font size and so measures
    /// wider than any real one. What must hold on every font is that nothing is
    /// cut off and that the two halves do not compete.
    double scaleOf(WidgetTester tester, String text) {
      final fitted = tester.renderObject<RenderBox>(
        find.ancestor(of: find.text(text), matching: find.byType(FittedBox)),
      );
      final paragraph = tester.renderObject<RenderBox>(find.text(text));
      return fitted.size.width / paragraph.size.width;
    }

    testWidgets('the app name is never cut short', (tester) async {
      await pumpAtExportSize(tester);

      expect(find.text('TAIL END CHARLIE'), findsOneWidget);
      expect(
        clipped(tester, 'TAIL END CHARLIE'),
        isFalse,
        reason: 'this is the image a stranger sees first',
      );
    });

    testWidgets('the voyage code beside it is never cut short', (tester) async {
      await pumpAtExportSize(tester);

      expect(clipped(tester, 'VOYAGE ABC123'), isFalse);
    });

    testWidgets('the longer half of the header gets the larger share', (
      tester,
    ) async {
      // The original defect was two flexible children with the same factor:
      // they split the row evenly whatever they needed, so the app name got
      // half the width against the two thirds it takes. Splitting evenly is
      // still wrong even where nothing clips, because it shrinks the name for
      // room the voyage code was never going to use.
      await pumpAtExportSize(tester);

      double roomFor(String text) => tester
          .renderObject<RenderBox>(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(FittedBox),
            ),
          )
          .size
          .width;

      expect(
        roomFor('TAIL END CHARLIE'),
        greaterThan(roomFor('VOYAGE ABC123')),
      );
    });

    testWidgets('a narrower card shrinks the header rather than clipping it', (
      tester,
    ) async {
      final wide = await (() async {
        await pumpAtExportSize(tester, width: 420);
        return scaleOf(tester, 'TAIL END CHARLIE');
      })();

      await pumpAtExportSize(tester, width: 300);

      expect(clipped(tester, 'TAIL END CHARLIE'), isFalse);
      expect(
        scaleOf(tester, 'TAIL END CHARLIE'),
        lessThan(wide),
        reason: 'something has to give on a narrower card; not the letters',
      );
    });

    testWidgets('a long voyage code cannot squeeze the app name', (
      tester,
    ) async {
      // Neither side may starve the other. Both are laid out loosely with a
      // fixed share, so an unusually long code shrinks itself instead of
      // stealing room from the name.
      await pumpAtExportSize(tester);
      final withShortCode = scaleOf(tester, 'TAIL END CHARLIE');

      await pumpAtExportSize(
        tester,
        voyageCode: 'A-VERY-LONG-VOYAGE-CODE-INDEED',
      );

      expect(clipped(tester, 'TAIL END CHARLIE'), isFalse);
      expect(clipped(tester, 'VOYAGE A-VERY-LONG-VOYAGE-CODE-INDEED'), isFalse);
      expect(scaleOf(tester, 'TAIL END CHARLIE'), withShortCode);
    });
  });
}

VoyageSummary _summary({String voyageCode = 'ABC123'}) => VoyageSummary(
  voyageId: 'voyage-1',
  voyageCode: voyageCode,
  displayName: 'Oliver',
  startedAt: DateTime.utc(2026, 7, 16, 9),
  endedAt: DateTime.utc(2026, 7, 16, 10, 30),
  generatedAt: DateTime.utc(2026, 7, 16, 10, 31),
  eventCount: 42,
  markerSessions: [
    MarkerSessionSummary(
      markerDeviceId: 'device-a',
      startedAt: DateTime.utc(2026, 7, 16, 9, 10),
      endedAt: DateTime.utc(2026, 7, 16, 9, 20),
      uniquePassCount: 7,
      duration: const Duration(minutes: 10),
    ),
  ],
  sailorCount: 4,
  totalDistanceMeters: 32000,
);
