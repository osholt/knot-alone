import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/navigation_export_sheet.dart';
import 'package:tide_and_seek/services/navigation_export.dart';

void main() {
  Future<NavigationTarget?> openSheet(WidgetTester tester) async {
    NavigationTarget? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selected = await NavigationExportSheet.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return selected;
  }

  testWidgets('offers marine apps and the generic GPX share', (tester) async {
    await openSheet(tester);

    expect(find.text('Share GPX file'), findsOneWidget);
    expect(find.text('Navionics Boating'), findsOneWidget);
    expect(find.text('Aqua Map'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('savvy navvy'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('iSailor'), findsOneWidget);
    expect(find.text('OpenCPN'), findsOneWidget);
    expect(find.text('Garmin ActiveCaptain'), findsOneWidget);
  });

  testWidgets('offers no road or motorcycle app', (tester) async {
    await openSheet(tester);
    for (final banned in [
      'Google Maps',
      'Waze',
      'Calimoto',
      'MyRoute-app',
      'BMW Motorrad',
      'Harley-Davidson',
    ]) {
      expect(find.text(banned), findsNothing, reason: banned);
    }
  });

  testWidgets('says the same thing about every option, because it is true', (
    tester,
  ) async {
    await openSheet(tester);
    // No "direct links cannot transfer an exact route" caveat any more: there
    // are no direct links, and every option carries the whole GPX.
    expect(find.textContaining('full GPX route'), findsOneWidget);
    expect(find.textContaining('Direct links'), findsNothing);
  });

  testWidgets('returns the tapped target', (tester) async {
    NavigationTarget? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selected = await NavigationExportSheet.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Navionics Boating'));
    await tester.pumpAndSettle();
    expect(selected, NavigationTarget.navionics);
  });
}
