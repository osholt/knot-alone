import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  // #61. Both tests that used to live here drove the road-routing preferences
  // panel: a routing style offering "Twisty (up to 50% longer)", and switches
  // for motorways, major roads, tolls, ferries and unsurfaced byways. Every one
  // was inert, because `RhumbLinePassagePlanner` accepts `preferences` and
  // passes them through untouched (#19). They tested that a sailor could set
  // something that changed nothing.
  //
  // What replaces them is the property that matters: the panel is gone, and the
  // sheet says what it actually does.
  testWidgets('no road-routing preference is offered', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => DestinationRouteSheet.show(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    for (final key in [
      'route-style-field',
      'avoid-motorways-switch',
      'avoid-major-roads-switch',
      'avoid-tolls-switch',
      'avoid-ferries-switch',
      'avoid-unsurfaced-byways-switch',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: '$key should be gone');
    }
    expect(find.text('Route preferences'), findsNothing);
    // "Avoid ferries" on a sailing app is the one that gave the game away.
    expect(find.textContaining('ferries'), findsNothing);
    expect(find.textContaining('web planner'), findsNothing);
  });

  testWidgets('the sheet says it lays one unchecked leg', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => DestinationRouteSheet.show(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // It used to promise a "road-following GPX route" from a router #19 deleted.
    expect(find.textContaining('road-following'), findsNothing);
    expect(find.textContaining('direct course'), findsOneWidget);
    expect(find.textContaining('not checked'), findsOneWidget);
    expect(find.text('Lay a course'), findsOneWidget);
    expect(find.text('Plan road route'), findsNothing);
  });
}
