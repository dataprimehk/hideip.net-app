import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/ui_prefs.dart';
import 'package:hideip_vpn/core/votes.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/locations_screen.dart';
import 'package:hideip_vpn/ui/strings.dart';

Widget _section({required bool expanded, VoidCallback? onToggle}) =>
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ComingNextSection(
              expanded: expanded,
              onToggle: onToggle ?? () {},
              onOpenMap: () {},
            ),
          ],
        ),
      ),
    );

/// Either the country's name or, before the atlas has loaded, its code.
Finder _country(String cc, String name) => find.byWidgetPredicate(
  (w) => w is Text && (w.data == name || w.data == cc),
);

void main() {
  setUp(() {
    // Two standings the server answered with last time; no network now.
    SharedPreferences.setMockInitialValues({
      'votes_counts_v1': jsonEncode({'DE': 10, 'FR': 5}),
    });
    VoteService.instance.resetForTesting();
    VoteService.instance.clientOverride = MockClient(
      (_) async => http.Response('', 503),
    );
    Hip.reducedMotion = true;
  });
  tearDown(() {
    VoteService.instance.resetForTesting();
    Hip.reducedMotion = false;
  });

  test('the folded state persists and starts closed', () async {
    expect(const UiPrefs().comingNextOpen, isFalse);
    expect((await UiPrefs.load()).comingNextOpen, isFalse);
    await const UiPrefs(comingNextOpen: true).save();
    expect((await UiPrefs.load()).comingNextOpen, isTrue);
    expect(
      const UiPrefs().copyWith(comingNextOpen: true).comingNextOpen,
      isTrue,
    );
  });

  testWidgets('closed: the header counts the rows and the pointer stays', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _section(expanded: false, onToggle: () => toggles++),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(S.dComingNext.toUpperCase()), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'two standings wait below');
    expect(
      find.text(S.dVoteTitle),
      findsOneWidget,
      reason: 'the way into voting is visible either way',
    );
    expect(_country('DE', 'Germany'), findsNothing);
    expect(_country('FR', 'France'), findsNothing);
    expect(find.text(S.dVoteNote), findsNothing);

    await tester.tap(find.text(S.dComingNext.toUpperCase()));
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('open: the standings and the note are back', (tester) async {
    await tester.pumpWidget(_section(expanded: true));
    await tester.pump();
    await tester.pump();

    // The header's count, and the rank tile of the second row.
    expect(find.text('2'), findsNWidgets(2));
    expect(_country('DE', 'Germany'), findsOneWidget);
    expect(_country('FR', 'France'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text(S.dVoteNote), findsOneWidget);
  });

  testWidgets('with nothing to show the header carries no count', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    VoteService.instance.resetForTesting();
    VoteService.instance.clientOverride = MockClient(
      (_) async => http.Response('', 503),
    );
    await tester.pumpWidget(_section(expanded: false));
    await tester.pump();
    await tester.pump();
    expect(find.text(S.dComingNext.toUpperCase()), findsOneWidget);
    expect(find.text(' · '), findsNothing);
    expect(find.text(S.dVoteTitle), findsOneWidget);
  });
}
