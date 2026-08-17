import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';
import 'package:tide_and_seek/services/voyage_completion_detector.dart';

void main() {
  const assessment = VoyageCompletionAssessment(
    routeProgressFraction: 0.94,
    minimumRouteProgressFraction: 0.9,
    destinationRadiusMeters: 90,
    sailorCount: 4,
    freshSailorCount: 4,
    arrivedSailorCount: 4,
  );

  testWidgets('completion asks the skipper instead of ending silently', (
    tester,
  ) async {
    VoyageCompletionDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showVoyageCompletionDialog(
                context,
                assessment: assessment,
                relayCanCarryReopen: true,
              );
            },
            child: const Text('Check completion'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check completion'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('voyage-completion-suggestion')),
      findsOneWidget,
    );
    expect(find.textContaining('4 of 4 sailors'), findsOneWidget);
    expect(find.textContaining('94% of the route'), findsOneWidget);
    expect(
      find.textContaining('resume this voyage within 24 hours'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('continue-completed-voyage')));
    await tester.pumpAndSettle();
    expect(decision, VoyageCompletionDecision.continueVoyage);
  });

  testWidgets('unsupported relays warn before the skipper ends', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showVoyageCompletionDialog(
              context,
              assessment: assessment,
              relayCanCarryReopen: false,
            ),
            child: const Text('Check completion'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check completion'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('cannot resume an ended voyage'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('confirm-completed-voyage')), findsOneWidget);
  });
}
