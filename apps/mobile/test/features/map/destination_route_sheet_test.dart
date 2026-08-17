import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/route_preferences.dart';
import 'package:tide_and_seek/features/map/destination_route_sheet.dart';

void main() {
  testWidgets('collects a destination and offers marine app handoff', (
    tester,
  ) async {
    DestinationPlanRequest? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                request = await DestinationRouteSheet.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('destination-field')),
      'Matlock Bath',
    );
    await tester.tap(find.byKey(const Key('add-route-stop')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('route-stop-field-0')),
      'Bakewell',
    );
    // The sheet now also carries the route preferences (#182), so the handoff
    // field can start below the fold.
    await tester.scrollUntilVisible(
      find.byKey(const Key('destination-handoff-field')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('destination-handoff-field')));
    await tester.pumpAndSettle();

    expect(find.text('Navionics Boating'), findsOneWidget);
    expect(find.text('Aqua Map'), findsOneWidget);
    // The road apps the inherited sheet offered are gone (#30).
    expect(find.text('Calimoto'), findsNothing);
    expect(find.text('Google Maps'), findsNothing);

    await tester.tap(find.text('Aqua Map'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();

    expect(request?.query, 'Matlock Bath');
    expect(request?.stopQueries, const ['Bakewell']);
    expect(request?.handoffTarget?.name, 'aquaMap');
  });

  testWidgets('restores an edited request and allows stops to be reordered', (
    tester,
  ) async {
    DestinationPlanRequest? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                request = await DestinationRouteSheet.show(
                  context,
                  initialRequest: const DestinationPlanRequest(
                    startQuery: 'Start',
                    stopQueries: ['First', 'Second'],
                    query: 'Finish',
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);

    await tester.tap(find.byKey(const Key('move-route-stop-down-0')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();

    expect(request?.stopQueries, const ['Second', 'First']);
  });

  testWidgets('unsurfaced byways are avoided until a sailor says otherwise', (
    tester,
  ) async {
    DestinationPlanRequest? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                request = await DestinationRouteSheet.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('destination-field')),
      'Matlock Bath',
    );

    final bywaySwitch = find.byKey(const Key('avoid-unsurfaced-byways-switch'));
    await tester.scrollUntilVisible(
      bywaySwitch,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      tester.widget<SwitchListTile>(bywaySwitch).value,
      isTrue,
      reason: 'the documented default is to avoid them',
    );

    await tester.tap(find.byKey(const Key('avoid-motorways-switch')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();

    expect(request?.preferences.avoidMotorways, isTrue);
    expect(
      request?.preferences.bywaySurface,
      BywaySurfacePreference.avoidUnsurfaced,
    );
    // Avoiding motorways alone is not a byway decision, and vice versa.
    expect(request?.preferences.style, RouteStyle.quickest);
  });

  testWidgets('a sailor can ask for twisty roads and for byways', (
    tester,
  ) async {
    DestinationPlanRequest? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                request = await DestinationRouteSheet.show(
                  context,
                  initialRequest: const DestinationPlanRequest(
                    query: 'Matlock Bath',
                    preferences: RoutePreferences(style: RouteStyle.twisty),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final bywaySwitch = find.byKey(const Key('avoid-unsurfaced-byways-switch'));
    await tester.scrollUntilVisible(
      bywaySwitch,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(bywaySwitch);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();

    expect(request?.preferences.style, RouteStyle.twisty);
    expect(
      request?.preferences.bywaySurface,
      BywaySurfacePreference.allowUnsurfaced,
    );
    expect(request?.preferences.requiresMotorcycleCosting, isTrue);
  });
}
