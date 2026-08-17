import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';

void main() {
  testWidgets('the skipper Leave flow offers end for everyone directly', (
    tester,
  ) async {
    VoyageExitDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showVoyageExitDialog(context, isSkipper: true);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Leave or end this voyage?'), findsOneWidget);
    expect(find.byKey(const Key('leave-only-this-phone')), findsOneWidget);
    expect(find.byKey(const Key('end-voyage-for-everyone')), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-voyage-for-everyone')));
    await tester.pumpAndSettle();

    expect(decision, VoyageExitDecision.endForEveryone);
  });

  testWidgets('a sailor cannot end the voyage for everyone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showVoyageExitDialog(context, isSkipper: false),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Leave this voyage?'), findsOneWidget);
    expect(find.byKey(const Key('end-voyage-for-everyone')), findsNothing);
    expect(find.text('Leave voyage'), findsOneWidget);
  });

  // #362: a solo voyage is still led by the sailor, so isSkipper is true and the
  // dialog told somebody alone on a road that they were about to end the voyage
  // "for everyone" and offered them a choice between leaving it and ending it -
  // two descriptions of the same act, since there is nobody to leave it to.
  testWidgets('a solo voyage is ended, not left, and nothing is for everyone', (
    tester,
  ) async {
    VoyageExitDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showVoyageExitDialog(
                context,
                isSkipper: true,
                isSolo: true,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('End this voyage?'), findsOneWidget);
    expect(find.textContaining('everyone'), findsNothing);
    expect(find.textContaining('group'), findsNothing);
    // One act, one action: there is no "leave" distinct from "end".
    expect(find.byKey(const Key('leave-only-this-phone')), findsNothing);
    expect(find.text('End voyage'), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-voyage-for-everyone')));
    await tester.pumpAndSettle();

    expect(decision, VoyageExitDecision.endForEveryone);
  });
}
